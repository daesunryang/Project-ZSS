class_name ContainerMarkers
extends RefCounted
## Client-only placeholder visuals of the containers standing in the world
## (P3-3, docs/09 §15.3): one marker per mirrored container, a box with a
## label above it (the container's name, and whether it was searched).
## Markers are created, updated and removed as the mirror changes.
## Presentation only: it reads the mirror and decides nothing.

## Node names inside the root: "Container_<container id>" with the children
## below.
const MARKER_PREFIX: String = "Container_"
const BODY_NODE: String = "Body"
const LABEL_NODE: String = "Label"

var _root: Node3D
var _catalog: ContainerCatalog
var _settings: ClientPresentationSettings
## container_id -> its marker node.
var _markers: Dictionary[String, Node3D] = {}
## container_id -> what the marker was last built from.
var _keys: Dictionary[String, String] = {}
var _mesh: BoxMesh = BoxMesh.new()
var _unsearched_material: StandardMaterial3D = StandardMaterial3D.new()
var _searched_material: StandardMaterial3D = StandardMaterial3D.new()


## `root` is the node the markers are added to; it must outlive this object
## or be freed together with its children.
func _init(root: Node3D, catalog: ContainerCatalog, settings: ClientPresentationSettings) -> void:
	_root = root
	_catalog = catalog
	_settings = settings
	_mesh.size = Vector3.ONE * settings.container_marker_size_m
	_unsearched_material.albedo_color = settings.container_marker_color
	_searched_material.albedo_color = settings.container_searched_marker_color


## Makes the markers match `containers` (the mirror
## ClientContainerState.containers: {container_id: {definition_id, position,
## searched}}). Rows that are no containers get no marker.
func sync(containers: Dictionary) -> void:
	if not is_instance_valid(_root):
		return
	for existing_id: String in _markers.keys():
		if not containers.has(existing_id) or not _is_drawable(containers[existing_id]):
			# Out of the tree at once (queue_free alone keeps the node, and its
			# name, until the end of the frame).
			_root.remove_child(_markers[existing_id])
			_markers[existing_id].queue_free()
			_markers.erase(existing_id)
			_keys.erase(existing_id)
	for container_id: Variant in containers:
		if typeof(container_id) != TYPE_STRING or not _is_drawable(containers[container_id]):
			continue
		var entry: Dictionary = containers[container_id]
		var label_text: String = ClientPresentationFormatter.container_label(entry, _catalog)
		var position: Vector3 = entry[ClientContainerState.KEY_POSITION]
		var searched: bool = entry.get(ClientContainerState.KEY_SEARCHED, false) == true
		var key: String = "%s|%s|%s" % [label_text, str(position), str(searched)]
		if _keys.get(container_id, "") == key:
			continue
		var marker: Node3D = _markers.get(container_id, null)
		if marker == null:
			marker = _make_marker(container_id)
			_root.add_child(marker)
			_markers[container_id] = marker
		_keys[container_id] = key
		marker.position = position
		(marker.get_node(BODY_NODE) as MeshInstance3D).material_override = _searched_material if searched else _unsearched_material
		(marker.get_node(LABEL_NODE) as Label3D).text = label_text


func marker_count() -> int:
	return _markers.size()


## The marker node of a container, or null.
func marker_of(container_id: String) -> Node3D:
	return _markers.get(container_id, null)


func _is_drawable(entry: Variant) -> bool:
	if typeof(entry) != TYPE_DICTIONARY:
		return false
	var position: Variant = (entry as Dictionary).get(ClientContainerState.KEY_POSITION, null)
	if typeof(position) != TYPE_VECTOR3 or not (position as Vector3).is_finite():
		return false
	return not ClientPresentationFormatter.container_label(entry as Dictionary, _catalog).is_empty()


## A box standing on the ground and a billboard label above it.
func _make_marker(container_id: String) -> Node3D:
	var marker: Node3D = Node3D.new()
	marker.name = MARKER_PREFIX + container_id
	var body: MeshInstance3D = MeshInstance3D.new()
	body.name = BODY_NODE
	body.mesh = _mesh
	body.position = Vector3.UP * (_settings.container_marker_size_m * 0.5)
	marker.add_child(body)
	var label: Label3D = Label3D.new()
	label.name = LABEL_NODE
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = _settings.container_label_pixel_size
	label.font_size = _settings.container_label_font_size
	label.modulate = _settings.container_label_color
	label.position = Vector3.UP * (_settings.container_marker_size_m + _settings.container_label_margin_m)
	marker.add_child(label)
	return marker
