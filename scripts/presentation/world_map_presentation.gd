class_name WorldMapPresentation
extends RefCounted
## Pure geometry of the client's placeholder map (P3-2, docs/09 §15.2): where
## the ground, the map edges and the cell borders go. No nodes; everything is
## computed from the map layout the server sent (ClientWorldMap), never from
## the client's own settings files. WorldMapVisuals turns the results into
## meshes.

## Keys of the dictionaries returned below.
const KEY_NAME: String = "name"
const KEY_POSITION: String = "position"
const KEY_SIZE: String = "size"
const KEY_TEXT: String = "text"
## Names of the four edge walls, in the order edge_boxes() returns them.
const EDGE_NAMES: PackedStringArray = ["EdgeMinX", "EdgeMaxX", "EdgeMinZ", "EdgeMaxZ"]


## The flat ground: {position: Vector3 (its centre, y = 0), size: Vector2
## (width on x, depth on z)}. It covers the map rectangle exactly.
static func ground(bounds_min: Vector2, bounds_max: Vector2) -> Dictionary:
	var center: Vector2 = (bounds_min + bounds_max) * 0.5
	return {
		KEY_POSITION: Vector3(center.x, 0.0, center.y),
		KEY_SIZE: bounds_max - bounds_min,
	}


## Four walls standing just OUTSIDE the map rectangle (the inner face of a
## wall is the map edge), so the walkable area is not made smaller by them:
## [{name, position: Vector3 (centre), size: Vector3}, ...] in EDGE_NAMES
## order. The walls along z are longer by twice the thickness, so the
## corners are closed.
static func edge_boxes(bounds_min: Vector2, bounds_max: Vector2, height_m: float, thickness_m: float) -> Array[Dictionary]:
	var extent: Vector2 = bounds_max - bounds_min
	var center: Vector2 = (bounds_min + bounds_max) * 0.5
	var half: float = thickness_m * 0.5
	var y: float = height_m * 0.5
	var boxes: Array[Dictionary] = []
	boxes.append({KEY_NAME: EDGE_NAMES[0], KEY_POSITION: Vector3(bounds_min.x - half, y, center.y), KEY_SIZE: Vector3(thickness_m, height_m, extent.y)})
	boxes.append({KEY_NAME: EDGE_NAMES[1], KEY_POSITION: Vector3(bounds_max.x + half, y, center.y), KEY_SIZE: Vector3(thickness_m, height_m, extent.y)})
	boxes.append({KEY_NAME: EDGE_NAMES[2], KEY_POSITION: Vector3(center.x, y, bounds_min.y - half), KEY_SIZE: Vector3(extent.x + thickness_m * 2.0, height_m, thickness_m)})
	boxes.append({KEY_NAME: EDGE_NAMES[3], KEY_POSITION: Vector3(center.x, y, bounds_max.y + half), KEY_SIZE: Vector3(extent.x + thickness_m * 2.0, height_m, thickness_m)})
	return boxes


## The cells the overlay shows: the cells of the map within `radius_cells`
## of `center_cell` (a square), sorted by x, then z.
static func overlay_cells(grid: WorldCellGrid, center_cell: Vector2i, radius_cells: int) -> Array[Vector2i]:
	return grid.cells_within(center_cell, radius_cells)


## Border lines of the overlay cells at height `height_m`: pairs of points
## (segment start, segment end). Every border between or around the shown
## cells appears once; lines are cut off at the map rectangle (the last cell
## of a map whose size is no multiple of the cell size reaches beyond it).
static func cell_border_segments(grid: WorldCellGrid, bounds_min: Vector2, bounds_max: Vector2, center_cell: Vector2i, radius_cells: int, height_m: float) -> PackedVector3Array:
	var points: PackedVector3Array = []
	var cells: Array[Vector2i] = overlay_cells(grid, center_cell, radius_cells)
	if cells.is_empty():
		return points
	var first: Vector2i = cells[0]
	var last: Vector2i = cells[cells.size() - 1]
	var size: float = grid.cell_size_m
	var x_from: float = clampf(float(first.x) * size, bounds_min.x, bounds_max.x)
	var x_to: float = clampf(float(last.x + 1) * size, bounds_min.x, bounds_max.x)
	var z_from: float = clampf(float(first.y) * size, bounds_min.y, bounds_max.y)
	var z_to: float = clampf(float(last.y + 1) * size, bounds_min.y, bounds_max.y)
	# Lines of constant x (they run along z), then lines of constant z.
	for index: int in range(first.x, last.x + 2):
		var x: float = clampf(float(index) * size, bounds_min.x, bounds_max.x)
		points.append(Vector3(x, height_m, z_from))
		points.append(Vector3(x, height_m, z_to))
	for index: int in range(first.y, last.y + 2):
		var z: float = clampf(float(index) * size, bounds_min.y, bounds_max.y)
		points.append(Vector3(x_from, height_m, z))
		points.append(Vector3(x_to, height_m, z))
	return points


## One label per overlay cell: [{text: the cell id, position: the middle of
## the part of the cell that lies on the map, at `height_m`}, ...], in
## overlay_cells() order.
static func cell_labels(grid: WorldCellGrid, bounds_min: Vector2, bounds_max: Vector2, center_cell: Vector2i, radius_cells: int, height_m: float) -> Array[Dictionary]:
	var labels: Array[Dictionary] = []
	var size: float = grid.cell_size_m
	for cell: Vector2i in overlay_cells(grid, center_cell, radius_cells):
		var x_from: float = clampf(float(cell.x) * size, bounds_min.x, bounds_max.x)
		var x_to: float = clampf(float(cell.x + 1) * size, bounds_min.x, bounds_max.x)
		var z_from: float = clampf(float(cell.y) * size, bounds_min.y, bounds_max.y)
		var z_to: float = clampf(float(cell.y + 1) * size, bounds_min.y, bounds_max.y)
		labels.append({
			KEY_TEXT: WorldCellGrid.id_of(cell),
			KEY_POSITION: Vector3((x_from + x_to) * 0.5, height_m, (z_from + z_to) * 0.5),
		})
	return labels
