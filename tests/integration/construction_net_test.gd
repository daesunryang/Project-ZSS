extends TestCase
## P3-5: building a structure over real ENet (one server and 2..3 clients in
## one process; docs/09 §15.5). One player places a blueprint, another
## brings the materials, both work, and every mirror shows the same state
## and progress and at last the completed wall. Also forged requests,
## flooding, a late joiner, a world cell that leaves memory in the middle
## of a construction, save -> restart -> restore, what a crash between two
## saves can leave on disk, and returned materials as world items.
## Rules: tests/unit/building_construction_test.gd.

const WORLD: String = "construction_net_world"
const NEVER: float = 1.0e9
const WAIT_SEC: float = 15.0
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_FRAMES: int = 20
const GENEROUS_RATE: float = 120.0
const GENEROUS_BURST: int = 120
const LETHAL_DAMAGE: float = 100000.0
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const SPAWN_TILE: Vector2i = Vector2i(5, 5)
const PLANK: String = ConstructionTestKit.PLANK
const NAIL: String = ConstructionTestKit.NAIL
const WALL: String = ConstructionTestKit.WALL
const FLOOR: String = ConstructionTestKit.FLOOR
const FREE_WALL: String = ConstructionTestKit.FREE_WALL
const ENDLESS_WALL: String = ConstructionTestKit.ENDLESS_WALL
const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X
const EAST: int = 1
const WEST: int = 3
const NORTH: int = 0
const EAST_SLOT: Vector3i = Vector3i(6, 5, LOW_X)
## Work of the test wall here, seconds of one worker: short, because these
## tests run in real time.
const WALL_WORK_SEC: float = 1.5
## A tile four cells from the spawn cell: outside its preload ring.
const FAR_TILE: Vector2i = Vector2i(45, 5)
const FAR_CELL: String = "cell_4_0"
const FAR_SPOT: Vector3 = Vector3(45.5, 0.0, 5.5)
const SAVED_FLOAT_TOLERANCE: float = 0.000001

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
	_net_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	_net_settings.pickup_intent_burst = GENEROUS_BURST
	# from_defaults() hands out shared cached resources: replace, never edit.
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.gameplay.world_half_extent_m = 50.0
	_config.gameplay.player_spawn_position = SPAWN
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.wander_pause_min_sec = NEVER
	_config.zombie.wander_pause_max_sec = NEVER
	_config.catalog = ConstructionTestKit.items()
	_config.structures = ConstructionTestKit.structures()
	_config.structures.get_definition(WALL).build_work_sec = WALL_WORK_SEC
	_config.structures.get_definition(FLOOR).build_work_sec = WALL_WORK_SEC
	# The shipped rule: a placement is a blueprint.
	_config.building = BuildingSettings.new()
	_config.structure_net = StructureNetSettings.new()
	_config.structure_net.place_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.place_intent_burst = GENEROUS_BURST
	_config.structure_net.demolish_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.demolish_intent_burst = GENEROUS_BURST
	_config.structure_net.deliver_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.deliver_intent_burst = GENEROUS_BURST
	_config.structure_net.work_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.work_intent_burst = GENEROUS_BURST
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
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	_world = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	if not _save_root.is_empty():
		SaveService.remove_tree(_save_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## A new world whose released cells are kept in memory (no files).
func _start() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	_cells().set_store(WorldCellStore.new())
	return _cluster.start_server(_world, null) == OK


func _eventually(condition: Callable, timeout_sec: float = WAIT_SEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func _settle() -> void:
	await _cluster.wait_frames(SETTLE_FRAMES)


func _building() -> BuildingService:
	return _world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _cells() -> WorldCellService:
	return _world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _net(service: NetworkService) -> StructureNetModule:
	return service.get_module(StructureNetModule.MODULE_NAME) as StructureNetModule


func _inventory_net(service: NetworkService) -> InventoryNetModule:
	return service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule


func _mirror(service: NetworkService) -> ClientStructureState:
	return _net(service).client_state


func _player(client: NetworkService) -> PlayerState:
	return _world.get_player(client.client_state.local_player_id)


func _id(client: NetworkService) -> String:
	return client.client_state.local_player_id


## Items lying at the spawn point for the players to pick up. Spawned before
## the clients join, so they are in every join snapshot.
func _lay(definition_id: String, quantity: int) -> String:
	var item_id: String = _world.inventory.spawn_world_item(definition_id, quantity, _world.cell_id_at(SPAWN), SPAWN)
	if item_id.is_empty():
		fail("test setup: could not lay %d %s" % [quantity, definition_id])
	return item_id


## The client picks the items up, through the real pickup request.
func _pick_up(client: NetworkService, item_ids: Array) -> void:
	for item_id: String in item_ids:
		client.request_pickup(item_id)
	var has_all: Callable = func() -> bool:
		for item_id: String in item_ids:
			if not client.client_state.has_inventory_item(item_id):
				return false
		return true
	if not await _eventually(has_all):
		fail("test setup: pickup of %s failed" % str(item_ids))


## Units of one kind in the client's own inventory mirror.
func _mirrored_units(client: NetworkService, definition_id: String) -> int:
	var units: int = 0
	for entry: Dictionary in client.client_state.inventory:
		if entry["definition_id"] == definition_id:
			units += int(entry["quantity"])
	return units


## Collects every answer the client gets: [request_id, ok, reason, structure_id].
func _results_of(client: NetworkService) -> Array[Array]:
	var results: Array[Array] = []
	_net(client).structure_result.connect(func(request_id: int, ok: bool, reason: String, structure_id: String) -> void: results.append([request_id, ok, reason, structure_id]))
	return results


## Sends one request (`send` returns its id) and waits for its answer:
## [ok, reason, structure_id].
func _ask(client: NetworkService, send: Callable) -> Array:
	var results: Array[Array] = _results_of(client)
	var request_id: int = send.call()
	if not await _eventually(func() -> bool: return results.size() >= 1):
		return [false, "no_answer", ""]
	return results[0].slice(1) if results[0][0] == request_id else [false, "wrong_request_id", ""]


func _place(client: NetworkService, definition_id: String, rotation: int = EAST, tile: Vector2i = SPAWN_TILE) -> Array:
	return await _ask(client, func() -> int: return _net(client).request_place(definition_id, tile, rotation))


func _deliver(client: NetworkService, structure_id: String, item_id: String = BuildingService.ANY_CARRIED_ITEM, quantity: int = BuildingService.AS_MUCH_AS_NEEDED) -> Array:
	return await _ask(client, func() -> int: return _net(client).request_deliver(structure_id, item_id, quantity))


func _work(client: NetworkService, structure_id: String, working: bool) -> Array:
	return await _ask(client, func() -> int: return _net(client).request_work(structure_id, working))


func _cancel(client: NetworkService, structure_id: String) -> Array:
	return await _ask(client, func() -> int: return _net(client).request_cancel(structure_id))


func _demolish(client: NetworkService, structure_id: String) -> Array:
	return await _ask(client, func() -> int: return _net(client).request_demolish(structure_id))


## What the server has in memory, as the mirror would hold it.
func _server_view() -> Dictionary:
	var view: Dictionary = {}
	for row: Dictionary in _building().rows():
		view[str(row["structure_id"])] = {
			"definition_id": row["definition_id"],
			"tile": Vector2i(int(row["x"]), int(row["z"])),
			"rotation": row["rotation"],
			"state": row["state"],
			"door_open": row["door_open"],
			"health_fraction": row["health_fraction"],
			"progress": row["progress"],
			"delivered": row["delivered"],
			"required": row["required"],
		}
	return view


func _client_view(client: NetworkService) -> Dictionary:
	var view: Dictionary = {}
	for structure_id: String in _mirror(client).structure_ids():
		view[structure_id] = _mirror(client).get_structure(structure_id)
	return view


## True when the client's mirror shows exactly what the server has in
## memory: the structures and who works on them.
func _matches_server(client: NetworkService) -> bool:
	if _client_view(client) != _server_view():
		return false
	var working: Dictionary = {}
	for row: Array in _building().worker_rows():
		working[row[0]] = row[1]
	var mirrored: Dictionary = {}
	for player_id: String in _mirror(client).workers:
		mirrored[player_id] = _mirror(client).workers[player_id]
	return mirrored == working


func _join_two() -> Array[NetworkService]:
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return []
	return [a, b]


func _clean(clients: Array) -> void:
	for client: NetworkService in clients:
		assert_eq(_mirror(client).rejected_payload_count, 0, "no structure payload was refused")
		assert_eq(_mirror(client).unknown_removal_count + _mirror(client).unknown_work_stop_count, 0)
		assert_eq(_net(client).rejected_payload_count, 0)
		assert_eq(_inventory_net(client).rejected_payload_count, 0, "no inventory payload was refused")
	assert_eq(_net(_cluster.server).unsendable_row_count, 0)


# ------------------------------------------------------------ 1. building together

func test_one_places_the_other_delivers_both_work_and_both_see_the_same_wall() -> void:
	assert_true(_start(), "server started")
	var planks: String = _lay(PLANK, 6)
	var nails: String = _lay(NAIL, 2)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	await _pick_up(b, [planks, nails])

	# Alice places: a blueprint, for both.
	var placed: Array = await _place(a, WALL)
	assert_eq(placed.slice(0, 2), [true, ""], "the server approved the placement")
	var wall_id: String = placed[2]
	assert_true(await _eventually(func() -> bool: return _mirror(b).has_structure(wall_id)), "bob got the blueprint")
	var blueprint: Dictionary = {
		"definition_id": WALL, "tile": SPAWN_TILE, "rotation": EAST, "state": "blueprint", "door_open": false, "health_fraction": 0.0,
		"progress": 0.0, "delivered": {}, "required": {PLANK: 4, NAIL: 2},
	}
	assert_eq(_mirror(a).get_structure(wall_id), blueprint)
	assert_eq(_mirror(b).get_structure(wall_id), blueprint, "both see what it needs")
	assert_false(_building().is_edge_blocked(EAST_SLOT), "a blueprint blocks nothing")
	assert_eq((await _work(a, wall_id, true)).slice(0, 2), [false, BuildingService.REASON_MATERIALS_MISSING], "docs/04 §12: no materials, a clear refusal")

	# Bob brings the materials. He did not place it.
	var alice_owner_messages: int = _inventory_net(a).owner_message_count
	assert_eq(await _deliver(b, wall_id), [true, "", wall_id])
	assert_eq(_mirror(b).get_structure(wall_id)["delivered"], {PLANK: 4, NAIL: 2}, "the row arrives before the answer")
	assert_true(await _eventually(func() -> bool: return _mirror(a).get_structure(wall_id)["delivered"] == {PLANK: 4, NAIL: 2}), "alice sees the materials in it")
	assert_eq(_mirrored_units(b, PLANK), 2, "bob's own inventory: four planks went into the wall")
	assert_eq(_mirrored_units(b, NAIL), 0, "and both nails")
	assert_false(b.client_state.has_inventory_item(nails), "the emptied stack is gone from his mirror")
	assert_eq(ConstructionTestKit.carried(_world, _player(b), PLANK), 2, "as on the server")
	assert_eq(_inventory_net(a).owner_message_count, alice_owner_messages, "alice is told nothing about bob's inventory")
	assert_eq(_mirror(a).get_structure(wall_id)["state"], "blueprint", "materials alone build nothing")

	# Both work. Everybody sees who works, and the progress in steps.
	var a_progress: Array[float] = []
	var a_work: Array[Array] = []
	var b_work: Array[Array] = []
	_mirror(a).structure_changed.connect(func(structure_id: String) -> void: a_progress.append(float(_mirror(a).get_structure(structure_id)["progress"])))
	_mirror(a).work_changed.connect(func(player_id: String, structure_id: String, working: bool, reason: String) -> void: a_work.append([player_id, structure_id, working, reason]))
	_mirror(b).work_changed.connect(func(player_id: String, structure_id: String, working: bool, reason: String) -> void: b_work.append([player_id, structure_id, working, reason]))
	# Counted where it arrives: the server counts once per receiving peer.
	var messages_before: int = _net(a).received_message_count
	var tick_before: int = Engine.get_physics_frames()
	assert_eq(await _work(a, wall_id, true), [true, "", wall_id])
	assert_eq(await _work(b, wall_id, true), [true, "", wall_id])
	assert_true(await _eventually(func() -> bool: return _mirror(a).get_structure(wall_id)["state"] == "completed" and _mirror(b).get_structure(wall_id)["state"] == "completed"), "both see the wall completed")
	var ticks: int = Engine.get_physics_frames() - tick_before
	var messages: int = _net(a).received_message_count - messages_before
	# The acceptance line of the phase: two players see the same structure.
	var completed: Dictionary = blueprint.duplicate(true)
	completed.merge({"state": "completed", "health_fraction": 1.0, "progress": 1.0, "delivered": {PLANK: 4, NAIL: 2}}, true)
	assert_eq(_mirror(a).get_structure(wall_id), completed)
	assert_eq(_mirror(b).get_structure(wall_id), _mirror(a).get_structure(wall_id), "two players see the same wall")
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b)), "and it is what the server has, with nobody working any more")
	# It blocks now, on the server.
	assert_true(_building().is_edge_blocked(EAST_SLOT))
	assert_true(_world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, SPAWN, Vector3(7.5, 0.0, 5.5)).x < 6.0, "the completed wall stops a step")
	# Who worked was public, in the same order for both.
	var alice_id: String = _id(a)
	var bob_id: String = _id(b)
	assert_eq(a_work.slice(0, 2), [[alice_id, wall_id, true, ""], [bob_id, wall_id, true, ""]])
	assert_eq(a_work, b_work, "both mirrors heard the same work changes")
	assert_eq(a_work.size(), 4)
	for change: Array in a_work.slice(2):
		assert_eq(change.slice(1), [wall_id, false, BuildingService.STOP_FINISHED])
	# Progress came in steps: more than a start and an end, far fewer than
	# server ticks, never backwards.
	assert_true(a_progress.size() >= 10 and a_progress.size() <= 30, "progress rows: %d in %d server ticks" % [a_progress.size(), ticks])
	for index: int in range(1, a_progress.size()):
		assert_true(a_progress[index] >= a_progress[index - 1])
	assert_true(messages < ticks, "no message per tick: %d messages in %d ticks" % [messages, ticks])
	print("[measure] one wall built by two workers over the network: %d replication messages (%d structure rows, 4 work changes) in %d server ticks" % [messages, a_progress.size(), ticks])
	# The finished wall takes no more work or materials.
	assert_eq(await _work(b, wall_id, true), [false, BuildingService.REASON_NOT_UNDER_CONSTRUCTION, ""])
	assert_eq(await _deliver(b, wall_id), [false, BuildingService.REASON_NOT_UNDER_CONSTRUCTION, ""])
	assert_eq(_mirrored_units(b, PLANK), 2)
	assert_eq(_net(_cluster.server).client_state.structure_count(), 0, "the server keeps no mirror")
	_clean(clients)


func test_measure_the_messages_of_one_wall_built_by_one_worker() -> void:
	assert_true(_start(), "server started")
	var planks: String = _lay(PLANK, 4)
	var nails: String = _lay(NAIL, 2)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	await _pick_up(a, [planks, nails])
	# Counted where it arrives (the server counts once per receiving peer).
	var observer: StructureNetModule = _net(clients[1])
	var before: Array[int] = [observer.received_message_count, observer.received_row_count, observer.received_work_change_count]
	var tick_before: int = Engine.get_physics_frames()
	var placed: Array = await _place(a, WALL)
	var wall_id: String = placed[2]
	assert_eq(await _deliver(a, wall_id), [true, "", wall_id])
	assert_eq(await _work(a, wall_id, true), [true, "", wall_id])
	assert_true(await _eventually(func() -> bool: return _mirror(clients[1]).has_structure(wall_id) and _mirror(clients[1]).get_structure(wall_id)["state"] == "completed"))
	await _settle()
	var messages: int = observer.received_message_count - before[0]
	var rows: int = observer.received_row_count - before[1]
	var work_changes: int = observer.received_work_change_count - before[2]
	var ticks: int = Engine.get_physics_frames() - tick_before
	# Placed, delivered, became `constructing`, a row per progress step,
	# completed; work started and stopped.
	var steps: int = roundi(1.0 / _config.building.progress_event_step)
	assert_eq(work_changes, 2)
	assert_true(rows >= steps and rows <= steps + 5, "%d rows for %d progress steps" % [rows, steps])
	assert_eq(messages, rows + work_changes, "one message per row here: every row was sent in its own tick")
	print("[measure] one wall from placement to completion, one worker, progress step %.0f%%: %d replication messages to each client (%d structure rows, %d work changes) in %d server ticks; independent of how long the work takes" % [_config.building.progress_event_step * 100.0, messages, rows, work_changes, ticks])
	_clean(clients)


# ------------------------------------------------------------ 2. forged requests

func test_forged_construction_requests_are_refused_and_change_nothing() -> void:
	assert_true(_start(), "server started")
	var bobs_planks: String = _lay(PLANK, 6)
	var bobs_nails: String = _lay(NAIL, 2)
	var alices_nails: String = _lay(NAIL, 3)
	var lying: String = _lay(PLANK, 5)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	await _pick_up(b, [bobs_planks, bobs_nails])
	await _pick_up(a, [alices_nails])
	var wall: Array = await _place(a, WALL)
	var floor_answer: Array = await _place(a, FLOOR)
	assert_true(wall[0] and floor_answer[0])
	var wall_id: String = wall[2]
	var done_id: String = floor_answer[2]
	assert_true(_building().complete_structure(_world, done_id).ok)
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b)))
	var before: Dictionary = _server_view()
	var b_results: Array[Array] = _results_of(b)
	var module: StructureNetModule = _net(b)
	var expected: Array = []
	# --- deliver: only what bob himself carries, in sane amounts ---
	module.send_raw_deliver_request(1, wall_id, alices_nails, 1)
	expected.append([1, false, InventoryService.REASON_NOT_IN_INVENTORY, ""])
	module.send_raw_deliver_request(2, wall_id, lying, 1)
	expected.append([2, false, InventoryService.REASON_NOT_IN_INVENTORY, ""])
	module.send_raw_deliver_request(3, wall_id, "item_999999", 1)
	expected.append([3, false, InventoryService.REASON_NOT_IN_INVENTORY, ""])
	module.send_raw_deliver_request(4, wall_id, bobs_planks, -1)
	expected.append([4, false, InventoryService.REASON_BAD_QUANTITY, ""])
	module.send_raw_deliver_request(5, wall_id, bobs_planks, StructureDefinition.MAX_COST_QUANTITY + 1)
	expected.append([5, false, InventoryService.REASON_BAD_QUANTITY, ""])
	module.send_raw_deliver_request(6, wall_id, bobs_planks, 9223372036854775807)
	expected.append([6, false, InventoryService.REASON_BAD_QUANTITY, ""])
	module.send_raw_deliver_request(7, wall_id, bobs_planks, 7)
	expected.append([7, false, InventoryService.REASON_BAD_QUANTITY, ""])
	module.send_raw_deliver_request(8, wall_id, bobs_planks, 2.5)
	expected.append([8, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_deliver_request(9, wall_id, 7, 1)
	expected.append([9, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_deliver_request(10, 5, bobs_planks, 1)
	expected.append([10, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_deliver_request(11, wall_id, "x".repeat(200), 1)
	expected.append([11, false, IntentValidator.REASON_BAD_ITEM_ID, ""])
	module.send_raw_deliver_request(12, "structure_999999", bobs_planks, 1)
	expected.append([12, false, BuildingService.REASON_UNKNOWN_STRUCTURE, ""])
	module.send_raw_deliver_request(13, "wall", bobs_planks, 1)
	expected.append([13, false, StructureNetModule.REASON_BAD_STRUCTURE_ID, ""])
	module.send_raw_deliver_request(14, done_id, bobs_planks, 1)
	expected.append([14, false, BuildingService.REASON_NOT_UNDER_CONSTRUCTION, ""])
	module.send_raw_deliver_request(15, wall_id, "", 3)
	expected.append([15, false, InventoryService.REASON_BAD_QUANTITY, ""])
	# --- work ---
	module.send_raw_work_request(16, wall_id, "yes")
	expected.append([16, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_work_request(17, wall_id, 1)
	expected.append([17, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_work_request(18, wall_id, true)
	expected.append([18, false, BuildingService.REASON_MATERIALS_MISSING, ""])
	module.send_raw_work_request(19, wall_id, false)
	expected.append([19, false, BuildingService.REASON_NOT_WORKING, ""])
	module.send_raw_work_request(20, "structure_999999", true)
	expected.append([20, false, BuildingService.REASON_UNKNOWN_STRUCTURE, ""])
	module.send_raw_work_request(21, done_id, true)
	expected.append([21, false, BuildingService.REASON_NOT_UNDER_CONSTRUCTION, ""])
	module.send_raw_work_request(22, _id(b), true)
	expected.append([22, false, StructureNetModule.REASON_BAD_STRUCTURE_ID, ""])
	# --- cancel: somebody else's blueprint, a finished piece ---
	module.send_raw_cancel_request(23, wall_id)
	expected.append([23, false, BuildingService.REASON_NOT_OWNER, ""])
	module.send_raw_cancel_request(24, done_id)
	expected.append([24, false, BuildingService.REASON_NOT_UNDER_CONSTRUCTION, ""])
	module.send_raw_cancel_request(25, "structure_999999")
	expected.append([25, false, BuildingService.REASON_UNKNOWN_STRUCTURE, ""])
	module.send_raw_cancel_request(26, 26)
	expected.append([26, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_cancel_request(27, "structure_" + "9".repeat(100))
	expected.append([27, false, StructureNetModule.REASON_BAD_STRUCTURE_ID, ""])
	assert_true(await _eventually(func() -> bool: return b_results.size() == expected.size()), "every request with a usable id was answered (%d of %d)" % [b_results.size(), expected.size()])
	assert_eq(b_results, expected)
	# The owner demolishes a finished piece and cancels an unfinished one,
	# never the other way round.
	assert_eq(await _demolish(a, wall_id), [false, BuildingService.REASON_UNDER_CONSTRUCTION, ""])
	assert_eq(await _cancel(a, done_id), [false, BuildingService.REASON_NOT_UNDER_CONSTRUCTION, ""])
	# Requests without a usable request id are refused without an answer.
	module.send_raw_deliver_request(-5, wall_id, bobs_planks, 1)
	module.send_raw_work_request(-1, wall_id, true)
	module.send_raw_cancel_request(-3, wall_id)
	assert_true(await _eventually(func() -> bool: return _cluster.server.rejected_intent_count(IntentValidator.REASON_BAD_SEQUENCE) == 3), "negative request ids are counted")
	await _settle()
	assert_eq(b_results.size(), expected.size(), "and not answered")
	# Out of range: the server's position of the player decides.
	_player(b).position = Vector3(20.5, 0.0, 5.5)
	assert_eq(await _deliver(b, wall_id, bobs_planks, 1), [false, BuildingService.REASON_TOO_FAR, ""])
	assert_eq(await _work(b, wall_id, true), [false, BuildingService.REASON_TOO_FAR, ""])
	_player(b).position = SPAWN
	# The state of the player: asleep, then dead.
	var bob_id: String = _id(b)
	assert_true(_survival().start_rest(bob_id).ok)
	assert_eq(await _deliver(b, wall_id, bobs_planks, 1), [false, SurvivalService.REASON_PLAYER_RESTING, ""])
	assert_eq(await _work(b, wall_id, true), [false, SurvivalService.REASON_PLAYER_RESTING, ""])
	assert_true(_survival().stop_rest(bob_id).ok)
	# A connection that never joined.
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	assert_true(await _eventually(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED), "the stranger connected")
	_net(stranger).send_raw_deliver_request(1, wall_id, bobs_planks, 1)
	_net(stranger).send_raw_work_request(2, wall_id, true)
	_net(stranger).send_raw_cancel_request(3, wall_id)
	assert_true(await _eventually(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 3), "requests of a peer that did not join are refused")
	# Nothing changed anywhere.
	await _settle()
	assert_eq(_server_view(), before, "the server's structures are untouched")
	assert_true(_matches_server(a) and _matches_server(b))
	assert_eq(_building().worker_count(), 0)
	assert_eq(ConstructionTestKit.carried(_world, _player(b), PLANK), 6)
	assert_eq(_mirrored_units(b, PLANK), 6)
	assert_eq(ConstructionTestKit.carried(_world, _player(a), NAIL), 3, "alice's nails are still hers")
	assert_eq(_world.inventory.get_item(lying).quantity, 5)
	assert_eq(_cluster.server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE), 6)
	assert_eq(_cluster.server.rejected_intent_count(InventoryService.REASON_BAD_QUANTITY), 5)
	assert_eq(_cluster.server.rejected_intent_count(BuildingService.REASON_NOT_OWNER), 1)
	# A dead character does nothing at all (its things fall to the ground).
	assert_true(_survival().apply_damage(bob_id, DamageInput.create("test_source", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(await _deliver(b, wall_id), [false, SurvivalService.REASON_PLAYER_DEAD, ""])
	assert_eq(await _work(b, wall_id, true), [false, SurvivalService.REASON_PLAYER_DEAD, ""])
	assert_eq(await _cancel(b, wall_id), [false, SurvivalService.REASON_PLAYER_DEAD, ""])
	assert_eq(_server_view(), before)
	assert_eq(_net(_cluster.server).request_deliver(wall_id), StructureNetModule.NO_REQUEST, "the server role sends no request")
	_clean(clients)


# ------------------------------------------------------------ 3. flooding

func test_a_flood_of_construction_requests_is_rate_limited_per_peer_and_intent() -> void:
	const BURST: int = 2
	const FLOOD: int = 6
	# One new token every 100 seconds: only the burst passes within the test.
	_config.structure_net.deliver_intent_rate_per_sec = 0.01
	_config.structure_net.deliver_intent_burst = BURST
	_config.structure_net.work_intent_rate_per_sec = 0.01
	_config.structure_net.work_intent_burst = 1
	_config.structure_net.demolish_intent_rate_per_sec = 0.01
	_config.structure_net.demolish_intent_burst = 1
	assert_true(_start(), "server started")
	var bobs_planks: String = _lay(PLANK, 6)
	var alices_nails: String = _lay(NAIL, 2)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	await _pick_up(b, [bobs_planks])
	await _pick_up(a, [alices_nails])
	var wall_id: String = (await _place(a, WALL))[2]
	var spare_id: String = (await _place(a, FREE_WALL, WEST))[2]
	var done_id: String = (await _place(a, FREE_WALL, NORTH))[2]
	assert_true(_building().complete_structure(_world, done_id).ok)
	var b_results: Array[Array] = _results_of(b)
	var requests: Array = []
	for index: int in range(FLOOD):
		requests.append(_net(b).request_deliver(wall_id, bobs_planks, 1))
	assert_true(await _eventually(func() -> bool: return b_results.size() == FLOOD), "every request was answered (%d)" % b_results.size())
	for index: int in range(FLOOD):
		assert_eq(b_results[index][0], requests[index])
		if index < BURST:
			assert_eq(b_results[index].slice(1), [true, "", wall_id], "request %d is within the burst" % index)
		else:
			assert_eq(b_results[index].slice(1), [false, NetworkService.RATE_LIMITED, ""], "request %d is over the limit" % index)
	assert_eq(_building().get_structure(wall_id).delivered_materials[PLANK], BURST, "the refused requests delivered nothing")
	assert_eq(ConstructionTestKit.carried(_world, _player(b), PLANK), 6 - BURST)
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST)
	# The bucket is per peer and per intent.
	assert_eq(await _deliver(a, wall_id), [true, "", wall_id], "alice is not limited by bob's flood")
	assert_eq(await _work(b, spare_id, true), [true, "", spare_id], "work has its own bucket")
	assert_eq(await _work(b, spare_id, false), [false, NetworkService.RATE_LIMITED, ""])
	assert_eq(_building().work_of(_id(b)), spare_id, "the refused stop request stopped nothing")
	# Cancel and demolish share one bucket: both take a structure away.
	assert_eq(await _cancel(a, spare_id), [true, "", spare_id])
	assert_eq(await _demolish(a, done_id), [false, NetworkService.RATE_LIMITED, ""])
	assert_true(_building().has_structure(done_id))
	await _settle()
	assert_true(_matches_server(a) and _matches_server(b))
	_clean(clients)


# ------------------------------------------------------------ 4. late joiner

func test_a_late_joiner_gets_the_blueprint_with_its_materials_progress_and_workers() -> void:
	assert_true(_start(), "server started")
	var planks: String = _lay(PLANK, 3)
	var a: NetworkService = await _cluster.join_client("alice")
	assert_not_null(a)
	await _pick_up(a, [planks])
	# A wall with half of its materials, worked on until they ran out.
	var wall_id: String = (await _place(a, WALL))[2]
	assert_eq(await _deliver(a, wall_id), [true, "", wall_id])
	assert_eq(await _work(a, wall_id, true), [true, "", wall_id])
	assert_true(await _eventually(func() -> bool: return _building().work_of(_id(a)).is_empty()), "the materials ran out")
	assert_eq(_building().get_structure(wall_id).construction_progress, 0.5)
	# A blueprint nobody touched, and a wall alice is working on right now.
	var blueprint_id: String = (await _place(a, FLOOR))[2]
	var endless_id: String = (await _place(a, ENDLESS_WALL, WEST))[2]
	assert_eq(await _work(a, endless_id, true), [true, "", endless_id])
	await _settle()

	var b: NetworkService = await _cluster.join_client("bob")
	assert_not_null(b)
	# The mirror is complete the moment the join is.
	assert_eq(_mirror(b).structure_count(), 3)
	var joined: Dictionary = _mirror(b).get_structure(wall_id)
	assert_eq(joined["state"], "constructing")
	assert_eq(joined["progress"], 0.5, "with its progress")
	assert_eq(joined["delivered"], {PLANK: 3}, "what is in it")
	assert_eq(joined["required"], {PLANK: 4, NAIL: 2}, "and what it needs")
	assert_eq(_mirror(b).get_structure(blueprint_id)["state"], "blueprint")
	assert_eq(_mirror(b).work_of(_id(a)), endless_id, "and who is working on what")
	assert_eq(_mirror(b).workers_of(endless_id), PackedStringArray([_id(a)]))
	assert_eq(_mirror(b).get_structure(endless_id)["state"], "constructing")
	# From then on it follows changes like everybody else: alice stops, and
	# both mirrors hold exactly what the server has.
	assert_eq(await _work(a, endless_id, false), [true, "", endless_id])
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b)), "the late joiner has what the server has")
	assert_eq(_mirror(b).work_of(_id(a)), "")
	assert_eq(_client_view(a), _client_view(b))
	_clean([a, b])


# ------------------------------------------------------------ 5. world cells

func test_a_cell_released_in_the_middle_of_a_construction_comes_back_for_everybody() -> void:
	# This test is about a cell leaving the server's memory while a client
	# watches it: bob, at home, is told about the far cell too (the interest
	# area is the whole map here, as in world_cell_net_test.gd). With the
	# shipped interest area he would never see it (structure_interest_net_test.gd).
	_config.interest = InterestSettings.new()
	_config.interest.interest_radius_cells = 10
	_config.interest.keep_margin_cells = 0
	assert_true(_start(), "server started")
	var planks: String = _lay(PLANK, 4)
	var nails: String = _lay(NAIL, 2)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	await _pick_up(a, [planks, nails])
	# Alice goes far away and starts a wall there: all planks, one nail.
	_player(a).position = FAR_SPOT
	assert_true(await _eventually(func() -> bool: return _cells().is_loaded(FAR_CELL)))
	var wall_id: String = (await _place(a, WALL, EAST, FAR_TILE))[2]
	assert_eq(await _deliver(a, wall_id, planks), [true, "", wall_id])
	assert_eq(await _deliver(a, wall_id, nails, 1), [true, "", wall_id])
	assert_eq(await _work(a, wall_id, true), [true, "", wall_id])
	assert_true(await _eventually(func() -> bool: return _building().get_structure(wall_id).construction_progress > 0.2), "some work is done")
	var b_work: Array[Array] = []
	var b_removed: PackedStringArray = []
	var b_added: PackedStringArray = []
	_mirror(b).work_changed.connect(func(player_id: String, _structure_id: String, working: bool, reason: String) -> void: b_work.append([player_id, working, reason]))
	_mirror(b).structure_removed.connect(func(structure_id: String) -> void: b_removed.append(structure_id))
	_mirror(b).structure_added.connect(func(structure_id: String) -> void: b_added.append(structure_id))

	# She walks home while working: the work stops, the cell is released.
	_player(a).position = SPAWN
	assert_true(await _eventually(func() -> bool: return _cells().state_of(FAR_CELL) == WorldCellLifecycle.State.UNLOADED), "the far cell is released")
	assert_false(_building().has_structure(wall_id))
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b)), "the mirrors show what the server has in memory: nothing")
	assert_eq(_mirror(b).structure_count(), 0)
	assert_eq(b_work, [[_id(a), false, BuildingService.REASON_TOO_FAR]], "bob saw her stop, before the wall left")
	assert_eq(Array(b_removed), [wall_id])
	assert_false(_world.registry.is_tombstoned(wall_id), "released, not removed")
	assert_eq(ConstructionTestKit.carried(_world, _player(a), NAIL), 1, "her last nail is still hers")

	# Bob walks there: the cell is loaded and everybody gets the wall as it was.
	_player(b).position = FAR_SPOT
	assert_true(await _eventually(func() -> bool: return _cells().is_loaded(FAR_CELL)), "the far cell is in memory again")
	assert_true(await _eventually(func() -> bool: return _mirror(a).has_structure(wall_id) and _matches_server(a) and _matches_server(b)), "every client got the wall of the loaded cell")
	var back: Dictionary = _mirror(b).get_structure(wall_id)
	assert_eq(back["state"], "constructing")
	assert_eq(back["delivered"], {PLANK: 4, NAIL: 1})
	assert_true(float(back["progress"]) > 0.2 and float(back["progress"]) <= 5.0 / 6.0, "the progress it had: %f" % float(back["progress"]))
	assert_eq(_mirror(a).get_structure(wall_id), back)
	assert_eq(Array(b_added), [wall_id])
	assert_eq(_building().worker_count(), 0, "nobody works after a reload")
	# Bob, who never touched it, works it up to what its materials allow.
	assert_eq(await _work(b, wall_id, true), [true, "", wall_id])
	assert_true(await _eventually(func() -> bool: return _building().work_of(_id(b)).is_empty()), "the materials ran out")
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b)))
	assert_eq(_mirror(a).get_structure(wall_id)["progress"], 5.0 / 6.0, "five of six units are there")
	_clean(clients)


# ------------------------------------------------------------ 6. saving

func test_a_construction_survives_a_server_restart_and_a_crash_loses_no_material() -> void:
	_save_root = "user://test_saves/construction_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var planks: String = _lay(PLANK, 8)
	var nails: String = _lay(NAIL, 2)
	var a: NetworkService = await _cluster.join_client("alice")
	if a == null:
		fail("alice did not join")
		return
	var alice_id: String = _id(a)
	await _pick_up(a, [planks, nails])
	var save: SaveService = SaveService.new(_save_root)
	var generation: int = save.current_generation(WORLD)

	# When the world is written.
	var wall_id: String = (await _place(a, WALL))[2]
	assert_true(save.current_generation(WORLD) > generation, "an accepted placement is saved at once")
	generation = save.current_generation(WORLD)
	assert_eq(await _deliver(a, wall_id, planks, 4), [true, "", wall_id])
	assert_eq(await _deliver(a, wall_id, nails, 1), [true, "", wall_id])
	assert_eq(await _work(a, wall_id, true), [true, "", wall_id])
	assert_true(await _eventually(func() -> bool: return _building().get_structure(wall_id).construction_progress > 0.3))
	assert_eq(await _work(a, wall_id, false), [true, "", wall_id])
	await _settle()
	assert_eq(save.current_generation(WORLD), generation, "deliveries, work and progress do not write the world (docs/15 P3-116)")

	# What a crash right now would leave: the last save, read into a second
	# world while the server keeps running. The deliveries are not in it,
	# and neither is the loss from alice's inventory: nothing is doubled and
	# nothing is gone.
	var crashed: ServerWorld = WorldPersistence.new(SaveService.new(_save_root), _config).load_or_create(WORLD)
	assert_not_null(crashed)
	if crashed != null:
		var crashed_cells: WorldCellService = crashed.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
		assert_eq(crashed_cells.load_all_saved_cells(crashed).size(), 0)
		var crashed_alice: PlayerState = crashed.get_player(alice_id)
		assert_eq(ConstructionTestKit.carried(crashed, crashed_alice, PLANK), 8, "she has her planks again")
		assert_eq(ConstructionTestKit.carried(crashed, crashed_alice, NAIL), 2)
		var crashed_wall: StructureInstance = (crashed.get_system(BuildingService.SYSTEM_ID) as BuildingService).get_structure(wall_id)
		assert_not_null(crashed_wall, "the blueprint was saved when it was placed")
		if crashed_wall != null:
			assert_eq(crashed_wall.delivered_materials.size(), 0, "and the wall does not have them")
			assert_eq(crashed_wall.construction_progress, 0.0, "the recent progress is lost, as allowed")
		assert_eq(ConstructionTestKit.total(crashed, [crashed_alice], PLANK), ConstructionTestKit.total(_world, [_player(a)], PLANK), "the same number of planks exists in both")
		assert_eq(ConstructionTestKit.total(crashed, [crashed_alice], NAIL), ConstructionTestKit.total(_world, [_player(a)], NAIL))
	crashed = null

	# A cancelled blueprint and a completed floor are written.
	var spare_id: String = (await _place(a, FREE_WALL, WEST))[2]
	generation = save.current_generation(WORLD)
	assert_eq(await _cancel(a, spare_id), [true, "", spare_id])
	assert_eq(save.current_generation(WORLD), generation + 1, "a cancellation is saved at once")
	# A cancellation that returns materials puts items into the world, which
	# the inventory module would save at the end of the tick: one save, not two.
	var refunded_id: String = (await _place(a, FLOOR, EAST, Vector2i(5, 6)))[2]
	assert_eq(await _deliver(a, refunded_id, planks, 2), [true, "", refunded_id])
	generation = save.current_generation(WORLD)
	assert_eq(await _cancel(a, refunded_id), [true, "", refunded_id])
	assert_eq(save.current_generation(WORLD), generation + 1, "saved before the answer")
	await _settle()
	assert_eq(save.current_generation(WORLD), generation + 1, "and written once")
	assert_eq(ConstructionTestKit.lying(_world, PLANK), 2, "the two planks lie where the floor was planned")
	var floor_id: String = (await _place(a, FLOOR))[2]
	assert_eq(await _deliver(a, floor_id, planks), [true, "", floor_id])
	generation = save.current_generation(WORLD)
	assert_eq(await _work(a, floor_id, true), [true, "", floor_id])
	assert_true(await _eventually(func() -> bool: return _building().get_structure(floor_id).construction_state == StructureInstance.State.COMPLETED))
	assert_true(await _eventually(func() -> bool: return save.current_generation(WORLD) > generation), "a completion is saved")
	assert_eq(save.current_generation(WORLD), generation + 1, "once")
	# Work on the wall again, and leave while working.
	assert_eq(await _work(a, wall_id, true), [true, "", wall_id])
	assert_true(await _eventually(func() -> bool: return _building().get_structure(wall_id).construction_progress > 0.55))
	var before: Dictionary = _server_view()
	assert_eq(before.size(), 2)
	var planks_before: int = ConstructionTestKit.total(_world, [_player(a)], PLANK)
	var nails_before: int = ConstructionTestKit.total(_world, [_player(a)], NAIL)

	# --- full restart (the shutdown saves): state comes only from disk ---
	await _cluster.shutdown()
	_cluster = null
	_world = null
	var persistence2: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence2.load_or_create(WORLD)
	assert_not_null(_world, "world restored from save")
	if _world == null:
		return
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	if a2 == null:
		fail("alice did not rejoin")
		return
	assert_eq(_id(a2), alice_id, "alice is the same player")
	assert_true(await _eventually(func() -> bool: return _mirror(a2).structure_count() == 2 and _matches_server(a2)), "session 2: the mirror shows the saved structures")
	var wall: Dictionary = _mirror(a2).get_structure(wall_id)
	assert_eq(wall["state"], "constructing", "in the middle of its construction")
	assert_eq(wall["delivered"], {PLANK: 4, NAIL: 1})
	assert_true(float(wall["progress"]) > 0.55 and float(wall["progress"]) <= 5.0 / 6.0, "with its progress: %f" % float(wall["progress"]))
	# (A save is text: the last bits of a float may differ.)
	assert_true(float(wall["progress"]) >= float(before[wall_id]["progress"]) - SAVED_FLOAT_TOLERANCE, "nothing of the progress before the shutdown is lost")
	assert_eq(_mirror(a2).get_structure(floor_id), before[floor_id], "the completed floor is as it was")
	assert_eq(_building().worker_count(), 0, "after a restart nobody works")
	assert_eq(_mirror(a2).workers.size(), 0)
	assert_false(_building().has_structure(spare_id), "the cancelled blueprint stays gone")
	assert_true(_world.registry.is_tombstoned(spare_id))
	# The inventory agrees with the structures: nothing doubled, nothing lost.
	assert_eq(_mirrored_units(a2, NAIL), 1, "her last nail")
	assert_eq(_mirrored_units(a2, PLANK), 0)
	assert_true(await _eventually(func() -> bool: return a2.client_state.world_items.size() == 1), "the returned planks still lie on the ground")
	assert_eq(ConstructionTestKit.total(_world, [_player(a2)], PLANK), planks_before)
	assert_eq(ConstructionTestKit.total(_world, [_player(a2)], NAIL), nails_before)
	# The construction is resumed and finished.
	assert_eq(await _deliver(a2, wall_id), [true, "", wall_id])
	assert_eq(await _work(a2, wall_id, true), [true, "", wall_id])
	assert_true(await _eventually(func() -> bool: return _mirror(a2).get_structure(wall_id)["state"] == "completed"), "the wall is finished after the restart")
	assert_true(_building().is_edge_blocked(EAST_SLOT))
	assert_eq(_building().get_structure(wall_id).placed_by, alice_id)
	assert_eq(ConstructionTestKit.total(_world, [_player(a2)], PLANK), planks_before)
	_clean([a2])


# ------------------------------------------------------------ 7. returned materials

func test_returned_materials_appear_as_world_items_for_the_clients_that_see_the_place() -> void:
	assert_true(_start(), "server started")
	var planks: String = _lay(PLANK, 6)
	var nails: String = _lay(NAIL, 4)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	# Carol is far away: the spawn cell is not one of her cells (P3-2).
	var c: NetworkService = await _cluster.join_client("carol")
	assert_not_null(c)
	_player(c).position = FAR_SPOT
	var carol_peer: int = _cluster.server.peer_of_player(_id(c))
	assert_true(await _eventually(func() -> bool: return not _cluster.server.is_cell_of_interest(carol_peer, "cell_0_0")), "carol is not told about the spawn cell")
	var carol_items: Array[int] = [0]
	_inventory_net(c).world_items_added.connect(func(ids: PackedStringArray) -> void: carol_items[0] += ids.size())
	await _pick_up(b, [planks, nails])
	assert_true(await _eventually(func() -> bool: return a.client_state.world_items.is_empty() and c.client_state.world_items.is_empty()), "nothing lies in the world")
	var wall_id: String = (await _place(a, WALL))[2]
	assert_eq(await _deliver(b, wall_id), [true, "", wall_id])
	assert_eq(await _work(b, wall_id, true), [true, "", wall_id])
	assert_true(await _eventually(func() -> bool: return _building().get_structure(wall_id).construction_progress > 0.1))
	# Bob brought everything, but alice placed it: she cancels.
	assert_eq(await _cancel(b, wall_id), [false, BuildingService.REASON_NOT_OWNER, ""])
	assert_eq(await _cancel(a, wall_id), [true, "", wall_id])
	assert_true(await _eventually(func() -> bool: return not _mirror(b).has_structure(wall_id) and b.client_state.world_items.size() == 2), "bob sees the wall go and its materials lie there")
	assert_true(await _eventually(func() -> bool: return a.client_state.world_items.size() == 2))
	for client: NetworkService in clients:
		var seen: Dictionary = {}
		for item_id: String in client.client_state.world_items:
			var entry: Dictionary = client.client_state.world_items[item_id]
			assert_eq(entry, _world.inventory.describe_world_item(item_id), "the item as the server has it")
			assert_eq(entry[ClientWorldState.KEY_POSITION], Vector3(6.5, 0.0, 5.5), "at the piece")
			seen[entry[ClientWorldState.KEY_DEFINITION_ID]] = entry[ClientWorldState.KEY_QUANTITY]
		assert_eq(seen, {PLANK: 4, NAIL: 2}, "everything that was delivered, nothing more")
		assert_eq(_mirror(client).workers.size(), 0, "bob's work ended with the wall")
	assert_true(_matches_server(a) and _matches_server(b))
	# Returned materials are a drop in that cell: a client that is not told
	# about the cell hears nothing of them.
	await _settle()
	assert_eq(c.client_state.world_items.size(), 0, "carol, far away, does not get the returned materials")
	assert_eq(carol_items[0], 0, "no world item message reached her")
	assert_eq(_cluster.server.peers_interested_in("cell_0_0").has(carol_peer), false)
	# They are ordinary items: alice, who paid nothing, picks the planks up.
	var returned_planks: String = ""
	for item_id: String in a.client_state.world_items:
		if a.client_state.world_items[item_id][ClientWorldState.KEY_DEFINITION_ID] == PLANK:
			returned_planks = item_id
	_player(a).position = Vector3(6.5, 0.0, 5.5)
	await _pick_up(a, [returned_planks])
	assert_true(await _eventually(func() -> bool: return b.client_state.world_items.size() == 1), "bob sees them picked up")
	assert_eq(_mirrored_units(a, PLANK), 4)
	assert_eq(ConstructionTestKit.total(_world, [_player(a), _player(b)], PLANK), 6, "six planks came into this world and six are in it")
	assert_eq(ConstructionTestKit.total(_world, [_player(a), _player(b)], NAIL), 4)
	# Carol walks there: now the place is hers to see, with what still lies there.
	_player(c).position = SPAWN
	assert_true(await _eventually(func() -> bool: return c.client_state.world_items.size() == 1), "carol sees the nails that are left when she comes")
	assert_eq(c.client_state.world_items, b.client_state.world_items, "the same as bob, who stood there all along")
	_clean([a, b, c])


# ------------------------------------------------------------ rules (no network)

func test_default_settings_and_request_validation() -> void:
	var settings: StructureNetSettings = StructureNetSettings.load_or_default()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	assert_false(settings.persist_on_delivery, "a delivery does not write the world (docs/00 ADR-025)")
	assert_true(settings.persist_on_completion and settings.persist_on_place_and_demolish)
	var broken: StructureNetSettings = StructureNetSettings.new()
	broken.deliver_intent_rate_per_sec = 0.0
	assert_true(broken.validate().size() > 0)
	broken = StructureNetSettings.new()
	broken.work_intent_burst = 0
	assert_true(broken.validate().size() > 0)
	var module: StructureNetModule = StructureNetModule.new(settings, StructureCatalog.load_directory())
	assert_eq(module.request_deliver("structure_000001"), StructureNetModule.NO_REQUEST, "nothing is sent while offline")
	assert_eq(module.request_work("structure_000001", true), StructureNetModule.NO_REQUEST)
	assert_eq(module.request_cancel("structure_000001"), StructureNetModule.NO_REQUEST)
	module.free()
	# Request shapes.
	const ID: String = "structure_000001"
	assert_eq(StructureNetModule.validate_deliver_request(1, ID, "item_000002", 0), "")
	assert_eq(StructureNetModule.validate_deliver_request(1, ID, "", 0), "", "\"\" = whatever is carried and needed")
	assert_eq(StructureNetModule.validate_deliver_request(1, ID, "item_000002", StructureDefinition.MAX_COST_QUANTITY), "")
	assert_eq(StructureNetModule.validate_deliver_request(1, ID, "item_000002", StructureDefinition.MAX_COST_QUANTITY + 1), InventoryService.REASON_BAD_QUANTITY)
	assert_eq(StructureNetModule.validate_deliver_request(1, ID, "item_000002", -1), InventoryService.REASON_BAD_QUANTITY)
	assert_eq(StructureNetModule.validate_deliver_request(1, ID, "item_000002", 1.0), IntentValidator.REASON_BAD_TYPE)
	assert_eq(StructureNetModule.validate_deliver_request(1, ID, null, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(StructureNetModule.validate_deliver_request(1, "zombie_000001", "item_000002", 1), StructureNetModule.REASON_BAD_STRUCTURE_ID)
	assert_eq(StructureNetModule.validate_deliver_request(-1, ID, "item_000002", 1), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(StructureNetModule.validate_deliver_request(1, ID, "i".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1), 1), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(StructureNetModule.validate_work_request(1, ID, true), "")
	assert_eq(StructureNetModule.validate_work_request(1, ID, 0), IntentValidator.REASON_BAD_TYPE)
	assert_eq(StructureNetModule.validate_work_request(1, "door", false), StructureNetModule.REASON_BAD_STRUCTURE_ID)
	assert_eq(StructureNetModule.validate_cancel_request(1, ID), "")
	assert_eq(StructureNetModule.validate_cancel_request(1, 7), IntentValidator.REASON_BAD_TYPE)
	assert_eq(StructureNetModule.validate_cancel_request(-1, ID), IntentValidator.REASON_BAD_SEQUENCE)
