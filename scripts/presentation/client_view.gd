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
@onready var _inventory_label: Label = %InventoryLabel
@onready var _consume_result_label: Label = %ConsumeResultLabel
@onready var _creation_screen: CharacterCreationScreen = %CharacterCreationScreen

## Children of a player's visual.
const PLAYER_BODY_NODE: String = "Body"
const PLAYER_TAG_NODE: String = "NameTag"

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
## player_id -> Node3D "Player_<id>" with the children "Body" (the capsule,
## MeshInstance3D) and "NameTag" (Label3D).
var _player_visuals: Dictionary[String, Node3D] = {}
## player_id -> what the capsule and the name tag were last built from
## (the mirrors change many times a second; meshes are rebuilt on change).
var _player_look_keys: Dictionary[String, String] = {}
var _zombie_visuals: Dictionary[String, MeshInstance3D] = {}
var _zombie_capsule_mesh: CapsuleMesh = null
var _dead_player_material: StandardMaterial3D = null
var _zombie_materials: Dictionary[String, StandardMaterial3D] = {}
var _event_lines: PackedStringArray = []
var _attack_result_until_sec: float = 0.0
var _inventory_module: InventoryNetModule = null
## Flood guard of the consume key (same rule as the attack guard).
var _consume_policy: AttackIntentPolicy = null
## Static item definitions: names for the HUD and "is this consumable".
var _item_catalog: ItemCatalog = null
var _consume_result_until_sec: float = 0.0
## Hash of the inventory mirror the HUD summary was built from.
var _inventory_signature: int = 0
## Lie down / get up requests go through the survival module (P2-T8).
var _survival_module: SurvivalNetModule = null
## Flood guard of the rest key (same rule as the attack guard).
var _rest_policy: AttackIntentPolicy = null
## Lie prone / stand up requests and everybody's posture (P2-T11).
var _posture_module: PostureNetModule = null
var _posture_state: ClientPostureState = null
## Flood guard of the prone key (the interval of the rest key).
var _posture_policy: AttackIntentPolicy = null
## Character names and appearance, and the creation request (P2-T9).
var _character_module: CharacterNetModule = null
var _character_state: ClientCharacterState = null
## Appearance definitions the placeholder look is computed from (the
## module's when connected, so the client and the mirror agree).
var _appearance_catalog: AppearanceCatalog = AppearanceCatalog.new()


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
	_consume_policy = AttackIntentPolicy.new(_presentation.consume_min_interval_sec)
	_rest_policy = AttackIntentPolicy.new(_presentation.rest_min_interval_sec)
	_posture_policy = AttackIntentPolicy.new(_presentation.rest_min_interval_sec)
	_item_catalog = ItemCatalog.load_directory()
	ClientInputActions.register(_settings, _presentation)
	_prepare_player_resources()
	_prepare_zombie_resources()
	_creation_screen.create_requested.connect(_on_create_requested)
	_apply_mouse_mode()
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
	if _consume_result_label.visible and _now_sec() >= _consume_result_until_sec:
		_consume_result_label.visible = false


func _physics_process(_delta: float) -> void:
	_update_camera()
	# No game input while the character creation screen is open (P2-T9).
	if not is_game_input_enabled():
		return
	if Input.is_action_just_pressed(ClientInputActions.ATTACK):
		_request_melee_attack()
	for action: StringName in ClientInputActions.USE_ACTION_KINDS:
		if Input.is_action_just_pressed(action):
			_request_use(ClientInputActions.USE_ACTION_KINDS[action])
	if Input.is_action_just_pressed(ClientInputActions.REST):
		_request_rest()
	if Input.is_action_just_pressed(ClientInputActions.PRONE):
		_request_prone()
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
	_survival_module = _network.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule
	if _survival_module != null:
		_survival_state = _survival_module.client_state
		if not _survival_state.changed.is_connected(_on_survival_state_changed):
			_survival_state.changed.connect(_on_survival_state_changed)
		if not _survival_state.event_received.is_connected(_on_survival_event):
			_survival_state.event_received.connect(_on_survival_event)
		if not _survival_module.rest_result.is_connected(_on_rest_result):
			_survival_module.rest_result.connect(_on_rest_result)
	_posture_module = _network.get_module(PostureNetModule.MODULE_NAME) as PostureNetModule
	if _posture_module != null:
		_posture_state = _posture_module.client_state
		# A posture changes what the capsules and the HUD show, like survival.
		if not _posture_state.changed.is_connected(_on_survival_state_changed):
			_posture_state.changed.connect(_on_survival_state_changed)
		if not _posture_module.posture_result.is_connected(_on_posture_result):
			_posture_module.posture_result.connect(_on_posture_result)
	_combat_module = _network.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule
	if _combat_module != null:
		if not _combat_module.melee_result.is_connected(_on_melee_result):
			_combat_module.melee_result.connect(_on_melee_result)
		if not _combat_module.combat_event.is_connected(_on_combat_event):
			_combat_module.combat_event.connect(_on_combat_event)
	_inventory_module = _network.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	if _inventory_module != null and not _inventory_module.consume_result.is_connected(_on_consume_result):
		_inventory_module.consume_result.connect(_on_consume_result)
	_character_module = _network.get_module(CharacterNetModule.MODULE_NAME) as CharacterNetModule
	if _character_module != null:
		_character_state = _character_module.client_state
		var rules: CharacterRules = _character_module.character_rules()
		_appearance_catalog = rules.catalog
		_creation_screen.setup(rules)
		if not _character_state.changed.is_connected(_on_character_state_changed):
			_character_state.changed.connect(_on_character_state_changed)
		if not _character_module.create_result.is_connected(_on_create_result):
			_character_module.create_result.connect(_on_create_result)
	_sync_creation_screen()
	_sync_player_visuals()
	_sync_zombie_visuals()
	_refresh_survival_hud()
	_refresh_inventory_hud()
	_load_recent_events()


func _on_world_state_changed() -> void:
	_sync_player_visuals()
	_update_camera()
	_refresh_inventory_hud()


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


func _on_consume_result(_request_id: int, ok: bool, reason: String) -> void:
	_show_consume_text(ClientPresentationFormatter.format_consume_result(ok, reason))


## The answer to a rest request is shown where the use results are shown.
func _on_rest_result(_request_id: int, ok: bool, reason: String) -> void:
	_show_consume_text(ClientPresentationFormatter.format_rest_result(ok, reason))


## The answer to a posture request is shown where the use results are shown.
func _on_posture_result(_request_id: int, ok: bool, reason: String) -> void:
	_show_consume_text(ClientPresentationFormatter.format_posture_result(ok, reason))


## A survival event that deserves a notice (P2-T10: why the local player
## woke) is shown where the use results are shown.
func _on_survival_event(event: Dictionary) -> void:
	var notice: String = ClientPresentationFormatter.format_survival_notice(event)
	if not notice.is_empty():
		_show_consume_text(notice)


func _show_consume_text(text: String) -> void:
	_consume_result_label.text = text
	_consume_result_label.visible = true
	_consume_result_until_sec = _now_sec() + _presentation.consume_result_duration_sec


func _prepare_player_resources() -> void:
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
			# Out of the tree at once (queue_free alone keeps the node, and its
			# name, until the end of the frame).
			_players_root.remove_child(_player_visuals[existing_id])
			_player_visuals[existing_id].queue_free()
			_player_visuals.erase(existing_id)
			_player_look_keys.erase(existing_id)
	for player_id: String in _state.players:
		var visual: Node3D = _player_visuals.get(player_id, null)
		if visual == null:
			visual = _make_player_visual(player_id)
			_players_root.add_child(visual)
			_player_visuals[player_id] = visual
		var body: MeshInstance3D = visual.get_node(PLAYER_BODY_NODE) as MeshInstance3D
		var tag: Label3D = visual.get_node(PLAYER_TAG_NODE) as Label3D
		var entry: Dictionary = _state.players[player_id]
		var alive: bool = _survival_state == null or not _survival_state.has_player(player_id) or _survival_state.is_alive(player_id)
		# Lying down to rest is visible on every client (P2-T8): the capsule
		# lies on the ground like a dead one but keeps its living colour.
		var posture: PlayerPosture.Kind = _posture_state.posture_of(player_id) if _posture_state != null else PlayerPosture.Kind.STANDING
		var resting: bool = (_survival_state != null and _survival_state.is_resting(player_id)) or (alive and posture == PlayerPosture.Kind.RESTING)
		var lying: bool = ClientPresentationFormatter.player_is_lying(alive, resting)
		# Lying prone is visible on every client too (P2-T11): the capsule
		# leans forward, so it is told apart from a sleeper on its back.
		var prone: bool = ClientPresentationFormatter.player_is_prone(alive, resting, posture)
		var is_local: bool = player_id == _state.local_player_id
		# Name and appearance (P2-T9): the top colour is the capsule colour,
		# height and body type its size. Without a character row the usual
		# capsule in the local / remote colour is shown and no name.
		var character_name: String = _character_state.character_name(player_id) if _character_state != null else ""
		var selection: Dictionary = _character_state.appearance(player_id) if _character_state != null else {}
		var mesh: CapsuleMesh = body.mesh as CapsuleMesh
		# The mirrors change many times a second (positions): the capsule and
		# the name are rebuilt only when what they show changed.
		var look_key: String = "%s|%d|%s|%s" % [character_name, selection.hash(), str(alive), str(is_local)]
		if _player_look_keys.get(player_id, "") != look_key:
			_player_look_keys[player_id] = look_key
			var look: Dictionary = CharacterCapsuleLook.build(_appearance_catalog, selection, _settings.capsule_radius_m, _settings.capsule_height_m, _settings.local_player_color if is_local else _settings.remote_player_color)
			mesh.radius = float(look[CharacterCapsuleLook.KEY_RADIUS])
			mesh.height = float(look[CharacterCapsuleLook.KEY_HEIGHT])
			if alive:
				var material: StandardMaterial3D = StandardMaterial3D.new()
				material.albedo_color = look[CharacterCapsuleLook.KEY_COLOR]
				body.material_override = material
			else:
				body.material_override = _dead_player_material
			tag.text = character_name
			tag.visible = not character_name.is_empty()
			tag.modulate = _presentation.name_tag_dead_color if not alive else (_presentation.name_tag_local_color if is_local else _presentation.name_tag_remote_color)
		var radius: float = mesh.radius
		var height: float = mesh.height
		visual.position = entry.get("position", Vector3.ZERO) as Vector3
		visual.rotation = Vector3(0.0, float(entry.get("yaw", 0.0)), 0.0)
		var tilt: float = ClientPresentationFormatter.player_pose_tilt_rad(alive, resting, prone, _presentation)
		var center_height: float = radius if lying else ClientPresentationFormatter.player_body_center_height(radius, height, tilt)
		body.position = Vector3.UP * center_height
		body.rotation = Vector3(tilt, 0.0, 0.0)
		# The name stays upright above whatever the capsule does.
		tag.position = Vector3.UP * ((radius * 2.0 if lying else (center_height * 2.0 if prone else height)) + _presentation.name_tag_margin_m)


## A player's placeholder: a root that follows position and facing, the
## capsule (its own mesh: every character has its own size) and the name.
func _make_player_visual(player_id: String) -> Node3D:
	var visual: Node3D = Node3D.new()
	visual.name = "Player_" + player_id
	var body: MeshInstance3D = MeshInstance3D.new()
	body.name = PLAYER_BODY_NODE
	var mesh: CapsuleMesh = CapsuleMesh.new()
	mesh.radius = _settings.capsule_radius_m
	mesh.height = _settings.capsule_height_m
	body.mesh = mesh
	visual.add_child(body)
	var tag: Label3D = Label3D.new()
	tag.name = PLAYER_TAG_NODE
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.pixel_size = _presentation.name_tag_pixel_size
	tag.font_size = _presentation.name_tag_font_size
	tag.visible = false
	visual.add_child(tag)
	return visual


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
		"character_generation": _survival_state.character_generation(),
		"character_name": _character_state.character_name(_survival_state.local_player_id) if _character_state != null else "",
		"resting": _survival_state.is_resting(_survival_state.local_player_id),
		"posture": PlayerPosture.name_of(_local_posture()),
	}
	var lines: PackedStringArray = ClientPresentationFormatter.build_survival_lines(vitals, _presentation)
	var carried: Array[Dictionary] = _state.inventory if _state != null else ([] as Array[Dictionary])
	lines.append_array(ClientPresentationFormatter.build_treatment_lines(vitals, carried, _item_catalog, _presentation))
	lines.append_array(ClientPresentationFormatter.build_rest_lines(vitals, _presentation))
	lines.append_array(ClientPresentationFormatter.build_posture_lines(vitals, _presentation))
	_survival_label.text = "\n".join(lines)
	_survival_label.visible = true


## Rebuilds the inventory summary when the local inventory mirror changed.
## Hidden while not joined (the mirror says nothing then).
func _refresh_inventory_hud() -> void:
	if _state == null or _state.local_player_id.is_empty():
		_inventory_label.visible = false
		return
	var signature: int = _state.inventory.hash()
	if _inventory_label.visible and signature == _inventory_signature:
		return
	_inventory_signature = signature
	_inventory_label.text = "\n".join(ClientPresentationFormatter.build_inventory_lines(_state.inventory, _item_catalog, _presentation.hud_inventory_line_count))
	_inventory_label.visible = true
	# The survival HUD counts the carried bandages.
	_refresh_survival_hud()


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


## A use key (food, drink, bandage, cure): asks the server to use the first item of
## that kind in the mirrored inventory. Only the item id is sent; the server
## decides whether and how it works.
func _request_use(kind: ConsumeIntentPolicy.Kind) -> void:
	var connected: bool = (
		_inventory_module != null
		and _network != null
		and _network.is_client()
		and _state != null
		and not _state.local_player_id.is_empty()
	)
	if not _consume_policy.should_send(connected, _now_sec()):
		return
	var item_id: String = ConsumeIntentPolicy.first_item_id_of_kind(_state.inventory, _item_catalog, kind)
	if item_id.is_empty():
		_show_consume_text(ClientPresentationFormatter.nothing_to_use_text(kind))
		return
	_inventory_module.request_consume(item_id)


## Rest key (P2-T8): asks the server to lie down, or to get up when the
## mirror says the local player is lying. Only the wanted state is sent; the
## server decides.
func _request_rest() -> void:
	var connected: bool = (
		_survival_module != null
		and _survival_state != null
		and _network != null
		and _network.is_client()
		and _state != null
		and not _state.local_player_id.is_empty()
	)
	if not _rest_policy.should_send(connected, _now_sec()):
		return
	_survival_module.request_rest(not _survival_state.is_resting(_state.local_player_id))


## Prone key (P2-T11): asks the server to lie prone, or to stand up when the
## mirror says the local player is prone. Only the wanted posture is sent;
## the server decides (and wakes a sleeper that wants to lie prone).
func _request_prone() -> void:
	var connected: bool = (
		_posture_module != null
		and _network != null
		and _network.is_client()
		and _state != null
		and not _state.local_player_id.is_empty()
	)
	if not _posture_policy.should_send(connected, _now_sec()):
		return
	_posture_module.request_posture(PlayerPosture.Kind.STANDING if _local_posture() == PlayerPosture.Kind.PRONE else PlayerPosture.Kind.PRONE)


## Posture of the local player as the mirrors know it: asleep when either
## mirror says so, otherwise what the posture mirror says.
func _local_posture() -> PlayerPosture.Kind:
	if _state == null or _state.local_player_id.is_empty():
		return PlayerPosture.Kind.STANDING
	if _survival_state != null and _survival_state.is_resting(_state.local_player_id):
		return PlayerPosture.Kind.RESTING
	return _posture_state.posture_of(_state.local_player_id) if _posture_state != null else PlayerPosture.Kind.STANDING


# ------------------------------------------------------------ character creation (P2-T9)

## False while the character creation screen is open: no move, attack, use,
## rest or pickup input is sent then.
func is_game_input_enabled() -> bool:
	return _creation_screen == null or not _creation_screen.is_open()


func _on_character_state_changed() -> void:
	_sync_player_visuals()
	_refresh_survival_hud()
	_sync_creation_screen()


## Opens the screen when the server says the local player may create a
## character (it has none, or its character is dead and the wait is over)
## and closes it otherwise. A session started with `--character-name=`
## creates without the screen.
func _sync_creation_screen() -> void:
	var can_create: bool = _character_state != null and _character_state.can_create_character()
	var auto_create: bool = _character_module != null and _character_module.is_auto_create_enabled()
	var should_open: bool = CharacterCreationScreen.should_open(can_create, auto_create)
	if should_open and not _creation_screen.is_open():
		var local_id: String = _state.local_player_id if _state != null else ""
		_creation_screen.open(not _character_state.has_character(local_id))
		_apply_mouse_mode()
	elif not should_open and _creation_screen.is_open():
		_creation_screen.close()
		_apply_mouse_mode()


## The screen's confirm button: only the intent is sent; the server decides.
func _on_create_requested(character_name: String, appearance: Dictionary) -> void:
	if _character_module == null or _character_module.request_create_character(character_name, appearance) == CharacterNetModule.NO_REQUEST:
		_creation_screen.show_server_reason(NetworkService.NOT_JOINED)


## The server's answer. An accepted request closes the screen through the
## creation state the server sends with it; a refusal is shown.
func _on_create_result(_request_id: int, ok: bool, reason: String) -> void:
	if ok:
		_sync_creation_screen()
	else:
		_creation_screen.show_server_reason(reason)


## The mouse is free while the creation screen is open and captured for the
## camera otherwise (never touched on a headless display).
func _apply_mouse_mode() -> void:
	if DisplayServer.get_name() == "headless":
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _creation_screen != null and _creation_screen.is_open() else Input.MOUSE_MODE_CAPTURED


func _now_sec() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
