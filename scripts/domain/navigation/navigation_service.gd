class_name NavigationService
extends ServerSystem
## Structure-aware query seam for path searches and line blocking. This
## system owns no world graph or cache; every query reads BuildingService's
## current public edge state.

const SYSTEM_ID: String = "navigation"

var settings: NavigationSettings
var _world_ref: WeakRef
var _finder: GridPathFinder
var _edge_query: Callable


func _init(value: NavigationSettings) -> void:
	settings = value


func get_system_id() -> String:
	return SYSTEM_ID


func on_registered(world: ServerWorld) -> void:
	_world_ref = weakref(world)
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	if building != null:
		_finder = GridPathFinder.new(building.grid)
		_edge_query = Callable(building, "is_edge_blocked")


func find_path(from: Vector3, to: Vector3, max_expanded_nodes: int = -1) -> GridPathResult:
	var search: GridPathSearch = begin_search(from, to, max_expanded_nodes)
	if search == null:
		return GridPathResult.new()
	return search.advance(settings.max_expanded_nodes)


func begin_search(from: Vector3, to: Vector3, max_expanded_nodes: int = -1) -> GridPathSearch:
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService if world != null else null
	if building == null:
		return null
	if _finder == null:
		_finder = GridPathFinder.new(building.grid)
		_edge_query = Callable(building, "is_edge_blocked")
	var node_limit: int = settings.max_expanded_nodes
	if max_expanded_nodes >= 0:
		node_limit = mini(node_limit, max_expanded_nodes)
	return _finder.begin_search(from, to, _edge_query, node_limit, settings.max_search_radius_m, settings.max_search_msec)


func blocking_edge_count() -> int:
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService if world != null else null
	return building.blocking_edge_count() if building != null else 0


## ServerSystem line query hook. Floors, blueprints and open doors are not
## in BuildingService's live blocker set and therefore do not block.
func is_line_blocked(from: Vector3, to: Vector3) -> bool:
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService if world != null else null
	if building == null or building.blocking_edge_count() == 0:
		return false
	return building.resolve_movement_step(ZombieService.ENTITY_KIND_ZOMBIE, from, to) != to


