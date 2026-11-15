extends TestCase
## P3-1: what clients see when the server releases and loads world cells
## (docs/09 §15.1), over real ENet (one server and two clients in one
## process). A client must never keep showing an entity the server took out
## of memory, must get the entities of a cell that is loaded while it is
## connected, and two clients must agree. No message was added for this:
## the existing world item and zombie messages are reused.

const WORLD: String = "cell_net_world"
const NEVER: float = 1.0e9
const WAIT_SEC: float = 15.0
const SPAWN: Vector3 = Vector3(5.0, 0.0, 5.0)
## In cell_4_0: four cells from the spawn cell, outside its preload ring.
const FAR_ITEM_AT: Vector3 = Vector3(45.0, 0.0, 5.0)
const FAR_ZOMBIE_AT: Vector3 = Vector3(46.0, 0.0, 8.0)
const FAR_CELL: String = "cell_4_0"

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _store: WorldCellStore = null
var _server_events: Array[Dictionary] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	# from_defaults() hands out shared cached resources: replace, never edit.
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.gameplay.world_half_extent_m = 50.0
	_config.gameplay.player_spawn_position = SPAWN
	_config.clock = WorldClockSettings.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.wander_pause_min_sec = NEVER
	_config.zombie.wander_pause_max_sec = NEVER
	# 10 m cells; a cell is released 0.4 s (real time) after nobody wants it.
	_config.world_cells = WorldCellSettings.new()
	_config.world_cells.cell_size_m = 10.0
	_config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	_config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	_config.world_cells.active_radius_cells = 1
	_config.world_cells.preload_radius_cells = 2
	_config.world_cells.preload_lookahead_sec = 0.0
	_config.world_cells.deactivate_delay_sec = 0.1
	_config.world_cells.unload_delay_sec = 0.3
	_config.world_cells.refresh_period_sec = 0.0
	_cluster = NetTestCluster.new(tree, network_settings, _config)
	_server_events = []


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func _start() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(DevWorldSeed.new())
	_store = WorldCellStore.new()
	_cells().set_store(_store)
	if _cluster.start_server(_world, null) != OK:
		return false
	_zombie_module(_cluster.server).server_events_drained.connect(func(events: Array[Dictionary]) -> void: _server_events.append_array(events))
	return true


func _eventually(condition: Callable, timeout_sec: float = WAIT_SEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func _cells() -> WorldCellService:
	return _world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _zombies() -> ZombieService:
	return _world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _zombie_module(service: NetworkService) -> ZombieNetModule:
	return service.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule


func _mirror(service: NetworkService) -> ClientZombieState:
	return _zombie_module(service).client_state


func _item_ids(client: NetworkService) -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(client.client_state.world_items.keys())
	ids.sort()
	return ids


func _zombie_ids(client: NetworkService) -> PackedStringArray:
	var ids: PackedStringArray = _mirror(client).zombie_ids()
	ids.sort()
	return ids


func _server_zombie_ids() -> PackedStringArray:
	var ids: PackedStringArray = _zombies().zombie_ids()
	ids.sort()
	return ids


## True when the client shows exactly what the server has in memory.
func _matches_server(client: NetworkService) -> bool:
	return _item_ids(client) == _world.inventory.world_item_ids() and _zombie_ids(client) == _server_zombie_ids()


func _spawn_zombie(position: Vector3) -> String:
	# Facing +z: every player in these tests stands to the side of or behind it.
	return str(_zombies().spawn_zombie(_world, position, ZombiePerception.yaw_towards(Vector3(0.0, 0.0, 1.0), 0.0)).event["zombie_id"])


func _count(events: Array[Dictionary], event_type: String) -> int:
	var count: int = 0
	for event: Dictionary in events:
		if event["event_type"] == event_type:
			count += 1
	return count


func test_clients_lose_released_entities_and_get_them_back_when_the_cell_loads() -> void:
	assert_true(_start())
	var near_item: String = _world.inventory.spawn_world_item("dev_test_item", 1, _world.cell_id_at(Vector3(6.0, 0.0, 5.0)), Vector3(6.0, 0.0, 5.0))
	var near_zombie: String = _spawn_zombie(Vector3(12.0, 0.0, 5.0))
	var far_item: String = _world.inventory.spawn_world_item("dev_food_ration", 2, FAR_CELL, FAR_ITEM_AT)
	var far_zombie: String = _spawn_zombie(FAR_ZOMBIE_AT)
	assert_true(_zombies().apply_damage_to_zombie(far_zombie, 25.0, "test_source").ok)

	# --- a cell is released while a client is connected ---
	var a: NetworkService = await _cluster.join_client("alice")
	assert_not_null(a)
	var a_removed: PackedStringArray = []
	_mirror(a).zombie_removed.connect(func(zombie_id: String) -> void: a_removed.append(zombie_id))
	assert_true(await _eventually(func() -> bool: return _cells().state_of(FAR_CELL) == WorldCellLifecycle.State.UNLOADED), "the far cell is released")
	assert_false(_zombies().has_zombie(far_zombie))
	assert_true(await _eventually(func() -> bool: return _matches_server(a)), "the client shows what the server has: items %s, zombies %s" % [str(_item_ids(a)), str(_zombie_ids(a))])
	assert_eq(_item_ids(a), PackedStringArray([near_item]), "the released item is gone from the client")
	assert_eq(_zombie_ids(a), PackedStringArray([near_zombie]), "and the released zombie")
	assert_false(WorldCellDocument.is_empty(_store.document_of(FAR_CELL)), "they are saved, not lost")

	# --- a late joiner gets what is in memory, nothing else ---
	var b: NetworkService = await _cluster.join_client("bob")
	assert_not_null(b)
	assert_eq(_item_ids(b), PackedStringArray([near_item]))
	assert_true(await _eventually(func() -> bool: return _zombie_ids(b) == PackedStringArray([near_zombie])))

	# --- the cell is loaded again while both are connected ---
	var a_id: String = a.client_state.local_player_id
	_world.get_player(a_id).position = Vector3(35.0, 0.0, 5.0)
	assert_true(await _eventually(func() -> bool: return _cells().is_loaded(FAR_CELL)), "alice walked there: the cell is in memory")
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b)), "both clients got the entities of the loaded cell")
	assert_eq(_item_ids(a), PackedStringArray([near_item, far_item]))
	assert_eq(_item_ids(b), _item_ids(a), "two clients agree")
	assert_eq(_zombie_ids(b), _zombie_ids(a))
	assert_eq(a.client_state.world_items[far_item], b.client_state.world_items[far_item])
	assert_eq(a.client_state.world_items[far_item]["position"], FAR_ITEM_AT)
	assert_eq(int(a.client_state.world_items[far_item]["quantity"]), 2)
	# The zombie came back as it was: the next snapshot carries its real health.
	assert_true(await _eventually(func() -> bool: return is_equal_approx(float(_mirror(a).get_zombie(far_zombie).get("health_fraction", 0.0)), 0.75) and is_equal_approx(float(_mirror(b).get_zombie(far_zombie).get("health_fraction", 0.0)), 0.75)), "health of the reloaded zombie on both clients")
	assert_eq(_mirror(a).get_zombie(far_zombie)["position"], FAR_ZOMBIE_AT)

	# --- and released again ---
	_world.get_player(a_id).position = SPAWN
	assert_true(await _eventually(func() -> bool: return _cells().state_of(FAR_CELL) == WorldCellLifecycle.State.UNLOADED))
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b)))
	assert_eq(_item_ids(a), PackedStringArray([near_item]))
	assert_eq(_item_ids(b), PackedStringArray([near_item]))
	assert_eq(_zombie_ids(a), PackedStringArray([near_zombie]))
	assert_eq(_zombie_ids(b), PackedStringArray([near_zombie]))
	assert_eq(a_removed.count(far_zombie), 2, "alice's mirror dropped the zombie both times its cell was released")

	# --- nothing was invented or broken on the way ---
	for client: NetworkService in [a, b]:
		assert_eq(_mirror(client).rejected_payload_count, 0)
		assert_eq(_mirror(client).event_gap_count, 0, "the zombie event stream has no holes")
		assert_eq((client.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule).rejected_payload_count, 0)
	assert_eq(_count(_server_events, ZombieService.EVENT_SPAWNED), 2, "the server's own event stream only has the two real spawns")
	assert_eq(_count(_server_events, ZombieService.EVENT_REMOVED), 0, "and no removal: no zombie was removed from the world")
	assert_eq(_zombies().zombie_count(), 1)
	assert_eq(_world.registry.is_tombstoned(far_zombie), false)
	var net: WorldCellNetModule = _cluster.server.get_module(WorldCellNetModule.MODULE_NAME) as WorldCellNetModule
	assert_true(net.sent_item_add_count >= 1 and net.sent_item_remove_count >= 2)


func test_a_cell_emptied_by_a_pickup_stays_empty_for_everybody_after_a_reload() -> void:
	assert_true(_start())
	var item_id: String = _world.inventory.spawn_world_item("dev_test_item", 1, _world.cell_id_at(Vector3(6.0, 0.0, 5.0)), Vector3(6.0, 0.0, 5.0))
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	assert_true(a != null and b != null)
	assert_eq(_item_ids(b), PackedStringArray([item_id]))
	var answers: Array[bool] = []
	a.pickup_result.connect(func(_request_id: int, ok: bool, _reason: String) -> void: answers.append(ok))
	a.request_pickup(item_id)
	assert_true(await _eventually(func() -> bool: return answers.size() == 1 and answers[0]), "alice picked it up")
	assert_true(await _eventually(func() -> bool: return _item_ids(b).is_empty()), "bob saw it go")
	# Both walk away until the cell is released, then come back.
	for client: NetworkService in [a, b]:
		_world.get_player(client.client_state.local_player_id).position = Vector3(-45.0, 0.0, -45.0)
	assert_true(await _eventually(func() -> bool: return _cells().state_of("cell_0_0") == WorldCellLifecycle.State.UNLOADED))
	for client: NetworkService in [a, b]:
		_world.get_player(client.client_state.local_player_id).position = SPAWN
	assert_true(await _eventually(func() -> bool: return _cells().state_of("cell_0_0") == WorldCellLifecycle.State.ACTIVE))
	await _cluster.wait_frames(20)
	assert_eq(_world.inventory.world_item_ids().size(), 0, "the item did not come back with the cell")
	assert_eq(_item_ids(a).size(), 0)
	assert_eq(_item_ids(b).size(), 0)
	assert_true(a.client_state.has_inventory_item(item_id), "alice still carries it")
