extends Node
## Entry point (scenes/main/main.tscn). Parses launch options, applies
## settings, then hands off to GameBootstrap. Owns process exit codes.

## Exit codes are part of the launch contract used by tools/*.sh.
const EXIT_OK: int = 0
const EXIT_BOOTSTRAP_FAILED: int = 1
const EXIT_BAD_ARGUMENTS: int = 2

var _config: LaunchConfig = null
var _bootstrap: GameBootstrap = null
var _frames_run: int = 0
var _seconds_run: float = 0.0
var _quitting: bool = false


func _ready() -> void:
	var settings: AppSettings = AppSettings.load_or_default()
	_config = LaunchConfig.parse(OS.get_cmdline_user_args(), OS.has_feature("dedicated_server"))

	var level_name: String = _config.log_level_override if not _config.log_level_override.is_empty() else settings.log_level
	var level: int = GameLogger.parse_level(level_name)
	GameLogger.set_min_level(level as GameLogger.Level if level >= 0 else GameLogger.Level.INFO)

	GameLogger.info("main", "starting", {"build": BuildInfo.summary(), "role": _config.role_name()})
	if not BuildInfo.is_supported_engine():
		GameLogger.warning("main", "engine version differs from pinned 4.7.2.stable", {"engine": BuildInfo.engine_version_string()})

	var setting_errors: PackedStringArray = settings.validate()
	if not setting_errors.is_empty():
		GameLogger.fatal("main", "invalid settings", {"errors": ", ".join(setting_errors), "operation": "validate_settings"})
		_quit(EXIT_BOOTSTRAP_FAILED)
		return
	if not _config.errors.is_empty():
		GameLogger.fatal("main", "invalid launch arguments", {"errors": "; ".join(_config.errors), "operation": "parse_args"})
		_quit(EXIT_BAD_ARGUMENTS)
		return

	_bootstrap = GameBootstrap.new()
	_bootstrap.name = "GameBootstrap"
	add_child(_bootstrap)
	var result: Error = _bootstrap.start(_config, settings)
	if result != OK:
		GameLogger.fatal("main", "bootstrap failed", {"error": error_string(result), "operation": "bootstrap_start"})
		_quit(EXIT_BOOTSTRAP_FAILED)


func _process(delta: float) -> void:
	if _quitting or _config == null:
		return
	_frames_run += 1
	_seconds_run += delta
	if _config.run_frames != LaunchConfig.RUN_FOREVER and _frames_run >= _config.run_frames:
		GameLogger.info("main", "run frame limit reached, shutting down", {"frames": _frames_run, "role": _config.role_name()})
		_quit(EXIT_OK)
	elif _config.run_seconds > 0.0 and _seconds_run >= _config.run_seconds:
		GameLogger.info("main", "run time limit reached, shutting down", {"seconds": snappedf(_seconds_run, 0.01), "role": _config.role_name()})
		_quit(EXIT_OK)


func _quit(code: int) -> void:
	_quitting = true
	if code == EXIT_OK:
		GameLogger.info("main", "shutdown", {"exit_code": code})
	get_tree().quit(code)
