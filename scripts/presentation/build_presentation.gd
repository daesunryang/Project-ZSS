class_name BuildPresentation
extends RefCounted
## Client-only coordinator for structure visuals, build input and HUD.
## It sends intents and displays the mirror; it never decides game state.

const FLOOR_ID: String = "dev_floor"
const WALL_ID: String = "dev_wall"
const DOOR_ID: String = "dev_door"
const STORAGE_BOX_ID: String = "dev_storage_box"

var _root: Node3D
var _hud: Label
var _settings: ClientPresentationSettings
var _building: BuildingSettings
var _catalog: StructureCatalog
var _items: ItemCatalog
var _grid: StructureGrid
var _module: StructureNetModule
var _mirror: ClientStructureState
var _world: ClientWorldState
var _visuals: StructureVisuals
var _ghost: MeshInstance3D
var _build_mode: bool = false
var _selected_definition_id: String = FLOOR_ID
var _rotation_steps: int = 0
var _candidate: Dictionary = BuildModePolicy.NO_HIT
var _candidate_valid: bool = false
var _target_id: String = ""
var _result_text: String = ""
var _ghost_key: String = ""


func _init(root: Node3D, hud: Label, settings: ClientPresentationSettings, building: BuildingSettings, catalog: StructureCatalog, items: ItemCatalog, module: StructureNetModule, world: ClientWorldState) -> void:
	_root = root
	_hud = hud
	_settings = settings
	_building = building
	_catalog = catalog
	_items = items
	_module = module
	_mirror = module.client_state
	_world = world
	_grid = StructureGrid.new(building.grid_module_m)
	_visuals = StructureVisuals.new(root, _mirror, catalog, items, _grid, settings)
	_ghost = MeshInstance3D.new()
	_ghost.name = "BuildPreview"
	_ghost.visible = false
	root.add_child(_ghost)
	_module.structure_result.connect(_on_structure_result)
	_mirror.work_changed.connect(_on_work_changed)
	_refresh_hud()


## Returns whether this frame's attack and pickup actions were consumed.
func tick(camera: Camera3D, map: ClientWorldMap) -> Dictionary:
	_visuals.update_focus(_local_position())
	if Input.is_action_just_pressed(ClientInputActions.BUILD_MODE):
		_build_mode = not _build_mode
	if _build_mode:
		if Input.is_action_just_pressed(ClientInputActions.BUILD_FLOOR):
			_select(FLOOR_ID)
		if Input.is_action_just_pressed(ClientInputActions.BUILD_WALL):
			_select(WALL_ID)
		if Input.is_action_just_pressed(ClientInputActions.BUILD_DOOR):
			_select(DOOR_ID)
		if Input.is_action_just_pressed(ClientInputActions.BUILD_STORAGE_BOX):
			_select(STORAGE_BOX_ID)
		if Input.is_action_just_pressed(ClientInputActions.BUILD_ROTATE):
			_rotation_steps = posmod(_rotation_steps + 1, StructureGrid.ROTATION_COUNT)
	_update_target(camera)
	_update_preview(camera, map)
	var used_attack: bool = false
	var used_pickup: bool = false
	if _build_mode and Input.is_action_just_pressed(ClientInputActions.ATTACK):
		used_attack = true
		if bool(_candidate.get("hit", false)):
			_module.request_place(_selected_definition_id, _candidate["tile"], int(_candidate["rotation"]))
		else:
			_result_text = "바닥을 조준해야 배치할 수 있습니다"
	if Input.is_action_just_pressed(ClientInputActions.BUILD_DELIVER) and _target_in_range(_settings.structure_deliver_target_range_m):
		_module.request_deliver(_target_id)
	if Input.is_action_just_pressed(ClientInputActions.BUILD_WORK) and _target_in_range(_settings.structure_work_target_range_m):
		var me: String = _world.local_player_id
		_module.request_work(_target_id, _mirror.work_of(me) != _target_id)
	if Input.is_action_just_pressed(ClientInputActions.BUILD_REMOVE) and _target_in_range(_settings.structure_remove_target_range_m):
		var entry: Dictionary = _mirror.get_structure(_target_id)
		if str(entry.get(ClientStructureState.KEY_STATE, "")) == "completed":
			_module.request_demolish(_target_id)
		else:
			_module.request_cancel(_target_id)
	if Input.is_action_just_pressed(ClientInputActions.PICKUP) and _target_is_usable_door():
		used_pickup = true
		var door: Dictionary = _mirror.get_structure(_target_id)
		_module.request_door(_target_id, not bool(door[ClientStructureState.KEY_DOOR_OPEN]))
	_refresh_hud()
	return {"attack": used_attack, "pickup": used_pickup}


func visuals() -> StructureVisuals:
	return _visuals


func target_id() -> String:
	return _target_id


func is_build_mode() -> bool:
	return _build_mode


func selected_definition_id() -> String:
	return _selected_definition_id


func _select(definition_id: String) -> void:
	if _catalog.has(definition_id):
		_selected_definition_id = definition_id
		_rotation_steps = 0
		_ghost_key = ""


func _local_position() -> Vector3:
	var player_id: String = _world.local_player_id
	return _world.position_of(player_id) if not player_id.is_empty() and _world.players.has(player_id) else Vector3.ZERO


func _update_target(camera: Camera3D) -> void:
	var maximum_reach: float = maxf(maxf(_settings.structure_deliver_target_range_m, _settings.structure_work_target_range_m), maxf(_settings.structure_remove_target_range_m, _settings.structure_door_target_range_m))
	_target_id = BuildModePolicy.target_structure(camera.global_position, -camera.global_basis.z, _local_position(), _mirror, _grid, _settings.build_ray_length_m, maximum_reach, _settings.structure_target_radius_m)


func _update_preview(camera: Camera3D, map: ClientWorldMap) -> void:
	_ghost.visible = _build_mode
	if not _build_mode:
		return
	var definition: StructureDefinition = _catalog.get_definition(_selected_definition_id)
	_candidate = BuildModePolicy.aimed_placement(camera.global_position, -camera.global_basis.z, 0.0, _settings.build_ray_length_m, _local_position(), _settings.build_preview_min_distance_m, _settings.build_preview_range_m, definition, _grid, _rotation_steps)
	_candidate_valid = map != null and map.is_known() and BuildModePolicy.preview_is_valid(_candidate, _mirror, _local_position(), map.bounds_min, map.bounds_max, _settings.build_preview_range_m, _grid.module_m)
	if not bool(_candidate.get("hit", false)):
		_ghost.visible = false
		return
	_ghost.position = _candidate["anchor"]
	_build_ghost(definition, _candidate["slot"], _candidate_valid)


func _build_ghost(definition: StructureDefinition, slot: Vector3i, valid: bool) -> void:
	var key: String = "%s:%d:%s" % [definition.definition_id, slot.z, valid]
	if key == _ghost_key:
		return
	_ghost_key = key
	var mesh: BoxMesh = BoxMesh.new()
	_ghost.rotation = Vector3.ZERO
	if definition.visual_size_m != Vector3.ZERO:
		mesh.size = definition.visual_size_m
		_ghost.position.y = definition.visual_size_m.y * 0.5
	elif definition.placement == StructureDefinition.Placement.TILE:
		mesh.size = Vector3(_grid.module_m * _settings.structure_floor_scale, _settings.structure_floor_height_m, _grid.module_m * _settings.structure_floor_scale)
		_ghost.position.y = _settings.structure_floor_height_m * 0.5
	else:
		mesh.size = Vector3(_grid.module_m * _settings.structure_edge_scale, _settings.structure_wall_height_m, _settings.structure_wall_thickness_m)
		_ghost.position.y = _settings.structure_wall_height_m * 0.5
		if slot.z == StructureGrid.Layer.EDGE_LOW_X:
			_ghost.rotation.y = PI * 0.5
	_ghost.mesh = mesh
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = _settings.build_preview_valid_color if valid else _settings.build_preview_invalid_color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost.material_override = material


func _target_is_usable_door() -> bool:
	if _target_id.is_empty():
		return false
	var entry: Dictionary = _mirror.get_structure(_target_id)
	var definition: StructureDefinition = _catalog.get_definition(str(entry.get(ClientStructureState.KEY_DEFINITION_ID, "")))
	if definition == null or not definition.is_door:
		return false
	var state: String = str(entry.get(ClientStructureState.KEY_STATE, ""))
	if state != "completed" and state != "damaged":
		return false
	var anchor: Vector3 = _grid.slot_anchor(_mirror.slot_of(_target_id))
	return StructureGrid.flat_distance(_local_position(), anchor) <= _settings.structure_door_target_range_m


func _target_in_range(reach_m: float) -> bool:
	if _target_id.is_empty():
		return false
	var anchor: Vector3 = _grid.slot_anchor(_mirror.slot_of(_target_id))
	return StructureGrid.flat_distance(_local_position(), anchor) <= reach_m


func _refresh_hud() -> void:
	var definition: StructureDefinition = _catalog.get_definition(_selected_definition_id)
	var mode: String = "켜짐" if _build_mode else "꺼짐"
	var piece: String = definition.display_name if definition != null else _selected_definition_id
	var cost: String = StructurePresentationFormatter.material_text(definition.build_costs if definition != null else {}, {}, _items)
	var entry: Dictionary = _mirror.get_structure(_target_id) if not _target_id.is_empty() else {}
	var shown_rotation: int = int(_candidate.get("rotation", _rotation_steps)) if _build_mode else _rotation_steps
	var lines: PackedStringArray = PackedStringArray([
		"카메라: 휠 줌 | 높이 [PageUp/PageDown]",
		"건축 모드 [L]: %s | %s [1/2/3/4] | 회전 %d [.]" % [mode, piece, shown_rotation],
		"비용: %s" % cost,
		StructurePresentationFormatter.structure_summary(entry, _mirror.workers_of(_target_id).size(), _items),
	])
	if not _world.local_player_id.is_empty() and not _mirror.work_of(_world.local_player_id).is_empty():
		lines.append("작업 중 [,] | 자재 넣기 [M] | 취소/철거 [Delete]")
	else:
		lines.append("작업 시작 [,] | 자재 넣기 [M] | 취소/철거 [Delete]")
	# E is shared with the item pickup; an aimed door in reach wins (P3-189),
	# so say so while it does (P3-201).
	if _target_is_usable_door():
		lines.append("%s [E] (줍기보다 먼저)" % ("문 닫기" if bool(entry.get(ClientStructureState.KEY_DOOR_OPEN, false)) else "문 열기"))
	if not _result_text.is_empty():
		lines.append(_result_text)
	_hud.text = "\n".join(lines)
	_hud.visible = true


func _on_structure_result(_request_id: int, ok: bool, reason: String, _structure_id: String) -> void:
	_result_text = StructurePresentationFormatter.result_text(ok, reason)
	_refresh_hud()


func _on_work_changed(player_id: String, _structure_id: String, working: bool, reason: String) -> void:
	if player_id == _world.local_player_id and not working and not reason.is_empty():
		_result_text = StructurePresentationFormatter.work_stop_text(reason)
	_refresh_hud()
