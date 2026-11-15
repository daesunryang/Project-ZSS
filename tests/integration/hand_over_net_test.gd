extends TestCase
## P2-T14: handing an item over to another player over real ENet (server + 3
## clients). A client names an item it carries, a target player and a
## quantity; the server decides everything else from its own state. The
## units move into the receiver's inventory. The giver learns the result and
## sees its own inventory change, the receiver sees its own inventory change
## and is told who handed it what, and a bystander is told only that one
## player handed something to another (docs/00 ADR-009, ADR-020; docs/09
## §14.28). Rules: tests/unit/hand_over_test.gd.

const WORLD: String = "hand_over_net_test_world"
const NEVER: float = 1.0e9
const FOOD: String = "t14n_food"
const FOOD_HUNGER: float = 30.0
const PLAIN: String = "t14n_plain"
const BULK: String = "t14n_bulk"
const STACK_MAX: int = 5
const PIPE: String = "dev_melee_pipe"
const NEED_TOLERANCE: float = 0.01
const CELL: String = DevWorldSeed.DEV_CELL_ID
## Players spawn at the origin; these positions are within pickup range.
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const OTHER_ITEM_AT: Vector3 = Vector3(-0.5, 0.0, 1.0)
const THIRD_ITEM_AT: Vector3 = Vector3(0.5, 0.0, -1.0)
const FAR_AWAY: Vector3 = Vector3(60.0, 0.0, 0.0)
const WAIT_MSEC: int = 6000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const LETHAL_DAMAGE: float = 100000.0
const FORGED_REQUEST_ID: int = 77
const MISSING_PLAYER_ID: String = "player_999999"
const MISSING_ITEM_ID: String = "item_999999"
const HUGE_QUANTITY: int = 9223372036854775807
## Needs that must not move on their own during a test.
const FROZEN_NEED_HOURS: float = 100000.0
## Words that must not appear in anything a bystander receives.
const PRIVATE_WORDS: PackedStringArray = ["definition", "quantity", "food", "plain", "bulk", "pipe", "item", "inventory", "slot", "stack"]

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
	# Hand-overs use the drop bucket.
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


## The client's survival mirror.
func _mirror(service: NetworkService) -> ClientSurvivalState:
	return (service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule).client_state


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _spawn(definition_id: String, quantity: int = 1, position: Vector3 = ITEM_AT) -> String:
	return _world.inventory.spawn_world_item(definition_id, quantity, CELL, position)


## Rows [request_id, ok, reason] of every hand-over result of `service`.
func _results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).hand_over_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Every hand-over notice `service` receives from now on.
func _notices_of(service: NetworkService) -> Array[Dictionary]:
	var notices: Array[Dictionary] = []
	_module(service).hand_over_seen.connect(func(notice: Dictionary) -> void: notices.append(notice))
	return notices


## Every treatment notice `service` receives from now on (none is expected:
## handing over is not tending).
func _treatment_notices_of(service: NetworkService) -> Array[Dictionary]:
	var notices: Array[Dictionary] = []
	_module(service).treatment_seen.connect(func(notice: Dictionary) -> void: notices.append(notice))
	return notices


## Every survival event `service` receives from now on.
func _survival_events_of(service: NetworkService) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_mirror(service).event_received.connect(func(event: Dictionary) -> void: events.append(event))
	return events


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


## Picks up `item_ids` through the real pickup RPC and waits for the mirror.
func _pick_up(client: NetworkService, item_ids: Array) -> bool:
	for item_id: String in item_ids:
		client.request_pickup(item_id)
	var has_all: Callable = func() -> bool:
		for item_id: String in item_ids:
			if not client.client_state.has_inventory_item(item_id):
				return false
		return true
	var done: bool = await _wait(has_all)
	if not done:
		fail("test setup: pickup of %s failed" % str(item_ids))
	return done


## Sends one hand-over request and waits for its answer: [ok, reason].
func _hand_over(client: NetworkService, item_id: String, target_id: String, quantity: int) -> Array:
	var rows: Array[Array] = _results_of(client)
	var request_id: int = _module(client).request_hand_over(item_id, target_id, quantity)
	if request_id == InventoryNetModule.NO_REQUEST:
		fail("the hand-over request was not sent")
		return [false, "not_sent"]
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	if not answered:
		fail("the hand-over request was not answered")
		return [false, "no_answer"]
	if int(rows[0][0]) != request_id:
		fail("the answer carries another request id: %s" % str(rows[0]))
	return [rows[0][1], rows[0][2]]


func _server_quantity(item_id: String) -> int:
	var item: ItemInstance = _world.inventory.get_item(item_id)
	return 0 if item == null else item.quantity


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


## Waits until the inventory mirror of every client equals what the server
## holds for that client's player, and asserts it.
func _assert_mirrors_match(clients: Array[NetworkService], label: String) -> void:
	for client: NetworkService in clients:
		var player_id: String = client.client_state.local_player_id
		var matches: bool = await _wait(func() -> bool: return _mirror_inventory(client) == _server_inventory(player_id))
		assert_true(matches, "%s: the mirror of %s equals the server: %s vs %s" % [label, player_id, str(_mirror_inventory(client)), str(_server_inventory(player_id))])


## Asserts that a bystander's notice says only who handed something to whom.
func _assert_public_notice(notice: Dictionary, giver_id: String, receiver_id: String, label: String) -> void:
	var keys: Array = notice.keys()
	keys.sort()
	assert_eq(keys, ["giver_id", "receiver_id", "scope", "world_time"], label + ": a public notice carries nothing else")
	assert_eq(notice.get("scope", ""), InventoryNetModule.NOTICE_SCOPE_PUBLIC, label)
	assert_eq(notice.get("giver_id", ""), giver_id, label)
	assert_eq(notice.get("receiver_id", ""), receiver_id, label)
	var text: String = JSON.stringify(notice).to_lower().replace(giver_id, "").replace(receiver_id, "")
	for word: String in PRIVATE_WORDS:
		assert_not_contains(text, word, label + ": a bystander was told what was handed over")


# ------------------------------------------------------------ 1. handing over

func test_a_client_hands_food_over_and_the_receiver_keeps_it_and_eats_it_later() -> void:
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
	# Bob is hungry; being handed food does not change that.
	_survival().get_vitals(bob_id).hunger = 60.0
	assert_true(await _wait(func() -> bool: return _mirror(b).need_category("hunger") == "caution"), "bob's mirror shows his hunger")
	await _settle()
	var a_notices: Array[Dictionary] = _notices_of(a)
	var b_notices: Array[Dictionary] = _notices_of(b)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var treatment_notices: Array[Array] = [_treatment_notices_of(a), _treatment_notices_of(b), _treatment_notices_of(c)]
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	var c_events: Array[Dictionary] = _survival_events_of(c)
	var a_inventory: Array[Array] = _inventory_signals_of(a)
	var b_inventory: Array[Array] = _inventory_signals_of(b)
	var c_inventory: Array[Array] = _inventory_signals_of(c)
	var b_results: Array[Array] = _results_of(b)
	var c_results: Array[Array] = _results_of(c)
	var owner_messages: Array = [_module(a).owner_message_count, _module(b).owner_message_count, _module(c).owner_message_count]

	# Alice hands two of her three units to bob: the item id, the receiver
	# and how many, nothing else.
	assert_eq(await _hand_over(a, food, bob_id, 2), [true, ""])
	assert_eq(_server_rows(alice_id), [["slot_0", FOOD, 1]], "server: one unit stays with alice")
	assert_eq(_server_rows(bob_id), [["slot_0", FOOD, 2]], "server: two units are bob's")
	var bobs_food: String = _world.inventory.items_in_inventory(_world.get_player(bob_id).inventory_id)[0].item_instance_id
	assert_ne(bobs_food, food, "bob's stack has an id of its own")
	assert_true(absf(_survival().get_vitals(bob_id).hunger - 60.0) <= NEED_TOLERANCE, "server: bob was handed food, not fed (%f)" % _survival().get_vitals(bob_id).hunger)
	await _settle()
	await _assert_mirrors_match(clients, "after the hand-over")
	assert_eq(_mirror(b).need_category("hunger"), "caution", "bob's mirror: as hungry as before")

	# Alice: the result and her own smaller stack. No notice.
	assert_eq(a_notices.size(), 0, "the giver gets the result, not a notice: %s" % str(a_notices))
	assert_eq(a_inventory, [["inventory_item_changed", food]], "alice was sent her own stack only")
	# Bob: his new stack and who handed him what and how many.
	assert_eq(b_inventory, [["inventory_item_changed", bobs_food]], "bob was sent his own new stack only")
	assert_eq(b_notices.size(), 1, str(b_notices))
	var b_keys: Array = b_notices[0].keys()
	b_keys.sort()
	assert_eq(b_keys, ["definition_id", "giver_id", "quantity", "receiver_id", "scope", "world_time"])
	assert_eq(b_notices[0].get("scope", ""), InventoryNetModule.NOTICE_SCOPE_TARGET)
	assert_eq(b_notices[0].get("giver_id", ""), alice_id, "bob knows who handed it to him")
	assert_eq(b_notices[0].get("receiver_id", ""), bob_id)
	assert_eq(b_notices[0].get("definition_id", ""), FOOD, "and what")
	assert_eq(b_notices[0].get("quantity", -1), 2, "and how many")
	# Carol: that alice handed something to bob. Not what, not how many, and
	# nothing of anybody's inventory.
	assert_eq(c_notices.size(), 1, str(c_notices))
	_assert_public_notice(c_notices[0], alice_id, bob_id, "carol")
	assert_eq(c_inventory.size(), 0, "carol got no inventory or world item message: %s" % str(c_inventory))
	assert_eq(c.client_state.inventory.size(), 0, "carol's inventory mirror is about herself")
	assert_eq([_module(a).owner_message_count - int(owner_messages[0]), _module(b).owner_message_count - int(owner_messages[1]), _module(c).owner_message_count - int(owner_messages[2])], [1, 1, 0], "one owner-only message each for the giver and the receiver, none for the bystander")
	assert_eq(b_results.size() + c_results.size(), 0, "the result goes to the requester only")
	# Handing over is not tending and changes nobody's vitals.
	assert_eq(treatment_notices[0].size() + treatment_notices[1].size() + treatment_notices[2].size(), 0, "no treatment notice")
	assert_eq(a_events.size() + b_events.size() + c_events.size(), 0, "no survival event: %s %s %s" % [str(a_events), str(b_events), str(c_events)])

	# Bob kept it; now he eats one unit of what he was handed.
	var consumes: Array[Array] = []
	_module(b).consume_result.connect(func(request_id: int, ok: bool, reason: String) -> void: consumes.append([request_id, ok, reason]))
	var consume_id: int = _module(b).request_consume(bobs_food)
	assert_true(await _wait(func() -> bool: return consumes.size() == 1), "bob's consume request was answered")
	assert_eq(consumes, [[consume_id, true, ""]], "bob can use what he was handed")
	assert_true(absf(_survival().get_vitals(bob_id).hunger - (60.0 - FOOD_HUNGER)) <= NEED_TOLERANCE, "server: bob ate (%f)" % _survival().get_vitals(bob_id).hunger)
	assert_true(await _wait(func() -> bool: return _mirror(b).need_category("hunger") == "good"), "bob's mirror: no longer hungry")
	assert_eq(_server_quantity(bobs_food), 1)

	# Alice's last unit: her stack is gone, bob's grows (no second stack).
	a_inventory.clear()
	b_inventory.clear()
	assert_eq(await _hand_over(a, food, bob_id, 1), [true, ""])
	assert_eq(_server_rows(alice_id), [], "server: alice holds nothing")
	assert_eq(_server_rows(bob_id), [["slot_0", FOOD, 2]], "server: merged into bob's stack")
	assert_null(_world.inventory.get_item(food), "server: alice's emptied stack no longer exists")
	await _settle()
	await _assert_mirrors_match(clients, "after the last unit")
	assert_eq(a_inventory, [["inventory_items_removed", [food]]], "alice was told her stack is gone")
	assert_eq(b_inventory, [["inventory_item_changed", bobs_food]], "bob was sent his grown stack")
	assert_eq(c_notices.size(), 2)
	_assert_public_notice(c_notices[1], alice_id, bob_id, "carol, second hand-over")
	assert_eq(c_inventory.size(), 0)
	assert_eq(_cluster.server.rejected_intent_count(), 0, "nothing was refused")
	assert_eq(_module(a).rejected_payload_count + _module(b).rejected_payload_count + _module(c).rejected_payload_count, 0, "the server's own messages pass the client validation")


func test_whole_stacks_single_items_and_overflow_reach_both_mirrors() -> void:
	assert_true(_start_server(), "server started")
	var alices_bulk: String = _spawn(BULK, 4)
	var pipe: String = _spawn(PIPE, 1, OTHER_ITEM_AT)
	var bobs_bulk: String = _spawn(BULK, 3, THIRD_ITEM_AT)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [alices_bulk, pipe]):
		return
	if not await _pick_up(b, [bobs_bulk]):
		return
	# Bob sleeps: he can be handed things and is not woken.
	assert_true(_survival().start_rest(bob_id).ok, "bob lies down")
	await _settle()
	var a_inventory: Array[Array] = _inventory_signals_of(a)
	var b_inventory: Array[Array] = _inventory_signals_of(b)
	var c_inventory: Array[Array] = _inventory_signals_of(c)
	var b_notices: Array[Dictionary] = _notices_of(b)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var c_owner_messages: int = _module(c).owner_message_count

	# An item that is no food and no treatment: the same instance moves.
	assert_eq(await _hand_over(a, pipe, bob_id, 1), [true, ""])
	assert_eq(_world.inventory.get_item(pipe).location_id, _world.get_player(bob_id).inventory_id, "server: the pipe is bob's, with the id it had")
	# Four units into a stack of three (max five): two fill bob's stack, the
	# two left over arrive as alice's own instance in bob's next free slot.
	assert_eq(await _hand_over(a, alices_bulk, bob_id, 4), [true, ""])
	assert_eq(_server_rows(alice_id), [], "server: alice holds nothing")
	assert_eq(_server_rows(bob_id), [["slot_0", BULK, STACK_MAX], ["slot_1", PIPE, 1], ["slot_2", BULK, 2]], "server: bob's stack is full, the rest is a stack of its own")
	assert_true(_survival().is_resting(bob_id), "server: bob sleeps on")
	await _settle()
	await _assert_mirrors_match(clients, "after both hand-overs")
	assert_eq(a_inventory, [["inventory_items_removed", [pipe]], ["inventory_items_removed", [alices_bulk]]])
	assert_eq(b_inventory, [["inventory_item_changed", pipe], ["inventory_item_changed", bobs_bulk], ["inventory_item_changed", alices_bulk]], "bob was sent every stack of his that changed, in order")
	assert_eq(b_notices.size(), 2, str(b_notices))
	assert_eq(b_notices[0].get("definition_id", ""), PIPE)
	assert_eq(b_notices[0].get("quantity", -1), 1)
	assert_eq(b_notices[1].get("definition_id", ""), BULK)
	assert_eq(b_notices[1].get("quantity", -1), 4, "how many were handed over, not how they were stacked")
	assert_eq(c_notices.size(), 2, str(c_notices))
	for notice: Dictionary in c_notices:
		_assert_public_notice(notice, alice_id, bob_id, "carol")
	assert_eq(c_inventory.size(), 0)
	assert_eq(_module(c).owner_message_count, c_owner_messages, "carol got no owner-only message")
	assert_eq(_cluster.server.rejected_intent_count(), 0)


# ------------------------------------------------------------ 2. refusals

func test_refused_hand_overs_change_nothing_and_are_told_to_nobody_else() -> void:
	_config.gameplay.inventory_slot_capacity = 1
	assert_true(_start_server(), "server started")
	var food: String = _spawn(FOOD, 3)
	var bobs: String = _spawn(PLAIN, 1, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var carol_id: String = c.client_state.local_player_id
	if not await _pick_up(a, [food]):
		return
	if not await _pick_up(b, [bobs]):
		return
	await _settle()
	var b_notices: Array[Dictionary] = _notices_of(b)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var a_inventory: Array[Array] = _inventory_signals_of(a)
	var b_inventory: Array[Array] = _inventory_signals_of(b)
	var before: Dictionary = _world.inventory.to_snapshot()
	var server: NetworkService = _cluster.server

	# Bob's only slot is taken.
	assert_eq(await _hand_over(a, food, bob_id, 1), [false, ServerWorld.REASON_TARGET_INVENTORY_FULL], "bob has no room")
	# Not hers to hand over.
	assert_eq(await _hand_over(a, bobs, carol_id, 1), [false, InventoryService.REASON_NOT_IN_INVENTORY], "bob's item to carol")
	assert_eq(await _hand_over(a, MISSING_ITEM_ID, bob_id, 1), [false, InventoryService.REASON_NOT_IN_INVENTORY], "an id that does not exist looks the same")
	# More than she has.
	assert_eq(await _hand_over(a, food, carol_id, 4), [false, InventoryService.REASON_BAD_QUANTITY], "four of three")
	assert_eq(await _hand_over(a, food, carol_id, HUGE_QUANTITY), [false, InventoryService.REASON_BAD_QUANTITY], "a huge quantity")
	# To herself, to nobody.
	assert_eq(await _hand_over(a, food, alice_id, 1), [false, ServerWorld.REASON_TARGET_IS_SELF])
	assert_eq(await _hand_over(a, food, MISSING_PLAYER_ID, 1), [false, ServerWorld.REASON_TARGET_UNAVAILABLE], "no such player")
	# Too far: the server's positions decide, whatever the client believes.
	_world.get_player(carol_id).position = FAR_AWAY
	assert_eq(await _hand_over(a, food, carol_id, 1), [false, ServerWorld.REASON_TARGET_TOO_FAR])
	_world.get_player(carol_id).position = Vector3.ZERO
	# Dead.
	assert_true(_survival().apply_damage(carol_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(await _hand_over(a, food, carol_id, 1), [false, ServerWorld.REASON_TARGET_DEAD])
	# Gone: carol leaves. Her id answers like an unknown one.
	_cluster.remove_client(c)
	assert_true(await _wait(func() -> bool: return not _world.is_online(carol_id)), "carol left")
	assert_eq(await _hand_over(a, food, carol_id, 1), [false, ServerWorld.REASON_TARGET_UNAVAILABLE], "an offline player")
	# A sleeping giver must get up first.
	assert_true(_survival().start_rest(alice_id).ok, "alice lies down")
	assert_eq(await _hand_over(a, food, bob_id, 1), [false, SurvivalService.REASON_PLAYER_RESTING])
	assert_true(_survival().stop_rest(alice_id).ok)
	await _settle()
	assert_eq(_world.inventory.to_snapshot(), before, "no refused request changed an item")
	assert_eq(a_inventory.size() + b_inventory.size(), 0, "no inventory message was sent")
	assert_eq(b_notices.size() + c_notices.size(), 0, "a refused hand-over is told to nobody but the requester")
	assert_eq(server.rejected_intent_count(), 11, "every refusal was counted")
	assert_eq(server.rejected_intent_count(InventoryService.REASON_UNKNOWN_ITEM), 1, "the counter keeps the server's own reason")
	var two: Array[NetworkService] = [a, b]
	await _assert_mirrors_match(two, "after the refusals")
	# The dead hand nothing over.
	assert_true(_survival().apply_damage(bob_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(await _hand_over(b, bobs, alice_id, 1), [false, SurvivalService.REASON_PLAYER_DEAD], "a dead player hands nothing over")


# ------------------------------------------------------------ 3. manipulated requests

func test_manipulated_hand_over_requests_are_rejected_and_change_nothing() -> void:
	assert_true(_start_server(), "server started")
	var food: String = _spawn(FOOD, 3)
	var bobs: String = _spawn(FOOD, 2, OTHER_ITEM_AT)
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
	await _settle()
	var a_results: Array[Array] = _results_of(a)
	var b_notices: Array[Dictionary] = _notices_of(b)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var b_inventory: Array[Array] = _inventory_signals_of(b)
	var before: Dictionary = _world.inventory.to_snapshot()
	var server: NetworkService = _cluster.server
	var module: InventoryNetModule = _module(a)

	# Malformed arguments.
	module.send_raw_hand_over_request("x", food, bob_id, 1)
	module.send_raw_hand_over_request(1, 5, bob_id, 1)
	module.send_raw_hand_over_request(2, food, 7, 1)
	module.send_raw_hand_over_request(3, food, null, 1)
	module.send_raw_hand_over_request(4, food, [bob_id], 1)
	module.send_raw_hand_over_request(5, food, bob_id, "1")
	module.send_raw_hand_over_request(6, food, bob_id, 1.0)
	module.send_raw_hand_over_request(7, food, bob_id, null)
	module.send_raw_hand_over_request(8, food, bob_id, Vector3.ZERO)
	module.send_raw_hand_over_request(-1, food, bob_id, 1)
	module.send_raw_hand_over_request(9, "", bob_id, 1)
	module.send_raw_hand_over_request(10, "i".repeat(200), bob_id, 1)
	module.send_raw_hand_over_request(11, food, "", 1)
	module.send_raw_hand_over_request(12, food, "p".repeat(200), 1)
	module.send_raw_hand_over_request(13, food, bob_id, 0)
	module.send_raw_hand_over_request(14, food, bob_id, -5)
	module.send_raw_hand_over_request(15.0, food, bob_id, 1)
	const MALFORMED: int = 17
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == MALFORMED), "every malformed request was rejected (%d)" % server.rejected_intent_count())
	# A request cannot carry a position, an owner or a receiving slot: the
	# handler takes four arguments and the engine refuses a call with more
	# (reported as an engine error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_hand_over.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, food, bob_id, 1, Vector3.ZERO)
	module._rpc_request_hand_over.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, bobs, alice_id, 1, bob_id)
	await _settle()
	Engine.print_error_messages = true
	assert_eq(a_results, [
		[1, false, IntentValidator.REASON_BAD_TYPE],
		[2, false, IntentValidator.REASON_BAD_TYPE],
		[3, false, IntentValidator.REASON_BAD_TYPE],
		[4, false, IntentValidator.REASON_BAD_TYPE],
		[5, false, IntentValidator.REASON_BAD_TYPE],
		[6, false, IntentValidator.REASON_BAD_TYPE],
		[7, false, IntentValidator.REASON_BAD_TYPE],
		[8, false, IntentValidator.REASON_BAD_TYPE],
		[9, false, IntentValidator.REASON_BAD_ITEM_ID],
		[10, false, IntentValidator.REASON_BAD_ITEM_ID],
		[11, false, InventoryNetModule.REASON_BAD_TARGET_ID],
		[12, false, InventoryNetModule.REASON_BAD_TARGET_ID],
		[13, false, InventoryService.REASON_BAD_QUANTITY],
		[14, false, InventoryService.REASON_BAD_QUANTITY],
	], "answers go to usable request ids only, in order")
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE), 10)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_SEQUENCE), 1)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_ITEM_ID), 2)
	assert_eq(server.rejected_intent_count(InventoryNetModule.REASON_BAD_TARGET_ID), 2)
	assert_eq(server.rejected_intent_count(InventoryService.REASON_BAD_QUANTITY), 2)
	assert_eq(server.rejected_intent_count(), MALFORMED, "the calls the engine refused never reached the handler")

	# Well-formed lies: somebody else's item (to oneself or to a third
	# player), ids of other kinds of things, more units than the stack holds.
	a_results.clear()
	assert_eq(await _hand_over(a, bobs, alice_id, 1), [false, InventoryService.REASON_NOT_IN_INVENTORY], "taking bob's item")
	assert_eq(await _hand_over(a, bobs, c.client_state.local_player_id, 2), [false, InventoryService.REASON_NOT_IN_INVENTORY], "moving bob's item to carol")
	assert_eq(await _hand_over(a, bob_id, bob_id, 1), [false, InventoryService.REASON_NOT_IN_INVENTORY], "a player id as the item")
	assert_eq(await _hand_over(a, food, _world.get_player(bob_id).inventory_id, 1), [false, ServerWorld.REASON_TARGET_UNAVAILABLE], "an inventory id as the target")
	assert_eq(await _hand_over(a, food, food, 1), [false, ServerWorld.REASON_TARGET_UNAVAILABLE], "an item id as the target")
	assert_eq(await _hand_over(a, food, bob_id, HUGE_QUANTITY), [false, InventoryService.REASON_BAD_QUANTITY], "a huge quantity")
	assert_eq(await _hand_over(a, food, bob_id, 4), [false, InventoryService.REASON_BAD_QUANTITY], "one more than the stack holds")
	await _settle()
	assert_eq(_world.inventory.to_snapshot(), before, "no item changed")
	assert_eq(b_notices.size() + c_notices.size(), 0)
	assert_eq(b_inventory.size(), 0, "bob's inventory was not touched")

	# Forged server messages: a client cannot tell another client that it was
	# handed something, or answer a request. Real ENet path: the engine
	# refuses these (the sender is not the authority) and reports each as an
	# engine error, the expected outcome, so printing is off for this block.
	var forged_target: Dictionary = {"scope": "target", "giver_id": alice_id, "receiver_id": bob_id, "definition_id": FOOD, "quantity": 5, "world_time": 1.0}
	var b_results: Array[Array] = _results_of(b)
	var server_notices: Array[Dictionary] = _notices_of(server)
	var rejected_before: int = server.rejected_intent_count()
	Engine.print_error_messages = false
	for target: int in [NetworkService.SERVER_PEER_ID, b.multiplayer.get_unique_id()]:
		module._rpc_hand_over_result.rpc_id(target, FORGED_REQUEST_ID, true, "")
		module._rpc_hand_over_notice.rpc_id(target, forged_target)
	await _settle()
	Engine.print_error_messages = true
	# Script-level guard, independent of the engine (sender id 0 here), and a
	# client never acts on a request addressed to it.
	_module(b)._rpc_hand_over_result(FORGED_REQUEST_ID, true, "")
	_module(b)._rpc_hand_over_notice(forged_target)
	_module(b)._rpc_request_hand_over(FORGED_REQUEST_ID, food, bob_id, 1)
	await _settle()
	assert_eq(b_results.size() + b_notices.size() + server_notices.size(), 0, "nothing forged was delivered")
	assert_eq(_world.inventory.to_snapshot(), before)
	assert_eq(server.rejected_intent_count(), rejected_before)
	var everybody: Array[NetworkService] = [a, b, c]
	await _assert_mirrors_match(everybody, "after every manipulated request")


func test_hand_over_request_before_join_is_rejected_and_floods_are_limited() -> void:
	const BURST: int = 2
	const FLOOD: int = 6
	# One new token every 100 seconds: only the burst passes within the test.
	_inventory_net.drop_intent_rate_per_sec = 0.01
	_inventory_net.drop_intent_burst = BURST
	assert_true(_start_server(), "server started")
	var bulk: String = _spawn(BULK, STACK_MAX)
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var stranger_results: Array[Array] = _results_of(stranger)
	var connected: bool = await _wait(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	assert_eq(_module(stranger).request_hand_over(bulk, "player_000001", 1), InventoryNetModule.NO_REQUEST, "the client API sends nothing before the join")
	_module(stranger).send_raw_hand_over_request(1, bulk, "player_000001", 1)
	assert_true(await _wait(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 1), "the server refused the request of a peer that has not joined")
	await _settle()
	assert_eq(stranger_results.size(), 0, "an unjoined peer is told nothing")

	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = clients[1].client_state.local_player_id
	if not await _pick_up(a, [bulk]):
		return
	var a_results: Array[Array] = _results_of(a)
	var requests: Array = []
	for index: int in range(FLOOD):
		requests.append(_module(a).request_hand_over(bulk, bob_id, 1))
	assert_true(await _wait(func() -> bool: return a_results.size() == FLOOD), "every request was answered (%d)" % a_results.size())
	await _settle()
	var expected: Array = []
	for index: int in range(FLOOD):
		expected.append([requests[index], true, ""] if index < BURST else [requests[index], false, NetworkService.RATE_LIMITED])
	assert_eq(a_results, expected, "only the burst is accepted")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST, "rejection counter")
	assert_eq(_server_rows(alice_id), [["slot_0", BULK, STACK_MAX - BURST]], "server: only the accepted requests moved a unit")
	assert_eq(_server_rows(bob_id), [["slot_0", BULK, BURST]])
	await _assert_mirrors_match(clients, "after the flood")
	# A drop shares the allowance (both take an item out of the inventory and
	# are saved at once); a use has its own.
	var drops: Array[Array] = []
	_module(a).drop_result.connect(func(request_id: int, ok: bool, reason: String) -> void: drops.append([request_id, ok, reason]))
	var drop_id: int = _module(a).request_drop(bulk)
	assert_true(await _wait(func() -> bool: return drops.size() == 1), "the drop request was answered")
	assert_eq(drops, [[drop_id, false, NetworkService.RATE_LIMITED]])
	var consumes: Array[Array] = []
	_module(a).consume_result.connect(func(request_id: int, ok: bool, reason: String) -> void: consumes.append([request_id, ok, reason]))
	var consume_id: int = _module(a).request_consume(bulk)
	assert_true(await _wait(func() -> bool: return consumes.size() == 1), "the consume request was answered")
	assert_eq(consumes, [[consume_id, false, ItemConsumption.REASON_NOT_CONSUMABLE]], "the use allowance is another bucket")


# ------------------------------------------------------------ 4. save and restart

func test_handed_over_items_survive_a_save_and_server_restart() -> void:
	_save_root = "user://test_saves/hand_over_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	var food: String = _spawn(FOOD, 4)
	var plain: String = _spawn(PLAIN, 1, OTHER_ITEM_AT)
	var bobs_food: String = _spawn(FOOD, 4, THIRD_ITEM_AT)
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

	# A hand-over is saved at once, like a pickup and a drop.
	var generation: int = save.current_generation(WORLD)
	assert_eq(await _hand_over(a, food, bob_id, 3), [true, ""])
	assert_true(save.current_generation(WORLD) > generation, "the hand-over was saved before the answer went out")
	# A refused one is not.
	generation = save.current_generation(WORLD)
	assert_eq(await _hand_over(a, food, bob_id, 5), [false, InventoryService.REASON_BAD_QUANTITY])
	assert_eq(save.current_generation(WORLD), generation, "a refused hand-over writes no save")
	assert_eq(await _hand_over(a, plain, bob_id, 1), [true, ""])
	assert_eq(await _hand_over(a, food, bob_id, 1), [true, ""])
	var alice_rows: Array = _server_rows(alice_id)
	var bob_rows: Array = _server_rows(bob_id)
	assert_eq(alice_rows, [])
	assert_eq(bob_rows, [["slot_0", FOOD, STACK_MAX], ["slot_1", FOOD, 3], ["slot_2", PLAIN, 1]], "three fill bob's stack and overflow, the last one joins the overflow")
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
	assert_eq(_server_rows(alice_id), alice_rows, "alice's inventory was restored")
	assert_eq(_server_rows(bob_id), bob_rows, "bob's inventory was restored")
	assert_eq(JSON.stringify(_world.inventory.to_snapshot()), snapshot_text, "the same items, ids, slots and quantities")
	assert_null(_world.inventory.get_item(food), "the stack that merged away is not restored")
	assert_true(_world.registry.is_tombstoned(food))
	assert_eq(_world.inventory.get_item(plain).location_id, _world.get_player(bob_id).inventory_id)
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
	assert_eq(a2.client_state.inventory.size(), 0, "alice rejoins with what she kept: nothing")
	assert_eq(b2.client_state.inventory.size(), 3, "bob rejoins with what he was handed")
	# The game goes on: bob hands the single item back, ids never come back.
	assert_eq(await _hand_over(b2, plain, alice_id, 1), [true, ""])
	await _assert_mirrors_match(two_again, "session 2 after handing back")
	assert_eq(_server_rows(alice_id), [["slot_0", PLAIN, 1]])
	var fresh: String = _spawn(PLAIN)
	for used: String in [food, plain, bobs_food]:
		assert_true(EntityIdGenerator.sequence_of(fresh) > EntityIdGenerator.sequence_of(used), "new ids continue after every id ever used")


# ------------------------------------------------------------ rules (no network)

func test_rpc_table_request_validation_and_notice_validation() -> void:
	assert_eq(BuildInfo.PROTOCOL_VERSION, 9, "the hand-over RPCs are a protocol change (P2-T14)")
	const ITEM: String = "item_000001"
	const USER: String = "player_000001"
	const TARGET: String = "player_000002"
	const BYSTANDER: String = "player_000003"
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, TARGET, 1), "")
	assert_eq(InventoryNetModule.validate_hand_over_request(0, "x", "p", HUGE_QUANTITY), "", "how many the stack holds is the rule's check")
	assert_eq(InventoryNetModule.validate_hand_over_request("1", ITEM, TARGET, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_hand_over_request(1.0, ITEM, TARGET, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, 5, TARGET, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, &"item_000001", TARGET, 1), IntentValidator.REASON_BAD_TYPE, "StringName is not String")
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, null, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, 3, 1), IntentValidator.REASON_BAD_TYPE, "a target is an id, not a number")
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, TARGET, 1.0), IntentValidator.REASON_BAD_TYPE, "a quantity is a whole number")
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, TARGET, "1"), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, TARGET, null), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, TARGET, true), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_hand_over_request(-1, ITEM, TARGET, 1), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, "", TARGET, 1), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, "i".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1), TARGET, 1), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, "", 1), InventoryNetModule.REASON_BAD_TARGET_ID, "there is no \"myself\" to hand to")
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, "p".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1), 1), InventoryNetModule.REASON_BAD_TARGET_ID)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, "p".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH), 1), "")
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, TARGET, 0), InventoryService.REASON_BAD_QUANTITY)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, TARGET, -3), InventoryService.REASON_BAD_QUANTITY)
	# The order: types, request id, item id, target id, quantity.
	assert_eq(InventoryNetModule.validate_hand_over_request(-1, "", "", 0), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, "", "", 0), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(InventoryNetModule.validate_hand_over_request(1, ITEM, "", 0), InventoryNetModule.REASON_BAD_TARGET_ID)
	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	var module: InventoryNetModule = service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	assert_eq(module.request_hand_over(ITEM, TARGET, 1), InventoryNetModule.NO_REQUEST, "nothing is sent while offline")
	# Channel 0, reliable; requests from any peer, everything else only from the server.
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	var expected_modes: Dictionary[String, int] = {
		"_rpc_request_hand_over": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_hand_over_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_hand_over_notice": MultiplayerAPI.RPC_MODE_AUTHORITY,
	}
	for method: String in expected_modes:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), expected_modes[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	service.free()

	# Notices: exact keys per scope and the right addressee.
	var target_notice: Dictionary = {"scope": "target", "giver_id": USER, "receiver_id": TARGET, "definition_id": "dev_food_ration", "quantity": 2, "world_time": 5.0}
	var public_notice: Dictionary = {"scope": "public", "giver_id": USER, "receiver_id": TARGET, "world_time": 5.0}
	assert_true(InventoryNetModule.is_valid_hand_over_notice(target_notice, TARGET))
	assert_true(InventoryNetModule.is_valid_hand_over_notice(public_notice, BYSTANDER))
	assert_false(InventoryNetModule.is_valid_hand_over_notice(target_notice, BYSTANDER), "a target notice is for the receiver only")
	assert_false(InventoryNetModule.is_valid_hand_over_notice(target_notice, USER))
	assert_false(InventoryNetModule.is_valid_hand_over_notice(public_notice, TARGET), "the receiver gets the target notice")
	assert_false(InventoryNetModule.is_valid_hand_over_notice(public_notice, USER), "the giver gets the result")
	# A hand-over notice is no treatment notice and the other way round.
	assert_false(InventoryNetModule.is_valid_treatment_notice(target_notice, TARGET))
	assert_false(InventoryNetModule.is_valid_treatment_notice(public_notice, BYSTANDER))
	assert_false(InventoryNetModule.is_valid_hand_over_notice({"scope": "public", "user_id": USER, "target_id": TARGET, "world_time": 5.0}, BYSTANDER))
	var bad_notices: Array = [
		"notice",
		null,
		[],
		{},
		{"scope": "owner", "giver_id": USER, "receiver_id": TARGET, "world_time": 5.0},
		{"scope": 1, "giver_id": USER, "receiver_id": TARGET, "world_time": 5.0},
		{"scope": "public", "giver_id": USER, "receiver_id": TARGET},
		{"scope": "public", "giver_id": USER, "receiver_id": USER, "world_time": 5.0},
		{"scope": "public", "giver_id": USER, "receiver_id": TARGET, "world_time": -1.0},
		{"scope": "public", "giver_id": USER, "receiver_id": TARGET, "world_time": NAN},
		{"scope": "public", "giver_id": USER, "receiver_id": TARGET, "world_time": "5"},
		{"scope": "public", "giver_id": "", "receiver_id": TARGET, "world_time": 5.0},
		{"scope": "public", "giver_id": 1, "receiver_id": TARGET, "world_time": 5.0},
		{"scope": "public", "giver_id": USER, "receiver_id": "p".repeat(200), "world_time": 5.0},
		{"scope": "public", "giver_id": USER, "receiver_id": TARGET, "world_time": 5.0, "definition_id": "dev_cure"},
		{"scope": "public", "giver_id": USER, "receiver_id": TARGET, "world_time": 5.0, "quantity": 1},
		{"scope": "public", "giver_id": USER, "receiver_id": TARGET, "world_time": 5.0, "item_instance_id": ITEM},
	]
	for bad: Variant in bad_notices:
		assert_false(InventoryNetModule.is_valid_hand_over_notice(bad, BYSTANDER), "rejected: %s" % str(bad))
	for key: String in ["definition_id", "quantity", "giver_id", "receiver_id", "world_time"]:
		var missing: Dictionary = target_notice.duplicate()
		missing.erase(key)
		assert_false(InventoryNetModule.is_valid_hand_over_notice(missing, TARGET), "a target notice without " + key)
	var wrong: Array[Dictionary] = [
		{"definition_id": "Not A Definition"}, {"definition_id": 3}, {"definition_id": "d".repeat(200)},
		{"quantity": 0}, {"quantity": -1}, {"quantity": 2.0}, {"quantity": "2"}, {"quantity": null},
		{"giver_id": TARGET}, {"receiver_id": BYSTANDER},
		{"item_instance_id": ITEM}, {"slot_id": "slot_0"}, {"inventory": []}, {"remaining_quantity": 1},
	]
	for change: Dictionary in wrong:
		var changed: Dictionary = target_notice.duplicate()
		changed.merge(change, true)
		assert_false(InventoryNetModule.is_valid_hand_over_notice(changed, TARGET), "rejected: %s" % str(change))
