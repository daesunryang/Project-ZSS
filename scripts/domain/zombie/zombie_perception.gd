class_name ZombiePerception
extends RefCounted
## Pure sight / facing rules for zombies (docs/02 §6.2). No nodes, no
## geometry: obstacles and target movement are not modelled yet
## (docs/15 P2-25). Everything works on the XZ plane.
##
## Yaw convention (same as the player/camera yaw): yaw 0 faces -Z and the
## forward vector is (-sin(yaw), 0, -cos(yaw)), i.e. Node3D.rotation.y.

## Below this distance the target is "on top of" the eye and always seen.
const TOUCH_DISTANCE_M: float = 0.001


## Unit forward vector for a yaw angle.
static func forward_of(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


## Yaw that faces along `direction` (XZ part). Returns `fallback` for a
## zero-length direction.
static func yaw_towards(direction: Vector3, fallback: float) -> float:
	if is_zero_approx(direction.x) and is_zero_approx(direction.z):
		return fallback
	return atan2(-direction.x, -direction.z)


## Distance on the XZ plane.
static func flat_distance(from: Vector3, to: Vector3) -> float:
	return Vector2(to.x - from.x, to.z - from.z).length()


## True when `target` is within `range_m` and inside the view cone of
## `half_angle_rad` around the eye's facing. Non-finite input is never seen.
static func can_see(eye: Vector3, yaw: float, target: Vector3, range_m: float, half_angle_rad: float) -> bool:
	if not eye.is_finite() or not target.is_finite() or not is_finite(yaw) or not is_finite(range_m) or not is_finite(half_angle_rad):
		return false
	if range_m <= 0.0 or half_angle_rad < 0.0:
		return false
	var offset: Vector2 = Vector2(target.x - eye.x, target.z - eye.z)
	var distance: float = offset.length()
	if distance > range_m:
		return false
	if distance <= TOUCH_DISTANCE_M:
		return true
	var forward: Vector3 = forward_of(yaw)
	var cosine: float = clampf(offset.dot(Vector2(forward.x, forward.z)) / distance, -1.0, 1.0)
	return acos(cosine) <= half_angle_rad
