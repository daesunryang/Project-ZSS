extends TestCase
## F-25 over real ENet (docs/09 §17.12): what clients are told of an NPC's
## body is its condition and nothing else; a client's melee swing can hit an
## NPC; a client's bandage can be used on an NPC; a zombie's attack on an
## NPC reaches the clients as a zombie event they accept.

const WORLD: String = "npc_health_net_world"
## Both clients stand here; yaw 0 faces -Z.
const SPAWN: Vector3 = Vector3(5.0, 0.0, 5.0)
## Straight ahead of them, in reach, in the same cell.
const NEAR: Vector3 = Vector3(5.0, 0.0, 3.9)
const DEFINITION_ID: String = "f25_net_survivor"
const MAX_WAIT_TICKS: int = 240
const BANDAGE: String = "dev_bandage"
const PRIVATE_WORDS: PackedStringArray = ["health", "injur", "wound", "infection", "bleed", "severity", "killer", "rise_at", "died_at", "latent"]

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	_config = CompositionConfig.from_defaults()
	_config.npc_behaviour = null
	_config.npc_health = NpcHealthSettings.new()
	_config.gameplay = GameplaySettings.new()
	_config.gameplay.world_half_extent_m = 50.0
	_config.gameplay.player_spawn_position = SPAWN
	_config.clock = WorldClockSettings.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.infection_chance_bite = 1.0
	_config.survival.infection_chance_scratch = 1.0
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.wander_pause_min_sec = 1.0e9
	_config.zombie.wander_pause_max_sec = 1.0e9
	_config.combat = CombatSettings.new()
	_config.combat.damage_roll_min = 1.0
	_config.combat.damage_roll_max = 1.0
	_config.map_content = null
	_config.npc_spots = null
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
	definition.display_name = "체력 전송 검사원"
	definition.appearance = _config.appearance.default_selection()
	_config.npc_definitions.add(definition)
	_config.npc_net = NpcNetSettings.new()
	_cluster = NetTestCluster.new(tree, network_settings, _config)


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func _start() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null or _world.seed_new_world(DevWorldSeed.new()) != OK:
		return false
	return _cluster.start_server(_world, null) == OK


func _npcs() -> NpcService:
	return _world.get_system(NpcService.SYSTEM_ID) as NpcService


func _health() -> NpcHealth:
	return NpcHealth.of_world(_world)


func _mirror(service: NetworkService) -> ClientNpcState:
	return (service.get_module(NpcNetModule.MODULE_NAME) as NpcNetModule).client_state


func _combat(service: NetworkService) -> CombatNetModule:
	return service.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule


func _spawn(position: Vector3 = NEAR) -> String:
	var result: ActionResult = _npcs().spawn_npc(_world, DEFINITION_ID, position)
	if not result.ok:
		fail("test setup: NPC spawn refused: " + result.reason)
		return ""
	return str(result.event[NpcService.KEY_NPC_ID])


func _hit(npc_id: String, amount: float, type: Wound.Type = Wound.Type.LACERATION) -> bool:
	return _health().apply_damage(npc_id, DamageInput.create("test_source", BodyPart.Part.TORSO, type, amount)).ok


func _condition_is(clients: Array[NetworkService], npc_id: String, condition: String) -> Callable:
	return func() -> bool:
		for client: NetworkService in clients:
			if _mirror(client).condition_of(npc_id) != condition:
				return false
		return true


func test_clients_see_ok_hurt_and_dead_and_nothing_else_of_the_body() -> void:
	assert_true(_start())
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	assert_true(a != null and b != null)
	var both: Array[NetworkService] = [a, b]
	var npc_id: String = _spawn()
	assert_true(await _cluster.wait_ticks_until(_condition_is(both, npc_id, "ok"), MAX_WAIT_TICKS), "a whole NPC is ok on both clients")
	assert_true(_hit(npc_id, 25.0))
	assert_true(await _cluster.wait_ticks_until(_condition_is(both, npc_id, "hurt"), MAX_WAIT_TICKS), "a bleeding NPC is hurt on both clients")
	assert_true(_hit(npc_id, 500.0))
	assert_true(await _cluster.wait_ticks_until(_condition_is(both, npc_id, "dead"), MAX_WAIT_TICKS), "a dead NPC is dead on both clients")
	assert_true(_mirror(a).is_dead(npc_id))
	assert_true(_mirror(a).has_npc(npc_id), "the body is still there to see")
	# A client that joins now gets the body in its join snapshot.
	var c: NetworkService = await _cluster.join_client("carol")
	assert_true(c != null)
	assert_true(await _cluster.wait_ticks_until(_condition_is([c] as Array[NetworkService], npc_id, "dead"), MAX_WAIT_TICKS), "a late client sees the body")
	var server_module: NpcNetModule = _cluster.server.get_module(NpcNetModule.MODULE_NAME) as NpcNetModule
	for client: NetworkService in [a, b, c]:
		var wire_text: String = var_to_str(server_module.build_join_fragment(client.client_state.local_player_id)) + var_to_str(_mirror(client).recent_events())
		for word: String in PRIVATE_WORDS:
			assert_not_contains(wire_text, word, "nothing of the body but its condition: " + word)
		assert_eq(_mirror(client).rejected_payload_count, 0)
	assert_eq(server_module.invalid_condition_count, 0)
	var keys: Array = _mirror(a).get_npc(npc_id).keys()
	assert_eq(keys.size(), 8, "seven public values and the condition")


func test_a_clients_swing_hits_an_npc_and_both_clients_are_told() -> void:
	assert_true(_start())
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	assert_true(a != null and b != null)
	var npc_id: String = _spawn()
	assert_true(await _cluster.wait_ticks_until(_condition_is([a, b] as Array[NetworkService], npc_id, "ok"), MAX_WAIT_TICKS))
	var results: Array = []
	_combat(a).melee_result.connect(func(request_id: int, ok: bool, reason: String) -> void: results.append([request_id, ok, reason]))
	var request_id: int = _combat(a).request_melee_attack(0.0)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return results.size() == 1, MAX_WAIT_TICKS), "the server answered the swing")
	assert_eq(results[0], [request_id, true, ""])
	var told: Callable = func() -> bool: return _combat(a).events.event_count() == 1 and _combat(b).events.event_count() == 1
	assert_true(await _cluster.wait_ticks_until(told, MAX_WAIT_TICKS), "both clients got the combat event")
	for client: NetworkService in [a, b]:
		var event: Dictionary = _combat(client).events.last_event()
		assert_eq(event[ClientCombatState.KEY_TARGET_ID], npc_id)
		assert_eq(event[ClientCombatState.KEY_HIT], true)
		assert_eq(event[ClientCombatState.KEY_ATTACKER_ID], a.client_state.local_player_id)
		assert_eq(_combat(client).rejected_event_count, 0)
	var vitals: NpcVitals = _health().vitals_of(npc_id)
	assert_true(vitals.health < vitals.max_health(), "the server took the health")
	assert_eq(vitals.injuries[0].source_id, a.client_state.local_player_id)


func test_a_clients_bandage_stops_an_npcs_bleeding() -> void:
	assert_true(_start())
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	assert_true(a != null and b != null)
	var npc_id: String = _spawn()
	assert_true(_hit(npc_id, 25.0))
	assert_true(await _cluster.wait_ticks_until(_condition_is([a, b] as Array[NetworkService], npc_id, "hurt"), MAX_WAIT_TICKS))
	var alice_id: String = a.client_state.local_player_id
	var alice: PlayerState = _world.get_player(alice_id)
	var item_id: String = _world.inventory.spawn_world_item(BANDAGE, 1, _world.cell_id_at(alice.position), alice.position)
	assert_true(_world.try_pickup(alice_id, item_id).ok)
	var inventory: InventoryNetModule = a.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	var bob_inventory: InventoryNetModule = b.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	var results: Array = []
	var notices: Array = []
	inventory.use_on_result.connect(func(request_id: int, ok: bool, reason: String) -> void: results.append([request_id, ok, reason]))
	bob_inventory.treatment_seen.connect(func(notice: Dictionary) -> void: notices.append(notice))
	var request_id: int = inventory.request_use_on(item_id, npc_id)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return results.size() == 1, MAX_WAIT_TICKS), "the server answered")
	assert_eq(results[0], [request_id, true, ""])
	assert_false(_health().vitals_of(npc_id).is_bleeding())
	assert_null(_world.inventory.get_item(item_id), "the bandage is used up")
	assert_true(await _cluster.wait_ticks_until(_condition_is([a, b] as Array[NetworkService], npc_id, "ok"), MAX_WAIT_TICKS), "both clients see it is no longer hurt")
	assert_eq(notices.size(), 0, "no player notice is sent about an NPC")
	# A second use has nothing to treat: refused with the players' reason.
	var second_id: String = _world.inventory.spawn_world_item(BANDAGE, 1, _world.cell_id_at(alice.position), alice.position)
	assert_true(_world.try_pickup(alice_id, second_id).ok)
	inventory.request_use_on(second_id, npc_id)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return results.size() == 2, MAX_WAIT_TICKS))
	assert_eq(results[1][1], false)
	assert_eq(results[1][2], SurvivalService.REASON_NOT_BLEEDING)
	assert_not_null(_world.inventory.get_item(second_id))


func test_a_zombies_attack_on_an_npc_reaches_the_clients_as_a_zombie_event() -> void:
	_config.zombie.bite_chance = 1.0
	assert_true(_start())
	var a: NetworkService = await _cluster.join_client("alice")
	assert_true(a != null)
	# The NPC stands apart from Alice; the zombie one metre behind it looks
	# at the NPC and away from her.
	var npc_id: String = _spawn(Vector3(8.5, 0.0, 2.0))
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var zombie_id: String = str(zombies.spawn_zombie(_world, Vector3(8.5, 0.0, 1.0), PI).event["zombie_id"])
	var zombie_mirror: ClientZombieState = (a.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
	var attacked: Callable = func() -> bool:
		for event: Dictionary in zombie_mirror.recent_events():
			if str(event.get("event_type", "")) == ZombieService.EVENT_ATTACKED and str(event.get("target_id", "")) == npc_id:
				return true
		return false
	assert_true(await _cluster.wait_ticks_until(attacked, MAX_WAIT_TICKS), "the client saw the zombie attack the NPC")
	assert_eq(zombie_mirror.rejected_payload_count, 0, "the client accepts an NPC id as a zombie's target")
	for event: Dictionary in zombie_mirror.recent_events():
		if str(event.get("event_type", "")) == ZombieService.EVENT_ATTACKED:
			assert_eq(str(event.get("zombie_id", "")), zombie_id)
			assert_false(event.has("infection"), "what the bite did to the NPC stays on the server")
			assert_false(event.has("target_health_after"))
	assert_true(_health().vitals_of(npc_id).infection.is_infected(), "on the server the bite infected it")
	assert_true(await _cluster.wait_ticks_until(_condition_is([a] as Array[NetworkService], npc_id, "hurt"), MAX_WAIT_TICKS), "and the client sees a hurt NPC")
