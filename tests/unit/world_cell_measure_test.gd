extends TestCase
## P3-1: measurements, not guarantees (CLAUDE.md §6, docs/03 §8). Prints how
## long it takes on this machine to release, load, activate and deactivate
## one cell with a few hundred entities, with a memory store and with a real
## world save on disk, and how long a full world save takes with many cell
## files. The lines start with "[measure]"; docs/15 §15.1 records one run.
## The assertions only check that the measured work really happened.

const WORLD: String = "cell_measure_world"
const NEVER: float = 1.0e9
const ITEMS: int = 200
const ZOMBIES: int = 100
const ROUNDS: int = 5
## The measured cell: four cells from the player's start.
const BUSY_CELL: String = "cell_4_0"
const USEC_PER_MSEC: float = 1000.0

var _root: String = ""
var _settings: WorldCellSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/cell_measure_%d" % Time.get_ticks_usec()
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
	config.gameplay.player_spawn_position = Vector3(5.0, 0.0, 5.0)
	config.clock = WorldClockSettings.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.zombie.max_active_zombies = 10000
	config.zombie.wander_pause_min_sec = NEVER
	config.zombie.wander_pause_max_sec = NEVER
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = _settings
	return config


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


## `items` world items and `zombies` zombies spread over one cell.
func _fill_cell(world: ServerWorld, cell: Vector2i, items: int, zombies: int) -> void:
	var corner: Vector3 = world.cell_grid.cell_min_corner(cell)
	var cell_id: String = WorldCellGrid.id_of(cell)
	var service: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	for index: int in range(items):
		world.inventory.spawn_world_item("dev_test_item", 1, cell_id, corner + Vector3(0.5 + float(index % 10) * 0.9, 0.0, 0.5 + float(index % 9)))
	for index: int in range(zombies):
		service.spawn_zombie(world, corner + Vector3(0.5 + float(index % 10) * 0.9, 0.0, 0.5 + float(index % 9)), 1.0)


## Puts the player somewhere and looks once; returns how long the look took.
func _timed_look(world: ServerWorld, player_id: String, position: Vector3) -> float:
	world.get_player(player_id).position = position
	var started: int = Time.get_ticks_usec()
	_cells(world).refresh(world)
	return float(Time.get_ticks_usec() - started) / USEC_PER_MSEC


func _report(label: String, samples: Array[float]) -> void:
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	print("[measure] %s: median %.2f ms, min %.2f ms, max %.2f ms (%d runs)" % [label, sorted[sorted.size() / 2], sorted[0], sorted[sorted.size() - 1], sorted.size()])


## Releases, loads, activates and deactivates the busy cell ROUNDS times.
func _measure_cycle(world: ServerWorld, player_id: String, label: String) -> void:
	var cells: WorldCellService = _cells(world)
	var entities: int = ITEMS + ZOMBIES
	var releasing: Array[float] = []
	var loading: Array[float] = []
	var activating: Array[float] = []
	var deactivating: Array[float] = []
	# The first look brings the freshly placed entities under cell control
	# and releases the cell at once (not measured).
	cells.refresh(world)
	for round_index: int in range(ROUNDS):
		assert_eq(cells.state_of(BUSY_CELL), WorldCellLifecycle.State.UNLOADED)
		assert_eq(world.cell_index.count_in_cell(BUSY_CELL), 0)
		# Nothing is released during the next three looks, so each of them
		# does one thing to the busy cell.
		_settings.unload_delay_sec = NEVER
		# Next to it: loaded, not active.
		loading.append(_timed_look(world, player_id, Vector3(35.0, 0.0, 5.0)))
		assert_eq(cells.state_of(BUSY_CELL), WorldCellLifecycle.State.PRELOADED)
		assert_eq(world.cell_index.count_in_cell(BUSY_CELL), entities)
		# In it: active.
		activating.append(_timed_look(world, player_id, Vector3(45.0, 0.0, 5.0)))
		assert_eq(cells.state_of(BUSY_CELL), WorldCellLifecycle.State.ACTIVE)
		deactivating.append(_timed_look(world, player_id, Vector3(35.0, 0.0, 5.0)))
		assert_eq(cells.state_of(BUSY_CELL), WorldCellLifecycle.State.PRELOADED)
		# Far away: the busy cell is saved and released in this look.
		_settings.unload_delay_sec = 0.0
		releasing.append(_timed_look(world, player_id, Vector3(5.0, 0.0, 5.0)))
	_report("%s: release a cell with %d items + %d zombies (save, then free)" % [label, ITEMS, ZOMBIES], releasing)
	_report("%s: load that cell" % label, loading)
	_report("%s: activate that cell" % label, activating)
	_report("%s: deactivate that cell" % label, deactivating)


func test_measure_cell_cycle_with_a_memory_store() -> void:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	world.seed_new_world(DevWorldSeed.new())
	_cells(world).set_store(WorldCellStore.new())
	var player_id: String = world.join("alice").player_id
	_fill_cell(world, Vector2i(4, 0), ITEMS, ZOMBIES)
	_measure_cycle(world, player_id, "memory store")
	assert_eq(_cells(world).unload_count >= ROUNDS, true)


func test_measure_cell_cycle_with_a_world_save_on_disk() -> void:
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config())
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	var player_id: String = world.join("alice").player_id
	_fill_cell(world, Vector2i(4, 0), ITEMS, ZOMBIES)
	_measure_cycle(world, player_id, "world save on disk")
	assert_true(SaveService.new(_root).current_generation(WORLD) > ROUNDS, "every release wrote a save generation")


func test_measure_a_full_save_with_many_cell_files() -> void:
	# The default grid (10 x 10 cells of 50 m): 60 cells with 5 items and 2
	# zombies each, everything in memory, then saved a few times.
	var config: CompositionConfig = _config()
	config.gameplay = GameplaySettings.new()
	config.world_cells = WorldCellSettings.new()
	var save: SaveService = SaveService.new(_root)
	var persistence: WorldPersistence = WorldPersistence.new(save, config)
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	var filled: int = 0
	for x: int in range(world.cell_grid.min_cell.x, world.cell_grid.max_cell.x + 1):
		for z: int in range(world.cell_grid.min_cell.y, world.cell_grid.max_cell.y + 1):
			if filled < 60:
				_fill_cell(world, Vector2i(x, z), 5, 2)
				filled += 1
	var samples: Array[float] = []
	for round_index: int in range(ROUNDS):
		var started: int = Time.get_ticks_usec()
		assert_eq(persistence.save(world), OK)
		samples.append(float(Time.get_ticks_usec() - started) / USEC_PER_MSEC)
	assert_eq(save.saved_cell_ids(WORLD).size(), 60)
	_report("full world save, 60 cells in memory (420 entities, 60 cell files)", samples)
	# The same world with every cell released: a save only touches the world
	# document, but still copies every file into the backups.
	var cells: WorldCellService = _cells(world)
	var player_id: String = world.join("alice").player_id
	world.get_player(player_id).position = Vector3(240.0, 0.0, 240.0)
	# Four minutes of game clock: the cells around the first position are
	# deactivated, then every cell far from the player is saved and released.
	for minute: int in range(4):
		world.step_systems(60.0)
	var in_memory: int = cells.loaded_cell_ids().size()
	samples = []
	for round_index: int in range(ROUNDS):
		var started: int = Time.get_ticks_usec()
		assert_eq(persistence.save(world), OK)
		samples.append(float(Time.get_ticks_usec() - started) / USEC_PER_MSEC)
	_report("full world save, %d cells in memory, 60 cell files on disk" % in_memory, samples)
	assert_true(in_memory < 60)
