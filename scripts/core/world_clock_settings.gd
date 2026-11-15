class_name WorldClockSettings
extends Resource
## WorldClock tuning. Defaults in `res://data/tuning/world_clock_settings.tres`.
## docs/00 ADR-006 (user decision): one world day per real hour (scale 24).
## The scale applies to calendar time only; action time is always real
## seconds (docs/09 §14.16).

const DEFAULT_PATH: String = "res://data/tuning/world_clock_settings.tres"

## World (calendar) seconds per real second. Action time ignores it.
@export_range(0.01, 1000.0) var time_scale: float = 24.0
## Stop both times while no player is online.
@export var pause_when_empty: bool = true


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if time_scale <= 0.0:
		errors.append("time_scale must be > 0")
	return errors


func create_clock() -> WorldClock:
	return WorldClock.new(time_scale, pause_when_empty)


static func load_or_default(path: String = DEFAULT_PATH) -> WorldClockSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is WorldClockSettings:
		return loaded as WorldClockSettings
	GameLogger.warning("config", "world clock settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return WorldClockSettings.new()
