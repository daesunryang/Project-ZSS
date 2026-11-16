class_name GridPathSearch
extends RefCounted
## Incremental bounded weighted A* search. Every instance owns its frontier,
## scores, parents and edge memo so it can be resumed on a later server tick.

const SQRT_TWO: float = 1.4142135623730951
const HEURISTIC_WEIGHT: float = 1000000.0

var result: GridPathResult = GridPathResult.new()
var last_advance_expanded_nodes: int = 0

var _grid: StructureGrid
var _query: Callable
var _start: Vector2i
var _goal: Vector2i
var _exact_goal: Vector3
var _max_expanded_nodes: int = 0
var _max_search_msec: float = 0.0
var _radius_squared: float = 0.0
var _finished: bool = false
var _radius_clipped: bool = false

var _g_scores: Dictionary = {}
var _came_from: Dictionary = {}
var _closed: Dictionary = {}
var _edge_cache: Dictionary = {}
var _heap_nodes: Array[Vector2i] = []
var _heap_scores: PackedFloat64Array = PackedFloat64Array()
var _popped_node: Vector2i = Vector2i.ZERO


func _init(grid: StructureGrid, from: Vector3, to: Vector3, is_edge_blocked: Callable, max_expanded_nodes: int, max_search_radius_m: float, max_search_msec: float = 0.0) -> void:
	_grid = grid
	_query = is_edge_blocked
	_exact_goal = to
	_max_expanded_nodes = max_expanded_nodes
	_max_search_msec = max_search_msec
	if grid == null or not from.is_finite() or not to.is_finite() or not is_edge_blocked.is_valid() or max_expanded_nodes < 1 or not is_finite(max_search_radius_m) or max_search_radius_m <= 0.0 or not is_finite(max_search_msec) or max_search_msec < 0.0:
		_finished = true
		return
	_start = grid.tile_of(from)
	_goal = grid.tile_of(to)
	var radius_tiles: float = max_search_radius_m / grid.module_m
	_radius_squared = radius_tiles * radius_tiles
	if float((_goal - _start).length_squared()) > _radius_squared:
		result.bound_hit = true
		_finished = true
		return
	if _start == _goal:
		result.found = true
		result.waypoints.append(to)
		_finished = true
		return
	_g_scores[_start] = 0.0
	_heap_push(_start, HEURISTIC_WEIGHT * _octile(_goal.x - _start.x, _goal.y - _start.y))


func is_finished() -> bool:
	return _finished


## Expands at most `node_budget` nodes and preserves all state when the slice
## ends. The public per-search bound remains cumulative across every slice.
func advance(node_budget: int) -> GridPathResult:
	last_advance_expanded_nodes = 0
	if _finished or node_budget < 1:
		return result
	var deadline_usec: int = Time.get_ticks_usec() + ceili(_max_search_msec * 1000.0) if _max_search_msec > 0.0 else 0
	while not _heap_nodes.is_empty() and last_advance_expanded_nodes < node_budget:
		if deadline_usec > 0 and last_advance_expanded_nodes % 8 == 0 and Time.get_ticks_usec() >= deadline_usec:
			result.bound_hit = true
			_finished = true
			return result
		if result.expanded_nodes >= _max_expanded_nodes:
			result.bound_hit = true
			_finished = true
			return result
		_heap_pop()
		var current: Vector2i = _popped_node
		if _closed.has(current):
			continue
		_closed[current] = true
		result.expanded_nodes += 1
		last_advance_expanded_nodes += 1
		if current == _goal:
			result.found = true
			result.waypoints = _reconstruct()
			_finished = true
			return result
		_expand(current)
	if _heap_nodes.is_empty():
		result.bound_hit = _radius_clipped
		_finished = true
	elif result.expanded_nodes >= _max_expanded_nodes:
		result.bound_hit = true
		_finished = true
	return result


func _expand(current: Vector2i) -> void:
	var west_blocked: bool = _is_edge_blocked(Vector3i(current.x, current.y, StructureGrid.Layer.EDGE_LOW_X))
	var east_blocked: bool = _is_edge_blocked(Vector3i(current.x + 1, current.y, StructureGrid.Layer.EDGE_LOW_X))
	var north_blocked: bool = _is_edge_blocked(Vector3i(current.x, current.y, StructureGrid.Layer.EDGE_LOW_Z))
	var south_blocked: bool = _is_edge_blocked(Vector3i(current.x, current.y + 1, StructureGrid.Layer.EDGE_LOW_Z))
	var current_g: float = float(_g_scores[current])
	for direction_index: int in 8:
		var blocked: bool
		var direction: Vector2i
		match direction_index:
			0: blocked = east_blocked; direction = Vector2i(1, 0)
			1: blocked = west_blocked; direction = Vector2i(-1, 0)
			2: blocked = south_blocked; direction = Vector2i(0, 1)
			3: blocked = north_blocked; direction = Vector2i(0, -1)
			4: blocked = east_blocked or south_blocked; direction = Vector2i(1, 1)
			5: blocked = east_blocked or north_blocked; direction = Vector2i(1, -1)
			6: blocked = west_blocked or south_blocked; direction = Vector2i(-1, 1)
			_: blocked = west_blocked or north_blocked; direction = Vector2i(-1, -1)
		if blocked:
			continue
		var next: Vector2i = current + direction
		if direction_index >= 4:
			# A smoothed mover may approach a tile centre off-axis, so also
			# require the two destination-side edges for diagonal movement.
			var entry_x: Vector3i = Vector3i(current.x + 1 if direction.x > 0 else current.x, next.y, StructureGrid.Layer.EDGE_LOW_X)
			var entry_z: Vector3i = Vector3i(next.x, current.y + 1 if direction.y > 0 else current.y, StructureGrid.Layer.EDGE_LOW_Z)
			if _is_edge_blocked(entry_x) or _is_edge_blocked(entry_z):
				continue
		var relative: Vector2i = next - _start
		if float(relative.length_squared()) > _radius_squared:
			_radius_clipped = true
			continue
		if _closed.has(next):
			continue
		var tentative: float = current_g + (1.0 if direction_index < 4 else SQRT_TWO)
		if _g_scores.has(next) and tentative >= float(_g_scores[next]):
			continue
		_g_scores[next] = tentative
		_came_from[next] = current
		var score: float = tentative + HEURISTIC_WEIGHT * _octile(_goal.x - next.x, _goal.y - next.y)
		_heap_push(next, score)


func _is_edge_blocked(slot: Vector3i) -> bool:
	var key: int = StructureGrid.slot_key(slot)
	if not _edge_cache.has(key):
		_edge_cache[key] = bool(_query.call(slot))
	return bool(_edge_cache[key])


func _heap_push(node: Vector2i, score: float) -> void:
	var index: int = _heap_nodes.size()
	_heap_nodes.append(node)
	_heap_scores.append(score)
	while index > 0:
		var parent: int = (index - 1) / 2
		if not _heap_less(score, node, _heap_scores[parent], _heap_nodes[parent]):
			break
		_heap_nodes[index] = _heap_nodes[parent]
		_heap_scores[index] = _heap_scores[parent]
		index = parent
	_heap_nodes[index] = node
	_heap_scores[index] = score


func _heap_pop() -> void:
	_popped_node = _heap_nodes[0]
	var last_index: int = _heap_nodes.size() - 1
	var last_node: Vector2i = _heap_nodes[last_index]
	var last_score: float = _heap_scores[last_index]
	_heap_nodes.remove_at(last_index)
	_heap_scores.resize(last_index)
	if last_index == 0:
		return
	var index: int = 0
	while true:
		var left: int = index * 2 + 1
		if left >= last_index:
			break
		var right: int = left + 1
		var child: int = left
		if right < last_index and _heap_less(_heap_scores[right], _heap_nodes[right], _heap_scores[left], _heap_nodes[left]):
			child = right
		if not _heap_less(_heap_scores[child], _heap_nodes[child], last_score, last_node):
			break
		_heap_nodes[index] = _heap_nodes[child]
		_heap_scores[index] = _heap_scores[child]
		index = child
	_heap_nodes[index] = last_node
	_heap_scores[index] = last_score


func _reconstruct() -> Array[Vector3]:
	var reversed: Array[Vector2i] = []
	var current: Vector2i = _goal
	while current != _start:
		reversed.append(current)
		current = _came_from[current]
	var tiles: Array[Vector2i] = [_start]
	for index: int in range(reversed.size() - 1, -1, -1):
		tiles.append(reversed[index])
	var waypoints: Array[Vector3] = []
	for index: int in range(1, tiles.size()):
		var point: Vector3 = _grid.tile_center(tiles[index])
		point.y = _exact_goal.y
		waypoints.append(point)
	waypoints[waypoints.size() - 1] = _exact_goal
	return waypoints


static func _heap_less(left_score: float, left: Vector2i, right_score: float, right: Vector2i) -> bool:
	if left_score != right_score:
		return left_score < right_score
	if left.x != right.x:
		return left.x < right.x
	return left.y < right.y


static func _octile(dx: int, dz: int) -> float:
	var absolute_x: int = absi(dx)
	var absolute_z: int = absi(dz)
	return float(maxi(absolute_x, absolute_z)) + (SQRT_TWO - 1.0) * float(mini(absolute_x, absolute_z))
