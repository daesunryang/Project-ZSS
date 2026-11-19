extends TestCase
## P4-5b: what the basic NPC actions do (docs/09 §17.8). Each action is
## begun through the contract the decision layer uses (NpcActionExecutor:
## begin / is_running / cancel) and watched from outside: where the NPC
## goes, what leaves the container, what happens to its needs, what the
## decision layer is told, what is saved. The decider here only writes down
## what it is told; the real decider with the real map is in
## npc_behaviour_day_test.gd. Server rules only, no nodes; ticks are
## stepped by hand. An hour of the calendar is 100 ticks here.

const WORLD: String = "npc_behaviour_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
const WALKER: String = "t45b_walker"
const WALL: String = "dev_wall"
const RATION: String = "dev_food_ration"
const SPEED: float = 2.0
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const HOUR_TICKS: int = 100
const ARRIVED: String = NpcActionExecutor.REPORT_ARRIVED
const DONE: String = NpcActionExecutor.REPORT_DONE
const FAILED: String = NpcActionExecutor.REPORT_FAILED_PREFIX

const PANTRY: String = "pantry"
const BARE_PANTRY: String = "bare_pantry"
const WELL: String = "well"
const BED: String = "bed"
const BENCH: String = "bench"
const PANTRY_TILE: Vector2i = Vector2i(2, 8)
const BARE_TILE: Vector2i = Vector2i(14, 2)
const WELL_TILE: Vector2i = Vector2i(8, 2)
const BED_TILE: Vector2i = Vector2i(3, 3)
const BENCH_TILE: Vector2i = Vector2i(10, 6)


## Writes down what the decision layer is told: "<tick> <npc> <reasons>".
class Recorder:
	extends NpcDecider
	var log: PackedStringArray = []
	var tick: int = 0
	var _executor: WeakRef = null
	var _behaviours: WeakRef = null

	func on_executor_attached(executor: NpcExecutor) -> void:
		_executor = weakref(executor)

	func on_behaviours_attached(behaviours: NpcBehaviours) -> void:
		_behaviours = weakref(behaviours)

	func executor() -> NpcExecutor:
		return _executor.get_ref() as NpcExecutor if _executor != null else null

	func behaviours() -> NpcBehaviours:
		return _behaviours.get_ref() as NpcBehaviours if _behaviours != null else null

	func decide(_world: ServerWorld, _npcs: NpcService, npc: NpcState, reasons: PackedStringArray, _from: NpcScheduler) -> void:
		var told_now: PackedStringArray = []
		for reason: String in reasons:
			if reason != NpcDecider.REASON_PERIOD:
				told_now.append(reason)
		if not told_now.is_empty():
			log.append("%d %s %s" % [tick, npc.npc_id, ",".join(told_now)])

	func told(npc_id: String) -> PackedStringArray:
		var reasons: PackedStringArray = []
		for line: String in log:
			if line.get_slice(" ", 1) == npc_id:
				reasons.append_array(line.get_slice(" ", 2).split(","))
		return reasons


## Writes down the stage's events: "<event> <npc> <action> [<code>]".
class Events:
	extends RefCounted
	var log: PackedStringArray = []
	var infos: Array[Dictionary] = []

	func watch(behaviours: NpcBehaviours) -> void:
		behaviours.behaviour_started.connect(func(npc_id: String, action_id: String, _info: Dictionary) -> void: log.append("started %s %s" % [npc_id, action_id]))
		behaviours.behaviour_finished.connect(func(npc_id: String, action_id: String, info: Dictionary) -> void:
			log.append("finished %s %s" % [npc_id, action_id])
			infos.append(info))
		behaviours.behaviour_failed.connect(func(npc_id: String, action_id: String, code: String) -> void: log.append("failed %s %s %s" % [npc_id, action_id, code]))
		behaviours.behaviour_cancelled.connect(func(npc_id: String, action_id: String) -> void: log.append("cancelled %s %s" % [npc_id, action_id]))


var _cell_settings: WorldCellSettings = null
var _exec: NpcExecutorSettings = null
var _behaviour: NpcBehaviourSettings = null
var _recorder: Recorder = null
var _events: Events = null
var _actions: NpcActionCatalog = null


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
	_exec.max_planning_nodes_per_tick = 100000
	_exec.max_search_nodes_per_tick = 100000
	_exec.max_plans_per_tick = 100
	_exec.min_replan_interval_sec = 0.2
	_exec.door_pause_sec = 0.2
	_behaviour = NpcBehaviourSettings.new()
	_behaviour.inventory_slots = 2
	_behaviour.eat_duration_sec = 1.0
	_behaviour.drink_duration_sec = 0.5
	_behaviour.drink_thirst_reduction = 30.0
	_behaviour.rest_until_fatigue = 5.0
	_behaviour.rest_check_period_sec = 0.5
	_behaviour.work_shift_sec = 3.0
	_behaviour.wander_radius_m = 4.0
	_behaviour.wander_linger_sec = 0.5
	_behaviour.flee_distance_m = 6.0
	_recorder = Recorder.new()
	_events = Events.new()
	_actions = NpcActionCatalog.load_directory()


func after_each() -> void:
	GameLogger.set_capture(false)
	_recorder = null
	_events = null


# ------------------------------------------------------------ helpers

func _spot(spot_id: String, kind: String, tile: Vector2i, exclusive: bool = true, stock_units: int = 0) -> NpcSpotDefinition:
	var spot: NpcSpotDefinition = NpcSpotDefinition.new()
	spot.spot_id = spot_id
	spot.kind = kind
	spot.tile_offset = tile
	spot.exclusive = exclusive
	if stock_units > 0:
		spot.stock_item_id = RATION
		spot.stock_units = stock_units
	return spot


func _spots() -> NpcSpotSet:
	var spots: NpcSpotSet = NpcSpotSet.new()
	spots.spot_set_id = "t45b_spots"
	spots.spots = [
		_spot(PANTRY, NpcSpotDefinition.KIND_FOOD, PANTRY_TILE, false, 3),
		_spot(BARE_PANTRY, NpcSpotDefinition.KIND_FOOD, BARE_TILE, false),
		_spot(WELL, NpcSpotDefinition.KIND_WATER, WELL_TILE),
		_spot(BED, NpcSpotDefinition.KIND_BED, BED_TILE),
		_spot(BENCH, NpcSpotDefinition.KIND_WORK, BENCH_TILE),
	]
	return spots


func _config(recorder: Recorder, spots: NpcSpotSet = null) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	# One calendar hour = 5 real seconds = 100 ticks.
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = 720.0
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
	config.npc_behaviour = _behaviour
	config.npc_spots = spots if spots != null else _spots()
	return config


func _world(recorder: Recorder = null, spots: NpcSpotSet = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config(recorder if recorder != null else _recorder, spots))
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	return world


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _containers(world: ServerWorld) -> ContainerService:
	return world.get_system(ContainerService.SYSTEM_ID) as ContainerService


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


func _tile_centre(tile: Vector2i) -> Vector3:
	return Vector3(float(tile.x) + 0.5, 0.0, float(tile.y) + 0.5)


## A container on a tile (its loot table is none: it starts empty and
## counts as searched). Returns it.
func _cabinet(world: ServerWorld, tile: Vector2i) -> ContainerInstance:
	var created: ActionResult = _containers(world).create_container(world, "dev_storage_box_container", _tile_centre(tile))
	if not created.ok:
		fail("test setup: container refused: " + created.reason)
		return null
	return _containers(world).get_container(str(created.event[ContainerInstance.KEY_CONTAINER_ID]))


## A world with a player at SPAWN, NPCs at `positions`, and a container on
## each food spot.
func _start(positions: Array[Vector3], recorder: Recorder = null) -> Dictionary:
	var used: Recorder = recorder if recorder != null else _recorder
	var world: ServerWorld = _world(used)
	var alice: PlayerState = world.join("alice")
	world.step_systems(TICK)
	var ids: PackedStringArray = []
	for position: Vector3 in positions:
		ids.append(_spawn(world, position))
	var pantry: ContainerInstance = _cabinet(world, PANTRY_TILE)
	var bare: ContainerInstance = _cabinet(world, BARE_TILE)
	if used == _recorder:
		_events.watch(used.behaviours())
	return {"world": world, "alice": alice, "ids": ids, "behaviours": used.behaviours(), "executor": used.executor(), "pantry": pantry, "bare": bare}


func _begin(started: Dictionary, npc_id: String, action_id: String, target: Dictionary = {}) -> String:
	var world: ServerWorld = started["world"]
	var behaviours: NpcBehaviours = started["behaviours"]
	return behaviours.action_executor().begin(world, _npcs(world), _npcs(world).get_npc(npc_id), _actions.get_action(action_id), target)


func _cancel(started: Dictionary, npc_id: String) -> void:
	var world: ServerWorld = started["world"]
	(started["behaviours"] as NpcBehaviours).action_executor().cancel(world, _npcs(world), _npcs(world).get_npc(npc_id))


func _needs(world: ServerWorld, npc_id: String) -> NpcNeeds:
	return _npcs(world).get_npc(npc_id).component(NpcNeeds.COMPONENT_ID) as NpcNeeds


## The NPC's need, brought up to now.
func _need(world: ServerWorld, npc_id: String, kind: String) -> float:
	var needs: NpcNeeds = _needs(world, npc_id)
	needs.advance_to(maxf(world.clock.world_time_sec, needs.last_updated_world_time()))
	return needs.value(kind)


func _state(world: ServerWorld, npc_id: String) -> NpcBehaviourState:
	return _npcs(world).get_npc(npc_id).component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState


func _position(world: ServerWorld, npc_id: String) -> Vector3:
	return _npcs(world).get_npc(npc_id).position


## Units of an item in an inventory.
func _units(world: ServerWorld, inventory_id: String, definition_id: String = RATION) -> int:
	var total: int = 0
	for item: ItemInstance in world.inventory.items_in_inventory(inventory_id):
		if item.definition_id == definition_id:
			total += item.quantity
	return total


func _until_told(world: ServerWorld, npc_id: String, reason: String, limit: int = 3000) -> int:
	for guard: int in range(limit):
		if _recorder.told(npc_id).has(reason):
			return guard
		_run(world, 1)
	fail("%s was never told %s (told: %s)" % [npc_id, reason, ",".join(_recorder.told(npc_id))])
	return limit


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


func _document(world: ServerWorld, npc_id: String) -> Dictionary:
	return ((_npcs(world).npc_document(npc_id)[NpcState.KEY_COMPONENTS] as Dictionary).get(NpcBehaviourState.COMPONENT_ID, {}) as Dictionary)


func _stage_document(world: ServerWorld) -> Dictionary:
	var npc_part: Dictionary = (world.to_documents()["world_state"]["systems"] as Dictionary).get(NpcService.SYSTEM_ID, {})
	return (npc_part.get(NpcService.KEY_STAGES, {}) as Dictionary).get(NpcBehaviours.STAGE_ID, {})


# ------------------------------------------------------------ data

func test_the_shipped_settings_and_stock_are_valid_and_bad_ones_are_refused() -> void:
	assert_true(ResourceLoader.exists(NpcBehaviourSettings.DEFAULT_PATH))
	var shipped: NpcBehaviourSettings = NpcBehaviourSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.map_content = MapContentDefinition.load_or_null()
	config.npc_roster = NpcRoster.load_or_null()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	# Every action the decision layer can choose is one this stage runs.
	for action_id: String in NpcActionCatalog.load_directory().action_ids():
		assert_true(NpcBehaviours.ACTIONS.has(action_id), "%s is a behaviour" % action_id)
	# The food containers of the test map are stocked with food.
	var spots: NpcSpotSet = NpcSpotSet.load_or_null()
	for spot_id: String in spots.spot_ids(NpcSpotDefinition.KIND_FOOD):
		var spot: NpcSpotDefinition = spots.get_spot(spot_id)
		assert_true(spot.stock_units > 0, "%s is stocked" % spot_id)
		assert_true(config.catalog.get_definition(spot.stock_item_id).consume_hunger_reduction > 0.0)
	var bad: NpcBehaviourSettings = NpcBehaviourSettings.new()
	bad.inventory_slots = 0
	bad.eat_duration_sec = -1.0
	bad.drink_thirst_reduction = NAN
	bad.rest_check_period_sec = 0.0
	bad.work_shift_sec = 0.0
	bad.wander_radius_m = 0.0
	bad.flee_distance_m = -2.0
	assert_eq(bad.validate().size(), 7, "; ".join(bad.validate()))
	# Bad stock data.
	var bed_with_stock: NpcSpotDefinition = _spot("stocked_bed", NpcSpotDefinition.KIND_BED, Vector2i(1, 1), true, 2)
	assert_eq(bed_with_stock.validate().size(), 1, "only food spots are stocked")
	var half: NpcSpotDefinition = _spot("half", NpcSpotDefinition.KIND_FOOD, Vector2i(1, 2), false)
	half.stock_units = 4
	assert_eq(half.validate().size(), 1, "units without an item")
	var not_food: NpcSpotSet = NpcSpotSet.new()
	not_food.spot_set_id = "not_food"
	var nails: NpcSpotDefinition = _spot("nails", NpcSpotDefinition.KIND_FOOD, Vector2i(1, 3), false, 2)
	nails.stock_item_id = "dev_nails"
	nails.building_id = ""
	not_food.spots = [nails]
	var errors: PackedStringArray = not_food.validate_against(null, StructureGrid.new(1.0), 50.0, config.catalog)
	assert_true("; ".join(errors).contains("must be food"), "; ".join(errors))


# ------------------------------------------------------------ eating

func test_eating_takes_one_unit_from_the_container_and_lowers_hunger() -> void:
	var started: Dictionary = _start([Vector3(3.5, 0.0, 5.5)])
	var world: ServerWorld = started["world"]
	var behaviours: NpcBehaviours = started["behaviours"]
	var pantry: ContainerInstance = started["pantry"]
	var npc_id: String = started["ids"][0]
	var state: NpcBehaviourState = _state(world, npc_id)
	assert_true(world.inventory.is_detached_inventory(state.inventory_id), "the NPC has an inventory of its own")
	# 24 calendar hours: hunger 50.
	_run(world, 24 * HOUR_TICKS)
	var hungry: float = _need(world, npc_id, NpcNeedKind.HUNGER)
	assert_true(is_equal_approx(hungry, 50.0), "hunger after a day: %f" % hungry)
	assert_false(behaviours.is_stocked(PANTRY))
	assert_eq(_units(world, pantry.inventory_id), 0, "the container is not stocked before anybody comes to eat")
	assert_eq(_begin(started, npc_id, NpcBehaviours.ACTION_EAT), "")
	assert_true(behaviours.action_executor().is_running(npc_id))
	assert_eq(state.step, NpcBehaviourState.STEP_GOING)
	assert_eq(state.spot_id, PANTRY, "the nearer food spot")
	_until_told(world, npc_id, ARRIVED)
	assert_eq(_position(world, npc_id), _tile_centre(PANTRY_TILE), "it stands at the container")
	assert_true(behaviours.is_stocked(PANTRY))
	assert_eq(_units(world, pantry.inventory_id), 2, "three units were stocked and one was taken")
	assert_eq(_units(world, state.inventory_id), 1, "into the NPC's inventory")
	assert_eq(state.step, NpcBehaviourState.STEP_PERFORMING)
	var before_done: float = _need(world, npc_id, NpcNeedKind.HUNGER)
	var arrived_tick: int = _recorder.tick
	_until_told(world, npc_id, DONE)
	# eat_duration_sec 1.0 = 20 ticks.
	assert_eq(_recorder.tick - arrived_tick, 20)
	assert_eq(_units(world, state.inventory_id), 0, "the unit is used up")
	assert_eq(_units(world, pantry.inventory_id), 2)
	var fed: float = _need(world, npc_id, NpcNeedKind.HUNGER)
	assert_true(fed < before_done - 39.0 and fed < 12.0, "the ration takes 40 off: %f -> %f" % [before_done, fed])
	assert_false(behaviours.action_executor().is_running(npc_id))
	assert_eq(state.count_of(NpcBehaviours.ACTION_EAT), 1)
	assert_eq(_recorder.told(npc_id), PackedStringArray([ARRIVED, DONE]))
	assert_eq(_events.log, PackedStringArray(["started %s eat" % npc_id, "finished %s eat" % npc_id]))
	assert_eq(str(_events.infos[0][NpcBehaviours.INFO_ITEM]), RATION)
	# The stock is given once: eating again takes from what is left.
	_recorder.log.clear()
	assert_eq(_begin(started, npc_id, NpcBehaviours.ACTION_EAT), "")
	_until_told(world, npc_id, DONE)
	assert_eq(_units(world, pantry.inventory_id), 1)
	assert_eq(behaviours.stocked_count, 1)
	assert_eq(_json(_stage_document(world)), {"schema_version": 1.0, "stocked": [PANTRY]})


func test_eating_fails_without_food_and_an_npc_that_carries_food_eats_it() -> void:
	var started: Dictionary = _start([Vector3(13.5, 0.0, 3.5), Vector3(3.5, 0.0, 5.5)])
	var world: ServerWorld = started["world"]
	var behaviours: NpcBehaviours = started["behaviours"]
	var pantry: ContainerInstance = started["pantry"]
	var far: String = started["ids"][0]
	var near: String = started["ids"][1]
	_run(world, 12 * HOUR_TICKS)
	# The nearest food spot of the first NPC is the bare one: its container
	# is in memory and empty, so it sets out for the other one.
	assert_eq(_begin(started, far, NpcBehaviours.ACTION_EAT), "")
	assert_eq(_state(world, far).spot_id, PANTRY, "not the container that is known to be empty")
	_cancel(started, far)
	# Food that is gone when the NPC arrives: it fails there.
	assert_eq(_begin(started, near, NpcBehaviours.ACTION_EAT), "")
	_run(world, 5)
	behaviours._stock(world, _npcs(world), PANTRY)
	for item: ItemInstance in world.inventory.items_in_inventory(pantry.inventory_id):
		assert_true(world.inventory.remove_item(pantry.inventory_id, item.item_instance_id, item.quantity).ok)
	_until_told(world, near, FAILED + NpcActionExecutor.FAIL_NO_RESOURCE)
	assert_false(behaviours.action_executor().is_running(near))
	assert_false((started["executor"] as NpcExecutor).is_busy(near), "the movement executor let go too")
	assert_eq(_state(world, near).count_of(NpcBehaviourState.COUNT_FAILED), 1)
	assert_true(_events.log.has("failed %s eat no_resource" % near))
	assert_eq(_recorder.told(near), PackedStringArray([FAILED + NpcActionExecutor.FAIL_NO_RESOURCE]), "it never said it arrived")
	# Now every container is known to be empty: nobody even sets out.
	assert_eq(_begin(started, far, NpcBehaviours.ACTION_EAT), NpcActionExecutor.FAIL_NO_RESOURCE)
	assert_false(behaviours.action_executor().is_running(far))
	assert_eq(_recorder.told(far).size(), 0, "a refusal is an answer, not a report")
	# An eating that is cut short leaves the unit with the NPC.
	assert_false(world.inventory.spawn_detached_item(pantry.inventory_id, RATION, 2).is_empty())
	_recorder.log.clear()
	assert_eq(_begin(started, near, NpcBehaviours.ACTION_EAT), "")
	_until_told(world, near, ARRIVED)
	_run(world, 3)
	_cancel(started, near)
	var state: NpcBehaviourState = _state(world, near)
	assert_false(state.is_running())
	assert_eq(_units(world, state.inventory_id), 1, "it keeps what it took")
	assert_eq(_units(world, pantry.inventory_id), 1)
	assert_eq(_events.log[_events.log.size() - 1], "cancelled %s eat" % near)
	# Next time it eats what it carries, where it stands.
	_run(world, 5)
	_recorder.log.clear()
	var hunger_before: float = _need(world, near, NpcNeedKind.HUNGER)
	var stood: Vector3 = _position(world, near)
	assert_eq(_begin(started, near, NpcBehaviours.ACTION_EAT), "")
	assert_eq(state.spot_id, "")
	_until_told(world, near, DONE)
	assert_eq(_position(world, near), stood, "no way to go")
	assert_eq(_units(world, state.inventory_id), 0)
	assert_eq(_units(world, pantry.inventory_id), 1, "nothing more left the container")
	assert_true(_need(world, near, NpcNeedKind.HUNGER) < hunger_before)
	assert_eq(_recorder.told(near), PackedStringArray([ARRIVED, DONE]))


# ------------------------------------------------------------ drinking, resting, working

func test_drinking_lowers_thirst_at_a_water_spot_one_npc_at_a_time() -> void:
	var started: Dictionary = _start([Vector3(7.5, 0.0, 4.5), Vector3(9.5, 0.0, 4.5)])
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	var first: String = started["ids"][0]
	var second: String = started["ids"][1]
	# 12 calendar hours: thirst 50.
	_run(world, 12 * HOUR_TICKS)
	var thirsty: float = _need(world, first, NpcNeedKind.THIRST)
	assert_true(is_equal_approx(thirsty, 50.0), "thirst after half a day: %f" % thirsty)
	assert_eq(_begin(started, first, NpcBehaviours.ACTION_DRINK), "")
	assert_eq(executor.holder_of(WELL), first, "the water spot is its own while it drinks")
	assert_eq(_begin(started, second, NpcBehaviours.ACTION_DRINK), NpcActionExecutor.FAIL_RESERVED, "the only water spot is taken")
	_until_told(world, first, ARRIVED)
	assert_eq(_position(world, first), _tile_centre(WELL_TILE))
	var arrived_tick: int = _recorder.tick
	_until_told(world, first, DONE)
	# drink_duration_sec 0.5 = 10 ticks.
	assert_eq(_recorder.tick - arrived_tick, 10)
	var after: float = _need(world, first, NpcNeedKind.THIRST)
	assert_true(after > thirsty - 30.0 and after < thirsty - 28.0, "30 off (and a little thirst while it walked): %f -> %f" % [thirsty, after])
	assert_eq(executor.holder_of(WELL), "", "the spot is free again")
	assert_eq(_state(world, first).count_of(NpcBehaviours.ACTION_DRINK), 1)
	assert_eq(_begin(started, second, NpcBehaviours.ACTION_DRINK), "")
	_until_told(world, second, DONE)
	assert_eq(_events.log, PackedStringArray(["started %s drink" % first, "finished %s drink" % first, "started %s drink" % second, "finished %s drink" % second]))


func test_resting_lowers_fatigue_until_the_npc_gets_up_by_itself() -> void:
	var started: Dictionary = _start([Vector3(5.5, 0.0, 3.5), Vector3(6.5, 0.0, 8.5)])
	var world: ServerWorld = started["world"]
	var executor: NpcExecutor = started["executor"]
	var sleeper: String = started["ids"][0]
	var other: String = started["ids"][1]
	# 9 calendar hours: fatigue 50.
	_run(world, 9 * HOUR_TICKS)
	var tired: float = _need(world, sleeper, NpcNeedKind.FATIGUE)
	assert_true(is_equal_approx(tired, 50.0), "fatigue after nine hours: %f" % tired)
	assert_eq(_begin(started, sleeper, NpcBehaviours.ACTION_REST), "")
	assert_eq(_needs(world, sleeper).activity(), NpcNeedKind.IDLE, "not resting before it lies down")
	_until_told(world, sleeper, ARRIVED)
	assert_eq(_position(world, sleeper), _tile_centre(BED_TILE))
	assert_eq(_needs(world, sleeper).activity(), NpcNeedKind.RESTING)
	assert_eq(executor.holder_of(BED), sleeper)
	_run(world, 50)
	var resting: float = _need(world, sleeper, NpcNeedKind.FATIGUE)
	assert_true(resting < tired - 10.0, "half an hour in bed: %f -> %f" % [tired, resting])
	assert_false(_recorder.told(sleeper).has(DONE))
	# The second NPC finds the bed taken and rests where it stands.
	var stood: Vector3 = _position(world, other)
	assert_eq(_begin(started, other, NpcBehaviours.ACTION_REST), "")
	_run(world, 2)
	assert_eq(_recorder.told(other), PackedStringArray([ARRIVED]), "no way to go: it rests at once")
	assert_eq(_needs(world, other).activity(), NpcNeedKind.RESTING)
	assert_eq(_position(world, other), stood)
	# The sleeper gets up when its fatigue is low enough: 3.2 hours from 100
	# to 0, so about 1.4 more hours from 45.
	_until_told(world, sleeper, DONE, 400)
	var rested: float = _need(world, sleeper, NpcNeedKind.FATIGUE)
	assert_true(rested <= _behaviour.rest_until_fatigue + 0.5 and rested > 0.0, "it got up at %f" % rested)
	assert_eq(_needs(world, sleeper).activity(), NpcNeedKind.IDLE)
	assert_eq(executor.holder_of(BED), "", "the bed is free")
	assert_false(executor.is_busy(sleeper))
	assert_eq(_state(world, sleeper).count_of(NpcBehaviours.ACTION_REST), 1)
	# Cancelling (a flee interrupt) wakes it at once.
	_cancel(started, other)
	assert_eq(_needs(world, other).activity(), NpcNeedKind.IDLE)
	assert_false((started["behaviours"] as NpcBehaviours).action_executor().is_running(other))
	_run(world, 40)
	assert_false(_recorder.told(other).has(DONE), "a cancelled action reports nothing")


func test_working_counts_the_time_at_the_work_place() -> void:
	var started: Dictionary = _start([Vector3(8.5, 0.0, 6.5)])
	var world: ServerWorld = started["world"]
	var npc_id: String = started["ids"][0]
	var state: NpcBehaviourState = _state(world, npc_id)
	assert_eq(_begin(started, npc_id, NpcBehaviours.ACTION_WORK), "")
	_run(world, 3)
	assert_eq(_needs(world, npc_id).activity(), NpcNeedKind.IDLE, "walking is not working")
	assert_eq(state.worked_usec, 0)
	_until_told(world, npc_id, ARRIVED)
	assert_eq(_position(world, npc_id), _tile_centre(BENCH_TILE))
	assert_eq(_needs(world, npc_id).activity(), NpcNeedKind.WORKING)
	_until_told(world, npc_id, DONE)
	assert_eq(state.worked_usec, 3000000, "one shift of work_shift_sec")
	assert_eq(state.count_of(NpcBehaviours.ACTION_WORK), 1)
	assert_eq(_needs(world, npc_id).activity(), NpcNeedKind.IDLE)
	assert_eq(int(_events.infos[0][NpcBehaviours.INFO_WORKED]), 3000000)
	# Work that is cut short still counts for the time it lasted.
	_recorder.log.clear()
	assert_eq(_begin(started, npc_id, NpcBehaviours.ACTION_WORK), "")
	_until_told(world, npc_id, ARRIVED)
	_run(world, 10)
	_cancel(started, npc_id)
	assert_eq(_needs(world, npc_id).activity(), NpcNeedKind.IDLE)
	assert_true(state.worked_usec > 3000000 and state.worked_usec < 4000000, "%d" % state.worked_usec)
	assert_eq(state.count_of(NpcBehaviours.ACTION_WORK), 1, "only a whole shift counts as one")
	assert_eq(state.count_of("work_cut"), 1, "the one that was cut short is counted apart")


# ------------------------------------------------------------ wandering, fleeing

func test_wandering_goes_somewhere_near_and_fleeing_runs_away_from_the_threat() -> void:
	var started: Dictionary = _start([Vector3(-12.5, 0.0, -12.5), Vector3(-12.5, 0.0, 12.5)])
	var world: ServerWorld = started["world"]
	var wanderer: String = started["ids"][0]
	var runner: String = started["ids"][1]
	var npc: NpcState = _npcs(world).get_npc(wanderer)
	var from: Vector3 = npc.position
	var twin: RandomNumberGenerator = RandomNumberGenerator.new()
	twin.seed = npc.rng.seed
	twin.state = npc.rng.state
	assert_eq(_begin(started, wanderer, NpcBehaviours.ACTION_WANDER), "")
	twin.randf()
	twin.randf()
	assert_eq(npc.rng.state, twin.state, "two numbers of the NPC's own generator, no more")
	var goal: Vector3 = (started["executor"] as NpcExecutor).action_info(wanderer)[NpcExecutor.INFO_TARGET]
	assert_true(goal.distance_to(from) <= _behaviour.wander_radius_m + 0.001, "within the radius: %f" % goal.distance_to(from))
	assert_ne(goal, from)
	var ticks: int = _until_told(world, wanderer, DONE)
	assert_eq(_position(world, wanderer), goal)
	assert_false(_recorder.told(wanderer).has(ARRIVED), "a wander is over when the NPC is there")
	# wander_linger_sec 0.5 = 10 ticks on top of the walk.
	assert_true(ticks >= 10 + ceili(goal.distance_to(from) / (SPEED * TICK)), "it stood there a while: %d ticks" % ticks)
	assert_eq(_state(world, wanderer).count_of(NpcBehaviours.ACTION_WANDER), 1)
	# Fleeing: straight away from the threat, running.
	var stood: Vector3 = _position(world, runner)
	var threat: Vector3 = stood + Vector3(3.0, 0.0, 0.0)
	var target: Dictionary = {NpcActionExecutor.TARGET_THREAT_ID: "zombie_000001", NpcActionExecutor.TARGET_THREAT_POSITION: [threat.x, threat.y, threat.z]}
	assert_eq(_begin(started, runner, NpcBehaviours.ACTION_FLEE, target), "")
	_run(world, 3)
	var early: Vector3 = _position(world, runner)
	_run(world, 1)
	assert_true(is_equal_approx(early.distance_to(_position(world, runner)), 2.0 * SPEED * TICK), "a running step")
	_until_told(world, runner, DONE)
	var fled: Vector3 = _position(world, runner)
	assert_true(is_equal_approx(fled.x, stood.x - _behaviour.flee_distance_m) and is_equal_approx(fled.z, stood.z), "6 m straight away: %s" % str(fled))
	assert_eq(_state(world, runner).count_of(NpcBehaviours.ACTION_FLEE), 1)
	# What is not a behaviour, and who cannot act.
	var unknown: NpcActionDefinition = NpcActionDefinition.new()
	unknown.action_id = "juggle"
	var behaviours: NpcBehaviours = started["behaviours"]
	assert_eq(behaviours.action_executor().begin(world, _npcs(world), _npcs(world).get_npc(runner), unknown, {}), NpcActionExecutor.FAIL_UNSUPPORTED)
	(started["alice"] as PlayerState).position = Vector3(45.5, 0.0, 45.5)
	_run(world, 2)
	assert_false(_npcs(world).is_awake(runner))
	assert_eq(_begin(started, runner, NpcBehaviours.ACTION_WANDER), NpcBehaviours.FAIL_NOT_READY)


func test_a_world_without_spots_has_nowhere_to_go_but_rest_and_wander_still_work() -> void:
	var empty: NpcSpotSet = NpcSpotSet.new()
	empty.spot_set_id = "no_spots"
	var world: ServerWorld = _world(_recorder, empty)
	world.join("alice")
	world.step_systems(TICK)
	var npc_id: String = _spawn(world, Vector3(3.5, 0.0, 3.5))
	var started: Dictionary = {"world": world, "behaviours": _recorder.behaviours()}
	for action_id: String in [NpcBehaviours.ACTION_EAT, NpcBehaviours.ACTION_DRINK, NpcBehaviours.ACTION_WORK]:
		assert_eq(_begin(started, npc_id, action_id), NpcActionExecutor.FAIL_TARGET_GONE, "%s has no place" % action_id)
	assert_eq(_begin(started, npc_id, NpcBehaviours.ACTION_REST), "", "resting needs no bed")
	assert_eq(_needs(world, npc_id).activity(), NpcNeedKind.RESTING)
	_cancel(started, npc_id)
	assert_eq(_begin(started, npc_id, NpcBehaviours.ACTION_WANDER), "")
	_until_told(world, npc_id, DONE)


# ------------------------------------------------------------ the movement executor's failures

func test_a_way_that_cannot_be_found_fails_the_behaviour_with_no_path() -> void:
	var started: Dictionary = _start([Vector3(9.5, 0.0, 9.5)])
	var world: ServerWorld = started["world"]
	var npc_id: String = started["ids"][0]
	# The bench is walled in.
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	for rotation: int in range(4):
		var placed: ActionResult = building.place_structure(world, WALL, BENCH_TILE, rotation)
		assert_true(placed.ok and building.complete_structure(world, str(placed.event[BuildingService.KEY_STRUCTURE_ID])).ok)
	assert_eq(_begin(started, npc_id, NpcBehaviours.ACTION_WORK), "")
	_until_told(world, npc_id, FAILED + NpcActionExecutor.FAIL_NO_PATH)
	assert_false((started["behaviours"] as NpcBehaviours).action_executor().is_running(npc_id))
	assert_eq((started["executor"] as NpcExecutor).holder_of(BENCH), "", "the spot is free again")
	assert_eq(_needs(world, npc_id).activity(), NpcNeedKind.IDLE)
	assert_eq(_events.log, PackedStringArray(["started %s work" % npc_id, "failed %s work no_path" % npc_id]))
	# What the movement executor does for somebody else is passed on as it is.
	_recorder.log.clear()
	assert_true((started["executor"] as NpcExecutor).begin_move(npc_id, Vector3(8.5, 0.0, 9.5)).ok)
	_until_told(world, npc_id, NpcExecutor.INTERRUPT_DONE)
	assert_eq(_events.log.size(), 2, "not a behaviour: no event")


# ------------------------------------------------------------ save

func test_what_is_saved_is_whole_numbers_and_survives_a_text_round_trip_bit_for_bit() -> void:
	var started: Dictionary = _start([Vector3(3.5, 0.0, 5.5)])
	var world: ServerWorld = started["world"]
	var npc_id: String = started["ids"][0]
	_run(world, 12 * HOUR_TICKS)
	assert_eq(_begin(started, npc_id, NpcBehaviours.ACTION_WORK), "")
	_until_told(world, npc_id, DONE)
	_recorder.log.clear()
	assert_eq(_begin(started, npc_id, NpcBehaviours.ACTION_EAT), "")
	_until_told(world, npc_id, ARRIVED)
	_run(world, 7)
	var document: Dictionary = _document(world, npc_id)
	assert_true(SaveService.is_json_safe(document))
	var text: String = JSON.stringify(document)
	var read: Dictionary = JSON.parse_string(text) as Dictionary
	# Text -> values -> text -> values: nothing moves (the first text writes
	# whole numbers as "1", every later one as "1.0": the same numbers).
	var second_text: String = JSON.stringify(read)
	assert_eq(JSON.stringify(JSON.parse_string(second_text)), second_text, "the document's text reads back to the same text")
	assert_eq(JSON.parse_string(second_text), read)
	for key: String in [NpcBehaviourState.KEY_TIMER, NpcBehaviourState.KEY_WORKED]:
		assert_eq(int(read[key]), int(document[key]), "%s is the same whole number" % key)
	assert_eq(str(read[NpcBehaviourState.KEY_ACTION_ID]), NpcBehaviours.ACTION_EAT)
	assert_eq(str(read[NpcBehaviourState.KEY_STEP]), NpcBehaviourState.STEP_PERFORMING)
	assert_eq(str(read[NpcBehaviourState.KEY_SPOT]), PANTRY)
	assert_eq(int(read[NpcBehaviourState.KEY_WORKED]), 3000000)
	assert_eq(read[NpcBehaviourState.KEY_COUNTS], {"work": 1.0})
	assert_eq((read[NpcBehaviourState.KEY_ITEMS] as Array).size(), 1, "the unit it is eating")
	# Every number of the document is a whole number (the item's own floats
	# are the inventory's business and are 1.0 here).
	for key: String in [NpcBehaviourState.KEY_TIMER, NpcBehaviourState.KEY_WORKED, NpcComponent.KEY_SCHEMA_VERSION]:
		assert_true(ItemInstance.is_integer_value(read[key]), key)
	# A component restores what it wrote, and writes the same again.
	var copy: NpcBehaviourState = NpcBehaviourState.new(_behaviour)
	assert_eq(copy.restore_document(read).size(), 0)
	var written: Dictionary = copy.to_document()
	written[NpcComponent.KEY_SCHEMA_VERSION] = 1
	assert_eq(JSON.stringify(_json(written)), JSON.stringify(read))
	# What it refuses.
	var bad_values: Dictionary = {
		NpcComponent.KEY_SCHEMA_VERSION: 2,
		NpcBehaviourState.KEY_ACTION_ID: "Bad Action",
		NpcBehaviourState.KEY_STEP: "flying",
		NpcBehaviourState.KEY_TIMER: -2,
		NpcBehaviourState.KEY_SPOT: 7,
		NpcBehaviourState.KEY_COUNTS: {"eat": -1},
		NpcBehaviourState.KEY_WORKED: 1.5,
		NpcBehaviourState.KEY_INVENTORY_ID: 3,
		NpcBehaviourState.KEY_ITEMS: [{"not": "an item"}],
	}
	for key: String in bad_values:
		var broken: Dictionary = read.duplicate(true)
		broken[key] = bad_values[key]
		var fresh: NpcBehaviourState = NpcBehaviourState.new(_behaviour)
		assert_true(fresh.restore_document(broken).size() > 0, "a bad %s is refused" % key)
		assert_eq(fresh.action_id, "", "and nothing of it is taken")
		var missing: Dictionary = read.duplicate(true)
		missing.erase(key)
		assert_true(NpcBehaviourState.new(_behaviour).restore_document(missing).size() > 0, "a missing %s is refused" % key)
	var disagreeing: Dictionary = read.duplicate(true)
	disagreeing[NpcBehaviourState.KEY_STEP] = ""
	assert_true(NpcBehaviourState.new(_behaviour).restore_document(disagreeing).size() > 0)
	for broken_stage: Dictionary in [{"schema_version": 2, "stocked": []}, {"schema_version": 1, "stocked": "pantry"}, {"schema_version": 1, "stocked": ["Bad Spot"]}, {"schema_version": 1}]:
		assert_true(NpcBehaviours.new(_behaviour).restore_world_document(broken_stage).size() > 0, str(broken_stage))


func test_an_action_and_what_the_npc_carries_survive_a_restart_and_a_cell_unload() -> void:
	# The run that goes on: eat (cut short), then eat what it carries.
	var started: Dictionary = _start([Vector3(3.5, 0.0, 5.5)])
	var world: ServerWorld = started["world"]
	var npc_id: String = started["ids"][0]
	_run(world, 12 * HOUR_TICKS)
	assert_eq(_begin(started, npc_id, NpcBehaviours.ACTION_EAT), "")
	_until_told(world, npc_id, ARRIVED)
	_run(world, 7)
	var carried: ItemInstance = _state(world, npc_id).carried_items()[0]
	var item_id: String = carried.item_instance_id
	var inventory_id: String = _state(world, npc_id).inventory_id
	var documents: Dictionary = _json(world.to_documents())
	var saved: Dictionary = _json(_document(world, npc_id))
	_until_told(world, npc_id, DONE)
	var expected: Dictionary = _json(_document(world, npc_id))
	var expected_hunger: float = _needs(world, npc_id).value(NpcNeedKind.HUNGER)
	# The restarted run.
	var after: Recorder = Recorder.new()
	var second: ServerWorld = _world(after)
	assert_eq(second.restore_documents(documents["world_state"], documents["players"], documents["cells"]).size(), 0)
	second.join("alice")
	assert_eq(_json(_document(second, npc_id)), saved, "restored as it was saved")
	var state: NpcBehaviourState = _state(second, npc_id)
	assert_eq(state.inventory_id, inventory_id)
	assert_eq(state.carried_items().size(), 1)
	assert_eq(state.carried_items()[0].item_instance_id, item_id, "the very unit it carried")
	assert_true(after.behaviours().action_executor().is_running(npc_id), "the executor answers as before the save")
	assert_true(after.behaviours().is_stocked(PANTRY), "the stock is not given again")
	for tick: int in range(40):
		if after.told(npc_id).has(DONE):
			break
		_run(second, 1, after)
	# 20 ticks of eating, 8 of them before the save: 12 after it, and the
	# decider hears one tick later.
	assert_eq(after.tick, 12 + 1, "the eating goes on where it was")
	assert_eq(_json(_document(second, npc_id)), expected, "it ends as the run that went on")
	assert_true(is_equal_approx(_needs(second, npc_id).value(NpcNeedKind.HUNGER), expected_hunger))
	assert_null(second.inventory.get_item(item_id), "the unit is used up")
	assert_eq(after.behaviours().stocked_count, 0)
	# A cell that leaves memory takes the NPC's inventory with it and brings
	# it back: an NPC that carries a unit (an eating cut short).
	assert_false(second.inventory.spawn_detached_item((_containers(second).get_container((started["pantry"] as ContainerInstance).container_id)).inventory_id, RATION, 1).is_empty())
	var again: Dictionary = {"world": second, "behaviours": after.behaviours()}
	_begin(again, npc_id, NpcBehaviours.ACTION_EAT)
	for tick: int in range(200):
		if state.step == NpcBehaviourState.STEP_PERFORMING:
			break
		_run(second, 1, after)
	after.behaviours().action_executor().cancel(second, _npcs(second), _npcs(second).get_npc(npc_id))
	var kept_id: String = state.carried_items()[0].item_instance_id
	var before_unload: Dictionary = _json(_document(second, npc_id))
	second.get_player(second.online_player_ids()[0]).position = Vector3(45.5, 0.0, 45.5)
	_run(second, 40, after)
	assert_false(_npcs(second).has_npc(npc_id), "the NPC left memory with its cell")
	assert_null(second.inventory.get_item(kept_id), "and so did what it carries")
	assert_false(second.inventory.has_inventory(inventory_id))
	second.get_player(second.online_player_ids()[0]).position = SPAWN
	_run(second, 5, after)
	assert_true(_npcs(second).has_npc(npc_id))
	assert_eq(_json(_document(second, npc_id)), before_unload, "it comes back as it left")
	assert_not_null(second.inventory.get_item(kept_id))
	assert_eq(_state(second, npc_id).carried_items()[0].item_instance_id, kept_id)
	# An NPC that is removed takes what it carries out of the game.
	var items_before: int = second.inventory.item_count()
	assert_true(_npcs(second).remove_npc(second, npc_id).ok)
	assert_eq(second.inventory.item_count(), items_before - 1)
	assert_null(second.inventory.get_item(kept_id))
	assert_true(second.registry.is_tombstoned(kept_id), "its id is never used again")
