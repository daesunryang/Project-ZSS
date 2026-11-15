class_name ClientInputActions
extends RefCounted
## Registers client actions at runtime so project.godot remains untouched.

const MOVE_FORWARD: StringName = &"move_forward"
const MOVE_BACKWARD: StringName = &"move_backward"
const MOVE_LEFT: StringName = &"move_left"
const MOVE_RIGHT: StringName = &"move_right"
const PICKUP: StringName = &"pickup"
const ATTACK: StringName = &"attack"
const CONSUME: StringName = &"consume"


static func register(settings: CameraSettings, presentation: ClientPresentationSettings = null) -> void:
	_add_key_action(MOVE_FORWARD, settings.move_forward_key, settings.input_deadzone)
	_add_key_action(MOVE_BACKWARD, settings.move_backward_key, settings.input_deadzone)
	_add_key_action(MOVE_LEFT, settings.move_left_key, settings.input_deadzone)
	_add_key_action(MOVE_RIGHT, settings.move_right_key, settings.input_deadzone)
	_add_key_action(PICKUP, settings.pickup_key, settings.input_deadzone)
	if presentation != null:
		_add_mouse_action(ATTACK, presentation.attack_mouse_button, settings.input_deadzone)
		_add_key_action(CONSUME, presentation.consume_key, settings.input_deadzone)


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
