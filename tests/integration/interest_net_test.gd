extends TestCase
## P3-2 (docs/09 §15.2): every client is told only about the world items and
## zombies in the cells around its own player. Real ENet, one server and
## several clients in one process, on the 500 m x 500 m test map with its
## shipped cell and interest settings (50 m cells; a peer is told about the
## cells within 2 cells of its player and keeps them up to 3 cells away).
## Players are moved through the server (its positions are the only ones
## that count), never by client input.
##
## Entities are placed before the clients join, or through the server rules
## that announce them: an item spawned straight into the inventory service
## is not announced to anybody (docs/15 P2-119).
##
## Cell lifecycle (cells leaving and entering the server's memory) is
## covered by world_cell_net_test.gd; here no cell is ever released (the
## world has no cell store), so what a client sees depends on interest only.

const WORLD: String = "interest_net_world"
const NEVER: float = 1.0e9
const WAIT_MSEC: int = 8000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 30
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const BULK: String = "p32_bulk"
const STACK_MAX: int = 5
## Three places far apart: eight cells between any two of them.
const AT_A: Vector3 = Vector3(-200.0, 0.0, -200.0)
const AT_B: Vector3 = Vector3(200.0, 0.0, -200.0)
const AT_C: Vector3 = Vector3(200.0, 0.0, 200.0)
const NEAR_A: Vector3 = Vector3(-199.0, 0.0, -199.0)
const NEAR_C: Vector3 = Vector3(199.0, 0.0, 199.0)
const MISSING_ITEM_ID: String = "item_999999"

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	network_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	network_settings.pickup_intent_burst = GENEROUS_BURST
	# from_defaults() hands out shared cached resources: replace, never edit.
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.catalog = _new_catalog()
	_config.survival = SurvivalSettings.new()
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	# Zombies stand still unless a test leads one: they see all around, follow
	# a player in sight and never get close enough to attack.
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.wander_pause_min_sec = NEVER
	_config.zombie.wander_pause_max_sec = NEVER
	_config.zombie.ai_period_sec = 0.1
	_config.zombie.sight_half_angle_deg = 180.0
	_config.zombie.attack_range_m = 0.0
	_config.zombie_net = ZombieNetSettings.new()
	_config.inventory_net = InventoryNetSettings.new()
	_config.inventory_net.drop_intent_rate_per_sec = GENEROUS_RATE
	_config.inventory_net.drop_intent_burst = GENEROUS_BURST
	# The shipped map, cells and interest area; cells are looked at every tick.
	_config.world_cells = WorldCellSettings.new()
	_config.world_cells.refresh_period_sec = 0.0
	_config.world_cells.preload_lookahead_sec = 0.0
	_config.interest = InterestSettings.new()
	_cluster = NetTestCluster.new(tree, network_settings, _config)
	_world = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _new_catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var bulk: ItemDefinition = ItemDefinition.new()
	bulk.definition_id = BULK
	bulk.max_stack = STACK_MAX
	catalog.add(bulk)
	return catalog


func _start() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


## Lets the server run some ticks so anything still in flight arrives.
func _settle() -> void:
	for tick: int in range(SETTLE_TICKS):
		await tree.physics_frame


func _join(player_key: String) -> NetworkService:
	var client: NetworkService = await _cluster.join_client(player_key)
	if client == null:
		fail("%s did not join" % player_key)
	return client


func _player_id(client: NetworkService) -> String:
	return client.client_state.local_player_id


## Puts a client's player somewhere on the server and waits until the client
## itself has seen that position (so the server looked at it since).
func _place(client: NetworkService, position: Vector3) -> void:
	var player_id: String = _player_id(client)
	_world.get_player(player_id).position = position
	await _wait(func() -> bool: return client.client_state.position_of(player_id).distance_to(position) < 0.01)
	await _settle()


func _zombies() -> ZombieService:
	return _world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _zombie_module(service: NetworkService) -> ZombieNetModule:
	return service.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule


func _mirror(service: NetworkService) -> ClientZombieState:
	return _zombie_module(service).client_state


func _inventory_module(service: NetworkService) -> InventoryNetModule:
	return service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule


## An item lying in the cell of its position, as the server rules place it.
func _spawn_item(position: Vector3, definition_id: String = "dev_test_item", quantity: int = 1) -> String:
	return _world.inventory.spawn_world_item(definition_id, quantity, _world.cell_id_at(position), position)


func _spawn_zombie(position: Vector3) -> String:
	return str(_zombies().spawn_zombie(_world, position, 0.0).event.get("zombie_id", ""))


func _item_ids(client: NetworkService) -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(client.client_state.world_items.keys())
	ids.sort()
	return ids


func _zombie_ids(client: NetworkService) -> PackedStringArray:
	var ids: PackedStringArray = _mirror(client).zombie_ids()
	ids.sort()
	return ids


func _sorted(ids: Array) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray(ids)
	result.sort()
	return result


## Every zombie event `client` receives from now on, as "type:zombie_id"
## (the returned array keeps growing).
func _zombie_events_of(client: NetworkService) -> Array[String]:
	var lines: Array[String] = []
	_mirror(client).event_received.connect(func(event: Dictionary) -> void: lines.append("%s:%s" % [str(event["event_type"]), str(event["zombie_id"])]))
	return lines


## Counts of the zombie_added / zombie_removed signals of a client's mirror,
## per zombie id: {"added": {id: n}, "removed": {id: n}}.
func _zombie_membership_of(client: NetworkService) -> Dictionary:
	var counts: Dictionary = {"added": {}, "removed": {}}
	_mirror(client).zombie_added.connect(func(zombie_id: String) -> void: counts["added"][zombie_id] = int(counts["added"].get(zombie_id, 0)) + 1)
	_mirror(client).zombie_removed.connect(func(zombie_id: String) -> void: counts["removed"][zombie_id] = int(counts["removed"].get(zombie_id, 0)) + 1)
	return counts


## How often each world item id was announced to `client` as added, from
## now on (the returned dictionary keeps growing).
func _item_adds_of(client: NetworkService) -> Dictionary:
	var counts: Dictionary = {}
	_inventory_module(client).world_items_added.connect(func(ids: PackedStringArray) -> void:
		for item_id: String in ids:
			counts[item_id] = int(counts.get(item_id, 0)) + 1)
	return counts


## Sends one pickup request and waits for its answer: [ok, reason].
func _pickup(client: NetworkService, item_id: String) -> Array:
	var rows: Array[Array] = []
	var on_result: Callable = func(_request_id: int, ok: bool, reason: String) -> void: rows.append([ok, reason])
	client.pickup_result.connect(on_result)
	client.request_pickup(item_id)
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	client.pickup_result.disconnect(on_result)
	if not answered:
		fail("the pickup request was not answered")
		return [false, "no_answer"]
	return rows[0]


## Sends one drop request and waits for its answer: [ok, reason].
func _drop(client: NetworkService, item_id: String, quantity: int) -> Array:
	var rows: Array[Array] = []
	var on_result: Callable = func(_request_id: int, ok: bool, reason: String) -> void: rows.append([ok, reason])
	_inventory_module(client).drop_result.connect(on_result)
	_inventory_module(client).request_drop(item_id, quantity)
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	_inventory_module(client).drop_result.disconnect(on_result)
	if not answered:
		fail("the drop request was not answered")
		return [false, "no_answer"]
	return rows[0]


## Three clients, each moved to its own far corner of the map.
func _join_three_far_apart() -> Array[NetworkService]:
	var clients: Array[NetworkService] = []
	for key: String in ["alice", "bob", "carol"]:
		var client: NetworkService = await _join(key)
		if client == null:
			return []
		clients.append(client)
	await _place(clients[0], AT_A)
	await _place(clients[1], AT_B)
	await _place(clients[2], AT_C)
	return clients


# ------------------------------------------------------------ world items

func test_an_item_is_mirrored_only_around_it_and_follows_a_peer_that_walks_in_and_out() -> void:
	assert_true(_start())
	var item_id: String = _spawn_item(NEAR_A)
	assert_false(item_id.is_empty())
	var clients: Array[NetworkService] = await _join_three_far_apart()
	assert_eq(clients.size(), 3)
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var b_adds: Dictionary = _item_adds_of(b)
	assert_true(await _wait(func() -> bool: return _item_ids(a) == PackedStringArray([item_id])), "the item near alice is in her mirror")
	await _settle()
	assert_eq(_item_ids(b), PackedStringArray(), "bob, 400 m away, was not told about it")
	assert_eq(_item_ids(c), PackedStringArray(), "nor carol")

	# --- bob walks in ---
	await _place(b, AT_A + Vector3(60.0, 0.0, 0.0))
	assert_true(await _wait(func() -> bool: return _item_ids(b) == PackedStringArray([item_id])), "one cell away from the item: bob has it now")
	assert_eq(b.client_state.world_items[item_id], a.client_state.world_items[item_id], "the same row alice has")
	assert_eq(b.client_state.world_items[item_id]["position"], NEAR_A)
	assert_eq(int(b_adds.get(item_id, 0)), 1, "announced once")

	# --- and out again ---
	await _place(b, AT_B)
	assert_true(await _wait(func() -> bool: return _item_ids(b).is_empty()), "back in his corner: the item left bob's mirror")
	await _settle()
	assert_eq(int(b_adds.get(item_id, 0)), 1, "and was not announced again")
	assert_eq(_item_ids(a), PackedStringArray([item_id]), "alice still has it")
	assert_eq(_item_ids(c), PackedStringArray(), "carol never had it")
	assert_eq(_world.inventory.world_item_ids(), PackedStringArray([item_id]), "the item itself never moved")
	for client: NetworkService in clients:
		assert_eq(_inventory_module(client).rejected_payload_count, 0)


func test_the_join_data_of_a_late_joiner_holds_only_what_is_around_its_player() -> void:
	assert_true(_start())
	var item_near_a: String = _spawn_item(NEAR_A)
	var item_near_c: String = _spawn_item(NEAR_C)
	var item_at_origin: String = _spawn_item(Vector3(3.0, 0.0, 3.0))
	var a: NetworkService = await _join("alice")
	var c: NetworkService = await _join("carol")
	assert_true(a != null and c != null)
	await _place(a, AT_A)
	await _place(c, AT_C)
	var zombie_near_a: String = _spawn_zombie(AT_A + Vector3(0.0, 0.0, 30.0))
	var zombie_near_c: String = _spawn_zombie(AT_C + Vector3(0.0, 0.0, -30.0))
	var zombie_at_origin: String = _spawn_zombie(Vector3(-40.0, 0.0, 10.0))
	assert_true(await _wait(func() -> bool: return _zombie_ids(a) == PackedStringArray([zombie_near_a]) and _item_ids(a) == PackedStringArray([item_near_a])), "alice was told about what is near her")
	# Carol goes away where she stands: the server keeps her position.
	_cluster.remove_client(c)
	await _settle()

	# --- she comes back: the join data is cut to her cells ---
	var c_again: NetworkService = await _join("carol")
	assert_not_null(c_again)
	assert_eq(_world.get_player(_player_id(c_again)).position, AT_C, "she is where she left")
	assert_eq(_item_ids(c_again), PackedStringArray([item_near_c]), "only the item near her came with the join")
	assert_eq(_zombie_ids(c_again), PackedStringArray([zombie_near_c]), "and only the zombie near her")
	assert_eq(_mirror(c_again).get_zombie(zombie_near_c)["position"], AT_C + Vector3(0.0, 0.0, -30.0))

	# --- a new player starts at the spawn point and sees what is there ---
	var d: NetworkService = await _join("dave")
	assert_not_null(d)
	assert_eq(_item_ids(d), PackedStringArray([item_at_origin]))
	assert_eq(_zombie_ids(d), PackedStringArray([zombie_at_origin]))
	await _settle()
	assert_eq(_item_ids(c_again), PackedStringArray([item_near_c]), "nothing else trickled in afterwards")
	assert_eq(_zombie_ids(c_again), PackedStringArray([zombie_near_c]))
	assert_eq(_item_ids(a), PackedStringArray([item_near_a]))
	assert_eq(_zombie_ids(a), PackedStringArray([zombie_near_a]))
	assert_eq(_world.inventory.world_item_ids(), _sorted([item_near_a, item_near_c, item_at_origin]))
	for client: NetworkService in [a, c_again, d]:
		assert_eq(_mirror(client).event_gap_count, 0)
		assert_eq(_mirror(client).rejected_payload_count, 0)


func test_drops_and_pickups_reach_exactly_the_peers_around_them() -> void:
	assert_true(_start())
	var stack_id: String = _spawn_item(Vector3(1.0, 0.0, 1.0), BULK, 3)
	var other_stack_id: String = _spawn_item(Vector3(1.0, 0.0, 0.5), BULK, 2)
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	var d: NetworkService = await _join("dave")
	assert_true(a != null and b != null and d != null)
	# Alice and dave each pick a stack up at the spawn point, then walk to
	# alice's corner together; bob goes to his own.
	assert_eq(await _pickup(a, stack_id), [true, ""])
	assert_eq(await _pickup(d, other_stack_id), [true, ""])
	await _place(a, AT_A)
	await _place(d, AT_A + Vector3(1.0, 0.0, 0.0))
	await _place(b, AT_B)
	var b_adds: Dictionary = _item_adds_of(b)
	var b_most_items: Array[int] = [0]
	b.client_state.changed.connect(func() -> void: b_most_items[0] = maxi(b_most_items[0], b.client_state.world_items.size()))

	# --- a part of a stack is put down: a new item for the two who are there ---
	assert_eq(await _drop(a, stack_id, 1), [true, ""])
	assert_true(await _wait(func() -> bool: return _item_ids(a).size() == 1 and _item_ids(d) == _item_ids(a)), "alice and dave both see the unit on the ground")
	var lying_id: String = _item_ids(a)[0]
	assert_ne(lying_id, stack_id, "a part of a stack is a new item")
	assert_eq(int(a.client_state.world_items[lying_id]["quantity"]), 1)
	assert_eq(d.client_state.world_items[lying_id], a.client_state.world_items[lying_id])
	assert_eq(int(a.client_state.get_inventory_item(stack_id)["quantity"]), 2, "alice's own stack got smaller")

	# --- the whole rest of the stack too ---
	assert_eq(await _drop(a, stack_id, InventoryService.WHOLE_STACK), [true, ""])
	assert_true(await _wait(func() -> bool: return _item_ids(a) == _sorted([lying_id, stack_id]) and _item_ids(d) == _item_ids(a)))
	assert_false(a.client_state.has_inventory_item(stack_id))

	# --- dave picks both up: they merge into the stack he carries ---
	assert_eq(await _pickup(d, lying_id), [true, ""])
	assert_eq(await _pickup(d, stack_id), [true, ""])
	assert_true(await _wait(func() -> bool: return _item_ids(a).is_empty() and _item_ids(d).is_empty()), "both saw the items go")
	assert_eq(int(d.client_state.get_inventory_item(other_stack_id)["quantity"]), 5, "2 + 1 + 2 units in dave's stack")
	assert_false(d.client_state.has_inventory_item(lying_id), "the merged item is gone, not carried")
	await _settle()

	# --- bob, far away, was told nothing at all about any of it ---
	assert_eq(b_adds.size(), 0, "no world item was announced to bob: %s" % str(b_adds))
	assert_eq(b_most_items[0], 0, "and his mirror never held one")
	assert_eq(_item_ids(b), PackedStringArray())
	assert_eq(_world.inventory.world_item_ids(), PackedStringArray())
	for client: NetworkService in [a, b, d]:
		assert_eq(_inventory_module(client).rejected_payload_count, 0)


func test_what_a_dead_player_leaves_behind_is_seen_where_it_lies() -> void:
	assert_true(_start())
	var stack_id: String = _spawn_item(Vector3(1.0, 0.0, 1.0), BULK, 3)
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	var d: NetworkService = await _join("dave")
	assert_true(a != null and b != null and d != null)
	assert_eq(await _pickup(a, stack_id), [true, ""])
	await _place(a, AT_A)
	await _place(d, AT_A + Vector3(1.0, 0.0, 0.0))
	await _place(b, AT_B)
	# The server rule of a death (ServerWorld.drop_all_player_items).
	assert_true(_world.drop_all_player_items(_player_id(a)).ok)
	assert_true(await _wait(func() -> bool: return _item_ids(a) == PackedStringArray([stack_id]) and _item_ids(d) == PackedStringArray([stack_id])), "alice and dave see what she dropped")
	assert_eq(a.client_state.world_items[stack_id]["position"], AT_A)
	assert_false(a.client_state.has_inventory_item(stack_id))
	await _settle()
	assert_eq(_item_ids(b), PackedStringArray(), "bob does not")


# ------------------------------------------------------------ zombies

func test_zombie_snapshots_and_events_reach_only_the_peers_around_the_zombie() -> void:
	_config.zombie.corpse_remove_delay_sec = 0.5
	assert_true(_start())
	var clients: Array[NetworkService] = await _join_three_far_apart()
	assert_eq(clients.size(), 3)
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var a_events: Array[String] = _zombie_events_of(a)
	var b_events: Array[String] = _zombie_events_of(b)
	var c_events: Array[String] = _zombie_events_of(c)
	# One zombie near alice, one near carol; nothing near bob.
	var near_a: String = _spawn_zombie(AT_A + Vector3(0.0, 0.0, 30.0))
	var near_c: String = _spawn_zombie(AT_C + Vector3(0.0, 0.0, -30.0))
	assert_true(await _wait(func() -> bool: return _zombie_ids(a) == PackedStringArray([near_a]) and _zombie_ids(c) == PackedStringArray([near_c])))
	# The zombie near alice is hurt and killed by server rules, then its
	# corpse is cleared away.
	assert_true(_zombies().apply_damage_to_zombie(near_a, 25.0, "test_source").ok)
	assert_true(await _wait(func() -> bool: return is_equal_approx(float(_mirror(a).get_zombie(near_a).get("health_fraction", 1.0)), 0.75)), "alice sees its health in the next snapshot")
	assert_true(_zombies().apply_damage_to_zombie(near_a, 1000.0, "test_source").ok)
	assert_true(await _wait(func() -> bool: return not _mirror(a).has_zombie(near_a)), "the corpse is gone from alice's mirror")
	await _settle()
	assert_eq(PackedStringArray(a_events), PackedStringArray([
		"zombie_spawned:" + near_a,
		"zombie_damaged:" + near_a,
		"zombie_damaged:" + near_a,
		"zombie_died:" + near_a,
		"zombie_removed:" + near_a,
	]), "alice got the whole story of her zombie, in order")
	assert_eq(PackedStringArray(c_events), PackedStringArray(["zombie_spawned:" + near_c]), "carol only that of hers")
	assert_eq(PackedStringArray(b_events), PackedStringArray(), "bob got no zombie event at all")
	assert_eq(_zombie_ids(b), PackedStringArray(), "and has no zombie")
	assert_eq(_zombie_ids(c), PackedStringArray([near_c]), "carol never had alice's zombie")
	assert_eq(_mirror(c).get_zombie(near_c)["position"], AT_C + Vector3(0.0, 0.0, -30.0))
	for client: NetworkService in clients:
		assert_eq(_mirror(client).event_gap_count, 0, "every client's event stream is whole")
		assert_eq(_mirror(client).rejected_payload_count, 0)


func test_a_zombie_that_crosses_an_interest_border_appears_and_disappears_once() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	assert_true(a != null and b != null)
	# Bob stands in cell -2: he is told about the cells -4..0 on x, so the
	# border of his area is x = 50 (between cell 0 and cell 1). He arrives
	# from far away: coming straight from the spawn point he would still
	# keep cell 1, which is within the keep radius. Alice, the bait, stands
	# in cell 0 and is told about both sides of that border.
	await _place(b, AT_C)
	await _place(b, Vector3(-75.0, 0.0, 25.0))
	await _place(a, Vector3(44.0, 0.0, 25.0))
	var a_membership: Dictionary = _zombie_membership_of(a)
	var b_membership: Dictionary = _zombie_membership_of(b)
	var b_events: Array[String] = _zombie_events_of(b)
	var zombie_id: String = _spawn_zombie(Vector3(58.0, 0.0, 25.0))
	assert_true(await _wait(func() -> bool: return _mirror(a).has_zombie(zombie_id)), "alice sees it from the start")
	assert_false(_mirror(b).has_zombie(zombie_id), "it spawned outside bob's cells")

	# --- it walks after alice, into a cell bob is told about ---
	assert_true(await _wait(func() -> bool: return _zombies().get_zombie(zombie_id).position.x < 49.0), "the zombie crossed the border on the server")
	assert_true(await _wait(func() -> bool: return _mirror(b).has_zombie(zombie_id)), "and appeared on bob's side")
	assert_true(await _wait(func() -> bool: return str(_mirror(b).get_zombie(zombie_id).get("state", "")) == "chase"), "as what it is: chasing")
	assert_true((_mirror(b).get_zombie(zombie_id)["position"] as Vector3).x < 50.5, "where it is")

	# --- alice leads it back out ---
	_world.get_player(_player_id(a)).position = Vector3(64.0, 0.0, 25.0)
	assert_true(await _wait(func() -> bool: return _zombies().get_zombie(zombie_id).position.x > 51.0), "the zombie crossed back")
	assert_true(await _wait(func() -> bool: return not _mirror(b).has_zombie(zombie_id)), "and disappeared for bob")
	await _settle()

	assert_eq(int(b_membership["added"].get(zombie_id, 0)), 1, "it appeared once")
	assert_eq(int(b_membership["removed"].get(zombie_id, 0)), 1, "and disappeared once")
	assert_eq(int(a_membership["added"].get(zombie_id, 0)), 1, "alice had it all along: no second copy")
	assert_eq(int(a_membership["removed"].get(zombie_id, 0)), 0, "and it never left her mirror")
	assert_eq(_mirror(a).zombie_count(), 1)
	assert_eq(_mirror(b).zombie_count(), 0, "no ghost stays behind")
	assert_true(_zombies().has_zombie(zombie_id), "the zombie itself is still in the world")
	assert_false(b_events.has("zombie_spawned:" + zombie_id), "bob was never told it was spawned: %s" % str(b_events))
	assert_false(b_events.has("zombie_removed:" + zombie_id), "nor that it was removed from the world")
	for client: NetworkService in [a, b]:
		assert_eq(_mirror(client).event_gap_count, 0)
		assert_eq(_mirror(client).rejected_payload_count, 0)


# ------------------------------------------------------------ trust

func test_a_forged_pickup_of_an_item_outside_the_peers_cells_reveals_nothing() -> void:
	assert_true(_start())
	var carried_id: String = _spawn_item(Vector3(1.0, 0.0, 1.0), BULK, 2)
	var far_id: String = _spawn_item(NEAR_A)
	var near_but_out_of_reach_id: String = _spawn_item(AT_B + Vector3(20.0, 0.0, 0.0))
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	assert_true(a != null and b != null)
	assert_eq(await _pickup(a, carried_id), [true, ""])
	await _place(a, AT_A)
	await _place(b, AT_B)
	assert_true(await _wait(func() -> bool: return _item_ids(b) == PackedStringArray([near_but_out_of_reach_id])), "bob knows the item 20 m from him and nothing else")
	var server: NetworkService = _cluster.server
	var b_adds: Dictionary = _item_adds_of(b)

	# Bob asks for an item id he was never told (alice's corner of the map),
	# for an item somebody carries and for an id that does not exist.
	var answer_far: Array = await _pickup(b, far_id)
	var answer_carried: Array = await _pickup(b, carried_id)
	var answer_missing: Array = await _pickup(b, MISSING_ITEM_ID)
	assert_eq(answer_far, [false, InventoryService.REASON_NOT_IN_WORLD], "an item outside his cells")
	assert_eq(answer_carried, answer_far, "reads exactly like an item somebody carries")
	assert_eq(answer_missing, answer_far, "and like an id that does not exist")
	# The server judged each by its own rules and remembers the real reason.
	assert_eq(server.rejected_intent_count(InventoryService.REASON_TOO_FAR), 1, "the far item was simply out of reach")
	assert_eq(server.rejected_intent_count(InventoryService.REASON_NOT_IN_WORLD), 1)
	assert_eq(server.rejected_intent_count(InventoryService.REASON_UNKNOWN_ITEM), 1)
	# An item he IS told about keeps its plain answer.
	assert_eq(await _pickup(b, near_but_out_of_reach_id), [false, InventoryService.REASON_TOO_FAR], "what he can see he may be told is too far")
	await _settle()
	assert_eq(_item_ids(b), PackedStringArray([near_but_out_of_reach_id]), "bob's mirror is what it was")
	assert_eq(b_adds.size(), 0, "no world item message reached him")
	assert_eq(_item_ids(a), PackedStringArray([far_id]), "alice's item is where it was")
	assert_eq(_world.inventory.world_item_ids(), _sorted([far_id, near_but_out_of_reach_id]), "nothing moved on the server")
	assert_true(a.client_state.has_inventory_item(carried_id))
	assert_eq(_world.inventory.items_in_inventory(_world.get_player(_player_id(b)).inventory_id).size(), 0)


# ------------------------------------------------------------ agreement

func test_two_clients_standing_together_agree_on_what_they_see() -> void:
	assert_true(_start())
	var scattered_items: PackedStringArray = []
	var scattered_zombies: PackedStringArray = []
	# A row of items and zombies from alice's corner to bob's, every 40 m.
	for step: int in range(11):
		var position: Vector3 = Vector3(-200.0 + 40.0 * float(step), 0.0, -190.0)
		scattered_items.append(_spawn_item(position))
		scattered_zombies.append(_spawn_zombie(position + Vector3(0.0, 0.0, -40.0)))
	var a: NetworkService = await _join("alice")
	var d: NetworkService = await _join("dave")
	var b: NetworkService = await _join("bob")
	assert_true(a != null and d != null and b != null)
	# Alice and dave arrive from the far corner, so nothing they pass on the
	# way is still within their keep radius.
	await _place(a, AT_C)
	await _place(d, AT_C)
	await _place(a, AT_A)
	await _place(d, AT_A + Vector3(2.0, 0.0, 0.0))
	await _place(b, AT_B)
	assert_true(await _wait(func() -> bool: return _item_ids(a).size() == 4 and _item_ids(d) == _item_ids(a)), "both see the same items: %s / %s" % [str(_item_ids(a)), str(_item_ids(d))])
	assert_true(await _wait(func() -> bool: return _zombie_ids(a).size() == 4 and _zombie_ids(d) == _zombie_ids(a)), "and the same zombies")
	# x = -200 .. -80: the cells -4, -3 and -2 on x (alice is in cell -4).
	assert_eq(_item_ids(a), _sorted([scattered_items[0], scattered_items[1], scattered_items[2], scattered_items[3]]))
	assert_eq(_zombie_ids(a), _sorted([scattered_zombies[0], scattered_zombies[1], scattered_zombies[2], scattered_zombies[3]]))
	for item_id: String in _item_ids(a):
		assert_eq(d.client_state.world_items[item_id], a.client_state.world_items[item_id])
	for zombie_id: String in _zombie_ids(a):
		assert_eq(_mirror(d).get_zombie(zombie_id), _mirror(a).get_zombie(zombie_id))
	# Bob sees the other end of the row: x = 120 .. 200, the cells 2, 3 and 4.
	assert_true(await _wait(func() -> bool: return _item_ids(b).size() == 3 and _zombie_ids(b).size() == 3))
	assert_eq(_item_ids(b), _sorted([scattered_items[8], scattered_items[9], scattered_items[10]]))
	assert_eq(_zombie_ids(b), _sorted([scattered_zombies[8], scattered_zombies[9], scattered_zombies[10]]))
	# Nobody sees the middle.
	for index: int in [4, 5, 6, 7]:
		for client: NetworkService in [a, b, d]:
			assert_false(client.client_state.world_items.has(scattered_items[index]))
			assert_false(_mirror(client).has_zombie(scattered_zombies[index]))


# ------------------------------------------------------------ combat events

func _combat_module(service: NetworkService) -> CombatNetModule:
	return service.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule


## One exact weapon for everybody: 40 damage, 2 m reach, no cooldown.
func _use_test_weapon() -> void:
	var weapon: MeleeWeaponDefinition = MeleeWeaponDefinition.new()
	weapon.weapon_id = "unarmed"
	weapon.display_name = "unarmed"
	weapon.category = MeleeWeaponDefinition.Category.UNARMED
	weapon.base_damage = 40.0
	weapon.range_m = 2.0
	weapon.arc_angle_deg = 90.0
	weapon.cooldown_sec = 0.0
	weapon.stamina_cost = 0.0
	weapon.noise_loudness = 0.0
	_config.combat = CombatSettings.new()
	_config.combat.damage_roll_min = 1.0
	_config.combat.damage_roll_max = 1.0
	_config.combat.inventory_weapon_rule = CombatSettings.WeaponRule.UNARMED_ONLY
	_config.melee_weapons = MeleeWeaponCatalog.new()
	_config.melee_weapons.add(weapon)
	_config.combat_net = CombatNetSettings.new()
	_config.combat_net.melee_intent_rate_per_sec = GENEROUS_RATE
	_config.combat_net.melee_intent_burst = GENEROUS_BURST
	_config.survival.stamina_regen_per_sec = 0.0


## Every combat event `client` receives from now on (the array keeps growing).
func _combat_events_of(client: NetworkService) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_combat_module(client).combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	return events


## Sends one melee request and waits for its answer: [ok, reason].
func _swing(client: NetworkService, aim_yaw: float) -> Array:
	var rows: Array[Array] = []
	var on_result: Callable = func(_request_id: int, ok: bool, reason: String) -> void: rows.append([ok, reason])
	_combat_module(client).melee_result.connect(on_result)
	_combat_module(client).request_melee_attack(aim_yaw)
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	_combat_module(client).melee_result.disconnect(on_result)
	if not answered:
		fail("the melee request was not answered")
		return [false, "no_answer"]
	return rows[0]


func test_a_swing_reaches_the_attacker_and_the_peers_that_know_what_it_hit() -> void:
	_use_test_weapon()
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	var d: NetworkService = await _join("dave")
	var b: NetworkService = await _join("bob")
	assert_true(a != null and d != null and b != null)
	await _place(a, AT_A)
	await _place(d, AT_A + Vector3(3.0, 0.0, 0.0))
	await _place(b, AT_B)
	# A zombie right in front of alice (yaw 0 faces -z).
	var zombie_id: String = _spawn_zombie(AT_A + Vector3(0.0, 0.0, -1.5))
	assert_true(await _wait(func() -> bool: return _mirror(a).has_zombie(zombie_id) and _mirror(d).has_zombie(zombie_id)))
	var a_events: Array[Dictionary] = _combat_events_of(a)
	var d_events: Array[Dictionary] = _combat_events_of(d)
	var b_events: Array[Dictionary] = _combat_events_of(b)
	var b_zombie_events: Array[String] = _zombie_events_of(b)

	# --- a hit: for alice and for dave, who both know the zombie ---
	assert_eq(await _swing(a, 0.0), [true, ""])
	assert_true(await _wait(func() -> bool: return a_events.size() == 1 and d_events.size() == 1), "the attacker and the bystander both got the swing")
	assert_true(bool(a_events[0]["hit"]))
	assert_eq(a_events[0]["target_id"], zombie_id)
	assert_eq(a_events[0]["attacker_id"], _player_id(a))
	assert_eq(d_events[0], a_events[0], "the same event")
	assert_true(await _wait(func() -> bool: return is_equal_approx(float(_mirror(d).get_zombie(zombie_id).get("health_fraction", 1.0)), 0.6)), "and the health of the zombie follows")

	# --- a miss names no zombie: it goes to who is told about the cell alice is in ---
	assert_eq(await _swing(a, PI), [true, ""])
	assert_true(await _wait(func() -> bool: return a_events.size() == 2 and d_events.size() == 2))
	assert_false(bool(a_events[1]["hit"]))
	assert_eq(d_events[1], a_events[1])

	# --- bob swings at nothing in his corner: his own action is his to see ---
	assert_eq(await _swing(b, 0.0), [true, ""])
	assert_true(await _wait(func() -> bool: return b_events.size() == 1), "bob got the result of his own swing")
	assert_eq(b_events[0]["attacker_id"], _player_id(b))
	assert_false(bool(b_events[0]["hit"]))
	await _settle()
	assert_eq(b_events.size(), 1, "and nothing about the fight 400 m away")
	assert_eq(a_events.size(), 2, "alice heard nothing of the swing bob made")
	assert_eq(d_events.size(), 2)
	assert_eq(b_zombie_events.size(), 0, "bob got no zombie event either: %s" % str(b_zombie_events))
	assert_false(_mirror(b).has_zombie(zombie_id))
	# Sequence numbers are the server's: a far client sees holes, never a step back.
	assert_eq(int(b_events[0]["sequence"]), 3)
	assert_eq(_combat_module(b).last_event_sequence(), 3)
	assert_eq(_combat_module(a).last_event_sequence(), 2)
	for client: NetworkService in [a, b, d]:
		assert_eq(_combat_module(client).rejected_event_count, 0)


# ------------------------------------------------------------ told on purpose

func test_a_peer_told_about_a_zombie_outside_its_cells_gets_it_once_and_loses_it_again() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	assert_true(a != null and b != null)
	await _place(a, AT_A)
	await _place(b, AT_B)
	var zombie_id: String = _spawn_zombie(AT_A + Vector3(0.0, 0.0, 30.0))
	assert_true(_zombies().apply_damage_to_zombie(zombie_id, 25.0, "test_source").ok)
	assert_true(await _wait(func() -> bool: return _mirror(a).has_zombie(zombie_id)))
	await _settle()
	assert_false(_mirror(b).has_zombie(zombie_id))
	var server_module: ZombieNetModule = _zombie_module(_cluster.server)
	var b_peer: int = _cluster.server.peer_of_player(_player_id(b))
	var a_peer: int = _cluster.server.peer_of_player(_player_id(a))
	assert_true(server_module.knows_zombie(a_peer, zombie_id))
	assert_false(server_module.knows_zombie(b_peer, zombie_id))
	var b_membership: Dictionary = _zombie_membership_of(b)
	var b_events: Array[String] = _zombie_events_of(b)
	var seen_as: Array[Dictionary] = []
	_mirror(b).zombie_added.connect(func(added_id: String) -> void: seen_as.append(_mirror(b).get_zombie(added_id).duplicate()))

	# What a module does before it sends bob a message that names the zombie
	# (the player a zombie hit, the attacker of a zombie): bob is told first.
	assert_true(server_module.ensure_known(b_peer, zombie_id))
	assert_true(await _wait(func() -> bool: return int(b_membership["added"].get(zombie_id, 0)) == 1), "bob was told about the zombie")
	assert_eq(seen_as.size(), 1)
	assert_true(is_equal_approx(float(seen_as[0]["health_fraction"]), 0.75), "as it is: hurt")
	assert_eq(seen_as[0]["position"], AT_A + Vector3(0.0, 0.0, 30.0))
	assert_eq(server_module.forced_known_count, 1)
	# It is not in his cells: the next reconciliation takes it away again.
	assert_true(await _wait(func() -> bool: return int(b_membership["removed"].get(zombie_id, 0)) == 1), "and it left his mirror again")
	await _settle()
	assert_eq(PackedStringArray(b_events), PackedStringArray(["zombie_entered:" + zombie_id, "zombie_left:" + zombie_id]))
	assert_eq(int(b_membership["added"].get(zombie_id, 0)), 1, "once in")
	assert_eq(int(b_membership["removed"].get(zombie_id, 0)), 1, "once out")
	assert_false(server_module.knows_zombie(b_peer, zombie_id))
	assert_eq(_mirror(b).zombie_count(), 0, "no ghost")
	assert_true(_mirror(a).has_zombie(zombie_id), "alice never lost it")
	# Asking again for a peer that knows the zombie, or for nothing real, does nothing.
	assert_true(server_module.ensure_known(a_peer, zombie_id))
	assert_false(server_module.ensure_known(b_peer, "zombie_999999"))
	assert_false(server_module.ensure_known(987654, zombie_id))
	assert_eq(server_module.forced_known_count, 1)
	for client: NetworkService in [a, b]:
		assert_eq(_mirror(client).event_gap_count, 0)
		assert_eq(_mirror(client).rejected_payload_count, 0)


func test_a_player_hit_by_a_zombie_outside_its_cells_is_told_who_hit_it() -> void:
	# An interest area of one cell (far smaller than the shipped one): a zombie
	# can then stand across a cell border, outside the area, and still reach.
	_config.interest.interest_radius_cells = 0
	_config.interest.keep_margin_cells = 0
	_config.zombie.attack_range_m = 1.5
	_config.zombie.attack_windup_sec = 0.1
	_config.zombie.attack_cooldown_sec = 0.3
	_config.zombie.bite_damage = 1.0
	_config.zombie.scratch_damage = 1.0
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	var d: NetworkService = await _join("dave")
	assert_true(a != null and d != null)
	# Alice stands half a metre from the border of her cell; dave in the same
	# cell, ten metres further in.
	await _place(a, Vector3(49.5, 0.0, 25.0))
	await _place(d, Vector3(39.0, 0.0, 25.0))
	var a_events: Array[Dictionary] = []
	_mirror(a).event_received.connect(func(event: Dictionary) -> void: a_events.append(event))
	var d_events: Array[String] = _zombie_events_of(d)
	# The zombie is one metre from alice, in the next cell.
	var zombie_id: String = _spawn_zombie(Vector3(50.5, 0.0, 25.0))
	assert_eq(_world.cell_index.cell_of(zombie_id), "cell_1_0")
	var hit: Callable = func() -> bool:
		for event: Dictionary in a_events:
			if event["event_type"] == ZombieService.EVENT_ATTACKED:
				return true
		return false
	assert_true(await _wait(hit), "alice was told that she was hit")
	await _settle()

	# Alice was never sent an event about a zombie she had not been told about:
	# whenever something about it reached her, it had entered her mirror first.
	var known: bool = false
	var attacks: int = 0
	for event: Dictionary in a_events:
		assert_eq(event["zombie_id"], zombie_id)
		match str(event["event_type"]):
			ZombieNetProtocol.EVENT_ENTERED:
				known = true
			ZombieNetProtocol.EVENT_LEFT:
				known = false
			_:
				assert_true(known, "%s arrived while the zombie was in her mirror" % str(event["event_type"]))
		if event["event_type"] == ZombieService.EVENT_ATTACKED:
			attacks += 1
			assert_eq(event["target_id"], _player_id(a))
			assert_true(event.has("infection"), "with her own infection result")
	assert_true(attacks >= 1)
	assert_eq(str(a_events[0]["event_type"]), ZombieNetProtocol.EVENT_ENTERED, "first of all she was told about the zombie")
	assert_true(_zombie_module(_cluster.server).forced_known_count >= 1)
	# Dave, who was not hit and is not told about that cell, heard nothing.
	assert_eq(PackedStringArray(d_events), PackedStringArray(), "the bystander got no zombie event")
	assert_false(_mirror(d).has_zombie(zombie_id))
	for client: NetworkService in [a, d]:
		assert_eq(_mirror(client).event_gap_count, 0)
		assert_eq(_mirror(client).rejected_payload_count, 0)


# ------------------------------------------------------------ no character yet

func test_a_joined_player_without_a_character_is_told_nothing_until_it_enters_the_world() -> void:
	_config.require_character_creation = true
	assert_true(_start())
	var item_id: String = _spawn_item(Vector3(3.0, 0.0, 3.0))
	var zombie_id: String = _spawn_zombie(Vector3(-40.0, 0.0, 10.0))
	# Bob is in the world at the spawn point, so its cells are in the server's
	# memory: what alice is not told is not told because she has no character.
	var b: NetworkService = await _join("bob")
	assert_not_null(b)
	var bob_answers: Array[bool] = []
	var bob_module: CharacterNetModule = b.get_module(CharacterNetModule.MODULE_NAME) as CharacterNetModule
	bob_module.create_result.connect(func(_request_id: int, ok: bool, _reason: String) -> void: bob_answers.append(ok))
	bob_module.request_create_character("Bob", {})
	assert_true(await _wait(func() -> bool: return bob_answers.size() == 1 and bob_answers[0] and _item_ids(b) == PackedStringArray([item_id])), "bob has a character and sees the item")
	# Watched from before the join: the most the mirrors ever hold.
	var a: NetworkService = _cluster.add_client("alice", false)
	var most: Array[int] = [0, 0]
	a.client_state.changed.connect(func() -> void: most[0] = maxi(most[0], a.client_state.world_items.size()))
	_mirror(a).changed.connect(func() -> void: most[1] = maxi(most[1], _mirror(a).zombie_count()))
	await _settle()
	a.send_join_request(BuildInfo.PROTOCOL_VERSION, BuildInfo.game_version(), "alice")
	assert_true(await _wait(func() -> bool: return not _player_id(a).is_empty()), "alice joined")
	var a_adds: Dictionary = _item_adds_of(a)
	var a_membership: Dictionary = _zombie_membership_of(a)
	await _settle()
	assert_false(_world.is_online(_player_id(a)), "alice is connected but not in the world")
	assert_eq(_item_ids(a), PackedStringArray(), "no character, no cells: no item")
	assert_eq(_zombie_ids(a), PackedStringArray(), "and no zombie")
	assert_eq(most, [0, 0] as Array[int], "not even in the join data: her mirrors never held anything")
	assert_eq(_cluster.server.cell_interest.cell_count_of(_cluster.server.peer_of_player(_player_id(a))), 0)
	var map: ClientWorldMap = (a.get_module(WorldCellNetModule.MODULE_NAME) as WorldCellNetModule).client_map
	assert_true(map.is_known(), "the map layout is no secret: it came with the join")

	# --- she creates her character and enters the world at the spawn point ---
	var character_module: CharacterNetModule = a.get_module(CharacterNetModule.MODULE_NAME) as CharacterNetModule
	var answers: Array[bool] = []
	character_module.create_result.connect(func(_request_id: int, ok: bool, _reason: String) -> void: answers.append(ok))
	assert_ne(character_module.request_create_character("Alice", {}), CharacterNetModule.NO_REQUEST)
	assert_true(await _wait(func() -> bool: return answers.size() == 1 and answers[0]), "the character was created")
	assert_true(await _wait(func() -> bool: return _item_ids(a) == PackedStringArray([item_id]) and _zombie_ids(a) == PackedStringArray([zombie_id])), "now she is told what is around the spawn point")
	await _settle()
	assert_eq(int(a_adds.get(item_id, 0)), 1, "the item was announced once")
	assert_eq(int(a_membership["added"].get(zombie_id, 0)), 1, "the zombie appeared once")
	assert_eq(_cluster.server.cell_interest.cell_count_of(_cluster.server.peer_of_player(_player_id(a))), 25)
	assert_eq(_mirror(a).event_gap_count, 0)


# ------------------------------------------------------------ map layout

func test_the_client_learns_the_map_layout_from_the_server_it_joined() -> void:
	# Not the shipped map: 25 m cells on a 250 m x 150 m rectangle.
	_config.world_cells.cell_size_m = 25.0
	_config.world_cells.bounds_min_m = Vector2(-100.0, -50.0)
	_config.world_cells.bounds_max_m = Vector2(150.0, 100.0)
	_config.gameplay.world_half_extent_m = 50.0
	assert_true(_start())
	var waiting: NetworkService = _cluster.add_client("alice", false)
	var map: ClientWorldMap = (waiting.get_module(WorldCellNetModule.MODULE_NAME) as WorldCellNetModule).client_map
	await _settle()
	assert_false(map.is_known(), "nothing is known before the join: the client has no map of its own")
	assert_eq(map.cell_id_at(Vector3.ZERO), "")
	waiting.send_join_request(BuildInfo.PROTOCOL_VERSION, BuildInfo.game_version(), "alice")
	assert_true(await _wait(func() -> bool: return not waiting.client_state.local_player_id.is_empty()), "alice joined")
	assert_true(map.is_known(), "the layout came with the join snapshot")
	assert_eq(map.cell_size_m, 25.0)
	assert_eq(map.bounds_min, Vector2(-100.0, -50.0))
	assert_eq(map.bounds_max, Vector2(150.0, 100.0))
	assert_eq(map.grid.signature(), _world.cell_grid.signature(), "the grid of the client is the grid of the server")
	assert_ne(map.cell_size_m, WorldCellSettings.load_or_default().cell_size_m, "and not the grid of the settings file the client has")
	for position: Vector3 in [Vector3(0.0, 0.0, 0.0), Vector3(-30.0, 0.0, 49.0), Vector3(37.5, 0.0, -12.5)]:
		assert_eq(map.cell_id_at(position), _world.cell_id_at(position), "both name the same cell at %s" % str(position))
	assert_eq((waiting.get_module(WorldCellNetModule.MODULE_NAME) as WorldCellNetModule).rejected_fragment_count, 0)
