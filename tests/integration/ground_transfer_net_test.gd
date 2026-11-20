extends TestCase
## P2-T15 (docs/00 ADR-021, docs/09 §14.29): items travel between players
## over the ground, over real ENet (server + 3 clients). A client names an
## item it carries and how many units to put down; the server decides
## everything else from its own state. The units lie in the world for
## everybody; whoever picks them up gets them merged into the stacks it
## carries. Each inventory is replicated to its owner only, and no request
## puts an item into another player's inventory (the hand-over intent of
## P2-T14 is gone). Rules: tests/unit/ground_transfer_test.gd.
## (This file replaces tests/integration/hand_over_net_test.gd.)

const WORLD: String = "ground_transfer_net_test_world"
const NEVER: float = 1.0e9
const FOOD: String = "t15n_food"
const FOOD_HUNGER: float = 30.0
const PLAIN: String = "t15n_plain"
const BULK: String = "t15n_bulk"
const STACK_MAX: int = 5
const CELL: String = DevWorldSeed.DEV_CELL_ID
## Players spawn at the origin; these positions are within pickup range.
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const OTHER_ITEM_AT: Vector3 = Vector3(-0.5, 0.0, 1.0)
const THIRD_ITEM_AT: Vector3 = Vector3(0.5, 0.0, -1.0)
const WAIT_MSEC: int = 6000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const LETHAL_DAMAGE: float = 100000.0
const FORGED_REQUEST_ID: int = 77
const MISSING_ITEM_ID: String = "item_999999"
const HUGE_QUANTITY: int = 9223372036854775807
## Needs that must not move on their own during a test.
const FROZEN_NEED_HOURS: float = 100000.0
## Every RPC of the inventory module (P2-T15: no hand-over RPC among them).
const INVENTORY_RPCS: Array = [
	"_rpc_consume_result",
	"_rpc_drop_result",
	"_rpc_inventory_item_changed",
	"_rpc_inventory_items_removed",
	"_rpc_request_consume",
	"_rpc_request_drop",
	"_rpc_request_use_on",
	"_rpc_treatment_notice",
	"_rpc_use_on_result",
	"_rpc_world_items_added",
	# P3-2: the world items of a cell the client is no longer told about.
	"_rpc_world_items_removed",
]

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
	_net_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	_net_settings.pickup_intent_burst = GENEROUS_BURST
	_inventory_net = InventoryNetSettings.new()
	_inventory_net.drop_intent_rate_per_sec = GENEROUS_RATE
	_inventory_net.drop_intent_burst = GENEROUS_BURST
	_inventory_net.consume_intent_rate_per_sec = GENEROUS_RATE
	_inventory_net.consume_intent_burst = GENEROUS_BURST
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.catalog = _new_catalog()
	# Vitals change only when a test changes them.
	_config.survival = SurvivalSettings.new()
	_config.survival.hunger_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.thirst_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.fatigue_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.wound_recovery_per_world_sec = 0.0
	_config.survival.stamina_regen_per_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	_config.survival_net = SurvivalNetSettings.new()
	_config.survival_net.owner_snapshot_rate_hz = 20.0
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

## The shipped item definitions plus a test food, a single item and a stack.
func _new_catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var food: ItemDefinition = ItemDefinition.new()
	food.definition_id = FOOD
	food.max_stack = STACK_MAX
	food.consume_hunger_reduction = FOOD_HUNGER
	catalog.add(food)
	var plain: ItemDefinition = ItemDefinition.new()
	plain.definition_id = PLAIN
	plain.max_stack = 1
	catalog.add(plain)
	var bulk: ItemDefinition = ItemDefinition.new()
	bulk.definition_id = BULK
	bulk.max_stack = STACK_MAX
	catalog.add(bulk)
	return catalog


func _start_server() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


## Joins "alice", "bob" and "carol" (after the test placed its items).
func _join_three() -> Array[NetworkService]:
	var joined: Array[NetworkService] = []
	for key: String in ["alice", "bob", "carol"]:
		var client: NetworkService = await _cluster.join_client(key)
		if client == null:
			fail("%s did not join" % key)
			return []
		joined.append(client)
	return joined


func _module(service: NetworkService) -> InventoryNetModule:
	return service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _spawn(definition_id: String, quantity: int = 1, position: Vector3 = ITEM_AT) -> String:
	return _world.inventory.spawn_world_item(definition_id, quantity, CELL, position)


## Rows [request_id, ok, reason] of every drop result of `service`.
func _drop_results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).drop_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Rows [request_id, ok, reason] of every pickup result of `service`.
func _pickup_results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	service.pickup_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Every treatment notice `service` receives from now on.
func _treatment_notices_of(service: NetworkService) -> Array[Dictionary]:
	var notices: Array[Dictionary] = []
	_module(service).treatment_seen.connect(func(notice: Dictionary) -> void: notices.append(notice))
	return notices


## Rows [signal name, payload] of the inventory and world item signals of
## `service`.
func _inventory_signals_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	var module: InventoryNetModule = _module(service)
	module.inventory_items_removed.connect(func(ids: PackedStringArray) -> void: rows.append(["inventory_items_removed", Array(ids)]))
	module.inventory_item_changed.connect(func(item_id: String) -> void: rows.append(["inventory_item_changed", item_id]))
	module.world_items_added.connect(func(ids: PackedStringArray) -> void: rows.append(["world_items_added", Array(ids)]))
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


## Sends one pickup request and waits for its answer: [ok, reason].
func _pickup(client: NetworkService, item_id: String) -> Array:
	var rows: Array[Array] = _pickup_results_of(client)
	var request_id: int = client.request_pickup(item_id)
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	if not answered:
		fail("the pickup request was not answered")
		return [false, "no_answer"]
	if int(rows[0][0]) != request_id:
		fail("the answer carries another request id: %s" % str(rows[0]))
	return [rows[0][1], rows[0][2]]


## Picks up `item_ids` (test setup) and fails the test when one is refused.
func _pick_up(client: NetworkService, item_ids: Array) -> bool:
	for item_id: String in item_ids:
		var answer: Array = await _pickup(client, item_id)
		if answer != [true, ""]:
			fail("test setup: pickup of %s failed: %s" % [item_id, str(answer)])
			return false
	return true


## Sends one drop request and waits for its answer: [ok, reason].
func _drop(client: NetworkService, item_id: String, quantity: int = InventoryService.WHOLE_STACK) -> Array:
	var rows: Array[Array] = _drop_results_of(client)
	var request_id: int = _module(client).request_drop(item_id, quantity)
	if request_id == InventoryNetModule.NO_REQUEST:
		fail("the drop request was not sent")
		return [false, "not_sent"]
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	if not answered:
		fail("the drop request was not answered")
		return [false, "no_answer"]
	if int(rows[0][0]) != request_id:
		fail("the answer carries another request id: %s" % str(rows[0]))
	return [rows[0][1], rows[0][2]]


## [slot, definition, quantity] of what a player carries on the server.
func _server_rows(player_id: String) -> Array:
	var rows: Array = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		rows.append([item.slot_id, item.definition_id, item.quantity])
	return rows


## What a player carries on the server, as the dictionaries its client
## mirrors, sorted by item id.
func _server_inventory(player_id: String) -> Array:
	var entries: Array = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		entries.append(item.to_dict())
	entries.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return str(left["item_instance_id"]) < str(right["item_instance_id"]))
	return entries


## The client's inventory mirror, sorted by item id.
func _mirror_inventory(client: NetworkService) -> Array:
	var entries: Array = []
	for entry: Dictionary in client.client_state.inventory:
		entries.append(entry.duplicate(true))
	entries.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return str(left["item_instance_id"]) < str(right["item_instance_id"]))
	return entries


## The items lying in the world as the server describes them, by id.
func _server_world_items() -> Dictionary:
	var items: Dictionary = {}
	for item_id: String in _world.inventory.world_item_ids():
		items[item_id] = _world.inventory.describe_world_item(item_id)
	return items


## The client's mirror of the items lying in the world, by id.
func _mirror_world_items(client: NetworkService) -> Dictionary:
	var items: Dictionary = {}
	for item_id: String in client.client_state.world_items:
		items[item_id] = client.client_state.world_items[item_id].duplicate(true)
	return items


## Waits until every client's inventory mirror equals what the server holds
## for its player and every client's world item mirror equals the server's
## world items, and asserts both.
func _assert_mirrors_match(clients: Array[NetworkService], label: String) -> void:
	for client: NetworkService in clients:
		var player_id: String = client.client_state.local_player_id
		var matches: bool = await _wait(func() -> bool: return _mirror_inventory(client) == _server_inventory(player_id) and _mirror_world_items(client) == _server_world_items())
		assert_true(matches, "%s: the mirror of %s equals the server: %s vs %s; world %s vs %s" % [label, player_id, str(_mirror_inventory(client)), str(_server_inventory(player_id)), str(_mirror_world_items(client)), str(_server_world_items())])


## Units per definition over every item that exists on the server.
func _totals() -> Dictionary:
	var totals: Dictionary = {}
	for entry: Dictionary in _world.inventory.to_snapshot()[InventoryService.SNAPSHOT_ITEMS]:
		var definition_id: String = str(entry["definition_id"])
		totals[definition_id] = int(totals.get(definition_id, 0)) + int(entry["quantity"])
	return totals


# ------------------------------------------------------------ 1. over the ground

func test_units_put_down_by_one_client_are_seen_by_all_and_merge_into_the_pickers_stack() -> void:
	assert_true(_start_server(), "server started")
	var food: String = _spawn(FOOD, 3)
	var bobs: String = _spawn(FOOD, 1, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [food]):
		return
	if not await _pick_up(b, [bobs]):
		return
	await _assert_mirrors_match(clients, "start")
	var totals: Dictionary = _totals()
	assert_eq(totals.get(FOOD, 0), 4)
	var a_signals: Array[Array] = _inventory_signals_of(a)
	var b_signals: Array[Array] = _inventory_signals_of(b)
	var c_signals: Array[Array] = _inventory_signals_of(c)
	var c_treatments: Array[Dictionary] = _treatment_notices_of(c)
	var c_owner_messages: int = _module(c).owner_message_count
	var b_owner_messages: int = _module(b).owner_message_count

	# --- alice puts ONE unit of her stack down.
	assert_eq(await _drop(a, food, 1), [true, ""])
	assert_eq(_server_rows(alice_id), [["slot_0", FOOD, 2]], "server: alice keeps the rest of her stack")
	var lying_ids: PackedStringArray = _world.inventory.world_item_ids()
	assert_eq(lying_ids.size(), 1, "server: one item lies in the world")
	var lying: String = lying_ids[0]
	assert_ne(lying, food, "the unit is a new item with a new id")
	assert_eq(_world.inventory.get_item(lying).quantity, 1)
	assert_eq(_world.inventory.world_position_of(lying), _world.get_player(alice_id).position, "where the server knows alice to be")
	await _assert_mirrors_match(clients, "after one unit was put down")
	for client: NetworkService in clients:
		var entry: Dictionary = client.client_state.world_items.get(lying, {})
		assert_eq(entry.get("definition_id", ""), FOOD, "everybody sees what lies there")
		assert_eq(entry.get("quantity", 0), 1, "and how many")
		assert_eq(entry.get("position", Vector3.INF), _world.get_player(alice_id).position)
		var keys: Array = entry.keys()
		keys.sort()
		assert_eq(keys, ["definition_id", "item_instance_id", "position", "quantity"], "a world item says nothing about who put it down")
	assert_eq(a_signals, [["inventory_item_changed", food], ["world_items_added", [lying]]], "alice: her smaller stack, then the item in the world")
	assert_eq(b_signals, [["world_items_added", [lying]]], "bob: only the item in the world")
	assert_eq(c_signals, [["world_items_added", [lying]]], "carol: only the item in the world")
	assert_eq(_module(b).owner_message_count, b_owner_messages, "bob was sent nothing about alice's inventory")
	assert_eq(_server_rows(bob_id), [["slot_0", FOOD, 1]], "nothing reached bob's inventory by itself")

	# --- bob picks it up: it joins the stack he carries.
	a_signals.clear()
	b_signals.clear()
	c_signals.clear()
	assert_eq(await _pickup(b, lying), [true, ""])
	assert_eq(_server_rows(bob_id), [["slot_0", FOOD, 2]], "server: one stack of two, not two slots")
	assert_null(_world.inventory.get_item(lying), "the picked-up item merged away")
	assert_true(_world.registry.is_tombstoned(lying), "its id is retired")
	await _assert_mirrors_match(clients, "after the pickup")
	assert_false(b.client_state.has_inventory_item(lying), "bob's mirror never held the item that merged away")
	assert_eq(b_signals, [["inventory_item_changed", bobs]], "bob: his grown stack")
	assert_eq(a_signals.size() + c_signals.size(), 0, "nobody else is told what bob carries")
	for client: NetworkService in clients:
		assert_false(client.client_state.world_items.has(lying), "the item left everybody's world")

	# --- alice puts the rest down as a whole stack, bob picks that up too.
	assert_eq(await _drop(a, food), [true, ""])
	assert_eq(_server_rows(alice_id), [])
	assert_eq(_world.inventory.world_item_ids(), PackedStringArray([food]), "the whole stack lies there under its own id")
	await _assert_mirrors_match(clients, "after the whole stack was put down")
	assert_eq(await _pickup(b, food), [true, ""])
	assert_eq(_server_rows(bob_id), [["slot_0", FOOD, 4]])
	await _assert_mirrors_match(clients, "after the second pickup")

	# --- more than his stack can take: the rest keeps its id in a new slot.
	var more: String = _spawn(FOOD, 3, THIRD_ITEM_AT)
	assert_eq(await _pickup(b, more), [true, ""])
	assert_eq(_server_rows(bob_id), [["slot_0", FOOD, STACK_MAX], ["slot_1", FOOD, 2]], "one unit filled the stack, two took a slot")
	assert_eq(_world.inventory.get_item(more).location_id, _world.get_player(bob_id).inventory_id, "the same instance, now carried")
	await _assert_mirrors_match(clients, "after the overflowing pickup")
	totals[FOOD] = int(totals[FOOD]) + 3
	assert_eq(_totals(), totals, "no unit was lost or copied")

	# --- carol, who only watched, was told about the world and nothing else.
	await _settle()
	assert_eq(_module(c).owner_message_count, c_owner_messages, "no inventory message ever went to carol")
	assert_eq(c.client_state.inventory.size(), 0)
	assert_eq(c_treatments.size(), 0, "moving items is not tending to anybody")
	assert_eq(_module(a).rejected_payload_count + _module(b).rejected_payload_count + _module(c).rejected_payload_count, 0, "every server message passed the client's checks")


# ------------------------------------------------------------ 2. refused and manipulated requests

func test_refused_and_manipulated_drop_requests_change_nothing() -> void:
	assert_true(_start_server(), "server started")
	var food: String = _spawn(FOOD, 3)
	var bobs: String = _spawn(FOOD, 2, OTHER_ITEM_AT)
	var lying: String = _spawn(PLAIN, 1, THIRD_ITEM_AT)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [food]):
		return
	if not await _pick_up(b, [bobs]):
		return
	await _assert_mirrors_match(clients, "start")
	var a_results: Array[Array] = _drop_results_of(a)
	var a_signals: Array[Array] = _inventory_signals_of(a)
	var b_signals: Array[Array] = _inventory_signals_of(b)
	var c_signals: Array[Array] = _inventory_signals_of(c)
	var before: Dictionary = _world.inventory.to_snapshot()
	var server: NetworkService = _cluster.server
	var module: InventoryNetModule = _module(a)

	# Malformed quantities (the other arguments: inventory_net_test.gd).
	module.send_raw_drop_request(1, food, "1")
	module.send_raw_drop_request(2, food, 1.0)
	module.send_raw_drop_request(3, food, null)
	module.send_raw_drop_request(4, food, Vector3.ZERO)
	module.send_raw_drop_request(5, food, true)
	module.send_raw_drop_request(6, food, [1])
	module.send_raw_drop_request(7, food, -1)
	module.send_raw_drop_request(8, food, -9223372036854775807)
	module.send_raw_drop_request("x", food, 1)
	module.send_raw_drop_request(-1, food, 1)
	const MALFORMED: int = 10
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == MALFORMED), "every malformed request was rejected (%d)" % server.rejected_intent_count())
	# Well-formed lies: more units than the stack holds, somebody else's
	# stack, an item lying in the world, ids of other things.
	module.send_raw_drop_request(9, food, 4)
	module.send_raw_drop_request(10, food, HUGE_QUANTITY)
	module.send_raw_drop_request(11, bobs, 1)
	module.send_raw_drop_request(12, bobs, 99)
	module.send_raw_drop_request(13, lying, 1)
	module.send_raw_drop_request(14, MISSING_ITEM_ID, 1)
	module.send_raw_drop_request(15, bob_id, 1)
	const LIES: int = 7
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == MALFORMED + LIES), "every lie was refused (%d)" % server.rejected_intent_count())
	# A request cannot carry a position, an owner or a receiving player: the
	# handler takes three arguments and the engine refuses a call with more
	# (reported as an engine error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_drop.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, food, 1, Vector3(50.0, 0.0, 50.0))
	module._rpc_request_drop.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, food, 1, bob_id)
	await _settle()
	Engine.print_error_messages = true
	assert_eq(a_results, [
		[1, false, IntentValidator.REASON_BAD_TYPE],
		[2, false, IntentValidator.REASON_BAD_TYPE],
		[3, false, IntentValidator.REASON_BAD_TYPE],
		[4, false, IntentValidator.REASON_BAD_TYPE],
		[5, false, IntentValidator.REASON_BAD_TYPE],
		[6, false, IntentValidator.REASON_BAD_TYPE],
		[7, false, InventoryService.REASON_BAD_QUANTITY],
		[8, false, InventoryService.REASON_BAD_QUANTITY],
		[9, false, InventoryService.REASON_BAD_QUANTITY],
		[10, false, InventoryService.REASON_BAD_QUANTITY],
		[11, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[12, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[13, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[14, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[15, false, InventoryService.REASON_NOT_IN_INVENTORY],
	], "answers go to usable request ids only, in order; an id that does not exist is told like one that is not carried")
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE), 7)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_SEQUENCE), 1)
	assert_eq(server.rejected_intent_count(InventoryService.REASON_BAD_QUANTITY), 4)
	assert_eq(server.rejected_intent_count(InventoryService.REASON_NOT_IN_INVENTORY), 3, "bob's stack twice, the item lying in the world")
	assert_eq(server.rejected_intent_count(InventoryService.REASON_UNKNOWN_ITEM), 2, "the counter keeps the server's own reason")
	assert_eq(server.rejected_intent_count(), MALFORMED + LIES, "the calls the engine refused never reached the handler")

	# Who cannot put anything down: a sleeper must get up first, the dead
	# cannot (their belongings lie on the ground anyway).
	a_results.clear()
	assert_true(_survival().start_rest(alice_id).ok, "alice lies down")
	assert_eq(await _drop(a, food, 1), [false, SurvivalService.REASON_PLAYER_RESTING])
	assert_true(_survival().stop_rest(alice_id).ok)
	await _settle()
	assert_eq(_world.inventory.to_snapshot(), before, "no refused request changed an item")
	assert_eq(a_signals.size() + b_signals.size() + c_signals.size(), 0, "no inventory or world message was sent")
	await _assert_mirrors_match(clients, "after the refusals")
	assert_true(_survival().apply_damage(bob_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(await _drop(b, bobs, 1), [false, SurvivalService.REASON_PLAYER_DEAD], "a dead player puts nothing down")


func test_no_request_puts_an_item_into_another_players_inventory() -> void:
	assert_true(_start_server(), "server started")
	var food: String = _spawn(FOOD, 3)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [food]):
		return
	await _assert_mirrors_match(clients, "start")
	var module: InventoryNetModule = _module(a)
	# The hand-over intent of P2-T14 no longer exists on either side.
	for method: String in ["request_hand_over", "send_raw_hand_over_request", "_rpc_request_hand_over", "_rpc_hand_over_result", "_rpc_hand_over_notice"]:
		assert_false(module.has_method(method), "%s is gone" % method)
		assert_false(_module(_cluster.server).has_method(method), "%s is gone on the server" % method)
	var rpc_names: Array = []
	for key: Variant in (module.get_script() as Script).get_rpc_config().keys():
		rpc_names.append(str(key))
	rpc_names.sort()
	assert_eq(rpc_names, INVENTORY_RPCS, "the RPCs of the inventory module: none moves an item to another player")
	# A client of the old protocol that still sends it reaches nothing (the
	# engine reports the unknown RPC as an error, the expected outcome).
	var before: Dictionary = _world.inventory.to_snapshot()
	var rejected_before: int = _cluster.server.rejected_intent_count()
	var b_signals: Array[Array] = _inventory_signals_of(b)
	Engine.print_error_messages = false
	module.rpc_id(NetworkService.SERVER_PEER_ID, &"_rpc_request_hand_over", FORGED_REQUEST_ID, food, bob_id, 1)
	await _settle()
	Engine.print_error_messages = true
	assert_eq(_world.inventory.to_snapshot(), before, "nothing moved")
	assert_eq(_cluster.server.rejected_intent_count(), rejected_before)
	assert_eq(_server_rows(bob_id), [], "bob's inventory is empty as before")
	# What a player CAN do for another: feed it (the unit is used up, nothing
	# arrives in the other inventory) or put the item down next to it.
	var use_results: Array[Array] = []
	module.use_on_result.connect(func(request_id: int, ok: bool, reason: String) -> void: use_results.append([request_id, ok, reason]))
	module.request_use_on(food, bob_id)
	assert_true(await _wait(func() -> bool: return use_results.size() == 1), "the use-on request was answered")
	assert_eq(use_results[0][1], true, str(use_results))
	assert_eq(_server_rows(alice_id), [["slot_0", FOOD, 2]], "one unit was used up")
	assert_eq(_server_rows(bob_id), [], "feeding bob put nothing into his inventory")
	assert_eq(await _drop(a, food, 1), [true, ""])
	await _settle()
	assert_eq(_server_rows(bob_id), [], "an item put down next to bob is not his until he picks it up")
	assert_eq(b_signals.size(), 1, "bob was told about the item in the world and nothing else: %s" % str(b_signals))
	assert_eq(b_signals[0][0], "world_items_added")
	assert_eq(c.client_state.inventory.size(), 0)


func test_a_server_rule_that_transfers_reaches_both_owners_only() -> void:
	# InventoryService.transfer_item stays as a server rule entry (no player
	# intent calls it since P2-T15). When a rule uses it, each owner is sent
	# its own inventory and nobody else anything.
	assert_true(_start_server(), "server started")
	var food: String = _spawn(FOOD, 4)
	var bobs: String = _spawn(FOOD, 4, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [food]):
		return
	if not await _pick_up(b, [bobs]):
		return
	await _assert_mirrors_match(clients, "start")
	var a_signals: Array[Array] = _inventory_signals_of(a)
	var b_signals: Array[Array] = _inventory_signals_of(b)
	var c_signals: Array[Array] = _inventory_signals_of(c)
	var c_owner_messages: int = _module(c).owner_message_count
	var alice_inventory: String = _world.get_player(alice_id).inventory_id
	var bob_inventory: String = _world.get_player(bob_id).inventory_id
	# Three of four: one fills bob's stack, two arrive as a new stack.
	var moved: ActionResult = _world.inventory.transfer_item(alice_inventory, food, bob_inventory, 3)
	assert_true(moved.ok, moved.reason)
	await _assert_mirrors_match(clients, "after the transfer")
	assert_eq(_server_rows(alice_id), [["slot_0", FOOD, 1]])
	assert_eq(_server_rows(bob_id), [["slot_0", FOOD, STACK_MAX], ["slot_1", FOOD, 2]])
	assert_eq(a_signals, [["inventory_item_changed", food]], "alice: her smaller stack")
	assert_eq(b_signals.size(), 2, "bob: the stack that grew and the one that arrived: %s" % str(b_signals))
	# The last unit: alice's stack merges away and she is told it is gone.
	a_signals.clear()
	assert_true(_world.inventory.transfer_item(alice_inventory, food, bob_inventory, 1).ok)
	await _assert_mirrors_match(clients, "after the last unit")
	assert_eq(a_signals, [["inventory_items_removed", [food]]])
	await _settle()
	assert_eq(c_signals.size(), 0, "carol was told nothing")
	assert_eq(_module(c).owner_message_count, c_owner_messages)


# ------------------------------------------------------------ 3. save and restart

func test_units_put_down_and_merged_pickups_survive_a_save_and_server_restart() -> void:
	_save_root = "user://test_saves/ground_transfer_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	var food: String = _spawn(FOOD, 4)
	var plain: String = _spawn(PLAIN, 1, OTHER_ITEM_AT)
	var bobs_food: String = _spawn(FOOD, 3, THIRD_ITEM_AT)
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [food, plain]):
		return
	if not await _pick_up(b, [bobs_food]):
		return
	var save: SaveService = SaveService.new(_save_root)

	# Putting units down is saved at once, like a pickup.
	var generation: int = save.current_generation(WORLD)
	assert_eq(await _drop(a, food, 3), [true, ""])
	assert_true(save.current_generation(WORLD) > generation, "the drop was saved before the answer went out")
	var lying: String = _world.inventory.world_item_ids()[0]
	# A refused one is not.
	generation = save.current_generation(WORLD)
	assert_eq(await _drop(a, food, 5), [false, InventoryService.REASON_BAD_QUANTITY])
	assert_eq(save.current_generation(WORLD), generation, "a refused drop writes no save")
	# Bob picks the three units up: two fill his stack, one takes a slot.
	assert_eq(await _pickup(b, lying), [true, ""])
	assert_true(save.current_generation(WORLD) > generation, "the pickup was saved")
	assert_eq(await _drop(a, plain), [true, ""])
	var alice_rows: Array = _server_rows(alice_id)
	var bob_rows: Array = _server_rows(bob_id)
	assert_eq(alice_rows, [["slot_0", FOOD, 1]])
	assert_eq(bob_rows, [["slot_0", FOOD, STACK_MAX], ["slot_1", FOOD, 1]], "two units filled bob's stack, the third keeps the lying item's id in a slot")
	assert_eq(_world.inventory.world_item_ids(), PackedStringArray([plain]))
	var snapshot_text: String = JSON.stringify(_world.inventory.to_snapshot())
	var two: Array[NetworkService] = [a, b]
	await _assert_mirrors_match(two, "session 1")

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
	assert_eq(_server_rows(alice_id), alice_rows, "alice's inventory was restored")
	assert_eq(_server_rows(bob_id), bob_rows, "bob's inventory was restored")
	assert_eq(JSON.stringify(_world.inventory.to_snapshot()), snapshot_text, "the same items, ids, slots, quantities and positions")
	assert_eq(_world.inventory.get_item(lying).location_id, _world.get_player(bob_id).inventory_id, "the item bob picked up is his after the restart")
	assert_eq(_world.inventory.world_item_ids(), PackedStringArray([plain]), "what lay on the ground still lies there")
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	var b2: NetworkService = await _cluster.join_client("bob")
	if a2 == null or b2 == null:
		fail("clients did not rejoin")
		return
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	assert_eq(b2.client_state.local_player_id, bob_id)
	var two_again: Array[NetworkService] = [a2, b2]
	await _assert_mirrors_match(two_again, "session 2")
	# The game goes on: alice puts her last unit down, bob's second stack
	# takes it, and ids never come back.
	assert_eq(await _drop(a2, food, 1), [true, ""])
	assert_eq(await _pickup(b2, food), [true, ""])
	await _assert_mirrors_match(two_again, "session 2 after another round")
	assert_eq(_server_rows(alice_id), [])
	assert_eq(_server_rows(bob_id), [["slot_0", FOOD, STACK_MAX], ["slot_1", FOOD, 2]])
	assert_true(_world.registry.is_tombstoned(food), "alice's stack merged away")
	var fresh: String = _spawn(PLAIN)
	for used: String in [food, plain, bobs_food, lying]:
		assert_true(EntityIdGenerator.sequence_of(fresh) > EntityIdGenerator.sequence_of(used), "new ids continue after every id ever used")


# ------------------------------------------------------------ rules (no network)

func test_rpc_table_and_drop_request_validation() -> void:
	assert_eq(BuildInfo.PROTOCOL_VERSION, 18, "the drop quantity and the withdrawn hand-over RPCs were a protocol change (10, P2-T15); 11 since the trade RPCs (P2-T16), 12 since the structure RPCs (P3-4a), 13 since the replication scope by cell (P3-2), 14 since the construction RPCs (P3-5), 15 since the container RPCs (P3-3)")
	const ITEM: String = "item_000001"
	assert_eq(InventoryService.WHOLE_STACK, 0)
	assert_eq(InventoryNetModule.validate_drop_request(1, ITEM, 1), "")
	assert_eq(InventoryNetModule.validate_drop_request(0, "x", InventoryService.WHOLE_STACK), "", "the whole stack")
	assert_eq(InventoryNetModule.validate_drop_request(1, ITEM, HUGE_QUANTITY), "", "how many the stack holds is the transaction's check")
	assert_eq(InventoryNetModule.validate_drop_request("1", ITEM, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_drop_request(1.0, ITEM, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_drop_request(1, 5, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_drop_request(1, &"item_000001", 1), IntentValidator.REASON_BAD_TYPE, "StringName is not String")
	assert_eq(InventoryNetModule.validate_drop_request(1, ITEM, 1.0), IntentValidator.REASON_BAD_TYPE, "a quantity is a whole number")
	assert_eq(InventoryNetModule.validate_drop_request(1, ITEM, "1"), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_drop_request(1, ITEM, null), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_drop_request(1, ITEM, true), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_drop_request(-1, ITEM, 1), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(InventoryNetModule.validate_drop_request(1, "", 1), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(InventoryNetModule.validate_drop_request(1, "i".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1), 1), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(InventoryNetModule.validate_drop_request(1, ITEM, -1), InventoryService.REASON_BAD_QUANTITY)
	assert_eq(InventoryNetModule.validate_drop_request(1, ITEM, -9223372036854775807), InventoryService.REASON_BAD_QUANTITY)
	# The order: types, request id, item id, quantity.
	assert_eq(InventoryNetModule.validate_drop_request(-1, "", -1), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(InventoryNetModule.validate_drop_request(1, "", -1), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(InventoryNetModule.validate_drop_request("x", "", 1.5), IntentValidator.REASON_BAD_TYPE)
	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	var module: InventoryNetModule = service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	assert_eq(module.request_drop(ITEM, 1), InventoryNetModule.NO_REQUEST, "nothing is sent while offline")
	# Channel 0, reliable; the request from any peer.
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	var method_config: Dictionary = rpc_config.get(&"_rpc_request_drop", rpc_config.get("_rpc_request_drop", {}))
	assert_eq(method_config.get("rpc_mode", -1), MultiplayerAPI.RPC_MODE_ANY_PEER)
	assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE)
	assert_eq(method_config.get("call_local", true), false)
	var rpc_names: Array = []
	for key: Variant in rpc_config.keys():
		rpc_names.append(str(key))
	rpc_names.sort()
	assert_eq(rpc_names, INVENTORY_RPCS)
	service.free()
