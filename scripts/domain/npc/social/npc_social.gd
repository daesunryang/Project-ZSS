class_name NpcSocial
extends NpcStage
## NPCs notice players and react to them (F-31, docs/09 §17.16 "발견과
## 반응"). One NpcStage, stage id "social", added after the behaviours. It
## also owns the conversations (NpcDialogue, dialogue()).
##
## Noticing: every `notice_check_period_sec` (bucketed like the threat
## sensor: the NPCs of one bucket per slot) an awake NPC that is not asleep
## looks for players the way it looks for zombies: within the threat sight
## range, in every direction, the line not blocked by a structure
## (ServerWorld.is_line_blocked). For each player it sees it works out a
## reaction (NpcReactionRules) from its personality, its record of that
## player (RelationshipStore), whether the player is armed, hurt it before
## or was seen killing NPCs (its memories), and how it is itself.
##
## What everybody sees: one public reaction per NPC
## (NpcSocialState.reaction: none / wary / hide / greet / afraid / talk),
## the one towards the player that frightens it most. It is replicated like
## the action label and is not saved.
##
## What the NPC does about it is decided by the decision layer, which asks
## directive() in its hard interrupt step, after the zombies:
##   afraid  -> the flee action, the player as the threat, for as long as
##              it sees the player;
##   talking -> the action "meet", mode talk: it stands and faces the
##              player until the conversation is over;
##   for `attention_sec` after it noticed the player (again after the
##   player was out of sight for `renotice_after_sec`):
##   hide    -> "meet", mode back_off: it walks away to keep its distance;
##   greet   -> "meet", mode approach: it comes over;
##   wary    -> "meet", mode watch: it stands and watches.
## After that it goes on with its day (the label stays while it sees the
## player). This stage decides nothing itself: it asks the scheduler for a
## decision when the answer of directive() changed.
##
## A player that hurts an NPC (NpcHealth.npc_damaged) is remembered: the
## record, the relationship (fear, trust, resentment), a memory, emotions.
## NPCs do not attack players here (F-32).
##
## Save: per NPC the component "social" (NpcSocialState) and the
## relationship records. Who sees whom right now (and until when it has an
## NPC's attention) is this stage's world document, so a server that was
## restarted goes on like one that never stopped: nobody is "noticed anew"
## because of a restart. Whole numbers and names, plus two floats that the
## next look overwrites. Conversations are not saved.

## Emitted when an NPC notices a player (anew).
signal player_noticed(npc_id: String, player_id: String, reaction: String)
## Emitted when a player hurt an NPC (after the record was written).
signal npc_harmed_by_player(npc_id: String, player_id: String)

const STAGE_ID: String = "social"
const BUCKET_COUNT: int = 10
## The action of the decision layer this stage asks for.
const ACTION_MEET: String = "meet"
## Scheduler interrupt reason.
const REASON_PLAYER: String = "player_noticed"
## Record "hard_interrupt" of a decision.
const HARD_PLAYER_FEARED: String = "player_feared"
const HARD_PLAYER_MET: String = "player_met"

## directive() keys.
const KEY_ACTION: String = "action"
const KEY_CODE: String = "code"
const KEY_TARGET: String = "target"
## Target of "meet".
const TARGET_MODE: String = "mode"
const TARGET_PLAYER_ID: String = "player_id"
const TARGET_PLAYER_POSITION: String = "player_position"
const TARGET_HOLD_SEC: String = "hold_sec"
const MODE_WATCH: String = "watch"
const MODE_APPROACH: String = "approach"
const MODE_BACK_OFF: String = "back_off"
const MODE_TALK: String = "talk"
const MODES: PackedStringArray = [MODE_WATCH, MODE_APPROACH, MODE_BACK_OFF, MODE_TALK]

const MEMORY_ATTACKED: String = "attacked_by_player"
const TAG_ATTACKED: String = "attacked"
const TAG_PLAYER: String = "player"
const LABEL_SLEEP: String = "sleep"
const LABEL_FLEE: String = "flee"
const APPROACH_SLACK_M: float = 0.5
const SCHEMA_VERSION: int = 1
const KEY_SCHEMA_VERSION: String = "schema_version"
const KEY_SIGHT: String = "sight"
const KEY_SIGNATURES: String = "signatures"
const KEY_ROUSED: String = "roused_until"
const MAX_SAVED_NPCS: int = 4096
const MAX_SAFE_INT: int = 9007199254740991
const FACE_EPSILON: float = 0.05
const MIN_HOLD_SEC: float = 0.5

## Diagnostics: NPCs looked at so far / in the latest tick, decisions asked
## for, and the wall clock time of the latest tick.
var look_count: int = 0
var last_look_count: int = 0
var poke_count: int = 0
var last_step_usec: int = 0

var settings: NpcSocialSettings

var _sight_range_m: float
var _day_length_world_sec: float
var _weapons: MeleeWeaponCatalog
var _homes: NpcHomes
var _scheduler_ref: WeakRef
var _dialogue: NpcDialogue
var _slot_usec: int
var _world_ref: WeakRef = null
var _npcs_ref: WeakRef = null
## npc_id -> {player_id -> Sighting}.
var _sight: Dictionary[String, Dictionary] = {}
## npc_id -> what directive() said last ("" = nothing).
var _signature: Dictionary[String, String] = {}
## npc_id -> scheduler time until which a sleeper that was woken looks.
var _roused_until: Dictionary[String, int] = {}
## definition_id -> NpcDefinition.personality().
var _traits: Dictionary[String, Dictionary] = {}
## Per tick: player_id -> carries a weapon.
var _armed: Dictionary[String, bool] = {}


class Sighting extends RefCounted:
	var visible: bool = false
	var seen_usec: int = 0
	var attention_until_usec: int = 0
	var reaction: String = NpcReactionRules.NONE
	var fear: float = 0.0
	var distance_m: float = 0.0
	var kills_seen: int = 0
	var kills_stale: bool = true


func _init(social_settings: NpcSocialSettings, lines: NpcDialogueLines, scheduler: NpcScheduler, sight_range_m: float, day_length_world_sec: float, weapons: MeleeWeaponCatalog, homes: NpcHomes) -> void:
	settings = social_settings if social_settings != null else NpcSocialSettings.new()
	_scheduler_ref = weakref(scheduler)
	_sight_range_m = sight_range_m
	_day_length_world_sec = maxf(day_length_world_sec, 1.0)
	_weapons = weapons
	_homes = homes
	_slot_usec = maxi(NpcScheduleSettings.to_usec(settings.notice_check_period_sec) / BUCKET_COUNT, 1)
	_dialogue = NpcDialogue.new(self, lines if lines != null else NpcDialogueLines.new())


## Registers the component "social" and adds the stage. Null (logged) when
## either is refused.
static func install(npcs: NpcService, social_settings: NpcSocialSettings, lines: NpcDialogueLines, scheduler: NpcScheduler, sight_range_m: float, day_length_world_sec: float, weapons: MeleeWeaponCatalog, homes: NpcHomes) -> NpcSocial:
	if npcs == null or social_settings == null or scheduler == null:
		return null
	if npcs.register_component(NpcSocialState.COMPONENT_ID, NpcSocialState.make) != OK:
		return null
	var stage: NpcSocial = NpcSocial.new(social_settings, lines, scheduler, sight_range_m, day_length_world_sec, weapons, homes)
	if npcs.add_stage(stage) != OK:
		return null
	return stage


## The social stage of a world, or null.
static func of_world(world: ServerWorld) -> NpcSocial:
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService if world != null else null
	return npcs.get_stage(STAGE_ID) as NpcSocial if npcs != null else null


func stage_id() -> String:
	return STAGE_ID


func dialogue() -> NpcDialogue:
	return _dialogue


func homes() -> NpcHomes:
	return _homes


func sight_range_m() -> float:
	return _sight_range_m


## The scheduler's clock (action time, usec); 0 without a scheduler.
func now_usec() -> int:
	var scheduler: NpcScheduler = _scheduler()
	return scheduler.clock_usec() if scheduler != null else 0


func _scheduler() -> NpcScheduler:
	return _scheduler_ref.get_ref() as NpcScheduler if _scheduler_ref != null else null


## The calendar day of a world time (0, 1, 2, ...).
func day_of(world_time_sec: float) -> int:
	return int(floor(maxf(world_time_sec, 0.0) / _day_length_world_sec))


static func bucket_of(npc_id: String) -> int:
	return npc_id.get_slice("_", 1).to_int() % BUCKET_COUNT


# ------------------------------------------------------------ NpcStage

func on_npc_woke(world: ServerWorld, _npc: NpcState) -> void:
	_world_ref = weakref(world)
	_npcs_ref = weakref(world.get_system(NpcService.SYSTEM_ID))


func on_npc_slept(world: ServerWorld, npc: NpcState) -> void:
	_forget(world, npc)


func on_npc_left(world: ServerWorld, npc: NpcState, _retired: bool) -> void:
	_forget(world, npc)


func step(world: ServerWorld, npcs: NpcService, action_delta: float, _world_delta: float) -> void:
	last_look_count = 0
	last_step_usec = 0
	_world_ref = weakref(world)
	_npcs_ref = weakref(npcs)
	var scheduler: NpcScheduler = _scheduler()
	if scheduler == null:
		return
	var now: int = scheduler.clock_usec()
	_dialogue.step(world, npcs, now)
	if not is_finite(action_delta) or action_delta <= 0.0:
		return
	var from_slot: int = maxi(now - NpcScheduleSettings.to_usec(action_delta), 0) / _slot_usec
	var to_slot: int = now / _slot_usec
	if to_slot == from_slot or npcs.awake_count() == 0:
		return
	var players: Array[PlayerState] = _players(world)
	# Nobody to see and nobody was seen: nothing to do.
	if players.is_empty() and _sight.is_empty():
		return
	var started_usec: int = Time.get_ticks_usec()
	_armed.clear()
	var ids: PackedStringArray = npcs.awake_npc_ids()
	for slot: int in range(maxi(from_slot + 1, to_slot - BUCKET_COUNT + 1), to_slot + 1):
		var bucket: int = slot % BUCKET_COUNT
		for npc_id: String in ids:
			if bucket_of(npc_id) != bucket:
				continue
			if players.is_empty() and not _sight.has(npc_id):
				continue
			_look(world, npcs, npcs.get_npc(npc_id), players, now)
	last_step_usec = Time.get_ticks_usec() - started_usec


func to_world_document() -> Dictionary:
	if _sight.is_empty() and _signature.is_empty() and _roused_until.is_empty():
		return {}
	var sight: Dictionary = {}
	var npc_ids: Array = _sight.keys()
	npc_ids.sort()
	for npc_id: String in npc_ids:
		var rows: Dictionary = {}
		var player_ids: Array = (_sight[npc_id] as Dictionary).keys()
		player_ids.sort()
		for player_id: String in player_ids:
			var sighting: Sighting = _sight[npc_id][player_id]
			rows[player_id] = [sighting.visible, sighting.seen_usec, sighting.attention_until_usec, sighting.reaction, sighting.fear, sighting.distance_m]
		sight[npc_id] = rows
	var signatures: Dictionary = {}
	var signed_ids: Array = _signature.keys()
	signed_ids.sort()
	for npc_id: String in signed_ids:
		signatures[npc_id] = _signature[npc_id]
	var roused: Dictionary = {}
	var roused_ids: Array = _roused_until.keys()
	roused_ids.sort()
	for npc_id: String in roused_ids:
		roused[npc_id] = _roused_until[npc_id]
	return {KEY_SCHEMA_VERSION: SCHEMA_VERSION, KEY_SIGHT: sight, KEY_SIGNATURES: signatures, KEY_ROUSED: roused}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if document.is_empty():
		return errors
	if not ItemInstance.is_integer_value(document.get(KEY_SCHEMA_VERSION, null)) or int(document[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("npc social: unsupported schema_version")
		return errors
	var raw_sight: Variant = document.get(KEY_SIGHT, null)
	var raw_signatures: Variant = document.get(KEY_SIGNATURES, null)
	var raw_roused: Variant = document.get(KEY_ROUSED, null)
	if typeof(raw_sight) != TYPE_DICTIONARY or typeof(raw_signatures) != TYPE_DICTIONARY or typeof(raw_roused) != TYPE_DICTIONARY or (raw_sight as Dictionary).size() > MAX_SAVED_NPCS or (raw_signatures as Dictionary).size() > MAX_SAVED_NPCS or (raw_roused as Dictionary).size() > MAX_SAVED_NPCS:
		errors.append("npc social: sight, signatures and roused_until must be objects of at most %d NPCs" % MAX_SAVED_NPCS)
		return errors
	var player_pattern: RegEx = RegEx.create_from_string(RelationshipState.PLAYER_ID_PATTERN)
	var sight: Dictionary[String, Dictionary] = {}
	for npc_id: Variant in (raw_sight as Dictionary):
		var rows: Variant = (raw_sight as Dictionary)[npc_id]
		if typeof(npc_id) != TYPE_STRING or not NpcState.is_valid_npc_id(str(npc_id)) or typeof(rows) != TYPE_DICTIONARY:
			errors.append("npc social: invalid sight entry")
			continue
		var seen: Dictionary = {}
		for player_id: Variant in (rows as Dictionary):
			var row: Variant = (rows as Dictionary)[player_id]
			var sighting: Sighting = _sighting_from(row)
			if typeof(player_id) != TYPE_STRING or player_pattern.search(str(player_id)) == null or sighting == null:
				errors.append("npc social: invalid sighting of %s" % str(npc_id))
				continue
			seen[str(player_id)] = sighting
		if not seen.is_empty():
			sight[str(npc_id)] = seen
	var signatures: Dictionary[String, String] = {}
	for npc_id: Variant in (raw_signatures as Dictionary):
		var value: Variant = (raw_signatures as Dictionary)[npc_id]
		if typeof(npc_id) != TYPE_STRING or not NpcState.is_valid_npc_id(str(npc_id)) or typeof(value) != TYPE_STRING or (value as String).is_empty() or (value as String).length() > 128:
			errors.append("npc social: invalid signature entry")
			continue
		signatures[str(npc_id)] = str(value)
	var roused: Dictionary[String, int] = {}
	for npc_id: Variant in (raw_roused as Dictionary):
		var value: Variant = (raw_roused as Dictionary)[npc_id]
		if typeof(npc_id) != TYPE_STRING or not NpcState.is_valid_npc_id(str(npc_id)) or not _is_time(value):
			errors.append("npc social: invalid roused_until entry")
			continue
		roused[str(npc_id)] = int(value)
	if not errors.is_empty():
		return errors
	_sight = sight
	_signature = signatures
	_roused_until = roused
	return errors


static func _is_time(value: Variant) -> bool:
	return ItemInstance.is_integer_value(value) and int(value) >= 0 and int(value) <= MAX_SAFE_INT


static func _sighting_from(row: Variant) -> Sighting:
	if typeof(row) != TYPE_ARRAY or (row as Array).size() != 6:
		return null
	var values: Array = row
	if typeof(values[0]) != TYPE_BOOL or not _is_time(values[1]) or not _is_time(values[2]) or typeof(values[3]) != TYPE_STRING or not NpcReactionRules.REACTIONS.has(str(values[3])):
		return null
	for index: int in [4, 5]:
		if (typeof(values[index]) != TYPE_FLOAT and typeof(values[index]) != TYPE_INT) or not is_finite(float(values[index])) or float(values[index]) < 0.0:
			return null
	var sighting: Sighting = Sighting.new()
	sighting.visible = bool(values[0])
	sighting.seen_usec = int(values[1])
	sighting.attention_until_usec = int(values[2])
	sighting.reaction = str(values[3])
	sighting.fear = float(values[4])
	sighting.distance_m = float(values[5])
	return sighting


# ------------------------------------------------------------ what the decision layer asks

## What the NPC should do about the players now: {} (nothing), or
## {action: "flee" | "meet", code, target}. Reads the latest look; changes
## nothing.
func directive(world: ServerWorld, npc: NpcState, now: int) -> Dictionary:
	if world == null or npc == null:
		return {}
	var seen: Dictionary = _sight.get(npc.npc_id, {})
	var feared_id: String = _focus(seen, true)
	if not feared_id.is_empty():
		var feared: PlayerState = world.get_player(feared_id)
		if feared != null:
			return {
				KEY_ACTION: NpcBehaviours.ACTION_FLEE,
				KEY_CODE: HARD_PLAYER_FEARED,
				KEY_TARGET: {
					NpcActionExecutor.TARGET_THREAT_ID: feared_id,
					NpcActionExecutor.TARGET_THREAT_POSITION: [feared.position.x, feared.position.y, feared.position.z],
				},
			}
	var talker_id: String = _dialogue.talker_of(npc.npc_id)
	if not talker_id.is_empty():
		var talker: PlayerState = world.get_player(talker_id)
		if talker != null:
			return _meet(MODE_TALK, talker, settings.talk_idle_timeout_sec)
	var focus_id: String = _focus(seen, false)
	if focus_id.is_empty():
		return {}
	var sighting: Sighting = seen[focus_id]
	var player: PlayerState = world.get_player(focus_id)
	if player == null or sighting.attention_until_usec <= now:
		return {}
	var hold_sec: float = maxf(float(sighting.attention_until_usec - now) / 1000000.0, MIN_HOLD_SEC)
	match sighting.reaction:
		NpcReactionRules.HIDE:
			return _meet(MODE_BACK_OFF if sighting.distance_m < settings.back_off_within_m else MODE_WATCH, player, hold_sec)
		NpcReactionRules.GREET:
			return _meet(MODE_APPROACH if sighting.distance_m > settings.greet_distance_m + APPROACH_SLACK_M else MODE_WATCH, player, hold_sec)
		NpcReactionRules.WARY:
			return _meet(MODE_WATCH, player, hold_sec)
	return {}


## True when `target` (a running "meet") is what `directive` asks for: the
## same mode towards the same player.
static func is_same_meeting(target: Dictionary, wanted: Dictionary) -> bool:
	var wanted_target: Dictionary = wanted.get(KEY_TARGET, {})
	return str(target.get(TARGET_MODE, "")) == str(wanted_target.get(TARGET_MODE, "?")) and str(target.get(TARGET_PLAYER_ID, "")) == str(wanted_target.get(TARGET_PLAYER_ID, "?"))


# ------------------------------------------------------------ what others ask

## What NpcReactionRules looks at for this NPC and this player, read from
## the world now.
func view_of(world: ServerWorld, npcs: NpcService, npc: NpcState, player_id: String) -> NpcReactionRules.View:
	var view: NpcReactionRules.View = NpcReactionRules.View.new()
	if world == null or npcs == null or npc == null:
		return view
	view.traits = _traits_of(npcs, npc)
	var relationships: RelationshipStore = npc.component(RelationshipStore.COMPONENT_ID) as RelationshipStore
	# Read only (NpcReactionRules changes nothing): no copy.
	view.relationship = relationships.peek_relationship(player_id) if relationships != null else null
	var player: PlayerState = world.get_player(player_id)
	view.armed = player != null and _is_armed(world, player)
	var state: NpcSocialState = NpcSocialState.of(npc)
	var record: NpcSocialState.Record = state.record_of(player_id) if state != null else null
	view.harmed_count = record.harmed if record != null else 0
	var sighting: Sighting = (_sight.get(npc.npc_id, {}) as Dictionary).get(player_id, null)
	if sighting != null and not sighting.kills_stale:
		view.kills_seen = sighting.kills_seen
	else:
		view.kills_seen = _kills_seen(npc, player_id)
		if sighting != null:
			sighting.kills_seen = view.kills_seen
			sighting.kills_stale = false
	view.npc_hurt = NpcVitals.condition_of(npc) != NpcVitals.CONDITION_OK
	var emotions: NpcEmotions = npc.component(NpcEmotions.COMPONENT_ID) as NpcEmotions
	view.emotion_fear = emotions.value_at("fear", world.clock.world_time_sec) if emotions != null else 0.0
	return view


## The personality of an NPC's definition (read only; made once per
## definition: it never changes while the game runs).
func _traits_of(npcs: NpcService, npc: NpcState) -> Dictionary:
	if not _traits.has(npc.definition_id):
		var definition: NpcDefinition = npcs.definition_of(npc.npc_id)
		_traits[npc.definition_id] = definition.personality() if definition != null else {}
	return _traits[npc.definition_id]


## Adds `deltas` ({axis: amount}) to what the NPC thinks of the player
## (clamped to 0..1). A stranger gets its record here, with the trust its
## nature gives one. False when the NPC keeps no relationships.
func adjust_relationship(world: ServerWorld, npcs: NpcService, npc: NpcState, player_id: String, deltas: Dictionary) -> bool:
	var relationships: RelationshipStore = npc.component(RelationshipStore.COMPONENT_ID) as RelationshipStore if npc != null else null
	if relationships == null or world == null:
		return false
	var state: RelationshipState = relationships.relationship(player_id)
	if state == null:
		state = RelationshipState.new()
		state.source_entity_id = npc.npc_id
		state.target_entity_id = player_id
		state.trust = NpcReactionRules.trust(view_of(world, npcs, npc, player_id), settings)
	for axis: Variant in deltas:
		if RelationshipState.AXES.has(str(axis)):
			state.set(str(axis), clampf(float(state.get(str(axis))) + float(deltas[axis]), 0.0, 1.0))
	state.last_interaction_time = maxf(world.clock.world_time_sec, 0.0)
	return relationships.put_relationship(state).ok


## Adds to one of the NPC's emotions (nothing without the component).
func feel(world: ServerWorld, npc: NpcState, axis: String, amount: float) -> void:
	var emotions: NpcEmotions = npc.component(NpcEmotions.COMPONENT_ID) as NpcEmotions if npc != null else null
	if emotions != null and world != null and amount != 0.0:
		emotions.apply_emotion(axis, amount, world.clock.world_time_sec)


## True while the NPC sleeps (and was not just woken by a player).
func is_asleep(npc: NpcState, now: int) -> bool:
	return NpcDecisionComponent.label_of(npc) == LABEL_SLEEP and int(_roused_until.get(npc.npc_id, 0)) <= now


## True while the NPC runs from something or fights.
static func is_fleeing(npc: NpcState) -> bool:
	return NpcDecisionComponent.label_of(npc) == LABEL_FLEE


## A player woke the NPC: it looks around for `attention_sec` although it
## sleeps, and at this player at once.
func rouse(world: ServerWorld, npcs: NpcService, npc: NpcState) -> void:
	var now: int = now_usec()
	_roused_until[npc.npc_id] = now + NpcScheduleSettings.to_usec(maxf(settings.attention_sec, MIN_HOLD_SEC))
	look_now(world, npcs, npc)


## Looks for players at once (a conversation began or ended, the NPC was
## hurt) instead of at the NPC's next turn.
func look_now(world: ServerWorld, npcs: NpcService, npc: NpcState) -> void:
	if world == null or npcs == null or npc == null or not npcs.is_awake(npc.npc_id):
		return
	_armed.clear()
	_look(world, npcs, npc, _players(world), now_usec())


## The kind of an item for gifts and trades (NpcSurvivalSense.KIND_*).
func kind_of(definition: ItemDefinition) -> String:
	if definition == null:
		return NpcSurvivalSense.KIND_OTHER
	if definition.is_treatment():
		return NpcSurvivalSense.KIND_MEDICAL
	if definition.consume_hunger_reduction > 0.0:
		return NpcSurvivalSense.KIND_FOOD
	if definition.consume_thirst_reduction > 0.0:
		return NpcSurvivalSense.KIND_DRINK
	if _weapons != null and _weapons.for_item(definition.definition_id) != null:
		return NpcSurvivalSense.KIND_WEAPON
	return NpcSurvivalSense.KIND_OTHER


# ------------------------------------------------------------ being hurt

## NpcHealth.npc_damaged: a player's hit is remembered for good.
func on_npc_damaged(npc_id: String, source_id: String) -> void:
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	var npcs: NpcService = _npcs_ref.get_ref() as NpcService if _npcs_ref != null else null
	if world == null or npcs == null or RegEx.create_from_string(RelationshipState.PLAYER_ID_PATTERN).search(source_id) == null:
		return
	var npc: NpcState = npcs.get_npc(npc_id)
	var state: NpcSocialState = NpcSocialState.of(npc)
	if npc == null or state == null:
		return
	var now: float = world.clock.world_time_sec
	_dialogue.end_for_npc(world, npc_id, NpcDialogue.END_NPC_HURT)
	var vitals: NpcVitals = NpcVitals.of(npc)
	if vitals != null and not vitals.is_alive():
		return
	var record: NpcSocialState.Record = state.ensure_record(source_id, now, settings.max_known_players)
	record.harmed = mini(record.harmed + 1, NpcSocialState.MAX_SAFE_INT)
	record.harmed_last_at = now
	state.touch()
	adjust_relationship(world, npcs, npc, source_id, {"fear": settings.harmed_fear, "trust": -settings.harmed_trust_loss, "resentment": settings.harmed_resentment})
	feel(world, npc, "fear", settings.harmed_emotion_fear)
	feel(world, npc, "anger", settings.harmed_emotion_anger)
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	if memories != null:
		var participants: Array[Dictionary] = [{"entity_id": npc.npc_id, "role": "target"}, {"entity_id": source_id, "role": "actor"}]
		var recorded: ActionResult = memories.record_memory("", MEMORY_ATTACKED, participants, npc.position, now, NpcMemory.OBSERVATION_DIRECT, settings.harmed_memory_importance, settings.harmed_memory_intensity, PackedStringArray([TAG_ATTACKED, TAG_PLAYER]))
		if not recorded.ok:
			GameLogger.warning("npc", "a player's attack was not remembered", {"entity_id": npc_id, "reason": recorded.reason, "operation": "on_npc_damaged"})
	npc_harmed_by_player.emit(npc_id, source_id)
	look_now(world, npcs, npc)


## NpcHealth.npc_died: whoever sees the killer counts its kills again.
func on_npc_died(npc_id: String, _cause: String, killer_id: String) -> void:
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	if world != null:
		_dialogue.end_for_npc(world, npc_id, NpcDialogue.END_NPC_GONE)
	for seen: Dictionary in _sight.values():
		var sighting: Sighting = seen.get(killer_id, null)
		if sighting != null:
			sighting.kills_stale = true


# ------------------------------------------------------------ internals

func _meet(mode: String, player: PlayerState, hold_sec: float) -> Dictionary:
	return {
		KEY_ACTION: ACTION_MEET,
		KEY_CODE: HARD_PLAYER_MET,
		KEY_TARGET: {
			TARGET_MODE: mode,
			TARGET_PLAYER_ID: player.player_id,
			TARGET_PLAYER_POSITION: [player.position.x, player.position.y, player.position.z],
			TARGET_HOLD_SEC: hold_sec,
		},
	}


## The players an NPC could see: online, with a character, alive.
func _players(world: ServerWorld) -> Array[PlayerState]:
	var players: Array[PlayerState] = []
	for player_id: String in world.online_player_ids():
		var player: PlayerState = world.get_player(player_id)
		if player != null and player.has_character() and not world.is_player_dead(player_id):
			players.append(player)
	return players


func _is_armed(world: ServerWorld, player: PlayerState) -> bool:
	if _armed.has(player.player_id):
		return _armed[player.player_id]
	var armed: bool = false
	if _weapons != null and world.inventory.has_inventory(player.inventory_id):
		for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
			if _weapons.for_item(item.definition_id) != null:
				armed = true
				break
	_armed[player.player_id] = armed
	return armed


## NPCs this NPC remembers `player_id` killing.
func _kills_seen(npc: NpcState, player_id: String) -> int:
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	if memories == null or memories.count() == 0:
		return 0
	var kills: int = 0
	for memory_id: String in memories.memory_ids():
		var memory: NpcMemory = memories.memory(memory_id)
		if memory == null or memory.event_type != NpcHealth.MEMORY_EVENT_DIED or not memory.interpretation_tags.has(NpcHealth.TAG_KILLED_BY_PLAYER):
			continue
		for participant: Dictionary in memory.participants:
			if str(participant.get("entity_id", "")) == player_id and str(participant.get("role", "")) == "actor":
				kills += 1
				break
	return kills


## The player the NPC attends to among those it sees: the one that
## frightens it most (ties: the nearest, then the smaller id). With
## `afraid_only`: only one it runs from. "" = none.
func _focus(seen: Dictionary, afraid_only: bool) -> String:
	var best_id: String = ""
	var best: Sighting = null
	for player_id: String in seen:
		var sighting: Sighting = seen[player_id]
		if not sighting.visible or (afraid_only and sighting.reaction != NpcReactionRules.AFRAID):
			continue
		if best == null or sighting.fear > best.fear or (sighting.fear == best.fear and (sighting.distance_m < best.distance_m or (sighting.distance_m == best.distance_m and player_id < best_id))):
			best_id = player_id
			best = sighting
	return best_id


## One NPC looks for the players and what it shows and wants is brought up
## to date.
func _look(world: ServerWorld, npcs: NpcService, npc: NpcState, players: Array[PlayerState], now: int) -> void:
	var state: NpcSocialState = NpcSocialState.of(npc)
	if npc == null or state == null:
		return
	look_count += 1
	last_look_count += 1
	var npc_id: String = npc.npc_id
	var seen: Dictionary = _sight.get(npc_id, {})
	var asleep: bool = is_asleep(npc, now)
	var range_sq: float = _sight_range_m * _sight_range_m
	var renotice_usec: int = NpcScheduleSettings.to_usec(settings.renotice_after_sec)
	for sighting: Sighting in seen.values():
		sighting.visible = false
	if not asleep:
		for player: PlayerState in players:
			var distance_sq: float = Vector2(player.position.x - npc.position.x, player.position.z - npc.position.z).length_squared()
			if distance_sq > range_sq or world.is_line_blocked(npc.position, player.position):
				continue
			var player_id: String = player.player_id
			var sighting: Sighting = seen.get(player_id, null)
			var anew: bool = sighting == null or now - sighting.seen_usec >= renotice_usec
			if sighting == null:
				sighting = Sighting.new()
				seen[player_id] = sighting
			sighting.visible = true
			sighting.seen_usec = now
			sighting.distance_m = sqrt(distance_sq)
			var view: NpcReactionRules.View = view_of(world, npcs, npc, player_id)
			var assessed: Array = NpcReactionRules.assess(view, settings)
			var reaction: String = assessed[0]
			sighting.fear = assessed[1]
			if anew or reaction != sighting.reaction:
				sighting.attention_until_usec = now + NpcScheduleSettings.to_usec(settings.attention_sec)
			sighting.reaction = reaction
			if anew:
				player_noticed.emit(npc_id, player_id, reaction)
	# A player that left for good is forgotten here (its record stays).
	for player_id: String in seen.keys():
		var sighting: Sighting = seen[player_id]
		if not sighting.visible and now - sighting.seen_usec >= renotice_usec:
			seen.erase(player_id)
	if seen.is_empty():
		_sight.erase(npc_id)
	else:
		_sight[npc_id] = seen
	if int(_roused_until.get(npc_id, 0)) <= now:
		_roused_until.erase(npc_id)
	var talker_id: String = _dialogue.talker_of(npc_id)
	var focus_id: String = _focus(seen, false)
	var shown: String = NpcReactionRules.TALK if not talker_id.is_empty() else ((seen[focus_id] as Sighting).reaction if not focus_id.is_empty() else NpcReactionRules.NONE)
	state.reaction = shown
	state.reaction_player_id = talker_id if not talker_id.is_empty() else focus_id
	_face(world, npcs, npc, state.reaction_player_id, not talker_id.is_empty())
	var wanted: Dictionary = directive(world, npc, now)
	var wanted_target: Dictionary = wanted.get(KEY_TARGET, {})
	var signature: String = "" if wanted.is_empty() else "%s:%s:%s" % [str(wanted[KEY_ACTION]), str(wanted_target.get(TARGET_MODE, "")), str(wanted_target.get(TARGET_PLAYER_ID, wanted_target.get(NpcActionExecutor.TARGET_THREAT_ID, "")))]
	if signature != str(_signature.get(npc_id, "")):
		if signature.is_empty():
			_signature.erase(npc_id)
		else:
			_signature[npc_id] = signature
		_poke(npc_id)


## An NPC that stands for a player (it watches, greets or talks) turns to it.
func _face(world: ServerWorld, npcs: NpcService, npc: NpcState, player_id: String, talking: bool) -> void:
	if player_id.is_empty():
		return
	var behaviour: NpcBehaviourState = npc.component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState
	var standing: bool = (behaviour == null and talking) or (behaviour != null and behaviour.action_id == ACTION_MEET and behaviour.step == NpcBehaviourState.STEP_PERFORMING)
	var player: PlayerState = world.get_player(player_id)
	if not standing or player == null:
		return
	var offset: Vector3 = player.position - npc.position
	if Vector2(offset.x, offset.z).length_squared() < 0.0001:
		return
	var yaw: float = atan2(-offset.x, -offset.z)
	if absf(angle_difference(npc.yaw, yaw)) > FACE_EPSILON:
		npcs.set_npc_transform(world, npc.npc_id, npc.position, yaw)


## Asks the scheduler for a decision of this NPC now.
func _poke(npc_id: String) -> void:
	var scheduler: NpcScheduler = _scheduler()
	if scheduler != null and scheduler.request_interrupt(npc_id, REASON_PLAYER):
		poke_count += 1


## Called by NpcDialogue when a conversation of this NPC began or ended.
func on_conversation_changed(world: ServerWorld, npcs: NpcService, npc_id: String) -> void:
	var npc: NpcState = npcs.get_npc(npc_id) if npcs != null else null
	if npc == null:
		return
	if npcs.is_awake(npc_id):
		look_now(world, npcs, npc)
	else:
		var state: NpcSocialState = NpcSocialState.of(npc)
		if state != null:
			state.reaction = NpcReactionRules.NONE
			state.reaction_player_id = ""


func _forget(world: ServerWorld, npc: NpcState) -> void:
	if npc == null:
		return
	_dialogue.end_for_npc(world, npc.npc_id, NpcDialogue.END_NPC_GONE)
	_sight.erase(npc.npc_id)
	_signature.erase(npc.npc_id)
	_roused_until.erase(npc.npc_id)
	var state: NpcSocialState = NpcSocialState.of(npc)
	if state != null:
		state.reaction = NpcReactionRules.NONE
		state.reaction_player_id = ""
