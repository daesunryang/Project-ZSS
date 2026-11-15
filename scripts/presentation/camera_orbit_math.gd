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
