class_name CameraOrbitMath
extends RefCounted
## Pure third-person orbit calculations. No Node or input dependency.


## Applies a mouse delta and returns (wrapped yaw, clamped pitch).
static func apply_mouse_delta(yaw: float, pitch: float, mouse_delta: Vector2, sensitivity: float, min_pitch: float, max_pitch: float) -> Vector2:
	return Vector2(
		wrap_yaw(yaw - mouse_delta.x * sensitivity),
		clampf(pitch - mouse_delta.y * sensitivity, min_pitch, max_pitch)
	)


## Canonical yaw used for both camera-relative input and the move intent.
static func wrap_yaw(yaw: float) -> float:
	return wrapf(yaw, -PI, PI)


## World position of an orbit camera looking at `target`.
static func camera_position(target: Vector3, yaw: float, pitch: float, distance: float) -> Vector3:
	var offset: Vector3 = Vector3(0.0, 0.0, distance)
	offset = offset.rotated(Vector3.RIGHT, pitch)
	offset = offset.rotated(Vector3.UP, yaw)
	return target + offset


## Moves the zoom by whole configured steps. Positive steps move farther.
static func zoom_distance(distance: float, steps_farther: int, step_m: float, minimum_m: float, maximum_m: float) -> float:
	return clampf(distance + float(steps_farther) * step_m, minimum_m, maximum_m)


## Moves the look target by whole configured height steps.
static func target_height_offset(offset_m: float, steps_up: int, step_m: float, minimum_m: float, maximum_m: float) -> float:
	return clampf(offset_m + float(steps_up) * step_m, minimum_m, maximum_m)


## Orbit position clamped above the local ground plane. The target is not
## moved, so the camera continues to look at the configured reference height.
static func camera_position_above_ground(target: Vector3, yaw: float, pitch: float, distance: float, ground_y: float, clearance_m: float) -> Vector3:
	var position: Vector3 = camera_position(target, yaw, pitch, distance)
	position.y = maxf(position.y, ground_y + clearance_m)
	return position
