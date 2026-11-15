class_name ClientInputActions
extends RefCounted
## Registers client actions at runtime so project.godot remains untouched.

const MOVE_FORWARD: StringName = &"move_forward"
const MOVE_BACKWARD: StringName = &"move_backward"
const MOVE_LEFT: StringName = &"move_left"
const MOVE_RIGHT: StringName = &"move_right"
const PICKUP: StringName = &"pickup"
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
	_add_key_action(PICKUP, settings.pickup_key, settings.input_deadzone)
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
