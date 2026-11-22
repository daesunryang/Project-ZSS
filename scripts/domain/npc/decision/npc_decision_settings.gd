class_name NpcDecisionSettings
extends Resource
## How NPCs choose what to do (NpcUtilityDecider, P4-4, docs/09 §17.6).
## Defaults in `res://data/tuning/npc_decision_settings.tres`. Every value is
## PROVISIONAL (docs/15 §17.6) until Phase 4 is tuned as a whole. Durations
## are action time (real seconds, docs/13 §16.3 D10) unless they say
## otherwise.

const DEFAULT_PATH: String = "res://data/tuning/npc_decision_settings.tres"

@export_group("Utility choice")
## A candidate whose score is below this is not chosen.
@export_range(0.0, 10.0, 0.01) var min_action_score: float = 0.05
## Added to the score of the action the NPC already runs (hysteresis: a
## candidate must be better by more than this to replace it).
@export_range(0.0, 1.0, 0.01) var current_action_bonus: float = 0.15
## Largest random amount added to a candidate's score, from the NPC's own
## generator (0 = none, no number is drawn).
@export_range(0.0, 1.0, 0.001) var score_jitter: float = 0.02
## The action when no candidate is left ("" = stand idle).
@export var fallback_action_id: String = "wander"

@export_group("Anti-oscillation and failures")
## Default of NpcActionDefinition.min_duration_sec.
@export_range(0.0, 3600.0, 0.1, "suffix:s") var default_min_duration_sec: float = 5.0
## After a failure the NPC chooses nothing for this long (state Recover).
@export_range(0.0, 600.0, 0.1, "suffix:s") var recover_cooldown_sec: float = 1.0
## Default of NpcActionDefinition.retry_cooldown_sec, and the most the
## doubling for failures in a row makes of it.
@export_range(0.0, 3600.0, 0.1, "suffix:s") var retry_cooldown_sec: float = 10.0
@export_range(0.0, 86400.0, 0.1, "suffix:s") var retry_cooldown_max_sec: float = 120.0

@export_group("Hard interrupt: a visible zombie")
## The action a visible threat starts ("" = NPCs never flee).
@export var flee_action_id: String = "flee"
## An NPC sees a living zombie within this distance when no structure
## blocks the line (ServerWorld.is_line_blocked), in every direction.
@export_range(0.0, 1000.0, 0.5, "suffix:m") var threat_sight_range_m: float = 15.0
## How often an awake NPC looks for threats between its decisions
## (bucketed like the decisions).
@export_range(0.05, 600.0, 0.05, "suffix:s") var threat_check_period_sec: float = 0.5

@export_group("Environment")
## Calendar seconds of one day (the hours of an action's window).
@export_range(1.0, 10000000.0) var day_length_world_sec: float = 86400.0

@export_group("Night sleep (F-6)")
## For how many calendar hours after an NPC's bedtime
## (NpcDefinition.bedtime_hour) its night sleep may still begin (an action
## with `requires_bedtime`). An NPC that was kept up longer than this has
## missed the night and only naps.
@export_range(0.25, 24.0, 0.25, "suffix:h") var night_sleep_window_hours: float = 8.0

@export_group("Decision records (debug overlay, tests)")
## Decision records kept per NPC (a ring: the oldest goes first). Not saved.
@export_range(1, 1024) var record_capacity: int = 16
## Candidates written into one record, best first.
@export_range(1, 64) var record_top_candidates: int = 5


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	for entry: Array in [["min_action_score", min_action_score], ["default_min_duration_sec", default_min_duration_sec], ["recover_cooldown_sec", recover_cooldown_sec], ["retry_cooldown_sec", retry_cooldown_sec], ["retry_cooldown_max_sec", retry_cooldown_max_sec], ["threat_sight_range_m", threat_sight_range_m]]:
		if not is_finite(float(entry[1])) or float(entry[1]) < 0.0:
			errors.append("npc decision %s must be >= 0" % str(entry[0]))
	for entry: Array in [["current_action_bonus", current_action_bonus], ["score_jitter", score_jitter]]:
		if not is_finite(float(entry[1])) or float(entry[1]) < 0.0 or float(entry[1]) > 1.0:
			errors.append("npc decision %s must be within 0..1" % str(entry[0]))
	for entry: Array in [["threat_check_period_sec", threat_check_period_sec], ["day_length_world_sec", day_length_world_sec], ["night_sleep_window_hours", night_sleep_window_hours]]:
		if not is_finite(float(entry[1])) or float(entry[1]) <= 0.0:
			errors.append("npc decision %s must be > 0" % str(entry[0]))
	if is_finite(night_sleep_window_hours) and night_sleep_window_hours > NpcActionDefinition.HOURS_PER_DAY:
		errors.append("npc decision night_sleep_window_hours must be at most 24")
	if errors.is_empty() and retry_cooldown_max_sec < retry_cooldown_sec:
		errors.append("npc decision retry_cooldown_max_sec must be >= retry_cooldown_sec")
	for entry: Array in [["fallback_action_id", fallback_action_id], ["flee_action_id", flee_action_id]]:
		if not str(entry[1]).is_empty() and not NpcComponent.is_valid_id(str(entry[1])):
			errors.append("npc decision %s must be snake_case or empty" % str(entry[0]))
	if record_capacity < 1 or record_top_candidates < 1:
		errors.append("npc decision record sizes must be >= 1")
	return errors


## Errors of the settings against the actions: the two named actions exist
## (or are not named).
func validate_against(actions: NpcActionCatalog) -> PackedStringArray:
	var errors: PackedStringArray = []
	if actions == null:
		errors.append("npc decision: no action catalog")
		return errors
	for entry: Array in [["fallback_action_id", fallback_action_id], ["flee_action_id", flee_action_id]]:
		if not str(entry[1]).is_empty() and not actions.has(str(entry[1])):
			errors.append("npc decision %s '%s' is not an action" % [entry[0], entry[1]])
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NpcDecisionSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcDecisionSettings:
		return loaded as NpcDecisionSettings
	GameLogger.warning("config", "npc decision settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcDecisionSettings.new()
