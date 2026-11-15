extends TestCase
## P2-T10: sleep tuning over real ENet (server + 2 clients).
##   - a sleeper woken by a danger (thirst here) is told why; the other player
##     only learns the observable fact "she got up" (docs/00 ADR-009)
##   - a player in danger cannot lie down, and does not flap between lying
##     down and waking
##   - a zombie hit that would kill leaves a sleeper alive and awake; a later
##     hit on the awake player kills
## Rules: tests/unit/sleep_tuning_test.gd.

const WORLD: String = "sleep_tuning_net_test_world"
const NEVER: float = 1.0e9
const WAIT_MSEC: int = 8000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const LETHAL_DAMAGE: float = 100000.0
## Needs that must not move on their own during a test.
const FROZEN_NEED_HOURS: float = 100000.0
## World hours for thirst to reach its maximum: about 0.67 per real second
## at 24x.
const FAST_THIRST_HOURS: float = 1.0
## How far below the danger threshold the sleeper's thirst starts (about 3
## real seconds of sleep).
const THIRST_MARGIN: float = 2.0
## Keys of the only events another player gets about somebody's rest.
const PUBLIC_REST_KEYS: Array = ["event_type", "player_id", "scope", "world_time"]
## Words that must not appear in anything another player receives.
const PRIVATE_WORDS: PackedStringArray = ["thirst", "hunger", "fatigue", "need", "cause", "health", "stamina", "danger"]

var _cluster: NetTestCluster = null
var _net_settings: NetworkSettings = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_net_settings = NetworkSettings.new()
	_net_settings.autosave_interval_sec = 0.0
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.hunger_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.thirst_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.fatigue_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.wound_recovery_per_world_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	# Only hits change health here.
	_config.survival.bleeding_bite_multiplier = 0.0
	_config.survival.bleeding_scratch_multiplier = 0.0
	_config.survival.infection_chance_bite = 0.0
	_config.survival.infection_chance_scratch = 0.0
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


func _module(service: NetworkService) -> SurvivalNetModule:
	return service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule


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


func _events_about(events: Array[Dictionary], player_id: String, event_type: String = "") -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("player_id", "")) == player_id and (event_type.is_empty() or str(event.get("event_type", "")) == event_type):
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
	return [rows[0][1], rows[0][2]]


# ------------------------------------------------------------ 1. woken by a danger

func test_a_sleeper_woken_by_thirst_knows_why_and_others_only_see_her_get_up() -> void:
	_config.survival.thirst_hours_to_max = FAST_THIRST_HOURS
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var danger: float = _config.survival.need_danger_threshold
	_vitals(alice_id).thirst = danger - THIRST_MARGIN
	await _settle()
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	var b_results: Array[Array] = _rest_results_of(b)

	# Thirsty but not yet in danger: alice may lie down.
	assert_eq(await _request_rest(a, true), [true, ""])
	assert_true(_survival().is_resting(alice_id), "server: alice sleeps")
	assert_true(await _wait(func() -> bool: return _mirror(b).is_resting(alice_id)), "bob's mirror: alice is lying down")
	# Her thirst reaches the danger category: the server wakes her.
	assert_true(await _wait(func() -> bool: return not _survival().is_resting(alice_id)), "server: thirst woke alice")
	assert_true(_survival().is_alive(alice_id))
	assert_true(_vitals(alice_id).thirst >= danger, "server: her thirst is dangerous (%f)" % _vitals(alice_id).thirst)
	assert_true(await _wait(func() -> bool: return not _mirror(a).is_resting(alice_id) and not _mirror(b).is_resting(alice_id)), "both mirrors: alice is up")
	assert_true(await _wait(func() -> bool: return _mirror(a).need_category("thirst") == "danger"), "alice's mirror: her thirst is dangerous")
	await _settle()

	# Alice is told why she woke.
	var a_ended: Array[Dictionary] = _events_about(a_events, alice_id, SurvivalService.EVENT_PLAYER_REST_ENDED)
	assert_eq(a_ended.size(), 1, "alice: %s" % str(_types_of(a_events)))
	assert_eq(a_ended[0].get("cause", ""), SurvivalService.REST_END_THIRST, "the owner event carries the cause")
	assert_eq(a_ended[0].get("scope", ""), ClientSurvivalState.SCOPE_OWNER)
	assert_contains(ClientPresentationFormatter.format_survival_notice(a_ended[0]), "갈증", "and her HUD can say it")
	# Bob learns that she lay down and got up, nothing else.
	var b_about: Array[Dictionary] = _events_about(b_events, alice_id)
	assert_eq(_types_of(b_about), [SurvivalService.EVENT_PLAYER_REST_STARTED, SurvivalService.EVENT_PLAYER_REST_ENDED], "bob: %s" % str(b_about))
	for event: Dictionary in b_about:
		assert_eq(str(event.get("scope", "")), ClientSurvivalState.SCOPE_PUBLIC)
		var keys: Array = event.keys()
		keys.sort()
		assert_eq(keys, PUBLIC_REST_KEYS, "a public rest event carries nothing else")
		var text: String = JSON.stringify(event).to_lower()
		for word: String in PRIVATE_WORDS:
			assert_not_contains(text, word, "bob was told something private")
	assert_eq(ClientPresentationFormatter.format_survival_notice(b_about[1]), "", "bob's HUD has nothing to say about it")

	# Still in danger: she cannot lie down again (no lying down / waking loop).
	a_events.clear()
	b_events.clear()
	for attempt: int in 3:
		assert_eq(await _request_rest(a, true), [false, SurvivalService.REASON_CANNOT_REST_PREFIX + SurvivalService.REST_END_THIRST], "attempt %d" % attempt)
		await _settle()
	assert_false(_survival().is_resting(alice_id))
	assert_eq(_events_about(a_events, alice_id, SurvivalService.EVENT_PLAYER_REST_STARTED).size(), 0)
	assert_eq(_events_about(b_events, alice_id).size(), 0, "bob is told nothing about the refused requests")
	assert_eq(b_results.size(), 0, "results go to the requester only")
	assert_eq(_cluster.server.rejected_intent_count(SurvivalService.REASON_CANNOT_REST_PREFIX + SurvivalService.REST_END_THIRST), 3)
	# Bob, not in danger, can still lie down.
	assert_eq(await _request_rest(b, true), [true, ""])
	assert_true(_survival().is_resting(bob_id))


# ------------------------------------------------------------ 2. a zombie hit on a sleeper

func test_a_zombie_hit_that_would_kill_leaves_a_sleeper_alive_and_awake() -> void:
	# Every zombie hit would kill a full-health player.
	_config.zombie.bite_damage = LETHAL_DAMAGE
	_config.zombie.scratch_damage = LETHAL_DAMAGE
	assert_true(_start_server(), "server started")
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var floor_health: float = _config.survival.rest_hit_min_health
	# Bob stands behind where the zombie will be: it only sees alice.
	_world.get_player(bob_id).position = Vector3(0.0, 0.0, 8.0)
	assert_eq(await _request_rest(a, true), [true, ""])
	assert_true(await _wait(func() -> bool: return _mirror(b).is_resting(alice_id)), "bob's mirror: alice is lying down")
	await _settle()
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	# A zombie next to alice, facing her (yaw 0 looks along -Z).
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var spawned: ActionResult = zombies.spawn_zombie(_world, Vector3(0.0, 0.0, 1.0), 0.0)
	assert_true(spawned.ok, spawned.reason)
	var zombie_id: String = str(spawned.event.get("zombie_id", ""))

	assert_true(await _wait(func() -> bool: return not _survival().is_resting(alice_id)), "server: the attack woke alice")
	# The zombie did its part; put it down before its next attack.
	assert_true(zombies.apply_damage_to_zombie(zombie_id, LETHAL_DAMAGE, alice_id).ok)
	assert_true(_survival().is_alive(alice_id), "server: the hit taken asleep did not kill alice")
	assert_true(absf(_vitals(alice_id).health - floor_health) < 0.001, "server: she is left with the floor health (%f)" % _vitals(alice_id).health)
	assert_eq(_vitals(alice_id).injuries.size(), 1, "server: the wound is hers")
	assert_true(await _wait(func() -> bool: return absf(_mirror(a).health() - floor_health) < 0.001 and not _mirror(a).is_resting(alice_id)), "alice's mirror: awake with the floor health (%f)" % _mirror(a).health())
	assert_true(_mirror(a).is_alive(alice_id))
	assert_true(await _wait(func() -> bool: return not _mirror(b).is_resting(alice_id)), "bob's mirror: alice is up")
	assert_true(_mirror(b).is_alive(alice_id), "bob's mirror: alice is alive")
	await _settle()

	# Alice: the wound that did not kill, then the waking with its cause.
	var a_wounded: Array[Dictionary] = _events_about(a_events, alice_id, SurvivalService.EVENT_PLAYER_WOUNDED)
	assert_eq(a_wounded.size(), 1)
	assert_eq(a_wounded[0].get("died", true), false)
	assert_true(absf(float(a_wounded[0].get("health_after", -1.0)) - floor_health) < 0.001)
	var a_ended: Array[Dictionary] = _events_about(a_events, alice_id, SurvivalService.EVENT_PLAYER_REST_ENDED)
	assert_eq(a_ended.size(), 1)
	assert_eq(a_ended[0].get("cause", ""), SurvivalService.REST_END_DAMAGED)
	assert_eq(_events_about(a_events, alice_id, SurvivalService.EVENT_PLAYER_DIED).size(), 0)
	# Bob: the observable hit (not deadly) and that she got up.
	var b_wounded: Array[Dictionary] = _events_about(b_events, alice_id, SurvivalService.EVENT_PLAYER_WOUNDED)
	assert_eq(b_wounded.size(), 1)
	assert_eq(b_wounded[0].get("died", true), false)
	for event: Dictionary in _events_about(b_events, alice_id):
		assert_eq(str(event.get("scope", "")), ClientSurvivalState.SCOPE_PUBLIC)
		assert_false(event.has("cause") or event.has("health_after") or event.has("damage"), "public event carries private data: %s" % str(event))

	# Awake now: the next hit follows the usual rules and kills.
	assert_true(_survival().apply_damage(alice_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_false(_survival().is_alive(alice_id), "server: a hit on an awake player kills")
	assert_true(await _wait(func() -> bool: return not _mirror(a).is_alive(alice_id) and not _mirror(b).is_alive(alice_id)), "both clients saw the death")
