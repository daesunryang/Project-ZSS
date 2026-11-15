class_name IntentValidator
extends RefCounted
## Pure validation of untrusted client RPC arguments (CLAUDE.md §5,
## docs/08 §5). Each function returns "" when valid, otherwise a stable
## reason code. RPC handlers declare Variant parameters and call these, so
## wrongly typed input is rejected instead of raising script errors.

const REASON_BAD_TYPE: String = "bad_type"
const REASON_PROTOCOL_MISMATCH: String = "protocol_mismatch"
const REASON_BAD_PLAYER_KEY: String = "bad_player_key"
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
