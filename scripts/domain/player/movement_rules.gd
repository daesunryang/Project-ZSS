class_name MovementRules
extends RefCounted
## Pure server movement rules (no physics/collision yet: Phase 3 world).
## Input direction is a Vector2 on the XZ plane (x -> +X, y -> +Z) with
## length <= 1; speed comes from GameplaySettings, never from the client.

## Tolerance for float noise on normalized client input.
const DIRECTION_LENGTH_TOLERANCE: float = 0.001
const MAX_DIRECTION_LENGTH: float = 1.0


## Next position after `delta` seconds, clamped to the square world.
static func step(position: Vector3, direction: Vector2, speed_mps: float, delta: float, half_extent_m: float) -> Vector3:
	var clamped_direction: Vector2 = direction.limit_length(MAX_DIRECTION_LENGTH)
	var next: Vector3 = position + Vector3(clamped_direction.x, 0.0, clamped_direction.y) * speed_mps * delta
	return Vector3(clampf(next.x, -half_extent_m, half_extent_m), next.y, clampf(next.z, -half_extent_m, half_extent_m))


## True when `direction` is an acceptable intent magnitude.
static func is_valid_direction(direction: Vector2) -> bool:
	return direction.is_finite() and direction.length() <= MAX_DIRECTION_LENGTH + DIRECTION_LENGTH_TOLERANCE
