class_name ContainerNetModule
extends NetModule
## The container intents and the replication of containers (P3-3, docs/00
## ADR-021, ADR-026, docs/09 §15.3). Network only: every rule is in
## ContainerService and InventoryService.transfer_item.
##
## RPC table (channel 0 = reliable ordered: containers are world state, and
## what a client sees of one must arrive in the order the server decided it):
##   client -> server  _rpc_request_container_open(request_id:int,
##                         container_id:String)                      reliable, ch0
##   client -> server  _rpc_request_container_close(request_id:int,
##                         container_id:String)                      reliable, ch0
##   client -> server  _rpc_request_container_take(request_id:int,
##                         container_id:String, item_instance_id:String,
##                         quantity:int)                             reliable, ch0
##   client -> server  _rpc_request_container_put(request_id:int,
##                         container_id:String, item_instance_id:String,
##                         quantity:int)                             reliable, ch0
##   server -> client  _rpc_container_result(request_id:int, ok:bool,
##                         reason:String)                            reliable, ch0
##   server -> near    _rpc_container_rows(rows:Array)               reliable, ch0
##   server -> near    _rpc_containers_removed(container_ids:Array)  reliable, ch0
##   server -> opener  _rpc_container_session(container_id:String,
##                         phase:String, reason:String, search_sec:float,
##                         items:Array)                              reliable, ch0
##   server -> viewers _rpc_container_items(container_id:String,
##                         changed:Array, removed:Array)             reliable, ch0
## Row formats: ClientContainerState.
##
## Intents: a client names things only: the container, a stack and how many
## units of it (0 = the whole stack). The actor is always the player of the
## sending peer; there is no argument for a position, an owner, an
## inventory or a result. Server checks, in order: joined (`not_joined`),
## argument types (`bad_type`), request id >= 0 (`bad_sequence`), the other
## arguments (`bad_container_id`, `bad_item_id`, `bad_quantity`), request
## rate (`rate_limited`, one bucket for all four intents), then the rule
## (ContainerService: `too_far`, `container_not_open`, `container_full`,
## ...). Every refusal is counted (NetworkService.rejected_intent_count) and
## changes nothing. The result goes to the requester only; `reason` is ""
## exactly when ok.
##
## Who is told what (docs/00 ADR-009, ADR-026):
##   - That a container exists (id, definition, position, whether it was
##     searched) goes to the peers that are told about its cell
##     (NetworkService.cell_interest, docs/09 §15.2), and only to them: in
##     the join fragment, when a peer gains or loses the cell, and when a
##     container is created or searched.
##   - What is INSIDE goes only to the peers whose player has that container
##     open: everything when it opens (_rpc_container_session "open"), then
##     every change while it stays open (_rpc_container_items). A player who
##     searches is told nothing about the content until the search is over.
##     Nobody else is sent an item of a container, and nobody is told who
##     has which container open.
##   - A player's own inventory change (what it took, what it put in)
##     reaches it through InventoryNetModule's owner-only messages, sent
##     inside the transaction, before anything from here.
##   - A refusal never tells a requester about a container outside its cells:
##     such a container is reported like one that does not exist
##     (`unknown_container`), whatever the rule said (public_reason).
##   - What changed is sent before the result of the request that caused it
##     (same ordered channel).
##
## Saving: an accepted take or put is saved before anything about it is
## sent (like a pickup and a drop). Opening, searching and closing are not
## saved at once: a search is repeatable (the loot is decided by the seed)
## and is saved with the next save.
##
## Client surface (presentation): request_open(), request_close(),
## request_take(), request_put(), the `container_result` signal and the
## mirror `client_state`. The mirror has no authority.

## Client: answer to one of this client's own container requests.
signal container_result(request_id: int, ok: bool, reason: String)

const MODULE_NAME: String = "ContainerNet"
## Intent names in rejection logs.
const INTENT_OPEN: String = "container_open"
const INTENT_CLOSE: String = "container_close"
const INTENT_TAKE: String = "container_take"
const INTENT_PUT: String = "container_put"
## Returned by the request_*() functions when nothing was sent.
const NO_REQUEST: int = 0
## Longest reason code a client accepts in a result.
const REASON_MAX_LENGTH: int = 64
const REASON_BAD_CONTAINER_ID: String = "bad_container_id"
## Save reason (logs only).
const SAVE_REASON_TRANSFER: String = "container_transfer"

var client_state: ClientContainerState = null
## Client: results from the server that failed validation.
var rejected_payload_count: int = 0
## Server diagnostics: messages sent since the start, by kind.
var sent_row_message_count: int = 0
var sent_removed_message_count: int = 0
var sent_session_message_count: int = 0
var sent_items_message_count: int = 0
var sent_result_message_count: int = 0

var _settings: ContainerNetSettings
# --- server state ---
var _world: ServerWorld = null
var _containers: ContainerService = null
var _inventory_net: InventoryNetModule = null
var _interest: CellInterest = null
var _limiter: RateLimiter = null
# --- client state ---
var _last_request_id: int = NO_REQUEST


func _init(settings: ContainerNetSettings = null, definitions: ContainerCatalog = null) -> void:
	name = MODULE_NAME
	_settings = settings if settings != null else ContainerNetSettings.new()
	client_state = ClientContainerState.new(_settings, definitions)


func _exit_tree() -> void:
	if _interest == null:
		return
	if _interest.cell_gained.is_connected(_on_cell_gained):
		_interest.cell_gained.disconnect(_on_cell_gained)
	if _interest.cell_lost.is_connected(_on_cell_lost):
		_interest.cell_lost.disconnect(_on_cell_lost)
	_interest = null


# ------------------------------------------------------------ pure rules

## "" when the arguments of an open or a close request are usable, otherwise
## a reason code. Types first, so wrongly typed input never reaches a
## conversion.
static func validate_container_request(request_id: Variant, container_id: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(container_id) != TYPE_STRING:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	if not _is_id(container_id):
		return REASON_BAD_CONTAINER_ID
	return ""


## "" when the arguments of a take or a put request are usable. The quantity
## is 0 (the whole stack) or more; how many units the stack holds is the
## rule's check.
static func validate_item_request(request_id: Variant, container_id: Variant, item_instance_id: Variant, quantity: Variant) -> String:
	if typeof(item_instance_id) != TYPE_STRING or typeof(quantity) != TYPE_INT:
		return IntentValidator.REASON_BAD_TYPE
	var reason: String = validate_container_request(request_id, container_id)
	if not reason.is_empty():
		return reason
	if not _is_id(item_instance_id):
		return IntentValidator.REASON_BAD_ITEM_ID
	if int(quantity) < 0:
		return InventoryService.REASON_BAD_QUANTITY
	return ""


## The reason code a requester is told. `container_known`: the container is
## in memory and in a cell the requester is told about. `actor_can_act`: the
## requester is in the world and nothing blocks its actions (then the rule's
## refusal was about the container, not about the requester). A refusal
## about a container the requester is not told about is reported as
## `unknown_container`, so a client cannot probe where containers are or
## whether somebody has one open.
static func public_reason(reason: String, container_known: bool, actor_can_act: bool) -> String:
	if container_known or not actor_can_act:
		return reason
	return ContainerService.REASON_UNKNOWN_CONTAINER


## The wire row of a public container row (ContainerService.public_row).
static func encode_row(public_row: Dictionary) -> Array:
	var position: Array = public_row.get(ContainerService.KEY_POSITION, [0.0, 0.0, 0.0])
	return [
		str(public_row.get(ContainerService.KEY_CONTAINER_ID, "")),
		str(public_row.get(ContainerService.KEY_DEFINITION_ID, "")),
		float(position[0]),
		float(position[1]),
		float(position[2]),
		public_row.get(ContainerService.KEY_SEARCHED, false) == true,
	]


## The wire rows of content entries (ContainerService.contents_of).
static func encode_items(entries: Array) -> Array:
	var rows: Array = []
	for entry: Variant in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		rows.append([
			str((entry as Dictionary).get(ContainerService.ENTRY_ITEM_ID, "")),
			str((entry as Dictionary).get(ContainerService.ENTRY_DEFINITION_ID, "")),
			int((entry as Dictionary).get(ContainerService.ENTRY_QUANTITY, 0)),
			int((entry as Dictionary).get(ContainerService.ENTRY_SLOT, -1)),
		])
	return rows


static func _is_id(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and not str(value).is_empty() and str(value).length() <= IntentValidator.ENTITY_ID_MAX_LENGTH


# ------------------------------------------------------------ NetModule hooks

func on_server_started(world: ServerWorld) -> void:
	_containers = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
	if _containers == null:
		GameLogger.info("net", "world has no container system, container replication is off", {"world_id": world.world_id, "module": MODULE_NAME})
		return
	_world = world
	_inventory_net = network.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	_limiter = RateLimiter.new(_settings.container_intent_rate_per_sec, _settings.container_intent_burst)
	# P3-2 (docs/09 §15.2): the containers of a cell go to the peers that are
	# told about that cell. Without the interest module every peer is told
	# about every container in memory.
	_interest = network.cell_interest
	if _interest != null:
		_interest.cell_gained.connect(_on_cell_gained)
		_interest.cell_lost.connect(_on_cell_lost)


func on_player_left(peer_id: int, _player_id: String) -> void:
	if _limiter != null:
		_limiter.forget(peer_id)


## Server: sends what the container system did by itself in this tick (a
## search that completed, a session that ended, a container a server rule
## created).
func server_physics(_delta: float) -> void:
	_flush_events()


## The containers of the cells the joining peer is told about (its first
## cells are decided already: the interest module is registered first).
## Events still queued are sent to the peers that are joined already first,
## so the fragment and the stream never disagree.
func build_join_fragment(player_id: String) -> Dictionary:
	if _containers == null:
		return {}
	_flush_events()
	var peer_id: int = network.peer_of_player(player_id)
	var rows: Array = []
	for container_id: String in _containers.container_ids():
		var container: ContainerInstance = _containers.get_container(container_id)
		if not network.is_cell_of_interest(peer_id, container.cell_id):
			continue
		var row: Array = _checked_row(_containers.public_row(container), "build_join_fragment")
		if not row.is_empty():
			rows.append(row)
	return {ClientContainerState.KEY_SCHEMA_VERSION: ClientContainerState.SCHEMA_VERSION, ClientContainerState.KEY_CONTAINERS: rows}


func apply_join_fragment(fragment: Dictionary) -> void:
	_last_request_id = NO_REQUEST
	client_state.apply_join(fragment)


# ------------------------------------------------------------ server side

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_container_open(request_id: Variant, container_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_OPEN, request_id, validate_container_request(request_id, container_id))
	if not player_id.is_empty():
		# The container is only a name: everything about it is read from the server.
		_finish(player_id, int(request_id), str(container_id), _containers.try_open(_world, player_id, str(container_id)), false)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_container_close(request_id: Variant, container_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_CLOSE, request_id, validate_container_request(request_id, container_id))
	if not player_id.is_empty():
		_finish(player_id, int(request_id), str(container_id), _containers.try_close(_world, player_id, str(container_id)), false)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_container_take(request_id: Variant, container_id: Variant, item_instance_id: Variant, quantity: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_TAKE, request_id, validate_item_request(request_id, container_id, item_instance_id, quantity))
	if not player_id.is_empty():
		# Whose inventory the units go into is never an argument: the sending
		# peer's player. Its inventory change is replicated to it inside this call.
		_finish(player_id, int(request_id), str(container_id), _containers.try_take(_world, player_id, str(container_id), str(item_instance_id), int(quantity)), true)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_container_put(request_id: Variant, container_id: Variant, item_instance_id: Variant, quantity: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_PUT, request_id, validate_item_request(request_id, container_id, item_instance_id, quantity))
	if not player_id.is_empty():
		_finish(player_id, int(request_id), str(container_id), _containers.try_put(_world, player_id, str(container_id), str(item_instance_id), int(quantity)), true)


## The checks every container intent starts with (see the header). Returns
## the player of the sending peer, or "" when the request was refused
## (counted, logged and answered where it can be). Call only inside an RPC
## handler.
func _begin(intent: String, request_id: Variant, invalid_reason: String) -> String:
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The actor is whoever owns the sending peer, never an argument.
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, intent, NetworkService.NOT_JOINED)
		return ""
	if not invalid_reason.is_empty():
		network.reject_intent(peer_id, intent, invalid_reason, player_id)
		if typeof(request_id) == TYPE_INT and int(request_id) >= 0:
			_send_result(peer_id, int(request_id), false, invalid_reason)
		return ""
	if _containers == null:
		network.reject_intent(peer_id, intent, ContainerService.REASON_UNAVAILABLE, player_id)
		_send_result(peer_id, int(request_id), false, ContainerService.REASON_UNAVAILABLE)
		return ""
	if not _limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, intent, NetworkService.RATE_LIMITED, player_id)
		_send_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED)
		return ""
	return player_id


## Saves an accepted transfer, sends what the rule changed, then the answer.
## Call only inside an RPC handler.
func _finish(player_id: String, request_id: int, container_id: String, result: ActionResult, is_transfer: bool) -> void:
	var peer_id: int = multiplayer.get_remote_sender_id()
	if result.ok and is_transfer:
		_save_transfer()
	# Everybody concerned learns the new state before the requester gets the
	# answer (same ordered channel).
	_flush_events()
	if not result.ok:
		# Refusals by game state are normal play: counted, not logged as warnings.
		network.count_rejection(result.reason)
		_send_result(peer_id, request_id, false, _public_reason(peer_id, player_id, container_id, result.reason))
		return
	_send_result(peer_id, request_id, true, "")


## What the requester is told about a refusal (public_reason).
func _public_reason(peer_id: int, player_id: String, container_id: String, reason: String) -> String:
	var container: ContainerInstance = _containers.get_container(container_id)
	var known: bool = container != null and network.is_cell_of_interest(peer_id, container.cell_id)
	var can_act: bool = _world.is_online(player_id) and _world.player_action_block_reason(player_id).is_empty()
	return public_reason(reason, known, can_act)


## An accepted take or put moved items between a container and an
## inventory: the world is saved at once.
func _save_transfer() -> void:
	if _inventory_net != null:
		_inventory_net.flush_pending_save(SAVE_REASON_TRANSFER)
	else:
		network.persist(SAVE_REASON_TRANSFER)


## Sends every pending event of the container system, in the order it
## happened: container rows to the peers that are told about the cell, a
## session state to the player it belongs to, a content change to the
## players that had the container open.
func _flush_events() -> void:
	if _containers == null or network == null or not network.is_server():
		return
	var events: Array[Dictionary] = _containers.drain_events()
	if events.is_empty():
		return
	# peer_id -> rows that wait to be sent (one message for many rows).
	var pending_rows: Dictionary[int, Array] = {}
	for event: Dictionary in events:
		var event_type: String = str(event.get("event_type", ""))
		if event_type == ContainerService.EVENT_ADDED or event_type == ContainerService.EVENT_CHANGED:
			var row: Array = _checked_row(event, "flush_events")
			if row.is_empty():
				continue
			for peer_id: int in network.peers_interested_in(str(event.get("cell_id", ""))):
				if not pending_rows.has(peer_id):
					pending_rows[peer_id] = []
				pending_rows[peer_id].append(row)
			continue
		# A session or a content message follows the rows recorded before it.
		_send_pending_rows(pending_rows)
		if event_type == ContainerService.EVENT_REMOVED:
			_send_removed_to_interest(str(event.get("cell_id", "")), str(event.get(ContainerService.KEY_CONTAINER_ID, "")))
		elif event_type == ContainerService.EVENT_SESSION:
			_send_session(event)
		elif event_type == ContainerService.EVENT_CONTENTS:
			_send_contents(event)
	_send_pending_rows(pending_rows)


func _send_removed_to_interest(cell_id: String, container_id: String) -> void:
	if container_id.is_empty():
		return
	for peer_id: int in network.peers_interested_in(cell_id):
		if network.can_send_to(peer_id):
			sent_removed_message_count += 1
			_rpc_containers_removed.rpc_id(peer_id, [container_id])


func _send_pending_rows(pending_rows: Dictionary[int, Array]) -> void:
	for peer_id: int in pending_rows:
		_send_rows(peer_id, pending_rows[peer_id])
	pending_rows.clear()


## The state of one player's session, to that player only.
func _send_session(event: Dictionary) -> void:
	var peer_id: int = network.peer_of_player(str(event.get("player_id", "")))
	if peer_id == 0 or not network.can_send_to(peer_id):
		return
	var items: Array = encode_items(event.get("items", []) as Array)
	sent_session_message_count += 1
	_rpc_container_session.rpc_id(peer_id, str(event.get(ContainerService.KEY_CONTAINER_ID, "")), str(event.get("phase", "")), str(event.get("reason", "")), float(event.get("search_sec", 0.0)), items)


## What changed inside a container, to the players that had it open.
func _send_contents(event: Dictionary) -> void:
	var changed: Array = encode_items(event.get("changed", []) as Array)
	var removed: Array = []
	for item_id: Variant in event.get("removed", []) as Array:
		removed.append(str(item_id))
	for player_id: Variant in event.get("viewers", []) as Array:
		var peer_id: int = network.peer_of_player(str(player_id))
		if peer_id == 0 or not network.can_send_to(peer_id):
			continue
		sent_items_message_count += 1
		_rpc_container_items.rpc_id(peer_id, str(event.get(ContainerService.KEY_CONTAINER_ID, "")), changed, removed)


## P3-2: the containers of a cell a peer is told about from now on.
func _on_cell_gained(peer_id: int, cell_id: String) -> void:
	if _containers == null or network == null or not network.is_server():
		return
	# What is still queued about this cell was not meant for this peer: it
	# gets the cell as it is now.
	_flush_events()
	var rows: Array = []
	for public_row: Dictionary in _containers.rows_in_cell(_world, cell_id):
		var row: Array = _checked_row(public_row, "cell_gained")
		if not row.is_empty():
			rows.append(row)
	_send_rows(peer_id, rows)


## P3-2: the containers of a cell a peer is no longer told about leave its
## mirror. They still stand in the world.
func _on_cell_lost(peer_id: int, cell_id: String) -> void:
	if _containers == null or network == null or not network.is_server() or not network.can_send_to(peer_id):
		return
	_flush_events()
	var ids: Array = Array(_containers.container_ids_in_cell(_world, cell_id))
	var per_message: int = clampi(_settings.removals_per_message, 1, ClientContainerState.MAX_IDS_PER_MESSAGE)
	var offset: int = 0
	while offset < ids.size():
		var message: Array = ids.slice(offset, offset + per_message)
		offset += message.size()
		sent_removed_message_count += 1
		_rpc_containers_removed.rpc_id(peer_id, message)


## Sends container rows to one peer, cut into messages.
func _send_rows(peer_id: int, rows: Array) -> void:
	if rows.is_empty() or not network.can_send_to(peer_id):
		return
	var per_message: int = clampi(_settings.rows_per_message, 1, ClientContainerState.MAX_ROWS_PER_MESSAGE)
	var offset: int = 0
	while offset < rows.size():
		var message: Array = rows.slice(offset, offset + per_message)
		offset += message.size()
		sent_row_message_count += 1
		_rpc_container_rows.rpc_id(peer_id, message)


## The wire row of a public row, or [] (logged) when it would not pass the
## rule the clients apply: the server holds its own output to it.
func _checked_row(public_row: Dictionary, operation: String) -> Array:
	var row: Array = encode_row(public_row)
	if not client_state.is_valid_row(row):
		GameLogger.error("net", "container row not replicated", {"entity_id": str(public_row.get(ContainerService.KEY_CONTAINER_ID, "")), "module": MODULE_NAME, "operation": operation})
		return []
	return row


func _send_result(peer_id: int, request_id: int, ok: bool, reason: String) -> void:
	if network.can_send_to(peer_id):
		sent_result_message_count += 1
		_rpc_container_result.rpc_id(peer_id, request_id, ok, reason)


# ------------------------------------------------------------ client side

## Asks the server to open (search) a container. Returns the request id the
## `container_result` signal will carry, or NO_REQUEST when nothing was sent
## (not a joined client). Nothing is decided here; the same goes for the
## three functions below.
func request_open(container_id: String) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_open_request(_last_request_id, container_id)
	return _last_request_id


## Asks the server to close the container (or to give up searching it).
func request_close(container_id: String) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_close_request(_last_request_id, container_id)
	return _last_request_id


## Asks the server for `quantity` units of a stack inside the open
## container (InventoryService.WHOLE_STACK = all of it).
func request_take(container_id: String, item_instance_id: String, quantity: int) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_take_request(_last_request_id, container_id, item_instance_id, quantity)
	return _last_request_id


## Asks the server to put `quantity` units of a carried stack into the open
## container (InventoryService.WHOLE_STACK = all of it).
func request_put(container_id: String, item_instance_id: String, quantity: int) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_put_request(_last_request_id, container_id, item_instance_id, quantity)
	return _last_request_id


## The send_raw_* functions send an arbitrary request without any
## client-side check (tests: malformed or forged input through the real RPC
## path).
func send_raw_open_request(request_id: Variant, container_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_container_open.rpc_id(NetworkService.SERVER_PEER_ID, request_id, container_id)


func send_raw_close_request(request_id: Variant, container_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_container_close.rpc_id(NetworkService.SERVER_PEER_ID, request_id, container_id)


func send_raw_take_request(request_id: Variant, container_id: Variant, item_instance_id: Variant, quantity: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_container_take.rpc_id(NetworkService.SERVER_PEER_ID, request_id, container_id, item_instance_id, quantity)


func send_raw_put_request(request_id: Variant, container_id: Variant, item_instance_id: Variant, quantity: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_container_put.rpc_id(NetworkService.SERVER_PEER_ID, request_id, container_id, item_instance_id, quantity)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_container_result(request_id: Variant, ok: Variant, reason: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if typeof(request_id) != TYPE_INT or typeof(ok) != TYPE_BOOL or typeof(reason) != TYPE_STRING:
		_reject_result()
		return
	var reason_code: String = reason
	# "" exactly when the request was accepted.
	if int(request_id) < 0 or reason_code.length() > REASON_MAX_LENGTH or bool(ok) != reason_code.is_empty():
		_reject_result()
		return
	container_result.emit(int(request_id), bool(ok), reason_code)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_container_rows(rows: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	client_state.apply_rows(rows)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_containers_removed(container_ids: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	client_state.apply_removed(container_ids)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_container_session(container_id: Variant, phase: Variant, reason: Variant, search_sec: Variant, items: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	client_state.apply_session(container_id, phase, reason, search_sec, items)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_container_items(container_id: Variant, changed: Variant, removed: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	client_state.apply_items(container_id, changed, removed)


func _can_request() -> bool:
	return network != null and network.is_client() and not network.client_state.local_player_id.is_empty()


func _reject_result() -> void:
	rejected_payload_count += 1
	GameLogger.warning("container_net", "container result dropped", {"module": MODULE_NAME, "operation": "apply_payload"})
