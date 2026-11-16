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
## Shared backdrop and text treatment for the two stacked HUD columns.
@export var hud_panel_color: Color = Color(0.035, 0.045, 0.055, 0.82)
@export_range(0, 32) var hud_panel_padding_px: int = 8
@export_range(0, 32) var hud_panel_corner_radius_px: int = 6
@export_range(0, 32) var hud_stack_separation_px: int = 6
@export_range(0, 16) var hud_text_outline_size_px: int = 4
@export var hud_text_outline_color: Color = Color(0.0, 0.0, 0.0, 0.95)
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

## Inventory cursor and putting items down (P2-T15, docs/00 ADR-021, docs/15
## P2-218..P2-220). The cursor is on one carried stack of the mirrored
## inventory; these keys move it to the previous / next stack (local only,
## nothing is sent).
@export var select_previous_key: Key = KEY_Z
@export var select_next_key: Key = KEY_X
## Asks the server to put `drop_quantity` units of the selected stack down
## where the player stands (never more than the mirrored stack holds).
@export var drop_key: Key = KEY_Q
@export_range(1, 10000) var drop_quantity: int = 1
## Held with the drop key: put the whole selected stack down instead.
@export var drop_stack_modifier_key: Key = KEY_CTRL
## Local flood guard between two drop requests (the server has its own).
@export_range(0.01, 5.0) var drop_min_interval_sec: float = 0.25

## Trade (P2-T16, docs/00 ADR-022, docs/15 P2-243..P2-245). The request key
## asks the player the camera looks at (the candidate of
## treat_other_modifier_key) for a trade.
@export var trade_request_key: Key = KEY_T
## Accepts a request addressed to the local player; in an open session it
## confirms the offers as shown, or takes the confirmation back.
@export var trade_accept_key: Key = KEY_Y
## Declines a request, takes the own request back, or cancels the session.
@export var trade_decline_key: Key = KEY_N
## In an open session: one press puts `trade_offer_step` more / fewer units
## of the stack under the inventory cursor into the own offer.
@export var trade_offer_add_key: Key = KEY_O
@export var trade_offer_remove_key: Key = KEY_P
@export_range(1, 10000) var trade_offer_step: int = 1
## Local flood guard between two trade requests of any kind (the server has
## its own).
@export_range(0.01, 5.0) var trade_min_interval_sec: float = 0.2

## Items lying in the world (P2-T15, docs/15 P2-221): a placeholder box with
## a billboard label (display name and quantity) above it. Edge length and
## colour of the box, distance of the label above it, world size of one font
## pixel, font size and colour of the label.
@export_range(0.01, 5.0) var world_item_marker_size_m: float = 0.25
@export var world_item_marker_color: Color = Color(0.95, 0.80, 0.30, 1.0)
@export_range(0.0, 5.0) var world_item_label_margin_m: float = 0.20
@export_range(0.0001, 0.1) var world_item_label_pixel_size: float = 0.004
@export_range(1, 256) var world_item_label_font_size: int = 24
@export var world_item_label_color: Color = Color(1.0, 0.95, 0.70, 1.0)
## Labels are nodes, unlike batched bodies. Only items within this distance
## of the local player receive one, up to the nearest configured count.
@export_range(0.0, 100.0) var world_item_label_distance_m: float = 12.0
@export_range(0, 256) var world_item_label_max_count: int = 8
## The pickup candidate shown in the HUD and named by the pickup key: the
## nearest world item within this distance of the local player, in the
## mirror. Only a suggestion: the server checks its own positions and range
## (GameplaySettings.pickup_range_m).
@export_range(0.1, 50.0) var pickup_candidate_range_m: float = 2.5

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

## The test map (P3-2, docs/15 P3-047..P3-049): a flat ground as large as the
## map the SERVER described (the size is not a setting here), and a wall along
## each edge. Colours of both, height and thickness of the walls.
@export var map_ground_color: Color = Color(0.30, 0.36, 0.28, 1.0)
@export var map_edge_color: Color = Color(0.75, 0.25, 0.20, 1.0)
@export_range(0.1, 100.0) var map_edge_height_m: float = 3.0
@export_range(0.01, 50.0) var map_edge_thickness_m: float = 0.5
## Cell overlay, a testing aid: this key shows / hides the borders and ids
## of the world cells around the local player (local only, nothing is sent).
@export var cell_overlay_key: Key = KEY_F3
@export var cell_overlay_initially_visible: bool = false
## The overlay covers the cells within this many cells of the player's cell.
@export_range(0, 32) var cell_overlay_radius_cells: int = 3
@export var cell_overlay_color: Color = Color(1.0, 0.85, 0.20, 1.0)
## Height of the border lines above the ground (above 0, so they are not
## hidden in it) and of the cell id labels.
@export_range(0.001, 10.0) var cell_overlay_height_m: float = 0.05
@export_range(0.0, 50.0) var cell_overlay_label_height_m: float = 2.5
@export_range(0.0001, 1.0) var cell_overlay_label_pixel_size: float = 0.02
@export_range(1, 256) var cell_overlay_label_font_size: int = 48

## Containers (P3-3, docs/00 ADR-021, ADR-026; docs/15 P3-083..P3-086). The
## open key asks the server to open the nearest container in reach, or to
## close the one that is open (or being searched).
@export var container_open_key: Key = KEY_H
## The cursor on the stacks inside the open container: previous / next
## (local only, nothing is sent).
@export var container_previous_key: Key = KEY_J
@export var container_next_key: Key = KEY_K
## Takes `container_transfer_quantity` units of the stack under the container
## cursor into the inventory.
@export var container_take_key: Key = KEY_U
## Puts `container_transfer_quantity` units of the stack under the INVENTORY
## cursor (select_previous_key / select_next_key) into the open container.
## Held with `drop_stack_modifier_key`, both keys move the whole stack.
@export var container_put_key: Key = KEY_I
@export_range(1, 10000) var container_transfer_quantity: int = 1
## Local flood guard between two container requests of any kind (the server
## has its own).
@export_range(0.01, 5.0) var container_min_interval_sec: float = 0.2
## The container named in the HUD and by the open key: the nearest one
## within this distance of the local player, in the mirror. Only a
## suggestion: the server checks its own positions and range
## (ContainerSettings.interact_range_m).
@export_range(0.1, 50.0) var container_candidate_range_m: float = 2.5
## Stacks of the open container listed in the HUD; the rest is counted.
@export_range(1, 50) var hud_container_line_count: int = 6
## Placeholder of a container: a box with a billboard label (its name, and
## "수색 전" until somebody searched it). Edge length of the box, its colour
## before and after the search, distance of the label above it, world size of
## one font pixel, font size and colour of the label.
@export_range(0.01, 5.0) var container_marker_size_m: float = 0.7
@export var container_marker_color: Color = Color(0.55, 0.38, 0.20, 1.0)
@export var container_searched_marker_color: Color = Color(0.34, 0.32, 0.30, 1.0)
@export_range(0.0, 5.0) var container_label_margin_m: float = 0.25
@export_range(0.0001, 0.1) var container_label_pixel_size: float = 0.006
@export_range(1, 256) var container_label_font_size: int = 36
@export var container_label_color: Color = Color(0.85, 0.95, 1.0, 1.0)
@export_range(0.0, 100.0) var container_label_distance_m: float = 16.0

## Building presentation (P3-4b). These values affect only input mapping,
## placeholder geometry and client-side preview estimates; the server owns
## every building rule.
@export var build_mode_key: Key = KEY_L
@export var build_floor_key: Key = KEY_1
@export var build_wall_key: Key = KEY_2
@export var build_door_key: Key = KEY_3
@export var build_storage_box_key: Key = KEY_4
@export var build_rotate_key: Key = KEY_PERIOD
@export var build_deliver_key: Key = KEY_M
@export var build_work_key: Key = KEY_COMMA
@export var build_remove_key: Key = KEY_DELETE
@export_range(0.1, 1000.0) var build_ray_length_m: float = 100.0
@export_range(0.01, 5.0) var structure_target_radius_m: float = 0.8
@export_range(0.1, 100.0) var build_preview_range_m: float = 4.0
@export_range(0.1, 100.0) var structure_deliver_target_range_m: float = 2.5
@export_range(0.1, 100.0) var structure_work_target_range_m: float = 2.5
@export_range(0.1, 100.0) var structure_remove_target_range_m: float = 4.0
@export_range(0.1, 100.0) var structure_door_target_range_m: float = 2.5
@export_range(0.1, 2.0) var structure_floor_scale: float = 0.94
@export_range(0.01, 1.0) var structure_floor_height_m: float = 0.12
@export_range(0.1, 2.0) var structure_edge_scale: float = 0.94
@export_range(0.1, 10.0) var structure_wall_height_m: float = 2.2
@export_range(0.01, 1.0) var structure_wall_thickness_m: float = 0.16
@export_range(0.01, 1.0) var structure_door_thickness_m: float = 0.10
@export var structure_completed_color: Color = Color(0.48, 0.38, 0.25, 1.0)
@export var structure_blueprint_color: Color = Color(0.35, 0.75, 1.0, 0.42)
@export var build_preview_valid_color: Color = Color(0.25, 0.95, 0.45, 0.50)
@export var build_preview_invalid_color: Color = Color(1.0, 0.22, 0.18, 0.50)
@export_range(0.0, 5.0) var structure_label_margin_m: float = 0.25
@export_range(0.0001, 0.1) var structure_label_pixel_size: float = 0.005
@export_range(1, 256) var structure_label_font_size: int = 28
@export var structure_label_color: Color = Color(0.85, 0.95, 1.0, 1.0)
@export_range(0.0, 100.0) var structure_label_distance_m: float = 20.0


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
	if hud_panel_padding_px < 0 or hud_panel_corner_radius_px < 0 or hud_stack_separation_px < 0 or hud_text_outline_size_px < 0:
		errors.append("HUD panel dimensions and text outline size must be >= 0")
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
	var item_keys: Dictionary[String, Key] = {"select_previous_key": select_previous_key, "select_next_key": select_next_key, "drop_key": drop_key, "drop_stack_modifier_key": drop_stack_modifier_key}
	for key_name: String in item_keys:
		if item_keys[key_name] == KEY_NONE:
			errors.append("%s must not be KEY_NONE" % key_name)
	if drop_quantity < 1:
		errors.append("drop_quantity must be >= 1")
	if drop_min_interval_sec <= 0.0:
		errors.append("drop_min_interval_sec must be > 0")
	if world_item_marker_size_m <= 0.0 or world_item_label_margin_m < 0.0 or world_item_label_pixel_size <= 0.0 or world_item_label_font_size < 1:
		errors.append("world item marker size and label pixel size must be > 0, label margin >= 0 and font size >= 1")
	if world_item_label_distance_m < 0.0:
		errors.append("world_item_label_distance_m must be >= 0")
	if world_item_label_max_count < 0:
		errors.append("world_item_label_max_count must be >= 0")
	if not is_finite(pickup_candidate_range_m) or pickup_candidate_range_m <= 0.0:
		errors.append("pickup_candidate_range_m must be > 0")
	var trade_keys: Dictionary[String, Key] = {"trade_request_key": trade_request_key, "trade_accept_key": trade_accept_key, "trade_decline_key": trade_decline_key, "trade_offer_add_key": trade_offer_add_key, "trade_offer_remove_key": trade_offer_remove_key}
	for key_name: String in trade_keys:
		if trade_keys[key_name] == KEY_NONE:
			errors.append("%s must not be KEY_NONE" % key_name)
	if trade_offer_step < 1:
		errors.append("trade_offer_step must be >= 1")
	if trade_min_interval_sec <= 0.0:
		errors.append("trade_min_interval_sec must be > 0")
	if cell_overlay_key == KEY_NONE:
		errors.append("cell_overlay_key must not be KEY_NONE")
	if not is_finite(map_edge_height_m) or map_edge_height_m <= 0.0 or not is_finite(map_edge_thickness_m) or map_edge_thickness_m <= 0.0:
		errors.append("map edge height and thickness must be > 0")
	if cell_overlay_radius_cells < 0:
		errors.append("cell_overlay_radius_cells must be >= 0")
	if not is_finite(cell_overlay_height_m) or cell_overlay_height_m <= 0.0 or not is_finite(cell_overlay_label_height_m) or cell_overlay_label_height_m < 0.0 or cell_overlay_label_pixel_size <= 0.0 or cell_overlay_label_font_size < 1:
		errors.append("cell overlay height and label pixel size must be > 0, label height >= 0 and font size >= 1")
	var container_keys: Dictionary[String, Key] = {"container_open_key": container_open_key, "container_previous_key": container_previous_key, "container_next_key": container_next_key, "container_take_key": container_take_key, "container_put_key": container_put_key}
	for key_name: String in container_keys:
		if container_keys[key_name] == KEY_NONE:
			errors.append("%s must not be KEY_NONE" % key_name)
	if container_transfer_quantity < 1:
		errors.append("container_transfer_quantity must be >= 1")
	if container_min_interval_sec <= 0.0:
		errors.append("container_min_interval_sec must be > 0")
	if not is_finite(container_candidate_range_m) or container_candidate_range_m <= 0.0:
		errors.append("container_candidate_range_m must be > 0")
	if hud_container_line_count <= 0:
		errors.append("hud_container_line_count must be > 0")
	if container_marker_size_m <= 0.0 or container_label_margin_m < 0.0 or container_label_pixel_size <= 0.0 or container_label_font_size < 1:
		errors.append("container marker size and label pixel size must be > 0, label margin >= 0 and font size >= 1")
	if container_label_distance_m < 0.0:
		errors.append("container_label_distance_m must be >= 0")
	var build_keys: Dictionary[String, Key] = {"build_mode_key": build_mode_key, "build_floor_key": build_floor_key, "build_wall_key": build_wall_key, "build_door_key": build_door_key, "build_storage_box_key": build_storage_box_key, "build_rotate_key": build_rotate_key, "build_deliver_key": build_deliver_key, "build_work_key": build_work_key, "build_remove_key": build_remove_key}
	for key_name: String in build_keys:
		if build_keys[key_name] == KEY_NONE:
			errors.append("%s must not be KEY_NONE" % key_name)
	if build_ray_length_m <= 0.0 or structure_target_radius_m <= 0.0 or build_preview_range_m <= 0.0 or structure_deliver_target_range_m <= 0.0 or structure_work_target_range_m <= 0.0 or structure_remove_target_range_m <= 0.0 or structure_door_target_range_m <= 0.0:
		errors.append("building ray length, preview and target ranges must be > 0")
	if structure_floor_scale <= 0.0 or structure_floor_height_m <= 0.0 or structure_edge_scale <= 0.0 or structure_wall_height_m <= 0.0 or structure_wall_thickness_m <= 0.0 or structure_door_thickness_m <= 0.0:
		errors.append("structure placeholder dimensions must be > 0")
	if structure_label_margin_m < 0.0 or structure_label_pixel_size <= 0.0 or structure_label_font_size < 1:
		errors.append("structure label margin must be >= 0, pixel size > 0 and font size >= 1")
	if structure_label_distance_m < 0.0:
		errors.append("structure_label_distance_m must be >= 0")
	if not _are_distinct(assigned_keys().values()):
		errors.append("use keys (consume, drink, bandage, cure), the rest key, the prone key, the treat-other modifier, the cursor keys, the drop key, the drop-stack modifier, the trade keys, the cell overlay key, the container keys and the building keys must be different keys")
	return errors


## Every key this resource assigns, by setting name.
func assigned_keys() -> Dictionary[String, Key]:
	return {
		"consume_key": consume_key,
		"drink_key": drink_key,
		"bandage_key": bandage_key,
		"cure_key": cure_key,
		"rest_key": rest_key,
		"prone_key": prone_key,
		"treat_other_modifier_key": treat_other_modifier_key,
		"select_previous_key": select_previous_key,
		"select_next_key": select_next_key,
		"drop_key": drop_key,
		"drop_stack_modifier_key": drop_stack_modifier_key,
		"trade_request_key": trade_request_key,
		"trade_accept_key": trade_accept_key,
		"trade_decline_key": trade_decline_key,
		"trade_offer_add_key": trade_offer_add_key,
		"trade_offer_remove_key": trade_offer_remove_key,
		"cell_overlay_key": cell_overlay_key,
		"container_open_key": container_open_key,
		"container_previous_key": container_previous_key,
		"container_next_key": container_next_key,
		"container_take_key": container_take_key,
		"container_put_key": container_put_key,
		"build_mode_key": build_mode_key,
		"build_floor_key": build_floor_key,
		"build_wall_key": build_wall_key,
		"build_door_key": build_door_key,
		"build_storage_box_key": build_storage_box_key,
		"build_rotate_key": build_rotate_key,
		"build_deliver_key": build_deliver_key,
		"build_work_key": build_work_key,
		"build_remove_key": build_remove_key,
	}


## Names of the settings of this resource whose key is also a movement or
## pickup key of `camera` (CameraSettings assigns those). Empty = no clash.
func keys_shared_with(camera: CameraSettings) -> PackedStringArray:
	var taken: Array[Key] = [camera.move_forward_key, camera.move_backward_key, camera.move_left_key, camera.move_right_key, camera.pickup_key]
	var shared: PackedStringArray = []
	var own: Dictionary[String, Key] = assigned_keys()
	for key_name: String in own:
		if own[key_name] != KEY_NONE and taken.has(own[key_name]):
			shared.append(key_name)
	return shared


## True when no key appears twice in `keys` (unset keys are not compared).
static func _are_distinct(keys_to_check: Array) -> bool:
	var seen: Dictionary[Key, bool] = {}
	for key: Key in keys_to_check:
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
