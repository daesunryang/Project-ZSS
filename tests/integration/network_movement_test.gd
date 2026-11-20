extends TestCase
## P1-3: server-authoritative movement over real ENet with 2 clients.

const MOVE_FRAMES: int = 30
const STOP_FRAMES: int = 3
const POSITION_TOLERANCE_M: float = 0.05

var _cluster: NetTestCluster = null
var _settings: NetworkSettings = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = NetworkSettings.new()
	_settings.autosave_interval_sec = 0.0
	_cluster = NetTestCluster.new(tree, _settings)
	_world = ServerWorld.new("move_net_test", GameplaySettings.new(), ItemCatalog.load_directory())


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func _send_for_frames(client: NetworkService, direction: Vector2, frames: int) -> void:
	for frame: int in range(frames):
		client.send_move_intent(direction, 0.0)
		await tree.physics_frame


func test_move_intents_move_player_and_replicate_to_other_client() -> void:
	assert_eq(_cluster.start_server(_world, null), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var start: Vector3 = _world.get_player(alice_id).position
	await _send_for_frames(a, Vector2(1, 0), MOVE_FRAMES)
	# Stop: zero intents (repeated because the channel is unreliable).
	await _send_for_frames(a, Vector2.ZERO, STOP_FRAMES)
	await _cluster.wait_frames(10)
	var server_position: Vector3 = _world.get_player(alice_id).position
	assert_true(server_position.x > start.x + 0.5, "server moved alice: %s" % str(server_position))
	assert_true(is_equal_approx(server_position.z, start.z), "no sideways drift")
	# Max distance the server can grant: speed * (frames sent + timeout window).
	var max_distance: float = _world.gameplay.move_speed_mps * (float(MOVE_FRAMES) / Engine.physics_ticks_per_second + _settings.move_input_timeout_sec)
	assert_true(server_position.distance_to(start) <= max_distance + POSITION_TOLERANCE_M, "speed is server-limited")
	var replicated: bool = await _cluster.wait_until(_clients_converged.bind([a, b], alice_id))
	assert_true(replicated, "both clients converge on the server position")
	var settled: Vector3 = _world.get_player(alice_id).position
	await _cluster.wait_frames(40)
	assert_eq(_world.get_player(alice_id).position, settled, "player stops when intents stop")


func _clients_converged(clients: Array, player_id: String) -> bool:
	var server_position: Vector3 = _world.get_player(player_id).position
	for client: NetworkService in clients:
		if client.client_state.position_of(player_id).distance_to(server_position) >= POSITION_TOLERANCE_M:
			return false
	return true


func test_manipulated_move_intents_are_rejected() -> void:
	assert_eq(_cluster.start_server(_world, null), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	if a == null:
		fail("client did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var start: Vector3 = _world.get_player(alice_id).position
	a.send_raw_move_intent(1, Vector2(50, 0), 0.0)       # speed hack
	a.send_raw_move_intent(2, Vector2(NAN, 0), 0.0)      # NaN
	a.send_raw_move_intent(3, Vector3(100, 0, 0), 0.0)   # wrong type (a position)
	a.send_raw_move_intent("4", Vector2(1, 0), 0.0)      # wrong sequence type
	a.send_raw_move_intent(5, Vector2(1, 0), 1e9)        # garbage yaw
	a.send_raw_move_intent(6, Vector2(1, 0), 0.0, "yes") # wrong sprint flag type
	var counted: bool = await _cluster.wait_until(func() -> bool: return _cluster.server.rejected_intent_count() >= 6)
	assert_true(counted, "all malformed intents were seen and rejected")
	assert_eq(_cluster.server.rejected_intent_count(IntentValidator.REASON_BAD_DIRECTION), 2)
	assert_eq(_cluster.server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE), 3)
	assert_eq(_cluster.server.rejected_intent_count(IntentValidator.REASON_BAD_YAW), 1)
	await _cluster.wait_frames(10)
	assert_eq(_world.get_player(alice_id).position, start, "rejected intents never move the player")


func test_intent_flood_is_rate_limited() -> void:
	_settings.move_intent_rate_per_sec = 10.0
	_settings.move_intent_burst = 5
	assert_eq(_cluster.start_server(_world, null), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	if a == null:
		fail("client did not join")
		return
	for index: int in range(50):
		a.send_move_intent(Vector2(1, 0), 0.0)
	var limited: bool = await _cluster.wait_until(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED) >= 40)
	assert_true(limited, "flood beyond burst is rejected (%d)" % _cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED))
