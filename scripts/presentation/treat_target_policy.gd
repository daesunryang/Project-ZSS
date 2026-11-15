class_name TreatTargetPolicy
extends RefCounted
## Pure client-side choice of whom a "use on another player" key means
## (P2-T12, docs/09 §14.27): the nearest other player in the direction the
## camera looks, within reach, in the mirrored positions. It only picks a
## player id to send; whether that player can be treated (alive, in the
## world, close enough on the server) is decided by the server.
##
## Everything is on the XZ plane. Yaw convention as everywhere else: yaw 0
## faces -Z and the forward vector is (-sin(yaw), 0, -cos(yaw)).

## Returned when there is nobody to treat.
const NO_TARGET: String = ""
## Below this distance a player is "on the same spot": reachable whatever
## the facing.
const TOUCH_DISTANCE_M: float = 0.001


## Id of the nearest player other than `local_player_id` within `range_m`
## and within `half_angle_rad` around `facing_yaw`, seen from the local
## player's mirrored position, or NO_TARGET. `players` is the position
## mirror ({player_id: {"position": Vector3, ...}}); `excluded_ids` are
## players that cannot be treated (the dead). Equal distances resolve to the
## smaller id. Malformed rows are skipped; invalid arguments give NO_TARGET.
static func pick_target(local_player_id: String, players: Dictionary, excluded_ids: PackedStringArray, facing_yaw: float, range_m: float, half_angle_rad: float) -> String:
	if local_player_id.is_empty() or not is_finite(facing_yaw) or not is_finite(range_m) or not is_finite(half_angle_rad):
		return NO_TARGET
	if range_m <= 0.0 or half_angle_rad < 0.0:
		return NO_TARGET
	var origin: Variant = _position_of(players.get(local_player_id, null))
	if origin == null:
		return NO_TARGET
	var forward: Vector2 = Vector2(-sin(facing_yaw), -cos(facing_yaw))
	var best_id: String = NO_TARGET
	var best_distance: float = INF
	for key: Variant in players:
		if typeof(key) != TYPE_STRING or key == local_player_id or excluded_ids.has(key):
			continue
		var position: Variant = _position_of(players[key])
		if position == null:
			continue
		var offset: Vector2 = Vector2((position as Vector3).x - (origin as Vector3).x, (position as Vector3).z - (origin as Vector3).z)
		var distance: float = offset.length()
		if distance > range_m:
			continue
		if distance > TOUCH_DISTANCE_M and acos(clampf(offset.dot(forward) / distance, -1.0, 1.0)) > half_angle_rad:
			continue
		if distance < best_distance or (distance == best_distance and str(key) < best_id):
			best_distance = distance
			best_id = key
	return best_id


## The finite Vector3 position of a mirror row, or null.
static func _position_of(row: Variant) -> Variant:
	if typeof(row) != TYPE_DICTIONARY:
		return null
	var position: Variant = (row as Dictionary).get("position", null)
	if typeof(position) != TYPE_VECTOR3 or not (position as Vector3).is_finite():
		return null
	return position
