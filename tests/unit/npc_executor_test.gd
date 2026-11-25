extends TestCase
## P4-5a: the NPC executor (docs/09 §17.7). HOW an NPC carries out what was
## decided: it walks a planned path one resolved step per tick, opens the
## door in its way and closes it behind itself, plans within a FIFO and a
## node budget, holds a spot nobody else can take, tells the decision layer
## when it is done or why it failed, and goes on after a save, a restart and
## a restore as if nothing had happened (docs/13 §16.3 D11). WHAT an NPC
## does is P4-4 / P4-5b: the decider here only writes down what it is told.
## Server rules only, no nodes; ticks are stepped by hand.

const WORLD: String = "npc_executor_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
const WALKER: String = "t45_walker"
const WALL: String = "dev_wall"
const DOOR: String = "dev_door"
const SPEED: float = 2.0
## 10 m cells; the player's cell and two rings around it are simulated,
## three rings are in memory.
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const DONE: String = NpcExecutor.INTERRUPT_DONE
const ARRIVED: String = NpcExecutor.INTERRUPT_ARRIVED
const FAILED: String = NpcExecutor.INTERRUPT_FAILED_PREFIX

const BED_IN: String = "bed_in"
const BED_EAST: String = "bed_east"
const BED_SEALED: String = "bed_sealed"
const WATER_OUT: String = "water_out"
const BENCH: String = "bench"


## Writes down every decision it is asked for: "<tick> <npc> <reasons>".
class Recorder:
	extends NpcDecider
	var log: PackedStringArray = []
	var tick: int = 0
	var _executor: WeakRef = null

	func on_executor_attached(executor: NpcExecutor) -> void:
		_executor = weakref(executor)

	func executor() -> NpcExecutor:
		return _executor.get_ref() as NpcExecutor if _executor != null else null

	func decide(_world: ServerWorld, _npcs: NpcService, npc: NpcState, reasons: PackedStringArray, _from: NpcScheduler) -> void:
		var told: PackedStringArray = []
		for reason: String in reasons:
			if reason != NpcDecider.REASON_PERIOD:
				told.append(reason)
		if not told.is_empty():
			log.append("%d %s %s" % [tick, npc.npc_id, ",".join(told)])

	## What `npc_id` was told, in order, without the ticks.
	func told(npc_id: String) -> PackedStringArray:
		var reasons: PackedStringArray = []
		for line: String in log:
			if line.get_slice(" ", 1) == npc_id:
				reasons.append_array(line.get_slice(" ", 2).split(","))
		return reasons

	## The tick in which `npc_id` was told `reason` first (-1 = never).
	func tick_of(npc_id: String, reason: String) -> int:
		for line: String in log:
			if line.get_slice(" ", 1) == npc_id and line.get_slice(" ", 2).split(",").has(reason):
				return line.get_slice(" ", 0).to_int()
		return -1


## Counts the steps every kind of mover asks the world about, and can stop
## NPCs at an invisible line the path search knows nothing about.
class StepSpy:
	extends ServerSystem
	var calls: Dictionary[String, int] = {}
	## NPCs cannot cross x = this from the low side (INF = no line).
	var npc_line_x: float = INF

	func get_system_id() -> String:
		return "step_spy"

	func constrains_movement() -> bool:
		return true

	func resolve_movement_step(mover_kind: String, from: Vector3, to: Vector3) -> Vector3:
		calls[mover_kind] = int(calls.get(mover_kind, 0)) + 1
		if mover_kind == NpcService.ENTITY_KIND and from.x < npc_line_x and to.x >= npc_line_x:
			return from
		return to


var _cell_settings: WorldCellSettings = null
var _exec: NpcExecutorSettings = null
var _recorder: Recorder = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_cell_settings = WorldCellSettings.new()
	_cell_settings.cell_size_m = 10.0
	_cell_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_cell_settings.bounds_max_m = Vector2(50.0, 50.0)
	_cell_settings.active_radius_cells = 2
	_cell_settings.preload_radius_cells = 3
	_cell_settings.preload_lookahead_sec = 0.0
	_cell_settings.deactivate_delay_sec = 0.0
	_cell_settings.unload_delay_sec = 0.5
	_cell_settings.refresh_period_sec = 0.0
	_cell_settings.max_preload_loads_per_refresh = 1000
	_exec = NpcExecutorSettings.new()
	_exec.walk_speed_mps = SPEED
	_exec.run_speed_mps = 2.0 * SPEED
	# Plans finish in the tick they are asked for, unless a test wants less.
	_exec.max_planning_nodes_per_tick = 100000
	_exec.max_search_nodes_per_tick = 100000
	_exec.max_plans_per_tick = 100
	_exec.max_search_nodes = 2048
	_exec.min_replan_interval_sec = 0.2
	_exec.max_replans_per_action = 3
	_exec.door_pause_sec = 0.2
	_recorder = Recorder.new()


func after_each() -> void:
	GameLogger.set_capture(false)
	_recorder = null


# ------------------------------------------------------------ helpers

func _spot(spot_id: String, kind: String, tile: Vector2i, exclusive: bool = true) -> NpcSpotDefinition:
	var spot: NpcSpotDefinition = NpcSpotDefinition.new()
	spot.spot_id = spot_id
	spot.kind = kind
	spot.tile_offset = tile
	spot.exclusive = exclusive
	return spot


## Outdoor spots (world tiles): a test world has no map content.
func _spots() -> NpcSpotSet:
	var spots: NpcSpotSet = NpcSpotSet.new()
	spots.spot_set_id = "t45_spots"
	spots.spots = [
		_spot(BED_IN, NpcSpotDefinition.KIND_BED, Vector2i(8, 15)),
		_spot(BED_EAST, NpcSpotDefinition.KIND_BED, Vector2i(26, 5)),
		_spot(BED_SEALED, NpcSpotDefinition.KIND_BED, Vector2i(15, -5)),
		_spot(WATER_OUT, NpcSpotDefinition.KIND_WATER, Vector2i(2, 12)),
		_spot(BENCH, NpcSpotDefinition.KIND_WORK, Vector2i(1, 1), false),
	]
	return spots


func _config(recorder: Recorder) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# F-31: no social layer here, so the NPCs take no notice of the players
	# (noticing and talking are tested in the F-31 tests).
	config.npc_social = null
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = _cell_settings
	config.building = BuildingSettings.new()
	config.navigation = NavigationSettings.new()
	config.npc = NpcSettings.new()
	config.npc_definitions = NpcCatalog.new()
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = WALKER
	definition.display_name = "걷는 사람"
	config.npc_definitions.add(definition)
	config.npc_schedule = NpcScheduleSettings.new()
	config.npc_decider = recorder
	config.npc_executor = _exec
	config.npc_spots = _spots()
	return config


func _world(recorder: Recorder = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config(recorder if recorder != null else _recorder))
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	return world


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _navigation(world: ServerWorld) -> NavigationService:
	return world.get_system(NavigationService.SYSTEM_ID) as NavigationService


## Steps the world; the recorder's tick is the number of the step.
func _run(world: ServerWorld, ticks: int, recorder: Recorder = null) -> void:
	var counted: Recorder = recorder if recorder != null else _recorder
	for index: int in range(ticks):
		counted.tick += 1
		world.step_systems(TICK)


func _spawn(world: ServerWorld, position: Vector3) -> String:
	var spawned: ActionResult = _npcs(world).spawn_npc(world, WALKER, position)
	if not spawned.ok:
		fail("test setup: npc refused: " + spawned.reason)
		return ""
	return str(spawned.event.get(NpcService.KEY_NPC_ID, ""))


## A world with a player at SPAWN and NPCs at `positions`.
func _start(positions: Array[Vector3], recorder: Recorder = null) -> Dictionary:
	var world: ServerWorld = _world(recorder)
	var alice: PlayerState = world.join("alice")
	world.step_systems(TICK)
	var ids: PackedStringArray = []
	for position: Vector3 in positions:
		ids.append(_spawn(world, position))
	return {"world": world, "alice": alice, "ids": ids, "executor": (recorder if recorder != null else _recorder).executor()}


func _place(world: ServerWorld, definition: String, tile: Vector2i, rotation: int) -> String:
	var placed: ActionResult = _building(world).place_structure(world, definition, tile, rotation)
	if not placed.ok:
		fail("test setup: %s at %s refused: %s" % [definition, str(tile), placed.reason])
		return ""
	var structure_id: String = str(placed.event[BuildingService.KEY_STRUCTURE_ID])
	var completed: ActionResult = _building(world).complete_structure(world, structure_id)
	assert_true(completed.ok, "test setup: complete %s at %s: %s" % [definition, str(tile), completed.reason])
	return structure_id


## Walls on the line x = `x` for the tiles z_from .. z_to; a door at `door_z`.
## Returns the door's id.
func _barrier(world: ServerWorld, x: int, z_from: int, z_to: int, door_z: int = 1000000) -> String:
	var door_id: String = ""
	for z: int in range(z_from, z_to + 1):
		var structure_id: String = _place(world, DOOR if z == door_z else WALL, Vector2i(x, z), 3)
		if z == door_z:
			door_id = structure_id
	return door_id


## A house: inside are the tiles x 6..10, z 13..17; the door is in its east
## wall (the line x = 11) at z = 15. Returns the door's id.
func _house(world: ServerWorld) -> String:
	_barrier(world, 6, 13, 17)
	var door_id: String = _barrier(world, 11, 13, 17, 15)
	for x: int in range(6, 11):
		_place(world, WALL, Vector2i(x, 13), 0)
		_place(world, WALL, Vector2i(x, 18), 0)
	return door_id


## A box of four walls around one tile: nobody gets in.
func _seal(world: ServerWorld, tile: Vector2i) -> void:
	for rotation: int in range(4):
		_place(world, WALL, tile, rotation)


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


func _state_document(world: ServerWorld, npc_id: String) -> Dictionary:
	return ((_npcs(world).npc_document(npc_id)[NpcState.KEY_COMPONENTS] as Dictionary).get(NpcExecutorState.COMPONENT_ID, {}) as Dictionary)


func _stage_document(world: ServerWorld) -> Dictionary:
	var npc_part: Dictionary = (world.to_documents()["world_state"]["systems"] as Dictionary).get(NpcService.SYSTEM_ID, {})
	return (npc_part.get(NpcService.KEY_STAGES, {}) as Dictionary).get(NpcExecutor.STAGE_ID, {})


func _position(world: ServerWorld, npc_id: String) -> Vector3:
	return _npcs(world).get_npc(npc_id).position


## Steps until `npc_id` is told `reason`, at most `limit` ticks. Returns the
## positions it had after every tick.
func _until_told(world: ServerWorld, npc_id: String, reason: String, limit: int = 2000) -> Array[Vector3]:
	var trail: Array[Vector3] = [_position(world, npc_id)]
	for guard: int in range(limit):
		if _recorder.told(npc_id).has(reason):
			return trail
		_run(world, 1)
		trail.append(_position(world, npc_id))
	fail("%s was never told %s (told: %s)" % [npc_id, reason, ",".join(_recorder.told(npc_id))])
	return trail


# ------------------------------------------------------------ data

func test_the_shipped_settings_are_the_planned_budget_and_bad_settings_are_refused() -> void:
	assert_true(ResourceLoader.exists(NpcExecutorSettings.DEFAULT_PATH))
	var shipped: NpcExecutorSettings = NpcExecutorSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	# docs/13 §16.4 "경로 계획".
	assert_eq(shipped.max_planning_nodes_per_tick, 24)
	assert_eq(shipped.max_search_nodes_per_tick, 8)
	assert_eq(shipped.max_plans_per_tick, 4)
	assert_eq(shipped.max_search_nodes, 2048)
	assert_eq(shipped.min_replan_interval_sec, 1.0)
	assert_eq(NavigationSettings.load_or_default().max_search_radius_m, 60.0, "the radius is the navigation system's")
	assert_eq(CompositionConfig.from_defaults().validate().size(), 0, "; ".join(CompositionConfig.from_defaults().validate()))
	var bad: NpcExecutorSettings = NpcExecutorSettings.new()
	bad.walk_speed_mps = 0.0
	bad.max_planning_nodes_per_tick = 0
	bad.max_search_nodes_per_tick = 0
	bad.max_plans_per_tick = 0
	bad.max_search_nodes = 0
	bad.min_replan_interval_sec = -1.0
	bad.max_replans_per_action = -1
	bad.door_pause_sec = NAN
	assert_eq(bad.validate().size(), 8, "; ".join(bad.validate()))


func test_the_shipped_spots_fit_the_test_map_and_bad_spots_are_refused() -> void:
	var map: MapContentDefinition = MapContentDefinition.load_or_null()
	var spots: NpcSpotSet = NpcSpotSet.load_or_null()
	assert_not_null(map)
	assert_not_null(spots)
	var grid: StructureGrid = StructureGrid.new(BuildingSettings.load_or_default().grid_module_m)
	var half_extent: float = GameplaySettings.load_or_default().world_half_extent_m
	assert_eq(spots.map_id, map.map_id)
	assert_eq(spots.validate().size(), 0, "; ".join(spots.validate()))
	assert_eq(spots.validate_against(map, grid, half_extent).size(), 0, "; ".join(spots.validate_against(map, grid, half_extent)))
	# D7: beds, work places, water and the food container, as map data.
	assert_eq(spots.spot_ids(NpcSpotDefinition.KIND_BED).size(), 10)
	assert_eq(spots.spot_ids(NpcSpotDefinition.KIND_WATER).size(), 3)
	assert_eq(spots.spot_ids(NpcSpotDefinition.KIND_FOOD).size(), 3)
	assert_eq(spots.spot_ids(NpcSpotDefinition.KIND_WORK).size(), 10)
	for house: String in ["house_a", "house_b", "house_c"]:
		assert_true(spots.spot_ids(NpcSpotDefinition.KIND_BED, house).size() >= 1, "%s has a bed" % house)
		assert_eq(spots.spot_ids(NpcSpotDefinition.KIND_WATER, house).size(), 1, "%s has water" % house)
		assert_eq(spots.spot_ids(NpcSpotDefinition.KIND_FOOD, house).size(), 1, "%s has a food container" % house)
	var positions: Dictionary[String, Vector3] = spots.positions(map, grid)
	assert_eq(positions.size(), spots.spots.size(), "every spot has a place on the map")
	# Every dev NPC has a bed on its home tile and a work place on its work tile.
	var definitions: NpcCatalog = NpcCatalog.load_directory()
	for definition_id: String in NpcRoster.load_or_null().npc_definition_ids:
		var definition: NpcDefinition = definitions.get_definition(definition_id)
		var home: Vector3 = NpcRoster.spot_position(map, grid, definition.home_building_id, definition.home_tile_offset)
		var work: Vector3 = NpcRoster.spot_position(map, grid, definition.work_building_id, definition.work_tile_offset)
		var has_bed: bool = false
		var has_work: bool = false
		for spot_id: String in positions:
			has_bed = has_bed or (spots.get_spot(spot_id).kind == NpcSpotDefinition.KIND_BED and positions[spot_id] == home)
			has_work = has_work or (spots.get_spot(spot_id).kind == NpcSpotDefinition.KIND_WORK and positions[spot_id] == work)
		assert_true(has_bed, "%s has a bed at home" % definition_id)
		assert_true(has_work, "%s has a work place" % definition_id)
	# Without the map the building spots have no place (and are not used).
	assert_eq(spots.positions(null, grid).size(), 0)
	# Bad data.
	var bad: NpcSpotSet = NpcSpotSet.new()
	bad.spot_set_id = "bad_spots"
	bad.map_id = map.map_id
	var unknown_kind: NpcSpotDefinition = _spot("couch", "couch", Vector2i(1, 1))
	unknown_kind.building_id = "house_a"
	var twin_a: NpcSpotDefinition = _spot("twin", NpcSpotDefinition.KIND_BED, Vector2i(2, 2))
	twin_a.building_id = "house_a"
	var twin_b: NpcSpotDefinition = _spot("twin", NpcSpotDefinition.KIND_BED, Vector2i(2, 2))
	twin_b.building_id = "house_a"
	bad.spots = [unknown_kind, twin_a, twin_b, _spot("Bad Name", NpcSpotDefinition.KIND_BED, Vector2i(0, 0)), null]
	# unknown kind, duplicate id, the same tile twice, a bad name, an empty entry.
	assert_eq(bad.validate().size(), 5, "; ".join(bad.validate()))
	var misplaced: NpcSpotSet = NpcSpotSet.new()
	misplaced.spot_set_id = "misplaced_spots"
	misplaced.map_id = map.map_id
	var nowhere: NpcSpotDefinition = _spot("nowhere", NpcSpotDefinition.KIND_BED, Vector2i(1, 1))
	nowhere.building_id = "house_z"
	var outside: NpcSpotDefinition = _spot("outside", NpcSpotDefinition.KIND_BED, Vector2i(9, 9))
	outside.building_id = "house_a"
	var no_food: NpcSpotDefinition = _spot("no_food", NpcSpotDefinition.KIND_FOOD, Vector2i(1, 1), false)
	no_food.building_id = "house_a"
	var on_cabinet: NpcSpotDefinition = _spot("on_cabinet", NpcSpotDefinition.KIND_BED, Vector2i(0, 3))
	on_cabinet.building_id = "house_a"
	misplaced.spots = [nowhere, outside, no_food, on_cabinet, _spot("off_map", NpcSpotDefinition.KIND_WATER, Vector2i(100000, 0))]
	assert_eq(misplaced.validate().size(), 0, "; ".join(misplaced.validate()))
	assert_eq(misplaced.validate_against(map, grid, half_extent).size(), 5, "; ".join(misplaced.validate_against(map, grid, half_extent)))


func test_a_world_with_the_test_map_gives_the_executor_the_shipped_spots() -> void:
	# The composition of a dedicated server: the shipped settings, the map
	# content and the roster (GameBootstrap). Nothing is seeded here.
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.map_content = MapContentDefinition.load_or_null()
	config.npc_roster = NpcRoster.load_or_null()
	config.npc_decider = _recorder
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	assert_not_null(world)
	var executor: NpcExecutor = _recorder.executor()
	assert_not_null(executor)
	if executor == null:
		return
	assert_eq(executor.free_spot_ids().size(), 26)
	assert_eq(executor.free_spot_ids(NpcSpotDefinition.KIND_BED).size(), 10)
	assert_eq(executor.free_spot_ids(NpcSpotDefinition.KIND_WATER, "house_b"), PackedStringArray(["water_house_b"]))
	# house_a starts at tile (8, 8); its first bed is the tile (1, 1) inside.
	assert_eq(executor.spot_position("bed_house_a_1"), Vector3(9.5, 0.0, 9.5))
	assert_eq(executor.spot_definition("food_house_c").exclusive, false)
	# Without the map content the building spots have no place.
	var bare: Recorder = Recorder.new()
	var bare_config: CompositionConfig = CompositionConfig.from_defaults()
	bare_config.npc_decider = bare
	assert_not_null(ServerComposition.create_world(WORLD, bare_config))
	assert_eq(bare.executor().free_spot_ids().size(), 0)
	assert_false(bare.executor().has_spot("bed_house_a_1"))


func test_the_default_composition_gives_every_npc_an_idle_executor_state() -> void:
	var started: Dictionary = _start([SPAWN + Vector3(1.0, 0.0, 0.0), SPAWN + Vector3(2.0, 0.0, 0.0)])
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	assert_not_null(executor, "a decider with on_executor_attached is given the executor")
	if executor == null:
		return
	var before: Dictionary = {}
	for npc_id: String in started["ids"]:
		assert_true(_npcs(world).get_npc(npc_id).component(NpcExecutorState.COMPONENT_ID) is NpcExecutorState)
		assert_false(executor.is_busy(npc_id))
		assert_eq(executor.phase_of(npc_id), NpcExecutorState.PHASE_IDLE)
		before[npc_id] = [_position(world, npc_id), _json(_state_document(world, npc_id))]
	_run(world, 100)
	for npc_id: String in started["ids"]:
		assert_eq(_position(world, npc_id), before[npc_id][0], "an NPC that was told nothing stands still")
		assert_eq(_json(_state_document(world, npc_id)), before[npc_id][1], "and its executor document does not change")
	assert_eq(_stage_document(world).size(), 0, "a world in which nobody planned saves nothing of the stage")
	assert_eq(_recorder.log.size(), 0)


# ------------------------------------------------------------ walking

func test_an_npc_walks_around_a_wall_one_resolved_step_per_tick() -> void:
	var started: Dictionary = _start([Vector3(13.5, 0.0, 13.25)])
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	var npc_id: String = started["ids"][0]
	var spy: StepSpy = StepSpy.new()
	assert_eq(world.register_system(spy), OK)
	# A wall on the line x = 15 for z 10 .. 16, between the NPC and its goal.
	_barrier(world, 15, 10, 16)
	var goal: Vector3 = Vector3(17.5, 0.0, 13.75)
	var begun: ActionResult = executor.begin_move(npc_id, goal)
	assert_true(begun.ok, begun.reason)
	assert_true(executor.is_busy(npc_id))
	assert_eq(executor.begin_move(npc_id, goal).reason, NpcExecutor.REASON_BUSY, "one action at a time")
	var trail: Array[Vector3] = _until_told(world, npc_id, DONE)
	assert_eq(_position(world, npc_id), goal, "it arrives exactly at the goal")
	assert_false(executor.is_busy(npc_id))
	assert_eq(executor.last_outcome(npc_id), {NpcExecutor.OUTCOME_RESULT: NpcExecutorState.RESULT_DONE, NpcExecutor.OUTCOME_CODE: ""})
	assert_eq(_recorder.told(npc_id), PackedStringArray([DONE]))
	var moved_ticks: int = 0
	var went_around: bool = false
	for index: int in range(1, trail.size()):
		var from: Vector3 = trail[index - 1]
		var to: Vector3 = trail[index]
		if from == to:
			continue
		moved_ticks += 1
		assert_true(from.distance_to(to) <= SPEED * TICK + 0.0001, "a step is at most speed x tick: %f" % from.distance_to(to))
		# It never goes through the wall.
		if (from.x < 15.0) != (to.x < 15.0):
			went_around = true
			assert_true(minf(from.z, to.z) >= 17.0 or maxf(from.z, to.z) < 10.0, "crossed the wall's line at z %f" % to.z)
	assert_true(went_around)
	# The straight line is 4 m; the way round is much longer.
	assert_true(moved_ticks > roundi(8.0 / (SPEED * TICK)), "it took the long way: %d ticks" % moved_ticks)
	assert_eq(int(spy.calls.get(NpcService.ENTITY_KIND, 0)), moved_ticks, "one ServerWorld.resolve_movement per step")
	assert_eq(executor.total_search_count, 1, "one search for the whole walk")
	# It faces the way it walked last.
	var last_step: Vector3 = trail[trail.size() - 1] - trail[trail.size() - 3]
	assert_true(absf(angle_difference(_npcs(world).get_npc(npc_id).yaw, atan2(-last_step.x, -last_step.z))) < 0.01)
	# Running is faster.
	assert_true(executor.begin_move(npc_id, Vector3(17.5, 0.0, 8.5), true).ok)
	_run(world, 2)
	var before: Vector3 = _position(world, npc_id)
	_run(world, 1)
	assert_true(is_equal_approx(before.distance_to(_position(world, npc_id)), 2.0 * SPEED * TICK), "a running step")
	# What cannot be begun.
	assert_true(executor.cancel(npc_id))
	assert_false(executor.is_busy(npc_id))
	assert_eq(executor.last_outcome(npc_id)[NpcExecutor.OUTCOME_RESULT], NpcExecutorState.RESULT_CANCELLED)
	assert_false(executor.cancel(npc_id), "nothing to cancel")
	assert_eq(executor.begin_move("npc_999999", goal).reason, NpcExecutor.REASON_UNKNOWN_NPC)
	assert_eq(executor.begin_move(npc_id, Vector3(500.0, 0.0, 0.0)).reason, NpcExecutor.REASON_BAD_TARGET)
	assert_eq(executor.begin_move(npc_id, Vector3(NAN, 0.0, 0.0)).reason, NpcExecutor.REASON_BAD_TARGET)
	assert_eq(executor.begin_use_spot(npc_id, "no_such_spot", 1.0).reason, NpcExecutor.REASON_UNKNOWN_SPOT)
	assert_eq(executor.begin_use_spot(npc_id, BENCH, -3.0).reason, NpcExecutor.REASON_BAD_DURATION)
	assert_eq(_recorder.told(npc_id), PackedStringArray([DONE]), "a cancelled action tells nobody")


func test_an_npc_opens_the_door_in_its_way_and_closes_it_behind_itself() -> void:
	var started: Dictionary = _start([Vector3(13.5, 0.0, 15.5)])
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	var npc_id: String = started["ids"][0]
	var door_id: String = _house(world)
	var door: StructureInstance = _building(world).get_structure(door_id)
	var outside: Vector3 = Vector3(13.5, 0.0, 15.5)
	var inside: Vector3 = Vector3(8.5, 0.0, 15.5)
	assert_false(door.door_open)
	assert_false(_navigation(world).find_path(outside, inside).found, "the house is shut to the default search (zombies)")
	_building(world).drain_events()
	assert_true(executor.begin_move(npc_id, inside).ok)
	var trail: Array[Vector3] = [outside]
	var open_ticks: int = 0
	var opened_at: Vector3 = Vector3.ZERO
	var stood_ticks: int = 0
	var closed_at: Vector3 = Vector3.ZERO
	var busy_when_closed: bool = false
	for guard: int in range(400):
		if _recorder.told(npc_id).has(DONE):
			break
		_run(world, 1)
		trail.append(_position(world, npc_id))
		if door.door_open:
			if open_ticks == 0:
				opened_at = _position(world, npc_id)
			open_ticks += 1
			if _position(world, npc_id) == opened_at:
				stood_ticks += 1
		elif open_ticks > 0 and closed_at == Vector3.ZERO:
			closed_at = _position(world, npc_id)
			busy_when_closed = executor.is_busy(npc_id)
	assert_eq(_position(world, npc_id), inside, "it is inside")
	assert_true(open_ticks > 0, "the door was opened")
	assert_true(opened_at.x > 11.0 and opened_at.x <= 12.0, "it opened the door from the tile in front of it: %s" % str(opened_at))
	# door_pause_sec 0.2 = 4 ticks in front of the door it opened.
	assert_true(stood_ticks >= 4, "it waited in front of the door: %d ticks" % stood_ticks)
	assert_false(door.door_open, "and closed it behind itself")
	assert_eq(closed_at, Vector3(10.5, 0.0, 15.5), "it closes the door from the first tile behind it")
	assert_true(busy_when_closed, "and walks on: the door is not left open until it arrives")
	for point: Vector3 in trail:
		assert_true(is_equal_approx(point.z, 15.5), "straight through the door: %s" % str(point))
	var door_events: int = 0
	for event: Dictionary in _building(world).drain_events():
		if str(event.get("cause", "")) == BuildingService.CAUSE_DOOR:
			door_events += 1
			assert_eq(str(event.get("player_id", "x")), "", "a server rule opens and closes it")
	assert_eq(door_events, 2, "opened once, closed once: public like a player's door")
	assert_eq(executor.doors_opened_count, 1)
	assert_eq(executor.doors_closed_count, 1)
	assert_false(_navigation(world).find_path(outside, inside).found, "still shut to the default search")
	assert_false(_navigation(world).find_path(inside, outside).found)
	# A door somebody else left open stays open: the NPC only closes what it opened.
	assert_true(_building(world).set_door_open(world, door_id, true).ok)
	_recorder.log.clear()
	assert_true(executor.begin_move(npc_id, outside).ok)
	_until_told(world, npc_id, DONE)
	assert_eq(_position(world, npc_id), outside)
	assert_true(door.door_open, "it leaves an open door open")
	assert_eq(executor.doors_opened_count, 1)
	# A cancelled walk closes the door it opened.
	assert_true(_building(world).set_door_open(world, door_id, false).ok)
	_recorder.log.clear()
	assert_true(executor.begin_move(npc_id, inside).ok)
	for guard: int in range(400):
		if door.door_open:
			break
		_run(world, 1)
	assert_true(door.door_open)
	assert_true(executor.cancel(npc_id))
	assert_false(door.door_open, "cancelling closes the door it opened")


# ------------------------------------------------------------ planning budget

func test_planning_is_first_come_first_served_within_the_node_budget() -> void:
	_exec.max_planning_nodes_per_tick = 24
	_exec.max_search_nodes_per_tick = 8
	_exec.max_plans_per_tick = 4
	var positions: Array[Vector3] = []
	for index: int in range(6):
		positions.append(Vector3(12.5, 0.0, 6.5 + 3.0 * float(index)))
	var started: Dictionary = _start(positions)
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	var ids: PackedStringArray = started["ids"]
	# A long wall right in front of everybody: every search has to work.
	_barrier(world, 15, -5, 28)
	# Asked for in this order (not the order of the ids).
	var order: PackedStringArray = [ids[3], ids[0], ids[5], ids[1], ids[4], ids[2]]
	for npc_id: String in order:
		assert_true(executor.begin_move(npc_id, _position(world, npc_id) + Vector3(5.0, 0.0, 0.0)).ok)
	assert_eq(executor.queued_npc_ids(), order, "the queue is the order of asking")
	_run(world, 1)
	# 24 nodes, 8 per search: the first three had a turn and went to the back.
	assert_eq(executor.last_plan_node_count, 24)
	assert_eq(executor.last_plan_turn_count, 3)
	assert_eq(executor.queued_npc_ids(), PackedStringArray([order[3], order[4], order[5], order[0], order[1], order[2]]))
	for index: int in range(6):
		assert_eq(int(_state_document(world, order[index])[NpcExecutorState.KEY_PLAN_EXPANDED]), 8 if index < 3 else 0)
	var planned_at: Dictionary[String, int] = {}
	for tick: int in range(2, 3000):
		_run(world, 1)
		assert_true(executor.last_plan_node_count <= 24, "tick %d expanded %d nodes" % [tick, executor.last_plan_node_count])
		assert_true(executor.last_plan_turn_count <= 4)
		for npc_id: String in ids:
			if not planned_at.has(npc_id) and executor.phase_of(npc_id) != NpcExecutorState.PHASE_PLANNING:
				planned_at[npc_id] = tick
		if planned_at.size() == ids.size():
			break
	assert_eq(planned_at.size(), ids.size(), "nobody starves: %s" % str(planned_at))
	assert_eq(executor.peak_plan_nodes_per_tick, 24, "the budget is used, never exceeded")
	assert_eq(executor.peak_search_nodes_per_tick, 8)
	assert_true(executor.peak_plan_turns_per_tick <= 4)
	assert_eq(executor.total_search_count, 6)
	assert_eq(executor.queued_npc_ids().size(), 0)
	# The turn cap alone: four searches a tick, however small.
	_exec.max_planning_nodes_per_tick = 100000
	_exec.max_search_nodes_per_tick = 1
	for npc_id: String in ids:
		executor.cancel(npc_id)
		assert_true(executor.begin_move(npc_id, _position(world, npc_id) + Vector3(0.0, 0.0, 2.0)).ok)
	_run(world, 1)
	assert_eq(executor.last_plan_turn_count, 4)
	assert_eq(executor.last_plan_node_count, 4)


# ------------------------------------------------------------ reservations

func test_a_spot_is_held_by_one_npc_and_given_back_when_the_action_ends() -> void:
	var started: Dictionary = _start([Vector3(3.5, 0.0, 10.5), Vector3(4.5, 0.0, 10.5), Vector3(1.5, 0.0, 3.5)])
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	var a: String = started["ids"][0]
	var b: String = started["ids"][1]
	var c: String = started["ids"][2]
	_seal(world, Vector2i(15, -5))
	assert_true(executor.has_spot(WATER_OUT))
	assert_eq(executor.spot_position(WATER_OUT), Vector3(2.5, 0.0, 12.5))
	assert_false(executor.has_spot("no_such_spot"))
	assert_eq(executor.free_spot_ids(NpcSpotDefinition.KIND_BED), PackedStringArray([BED_EAST, BED_IN, BED_SEALED]))
	# By hand: one NPC per spot, one spot per NPC.
	assert_true(executor.reserve(a, WATER_OUT).ok)
	assert_true(executor.reserve(a, WATER_OUT).ok, "asking again is fine")
	assert_eq(executor.reserve(b, WATER_OUT).reason, NpcExecutor.REASON_SPOT_RESERVED, "two NPCs cannot reserve one spot")
	assert_eq(executor.holder_of(WATER_OUT), a)
	assert_eq(executor.reserved_spot_of(a), WATER_OUT)
	assert_false(executor.is_spot_free(WATER_OUT))
	assert_true(executor.is_spot_free(WATER_OUT, a))
	assert_eq(executor.free_spot_ids(NpcSpotDefinition.KIND_WATER).size(), 0)
	assert_eq(executor.reserve(a, "no_such_spot").reason, NpcExecutor.REASON_UNKNOWN_SPOT)
	assert_true(executor.reserve(a, BED_IN).ok, "another spot: the first one is given back")
	assert_eq(executor.holder_of(WATER_OUT), "")
	assert_true(executor.release(a))
	assert_false(executor.release(a))
	assert_eq(executor.holder_of(BED_IN), "")
	# Using a spot reserves it for as long as the action lasts.
	assert_true(executor.begin_use_spot(a, WATER_OUT, 0.5).ok)
	assert_eq(executor.holder_of(WATER_OUT), a, "reserved while it walks there")
	var refused: ActionResult = executor.begin_use_spot(b, WATER_OUT, 0.5)
	assert_eq(refused.reason, NpcExecutor.REASON_SPOT_RESERVED, "the conflict is known at once")
	assert_false(executor.is_busy(b))
	_until_told(world, a, ARRIVED)
	assert_eq(_position(world, a), Vector3(2.5, 0.0, 12.5))
	assert_eq(executor.phase_of(a), NpcExecutorState.PHASE_USING)
	assert_eq(executor.holder_of(WATER_OUT), a)
	var arrived_tick: int = _recorder.tick_of(a, ARRIVED)
	_until_told(world, a, DONE)
	# 0.5 s = 10 ticks of using; the decider hears of each one tick later.
	assert_eq(_recorder.tick_of(a, DONE) - arrived_tick, 10)
	assert_eq(executor.holder_of(WATER_OUT), "", "completion gives the spot back")
	assert_eq(_recorder.told(b).size(), 0, "a refusal is an answer, not an interrupt")
	# Cancelling gives it back.
	assert_true(executor.begin_use_spot(b, WATER_OUT, NpcExecutor.HOLD).ok)
	assert_eq(executor.holder_of(WATER_OUT), b)
	_until_told(world, b, ARRIVED)
	_run(world, 100)
	assert_eq(executor.phase_of(b), NpcExecutorState.PHASE_USING, "HOLD lasts until it is cancelled")
	assert_true(executor.cancel(b))
	assert_eq(executor.holder_of(WATER_OUT), "")
	# Failing gives it back: nobody gets into the sealed box.
	assert_true(executor.begin_use_spot(a, BED_SEALED, 1.0).ok)
	assert_eq(executor.holder_of(BED_SEALED), a)
	_until_told(world, a, FAILED + NpcExecutor.FAIL_PATH_NOT_FOUND)
	assert_eq(executor.holder_of(BED_SEALED), "", "failure gives the spot back")
	assert_eq(executor.last_outcome(a), {NpcExecutor.OUTCOME_RESULT: NpcExecutorState.RESULT_FAILED, NpcExecutor.OUTCOME_CODE: NpcExecutor.FAIL_PATH_NOT_FOUND})
	# A spot reserved by hand outlives the action that uses it.
	assert_true(executor.reserve(a, WATER_OUT).ok)
	assert_true(executor.begin_use_spot(a, WATER_OUT, 0.1).ok)
	_recorder.log.clear()
	_until_told(world, a, DONE)
	assert_eq(executor.holder_of(WATER_OUT), a)
	# A spot that is not exclusive is used by many and reserved by nobody.
	assert_true(executor.begin_use_spot(b, BENCH, NpcExecutor.HOLD).ok)
	assert_true(executor.begin_use_spot(c, BENCH, NpcExecutor.HOLD).ok)
	assert_eq(executor.holder_of(BENCH), "")
	assert_true(executor.is_spot_free(BENCH))
	_until_told(world, b, ARRIVED)
	_until_told(world, c, ARRIVED)
	assert_eq(_position(world, b), _position(world, c))
	# An NPC that is removed gives its spot back.
	assert_true(_npcs(world).remove_npc(world, a).ok)
	assert_eq(executor.holder_of(WATER_OUT), "", "removal gives the spot back")
	assert_eq(executor.reserve(a, WATER_OUT).reason, NpcExecutor.REASON_UNKNOWN_NPC)


func test_a_sleeping_npc_gives_its_spot_up_and_fails_when_somebody_took_it() -> void:
	var started: Dictionary = _start([Vector3(24.5, 0.0, 5.5), Vector3(22.5, 0.0, 6.5), Vector3(3.5, 0.0, 5.5)])
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	var alice: PlayerState = started["alice"]
	var east: String = started["ids"][0]
	var walker: String = started["ids"][1]
	var west: String = started["ids"][2]
	assert_true(executor.begin_use_spot(east, BED_EAST, NpcExecutor.HOLD).ok)
	_until_told(world, east, ARRIVED)
	assert_true(executor.begin_move(walker, Vector3(22.5, 0.0, 26.5)).ok)
	_run(world, 5)
	# The player walks west: the cells from x = 20 are no longer simulated.
	alice.position = Vector3(-4.5, 0.0, 5.5)
	_run(world, 2)
	assert_false(_npcs(world).is_awake(east))
	assert_true(_npcs(world).is_awake(west))
	assert_eq(executor.holder_of(BED_EAST), "", "a sleeping NPC holds no spot")
	assert_eq(executor.phase_of(east), NpcExecutorState.PHASE_USING, "its action is frozen as it is")
	var frozen_at: Vector3 = _position(world, walker)
	_run(world, 40)
	assert_eq(_position(world, walker), frozen_at, "a sleeping NPC does not walk")
	assert_eq(executor.phase_of(walker), NpcExecutorState.PHASE_MOVING)
	assert_eq(executor.begin_move(east, SPAWN).reason, NpcExecutor.REASON_NOT_AWAKE)
	assert_eq(executor.reserve(east, BED_EAST).reason, NpcExecutor.REASON_NOT_AWAKE)
	# Somebody who is awake takes the bed.
	assert_true(executor.reserve(west, BED_EAST).ok)
	alice.position = SPAWN
	_run(world, 3)
	assert_true(_npcs(world).is_awake(east))
	assert_eq(executor.holder_of(BED_EAST), west, "who took it keeps it")
	assert_false(executor.is_busy(east))
	assert_eq(_recorder.told(east), PackedStringArray([ARRIVED, FAILED + NpcExecutor.FAIL_SPOT_RESERVED]))
	assert_eq(executor.last_outcome(east)[NpcExecutor.OUTCOME_CODE], NpcExecutor.FAIL_SPOT_RESERVED)
	assert_eq(executor.reserved_spot_of(east), "")
	# The walker goes on where it stopped, without planning again.
	assert_eq(executor.total_search_count, 2)
	_until_told(world, walker, DONE)
	assert_eq(_position(world, walker), Vector3(22.5, 0.0, 26.5))
	assert_eq(executor.total_search_count, 2)
	# Nobody took it: the sleeper gets its spot back when it wakes.
	assert_true(executor.release(west))
	assert_true(executor.begin_use_spot(east, BED_EAST, NpcExecutor.HOLD).ok)
	alice.position = Vector3(-4.5, 0.0, 5.5)
	_run(world, 2)
	assert_eq(executor.holder_of(BED_EAST), "")
	alice.position = SPAWN
	_run(world, 3)
	assert_eq(executor.holder_of(BED_EAST), east)
	assert_eq(executor.phase_of(east), NpcExecutorState.PHASE_USING)
	# A spot held by hand that somebody took: the sleeper is told when it wakes.
	assert_true(executor.cancel(east))
	assert_true(executor.reserve(east, BED_EAST).ok)
	alice.position = Vector3(-4.5, 0.0, 5.5)
	_run(world, 2)
	assert_true(executor.reserve(west, BED_EAST).ok)
	alice.position = SPAWN
	_recorder.log.clear()
	_run(world, 3)
	assert_eq(_recorder.told(east), PackedStringArray([NpcExecutor.INTERRUPT_RESERVATION_LOST]))
	assert_eq(executor.holder_of(BED_EAST), west)


func test_two_sleepers_that_want_one_spot_the_lower_id_gets_it() -> void:
	# The cells of both NPCs are two rings from the player's: they sleep and
	# wake together when the player steps one cell diagonally away and back.
	# Two pairs, mirrored, so that in one of them the higher id stands in the
	# cell that wakes first, whichever cell that is.
	var east: Vector3 = Vector3(24.5, 0.0, 5.5)
	var south: Vector3 = Vector3(5.5, 0.0, 24.5)
	var started: Dictionary = _start([east, south, south + Vector3(1.0, 0.0, 0.0), east + Vector3(0.0, 0.0, 1.0)])
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	var alice: PlayerState = started["alice"]
	var ids: PackedStringArray = started["ids"]
	# In each pair the NPC in the east holds the spot, falls asleep, and the
	# one in the south takes it; then both sleep, each wanting it back.
	assert_true(executor.reserve(ids[0], BED_EAST).ok)
	assert_true(executor.reserve(ids[3], WATER_OUT).ok)
	alice.position = Vector3(-4.5, 0.0, 5.5)
	_run(world, 2)
	assert_false(_npcs(world).is_awake(ids[0]))
	assert_false(_npcs(world).is_awake(ids[3]))
	assert_true(_npcs(world).is_awake(ids[1]))
	assert_true(_npcs(world).is_awake(ids[2]))
	assert_true(executor.reserve(ids[1], BED_EAST).ok)
	assert_true(executor.reserve(ids[2], WATER_OUT).ok)
	alice.position = Vector3(-4.5, 0.0, -4.5)
	_run(world, 2)
	assert_eq(_npcs(world).awake_count(), 0)
	assert_eq(_npcs(world).npc_count(), 4, "all are still in memory")
	assert_eq(executor.holder_of(BED_EAST), "")
	assert_eq(executor.holder_of(WATER_OUT), "")
	for npc_id: String in ids:
		assert_ne(executor.reserved_spot_of(npc_id), "", "%s wants its spot back" % npc_id)
	alice.position = SPAWN
	_run(world, 3)
	assert_eq(_npcs(world).awake_count(), 4)
	assert_eq(executor.holder_of(BED_EAST), ids[0], "the lower id, whoever woke first")
	assert_eq(executor.holder_of(WATER_OUT), ids[2], "the lower id, whoever woke first")
	assert_eq(executor.reserved_spot_of(ids[1]), "")
	assert_eq(executor.reserved_spot_of(ids[3]), "")
	assert_eq(_recorder.told(ids[1]), PackedStringArray([NpcExecutor.INTERRUPT_RESERVATION_LOST]))
	assert_eq(_recorder.told(ids[3]), PackedStringArray([NpcExecutor.INTERRUPT_RESERVATION_LOST]))
	assert_eq(_recorder.told(ids[0]).size() + _recorder.told(ids[2]).size(), 0)


# ------------------------------------------------------------ failures

func test_failures_have_reason_codes_and_interrupt_the_decision_layer() -> void:
	var started: Dictionary = _start([Vector3(13.5, 0.0, 13.5), Vector3(3.5, 0.0, 10.5), Vector3(2.5, 0.0, 2.5), Vector3(8.5, 0.0, -5.5)])
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	var ids: PackedStringArray = started["ids"]
	var spy: StepSpy = StepSpy.new()
	assert_eq(world.register_system(spy), OK)
	_seal(world, Vector2i(15, -5))
	assert_eq(NpcExecutor.failure_code_of(FAILED + NpcExecutor.FAIL_TARGET_GONE), NpcExecutor.FAIL_TARGET_GONE)
	assert_eq(NpcExecutor.failure_code_of(DONE), "")
	for code: String in [NpcExecutor.FAIL_PATH_NOT_FOUND, NpcExecutor.FAIL_PATH_BLOCKED, NpcExecutor.FAIL_TARGET_GONE, NpcExecutor.FAIL_SPOT_RESERVED]:
		assert_true(NpcScheduleComponent.is_valid_reason(FAILED + code), "%s is a name the scheduler takes" % code)
	for reason: String in [DONE, ARRIVED, NpcExecutor.INTERRUPT_RESERVATION_LOST]:
		assert_true(NpcScheduleComponent.is_valid_reason(reason))
	# No path: the goal is walled in.
	assert_true(executor.begin_move(ids[3], Vector3(15.5, 0.0, -4.5)).ok)
	_until_told(world, ids[3], FAILED + NpcExecutor.FAIL_PATH_NOT_FOUND)
	assert_eq(_position(world, ids[3]), Vector3(8.5, 0.0, -5.5), "it did not set out")
	assert_eq(executor.last_outcome(ids[3]), {NpcExecutor.OUTCOME_RESULT: NpcExecutorState.RESULT_FAILED, NpcExecutor.OUTCOME_CODE: NpcExecutor.FAIL_PATH_NOT_FOUND})
	assert_false(executor.is_busy(ids[3]))
	# The target is gone: the thing it walks to is removed on the way.
	var post: String = _place(world, WALL, Vector2i(3, 18), 0)
	assert_true(executor.begin_move(ids[1], Vector3(3.5, 0.0, 17.5), false, post).ok)
	_run(world, 10)
	assert_true(executor.is_busy(ids[1]))
	assert_true(_building(world).remove_structure(world, post).ok)
	_run(world, 2)
	assert_eq(_recorder.told(ids[1]), PackedStringArray([FAILED + NpcExecutor.FAIL_TARGET_GONE]))
	assert_false(executor.is_busy(ids[1]))
	var stopped_at: Vector3 = _position(world, ids[1])
	assert_true(stopped_at.z > 10.5 and stopped_at.z < 17.0, "it stops where it is: %s" % str(stopped_at))
	assert_eq(executor.begin_move(ids[1], SPAWN, false, post).reason, NpcExecutor.REASON_BAD_TARGET, "a target that is already gone is refused at once")
	# A new wall across the way: it plans again (after the pause) and arrives.
	assert_true(executor.begin_move(ids[0], Vector3(17.5, 0.0, 13.5)).ok)
	_run(world, 5)
	_barrier(world, 15, 10, 16)
	var searches: int = executor.total_search_count
	_until_told(world, ids[0], DONE)
	assert_eq(_position(world, ids[0]), Vector3(17.5, 0.0, 13.5))
	assert_eq(executor.total_search_count, searches + 1, "one more search")
	assert_eq(executor.total_replan_count, 1)
	# Blocked again and again by something no search sees: it gives up.
	spy.npc_line_x = 4.0
	assert_true(executor.begin_move(ids[2], Vector3(6.5, 0.0, 2.5)).ok)
	_until_told(world, ids[2], FAILED + NpcExecutor.FAIL_PATH_BLOCKED)
	assert_true(_position(world, ids[2]).x < 4.0)
	assert_eq(executor.total_replan_count, 1 + _exec.max_replans_per_action, "it tried max_replans_per_action more times")
	assert_eq(executor.last_outcome(ids[2])[NpcExecutor.OUTCOME_CODE], NpcExecutor.FAIL_PATH_BLOCKED)
	assert_false(executor.is_busy(ids[2]))


# ------------------------------------------------------------ save and restore

const SCRIPT_SPOTS: Array[Vector3] = [
	Vector3(13.5, 0.0, 13.25), Vector3(13.5, 0.0, 15.5), Vector3(3.5, 0.0, 10.5),
	Vector3(24.5, 0.0, 5.5), Vector3(1.5, 0.0, 3.5),
]
const SCRIPT_TICKS: int = 900
## What every NPC is asked to do, turn by turn: [kind, target or spot,
## duration]. "m" walk, "r" run, "u" use a spot.
const SCRIPT_PLANS: Array[Array] = [
	[["m", Vector3(17.5, 0.0, 13.75)], ["u", BED_IN, 0.6], ["m", Vector3(13.5, 0.0, 13.25)], ["r", Vector3(18.5, 0.0, 22.5)]],
	[["u", BED_IN, 1.0], ["m", Vector3(13.5, 0.0, 15.5)], ["u", WATER_OUT, 0.4], ["m", Vector3(9.5, 0.0, 16.5)]],
	[["u", WATER_OUT, NpcExecutor.HOLD], ["m", Vector3(3.5, 0.0, 16.5)], ["u", BENCH, 0.3], ["m", Vector3(7.5, 0.0, 14.5)]],
	[["u", BED_EAST, 2.0], ["m", Vector3(18.5, 0.0, 8.5)], ["u", BED_EAST, NpcExecutor.HOLD], ["r", Vector3(24.5, 0.0, 5.5)]],
	[["u", BENCH, 0.5], ["m", Vector3(16.5, 0.0, 18.5)], ["u", BED_SEALED, 1.0], ["m", Vector3(1.5, 0.0, 3.5)]],
]


func _script_setup(world: ServerWorld) -> void:
	_barrier(world, 15, 10, 16)
	_house(world)
	_seal(world, Vector2i(15, -5))


## One tick of the script: the player walks west and back (so NPCs fall
## asleep, leave memory and come back), every 45 ticks every NPC that has
## nothing to do is given its next action, and now and then one is
## cancelled. Everything depends on the tick and on the world only.
func _scripted_tick(world: ServerWorld, recorder: Recorder, alice: PlayerState, ids: PackedStringArray, tick: int, seen: Dictionary = {}) -> String:
	var executor: NpcExecutor = recorder.executor()
	var phase: int = tick % 300
	alice.position = Vector3(5.5 - 0.3 * float(maxi(mini(phase, 300 - phase) - 60, 0)), 0.0, 5.5)
	if tick % 45 == 0:
		for index: int in range(ids.size()):
			if not executor.is_busy(ids[index]):
				var plans: Array = SCRIPT_PLANS[index]
				var plan: Array = plans[(tick / 45) % plans.size()]
				if str(plan[0]) == "u":
					executor.begin_use_spot(ids[index], str(plan[1]), float(plan[2]))
				else:
					executor.begin_move(ids[index], plan[1] as Vector3, str(plan[0]) == "r")
	if tick % 97 == 40:
		executor.cancel(ids[(tick / 97) % ids.size()])
	recorder.tick = tick
	world.step_systems(TICK)
	var npcs: NpcService = _npcs(world)
	var line: PackedStringArray = []
	for npc_id: String in ids:
		var npc: NpcState = npcs.get_npc(npc_id)
		if npc == null:
			line.append("%s gone" % npc_id)
			seen["out_of_memory"] = true
			continue
		var state: NpcExecutorState = npc.component(NpcExecutorState.COMPONENT_ID) as NpcExecutorState
		# The position is exact. The facing is a 64-bit float that this test's
		# text round trip (JSON without full precision) cuts to 14 decimals
		# and takes the sign of a zero from.
		var facing: String = "%.9f" % npc.yaw
		line.append("%s %s %s %s" % [npc_id, var_to_str(npc.position), "0.000000000" if facing == "-0.000000000" else facing, state.phase])
		if not npcs.is_awake(npc_id) and state.is_busy():
			seen["asleep_busy"] = true
	return " | ".join(line)


## What a save point catches: which NPC states the saved documents hold.
func _saved_kinds(world: ServerWorld, ids: PackedStringArray) -> PackedStringArray:
	var kinds: PackedStringArray = []
	for npc_id: String in ids:
		var npc: NpcState = _npcs(world).get_npc(npc_id)
		if npc == null:
			kinds.append("out_of_memory")
			continue
		var state: NpcExecutorState = npc.component(NpcExecutorState.COMPONENT_ID) as NpcExecutorState
		if state.phase == NpcExecutorState.PHASE_PLANNING and state.plan_expanded > 0:
			kinds.append("mid_search")
		elif state.phase == NpcExecutorState.PHASE_PLANNING:
			kinds.append("waiting_to_search")
		elif state.phase == NpcExecutorState.PHASE_MOVING and state.timer_usec > 0:
			kinds.append("at_a_door")
		elif state.phase == NpcExecutorState.PHASE_MOVING and not state.opened_doors.is_empty():
			kinds.append("in_a_doorway")
		elif state.phase == NpcExecutorState.PHASE_MOVING:
			kinds.append("mid_walk")
		elif state.phase == NpcExecutorState.PHASE_USING:
			kinds.append("using")
		if not _npcs(world).is_awake(npc_id) and state.is_busy():
			kinds.append("asleep_busy")
		if not state.reserved_spot_id.is_empty():
			kinds.append("reserved")
	return kinds


func _states(world: ServerWorld) -> Dictionary:
	var result: Dictionary = {}
	for npc_id: String in _npcs(world).npc_ids():
		result[npc_id] = _state_document(world, npc_id)
	return result


func _script_exec_settings() -> void:
	# The shipped budget: searches take several ticks.
	_exec.max_planning_nodes_per_tick = 24
	_exec.max_search_nodes_per_tick = 8
	_exec.max_plans_per_tick = 4
	_exec.min_replan_interval_sec = 0.5
	# A search that finds nothing gives up within the script.
	_exec.max_search_nodes = 160


const SAVE_POINTS: PackedInt32Array = [1, 2, 9, 28, 47, 60, 101, 140, 200, 262, 370, 455, 583, 742]


func test_a_run_that_is_saved_restarted_and_restored_walks_like_one_that_goes_on() -> void:
	_script_exec_settings()
	# The run that goes on.
	var recorder: Recorder = Recorder.new()
	var started: Dictionary = _start(SCRIPT_SPOTS, recorder)
	var world: ServerWorld = started["world"]
	var ids: PackedStringArray = started["ids"]
	_script_setup(world)
	var seen: Dictionary = {}
	var expected_trail: PackedStringArray = []
	for tick: int in range(SCRIPT_TICKS):
		expected_trail.append(_scripted_tick(world, recorder, started["alice"], ids, tick, seen))
		if OS.has_environment("ZSS_NPC_EXECUTOR_TIMELINE"):
			print("[timeline] saved at %d would catch: %s" % [tick + 1, ", ".join(_saved_kinds(world, ids))])
	var expected_log: PackedStringArray = recorder.log
	var told: String = " ".join(expected_log)
	for reason: String in [DONE, ARRIVED, FAILED + NpcExecutor.FAIL_PATH_NOT_FOUND]:
		assert_contains(told, reason, "the script covers %s" % reason)
	for what: String in ["asleep_busy", "out_of_memory"]:
		assert_true(bool(seen.get(what, false)), "the script covers NPCs that are %s" % what)
	var executor: NpcExecutor = recorder.executor()
	assert_true(executor.doors_opened_count >= 2 and executor.doors_closed_count >= 2, "the script goes through doors")
	assert_true(executor.total_search_count >= 12, "the script plans: %d searches" % executor.total_search_count)
	var expected_states: Dictionary = _json(_states(world))
	var expected_stage: Dictionary = _json(_stage_document(world))
	assert_true(int(expected_stage.get(NpcExecutor.KEY_NEXT_PLAN_SEQ, 0)) > 0, "the stage saves its queue counter")
	# The same script run twice gives the same run (no hidden randomness).
	var again: Recorder = Recorder.new()
	var twin: Dictionary = _start(SCRIPT_SPOTS, again)
	_script_setup(twin["world"])
	for tick: int in range(SCRIPT_TICKS):
		if _scripted_tick(twin["world"], again, twin["alice"], ids, tick) != expected_trail[tick]:
			fail("a second run differs at tick %d" % tick)
			break
	assert_eq(again.log, expected_log, "a second run tells the deciders the same")
	# The same run, saved after tick `save_at - 1` and restored into a new
	# world (a restart).
	var caught: Dictionary[String, bool] = {}
	for save_at: int in SAVE_POINTS:
		var before: Recorder = Recorder.new()
		var first: Dictionary = _start(SCRIPT_SPOTS, before)
		var first_world: ServerWorld = first["world"]
		_script_setup(first_world)
		for tick: int in range(save_at):
			_scripted_tick(first_world, before, first["alice"], ids, tick)
		for kind: String in _saved_kinds(first_world, ids):
			caught[kind] = true
		var saved_states: Dictionary = _json(_states(first_world))
		# A save is text: the documents go through JSON.
		var documents: Dictionary = _json(first_world.to_documents())
		var after: Recorder = Recorder.new()
		var second_world: ServerWorld = _world(after)
		assert_eq(second_world.restore_documents(documents["world_state"], documents["players"], documents["cells"]).size(), 0)
		var alice: PlayerState = second_world.join("alice")
		# Restored: the same action, the same waypoints still ahead.
		for npc_id: String in _npcs(second_world).npc_ids():
			assert_eq(_json(_state_document(second_world, npc_id)), saved_states[npc_id], "saved at %d: %s is restored as it was saved" % [save_at, npc_id])
		var searches_before_restore: int = after.executor().total_search_count
		assert_eq(searches_before_restore, 0)
		for tick: int in range(save_at, SCRIPT_TICKS):
			var line: String = _scripted_tick(second_world, after, alice, ids, tick)
			if line != expected_trail[tick]:
				fail("saved at %d: tick %d is\n  %s\nthe run that went on has\n  %s" % [save_at, tick, line, expected_trail[tick]])
				break
		var actual_log: PackedStringArray = before.log.duplicate()
		actual_log.append_array(after.log)
		assert_eq(actual_log, expected_log, "saved at %d: the deciders are told the same in the same ticks" % save_at)
		assert_eq(_json(_states(second_world)), expected_states, "saved at %d: every NPC ends the same" % save_at)
		assert_eq(_json(_stage_document(second_world)), expected_stage, "saved at %d: the stage ends the same" % save_at)
	for kind: String in ["waiting_to_search", "mid_search", "mid_walk", "at_a_door", "in_a_doorway", "using", "asleep_busy", "out_of_memory", "reserved"]:
		assert_true(caught.has(kind), "a save point catches an NPC that is %s (caught: %s)" % [kind, ", ".join(PackedStringArray(caught.keys()))])


## The planning queue of the budget test, tick by tick: who waits in which
## order, how far every search is, and where everybody stands.
func _queue_tick(world: ServerWorld, recorder: Recorder, ids: PackedStringArray) -> String:
	_run(world, 1, recorder)
	var executor: NpcExecutor = recorder.executor()
	var line: PackedStringArray = [",".join(executor.queued_npc_ids())]
	for npc_id: String in ids:
		line.append("%s %s %d %s" % [npc_id, executor.phase_of(npc_id), int(_state_document(world, npc_id)[NpcExecutorState.KEY_PLAN_EXPANDED]), var_to_str(_position(world, npc_id))])
	return " | ".join(line)


func test_a_restored_planning_queue_keeps_its_order_and_every_search_its_progress() -> void:
	_exec.max_planning_nodes_per_tick = 24
	_exec.max_search_nodes_per_tick = 8
	_exec.max_plans_per_tick = 4
	var positions: Array[Vector3] = []
	for index: int in range(6):
		positions.append(Vector3(12.5, 0.0, 6.5 + 3.0 * float(index)))
	var ticks: int = 160
	# The run that goes on. Asked for in an order that is not the order of
	# the ids, so the queue's order is something only the save can know.
	var recorder: Recorder = Recorder.new()
	var started: Dictionary = _start(positions, recorder)
	var world: ServerWorld = started["world"]
	var ids: PackedStringArray = started["ids"]
	var order: PackedStringArray = [ids[3], ids[0], ids[5], ids[1], ids[4], ids[2]]
	_barrier(world, 15, -5, 28)
	for npc_id: String in order:
		assert_true(recorder.executor().begin_move(npc_id, _position(world, npc_id) + Vector3(5.0, 0.0, 0.0)).ok)
	var expected: PackedStringArray = []
	for tick: int in range(ticks):
		expected.append(_queue_tick(world, recorder, ids))
	assert_true(recorder.executor().queued_npc_ids().is_empty(), "every search of the script ends")
	for save_at: int in [0, 1, 2, 5, 11, 30]:
		var before: Recorder = Recorder.new()
		var first: Dictionary = _start(positions, before)
		var first_world: ServerWorld = first["world"]
		_barrier(first_world, 15, -5, 28)
		for npc_id: String in order:
			before.executor().begin_move(npc_id, _position(first_world, npc_id) + Vector3(5.0, 0.0, 0.0))
		for tick: int in range(save_at):
			_queue_tick(first_world, before, ids)
		var waiting: PackedStringArray = before.executor().queued_npc_ids()
		assert_true(waiting.size() >= 4, "saved at %d: more searches wait than a tick serves" % save_at)
		var documents: Dictionary = _json(first_world.to_documents())
		var after: Recorder = Recorder.new()
		after.tick = save_at
		var second_world: ServerWorld = _world(after)
		assert_eq(second_world.restore_documents(documents["world_state"], documents["players"], documents["cells"]).size(), 0)
		second_world.join("alice")
		for tick: int in range(save_at, ticks):
			var line: String = _queue_tick(second_world, after, ids)
			if line != expected[tick]:
				fail("saved at %d: tick %d is\n  %s\nthe run that went on has\n  %s" % [save_at, tick, line, expected[tick]])
				break
		assert_eq(after.log, recorder.log.slice(before.log.size()), "saved at %d: the deciders are told the same" % save_at)
		assert_eq(_json(_stage_document(second_world)), _json(_stage_document(world)), "saved at %d: the queue counter ends the same" % save_at)


func test_a_walk_saved_half_way_arrives_in_the_same_tick_without_planning_again() -> void:
	# The goes-on run.
	var started: Dictionary = _start([Vector3(13.5, 0.0, 13.25)])
	var world: ServerWorld = started["world"]
	var npc_id: String = started["ids"][0]
	_barrier(world, 15, 10, 16)
	var goal: Vector3 = Vector3(17.5, 0.0, 13.75)
	assert_true((started["executor"] as NpcExecutor).begin_move(npc_id, goal).ok)
	_run(world, 40)
	var documents: Dictionary = _json(world.to_documents())
	var ahead: Array = _json(_state_document(world, npc_id))[NpcExecutorState.KEY_WAYPOINTS]
	assert_true(ahead.size() >= 3, "it is half way: %d waypoints ahead" % ahead.size())
	assert_eq((started["executor"] as NpcExecutor).action_info(npc_id)[NpcExecutor.INFO_WAYPOINTS].size(), ahead.size())
	_until_told(world, npc_id, DONE)
	var arrival_tick: int = _recorder.tick_of(npc_id, DONE)
	# The restarted run.
	var after: Recorder = Recorder.new()
	after.tick = 40
	var second_world: ServerWorld = _world(after)
	assert_eq(second_world.restore_documents(documents["world_state"], documents["players"], documents["cells"]).size(), 0)
	second_world.join("alice")
	assert_eq(_json(_state_document(second_world, npc_id))[NpcExecutorState.KEY_WAYPOINTS], ahead, "the same waypoints are still ahead")
	for guard: int in range(2000):
		if after.told(npc_id).has(DONE):
			break
		_run(second_world, 1, after)
	assert_eq(after.tick_of(npc_id, DONE), arrival_tick, "it arrives in the same tick")
	assert_eq(_position(second_world, npc_id), goal)
	assert_eq(after.executor().total_search_count, 0, "and never planned again")


func test_what_is_saved_and_what_a_restore_refuses() -> void:
	var started: Dictionary = _start([Vector3(13.5, 0.0, 15.5)])
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	var npc_id: String = started["ids"][0]
	_house(world)
	assert_true(executor.begin_use_spot(npc_id, BED_IN, 3.0).ok)
	# 2 m to the door at 0.1 m a tick, then it stands in front of it.
	_run(world, 23)
	var document: Dictionary = _json(_state_document(world, npc_id))
	assert_true(SaveService.is_json_safe(_state_document(world, npc_id)))
	assert_eq(int(document[NpcComponent.KEY_SCHEMA_VERSION]), 1)
	assert_eq(str(document[NpcExecutorState.KEY_PHASE]), NpcExecutorState.PHASE_MOVING)
	assert_eq(str(document[NpcExecutorState.KEY_KIND]), NpcExecutorState.KIND_USE_SPOT)
	assert_eq(str(document[NpcExecutorState.KEY_SPOT]), BED_IN)
	assert_eq(str(document[NpcExecutorState.KEY_RESERVED_SPOT]), BED_IN)
	assert_eq(document[NpcExecutorState.KEY_RESERVATION_AUTO], true)
	assert_eq(int(document[NpcExecutorState.KEY_USE]), 3000000)
	assert_eq((document[NpcExecutorState.KEY_OPENED_DOORS] as Array).size(), 1, "the door it opened and still has to close")
	assert_true((document[NpcExecutorState.KEY_WAYPOINTS] as Array).size() >= 2)
	var stage: Dictionary = _json(_stage_document(world))
	assert_eq(int(stage[NpcExecutor.KEY_SCHEMA_VERSION]), 1)
	assert_eq(int(stage[NpcExecutor.KEY_NEXT_PLAN_SEQ]), 1)
	# A component restores what it wrote, and refuses what it did not.
	var copy: NpcExecutorState = NpcExecutorState.new()
	assert_eq(copy.restore_document(document).size(), 0)
	var written: Dictionary = copy.to_document()
	written[NpcComponent.KEY_SCHEMA_VERSION] = 1
	assert_eq(_json(written), document)
	var bad_values: Dictionary = {
		NpcExecutorState.KEY_PHASE: "flying",
		NpcExecutorState.KEY_KIND: 7,
		NpcExecutorState.KEY_TARGET: [1.0, 2.0],
		NpcExecutorState.KEY_RUN: "yes",
		NpcExecutorState.KEY_SPOT: "Bad Spot",
		NpcExecutorState.KEY_TARGET_ENTITY: 3,
		NpcExecutorState.KEY_WAYPOINTS: [[1.0, 2.0, "x"]],
		NpcExecutorState.KEY_TIMER: -2,
		NpcExecutorState.KEY_USE: 1.5,
		NpcExecutorState.KEY_PLAN_SEQ: -7,
		NpcExecutorState.KEY_PLAN_EXPANDED: -1,
		NpcExecutorState.KEY_REPLANS: "many",
		NpcExecutorState.KEY_OPENED_DOORS: [""],
		NpcExecutorState.KEY_RESERVED_SPOT: 5,
		NpcExecutorState.KEY_RESERVATION_AUTO: 1,
		NpcExecutorState.KEY_LAST_RESULT: "won",
		NpcExecutorState.KEY_LAST_CODE: "Bad Code",
	}
	for key: String in bad_values:
		var broken: Dictionary = document.duplicate(true)
		broken[key] = bad_values[key]
		var fresh: NpcExecutorState = NpcExecutorState.new()
		assert_true(fresh.restore_document(broken).size() > 0, "a bad %s is refused" % key)
		assert_eq(fresh.phase, NpcExecutorState.PHASE_IDLE, "and nothing of it is taken")
		var missing: Dictionary = document.duplicate(true)
		missing.erase(key)
		assert_true(NpcExecutorState.new().restore_document(missing).size() > 0, "a missing %s is refused" % key)
	var disagreeing: Dictionary = document.duplicate(true)
	disagreeing[NpcExecutorState.KEY_KIND] = NpcExecutorState.KIND_NONE
	assert_true(NpcExecutorState.new().restore_document(disagreeing).size() > 0, "phase and kind must agree")
	# The stage refuses a broken counter.
	for broken_stage: Dictionary in [{NpcExecutor.KEY_SCHEMA_VERSION: 2, NpcExecutor.KEY_NEXT_PLAN_SEQ: 1}, {NpcExecutor.KEY_SCHEMA_VERSION: 1, NpcExecutor.KEY_NEXT_PLAN_SEQ: -1}, {NpcExecutor.KEY_SCHEMA_VERSION: 1}]:
		assert_true(NpcExecutor.new(_exec).restore_world_document(broken_stage).size() > 0, str(broken_stage))
	# A save whose spot no longer exists: the action fails, nothing breaks.
	var documents: Dictionary = _json(world.to_documents())
	var after: Recorder = Recorder.new()
	var config: CompositionConfig = _config(after)
	config.npc_spots = NpcSpotSet.new()
	var second_world: ServerWorld = ServerComposition.create_world(WORLD, config)
	(second_world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	assert_eq(second_world.restore_documents(documents["world_state"], documents["players"], documents["cells"]).size(), 0)
	second_world.join("alice")
	_run(second_world, 3, after)
	assert_eq(after.told(npc_id), PackedStringArray([FAILED + NpcExecutor.FAIL_TARGET_GONE]))
	assert_false(after.executor().is_busy(npc_id))
	assert_eq(after.executor().reserved_spot_of(npc_id), "")
	var door: StructureInstance = _building(second_world).get_structure(str((document[NpcExecutorState.KEY_OPENED_DOORS] as Array)[0]))
	assert_false(door.door_open, "the door it had opened is closed")
