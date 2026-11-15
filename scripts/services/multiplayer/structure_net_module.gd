class_name StructureNetModule
extends NetModule
## The building intents and replication of structures (P3-4a, docs/09
## §15.4). Network only: every rule is in BuildingService. Assembled in
## ServerComposition.install_net_modules() on every peer.
##
## RPC table (channel 0 = NetworkSettings.CHANNEL_RELIABLE, reliable and
## ordered: structures are world state, and a client must see additions,
## changes and removals in the server's order):
##   client -> server  _rpc_request_place(request_id:int, definition_id:String,
##                                        x:int, z:int, rotation:int)        reliable, ch0
##   client -> server  _rpc_request_demolish(request_id:int, structure_id:String)
##                                                                           reliable, ch0
##   client -> server  _rpc_request_door(request_id:int, structure_id:String,
##                                       open:bool)                          reliable, ch0
##   server -> owner   _rpc_structure_result(request_id:int, ok:bool,
##                                           reason:String, structure_id:String)
##                                                                           reliable, ch0
##   server -> clients _rpc_structure_rows(rows:Array)                       reliable, ch0
##       structures that were added or changed (ClientStructureState rows)
##   server -> clients _rpc_structures_removed(structure_ids:Array)          reliable, ch0
## Initial state: join fragment {schema_version, structures: [row, ...]}
## with every structure the server has in memory.
##
## Intents. A client names what it wants: a definition, a tile and a
## rotation (whole numbers: a request cannot be off the grid); a structure
## id; the door state it wants (not a toggle). There is no player argument
## (the actor is the player of the sending peer) and no position, owner,
## cost or result argument: where the player is, whether it may build
## there and what it costs is server state. Server checks, in order: joined
## (`not_joined`), argument types (`bad_type`), request id >= 0
## (`bad_sequence`), the shape of the ids and numbers (`bad_definition_id`,
## `bad_structure_id`, `out_of_bounds`, `bad_rotation`), the request rate of
## that intent (`rate_limited`), then the rule (BuildingService: range,
## overlap, permission, state, ...). Every refusal is counted
## (NetworkService.rejected_intent_count) and changes nothing. The result
## goes to the requester only; `reason` is "" exactly when ok, and
## `structure_id` is the structure that was placed, demolished or changed
## ("" on a refusal).
##
## Replication. A structure is something anybody can see, so every joined
## peer gets every structure in the server's memory: no interest management
## yet (docs/15 P3-112; per-client scope is P3-2). BuildingService records
## events; this module drains them every server tick, and at once when a
## request was accepted, so that everybody learns of a change before the
## requester gets its answer (same ordered channel). This module is the
## only consumer of BuildingService.drain_events().
##
## World cells (docs/09 §15.1): when a cell comes into memory its
## structures are sent as rows, when it is about to leave memory as
## removals. Nothing was built or demolished in the world then, so those are
## not BuildingService events.
##
## Client surface (presentation, P3-4b): request_place(), request_demolish(),
## request_door(), the `structure_result` signal and the mirror
## `client_state`. The mirror has no authority.

## Client: answer to one of this client's own building requests.
signal structure_result(request_id: int, ok: bool, reason: String, structure_id: String)

const MODULE_NAME: String = "StructureNet"
## Intent names in rejection logs.
const INTENT_PLACE: String = "structure_place"
const INTENT_DEMOLISH: String = "structure_demolish"
const INTENT_DOOR: String = "structure_door"
const REASON_BAD_DEFINITION_ID: String = "bad_definition_id"
const REASON_BAD_STRUCTURE_ID: String = "bad_structure_id"
const SAVE_REASON_PLACED: String = "structure_placed"
const SAVE_REASON_REMOVED: String = "structure_removed"
const SAVE_REASON_DOOR: String = "structure_door"
## Returned by the request functions when nothing was sent.
const NO_REQUEST: int = 0
## Longest reason code a client accepts in a result.
const REASON_MAX_LENGTH: int = 64
## Longest definition id the server looks at.
const DEFINITION_ID_MAX_LENGTH: int = 64

## Client: the mirror. Stays empty on the server (which uses it to hold its
## own rows to the rule its clients apply).
var client_state: ClientStructureState
## Diagnostics.
var sent_row_count: int = 0
var sent_removal_count: int = 0
var unsendable_row_count: int = 0
## Client: results from the server that failed validation.
var rejected_payload_count: int = 0

var _settings: StructureNetSettings
# --- server state ---
var _world: ServerWorld = null
var _building: BuildingService = null
var _cells: WorldCellService = null
var _place_limiter: RateLimiter = null
var _demolish_limiter: RateLimiter = null
var _door_limiter: RateLimiter = null
# --- client state ---
var _last_request_id: int = NO_REQUEST


func _init(settings: StructureNetSettings = null, catalog: StructureCatalog = null) -> void:
	name = MODULE_NAME
	_settings = settings if settings != null else StructureNetSettings.new()
	client_state = ClientStructureState.new(_settings, catalog)


# ------------------------------------------------------------ pure rules

## "" when the arguments of a placement request are usable, otherwise a
## reason code. Types first, so wrongly typed input never reaches a
## conversion.
static func validate_place_request(request_id: Variant, definition_id: Variant, x: Variant, z: Variant, rotation: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(definition_id) != TYPE_STRING or typeof(x) != TYPE_INT or typeof(z) != TYPE_INT or typeof(rotation) != TYPE_INT:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	var definition: String = definition_id
	if definition.is_empty() or definition.length() > DEFINITION_ID_MAX_LENGTH or not ItemInstance.is_valid_definition_id(definition):
		return REASON_BAD_DEFINITION_ID
	# Compared as 64-bit numbers: a Vector2i would wrap a huge value around.
	for coordinate: int in [int(x), int(z)]:
		if coordinate < -StructureGrid.MAX_TILE_COORD or coordinate > StructureGrid.MAX_TILE_COORD:
			return BuildingService.REASON_OUT_OF_BOUNDS
	if not StructureGrid.is_valid_rotation(int(rotation)):
		return BuildingService.REASON_BAD_ROTATION
	return ""


## "" when the arguments of a demolish request are usable.
static func validate_demolish_request(request_id: Variant, structure_id: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(structure_id) != TYPE_STRING:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	var id: String = structure_id
	if id.length() > ClientStructureState.MAX_ID_LENGTH or not StructureInstance.is_valid_structure_id(id):
		return REASON_BAD_STRUCTURE_ID
	return ""


## "" when the arguments of a door request are usable.
static func validate_door_request(request_id: Variant, structure_id: Variant, open: Variant) -> String:
	if typeof(open) != TYPE_BOOL:
		return IntentValidator.REASON_BAD_TYPE
	return validate_demolish_request(request_id, structure_id)


# ------------------------------------------------------------ NetModule hooks

func on_server_started(world: ServerWorld) -> void:
	_building = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	if _building == null:
		GameLogger.info("net", "world has no building system, structure replication is off", {"world_id": world.world_id, "module": MODULE_NAME})
		return
	_world = world
	_place_limiter = RateLimiter.new(_settings.place_intent_rate_per_sec, _settings.place_intent_burst)
	_demolish_limiter = RateLimiter.new(_settings.demolish_intent_rate_per_sec, _settings.demolish_intent_burst)
	_door_limiter = RateLimiter.new(_settings.door_intent_rate_per_sec, _settings.door_intent_burst)
	_cells = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	if _cells != null:
		_cells.cell_loaded.connect(_on_cell_loaded)
		_cells.cell_unloading.connect(_on_cell_unloading)


func _exit_tree() -> void:
	if _cells == null:
		return
	if _cells.cell_loaded.is_connected(_on_cell_loaded):
		_cells.cell_loaded.disconnect(_on_cell_loaded)
	if _cells.cell_unloading.is_connected(_on_cell_unloading):
		_cells.cell_unloading.disconnect(_on_cell_unloading)


func on_player_left(peer_id: int, _player_id: String) -> void:
	for limiter: RateLimiter in [_place_limiter, _demolish_limiter, _door_limiter]:
		if limiter != null:
			limiter.forget(peer_id)


func server_physics(_delta: float) -> void:
	_flush_events()


## Every structure in memory as it is right now. Events still queued in
## BuildingService are sent to the peers that are joined already first, so
## the fragment and the stream never disagree.
func build_join_fragment(_player_id: String) -> Dictionary:
	if _building == null:
		return {}
	_flush_events()
	return {
		ClientStructureState.KEY_SCHEMA_VERSION: ClientStructureState.SCHEMA_VERSION,
		ClientStructureState.KEY_STRUCTURES: _encode_rows(_building.rows()),
	}


func apply_join_fragment(fragment: Dictionary) -> void:
	_last_request_id = NO_REQUEST
	client_state.apply_join(fragment)


# ------------------------------------------------------------ server side

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_place(request_id: Variant, definition_id: Variant, x: Variant, z: Variant, rotation: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The actor is whoever owns the sending peer, never an argument.
	var player_id: String = network.sender_player_id()
	if not _accept_request(peer_id, player_id, INTENT_PLACE, request_id, validate_place_request(request_id, definition_id, x, z, rotation), _place_limiter):
		return
	var result: ActionResult = _building.try_place(_world, player_id, str(definition_id), Vector2i(int(x), int(z)), int(rotation))
	_finish_request(peer_id, player_id, INTENT_PLACE, int(request_id), result, _settings.persist_on_place_and_demolish, SAVE_REASON_PLACED)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_demolish(request_id: Variant, structure_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = network.sender_player_id()
	if not _accept_request(peer_id, player_id, INTENT_DEMOLISH, request_id, validate_demolish_request(request_id, structure_id), _demolish_limiter):
		return
	var result: ActionResult = _building.try_demolish(_world, player_id, str(structure_id))
	_finish_request(peer_id, player_id, INTENT_DEMOLISH, int(request_id), result, _settings.persist_on_place_and_demolish, SAVE_REASON_REMOVED)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_door(request_id: Variant, structure_id: Variant, open: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = network.sender_player_id()
	if not _accept_request(peer_id, player_id, INTENT_DOOR, request_id, validate_door_request(request_id, structure_id, open), _door_limiter):
		return
	var result: ActionResult = _building.try_set_door(_world, player_id, str(structure_id), bool(open))
	_finish_request(peer_id, player_id, INTENT_DOOR, int(request_id), result, _settings.persist_on_door_change, SAVE_REASON_DOOR)


## The checks every building intent shares, before the rule: joined, the
## shape of the arguments (`shape_reason` from a validate_* function), the
## request rate, a building system. False = the request was refused (and
## answered, when it carried a usable request id).
func _accept_request(peer_id: int, player_id: String, intent: String, request_id: Variant, shape_reason: String, limiter: RateLimiter) -> bool:
	if player_id.is_empty():
		network.reject_intent(peer_id, intent, NetworkService.NOT_JOINED)
		return false
	if not shape_reason.is_empty():
		network.reject_intent(peer_id, intent, shape_reason, player_id)
		if typeof(request_id) == TYPE_INT and int(request_id) >= 0:
			_send_result(peer_id, int(request_id), false, shape_reason, "")
		return false
	if _building == null:
		network.reject_intent(peer_id, intent, BuildingService.REASON_UNAVAILABLE, player_id)
		_send_result(peer_id, int(request_id), false, BuildingService.REASON_UNAVAILABLE, "")
		return false
	if not limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, intent, NetworkService.RATE_LIMITED, player_id)
		_send_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED, "")
		return false
	return true


## Answers a request the rule decided: a refusal is counted and answered;
## an accepted change is replicated first, then answered, then saved.
func _finish_request(peer_id: int, player_id: String, intent: String, request_id: int, result: ActionResult, save_now: bool, save_reason: String) -> void:
	if not result.ok:
		# Refusals by game state are normal play: counted, not logged as warnings.
		network.count_rejection(result.reason)
		_send_result(peer_id, request_id, false, result.reason, "")
		return
	var structure_id: String = str(result.event.get(BuildingService.KEY_STRUCTURE_ID, ""))
	_flush_events()
	_send_result(peer_id, request_id, true, "", structure_id)
	GameLogger.info("net", "building request accepted", {"peer_id": peer_id, "player_id": player_id, "intent": intent, "request_id": request_id, "entity_id": structure_id})
	if save_now:
		network.persist(save_reason)


func _send_result(peer_id: int, request_id: int, ok: bool, reason: String, structure_id: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_structure_result.rpc_id(peer_id, request_id, ok, reason, structure_id)


## Sends what BuildingService recorded since the last call to every joined
## peer, in the order it happened.
func _flush_events() -> void:
	if _building == null or network == null or not network.is_server():
		return
	var events: Array[Dictionary] = _building.drain_events()
	if events.is_empty():
		return
	var rows: Array = []
	var removed: Array = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == BuildingService.EVENT_REMOVED:
			_broadcast_rows(rows)
			rows = []
			removed.append(str(event.get(BuildingService.KEY_STRUCTURE_ID, "")))
			continue
		_broadcast_removed(removed)
		removed = []
		var row: Array = _checked_row(event, "flush_events")
		if not row.is_empty():
			rows.append(row)
	_broadcast_rows(rows)
	_broadcast_removed(removed)


## P3-1: the structures of a cell that came into memory appear on the
## clients.
func _on_cell_loaded(cell_id: String) -> void:
	if _building == null or network == null or not network.is_server():
		return
	_flush_events()
	_broadcast_rows(_encode_rows(_building.rows_in_cell(_world, cell_id)))


## P3-1: the structures of a cell that is about to leave memory disappear
## from the clients.
func _on_cell_unloading(cell_id: String) -> void:
	if _building == null or network == null or not network.is_server():
		return
	_flush_events()
	_broadcast_removed(Array(_building.structure_ids_in_cell(_world, cell_id)))


func _encode_rows(public_rows: Array[Dictionary]) -> Array:
	var rows: Array = []
	for public_row: Dictionary in public_rows:
		var row: Array = _checked_row(public_row, "encode_rows")
		if not row.is_empty():
			rows.append(row)
	return rows


## The wire row of a public row, or [] (logged, counted) when it would not
## pass the check the clients apply.
func _checked_row(public_row: Dictionary, operation: String) -> Array:
	var row: Array = ClientStructureState.encode_row(public_row)
	if row.is_empty() or not client_state.is_valid_row(row):
		unsendable_row_count += 1
		GameLogger.error("net", "structure does not fit the wire format", {"entity_id": str(public_row.get(BuildingService.KEY_STRUCTURE_ID, "")), "module": MODULE_NAME, "operation": operation})
		return []
	return row


func _broadcast_rows(rows: Array) -> void:
	if rows.is_empty():
		return
	var peers: PackedInt32Array = network.joined_peers()
	var offset: int = 0
	while offset < rows.size():
		var message: Array = rows.slice(offset, offset + _settings.rows_per_message)
		for peer_id: int in peers:
			if network.can_send_to(peer_id):
				_rpc_structure_rows.rpc_id(peer_id, message)
		offset += message.size()
		sent_row_count += message.size()


func _broadcast_removed(structure_ids: Array) -> void:
	if structure_ids.is_empty():
		return
	var peers: PackedInt32Array = network.joined_peers()
	var offset: int = 0
	while offset < structure_ids.size():
		var message: Array = structure_ids.slice(offset, offset + _settings.removals_per_message)
		for peer_id: int in peers:
			if network.can_send_to(peer_id):
				_rpc_structures_removed.rpc_id(peer_id, message)
		offset += message.size()
		sent_removal_count += message.size()


# ------------------------------------------------------------ client side

## Asks the server to place a structure of `definition_id` on `tile` with
## `rotation` (quarter turns, StructureGrid). Returns the request id the
## `structure_result` signal will carry, or NO_REQUEST when nothing was sent
## (not a joined client). Nothing is decided here.
func request_place(definition_id: String, tile: Vector2i, rotation: int) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_place_request(_last_request_id, definition_id, tile.x, tile.y, rotation)
	return _last_request_id


## Asks the server to demolish a structure.
func request_demolish(structure_id: String) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_demolish_request(_last_request_id, structure_id)
	return _last_request_id


## Asks the server to open (`open` true) or close a door.
func request_door(structure_id: String, open: bool) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_door_request(_last_request_id, structure_id, open)
	return _last_request_id


## Send arbitrary requests without any client-side check (tests: malformed
## or premature input through the real RPC path).
func send_raw_place_request(request_id: Variant, definition_id: Variant, x: Variant, z: Variant, rotation: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_place.rpc_id(NetworkService.SERVER_PEER_ID, request_id, definition_id, x, z, rotation)


func send_raw_demolish_request(request_id: Variant, structure_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_demolish.rpc_id(NetworkService.SERVER_PEER_ID, request_id, structure_id)


func send_raw_door_request(request_id: Variant, structure_id: Variant, open: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_door.rpc_id(NetworkService.SERVER_PEER_ID, request_id, structure_id, open)


func _can_request() -> bool:
	return network != null and network.is_client() and not network.client_state.local_player_id.is_empty()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_structure_result(request_id: Variant, ok: Variant, reason: Variant, structure_id: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if typeof(request_id) != TYPE_INT or typeof(ok) != TYPE_BOOL or typeof(reason) != TYPE_STRING or typeof(structure_id) != TYPE_STRING:
		_reject_result()
		return
	var reason_code: String = reason
	var id: String = structure_id
	# "" exactly when the request was accepted; a structure exactly then.
	if int(request_id) < 0 or reason_code.length() > REASON_MAX_LENGTH or bool(ok) != reason_code.is_empty() or bool(ok) == id.is_empty():
		_reject_result()
		return
	if not id.is_empty() and (id.length() > ClientStructureState.MAX_ID_LENGTH or not StructureInstance.is_valid_structure_id(id)):
		_reject_result()
		return
	structure_result.emit(int(request_id), bool(ok), reason_code, id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_structure_rows(rows: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	client_state.apply_rows(rows)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_structures_removed(structure_ids: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	client_state.apply_removed(structure_ids)


func _reject_result() -> void:
	rejected_payload_count += 1
	GameLogger.warning("structure_net", "structure result dropped", {"module": MODULE_NAME, "operation": "apply_payload"})
