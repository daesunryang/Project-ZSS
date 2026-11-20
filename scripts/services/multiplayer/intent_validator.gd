class_name IntentValidator
extends RefCounted
## Pure validation of untrusted client RPC arguments (CLAUDE.md §5,
## docs/08 §5). Each function returns "" when valid, otherwise a stable
## reason code. RPC handlers declare Variant parameters and call these, so
## wrongly typed input is rejected instead of raising script errors.

const REASON_BAD_TYPE: String = "bad_type"
const REASON_PROTOCOL_MISMATCH: String = "protocol_mismatch"
const REASON_BAD_PLAYER_KEY: String = "bad_player_key"
const REASON_BAD_DIRECTION: String = "bad_direction"
const REASON_BAD_YAW: String = "bad_yaw"
const REASON_BAD_SEQUENCE: String = "bad_sequence"
const REASON_BAD_ITEM_ID: String = "bad_item_id"
const ENTITY_ID_MAX_LENGTH: int = 64
## Upper bound on |yaw| accepted from clients (radians; any facing is
## representable within one turn, larger values are treated as garbage).
const MAX_ABS_YAW: float = TAU
const PLAYER_KEY_PATTERN: String = "^[A-Za-z0-9_-]+$"
const GAME_VERSION_MAX_LENGTH: int = 32


static func validate_join(protocol_version: Variant, game_version: Variant, player_key: Variant, expected_protocol: int, max_key_length: int) -> String:
	if typeof(protocol_version) != TYPE_INT or typeof(game_version) != TYPE_STRING or typeof(player_key) != TYPE_STRING:
		return REASON_BAD_TYPE
	if str(game_version).length() > GAME_VERSION_MAX_LENGTH:
		return REASON_BAD_TYPE
	if int(protocol_version) != expected_protocol:
		return REASON_PROTOCOL_MISMATCH
	var key: String = str(player_key)
	if key.is_empty() or key.length() > max_key_length:
		return REASON_BAD_PLAYER_KEY
	if RegEx.create_from_string(PLAYER_KEY_PATTERN).search(key) == null:
		return REASON_BAD_PLAYER_KEY
	return ""


static func validate_move(sequence: Variant, direction: Variant, yaw: Variant, sprinting: Variant = false) -> String:
	if typeof(sequence) != TYPE_INT or typeof(direction) != TYPE_VECTOR2 or typeof(yaw) != TYPE_FLOAT or typeof(sprinting) != TYPE_BOOL:
		return REASON_BAD_TYPE
	if int(sequence) < 0:
		return REASON_BAD_SEQUENCE
	if not MovementRules.is_valid_direction(direction as Vector2):
		return REASON_BAD_DIRECTION
	if not is_finite(float(yaw)) or absf(float(yaw)) > MAX_ABS_YAW:
		return REASON_BAD_YAW
	return ""


static func validate_pickup(request_id: Variant, item_instance_id: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(item_instance_id) != TYPE_STRING:
		return REASON_BAD_TYPE
	if int(request_id) < 0:
		return REASON_BAD_SEQUENCE
	var id: String = str(item_instance_id)
	if id.is_empty() or id.length() > ENTITY_ID_MAX_LENGTH:
		return REASON_BAD_ITEM_ID
	return ""
