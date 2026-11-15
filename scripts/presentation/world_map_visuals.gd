class_name WorldMapVisuals
extends RefCounted
## Client-only placeholder map (P3-2, docs/09 §15.2): a flat ground as large
## as the map the server described, four walls marking its edges and, for
## testing, an overlay that draws the borders and ids of the cells around the
## local player. Everything is built from ClientWorldMap (the server's
## layout) and ClientPresentationSettings (looks only). Presentation only:
## it decides nothing. Geometry: WorldMapPresentation.

## Node names inside the root.
const GROUND_NODE: String = "Ground"
const EDGES_NODE: String = "Edges"
const OVERLAY_NODE: String = "CellOverlay"
const OVERLAY_LINES_NODE: String = "Borders"
const OVERLAY_LABELS_NODE: String = "Labels"
const LABEL_PREFIX: String = "CellLabel_"

var _root: Node3D
var _settings: ClientPresentationSettings
var _ground: MeshInstance3D = null
var _edges: Node3D = null
var _overlay: Node3D = null
var _overlay_lines: MeshInstance3D = null
var _overlay_labels: Node3D = null
var _ground_material: StandardMaterial3D = StandardMaterial3D.new()
var _edge_material: StandardMaterial3D = StandardMaterial3D.new()
var _overlay_material: StandardMaterial3D = StandardMaterial3D.new()
## The layout the ground and the edges were last built from.
var _map_key: String = ""
## The cell the overlay was last built around ("" = not built).
var _overlay_key: String = ""
var _overlay_wanted: bool = false


## `root` is the node the map is added to; it must outlive this object or
## be freed together with its children.
func _init(root: Node3D, settings: ClientPresentationSettings) -> void:
	_root = root
	_settings = settings
	_ground_material.albedo_color = settings.map_ground_color
	_edge_material.albedo_color = settings.map_edge_color
	_overlay_material.albedo_color = settings.cell_overlay_color
	_overlay_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_overlay_wanted = settings.cell_overlay_initially_visible


## Makes the ground and the edges match the layout the server sent; without
## a layout (not joined, or a refused fragment) nothing is shown.
func sync(map: ClientWorldMap) -> void:
	if not is_instance_valid(_root):
		return
	var key: String = "%s|%s|%s" % [str(map.cell_size_m), str(map.bounds_min), str(map.bounds_max)] if map != null and map.is_known() else ""
	if key == _map_key:
		return
	_map_key = key
	_overlay_key = ""
	_free_children()
	if key.is_empty():
		return
	var ground: Dictionary = WorldMapPresentation.ground(map.bounds_min, map.bounds_max)
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = ground[WorldMapPresentation.KEY_SIZE]
	_ground = MeshInstance3D.new()
	_ground.name = GROUND_NODE
	_ground.mesh = plane
	_ground.material_override = _ground_material
	_ground.position = ground[WorldMapPresentation.KEY_POSITION]
	_root.add_child(_ground)
	_edges = Node3D.new()
	_edges.name = EDGES_NODE
	_root.add_child(_edges)
	for box: Dictionary in WorldMapPresentation.edge_boxes(map.bounds_min, map.bounds_max, _settings.map_edge_height_m, _settings.map_edge_thickness_m):
		var mesh: BoxMesh = BoxMesh.new()
		mesh.size = box[WorldMapPresentation.KEY_SIZE]
		var wall: MeshInstance3D = MeshInstance3D.new()
		wall.name = str(box[WorldMapPresentation.KEY_NAME])
		wall.mesh = mesh
		wall.material_override = _edge_material
		wall.position = box[WorldMapPresentation.KEY_POSITION]
		_edges.add_child(wall)
	_overlay = Node3D.new()
	_overlay.name = OVERLAY_NODE
	_overlay.visible = _overlay_wanted
	_root.add_child(_overlay)
	_overlay_lines = MeshInstance3D.new()
	_overlay_lines.name = OVERLAY_LINES_NODE
	_overlay_lines.material_override = _overlay_material
	_overlay.add_child(_overlay_lines)
	_overlay_labels = Node3D.new()
	_overlay_labels.name = OVERLAY_LABELS_NODE
	_overlay.add_child(_overlay_labels)


## Shows or hides the cell overlay (the debug key).
func set_overlay_visible(visible: bool) -> void:
	_overlay_wanted = visible
	if is_instance_valid(_overlay):
		_overlay.visible = visible


## True when the overlay is switched on (it shows once a layout is known).
func is_overlay_visible() -> bool:
	return _overlay_wanted


## Rebuilds the overlay around the cell the local player is in, when it is
## switched on and that cell changed since it was last built.
func update_overlay(map: ClientWorldMap, position: Vector3) -> void:
	if not _overlay_wanted or map == null or not map.is_known() or not is_instance_valid(_overlay):
		return
	var center: Vector2i = map.grid.cell_of(position)
	var key: String = WorldCellGrid.id_of(center)
	if key == _overlay_key:
		return
	_overlay_key = key
	var radius: int = _settings.cell_overlay_radius_cells
	var points: PackedVector3Array = WorldMapPresentation.cell_border_segments(map.grid, map.bounds_min, map.bounds_max, center, radius, _settings.cell_overlay_height_m)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	var mesh: ArrayMesh = ArrayMesh.new()
	if not points.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_overlay_lines.mesh = mesh
	for child: Node in _overlay_labels.get_children():
		_overlay_labels.remove_child(child)
		child.queue_free()
	for entry: Dictionary in WorldMapPresentation.cell_labels(map.grid, map.bounds_min, map.bounds_max, center, radius, _settings.cell_overlay_label_height_m):
		var label: Label3D = Label3D.new()
		label.name = LABEL_PREFIX + str(entry[WorldMapPresentation.KEY_TEXT])
		label.text = str(entry[WorldMapPresentation.KEY_TEXT])
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.pixel_size = _settings.cell_overlay_label_pixel_size
		label.font_size = _settings.cell_overlay_label_font_size
		label.modulate = _settings.cell_overlay_color
		label.position = entry[WorldMapPresentation.KEY_POSITION]
		_overlay_labels.add_child(label)


## The ground node, or null while no layout is known (tests).
func ground_node() -> MeshInstance3D:
	return _ground if is_instance_valid(_ground) else null


## Number of segments of the overlay as it was last built.
func overlay_segment_count() -> int:
	if not is_instance_valid(_overlay_lines) or _overlay_lines.mesh == null or _overlay_lines.mesh.get_surface_count() == 0:
		return 0
	# Two points per segment.
	return (_overlay_lines.mesh as ArrayMesh).surface_get_array_len(0) >> 1


func _free_children() -> void:
	for child: Node in _root.get_children():
		_root.remove_child(child)
		child.queue_free()
	_ground = null
	_edges = null
	_overlay = null
	_overlay_lines = null
	_overlay_labels = null
