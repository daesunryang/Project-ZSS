extends TestCase
## Phase 1 acceptance (docs/13 §3): two clients connect and move, one item is
## picked up in the shared world, saved, and restored after a full server
## restart (new ServerWorld from disk, clients reconnect).
## Server + 2 clients run over real ENet sockets on localhost.

const WORLD: String = "phase1_world"
const PICKUP_MARGIN_M: float = 0.5
const MAX_MOVE_FRAMES: int = 600
const STOP_FRAMES: int = 3

var _root: String = ""
var _settings: NetworkSettings = null
var _cluster: NetTestCluster = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/phase1_%d" % Time.get_ticks_usec()
	_settings = NetworkSettings.new()
	_settings.autosave_interval_sec = 0.0


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _persistence() -> WorldPersistence:
	return WorldPersistence.new(SaveService.new(_root), CompositionConfig.from_defaults())


func _collect_results(client: NetworkService) -> Dictionary:
	var results: Dictionary = {}
	client.pickup_result.connect(func(request_id: int, ok: bool, reason: String) -> void: results[request_id] = [ok, reason])
	return results


func test_two_clients_move_pick_up_save_and_restore() -> void:
	# --- session 1 -------------------------------------------------------
	var persistence: WorldPersistence = _persistence()
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	_cluster = NetTestCluster.new(tree, _settings)
	assert_eq(_cluster.start_server(world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	assert_eq(b.client_state.world_items.size(), 1, "bob sees the shared item")
	var item_id: String = b.client_state.world_items.keys()[0]
	var item_position: Vector3 = b.client_state.world_items[item_id]["position"]
	var a_results: Dictionary = _collect_results(a)
	var b_results: Dictionary = _collect_results(b)

	# Out of range: the server uses its own position for alice, not the client's.
	var far_request: int = a.request_pickup(item_id)
	await _cluster.wait_until(func() -> bool: return a_results.has(far_request))
	assert_eq(a_results.get(far_request, []), [false, InventoryService.REASON_TOO_FAR])

	# Both clients move (bob away from the item), alice walks to the item.
	var direction: Vector2 = Vector2(item_position.x, item_position.z).normalized()
	var range_m: float = world.gameplay.pickup_range_m - PICKUP_MARGIN_M
	for frame: int in range(MAX_MOVE_FRAMES):
		if world.get_player(alice_id).position.distance_to(item_position) <= range_m:
			break
		a.send_move_intent(direction, 0.0)
		b.send_move_intent(-direction, PI)
		await tree.physics_frame
	for frame: int in range(STOP_FRAMES):
		a.send_move_intent(Vector2.ZERO, 0.0)
		b.send_move_intent(Vector2.ZERO, PI)
		await tree.physics_frame
	await _cluster.wait_frames(10)
	var alice_position: Vector3 = world.get_player(alice_id).position
	assert_true(alice_position.distance_to(item_position) <= world.gameplay.pickup_range_m, "alice reached the item: %s" % str(alice_position))
	assert_true(world.get_player(bob_id).position.distance_to(Vector3.ZERO) > 0.5, "bob moved too")
	var bob_sees_alice: bool = await _cluster.wait_until(func() -> bool: return b.client_state.position_of(alice_id).distance_to(world.get_player(alice_id).position) < 0.05)
	assert_true(bob_sees_alice, "bob observes alice's server position")

	# Pickup succeeds once; bob's late request for the same item fails.
	var generation_before: int = SaveService.new(_root).current_generation(WORLD)
	var request: int = a.request_pickup(item_id)
	var late: int = b.request_pickup(item_id)
	await _cluster.wait_until(func() -> bool: return a_results.has(request) and b_results.has(late))
	assert_eq(a_results.get(request, []), [true, ""])
	assert_eq(b_results.get(late, []), [false, InventoryService.REASON_NOT_IN_WORLD])
	var replicated: bool = await _cluster.wait_until(func() -> bool:
		return a.client_state.has_inventory_item(item_id) and not a.client_state.world_items.has(item_id) and not b.client_state.world_items.has(item_id))
	assert_true(replicated, "pickup replicated to both clients")
	assert_false(b.client_state.has_inventory_item(item_id), "no duplicate in bob's inventory")
	assert_true(SaveService.new(_root).current_generation(WORLD) > generation_before, "pickup saved immediately")

	# Manipulated pickup requests are rejected without side effects.
	b.send_raw_pickup_request("x", item_id)
	b.send_raw_pickup_request(99, 12345)
	b.send_raw_pickup_request(100, "")
	var rejected: bool = await _cluster.wait_until(func() -> bool:
		return _cluster.server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE) >= 2 and _cluster.server.rejected_intent_count(IntentValidator.REASON_BAD_ITEM_ID) >= 1)
	assert_true(rejected, "malformed pickups rejected")

	# --- full restart: everything torn down, state comes only from disk ---
	await _cluster.shutdown()
	_cluster = null
	world = null
	var persistence2: WorldPersistence = _persistence()
	var world2: ServerWorld = persistence2.load_or_create(WORLD)
	assert_not_null(world2, "world restored from save")
	if world2 == null:
		return
	assert_eq(world2.inventory.world_item_ids().size(), 0, "picked item is not respawned")
	_cluster = NetTestCluster.new(tree, _settings)
	assert_eq(_cluster.start_server(world2, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	var b2: NetworkService = await _cluster.join_client("bob")
	if a2 == null or b2 == null:
		fail("clients did not rejoin")
		return
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	assert_eq(b2.client_state.local_player_id, bob_id)
	assert_true(a2.client_state.has_inventory_item(item_id), "item restored into alice's inventory")
	assert_eq(a2.client_state.inventory.size(), 1)
	assert_eq(b2.client_state.inventory.size(), 0)
	assert_eq(b2.client_state.world_items.size(), 0)
	assert_true(a2.client_state.position_of(alice_id).distance_to(alice_position) < 0.05, "alice position restored")
