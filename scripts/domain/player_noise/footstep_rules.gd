class_name FootstepRules
extends RefCounted
## Pure footstep rules: turning a position change of one server tick into
## footstep positions. No nodes, no world state. Distances are measured on
## the XZ plane (falling or climbing is not walking).

const NO_DISTANCE: float = 0.0


## Distance on the XZ plane.
static func flat_distance(from: Vector3, to: Vector3) -> float:
	return Vector2(to.x - from.x, to.z - from.z).length()


## True when moving `moved_m` in `real_delta` seconds is fast enough to be
## heard. No movement, no elapsed time or invalid input is not walking.
static func is_walking(moved_m: float, real_delta: float, min_speed_mps: float) -> bool:
	if not is_finite(moved_m) or not is_finite(real_delta) or moved_m <= 0.0 or real_delta <= 0.0:
		return false
	return moved_m / real_delta >= min_speed_mps


## True when moving `moved_m` in `real_delta` seconds is faster than
## `teleport_speed_mps`, i.e. a jump (respawn, admin move) rather than
## walking. A non-finite distance counts as a jump.
static func is_teleport(moved_m: float, real_delta: float, teleport_speed_mps: float) -> bool:
	if not is_finite(moved_m) or not is_finite(real_delta):
		return true
	if moved_m <= 0.0:
		return false
	if real_delta <= 0.0:
		return true
	return moved_m / real_delta > teleport_speed_mps


## Points on the straight path `from` -> `to` where a footstep falls:
## the first after `stride_m - carried_m` metres, then every `stride_m`.
## `carried_m` is the distance walked since the previous footstep. At most
## `max_count` points are returned (the earliest ones). Invalid input gives
## an empty list.
static func footstep_positions(from: Vector3, to: Vector3, carried_m: float, stride_m: float, max_count: int) -> PackedVector3Array:
	var positions: PackedVector3Array = []
	if not from.is_finite() or not to.is_finite() or not is_finite(carried_m) or not is_finite(stride_m):
		return positions
	if stride_m <= 0.0 or carried_m < 0.0 or max_count < 1:
		return positions
	var moved: float = flat_distance(from, to)
	if moved <= 0.0:
		return positions
	var next_step_at: float = stride_m - fposmod(carried_m, stride_m)
	while next_step_at <= moved and positions.size() < max_count:
		positions.append(from.lerp(to, next_step_at / moved))
		next_step_at += stride_m
	return positions


## Distance walked since the last footstep after moving `moved_m` more.
## Invalid input restarts the stride (0).
static func carried_after(carried_m: float, moved_m: float, stride_m: float) -> float:
	if not is_finite(carried_m) or not is_finite(moved_m) or not is_finite(stride_m):
		return NO_DISTANCE
	if stride_m <= 0.0 or carried_m < 0.0 or moved_m < 0.0:
		return NO_DISTANCE
	return fposmod(carried_m + moved_m, stride_m)
