class_name InputIntentMath
extends RefCounted
## Pure conversion from sampled controls to server-contract world XZ intent.


## Applies a radial deadzone and limits diagonal input to unit length.
static func sample_to_local_intent(sample: Vector2, deadzone: float) -> Vector2:
	if not sample.is_finite() or sample.length() <= deadzone:
		return Vector2.ZERO
	return sample.limit_length(1.0)


## Converts local (right, forward) input to world (X, Z) for camera yaw.
static func camera_relative_direction(local_intent: Vector2, yaw: float) -> Vector2:
	var right: Vector2 = Vector2(cos(yaw), -sin(yaw))
	var forward: Vector2 = Vector2(-sin(yaw), -cos(yaw))
	return (right * local_intent.x + forward * local_intent.y).limit_length(1.0)


## Nearest item id by client-mirrored position within `max_distance_m` (the
## range included; unlimited by default), or "" when there is none. A
## suggestion only: the server still validates the range with its own
## positions.
static func nearest_world_item_id(origin: Vector3, world_items: Dictionary[String, Dictionary], max_distance_m: float = INF) -> String:
	var nearest_id: String = ""
	var nearest_distance_squared: float = INF
	if is_nan(max_distance_m) or max_distance_m < 0.0:
		return nearest_id
	var limit_squared: float = max_distance_m * max_distance_m
	for item_id: String in world_items:
		var position_value: Variant = world_items[item_id].get("position", null)
		if typeof(position_value) != TYPE_VECTOR3:
			continue
		var distance_squared: float = origin.distance_squared_to(position_value as Vector3)
		if distance_squared > limit_squared:
			continue
		if distance_squared < nearest_distance_squared:
			nearest_distance_squared = distance_squared
			nearest_id = item_id
	return nearest_id
