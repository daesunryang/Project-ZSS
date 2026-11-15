extends TestCase
## P2-T2: inventory change replication over real ENet (server + 2 clients).
## A client only asks ("drop this item"); the server decides with its own
## state and position, everyone sees the item appear in the world, only the
## owner sees the inventory change, and manipulated or forged messages change
## nothing. Server-side "drop everything" and "remove" reach the mirrors too.

const WORLD: String = "inventory_net_test_world"
const NEVER: float = 1.0e9
const SINGLE: String = "t2_single"
const STACK: String = "t2_stack"
const STACK_MAX: int = 10
const CELL: String = DevWorldSeed.DEV_CELL_ID
## Players spawn at the origin; every position here is within pickup range
## (2.5 m) of it and of the others.
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const OTHER_ITEM_AT: Vector3 = Vector3(-0.5, 0.0, 1.0)
const ALICE_AT: Vector3 = Vector3(1.5, 0.0, -1.0)
const WAIT_MSEC: int = 5000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
## Real time given to the clients to put their requests on the wire while
## the server is not reading (same-tick test).
const CLIENT_FLUSH_MSEC: int = 150
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const LETHAL_DAMAGE: float = 100000.0
const FORGED_REQUEST_ID: int = 77
const MISSING_ITEM_ID: String = "item_999999"

var _cluster: NetTestCluster = null
var _net_settings: NetworkSettings = null
var _inventory_net: InventoryNetSettings = null
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
	_inventory_net = InventoryNetSettings.new()
	_inventory_net.drop_intent_rate_per_sec = GENEROUS_RATE
	_inventory_net.drop_intent_burst = GENEROUS_BURST
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.catalog = _new_catalog()
	# Survival time rules are off: no regeneration, healing or respawn.
	_config.survival = SurvivalSettings.new()
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.wound_recovery_per_world_sec = 0.0
	_config.survival.stamina_regen_per_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	# No zombies.
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.inventory_net = _inventory_net
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	_world = null


func after_each() -> void:
	Engine.print_error_messages = true
	tree.multiplayer_poll = true
	if _cluster != null:
		await _cluster.shutdown()
	if not _save_root.is_empty():
		SaveService.remove_tree(_save_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## The shipped item definitions plus a single item and a stackable one.
func _new_catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var single: ItemDefinition = ItemDefinition.new()
	single.definition_id = SINGLE
	single.max_stack = 1
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


## Joins "alice" and "bob" (after the test placed its items, so they arrive
## in the join snapshot). Empty on failure.
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


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _spawn(definition_id: String = SINGLE, quantity: int = 1, position: Vector3 = ITEM_AT) -> String:
	return _world.inventory.spawn_world_item(definition_id, quantity, CELL, position)


## Rows [request_id, ok, reason] of every drop result of `service`.
func _drop_results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).drop_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## request_id -> [ok, reason] of every pickup result of `service`.
func _pickup_results_of(service: NetworkService) -> Dictionary:
	var results: Dictionary = {}
	service.pickup_result.connect(func(request_id: int, ok: bool, reason: String) -> void: results[request_id] = [ok, reason])
	return results


## Rows [signal name, payload] of the module's mirror signals of `service`.
func _mirror_signals_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	var module: InventoryNetModule = _module(service)
	module.world_items_added.connect(func(ids: PackedStringArray) -> void: rows.append(["world_items_added", Array(ids)]))
	module.inventory_items_removed.connect(func(ids: PackedStringArray) -> void: rows.append(["inventory_items_removed", Array(ids)]))
	module.inventory_item_changed.connect(func(item_id: String) -> void: rows.append(["inventory_item_changed", item_id]))
	return rows


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


## Every item id is mirrored in exactly one place, and the mirrors together
## hold exactly the items the server has.
func _assert_conserved(clients: Array[NetworkService], expected_count: int, label: String) -> void:
	assert_eq(_world.inventory.item_count(), expected_count, label + ": server item count")
	var seen: Dictionary = {}
	for item_id: String in clients[0].client_state.world_items:
		seen[item_id] = 1
	for client: NetworkService in clients:
		for entry: Dictionary in client.client_state.inventory:
			var item_id: String = str(entry["item_instance_id"])
			seen[item_id] = int(seen.get(item_id, 0)) + 1
	assert_eq(seen.size(), expected_count, label + ": mirrored item count")
	for item_id: Variant in seen:
		assert_eq(seen[item_id], 1, "%s: %s is mirrored in one place" % [label, str(item_id)])


## Picks up `item_ids` through the real pickup RPC and waits for the mirror.
func _pick_up(client: NetworkService, item_ids: Array) -> bool:
	var results: Dictionary = _pickup_results_of(client)
	var requests: Array[int] = []
	for item_id: String in item_ids:
		requests.append(client.request_pickup(item_id))
	var done: bool = await _wait(func() -> bool:
		for request: int in requests:
			if not results.has(request):
				return false
		for item_id: String in item_ids:
			if not client.client_state.has_inventory_item(item_id):
				return false
		return true)
	if not done:
		fail("test setup: pickup of %s failed: %s" % [str(item_ids), str(results)])
	return done


func _inventory_ids(player_id: String) -> Array:
	var ids: Array = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		ids.append(item.item_instance_id)
	return ids


# ------------------------------------------------------------ 1. pick up, drop, pick up

func test_a_dropped_item_appears_for_everyone_at_the_server_position_and_can_be_picked_up() -> void:
	assert_true(_start_server(), "server started")
	var item_id: String = _spawn(STACK, 4)
	var bystander_id: String = _spawn(SINGLE, 1, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var total: int = _world.inventory.item_count()
	await _assert_mirrors_match(clients, "start")
	var a_drops: Array[Array] = _drop_results_of(a)
	var b_drops: Array[Array] = _drop_results_of(b)
	var a_signals: Array[Array] = _mirror_signals_of(a)
	var b_signals: Array[Array] = _mirror_signals_of(b)

	# Alice picks the item up, then stands somewhere else (server position).
	if not await _pick_up(a, [item_id]):
		return
	await _assert_mirrors_match(clients, "after alice's pickup")
	_world.get_player(alice_id).position = ALICE_AT

	# Alice drops it: an intent with a request id and the item id only.
	var request_id: int = _module(a).request_drop(item_id)
	assert_true(request_id > 0, "a joined client gets a request id")
	assert_true(await _wait(func() -> bool: return a_drops.size() == 1), "alice got her answer")
	assert_eq(a_drops, [[request_id, true, ""]])
	await _assert_mirrors_match(clients, "after the drop")
	await _settle()
	assert_eq(_world.inventory.get_item(item_id).location_type, ItemInstance.LOCATION_WORLD, "server: the item lies in the world")
	assert_eq(_world.inventory.world_position_of(item_id), ALICE_AT, "server: where the server knows alice to be")
	var expected_entry: Dictionary = {"item_instance_id": item_id, "definition_id": STACK, "quantity": 4, "position": ALICE_AT}
	for client: NetworkService in clients:
		assert_eq(client.client_state.world_items.get(item_id, {}), expected_entry, "every client sees it there")
		assert_false(client.client_state.has_inventory_item(item_id))
	assert_eq(_inventory_ids(alice_id), [], "server: alice no longer carries it")
	assert_eq(b_drops.size(), 0, "the result goes to the requester only")
	assert_eq(a_signals, [["inventory_items_removed", [item_id]], ["world_items_added", [item_id]]], "the owner: inventory change, then the world item")
	assert_eq(b_signals, [["world_items_added", [item_id]]], "others: the world item only")
	assert_eq(_module(a).owner_message_count, 1, "the owner got one inventory message")
	assert_eq(_module(b).owner_message_count, 0, "nobody else is sent anything about alice's inventory")
	_assert_conserved(clients, total, "after the drop")

	# Bob (at the spawn point, in range of alice's spot) picks it up.
	if not await _pick_up(b, [item_id]):
		return
	await _assert_mirrors_match(clients, "after bob's pickup")
	assert_eq(_inventory_ids(bob_id), [item_id], "server: bob carries it")
	assert_true(b.client_state.has_inventory_item(item_id))
	assert_eq(b.client_state.get_inventory_item(item_id).get("quantity", 0), 4, "the stack is intact")
	for client: NetworkService in clients:
		assert_false(client.client_state.world_items.has(item_id), "gone from the world for everyone")
	assert_false(a.client_state.has_inventory_item(item_id), "no copy stays with alice")
	assert_true(a.client_state.world_items.has(bystander_id) and b.client_state.world_items.has(bystander_id), "the other world item was never disturbed")
	_assert_conserved(clients, total, "at the end")
	assert_eq(_cluster.server.rejected_intent_count(), 0)


# ------------------------------------------------------------ 2. same tick

func test_a_drop_and_a_pickup_of_the_same_item_in_the_same_tick_stay_consistent() -> void:
	const ROUNDS: int = 6
	assert_true(_start_server(), "server started")
	var item_id: String = _spawn()
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var server: NetworkService = _cluster.server
	var total: int = _world.inventory.item_count()
	var a_drops: Array[Array] = _drop_results_of(a)
	var b_drops: Array[Array] = _drop_results_of(b)
	var b_pickups: Dictionary = _pickup_results_of(b)

	for round_index: int in range(ROUNDS):
		# Alice holds the item at the start of every round.
		if _inventory_ids(alice_id) != [item_id]:
			if _world.inventory.get_item(item_id).location_type != ItemInstance.LOCATION_WORLD:
				var give_back: int = _module(b).request_drop(item_id)
				assert_true(await _wait(func() -> bool: return not b_drops.is_empty() and b_drops[b_drops.size() - 1][0] == give_back), "bob gave it back")
			if not await _pick_up(a, [item_id]):
				return
		await _assert_mirrors_match(clients, "round %d start" % round_index)
		a_drops.clear()
		var rejections_before: int = server.rejected_intent_count()

		# The server stops reading the network while both clients send, so
		# all three requests are waiting when it reads again: they are
		# handled by one poll, i.e. within the same server tick. The send
		# order alternates and alice repeats her request.
		tree.multiplayer_poll = false
		var pickup_request: int = 0
		var drop_request: int = 0
		if round_index % 2 == 0:
			drop_request = _module(a).request_drop(item_id)
			pickup_request = b.request_pickup(item_id)
		else:
			pickup_request = b.request_pickup(item_id)
			drop_request = _module(a).request_drop(item_id)
		var repeated_request: int = _module(a).request_drop(item_id)
		var deadline: int = Time.get_ticks_msec() + CLIENT_FLUSH_MSEC
		while Time.get_ticks_msec() < deadline:
			a.multiplayer.poll()
			b.multiplayer.poll()
			await tree.process_frame
		assert_eq(server.rejected_intent_count(), rejections_before, "round %d: the server has handled nothing yet" % round_index)
		assert_eq(_inventory_ids(alice_id), [item_id], "round %d: nothing is committed yet" % round_index)
		server.multiplayer.poll()
		tree.multiplayer_poll = true

		# Straight after that one poll the server state is final: the drop was
		# committed exactly once, and the pickup either came first (refused,
		# the item now lies in the world) or second (bob holds the item).
		var item: ItemInstance = _world.inventory.get_item(item_id)
		var pickup_came_first: bool = item.location_type == ItemInstance.LOCATION_WORLD
		assert_eq(_inventory_ids(alice_id), [], "round %d: alice's drop was committed" % round_index)
		assert_eq(server.rejected_intent_count(InventoryService.REASON_NOT_IN_INVENTORY), round_index + 1, "round %d: the repeated drop was refused in the same poll" % round_index)
		assert_eq(server.rejected_intent_count() - rejections_before, 2 if pickup_came_first else 1, "round %d: every request was handled by that one poll" % round_index)
		if not pickup_came_first:
			assert_eq(item.location_id, _world.get_player(b.client_state.local_player_id).inventory_id, "round %d: bob holds the item" % round_index)

		# The answers and the mirrors agree with it.
		assert_true(await _wait(func() -> bool: return a_drops.size() == 2 and b_pickups.has(pickup_request)), "round %d: every request was answered" % round_index)
		await _settle()
		assert_eq(a_drops, [[drop_request, true, ""], [repeated_request, false, InventoryService.REASON_NOT_IN_INVENTORY]], "round %d" % round_index)
		assert_eq(b_pickups.get(pickup_request, []), [false, InventoryService.REASON_NOT_IN_WORLD] if pickup_came_first else [true, ""], "round %d" % round_index)
		await _assert_mirrors_match(clients, "round %d end" % round_index)
		_assert_conserved(clients, total, "round %d" % round_index)
		assert_false(a.client_state.has_inventory_item(item_id), "round %d: alice's mirror let go of it" % round_index)
		assert_eq(b.client_state.has_inventory_item(item_id), not pickup_came_first, "round %d: bob's mirror" % round_index)
		assert_eq(b.client_state.world_items.has(item_id), pickup_came_first, "round %d: the world mirror" % round_index)
	# Which request the server reads first is up to the transport; both orders
	# are valid outcomes and each round was checked for the one that happened.


# ------------------------------------------------------------ 3. manipulated requests

func test_manipulated_drop_requests_are_rejected_and_change_nothing() -> void:
	assert_true(_start_server(), "server started")
	var mine: String = _spawn()
	var bobs: String = _spawn(SINGLE, 1, OTHER_ITEM_AT)
	var lying: String = _spawn(STACK, 3)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [mine]):
		return
	if not await _pick_up(b, [bobs]):
		return
	await _assert_mirrors_match(clients, "start")
	var a_drops: Array[Array] = _drop_results_of(a)
	var b_drops: Array[Array] = _drop_results_of(b)
	var b_signals: Array[Array] = _mirror_signals_of(b)
	var before: Dictionary = _world.inventory.to_snapshot()
	var server: NetworkService = _cluster.server
	var module: InventoryNetModule = _module(a)
	var long_id: String = "x".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1)

	# Wrong ownership / unknown ids: answered, and nothing tells the requester
	# whether the id exists somewhere else.
	module.send_raw_drop_request(1, bobs)
	module.send_raw_drop_request(2, MISSING_ITEM_ID)
	module.send_raw_drop_request(3, lying)
	# Malformed arguments.
	module.send_raw_drop_request("x", mine)
	module.send_raw_drop_request(4, 12345)
	module.send_raw_drop_request(5, "")
	module.send_raw_drop_request(6, long_id)
	module.send_raw_drop_request(-1, mine)
	module.send_raw_drop_request(7.0, mine)
	module.send_raw_drop_request(8, null)
	module.send_raw_drop_request(9, [mine])
	module.send_raw_drop_request(null, null)
	const EXPECTED_REJECTIONS: int = 12
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == EXPECTED_REJECTIONS), "every manipulated request was rejected (%d)" % server.rejected_intent_count())
	# A request cannot carry a position or an owner: the handler takes two
	# arguments, and the engine refuses a call with more (reported as an
	# engine error, which is the expected outcome, so printing is off here).
	Engine.print_error_messages = false
	module._rpc_request_drop.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, bobs, bob_id)
	module._rpc_request_drop.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, mine, Vector3(100, 0, 100))
	await _settle()
	Engine.print_error_messages = true

	assert_eq(a_drops, [
		[1, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[2, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[3, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[4, false, IntentValidator.REASON_BAD_TYPE],
		[5, false, IntentValidator.REASON_BAD_ITEM_ID],
		[6, false, IntentValidator.REASON_BAD_ITEM_ID],
		[8, false, IntentValidator.REASON_BAD_TYPE],
		[9, false, IntentValidator.REASON_BAD_TYPE],
	], "answers go to usable request ids only, in order")
	assert_eq(server.rejected_intent_count(InventoryService.REASON_NOT_IN_INVENTORY), 2, "someone else's item, an item lying in the world")
	assert_eq(server.rejected_intent_count(InventoryService.REASON_UNKNOWN_ITEM), 1, "an id that does not exist")
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE), 6)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_ITEM_ID), 2)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_SEQUENCE), 1)
	assert_eq(server.rejected_intent_count(), EXPECTED_REJECTIONS, "the calls the engine refused never reached the handler")
	assert_eq(_world.inventory.to_snapshot(), before, "server state is unchanged")
	assert_eq(b_drops.size() + b_signals.size(), 0, "bob was told nothing")
	await _assert_mirrors_match(clients, "after the manipulated requests")
	assert_eq(_inventory_ids(bob_id), [bobs], "bob still carries his item")

	# The path itself works: a clean request from the same peer is accepted.
	var request_id: int = module.request_drop(mine)
	assert_true(await _wait(func() -> bool: return a_drops.size() == 9), "a valid request still goes through")
	assert_eq(a_drops[8], [request_id, true, ""])
	await _assert_mirrors_match(clients, "after the valid drop")


func test_drop_request_before_join_is_rejected() -> void:
	assert_true(_start_server(), "server started")
	var item_id: String = _spawn()
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var results: Array[Array] = _drop_results_of(stranger)
	var signals: Array[Array] = _mirror_signals_of(stranger)
	var connected: bool = await _wait(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	var before: Dictionary = _world.inventory.to_snapshot()
	assert_eq(_module(stranger).request_drop(item_id), InventoryNetModule.NO_REQUEST, "the client API sends nothing before the join")
	_module(stranger).send_raw_drop_request(1, item_id)
	assert_true(await _wait(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 1), "the server refused the request of a peer that has not joined")
	await _settle()
	assert_eq(_cluster.server.rejected_intent_count(), 1, "exactly the raw request reached the server")
	assert_eq(results.size() + signals.size(), 0, "an unjoined peer is told nothing")
	assert_eq(_world.inventory.to_snapshot(), before)
	assert_eq(_world.online_player_ids().size(), 0)


func test_drop_flood_is_rate_limited_per_peer() -> void:
	const BURST: int = 2
	const FLOOD: int = 6
	# One new token every 100 seconds: only the burst passes within the test.
	_inventory_net.drop_intent_rate_per_sec = 0.01
	_inventory_net.drop_intent_burst = BURST
	assert_true(_start_server(), "server started")
	var alice_items: Array = []
	for index: int in range(FLOOD):
		alice_items.append(_spawn())
	var bobs: String = _spawn(SINGLE, 1, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	if not await _pick_up(a, alice_items):
		return
	if not await _pick_up(b, [bobs]):
		return
	var a_drops: Array[Array] = _drop_results_of(a)
	var b_drops: Array[Array] = _drop_results_of(b)
	var requests: Array = []
	for item_id: String in alice_items:
		requests.append(_module(a).request_drop(item_id))
	assert_true(await _wait(func() -> bool: return a_drops.size() == FLOOD), "every request was answered (%d)" % a_drops.size())
	await _settle()
	var expected: Array = []
	for index: int in range(FLOOD):
		expected.append([requests[index], true, ""] if index < BURST else [requests[index], false, NetworkService.RATE_LIMITED])
	assert_eq(a_drops, expected, "only the burst is accepted")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST, "rejection counter")
	assert_eq(_inventory_ids(alice_id), alice_items.slice(BURST), "refused requests drop nothing")
	assert_eq(Array(_world.inventory.world_item_ids()), alice_items.slice(0, BURST))
	await _assert_mirrors_match(clients, "after the flood")
	# The bucket is per peer: bob is not limited by alice's flood.
	var request_id: int = _module(b).request_drop(bobs)
	assert_true(await _wait(func() -> bool: return b_drops.size() == 1), "bob was answered")
	assert_eq(b_drops, [[request_id, true, ""]])


func test_a_dead_player_cannot_drop() -> void:
	assert_true(_start_server(), "server started")
	var bobs: String = _spawn()
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(b, [bobs]):
		return
	var b_drops: Array[Array] = _drop_results_of(b)
	assert_true(_survival().apply_damage(bob_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok, "test setup: kill bob")
	assert_false(_survival().is_alive(bob_id))
	# Since P2-T4 the death itself put bob's item down where he died. Let
	# that reach the mirrors first, then watch that the refused request of
	# the dead player changes nothing more.
	await _assert_mirrors_match(clients, "after bob's death")
	var a_signals: Array[Array] = _mirror_signals_of(a)
	var before: Dictionary = _world.inventory.to_snapshot()
	var request_id: int = _module(b).request_drop(bobs)
	assert_true(await _wait(func() -> bool: return b_drops.size() == 1), "dead bob got an answer")
	await _settle()
	assert_eq(b_drops, [[request_id, false, InventoryNetModule.REASON_PLAYER_DEAD]])
	assert_eq(_cluster.server.rejected_intent_count(InventoryNetModule.REASON_PLAYER_DEAD), 1, "rejection counter")
	assert_eq(_cluster.server.rejected_intent_count(), 1)
	assert_eq(_world.inventory.to_snapshot(), before, "the item stays where it was")
	assert_eq(a_signals.size(), 0)
	await _assert_mirrors_match(clients, "after the refused drop")


# ------------------------------------------------------------ 4. forged server messages

func test_server_only_rpcs_sent_by_a_client_are_ignored() -> void:
	assert_true(_start_server(), "server started")
	var bobs: String = _spawn(STACK, 5)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(b, [bobs]):
		return
	await _assert_mirrors_match(clients, "start")
	var server_results: Array[Array] = _drop_results_of(_cluster.server)
	var server_signals: Array[Array] = _mirror_signals_of(_cluster.server)
	var b_drops: Array[Array] = _drop_results_of(b)
	var b_signals: Array[Array] = _mirror_signals_of(b)
	var before: Dictionary = _world.inventory.to_snapshot()
	var b_peer: int = b.multiplayer.get_unique_id()
	var forged_world_item: Dictionary = {"item_instance_id": "item_777777", "definition_id": SINGLE, "quantity": 1, "position": Vector3.ZERO}
	var forged_carried: Dictionary = b.client_state.get_inventory_item(bobs).duplicate()
	forged_carried["quantity"] = 1

	# Real ENet path. The engine refuses these (the sender is not the
	# authority; clients cannot reach each other) and reports each refusal as
	# an engine error, which is the expected outcome here, so error printing
	# is off for exactly this block (tools/run_tests.sh fails on any error line).
	Engine.print_error_messages = false
	for target: int in [NetworkService.SERVER_PEER_ID, b_peer]:
		_module(a)._rpc_drop_result.rpc_id(target, FORGED_REQUEST_ID, true, "")
		_module(a)._rpc_world_items_added.rpc_id(target, [forged_world_item])
		_module(a)._rpc_inventory_items_removed.rpc_id(target, [bobs])
		_module(a)._rpc_inventory_item_changed.rpc_id(target, forged_carried)
	await _settle()
	Engine.print_error_messages = true

	# Script-level guard, independent of the engine: a handler that is not
	# running an RPC sent by the server does nothing (sender id 0 here).
	for service: NetworkService in [b, _cluster.server]:
		_module(service)._rpc_drop_result(FORGED_REQUEST_ID, true, "")
		_module(service)._rpc_world_items_added([forged_world_item])
		_module(service)._rpc_inventory_items_removed([bobs])
		_module(service)._rpc_inventory_item_changed(forged_carried)
	# ... and a client never acts on a request addressed to it.
	_module(b)._rpc_request_drop(FORGED_REQUEST_ID, bobs)
	await _settle()

	assert_eq(b_drops.size() + b_signals.size(), 0, "bob received nothing forged")
	assert_eq(server_results.size() + server_signals.size(), 0, "the server never handles client-bound messages")
	assert_eq(_module(b).rejected_payload_count, 0, "nothing even reached bob's validation")
	assert_eq(_world.inventory.to_snapshot(), before, "server state is unchanged")
	assert_eq(_inventory_ids(bob_id), [bobs])
	assert_eq(b.client_state.get_inventory_item(bobs).get("quantity", 0), 5)
	assert_false(b.client_state.world_items.has("item_777777"))
	await _assert_mirrors_match(clients, "after the forged messages")
	assert_eq(_cluster.server.rejected_intent_count(), 0, "no intent handler ran")


func test_a_client_drops_malformed_messages_even_from_the_server() -> void:
	assert_true(_start_server(), "server started")
	var carried: String = _spawn(STACK, 5)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var alice_id: String = a.client_state.local_player_id
	if not await _pick_up(a, [carried]):
		return
	var a_drops: Array[Array] = _drop_results_of(a)
	var a_signals: Array[Array] = _mirror_signals_of(a)
	var server_module: InventoryNetModule = _module(_cluster.server)
	var a_peer: int = _cluster.server.peer_of_player(alice_id)
	var good: Dictionary = {"item_instance_id": "item_555555", "definition_id": SINGLE, "quantity": 1, "position": Vector3(2, 0, 2)}
	var bad_quantity: Dictionary = good.duplicate()
	bad_quantity["item_instance_id"] = "item_555556"
	bad_quantity["quantity"] = 0
	var oversized: Array = []
	for index: int in range(InventoryNetModule.MAX_ITEMS_PER_MESSAGE + 1):
		var entry: Dictionary = good.duplicate()
		entry["item_instance_id"] = "item_6%05d" % index
		oversized.append(entry)
	var oversized_ids: Array = []
	for index: int in range(InventoryNetModule.MAX_ITEMS_PER_MESSAGE + 1):
		oversized_ids.append(carried)
	var world_carried: Dictionary = a.client_state.get_inventory_item(carried).duplicate()
	world_carried["location_type"] = ItemInstance.LOCATION_WORLD
	var no_quantity: Dictionary = a.client_state.get_inventory_item(carried).duplicate()
	no_quantity.erase("quantity")

	server_module._rpc_world_items_added.rpc_id(a_peer, "not a list")
	server_module._rpc_world_items_added.rpc_id(a_peer, oversized)
	server_module._rpc_world_items_added.rpc_id(a_peer, ["junk", bad_quantity, good, 7])
	server_module._rpc_inventory_items_removed.rpc_id(a_peer, carried)
	server_module._rpc_inventory_items_removed.rpc_id(a_peer, oversized_ids)
	server_module._rpc_inventory_items_removed.rpc_id(a_peer, [5, "", "x".repeat(ClientWorldState.ITEM_ID_MAX_LENGTH + 1)])
	server_module._rpc_inventory_item_changed.rpc_id(a_peer, "junk")
	server_module._rpc_inventory_item_changed.rpc_id(a_peer, world_carried)
	server_module._rpc_inventory_item_changed.rpc_id(a_peer, no_quantity)
	server_module._rpc_drop_result.rpc_id(a_peer, "1", true, "")
	server_module._rpc_drop_result.rpc_id(a_peer, 1, "yes", "")
	server_module._rpc_drop_result.rpc_id(a_peer, 2, true, InventoryService.REASON_NOT_IN_INVENTORY)
	server_module._rpc_drop_result.rpc_id(a_peer, 3, false, "")
	server_module._rpc_drop_result.rpc_id(a_peer, -4, false, InventoryService.REASON_NOT_IN_INVENTORY)
	server_module._rpc_drop_result.rpc_id(a_peer, 5, false, "x".repeat(InventoryNetModule.REASON_MAX_LENGTH + 1))
	server_module._rpc_drop_result.rpc_id(a_peer, 6, false, InventoryService.REASON_NOT_IN_INVENTORY)
	assert_true(await _wait(func() -> bool: return a_drops.size() == 1), "the last, well-formed result arrived")
	await _settle()

	assert_eq(a_drops, [[6, false, InventoryService.REASON_NOT_IN_INVENTORY]], "malformed results are dropped")
	assert_eq(a_signals, [["world_items_added", ["item_555555"]]], "only the well-formed entry was applied")
	assert_true(a.client_state.world_items.has("item_555555"))
	assert_false(a.client_state.world_items.has("item_555556"))
	assert_eq(a.client_state.world_items.size(), 1)
	assert_eq(a.client_state.get_inventory_item(carried).get("quantity", 0), 5, "the inventory mirror is untouched")
	assert_eq(a.client_state.get_inventory_item(carried).get("location_type", ""), ItemInstance.LOCATION_INVENTORY)
	# World items: 2 whole messages + 3 entries. Removed ids: 2 whole
	# messages + 3 entries. Changed item: 3 messages. Results: 6 messages.
	assert_eq(_module(a).rejected_payload_count, 2 + 3 + 2 + 3 + 3 + 6, "every dropped payload is counted")


# ------------------------------------------------------------ 5. late joiner

func test_a_late_joiner_sees_dropped_items_in_the_join_snapshot() -> void:
	assert_true(_start_server(), "server started")
	var dropped: String = _spawn(STACK, 3)
	var kept: String = _spawn()
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var alice_id: String = a.client_state.local_player_id
	if not await _pick_up(a, [dropped, kept]):
		return
	_world.get_player(alice_id).position = ALICE_AT
	var a_drops: Array[Array] = _drop_results_of(a)
	_module(a).request_drop(dropped)
	assert_true(await _wait(func() -> bool: return a_drops.size() == 1 and a_drops[0][1]), "alice dropped the item")

	var c: NetworkService = await _cluster.join_client("carol")
	assert_not_null(c, "carol joined late")
	if c == null:
		return
	clients.append(c)
	assert_eq(c.client_state.world_items.get(dropped, {}), {"item_instance_id": dropped, "definition_id": STACK, "quantity": 3, "position": ALICE_AT}, "the join snapshot carries the dropped item")
	assert_eq(c.client_state.world_items.size(), 1)
	assert_eq(c.client_state.inventory.size(), 0, "carol gets nobody else's inventory")
	await _assert_mirrors_match(clients, "after carol joined")
	# Later changes reach her like everyone else.
	var c_signals: Array[Array] = _mirror_signals_of(c)
	_module(a).request_drop(kept)
	assert_true(await _wait(func() -> bool: return a_drops.size() == 2 and c_signals.size() == 1), "carol sees the next drop")
	assert_eq(c_signals, [["world_items_added", [kept]]])
	await _assert_mirrors_match(clients, "after the second drop")
	_assert_conserved(clients, 2, "at the end")


# ------------------------------------------------------------ 6. server-side calls

func test_server_side_remove_and_drop_all_reach_the_mirrors() -> void:
	const PER_MESSAGE: int = 2
	_inventory_net.max_items_per_message = PER_MESSAGE
	assert_true(_start_server(), "server started")
	var stack_id: String = _spawn(STACK, 6)
	var singles: Array = []
	for index: int in range(4):
		singles.append(_spawn())
	var bobs: String = _spawn(SINGLE, 1, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [stack_id] + singles):
		return
	if not await _pick_up(b, [bobs]):
		return
	await _assert_mirrors_match(clients, "start")
	var a_signals: Array[Array] = _mirror_signals_of(a)
	var b_signals: Array[Array] = _mirror_signals_of(b)
	var a_drops: Array[Array] = _drop_results_of(a)

	# Part of a stack (what eating one unit will do): the owner alone is told.
	assert_true(_world.remove_player_item(alice_id, stack_id, 2).ok)
	assert_true(await _wait(func() -> bool: return a_signals.size() == 1), "alice was told about the smaller stack")
	assert_eq(a_signals, [["inventory_item_changed", stack_id]])
	assert_eq(a.client_state.get_inventory_item(stack_id).get("quantity", 0), 4)
	await _assert_mirrors_match(clients, "after the partial removal")

	# The rest of the stack: the instance is gone on the server and in the mirror.
	assert_true(_world.remove_player_item(alice_id, stack_id, 4).ok)
	assert_true(await _wait(func() -> bool: return a_signals.size() == 2), "alice was told the stack is gone")
	assert_eq(a_signals[1], ["inventory_items_removed", [stack_id]])
	assert_null(_world.inventory.get_item(stack_id))
	assert_false(a.client_state.has_inventory_item(stack_id))
	await _assert_mirrors_match(clients, "after the full removal")

	# A refused server call tells nobody anything.
	assert_false(_world.remove_player_item(alice_id, bobs, 1).ok)
	assert_false(_world.remove_player_item(alice_id, stack_id, 1).ok)

	# Everything alice carries (what a death will do), at her server position.
	_world.get_player(alice_id).position = ALICE_AT
	var all: ActionResult = _world.drop_all_player_items(alice_id)
	assert_true(all.ok, all.reason)
	assert_eq(all.event.get("item_instance_ids", []), singles)
	await _assert_mirrors_match(clients, "after dropping everything")
	await _settle()
	assert_eq(a.client_state.inventory.size(), 0, "alice's inventory mirror is empty")
	for client: NetworkService in clients:
		for item_id: String in singles:
			assert_eq(client.client_state.world_items.get(item_id, {}).get("position", null), ALICE_AT, "every client sees %s at alice's position" % item_id)
	# Four items, two per message, in slot order; the owner's removals first.
	assert_eq(a_signals.slice(2), [
		["inventory_items_removed", singles.slice(0, PER_MESSAGE)],
		["inventory_items_removed", singles.slice(PER_MESSAGE)],
		["world_items_added", singles.slice(0, PER_MESSAGE)],
		["world_items_added", singles.slice(PER_MESSAGE)],
	])
	assert_eq(b_signals, [
		["world_items_added", singles.slice(0, PER_MESSAGE)],
		["world_items_added", singles.slice(PER_MESSAGE)],
	], "bob is told about the world items only, never about alice's inventory")
	assert_eq(_inventory_ids(bob_id), [bobs], "bob's inventory is untouched")
	assert_true(b.client_state.has_inventory_item(bobs))
	assert_eq(_module(a).owner_message_count, 4, "alice: smaller stack, stack gone, two removal messages")
	assert_eq(_module(b).owner_message_count, 0, "bob never received an owner-only message")
	assert_eq(a_drops.size(), 0, "no request, no result")
	assert_eq(_module(a).rejected_payload_count + _module(b).rejected_payload_count, 0, "the server's own messages pass the client validation")
	_assert_conserved(clients, 5, "at the end")
	assert_eq(_cluster.server.rejected_intent_count(), 0)


# ------------------------------------------------------------ save and restart

func test_dropped_and_removed_items_survive_a_save_and_server_restart() -> void:
	_save_root = "user://test_saves/inventory_net_%d" % Time.get_ticks_usec()
	_config.dev_seed.item_definition_ids = PackedStringArray([SINGLE, SINGLE])
	_config.dev_seed.item_positions = PackedVector3Array([ITEM_AT, OTHER_ITEM_AT])
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	var stack_id: String = _spawn(STACK, 5)
	var used_up: String = _spawn(STACK, 1, OTHER_ITEM_AT)
	var seeded: PackedStringArray = _world.inventory.world_item_ids()
	assert_eq(seeded.size(), 4, "two seeded items and the two placed by the test")
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var clients: Array[NetworkService] = [a, b]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var dropped: String = seeded[0]
	var kept: String = seeded[1]
	if not await _pick_up(a, [dropped, kept, stack_id]):
		return
	_world.get_player(alice_id).position = ALICE_AT
	var a_drops: Array[Array] = _drop_results_of(a)
	var save: SaveService = SaveService.new(_save_root)

	# A drop is saved at once, like a pickup.
	var generation: int = save.current_generation(WORLD)
	_module(a).request_drop(dropped)
	assert_true(await _wait(func() -> bool: return a_drops.size() == 1), "alice dropped the item")
	assert_eq(a_drops[0].slice(1), [true, ""])
	assert_true(save.current_generation(WORLD) > generation, "the drop was saved before the answer went out")
	# A server-side change is saved by the end of the server tick.
	generation = save.current_generation(WORLD)
	assert_true(_world.remove_player_item(alice_id, stack_id, 2).ok)
	assert_true(await _wait(func() -> bool: return save.current_generation(WORLD) > generation), "the removal was saved")
	await _assert_mirrors_match(clients, "session 1")
	if not await _pick_up(b, [used_up]):
		return
	assert_true(_world.remove_player_item(bob_id, used_up, 1).ok)
	assert_true(await _wait(func() -> bool: return not b.client_state.has_inventory_item(used_up)), "bob's last unit is gone")

	# --- full restart: everything torn down, state comes only from disk ---
	await _cluster.shutdown()
	_cluster = null
	_world = null
	var persistence2: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence2.load_or_create(WORLD)
	assert_not_null(_world, "world restored from save")
	if _world == null:
		return
	assert_eq(_world.inventory.world_item_ids(), PackedStringArray([dropped]), "the dropped item lies in the world")
	assert_eq(_world.inventory.world_position_of(dropped), ALICE_AT, "... where it was dropped")
	assert_null(_world.inventory.get_item(used_up), "the used-up item is not restored")
	assert_true(_world.registry.is_tombstoned(used_up))
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	var b2: NetworkService = await _cluster.join_client("bob")
	if a2 == null or b2 == null:
		fail("clients did not rejoin")
		return
	var clients2: Array[NetworkService] = [a2, b2]
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	assert_eq(b2.client_state.local_player_id, bob_id)
	var expected_entry: Dictionary = {"item_instance_id": dropped, "definition_id": SINGLE, "quantity": 1, "position": ALICE_AT}
	for client: NetworkService in clients2:
		assert_eq(client.client_state.world_items.size(), 1)
		assert_eq(client.client_state.world_items.get(dropped, {}), expected_entry, "both clients see the same world item")
	assert_eq(a2.client_state.inventory.size(), 2, "alice has her own inventory")
	assert_true(a2.client_state.has_inventory_item(kept))
	assert_eq(a2.client_state.get_inventory_item(stack_id).get("quantity", 0), 3, "the reduced stack was saved")
	assert_eq(b2.client_state.inventory.size(), 0, "bob has his own (empty) inventory")
	await _assert_mirrors_match(clients2, "session 2")
	_assert_conserved(clients2, 3, "session 2")
	# The restored item is a normal world item, and ids never come back.
	if not await _pick_up(b2, [dropped]):
		return
	await _assert_mirrors_match(clients2, "session 2 after bob's pickup")
	var fresh: String = _spawn()
	assert_true(EntityIdGenerator.sequence_of(fresh) > EntityIdGenerator.sequence_of(used_up), "new ids continue after every id ever used")


# ------------------------------------------------------------ rules (no network)

func test_default_settings_and_composition() -> void:
	assert_true(ResourceLoader.exists(InventoryNetSettings.DEFAULT_PATH), "default settings resource is shipped")
	var settings: InventoryNetSettings = InventoryNetSettings.load_or_default()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_not_null(config.inventory_net)
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var broken: InventoryNetSettings = InventoryNetSettings.new()
	broken.drop_intent_rate_per_sec = 0.0
	broken.max_items_per_message = InventoryNetModule.MAX_ITEMS_PER_MESSAGE + 1
	assert_eq(broken.validate().size(), 2, "; ".join(broken.validate()))
	config.inventory_net = broken
	assert_true(config.validate().size() > 0, "composition validation covers the inventory network settings")
	config.inventory_net = null
	assert_true(config.validate().size() > 0, "a missing settings object is reported")
	assert_eq(BuildInfo.PROTOCOL_VERSION, 5, "new RPCs are a protocol change: 4 for the drop RPCs, 5 since the consume RPCs (P2-T3)")

	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	var module: InventoryNetModule = service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	assert_not_null(module, "the composition installs the inventory module")
	assert_eq(str(module.name), InventoryNetModule.MODULE_NAME, "same node name on every peer")
	assert_eq(module.request_drop("item_000001"), InventoryNetModule.NO_REQUEST, "nothing is sent while offline")
	# Channel 0, reliable; requests from any peer, everything else only from the server.
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	var expected_modes: Dictionary[String, int] = {
		"_rpc_request_drop": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_drop_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
		# P2-T3 added the consume intent to this module (consume_net_test.gd).
		"_rpc_request_consume": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_consume_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_world_items_added": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_inventory_items_removed": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_inventory_item_changed": MultiplayerAPI.RPC_MODE_AUTHORITY,
	}
	assert_eq(rpc_config.size(), expected_modes.size(), "no other RPC exists")
	for method: String in expected_modes:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), expected_modes[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	service.free()


func test_request_and_payload_validation_rules() -> void:
	assert_eq(InventoryNetModule.validate_drop_request(1, "item_000001"), "")
	assert_eq(InventoryNetModule.validate_drop_request(0, "x"), "")
	assert_eq(InventoryNetModule.validate_drop_request("1", "item_000001"), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_drop_request(1.0, "item_000001"), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_drop_request(1, &"item_000001"), IntentValidator.REASON_BAD_TYPE, "StringName is not String")
	assert_eq(InventoryNetModule.validate_drop_request(-1, "item_000001"), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(InventoryNetModule.validate_drop_request(1, ""), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(InventoryNetModule.validate_drop_request(1, "x".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH)), "")
	assert_eq(InventoryNetModule.validate_drop_request(1, "x".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1)), IntentValidator.REASON_BAD_ITEM_ID)
	# What the requester is told never reveals whether a foreign id exists.
	assert_eq(InventoryNetModule.public_reason(InventoryService.REASON_UNKNOWN_ITEM), InventoryService.REASON_NOT_IN_INVENTORY)
	assert_eq(InventoryNetModule.public_reason(InventoryService.REASON_NOT_IN_INVENTORY), InventoryService.REASON_NOT_IN_INVENTORY)
	assert_eq(InventoryNetModule.public_reason(InventoryNetModule.REASON_PLAYER_DEAD), InventoryNetModule.REASON_PLAYER_DEAD)
	# Owner inventory entries: a full ItemInstance dictionary that is carried.
	var carried: Dictionary = {"schema_version": 1, "item_instance_id": "item_000001", "definition_id": STACK, "quantity": 2, "location_type": "inventory", "location_id": "inventory_000001", "slot_id": "slot_0"}
	assert_true(InventoryNetModule.is_valid_inventory_item(carried))
	var lying: Dictionary = carried.duplicate()
	lying["location_type"] = "world"
	var long_id: Dictionary = carried.duplicate()
	long_id["item_instance_id"] = "x".repeat(ClientWorldState.ITEM_ID_MAX_LENGTH + 1)
	var no_definition: Dictionary = carried.duplicate()
	no_definition.erase("definition_id")
	for bad: Variant in [lying, long_id, no_definition, {}, "junk", null, 3]:
		assert_false(InventoryNetModule.is_valid_inventory_item(bad), "rejected: %s" % str(bad))
