extends TestCase
## P3-4a: the building grid (docs/04 §2, docs/00 ADR-024): tiles, edge
## slots, rotation, and the movement trace against blocking edges
## (StructureGrid). Pure math, no world.

const SKIN: float = 0.05
const TOLERANCE: float = 0.0001
const TILE: int = StructureDefinition.Placement.TILE
const EDGE: int = StructureDefinition.Placement.EDGE
const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X
const LOW_Z: int = StructureGrid.Layer.EDGE_LOW_Z
const FUZZ_STEPS: int = 4000
const FUZZ_SEED: int = 20261116

var _grid: StructureGrid = null


func before_each() -> void:
	_grid = StructureGrid.new(1.0)


## A set of blocking edges from slots Vector3i(x, z, layer).
func _blocking(slots: Array[Vector3i]) -> Dictionary[int, bool]:
	var blocking: Dictionary[int, bool] = {}
	for slot: Vector3i in slots:
		blocking[StructureGrid.slot_key(slot)] = true
	return blocking


func _step(from: Vector3, to: Vector3, blocking: Dictionary[int, bool], slide: bool = false) -> Vector3:
	return _grid.resolve_step(from, to, blocking, SKIN, slide)


func _near(actual: Vector3, expected: Vector3) -> bool:
	return actual.distance_to(expected) <= TOLERANCE


func test_tiles_round_down_and_a_point_on_a_line_is_in_the_higher_tile() -> void:
	assert_eq(_grid.tile_of(Vector3(0.5, 9.0, 0.5)), Vector2i(0, 0), "height is ignored")
	assert_eq(_grid.tile_of(Vector3(-0.001, 0.0, 0.0)), Vector2i(-1, 0))
	assert_eq(_grid.tile_of(Vector3(3.0, 0.0, -2.0)), Vector2i(3, -2), "exactly on a line: the tile with the larger coordinate")
	assert_eq(_grid.tile_of(Vector3(2.999, 0.0, -2.001)), Vector2i(2, -3))
	assert_eq(_grid.tile_center(Vector2i(-1, 2)), Vector3(-0.5, 0.0, 2.5))
	var half: StructureGrid = StructureGrid.new(0.5)
	assert_eq(half.tile_of(Vector3(1.2, 0.0, -0.3)), Vector2i(2, -1), "the module size is a setting")
	assert_eq(half.tile_center(Vector2i(2, -1)), Vector3(1.25, 0.0, -0.25))


func test_rotation_picks_the_side_and_both_sides_of_an_edge_are_one_slot() -> void:
	var tile: Vector2i = Vector2i(4, -3)
	assert_eq(StructureGrid.slot_of(TILE, tile, 2), Vector3i(4, -3, StructureGrid.Layer.TILE), "a tile piece takes the tile, whatever its facing")
	assert_eq(StructureGrid.slot_of(EDGE, tile, 0), Vector3i(4, -3, LOW_Z), "rotation 0: the -Z side")
	assert_eq(StructureGrid.slot_of(EDGE, tile, 1), Vector3i(5, -3, LOW_X), "rotation 1: the +X side")
	assert_eq(StructureGrid.slot_of(EDGE, tile, 2), Vector3i(4, -2, LOW_Z), "rotation 2: the +Z side")
	assert_eq(StructureGrid.slot_of(EDGE, tile, 3), Vector3i(4, -3, LOW_X), "rotation 3: the -X side")
	# The side of a tile in direction d is the opposite side of its neighbour.
	for rotation: int in range(StructureGrid.ROTATION_COUNT):
		var neighbour: Vector2i = tile + StructureGrid.SIDE_DIRECTIONS[rotation]
		var opposite: int = (rotation + 2) % StructureGrid.ROTATION_COUNT
		assert_eq(StructureGrid.slot_of(EDGE, neighbour, opposite), StructureGrid.slot_of(EDGE, tile, rotation), "one edge, one slot (rotation %d)" % rotation)
	assert_true(StructureGrid.is_valid_rotation(0) and StructureGrid.is_valid_rotation(3))
	assert_false(StructureGrid.is_valid_rotation(-1) or StructureGrid.is_valid_rotation(4))


func test_slot_keys_are_unique() -> void:
	var seen: Dictionary[int, Vector3i] = {}
	var clashes: int = 0
	for x: int in [-StructureGrid.MAX_TILE_COORD - 1, -300, -1, 0, 1, 250, StructureGrid.MAX_TILE_COORD + 1]:
		for z: int in [-StructureGrid.MAX_TILE_COORD - 1, -2, 0, 7, StructureGrid.MAX_TILE_COORD + 1]:
			for layer: int in [StructureGrid.Layer.TILE, LOW_X, LOW_Z]:
				var key: int = StructureGrid.slot_key(Vector3i(x, z, layer))
				if seen.has(key):
					clashes += 1
				seen[key] = Vector3i(x, z, layer)
	assert_eq(clashes, 0)
	assert_eq(seen.size(), 7 * 5 * 3)


func test_anchor_home_ends_and_distances_of_slots() -> void:
	assert_eq(_grid.slot_anchor(Vector3i(2, 3, StructureGrid.Layer.TILE)), Vector3(2.5, 0.0, 3.5))
	assert_eq(_grid.slot_anchor(Vector3i(2, 3, LOW_X)), Vector3(2.0, 0.0, 3.5), "middle of the edge x = 2")
	assert_eq(_grid.slot_anchor(Vector3i(2, 3, LOW_Z)), Vector3(2.5, 0.0, 3.0), "middle of the edge z = 3")
	assert_eq(_grid.slot_home(Vector3i(2, 3, LOW_X)), Vector3(2.5, 0.0, 3.5), "an edge belongs to the tile it is the low side of")
	assert_eq(_grid.edge_ends(Vector3i(2, 3, LOW_X)), PackedVector2Array([Vector2(2.0, 3.0), Vector2(2.0, 4.0)]))
	assert_eq(_grid.edge_ends(Vector3i(2, 3, LOW_Z)), PackedVector2Array([Vector2(2.0, 3.0), Vector2(3.0, 3.0)]))
	assert_true(is_equal_approx(_grid.distance_to_edge(Vector3(1.5, 0.0, 3.5), Vector3i(2, 3, LOW_X)), 0.5), "beside the edge")
	assert_true(is_equal_approx(_grid.distance_to_edge(Vector3(2.0, 5.0, 5.0), Vector3i(2, 3, LOW_X)), 1.0), "past its end, height ignored")
	assert_true(is_equal_approx(_grid.distance_to_edge(Vector3(2.0, 0.0, 3.2), Vector3i(2, 3, LOW_X)), 0.0), "on it")
	assert_true(is_equal_approx(StructureGrid.flat_distance(Vector3(0.0, 7.0, 0.0), Vector3(3.0, 0.0, 4.0)), 5.0))


func test_tiles_inside_the_play_area() -> void:
	assert_true(_grid.is_tile_inside(Vector2i(0, 0), 50.0))
	assert_true(_grid.is_tile_inside(Vector2i(49, -50), 50.0), "the outermost tiles")
	assert_false(_grid.is_tile_inside(Vector2i(50, 0), 50.0), "one past the edge")
	assert_false(_grid.is_tile_inside(Vector2i(0, -51), 50.0))
	assert_false(_grid.is_tile_inside(Vector2i(StructureGrid.MAX_TILE_COORD + 1, 0), 1.0e12), "beyond what the grid works with")


func test_a_step_with_nothing_in_the_way_is_returned_untouched() -> void:
	var from: Vector3 = Vector3(0.5, 1.0, 0.5)
	var to: Vector3 = Vector3(7.25, 2.0, -3.75)
	assert_eq(_step(from, to, {}), to, "no blocking edge at all")
	# A wall that the step does not cross.
	var blocking: Dictionary[int, bool] = _blocking([Vector3i(3, 5, LOW_X), Vector3i(-2, -2, LOW_Z)])
	assert_eq(_step(from, to, blocking), to)
	assert_eq(_step(from, from, blocking), from, "a step of no length")
	assert_false(_grid.is_step_blocked(from, to, blocking))


func test_a_wall_stops_a_step_in_front_of_it_from_either_side() -> void:
	# The edge x = 3 between tiles (2, 0) and (3, 0).
	var blocking: Dictionary[int, bool] = _blocking([Vector3i(3, 0, LOW_X)])
	var from_west: Vector3 = _step(Vector3(2.2, 0.0, 0.5), Vector3(3.6, 0.0, 0.5), blocking)
	assert_true(_near(from_west, Vector3(3.0 - SKIN, 0.0, 0.5)), "stopped %s" % str(from_west))
	var from_east: Vector3 = _step(Vector3(3.6, 0.0, 0.5), Vector3(2.2, 0.0, 0.5), blocking)
	assert_true(_near(from_east, Vector3(3.0 + SKIN, 0.0, 0.5)), "stopped %s" % str(from_east))
	assert_true(_grid.is_step_blocked(Vector3(2.2, 0.0, 0.5), Vector3(3.6, 0.0, 0.5), blocking))
	# A z edge the same way.
	var z_blocking: Dictionary[int, bool] = _blocking([Vector3i(0, -1, LOW_Z)])
	var from_north: Vector3 = _step(Vector3(0.5, 0.0, -1.5), Vector3(0.5, 0.0, -0.5), z_blocking)
	assert_true(_near(from_north, Vector3(0.5, 0.0, -1.0 - SKIN)), "stopped %s" % str(from_north))
	# The next segment of the same line is not blocked.
	assert_eq(_step(Vector3(2.2, 0.0, 1.5), Vector3(3.6, 0.0, 1.5), blocking), Vector3(3.6, 0.0, 1.5), "beside the wall")
	# The stop point lies on the step: an oblique step keeps its direction.
	var oblique: Vector3 = _step(Vector3(2.0, 0.0, 0.1), Vector3(4.0, 0.0, 0.9), blocking)
	assert_true(_near(oblique, Vector3(2.95, 0.0, 0.1 + 0.8 * 0.475)), "stopped %s" % str(oblique))
	# The height comes from the target.
	assert_true(is_equal_approx(_step(Vector3(2.2, 1.0, 0.5), Vector3(3.6, 4.0, 0.5), blocking).y, 4.0))


func test_a_mover_closer_than_the_skin_stays_and_never_passes() -> void:
	var blocking: Dictionary[int, bool] = _blocking([Vector3i(3, 0, LOW_X)])
	var close: Vector3 = Vector3(2.99, 0.0, 0.5)
	assert_true(_near(_step(close, Vector3(3.5, 0.0, 0.5), blocking), close), "closer than the skin: it stays where it is, it is not pushed back")
	# Almost along the wall: it does not go back along its path either.
	var grazing: Vector3 = _step(Vector3(2.99, 0.0, 0.1), Vector3(3.01, 0.0, 0.9), blocking)
	assert_true(_near(grazing, Vector3(2.99, 0.0, 0.1)), "stopped %s" % str(grazing))
	var grazing_slide: Vector3 = _step(Vector3(2.99, 0.0, 0.1), Vector3(3.01, 0.0, 0.9), blocking, true)
	assert_true(_near(grazing_slide, Vector3(2.99, 0.0, 0.9)), "a slider keeps going along the wall: %s" % str(grazing_slide))
	# Pushing into a corner again and again ends in the same place every time.
	var corner: Dictionary[int, bool] = _blocking([Vector3i(3, 0, LOW_X), Vector3i(2, 1, LOW_Z)])
	var pushed: Vector3 = Vector3(2.5, 0.0, 0.5)
	var previous: Vector3 = pushed
	for index: int in range(40):
		previous = pushed
		pushed = _step(pushed, pushed + Vector3(0.194, 0.0, 0.0485), corner, true)
	assert_eq(pushed, previous, "no jitter in the corner: %s" % str(pushed))
	assert_true(pushed.x < 3.0 and pushed.x >= 3.0 - SKIN - TOLERANCE and pushed.z < 1.0 and pushed.z >= 1.0 - SKIN - TOLERANCE, "within the skin of both walls: %s" % str(pushed))
	# Exactly on the line the mover is in the higher tile: east of the wall.
	var on_line: Vector3 = Vector3(3.0, 0.0, 0.5)
	assert_true(_near(_step(on_line, Vector3(2.5, 0.0, 0.5), blocking), on_line), "it cannot go west")
	assert_eq(_step(on_line, Vector3(3.5, 0.0, 0.5), blocking), Vector3(3.5, 0.0, 0.5), "it can go east")
	assert_eq(_step(on_line, Vector3(3.0, 0.0, 5.5), blocking), Vector3(3.0, 0.0, 5.5), "and along the line")


func test_a_long_step_cannot_tunnel_through_a_thin_wall() -> void:
	var blocking: Dictionary[int, bool] = _blocking([Vector3i(10, 4, LOW_X)])
	var stopped: Vector3 = _step(Vector3(-40.5, 0.0, 4.5), Vector3(45.5, 0.0, 4.5), blocking)
	assert_true(_near(stopped, Vector3(10.0 - SKIN, 0.0, 4.5)), "one step of 86 m stops at the wall: %s" % str(stopped))
	# An oblique long step that crosses many tiles before the wall.
	var oblique: Vector3 = _step(Vector3(0.5, 0.0, 0.5), Vector3(20.5, 0.0, 8.5), _blocking([Vector3i(10, 4, LOW_X)]))
	assert_true(oblique.x < 10.0 and oblique.x > 9.9, "stopped at the wall: %s" % str(oblique))
	# The same step one row lower misses the wall.
	assert_eq(_step(Vector3(0.5, 0.0, -0.5), Vector3(20.5, 0.0, 7.5), blocking), Vector3(20.5, 0.0, 7.5))


func test_diagonal_steps_through_a_grid_corner() -> void:
	var from: Vector3 = Vector3(0.5, 0.0, 0.5)
	var to: Vector3 = Vector3(1.5, 0.0, 1.5)
	# The four edges that meet at the corner (1, 1).
	var below: Vector3i = Vector3i(1, 0, LOW_X)   # between tiles (0,0) and (1,0)
	var above: Vector3i = Vector3i(1, 1, LOW_X)   # between tiles (0,1) and (1,1)
	var left: Vector3i = Vector3i(0, 1, LOW_Z)    # between tiles (0,0) and (0,1)
	var right: Vector3i = Vector3i(1, 1, LOW_Z)   # between tiles (1,0) and (1,1)
	# One wall ending at the corner leaves a way around it.
	for single: Vector3i in [below, above, left, right]:
		assert_eq(_step(from, to, _blocking([single])), to, "a wall tip does not seal the corner: %s" % str(single))
	# Two walls on the same way around: the other way is open.
	assert_eq(_step(from, to, _blocking([below, right])), to, "an L around tile (1, 0)")
	assert_eq(_step(from, to, _blocking([left, above])), to, "an L around tile (0, 1)")
	# Walls on both ways: sealed.
	for sealed: Array in [[below, left], [below, above], [left, right], [right, above]]:
		var pair: Array[Vector3i] = [sealed[0], sealed[1]]
		var stopped: Vector3 = _step(from, to, _blocking(pair))
		assert_true(_near(stopped, Vector3(1.0 - SKIN, 0.0, 1.0 - SKIN)), "sealed corner %s stops the step: %s" % [str(pair), str(stopped)])
		# And in the opposite direction.
		var back: Vector3 = _step(to, from, _blocking(pair))
		assert_true(_near(back, Vector3(1.0 + SKIN, 0.0, 1.0 + SKIN)), "sealed corner %s from the other side: %s" % [str(pair), str(back)])
	# The other diagonal through the same corner.
	var stopped_other: Vector3 = _step(Vector3(1.5, 0.0, 0.5), Vector3(0.5, 0.0, 1.5), _blocking([below, above]))
	assert_true(_near(stopped_other, Vector3(1.0 + SKIN, 0.0, 1.0 - SKIN)), "stopped %s" % str(stopped_other))
	# A step that passes just beside the corner takes one way around it.
	assert_eq(_step(Vector3(0.5, 0.0, 0.4), Vector3(1.5, 0.0, 1.4), _blocking([left, above])), Vector3(1.5, 0.0, 1.4), "x first: open")
	var blocked_way: Vector3 = _step(Vector3(0.5, 0.0, 0.4), Vector3(1.5, 0.0, 1.4), _blocking([below]))
	assert_true(blocked_way.x < 1.0, "x first: blocked, even though the corner is not sealed: %s" % str(blocked_way))


func test_sliding_keeps_the_part_of_the_step_along_the_wall() -> void:
	var wall: Vector3i = Vector3i(3, 0, LOW_X)
	var from: Vector3 = Vector3(2.5, 0.0, 0.2)
	var to: Vector3 = Vector3(3.3, 0.0, 0.8)
	var stopped: Vector3 = _step(from, to, _blocking([wall]), false)
	var slid: Vector3 = _step(from, to, _blocking([wall]), true)
	assert_true(stopped.z < 0.6, "without sliding the step ends where it met the wall: %s" % str(stopped))
	assert_true(_near(slid, Vector3(3.0 - SKIN, 0.0, 0.8)), "with sliding it goes on along the wall: %s" % str(slid))
	# Sliding into a second wall stops in the corner.
	var corner: Vector3 = _step(Vector3(2.5, 0.0, 0.5), Vector3(3.3, 0.0, 1.4), _blocking([wall, Vector3i(2, 1, LOW_Z)]), true)
	assert_true(_near(corner, Vector3(3.0 - SKIN, 0.0, 1.0 - SKIN)), "stopped in the corner: %s" % str(corner))
	# A step straight into a wall has nothing to slide with.
	assert_true(_near(_step(Vector3(2.5, 0.0, 0.5), Vector3(3.5, 0.0, 0.5), _blocking([wall]), true), Vector3(3.0 - SKIN, 0.0, 0.5)))
	# Sliding along a z edge.
	var z_slid: Vector3 = _step(Vector3(0.2, 0.0, 1.5), Vector3(0.8, 0.0, 2.4), _blocking([Vector3i(0, 2, LOW_Z)]), true)
	assert_true(_near(z_slid, Vector3(0.8, 0.0, 2.0 - SKIN)), "slid %s" % str(z_slid))
	# Nothing in the way: sliding changes nothing.
	assert_eq(_step(from, Vector3(2.9, 0.0, 0.8), _blocking([wall]), true), Vector3(2.9, 0.0, 0.8))


func test_non_finite_steps_do_not_move_and_do_not_hang() -> void:
	var blocking: Dictionary[int, bool] = _blocking([Vector3i(3, 0, LOW_X)])
	var from: Vector3 = Vector3(2.5, 0.0, 0.5)
	assert_eq(_step(from, Vector3(INF, 0.0, 0.5), blocking), from)
	assert_eq(_step(from, Vector3(NAN, 0.0, 0.5), blocking), from)
	assert_false(_grid.is_step_blocked(from, Vector3(INF, 0.0, 0.5), blocking))


## Random walls and random steps: whatever the trace answers, the straight
## way from the start to the answer crosses no blocking edge, and the mover
## never goes backwards or farther than it asked to.
func test_random_steps_never_end_behind_a_blocking_edge() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = FUZZ_SEED
	var slots: Array[Vector3i] = []
	for index: int in range(60):
		slots.append(Vector3i(rng.randi_range(-4, 4), rng.randi_range(-4, 4), LOW_X if rng.randf() < 0.5 else LOW_Z))
	var blocking: Dictionary[int, bool] = _blocking(slots)
	var crossed: int = 0
	var backwards: int = 0
	var stopped_count: int = 0
	var slide_crossed: int = 0
	for index: int in range(FUZZ_STEPS):
		var from: Vector3 = Vector3(rng.randf_range(-5.0, 5.0), 0.0, rng.randf_range(-5.0, 5.0))
		var to: Vector3 = from + Vector3(rng.randf_range(-3.0, 3.0), 0.0, rng.randf_range(-3.0, 3.0))
		# Every fourth step starts and ends on whole and half metres, so steps
		# through exact grid corners and along grid lines are in the mix.
		if index % 4 == 0:
			from = Vector3(roundf(from.x * 2.0) / 2.0, 0.0, roundf(from.z * 2.0) / 2.0)
			to = Vector3(roundf(to.x * 2.0) / 2.0, 0.0, roundf(to.z * 2.0) / 2.0)
		var result: Vector3 = _grid.resolve_step(from, to, blocking, SKIN, false)
		if result != to:
			stopped_count += 1
		if _grid.is_step_blocked(from, result, blocking):
			crossed += 1
		if (result - from).dot(to - from) < -TOLERANCE or (result - from).length() > (to - from).length() + TOLERANCE:
			backwards += 1
		# A slide ends somewhere reachable too: start -> first stop -> end.
		var first: Vector3 = result
		var slid: Vector3 = _grid.resolve_step(from, to, blocking, SKIN, true)
		if slid != first and _grid.is_step_blocked(first, slid, blocking):
			slide_crossed += 1
	assert_eq(crossed, 0, "steps that ended behind a blocking edge")
	assert_eq(backwards, 0, "steps that went backwards or too far")
	assert_eq(slide_crossed, 0, "slides that crossed a blocking edge")
	assert_true(stopped_count > FUZZ_STEPS / 10, "the walls did stop steps: %d" % stopped_count)
