class_name ClientInputActions
extends RefCounted
## Registers client actions at runtime so project.godot remains untouched.

const MOVE_FORWARD: StringName = &"move_forward"
const MOVE_BACKWARD: StringName = &"move_backward"
const MOVE_LEFT: StringName = &"move_left"
const MOVE_RIGHT: StringName = &"move_right"
const SPRINT: StringName = &"sprint"
const PICKUP: StringName = &"pickup"
## Raise / lower the local camera look target. No server intent is sent.
const CAMERA_HEIGHT_UP: StringName = &"camera_height_up"
const CAMERA_HEIGHT_DOWN: StringName = &"camera_height_down"
const ATTACK: StringName = &"attack"
## Use keys, one per kind of item (P2-T6). CONSUME is the food key (the
## single consume key of P2-T3 kept its name and its setting `consume_key`).
const CONSUME: StringName = &"consume"
const DRINK: StringName = &"drink"
const USE_BANDAGE: StringName = &"use_bandage"
const USE_CURE: StringName = &"use_cure"
## Lie down / get up (P2-T8).
const REST: StringName = &"rest"
## Lie prone / stand up (P2-T11).
const PRONE: StringName = &"prone"
## Held with a treatment key: use the item on another player (P2-T12).
const TREAT_OTHER: StringName = &"treat_other"
## Inventory cursor: the previous / next carried stack (P2-T15).
const SELECT_PREVIOUS: StringName = &"select_previous_item"
const SELECT_NEXT: StringName = &"select_next_item"
## Put units of the selected stack down (P2-T15).
const DROP: StringName = &"drop_item"
## Held with the drop key: put the whole selected stack down (P2-T15).
const DROP_STACK: StringName = &"drop_stack"
## Trade (P2-T16): ask the player the camera looks at; accept a request /
## confirm the offers; decline / cancel; put more / fewer units of the
## selected stack into the own offer.
const TRADE_REQUEST: StringName = &"trade_request"
const TRADE_ACCEPT: StringName = &"trade_accept"
const TRADE_DECLINE: StringName = &"trade_decline"
const TRADE_OFFER_ADD: StringName = &"trade_offer_add"
const TRADE_OFFER_REMOVE: StringName = &"trade_offer_remove"
## Show / hide the borders of the world cells around the player (P3-2; a
## testing aid, local only).
const CELL_OVERLAY: StringName = &"toggle_cell_overlay"
## P4-8 private NPC AI panel and remaining path line.
const NPC_DEBUG_OVERLAY: StringName = &"toggle_npc_debug_overlay"
## Containers (P3-3): open the nearest container / close the open one; the
## cursor on the stacks inside; take the stack under that cursor; put the
## stack under the inventory cursor in. DROP_STACK held with take or put
## moves the whole stack.
const CONTAINER_OPEN: StringName = &"container_open"
const CONTAINER_PREVIOUS: StringName = &"container_previous_item"
const CONTAINER_NEXT: StringName = &"container_next_item"
const CONTAINER_TAKE: StringName = &"container_take"
const CONTAINER_PUT: StringName = &"container_put"
## Building mode and structure actions (P3-4b).
const BUILD_MODE: StringName = &"toggle_build_mode"
const BUILD_FLOOR: StringName = &"build_floor"
const BUILD_WALL: StringName = &"build_wall"
const BUILD_DOOR: StringName = &"build_door"
const BUILD_STORAGE_BOX: StringName = &"build_storage_box"
const BUILD_ROTATE: StringName = &"build_rotate"
const BUILD_DELIVER: StringName = &"build_deliver"
const BUILD_WORK: StringName = &"build_work"
const BUILD_REMOVE: StringName = &"build_remove"
## Use action -> the kind of item its key asks the server to use.
const USE_ACTION_KINDS: Dictionary[StringName, ConsumeIntentPolicy.Kind] = {
	CONSUME: ConsumeIntentPolicy.Kind.FOOD,
	DRINK: ConsumeIntentPolicy.Kind.DRINK,
	USE_BANDAGE: ConsumeIntentPolicy.Kind.BANDAGE,
	USE_CURE: ConsumeIntentPolicy.Kind.CURE,
}


static func register(settings: CameraSettings, presentation: ClientPresentationSettings = null) -> void:
	_add_key_action(MOVE_FORWARD, settings.move_forward_key, settings.input_deadzone)
	_add_key_action(MOVE_BACKWARD, settings.move_backward_key, settings.input_deadzone)
	_add_key_action(MOVE_LEFT, settings.move_left_key, settings.input_deadzone)
	_add_key_action(MOVE_RIGHT, settings.move_right_key, settings.input_deadzone)
	_add_key_action(SPRINT, settings.sprint_key, settings.input_deadzone)
	_add_key_action(PICKUP, settings.pickup_key, settings.input_deadzone)
	_add_key_action(CAMERA_HEIGHT_UP, settings.camera_height_up_key, settings.input_deadzone)
	_add_key_action(CAMERA_HEIGHT_DOWN, settings.camera_height_down_key, settings.input_deadzone)
	if presentation != null:
		_add_mouse_action(ATTACK, presentation.attack_mouse_button, settings.input_deadzone)
		_add_key_action(CONSUME, presentation.consume_key, settings.input_deadzone)
		_add_key_action(DRINK, presentation.drink_key, settings.input_deadzone)
		_add_key_action(USE_BANDAGE, presentation.bandage_key, settings.input_deadzone)
		_add_key_action(USE_CURE, presentation.cure_key, settings.input_deadzone)
		_add_key_action(REST, presentation.rest_key, settings.input_deadzone)
		_add_key_action(PRONE, presentation.prone_key, settings.input_deadzone)
		_add_key_action(TREAT_OTHER, presentation.treat_other_modifier_key, settings.input_deadzone)
		_add_key_action(SELECT_PREVIOUS, presentation.select_previous_key, settings.input_deadzone)
		_add_key_action(SELECT_NEXT, presentation.select_next_key, settings.input_deadzone)
		_add_key_action(DROP, presentation.drop_key, settings.input_deadzone)
		_add_key_action(DROP_STACK, presentation.drop_stack_modifier_key, settings.input_deadzone)
		_add_key_action(TRADE_REQUEST, presentation.trade_request_key, settings.input_deadzone)
		_add_key_action(TRADE_ACCEPT, presentation.trade_accept_key, settings.input_deadzone)
		_add_key_action(TRADE_DECLINE, presentation.trade_decline_key, settings.input_deadzone)
		_add_key_action(TRADE_OFFER_ADD, presentation.trade_offer_add_key, settings.input_deadzone)
		_add_key_action(TRADE_OFFER_REMOVE, presentation.trade_offer_remove_key, settings.input_deadzone)
		_add_key_action(CELL_OVERLAY, presentation.cell_overlay_key, settings.input_deadzone)
		_add_key_action(NPC_DEBUG_OVERLAY, presentation.npc_debug_overlay_key, settings.input_deadzone)
		_add_key_action(CONTAINER_OPEN, presentation.container_open_key, settings.input_deadzone)
		_add_key_action(CONTAINER_PREVIOUS, presentation.container_previous_key, settings.input_deadzone)
		_add_key_action(CONTAINER_NEXT, presentation.container_next_key, settings.input_deadzone)
		_add_key_action(CONTAINER_TAKE, presentation.container_take_key, settings.input_deadzone)
		_add_key_action(CONTAINER_PUT, presentation.container_put_key, settings.input_deadzone)
		_add_key_action(BUILD_MODE, presentation.build_mode_key, settings.input_deadzone)
		_add_key_action(BUILD_FLOOR, presentation.build_floor_key, settings.input_deadzone)
		_add_key_action(BUILD_WALL, presentation.build_wall_key, settings.input_deadzone)
		_add_key_action(BUILD_DOOR, presentation.build_door_key, settings.input_deadzone)
		_add_key_action(BUILD_STORAGE_BOX, presentation.build_storage_box_key, settings.input_deadzone)
		_add_key_action(BUILD_ROTATE, presentation.build_rotate_key, settings.input_deadzone)
		_add_key_action(BUILD_DELIVER, presentation.build_deliver_key, settings.input_deadzone)
		_add_key_action(BUILD_WORK, presentation.build_work_key, settings.input_deadzone)
		_add_key_action(BUILD_REMOVE, presentation.build_remove_key, settings.input_deadzone)


static func _add_key_action(action: StringName, key: Key, deadzone: float) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action, deadzone)
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = key
	InputMap.action_add_event(action, event)


static func _add_mouse_action(action: StringName, button: MouseButton, deadzone: float) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action, deadzone)
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	InputMap.action_add_event(action, event)
