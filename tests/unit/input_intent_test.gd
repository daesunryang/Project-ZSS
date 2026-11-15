extends TestCase
## Input sampling, camera-relative movement and send cadence.

const ACTIONS: Array[StringName] = [
	ClientInputActions.MOVE_FORWARD,
	ClientInputActions.MOVE_BACKWARD,
	ClientInputActions.MOVE_LEFT,
	ClientInputActions.MOVE_RIGHT,
	ClientInputActions.PICKUP,
]


func after_each() -> void:
	for action: StringName in ACTIONS:
		if InputMap.has_action(action):
			InputMap.erase_action(action)


func test_sample_deadzone_and_normalization() -> void:
	assert_eq(InputIntentMath.sample_to_local_intent(Vector2(0.05, 0.0), 0.1), Vector2.ZERO)
	assert_eq(InputIntentMath.sample_to_local_intent(Vector2(NAN, 0.0), 0.1), Vector2.ZERO)
	var diagonal: Vector2 = InputIntentMath.sample_to_local_intent(Vector2.ONE, 0.1)
	assert_true(is_equal_approx(diagonal.length(), 1.0))
	assert_eq(InputIntentMath.sample_to_local_intent(Vector2(0.5, 0.0), 0.1), Vector2(0.5, 0.0))


func test_camera_relative_direction_for_multiple_yaws() -> void:
	assert_true(InputIntentMath.camera_relative_direction(Vector2(0.0, 1.0), 0.0).is_equal_approx(Vector2(0.0, -1.0)))
	assert_true(InputIntentMath.camera_relative_direction(Vector2(0.0, 1.0), PI * 0.5).is_equal_approx(Vector2(-1.0, 0.0)))
	assert_true(InputIntentMath.camera_relative_direction(Vector2(0.0, 1.0), -PI * 0.5).is_equal_approx(Vector2(1.0, 0.0)))
	assert_true(InputIntentMath.camera_relative_direction(Vector2(1.0, 0.0), PI).is_equal_approx(Vector2(-1.0, 0.0)))


func test_move_sender_changes_resends_and_sends_stop_once() -> void:
	var sender: MoveIntentSender = MoveIntentSender.new(0.2, 0.01, 0.01)
	assert_false(sender.should_send(Vector2.ZERO, 0.0, 0.0), "idle zero is not repeated")
	assert_true(sender.should_send(Vector2(0.0, -1.0), 0.0, 0.0), "movement starts immediately")
	assert_false(sender.should_send(Vector2(0.0, -1.0), 0.0, 0.19))
	assert_true(sender.should_send(Vector2(0.0, -1.0), 0.0, 0.20), "held input is refreshed")
	assert_true(sender.should_send(Vector2(1.0, 0.0), 0.0, 0.21), "direction change is immediate")
	assert_true(sender.should_send(Vector2(1.0, 0.0), 0.5, 0.22), "yaw change is immediate while moving")
	assert_true(sender.should_send(Vector2.ZERO, 0.5, 0.23), "stop sends one zero")
	assert_false(sender.should_send(Vector2.ZERO, 1.0, 1.0), "stopped zero is not refreshed")


func test_runtime_actions_use_settings_and_do_not_duplicate() -> void:
	var settings: CameraSettings = CameraSettings.new()
	settings.move_forward_key = KEY_UP
	ClientInputActions.register(settings)
	assert_true(InputMap.has_action(ClientInputActions.MOVE_FORWARD))
	var events: Array[InputEvent] = InputMap.action_get_events(ClientInputActions.MOVE_FORWARD)
	assert_eq(events.size(), 1)
	assert_eq((events[0] as InputEventKey).physical_keycode, KEY_UP)
	ClientInputActions.register(settings)
	assert_eq(InputMap.action_get_events(ClientInputActions.MOVE_FORWARD).size(), 1)


func test_nearest_pickup_candidate_uses_mirrored_positions_only() -> void:
	var items: Dictionary[String, Dictionary] = {
		"item_far": {"position": Vector3(10.0, 0.0, 0.0)},
		"item_near": {"position": Vector3(2.0, 0.0, 0.0)},
		"item_bad": {"position": "not a vector"},
	}
	assert_eq(InputIntentMath.nearest_world_item_id(Vector3.ZERO, items), "item_near")
