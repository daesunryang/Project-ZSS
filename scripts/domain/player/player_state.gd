class_name PlayerState
extends RefCounted
## Persistent player state (docs/14 §3 PlayerState, Phase 1 subset).
##
## Phase 1 fields only: identity, position, facing, inventory. health /
## injuries / needs / infection / shelter_membership arrive in Phase 2+.
## `peer_id` is runtime connection info and is never saved.

## v2 (Phase 2): the player file may carry "systems" fragments written by
## ServerWorld; PlayerState itself ignores that key.
const SCHEMA_VERSION: int = 2
const PLAYER_ID_PATTERN: String = "^player_[0-9]+$"

var player_id: String = ""
## PROVISIONAL client-chosen identity key used to find the same player on
## reconnect (no authentication yet, docs/15 P1-1).
var player_key: String = ""
var position: Vector3 = Vector3.ZERO
## Facing around the Y axis, radians.
var yaw: float = 0.0
var inventory_id: String = ""
## Real-time (UTC unix seconds) of the last save. Not world time (docs/14 §2).
var last_saved_at_utc: int = 0


func to_dict() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"player_id": player_id,
		"player_key": player_key,
		"position": [position.x, position.y, position.z],
		"yaw": yaw,
		"inventory_id": inventory_id,
		"last_saved_at_utc": last_saved_at_utc,
	}


## Returns null (and logs) when `data` is malformed.
static func from_dict(data: Dictionary) -> PlayerState:
	var errors: PackedStringArray = validate_dict(data)
	if not errors.is_empty():
		GameLogger.error("player", "invalid player data", {"player_id": str(data.get("player_id", "")), "errors": "; ".join(errors), "operation": "player_from_dict"})
		return null
	var state: PlayerState = PlayerState.new()
	state.player_id = str(data["player_id"])
	state.player_key = str(data["player_key"])
	var p: Array = data["position"]
	state.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	state.yaw = float(data["yaw"])
	state.inventory_id = str(data["inventory_id"])
	state.last_saved_at_utc = int(data.get("last_saved_at_utc", 0))
	return state


static func validate_dict(data: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	for key: String in ["schema_version", "player_id", "player_key", "position", "yaw", "inventory_id"]:
		if not data.has(key):
			errors.append("missing " + key)
	if not errors.is_empty():
		return errors
	if not ItemInstance.is_integer_value(data["schema_version"]) or int(data["schema_version"]) != SCHEMA_VERSION:
		errors.append("unsupported schema_version")
	if typeof(data["player_id"]) != TYPE_STRING or not is_valid_player_id(str(data["player_id"])):
		errors.append("invalid player_id")
	if typeof(data["player_key"]) != TYPE_STRING or str(data["player_key"]).is_empty():
		errors.append("invalid player_key")
	var p: Variant = data["position"]
	if typeof(p) != TYPE_ARRAY or (p as Array).size() != 3:
		errors.append("position must be [x, y, z]")
	else:
		for component: Variant in (p as Array):
			if not (typeof(component) == TYPE_FLOAT or typeof(component) == TYPE_INT) or not is_finite(float(component)):
				errors.append("position components must be finite numbers")
				break
	if not (typeof(data["yaw"]) == TYPE_FLOAT or typeof(data["yaw"]) == TYPE_INT) or not is_finite(float(data["yaw"])):
		errors.append("yaw must be a finite number")
	if typeof(data["inventory_id"]) != TYPE_STRING or str(data["inventory_id"]).is_empty():
		errors.append("invalid inventory_id")
	return errors


static func is_valid_player_id(id: String) -> bool:
	return RegEx.create_from_string(PLAYER_ID_PATTERN).search(id) != null
