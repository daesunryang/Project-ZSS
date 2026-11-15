extends TestCase
## P2-T3: eating and drinking over real ENet (server + 2 clients).
## A client only asks ("consume this item"); the server takes one unit from
## the requester's own inventory and lowers that player's hunger / thirst.
## The owner sees the inventory change (InventoryNet) and the lower needs
## (owner survival snapshot); nobody else is told anything. Manipulated
## requests change nothing. Consumption is not saved on its own.

const WORLD: String = "consume_net_test_world"
const NEVER: float = 1.0e9
const FOOD: String = "t3_food"
const WATER: String = "t3_water"
const PLAIN: String = "t3_plain"
const FOOD_HUNGER: float = 30.0
const WATER_THIRST: float = 45.0
const STACK_MAX: int = 5
const CELL: String = DevWorldSeed.DEV_CELL_ID
## Players spawn at the origin; both positions are within pickup range.
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const OTHER_ITEM_AT: Vector3 = Vector3(-0.5, 0.0, 1.0)
const WAIT_MSEC: int = 5000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const LETHAL_DAMAGE: float = 100000.0
const FORGED_REQUEST_ID: int = 77
const MISSING_ITEM_ID: String = "item_999999"
## Needs do not move on their own during a test (the longest allowed climb).
const FROZEN_NEED_HOURS: float = 100000.0
## Largest need drift tolerated while a test runs.
const NEED_TOLERANCE: float = 0.01

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
	_inventory_net.consume_intent_rate_per_sec = GENEROUS_RATE
	_inventory_net.consume_intent_burst = GENEROUS_BURST
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.catalog = _new_catalog()
	# Only consumption moves needs: no growth, recovery or respawn.
	_config.survival = SurvivalSettings.new()
	_config.survival.hunger_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.thirst_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.fatigue_hours_to_max = FROZEN_NEED_HOURS
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
	if _cluster != null:
		await _cluster.shutdown()
	if not _save_root.is_empty():
		SaveService.remove_tree(_save_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## The shipped item definitions plus a food, a drink and a plain item.
func _new_catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	catalog.add(_definition(FOOD, FOOD_HUNGER, 0.0))
	catalog.add(_definition(WATER, 0.0, WATER_THIRST))
	catalog.add(_definition(PLAIN, 0.0, 0.0))
	return catalog


func _definition(definition_id: String, hunger: float, thirst: float) -> ItemDefinition:
	var definition: ItemDefinition = ItemDefinition.new()
	definition.definition_id = definition_id
	definition.max_stack = STACK_MAX
	definition.consume_hunger_reduction = hunger
	definition.consume_thirst_reduction = thirst
	return definition


func _start_server() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


## Joins "alice" and "bob" (after the test placed its items). Empty on failure.
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
func _needs_mirror(service: NetworkService) -> ClientSurvivalState:
	return (service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule).client_state


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _vitals(player_id: String) -> PlayerVitals:
	return _survival().get_vitals(player_id)


func _spawn(definition_id: String, quantity: int = 1, position: Vector3 = ITEM_AT) -> String:
	return _world.inventory.spawn_world_item(definition_id, quantity, CELL, position)


## Rows [request_id, ok, reason] of every consume result of `service`.
func _consume_results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).consume_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Rows [signal name, payload] of the module's mirror signals of `service`.
func _mirror_signals_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	var module: InventoryNetModule = _module(service)
	module.world_items_added.connect(func(ids: PackedStringArray) -> void: rows.append(["world_items_added", Array(ids)]))
	module.inventory_items_removed.connect(func(ids: PackedStringArray) -> void: rows.append(["inventory_items_removed", Array(ids)]))
	module.inventory_item_changed.connect(func(item_id: String) -> void: rows.append(["inventory_item_changed", item_id]))
	return rows


## Every survival event `service` receives from now on.
func _survival_events_of(service: NetworkService) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_needs_mirror(service).event_received.connect(func(event: Dictionary) -> void: events.append(event))
	return events


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


## Picks up `item_ids` through the real pickup RPC and waits for the mirror.
func _pick_up(client: NetworkService, item_ids: Array) -> bool:
	var results: Dictionary = {}
	client.pickup_result.connect(func(request_id: int, ok: bool, reason: String) -> void: results[request_id] = [ok, reason])
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


## "" when the client's inventory mirror equals what its player carries on
## the server, else what differs.
func _inventory_mismatch(client: NetworkService) -> String:
	var state: ClientWorldState = client.client_state
	var carried: Array[ItemInstance] = _world.inventory.items_in_inventory(_world.get_player(state.local_player_id).inventory_id)
	if state.inventory.size() != carried.size():
		return "inventory: mirror %d, server %d" % [state.inventory.size(), carried.size()]
	for item: ItemInstance in carried:
		if state.get_inventory_item(item.item_instance_id) != item.to_dict():
			return "carried item %s differs: %s" % [item.item_instance_id, str(state.get_inventory_item(item.item_instance_id))]
	return ""


## "" when the client's own need categories equal the server's, else what differs.
func _needs_mismatch(client: NetworkService) -> String:
	var player_id: String = client.client_state.local_player_id
	for kind_index: int in NeedKind.KIND_NAMES.size():
		var kind_name: String = NeedKind.KIND_NAMES[kind_index]
		var server_category: String = NeedKind.category_name(_survival().need_category(player_id, kind_index as NeedKind.Kind))
		if _needs_mirror(client).need_category(kind_name) != server_category:
			return "%s: mirror %s, server %s" % [kind_name, _needs_mirror(client).need_category(kind_name), server_category]
	return ""


## Waits until the client's inventory and need mirrors equal the server.
func _assert_owner_mirror_matches(client: NetworkService, label: String) -> void:
	var matched: bool = await _wait(func() -> bool: return _inventory_mismatch(client).is_empty() and _needs_mismatch(client).is_empty())
	assert_true(matched, "%s: %s %s" % [label, _inventory_mismatch(client), _needs_mismatch(client)])


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= NEED_TOLERANCE


# ------------------------------------------------------------ 1. pick up, eat, drink

func test_a_client_eats_what_it_picked_up_and_only_the_owner_learns_it() -> void:
	assert_true(_start_server(), "server started")
	var food_id: String = _spawn(FOOD, 3)
	var water_id: String = _spawn(WATER, 1, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	# Alice is hungry (caution) and very thirsty (danger); bob is fine.
	_vitals(alice_id).hunger = 60.0
	_vitals(alice_id).thirst = 80.0
	await _assert_owner_mirror_matches(a, "start")
	assert_eq(_needs_mirror(a).need_category("hunger"), "caution")
	assert_eq(_needs_mirror(a).need_category("thirst"), "danger")
	if not await _pick_up(a, [food_id, water_id]):
		return
	await _settle()
	var a_consumes: Array[Array] = _consume_results_of(a)
	var b_consumes: Array[Array] = _consume_results_of(b)
	var a_signals: Array[Array] = _mirror_signals_of(a)
	var b_signals: Array[Array] = _mirror_signals_of(b)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	var b_owner_messages: int = _module(b).owner_message_count

	# Alice eats: an intent with a request id and the item id only.
	var eat_request: int = _module(a).request_consume(food_id)
	assert_true(eat_request > 0, "a joined client gets a request id")
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 1), "alice got her answer")
	assert_eq(a_consumes, [[eat_request, true, ""]])
	assert_eq(_world.inventory.get_item(food_id).quantity, 2, "server: one unit left the stack")
	assert_true(_near(_vitals(alice_id).hunger, 60.0 - FOOD_HUNGER), "server: hunger %f" % _vitals(alice_id).hunger)
	assert_true(_near(_vitals(alice_id).thirst, 80.0), "server: thirst untouched")
	await _assert_owner_mirror_matches(a, "after eating")
	assert_eq(a.client_state.get_inventory_item(food_id).get("quantity", 0), 2, "alice's mirror: the smaller stack")
	assert_eq(_needs_mirror(a).need_category("hunger"), "good", "alice's mirror: hunger is good again")
	assert_eq(_needs_mirror(a).need_category("thirst"), "danger")

	# Alice drinks her only bottle: the item is gone.
	var drink_request: int = _module(a).request_consume(water_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 2), "alice got her second answer")
	assert_eq(a_consumes[1], [drink_request, true, ""])
	assert_null(_world.inventory.get_item(water_id), "server: the used-up item no longer exists")
	assert_true(_near(_vitals(alice_id).thirst, 80.0 - WATER_THIRST), "server: thirst %f" % _vitals(alice_id).thirst)
	await _assert_owner_mirror_matches(a, "after drinking")
	assert_false(a.client_state.has_inventory_item(water_id), "alice's mirror: the bottle is gone")
	assert_eq(_needs_mirror(a).need_category("thirst"), "good")
	await _settle()

	assert_eq(a_signals, [["inventory_item_changed", food_id], ["inventory_items_removed", [water_id]]], "the owner: a smaller stack, then a removed item")
	# Nobody else is told: no result, no inventory message, no world item, no need of alice's.
	assert_eq(b_consumes.size(), 0, "the result goes to the requester only")
	assert_eq(b_signals.size(), 0, "bob's mirrors did not change")
	assert_eq(_module(b).owner_message_count, b_owner_messages, "bob never received an owner-only message")
	for event: Dictionary in b_events:
		assert_ne(str(event.get("player_id", "")), alice_id, "bob received a survival event about alice: %s" % str(event))
	assert_eq(b_events.size(), 0, "bob received no survival event at all")
	assert_eq(_needs_mirror(b).need_category("hunger"), "good", "bob's mirror shows his own needs")
	assert_true(_near(_vitals(bob_id).hunger, 0.0), "server: bob's needs were not touched")
	assert_eq(b.client_state.inventory.size(), 0)
	assert_false(b.client_state.world_items.has(food_id) or b.client_state.world_items.has(water_id), "nothing reappeared in the world")
	assert_eq(_module(a).rejected_payload_count + _module(b).rejected_payload_count, 0, "the server's own messages pass the client validation")
	assert_eq(_cluster.server.rejected_intent_count(), 0)


# ------------------------------------------------------------ 2. manipulated requests

func test_manipulated_consume_requests_are_rejected_and_change_nothing() -> void:
	assert_true(_start_server(), "server started")
	var mine: String = _spawn(FOOD, 2)
	var plain: String = _spawn(PLAIN)
	var bobs: String = _spawn(FOOD, 1, OTHER_ITEM_AT)
	var lying: String = _spawn(WATER, 3, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [mine, plain]):
		return
	if not await _pick_up(b, [bobs]):
		return
	_vitals(alice_id).hunger = 70.0
	_vitals(alice_id).thirst = 70.0
	_vitals(bob_id).hunger = 70.0
	await _assert_owner_mirror_matches(a, "start")
	var a_consumes: Array[Array] = _consume_results_of(a)
	var b_consumes: Array[Array] = _consume_results_of(b)
	var b_signals: Array[Array] = _mirror_signals_of(b)
	var before: Dictionary = _world.inventory.to_snapshot()
	var server: NetworkService = _cluster.server
	var module: InventoryNetModule = _module(a)
	var long_id: String = "x".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1)

	# Wrong ownership / unknown ids: answered, and nothing tells the requester
	# whether the id exists somewhere else or what kind of item it is.
	module.send_raw_consume_request(1, bobs)
	module.send_raw_consume_request(2, MISSING_ITEM_ID)
	module.send_raw_consume_request(3, lying)
	# Her own item, but not something to eat.
	module.send_raw_consume_request(4, plain)
	# Malformed arguments.
	module.send_raw_consume_request("x", mine)
	module.send_raw_consume_request(5, 12345)
	module.send_raw_consume_request(6, "")
	module.send_raw_consume_request(7, long_id)
	module.send_raw_consume_request(-1, mine)
	module.send_raw_consume_request(8.0, mine)
	module.send_raw_consume_request(9, null)
	module.send_raw_consume_request(10, [mine])
	module.send_raw_consume_request(null, null)
	const EXPECTED_REJECTIONS: int = 13
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == EXPECTED_REJECTIONS), "every manipulated request was rejected (%d)" % server.rejected_intent_count())
	# A request cannot name another player, a quantity or an effect: the
	# handler takes two arguments and the engine refuses a call with more
	# (reported as an engine error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_consume.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, bobs, bob_id)
	module._rpc_request_consume.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, mine, 100.0)
	await _settle()
	Engine.print_error_messages = true

	assert_eq(a_consumes, [
		[1, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[2, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[3, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[4, false, ItemConsumption.REASON_NOT_CONSUMABLE],
		[5, false, IntentValidator.REASON_BAD_TYPE],
		[6, false, IntentValidator.REASON_BAD_ITEM_ID],
		[7, false, IntentValidator.REASON_BAD_ITEM_ID],
		[9, false, IntentValidator.REASON_BAD_TYPE],
		[10, false, IntentValidator.REASON_BAD_TYPE],
	], "answers go to usable request ids only, in order")
	assert_eq(server.rejected_intent_count(InventoryService.REASON_NOT_IN_INVENTORY), 2, "someone else's item, an item lying in the world")
	assert_eq(server.rejected_intent_count(InventoryService.REASON_UNKNOWN_ITEM), 1, "an id that does not exist")
	assert_eq(server.rejected_intent_count(ItemConsumption.REASON_NOT_CONSUMABLE), 1)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE), 6)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_ITEM_ID), 2)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_SEQUENCE), 1)
	assert_eq(server.rejected_intent_count(), EXPECTED_REJECTIONS, "the calls the engine refused never reached the handler")
	assert_eq(_world.inventory.to_snapshot(), before, "server items are unchanged")
	assert_true(_near(_vitals(alice_id).hunger, 70.0) and _near(_vitals(alice_id).thirst, 70.0), "alice's needs are unchanged")
	assert_true(_near(_vitals(bob_id).hunger, 70.0), "bob's item did not feed anybody")
	assert_eq(b_consumes.size() + b_signals.size(), 0, "bob was told nothing")
	assert_eq(b.client_state.get_inventory_item(bobs).get("quantity", 0), 1, "bob still carries his food")

	# The path itself works: a clean request from the same peer is accepted.
	var request_id: int = module.request_consume(mine)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 10), "a valid request still goes through")
	assert_eq(a_consumes[9], [request_id, true, ""])
	assert_true(_near(_vitals(alice_id).hunger, 70.0 - FOOD_HUNGER))
	await _assert_owner_mirror_matches(a, "after the valid request")


func test_consume_request_before_join_is_rejected() -> void:
	assert_true(_start_server(), "server started")
	var item_id: String = _spawn(FOOD)
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var results: Array[Array] = _consume_results_of(stranger)
	var connected: bool = await _wait(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	var before: Dictionary = _world.inventory.to_snapshot()
	assert_eq(_module(stranger).request_consume(item_id), InventoryNetModule.NO_REQUEST, "the client API sends nothing before the join")
	_module(stranger).send_raw_consume_request(1, item_id)
	assert_true(await _wait(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 1), "the server refused the request of a peer that has not joined")
	await _settle()
	assert_eq(_cluster.server.rejected_intent_count(), 1, "exactly the raw request reached the server")
	assert_eq(results.size(), 0, "an unjoined peer is told nothing")
	assert_eq(_world.inventory.to_snapshot(), before)
	assert_eq(_world.online_player_ids().size(), 0)


func test_consume_flood_is_rate_limited_per_peer() -> void:
	const BURST: int = 2
	const FLOOD: int = 5
	# One new token every 100 seconds: only the burst passes within the test.
	_inventory_net.consume_intent_rate_per_sec = 0.01
	_inventory_net.consume_intent_burst = BURST
	assert_true(_start_server(), "server started")
	var food_id: String = _spawn(FOOD, STACK_MAX)
	var bobs: String = _spawn(FOOD, 1, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	if not await _pick_up(a, [food_id]):
		return
	if not await _pick_up(b, [bobs]):
		return
	_vitals(alice_id).hunger = 95.0
	var a_consumes: Array[Array] = _consume_results_of(a)
	var b_consumes: Array[Array] = _consume_results_of(b)
	var requests: Array = []
	for index: int in range(FLOOD):
		requests.append(_module(a).request_consume(food_id))
	assert_true(await _wait(func() -> bool: return a_consumes.size() == FLOOD), "every request was answered (%d)" % a_consumes.size())
	await _settle()
	var expected: Array = []
	for index: int in range(FLOOD):
		expected.append([requests[index], true, ""] if index < BURST else [requests[index], false, NetworkService.RATE_LIMITED])
	assert_eq(a_consumes, expected, "only the burst is accepted")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST, "rejection counter")
	assert_eq(_world.inventory.get_item(food_id).quantity, STACK_MAX - BURST, "refused requests use nothing up")
	assert_true(_near(_vitals(alice_id).hunger, 95.0 - float(BURST) * FOOD_HUNGER), "refused requests feed nobody")
	# The bucket is per peer and separate from the drop bucket: bob eats and
	# alice can still put her stack down.
	var bob_request: int = _module(b).request_consume(bobs)
	assert_true(await _wait(func() -> bool: return b_consumes.size() == 1), "bob was answered")
	assert_eq(b_consumes, [[bob_request, true, ""]])
	var drops: Array[Array] = []
	_module(a).drop_result.connect(func(request_id: int, ok: bool, reason: String) -> void: drops.append([request_id, ok, reason]))
	var drop_request: int = _module(a).request_drop(food_id)
	assert_true(await _wait(func() -> bool: return drops.size() == 1), "alice's drop was answered")
	assert_eq(drops, [[drop_request, true, ""]], "eating does not use up the drop allowance")


func test_a_dead_player_cannot_consume() -> void:
	assert_true(_start_server(), "server started")
	var food_id: String = _spawn(FOOD, 2)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var alice_id: String = a.client_state.local_player_id
	if not await _pick_up(a, [food_id]):
		return
	_vitals(alice_id).hunger = 90.0
	var a_consumes: Array[Array] = _consume_results_of(a)
	assert_true(_survival().apply_damage(alice_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok, "test setup: kill alice")
	assert_false(_survival().is_alive(alice_id))
	# Since P2-T4 the death put her food down where she died. Wait for that
	# to reach her mirror, then watch that the refused request changes nothing.
	assert_true(await _wait(func() -> bool: return a.client_state.world_items.has(food_id) and a.client_state.inventory.is_empty()), "the death's drop reached alice")
	var a_signals: Array[Array] = _mirror_signals_of(a)
	var before: Dictionary = _world.inventory.to_snapshot()
	var request_id: int = _module(a).request_consume(food_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 1), "dead alice got an answer")
	await _settle()
	assert_eq(a_consumes, [[request_id, false, SurvivalService.REASON_PLAYER_DEAD]])
	assert_eq(_cluster.server.rejected_intent_count(SurvivalService.REASON_PLAYER_DEAD), 1, "rejection counter")
	assert_eq(_cluster.server.rejected_intent_count(), 1)
	assert_eq(_world.inventory.to_snapshot(), before, "the item is not used up")
	assert_eq(_vitals(alice_id).hunger, 90.0, "a dead player's needs do not change")
	assert_eq(a_signals.size(), 0)


func test_a_consume_result_sent_by_a_client_is_ignored() -> void:
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var b_consumes: Array[Array] = _consume_results_of(b)
	var server_results: Array[Array] = _consume_results_of(_cluster.server)
	# Real ENet path: the engine refuses these (the sender is not the
	# authority; clients cannot reach each other) and reports each refusal as
	# an engine error, the expected outcome, so printing is off for this block.
	Engine.print_error_messages = false
	for target: int in [NetworkService.SERVER_PEER_ID, b.multiplayer.get_unique_id()]:
		_module(a)._rpc_consume_result.rpc_id(target, FORGED_REQUEST_ID, true, "")
	await _settle()
	Engine.print_error_messages = true
	# Script-level guard, independent of the engine (sender id 0 here), and a
	# client never acts on a request addressed to it.
	_module(b)._rpc_consume_result(FORGED_REQUEST_ID, true, "")
	_module(_cluster.server)._rpc_consume_result(FORGED_REQUEST_ID, true, "")
	_module(b)._rpc_request_consume(FORGED_REQUEST_ID, MISSING_ITEM_ID)
	await _settle()
	assert_eq(b_consumes.size() + server_results.size(), 0, "nothing forged was delivered")
	assert_eq(_module(b).rejected_payload_count, 0, "nothing even reached bob's validation")
	assert_eq(_cluster.server.rejected_intent_count(), 0, "no intent handler ran")


# ------------------------------------------------------------ 3. saving

func test_consumption_is_left_to_the_next_save_and_survives_a_restart() -> void:
	_save_root = "user://test_saves/consume_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	var food_id: String = _spawn(FOOD, 3)
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	_vitals(alice_id).hunger = 90.0
	# The pickup is a major transaction: saved at once (hunger 90, stack of 3).
	if not await _pick_up(a, [food_id]):
		return
	var save: SaveService = SaveService.new(_save_root)
	var a_consumes: Array[Array] = _consume_results_of(a)

	# Eating is not saved on its own.
	var generation: int = save.current_generation(WORLD)
	_module(a).request_consume(food_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 1), "alice ate")
	assert_eq(a_consumes[0].slice(1), [true, ""])
	await _settle()
	assert_eq(save.current_generation(WORLD), generation, "a consumption alone does not write the world")
	# What a crash right now would bring back: the last save, in which the
	# unit is still in the stack and the hunger is still there (never one
	# without the other).
	var on_disk: ServerWorld = WorldPersistence.new(SaveService.new(_save_root), _config).load_or_create(WORLD)
	assert_not_null(on_disk)
	if on_disk == null:
		return
	assert_eq(on_disk.inventory.get_item(food_id).quantity, 3, "on disk: the stack before the bite")
	assert_true(_near((on_disk.get_system(SurvivalService.SYSTEM_ID) as SurvivalService).get_vitals(alice_id).hunger, 90.0), "on disk: the hunger before the bite")

	# The next save that happens anyway (here: a player leaving) carries it.
	_cluster.remove_client(b)
	assert_true(await _wait(func() -> bool: return save.current_generation(WORLD) > generation), "bob leaving saved the world")
	_module(a).request_consume(food_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 2), "alice ate again")
	var hunger_after: float = _vitals(alice_id).hunger
	assert_true(_near(hunger_after, 90.0 - 2.0 * FOOD_HUNGER), "hunger %f" % hunger_after)

	# --- full restart (the shutdown saves): state comes only from disk ---
	await _cluster.shutdown()
	_cluster = null
	_world = null
	var persistence2: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence2.load_or_create(WORLD)
	assert_not_null(_world, "world restored from save")
	if _world == null:
		return
	assert_eq(_world.inventory.get_item(food_id).quantity, 1, "two units were eaten")
	assert_true(_near(_vitals(alice_id).hunger, hunger_after), "the lowered hunger was saved: %f" % _vitals(alice_id).hunger)
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	if a2 == null:
		fail("alice did not rejoin")
		return
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	assert_eq(a2.client_state.get_inventory_item(food_id).get("quantity", 0), 1)
	await _assert_owner_mirror_matches(a2, "session 2")
	# The last unit: the stack is gone for good.
	var a2_consumes: Array[Array] = _consume_results_of(a2)
	_module(a2).request_consume(food_id)
	assert_true(await _wait(func() -> bool: return a2_consumes.size() == 1), "alice ate the last unit")
	assert_eq(a2_consumes[0].slice(1), [true, ""])
	assert_null(_world.inventory.get_item(food_id))
	assert_true(_world.registry.is_tombstoned(food_id))
	await _assert_owner_mirror_matches(a2, "session 2 after the last unit")


func test_consumption_can_be_configured_to_save_at_once() -> void:
	_inventory_net.save_after_consume = true
	_save_root = "user://test_saves/consume_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	var food_id: String = _spawn(FOOD, 2)
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	if a == null:
		fail("alice did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	_vitals(alice_id).hunger = 90.0
	if not await _pick_up(a, [food_id]):
		return
	var save: SaveService = SaveService.new(_save_root)
	var generation: int = save.current_generation(WORLD)
	var a_consumes: Array[Array] = _consume_results_of(a)
	_module(a).request_consume(food_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 1), "alice ate")
	assert_eq(a_consumes[0].slice(1), [true, ""])
	assert_true(save.current_generation(WORLD) > generation, "the consumption was saved before the answer went out")
	var on_disk: ServerWorld = WorldPersistence.new(SaveService.new(_save_root), _config).load_or_create(WORLD)
	assert_not_null(on_disk)
	if on_disk == null:
		return
	assert_eq(on_disk.inventory.get_item(food_id).quantity, 1)
	assert_true(_near((on_disk.get_system(SurvivalService.SYSTEM_ID) as SurvivalService).get_vitals(alice_id).hunger, 90.0 - FOOD_HUNGER))


# ------------------------------------------------------------ rules (no network)

func test_default_settings_and_request_validation() -> void:
	var settings: InventoryNetSettings = InventoryNetSettings.load_or_default()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	assert_false(settings.save_after_consume, "shipped policy: consumption waits for the next save")
	assert_true(settings.consume_intent_rate_per_sec > 0.0 and settings.consume_intent_burst >= 1)
	var broken: InventoryNetSettings = InventoryNetSettings.new()
	broken.consume_intent_rate_per_sec = 0.0
	assert_eq(broken.validate().size(), 1, "; ".join(broken.validate()))
	assert_eq(BuildInfo.PROTOCOL_VERSION, 8, "the consume RPCs were a protocol change (5); 6 since the rest RPCs (P2-T8), 7 since the character RPCs (P2-T9), 8 since P2-T10..T12")
	assert_eq(InventoryNetModule.validate_consume_request(1, "item_000001"), "")
	assert_eq(InventoryNetModule.validate_consume_request("1", "item_000001"), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_consume_request(1, &"item_000001"), IntentValidator.REASON_BAD_TYPE, "StringName is not String")
	assert_eq(InventoryNetModule.validate_consume_request(-1, "item_000001"), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(InventoryNetModule.validate_consume_request(1, ""), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(InventoryNetModule.validate_consume_request(1, "x".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1)), IntentValidator.REASON_BAD_ITEM_ID)
	# What the requester is told never reveals whether a foreign id exists.
	assert_eq(InventoryNetModule.public_reason(ItemConsumption.REASON_NOT_CONSUMABLE), ItemConsumption.REASON_NOT_CONSUMABLE)
	assert_eq(InventoryNetModule.public_reason(InventoryService.REASON_UNKNOWN_ITEM), InventoryService.REASON_NOT_IN_INVENTORY)
	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	var module: InventoryNetModule = service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	assert_eq(module.request_consume("item_000001"), InventoryNetModule.NO_REQUEST, "nothing is sent while offline")
	service.free()
