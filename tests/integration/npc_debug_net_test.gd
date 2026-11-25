extends TestCase
## P4-8: one authorized peer may subscribe to one NPC at 2 Hz. Disabled,
## unauthorized and out-of-interest requests never invoke the private query.

const WORLD: String = "npc_debug_net_world"
const DEFINITION_ID: String = "npc_debug_net_subject"
const SPAWN: Vector3 = Vector3(5.0, 0.0, 5.0)
const MAX_WAIT_TICKS: int = 180

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.gameplay.world_half_extent_m = 50.0
	_config.gameplay.player_spawn_position = SPAWN
	_config.clock = WorldClockSettings.new()
	_config.survival = SurvivalSettings.new()
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.world_cells = WorldCellSettings.new()
	_config.world_cells.cell_size_m = 10.0
	_config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	_config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	_config.world_cells.active_radius_cells = 0
	_config.world_cells.preload_radius_cells = 1
	_config.world_cells.refresh_period_sec = 0.0
	_config.world_cells.max_preload_loads_per_refresh = 1000
	_config.interest = InterestSettings.new()
	_config.interest.interest_radius_cells = 0
	_config.interest.keep_margin_cells = 0
	_config.npc = NpcSettings.new()
	_config.npc_definitions = NpcCatalog.new()
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = DEFINITION_ID
	definition.display_name = "구독 대상"
	definition.appearance = _config.appearance.default_selection()
	_config.npc_definitions.add(definition)
	_config.npc_debug = NpcDebugSettings.new()
	_cluster = NetTestCluster.new(tree, network_settings, _config)


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func _start() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	(_world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	if _world.seed_new_world(DevWorldSeed.new()) != OK:
		return false
	return _cluster.start_server(_world, null) == OK


func _module(service: NetworkService) -> NpcDebugNetModule:
	return service.get_module(NpcDebugNetModule.MODULE_NAME) as NpcDebugNetModule


func _spawn(position: Vector3 = SPAWN + Vector3(1.0, 0.0, 0.0)) -> String:
	var npcs: NpcService = _world.get_system(NpcService.SYSTEM_ID) as NpcService
	var spawned: ActionResult = npcs.spawn_npc(_world, DEFINITION_ID, position)
	if not spawned.ok:
		fail("test setup: NPC spawn refused: " + spawned.reason)
		return ""
	return str(spawned.event.get(NpcService.KEY_NPC_ID, ""))


func test_disabled_server_rejects_subscription_without_invoking_query() -> void:
	_config.npc_debug.enabled = false
	assert_true(_start())
	var client: NetworkService = await _cluster.join_client("alice")
	assert_not_null(client)
	var npc_id: String = _spawn()
	assert_true(_module(client).request_subscribe(npc_id))
	await _cluster.wait_ticks(45)
	assert_eq(_module(_cluster.server).query_inspect_count(), 0, "disabled means zero query cost")
	assert_false(_module(client).client_state.server_enabled)
	assert_eq(_module(client).client_state.reason, NpcDebugNetModule.REASON_SERVER_DISABLED)
	assert_eq(_module(_cluster.server).subscription_count(), 0)


func test_only_authorized_subscriber_receives_two_hz_private_snapshot_then_unsubscribe_and_disconnect_clean_up() -> void:
	_config.npc_debug.enabled = true
	_config.npc_debug.update_rate_hz = 2.0
	_config.npc_debug.allowed_player_keys = PackedStringArray(["alice"])
	assert_true(_start())
	var alice: NetworkService = await _cluster.join_client("alice")
	var bob: NetworkService = await _cluster.join_client("bob")
	assert_true(alice != null and bob != null)
	var npc_id: String = _spawn()
	assert_true(_module(alice).request_subscribe(npc_id))
	assert_true(_module(bob).request_subscribe(npc_id), "request reaches the server and is refused there")
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _module(alice).client_state.received_snapshot_count >= 2, MAX_WAIT_TICKS))
	assert_eq(_module(alice).client_state.snapshot.get("npc_id", ""), npc_id)
	assert_true(_module(alice).client_state.snapshot.get("found", false))
	assert_eq(_module(bob).client_state.received_snapshot_count, 0, "private snapshot never reaches another peer")
	assert_eq(_module(bob).client_state.reason, NpcDebugNetModule.REASON_NOT_ALLOWED)
	assert_eq(_module(_cluster.server).subscription_count(), 1)
	var count_after_two: int = _module(_cluster.server).query_inspect_count()
	assert_true(count_after_two >= 2 and count_after_two <= 3, "2 Hz sampling over the simulated wait window")

	assert_true(_module(alice).request_unsubscribe())
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _module(_cluster.server).subscription_count() == 0, 60))
	var stopped_count: int = _module(_cluster.server).query_inspect_count()
	await _cluster.wait_ticks(45)
	assert_eq(_module(_cluster.server).query_inspect_count(), stopped_count, "unsubscribe stops reads")

	assert_true(_module(alice).request_subscribe(npc_id))
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _module(_cluster.server).subscription_count() == 1, 60))
	_cluster.remove_client(alice)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _module(_cluster.server).subscription_count() == 0, 60), "disconnect removes subscription")


func test_interest_loss_reports_missing_without_querying_private_state() -> void:
	_config.npc_debug.enabled = true
	_config.npc_debug.allow_all_player_keys = true
	assert_true(_start())
	var client: NetworkService = await _cluster.join_client("alice")
	assert_not_null(client)
	var npc_id: String = _spawn(Vector3(15.0, 0.0, 5.0))
	var before: int = _module(_cluster.server).query_inspect_count()
	assert_true(_module(client).request_subscribe(npc_id))
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _module(client).client_state.received_snapshot_count > 0, MAX_WAIT_TICKS))
	assert_false(_module(client).client_state.snapshot.get("found", true))
	assert_eq(_module(_cluster.server).query_inspect_count(), before, "out-of-interest NPC is not queried")

	var received: int = _module(client).client_state.received_snapshot_count
	assert_true(_module(client).request_subscribe("npc_999999"))
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _module(client).client_state.received_snapshot_count > received, MAX_WAIT_TICKS))
	assert_false(_module(client).client_state.snapshot.get("found", true), "NPC outside server memory is explicit")
	assert_eq(_module(_cluster.server).query_inspect_count(), before, "out-of-memory NPC is not queried")


func test_rpc_channels_are_reliable_channel_zero_and_protocol_is_seventeen() -> void:
	assert_eq(BuildInfo.PROTOCOL_VERSION, 21)
	var config: Dictionary = (NpcDebugNetModule as Script).get_rpc_config()
	assert_eq(config.size(), 4)
	for method: StringName in [&"_rpc_request_subscribe", &"_rpc_request_unsubscribe"]:
		assert_eq(config[method]["rpc_mode"], MultiplayerAPI.RPC_MODE_ANY_PEER)
		assert_eq(config[method]["transfer_mode"], MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		assert_eq(config[method]["channel"], NetworkSettings.CHANNEL_RELIABLE)
	for method: StringName in [&"_rpc_debug_status", &"_rpc_debug_snapshot"]:
		assert_eq(config[method]["rpc_mode"], MultiplayerAPI.RPC_MODE_AUTHORITY)
		assert_eq(config[method]["transfer_mode"], MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		assert_eq(config[method]["channel"], NetworkSettings.CHANNEL_RELIABLE)
