class_name StructureNetModule
extends NetModule
## The building intents and replication of structures (P3-4a, docs/09
## §15.4) and of their construction (P3-5, docs/09 §15.5). Network only:
## every rule is in BuildingService. Assembled in
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
## P3-5:
##   client -> server  _rpc_request_deliver(request_id:int, structure_id:String,
##                                          item_instance_id:String, quantity:int)
##                                                                           reliable, ch0
##   client -> server  _rpc_request_work(request_id:int, structure_id:String,
##                                       working:bool)                       reliable, ch0
##   client -> server  _rpc_request_cancel(request_id:int, structure_id:String)
##                                                                           reliable, ch0
##   server -> clients _rpc_work_changed(player_id:String, structure_id:String,
##                                       working:bool, reason:String)        reliable, ch0
## Every request is answered with _rpc_structure_result.
## Initial state: join fragment {schema_version, structures: [row, ...],
## workers: [[player_id, structure_id], ...]} with the structures of the
## joining peer's cells and the players working on them.
##
## Construction (P3-5). Deliver: the client names the structure, one of its
## carried stacks ("" = whatever it carries that is needed) and how many
## units at most (0 = as many as are needed). Work: the structure and the
## state it wants (true = work on it, false = stop working on it). Cancel:
## the structure. Shape checks: `bad_structure_id`, `bad_item_id`,
## `bad_quantity` (below 0 or above StructureDefinition.MAX_COST_QUANTITY).
## What is taken, how fast the work goes and what a cancellation returns is
## decided by BuildingService from server state. The inventory the materials
## left is sent to its owner only, by InventoryNetModule (it replicates the
## `items_taken` transaction without scheduling a save); returned materials
## are world items and InventoryNetModule announces them like any dropped
## item, to the peers that are told about that cell.
## Progress is not sent every tick: BuildingService records an event when a
## structure becomes `constructing`, every
## BuildingSettings.progress_event_step of progress, when its last worker
## stops and when it is completed, and each event is one row. Who is working
## is sent to the peers that see the structure (_rpc_work_changed): it is
## something anybody standing there can see.
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
## Replication. A structure is something anybody standing there can see.
## BuildingService records events; this module drains them every server
## tick, and at once when a request was accepted, so that the peers that see
## the structure learn of a change before the requester gets its answer
## (same ordered channel). This module is the only consumer of
## BuildingService.drain_events().
##
## Scope by cell (docs/09 §15.2, §15.5; docs/15 P3-056 resolved). A peer is
## told only about the structures of the cells it is told about
## (NetworkService.cell_interest), and about who works on those structures:
##   - the join fragment holds the structures and workers of the joining
##     peer's cells (none for a player without a character);
##   - when a peer gains a cell (it walked there, entered the world, or the
##     cell came into the server's memory) it gets that cell's structures as
##     rows and their workers as work changes; when it loses a cell (it
##     walked away, or the cell is about to leave memory) it gets one removal
##     for that cell's structures. The mirror drops their workers with them.
##     Nothing was built or demolished then: these are no BuildingService
##     events;
##   - every event goes to NetworkService.peers_interested_in(the cell of
##     the structure) only. Events of a cell that are still queued when a
##     peer gains or loses that cell are sorted out first, so a mirror never
##     gets a removal or a stop for something it was not told about, and
##     never keeps something that was removed while it left;
##   - the requester always gets the answer to its own request.
## Invariant: a mirror holds exactly the structures of the peer's cells.
## Without an interest module (an assembly that did not install it) every
## joined peer is told about everything and cells are not followed.
##
## What a requester may learn (docs/00 ADR-009). A request that names a
## structure the requester is not told about is handled as if it named a
## structure that does not exist: the rule is asked about no structure, so
## the answer (normally `unknown_structure`, or the requester's own state
## such as `player_dead`) is exactly the one an invented id gets, and
## nothing happens to the structure (counted:
## hidden_structure_request_count). A request to STOP working is not
## treated this way: its only refusals (`not_online`, `not_working`) say
## nothing about any structure. Placement names no structure; its refusals
## (`slot_occupied`, ...) concern a slot within placement range of the
## requester (docs/15 P3-058).
##
## Saving (docs/00 ADR-025). A placement, a cancellation and a demolition
## are saved at once (persist_on_place_and_demolish), a completion at the
## end of its tick (persist_on_completion). A delivery, a start or stop of
## work and progress are not saved on their own (persist_on_delivery): they
## are written by the next save that happens anyway.
##
## Client surface (presentation, P3-4b): request_place(), request_deliver(),
## request_work(), request_cancel(), request_demolish(), request_door(), the
## `structure_result` signal and the mirror `client_state`. The mirror has
## no authority.

## Client: answer to one of this client's own building requests.
signal structure_result(request_id: int, ok: bool, reason: String, structure_id: String)

const MODULE_NAME: String = "StructureNet"
## Intent names in rejection logs.
const INTENT_PLACE: String = "structure_place"
const INTENT_DEMOLISH: String = "structure_demolish"
const INTENT_DOOR: String = "structure_door"
const INTENT_DELIVER: String = "structure_deliver"
const INTENT_WORK: String = "structure_work"
const INTENT_CANCEL: String = "structure_cancel"
const REASON_BAD_DEFINITION_ID: String = "bad_definition_id"
const REASON_BAD_STRUCTURE_ID: String = "bad_structure_id"
const SAVE_REASON_PLACED: String = "structure_placed"
const SAVE_REASON_REMOVED: String = "structure_removed"
const SAVE_REASON_DOOR: String = "structure_door"
const SAVE_REASON_DELIVERED: String = "structure_materials_delivered"
const SAVE_REASON_CANCELLED: String = "structure_cancelled"
const SAVE_REASON_COMPLETED: String = "structure_completed"
## Kinds of operations queued for a peer while events are sent
## (_flush_events): a structure row, a removed structure id, a work change.
const OP_ROW: int = 0
const OP_REMOVED: int = 1
const OP_WORK: int = 2
## _flush_events: the peer named is gaining every cell at once (a join).
const ALL_CELLS: String = "*"
## Returned by the request functions when nothing was sent.
const NO_REQUEST: int = 0
## Longest reason code a client accepts in a result.
const REASON_MAX_LENGTH: int = 64
## Longest definition id the server looks at.
const DEFINITION_ID_MAX_LENGTH: int = 64

## Client: the mirror. Stays empty on the server (which uses it to hold its
## own rows to the rule its clients apply).
var client_state: ClientStructureState
## Server diagnostics: rows, removed ids, work changes and messages of any of
## the three kinds sent since the start. Each is counted once per peer it
## was sent to (peers get different streams since the scope by cell).
var sent_row_count: int = 0
var sent_removal_count: int = 0
var unsendable_row_count: int = 0
var sent_work_change_count: int = 0
var sent_message_count: int = 0
## Client: results from the server that failed validation.
var rejected_payload_count: int = 0
## Client (diagnostics): replication messages received from the server (rows,
## removals, work changes; not the answers to this client's own requests)
## and what they carried.
var received_message_count: int = 0
var received_row_count: int = 0
var received_removal_count: int = 0
var received_work_change_count: int = 0

var _settings: StructureNetSettings
# --- server state ---
var _world: ServerWorld = null
var _building: BuildingService = null
## The session's cell interest (docs/09 §15.2), or null without the module.
var _interest: CellInterest = null
var _place_limiter: RateLimiter = null
var _demolish_limiter: RateLimiter = null
var _door_limiter: RateLimiter = null
var _deliver_limiter: RateLimiter = null
var _work_limiter: RateLimiter = null
var _inventory_net: InventoryNetModule = null
## A structure was completed and the world was not saved since.
var _completion_unsaved: bool = false
## Diagnostics: requests that named a structure the requester is not told
## about and were answered as if it did not exist.
var hidden_structure_request_count: int = 0
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


## "" when the arguments of a delivery request are usable. The item is ""
## (whatever is carried and needed) or an id of bounded length; the quantity
## is 0 (as many as needed) or a number of units no structure can need more
## of. Whether the item is carried and how many units the stack holds is the
## rule's check.
static func validate_deliver_request(request_id: Variant, structure_id: Variant, item_instance_id: Variant, quantity: Variant) -> String:
	if typeof(item_instance_id) != TYPE_STRING or typeof(quantity) != TYPE_INT:
		return IntentValidator.REASON_BAD_TYPE
	var reason: String = validate_demolish_request(request_id, structure_id)
	if not reason.is_empty():
		return reason
	if str(item_instance_id).length() > IntentValidator.ENTITY_ID_MAX_LENGTH:
		return IntentValidator.REASON_BAD_ITEM_ID
	# Compared as a 64-bit number, before it reaches any rule.
	if int(quantity) < BuildingService.AS_MUCH_AS_NEEDED or int(quantity) > StructureDefinition.MAX_COST_QUANTITY:
		return InventoryService.REASON_BAD_QUANTITY
	return ""


## "" when the arguments of a work request are usable.
static func validate_work_request(request_id: Variant, structure_id: Variant, working: Variant) -> String:
	return validate_door_request(request_id, structure_id, working)


## "" when the arguments of a cancel request are usable.
static func validate_cancel_request(request_id: Variant, structure_id: Variant) -> String:
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
	_deliver_limiter = RateLimiter.new(_settings.deliver_intent_rate_per_sec, _settings.deliver_intent_burst)
	_work_limiter = RateLimiter.new(_settings.work_intent_rate_per_sec, _settings.work_intent_burst)
	_completion_unsaved = false
	# P3-5: the inventory module replicates the materials a delivery takes
	# and the items a cancellation returns; here only its pending save is
	# used (_save). Null in an assembly without it.
	_inventory_net = network.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	# Scope by cell: the interest module (registered first) decides who is
	# told about which cell; a cell entering or leaving the server's memory
	# reaches this module through it as a gain or a loss.
	_interest = network.cell_interest
	if _interest == null:
		GameLogger.warning("net", "no interest module: every joined peer is told about every structure", {"world_id": world.world_id, "module": MODULE_NAME, "operation": "on_server_started"})
		return
	_interest.cell_gained.connect(_on_cell_gained)
	_interest.cell_lost.connect(_on_cell_lost)


func _exit_tree() -> void:
	if _interest == null:
		return
	if _interest.cell_gained.is_connected(_on_cell_gained):
		_interest.cell_gained.disconnect(_on_cell_gained)
	if _interest.cell_lost.is_connected(_on_cell_lost):
		_interest.cell_lost.disconnect(_on_cell_lost)
	_interest = null


func on_player_left(peer_id: int, _player_id: String) -> void:
	for limiter: RateLimiter in [_place_limiter, _demolish_limiter, _door_limiter, _deliver_limiter, _work_limiter]:
		if limiter != null:
			limiter.forget(peer_id)


func server_physics(_delta: float) -> void:
	_flush_events()
	# P3-5: a completion happens in the world's step, not in a request.
	if _completion_unsaved:
		_completion_unsaved = false
		if _settings.persist_on_completion and network != null and network.is_server():
			network.persist(SAVE_REASON_COMPLETED)


## The structures of the joining peer's cells as they are right now, and the
## players working on them (the peer's first cells are decided already: the
## interest module builds its fragment first). Events still queued in
## BuildingService are sent first, to everybody but the joining peer (the
## fragment already holds their outcome), so the fragment and the stream
## never disagree.
func build_join_fragment(player_id: String) -> Dictionary:
	if _building == null:
		return {}
	var peer_id: int = network.peer_of_player(player_id)
	_flush_events(peer_id, ALL_CELLS, false)
	var rows: Array = []
	var visible: Dictionary[String, bool] = {}
	for public_row: Dictionary in _building.rows():
		var structure_id: String = str(public_row.get(BuildingService.KEY_STRUCTURE_ID, ""))
		if not _is_told_about(peer_id, structure_id):
			continue
		var row: Array = _checked_row(public_row, "build_join_fragment")
		if not row.is_empty():
			rows.append(row)
			visible[structure_id] = true
	var workers: Array = []
	for worker: Array in _building.worker_rows():
		if visible.has(str(worker[1])):
			workers.append(worker)
	return {
		ClientStructureState.KEY_SCHEMA_VERSION: ClientStructureState.SCHEMA_VERSION,
		ClientStructureState.KEY_STRUCTURES: rows,
		ClientStructureState.KEY_WORKERS: workers,
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
	var result: ActionResult = _building.try_demolish(_world, player_id, _id_for_rule(peer_id, str(structure_id)))
	_finish_request(peer_id, player_id, INTENT_DEMOLISH, int(request_id), result, _settings.persist_on_place_and_demolish, SAVE_REASON_REMOVED)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_door(request_id: Variant, structure_id: Variant, open: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = network.sender_player_id()
	if not _accept_request(peer_id, player_id, INTENT_DOOR, request_id, validate_door_request(request_id, structure_id, open), _door_limiter):
		return
	var result: ActionResult = _building.try_set_door(_world, player_id, _id_for_rule(peer_id, str(structure_id)), bool(open))
	_finish_request(peer_id, player_id, INTENT_DOOR, int(request_id), result, _settings.persist_on_door_change, SAVE_REASON_DOOR)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_deliver(request_id: Variant, structure_id: Variant, item_instance_id: Variant, quantity: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = network.sender_player_id()
	if not _accept_request(peer_id, player_id, INTENT_DELIVER, request_id, validate_deliver_request(request_id, structure_id, item_instance_id, quantity), _deliver_limiter):
		return
	# The owner's inventory is replicated inside this call
	# (transaction_committed), before the row and the result.
	var result: ActionResult = _building.try_deliver(_world, player_id, _id_for_rule(peer_id, str(structure_id)), str(item_instance_id), int(quantity))
	_finish_request(peer_id, player_id, INTENT_DELIVER, int(request_id), result, _settings.persist_on_delivery, SAVE_REASON_DELIVERED)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_work(request_id: Variant, structure_id: Variant, working: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = network.sender_player_id()
	if not _accept_request(peer_id, player_id, INTENT_WORK, request_id, validate_work_request(request_id, structure_id, working), _work_limiter):
		return
	# A stop request is passed on as it is: its refusals reveal no structure.
	var named: String = _id_for_rule(peer_id, str(structure_id)) if bool(working) else str(structure_id)
	var result: ActionResult = _building.try_set_work(_world, player_id, named, bool(working))
	# Who works is not saved at all.
	_finish_request(peer_id, player_id, INTENT_WORK, int(request_id), result, false, "")


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_cancel(request_id: Variant, structure_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = network.sender_player_id()
	# The demolish bucket: both take a structure out of the world.
	if not _accept_request(peer_id, player_id, INTENT_CANCEL, request_id, validate_cancel_request(request_id, structure_id), _demolish_limiter):
		return
	var result: ActionResult = _building.try_cancel(_world, player_id, _id_for_rule(peer_id, str(structure_id)))
	_finish_request(peer_id, player_id, INTENT_CANCEL, int(request_id), result, _settings.persist_on_place_and_demolish, SAVE_REASON_CANCELLED)


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
		_save(save_reason, result.event)


## Saves the world for an accepted request. Materials that were returned
## are an item drop InventoryNetModule is about to save at the end of this
## tick: its pending save is used, so the world is written once.
func _save(save_reason: String, event: Dictionary) -> void:
	var returned: Variant = event.get("refund_item_instance_ids", [])
	if _inventory_net != null and typeof(returned) == TYPE_ARRAY and not (returned as Array).is_empty():
		_inventory_net.flush_pending_save(save_reason)
	else:
		network.persist(save_reason)


func _send_result(peer_id: int, request_id: int, ok: bool, reason: String, structure_id: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_structure_result.rpc_id(peer_id, request_id, ok, reason, structure_id)


## The structure id a rule is asked about for a request of `peer_id`:
## `structure_id` itself, or "" (no structure at all) when it names a
## structure the peer is not told about. See "What a requester may learn".
func _id_for_rule(peer_id: int, structure_id: String) -> String:
	if not _building.has_structure(structure_id) or _is_told_about(peer_id, structure_id):
		return structure_id
	hidden_structure_request_count += 1
	return ""


## True when the structure is in memory and in one of the peer's cells.
func _is_told_about(peer_id: int, structure_id: String) -> bool:
	var structure: StructureInstance = _building.get_structure(structure_id)
	return structure != null and network.is_cell_of_interest(peer_id, structure.cell_id)


## Sends what BuildingService recorded since the last call, in the order it
## happened, each event to the peers that are told about its cell.
## `peer_id` / `cell_id` name a peer that is gaining (`leaving` false) or
## losing (`leaving` true) a cell right now, when the interest set already
## shows the new state: the queued events of that cell do not go to a peer
## that is about to get the whole cell, and still go to a peer that is
## about to have the cell taken away. `cell_id` ALL_CELLS (with `leaving`
## false) is a peer that is joining: no queued event goes to it.
func _flush_events(peer_id: int = 0, cell_id: String = "", leaving: bool = false) -> void:
	if _building == null or network == null or not network.is_server():
		return
	var events: Array[Dictionary] = _building.drain_events()
	if events.is_empty():
		return
	# peer id -> its operations in order: [OP_*, payload].
	var outbox: Dictionary[int, Array] = {}
	for event: Dictionary in events:
		var event_type: String = str(event.get("event_type", ""))
		var operation: Array = []
		if event_type == BuildingService.EVENT_WORK_STARTED or event_type == BuildingService.EVENT_WORK_STOPPED:
			operation = _work_operation(event, event_type == BuildingService.EVENT_WORK_STARTED)
		elif event_type == BuildingService.EVENT_REMOVED:
			operation = [OP_REMOVED, str(event.get(BuildingService.KEY_STRUCTURE_ID, ""))]
		else:
			if event_type == BuildingService.EVENT_CHANGED and str(event.get("cause", "")) == BuildingService.CAUSE_COMPLETED:
				_completion_unsaved = true
			var row: Array = _checked_row(event, "flush_events")
			if not row.is_empty():
				operation = [OP_ROW, row]
		if operation.is_empty():
			continue
		var event_cell: String = str(event.get("cell_id", ""))
		var receivers: PackedInt32Array = network.peers_interested_in(event_cell)
		if peer_id != 0 and (event_cell == cell_id or cell_id == ALL_CELLS):
			var index: int = receivers.find(peer_id)
			if leaving and index < 0:
				receivers.append(peer_id)
			elif not leaving and index >= 0:
				receivers.remove_at(index)
		for receiver: int in receivers:
			if not outbox.has(receiver):
				outbox[receiver] = []
			outbox[receiver].append(operation)
	for receiver: int in outbox:
		_send_operations(receiver, outbox[receiver])


## Sends one peer its operations in order: consecutive rows as row messages,
## consecutive removals as removal messages, each work change by itself.
func _send_operations(peer_id: int, operations: Array) -> void:
	var rows: Array = []
	var removed: Array = []
	for operation: Array in operations:
		if operation[0] != OP_ROW:
			_send_rows(peer_id, rows)
			rows = []
		if operation[0] != OP_REMOVED:
			_send_removed(peer_id, removed)
			removed = []
		if operation[0] == OP_ROW:
			rows.append(operation[1])
		elif operation[0] == OP_REMOVED:
			removed.append(operation[1])
		else:
			_send_work(peer_id, operation[1] as Array)
	_send_rows(peer_id, rows)
	_send_removed(peer_id, removed)


## A peer is told about a cell from now on (it walked there, it entered the
## world, or the cell came into the server's memory): it gets the cell's
## structures as they are, then who is working on them.
func _on_cell_gained(peer_id: int, cell_id: String) -> void:
	if _building == null or network == null or not network.is_server():
		return
	_flush_events(peer_id, cell_id, false)
	var structure_ids: PackedStringArray = _building.structure_ids_in_cell(_world, cell_id)
	if structure_ids.is_empty():
		return
	_send_rows(peer_id, _encode_rows(_building.rows_in_cell(_world, cell_id)))
	for structure_id: String in structure_ids:
		for player_id: String in _building.workers_of(structure_id):
			var operation: Array = _work_operation({"player_id": player_id, BuildingService.KEY_STRUCTURE_ID: structure_id}, true)
			if not operation.is_empty():
				_send_work(peer_id, operation[1] as Array)


## A peer is no longer told about a cell (it walked away, or the cell is
## about to leave the server's memory; its structures can still be read):
## the cell's structures leave its mirror, and their workers with them
## (ClientStructureState drops the workers of a structure that is removed).
func _on_cell_lost(peer_id: int, cell_id: String) -> void:
	if _building == null or network == null or not network.is_server():
		return
	_flush_events(peer_id, cell_id, true)
	_send_removed(peer_id, Array(_building.structure_ids_in_cell(_world, cell_id)))


## The operation for a BuildingService work event ([] when it would not pass
## the check the clients apply: logged and counted).
func _work_operation(event: Dictionary, working: bool) -> Array:
	var player_id: String = str(event.get("player_id", ""))
	var structure_id: String = str(event.get(BuildingService.KEY_STRUCTURE_ID, ""))
	var reason: String = "" if working else str(event.get("reason", ""))
	# The server holds its own output to the rule its clients apply.
	if not PlayerState.is_valid_player_id(player_id) or not StructureInstance.is_valid_structure_id(structure_id) or working != reason.is_empty() or reason.length() > ClientStructureState.REASON_MAX_LENGTH:
		unsendable_row_count += 1
		GameLogger.error("net", "work change does not fit the wire format", {"entity_id": structure_id, "player_id": player_id, "module": MODULE_NAME, "operation": "work_operation"})
		return []
	return [OP_WORK, [player_id, structure_id, working, reason]]


## Tells one peer that a player started or stopped working on a structure:
## `change` is [player_id, structure_id, working, reason].
func _send_work(peer_id: int, change: Array) -> void:
	if not network.can_send_to(peer_id):
		return
	_rpc_work_changed.rpc_id(peer_id, change[0], change[1], change[2], change[3])
	sent_work_change_count += 1
	sent_message_count += 1


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


## Sends one peer structure rows (added or changed structures), cut into
## messages of rows_per_message.
func _send_rows(peer_id: int, rows: Array) -> void:
	if rows.is_empty() or not network.can_send_to(peer_id):
		return
	var offset: int = 0
	while offset < rows.size():
		var message: Array = rows.slice(offset, offset + _settings.rows_per_message)
		_rpc_structure_rows.rpc_id(peer_id, message)
		offset += message.size()
		sent_row_count += message.size()
		sent_message_count += 1


## Takes structures out of one peer's mirror, cut into messages of
## removals_per_message.
func _send_removed(peer_id: int, structure_ids: Array) -> void:
	if structure_ids.is_empty() or not network.can_send_to(peer_id):
		return
	var offset: int = 0
	while offset < structure_ids.size():
		var message: Array = structure_ids.slice(offset, offset + _settings.removals_per_message)
		_rpc_structures_removed.rpc_id(peer_id, message)
		offset += message.size()
		sent_removal_count += message.size()
		sent_message_count += 1


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


## Asks the server to put carried materials into an unfinished structure:
## `quantity` units of the carried stack `item_instance_id` at most (0 = as
## many as the structure still needs), or, with "" as the item, whatever the
## player carries that the structure still needs. The server takes only what
## is missing.
func request_deliver(structure_id: String, item_instance_id: String = BuildingService.ANY_CARRIED_ITEM, quantity: int = BuildingService.AS_MUCH_AS_NEEDED) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_deliver_request(_last_request_id, structure_id, item_instance_id, quantity)
	return _last_request_id


## Asks the server to let the player work on an unfinished structure
## (`working` true) or to stop working on it.
func request_work(structure_id: String, working: bool) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_work_request(_last_request_id, structure_id, working)
	return _last_request_id


## Asks the server to cancel an unfinished structure the player placed.
func request_cancel(structure_id: String) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_cancel_request(_last_request_id, structure_id)
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


func send_raw_deliver_request(request_id: Variant, structure_id: Variant, item_instance_id: Variant, quantity: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_deliver.rpc_id(NetworkService.SERVER_PEER_ID, request_id, structure_id, item_instance_id, quantity)


func send_raw_work_request(request_id: Variant, structure_id: Variant, working: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_work.rpc_id(NetworkService.SERVER_PEER_ID, request_id, structure_id, working)


func send_raw_cancel_request(request_id: Variant, structure_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_cancel.rpc_id(NetworkService.SERVER_PEER_ID, request_id, structure_id)


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
	received_message_count += 1
	received_row_count += (rows as Array).size() if typeof(rows) == TYPE_ARRAY else 0
	client_state.apply_rows(rows)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_structures_removed(structure_ids: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	received_message_count += 1
	received_removal_count += (structure_ids as Array).size() if typeof(structure_ids) == TYPE_ARRAY else 0
	client_state.apply_removed(structure_ids)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_work_changed(player_id: Variant, structure_id: Variant, working: Variant, reason: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	received_message_count += 1
	received_work_change_count += 1
	client_state.apply_work_change(player_id, structure_id, working, reason)


func _reject_result() -> void:
	rejected_payload_count += 1
	GameLogger.warning("structure_net", "structure result dropped", {"module": MODULE_NAME, "operation": "apply_payload"})
