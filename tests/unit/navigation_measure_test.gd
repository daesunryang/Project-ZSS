extends TestCase
## P3-6 measurements, not performance guarantees. Output is copied to
## docs/15 section 15.6 after a run on the development machine.

const RUNS: int = 25
const TICK: float = 1.0 / 60.0
const WALL: String = "dev_wall"
const BEFORE_OPEN_MEDIAN_MS: float = 3.468
const BEFORE_WALL_MEDIAN_MS: float = 46.984
const BEFORE_TICK_MS: float = 414.984

var _grid: StructureGrid = StructureGrid.new(1.0)
var _blocked: Dictionary[int, bool] = {}


func _is_blocked(slot: Vector3i) -> bool:
	return _blocked.has(StructureGrid.slot_key(slot))


func _median(samples: Array[float]) -> float:
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _maximum(samples: Array[float]) -> float:
	var maximum: float = 0.0
	for sample: float in samples:
		maximum = maxf(maximum, sample)
	return maximum


func _measure_search(from: Vector3, to: Vector3) -> Array[float]:
	var finder: GridPathFinder = GridPathFinder.new(_grid)
	var samples: Array[float] = []
	for run: int in range(RUNS):
		var started: int = Time.get_ticks_usec()
		var result: GridPathResult = finder.find_path(from, to, Callable(self, "_is_blocked"), 10000, 100.0, 0.0)
		samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
		assert_true(result.found)
	return samples


func test_measure_open_area_and_long_wall_searches() -> void:
	_blocked.clear()
	var open_samples: Array[float] = _measure_search(Vector3(0.5, 0.0, 0.5), Vector3(59.5, 0.0, 59.5))
	for z: int in range(40):
		_blocked[StructureGrid.slot_key(Vector3i(20, z, StructureGrid.Layer.EDGE_LOW_X))] = true
	var wall_samples: Array[float] = _measure_search(Vector3(-5.5, 0.0, 20.5), Vector3(45.5, 0.0, 20.5))
	var open_median: float = _median(open_samples)
	var wall_median: float = _median(wall_samples)
	print("[measure] P3-6d one-slice search: open 60x60 %.3f -> %.3f ms median; around 40 m wall %.3f -> %.3f ms median, %.3f ms worst (%d runs each)" % [BEFORE_OPEN_MEDIAN_MS, open_median, BEFORE_WALL_MEDIAN_MS, wall_median, _maximum(wall_samples), RUNS])
	assert_true(open_median < 10.0, "generous regression bound: %.3f ms" % open_median)
	assert_true(wall_median < 25.0, "generous regression bound: %.3f ms" % wall_median)


func test_measure_optional_search_time_safety_valve() -> void:
	if OS.get_environment("ZSS_RUN_WALL_CLOCK_NAV_MEASURE") != "1":
		assert_true(true, "set ZSS_RUN_WALL_CLOCK_NAV_MEASURE=1 for the scheduling-sensitive measurement")
		return
	_blocked.clear()
	for z: int in range(-100, 101):
		_blocked[StructureGrid.slot_key(Vector3i(20, z, StructureGrid.Layer.EDGE_LOW_X))] = true
	var finder: GridPathFinder = GridPathFinder.new(_grid)
	var samples: Array[float] = []
	for run: int in range(RUNS):
		var started: int = Time.get_ticks_usec()
		var result: GridPathResult = finder.find_path(Vector3(0.5, 0.0, 0.5), Vector3(40.5, 0.0, 0.5), Callable(self, "_is_blocked"), 2048, 100.0, 4.0)
		samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
		assert_false(result.found)
		assert_true(result.bound_hit)
	print("[measure] P3-6d optional 4 ms search safety valve: %.3f ms median, %.3f ms worst (%d runs)" % [_median(samples), _maximum(samples), RUNS])
	assert_true(_maximum(samples) < 20.0, "generous time-budget regression bound")


func test_measure_tick_with_one_hundred_chasers_at_a_wall() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 100.0
	config.gameplay.player_spawn_position = Vector3(10.5, 0.0, 5.5)
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.zombie.max_active_zombies = 100
	config.zombie.ai_period_sec = 1000.0
	config.navigation = NavigationSettings.new()
	config.building = BuildingSettings.new()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 200.0
	config.world_cells.bounds_min_m = Vector2(-100.0, -100.0)
	config.world_cells.bounds_max_m = Vector2(100.0, 100.0)
	config.world_cells.active_radius_cells = 0
	config.world_cells.preload_radius_cells = 1
	var world: ServerWorld = ServerComposition.create_world("navigation_measure", config)
	world.seed_new_world(DevWorldSeed.new())
	var player: PlayerState = world.join("alice")
	player.position = Vector3(10.5, 0.0, 5.5)
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	for z: int in range(-20, 31):
		# P3-5: a placed piece is a blueprint; complete it so the wall stands.
		var placed: ActionResult = building.place_structure(world, WALL, Vector2i(6, z), 3)
		assert_true(placed.ok)
		assert_true(building.complete_structure(world, str(placed.event[BuildingService.KEY_STRUCTURE_ID])).ok)
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	for index: int in range(100):
		var position: Vector3 = Vector3(2.5 + float(index % 5) * 0.05, 0.0, 3.0 + float(index / 5) * 0.25)
		var result: ActionResult = zombies.spawn_zombie(world, position, ZombiePerception.yaw_towards(player.position - position, 0.0))
		assert_true(result.ok)
		var zombie: ZombieState = zombies.get_zombie(str(result.event["zombie_id"]))
		zombie.state = ZombieState.State.CHASE
		zombie.target_player_id = player.player_id
		zombie.target_visible = true
		zombie.focus_position = player.position
	var samples: Array[float] = []
	var planning_samples: Array[float] = []
	var node_samples: Array[float] = []
	var planned_ticks: int = 0
	for tick: int in range(RUNS):
		var started: int = Time.get_ticks_usec()
		world.step_systems(TICK)
		samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
		if zombies.last_plan_count > 0:
			planned_ticks += 1
			planning_samples.append(zombies.last_plan_msec)
			node_samples.append(float(zombies.last_plan_node_count))
	var tick_median: float = _median(samples)
	print("[measure] P3-6d 100-chaser wall tick with default %d-node budget: %.3f ms median, %.3f ms worst; planning %.3f ms median, %.3f ms worst, %.0f nodes median (%d ticks, %d planning ticks, %d searches; pre-P3-6b %.3f ms)" % [config.navigation.max_planning_nodes_per_tick, tick_median, _maximum(samples), _median(planning_samples), _maximum(planning_samples), _median(node_samples), RUNS, planned_ticks, zombies.total_plan_count, BEFORE_TICK_MS])
	assert_true(planned_ticks > 0 and zombies.total_plan_count > 0)
	assert_true(tick_median < 40.0, "generous regression bound: %.3f ms" % tick_median)
