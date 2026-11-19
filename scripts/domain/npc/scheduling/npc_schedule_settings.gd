class_name NpcScheduleSettings
extends Resource
## When NPCs think (NpcScheduler, P4-3, docs/09 §17.3). Defaults in
## `res://data/tuning/npc_schedule_settings.tres`. Every value is
## PROVISIONAL (docs/15 §17.3, docs/13 §16.4) until Phase 4 is tuned as a
## whole. All periods are action time (real seconds, docs/13 §16.3 D10): the
## calendar time scale does not change them.

const DEFAULT_PATH: String = "res://data/tuning/npc_schedule_settings.tres"
const USEC_PER_SEC: int = 1000000

@export_group("Decisions")
## How often an NPC of the "near" tier re-evaluates what it does.
@export_range(0.05, 600.0, 0.05, "suffix:s") var decision_near_period_sec: float = 2.0
## The same for the "far" tier. Not shorter than the near period.
@export_range(0.05, 3600.0, 0.05, "suffix:s") var decision_far_period_sec: float = 10.0
## Buckets a period is cut into: an NPC's bucket (from its id) decides at
## which moment of every period its turn comes, so the NPCs of one tier do
## not all think in the same tick.
@export_range(1, 1000) var decision_bucket_count: int = 10
## Most decisions (periodic and interrupts together) one server tick runs.
## What does not fit waits for the next tick, oldest first.
@export_range(1, 1000) var max_decisions_per_tick: int = 2

@export_group("Tiers")
## An NPC is "near" when the nearest online player is at most this far.
@export_range(0.0, 10000.0, 0.5, "suffix:m") var near_radius_m: float = 30.0
## A near NPC only becomes "far" beyond near_radius_m + this margin, so an
## NPC at the edge does not flip every time it is looked at.
@export_range(0.0, 1000.0, 0.5, "suffix:m") var near_exit_margin_m: float = 5.0
## How often the tier of an awake NPC is looked at again (bucketed like the
## decisions).
@export_range(0.05, 600.0, 0.05, "suffix:s") var tier_period_sec: float = 0.5


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	for entry: Array in [["decision_near_period_sec", decision_near_period_sec], ["decision_far_period_sec", decision_far_period_sec], ["tier_period_sec", tier_period_sec]]:
		if not is_finite(float(entry[1])) or float(entry[1]) <= 0.0:
			errors.append("npc schedule %s must be > 0" % str(entry[0]))
	if decision_bucket_count < 1:
		errors.append("npc schedule decision_bucket_count must be >= 1")
	if max_decisions_per_tick < 1:
		errors.append("npc schedule max_decisions_per_tick must be >= 1")
	if not is_finite(near_radius_m) or near_radius_m < 0.0:
		errors.append("npc schedule near_radius_m must be >= 0")
	if not is_finite(near_exit_margin_m) or near_exit_margin_m < 0.0:
		errors.append("npc schedule near_exit_margin_m must be >= 0")
	if not errors.is_empty():
		return errors
	if decision_far_period_sec < decision_near_period_sec:
		errors.append("npc schedule decision_far_period_sec must be >= decision_near_period_sec")
	# A bucket's slot must be at least one microsecond of the schedule clock.
	if mini(to_usec(decision_near_period_sec), to_usec(tier_period_sec)) < decision_bucket_count:
		errors.append("npc schedule periods are too short for decision_bucket_count")
	return errors


## Seconds as whole microseconds of the schedule clock.
static func to_usec(seconds: float) -> int:
	return roundi(seconds * float(USEC_PER_SEC))


static func load_or_default(path: String = DEFAULT_PATH) -> NpcScheduleSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcScheduleSettings:
		return loaded as NpcScheduleSettings
	GameLogger.warning("config", "npc schedule settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcScheduleSettings.new()
