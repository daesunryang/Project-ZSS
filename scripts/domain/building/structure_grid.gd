class_name StructureGrid
extends RefCounted
## The building grid (P3-4a, docs/04 §2, docs/00 ADR-024): tiles, tile
## edges, rotation, and the movement trace against blocking edges. Pure
## math, no state besides the module size; no nodes.
##
## Tiles. World positions stay world-origin based. Tile (tx, tz) covers
## [tx * m, (tx + 1) * m) on X and on Z (height is ignored), so negative
## coordinates round down, exactly like world cells (WorldCellGrid).
##
## Slots. A structure takes one slot, a Vector3i(x, z, layer):
##   TILE        the tile (x, z) itself                       (floors)
##   EDGE_LOW_X  the side of tile (x, z) with the smaller x:
##               the segment x = x * m, z in [z * m, (z + 1) * m]
##   EDGE_LOW_Z  the side of tile (x, z) with the smaller z:
##               the segment z = z * m, x in [x * m, (x + 1) * m]
## Every edge between two tiles has exactly one slot (it is the low side of
## the tile with the larger coordinate), so two pieces can never stand on
## the same edge from its two sides.
##
## Rotation is a number of quarter turns, 0..3. An edge piece is placed on
## a tile and its rotation names the side of that tile it stands on:
##   0  the -Z side    1  the +X side    2  the +Z side    3  the -X side
## (SIDE_DIRECTIONS). For a tile piece the rotation is only its facing.
##
## Movement (resolve_step). Movers are points and blocking edges are thin
## segments. A step from A to B is walked through the tiles it crosses
## (only those are looked at); every time it leaves a tile through an edge,
## that edge is looked up in the set of blocking edges. So a step can never
## skip a wall, however long it is. A step that passes exactly through a
## grid corner is blocked when both ways around the corner are blocked. A
## point exactly on a grid line is in the tile with the larger coordinate.
## A mover that runs into an edge stops `skin_m` in front of it; one that is
## already closer stays where it is. It never ends on the far side.

enum Layer { TILE = 0, EDGE_LOW_X = 1, EDGE_LOW_Z = 2 }

const ROTATION_COUNT: int = 4
## Tile direction (x, z) of the side an edge piece stands on, by rotation.
const SIDE_DIRECTIONS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
## Largest |tile coordinate| the grid works with (keys and float math stay
## exact far beyond any map).
const MAX_TILE_COORD: int = 1000000
## Float tolerance when a tile is compared with the play area, metres.
const BOUNDS_EPSILON_M: float = 0.0001
## Two crossing times closer than this (as a fraction of the step) are the
## same crossing: the step goes through a grid corner.
const TIE_TOLERANCE: float = 1.0e-9

const _KEY_OFFSET: int = 1 << 20
const _KEY_X_SHIFT: int = 23
const _KEY_Z_SHIFT: int = 2
const _HIT_NONE: int = 0
const _HIT_X: int = 1
const _HIT_Z: int = 2
const _HIT_CORNER: int = 3

var module_m: float

## Result of the last _trace() that hit something (scratch, not state).
var _hit_time: float = 0.0
var _hit_line_x: float = 0.0
var _hit_line_z: float = 0.0
var _hit_step_x: int = 0
var _hit_step_z: int = 0
var _stop_x: float = 0.0
var _stop_z: float = 0.0


func _init(grid_module_m: float = 1.0) -> void:
	module_m = grid_module_m


# ------------------------------------------------------------ tiles and slots

## Tile of a world position.
func tile_of(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / module_m), floori(position.z / module_m))


func tile_center(tile: Vector2i) -> Vector3:
	return Vector3((float(tile.x) + 0.5) * module_m, 0.0, (float(tile.y) + 0.5) * module_m)


static func is_valid_rotation(rotation: int) -> bool:
	return rotation >= 0 and rotation < ROTATION_COUNT


static func is_valid_tile(tile: Vector2i) -> bool:
	return absi(tile.x) <= MAX_TILE_COORD and absi(tile.y) <= MAX_TILE_COORD


## The slot a piece with this placement (StructureDefinition.Placement)
## takes when it is placed on `tile` with `rotation`.
static func slot_of(placement: int, tile: Vector2i, rotation: int) -> Vector3i:
	if placement != StructureDefinition.Placement.EDGE:
		return Vector3i(tile.x, tile.y, Layer.TILE)
	match rotation:
		0:
			return Vector3i(tile.x, tile.y, Layer.EDGE_LOW_Z)
		1:
			return Vector3i(tile.x + 1, tile.y, Layer.EDGE_LOW_X)
		2:
			return Vector3i(tile.x, tile.y + 1, Layer.EDGE_LOW_Z)
		_:
			return Vector3i(tile.x, tile.y, Layer.EDGE_LOW_X)


## One integer per slot (dictionary key).
static func slot_key(slot: Vector3i) -> int:
	return ((slot.x + _KEY_OFFSET) << _KEY_X_SHIFT) | ((slot.y + _KEY_OFFSET) << _KEY_Z_SHIFT) | slot.z


## Where a slot is: the centre of a tile slot, the middle of an edge slot.
## Distances to a structure are measured to this point.
func slot_anchor(slot: Vector3i) -> Vector3:
	match slot.z:
		Layer.EDGE_LOW_X:
			return Vector3(float(slot.x) * module_m, 0.0, (float(slot.y) + 0.5) * module_m)
		Layer.EDGE_LOW_Z:
			return Vector3((float(slot.x) + 0.5) * module_m, 0.0, float(slot.y) * module_m)
	return tile_center(Vector2i(slot.x, slot.y))


## Centre of the tile a slot is named after. It decides which world cell a
## structure belongs to, so one slot always belongs to one cell (an edge on
## a cell border belongs to the cell on its high side).
func slot_home(slot: Vector3i) -> Vector3:
	return tile_center(Vector2i(slot.x, slot.y))


## The two ends of an edge slot on the XZ plane (x, z).
func edge_ends(slot: Vector3i) -> PackedVector2Array:
	var corner: Vector2 = Vector2(float(slot.x) * module_m, float(slot.y) * module_m)
	if slot.z == Layer.EDGE_LOW_X:
		return PackedVector2Array([corner, corner + Vector2(0.0, module_m)])
	return PackedVector2Array([corner, corner + Vector2(module_m, 0.0)])


## Flat (XZ) distance from a position to an edge slot's segment.
func distance_to_edge(position: Vector3, slot: Vector3i) -> float:
	var ends: PackedVector2Array = edge_ends(slot)
	var point: Vector2 = Vector2(position.x, position.z)
	var along: Vector2 = ends[1] - ends[0]
	var t: float = clampf((point - ends[0]).dot(along) / along.length_squared(), 0.0, 1.0)
	return point.distance_to(ends[0] + along * t)


## Flat (XZ) distance between two positions.
static func flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## True when the whole tile lies inside the square play area of
## `half_extent_m` around the origin.
func is_tile_inside(tile: Vector2i, half_extent_m: float) -> bool:
	if not is_valid_tile(tile):
		return false
	var limit: float = half_extent_m + BOUNDS_EPSILON_M
	return float(tile.x) * module_m >= -limit and float(tile.x + 1) * module_m <= limit and float(tile.y) * module_m >= -limit and float(tile.y + 1) * module_m <= limit


# ------------------------------------------------------------ movement

## Where a straight step from `from` to `to` ends when the edges in
## `blocking` ({slot_key: true}, edge slots only) cannot be crossed:
##   - nothing in the way: `to`, unchanged;
##   - otherwise the point on the step `skin_m` in front of the first
##     blocking edge, or its start when the mover is already closer than
##     that (a mover is never pushed back and never passes the edge);
##   - with `slide`, the rest of the step goes on along that edge (its
##     component parallel to the edge) until it is done or blocked again.
## Height is taken from `to`. Cost: the tiles the step crosses.
func resolve_step(from: Vector3, to: Vector3, blocking: Dictionary[int, bool], skin_m: float, slide: bool) -> Vector3:
	if blocking.is_empty():
		return to
	if not from.is_finite() or not to.is_finite():
		return from
	var from_x: float = from.x
	var from_z: float = from.z
	var hit: int = _trace(from_x, from_z, to.x, to.z, blocking)
	if hit == _HIT_NONE:
		return to
	_find_stop(hit, from_x, from_z, to.x, to.z, skin_m)
	# Positions are stored as 32-bit floats: the rounded stop point must still
	# be reachable. If rounding carried it across a blocked edge, stay put.
	var stop_x: float = _stored(_stop_x)
	var stop_z: float = _stored(_stop_z)
	if _trace(from_x, from_z, stop_x, stop_z, blocking) != _HIT_NONE:
		return Vector3(from_x, to.y, from_z)
	if not slide or hit == _HIT_CORNER:
		return Vector3(stop_x, to.y, stop_z)
	# Slide: keep the coordinate across the edge, finish the other one.
	var slide_x: float = stop_x if hit == _HIT_X else to.x
	var slide_z: float = stop_z if hit == _HIT_Z else to.z
	var second: int = _trace(stop_x, stop_z, slide_x, slide_z, blocking)
	if second == _HIT_NONE:
		return Vector3(slide_x, to.y, slide_z)
	_find_stop(second, stop_x, stop_z, slide_x, slide_z, skin_m)
	var end_x: float = _stored(_stop_x)
	var end_z: float = _stored(_stop_z)
	if _trace(stop_x, stop_z, end_x, end_z, blocking) != _HIT_NONE:
		return Vector3(stop_x, to.y, stop_z)
	return Vector3(end_x, to.y, end_z)


## True when a straight step from `from` to `to` crosses a blocking edge.
func is_step_blocked(from: Vector3, to: Vector3, blocking: Dictionary[int, bool]) -> bool:
	if blocking.is_empty() or not from.is_finite() or not to.is_finite():
		return false
	return _trace(from.x, from.z, to.x, to.z, blocking) != _HIT_NONE


## Walks the tiles from (fx, fz) to (tx, tz) and returns what stopped the
## walk (_HIT_*). On a hit the crossing is left in the _hit_* fields.
func _trace(fx: float, fz: float, tx: float, tz: float, blocking: Dictionary[int, bool]) -> int:
	var cx: int = floori(fx / module_m)
	var cz: int = floori(fz / module_m)
	var ex: int = floori(tx / module_m)
	var ez: int = floori(tz / module_m)
	if cx == ex and cz == ez:
		return _HIT_NONE
	var dx: float = tx - fx
	var dz: float = tz - fz
	var step_x: int = 1 if ex > cx else -1
	var step_z: int = 1 if ez > cz else -1
	# Every pass moves one tile closer to the end tile on at least one axis.
	while cx != ex or cz != ez:
		# The grid lines the walk meets next: index and crossing time (0..1).
		var line_x: int = cx + 1 if step_x > 0 else cx
		var line_z: int = cz + 1 if step_z > 0 else cz
		var time_x: float = (float(line_x) * module_m - fx) / dx if cx != ex else INF
		var time_z: float = (float(line_z) * module_m - fz) / dz if cz != ez else INF
		if cx != ex and cz != ez and absf(time_x - time_z) <= TIE_TOLERANCE:
			# Through the corner (line_x, line_z): blocked only when neither way
			# around it is open (x first, or z first).
			var x_first: bool = blocking.has(_edge_key(line_x, cz, Layer.EDGE_LOW_X)) or blocking.has(_edge_key(cx + step_x, line_z, Layer.EDGE_LOW_Z))
			var z_first: bool = blocking.has(_edge_key(cx, line_z, Layer.EDGE_LOW_Z)) or blocking.has(_edge_key(line_x, cz + step_z, Layer.EDGE_LOW_X))
			if x_first and z_first:
				return _record_hit(_HIT_CORNER, minf(time_x, time_z), line_x, line_z, step_x, step_z)
			cx += step_x
			cz += step_z
		elif time_x < time_z:
			if blocking.has(_edge_key(line_x, cz, Layer.EDGE_LOW_X)):
				return _record_hit(_HIT_X, time_x, line_x, line_z, step_x, step_z)
			cx += step_x
		else:
			if blocking.has(_edge_key(cx, line_z, Layer.EDGE_LOW_Z)):
				return _record_hit(_HIT_Z, time_z, line_x, line_z, step_x, step_z)
			cz += step_z
	return _HIT_NONE


func _record_hit(hit: int, time: float, line_x: int, line_z: int, step_x: int, step_z: int) -> int:
	_hit_time = time
	_hit_line_x = float(line_x) * module_m
	_hit_line_z = float(line_z) * module_m
	_hit_step_x = step_x
	_hit_step_z = step_z
	return hit


## Leaves in _stop_x / _stop_z the point of the step (fx, fz) -> (tx, tz)
## that is `skin_m` in front of the edge(s) the last _trace() hit, or the
## start of the step when that is already closer. A mover is never pushed
## back: a step that ended just short of an edge without crossing it would
## otherwise jump back on the next one.
func _find_stop(hit: int, fx: float, fz: float, tx: float, tz: float, skin_m: float) -> void:
	var dx: float = tx - fx
	var dz: float = tz - fz
	var time: float = _hit_time
	if hit == _HIT_X or hit == _HIT_CORNER:
		var limit_x: float = _hit_line_x - skin_m if _hit_step_x > 0 else _hit_line_x + skin_m
		time = minf(time, (limit_x - fx) / dx)
	if hit == _HIT_Z or hit == _HIT_CORNER:
		var limit_z: float = _hit_line_z - skin_m if _hit_step_z > 0 else _hit_line_z + skin_m
		time = minf(time, (limit_z - fz) / dz)
	time = maxf(time, 0.0)
	_stop_x = fx + dx * time
	_stop_z = fz + dz * time


static func _edge_key(x: int, z: int, layer: int) -> int:
	return ((x + _KEY_OFFSET) << _KEY_X_SHIFT) | ((z + _KEY_OFFSET) << _KEY_Z_SHIFT) | layer


## The value a position component has once it is stored in a Vector3.
static func _stored(value: float) -> float:
	return Vector2(value, 0.0).x
