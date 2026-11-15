class_name ClientPresentationSettings
extends Resource
## Client-only placeholder visuals, HUD and attack-input tuning.
## Product-facing values are PROVISIONAL (docs/15 §8).

const DEFAULT_PATH: String = "res://data/tuning/client_presentation_settings.tres"

@export_range(0.1, 5.0) var zombie_capsule_radius_m: float = 0.38
@export_range(0.2, 10.0) var zombie_capsule_height_m: float = 1.70
@export_range(0.0, PI) var dead_tilt_rad: float = PI * 0.5
@export var dead_player_color: Color = Color(0.25, 0.28, 0.32, 1.0)

@export var zombie_idle_color: Color = Color(0.30, 0.68, 0.30, 1.0)
@export var zombie_investigate_color: Color = Color(0.78, 0.72, 0.22, 1.0)
@export var zombie_chase_color: Color = Color(0.92, 0.46, 0.12, 1.0)
@export var zombie_attack_color: Color = Color(0.92, 0.12, 0.10, 1.0)
@export var zombie_search_color: Color = Color(0.55, 0.32, 0.70, 1.0)
@export var zombie_dormant_color: Color = Color(0.30, 0.42, 0.30, 1.0)
@export var zombie_dead_color: Color = Color(0.12, 0.16, 0.12, 1.0)

@export var attack_mouse_button: MouseButton = MOUSE_BUTTON_LEFT
@export_range(0.01, 1.0) var attack_min_interval_sec: float = 0.15
@export_range(0.1, 10.0) var attack_result_duration_sec: float = 2.0
@export_range(1, 20) var hud_event_line_count: int = 5
@export var death_message: String = "사망했습니다. 서버의 부활을 기다리는 중입니다."


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if zombie_capsule_radius_m <= 0.0 or zombie_capsule_height_m < zombie_capsule_radius_m * 2.0:
		errors.append("zombie capsule height must be at least twice its radius")
	if dead_tilt_rad <= 0.0 or dead_tilt_rad > PI:
		errors.append("dead_tilt_rad must be within (0, PI]")
	if attack_mouse_button == MOUSE_BUTTON_NONE:
		errors.append("attack_mouse_button must not be MOUSE_BUTTON_NONE")
	if attack_min_interval_sec <= 0.0:
		errors.append("attack_min_interval_sec must be > 0")
	if attack_result_duration_sec <= 0.0:
		errors.append("attack_result_duration_sec must be > 0")
	if hud_event_line_count <= 0:
		errors.append("hud_event_line_count must be > 0")
	if death_message.is_empty():
		errors.append("death_message must not be empty")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> ClientPresentationSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is ClientPresentationSettings:
		return loaded as ClientPresentationSettings
	GameLogger.warning("config", "client presentation settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return ClientPresentationSettings.new()
