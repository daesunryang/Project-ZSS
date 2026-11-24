extends TestCase
## F-33: the generated map through WorldPersistence and real files (docs/10,
## docs/09 §15.1, §15.3.1): save -> process "restart" (a brand-new world
## object from disk) -> restore.
##   - a generated cell comes back exactly as it was left, with what was
##     changed in it, and is not generated again; the world keeps its seed;
##   - a world that was saved as the 500 m test map loads under the 4 km
##     settings with its starting town untouched, and gets the generated map
##     in the cells beyond its old edge when they are first loaded.

const WORLD: String = "procedural_persist_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const SEED: int = 20261123
const OTHER_SEED: int = 99
const CELL_M: float = 50.0
const OLD_HALF_EXTENT_M: float = 250.0
const KIND_STRUCTURE: String = BuildingService.ENTITY_KIND_STRUCTURE
const KIND_CONTAINER: String = ContainerService.ENTITY_KIND_CONTAINER
const DRAIN_TICKS: int = 5000
const FLOORS: bool = false

var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/procedural_persist_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## The shipped composition with the test map and the generated map, nothing
## that moves by itself, cells released as soon as nobody wants them.
func _config(seed_value: int = SEED) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.preload_lookahead_sec = 0.0
	config.world_cells.deactivate_delay_sec = 0.0
	config.world_cells.unload_delay_sec = 0.0
	config.world_cells.max_preload_loads_per_refresh = 1000
	config.map_content = MapContentDefinition.load_or_null()
	config.procedural_map = (ProceduralMapSettings.load_or_null() as ProceduralMapSettings).duplicate(true) as ProceduralMapSettings
	config.procedural_map.world_seed = seed_value
	config.procedural_map.town_zombies_per_cell_max = 0
	config.procedural_map.roadside_zombie_percent = 0
	config.procedural_map.wild_zombie_per_10000 = 0
	return config


## The same server as it was before F-33: a 500 m world, no generated map.
func _old_config() -> CompositionConfig:
	var config: CompositionConfig = _config()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = OLD_HALF_EXTENT_M
	config.world_cells.bounds_min_m = Vector2(-OLD_HALF_EXTENT_M, -OLD_HALF_EXTENT_M)
	config.world_cells.bounds_max_m = Vector2(OLD_HALF_EXTENT_M, OLD_HALF_EXTENT_M)
	config.procedural_map = null
	return config


func _start(config: CompositionConfig) -> ServerWorld:
	var world: ServerWorld = WorldPersistence.new(SaveService.new(_root), config).load_or_create(WORLD)
	if world == null:
		fail("the world could not be created or loaded")
	return world


func _save(world: ServerWorld) -> void:
	# The cell store of a saved world is the world save itself: this writes
	# the whole world and waits for it.
	assert_eq(_cells(world).get_store().save_cells(world, PackedStringArray()), OK, "the world is saved")


func _map(world: ServerWorld) -> ProceduralMapService:
	return world.get_system(ProceduralMapService.SYSTEM_ID) as ProceduralMapService


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _move(world: ServerWorld, player_id: String, position: Vector3) -> void:
	world.get_player(player_id).position = position
	_cells(world).refresh(world)


func _drain(world: ServerWorld) -> void:
	for _tick: int in range(DRAIN_TICKS):
		if _map(world).pending_cell_count() == 0:
			return
		world.step_systems(TICK)
	fail("the generated cells were not finished in %d ticks" % DRAIN_TICKS)


func _corner_position(corner: Vector2i) -> Vector3:
	return Vector3(float(corner.x) * CELL_M + 0.5, 0.0, float(corner.y) * CELL_M + 0.5)


func _town_crossing(world: ServerWorld) -> Vector2i:
	for town: Dictionary in _map(world).generator().towns():
		if not bool(town[ProceduralMapGenerator.KEY_TOWN_HOME]):
			return town[ProceduralMapGenerator.KEY_TOWN_CORNER]
	fail("test setup: the map has no town away from the start")
	return Vector2i.ZERO


func _built_cell(world: ServerWorld, crossing: Vector2i) -> Vector2i:
	for x: int in range(crossing.x, crossing.x + 6):
		for z: int in range(crossing.y - 3, crossing.y + 3):
			if _map(world).generator().plan_cell(Vector2i(x, z)).buildings.size() >= 2:
				return Vector2i(x, z)
	fail("test setup: no built cell near the town crossing")
	return crossing


## "id|definition|x|z|rotation|state" of every structure of a cell, sorted.
func _structures_in_cell(world: ServerWorld, cell_id: String) -> PackedStringArray:
	var rows: PackedStringArray = []
	for structure_id: String in world.cell_index.entities_in_cell(cell_id, KIND_STRUCTURE):
		var structure: StructureInstance = _building(world).get_structure(structure_id)
		rows.append("%s|%s|%d|%d|%d|%d" % [structure_id, structure.definition_id, structure.tile.x, structure.tile.y, structure.rotation, structure.construction_state])
	rows.sort()
	return rows


## The same for every structure in memory.
func _all_structures(world: ServerWorld) -> PackedStringArray:
	var rows: PackedStringArray = []
	for cell_id: String in _cells(world).loaded_cell_ids():
		rows.append_array(_structures_in_cell(world, cell_id))
	rows.sort()
	return rows


# ------------------------------------------------------------ restart

func test_a_restarted_server_keeps_generated_cells_and_the_seed() -> void:
	var config: CompositionConfig = _config()
	var world: ServerWorld = _start(config)
	if world == null:
		return
	var crossing: Vector2i = _town_crossing(world)
	var cell: Vector2i = _built_cell(world, crossing)
	var cell_id: String = WorldCellGrid.id_of(cell)
	var player_id: String = world.join("alice").player_id
	_move(world, player_id, _corner_position(crossing))
	_drain(world)
	# One wall is gone before the restart: it must stay gone.
	for structure_id: String in world.cell_index.entities_in_cell(cell_id, KIND_STRUCTURE):
		if _building(world).get_structure(structure_id).definition_id == "dev_wall":
			assert_true(_building(world).remove_structure(world, structure_id).ok)
			break
	var before: PackedStringArray = _structures_in_cell(world, cell_id)
	var containers_before: int = world.cell_index.count_in_cell(cell_id, KIND_CONTAINER)
	var planned: int = _map(world).generator().plan_cell(cell).piece_count(FLOORS)
	assert_eq(before.size(), planned - 1, "the cell was generated, and one wall removed")
	assert_true(containers_before > 0)
	_save(world)
	world = null
	# The restarted server is configured with another seed: the world's wins.
	var restarted: ServerWorld = _start(_config(OTHER_SEED))
	if restarted == null:
		return
	assert_eq(_map(restarted).world_seed(), SEED, "the world keeps the seed it was created with")
	assert_eq(_cells(restarted).loaded_cell_ids().size(), 0, "a start brings no cell into memory")
	assert_eq(_building(restarted).structure_count(), 0)
	var again_id: String = restarted.join("alice").player_id
	_move(restarted, again_id, _corner_position(crossing))
	_drain(restarted)
	assert_eq(_structures_in_cell(restarted, cell_id), before, "the cell came back as it was left: ids, tiles, the missing wall")
	assert_eq(restarted.cell_index.count_in_cell(cell_id, KIND_CONTAINER), containers_before)
	assert_eq(_map(restarted).structures_placed, 0, "explored cells are not generated again")
	assert_eq(_map(restarted).skipped_structures, 0)
	# A town cell nobody was near yet is generated now, with the old seed.
	var far_town: Vector2i = crossing
	for town: Dictionary in _map(restarted).generator().towns():
		if not bool(town[ProceduralMapGenerator.KEY_TOWN_HOME]) and (town[ProceduralMapGenerator.KEY_TOWN_CORNER] as Vector2i) != crossing:
			far_town = town[ProceduralMapGenerator.KEY_TOWN_CORNER]
			break
	assert_ne(far_town, crossing, "the map has a second town")
	var fresh_cell: Vector2i = _built_cell(restarted, far_town)
	_move(restarted, again_id, _corner_position(far_town))
	_drain(restarted)
	var expected: ProceduralMapGenerator = ProceduralMapGenerator.new(ProceduralMapSettings.load_or_null(), SEED, CELL_M, Vector2(-2000.0, -2000.0), Vector2(2000.0, 2000.0), 2000.0, 1.0)
	assert_eq(restarted.cell_index.count_in_cell(WorldCellGrid.id_of(fresh_cell), KIND_STRUCTURE), expected.plan_cell(fresh_cell).piece_count(FLOORS), "new cells follow the world's own seed")
	assert_true(_map(restarted).structures_placed > 0)


# ------------------------------------------------------------ older worlds

func test_a_world_saved_as_the_500_m_map_loads_and_grows() -> void:
	var old_config: CompositionConfig = _old_config()
	assert_eq(old_config.validate().size(), 0, "; ".join(old_config.validate()))
	var old_world: ServerWorld = _start(old_config)
	if old_world == null:
		return
	assert_true(_map(old_world).to_world_document().is_empty(), "the old world knows nothing of a generated map")
	# A player walked around the starting town and built a wall at its edge.
	var player_id: String = old_world.join("alice").player_id
	_move(old_world, player_id, Vector3(240.0, 0.0, 240.0))
	var own_wall: ActionResult = _building(old_world).place_structure(old_world, "dev_wall", Vector2i(245, 245), 0, player_id)
	assert_true(own_wall.ok, own_wall.reason)
	_save(old_world)
	assert_eq(_cells(old_world).load_all_saved_cells(old_world).size(), 0)
	var town_before: PackedStringArray = _all_structures(old_world)
	var content: MapContentDefinition = MapContentDefinition.load_or_null()
	assert_eq(town_before.size(), content.piece_count() + 1, "the starting town and the player's wall")
	var containers_before: int = (old_world.get_system(ContainerService.SYSTEM_ID) as ContainerService).container_count()
	old_world = null
	# The same save under the shipped 4 km settings.
	var config: CompositionConfig = _config()
	var world: ServerWorld = _start(config)
	if world == null:
		return
	assert_eq(world.gameplay.world_half_extent_m, 2000.0)
	assert_true((world.get_system(MapContentService.SYSTEM_ID) as MapContentService).is_seeded(), "the test map is not seeded again")
	assert_eq(_map(world).world_seed(), SEED, "the old world takes the configured seed at its first start")
	assert_eq(_cells(world).load_all_saved_cells(world).size(), 0, "every old cell loads")
	assert_eq(_all_structures(world), town_before, "the starting town and what players built are untouched")
	assert_eq((world.get_system(ContainerService.SYSTEM_ID) as ContainerService).container_count(), containers_before)
	for cell_id: String in _cells(world).loaded_cell_ids():
		assert_true(_map(world).to_cell_document(cell_id).is_empty(), "no old cell is touched by the generator")
	assert_eq(_map(world).structures_placed, 0)
	# The player is where it was, and walks out of the old world.
	var again: PlayerState = world.join("alice")
	assert_true(again.position.distance_to(Vector3(240.0, 0.0, 240.0)) < 0.01, "the player kept its place")
	_move(world, again.player_id, Vector3(400.5, 0.0, 0.5))
	_drain(world)
	assert_true(_map(world).structures_placed > 100, "beyond the old edge the home town is generated: %d pieces" % _map(world).structures_placed)
	assert_true(_map(world).buildings_placed >= 5)
	_save(world)
	# And the grown world restarts like any other.
	var grown: ServerWorld = _start(_config())
	if grown == null:
		return
	assert_eq(_cells(grown).load_all_saved_cells(grown).size(), 0)
	assert_eq(_all_structures(grown).size(), town_before.size() + _map(world).structures_placed, "the starting town plus what was generated")
	assert_eq(_map(grown).structures_placed, 0)
