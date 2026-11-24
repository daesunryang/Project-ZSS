extends TestCase
## P3-4a: grid structures over real ENet (one server and 2..3 clients in one
## process; docs/09 §15.4). A client only asks; the server decides, and
## every client's mirror shows the same structures as the server: the
## acceptance line of the phase ("두 플레이어가 같은 구조물을 본다", docs/13
## §5). Also forged requests, flooding, a late joiner, world cells that leave
## and enter the server's memory, and save -> restart -> restore.
## Rules: tests/unit/building_service_test.gd.

const WORLD: String = "structure_net_world"
const NEVER: float = 1.0e9
const WAIT_SEC: float = 15.0
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_FRAMES: int = 20
const GENEROUS_RATE: float = 120.0
const GENEROUS_BURST: int = 120
const LETHAL_DAMAGE: float = 100000.0
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const SPAWN_TILE: Vector2i = Vector2i(5, 5)
const FLOOR: String = "dev_floor"
const WALL: String = "dev_wall"
const DOOR: String = "dev_door"
const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X
## A tile four cells from the spawn cell: outside its preload ring.
const FAR_TILE: Vector2i = Vector2i(45, 5)
const FAR_CELL: String = "cell_4_0"
const FAR_SPOT: Vector3 = Vector3(44.5, 0.0, 5.5)

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
	_config.building = BuildingSettings.new()
	# These tests are about standing pieces (P3-4a): the dev switch is on.
	# The construction flow over the network: construction_net_test.gd.
	_config.building.instant_completion = true
	_config.structure_net = StructureNetSettings.new()
	_config.structure_net.place_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.place_intent_burst = GENEROUS_BURST
	_config.structure_net.demolish_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.demolish_intent_burst = GENEROUS_BURST
	_config.structure_net.door_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.door_intent_burst = GENEROUS_BURST
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
	# These tests watch cells leave and enter the server's memory from afar:
	# the interest area is the whole map here (as in world_cell_net_test.gd),
	# so every client is told about every cell the server has in memory. The
	# scope by cell itself: structure_interest_net_test.gd.
	_config.interest = InterestSettings.new()
	_config.interest.interest_radius_cells = 10
	_config.interest.keep_margin_cells = 0
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


func _mirror(service: NetworkService) -> ClientStructureState:
	return _net(service).client_state


func _player(client: NetworkService) -> PlayerState:
	return _world.get_player(client.client_state.local_player_id)


## Collects every answer the client gets: [request_id, ok, reason, structure_id].
func _results_of(client: NetworkService) -> Array[Array]:
	var results: Array[Array] = []
	_net(client).structure_result.connect(func(request_id: int, ok: bool, reason: String, structure_id: String) -> void: results.append([request_id, ok, reason, structure_id]))
	return results


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


## True when the client's mirror shows exactly what the server has in memory.
func _matches_server(client: NetworkService) -> bool:
	return _client_view(client) == _server_view()


## Sends one placement and waits for its answer: [ok, reason, structure_id].
func _place(client: NetworkService, definition_id: String, tile: Vector2i, rotation: int) -> Array:
	var results: Array[Array] = _results_of(client)
	var request_id: int = _net(client).request_place(definition_id, tile, rotation)
	if not await _eventually(func() -> bool: return results.size() >= 1):
		return [false, "no_answer", ""]
	return results[0].slice(1) if results[0][0] == request_id else [false, "wrong_request_id", ""]


func _door(client: NetworkService, structure_id: String, open: bool) -> Array:
	var results: Array[Array] = _results_of(client)
	var request_id: int = _net(client).request_door(structure_id, open)
	if not await _eventually(func() -> bool: return results.size() >= 1):
		return [false, "no_answer", ""]
	return results[0].slice(1) if results[0][0] == request_id else [false, "wrong_request_id", ""]


func _demolish(client: NetworkService, structure_id: String) -> Array:
	var results: Array[Array] = _results_of(client)
	var request_id: int = _net(client).request_demolish(structure_id)
	if not await _eventually(func() -> bool: return results.size() >= 1):
		return [false, "no_answer", ""]
	return results[0].slice(1) if results[0][0] == request_id else [false, "wrong_request_id", ""]


func _join_two() -> Array[NetworkService]:
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return []
	return [a, b]


# ------------------------------------------------------------ 1. the same structure

func test_a_wall_placed_by_one_player_is_seen_by_both() -> void:
	assert_true(_start(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var a_added: PackedStringArray = []
	var b_added: PackedStringArray = []
	_mirror(a).structure_added.connect(func(structure_id: String) -> void: a_added.append(structure_id))
	_mirror(b).structure_added.connect(func(structure_id: String) -> void: b_added.append(structure_id))
	var b_results: Array[Array] = _results_of(b)
	assert_eq(_mirror(a).structure_count(), 0)

	var placed: Array = await _place(a, WALL, Vector2i(6, 5), 1)
	assert_eq(placed.slice(0, 2), [true, ""], "the server approved the placement")
	var wall_id: String = placed[2]
	assert_true(_building().has_structure(wall_id), "the answer names the structure the server made")
	assert_true(await _eventually(func() -> bool: return _mirror(a).has_structure(wall_id) and _mirror(b).has_structure(wall_id)), "both clients got it")
	# The phase's acceptance line: two players see the same structure.
	var required: Dictionary = {}
	for item_id: String in _config.structures.get_definition(WALL).build_costs:
		required[item_id] = _config.structures.get_definition(WALL).build_costs[item_id]
	var expected: Dictionary = {"definition_id": WALL, "tile": Vector2i(6, 5), "rotation": 1, "state": "completed", "door_open": false, "health_fraction": 1.0, "progress": 1.0, "delivered": {}, "required": required}
	assert_eq(_mirror(a).get_structure(wall_id), expected)
	assert_eq(_mirror(b).get_structure(wall_id), _mirror(a).get_structure(wall_id), "two players see the same structure")
	assert_true(_matches_server(a) and _matches_server(b), "and it is what the server has")
	assert_eq(_mirror(b).structure_id_at(Vector3i(7, 5, LOW_X)), wall_id, "the mirror knows which slot it takes")
	assert_eq(_mirror(b).slot_of(wall_id), Vector3i(7, 5, LOW_X))
	assert_eq(Array(a_added), [wall_id])
	assert_eq(Array(b_added), [wall_id])
	# The server made it: the placer is the player of the peer, the place is
	# the tile that was asked for, and the wall stops movement there.
	var structure: StructureInstance = _building().get_structure(wall_id)
	assert_eq(structure.placed_by, a.client_state.local_player_id)
	assert_eq(_world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, Vector3(6.5, 0.0, 5.5), Vector3(7.5, 0.0, 5.5)).x < 7.0, true)
	await _settle()
	assert_eq(b_results.size(), 0, "an answer goes to the requester only")

	# A floor and a door by the other player.
	var floor_answer: Array = await _place(b, FLOOR, SPAWN_TILE, 2)
	var door_answer: Array = await _place(b, DOOR, Vector2i(5, 6), 2)
	assert_true(floor_answer[0] and door_answer[0], "%s %s" % [str(floor_answer), str(door_answer)])
	assert_true(await _eventually(func() -> bool: return _mirror(a).structure_count() == 3 and _mirror(b).structure_count() == 3))
	assert_true(_matches_server(a) and _matches_server(b))
	assert_eq(_client_view(a), _client_view(b), "both mirrors hold the same three structures")
	assert_eq(_mirror(a).get_structure(str(floor_answer[2]))["rotation"], 2)
	for client: NetworkService in clients:
		assert_eq(_mirror(client).rejected_payload_count, 0)
		assert_eq(_net(client).rejected_payload_count, 0)
	assert_eq(_net(_cluster.server).unsendable_row_count, 0)
	assert_eq(_net(_cluster.server).client_state.structure_count(), 0, "the server keeps no mirror")


# ------------------------------------------------------------ 2. doors and demolition

func test_a_door_toggled_by_one_player_is_seen_by_the_other() -> void:
	assert_true(_start(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var placed: Array = await _place(a, DOOR, SPAWN_TILE, 1)
	assert_true(placed[0], str(placed))
	var door_id: String = placed[2]
	assert_true(await _eventually(func() -> bool: return _mirror(b).has_structure(door_id)))
	var a_changed: PackedStringArray = []
	_mirror(a).structure_changed.connect(func(structure_id: String) -> void: a_changed.append(structure_id))
	var slot: Vector3i = Vector3i(6, 5, LOW_X)
	assert_true(_building().is_edge_blocked(slot))

	# Bob did not place the door; he opens it. Alice sees it open.
	assert_eq(await _door(b, door_id, true), [true, "", door_id])
	assert_true(await _eventually(func() -> bool: return bool(_mirror(a).get_structure(door_id)["door_open"])), "alice sees the door bob opened")
	assert_true(bool(_mirror(b).get_structure(door_id)["door_open"]))
	assert_false(_building().is_edge_blocked(slot), "on the server the open door does not block")
	assert_eq(Array(a_changed), [door_id], "a change, not a new structure")
	# The wanted state, not a toggle.
	assert_eq(await _door(a, door_id, true), [false, BuildingService.REASON_DOOR_ALREADY_IN_STATE, ""])
	assert_eq(await _door(a, door_id, false), [true, "", door_id])
	assert_true(await _eventually(func() -> bool: return not bool(_mirror(b).get_structure(door_id)["door_open"])), "bob sees it closed again")
	assert_true(_building().is_edge_blocked(slot))
	assert_true(_matches_server(a) and _matches_server(b))

	# Only the placer demolishes.
	var a_removed: PackedStringArray = []
	var b_removed: PackedStringArray = []
	_mirror(a).structure_removed.connect(func(structure_id: String) -> void: a_removed.append(structure_id))
	_mirror(b).structure_removed.connect(func(structure_id: String) -> void: b_removed.append(structure_id))
	assert_eq(await _demolish(b, door_id), [false, BuildingService.REASON_NOT_OWNER, ""], "bob did not place it")
	assert_true(_building().has_structure(door_id))
	assert_eq(await _demolish(a, door_id), [true, "", door_id])
	assert_true(await _eventually(func() -> bool: return not _mirror(a).has_structure(door_id) and not _mirror(b).has_structure(door_id)), "it is gone for both")
	assert_false(_building().has_structure(door_id))
	assert_eq(Array(a_removed), [door_id])
	assert_eq(Array(b_removed), [door_id])
	assert_eq(_mirror(a).structure_id_at(slot), "")
	assert_eq(await _door(b, door_id, true), [false, BuildingService.REASON_UNKNOWN_STRUCTURE, ""])
	for client: NetworkService in clients:
		assert_eq(_mirror(client).rejected_payload_count + _mirror(client).unknown_removal_count, 0)


# ------------------------------------------------------------ 3. one spot

func test_requests_for_one_spot_exactly_one_wins() -> void:
	assert_true(_start(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = await _cluster.join_client("carol")
	assert_not_null(c)
	var a_results: Array[Array] = _results_of(a)
	var b_results: Array[Array] = _results_of(b)
	# The same edge asked for in the same frame, from its two sides and with
	# different pieces: the server handles them one after the other.
	var a_request: int = _net(a).request_place(WALL, SPAWN_TILE, 1)
	var b_request: int = _net(b).request_place(DOOR, Vector2i(6, 5), 3)
	assert_true(await _eventually(func() -> bool: return a_results.size() == 1 and b_results.size() == 1), "both were answered")
	assert_eq(a_results[0][0], a_request)
	assert_eq(b_results[0][0], b_request)
	var winners: int = (1 if a_results[0][1] else 0) + (1 if b_results[0][1] else 0)
	assert_eq(winners, 1, "exactly one request wins: %s %s" % [str(a_results[0]), str(b_results[0])])
	var loser: Array = b_results[0] if a_results[0][1] else a_results[0]
	assert_eq(loser.slice(1), [false, BuildingService.REASON_SLOT_OCCUPIED, ""])
	assert_eq(_building().structure_count(), 1)
	# A third request for the same spot is refused as well.
	assert_eq(await _place(c, WALL, SPAWN_TILE, 1), [false, BuildingService.REASON_SLOT_OCCUPIED, ""], "the third request")
	assert_eq(await _place(a, DOOR, Vector2i(6, 5), 3), [false, BuildingService.REASON_SLOT_OCCUPIED, ""])
	assert_eq(_building().structure_count(), 1)
	await _settle()
	for client: NetworkService in [a, b, c]:
		assert_eq(_mirror(client).structure_count(), 1, "every client has the one structure")
		assert_true(_matches_server(client))
	assert_eq(_cluster.server.rejected_intent_count(BuildingService.REASON_SLOT_OCCUPIED), 3)


# ------------------------------------------------------------ 4. forged requests

func test_forged_requests_are_refused_and_change_nothing() -> void:
	assert_true(_start(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var placed: Array = await _place(a, WALL, SPAWN_TILE, 1)
	var bobs: Array = await _place(b, DOOR, SPAWN_TILE, 3)
	assert_true(placed[0] and bobs[0])
	var wall_id: String = placed[2]
	var door_id: String = bobs[2]
	await _settle()
	var before: Dictionary = _server_view()
	var a_results: Array[Array] = _results_of(a)
	var module: StructureNetModule = _net(a)
	var expected: Array = []
	# --- placement ---
	module.send_raw_place_request(1, "no_such_structure", 5, 6, 0)
	expected.append([1, false, BuildingService.REASON_UNKNOWN_DEFINITION, ""])
	module.send_raw_place_request(2, "Not A Definition", 5, 6, 0)
	expected.append([2, false, StructureNetModule.REASON_BAD_DEFINITION_ID, ""])
	module.send_raw_place_request(3, "x".repeat(200), 5, 6, 0)
	expected.append([3, false, StructureNetModule.REASON_BAD_DEFINITION_ID, ""])
	# Off the grid: coordinates are whole tiles, anything else is the wrong type.
	module.send_raw_place_request(4, WALL, 5.5, 6, 0)
	expected.append([4, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_place_request(5, WALL, Vector3(5.0, 0.0, 6.0), 6, 0)
	expected.append([5, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_place_request(6, 7, 5, 6, 0)
	expected.append([6, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_place_request(7, WALL, 5, 6, "north")
	expected.append([7, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_place_request(8, WALL, 5, 6, 0.0)
	expected.append([8, false, IntentValidator.REASON_BAD_TYPE, ""])
	# Out of bounds: just past the map, and far beyond any map.
	module.send_raw_place_request(9, FLOOR, 50, 5, 0)
	expected.append([9, false, BuildingService.REASON_OUT_OF_BOUNDS, ""])
	module.send_raw_place_request(10, FLOOR, 5, -4000000000000, 0)
	expected.append([10, false, BuildingService.REASON_OUT_OF_BOUNDS, ""])
	module.send_raw_place_request(11, FLOOR, -9223372036854775807 - 1, 5, 0)
	expected.append([11, false, BuildingService.REASON_OUT_OF_BOUNDS, ""])
	module.send_raw_place_request(12, WALL, 5, 6, 4)
	expected.append([12, false, BuildingService.REASON_BAD_ROTATION, ""])
	module.send_raw_place_request(13, WALL, 5, 6, -1)
	expected.append([13, false, BuildingService.REASON_BAD_ROTATION, ""])
	# Out of range: the server's position of the player decides.
	module.send_raw_place_request(14, FLOOR, 12, 5, 0)
	expected.append([14, false, BuildingService.REASON_TOO_FAR, ""])
	# --- demolish ---
	module.send_raw_demolish_request(15, door_id)
	expected.append([15, false, BuildingService.REASON_NOT_OWNER, ""])
	module.send_raw_demolish_request(16, "structure_999999")
	expected.append([16, false, BuildingService.REASON_UNKNOWN_STRUCTURE, ""])
	module.send_raw_demolish_request(17, a.client_state.local_player_id)
	expected.append([17, false, StructureNetModule.REASON_BAD_STRUCTURE_ID, ""])
	module.send_raw_demolish_request(18, 18)
	expected.append([18, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_demolish_request(19, "structure_" + "9".repeat(100))
	expected.append([19, false, StructureNetModule.REASON_BAD_STRUCTURE_ID, ""])
	# --- door ---
	module.send_raw_door_request(20, wall_id, true)
	expected.append([20, false, BuildingService.REASON_NOT_A_DOOR, ""])
	module.send_raw_door_request(21, door_id, 1)
	expected.append([21, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_door_request(22, door_id, "open")
	expected.append([22, false, IntentValidator.REASON_BAD_TYPE, ""])
	module.send_raw_door_request(23, "door", true)
	expected.append([23, false, StructureNetModule.REASON_BAD_STRUCTURE_ID, ""])
	assert_true(await _eventually(func() -> bool: return a_results.size() == expected.size()), "every request with a usable id was answered (%d of %d)" % [a_results.size(), expected.size()])
	assert_eq(a_results, expected)
	# Requests without a usable request id are refused without an answer.
	module.send_raw_place_request(-5, WALL, 5, 6, 0)
	module.send_raw_place_request("one", WALL, 5, 6, 0)
	module.send_raw_demolish_request(null, wall_id)
	module.send_raw_door_request(-1, door_id, true)
	assert_true(await _eventually(func() -> bool: return _cluster.server.rejected_intent_count(IntentValidator.REASON_BAD_SEQUENCE) == 2), "negative request ids are counted")
	await _settle()
	assert_eq(a_results.size(), expected.size(), "and not answered")
	# The state of the player: asleep, then dead.
	var alice_id: String = a.client_state.local_player_id
	assert_true(_survival().start_rest(alice_id).ok)
	assert_eq(await _place(a, FLOOR, Vector2i(5, 6), 0), [false, SurvivalService.REASON_PLAYER_RESTING, ""])
	assert_eq(await _door(a, door_id, true), [false, SurvivalService.REASON_PLAYER_RESTING, ""])
	assert_true(_survival().stop_rest(alice_id).ok)
	assert_true(_survival().apply_damage(alice_id, DamageInput.create("test_source", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(await _place(a, FLOOR, Vector2i(5, 6), 0), [false, SurvivalService.REASON_PLAYER_DEAD, ""])
	assert_eq(await _demolish(a, wall_id), [false, SurvivalService.REASON_PLAYER_DEAD, ""], "a dead character demolishes nothing, not even its own wall")
	assert_eq(await _door(a, door_id, true), [false, SurvivalService.REASON_PLAYER_DEAD, ""])
	# A connection that never joined.
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	assert_true(await _eventually(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED), "the stranger connected")
	_net(stranger).send_raw_place_request(1, WALL, 5, 6, 0)
	_net(stranger).send_raw_demolish_request(2, wall_id)
	_net(stranger).send_raw_door_request(3, door_id, true)
	assert_true(await _eventually(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 3), "requests of a peer that did not join are refused")
	# Nothing changed anywhere.
	await _settle()
	assert_eq(_server_view(), before, "the server's structures are untouched")
	assert_true(_matches_server(a) and _matches_server(b))
	assert_eq(_building().structure_count(), 2)
	assert_false(_building().get_structure(door_id).door_open)
	assert_eq(_cluster.server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE), 10)
	assert_eq(_cluster.server.rejected_intent_count(BuildingService.REASON_OUT_OF_BOUNDS), 3)
	assert_eq(_cluster.server.rejected_intent_count(BuildingService.REASON_NOT_OWNER), 1)
	assert_eq(_net(a).request_place(WALL, SPAWN_TILE, 0) > 0, true, "a joined client can still ask")
	assert_eq(_net(_cluster.server).request_place(WALL, SPAWN_TILE, 0), StructureNetModule.NO_REQUEST, "the server role sends no request")


# ------------------------------------------------------------ 5. flooding

func test_a_flood_of_requests_is_rate_limited_per_peer() -> void:
	const BURST: int = 3
	const FLOOD: int = 10
	# One new token every 100 seconds: only the burst passes within the test.
	_config.structure_net.place_intent_rate_per_sec = 0.01
	_config.structure_net.place_intent_burst = BURST
	_config.structure_net.door_intent_rate_per_sec = 0.01
	_config.structure_net.door_intent_burst = 1
	assert_true(_start(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var a_results: Array[Array] = _results_of(a)
	var requests: Array = []
	for index: int in range(FLOOD):
		requests.append(_net(a).request_place(FLOOR, Vector2i(3 + index % 5, 4 + index / 5), 0))
	assert_true(await _eventually(func() -> bool: return a_results.size() == FLOOD), "every request was answered (%d)" % a_results.size())
	for index: int in range(FLOOD):
		assert_eq(a_results[index][0], requests[index])
		if index < BURST:
			assert_eq(a_results[index].slice(1, 3), [true, ""], "request %d is within the burst" % index)
		else:
			assert_eq(a_results[index].slice(1), [false, NetworkService.RATE_LIMITED, ""], "request %d is over the limit" % index)
	assert_eq(_building().structure_count(), BURST, "the refused requests built nothing")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST)
	# The bucket is per peer and per intent: bob can place, and alice's door
	# requests have their own bucket.
	var bobs: Array = await _place(b, DOOR, SPAWN_TILE, 1)
	assert_eq(bobs.slice(0, 2), [true, ""], "bob is not limited by alice's flood")
	assert_eq(await _door(a, str(bobs[2]), true), [true, "", str(bobs[2])], "another intent, another bucket")
	assert_eq(await _door(a, str(bobs[2]), false), [false, NetworkService.RATE_LIMITED, ""])
	await _settle()
	assert_true(_matches_server(a) and _matches_server(b))


# ------------------------------------------------------------ 6. late joiner

func test_a_late_joiner_gets_the_structures_in_its_join_data() -> void:
	assert_true(_start(), "server started")
	var a: NetworkService = await _cluster.join_client("alice")
	assert_not_null(a)
	var wall: Array = await _place(a, WALL, SPAWN_TILE, 1)
	var door: Array = await _place(a, DOOR, SPAWN_TILE, 2)
	var floor_answer: Array = await _place(a, FLOOR, SPAWN_TILE, 0)
	var gone: Array = await _place(a, WALL, SPAWN_TILE, 3)
	assert_true(wall[0] and door[0] and floor_answer[0] and gone[0])
	assert_eq(await _door(a, str(door[2]), true), [true, "", str(door[2])])
	assert_eq(await _demolish(a, str(gone[2])), [true, "", str(gone[2])])
	# A structure made by a server rule in the same tick as the join is in the
	# join data too.
	assert_true(_building().place_structure(_world, FLOOR, Vector2i(6, 6), 0).ok)
	var b: NetworkService = await _cluster.join_client("bob")
	assert_not_null(b)
	# The mirror is complete the moment the join is.
	assert_eq(_mirror(b).structure_count(), 4, "three by alice and one by the server")
	assert_true(_matches_server(b), "the late joiner has what the server has")
	assert_true(bool(_mirror(b).get_structure(str(door[2]))["door_open"]), "with the door as it is now: open")
	assert_false(_mirror(b).has_structure(str(gone[2])), "and without what was demolished")
	assert_true(await _eventually(func() -> bool: return _matches_server(a)))
	assert_eq(_client_view(a), _client_view(b))
	# The join snapshot carries this module's fragment next to the others: the
	# trade module (P2-T16) is installed on every peer and took its own part.
	for service: NetworkService in [_cluster.server, a, b]:
		assert_not_null(service.get_module(TradeNetModule.MODULE_NAME), "the trade module is installed")
		assert_not_null(service.get_module(StructureNetModule.MODULE_NAME), "the structure module is installed")
	assert_eq((b.get_module(TradeNetModule.MODULE_NAME) as TradeNetModule).client_state.rejected_payload_count, 0, "the trade part of the join snapshot was accepted")
	# From then on it follows changes like everybody else.
	assert_eq(await _door(b, str(door[2]), false), [true, "", str(door[2])])
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b)))
	assert_eq(_mirror(b).rejected_payload_count + _mirror(a).rejected_payload_count, 0)


# ------------------------------------------------------------ 7. world cells

func test_a_released_cell_takes_its_structures_from_the_mirrors_and_a_reload_brings_them_back() -> void:
	assert_true(_start(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var near: Array = await _place(a, WALL, SPAWN_TILE, 1)
	assert_true(near[0])
	# Alice goes far away and builds there: a wall, a door she opens, a floor.
	_player(a).position = FAR_SPOT
	assert_true(await _eventually(func() -> bool: return _cells().is_loaded(FAR_CELL)))
	var far_wall: Array = await _place(a, WALL, FAR_TILE, 1)
	var far_door: Array = await _place(a, DOOR, FAR_TILE, 2)
	var far_floor: Array = await _place(a, FLOOR, FAR_TILE, 0)
	assert_true(far_wall[0] and far_door[0] and far_floor[0], "%s %s %s" % [str(far_wall), str(far_door), str(far_floor)])
	assert_eq(await _door(a, str(far_door[2]), true), [true, "", str(far_door[2])])
	assert_true(await _eventually(func() -> bool: return _mirror(b).structure_count() == 4 and _matches_server(b)), "bob sees them from afar (the interest area of this file is the whole map)")
	var far_expected: Dictionary = _client_view(b)
	far_expected.erase(str(near[2]))
	var b_removed: PackedStringArray = []
	var b_added: PackedStringArray = []
	_mirror(b).structure_removed.connect(func(structure_id: String) -> void: b_removed.append(structure_id))
	_mirror(b).structure_added.connect(func(structure_id: String) -> void: b_added.append(structure_id))

	# She comes back: the far cell is saved and released.
	_player(a).position = SPAWN
	assert_true(await _eventually(func() -> bool: return _cells().state_of(FAR_CELL) == WorldCellLifecycle.State.UNLOADED), "the far cell is released")
	assert_false(_building().has_structure(str(far_wall[2])))
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b)), "the mirrors show what the server has in memory")
	assert_eq(Array(_mirror(a).structure_ids()), [str(near[2])], "the released structures are gone from the client")
	assert_eq(Array(_mirror(b).structure_ids()), [str(near[2])])
	assert_eq(b_removed.size(), 3)
	assert_false(_world.registry.is_tombstoned(str(far_wall[2])), "released, not demolished")

	# A client that joins now gets what is in memory, nothing else.
	var c: NetworkService = await _cluster.join_client("carol")
	assert_not_null(c)
	assert_eq(Array(_mirror(c).structure_ids()), [str(near[2])])

	# Bob walks there: the cell is loaded and everybody gets its structures.
	_player(b).position = FAR_SPOT
	assert_true(await _eventually(func() -> bool: return _cells().is_loaded(FAR_CELL)), "the far cell is in memory again")
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b) and _matches_server(c)), "every client got the structures of the loaded cell")
	assert_eq(_mirror(a).structure_count(), 4)
	for structure_id: String in far_expected:
		assert_eq(_mirror(b).get_structure(structure_id), far_expected[structure_id], "back as it was: " + structure_id)
		assert_eq(_mirror(c).get_structure(structure_id), far_expected[structure_id])
	assert_true(bool(_mirror(c).get_structure(str(far_door[2]))["door_open"]), "the door is still open")
	assert_eq(b_added.size(), 3, "bob's mirror got them as additions")
	# The reloaded wall is the same structure: its placer can demolish it.
	_player(a).position = FAR_SPOT
	assert_eq(await _demolish(a, str(far_wall[2])), [true, "", str(far_wall[2])])
	assert_true(await _eventually(func() -> bool: return _matches_server(a) and _matches_server(b) and _matches_server(c)))
	for client: NetworkService in [a, b, c]:
		assert_eq(_mirror(client).rejected_payload_count, 0)
		assert_eq(_mirror(client).unknown_removal_count, 0)
	assert_eq(_building().drain_events().size(), 0, "the module drained every event")


# ------------------------------------------------------------ 8. saving

func test_structures_survive_a_server_restart() -> void:
	_save_root = "user://test_saves/structure_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	if a == null:
		fail("alice did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var save: SaveService = SaveService.new(_save_root)
	var generation: int = save.current_generation(WORLD)
	var wall: Array = await _place(a, WALL, SPAWN_TILE, 1)
	assert_true(wall[0], str(wall))
	assert_true(save.current_generation(WORLD) > generation, "an accepted placement is saved at once")
	var door: Array = await _place(a, DOOR, SPAWN_TILE, 2)
	var gone: Array = await _place(a, FLOOR, SPAWN_TILE, 0)
	assert_true(door[0] and gone[0])
	generation = save.current_generation(WORLD)
	assert_eq(await _door(a, str(door[2]), true), [true, "", str(door[2])])
	await _settle()
	assert_eq(save.current_generation(WORLD), generation, "a door change alone does not write the world (setting)")
	assert_eq(await _demolish(a, str(gone[2])), [true, "", str(gone[2])])
	# Far away, in a cell that is released before the shutdown.
	_player(a).position = FAR_SPOT
	assert_true(await _eventually(func() -> bool: return _cells().is_loaded(FAR_CELL)))
	var far_wall: Array = await _place(a, WALL, FAR_TILE, 3)
	assert_true(far_wall[0], str(far_wall))
	_player(a).position = SPAWN
	assert_true(await _eventually(func() -> bool: return _cells().state_of(FAR_CELL) == WorldCellLifecycle.State.UNLOADED))
	var before: Dictionary = _server_view()
	assert_eq(before.size(), 2)
	var next_id: int = _world.ids.get_next_sequence()

	# --- full restart (the shutdown saves): state comes only from disk ---
	await _cluster.shutdown()
	_cluster = null
	_world = null
	var persistence2: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence2.load_or_create(WORLD)
	assert_not_null(_world, "world restored from save")
	if _world == null:
		return
	assert_eq(_building().structure_count(), 0, "a server starts with no cell in memory")
	assert_eq(_world.ids.get_next_sequence(), next_id, "the ids of saved structures stay reserved")
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	if a2 == null:
		fail("alice did not rejoin")
		return
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	assert_true(await _eventually(func() -> bool: return _mirror(a2).structure_count() == 2 and _matches_server(a2)), "session 2: the mirror shows the saved structures")
	assert_eq(_server_view(), before, "the same structures, ids, places and states as before the restart")
	assert_true(_building().get_structure(str(door[2])).door_open, "the door is still open")
	assert_eq(_building().get_structure(str(wall[2])).placed_by, alice_id)
	assert_false(_building().has_structure(str(gone[2])), "the demolished floor stays gone")
	assert_true(_world.registry.is_tombstoned(str(gone[2])))
	assert_true(_building().is_edge_blocked(Vector3i(6, 5, LOW_X)), "the restored wall blocks")
	# The far structure comes back with its cell, for the client too.
	_player(a2).position = FAR_SPOT
	assert_true(await _eventually(func() -> bool: return _mirror(a2).has_structure(str(far_wall[2]))), "the far wall came back from its cell file")
	assert_true(_matches_server(a2))
	# The world goes on: the old slot is taken, a new structure gets a new id,
	# and the placer of before the restart still owns her wall.
	assert_eq(await _place(a2, DOOR, FAR_TILE, 3), [false, BuildingService.REASON_SLOT_OCCUPIED, ""])
	var fresh: Array = await _place(a2, FLOOR, FAR_TILE, 0)
	assert_true(fresh[0] and not before.has(str(fresh[2])) and str(fresh[2]) != str(gone[2]) and str(fresh[2]) != str(far_wall[2]), str(fresh))
	assert_eq(await _demolish(a2, str(far_wall[2])), [true, "", str(far_wall[2])])
	assert_eq(_mirror(a2).rejected_payload_count, 0)


# ------------------------------------------------------------ rules (no network)

func test_default_settings_rpc_table_and_request_validation() -> void:
	var settings: StructureNetSettings = StructureNetSettings.load_or_default()
	assert_true(ResourceLoader.exists(StructureNetSettings.DEFAULT_PATH))
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	var broken: StructureNetSettings = StructureNetSettings.new()
	broken.place_intent_rate_per_sec = 0.0
	broken.door_intent_burst = 0
	broken.rows_per_message = ClientStructureState.MAX_ROWS_PER_MESSAGE + 1
	broken.removals_per_message = 0
	broken.max_mirror_structures = 0
	assert_eq(broken.validate().size(), 5, "; ".join(broken.validate()))
	broken.deliver_intent_rate_per_sec = -1.0
	broken.work_intent_burst = 0
	assert_eq(broken.validate().size(), 5, "the new rates are checked by the same two rules")
	assert_eq(BuildInfo.PROTOCOL_VERSION, 20, "the structure RPCs are a protocol change (12, P3-4a); 13 since the replication scope by cell (P3-2), 14 since the construction RPCs and the longer structure rows (P3-5), 15 since the container RPCs (P3-3)")
	# Every message is on the reliable ordered channel (docs/09 §15.4).
	var module: StructureNetModule = StructureNetModule.new(settings, StructureCatalog.load_directory())
	assert_eq(str(module.name), StructureNetModule.MODULE_NAME)
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	var expected: Dictionary[String, int] = {
		"_rpc_request_place": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_request_demolish": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_request_door": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_structure_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_structure_rows": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_structures_removed": MultiplayerAPI.RPC_MODE_AUTHORITY,
		# P3-5 (docs/09 §15.5).
		"_rpc_request_deliver": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_request_work": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_request_cancel": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_work_changed": MultiplayerAPI.RPC_MODE_AUTHORITY,
	}
	assert_eq(rpc_config.size(), expected.size(), "no other RPC exists")
	for method: String in expected:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), expected[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	assert_eq(module.request_place(WALL, SPAWN_TILE, 0), StructureNetModule.NO_REQUEST, "nothing is sent while offline")
	module.free()
	assert_eq(CompositionConfig.from_defaults().validate().size(), 0)
	# Request shapes.
	assert_eq(StructureNetModule.validate_place_request(1, WALL, 5, -6, 3), "")
	assert_eq(StructureNetModule.validate_place_request(1, WALL, StructureGrid.MAX_TILE_COORD, 0, 0), "")
	assert_eq(StructureNetModule.validate_place_request(1, WALL, StructureGrid.MAX_TILE_COORD + 1, 0, 0), BuildingService.REASON_OUT_OF_BOUNDS)
	assert_eq(StructureNetModule.validate_place_request(1, "", 0, 0, 0), StructureNetModule.REASON_BAD_DEFINITION_ID)
	assert_eq(StructureNetModule.validate_place_request(-1, WALL, 0, 0, 0), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(StructureNetModule.validate_place_request(1, WALL, 0, 0, 4), BuildingService.REASON_BAD_ROTATION)
	assert_eq(StructureNetModule.validate_place_request(1, WALL, 0, null, 0), IntentValidator.REASON_BAD_TYPE)
	assert_eq(StructureNetModule.validate_demolish_request(1, "structure_000001"), "")
	assert_eq(StructureNetModule.validate_demolish_request(1, "zombie_000001"), StructureNetModule.REASON_BAD_STRUCTURE_ID)
	assert_eq(StructureNetModule.validate_door_request(1, "structure_000001", false), "")
	assert_eq(StructureNetModule.validate_door_request(1, "structure_000001", 0), IntentValidator.REASON_BAD_TYPE)
	assert_eq(StructureNetModule.validate_door_request(-1, "structure_000001", true), IntentValidator.REASON_BAD_SEQUENCE)
