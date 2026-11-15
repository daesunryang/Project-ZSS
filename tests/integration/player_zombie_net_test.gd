extends TestCase
## P2-T5 (docs/00 ADR-008): a player who dies of infection leaves a zombie,
## over real ENet (server + 2 clients). Both clients' zombie mirrors show
## the new zombie at the place the player died (existing ZombieNet
## replication), nothing sent to anybody says which player it was, other
## deaths add no zombie, a late joiner sees it, and it survives a restart.

const WORLD: String = "player_zombie_net_test_world"
const SINGLE: String = "t5_single"
const CELL: String = DevWorldSeed.DEV_CELL_ID
## Players spawn at the origin; the item is within pickup range of it.
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const DEATH_AT: Vector3 = Vector3(6.0, 0.0, -3.5)
const DEATH_YAW: float = 0.75
const WAIT_MSEC: int = 10000
const SETTLE_TICKS: int = 20
const LETHAL_DAMAGE: float = 100000.0
const NEVER: float = 1.0e9
## Every infection stage lasts this long (calendar hours): 7.2 world seconds,
## 0.3 real seconds at the default 24x clock; five stages take 1.5 s.
const STAGE_HOURS: float = 0.002
const POSITION_TOLERANCE_M: float = 0.001

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
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var single: ItemDefinition = ItemDefinition.new()
	single.definition_id = SINGLE
	catalog.add(single)
	_config.catalog = catalog
	_config.survival = SurvivalSettings.new()
	_config.survival.respawn_delay_sec = NEVER
	_config.survival.infection_chance_bite = 1.0
	_config.survival.infection_latent_hours = STAGE_HOURS
	_config.survival.infection_early_hours = STAGE_HOURS
	_config.survival.infection_progressing_hours = STAGE_HOURS
	_config.survival.infection_severe_hours = STAGE_HOURS
	_config.survival.infection_terminal_hours = STAGE_HOURS
	_config.survival_net = SurvivalNetSettings.new()
	_config.survival_net.owner_snapshot_rate_hz = 20.0
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	# No development zombies; a zombie that appears never sees, hears, moves
	# or attacks, so its mirror can be compared exactly.
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.sight_range_m = 0.0
	_config.zombie.hearing_multiplier = 0.0
	_config.zombie.wander_pause_min_sec = NEVER
	_config.zombie.wander_pause_max_sec = NEVER
	_config.zombie.wander_speed_mps = 0.0
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	_world = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	if not _save_root.is_empty():
		SaveService.remove_tree(_save_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _zombie_mirror(service: NetworkService) -> ClientZombieState:
	return (service.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state


func _vitals_mirror(service: NetworkService) -> ClientSurvivalState:
	return (service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule).client_state


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _zombies() -> ZombieService:
	return _world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func _settle() -> void:
	for tick: int in range(SETTLE_TICKS):
		await tree.physics_frame


func _zombie_events_of(service: NetworkService) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_zombie_mirror(service).event_received.connect(func(event: Dictionary) -> void: events.append(event))
	return events


func _survival_events_of(service: NetworkService) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_vitals_mirror(service).event_received.connect(func(event: Dictionary) -> void: events.append(event))
	return events


func _infect(player_id: String) -> void:
	var result: ActionResult = _survival().apply_infection_exposure(player_id, InfectionState.Exposure.BITE, "zombie_000001")
	if not result.ok or str(result.event.get("event_type", "")) != SurvivalService.EVENT_PLAYER_INFECTED:
		fail("test setup: infection failed: %s" % result.reason)


## "" when the client's zombie mirror shows exactly the server's zombies
## (ids in spawn order, position, facing, state, health), else what differs.
## The zombies in these tests never move.
func _zombie_mismatch(client: NetworkService) -> String:
	var mirror: ClientZombieState = _zombie_mirror(client)
	var rows: Array[Dictionary] = _zombies().snapshot_rows()
	if mirror.zombie_count() != rows.size():
		return "zombies: mirror %d, server %d" % [mirror.zombie_count(), rows.size()]
	var ids: PackedStringArray = mirror.zombie_ids()
	for index: int in range(rows.size()):
		var row: Dictionary = rows[index]
		var zombie_id: String = str(row["id"])
		if ids[index] != zombie_id:
			return "zombie %d: mirror %s, server %s" % [index, ids[index], zombie_id]
		var mirrored: Dictionary = mirror.get_zombie(zombie_id)
		if (mirrored.get("position", Vector3.INF) as Vector3).distance_to(row["position"] as Vector3) > POSITION_TOLERANCE_M:
			return "%s position: mirror %s, server %s" % [zombie_id, str(mirrored.get("position", null)), str(row["position"])]
		if absf(float(mirrored.get("yaw", INF)) - float(row["yaw"])) > POSITION_TOLERANCE_M:
			return "%s yaw: mirror %s, server %s" % [zombie_id, str(mirrored.get("yaw", null)), str(row["yaw"])]
		if str(mirrored.get("state", "")) != str(row["state"]):
			return "%s state: mirror %s, server %s" % [zombie_id, str(mirrored.get("state", "")), str(row["state"])]
		if absf(float(mirrored.get("health_fraction", -1.0)) - float(row["health_fraction"])) > POSITION_TOLERANCE_M:
			return "%s health: mirror %s, server %s" % [zombie_id, str(mirrored.get("health_fraction", null)), str(row["health_fraction"])]
	return ""


func _assert_zombie_mirrors_match(clients: Array[NetworkService], label: String) -> void:
	var matched: bool = await _wait(func() -> bool:
		for client: NetworkService in clients:
			if not _zombie_mismatch(client).is_empty():
				return false
		return true)
	if matched:
		assert_true(true)
		return
	for client: NetworkService in clients:
		assert_eq(_zombie_mismatch(client), "", "%s (%s)" % [label, client.client_state.local_player_id])


func _events_of(events: Array[Dictionary], event_type: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == event_type:
			matching.append(event)
	return matching


func _event_types(events: Array[Dictionary], player_id: String) -> Array:
	var types: Array = []
	for event: Dictionary in events:
		if str(event.get("player_id", "")) == player_id:
			types.append(str(event.get("event_type", "")))
	return types


# ------------------------------------------------------------ 1. infection death

func test_an_infection_death_puts_one_zombie_where_the_player_died_on_every_client() -> void:
	_config.survival.respawn_delay_sec = 1.0
	_world = ServerComposition.create_world(WORLD, _config)
	assert_not_null(_world)
	if _world == null:
		return
	_world.seed_new_world(_config.dev_seed)
	var item_id: String = _world.inventory.spawn_world_item(SINGLE, 1, CELL, ITEM_AT)
	assert_eq(_cluster.start_server(_world, null), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var clients: Array[NetworkService] = [a, b]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	a.request_pickup(item_id)
	assert_true(await _wait(func() -> bool: return a.client_state.has_inventory_item(item_id)), "alice picked the item up")
	_world.get_player(alice_id).position = DEATH_AT
	_world.get_player(alice_id).yaw = DEATH_YAW
	var a_zombie_events: Array[Dictionary] = _zombie_events_of(a)
	var b_zombie_events: Array[Dictionary] = _zombie_events_of(b)
	var a_survival_events: Array[Dictionary] = _survival_events_of(a)
	var b_survival_events: Array[Dictionary] = _survival_events_of(b)
	assert_eq(_zombie_mirror(a).zombie_count() + _zombie_mirror(b).zombie_count(), 0, "no zombie anywhere yet")

	# --- alice is infected and turns ---
	_infect(alice_id)
	assert_true(await _wait(func() -> bool: return not _survival().is_alive(alice_id)), "alice died of the infection")
	assert_eq(_zombies().zombie_count(), 1, "server: exactly one zombie")
	var zombie_id: String = _zombies().zombie_ids()[0]
	assert_eq(_zombies().get_zombie(zombie_id).position, DEATH_AT, "server: where alice died")
	await _assert_zombie_mirrors_match(clients, "after the infection death")
	for client: NetworkService in clients:
		var mirrored: Dictionary = _zombie_mirror(client).get_zombie(zombie_id)
		var who: String = client.client_state.local_player_id
		assert_true(_zombie_mirror(client).has_zombie(zombie_id), "%s sees the zombie" % who)
		assert_true((mirrored.get("position", Vector3.INF) as Vector3).distance_to(DEATH_AT) <= POSITION_TOLERANCE_M, "%s sees it where alice died: %s" % [who, str(mirrored.get("position", null))])
		assert_true(absf(float(mirrored.get("yaw", INF)) - DEATH_YAW) <= POSITION_TOLERANCE_M, "%s sees it facing alice's way" % who)
		assert_eq(mirrored.get("state", ""), "idle")
		assert_eq(mirrored.get("health_fraction", 0.0), 1.0)
	# Both clients were told by the same reliable event, and nothing in it
	# (or in the mirror) says which player the zombie was.
	await _settle()
	var a_spawned: Array[Dictionary] = _events_of(a_zombie_events, ZombieService.EVENT_SPAWNED)
	var b_spawned: Array[Dictionary] = _events_of(b_zombie_events, ZombieService.EVENT_SPAWNED)
	assert_eq(a_spawned.size(), 1)
	assert_eq(b_spawned, a_spawned, "the same event, same sequence, for both")
	if not a_spawned.is_empty():
		var keys: Array = a_spawned[0].keys()
		keys.sort()
		assert_eq(keys, ["event_type", "position", "sequence", "world_time", "yaw", "zombie_id"])
		for value: Variant in a_spawned[0].values():
			assert_ne(value, alice_id, "the zombie event names the player")
	assert_eq(_zombie_mirror(b).get_zombie(zombie_id).keys().size(), 4, "position, yaw, state, health_fraction only")
	# Bob learns that alice died, not why (ADR-009); alice herself knows.
	var b_saw: Array = _event_types(b_survival_events, alice_id)
	assert_eq(b_saw.slice(0, 1), [SurvivalService.EVENT_PLAYER_DIED], "bob is told that alice died")
	for event_type: String in b_saw:
		# (The new character may already have started on a slow machine.)
		assert_true(event_type in [SurvivalService.EVENT_PLAYER_DIED, SurvivalService.EVENT_PLAYER_RESPAWNED], "bob received %s about alice" % event_type)
	for event: Dictionary in b_survival_events:
		assert_false(event.has("cause") or event.has("infection_stage") or event.has("exposure"), "infection data was sent to another player: %s" % str(event))
	var own_deaths: Array[Dictionary] = _events_of(a_survival_events, SurvivalService.EVENT_PLAYER_DIED)
	assert_eq(own_deaths.size(), 1)
	if not own_deaths.is_empty():
		assert_eq(own_deaths[0].get("cause", ""), SurvivalService.CAUSE_INFECTION)
	# Her belongings lie at the same spot (P2-T4).
	for client: NetworkService in clients:
		assert_eq(client.client_state.world_items.get(item_id, {}).get("position", null), DEATH_AT)

	# --- the new character brings no second zombie ---
	assert_true(await _wait(func() -> bool: return _vitals_mirror(a).is_alive(alice_id) and _vitals_mirror(a).character_generation() == 2), "alice started her next character")
	assert_eq(_vitals_mirror(a).infection_stage(), "none", "the new character is not infected")
	await _settle()
	assert_eq(_zombies().zombie_ids(), PackedStringArray([zombie_id]))
	await _assert_zombie_mirrors_match(clients, "after the new character started")

	# --- a death that is not caused by infection adds no zombie ---
	assert_true(_survival().apply_damage(bob_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_true(await _wait(func() -> bool: return not _vitals_mirror(a).is_alive(bob_id)), "alice sees bob dead")
	await _settle()
	assert_eq(_zombies().zombie_ids(), PackedStringArray([zombie_id]), "server: still one zombie")
	await _assert_zombie_mirrors_match(clients, "after bob's death")
	assert_eq(_events_of(a_zombie_events, ZombieService.EVENT_SPAWNED).size(), 1)

	# --- a late joiner gets the zombie in the join snapshot ---
	var c: NetworkService = await _cluster.join_client("carol")
	if c == null:
		fail("carol did not join")
		return
	assert_eq(_zombie_mirror(c).zombie_ids(), PackedStringArray([zombie_id]))
	var all: Array[NetworkService] = [a, b, c]
	await _assert_zombie_mirrors_match(all, "after carol joined")
	assert_eq(_zombie_mirror(a).rejected_payload_count + _zombie_mirror(b).rejected_payload_count + _zombie_mirror(c).rejected_payload_count, 0, "the server's own messages pass the client validation")


# ------------------------------------------------------------ 2. save and restart

func test_the_player_zombie_survives_a_server_restart() -> void:
	_save_root = "user://test_saves/player_zombie_net_%d" % Time.get_ticks_usec()
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
	_world.get_player(alice_id).position = DEATH_AT
	_world.get_player(alice_id).yaw = DEATH_YAW
	_infect(alice_id)
	assert_true(await _wait(func() -> bool: return not _survival().is_alive(alice_id)), "alice died of the infection")
	assert_eq(_zombies().zombie_count(), 1)
	var zombie_id: String = _zombies().zombie_ids()[0]
	var session1: Array[NetworkService] = [a, b]
	await _assert_zombie_mirrors_match(session1, "session 1")
	var saved_zombie: String = JSON.stringify(_zombies().get_zombie(zombie_id).to_dict())

	# --- full restart (the shutdown saves): state comes only from disk ---
	await _cluster.shutdown()
	_cluster = null
	_world = null
	var persistence2: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence2.load_or_create(WORLD)
	assert_not_null(_world, "world restored from save")
	if _world == null:
		return
	assert_eq(_zombies().zombie_ids(), PackedStringArray([zombie_id]), "the same zombie, once")
	assert_eq(_zombies().get_zombie(zombie_id).position, DEATH_AT)
	assert_eq(JSON.stringify(_zombies().get_zombie(zombie_id).to_dict()), saved_zombie, "restored exactly as saved")
	assert_false(_survival().is_alive(alice_id), "alice is still dead")
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	var b2: NetworkService = await _cluster.join_client("bob")
	if a2 == null or b2 == null:
		fail("clients did not rejoin")
		return
	var session2: Array[NetworkService] = [a2, b2]
	for client: NetworkService in session2:
		assert_eq(_zombie_mirror(client).zombie_ids(), PackedStringArray([zombie_id]), "the join snapshot lists the zombie")
	await _assert_zombie_mirrors_match(session2, "session 2")
	await _settle()
	assert_eq(_zombies().zombie_count(), 1, "logging in again does not repeat the death")
