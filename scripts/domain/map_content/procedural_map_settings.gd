class_name ProceduralMapSettings
extends Resource
## The generated part of the map (F-33, docs/09 §15.3.1, docs/15 §F-33):
## towns of different sizes, roads between them, farms along the roads, all
## made from one world seed. Defaults in
## `res://data/tuning/procedural_map_settings.tres`. Every value is
## PROVISIONAL (docs/15 F33-001..) until play-tested.
##
## The layout is original: a town is a disc of world cells around a street
## crossing, every cell of it is one block between streets (the streets run
## along the cell borders), and a block is cut into lots with one building
## each. Nothing is copied from another game's map.

const DEFAULT_PATH: String = "res://data/tuning/procedural_map_settings.tres"
## Largest seed: exact in JSON and in a float.
const MAX_WORLD_SEED: int = 9007199254740991
const PERCENT_MAX: int = 100
const PER_10000_MAX: int = 10000

@export_group("World")
## The seed of a NEW world's layout. 0 = a random seed per world. A world
## keeps the seed it was created with (it is in its save).
@export var world_seed: int = 20261123
## Nothing is generated in the cells that touch this square around the
## origin (metres): the hand-made starting town (the test map) and whatever
## players built there before the world grew.
@export_range(0.0, 100000.0) var reserved_half_extent_m: float = 250.0

@export_group("Towns")
## A town around the reserved square, so the first generated houses stand
## right outside the starting town (metres; 0 = none).
@export_range(0.0, 100000.0) var home_town_radius_m: float = 500.0
## How many more towns are tried. One that finds no free place is left out.
@export_range(0, 1000) var town_count: int = 12
@export_range(1.0, 100000.0) var town_min_radius_m: float = 120.0
@export_range(1.0, 100000.0) var town_max_radius_m: float = 450.0
## Free land between two towns, metres.
@export_range(0.0, 100000.0) var town_spacing_m: float = 250.0
## Tries per town to find a free place.
@export_range(1, 10000) var town_placement_attempts: int = 64
## Chance (percent) that a block is built on, at the town centre and at its
## edge; in between it changes evenly. The other blocks stay open land.
@export_range(0, 100) var town_center_block_percent: int = 95
@export_range(0, 100) var town_edge_block_percent: int = 60
## Chance (percent) that a lot of a built block has a building, at the
## centre and at the edge.
@export_range(0, 100) var town_center_lot_percent: int = 90
@export_range(0, 100) var town_edge_lot_percent: int = 60
## Blocks closer to the centre than this part of the town radius (percent)
## can be commercial, with this chance (percent).
@export_range(0, 100) var commercial_core_percent: int = 35
@export_range(0, 100) var commercial_block_percent: int = 50

@export_group("Countryside")
## Chance (percent) that a cell beside a road between towns has a farm.
@export_range(0, 100) var roadside_farm_percent: int = 22
## Chance (per ten thousand) that a cell away from every road has a lone
## building.
@export_range(0, 10000) var wild_building_per_10000: int = 120
## Chance (percent) of each further building of a farm (barn, shed).
@export_range(0, 100) var farm_extra_building_percent: int = 35

@export_group("Blocks")
## Half the width of a street: this strip along every cell border stays
## empty, metres.
@export_range(0.0, 1000.0) var road_half_width_m: float = 3.0
## Free tiles between a building and the edge of its lot.
@export_range(1, 100) var yard_margin_tiles: int = 2
## false = generated buildings get no floor pieces (walls, doors and
## containers only).
@export var place_floors: bool = false

@export_group("Zombies")
## A town cell gets up to this many zombies when it is generated, each with
## this chance (percent). They stand in the streets.
@export_range(0, 64) var town_zombies_per_cell_max: int = 2
@export_range(0, 100) var town_zombie_percent: int = 35
## Chance (percent) of one zombie in a cell beside a road.
@export_range(0, 100) var roadside_zombie_percent: int = 8
## Chance (per ten thousand) of one zombie in a cell away from every road.
@export_range(0, 10000) var wild_zombie_per_10000: int = 300

@export_group("Placement")
## Structure pieces placed per server tick for cells nobody is next to yet
## (measured: about 60 microseconds a piece, docs/15 F33-020). A cell that
## becomes ACTIVE with a player in it or beside it is finished at once.
@export_range(1, 1000000) var max_pieces_per_tick: int = 24

@export_group("Archetypes")
@export var archetypes: Array[ProceduralBuildingArchetype] = []


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if world_seed < 0 or world_seed > MAX_WORLD_SEED:
		errors.append("procedural map world_seed must be within [0, %d]" % MAX_WORLD_SEED)
	for value: float in [reserved_half_extent_m, home_town_radius_m, town_spacing_m, road_half_width_m]:
		if not is_finite(value) or value < 0.0:
			errors.append("procedural map distances must be finite and >= 0")
			break
	if not is_finite(town_min_radius_m) or not is_finite(town_max_radius_m) or town_min_radius_m <= 0.0 or town_max_radius_m < town_min_radius_m:
		errors.append("procedural map town radii must be 0 < min <= max")
	if town_count < 0 or town_placement_attempts < 1:
		errors.append("procedural map town_count must be >= 0 and town_placement_attempts >= 1")
	for percent: int in [town_center_block_percent, town_edge_block_percent, town_center_lot_percent, town_edge_lot_percent, commercial_core_percent, commercial_block_percent, roadside_farm_percent, farm_extra_building_percent, town_zombie_percent, roadside_zombie_percent]:
		if percent < 0 or percent > PERCENT_MAX:
			errors.append("procedural map percentages must be within [0, 100]")
			break
	if wild_building_per_10000 < 0 or wild_building_per_10000 > PER_10000_MAX or wild_zombie_per_10000 < 0 or wild_zombie_per_10000 > PER_10000_MAX:
		errors.append("procedural map per-10000 chances must be within [0, 10000]")
	if yard_margin_tiles < 1:
		errors.append("procedural map yard_margin_tiles must be >= 1 (two buildings never share an edge)")
	if town_zombies_per_cell_max < 0:
		errors.append("procedural map town_zombies_per_cell_max must be >= 0")
	if max_pieces_per_tick < 1:
		errors.append("procedural map max_pieces_per_tick must be >= 1")
	var seen: Dictionary[String, bool] = {}
	var zones: Dictionary[int, bool] = {}
	for archetype: ProceduralBuildingArchetype in archetypes:
		if archetype == null:
			errors.append("procedural map: an archetype entry is empty")
			continue
		errors.append_array(archetype.validate())
		if seen.has(archetype.archetype_id):
			errors.append("procedural map: duplicate archetype_id %s" % archetype.archetype_id)
		seen[archetype.archetype_id] = true
		zones[archetype.zone] = true
	for zone: int in [ProceduralBuildingArchetype.Zone.RESIDENTIAL, ProceduralBuildingArchetype.Zone.COMMERCIAL, ProceduralBuildingArchetype.Zone.RURAL]:
		if not zones.has(zone):
			errors.append("procedural map: every zone (residential, commercial, rural) needs an archetype")
			break
	return errors


## Errors against the definitions and the world the map is generated in:
## every archetype names structure definitions of the right kind, container
## definitions and a loot table that exist; a block has room for a building;
## the hand-made map lies inside the reserved square.
func validate_against(structures: StructureCatalog, container_definitions: ContainerCatalog, loot_tables: LootTableCatalog, grid: StructureGrid, cell_size_m: float, map_content: MapContentDefinition) -> PackedStringArray:
	var errors: PackedStringArray = []
	for archetype: ProceduralBuildingArchetype in archetypes:
		if archetype == null:
			continue
		var label: String = "procedural archetype %s" % archetype.archetype_id
		var floor_definition: StructureDefinition = structures.get_definition(archetype.floor_definition_id)
		var wall_definition: StructureDefinition = structures.get_definition(archetype.wall_definition_id)
		var door_definition: StructureDefinition = structures.get_definition(archetype.door_definition_id)
		if floor_definition == null or floor_definition.is_edge():
			errors.append("%s: floor %s must be a tile piece" % [label, archetype.floor_definition_id])
		if wall_definition == null or not wall_definition.is_edge() or not wall_definition.blocks_movement or wall_definition.is_door:
			errors.append("%s: wall %s must be an edge piece that blocks movement" % [label, archetype.wall_definition_id])
		if door_definition == null or not door_definition.is_door:
			errors.append("%s: door %s must be a door" % [label, archetype.door_definition_id])
		for definition_id: String in archetype.container_definition_ids:
			if container_definitions.get_definition(definition_id) == null:
				errors.append("%s: unknown container %s" % [label, definition_id])
		if not archetype.loot_table_id.is_empty() and not loot_tables.has(archetype.loot_table_id):
			errors.append("%s: unknown loot table %s" % [label, archetype.loot_table_id])
	var tiles_per_cell: float = cell_size_m / grid.module_m
	if absf(tiles_per_cell - roundf(tiles_per_cell)) > ProceduralMapGenerator.TILE_EPSILON:
		errors.append("procedural map: the cell size (%s m) must be a whole number of building tiles" % str(cell_size_m))
	var block_tiles: int = floori((cell_size_m - 2.0 * road_half_width_m) / grid.module_m)
	if block_tiles < 2 * yard_margin_tiles + ProceduralBuildingArchetype.MIN_SIDE_TILES:
		errors.append("procedural map: a cell of %s m leaves no room for a building between its streets" % str(cell_size_m))
	if map_content != null:
		for building: MapBuildingDefinition in map_content.buildings:
			if building == null:
				continue
			var footprint: Rect2i = MapBuildingPlan.footprint(building)
			if not grid.is_tile_inside(footprint.position, reserved_half_extent_m) or not grid.is_tile_inside(footprint.end - Vector2i.ONE, reserved_half_extent_m):
				errors.append("procedural map: building %s of map %s lies outside reserved_half_extent_m" % [building.building_id, map_content.map_id])
	return errors


## Archetypes of one zone, in the order of the settings.
func archetypes_of(zone: int) -> Array[ProceduralBuildingArchetype]:
	var found: Array[ProceduralBuildingArchetype] = []
	for archetype: ProceduralBuildingArchetype in archetypes:
		if archetype != null and archetype.zone == zone:
			found.append(archetype)
	return found


## The settings at `path`, or null (logged) when there are none: the world
## then gets no generated map.
static func load_or_null(path: String = DEFAULT_PATH) -> ProceduralMapSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is ProceduralMapSettings:
		return loaded as ProceduralMapSettings
	GameLogger.warning("config", "procedural map settings missing; the world gets no generated buildings", {"path": path, "operation": "load_settings"})
	return null
