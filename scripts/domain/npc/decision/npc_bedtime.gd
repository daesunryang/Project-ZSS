class_name NpcBedtime
extends RefCounted
## When an NPC's night begins (F-6, docs/09 §17.11). Pure functions, no
## world. Every NPC has its own bedtime (NpcDefinition.bedtime_hour, an hour
## of the calendar day): an early one is a morning type, a late one an
## evening type. The night sleep may begin from the bedtime for
## NpcDecisionSettings.night_sleep_window_hours, once per night.
##
## A "night" is the calendar day counted from bedtime to bedtime: night N
## lasts from (N - 1) days + bedtime to N days + bedtime, so night 0 is the
## time before the first bedtime of the world and the night number of a
## calendar time >= 0 is >= 0.
##
## Both functions look at the time NpcUtilityScorer.HOUR_EPSILON hours
## ahead, like the window of an action: a decision at the very moment the
## bedtime comes must not depend on the last digit of the calendar time,
## which a save rounds.

## No night yet (NpcDecisionComponent.last_sleep_night).
const NO_NIGHT: int = -1


## The number of the night `world_time_sec` belongs to for an NPC whose
## bedtime is `bedtime_hour` (>= 0).
static func night_of(world_time_sec: float, day_length_world_sec: float, bedtime_hour: float) -> int:
	if day_length_world_sec <= 0.0 or not is_finite(world_time_sec) or not is_finite(bedtime_hour):
		return 0
	var hours: float = world_time_sec / day_length_world_sec * NpcActionDefinition.HOURS_PER_DAY + NpcUtilityScorer.HOUR_EPSILON
	return maxi(floori((hours - bedtime_hour) / NpcActionDefinition.HOURS_PER_DAY) + 1, 0)


## True from the bedtime for `window_hours` (the window may pass midnight;
## 24 hours or more: always).
static func is_bedtime(world_time_sec: float, day_length_world_sec: float, bedtime_hour: float, window_hours: float) -> bool:
	if not is_finite(bedtime_hour) or not is_finite(window_hours) or window_hours <= 0.0:
		return false
	if window_hours >= NpcActionDefinition.HOURS_PER_DAY:
		return true
	var hour: float = NpcUtilityScorer.hour_of_day(world_time_sec, day_length_world_sec) + NpcUtilityScorer.HOUR_EPSILON
	return NpcUtilityScorer.in_window(hour, bedtime_hour, fposmod(bedtime_hour + window_hours, NpcActionDefinition.HOURS_PER_DAY))
