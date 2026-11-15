class_name ClientView
extends Node3D
## Client-only camera, local input and temporary player presentation.
## Never instantiated on the server (docs/09 §11).

@onready var _camera: Camera3D = %Camera
@onready var _players_root: Node3D = %Players
@onready var _zombies_root: Node3D = %Zombies
@onready var _survival_label: Label = %SurvivalLabel
@onready var _event_log_label: Label = %EventLogLabel
@onready var _attack_result_label: Label = %AttackResultLabel

var _settings: CameraSettings = null
var _presentation: ClientPresentationSettings = null
var _network: NetworkService = null
var _state: ClientWorldState = null
var _zombie_state: ClientZombieState = null
var _survival_state: ClientSurvivalState = null
var _combat_module: CombatNetModule = null
var _intent_sender: MoveIntentSender = null
var _attack_policy: AttackIntentPolicy = null
var _yaw: float = 0.0
var _pitch: float = 0.0
var _player_visuals: Dictionary[String, MeshInstance3D] = {}
var _zombie_visuals: Dictionary[String, MeshInstance3D] = {}
var _capsule_mesh: CapsuleMesh = null
var _zombie_capsule_mesh: CapsuleMesh = null
var _local_material: StandardMaterial3D = null
var _remote_material: StandardMaterial3D = null
var _dead_player_material: StandardMaterial3D = null
var _zombie_materials: Dictionary[String, StandardMaterial3D] = {}
var _event_lines: PackedStringArray = []
var _attack_result_until_sec: float = 0.0


func _ready() -> void:
	%VersionLabel.text = BuildInfo.summary()
	_settings = CameraSettings.load_or_default()
	var errors: PackedStringArray = _settings.validate()
	if not errors.is_empty():
		GameLogger.error("presentation", "invalid camera settings; using built-in defaults", {"errors": "; ".join(errors), "operation": "client_view_ready"})
		_settings = CameraSettings.new()
	_presentation = ClientPresentationSettings.load_or_default()
	errors = _presentation.validate()
	if not errors.is_empty():
		GameLogger.error("presentation", "invalid client presentation settings; using built-in defaults", {"errors": "; ".join(errors), "operation": "client_view_ready"})
		_presentation = ClientPresentationSettings.new()
	_yaw = 0.0
	_pitch = _settings.initial_pitch_rad
	_intent_sender = MoveIntentSender.new(
		_settings.move_resend_interval_sec,
		_settings.direction_change_epsilon,
		_settings.yaw_change_epsilon_rad
	)
	_attack_policy = AttackIntentPolicy.new(_presentation.attack_min_interval_sec)
	ClientInputActions.register(_settings, _presentation)
	_prepare_player_resources()
	_prepare_zombie_resources()
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


func _process(_delta: float) -> void:
	if _attack_result_label.visible and _now_sec() >= _attack_result_until_sec:
		_attack_result_label.visible = false


func _physics_process(_delta: float) -> void:
	_update_camera()
	if Input.is_action_just_pressed(ClientInputActions.ATTACK):
		_request_melee_attack()
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
	var zombie_module: ZombieNetModule = _network.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule
	if zombie_module != null:
		_zombie_state = zombie_module.client_state
		if not _zombie_state.changed.is_connected(_on_zombie_state_changed):
			_zombie_state.changed.connect(_on_zombie_state_changed)
		if not _zombie_state.zombie_added.is_connected(_on_zombie_added):
			_zombie_state.zombie_added.connect(_on_zombie_added)
		if not _zombie_state.zombie_removed.is_connected(_on_zombie_removed):
			_zombie_state.zombie_removed.connect(_on_zombie_removed)
		if not _zombie_state.event_received.is_connected(_on_zombie_event):
			_zombie_state.event_received.connect(_on_zombie_event)
	var survival_module: SurvivalNetModule = _network.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule
	if survival_module != null:
		_survival_state = survival_module.client_state
		if not _survival_state.changed.is_connected(_on_survival_state_changed):
			_survival_state.changed.connect(_on_survival_state_changed)
	_combat_module = _network.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule
	if _combat_module != null:
		if not _combat_module.melee_result.is_connected(_on_melee_result):
			_combat_module.melee_result.connect(_on_melee_result)
		if not _combat_module.combat_event.is_connected(_on_combat_event):
			_combat_module.combat_event.connect(_on_combat_event)
	_sync_player_visuals()
	_sync_zombie_visuals()
	_refresh_survival_hud()
	_load_recent_events()


func _on_world_state_changed() -> void:
	_sync_player_visuals()
	_update_camera()


func _on_survival_state_changed() -> void:
	_sync_player_visuals()
	_refresh_survival_hud()


func _on_zombie_state_changed() -> void:
	_sync_zombie_visuals()


func _on_zombie_added(_zombie_id: String) -> void:
	_sync_zombie_visuals()


func _on_zombie_removed(zombie_id: String) -> void:
	var visual: MeshInstance3D = _zombie_visuals.get(zombie_id, null)
	if visual != null:
		visual.queue_free()
		_zombie_visuals.erase(zombie_id)


func _on_zombie_event(event: Dictionary) -> void:
	var local_player_id: String = _state.local_player_id if _state != null else ""
	_append_event_line(ClientPresentationFormatter.format_zombie_event(event, local_player_id))


func _on_combat_event(event: Dictionary) -> void:
	_append_event_line(ClientPresentationFormatter.format_combat_event(event))


func _on_melee_result(_request_id: int, ok: bool, reason: String) -> void:
	_attack_result_label.text = ClientPresentationFormatter.format_attack_result(ok, reason)
	_attack_result_label.visible = true
	_attack_result_until_sec = _now_sec() + _presentation.attack_result_duration_sec


func _prepare_player_resources() -> void:
	_capsule_mesh = CapsuleMesh.new()
	_capsule_mesh.radius = _settings.capsule_radius_m
	_capsule_mesh.height = _settings.capsule_height_m
	_local_material = StandardMaterial3D.new()
	_local_material.albedo_color = _settings.local_player_color
	_remote_material = StandardMaterial3D.new()
	_remote_material.albedo_color = _settings.remote_player_color
	_dead_player_material = StandardMaterial3D.new()
	_dead_player_material.albedo_color = _presentation.dead_player_color


func _prepare_zombie_resources() -> void:
	_zombie_capsule_mesh = CapsuleMesh.new()
	_zombie_capsule_mesh.radius = _presentation.zombie_capsule_radius_m
	_zombie_capsule_mesh.height = _presentation.zombie_capsule_height_m
	for state_name: String in ZombieState.STATE_NAMES:
		var material: StandardMaterial3D = StandardMaterial3D.new()
		material.albedo_color = ClientPresentationFormatter.zombie_color(state_name, _presentation)
		_zombie_materials[state_name] = material


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
		var alive: bool = _survival_state == null or not _survival_state.has_player(player_id) or _survival_state.is_alive(player_id)
		var center_height: float = _settings.capsule_height_m * 0.5 if alive else _settings.capsule_radius_m
		visual.position = (entry.get("position", Vector3.ZERO) as Vector3) + Vector3.UP * center_height
		visual.rotation = Vector3(0.0 if alive else _presentation.dead_tilt_rad, float(entry.get("yaw", 0.0)), 0.0)
		if not alive:
			visual.material_override = _dead_player_material
		else:
			visual.material_override = _local_material if player_id == _state.local_player_id else _remote_material


func _sync_zombie_visuals() -> void:
	if _zombie_state == null:
		return
	for existing_id: String in _zombie_visuals.keys():
		if not _zombie_state.has_zombie(existing_id):
			_zombie_visuals[existing_id].queue_free()
			_zombie_visuals.erase(existing_id)
	for zombie_id: String in _zombie_state.zombie_ids():
		var visual: MeshInstance3D = _zombie_visuals.get(zombie_id, null)
		if visual == null:
			visual = MeshInstance3D.new()
			visual.name = "Zombie_" + zombie_id
			visual.mesh = _zombie_capsule_mesh
			_zombies_root.add_child(visual)
			_zombie_visuals[zombie_id] = visual
		var entry: Dictionary = _zombie_state.get_zombie(zombie_id)
		var state_name: String = str(entry.get("state", ClientZombieState.STATE_IDLE))
		var dead: bool = state_name == ClientZombieState.STATE_DEAD
		var center_height: float = _presentation.zombie_capsule_radius_m if dead else _presentation.zombie_capsule_height_m * 0.5
		visual.position = (entry.get("position", Vector3.ZERO) as Vector3) + Vector3.UP * center_height
		visual.rotation = Vector3(_presentation.dead_tilt_rad if dead else 0.0, float(entry.get("yaw", 0.0)), 0.0)
		visual.material_override = _zombie_materials.get(state_name, _zombie_materials[ClientZombieState.STATE_IDLE])


func _refresh_survival_hud() -> void:
	if _survival_state == null or _survival_state.local_player_id.is_empty() or not _survival_state.has_player(_survival_state.local_player_id):
		_survival_label.visible = false
		return
	var needs: Dictionary = {}
	for kind: String in NeedKind.KIND_NAMES:
		needs[kind] = _survival_state.need_category(kind)
	var vitals: Dictionary = {
		"alive": _survival_state.is_alive(_survival_state.local_player_id),
		"health": _survival_state.health(),
		"stamina": _survival_state.stamina(),
		"needs": needs,
		"wounds": _survival_state.wounds(),
		"infection_stage": _survival_state.infection_stage(),
	}
	_survival_label.text = "\n".join(ClientPresentationFormatter.build_survival_lines(vitals, _presentation))
	_survival_label.visible = true


func _load_recent_events() -> void:
	_event_lines.clear()
	if _combat_module != null:
		for event: Dictionary in _combat_module.recent_events():
			_append_event_line(ClientPresentationFormatter.format_combat_event(event))
	if _zombie_state != null:
		var local_player_id: String = _state.local_player_id if _state != null else ""
		for event: Dictionary in _zombie_state.recent_events():
			_append_event_line(ClientPresentationFormatter.format_zombie_event(event, local_player_id))
	_refresh_event_log()


func _append_event_line(line: String) -> void:
	if line.is_empty():
		return
	_event_lines.append(line)
	while _event_lines.size() > _presentation.hud_event_line_count:
		_event_lines.remove_at(0)
	_refresh_event_log()


func _refresh_event_log() -> void:
	_event_log_label.text = "최근 이벤트\n" + "\n".join(_event_lines)
	_event_log_label.visible = not _event_lines.is_empty()


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


func _request_melee_attack() -> void:
	var connected: bool = (
		_combat_module != null
		and _network != null
		and _network.is_client()
		and _state != null
		and not _state.local_player_id.is_empty()
	)
	if not _attack_policy.should_send(connected, _now_sec()):
		return
	_combat_module.request_melee_attack(_yaw)


func _now_sec() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
