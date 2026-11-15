class_name TradeService
extends ServerSystem
## Server-authoritative trades between two players (P2-T16, user decision
## 2026-11-16, docs/00 ADR-022, docs/09 §14.30). System id "trade";
## registered by ServerComposition after the systems whose state it asks the
## world for (survival, posture). No networking here: TradeNetModule calls
## the methods below from its RPC handlers and forwards drain_events().
##
## Flow: A asks B (request_trade) -> B accepts (accept) or declines (cancel),
## or the request times out -> an open session: each side puts stacks of its
## own inventory into its offer (set_offer; quantity 0 takes a stack out) ->
## each side confirms (set_confirmed) -> when both have confirmed, the
## exchange is done in ONE InventoryService.exchange_items transaction (all
## or nothing) and the session is closed as completed. One side may offer
## nothing (a gift): the receiver consents by confirming.
##
## Rules that protect the two sides:
##   - Every change of either offer clears BOTH confirmations and raises the
##     session's `revision`. A confirmation names the revision it saw and is
##     refused (`stale_offer`) when the offers changed since, so nobody
##     confirms an offer it has not seen.
##   - An offer names stacks of the offering player's own inventory only,
##     and never more units than the stack holds. When an offered stack
##     shrinks or leaves the inventory (eaten, put down), the offer is
##     adjusted by the server and both confirmations are cleared.
##   - A player is in at most one request or session. Asking somebody who is
##     in one is refused (`target_busy`); a player in one cannot ask.
##   - Nothing moves before both have confirmed, and then everything moves
##     or nothing does.
##
## A request or session is cancelled (both are told why, nothing moved)
## when: either side cancels (a declined request, a withdrawn request, a
## cancelled session), the two are further apart than
## TradeSettings.session_range_m, either dies, lies down to sleep, leaves,
## starts a new character, or a timeout passes (TradeSettings.
## request_timeout_sec for an unanswered request,
## session_idle_timeout_sec without an accepted action in a session). The
## state checks run every server tick (step) and before every intent.
##
## Who may be asked: an online, living player within
## TradeSettings.request_range_m who is awake (`target_resting` otherwise)
## and in no other request or session. A prone player can trade.
##
## Events (drain_events; JSON-safe), one per change of a session:
##   {event_type: "trade_session_changed", change: CHANGE_*, session:
##    TradeSession.to_dict(), world_time}
## The offers in an event are for the two parties only (docs/00 ADR-009);
## TradeNetModule decides what each peer is sent.
##
## Time: timeouts are action time (real seconds, WorldClock.action_time_sec),
## so they are driven by the injected clock and stop while the world is
## paused. Save: nothing. Sessions are session state: none survives a
## restart, and a player that leaves has no session.

const SYSTEM_ID: String = "trade"
const EVENT_SESSION_CHANGED: String = "trade_session_changed"

## What an event reports.
const CHANGE_REQUESTED: String = "requested"
const CHANGE_OPENED: String = "opened"
const CHANGE_OFFER: String = "offer_changed"
## The server adjusted an offer (an offered stack shrank or left the
## inventory).
const CHANGE_OFFER_ADJUSTED: String = "offer_adjusted"
const CHANGE_CONFIRMED: String = "confirmed"
const CHANGE_UNCONFIRMED: String = "unconfirmed"
## Both had confirmed but the exchange was refused; the session stays open
## and `cause` / `by_player_id` of the event's session say why.
const CHANGE_EXCHANGE_FAILED: String = "exchange_failed"
const CHANGE_CLOSED: String = "closed"

## Why a request or session was cancelled (TradeSession.cause).
const CAUSE_DECLINED: String = "declined"
const CAUSE_WITHDRAWN: String = "withdrawn"
const CAUSE_CANCELLED: String = "cancelled"
const CAUSE_TOO_FAR: String = "too_far"
const CAUSE_PLAYER_DEAD: String = "player_dead"
const CAUSE_PLAYER_RESTING: String = SurvivalService.REASON_PLAYER_RESTING
const CAUSE_DISCONNECTED: String = "disconnected"
const CAUSE_NEW_CHARACTER: String = "new_character"
const CAUSE_REQUEST_TIMEOUT: String = "request_timeout"
const CAUSE_IDLE_TIMEOUT: String = "idle_timeout"
## Cause of a CHANGE_EXCHANGE_FAILED event: `by_player_id` has no room.
const CAUSE_INVENTORY_FULL: String = InventoryService.REASON_INVENTORY_FULL

## Failure reason codes (stable, sent to clients).
const REASON_NOT_ONLINE: String = ServerWorld.REASON_NOT_ONLINE
## The requester is already in a request or a session.
const REASON_ALREADY_TRADING: String = "already_trading"
const REASON_TARGET_IS_SELF: String = "target_is_self"
const REASON_TARGET_UNAVAILABLE: String = ServerWorld.REASON_TARGET_UNAVAILABLE
const REASON_TARGET_DEAD: String = ServerWorld.REASON_TARGET_DEAD
const REASON_TARGET_TOO_FAR: String = ServerWorld.REASON_TARGET_TOO_FAR
## The target is asleep (or cannot act for another reason).
const REASON_TARGET_RESTING: String = "target_resting"
## The target is in a request or session with somebody.
const REASON_TARGET_BUSY: String = "target_busy"
## No pending request with that id is addressed to the player.
const REASON_NO_SUCH_REQUEST: String = "no_such_request"
## The player is no party of a session with that id (it never was, or the
## session is over).
const REASON_NOT_IN_SESSION: String = "not_in_session"
## The session exists but is still a request waiting for its answer.
const REASON_SESSION_NOT_OPEN: String = "session_not_open"
## The session was just cancelled because of the state of a party (the
## closed session tells both why).
const REASON_SESSION_CANCELLED: String = "session_cancelled"
const REASON_NOT_IN_OFFER: String = "not_in_offer"
const REASON_OFFER_UNCHANGED: String = "offer_unchanged"
const REASON_OFFER_FULL: String = "offer_full"
## The confirmation names another revision than the session's.
const REASON_STALE_OFFER: String = "stale_offer"
const REASON_ALREADY_CONFIRMED: String = "already_confirmed"
const REASON_NOT_CONFIRMED: String = "not_confirmed"
## Neither side offers anything.
const REASON_NOTHING_OFFERED: String = "nothing_offered"
## The server had to adjust an offer, so nothing was confirmed.
const REASON_OFFER_CHANGED: String = "offer_changed"
## The exchange was refused because the confirming player's own inventory /
## the other player's inventory cannot take what would come in.
const REASON_INVENTORY_FULL: String = InventoryService.REASON_INVENTORY_FULL
const REASON_OTHER_INVENTORY_FULL: String = "other_inventory_full"

## Events discarded because the configured pending queue was full.
var dropped_event_count: int = 0

var _settings: TradeSettings
var _clock: WorldClock
## The world this system is registered in (weak: the world owns its
## systems). Needed where no hook passes it: on_inventory_transaction.
var _world_ref: WeakRef = null
## player_id -> the request or session the player is in (both parties map
## to the same object). A closed session is in no map.
var _session_by_player: Dictionary[String, TradeSession] = {}
var _next_session_id: int = 1
var _events: Array[Dictionary] = []
## True while this system's own exchange is being committed (its inventory
## transaction must not adjust the offers it is carrying out).
var _exchanging: bool = false


func _init(settings: TradeSettings, clock: WorldClock) -> void:
	_settings = settings
	_clock = clock


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ public API

## The request or session `player_id` is in, or null.
func session_of(player_id: String) -> TradeSession:
	return _session_by_player.get(player_id, null)


## Number of requests and sessions that are not closed.
func session_count() -> int:
	return _sessions().size()


## `requester_id` asks `target_id` for a trade. Checks, in this order (the
## first that fails is the reason; a refused request changes nothing):
##   1. the requester is in the world           not_online
##   2. the requester can act                   player_dead, player_resting
##   3. the requester is in no request/session  already_trading (but: asking
##      the player whose request to me is pending accepts that request)
##   4. the target is another player            target_is_self
##   5. the target is in the world              target_unavailable (unknown,
##      away, without a character: one reason, ids cannot be probed)
##   6. the target is alive                     target_dead
##   7. within TradeSettings.request_range_m    target_too_far
##   8. the target is awake                     target_resting
##   9. the target is in no request/session     target_busy
## The order decides what a requester can learn: whether somebody sleeps or
## is busy trading is only told next to that player (7 before 8 and 9).
## Success: the session as plain data (TradeSession.to_dict), phase
## "requested" (or "open" for an answered request, see 3).
func request_trade(world: ServerWorld, requester_id: String, target_id: String) -> ActionResult:
	if not world.is_online(requester_id):
		return ActionResult.failure(REASON_NOT_ONLINE)
	var blocked: String = world.player_action_block_reason(requester_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var own: TradeSession = session_of(requester_id)
	if own != null:
		# Both want it: a request answered with a request is an acceptance.
		if own.phase == TradeSession.PHASE_REQUESTED and own.target_id == requester_id and own.requester_id == target_id:
			return accept(world, requester_id, own.session_id)
		return ActionResult.failure(REASON_ALREADY_TRADING)
	if target_id == requester_id:
		return ActionResult.failure(REASON_TARGET_IS_SELF)
	var requester: PlayerState = world.get_player(requester_id)
	var target: PlayerState = world.get_player(target_id)
	if target == null or not world.is_online(target_id):
		return ActionResult.failure(REASON_TARGET_UNAVAILABLE)
	if world.is_player_dead(target_id):
		return ActionResult.failure(REASON_TARGET_DEAD)
	if requester.position.distance_to(target.position) > _settings.request_range_m:
		return ActionResult.failure(REASON_TARGET_TOO_FAR)
	if not world.player_action_block_reason(target_id).is_empty():
		return ActionResult.failure(REASON_TARGET_RESTING)
	if session_of(target_id) != null:
		return ActionResult.failure(REASON_TARGET_BUSY)
	var session: TradeSession = TradeSession.new(_next_session_id, requester_id, target_id, _clock.action_time_sec)
	_next_session_id += 1
	_session_by_player[requester_id] = session
	_session_by_player[target_id] = session
	GameLogger.info("trade", "trade requested", {"session_id": session.session_id, "player_id": requester_id, "target_id": target_id})
	return ActionResult.success(_report(session, CHANGE_REQUESTED))


## The player that was asked says yes: the session opens. Failure:
## no_such_request (no pending request with that id is addressed to the
## player), session_cancelled (a party's state ended it just now).
func accept(world: ServerWorld, player_id: String, session_id: int) -> ActionResult:
	var session: TradeSession = session_of(player_id)
	if session == null or session.session_id != session_id or session.phase != TradeSession.PHASE_REQUESTED or session.target_id != player_id:
		return ActionResult.failure(REASON_NO_SUCH_REQUEST)
	if _close_if_broken(world, session):
		return ActionResult.failure(REASON_SESSION_CANCELLED)
	session.phase = TradeSession.PHASE_OPEN
	session.last_activity_at = _clock.action_time_sec
	GameLogger.info("trade", "trade session opened", {"session_id": session.session_id, "player_id": session.requester_id, "target_id": session.target_id})
	return ActionResult.success(_report(session, CHANGE_OPENED))


## A party backs out: the target declines a request ("declined"), the
## requester takes it back ("withdrawn"), either side ends an open session
## ("cancelled"). Always possible for a party, whatever its state. Nothing
## moves. Failure: not_in_session.
func cancel(_world: ServerWorld, player_id: String, session_id: int) -> ActionResult:
	var session: TradeSession = session_of(player_id)
	if session == null or session.session_id != session_id:
		return ActionResult.failure(REASON_NOT_IN_SESSION)
	var cause: String = CAUSE_CANCELLED
	if session.phase == TradeSession.PHASE_REQUESTED:
		cause = CAUSE_DECLINED if player_id == session.target_id else CAUSE_WITHDRAWN
	return ActionResult.success(_close(session, TradeSession.OUTCOME_CANCELLED, cause, player_id))


## `player_id` puts `quantity` units of a stack it carries into its own
## offer, changes how many units of an offered stack it offers, or takes the
## stack out of its offer (`quantity` 0). There is no argument for whose
## offer: it is always the caller's. Checks, in order: the caller is a party
## of that open session (not_in_session, session_not_open), both parties'
## state (session_cancelled), then for quantity 0: the stack is in the
## caller's offer (not_in_offer); otherwise: the item exists and the caller
## carries it (unknown_item, item_not_in_inventory), 1 <= quantity <= the
## stack (bad_quantity), something changes (offer_unchanged), and a new
## stack fits TradeSettings.max_offer_entries (offer_full).
## An accepted change raises the revision and clears BOTH confirmations.
func set_offer(world: ServerWorld, player_id: String, session_id: int, item_instance_id: String, quantity: int) -> ActionResult:
	var session: TradeSession = session_of(player_id)
	if session == null or session.session_id != session_id:
		return ActionResult.failure(REASON_NOT_IN_SESSION)
	if session.phase != TradeSession.PHASE_OPEN:
		return ActionResult.failure(REASON_SESSION_NOT_OPEN)
	if _close_if_broken(world, session):
		return ActionResult.failure(REASON_SESSION_CANCELLED)
	var offer: Array = session.offers[player_id]
	var index: int = session.offer_index(player_id, item_instance_id)
	if quantity == 0:
		if index < 0:
			return ActionResult.failure(REASON_NOT_IN_OFFER)
		offer.remove_at(index)
	else:
		var item: ItemInstance = world.inventory.get_item(item_instance_id)
		if item == null:
			return ActionResult.failure(InventoryService.REASON_UNKNOWN_ITEM)
		# Ownership before the quantity: nothing is learnt about a stack the
		# caller does not carry.
		if not _carries(world, player_id, item):
			return ActionResult.failure(InventoryService.REASON_NOT_IN_INVENTORY)
		if quantity < 1 or quantity > item.quantity:
			return ActionResult.failure(InventoryService.REASON_BAD_QUANTITY)
		if index >= 0:
			if int((offer[index] as Dictionary)[TradeSession.KEY_QUANTITY]) == quantity:
				return ActionResult.failure(REASON_OFFER_UNCHANGED)
			(offer[index] as Dictionary)[TradeSession.KEY_QUANTITY] = quantity
		else:
			if offer.size() >= _settings.max_offer_entries:
				return ActionResult.failure(REASON_OFFER_FULL)
			offer.append({TradeSession.KEY_ITEM_ID: item_instance_id, TradeSession.KEY_DEFINITION_ID: item.definition_id, TradeSession.KEY_QUANTITY: quantity})
	session.revision += 1
	session.clear_confirmations()
	session.last_activity_at = _clock.action_time_sec
	return ActionResult.success(_report(session, CHANGE_OFFER))


## `player_id` confirms the offers as they are at `revision` (`wanted`
## true), or takes its confirmation back (false; the revision is not looked
## at). There is no argument for whose confirmation: always the caller's.
## Checks for a confirmation, in order: the caller is a party of that open
## session, both parties' state, the revision is the session's
## (stale_offer), not confirmed yet (already_confirmed), something is
## offered (nothing_offered), every offered stack is still carried
## (offer_changed: the offers were adjusted instead).
## When both have confirmed, the exchange is carried out at once in one
## InventoryService.exchange_items transaction:
##   - done: the session is closed as completed and the result is its
##     closed state;
##   - an inventory cannot take what would come in: nothing moves, both
##     confirmations are cleared, the session stays open, and the caller is
##     told `inventory_full` (its own) or `other_inventory_full`.
func set_confirmed(world: ServerWorld, player_id: String, session_id: int, revision: int, wanted: bool) -> ActionResult:
	var session: TradeSession = session_of(player_id)
	if session == null or session.session_id != session_id:
		return ActionResult.failure(REASON_NOT_IN_SESSION)
	if session.phase != TradeSession.PHASE_OPEN:
		return ActionResult.failure(REASON_SESSION_NOT_OPEN)
	if _close_if_broken(world, session):
		return ActionResult.failure(REASON_SESSION_CANCELLED)
	if not wanted:
		if not session.confirmed[player_id]:
			return ActionResult.failure(REASON_NOT_CONFIRMED)
		session.confirmed[player_id] = false
		session.last_activity_at = _clock.action_time_sec
		return ActionResult.success(_report(session, CHANGE_UNCONFIRMED))
	if revision != session.revision:
		return ActionResult.failure(REASON_STALE_OFFER)
	if session.confirmed[player_id]:
		return ActionResult.failure(REASON_ALREADY_CONFIRMED)
	if session.is_empty():
		return ActionResult.failure(REASON_NOTHING_OFFERED)
	if _adjust_offers(world, session):
		return ActionResult.failure(REASON_OFFER_CHANGED)
	session.confirmed[player_id] = true
	session.last_activity_at = _clock.action_time_sec
	if not session.both_confirmed():
		return ActionResult.success(_report(session, CHANGE_CONFIRMED))
	return _exchange(world, session, player_id)


## Returns and clears the events recorded since the previous call (oldest
## first). At most `max_pending_events` are kept between calls.
func drain_events() -> Array[Dictionary]:
	var drained: Array[Dictionary] = _events
	_events = []
	return drained


# ------------------------------------------------------------ hooks

func on_registered(world: ServerWorld) -> void:
	_world_ref = weakref(world)


## Every server tick: ends requests and sessions whose parties' state broke
## them, and the ones that timed out.
func step(world: ServerWorld, _action_delta: float, _world_delta: float) -> void:
	var now: float = _clock.action_time_sec
	for session: TradeSession in _sessions():
		if _close_if_broken(world, session):
			continue
		if session.phase == TradeSession.PHASE_REQUESTED and now - session.created_at >= _settings.request_timeout_sec:
			_close(session, TradeSession.OUTCOME_CANCELLED, CAUSE_REQUEST_TIMEOUT, "")
		elif session.phase == TradeSession.PHASE_OPEN and now - session.last_activity_at >= _settings.session_idle_timeout_sec:
			_close(session, TradeSession.OUTCOME_CANCELLED, CAUSE_IDLE_TIMEOUT, "")


## A party left the server: its request or session ends at once.
func on_player_offline(_world: ServerWorld, player_id: String) -> void:
	var session: TradeSession = session_of(player_id)
	if session != null:
		_close(session, TradeSession.OUTCOME_CANCELLED, CAUSE_DISCONNECTED, player_id)


## A party's next character started: whatever its old character was trading
## is over.
func on_character_started(_world: ServerWorld, player_id: String) -> void:
	var session: TradeSession = session_of(player_id)
	if session != null:
		_close(session, TradeSession.OUTCOME_CANCELLED, CAUSE_NEW_CHARACTER, player_id)


## Hook for InventoryService.transaction_committed (ServerComposition
## connects it): an offer may only name what its player still carries. When
## an offered stack shrank or left the inventory (eaten, put down, lost at a
## death), the offer is adjusted and both confirmations are cleared.
func on_inventory_transaction(_event: Dictionary) -> void:
	if _exchanging or _world_ref == null:
		return
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld
	if world == null:
		return
	for session: TradeSession in _sessions():
		if session.phase == TradeSession.PHASE_OPEN:
			_adjust_offers(world, session)


# ------------------------------------------------------------ internals

## The requests and sessions that are not closed, each once, oldest first.
func _sessions() -> Array[TradeSession]:
	var sessions: Array[TradeSession] = []
	for session: TradeSession in _session_by_player.values():
		if not sessions.has(session):
			sessions.append(session)
	sessions.sort_custom(func(a: TradeSession, b: TradeSession) -> bool: return a.session_id < b.session_id)
	return sessions


func _carries(world: ServerWorld, player_id: String, item: ItemInstance) -> bool:
	var player: PlayerState = world.get_player(player_id)
	return player != null and item.location_type == ItemInstance.LOCATION_INVENTORY and item.location_id == player.inventory_id


## [cause, by_player_id] when the state of the parties ends the session
## (somebody is not in the world, dead or cannot act; they are too far
## apart), ["", ""] otherwise.
func _break_cause(world: ServerWorld, session: TradeSession) -> Array:
	for player_id: String in [session.requester_id, session.target_id]:
		if not world.is_online(player_id):
			return [CAUSE_DISCONNECTED, player_id]
		if world.is_player_dead(player_id):
			return [CAUSE_PLAYER_DEAD, player_id]
		var blocked: String = world.player_action_block_reason(player_id)
		if not blocked.is_empty():
			return [blocked, player_id]
	var requester: PlayerState = world.get_player(session.requester_id)
	var target: PlayerState = world.get_player(session.target_id)
	if requester.position.distance_to(target.position) > _settings.session_range_m:
		return [CAUSE_TOO_FAR, ""]
	return ["", ""]


## Cancels the session when the state of its parties ended it. Returns true
## when it did.
func _close_if_broken(world: ServerWorld, session: TradeSession) -> bool:
	var broken: Array = _break_cause(world, session)
	if str(broken[0]).is_empty():
		return false
	_close(session, TradeSession.OUTCOME_CANCELLED, str(broken[0]), str(broken[1]))
	return true


## Ends a request or session and frees both players. Returns the event's
## session data.
func _close(session: TradeSession, outcome: String, cause: String, by_player_id: String) -> Dictionary:
	session.phase = TradeSession.PHASE_CLOSED
	session.outcome = outcome
	session.cause = cause
	session.by_player_id = by_player_id
	session.clear_confirmations()
	_session_by_player.erase(session.requester_id)
	_session_by_player.erase(session.target_id)
	GameLogger.info("trade", "trade session closed", {"session_id": session.session_id, "player_id": session.requester_id, "target_id": session.target_id, "outcome": outcome, "cause": cause, "by_player_id": by_player_id})
	return _report(session, CHANGE_CLOSED)


## Makes every offer of the session name only what its player carries: an
## entry whose stack left the inventory is dropped, an entry that names more
## units than the stack holds is lowered. Returns true when something had
## to be adjusted (then the revision went up, both confirmations are
## cleared and an "offer_adjusted" event was recorded).
func _adjust_offers(world: ServerWorld, session: TradeSession) -> bool:
	var adjusted: bool = false
	for player_id: String in [session.requester_id, session.target_id]:
		var offer: Array = session.offers[player_id]
		for index: int in range(offer.size() - 1, -1, -1):
			var entry: Dictionary = offer[index]
			var item: ItemInstance = world.inventory.get_item(str(entry[TradeSession.KEY_ITEM_ID]))
			if item == null or not _carries(world, player_id, item):
				offer.remove_at(index)
				adjusted = true
			elif int(entry[TradeSession.KEY_QUANTITY]) > item.quantity:
				entry[TradeSession.KEY_QUANTITY] = item.quantity
				adjusted = true
	if adjusted:
		session.revision += 1
		session.clear_confirmations()
		_report(session, CHANGE_OFFER_ADJUSTED)
	return adjusted


## Both have confirmed: one inventory transaction, all or nothing.
## `confirmer_id` is the player whose confirmation completed the pair.
func _exchange(world: ServerWorld, session: TradeSession, confirmer_id: String) -> ActionResult:
	var requester: PlayerState = world.get_player(session.requester_id)
	var target: PlayerState = world.get_player(session.target_id)
	_exchanging = true
	var result: ActionResult = world.inventory.exchange_items(requester.inventory_id, session.exchange_offer(session.requester_id), target.inventory_id, session.exchange_offer(session.target_id))
	_exchanging = false
	if result.ok:
		return ActionResult.success(_close(session, TradeSession.OUTCOME_COMPLETED, "", ""))
	# Nothing moved. Both confirm again once whatever was in the way is gone.
	session.clear_confirmations()
	session.last_activity_at = _clock.action_time_sec
	var full_player_id: String = ""
	if result.reason == InventoryService.REASON_FIRST_INVENTORY_FULL:
		full_player_id = session.requester_id
	elif result.reason == InventoryService.REASON_SECOND_INVENTORY_FULL:
		full_player_id = session.target_id
	if full_player_id.is_empty():
		# Not expected: the offers were checked a moment ago.
		GameLogger.error("trade", "exchange refused", {"session_id": session.session_id, "reason": result.reason, "operation": "exchange"})
		_adjust_offers(world, session)
		_report(session, CHANGE_EXCHANGE_FAILED, result.reason, "")
		return ActionResult.failure(result.reason)
	_report(session, CHANGE_EXCHANGE_FAILED, CAUSE_INVENTORY_FULL, full_player_id)
	return ActionResult.failure(REASON_INVENTORY_FULL if full_player_id == confirmer_id else REASON_OTHER_INVENTORY_FULL)


## Queues one session event and returns its session data. `cause` /
## `by_player_id` override the session's own in the event (an exchange that
## failed says why without ending the session).
func _report(session: TradeSession, change: String, cause: String = "", by_player_id: String = "") -> Dictionary:
	var data: Dictionary = session.to_dict()
	if not cause.is_empty():
		data["cause"] = cause
		data["by_player_id"] = by_player_id
	_events.append({
		"event_type": EVENT_SESSION_CHANGED,
		"change": change,
		"session": data.duplicate(true),
		"world_time": _clock.world_time_sec,
	})
	while _events.size() > _settings.max_pending_events:
		_events.pop_front()
		dropped_event_count += 1
	return data
