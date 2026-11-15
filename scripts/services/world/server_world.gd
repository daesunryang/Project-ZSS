class_name ServerWorld
extends RefCounted
## Authoritative world state and rules on the server (docs/08 §3).
##
## Owns: entity ids, registry, inventory, all known players and the
## player_key -> player_id map. No networking and no file I/O here: the
## NetworkService calls in with validated intents, WorldPersistence turns
## this into save documents. Fully testable without nodes.

const SCHEMA_VERSION: int = 1
const ENTITY_KIND_PLAYER: String = "player"
const REASON_NOT_ONLINE: String = "not_online"
const REASON_STALE_SEQUENCE: String = "stale_sequence"

var world_id: String
var gameplay: GameplaySettings
var ids: EntityIdGenerator = EntityIdGenerator.new()
var registry: EntityRegistry = EntityRegistry.new()
var inventory: InventoryService

var _players: Dictionary[String, PlayerState] = {}
var _player_ids_by_key: Dictionary[String, String] = {}
var _online: Dictionary[String, bool] = {}
## player_id -> {"direction": Vector2, "sequence": int, "received_msec": int}
var _move_inputs: Dictionary[String, Dictionary] = {}


func _init(id: String, gameplay_settings: GameplaySettings, catalog: ItemCatalog) -> void:
	world_id = id
	gameplay = gameplay_settings
	inventory = InventoryService.new(catalog, ids, registry, gameplay.pickup_range_m)


## Populates a brand-new world from the development seed.
func seed_new_world(seed: DevWorldSeed) -> Error:
	var errors: PackedStringArray = seed.validate()
	if not errors.is_empty():
		GameLogger.error("world", "invalid world seed", {"world_id": world_id, "errors": "; ".join(errors), "operation": "seed_world"})
		return ERR_INVALID_DATA
	for index: int in range(seed.item_definition_ids.size()):
		var item_id: String = inventory.spawn_world_item(seed.item_definition_ids[index], 1, DevWorldSeed.DEV_CELL_ID, seed.item_positions[index])
		if item_id.is_empty():
			return ERR_INVALID_DATA
	GameLogger.info("world", "new world seeded", {"world_id": world_id, "items": seed.item_definition_ids.size()})
	return OK


## Brings a player online: the existing player for `player_key`, or a new one.
## Returns null if the key is already online or creation fails.
func join(player_key: String) -> PlayerState:
	var player_id: String = _player_ids_by_key.get(player_key, "")
	if not player_id.is_empty() and _online.has(player_id):
		GameLogger.warning("world", "player key already online", {"world_id": world_id, "player_id": player_id, "operation": "join"})
		return null
	var state: PlayerState = null
	if player_id.is_empty():
		state = _create_player(player_key)
		if state == null:
			return null
	else:
		state = _players[player_id]
	_online[state.player_id] = true
	GameLogger.info("world", "player online", {"world_id": world_id, "player_id": state.player_id})
	return state


## Takes a player offline (state is kept for saving and reconnect).
func leave(player_id: String) -> void:
	_move_inputs.erase(player_id)
	if _online.erase(player_id):
		GameLogger.info("world", "player offline", {"world_id": world_id, "player_id": player_id})


func is_online(player_id: String) -> bool:
	return _online.has(player_id)


func get_player(player_id: String) -> PlayerState:
	return _players.get(player_id, null)


func online_player_ids() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray(_online.keys())
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
		var state: PlayerState = _players[player_id]
		state.position = MovementRules.step(state.position, input["direction"], gameplay.move_speed_mps, delta, gameplay.world_half_extent_m)


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
	}
	var players: Dictionary = {}
	for player_id: String in _players:
		players[player_id] = _players[player_id].to_dict()
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
	return errors


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
