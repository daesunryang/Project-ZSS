extends TestCase
## P3-5: measurements, not guarantees (CLAUDE.md §6). Prints what one
## server tick costs on this machine while players work on structures, what
## a delivery costs, and how many events (= replicated rows) one wall makes
## while it is built. The lines start with "[measure]"; docs/15 §15.5
## records one run. The assertions only check that the measured work really
## happened. Messages over the network: construction_net_test.gd.

const WORLD: String = "construction_measure_world"
const NEVER: float = 1.0e9
const USEC_PER_MSEC: float = 1000.0
const TICK: float = 1.0 / 60.0
const WORKERS: int = 8
const TICKS: int = 2000
const ROUNDS: int = 5
## Deliveries measured: two planks each, from a player that carries twelve
## stacks at the start (a default inventory holds twenty).
const DELIVERIES: int = 60
const ENDLESS_WALL: String = ConstructionTestKit.ENDLESS_WALL
const WALL: String = ConstructionTestKit.WALL
const FLOOR: String = ConstructionTestKit.FLOOR
const PLANK: String = ConstructionTestKit.PLANK
const NAIL: String = ConstructionTestKit.NAIL
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


func _world() -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.catalog = ConstructionTestKit.items()
	config.structures = ConstructionTestKit.structures()
	config.building = BuildingSettings.new()
	config.building.max_workers_per_structure = WORKERS
	# The delivery measurement reaches every floor from one spot.
	config.building.deliver_range_m = 100.0
	# One cell: the whole map is in memory.
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 100.0
	config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	world.seed_new_world(DevWorldSeed.new())
	return world


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


## Average time of one ServerWorld.step_systems() call, milliseconds.
func _time_ticks(world: ServerWorld, ticks: int) -> float:
	var started: int = Time.get_ticks_usec()
	for tick: int in range(ticks):
		world.step_systems(TICK)
	return float(Time.get_ticks_usec() - started) / USEC_PER_MSEC / float(ticks)


func _players(world: ServerWorld, count: int) -> Array[PlayerState]:
	var players: Array[PlayerState] = []
	for index: int in range(count):
		players.append(world.join("worker_%d" % index))
	return players


func test_measure_a_server_tick_with_players_working_on_structures() -> void:
	# One world, the same players and structures in every phase, so the
	# differences are the work and nothing else. Each phase is measured
	# ROUNDS times in turn; the median is reported.
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var players: Array[PlayerState] = _players(world, WORKERS)
	var walls: PackedStringArray = []
	for index: int in range(WORKERS):
		var placed: ActionResult = service.try_place(world, players[index].player_id, ENDLESS_WALL, Vector2i(5 + index % 2, 4 + index / 2), 0)
		assert_true(placed.ok, placed.reason)
		walls.append(str(placed.event["structure_id"]))
	var samples: Dictionary[String, Array] = {"idle": [], "spread": [], "crowd": []}
	_time_ticks(world, 200)
	for round_index: int in range(ROUNDS):
		# Nobody works: the cost of everything else.
		samples["idle"].append(_time_ticks(world, TICKS))
		# Each of the players works on a wall of its own.
		for index: int in range(WORKERS):
			assert_true(service.try_set_work(world, players[index].player_id, walls[index], true).ok)
		samples["spread"].append(_time_ticks(world, TICKS))
		assert_eq(service.worker_count(), WORKERS, "they worked the whole time")
		# All of them work on one wall.
		for index: int in range(1, WORKERS):
			assert_true(service.try_set_work(world, players[index].player_id, walls[0], true).ok)
		samples["crowd"].append(_time_ticks(world, TICKS))
		assert_eq(service.workers_of(walls[0]).size(), WORKERS)
		for player: PlayerState in players:
			service.stop_work(player.player_id, BuildingService.STOP_REQUESTED)
		service.drain_events()
	assert_true(service.get_structure(walls[0]).construction_progress > 0.0)
	var medians: Dictionary[String, float] = {}
	for phase: String in samples:
		var sorted: Array = samples[phase].duplicate()
		sorted.sort()
		medians[phase] = sorted[sorted.size() / 2]
	print("[measure] one server tick of all systems with %d players online: %.4f ms when nobody works, %.4f ms when each works on a structure of its own, %.4f ms when all work on one structure (median of %d runs of %d ticks)" % [WORKERS, medians["idle"], medians["spread"], medians["crowd"], ROUNDS, TICKS])
	print("[measure] so the work of %d players costs %.1f us per tick on %d structures (%.1f us per worker) and %.1f us per tick on one structure" % [WORKERS, (medians["spread"] - medians["idle"]) * USEC_PER_MSEC, WORKERS, (medians["spread"] - medians["idle"]) * USEC_PER_MSEC / float(WORKERS), (medians["crowd"] - medians["idle"]) * USEC_PER_MSEC])


func test_measure_deliveries_and_the_events_of_one_wall() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	# Floors that take two planks each: one delivery each.
	assert_true(ConstructionTestKit.give(world, alice, PLANK, DELIVERIES * 2))
	var floors: PackedStringArray = []
	for index: int in range(DELIVERIES):
		var placed: ActionResult = service.place_structure(world, FLOOR, Vector2i(index % 10, index / 10), 0)
		assert_true(placed.ok, placed.reason)
		floors.append(str(placed.event["structure_id"]))
	service.drain_events()
	var started: int = Time.get_ticks_usec()
	var delivered: int = 0
	for structure_id: String in floors:
		if service.try_deliver(world, alice.player_id, structure_id).ok:
			delivered += 1
	var each_us: float = float(Time.get_ticks_usec() - started) / float(DELIVERIES)
	assert_eq(delivered, DELIVERIES)
	assert_eq(ConstructionTestKit.carried(world, alice, PLANK), 0)
	print("[measure] one delivery (inventory transaction, structure update, event, log line; no save): %.1f us (average of %d, the player carrying up to %d stacks, %d items in the world)" % [each_us, DELIVERIES, DELIVERIES * 2 / ConstructionTestKit.PLANK_STACK, DELIVERIES * 2 / ConstructionTestKit.PLANK_STACK])
	service.drain_events()

	# One wall from blueprint to completed, one worker, 60 ticks per second.
	assert_true(ConstructionTestKit.give(world, alice, PLANK, 4))
	assert_true(ConstructionTestKit.give(world, alice, NAIL, 2))
	var wall_id: String = str(service.try_place(world, alice.player_id, WALL, Vector2i(5, 5), 1).event["structure_id"])
	assert_true(service.try_deliver(world, alice.player_id, wall_id).ok)
	assert_true(service.try_set_work(world, alice.player_id, wall_id, true).ok)
	var ticks: int = 0
	while service.get_structure(wall_id).construction_state != StructureInstance.State.COMPLETED and ticks < 100000:
		world.step_systems(TICK)
		ticks += 1
	var events: Array[Dictionary] = service.drain_events()
	var rows: int = 0
	var work: int = 0
	for event: Dictionary in events:
		if event["event_type"] == BuildingService.EVENT_WORK_STARTED or event["event_type"] == BuildingService.EVENT_WORK_STOPPED:
			work += 1
		else:
			rows += 1
	assert_eq(service.get_structure(wall_id).construction_state, StructureInstance.State.COMPLETED)
	assert_true(rows < ticks / 10, "far fewer rows than ticks")
	print("[measure] one wall (%.0f s of work, progress step %.0f%%) from placement to completion: %d structure events and %d work events in %d server ticks" % [ConstructionTestKit.WALL_WORK_SEC, BuildingSettings.new().progress_event_step * 100.0, rows, work, ticks])
