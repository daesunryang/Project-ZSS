class_name SkillRules
extends RefCounted
## Pure skill rules (F-9): experience -> level, level progress, and the
## material reduction of a level (FD-8). No state, no nodes; the server
## (SkillService) and the client HUD use the same functions.

## A skill at max_level has no next level.
const NO_NEXT_LEVEL: int = -1
const PERCENT: int = 100


## Level 1..max_level for an amount of experience (negative counts as 0).
static func level_for_xp(xp: int, settings: SkillSettings) -> int:
	var level: int = SkillSettings.MIN_LEVEL
	for threshold: int in settings.level_xp:
		if xp < threshold:
			break
		level += 1
	return mini(level, settings.max_level)


## Experience a skill needs to reach `level` (0 for level 1).
static func xp_to_reach(level: int, settings: SkillSettings) -> int:
	var clamped: int = clampi(level, SkillSettings.MIN_LEVEL, settings.max_level)
	return 0 if clamped == SkillSettings.MIN_LEVEL else settings.level_xp[clamped - 2]


## Where `xp` stands: {level, xp, level_start_xp, next_level_xp}.
## next_level_xp is NO_NEXT_LEVEL at max_level.
static func progress_of(xp: int, settings: SkillSettings) -> Dictionary:
	var capped: int = clampi(xp, 0, settings.max_xp())
	var level: int = level_for_xp(capped, settings)
	return {
		"level": level,
		"xp": capped,
		"level_start_xp": xp_to_reach(level, settings),
		"next_level_xp": NO_NEXT_LEVEL if level >= settings.max_level else xp_to_reach(level + 1, settings),
	}


## Share of the material a level saves, 0..1 (for display; the costs
## themselves are computed exactly by reduced_quantity).
static func reduction_fraction(level: int, settings: SkillSettings) -> float:
	var steps: int = settings.max_level - SkillSettings.MIN_LEVEL
	var above: int = clampi(level, SkillSettings.MIN_LEVEL, settings.max_level) - SkillSettings.MIN_LEVEL
	return float(above * settings.max_cost_reduction_percent) / float(steps * PERCENT)


## Units of one material a player of `level` pays instead of `base` (FD-8):
## base * (1 - reduction), rounded UP, never below 1. Integer arithmetic,
## so the result does not depend on float rounding. base <= 0 stays as is.
static func reduced_quantity(base: int, level: int, settings: SkillSettings) -> int:
	if base <= 0:
		return base
	var steps: int = settings.max_level - SkillSettings.MIN_LEVEL
	var above: int = clampi(level, SkillSettings.MIN_LEVEL, settings.max_level) - SkillSettings.MIN_LEVEL
	var denominator: int = steps * PERCENT
	var kept: int = denominator - above * settings.max_cost_reduction_percent
	return maxi((base * kept + denominator - 1) / denominator, 1)


## Every material of `costs` reduced for `level` (a new dictionary).
static func reduced_costs(costs: Dictionary[String, int], level: int, settings: SkillSettings) -> Dictionary[String, int]:
	var reduced: Dictionary[String, int] = {}
	for item_id: String in costs:
		reduced[item_id] = reduced_quantity(costs[item_id], level, settings)
	return reduced
