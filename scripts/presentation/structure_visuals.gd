class_name StructureVisuals
extends RefCounted
## Placeholder structure nodes driven only by ClientStructureState signals.

const BODY_NAME: String = "Body"
const LABEL_NAME: String = "ProgressLabel"

var _root: Node3D
var _mirror: ClientStructureState
var _catalog: StructureCatalog
var _items: ItemCatalog
var _grid: StructureGrid
var _settings: ClientPresentationSettings
var _nodes: Dictionary[String, Node3D] = {}


func _init(root: Node3D, mirror: ClientStructureState, catalog: StructureCatalog, items: ItemCatalog, grid: StructureGrid, settings: ClientPresentationSettings) -> void:
	_root = root
	_mirror = mirror
	_catalog = catalog
	_items = items
	_grid = grid
	_settings = settings
	_mirror.structure_added.connect(_upsert)
	_mirror.structure_changed.connect(_upsert)
	_mirror.structure_removed.connect(_remove)
	_mirror.work_changed.connect(_on_work_changed)
	# A join fragment replaces the whole mirror and emits only `changed` (and
	# `structure_added` for what it holds), not `structure_removed` for what
	# it dropped: free those nodes here.
	_mirror.changed.connect(_prune)
	for structure_id: String in _mirror.structure_ids():
		_upsert(structure_id)


func visual_of(structure_id: String) -> Node3D:
	return _nodes.get(structure_id, null)


func count() -> int:
	return _nodes.size()


func _upsert(structure_id: String) -> void:
	var entry: Dictionary = _mirror.get_structure(structure_id)
	if entry.is_empty():
		_remove(structure_id)
		return
	var definition: StructureDefinition = _catalog.get_definition(str(entry[ClientStructureState.KEY_DEFINITION_ID]))
	if definition == null:
		return
	_remove(structure_id)
	var node: Node3D = Node3D.new()
	node.name = "Structure_" + structure_id
	var slot: Vector3i = _mirror.slot_of(structure_id)
	node.position = _grid.slot_anchor(slot)
	var body: MeshInstance3D = MeshInstance3D.new()
	body.name = BODY_NAME
	var mesh: BoxMesh = BoxMesh.new()
	var visual_height: float = _settings.structure_wall_height_m
	if definition.visual_size_m != Vector3.ZERO:
		mesh.size = definition.visual_size_m
		body.position.y = definition.visual_size_m.y * 0.5
		visual_height = definition.visual_size_m.y
	elif definition.placement == StructureDefinition.Placement.TILE:
		mesh.size = Vector3(_grid.module_m * _settings.structure_floor_scale, _settings.structure_floor_height_m, _grid.module_m * _settings.structure_floor_scale)
		body.position.y = _settings.structure_floor_height_m * 0.5
		visual_height = _settings.structure_floor_height_m
	else:
		mesh.size = Vector3(_grid.module_m * _settings.structure_edge_scale, _settings.structure_wall_height_m, _settings.structure_wall_thickness_m if not definition.is_door else _settings.structure_door_thickness_m)
		body.position.y = _settings.structure_wall_height_m * 0.5
		if slot.z == StructureGrid.Layer.EDGE_LOW_X:
			body.rotation.y = PI * 0.5
		if definition.is_door and bool(entry[ClientStructureState.KEY_DOOR_OPEN]):
			body.rotation.y += PI * 0.5
	body.mesh = mesh
	var material: StandardMaterial3D = StandardMaterial3D.new()
	var state: String = str(entry[ClientStructureState.KEY_STATE])
	var complete: bool = state == "completed" or state == "damaged"
	material.albedo_color = _settings.structure_completed_color if complete else _settings.structure_blueprint_color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if material.albedo_color.a < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	body.material_override = material
	node.add_child(body)
	if not complete:
		var label: Label3D = Label3D.new()
		label.name = LABEL_NAME
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position.y = visual_height + _settings.structure_label_margin_m
		label.pixel_size = _settings.structure_label_pixel_size
		label.font_size = _settings.structure_label_font_size
		label.modulate = _settings.structure_label_color
		label.text = "%s · %d%% · 작업자 %d명" % [StructurePresentationFormatter.material_text(entry[ClientStructureState.KEY_REQUIRED], entry[ClientStructureState.KEY_DELIVERED], _items), roundi(float(entry[ClientStructureState.KEY_PROGRESS]) * 100.0), _mirror.workers_of(structure_id).size()]
		node.add_child(label)
	_root.add_child(node)
	_nodes[structure_id] = node


func _remove(structure_id: String) -> void:
	var node: Node3D = _nodes.get(structure_id, null)
	if node != null:
		node.free()
	_nodes.erase(structure_id)


## Frees the node of every structure the mirror no longer holds.
func _prune() -> void:
	for structure_id: String in _nodes.keys():
		if not _mirror.has_structure(structure_id):
			_remove(structure_id)


func _on_work_changed(_player_id: String, structure_id: String, _working: bool, _reason: String) -> void:
	if _mirror.has_structure(structure_id):
		_upsert(structure_id)
