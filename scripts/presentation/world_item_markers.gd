class_name WorldItemMarkers
extends RefCounted
## Batched client-only placeholders for items lying in the world.

const BATCH_NODE: String = "WorldItemBodies"
const MARKER_PREFIX: String = "WorldItem_"
const LABEL_NODE: String = "Label"

var _root: Node3D
var _catalog: ItemCatalog
var _settings: ClientPresentationSettings
var _batch: MultiMeshInstance3D
var _entries: Dictionary[String, Dictionary] = {}
var _ids: PackedStringArray = []
var _transforms: Dictionary[String, Transform3D] = {}
var _labels: Dictionary[String, Node3D] = {}
var _focus: Vector3 = Vector3.ZERO
var _mesh: BoxMesh = BoxMesh.new()
var _material: StandardMaterial3D = StandardMaterial3D.new()


func _init(root: Node3D, catalog: ItemCatalog, settings: ClientPresentationSettings) -> void:
	_root = root
	_catalog = catalog
	_settings = settings
	_mesh.size = Vector3.ONE * settings.world_item_marker_size_m
	_material.albedo_color = settings.world_item_marker_color
	_batch = MultiMeshInstance3D.new()
	_batch.name = BATCH_NODE
	_batch.material_override = _material
	_root.add_child(_batch)


## Rebuilds one compact MultiMesh when the authoritative mirror changes.
func sync(world_items: Dictionary, focus: Vector3 = Vector3.ZERO) -> void:
	if not is_instance_valid(_root):
		return
	_focus = focus
	_entries.clear()
	_ids.clear()
	_transforms.clear()
	for item_id: Variant in world_items:
		if typeof(item_id) == TYPE_STRING and _is_drawable(world_items[item_id]):
			_entries[item_id] = (world_items[item_id] as Dictionary).duplicate()
			_ids.append(item_id)
	_ids.sort()
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _mesh
	multimesh.instance_count = _ids.size()
	for index: int in range(_ids.size()):
		var position: Vector3 = _entries[_ids[index]][ClientWorldState.KEY_POSITION]
		var transform := Transform3D(Basis.IDENTITY, position + Vector3.UP * (_settings.world_item_marker_size_m * 0.5))
		multimesh.set_instance_transform(index, transform)
		_transforms[_ids[index]] = transform
	_batch.multimesh = multimesh
	_update_labels()


## Updates distance-limited labels without touching the body MultiMesh.
func update_focus(focus: Vector3) -> void:
	if focus.distance_squared_to(_focus) < 0.0625:
		return
	_focus = focus
	_update_labels()


func marker_count() -> int:
	return _ids.size()


func body_instance_count() -> int:
	return _batch.multimesh.instance_count if _batch.multimesh != null else 0


func label_count() -> int:
	return _labels.size()


func has_marker(item_instance_id: String) -> bool:
	return _entries.has(item_instance_id)


func transform_of(item_instance_id: String) -> Transform3D:
	return _transforms.get(item_instance_id, Transform3D())


func label_of(item_instance_id: String) -> Label3D:
	var anchor: Node3D = _labels.get(item_instance_id, null)
	return anchor.get_node(LABEL_NODE) as Label3D if anchor != null else null


func _update_labels() -> void:
	var max_distance_sq: float = _settings.world_item_label_distance_m * _settings.world_item_label_distance_m
	for item_id: String in _labels.keys():
		var position: Vector3 = _entries.get(item_id, {}).get(ClientWorldState.KEY_POSITION, Vector3.INF)
		if not _entries.has(item_id) or position.distance_squared_to(_focus) > max_distance_sq:
			_labels[item_id].free()
			_labels.erase(item_id)
	for item_id: String in _ids:
		var entry: Dictionary = _entries[item_id]
		var position: Vector3 = entry[ClientWorldState.KEY_POSITION]
		if position.distance_squared_to(_focus) > max_distance_sq:
			continue
		var anchor: Node3D = _labels.get(item_id, null)
		if anchor == null:
			anchor = _make_label(item_id)
			_root.add_child(anchor)
			_labels[item_id] = anchor
		anchor.position = position
		(anchor.get_node(LABEL_NODE) as Label3D).text = ClientPresentationFormatter.world_item_label(entry, _catalog)


func _is_drawable(entry: Variant) -> bool:
	if typeof(entry) != TYPE_DICTIONARY:
		return false
	var position: Variant = (entry as Dictionary).get(ClientWorldState.KEY_POSITION, null)
	return typeof(position) == TYPE_VECTOR3 and (position as Vector3).is_finite() and not ClientPresentationFormatter.world_item_label(entry as Dictionary, _catalog).is_empty()


func _make_label(item_id: String) -> Node3D:
	var anchor: Node3D = Node3D.new()
	anchor.name = MARKER_PREFIX + item_id
	var label: Label3D = Label3D.new()
	label.name = LABEL_NODE
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = _settings.world_item_label_pixel_size
	label.font_size = _settings.world_item_label_font_size
	label.modulate = _settings.world_item_label_color
	label.position = Vector3.UP * (_settings.world_item_marker_size_m + _settings.world_item_label_margin_m)
	anchor.add_child(label)
	return anchor
