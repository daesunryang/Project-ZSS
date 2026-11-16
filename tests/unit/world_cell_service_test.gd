extends TestCase
## P3-1: WorldCellService (docs/03 §3, docs/09 §15.1): which cells are
## active / preloaded / unloaded for scripted server positions of players,
## the lifecycle path, hysteresis on a stepped clock, look-ahead, the load
## budget, failed loads and saves, strays, and unload -> reload of a cell's
## entities. No nodes, no real waiting: time only passes through
## ServerWorld.step_systems().

const WORLD: String = "cell_test_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const TOLERANCE: float = 0.000001
const S: Dictionary = {
	"unloaded": WorldCellLifecycle.State.UNLOADED,
	"loading": WorldCellLifecycle.State.LOADING,
	"preloaded": WorldCellLifecycle.State.PRELOADED,
	"active": WorldCellLifecycle.State.ACTIVE,
	"saving": WorldCellLifecycle.State.SAVING,
	"unloading": WorldCellLifecycle.State.UNLOADING,
}

var _settings: WorldCellSettings = null
var _transitions: Array[Array] = []
var _spawn: Vector3 = Vector3.ZERO


## A store whose loads / saves can be made to fail.
class FailingStore extends WorldCellStore:
	var fail_load: Dictionary[String, bool] = {}
	var fail_save: bool = false
	var load_calls: int = 0
	var save_calls: int = 0

	func load_cell(cell_id: String) -> Dictionary:
		load_calls += 1
		if fail_load.has(cell_id):
			return {WorldCellStore.KEY_ERROR: ERR_FILE_CORRUPT, WorldCellStore.KEY_DOCUMENT: {}}
		return super.load_cell(cell_id)

	func save_cells(world: ServerWorld, cell_ids: PackedStringArray) -> Error:
		save_calls += 1
		if fail_save:
			return ERR_FILE_CANT_WRITE
		return super.save_cells(world, cell_ids)


## A deterministic stand-in for a background writer. Tests decide the exact
## tick at which the completion callback runs; no wall-clock waiting.
class DeferredStore extends WorldCellStore:
	var callback: Callable
	var pending_world: ServerWorld
	var pending_ids: PackedStringArray
	var save_calls: int = 0

	func request_save_cells(world: ServerWorld, cell_ids: PackedStringArray, completed: Callable) -> void:
		save_calls += 1
		pending_world = world
		pending_ids = cell_ids.duplicate()
		callback = completed

	## Drops the world and the callback (bound to the world) before calling
	## it: the world owns this store through WorldCellService, so keeping
	## them would be a world -> store -> world reference cycle (a leak).
	func complete(error: Error) -> void:
		var world: ServerWorld = pending_world
		pending_world = null
		if error == OK:
			error = super.save_cells(world, pending_ids)
		var completed: Callable = callback
		callback = Callable()
		completed.call(error)


func before_each() -> void:
	GameLogger.set_capture(true)
	_transitions = []
	_spawn = Vector3.ZERO
	# A 10 x 10 map of 10 m cells; the player's cell and its neighbours are
	# active, one more ring is preloaded. No look-ahead and a look every tick
	# unless a test changes it.
	_settings = WorldCellSettings.new()
	_settings.cell_size_m = 10.0
	_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_settings.bounds_max_m = Vector2(50.0, 50.0)
	_settings.active_radius_cells = 1
	_settings.preload_radius_cells = 2
	_settings.preload_lookahead_sec = 0.0
	_settings.deactivate_delay_sec = 2.0
	_settings.unload_delay_sec = 4.0
	_settings.refresh_period_sec = 0.0
	_settings.max_preload_loads_per_refresh = 1000
	_settings.retry_delay_sec = 3.0


func after_each() -> void:
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = _spawn
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.zombie.wander_pause_min_sec = NEVER
	config.zombie.wander_pause_max_sec = NEVER
	config.world_cells = _settings
	return config


func _world(store: WorldCellStore = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	world.seed_new_world(DevWorldSeed.new())
	var cells: WorldCellService = _cells(world)
	cells.set_store(store)
	cells.cell_state_changed.connect(func(cell_id: String, from: int, to: int) -> void: _transitions.append([cell_id, from, to]))
	return world


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _state(world: ServerWorld, cell_id: String) -> int:
	return _cells(world).state_of(cell_id)


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


## Puts a player somewhere (as the server movement would) and steps once.
func _move(world: ServerWorld, player_id: String, position: Vector3) -> void:
	world.get_player(player_id).position = position
	world.step_systems(TICK)


## The states one cell went through, as names.
func _path_of(cell_id: String) -> PackedStringArray:
	var path: PackedStringArray = []
	for entry: Array in _transitions:
		if entry[0] == cell_id:
			if path.is_empty():
				path.append(WorldCellLifecycle.state_name(entry[1]))
			path.append(WorldCellLifecycle.state_name(entry[2]))
	return path


func _log_has(text: String) -> bool:
	for line: String in GameLogger.captured_lines():
		if line.contains(text):
			return true
	return false


func _approx_equal(a: Variant, b: Variant) -> bool:
	if (typeof(a) == TYPE_FLOAT or typeof(a) == TYPE_INT) and (typeof(b) == TYPE_FLOAT or typeof(b) == TYPE_INT):
		return absf(float(a) - float(b)) <= TOLERANCE
	if typeof(a) != typeof(b):
		return false
	if typeof(a) == TYPE_ARRAY:
		if (a as Array).size() != (b as Array).size():
			return false
		for index: int in range((a as Array).size()):
			if not _approx_equal(a[index], b[index]):
				return false
		return true
	if typeof(a) == TYPE_DICTIONARY:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for key: Variant in (a as Dictionary):
			if not (b as Dictionary).has(key) or not _approx_equal(a[key], b[key]):
				return false
		return true
	return a == b


# ------------------------------------------------------------ activation

func test_composition_registers_the_cell_service_first() -> void:
	var world: ServerWorld = _world()
	assert_eq(world.system_ids()[0], WorldCellService.SYSTEM_ID)
	assert_eq(world.cell_grid.cell_size_m, 10.0, "the world's grid comes from the cell settings")
	assert_eq(world.cell_id_at(Vector3(-15.0, 0.0, 25.0)), "cell_-2_2")
	assert_eq(CompositionConfig.from_defaults().validate().size(), 0)


func test_nothing_is_loaded_while_nobody_is_in_the_world() -> void:
	var world: ServerWorld = _world()
	_run(world, 2.0)
	assert_eq(_cells(world).loaded_cell_ids().size(), 0)
	assert_eq(_state(world, "cell_0_0"), S["unloaded"])
	assert_true(world.is_cell_simulated("cell_0_0") == false and world.is_cell_loaded("cell_0_0") == false)


func test_a_player_entering_the_world_gets_its_cells_at_once() -> void:
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	assert_eq(_state(world, world.cell_id_at(player.position)), S["active"], "before any tick")
	var cells: WorldCellService = _cells(world)
	assert_eq(cells.active_cell_ids().size(), 9, "the player's cell and its eight neighbours")
	assert_eq(cells.loaded_cell_ids().size(), 25, "plus one preloaded ring")
	for cell_id: String in ["cell_-1_-1", "cell_0_0", "cell_1_1", "cell_-1_1"]:
		assert_eq(_state(world, cell_id), S["active"], cell_id)
	for cell_id: String in ["cell_2_0", "cell_-2_-2", "cell_0_2", "cell_1_-2"]:
		assert_eq(_state(world, cell_id), S["preloaded"], cell_id)
	for cell_id: String in ["cell_3_0", "cell_-3_-3", "cell_0_3"]:
		assert_eq(_state(world, cell_id), S["unloaded"], cell_id)
	assert_eq(_path_of("cell_0_0"), PackedStringArray(["unloaded", "loading", "preloaded", "active"]))
	assert_eq(_path_of("cell_2_0"), PackedStringArray(["unloaded", "loading", "preloaded"]))
	assert_true(world.is_cell_simulated("cell_1_1"))
	assert_true(world.is_cell_loaded("cell_2_0") and not world.is_cell_simulated("cell_2_0"))


func test_only_players_in_the_world_load_cells() -> void:
	var world: ServerWorld = _world()
	world.require_character_creation = true
	var connected: PlayerState = world.join("no_character_yet")
	_run(world, 1.0)
	assert_false(world.is_online(connected.player_id))
	assert_eq(_cells(world).loaded_cell_ids().size(), 0, "a connection without a character is not in the world")
	var created: ActionResult = world.create_character(connected.player_id, "Alice", {})
	assert_true(created.ok, created.reason)
	assert_eq(_state(world, "cell_0_0"), S["active"], "entering the world loads the cells at once")


func test_cells_follow_the_server_position_and_old_cells_wait_before_they_go() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var player_id: String = world.join("alice").player_id
	_move(world, player_id, Vector3(25.0, 0.0, 5.0))
	assert_eq(_state(world, "cell_2_0"), S["active"], "the new cell is active in the tick the player is in it")
	assert_eq(_state(world, "cell_3_1"), S["active"])
	assert_eq(_state(world, "cell_4_0"), S["preloaded"])
	assert_eq(_state(world, "cell_-1_0"), S["active"], "the old cell is not dropped at once")
	assert_eq(_state(world, "cell_-2_0"), S["preloaded"])
	_run(world, 1.8)
	assert_eq(_state(world, "cell_-1_0"), S["active"], "still inside deactivate_delay_sec")
	_run(world, 0.3)
	assert_eq(_state(world, "cell_-1_0"), S["preloaded"])
	assert_eq(_state(world, "cell_0_0"), S["preloaded"], "inside the preload radius: stays in memory")
	assert_eq(_state(world, "cell_-2_0"), S["preloaded"], "still inside unload_delay_sec")
	_run(world, 2.0)
	assert_eq(_state(world, "cell_-2_0"), S["unloaded"], "4 s after it was last wanted")
	assert_eq(_path_of("cell_-2_0"), PackedStringArray(["unloaded", "loading", "preloaded", "saving", "unloading", "unloaded"]))
	assert_eq(_state(world, "cell_-1_0"), S["preloaded"], "its own 4 s started when it stopped being active")
	_run(world, 4.0)
	assert_eq(_state(world, "cell_-1_0"), S["unloaded"])
	assert_eq(_path_of("cell_-1_0"), PackedStringArray(["unloaded", "loading", "preloaded", "active", "preloaded", "saving", "unloading", "unloaded"]))
	assert_eq(_state(world, "cell_0_0"), S["preloaded"])
	assert_eq(_cells(world).active_cell_ids().size(), 9)
	assert_eq(_cells(world).loaded_cell_ids().size(), 25)


func test_coming_back_in_time_cancels_the_wait() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var player_id: String = world.join("alice").player_id
	_move(world, player_id, Vector3(25.0, 0.0, 5.0))
	_run(world, 1.5)
	_move(world, player_id, Vector3(5.0, 0.0, 5.0))
	_run(world, 1.5)
	_move(world, player_id, Vector3(25.0, 0.0, 5.0))
	_run(world, 1.5)
	assert_eq(_state(world, "cell_-1_0"), S["active"], "the 2 s start again every time the player leaves")
	assert_eq(_path_of("cell_-1_0"), PackedStringArray(["unloaded", "loading", "preloaded", "active"]))
	assert_eq(_cells(world).unload_count, 0)


func test_walking_along_a_border_does_not_thrash() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var player_id: String = world.join("alice").player_id
	# Back and forth over the border between cell 0 and cell 1, twice a second.
	for crossing: int in range(4):
		_move(world, player_id, Vector3(10.2 if crossing % 2 == 0 else 9.8, 0.0, 5.0))
		_run(world, 0.4)
	var settled: int = _transitions.size()
	for crossing: int in range(60):
		_move(world, player_id, Vector3(10.2 if crossing % 2 == 0 else 9.8, 0.0, 5.0))
		_run(world, 0.4)
	assert_eq(_transitions.size(), settled, "30 s of crossing the border change no cell")
	assert_eq(_state(world, "cell_-1_0"), S["active"])
	assert_eq(_state(world, "cell_2_0"), S["active"])
	assert_eq(_state(world, "cell_3_0"), S["preloaded"])
	assert_eq(_cells(world).unload_count, 0)
	# The same walk without the delays loads and releases cells all the time.
	_settings.deactivate_delay_sec = 0.0
	_settings.unload_delay_sec = 0.0
	_transitions = []
	_spawn = Vector3.ZERO
	var impatient: ServerWorld = _world(WorldCellStore.new())
	var other_id: String = impatient.join("bob").player_id
	for crossing: int in range(20):
		_move(impatient, other_id, Vector3(10.2 if crossing % 2 == 0 else 9.8, 0.0, 5.0))
		_run(impatient, 0.4)
	assert_true(_cells(impatient).unload_count >= 20, "control: without hysteresis every crossing releases cells")


func test_two_players_keep_both_areas_and_a_leaving_player_gives_its_area_up() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var alice: String = world.join("alice").player_id
	var bob: String = world.join("bob").player_id
	_move(world, bob, Vector3(-35.0, 0.0, -35.0))
	assert_eq(_state(world, "cell_-4_-4"), S["active"])
	assert_eq(_state(world, "cell_0_0"), S["active"])
	_run(world, 8.0)
	assert_eq(_cells(world).active_cell_ids().size(), 18, "two separate 3 x 3 areas")
	world.leave(bob)
	_run(world, 8.0)
	assert_true(world.is_online(alice))
	assert_eq(_state(world, "cell_-4_-4"), S["unloaded"], "nobody is there any more")
	assert_eq(_state(world, "cell_0_0"), S["active"])
	assert_eq(_cells(world).active_cell_ids().size(), 9)


func test_nothing_changes_while_the_clock_is_paused() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var alice: String = world.join("alice").player_id
	world.leave(alice)
	_run(world, 30.0)
	assert_eq(_cells(world).loaded_cell_ids().size(), 25, "an empty, paused world keeps what it had")
	assert_eq(_cells(world).unload_count, 0)


func test_active_cells_never_border_a_cell_that_is_not_in_memory() -> void:
	_settings.deactivate_delay_sec = 0.7
	_settings.unload_delay_sec = 0.3
	var world: ServerWorld = _world(WorldCellStore.new())
	var player_id: String = world.join("alice").player_id
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7
	var position: Vector3 = Vector3.ZERO
	var broken: int = 0
	for tick: int in range(400):
		position = world.clamp_to_world(position + Vector3(rng.randf_range(-6.0, 6.0), 0.0, rng.randf_range(-6.0, 6.0)))
		_move(world, player_id, position)
		for cell_id: String in _cells(world).active_cell_ids():
			for near: Vector2i in world.cell_grid.neighbours(WorldCellGrid.parse_id(cell_id) as Vector2i):
				if not world.is_cell_loaded(WorldCellGrid.id_of(near)):
					broken += 1
		if _state(world, world.cell_id_at(position)) != S["active"]:
			broken += 1
	assert_eq(broken, 0)
	assert_true(_cells(world).unload_count > 10, "the walk did release cells")


# ------------------------------------------------------------ look-ahead and budget

func test_look_ahead_preloads_in_the_direction_of_travel_but_activates_nothing() -> void:
	_settings.preload_lookahead_sec = 2.0
	_spawn = Vector3(4.0, 0.0, 5.0)
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	assert_eq(_state(world, "cell_3_0"), S["unloaded"])
	# 0.4 m per tick = 4 m/s towards +x: in 2 s the player is 8 m further.
	for tick: int in range(8):
		_move(world, player_id, world.get_player(player_id).position + Vector3(0.4, 0.0, 0.0))
	assert_eq(world.cell_id_at(world.get_player(player_id).position), "cell_0_0", "still in its old cell")
	assert_eq(_state(world, "cell_3_0"), S["preloaded"], "the cells around where it is heading are in memory")
	assert_eq(_state(world, "cell_2_0"), S["preloaded"], "a look-ahead never activates a cell")
	assert_eq(_state(world, "cell_-3_0"), S["unloaded"], "nothing behind it")


func test_without_look_ahead_cells_ahead_wait_for_the_player() -> void:
	_spawn = Vector3(4.0, 0.0, 5.0)
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	for tick: int in range(8):
		_move(world, player_id, world.get_player(player_id).position + Vector3(0.4, 0.0, 0.0))
	assert_eq(_state(world, "cell_3_0"), S["unloaded"])


func test_look_ahead_reaches_at_most_one_cell() -> void:
	_settings.preload_lookahead_sec = 2.0
	_spawn = Vector3(-45.0, 0.0, 5.0)
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	assert_eq(_state(world, "cell_-5_0"), S["active"])
	# A jump of 50 m in one tick (a respawn, an admin move).
	_move(world, player_id, Vector3(5.0, 0.0, 5.0))
	assert_eq(_state(world, "cell_3_0"), S["preloaded"], "one cell ahead of the player's cell")
	assert_eq(_state(world, "cell_4_0"), S["unloaded"], "not five")


func test_the_outer_preload_ring_is_loaded_within_the_budget() -> void:
	_settings.preload_radius_cells = 3
	_settings.max_preload_loads_per_refresh = 2
	var world: ServerWorld = _world()
	world.join("alice")
	var cells: WorldCellService = _cells(world)
	assert_eq(cells.active_cell_ids().size(), 9)
	assert_eq(cells.loaded_cell_ids().size(), 27, "the active area and the ring next to it at once, two more cells of the outer ring")
	world.step_systems(TICK)
	assert_eq(cells.loaded_cell_ids().size(), 29)
	_run(world, 2.0)
	assert_eq(cells.loaded_cell_ids().size(), 49, "the whole 7 x 7 area a little later")


func test_refresh_period_limits_how_often_the_players_are_looked_at() -> void:
	_settings.refresh_period_sec = 1.0
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	var cells: WorldCellService = _cells(world)
	var looks: int = cells.refresh_count
	_run(world, 5.0)
	assert_eq(cells.refresh_count - looks, 5, "once a second, not every tick")
	world.get_player(player_id).position = Vector3(25.0, 0.0, 5.0)
	_run(world, 1.0)
	assert_eq(_state(world, "cell_3_0"), S["active"])


# ------------------------------------------------------------ failures

func test_a_cell_that_fails_to_load_is_not_activated_and_is_retried() -> void:
	var store: FailingStore = FailingStore.new()
	store.fail_load["cell_0_0"] = true
	var world: ServerWorld = _world(store)
	world.join("alice")
	var cells: WorldCellService = _cells(world)
	assert_eq(_state(world, "cell_0_0"), S["unloaded"], "not activated")
	assert_false(world.is_cell_simulated("cell_0_0"))
	assert_eq(_path_of("cell_0_0"), PackedStringArray(["unloaded", "loading", "unloaded"]))
	assert_eq(cells.failed_load_count, 1)
	assert_eq(cells.active_cell_ids().size(), 8, "the other cells are not held back")
	assert_true(_log_has("cell could not be loaded"), "the failure is logged")
	assert_true(_log_has("cell_id=cell_0_0"), "with the cell id")
	_run(world, 2.5)
	assert_eq(cells.failed_load_count, 1, "no retry before retry_delay_sec")
	_run(world, 1.0)
	assert_eq(cells.failed_load_count, 2, "retried, failed again")
	store.fail_load.clear()
	_run(world, 3.5)
	assert_eq(_state(world, "cell_0_0"), S["active"], "the retry after the fault was fixed loads and activates it")
	assert_eq(cells.failed_load_count, 2)


func test_a_cell_document_that_cannot_be_restored_fails_the_load() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	store.replace_documents({"cell_0_0": {"schema_version": 99, "cell_id": "cell_0_0", "world_items": {}, "systems": {"zombie": {}}}})
	var world: ServerWorld = _world(store)
	world.join("alice")
	assert_eq(_state(world, "cell_0_0"), S["unloaded"])
	assert_eq(_cells(world).failed_load_count, 1)
	assert_true(_log_has("unsupported schema_version"))


func test_a_cell_that_cannot_be_saved_stays_in_memory() -> void:
	var store: FailingStore = FailingStore.new()
	store.fail_save = true
	var world: ServerWorld = _world(store)
	var player_id: String = world.join("alice").player_id
	var item_id: String = world.inventory.spawn_world_item("dev_test_item", 1, "cell_-2_0", Vector3(-15.0, 0.0, 5.0))
	_move(world, player_id, Vector3(25.0, 0.0, 5.0))
	_run(world, 5.0)
	var cells: WorldCellService = _cells(world)
	assert_eq(_state(world, "cell_-2_0"), S["preloaded"], "back in memory, nothing released")
	assert_not_null(world.inventory.get_item(item_id))
	assert_true(cells.failed_save_count >= 1)
	assert_eq(cells.unload_count, 0)
	assert_true(_log_has("cells could not be saved"))
	assert_true(_path_of("cell_-2_0").has("saving"))
	assert_false(_path_of("cell_-2_0").has("unloading"))
	var attempts: int = _path_of("cell_-2_0").count("saving")
	_run(world, 1.5)
	assert_eq(_path_of("cell_-2_0").count("saving"), attempts, "no retry before retry_delay_sec")
	store.fail_save = false
	_run(world, 2.0)
	assert_eq(_state(world, "cell_-2_0"), S["unloaded"])
	assert_null(world.inventory.get_item(item_id), "released only after it was saved")
	assert_false(WorldCellDocument.is_empty(store.document_of("cell_-2_0")))


func test_a_cell_stays_saving_until_the_background_save_completes() -> void:
	var store: DeferredStore = DeferredStore.new()
	var world: ServerWorld = _world(store)
	var player_id: String = world.join("alice").player_id
	var item_id: String = world.inventory.spawn_world_item("dev_test_item", 1, "cell_-2_0", Vector3(-15.0, 0.0, 5.0))
	_move(world, player_id, Vector3(25.0, 0.0, 5.0))
	_run(world, 5.0)
	assert_eq(_state(world, "cell_-2_0"), S["saving"], "not released when the request merely started")
	assert_not_null(world.inventory.get_item(item_id))
	assert_eq(store.save_calls, 1, "refreshes do not queue more saves while SAVING")
	store.complete(OK)
	assert_eq(_state(world, "cell_-2_0"), S["unloaded"], "released only after durable completion")
	assert_null(world.inventory.get_item(item_id))

	var failing: DeferredStore = DeferredStore.new()
	var second: ServerWorld = _world(failing)
	var second_player: String = second.join("bob").player_id
	var kept: String = second.inventory.spawn_world_item("dev_test_item", 1, "cell_-2_0", Vector3(-15.0, 0.0, 5.0))
	_move(second, second_player, Vector3(25.0, 0.0, 5.0))
	_run(second, 5.0)
	assert_eq(_state(second, "cell_-2_0"), S["saving"])
	failing.complete(ERR_FILE_CANT_WRITE)
	assert_eq(_state(second, "cell_-2_0"), S["preloaded"], "a failed generation keeps the cell in memory")
	assert_not_null(second.inventory.get_item(kept))
	assert_eq(_cells(second).failed_save_count, 1)

	var returning: DeferredStore = DeferredStore.new()
	var third: ServerWorld = _world(returning)
	var third_player: String = third.join("carol").player_id
	var still_here: String = third.inventory.spawn_world_item("dev_test_item", 1, "cell_-2_0", Vector3(-15.0, 0.0, 5.0))
	_move(third, third_player, Vector3(25.0, 0.0, 5.0))
	_run(third, 5.0)
	assert_eq(_state(third, "cell_-2_0"), S["saving"])
	# No refresh between this server-position change and completion: the
	# completion path itself must notice that the cell is wanted again.
	third.get_player(third_player).position = Vector3(-15.0, 0.0, 5.0)
	returning.complete(OK)
	assert_eq(_state(third, "cell_-2_0"), S["preloaded"])
	assert_not_null(third.inventory.get_item(still_here))


func test_without_a_store_no_cell_is_released() -> void:
	var world: ServerWorld = _world(null)
	var player_id: String = world.join("alice").player_id
	_move(world, player_id, Vector3(-45.0, 0.0, -45.0))
	_run(world, 30.0)
	assert_eq(_state(world, "cell_1_1"), S["preloaded"], "simulation stops")
	assert_eq(_cells(world).unload_count, 0, "but nothing leaves memory without a place to save it")
	assert_false(_transitions.any(func(entry: Array) -> bool: return entry[2] == S["saving"]))


# ------------------------------------------------------------ entities

func test_seeded_and_dropped_items_are_indexed_under_the_cell_of_their_position() -> void:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	var seed: DevWorldSeed = DevWorldSeed.new()
	seed.item_definition_ids = PackedStringArray(["dev_test_item", "dev_test_item"])
	seed.item_positions = PackedVector3Array([Vector3(6.0, 0.0, 0.0), Vector3(-2.0, 0.0, 22.0)])
	assert_eq(world.seed_new_world(seed), OK)
	var ids: PackedStringArray = world.inventory.world_item_ids()
	assert_eq(world.inventory.get_item(ids[0]).location_id, "cell_0_0")
	assert_eq(world.inventory.get_item(ids[1]).location_id, "cell_-1_2")
	assert_eq(world.cell_index.cell_of(ids[1]), "cell_-1_2")
	assert_eq(world.inventory.world_item_ids_in_cell("cell_-1_2"), PackedStringArray([ids[1]]))
	var player: PlayerState = world.join("alice")
	player.position = Vector3(5.0, 0.0, 1.0)
	assert_true(world.try_pickup(player.player_id, ids[0]).ok)
	assert_false(world.cell_index.has(ids[0]), "a carried item is in no cell")
	player.position = Vector3(-15.0, 0.0, 25.0)
	var dropped: ActionResult = world.try_drop_item(player.player_id, ids[0])
	assert_true(dropped.ok, dropped.reason)
	assert_eq(dropped.event["cell_id"], "cell_-2_2")
	assert_eq(world.inventory.get_item(ids[0]).location_id, "cell_-2_2")
	assert_eq(world.cell_index.cell_of(ids[0]), "cell_-2_2")
	assert_eq(world.cell_index.kind_of(ids[0]), InventoryService.ENTITY_KIND_ITEM)


func test_unload_and_reload_brings_every_entity_back_as_it_was() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var player_id: String = world.join("alice").player_id
	var zombies: ZombieService = _zombies(world)
	var item_a: String = world.inventory.spawn_world_item("dev_food_ration", 3, "cell_-2_0", Vector3(-15.5, 0.0, 5.25))
	var item_b: String = world.inventory.spawn_world_item("dev_test_item", 1, "cell_-2_0", Vector3(-11.0, 0.5, 9.0))
	var zombie_a: String = str(zombies.spawn_zombie(world, Vector3(-17.0, 0.0, 3.0), 1.25).event["zombie_id"])
	var zombie_b: String = str(zombies.spawn_zombie(world, Vector3(-12.0, 0.0, 8.0), -2.0).event["zombie_id"])
	assert_true(zombies.apply_damage_to_zombie(zombie_a, 37.5, player_id).ok)
	assert_true(zombies.apply_damage_to_zombie(zombie_b, 1000.0, player_id).ok, "a corpse")
	var items_before: Dictionary = {item_a: world.inventory.get_item(item_a).to_dict(), item_b: world.inventory.get_item(item_b).to_dict()}
	var positions_before: Dictionary = {item_a: world.inventory.world_position_of(item_a), item_b: world.inventory.world_position_of(item_b)}
	var zombies_before: Dictionary = {zombie_a: zombies.get_zombie(zombie_a).to_dict(), zombie_b: zombies.get_zombie(zombie_b).to_dict()}
	var next_sequence: int = world.ids.get_next_sequence()
	# Away, until the cell is released.
	_move(world, player_id, Vector3(35.0, 0.0, 5.0))
	_run(world, 5.0)
	assert_eq(_state(world, "cell_-2_0"), S["unloaded"])
	for entity_id: String in [item_a, item_b, zombie_a, zombie_b]:
		assert_false(world.registry.has(entity_id), entity_id + " left the registry")
		assert_false(world.registry.is_tombstoned(entity_id), entity_id + " was not retired")
		assert_false(world.cell_index.has(entity_id))
	assert_null(world.inventory.get_item(item_a))
	assert_false(world.inventory.world_item_ids().has(item_b))
	assert_false(zombies.has_zombie(zombie_a))
	assert_eq(zombies.zombie_count(), 0)
	assert_eq(world.cell_index.count_in_cell("cell_-2_0"), 0)
	assert_eq(store.saved_cell_ids(), PackedStringArray(["cell_-2_0"]), "empty cells leave no document")
	# Back within the preload radius: the cell is in memory again, not yet simulated.
	_move(world, player_id, Vector3(5.0, 0.0, 5.0))
	assert_eq(_state(world, "cell_-2_0"), S["preloaded"])
	for item_id: String in items_before:
		assert_not_null(world.inventory.get_item(item_id), item_id)
		assert_true(_approx_equal(world.inventory.get_item(item_id).to_dict(), items_before[item_id]), "item " + item_id)
		assert_true(world.inventory.world_position_of(item_id).is_equal_approx(positions_before[item_id]), "position of " + item_id)
		assert_eq(world.registry.kind_of(item_id), InventoryService.ENTITY_KIND_ITEM)
		assert_eq(world.cell_index.cell_of(item_id), "cell_-2_0")
	for zombie_id: String in zombies_before:
		assert_true(zombies.has_zombie(zombie_id), zombie_id)
		assert_true(_approx_equal(zombies.get_zombie(zombie_id).to_dict(), zombies_before[zombie_id]), "zombie " + zombie_id)
		assert_eq(world.registry.kind_of(zombie_id), ZombieService.ENTITY_KIND_ZOMBIE)
		assert_eq(world.cell_index.cell_of(zombie_id), "cell_-2_0")
	assert_eq(zombies.zombie_count(), 2)
	assert_eq(world.inventory.world_item_ids().size(), 2, "nothing was created a second time")
	assert_eq(world.ids.get_next_sequence(), next_sequence, "no new ids were handed out")


func test_an_item_taken_before_the_unload_does_not_come_back_with_the_cell() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var player: PlayerState = world.join("alice")
	var taken: String = world.inventory.spawn_world_item("dev_test_item", 1, "cell_-2_0", Vector3(-15.0, 0.0, 5.0))
	var left: String = world.inventory.spawn_world_item("dev_test_item", 1, "cell_-2_0", Vector3(-16.0, 0.0, 5.0))
	player.position = Vector3(-14.0, 0.0, 5.0)
	assert_true(world.try_pickup(player.player_id, taken).ok)
	for trip: int in range(3):
		_move(world, player.player_id, Vector3(35.0, 0.0, 5.0))
		_run(world, 7.0)
		assert_eq(_state(world, "cell_-2_0"), S["unloaded"])
		assert_not_null(world.inventory.get_item(taken), "a carried item stays in memory")
		_move(world, player.player_id, Vector3(-14.0, 0.0, 5.0))
		assert_eq(world.inventory.world_item_ids(), PackedStringArray([left]), "trip %d: only the item that was left lies there" % trip)
		assert_eq(world.inventory.item_count(), 2)


func test_entities_in_a_cell_that_is_not_loaded_get_their_cell_loaded_and_merged() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	# A document that was saved for cell_4_4 earlier: one item.
	var donor: ServerWorld = _world()
	var saved_item: String = donor.inventory.spawn_world_item("dev_test_item", 1, "cell_4_4", Vector3(45.0, 0.0, 45.0))
	store.replace_documents({"cell_4_4": JSON.parse_string(JSON.stringify(donor.cell_document("cell_4_4")))})
	var world: ServerWorld = _world(store)
	# A zombie placed there while the cell is not in memory.
	var zombie_id: String = str(_zombies(world).spawn_zombie(world, Vector3(44.0, 0.0, 46.0)).event["zombie_id"])
	assert_eq(_state(world, "cell_4_4"), S["unloaded"])
	assert_eq(world.cell_index.cell_of(zombie_id), "cell_4_4")
	var player_id: String = world.join("alice").player_id
	assert_eq(_state(world, "cell_4_4"), S["preloaded"], "loaded at the next look although no player is near")
	assert_not_null(world.inventory.get_item(saved_item), "what was saved for the cell came into memory with it")
	assert_true(_zombies(world).has_zombie(zombie_id))
	_run(world, 5.0)
	assert_eq(_state(world, "cell_4_4"), S["unloaded"], "and released again, saved with both")
	var document: Dictionary = store.document_of("cell_4_4")
	assert_eq(((document["world_items"] as Dictionary)["items"] as Array).size(), 1)
	assert_eq((((document["systems"] as Dictionary)["zombie"] as Dictionary)["zombies"] as Array).size(), 1)
	assert_true(world.is_online(player_id))


func test_releasing_empty_cells_does_not_ask_the_store_to_save() -> void:
	var store: FailingStore = FailingStore.new()
	var world: ServerWorld = _world(store)
	var player: PlayerState = world.join("alice")
	_move(world, player.player_id, Vector3(35.0, 0.0, 5.0))
	_run(world, 8.0)
	assert_true(_cells(world).unload_count > 0, "cells were released")
	assert_eq(store.save_calls, 0, "nothing lay in them and nothing was saved for them: there is nothing to save")
	# A cell with an item is saved before it is released.
	var item_id: String = world.inventory.spawn_world_item("dev_test_item", 1, "cell_1_0", Vector3(15.0, 0.0, 5.0))
	_move(world, player.player_id, Vector3(-35.0, 0.0, 5.0))
	_run(world, 8.0)
	assert_eq(_state(world, "cell_1_0"), S["unloaded"])
	assert_true(store.save_calls >= 1)
	assert_true(store.saved_cell_ids().has("cell_1_0"))
	# The item is taken; the cell is empty now but still has a saved document,
	# so releasing it must save again (or the item would come back).
	_move(world, player.player_id, Vector3(15.0, 0.0, 5.0))
	assert_true(world.try_pickup(player.player_id, item_id).ok)
	var saves: int = store.save_calls
	_move(world, player.player_id, Vector3(-35.0, 0.0, 5.0))
	_run(world, 8.0)
	assert_eq(_state(world, "cell_1_0"), S["unloaded"])
	assert_true(store.save_calls > saves, "the emptied cell was saved")
	assert_false(store.saved_cell_ids().has("cell_1_0"), "its document is gone")
	_move(world, player.player_id, Vector3(15.0, 0.0, 5.0))
	assert_eq(world.inventory.world_item_ids().size(), 0)
