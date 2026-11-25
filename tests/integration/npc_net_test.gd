extends TestCase
## P4-7: server-authoritative NPC replication over real ENet.

const WORLD: String = "npc_net_world"
const SPAWN: Vector3 = Vector3(5.0, 0.0, 5.0)
const MOVED: Vector3 = Vector3(7.0, 0.0, 6.0)
const OUTSIDE_INTEREST: Vector3 = Vector3(15.0, 0.0, 5.0)
const DEFINITION_ID: String = "npc_net_private_definition"
const PRIVATE_SENTINEL: String = "npc_component_secret_must_not_cross_wire"
const MAX_WAIT_TICKS: int = 180


class SecretComponent:
	extends NpcComponent

	func component_id() -> String:
		return "npc_net_private_probe"

	func to_document() -> Dictionary:
		return {
			"hunger": 0.987654,
			"emotion": "private_fear",
			"memory": PRIVATE_SENTINEL,
			"relationship": {"player_000001": -0.75},
			"goal": "private_goal",
		}


var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _labels: Dictionary[String, String] = {}


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
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.world_cells = WorldCellSettings.new()
	_config.world_cells.cell_size_m = 10.0
	_config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	_config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	_config.world_cells.active_radius_cells = 0
	_config.world_cells.preload_radius_cells = 1
	_config.world_cells.preload_lookahead_sec = 0.0
	_config.world_cells.refresh_period_sec = 0.0
	_config.world_cells.max_preload_loads_per_refresh = 1000
	_config.interest = InterestSettings.new()
	_config.interest.interest_radius_cells = 0
	_config.interest.keep_margin_cells = 0
	_config.npc = NpcSettings.new()
	_config.npc_definitions = NpcCatalog.new()
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = DEFINITION_ID
	definition.display_name = "비공개값 검사원"
	definition.appearance = _config.appearance.default_selection()
	definition.background_tags = PackedStringArray(["private_background_sentinel"])
	definition.courage = 0.123456
	definition.skill_medical = 0.654321
	_config.npc_definitions.add(definition)
	_config.npc_net = NpcNetSettings.new()
	_cluster = NetTestCluster.new(tree, network_settings, _config)
	_labels = {}


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func _start() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	var npcs: NpcService = _npcs()
	if npcs.register_component("npc_net_private_probe", func() -> NpcComponent: return SecretComponent.new()) != OK:
		return false
	if _world.seed_new_world(DevWorldSeed.new()) != OK:
		return false
	if _cluster.start_server(_world, null) != OK:
		return false
	return _module(_cluster.server).set_action_label_source(func(npc: NpcState) -> String: return _labels.get(npc.npc_id, "idle")) == OK


func _npcs() -> NpcService:
	return _world.get_system(NpcService.SYSTEM_ID) as NpcService


func _module(service: NetworkService) -> NpcNetModule:
	return service.get_module(NpcNetModule.MODULE_NAME) as NpcNetModule


func _mirror(service: NetworkService) -> ClientNpcState:
	return _module(service).client_state


func _spawn(position: Vector3 = SPAWN) -> String:
	var result: ActionResult = _npcs().spawn_npc(_world, DEFINITION_ID, position, 0.5)
	if not result.ok:
		fail("test setup: NPC spawn refused: " + result.reason)
		return ""
	return str(result.event[NpcService.KEY_NPC_ID])


func _event_count(state: ClientNpcState, event_type: String) -> int:
	var count: int = 0
	for event: Dictionary in state.recent_events():
		if str(event.get(NpcNetProtocol.KEY_EVENT_TYPE, "")) == event_type:
			count += 1
	return count


func test_two_clients_follow_one_public_row_then_receive_left_outside_interest() -> void:
	assert_true(_start())
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	assert_true(a != null and b != null)
	var npc_id: String = _spawn()
	assert_false(npc_id.is_empty())
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _mirror(a).has_npc(npc_id) and _mirror(b).has_npc(npc_id), MAX_WAIT_TICKS), "npc_entered reached both clients")
	var a_row: Dictionary = _mirror(a).get_npc(npc_id)
	var b_row: Dictionary = _mirror(b).get_npc(npc_id)
	assert_eq(a_row, b_row, "both clients hold the same public NPC row")
	assert_eq(a_row[NpcNetProtocol.KEY_NAME], "비공개값 검사원")
	assert_eq(a_row[NpcNetProtocol.KEY_APPEARANCE], _config.appearance.default_selection())
	assert_eq(a_row[NpcNetProtocol.KEY_ACTION_LABEL], "idle")
	assert_eq(a_row[NpcNetProtocol.KEY_POSTURE], "standing")

	# The actual join-fragment wire is an exact public whitelist. Definition,
	# component, needs, mind, relationships, skills, goal and RNG stay server-only.
	var fragment: Dictionary = _module(_cluster.server).build_join_fragment(a.client_state.local_player_id)
	var wire_text: String = var_to_str(fragment)
	for forbidden: String in [DEFINITION_ID, "private_background_sentinel", "npc_net_private_probe", "hunger", "emotion", "memory", "relationship", "personality", "skills", "goal", "rng", PRIVATE_SENTINEL, "private_fear", "private_goal"]:
		assert_not_contains(wire_text, forbidden, "wire has no private key/value: " + forbidden)

	# P4-4 will supply the same seam; the changed observable label is reliable.
	_labels[npc_id] = "walk"
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return str(_mirror(a).get_npc(npc_id).get(NpcNetProtocol.KEY_ACTION_LABEL, "")) == "walk" and str(_mirror(b).get_npc(npc_id).get(NpcNetProtocol.KEY_ACTION_LABEL, "")) == "walk", MAX_WAIT_TICKS), "action label event reached both clients")
	assert_eq(_event_count(_mirror(a), NpcNetProtocol.EVENT_ACTION_CHANGED), 1)
	assert_eq(_event_count(_mirror(b), NpcNetProtocol.EVENT_ACTION_CHANGED), 1)

	# NPCs do not move themselves yet. Moving through the server API is seen
	# by both mirrors on the configured 5 Hz snapshot stream.
	assert_true(_npcs().set_npc_transform(_world, npc_id, MOVED, 1.25))
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _mirror(a).get_npc(npc_id).get(NpcNetProtocol.KEY_POSITION, Vector3.ZERO) == MOVED and _mirror(b).get_npc(npc_id).get(NpcNetProtocol.KEY_POSITION, Vector3.ZERO) == MOVED, MAX_WAIT_TICKS), "both clients followed set_npc_transform")
	assert_eq(_mirror(a).get_npc(npc_id), _mirror(b).get_npc(npc_id))

	# cell_1_0 is loaded by the spawn cell's preload ring but is outside both
	# clients' radius-0 interest. Membership leaves only through reliable ch0.
	assert_true(_npcs().set_npc_transform(_world, npc_id, OUTSIDE_INTEREST, 1.5))
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return not _mirror(a).has_npc(npc_id) and not _mirror(b).has_npc(npc_id), MAX_WAIT_TICKS), "npc_left removed it outside interest")
	assert_eq(_event_count(_mirror(a), NpcNetProtocol.EVENT_LEFT), 1)
	assert_eq(_event_count(_mirror(b), NpcNetProtocol.EVENT_LEFT), 1)
	for client: NetworkService in [a, b]:
		assert_eq(_mirror(client).rejected_payload_count, 0)
		assert_eq(_mirror(client).event_gap_count, 0)


func test_rpc_channels_and_modes_are_the_budgeted_ones() -> void:
	assert_eq(BuildInfo.PROTOCOL_VERSION, 21, "NpcNet join/events/snapshots are protocol 16")
	var script: Script = NpcNetModule
	var config: Dictionary = script.get_rpc_config()
	var snapshot: Dictionary = config[&"_rpc_npc_snapshot"]
	var events: Dictionary = config[&"_rpc_npc_events"]
	assert_eq(config.size(), 2, "server -> client only")
	assert_eq(snapshot["rpc_mode"], MultiplayerAPI.RPC_MODE_AUTHORITY)
	assert_eq(snapshot["transfer_mode"], MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
	assert_eq(snapshot["channel"], NetworkSettings.CHANNEL_ENTITY_SNAPSHOT)
	assert_eq(events["rpc_mode"], MultiplayerAPI.RPC_MODE_AUTHORITY)
	assert_eq(events["transfer_mode"], MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	assert_eq(events["channel"], NetworkSettings.CHANNEL_RELIABLE)
