extends TestCase
## P2-T4 (docs/00 ADR-007): permanent death over real ENet (server + 2
## clients). When a character dies, everything it carried appears in the
## world for every client where it died, anybody alive can pick it up, and
## the player starts a new character at the spawn point with an empty
## inventory and the next character generation (told to the owner only).
## Also: leaving and rejoining while dead, and a server restart while dead.

const WORLD: String = "permanent_death_net_test_world"
const SINGLE: String = "t4_single"
const STACK: String = "t4_stack"
const STACK_MAX: int = 10
const CELL: String = DevWorldSeed.DEV_CELL_ID
## Players spawn at the origin; every position here is within pickup range
## (2.5 m) of it and of the others.
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const OTHER_ITEM_AT: Vector3 = Vector3(-0.5, 0.0, 1.0)
const DEATH_AT: Vector3 = Vector3(1.5, 0.0, -1.0)
const WAIT_MSEC: int = 8000
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const LETHAL_DAMAGE: float = 100000.0
## Long enough that a test can look at the dead character first.
const DELAY_SEC: float = 2.0
const NEVER: float = 1.0e9

var _cluster: NetTestCluster = null
var _net_settings: NetworkSettings = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _save_root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_save_root = ""
	_net_settings = NetworkSettings.new()
	_net_settings.autosave_interval_sec = 0.0
	# Pickups are test setup here: keep their limiter out of the way.
	_net_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	_net_settings.pickup_intent_burst = GENEROUS_BURST
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.catalog = _new_catalog()
	_config.survival = SurvivalSettings.new()
	_config.survival.respawn_delay_sec = DELAY_SEC
	_config.survival_net = SurvivalNetSettings.new()
	_config.survival_net.owner_snapshot_rate_hz = 20.0
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	# No zombies.
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	_world = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	if not _save_root.is_empty():
		SaveService.remove_tree(_save_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _new_catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var single: ItemDefinition = ItemDefinition.new()
	single.definition_id = SINGLE
	catalog.add(single)
	var stack: ItemDefinition = ItemDefinition.new()
	stack.definition_id = STACK
	stack.max_stack = STACK_MAX
	catalog.add(stack)
	return catalog


func _start_server() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


func _join_two() -> Array[NetworkService]:
	var joined: Array[NetworkService] = []
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return joined
	joined.append(a)
	joined.append(b)
	return joined


func _module(service: NetworkService) -> InventoryNetModule:
	return service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule


## The client's survival mirror.
func _vitals_mirror(service: NetworkService) -> ClientSurvivalState:
	return (service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule).client_state


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _spawn(definition_id: String = SINGLE, quantity: int = 1, position: Vector3 = ITEM_AT) -> String:
	return _world.inventory.spawn_world_item(definition_id, quantity, CELL, position)


func _kill(player_id: String) -> void:
	var result: ActionResult = _survival().apply_damage(player_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE))
	if not result.ok:
		fail("test setup: kill failed: " + result.reason)


## Rows [signal name, payload] of the module's mirror signals of `service`.
func _mirror_signals_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	var module: InventoryNetModule = _module(service)
	module.world_items_added.connect(func(ids: PackedStringArray) -> void: rows.append(["world_items_added", Array(ids)]))
	module.inventory_items_removed.connect(func(ids: PackedStringArray) -> void: rows.append(["inventory_items_removed", Array(ids)]))
	module.inventory_item_changed.connect(func(item_id: String) -> void: rows.append(["inventory_item_changed", item_id]))
	return rows


## request_id -> [ok, reason] of every pickup result of `service`.
func _pickup_results_of(service: NetworkService) -> Dictionary:
	var results: Dictionary = {}
	service.pickup_result.connect(func(request_id: int, ok: bool, reason: String) -> void: results[request_id] = [ok, reason])
	return results


## Every survival event `service` receives from now on.
func _survival_events_of(service: NetworkService) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_vitals_mirror(service).event_received.connect(func(event: Dictionary) -> void: events.append(event))
	return events


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func _settle() -> void:
	for tick: int in range(SETTLE_TICKS):
		await tree.physics_frame


## Picks up `item_ids` through the real pickup RPC and waits for the mirror.
func _pick_up(client: NetworkService, item_ids: Array) -> bool:
	var results: Dictionary = _pickup_results_of(client)
	for item_id: String in item_ids:
		client.request_pickup(item_id)
	var done: bool = await _wait(func() -> bool:
		for item_id: String in item_ids:
			if not client.client_state.has_inventory_item(item_id):
				return false
		return true)
	if not done:
		fail("test setup: pickup of %s failed: %s" % [str(item_ids), str(results)])
	return done


func _carried_ids(player_id: String) -> Array:
	var ids: Array = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		ids.append(item.item_instance_id)
	return ids


## "" when the client's mirror equals the server's state (every world item,
## and exactly the items its own player carries), else what differs.
func _mismatch(client: NetworkService) -> String:
	var state: ClientWorldState = client.client_state
	var world_ids: PackedStringArray = _world.inventory.world_item_ids()
	if state.world_items.size() != world_ids.size():
		return "world items: mirror %d, server %d" % [state.world_items.size(), world_ids.size()]
	for item_id: String in world_ids:
		if not state.world_items.has(item_id):
			return "world item %s missing in the mirror" % item_id
		if state.world_items[item_id] != _world.inventory.describe_world_item(item_id):
			return "world item %s differs: %s" % [item_id, str(state.world_items[item_id])]
	var carried: Array[ItemInstance] = _world.inventory.items_in_inventory(_world.get_player(state.local_player_id).inventory_id)
	if state.inventory.size() != carried.size():
		return "inventory: mirror %d, server %d" % [state.inventory.size(), carried.size()]
	for item: ItemInstance in carried:
		if state.get_inventory_item(item.item_instance_id) != item.to_dict():
			return "carried item %s differs: %s" % [item.item_instance_id, str(state.get_inventory_item(item.item_instance_id))]
	return ""


## Waits until every client's mirror equals the server state and asserts it.
func _assert_mirrors_match(clients: Array[NetworkService], label: String) -> void:
	var matched: bool = await _wait(func() -> bool:
		for client: NetworkService in clients:
			if not _mismatch(client).is_empty():
				return false
		return true)
	if matched:
		assert_true(true)
		return
	for client: NetworkService in clients:
		assert_eq(_mismatch(client), "", "%s (%s)" % [label, client.client_state.local_player_id])


func _event_types(events: Array[Dictionary], player_id: String) -> Array:
	var types: Array = []
	for event: Dictionary in events:
		if str(event.get("player_id", "")) == player_id:
			types.append(str(event.get("event_type", "")))
	return types


# ------------------------------------------------------------ 1. die, loot, start over

func test_a_dead_characters_belongings_lie_in_the_world_for_everyone_and_the_player_starts_over() -> void:
	assert_true(_start_server(), "server started")
	var single_id: String = _spawn()
	var stack_id: String = _spawn(STACK, 4, OTHER_ITEM_AT)
	var bobs: String = _spawn(SINGLE, 1, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [single_id, stack_id]):
		return
	if not await _pick_up(b, [bobs]):
		return
	var total: int = _world.inventory.item_count()
	var carried: Array = _carried_ids(alice_id)
	assert_eq(carried, [single_id, stack_id])
	assert_eq(_vitals_mirror(a).character_generation(), 1, "alice knows she plays her first character")
	_world.get_player(alice_id).position = DEATH_AT
	await _assert_mirrors_match(clients, "start")
	var a_signals: Array[Array] = _mirror_signals_of(a)
	var b_signals: Array[Array] = _mirror_signals_of(b)
	var a_pickups: Dictionary = _pickup_results_of(a)
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	var b_owner_messages: int = _module(b).owner_message_count

	# --- alice dies ---
	_kill(alice_id)
	assert_eq(_carried_ids(alice_id), [], "server: the dead character carries nothing")
	var seen_dead: bool = await _wait(func() -> bool:
		return not _vitals_mirror(a).is_alive(alice_id) and not _vitals_mirror(b).is_alive(alice_id) and _mismatch(a).is_empty() and _mismatch(b).is_empty())
	assert_true(seen_dead, "both clients see alice dead and her things in the world: %s / %s" % [_mismatch(a), _mismatch(b)])
	assert_false(_survival().is_alive(alice_id), "alice is still dead on the server (the delay has not passed)")
	for client: NetworkService in clients:
		for item_id: String in carried:
			assert_eq(client.client_state.world_items.get(item_id, {}).get("position", null), DEATH_AT, "%s sees %s where alice died" % [client.client_state.local_player_id, item_id])
		assert_eq(client.client_state.world_items.get(stack_id, {}).get("quantity", 0), 4, "the stack is whole")
	assert_eq(a.client_state.inventory.size(), 0, "alice's inventory mirror is empty")
	assert_eq(a_signals, [["inventory_items_removed", carried], ["world_items_added", carried]], "the owner: inventory change, then the world items")
	assert_eq(b_signals, [["world_items_added", carried]], "others: the world items only")
	assert_eq(_module(b).owner_message_count, b_owner_messages, "bob is not sent anything about alice's inventory")
	assert_eq(_world.inventory.item_count(), total, "nothing was created or lost")
	# The dead character cannot take its things back.
	var refused_request: int = a.request_pickup(single_id)
	assert_true(await _wait(func() -> bool: return a_pickups.has(refused_request)), "dead alice got an answer")
	assert_eq(a_pickups.get(refused_request, []), [false, SurvivalService.REASON_PLAYER_DEAD])
	assert_eq(_carried_ids(alice_id), [])

	# --- the new character ---
	var started: bool = await _wait(func() -> bool:
		return _vitals_mirror(a).is_alive(alice_id) and _vitals_mirror(b).is_alive(alice_id) and _vitals_mirror(a).character_generation() == 2)
	assert_true(started, "both clients see alice alive again; alice knows it is her second character")
	var spawn_at: Vector3 = _config.gameplay.player_spawn_position
	assert_true(_survival().is_alive(alice_id))
	assert_eq(_world.get_player(alice_id).character_generation, 2, "server: second character")
	assert_eq(_world.get_player(alice_id).position, spawn_at, "server: at the spawn point")
	assert_eq(_carried_ids(alice_id), [], "server: the new character has nothing")
	var a_at_spawn: bool = await _wait(func() -> bool: return a.client_state.position_of(alice_id).distance_to(spawn_at) < 0.01 and b.client_state.position_of(alice_id).distance_to(spawn_at) < 0.01)
	assert_true(a_at_spawn, "both clients see alice at the spawn point")
	var health_full: bool = await _wait(func() -> bool: return _vitals_mirror(a).health() == _config.survival.max_health)
	assert_true(health_full, "alice's mirror: full health")
	assert_eq(_vitals_mirror(a).wounds().size(), 0, "alice's mirror: no wounds")
	assert_eq(_vitals_mirror(a).infection_stage(), "none")
	assert_eq(_vitals_mirror(a).need_category("hunger"), "good")
	assert_eq(a.client_state.inventory.size(), 0, "alice's mirror: the new character has nothing")
	await _assert_mirrors_match(clients, "after the new character started")
	for client: NetworkService in clients:
		for item_id: String in carried:
			assert_eq(client.client_state.world_items.get(item_id, {}).get("position", null), DEATH_AT, "%s still lies where the old character died" % item_id)
	# Others learn that alice died and came back, not which character she is.
	assert_eq(_event_types(b_events, alice_id), [SurvivalService.EVENT_PLAYER_WOUNDED, SurvivalService.EVENT_PLAYER_DIED, SurvivalService.EVENT_PLAYER_RESPAWNED])
	for event: Dictionary in b_events:
		assert_false(event.has("character_generation") or event.has("cause"), "public event carries private data: %s" % str(event))
	assert_eq(_vitals_mirror(b).character_generation(), 1, "bob only knows his own character")
	assert_true(_event_types(a_events, alice_id).has(SurvivalService.EVENT_PLAYER_RESPAWNED))

	# --- anybody alive can take what was left: bob one item, the new alice the other ---
	if not await _pick_up(b, [single_id]):
		return
	if not await _pick_up(a, [stack_id]):
		return
	await _assert_mirrors_match(clients, "after the pickups")
	assert_eq(_carried_ids(bob_id), [bobs, single_id], "server: bob carries what he took")
	assert_eq(_carried_ids(alice_id), [stack_id])
	assert_eq(a.client_state.get_inventory_item(stack_id).get("quantity", 0), 4)
	assert_eq(_world.inventory.item_count(), total)
	assert_eq(_module(a).rejected_payload_count + _module(b).rejected_payload_count, 0, "the server's own messages pass the client validation")


# ------------------------------------------------------------ 2. leave while dead

func test_leaving_while_dead_and_rejoining_starts_the_new_character_with_nothing() -> void:
	_config.survival.respawn_delay_sec = 1.0
	assert_true(_start_server(), "server started")
	var single_id: String = _spawn()
	var stack_id: String = _spawn(STACK, 3, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	if not await _pick_up(a, [single_id, stack_id]):
		return
	var total: int = _world.inventory.item_count()
	var carried: Array = _carried_ids(alice_id)
	_world.get_player(alice_id).position = DEATH_AT
	_kill(alice_id)
	assert_true(await _wait(func() -> bool: return _mismatch(b).is_empty() and b.client_state.world_items.size() == 2), "bob sees alice's things in the world")
	# Alice quits while dead; the world runs on for bob, past her delay.
	_cluster.remove_client(a)
	assert_true(await _wait(func() -> bool: return not _world.is_online(alice_id)), "alice left")
	var action_then: float = _world.clock.action_time_sec
	assert_true(await _wait(func() -> bool: return _world.clock.action_time_sec - action_then > 1.5), "the world kept running")
	assert_false(_survival().is_alive(alice_id), "nothing happens to an offline dead player")
	assert_eq(_world.get_player(alice_id).character_generation, 1)
	assert_eq(Array(_world.inventory.world_item_ids()), carried)

	var a2: NetworkService = await _cluster.join_client("alice")
	if a2 == null:
		fail("alice did not rejoin")
		return
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	var started: bool = await _wait(func() -> bool: return _vitals_mirror(a2).is_alive(alice_id) and _vitals_mirror(a2).character_generation() == 2 and _vitals_mirror(b).is_alive(alice_id))
	assert_true(started, "the new character started after the rejoin")
	assert_eq(_world.get_player(alice_id).character_generation, 2)
	assert_eq(_world.get_player(alice_id).position, _config.gameplay.player_spawn_position)
	assert_eq(_carried_ids(alice_id), [])
	assert_eq(a2.client_state.inventory.size(), 0, "the new character starts with nothing")
	var both: Array[NetworkService] = [a2, b]
	await _assert_mirrors_match(both, "after the rejoin")
	assert_eq(Array(_world.inventory.world_item_ids()), carried, "her things lie where she died, once")
	for item_id: String in carried:
		assert_eq(_world.inventory.world_position_of(item_id), DEATH_AT)
	assert_eq(_world.inventory.item_count(), total)
	await _settle()
	assert_eq(_world.get_player(alice_id).character_generation, 2, "one death, one new character")


# ------------------------------------------------------------ 3. restart while dead

func test_a_death_wait_survives_a_server_restart() -> void:
	# The delay cannot run out before the restart.
	_config.survival.respawn_delay_sec = NEVER
	_save_root = "user://test_saves/permanent_death_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	var single_id: String = _spawn()
	var stack_id: String = _spawn(STACK, 5, OTHER_ITEM_AT)
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	if not await _pick_up(a, [single_id, stack_id]):
		return
	var total: int = _world.inventory.item_count()
	var carried: Array = _carried_ids(alice_id)
	_world.get_player(alice_id).position = DEATH_AT
	var save: SaveService = SaveService.new(_save_root)
	var generation: int = save.current_generation(WORLD)
	_kill(alice_id)
	# The death (items in the world, dead character) is saved by the end of the tick.
	assert_true(await _wait(func() -> bool: return save.current_generation(WORLD) > generation), "the death was saved")

	# --- full restart: everything torn down, state comes only from disk ---
	await _cluster.shutdown()
	_cluster = null
	_world = null
	var persistence2: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence2.load_or_create(WORLD)
	assert_not_null(_world, "world restored from save")
	if _world == null:
		return
	# P3-1: a restart brings no cell into memory; this test looks at the whole world.
	(_world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).load_all_saved_cells(_world)
	assert_false(_survival().is_alive(alice_id), "alice is still dead")
	assert_eq(_world.get_player(alice_id).character_generation, 1)
	assert_eq(_world.get_player(alice_id).position, DEATH_AT)
	assert_eq(_carried_ids(alice_id), [], "the dead character was saved without items")
	assert_eq(Array(_world.inventory.world_item_ids()), carried, "her things lie in the world, once")
	assert_eq(_world.inventory.get_item(stack_id).quantity, 5)
	assert_eq(_world.inventory.item_count(), total)
	# From here on the (same settings object's) delay is short, so the wait
	# that began before the restart ends soon after alice is back online.
	_config.survival.respawn_delay_sec = 0.5
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	var b2: NetworkService = await _cluster.join_client("bob")
	if a2 == null or b2 == null:
		fail("clients did not rejoin")
		return
	var both: Array[NetworkService] = [a2, b2]
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	assert_eq(a2.client_state.inventory.size(), 0, "alice rejoins with an empty inventory")
	for client: NetworkService in both:
		for item_id: String in carried:
			assert_eq(client.client_state.world_items.get(item_id, {}).get("position", null), DEATH_AT, "%s lies where alice died" % item_id)
	var started: bool = await _wait(func() -> bool: return _vitals_mirror(a2).is_alive(alice_id) and _vitals_mirror(a2).character_generation() == 2 and _vitals_mirror(b2).is_alive(alice_id))
	assert_true(started, "the new character started after the restart")
	assert_eq(_world.get_player(alice_id).character_generation, 2)
	assert_eq(_carried_ids(alice_id), [])
	await _assert_mirrors_match(both, "session 2")
	assert_eq(Array(_world.inventory.world_item_ids()), carried, "nothing dropped twice, nothing lost")
	assert_eq(_world.inventory.item_count(), total)
	# What she left can be taken after the restart, too.
	if not await _pick_up(b2, [single_id]):
		return
	await _assert_mirrors_match(both, "session 2 after bob's pickup")
