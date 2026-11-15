extends TestCase
## P2-0: NetModule seam over real ENet (server + 2 clients): lifecycle hooks,
## join fragment, validated client intent, broadcast, registration rules.

var _cluster: NetTestCluster = null


func before_each() -> void:
	GameLogger.set_capture(true)
	var settings: NetworkSettings = NetworkSettings.new()
	settings.autosave_interval_sec = 0.0
	_cluster = NetTestCluster.new(tree, settings)
	_cluster.extra_module_factories.append(func() -> NetModule: return TestEchoModule.new())


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func _echo(service: NetworkService) -> TestEchoModule:
	return service.get_module(TestEchoModule.MODULE_NAME) as TestEchoModule


func test_module_hooks_fragment_and_rpcs() -> void:
	var world: ServerWorld = ServerComposition.create_world("module_seam_world", CompositionConfig.from_defaults())
	assert_eq(_cluster.start_server(world, null), OK)
	var server_echo: TestEchoModule = _echo(_cluster.server)
	assert_true(server_echo.server_started)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	assert_eq(_echo(a).join_fragment, {"greeting": "hello " + alice_id}, "join fragment delivered")
	assert_eq(server_echo.joined, PackedStringArray([alice_id, b.client_state.local_player_id]))
	assert_true(server_echo.physics_ticks > 0, "server_physics hook runs")
	var alice_peer: int = _cluster.server.peer_of_player(alice_id)
	assert_true(alice_peer != 0 and _cluster.server.joined_peers().has(alice_peer))
	assert_eq(_cluster.server.player_of_peer(alice_peer), alice_id)

	_echo(a).send_echo("hi")
	_echo(a).send_echo(12345)  # wrong type -> rejected through the module
	var delivered: bool = await _cluster.wait_until(func() -> bool: return _echo(b).broadcasts.size() == 1 and _echo(a).broadcasts.size() == 1)
	assert_true(delivered, "broadcast reached both clients")
	assert_eq(_echo(b).broadcasts, PackedStringArray([alice_id + ":hi"]))
	assert_eq(server_echo.received.size(), 1, "sender_player_id resolved for the valid intent only")
	var rejected: bool = await _cluster.wait_until(func() -> bool: return _cluster.server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE) == 1)
	assert_true(rejected)

	_cluster.remove_client(a)
	var left: bool = await _cluster.wait_until(func() -> bool: return server_echo.left.has(alice_id))
	assert_true(left, "on_player_left hook runs")


func test_registration_rules() -> void:
	var service: NetworkService = NetworkService.new()
	tree.root.add_child(service)
	assert_eq(service.register_module(TestEchoModule.new()), OK)
	var duplicate: TestEchoModule = TestEchoModule.new()
	assert_eq(service.register_module(duplicate), ERR_ALREADY_EXISTS)
	duplicate.free()
	assert_not_null(service.get_module(TestEchoModule.MODULE_NAME))
	assert_null(service.get_module("Missing"))
	service.free()
