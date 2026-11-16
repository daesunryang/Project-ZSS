extends TestCase
## Structures follow the replication scope by cell (docs/09 §15.2, §15.5;
## resolves docs/15 P3-056): a client is told only about the structures, and
## the players working on them, in the cells around its own player. Real
## ENet, one server and three clients in one process, on the 500 m x 500 m
## test map with its shipped cell and interest settings (50 m cells; a peer
## is told about the cells within 2 cells of its player and keeps them up to
## 3 cells away). Players are moved through the server, never by client
## input. No cell is ever released here (the world has no cell store), so
## what a client sees depends on interest only; cells leaving the server's
## memory are in structure_net_test.gd and construction_net_test.gd.

const WORLD: String = "structure_interest_world"
const NEVER: float = 1.0e9
const WAIT_MSEC: int = 10000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 30
const GENEROUS_RATE: float = 120.0
const GENEROUS_BURST: int = 120
const PLANK: String = ConstructionTestKit.PLANK
const NAIL: String = ConstructionTestKit.NAIL
const WALL: String = ConstructionTestKit.WALL
const FLOOR: String = ConstructionTestKit.FLOOR
const DOOR: String = ConstructionTestKit.DOOR
const FREE_WALL: String = ConstructionTestKit.FREE_WALL
const ENDLESS_WALL: String = ConstructionTestKit.ENDLESS_WALL
const EAST: int = 1
const WEST: int = 3
const NORTH: int = 0
## Work of the test wall here, seconds of one worker (real time).
const WALL_WORK_SEC: float = 1.0
## Three places far apart: eight cells between any two of them.
const AT_A: Vector3 = Vector3(-199.5, 0.0, -199.5)
const BESIDE_A: Vector3 = Vector3(-199.5, 0.0, -198.5)
const TILE_A: Vector2i = Vector2i(-200, -200)
const AT_B: Vector3 = Vector3(200.0, 0.0, -200.0)
const AT_C: Vector3 = Vector3(200.0, 0.0, 200.0)
const MISSING_ID: String = "structure_999999"

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	network_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	network_settings.pickup_intent_burst = GENEROUS_BURST
	# from_defaults() hands out shared cached resources: replace, never edit.
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.catalog = ConstructionTestKit.items()
	_config.structures = ConstructionTestKit.structures()
	_config.structures.get_definition(WALL).build_work_sec = WALL_WORK_SEC
	_config.building = BuildingSettings.new()
	_config.structure_net = StructureNetSettings.new()
	_config.structure_net.place_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.place_intent_burst = GENEROUS_BURST
	_config.structure_net.demolish_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.demolish_intent_burst = GENEROUS_BURST
	_config.structure_net.door_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.door_intent_burst = GENEROUS_BURST
	_config.structure_net.deliver_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.deliver_intent_burst = GENEROUS_BURST
	_config.structure_net.work_intent_rate_per_sec = GENEROUS_RATE
	_config.structure_net.work_intent_burst = GENEROUS_BURST
	# The shipped map, cells and interest area; cells are looked at every tick.
	_config.world_cells = WorldCellSettings.new()
	_config.world_cells.refresh_period_sec = 0.0
	_config.world_cells.preload_lookahead_sec = 0.0
	_config.interest = InterestSettings.new()
	_cluster = NetTestCluster.new(tree, network_settings, _config)
	_world = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _start() -> bool:
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


func _id(client: NetworkService) -> String:
	return client.client_state.local_player_id


func _peer(client: NetworkService) -> int:
	return _cluster.server.peer_of_player(_id(client))


## Puts a client's player somewhere on the server and waits until the client
## itself has seen that position (so the server looked at it since).
func _move(client: NetworkService, position: Vector3) -> void:
	var player_id: String = _id(client)
	_world.get_player(player_id).position = position
	await _wait(func() -> bool: return client.client_state.position_of(player_id).distance_to(position) < 0.01)
	await _settle()


func _building() -> BuildingService:
	return _world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _net(service: NetworkService) -> StructureNetModule:
	return service.get_module(StructureNetModule.MODULE_NAME) as StructureNetModule


func _mirror(service: NetworkService) -> ClientStructureState:
	return _net(service).client_state


## Sends one request (`send` returns its id) and waits for its answer:
## [ok, reason, structure_id].
func _ask(client: NetworkService, send: Callable) -> Array:
	var results: Array[Array] = []
	_net(client).structure_result.connect(func(request_id: int, ok: bool, reason: String, structure_id: String) -> void: results.append([request_id, ok, reason, structure_id]))
	var request_id: int = send.call()
	if not await _wait(func() -> bool: return results.size() >= 1):
		return [false, "no_answer", ""]
	return results[0].slice(1) if results[0][0] == request_id else [false, "wrong_request_id", ""]


func _place(client: NetworkService, definition_id: String, rotation: int, tile: Vector2i = TILE_A) -> String:
	var answer: Array = await _ask(client, func() -> int: return _net(client).request_place(definition_id, tile, rotation))
	if not answer[0]:
		fail("test setup: %s was not placed: %s" % [definition_id, str(answer)])
	return str(answer[2])


func _demolish(client: NetworkService, structure_id: String) -> Array:
	return await _ask(client, func() -> int: return _net(client).request_demolish(structure_id))


func _door(client: NetworkService, structure_id: String, open: bool) -> Array:
	return await _ask(client, func() -> int: return _net(client).request_door(structure_id, open))


func _deliver(client: NetworkService, structure_id: String) -> Array:
	return await _ask(client, func() -> int: return _net(client).request_deliver(structure_id))


func _work(client: NetworkService, structure_id: String, working: bool) -> Array:
	return await _ask(client, func() -> int: return _net(client).request_work(structure_id, working))


func _cancel(client: NetworkService, structure_id: String) -> Array:
	return await _ask(client, func() -> int: return _net(client).request_cancel(structure_id))


## What the client's mirror holds: {structure_id: entry}. The progress of
## `moving_id` is left out: a structure somebody is working on right now
## moves on every tick on the server and reaches a mirror only in steps
## (BuildingSettings.progress_event_step), so two views of it differ by when
## they were taken.
func _view(client: NetworkService, moving_id: String = "") -> Dictionary:
	var view: Dictionary = {}
	for structure_id: String in _mirror(client).structure_ids():
		view[structure_id] = _mirror(client).get_structure(structure_id).duplicate(true)
	return _without_progress(view, moving_id)


func _without_progress(view: Dictionary, moving_id: String) -> Dictionary:
	if view.has(moving_id):
		(view[moving_id] as Dictionary).erase("progress")
	return view


## What the server has in the cells this client is told about, as its mirror
## would hold it.
func _server_view_for(client: NetworkService) -> Dictionary:
	var view: Dictionary = {}
	for row: Dictionary in _building().rows():
		var structure_id: String = row["structure_id"]
		if not _cluster.server.is_cell_of_interest(_peer(client), _building().get_structure(structure_id).cell_id):
			continue
		view[structure_id] = {
			"definition_id": row["definition_id"], "tile": Vector2i(int(row["x"]), int(row["z"])), "rotation": row["rotation"], "state": row["state"],
			"door_open": row["door_open"], "health_fraction": row["health_fraction"], "progress": row["progress"], "delivered": row["delivered"], "required": row["required"],
		}
	return view


## True when the client's mirror shows exactly the structures of its cells
## and exactly the players working on them (see _view for `moving_id`).
func _matches_server(client: NetworkService, moving_id: String = "") -> bool:
	var expected: Dictionary = _server_view_for(client)
	if _view(client, moving_id) != _without_progress(expected.duplicate(true), moving_id):
		return false
	var working: Dictionary = {}
	for row: Array in _building().worker_rows():
		if expected.has(row[1]):
			working[row[0]] = row[1]
	var mirrored: Dictionary = {}
	for player_id: String in _mirror(client).workers:
		mirrored[player_id] = _mirror(client).workers[player_id]
	return mirrored == working


func _clean(clients: Array) -> void:
	for client: NetworkService in clients:
		assert_eq(_mirror(client).rejected_payload_count, 0, "no structure payload was refused")
		assert_eq(_mirror(client).unknown_removal_count, 0, "no removal of a structure the mirror did not have")
		assert_eq(_mirror(client).unknown_work_stop_count, 0, "no stop of a worker the mirror did not have")
		assert_eq(_net(client).rejected_payload_count, 0)
	assert_eq(_net(_cluster.server).unsendable_row_count, 0)


# ------------------------------------------------------------ 1. near and far

func test_structures_and_their_workers_are_mirrored_only_around_them_and_follow_a_peer_that_walks_in_and_out() -> void:
	assert_true(_start())
	var planks: String = _world.inventory.spawn_world_item(PLANK, 3, _world.cell_id_at(AT_A), AT_A)
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	var c: NetworkService = await _join("carol")
	if a == null or b == null or c == null:
		return
	await _move(a, AT_A)
	await _move(b, BESIDE_A)
	await _move(c, AT_B)
	var alice_id: String = _id(a)
	var c_added: PackedStringArray = []
	var c_removed: PackedStringArray = []
	var c_work: Array[Array] = []
	_mirror(c).structure_added.connect(func(structure_id: String) -> void: c_added.append(structure_id))
	_mirror(c).structure_removed.connect(func(structure_id: String) -> void: c_removed.append(structure_id))
	_mirror(c).work_changed.connect(func(player_id: String, structure_id: String, working: bool, reason: String) -> void: c_work.append([player_id, structure_id, working, reason]))
	var carol_messages: int = _net(c).received_message_count

	# Alice builds next to bob: a wall with half of its materials, worked on
	# until they ran out; a wall she keeps working on; a door she opens.
	a.request_pickup(planks)
	assert_true(await _wait(func() -> bool: return a.client_state.has_inventory_item(planks)), "alice picked the planks up")
	var wall_id: String = await _place(a, WALL, EAST)
	assert_eq(await _deliver(a, wall_id), [true, "", wall_id])
	assert_eq(await _work(a, wall_id, true), [true, "", wall_id])
	assert_true(await _wait(func() -> bool: return _building().work_of(alice_id).is_empty()), "the materials ran out")
	var endless_id: String = await _place(a, ENDLESS_WALL, WEST)
	assert_eq(await _work(a, endless_id, true), [true, "", endless_id])
	var door_id: String = await _place(a, DOOR, NORTH)
	assert_true(_building().complete_structure(_world, door_id).ok)
	assert_true(await _wait(func() -> bool: return _mirror(a).has_structure(door_id) and _mirror(a).get_structure(door_id)["state"] == "completed"))
	assert_eq(await _door(a, door_id, true), [true, "", door_id])
	assert_true(await _wait(func() -> bool: return _mirror(a).structure_count() == 3 and _matches_server(a, endless_id) and _matches_server(b, endless_id)), "alice and bob, standing there, see the three structures")
	assert_eq(_view(a), _view(b), "two clients standing together see the same, to the last progress step")
	assert_eq(_mirror(b).work_of(alice_id), endless_id, "bob sees alice work")
	assert_eq(_mirror(a).workers, _mirror(b).workers)
	# Carol, eight cells away, was told nothing at all.
	await _settle()
	assert_false(_cluster.server.is_cell_of_interest(_peer(c), _building().get_structure(wall_id).cell_id))
	assert_eq(_mirror(c).structure_count(), 0, "carol's mirror holds no structure of a cell she does not see")
	assert_eq(_mirror(c).workers.size(), 0)
	assert_eq(_net(c).received_message_count, carol_messages, "no row, removal or work change reached her")
	assert_true(_matches_server(c))

	# She walks there: she gains the cell with everything in it, as it is.
	await _move(c, BESIDE_A + Vector3(1.0, 0.0, 0.0))
	assert_true(await _wait(func() -> bool: return _mirror(c).structure_count() == 3 and _matches_server(c, endless_id)), "carol sees the structures of the cells she walked into")
	var wall: Dictionary = _mirror(c).get_structure(wall_id)
	assert_eq(wall["state"], "constructing", "the half built wall arrives half built")
	assert_eq(wall["progress"], 0.5)
	assert_eq(wall["delivered"], {PLANK: 3})
	assert_eq(wall["required"], {PLANK: 4, NAIL: 2})
	assert_true(bool(_mirror(c).get_structure(door_id)["door_open"]), "the door arrives open")
	assert_eq(_mirror(c).work_of(alice_id), endless_id, "and she sees who is working there")
	assert_eq(c_work, [[alice_id, endless_id, true, ""]])
	var added: Array = Array(c_added)
	added.sort()
	var expected_ids: Array = [wall_id, endless_id, door_id]
	expected_ids.sort()
	assert_eq(added, expected_ids, "each appeared once")
	assert_eq(c_removed.size(), 0)
	assert_eq(_view(c, endless_id), _view(a, endless_id), "three clients standing together agree")
	assert_true(float(_mirror(c).get_structure(endless_id)["progress"]) >= float(_mirror(a).get_structure(endless_id)["progress"]), "the wall in progress arrived with the progress it has now, not an old one")
	# From now on she follows changes like the others.
	assert_eq(await _door(a, door_id, false), [true, "", door_id])
	assert_true(await _wait(func() -> bool: return not bool(_mirror(c).get_structure(door_id)["door_open"])), "carol sees alice close the door")

	# She walks away: the structures leave her mirror; they are still there.
	await _move(c, AT_C)
	assert_true(await _wait(func() -> bool: return _mirror(c).structure_count() == 0), "carol's mirror lost the structures of the cells she left")
	assert_eq(c_removed.size(), 3)
	assert_eq(_mirror(c).workers.size(), 0, "and their workers")
	assert_eq(_building().structure_count(), 3, "nothing was removed from the world")
	assert_false(_world.registry.is_tombstoned(wall_id))
	assert_true(_matches_server(c))
	carol_messages = _net(c).received_message_count
	# What happens there now does not reach her any more.
	assert_eq(await _work(a, endless_id, false), [true, "", endless_id])
	assert_eq(await _cancel(a, wall_id), [true, "", wall_id])
	assert_true(await _wait(func() -> bool: return not _mirror(b).has_structure(wall_id) and _mirror(b).workers.is_empty()), "bob sees alice stop and the wall go")
	assert_true(_matches_server(a) and _matches_server(b))
	await _settle()
	assert_eq(_net(c).received_message_count, carol_messages, "carol hears nothing of it")
	assert_eq(_mirror(c).structure_count(), 0)
	_clean([a, b, c])


# ------------------------------------------------------------ 2. late joiner

func test_the_join_data_of_a_late_joiner_holds_only_the_structures_around_its_player() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	if a == null:
		return
	# A floor at the spawn point (a server rule), then alice goes far away,
	# builds a wall there and keeps working on it.
	var floor_placed: ActionResult = _building().place_structure(_world, FLOOR, Vector2i(0, 0), 0)
	assert_true(floor_placed.ok, floor_placed.reason)
	var floor_id: String = str(floor_placed.event["structure_id"])
	assert_true(_building().complete_structure(_world, floor_id).ok)
	await _move(a, AT_A)
	var endless_id: String = await _place(a, ENDLESS_WALL, EAST)
	assert_eq(await _work(a, endless_id, true), [true, "", endless_id])
	await _settle()
	assert_eq(_building().structure_count(), 2)
	# Watched from before the join: the most the mirror ever holds.
	var d: NetworkService = _cluster.add_client("dave", false)
	var most: Array[int] = [0, 0]
	_mirror(d).changed.connect(func() -> void:
		most[0] = maxi(most[0], _mirror(d).structure_count())
		most[1] = maxi(most[1], _mirror(d).workers.size()))
	await _settle()
	d.send_join_request(BuildInfo.PROTOCOL_VERSION, BuildInfo.game_version(), "dave")
	assert_true(await _wait(func() -> bool: return not _id(d).is_empty()), "dave joined")
	# The mirror is complete the moment the join is: the floor, nothing else.
	assert_eq(_mirror(d).structure_ids(), PackedStringArray([floor_id]), "the join data holds the structures around the spawn point only")
	assert_eq(_mirror(d).get_structure(floor_id)["state"], "completed")
	assert_false(_mirror(d).has_structure(endless_id), "not the wall eight cells away")
	assert_eq(_mirror(d).workers.size(), 0, "nor who works on it")
	await _settle()
	assert_eq(most, [1, 0] as Array[int], "his mirror never held more")
	assert_true(_matches_server(d))
	assert_true(_matches_server(a, endless_id), "alice, far away, lost the floor and has her wall")
	assert_eq(_mirror(a).structure_ids(), PackedStringArray([endless_id]))
	_clean([a, d])


# ------------------------------------------------------------ 3. forged requests

func test_requests_that_name_a_structure_outside_the_peers_cells_reveal_nothing() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	var c: NetworkService = await _join("carol")
	if a == null or c == null:
		return
	await _move(a, AT_A)
	await _move(c, AT_B)
	var wall_id: String = await _place(a, WALL, EAST)
	var done_id: String = await _place(a, FREE_WALL, WEST)
	var door_id: String = await _place(a, DOOR, NORTH)
	assert_true(_building().complete_structure(_world, done_id).ok)
	assert_true(_building().complete_structure(_world, door_id).ok)
	assert_true(await _wait(func() -> bool: return _matches_server(a) and _mirror(a).structure_count() == 3))
	await _settle()
	var before: Array[Dictionary] = _building().rows()
	assert_eq(_mirror(c).structure_count(), 0, "carol was told about none of them")
	# Carol names them anyway (ids are easy to guess). Every answer is the
	# one she gets for an id that does not exist.
	var answers: Dictionary = {}
	for structure_id: String in [MISSING_ID, wall_id, done_id, door_id]:
		answers[structure_id] = [
			await _demolish(c, structure_id), await _door(c, structure_id, true), await _deliver(c, structure_id),
			await _work(c, structure_id, true), await _work(c, structure_id, false), await _cancel(c, structure_id),
		]
	var unknown: Array = [false, BuildingService.REASON_UNKNOWN_STRUCTURE, ""]
	assert_eq(answers[MISSING_ID], [unknown, unknown, unknown, unknown, [false, BuildingService.REASON_NOT_WORKING, ""], unknown], "an id nobody has")
	for structure_id: String in [wall_id, done_id, door_id]:
		assert_eq(answers[structure_id], answers[MISSING_ID], "a structure outside her cells is answered like an id that does not exist: %s" % structure_id)
	assert_eq(_net(_cluster.server).hidden_structure_request_count, 15, "five requests for each of the three structures (a stop request reveals nothing and is not hidden)")
	# Her own state is still told to her, the same for both kinds of id.
	var survival: SurvivalService = _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	assert_true(survival.start_rest(_id(c)).ok)
	assert_eq(await _cancel(c, wall_id), [false, SurvivalService.REASON_PLAYER_RESTING, ""])
	assert_eq(await _cancel(c, MISSING_ID), [false, SurvivalService.REASON_PLAYER_RESTING, ""])
	assert_true(survival.stop_rest(_id(c)).ok)
	# Nothing happened to the structures.
	await _settle()
	assert_eq(_building().rows(), before, "the server's structures are untouched")
	assert_eq(_building().worker_count(), 0)
	assert_eq(_mirror(c).structure_count(), 0)

	# She walks there: now they are hers to see, and the answers are the real ones.
	await _move(c, BESIDE_A)
	assert_true(await _wait(func() -> bool: return _mirror(c).structure_count() == 3 and _matches_server(c)))
	assert_eq(await _cancel(c, wall_id), [false, BuildingService.REASON_NOT_OWNER, ""])
	assert_eq(await _demolish(c, done_id), [false, BuildingService.REASON_NOT_OWNER, ""])
	assert_eq(await _work(c, wall_id, true), [false, BuildingService.REASON_MATERIALS_MISSING, ""])
	assert_eq(await _door(c, door_id, true), [true, "", door_id], "anybody standing there may open the door")
	assert_true(await _wait(func() -> bool: return bool(_mirror(a).get_structure(door_id)["door_open"])), "alice sees it open")
	assert_eq(_net(_cluster.server).hidden_structure_request_count, 16, "only the request she made while resting was hidden since")
	_clean([a, c])


# ------------------------------------------------------------ 4. no character yet

func test_a_joined_player_without_a_character_is_told_about_no_structure_until_it_enters_the_world() -> void:
	_config.require_character_creation = true
	assert_true(_start())
	var b: NetworkService = await _join("bob")
	if b == null:
		return
	var bob_answers: Array[bool] = []
	var bob_module: CharacterNetModule = b.get_module(CharacterNetModule.MODULE_NAME) as CharacterNetModule
	bob_module.create_result.connect(func(_request_id: int, ok: bool, _reason: String) -> void: bob_answers.append(ok))
	bob_module.request_create_character("Bob", {})
	assert_true(await _wait(func() -> bool: return bob_answers.size() == 1 and bob_answers[0] and _world.is_online(_id(b))), "bob has a character")
	var placed: ActionResult = _building().place_structure(_world, FLOOR, Vector2i(0, 0), 0)
	assert_true(placed.ok, placed.reason)
	var floor_id: String = str(placed.event["structure_id"])
	assert_true(await _wait(func() -> bool: return _mirror(b).has_structure(floor_id)), "bob, in the world, sees the blueprint")
	# Alice joins and has no character yet.
	var a: NetworkService = _cluster.add_client("alice", false)
	var most: Array[int] = [0]
	_mirror(a).changed.connect(func() -> void: most[0] = maxi(most[0], _mirror(a).structure_count()))
	await _settle()
	a.send_join_request(BuildInfo.PROTOCOL_VERSION, BuildInfo.game_version(), "alice")
	assert_true(await _wait(func() -> bool: return not _id(a).is_empty()), "alice joined")
	await _settle()
	assert_false(_world.is_online(_id(a)), "alice is connected but not in the world")
	assert_eq(_mirror(a).structure_count(), 0, "no character, no cells: no structure")
	assert_eq(most, [0] as Array[int], "not even in the join data")
	# A change while she waits does not reach her either.
	assert_true(_building().complete_structure(_world, floor_id).ok)
	assert_true(await _wait(func() -> bool: return _mirror(b).get_structure(floor_id)["state"] == "completed"))
	await _settle()
	assert_eq(_net(a).received_message_count, 0)
	# She creates her character and enters the world at the spawn point.
	var answers: Array[bool] = []
	var character_module: CharacterNetModule = a.get_module(CharacterNetModule.MODULE_NAME) as CharacterNetModule
	character_module.create_result.connect(func(_request_id: int, ok: bool, _reason: String) -> void: answers.append(ok))
	assert_ne(character_module.request_create_character("Alice", {}), CharacterNetModule.NO_REQUEST)
	assert_true(await _wait(func() -> bool: return answers.size() == 1 and answers[0]), "the character was created")
	assert_true(await _wait(func() -> bool: return _mirror(a).structure_ids() == PackedStringArray([floor_id])), "now she is told what stands around the spawn point")
	assert_eq(_mirror(a).get_structure(floor_id), _mirror(b).get_structure(floor_id))
	_clean([a, b])
