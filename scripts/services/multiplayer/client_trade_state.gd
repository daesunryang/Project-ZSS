class_name ClientTradeState
extends RefCounted
## Non-authoritative client mirror of the local player's trade (P2-T16,
## docs/09 §14.30): the request or session this client's player is in, as
## the server last described it, and the trades it saw others complete. It
## has no send / RPC API. Every incoming DTO is validated before mutation.
##
## Session state as the server sends it to ONE party (exact keys):
##   {session_id: int >= 1, phase: "requested" | "open" | "closed",
##    requester_id, target_id: who asked whom (the local player is one of
##      them),
##    revision: int >= 0 (counts the changes of either offer),
##    my_offer: Array of {item_instance_id, definition_id, quantity} (the
##      local player's own offer: stacks of its own inventory),
##    their_offer: Array of {definition_id, quantity} (what the other side
##      offers: kind and number, no item ids),
##    my_confirmed, their_confirmed: bool,
##    change: what the message reports (TradeService.CHANGE_*),
##    outcome: "" | "completed" | "cancelled" ("" unless closed),
##    cause: why (a cancel cause, or why an exchange failed), may be "",
##    by_player_id: "" or the party that caused it,
##    world_time: float}
## A client is only ever sent the states of its own session: what two other
## players offer each other never reaches it.
##
## Notice of a completed trade, sent to every joined peer that was no party
## of it (exact keys): {player_ids: [a, b] (sorted), world_time}. It says
## that the two traded, not what and not who asked.

signal changed
## The local player's request or session ended; `state` is its last state
## (outcome "completed" or "cancelled").
signal session_closed(state: Dictionary)
## A validated notice of a trade between two other players arrived.
signal notice_received(notice: Dictionary)

const STATE_KEYS: Array = ["session_id", "phase", "requester_id", "target_id", "revision", "my_offer", "their_offer", "my_confirmed", "their_confirmed", "change", "outcome", "cause", "by_player_id", "world_time"]
const MY_OFFER_KEYS: Array = ["item_instance_id", "definition_id", "quantity"]
const THEIR_OFFER_KEYS: Array = ["definition_id", "quantity"]
const NOTICE_KEYS: Array = ["player_ids", "world_time"]
const PHASES: Array = [TradeSession.PHASE_REQUESTED, TradeSession.PHASE_OPEN, TradeSession.PHASE_CLOSED]
const CHANGES: Array = [
	TradeService.CHANGE_REQUESTED, TradeService.CHANGE_OPENED, TradeService.CHANGE_OFFER, TradeService.CHANGE_OFFER_ADJUSTED,
	TradeService.CHANGE_CONFIRMED, TradeService.CHANGE_UNCONFIRMED, TradeService.CHANGE_EXCHANGE_FAILED, TradeService.CHANGE_CLOSED,
]
## Protocol limit: stacks in one offer of a session state. The server's
## TradeSettings.max_offer_entries may not exceed it.
const MAX_OFFER_ENTRIES: int = 32
## Longest player / item / definition id accepted from the server.
const ID_MAX_LENGTH: int = IntentValidator.ENTITY_ID_MAX_LENGTH
## Longest cause code accepted from the server.
const CAUSE_MAX_LENGTH: int = 64
## Notices kept for the presentation (oldest dropped).
const MAX_RECENT_NOTICES: int = 16

var local_player_id: String = ""
## Payloads from the server that failed validation.
var rejected_payload_count: int = 0

## The request or session the local player is in ({} = none).
var _session: Dictionary = {}
## The last state of the request or session that ended most recently.
var _last_closed: Dictionary = {}
var _recent_notices: Array[Dictionary] = []


## Applies a (re)join: a player that just joined is in no trade.
func apply_join(player_id: String) -> void:
	local_player_id = player_id
	_session = {}
	_last_closed = {}
	_recent_notices.clear()
	changed.emit()


## Applies a session state from the server. Returns false (no change) when
## it is malformed or not addressed to the local player.
func apply_state(state: Variant) -> bool:
	if not is_valid_state(state, local_player_id):
		return _reject("state")
	var accepted: Dictionary = (state as Dictionary).duplicate(true)
	if str(accepted["phase"]) == TradeSession.PHASE_CLOSED:
		# Only the end of the session the mirror knows (or of one it never saw
		# open, e.g. a request refused at once) is an end.
		if not _session.is_empty() and int(_session["session_id"]) != int(accepted["session_id"]):
			return _reject("closed_other_session")
		_session = {}
		_last_closed = accepted
		changed.emit()
		session_closed.emit(accepted.duplicate(true))
		return true
	_session = accepted
	changed.emit()
	return true


## Applies a notice of a trade between two other players.
func apply_notice(notice: Variant) -> bool:
	if not is_valid_notice(notice, local_player_id):
		return _reject("notice")
	var accepted: Dictionary = (notice as Dictionary).duplicate(true)
	_recent_notices.append(accepted)
	while _recent_notices.size() > MAX_RECENT_NOTICES:
		_recent_notices.pop_front()
	notice_received.emit(accepted.duplicate(true))
	return true


## True while the local player is in a request or a session.
func has_session() -> bool:
	return not _session.is_empty()


## A copy of the current session state ({} = none).
func session() -> Dictionary:
	return _session.duplicate(true)


## A copy of the last state of the most recently ended session ({} = none).
func last_closed() -> Dictionary:
	return _last_closed.duplicate(true)


func session_id() -> int:
	return int(_session.get("session_id", 0))


## "requested", "open" or "" (no session).
func phase() -> String:
	return str(_session.get("phase", ""))


## The other party of the current session ("" = no session).
func partner_id() -> String:
	return partner_of(_session, local_player_id)


## True when the local player asked (false when it was asked, or no session).
func is_requester() -> bool:
	return has_session() and str(_session["requester_id"]) == local_player_id


func revision() -> int:
	return int(_session.get("revision", 0))


func my_offer() -> Array:
	return (_session.get("my_offer", []) as Array).duplicate(true)


func their_offer() -> Array:
	return (_session.get("their_offer", []) as Array).duplicate(true)


func my_confirmed() -> bool:
	return _session.get("my_confirmed", false) == true


func their_confirmed() -> bool:
	return _session.get("their_confirmed", false) == true


## The notices received so far (at most MAX_RECENT_NOTICES, oldest first).
func recent_notices() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for notice: Dictionary in _recent_notices:
		result.append(notice.duplicate(true))
	return result


## The other party of a session state as seen by `player_id` ("" when the
## state is empty or the player is no party).
static func partner_of(state: Dictionary, player_id: String) -> String:
	var requester_id: String = str(state.get("requester_id", ""))
	var target_id: String = str(state.get("target_id", ""))
	if player_id == requester_id:
		return target_id
	return requester_id if player_id == target_id else ""


## True when `state` is a session state as the server sends it to the party
## `player_id` (see the header): exact keys, bounded strings and arrays, and
## `player_id` is one of the two parties.
static func is_valid_state(state: Variant, player_id: String) -> bool:
	if typeof(state) != TYPE_DICTIONARY or not _has_exact_keys(state as Dictionary, STATE_KEYS):
		return false
	var data: Dictionary = state
	if typeof(data["session_id"]) != TYPE_INT or int(data["session_id"]) < 1:
		return false
	if typeof(data["phase"]) != TYPE_STRING or not PHASES.has(data["phase"]):
		return false
	if not _is_id(data["requester_id"]) or not _is_id(data["target_id"]) or data["requester_id"] == data["target_id"]:
		return false
	if player_id.is_empty() or (data["requester_id"] != player_id and data["target_id"] != player_id):
		return false
	if typeof(data["revision"]) != TYPE_INT or int(data["revision"]) < 0:
		return false
	if not _is_valid_offer(data["my_offer"], MY_OFFER_KEYS) or not _is_valid_offer(data["their_offer"], THEIR_OFFER_KEYS):
		return false
	if typeof(data["my_confirmed"]) != TYPE_BOOL or typeof(data["their_confirmed"]) != TYPE_BOOL:
		return false
	if typeof(data["change"]) != TYPE_STRING or not CHANGES.has(data["change"]):
		return false
	var outcome: Variant = data["outcome"]
	var closed: bool = str(data["phase"]) == TradeSession.PHASE_CLOSED
	if typeof(outcome) != TYPE_STRING:
		return false
	# An outcome exactly when the session is closed.
	if closed != (outcome == TradeSession.OUTCOME_COMPLETED or outcome == TradeSession.OUTCOME_CANCELLED) or (not closed and outcome != TradeSession.OUTCOME_NONE):
		return false
	if typeof(data["cause"]) != TYPE_STRING or str(data["cause"]).length() > CAUSE_MAX_LENGTH:
		return false
	var by_player_id: Variant = data["by_player_id"]
	if typeof(by_player_id) != TYPE_STRING or (by_player_id != "" and by_player_id != data["requester_id"] and by_player_id != data["target_id"]):
		return false
	return _is_time(data["world_time"])


## True when `notice` is a completed-trade notice as the server sends it to
## a bystander `player_id`: exact keys, two different players in sorted
## order, neither of them the local player.
static func is_valid_notice(notice: Variant, player_id: String) -> bool:
	if typeof(notice) != TYPE_DICTIONARY or not _has_exact_keys(notice as Dictionary, NOTICE_KEYS):
		return false
	var data: Dictionary = notice
	var ids: Variant = data["player_ids"]
	if typeof(ids) != TYPE_ARRAY or (ids as Array).size() != 2:
		return false
	var first: Variant = (ids as Array)[0]
	var second: Variant = (ids as Array)[1]
	if not _is_id(first) or not _is_id(second) or str(first) >= str(second):
		return false
	if first == player_id or second == player_id:
		return false
	return _is_time(data["world_time"])


static func _is_valid_offer(offer: Variant, keys: Array) -> bool:
	if typeof(offer) != TYPE_ARRAY or (offer as Array).size() > MAX_OFFER_ENTRIES:
		return false
	var seen: Dictionary = {}
	for entry: Variant in offer as Array:
		if typeof(entry) != TYPE_DICTIONARY or not _has_exact_keys(entry as Dictionary, keys):
			return false
		var data: Dictionary = entry
		if data.has("item_instance_id"):
			if not _is_id(data["item_instance_id"]) or seen.has(data["item_instance_id"]):
				return false
			seen[data["item_instance_id"]] = true
		if typeof(data["definition_id"]) != TYPE_STRING or str(data["definition_id"]).length() > ID_MAX_LENGTH or not ItemInstance.is_valid_definition_id(str(data["definition_id"])):
			return false
		if typeof(data["quantity"]) != TYPE_INT or int(data["quantity"]) < 1:
			return false
	return true


static func _has_exact_keys(data: Dictionary, keys: Array) -> bool:
	if data.size() != keys.size():
		return false
	for key: Variant in data.keys():
		if typeof(key) != TYPE_STRING or not keys.has(key):
			return false
	return true


static func _is_id(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and not str(value).is_empty() and str(value).length() <= ID_MAX_LENGTH


static func _is_time(value: Variant) -> bool:
	return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value)) and float(value) >= 0.0


func _reject(what: String) -> bool:
	rejected_payload_count += 1
	GameLogger.warning("trade_net", "trade payload dropped", {"reason": what, "operation": "apply_payload"})
	return false
