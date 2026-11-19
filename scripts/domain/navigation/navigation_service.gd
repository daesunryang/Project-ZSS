class_name NavigationService
extends ServerSystem
## Structure-aware query seam for path searches and line blocking. This
## system owns no world graph or cache; every query reads BuildingService's
## current public edge state.

const SYSTEM_ID: String = "navigation"

var settings: NavigationSettings
var _building: BuildingService
var _finder: GridPathFinder
var _edge_query: Callable


func _init(value: NavigationSettings) -> void:
	settings = value


func get_system_id() -> String:
	return SYSTEM_ID


func on_registered(world: ServerWorld) -> void:
	_building = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	if _building != null:
		_finder = GridPathFinder.new(_building.grid)
		_edge_query = Callable(_building, "is_edge_blocked")


func find_path(from: Vector3, to: Vector3, max_expanded_nodes: int = -1) -> GridPathResult:
	var search: GridPathSearch = begin_search(from, to, max_expanded_nodes)
	if search == null:
		return GridPathResult.new()
	return search.advance(settings.max_expanded_nodes)


func begin_search(from: Vector3, to: Vector3, max_expanded_nodes: int = -1) -> GridPathSearch:
	if _building == null:
		return null
	if _finder == null:
		_finder = GridPathFinder.new(_building.grid)
		_edge_query = Callable(_building, "is_edge_blocked")
	var node_limit: int = settings.max_expanded_nodes
	if max_expanded_nodes >= 0:
		node_limit = mini(node_limit, max_expanded_nodes)
	return _finder.begin_search(from, to, _edge_query, node_limit, settings.max_search_radius_m, settings.max_search_msec)


func blocking_edge_count() -> int:
	return _building.blocking_edge_count() if _building != null else 0


## ServerSystem line query hook. Floors, blueprints and open doors are not
## in BuildingService's live blocker set and therefore do not block.
func is_line_blocked(from: Vector3, to: Vector3) -> bool:
	if _building == null or _building.blocking_edge_count() == 0:
		return false
	return _building.resolve_movement_step(ZombieService.ENTITY_KIND_ZOMBIE, from, to) != to


func blocks_lines() -> bool:
	return true


