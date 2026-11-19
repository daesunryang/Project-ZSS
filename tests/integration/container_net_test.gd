extends TestCase
## P3-3 (docs/00 ADR-021 "창고에 넣어서 옮기는 방식", ADR-026, docs/09 §15.3):
## containers over real ENet (one server and three clients in one process) on
## the 500 m x 500 m test map with its shipped cell and interest settings.
##   - Alice puts items into a container, Bob takes them out: the user's way
##     of moving items between players without meeting.
##   - That a container exists reaches only the clients that are told about
##     its cell; what is inside reaches only the clients that have it open.
##   - A client names a container, a stack and a quantity; the server decides
##     everything else from its own state. Forged requests change nothing and
##     reveal nothing.
## Players are moved through the server (its positions are the only ones
## that count). Rules: tests/unit/container_service_test.gd; cells and saves:
## tests/unit/container_cell_test.gd, container_persistence_test.gd.

const WORLD: String = "container_net_world"
const NEVER: float = 1.0e9
const WAIT_MSEC: int = 8000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 30
const GENEROUS_RATE: float = 120.0
const GENEROUS_BURST: int = 120
const LETHAL_DAMAGE: float = 100000.0
const LIGHT_DAMAGE: float = 1.0
const ZOMBIE: String = "zombie_000001"
const BULK: String = "p33n_bulk"
const STACK_MAX: int = 5
const PLAIN: String = "p33n_plain"
## A storage box nobody filled (no loot table) and the shipped cabinet.
const BOX: String = "p33n_box"
const BOX_SLOTS: int = 4
const CABINET: String = "dev_cabinet"
## Players spawn at the origin; the store stands next to it.
const STORE_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const SECOND_AT: Vector3 = Vector3(-1.0, 0.0, 1.0)
## In the cells around the origin, but out of reach from it.
const ACROSS_AT: Vector3 = Vector3(12.0, 0.0, 0.0)
## Far from the origin: eight cells away, in nobody's cells.
const FAR_AWAY: Vector3 = Vector3(200.0, 0.0, 200.0)
const NEAR_FAR_AWAY: Vector3 = Vector3(199.0, 0.0, 200.0)
const MISSING_ITEM_ID: String = "item_999999"
const MISSING_CONTAINER_ID: String = "container_999999"
const FORGED_REQUEST_ID: int = 77
## Every RPC of the container module.
const CONTAINER_RPCS: Dictionary[String, int] = {
	"_rpc_request_container_open": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_request_container_close": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_request_container_take": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_request_container_put": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_container_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
	"_rpc_container_rows": MultiplayerAPI.RPC_MODE_AUTHORITY,
	"_rpc_containers_removed": MultiplayerAPI.RPC_MODE_AUTHORITY,
	"_rpc_container_session": MultiplayerAPI.RPC_MODE_AUTHORITY,
	"_rpc_container_items": MultiplayerAPI.RPC_MODE_AUTHORITY,
}

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _settings: ContainerSettings = null
var _net: ContainerNetSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	network_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	network_settings.pickup_intent_burst = GENEROUS_BURST
	_settings = ContainerSettings.new()
	_settings.search_duration_sec = 0.0
	_net = ContainerNetSettings.new()
	_net.container_intent_rate_per_sec = GENEROUS_RATE
	_net.container_intent_burst = GENEROUS_BURST
	# from_defaults() hands out shared cached resources: replace, never edit.
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.catalog = _new_catalog()
	_config.survival = SurvivalSettings.new()
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.wound_recovery_per_world_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.inventory_net = InventoryNetSettings.new()
	# The shipped map, cells and interest area; cells are looked at every tick.
	_config.world_cells = WorldCellSettings.new()
	_config.world_cells.refresh_period_sec = 0.0
	_config.world_cells.preload_lookahead_sec = 0.0
	_config.interest = InterestSettings.new()
	_config.containers = _settings
	_config.container_net = _net
	_config.container_definitions = ContainerCatalog.load_directory()
	var box: ContainerDefinition = ContainerDefinition.new()
	box.definition_id = BOX
	box.display_name = "Test Box"
	box.slot_count = BOX_SLOTS
	_config.container_definitions.add(box)
	_cluster = NetTestCluster.new(tree, network_settings, _config)
	_world = null


func after_each() -> void:
	Engine.print_error_messages = true
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
	var plain: ItemDefinition = ItemDefinition.new()
	plain.definition_id = PLAIN
	plain.max_stack = 1
	catalog.add(plain)
	return catalog


func _start() -> bool:
	var errors: PackedStringArray = _config.validate()
	if not errors.is_empty():
		fail("test setup: invalid config: " + "; ".join(errors))
		return false
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


func _containers() -> ContainerService:
	return _world.get_system(ContainerService.SYSTEM_ID) as ContainerService


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _module(service: NetworkService) -> ContainerNetModule:
	return service.get_module(ContainerNetModule.MODULE_NAME) as ContainerNetModule


## The client's container mirror.
func _mirror(service: NetworkService) -> ClientContainerState:
	return _module(service).client_state


## Puts a client's player somewhere on the server and waits until the client
## itself has seen that position (so the server looked at it since).
func _place(client: NetworkService, position: Vector3) -> void:
	var player_id: String = _player_id(client)
	_world.get_player(player_id).position = position
	await _wait(func() -> bool: return client.client_state.position_of(player_id).distance_to(position) < 0.01)
	await _settle()


## A container created by a server rule; its cell is brought into memory
## first when no player is near.
func _create(definition_id: String, position: Vector3) -> String:
	(_world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).load_cell_now(_world, _world.cell_id_at(position))
	var created: ActionResult = _containers().create_container(_world, definition_id, position)
	if not created.ok:
		fail("test setup: container refused: " + created.reason)
		return ""
	return str(created.event.get("container_id", ""))


## A player that exists before its client joins and carries `stacks`
## ([definition, quantity] rows): its inventory arrives with the join. Returns
## the item ids, in the order of `stacks`.
func _prepare(player_key: String, stacks: Array) -> Array[String]:
	var player: PlayerState = _world.join(player_key)
	var ids: Array[String] = []
	for stack: Array in stacks:
		var item_id: String = _world.inventory.spawn_world_item(str(stack[0]), int(stack[1]), _world.cell_id_at(player.position), player.position)
		if not _world.try_pickup(player.player_id, item_id).ok:
			fail("test setup: %s could not pick up %s" % [player_key, str(stack[0])])
		ids.append(item_id)
	_world.leave(player.player_id)
	return ids


## Sends one container request through `send` (it returns the request id or
## nothing) and waits for its answer: [ok, reason].
func _answer(client: NetworkService, send: Callable) -> Array:
	var rows: Array[Array] = []
	var module: ContainerNetModule = _module(client)
	var listener: Callable = func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason])
	module.container_result.connect(listener)
	send.call()
	await _wait(func() -> bool: return not rows.is_empty())
	module.container_result.disconnect(listener)
	if rows.is_empty():
		fail("no answer to a container request")
		return [false, "no_answer"]
	return [rows[0][1], rows[0][2]]


func _open(client: NetworkService, container_id: String) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_open(container_id))


func _close(client: NetworkService, container_id: String) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_close(container_id))


func _take(client: NetworkService, container_id: String, item_id: String, quantity: int = InventoryService.WHOLE_STACK) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_take(container_id, item_id, quantity))


func _put(client: NetworkService, container_id: String, item_id: String, quantity: int = InventoryService.WHOLE_STACK) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_put(container_id, item_id, quantity))


## [definition, quantity] of what a container holds on the server, by slot.
func _stored(container_id: String) -> Array:
	var rows: Array = []
	for entry: Dictionary in _containers().contents_of(container_id):
		rows.append([entry["definition_id"], entry["quantity"]])
	return rows


## [item id, definition, quantity, slot] of what a container holds on the
## server / of what a client's mirror says the open container holds.
func _server_contents(container_id: String) -> Array:
	var rows: Array = []
	for entry: Dictionary in _containers().contents_of(container_id):
		rows.append([entry["item_instance_id"], entry["definition_id"], entry["quantity"], entry["slot"]])
	return rows


func _mirror_contents(client: NetworkService) -> Array:
	var rows: Array = []
	for entry: Dictionary in _mirror(client).contents():
		rows.append([entry[ClientContainerState.KEY_ITEM_ID], entry[ClientContainerState.KEY_DEFINITION_ID], entry[ClientContainerState.KEY_QUANTITY], entry[ClientContainerState.KEY_SLOT]])
	return rows


## [definition, quantity] of what a player carries on the server, by slot.
func _carried(player_id: String) -> Array:
	var rows: Array = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		rows.append([item.definition_id, item.quantity])
	return rows


## {item id: quantity} of a client's own inventory mirror / of the server's
## inventory of that client's player.
func _inventory_mirror(client: NetworkService) -> Dictionary:
	var result: Dictionary = {}
	for entry: Dictionary in client.client_state.inventory:
		result[str(entry["item_instance_id"])] = int(entry["quantity"])
	return result


func _inventory_server(client: NetworkService) -> Dictionary:
	var result: Dictionary = {}
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(_player_id(client)).inventory_id):
		result[item.item_instance_id] = item.quantity
	return result


func _sorted_ids(client: NetworkService) -> PackedStringArray:
	var ids: PackedStringArray = _mirror(client).container_ids()
	ids.sort()
	return ids


## [every message the server's container module sent, every owner-only
## inventory message these clients received] since the start.
func _message_counts(clients: Array[NetworkService]) -> Array[int]:
	var module: ContainerNetModule = _module(_cluster.server)
	var container_total: int = module.sent_row_message_count + module.sent_removed_message_count + module.sent_session_message_count + module.sent_items_message_count + module.sent_result_message_count
	var owner_total: int = 0
	for client: NetworkService in clients:
		owner_total += (client.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule).owner_message_count
	return [container_total, owner_total]


## What _message_counts(clients) grew by since `before`.
func _since(clients: Array[NetworkService], before: Array[int]) -> Array[int]:
	var now: Array[int] = _message_counts(clients)
	return [now[0] - before[0], now[1] - before[1]]


## Counts every change signal of a client's container mirror from now on.
func _changes_of(client: NetworkService) -> Array[int]:
	var count: Array[int] = [0]
	_mirror(client).changed.connect(func() -> void: count[0] += 1)
	return count


func _assert_clean(clients: Array[NetworkService], label: String) -> void:
	for client: NetworkService in clients:
		assert_eq(_mirror(client).rejected_payload_count, 0, label + ": every container payload was valid")
		assert_eq(_module(client).rejected_payload_count, 0, label)
		var inventory_net: InventoryNetModule = client.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
		assert_eq(inventory_net.rejected_payload_count, 0, label + ": every inventory payload was valid")


# ------------------------------------------------------------ 1. the user's flow

func test_alice_puts_items_into_a_container_and_bob_takes_them_out() -> void:
	assert_true(_start(), "server started")
	var alice_items: Array[String] = _prepare("alice", [[BULK, 5], [PLAIN, 1], ["dev_food_ration", 3]])
	var bob_items: Array[String] = _prepare("bob", [[BULK, 2]])
	var box_id: String = _create(BOX, STORE_AT)
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	var c: NetworkService = await _join("carol")
	if a == null or b == null or c == null:
		return
	await _place(c, FAR_AWAY)
	var c_changes: Array[int] = _changes_of(c)
	assert_eq(_sorted_ids(a), PackedStringArray([box_id]), "alice is told that the container exists")
	assert_eq(_sorted_ids(b), PackedStringArray([box_id]))
	assert_eq(_mirror(c).container_count(), 0, "carol is far away: the container left her mirror")
	var before: int = _module(_cluster.server).sent_items_message_count

	# Alice opens it and puts things in: a whole stack, a single item, a part.
	assert_eq(await _open(a, box_id), [true, ""])
	assert_eq(_mirror(a).phase(), ClientContainerState.PHASE_OPEN, "the state arrives before the answer")
	assert_eq(_mirror(a).open_container_id(), box_id)
	assert_eq(_mirror_contents(a), [])
	assert_eq(await _put(a, box_id, alice_items[0]), [true, ""])
	assert_eq(await _put(a, box_id, alice_items[1], 1), [true, ""])
	assert_eq(await _put(a, box_id, alice_items[2], 2), [true, ""])
	assert_eq(_stored(box_id), [[BULK, 5], [PLAIN, 1], ["dev_food_ration", 2]])
	assert_eq(_carried(_player_id(a)), [["dev_food_ration", 1]])
	assert_eq(_mirror_contents(a), _server_contents(box_id), "alice sees what is inside, as the server has it")
	assert_eq(_inventory_mirror(a), _inventory_server(a), "her own inventory followed through the inventory messages")
	assert_eq(_mirror_contents(b), [], "bob has not opened it: he is told nothing about what is inside")
	assert_eq(_mirror(b).phase(), ClientContainerState.PHASE_NONE)
	assert_eq(_module(_cluster.server).sent_items_message_count - before, 3, "one content message per put, to alice only")
	assert_eq(await _close(a, box_id), [true, ""])
	assert_eq(_mirror(a).phase(), ClientContainerState.PHASE_NONE)
	assert_eq(_mirror_contents(a), [], "a closed container shows nothing")
	# Alice walks away; the items stay.
	await _place(a, ACROSS_AT)

	# Bob opens it and takes everything out.
	assert_eq(await _open(b, box_id), [true, ""])
	assert_eq(_mirror_contents(b), _server_contents(box_id), "bob gets the whole content when he opens it")
	assert_eq(_mirror_contents(b).size(), 3)
	assert_eq(await _take(b, box_id, alice_items[0], 3), [true, ""], "a part of a stack")
	assert_eq(_carried(_player_id(b)), [[BULK, 5]], "the units joined the stack bob carries")
	assert_eq(_stored(box_id), [[BULK, 2], [PLAIN, 1], ["dev_food_ration", 2]])
	assert_eq(_mirror_contents(b), _server_contents(box_id), "the change reached his mirror")
	for entry: Array in _server_contents(box_id):
		assert_eq(await _take(b, box_id, str(entry[0])), [true, ""])
	assert_eq(_stored(box_id), [], "the container is empty")
	assert_eq(_mirror_contents(b), [])
	assert_eq(_carried(_player_id(b)), [[BULK, 5], [BULK, 2], [PLAIN, 1], ["dev_food_ration", 2]])
	assert_eq(_inventory_mirror(b), _inventory_server(b), "bob's inventory mirror is what the server has")
	assert_eq(_world.inventory.get_item(alice_items[1]).location_id, _world.get_player(_player_id(b)).inventory_id, "the single item moved with its id")
	assert_true(_inventory_mirror(b).has(bob_items[0]), "the stack he came with is still his")
	assert_eq(_inventory_mirror(a), _inventory_server(a))
	assert_eq(_carried(_player_id(a)), [["dev_food_ration", 1]], "alice keeps what she did not put in")
	# Carol, far away, was told nothing of all that.
	await _settle()
	assert_eq(c_changes[0], 0, "no container message reached carol")
	assert_eq(_mirror(c).container_count(), 0)
	var clients: Array[NetworkService] = [a, b, c]
	_assert_clean(clients, "the flow")
	assert_eq(_cluster.server.rejected_intent_count(), 0, "nothing was refused")


# ------------------------------------------------------------ 2. who is told what

func test_contents_go_only_to_the_clients_that_have_the_container_open() -> void:
	assert_true(_start(), "server started")
	var alice_items: Array[String] = _prepare("alice", [[BULK, 5], [PLAIN, 1]])
	var box_id: String = _create(BOX, STORE_AT)
	var cabinet_id: String = _create(CABINET, SECOND_AT)
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var server_module: ContainerNetModule = _module(_cluster.server)
	assert_eq(await _open(a, box_id), [true, ""])
	var sent: int = server_module.sent_items_message_count
	assert_eq(await _put(a, box_id, alice_items[0], 2), [true, ""])
	assert_eq(server_module.sent_items_message_count - sent, 1, "one viewer: one content message")
	await _settle()
	assert_eq(_mirror(b).stale_contents_count, 0, "nothing about the content was sent to bob")
	assert_eq(_mirror_contents(b), [])
	# Two players have it open: both follow every change.
	assert_eq(await _open(b, box_id), [true, ""])
	assert_eq(_mirror_contents(b), _server_contents(box_id))
	sent = server_module.sent_items_message_count
	var both: Array[NetworkService] = [a, b]
	var before_put: Array[int] = _message_counts(both)
	assert_eq(await _put(a, box_id, alice_items[0], 1), [true, ""])
	var put_messages: Array[int] = _since(both, before_put)
	assert_eq(server_module.sent_items_message_count - sent, 2, "two viewers: two content messages")
	assert_true(await _wait(func() -> bool: return _mirror_contents(b) == _server_contents(box_id)), "bob sees what alice put in")
	assert_eq(_mirror_contents(a), _server_contents(box_id))
	var stored_id: String = str(_server_contents(box_id)[0][0])
	var before_take: Array[int] = _message_counts(both)
	assert_eq(await _take(b, box_id, stored_id, 1), [true, ""])
	var take_messages: Array[int] = _since(both, before_take)
	assert_true(await _wait(func() -> bool: return _mirror_contents(a) == _server_contents(box_id)), "alice sees what bob took out")
	# Measured, not a limit: what one put and one take of one unit sent with two
	# viewers (content to each viewer, the answer, the owner's inventory change).
	assert_eq(put_messages[0], 3, "a put with two viewers: two content messages and one answer")
	assert_eq(take_messages[0], 3, "a take with two viewers: two content messages and one answer")
	assert_true(put_messages[1] >= 1 and take_messages[1] >= 1, "the inventory change of the requester went through the inventory messages")
	print("[measure] container messages with 2 viewers: one put of 1 unit = %d ContainerNet (server sent) + %d InventoryNet owner messages (received by the two clients), one take of 1 unit = %d + %d" % [put_messages[0], put_messages[1], take_messages[0], take_messages[1]])
	# Both ask for the same two units at once: exactly one gets them.
	var results: Array[Array] = []
	var collect: Callable = func(_request_id: int, ok: bool, reason: String) -> void: results.append([ok, reason])
	_module(a).container_result.connect(collect)
	_module(b).container_result.connect(collect)
	_module(a).request_take(box_id, stored_id, 2)
	_module(b).request_take(box_id, stored_id, 2)
	assert_true(await _wait(func() -> bool: return results.size() == 2), "both were answered")
	_module(a).container_result.disconnect(collect)
	_module(b).container_result.disconnect(collect)
	results.sort_custom(func(x: Array, y: Array) -> bool: return bool(x[0]) and not bool(y[0]))
	assert_eq(results, [[true, ""], [false, ContainerService.REASON_ITEM_NOT_INSIDE]], "one winner, and a clear refusal for the other")
	assert_eq(_stored(box_id), [])
	var bulk_total: int = 0
	for client: NetworkService in [a, b]:
		for row: Array in _carried(_player_id(client)):
			if row[0] == BULK:
				bulk_total += int(row[1])
	assert_eq(bulk_total, 5, "no unit was doubled or lost")
	# Bob closes: later changes are not sent to him any more.
	assert_eq(await _close(b, box_id), [true, ""])
	sent = server_module.sent_items_message_count
	assert_eq(await _put(a, box_id, alice_items[1]), [true, ""])
	assert_eq(server_module.sent_items_message_count - sent, 1)
	await _settle()
	assert_eq(_mirror_contents(b), [])
	# A searched container: everybody near learns THAT it was searched, only
	# the one who has it open learns what was found.
	assert_false(_mirror(b).get_container(cabinet_id)[ClientContainerState.KEY_SEARCHED])
	assert_eq(await _open(a, cabinet_id), [true, ""])
	assert_eq(_mirror(a).open_container_id(), cabinet_id, "opening another container closed the first")
	assert_true(await _wait(func() -> bool: return _mirror(b).get_container(cabinet_id)[ClientContainerState.KEY_SEARCHED] == true), "bob sees that it was searched")
	assert_eq(_mirror_contents(a), _server_contents(cabinet_id))
	assert_eq(_mirror_contents(b), [])
	var two: Array[NetworkService] = [a, b]
	_assert_clean(two, "disclosure")


# ------------------------------------------------------------ 3. cells

func test_containers_follow_the_cells_a_client_is_told_about() -> void:
	assert_true(_start(), "server started")
	var home_id: String = _create(BOX, STORE_AT)
	var far_id: String = _create(CABINET, NEAR_FAR_AWAY)
	var a: NetworkService = await _join("alice")
	var c: NetworkService = await _join("carol")
	if a == null or c == null:
		return
	assert_eq(_sorted_ids(a), PackedStringArray([home_id]), "the join data holds the containers of the joining client's cells only")
	assert_eq(_sorted_ids(c), PackedStringArray([home_id]))
	var home: Dictionary = _mirror(a).get_container(home_id)
	assert_eq(home[ClientContainerState.KEY_DEFINITION_ID], BOX)
	assert_eq(home[ClientContainerState.KEY_POSITION], STORE_AT)
	assert_eq(home[ClientContainerState.KEY_SEARCHED], true, "a container without loot counts as searched")
	# Carol walks far away: she loses the home container and gains the far one.
	await _place(c, FAR_AWAY)
	assert_eq(_sorted_ids(c), PackedStringArray([far_id]), "cell lost: removed; cell gained: added")
	assert_eq(_mirror(c).get_container(far_id)[ClientContainerState.KEY_SEARCHED], false)
	# A container created while a client is told about the cell appears at
	# once, for that client only.
	var c_changes: Array[int] = _changes_of(c)
	var new_id: String = _create(CABINET, SECOND_AT)
	assert_true(await _wait(func() -> bool: return _mirror(a).has_container(new_id)), "alice is told about the new container")
	await _settle()
	assert_eq(c_changes[0], 0, "carol is not: it is not in her cells")
	# A late joiner gets what stands around the spawn point, and no content.
	assert_eq(await _open(a, home_id), [true, ""])
	var b: NetworkService = await _join("bob")
	if b == null:
		return
	assert_eq(_sorted_ids(b), PackedStringArray([home_id, new_id]), "a late joiner is told about the containers around it")
	assert_eq(_mirror(b).phase(), ClientContainerState.PHASE_NONE)
	assert_eq(_mirror_contents(b), [], "and nothing about what is inside or who has one open")
	# Carol comes back: the far one goes, the two near the origin come.
	await _place(c, Vector3.ZERO)
	assert_eq(_sorted_ids(c), PackedStringArray([home_id, new_id]))
	# Alice walks away with the container open: the server closes it.
	var closed: Array = []
	_mirror(a).session_closed.connect(func(container_id: String, reason: String) -> void: closed.append([container_id, reason]))
	_world.get_player(_player_id(a)).position = ACROSS_AT
	assert_true(await _wait(func() -> bool: return not closed.is_empty()), "the session ended")
	assert_eq(closed, [[home_id, ContainerService.REASON_TOO_FAR]])
	assert_eq(_mirror(a).phase(), ClientContainerState.PHASE_NONE)
	assert_eq(_containers().session_count(), 0)
	assert_true(_mirror(a).has_container(home_id), "the container itself is still in her cells")
	var three: Array[NetworkService] = [a, b, c]
	_assert_clean(three, "cells")


# ------------------------------------------------------------ 4. forged requests

func test_forged_and_malformed_requests_are_refused_and_reveal_nothing() -> void:
	assert_true(_start(), "server started")
	var alice_items: Array[String] = _prepare("alice", [[BULK, 3]])
	var bob_items: Array[String] = _prepare("bob", [[PLAIN, 1]])
	var box_id: String = _create(BOX, STORE_AT)
	var across_id: String = _create(BOX, ACROSS_AT)
	var far_id: String = _create(BOX, NEAR_FAR_AWAY)
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var server: NetworkService = _cluster.server
	var module: ContainerNetModule = _module(a)
	assert_true(_mirror(a).has_container(across_id), "a container in her cells, out of reach")
	assert_false(_mirror(a).has_container(far_id), "a container she is not told about")
	# Bob has the box open and put his item in; alice has not opened it.
	assert_eq(await _open(b, box_id), [true, ""])
	assert_eq(await _put(b, box_id, bob_items[0]), [true, ""])
	var snapshot: String = JSON.stringify([_server_contents(box_id), _inventory_server(a), _inventory_server(b)])

	# Out of reach: the range is the server's.
	assert_eq(await _open(a, across_id), [false, ContainerService.REASON_TOO_FAR])
	assert_eq(await _take(a, across_id, bob_items[0], 1), [false, ContainerService.REASON_NOT_OPEN])
	# A container outside her cells answers exactly like one that does not
	# exist, for every intent.
	for container_id: String in [far_id, MISSING_CONTAINER_ID]:
		assert_eq(await _open(a, container_id), [false, ContainerService.REASON_UNKNOWN_CONTAINER], container_id)
		assert_eq(await _take(a, container_id, bob_items[0], 1), [false, ContainerService.REASON_UNKNOWN_CONTAINER], container_id)
		assert_eq(await _put(a, container_id, alice_items[0], 1), [false, ContainerService.REASON_UNKNOWN_CONTAINER], container_id)
		assert_eq(await _close(a, container_id), [false, ContainerService.REASON_UNKNOWN_CONTAINER], container_id)
	# Not opened: nothing can be taken or put, and nothing is learnt about
	# what is inside (an item that is inside and one that is not answer alike).
	assert_eq(await _take(a, box_id, bob_items[0], 1), [false, ContainerService.REASON_NOT_OPEN])
	assert_eq(await _take(a, box_id, MISSING_ITEM_ID, 1), [false, ContainerService.REASON_NOT_OPEN])
	assert_eq(await _put(a, box_id, alice_items[0], 1), [false, ContainerService.REASON_NOT_OPEN])
	assert_eq(await _close(a, box_id), [false, ContainerService.REASON_NOT_OPEN])
	# Opened: items that are not where the request says, and bad quantities.
	assert_eq(await _open(a, box_id), [true, ""])
	assert_eq(await _open(a, box_id), [false, ContainerService.REASON_ALREADY_OPEN])
	assert_eq(await _take(a, box_id, MISSING_ITEM_ID, 1), [false, ContainerService.REASON_ITEM_NOT_INSIDE])
	assert_eq(await _take(a, box_id, alice_items[0], 1), [false, ContainerService.REASON_ITEM_NOT_INSIDE], "her own carried stack is not inside")
	assert_eq(await _take(a, box_id, bob_items[0], 2), [false, InventoryService.REASON_BAD_QUANTITY], "more than the stack holds")
	assert_eq(await _take(a, box_id, bob_items[0], 1000000), [false, InventoryService.REASON_BAD_QUANTITY])
	assert_eq(await _put(a, box_id, MISSING_ITEM_ID, 1), [false, ContainerService.REASON_ITEM_NOT_CARRIED])
	assert_eq(await _put(a, box_id, bob_items[0], 1), [false, ContainerService.REASON_ITEM_NOT_CARRIED], "an item she does not carry (it lies in the box)")
	assert_eq(await _put(a, box_id, alice_items[0], 4), [false, InventoryService.REASON_BAD_QUANTITY])
	# Malformed arguments never reach the rule.
	var results: Array[Array] = []
	module.container_result.connect(func(request_id: int, ok: bool, reason: String) -> void: results.append([request_id, ok, reason]))
	var rejected_before: int = server.rejected_intent_count()
	module.send_raw_open_request(1001, 7)
	module.send_raw_open_request("x", box_id)
	module.send_raw_open_request(-3, box_id)
	module.send_raw_open_request(1002, "")
	module.send_raw_close_request(1003, "c".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1))
	module.send_raw_take_request(1004, box_id, bob_items[0], -1)
	module.send_raw_take_request(1005, box_id, bob_items[0], 1.5)
	module.send_raw_take_request(1006, box_id, 9, 1)
	module.send_raw_put_request(1007, box_id, "", 1)
	module.send_raw_put_request(1008, box_id, alice_items[0], "all")
	module.send_raw_put_request(1009, Vector3.ZERO, alice_items[0], 1)
	const MALFORMED: int = 11
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() - rejected_before == MALFORMED), "every malformed request was rejected (%d)" % (server.rejected_intent_count() - rejected_before))
	await _settle()
	assert_eq(results, [
		[1001, false, IntentValidator.REASON_BAD_TYPE],
		[1002, false, ContainerNetModule.REASON_BAD_CONTAINER_ID],
		[1003, false, ContainerNetModule.REASON_BAD_CONTAINER_ID],
		[1004, false, InventoryService.REASON_BAD_QUANTITY],
		[1005, false, IntentValidator.REASON_BAD_TYPE],
		[1006, false, IntentValidator.REASON_BAD_TYPE],
		[1007, false, IntentValidator.REASON_BAD_ITEM_ID],
		[1008, false, IntentValidator.REASON_BAD_TYPE],
		[1009, false, IntentValidator.REASON_BAD_TYPE],
	], "a request without a usable request id gets no answer")
	# A request cannot carry more than its arguments (no "for player X", no
	# position, no target inventory): the engine refuses a call with more
	# (reported as an engine error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_container_take.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, box_id, bob_items[0], 1, _player_id(b))
	module._rpc_request_container_put.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, box_id, alice_items[0], 1, Vector3.ZERO)
	module._rpc_request_container_open.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, far_id, FAR_AWAY)
	# A client cannot send what only the server sends.
	module._rpc_container_session.rpc_id(NetworkService.SERVER_PEER_ID, box_id, ClientContainerState.PHASE_OPEN, "", 0.0, [])
	_module(b)._rpc_container_items.rpc_id(NetworkService.SERVER_PEER_ID, box_id, [], [bob_items[0]])
	await _settle()
	Engine.print_error_messages = true
	assert_false(results.any(func(row: Array) -> bool: return int(row[0]) == FORGED_REQUEST_ID), "a call with extra arguments never reached the handler")
	assert_eq(_mirror(server).phase(), ClientContainerState.PHASE_NONE, "the server does not take a session state from a client")
	assert_eq(_mirror(server).container_count(), 0)
	assert_eq(JSON.stringify([_server_contents(box_id), _inventory_server(a), _inventory_server(b)]), snapshot, "nothing of all that moved anything")
	# A sleeper and a dead character.
	assert_true(_survival().start_rest(_player_id(a)).ok)
	assert_eq(await _take(a, box_id, bob_items[0], 1), [false, "player_resting"])
	assert_eq(await _open(a, box_id), [false, "player_resting"])
	_survival().stop_rest(_player_id(a))
	assert_true(_survival().apply_damage(_player_id(a), DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(await _open(a, box_id), [false, "player_dead"])
	assert_eq(await _take(a, box_id, bob_items[0], 1), [false, "player_dead"])
	assert_eq(await _put(a, box_id, alice_items[0], 1), [false, "player_dead"])
	assert_eq(await _open(a, far_id), [false, "player_dead"], "a refusal about the requester itself is the same for every container")
	# Nothing of that moved anything either. (Alice's death put her belongings
	# down where she stood: that is the death rule, not a container request.)
	assert_eq(_stored(box_id), [[PLAIN, 1]], "bob's item is still in the box")
	assert_eq(_world.inventory.get_item(bob_items[0]).location_id, _containers().get_container(box_id).inventory_id)
	assert_eq(_world.inventory.get_item(alice_items[0]).quantity, 3, "alice's stack is whole")
	assert_true(snapshot.contains(bob_items[0]))
	assert_eq(_mirror_contents(b), _server_contents(box_id))
	assert_eq(_mirror(a).rejected_payload_count + _mirror(b).rejected_payload_count, 0)


func test_requests_before_join_are_refused_and_floods_are_limited() -> void:
	const BURST: int = 3
	const FLOOD: int = 7
	# One new token every 100 seconds: only the burst passes within the test.
	_net.container_intent_rate_per_sec = 0.01
	_net.container_intent_burst = BURST
	assert_true(_start(), "server started")
	var box_id: String = _create(BOX, STORE_AT)
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var stranger_results: Array[Array] = []
	_module(stranger).container_result.connect(func(request_id: int, ok: bool, reason: String) -> void: stranger_results.append([request_id, ok, reason]))
	var connected: bool = await _wait(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	assert_eq(_module(stranger).request_open(box_id), ContainerNetModule.NO_REQUEST, "the client API sends nothing before the join")
	assert_eq(_module(stranger).request_close(box_id), ContainerNetModule.NO_REQUEST)
	assert_eq(_module(stranger).request_take(box_id, MISSING_ITEM_ID, 1), ContainerNetModule.NO_REQUEST)
	assert_eq(_module(stranger).request_put(box_id, MISSING_ITEM_ID, 1), ContainerNetModule.NO_REQUEST)
	_module(stranger).send_raw_open_request(1, box_id)
	_module(stranger).send_raw_close_request(2, box_id)
	_module(stranger).send_raw_take_request(3, box_id, MISSING_ITEM_ID, 1)
	_module(stranger).send_raw_put_request(4, box_id, MISSING_ITEM_ID, 1)
	assert_true(await _wait(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 4), "the server refused every request of a peer that has not joined")
	await _settle()
	assert_eq(stranger_results.size(), 0, "an unjoined peer is told nothing")
	assert_eq(_mirror(stranger).container_count(), 0, "and knows no container")
	assert_eq(_containers().session_count(), 0)

	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var a_results: Array[Array] = []
	_module(a).container_result.connect(func(request_id: int, ok: bool, reason: String) -> void: a_results.append([request_id, ok, reason]))
	var requests: Array = []
	for index: int in range(FLOOD):
		requests.append(_module(a).request_take(box_id, MISSING_ITEM_ID, 1))
	assert_true(await _wait(func() -> bool: return a_results.size() == FLOOD), "every request was answered (%d)" % a_results.size())
	var expected: Array = []
	for index: int in range(FLOOD):
		expected.append([requests[index], false, ContainerService.REASON_NOT_OPEN if index < BURST else NetworkService.RATE_LIMITED])
	assert_eq(a_results, expected, "only the burst reaches the rule")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST)
	# Another intent of the same peer is limited too; another peer is not.
	assert_eq(await _open(a, box_id), [false, NetworkService.RATE_LIMITED], "all four intents share the allowance")
	assert_eq(await _open(b, box_id), [true, ""])


# ------------------------------------------------------------ 5. searching

func test_a_search_takes_time_and_tells_nothing_until_it_is_over() -> void:
	const SEARCH_SEC: float = 1.0
	_settings.search_duration_sec = SEARCH_SEC
	assert_true(_start(), "server started")
	var cabinet_id: String = _create(CABINET, STORE_AT)
	var other_id: String = _create(CABINET, SECOND_AT)
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var started_msec: int = Time.get_ticks_msec()
	assert_eq(await _open(a, cabinet_id), [true, ""], "a search that started is an accepted request")
	assert_eq(_mirror(a).phase(), ClientContainerState.PHASE_SEARCHING)
	assert_eq(_mirror(a).search_sec(), SEARCH_SEC, "the client is told how long it takes")
	assert_eq(_mirror_contents(a), [], "nothing about the content yet")
	assert_eq(_containers().contents_of(cabinet_id).size(), 0, "nothing was rolled yet")
	assert_eq(await _take(a, cabinet_id, MISSING_ITEM_ID, 1), [false, ContainerService.REASON_SEARCHING])
	assert_true(await _wait(func() -> bool: return _mirror(a).phase() == ClientContainerState.PHASE_OPEN), "the search completes")
	assert_true(Time.get_ticks_msec() - started_msec >= int(SEARCH_SEC * 1000.0) - 200, "not before its time (%d ms)" % (Time.get_ticks_msec() - started_msec))
	assert_true(_containers().get_container(cabinet_id).searched)
	assert_eq(_mirror_contents(a), _server_contents(cabinet_id), "now the content is shown")
	assert_true(await _wait(func() -> bool: return _mirror(b).get_container(cabinet_id)[ClientContainerState.KEY_SEARCHED] == true), "bob sees that it was searched")
	assert_eq(_mirror_contents(b), [])
	# Bob opens the searched container at once.
	assert_eq(await _open(b, cabinet_id), [true, ""])
	assert_eq(_mirror(b).phase(), ClientContainerState.PHASE_OPEN)
	assert_eq(_mirror_contents(b), _server_contents(cabinet_id))
	# A hit interrupts a search: the client is told why, nothing was found.
	var closed: Array = []
	_mirror(a).session_closed.connect(func(container_id: String, reason: String) -> void: closed.append([container_id, reason]))
	assert_eq(await _open(a, other_id), [true, ""])
	assert_eq(_mirror(a).phase(), ClientContainerState.PHASE_SEARCHING)
	assert_true(_survival().apply_damage(_player_id(a), DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LIGHT_DAMAGE)).ok)
	assert_true(await _wait(func() -> bool: return closed.size() == 2), "the search ended")
	assert_eq(closed, [[cabinet_id, ContainerService.REASON_SWITCHED], [other_id, ContainerService.REASON_INTERRUPTED]])
	assert_eq(_mirror(a).phase(), ClientContainerState.PHASE_NONE)
	await _settle()
	assert_false(_containers().get_container(other_id).searched, "an interrupted search finds nothing")
	assert_false(_mirror(b).get_container(other_id)[ClientContainerState.KEY_SEARCHED])
	# Giving a search up with the close request.
	assert_eq(await _open(a, other_id), [true, ""])
	assert_eq(await _close(a, other_id), [true, ""])
	assert_eq(_mirror(a).phase(), ClientContainerState.PHASE_NONE)
	var two: Array[NetworkService] = [a, b]
	_assert_clean(two, "search")


# ------------------------------------------------------------ rules (no network)

func test_rpc_table_settings_and_composition() -> void:
	assert_eq(BuildInfo.PROTOCOL_VERSION, 17, "the container RPCs are a protocol change (15, P3-3; 14 was P3-5)")
	var shipped: ContainerNetSettings = ContainerNetSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0)
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var broken: ContainerNetSettings = ContainerNetSettings.new()
	broken.container_intent_rate_per_sec = 0.0
	config.container_net = broken
	assert_true(config.validate().size() > 0, "composition validation covers the container network settings")
	config.container_net = null
	assert_true(config.validate().size() > 0, "a missing settings object is reported")
	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	var module: ContainerNetModule = service.get_module(ContainerNetModule.MODULE_NAME) as ContainerNetModule
	assert_not_null(module, "the composition installs the container module")
	assert_eq(str(module.name), ContainerNetModule.MODULE_NAME, "same node name on every peer")
	assert_eq(module.request_open("container_000001"), ContainerNetModule.NO_REQUEST, "nothing is sent while offline")
	assert_true(service.get_children().find(service.get_module(InterestNetModule.MODULE_NAME)) < service.get_children().find(module), "after the interest module, whose cells it reads")
	assert_true(service.get_children().find(service.get_module(InventoryNetModule.MODULE_NAME)) < service.get_children().find(module), "after the inventory module, whose save it flushes")
	# Channel 0, reliable; requests from any peer, everything else only from the server.
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	assert_eq(rpc_config.size(), CONTAINER_RPCS.size(), "no other RPC exists")
	for method: String in CONTAINER_RPCS:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), CONTAINER_RPCS[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	service.free()
