extends TestCase
## P3-2: measurements, not guarantees (CLAUDE.md §6, docs/03 §8). Prints, for
## one scripted scene on the shipped 500 m map, what a client far away from
## the other players is sent with and without replication scope, and what
## the interest bookkeeping costs per server tick with 8 peers on this
## machine. The lines start with "[measure]"; docs/15 §15.2 records one run.
## The assertions only check that the measured work really happened and that
## scope never sends more than no scope.
##
## Scene: 300 world items and 100 standing zombies spread over the whole map
## (fixed seed), three players in three corners. The measured client is the
## one in the corner at (200, -200).
##   "before" = the behaviour of P3-1: every client is told about every cell
##              the server has in memory. Reproduced by an interest area as
##              large as the map (cells not in memory are never announced).
##   "after"  = the shipped interest settings (2 cells, kept up to 3).

const WORLD: String = "interest_measure_world"
const NEVER: float = 1.0e9
const ITEMS: int = 300
const ZOMBIES: int = 100
const SCENE_SEED: int = 20261116
const SPREAD_M: float = 240.0
const WAIT_MSEC: int = 10000
const SETTLE_TICKS: int = 30
const WINDOW_SEC: float = 3.0
const USEC_PER_MSEC: float = 1000.0
const CORNER_A: Vector3 = Vector3(-200.0, 0.0, -200.0)
const CORNER_B: Vector3 = Vector3(200.0, 0.0, 200.0)
const CORNER_C: Vector3 = Vector3(200.0, 0.0, -200.0)
## The measured client walks this way and back to its corner.
const WALK: Array[Vector3] = [
	Vector3(100.0, 0.0, -100.0), Vector3(0.0, 0.0, 0.0), Vector3(-100.0, 0.0, 100.0),
	Vector3(0.0, 0.0, 0.0), Vector3(100.0, 0.0, -100.0), Vector3(200.0, 0.0, -200.0),
]
const WHOLE_MAP_RADIUS: int = 64
const PEERS: int = 8
const IDLE_TICKS: int = 2000
const MOVE_TICKS: int = 200

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_cluster = null
	_world = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

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


## The scene's server with the given interest area. Cells nobody wants are
## released quickly (memory store), as on a server that has been running.
func _start(radius_cells: int, margin_cells: int) -> bool:
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	network_settings.max_players = PEERS
	# from_defaults() hands out shared cached resources: replace, never edit.
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.max_active_zombies = ZOMBIES
	_config.zombie.wander_pause_min_sec = NEVER
	_config.zombie.wander_pause_max_sec = NEVER
	_config.zombie.sight_range_m = 0.0
	_config.zombie_net = ZombieNetSettings.new()
	_config.inventory_net = InventoryNetSettings.new()
	_config.world_cells = WorldCellSettings.new()
	_config.world_cells.refresh_period_sec = 0.0
	_config.world_cells.preload_lookahead_sec = 0.0
	_config.world_cells.deactivate_delay_sec = 0.1
	_config.world_cells.unload_delay_sec = 0.3
	_config.interest = InterestSettings.new()
	_config.interest.interest_radius_cells = radius_cells
	_config.interest.keep_margin_cells = margin_cells
	_cluster = NetTestCluster.new(tree, network_settings, _config)
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	(_world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = SCENE_SEED
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	for index: int in range(ITEMS):
		var position: Vector3 = Vector3(rng.randf_range(-SPREAD_M, SPREAD_M), 0.0, rng.randf_range(-SPREAD_M, SPREAD_M))
		_world.inventory.spawn_world_item("dev_test_item", 1, _world.cell_id_at(position), position)
	for index: int in range(ZOMBIES):
		zombies.spawn_zombie(_world, Vector3(rng.randf_range(-SPREAD_M, SPREAD_M), 0.0, rng.randf_range(-SPREAD_M, SPREAD_M)), 0.0)
	return _cluster.start_server(_world, null) == OK


func _place(client: NetworkService, position: Vector3) -> void:
	var player_id: String = client.client_state.local_player_id
	_world.get_player(player_id).position = position
	await _wait(func() -> bool: return client.client_state.position_of(player_id).distance_to(position) < 0.01)
	await _settle()


func _zombie_module(service: NetworkService) -> ZombieNetModule:
	return service.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule


func _inventory_module(service: NetworkService) -> InventoryNetModule:
	return service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule


## What the client has received so far (the modules' own counters).
func _received(client: NetworkService) -> Dictionary:
	var zombie_module: ZombieNetModule = _zombie_module(client)
	var inventory_module: InventoryNetModule = _inventory_module(client)
	return {
		"snapshot_messages": zombie_module.received_snapshot_message_count,
		"snapshot_rows": zombie_module.received_snapshot_row_count,
		"zombie_events": zombie_module.received_event_count,
		"item_messages": inventory_module.world_item_message_count,
		"items_added": inventory_module.received_world_item_add_count,
		"items_removed": inventory_module.received_world_item_remove_count,
	}


func _delta(before: Dictionary, after: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key: String in after:
		result[key] = int(after[key]) - int(before[key])
	return result


## Bytes of one zombie snapshot row as Godot encodes a Variant (close to,
## not the same as, the bytes on the wire).
func _row_bytes() -> int:
	return var_to_bytes(["zombie_000001", Vector3(123.4, 0.0, -98.7), 1.5, 0, 0.75]).size()


## Runs the scene with one interest area and returns what the far client
## was sent.
func _run_scene(label: String, radius_cells: int, margin_cells: int) -> Dictionary:
	if not _start(radius_cells, margin_cells):
		fail("%s: the server did not start" % label)
		return {}
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	var c: NetworkService = await _cluster.join_client("carol")
	if a == null or b == null or c == null:
		fail("%s: clients did not join" % label)
		return {}
	await _place(a, CORNER_A)
	await _place(b, CORNER_B)
	await _place(c, CORNER_C)
	# Let the cells nobody wants any more leave the server's memory.
	await tree.create_timer(1.0).timeout
	await _settle()
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var result: Dictionary = {
		"mirror_items": c.client_state.world_items.size(),
		"mirror_zombies": _zombie_module(c).client_state.zombie_count(),
		"memory_items": _world.inventory.world_item_ids().size(),
		"memory_zombies": zombies.zombie_count(),
	}
	print("[measure] %s: the far client mirrors %d items and %d zombies; the server has %d items and %d zombies in memory, %d and %d in the world" % [label, result["mirror_items"], result["mirror_zombies"], result["memory_items"], result["memory_zombies"], ITEMS, ZOMBIES])

	# --- standing still for a while ---
	var before: Dictionary = _received(c)
	await tree.create_timer(WINDOW_SEC).timeout
	var standing: Dictionary = _delta(before, _received(c))
	result["standing"] = standing
	print("[measure] %s: standing still for %.1f s the far client received %d zombie snapshot messages with %d rows (about %d bytes of rows), %d zombie events and %d world item messages" % [label, WINDOW_SEC, standing["snapshot_messages"], standing["snapshot_rows"], int(standing["snapshot_rows"]) * _row_bytes(), standing["zombie_events"], standing["item_messages"]])

	# --- walking to the middle of the map, to the opposite side and back,
	# while the client in the first corner stands still ---
	before = _received(c)
	var bystander_before: Dictionary = _received(a)
	for waypoint: Vector3 in WALK:
		await _place(c, waypoint)
	await tree.create_timer(1.0).timeout
	await _settle()
	var walking: Dictionary = _delta(before, _received(c))
	var bystander: Dictionary = _delta(bystander_before, _received(a))
	result["walking"] = walking
	result["bystander"] = bystander
	print("[measure] %s: walking %d legs across the map and back the far client received %d world item messages (%d items added, %d removed by cell) and %d zombie events, besides %d snapshot rows" % [label, WALK.size(), walking["item_messages"], walking["items_added"], walking["items_removed"], walking["zombie_events"], walking["snapshot_rows"]])
	print("[measure] %s: meanwhile a client standing in another corner received %d world item messages (%d items added, %d removed by cell) and %d zombie events, besides %d snapshot rows" % [label, bystander["item_messages"], bystander["items_added"], bystander["items_removed"], bystander["zombie_events"], bystander["snapshot_rows"]])

	# --- leaving and joining again in its corner ---
	_cluster.remove_client(c)
	await _settle()
	var c_again: NetworkService = await _cluster.join_client("carol")
	if c_again == null:
		fail("%s: carol did not join again" % label)
		return result
	result["join_items"] = c_again.client_state.world_items.size()
	result["join_zombies"] = _zombie_module(c_again).client_state.zombie_count()
	print("[measure] %s: the join data of the far client holds %d items and %d zombie rows" % [label, result["join_items"], result["join_zombies"]])
	result["rejected"] = _zombie_module(c_again).client_state.rejected_payload_count + _inventory_module(c_again).rejected_payload_count + _zombie_module(c_again).client_state.event_gap_count
	await _cluster.shutdown()
	_cluster = null
	return result


# ------------------------------------------------------------ measurements

func test_measure_what_a_far_client_is_sent_before_and_after_scope() -> void:
	var before: Dictionary = await _run_scene("before (no scope)", WHOLE_MAP_RADIUS, 0)
	var after: Dictionary = await _run_scene("after (scope)", InterestSettings.new().interest_radius_cells, InterestSettings.new().keep_margin_cells)
	if before.is_empty() or after.is_empty():
		return
	assert_true(int(before["mirror_items"]) > 0 and int(before["mirror_zombies"]) > 0, "the scene has entities in memory")
	assert_eq(before["mirror_items"], before["memory_items"], "without scope a client mirrors everything the server has in memory")
	assert_eq(before["mirror_zombies"], before["memory_zombies"])
	assert_true(int(after["mirror_items"]) < int(before["mirror_items"]), "with scope the far client mirrors fewer items")
	assert_true(int(after["mirror_zombies"]) < int(before["mirror_zombies"]), "and fewer zombies")
	assert_true(int((after["standing"] as Dictionary)["snapshot_rows"]) < int((before["standing"] as Dictionary)["snapshot_rows"]), "and is sent fewer snapshot rows")
	assert_true(int(after["join_items"]) < int(before["join_items"]) and int(after["join_zombies"]) < int(before["join_zombies"]), "its join data is smaller")
	# A client that walked to a place still keeps a ring of cells it passed
	# (hysteresis); one that joins there starts with the plain square.
	assert_true(int(after["join_items"]) <= int(after["mirror_items"]), "a rejoin in the same place gives no more than the walker had")
	var bystander: Dictionary = after["bystander"]
	assert_eq(int(bystander["item_messages"]) + int(bystander["zombie_events"]), 0, "with scope a client that stands still hears nothing of somebody walking elsewhere")
	assert_true(int((before["bystander"] as Dictionary)["item_messages"]) > 0, "without scope it is told about every cell the walker makes the server load")
	assert_eq(int(before["rejected"]) + int(after["rejected"]), 0, "no payload was refused and no event stream had a hole")


func test_measure_the_cost_of_the_interest_update_with_eight_peers() -> void:
	var defaults: InterestSettings = InterestSettings.new()
	assert_true(_start(defaults.interest_radius_cells, defaults.keep_margin_cells))
	var clients: Array[NetworkService] = []
	for index: int in range(PEERS):
		var client: NetworkService = await _cluster.join_client("peer_%d" % index)
		assert_not_null(client)
		if client == null:
			return
		clients.append(client)
	await _settle()
	var server: NetworkService = _cluster.server
	var module: InterestNetModule = server.get_module(InterestNetModule.MODULE_NAME) as InterestNetModule
	var interest: CellInterest = server.cell_interest
	assert_eq(interest.peer_ids().size(), PEERS)
	var player_ids: PackedStringArray = []
	for client: NetworkService in clients:
		player_ids.append(client.client_state.local_player_id)

	# --- nobody moves: the usual tick ---
	var recomputes_before: int = interest.recompute_count
	var started: int = Time.get_ticks_usec()
	for tick: int in range(IDLE_TICKS):
		module.server_physics(1.0 / 60.0)
	var idle_usec: float = float(Time.get_ticks_usec() - started) / float(IDLE_TICKS)
	assert_eq(interest.recompute_count, recomputes_before, "nobody left its cell: nothing was worked out again")
	print("[measure] interest update, %d peers standing still: %.1f usec per server tick (%d ticks)" % [PEERS, idle_usec, IDLE_TICKS])

	# --- every peer crosses a cell border every tick, to and fro: the cells
	# are worked out again but nothing is gained or lost (hysteresis) ---
	# One crossing each way first, so every peer has both columns of cells.
	for x: float in [49.0, 51.0, 49.0]:
		for index: int in range(PEERS):
			_world.get_player(player_ids[index]).position = Vector3(x, 0.0, 10.0 * float(index))
		module.server_physics(1.0 / 60.0)
	var changes_before: int = interest.gained_count + interest.lost_count
	recomputes_before = interest.recompute_count
	started = Time.get_ticks_usec()
	for tick: int in range(MOVE_TICKS):
		for index: int in range(PEERS):
			_world.get_player(player_ids[index]).position = Vector3(51.0 if tick % 2 == 0 else 49.0, 0.0, 10.0 * float(index))
		module.server_physics(1.0 / 60.0)
	var crossing_usec: float = float(Time.get_ticks_usec() - started) / float(MOVE_TICKS)
	assert_eq(interest.recompute_count - recomputes_before, MOVE_TICKS * PEERS, "every crossing was looked at")
	assert_eq(interest.gained_count + interest.lost_count, changes_before, "and none changed a cell (hysteresis)")
	print("[measure] interest update, %d peers each crossing a cell border every tick: %.1f usec per server tick (%d ticks, no cell gained or lost)" % [PEERS, crossing_usec, MOVE_TICKS])

	# --- every peer jumps across the map every tick: all its cells are
	# replaced, and the world items of those cells are sent. Only the
	# interest module is timed; the cell lifecycle runs before it, as on a
	# real tick, so the cells are in memory ---
	var cell_module: WorldCellNetModule = server.get_module(WorldCellNetModule.MODULE_NAME) as WorldCellNetModule
	var cell_service: WorldCellService = _world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	var sent_before: int = cell_module.sent_item_add_count + cell_module.sent_item_remove_count
	var gained_before: int = interest.gained_count
	var timed_usec: int = 0
	for tick: int in range(MOVE_TICKS):
		for index: int in range(PEERS):
			_world.get_player(player_ids[index]).position = Vector3(-200.0 if tick % 2 == 0 else 200.0, 0.0, -200.0 if tick % 2 == 0 else 200.0)
		cell_service.refresh(_world)
		var tick_started: int = Time.get_ticks_usec()
		module.server_physics(1.0 / 60.0)
		timed_usec += Time.get_ticks_usec() - tick_started
	var jump_usec: float = float(timed_usec) / float(MOVE_TICKS)
	var cells_changed: int = interest.gained_count - gained_before
	var items_sent: int = cell_module.sent_item_add_count + cell_module.sent_item_remove_count - sent_before
	assert_true(cells_changed > 0 and items_sent > 0, "the jumps really replaced cells and sent their items")
	print("[measure] interest update, %d peers each jumping across the map every tick: %.1f usec (%.2f ms) per server tick, sending the world items of the cells (%d ticks; %.1f cells gained and %.1f item announcements per tick)" % [PEERS, jump_usec, jump_usec / USEC_PER_MSEC, MOVE_TICKS, float(cells_changed) / float(MOVE_TICKS), float(items_sent) / float(MOVE_TICKS)])



## One zombie replication tick that sends a snapshot (reconciliation, row
## encoding and the RPC calls), with 8 peers standing in a row across the
## map: microseconds per tick and rows sent per tick to all peers together.
func _measure_zombie_tick(label: String, radius_cells: int, margin_cells: int) -> Dictionary:
	if not _start(radius_cells, margin_cells):
		fail("%s: the server did not start" % label)
		return {}
	var player_ids: PackedStringArray = []
	for index: int in range(PEERS):
		var client: NetworkService = await _cluster.join_client("peer_%d" % index)
		if client == null:
			fail("%s: a client did not join" % label)
			return {}
		player_ids.append(client.client_state.local_player_id)
	for index: int in range(PEERS):
		_world.get_player(player_ids[index]).position = Vector3(-210.0 + 60.0 * float(index), 0.0, 0.0)
	# The cells settle: what nobody wants leaves the server's memory.
	await tree.create_timer(1.0).timeout
	await _settle()
	var zombie_module: ZombieNetModule = _zombie_module(_cluster.server)
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var snapshot_period: float = 1.0 / _config.zombie_net.snapshot_rate_hz
	var rows_before: int = zombie_module.sent_snapshot_row_count
	var timed_usec: int = 0
	for tick: int in range(MOVE_TICKS):
		var tick_started: int = Time.get_ticks_usec()
		zombie_module.server_physics(snapshot_period)
		timed_usec += Time.get_ticks_usec() - tick_started
	var result: Dictionary = {
		"usec": float(timed_usec) / float(MOVE_TICKS),
		"rows": float(zombie_module.sent_snapshot_row_count - rows_before) / float(MOVE_TICKS),
		"memory_zombies": zombies.zombie_count(),
	}
	print("[measure] %s: zombie replication tick with a snapshot, %d peers in a row, %d of %d zombies in memory: %.1f usec (%.2f ms) per tick, %.1f rows sent per tick to all peers together (%d ticks)" % [label, PEERS, result["memory_zombies"], ZOMBIES, result["usec"], float(result["usec"]) / USEC_PER_MSEC, result["rows"], MOVE_TICKS])
	await _cluster.shutdown()
	_cluster = null
	return result


func test_measure_the_zombie_replication_tick_with_and_without_scope() -> void:
	var before: Dictionary = await _measure_zombie_tick("before (no scope)", WHOLE_MAP_RADIUS, 0)
	var after: Dictionary = await _measure_zombie_tick("after (scope)", InterestSettings.new().interest_radius_cells, InterestSettings.new().keep_margin_cells)
	if before.is_empty() or after.is_empty():
		return
	assert_true(float(before["rows"]) > 0.0 and float(after["rows"]) > 0.0, "snapshots were sent")
	assert_true(float(after["rows"]) < float(before["rows"]), "with scope fewer rows are sent")
	assert_eq(before["memory_zombies"], after["memory_zombies"], "the same zombies are in memory in both runs")
