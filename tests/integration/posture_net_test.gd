extends TestCase
## P2-T11: lying prone over real ENet (server + 2..3 clients). A client only
## asks for a posture; the server decides. A posture is a fact anybody can
## see, so the server and every client's mirror agree on who stands, who lies
## prone and who sleeps. A prone player crawls slowly, and a zombie that
## sees a standing player does not see a prone one at the same distance.
## Rules: tests/unit/posture_test.gd.

const WORLD: String = "posture_net_test_world"
const NEVER: float = 1.0e9
const WAIT_MSEC: int = 8000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const LETHAL_DAMAGE: float = 100000.0
const FORGED_REQUEST_ID: int = 77
const SIGHT_RANGE: float = 20.0
## Needs that must not move on their own during a test.
const FROZEN_NEED_HOURS: float = 100000.0
## Server ticks both players push the same move intent.
const MOVE_TICKS: int = 60

var _cluster: NetTestCluster = null
var _net_settings: NetworkSettings = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_net_settings = NetworkSettings.new()
	_net_settings.autosave_interval_sec = 0.0
	# Tests push a move intent every server tick.
	_net_settings.move_intent_rate_per_sec = 240.0
	_net_settings.move_intent_burst = 240
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.hunger_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.thirst_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.fatigue_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.respawn_delay_sec = NEVER
	_config.survival_net = SurvivalNetSettings.new()
	_config.survival_net.owner_snapshot_rate_hz = 20.0
	_config.survival_net.rest_intent_rate_per_sec = GENEROUS_RATE
	_config.survival_net.rest_intent_burst = GENEROUS_BURST
	_config.posture = PostureSettings.new()
	_config.posture_net = PostureNetSettings.new()
	_config.posture_net.posture_intent_rate_per_sec = GENEROUS_RATE
	_config.posture_net.posture_intent_burst = GENEROUS_BURST
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	# No zombies unless a test places one; they stand until they see somebody.
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.wander_pause_min_sec = NEVER
	_config.zombie.wander_pause_max_sec = NEVER
	_config.zombie.sight_range_m = SIGHT_RANGE
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	_world = null


func after_each() -> void:
	Engine.print_error_messages = true
	if _cluster != null:
		await _cluster.shutdown()
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _start_server() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


## Joins "alice" and "bob". Empty on failure.
func _join_two() -> Array[NetworkService]:
	var joined: Array[NetworkService] = []
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return joined
	joined.append(a)
	joined.append(b)
	return joined


func _module(service: NetworkService) -> PostureNetModule:
	return service.get_module(PostureNetModule.MODULE_NAME) as PostureNetModule


## The client's posture mirror.
func _mirror(service: NetworkService) -> ClientPostureState:
	return _module(service).client_state


func _survival_module(service: NetworkService) -> SurvivalNetModule:
	return service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule


func _posture() -> PostureService:
	return _world.get_system(PostureService.SYSTEM_ID) as PostureService


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


## Rows [request_id, ok, reason] of every posture result of `service`.
func _results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).posture_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Rows [player_id, posture name] of every posture change `service` mirrors.
func _changes_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_mirror(service).posture_changed.connect(func(player_id: String, posture: PlayerPosture.Kind) -> void: rows.append([player_id, PlayerPosture.name_of(posture)]))
	return rows


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


## Lets the server run some ticks so anything still in flight arrives.
func _settle(ticks: int = SETTLE_TICKS) -> void:
	for tick: int in range(ticks):
		await tree.physics_frame


## Sends one posture request and waits for its answer: [ok, reason].
func _request(client: NetworkService, posture: PlayerPosture.Kind) -> Array:
	var rows: Array[Array] = _results_of(client)
	var request_id: int = _module(client).request_posture(posture)
	if request_id == PostureNetModule.NO_REQUEST:
		fail("the posture request was not sent")
		return [false, "not_sent"]
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	if not answered:
		fail("the posture request was not answered")
		return [false, "no_answer"]
	if int(rows[0][0]) != request_id:
		fail("the answer carries another request id: %s" % str(rows[0]))
	return [rows[0][1], rows[0][2]]


## "" when the client's view of everybody's posture equals the server's,
## else what differs.
func _mismatch(client: NetworkService) -> String:
	for player_id: String in _world.online_player_ids():
		if _mirror(client).posture_of(player_id) != _posture().posture_of(player_id):
			return "%s: mirror %s, server %s" % [player_id, PlayerPosture.name_of(_mirror(client).posture_of(player_id)), PlayerPosture.name_of(_posture().posture_of(player_id))]
	return ""


## Waits until every given client agrees with the server about postures.
func _assert_mirrors_match(clients: Array, label: String) -> void:
	for client: NetworkService in clients:
		var matched: bool = await _wait(func() -> bool: return _mismatch(client).is_empty())
		assert_true(matched, "%s (%s): %s" % [label, client.client_state.local_player_id, _mismatch(client)])


# ------------------------------------------------------------ 1. prone, crawl, stand up

func test_a_client_lies_prone_everybody_sees_it_and_it_crawls() -> void:
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	await _assert_mirrors_match([a, b], "start")
	assert_eq(_mirror(a).posture_of(alice_id), PlayerPosture.Kind.STANDING)
	await _settle()
	var b_changes: Array[Array] = _changes_of(b)
	var b_results: Array[Array] = _results_of(b)
	var b_survival_events: Array[Dictionary] = []
	_survival_module(b).client_state.event_received.connect(func(event: Dictionary) -> void: b_survival_events.append(event))

	# Alice lies prone: an intent with a request id and the wanted posture only.
	assert_eq(await _request(a, PlayerPosture.Kind.PRONE), [true, ""])
	assert_eq(_posture().posture_of(alice_id), PlayerPosture.Kind.PRONE, "server: alice is prone")
	assert_eq(_posture().posture_of(bob_id), PlayerPosture.Kind.STANDING, "server: bob stands")
	assert_eq(_mirror(a).posture_of(alice_id), PlayerPosture.Kind.PRONE, "alice's mirror knew before the answer arrived")
	await _assert_mirrors_match([a, b], "alice prone")
	assert_eq(_mirror(b).posture_of(alice_id), PlayerPosture.Kind.PRONE, "bob's mirror: alice is prone (an observable fact)")
	assert_eq(_mirror(b).posture_of(bob_id), PlayerPosture.Kind.STANDING)

	# Both push the same move intent for the same ticks: alice crawls.
	var a_start: Vector3 = _world.get_player(alice_id).position
	var b_start: Vector3 = _world.get_player(bob_id).position
	for tick: int in range(MOVE_TICKS):
		a.send_move_intent(Vector2(1.0, 0.0), 0.0)
		b.send_move_intent(Vector2(1.0, 0.0), 0.0)
		await tree.physics_frame
	await _settle(5)
	var crawled: float = _world.get_player(alice_id).position.x - a_start.x
	var walked: float = _world.get_player(bob_id).position.x - b_start.x
	assert_true(walked > 1.0, "server: bob walked (%f)" % walked)
	assert_true(crawled > 0.0, "server: alice moved (%f)" % crawled)
	var ratio: float = crawled / walked
	assert_true(absf(ratio - _config.posture.prone_movement_multiplier) < 0.1, "server: a prone player moves at the prone speed (ratio %f)" % ratio)
	assert_eq(_posture().posture_of(alice_id), PlayerPosture.Kind.PRONE, "moving does not change the posture")

	# A late joiner learns it from the join snapshot.
	var c: NetworkService = await _cluster.join_client("carol")
	assert_not_null(c, "carol joined")
	if c == null:
		return
	assert_eq(_mirror(c).posture_of(alice_id), PlayerPosture.Kind.PRONE, "carol's mirror: alice is prone")
	await _assert_mirrors_match([a, b, c], "carol joined")

	# Alice stands up.
	assert_eq(await _request(a, PlayerPosture.Kind.STANDING), [true, ""])
	await _assert_mirrors_match([a, b, c], "alice up")
	assert_eq(_mirror(b).posture_of(alice_id), PlayerPosture.Kind.STANDING)
	await _settle()
	# What bob was told: alice's two posture changes, nothing about why and
	# nothing through the survival channel (no vitals, no needs).
	assert_eq(b_changes, [[alice_id, "prone"], [alice_id, "standing"]], "bob: %s" % str(b_changes))
	assert_eq(b_survival_events.size(), 0, "a posture change is no survival event: %s" % str(b_survival_events))
	assert_eq(b_results.size(), 0, "the result goes to the requester only")
	# Move intents travel unreliably: a reordered one is counted as stale. Nothing else was refused.
	assert_eq(_cluster.server.rejected_intent_count() - _cluster.server.rejected_intent_count(ServerWorld.REASON_STALE_SEQUENCE), 0)

	# Leaving while prone ends the posture with the session.
	assert_eq(await _request(a, PlayerPosture.Kind.PRONE), [true, ""])
	await _assert_mirrors_match([a, b, c], "alice prone again")
	_cluster.remove_client(a)
	assert_true(await _wait(func() -> bool: return not _world.is_online(alice_id)), "alice left")
	assert_eq(_posture().posture_of(alice_id), PlayerPosture.Kind.STANDING, "server: an offline player has no posture")
	var a2: NetworkService = await _cluster.join_client("alice")
	assert_not_null(a2, "alice rejoined")
	if a2 == null:
		return
	await _assert_mirrors_match([a2, b, c], "alice rejoined")
	assert_eq(_mirror(b).posture_of(alice_id), PlayerPosture.Kind.STANDING, "bob's mirror: she stands after rejoining")


# ------------------------------------------------------------ 2. zombie sight

func test_a_zombie_sees_the_standing_player_and_not_the_prone_one_at_the_same_distance() -> void:
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	# Between the prone and the standing sight distance, both in front of
	# where the zombie will look (yaw 0 looks along -Z), the same distance.
	var distance: float = SIGHT_RANGE * (_config.posture.prone_still_visibility + _config.posture.standing_still_visibility) * 0.5
	_world.get_player(alice_id).position = Vector3(-1.5, 0.0, -distance)
	_world.get_player(bob_id).position = Vector3(1.5, 0.0, -distance)
	assert_eq(await _request(a, PlayerPosture.Kind.PRONE), [true, ""])
	await _assert_mirrors_match([a, b], "alice prone, bob standing")
	# The placement was a jump: let the server see it (process frames can
	# outrun server ticks) and let it age out of the movement memory.
	await _settle()
	assert_true(await _wait(func() -> bool: return not _posture().is_moving(alice_id) and not _posture().is_moving(bob_id)), "both are still")
	assert_true(absf(_world.player_visibility_multiplier(alice_id) - _config.posture.prone_still_visibility) < 0.001, "server: alice is hard to see")
	assert_true(absf(_world.player_visibility_multiplier(bob_id) - _config.posture.standing_still_visibility) < 0.001, "server: bob is easy to see (%f)" % _world.player_visibility_multiplier(bob_id))

	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var spawned: ActionResult = zombies.spawn_zombie(_world, Vector3.ZERO, 0.0)
	assert_true(spawned.ok, spawned.reason)
	var zombie_id: String = str(spawned.event.get("zombie_id", ""))
	var targets: Dictionary[String, bool] = {}
	var sees_bob: Callable = func() -> bool:
		targets[zombies.get_zombie(zombie_id).target_player_id] = true
		return zombies.get_zombie(zombie_id).target_player_id == bob_id
	var saw_bob: bool = await _wait(sees_bob)
	assert_true(saw_bob, "server: the zombie saw bob, who stands")
	# Its next decisions too: it never turns to alice.
	for tick: int in range(SETTLE_TICKS * 3):
		targets[zombies.get_zombie(zombie_id).target_player_id] = true
		await tree.physics_frame
	assert_false(targets.has(alice_id), "server: the zombie never saw alice, who lies prone at the same distance (%s)" % str(targets.keys()))
	assert_eq(ZombieState.state_name(zombies.get_zombie(zombie_id).state), "chase")
	# Both clients see the same chase (the zombie mirror is public).
	var a_zombies: ClientZombieState = (a.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
	var b_zombies: ClientZombieState = (b.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
	assert_true(await _wait(func() -> bool: return str(a_zombies.get_zombie(zombie_id).get("state", "")) == "chase" and str(b_zombies.get_zombie(zombie_id).get("state", "")) == "chase"), "both mirrors: the zombie chases")
	assert_true(zombies.apply_damage_to_zombie(zombie_id, LETHAL_DAMAGE, bob_id).ok)


# ------------------------------------------------------------ 3. prone and sleep, both intents

func test_prone_and_sleep_stay_one_posture_across_both_intents() -> void:
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	assert_eq(await _request(a, PlayerPosture.Kind.PRONE), [true, ""])
	await _assert_mirrors_match([a, b], "alice prone")
	# The rest intent of the survival module (the rest key) from prone.
	var rest_rows: Array[Array] = []
	_survival_module(a).rest_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rest_rows.append([request_id, ok, reason]))
	var rest_id: int = _survival_module(a).request_rest(true)
	assert_true(await _wait(func() -> bool: return rest_rows.size() == 1), "the rest request was answered")
	assert_eq(rest_rows, [[rest_id, true, ""]])
	assert_eq(_posture().posture_of(alice_id), PlayerPosture.Kind.RESTING, "server: asleep, not prone")
	await _assert_mirrors_match([a, b], "alice asleep")
	assert_eq(_mirror(b).posture_of(alice_id), PlayerPosture.Kind.RESTING)
	assert_true(await _wait(func() -> bool: return _survival_module(b).client_state.is_resting(alice_id)), "bob's survival mirror agrees")
	# The wanted-posture intent wakes her: straight from sleep to prone.
	assert_eq(await _request(a, PlayerPosture.Kind.PRONE), [true, ""])
	assert_false(_survival().is_resting(alice_id), "server: she woke")
	assert_eq(_posture().posture_of(alice_id), PlayerPosture.Kind.PRONE)
	await _assert_mirrors_match([a, b], "alice prone again")
	assert_true(await _wait(func() -> bool: return not _survival_module(b).client_state.is_resting(alice_id) and not _survival_module(a).client_state.is_resting(alice_id)), "both survival mirrors: she is awake")
	# And it can lie down to sleep and get up.
	assert_eq(await _request(a, PlayerPosture.Kind.RESTING), [true, ""])
	assert_true(_survival().is_resting(alice_id))
	await _assert_mirrors_match([a, b], "alice asleep through the posture intent")
	assert_true(await _wait(func() -> bool: return _survival_module(b).client_state.is_resting(alice_id)), "bob's survival mirror follows")
	assert_eq(await _request(a, PlayerPosture.Kind.RESTING), [false, SurvivalService.REASON_ALREADY_RESTING])
	assert_eq(await _request(a, PlayerPosture.Kind.STANDING), [true, ""])
	assert_false(_survival().is_resting(alice_id))
	await _assert_mirrors_match([a, b], "alice up")
	# A prone player's attack is refused; standing, it is accepted.
	assert_eq(await _request(a, PlayerPosture.Kind.PRONE), [true, ""])
	var combat: CombatNetModule = a.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule
	var attacks: Array[Array] = []
	combat.melee_result.connect(func(request_id: int, ok: bool, reason: String) -> void: attacks.append([request_id, ok, reason]))
	var attack_id: int = combat.request_melee_attack(0.0)
	assert_true(await _wait(func() -> bool: return attacks.size() == 1), "the attack was answered")
	assert_eq(attacks, [[attack_id, false, PostureService.REASON_PLAYER_PRONE]], "no attack while prone")
	# Death ends prone for everybody.
	assert_true(_survival().apply_damage(alice_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(_posture().posture_of(alice_id), PlayerPosture.Kind.STANDING, "server: a dead character has no posture")
	await _assert_mirrors_match([a, b], "alice dead")
	assert_eq(await _request(a, PlayerPosture.Kind.PRONE), [false, SurvivalService.REASON_PLAYER_DEAD])


# ------------------------------------------------------------ 4. manipulated requests

func test_manipulated_posture_requests_are_rejected_and_change_nothing() -> void:
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var a_results: Array[Array] = _results_of(a)
	var b_results: Array[Array] = _results_of(b)
	var server: NetworkService = _cluster.server
	var module: PostureNetModule = _module(a)

	# Malformed arguments: nobody changes posture.
	module.send_raw_posture_request("x", "prone")
	module.send_raw_posture_request(1, 1)
	module.send_raw_posture_request(2, null)
	module.send_raw_posture_request(3, "flying")
	module.send_raw_posture_request(-1, "prone")
	module.send_raw_posture_request(4.0, "prone")
	module.send_raw_posture_request(5, ["prone"])
	module.send_raw_posture_request(6, "PRONE")
	module.send_raw_posture_request(7, "prone".repeat(100))
	module.send_raw_posture_request(8, bob_id)
	module.send_raw_posture_request(9, true)
	const MALFORMED: int = 11
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == MALFORMED), "every malformed request was rejected (%d)" % server.rejected_intent_count())
	# A request cannot name the player to put down, a speed or a visibility:
	# the handler takes two arguments and the engine refuses a call with more
	# (reported as an engine error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_posture.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, "prone", bob_id)
	module._rpc_request_posture.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, "prone", 0.0)
	await _settle()
	Engine.print_error_messages = true
	assert_eq(a_results, [
		[1, false, IntentValidator.REASON_BAD_TYPE],
		[2, false, IntentValidator.REASON_BAD_TYPE],
		[3, false, PostureService.REASON_BAD_POSTURE],
		[5, false, IntentValidator.REASON_BAD_TYPE],
		[6, false, PostureService.REASON_BAD_POSTURE],
		[7, false, PostureService.REASON_BAD_POSTURE],
		[8, false, PostureService.REASON_BAD_POSTURE],
		[9, false, IntentValidator.REASON_BAD_TYPE],
	], "answers go to usable request ids only, in order")
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE), 6)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_SEQUENCE), 1)
	assert_eq(server.rejected_intent_count(PostureService.REASON_BAD_POSTURE), 4)
	assert_eq(server.rejected_intent_count(), MALFORMED, "the calls the engine refused never reached the handler")
	assert_eq(_posture().posture_of(alice_id), PlayerPosture.Kind.STANDING)
	assert_eq(_posture().posture_of(bob_id), PlayerPosture.Kind.STANDING, "nobody changed posture")

	# Wrong state: standing up while standing, lying prone twice.
	a_results.clear()
	module.send_raw_posture_request(10, "standing")
	module.send_raw_posture_request(11, "prone")
	module.send_raw_posture_request(12, "prone")
	assert_true(await _wait(func() -> bool: return a_results.size() == 3), "alice was answered")
	assert_eq(a_results, [
		[10, false, PostureService.REASON_ALREADY_IN_POSTURE],
		[11, true, ""],
		[12, false, PostureService.REASON_ALREADY_IN_POSTURE],
	])
	# Bob cannot make alice stand: his request is about himself only.
	_module(b).send_raw_posture_request(1, "standing")
	assert_true(await _wait(func() -> bool: return b_results.size() == 1), "bob was answered")
	assert_eq(b_results, [[1, false, PostureService.REASON_ALREADY_IN_POSTURE]])
	assert_eq(_posture().posture_of(alice_id), PlayerPosture.Kind.PRONE, "alice is still prone")
	await _assert_mirrors_match([a, b], "after the manipulated requests")

	# Forged server messages: a client cannot tell another client (or the
	# server) who is prone, or answer a request. Real ENet path: the engine
	# refuses these (the sender is not the authority) and reports each as an
	# engine error, the expected outcome, so printing is off for this block.
	var b_changes: Array[Array] = _changes_of(b)
	var server_results: Array[Array] = _results_of(server)
	b_results.clear()
	Engine.print_error_messages = false
	for target: int in [NetworkService.SERVER_PEER_ID, b.multiplayer.get_unique_id()]:
		module._rpc_posture_result.rpc_id(target, FORGED_REQUEST_ID, true, "")
		module._rpc_posture_rows.rpc_id(target, [{"player_id": bob_id, "posture": "prone"}])
	await _settle()
	Engine.print_error_messages = true
	# Script-level guard, independent of the engine (sender id 0 here), and a
	# client never acts on a request addressed to it.
	_module(b)._rpc_posture_result(FORGED_REQUEST_ID, true, "")
	_module(b)._rpc_posture_rows([{"player_id": bob_id, "posture": "prone"}])
	_module(b)._rpc_request_posture(FORGED_REQUEST_ID, "prone")
	await _settle()
	assert_eq(b_results.size() + server_results.size() + b_changes.size(), 0, "nothing forged was delivered")
	assert_eq(_mirror(b).posture_of(bob_id), PlayerPosture.Kind.STANDING, "bob's mirror was not changed")
	assert_eq(_posture().posture_of(bob_id), PlayerPosture.Kind.STANDING)
	assert_eq(server.rejected_intent_count(), MALFORMED + 3, "only the three wrong-state requests were added")


func test_posture_request_before_join_and_without_a_character_is_rejected() -> void:
	_config.require_character_creation = true
	assert_true(_start_server(), "server started")
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var results: Array[Array] = _results_of(stranger)
	var connected: bool = await _wait(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	assert_eq(_module(stranger).request_posture(PlayerPosture.Kind.PRONE), PostureNetModule.NO_REQUEST, "the client API sends nothing before the join")
	_module(stranger).send_raw_posture_request(1, "prone")
	assert_true(await _wait(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 1), "the server refused the request of a peer that has not joined")
	await _settle()
	assert_eq(results.size(), 0, "an unjoined peer is told nothing")
	# A joined player that has not created its character is not in the world.
	var ghost: NetworkService = await _cluster.join_client("ghost")
	assert_not_null(ghost, "ghost joined")
	if ghost == null:
		return
	var ghost_id: String = ghost.client_state.local_player_id
	assert_false(_world.is_online(ghost_id), "connected, without a character")
	assert_eq(await _request(ghost, PlayerPosture.Kind.PRONE), [false, ServerWorld.REASON_NOT_ONLINE])
	assert_eq(_posture().posture_of(ghost_id), PlayerPosture.Kind.STANDING)
	assert_eq(_world.online_player_ids().size(), 0)


func test_posture_flood_is_rate_limited_per_peer() -> void:
	const BURST: int = 2
	const FLOOD: int = 6
	# One new token every 100 seconds: only the burst passes within the test.
	_config.posture_net.posture_intent_rate_per_sec = 0.01
	_config.posture_net.posture_intent_burst = BURST
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var a_results: Array[Array] = _results_of(a)
	var requests: Array = []
	# Down, up, down, up, ...
	for index: int in range(FLOOD):
		requests.append(_module(a).request_posture(PlayerPosture.Kind.PRONE if index % 2 == 0 else PlayerPosture.Kind.STANDING))
	assert_true(await _wait(func() -> bool: return a_results.size() == FLOOD), "every request was answered (%d)" % a_results.size())
	await _settle()
	var expected: Array = []
	for index: int in range(FLOOD):
		expected.append([requests[index], true, ""] if index < BURST else [requests[index], false, NetworkService.RATE_LIMITED])
	assert_eq(a_results, expected, "only the burst is accepted")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST, "rejection counter")
	assert_eq(_posture().posture_of(alice_id), PlayerPosture.Kind.STANDING, "down and up again: the refused requests changed nothing")
	# The bucket is per peer: bob can still lie prone.
	assert_eq(await _request(b, PlayerPosture.Kind.PRONE), [true, ""])


# ------------------------------------------------------------ rules (no network)

func test_default_settings_rpc_table_and_request_validation() -> void:
	var settings: PostureNetSettings = PostureNetSettings.load_or_default()
	assert_true(ResourceLoader.exists(PostureNetSettings.DEFAULT_PATH))
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	var broken: PostureNetSettings = PostureNetSettings.new()
	broken.posture_intent_rate_per_sec = 0.0
	broken.max_player_id_length = 0
	assert_eq(broken.validate().size(), 2, "; ".join(broken.validate()))
	assert_eq(CompositionConfig.from_defaults().validate().size(), 0)
	assert_eq(BuildInfo.PROTOCOL_VERSION, 9, "the posture RPCs are part of protocol 8 (P2-T10..T12); 9 since the hand-over RPCs (P2-T14)")
	assert_eq(PostureNetModule.SCHEMA_VERSION, ClientPostureState.SCHEMA_VERSION, "server and client agree on the format")
	assert_eq(PostureNetModule.validate_posture_request(1, "prone"), "")
	assert_eq(PostureNetModule.validate_posture_request(0, "standing"), "")
	assert_eq(PostureNetModule.validate_posture_request(2, "resting"), "")
	assert_eq(PostureNetModule.validate_posture_request("1", "prone"), IntentValidator.REASON_BAD_TYPE)
	assert_eq(PostureNetModule.validate_posture_request(1.0, "prone"), IntentValidator.REASON_BAD_TYPE)
	assert_eq(PostureNetModule.validate_posture_request(1, 1), IntentValidator.REASON_BAD_TYPE, "a posture is a name, not a number")
	assert_eq(PostureNetModule.validate_posture_request(1, null), IntentValidator.REASON_BAD_TYPE)
	assert_eq(PostureNetModule.validate_posture_request(-1, "prone"), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(PostureNetModule.validate_posture_request(1, ""), PostureService.REASON_BAD_POSTURE)
	assert_eq(PostureNetModule.validate_posture_request(1, "crouching"), PostureService.REASON_BAD_POSTURE)
	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	var module: PostureNetModule = service.get_module(PostureNetModule.MODULE_NAME) as PostureNetModule
	assert_not_null(module, "the module is installed on servers and clients")
	assert_eq(module.request_posture(PlayerPosture.Kind.PRONE), PostureNetModule.NO_REQUEST, "nothing is sent while offline")
	# Channel 0, reliable; the request from any peer, everything else only from the server.
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	var expected_modes: Dictionary[String, int] = {
		"_rpc_request_posture": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_posture_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_posture_rows": MultiplayerAPI.RPC_MODE_AUTHORITY,
	}
	assert_eq(rpc_config.size(), expected_modes.size(), "no other RPC exists")
	for method: String in expected_modes:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), expected_modes[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	service.free()


func test_the_client_mirror_validates_posture_payloads() -> void:
	const ME: String = "player_000001"
	const OTHER: String = "player_000002"
	var mirror: ClientPostureState = ClientPostureState.new(PostureNetSettings.new())
	assert_eq(mirror.posture_of(ME), PlayerPosture.Kind.STANDING, "unknown players stand")
	var fragment: Dictionary = {"schema_version": ClientPostureState.SCHEMA_VERSION, "players": [
		{"player_id": ME, "posture": "standing"},
		{"player_id": OTHER, "posture": "prone"},
	]}
	assert_true(mirror.apply_join(ME, fragment))
	assert_eq(mirror.posture_of(OTHER), PlayerPosture.Kind.PRONE, "the join fragment says who lies prone")
	assert_true(mirror.is_prone(OTHER))
	var changes: Array[Array] = []
	mirror.posture_changed.connect(func(player_id: String, posture: PlayerPosture.Kind) -> void: changes.append([player_id, PlayerPosture.name_of(posture)]))
	assert_eq(mirror.apply_rows([{"player_id": OTHER, "posture": "resting"}, {"player_id": ME, "posture": "prone"}]), 2)
	assert_eq(mirror.apply_rows([{"player_id": ME, "posture": "prone"}]), 1, "the same posture again is accepted")
	assert_eq(changes, [[OTHER, "resting"], [ME, "prone"]], "one notification per change")
	mirror.remove_player(OTHER)
	assert_eq(mirror.posture_of(OTHER), PlayerPosture.Kind.STANDING)
	# Refused rows change nothing; the good rows of the same batch are kept.
	var bad_rows: Array = [
		{"player_id": ME, "posture": "flying"},
		{"player_id": ME, "posture": 1},
		{"player_id": "", "posture": "standing"},
		{"player_id": ME},
		{"player_id": ME, "posture": "standing", "visibility": 0.4},
		{"player_id": ME, "posture": "standing", "previous": "prone"},
		"standing",
		{"player_id": "x".repeat(1000), "posture": "standing"},
	]
	assert_eq(mirror.apply_rows(bad_rows), 0, "unknown postures, wrong types, extra fields and bad ids are refused")
	assert_eq(mirror.posture_of(ME), PlayerPosture.Kind.PRONE)
	assert_eq(mirror.apply_rows(bad_rows + [{"player_id": OTHER, "posture": "prone"}]), 1)
	assert_true(mirror.is_prone(OTHER))
	# A refused join fragment leaves everybody standing.
	for bad_fragment: Dictionary in [
		{"schema_version": ClientPostureState.SCHEMA_VERSION + 1, "players": []},
		{"schema_version": ClientPostureState.SCHEMA_VERSION},
		{"schema_version": ClientPostureState.SCHEMA_VERSION, "players": [{"player_id": ME, "posture": "flying"}]},
		{"schema_version": ClientPostureState.SCHEMA_VERSION, "players": [{"player_id": ME, "posture": "prone"}, {"player_id": ME, "posture": "standing"}]},
		{"schema_version": ClientPostureState.SCHEMA_VERSION, "players": [], "extra": true},
		{},
	]:
		assert_false(mirror.apply_join(ME, bad_fragment), "rejected: %s" % str(bad_fragment))
		assert_eq(mirror.posture_of(OTHER), PlayerPosture.Kind.STANDING)
