extends TestCase
## P1-1: server + 2 clients over real ENet (localhost). Join handshake,
## rejection paths, reconnect identity, leave notifications.

var _cluster: NetTestCluster = null
var _settings: NetworkSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = NetworkSettings.new()
	_settings.handshake_timeout_sec = 1.0
	_settings.reject_disconnect_delay_sec = 0.1
	_settings.autosave_interval_sec = 0.0
	_cluster = NetTestCluster.new(tree, _settings)


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func _new_world() -> ServerWorld:
	var world: ServerWorld = ServerWorld.new("net_test_world", GameplaySettings.new(), ItemCatalog.load_directory())
	world.seed_new_world(DevWorldSeed.load_or_default())
	return world


func _rejection_of(client: NetworkService) -> Array[String]:
	var reasons: Array[String] = []
	client.join_rejected.connect(func(reason: String) -> void: reasons.append(reason))
	return reasons


func test_two_clients_join_and_see_each_other() -> void:
	assert_eq(_cluster.start_server(_new_world(), null), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	assert_not_null(a, "alice joined")
	var b: NetworkService = await _cluster.join_client("bob")
	assert_not_null(b, "bob joined")
	if a == null or b == null:
		return
	assert_ne(a.client_state.local_player_id, b.client_state.local_player_id)
	assert_eq(b.client_state.players.size(), 2, "bob's snapshot lists both players")
	assert_eq(b.client_state.world_items.size(), 1, "bob sees the seeded item")
	var a_sees_b: bool = await _cluster.wait_until(func() -> bool: return a.client_state.players.has(b.client_state.local_player_id))
	assert_true(a_sees_b, "alice is told about bob")
	assert_eq(_cluster.server.joined_peer_count(), 2)
	assert_false((_cluster.server.multiplayer as SceneMultiplayer).server_relay, "client-to-client relay is disabled")


func test_wrong_protocol_and_bad_types_are_rejected() -> void:
	assert_eq(_cluster.start_server(_new_world(), null), OK)
	var bad_protocol: NetworkService = _cluster.add_client("mallory", false)
	var bad_types: NetworkService = _cluster.add_client("trudy", false)
	var protocol_reasons: Array[String] = _rejection_of(bad_protocol)
	var type_reasons: Array[String] = _rejection_of(bad_types)
	await _cluster.wait_until(func() -> bool: return bad_protocol.multiplayer.get_unique_id() != 1 and bad_protocol.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and bad_types.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	bad_protocol.send_join_request(BuildInfo.PROTOCOL_VERSION + 1, "9.9.9", "mallory")
	bad_types.send_join_request("1", 5, ["not", "a", "key"])
	await _cluster.wait_until(func() -> bool: return protocol_reasons.size() > 0 and type_reasons.size() > 0)
	assert_eq(protocol_reasons, [IntentValidator.REASON_PROTOCOL_MISMATCH] as Array[String])
	assert_eq(type_reasons, [IntentValidator.REASON_BAD_TYPE] as Array[String])
	assert_eq(_cluster.server.joined_peer_count(), 0)
	var kicked: bool = await _cluster.wait_until(func() -> bool: return bad_protocol.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED)
	assert_true(kicked, "rejected peer is disconnected")


func test_duplicate_key_and_server_full_are_rejected() -> void:
	_settings.max_players = 2
	assert_eq(_cluster.start_server(_new_world(), null), OK)
	assert_not_null(await _cluster.join_client("alice"))
	var twin: NetworkService = _cluster.add_client("alice")
	var twin_reasons: Array[String] = _rejection_of(twin)
	await _cluster.wait_until(func() -> bool: return twin_reasons.size() > 0)
	assert_eq(twin_reasons, [NetworkService.REASON_KEY_IN_USE] as Array[String])
	assert_not_null(await _cluster.join_client("bob"))
	var third: NetworkService = _cluster.add_client("carol")
	var third_reasons: Array[String] = _rejection_of(third)
	await _cluster.wait_until(func() -> bool: return third_reasons.size() > 0)
	assert_eq(third_reasons, [NetworkService.REASON_SERVER_FULL] as Array[String])
	assert_eq(_cluster.server.joined_peer_count(), 2)


func test_silent_peer_times_out() -> void:
	assert_eq(_cluster.start_server(_new_world(), null), OK)
	var silent: NetworkService = _cluster.add_client("silent", false)
	var reasons: Array[String] = _rejection_of(silent)
	var rejected: bool = await _cluster.wait_until(func() -> bool: return reasons.size() > 0)
	assert_true(rejected)
	assert_eq(reasons, [NetworkService.REASON_HANDSHAKE_TIMEOUT] as Array[String])


func test_reconnect_keeps_player_identity_and_notifies_others() -> void:
	assert_eq(_cluster.start_server(_new_world(), null), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	_cluster.remove_client(a)
	var b_saw_leave: bool = await _cluster.wait_until(func() -> bool: return not b.client_state.players.has(alice_id))
	assert_true(b_saw_leave, "bob is told alice left")
	assert_false(_cluster.server.get_world().is_online(alice_id))
	var again: NetworkService = await _cluster.join_client("alice")
	assert_not_null(again)
	if again != null:
		assert_eq(again.client_state.local_player_id, alice_id, "same key -> same player")
	assert_eq(_cluster.server.get_world().known_player_count(), 2)
