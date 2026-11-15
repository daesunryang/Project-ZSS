class_name PostureSettings
extends Resource
## Posture and stealth tuning (P2-T11, docs/00 ADR-017, docs/09 §14.26).
## Defaults in `res://data/tuning/posture_settings.tres`. Every value is
## PROVISIONAL (docs/15 §14.2 P2-189..P2-194) and must be balanced by
## play-testing. Speeds are metres per real second and times are real
## seconds (action time, docs/09 §14.16).

const DEFAULT_PATH: String = "res://data/tuning/posture_settings.tres"

@export_group("Visibility")
## Factor on the distance at which a zombie can see the player (1.0 = the
## zombie's full sight range, 0 = never seen). User decision 2026-11-15: a
## moving player is seen best, a sleeping player a little less, a prone
## player least; sleeping gives no stealth like lying prone does.
@export_range(0.0, 1.0) var standing_moving_visibility: float = 1.0
@export_range(0.0, 1.0) var standing_still_visibility: float = 0.9
@export_range(0.0, 1.0) var resting_visibility: float = 0.8
@export_range(0.0, 1.0) var prone_moving_visibility: float = 0.6
@export_range(0.0, 1.0) var prone_still_visibility: float = 0.4
## A player counts as moving when the server moved it at least this fast in
## a tick ...
@export_range(0.0, 1000.0) var moving_min_speed_mps: float = 0.5
## ... and for this long afterwards (zombies decide less often than players
## move, and a brief stop is not hiding).
@export_range(0.0, 1000.0) var moving_memory_sec: float = 0.5

@export_group("Prone")
## Factor on the server movement speed of a prone player.
@export_range(0.0, 1.0) var prone_movement_multiplier: float = 0.35
## Factors on the footsteps of a prone player: loudness of one footstep and
## distance crawled between two of them (PlayerNoiseSettings).
@export_range(0.0, 1.0) var prone_footstep_loudness_multiplier: float = 0.4
@export_range(0.01, 10.0) var prone_footstep_stride_multiplier: float = 0.5
## true: a prone player cannot make a melee attack ("player_prone"); it can
## still pick up, put down and use items.
@export var prone_blocks_attack: bool = true
## Undrained posture events kept for the network layer; oldest are dropped.
@export_range(1, 1000000) var max_pending_events: int = 256


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	for value: float in [standing_moving_visibility, standing_still_visibility, resting_visibility, prone_moving_visibility, prone_still_visibility]:
		if not is_finite(value) or value < 0.0 or value > 1.0:
			errors.append("posture visibility factors must be within [0, 1]")
			break
	# The order the user decided: prone < sleeping < moving.
	if standing_still_visibility > standing_moving_visibility:
		errors.append("posture standing_still_visibility must not exceed standing_moving_visibility")
	if resting_visibility >= standing_moving_visibility:
		errors.append("posture resting_visibility must be below standing_moving_visibility")
	if prone_moving_visibility >= resting_visibility:
		errors.append("posture prone_moving_visibility must be below resting_visibility")
	if prone_still_visibility > prone_moving_visibility:
		errors.append("posture prone_still_visibility must not exceed prone_moving_visibility")
	if not is_finite(moving_min_speed_mps) or moving_min_speed_mps < 0.0 or not is_finite(moving_memory_sec) or moving_memory_sec < 0.0:
		errors.append("posture moving_min_speed_mps and moving_memory_sec must be finite and >= 0")
	if not is_finite(prone_movement_multiplier) or prone_movement_multiplier < 0.0 or prone_movement_multiplier > 1.0:
		errors.append("posture prone_movement_multiplier must be within [0, 1]")
	if not is_finite(prone_footstep_loudness_multiplier) or prone_footstep_loudness_multiplier < 0.0 or prone_footstep_loudness_multiplier > 1.0:
		errors.append("posture prone_footstep_loudness_multiplier must be within [0, 1]")
	if not is_finite(prone_footstep_stride_multiplier) or prone_footstep_stride_multiplier <= 0.0:
		errors.append("posture prone_footstep_stride_multiplier must be > 0")
	if max_pending_events < 1:
		errors.append("posture max_pending_events must be >= 1")
	return errors


## Visibility factor of a player in `posture` that is moving or not.
func visibility(posture: PlayerPosture.Kind, moving: bool) -> float:
	match posture:
		PlayerPosture.Kind.RESTING:
			return resting_visibility
		PlayerPosture.Kind.PRONE:
			return prone_moving_visibility if moving else prone_still_visibility
		_:
			return standing_moving_visibility if moving else standing_still_visibility


static func load_or_default(path: String = DEFAULT_PATH) -> PostureSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is PostureSettings:
		return loaded as PostureSettings
	GameLogger.warning("config", "posture settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return PostureSettings.new()
