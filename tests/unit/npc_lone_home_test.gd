extends TestCase
## F-28 (docs/09 §17.13): the NPCs of the roster live alone in generated
## buildings. In a world with the generated map every NPC of the roster gets
## a building of its own, chosen with the world seed: houses, one NPC per
## building, spread over the towns and the countryside, the same after a
## restart and in every world with that seed. What it uses there (bed,
## water, the containers with its food) is derived from the building. It
## eats what the containers hold (their loot and the home stock, never
## refilled) and nothing sends it to work. A world that placed its NPCs in
## the houses of the test map before moves each of them once.
##
## The shipped composition and generated map, without generated zombies (an
## NPC flees what it sees; a zombie in the street would decide the day).
## The two tests of living at home run without the survival layer of F-29:
## with it the NPC leaves its house to search the neighbourhood
## (tests/unit/npc_scavenge_test.gd).
## NPCs in the houses of the test map (the controlled setup of the other NPC
## tests): npc_cell_persistence_test.gd, npc_behaviour_day_test.gd.

const WORLD: String = "npc_lone_home_world"
const OTHER_WORLD: String = "npc_lone_home_world_b"
const SEED: int = 20261123
const OTHER_SEED: int = 4242
const CELL_M: float = 50.0
const HALF_M: float = 2000.0
const MODULE_M: float = 1.0
const TICK: float = 0.05
const TICKS_PER_HOUR: int = 3000
const NEVER: float = 1.0e9
const ROSTER_ID: String = "dev_npc_roster"
const ROSTER_SIZE: int = 10
const TOWN: Vector3 = Vector3(0.0, 0.0, 0.0)
## Three of ten live outside every town (countryside_per_mille 300).
const RURAL_HOMES: int = 3
## Ticks for the cells around a player to come into memory and be built.
const ARRIVE_TICKS: int = 40
## Wall-clock bounds (assert_time_bound: a warning unless ZSS_STRICT_TIMING).
const CHOOSING_BOUND_MS: float = 200.0
const SEEDING_BOUND_MS: float = 3000.0

var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/npc_lone_home_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _procedural(seed_value: int = SEED) -> ProceduralMapSettings:
	var settings: ProceduralMapSettings = (ProceduralMapSettings.load_or_null() as ProceduralMapSettings).duplicate(true) as ProceduralMapSettings
	settings.world_seed = seed_value
	settings.town_zombies_per_cell_max = 0
	settings.roadside_zombie_percent = 0
	settings.wild_zombie_per_10000 = 0
	return settings


func _generator(seed_value: int = SEED) -> ProceduralMapGenerator:
	return ProceduralMapGenerator.new(_procedural(seed_value), seed_value, CELL_M, Vector2(-HALF_M, -HALF_M), Vector2(HALF_M, HALF_M), HALF_M, MODULE_M)


## The shipped composition of a dedicated server (the test map, the roster,
## the generated map when `procedural` is given), NPCs that stand still, and
## nothing else that moves by itself.
func _config(procedural: ProceduralMapSettings) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.npc_behaviour = null
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = WorldCellSettings.load_or_default().duplicate() as WorldCellSettings
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.preload_lookahead_sec = 0.0
	config.map_content = MapContentDefinition.load_or_null()
	config.npc_roster = NpcRoster.load_or_null()
	config.procedural_map = procedural
	return config


func _boot(config: CompositionConfig, world_id: String = WORLD) -> ServerWorld:
	return WorldPersistence.new(SaveService.new(_root), config).load_or_create(world_id)


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _map(world: ServerWorld) -> ProceduralMapService:
	return world.get_system(ProceduralMapService.SYSTEM_ID) as ProceduralMapService


func _run(world: ServerWorld, ticks: int) -> void:
	for tick: int in range(ticks):
		world.step_systems(TICK)


## {definition_id: building_id} of the roster, as the world chose it.
func _homes(world: ServerWorld) -> Dictionary:
	var homes: Dictionary = {}
	for definition_id: String in NpcRoster.load_or_null().npc_definition_ids:
		homes[definition_id] = _npcs(world).seeded_home(ROSTER_ID, definition_id)
	return homes


func _read_json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary


## Every NPC document on disk, by id (an id that is there twice fails).
func _npcs_on_disk(world_id: String = WORLD) -> Dictionary:
	var save: SaveService = SaveService.new(_root)
	var base: String = save.world_dir(world_id)
	var found: Dictionary = {}
	var world_part: Dictionary = (_read_json(base.path_join(SaveService.WORLD_STATE_FILE))["systems"] as Dictionary).get(NpcService.SYSTEM_ID, {})
	var lists: Array = [world_part.get(NpcService.KEY_NPCS, [])]
	for cell_id: String in save.saved_cell_ids(world_id):
		var cell: Dictionary = _read_json(base.path_join(SaveService.cell_file(cell_id)))
		lists.append(((cell["systems"] as Dictionary).get(NpcService.SYSTEM_ID, {}) as Dictionary).get(NpcService.KEY_NPCS, []))
	for list: Array in lists:
		for npc: Dictionary in list:
			var npc_id: String = str(npc[NpcState.KEY_NPC_ID])
			if found.has(npc_id):
				fail("%s is on disk twice" % npc_id)
			found[npc_id] = npc
	return found


func _home_document(npc_document: Dictionary) -> Dictionary:
	return (npc_document[NpcState.KEY_COMPONENTS] as Dictionary).get(NpcHome.COMPONENT_ID, {})


## Units of food (items that lower hunger) in the containers of a building
## that are in memory.
func _food_in(world: ServerWorld, layout: NpcHomeLayout) -> int:
	var containers: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
	var total: int = 0
	for index: int in range(layout.food_offsets.size()):
		var container: ContainerInstance = containers.get_container(containers.container_id_of_source(MapBuildingPlan.container_source_key(ProceduralMapGenerator.MAP_ID, layout.building_id, index)))
		if container != null:
			total += _food_units(world, container.inventory_id)
	return total


func _food_units(world: ServerWorld, inventory_id: String) -> int:
	var total: int = 0
	for item: ItemInstance in world.inventory.items_in_inventory(inventory_id):
		var definition: ItemDefinition = world.inventory.definition_of(item.item_instance_id)
		if definition != null and definition.consume_hunger_reduction > 0.0:
			total += item.quantity
	return total


# ------------------------------------------------------------ pure data

func test_the_shipped_home_settings_are_valid() -> void:
	var settings: NpcHomeSettings = NpcHomeSettings.load_or_default()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	assert_true(settings.lone_homes, "a dedicated server gives lone homes")
	var config: CompositionConfig = _config(_procedural())
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var bad: NpcHomeSettings = NpcHomeSettings.new()
	bad.stock_item_id = "dev_nails"
	assert_true("; ".join(bad.validate_against(config.catalog)).contains("must be food"))
	bad.stock_item_id = ""
	assert_true("; ".join(bad.validate()).contains("go together"))
	bad.home_building_types = PackedStringArray()
	assert_true("; ".join(bad.validate()).contains("home_building_types"))


func test_every_generated_building_gives_a_home_layout_inside_itself() -> void:
	var generator: ProceduralMapGenerator = _generator()
	var buildings: int = 0
	var without_layout: int = 0
	for x: int in range(generator.min_cell().x, generator.max_cell().x + 1):
		for z: int in range(generator.min_cell().y, generator.max_cell().y + 1):
			for building: ProceduralBuilding in generator.plan_cell(Vector2i(x, z)).buildings:
				buildings += 1
				var definition: MapBuildingDefinition = building.definition
				var layout: NpcHomeLayout = NpcHomeLayout.of(definition)
				if not layout.is_valid():
					without_layout += 1
					continue
				var door: Vector2i = (MapBuildingPlan.door_piece(definition)[MapBuildingPlan.KEY_TILE] as Vector2i) - definition.origin_tile
				var used: Dictionary = {door: "door"}
				for placement: MapContainerPlacement in definition.containers:
					used[placement.tile_offset] = "container"
				for entry: Array in [["home", layout.home_offset], ["bed", layout.bed_offset], ["water", layout.water_offset]]:
					var offset: Vector2i = entry[1]
					if offset.x < 0 or offset.y < 0 or offset.x >= definition.size_tiles.x or offset.y >= definition.size_tiles.y:
						fail("%s: %s lies outside the building" % [definition.building_id, entry[0]])
					if used.has(offset):
						fail("%s: %s is on the tile of %s" % [definition.building_id, entry[0], used[offset]])
					used[offset] = entry[0]
				if layout.food_offsets.size() != definition.containers.size():
					fail("%s: one food spot per container" % definition.building_id)
	assert_true(buildings > 1000, "the shipped map has thousands of buildings (%d)" % buildings)
	assert_eq(without_layout, 0, "every one of them can be lived in")
	assert_true(get_failures().is_empty(), "every layout is inside its building, on free tiles")


func test_building_ids_and_spot_ids_are_read_back() -> void:
	var generator: ProceduralMapGenerator = _generator()
	for cell: Vector2i in [Vector2i(-12, 3), Vector2i(0, 0), Vector2i(7, -40)]:
		var building_id: String = ProceduralMapGenerator.building_id_of(cell, 2)
		var parsed: Dictionary = ProceduralMapGenerator.parse_building_id(building_id)
		assert_eq(parsed.get(ProceduralMapGenerator.KEY_PARSED_CELL, null), cell, building_id)
		assert_eq(parsed.get(ProceduralMapGenerator.KEY_PARSED_INDEX, -1), 2)
	for bad: String in ["", "house_a", "gen_n1_p2", "gen_x1_p2_0", "gen_n0_p2_0", "gen_p1_p2_-1", "gen_p01_p2_0", "gen_p1_p2_0_bed"]:
		assert_true(ProceduralMapGenerator.parse_building_id(bad).is_empty(), "'%s' is no generated building id" % bad)
	assert_null(generator.building_by_id("house_a"))
	assert_null(generator.building_by_id(ProceduralMapGenerator.building_id_of(Vector2i(0, 0), 0)), "nothing is generated in the starting town")
	var picked: ProceduralBuilding = NpcHomePicker.new(generator, NpcHomeSettings.new()).pick("somebody", {})
	assert_not_null(picked)
	if picked == null:
		return
	assert_eq(generator.building_by_id(picked.building_id()).summary(), picked.summary(), "an id gives its building back")
	var layout: NpcHomeLayout = NpcHomeLayout.of(picked.definition)
	var ids: PackedStringArray = layout.spot_ids()
	assert_eq(ids.size(), 2 + picked.definition.containers.size(), "a bed, water and one food spot per container")
	for spot_id: String in ids:
		assert_true(NpcComponent.is_valid_id(spot_id), "%s can be saved as a spot id" % spot_id)
		assert_eq(NpcHomeLayout.building_id_of_spot(spot_id), picked.building_id())
		var spot: NpcSpotDefinition = layout.spot(spot_id)
		assert_not_null(spot)
		assert_eq(spot.validate().size(), 0)
		assert_eq(spot.exclusive, spot.kind != NpcSpotDefinition.KIND_FOOD, "one NPC per bed and water point")
	assert_eq(layout.spot_ids(NpcSpotDefinition.KIND_WORK).size(), 0, "nobody works in a home")
	assert_null(layout.spot(picked.building_id() + "_food_99"))
	assert_null(layout.spot(picked.building_id() + "_desk"))
	assert_eq(NpcHomeLayout.building_id_of_spot("bed_house_a_1"), "", "a spot of the hand-made spot set is no generated spot")
	# The resolver the executor asks: generated spots by id, without a list.
	var homes: NpcHomes = NpcHomes.new(NpcHomeSettings.new(), null, StructureGrid.new(MODULE_M))
	assert_null(homes.generated_spot(layout.bed_spot_id()), "no generated map, no generated spots")
	assert_false(homes.gives_lone_homes())
	homes.set_generator_source(func() -> ProceduralMapGenerator: return generator)
	assert_true(homes.gives_lone_homes())
	assert_eq(homes.generated_spot(layout.bed_spot_id()).tile_offset, layout.bed_offset)
	assert_eq(homes.generated_spot_position(layout.bed_spot_id()), StructureGrid.new(MODULE_M).tile_center(layout.origin_tile + layout.bed_offset))
	assert_null(homes.generated_spot("bed_house_a_1"))
	assert_null(homes.generated_spot("gen_p0_p0_0_bed"), "no such building")
	assert_eq(homes.generated_spot_ids(picked.building_id(), NpcSpotDefinition.KIND_BED), PackedStringArray([layout.bed_spot_id()]))


func test_the_picker_gives_every_npc_a_house_of_its_own_spread_over_the_map() -> void:
	var generator: ProceduralMapGenerator = _generator()
	var settings: NpcHomeSettings = NpcHomeSettings.load_or_default()
	var roster: NpcRoster = NpcRoster.load_or_null()
	assert_eq(roster.npc_definition_ids.size(), ROSTER_SIZE)
	var started_usec: int = Time.get_ticks_usec()
	var picker: NpcHomePicker = NpcHomePicker.new(generator, settings)
	var taken: Dictionary = {}
	var chosen: PackedStringArray = []
	var towns: Dictionary = {}
	var rural: int = 0
	var planned: int = 0
	for definition_id: String in roster.npc_definition_ids:
		var building: ProceduralBuilding = picker.pick(definition_id, taken)
		planned += picker.last_planned_cell_count
		assert_not_null(building, "a home for %s" % definition_id)
		if building == null:
			return
		assert_false(taken.has(building.building_id()), "one NPC per building")
		assert_true(settings.home_building_types.has(building.definition.building_type), "%s lives in a house (%s)" % [definition_id, building.definition.building_type])
		assert_true(NpcHomePicker.is_home(building))
		var town: int = generator.town_of(building.cell)
		if town < 0:
			rural += 1
			assert_ne(generator.cell_kind(building.cell), ProceduralMapGenerator.CellKind.TOWN)
		else:
			assert_false(towns.has(town), "no town gets a second NPC while others have none")
			towns[town] = true
		taken[building.building_id()] = true
		chosen.append(building.building_id())
	var elapsed_ms: float = float(Time.get_ticks_usec() - started_usec) / 1000.0
	assert_eq(chosen.size(), ROSTER_SIZE)
	assert_eq(rural, RURAL_HOMES, "three of ten live outside every town")
	assert_eq(towns.size(), ROSTER_SIZE - RURAL_HOMES, "the others each in a town of their own")
	assert_true(planned <= ROSTER_SIZE * settings.cell_attempts * (generator.towns().size() + 2), "the search is bounded (%d cells planned)" % planned)
	print("[f28] choosing %d homes: %.2f ms, %d cells planned, towns %s" % [chosen.size(), elapsed_ms, planned, str(towns.keys())])
	assert_time_bound(elapsed_ms, CHOOSING_BOUND_MS, "choosing ten homes")
	# The same again, whenever it is asked.
	var again: NpcHomePicker = NpcHomePicker.new(_generator(), settings)
	var taken_again: Dictionary = {}
	for index: int in range(ROSTER_SIZE):
		var building: ProceduralBuilding = again.pick(roster.npc_definition_ids[index], taken_again)
		assert_eq(building.building_id(), chosen[index], "the same seed gives the same homes")
		taken_again[building.building_id()] = true
	# An NPC that joins later does not move the others, and takes no home
	# that is taken.
	var late: ProceduralBuilding = again.pick("somebody_new", taken_again)
	assert_not_null(late)
	assert_false(taken_again.has(late.building_id()))
	# Another seed, other homes.
	var other: NpcHomePicker = NpcHomePicker.new(_generator(OTHER_SEED), settings)
	var other_taken: Dictionary = {}
	var same: int = 0
	for index: int in range(ROSTER_SIZE):
		var building: ProceduralBuilding = other.pick(roster.npc_definition_ids[index], other_taken)
		assert_not_null(building)
		other_taken[building.building_id()] = true
		same += 1 if building.building_id() == chosen[index] else 0
	assert_true(same < ROSTER_SIZE, "another world seed gives other homes")
	# No generated map, nobody is placed by the picker.
	assert_null(NpcHomePicker.new(null, settings).pick("somebody", {}))


# ------------------------------------------------------------ a new world

func test_a_new_world_places_the_roster_alone_in_generated_houses_and_keeps_it() -> void:
	var config: CompositionConfig = _config(_procedural())
	var world: ServerWorld = _boot(config)
	assert_not_null(world)
	if world == null:
		return
	var service: NpcService = _npcs(world)
	var report: Dictionary = service.last_seed_report
	assert_eq(service.population_count(), ROSTER_SIZE)
	assert_true(service.is_seeded())
	assert_eq(service.npc_count(), 0, "the far cells the seeding loaded were saved and released")
	assert_eq(int(report[NpcService.REPORT_NPCS]), ROSTER_SIZE)
	assert_eq(int(report[NpcService.REPORT_GENERATED_HOMES]), ROSTER_SIZE, "every NPC got a generated home")
	assert_true(int(report[NpcService.REPORT_CELLS_LOADED]) <= ROSTER_SIZE, "at most one cell per NPC was loaded")
	var seeding_ms: float = float(int(report[NpcService.REPORT_USEC])) / 1000.0
	print("[f28] new world on disk: %d NPCs in generated homes, %d cells loaded, seeding %.1f ms (choosing %.2f ms), structures placed %d" % [ROSTER_SIZE, int(report[NpcService.REPORT_CELLS_LOADED]), seeding_ms, float(int(report[NpcService.REPORT_CHOOSING_USEC])) / 1000.0, _map(world).structures_placed])
	assert_time_bound(seeding_ms, SEEDING_BOUND_MS, "placing ten NPCs in far generated homes (world creation)")
	var generator: ProceduralMapGenerator = _map(world).generator()
	var homes: Dictionary = _homes(world)
	var seen: Dictionary = {}
	var rural: int = 0
	var towns: Dictionary = {}
	for definition_id: String in homes:
		var building: ProceduralBuilding = generator.building_by_id(str(homes[definition_id]))
		assert_not_null(building, "%s lives in a building of the generated map" % definition_id)
		if building == null:
			return
		assert_false(seen.has(building.building_id()), "one NPC per building")
		seen[building.building_id()] = true
		assert_eq(building.definition.building_type, "house")
		if generator.town_of(building.cell) < 0:
			rural += 1
		else:
			towns[generator.town_of(building.cell)] = true
	assert_eq(rural, RURAL_HOMES)
	assert_eq(towns.size(), ROSTER_SIZE - RURAL_HOMES, "not all in one town")
	# On disk before anybody joined: each NPC once, in its home.
	var on_disk: Dictionary = _npcs_on_disk()
	assert_eq(on_disk.size(), ROSTER_SIZE)
	var grid: StructureGrid = StructureGrid.new(config.building.grid_module_m)
	for definition_id: String in homes:
		var document: Dictionary = on_disk[service.seeded_npc_id(ROSTER_ID, definition_id)]
		var home: Dictionary = _home_document(document)
		assert_eq(str(home.get(NpcHome.KEY_SOURCE, "")), NpcHome.SOURCE_GENERATED)
		assert_eq(str(home.get(NpcHome.KEY_BUILDING_ID, "")), str(homes[definition_id]))
		var layout: NpcHomeLayout = NpcHomeLayout.of(generator.building_by_id(str(homes[definition_id])).definition)
		var position: Array = document[NpcState.KEY_POSITION]
		var tile: Vector2i = grid.tile_of(Vector3(float(position[0]), float(position[1]), float(position[2])))
		assert_eq(tile, layout.home_tile(), "%s stands on the home tile of its house" % definition_id)
		assert_true(Rect2i(layout.origin_tile, layout.size_tiles).has_point(tile))
	var sequence: int = world.ids.get_next_sequence()

	# A restart: the same homes, nobody placed again.
	var second: ServerWorld = _boot(config)
	assert_not_null(second, "the save loads")
	if second == null:
		return
	assert_eq(second.ids.get_next_sequence(), sequence, "the restart placed nobody and nothing")
	assert_eq(_homes(second), homes, "the same homes after a restart")
	assert_eq(_npcs(second).npc_count(), 0)
	# The starting town has no NPC any more.
	var alice: PlayerState = second.join("alice")
	alice.position = TOWN
	_run(second, ARRIVE_TICKS)
	assert_eq(_npcs(second).npc_count(), 0, "nobody lives in the houses of the starting town")
	assert_eq(_npcs(second).pending_relocation_count(), 0)
	# Somebody walks to a home: the NPC is there, in a house that stands.
	var first_definition: String = NpcRoster.load_or_null().npc_definition_ids[0]
	var layout: NpcHomeLayout = NpcHomeLayout.of(generator.building_by_id(str(homes[first_definition])).definition)
	var home_position: Vector3 = grid.tile_center(layout.home_tile())
	alice.position = home_position
	_run(second, ARRIVE_TICKS)
	var npc_id: String = _npcs(second).seeded_npc_id(ROSTER_ID, first_definition)
	var npc: NpcState = _npcs(second).get_npc(npc_id)
	assert_not_null(npc, "the NPC is in memory when a player is at its home")
	if npc == null:
		return
	assert_eq(npc.position, home_position)
	assert_true(_npcs(second).is_awake(npc_id))
	var home: NpcHome = NpcHome.of(npc)
	assert_true(home.is_generated())
	assert_eq(home.building_id, layout.building_id)
	assert_false(home.has_work_place(_npcs(second).definition_of(npc_id)), "an NPC that lives alone has no work place")
	var cell_id: String = second.cell_id_at(home_position)
	assert_true(_map(second).is_cell_complete(cell_id), "the house was built when the NPC was put into it")
	var building: BuildingService = second.get_system(BuildingService.SYSTEM_ID) as BuildingService
	assert_true(building.structure_ids_in_cell(second, cell_id).size() >= MapBuildingPlan.structure_pieces(generator.building_by_id(layout.building_id).definition).size() - layout.size_tiles.x * layout.size_tiles.y, "its walls and door stand")
	var containers: ContainerService = second.get_system(ContainerService.SYSTEM_ID) as ContainerService
	for index: int in range(layout.food_offsets.size()):
		var container: ContainerInstance = containers.get_container(containers.container_id_of_source(MapBuildingPlan.container_source_key(ProceduralMapGenerator.MAP_ID, layout.building_id, index)))
		assert_not_null(container)
		assert_true(container.searched, "the NPC knows what is in the containers of its home")
	assert_true(_food_in(second, layout) >= NpcHomeSettings.load_or_default().stock_units, "the home has its stock (%d units of food)" % _food_in(second, layout))
	assert_false(" | ".join(GameLogger.captured_lines()).contains("[ERROR]"), "no errors on the way")

	# Another world with the same seed: the same homes. Another seed: others.
	var twin: ServerWorld = _boot(config, OTHER_WORLD)
	assert_not_null(twin)
	if twin != null:
		assert_eq(_homes(twin), homes, "the same world seed gives the same homes")
	SaveService.remove_tree(_root)
	var other: ServerWorld = _boot(_config(_procedural(OTHER_SEED)), OTHER_WORLD)
	assert_not_null(other)
	if other != null:
		assert_ne(_homes(other), homes, "another world seed gives other homes")
		assert_eq(int(_npcs(other).last_seed_report[NpcService.REPORT_GENERATED_HOMES]), ROSTER_SIZE)


func test_lone_homes_can_be_turned_off_and_need_a_generated_map() -> void:
	# No generated map: the houses of the test map, as before.
	var plain: ServerWorld = _boot(_config(null))
	assert_not_null(plain)
	if plain == null:
		return
	assert_eq(_npcs(plain).population_count(), ROSTER_SIZE)
	assert_eq(int(_npcs(plain).last_seed_report[NpcService.REPORT_GENERATED_HOMES]), 0)
	print("[f28] new world on disk without a generated map (the houses of the test map): seeding %.1f ms" % (float(int(_npcs(plain).last_seed_report[NpcService.REPORT_USEC])) / 1000.0))
	var alice: PlayerState = plain.join("alice")
	alice.position = TOWN
	_run(plain, ARRIVE_TICKS)
	assert_eq(_npcs(plain).npc_count(), ROSTER_SIZE, "all in the starting town")
	for npc_id: String in _npcs(plain).npc_ids():
		assert_false(NpcHome.of(_npcs(plain).get_npc(npc_id)).is_generated())
		assert_true(NpcHome.of(_npcs(plain).get_npc(npc_id)).has_work_place(_npcs(plain).definition_of(npc_id)), "with the work place its definition names")
	SaveService.remove_tree(_root)
	# The setting off: the same, even with a generated map.
	var config: CompositionConfig = _config(_procedural())
	config.npc_homes = NpcHomeSettings.load_or_default().duplicate() as NpcHomeSettings
	config.npc_homes.lone_homes = false
	var off: ServerWorld = _boot(config)
	assert_not_null(off)
	if off == null:
		return
	assert_eq(int(_npcs(off).last_seed_report[NpcService.REPORT_GENERATED_HOMES]), 0)
	assert_eq(_npcs(off).seeded_home(ROSTER_ID, NpcRoster.load_or_null().npc_definition_ids[0]), "")


# ------------------------------------------------------------ a world from before

func test_a_world_that_placed_its_npcs_in_the_test_map_moves_each_of_them_once() -> void:
	# A world from before this ticket: no generated map, the NPCs in the
	# three houses of the test map.
	var old_world: ServerWorld = _boot(_config(null))
	assert_not_null(old_world)
	if old_world == null:
		return
	var ids: PackedStringArray = _npcs(old_world).population_ids()
	assert_eq(ids.size(), ROSTER_SIZE)
	for npc_id: String in _npcs_on_disk():
		assert_eq(str(_home_document(_npcs_on_disk()[npc_id]).get(NpcHome.KEY_SOURCE, "")), NpcHome.SOURCE_DEFINITION)
	# The next start has the generated map: homes are chosen, nobody is
	# placed, and nobody moves before it is in memory.
	var config: CompositionConfig = _config(_procedural())
	var world: ServerWorld = _boot(config)
	assert_not_null(world, "the old save loads")
	if world == null:
		return
	var service: NpcService = _npcs(world)
	assert_eq(service.population_ids(), ids, "nobody new")
	var homes: Dictionary = _homes(world)
	for definition_id: String in homes:
		assert_false(str(homes[definition_id]).is_empty(), "a home was chosen for %s" % definition_id)
	assert_eq(int(service.last_seed_report[NpcService.REPORT_HOMES_CHOSEN]), ROSTER_SIZE)
	assert_eq(int(service.last_seed_report[NpcService.REPORT_NPCS]), 0)
	assert_eq(service.relocated_count, 0)
	# A player in the starting town brings them into memory: they move, one
	# per tick.
	var alice: PlayerState = world.join("alice")
	alice.position = TOWN
	_run(world, ARRIVE_TICKS)
	assert_eq(service.relocated_count, ROSTER_SIZE, "every NPC moved")
	assert_eq(service.pending_relocation_count(), 0)
	print("[f28] old world: %d NPCs moved to generated homes, slowest move %.1f ms" % [service.relocated_count, float(service.max_relocation_usec) / 1000.0])
	var grid: StructureGrid = StructureGrid.new(config.building.grid_module_m)
	var generator: ProceduralMapGenerator = _map(world).generator()
	var food_per_home: PackedInt32Array = []
	for definition_id: String in homes:
		var npc_id: String = service.seeded_npc_id(ROSTER_ID, definition_id)
		var npc: NpcState = service.get_npc(npc_id)
		assert_not_null(npc, "a moved NPC is in memory until its new cell is released")
		if npc == null:
			continue
		var layout: NpcHomeLayout = NpcHomeLayout.of(generator.building_by_id(str(homes[definition_id])).definition)
		assert_eq(npc.position, grid.tile_center(layout.home_tile()))
		assert_true(NpcHome.of(npc).is_generated())
		assert_eq(NpcHome.of(npc).building_id, layout.building_id)
		assert_false(service.is_awake(npc_id), "nobody is near its new home")
		assert_true(_map(world).is_cell_complete(world.cell_id_at(npc.position)))
		assert_true(_food_in(world, layout) >= NpcHomeSettings.load_or_default().stock_units)
		food_per_home.append(_food_in(world, layout))
	print("[f28] units of food per home (the loot of its containers + the home stock of %d; the loot seed of a world is random): %s" % [NpcHomeSettings.load_or_default().stock_units, str(food_per_home)])
	assert_eq(WorldPersistence.new(SaveService.new(_root), config).save(world), OK)
	var on_disk: Dictionary = _npcs_on_disk()
	assert_eq(on_disk.size(), ROSTER_SIZE, "every NPC is on disk once")
	for npc_id: String in on_disk:
		assert_eq(str(_home_document(on_disk[npc_id]).get(NpcHome.KEY_SOURCE, "")), NpcHome.SOURCE_GENERATED)
	var sequence: int = world.ids.get_next_sequence()
	# And never again.
	var later: ServerWorld = _boot(config)
	assert_not_null(later)
	if later == null:
		return
	assert_eq(_homes(later), homes)
	var alice2: PlayerState = later.join("alice")
	alice2.position = TOWN
	_run(later, ARRIVE_TICKS)
	assert_eq(_npcs(later).relocated_count, 0, "nobody moves a second time")
	assert_eq(_npcs(later).npc_count(), 0, "the starting town is empty")
	assert_eq(later.ids.get_next_sequence(), sequence)
	assert_eq(_npcs(later).population_ids(), ids)
	assert_false(" | ".join(GameLogger.captured_lines()).contains("[ERROR]"), "no errors on the way")
	# With relocate_existing off an old world keeps its NPCs where they are.
	SaveService.remove_tree(_root)
	assert_not_null(_boot(_config(null)))
	var keep: CompositionConfig = _config(_procedural())
	keep.npc_homes = NpcHomeSettings.load_or_default().duplicate() as NpcHomeSettings
	keep.npc_homes.relocate_existing = false
	var kept: ServerWorld = _boot(keep)
	assert_not_null(kept)
	if kept == null:
		return
	var alice3: PlayerState = kept.join("alice")
	alice3.position = TOWN
	_run(kept, ARRIVE_TICKS)
	assert_eq(_npcs(kept).relocated_count, 0)
	assert_eq(_npcs(kept).npc_count(), ROSTER_SIZE, "they stay in the starting town")


func test_npcs_that_were_busy_in_the_test_map_go_on_living_after_they_were_moved() -> void:
	# A world from before, with NPCs in the middle of their morning.
	var before: NpcLifeRun = NpcLifeRun.begin_on_disk(WORLD, _root, TICK)
	assert_not_null(before)
	if before == null:
		return
	before.run_ticks(9 * TICKS_PER_HOUR)
	var busy: int = 0
	for npc_id: String in before.npcs().npc_ids():
		busy += 1 if before.behaviour_of(npc_id).is_running() else 0
	assert_true(busy >= 1, "somebody is in the middle of an action when the world is saved (%d)" % busy)
	assert_eq(before.persistence.save(before.world), OK)
	var ids: PackedStringArray = before.npcs().population_ids()
	before.finish()
	# The next start has the generated map: they come into memory around the
	# observer and are moved.
	var run: NpcLifeRun = NpcLifeRun.begin_on_disk(WORLD, _root, TICK, _procedural(), false)
	assert_not_null(run, "the old save loads")
	if run == null:
		return
	var service: NpcService = run.npcs()
	run.run_ticks(ARRIVE_TICKS)
	assert_eq(service.relocated_count, ROSTER_SIZE)
	assert_eq(service.population_ids(), ids)
	assert_eq(service.awake_count(), 0, "nobody is left near the spawn point")
	# One of them, an hour with a player at its new home.
	var definition_id: String = NpcRoster.load_or_null().npc_definition_ids[0]
	var npc_id: String = service.seeded_npc_id(ROSTER_ID, definition_id)
	var layout: NpcHomeLayout = NpcHomeLayout.of(_map(run.world).generator().building_by_id(service.seeded_home(ROSTER_ID, definition_id)).definition)
	var home_position: Vector3 = StructureGrid.new(MODULE_M).tile_center(layout.home_tile())
	run.observer.position = home_position
	run.run_ticks(ARRIVE_TICKS)
	assert_true(service.is_awake(npc_id))
	var finished_before: int = run.behaviours.finished_count
	var worked_before: int = int(run.counts_of(npc_id)["worked_usec"])
	var farthest: float = 0.0
	for tick: int in range(2 * TICKS_PER_HOUR):
		run.step()
		if tick % 100 == 0:
			var npc: NpcState = service.get_npc(npc_id)
			farthest = maxf(farthest, Vector2(npc.position.x - home_position.x, npc.position.z - home_position.z).length())
	var reach: float = maxf(NpcBehaviourSettings.load_or_default().wander_radius_m, Vector2(layout.size_tiles).length() * MODULE_M) + MODULE_M
	assert_true(run.behaviours.finished_count > finished_before, "it does things at its new home")
	assert_true(farthest <= reach, "and stays there (%.1f m, at most %.1f m)" % [farthest, reach])
	assert_eq(int(run.counts_of(npc_id)["worked_usec"]), worked_before, "it does not go on working")
	var executor: NpcExecutor = run.behaviours.movement_executor()
	var reserved: String = executor.reserved_spot_of(npc_id)
	assert_true(reserved.is_empty() or reserved.begins_with(layout.building_id), "it holds no spot of the test map any more (%s)" % reserved)
	assert_false(" | ".join(GameLogger.captured_lines()).contains("[ERROR]"), "no errors on the way")
	run.finish()



# ------------------------------------------------------------ living there

func test_a_lone_npc_eats_drinks_and_sleeps_in_its_house_and_nothing_sends_it_to_work() -> void:
	var run: NpcLifeRun = NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural(), false)
	assert_not_null(run, "the world could be made")
	if run == null:
		return
	var service: NpcService = run.npcs()
	assert_eq(service.population_count(), ROSTER_SIZE)
	assert_eq(service.npc_count(), 0, "nobody lives near the spawn point")
	var definition_id: String = NpcRoster.load_or_null().npc_definition_ids[0]
	var npc_id: String = service.seeded_npc_id(ROSTER_ID, definition_id)
	var generator: ProceduralMapGenerator = _map(run.world).generator()
	var layout: NpcHomeLayout = NpcHomeLayout.of(generator.building_by_id(service.seeded_home(ROSTER_ID, definition_id)).definition)
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	var home_position: Vector3 = grid.tile_center(layout.home_tile())
	# Tick cost with every NPC far away: nobody is awake, no stage has work.
	run.run_ticks(ARRIVE_TICKS)
	assert_eq(service.awake_count(), 0)
	var far_usec: int = 0
	for tick: int in range(200):
		var started: int = Time.get_ticks_usec()
		run.step()
		far_usec += Time.get_ticks_usec() - started
	print("[f28] tick with ten NPCs in far homes (none in memory): %.3f ms mean, npc stages %.3f ms" % [float(far_usec) / 200000.0, service.last_step_msec])
	# The observer stands in the NPC's house for a day and two hours.
	run.observer.position = home_position
	run.run_ticks(ARRIVE_TICKS)
	assert_true(service.is_awake(npc_id), "the NPC is simulated while a player is near")
	assert_eq(service.awake_count(), 1, "the others are far away")
	var food_before: int = _food_in(run.world, layout)
	assert_true(food_before >= NpcHomeSettings.load_or_default().stock_units)
	var work_rejections: Dictionary = {}
	var work_chosen: Array[int] = [0]
	run.decider.decided.connect(func(decided_id: String, record: Dictionary) -> void:
		if decided_id != npc_id:
			return
		if str(record[NpcUtilityDecider.KEY_CHOSEN]) == NpcBehaviours.ACTION_WORK:
			work_chosen[0] += 1
		for rejected: Dictionary in (record[NpcUtilityDecider.KEY_REJECTED] as Array):
			if str(rejected[NpcUtilityDecider.KEY_ACTION_ID]) == NpcBehaviours.ACTION_WORK:
				work_rejections[str(rejected[NpcUtilityDecider.KEY_CODE])] = true)
	var farthest: float = 0.0
	var reach: float = maxf(NpcBehaviourSettings.load_or_default().wander_radius_m, Vector2(layout.size_tiles).length() * MODULE_M) + MODULE_M
	var busy_usec: int = 0
	for hour: int in range(26):
		for tick: int in range(TICKS_PER_HOUR):
			var started: int = Time.get_ticks_usec()
			run.step()
			busy_usec += Time.get_ticks_usec() - started
			if tick % 100 == 0:
				run.see_labels()
				var npc: NpcState = service.get_npc(npc_id)
				farthest = maxf(farthest, Vector2(npc.position.x - home_position.x, npc.position.z - home_position.z).length())
	var counts: Dictionary = run.counts_of(npc_id)
	print("[f28] a day at home (26 h): %s, farthest %.1f m from the home tile, food %d -> %d, tick %.3f ms mean (one NPC awake)" % [str(counts), farthest, food_before, _food_in(run.world, layout), float(busy_usec) / float(26 * TICKS_PER_HOUR) / 1000.0])
	assert_true(int(counts["eat"]) >= 1, "it ate")
	assert_true(int(counts["drink"]) >= 2, "it drank")
	assert_true(int(counts["sleep"]) + int(counts["sleep_cut"]) + int(counts["rest"]) + int(counts["rest_cut"]) >= 1, "it slept")
	assert_eq(int(counts["work"]), 0, "it did not work")
	assert_eq(int(counts["worked_usec"]), 0)
	assert_eq(work_chosen[0], 0, "the decision layer never chose work")
	assert_true(work_rejections.has(NpcUtilityDecider.REJECT_NO_JOB), "work is refused: it has no work place")
	assert_false((run.labels.get(npc_id, {}) as Dictionary).has("work"), "nobody saw it work")
	assert_true(farthest <= reach, "it stays near its home (%.1f m, at most %.1f m)" % [farthest, reach])
	# What it ate came out of the containers of its house: nothing was added.
	var carried: int = _food_units(run.world, run.behaviour_of(npc_id).inventory_id)
	assert_eq(_food_in(run.world, layout) + int(counts["eat"]) + carried, food_before, "no food appears from nowhere")
	for what: String in run.failure_counts():
		assert_false(what.begins_with("eat ") or what.begins_with("drink ") or what.begins_with("sleep ") or what.begins_with("rest "), "nothing it needs at home failed (%s)" % what)
	assert_true(run.refusal_counts().is_empty(), "nothing it chose was refused: %s" % str(run.refusal_counts()))
	var beds: NpcExecutor = run.behaviours.movement_executor()
	assert_eq(beds.free_spot_ids(NpcSpotDefinition.KIND_WORK, layout.building_id).size(), 0)
	assert_true(beds.has_spot(layout.bed_spot_id()) and beds.has_spot(layout.water_spot_id()))
	assert_false(" | ".join(GameLogger.captured_lines()).contains("[ERROR]"), "no errors on the way")
	run.finish()
