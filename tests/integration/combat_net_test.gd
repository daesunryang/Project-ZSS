extends TestCase
## P2-N1b: melee attack intent RPC and combat event replication over real
## ENet (server + 2 clients): the server decides, the requester alone gets
## the result, every client gets the same events in the same order, and
## manipulated / forged messages change nothing.

const WORLD: String = "combat_net_test_world"
const MODULE_SCRIPT: String = "res://scripts/services/multiplayer/combat_net_module.gd"
const NEVER: float = 1.0e9
## Yaw 0 faces -Z.
const AIM_MINUS_Z: float = 0.0
const WEAPON_ID: String = "unarmed"
const DAMAGE: float = 40.0
const RANGE_M: float = 2.0
const ARC_DEG: float = 90.0
const ZOMBIE_HEALTH: float = 100.0
const ZOMBIE_AHEAD: Vector3 = Vector3(0.0, 0.0, -1.5)
const FAR_AWAY: Vector3 = Vector3(50.0, 0.0, 50.0)
const WAIT_MSEC: int = 5000
## Physics frames (server ticks) waited before asserting that nothing more
## arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 240.0
const GENEROUS_BURST: int = 240
const LONG_COOLDOWN_SEC: float = 1000.0
const HEAVY_STAMINA_COST: float = 60.0
const LETHAL_DAMAGE: float = 100000.0
const FORGED_SEQUENCE: int = 999
const FORGED_REQUEST_ID: int = 77

var _cluster: NetTestCluster = null
var _net_settings: NetworkSettings = null
var _combat_net: CombatNetSettings = null
var _config: CompositionConfig = null
var _weapon: MeleeWeaponDefinition = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_net_settings = NetworkSettings.new()
	_net_settings.autosave_interval_sec = 0.0
	_combat_net = CombatNetSettings.new()
	# Out of the way unless a test is about the limiter.
	_combat_net.melee_intent_rate_per_sec = GENEROUS_RATE
	_combat_net.melee_intent_burst = GENEROUS_BURST
	_weapon = MeleeWeaponDefinition.new()
	_weapon.weapon_id = WEAPON_ID
	_weapon.display_name = WEAPON_ID
	_weapon.category = MeleeWeaponDefinition.Category.UNARMED
	_weapon.base_damage = DAMAGE
	_weapon.range_m = RANGE_M
	_weapon.arc_angle_deg = ARC_DEG
	_weapon.cooldown_sec = 0.0
	_weapon.stamina_cost = 0.0
	_weapon.noise_loudness = 0.0
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	# Survival time rules are off: no regeneration, healing or respawn.
	_config.survival = SurvivalSettings.new()
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.wound_recovery_per_world_sec = 0.0
	_config.survival.stamina_regen_per_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	_config.noise = NoiseSettings.new()
	# No footsteps.
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	# Zombies are placed by the tests, never see, never move, never attack.
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.wander_pause_min_sec = NEVER
	_config.zombie.wander_pause_max_sec = NEVER
	_config.zombie.sight_range_m = 0.0
	_config.zombie.wander_speed_mps = 0.0
	_config.zombie.investigate_speed_mps = 0.0
	_config.zombie.chase_speed_mps = 0.0
	_config.zombie.search_speed_mps = 0.0
	# Exact damage, one weapon.
	_config.combat = CombatSettings.new()
	_config.combat.damage_roll_min = 1.0
	_config.combat.damage_roll_max = 1.0
	_config.combat.inventory_weapon_rule = CombatSettings.WeaponRule.UNARMED_ONLY
	_config.melee_weapons = MeleeWeaponCatalog.new()
	_config.melee_weapons.add(_weapon)
	_config.combat_net = _combat_net
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	_world = null


func after_each() -> void:
	Engine.print_error_messages = true
	await _cluster.shutdown()
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _start_server() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(DevWorldSeed.new())
	return _cluster.start_server(_world, null) == OK


## Starts the server and joins "alice" and "bob". Empty on failure.
func _start_with_two_clients() -> Array[NetworkService]:
	var joined: Array[NetworkService] = []
	if not _start_server():
		fail("server did not start")
		return joined
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return joined
	joined.append(a)
	joined.append(b)
	return joined


func _module(service: NetworkService) -> CombatNetModule:
	return service.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule


func _combat() -> CombatService:
	return _world.get_system(CombatService.SYSTEM_ID) as CombatService


func _zombies() -> ZombieService:
	return _world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _spawn(position: Vector3) -> String:
	return str(_zombies().spawn_zombie(_world, position).event.get("zombie_id", ""))


func _health(zombie_id: String) -> float:
	return _zombies().get_zombie(zombie_id).health


func _stamina(player_id: String) -> float:
	return _survival().get_vitals(player_id).stamina


## Rows [request_id, ok, reason] of every result signal of `service`.
func _results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).melee_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Every event signal of `service`, in arrival order.
func _events_of(service: NetworkService) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	_module(service).combat_event.connect(func(event: Dictionary) -> void: rows.append(event))
	return rows


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


func _column(events: Array[Dictionary], key: String) -> Array:
	var values: Array = []
	for event: Dictionary in events:
		values.append(event.get(key, null))
	return values


## A well-formed public event, as the server would broadcast it.
func _public_event(sequence: int) -> Dictionary:
	return {
		ClientCombatState.KEY_SEQUENCE: sequence,
		ClientCombatState.KEY_EVENT_TYPE: ClientCombatState.EVENT_MELEE_ATTACK,
		ClientCombatState.KEY_ATTACKER_ID: "player_000001",
		ClientCombatState.KEY_WEAPON_ID: WEAPON_ID,
		ClientCombatState.KEY_AIM_YAW: 0.5,
		ClientCombatState.KEY_POSITION: Vector3(1.0, 0.0, 2.0),
		ClientCombatState.KEY_HIT: true,
		ClientCombatState.KEY_TARGET_ID: "zombie_000002",
		ClientCombatState.KEY_TARGET_DIED: false,
		ClientCombatState.KEY_WORLD_TIME: 12.5,
		ClientCombatState.KEY_DAMAGE: 8.0,
		ClientCombatState.KEY_TARGET_HEALTH_AFTER: 92.0,
	}


# ------------------------------------------------------------ 1. one attack

func test_attack_hits_the_zombie_and_both_clients_get_the_same_event() -> void:
	var clients: Array[NetworkService] = await _start_with_two_clients()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var zombie_id: String = _spawn(ZOMBIE_AHEAD)
	var a_results: Array[Array] = _results_of(a)
	var b_results: Array[Array] = _results_of(b)
	var a_events: Array[Dictionary] = _events_of(a)
	var b_events: Array[Dictionary] = _events_of(b)

	var request_id: int = _module(a).request_melee_attack(AIM_MINUS_Z)
	assert_true(request_id > 0, "a joined client gets a request id")
	var done: bool = await _wait(func() -> bool: return a_results.size() == 1 and a_events.size() == 1 and b_events.size() == 1)
	assert_true(done, "result and events arrived (results %d, events %d/%d)" % [a_results.size(), a_events.size(), b_events.size()])
	if not done:
		return
	await _settle()

	assert_eq(_health(zombie_id), ZOMBIE_HEALTH - DAMAGE, "the server's zombie lost health")
	assert_eq(a_results, [[request_id, true, ""]], "the requester gets one success result")
	assert_eq(b_results.size(), 0, "the other client never gets the requester's result")
	assert_eq(a_events.size(), 1)
	assert_eq(b_events.size(), 1)
	var event: Dictionary = a_events[0]
	assert_eq(b_events[0], event, "both clients received the same event")
	assert_eq(_module(_cluster.server).recent_events(), [event], "... and it is what the server broadcast")
	assert_eq(_module(a).recent_events(), [event], "client mirror (A)")
	assert_eq(_module(b).recent_events(), [event], "client mirror (B)")
	assert_eq(_module(b).last_event_sequence(), 1)
	# The whole payload, decided from server state.
	var world_time: Variant = event.get(ClientCombatState.KEY_WORLD_TIME, null)
	assert_true(typeof(world_time) == TYPE_FLOAT and float(world_time) >= 0.0 and float(world_time) <= _world.clock.world_time_sec, "world_time is the server clock")
	assert_eq(event, {
		ClientCombatState.KEY_SEQUENCE: 1,
		ClientCombatState.KEY_EVENT_TYPE: CombatService.EVENT_MELEE_ATTACK,
		ClientCombatState.KEY_ATTACKER_ID: alice_id,
		ClientCombatState.KEY_WEAPON_ID: WEAPON_ID,
		ClientCombatState.KEY_AIM_YAW: AIM_MINUS_Z,
		ClientCombatState.KEY_POSITION: _world.get_player(alice_id).position,
		ClientCombatState.KEY_HIT: true,
		ClientCombatState.KEY_TARGET_ID: zombie_id,
		ClientCombatState.KEY_TARGET_DIED: false,
		ClientCombatState.KEY_WORLD_TIME: world_time,
		ClientCombatState.KEY_DAMAGE: DAMAGE,
		ClientCombatState.KEY_TARGET_HEALTH_AFTER: ZOMBIE_HEALTH - DAMAGE,
	})
	assert_eq(_combat().drain_events().size(), 0, "the module is the consumer of the combat event queue")


# ------------------------------------------------------------ 2. until death

func test_attacks_until_the_zombie_dies_give_both_clients_the_same_event_sequence() -> void:
	var clients: Array[NetworkService] = await _start_with_two_clients()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var zombie_id: String = _spawn(ZOMBIE_AHEAD)
	var a_results: Array[Array] = _results_of(a)
	var b_results: Array[Array] = _results_of(b)
	var a_events: Array[Dictionary] = _events_of(a)
	var b_events: Array[Dictionary] = _events_of(b)

	# Two attackers in the same frame: the server's order is the only order.
	_module(a).request_melee_attack(AIM_MINUS_Z)
	_module(b).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return a_events.size() == 2 and b_events.size() == 2), "first two swings replicated")
	# The killing blow, then a swing at the corpse.
	_module(a).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return a_events.size() == 3 and b_events.size() == 3), "killing blow replicated")
	_module(b).request_melee_attack(AIM_MINUS_Z)
	var done: bool = await _wait(func() -> bool: return a_events.size() == 4 and b_events.size() == 4 and a_results.size() == 2 and b_results.size() == 2)
	assert_true(done, "all four swings replicated (%d/%d)" % [a_events.size(), b_events.size()])
	if not done:
		return
	await _settle()

	assert_false(_zombies().get_zombie(zombie_id).is_alive(), "the server's zombie is dead")
	assert_eq(a_events.size(), 4, "no extra events")
	assert_eq(a_events, b_events, "both clients received the same events in the same order")
	assert_eq(_module(_cluster.server).recent_events(), a_events, "... the order the server broadcast")
	assert_eq(_module(a).recent_events(), _module(b).recent_events(), "mirrors agree")
	assert_eq(_column(a_events, ClientCombatState.KEY_SEQUENCE), [1, 2, 3, 4])
	assert_eq(_column(a_events, ClientCombatState.KEY_HIT), [true, true, true, false])
	assert_eq(_column(a_events, ClientCombatState.KEY_TARGET_ID), [zombie_id, zombie_id, zombie_id, ""])
	assert_eq(_column(a_events, ClientCombatState.KEY_TARGET_HEALTH_AFTER), [60.0, 20.0, 0.0, 0.0])
	assert_eq(_column(a_events, ClientCombatState.KEY_DAMAGE), [DAMAGE, DAMAGE, DAMAGE, 0.0])
	assert_eq(_column(a_events, ClientCombatState.KEY_TARGET_DIED), [false, false, true, false])
	var attackers: Array = _column(a_events, ClientCombatState.KEY_ATTACKER_ID)
	assert_true(attackers.slice(0, 2).has(alice_id) and attackers.slice(0, 2).has(bob_id), "both players attacked first: %s" % str(attackers))
	assert_eq(attackers.slice(2), [alice_id, bob_id])
	for row: Array in a_results + b_results:
		assert_eq(row.slice(1), [true, ""], "every swing was accepted")


# ------------------------------------------------------------ 3. refusals

func test_cooldown_stamina_and_dead_player_requests_are_refused_without_events() -> void:
	_weapon.cooldown_sec = LONG_COOLDOWN_SEC
	_weapon.stamina_cost = HEAVY_STAMINA_COST
	var clients: Array[NetworkService] = await _start_with_two_clients()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var bob_id: String = b.client_state.local_player_id
	var zombie_id: String = _spawn(ZOMBIE_AHEAD)
	var a_results: Array[Array] = _results_of(a)
	var b_results: Array[Array] = _results_of(b)
	var a_events: Array[Dictionary] = _events_of(a)
	var b_events: Array[Dictionary] = _events_of(b)

	# Accepted swing, then the cooldown.
	var first: int = _module(a).request_melee_attack(AIM_MINUS_Z)
	var second: int = _module(a).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return a_results.size() == 2), "alice got both answers")
	assert_eq(a_results, [[first, true, ""], [second, false, CombatService.REASON_ON_COOLDOWN]])
	# Not enough stamina (bob has no cooldown running).
	assert_true(_survival().try_spend_stamina(bob_id, HEAVY_STAMINA_COST), "test setup: tire bob")
	var tired_stamina: float = _stamina(bob_id)
	var third: int = _module(b).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return b_results.size() == 1), "bob got an answer")
	assert_eq(b_results, [[third, false, CombatService.REASON_NOT_ENOUGH_STAMINA]])
	assert_eq(_stamina(bob_id), tired_stamina, "a refused swing spends nothing")
	# Dead player.
	assert_true(_survival().apply_damage(bob_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok, "test setup: kill bob")
	assert_false(_survival().is_alive(bob_id))
	var fourth: int = _module(b).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return b_results.size() == 2), "dead bob got an answer")
	assert_eq(b_results[1], [fourth, false, CombatService.REASON_PLAYER_DEAD])
	await _settle()

	assert_eq(a_events.size(), 1, "only the accepted swing produced an event")
	assert_eq(b_events, a_events)
	assert_eq(_module(_cluster.server).recent_events(), a_events)
	assert_eq(_health(zombie_id), ZOMBIE_HEALTH - DAMAGE, "only the accepted swing did damage")
	for reason: String in [CombatService.REASON_ON_COOLDOWN, CombatService.REASON_NOT_ENOUGH_STAMINA, CombatService.REASON_PLAYER_DEAD]:
		assert_eq(_cluster.server.rejected_intent_count(reason), 1, "rejection counted: " + reason)
	assert_eq(_cluster.server.rejected_intent_count(), 3)


# ------------------------------------------------------------ 4. manipulated requests

func test_manipulated_requests_are_rejected_and_change_nothing() -> void:
	var clients: Array[NetworkService] = await _start_with_two_clients()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var zombie_id: String = _spawn(ZOMBIE_AHEAD)
	var a_results: Array[Array] = _results_of(a)
	var a_events: Array[Dictionary] = _events_of(a)
	var b_events: Array[Dictionary] = _events_of(b)
	var stamina_before: float = _stamina(alice_id)
	var combat_document: Dictionary = _combat().to_world_document()
	var bad_type: String = IntentValidator.REASON_BAD_TYPE
	var bad_yaw: String = CombatService.REASON_BAD_AIM_YAW
	# [request_id, aim_yaw, expected reason]
	var cases: Array[Array] = [
		[1, "0.0", bad_type],                 # text instead of a number
		[2, 0, bad_type],                     # integer yaw
		["3", AIM_MINUS_Z, bad_type],         # text request id
		[4, Vector2(1.0, 0.0), bad_type],     # a direction instead of a yaw
		[5, null, bad_type],
		[6, [AIM_MINUS_Z], bad_type],
		[7.5, AIM_MINUS_Z, bad_type],         # fractional request id
		[8, {"player_id": "player_000002"}, bad_type],
		[9, NAN, bad_yaw],
		[10, INF, bad_yaw],
		[11, -INF, bad_yaw],
		[12, 100.0, bad_yaw],                 # out of range
		[-1, AIM_MINUS_Z, IntentValidator.REASON_BAD_SEQUENCE],
	]
	var expected_counts: Dictionary[String, int] = {}
	var expected_results: Array[Array] = []
	for case: Array in cases:
		var reason: String = case[2]
		expected_counts[reason] = expected_counts.get(reason, 0) + 1
		# Only a usable request id can be answered.
		if typeof(case[0]) == TYPE_INT and int(case[0]) >= 0:
			expected_results.append([case[0], false, reason])
		_module(a).send_raw_melee_request(case[0], case[1])
	var counted: bool = await _wait(func() -> bool: return _cluster.server.rejected_intent_count() >= cases.size() and a_results.size() >= expected_results.size())
	assert_true(counted, "every manipulated request was seen (%d of %d)" % [_cluster.server.rejected_intent_count(), cases.size()])
	await _settle()

	assert_eq(_cluster.server.rejected_intent_count(), cases.size(), "rejection counter")
	for reason: String in expected_counts:
		assert_eq(_cluster.server.rejected_intent_count(reason), expected_counts[reason], "rejections for " + reason)
	assert_eq(a_results, expected_results, "the requester is told why (when the request id is usable)")
	assert_eq(_health(zombie_id), ZOMBIE_HEALTH, "no damage")
	assert_eq(_stamina(alice_id), stamina_before, "no stamina spent")
	assert_eq(_combat().cooldown_remaining(alice_id), 0.0, "no cooldown started")
	assert_eq(_combat().to_world_document(), combat_document, "combat state (RNG) untouched")
	assert_eq(a_events.size() + b_events.size(), 0, "no event reached a client")
	assert_eq(_module(_cluster.server).recent_events().size(), 0, "no event was broadcast")
	# The path itself works: a clean request from the same peer is accepted.
	var request_id: int = _module(a).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return a_events.size() == 1 and b_events.size() == 1), "a valid request still goes through")
	assert_eq(a_results[a_results.size() - 1], [request_id, true, ""])
	assert_eq(_health(zombie_id), ZOMBIE_HEALTH - DAMAGE)


func test_request_before_join_is_rejected() -> void:
	assert_true(_start_server(), "server started")
	var zombie_id: String = _spawn(ZOMBIE_AHEAD)
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var results: Array[Array] = _results_of(stranger)
	var events: Array[Dictionary] = _events_of(stranger)
	var connected: bool = await _wait(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	assert_eq(_module(stranger).request_melee_attack(AIM_MINUS_Z), CombatNetModule.NO_REQUEST, "the client API sends nothing before the join")
	_module(stranger).send_raw_melee_request(1, AIM_MINUS_Z)
	var rejected: bool = await _wait(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 1)
	assert_true(rejected, "the server refused the request of a peer that has not joined")
	await _settle()
	assert_eq(_cluster.server.rejected_intent_count(), 1, "exactly the raw request reached the server")
	assert_eq(results.size() + events.size(), 0, "an unjoined peer is told nothing")
	assert_eq(_health(zombie_id), ZOMBIE_HEALTH)
	assert_eq(_module(_cluster.server).recent_events().size(), 0)
	assert_eq(_world.online_player_ids().size(), 0)


func test_request_flood_is_rate_limited_per_peer() -> void:
	const BURST: int = 2
	const FLOOD: int = 6
	# One new token every 100 seconds: only the burst passes within the test.
	_combat_net.melee_intent_rate_per_sec = 0.01
	_combat_net.melee_intent_burst = BURST
	var clients: Array[NetworkService] = await _start_with_two_clients()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var zombie_id: String = _spawn(ZOMBIE_AHEAD)
	var a_results: Array[Array] = _results_of(a)
	var b_results: Array[Array] = _results_of(b)
	var a_events: Array[Dictionary] = _events_of(a)
	for index: int in range(FLOOD):
		_module(a).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return a_results.size() == FLOOD), "every request was answered (%d)" % a_results.size())
	await _settle()
	var accepted: int = 0
	var limited: int = 0
	for row: Array in a_results:
		if row[1]:
			accepted += 1
		elif row[2] == NetworkService.RATE_LIMITED:
			limited += 1
	assert_eq(accepted, BURST, "only the burst is accepted")
	assert_eq(limited, FLOOD - BURST, "the rest is refused as rate_limited")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST, "rejection counter")
	assert_eq(a_events.size(), BURST, "refused requests make no events")
	assert_eq(_health(zombie_id), ZOMBIE_HEALTH - DAMAGE * BURST, "refused requests do no damage")
	# The bucket is per peer: bob is not limited by alice's flood.
	var request_id: int = _module(b).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return b_results.size() == 1), "bob was answered")
	assert_eq(b_results, [[request_id, true, ""]])


# ------------------------------------------------------------ 5. forged server messages

func test_server_only_rpcs_sent_by_a_client_are_ignored() -> void:
	var clients: Array[NetworkService] = await _start_with_two_clients()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var zombie_id: String = _spawn(ZOMBIE_AHEAD)
	var server_results: Array[Array] = _results_of(_cluster.server)
	var server_events: Array[Dictionary] = _events_of(_cluster.server)
	var a_events: Array[Dictionary] = _events_of(a)
	var b_results: Array[Array] = _results_of(b)
	var b_events: Array[Dictionary] = _events_of(b)
	_module(a).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return a_events.size() == 1 and b_events.size() == 1), "one real event first")
	var real_events: Array[Dictionary] = _module(_cluster.server).recent_events()
	var forged: Dictionary = _public_event(FORGED_SEQUENCE)
	var b_peer: int = b.multiplayer.get_unique_id()

	# Real ENet path. The engine refuses these (the sender is not the
	# authority; clients cannot reach each other) and reports each refusal as
	# an engine error, which is the expected outcome here, so error printing
	# is off for exactly this block (tools/run_tests.sh fails on any error line).
	Engine.print_error_messages = false
	_module(a)._rpc_melee_result.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, true, "")
	_module(a)._rpc_combat_events.rpc_id(NetworkService.SERVER_PEER_ID, [forged])
	_module(a)._rpc_melee_result.rpc_id(b_peer, FORGED_REQUEST_ID, true, "")
	_module(a)._rpc_combat_events.rpc_id(b_peer, [forged])
	await _settle()
	Engine.print_error_messages = true

	# Script-level guard, independent of the engine: a handler that is not
	# running an RPC sent by the server does nothing (sender id 0 here).
	for service: NetworkService in [b, _cluster.server]:
		_module(service)._rpc_melee_result(FORGED_REQUEST_ID, true, "")
		_module(service)._rpc_combat_events([forged])
	# ... and a client never acts on a request addressed to it.
	_module(b)._rpc_request_melee_attack(FORGED_REQUEST_ID, AIM_MINUS_Z)
	await _settle()

	assert_eq(b_results.size(), 0, "bob received no forged result")
	assert_eq(b_events.size(), 1, "bob received no forged event")
	assert_eq(_module(b).recent_events(), real_events, "bob's mirror is untouched")
	assert_eq(_module(b).last_event_sequence(), 1)
	assert_eq(server_results.size() + server_events.size(), 0, "the server never handles client-bound messages")
	assert_eq(_module(_cluster.server).recent_events(), real_events, "the server's broadcast record is untouched")
	assert_eq(_health(zombie_id), ZOMBIE_HEALTH - DAMAGE, "no extra damage")
	# Alice is still a normal client afterwards.
	_module(a).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return a_events.size() == 2 and b_events.size() == 2), "real events still flow")
	assert_eq(_column(b_events, ClientCombatState.KEY_SEQUENCE), [1, 2])


# ------------------------------------------------------------ 6. impersonation

func test_a_request_cannot_name_another_player() -> void:
	# The contract: the request carries a request id and an aim, nothing else.
	var script: GDScript = load(MODULE_SCRIPT) as GDScript
	var argument_names: Array[String] = []
	var found: bool = false
	for method: Dictionary in script.get_script_method_list():
		if str(method["name"]) == "_rpc_request_melee_attack":
			found = true
			for argument: Dictionary in method["args"]:
				argument_names.append(str(argument["name"]))
	assert_true(found, "the request RPC exists")
	var expected_names: Array[String] = ["request_id", "aim_yaw"]
	assert_eq(argument_names, expected_names, "no player, position, target, weapon or damage argument")

	var clients: Array[NetworkService] = await _start_with_two_clients()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	# Bob stands in front of the zombie, alice far away from it.
	_world.get_player(alice_id).position = FAR_AWAY
	var zombie_id: String = _spawn(ZOMBIE_AHEAD)
	_weapon.stamina_cost = 5.0
	var bob_stamina: float = _stamina(bob_id)
	var alice_stamina: float = _stamina(alice_id)
	var a_results: Array[Array] = _results_of(a)
	var a_events: Array[Dictionary] = _events_of(a)
	var b_events: Array[Dictionary] = _events_of(b)

	var request_id: int = _module(a).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return a_events.size() == 1 and b_events.size() == 1 and a_results.size() == 1), "alice's swing replicated")
	if a_events.is_empty():
		return
	var event: Dictionary = a_events[0]
	assert_eq(a_results, [[request_id, true, ""]])
	assert_eq(event[ClientCombatState.KEY_ATTACKER_ID], alice_id, "the attacker is the sending peer's player")
	assert_eq(event[ClientCombatState.KEY_POSITION], FAR_AWAY, "the swing happens at the sender's server position")
	assert_eq(event[ClientCombatState.KEY_HIT], false, "... which is nowhere near bob's zombie")
	assert_eq(_health(zombie_id), ZOMBIE_HEALTH)
	assert_eq(_stamina(alice_id), alice_stamina - _weapon.stamina_cost, "alice paid for her swing")
	assert_eq(_stamina(bob_id), bob_stamina, "bob paid nothing")

	# Smuggling a player id as an extra argument does not reach the handler
	# (the engine reports the argument mismatch as an error: expected here).
	Engine.print_error_messages = false
	_module(a)._rpc_request_melee_attack.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, AIM_MINUS_Z, bob_id)
	await _settle()
	Engine.print_error_messages = true
	assert_eq(a_events.size(), 1, "no swing for the smuggled request")
	assert_eq(a_results.size(), 1, "no answer for the smuggled request")
	assert_eq(_health(zombie_id), ZOMBIE_HEALTH)
	assert_eq(_stamina(bob_id), bob_stamina)
	assert_eq(_combat().cooldown_remaining(bob_id), 0.0)


# ------------------------------------------------------------ late join

func test_a_late_joiner_starts_after_the_events_already_sent() -> void:
	var clients: Array[NetworkService] = await _start_with_two_clients()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	_spawn(ZOMBIE_AHEAD)
	var b_events: Array[Dictionary] = _events_of(b)
	_module(a).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return b_events.size() == 1), "first event replicated")
	var c: NetworkService = await _cluster.join_client("carol")
	assert_not_null(c, "carol joined")
	if c == null:
		return
	var c_events: Array[Dictionary] = _events_of(c)
	assert_eq(_module(c).recent_events().size(), 0, "past events are not replayed")
	assert_eq(_module(c).last_event_sequence(), 1, "the join snapshot carries the event baseline")
	_module(a).request_melee_attack(AIM_MINUS_Z)
	assert_true(await _wait(func() -> bool: return b_events.size() == 2 and c_events.size() == 1), "second event reached everyone")
	assert_eq(c_events[0], b_events[1], "the late joiner gets the same event as the others")
	assert_eq(c_events[0][ClientCombatState.KEY_SEQUENCE], 2)


# ------------------------------------------------------------ batching, disclosure setting

func test_a_tick_with_many_events_is_split_into_messages_in_order() -> void:
	const SWINGS: int = 5
	_combat_net.max_events_per_message = 2
	_combat_net.broadcast_damage_numbers = false
	var clients: Array[NetworkService] = await _start_with_two_clients()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	_spawn(ZOMBIE_AHEAD)
	var a_events: Array[Dictionary] = _events_of(a)
	var b_events: Array[Dictionary] = _events_of(b)
	# All swings land in the queue between two server ticks (server-side
	# calls, not requests), so one tick has to send three messages.
	var aims: Array = []
	for index: int in range(SWINGS):
		var aim: float = 0.1 * index
		aims.append(aim)
		assert_true(_combat().request_melee_attack(_world, alice_id, aim).ok, "test setup: swing %d" % index)
	var done: bool = await _wait(func() -> bool: return a_events.size() == SWINGS and b_events.size() == SWINGS)
	assert_true(done, "every event arrived (%d/%d)" % [a_events.size(), b_events.size()])
	await _settle()
	assert_eq(a_events, b_events, "same events, same order")
	assert_eq(_module(_cluster.server).recent_events(), a_events)
	assert_eq(_column(a_events, ClientCombatState.KEY_SEQUENCE), [1, 2, 3, 4, 5])
	assert_eq(_column(a_events, ClientCombatState.KEY_AIM_YAW), aims, "the order the server decided them")
	for event: Dictionary in b_events:
		assert_false(event.has(ClientCombatState.KEY_DAMAGE) or event.has(ClientCombatState.KEY_TARGET_HEALTH_AFTER), "damage numbers are withheld from every client by the setting")
	assert_eq(_module(a).rejected_event_count + _module(b).rejected_event_count, 0)


# ------------------------------------------------------------ client-side validation

func test_a_client_drops_malformed_messages_even_from_the_server() -> void:
	var clients: Array[NetworkService] = await _start_with_two_clients()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var server_module: CombatNetModule = _module(_cluster.server)
	var a_peer: int = a.multiplayer.get_unique_id()
	var a_results: Array[Array] = _results_of(a)
	var a_events: Array[Dictionary] = _events_of(a)
	var bad_yaw: Dictionary = _public_event(11)
	bad_yaw[ClientCombatState.KEY_AIM_YAW] = NAN
	var oversized: Array = []
	for index: int in range(CombatNetModule.MAX_EVENTS_PER_MESSAGE + 1):
		oversized.append(_public_event(100 + index))
	# A server of another build (or a bug) sending what this client cannot use.
	server_module._rpc_combat_events.rpc_id(a_peer, "not a list")
	server_module._rpc_combat_events.rpc_id(a_peer, oversized)
	server_module._rpc_combat_events.rpc_id(a_peer, ["junk", bad_yaw, _public_event(10), _public_event(10), 7])
	server_module._rpc_melee_result.rpc_id(a_peer, "1", true, "")
	server_module._rpc_melee_result.rpc_id(a_peer, 1, "yes", "")
	server_module._rpc_melee_result.rpc_id(a_peer, 2, true, CombatService.REASON_ON_COOLDOWN)
	server_module._rpc_melee_result.rpc_id(a_peer, 3, false, "")
	server_module._rpc_melee_result.rpc_id(a_peer, -4, false, CombatService.REASON_ON_COOLDOWN)
	server_module._rpc_melee_result.rpc_id(a_peer, 5, false, "x".repeat(CombatNetModule.REASON_MAX_LENGTH + 1))
	server_module._rpc_melee_result.rpc_id(a_peer, 6, false, CombatService.REASON_ON_COOLDOWN)
	assert_true(await _wait(func() -> bool: return a_results.size() >= 1), "the well-formed result arrived last")
	await _settle()
	assert_eq(a_results, [[6, false, CombatService.REASON_ON_COOLDOWN]], "only the well-formed result is passed on")
	assert_eq(a_events, [_public_event(10)], "only the well-formed, new event is passed on")
	assert_eq(_module(a).recent_events(), [_public_event(10)])
	assert_eq(_module(a).last_event_sequence(), 10)
	# "not a list", the oversized message, "junk", the NaN yaw, the repeated sequence, 7.
	assert_eq(_module(a).rejected_event_count, 6, "every dropped payload is counted")


# ------------------------------------------------------------ rules (no network)

func test_default_settings_and_composition() -> void:
	assert_true(ResourceLoader.exists(CombatNetSettings.DEFAULT_PATH), "default settings resource is shipped")
	var settings: CombatNetSettings = CombatNetSettings.load_or_default()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_not_null(config.combat_net)
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var broken: CombatNetSettings = CombatNetSettings.new()
	broken.melee_intent_rate_per_sec = 0.0
	broken.max_events_per_message = CombatNetModule.MAX_EVENTS_PER_MESSAGE + 1
	assert_eq(broken.validate().size(), 2, "; ".join(broken.validate()))
	config.combat_net = broken
	assert_true(config.validate().size() > 0, "composition validation covers the combat network settings")
	config.combat_net = null
	assert_true(config.validate().size() > 0, "a missing settings object is reported")

	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	var module: CombatNetModule = service.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule
	assert_not_null(module, "the composition installs the combat module")
	assert_eq(str(module.name), CombatNetModule.MODULE_NAME, "same node name on every peer")
	assert_eq(module.request_melee_attack(AIM_MINUS_Z), CombatNetModule.NO_REQUEST, "nothing is sent while offline")
	# Channel 0, reliable; requests from any peer, answers only from the server.
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	var expected_modes: Dictionary[String, int] = {
		"_rpc_request_melee_attack": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_melee_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_combat_events": MultiplayerAPI.RPC_MODE_AUTHORITY,
	}
	for method: String in expected_modes:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), expected_modes[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	service.free()


func test_request_validation_rules() -> void:
	var limit: float = TAU
	assert_eq(CombatNetModule.validate_melee_request(1, 0.25, limit), "")
	assert_eq(CombatNetModule.validate_melee_request(0, -TAU, limit), "", "the bound itself is allowed")
	assert_eq(CombatNetModule.validate_melee_request("1", 0.25, limit), IntentValidator.REASON_BAD_TYPE)
	assert_eq(CombatNetModule.validate_melee_request(1, 1, limit), IntentValidator.REASON_BAD_TYPE)
	assert_eq(CombatNetModule.validate_melee_request(1, "0.25", limit), IntentValidator.REASON_BAD_TYPE)
	assert_eq(CombatNetModule.validate_melee_request(1, null, limit), IntentValidator.REASON_BAD_TYPE)
	assert_eq(CombatNetModule.validate_melee_request(-1, 0.25, limit), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(CombatNetModule.validate_melee_request(1, NAN, limit), CombatService.REASON_BAD_AIM_YAW)
	assert_eq(CombatNetModule.validate_melee_request(1, INF, limit), CombatService.REASON_BAD_AIM_YAW)
	assert_eq(CombatNetModule.validate_melee_request(1, TAU + 0.001, limit), CombatService.REASON_BAD_AIM_YAW)


func test_public_event_projection_and_client_validation() -> void:
	# A real server event, straight from the combat system (no network).
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config)
	world.seed_new_world(DevWorldSeed.new())
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = str((world.get_system(ZombieService.SYSTEM_ID) as ZombieService).spawn_zombie(world, ZOMBIE_AHEAD).event["zombie_id"])
	var raw: Dictionary = (world.get_system(CombatService.SYSTEM_ID) as CombatService).request_melee_attack(world, alice.player_id, AIM_MINUS_Z).event
	assert_eq(raw.get("target_id", ""), zombie_id, "test setup: a hit")

	var full: Dictionary = CombatNetModule.to_public_event(raw, 7, true)
	assert_eq(full, {
		ClientCombatState.KEY_SEQUENCE: 7,
		ClientCombatState.KEY_EVENT_TYPE: CombatService.EVENT_MELEE_ATTACK,
		ClientCombatState.KEY_ATTACKER_ID: alice.player_id,
		ClientCombatState.KEY_WEAPON_ID: WEAPON_ID,
		ClientCombatState.KEY_AIM_YAW: AIM_MINUS_Z,
		ClientCombatState.KEY_POSITION: alice.position,
		ClientCombatState.KEY_HIT: true,
		ClientCombatState.KEY_TARGET_ID: zombie_id,
		ClientCombatState.KEY_TARGET_DIED: false,
		ClientCombatState.KEY_WORLD_TIME: raw["world_time"],
		ClientCombatState.KEY_DAMAGE: DAMAGE,
		ClientCombatState.KEY_TARGET_HEALTH_AFTER: ZOMBIE_HEALTH - DAMAGE,
	}, "public projection of melee_attack")
	assert_eq(ClientCombatState.validate_event(full), "", "the server's projection passes the client's validation")
	# Numbers withheld (CombatNetSettings.broadcast_damage_numbers = false).
	var lean: Dictionary = CombatNetModule.to_public_event(raw, 7, false)
	assert_false(lean.has(ClientCombatState.KEY_DAMAGE) or lean.has(ClientCombatState.KEY_TARGET_HEALTH_AFTER), "damage numbers can be withheld")
	assert_eq(lean.size(), full.size() - 2)
	assert_eq(ClientCombatState.validate_event(lean), "")
	# Anything this module does not know is never forwarded.
	var unknown: Dictionary = raw.duplicate()
	unknown["event_type"] = "player_secret"
	assert_eq(CombatNetModule.to_public_event(unknown, 8, true), {}, "unknown event types are not forwarded")
	var extended: Dictionary = raw.duplicate()
	extended["attacker_stamina"] = 12.0
	assert_eq(CombatNetModule.to_public_event(extended, 7, true), full, "fields outside the whitelist are not forwarded")

	# Client side: only well-formed, newer events enter the mirror.
	var state: ClientCombatState = ClientCombatState.new(2)
	assert_eq(state.apply_event(_public_event(1)), "")
	assert_eq(state.apply_event(_public_event(2)), "")
	assert_eq(state.apply_event(_public_event(2)), ClientCombatState.REASON_STALE_EVENT, "a repeated sequence is dropped")
	assert_eq(state.apply_event(_public_event(1)), ClientCombatState.REASON_STALE_EVENT)
	var dirty: Dictionary = _public_event(5)
	dirty["attacker_health"] = 3.0
	assert_eq(state.apply_event(dirty), "")
	assert_eq(state.last_sequence, 5)
	assert_eq(state.recent_events(), [_public_event(2), _public_event(5)], "bounded, oldest first, unknown keys stripped")
	state.recent_events()[0][ClientCombatState.KEY_ATTACKER_ID] = "tampered"
	assert_eq(state.recent_events()[0], _public_event(2), "readers get copies")
	var miss: Dictionary = _public_event(6)
	miss[ClientCombatState.KEY_HIT] = false
	miss[ClientCombatState.KEY_TARGET_ID] = ""
	miss[ClientCombatState.KEY_DAMAGE] = 0.0
	miss[ClientCombatState.KEY_TARGET_HEALTH_AFTER] = 0.0
	assert_eq(ClientCombatState.validate_event(miss), "", "a miss is well-formed")

	var long_id: String = "x".repeat(ClientCombatState.ID_MAX_LENGTH + 1)
	# [key, bad value] applied to a well-formed event; null = key removed.
	var malformed: Array[Array] = [
		[ClientCombatState.KEY_SEQUENCE, 0],
		[ClientCombatState.KEY_SEQUENCE, "6"],
		[ClientCombatState.KEY_SEQUENCE, 6.0],
		[ClientCombatState.KEY_EVENT_TYPE, 3],
		[ClientCombatState.KEY_ATTACKER_ID, ""],
		[ClientCombatState.KEY_ATTACKER_ID, 42],
		[ClientCombatState.KEY_ATTACKER_ID, long_id],
		[ClientCombatState.KEY_WEAPON_ID, ""],
		[ClientCombatState.KEY_WEAPON_ID, long_id],
		[ClientCombatState.KEY_AIM_YAW, NAN],
		[ClientCombatState.KEY_AIM_YAW, 4.0],
		[ClientCombatState.KEY_AIM_YAW, 1],
		[ClientCombatState.KEY_POSITION, [1.0, 0.0, 2.0]],
		[ClientCombatState.KEY_POSITION, Vector3(INF, 0.0, 0.0)],
		[ClientCombatState.KEY_HIT, 1],
		[ClientCombatState.KEY_HIT, false],
		[ClientCombatState.KEY_TARGET_ID, ""],
		[ClientCombatState.KEY_TARGET_ID, long_id],
		[ClientCombatState.KEY_TARGET_DIED, "no"],
		[ClientCombatState.KEY_WORLD_TIME, -1.0],
		[ClientCombatState.KEY_WORLD_TIME, NAN],
		[ClientCombatState.KEY_DAMAGE, -8.0],
		[ClientCombatState.KEY_DAMAGE, "8"],
		[ClientCombatState.KEY_DAMAGE, null],
		[ClientCombatState.KEY_TARGET_HEALTH_AFTER, INF],
		[ClientCombatState.KEY_TARGET_HEALTH_AFTER, null],
		[ClientCombatState.KEY_ATTACKER_ID, null],
		[ClientCombatState.KEY_WORLD_TIME, null],
	]
	for case: Array in malformed:
		var event: Dictionary = _public_event(6)
		if case[1] == null:
			event.erase(case[0])
		else:
			event[case[0]] = case[1]
		assert_eq(state.apply_event(event), ClientCombatState.REASON_BAD_EVENT, "malformed %s = %s" % [str(case[0]), str(case[1])])
	var died_without_hit: Dictionary = miss.duplicate()
	died_without_hit[ClientCombatState.KEY_TARGET_DIED] = true
	assert_eq(state.apply_event(died_without_hit), ClientCombatState.REASON_BAD_EVENT, "a miss cannot kill")
	var unknown_type: Dictionary = _public_event(6)
	unknown_type[ClientCombatState.KEY_EVENT_TYPE] = "player_secret"
	assert_eq(state.apply_event(unknown_type), ClientCombatState.REASON_UNKNOWN_EVENT)
	for payload: Variant in [null, 5, "melee_attack", [], [_public_event(6)]]:
		assert_eq(state.apply_event(payload), ClientCombatState.REASON_BAD_EVENT, "not an event: %s" % str(payload))
	assert_eq(state.last_sequence, 5, "rejected payloads leave the mirror alone")
	assert_eq(state.recent_events().size(), 2)
	state.reset(40)
	assert_eq(state.recent_events().size(), 0)
	assert_eq(state.apply_event(_public_event(40)), ClientCombatState.REASON_STALE_EVENT, "the join baseline is the newest event already sent")
	assert_eq(state.apply_event(_public_event(41)), "")
