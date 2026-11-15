class_name MeleeHitRules
extends RefCounted
## Pure melee hit rules (docs/02 §5.2): who is inside a swing and how much
## damage a hit does. No nodes, no world state; everything is on the XZ
## plane (height is ignored until there is terrain, docs/15 P2-42).
##
## Yaw convention: the shared player/zombie one (ZombiePerception): yaw 0
## faces -Z and the forward vector is (-sin(yaw), 0, -cos(yaw)).

const HALF: float = 0.5
const NO_DAMAGE: float = 0.0
const NO_TARGET: String = ""


## Unit direction of a swing aimed at `aim_yaw`.
static func aim_direction(aim_yaw: float) -> Vector3:
	return ZombiePerception.forward_of(aim_yaw)


## True for a finite yaw within [-max_abs, max_abs].
static func is_valid_aim_yaw(aim_yaw: float, max_abs: float) -> bool:
	return is_finite(aim_yaw) and absf(aim_yaw) <= max_abs


## True when `target` is within `range_m` of `origin` and inside the arc of
## `arc_angle_deg` (full opening angle) centred on `aim_yaw`. A target on
## top of the origin is always inside. Non-finite input is never inside.
static func is_in_arc(origin: Vector3, aim_yaw: float, target: Vector3, range_m: float, arc_angle_deg: float) -> bool:
	if not is_finite(arc_angle_deg) or arc_angle_deg < 0.0:
		return false
	return ZombiePerception.can_see(origin, aim_yaw, target, range_m, deg_to_rad(arc_angle_deg) * HALF)


## Id of the nearest candidate inside the arc ("" = none). `candidate_ids`
## and `candidate_positions` are parallel lists; equal distances resolve to
## the smaller id, independent of the list order.
static func pick_target(origin: Vector3, aim_yaw: float, range_m: float, arc_angle_deg: float, candidate_ids: PackedStringArray, candidate_positions: PackedVector3Array) -> String:
	if candidate_ids.size() != candidate_positions.size():
		return NO_TARGET
	var best_id: String = NO_TARGET
	var best_distance: float = INF
	for index: int in range(candidate_ids.size()):
		var position: Vector3 = candidate_positions[index]
		if not is_in_arc(origin, aim_yaw, position, range_m, arc_angle_deg):
			continue
		var distance: float = ZombiePerception.flat_distance(origin, position)
		if distance < best_distance or (distance == best_distance and candidate_ids[index] < best_id):
			best_distance = distance
			best_id = candidate_ids[index]
	return best_id


## Damage of one hit: weapon base damage x handling factor (arm/hand
## wounds) x random factor. Invalid or negative factors give 0 (no damage).
static func damage(base_damage: float, handling_multiplier: float, roll: float) -> float:
	if not is_finite(base_damage) or not is_finite(handling_multiplier) or not is_finite(roll):
		return NO_DAMAGE
	if base_damage <= 0.0 or handling_multiplier <= 0.0 or roll <= 0.0:
		return NO_DAMAGE
	return base_damage * handling_multiplier * roll
