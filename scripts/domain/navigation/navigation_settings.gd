class_name NavigationSettings
extends Resource
## Bounded zombie grid navigation tuning (P3-6, docs/15 section 15.6).

const DEFAULT_PATH: String = "res://data/tuning/navigation_settings.tres"

@export_group("Search")
@export_range(1, 100000) var max_expanded_nodes: int = 2048
@export_range(0.1, 10000.0) var max_search_radius_m: float = 60.0
## Non-deterministic operator safety valve. Zero disables wall-clock decisions.
@export_range(0.0, 1000.0) var max_search_msec: float = 0.0

@export_group("Replanning")
@export_range(0.0, 1000.0) var replan_goal_distance_m: float = 1.0
@export_range(0.01, 1000.0) var replan_timeout_sec: float = 1.0
@export_range(0.01, 1000.0) var min_plan_interval_sec: float = 0.25

@export_group("Budget")
@export_range(1, 100000) var max_plans_per_tick: int = 8
@export_range(1, 1000000) var max_planning_nodes_per_tick: int = 48
## Round-robin slice: one pending search cannot consume the whole tick.
@export_range(1, 1000000) var max_search_nodes_per_tick: int = 8
## Non-deterministic operator safety valve. Zero disables wall-clock decisions.
@export_range(0.0, 1000.0) var max_planning_msec_per_tick: float = 0.0


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if max_expanded_nodes < 1:
		errors.append("navigation max_expanded_nodes must be >= 1")
	if not is_finite(max_search_radius_m) or max_search_radius_m <= 0.0:
		errors.append("navigation max_search_radius_m must be > 0")
	if not is_finite(max_search_msec) or max_search_msec < 0.0:
		errors.append("navigation max_search_msec must be >= 0")
	if not is_finite(replan_goal_distance_m) or replan_goal_distance_m < 0.0:
		errors.append("navigation replan_goal_distance_m must be >= 0")
	if not is_finite(replan_timeout_sec) or replan_timeout_sec <= 0.0:
		errors.append("navigation replan_timeout_sec must be > 0")
	if not is_finite(min_plan_interval_sec) or min_plan_interval_sec <= 0.0:
		errors.append("navigation min_plan_interval_sec must be > 0")
	if max_plans_per_tick < 1:
		errors.append("navigation max_plans_per_tick must be >= 1")
	if max_planning_nodes_per_tick < 1:
		errors.append("navigation max_planning_nodes_per_tick must be >= 1")
	if max_search_nodes_per_tick < 1:
		errors.append("navigation max_search_nodes_per_tick must be >= 1")
	if not is_finite(max_planning_msec_per_tick) or max_planning_msec_per_tick < 0.0:
		errors.append("navigation max_planning_msec_per_tick must be >= 0")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NavigationSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NavigationSettings:
		return loaded as NavigationSettings
	GameLogger.warning("config", "navigation settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NavigationSettings.new()

