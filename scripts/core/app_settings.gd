class_name AppSettings
extends Resource
## Bootstrap-level settings (static definition data, docs/00 ADR-005).
##
## Default values live in `res://data/tuning/app_settings.tres`. Command line
## options (LaunchConfig) override them at runtime without mutating the file.
## Values marked PROVISIONAL are development defaults, not product decisions
## (see docs/15 "Phase 0 부트스트랩 임시 가정").

const DEFAULT_PATH: String = "res://data/tuning/app_settings.tres"

## Minimum log level name: DEBUG, INFO, WARNING, ERROR, FATAL.
@export var log_level: String = "INFO"
## PROVISIONAL: id of the empty development world loaded in Phase 0.
@export var default_world_id: String = "dev_empty_world"


## Returns a list of human readable validation errors (empty when valid).
func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if GameLogger.parse_level(log_level) < 0:
		errors.append("log_level '%s' is not a known level" % log_level)
	if not LaunchConfig.is_valid_world_id(default_world_id):
		errors.append("default_world_id '%s' is invalid" % default_world_id)
	return errors


## Loads settings from `path`. Falls back to built-in defaults on failure and
## reports the problem through the logger.
static func load_or_default(path: String = DEFAULT_PATH) -> AppSettings:
	if ResourceLoader.exists(path):
		var loaded: Resource = ResourceLoader.load(path)
		if loaded is AppSettings:
			return loaded as AppSettings
		GameLogger.error("config", "settings resource has wrong type, using defaults", {"path": path, "operation": "load_settings"})
	else:
		GameLogger.warning("config", "settings resource missing, using defaults", {"path": path, "operation": "load_settings"})
	return AppSettings.new()
