class_name NpcDialogueNetModule
extends NetModule
## The talk intents and the conversation views of a player with an NPC
## (F-31, docs/09 §17.16). Network only: every rule is in NpcDialogue
## (range, line of sight, who the NPC talks to, what it answers).
##
## RPC table (channel 0 = reliable ordered):
##   client -> server  _rpc_request_talk(request_id:int, npc_id:String)                 reliable, ch0
##   client -> server  _rpc_request_choose(request_id:int, npc_id:String, turn:int,
##                                          choice_id:String)                            reliable, ch0
##   client -> server  _rpc_request_end(request_id:int)                                  reliable, ch0
##   server -> talker  _rpc_dialogue_result(request_id:int, ok:bool, reason:String,
##                                           view:Dictionary)                            reliable, ch0
##   server -> talker  _rpc_dialogue_ended(view:Dictionary)                              reliable, ch0
##
## Intents: a client names things only: the NPC it wants to talk to, the
## view (turn) it answers and the id of the choice it makes. The actor is
## always the player of the sending peer: there is no argument for "who
## talks", none for a position or a distance, none for an item (a gift is
## the choice "give:<n>" of a list the server made), and no text. Server
## checks, in order: joined (`not_joined`), argument types (`bad_type`),
## request id >= 0 (`bad_sequence`), the shape of the NPC id (`bad_npc_id`),
## the turn (`bad_turn`) and the choice id (`bad_choice_id`), request rate
## (`rate_limited`, one bucket for the three intents), that the world has
## conversations (`dialogue_unavailable`), that this peer has been told
## about that NPC (`unknown_npc`: an NPC outside the cells the peer is told
## about is answered exactly like one that does not exist), then the rule
## (NpcDialogue: `too_far`, `no_line_of_sight`, `npc_dead`, `npc_talking`,
## `not_talking`, `stale_turn`, `bad_choice`, `player_dead`, ...). Every
## refusal is counted (NetworkService.rejected_intent_count) and changes
## nothing.
##
## Result: to the requester only. `reason` is "" exactly when ok; `view` is
## the conversation as it is now when ok (ClientDialogueState describes it)
## and {} otherwise. An NPC that will not talk is an accepted request: ok,
## a view that is not open, the line it said and end_reason "refused".
##
## Disclosure (docs/00 ADR-009): lines and choices go to the talker only.
## Everybody else learns one thing, through NpcNetModule: the NPC's public
## reaction is "talk". A conversation the server ended (the player walked
## away, the NPC fled, was hurt or died, nobody said anything for too long)
## reaches the talker as _rpc_dialogue_ended with the last view; it is sent
## before the result of a request handled in the same tick.
##
## Items: a gift or a swap inside a conversation moves real items through
## InventoryService; InventoryNetModule sends the talker its own inventory
## change (owner only) inside that call, so before the result. The change is
## saved before the result is sent (like a completed trade).
##
## Client surface (presentation): request_start(), request_choose(),
## request_end(), the signals below and the mirror `client_state`. The
## mirror has no authority.

## Client: answer to one of this client's own dialogue requests.
signal dialogue_result(request_id: int, ok: bool, reason: String)
## Client: the server ended the conversation (`view` is its last view).
signal dialogue_ended(view: Dictionary)

const MODULE_NAME: String = "NpcDialogueNet"
## Intent names in rejection logs.
const INTENT_TALK: String = "npc_talk"
const INTENT_CHOOSE: String = "npc_talk_choose"
const INTENT_END: String = "npc_talk_end"
## Returned by the request_*() functions when nothing was sent.
const NO_REQUEST: int = 0
## Longest reason code a client accepts in a result.
const REASON_MAX_LENGTH: int = 64
const REASON_BAD_NPC_ID: String = "bad_npc_id"
const REASON_BAD_TURN: String = "bad_turn"
const REASON_BAD_CHOICE_ID: String = "bad_choice_id"
## Save reason (logs only).
const SAVE_REASON_DIALOGUE: String = "npc_dialogue_items"

var client_state: ClientDialogueState = ClientDialogueState.new()
## Client: results from the server that failed validation.
var rejected_payload_count: int = 0
## Server: views that did not fit the wire format and were not sent.
var unsendable_view_count: int = 0
## Server: texts that were longer than the wire format carries and were cut.
var cut_text_count: int = 0

var _settings: NpcDialogueNetSettings
# --- server state ---
var _world: ServerWorld = null
var _npc_net: NpcNetModule = null
var _inventory_net: InventoryNetModule = null
var _limiter: RateLimiter = null
# --- client state ---
var _last_request_id: int = NO_REQUEST
## Requests that named the conversation the mirror was in (a choice, an
## end): when the server answers one of them "you are in no conversation",
## the mirror is wrong and is closed.
var _conversation_requests: Dictionary[int, bool] = {}


func _init(settings: NpcDialogueNetSettings = null) -> void:
	name = MODULE_NAME
	_settings = settings if settings != null else NpcDialogueNetSettings.new()


# ------------------------------------------------------------ pure rules

## "" when the arguments of a talk request are usable, otherwise a reason
## code. Types first, so wrongly typed input never reaches a conversion.
static func validate_talk_request(request_id: Variant, npc_id: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(npc_id) != TYPE_STRING:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	if not ClientDialogueState.is_npc_id(npc_id):
		return REASON_BAD_NPC_ID
	return ""


## "" when the arguments of a choice are usable.
static func validate_choose_request(request_id: Variant, npc_id: Variant, turn: Variant, choice_id: Variant) -> String:
	if typeof(turn) != TYPE_INT or typeof(choice_id) != TYPE_STRING:
		return IntentValidator.REASON_BAD_TYPE
	var reason: String = validate_talk_request(request_id, npc_id)
	if not reason.is_empty():
		return reason
	if int(turn) < 0 or int(turn) > ClientDialogueState.MAX_TURN:
		return REASON_BAD_TURN
	if not ClientDialogueState.is_choice_id(choice_id):
		return REASON_BAD_CHOICE_ID
	return ""


## "" when the argument of an end request is usable.
static func validate_end_request(request_id: Variant) -> String:
	if typeof(request_id) != TYPE_INT:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	return ""


## "" when the arguments of a result are usable (client side): "" exactly
## when ok, a valid view exactly when ok.
static func result_error(request_id: Variant, ok: Variant, reason: Variant, view: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(ok) != TYPE_BOOL or typeof(reason) != TYPE_STRING or typeof(view) != TYPE_DICTIONARY:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	var reason_code: String = reason
	if reason_code.length() > REASON_MAX_LENGTH or bool(ok) != reason_code.is_empty():
		return ClientDialogueState.REASON_BAD_VIEW
	if not bool(ok):
		return "" if (view as Dictionary).is_empty() else ClientDialogueState.REASON_BAD_VIEW
	return ClientDialogueState.view_error(view)


## The view as it is sent: exactly the keys of the wire format, copied from
## a view of NpcDialogue. A text that is longer than the wire format
## carries is cut (`cut` counts them, one element). {} when the source is no
## view at all.
static func wire_view(source: Dictionary, cut: Array = []) -> Dictionary:
	for key: String in ClientDialogueState.VIEW_KEYS:
		if not source.has(key):
			return {}
	var raw_choices: Variant = source[NpcDialogue.KEY_CHOICES]
	if typeof(raw_choices) != TYPE_ARRAY:
		return {}
	var shown: Array = []
	for entry: Variant in (raw_choices as Array):
		if typeof(entry) != TYPE_ARRAY or (entry as Array).size() != ClientDialogueState.CHOICE_SIZE:
			return {}
		shown.append([(entry as Array)[ClientDialogueState.CHOICE_ID], _cut(str((entry as Array)[ClientDialogueState.CHOICE_TEXT]), ClientDialogueState.CHOICE_TEXT_MAX_LENGTH, cut)])
	return {
		NpcDialogue.KEY_NPC_ID: source[NpcDialogue.KEY_NPC_ID],
		NpcDialogue.KEY_NPC_NAME: source[NpcDialogue.KEY_NPC_NAME],
		NpcDialogue.KEY_OPEN: source[NpcDialogue.KEY_OPEN],
		NpcDialogue.KEY_TURN: source[NpcDialogue.KEY_TURN],
		NpcDialogue.KEY_LINE: _cut(str(source[NpcDialogue.KEY_LINE]), ClientDialogueState.LINE_MAX_LENGTH, cut),
		NpcDialogue.KEY_CHOICES: shown,
		NpcDialogue.KEY_END_REASON: source[NpcDialogue.KEY_END_REASON],
	}


static func _cut(text: String, max_length: int, cut: Array) -> String:
	if text.length() <= max_length:
		return text
	cut.append(true)
	return text.left(max_length)


# ------------------------------------------------------------ NetModule hooks

func on_server_started(world: ServerWorld) -> void:
	_world = world
	_npc_net = network.get_module(NpcNetModule.MODULE_NAME) as NpcNetModule
	_inventory_net = network.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	_limiter = RateLimiter.new(_settings.dialogue_intent_rate_per_sec, _settings.dialogue_intent_burst)
	if _dialogue() == null:
		GameLogger.info("net", "world has no npc social layer, npc dialogue is off", {"world_id": world.world_id, "module": MODULE_NAME})


## A peer left: its conversation is over and the NPC is free again.
func on_player_left(peer_id: int, player_id: String) -> void:
	if _limiter != null:
		_limiter.forget(peer_id)
	var dialogue: NpcDialogue = _dialogue()
	if dialogue != null and not player_id.is_empty():
		dialogue.end_for_player(_world, player_id)


## Server: sends the conversations the server ended in this tick.
func server_physics(_delta: float) -> void:
	_flush_events()


func apply_join_fragment(_fragment: Dictionary) -> void:
	_last_request_id = NO_REQUEST
	_conversation_requests.clear()
	client_state.apply_join()


# ------------------------------------------------------------ server side

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_talk(request_id: Variant, npc_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_TALK, request_id, validate_talk_request(request_id, npc_id), npc_id)
	if not player_id.is_empty():
		# The NPC is only a name: everything about it is read from the server.
		_finish(player_id, int(request_id), _dialogue().start(_world, player_id, str(npc_id)))


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_choose(request_id: Variant, npc_id: Variant, turn: Variant, choice_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_CHOOSE, request_id, validate_choose_request(request_id, npc_id, turn, choice_id), npc_id)
	if not player_id.is_empty():
		# Whether that choice is offered now is the rule's check; a gift or a
		# swap it stands for moves items inside this call.
		_finish(player_id, int(request_id), _dialogue().choose(_world, player_id, str(npc_id), int(turn), str(choice_id)))


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_end(request_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var player_id: String = _begin(INTENT_END, request_id, validate_end_request(request_id), null)
	if not player_id.is_empty():
		_finish(player_id, int(request_id), _dialogue().end(_world, player_id))


## The checks every dialogue intent starts with (see the header). Returns
## the player of the sending peer, or "" when the request was refused
## (counted, logged and answered where it can be). `npc_id`: the NPC the
## request names (null = none). Call only inside an RPC handler.
func _begin(intent: String, request_id: Variant, invalid_reason: String, npc_id: Variant) -> String:
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The actor is whoever owns the sending peer, never an argument.
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, intent, NetworkService.NOT_JOINED)
		return ""
	if not invalid_reason.is_empty():
		network.reject_intent(peer_id, intent, invalid_reason, player_id)
		if typeof(request_id) == TYPE_INT and int(request_id) >= 0:
			_send_result(peer_id, int(request_id), false, invalid_reason, {})
		return ""
	if not _limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, intent, NetworkService.RATE_LIMITED, player_id)
		_send_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED, {})
		return ""
	if _dialogue() == null:
		network.reject_intent(peer_id, intent, NpcDialogue.REASON_UNAVAILABLE, player_id)
		_send_result(peer_id, int(request_id), false, NpcDialogue.REASON_UNAVAILABLE, {})
		return ""
	# An NPC this peer was never told about does not exist for it.
	if npc_id != null and (_npc_net == null or not _npc_net.knows_npc(peer_id, str(npc_id))):
		network.count_rejection(NpcDialogue.REASON_UNKNOWN_NPC)
		_send_result(peer_id, int(request_id), false, NpcDialogue.REASON_UNKNOWN_NPC, {})
		return ""
	return player_id


## Sends what the rule ended by itself, then the answer. Call only inside
## an RPC handler.
func _finish(player_id: String, request_id: int, result: ActionResult) -> void:
	var peer_id: int = multiplayer.get_remote_sender_id()
	# A conversation the server ended before this request is told first
	# (same ordered channel).
	_flush_events()
	if not result.ok:
		# Refusals by game state are normal play: counted, not logged as warnings.
		network.count_rejection(result.reason)
		_send_result(peer_id, request_id, false, result.reason, {})
		return
	var view: Dictionary = _sendable(result.event, player_id)
	if view.is_empty():
		# What cannot be shown cannot be answered: the conversation is ended
		# rather than left open where the player cannot see it.
		_dialogue().end(_world, player_id)
		_send_result(peer_id, request_id, false, ClientDialogueState.REASON_BAD_VIEW, {})
		return
	# A gift or a swap changed inventories: on disk before the answer.
	if _inventory_net != null:
		_inventory_net.flush_pending_save(SAVE_REASON_DIALOGUE)
	_send_result(peer_id, request_id, true, "", view)


## Sends every conversation the server ended to its player, and to nobody
## else.
func _flush_events() -> void:
	var dialogue: NpcDialogue = _dialogue()
	if dialogue == null or network == null or not network.is_server():
		return
	for event: Dictionary in dialogue.drain_events():
		var player_id: String = str(event.get(NpcDialogue.KEY_PLAYER_ID, ""))
		var peer_id: int = network.peer_of_player(player_id)
		if peer_id == 0 or not network.can_send_to(peer_id):
			continue
		var raw: Variant = event.get(NpcDialogue.KEY_VIEW, null)
		var view: Dictionary = _sendable(raw as Dictionary if typeof(raw) == TYPE_DICTIONARY else {}, player_id)
		if view.is_empty() or bool(view[NpcDialogue.KEY_OPEN]):
			continue
		_rpc_dialogue_ended.rpc_id(peer_id, view)


## The view as it goes on the wire, or {} (logged, counted) when it does
## not fit. The server holds its own output to the rule its clients apply.
func _sendable(source: Dictionary, player_id: String) -> Dictionary:
	var cut: Array = []
	var view: Dictionary = wire_view(source, cut)
	if not cut.is_empty():
		cut_text_count += cut.size()
		GameLogger.warning("net", "npc dialogue text cut to the wire limit", {"entity_id": str(source.get(NpcDialogue.KEY_NPC_ID, "")), "player_id": player_id, "texts": cut.size(), "module": MODULE_NAME, "operation": "send_view"})
	if view.is_empty() or not ClientDialogueState.view_error(view).is_empty():
		unsendable_view_count += 1
		GameLogger.error("net", "npc dialogue view not sent", {"entity_id": str(source.get(NpcDialogue.KEY_NPC_ID, "")), "player_id": player_id, "module": MODULE_NAME, "operation": "send_view"})
		return {}
	return view


func _send_result(peer_id: int, request_id: int, ok: bool, reason: String, view: Dictionary) -> void:
	if network.can_send_to(peer_id):
		_rpc_dialogue_result.rpc_id(peer_id, request_id, ok, reason, view)


## The conversations of the world, or null (no social layer, no NPCs).
func _dialogue() -> NpcDialogue:
	var social: NpcSocial = NpcSocial.of_world(_world) if _world != null else null
	return social.dialogue() if social != null else null


# ------------------------------------------------------------ client side

## Asks the server to talk to the NPC `npc_id`. Returns the request id the
## `dialogue_result` signal will carry, or NO_REQUEST when nothing was sent
## (not a joined client). Nothing is decided here; the same goes for the
## two functions below.
func request_start(npc_id: String) -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_talk_request(_last_request_id, npc_id)
	return _last_request_id


## Makes the choice `choice_id` of the view the mirror shows. NO_REQUEST
## when the mirror is in no conversation.
func request_choose(choice_id: String) -> int:
	if not _can_request() or not client_state.open:
		return NO_REQUEST
	_last_request_id += 1
	_conversation_requests[_last_request_id] = true
	send_raw_choose_request(_last_request_id, client_state.npc_id, client_state.turn, choice_id)
	return _last_request_id


## Ends the local player's conversation.
func request_end() -> int:
	if not _can_request():
		return NO_REQUEST
	_last_request_id += 1
	_conversation_requests[_last_request_id] = true
	send_raw_end_request(_last_request_id)
	return _last_request_id


## The send_raw_* functions send an arbitrary request without any
## client-side check (tests: malformed or premature input through the real
## RPC path).
func send_raw_talk_request(request_id: Variant, npc_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_talk.rpc_id(NetworkService.SERVER_PEER_ID, request_id, npc_id)


func send_raw_choose_request(request_id: Variant, npc_id: Variant, turn: Variant, choice_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_choose.rpc_id(NetworkService.SERVER_PEER_ID, request_id, npc_id, turn, choice_id)


func send_raw_end_request(request_id: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_end.rpc_id(NetworkService.SERVER_PEER_ID, request_id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_dialogue_result(request_id: Variant, ok: Variant, reason: Variant, view: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if not result_error(request_id, ok, reason, view).is_empty():
		_reject_payload("result")
		return
	var about_conversation: bool = _conversation_requests.erase(int(request_id))
	if bool(ok):
		client_state.apply_view(view)
	else:
		client_state.apply_error(str(reason), about_conversation and str(reason) == NpcDialogue.REASON_NOT_TALKING)
	dialogue_result.emit(int(request_id), bool(ok), str(reason))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_dialogue_ended(view: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	# Only an end is ever sent this way.
	if not ClientDialogueState.view_error(view).is_empty() or bool((view as Dictionary)[NpcDialogue.KEY_OPEN]):
		_reject_payload("ended")
		return
	if client_state.apply_view(view, false).is_empty():
		dialogue_ended.emit((view as Dictionary).duplicate(true))


func _can_request() -> bool:
	return network != null and network.is_client() and not network.client_state.local_player_id.is_empty()


func _reject_payload(message: String) -> void:
	rejected_payload_count += 1
	GameLogger.warning("npc_dialogue_net", "npc dialogue payload dropped", {"message": message, "module": MODULE_NAME, "operation": "apply_payload"})
