class_name ProceduralMapGenerator
extends RefCounted
## Makes the generated part of the map from one world seed (F-33, docs/09
## §15.3.1). Pure: no world, no nodes, no clock. The same seed, settings and
## world size give the same towns, roads and buildings, whichever cell is
## asked for first and whenever.
##
## Layout (original, not taken from any other game's map):
##   - A town is a disc of world cells around a street crossing (a cell
##     corner). Towns have different radii and keep free land between them.
##     One "home" town lies around the reserved square of the hand-made
##     starting town.
##   - Every cell border is a street: a strip of `road_half_width_m` on each
##     side of it stays empty, so a cell is one block and no building ever
##     crosses a cell border (a cell is generated without its neighbours).
##   - A built block is cut into a grid of lots; a lot gets one building of
##     an archetype of the block's zone that fits it, with a yard around it,
##     its door towards a street, interior walls with a door each, and
##     containers along its walls.
##   - Roads between towns run along cell borders too (an L from a town to
##     the nearest town made before it). Cells beside such a road can have
##     a farm; cells away from everything rarely have a lone building.
##   - Nothing is generated in the cells that touch the reserved square, nor
##     in a cell that is not wholly inside the play area.
##
## Whole-map work here is only the town list and the road cells (a few
## thousand dictionary entries); buildings are made per cell, on demand.

## Raised when the same seed would give another layout. A cell that was
## generated keeps what it got (ProceduralMapService records it).
const GENERATOR_VERSION: int = 1
## The map id in the source keys of generated containers.
const MAP_ID: String = "procedural"
const BUILDING_ID_PREFIX: String = "gen"

enum CellKind { OUTSIDE = 0, RESERVED = 1, TOWN = 2, ROADSIDE = 3, WILD = 4 }

## Keys of a town row (towns()).
const KEY_TOWN_INDEX: String = "index"
## The street crossing in the middle, in cells (a cell corner).
const KEY_TOWN_CORNER: String = "corner"
const KEY_TOWN_RADIUS_M: String = "radius_m"
const KEY_TOWN_HOME: String = "home"
## Keys of a road segment (roads()): two cell corners on one line.
const KEY_ROAD_FROM: String = "from"
const KEY_ROAD_TO: String = "to"
## Keys of count_summary().
const KEY_COUNT_CELLS: String = "cells"
const KEY_COUNT_TOWN_CELLS: String = "town_cells"
const KEY_COUNT_ROADSIDE_CELLS: String = "roadside_cells"
const KEY_COUNT_CELLS_WITH_BUILDINGS: String = "cells_with_buildings"
const KEY_COUNT_BUILDINGS: String = "buildings"
const KEY_COUNT_BY_TYPE: String = "buildings_by_type"
const KEY_COUNT_PIECES: String = "structure_pieces"
const KEY_COUNT_MAX_PIECES_PER_CELL: String = "max_pieces_per_cell"
const KEY_COUNT_CONTAINERS: String = "containers"
const KEY_COUNT_ZOMBIES: String = "zombies"
## Keys of parse_building_id().
const KEY_PARSED_CELL: String = "cell"
const KEY_PARSED_INDEX: String = "index"

## Hex digits of a hash used as a seed: 60 bits, always a positive int.
const SEED_HEX_DIGITS: int = 15
const PERCENT_MAX: int = 100
const PER_10000_MAX: int = 10000
const PERMILLE: int = 1000
const TILE_EPSILON: float = 0.0001
## Lot grids (columns, rows) a block is cut into, by zone.
const RESIDENTIAL_LOT_GRIDS: Array[Vector2i] = [Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3)]
const COMMERCIAL_LOT_GRIDS: Array[Vector2i] = [Vector2i(2, 1), Vector2i(1, 2), Vector2i(2, 2)]
const FARM_LOT_GRID: Vector2i = Vector2i(2, 2)
const LONE_LOT_GRID: Vector2i = Vector2i(1, 1)

var world_seed: int = 0

var _settings: ProceduralMapSettings
var _cell_size_m: float = 50.0
var _module_m: float = 1.0
## Tiles along one side of a cell; 0 = the cell size is no whole number of
## tiles and nothing is generated.
var _tiles_per_cell: int = 0
var _road_tiles: int = 0
var _reserved_m: float = 0.0
## The cells that lie wholly inside the map bounds and the play area.
var _min_cell: Vector2i = Vector2i.ZERO
var _max_cell: Vector2i = Vector2i(-1, -1)
var _towns: Array[Dictionary] = []
var _roads: Array[Dictionary] = []
var _roadside: Dictionary[Vector2i, bool] = {}


func _init(settings: ProceduralMapSettings, seed_value: int, cell_size_m: float, bounds_min_m: Vector2, bounds_max_m: Vector2, world_half_extent_m: float, grid_module_m: float) -> void:
	_settings = settings
	world_seed = seed_value
	_cell_size_m = cell_size_m
	_module_m = grid_module_m
	_reserved_m = settings.reserved_half_extent_m
	var tiles: float = cell_size_m / grid_module_m
	if absf(tiles - roundf(tiles)) > TILE_EPSILON or tiles < 1.0:
		return
	_tiles_per_cell = roundi(tiles)
	_road_tiles = ceili(settings.road_half_width_m / grid_module_m - TILE_EPSILON)
	var low: Vector2 = Vector2(maxf(bounds_min_m.x, -world_half_extent_m), maxf(bounds_min_m.y, -world_half_extent_m))
	var high: Vector2 = Vector2(minf(bounds_max_m.x, world_half_extent_m), minf(bounds_max_m.y, world_half_extent_m))
	_min_cell = Vector2i(ceili(low.x / cell_size_m - TILE_EPSILON), ceili(low.y / cell_size_m - TILE_EPSILON))
	_max_cell = Vector2i(floori(high.x / cell_size_m + TILE_EPSILON) - 1, floori(high.y / cell_size_m + TILE_EPSILON) - 1)
	_build_towns()
	_build_roads()


# ------------------------------------------------------------ public API

## True when this generator can place anything at all.
func is_usable() -> bool:
	return _tiles_per_cell > 0 and _max_cell.x >= _min_cell.x and _max_cell.y >= _min_cell.y


## The towns, in the order they were made ({index, corner, radius_m, home}).
func towns() -> Array[Dictionary]:
	return _towns.duplicate(true)


## The road segments between towns ({from, to}: cell corners).
func roads() -> Array[Dictionary]:
	return _roads.duplicate(true)


## The cells something can be generated in (smallest and largest cell).
func min_cell() -> Vector2i:
	return _min_cell


func max_cell() -> Vector2i:
	return _max_cell


## The side of a world cell, metres.
func cell_size_m() -> float:
	return _cell_size_m


func cell_kind(cell: Vector2i) -> int:
	if not is_usable() or cell.x < _min_cell.x or cell.y < _min_cell.y or cell.x > _max_cell.x or cell.y > _max_cell.y:
		return CellKind.OUTSIDE
	if _is_reserved(cell):
		return CellKind.RESERVED
	if town_of(cell) >= 0:
		return CellKind.TOWN
	return CellKind.ROADSIDE if _roadside.has(cell) else CellKind.WILD


## Index of the town a cell belongs to (its centre lies in the town's disc),
## -1 for none.
func town_of(cell: Vector2i) -> int:
	var center: Vector2 = Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5)
	for town: Dictionary in _towns:
		if (center - Vector2(town[KEY_TOWN_CORNER] as Vector2i)).length() * _cell_size_m <= float(town[KEY_TOWN_RADIUS_M]):
			return int(town[KEY_TOWN_INDEX])
	return -1


## What the generated map puts in one cell. Never null; empty for a cell
## that gets nothing.
func plan_cell(cell: Vector2i) -> ProceduralCellPlan:
	var plan: ProceduralCellPlan = ProceduralCellPlan.new()
	plan.cell = cell
	plan.kind = cell_kind(cell)
	if plan.kind == CellKind.OUTSIDE or plan.kind == CellKind.RESERVED:
		return plan
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _seed_of("cell|%d|%d" % [cell.x, cell.y])
	match plan.kind:
		CellKind.TOWN:
			plan.town_index = town_of(cell)
			_plan_town_block(plan, rng)
		CellKind.ROADSIDE:
			_plan_farm(plan, rng)
		_:
			_plan_wild(plan, rng)
	return plan


## Counts of the whole map (tests, tools, the log line of a new world). It
## plans every cell, so it is not for a server tick.
func count_summary() -> Dictionary:
	var by_type: Dictionary = {}
	var summary: Dictionary = {KEY_COUNT_CELLS: 0, KEY_COUNT_TOWN_CELLS: 0, KEY_COUNT_ROADSIDE_CELLS: 0, KEY_COUNT_CELLS_WITH_BUILDINGS: 0, KEY_COUNT_BUILDINGS: 0, KEY_COUNT_BY_TYPE: by_type, KEY_COUNT_PIECES: 0, KEY_COUNT_MAX_PIECES_PER_CELL: 0, KEY_COUNT_CONTAINERS: 0, KEY_COUNT_ZOMBIES: 0}
	if not is_usable():
		return summary
	for x: int in range(_min_cell.x, _max_cell.x + 1):
		for z: int in range(_min_cell.y, _max_cell.y + 1):
			var plan: ProceduralCellPlan = plan_cell(Vector2i(x, z))
			summary[KEY_COUNT_CELLS] = int(summary[KEY_COUNT_CELLS]) + 1
			if plan.kind == CellKind.TOWN:
				summary[KEY_COUNT_TOWN_CELLS] = int(summary[KEY_COUNT_TOWN_CELLS]) + 1
			elif plan.kind == CellKind.ROADSIDE:
				summary[KEY_COUNT_ROADSIDE_CELLS] = int(summary[KEY_COUNT_ROADSIDE_CELLS]) + 1
			if not plan.buildings.is_empty():
				summary[KEY_COUNT_CELLS_WITH_BUILDINGS] = int(summary[KEY_COUNT_CELLS_WITH_BUILDINGS]) + 1
			var pieces: int = plan.piece_count(_settings.place_floors)
			summary[KEY_COUNT_BUILDINGS] = int(summary[KEY_COUNT_BUILDINGS]) + plan.buildings.size()
			summary[KEY_COUNT_PIECES] = int(summary[KEY_COUNT_PIECES]) + pieces
			summary[KEY_COUNT_MAX_PIECES_PER_CELL] = maxi(int(summary[KEY_COUNT_MAX_PIECES_PER_CELL]), pieces)
			summary[KEY_COUNT_CONTAINERS] = int(summary[KEY_COUNT_CONTAINERS]) + plan.container_count()
			summary[KEY_COUNT_ZOMBIES] = int(summary[KEY_COUNT_ZOMBIES]) + plan.zombie_positions.size()
			for building: ProceduralBuilding in plan.buildings:
				by_type[building.definition.building_type] = int(by_type.get(building.definition.building_type, 0)) + 1
	return summary


## The id of the building at `index` of a cell: stable, snake_case, unique
## in the world ("gen_n12_p3_0" = cell (-12, 3), building 0).
static func building_id_of(cell: Vector2i, index: int) -> String:
	return "%s_%s_%s_%d" % [BUILDING_ID_PREFIX, _coordinate_label(cell.x), _coordinate_label(cell.y), index]


## The cell and the index a generated building id names ({} = not such an
## id): {"cell": Vector2i, "index": int}. The opposite of building_id_of.
static func parse_building_id(building_id: String) -> Dictionary:
	var parts: PackedStringArray = building_id.split("_")
	if parts.size() != 4 or parts[0] != BUILDING_ID_PREFIX or not parts[3].is_valid_int() or parts[3].to_int() < 0:
		return {}
	var x: Variant = _coordinate_of(parts[1])
	var z: Variant = _coordinate_of(parts[2])
	if x == null or z == null:
		return {}
	var parsed: Dictionary = {KEY_PARSED_CELL: Vector2i(int(x), int(z)), KEY_PARSED_INDEX: parts[3].to_int()}
	# Only the one spelling building_id_of writes ("n0", "p007" are no ids).
	return parsed if building_id_of(parsed[KEY_PARSED_CELL] as Vector2i, int(parsed[KEY_PARSED_INDEX])) == building_id else {}


## The generated building with this id, or null (not a generated id, or the
## cell has no such building). Plans the building's cell.
func building_by_id(building_id: String) -> ProceduralBuilding:
	var parsed: Dictionary = parse_building_id(building_id)
	if parsed.is_empty():
		return null
	var plan: ProceduralCellPlan = plan_cell(parsed[KEY_PARSED_CELL] as Vector2i)
	var index: int = int(parsed[KEY_PARSED_INDEX])
	return plan.buildings[index] if index < plan.buildings.size() else null


# ------------------------------------------------------------ towns and roads

func _build_towns() -> void:
	if not is_usable():
		return
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _seed_of("towns")
	if _settings.home_town_radius_m > 0.0:
		_towns.append({KEY_TOWN_INDEX: 0, KEY_TOWN_CORNER: Vector2i.ZERO, KEY_TOWN_RADIUS_M: _settings.home_town_radius_m, KEY_TOWN_HOME: true})
	for _town: int in range(_settings.town_count):
		# More small towns than large ones: the square of an even roll.
		var roll: float = float(rng.randi_range(0, PERMILLE)) / float(PERMILLE)
		var radius_m: float = lerpf(_settings.town_min_radius_m, _settings.town_max_radius_m, roll * roll)
		var radius_cells: int = ceili(radius_m / _cell_size_m)
		var low: Vector2i = _min_cell + Vector2i(radius_cells, radius_cells)
		var high: Vector2i = _max_cell + Vector2i.ONE - Vector2i(radius_cells, radius_cells)
		if high.x < low.x or high.y < low.y:
			continue
		for _attempt: int in range(_settings.town_placement_attempts):
			var corner: Vector2i = Vector2i(rng.randi_range(low.x, high.x), rng.randi_range(low.y, high.y))
			if _is_town_place_free(corner, radius_m):
				_towns.append({KEY_TOWN_INDEX: _towns.size(), KEY_TOWN_CORNER: corner, KEY_TOWN_RADIUS_M: radius_m, KEY_TOWN_HOME: false})
				break


func _is_town_place_free(corner: Vector2i, radius_m: float) -> bool:
	for town: Dictionary in _towns:
		var distance_m: float = Vector2(corner - (town[KEY_TOWN_CORNER] as Vector2i)).length() * _cell_size_m
		if distance_m < radius_m + float(town[KEY_TOWN_RADIUS_M]) + _settings.town_spacing_m:
			return false
	return true


## Every town after the first is joined to the nearest town made before it
## by an L of two road segments along cell borders.
func _build_roads() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _seed_of("roads")
	for index: int in range(1, _towns.size()):
		var from: Vector2i = _towns[index][KEY_TOWN_CORNER]
		var nearest: Vector2i = _towns[0][KEY_TOWN_CORNER]
		var best: int = -1
		for earlier: int in range(index):
			var corner: Vector2i = _towns[earlier][KEY_TOWN_CORNER]
			var distance: int = (corner - from).length_squared()
			if best < 0 or distance < best:
				best = distance
				nearest = corner
		var bend: Vector2i = Vector2i(nearest.x, from.y) if rng.randi_range(0, 1) == 0 else Vector2i(from.x, nearest.y)
		_add_road(from, bend)
		_add_road(bend, nearest)


## A straight road between two cell corners on one line; the cells on both
## sides of it are roadside cells.
func _add_road(from: Vector2i, to: Vector2i) -> void:
	if from == to:
		return
	_roads.append({KEY_ROAD_FROM: from, KEY_ROAD_TO: to})
	if from.y == to.y:
		for x: int in range(mini(from.x, to.x), maxi(from.x, to.x)):
			_roadside[Vector2i(x, from.y - 1)] = true
			_roadside[Vector2i(x, from.y)] = true
	else:
		for z: int in range(mini(from.y, to.y), maxi(from.y, to.y)):
			_roadside[Vector2i(from.x - 1, z)] = true
			_roadside[Vector2i(from.x, z)] = true


## True when the cell touches the reserved square around the origin.
func _is_reserved(cell: Vector2i) -> bool:
	if _reserved_m <= 0.0:
		return false
	var low: Vector2 = Vector2(cell) * _cell_size_m
	var high: Vector2 = low + Vector2(_cell_size_m, _cell_size_m)
	return low.x < _reserved_m - TILE_EPSILON and high.x > -_reserved_m + TILE_EPSILON and low.y < _reserved_m - TILE_EPSILON and high.y > -_reserved_m + TILE_EPSILON


# ------------------------------------------------------------ cells

@warning_ignore("integer_division")
func _plan_town_block(plan: ProceduralCellPlan, rng: RandomNumberGenerator) -> void:
	var town: Dictionary = _towns[plan.town_index]
	var center: Vector2 = Vector2(float(plan.cell.x) + 0.5, float(plan.cell.y) + 0.5)
	var distance_m: float = (center - Vector2(town[KEY_TOWN_CORNER] as Vector2i)).length() * _cell_size_m
	# 0 at the centre, 1000 at the edge.
	var depth: int = clampi(int(distance_m * float(PERMILLE) / float(town[KEY_TOWN_RADIUS_M])), 0, PERMILLE)
	var built: bool = _roll_percent(rng) <= _between(_settings.town_center_block_percent, _settings.town_edge_block_percent, depth)
	var commercial: bool = _roll_percent(rng) <= _settings.commercial_block_percent and depth * PERCENT_MAX <= _settings.commercial_core_percent * PERMILLE
	var grids: Array[Vector2i] = COMMERCIAL_LOT_GRIDS if commercial else RESIDENTIAL_LOT_GRIDS
	var lot_grid: Vector2i = grids[rng.randi_range(0, grids.size() - 1)]
	var lot_percent: int = _between(_settings.town_center_lot_percent, _settings.town_edge_lot_percent, depth)
	var zone: int = ProceduralBuildingArchetype.Zone.COMMERCIAL if commercial else ProceduralBuildingArchetype.Zone.RESIDENTIAL
	if built:
		for lot: Dictionary in _lots(lot_grid):
			if _roll_percent(rng) <= lot_percent:
				_add_building(plan, rng, zone, lot)
	for _zombie: int in range(_settings.town_zombies_per_cell_max):
		if _roll_percent(rng) <= _settings.town_zombie_percent:
			plan.zombie_positions.append(_street_position(plan.cell, rng))


func _plan_farm(plan: ProceduralCellPlan, rng: RandomNumberGenerator) -> void:
	var built: bool = _roll_percent(rng) <= _settings.roadside_farm_percent
	var lots: Array[Dictionary] = _lots(FARM_LOT_GRID)
	var main_lot: int = rng.randi_range(0, lots.size() - 1)
	if built:
		for index: int in range(lots.size()):
			var extra: bool = _roll_percent(rng) <= _settings.farm_extra_building_percent
			if index == main_lot or extra:
				_add_building(plan, rng, ProceduralBuildingArchetype.Zone.RURAL, lots[index])
	if _roll_percent(rng) <= _settings.roadside_zombie_percent:
		plan.zombie_positions.append(_street_position(plan.cell, rng))


func _plan_wild(plan: ProceduralCellPlan, rng: RandomNumberGenerator) -> void:
	if rng.randi_range(1, PER_10000_MAX) <= _settings.wild_building_per_10000:
		_add_building(plan, rng, ProceduralBuildingArchetype.Zone.RURAL, _lots(LONE_LOT_GRID)[0])
	if rng.randi_range(1, PER_10000_MAX) <= _settings.wild_zombie_per_10000:
		plan.zombie_positions.append(_street_position(plan.cell, rng))


## The lots of a block cut into `lot_grid` columns and rows:
## {rect: Rect2i in tiles of the cell, sides: the outer sides (edge
## rotations) of the lot that face a street}.
@warning_ignore("integer_division")
func _lots(lot_grid: Vector2i) -> Array[Dictionary]:
	var lots: Array[Dictionary] = []
	var inner: int = _tiles_per_cell - 2 * _road_tiles
	for column: int in range(lot_grid.x):
		for row: int in range(lot_grid.y):
			var low: Vector2i = Vector2i(_road_tiles + inner * column / lot_grid.x, _road_tiles + inner * row / lot_grid.y)
			var high: Vector2i = Vector2i(_road_tiles + inner * (column + 1) / lot_grid.x, _road_tiles + inner * (row + 1) / lot_grid.y)
			var sides: Array[int] = []
			if row == 0:
				sides.append(MapBuildingPlan.SIDE_LOW_Z)
			if column == lot_grid.x - 1:
				sides.append(MapBuildingPlan.SIDE_HIGH_X)
			if row == lot_grid.y - 1:
				sides.append(MapBuildingPlan.SIDE_HIGH_Z)
			if column == 0:
				sides.append(MapBuildingPlan.SIDE_LOW_X)
			lots.append({"rect": Rect2i(low, high - low), "sides": sides})
	return lots


## Puts one building of `zone` into a lot, when an archetype fits it.
func _add_building(plan: ProceduralCellPlan, rng: RandomNumberGenerator, zone: int, lot: Dictionary) -> void:
	var rect: Rect2i = lot["rect"]
	var room: Vector2i = rect.size - Vector2i(2 * _settings.yard_margin_tiles, 2 * _settings.yard_margin_tiles)
	var fitting: Array[ProceduralBuildingArchetype] = []
	var total_weight: int = 0
	for archetype: ProceduralBuildingArchetype in _settings.archetypes_of(zone):
		if _fits(archetype, room, true) or _fits(archetype, room, false):
			fitting.append(archetype)
			total_weight += archetype.weight
	if fitting.is_empty():
		return
	var pick: int = rng.randi_range(1, total_weight)
	var chosen: ProceduralBuildingArchetype = fitting[0]
	for archetype: ProceduralBuildingArchetype in fitting:
		pick -= archetype.weight
		if pick <= 0:
			chosen = archetype
			break
	var along_x: bool = _fits(chosen, room, true)
	if along_x and _fits(chosen, room, false):
		along_x = rng.randi_range(0, 1) == 0
	var long_room: int = room.x if along_x else room.y
	var short_room: int = room.y if along_x else room.x
	var long_side: int = rng.randi_range(chosen.min_size_tiles.x, mini(chosen.max_size_tiles.x, long_room))
	var short_side: int = rng.randi_range(chosen.min_size_tiles.y, mini(chosen.max_size_tiles.y, short_room))
	var size: Vector2i = Vector2i(long_side, short_side) if along_x else Vector2i(short_side, long_side)
	var local: Vector2i = rect.position + Vector2i(_settings.yard_margin_tiles + rng.randi_range(0, room.x - size.x), _settings.yard_margin_tiles + rng.randi_range(0, room.y - size.y))
	var sides: Array[int] = lot["sides"]
	var definition: MapBuildingDefinition = MapBuildingDefinition.new()
	definition.building_id = building_id_of(plan.cell, plan.buildings.size())
	definition.building_type = chosen.building_type
	definition.origin_tile = plan.cell * _tiles_per_cell + local
	definition.size_tiles = size
	definition.floor_definition_id = chosen.floor_definition_id
	definition.wall_definition_id = chosen.wall_definition_id
	definition.door_definition_id = chosen.door_definition_id
	definition.door_side = sides[rng.randi_range(0, sides.size() - 1)] if not sides.is_empty() else rng.randi_range(0, StructureGrid.ROTATION_COUNT - 1)
	# Not in a corner: the door of a side of 3 or more tiles keeps a wall on
	# both sides of it.
	definition.door_offset = rng.randi_range(1, definition.door_side_length() - 2)
	definition.loot_table_id = chosen.loot_table_id
	var building: ProceduralBuilding = ProceduralBuilding.new()
	building.cell = plan.cell
	building.archetype_id = chosen.archetype_id
	building.definition = definition
	building.interior_pieces = _interior(rng, chosen, definition, along_x)
	definition.containers = _containers(rng, chosen, definition)
	plan.buildings.append(building)


func _fits(archetype: ProceduralBuildingArchetype, room: Vector2i, along_x: bool) -> bool:
	var long_room: int = room.x if along_x else room.y
	var short_room: int = room.y if along_x else room.x
	return archetype.min_size_tiles.x <= long_room and archetype.min_size_tiles.y <= short_room


## Interior walls across the long side, each with one door.
@warning_ignore("integer_division")
func _interior(rng: RandomNumberGenerator, archetype: ProceduralBuildingArchetype, definition: MapBuildingDefinition, along_x: bool) -> Array[Dictionary]:
	var pieces: Array[Dictionary] = []
	var long_side: int = definition.size_tiles.x if along_x else definition.size_tiles.y
	var short_side: int = definition.size_tiles.y if along_x else definition.size_tiles.x
	if archetype.room_span_tiles <= 0:
		return pieces
	var partitions: int = clampi(long_side / archetype.room_span_tiles - 1, 0, archetype.max_partitions)
	for index: int in range(1, partitions + 1):
		var at: int = long_side * index / (partitions + 1)
		var door_at: int = rng.randi_range(0, short_side - 1)
		for across: int in range(short_side):
			var definition_id: String = definition.door_definition_id if across == door_at else definition.wall_definition_id
			var tile: Vector2i = definition.origin_tile + (Vector2i(at, across) if along_x else Vector2i(across, at))
			pieces.append({MapBuildingPlan.KEY_DEFINITION_ID: definition_id, MapBuildingPlan.KEY_TILE: tile, MapBuildingPlan.KEY_ROTATION: MapBuildingPlan.SIDE_LOW_X if along_x else MapBuildingPlan.SIDE_LOW_Z})
	return pieces


## Containers on tiles along the outer wall, never on the tile behind the
## outer door.
func _containers(rng: RandomNumberGenerator, archetype: ProceduralBuildingArchetype, definition: MapBuildingDefinition) -> Array[MapContainerPlacement]:
	var placements: Array[MapContainerPlacement] = []
	var count: int = rng.randi_range(archetype.min_containers, archetype.max_containers)
	if count <= 0 or archetype.container_definition_ids.is_empty():
		return placements
	var door_tile: Vector2i = (MapBuildingPlan.door_piece(definition)[MapBuildingPlan.KEY_TILE] as Vector2i) - definition.origin_tile
	var free: Array[Vector2i] = []
	for x: int in range(definition.size_tiles.x):
		for z: int in range(definition.size_tiles.y):
			var offset: Vector2i = Vector2i(x, z)
			if (x == 0 or z == 0 or x == definition.size_tiles.x - 1 or z == definition.size_tiles.y - 1) and offset != door_tile:
				free.append(offset)
	for _container: int in range(mini(count, free.size())):
		var placement: MapContainerPlacement = MapContainerPlacement.new()
		placement.definition_id = archetype.container_definition_ids[rng.randi_range(0, archetype.container_definition_ids.size() - 1)]
		var at: int = rng.randi_range(0, free.size() - 1)
		placement.tile_offset = free[at]
		free.remove_at(at)
		placements.append(placement)
	return placements


## A place in the street strip along one border of the cell (the centre of
## a tile no building can stand on).
func _street_position(cell: Vector2i, rng: RandomNumberGenerator) -> Vector3:
	var side: int = rng.randi_range(0, StructureGrid.ROTATION_COUNT - 1)
	var along: int = rng.randi_range(0, _tiles_per_cell - 1)
	var strip: int = mini(1, maxi(_road_tiles - 1, 0))
	var local: Vector2i = Vector2i(along, strip)
	match side:
		MapBuildingPlan.SIDE_HIGH_X:
			local = Vector2i(_tiles_per_cell - 1 - strip, along)
		MapBuildingPlan.SIDE_HIGH_Z:
			local = Vector2i(along, _tiles_per_cell - 1 - strip)
		MapBuildingPlan.SIDE_LOW_X:
			local = Vector2i(strip, along)
	var tile: Vector2i = cell * _tiles_per_cell + local
	return Vector3((float(tile.x) + 0.5) * _module_m, 0.0, (float(tile.y) + 0.5) * _module_m)


# ------------------------------------------------------------ numbers

## A seed for one part of the map: a hash of the generator version, the
## world seed and a label. Always the same for the same input.
func _seed_of(label: String) -> int:
	return ("f33|%d|%d|%s" % [GENERATOR_VERSION, world_seed, label]).sha256_text().substr(0, SEED_HEX_DIGITS).hex_to_int()


static func _roll_percent(rng: RandomNumberGenerator) -> int:
	return rng.randi_range(1, PERCENT_MAX)


## `at_center` at depth 0, `at_edge` at depth 1000, evenly in between
## (whole numbers only).
@warning_ignore("integer_division")
static func _between(at_center: int, at_edge: int, depth: int) -> int:
	return at_center + (at_edge - at_center) * depth / PERMILLE


static func _coordinate_label(value: int) -> String:
	return ("n%d" % -value) if value < 0 else ("p%d" % value)


## The number a coordinate label names, or null.
static func _coordinate_of(label: String) -> Variant:
	if label.length() < 2 or not label.substr(1).is_valid_int() or label.substr(1).to_int() < 0:
		return null
	if label[0] == "n":
		return -label.substr(1).to_int()
	return label.substr(1).to_int() if label[0] == "p" else null
