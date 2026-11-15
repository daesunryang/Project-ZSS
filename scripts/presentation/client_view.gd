class_name ClientView
extends Node3D
## Client-only camera, local input and temporary player presentation.
## Never instantiated on the server (docs/09 §11).

@onready var _camera: Camera3D = %Camera
@onready var _players_root: Node3D = %Players

var _settings: CameraSettings = null
var _network: NetworkService = null
var _state: ClientWorldState = null
var _intent_sender: MoveIntentSender = null
var _yaw: float = 0.0
var _pitch: float = 0.0
var _player_visuals: Dictionary[String, MeshInstance3D] = {}
var _capsule_mesh: CapsuleMesh = null
var _local_material: StandardMaterial3D = null
var _remote_material: StandardMaterial3D = null


func _ready() -> void:
	%VersionLabel.text = BuildInfo.summary()
	_settings = CameraSettings.load_or_default()
	var errors: PackedStringArray = _settings.validate()
	if not errors.is_empty():
		GameLogger.error("presentation", "invalid camera settings; using built-in defaults", {"errors": "; ".join(errors), "operation": "client_view_ready"})
		_settings = CameraSettings.new()
	_yaw = 0.0
	_pitch = _settings.initial_pitch_rad
	_intent_sender = MoveIntentSender.new(
		_settings.move_resend_interval_sec,
		_settings.direction_change_epsilon,
		_settings.yaw_change_epsilon_rad
	)
	ClientInputActions.register(_settings)
	_prepare_player_resources()
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_camera()
	_bind_network.call_deferred()
	GameLogger.info("presentation", "client view ready", {"display_driver": DisplayServer.get_name()})


func _exit_tree() -> void:
	if DisplayServer.get_name() != "headless" and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		var orbit: Vector2 = CameraOrbitMath.apply_mouse_delta(
			_yaw,
			_pitch,
			motion.relative,
			_settings.mouse_sensitivity_rad_per_pixel,
			_settings.min_pitch_rad,
			_settings.max_pitch_rad
		)
		_yaw = orbit.x
		_pitch = orbit.y
		_update_camera()
		get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	_update_camera()
	if _network == null or _state == null or _state.local_player_id.is_empty():
		return
	var sample: Vector2 = Vector2(
		Input.get_axis(ClientInputActions.MOVE_LEFT, ClientInputActions.MOVE_RIGHT),
		Input.get_axis(ClientInputActions.MOVE_BACKWARD, ClientInputActions.MOVE_FORWARD)
	)
	var local_intent: Vector2 = InputIntentMath.sample_to_local_intent(sample, _settings.input_deadzone)
	var world_intent: Vector2 = InputIntentMath.camera_relative_direction(local_intent, _yaw)
	var now_sec: float = float(Time.get_ticks_msec()) / 1000.0
	if _intent_sender.should_send(world_intent, _yaw, now_sec):
		_network.send_move_intent(world_intent, _yaw)
	if Input.is_action_just_pressed(ClientInputActions.PICKUP):
		_request_nearest_pickup()


func _bind_network() -> void:
	var bootstrap: GameBootstrap = get_parent() as GameBootstrap
	if bootstrap == null or bootstrap.get_client_view() != self:
		GameLogger.error("presentation", "client view has no owning bootstrap", {"operation": "bind_network"})
		return
	_network = bootstrap.get_network()
	if _network == null:
		return
	_state = _network.client_state
	if not _state.changed.is_connected(_on_world_state_changed):
		_state.changed.connect(_on_world_state_changed)
	_sync_player_visuals()


func _on_world_state_changed() -> void:
	_sync_player_visuals()


func _prepare_player_resources() -> void:
	_capsule_mesh = CapsuleMesh.new()
	_capsule_mesh.radius = _settings.capsule_radius_m
	_capsule_mesh.height = _settings.capsule_height_m
	_local_material = StandardMaterial3D.new()
	_local_material.albedo_color = _settings.local_player_color
	_remote_material = StandardMaterial3D.new()
	_remote_material.albedo_color = _settings.remote_player_color


func _sync_player_visuals() -> void:
	if _state == null:
		return
	for existing_id: String in _player_visuals.keys():
		if not _state.players.has(existing_id):
			_player_visuals[existing_id].queue_free()
			_player_visuals.erase(existing_id)
	for player_id: String in _state.players:
		var visual: MeshInstance3D = _player_visuals.get(player_id, null)
		if visual == null:
			visual = MeshInstance3D.new()
			visual.name = "Player_" + player_id
			visual.mesh = _capsule_mesh
			_players_root.add_child(visual)
			_player_visuals[player_id] = visual
		var entry: Dictionary = _state.players[player_id]
		visual.position = (entry.get("position", Vector3.ZERO) as Vector3) + Vector3.UP * (_settings.capsule_height_m * 0.5)
		visual.rotation.y = float(entry.get("yaw", 0.0))
		visual.material_override = _local_material if player_id == _state.local_player_id else _remote_material


func _update_camera() -> void:
	if _camera == null or _settings == null:
		return
	var target: Vector3 = Vector3.UP * _settings.target_height_m
	if _state != null and not _state.local_player_id.is_empty():
		target += _state.position_of(_state.local_player_id)
	_camera.global_position = CameraOrbitMath.camera_position(target, _yaw, _pitch, _settings.camera_distance_m)
	_camera.look_at(target, Vector3.UP)


func _request_nearest_pickup() -> void:
	var local_position: Vector3 = _state.position_of(_state.local_player_id)
	var item_id: String = InputIntentMath.nearest_world_item_id(local_position, _state.world_items)
	if not item_id.is_empty():
		_network.request_pickup(item_id)
