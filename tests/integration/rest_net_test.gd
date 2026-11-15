extends TestCase
## P2-T8: lying down and getting up over real ENet (server + 2..3 clients).
## A client only asks ("lie down" / "get up"); the server decides. While a
## player rests the server lowers its fatigue, ignores its move intents and
## refuses its attacks and item actions; a hit wakes it. The owner mirrors
## its own state. Other players learn the observable fact "this player is
## lying down" and nothing about its fatigue (docs/00 ADR-009). Resting is
## not saved.

const WORLD: String = "rest_net_test_world"
const NEVER: float = 1.0e9
const CELL: String = DevWorldSeed.DEV_CELL_ID
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const WAIT_MSEC: int = 6000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const LETHAL_DAMAGE: float = 100000.0
const FORGED_REQUEST_ID: int = 77
const AIM_MINUS_Z: float = 0.0
## Needs do not move on their own during a test (the longest allowed climb).
const FROZEN_NEED_HOURS: float = 100000.0
## World hours of rest from the maximum to 0: about 3 real seconds at 24x.
const FAST_REST_HOURS: float = 0.02
const TIRED: float = 90.0
## "Rested" in these tests: this far below the caution threshold, so the
## category does not sit on the boundary when the rest stops.
const RESTED_MARGIN: float = 5.0
## Keys of the only events another player gets about somebody's rest.
const PUBLIC_REST_KEYS: Array = ["event_type", "player_id", "scope", "world_time"]
## Words that must not appear in anything another player receives.
const PRIVATE_WORDS: PackedStringArray = ["fatigue", "need", "hunger", "thirst", "cause", "health", "stamina"]

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
	_net_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	_net_settings.pickup_intent_burst = GENEROUS_BURST
	# Tests push a move intent every server tick.
	_net_settings.move_intent_rate_per_sec = 240.0
	_net_settings.move_intent_burst = 240
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	# Only resting moves fatigue: no growth, no recovery, no respawn.
	_config.survival = SurvivalSettings.new()
	_config.survival.hunger_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.thirst_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.fatigue_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.rest_fatigue_hours_from_max = FAST_REST_HOURS
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.wound_recovery_per_world_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	_config.survival_net = SurvivalNetSettings.new()
	_config.survival_net.owner_snapshot_rate_hz = 20.0
	_config.survival_net.rest_intent_rate_per_sec = GENEROUS_RATE
	_config.survival_net.rest_intent_burst = GENEROUS_BURST
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	# No zombies unless a test places one.
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	_world = null


func after_each() -> void:
	Engine.print_error_messages = true
	if _cluster != null:
		await _cluster.shutdown()
	if not _save_root.is_empty():
		SaveService.remove_tree(_save_root)
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


func _module(service: NetworkService) -> SurvivalNetModule:
	return service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule


## The client's survival mirror.
func _mirror(service: NetworkService) -> ClientSurvivalState:
	return _module(service).client_state


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _vitals(player_id: String) -> PlayerVitals:
	return _survival().get_vitals(player_id)


## Rows [request_id, ok, reason] of every rest result of `service`.
func _rest_results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).rest_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Every survival event `service` receives from now on.
func _survival_events_of(service: NetworkService) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_mirror(service).event_received.connect(func(event: Dictionary) -> void: events.append(event))
	return events


## The events of `events` that are about `player_id`.
func _events_about(events: Array[Dictionary], player_id: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("player_id", "")) == player_id:
			matching.append(event)
	return matching


func _types_of(events: Array[Dictionary]) -> Array:
	var types: Array = []
	for event: Dictionary in events:
		types.append(str(event.get("event_type", "")))
	return types


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


## Sends one rest request and waits for its answer: [ok, reason].
func _request_rest(client: NetworkService, lie_down: bool) -> Array:
	var rows: Array[Array] = _rest_results_of(client)
	var request_id: int = _module(client).request_rest(lie_down)
	if request_id == SurvivalNetModule.NO_REQUEST:
		fail("the rest request was not sent")
		return [false, "not_sent"]
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	if not answered:
		fail("the rest request was not answered")
		return [false, "no_answer"]
	if int(rows[0][0]) != request_id:
		fail("the answer carries another request id: %s" % str(rows[0]))
	return [rows[0][1], rows[0][2]]


## "" when the client's view of who is lying down equals the server's for
## every online player, else what differs.
func _resting_mismatch(client: NetworkService) -> String:
	for player_id: String in _world.online_player_ids():
		if _mirror(client).is_resting(player_id) != _survival().is_resting(player_id):
			return "%s: mirror %s, server %s" % [player_id, str(_mirror(client).is_resting(player_id)), str(_survival().is_resting(player_id))]
	return ""


## "" when the client's own need categories equal the server's.
func _needs_mismatch(client: NetworkService) -> String:
	var player_id: String = client.client_state.local_player_id
	for kind_index: int in NeedKind.KIND_NAMES.size():
		var kind_name: String = NeedKind.KIND_NAMES[kind_index]
		var server_category: String = NeedKind.category_name(_survival().need_category(player_id, kind_index as NeedKind.Kind))
		if _mirror(client).need_category(kind_name) != server_category:
			return "%s: mirror %s, server %s" % [kind_name, _mirror(client).need_category(kind_name), server_category]
	return ""


## Waits until every given client agrees with the server about who rests and
## its own mirror agrees about its needs.
func _assert_mirrors_match(clients: Array, label: String) -> void:
	for client: NetworkService in clients:
		var matched: bool = await _wait(func() -> bool: return _resting_mismatch(client).is_empty() and _needs_mismatch(client).is_empty())
		assert_true(matched, "%s (%s): %s %s" % [label, client.client_state.local_player_id, _resting_mismatch(client), _needs_mismatch(client)])


## Sends the same move intent for `ticks` server ticks.
func _push_move(client: NetworkService, ticks: int) -> void:
	for tick: int in range(ticks):
		client.send_move_intent(Vector2(1.0, 0.0), 0.0)
		await tree.physics_frame


# ------------------------------------------------------------ 1. lie down, rest, get up

func test_a_client_lies_down_rests_and_gets_up() -> void:
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	_vitals(alice_id).fatigue = TIRED
	_vitals(bob_id).fatigue = TIRED
	await _assert_mirrors_match([a, b], "start")
	assert_eq(_mirror(a).need_category("fatigue"), "danger")
	assert_false(_mirror(a).is_resting(alice_id))
	await _settle()
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	var b_results: Array[Array] = _rest_results_of(b)

	# Alice lies down: an intent with a request id and the wanted state only.
	assert_eq(await _request_rest(a, true), [true, ""])
	assert_true(_survival().is_resting(alice_id), "server: alice rests")
	assert_false(_survival().is_resting(bob_id), "server: bob does not")
	await _assert_mirrors_match([a, b], "alice lying")
	assert_true(_mirror(a).is_resting(alice_id), "alice's mirror: she is lying down")
	assert_true(_mirror(b).is_resting(alice_id), "bob's mirror: alice is lying down (an observable fact)")
	assert_false(_mirror(b).is_resting(bob_id), "bob's mirror: he is standing")

	# Her move intents are ignored while she rests.
	var position: Vector3 = _world.get_player(alice_id).position
	await _push_move(a, 30)
	assert_eq(_world.get_player(alice_id).position, position, "server: a resting player does not move")
	assert_true(_survival().is_resting(alice_id), "a move intent does not wake her")

	# Rest lowers her fatigue; her own mirror follows, bob's fatigue stays.
	assert_true(await _wait(func() -> bool: return _vitals(alice_id).fatigue < _config.survival.need_caution_threshold - RESTED_MARGIN), "server: alice's fatigue fell (%f)" % _vitals(alice_id).fatigue)
	await _assert_mirrors_match([a, b], "alice rested")
	assert_eq(_mirror(a).need_category("fatigue"), "good", "alice's mirror: her fatigue is good again")
	assert_true(absf(_vitals(bob_id).fatigue - TIRED) < 0.01, "server: bob, standing, is as tired as before")
	assert_eq(_mirror(b).need_category("fatigue"), "danger", "bob's mirror shows his own fatigue")

	# Alice gets up and can walk again.
	assert_eq(await _request_rest(a, false), [true, ""])
	assert_false(_survival().is_resting(alice_id))
	await _assert_mirrors_match([a, b], "alice up")
	assert_false(_mirror(b).is_resting(alice_id), "bob's mirror: alice stands")
	await _push_move(a, 30)
	assert_true(_world.get_player(alice_id).position.x > position.x, "server: alice walks again")
	await _settle()

	# What alice was told about herself: lying down, the better fatigue, getting up.
	var a_types: Array = _types_of(a_events)
	assert_eq(a_types[0], SurvivalService.EVENT_PLAYER_REST_STARTED)
	assert_eq(a_types[a_types.size() - 1], SurvivalService.EVENT_PLAYER_REST_ENDED)
	assert_eq(a_events[a_events.size() - 1].get("cause", ""), SurvivalService.REST_END_REQUESTED, "the owner is told why the rest ended")
	assert_true(a_types.has(SurvivalService.EVENT_NEED_CATEGORY_CHANGED), "alice was told her fatigue category changed")
	# What bob was told: alice lay down, alice got up. No fatigue, no cause.
	assert_eq(_types_of(b_events), [SurvivalService.EVENT_PLAYER_REST_STARTED, SurvivalService.EVENT_PLAYER_REST_ENDED], "bob: %s" % str(b_events))
	for event: Dictionary in b_events:
		assert_eq(str(event.get("player_id", "")), alice_id)
		assert_eq(str(event.get("scope", "")), ClientSurvivalState.SCOPE_PUBLIC)
		var keys: Array = event.keys()
		keys.sort()
		assert_eq(keys, PUBLIC_REST_KEYS, "a public rest event carries nothing else")
		var text: String = JSON.stringify(event).to_lower()
		for word: String in PRIVATE_WORDS:
			assert_not_contains(text, word, "bob was told something private")
	assert_eq(b_results.size(), 0, "the result goes to the requester only")
	# Move intents travel unreliably: a reordered one is counted as stale. Nothing else was refused.
	assert_eq(_cluster.server.rejected_intent_count() - _cluster.server.rejected_intent_count(ServerWorld.REASON_STALE_SEQUENCE), 0)


# ------------------------------------------------------------ 2. a zombie wakes a resting player

func test_a_zombie_attack_wakes_a_resting_player() -> void:
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	# Bob stands behind where the zombie will be: it only sees alice.
	_world.get_player(bob_id).position = Vector3(0.0, 0.0, 8.0)
	assert_eq(await _request_rest(a, true), [true, ""])
	await _assert_mirrors_match([a, b], "alice lying")
	await _settle()
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	# A zombie next to alice, facing her (yaw 0 looks along -Z). The rules of
	# zombies are unchanged: a resting player is seen and attacked like any other.
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var spawned: ActionResult = zombies.spawn_zombie(_world, Vector3(0.0, 0.0, 1.0), 0.0)
	assert_true(spawned.ok, spawned.reason)
	var zombie_id: String = str(spawned.event.get("zombie_id", ""))

	assert_true(await _wait(func() -> bool: return not _survival().is_resting(alice_id)), "server: the attack woke alice")
	# The zombie did its part; put it down before it kills her.
	assert_true(zombies.apply_damage_to_zombie(zombie_id, LETHAL_DAMAGE, alice_id).ok)
	assert_true(_survival().is_alive(alice_id), "alice survived the first hit")
	assert_true(_vitals(alice_id).injuries.size() >= 1, "server: alice was wounded")
	await _assert_mirrors_match([a, b], "alice woken")
	assert_false(_mirror(a).is_resting(alice_id), "alice's mirror: she is up")
	assert_false(_mirror(b).is_resting(alice_id), "bob's mirror: alice is up")
	await _settle()

	# Alice: the wound, then the waking with its cause.
	var a_about: Array[Dictionary] = _events_about(a_events, alice_id)
	var a_types: Array = _types_of(a_about)
	var wounded_at: int = a_types.find(SurvivalService.EVENT_PLAYER_WOUNDED)
	var ended_at: int = a_types.find(SurvivalService.EVENT_PLAYER_REST_ENDED)
	assert_true(wounded_at >= 0 and ended_at > wounded_at, "alice: the hit, then the waking: %s" % str(a_types))
	assert_eq(a_about[ended_at].get("cause", ""), SurvivalService.REST_END_DAMAGED)
	# Bob: the observable hit and that alice got up; no cause, no numbers.
	var b_about: Array[Dictionary] = _events_about(b_events, alice_id)
	var b_types: Array = _types_of(b_about)
	assert_true(b_types.has(SurvivalService.EVENT_PLAYER_WOUNDED) and b_types.has(SurvivalService.EVENT_PLAYER_REST_ENDED), "bob: %s" % str(b_types))
	for event: Dictionary in b_about:
		assert_eq(str(event.get("scope", "")), ClientSurvivalState.SCOPE_PUBLIC)
		assert_false(event.has("cause") or event.has("health_after") or event.has("damage"), "public event carries private data: %s" % str(event))
	# After waking she may lie down again.
	assert_eq(await _request_rest(a, true), [true, ""])


# ------------------------------------------------------------ 3. what a resting player cannot do, and death

func test_a_resting_player_cannot_attack_or_handle_items_and_death_ends_the_rest() -> void:
	assert_true(_start_server(), "server started")
	var item_id: String = _world.inventory.spawn_world_item("dev_test_item", 1, CELL, ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	assert_eq(await _request_rest(a, true), [true, ""])
	var combat: CombatNetModule = a.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule
	var attacks: Array[Array] = []
	combat.melee_result.connect(func(request_id: int, ok: bool, reason: String) -> void: attacks.append([request_id, ok, reason]))
	var pickups: Array[Array] = []
	a.pickup_result.connect(func(request_id: int, ok: bool, reason: String) -> void: pickups.append([request_id, ok, reason]))
	var stamina: float = _vitals(alice_id).stamina

	var attack_id: int = combat.request_melee_attack(AIM_MINUS_Z)
	var pickup_id: int = a.request_pickup(item_id)
	assert_true(await _wait(func() -> bool: return attacks.size() == 1 and pickups.size() == 1), "both requests were answered")
	assert_eq(attacks, [[attack_id, false, SurvivalService.REASON_PLAYER_RESTING]], "no attack while resting")
	assert_eq(pickups, [[pickup_id, false, SurvivalService.REASON_PLAYER_RESTING]], "no pickup while resting")
	assert_eq(_vitals(alice_id).stamina, stamina, "the refused attack cost nothing")
	assert_true(_world.inventory.world_item_ids().has(item_id), "the item still lies in the world")
	assert_true(_survival().is_resting(alice_id), "refused requests do not wake her")
	assert_eq(_cluster.server.rejected_intent_count(SurvivalService.REASON_PLAYER_RESTING), 2)

	# A sleeper is killed: the rest ends, then the death. Everybody agrees.
	# P2-T10: the hit taken asleep wakes her and leaves her alive; the next
	# one, on an awake player, kills.
	await _settle()
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	assert_true(_survival().apply_damage(alice_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok, "test setup: hit sleeping alice")
	assert_true(_survival().is_alive(alice_id), "server: the hit taken asleep did not kill")
	assert_false(_survival().is_resting(alice_id), "server: the hit woke her")
	assert_true(_survival().apply_damage(alice_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok, "test setup: kill alice")
	assert_false(_survival().is_alive(alice_id), "server: the second hit killed")
	assert_false(_survival().is_resting(alice_id), "server: a dead character does not rest")
	assert_true(await _wait(func() -> bool: return not _mirror(b).is_alive(alice_id) and not _mirror(a).is_alive(alice_id)), "both clients saw the death")
	await _assert_mirrors_match([a, b], "alice dead")
	assert_false(_mirror(a).is_resting(alice_id))
	assert_false(_mirror(b).is_resting(alice_id))
	await _settle()
	var a_types: Array = _types_of(_events_about(a_events, alice_id))
	assert_true(a_types.find(SurvivalService.EVENT_PLAYER_REST_ENDED) >= 0 and a_types.find(SurvivalService.EVENT_PLAYER_REST_ENDED) < a_types.find(SurvivalService.EVENT_PLAYER_DIED), "alice: %s" % str(a_types))
	var b_types: Array = _types_of(_events_about(b_events, alice_id))
	assert_true(b_types.find(SurvivalService.EVENT_PLAYER_REST_ENDED) >= 0 and b_types.find(SurvivalService.EVENT_PLAYER_REST_ENDED) < b_types.find(SurvivalService.EVENT_PLAYER_DIED), "bob: %s" % str(b_types))
	# A dead player cannot lie down.
	assert_eq(await _request_rest(a, true), [false, SurvivalService.REASON_PLAYER_DEAD])
	assert_false(_survival().is_resting(alice_id))


# ------------------------------------------------------------ 4. manipulated requests

func test_manipulated_rest_requests_are_rejected_and_change_nothing() -> void:
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var a_results: Array[Array] = _rest_results_of(a)
	var b_results: Array[Array] = _rest_results_of(b)
	var server: NetworkService = _cluster.server
	var module: SurvivalNetModule = _module(a)

	# Malformed arguments: nobody lies down.
	module.send_raw_rest_request("x", true)
	module.send_raw_rest_request(1, 1)
	module.send_raw_rest_request(2, null)
	module.send_raw_rest_request(3, "true")
	module.send_raw_rest_request(-1, true)
	module.send_raw_rest_request(4.0, true)
	module.send_raw_rest_request(5, [true])
	module.send_raw_rest_request(6, bob_id)
	const MALFORMED: int = 8
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == MALFORMED), "every malformed request was rejected (%d)" % server.rejected_intent_count())
	# A request cannot name the player to put down or wake: the handler takes
	# two arguments and the engine refuses a call with more (reported as an
	# engine error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_rest.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, true, bob_id)
	await _settle()
	Engine.print_error_messages = true
	assert_eq(a_results, [
		[1, false, IntentValidator.REASON_BAD_TYPE],
		[2, false, IntentValidator.REASON_BAD_TYPE],
		[3, false, IntentValidator.REASON_BAD_TYPE],
		[5, false, IntentValidator.REASON_BAD_TYPE],
		[6, false, IntentValidator.REASON_BAD_TYPE],
	], "answers go to usable request ids only, in order")
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE), 7)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_SEQUENCE), 1)
	assert_eq(server.rejected_intent_count(), MALFORMED, "the call the engine refused never reached the handler")
	assert_false(_survival().is_resting(alice_id) or _survival().is_resting(bob_id), "nobody rests")

	# Wrong state: getting up while standing, lying down twice.
	a_results.clear()
	module.send_raw_rest_request(10, false)
	module.send_raw_rest_request(11, true)
	module.send_raw_rest_request(12, true)
	assert_true(await _wait(func() -> bool: return a_results.size() == 3), "alice was answered")
	assert_eq(a_results, [
		[10, false, SurvivalService.REASON_NOT_RESTING],
		[11, true, ""],
		[12, false, SurvivalService.REASON_ALREADY_RESTING],
	])
	assert_true(_survival().is_resting(alice_id))
	# Bob cannot wake alice: his request is about himself only.
	_module(b).send_raw_rest_request(1, false)
	assert_true(await _wait(func() -> bool: return b_results.size() == 1), "bob was answered")
	assert_eq(b_results, [[1, false, SurvivalService.REASON_NOT_RESTING]])
	assert_true(_survival().is_resting(alice_id), "alice still rests")
	assert_false(_survival().is_resting(bob_id))
	await _assert_mirrors_match([a, b], "after the manipulated requests")

	# Forged server messages: a client cannot tell another client that
	# somebody lies down or answer a request. Real ENet path: the engine
	# refuses these (the sender is not the authority) and reports each as an
	# engine error, the expected outcome, so printing is off for this block.
	var b_events: Array[Dictionary] = _survival_events_of(b)
	var server_results: Array[Array] = _rest_results_of(server)
	b_results.clear()
	Engine.print_error_messages = false
	for target: int in [NetworkService.SERVER_PEER_ID, b.multiplayer.get_unique_id()]:
		module._rpc_rest_result.rpc_id(target, FORGED_REQUEST_ID, true, "")
		module._rpc_survival_status.rpc_id(target, {"player_id": bob_id, "alive": true, "resting": true})
		module._rpc_survival_events.rpc_id(target, [{"scope": "public", "event_type": SurvivalService.EVENT_PLAYER_REST_STARTED, "player_id": bob_id, "world_time": 1.0}])
	await _settle()
	Engine.print_error_messages = true
	# Script-level guard, independent of the engine (sender id 0 here), and a
	# client never acts on a request addressed to it.
	_module(b)._rpc_rest_result(FORGED_REQUEST_ID, true, "")
	_module(b)._rpc_survival_status({"player_id": bob_id, "alive": true, "resting": true})
	_module(b)._rpc_survival_events([{"scope": "public", "event_type": SurvivalService.EVENT_PLAYER_REST_STARTED, "player_id": bob_id, "world_time": 1.0}])
	_module(b)._rpc_request_rest(FORGED_REQUEST_ID, true)
	await _settle()
	assert_eq(b_results.size() + server_results.size() + b_events.size(), 0, "nothing forged was delivered")
	assert_false(_mirror(b).is_resting(bob_id), "bob's mirror was not changed")
	assert_false(_survival().is_resting(bob_id))
	assert_eq(server.rejected_intent_count(), MALFORMED + 3, "only the three wrong-state requests were added")


func test_rest_request_before_join_is_rejected() -> void:
	assert_true(_start_server(), "server started")
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var results: Array[Array] = _rest_results_of(stranger)
	var connected: bool = await _wait(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	assert_eq(_module(stranger).request_rest(true), SurvivalNetModule.NO_REQUEST, "the client API sends nothing before the join")
	_module(stranger).send_raw_rest_request(1, true)
	assert_true(await _wait(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 1), "the server refused the request of a peer that has not joined")
	await _settle()
	assert_eq(_cluster.server.rejected_intent_count(), 1, "exactly the raw request reached the server")
	assert_eq(results.size(), 0, "an unjoined peer is told nothing")
	assert_eq(_world.online_player_ids().size(), 0)


func test_rest_flood_is_rate_limited_per_peer() -> void:
	const BURST: int = 2
	const FLOOD: int = 6
	# One new token every 100 seconds: only the burst passes within the test.
	_config.survival_net.rest_intent_rate_per_sec = 0.01
	_config.survival_net.rest_intent_burst = BURST
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var a_results: Array[Array] = _rest_results_of(a)
	var requests: Array = []
	# Down, up, down, up, ...
	for index: int in range(FLOOD):
		requests.append(_module(a).request_rest(index % 2 == 0))
	assert_true(await _wait(func() -> bool: return a_results.size() == FLOOD), "every request was answered (%d)" % a_results.size())
	await _settle()
	var expected: Array = []
	for index: int in range(FLOOD):
		expected.append([requests[index], true, ""] if index < BURST else [requests[index], false, NetworkService.RATE_LIMITED])
	assert_eq(a_results, expected, "only the burst is accepted")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST, "rejection counter")
	assert_false(_survival().is_resting(alice_id), "down and up again: the refused requests changed nothing")
	# The bucket is per peer: bob can still lie down.
	assert_eq(await _request_rest(b, true), [true, ""])


# ------------------------------------------------------------ 5. joining, leaving, restarting

func test_late_joiners_see_who_rests_and_leaving_ends_the_rest() -> void:
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	assert_eq(await _request_rest(a, true), [true, ""])
	await _assert_mirrors_match([a, b], "alice lying")
	# A late joiner learns it from the join snapshot.
	var c: NetworkService = await _cluster.join_client("carol")
	assert_not_null(c, "carol joined")
	if c == null:
		return
	assert_true(_mirror(c).is_resting(alice_id), "carol's mirror: alice is lying down")
	assert_false(_mirror(c).is_resting(c.client_state.local_player_id))
	await _assert_mirrors_match([a, b, c], "carol joined")
	# The newcomer's arrival does not disturb the others' view.
	assert_true(_mirror(b).is_resting(alice_id))

	# Alice leaves while lying down: the rest ends with her session.
	_cluster.remove_client(a)
	assert_true(await _wait(func() -> bool: return not _world.is_online(alice_id)), "alice left")
	assert_false(_survival().is_resting(alice_id), "server: an offline player does not rest")
	assert_true(await _wait(func() -> bool: return not _mirror(b).has_player(alice_id) and not _mirror(c).has_player(alice_id)), "the others dropped alice")
	assert_false(_mirror(b).is_resting(alice_id))
	var a2: NetworkService = await _cluster.join_client("alice")
	assert_not_null(a2, "alice rejoined")
	if a2 == null:
		return
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	assert_false(_survival().is_resting(alice_id), "server: she stands after rejoining")
	await _assert_mirrors_match([a2, b, c], "alice rejoined")
	assert_false(_mirror(a2).is_resting(alice_id))
	assert_false(_mirror(b).is_resting(alice_id))
	# And she can lie down again.
	assert_eq(await _request_rest(a2, true), [true, ""])
	await _assert_mirrors_match([a2, b, c], "alice lying again")


func test_rest_is_not_saved_and_fatigue_survives_a_server_restart() -> void:
	_save_root = "user://test_saves/rest_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	_vitals(alice_id).fatigue = TIRED
	_vitals(bob_id).fatigue = TIRED
	var save: SaveService = SaveService.new(_save_root)
	var generation: int = save.current_generation(WORLD)
	assert_eq(await _request_rest(a, true), [true, ""])
	await _settle()
	assert_eq(save.current_generation(WORLD), generation, "lying down does not write the world")
	assert_true(await _wait(func() -> bool: return _vitals(alice_id).fatigue < _config.survival.need_caution_threshold - RESTED_MARGIN), "alice rested")
	# The saved player document knows nothing about resting.
	var survival_fragment: Dictionary = ((_world.to_documents()["players"] as Dictionary)[alice_id] as Dictionary)[ServerWorld.KEY_SYSTEMS][SurvivalService.SYSTEM_ID]
	for key: Variant in survival_fragment.keys():
		assert_not_contains(str(key), "rest", "the survival fragment has a rest field")
	assert_eq(int(survival_fragment["schema_version"]), PlayerVitals.SCHEMA_VERSION)

	# --- full restart while alice is lying down: the clients quit (which
	# ends her rest), then the server saves and stops ---
	await _cluster.shutdown()
	_cluster = null
	var fatigue_at_shutdown: float = _vitals(alice_id).fatigue
	_world = null
	var persistence2: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence2.load_or_create(WORLD)
	assert_not_null(_world, "world restored from save")
	if _world == null:
		return
	assert_true(absf(_vitals(alice_id).fatigue - fatigue_at_shutdown) < 0.01, "the lowered fatigue was saved: %f vs %f" % [_vitals(alice_id).fatigue, fatigue_at_shutdown])
	assert_true(absf(_vitals(bob_id).fatigue - TIRED) < 0.01, "bob is as tired as he was")
	assert_false(_survival().is_resting(alice_id), "nobody rests after a restart")
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	var b2: NetworkService = await _cluster.join_client("bob")
	if a2 == null or b2 == null:
		fail("clients did not rejoin")
		return
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	await _assert_mirrors_match([a2, b2], "session 2")
	assert_false(_mirror(a2).is_resting(alice_id), "session 2: alice stands")
	assert_false(_mirror(b2).is_resting(alice_id))
	assert_eq(_mirror(a2).need_category("fatigue"), "good", "server fatigue %f (at shutdown %f)" % [_vitals(alice_id).fatigue, fatigue_at_shutdown])
	assert_eq(_mirror(b2).need_category("fatigue"), "danger")
	# She can move and lie down again in the new session.
	var position: Vector3 = _world.get_player(alice_id).position
	await _push_move(a2, 30)
	assert_true(_world.get_player(alice_id).position.x > position.x, "session 2: alice walks")
	assert_eq(await _request_rest(a2, true), [true, ""])
	await _assert_mirrors_match([a2, b2], "session 2: alice lying")


# ------------------------------------------------------------ rules (no network)

func test_default_settings_protocol_and_request_validation() -> void:
	var settings: SurvivalNetSettings = SurvivalNetSettings.load_or_default()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	assert_true(settings.rest_intent_rate_per_sec > 0.0 and settings.rest_intent_burst >= 1)
	var broken: SurvivalNetSettings = SurvivalNetSettings.new()
	broken.rest_intent_rate_per_sec = 0.0
	assert_eq(broken.validate().size(), 1, "; ".join(broken.validate()))
	assert_eq(BuildInfo.PROTOCOL_VERSION, 11, "the rest RPCs and the new survival snapshot format were a protocol change (6); 7 since the character RPCs (P2-T9), 8 since the new wake causes (P2-T10), 9 since the hand-over RPCs (P2-T14), 10 since they were withdrawn and the drop intent got a quantity (P2-T15), 11 since the trade RPCs (P2-T16)")
	assert_eq(SurvivalNetModule.SCHEMA_VERSION, 3, "the owner snapshot and the status rows carry `resting`")
	assert_eq(SurvivalNetModule.SCHEMA_VERSION, ClientSurvivalState.SCHEMA_VERSION, "server and client agree on the format")
	assert_eq(SurvivalNetModule.validate_rest_request(1, true), "")
	assert_eq(SurvivalNetModule.validate_rest_request(0, false), "")
	assert_eq(SurvivalNetModule.validate_rest_request("1", true), IntentValidator.REASON_BAD_TYPE)
	assert_eq(SurvivalNetModule.validate_rest_request(1.0, true), IntentValidator.REASON_BAD_TYPE)
	assert_eq(SurvivalNetModule.validate_rest_request(1, 1), IntentValidator.REASON_BAD_TYPE, "an int is not a bool")
	assert_eq(SurvivalNetModule.validate_rest_request(1, null), IntentValidator.REASON_BAD_TYPE)
	assert_eq(SurvivalNetModule.validate_rest_request(-1, true), IntentValidator.REASON_BAD_SEQUENCE)
	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	var module: SurvivalNetModule = service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule
	assert_eq(module.request_rest(true), SurvivalNetModule.NO_REQUEST, "nothing is sent while offline")
	# Channel 0, reliable; the rest request from any peer, everything else only from the server.
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	var expected_modes: Dictionary[String, int] = {
		"_rpc_request_rest": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_rest_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_survival_owner_snapshot": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_survival_status": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_survival_events": MultiplayerAPI.RPC_MODE_AUTHORITY,
	}
	assert_eq(rpc_config.size(), expected_modes.size(), "no other RPC exists")
	for method: String in expected_modes:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), expected_modes[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	service.free()


func test_the_client_mirror_validates_rest_payloads() -> void:
	const ME: String = "player_000001"
	const OTHER: String = "player_000002"
	var mirror: ClientSurvivalState = ClientSurvivalState.new(SurvivalNetSettings.new(), SurvivalSettings.new())
	var own: Dictionary = {
		"schema_version": ClientSurvivalState.SCHEMA_VERSION, "player_id": ME, "alive": true,
		"health": 50.0, "stamina": 50.0,
		"needs": {"hunger": "good", "thirst": "good", "fatigue": "danger"},
		"wounds": [], "infection_stage": "none", "character_generation": 1, "resting": false,
	}
	var fragment: Dictionary = {"schema_version": ClientSurvivalState.SCHEMA_VERSION, "self": own, "players": [
		{"player_id": ME, "alive": true, "resting": false},
		{"player_id": OTHER, "alive": true, "resting": true},
	]}
	assert_true(mirror.apply_join(ME, fragment))
	assert_false(mirror.is_resting(ME))
	assert_true(mirror.is_resting(OTHER), "the join fragment says who is lying down")
	assert_false(mirror.is_resting("player_999999"), "unknown players do not rest")
	var changes: Array[Array] = []
	mirror.player_resting_changed.connect(func(player_id: String, resting: bool) -> void: changes.append([player_id, resting]))
	# The owner snapshot carries the own state.
	var lying: Dictionary = own.duplicate(true)
	lying["resting"] = true
	assert_true(mirror.apply_owner_snapshot(lying))
	assert_true(mirror.is_resting(ME))
	# Public events about another player.
	assert_eq(mirror.apply_event_batch([{"scope": "public", "event_type": SurvivalService.EVENT_PLAYER_REST_ENDED, "player_id": OTHER, "world_time": 5.0}]), 1)
	assert_false(mirror.is_resting(OTHER))
	assert_eq(mirror.apply_event_batch([{"scope": "public", "event_type": SurvivalService.EVENT_PLAYER_REST_STARTED, "player_id": OTHER, "world_time": 6.0}]), 1)
	assert_true(mirror.is_resting(OTHER))
	# Owner events about oneself (with the cause).
	assert_eq(mirror.apply_event_batch([{"scope": "owner", "event_type": SurvivalService.EVENT_PLAYER_REST_ENDED, "player_id": ME, "cause": SurvivalService.REST_END_DAMAGED, "world_time": 7.0}]), 1)
	assert_false(mirror.is_resting(ME))
	assert_eq(changes, [[ME, true], [OTHER, false], [OTHER, true], [ME, false]], "one notification per change")
	# A status row (somebody joined) and a death.
	assert_true(mirror.apply_player_status({"player_id": "player_000003", "alive": true, "resting": false}))
	assert_eq(mirror.apply_event_batch([{"scope": "public", "event_type": SurvivalService.EVENT_PLAYER_DIED, "player_id": OTHER, "world_time": 8.0}]), 1)
	assert_false(mirror.is_resting(OTHER), "a dead player does not rest")
	mirror.remove_player(OTHER)
	assert_false(mirror.is_resting(OTHER))

	# Refused payloads change nothing.
	var bad_events: Array = [
		{"scope": "public", "event_type": SurvivalService.EVENT_PLAYER_REST_STARTED, "player_id": ME, "world_time": 9.0, "fatigue": 10.0},
		{"scope": "public", "event_type": SurvivalService.EVENT_PLAYER_REST_ENDED, "player_id": ME, "cause": "damaged", "world_time": 9.0},
		{"scope": "owner", "event_type": SurvivalService.EVENT_PLAYER_REST_STARTED, "player_id": "player_000003", "world_time": 9.0},
		{"scope": "owner", "event_type": SurvivalService.EVENT_PLAYER_REST_ENDED, "player_id": ME, "world_time": 9.0},
		{"scope": "owner", "event_type": SurvivalService.EVENT_PLAYER_REST_ENDED, "player_id": ME, "cause": "bored", "world_time": 9.0},
		{"scope": "public", "event_type": SurvivalService.EVENT_PLAYER_REST_STARTED, "player_id": ME, "world_time": -1.0},
		{"scope": "public", "event_type": SurvivalService.EVENT_PLAYER_REST_STARTED, "player_id": ME},
	]
	assert_eq(mirror.apply_event_batch(bad_events), 0, "extra fields, missing or unknown causes, foreign owner events and bad times are refused")
	assert_false(mirror.is_resting(ME))
	for bad_status: Dictionary in [
		{"player_id": ME, "alive": true},
		{"player_id": ME, "alive": true, "resting": 1},
		{"player_id": ME, "alive": false, "resting": true},
		{"player_id": ME, "alive": true, "resting": true, "fatigue": 3.0},
	]:
		assert_false(mirror.apply_player_status(bad_status), "rejected: %s" % str(bad_status))
	var no_resting: Dictionary = own.duplicate(true)
	no_resting.erase("resting")
	assert_false(mirror.apply_owner_snapshot(no_resting), "the previous format is refused")
	var dead_resting: Dictionary = own.duplicate(true)
	dead_resting["alive"] = false
	dead_resting["health"] = 0.0
	dead_resting["resting"] = true
	assert_false(mirror.apply_owner_snapshot(dead_resting), "a dead character cannot rest")
	var previous_format: Dictionary = own.duplicate(true)
	previous_format["schema_version"] = ClientSurvivalState.SCHEMA_VERSION - 1
	assert_false(mirror.apply_owner_snapshot(previous_format))
	assert_false(mirror.is_resting(ME), "refused payloads change nothing")
