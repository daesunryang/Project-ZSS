class_name ServerWorld
extends RefCounted
## Authoritative world state and rules on the server (docs/08 §3).
##
## Owns: entity ids, registry, inventory, all known players and the
## player_key -> player_id map. No networking and no file I/O here: the
## NetworkService calls in with validated intents, WorldPersistence turns
## this into save documents. Fully testable without nodes.
##
## Extension seam (Phase 2 P2-0): ServerSystem instances registered with
## register_system() are seeded with new worlds, told about players coming
## online/offline, stepped by step_systems() every server physics tick and
## persisted under "systems" in world_state.json and players/<id>.json.
##
## Characters (P2-T9, docs/00 ADR-015, docs/09 §14.24). A player is
## "connected" from join() to leave() and "online" (in the world: visible,
## stepped by the systems, able to act) only while it has a character:
##   - require_character_creation false (the default of this class and of
##     compositions built directly): join() gives a player without a
##     character the default one, so connected == online as before P2-T9.
##   - true (dedicated servers): a new player stays connected but not online
##     until create_character() succeeds. Every existing rule keys off
##     is_online() / online_player_ids() / on_player_online(), so such a
##     player cannot move or act ("not_online"), has no vitals, is no target
##     and is in no snapshot. A dead character stays online (a body in the
##     world) and its player creates the next one with create_character()
##     once the systems allow it (new_character_block_reason).

const SCHEMA_VERSION: int = 4
const KEY_SYSTEMS: String = "systems"
## Schema v4 (P3-1): world items and zombies may be saved in cell documents
## instead of the world document (see to_documents).
## WorldClock calendar time and action time (docs/09 §14.16). The action
## time was added in schema v3 (P2-T1).
const KEY_WORLD_TIME: String = "world_time_sec"
const KEY_ACTION_TIME: String = "action_time_sec"
const SYSTEM_ID_PATTERN: String = "^[a-z][a-z0-9_]*$"
const ENTITY_KIND_PLAYER: String = "player"
const REASON_NOT_ONLINE: String = "not_online"
const REASON_STALE_SEQUENCE: String = "stale_sequence"
const REASON_UNKNOWN_PLAYER: String = "unknown_player"
const EVENT_CHARACTER_STARTED: String = "character_started"
## A character was created by request (create_character).
const EVENT_CHARACTER_CREATED: String = "character_created"
## The player is known but has no connection (create_character).
const REASON_NOT_CONNECTED: String = "not_connected"
## Another player's character has this name and duplicates are not allowed.
const REASON_NAME_TAKEN: String = "name_taken"
## Reasons about the other player of an action between two players (a use on
## another player, ItemConsumption.try_use_on). The target is no player that
## can be reached: unknown, not connected, or connected without a character.
## One reason for all three, so a requester cannot probe which player ids
## exist.
const REASON_TARGET_UNAVAILABLE: String = "target_unavailable"
const REASON_TARGET_DEAD: String = "target_dead"
const REASON_TARGET_TOO_FAR: String = "target_too_far"

var world_id: String
var gameplay: GameplaySettings
var ids: EntityIdGenerator = EntityIdGenerator.new()
var registry: EntityRegistry = EntityRegistry.new()
var inventory: InventoryService
## Authoritative world clock (calendar time and action time).
## ServerComposition replaces it with a clock built from WorldClockSettings;
## this default is a real-time clock (scale 1), paused when empty.
var clock: WorldClock = WorldClock.new()
## Name rules and appearance definitions (P2-T9). ServerComposition replaces
## it with the configured rules; this default has the default name rules and
## no appearance slots.
var character_rules: CharacterRules = CharacterRules.new(CharacterSettings.new(), AppearanceCatalog.new())
## See the header: true = players create their characters themselves.
var require_character_creation: bool = false
## World cells (P3-1, docs/09 §15.1): the cell grid and the index of which
## cell every world entity in memory is in. ServerComposition replaces the
## grid with one built from WorldCellSettings (before anything is placed);
## this default is the default grid. See the "world cells" block below.
var cell_grid: WorldCellGrid = WorldCellGrid.new()
var cell_index: WorldCellIndex = WorldCellIndex.new()

## The registered WorldCellService, or null: a world without one keeps every
## cell in memory and simulates everything, as before P3-1.
var _cells: WorldCellService = null
var _players: Dictionary[String, PlayerState] = {}
var _player_ids_by_key: Dictionary[String, String] = {}
## Players in the world (connected and with a character).
var _online: Dictionary[String, bool] = {}
## Players with a connection, with or without a character (P2-T9).
var _connected: Dictionary[String, bool] = {}
## player_id -> {"direction": Vector2, "sequence": int, "received_msec": int}
var _move_inputs: Dictionary[String, Dictionary] = {}
var _systems: Dictionary[String, ServerSystem] = {}
## Registration order (= step order and save order; deterministic).
var _system_order: Array[ServerSystem] = []
## The systems that can stop a mover (ServerSystem.constrains_movement), in
## registration order (P3-4a). Empty in a world without structures.
var _movement_constraints: Array[ServerSystem] = []


func _init(id: String, gameplay_settings: GameplaySettings, catalog: ItemCatalog) -> void:
	world_id = id
	gameplay = gameplay_settings
	inventory = InventoryService.new(catalog, ids, registry, gameplay.pickup_range_m, gameplay.world_half_extent_m, cell_index)
	inventory.merge_on_pickup = gameplay.merge_stacks_on_pickup


## Populates a brand-new world from the development seed.
func seed_new_world(seed: DevWorldSeed) -> Error:
	var errors: PackedStringArray = seed.validate()
	if not errors.is_empty():
		GameLogger.error("world", "invalid world seed", {"world_id": world_id, "errors": "; ".join(errors), "operation": "seed_world"})
		return ERR_INVALID_DATA
	for index: int in range(seed.item_definition_ids.size()):
		var item_id: String = inventory.spawn_world_item(seed.item_definition_ids[index], seed.quantity_at(index), cell_id_at(seed.item_positions[index]), seed.item_positions[index])
		if item_id.is_empty():
			return ERR_INVALID_DATA
	for system: ServerSystem in _system_order:
		var error: Error = system.seed_new_world(self)
		if error != OK:
			GameLogger.error("world", "system failed to seed world", {"world_id": world_id, "system": system.get_system_id(), "error": error_string(error), "operation": "seed_world"})
			return error
	GameLogger.info("world", "new world seeded", {"world_id": world_id, "items": seed.item_definition_ids.size(), "systems": _system_order.size()})
	return OK


## Registers a system (before seeding/restoring). Fails on invalid or
## duplicate ids.
func register_system(system: ServerSystem) -> Error:
	var system_id: String = system.get_system_id()
	if RegEx.create_from_string(SYSTEM_ID_PATTERN).search(system_id) == null:
		GameLogger.error("world", "invalid system id", {"world_id": world_id, "system": system_id, "operation": "register_system"})
		return ERR_INVALID_PARAMETER
	if _systems.has(system_id):
		GameLogger.error("world", "duplicate system id", {"world_id": world_id, "system": system_id, "operation": "register_system"})
		return ERR_ALREADY_EXISTS
	_systems[system_id] = system
	_system_order.append(system)
	if system is WorldCellService:
		_cells = system as WorldCellService
	if system.constrains_movement():
		_movement_constraints.append(system)
	system.on_registered(self)
	return OK


## Registered system by id, or null.
func get_system(system_id: String) -> ServerSystem:
	return _systems.get(system_id, null)


## Registered system ids in registration order.
func system_ids() -> PackedStringArray:
	var ids_out: PackedStringArray = []
	for system: ServerSystem in _system_order:
		ids_out.append(system.get_system_id())
	return ids_out


## Advances the world clock and every system. Called once per server
## physics tick (after movement). Systems get the action delta (real
## seconds) and the calendar delta of the tick; both are 0 while the clock
## is paused (ServerSystem.step). Returns the calendar delta applied.
func step_systems(real_delta: float) -> float:
	var world_delta: float = clock.step(real_delta, not _online.is_empty())
	var action_delta: float = clock.last_action_delta
	for system: ServerSystem in _system_order:
		system.step(self, action_delta, world_delta)
	return world_delta


## Connects a player: the existing player for `player_key`, or a new one.
## Returns null if the key is already connected or creation fails. A player
## with a character is online (in the world) at once. A player without one
## gets the default character when creation is not required; otherwise it
## stays connected but not online until create_character() (P2-T9).
func join(player_key: String) -> PlayerState:
	var player_id: String = _player_ids_by_key.get(player_key, "")
	if not player_id.is_empty() and _connected.has(player_id):
		GameLogger.warning("world", "player key already online", {"world_id": world_id, "player_id": player_id, "operation": "join"})
		return null
	var state: PlayerState = null
	if player_id.is_empty():
		state = _create_player(player_key)
		if state == null:
			return null
	else:
		state = _players[player_id]
	_connected[state.player_id] = true
	if not state.has_character() and not require_character_creation:
		state.character = character_rules.default_profile()
	if state.has_character():
		_enter_world(state)
	else:
		GameLogger.info("world", "player connected without a character", {"world_id": world_id, "player_id": state.player_id})
	return state


## Takes a player offline (state is kept for saving and reconnect).
func leave(player_id: String) -> void:
	_move_inputs.erase(player_id)
	var was_connected: bool = _connected.erase(player_id)
	if _online.erase(player_id):
		GameLogger.info("world", "player offline", {"world_id": world_id, "player_id": player_id})
		for system: ServerSystem in _system_order:
			system.on_player_offline(self, player_id)
	elif was_connected:
		GameLogger.info("world", "player disconnected without a character", {"world_id": world_id, "player_id": player_id})


## True while the player is in the world: connected and with a character
## (alive or dead). Every game rule asks this, not is_player_connected().
func is_online(player_id: String) -> bool:
	return _online.has(player_id)


## True from join() to leave(), with or without a character (P2-T9).
func is_player_connected(player_id: String) -> bool:
	return _connected.has(player_id)


## True once the player has created a character (alive or dead).
func has_character(player_id: String) -> bool:
	var state: PlayerState = _players.get(player_id, null)
	return state != null and state.has_character()


## "" when the player may create a character now (create_character would
## not be refused for its state), otherwise a reason code: unknown_player,
## not_connected, or what a system answers for a player that already has a
## character (ServerSystem.new_character_block_reason: "character_alive",
## "respawn_wait").
func character_creation_block_reason(player_id: String) -> String:
	var state: PlayerState = _players.get(player_id, null)
	if state == null:
		return REASON_UNKNOWN_PLAYER
	if not _connected.has(player_id):
		return REASON_NOT_CONNECTED
	if not state.has_character():
		return ""
	for system: ServerSystem in _system_order:
		var reason: String = system.new_character_block_reason(player_id)
		if not reason.is_empty():
			return reason
	return ""


## The player creates a character with this name and appearance (docs/00
## ADR-015, docs/09 §14.24). The arguments are untrusted (Variant): they are
## checked by CharacterRules. Order of checks: the player's state
## (character_creation_block_reason), the request (types, name, appearance),
## then the name of other players' characters when duplicates are not
## allowed ("name_taken", compared without case; all known players count,
## also those who are away).
##   - First character: the player enters the world at the spawn point
##     (generation 1; systems get on_player_online).
##   - After a death: start_new_character() with the new profile.
## Success event:
##   {event_type: "character_created", player_id, character_generation,
##    name, appearance: {slot_id: option_id}, position: [x, y, z],
##    first_character: bool, dropped_item_instance_ids: Array of String}
## A refused request changes nothing.
func create_character(player_id: String, raw_name: Variant, raw_appearance: Variant) -> ActionResult:
	var blocked: String = character_creation_block_reason(player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var checked: ActionResult = character_rules.check_request(raw_name, raw_appearance)
	if not checked.ok:
		return checked
	var profile: CharacterProfile = CharacterRules.profile_of(checked)
	if not character_rules.settings.allow_duplicate_names and _is_name_taken(profile.name, player_id):
		return ActionResult.failure(REASON_NAME_TAKEN)
	var state: PlayerState = _players[player_id]
	var first_character: bool = not state.has_character()
	var dropped_ids: Variant = []
	if first_character:
		state.character = profile
		state.character_generation = PlayerState.FIRST_CHARACTER_GENERATION
		state.position = clamp_to_world(gameplay.player_spawn_position)
		_move_inputs.erase(player_id)
		_enter_world(state)
	else:
		var started: ActionResult = start_new_character(player_id, profile)
		if not started.ok:
			return started
		dropped_ids = started.event.get("dropped_item_instance_ids", [])
	GameLogger.info("world", "character created", {"world_id": world_id, "player_id": player_id, "character_generation": state.character_generation, "character_name": state.character.name, "first_character": first_character})
	return ActionResult.success({
		"event_type": EVENT_CHARACTER_CREATED,
		"player_id": player_id,
		"character_generation": state.character_generation,
		"name": state.character.name,
		"appearance": state.character.appearance.duplicate(),
		"position": [state.position.x, state.position.y, state.position.z],
		"first_character": first_character,
		"dropped_item_instance_ids": dropped_ids,
	})


func get_player(player_id: String) -> PlayerState:
	return _players.get(player_id, null)


## Ends the player's current character and starts the next one (docs/00
## ADR-007 permanent death, docs/09 §14.19). SurvivalService decides when;
## this changes the world-owned player state only:
##   - whatever is still carried goes to the world where the old character
##     is (normally nothing: a death drops everything at once; this covers
##     saves written before P2-T4), so a new character always starts empty;
##   - the transform returns to the configured spawn and pending movement
##     intent is discarded;
##   - the character generation goes up by one;
##   - the character gets `profile` (name and appearance, P2-T9). Without
##     one (a character that starts by itself where creation is not
##     required) the previous profile carries over;
##   - every system is told (ServerSystem.on_character_started).
## The player id and the inventory container stay. Success event:
##   {event_type: "character_started", player_id, character_generation,
##    position: [x, y, z], dropped_item_instance_ids: Array of String}
## Failure: unknown_player, or the reason the drop was refused; nothing
## changes then.
func start_new_character(player_id: String, profile: CharacterProfile = null) -> ActionResult:
	var state: PlayerState = _players.get(player_id, null)
	if state == null:
		return ActionResult.failure(REASON_UNKNOWN_PLAYER)
	var dropped: ActionResult = drop_all_player_items(player_id)
	if not dropped.ok:
		return dropped
	state.position = clamp_to_world(gameplay.player_spawn_position)
	_move_inputs.erase(player_id)
	state.character_generation += 1
	if profile != null:
		state.character = profile.copy()
	elif not state.has_character():
		state.character = character_rules.default_profile()
	for system: ServerSystem in _system_order:
		system.on_character_started(self, player_id)
	GameLogger.info("world", "new character started", {"world_id": world_id, "player_id": player_id, "character_generation": state.character_generation})
	return ActionResult.success({
		"event_type": EVENT_CHARACTER_STARTED,
		"player_id": player_id,
		"character_generation": state.character_generation,
		"position": [state.position.x, state.position.y, state.position.z],
		"dropped_item_instance_ids": dropped.event.get("item_instance_ids", []),
	})


## Players in the world (see is_online), sorted.
func online_player_ids() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray(_online.keys())
	result.sort()
	return result


## Players with a connection, with or without a character, sorted (P2-T9).
func connected_player_ids() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray(_connected.keys())
	result.sort()
	return result


func known_player_count() -> int:
	return _players.size()


## Stores the latest validated move intent. Older/duplicate sequences are
## ignored (unreliable channel may reorder). Returns "" or a reason code.
func set_move_input(player_id: String, sequence: int, direction: Vector2, yaw: float, now_msec: int) -> String:
	if not _online.has(player_id):
		return REASON_NOT_ONLINE
	var previous: Dictionary = _move_inputs.get(player_id, {})
	if not previous.is_empty() and sequence <= int(previous["sequence"]):
		return REASON_STALE_SEQUENCE
	_move_inputs[player_id] = {"direction": direction, "sequence": sequence, "received_msec": now_msec}
	_players[player_id].yaw = yaw
	return ""


## Advances authoritative movement of online players by `delta` seconds.
## Input older than `input_timeout_msec` counts as "stopped".
func step_movement(delta: float, now_msec: int, input_timeout_msec: int) -> void:
	for player_id: String in _move_inputs:
		var input: Dictionary = _move_inputs[player_id]
		if now_msec - int(input["received_msec"]) > input_timeout_msec:
			continue
		var multiplier: float = player_movement_multiplier(player_id)
		if multiplier <= 0.0:
			continue
		var state: PlayerState = _players[player_id]
		var next: Vector3 = MovementRules.step(state.position, input["direction"], gameplay.move_speed_mps * multiplier, delta, gameplay.world_half_extent_m)
		# P3-4a: walls and closed doors stop the step (or let it slide).
		state.position = resolve_movement(ENTITY_KIND_PLAYER, state.position, next)


## Where a straight step of a mover from `from` to `to` ends (P3-4a, docs/09
## §15.4): `to` unless a system has something in the way (walls, closed
## doors; ServerSystem.resolve_movement_step). `mover_kind` is the entity
## kind of the mover (ENTITY_KIND_PLAYER, "zombie"). Every system that moves
## an entity through the world asks this for each step and so needs to know
## nothing about structures. Each constraining system gets the answer of the
## one before it as its target. A world without such a system answers `to`.
func resolve_movement(mover_kind: String, from: Vector3, to: Vector3) -> Vector3:
	for system: ServerSystem in _movement_constraints:
		to = system.resolve_movement_step(mover_kind, from, to)
	return to


## Product of every system's movement factor for this player, clamped to
## [0, 1]. Invalid values (NaN/inf) stop the player rather than speed it up.
func player_movement_multiplier(player_id: String) -> float:
	var product: float = 1.0
	for system: ServerSystem in _system_order:
		var factor: float = system.player_movement_multiplier(player_id)
		if not is_finite(factor):
			GameLogger.error("world", "invalid movement multiplier", {"player_id": player_id, "system": system.get_system_id(), "operation": "player_movement_multiplier"})
			return 0.0
		product *= factor
	return clampf(product, 0.0, 1.0)


## "" when every system lets the player act (items, attacks), otherwise the
## first system's reason code (ServerSystem.player_action_block_reason;
## e.g. "player_dead", "player_resting").
func player_action_block_reason(player_id: String) -> String:
	for system: ServerSystem in _system_order:
		var reason: String = system.player_action_block_reason(player_id)
		if not reason.is_empty():
			return reason
	return ""


## "" when every system lets the player make an attack (P2-T11), otherwise a
## reason code: first whatever blocks every action
## (player_action_block_reason: "player_dead", "player_resting"), then what
## blocks attacks only (ServerSystem.player_attack_block_reason:
## "player_prone").
func player_attack_block_reason(player_id: String) -> String:
	var blocked: String = player_action_block_reason(player_id)
	if not blocked.is_empty():
		return blocked
	for system: ServerSystem in _system_order:
		var reason: String = system.player_attack_block_reason(player_id)
		if not reason.is_empty():
			return reason
	return ""


## How well the player can be seen (P2-T11): the product of every system's
## visibility factor, clamped to [0, 1]. An invalid factor (NaN / inf /
## negative) is logged and ignored, so a broken system never hides anybody.
func player_visibility_multiplier(player_id: String) -> float:
	var product: float = 1.0
	for system: ServerSystem in _system_order:
		product *= _valid_factor(system.player_visibility_multiplier(player_id), system, player_id, "player_visibility_multiplier")
	return clampf(product, 0.0, 1.0)


## Product of every system's footstep loudness factor (>= 0; P2-T11).
func player_footstep_loudness_multiplier(player_id: String) -> float:
	var product: float = 1.0
	for system: ServerSystem in _system_order:
		product *= _valid_factor(system.player_footstep_loudness_multiplier(player_id), system, player_id, "player_footstep_loudness_multiplier")
	return product


## Product of every system's footstep stride factor (>= 0; P2-T11).
func player_footstep_stride_multiplier(player_id: String) -> float:
	var product: float = 1.0
	for system: ServerSystem in _system_order:
		product *= _valid_factor(system.player_footstep_stride_multiplier(player_id), system, player_id, "player_footstep_stride_multiplier")
	return product


## `factor` when it is a usable multiplier (finite, >= 0), otherwise 1.0
## (no effect) and an error log naming the system.
func _valid_factor(factor: float, system: ServerSystem, player_id: String, operation: String) -> float:
	if is_finite(factor) and factor >= 0.0:
		return factor
	GameLogger.error("world", "invalid player factor ignored", {"player_id": player_id, "system": system.get_system_id(), "operation": operation})
	return 1.0


## Pickup by an online player, using the server-known position (the client
## never supplies a position). Returns the InventoryService result, or the
## reason a system blocks the player from acting (a dead character cannot
## pick anything up, P2-T4). What is picked up joins the stacks of the same
## kind the player carries (P2-T15, GameplaySettings.merge_stacks_on_pickup).
func try_pickup(player_id: String, item_instance_id: String) -> ActionResult:
	if not _online.has(player_id):
		return ActionResult.failure(REASON_NOT_ONLINE)
	var blocked: String = player_action_block_reason(player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var state: PlayerState = _players[player_id]
	return inventory.try_pickup(state.inventory_id, item_instance_id, state.position)


## Drop by an online player (P2-T2): the item goes to the world where the
## server knows the player to be. The client supplies neither a position nor
## an owner, only the item and how many units of it (P2-T15:
## InventoryService.WHOLE_STACK, the default, or 1..the stack; a part of a
## stack becomes a new item lying in the world). This and a pickup by
## somebody else is how items travel between players (docs/00 ADR-021): no
## rule puts an item into another player's inventory. Returns the
## InventoryService result, or the reason a system blocks the player from
## acting.
func try_drop_item(player_id: String, item_instance_id: String, quantity: int = InventoryService.WHOLE_STACK) -> ActionResult:
	if not _online.has(player_id):
		return ActionResult.failure(REASON_NOT_ONLINE)
	var blocked: String = player_action_block_reason(player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var state: PlayerState = _players[player_id]
	var position: Vector3 = clamp_to_world(state.position)
	return inventory.drop_item(state.inventory_id, item_instance_id, cell_id_at(position), position, quantity)


## Server rule entry (P2-T2, e.g. death): everything a known player carries
## goes to the world at the player's position. The player may be offline.
func drop_all_player_items(player_id: String) -> ActionResult:
	var state: PlayerState = _players.get(player_id, null)
	if state == null:
		return ActionResult.failure(REASON_UNKNOWN_PLAYER)
	var position: Vector3 = clamp_to_world(state.position)
	return inventory.drop_all_items(state.inventory_id, cell_id_at(position), position)


## Server rule entry (P2-T2, e.g. eating): `quantity` of an item a known
## player carries leaves the game. The player may be offline.
func remove_player_item(player_id: String, item_instance_id: String, quantity: int) -> ActionResult:
	var state: PlayerState = _players.get(player_id, null)
	if state == null:
		return ActionResult.failure(REASON_UNKNOWN_PLAYER)
	return inventory.remove_item(state.inventory_id, item_instance_id, quantity)


## True when a system knows the player's current character to be dead
## (ServerSystem.player_is_dead; P2-T14). False for a player nobody knows.
func is_player_dead(player_id: String) -> bool:
	for system: ServerSystem in _system_order:
		if system.player_is_dead(player_id):
			return true
	return false


## Clamps a position into the playable square.
func clamp_to_world(position: Vector3) -> Vector3:
	var limit: float = gameplay.world_half_extent_m
	return Vector3(clampf(position.x, -limit, limit), position.y, clampf(position.z, -limit, limit))


## Save documents of the whole world:
##   {"world_state": Dictionary, "players": {player_id: Dictionary},
##    "cells": {cell_id: WorldCellDocument}, "replace_cells": bool}
## World cells (P3-1, docs/09 §15.1): the world items and zombies of a cell
## are either in that cell's document or in the world document, never in
## both (saves_cell_document). In a saved world (WorldPersistence) "cells"
## are the cells that are in memory; the files of the other cells are
## already in the save. With a memory cell store "cells" are the released
## cells and the world document holds everything that is in memory. Without
## a cell store "cells" is empty. "replace_cells": every other saved cell
## file is out of date (SaveService.save_world).
func to_documents() -> Dictionary:
	# First: it may bring cells (and their saved entities) into memory.
	var cell_documents: Dictionary = _cells.cell_documents_for_save(self) if _cells != null else {}
	var keys: Dictionary = {}
	for key: String in _player_ids_by_key:
		keys[key] = _player_ids_by_key[key]
	var world_state: Dictionary = {
		"schema_version": SCHEMA_VERSION,
		"world_id": world_id,
		"next_entity_sequence": ids.get_next_sequence(),
		"tombstones": Array(registry.tombstones()),
		"player_keys": keys,
		"inventory": inventory.to_snapshot(saves_cell_document),
		KEY_WORLD_TIME: clock.world_time_sec,
		KEY_ACTION_TIME: clock.action_time_sec,
	}
	var system_docs: Dictionary = {}
	for system: ServerSystem in _system_order:
		var document: Dictionary = system.to_world_document()
		if not document.is_empty():
			system_docs[system.get_system_id()] = document
	world_state[KEY_SYSTEMS] = system_docs
	var players: Dictionary = {}
	for player_id: String in _players:
		var player_doc: Dictionary = _players[player_id].to_dict()
		var fragments: Dictionary = {}
		for system: ServerSystem in _system_order:
			var fragment: Dictionary = system.to_player_fragment(player_id)
			if not fragment.is_empty():
				fragments[system.get_system_id()] = fragment
		player_doc[KEY_SYSTEMS] = fragments
		players[player_id] = player_doc
	return {"world_state": world_state, "players": players, "cells": cell_documents, "replace_cells": _cells != null and _cells.replaces_saved_cells()}


## Restores from save documents into this (fresh) world. Returns errors;
## when non-empty the world must be discarded. `cells` are the cell
## documents to_documents() returned for a world with a memory cell store;
## a saved world leaves it empty (its cell files are read when a cell is
## loaded).
func restore_documents(world_state: Dictionary, players: Dictionary, cells: Dictionary = {}) -> PackedStringArray:
	var errors: PackedStringArray = []
	if str(world_state.get("world_id", "")) != world_id:
		errors.append("world_id mismatch")
		return errors
	var tombstones: PackedStringArray = []
	for entry: Variant in world_state.get("tombstones", []):
		tombstones.append(str(entry))
	registry.restore_tombstones(tombstones)
	var inventory_snapshot: Variant = world_state.get("inventory", {})
	if typeof(inventory_snapshot) != TYPE_DICTIONARY:
		errors.append("inventory must be an object")
		return errors
	errors.append_array(inventory.restore_snapshot(inventory_snapshot as Dictionary))
	# P3-1: a world item of the world document lies in the cell of its
	# position, whatever cell id was saved with it (saves written before
	# cells existed put "cell_0_0" on every item).
	inventory.reassign_world_item_cells(cell_id_at)
	for raw: Variant in players.values():
		if typeof(raw) != TYPE_DICTIONARY:
			errors.append("player document is not an object")
			continue
		var state: PlayerState = PlayerState.from_dict(raw as Dictionary)
		if state == null:
			errors.append("invalid player document")
			continue
		if _players.has(state.player_id):
			errors.append("duplicate player " + state.player_id)
			continue
		if not inventory.has_inventory(state.inventory_id):
			errors.append("player %s references missing inventory" % state.player_id)
		# Appearance data may have changed since the save was written.
		if state.has_character():
			state.character = character_rules.restore_profile(state.character)
		_players[state.player_id] = state
		_player_ids_by_key[state.player_key] = state.player_id
		registry.register(state.player_id, ENTITY_KIND_PLAYER)
		ids.reserve_existing_id(state.player_id)
	var keys: Variant = world_state.get("player_keys", {})
	if typeof(keys) == TYPE_DICTIONARY:
		for key: Variant in (keys as Dictionary):
			if _player_ids_by_key.get(str(key), "") != str((keys as Dictionary)[key]):
				errors.append("player_keys entry %s does not match a player file" % str(key))
	var next_sequence: Variant = world_state.get("next_entity_sequence", EntityIdGenerator.FIRST_SEQUENCE)
	if ItemInstance.is_integer_value(next_sequence) and int(next_sequence) >= ids.get_next_sequence():
		ids.restore_next_sequence(int(next_sequence))
	var world_time: Variant = world_state.get(KEY_WORLD_TIME, 0.0)
	if not (typeof(world_time) == TYPE_FLOAT or typeof(world_time) == TYPE_INT) or clock.restore(float(world_time)) != OK:
		errors.append("invalid world_time_sec")
	# No default: saved action-time deadlines (zombies, respawn) are only
	# valid against the clock they were written with. Older documents get
	# the key from SaveMigrations.world_v2_to_v3.
	var action_time: Variant = world_state.get(KEY_ACTION_TIME, null)
	if not (typeof(action_time) == TYPE_FLOAT or typeof(action_time) == TYPE_INT) or clock.restore_action_time(float(action_time)) != OK:
		errors.append("invalid action_time_sec")
	errors.append_array(_restore_systems(world_state, players))
	if _cells != null:
		errors.append_array(_cells.restore_cell_documents(self, cells))
	elif not cells.is_empty():
		errors.append("cell documents for a world without a cell service")
	return errors


func _restore_systems(world_state: Dictionary, players: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	var system_docs: Variant = world_state.get(KEY_SYSTEMS, {})
	if typeof(system_docs) != TYPE_DICTIONARY:
		errors.append("systems must be an object")
		return errors
	for key: Variant in (system_docs as Dictionary):
		if not _systems.has(str(key)):
			GameLogger.warning("world", "save has data for an unregistered system (ignored)", {"world_id": world_id, "system": str(key), "operation": "restore_world"})
	for system: ServerSystem in _system_order:
		var document: Variant = (system_docs as Dictionary).get(system.get_system_id(), null)
		if document == null:
			continue  # system added after this save was written: keeps its defaults
		if typeof(document) != TYPE_DICTIONARY:
			errors.append("system document %s is not an object" % system.get_system_id())
			continue
		errors.append_array(system.restore_world_document(document as Dictionary))
	for raw: Variant in players.values():
		if typeof(raw) != TYPE_DICTIONARY:
			continue  # already reported above
		var player_id: String = str((raw as Dictionary).get("player_id", ""))
		var fragments: Variant = (raw as Dictionary).get(KEY_SYSTEMS, {})
		if typeof(fragments) != TYPE_DICTIONARY:
			errors.append("player %s systems must be an object" % player_id)
			continue
		for system: ServerSystem in _system_order:
			var fragment: Variant = (fragments as Dictionary).get(system.get_system_id(), null)
			if fragment == null:
				continue
			if typeof(fragment) != TYPE_DICTIONARY:
				errors.append("player %s fragment %s is not an object" % [player_id, system.get_system_id()])
				continue
			errors.append_array(system.restore_player_fragment(player_id, fragment as Dictionary))
	return errors


## Puts a connected player with a character into the world.
func _enter_world(state: PlayerState) -> void:
	_online[state.player_id] = true
	GameLogger.info("world", "player online", {"world_id": world_id, "player_id": state.player_id})
	for system: ServerSystem in _system_order:
		system.on_player_online(self, state.player_id)


## True when the current character of another known player has
## `character_name` (compared without case).
func _is_name_taken(character_name: String, own_player_id: String) -> bool:
	var wanted: String = character_name.to_lower()
	for other_id: String in _players:
		if other_id == own_player_id:
			continue
		var other: PlayerState = _players[other_id]
		if other.has_character() and other.character.name.to_lower() == wanted:
			return true
	return false


func _create_player(player_key: String) -> PlayerState:
	var inventory_id: String = inventory.create_inventory(gameplay.inventory_slot_capacity)
	if inventory_id.is_empty():
		return null
	var state: PlayerState = PlayerState.new()
	state.player_id = ids.next_id(ENTITY_KIND_PLAYER)
	state.player_key = player_key
	state.position = clamp_to_world(gameplay.player_spawn_position)
	state.inventory_id = inventory_id
	if registry.register(state.player_id, ENTITY_KIND_PLAYER) != OK:
		return null
	_players[state.player_id] = state
	_player_ids_by_key[player_key] = state.player_id
	GameLogger.info("world", "player created", {"world_id": world_id, "player_id": state.player_id, "inventory_id": inventory_id})
	return state


# ------------------------------------------------------------ world cells
# P3-1 (docs/03 §3, docs/00 ADR-023, docs/09 §15.1). The world is cut into
# square cells. Every world entity that is in memory is in `cell_index`
# under the id of its cell; a cell's entities can be simulated (ACTIVE), kept
# in memory without being simulated (PRELOADED) or saved and released
# (UNLOADED). WorldCellService decides which, from the server positions of
# the online players. Systems ask the functions below and never do cell math
# of their own. Players are not part of a cell: they never leave memory.

## Id of the cell a world position is in.
func cell_id_at(position: Vector3) -> String:
	return cell_grid.cell_id_at(position)


## Cell coordinates of a world position: cheap to compare, for callers that
## check every tick whether an entity crossed a border (then: cell_id_of).
func cell_coords_at(position: Vector3) -> Vector2i:
	return cell_grid.cell_of(position)


func cell_id_of(cell: Vector2i) -> String:
	return WorldCellGrid.id_of(cell)


## True when the entities of this cell are simulated now (AI, senses,
## attacks). A world without a cell service simulates everything.
func is_cell_simulated(cell_id: String) -> bool:
	return _cells == null or _cells.is_simulated(cell_id)


## True when an entity at this position is simulated now.
func is_simulated_at(position: Vector3) -> bool:
	return _cells == null or _cells.is_simulated(cell_id_at(position))


## True when the entities of this cell are in memory, so an entity may be
## in it or move into it. A world without a cell service keeps everything in
## memory.
func is_cell_loaded(cell_id: String) -> bool:
	return _cells == null or _cells.is_loaded(cell_id)


## True when a save of the world made now writes the entities of this cell
## into the cell's own document (then they are not in the world document).
## Systems ask this in to_world_document().
func saves_cell_document(cell_id: String) -> bool:
	return _cells != null and _cells.saves_cell_document(cell_id)


## Brings the entities of cell documents that were written for ANOTHER
## cell grid into memory ({cell_id: document}) and gives every world item
## the cell of its position (zombies are indexed by position anyway). The
## caller then makes sure those documents are not read again. Returns errors.
func repartition_from(cell_documents: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	var cell_ids: PackedStringArray = []
	for key: Variant in cell_documents:
		cell_ids.append(str(key))
	cell_ids.sort()
	for cell_id: String in cell_ids:
		if typeof(cell_documents[cell_id]) != TYPE_DICTIONARY:
			errors.append("cell %s: document is not an object" % cell_id)
			continue
		errors.append_array(restore_cell_document(cell_id, cell_documents[cell_id] as Dictionary))
	inventory.reassign_world_item_cells(cell_id_at)
	return errors


## Save data of everything that lies in one cell (WorldCellDocument): the
## world items and what every system keeps there.
func cell_document(cell_id: String) -> Dictionary:
	var system_docs: Dictionary = {}
	for system: ServerSystem in _system_order:
		var document: Dictionary = system.to_cell_document(cell_id)
		if not document.is_empty():
			system_docs[system.get_system_id()] = document
	return WorldCellDocument.create(cell_id, inventory.cell_snapshot(cell_id), system_docs)


## Brings the saved entities of a cell back into memory ({} = nothing was
## saved for it). Returns errors; when non-empty the cell is not loaded.
## Each part (world items, each system) validates before it changes
## anything; a part restored before another part failed stays in memory and
## is skipped when the cell is loaded again, so nothing is lost or doubled.
func restore_cell_document(cell_id: String, document: Dictionary) -> PackedStringArray:
	if document.is_empty():
		return PackedStringArray()
	var errors: PackedStringArray = WorldCellDocument.validate(document, cell_id)
	if not errors.is_empty():
		return errors
	var world_items: Dictionary = document[WorldCellDocument.KEY_WORLD_ITEMS]
	if not world_items.is_empty():
		errors = inventory.restore_cell_snapshot(cell_id, world_items)
		if not errors.is_empty():
			return errors
	var system_docs: Dictionary = document[WorldCellDocument.KEY_SYSTEMS]
	for key: Variant in system_docs:
		if not _systems.has(str(key)):
			GameLogger.warning("world", "cell has data for an unregistered system (ignored)", {"world_id": world_id, "cell_id": cell_id, "system": str(key), "operation": "restore_cell"})
	for system: ServerSystem in _system_order:
		var system_doc: Variant = system_docs.get(system.get_system_id(), null)
		if system_doc == null:
			continue
		if typeof(system_doc) != TYPE_DICTIONARY:
			errors.append("cell %s: system document %s is not an object" % [cell_id, system.get_system_id()])
			return errors
		errors = system.restore_cell_document(self, cell_id, system_doc as Dictionary)
		if not errors.is_empty():
			return errors
	return errors


## Takes the entities of a cell out of memory. Only WorldCellService calls
## this, after the cell was saved (docs/03 §3.2).
func release_cell(cell_id: String) -> void:
	for system: ServerSystem in _system_order:
		system.release_cell(self, cell_id)
	inventory.release_cell(cell_id)


## Tells every system that a cell became ACTIVE (`active` true) or stopped
## being ACTIVE. Only WorldCellService calls this.
func notify_cell_active(cell_id: String, active: bool) -> void:
	for system: ServerSystem in _system_order:
		if active:
			system.on_cell_activated(self, cell_id)
		else:
			system.on_cell_deactivated(self, cell_id)
