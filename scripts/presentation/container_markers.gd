class_name ContainerMarkers
extends RefCounted
## Batched client-only container bodies, split by searched material.

const UNSEARCHED_BATCH_NODE: String = "UnsearchedContainerBodies"
const SEARCHED_BATCH_NODE: String = "SearchedContainerBodies"
const MARKER_PREFIX: String = "Container_"
const LABEL_NODE: String = "Label"

var _root: Node3D
var _catalog: ContainerCatalog
var _settings: ClientPresentationSettings
var _batches: Dictionary[bool, MultiMeshInstance3D] = {}
var _entries: Dictionary[String, Dictionary] = {}
var _transforms: Dictionary[String, Transform3D] = {}
var _labels: Dictionary[String, Node3D] = {}
var _focus: Vector3 = Vector3.ZERO
var _mesh: BoxMesh = BoxMesh.new()


func _init(root: Node3D, catalog: ContainerCatalog, settings: ClientPresentationSettings) -> void:
	_root = root
	_catalog = catalog
	_settings = settings
	_mesh.size = Vector3.ONE * settings.container_marker_size_m
	_make_batch(false, UNSEARCHED_BATCH_NODE, settings.container_marker_color)
	_make_batch(true, SEARCHED_BATCH_NODE, settings.container_searched_marker_color)


func sync(containers: Dictionary, focus: Vector3 = Vector3.ZERO) -> void:
	_focus = focus
	_entries.clear()
	_transforms.clear()
	var ids_by_kind: Dictionary[bool, PackedStringArray] = {false: PackedStringArray(), true: PackedStringArray()}
	for container_id: Variant in containers:
		if typeof(container_id) != TYPE_STRING or not _is_drawable(containers[container_id]):
			continue
		var entry: Dictionary = (containers[container_id] as Dictionary).duplicate()
		_entries[container_id] = entry
		ids_by_kind[entry.get(ClientContainerState.KEY_SEARCHED, false) == true].append(container_id)
	for searched: bool in ids_by_kind:
		var ids: PackedStringArray = ids_by_kind[searched]
		ids.sort()
		var multimesh: MultiMesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = _mesh
		multimesh.instance_count = ids.size()
		for index: int in range(ids.size()):
			var position: Vector3 = _entries[ids[index]][ClientContainerState.KEY_POSITION]
			var transform := Transform3D(Basis.IDENTITY, position + Vector3.UP * (_settings.container_marker_size_m * 0.5))
			multimesh.set_instance_transform(index, transform)
			_transforms[ids[index]] = transform
		_batches[searched].multimesh = multimesh
	_update_labels()


func update_focus(focus: Vector3) -> void:
	if focus.distance_squared_to(_focus) < 0.0625:
		return
	_focus = focus
	_update_labels()


func marker_count() -> int:
	return _entries.size()


func body_instance_count() -> int:
	return (_batches[false].multimesh.instance_count if _batches[false].multimesh != null else 0) + (_batches[true].multimesh.instance_count if _batches[true].multimesh != null else 0)


func label_count() -> int:
	return _labels.size()


func has_marker(container_id: String) -> bool:
	return _entries.has(container_id)


func transform_of(container_id: String) -> Transform3D:
	return _transforms.get(container_id, Transform3D())


func label_of(container_id: String) -> Label3D:
	var anchor: Node3D = _labels.get(container_id, null)
	return anchor.get_node(LABEL_NODE) as Label3D if anchor != null else null


func _make_batch(searched: bool, node_name: String, color: Color) -> void:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	var batch: MultiMeshInstance3D = MultiMeshInstance3D.new()
	batch.name = node_name
	batch.material_override = material
	_root.add_child(batch)
	_batches[searched] = batch


func _update_labels() -> void:
	var max_distance_sq: float = _settings.container_label_distance_m * _settings.container_label_distance_m
	for container_id: String in _labels.keys():
		var position: Vector3 = _entries.get(container_id, {}).get(ClientContainerState.KEY_POSITION, Vector3.INF)
		if not _entries.has(container_id) or position.distance_squared_to(_focus) > max_distance_sq:
			_labels[container_id].free()
			_labels.erase(container_id)
	for container_id: String in _entries:
		var entry: Dictionary = _entries[container_id]
		var position: Vector3 = entry[ClientContainerState.KEY_POSITION]
		if position.distance_squared_to(_focus) > max_distance_sq:
			continue
		var anchor: Node3D = _labels.get(container_id, null)
		if anchor == null:
			anchor = _make_label(container_id)
			_root.add_child(anchor)
			_labels[container_id] = anchor
		anchor.position = position
		(anchor.get_node(LABEL_NODE) as Label3D).text = ClientPresentationFormatter.container_label(entry, _catalog)


func _is_drawable(entry: Variant) -> bool:
	if typeof(entry) != TYPE_DICTIONARY:
		return false
	var position: Variant = (entry as Dictionary).get(ClientContainerState.KEY_POSITION, null)
	return typeof(position) == TYPE_VECTOR3 and (position as Vector3).is_finite() and not ClientPresentationFormatter.container_label(entry as Dictionary, _catalog).is_empty()


func _make_label(container_id: String) -> Node3D:
	var anchor: Node3D = Node3D.new()
	anchor.name = MARKER_PREFIX + container_id
	var label: Label3D = Label3D.new()
	label.name = LABEL_NODE
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = _settings.container_label_pixel_size
	label.font_size = _settings.container_label_font_size
	label.modulate = _settings.container_label_color
	label.position = Vector3.UP * (_settings.container_marker_size_m + _settings.container_label_margin_m)
	anchor.add_child(label)
	return anchor
