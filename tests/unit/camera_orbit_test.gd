extends TestCase
## Node-free camera orbit angle and position calculations.


func test_yaw_wraps_and_pitch_clamps() -> void:
	assert_true(is_equal_approx(CameraOrbitMath.wrap_yaw(TAU + 0.25), 0.25))
	assert_true(is_equal_approx(CameraOrbitMath.wrap_yaw(-TAU - 0.25), -0.25))
	var upper: Vector2 = CameraOrbitMath.apply_mouse_delta(0.0, 0.0, Vector2(-1000.0, -1000.0), 0.01, -0.8, 0.4)
	assert_true(upper.x >= -PI and upper.x < PI, "yaw remains canonical")
	assert_true(is_equal_approx(upper.y, 0.4), "pitch clamps to upper limit")
	var lower: Vector2 = CameraOrbitMath.apply_mouse_delta(0.0, 0.0, Vector2(0.0, 1000.0), 0.01, -0.8, 0.4)
	assert_true(is_equal_approx(lower.y, -0.8), "pitch clamps to lower limit")


func test_camera_position_orbits_target_at_configured_distance() -> void:
	var target: Vector3 = Vector3(2.0, 3.0, 4.0)
	var behind: Vector3 = CameraOrbitMath.camera_position(target, 0.0, 0.0, 6.0)
	assert_eq(behind, Vector3(2.0, 3.0, 10.0))
	var side: Vector3 = CameraOrbitMath.camera_position(target, PI * 0.5, 0.0, 6.0)
	assert_true(side.is_equal_approx(Vector3(8.0, 3.0, 4.0)))
	var elevated: Vector3 = CameraOrbitMath.camera_position(target, 0.0, -PI / 6.0, 6.0)
	assert_true(is_equal_approx(elevated.distance_to(target), 6.0))
	assert_true(elevated.y > target.y)


func test_shipped_camera_settings_load_and_validate() -> void:
	var settings: CameraSettings = CameraSettings.load_or_default()
	assert_true(settings.validate().is_empty())
	assert_true(settings.move_resend_interval_sec <= 0.25)
	assert_eq(settings.move_forward_key, KEY_W)
