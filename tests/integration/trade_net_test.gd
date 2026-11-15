extends TestCase
## P2-T16 (docs/00 ADR-022, docs/09 §14.30): a trade between two players
## over real ENet (server + 3 clients). A client names the player to ask,
## the session, a stack of its own inventory and how many units, and the
## offer revision it confirms; the server decides everything else from its
## own state and exchanges all at once when both have confirmed. The two
## parties see each other's offers (kind and number); a third client is
## sent no request, no offer and no confirmation, only that the two traded
## once they did (docs/00 ADR-009). Rules: tests/unit/trade_service_test.gd,
## the exchange itself: tests/unit/item_exchange_test.gd.

const WORLD: String = "trade_net_test_world"
const NEVER: float = 1.0e9
const FOOD: String = "t16n_food"
const PLAIN: String = "t16n_plain"
const BULK: String = "t16n_bulk"
const STACK_MAX: int = 5
const CELL: String = DevWorldSeed.DEV_CELL_ID
## Players spawn at the origin; these positions are within pickup range.
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const OTHER_ITEM_AT: Vector3 = Vector3(-0.5, 0.0, 1.0)
const THIRD_ITEM_AT: Vector3 = Vector3(0.5, 0.0, -1.0)
const FAR_AWAY: Vector3 = Vector3(60.0, 0.0, 0.0)
const WAIT_MSEC: int = 6000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 120.0
const GENEROUS_BURST: int = 120
const LETHAL_DAMAGE: float = 100000.0
const FORGED_REQUEST_ID: int = 77
const MISSING_ITEM_ID: String = "item_999999"
const MISSING_PLAYER_ID: String = "player_999999"
const MISSING_SESSION_ID: int = 999999
## Needs that must not move on their own during a test.
const FROZEN_NEED_HOURS: float = 100000.0
## Words that must not appear in anything a bystander receives.
const PRIVATE_WORDS: PackedStringArray = ["definition", "quantity", "offer", "food", "plain", "bulk", "item", "inventory", "slot", "stack", "requester", "target", "revision", "confirm"]
## Every RPC of the trade module.
const TRADE_RPCS: Dictionary[String, int] = {
	"_rpc_request_trade": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_request_trade_accept": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_request_trade_cancel": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_request_trade_offer": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_request_trade_confirm": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_trade_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
	"_rpc_trade_state": MultiplayerAPI.RPC_MODE_AUTHORITY,
	"_rpc_trade_notice": MultiplayerAPI.RPC_MODE_AUTHORITY,
}

var _cluster: NetTestCluster = null
var _net_settings: NetworkSettings = null
var _trade_settings: TradeSettings = null
var _trade_net: TradeNetSettings = null
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
	_trade_settings = TradeSettings.new()
	_trade_net = TradeNetSettings.new()
	_trade_net.trade_intent_rate_per_sec = GENEROUS_RATE
	_trade_net.trade_intent_burst = GENEROUS_BURST
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
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	# No zombies.
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.inventory_net = InventoryNetSettings.new()
	_config.trade = _trade_settings
	_config.trade_net = _trade_net
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
	food.consume_hunger_reduction = 30.0
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


func _module(service: NetworkService) -> TradeNetModule:
	return service.get_module(TradeNetModule.MODULE_NAME) as TradeNetModule


## The client's trade mirror.
func _mirror(service: NetworkService) -> ClientTradeState:
	return _module(service).client_state


func _inventory_module(service: NetworkService) -> InventoryNetModule:
	return service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule


func _trade() -> TradeService:
	return _world.get_system(TradeService.SYSTEM_ID) as TradeService


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _spawn(definition_id: String, quantity: int = 1, position: Vector3 = ITEM_AT) -> String:
	return _world.inventory.spawn_world_item(definition_id, quantity, CELL, position)


## Rows [request_id, ok, reason] of every trade result of `service`.
func _results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).trade_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Every change of the trade mirror of `service` from now on: the session
## state it holds after the change ({} = no session and nothing closed).
func _states_of(service: NetworkService) -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	# The listener captures the module (a node), not the mirror: a mirror
	# captured by a listener of its own signal would never be freed.
	var module: TradeNetModule = _module(service)
	module.client_state.changed.connect(func() -> void: states.append(module.client_state.session() if module.client_state.has_session() else module.client_state.last_closed()))
	return states


## Every completed-trade notice `service` receives from now on.
func _notices_of(service: NetworkService) -> Array[Dictionary]:
	var notices: Array[Dictionary] = []
	_mirror(service).notice_received.connect(func(notice: Dictionary) -> void: notices.append(notice))
	return notices


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


## Sends one trade request through `send` (it returns the request id) and
## waits for its answer: [ok, reason].
func _answer(client: NetworkService, send: Callable) -> Array:
	var rows: Array[Array] = _results_of(client)
	var request_id: int = send.call()
	if request_id == TradeNetModule.NO_REQUEST:
		fail("the trade request was not sent")
		return [false, "not_sent"]
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	if not answered:
		fail("the trade request was not answered")
		return [false, "no_answer"]
	if int(rows[0][0]) != request_id:
		fail("the answer carries another request id: %s" % str(rows[0]))
	return [rows[0][1], rows[0][2]]


func _ask(client: NetworkService, target_id: String) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_trade(target_id))


func _accept(client: NetworkService, session_id: int) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_accept(session_id))


func _cancel(client: NetworkService, session_id: int) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_cancel(session_id))


func _offer(client: NetworkService, session_id: int, item_id: String, quantity: int) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_offer(session_id, item_id, quantity))


func _confirm(client: NetworkService, session_id: int, revision: int, wanted: bool = true) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_confirm(session_id, revision, wanted))


## Opens a session between two clients and returns its id (0 on failure).
func _open(a: NetworkService, b: NetworkService) -> int:
	var asked: Array = await _ask(a, b.client_state.local_player_id)
	if asked != [true, ""]:
		fail("test setup: the request failed: %s" % str(asked))
		return 0
	var session_id: int = _mirror(a).session_id()
	var known: bool = await _wait(func() -> bool: return _mirror(b).session_id() == session_id)
	if not known:
		fail("test setup: the asked player never saw the request")
		return 0
	var accepted: Array = await _accept(b, session_id)
	if accepted != [true, ""]:
		fail("test setup: the accept failed: %s" % str(accepted))
		return 0
	var opened: bool = await _wait(func() -> bool: return _mirror(a).phase() == TradeSession.PHASE_OPEN and _mirror(b).phase() == TradeSession.PHASE_OPEN)
	if not opened:
		fail("test setup: the session did not open on both mirrors")
		return 0
	return session_id


## Waits until the trade of both clients ended and asserts how: cancelled,
## for `cause`, by `by_player_id`, on both mirrors.
func _assert_cancelled(a: NetworkService, b: NetworkService, session_id: int, cause: String, by_player_id: String, label: String) -> void:
	for client: NetworkService in [a, b]:
		var mirror: ClientTradeState = _mirror(client)
		var ended: bool = await _wait(func() -> bool: return not mirror.has_session() and int(mirror.last_closed().get("session_id", 0)) == session_id)
		assert_true(ended, "%s: %s was told that the trade ended" % [label, client.client_state.local_player_id])
		var closed: Dictionary = mirror.last_closed()
		assert_eq(closed.get("phase", ""), TradeSession.PHASE_CLOSED, label)
		assert_eq(closed.get("outcome", ""), TradeSession.OUTCOME_CANCELLED, label)
		assert_eq(closed.get("cause", ""), cause, label + ": both are told why")
		assert_eq(closed.get("by_player_id", "?"), by_player_id, label + ": and who caused it")
	assert_null(_trade().session_of(a.client_state.local_player_id), label + ": the server has no session any more")
	assert_null(_trade().session_of(b.client_state.local_player_id), label)


## [definition, quantity] of what a player carries on the server, in slot order.
func _server_rows(player_id: String) -> Array:
	var rows: Array = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		rows.append([item.definition_id, item.quantity])
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


## Units per definition over every item that exists on the server.
func _totals() -> Dictionary:
	var totals: Dictionary = {}
	for entry: Dictionary in _world.inventory.to_snapshot()[InventoryService.SNAPSHOT_ITEMS]:
		var definition_id: String = str(entry["definition_id"])
		totals[definition_id] = int(totals.get(definition_id, 0)) + int(entry["quantity"])
	return totals


# ------------------------------------------------------------ 1. the flow

func test_two_clients_trade_and_a_third_only_learns_that_they_traded() -> void:
	assert_true(_start_server(), "server started")
	var food: String = _spawn(FOOD, 3)
	var plain: String = _spawn(PLAIN, 1, OTHER_ITEM_AT)
	var bulk: String = _spawn(BULK, 5, THIRD_ITEM_AT)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [food, plain]):
		return
	if not await _pick_up(b, [bulk]):
		return
	await _assert_mirrors_match(clients, "start")
	var totals: Dictionary = _totals()
	var c_states: Array[Dictionary] = _states_of(c)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var a_notices: Array[Dictionary] = _notices_of(a)
	var b_notices: Array[Dictionary] = _notices_of(b)
	var c_owner_messages: int = _inventory_module(c).owner_message_count
	var b_owner_messages: int = _inventory_module(b).owner_message_count

	# --- alice asks bob.
	assert_eq(await _ask(a, bob_id), [true, ""])
	var session_id: int = _mirror(a).session_id()
	assert_true(session_id >= 1)
	assert_eq(_mirror(a).phase(), TradeSession.PHASE_REQUESTED, "the requester knows the state before the answer")
	assert_true(_mirror(a).is_requester())
	assert_eq(_mirror(a).partner_id(), bob_id)
	assert_true(await _wait(func() -> bool: return _mirror(b).session_id() == session_id), "bob is told that alice asks")
	assert_false(_mirror(b).is_requester())
	assert_eq(_mirror(b).partner_id(), alice_id)
	assert_eq(_mirror(b).phase(), TradeSession.PHASE_REQUESTED)

	# --- bob accepts.
	assert_eq(await _accept(b, session_id), [true, ""])
	assert_true(await _wait(func() -> bool: return _mirror(a).phase() == TradeSession.PHASE_OPEN), "alice is told that bob accepted")
	assert_eq(_mirror(b).phase(), TradeSession.PHASE_OPEN)

	# --- both put their offers together. Each side sees the other's offer as
	#     kind and number, its own with the item ids.
	assert_eq(await _offer(a, session_id, food, 2), [true, ""])
	assert_eq(await _offer(a, session_id, plain, 1), [true, ""])
	assert_eq(_mirror(a).my_offer(), [
		{"item_instance_id": food, "definition_id": FOOD, "quantity": 2},
		{"item_instance_id": plain, "definition_id": PLAIN, "quantity": 1},
	])
	assert_true(await _wait(func() -> bool: return _mirror(b).revision() == 2), "bob sees alice's offer change")
	assert_eq(_mirror(b).their_offer(), [{"definition_id": FOOD, "quantity": 2}, {"definition_id": PLAIN, "quantity": 1}], "kind and number, no item ids")
	assert_eq(_mirror(b).my_offer(), [])
	assert_eq(await _offer(b, session_id, bulk, 3), [true, ""])
	assert_true(await _wait(func() -> bool: return _mirror(a).revision() == 3))
	assert_eq(_mirror(a).their_offer(), [{"definition_id": BULK, "quantity": 3}])
	assert_eq(_server_rows(alice_id), [[FOOD, 3], [PLAIN, 1]], "an offer moves nothing")
	assert_eq(_server_rows(bob_id), [[BULK, 5]])

	# --- alice confirms; bob then raises his offer: her confirmation is gone
	#     and a confirmation of the old revision does not count.
	assert_eq(await _confirm(a, session_id, 3), [true, ""])
	assert_true(_mirror(a).my_confirmed())
	assert_true(await _wait(func() -> bool: return _mirror(b).their_confirmed()), "bob sees that alice confirmed")
	assert_eq(await _offer(b, session_id, bulk, 4), [true, ""])
	assert_false(_mirror(b).their_confirmed(), "a changed offer clears both confirmations")
	assert_true(await _wait(func() -> bool: return _mirror(a).revision() == 4 and not _mirror(a).my_confirmed()), "alice sees the new offer and that she has to confirm again")
	assert_eq(_mirror(a).their_offer(), [{"definition_id": BULK, "quantity": 4}])
	assert_eq(await _confirm(a, session_id, 3), [false, TradeService.REASON_STALE_OFFER], "what she confirmed is not what is offered now")
	assert_eq(_server_rows(alice_id), [[FOOD, 3], [PLAIN, 1]])

	# --- both confirm the current offers: the exchange happens at once.
	assert_eq(await _confirm(b, session_id, 4), [true, ""])
	assert_eq(_server_rows(bob_id), [[BULK, 5]], "one confirmation moves nothing")
	assert_eq(await _confirm(a, session_id, 4), [true, ""])
	assert_eq(_server_rows(alice_id), [[FOOD, 1], [BULK, 4]], "server: alice gave 2 food and her single item for 4 of bob's stack")
	assert_eq(_server_rows(bob_id), [[BULK, 1], [FOOD, 2], [PLAIN, 1]])
	assert_eq(_totals(), totals, "no unit was lost or copied")
	assert_false(_mirror(a).has_session(), "the confirmation's answer arrives after the closed session")
	assert_eq(_mirror(a).last_closed().get("outcome", ""), TradeSession.OUTCOME_COMPLETED)
	assert_true(await _wait(func() -> bool: return not _mirror(b).has_session()), "bob is told that the trade is done")
	assert_eq(_mirror(b).last_closed().get("outcome", ""), TradeSession.OUTCOME_COMPLETED)
	assert_eq(_mirror(b).last_closed().get("their_offer", []), [{"definition_id": FOOD, "quantity": 2}, {"definition_id": PLAIN, "quantity": 1}], "the closed state still says what was exchanged")
	await _assert_mirrors_match(clients, "after the trade")
	assert_null(_trade().session_of(alice_id))

	# --- carol, who stood next to them, was sent one notice and nothing else.
	assert_true(await _wait(func() -> bool: return c_notices.size() == 1), "carol is told that they traded")
	await _settle()
	assert_eq(c_notices.size(), 1, "once")
	var notice: Dictionary = c_notices[0]
	var keys: Array = notice.keys()
	keys.sort()
	assert_eq(keys, ["player_ids", "world_time"], "a notice carries nothing else")
	var traders: Array = [alice_id, bob_id]
	traders.sort()
	assert_eq(notice.get("player_ids", []), traders, "who traded, in id order: not who asked")
	var text: String = JSON.stringify(notice).to_lower().replace(alice_id, "").replace(bob_id, "").replace("player_ids", "")
	for word: String in PRIVATE_WORDS:
		assert_not_contains(text, word, "a bystander was told about the trade's content")
	assert_eq(c_states.size(), 0, "no request, offer or confirmation of the others ever reached carol's mirror")
	assert_false(_mirror(c).has_session())
	assert_eq(_mirror(c).last_closed(), {})
	assert_eq(_inventory_module(c).owner_message_count, c_owner_messages, "and no inventory message")
	assert_eq(c.client_state.inventory.size(), 0)
	assert_eq(a_notices.size() + b_notices.size(), 0, "the two parties get their session state, not the notice")
	assert_true(_inventory_module(b).owner_message_count > b_owner_messages, "bob was sent his own inventory change")
	assert_eq(_module(a).rejected_payload_count + _module(b).rejected_payload_count + _module(c).rejected_payload_count, 0)
	assert_eq(_mirror(a).rejected_payload_count + _mirror(b).rejected_payload_count + _mirror(c).rejected_payload_count, 0, "every server message passed the client's checks")
	assert_eq(_cluster.server.rejected_intent_count(), 1, "the one refused request was the stale confirmation")

	# --- a gift: bob offers nothing and consents by confirming.
	session_id = await _open(b, a)
	var bobs_food: String = ""
	for entry: Dictionary in b.client_state.inventory:
		if str(entry["definition_id"]) == FOOD:
			bobs_food = str(entry["item_instance_id"])
	assert_false(bobs_food.is_empty())
	assert_eq(await _offer(b, session_id, bobs_food, 2), [true, ""])
	assert_eq(await _confirm(b, session_id, 1), [true, ""])
	assert_eq(_server_rows(alice_id), [[FOOD, 1], [BULK, 4]], "nothing arrives before the receiver confirms")
	assert_true(await _wait(func() -> bool: return _mirror(a).revision() == 1 and _mirror(a).their_confirmed()))
	assert_eq(await _confirm(a, session_id, 1), [true, ""])
	assert_eq(_server_rows(alice_id), [[FOOD, 3], [BULK, 4]], "the two units joined the food alice kept")
	assert_eq(_server_rows(bob_id), [[BULK, 1], [PLAIN, 1]])
	await _assert_mirrors_match(clients, "after the gift")
	assert_true(await _wait(func() -> bool: return c_notices.size() == 2), "carol is told about the second trade")
	assert_eq(c_states.size(), 0)


# ------------------------------------------------------------ 2. requests that go nowhere

func test_declined_withdrawn_and_timed_out_requests_move_nothing_and_stay_between_the_two() -> void:
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
	var before: Dictionary = _world.inventory.to_snapshot()
	var c_states: Array[Dictionary] = _states_of(c)
	var c_notices: Array[Dictionary] = _notices_of(c)

	# Declined by the player that was asked.
	assert_eq(await _ask(a, bob_id), [true, ""])
	var session_id: int = _mirror(a).session_id()
	assert_true(await _wait(func() -> bool: return _mirror(b).session_id() == session_id))
	assert_eq(await _cancel(b, session_id), [true, ""])
	await _assert_cancelled(a, b, session_id, TradeService.CAUSE_DECLINED, bob_id, "declined")
	assert_eq(await _accept(b, session_id), [false, TradeService.REASON_NO_SUCH_REQUEST], "a declined request cannot be accepted any more")
	# Withdrawn by the player that asked.
	assert_eq(await _ask(a, bob_id), [true, ""])
	session_id = _mirror(a).session_id()
	assert_true(await _wait(func() -> bool: return _mirror(b).session_id() == session_id))
	assert_eq(await _cancel(a, session_id), [true, ""])
	await _assert_cancelled(a, b, session_id, TradeService.CAUSE_WITHDRAWN, alice_id, "withdrawn")
	# Unanswered: it times out on the server's clock (moved forward here, so
	# the test does not wait).
	assert_eq(await _ask(a, bob_id), [true, ""])
	session_id = _mirror(a).session_id()
	assert_true(await _wait(func() -> bool: return _mirror(b).session_id() == session_id))
	_world.clock.action_time_sec += _trade_settings.request_timeout_sec
	await _assert_cancelled(a, b, session_id, TradeService.CAUSE_REQUEST_TIMEOUT, "", "request timeout")
	assert_eq(await _accept(b, session_id), [false, TradeService.REASON_NO_SUCH_REQUEST], "too late")
	# While one request is pending, both are busy for everybody else.
	assert_eq(await _ask(a, bob_id), [true, ""])
	session_id = _mirror(a).session_id()
	assert_eq(await _ask(c, alice_id), [false, TradeService.REASON_TARGET_BUSY])
	assert_eq(await _ask(c, bob_id), [false, TradeService.REASON_TARGET_BUSY])
	assert_eq(await _ask(a, c.client_state.local_player_id), [false, TradeService.REASON_ALREADY_TRADING])
	assert_eq(await _cancel(a, session_id), [true, ""])
	await _assert_cancelled(a, b, session_id, TradeService.CAUSE_WITHDRAWN, alice_id, "withdrawn again")
	# Nobody trades with itself or with somebody that is not there.
	assert_eq(await _ask(a, alice_id), [false, TradeService.REASON_TARGET_IS_SELF])
	assert_eq(await _ask(a, MISSING_PLAYER_ID), [false, TradeService.REASON_TARGET_UNAVAILABLE])
	assert_eq(await _ask(a, food), [false, TradeService.REASON_TARGET_UNAVAILABLE], "an item id is no player")
	_world.get_player(bob_id).position = FAR_AWAY
	assert_eq(await _ask(a, bob_id), [false, TradeService.REASON_TARGET_TOO_FAR])
	await _settle()
	assert_eq(_world.inventory.to_snapshot(), before, "no request moved an item")
	assert_eq(c_states.size(), 0, "carol's mirror never changed: her own refused requests opened nothing and the others' are not hers")
	assert_eq(c_notices.size(), 0, "a trade that did not happen is told to nobody else")


# ------------------------------------------------------------ 3. cancelled sessions

func test_a_session_is_cancelled_by_distance_sleep_idleness_death_and_disconnect() -> void:
	assert_true(_start_server(), "server started")
	var food: String = _spawn(FOOD, 3)
	var bulk: String = _spawn(BULK, 5, OTHER_ITEM_AT)
	var carols: String = _spawn(PLAIN, 1, THIRD_ITEM_AT)
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
	if not await _pick_up(b, [bulk]):
		return
	if not await _pick_up(c, [carols]):
		return
	var before: Dictionary = _world.inventory.to_snapshot()
	var c_states: Array[Dictionary] = _states_of(c)
	var c_notices: Array[Dictionary] = _notices_of(c)

	# Each round: an open session with offers on both sides and one
	# confirmation, then the cause. [session id]
	var prepare: Callable = func() -> int:
		var opened: int = await _open(a, b)
		if await _offer(a, opened, food, 2) != [true, ""] or await _offer(b, opened, bulk, 3) != [true, ""]:
			fail("test setup: offers failed")
		if await _confirm(a, opened, 2) != [true, ""]:
			fail("test setup: confirmation failed")
		return opened

	# They move apart (the server's positions, not anything a client says).
	var session_id: int = await prepare.call()
	_world.get_player(bob_id).position = FAR_AWAY
	await _assert_cancelled(a, b, session_id, TradeService.CAUSE_TOO_FAR, "", "moved apart")
	_world.get_player(bob_id).position = _world.get_player(alice_id).position
	# One lies down to sleep.
	session_id = await prepare.call()
	assert_true(_survival().start_rest(bob_id).ok)
	await _assert_cancelled(a, b, session_id, TradeService.CAUSE_PLAYER_RESTING, bob_id, "fell asleep")
	assert_true(_survival().stop_rest(bob_id).ok)
	# Nothing happens for too long (the server's clock is moved forward).
	session_id = await prepare.call()
	_world.clock.action_time_sec += _trade_settings.session_idle_timeout_sec
	await _assert_cancelled(a, b, session_id, TradeService.CAUSE_IDLE_TIMEOUT, "", "idle")
	# A cancelled session takes no more intents.
	assert_eq(await _confirm(b, session_id, 2), [false, TradeService.REASON_NOT_IN_SESSION], "acting after the session ended")
	assert_eq(await _offer(a, session_id, food, 3), [false, TradeService.REASON_NOT_IN_SESSION])
	assert_eq(await _cancel(a, session_id), [false, TradeService.REASON_NOT_IN_SESSION])
	await _settle()
	assert_eq(_world.inventory.to_snapshot(), before, "no cancelled trade moved an item")
	assert_eq(c_states.size(), 0, "carol was told nothing about any of it")
	assert_eq(c_notices.size(), 0)

	# One leaves the server: the other is told at once.
	var c_session: int = await _open(a, c)
	assert_eq(await _offer(c, c_session, carols, 1), [true, ""])
	assert_eq(await _confirm(c, c_session, 1), [true, ""])
	_cluster.remove_client(c)
	assert_true(await _wait(func() -> bool: return not _mirror(a).has_session()), "alice is told that carol is gone")
	var closed: Dictionary = _mirror(a).last_closed()
	assert_eq(closed.get("session_id", 0), c_session)
	assert_eq(closed.get("outcome", ""), TradeSession.OUTCOME_CANCELLED)
	assert_eq(closed.get("cause", ""), TradeService.CAUSE_DISCONNECTED)
	assert_eq(closed.get("by_player_id", ""), carol_id)
	assert_null(_trade().session_of(alice_id))
	assert_eq(_world.inventory.get_item(carols).location_id, _world.get_player(carol_id).inventory_id, "carol's offered item stayed hers")
	assert_eq(_server_rows(alice_id), [[FOOD, 3]])

	# One dies: its belongings go to the ground, not to the other side.
	session_id = await prepare.call()
	assert_true(_survival().apply_damage(bob_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	await _assert_cancelled(a, b, session_id, TradeService.CAUSE_PLAYER_DEAD, bob_id, "died")
	assert_eq(_server_rows(alice_id), [[FOOD, 3]], "alice kept what she had offered and got nothing")
	assert_eq(_world.inventory.get_item(bulk).location_type, ItemInstance.LOCATION_WORLD, "the dead character's stack lies on the ground")
	assert_eq(_world.inventory.get_item(bulk).quantity, 5, "all of it")
	assert_eq(await _ask(a, bob_id), [false, TradeService.REASON_TARGET_DEAD], "the dead are not asked")
	assert_eq(await _ask(b, alice_id), [false, SurvivalService.REASON_PLAYER_DEAD], "and do not ask")


# ------------------------------------------------------------ 4. forged requests

func test_forged_and_malformed_trade_requests_are_refused_and_change_nothing() -> void:
	assert_true(_start_server(), "server started")
	var food: String = _spawn(FOOD, 3)
	var bulk: String = _spawn(BULK, 5, OTHER_ITEM_AT)
	var carols: String = _spawn(PLAIN, 1, THIRD_ITEM_AT)
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
	if not await _pick_up(b, [bulk]):
		return
	if not await _pick_up(c, [carols]):
		return
	var session_id: int = await _open(a, b)
	assert_eq(await _offer(b, session_id, bulk, 5), [true, ""])
	assert_true(await _wait(func() -> bool: return _mirror(a).revision() == 1))
	var server: NetworkService = _cluster.server
	var session: TradeSession = _trade().session_of(alice_id)
	var session_before: String = JSON.stringify(session.to_dict())
	var before: Dictionary = _world.inventory.to_snapshot()
	var a_results: Array[Array] = _results_of(a)
	var b_states: Array[Dictionary] = _states_of(b)
	var c_states: Array[Dictionary] = _states_of(c)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var module: TradeNetModule = _module(a)
	var long_id: String = "x".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1)

	# --- malformed arguments, through the real RPC path.
	module.send_raw_trade_request("x", bob_id)
	module.send_raw_trade_request(1, 7)
	module.send_raw_trade_request(2, null)
	module.send_raw_trade_request(3, "")
	module.send_raw_trade_request(4, long_id)
	module.send_raw_trade_request(-1, bob_id)
	module.send_raw_accept_request(5, "1")
	module.send_raw_accept_request(6, 0)
	module.send_raw_accept_request(7, -3)
	module.send_raw_cancel_request(8, 1.0)
	module.send_raw_cancel_request(9, null)
	module.send_raw_offer_request(10, session_id, 5, 1)
	module.send_raw_offer_request(11, session_id, food, "1")
	module.send_raw_offer_request(12, session_id, food, 1.0)
	module.send_raw_offer_request(13, session_id, "", 1)
	module.send_raw_offer_request(14, session_id, long_id, 1)
	module.send_raw_offer_request(15, session_id, food, -1)
	module.send_raw_offer_request(16, 0, food, 1)
	module.send_raw_confirm_request(17, session_id, "1", true)
	module.send_raw_confirm_request(18, session_id, 1, 1)
	module.send_raw_confirm_request(19, session_id, 1, "true")
	module.send_raw_confirm_request(20, session_id, -1, true)
	module.send_raw_confirm_request(21, -1, 1, true)
	module.send_raw_confirm_request(22.0, session_id, 1, true)
	const MALFORMED: int = 24
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == MALFORMED), "every malformed request was rejected (%d)" % server.rejected_intent_count())
	# A request cannot carry more than its arguments (no "for player X", no
	# position): the engine refuses a call with more (reported as an engine
	# error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_trade_offer.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, session_id, bulk, 0, bob_id)
	module._rpc_request_trade_confirm.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, session_id, 1, true, bob_id)
	module._rpc_request_trade.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, bob_id, Vector3.ZERO)
	await _settle()
	Engine.print_error_messages = true
	assert_eq(a_results, [
		[1, false, IntentValidator.REASON_BAD_TYPE],
		[2, false, IntentValidator.REASON_BAD_TYPE],
		[3, false, TradeNetModule.REASON_BAD_TARGET_ID],
		[4, false, TradeNetModule.REASON_BAD_TARGET_ID],
		[5, false, IntentValidator.REASON_BAD_TYPE],
		[6, false, TradeNetModule.REASON_BAD_SESSION_ID],
		[7, false, TradeNetModule.REASON_BAD_SESSION_ID],
		[8, false, IntentValidator.REASON_BAD_TYPE],
		[9, false, IntentValidator.REASON_BAD_TYPE],
		[10, false, IntentValidator.REASON_BAD_TYPE],
		[11, false, IntentValidator.REASON_BAD_TYPE],
		[12, false, IntentValidator.REASON_BAD_TYPE],
		[13, false, IntentValidator.REASON_BAD_ITEM_ID],
		[14, false, IntentValidator.REASON_BAD_ITEM_ID],
		[15, false, InventoryService.REASON_BAD_QUANTITY],
		[16, false, TradeNetModule.REASON_BAD_SESSION_ID],
		[17, false, IntentValidator.REASON_BAD_TYPE],
		[18, false, IntentValidator.REASON_BAD_TYPE],
		[19, false, IntentValidator.REASON_BAD_TYPE],
		[20, false, TradeNetModule.REASON_BAD_REVISION],
		[21, false, TradeNetModule.REASON_BAD_SESSION_ID],
	], "answers go to usable request ids only, in order")
	assert_eq(server.rejected_intent_count(), MALFORMED, "the calls the engine refused never reached a handler")

	# --- well-formed lies.
	a_results.clear()
	# An item the requester does not own, as its own offer.
	assert_eq(await _offer(a, session_id, bulk, 1), [false, InventoryService.REASON_NOT_IN_INVENTORY], "the other side's stack")
	assert_eq(await _offer(a, session_id, carols, 1), [false, InventoryService.REASON_NOT_IN_INVENTORY], "a third player's item")
	assert_eq(await _offer(a, session_id, MISSING_ITEM_ID, 1), [false, InventoryService.REASON_NOT_IN_INVENTORY], "an id that does not exist is told like one that is not carried")
	assert_eq(await _offer(a, session_id, bob_id, 1), [false, InventoryService.REASON_NOT_IN_INVENTORY], "a player id as the item")
	# More units than the stack holds.
	assert_eq(await _offer(a, session_id, food, 4), [false, InventoryService.REASON_BAD_QUANTITY])
	assert_eq(await _offer(a, session_id, food, 9223372036854775807), [false, InventoryService.REASON_BAD_QUANTITY])
	# Changing the other side's offer: "take it out" names bob's stack.
	assert_eq(await _offer(a, session_id, bulk, 0), [false, TradeService.REASON_NOT_IN_OFFER], "alice cannot take bob's stack out of bob's offer")
	# Confirming for the other side: there is no such argument; a
	# confirmation of a revision that is not the session's does nothing.
	assert_eq(await _confirm(a, session_id, 0), [false, TradeService.REASON_STALE_OFFER])
	assert_eq(await _confirm(a, session_id, 99), [false, TradeService.REASON_STALE_OFFER])
	assert_eq(await _confirm(a, session_id, 1, false), [false, TradeService.REASON_NOT_CONFIRMED])
	# Another session than the own one.
	assert_eq(await _confirm(a, MISSING_SESSION_ID, 1), [false, TradeService.REASON_NOT_IN_SESSION])
	assert_eq(await _offer(a, session_id + 1, food, 1), [false, TradeService.REASON_NOT_IN_SESSION])
	assert_eq(await _accept(a, session_id), [false, TradeService.REASON_NO_SUCH_REQUEST], "an open session is no request")
	# Trading with oneself, or a second trade at the same time.
	assert_eq(await _ask(a, alice_id), [false, TradeService.REASON_ALREADY_TRADING])
	assert_eq(await _ask(a, c.client_state.local_player_id), [false, TradeService.REASON_ALREADY_TRADING])
	# A client that is no party of the session acts in it.
	assert_eq(await _offer(c, session_id, carols, 1), [false, TradeService.REASON_NOT_IN_SESSION], "carol offers into alice's and bob's session")
	assert_eq(await _confirm(c, session_id, 1), [false, TradeService.REASON_NOT_IN_SESSION], "carol confirms it")
	assert_eq(await _cancel(c, session_id), [false, TradeService.REASON_NOT_IN_SESSION], "carol cancels it")
	assert_eq(await _accept(c, session_id), [false, TradeService.REASON_NO_SUCH_REQUEST])
	assert_eq(await _ask(c, alice_id), [false, TradeService.REASON_TARGET_BUSY])
	await _settle()
	assert_eq(JSON.stringify(session.to_dict()), session_before, "no forged request changed the session: bob's offer and both confirmations are what they were")
	assert_eq(_world.inventory.to_snapshot(), before, "or an item")
	assert_eq(b_states.size(), 0, "bob was sent no new state")
	assert_eq(_mirror(b).my_offer(), [{"item_instance_id": bulk, "definition_id": BULK, "quantity": 5}])
	assert_eq(c_states.size() + c_notices.size(), 0, "carol learnt nothing about the session by acting in it")
	assert_eq(server.rejected_intent_count(InventoryService.REASON_UNKNOWN_ITEM), 2, "the counter keeps the server's own reason")

	# --- forged server messages: a client cannot tell another client that a
	#     trade happened, put a session into its mirror or answer a request.
	#     Real ENet path: the engine refuses these (the sender is not the
	#     authority) and reports each as an engine error, the expected
	#     outcome, so printing is off for this block.
	var forged_state: Dictionary = TradeNetModule.party_state({"change": TradeService.CHANGE_CLOSED, "world_time": 1.0, "session": {"session_id": session_id, "requester_id": alice_id, "target_id": bob_id, "phase": TradeSession.PHASE_CLOSED, "revision": 1, "offers": {alice_id: [], bob_id: []}, "confirmed": {alice_id: false, bob_id: false}, "outcome": TradeSession.OUTCOME_COMPLETED, "cause": "", "by_player_id": ""}}, bob_id)
	assert_true(ClientTradeState.is_valid_state(forged_state, bob_id), "the forged state is well-formed: only its sender is wrong")
	var forged_notice: Dictionary = {"player_ids": [alice_id, bob_id], "world_time": 1.0}
	var b_results: Array[Array] = _results_of(b)
	var rejected_before: int = server.rejected_intent_count()
	Engine.print_error_messages = false
	for target: int in [NetworkService.SERVER_PEER_ID, b.multiplayer.get_unique_id(), c.multiplayer.get_unique_id()]:
		module._rpc_trade_result.rpc_id(target, FORGED_REQUEST_ID, true, "")
		module._rpc_trade_state.rpc_id(target, forged_state)
		module._rpc_trade_notice.rpc_id(target, forged_notice)
	await _settle()
	Engine.print_error_messages = true
	# Script-level guard, independent of the engine (sender id 0 here), and a
	# client never acts on a request addressed to it.
	_module(b)._rpc_trade_result(FORGED_REQUEST_ID, true, "")
	_module(b)._rpc_trade_state(forged_state)
	_module(c)._rpc_trade_notice(forged_notice)
	_module(b)._rpc_request_trade_confirm(FORGED_REQUEST_ID, session_id, 1, true)
	await _settle()
	assert_eq(b_results.size() + b_states.size() + c_states.size() + c_notices.size(), 0, "nothing forged was delivered")
	assert_eq(_mirror(b).phase(), TradeSession.PHASE_OPEN, "bob's mirror still shows the open session")
	assert_eq(JSON.stringify(session.to_dict()), session_before)
	assert_eq(server.rejected_intent_count(), rejected_before)
	# The session is still intact and completes normally.
	assert_eq(await _confirm(a, session_id, 1), [true, ""])
	assert_eq(await _confirm(b, session_id, 1), [true, ""])
	assert_eq(_server_rows(alice_id), [[FOOD, 3], [BULK, 5]])
	assert_eq(_server_rows(bob_id), [])
	# After the end the old session id is worth nothing.
	assert_eq(await _confirm(a, session_id, 1), [false, TradeService.REASON_NOT_IN_SESSION], "acting after the session ended")
	assert_eq(await _offer(b, session_id, bulk, 1), [false, TradeService.REASON_NOT_IN_SESSION])
	await _assert_mirrors_match(clients, "after everything")


func test_trade_requests_before_join_are_refused_and_floods_are_limited() -> void:
	const BURST: int = 3
	const FLOOD: int = 7
	# One new token every 100 seconds: only the burst passes within the test.
	_trade_net.trade_intent_rate_per_sec = 0.01
	_trade_net.trade_intent_burst = BURST
	assert_true(_start_server(), "server started")
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var stranger_results: Array[Array] = _results_of(stranger)
	var connected: bool = await _wait(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	assert_eq(_module(stranger).request_trade("player_000001"), TradeNetModule.NO_REQUEST, "the client API sends nothing before the join")
	assert_eq(_module(stranger).request_accept(1), TradeNetModule.NO_REQUEST)
	assert_eq(_module(stranger).request_cancel(1), TradeNetModule.NO_REQUEST)
	assert_eq(_module(stranger).request_offer(1, "item_000001", 1), TradeNetModule.NO_REQUEST)
	assert_eq(_module(stranger).request_confirm(1, 0, true), TradeNetModule.NO_REQUEST)
	_module(stranger).send_raw_trade_request(1, "player_000001")
	_module(stranger).send_raw_accept_request(2, 1)
	_module(stranger).send_raw_cancel_request(3, 1)
	_module(stranger).send_raw_offer_request(4, 1, "item_000001", 1)
	_module(stranger).send_raw_confirm_request(5, 1, 0, true)
	assert_true(await _wait(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 5), "the server refused every request of a peer that has not joined")
	await _settle()
	assert_eq(stranger_results.size(), 0, "an unjoined peer is told nothing")
	assert_eq(_trade().session_count(), 0)

	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var a_results: Array[Array] = _results_of(a)
	var requests: Array = []
	for index: int in range(FLOOD):
		requests.append(_module(a).request_cancel(MISSING_SESSION_ID))
	assert_true(await _wait(func() -> bool: return a_results.size() == FLOOD), "every request was answered (%d)" % a_results.size())
	var expected: Array = []
	for index: int in range(FLOOD):
		expected.append([requests[index], false, TradeService.REASON_NOT_IN_SESSION if index < BURST else NetworkService.RATE_LIMITED])
	assert_eq(a_results, expected, "only the burst reaches the rule; all five intents share the allowance")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST)
	# Another intent of the same peer is limited too; another peer is not.
	assert_eq(await _ask(a, clients[1].client_state.local_player_id), [false, NetworkService.RATE_LIMITED])
	assert_eq(await _ask(clients[1], a.client_state.local_player_id), [true, ""])


# ------------------------------------------------------------ 5. save and restart

func test_a_completed_trade_is_saved_at_once_and_survives_a_server_restart() -> void:
	_save_root = "user://test_saves/trade_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	var food: String = _spawn(FOOD, 4)
	var bulk: String = _spawn(BULK, 5, OTHER_ITEM_AT)
	var bobs_food: String = _spawn(FOOD, 4, THIRD_ITEM_AT)
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [food]):
		return
	if not await _pick_up(b, [bulk, bobs_food]):
		return
	var save: SaveService = SaveService.new(_save_root)
	var two: Array[NetworkService] = [a, b]

	# Requests, offers, confirmations and a cancelled trade write no save.
	var generation: int = save.current_generation(WORLD)
	var session_id: int = await _open(a, b)
	assert_eq(await _offer(a, session_id, food, 3), [true, ""])
	assert_eq(await _offer(b, session_id, bulk, 5), [true, ""])
	assert_eq(await _confirm(a, session_id, 2), [true, ""])
	assert_eq(await _cancel(b, session_id), [true, ""])
	await _settle()
	assert_eq(save.current_generation(WORLD), generation, "nothing of an unfinished trade is saved")
	# A completed trade is saved before the answer goes out, and once.
	session_id = await _open(a, b)
	assert_eq(await _offer(a, session_id, food, 3), [true, ""])
	assert_eq(await _offer(b, session_id, bulk, 5), [true, ""])
	assert_eq(await _confirm(a, session_id, 2), [true, ""])
	assert_eq(save.current_generation(WORLD), generation, "one confirmation is not a trade")
	assert_eq(await _confirm(b, session_id, 2), [true, ""])
	assert_eq(save.current_generation(WORLD), generation + 1, "the trade was saved before the answer went out")
	await _settle()
	assert_eq(save.current_generation(WORLD), generation + 1, "and only once")
	var alice_rows: Array = _server_rows(alice_id)
	var bob_rows: Array = _server_rows(bob_id)
	assert_eq(alice_rows, [[FOOD, 1], [BULK, 5]])
	assert_eq(bob_rows, [[FOOD, 2], [FOOD, STACK_MAX]], "one of alice's three filled bob's stack, two took the slot his bulk left")
	var snapshot_text: String = JSON.stringify(_world.inventory.to_snapshot())
	await _assert_mirrors_match(two, "session 1")
	# A session that is open when the server goes down.
	assert_true(await _open(a, b) > 0)

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
	assert_eq(_world.inventory.get_item(bulk).location_id, _world.get_player(alice_id).inventory_id, "the moved instance kept its id")
	assert_eq(_trade().session_count(), 0, "no session survives a restart")
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
	assert_false(_mirror(a2).has_session() or _mirror(b2).has_session(), "nobody rejoins into a trade")
	# The game goes on: they trade back, and ids never come back.
	session_id = await _open(b2, a2)
	assert_eq(await _offer(a2, session_id, bulk, 5), [true, ""])
	assert_eq(await _confirm(a2, session_id, 1), [true, ""])
	assert_eq(await _confirm(b2, session_id, 1), [true, ""])
	assert_eq(_server_rows(alice_id), [[FOOD, 1]])
	assert_eq(_server_rows(bob_id), [[FOOD, 2], [FOOD, STACK_MAX], [BULK, 5]])
	await _assert_mirrors_match(two_again, "session 2 after trading back")
	var fresh: String = _spawn(PLAIN)
	for used: String in [food, bulk, bobs_food]:
		assert_true(EntityIdGenerator.sequence_of(fresh) > EntityIdGenerator.sequence_of(used), "new ids continue after every id ever used")


# ------------------------------------------------------------ rules (no network)

func test_rpc_table_request_validation_and_state_validation() -> void:
	assert_eq(BuildInfo.PROTOCOL_VERSION, 13, "the trade RPCs were a protocol change (11, P2-T16); 12 since the structure RPCs (P3-4a), 13 since the replication scope by cell (P3-2)")
	const ITEM: String = "item_000001"
	const ALICE: String = "player_000001"
	const BOB: String = "player_000002"
	const CAROL: String = "player_000003"
	var long_id: String = "p".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1)
	# Asking.
	assert_eq(TradeNetModule.validate_trade_request(1, BOB), "")
	assert_eq(TradeNetModule.validate_trade_request(0, "p".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH)), "")
	assert_eq(TradeNetModule.validate_trade_request("1", BOB), IntentValidator.REASON_BAD_TYPE)
	assert_eq(TradeNetModule.validate_trade_request(1.0, BOB), IntentValidator.REASON_BAD_TYPE)
	assert_eq(TradeNetModule.validate_trade_request(1, 3), IntentValidator.REASON_BAD_TYPE, "a target is an id, not a number")
	assert_eq(TradeNetModule.validate_trade_request(1, &"player_000002"), IntentValidator.REASON_BAD_TYPE, "StringName is not String")
	assert_eq(TradeNetModule.validate_trade_request(-1, BOB), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(TradeNetModule.validate_trade_request(1, ""), TradeNetModule.REASON_BAD_TARGET_ID)
	assert_eq(TradeNetModule.validate_trade_request(1, long_id), TradeNetModule.REASON_BAD_TARGET_ID)
	# Accepting / cancelling.
	assert_eq(TradeNetModule.validate_session_request(1, 1), "")
	assert_eq(TradeNetModule.validate_session_request(1, "1"), IntentValidator.REASON_BAD_TYPE)
	assert_eq(TradeNetModule.validate_session_request(1, 1.0), IntentValidator.REASON_BAD_TYPE)
	assert_eq(TradeNetModule.validate_session_request(1, true), IntentValidator.REASON_BAD_TYPE)
	assert_eq(TradeNetModule.validate_session_request(-1, 1), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(TradeNetModule.validate_session_request(1, 0), TradeNetModule.REASON_BAD_SESSION_ID)
	assert_eq(TradeNetModule.validate_session_request(1, -5), TradeNetModule.REASON_BAD_SESSION_ID)
	# Offering.
	assert_eq(TradeNetModule.validate_offer_request(1, 1, ITEM, 1), "")
	assert_eq(TradeNetModule.validate_offer_request(1, 1, ITEM, 0), "", "0 takes the stack out of the offer")
	assert_eq(TradeNetModule.validate_offer_request(1, 1, ITEM, 9223372036854775807), "", "how many the stack holds is the rule's check")
	assert_eq(TradeNetModule.validate_offer_request(1, 1, 5, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(TradeNetModule.validate_offer_request(1, 1, ITEM, 1.0), IntentValidator.REASON_BAD_TYPE, "a quantity is a whole number")
	assert_eq(TradeNetModule.validate_offer_request(1, 1, ITEM, null), IntentValidator.REASON_BAD_TYPE)
	assert_eq(TradeNetModule.validate_offer_request(1, "1", ITEM, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(TradeNetModule.validate_offer_request(1, 1, "", 1), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(TradeNetModule.validate_offer_request(1, 1, long_id, 1), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(TradeNetModule.validate_offer_request(1, 1, ITEM, -1), InventoryService.REASON_BAD_QUANTITY)
	# The order: types, request id, session id, item id, quantity.
	assert_eq(TradeNetModule.validate_offer_request(-1, 0, "", -1), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(TradeNetModule.validate_offer_request(1, 0, "", -1), TradeNetModule.REASON_BAD_SESSION_ID)
	assert_eq(TradeNetModule.validate_offer_request(1, 1, "", -1), IntentValidator.REASON_BAD_ITEM_ID)
	# Confirming.
	assert_eq(TradeNetModule.validate_confirm_request(1, 1, 0, true), "")
	assert_eq(TradeNetModule.validate_confirm_request(1, 1, 3, false), "")
	assert_eq(TradeNetModule.validate_confirm_request(1, 1, 0, 1), IntentValidator.REASON_BAD_TYPE, "a confirmation is true or false")
	assert_eq(TradeNetModule.validate_confirm_request(1, 1, 0.0, true), IntentValidator.REASON_BAD_TYPE)
	assert_eq(TradeNetModule.validate_confirm_request(1, 1, "0", true), IntentValidator.REASON_BAD_TYPE)
	assert_eq(TradeNetModule.validate_confirm_request(1, 0, 0, true), TradeNetModule.REASON_BAD_SESSION_ID)
	assert_eq(TradeNetModule.validate_confirm_request(1, 1, -1, true), TradeNetModule.REASON_BAD_REVISION)
	# What the requester is told never reveals whether a foreign id exists.
	assert_eq(TradeNetModule.public_reason(InventoryService.REASON_UNKNOWN_ITEM), InventoryService.REASON_NOT_IN_INVENTORY)
	assert_eq(TradeNetModule.public_reason(TradeService.REASON_TARGET_BUSY), TradeService.REASON_TARGET_BUSY)

	# Settings and composition.
	var shipped: TradeNetSettings = TradeNetSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_eq(TradeNetSettings.new().trade_intent_rate_per_sec, shipped.trade_intent_rate_per_sec, "the script default agrees with the shipped resource")
	assert_eq(TradeNetSettings.new().trade_intent_burst, shipped.trade_intent_burst)
	var broken: TradeNetSettings = TradeNetSettings.new()
	broken.trade_intent_rate_per_sec = 0.0
	assert_eq(broken.validate().size(), 1)
	var too_many: TradeSettings = TradeSettings.new()
	too_many.max_offer_entries = ClientTradeState.MAX_OFFER_ENTRIES + 1
	assert_eq(shipped.validate_against(too_many).size(), 1, "an offer may not hold more stacks than a client accepts")
	assert_eq(shipped.validate_against(TradeSettings.load_or_default()).size(), 0)
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	config.trade_net = broken
	assert_true(config.validate().size() > 0, "composition validation covers the trade network settings")
	config.trade_net = null
	assert_true(config.validate().size() > 0, "a missing settings object is reported")
	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	var module: TradeNetModule = service.get_module(TradeNetModule.MODULE_NAME) as TradeNetModule
	assert_not_null(module, "the composition installs the trade module")
	assert_eq(str(module.name), TradeNetModule.MODULE_NAME, "same node name on every peer")
	assert_eq(module.request_trade(BOB), TradeNetModule.NO_REQUEST, "nothing is sent while offline")
	# Channel 0, reliable; requests from any peer, everything else only from the server.
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	assert_eq(rpc_config.size(), TRADE_RPCS.size(), "no other RPC exists")
	for method: String in TRADE_RPCS:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), TRADE_RPCS[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	service.free()

	# What each party is sent: its own offer with item ids, the other side's
	# as kind and number.
	var event: Dictionary = {
		"event_type": TradeService.EVENT_SESSION_CHANGED,
		"change": TradeService.CHANGE_OFFER,
		"world_time": 5.0,
		"session": {
			"session_id": 4, "requester_id": ALICE, "target_id": BOB, "phase": TradeSession.PHASE_OPEN, "revision": 2,
			"offers": {ALICE: [{"item_instance_id": ITEM, "definition_id": "dev_food_ration", "quantity": 2}], BOB: [{"item_instance_id": "item_000009", "definition_id": "dev_bandage", "quantity": 1}]},
			"confirmed": {ALICE: true, BOB: false},
			"outcome": "", "cause": "", "by_player_id": "",
		},
	}
	var for_alice: Dictionary = TradeNetModule.party_state(event, ALICE)
	var for_bob: Dictionary = TradeNetModule.party_state(event, BOB)
	assert_eq(for_alice["my_offer"], [{"item_instance_id": ITEM, "definition_id": "dev_food_ration", "quantity": 2}])
	assert_eq(for_alice["their_offer"], [{"definition_id": "dev_bandage", "quantity": 1}], "no item id of the other side")
	assert_eq(for_alice["my_confirmed"], true)
	assert_eq(for_alice["their_confirmed"], false)
	assert_eq(for_bob["my_offer"], [{"item_instance_id": "item_000009", "definition_id": "dev_bandage", "quantity": 1}])
	assert_eq(for_bob["their_offer"], [{"definition_id": "dev_food_ration", "quantity": 2}])
	assert_eq(for_bob["their_confirmed"], true)
	assert_not_contains(JSON.stringify(for_bob), ITEM, "bob is not sent the id of alice's stack")
	assert_true(ClientTradeState.is_valid_state(for_alice, ALICE))
	assert_true(ClientTradeState.is_valid_state(for_bob, BOB))
	assert_false(ClientTradeState.is_valid_state(for_alice, CAROL), "a state is for a party of its session only")
	assert_false(ClientTradeState.is_valid_state(for_alice, ""), "nobody is no party")
	# The mirror keeps nothing it cannot validate.
	var mirror: ClientTradeState = ClientTradeState.new()
	mirror.apply_join(CAROL)
	assert_false(mirror.apply_state(for_alice), "a state of somebody else's session")
	assert_false(mirror.has_session())
	assert_eq(mirror.rejected_payload_count, 1)
	mirror.apply_join(ALICE)
	assert_true(mirror.apply_state(for_alice))
	assert_eq(mirror.session_id(), 4)
	assert_eq(mirror.partner_id(), BOB)
	assert_true(mirror.is_requester())
	var bad_states: Array = ["state", null, [], {}]
	var changes: Array[Dictionary] = [
		{"session_id": 0}, {"session_id": "4"}, {"session_id": 4.0},
		{"phase": "trading"}, {"phase": 1},
		{"requester_id": ""}, {"requester_id": BOB}, {"target_id": 7}, {"target_id": long_id},
		{"revision": -1}, {"revision": "2"},
		{"my_offer": "none"}, {"my_offer": [{"definition_id": "dev_food_ration", "quantity": 2}]}, {"my_offer": [{"item_instance_id": ITEM, "definition_id": "Not A Definition", "quantity": 2}]},
		{"my_offer": [{"item_instance_id": ITEM, "definition_id": "dev_food_ration", "quantity": 0}]}, {"my_offer": [{"item_instance_id": ITEM, "definition_id": "dev_food_ration", "quantity": 2.0}]},
		{"my_offer": [{"item_instance_id": ITEM, "definition_id": "dev_food_ration", "quantity": 1}, {"item_instance_id": ITEM, "definition_id": "dev_food_ration", "quantity": 1}]},
		{"their_offer": [{"item_instance_id": "item_000009", "definition_id": "dev_bandage", "quantity": 1}]}, {"their_offer": [{"definition_id": "dev_bandage"}]}, {"their_offer": [5]},
		{"my_confirmed": 1}, {"their_confirmed": "no"},
		{"change": "something"}, {"change": 3},
		{"outcome": TradeSession.OUTCOME_COMPLETED}, {"outcome": "won"}, {"outcome": null},
		{"cause": 5}, {"cause": "c".repeat(200)},
		{"by_player_id": CAROL}, {"by_player_id": 3},
		{"world_time": -1.0}, {"world_time": NAN}, {"world_time": "5"},
		{"health": 10.0}, {"inventory": []},
	]
	for change: Dictionary in changes:
		var changed: Dictionary = for_alice.duplicate(true)
		changed.merge(change, true)
		bad_states.append(changed)
	for key: String in ClientTradeState.STATE_KEYS:
		var missing: Dictionary = for_alice.duplicate(true)
		missing.erase(key)
		bad_states.append(missing)
	var closed_without_outcome: Dictionary = for_alice.duplicate(true)
	closed_without_outcome["phase"] = TradeSession.PHASE_CLOSED
	bad_states.append(closed_without_outcome)
	var too_long: Dictionary = for_alice.duplicate(true)
	var entries: Array = []
	for index: int in range(ClientTradeState.MAX_OFFER_ENTRIES + 1):
		entries.append({"definition_id": "dev_bandage", "quantity": 1})
	too_long["their_offer"] = entries
	bad_states.append(too_long)
	for bad: Variant in bad_states:
		assert_false(ClientTradeState.is_valid_state(bad, ALICE), "rejected: %s" % str(bad))
		assert_false(mirror.apply_state(bad))
	assert_eq(mirror.session(), for_alice, "no malformed state changed the mirror")
	# Closing: only the session the mirror knows.
	var closed: Dictionary = for_alice.duplicate(true)
	closed.merge({"phase": TradeSession.PHASE_CLOSED, "change": TradeService.CHANGE_CLOSED, "outcome": TradeSession.OUTCOME_CANCELLED, "cause": TradeService.CAUSE_TOO_FAR}, true)
	var other_closed: Dictionary = closed.duplicate(true)
	other_closed["session_id"] = 9
	assert_true(ClientTradeState.is_valid_state(other_closed, ALICE))
	assert_false(mirror.apply_state(other_closed), "the end of another session does not end this one")
	assert_true(mirror.has_session())
	assert_true(mirror.apply_state(closed))
	assert_false(mirror.has_session())
	assert_eq(mirror.last_closed().get("cause", ""), TradeService.CAUSE_TOO_FAR)
	assert_eq(mirror.partner_id(), "")
	mirror.apply_join(ALICE)
	assert_eq(mirror.last_closed(), {}, "a (re)join starts clean")

	# Notices: exact keys, two other players in id order.
	var closed_event: Dictionary = event.duplicate(true)
	closed_event["session"]["requester_id"] = BOB
	closed_event["session"]["target_id"] = ALICE
	var notice: Dictionary = TradeNetModule.public_notice(closed_event)
	assert_eq(notice, {"player_ids": [ALICE, BOB], "world_time": 5.0}, "in id order whoever asked, and nothing about the offers")
	assert_true(ClientTradeState.is_valid_notice(notice, CAROL))
	assert_false(ClientTradeState.is_valid_notice(notice, ALICE), "a party gets its session state, not the notice")
	assert_false(ClientTradeState.is_valid_notice(notice, BOB))
	var bad_notices: Array = [
		"notice", null, [], {},
		{"player_ids": [BOB, ALICE], "world_time": 5.0},
		{"player_ids": [ALICE, ALICE], "world_time": 5.0},
		{"player_ids": [ALICE], "world_time": 5.0},
		{"player_ids": [ALICE, BOB, CAROL], "world_time": 5.0},
		{"player_ids": [ALICE, 7], "world_time": 5.0},
		{"player_ids": ["", BOB], "world_time": 5.0},
		{"player_ids": ALICE, "world_time": 5.0},
		{"player_ids": [ALICE, BOB]},
		{"player_ids": [ALICE, BOB], "world_time": -1.0},
		{"player_ids": [ALICE, BOB], "world_time": NAN},
		{"player_ids": [ALICE, BOB], "world_time": 5.0, "definition_id": "dev_food_ration"},
		{"player_ids": [ALICE, BOB], "world_time": 5.0, "quantity": 2},
		{"player_ids": [ALICE, BOB], "world_time": 5.0, "requester_id": ALICE},
	]
	for bad: Variant in bad_notices:
		assert_false(ClientTradeState.is_valid_notice(bad, CAROL), "rejected: %s" % str(bad))
	mirror.apply_join(CAROL)
	assert_true(mirror.apply_notice(notice))
	assert_false(mirror.apply_notice({"player_ids": [BOB, ALICE], "world_time": 5.0}))
	assert_eq(mirror.recent_notices(), [notice])
