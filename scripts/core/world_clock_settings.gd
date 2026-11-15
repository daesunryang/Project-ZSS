class_name WorldClockSettings
extends Resource
## WorldClock tuning. Defaults in `res://data/tuning/world_clock_settings.tres`.
## PROVISIONAL (docs/15 §6 P2-1): the real/world time scale is undecided.

const DEFAULT_PATH: String = "res://data/tuning/world_clock_settings.tres"

## World seconds per real second.
@export_range(0.01, 1000.0) var time_scale: float = 1.0
## Stop world time while no player is online.
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
