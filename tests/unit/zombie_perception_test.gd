extends TestCase
## P2-A2: pure sight / facing rules (no nodes, no world).

const RANGE: float = 25.0
const HALF_ANGLE: float = PI / 3.0  # 60 degrees
const EPSILON: float = 0.0001


func test_yaw_convention_matches_player_yaw() -> void:
	assert_true(ZombiePerception.forward_of(0.0).is_equal_approx(Vector3(0, 0, -1)), "yaw 0 faces -Z")
	assert_true(ZombiePerception.forward_of(PI * 0.5).is_equal_approx(Vector3(-1, 0, 0)))
	assert_true(ZombiePerception.forward_of(PI).is_equal_approx(Vector3(0, 0, 1)))
	for yaw: float in [0.0, 0.7, -1.3, 2.9, -3.0]:
		var back: float = ZombiePerception.yaw_towards(ZombiePerception.forward_of(yaw), 99.0)
		assert_true(absf(angle_difference(back, yaw)) < EPSILON, "yaw_towards inverts forward_of for %s" % str(yaw))
	assert_eq(ZombiePerception.yaw_towards(Vector3.ZERO, 1.25), 1.25, "zero direction keeps the fallback")
	assert_eq(ZombiePerception.yaw_towards(Vector3(0, 5, 0), 1.25), 1.25, "vertical direction keeps the fallback")


func test_sees_only_inside_range() -> void:
	assert_true(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(0, 0, -RANGE + 0.01), RANGE, HALF_ANGLE))
	assert_true(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(0, 0, -RANGE), RANGE, HALF_ANGLE), "boundary is inclusive")
	assert_false(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(0, 0, -RANGE - 0.01), RANGE, HALF_ANGLE))
	assert_false(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(0, 0, -1), 0.0, HALF_ANGLE), "blind when range is 0")
	assert_true(ZombiePerception.can_see(Vector3(100, 0, 100), 0.0, Vector3(100, 0, 95), RANGE, HALF_ANGLE), "relative to the eye position")


func test_sees_only_inside_view_cone() -> void:
	var inside: Vector3 = Vector3(-sin(HALF_ANGLE - 0.01), 0, -cos(HALF_ANGLE - 0.01)) * 10.0
	var outside: Vector3 = Vector3(-sin(HALF_ANGLE + 0.01), 0, -cos(HALF_ANGLE + 0.01)) * 10.0
	assert_true(ZombiePerception.can_see(Vector3.ZERO, 0.0, inside, RANGE, HALF_ANGLE))
	assert_false(ZombiePerception.can_see(Vector3.ZERO, 0.0, outside, RANGE, HALF_ANGLE))
	assert_false(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(0, 0, 10), RANGE, HALF_ANGLE), "directly behind")
	assert_false(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(10, 0, 0), RANGE, HALF_ANGLE), "90 degrees to the side")
	assert_true(ZombiePerception.can_see(Vector3.ZERO, PI, Vector3(0, 0, 10), RANGE, HALF_ANGLE), "turned around")
	assert_true(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(0, 0, 10), RANGE, PI), "180 degree half angle sees everything")
	assert_true(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3.ZERO, RANGE, 0.0), "same spot is always seen")


func test_height_is_ignored_and_bad_input_is_never_seen() -> void:
	assert_true(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(0, 50, -5), RANGE, HALF_ANGLE), "XZ plane only")
	assert_eq(ZombiePerception.flat_distance(Vector3(0, 9, 0), Vector3(3, -4, 4)), 5.0)
	assert_false(ZombiePerception.can_see(Vector3(NAN, 0, 0), 0.0, Vector3(0, 0, -5), RANGE, HALF_ANGLE))
	assert_false(ZombiePerception.can_see(Vector3.ZERO, NAN, Vector3(0, 0, -5), RANGE, HALF_ANGLE))
	assert_false(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(0, 0, INF), RANGE, HALF_ANGLE))
	assert_false(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(0, 0, -5), INF, HALF_ANGLE))
	assert_false(ZombiePerception.can_see(Vector3.ZERO, 0.0, Vector3(0, 0, -5), RANGE, -0.1))
