extends TestCase
## P4-5a: the path search option "doors are passable" (GridPathSearch, docs/09
## §17.7). OFF by default: a search without a door query is the search the
## zombies always had (P3-6). ON: a door edge is crossed straight, open or
## closed, and never diagonally past its corners. Pure math, no world.

const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X
const LOW_Z: int = StructureGrid.Layer.EDGE_LOW_Z

var _grid: StructureGrid
var _blocked: Dictionary[int, bool]
var _doors: Dictionary[int, bool]
var _finder: GridPathFinder
var _door_calls: int = 0


func before_each() -> void:
	_grid = StructureGrid.new(1.0)
	_blocked = {}
	_doors = {}
	_finder = GridPathFinder.new(_grid)
	_door_calls = 0


func _is_blocked(slot: Vector3i) -> bool:
	return _blocked.has(StructureGrid.slot_key(slot))


func _is_door(slot: Vector3i) -> bool:
	_door_calls += 1
	return _doors.has(StructureGrid.slot_key(slot))


func _no_door(_slot: Vector3i) -> bool:
	return false


func _block(slot: Vector3i) -> void:
	_blocked[StructureGrid.slot_key(slot)] = true


## A closed door: it blocks, and the door query names it.
func _door(slot: Vector3i, closed: bool = true) -> void:
	_doors[StructureGrid.slot_key(slot)] = true
	if closed:
		_block(slot)
	else:
		_blocked.erase(StructureGrid.slot_key(slot))


## A wall on the line x = `x` for the tiles z_from .. z_to.
func _wall_x(x: int, z_from: int, z_to: int) -> void:
	for z: int in range(z_from, z_to + 1):
		_block(Vector3i(x, z, LOW_X))


func _plain(from: Vector3, to: Vector3, max_nodes: int = 4096, radius_m: float = 40.0) -> GridPathResult:
	return _finder.find_path(from, to, Callable(self, "_is_blocked"), max_nodes, radius_m)


func _walker(from: Vector3, to: Vector3, max_nodes: int = 4096, radius_m: float = 40.0) -> GridPathResult:
	var search: GridPathSearch = _finder.begin_search(from, to, Callable(self, "_is_blocked"), max_nodes, radius_m, 0.0, Callable(self, "_is_door"))
	return search.advance(max_nodes)


## A deterministic clutter of walls (no random numbers).
func _clutter() -> void:
	for index: int in range(160):
		var x: int = (index * 7) % 23 - 4
		var z: int = (index * 13) % 19 - 4
		_block(Vector3i(x, z, LOW_X if index % 2 == 0 else LOW_Z))


func test_without_a_door_query_the_search_is_what_it_was() -> void:
	_clutter()
	# Two of the walls are doors, but nobody says so: they are walls.
	var pairs: Array[Array] = [
		[Vector3(0.5, 0.0, 0.5), Vector3(14.5, 0.0, 9.5)],
		[Vector3(-3.5, 0.0, 12.5), Vector3(16.5, 0.0, -2.5)],
		[Vector3(7.5, 0.0, 7.5), Vector3(7.5, 0.0, -3.5)],
		[Vector3(2.25, 0.0, 3.75), Vector3(11.5, 0.0, 12.5)],
	]
	for pair: Array in pairs:
		var plain: GridPathResult = _plain(pair[0], pair[1])
		# The same search with a door query that names no edge.
		var with_query: GridPathSearch = _finder.begin_search(pair[0], pair[1], Callable(self, "_is_blocked"), 4096, 40.0, 0.0, Callable(self, "_no_door"))
		var asked: GridPathResult = with_query.advance(4096)
		# And the old seven-argument constructor, in slices.
		var sliced: GridPathSearch = GridPathSearch.new(_grid, pair[0], pair[1], Callable(self, "_is_blocked"), 4096, 40.0, 0.0)
		for guard: int in range(10000):
			if sliced.is_finished():
				break
			sliced.advance(3)
		assert_true(plain.found, "the clutter leaves a way: %s" % str(pair))
		assert_eq(asked.found, plain.found)
		assert_eq(asked.waypoints, plain.waypoints, "a door query without doors changes nothing")
		assert_eq(asked.expanded_nodes, plain.expanded_nodes)
		assert_eq(sliced.result.waypoints, plain.waypoints, "slices change nothing")
		assert_eq(sliced.result.expanded_nodes, plain.expanded_nodes)
	assert_eq(_door_calls, 0, "a search without a door query never asks about doors")


func test_a_closed_door_stops_the_default_search_and_lets_a_walker_through() -> void:
	# A room: tiles x 4..6, z 0..2, walls all around, a door in its west wall
	# at z = 1 (the edge between the tiles (3, 1) and (4, 1)).
	_wall_x(4, 0, 2)
	_wall_x(7, 0, 2)
	for x: int in range(4, 7):
		_block(Vector3i(x, 0, LOW_Z))
		_block(Vector3i(x, 3, LOW_Z))
	_door(Vector3i(4, 1, LOW_X))
	var outside: Vector3 = Vector3(1.5, 0.0, 1.5)
	var inside: Vector3 = Vector3(5.5, 0.0, 1.5)
	var zombie: GridPathResult = _plain(outside, inside, 4096, 12.0)
	assert_false(zombie.found, "the default search does not go through a closed door")
	var walker: GridPathResult = _walker(outside, inside, 4096, 12.0)
	assert_true(walker.found, "a walker's search goes through the door")
	assert_eq(walker.waypoints, [Vector3(2.5, 0.0, 1.5), Vector3(3.5, 0.0, 1.5), Vector3(4.5, 0.0, 1.5), inside] as Array[Vector3], "straight through the door")
	assert_true(_door_calls > 0)
	# Out again, and the default search is still shut out afterwards.
	assert_true(_walker(inside, outside, 4096, 12.0).found)
	assert_false(_plain(inside, outside, 4096, 12.0).found)
	# A wall that is not a door stops a walker too.
	_doors.clear()
	assert_false(_walker(outside, inside, 4096, 12.0).found, "only doors are passable")


func test_a_door_is_crossed_straight_never_past_its_corners() -> void:
	# One door on the edge between (0, 0) and (1, 0), standing open.
	_door(Vector3i(1, 0, LOW_X), false)
	var from: Vector3 = Vector3(0.5, 0.0, 0.5)
	var to: Vector3 = Vector3(1.5, 0.0, 1.5)
	var plain: GridPathResult = _plain(from, to)
	assert_eq(plain.waypoints, [to] as Array[Vector3], "the default search cuts the corner of an open door")
	var open_path: GridPathResult = _walker(from, to)
	assert_true(open_path.found)
	assert_eq(open_path.waypoints.size(), 2, "a walker does not cut the corner of a door: %s" % str(open_path.waypoints))
	# The same door closed: the walker's path is the same one.
	_door(Vector3i(1, 0, LOW_X), true)
	var closed_path: GridPathResult = _walker(from, to)
	assert_eq(closed_path.waypoints, open_path.waypoints, "a walker's path does not depend on whether the door is open")
	assert_eq(closed_path.expanded_nodes, open_path.expanded_nodes)
	# Arriving diagonally at the far side of a door is not allowed either,
	# open or closed.
	for closed: bool in [true, false]:
		_door(Vector3i(1, 0, LOW_X), closed)
		var back: GridPathResult = _walker(Vector3(1.5, 0.0, 1.5), Vector3(0.5, 0.0, 0.5))
		assert_eq(back.waypoints.size(), 2, "door closed %s: %s" % [str(closed), str(back.waypoints)])
		assert_eq(_plain(Vector3(1.5, 0.0, 1.5), Vector3(0.5, 0.0, 0.5)).waypoints.size(), 2 if closed else 1, "the default search only minds a closed door")


func test_the_door_query_is_set_before_the_first_slice_only() -> void:
	_wall_x(3, -30, 30)
	_door(Vector3i(3, 0, LOW_X))
	var from: Vector3 = Vector3(0.5, 0.0, 0.5)
	var to: Vector3 = Vector3(5.5, 0.0, 0.5)
	var late: GridPathSearch = _finder.begin_search(from, to, Callable(self, "_is_blocked"), 4096, 40.0)
	late.advance(2)
	assert_false(late.set_door_query(Callable(self, "_is_door")), "too late: the search has looked at edges")
	var early: GridPathSearch = _finder.begin_search(from, to, Callable(self, "_is_blocked"), 4096, 40.0)
	assert_true(early.set_door_query(Callable(self, "_is_door")))
	var through: GridPathResult = early.advance(4096)
	assert_true(through.found)
	for waypoint: Vector3 in through.waypoints:
		assert_true(is_equal_approx(waypoint.z, 0.5), "through the door: %s" % str(through.waypoints))
	# The search that was too late went the long way round the wall.
	var around: GridPathResult = late.advance(4096)
	assert_true(not around.found or around.waypoints.size() > through.waypoints.size())
