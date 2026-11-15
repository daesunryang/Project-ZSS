class_name CameraSettings
extends Resource
## Client-only camera, input and placeholder presentation tuning.
## Every product-facing value is PROVISIONAL (docs/15 §7).

const DEFAULT_PATH: String = "res://data/tuning/camera_settings.tres"

@export_range(0.0001, 0.1) var mouse_sensitivity_rad_per_pixel: float = 0.003
@export_range(0.1, 100.0) var camera_distance_m: float = 6.0
@export_range(0.0, 10.0) var target_height_m: float = 1.5
@export_range(-1.55, 1.55) var initial_pitch_rad: float = -0.35
@export_range(-1.55, 1.55) var min_pitch_rad: float = -1.20
@export_range(-1.55, 1.55) var max_pitch_rad: float = 0.20

@export_range(0.0, 0.99) var input_deadzone: float = 0.10
@export var move_forward_key: Key = KEY_W
@export var move_backward_key: Key = KEY_S
@export var move_left_key: Key = KEY_A
@export var move_right_key: Key = KEY_D
@export var pickup_key: Key = KEY_E

## Must stay below the server's 0.5 s no-input timeout (docs/15 P1-8).
@export_range(0.01, 0.25) var move_resend_interval_sec: float = 0.20
@export_range(0.0001, 0.5) var direction_change_epsilon: float = 0.01
@export_range(0.0001, 0.5) var yaw_change_epsilon_rad: float = 0.01

@export_range(0.1, 5.0) var capsule_radius_m: float = 0.40
@export_range(0.2, 10.0) var capsule_height_m: float = 1.80
@export var local_player_color: Color = Color(0.20, 0.75, 1.0, 1.0)
@export var remote_player_color: Color = Color(1.0, 0.45, 0.25, 1.0)


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if mouse_sensitivity_rad_per_pixel <= 0.0:
		errors.append("mouse_sensitivity_rad_per_pixel must be > 0")
	if camera_distance_m <= 0.0 or target_height_m < 0.0:
		errors.append("camera distance must be > 0 and target height must be >= 0")
	if min_pitch_rad > max_pitch_rad or initial_pitch_rad < min_pitch_rad or initial_pitch_rad > max_pitch_rad:
		errors.append("pitch range must contain initial_pitch_rad")
	if input_deadzone < 0.0 or input_deadzone >= 1.0:
		errors.append("input_deadzone must be within [0, 1)")
	if move_resend_interval_sec <= 0.0 or move_resend_interval_sec > 0.25:
		errors.append("move_resend_interval_sec must be within (0, 0.25]")
	if direction_change_epsilon <= 0.0 or yaw_change_epsilon_rad <= 0.0:
		errors.append("intent change epsilons must be > 0")
	if capsule_radius_m <= 0.0 or capsule_height_m < capsule_radius_m * 2.0:
		errors.append("capsule height must be at least twice its radius")
	for key: Key in [move_forward_key, move_backward_key, move_left_key, move_right_key, pickup_key]:
		if key == KEY_NONE:
			errors.append("input keys must not be KEY_NONE")
			break
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> CameraSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is CameraSettings:
		return loaded as CameraSettings
	GameLogger.warning("config", "camera settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return CameraSettings.new()
