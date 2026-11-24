extends TestCase
## F-33 measurements (docs/15 §F-33, notes/f33-vast-map.md): what the
## generated map costs. Planning a cell, building a cell, the server tick
## while a player runs through a town, the save size per explored cell and
## the memory of a town in memory. The numbers are printed; real time only
## warns (docs/12 §1.1, assert_time_bound).

const WORLD: String = "procedural_measure_world"
const NEVER: float = 1.0e9
## The shipped setting: generated buildings get no floor pieces.
const FLOORS: bool = false
const TICK: float = 1.0 / 60.0
const CELL_M: float = 50.0
const USEC_PER_MSEC: float = 1000.0
const RUN_SPEED_MPS: float = 6.0
## The run: from this far west of a town crossing to this far east of it.
const RUN_HALF_LENGTH_M: float = 450.0
## Provisional bounds (docs/15 F33-020..): one tick is 16.7 ms.
const BUILD_CELL_BOUND_MS: float = 16.0
const TICK_MEDIAN_BOUND_MS: float = 2.0
const TICK_BUILD_BOUND_MS: float = 8.0

var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/procedural_measure_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


## The shipped composition, map and generated zombies; zombies do no harm,
## so the runner stays alive whatever it meets.
func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.respawn_delay_sec = NEVER
	config.zombie = (ZombieSettings.load_or_default() as ZombieSettings).duplicate() as ZombieSettings
	config.zombie.bite_chance = 0.0
	config.zombie.bite_damage = 0.0
	config.zombie.scratch_damage = 0.0
	config.dev_seed = DevWorldSeed.new()
	config.map_content = MapContentDefinition.load_or_null()
	config.procedural_map = ProceduralMapSettings.load_or_null()
	return config


func _map(world: ServerWorld) -> ProceduralMapService:
	return world.get_system(ProceduralMapService.SYSTEM_ID) as ProceduralMapService


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


## What the network modules do every tick on a server: without it the
## event queues stay full and every new event pays for dropping an old one.
func _drain_events(world: ServerWorld) -> void:
	(world.get_system(BuildingService.SYSTEM_ID) as BuildingService).drain_events()
	(world.get_system(ContainerService.SYSTEM_ID) as ContainerService).drain_events()
	(world.get_system(ZombieService.SYSTEM_ID) as ZombieService).drain_events()


func _stats(samples: Array[float]) -> String:
	if samples.is_empty():
		return "no samples"
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	@warning_ignore("integer_division")
	var median: float = sorted[sorted.size() / 2]
	@warning_ignore("integer_division")
	var p95: float = sorted[mini(sorted.size() - 1, sorted.size() * 95 / 100)]
	return "median %.3f ms, p95 %.3f ms, max %.3f ms (%d samples)" % [median, p95, sorted[sorted.size() - 1], sorted.size()]


func _sum(samples: Array[float]) -> float:
	var total: float = 0.0
	for sample: float in samples:
		total += sample
	return total


func _median(samples: Array[float]) -> float:
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	@warning_ignore("integer_division")
	return sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0


func _largest_town(generator: ProceduralMapGenerator) -> Dictionary:
	var best: Dictionary = {}
	for town: Dictionary in generator.towns():
		if not bool(town[ProceduralMapGenerator.KEY_TOWN_HOME]) and (best.is_empty() or float(town[ProceduralMapGenerator.KEY_TOWN_RADIUS_M]) > float(best[ProceduralMapGenerator.KEY_TOWN_RADIUS_M])):
			best = town
	return best


func _directory_bytes(path: String) -> int:
	var total: int = 0
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return 0
	for file_name: String in dir.get_files():
		var file: FileAccess = FileAccess.open(path.path_join(file_name), FileAccess.READ)
		if file != null:
			total += file.get_length()
	return total


func test_measure_planning_and_building_cells() -> void:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	_cells(world).set_store(WorldCellStore.new())
	world.seed_new_world(DevWorldSeed.new())
	var map: ProceduralMapService = _map(world)
	var generator: ProceduralMapGenerator = map.generator()
	var started: int = Time.get_ticks_usec()
	var fresh: ProceduralMapGenerator = ProceduralMapGenerator.new(ProceduralMapSettings.load_or_null(), map.world_seed(), CELL_M, Vector2(-2000.0, -2000.0), Vector2(2000.0, 2000.0), 2000.0, 1.0)
	print("[measure] f33 generator setup (towns, roads): %.3f ms, %d towns" % [float(Time.get_ticks_usec() - started) / USEC_PER_MSEC, fresh.towns().size()])
	var town: Dictionary = _largest_town(generator)
	var corner: Vector2i = town[ProceduralMapGenerator.KEY_TOWN_CORNER]
	var reach: int = ceili(float(town[ProceduralMapGenerator.KEY_TOWN_RADIUS_M]) / CELL_M)
	var plan_ms: Array[float] = []
	var build_ms: Array[float] = []
	var pieces_total: int = 0
	var worst_pieces: int = 0
	var memory_before: int = OS.get_static_memory_usage()
	for x: int in range(corner.x - reach, corner.x + reach):
		for z: int in range(corner.y - reach, corner.y + reach):
			var cell: Vector2i = Vector2i(x, z)
			started = Time.get_ticks_usec()
			var plan: ProceduralCellPlan = generator.plan_cell(cell)
			plan_ms.append(float(Time.get_ticks_usec() - started) / USEC_PER_MSEC)
			if plan.buildings.is_empty():
				continue
			started = Time.get_ticks_usec()
			_cells(world).load_cell_now(world, WorldCellGrid.id_of(cell))
			map.finish_pending(world)
			_drain_events(world)
			build_ms.append(float(Time.get_ticks_usec() - started) / USEC_PER_MSEC)
			pieces_total += plan.piece_count(FLOORS)
			worst_pieces = maxi(worst_pieces, plan.piece_count(FLOORS))
	var memory_after: int = OS.get_static_memory_usage()
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	print("[measure] f33 plan one cell (pure): %s" % _stats(plan_ms))
	print("[measure] f33 load + build one town cell at once: %s; %d cells, %d pieces (worst cell %d), %.1f us per piece" % [_stats(build_ms), build_ms.size(), pieces_total, worst_pieces, float(map.placing_usec) / float(maxi(pieces_total, 1))])
	print("[measure] f33 memory of the whole town in memory (%d structures, %d cells): %.1f MB, %.0f bytes per structure" % [building.structure_count(), build_ms.size(), float(memory_after - memory_before) / 1048576.0, float(memory_after - memory_before) / float(maxi(building.structure_count(), 1))])
	assert_eq(building.structure_count(), pieces_total, "every piece of the town stands")
	assert_true(build_ms.size() > 20, "a whole town was built")
	assert_time_bound(_median(build_ms), BUILD_CELL_BOUND_MS, "building a whole town cell at once (median)")


func test_measure_a_run_through_a_town_with_a_world_save_on_disk() -> void:
	var save: SaveService = SaveService.new(_root)
	var persistence: WorldPersistence = WorldPersistence.new(save, _config())
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	if world == null:
		return
	var map: ProceduralMapService = _map(world)
	var cells: WorldCellService = _cells(world)
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var town: Dictionary = _largest_town(map.generator())
	var corner: Vector2i = town[ProceduralMapGenerator.KEY_TOWN_CORNER]
	var player_id: String = world.join("alice").player_id
	var bytes_before: int = _directory_bytes(save.world_dir(WORLD).path_join(SaveService.CELLS_DIR))
	var files_before: int = save.saved_cell_ids(WORLD).size()
	# Along the street through the crossing, west to east, at running speed.
	var from: Vector3 = Vector3(float(corner.x) * CELL_M - RUN_HALF_LENGTH_M, 0.0, float(corner.y) * CELL_M + 0.5)
	var ticks: int = int(2.0 * RUN_HALF_LENGTH_M / (RUN_SPEED_MPS * TICK))
	var quiet: Array[float] = []
	var building_ticks: Array[float] = []
	var loading_ticks: Array[float] = []
	var saving_ticks: Array[float] = []
	var all_ticks: Array[float] = []
	var peak_structures: int = 0
	var peak_zombies: int = 0
	var peak_cells: int = 0
	world.get_player(player_id).position = from
	cells.refresh(world)
	map.finish_pending(world)
	for tick: int in range(ticks):
		world.get_player(player_id).position = from + Vector3(float(tick) * RUN_SPEED_MPS * TICK, 0.0, 0.0)
		var loads: int = cells.load_count
		var unloads: int = cells.unload_count
		var placed: int = map.structures_placed
		var generation: int = save.current_generation(WORLD)
		var started: int = Time.get_ticks_usec()
		world.step_systems(TICK)
		_drain_events(world)
		var elapsed: float = float(Time.get_ticks_usec() - started) / USEC_PER_MSEC
		all_ticks.append(elapsed)
		if save.current_generation(WORLD) != generation or cells.unload_count != unloads:
			saving_ticks.append(elapsed)
		elif cells.load_count != loads:
			loading_ticks.append(elapsed)
		elif map.structures_placed != placed:
			building_ticks.append(elapsed)
		else:
			quiet.append(elapsed)
		peak_structures = maxi(peak_structures, building.structure_count())
		peak_zombies = maxi(peak_zombies, zombies.zombie_count())
		peak_cells = maxi(peak_cells, cells.loaded_cell_ids().size())
	print("[measure] f33 run through a town (%d m at %.0f m/s, %d ticks of 1/60 s): all ticks %s" % [int(2.0 * RUN_HALF_LENGTH_M), RUN_SPEED_MPS, ticks, _stats(all_ticks)])
	print("[measure] f33 run: ticks with nothing special: %s" % _stats(quiet))
	print("[measure] f33 run: ticks that built generated pieces: %s" % _stats(building_ticks))
	print("[measure] f33 run: ticks that loaded cells: %s" % _stats(loading_ticks))
	print("[measure] f33 run: ticks that saved and released cells (file write on this thread here; on a worker on a server): %s" % _stats(saving_ticks))
	print("[measure] f33 run: peak in memory: %d cells, %d structures, %d zombies; built %d cells / %d buildings / %d structures; at once %d cells; longest build step %.3f ms; skipped %d pieces, %d zombies" % [peak_cells, peak_structures, peak_zombies, map.cells_completed, map.buildings_placed, map.structures_placed, map.cells_finished_at_once, float(map.max_step_usec) / USEC_PER_MSEC, map.skipped_structures + map.refused_structures, map.skipped_zombies])
	# What a save request costs the main thread with the town in memory.
	var started_build: int = Time.get_ticks_usec()
	var documents: Dictionary = world.to_documents()
	var build_ms: float = float(Time.get_ticks_usec() - started_build) / USEC_PER_MSEC
	print("[measure] f33 run: world documents of a save with %d cells in memory: %.3f ms (cells built %d, reused %d, %d documents)" % [cells.loaded_cell_ids().size(), build_ms, cells.last_save_cells_built, cells.last_save_cells_reused, documents.size()])
	assert_eq(persistence.save(world), OK)
	var explored: int = save.saved_cell_ids(WORLD).size() - files_before
	var bytes: int = _directory_bytes(save.world_dir(WORLD).path_join(SaveService.CELLS_DIR)) - bytes_before
	print("[measure] f33 save: %d cell files for the run, %.1f KB in all, %.1f KB per explored cell with content, %.0f bytes per generated structure" % [explored, float(bytes) / 1024.0, float(bytes) / 1024.0 / float(maxi(explored, 1)), float(bytes) / float(maxi(map.structures_placed, 1))])
	# A restarted server reads the explored cells back from their files.
	var restarted: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config()).load_or_create(WORLD)
	assert_not_null(restarted)
	var reload_ms: Array[float] = []
	var reloaded_structures: int = 0
	for cell_id: String in save.saved_cell_ids(WORLD):
		var started_load: int = Time.get_ticks_usec()
		_cells(restarted).load_cell_now(restarted, cell_id)
		var count: int = restarted.cell_index.count_in_cell(cell_id, BuildingService.ENTITY_KIND_STRUCTURE)
		if count > 0 and _map(restarted).is_cell_complete(cell_id):
			reload_ms.append(float(Time.get_ticks_usec() - started_load) / USEC_PER_MSEC)
			reloaded_structures += count
	print("[measure] f33 load one explored cell from its file (read, parse, restore): %s; %.1f us per structure" % [_stats(reload_ms), _sum(reload_ms) * USEC_PER_MSEC / float(maxi(reloaded_structures, 1))])
	assert_eq(_map(restarted).structures_placed, 0, "a restarted server generates nothing again in explored cells")
	assert_true(map.buildings_placed > 50, "the run went through a town: %d buildings" % map.buildings_placed)
	assert_true(explored > 10, "and its cells were saved")
	assert_eq(map.refused_structures, 0)
	assert_time_bound(_median(all_ticks), TICK_MEDIAN_BOUND_MS, "server tick while running through a town (median)")
	assert_time_bound(_median(building_ticks), TICK_BUILD_BOUND_MS, "server tick that builds generated pieces (median)")
