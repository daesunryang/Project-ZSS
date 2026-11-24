class_name NpcActionDefinition
extends Resource
## One thing an NPC can choose to do (P4-4, docs/05 §9.2, docs/09 §17.6).
## Data only: one `.tres` per action in
## `res://resources/definitions/npc_actions/`, loaded by NpcActionCatalog.
## It says WHEN the action may be chosen (preconditions) and HOW MUCH an NPC
## wants it (the terms of the utility score, NpcUtilityScorer); how the
## action is carried out is the executor's business (P4-5a / P4-5b), which
## finds its own data by `action_id`.
##
## Every weight and term value is within 0..1. Every number of the shipped
## actions is PROVISIONAL (docs/15 §17.6).

## The labels other players may see (NpcNetProtocol.ACTION_LABELS; a test
## keeps the two lists the same).
const LABELS: PackedStringArray = ["idle", "walk", "eat", "sleep", "work", "flee"]
const LABEL_IDLE: String = "idle"
const LABEL_WALK: String = "walk"
## No window of the day.
const NO_HOUR: float = -1.0
const HOURS_PER_DAY: float = 24.0
## A duration that is not set here: the default of NpcDecisionSettings.
const USE_DEFAULT: float = -1.0
const ID_MAX_LENGTH: int = 32

## Stable snake_case id. Saved with an NPC that runs it: never rename it.
@export var action_id: String = ""
## What other players see while the NPC performs the action, and while it
## walks to where the action happens (one of LABELS each).
@export var observable_label: String = LABEL_IDLE
@export var navigate_label: String = LABEL_WALK

@export_group("Choosing")
## False: never a candidate of the utility choice (the flee action, which
## only a hard interrupt starts).
@export var selectable: bool = true
## Breaks a tie of the score: the larger number wins (then the action id).
@export var fixed_priority: int = 0
## The base term of the score.
@export_range(0.0, 1.0) var base_priority: float = 0.0

@export_group("Need term")
## The need this action answers (NpcNeedKind, "" = none): the term is that
## need's urgency (0 = satisfied .. 1 = worst).
@export var need_kind: String = ""
@export_range(0.0, 1.0) var need_weight: float = 0.0
## Precondition: the action is no candidate while the need's urgency is
## below this.
@export_range(0.0, 1.0) var min_need_urgency: float = 0.0

@export_group("Personality term")
## {personality trait (NpcDefinition.PERSONALITY_TRAITS): -1..1}. The term
## is the weighted mean of the traits (a negative weight counts 1 - trait).
@export var personality_traits: Dictionary = {}
@export_range(0.0, 1.0) var personality_weight: float = 0.0

@export_group("Environment term")
## The hours of the calendar day (0..24, the window may pass midnight) in
## which the action fits: the term is 1 inside the window and 0 outside.
## NO_HOUR = no window (the term is 0).
@export_range(-1.0, 24.0) var active_from_hour: float = NO_HOUR
@export_range(-1.0, 24.0) var active_until_hour: float = NO_HOUR
@export_range(0.0, 1.0) var environment_weight: float = 0.0

@export_group("Phase 5 terms (their values are 0 in Phase 4)")
@export_range(0.0, 1.0) var relationship_weight: float = 0.0
@export_range(0.0, 1.0) var memory_weight: float = 0.0

@export_group("Preconditions")
## The NPC's definition must have a job role and a work place.
@export var requires_job: bool = false
## No candidate while any simulated need of the NPC is in the DANGER
## category (docs/13 §16.3 D3: "업무 거부").
@export var blocked_by_danger_need: bool = false
## The night sleep (F-6): a candidate only from the NPC's own bedtime
## (NpcDefinition.bedtime_hour) for NpcDecisionSettings
## .night_sleep_window_hours, and only until the NPC has finished it once in
## that night (NpcDecisionComponent.last_sleep_night).
@export var requires_bedtime: bool = false
## A sleeper wakes on danger (F-6): no candidate while a simulated need
## other than `need_kind` is in the DANGER category AND a selectable action
## that answers that need is not on its retry cooldown (the NPC gets up to
## eat or drink). When nothing can be done about the need (no such action,
## or it just failed), the NPC may lie down all the same.
@export var yields_to_danger_need: bool = false

@export_group("Survival (F-29, docs/09 §17.14)")
## True: the need term of this action is the NPC's supply shortage
## (NpcSurvivalSense.supply_shortage, 0..1) instead of the urgency of a
## simulated need; `need_kind` stays empty and `min_need_urgency` is
## compared with the shortage.
@export var need_is_supply_shortage: bool = false
## Only an NPC that lives alone in a generated building (F-28) may choose it.
@export var requires_lone_home: bool = false
## Only an NPC that is wounded or infected AND carries an item that would
## treat it now may choose it.
@export var requires_treatment: bool = false
## False: no number of the NPC's generator is drawn for this action (its
## jitter term is 0). The actions added after Phase 4 are like this, so that
## adding one does not change what the NPCs of an older world draw.
@export var draws_jitter: bool = true

@export_group("Moving (F-30, docs/09 §17.15)")
## Only an NPC that is in the middle of a move to another shelter, or has
## a reason to begin one (NpcRelocation.wants_to_move), may choose it.
@export var requires_move_reason: bool = false
## No candidate while the NPC is in the middle of a move: what would send
## it back to the home it is leaving (a scavenging trip, a stroll).
@export var blocked_while_moving: bool = false

@export_group("Keeping")
## True: once started, the utility choice neither replaces nor stops the
## action for as long as it runs: its preconditions (min_need_urgency) and
## the other candidates are not looked at again. It ends when the executor
## reports it done or failed, when a hard interrupt takes over, or when a
## simulated need other than `need_kind` reaches the DANGER category (then
## the ordinary choice decides). False (the default): the action is
## weighed against the others at every decision after min_duration_sec.
@export var runs_until_done: bool = false

@export_group("Timing (action time, real seconds; -1 = the settings' default)")
## Once started, the utility choice does not replace the action before this
## time has passed (hard interrupts and the executor's reports still do).
@export_range(-1.0, 3600.0) var min_duration_sec: float = USE_DEFAULT
## After a failure the action is no candidate for this long (doubled for
## every failure in a row, NpcDecisionSettings.retry_cooldown_max_sec).
@export_range(-1.0, 3600.0) var retry_cooldown_sec: float = USE_DEFAULT


func has_window() -> bool:
	return active_from_hour >= 0.0 and active_until_hour >= 0.0


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not NpcComponent.is_valid_id(action_id) or action_id.length() > ID_MAX_LENGTH:
		errors.append("npc action id '%s' must be snake_case with at most %d characters" % [action_id, ID_MAX_LENGTH])
	for label: String in [observable_label, navigate_label]:
		if not LABELS.has(label):
			errors.append("npc action %s: unknown label '%s'" % [action_id, label])
	for entry: Array in [["base_priority", base_priority], ["need_weight", need_weight], ["min_need_urgency", min_need_urgency], ["personality_weight", personality_weight], ["environment_weight", environment_weight], ["relationship_weight", relationship_weight], ["memory_weight", memory_weight]]:
		if not _is_unit(float(entry[1])):
			errors.append("npc action %s: %s must be within 0..1" % [action_id, entry[0]])
	if not need_kind.is_empty() and not NpcNeedKind.is_simulated(need_kind):
		errors.append("npc action %s: need_kind '%s' is not a simulated need" % [action_id, need_kind])
	if need_kind.is_empty() and not need_is_supply_shortage and (need_weight > 0.0 or min_need_urgency > 0.0):
		errors.append("npc action %s: a need weight or minimum without need_kind" % action_id)
	if need_is_supply_shortage and not need_kind.is_empty():
		errors.append("npc action %s: need_is_supply_shortage and need_kind exclude each other" % action_id)
	for trait_name: Variant in personality_traits:
		var weight: Variant = personality_traits[trait_name]
		if typeof(trait_name) != TYPE_STRING or not NpcDefinition.PERSONALITY_TRAITS.has(str(trait_name)):
			errors.append("npc action %s: unknown personality trait '%s'" % [action_id, str(trait_name)])
		elif (typeof(weight) != TYPE_FLOAT and typeof(weight) != TYPE_INT) or not is_finite(float(weight)) or absf(float(weight)) > 1.0:
			errors.append("npc action %s: the weight of %s must be within -1..1" % [action_id, str(trait_name)])
	if (active_from_hour >= 0.0) != (active_until_hour >= 0.0):
		errors.append("npc action %s: active_from_hour and active_until_hour must both be set or both be -1" % action_id)
	for hour: float in [active_from_hour, active_until_hour]:
		if not is_finite(hour) or hour > HOURS_PER_DAY or (hour < 0.0 and hour != NO_HOUR):
			errors.append("npc action %s: an hour must be within 0..24 or -1" % action_id)
	for entry: Array in [["min_duration_sec", min_duration_sec], ["retry_cooldown_sec", retry_cooldown_sec]]:
		var seconds: float = float(entry[1])
		if not is_finite(seconds) or (seconds < 0.0 and seconds != USE_DEFAULT):
			errors.append("npc action %s: %s must be >= 0 or -1" % [action_id, entry[0]])
	return errors


static func _is_unit(value: float) -> bool:
	return is_finite(value) and value >= 0.0 and value <= 1.0
