class_name GameLogger
extends RefCounted
## Structured logger (docs/09 §12).
##
## Levels: DEBUG, INFO, WARNING, ERROR, FATAL.
## Line format (stable, greppable):
##   <utc-iso8601> [LEVEL] [subsystem] message | key=value key=value
## Context keys such as world_id, peer_id, entity_id, request_id are passed in
## `context` and printed in sorted order. Keys listed in REDACTED_KEYS are
## never printed (no credentials in logs).
##
## Static state is limited to the minimum level and an optional capture sink
## used by tests; there is no Autoload.

enum Level { DEBUG = 0, INFO = 1, WARNING = 2, ERROR = 3, FATAL = 4 }

const LEVEL_NAMES: PackedStringArray = ["DEBUG", "INFO", "WARNING", "ERROR", "FATAL"]
## Context keys that must never be written to logs.
const REDACTED_KEYS: PackedStringArray = ["password", "token", "secret", "auth", "credential"]
const REDACTED_VALUE: String = "<redacted>"

static var _min_level: Level = Level.INFO
## When true, formatted lines are appended to `_captured` instead of printed.
static var _capture_enabled: bool = false
static var _captured: PackedStringArray = []


## Sets the minimum level that will be emitted.
static func set_min_level(level: Level) -> void:
	_min_level = level


static func get_min_level() -> Level:
	return _min_level


## Parses a level name (case-insensitive). Returns -1 when unknown.
static func parse_level(name: String) -> int:
	return LEVEL_NAMES.find(name.strip_edges().to_upper())


static func level_name(level: Level) -> String:
	return LEVEL_NAMES[level]


## Redirects output into an in-memory array (for tests). Pass `false` to restore printing.
static func set_capture(enabled: bool) -> void:
	_capture_enabled = enabled
	_captured = PackedStringArray()


## Lines captured since `set_capture(true)`.
static func captured_lines() -> PackedStringArray:
	return _captured


static func debug(subsystem: String, message: String, context: Dictionary = {}) -> void:
	write(Level.DEBUG, subsystem, message, context)


static func info(subsystem: String, message: String, context: Dictionary = {}) -> void:
	write(Level.INFO, subsystem, message, context)


static func warning(subsystem: String, message: String, context: Dictionary = {}) -> void:
	write(Level.WARNING, subsystem, message, context)


static func error(subsystem: String, message: String, context: Dictionary = {}) -> void:
	write(Level.ERROR, subsystem, message, context)


static func fatal(subsystem: String, message: String, context: Dictionary = {}) -> void:
	write(Level.FATAL, subsystem, message, context)


## Emits a line if `level` passes the filter. ERROR/FATAL go to stderr.
static func write(level: Level, subsystem: String, message: String, context: Dictionary = {}) -> void:
	if level < _min_level:
		return
	var line: String = format_line(level, subsystem, message, context, _utc_timestamp())
	if _capture_enabled:
		_captured.append(line)
		return
	if level >= Level.ERROR:
		printerr(line)
	else:
		print(line)


## Pure formatter (no I/O) so it can be unit tested with a fixed timestamp.
static func format_line(level: Level, subsystem: String, message: String, context: Dictionary, timestamp: String) -> String:
	var line: String = "%s [%s] [%s] %s" % [timestamp, LEVEL_NAMES[level], subsystem, message]
	if context.is_empty():
		return line
	var keys: Array = context.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	var parts: PackedStringArray = []
	for key: Variant in keys:
		var key_text: String = str(key)
		var value_text: String = REDACTED_VALUE if _is_redacted(key_text) else str(context[key])
		parts.append("%s=%s" % [key_text, value_text])
	return "%s | %s" % [line, " ".join(parts)]


static func _is_redacted(key: String) -> bool:
	var lowered: String = key.to_lower()
	for marker: String in REDACTED_KEYS:
		if lowered.contains(marker):
			return true
	return false


static func _utc_timestamp() -> String:
	return Time.get_datetime_string_from_system(true) + "Z"
