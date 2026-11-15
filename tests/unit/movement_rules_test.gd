extends TestCase
## MovementRules, move intent validation and ServerWorld movement state.


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


func test_step_uses_server_speed_and_clamps() -> void:
	assert_eq(MovementRules.step(Vector3.ZERO, Vector2(1, 0), 4.0, 0.5, 100.0), Vector3(2, 0, 0))
	assert_eq(MovementRules.step(Vector3.ZERO, Vector2(0, -1), 4.0, 1.0, 100.0), Vector3(0, 0, -4))
	assert_eq(MovementRules.step(Vector3(99, 0, 0), Vector2(1, 0), 4.0, 1.0, 100.0), Vector3(100, 0, 0), "clamped to world edge")
	var diagonal: Vector3 = MovementRules.step(Vector3.ZERO, Vector2(3, 4), 1.0, 1.0, 100.0)
	assert_true(is_equal_approx(diagonal.length(), 1.0), "over-long input is limited to unit length")


func test_validate_move() -> void:
	assert_eq(IntentValidator.validate_move(1, Vector2(0.6, 0.8), 0.0), "")
	assert_eq(IntentValidator.validate_move(1, Vector2(5, 0), 0.0), IntentValidator.REASON_BAD_DIRECTION)
	assert_eq(IntentValidator.validate_move(1, Vector2(NAN, 0), 0.0), IntentValidator.REASON_BAD_DIRECTION)
	assert_eq(IntentValidator.validate_move(1, Vector2(INF, 0), 0.0), IntentValidator.REASON_BAD_DIRECTION)
	assert_eq(IntentValidator.validate_move(1, Vector2.ZERO, INF), IntentValidator.REASON_BAD_YAW)
	assert_eq(IntentValidator.validate_move(1, Vector2.ZERO, 100.0), IntentValidator.REASON_BAD_YAW)
	assert_eq(IntentValidator.validate_move(-1, Vector2.ZERO, 0.0), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(IntentValidator.validate_move(1, Vector3.ZERO, 0.0), IntentValidator.REASON_BAD_TYPE)
	assert_eq(IntentValidator.validate_move("1", Vector2.ZERO, 0.0), IntentValidator.REASON_BAD_TYPE)


func test_world_movement_sequence_and_timeout() -> void:
	var world: ServerWorld = ServerWorld.new("move_test", GameplaySettings.new(), ItemCatalog.load_directory())
	var alice: PlayerState = world.join("alice")
	var speed: float = world.gameplay.move_speed_mps
	assert_eq(world.set_move_input(alice.player_id, 5, Vector2(1, 0), 0.25, 1000), "")
	assert_eq(world.set_move_input(alice.player_id, 5, Vector2(-1, 0), 0.0, 1000), ServerWorld.REASON_STALE_SEQUENCE)
	assert_eq(world.set_move_input(alice.player_id, 4, Vector2(-1, 0), 0.0, 1000), ServerWorld.REASON_STALE_SEQUENCE)
	world.step_movement(1.0, 1100, 500)
	assert_true(is_equal_approx(alice.position.x, speed))
	assert_eq(alice.yaw, 0.25)
	world.step_movement(1.0, 2000, 500)
	assert_true(is_equal_approx(alice.position.x, speed), "input older than timeout stops the player")
	assert_eq(world.set_move_input("player_999999", 1, Vector2.ZERO, 0.0, 0), ServerWorld.REASON_NOT_ONLINE)
	world.leave(alice.player_id)
	assert_eq(world.set_move_input(alice.player_id, 9, Vector2(1, 0), 0.0, 0), ServerWorld.REASON_NOT_ONLINE)


func test_client_snapshot_ordering() -> void:
	var state: ClientWorldState = ClientWorldState.new()
	assert_true(state.apply_position_snapshot(2, [["player_000001", Vector3(1, 0, 0), 0.0]]))
	assert_false(state.apply_position_snapshot(1, [["player_000001", Vector3(9, 0, 0), 0.0]]), "older tick dropped")
	assert_eq(state.position_of("player_000001"), Vector3(1, 0, 0))
	assert_false(state.apply_position_snapshot(3, [["player_000001", "not a vector", 0.0]]))
	assert_eq(state.last_snapshot_tick, 2)
