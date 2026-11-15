class_name TradeNetModule
extends NetModule
## The trade intents and replication of trade sessions (P2-T16, docs/00
## ADR-022, docs/09 §14.30). Network only: every rule is in TradeService and
## InventoryService.exchange_items.
##
## RPC table (channel 0 = reliable ordered):
##   client -> server  _rpc_request_trade(request_id:int, target_player_id:String)     reliable, ch0
##   client -> server  _rpc_request_trade_accept(request_id:int, session_id:int)       reliable, ch0
##   client -> server  _rpc_request_trade_cancel(request_id:int, session_id:int)       reliable, ch0
##   client -> server  _rpc_request_trade_offer(request_id:int, session_id:int,
##                                               item_instance_id:String,
##                                               quantity:int)                          reliable, ch0
##   client -> server  _rpc_request_trade_confirm(request_id:int, session_id:int,
##                                                 revision:int, confirmed:bool)        reliable, ch0
##   server -> client  _rpc_trade_result(request_id:int, ok:bool, reason:String)       reliable, ch0
##   server -> party   _rpc_trade_state(state:Dictionary)                               reliable, ch0
##   server -> others  _rpc_trade_notice(notice:Dictionary)                             reliable, ch0
##
## Intents: a client sends what it WANTS and names things only: the player
## to ask, the session, a stack of its own inventory and how many units of
## it to offer (0 = take it out of the offer), the offer revision it
## confirms. The actor is always the player of the sending peer: there is
## no argument for "whose offer" or "whose confirmation", and none for a
## position, a distance or what an inventory holds. Server checks, in
## order: joined (`not_joined`), argument types (`bad_type`), request id
## >= 0 (`bad_sequence`), the other arguments (`bad_target_id`,
## `bad_session_id`, `bad_item_id`, `bad_quantity`, `bad_revision`), request
## rate (`rate_limited`, one bucket for all five intents), then the rule
## (TradeService: `target_too_far`, `target_busy`, `not_in_session`,
## `item_not_in_inventory`, `stale_offer`, ...). Every refusal is counted
## (NetworkService.rejected_intent_count) and changes nothing. The result
## goes to the requester only; `reason` is "" exactly when ok. A requester
## is never told whether an item id it does not carry exists elsewhere
## (public_reason).
##
## Replication and disclosure (docs/00 ADR-009):
##   - The two parties get the state of their session after every change
##     (_rpc_trade_state), each from its own side: its own offer with item
##     ids, the other side's offer as kind and number only. Nobody else is
##     sent a session state: a third player never sees a request, an offer
##     or a confirmation, and not that a trade was cancelled.
##   - The exchange changes two inventories; InventoryNetModule sends each
##     owner its own inventory change (owner only), before the session state.
##   - When a trade is completed, every other joined peer gets one notice
##     (_rpc_trade_notice): that the two traded. Not what, not how much, not
##     who asked.
##   - A state is sent before the result of the request that caused it (same
##     ordered channel), so a client knows the new state when the answer
##     arrives.
##
## Saving: a completed trade is saved before the session state and the
## result are sent (like a pickup and a drop). Requests, offers and
## confirmations are session state and are not saved.
##
## Client surface (presentation): request_trade(), request_accept(),
## request_cancel(), request_offer(), request_confirm(), the `trade_result`
## signal and the mirror `client_state`. The mirror has no authority.

## Client: answer to one of this client's own trade requests (of any kind).
signal trade_result(request_id: int, ok: bool, reason: String)

const MODULE_NAME: String = "TradeNet"
## Intent names in rejection logs.
const INTENT_REQUEST: String = "trade_request"
const INTENT_ACCEPT: String = "trade_accept"
const INTENT_CANCEL: String = "trade_cancel"
const INTENT_OFFER: String = "trade_offer"
const INTENT_CONFIRM: String = "trade_confirm"
## Returned by the request_*() functions when nothing was sent.
const NO_REQUEST: int = 0
## Longest reason code a client accepts in a result.
const REASON_MAX_LENGTH: int = 64
const REASON_BAD_TARGET_ID: String = "bad_target_id"
const REASON_BAD_SESSION_ID: String = "bad_session_id"
const REASON_BAD_REVISION: String = "bad_revision"
## The world has no trade system (composition error).
const REASON_UNAVAILABLE: String = "trade_unavailable"
## Save reason (logs only).
const SAVE_REASON_TRADE: String = "trade_completed"
const NOTICE_PLAYER_IDS: String = "player_ids"
const NOTICE_WORLD_TIME: String = "world_time"

var client_state: ClientTradeState = ClientTradeState.new()
## Client: results from the server that failed validation.
var rejected_payload_count: int = 0

var _settings: TradeNetSettings
# --- server state ---
var _world: ServerWorld = null
var _trade: TradeService = null
var _inventory_net: InventoryNetModule = null
var _limiter: RateLimiter = null
# --- client state ---
var _last_request_id: int = NO_REQUEST


func _init(settings: TradeNetSettings) -> void:
	name = MODULE_NAME
	_settings = settings


# ------------------------------------------------------------ pure rules

## "" when the arguments of a trade request are usable, otherwise a reason
## code. Types first, so wrongly typed input never reaches a conversion.
static func validate_trade_request(request_id: Variant, target_player_id: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(target_player_id) != TYPE_STRING:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	if not _is_id(target_player_id):
		return REASON_BAD_TARGET_ID
	return ""


## "" when the arguments of an accept or a cancel request are usable.
static func validate_session_request(request_id: Variant, session_id: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(session_id) != TYPE_INT:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	if int(session_id) < 1:
		return REASON_BAD_SESSION_ID
	return ""


## "" when the arguments of an offer request are usable. The quantity is 0
## (take the stack out of the offer) or more; how many units the stack
## holds is the rule's check.
static func validate_offer_request(request_id: Variant, session_id: Variant, item_instance_id: Variant, quantity: Variant) -> String:
	if typeof(item_instance_id) != TYPE_STRING or typeof(quantity) != TYPE_INT:
		return IntentValidator.REASON_BAD_TYPE
	var reason: String = validate_session_request(request_id, session_id)
	if not reason.is_empty():
		return reason
	if not _is_id(item_instance_id):
		return IntentValidator.REASON_BAD_ITEM_ID
	if int(quantity) < 0:
		return InventoryService.REASON_BAD_QUANTITY
	return ""


## "" when the arguments of a confirm request are usable.
static func validate_confirm_request(request_id: Variant, session_id: Variant, revision: Variant, confirmed: Variant) -> String:
	if typeof(revision) != TYPE_INT or typeof(confirmed) != TYPE_BOOL:
		return IntentValidator.REASON_BAD_TYPE
	var reason: String = validate_session_request(request_id, session_id)
	if not reason.is_empty():
		return reason
	if int(revision) < 0:
		return REASON_BAD_REVISION
	return ""


## The reason code a requester is told. An id that does not exist is
## reported like an id the requester does not carry, so a client cannot
## probe which item ids exist in other inventories.
static func public_reason(reason: String) -> String:
	if reason == InventoryService.REASON_UNKNOWN_ITEM:
		return InventoryService.REASON_NOT_IN_INVENTORY
	return reason


## The state of a session as the party `player_id` is sent it, from a
## TradeService event (see ClientTradeState): its own offer with item ids,
## the other side's offer as kind and number only.
static func party_state(event: Dictionary, player_id: String) -> Dictionary:
	var session: Dictionary = event.get("session", {})
	var other_id: String = str(session.get("target_id", "")) if player_id == str(session.get("requester_id", "")) else str(session.get("requester_id", ""))
	var offers: Dictionary = session.get("offers", {})
	var confirmed: Dictionary = session.get("confirmed", {})
	var mine: Array = []
	for entry: Dictionary in offers.get(player_id, []):
		mine.append({"item_instance_id": str(entry[TradeSession.KEY_ITEM_ID]), "definition_id": str(entry[TradeSession.KEY_DEFINITION_ID]), "quantity": int(entry[TradeSession.KEY_QUANTITY])})
	var theirs: Array = []
	for entry: Dictionary in offers.get(other_id, []):
		theirs.append({"definition_id": str(entry[TradeSession.KEY_DEFINITION_ID]), "quantity": int(entry[TradeSession.KEY_QUANTITY])})
	return {
		"session_id": int(session.get("session_id", 0)),
		"phase": str(session.get("phase", "")),
		"requester_id": str(session.get("requester_id", "")),
		"target_id": str(session.get("target_id", "")),
		"revision": int(session.get("revision", 0)),
		"my_offer": mine,
		"their_offer": theirs,
		"my_confirmed": confirmed.get(player_id, false) == true,
		"their_confirmed": confirmed.get(other_id, false) == true,
		"change": str(event.get("change", "")),
		"outcome": str(session.get("outcome", "")),
		"cause": str(session.get("cause", "")),
		"by_player_id": str(session.get("by_player_id", "")),
		"world_time": float(event.get("world_time", 0.0)),
	}


## What a bystander is told about a completed trade: who traded (in id
## order, so not who asked) and when.
static func public_notice(event: Dictionary) -> Dictionary:
	var session: Dictionary = event.get("session", {})
	var ids: Array = [str(session.get("requester_id", "")), str(session.get("target_id", ""))]
	ids.sort()
	return {NOTICE_PLAYER_IDS: ids, NOTICE_WORLD_TIME: float(event.get("world_time", 0.0))}


static func _is_id(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and not str(value).is_empty() and str(value).length() <= IntentValidator.ENTITY_ID_MAX_LENGTH


# ------------------------------------------------------------ NetModule hooks

func on_server_started(world: ServerWorld) -> void:
	_world = world
	_trade = world.get_system(TradeService.SYSTEM_ID) as TradeService
	_inventory_net = network.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	_limiter = RateLimiter.new(_settings.trade_intent_rate_per_sec, _settings.trade_intent_burst)


## A peer left: its request or session was cancelled by the world
## (TradeService.on_player_offline); the other party is told now.
func on_player_left(peer_id: int, _player_id: String) -> void:
	if _limiter != null:
		_limiter.forget(peer_id)
	_flush_events()


## Server: sends what the trade system did by itself in this tick
## (timeouts, a party that died, slept or walked away).
func server_physics(_delta: float) -> void:
	_flush_events()


func apply_join_fragment(_fragment: Dictionary) -> void:
	_last_request_id = NO_REQUEST
	client_state.apply_join(network.client_state.local_player_id)


# ------------------------------------------------------------ server side

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_trade(request_id: Variant, target_player_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_REQUEST, request_id, validate_trade_request(request_id, target_player_id))
	if not player_id.is_empty():
		# The target is only a name: everything about it is read from the server.
		_finish(int(request_id), _trade.request_trade(_world, player_id, str(target_player_id)))


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_trade_accept(request_id: Variant, session_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_ACCEPT, request_id, validate_session_request(request_id, session_id))
	if not player_id.is_empty():
		_finish(int(request_id), _trade.accept(_world, player_id, int(session_id)))


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_trade_cancel(request_id: Variant, session_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_CANCEL, request_id, validate_session_request(request_id, session_id))
	if not player_id.is_empty():
		_finish(int(request_id), _trade.cancel(_world, player_id, int(session_id)))


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_trade_offer(request_id: Variant, session_id: Variant, item_instance_id: Variant, quantity: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_OFFER, request_id, validate_offer_request(request_id, session_id, item_instance_id, quantity))
	if not player_id.is_empty():
		# Whose offer it is, is never an argument: the sending peer's player.
		_finish(int(request_id), _trade.set_offer(_world, player_id, int(session_id), str(item_instance_id), int(quantity)))


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_trade_confirm(request_id: Variant, session_id: Variant, revision: Variant, confirmed: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_CONFIRM, request_id, validate_confirm_request(request_id, session_id, revision, confirmed))
	if not player_id.is_empty():
		# The exchange (when this confirmation completes the pair) happens
		# inside this call; both inventories are replicated to their owners by
		# InventoryNetModule before the session states below.
		_finish(int(request_id), _trade.set_confirmed(_world, player_id, int(session_id), int(revision), bool(confirmed)))


## The checks every trade intent starts with (see the header). Returns the
## player of the sending peer, or "" when the request was refused (counted,
## logged and answered where it can be). Call only inside an RPC handler.
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
	if not _limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, intent, NetworkService.RATE_LIMITED, player_id)
		_send_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED)
		return ""
	if _trade == null:
		network.reject_intent(peer_id, intent, REASON_UNAVAILABLE, player_id)
		_send_result(peer_id, int(request_id), false, REASON_UNAVAILABLE)
		return ""
	return player_id


## Sends what the rule changed, then the answer. Call only inside an RPC
## handler.
func _finish(request_id: int, result: ActionResult) -> void:
	var peer_id: int = multiplayer.get_remote_sender_id()
	# Everybody concerned learns the new state before the requester gets the
	# answer (same ordered channel).
	_flush_events()
	if not result.ok:
		# Refusals by game state are normal play: counted, not logged as warnings.
		network.count_rejection(result.reason)
		_send_result(peer_id, request_id, false, public_reason(result.reason))
		return
	_send_result(peer_id, request_id, true, "")


## Sends every pending session event: its state to the two parties (each
## from its own side) and, for a completed trade, a notice to everybody
## else. A completed trade is saved first.
func _flush_events() -> void:
	if _trade == null or network == null or not network.is_server():
		return
	for event: Dictionary in _trade.drain_events():
		var session: Dictionary = event.get("session", {})
		var parties: Array[String] = [str(session.get("requester_id", "")), str(session.get("target_id", ""))]
		var completed: bool = str(event.get("change", "")) == TradeService.CHANGE_CLOSED and str(session.get("outcome", "")) == TradeSession.OUTCOME_COMPLETED
		if completed:
			_save_completed_trade()
		for player_id: String in parties:
			var peer_id: int = network.peer_of_player(player_id)
			if peer_id == 0 or not network.can_send_to(peer_id):
				continue
			var state: Dictionary = party_state(event, player_id)
			# The server holds its own output to the rule its clients apply.
			if not ClientTradeState.is_valid_state(state, player_id):
				GameLogger.error("net", "trade state not sent", {"player_id": player_id, "module": MODULE_NAME, "operation": "flush_events"})
				continue
			_rpc_trade_state.rpc_id(peer_id, state)
		if completed:
			_send_notices(event, parties)


## A completed trade changed two inventories: the world is saved at once.
func _save_completed_trade() -> void:
	if _inventory_net != null:
		_inventory_net.flush_pending_save(SAVE_REASON_TRADE)
	else:
		network.persist(SAVE_REASON_TRADE)


## Tells every joined peer that is no party of the trade that the two
## traded. Nothing about what was exchanged leaves the server to them.
func _send_notices(event: Dictionary, parties: Array[String]) -> void:
	var notice: Dictionary = public_notice(event)
	for peer_id: int in network.joined_peers():
		var player_id: String = network.player_of_peer(peer_id)
		if parties.has(player_id) or not network.can_send_to(peer_id):
			continue
		# The server holds its own output to the rule its clients apply.
		if not ClientTradeState.is_valid_notice(notice, player_id):
			GameLogger.error("net", "trade notice not sent", {"player_id": player_id, "module": MODULE_NAME, "operation": "send_notices"})
			continue
		_rpc_trade_notice.rpc_id(peer_id, notice)


func _send_result(peer_id: int, request_id: int, ok: bool, reason: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_trade_result.rpc_id(peer_id, request_id, ok, reason)


# ------------------------------------------------------------ client side

## Asks the server to ask `target_player_id` for a trade. Returns the
## request id the `trade_result` signal will carry, or NO_REQUEST when
## nothing was sent (not a joined client). Nothing is decided here; the same
## goes for the four functions below.
func request_trade(target_player_id: String) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_trade_request(_last_request_id, target_player_id)
	return _last_request_id


## Accepts the pending request `session_id` addressed to the local player.
func request_accept(session_id: int) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_accept_request(_last_request_id, session_id)
	return _last_request_id


## Declines / withdraws the request or cancels the session `session_id`.
func request_cancel(session_id: int) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_cancel_request(_last_request_id, session_id)
	return _last_request_id


## Offers `quantity` units of the carried stack `item_instance_id` in the
## session `session_id` (0 = take the stack out of the offer).
func request_offer(session_id: int, item_instance_id: String, quantity: int) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_offer_request(_last_request_id, session_id, item_instance_id, quantity)
	return _last_request_id


## Confirms the offers of the session `session_id` as they are at
## `revision`, or takes the confirmation back (`confirmed` false).
func request_confirm(session_id: int, revision: int, confirmed: bool) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_confirm_request(_last_request_id, session_id, revision, confirmed)
	return _last_request_id


## The send_raw_* functions send an arbitrary request without any
## client-side check (tests: malformed or premature input through the real
## RPC path).
func send_raw_trade_request(request_id: Variant, target_player_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_trade.rpc_id(NetworkService.SERVER_PEER_ID, request_id, target_player_id)


func send_raw_accept_request(request_id: Variant, session_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_trade_accept.rpc_id(NetworkService.SERVER_PEER_ID, request_id, session_id)


func send_raw_cancel_request(request_id: Variant, session_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_trade_cancel.rpc_id(NetworkService.SERVER_PEER_ID, request_id, session_id)


func send_raw_offer_request(request_id: Variant, session_id: Variant, item_instance_id: Variant, quantity: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_trade_offer.rpc_id(NetworkService.SERVER_PEER_ID, request_id, session_id, item_instance_id, quantity)


func send_raw_confirm_request(request_id: Variant, session_id: Variant, revision: Variant, confirmed: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_trade_confirm.rpc_id(NetworkService.SERVER_PEER_ID, request_id, session_id, revision, confirmed)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_trade_result(request_id: Variant, ok: Variant, reason: Variant) -> void:
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
	trade_result.emit(int(request_id), bool(ok), reason_code)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_trade_state(state: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	client_state.apply_state(state)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_trade_notice(notice: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	client_state.apply_notice(notice)


func _can_request() -> bool:
	return network != null and network.is_client() and not network.client_state.local_player_id.is_empty()


func _reject_result() -> void:
	rejected_payload_count += 1
	GameLogger.warning("trade_net", "trade result dropped", {"module": MODULE_NAME, "operation": "apply_payload"})
