class_name NoiseSettings
extends Resource
## Noise tuning (docs/02 §5.3). Defaults in
## `res://data/tuning/noise_settings.tres`. Every value is PROVISIONAL
## (docs/15 §6 P2-20..P2-22) and must be balanced by play-testing.
##
## Model: heard intensity =
##   loudness * hearing_multiplier * occlusion * (1 - age / event_lifetime_sec)
##   - distance * distance_attenuation_per_m
## and a noise is audible while intensity >= min_audible_intensity. With the
## default attenuation of 1 per metre, `loudness` is roughly the distance in
## metres at which a fresh noise can still be heard.

const DEFAULT_PATH: String = "res://data/tuning/noise_settings.tres"

## Edge of one spatial hash cell on the XZ plane, metres.
@export_range(1.0, 1000.0) var cell_size_m: float = 16.0
## Upper bound of `loudness` accepted by emit().
@export_range(1.0, 100000.0) var max_loudness: float = 100.0
## Intensity lost per metre between source and listener.
@export_range(0.001, 1000.0) var distance_attenuation_per_m: float = 1.0
## World seconds until a noise has faded completely (linear decay).
@export_range(0.01, 100000.0) var event_lifetime_sec: float = 8.0
## Weakest intensity a listener still notices.
@export_range(0.001, 100000.0) var min_audible_intensity: float = 1.0
## Hearing multipliers above this are clamped (bounds the search radius).
@export_range(0.01, 100.0) var max_hearing_multiplier: float = 4.0
## Active noise events kept at once; the oldest is evicted beyond this.
@export_range(1, 100000) var max_active_events: int = 256
## Allowed `frequency_profile` names (docs/02 §5.3). They are carried on the
## event; they do not change attenuation yet (docs/15 P2-21).
@export var frequency_profiles: PackedStringArray = ["broadband", "low", "high"]
@export var default_profile: String = "broadband"


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if cell_size_m <= 0.0:
		errors.append("noise cell_size_m must be > 0")
	if max_loudness <= 0.0:
		errors.append("noise max_loudness must be > 0")
	if distance_attenuation_per_m <= 0.0:
		errors.append("noise distance_attenuation_per_m must be > 0")
	if event_lifetime_sec <= 0.0:
		errors.append("noise event_lifetime_sec must be > 0")
	if min_audible_intensity <= 0.0:
		errors.append("noise min_audible_intensity must be > 0")
	if max_hearing_multiplier <= 0.0:
		errors.append("noise max_hearing_multiplier must be > 0")
	if max_active_events < 1:
		errors.append("noise max_active_events must be >= 1")
	if frequency_profiles.is_empty() or not frequency_profiles.has(default_profile):
		errors.append("noise default_profile must be one of frequency_profiles")
	return errors


func is_valid_profile(profile: String) -> bool:
	return frequency_profiles.has(profile)


static func load_or_default(path: String = DEFAULT_PATH) -> NoiseSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NoiseSettings:
		return loaded as NoiseSettings
	GameLogger.warning("config", "noise settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NoiseSettings.new()
