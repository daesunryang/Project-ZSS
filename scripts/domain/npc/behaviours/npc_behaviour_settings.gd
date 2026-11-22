class_name NpcBehaviourSettings
extends Resource
## What the basic NPC behaviours do and how long they take (NpcBehaviours,
## P4-5b, docs/09 §17.8). Defaults in
## `res://data/tuning/npc_behaviour_settings.tres`. Every value is
## PROVISIONAL (docs/15 §17.8) until Phase 4 is tuned as a whole. Durations
## are action time (real seconds, docs/13 §16.3 D10); what a need gains or
## loses over calendar time is the need model's business (P4-2).

const DEFAULT_PATH: String = "res://data/tuning/npc_behaviour_settings.tres"
const USEC_PER_SEC: int = 1000000

@export_group("Inventory")
## Slots of an NPC's own inventory (a detached inventory, like a container).
@export_range(1, 1000) var inventory_slots: int = 4

@export_group("Eating and drinking")
## How long eating one unit of food takes.
@export_range(0.0, 3600.0, 0.1, "suffix:s") var eat_duration_sec: float = 6.0
## How long drinking at a water spot takes.
@export_range(0.0, 3600.0, 0.1, "suffix:s") var drink_duration_sec: float = 4.0
## Thirst one drink at a water spot takes away (need units; the water of a
## spot never runs out).
@export_range(0.0, 10000.0, 0.5) var drink_thirst_reduction: float = 60.0

@export_group("Resting")
## A resting NPC gets up by itself once its fatigue is at most this.
@export_range(0.0, 10000.0, 0.5) var rest_until_fatigue: float = 5.0
## An NPC in its night sleep (the action "sleep", F-6) gets up by itself
## once its fatigue is at most this (FD-11: it sleeps until fatigue is 0).
@export_range(0.0, 10000.0, 0.5) var sleep_until_fatigue: float = 0.0
## How often a resting NPC's fatigue is looked at.
@export_range(0.1, 3600.0, 0.1, "suffix:s") var rest_check_period_sec: float = 2.0

@export_group("Working")
## How long one stretch of work at the work place lasts; then the NPC
## decides again (and may go on working).
@export_range(0.1, 36000.0, 0.1, "suffix:s") var work_shift_sec: float = 120.0

@export_group("Wandering and fleeing")
## How far from its home (or, without one, from where it stands) an NPC
## wanders.
@export_range(0.5, 1000.0, 0.5, "suffix:m") var wander_radius_m: float = 8.0
## How long it stands where it wandered to.
@export_range(0.0, 3600.0, 0.1, "suffix:s") var wander_linger_sec: float = 5.0
## How far away from the threat a fleeing NPC runs in one go.
@export_range(0.5, 1000.0, 0.5, "suffix:m") var flee_distance_m: float = 12.0


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if inventory_slots < 1:
		errors.append("npc behaviour inventory_slots must be >= 1")
	for entry: Array in [["eat_duration_sec", eat_duration_sec], ["drink_duration_sec", drink_duration_sec], ["drink_thirst_reduction", drink_thirst_reduction], ["rest_until_fatigue", rest_until_fatigue], ["sleep_until_fatigue", sleep_until_fatigue], ["wander_linger_sec", wander_linger_sec]]:
		if not is_finite(float(entry[1])) or float(entry[1]) < 0.0:
			errors.append("npc behaviour %s must be >= 0" % str(entry[0]))
	for entry: Array in [["rest_check_period_sec", rest_check_period_sec], ["work_shift_sec", work_shift_sec], ["wander_radius_m", wander_radius_m], ["flee_distance_m", flee_distance_m]]:
		if not is_finite(float(entry[1])) or float(entry[1]) <= 0.0:
			errors.append("npc behaviour %s must be > 0" % str(entry[0]))
	return errors


## Seconds as whole microseconds (timers are integers: a save never rounds
## them). At least one microsecond for a time that is not zero.
static func to_usec(seconds: float) -> int:
	return maxi(roundi(seconds * float(USEC_PER_SEC)), 1) if seconds > 0.0 else 0


static func load_or_default(path: String = DEFAULT_PATH) -> NpcBehaviourSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcBehaviourSettings:
		return loaded as NpcBehaviourSettings
	GameLogger.warning("config", "npc behaviour settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcBehaviourSettings.new()
