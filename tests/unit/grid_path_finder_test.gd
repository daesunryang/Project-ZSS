extends TestCase
## P3-6: bounded, node-free grid path finding against live edge queries.

const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X
const LOW_Z: int = StructureGrid.Layer.EDGE_LOW_Z

var _grid: StructureGrid
var _blocked: Dictionary[int, bool]
var _finder: GridPathFinder


func before_each() -> void:
	_grid = StructureGrid.new(1.0)
	_blocked = {}
	_finder = GridPathFinder.new(_grid)


func _is_blocked(slot: Vector3i) -> bool:
	return _blocked.has(StructureGrid.slot_key(slot))


func _block(slot: Vector3i) -> void:
	_blocked[StructureGrid.slot_key(slot)] = true


func _find(from: Vector3, to: Vector3, max_nodes: int = 256, radius_m: float = 20.0) -> GridPathResult:
	return _finder.find_path(from, to, Callable(self, "_is_blocked"), max_nodes, radius_m)


func test_straight_corridor_returns_the_goal() -> void:
	var result: GridPathResult = _find(Vector3(0.5, 0.0, 0.5), Vector3(4.25, 0.0, 0.5))
	assert_true(result.found)
	assert_false(result.bound_hit)
	assert_true(result.expanded_nodes > 0)
	assert_eq(result.waypoints[result.waypoints.size() - 1], Vector3(4.25, 0.0, 0.5))
	for waypoint: Vector3 in result.waypoints:
		assert_true(is_equal_approx(waypoint.z, 0.5), "straight path: %s" % str(result.waypoints))


func test_path_goes_around_a_wall_and_uses_live_door_state() -> void:
	var from: Vector3 = Vector3(0.5, 0.0, 0.5)
	var to: Vector3 = Vector3(2.5, 0.0, 0.5)
	var door: Vector3i = Vector3i(1, 0, LOW_X)
	_block(door)
	var around: GridPathResult = _find(from, to)
	assert_true(around.found)
	assert_true(around.waypoints.size() >= 3, "went around: %s" % str(around.waypoints))
	var left_corridor: bool = false
	for waypoint: Vector3 in around.waypoints:
		left_corridor = left_corridor or not is_equal_approx(waypoint.z, 0.5)
	assert_true(left_corridor)
	_blocked.erase(StructureGrid.slot_key(door))
	var through_open_door: GridPathResult = _find(from, to)
	assert_true(through_open_door.found)
	for waypoint: Vector3 in through_open_door.waypoints:
		assert_true(is_equal_approx(waypoint.z, 0.5), "open door is straight: %s" % str(through_open_door.waypoints))


func test_closed_edges_can_make_no_path() -> void:
	_block(Vector3i(0, 0, LOW_X))
	_block(Vector3i(1, 0, LOW_X))
	_block(Vector3i(0, 0, LOW_Z))
	_block(Vector3i(0, 1, LOW_Z))
	var result: GridPathResult = _find(Vector3(0.5, 0.0, 0.5), Vector3(2.5, 0.0, 0.5), 256, 3.0)
	assert_false(result.found)
	assert_false(result.bound_hit, "the finite reachable area was exhausted")
	assert_eq(result.waypoints.size(), 0)


func test_diagonal_does_not_cut_past_one_blocked_orthogonal_edge() -> void:
	_block(Vector3i(1, 0, LOW_X))
	var result: GridPathResult = _find(Vector3(0.5, 0.0, 0.5), Vector3(1.5, 0.0, 1.5))
	assert_true(result.found)
	assert_true(result.waypoints.size() >= 2, "must take an orthogonal step first: %s" % str(result.waypoints))
	assert_ne(result.waypoints[0], Vector3(1.5, 0.0, 1.5))


func test_node_expansion_and_radius_bounds_report_fallback() -> void:
	var node_bound: GridPathResult = _find(Vector3(0.5, 0.0, 0.5), Vector3(20.5, 0.0, 0.5), 1, 30.0)
	assert_false(node_bound.found)
	assert_true(node_bound.bound_hit)
	assert_eq(node_bound.expanded_nodes, 1)
	var radius_bound: GridPathResult = _find(Vector3(0.5, 0.0, 0.5), Vector3(20.5, 0.0, 0.5), 256, 5.0)
	assert_false(radius_bound.found)
	assert_true(radius_bound.bound_hit)
	assert_eq(radius_bound.waypoints.size(), 0)


func test_resumed_search_matches_the_same_search_in_one_slice() -> void:
	for z: int in range(-12, 13):
		_block(Vector3i(6, z, LOW_X))
	var from: Vector3 = Vector3(0.5, 0.0, 0.5)
	var to: Vector3 = Vector3(12.5, 0.0, 0.5)
	var one_slice: GridPathResult = _find(from, to, 512, 30.0)
	var resumed: GridPathSearch = _finder.begin_search(from, to, Callable(self, "_is_blocked"), 512, 30.0)
	var slices: int = 0
	while not resumed.is_finished():
		resumed.advance(3)
		slices += 1
	assert_true(slices > 1, "the comparison exercised saved search state")
	assert_true(one_slice.found)
	assert_true(resumed.result.found)
	print("[measure] resumed wall search: %d nodes in %d three-node slices" % [one_slice.expanded_nodes, slices])
	assert_eq(resumed.result.expanded_nodes, one_slice.expanded_nodes)
	assert_eq(resumed.result.waypoints, one_slice.waypoints)
