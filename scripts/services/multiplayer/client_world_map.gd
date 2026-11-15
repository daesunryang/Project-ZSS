class_name ClientWorldMap
extends RefCounted
## What the server told this client about the layout of the map (P3-2,
## docs/09 §15.2): the size of a world cell and the map rectangle. It comes
## with the join snapshot (module fragment of WorldCellNetModule) and never
## from the client's own settings files, so a client always draws the map of
## the server it is connected to. Pure data; never authoritative and never
## sent back to the server. Presentation reads it (ground, map edges, the
## cell the local player is in, the cell border overlay).
##
## Fragment (the server's WorldCellGrid.signature()):
##   {cell_size_m: float > 0, bounds_min_m: [x, z], bounds_max_m: [x, z]}
## with finite numbers, bounds_max > bounds_min on both axes and at most
## MAX_CELLS_PER_AXIS cells on an axis. Anything else is refused and the map
## stays unknown.

signal changed

const KEY_CELL_SIZE: String = WorldCellGrid.KEY_CELL_SIZE
const KEY_BOUNDS_MIN: String = WorldCellGrid.KEY_BOUNDS_MIN
const KEY_BOUNDS_MAX: String = WorldCellGrid.KEY_BOUNDS_MAX
## A client refuses a map with more cells on one axis than this.
const MAX_CELLS_PER_AXIS: int = 100000
const REASON_BAD_FRAGMENT: String = "bad_map_fragment"
const REASON_BAD_CELL_SIZE: String = "bad_cell_size"
const REASON_BAD_BOUNDS: String = "bad_bounds"
const REASON_TOO_MANY_CELLS: String = "too_many_cells"

## Edge of one square cell, metres (0 while the map is unknown).
var cell_size_m: float = 0.0
## Map rectangle on the XZ plane as (x, z), metres.
var bounds_min: Vector2 = Vector2.ZERO
var bounds_max: Vector2 = Vector2.ZERO
## The same cell math the server uses, built from the values above (null
## while the map is unknown).
var grid: WorldCellGrid = null


## True once a valid layout was received.
func is_known() -> bool:
	return grid != null


## Server: the fragment that describes `world_grid` to a client.
static func describe(world_grid: WorldCellGrid) -> Dictionary:
	return world_grid.signature() if world_grid != null else {}


## "" when `fragment` is a usable map layout, otherwise a reason code.
static func fragment_error(fragment: Variant) -> String:
	if typeof(fragment) != TYPE_DICTIONARY:
		return REASON_BAD_FRAGMENT
	var data: Dictionary = fragment
	if data.size() != 3:
		return REASON_BAD_FRAGMENT
	var size: Variant = data.get(KEY_CELL_SIZE, null)
	if not _is_number(size) or not is_finite(float(size)) or float(size) <= 0.0:
		return REASON_BAD_CELL_SIZE
	var corners: Array[Vector2] = []
	for key: String in [KEY_BOUNDS_MIN, KEY_BOUNDS_MAX]:
		var corner: Variant = data.get(key, null)
		if typeof(corner) != TYPE_ARRAY or (corner as Array).size() != 2:
			return REASON_BAD_BOUNDS
		for component: Variant in (corner as Array):
			if not _is_number(component) or not is_finite(float(component)):
				return REASON_BAD_BOUNDS
		corners.append(Vector2(float(corner[0]), float(corner[1])))
	if corners[1].x <= corners[0].x or corners[1].y <= corners[0].y:
		return REASON_BAD_BOUNDS
	var extent: Vector2 = corners[1] - corners[0]
	if extent.x / float(size) > float(MAX_CELLS_PER_AXIS) or extent.y / float(size) > float(MAX_CELLS_PER_AXIS):
		return REASON_TOO_MANY_CELLS
	return ""


## Takes the layout of a join fragment. Returns "" or the reason it was
## refused; a refused (or empty) fragment leaves the map unknown.
func apply(fragment: Dictionary) -> String:
	var reason: String = fragment_error(fragment)
	if not reason.is_empty():
		clear()
		return reason
	var settings: WorldCellSettings = WorldCellSettings.new()
	settings.cell_size_m = float(fragment[KEY_CELL_SIZE])
	settings.bounds_min_m = Vector2(float(fragment[KEY_BOUNDS_MIN][0]), float(fragment[KEY_BOUNDS_MIN][1]))
	settings.bounds_max_m = Vector2(float(fragment[KEY_BOUNDS_MAX][0]), float(fragment[KEY_BOUNDS_MAX][1]))
	cell_size_m = settings.cell_size_m
	bounds_min = settings.bounds_min_m
	bounds_max = settings.bounds_max_m
	grid = WorldCellGrid.new(settings)
	changed.emit()
	return ""


## Forgets the layout (the map is unknown again).
func clear() -> void:
	var was_known: bool = is_known()
	cell_size_m = 0.0
	bounds_min = Vector2.ZERO
	bounds_max = Vector2.ZERO
	grid = null
	if was_known:
		changed.emit()


## Id of the cell a position is in ("" while the map is unknown).
func cell_id_at(position: Vector3) -> String:
	return grid.cell_id_at(position) if grid != null else ""


## Width (x) and depth (z) of the map, metres.
func extent() -> Vector2:
	return bounds_max - bounds_min


## Centre of the map on the XZ plane as (x, z).
func center() -> Vector2:
	return (bounds_min + bounds_max) * 0.5


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT
