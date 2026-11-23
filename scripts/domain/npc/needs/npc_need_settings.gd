class_name NpcNeedSettings
extends Resource
## Tuning and definition data of NPC needs (P4-2, docs/09 §17.2).
## Time values are calendar/world time (ADR-006). All values are
## PROVISIONAL until Phase 4's final tuning pass (docs/15 §17.2).

const DEFAULT_PATH: String = "res://data/tuning/npc_need_settings.tres"
const SECONDS_PER_HOUR: float = 3600.0
const MAX_RATE_MODIFIER: float = 100.0

## Every need known to Phase 4. Only NpcNeedKind.SIMULATED_KINDS has a
## non-zero rate; the rest exists for later definitions and decisions.
@export var defined_kinds: PackedStringArray = NpcNeedKind.DEFINED_KINDS.duplicate()
## 0 = satisfied, need_max = worst.
@export_range(1.0, 10000.0) var need_max: float = 100.0
@export_range(0.0, 10000.0) var caution_threshold: float = 40.0
@export_range(0.0, 10000.0) var danger_threshold: float = 75.0

@export_group("Idle growth (calendar hours from 0 to max)")
@export_range(0.01, 100000.0) var hunger_hours_to_max: float = 48.0
@export_range(0.01, 100000.0) var thirst_hours_to_max: float = 24.0
@export_range(0.01, 100000.0) var fatigue_hours_to_max: float = 18.0

@export_group("Activities")
## Calendar hours of rest that lower fatigue from max to 0.
@export_range(0.01, 100000.0) var rest_fatigue_hours_from_max: float = 3.2
## Calendar hours of night sleep (the action "sleep", F-6) that lower
## fatigue from max to 0. Slower than a nap so the night sleep lasts longer
## (user choice 2026-11-23, "3"). PROVISIONAL.
@export_range(0.01, 100000.0) var sleep_fatigue_hours_from_max: float = 3.2
## Hunger and thirst retain their idle rates while resting. Work only
## accelerates fatigue for now; the final values are deliberately deferred.
@export_range(1.0, 100.0) var working_fatigue_rate_multiplier: float = 1.5

@export_group("Future modifier seams")
## P4-2 keeps the personality/ability seams but applies no authored effect.
@export_range(0.01, 100.0) var default_personality_modifier: float = 1.0
@export_range(0.01, 100.0) var default_ability_modifier: float = 1.0


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(need_max) or need_max <= 0.0:
		errors.append("npc needs need_max must be finite and > 0")
	if not is_finite(caution_threshold) or not is_finite(danger_threshold) or caution_threshold < 0.0 or caution_threshold >= danger_threshold or danger_threshold > need_max:
		errors.append("npc need thresholds must satisfy 0 <= caution < danger <= need_max")
	for hours: float in [hunger_hours_to_max, thirst_hours_to_max, fatigue_hours_to_max, rest_fatigue_hours_from_max, sleep_fatigue_hours_from_max]:
		if not is_finite(hours) or hours <= 0.0:
			errors.append("npc need hour durations must be finite and > 0")
			break
	if not is_finite(working_fatigue_rate_multiplier) or working_fatigue_rate_multiplier < 1.0 or working_fatigue_rate_multiplier > MAX_RATE_MODIFIER:
		errors.append("npc working fatigue multiplier must be finite and within [1, 100]")
	for modifier: float in [default_personality_modifier, default_ability_modifier]:
		if not is_finite(modifier) or modifier <= 0.0 or modifier > MAX_RATE_MODIFIER:
			errors.append("npc need default modifiers must be finite and within (0, 100]")
			break
	if defined_kinds != NpcNeedKind.DEFINED_KINDS:
		errors.append("npc need defined_kinds must contain the Phase 4 definitions once, in stable order")
	return errors


## Need units per calendar second for an activity. Unknown and deferred
## kinds have zero rate. Personality and ability modifiers are applied by
## NpcNeeds, where their per-NPC values are stored.
func rate_per_world_sec(kind: String, activity: String) -> float:
	if not NpcNeedKind.is_simulated(kind) or not NpcNeedKind.is_valid_activity(activity):
		return 0.0
	if kind == NpcNeedKind.HUNGER:
		return need_max / (hunger_hours_to_max * SECONDS_PER_HOUR)
	if kind == NpcNeedKind.THIRST:
		return need_max / (thirst_hours_to_max * SECONDS_PER_HOUR)
	if activity == NpcNeedKind.RESTING:
		return -need_max / (rest_fatigue_hours_from_max * SECONDS_PER_HOUR)
	if activity == NpcNeedKind.SLEEPING:
		return -need_max / (sleep_fatigue_hours_from_max * SECONDS_PER_HOUR)
	var fatigue_rate: float = need_max / (fatigue_hours_to_max * SECONDS_PER_HOUR)
	return fatigue_rate * working_fatigue_rate_multiplier if activity == NpcNeedKind.WORKING else fatigue_rate


static func load_or_default(path: String = DEFAULT_PATH) -> NpcNeedSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcNeedSettings:
		return loaded as NpcNeedSettings
	GameLogger.warning("config", "npc need settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcNeedSettings.new()
