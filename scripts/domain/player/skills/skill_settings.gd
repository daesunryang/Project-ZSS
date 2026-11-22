class_name SkillSettings
extends Resource
## Player skill levels (F-9, notes/feature-plan-2026-11-20.md FD-3, FD-8):
## which skills exist, how much experience each level takes, how much a
## level lowers material costs and how much experience an action gives.
## Defaults in `res://data/tuning/skill_settings.tres`. Every number is
## PROVISIONAL (docs/15 §19, F9-001..F9-006) except the reduction rule the
## user set: "10레벨, 최대 50% 감소", "소수점은 올림".
##
## Every skill uses the same level curve. A new skill is one more id in
## `skill_ids` (and the action that gives it experience); saves and the
## network carry skills by id.

const DEFAULT_PATH: String = "res://data/tuning/skill_settings.tres"
const SKILL_ID_PATTERN: String = "^[a-z][a-z0-9_]*$"
const MIN_LEVEL: int = 1

## The skills a player has, by stable id (save and network key).
@export var skill_ids: PackedStringArray = PackedStringArray(["building", "repair"])
## Highest level of every skill (FD-8: 10).
@export_range(2, 100) var max_level: int = 10
## Total experience needed to REACH level 2, 3, ... max_level (so
## max_level - 1 values, strictly increasing). Experience never goes above
## the last value. PROVISIONAL (docs/15 F9-001).
@export var level_xp: PackedInt32Array = PackedInt32Array([100, 250, 450, 700, 1000, 1400, 1900, 2500, 3200])
## Material reduction at max_level in whole percent (FD-8: 50). Level 1 has
## none; every level between adds the same share (50 / 9 = about 5.6% per
## level with 10 levels). Each reduced quantity is rounded UP and never
## drops below 1 (SkillRules.reduced_quantity).
@export_range(0, 99) var max_cost_reduction_percent: int = 50
## Experience of the building skill for each worker who finishes the work
## on a structure. PROVISIONAL (docs/15 F9-003).
@export_range(0, 100000) var building_xp_per_structure: int = 10
## Experience of the repair skill for one finished repair (F-10 calls
## SkillService.record_repair_done). PROVISIONAL (docs/15 F9-004).
@export_range(0, 100000) var repair_xp_per_repair: int = 10


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if skill_ids.is_empty():
		errors.append("skill settings need at least one skill id")
	var seen: Dictionary[String, bool] = {}
	var pattern: RegEx = RegEx.create_from_string(SKILL_ID_PATTERN)
	for skill_id: String in skill_ids:
		if pattern.search(skill_id) == null:
			errors.append("skill id '%s' must be snake_case" % skill_id)
		if seen.has(skill_id):
			errors.append("skill id '%s' is listed twice" % skill_id)
		seen[skill_id] = true
	if max_level < 2:
		errors.append("skill max_level must be >= 2")
	elif level_xp.size() != max_level - 1:
		errors.append("skill level_xp needs max_level - 1 = %d values (has %d)" % [max_level - 1, level_xp.size()])
	var previous: int = 0
	for value: int in level_xp:
		if value <= previous:
			errors.append("skill level_xp must be > 0 and strictly increasing")
			break
		previous = value
	if max_cost_reduction_percent < 0 or max_cost_reduction_percent > 99:
		errors.append("skill max_cost_reduction_percent must be 0..99")
	if building_xp_per_structure < 0 or repair_xp_per_repair < 0:
		errors.append("skill experience per action must be >= 0")
	return errors


func has_skill(skill_id: String) -> bool:
	return skill_ids.has(skill_id)


## Experience at which a skill is at max_level (the experience cap).
func max_xp() -> int:
	return level_xp[level_xp.size() - 1] if not level_xp.is_empty() else 0


static func load_or_default(path: String = DEFAULT_PATH) -> SkillSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is SkillSettings:
		return loaded as SkillSettings
	GameLogger.warning("config", "skill settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return SkillSettings.new()
