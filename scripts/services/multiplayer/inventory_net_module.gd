class_name InventoryNetModule
extends NetModule
## Drop and consume intents and replication of inventory changes (P2-T2,
## P2-T3; docs/09 §14.17, §14.18). Network only: every rule is in
## InventoryService / ServerWorld / ItemConsumption.
##
## RPC table (channel 0 = reliable ordered, the channel of the pickup RPCs):
##   client -> server  _rpc_request_drop(request_id:int, item_instance_id:String,
##                                        quantity:int)                                reliable, ch0
##   server -> owner   _rpc_drop_result(request_id:int, ok:bool, reason:String)          reliable, ch0
##   client -> server  _rpc_request_consume(request_id:int, item_instance_id:String)    reliable, ch0
##   server -> owner   _rpc_consume_result(request_id:int, ok:bool, reason:String)       reliable, ch0
##   client -> server  _rpc_request_use_on(request_id:int, item_instance_id:String,
##                                          target_player_id:String)                     reliable, ch0
##   server -> owner   _rpc_use_on_result(request_id:int, ok:bool, reason:String)        reliable, ch0
##   server -> clients _rpc_treatment_notice(notice:Dictionary)                          reliable, ch0
##   server -> clients _rpc_world_items_added(items:Array[Dictionary])                   reliable, ch0
##   server -> clients _rpc_world_items_removed(item_instance_ids:Array[String])         reliable, ch0
##   server -> owner   _rpc_inventory_items_removed(item_instance_ids:Array[String])     reliable, ch0
##   server -> owner   _rpc_inventory_item_changed(item:Dictionary /* ItemInstance */)   reliable, ch0
##
## Consume = use up one unit of a carried item (eat / drink, P2-T3; bandage,
## P2-T6; cure, P2-T7): the same shape as a drop request: a request id and
## the id of a carried item, nothing else. There is no target, wound or
## effect argument: the effect comes from the item definition on the server
## and is applied to the requester (ItemConsumption). Checks, in order:
## joined, argument types, request id >= 0, item id length, request rate (its
## own bucket), then the rule (`player_dead`, `item_not_in_inventory`,
## `not_consumable`, `not_bleeding`, `not_infected`, `too_late`, ...). The
## result goes to the requester only. The smaller stack / the vanished item
## reaches the owner through the replication below and the effect (lower
## needs, a wound that no longer bleeds, a cleared infection) through the
## owner's survival events and snapshot; other players are told nothing
## about it. An accepted use is not saved on its own
## (InventoryNetSettings.save_after_consume, docs/15 P2-123).
##
## Use on another player (P2-T12, docs/09 §14.27): the consume intent with
## one more argument, the id of the player to treat ("" or the own id = use
## it on myself, exactly the consume intent). The client names the target
## only; where the two players are, whether the target is alive and what it
## needs is server state (ItemConsumption.try_use_on). Checks, in order:
## joined, argument types, request id >= 0, item id length, target id length
## (`bad_target_id`), request rate (the consume bucket), then the rule
## (`not_usable_on_others`, `target_unavailable`, `target_dead`,
## `target_too_far`, `not_bleeding`, `not_infected`, `too_late`, ...).
## Who is told what:
##   - the requester: the result (ok / reason) and its own smaller stack.
##     The reason is all it learns about the target (`not_bleeding`: no wound
##     of the target bleeds; `not_infected` / `too_late`: about its
##     infection). Nothing else: no health, no stage name, no wound list.
##   - the target: its own survival events and snapshot as for a self-use,
##     and a notice {scope: "target", user_id, target_id, definition_id, ok,
##     reason, world_time}: who used what on it and whether it did anything.
##   - every other joined peer: a notice {scope: "public", user_id,
##     target_id, world_time}: that one player tended to another. It is sent
##     for a successful use AND for an attempt that found nothing to treat,
##     so a bystander cannot tell whether the target needed treatment.
## No notice for requests refused before the attempt (wrong item, target
## away, dead or too far) and none for a use on oneself.
##
## Drop request: a client sends an intent only: its own request id, the id
## of the item to put down and how many units of it (P2-T15:
## InventoryService.WHOLE_STACK = the whole stack as the server knows it, or
## 1..the stack; a part of a stack becomes a new item lying in the world).
## There is no position or owner argument; the actor is the player of the
## sending peer and the item lands where the server knows that player to be.
## Server checks, in order: joined (`not_joined`), argument types
## (`bad_type`), request id >= 0 (`bad_sequence`), item id length
## (`bad_item_id`), quantity >= 0 (`bad_quantity`), request rate
## (`rate_limited`), the player is alive (`player_dead`), then the
## transaction's own rules (`item_not_in_inventory`, `bad_quantity` for more
## units than the stack holds, ...). Every refusal is counted
## (NetworkService.rejected_intent_count) and changes nothing.
##
## Items travel between players over the ground (docs/00 ADR-021): one
## player puts them down, another picks them up. No request of this module
## puts an item into another player's inventory (the hand-over intent of
## P2-T14 was withdrawn in P2-T15).
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
## the world goes to the joined peers that are told about the cell it lies in
## (P3-2, NetworkService.peers_interested_in; definition, quantity,
## position); an item that leaves an inventory or changes its quantity goes
## to the owner only. Nobody is sent another player's inventory. Late joiners
## get the world items of their cells and their own inventory in the join
## snapshot (NetworkService).
##
## Scope by cell (P3-2, docs/09 §15.2): when a peer gains or loses a cell,
## WorldCellNetModule sends that cell's world items through
## send_world_items_added() / send_world_items_removed(), the two public
## server functions of this module. A removal by cell is one message for many
## items (_rpc_world_items_removed); the removal of a single picked-up item
## is still NetworkService's _rpc_world_item_removed.
## A pickup is replicated by NetworkService itself (the picked-up item, the
## result, the item leaving the world); this module adds the carried stacks
## that grew because the picked-up units merged into them (P2-T15), sent to
## the owner before NetworkService's own messages.
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
## Client: answer to one of this client's own use-on-a-player requests.
signal use_on_result(request_id: int, ok: bool, reason: String)
## Client: a validated treatment notice arrived (see the header): this
## client's player was treated (scope "target") or it saw one player tend to
## another (scope "public").
signal treatment_seen(notice: Dictionary)
## Client: these items now lie in the world (already in the mirror).
signal world_items_added(item_instance_ids: PackedStringArray)
## Client: these items left the mirror because this client is no longer told
## about the cell they lie in (P3-2). They still lie in the world.
signal world_items_removed(item_instance_ids: PackedStringArray)
## Client: these items left the local inventory (already out of the mirror).
signal inventory_items_removed(item_instance_ids: PackedStringArray)
## Client: an item of the local inventory was added or changed (quantity).
signal inventory_item_changed(item_instance_id: String)

const MODULE_NAME: String = "InventoryNet"
## Intent name in rejection logs.
const INTENT_DROP: String = "drop_item"
const INTENT_CONSUME: String = "consume_item"
const INTENT_USE_ON: String = "use_item_on"
## The target argument of a use-on request is not a usable player id.
const REASON_BAD_TARGET_ID: String = "bad_target_id"
## Treatment notice scopes and keys (P2-T12).
const NOTICE_SCOPE_TARGET: String = "target"
const NOTICE_SCOPE_PUBLIC: String = "public"
const NOTICE_TARGET_KEYS: Array = ["scope", "user_id", "target_id", "definition_id", "ok", "reason", "world_time"]
const NOTICE_PUBLIC_KEYS: Array = ["scope", "user_id", "target_id", "world_time"]
## Client: treatment notices kept for the presentation (oldest dropped).
const MAX_RECENT_NOTICES: int = 16
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
## Client (diagnostics, P3-2): world item messages received from the server
## and the world items they announced as added / as removed by cell.
var world_item_message_count: int = 0
var received_world_item_add_count: int = 0
var received_world_item_remove_count: int = 0

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
var _last_use_on_request_id: int = NO_REQUEST
## Client: the newest validated treatment notices, oldest first.
var _recent_notices: Array[Dictionary] = []


func _init(settings: InventoryNetSettings) -> void:
	name = MODULE_NAME
	_settings = settings


func _exit_tree() -> void:
	if _world != null and _world.inventory.transaction_committed.is_connected(_on_inventory_transaction):
		_world.inventory.transaction_committed.disconnect(_on_inventory_transaction)


# ------------------------------------------------------------ pure rules

## "" when the arguments of a drop request are usable, otherwise a reason
## code. Types first; the item part follows the pickup request; the quantity
## is InventoryService.WHOLE_STACK or at least 1 (how many the stack holds is
## the transaction's check).
static func validate_drop_request(request_id: Variant, item_instance_id: Variant, quantity: Variant = InventoryService.WHOLE_STACK) -> String:
	if typeof(quantity) != TYPE_INT:
		return IntentValidator.REASON_BAD_TYPE
	var reason: String = IntentValidator.validate_pickup(request_id, item_instance_id)
	if not reason.is_empty():
		return reason
	if int(quantity) < InventoryService.WHOLE_STACK:
		return InventoryService.REASON_BAD_QUANTITY
	return ""


## "" when the arguments of a consume request are usable, otherwise a reason
## code. Same shape and rules as a drop request.
static func validate_consume_request(request_id: Variant, item_instance_id: Variant) -> String:
	return IntentValidator.validate_pickup(request_id, item_instance_id)


## "" when the arguments of a use-on-a-player request are usable, otherwise
## a reason code. The item part follows the consume request; the target is a
## String, "" (myself) or a player id of bounded length.
static func validate_use_on_request(request_id: Variant, item_instance_id: Variant, target_player_id: Variant) -> String:
	if typeof(target_player_id) != TYPE_STRING:
		return IntentValidator.REASON_BAD_TYPE
	var reason: String = IntentValidator.validate_pickup(request_id, item_instance_id)
	if not reason.is_empty():
		return reason
	if str(target_player_id).length() > IntentValidator.ENTITY_ID_MAX_LENGTH:
		return REASON_BAD_TARGET_ID
	return ""


## True when `notice` is a treatment notice as the server sends it to the
## player `local_player_id`: exact keys for its scope, bounded strings, two
## different players, and the right addressee (the target gets "target", a
## bystander "public"; the user gets neither).
static func is_valid_treatment_notice(notice: Variant, local_player_id: String) -> bool:
	if typeof(notice) != TYPE_DICTIONARY:
		return false
	var data: Dictionary = notice
	var scope: Variant = data.get("scope", null)
	if typeof(scope) != TYPE_STRING or (scope != NOTICE_SCOPE_TARGET and scope != NOTICE_SCOPE_PUBLIC):
		return false
	var expected: Array = NOTICE_TARGET_KEYS if scope == NOTICE_SCOPE_TARGET else NOTICE_PUBLIC_KEYS
	if data.size() != expected.size():
		return false
	for key: Variant in data.keys():
		if typeof(key) != TYPE_STRING or not expected.has(key):
			return false
	if not _is_valid_item_id(data["user_id"]) or not _is_valid_item_id(data["target_id"]) or data["user_id"] == data["target_id"]:
		return false
	var world_time: Variant = data["world_time"]
	if not (typeof(world_time) == TYPE_FLOAT or typeof(world_time) == TYPE_INT) or not is_finite(float(world_time)) or float(world_time) < 0.0:
		return false
	if scope == NOTICE_SCOPE_PUBLIC:
		return data["user_id"] != local_player_id and data["target_id"] != local_player_id
	if data["target_id"] != local_player_id:
		return false
	if typeof(data["definition_id"]) != TYPE_STRING or str(data["definition_id"]).length() > ClientWorldState.ITEM_ID_MAX_LENGTH or not ItemInstance.is_valid_definition_id(str(data["definition_id"])):
		return false
	if typeof(data["ok"]) != TYPE_BOOL or typeof(data["reason"]) != TYPE_STRING:
		return false
	# "" exactly when the use did something.
	return str(data["reason"]).length() <= REASON_MAX_LENGTH and bool(data["ok"]) == str(data["reason"]).is_empty()


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
	_last_use_on_request_id = NO_REQUEST
	_recent_notices.clear()


# ------------------------------------------------------------ server side

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_drop(request_id: Variant, item_instance_id: Variant, quantity: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The actor is whoever owns the sending peer, never an argument.
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, INTENT_DROP, NetworkService.NOT_JOINED)
		return
	var reason: String = validate_drop_request(request_id, item_instance_id, quantity)
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
	# (A player without a character is not in the world: it is refused as
	# "not_online" by try_drop_item below, not as dead. P2-T9.)
	if _survival != null and _world.is_online(player_id) and not _survival.is_alive(player_id):
		network.count_rejection(REASON_PLAYER_DEAD)
		_send_result(peer_id, int(request_id), false, REASON_PLAYER_DEAD)
		return
	var item_id: String = str(item_instance_id)
	# Replication happens inside this call (transaction_committed), before
	# the result below.
	var result: ActionResult = _world.try_drop_item(player_id, item_id, int(quantity))
	if not result.ok:
		network.count_rejection(result.reason)
		_send_result(peer_id, int(request_id), false, public_reason(result.reason))
		return
	_flush_save(SAVE_REASON_DROP)
	_send_result(peer_id, int(request_id), true, "")
	GameLogger.info("net", "drop committed", {"peer_id": peer_id, "player_id": player_id, "entity_id": item_id, "quantity": int(quantity), "request_id": int(request_id)})


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


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_use_on(request_id: Variant, item_instance_id: Variant, target_player_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The actor is whoever owns the sending peer, never an argument. The
	# target is only a name: everything about it is read from the server.
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, INTENT_USE_ON, NetworkService.NOT_JOINED)
		return
	var reason: String = validate_use_on_request(request_id, item_instance_id, target_player_id)
	if not reason.is_empty():
		network.reject_intent(peer_id, INTENT_USE_ON, reason, player_id)
		if typeof(request_id) == TYPE_INT and int(request_id) >= 0:
			_send_use_on_result(peer_id, int(request_id), false, reason)
		return
	# Using an item on somebody is a use: it shares the consume allowance.
	if not _consume_limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, INTENT_USE_ON, NetworkService.RATE_LIMITED, player_id)
		_send_use_on_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED)
		return
	var item_id: String = str(item_instance_id)
	var target_id: String = str(target_player_id)
	var on_other: bool = target_id != ItemConsumption.NO_TARGET and target_id != player_id
	# For the target's notice (the item may be gone after the use).
	var item: ItemInstance = _world.inventory.get_item(item_id)
	var definition_id: String = item.definition_id if item != null else ""
	_leave_to_next_save = not _settings.save_after_consume
	var result: ActionResult = ItemConsumption.try_use_on(_world, player_id, item_id, target_id)
	_leave_to_next_save = false
	if not result.ok:
		if result.reason == ItemConsumption.REASON_UNAVAILABLE:
			network.reject_intent(peer_id, INTENT_USE_ON, result.reason, player_id)
		else:
			# Refusals by game state are normal play: counted, not logged as warnings.
			network.count_rejection(result.reason)
		# An attempt that found nothing to treat was still made next to the
		# target: the target and bystanders see it like a successful one.
		if on_other and ItemConsumption.is_target_state_refusal(result.reason):
			_send_treatment_notices(player_id, target_id, definition_id, false, result.reason)
		_send_use_on_result(peer_id, int(request_id), false, public_reason(result.reason))
		return
	_flush_save(SAVE_REASON_CONSUME)
	if on_other:
		_send_treatment_notices(player_id, target_id, definition_id, true, "")
	_send_use_on_result(peer_id, int(request_id), true, "")
	GameLogger.info("net", "use on player committed", {"peer_id": peer_id, "player_id": player_id, "target_id": target_id, "entity_id": item_id, "request_id": int(request_id)})


## Tells the target who used what on it and whether it did anything, and
## every other joined peer except the user that the one tended to the other.
## Nothing about the target's condition leaves the server to a bystander.
func _send_treatment_notices(user_id: String, target_id: String, definition_id: String, ok: bool, reason: String) -> void:
	var world_time: float = _world.clock.world_time_sec
	var target_notice: Dictionary = {"scope": NOTICE_SCOPE_TARGET, "user_id": user_id, "target_id": target_id, "definition_id": definition_id, "ok": ok, "reason": reason, "world_time": world_time}
	var public_notice: Dictionary = {"scope": NOTICE_SCOPE_PUBLIC, "user_id": user_id, "target_id": target_id, "world_time": world_time}
	var user_peer: int = network.peer_of_player(user_id)
	var target_peer: int = network.peer_of_player(target_id)
	for peer_id: int in network.joined_peers():
		if peer_id == user_peer or not network.can_send_to(peer_id):
			continue
		if peer_id == target_peer:
			# The server holds its own output to the rule its clients apply.
			if is_valid_treatment_notice(target_notice, target_id):
				_rpc_treatment_notice.rpc_id(peer_id, target_notice)
			else:
				GameLogger.error("net", "treatment notice not sent", {"player_id": target_id, "module": MODULE_NAME, "operation": "send_treatment_notices"})
		else:
			_rpc_treatment_notice.rpc_id(peer_id, public_notice)


func _send_use_on_result(peer_id: int, request_id: int, ok: bool, reason: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_use_on_result.rpc_id(peer_id, request_id, ok, reason)


## Server: a transaction was committed in the InventoryService. Replicates it
## now, so the send order is the commit order.
func _on_inventory_transaction(event: Dictionary) -> void:
	if network == null or not network.is_server():
		return
	var event_type: String = str(event.get("event_type", ""))
	if event_type == InventoryService.EVENT_ITEMS_DROPPED:
		_replicate_dropped(event)
	elif event_type == InventoryService.EVENT_ITEM_UNITS_DROPPED:
		_replicate_units_dropped(event)
	elif event_type == InventoryService.EVENT_ITEM_REMOVED:
		_replicate_removed(event)
	elif event_type == InventoryService.EVENT_ITEM_TRANSFERRED:
		_replicate_transferred(event)
	elif event_type == InventoryService.EVENT_ITEMS_EXCHANGED:
		_replicate_exchanged(event)
	elif event_type == InventoryService.EVENT_ITEM_PICKED_UP:
		# The pickup itself is replicated (and saved) by NetworkService; only
		# the carried stacks that grew are sent from here.
		_replicate_merged(event)
		return
	elif event_type == InventoryService.EVENT_ITEMS_TAKEN:
		# P3-5: materials went into a structure. Replicated to the owner; no
		# save is scheduled here (whoever took them decides, docs/00 ADR-025).
		_replicate_taken(event)
		return
	else:
		return
	if not _leave_to_next_save:
		_save_pending = true


## Units of carried stacks went into something that is not an item any more
## (InventoryService.take_items, P3-5: materials delivered to a structure).
## Only the owner is told: its smaller stacks, and the stacks that are gone.
func _replicate_taken(event: Dictionary) -> void:
	var inventory_id: String = str(event.get("inventory_id", ""))
	var owner_peer: int = _owner_peer(inventory_id)
	if owner_peer == 0:
		return
	var gone: Array = []
	var taken: Variant = event.get("taken", [])
	for entry: Variant in (taken as Array if typeof(taken) == TYPE_ARRAY else []):
		var item_id: String = str((entry as Dictionary).get("item_instance_id", "")) if typeof(entry) == TYPE_DICTIONARY else ""
		var item: ItemInstance = _world.inventory.get_item(item_id)
		# Only what is in that inventory now is ever sent to its owner.
		if item != null and item.location_type == ItemInstance.LOCATION_INVENTORY and item.location_id == inventory_id:
			_send_inventory_item(owner_peer, item)
		elif not item_id.is_empty():
			gone.append(item_id)
	for message: Array in _split(gone):
		_rpc_inventory_items_removed.rpc_id(owner_peer, message)


## Items left an inventory and now lie in the world: the owner is told what
## left the inventory, the peers that are told about that cell (P3-2) what
## appeared in the world.
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
	var peers: PackedInt32Array = network.peers_interested_in(str(event.get("cell_id", "")))
	for message: Array in _split(world_entries):
		for peer_id: int in peers:
			if network.can_send_to(peer_id):
				_rpc_world_items_added.rpc_id(peer_id, message)


## A part of a stack was put down (P2-T15): the owner is told its smaller
## stack, the peers that are told about that cell (P3-2) the new item that
## lies in the world.
func _replicate_units_dropped(event: Dictionary) -> void:
	var inventory_id: String = str(event.get("inventory_id", ""))
	var owner_peer: int = _owner_peer(inventory_id)
	var carried: ItemInstance = _world.inventory.get_item(str(event.get("item_instance_id", "")))
	if owner_peer != 0 and carried != null and carried.location_type == ItemInstance.LOCATION_INVENTORY and carried.location_id == inventory_id:
		_send_inventory_item(owner_peer, carried)
	var lying_id: String = str(event.get("world_item_instance_id", ""))
	var lying: ItemInstance = _world.inventory.get_item(lying_id)
	if lying == null or lying.location_type != ItemInstance.LOCATION_WORLD:
		return
	var entry: Dictionary = _world.inventory.describe_world_item(lying_id)
	# The server holds its own output to the rule its clients apply.
	if not ClientWorldState.is_valid_world_item(entry):
		GameLogger.error("net", "world item not replicated", {"entity_id": lying_id, "module": MODULE_NAME, "operation": "replicate_units_dropped"})
		return
	for peer_id: int in network.peers_interested_in(str(event.get("cell_id", ""))):
		if network.can_send_to(peer_id):
			_rpc_world_items_added.rpc_id(peer_id, [entry])


## Picked-up units merged into carried stacks (P2-T15): the owner is told
## the stacks that grew. Nobody else is told anything about them.
func _replicate_merged(event: Dictionary) -> void:
	var inventory_id: String = str(event.get("inventory_id", ""))
	var owner_peer: int = _owner_peer(inventory_id)
	if owner_peer == 0:
		return
	var merged: Variant = event.get("merged", [])
	for entry: Variant in (merged as Array if typeof(merged) == TYPE_ARRAY else []):
		var grown: ItemInstance = _world.inventory.get_item(str((entry as Dictionary).get("item_instance_id", ""))) if typeof(entry) == TYPE_DICTIONARY else null
		# Only what is in that inventory now is ever sent to its owner.
		if grown == null or grown.location_type != ItemInstance.LOCATION_INVENTORY or grown.location_id != inventory_id:
			GameLogger.error("net", "merged stack not replicated", {"entity_id": str(event.get("item_instance_id", "")), "module": MODULE_NAME, "operation": "replicate_merged"})
			continue
		_send_inventory_item(owner_peer, grown)


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


## Units moved from one inventory into another (InventoryService.
## transfer_item; a server rule, no player intent calls it since P2-T15):
## the owner of the giving inventory is told its own change (the smaller
## stack, or that the stack left), the owner of the receiving one its stacks
## that grew or arrived. Each owner is sent its own inventory only, and
## nobody else is sent anything.
func _replicate_transferred(event: Dictionary) -> void:
	var item_id: String = str(event.get("item_instance_id", ""))
	var from_id: String = str(event.get("from_inventory_id", ""))
	var giver_peer: int = _owner_peer(from_id)
	if giver_peer != 0:
		var item: ItemInstance = _world.inventory.get_item(item_id)
		if item == null or item.location_type != ItemInstance.LOCATION_INVENTORY or item.location_id != from_id:
			_rpc_inventory_items_removed.rpc_id(giver_peer, [item_id])
		else:
			_send_inventory_item(giver_peer, item)
	var to_id: String = str(event.get("to_inventory_id", ""))
	var receiver_peer: int = _owner_peer(to_id)
	if receiver_peer == 0:
		return
	var received: Variant = event.get("received", [])
	for entry: Variant in (received as Array if typeof(received) == TYPE_ARRAY else []):
		var arrived: ItemInstance = _world.inventory.get_item(str((entry as Dictionary).get("item_instance_id", ""))) if typeof(entry) == TYPE_DICTIONARY else null
		# Only what is in that inventory now is ever sent to its owner.
		if arrived == null or arrived.location_type != ItemInstance.LOCATION_INVENTORY or arrived.location_id != to_id:
			GameLogger.error("net", "received item not replicated", {"entity_id": item_id, "module": MODULE_NAME, "operation": "replicate_transferred"})
			continue
		_send_inventory_item(receiver_peer, arrived)


## Two inventories gave each other items (InventoryService.exchange_items:
## a completed trade, P2-T16): each owner is told what left its inventory,
## then every stack that arrived in it or changed. Each owner is sent its
## own inventory only, and nobody else is sent anything.
func _replicate_exchanged(event: Dictionary) -> void:
	var sides: Variant = event.get("sides", [])
	for side: Variant in (sides as Array if typeof(sides) == TYPE_ARRAY else []):
		if typeof(side) != TYPE_DICTIONARY:
			continue
		var inventory_id: String = str((side as Dictionary).get("inventory_id", ""))
		var owner_peer: int = _owner_peer(inventory_id)
		if owner_peer == 0:
			continue
		var removed_ids: Array = []
		var removed: Variant = (side as Dictionary).get("removed_item_instance_ids", [])
		for raw_id: Variant in (removed as Array if typeof(removed) == TYPE_ARRAY else []):
			removed_ids.append(str(raw_id))
		for message: Array in _split(removed_ids):
			_rpc_inventory_items_removed.rpc_id(owner_peer, message)
		var changed: Variant = (side as Dictionary).get("changed_item_instance_ids", [])
		for raw_id: Variant in (changed as Array if typeof(changed) == TYPE_ARRAY else []):
			var item: ItemInstance = _world.inventory.get_item(str(raw_id))
			# Only what is in that inventory now is ever sent to its owner.
			if item == null or item.location_type != ItemInstance.LOCATION_INVENTORY or item.location_id != inventory_id:
				GameLogger.error("net", "exchanged item not replicated", {"entity_id": str(raw_id), "module": MODULE_NAME, "operation": "replicate_exchanged"})
				continue
			_send_inventory_item(owner_peer, item)


## Server (P3-2): tells one peer that these world items lie in the world
## (`entries`: InventoryService.describe_world_item() dictionaries). For the
## module that scopes world items by cell. Entries that do not fit the wire
## format are logged and left out. Returns how many items were sent.
func send_world_items_added(peer_id: int, entries: Array) -> int:
	if network == null or not network.is_server() or not network.can_send_to(peer_id):
		return 0
	var valid: Array = []
	for entry: Variant in entries:
		# The server holds its own output to the rule its clients apply.
		if not ClientWorldState.is_valid_world_item(entry):
			GameLogger.error("net", "world item not replicated", {"peer_id": peer_id, "module": MODULE_NAME, "operation": "send_world_items_added"})
			continue
		valid.append(entry)
	for message: Array in _split(valid):
		_rpc_world_items_added.rpc_id(peer_id, message)
	return valid.size()


## Server (P3-2): takes these world items out of one peer's mirror because it
## is no longer told about their cell. The items still lie in the world. For
## the module that scopes world items by cell. Returns how many ids were sent.
func send_world_items_removed(peer_id: int, item_instance_ids: Array) -> int:
	if network == null or not network.is_server() or not network.can_send_to(peer_id):
		return 0
	var valid: Array = []
	for item_instance_id: Variant in item_instance_ids:
		if not _is_valid_item_id(item_instance_id):
			GameLogger.error("net", "world item removal not replicated", {"peer_id": peer_id, "module": MODULE_NAME, "operation": "send_world_items_removed"})
			continue
		valid.append(str(item_instance_id))
	for message: Array in _split(valid):
		_rpc_world_items_removed.rpc_id(peer_id, message)
	return valid.size()


## Sends one carried item (added or changed) to the peer that owns it.
func _send_inventory_item(owner_peer: int, item: ItemInstance) -> void:
	var entry: Dictionary = item.to_dict()
	# The server holds its own output to the rule its clients apply.
	if not is_valid_inventory_item(entry):
		GameLogger.error("net", "inventory item not replicated", {"entity_id": item.item_instance_id, "module": MODULE_NAME, "operation": "send_inventory_item"})
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


## Server: saves now what committed transactions left to be saved at the
## end of this tick (nothing happens when nothing is pending). For a module
## that must have a rule's inventory change on disk before it answers the
## request that caused it (TradeNetModule: a completed trade).
func flush_pending_save(reason: String) -> void:
	_flush_save(reason)


func _flush_save(reason: String) -> void:
	if not _save_pending or network == null or not network.is_server():
		return
	_save_pending = false
	network.persist(reason)


# ------------------------------------------------------------ client side

## Asks the server to put a carried item down where the player stands:
## `quantity` units of it, or the whole stack (the default,
## InventoryService.WHOLE_STACK). Returns the request id the `drop_result`
## signal will carry, or NO_REQUEST when nothing was sent (not a joined
## client). Nothing is decided here.
func request_drop(item_instance_id: String, quantity: int = InventoryService.WHOLE_STACK) -> int:
	if network == null or not network.is_client() or network.client_state.local_player_id.is_empty():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_drop_request(_last_request_id, item_instance_id, quantity)
	return _last_request_id


## Sends an arbitrary request without any client-side check (tests:
## malformed or premature input through the real RPC path).
func send_raw_drop_request(request_id: Variant, item_instance_id: Variant, quantity: Variant = InventoryService.WHOLE_STACK) -> void:
	if network != null and network.is_client():
		_rpc_request_drop.rpc_id(NetworkService.SERVER_PEER_ID, request_id, item_instance_id, quantity)


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


## Asks the server to use one unit of a carried item on another player
## (P2-T12; "" or the own id = on myself). Returns the request id the
## `use_on_result` signal will carry, or NO_REQUEST when nothing was sent
## (not a joined client). Nothing is decided here: the target is only named.
func request_use_on(item_instance_id: String, target_player_id: String) -> int:
	if network == null or not network.is_client() or network.client_state.local_player_id.is_empty():
		return NO_REQUEST
	_last_use_on_request_id += 1
	send_raw_use_on_request(_last_use_on_request_id, item_instance_id, target_player_id)
	return _last_use_on_request_id


## Sends an arbitrary request without any client-side check (tests:
## malformed or premature input through the real RPC path).
func send_raw_use_on_request(request_id: Variant, item_instance_id: Variant, target_player_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_use_on.rpc_id(NetworkService.SERVER_PEER_ID, request_id, item_instance_id, target_player_id)


## Client: the treatment notices received so far (at most MAX_RECENT_NOTICES,
## oldest first).
func recent_treatment_notices() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for notice: Dictionary in _recent_notices:
		result.append(notice.duplicate(true))
	return result


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_use_on_result(request_id: Variant, ok: Variant, reason: Variant) -> void:
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
	use_on_result.emit(int(request_id), bool(ok), reason_code)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_treatment_notice(notice: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if not is_valid_treatment_notice(notice, network.client_state.local_player_id):
		_reject_payload("bad_treatment_notice")
		return
	var accepted: Dictionary = (notice as Dictionary).duplicate(true)
	_recent_notices.append(accepted)
	while _recent_notices.size() > MAX_RECENT_NOTICES:
		_recent_notices.pop_front()
	treatment_seen.emit(accepted.duplicate(true))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_world_items_added(payload: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	world_item_message_count += 1
	if typeof(payload) != TYPE_ARRAY or (payload as Array).size() > MAX_ITEMS_PER_MESSAGE:
		_reject_payload("bad_world_items")
		return
	var added: PackedStringArray = []
	for entry: Variant in payload as Array:
		if typeof(entry) != TYPE_DICTIONARY or not network.client_state.apply_world_item_added(entry as Dictionary):
			_reject_payload("bad_world_item")
			continue
		added.append(str((entry as Dictionary)[ClientWorldState.KEY_ITEM_ID]))
	received_world_item_add_count += added.size()
	if not added.is_empty():
		world_items_added.emit(added)


## P3-2: the world items of a cell this client is no longer told about. An id
## the mirror does not hold is skipped without complaint (the item may have
## been picked up a moment before).
@rpc("authority", "call_remote", "reliable", 0)
func _rpc_world_items_removed(payload: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	world_item_message_count += 1
	if typeof(payload) != TYPE_ARRAY or (payload as Array).size() > MAX_ITEMS_PER_MESSAGE:
		_reject_payload("bad_removed_world_items")
		return
	var ids: PackedStringArray = []
	for entry: Variant in payload as Array:
		if not _is_valid_item_id(entry):
			_reject_payload("bad_removed_world_item")
			continue
		ids.append(str(entry))
	received_world_item_remove_count += ids.size()
	var removed: PackedStringArray = network.client_state.apply_world_items_removed(ids)
	if not removed.is_empty():
		world_items_removed.emit(removed)


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
