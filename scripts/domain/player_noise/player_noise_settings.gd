class_name PlayerNoiseSettings
extends Resource
## Player movement noise tuning (docs/02 §5.3). Defaults in
## `res://data/tuning/player_noise_settings.tres`. Every value is
## PROVISIONAL (docs/15 §6.5 P2-48..P2-50) and must be balanced by
## play-testing. Speeds are metres per real second, the unit in which the
## server integrates player movement.

const DEFAULT_PATH: String = "res://data/tuning/player_noise_settings.tres"

## Distance walked between two footstep noises, metres (XZ plane).
@export_range(0.1, 1000.0) var stride_length_m: float = 2.0
## NoiseService loudness of one footstep. 0 = footsteps are disabled.
@export_range(0.0, 100000.0) var footstep_loudness: float = 6.0
## Loudness of a server-authorized running footstep.
@export_range(0.0, 100000.0) var sprint_footstep_loudness: float = 13.0
## NoiseSettings.frequency_profiles entry used for footsteps.
@export var footstep_frequency_profile: String = "broadband"
## Movement slower than this is silent and does not add to the stride.
@export_range(0.0, 1000.0) var min_speed_mps: float = 0.5
## A position change faster than this is a teleport (respawn, admin move),
## not walking: it makes no footstep and restarts the stride.
@export_range(0.001, 100000.0) var teleport_speed_mps: float = 15.0
## Footsteps emitted per player in one server tick; extra ones are dropped
## (only reached with very long ticks).
@export_range(1, 1000) var max_footsteps_per_tick: int = 4


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(stride_length_m) or stride_length_m <= 0.0:
		errors.append("player_noise stride_length_m must be > 0")
	if not is_finite(footstep_loudness) or footstep_loudness < 0.0:
		errors.append("player_noise footstep_loudness must be >= 0")
	if not is_finite(sprint_footstep_loudness) or sprint_footstep_loudness < 0.0:
		errors.append("player_noise sprint_footstep_loudness must be >= 0")
	if not is_finite(min_speed_mps) or min_speed_mps < 0.0:
		errors.append("player_noise min_speed_mps must be >= 0")
	if not is_finite(teleport_speed_mps) or teleport_speed_mps <= 0.0 or teleport_speed_mps < min_speed_mps:
		errors.append("player_noise teleport_speed_mps must be > 0 and >= min_speed_mps")
	if max_footsteps_per_tick < 1:
		errors.append("player_noise max_footsteps_per_tick must be >= 1")
	if footstep_frequency_profile.is_empty():
		errors.append("player_noise footstep_frequency_profile must not be empty")
	return errors


## Checks the footstep noise against what the noise system accepts.
func validate_against(noise: NoiseSettings) -> PackedStringArray:
	var errors: PackedStringArray = []
	if footstep_loudness > noise.max_loudness:
		errors.append("player_noise footstep_loudness exceeds noise max_loudness")
	if sprint_footstep_loudness > noise.max_loudness:
		errors.append("player_noise sprint_footstep_loudness exceeds noise max_loudness")
	if (footstep_loudness > 0.0 or sprint_footstep_loudness > 0.0) and not noise.is_valid_profile(
		footstep_frequency_profile
	):
		errors.append("player_noise footstep_frequency_profile %s is unknown" % footstep_frequency_profile)
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> PlayerNoiseSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is PlayerNoiseSettings:
		return loaded as PlayerNoiseSettings
	GameLogger.warning("config", "player noise settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return PlayerNoiseSettings.new()
