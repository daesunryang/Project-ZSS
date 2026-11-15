class_name WorldItemMarkers
extends RefCounted
## Client-only placeholder visuals of the items lying in the world (P2-T15,
## docs/09 §14.29): one marker per mirrored world item, a small box with a
## label (display name and quantity) above it. Markers are created, updated
## and removed as the mirror changes. Presentation only: it reads the mirror
## and decides nothing.

## Node names inside the root: "WorldItem_<item id>" with the children below.
const MARKER_PREFIX: String = "WorldItem_"
const BODY_NODE: String = "Body"
const LABEL_NODE: String = "Label"

var _root: Node3D
var _catalog: ItemCatalog
var _settings: ClientPresentationSettings
## item_instance_id -> its marker node.
var _markers: Dictionary[String, Node3D] = {}
## item_instance_id -> what the marker was last built from (the mirror
## changes many times a second; a marker is touched only when this differs).
var _keys: Dictionary[String, String] = {}
var _mesh: BoxMesh = BoxMesh.new()
var _material: StandardMaterial3D = StandardMaterial3D.new()


## `root` is the node the markers are added to; it must outlive this object
## or be freed together with its children.
func _init(root: Node3D, catalog: ItemCatalog, settings: ClientPresentationSettings) -> void:
	_root = root
	_catalog = catalog
	_settings = settings
	_mesh.size = Vector3.ONE * settings.world_item_marker_size_m
	_material.albedo_color = settings.world_item_marker_color


## Makes the markers match `world_items` (the mirror ClientWorldState.
## world_items: {item_instance_id: {definition_id, quantity, position}}).
## Rows that are no world items get no marker.
func sync(world_items: Dictionary) -> void:
	if not is_instance_valid(_root):
		return
	for existing_id: String in _markers.keys():
		if not world_items.has(existing_id) or not _is_drawable(world_items[existing_id]):
			# Out of the tree at once (queue_free alone keeps the node, and its
			# name, until the end of the frame).
			_root.remove_child(_markers[existing_id])
			_markers[existing_id].queue_free()
			_markers.erase(existing_id)
			_keys.erase(existing_id)
	for item_id: Variant in world_items:
		if typeof(item_id) != TYPE_STRING or not _is_drawable(world_items[item_id]):
			continue
		var entry: Dictionary = world_items[item_id]
		var label_text: String = ClientPresentationFormatter.world_item_label(entry, _catalog)
		var position: Vector3 = entry[ClientWorldState.KEY_POSITION]
		var key: String = "%s|%s" % [label_text, str(position)]
		if _keys.get(item_id, "") == key:
			continue
		var marker: Node3D = _markers.get(item_id, null)
		if marker == null:
			marker = _make_marker(item_id)
			_root.add_child(marker)
			_markers[item_id] = marker
		_keys[item_id] = key
		marker.position = position
		(marker.get_node(LABEL_NODE) as Label3D).text = label_text


func marker_count() -> int:
	return _markers.size()


## The marker node of an item, or null.
func marker_of(item_instance_id: String) -> Node3D:
	return _markers.get(item_instance_id, null)


func _is_drawable(entry: Variant) -> bool:
	if typeof(entry) != TYPE_DICTIONARY:
		return false
	var position: Variant = (entry as Dictionary).get(ClientWorldState.KEY_POSITION, null)
	if typeof(position) != TYPE_VECTOR3 or not (position as Vector3).is_finite():
		return false
	return not ClientPresentationFormatter.world_item_label(entry as Dictionary, _catalog).is_empty()


## A box standing on the ground and a billboard label above it.
func _make_marker(item_id: String) -> Node3D:
	var marker: Node3D = Node3D.new()
	marker.name = MARKER_PREFIX + item_id
	var body: MeshInstance3D = MeshInstance3D.new()
	body.name = BODY_NODE
	body.mesh = _mesh
	body.material_override = _material
	body.position = Vector3.UP * (_settings.world_item_marker_size_m * 0.5)
	marker.add_child(body)
	var label: Label3D = Label3D.new()
	label.name = LABEL_NODE
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = _settings.world_item_label_pixel_size
	label.font_size = _settings.world_item_label_font_size
	label.modulate = _settings.world_item_label_color
	label.position = Vector3.UP * (_settings.world_item_marker_size_m + _settings.world_item_label_margin_m)
	marker.add_child(label)
	return marker
