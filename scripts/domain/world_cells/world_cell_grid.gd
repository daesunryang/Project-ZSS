class_name WorldCellGrid
extends RefCounted
## Cell coordinates of the world (P3-1, docs/03 §3.1). Pure math, no state
## besides the grid itself; no nodes.
##
## World positions stay world-origin based. Cell (cx, cz) covers
## [cx * size, (cx + 1) * size) on X and on Z (height is ignored), so
## negative coordinates round down: x = -0.001 is in cell -1. Cells exist
## only inside the map bounds; a position on or beyond an edge of the map
## belongs to the edge cell, so every position has exactly one cell.
##
## Cell id: `cell_<cx>_<cz>` with plain decimal integers (`cell_-3_12`).
## It is stable (the save key and file name of a cell, docs/10 §3) and does
## not depend on the bounds, only on the cell size.

const CELL_ID_PREFIX: String = "cell_"
const CELL_ID_PATTERN: String = "^cell_(-?[0-9]{1,9})_(-?[0-9]{1,9})$"
const KEY_CELL_SIZE: String = "cell_size_m"
const KEY_BOUNDS_MIN: String = "bounds_min_m"
const KEY_BOUNDS_MAX: String = "bounds_max_m"

var cell_size_m: float
## First and last cell of the map (inclusive).
var min_cell: Vector2i
var max_cell: Vector2i

var _bounds_min: Vector2
var _bounds_max: Vector2


func _init(settings: WorldCellSettings = null) -> void:
	var source: WorldCellSettings = settings if settings != null else WorldCellSettings.new()
	cell_size_m = source.cell_size_m
	_bounds_min = source.bounds_min_m
	_bounds_max = source.bounds_max_m
	min_cell = Vector2i(floori(_bounds_min.x / cell_size_m), floori(_bounds_min.y / cell_size_m))
	max_cell = Vector2i(
		maxi(ceili(_bounds_max.x / cell_size_m) - 1, min_cell.x),
		maxi(ceili(_bounds_max.y / cell_size_m) - 1, min_cell.y),
	)


## Cell of a world position (always a cell of the map). A non-finite
## component counts as 0.
func cell_of(position: Vector3) -> Vector2i:
	var x: float = position.x if is_finite(position.x) else 0.0
	var z: float = position.z if is_finite(position.z) else 0.0
	return Vector2i(
		clampi(floori(x / cell_size_m), min_cell.x, max_cell.x),
		clampi(floori(z / cell_size_m), min_cell.y, max_cell.y),
	)


## Id of the cell a world position is in.
func cell_id_at(position: Vector3) -> String:
	return id_of(cell_of(position))


static func id_of(cell: Vector2i) -> String:
	return "%s%d_%d" % [CELL_ID_PREFIX, cell.x, cell.y]


## Cell coordinates for an id written by id_of(), or null when `cell_id` is
## not exactly such an id (no leading zeros, no "+", no "-0").
static func parse_id(cell_id: String) -> Variant:
	var found: RegExMatch = RegEx.create_from_string(CELL_ID_PATTERN).search(cell_id)
	if found == null:
		return null
	var cell: Vector2i = Vector2i(found.get_string(1).to_int(), found.get_string(2).to_int())
	return cell if id_of(cell) == cell_id else null


func contains_cell(cell: Vector2i) -> bool:
	return cell.x >= min_cell.x and cell.x <= max_cell.x and cell.y >= min_cell.y and cell.y <= max_cell.y


## True when `cell_id` is the id of a cell of this map.
func is_valid_cell_id(cell_id: String) -> bool:
	var cell: Variant = parse_id(cell_id)
	return cell != null and contains_cell(cell as Vector2i)


## True when the position is finite and inside the map bounds (edges count).
func contains_position(position: Vector3) -> bool:
	if not is_finite(position.x) or not is_finite(position.z):
		return false
	return position.x >= _bounds_min.x and position.x <= _bounds_max.x and position.z >= _bounds_min.y and position.z <= _bounds_max.y


## Corner of a cell with the smallest x and z (y = 0).
func cell_min_corner(cell: Vector2i) -> Vector3:
	return Vector3(float(cell.x) * cell_size_m, 0.0, float(cell.y) * cell_size_m)


func cell_center(cell: Vector2i) -> Vector3:
	return cell_min_corner(cell) + Vector3(cell_size_m * 0.5, 0.0, cell_size_m * 0.5)


func cell_count() -> int:
	return (max_cell.x - min_cell.x + 1) * (max_cell.y - min_cell.y + 1)


## Chebyshev distance between two cells: the number of cell steps when
## diagonal steps are allowed. Interest areas are squares of this distance.
static func distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## Cells of the map at most `radius` cells from `center` (a square, the
## centre included), sorted by x, then z. Empty for a negative radius.
func cells_within(center: Vector2i, radius: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if radius < 0:
		return cells
	for x: int in range(maxi(center.x - radius, min_cell.x), mini(center.x + radius, max_cell.x) + 1):
		for z: int in range(maxi(center.y - radius, min_cell.y), mini(center.y + radius, max_cell.y) + 1):
			cells.append(Vector2i(x, z))
	return cells


## Cells of the map exactly `radius` cells from `center` (radius 0: the
## centre itself, when it is on the map), sorted by x, then z.
func ring(center: Vector2i, radius: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for cell: Vector2i in cells_within(center, radius):
		if distance(cell, center) == radius:
			cells.append(cell)
	return cells


## The up to eight cells of the map next to `cell`.
func neighbours(cell: Vector2i) -> Array[Vector2i]:
	return ring(cell, 1)


## What decides which cell a position is in (JSON-safe). Two grids with the
## same signature partition the world the same way; a save remembers it
## (docs/09 §15.1).
func signature() -> Dictionary:
	return {
		KEY_CELL_SIZE: cell_size_m,
		KEY_BOUNDS_MIN: [_bounds_min.x, _bounds_min.y],
		KEY_BOUNDS_MAX: [_bounds_max.x, _bounds_max.y],
	}
