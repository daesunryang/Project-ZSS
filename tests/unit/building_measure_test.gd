extends TestCase
## P3-4a: measurements, not guarantees (CLAUDE.md §6). Prints how long it
## takes on this machine to check a movement step with a few thousand
## structures in memory, to step zombies that press against walls, to place
## a few hundred structures, and to save, release and load a cell that holds
## them (memory store and a real world save on disk). The lines start with
## "[measure]"; docs/15 §15.4 records one run. The assertions only check
## that the measured work really happened.

const WORLD: String = "building_measure_world"
const NEVER: float = 1.0e9
const USEC_PER_MSEC: float = 1000.0
const WALL: String = "dev_wall"
const FLOOR: String = "dev_floor"
const DOOR: String = "dev_door"
## Walls in memory for the movement measurements.
const MANY_STRUCTURES: int = 4000
const STEP_CHECKS: int = 20000
const ZOMBIES: int = 64
const ZOMBIE_TICKS: int = 200
const TICK: float = 1.0 / 60.0
## Structures in the cell that is saved, released and loaded.
const CELL_STRUCTURES: int = 300
const ROUNDS: int = 5
## The measured cell: four cells from the player's start.
const BUSY_CELL: String = "cell_4_0"

var _root: String = ""
var _settings: WorldCellSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/building_measure_%d" % Time.get_ticks_usec()
	_settings = WorldCellSettings.new()
	_settings.cell_size_m = 10.0
	_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_settings.bounds_max_m = Vector2(50.0, 50.0)
	_settings.active_radius_cells = 0
	_settings.preload_radius_cells = 1
	_settings.preload_lookahead_sec = 0.0
	_settings.deactivate_delay_sec = 0.0
	_settings.unload_delay_sec = 0.0
	_settings.refresh_period_sec = 0.0


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = Vector3(5.5, 0.0, 5.5)
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.zombie.max_active_zombies = 10000
	config.zombie.wander_pause_min_sec = NEVER
	config.zombie.wander_pause_max_sec = NEVER
	config.building = BuildingSettings.new()
	# Standing walls are what is measured here (P3-4a): the dev switch is on.
	config.building.instant_completion = true
	config.building.max_structures_per_cell = 100000
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = _settings
	return config


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _report(label: String, samples: Array[float]) -> void:
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	print("[measure] %s: median %.2f ms, min %.2f ms, max %.2f ms (%d runs)" % [label, sorted[sorted.size() / 2], sorted[0], sorted[sorted.size() - 1], sorted.size()])


## A world whose every cell is in memory and active (one big cell), so the
## structures of the whole map are loaded at once.
func _one_cell_world() -> ServerWorld:
	var config: CompositionConfig = _config()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 100.0
	config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	config.world_cells.active_radius_cells = 0
	config.world_cells.preload_radius_cells = 1
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	world.seed_new_world(DevWorldSeed.new())
	return world


## `count` walls: every tile of a square block gets a wall on its -Z side
## and on its -X side, so the block is a mesh of closed rooms.
func _build_wall_mesh(world: ServerWorld, count: int, origin: Vector2i) -> int:
	var service: BuildingService = _building(world)
	var side: int = ceili(sqrt(float(count) / 2.0))
	var placed: int = 0
	for x: int in range(side):
		for z: int in range(side):
			for rotation: int in [0, 3]:
				if placed < count and service.place_structure(world, WALL, origin + Vector2i(x, z), rotation).ok:
					placed += 1
	return placed


## Average time of one ServerWorld.resolve_movement() call, microseconds.
func _time_steps(world: ServerWorld, kind: String, steps: Array[Vector3]) -> float:
	var started: int = Time.get_ticks_usec()
	for index: int in range(0, steps.size(), 2):
		world.resolve_movement(kind, steps[index], steps[index + 1])
	return float(Time.get_ticks_usec() - started) / float(steps.size() / 2)


func test_measure_a_movement_step_check_with_thousands_of_structures() -> void:
	var world: ServerWorld = _one_cell_world()
	var alice: PlayerState = world.join("alice")
	alice.position = Vector3(-45.5, 0.0, -45.5)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 4
	# The steps of the measurement: a walking player's tick (6.7 cm) from
	# random places inside the wall mesh, in random directions; a zombie's
	# tick (5.3 cm); and one 20 m step.
	var player_steps: Array[Vector3] = []
	var zombie_steps: Array[Vector3] = []
	var long_steps: Array[Vector3] = []
	for index: int in range(STEP_CHECKS):
		var from: Vector3 = Vector3(rng.randf_range(0.0, 44.0), 0.0, rng.randf_range(0.0, 44.0))
		var direction: Vector3 = Vector3.RIGHT.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
		player_steps.append_array([from, from + direction * world.gameplay.move_speed_mps * TICK])
		zombie_steps.append_array([from, from + direction * 3.2 * TICK])
		long_steps.append_array([from, from + direction * 20.0])
	var empty_player: float = _time_steps(world, ServerWorld.ENTITY_KIND_PLAYER, player_steps)
	var empty_long: float = _time_steps(world, ServerWorld.ENTITY_KIND_PLAYER, long_steps)
	var placed: int = _build_wall_mesh(world, MANY_STRUCTURES, Vector2i(0, 0))
	assert_eq(placed, MANY_STRUCTURES)
	assert_eq(_building(world).blocking_edge_count(), MANY_STRUCTURES)
	var full_player: float = _time_steps(world, ServerWorld.ENTITY_KIND_PLAYER, player_steps)
	var full_zombie: float = _time_steps(world, ZombieService.ENTITY_KIND_ZOMBIE, zombie_steps)
	var full_long: float = _time_steps(world, ServerWorld.ENTITY_KIND_PLAYER, long_steps)
	var blocked: int = 0
	for index: int in range(0, player_steps.size(), 2):
		if world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, player_steps[index], player_steps[index + 1]) != player_steps[index + 1]:
			blocked += 1
	print("[measure] movement step check, no structures: %.2f us per player step, %.2f us per 20 m step (%d checks each)" % [empty_player, empty_long, STEP_CHECKS])
	print("[measure] movement step check, %d walls in memory: %.2f us per player step (%d of %d stopped by a wall), %.2f us per zombie step, %.2f us per 20 m step" % [MANY_STRUCTURES, full_player, blocked, STEP_CHECKS, full_zombie, full_long])
	assert_true(blocked > 0, "some steps did hit a wall")


func test_measure_zombies_pressing_against_walls() -> void:
	var samples: Dictionary[String, float] = {}
	for with_walls: bool in [false, true]:
		var world: ServerWorld = _one_cell_world()
		var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
		var alice: PlayerState = world.join("alice")
		alice.position = Vector3(22.5, 0.0, 44.5)
		if with_walls:
			assert_eq(_build_wall_mesh(world, MANY_STRUCTURES, Vector2i(0, 0)), MANY_STRUCTURES)
		# Zombies in the rooms of the mesh, all looking at the player: they
		# chase and (with walls) press against the wall of their room.
		for index: int in range(ZOMBIES):
			var position: Vector3 = Vector3(float(index % 8) * 5.0 + 2.5, 0.0, float(index / 8) * 4.0 + 2.5)
			assert_true(zombies.spawn_zombie(world, position, ZombiePerception.yaw_towards(alice.position - position, 0.0)).ok)
		for tick: int in range(60):
			world.step_systems(TICK)
		var started: int = Time.get_ticks_usec()
		for tick: int in range(ZOMBIE_TICKS):
			world.step_systems(TICK)
		samples["walls" if with_walls else "open"] = float(Time.get_ticks_usec() - started) / USEC_PER_MSEC / float(ZOMBIE_TICKS)
		if with_walls:
			assert_true(zombies.obstructed_move_count > ZOMBIES, "the zombies did press against walls: %d" % zombies.obstructed_move_count)
			print("[measure] %d obstructed zombie steps in %d ticks" % [zombies.obstructed_move_count, ZOMBIE_TICKS + 60])
	print("[measure] one server tick of all systems with %d chasing zombies: %.3f ms without structures, %.3f ms with %d walls (zombies pressing against them)" % [ZOMBIES, samples["open"], samples["walls"], MANY_STRUCTURES])


## `count` structures spread over one 10 m cell: floors, walls, doors.
func _fill_cell(world: ServerWorld, cell: Vector2i, count: int) -> float:
	var service: BuildingService = _building(world)
	var origin: Vector2i = Vector2i(cell.x * 10, cell.y * 10)
	var requests: Array[Array] = []
	for x: int in range(10):
		for z: int in range(10):
			requests.append([FLOOR, origin + Vector2i(x, z), 0])
			requests.append([WALL, origin + Vector2i(x, z), 0])
			requests.append([DOOR if (x + z) % 4 == 0 else WALL, origin + Vector2i(x, z), 3])
	var started: int = Time.get_ticks_usec()
	for index: int in range(count):
		var request: Array = requests[index]
		if not service.place_structure(world, str(request[0]), request[1] as Vector2i, int(request[2])).ok:
			fail("test setup: placement %d was refused" % index)
	return float(Time.get_ticks_usec() - started) / USEC_PER_MSEC


## Puts the player somewhere and looks once; returns how long the look took.
func _timed_look(world: ServerWorld, player_id: String, position: Vector3) -> float:
	world.get_player(player_id).position = position
	var started: int = Time.get_ticks_usec()
	_cells(world).refresh(world)
	return float(Time.get_ticks_usec() - started) / USEC_PER_MSEC


## Fills the busy cell, then releases and loads it ROUNDS times.
func _measure_cycle(world: ServerWorld, player_id: String, label: String) -> void:
	var cells: WorldCellService = _cells(world)
	_settings.unload_delay_sec = NEVER
	_timed_look(world, player_id, Vector3(45.5, 0.0, 5.5))
	var placing_ms: float = _fill_cell(world, Vector2i(4, 0), CELL_STRUCTURES)
	print("[measure] %s: place %d structures in one cell: %.2f ms (%.1f us each)" % [label, CELL_STRUCTURES, placing_ms, placing_ms * USEC_PER_MSEC / float(CELL_STRUCTURES)])
	assert_eq(world.cell_index.count_in_cell(BUSY_CELL, BuildingService.ENTITY_KIND_STRUCTURE), CELL_STRUCTURES)
	var releasing: Array[float] = []
	var loading: Array[float] = []
	for round_index: int in range(ROUNDS):
		# Far away: the busy cell is saved and released in this look.
		_settings.unload_delay_sec = 0.0
		releasing.append(_timed_look(world, player_id, Vector3(5.5, 0.0, 5.5)))
		assert_eq(cells.state_of(BUSY_CELL), WorldCellLifecycle.State.UNLOADED)
		assert_eq(_building(world).structure_count(), 0)
		_settings.unload_delay_sec = NEVER
		loading.append(_timed_look(world, player_id, Vector3(35.5, 0.0, 5.5)))
		assert_eq(cells.state_of(BUSY_CELL), WorldCellLifecycle.State.PRELOADED)
		assert_eq(_building(world).structure_count(), CELL_STRUCTURES)
	_report("%s: release a cell with %d structures (save, then free)" % [label, CELL_STRUCTURES], releasing)
	_report("%s: load that cell" % label, loading)


func test_measure_placing_saving_and_loading_a_cell_with_a_memory_store() -> void:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	world.seed_new_world(DevWorldSeed.new())
	_cells(world).set_store(WorldCellStore.new())
	var player_id: String = world.join("alice").player_id
	_measure_cycle(world, player_id, "memory store")
	assert_true(_cells(world).unload_count >= ROUNDS)
	# What a joining client is sent for that cell.
	var module: StructureNetModule = StructureNetModule.new(StructureNetSettings.new(), StructureCatalog.load_directory())
	var rows: Array = []
	for row: Dictionary in _building(world).rows():
		rows.append(ClientStructureState.encode_row(row))
	var fragment: Dictionary = {ClientStructureState.KEY_SCHEMA_VERSION: ClientStructureState.SCHEMA_VERSION, ClientStructureState.KEY_STRUCTURES: rows, ClientStructureState.KEY_WORKERS: []}
	var started: int = Time.get_ticks_usec()
	assert_true(module.client_state.apply_join(fragment))
	var apply_ms: float = float(Time.get_ticks_usec() - started) / USEC_PER_MSEC
	print("[measure] join fragment with %d structures: %d bytes encoded, %.2f ms to validate and apply on a client" % [rows.size(), var_to_bytes(fragment).size(), apply_ms])
	assert_eq(module.client_state.structure_count(), CELL_STRUCTURES)
	module.free()


func test_measure_placing_saving_and_loading_a_cell_with_a_world_save_on_disk() -> void:
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config())
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	var player_id: String = world.join("alice").player_id
	_measure_cycle(world, player_id, "world save on disk")
	assert_true(SaveService.new(_root).current_generation(WORLD) > ROUNDS, "every release wrote a save generation")
	var samples: Array[float] = []
	for round_index: int in range(ROUNDS):
		# A structure changes, then the whole world is saved (what an accepted
		# placement does).
		assert_true(_building(world).place_structure(world, FLOOR, Vector2i(30 + round_index, 9), 0).ok)
		var started: int = Time.get_ticks_usec()
		assert_eq(persistence.save(world), OK)
		samples.append(float(Time.get_ticks_usec() - started) / USEC_PER_MSEC)
	_report("world save on disk: the save after one placement (%d structures in memory)" % _building(world).structure_count(), samples)
