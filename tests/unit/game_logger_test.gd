extends TestCase
## GameLogger: formatting, level filtering, redaction.

const FIXED_TIME: String = "2026-01-01T00:00:00Z"

var _saved_level: GameLogger.Level = GameLogger.Level.INFO


func before_each() -> void:
	_saved_level = GameLogger.get_min_level()
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)
	GameLogger.set_min_level(_saved_level)


func test_format_without_context() -> void:
	var line: String = GameLogger.format_line(GameLogger.Level.INFO, "world", "ready", {}, FIXED_TIME)
	assert_eq(line, "2026-01-01T00:00:00Z [INFO] [world] ready")


func test_format_sorts_context_keys() -> void:
	var context: Dictionary = {"world_id": "w1", "entity_id": "e7", "peer_id": 3, "request_id": "r9"}
	var line: String = GameLogger.format_line(GameLogger.Level.ERROR, "inventory", "rejected", context, FIXED_TIME)
	assert_eq(line, "2026-01-01T00:00:00Z [ERROR] [inventory] rejected | entity_id=e7 peer_id=3 request_id=r9 world_id=w1")


func test_sensitive_keys_are_redacted() -> void:
	var line: String = GameLogger.format_line(GameLogger.Level.INFO, "net", "login", {"auth_token": "abc123", "Password": "hunter2"}, FIXED_TIME)
	assert_not_contains(line, "abc123")
	assert_not_contains(line, "hunter2")
	assert_contains(line, "auth_token=" + GameLogger.REDACTED_VALUE)


func test_level_filter_drops_lower_levels() -> void:
	GameLogger.set_min_level(GameLogger.Level.WARNING)
	GameLogger.info("test", "hidden")
	GameLogger.warning("test", "shown")
	GameLogger.fatal("test", "also shown")
	var lines: PackedStringArray = GameLogger.captured_lines()
	assert_eq(lines.size(), 2)
	assert_contains(lines[0], "[WARNING] [test] shown")
	assert_contains(lines[1], "[FATAL]")


func test_parse_level() -> void:
	assert_eq(GameLogger.parse_level("debug"), GameLogger.Level.DEBUG)
	assert_eq(GameLogger.parse_level(" FATAL "), GameLogger.Level.FATAL)
	assert_eq(GameLogger.parse_level("verbose"), -1)
	assert_eq(GameLogger.LEVEL_NAMES.size(), GameLogger.Level.size())
