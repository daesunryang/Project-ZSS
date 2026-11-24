extends TestCase
## F-33 (docs/09 §15.3.1): the generated map is placed in a world cell by
## cell, the first time a cell comes into memory, and exactly once: a cell
## that is released and loaded again, half-built or complete, never gets a
## piece twice and keeps what players changed. Nothing is placed when the
## world is created, nothing in the hand-made starting town. Server rules
## only, a memory cell store, no nodes. Real files and a server restart:
## tests/integration/procedural_map_persistence_test.gd.

const WORLD: String = "procedural_map_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
## The shipped setting: generated buildings get no floor pieces.
const FLOORS: bool = false
const SEED: int = 20261123
const OTHER_SEED: int = 4242
const CELL_M: float = 50.0
const KIND_STRUCTURE: String = BuildingService.ENTITY_KIND_STRUCTURE
const KIND_CONTAINER: String = ContainerService.ENTITY_KIND_CONTAINER
const KIND_ZOMBIE: String = ZombieService.ENTITY_KIND_ZOMBIE
## Enough ticks to build everything a player's cells hold.
const DRAIN_TICKS: int = 5000
## Pieces per tick of the test that releases a cell half-built.
const HALF_BUILT_BUDGET: int = 7
## The shipped budget of pieces per tick.
const MAX_PIECES_PER_TICK: int = 24


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## The shipped composition and generated map, nothing that moves by itself,
## no generated zombies (the tests that want them turn them on), cells
## released as soon as nobody wants them.
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
	config.procedural_map = (ProceduralMapSettings.load_or_null() as ProceduralMapSettings).duplicate(true) as ProceduralMapSettings
	config.procedural_map.world_seed = seed_value
	config.procedural_map.town_zombies_per_cell_max = 0
	config.procedural_map.roadside_zombie_percent = 0
	config.procedural_map.wild_zombie_per_10000 = 0
	return config


func _world(config: CompositionConfig = null, store: WorldCellStore = WorldCellStore.new()) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, config if config != null else _config())
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	if world.seed_new_world(DevWorldSeed.new()) != OK:
		fail("test setup: the world could not be seeded")
	return world


func _map(world: ServerWorld) -> ProceduralMapService:
	return world.get_system(ProceduralMapService.SYSTEM_ID) as ProceduralMapService


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _containers(world: ServerWorld) -> ContainerService:
	return world.get_system(ContainerService.SYSTEM_ID) as ContainerService


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


## The street crossing in the middle of the first town away from the start.
func _town_crossing(world: ServerWorld) -> Vector2i:
	for town: Dictionary in _map(world).generator().towns():
		if not bool(town[ProceduralMapGenerator.KEY_TOWN_HOME]):
			return town[ProceduralMapGenerator.KEY_TOWN_CORNER]
	fail("test setup: the map has no town away from the start")
	return Vector2i.ZERO


## A position in the street at a cell corner (nothing is ever built there).
func _corner_position(corner: Vector2i) -> Vector3:
	return Vector3(float(corner.x) * CELL_M + 0.5, 0.0, float(corner.y) * CELL_M + 0.5)


func _move(world: ServerWorld, player_id: String, position: Vector3) -> void:
	world.get_player(player_id).position = position
	_cells(world).refresh(world)


func _drain(world: ServerWorld) -> void:
	for _tick: int in range(DRAIN_TICKS):
		if _map(world).pending_cell_count() == 0:
			return
		world.step_systems(TICK)
	fail("the generated cells were not finished in %d ticks" % DRAIN_TICKS)


## "definition|x|z|rotation" of every structure of a cell, sorted.
func _pieces_in_cell(world: ServerWorld, cell_id: String) -> PackedStringArray:
	var rows: PackedStringArray = []
	for structure_id: String in world.cell_index.entities_in_cell(cell_id, KIND_STRUCTURE):
		var structure: StructureInstance = _building(world).get_structure(structure_id)
		rows.append("%s|%d|%d|%d" % [structure.definition_id, structure.tile.x, structure.tile.y, structure.rotation])
	rows.sort()
	return rows


## The same for what the generator plans for the cell.
func _planned_pieces(world: ServerWorld, cell: Vector2i) -> PackedStringArray:
	var rows: PackedStringArray = []
	for building: ProceduralBuilding in _map(world).generator().plan_cell(cell).buildings:
		for piece: Dictionary in building.pieces(FLOORS):
			var tile: Vector2i = piece[MapBuildingPlan.KEY_TILE]
			rows.append("%s|%d|%d|%d" % [str(piece[MapBuildingPlan.KEY_DEFINITION_ID]), tile.x, tile.y, int(piece[MapBuildingPlan.KEY_ROTATION])])
	rows.sort()
	return rows


## Structure pieces and containers the generator plans for the loaded cells.
func _planned_totals(world: ServerWorld) -> Vector2i:
	var totals: Vector2i = Vector2i.ZERO
	for cell_id: String in _cells(world).loaded_cell_ids():
		var plan: ProceduralCellPlan = _map(world).generator().plan_cell(WorldCellGrid.parse_id(cell_id) as Vector2i)
		totals += Vector2i(plan.piece_count(FLOORS), plan.container_count())
	return totals


## A cell of the town with at least `min_buildings` buildings, `distance`
## cells east of the crossing or farther.
func _built_cell(world: ServerWorld, crossing: Vector2i, min_buildings: int = 2) -> Vector2i:
	for x: int in range(crossing.x, crossing.x + 6):
		for z: int in range(crossing.y - 3, crossing.y + 3):
			if _map(world).generator().plan_cell(Vector2i(x, z)).buildings.size() >= min_buildings:
				return Vector2i(x, z)
	fail("test setup: no built cell near the town crossing")
	return crossing


# ------------------------------------------------------------ lazy placement

func test_a_new_world_places_nothing_until_a_cell_is_loaded() -> void:
	var world: ServerWorld = _world()
	var map: ProceduralMapService = _map(world)
	assert_true(map.is_enabled())
	assert_eq(map.world_seed(), SEED, "the world took the configured seed")
	assert_eq(_building(world).structure_count(), 0, "nothing is generated when the world is created")
	assert_eq(_cells(world).load_count, 0, "and no cell was brought into memory")
	assert_eq(map.cells_completed, 0)
	for _tick: int in range(5):
		world.step_systems(TICK)
	assert_eq(_building(world).structure_count(), 0, "nor while nobody is in the world")


func test_the_cells_around_a_player_get_their_buildings_once() -> void:
	var world: ServerWorld = _world()
	var map: ProceduralMapService = _map(world)
	var player_id: String = world.join("alice").player_id
	var crossing: Vector2i = _town_crossing(world)
	_move(world, player_id, _corner_position(crossing))
	assert_true(map.cells_finished_at_once >= 4, "the cells next to the player are finished at once: %d" % map.cells_finished_at_once)
	for cell: Vector2i in world.cell_grid.cells_within(crossing, ProceduralMapService.FINISH_NOW_RADIUS_CELLS):
		assert_true(map.is_cell_complete(WorldCellGrid.id_of(cell)))
	assert_true(map.pending_cell_count() > 0, "the cells farther away wait for their turn")
	var before: int = _building(world).structure_count()
	world.step_systems(TICK)
	var per_tick: int = _building(world).structure_count() - before
	assert_true(per_tick > 0, "every tick builds some of them")
	assert_eq(per_tick, MAX_PIECES_PER_TICK, "exactly the budget of pieces")
	_drain(world)
	var planned: Vector2i = _planned_totals(world)
	assert_true(planned.x > 1000, "a town centre holds many pieces: %d" % planned.x)
	assert_eq(_building(world).structure_count(), planned.x, "every planned piece stands")
	assert_eq(_containers(world).container_count(), planned.y, "and every planned container")
	assert_eq(map.skipped_structures + map.refused_structures + map.skipped_containers, 0, "nothing was left out")
	assert_eq(map.structures_placed, planned.x)
	# Every piece is a completed structure in the cell it was planned for.
	var cell: Vector2i = _built_cell(world, crossing)
	assert_eq(_pieces_in_cell(world, WorldCellGrid.id_of(cell)), _planned_pieces(world, cell))
	for structure_id: String in world.cell_index.entities_in_cell(WorldCellGrid.id_of(cell), KIND_STRUCTURE):
		assert_false(_building(world).get_structure(structure_id).is_under_construction(), "generated pieces stand completed")
	# More ticks and more looks change nothing.
	for _tick: int in range(10):
		world.step_systems(TICK)
	assert_eq(_building(world).structure_count(), planned.x, "nothing is placed twice")


func test_a_generated_house_keeps_people_out_except_through_its_door() -> void:
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	var crossing: Vector2i = _town_crossing(world)
	_move(world, player_id, _corner_position(crossing))
	_drain(world)
	var building: ProceduralBuilding = _map(world).generator().plan_cell(_built_cell(world, crossing)).buildings[0]
	var footprint: Rect2i = building.footprint()
	var grid: StructureGrid = _building(world).grid
	var inside: Vector3 = grid.tile_center(footprint.position)
	var outside: Vector3 = grid.tile_center(footprint.position - Vector2i(1, 0))
	assert_true(world.is_line_blocked(outside, inside), "a wall stands between the yard and the corner room")
	assert_ne(world.resolve_movement("player", outside, inside), inside, "and stops a walker")


func test_a_cell_that_is_released_and_loaded_again_is_not_built_twice() -> void:
	var world: ServerWorld = _world()
	var map: ProceduralMapService = _map(world)
	var player_id: String = world.join("alice").player_id
	var crossing: Vector2i = _town_crossing(world)
	var cell: Vector2i = _built_cell(world, crossing)
	var cell_id: String = WorldCellGrid.id_of(cell)
	_move(world, player_id, _corner_position(crossing))
	_drain(world)
	var first: PackedStringArray = _pieces_in_cell(world, cell_id)
	var containers_before: int = world.cell_index.count_in_cell(cell_id, KIND_CONTAINER)
	assert_true(first.size() > 50 and containers_before > 0, "the cell has buildings and containers")
	# A player demolishes... the server removes one wall: it must stay gone.
	var removed_id: String = ""
	for structure_id: String in world.cell_index.entities_in_cell(cell_id, KIND_STRUCTURE):
		if _building(world).get_structure(structure_id).definition_id == "dev_wall":
			removed_id = structure_id
			break
	assert_true(_building(world).remove_structure(world, removed_id).ok)
	var placed_before: int = map.structures_placed
	# Far away (the reserved starting town): every town cell is released.
	_move(world, player_id, Vector3(0.5, 0.0, 0.5))
	world.step_systems(TICK)
	_cells(world).refresh(world)
	assert_false(world.is_cell_loaded(cell_id), "the cell left memory")
	assert_eq(world.cell_index.count_in_cell(cell_id, KIND_STRUCTURE), 0)
	_move(world, player_id, _corner_position(crossing))
	_drain(world)
	assert_true(world.is_cell_loaded(cell_id))
	assert_eq(_pieces_in_cell(world, cell_id).size(), first.size() - 1, "the same pieces came back, without the removed wall")
	assert_eq(world.cell_index.count_in_cell(cell_id, KIND_CONTAINER), containers_before, "and the same containers")
	assert_eq(map.structures_placed, placed_before, "nothing was generated again")
	assert_eq(map.skipped_structures, 0, "nothing was even tried")


func test_a_cell_released_half_built_goes_on_where_it_stopped() -> void:
	var config: CompositionConfig = _config()
	config.procedural_map.max_pieces_per_tick = HALF_BUILT_BUDGET
	var world: ServerWorld = _world(config)
	var map: ProceduralMapService = _map(world)
	var crossing: Vector2i = _town_crossing(world)
	var cell: Vector2i = _built_cell(world, crossing, 3)
	var cell_id: String = WorldCellGrid.id_of(cell)
	var plan: ProceduralCellPlan = map.generator().plan_cell(cell)
	# Nobody is near: the cell is loaded by a server rule and built by ticks.
	assert_true(_cells(world).load_cell_now(world, cell_id))
	assert_eq(map.pending_cell_count(), 1)
	assert_eq(world.cell_index.count_in_cell(cell_id, KIND_STRUCTURE), 0, "loading alone builds nothing")
	# Tick by tick until the second building is half-built.
	var first_pieces: int = plan.buildings[0].pieces(FLOORS).size()
	@warning_ignore("integer_division")
	var ticks: int = first_pieces / HALF_BUILT_BUDGET + 2
	for _tick: int in range(ticks):
		world.step_systems(TICK)
	assert_eq(map.buildings_placed, 1, "the first building stands")
	assert_eq(world.cell_index.count_in_cell(cell_id, KIND_STRUCTURE), ticks * HALF_BUILT_BUDGET, "every tick placed its budget of pieces")
	assert_eq(world.cell_index.count_in_cell(cell_id, KIND_CONTAINER), plan.buildings[0].definition.containers.size(), "with its containers, and none of the next building yet")
	assert_false(map.is_cell_complete(cell_id))
	var document: Dictionary = map.to_cell_document(cell_id)
	assert_eq(int(document[ProceduralMapService.KEY_BUILDINGS_DONE]), 1)
	assert_eq(int(document[ProceduralMapService.KEY_PIECES_DONE]), ticks * HALF_BUILT_BUDGET - first_pieces, "the record knows the piece it stopped at")
	assert_false(bool(document[ProceduralMapService.KEY_COMPLETE]))
	assert_eq(_cells(world).release_cells_now(world, PackedStringArray([cell_id])), OK)
	assert_false(world.is_cell_loaded(cell_id), "released half-built")
	assert_eq(map.pending_cell_count(), 0, "a cell that left memory is not built")
	world.step_systems(TICK)
	assert_eq(map.buildings_placed, 1)
	assert_true(_cells(world).load_cell_now(world, cell_id))
	assert_eq(map.pending_cell_count(), 1, "it is queued again")
	_drain(world)
	assert_eq(map.buildings_placed, plan.buildings.size(), "every building was placed exactly once")
	assert_eq(_pieces_in_cell(world, cell_id), _planned_pieces(world, cell))
	assert_eq(world.cell_index.count_in_cell(cell_id, KIND_CONTAINER), plan.container_count())
	assert_eq(map.skipped_structures + map.skipped_containers, 0, "no piece was tried twice")
	assert_true(bool(map.to_cell_document(cell_id)[ProceduralMapService.KEY_COMPLETE]))


func test_cells_that_get_nothing_leave_no_trace() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(null, store)
	var map: ProceduralMapService = _map(world)
	var player_id: String = world.join("alice").player_id
	# The middle of the starting town: reserved cells all around.
	_move(world, player_id, Vector3(0.5, 0.0, 0.5))
	for _tick: int in range(5):
		world.step_systems(TICK)
	assert_true(_cells(world).load_count > 0, "cells were loaded")
	assert_eq(map.pending_cell_count(), 0)
	assert_eq(map.cells_completed, 0)
	assert_eq(_building(world).structure_count(), 0, "nothing is generated in the starting town")
	for cell_id: String in _cells(world).loaded_cell_ids():
		assert_true(map.to_cell_document(cell_id).is_empty(), "no record for a cell that gets nothing")
	world.leave(player_id)
	world.step_systems(TICK)
	_cells(world).refresh(world)
	assert_eq(store.saved_cell_ids().size(), 0, "and nothing to save for them")


func test_a_cell_that_is_being_saved_is_not_built_on() -> void:
	var world: ServerWorld = _world()
	var map: ProceduralMapService = _map(world)
	var cell: Vector2i = _built_cell(world, _town_crossing(world))
	var cell_id: String = WorldCellGrid.id_of(cell)
	assert_true(_cells(world).load_cell_now(world, cell_id))
	world.step_systems(TICK)
	var placed: int = map.structures_placed
	assert_true(placed > 0 and map.pending_cell_count() == 1, "the cell is half-built")
	# The state a cell has while a background save of it is running.
	_cells(world).set("_states", {cell_id: WorldCellLifecycle.State.SAVING} as Dictionary[String, int])
	for _tick: int in range(5):
		map.step(world, TICK, TICK)
	map.finish_pending(world)
	assert_eq(map.structures_placed, placed, "nothing is placed in a cell whose document was already cut")
	assert_eq(map.pending_cell_count(), 1, "it waits")
	_cells(world).set("_states", {cell_id: WorldCellLifecycle.State.PRELOADED} as Dictionary[String, int])
	map.finish_pending(world)
	assert_eq(_pieces_in_cell(world, cell_id), _planned_pieces(world, cell), "and is finished when the save is done")


# ------------------------------------------------------------ determinism

func test_two_worlds_with_the_same_seed_get_the_same_buildings() -> void:
	var first: ServerWorld = _world(_config(SEED))
	var crossing: Vector2i = _town_crossing(first)
	var cell: Vector2i = _built_cell(first, crossing)
	var cell_id: String = WorldCellGrid.id_of(cell)
	# The first world is walked into, the second loads the cell by itself
	# (another order, another moment).
	_move(first, first.join("alice").player_id, _corner_position(crossing))
	_drain(first)
	var second: ServerWorld = _world(_config(SEED))
	assert_true(_cells(second).load_cell_now(second, cell_id))
	_drain(second)
	assert_eq(_pieces_in_cell(second, cell_id), _pieces_in_cell(first, cell_id), "the same pieces on the same tiles")
	assert_true(_pieces_in_cell(first, cell_id).size() > 50)
	var other: ServerWorld = _world(_config(OTHER_SEED))
	assert_eq(_map(other).world_seed(), OTHER_SEED)
	_cells(other).load_cell_now(other, cell_id)
	_drain(other)
	assert_ne(_pieces_in_cell(other, cell_id), _pieces_in_cell(first, cell_id), "another seed, another cell")


func test_a_world_keeps_its_seed() -> void:
	var config: CompositionConfig = _config(0)
	var world: ServerWorld = _world(config)
	var seed_value: int = _map(world).world_seed()
	assert_true(seed_value >= 1 and seed_value <= ProceduralMapSettings.MAX_WORLD_SEED, "seed 0 in the settings = a random seed per world: %d" % seed_value)
	var document: Dictionary = JSON.parse_string(JSON.stringify(_map(world).to_world_document())) as Dictionary
	assert_eq(str(document[ProceduralMapService.KEY_WORLD_SEED]), str(seed_value), "saved as text (exact in JSON)")
	# Restored under settings that name another seed: the world's own wins.
	var restored: ProceduralMapService = ProceduralMapService.new(_config(OTHER_SEED).procedural_map, 1.0)
	assert_eq(restored.restore_world_document(document).size(), 0)
	assert_eq(restored.world_seed(), seed_value)
	assert_eq(restored.restore_world_document({"schema_version": 99}).size(), 1, "an unknown version is refused")
	assert_eq(restored.restore_world_document({"schema_version": 1, "world_seed": "abc"}).size(), 1)
	assert_eq(restored.world_seed(), seed_value, "a refused document changes nothing")
	assert_eq(restored.restore_cell_document(null, "cell_9_9", {"schema_version": 1, "generator_version": 1, "buildings_done": -1, "pieces_done": 0, "complete": true}).size(), 1, "an invalid cell record is refused")


func test_without_settings_nothing_is_generated_or_saved() -> void:
	var config: CompositionConfig = _config()
	config.procedural_map = null
	var world: ServerWorld = _world(config)
	var map: ProceduralMapService = _map(world)
	assert_not_null(map, "the system is always registered")
	assert_false(map.is_enabled())
	assert_null(map.generator())
	_move(world, world.join("alice").player_id, Vector3(850.5, 0.0, -949.5))
	for _tick: int in range(5):
		world.step_systems(TICK)
	assert_eq(_building(world).structure_count(), 0)
	assert_true(map.to_world_document().is_empty(), "a world without a generated map saves nothing about one")


# ------------------------------------------------------------ zombies

func test_generated_cells_get_their_zombies_once_and_within_the_limit() -> void:
	var config: CompositionConfig = _config()
	config.procedural_map.town_zombies_per_cell_max = 2
	config.procedural_map.town_zombie_percent = 100
	config.zombie.max_active_zombies = 20
	# They stand still: the test counts them where they were put.
	config.zombie.wander_speed_mps = 0.0
	config.zombie.sight_range_m = 0.1
	var world: ServerWorld = _world(config)
	var map: ProceduralMapService = _map(world)
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var crossing: Vector2i = _town_crossing(world)
	var cell: Vector2i = _built_cell(world, crossing)
	var cell_id: String = WorldCellGrid.id_of(cell)
	assert_true(_cells(world).load_cell_now(world, cell_id))
	_drain(world)
	assert_eq(world.cell_index.count_in_cell(cell_id, KIND_ZOMBIE), 2, "the cell got its zombies")
	assert_eq(map.zombies_placed, 2)
	for zombie_id: String in world.cell_index.entities_in_cell(cell_id, KIND_ZOMBIE):
		var tile: Vector2i = _building(world).grid.tile_of(zombies.get_zombie(zombie_id).position)
		for building: ProceduralBuilding in map.generator().plan_cell(cell).buildings:
			assert_false(building.footprint().grow(1).has_point(tile), "they stand in the street, not in a house")
	assert_eq(_cells(world).release_cells_now(world, PackedStringArray([cell_id])), OK)
	assert_true(_cells(world).load_cell_now(world, cell_id))
	_drain(world)
	assert_eq(world.cell_index.count_in_cell(cell_id, KIND_ZOMBIE), 2, "the same two came back; no new ones")
	assert_eq(map.zombies_placed, 2)
	# A whole town centre asks for more zombies than the limit has room for.
	_move(world, world.join("alice").player_id, _corner_position(crossing))
	_drain(world)
	assert_eq(zombies.zombie_count(), 20, "never more than max_active_zombies")
	assert_true(map.skipped_zombies > 0, "the others are left out and counted: %d" % map.skipped_zombies)
