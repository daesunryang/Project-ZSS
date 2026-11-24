extends TestCase
## F-33 (docs/09 §15.3.1): the generated map as pure data. The same world
## seed gives the same towns, roads and buildings whichever cell is asked
## first; another seed gives another map; the hand-made starting town and
## everything outside the play area are left alone; every building lies
## wholly inside its cell, clear of the streets and of every other building,
## and is made of pieces and containers the shipped definitions know.
## No world, no nodes. Placing in a world: procedural_map_service_test.gd.

const SEED: int = 20261123
const OTHER_SEED: int = 777
const CELL_M: float = 50.0
const HALF_M: float = 2000.0
const MODULE_M: float = 1.0
const TILES_PER_CELL: int = 50


func _settings() -> ProceduralMapSettings:
	return (ProceduralMapSettings.load_or_null() as ProceduralMapSettings).duplicate(true) as ProceduralMapSettings


func _generator(seed_value: int = SEED, settings: ProceduralMapSettings = null, half_m: float = HALF_M) -> ProceduralMapGenerator:
	return ProceduralMapGenerator.new(settings if settings != null else _settings(), seed_value, CELL_M, Vector2(-half_m, -half_m), Vector2(half_m, half_m), half_m, MODULE_M)


## The cells of one town (a square around its crossing that holds its disc).
func _cells_around_town(generator: ProceduralMapGenerator, town: Dictionary) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var corner: Vector2i = town[ProceduralMapGenerator.KEY_TOWN_CORNER]
	var reach: int = ceili(float(town[ProceduralMapGenerator.KEY_TOWN_RADIUS_M]) / CELL_M)
	for x: int in range(corner.x - reach, corner.x + reach):
		for z: int in range(corner.y - reach, corner.y + reach):
			if generator.cell_kind(Vector2i(x, z)) == ProceduralMapGenerator.CellKind.TOWN:
				cells.append(Vector2i(x, z))
	return cells


func _first_far_town(generator: ProceduralMapGenerator) -> Dictionary:
	for town: Dictionary in generator.towns():
		if not bool(town[ProceduralMapGenerator.KEY_TOWN_HOME]):
			return town
	return {}


# ------------------------------------------------------------ data

func test_the_shipped_settings_are_valid_against_the_shipped_definitions() -> void:
	var settings: ProceduralMapSettings = ProceduralMapSettings.load_or_null()
	assert_not_null(settings, "the settings are shipped as a resource")
	if settings == null:
		return
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.map_content = MapContentDefinition.load_or_null()
	config.procedural_map = settings
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	assert_eq(config.gameplay.world_half_extent_m, HALF_M, "the shipped world is 4 km x 4 km")
	assert_eq(config.world_cells.cell_size_m, CELL_M, "with the 50 m cells of the test map")
	assert_true(settings.archetypes.size() >= 8, "several kinds of buildings")


func test_settings_that_cannot_work_are_refused() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.map_content = MapContentDefinition.load_or_null()
	var settings: ProceduralMapSettings = _settings()
	settings.reserved_half_extent_m = 10.0
	config.procedural_map = settings
	assert_true("; ".join(config.validate()).contains("lies outside reserved_half_extent_m"), "the hand-made map must lie in the reserved square")
	settings = _settings()
	settings.archetypes[0].loot_table_id = "no_such_table"
	settings.archetypes[1].container_definition_ids = PackedStringArray(["no_such_container"])
	settings.archetypes[2].wall_definition_id = "dev_floor"
	config.procedural_map = settings
	var text: String = "; ".join(config.validate())
	assert_true(text.contains("unknown loot table no_such_table"), text)
	assert_true(text.contains("unknown container no_such_container"), text)
	assert_true(text.contains("must be an edge piece that blocks movement"), text)
	settings = _settings()
	settings.world_seed = -1
	settings.town_max_radius_m = 1.0
	settings.yard_margin_tiles = 0
	settings.archetypes.clear()
	text = "; ".join(settings.validate())
	assert_true(text.contains("world_seed"), text)
	assert_true(text.contains("town radii"), text)
	assert_true(text.contains("yard_margin_tiles"), text)
	assert_true(text.contains("every zone"), text)
	settings = _settings()
	settings.road_half_width_m = 24.0
	config.procedural_map = settings
	assert_true("; ".join(config.validate()).contains("leaves no room for a building"), "streets as wide as the block")


# ------------------------------------------------------------ determinism

func test_the_same_seed_gives_the_same_map_in_any_order() -> void:
	var first: ProceduralMapGenerator = _generator()
	var second: ProceduralMapGenerator = _generator()
	assert_eq(JSON.stringify(first.towns()), JSON.stringify(second.towns()), "the same towns")
	assert_eq(JSON.stringify(first.roads()), JSON.stringify(second.roads()), "the same roads")
	var town: Dictionary = _first_far_town(first)
	assert_false(town.is_empty(), "there is a town away from the start")
	var cells: Array[Vector2i] = _cells_around_town(first, town)
	assert_true(cells.size() >= 10, "the town has cells: %d" % cells.size())
	var forward: Array = []
	for cell: Vector2i in cells:
		forward.append(JSON.stringify(first.plan_cell(cell).summary()))
	# The other generator is asked backwards, and for every cell twice.
	var buildings: int = 0
	for index: int in range(cells.size() - 1, -1, -1):
		second.plan_cell(cells[index])
		var plan: ProceduralCellPlan = second.plan_cell(cells[index])
		buildings += plan.buildings.size()
		assert_eq(JSON.stringify(plan.summary()), str(forward[index]), "cell %s is the same whenever it is asked for" % str(cells[index]))
	assert_true(buildings >= 10, "and the town has buildings: %d" % buildings)


func test_another_seed_gives_another_map() -> void:
	var first: ProceduralMapGenerator = _generator(SEED)
	var other: ProceduralMapGenerator = _generator(OTHER_SEED)
	assert_ne(JSON.stringify(first.towns()), JSON.stringify(other.towns()), "other towns")
	# The home town lies at the origin for every seed, but its houses differ.
	var differing: int = 0
	var compared: int = 0
	for x: int in range(5, 9):
		for z: int in range(-4, 4):
			compared += 1
			if JSON.stringify(first.plan_cell(Vector2i(x, z)).summary()) != JSON.stringify(other.plan_cell(Vector2i(x, z)).summary()):
				differing += 1
	assert_true(differing * 2 > compared, "most cells of the home town differ: %d of %d" % [differing, compared])


# ------------------------------------------------------------ scale

func test_the_shipped_map_has_several_towns_and_well_over_a_thousand_buildings() -> void:
	var generator: ProceduralMapGenerator = _generator()
	var summary: Dictionary = generator.count_summary()
	print("[f33] shipped map: %s" % JSON.stringify(summary))
	print("[f33] towns: %s" % JSON.stringify(generator.towns()))
	assert_eq(int(summary[ProceduralMapGenerator.KEY_COUNT_CELLS]), 6400, "80 x 80 cells")
	assert_true(generator.towns().size() >= 6, "several towns: %d" % generator.towns().size())
	var radii: Dictionary = {}
	for town: Dictionary in generator.towns():
		radii[int(float(town[ProceduralMapGenerator.KEY_TOWN_RADIUS_M]) / 100.0)] = true
	assert_true(radii.size() >= 3, "of different sizes")
	assert_true(int(summary[ProceduralMapGenerator.KEY_COUNT_BUILDINGS]) >= 1500, "well over 1000 buildings: %d" % int(summary[ProceduralMapGenerator.KEY_COUNT_BUILDINGS]))
	var by_type: Dictionary = summary[ProceduralMapGenerator.KEY_COUNT_BY_TYPE]
	assert_true(by_type.size() >= 4, "several building types: %s" % str(by_type.keys()))
	assert_true(int(by_type.get("house", 0)) >= 1000, "most of them houses: %d" % int(by_type.get("house", 0)))
	assert_true(int(summary[ProceduralMapGenerator.KEY_COUNT_ROADSIDE_CELLS]) > 0, "roads between the towns")
	assert_true(int(summary[ProceduralMapGenerator.KEY_COUNT_ZOMBIES]) > 100, "zombies across the map")
	var limits: BuildingSettings = BuildingSettings.load_or_default()
	assert_true(int(summary[ProceduralMapGenerator.KEY_COUNT_MAX_PIECES_PER_CELL]) < limits.max_structures_per_cell / 2, "a cell stays far below the structure limit: %d" % int(summary[ProceduralMapGenerator.KEY_COUNT_MAX_PIECES_PER_CELL]))


# ------------------------------------------------------------ bounds

func test_nothing_is_generated_in_the_starting_town_or_outside_the_play_area() -> void:
	var generator: ProceduralMapGenerator = _generator()
	for x: int in range(-5, 5):
		for z: int in range(-5, 5):
			assert_eq(generator.cell_kind(Vector2i(x, z)), ProceduralMapGenerator.CellKind.RESERVED, "cell %d %d" % [x, z])
			assert_true(generator.plan_cell(Vector2i(x, z)).is_empty(), "nothing in the 500 m of the test map")
	assert_ne(generator.cell_kind(Vector2i(5, 0)), ProceduralMapGenerator.CellKind.RESERVED, "the next cell is free land")
	for cell: Vector2i in [Vector2i(40, 0), Vector2i(-41, 0), Vector2i(0, 40), Vector2i(0, -41), Vector2i(1000, 1000)]:
		assert_eq(generator.cell_kind(cell), ProceduralMapGenerator.CellKind.OUTSIDE)
		assert_true(generator.plan_cell(cell).is_empty(), "nothing beyond the map")
	assert_eq(generator.min_cell(), Vector2i(-40, -40))
	assert_eq(generator.max_cell(), Vector2i(39, 39))
	# A play area smaller than the cell bounds: only cells wholly inside it.
	var small: ProceduralMapGenerator = ProceduralMapGenerator.new(_settings(), SEED, CELL_M, Vector2(-HALF_M, -HALF_M), Vector2(HALF_M, HALF_M), 520.0, MODULE_M)
	assert_eq(small.max_cell(), Vector2i(9, 9), "the cell from 500 m to 550 m crosses the edge at 520 m")
	assert_eq(small.cell_kind(Vector2i(10, 0)), ProceduralMapGenerator.CellKind.OUTSIDE)
	# A world as small as the old test map gets nothing at all.
	var old: ProceduralMapGenerator = _generator(SEED, null, 250.0)
	assert_eq(int(old.count_summary()[ProceduralMapGenerator.KEY_COUNT_BUILDINGS]), 0, "the 500 m world is all starting town")
	# A cell size that is no whole number of tiles: nothing, no crash.
	var odd: ProceduralMapGenerator = ProceduralMapGenerator.new(_settings(), SEED, 50.5, Vector2(-HALF_M, -HALF_M), Vector2(HALF_M, HALF_M), HALF_M, MODULE_M)
	assert_false(odd.is_usable())
	assert_true(odd.plan_cell(Vector2i(12, 12)).is_empty())


func test_every_building_fits_its_cell_and_the_shipped_definitions() -> void:
	var settings: ProceduralMapSettings = _settings()
	var generator: ProceduralMapGenerator = _generator(SEED, settings)
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	var structures: StructureCatalog = StructureCatalog.load_directory()
	var road: int = ceili(settings.road_half_width_m / MODULE_M)
	var seen_ids: Dictionary[String, bool] = {}
	var checked: int = 0
	var with_rooms: int = 0
	for x: int in range(generator.min_cell().x, generator.max_cell().x + 1):
		for z: int in range(generator.min_cell().y, generator.max_cell().y + 1):
			var cell: Vector2i = Vector2i(x, z)
			var plan: ProceduralCellPlan = generator.plan_cell(cell)
			var inner: Rect2i = Rect2i(cell * TILES_PER_CELL + Vector2i(road, road), Vector2i(TILES_PER_CELL - 2 * road, TILES_PER_CELL - 2 * road))
			var footprints: Array[Rect2i] = []
			for building: ProceduralBuilding in plan.buildings:
				checked += 1
				var definition: MapBuildingDefinition = building.definition
				var footprint: Rect2i = building.footprint()
				if not definition.validate().is_empty():
					fail("%s: %s" % [definition.building_id, "; ".join(definition.validate())])
				if seen_ids.has(definition.building_id):
					fail("duplicate building id " + definition.building_id)
				seen_ids[definition.building_id] = true
				if not inner.encloses(footprint):
					fail("%s leaves its block: %s" % [definition.building_id, str(footprint)])
				for other: Rect2i in footprints:
					if footprint.grow(1).intersects(other):
						fail("%s touches another building" % definition.building_id)
				footprints.append(footprint)
				var doors: int = 0
				for piece: Dictionary in building.pieces(true):
					var piece_definition: StructureDefinition = structures.get_definition(str(piece[MapBuildingPlan.KEY_DEFINITION_ID]))
					var tile: Vector2i = piece[MapBuildingPlan.KEY_TILE]
					var home: Vector2i = grid.tile_of(grid.slot_home(StructureGrid.slot_of(piece_definition.placement, tile, int(piece[MapBuildingPlan.KEY_ROTATION]))))
					if not Rect2i(cell * TILES_PER_CELL, Vector2i(TILES_PER_CELL, TILES_PER_CELL)).has_point(home) or not footprint.has_point(tile):
						fail("%s: a piece lies outside its cell or its building" % definition.building_id)
					if piece_definition.is_door:
						doors += 1
				if doors != 1 + building.interior_door_count():
					fail("%s: one outer door and one door per interior wall" % definition.building_id)
				if building.interior_door_count() > 0:
					with_rooms += 1
			for position: Vector3 in plan.zombie_positions:
				var tile: Vector2i = grid.tile_of(position)
				if inner.has_point(tile) or not Rect2i(cell * TILES_PER_CELL, Vector2i(TILES_PER_CELL, TILES_PER_CELL)).has_point(tile):
					fail("a zombie of cell %s does not stand in its street" % str(cell))
	assert_true(checked >= 1500, "every building of the map was checked: %d" % checked)
	assert_true(with_rooms * 3 > checked, "many buildings have rooms: %d of %d" % [with_rooms, checked])


func test_building_ids_are_stable_snake_case() -> void:
	assert_eq(ProceduralMapGenerator.building_id_of(Vector2i(-12, 3), 0), "gen_n12_p3_0")
	assert_eq(ProceduralMapGenerator.building_id_of(Vector2i(0, -1), 4), "gen_p0_n1_4")
	assert_true(ItemInstance.is_valid_definition_id(ProceduralMapGenerator.building_id_of(Vector2i(-40, 39), 8)))
	assert_eq(MapBuildingPlan.container_source_key(ProceduralMapGenerator.MAP_ID, "gen_n12_p3_0", 2), "procedural/gen_n12_p3_0/2")
