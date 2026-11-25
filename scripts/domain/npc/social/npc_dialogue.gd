class_name NpcDialogue
extends RefCounted
## Conversations between a player and an NPC (F-31, docs/09 §17.16 "대화").
## Server only. One small state machine per conversation, fixed choices,
## every answer computed from the NPC's personality, what it thinks of the
## player (RelationshipStore), how afraid it is, its needs and its record of
## that player (NpcSocialState). The words come from NpcDialogueLines. No
## text is generated and no random number is drawn: which variant of a line
## an NPC says is counted (NpcSocialState.line_counter).
##
## A conversation is between one player and one NPC; an NPC talks to one
## player at a time. Conversations are NOT saved: a restart, a cell that
## stops being simulated, a player that leaves or walks away, an NPC that
## flees, is hurt or dies end them. What they changed (relationship,
## record, items) is saved with the NPC as it happens.
##
## start() / choose() / end() return an ActionResult. A failure is a
## request that could not be looked at (reason: REASON_*). A success
## carries the VIEW the player gets (event = view):
##   {npc_id, npc_name, open, turn, line, choices: [[choice_id, text], ...],
##    end_reason}
## `open` false = the conversation is over (or never began: the NPC would
## not talk; `line` is what it said, `end_reason` why). `turn` counts the
## views of one conversation: a choice names the turn it answers, so a
## choice that was made for an older view is refused (stale_turn).
##
## Nodes and choices:
##   asleep  (the NPC sleeps)  wake, leave
##   root    greet (once per conversation), who, give, news, trade, join,
##           threaten, leave
##   give    give:<n> (an item of the player's that is food, a drink or a
##           treatment; one unit really moves into the NPC's inventory),
##           back
##   trade   trade:<n> (one unit for one unit, both really move in one
##           inventory transaction), back
## "join" only writes the request down (the record, the signal
## join_requested) and says how the NPC leans; F-32 decides what happens.
##
## A conversation that went badly (a threat, a sleeper startled awake, a
## player that keeps asking an NPC that will not talk) is written into the
## record (bad_talks, last_bad_reason, last_bad_at) and announced
## (conversation_went_badly): the hook F-32 uses for hostility. Nobody
## attacks anybody here.

signal conversation_started(npc_id: String, player_id: String)
signal conversation_ended(npc_id: String, player_id: String, reason: String)
## `reason`: NpcSocialState.BAD_REASONS.
signal conversation_went_badly(npc_id: String, player_id: String, reason: String)
## `lean`: NpcReactionRules.join_lean at that moment (0..1).
signal join_requested(npc_id: String, player_id: String, lean: float)
signal gift_given(npc_id: String, player_id: String, item_definition_id: String)
signal trade_made(npc_id: String, player_id: String, given_definition_id: String, taken_definition_id: String)

## View keys.
const KEY_NPC_ID: String = "npc_id"
const KEY_NPC_NAME: String = "npc_name"
const KEY_OPEN: String = "open"
const KEY_TURN: String = "turn"
const KEY_LINE: String = "line"
const KEY_CHOICES: String = "choices"
const KEY_END_REASON: String = "end_reason"
## Keys of an event of drain_events(): a conversation the server ended.
const KEY_PLAYER_ID: String = "player_id"
const KEY_VIEW: String = "view"

const NODE_ASLEEP: String = "asleep"
const NODE_ROOT: String = "root"
const NODE_GIVE: String = "give"
const NODE_TRADE: String = "trade"

const CHOICE_GREET: String = "greet"
const CHOICE_WHO: String = "who"
const CHOICE_GIVE: String = "give"
const CHOICE_NEWS: String = "news"
const CHOICE_TRADE: String = "trade"
const CHOICE_JOIN: String = "join"
const CHOICE_THREATEN: String = "threaten"
const CHOICE_LEAVE: String = "leave"
const CHOICE_BACK: String = "back"
const CHOICE_WAKE: String = "wake"
const CHOICE_GIVE_PREFIX: String = "give:"
const CHOICE_TRADE_PREFIX: String = "trade:"
const CHOICE_ID_MAX_LENGTH: int = 16

## Why a request could not be looked at.
const REASON_UNAVAILABLE: String = "dialogue_unavailable"
const REASON_UNKNOWN_PLAYER: String = "unknown_player"
const REASON_UNKNOWN_NPC: String = NpcService.REASON_UNKNOWN_NPC
const REASON_NPC_DEAD: String = "npc_dead"
const REASON_NPC_UNAVAILABLE: String = "npc_unavailable"
const REASON_TOO_FAR: String = "too_far"
const REASON_NO_LINE_OF_SIGHT: String = "no_line_of_sight"
const REASON_NPC_BUSY: String = "npc_busy"
const REASON_NPC_TALKING: String = "npc_talking"
const REASON_NOT_TALKING: String = "not_talking"
const REASON_STALE_TURN: String = "stale_turn"
const REASON_BAD_CHOICE: String = "bad_choice"

## Why a conversation is over (view.end_reason; "" while it is open).
const END_PLAYER_LEFT: String = "player_left"
const END_NPC_ENDED: String = "npc_ended"
const END_REFUSED: String = "refused"
const END_TOO_FAR: String = "too_far"
const END_TIMEOUT: String = "timeout"
const END_NPC_BUSY: String = "npc_busy"
const END_NPC_HURT: String = "npc_hurt"
const END_NPC_GONE: String = "npc_gone"
const END_PLAYER_GONE: String = "player_gone"
const END_PLAYER_UNABLE: String = "player_unable"
const END_REASONS: PackedStringArray = [END_PLAYER_LEFT, END_NPC_ENDED, END_REFUSED, END_TOO_FAR, END_TIMEOUT, END_NPC_BUSY, END_NPC_HURT, END_NPC_GONE, END_PLAYER_GONE, END_PLAYER_UNABLE]

const NEWS_DISTANCE_STEP_M: float = 10.0
const COMPASS_SECTORS: int = 8
const NEED_URGENCY_PER_CATEGORY: float = 0.5
const GIFT_REPEAT_FACTOR: float = 0.5

## Diagnostics.
var started_count: int = 0
var refused_count: int = 0
var ended_count: int = 0
var choice_count: int = 0

var _social_ref: WeakRef
var _lines: NpcDialogueLines
var _by_player: Dictionary[String, Session] = {}
var _player_by_npc: Dictionary[String, String] = {}
## "npc_id|player_id" -> scheduler time until which the NPC will not talk.
var _refuse_until: Dictionary[String, int] = {}
var _events: Array[Dictionary] = []


class Session extends RefCounted:
	var player_id: String = ""
	var npc_id: String = ""
	var npc_name: String = ""
	var node: String = NODE_ROOT
	var turn: int = 0
	## Choices made in this conversation.
	var choices_made: int = 0
	var greeted: bool = false
	var news_told: int = 0
	var last_activity_usec: int = 0
	## The choices of the current view: [[id, text], ...].
	var choices: Array = []
	## give:<n> -> item instance id of the player's.
	var give_items: PackedStringArray = []
	## trade:<n> -> {give: player's item id, take: the NPC's item id}.
	var offers: Array[Dictionary] = []


func _init(social: NpcSocial, lines: NpcDialogueLines) -> void:
	_social_ref = weakref(social)
	_lines = lines


func lines() -> NpcDialogueLines:
	return _lines


# ------------------------------------------------------------ queries

func is_talking(player_id: String) -> bool:
	return _by_player.has(player_id)


## The player this NPC is in a conversation with ("" = none), also one
## that stands over it while it sleeps.
func partner_of(npc_id: String) -> String:
	return _player_by_npc.get(npc_id, "")


## The player this NPC talks with ("" = none, also while it sleeps through
## a conversation that has not woken it).
func talker_of(npc_id: String) -> String:
	var player_id: String = _player_by_npc.get(npc_id, "")
	var session: Session = _by_player.get(player_id, null)
	return player_id if session != null and session.node != NODE_ASLEEP else ""


## The NPC a player talks with ("" = none).
func npc_of(player_id: String) -> String:
	var session: Session = _by_player.get(player_id, null)
	return session.npc_id if session != null else ""


func session_count() -> int:
	return _by_player.size()


## The view of a player's open conversation ({} = none).
func view_of(player_id: String) -> Dictionary:
	var session: Session = _by_player.get(player_id, null)
	return _view(session, "", "") if session != null else {}


## Conversations the server ended since the last call:
## [{player_id, view}], oldest first. The network module sends them.
func drain_events() -> Array[Dictionary]:
	var drained: Array[Dictionary] = _events
	_events = []
	return drained


# ------------------------------------------------------------ requests

## The player wants to talk to the NPC.
func start(world: ServerWorld, player_id: String, npc_id: String) -> ActionResult:
	var social: NpcSocial = _social_ref.get_ref() as NpcSocial
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService if world != null else null
	if social == null or npcs == null:
		return ActionResult.failure(REASON_UNAVAILABLE)
	var player: PlayerState = world.get_player(player_id)
	if player == null or not world.is_online(player_id) or not player.has_character():
		return ActionResult.failure(REASON_UNKNOWN_PLAYER)
	var blocked: String = world.player_action_block_reason(player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var npc: NpcState = npcs.get_npc(npc_id)
	if npc == null:
		return ActionResult.failure(REASON_UNKNOWN_NPC)
	var vitals: NpcVitals = NpcVitals.of(npc)
	if vitals != null and not vitals.is_alive():
		return ActionResult.failure(REASON_NPC_DEAD)
	if not npcs.is_awake(npc_id):
		return ActionResult.failure(REASON_NPC_UNAVAILABLE)
	var settings: NpcSocialSettings = social.settings
	if _flat_distance(player.position, npc.position) > settings.talk_range_m:
		return ActionResult.failure(REASON_TOO_FAR)
	if world.is_line_blocked(player.position, npc.position):
		return ActionResult.failure(REASON_NO_LINE_OF_SIGHT)
	var current: Session = _by_player.get(player_id, null)
	if current != null and current.npc_id == npc_id:
		return ActionResult.success(_view(current, "", ""))
	var partner: String = _player_by_npc.get(npc_id, "")
	if not partner.is_empty() and partner != player_id:
		return ActionResult.failure(REASON_NPC_TALKING)
	if NpcSocial.is_fleeing(npc):
		return ActionResult.failure(REASON_NPC_BUSY)
	if current != null:
		_close(world, npcs, current, END_PLAYER_LEFT, false)
	var state: NpcSocialState = NpcSocialState.of(npc)
	if state == null:
		return ActionResult.failure(REASON_UNAVAILABLE)
	var now: int = social.now_usec()
	var world_time: float = world.clock.world_time_sec
	var record: NpcSocialState.Record = state.ensure_record(player_id, world_time, settings.max_known_players)
	var definition: NpcDefinition = npcs.definition_of(npc_id)
	var session: Session = Session.new()
	session.player_id = player_id
	session.npc_id = npc_id
	session.npc_name = definition.display_name if definition != null else ""
	session.last_activity_usec = now
	# It would not talk a moment ago: asking again is pestering.
	var refuse_key: String = _refuse_key(npc_id, player_id)
	if int(_refuse_until.get(refuse_key, 0)) > now:
		record.pester_streak += 1
		if record.pester_streak >= settings.pester_limit:
			record.pester_streak = 0
			social.adjust_relationship(world, npcs, npc, player_id, {"resentment": settings.pester_resentment})
			_went_badly(world, state, record, npc_id, player_id, NpcSocialState.BAD_PESTERED)
		state.touch()
		return _refuse(session, state, record, "refuse_again")
	_refuse_until.erase(refuse_key)
	if social.is_asleep(npc, now):
		session.node = NODE_ASLEEP
		_open(session)
		return ActionResult.success(_show(session, state, "asleep", {}, [CHOICE_WAKE, CHOICE_LEAVE]))
	var view: NpcReactionRules.View = social.view_of(world, npcs, npc, player_id)
	if NpcReactionRules.fear(view, settings) >= settings.refuse_fear:
		_set_refusing(refuse_key, now, settings)
		return _refuse(session, state, record, "refuse_fear")
	if view.relationship != null and view.relationship.resentment >= settings.refuse_resentment:
		_set_refusing(refuse_key, now, settings)
		return _refuse(session, state, record, "refuse_distrust")
	record.pester_streak = 0
	record.talks += 1
	record.last_talk_at = world_time
	state.touch()
	_open(session)
	started_count += 1
	conversation_started.emit(npc_id, player_id)
	social.on_conversation_changed(world, npcs, npc_id)
	return ActionResult.success(_show_root(session, state, "open_" + _disposition(view, settings), {}))


## The player chose `choice_id` of the view `turn` of its conversation
## with `npc_id`.
func choose(world: ServerWorld, player_id: String, npc_id: String, turn: int, choice_id: String) -> ActionResult:
	var social: NpcSocial = _social_ref.get_ref() as NpcSocial
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService if world != null else null
	if social == null or npcs == null:
		return ActionResult.failure(REASON_UNAVAILABLE)
	var session: Session = _by_player.get(player_id, null)
	if session == null or session.npc_id != npc_id:
		return ActionResult.failure(REASON_NOT_TALKING)
	if turn != session.turn:
		return ActionResult.failure(REASON_STALE_TURN)
	if not _offers_choice(session, choice_id):
		return ActionResult.failure(REASON_BAD_CHOICE)
	var settings: NpcSocialSettings = social.settings
	var now: int = social.now_usec()
	var broken: String = _broken_reason(world, npcs, social, session, now)
	if not broken.is_empty():
		return ActionResult.success(_close(world, npcs, session, broken, false))
	var npc: NpcState = npcs.get_npc(npc_id)
	var player: PlayerState = world.get_player(player_id)
	var state: NpcSocialState = NpcSocialState.of(npc)
	var record: NpcSocialState.Record = state.ensure_record(player_id, world.clock.world_time_sec, settings.max_known_players)
	var view: NpcReactionRules.View = social.view_of(world, npcs, npc, player_id)
	session.last_activity_usec = now
	session.choices_made += 1
	choice_count += 1
	if choice_id == CHOICE_LEAVE:
		var parting: String = "" if session.node == NODE_ASLEEP else _say(state, "bye_" + _disposition(view, settings), {})
		return ActionResult.success(_close(world, npcs, session, END_PLAYER_LEFT, false, parting))
	if choice_id == CHOICE_WAKE:
		return ActionResult.success(_wake(world, npcs, social, session, npc, state, record, view))
	if choice_id == CHOICE_THREATEN:
		return ActionResult.success(_threaten(world, npcs, social, session, npc, state, record, view))
	var definition: NpcDefinition = npcs.definition_of(npc_id)
	var limit: int = settings.talk_max_turns + int(round(float(settings.talk_turns_extraversion_bonus) * view.trait_of("extraversion")))
	if session.choices_made > limit:
		_set_refusing(_refuse_key(npc_id, player_id), now, settings)
		return ActionResult.success(_close(world, npcs, session, END_NPC_ENDED, false, _say(state, "enough", {})))
	var line_key: String = ""
	var params: Dictionary = {"name": session.npc_name}
	if choice_id == CHOICE_BACK:
		line_key = "back"
	elif choice_id == CHOICE_GREET:
		session.greeted = true
		var today: int = social.day_of(world.clock.world_time_sec)
		if record.greeted_day == today:
			line_key = "greet_again"
		else:
			record.greeted_day = today
			state.touch()
			line_key = "greet_" + _disposition(view, settings)
			social.adjust_relationship(world, npcs, npc, player_id, {"trust": settings.greet_trust, "liking": settings.greet_liking})
	elif choice_id == CHOICE_WHO:
		if NpcReactionRules.trust(view, settings) < settings.who_min_trust:
			line_key = "who_refuse"
		else:
			line_key = "who_open" if view.trait_of("extraversion") >= NpcReactionRules.AVERAGE_TRAIT else "who_guarded"
	elif choice_id == CHOICE_NEWS:
		var told: Dictionary = _news(world, social, session, npc, view)
		line_key = str(told["line"])
		params.merge(told["params"] as Dictionary)
	elif choice_id == CHOICE_JOIN:
		line_key = _join(world, social, npc_id, player_id, state, record, view)
	elif choice_id == CHOICE_GIVE:
		return ActionResult.success(_show_give(world, social, session, npc, player, state))
	elif choice_id.begins_with(CHOICE_GIVE_PREFIX):
		line_key = _give(world, npcs, social, session, npc, player, state, record, view, choice_id.trim_prefix(CHOICE_GIVE_PREFIX).to_int(), params)
	elif choice_id == CHOICE_TRADE:
		return ActionResult.success(_show_trade(world, social, session, npc, player, state, view))
	elif choice_id.begins_with(CHOICE_TRADE_PREFIX):
		line_key = _trade(world, npcs, social, session, npc, player, choice_id.trim_prefix(CHOICE_TRADE_PREFIX).to_int())
	if definition == null and session.npc_name.is_empty():
		params["name"] = "..."
	return ActionResult.success(_show_root(session, state, line_key, params))


## The player ends its conversation. A player that is in none gets
## not_talking.
func end(world: ServerWorld, player_id: String) -> ActionResult:
	var session: Session = _by_player.get(player_id, null)
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService if world != null else null
	if session == null or npcs == null:
		return ActionResult.failure(REASON_NOT_TALKING)
	return ActionResult.success(_close(world, npcs, session, END_PLAYER_LEFT, false))


## Ends the conversation of an NPC, if it is in one (it left memory, died,
## was hurt). The player is told through drain_events().
func end_for_npc(world: ServerWorld, npc_id: String, reason: String) -> void:
	var session: Session = _by_player.get(_player_by_npc.get(npc_id, ""), null)
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService if world != null else null
	if session != null:
		_close(world, npcs, session, reason, true)


## Ends the conversation of a player that left the server (nobody is told).
func end_for_player(world: ServerWorld, player_id: String) -> void:
	var session: Session = _by_player.get(player_id, null)
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService if world != null else null
	if session != null:
		_close(world, npcs, session, END_PLAYER_GONE, false)


## Once per tick: conversations that cannot go on are ended.
func step(world: ServerWorld, npcs: NpcService, now: int) -> void:
	if _by_player.is_empty():
		if not _refuse_until.is_empty():
			for key: String in _refuse_until.keys():
				if _refuse_until[key] <= now:
					_refuse_until.erase(key)
		return
	var social: NpcSocial = _social_ref.get_ref() as NpcSocial
	if social == null:
		return
	var player_ids: PackedStringArray = PackedStringArray(_by_player.keys())
	player_ids.sort()
	for player_id: String in player_ids:
		var session: Session = _by_player.get(player_id, null)
		if session == null:
			continue
		var broken: String = _broken_reason(world, npcs, social, session, now)
		if not broken.is_empty():
			_close(world, npcs, session, broken, true)


# ------------------------------------------------------------ choices

func _wake(world: ServerWorld, npcs: NpcService, social: NpcSocial, session: Session, npc: NpcState, state: NpcSocialState, record: NpcSocialState.Record, view: NpcReactionRules.View) -> Dictionary:
	var settings: NpcSocialSettings = social.settings
	record.wakes += 1
	state.touch()
	social.adjust_relationship(world, npcs, npc, session.player_id, {"trust": -settings.wake_trust_loss})
	social.feel(world, npc, "anger", settings.wake_anger)
	social.feel(world, npc, "surprise", settings.wake_anger)
	if NpcReactionRules.fear(view, settings) >= settings.wake_startle_fear:
		social.feel(world, npc, "fear", settings.wake_anger)
		_went_badly(world, state, record, session.npc_id, session.player_id, NpcSocialState.BAD_WOKEN)
		_set_refusing(_refuse_key(session.npc_id, session.player_id), social.now_usec(), settings)
		var line: String = _say(state, "wake_startled", {})
		var closed: Dictionary = _close(world, npcs, session, END_NPC_ENDED, false, line)
		social.rouse(world, npcs, npc)
		return closed
	session.node = NODE_ROOT
	record.talks += 1
	record.last_talk_at = world.clock.world_time_sec
	started_count += 1
	conversation_started.emit(session.npc_id, session.player_id)
	social.rouse(world, npcs, npc)
	return _show_root(session, state, "wake_grumpy", {})


func _threaten(world: ServerWorld, npcs: NpcService, social: NpcSocial, session: Session, npc: NpcState, state: NpcSocialState, record: NpcSocialState.Record, view: NpcReactionRules.View) -> Dictionary:
	var settings: NpcSocialSettings = social.settings
	var bold: float = NpcReactionRules.boldness(view, settings)
	var defiant: bool = bold >= settings.defiant_boldness
	# A timid NPC is frightened more; a bold one resents it more.
	social.adjust_relationship(world, npcs, npc, session.player_id, {
		"fear": settings.threaten_fear * (1.5 - bold),
		"trust": -settings.threaten_trust_loss,
		"resentment": settings.threaten_resentment * (0.5 + bold),
	})
	social.feel(world, npc, "anger" if defiant else "fear", settings.threaten_anger)
	_went_badly(world, state, record, session.npc_id, session.player_id, NpcSocialState.BAD_THREATENED)
	_set_refusing(_refuse_key(session.npc_id, session.player_id), social.now_usec(), settings)
	return _close(world, npcs, session, END_NPC_ENDED, false, _say(state, "threat_defiant" if defiant else "threat_cowed", {}))


func _join(world: ServerWorld, social: NpcSocial, npc_id: String, player_id: String, state: NpcSocialState, record: NpcSocialState.Record, view: NpcReactionRules.View) -> String:
	var settings: NpcSocialSettings = social.settings
	var lean: float = NpcReactionRules.join_lean(view, settings)
	record.join_requests = mini(record.join_requests + 1, NpcSocialState.MAX_SAFE_INT)
	record.join_last_at = world.clock.world_time_sec
	record.join_last_lean = lean
	state.touch()
	join_requested.emit(npc_id, player_id, lean)
	if lean >= settings.join_maybe_lean:
		return "join_maybe"
	return "join_no" if lean < settings.join_no_lean else "join_later"


## What the NPC knows: first a place it remembers as dangerous, then a
## building it emptied. {line, params}.
func _news(world: ServerWorld, social: NpcSocial, session: Session, npc: NpcState, view: NpcReactionRules.View) -> Dictionary:
	var settings: NpcSocialSettings = social.settings
	if NpcReactionRules.trust(view, settings) < settings.news_min_trust:
		return {"line": "news_refuse", "params": {}}
	var told: Array[Dictionary] = []
	var danger: Variant = _strongest_danger(world, npc, settings)
	if danger != null:
		told.append({"line": "news_danger", "params": _direction_params(npc.position, danger as Vector3)})
	var emptied: Variant = _nearest_emptied(social, npc, settings)
	if emptied != null:
		told.append({"line": "news_emptied", "params": _direction_params(npc.position, emptied as Vector3)})
	if session.news_told >= told.size():
		return {"line": "news_none", "params": {}}
	session.news_told += 1
	return told[session.news_told - 1]


func _show_give(world: ServerWorld, social: NpcSocial, session: Session, npc: NpcState, player: PlayerState, state: NpcSocialState) -> Dictionary:
	if NpcSurvivalSense.inventory_of(npc).is_empty():
		return _show_root(session, state, "give_cannot", {})
	session.give_items = PackedStringArray()
	var ids: Array = []
	var seen_definitions: Dictionary = {}
	for item: ItemInstance in NpcSurvivalSense.items_of(world, player.inventory_id):
		var definition: ItemDefinition = world.inventory.definition_of(item.item_instance_id)
		var kind: String = social.kind_of(definition)
		if seen_definitions.has(item.definition_id) or not (kind == NpcSurvivalSense.KIND_FOOD or kind == NpcSurvivalSense.KIND_DRINK or kind == NpcSurvivalSense.KIND_MEDICAL):
			continue
		seen_definitions[item.definition_id] = true
		ids.append([CHOICE_GIVE_PREFIX + str(session.give_items.size()), _lines.choice("give_item", {"item": _item_name(definition)})])
		session.give_items.append(item.item_instance_id)
		if session.give_items.size() >= social.settings.give_list_size:
			break
	if ids.is_empty():
		return _show_root(session, state, "give_nothing", {})
	session.node = NODE_GIVE
	ids.append([CHOICE_BACK, _lines.choice(CHOICE_BACK)])
	return _present(session, _say(state, "give_ask", {}), ids)


## One unit of the chosen item moves from the player to the NPC. Returns
## the line key.
func _give(world: ServerWorld, npcs: NpcService, social: NpcSocial, session: Session, npc: NpcState, player: PlayerState, state: NpcSocialState, record: NpcSocialState.Record, view: NpcReactionRules.View, index: int, params: Dictionary) -> String:
	var settings: NpcSocialSettings = social.settings
	var item: ItemInstance = world.inventory.get_item(session.give_items[index]) if index >= 0 and index < session.give_items.size() else null
	var npc_inventory: String = NpcSurvivalSense.inventory_of(npc)
	if item == null or item.location_type != ItemInstance.LOCATION_INVENTORY or item.location_id != player.inventory_id:
		return "give_nothing"
	if npc_inventory.is_empty():
		return "give_cannot"
	if NpcReactionRules.fear(view, settings) >= settings.gift_refuse_fear:
		return "give_refuse_fear"
	var definition: ItemDefinition = world.inventory.definition_of(item.item_instance_id)
	var definition_id: String = item.definition_id
	var urgency: float = _need_urgency(social, npc, view, social.kind_of(definition))
	var trust_before: float = NpcReactionRules.trust(view, settings)
	var moved: ActionResult = world.inventory.transfer_item(player.inventory_id, item.item_instance_id, npc_inventory, 1)
	if not moved.ok:
		return "give_full" if moved.reason == InventoryService.REASON_INVENTORY_FULL else "give_cannot"
	npcs.mark_npc_dirty(npc.npc_id)
	var today: int = social.day_of(world.clock.world_time_sec)
	if record.gift_day != today:
		record.gift_day = today
		record.gifts_today = 0
	var worth: float = (1.0 + (settings.gift_need_bonus - 1.0) * urgency) * pow(GIFT_REPEAT_FACTOR, float(mini(record.gifts_today, 30)))
	record.gifts_today += 1
	record.gifts_total = mini(record.gifts_total + 1, NpcSocialState.MAX_SAFE_INT)
	state.touch()
	social.adjust_relationship(world, npcs, npc, session.player_id, {
		"trust": settings.gift_trust * worth,
		"liking": settings.gift_liking * worth,
		"fear": -settings.gift_fear_relief * worth,
		"dependence": settings.gift_dependence * worth,
	})
	social.feel(world, npc, "happiness", settings.gift_liking * worth)
	social.feel(world, npc, "hope", settings.gift_liking * worth)
	params["item"] = _item_name(definition)
	gift_given.emit(npc.npc_id, session.player_id, definition_id)
	if urgency > 0.0:
		return "give_thanks_need"
	return "give_wary" if trust_before < settings.who_min_trust else "give_thanks"


func _show_trade(world: ServerWorld, social: NpcSocial, session: Session, npc: NpcState, player: PlayerState, state: NpcSocialState, view: NpcReactionRules.View) -> Dictionary:
	var settings: NpcSocialSettings = social.settings
	if NpcReactionRules.trust(view, settings) < settings.trade_min_trust:
		return _show_root(session, state, "trade_refuse", {})
	session.offers = _offers(world, social, npc, player, view)
	if session.offers.is_empty():
		return _show_root(session, state, "trade_nothing", {})
	var ids: Array = []
	for index: int in session.offers.size():
		var offer: Dictionary = session.offers[index]
		ids.append([CHOICE_TRADE_PREFIX + str(index), _lines.choice("trade_item", {"give": _item_name(world.inventory.definition_of(str(offer["give"]))), "take": _item_name(world.inventory.definition_of(str(offer["take"])))})])
	session.node = NODE_TRADE
	ids.append([CHOICE_BACK, _lines.choice(CHOICE_BACK)])
	return _present(session, _say(state, "trade_ask", {}), ids)


## One unit for one unit, in one inventory transaction. Returns the line key.
func _trade(world: ServerWorld, npcs: NpcService, social: NpcSocial, session: Session, npc: NpcState, player: PlayerState, index: int) -> String:
	if index < 0 or index >= session.offers.size():
		return "trade_failed"
	var offer: Dictionary = session.offers[index]
	var npc_inventory: String = NpcSurvivalSense.inventory_of(npc)
	var given: ItemInstance = world.inventory.get_item(str(offer["give"]))
	var taken: ItemInstance = world.inventory.get_item(str(offer["take"]))
	if npc_inventory.is_empty() or given == null or taken == null or given.location_id != player.inventory_id or taken.location_id != npc_inventory:
		return "trade_failed"
	var given_definition_id: String = given.definition_id
	var taken_definition_id: String = taken.definition_id
	var swapped: ActionResult = world.inventory.exchange_items(player.inventory_id, [{"item_instance_id": given.item_instance_id, "quantity": 1}], npc_inventory, [{"item_instance_id": taken.item_instance_id, "quantity": 1}])
	if not swapped.ok:
		return "trade_failed"
	npcs.mark_npc_dirty(npc.npc_id)
	social.adjust_relationship(world, npcs, npc, session.player_id, {"trust": social.settings.trade_trust})
	trade_made.emit(npc.npc_id, session.player_id, given_definition_id, taken_definition_id)
	return "trade_done"


## What the NPC would swap, one unit for one unit: for each kind of item
## the player carries, the most valuable thing the NPC would give for it.
## [{give: the player's item id, take: the NPC's item id}].
func _offers(world: ServerWorld, social: NpcSocial, npc: NpcState, player: PlayerState, view: NpcReactionRules.View) -> Array[Dictionary]:
	var settings: NpcSocialSettings = social.settings
	var offers: Array[Dictionary] = []
	var npc_inventory: String = NpcSurvivalSense.inventory_of(npc)
	if npc_inventory.is_empty():
		return offers
	# What the NPC can spare: [item, kind, worth to itself].
	var units: Dictionary = {}
	var carried: Array[ItemInstance] = NpcSurvivalSense.items_of(world, npc_inventory)
	for item: ItemInstance in carried:
		var kind: String = social.kind_of(world.inventory.definition_of(item.item_instance_id))
		units[kind] = int(units.get(kind, 0)) + item.quantity
	var spare: Array[Array] = []
	var spare_definitions: Dictionary = {}
	for item: ItemInstance in carried:
		var kind: String = social.kind_of(world.inventory.definition_of(item.item_instance_id))
		if spare_definitions.has(item.definition_id):
			continue
		if (kind == NpcSurvivalSense.KIND_FOOD or kind == NpcSurvivalSense.KIND_DRINK) and int(units[kind]) <= settings.trade_keep_units:
			continue
		if kind == NpcSurvivalSense.KIND_WEAPON and int(units[kind]) <= 1:
			continue
		spare_definitions[item.definition_id] = true
		spare.append([item, kind, _worth(social, npc, view, kind)])
	if spare.is_empty():
		return offers
	var margin: float = 1.0 + settings.trade_greed * view.trait_of("self_interest") - settings.trade_trust_discount * NpcReactionRules.trust(view, settings)
	var seen_definitions: Dictionary = {}
	for item: ItemInstance in NpcSurvivalSense.items_of(world, player.inventory_id):
		if seen_definitions.has(item.definition_id):
			continue
		seen_definitions[item.definition_id] = true
		var gets: float = _worth(social, npc, view, social.kind_of(world.inventory.definition_of(item.item_instance_id)))
		var best: ItemInstance = null
		var best_worth: float = -1.0
		for entry: Array in spare:
			var candidate: ItemInstance = entry[0]
			if candidate.definition_id == item.definition_id or gets < float(entry[2]) * margin:
				continue
			if float(entry[2]) > best_worth:
				best = candidate
				best_worth = float(entry[2])
		if best != null:
			offers.append({"give": item.item_instance_id, "take": best.item_instance_id})
			if offers.size() >= settings.trade_list_size:
				break
	return offers


## What one unit of a kind is worth to this NPC now.
func _worth(social: NpcSocial, npc: NpcState, view: NpcReactionRules.View, kind: String) -> float:
	var settings: NpcSocialSettings = social.settings
	var base: float = settings.worth_other
	match kind:
		NpcSurvivalSense.KIND_FOOD:
			base = settings.worth_food
		NpcSurvivalSense.KIND_DRINK:
			base = settings.worth_drink
		NpcSurvivalSense.KIND_MEDICAL:
			base = settings.worth_medical
		NpcSurvivalSense.KIND_WEAPON:
			base = settings.worth_weapon
	return base * (1.0 + (settings.trade_need_bonus - 1.0) * _need_urgency(social, npc, view, kind))


## How much the NPC needs a thing of `kind` now (0 .. 1): its hunger for
## food, its thirst for a drink, its wounds for a treatment.
func _need_urgency(_social: NpcSocial, npc: NpcState, view: NpcReactionRules.View, kind: String) -> float:
	var needs: NpcNeeds = npc.component(NpcNeeds.COMPONENT_ID) as NpcNeeds
	match kind:
		NpcSurvivalSense.KIND_FOOD:
			return clampf(float(needs.category(NpcNeedKind.HUNGER)) * NEED_URGENCY_PER_CATEGORY, 0.0, 1.0) if needs != null else 0.0
		NpcSurvivalSense.KIND_DRINK:
			return clampf(float(needs.category(NpcNeedKind.THIRST)) * NEED_URGENCY_PER_CATEGORY, 0.0, 1.0) if needs != null else 0.0
		NpcSurvivalSense.KIND_MEDICAL:
			return 1.0 if view.npc_hurt else 0.0
	return 0.0


# ------------------------------------------------------------ news

## The place of the NPC's strongest danger memory within range, or null.
func _strongest_danger(world: ServerWorld, npc: NpcState, settings: NpcSocialSettings) -> Variant:
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	if memories == null or memories.count() == 0:
		return null
	var now: float = world.clock.world_time_sec
	var best: Variant = null
	var best_weight: float = settings.news_min_strength
	for memory_id: String in memories.memory_ids():
		var memory: NpcMemory = memories.memory(memory_id)
		if memory == null or not memory.interpretation_tags.has(NpcSurvivalSense.TAG_DANGER) or _flat_distance(memory.location, npc.position) > settings.news_range_m:
			continue
		var weight: float = memory.strength_at(now) * memory.importance
		if weight > best_weight:
			best = memory.location
			best_weight = weight
	return best


## The middle of the nearest building the NPC found empty, or null.
func _nearest_emptied(social: NpcSocial, npc: NpcState, settings: NpcSocialSettings) -> Variant:
	var scavenge: NpcScavengeState = NpcScavengeState.of(npc)
	var homes: NpcHomes = social.homes()
	if scavenge == null or homes == null:
		return null
	var best: Variant = null
	var best_distance: float = settings.news_range_m
	for entry: Dictionary in scavenge.visited:
		if str(entry.get(NpcScavengeState.KEY_RESULT, "")) != NpcScavengeState.RESULT_EMPTY:
			continue
		var centre: Variant = homes.building_center(str(entry.get(NpcScavengeState.KEY_BUILDING_ID, "")))
		if typeof(centre) != TYPE_VECTOR3:
			continue
		var distance: float = _flat_distance(centre as Vector3, npc.position)
		if distance <= best_distance:
			best = centre
			best_distance = distance
	return best


## {dir, dist} of `place` seen from `from`: north is -Z, east is +X.
func _direction_params(from: Vector3, place: Vector3) -> Dictionary:
	var offset: Vector3 = place - from
	var sector: int = posmod(int(round(atan2(offset.x, -offset.z) / (TAU / float(COMPASS_SECTORS)))), COMPASS_SECTORS)
	var distance: float = maxf(round(_flat_distance(from, place) / NEWS_DISTANCE_STEP_M) * NEWS_DISTANCE_STEP_M, NEWS_DISTANCE_STEP_M)
	return {"dir": _lines.line("dir_%d" % sector), "dist": str(int(distance))}


# ------------------------------------------------------------ the machine

func _open(session: Session) -> void:
	_by_player[session.player_id] = session
	_player_by_npc[session.npc_id] = session.player_id


## The NPC will not talk: a line, no conversation.
func _refuse(session: Session, state: NpcSocialState, record: NpcSocialState.Record, line_key: String) -> ActionResult:
	refused_count += 1
	record.refusals = mini(record.refusals + 1, NpcSocialState.MAX_SAFE_INT)
	state.touch()
	return ActionResult.success(_view(session, _say(state, line_key, {}), END_REFUSED, false))


func _set_refusing(refuse_key: String, now: int, settings: NpcSocialSettings) -> void:
	if settings.refuse_cooldown_sec > 0.0:
		_refuse_until[refuse_key] = now + NpcScheduleSettings.to_usec(settings.refuse_cooldown_sec)


func _went_badly(world: ServerWorld, state: NpcSocialState, record: NpcSocialState.Record, npc_id: String, player_id: String, reason: String) -> void:
	record.bad_talks = mini(record.bad_talks + 1, NpcSocialState.MAX_SAFE_INT)
	record.last_bad_reason = reason
	record.last_bad_at = world.clock.world_time_sec
	state.touch()
	GameLogger.info("npc", "a conversation went badly", {"entity_id": npc_id, "player_id": player_id, "reason": reason, "operation": "dialogue"})
	conversation_went_badly.emit(npc_id, player_id, reason)


## The root node with the NPC's line.
func _show_root(session: Session, state: NpcSocialState, line_key: String, params: Dictionary) -> Dictionary:
	session.node = NODE_ROOT
	var ids: PackedStringArray = []
	if not session.greeted:
		ids.append(CHOICE_GREET)
	ids.append_array(PackedStringArray([CHOICE_WHO, CHOICE_GIVE, CHOICE_NEWS, CHOICE_TRADE, CHOICE_JOIN, CHOICE_THREATEN, CHOICE_LEAVE]))
	return _show(session, state, line_key, params, ids)


func _show(session: Session, state: NpcSocialState, line_key: String, params: Dictionary, choice_ids: PackedStringArray) -> Dictionary:
	var shown: Array = []
	for choice_id: String in choice_ids:
		shown.append([choice_id, _lines.choice(choice_id)])
	var full: Dictionary = {"name": session.npc_name}
	full.merge(params, true)
	return _present(session, _say(state, line_key, full), shown)


## A new view of an open conversation: the turn goes on.
func _present(session: Session, line: String, shown: Array) -> Dictionary:
	session.turn += 1
	session.choices = shown
	return _view(session, line, "")


func _view(session: Session, line: String, end_reason: String, open: bool = true) -> Dictionary:
	var still_open: bool = open and end_reason.is_empty()
	return {
		KEY_NPC_ID: session.npc_id,
		KEY_NPC_NAME: session.npc_name,
		KEY_OPEN: still_open,
		KEY_TURN: session.turn,
		KEY_LINE: line,
		KEY_CHOICES: session.choices.duplicate(true) if still_open else [],
		KEY_END_REASON: end_reason,
	}


func _say(state: NpcSocialState, line_key: String, params: Dictionary) -> String:
	if line_key.is_empty():
		return ""
	return _lines.line(line_key, state.next_line_index() if _lines.variant_count(line_key) > 1 else 0, params)


func _offers_choice(session: Session, choice_id: String) -> bool:
	for entry: Variant in session.choices:
		if str((entry as Array)[0]) == choice_id:
			return true
	return false


## Ends a conversation and returns its last view. `announce`: the server
## ended it, the player learns of it through drain_events().
func _close(world: ServerWorld, npcs: NpcService, session: Session, reason: String, announce: bool, line: String = "") -> Dictionary:
	_by_player.erase(session.player_id)
	if _player_by_npc.get(session.npc_id, "") == session.player_id:
		_player_by_npc.erase(session.npc_id)
	ended_count += 1
	var view: Dictionary = _view(session, line, reason, false)
	if announce:
		_events.append({KEY_PLAYER_ID: session.player_id, KEY_VIEW: view})
	conversation_ended.emit(session.npc_id, session.player_id, reason)
	var social: NpcSocial = _social_ref.get_ref() as NpcSocial
	if social != null and world != null and npcs != null:
		social.on_conversation_changed(world, npcs, session.npc_id)
	return view


## "" while the conversation can go on, or why it cannot (END_*).
func _broken_reason(world: ServerWorld, npcs: NpcService, social: NpcSocial, session: Session, now: int) -> String:
	var player: PlayerState = world.get_player(session.player_id)
	if player == null or not world.is_online(session.player_id):
		return END_PLAYER_GONE
	if not world.player_action_block_reason(session.player_id).is_empty():
		return END_PLAYER_UNABLE
	var npc: NpcState = npcs.get_npc(session.npc_id)
	var vitals: NpcVitals = NpcVitals.of(npc)
	if npc == null or not npcs.is_awake(session.npc_id) or (vitals != null and not vitals.is_alive()):
		return END_NPC_GONE
	if NpcSocial.is_fleeing(npc):
		return END_NPC_BUSY
	if _flat_distance(player.position, npc.position) > social.settings.talk_leave_range_m:
		return END_TOO_FAR
	if now - session.last_activity_usec >= NpcScheduleSettings.to_usec(social.settings.talk_idle_timeout_sec):
		return END_TIMEOUT
	return ""


## "warm", "neutral" or "cold": the tone of a line.
static func _disposition(view: NpcReactionRules.View, settings: NpcSocialSettings) -> String:
	if NpcReactionRules.warmth(view, settings) - NpcReactionRules.threat(view, settings) >= settings.greet_warmth:
		return "warm"
	if NpcReactionRules.fear(view, settings) >= settings.hide_fear or (view.relationship != null and view.relationship.resentment >= settings.refuse_resentment * 0.5):
		return "cold"
	return "neutral"


static func _item_name(definition: ItemDefinition) -> String:
	if definition == null:
		return "?"
	return definition.display_name if not definition.display_name.is_empty() else definition.definition_id


static func _refuse_key(npc_id: String, player_id: String) -> String:
	return "%s|%s" % [npc_id, player_id]


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
