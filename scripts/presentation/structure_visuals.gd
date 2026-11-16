class_name StructureVisuals
extends RefCounted
## Batched floors/walls/props; animated doors remain individual nodes.

const BATCH_PREFIX: String = "StructureBatch_"
const DOOR_PREFIX: String = "StructureDoor_"
const LABEL_PREFIX: String = "StructureLabel_"
const BODY_NAME: String = "Body"
const LABEL_NAME: String = "ProgressLabel"

var _root: Node3D
var _mirror: ClientStructureState
var _catalog: StructureCatalog
var _items: ItemCatalog
var _grid: StructureGrid
var _settings: ClientPresentationSettings
var _batches: Dictionary[String, MultiMeshInstance3D] = {}
var _doors: Dictionary[String, Node3D] = {}
var _labels: Dictionary[String, Node3D] = {}
var _transforms: Dictionary[String, Transform3D] = {}
var _focus: Vector3 = Vector3.ZERO


func _init(root: Node3D, mirror: ClientStructureState, catalog: StructureCatalog, items: ItemCatalog, grid: StructureGrid, settings: ClientPresentationSettings) -> void:
	_root = root
	_mirror = mirror
	_catalog = catalog
	_items = items
	_grid = grid
	_settings = settings
	# Every accepted payload emits `changed` once after its per-row signals.
	# Listening only here coalesces a 370-row join into one batch rebuild.
	_mirror.changed.connect(_rebuild)
	_rebuild()


func visual_of(structure_id: String) -> Node3D:
	return _doors.get(structure_id, _labels.get(structure_id, null))


func label_of(structure_id: String) -> Label3D:
	var anchor: Node3D = _labels.get(structure_id, null)
	return anchor.get_node(LABEL_NAME) as Label3D if anchor != null else null


func transform_of(structure_id: String) -> Transform3D:
	return _transforms.get(structure_id, Transform3D())


func has_visual(structure_id: String) -> bool:
	return _transforms.has(structure_id)


func count() -> int:
	return _transforms.size()


func batch_instance_count() -> int:
	var total: int = 0
	for batch: MultiMeshInstance3D in _batches.values():
		total += batch.multimesh.instance_count
	return total


func door_count() -> int:
	return _doors.size()


func label_count() -> int:
	return _labels.size()


func update_focus(focus: Vector3) -> void:
	if focus.distance_squared_to(_focus) < 0.0625:
		return
	_focus = focus
	_update_labels()


func _rebuild() -> void:
	for batch: MultiMeshInstance3D in _batches.values():
		batch.free()
	_batches.clear()
	for door: Node3D in _doors.values():
		door.free()
	_doors.clear()
	_transforms.clear()
	var ids_by_batch: Dictionary[String, PackedStringArray] = {}
	for structure_id: String in _mirror.structure_ids():
		var entry: Dictionary = _mirror.get_structure(structure_id)
		var definition: StructureDefinition = _catalog.get_definition(str(entry.get(ClientStructureState.KEY_DEFINITION_ID, "")))
		if definition == null:
			continue
		if definition.is_door:
			_make_door(structure_id, entry, definition)
			continue
		var complete: bool = _is_complete(entry)
		var key: String = "%s|%s" % [definition.definition_id, "solid" if complete else "blueprint"]
		if not ids_by_batch.has(key):
			ids_by_batch[key] = PackedStringArray()
		ids_by_batch[key].append(structure_id)
	for key: String in ids_by_batch:
		var ids: PackedStringArray = ids_by_batch[key]
		ids.sort()
		_make_batch(key, ids)
	_update_labels()


func _make_batch(key: String, ids: PackedStringArray) -> void:
	var first: Dictionary = _mirror.get_structure(ids[0])
	var definition: StructureDefinition = _catalog.get_definition(str(first[ClientStructureState.KEY_DEFINITION_ID]))
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = _mesh_size(definition)
	var material: StandardMaterial3D = _material(_is_complete(first))
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = ids.size()
	for index: int in range(ids.size()):
		var structure_id: String = ids[index]
		var transform: Transform3D = _body_transform(structure_id, definition, false)
		multimesh.set_instance_transform(index, transform)
		_transforms[structure_id] = transform
	var batch: MultiMeshInstance3D = MultiMeshInstance3D.new()
	batch.name = BATCH_PREFIX + key.replace("|", "_")
	batch.multimesh = multimesh
	batch.material_override = material
	_root.add_child(batch)
	_batches[key] = batch


func _make_door(structure_id: String, entry: Dictionary, definition: StructureDefinition) -> void:
	var node: Node3D = Node3D.new()
	node.name = DOOR_PREFIX + structure_id
	var body: MeshInstance3D = MeshInstance3D.new()
	body.name = BODY_NAME
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = _mesh_size(definition)
	body.mesh = mesh
	body.material_override = _material(_is_complete(entry))
	var transform: Transform3D = _body_transform(structure_id, definition, bool(entry[ClientStructureState.KEY_DOOR_OPEN]))
	body.transform = transform
	node.add_child(body)
	_root.add_child(node)
	_doors[structure_id] = node
	_transforms[structure_id] = transform


func _body_transform(structure_id: String, definition: StructureDefinition, door_open: bool) -> Transform3D:
	var slot: Vector3i = _mirror.slot_of(structure_id)
	var size: Vector3 = _mesh_size(definition)
	var yaw: float = PI * 0.5 if slot.z == StructureGrid.Layer.EDGE_LOW_X else 0.0
	if definition.is_door and door_open:
		yaw += PI * 0.5
	return Transform3D(Basis(Vector3.UP, yaw), _grid.slot_anchor(slot) + Vector3.UP * (size.y * 0.5))


func _mesh_size(definition: StructureDefinition) -> Vector3:
	if definition.visual_size_m != Vector3.ZERO:
		return definition.visual_size_m
	if definition.placement == StructureDefinition.Placement.TILE:
		return Vector3(_grid.module_m * _settings.structure_floor_scale, _settings.structure_floor_height_m, _grid.module_m * _settings.structure_floor_scale)
	return Vector3(_grid.module_m * _settings.structure_edge_scale, _settings.structure_wall_height_m, _settings.structure_door_thickness_m if definition.is_door else _settings.structure_wall_thickness_m)


func _material(complete: bool) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = _settings.structure_completed_color if complete else _settings.structure_blueprint_color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if material.albedo_color.a < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	return material


func _is_complete(entry: Dictionary) -> bool:
	var state: String = str(entry.get(ClientStructureState.KEY_STATE, ""))
	return state == "completed" or state == "damaged"


func _update_labels() -> void:
	var max_distance_sq: float = _settings.structure_label_distance_m * _settings.structure_label_distance_m
	for structure_id: String in _labels.keys():
		var entry: Dictionary = _mirror.get_structure(structure_id)
		var position: Vector3 = _grid.slot_anchor(_mirror.slot_of(structure_id)) if not entry.is_empty() else Vector3.INF
		if entry.is_empty() or _is_complete(entry) or position.distance_squared_to(_focus) > max_distance_sq:
			_labels[structure_id].free()
			_labels.erase(structure_id)
	for structure_id: String in _mirror.structure_ids():
		var entry: Dictionary = _mirror.get_structure(structure_id)
		if _is_complete(entry):
			continue
		var definition: StructureDefinition = _catalog.get_definition(str(entry.get(ClientStructureState.KEY_DEFINITION_ID, "")))
		if definition == null:
			continue
		var position: Vector3 = _grid.slot_anchor(_mirror.slot_of(structure_id))
		if position.distance_squared_to(_focus) > max_distance_sq:
			continue
		var anchor: Node3D = _labels.get(structure_id, null)
		if anchor == null:
			anchor = Node3D.new()
			anchor.name = LABEL_PREFIX + structure_id
			var label: Label3D = Label3D.new()
			label.name = LABEL_NAME
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.pixel_size = _settings.structure_label_pixel_size
			label.font_size = _settings.structure_label_font_size
			label.modulate = _settings.structure_label_color
			anchor.add_child(label)
			_root.add_child(anchor)
			_labels[structure_id] = anchor
		anchor.position = position
		(anchor.get_node(LABEL_NAME) as Label3D).position.y = _mesh_size(definition).y + _settings.structure_label_margin_m
		(anchor.get_node(LABEL_NAME) as Label3D).text = "%s · %d%% · 작업자 %d명" % [StructurePresentationFormatter.material_text(entry[ClientStructureState.KEY_REQUIRED], entry[ClientStructureState.KEY_DELIVERED], _items), roundi(float(entry[ClientStructureState.KEY_PROGRESS]) * 100.0), _mirror.workers_of(structure_id).size()]
