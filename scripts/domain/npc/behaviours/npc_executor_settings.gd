class_name NpcExecutorSettings
extends Resource
## How NPCs carry out what they decided (NpcExecutor, P4-5a, docs/09
## §17.7). Defaults in `res://data/tuning/npc_executor_settings.tres`. Every
## value is PROVISIONAL (docs/15 §17.7, docs/13 §16.4) until Phase 4 is
## tuned as a whole. All times are action time (real seconds, docs/13 §16.3
## D10).

const DEFAULT_PATH: String = "res://data/tuning/npc_executor_settings.tres"
const USEC_PER_SEC: int = 1000000

@export_group("Walking")
@export_range(0.05, 20.0, 0.05, "suffix:m/s") var walk_speed_mps: float = 1.4
@export_range(0.05, 20.0, 0.05, "suffix:m/s") var run_speed_mps: float = 3.6

@export_group("Path planning")
## Nodes all NPC searches together may expand in one server tick.
@export_range(1, 1000000) var max_planning_nodes_per_tick: int = 24
## Nodes one search may expand in one tick (the rest waits its next turn).
@export_range(1, 1000000) var max_search_nodes_per_tick: int = 8
## Searches that get a turn in one tick.
@export_range(1, 100000) var max_plans_per_tick: int = 4
## Nodes one search may expand in all (never more than
## NavigationSettings.max_expanded_nodes, whose radius also applies).
@export_range(1, 100000) var max_search_nodes: int = 2048
## After a walk was blocked, the NPC waits this long before it searches
## again (within one action).
@export_range(0.0, 600.0, 0.05, "suffix:s") var min_replan_interval_sec: float = 1.0
## Searches after the first one that one action may need. One more blocked
## walk fails the action (path_blocked).
@export_range(0, 100) var max_replans_per_action: int = 3

@export_group("Doors")
## How long an NPC stands in front of a door it just opened.
@export_range(0.0, 60.0, 0.05, "suffix:s") var door_pause_sec: float = 0.3


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	for entry: Array in [["walk_speed_mps", walk_speed_mps], ["run_speed_mps", run_speed_mps]]:
		if not is_finite(float(entry[1])) or float(entry[1]) <= 0.0:
			errors.append("npc executor %s must be > 0" % str(entry[0]))
	for entry: Array in [["max_planning_nodes_per_tick", max_planning_nodes_per_tick], ["max_search_nodes_per_tick", max_search_nodes_per_tick], ["max_plans_per_tick", max_plans_per_tick], ["max_search_nodes", max_search_nodes]]:
		if int(entry[1]) < 1:
			errors.append("npc executor %s must be >= 1" % str(entry[0]))
	for entry: Array in [["min_replan_interval_sec", min_replan_interval_sec], ["door_pause_sec", door_pause_sec]]:
		if not is_finite(float(entry[1])) or float(entry[1]) < 0.0:
			errors.append("npc executor %s must be >= 0" % str(entry[0]))
	if max_replans_per_action < 0:
		errors.append("npc executor max_replans_per_action must be >= 0")
	return errors


## Seconds as whole microseconds (the executor counts time in integers, so a
## save never rounds it).
static func to_usec(seconds: float) -> int:
	return roundi(seconds * float(USEC_PER_SEC))


static func load_or_default(path: String = DEFAULT_PATH) -> NpcExecutorSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcExecutorSettings:
		return loaded as NpcExecutorSettings
	GameLogger.warning("config", "npc executor settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcExecutorSettings.new()
