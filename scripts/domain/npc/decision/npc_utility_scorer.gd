class_name NpcUtilityScorer
extends RefCounted
## The utility score of a candidate action (P4-4, docs/05 §9.2, docs/09
## §17.6 "합산식"). Pure functions, no world.
##
##   score = base
##         + need_weight          * need
##         + personality_weight   * personality
##         + environment_weight   * environment
##         + relationship_weight  * relationship     (0 in Phase 4)
##         + memory_weight        * memory           (0 in Phase 4)
##         + current_action_bonus * commitment       (1 for the running action)
##         + score_jitter         * jitter           (NPC generator, 0..1)
##
## Every term value and every weight is clamped to 0..1 before it is used,
## so 0 <= score <= 6 + current_action_bonus + score_jitter whatever the
## data says. The cost terms of docs/05 §9.2 (risk, travel, resource) and
## goal_alignment are not part of Phase 4 (docs/15 P4-153).
##
## Order of two candidates: the larger score, then the larger
## fixed_priority, then the smaller action id.

const TERM_BASE: String = "base"
const TERM_NEED: String = "need"
const TERM_PERSONALITY: String = "personality"
const TERM_ENVIRONMENT: String = "environment"
const TERM_RELATIONSHIP: String = "relationship"
const TERM_MEMORY: String = "memory"
const TERM_COMMITMENT: String = "commitment"
const TERM_JITTER: String = "jitter"
## The terms, in the order they are summed.
const TERMS: PackedStringArray = [TERM_BASE, TERM_NEED, TERM_PERSONALITY, TERM_ENVIRONMENT, TERM_RELATIONSHIP, TERM_MEMORY, TERM_COMMITMENT, TERM_JITTER]

## Keys of a scored candidate.
const KEY_ACTION_ID: String = "action_id"
const KEY_SCORE: String = "score"
const KEY_FIXED_PRIORITY: String = "fixed_priority"
## {term: its value, 0..1}
const KEY_VALUES: String = "values"
## {term: weight * value, what is summed}
const KEY_TERMS: String = "terms"
## An hour counts as inside a window from this far before its start (and
## outside from this far before its end): a decision at the very moment a
## window opens must not depend on the last digit of the calendar time,
## which a save rounds.
const HOUR_EPSILON: float = 0.000001


static func unit(value: float) -> float:
	return clampf(value, 0.0, 1.0) if is_finite(value) else 0.0


## 0 (satisfied) .. 1 (worst) of a need value.
static func need_urgency(value: float, need_max: float) -> float:
	return unit(value / need_max) if need_max > 0.0 else 0.0


## The weighted mean of personality traits: weights {trait: -1..1} against
## values {trait: 0..1}. A negative weight counts (1 - trait). 0 without
## weights.
static func personality_fit(traits: Dictionary, weights: Dictionary) -> float:
	var total: float = 0.0
	var weight_sum: float = 0.0
	for trait_name: Variant in weights:
		var weight: float = float(weights[trait_name])
		if not is_finite(weight) or weight == 0.0:
			continue
		weight = clampf(weight, -1.0, 1.0)
		var value: float = unit(float(traits.get(trait_name, 0.5)))
		total += absf(weight) * (value if weight > 0.0 else 1.0 - value)
		weight_sum += absf(weight)
	return unit(total / weight_sum) if weight_sum > 0.0 else 0.0


## Hour of the calendar day (0 <= hour < 24) of a calendar time.
static func hour_of_day(world_time_sec: float, day_length_world_sec: float) -> float:
	if day_length_world_sec <= 0.0 or not is_finite(world_time_sec):
		return 0.0
	return fposmod(world_time_sec, day_length_world_sec) / day_length_world_sec * NpcActionDefinition.HOURS_PER_DAY


## True when `hour` is inside [from, until); the window may pass midnight
## (22 -> 6). from == until: the whole day.
static func in_window(hour: float, from_hour: float, until_hour: float) -> bool:
	if from_hour == until_hour:
		return true
	if from_hour < until_hour:
		return hour >= from_hour and hour < until_hour
	return hour >= from_hour or hour < until_hour


## 1 inside the action's window of the day, 0 outside or without a window.
static func environment_fit(action: NpcActionDefinition, hour: float) -> float:
	if not action.has_window():
		return 0.0
	return 1.0 if in_window(hour + HOUR_EPSILON, action.active_from_hour, action.active_until_hour) else 0.0


## Scores `action`. `need`, `personality`, `environment`, `relationship`,
## `memory` and `jitter` are the term values (clamped here); `is_current`:
## the NPC already runs this action.
static func score(action: NpcActionDefinition, settings: NpcDecisionSettings, need: float, personality: float, environment: float, relationship: float, memory: float, is_current: bool, jitter: float) -> Dictionary:
	var values: Dictionary = {
		TERM_BASE: unit(action.base_priority),
		TERM_NEED: unit(need),
		TERM_PERSONALITY: unit(personality),
		TERM_ENVIRONMENT: unit(environment),
		TERM_RELATIONSHIP: unit(relationship),
		TERM_MEMORY: unit(memory),
		TERM_COMMITMENT: 1.0 if is_current else 0.0,
		TERM_JITTER: unit(jitter),
	}
	var terms: Dictionary = {
		TERM_BASE: float(values[TERM_BASE]),
		TERM_NEED: unit(action.need_weight) * float(values[TERM_NEED]),
		TERM_PERSONALITY: unit(action.personality_weight) * float(values[TERM_PERSONALITY]),
		TERM_ENVIRONMENT: unit(action.environment_weight) * float(values[TERM_ENVIRONMENT]),
		TERM_RELATIONSHIP: unit(action.relationship_weight) * float(values[TERM_RELATIONSHIP]),
		TERM_MEMORY: unit(action.memory_weight) * float(values[TERM_MEMORY]),
		TERM_COMMITMENT: unit(settings.current_action_bonus) * float(values[TERM_COMMITMENT]),
		TERM_JITTER: unit(settings.score_jitter) * float(values[TERM_JITTER]),
	}
	var total: float = 0.0
	for term: String in TERMS:
		total += float(terms[term])
	return {KEY_ACTION_ID: action.action_id, KEY_SCORE: total, KEY_FIXED_PRIORITY: action.fixed_priority, KEY_VALUES: values, KEY_TERMS: terms}


## True when candidate `a` comes before `b` (see the header).
static func is_better(a: Dictionary, b: Dictionary) -> bool:
	if float(a[KEY_SCORE]) != float(b[KEY_SCORE]):
		return float(a[KEY_SCORE]) > float(b[KEY_SCORE])
	if int(a[KEY_FIXED_PRIORITY]) != int(b[KEY_FIXED_PRIORITY]):
		return int(a[KEY_FIXED_PRIORITY]) > int(b[KEY_FIXED_PRIORITY])
	return str(a[KEY_ACTION_ID]) < str(b[KEY_ACTION_ID])
