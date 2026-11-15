class_name InventoryNetModule
extends NetModule
## Drop and consume intents and replication of inventory changes (P2-T2,
## P2-T3; docs/09 §14.17, §14.18). Network only: every rule is in
## InventoryService / ServerWorld / ItemConsumption.
##
## RPC table (channel 0 = reliable ordered, the channel of the pickup RPCs):
##   client -> server  _rpc_request_drop(request_id:int, item_instance_id:String)       reliable, ch0
##   server -> owner   _rpc_drop_result(request_id:int, ok:bool, reason:String)          reliable, ch0
##   client -> server  _rpc_request_consume(request_id:int, item_instance_id:String)    reliable, ch0
##   server -> owner   _rpc_consume_result(request_id:int, ok:bool, reason:String)       reliable, ch0
##   server -> clients _rpc_world_items_added(items:Array[Dictionary])                   reliable, ch0
##   server -> owner   _rpc_inventory_items_removed(item_instance_ids:Array[String])     reliable, ch0
##   server -> owner   _rpc_inventory_item_changed(item:Dictionary /* ItemInstance */)   reliable, ch0
##
## Consume = use up one unit of a carried item (eat / drink, P2-T3; bandage,
## P2-T6): the same shape as a drop request: a request id and the id of a
## carried item, nothing else. There is no target, wound or effect argument:
## the effect comes from the item definition on the server and is applied to
## the requester (ItemConsumption). Checks, in order: joined, argument types,
## request id >= 0, item id length, request rate (its own bucket), then the
## rule (`player_dead`, `item_not_in_inventory`, `not_consumable`,
## `not_bleeding`, ...). The result goes to the requester only. The smaller
## stack / the vanished item reaches the owner through the replication below
## and the effect (lower needs, a wound that no longer bleeds) through the
## owner's survival events and snapshot; other players are told nothing
## about it. An accepted use is not saved on its own
## (InventoryNetSettings.save_after_consume, docs/15 P2-123).
##
## Request: a client sends an intent only: its own request id and the id of
## the item to put down. There is no position, owner or quantity argument;
## the actor is the player of the sending peer and the item lands where the
## server knows that player to be. Server checks, in order: joined
## (`not_joined`), argument types (`bad_type`), request id >= 0
## (`bad_sequence`), item id length (`bad_item_id`), request rate
## (`rate_limited`), the player is alive (`player_dead`), then the
## transaction's own rules (`item_not_in_inventory`, ...). Every refusal is
## counted (NetworkService.rejected_intent_count) and changes nothing.
##
## Result: sent to the requester only, for every request of a joined peer
## whose request id is usable (int >= 0). `reason` is "" exactly when ok.
## A requester is never told whether an id it does not hold exists elsewhere
## (see public_reason).
##
## Replication: the module listens to InventoryService.transaction_committed
## and sends at once, so clients receive inventory changes in the order the
## server committed them, also relative to the pickup messages NetworkService
## sends itself (same channel). It covers every caller: this module's drop
## intent and server rules that call ServerWorld.drop_all_player_items /
## remove_player_item or the InventoryService directly. An item that enters
## the world goes to every joined peer (definition, quantity, position); an
## item that leaves an inventory or changes its quantity goes to the owner
## only. Nobody is sent another player's inventory. Late joiners get world
## items and their own inventory in the join snapshot (NetworkService).
##
## Saving: a committed drop intent is saved before its result is sent (like a
## pickup); changes made by server rules are saved at the end of that server
## tick.
##
## Client surface (presentation): request_drop(), request_consume(), the
## signals below and the mirror NetworkService.client_state. The mirror has
## no authority.

## Client: answer to one of this client's own drop requests.
signal drop_result(request_id: int, ok: bool, reason: String)
## Client: answer to one of this client's own consume requests.
signal consume_result(request_id: int, ok: bool, reason: String)
## Client: these items now lie in the world (already in the mirror).
signal world_items_added(item_instance_ids: PackedStringArray)
## Client: these items left the local inventory (already out of the mirror).
signal inventory_items_removed(item_instance_ids: PackedStringArray)
## Client: an item of the local inventory was added or changed (quantity).
signal inventory_item_changed(item_instance_id: String)

const MODULE_NAME: String = "InventoryNet"
## Intent name in rejection logs.
const INTENT_DROP: String = "drop_item"
const INTENT_CONSUME: String = "consume_item"
## Returned by request_drop() / request_consume() when nothing was sent.
const NO_REQUEST: int = 0
## Protocol limit: a client drops a message with more entries. The server's
## InventoryNetSettings.max_items_per_message may not exceed it.
const MAX_ITEMS_PER_MESSAGE: int = 64
## Longest reason code a client accepts in a result.
const REASON_MAX_LENGTH: int = 64
const REASON_PLAYER_DEAD: String = SurvivalService.REASON_PLAYER_DEAD
## Save reasons (logs only).
const SAVE_REASON_DROP: String = "item_dropped"
const SAVE_REASON_CHANGE: String = "inventory_changed"
const SAVE_REASON_CONSUME: String = "item_consumed"

## Client: payloads from the server that failed validation (whole messages
## and single entries).
var rejected_payload_count: int = 0
## Client: owner-only messages (inventory items removed / changed) received
## from the server. A client only ever gets those about its own inventory.
var owner_message_count: int = 0

var _settings: InventoryNetSettings
# --- server state ---
var _world: ServerWorld = null
var _survival: SurvivalService = null
var _limiter: RateLimiter = null
var _consume_limiter: RateLimiter = null
## A replicated change has not been saved yet.
var _save_pending: bool = false
## True while a transaction is being committed whose change is left to the
## next regular save (a consumption, docs/15 P2-123). It is still replicated.
var _leave_to_next_save: bool = false
# --- client state ---
var _last_request_id: int = NO_REQUEST
var _last_consume_request_id: int = NO_REQUEST


func _init(settings: InventoryNetSettings) -> void:
	name = MODULE_NAME
	_settings = settings


func _exit_tree() -> void:
	if _world != null and _world.inventory.transaction_committed.is_connected(_on_inventory_transaction):
		_world.inventory.transaction_committed.disconnect(_on_inventory_transaction)


# ------------------------------------------------------------ pure rules

## "" when the arguments of a drop request are usable, otherwise a reason
## code. Same shape and rules as a pickup request (types first).
static func validate_drop_request(request_id: Variant, item_instance_id: Variant) -> String:
	return IntentValidator.validate_pickup(request_id, item_instance_id)


## "" when the arguments of a consume request are usable, otherwise a reason
## code. Same shape and rules as a drop request.
static func validate_consume_request(request_id: Variant, item_instance_id: Variant) -> String:
	return IntentValidator.validate_pickup(request_id, item_instance_id)


## The reason code a requester is told. An id that does not exist is reported
## like an id the requester does not hold, so a client cannot probe which
## item ids exist in other inventories.
static func public_reason(reason: String) -> String:
	if reason == InventoryService.REASON_UNKNOWN_ITEM:
		return InventoryService.REASON_NOT_IN_INVENTORY
	return reason


## True when `item` is an inventory entry as the server sends it to an owner:
## a valid ItemInstance dictionary that is carried in an inventory.
static func is_valid_inventory_item(item: Variant) -> bool:
	if typeof(item) != TYPE_DICTIONARY:
		return false
	var data: Dictionary = item
	if not ItemInstance.validate_dict(data).is_empty():
		return false
	if str(data["item_instance_id"]).length() > ClientWorldState.ITEM_ID_MAX_LENGTH:
		return false
	return str(data["location_type"]) == ItemInstance.LOCATION_INVENTORY


static func _is_valid_item_id(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and not str(value).is_empty() and str(value).length() <= ClientWorldState.ITEM_ID_MAX_LENGTH


# ------------------------------------------------------------ NetModule hooks

func on_server_started(world: ServerWorld) -> void:
	_world = world
	_survival = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	_limiter = RateLimiter.new(_settings.drop_intent_rate_per_sec, _settings.drop_intent_burst)
	_consume_limiter = RateLimiter.new(_settings.consume_intent_rate_per_sec, _settings.consume_intent_burst)
	_save_pending = false
	_leave_to_next_save = false
	if not world.inventory.transaction_committed.is_connected(_on_inventory_transaction):
		world.inventory.transaction_committed.connect(_on_inventory_transaction)


func on_player_left(peer_id: int, _player_id: String) -> void:
	if _limiter != null:
		_limiter.forget(peer_id)
	if _consume_limiter != null:
		_consume_limiter.forget(peer_id)


## Server: saves changes made by server rules during this tick.
func server_physics(_delta: float) -> void:
	_flush_save(SAVE_REASON_CHANGE)


func apply_join_fragment(_fragment: Dictionary) -> void:
	_last_request_id = NO_REQUEST
	_last_consume_request_id = NO_REQUEST


# ------------------------------------------------------------ server side

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_drop(request_id: Variant, item_instance_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The actor is whoever owns the sending peer, never an argument.
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, INTENT_DROP, NetworkService.NOT_JOINED)
		return
	var reason: String = validate_drop_request(request_id, item_instance_id)
	if not reason.is_empty():
		network.reject_intent(peer_id, INTENT_DROP, reason, player_id)
		if typeof(request_id) == TYPE_INT and int(request_id) >= 0:
			_send_result(peer_id, int(request_id), false, reason)
		return
	if not _limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, INTENT_DROP, NetworkService.RATE_LIMITED, player_id)
		_send_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED)
		return
	# Refusals by game state are normal play: counted, not logged as warnings.
	if _survival != null and not _survival.is_alive(player_id):
		network.count_rejection(REASON_PLAYER_DEAD)
		_send_result(peer_id, int(request_id), false, REASON_PLAYER_DEAD)
		return
	var item_id: String = str(item_instance_id)
	# Replication happens inside this call (transaction_committed), before
	# the result below.
	var result: ActionResult = _world.try_drop_item(player_id, item_id)
	if not result.ok:
		network.count_rejection(result.reason)
		_send_result(peer_id, int(request_id), false, public_reason(result.reason))
		return
	_flush_save(SAVE_REASON_DROP)
	_send_result(peer_id, int(request_id), true, "")
	GameLogger.info("net", "drop committed", {"peer_id": peer_id, "player_id": player_id, "entity_id": item_id, "request_id": int(request_id)})


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_consume(request_id: Variant, item_instance_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The actor is whoever owns the sending peer, never an argument.
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, INTENT_CONSUME, NetworkService.NOT_JOINED)
		return
	var reason: String = validate_consume_request(request_id, item_instance_id)
	if not reason.is_empty():
		network.reject_intent(peer_id, INTENT_CONSUME, reason, player_id)
		if typeof(request_id) == TYPE_INT and int(request_id) >= 0:
			_send_consume_result(peer_id, int(request_id), false, reason)
		return
	if not _consume_limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, INTENT_CONSUME, NetworkService.RATE_LIMITED, player_id)
		_send_consume_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED)
		return
	var item_id: String = str(item_instance_id)
	# The inventory change is replicated inside this call
	# (transaction_committed), before the result below. Unless configured
	# otherwise it is not marked for a save of its own.
	_leave_to_next_save = not _settings.save_after_consume
	var result: ActionResult = ItemConsumption.try_consume(_world, player_id, item_id)
	_leave_to_next_save = false
	if not result.ok:
		if result.reason == ItemConsumption.REASON_UNAVAILABLE:
			network.reject_intent(peer_id, INTENT_CONSUME, result.reason, player_id)
		else:
			# Refusals by game state are normal play: counted, not logged as warnings.
			network.count_rejection(result.reason)
		_send_consume_result(peer_id, int(request_id), false, public_reason(result.reason))
		return
	_flush_save(SAVE_REASON_CONSUME)
	_send_consume_result(peer_id, int(request_id), true, "")
	GameLogger.info("net", "consume committed", {"peer_id": peer_id, "player_id": player_id, "entity_id": item_id, "request_id": int(request_id)})


## Server: a transaction was committed in the InventoryService. Replicates it
## now, so the send order is the commit order.
func _on_inventory_transaction(event: Dictionary) -> void:
	if network == null or not network.is_server():
		return
	var event_type: String = str(event.get("event_type", ""))
	if event_type == InventoryService.EVENT_ITEMS_DROPPED:
		_replicate_dropped(event)
	elif event_type == InventoryService.EVENT_ITEM_REMOVED:
		_replicate_removed(event)
	else:
		return  # pickups are replicated (and saved) by NetworkService itself
	if not _leave_to_next_save:
		_save_pending = true


## Items left an inventory and now lie in the world: the owner is told what
## left the inventory, every joined peer what appeared in the world.
func _replicate_dropped(event: Dictionary) -> void:
	var removed_ids: Array = []
	var world_entries: Array = []
	var dropped: Variant = event.get("item_instance_ids", [])
	for raw_id: Variant in (dropped as Array if typeof(dropped) == TYPE_ARRAY else []):
		var item_id: String = str(raw_id)
		removed_ids.append(item_id)
		var item: ItemInstance = _world.inventory.get_item(item_id)
		if item == null or item.location_type != ItemInstance.LOCATION_WORLD:
			continue
		var entry: Dictionary = _world.inventory.describe_world_item(item_id)
		# The server holds its own output to the rule its clients apply.
		if not ClientWorldState.is_valid_world_item(entry):
			GameLogger.error("net", "world item not replicated", {"entity_id": item_id, "module": MODULE_NAME, "operation": "replicate_dropped"})
			continue
		world_entries.append(entry)
	var owner_peer: int = _owner_peer(str(event.get("inventory_id", "")))
	if owner_peer != 0:
		for message: Array in _split(removed_ids):
			_rpc_inventory_items_removed.rpc_id(owner_peer, message)
	var peers: PackedInt32Array = network.joined_peers()
	for message: Array in _split(world_entries):
		for peer_id: int in peers:
			if network.can_send_to(peer_id):
				_rpc_world_items_added.rpc_id(peer_id, message)


## A quantity left an inventory: only the owner is told (the smaller stack,
## or that the item is gone).
func _replicate_removed(event: Dictionary) -> void:
	var owner_peer: int = _owner_peer(str(event.get("inventory_id", "")))
	if owner_peer == 0:
		return
	var item_id: String = str(event.get("item_instance_id", ""))
	var item: ItemInstance = _world.inventory.get_item(item_id)
	if item == null:
		_rpc_inventory_items_removed.rpc_id(owner_peer, [item_id])
		return
	var entry: Dictionary = item.to_dict()
	if not is_valid_inventory_item(entry):
		GameLogger.error("net", "inventory item not replicated", {"entity_id": item_id, "module": MODULE_NAME, "operation": "replicate_removed"})
		return
	_rpc_inventory_item_changed.rpc_id(owner_peer, entry)


## Peer of the online player whose inventory is `inventory_id`, or 0 (nobody
## online owns it, or that peer cannot be sent to).
func _owner_peer(inventory_id: String) -> int:
	for player_id: String in _world.online_player_ids():
		var state: PlayerState = _world.get_player(player_id)
		if state == null or state.inventory_id != inventory_id:
			continue
		var peer_id: int = network.peer_of_player(player_id)
		return peer_id if peer_id != 0 and network.can_send_to(peer_id) else 0
	return 0


## `entries` cut into messages of at most `max_items_per_message` entries.
func _split(entries: Array) -> Array[Array]:
	var messages: Array[Array] = []
	var per_message: int = clampi(_settings.max_items_per_message, 1, MAX_ITEMS_PER_MESSAGE)
	var offset: int = 0
	while offset < entries.size():
		var message: Array = entries.slice(offset, offset + per_message)
		offset += message.size()
		messages.append(message)
	return messages


func _send_result(peer_id: int, request_id: int, ok: bool, reason: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_drop_result.rpc_id(peer_id, request_id, ok, reason)


func _send_consume_result(peer_id: int, request_id: int, ok: bool, reason: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_consume_result.rpc_id(peer_id, request_id, ok, reason)


func _flush_save(reason: String) -> void:
	if not _save_pending or network == null or not network.is_server():
		return
	_save_pending = false
	network.persist(reason)


# ------------------------------------------------------------ client side

## Asks the server to put a carried item down where the player stands.
## Returns the request id the `drop_result` signal will carry, or NO_REQUEST
## when nothing was sent (not a joined client). Nothing is decided here.
func request_drop(item_instance_id: String) -> int:
	if network == null or not network.is_client() or network.client_state.local_player_id.is_empty():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_drop_request(_last_request_id, item_instance_id)
	return _last_request_id


## Sends an arbitrary request without any client-side check (tests:
## malformed or premature input through the real RPC path).
func send_raw_drop_request(request_id: Variant, item_instance_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_drop.rpc_id(NetworkService.SERVER_PEER_ID, request_id, item_instance_id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_drop_result(request_id: Variant, ok: Variant, reason: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if typeof(request_id) != TYPE_INT or typeof(ok) != TYPE_BOOL or typeof(reason) != TYPE_STRING:
		_reject_payload("bad_result")
		return
	var reason_code: String = reason
	# "" exactly when the request was accepted.
	if int(request_id) < 0 or reason_code.length() > REASON_MAX_LENGTH or bool(ok) != reason_code.is_empty():
		_reject_payload("bad_result")
		return
	drop_result.emit(int(request_id), bool(ok), reason_code)


## Asks the server to eat / drink one unit of a carried item. Returns the
## request id the `consume_result` signal will carry, or NO_REQUEST when
## nothing was sent (not a joined client). Nothing is decided here.
func request_consume(item_instance_id: String) -> int:
	if network == null or not network.is_client() or network.client_state.local_player_id.is_empty():
		return NO_REQUEST
	_last_consume_request_id += 1
	send_raw_consume_request(_last_consume_request_id, item_instance_id)
	return _last_consume_request_id


## Sends an arbitrary request without any client-side check (tests:
## malformed or premature input through the real RPC path).
func send_raw_consume_request(request_id: Variant, item_instance_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_consume.rpc_id(NetworkService.SERVER_PEER_ID, request_id, item_instance_id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_consume_result(request_id: Variant, ok: Variant, reason: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if typeof(request_id) != TYPE_INT or typeof(ok) != TYPE_BOOL or typeof(reason) != TYPE_STRING:
		_reject_payload("bad_result")
		return
	var reason_code: String = reason
	# "" exactly when the request was accepted.
	if int(request_id) < 0 or reason_code.length() > REASON_MAX_LENGTH or bool(ok) != reason_code.is_empty():
		_reject_payload("bad_result")
		return
	consume_result.emit(int(request_id), bool(ok), reason_code)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_world_items_added(payload: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if typeof(payload) != TYPE_ARRAY or (payload as Array).size() > MAX_ITEMS_PER_MESSAGE:
		_reject_payload("bad_world_items")
		return
	var added: PackedStringArray = []
	for entry: Variant in payload as Array:
		if typeof(entry) != TYPE_DICTIONARY or not network.client_state.apply_world_item_added(entry as Dictionary):
			_reject_payload("bad_world_item")
			continue
		added.append(str((entry as Dictionary)[ClientWorldState.KEY_ITEM_ID]))
	if not added.is_empty():
		world_items_added.emit(added)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_inventory_items_removed(payload: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	owner_message_count += 1
	if typeof(payload) != TYPE_ARRAY or (payload as Array).size() > MAX_ITEMS_PER_MESSAGE:
		_reject_payload("bad_removed_items")
		return
	var removed: PackedStringArray = []
	for entry: Variant in payload as Array:
		if not _is_valid_item_id(entry):
			_reject_payload("bad_removed_item")
			continue
		if network.client_state.apply_inventory_item_removed(str(entry)):
			removed.append(str(entry))
	if not removed.is_empty():
		inventory_items_removed.emit(removed)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_inventory_item_changed(item: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	owner_message_count += 1
	if not is_valid_inventory_item(item) or not network.client_state.apply_inventory_item(item as Dictionary):
		_reject_payload("bad_inventory_item")
		return
	inventory_item_changed.emit(str((item as Dictionary)["item_instance_id"]))


func _reject_payload(reason: String) -> void:
	rejected_payload_count += 1
	GameLogger.warning("net", "inventory payload dropped", {"reason": reason, "module": MODULE_NAME, "operation": "apply_payload"})
