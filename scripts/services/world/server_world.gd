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

const SCHEMA_VERSION: int = 3
const KEY_SYSTEMS: String = "systems"
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


func _init(id: String, gameplay_settings: GameplaySettings, catalog: ItemCatalog) -> void:
	world_id = id
	gameplay = gameplay_settings
	inventory = InventoryService.new(catalog, ids, registry, gameplay.pickup_range_m, gameplay.world_half_extent_m)


## Populates a brand-new world from the development seed.
func seed_new_world(seed: DevWorldSeed) -> Error:
	var errors: PackedStringArray = seed.validate()
	if not errors.is_empty():
		GameLogger.error("world", "invalid world seed", {"world_id": world_id, "errors": "; ".join(errors), "operation": "seed_world"})
		return ERR_INVALID_DATA
	for index: int in range(seed.item_definition_ids.size()):
		var item_id: String = inventory.spawn_world_item(seed.item_definition_ids[index], seed.quantity_at(index), DevWorldSeed.DEV_CELL_ID, seed.item_positions[index])
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
		state.position = MovementRules.step(state.position, input["direction"], gameplay.move_speed_mps * multiplier, delta, gameplay.world_half_extent_m)


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


## Pickup by an online player, using the server-known position (the client
## never supplies a position). Returns the InventoryService result, or the
## reason a system blocks the player from acting (a dead character cannot
## pick anything up, P2-T4).
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
## an owner. Returns the InventoryService result, or the reason a system
## blocks the player from acting.
func try_drop_item(player_id: String, item_instance_id: String) -> ActionResult:
	if not _online.has(player_id):
		return ActionResult.failure(REASON_NOT_ONLINE)
	var blocked: String = player_action_block_reason(player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var state: PlayerState = _players[player_id]
	return inventory.drop_item(state.inventory_id, item_instance_id, DevWorldSeed.DEV_CELL_ID, clamp_to_world(state.position))


## Server rule entry (P2-T2, e.g. death): everything a known player carries
## goes to the world at the player's position. The player may be offline.
func drop_all_player_items(player_id: String) -> ActionResult:
	var state: PlayerState = _players.get(player_id, null)
	if state == null:
		return ActionResult.failure(REASON_UNKNOWN_PLAYER)
	return inventory.drop_all_items(state.inventory_id, DevWorldSeed.DEV_CELL_ID, clamp_to_world(state.position))


## Server rule entry (P2-T2, e.g. eating): `quantity` of an item a known
## player carries leaves the game. The player may be offline.
func remove_player_item(player_id: String, item_instance_id: String, quantity: int) -> ActionResult:
	var state: PlayerState = _players.get(player_id, null)
	if state == null:
		return ActionResult.failure(REASON_UNKNOWN_PLAYER)
	return inventory.remove_item(state.inventory_id, item_instance_id, quantity)


## Clamps a position into the playable square.
func clamp_to_world(position: Vector3) -> Vector3:
	var limit: float = gameplay.world_half_extent_m
	return Vector3(clampf(position.x, -limit, limit), position.y, clampf(position.z, -limit, limit))


## Save documents: {"world_state": Dictionary, "players": {player_id: Dictionary}}.
func to_documents() -> Dictionary:
	var keys: Dictionary = {}
	for key: String in _player_ids_by_key:
		keys[key] = _player_ids_by_key[key]
	var world_state: Dictionary = {
		"schema_version": SCHEMA_VERSION,
		"world_id": world_id,
		"next_entity_sequence": ids.get_next_sequence(),
		"tombstones": Array(registry.tombstones()),
		"player_keys": keys,
		"inventory": inventory.to_snapshot(),
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
	return {"world_state": world_state, "players": players}


## Restores from save documents into this (fresh) world. Returns errors;
## when non-empty the world must be discarded.
func restore_documents(world_state: Dictionary, players: Dictionary) -> PackedStringArray:
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
