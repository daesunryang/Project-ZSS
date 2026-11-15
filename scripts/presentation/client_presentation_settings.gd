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
@export var death_message: String = "사망했습니다. 이 캐릭터는 끝났습니다. 소지품은 죽은 자리에 남고, 잠시 뒤 새 캐릭터를 만들어 다시 시작합니다."

## Use keys (P2-T3, P2-T6, P2-T7; docs/15 P2-125, P2-144): each asks the server to
## use the first item of its kind in the mirrored inventory. `consume_key` is
## the food key (it was the only use key before P2-T6).
@export var consume_key: Key = KEY_F
@export var drink_key: Key = KEY_G
@export var bandage_key: Key = KEY_B
@export var cure_key: Key = KEY_V
## Local flood guard between two use requests of any kind (the server has
## its own).
@export_range(0.01, 5.0) var consume_min_interval_sec: float = 0.25
@export_range(0.1, 10.0) var consume_result_duration_sec: float = 2.0
## Item kinds listed in the HUD inventory summary; the rest is counted.
@export_range(1, 50) var hud_inventory_line_count: int = 6

## Rest (P2-T8, docs/15 P2-155): the key asks the server to lie down, or to
## get up when the mirror says the local player is lying.
@export var rest_key: Key = KEY_R
## Local flood guard between two rest requests (the server has its own).
@export_range(0.01, 5.0) var rest_min_interval_sec: float = 0.5
## How far a resting player's capsule is tilted (PI / 2 = lying flat).
@export_range(0.0, PI) var rest_tilt_rad: float = PI * 0.5

## Prone (P2-T11, docs/15 P2-194): the key asks the server to lie prone, or
## to stand up when the mirror says the local player is prone. Requests share
## the flood guard interval of the rest key.
@export var prone_key: Key = KEY_C
## How far a prone player's capsule leans forward. Less than PI / 2, so it
## is told apart from a sleeper, which lies flat on its back.
@export_range(0.0, PI) var prone_tilt_rad: float = 1.25

## Treating another player (P2-T12, docs/15 P2-199): holding this key while
## pressing the bandage or the cure key asks the server to use the item on
## the player the camera looks at instead of on oneself.
@export var treat_other_modifier_key: Key = KEY_SHIFT
## Which player that is: the nearest other living player within this
## distance and this half angle around the camera direction, in the mirror.
## Only a suggestion: the server checks its own positions and range.
@export_range(0.1, 50.0) var treat_target_range_m: float = 2.5
@export_range(1.0, 180.0) var treat_target_half_angle_deg: float = 60.0

## Handing an item over (P2-T14, docs/15 P2-211): holding this key while
## pressing a use key (food, drink, bandage, cure) asks the server to move
## the first item of that kind into the inventory of the player the camera
## looks at (the same candidate as for treat_other_modifier_key), instead of
## using it. When both modifiers are held, handing over wins.
@export var hand_over_modifier_key: Key = KEY_CTRL
## Units one key press asks to hand over (never more than the mirrored stack
## holds). The server decides whether that many can be handed over.
@export_range(1, 10000) var hand_over_quantity: int = 1

## Name tag above a player's capsule (P2-T9, docs/15 P2-170): a billboard
## Label3D. Distance above the top of the capsule, world size of one font
## pixel, font size, and the colours of the local player's name, other
## players' names and the name of a dead character.
@export_range(0.0, 5.0) var name_tag_margin_m: float = 0.25
@export_range(0.0001, 0.1) var name_tag_pixel_size: float = 0.006
@export_range(1, 256) var name_tag_font_size: int = 40
@export var name_tag_local_color: Color = Color(0.55, 0.95, 1.0, 1.0)
@export var name_tag_remote_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var name_tag_dead_color: Color = Color(0.6, 0.6, 0.6, 1.0)


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
	if consume_key == KEY_NONE:
		errors.append("consume_key must not be KEY_NONE")
	if consume_min_interval_sec <= 0.0:
		errors.append("consume_min_interval_sec must be > 0")
	if consume_result_duration_sec <= 0.0:
		errors.append("consume_result_duration_sec must be > 0")
	if hud_inventory_line_count <= 0:
		errors.append("hud_inventory_line_count must be > 0")
	var other_use_keys: Dictionary[String, Key] = {"drink_key": drink_key, "bandage_key": bandage_key, "cure_key": cure_key}
	for key_name: String in other_use_keys:
		if other_use_keys[key_name] == KEY_NONE:
			errors.append("%s must not be KEY_NONE" % key_name)
	if rest_key == KEY_NONE:
		errors.append("rest_key must not be KEY_NONE")
	if rest_min_interval_sec <= 0.0:
		errors.append("rest_min_interval_sec must be > 0")
	if rest_tilt_rad <= 0.0 or rest_tilt_rad > PI:
		errors.append("rest_tilt_rad must be within (0, PI]")
	if name_tag_margin_m < 0.0 or name_tag_pixel_size <= 0.0 or name_tag_font_size < 1:
		errors.append("name tag margin must be >= 0, pixel size > 0 and font size >= 1")
	if prone_key == KEY_NONE:
		errors.append("prone_key must not be KEY_NONE")
	if prone_tilt_rad <= 0.0 or prone_tilt_rad > PI:
		errors.append("prone_tilt_rad must be within (0, PI]")
	if treat_other_modifier_key == KEY_NONE:
		errors.append("treat_other_modifier_key must not be KEY_NONE")
	if treat_target_range_m <= 0.0:
		errors.append("treat_target_range_m must be > 0")
	if treat_target_half_angle_deg <= 0.0 or treat_target_half_angle_deg > 180.0:
		errors.append("treat_target_half_angle_deg must be within (0, 180]")
	if hand_over_modifier_key == KEY_NONE:
		errors.append("hand_over_modifier_key must not be KEY_NONE")
	if hand_over_quantity < 1:
		errors.append("hand_over_quantity must be >= 1")
	if not _are_distinct([consume_key, drink_key, bandage_key, cure_key, rest_key, prone_key, treat_other_modifier_key, hand_over_modifier_key]):
		errors.append("use keys (consume, drink, bandage, cure), the rest key, the prone key, the treat-other modifier and the hand-over modifier must be different keys")
	return errors


## True when no key appears twice in `keys` (unset keys are not compared).
static func _are_distinct(keys: Array[Key]) -> bool:
	var seen: Dictionary[Key, bool] = {}
	for key: Key in keys:
		if key == KEY_NONE:
			continue
		if seen.has(key):
			return false
		seen[key] = true
	return true


static func load_or_default(path: String = DEFAULT_PATH) -> ClientPresentationSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is ClientPresentationSettings:
		return loaded as ClientPresentationSettings
	GameLogger.warning("config", "client presentation settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return ClientPresentationSettings.new()
