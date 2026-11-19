class_name GridPathFinder
extends RefCounted
## Factory and one-shot compatibility wrapper for resumable grid searches.

var _grid: StructureGrid


func _init(grid: StructureGrid) -> void:
	_grid = grid


## `is_door_edge` (optional, P4-5a): the search option "doors are passable",
## see GridPathSearch. Without it the search is what it always was.
func begin_search(from: Vector3, to: Vector3, is_edge_blocked: Callable, max_expanded_nodes: int, max_search_radius_m: float, max_search_msec: float = 0.0, is_door_edge: Callable = Callable()) -> GridPathSearch:
	return GridPathSearch.new(_grid, from, to, is_edge_blocked, max_expanded_nodes, max_search_radius_m, max_search_msec, is_door_edge)


## Runs the same state machine in one slice for callers that do not need to
## retain a search. Its result is identical to advancing the search in parts.
func find_path(from: Vector3, to: Vector3, is_edge_blocked: Callable, max_expanded_nodes: int, max_search_radius_m: float, max_search_msec: float = 0.0) -> GridPathResult:
	var search: GridPathSearch = begin_search(from, to, is_edge_blocked, max_expanded_nodes, max_search_radius_m, max_search_msec)
	return search.advance(max_expanded_nodes)
