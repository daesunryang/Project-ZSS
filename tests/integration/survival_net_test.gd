extends TestCase
## P2-N1c: survival replication over real ENet (server + clients).

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	_config = CompositionConfig.from_defaults()
	# from_defaults() resources are cached/shared. Tests always replace settings.
	_config.survival = SurvivalSettings.new()
	_config.survival_net = SurvivalNetSettings.new()
	_config.survival_net.owner_snapshot_rate_hz = 20.0
	_config.clock = WorldClockSettings.new()
	_config.clock.time_scale = 20.0
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_cluster = NetTestCluster.new(tree, network_settings, _config)


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func _start() -> void:
	_world = ServerComposition.create_world("survival_net_world", _config)
	assert_not_null(_world)
	if _world != null:
		assert_eq(_cluster.start_server(_world, null), OK)


func _module(service: NetworkService) -> SurvivalNetModule:
	return service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule


func _state(service: NetworkService) -> ClientSurvivalState:
	return _module(service).client_state


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _has_event(state: ClientSurvivalState, event_type: String, player_id: String) -> bool:
	for event: Dictionary in state.recent_events():
		if str(event.get("event_type", "")) == event_type and str(event.get("player_id", "")) == player_id:
			return true
	return false


func test_owner_gets_health_while_other_gets_only_observable_hit() -> void:
	_start()
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var result: ActionResult = _survival().apply_damage(alice_id, DamageInput.create("zombie_1", BodyPart.Part.LEFT_ARM, Wound.Type.BITE, 25.0))
	assert_true(result.ok)
	var delivered: bool = await _cluster.wait_until(func() -> bool:
		return is_equal_approx(_state(a).health(), _survival().get_vitals(alice_id).health) and _state(a).wounds().size() == 1 and _has_event(_state(b), SurvivalService.EVENT_PLAYER_WOUNDED, alice_id)
	)
	assert_true(delivered, "owner health and public hit arrived")
	assert_eq(_state(a).wounds()[0]["wound_type"], "bite", "owner snapshot includes detailed wounds")
	var public_hit: Dictionary = {}
	for event: Dictionary in _state(b).recent_events():
		if str(event.get("event_type", "")) == SurvivalService.EVENT_PLAYER_WOUNDED and str(event.get("player_id", "")) == alice_id:
			public_hit = event
	assert_eq(public_hit.get("body_part", ""), "left_arm")
	assert_eq(public_hit.get("wound_type", ""), "bite")
	assert_false(public_hit.has("health_after"), "other player receives no health")
	assert_false(public_hit.has("damage"), "other player receives no damage number")
	assert_false(public_hit.has("wound"), "other player receives no detailed wound")


func test_infection_is_owner_only_and_never_appears_in_other_payloads() -> void:
	_config.survival.infection_chance_bite = 1.0
	_start()
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var infected: ActionResult = _survival().apply_infection_exposure(alice_id, InfectionState.Exposure.BITE, "zombie_1")
	assert_eq(infected.event["event_type"], SurvivalService.EVENT_PLAYER_INFECTED)
	var owner_updated: bool = await _cluster.wait_until(func() -> bool: return _state(a).infection_stage() == "latent")
	assert_true(owner_updated, "owner learned infection stage")
	await _cluster.wait_frames(5)
	assert_eq(_state(b).infection_stage(), "none", "bob's own state remains unrelated")
	assert_false(_has_event(_state(b), SurvivalService.EVENT_PLAYER_INFECTED, alice_id), "infection event is not broadcast")
	for event: Dictionary in _state(b).recent_events():
		if str(event.get("player_id", "")) != alice_id:
			continue
		assert_not_contains(str(event.get("event_type", "")), "infection")
		assert_false(event.has("infection_stage"))
		assert_false(event.has("exposure"))
		assert_false(event.has("chance"))
		assert_false(event.has("from"))
		assert_false(event.has("to"))


func test_death_and_respawn_are_public_with_position() -> void:
	_config.survival.respawn_delay_world_sec = 2.0
	_config.gameplay = GameplaySettings.new()
	_config.gameplay.player_spawn_position = Vector3(7.0, 0.0, -3.0)
	_start()
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	assert_true(_survival().apply_damage(alice_id, DamageInput.create("zombie_1", BodyPart.Part.TORSO, Wound.Type.LACERATION, 500.0)).ok)
	var both_dead: bool = await _cluster.wait_until(func() -> bool: return not _state(a).is_alive(alice_id) and not _state(b).is_alive(alice_id))
	assert_true(both_dead, "both clients observed death")
	var both_respawned: bool = await _cluster.wait_until(func() -> bool:
		return _state(a).is_alive(alice_id) and _state(b).is_alive(alice_id) and _has_event(_state(a), SurvivalService.EVENT_PLAYER_RESPAWNED, alice_id) and _has_event(_state(b), SurvivalService.EVENT_PLAYER_RESPAWNED, alice_id)
	)
	assert_true(both_respawned, "both clients observed respawn")
	assert_eq(_state(a).last_respawn_position(alice_id), _config.gameplay.player_spawn_position)
	assert_eq(_state(b).last_respawn_position(alice_id), _config.gameplay.player_spawn_position)


func test_late_join_fragment_has_other_status_and_own_full_state() -> void:
	_config.survival.respawn_delay_world_sec = 1000.0
	_start()
	var a: NetworkService = await _cluster.join_client("alice")
	if a == null:
		fail("alice did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	_survival().apply_damage(alice_id, DamageInput.create("zombie_1", BodyPart.Part.HEAD, Wound.Type.BITE, 500.0))
	assert_true(await _cluster.wait_until(func() -> bool: return not _state(a).is_alive(alice_id)))
	var late: NetworkService = await _cluster.join_client("late")
	assert_not_null(late)
	if late == null:
		return
	var late_id: String = late.client_state.local_player_id
	assert_true(_state(late).has_player(alice_id))
	assert_false(_state(late).is_alive(alice_id), "late join sees existing death")
	assert_true(_state(late).is_alive(late_id))
	assert_eq(_state(late).health(), _config.survival.max_health)
	assert_eq(_state(late).stamina(), _config.survival.max_stamina)
	assert_eq(_state(late).infection_stage(), "none")


func test_non_server_and_malformed_payloads_are_ignored() -> void:
	_start()
	var a: NetworkService = await _cluster.join_client("alice")
	if a == null:
		fail("alice did not join")
		return
	var state: ClientSurvivalState = _state(a)
	var before_health: float = state.health()
	var before_events: int = state.recent_events().size()
	# A direct/local invocation has no server remote sender and is ignored.
	_module(a)._rpc_survival_owner_snapshot({"schema_version": 1, "player_id": a.client_state.local_player_id, "alive": true, "health": 1.0, "stamina": 1.0, "needs": {"hunger": "good", "thirst": "good", "fatigue": "good"}, "wounds": [], "infection_stage": "none"})
	assert_eq(state.health(), before_health, "non-server sender ignored")
	# These travel through the real server authority RPC path but fail DTO validation.
	var peer_id: int = _cluster.server.peer_of_player(a.client_state.local_player_id)
	_module(_cluster.server)._rpc_survival_owner_snapshot.rpc_id(peer_id, {"schema_version": 1, "player_id": a.client_state.local_player_id, "alive": true, "health": _config.survival.max_health + 1.0, "stamina": 1.0, "needs": {}, "wounds": [], "infection_stage": "zombified"})
	_module(_cluster.server)._rpc_survival_events.rpc_id(peer_id, [{"scope": "public", "event_type": "player_infected", "player_id": a.client_state.local_player_id, "infection_stage": "latent"}])
	await _cluster.wait_frames(10)
	assert_eq(state.health(), before_health, "out-of-range snapshot ignored")
	assert_eq(state.recent_events().size(), before_events, "out-of-scope event ignored")
	assert_contains("\n".join(GameLogger.captured_lines()), "invalid client survival payload ignored")
