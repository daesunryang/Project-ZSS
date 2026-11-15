extends TestCase
## Phase 2 acceptance (docs/13 §4: "two clients fight the same zombie and
## confirm the same result"; docs/02 §8). One server and two clients talk
## over real ENet sockets on localhost with the production composition.
##
## Nothing is isolated: client move / pickup / melee intents, the server
## tick with zombie AI, footsteps, survival time rules (bleeding, stamina,
## needs, infection) and the three Phase 2 NetModules all run as shipped.
## Server-side calls are only used to prepare (placing zombies) and to read
## the authoritative state that the client mirrors are compared with.
## Whatever is verified is caused by a client intent and decided by the
## server.
##
## Settings that differ from the production tuning files (new resource
## instances; the cached defaults are never edited):
##   every test
##     zombie.dev_spawn_count 12 -> 0        the tests place their zombies,
##                                           so distances and facing are known
##     network autosave 60 s -> off          saves happen at known points
##                                           (pickup, player leave, shutdown)
##   main scenario
##     dev_seed: two `dev_melee_pipe` items  the pipe is not placed in the dev
##       at the spawn point                  world (docs/15 P2-47); with it the
##                                           fight is short enough for alice to
##                                           survive the default bite damage
##     zombie.bite_chance 0.3 -> 1.0         the first hit is a bite and
##     survival.infection_chance_bite        infects, so the infection checks
##       0.95 -> 1.0                         always run
##     zombie.corpse_remove_delay_sec        the corpse is removed inside the
##       30 -> 1.5                           test instead of 30 s later
##   wound penalty tests
##     zombie.attack_body_parts -> one part  the wound lands on a leg / an arm
##     zombie.bite_chance -> 1.0             a bite of 15 bleeds, and a
##                                           bleeding wound does not heal, so
##                                           the expected factor stays fixed
##     zombie.attack_cooldown_sec 1.5 -> 1e6 exactly one wound
##   infection stage test
##     survival.infection_latent_hours,      the values under test (seconds
##       infection_early_hours               instead of hours)
##     zombie.bite_chance, infection_chance_bite -> 1.0 (as above)

const WORLD: String = "phase2_world"
## Real-time budget of one wait. Waits are conditions with a time limit,
## never frame counts (the headless frame rate is not fixed).
const WAIT_SEC: float = 20.0
const NEVER_SEC: float = 1.0e6
## Yaw 0 faces -Z (docs/09 §14.9).
const YAW_MINUS_Z: float = 0.0
const YAW_PLUS_Z: float = PI
const PIPE_ID: String = "dev_melee_pipe"
const UNARMED_ID: String = "unarmed"
## Within pickup range (2.5 m) of the spawn point.
const PIPE_OFFSETS: PackedVector3Array = [Vector3(1.5, 0.0, 0.5), Vector3(-1.5, 0.0, 0.5)]
## Never sees or hears anything that happens around the spawn point.
const FAR_ZOMBIE_POSITION: Vector3 = Vector3(70.0, 0.0, 70.0)
## In front of the spawn point, inside zombie attack range and unarmed reach.
const CLOSE_ZOMBIE_OFFSET: Vector3 = Vector3(0.0, 0.0, -1.2)
const CORPSE_DELAY_SEC: float = 1.5
## The zombie with its back to the players stands this much further away
## than "one stride outside the hearing distance of a footstep".
const BEHIND_MARGIN_M: float = 1.0
## Alice's walk towards it ends at least this far outside its attack range.
const WALK_STOP_SHORT_M: float = 1.5
## Bob may walk this many times the zombie's distance while closing in.
const APPROACH_LIMIT_FACTOR: float = 2.0
## A client stops this far inside its weapon's reach.
const REACH_MARGIN_M: float = 0.5
## Values that only travel with a periodic snapshot may lag this many periods.
const SNAPSHOT_PERIODS_OF_LAG: float = 2.0
## World time that passes after the restart before "still bleeding" is judged.
const RESUME_SEC: float = 0.5
## Infection stage durations (world seconds) of the two runs of that test.
const QUICK_LATENT_SEC: float = 0.6
const QUICK_EARLY_SEC: float = 0.9
const SLOW_LATENT_SEC: float = 1.8
const SLOW_EARLY_SEC: float = 0.6
## Zero intents sent to stop (the move channel is unreliable).
const STOP_INTENTS: int = 3
## Server ticks waited so anything still in flight arrives.
const SETTLE_TICKS: int = 20
## How often a fighting client asks for a swing. Faster than the weapon
## cooldown on purpose: cooldown refusals are normal play (docs/15 P2-65).
const SWING_INTERVAL_MSEC: int = 300
const FIGHT_MAX_SEC: float = 30.0
const FLOOD_REQUESTS: int = 10
const FORGED_REQUEST_ID: int = 900
const OUT_OF_RANGE_YAW: float = 100.0
const SPEED_HACK_DIRECTION: Vector2 = Vector2(40.0, 0.0)
const HUGE_SEQUENCE: int = 1000000
const WARMUP_TICKS: int = 15
const MEASURE_TICKS: int = 60
const SPEED_TOLERANCE: float = 0.001
## Positions are 32-bit floats: one tick's step is exact to about 1e-6 m.
const STEP_TOLERANCE_M: float = 1.0e-4
const MIRROR_POSITION_TOLERANCE_M: float = 0.05
## JSON text keeps about 14 significant digits (docs/15 P2-12).
const SAVE_TOLERANCE: float = 1.0e-9
const POSITION_SAVE_TOLERANCE_M: float = 1.0e-4
const WORLD_TIME_TOLERANCE_SEC: float = 1.0e-6
const DAMAGE_TOLERANCE: float = 1.0e-6
const SECONDS_PER_HOUR: float = 3600.0

var _root: String = ""
var _net_settings: NetworkSettings = null
var _config: CompositionConfig = null
var _cluster: NetTestCluster = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/phase2_%d" % Time.get_ticks_usec()
	_net_settings = NetworkSettings.new()
	_net_settings.autosave_interval_sec = 0.0
	_config = _new_config()


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
		_cluster = null
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ============================================================ helpers

## Production settings; the two resources the tests change are copies.
func _new_config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.zombie = config.zombie.duplicate() as ZombieSettings
	config.zombie.dev_spawn_count = 0
	config.survival = config.survival.duplicate() as SurvivalSettings
	return config


func _persistence() -> WorldPersistence:
	return WorldPersistence.new(SaveService.new(_root), _config)


## Server without saving, on a new empty world. Null on failure.
func _start_plain() -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config)
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	if world == null or _cluster.start_server(world, null) != OK:
		return null
	return world


## Joins "alice" and "bob"; empty on failure.
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


## Polls `condition` once per frame for up to `timeout_sec` of real time.
func _eventually(condition: Callable, timeout_sec: float = WAIT_SEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func _settle() -> void:
	for tick: int in range(SETTLE_TICKS):
		await tree.physics_frame


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _combat(world: ServerWorld) -> CombatService:
	return world.get_system(CombatService.SYSTEM_ID) as CombatService


func _combat_module(service: NetworkService) -> CombatNetModule:
	return service.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule


## Preparation only: puts a zombie into the server world.
func _spawn(world: ServerWorld, position: Vector3, yaw: float) -> String:
	return str(_zombies(world).spawn_zombie(world, position, yaw).event.get("zombie_id", ""))


## Every zombie event the server produced, in server order (unfiltered).
func _record_server_zombie_events() -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var module: ZombieNetModule = _cluster.server.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule
	module.server_events_drained.connect(func(drained: Array[Dictionary]) -> void: events.append_array(drained))
	return events


func _events_of_zombie(events: Array[Dictionary], zombie_id: String, types: PackedStringArray) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("zombie_id", "")) == zombie_id and types.has(str(event.get("event_type", ""))):
			result.append(event)
	return result


func _events_of_type(events: Array[Dictionary], event_type: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == event_type:
			result.append(event)
	return result


func _observable_list(events: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in events:
		result.append(Observer.observable(event))
	return result


func _column(events: Array[Dictionary], key: String) -> Array:
	var values: Array = []
	for event: Dictionary in events:
		values.append(event.get(key, null))
	return values


func _wound_dicts(world: ServerWorld, player_id: String) -> Array[Dictionary]:
	var wounds: Array[Dictionary] = []
	for wound: Wound in _survival(world).get_vitals(player_id).injuries:
		wounds.append(wound.to_dict())
	return wounds


## True when the owner's mirror holds exactly the server's health, wounds,
## infection stage and alive flag in this frame. Stamina is left out: it
## regenerates every tick and only travels with the 2 Hz owner snapshot.
func _owner_mirror_matches(watch: Observer, world: ServerWorld, player_id: String) -> bool:
	var vitals: PlayerVitals = _survival(world).get_vitals(player_id)
	var mirror: ClientSurvivalState = watch.survival_mirror
	return (
		mirror.health() == vitals.health
		and mirror.wounds() == _wound_dicts(world, player_id)
		and mirror.infection_stage() == InfectionState.stage_name(vitals.infection.stage)
		and mirror.is_alive(player_id) == vitals.is_alive()
	)


## Facing for a move direction (x -> +X, y -> +Z).
func _yaw_of(direction: Vector2, fallback: float = YAW_MINUS_Z) -> float:
	return ZombiePerception.yaw_towards(Vector3(direction.x, 0.0, direction.y), fallback)


## Sends `direction.call()` as a move intent every server tick until
## `done.call()` holds (true), then stops. Gives up (false) once the client
## has asked for `max_distance_m` of walking (a distance limit, counted in
## server ticks so that a stalled frame cannot change how far the player
## gets) or after WAIT_SEC of real time.
func _walk(client: NetworkService, direction: Callable, done: Callable, max_distance_m: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(WAIT_SEC * 1000.0)
	var ticks_left: int = ceili(max_distance_m * float(Engine.physics_ticks_per_second) / _config.gameplay.move_speed_mps)
	var reached: bool = false
	var yaw: float = YAW_MINUS_Z
	while ticks_left > 0 and Time.get_ticks_msec() < deadline:
		if done.call():
			reached = true
			break
		var step: Vector2 = direction.call()
		yaw = _yaw_of(step, yaw)
		client.send_move_intent(step, yaw)
		ticks_left -= 1
		await tree.physics_frame
	if not reached:
		reached = bool(done.call())
	for index: int in range(STOP_INTENTS):
		client.send_move_intent(Vector2.ZERO, yaw)
		await tree.physics_frame
	return reached


func _approx(a: float, b: float, tolerance: float) -> bool:
	return absf(a - b) <= tolerance


## Deep comparison that allows `tolerance` between numbers (save files).
func _approx_equal(a: Variant, b: Variant, tolerance: float = SAVE_TOLERANCE) -> bool:
	var a_is_number: bool = typeof(a) == TYPE_FLOAT or typeof(a) == TYPE_INT
	var b_is_number: bool = typeof(b) == TYPE_FLOAT or typeof(b) == TYPE_INT
	if a_is_number and b_is_number:
		return absf(float(a) - float(b)) <= tolerance
	if typeof(a) != typeof(b):
		return false
	if typeof(a) == TYPE_ARRAY:
		var a_list: Array = a
		var b_list: Array = b
		if a_list.size() != b_list.size():
			return false
		for index: int in range(a_list.size()):
			if not _approx_equal(a_list[index], b_list[index], tolerance):
				return false
		return true
	if typeof(a) == TYPE_DICTIONARY:
		var a_map: Dictionary = a
		var b_map: Dictionary = b
		if a_map.size() != b_map.size():
			return false
		for key: Variant in a_map:
			if not b_map.has(key) or not _approx_equal(a_map[key], b_map[key], tolerance):
				return false
		return true
	return a == b


func _carried_definitions(world: ServerWorld, player_id: String) -> PackedStringArray:
	var definitions: PackedStringArray = []
	for item: ItemInstance in world.inventory.items_in_inventory(world.get_player(player_id).inventory_id):
		definitions.append(item.definition_id)
	return definitions


## Adds a client and records what its mirrors hold at the moment the join
## snapshot was applied (later ticks change them). Null on failure.
func _join_and_capture(player_key: String, capture: Dictionary) -> NetworkService:
	var client: NetworkService = _cluster.add_client(player_key)
	client.join_accepted.connect(func(player_id: String) -> void:
		var watch: Observer = Observer.new(client)
		var carried: PackedStringArray = []
		for item: Dictionary in client.client_state.inventory:
			carried.append(str(item["definition_id"]))
		capture["player_id"] = player_id
		capture["position"] = client.client_state.position_of(player_id)
		capture["inventory"] = carried
		capture["world_items"] = client.client_state.world_items.size()
		capture["zombie_ids"] = watch.zombie_mirror.zombie_ids()
		capture["zombies"] = watch.zombie_mirror.zombies.duplicate(true)
		capture["health"] = watch.survival_mirror.health()
		capture["stamina"] = watch.survival_mirror.stamina()
		capture["wounds"] = watch.survival_mirror.wounds()
		capture["infection_stage"] = watch.survival_mirror.infection_stage()
		capture["alive"] = watch.survival_mirror.is_alive(player_id))
	var joined: bool = await _eventually(func() -> bool: return capture.has("player_id"))
	return client if joined else null


func _assert_no_error_logs(stage: String) -> void:
	for line: String in GameLogger.captured_lines():
		if line.contains("[ERROR]") or line.contains("[FATAL]"):
			fail("%s: error logged: %s" % [stage, line])
			return
	assert_true(true, stage)


# ============================================================ observer

## Everything one client receives, in arrival order, plus what its mirrors
## said at the moment an event was announced.
class Observer extends RefCounted:
	## docs/15 P2-9, P2-85: only the attacked player gets these.
	const PRIVATE_ZOMBIE_KEYS: PackedStringArray = ["infection", "target_health_after"]
	const CHANNEL_ZOMBIE: String = "zombie"
	const CHANNEL_COMBAT: String = "combat"

	var client: NetworkService
	var zombie_mirror: ClientZombieState
	var survival_mirror: ClientSurvivalState
	var combat: CombatNetModule
	var zombie_events: Array[Dictionary] = []
	var combat_events: Array[Dictionary] = []
	var survival_events: Array[Dictionary] = []
	## Rows [request_id, ok, reason].
	var melee_results: Array[Array] = []
	## request_id -> [ok, reason]
	var pickup_results: Dictionary[int, Array] = {}
	## Zombie and combat events as they arrived: rows [channel, event]
	## (zombie events without private fields and sequence).
	var arrival: Array[Array] = []
	## zombie_id -> mirror state at each state change / death announcement.
	var mirror_states: Dictionary[String, Array] = {}
	## zombie_id -> mirror row when its death was announced.
	var death_rows: Dictionary[String, Dictionary] = {}
	## Own infection stage in the mirror at each infection event.
	var infection_stages: PackedStringArray = []

	func _init(service: NetworkService) -> void:
		client = service
		zombie_mirror = (service.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
		survival_mirror = (service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule).client_state
		combat = service.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule
		zombie_mirror.event_received.connect(_on_zombie_event)
		survival_mirror.event_received.connect(_on_survival_event)
		combat.combat_event.connect(_on_combat_event)
		combat.melee_result.connect(_on_melee_result)
		service.pickup_result.connect(_on_pickup_result)

	## A zombie event as every client may see it.
	static func observable(event: Dictionary) -> Dictionary:
		var copy: Dictionary = event.duplicate(true)
		for key: String in PRIVATE_ZOMBIE_KEYS:
			copy.erase(key)
		copy.erase(ClientZombieState.KEY_SEQUENCE)
		return copy

	func local_id() -> String:
		return client.client_state.local_player_id

	func own_position() -> Vector3:
		return client.client_state.position_of(local_id())

	func zombie_state(zombie_id: String) -> String:
		return str(zombie_mirror.get_zombie(zombie_id).get("state", ""))

	## Distance on the XZ plane between this client's own mirrored position
	## and the mirrored zombie (INF when the zombie is not mirrored).
	func distance_to_zombie(zombie_id: String) -> float:
		if not zombie_mirror.has_zombie(zombie_id):
			return INF
		return ZombiePerception.flat_distance(own_position(), zombie_mirror.get_zombie(zombie_id)["position"])

	## Unit move direction towards the mirrored zombie (ZERO when unknown).
	func direction_to_zombie(zombie_id: String) -> Vector2:
		if not zombie_mirror.has_zombie(zombie_id):
			return Vector2.ZERO
		var offset: Vector3 = (zombie_mirror.get_zombie(zombie_id)["position"] as Vector3) - own_position()
		return Vector2(offset.x, offset.z).normalized()

	## Aim that points from this client's mirrored position at the zombie.
	func aim_at_zombie(zombie_id: String) -> float:
		if not zombie_mirror.has_zombie(zombie_id):
			return 0.0
		return ZombiePerception.yaw_towards((zombie_mirror.get_zombie(zombie_id)["position"] as Vector3) - own_position(), 0.0)

	func accepted_swings() -> int:
		var count: int = 0
		for row: Array in melee_results:
			if row[1] == true:
				count += 1
		return count

	func _on_zombie_event(event: Dictionary) -> void:
		zombie_events.append(event)
		arrival.append([CHANNEL_ZOMBIE, observable(event)])
		var zombie_id: String = str(event["zombie_id"])
		var event_type: String = str(event["event_type"])
		if event_type == ZombieService.EVENT_STATE_CHANGED or event_type == ZombieService.EVENT_DIED:
			(mirror_states.get_or_add(zombie_id, []) as Array).append(zombie_state(zombie_id))
		if event_type == ZombieService.EVENT_DIED:
			death_rows[zombie_id] = zombie_mirror.get_zombie(zombie_id).duplicate(true)

	func _on_survival_event(event: Dictionary) -> void:
		survival_events.append(event)
		var event_type: String = str(event["event_type"])
		if event_type == SurvivalService.EVENT_PLAYER_INFECTED or event_type == SurvivalService.EVENT_PLAYER_INFECTION_STAGE_CHANGED:
			infection_stages.append(survival_mirror.infection_stage())

	func _on_combat_event(event: Dictionary) -> void:
		combat_events.append(event)
		arrival.append([CHANNEL_COMBAT, event])

	func _on_melee_result(request_id: int, ok: bool, reason: String) -> void:
		melee_results.append([request_id, ok, reason])

	func _on_pickup_result(request_id: int, ok: bool, reason: String) -> void:
		pickup_results[request_id] = [ok, reason]


# ============================================================ main scenario
# Acceptance items 1 (sound vs sight), 2 (zombie attack, wound, infection,
# who learns what), 3 (both clients kill the same zombie and agree),
# 6 (save -> restart -> load, then a client that drops and rejoins) and
# 7 (manipulated requests mid-fight).

func test_two_clients_fight_one_zombie_agree_on_the_result_and_it_survives_a_restart() -> void:
	var pipes: DevWorldSeed = DevWorldSeed.new()
	pipes.item_definition_ids = PackedStringArray([PIPE_ID, PIPE_ID])
	pipes.item_positions = PackedVector3Array([_config.gameplay.player_spawn_position + PIPE_OFFSETS[0], _config.gameplay.player_spawn_position + PIPE_OFFSETS[1]])
	_config.dev_seed = pipes
	_config.zombie.bite_chance = 1.0
	_config.zombie.corpse_remove_delay_sec = CORPSE_DELAY_SEC
	_config.survival.infection_chance_bite = 1.0
	var zombie_settings: ZombieSettings = _config.zombie
	var survival_settings: SurvivalSettings = _config.survival
	var pipe: MeleeWeaponDefinition = _config.melee_weapons.get_definition(PIPE_ID)
	assert_not_null(pipe, "the production weapon catalog has the pipe")
	if pipe == null:
		return

	# ------------------------------------------------------------ session 1
	var persistence: WorldPersistence = _persistence()
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world, "new world created")
	if world == null:
		return
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(world, persistence), OK)
	var server_zombie_events: Array[Dictionary] = _record_server_zombie_events()
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var watch_a: Observer = Observer.new(a)
	var watch_b: Observer = Observer.new(b)
	var watchers: Array[Observer] = [watch_a, watch_b]
	var alice_id: String = watch_a.local_id()
	var bob_id: String = watch_b.local_id()
	var spawn_point: Vector3 = world.get_player(alice_id).position

	# Both pick up a pipe: the weapon of the fight comes from the inventory.
	var item_ids: PackedStringArray = PackedStringArray(a.client_state.world_items.keys())
	item_ids.sort()
	assert_eq(item_ids.size(), 2, "two pipes lie at the spawn point")
	if item_ids.size() != 2:
		return
	var a_pick: int = a.request_pickup(item_ids[0])
	var b_pick: int = b.request_pickup(item_ids[1])
	var armed: bool = await _eventually(func() -> bool:
		return watch_a.pickup_results.has(a_pick) and watch_b.pickup_results.has(b_pick) and a.client_state.has_inventory_item(item_ids[0]) and b.client_state.has_inventory_item(item_ids[1]))
	assert_true(armed, "both pickups answered and replicated")
	assert_eq(watch_a.pickup_results.get(a_pick, []), [true, ""])
	assert_eq(watch_b.pickup_results.get(b_pick, []), [true, ""])
	assert_eq(_combat(world).weapon_for(world, alice_id).weapon_id, PIPE_ID, "alice fights with the carried pipe")
	assert_eq(_combat(world).weapon_for(world, bob_id).weapon_id, PIPE_ID)

	# Preparation: one zombie far away, one with its back to the players. The
	# second stands inside its sight range of the spawn point, but so far
	# that the first footstep of a walk towards it is still inaudible.
	var noise: NoiseService = world.get_system(NoiseService.SYSTEM_ID) as NoiseService
	var hearing_m: float = noise.max_audible_distance(_config.player_noise.footstep_loudness, zombie_settings.hearing_multiplier)
	var stride_m: float = _config.player_noise.stride_length_m
	var behind_m: float = hearing_m + stride_m + BEHIND_MARGIN_M
	var sight_m: float = zombie_settings.effective_sight_range_m()
	var half_angle: float = deg_to_rad(zombie_settings.sight_half_angle_deg)
	assert_true(hearing_m > stride_m and behind_m < sight_m, "footsteps carry %.1f m, sight %.1f m, zombie %.1f m away" % [hearing_m, sight_m, behind_m])
	var far_id: String = _spawn(world, FAR_ZOMBIE_POSITION, YAW_MINUS_Z)
	var zombie_start: Vector3 = spawn_point + Vector3(0.0, 0.0, -behind_m)
	var zombie_id: String = _spawn(world, zombie_start, YAW_MINUS_Z)
	assert_false(far_id.is_empty() or zombie_id.is_empty(), "zombies placed")
	var mirrored: bool = await _eventually(func() -> bool:
		return watch_a.zombie_state(zombie_id) == "idle" and watch_b.zombie_state(zombie_id) == "idle" and watch_a.zombie_mirror.has_zombie(far_id) and watch_b.zombie_mirror.has_zombie(far_id))
	assert_true(mirrored, "both clients mirror both zombies")
	assert_false(ZombiePerception.can_see(zombie_start, YAW_MINUS_Z, spawn_point, sight_m, half_angle), "the players are in range but behind the zombie")

	# --- item 1: heard first, seen afterwards --------------------------------
	# Alice walks at the zombie's back until her own mirror shows a reaction.
	# The distance limit stops her before she would walk into it.
	var walk_limit_m: float = behind_m - zombie_settings.attack_range_m - WALK_STOP_SHORT_M
	var reacted: bool = await _walk(a, func() -> Vector2: return Vector2(0.0, -1.0), func() -> bool: return watch_a.zombie_state(zombie_id) != "idle", walk_limit_m)
	assert_true(reacted, "the zombie reacted to alice walking up behind it")
	var chased: bool = await _eventually(func() -> bool:
		return ["chase", "attack"].has(watch_a.zombie_state(zombie_id)) and ["chase", "attack"].has(watch_b.zombie_state(zombie_id)))
	assert_true(chased, "both mirrors show the zombie going after its target")
	var sense_types: PackedStringArray = [ZombieService.EVENT_DETECTED, ZombieService.EVENT_STATE_CHANGED]
	var senses: Array[Dictionary] = _events_of_zombie(server_zombie_events, zombie_id, sense_types)
	assert_true(senses.size() >= 4, "server recorded hearing and seeing (%d events)" % senses.size())
	if senses.size() < 4:
		return
	var heard: Dictionary = senses[0]
	assert_eq([heard["event_type"], heard["sense"], heard["target_id"]], [ZombieService.EVENT_DETECTED, ZombieService.SENSE_SOUND, alice_id], "first it hears alice's footstep")
	var heard_at: Vector3 = Vector3(heard["position"][0], heard["position"][1], heard["position"][2])
	assert_false(ZombiePerception.can_see(zombie_start, YAW_MINUS_Z, heard_at, sight_m, half_angle), "... from outside its view cone")
	assert_true(ZombiePerception.flat_distance(zombie_start, heard_at) <= hearing_m, "... within hearing distance")
	assert_eq([senses[1]["event_type"], senses[1]["from"], senses[1]["to"], senses[1]["cause"]], [ZombieService.EVENT_STATE_CHANGED, "idle", "investigate", ZombieService.CAUSE_NOISE], "the noise makes it investigate")
	assert_eq([senses[2]["event_type"], senses[2]["sense"], senses[2]["target_id"]], [ZombieService.EVENT_DETECTED, ZombieService.SENSE_SIGHT, alice_id], "having turned, it sees alice")
	assert_eq([senses[3]["event_type"], senses[3]["from"], senses[3]["to"], senses[3]["cause"], senses[3]["target_id"]], [ZombieService.EVENT_STATE_CHANGED, "investigate", "chase", ZombieService.CAUSE_SIGHT, alice_id], "sight makes it chase")
	for watch: Observer in watchers:
		var received: Array[Dictionary] = _events_of_zombie(watch.zombie_events, zombie_id, sense_types)
		assert_true(received.size() >= 4, "%s received the detections" % watch.local_id())
		if received.size() < 4:
			return
		assert_eq(_observable_list(received.slice(0, 4)), _observable_list(senses.slice(0, 4)), "%s got the same events in the same order" % watch.local_id())
		assert_eq((watch.mirror_states.get(zombie_id, []) as Array).slice(0, 2), ["investigate", "chase"], "%s's mirror followed each change" % watch.local_id())
	assert_true(ZombiePerception.flat_distance(world.get_player(alice_id).position, zombie_start) > zombie_settings.attack_range_m, "alice stopped before reaching the zombie")

	# Bob closes in on the zombie, steering by his own mirrors.
	var reach_m: float = pipe.range_m - REACH_MARGIN_M
	var bob_near: bool = await _walk(b, func() -> Vector2: return watch_b.direction_to_zombie(zombie_id), func() -> bool: return watch_b.distance_to_zombie(zombie_id) <= reach_m, behind_m * APPROACH_LIMIT_FACTOR)
	assert_true(bob_near, "bob reached the zombie")

	# --- item 2: the zombie attacks alice ------------------------------------
	var bitten: bool = await _eventually(func() -> bool:
		return not _events_of_type(watch_a.zombie_events, ZombieService.EVENT_ATTACKED).is_empty() and not _events_of_type(watch_b.zombie_events, ZombieService.EVENT_ATTACKED).is_empty())
	assert_true(bitten, "both clients observed the zombie's first attack")
	if not bitten:
		return
	var server_hit: Dictionary = _events_of_type(server_zombie_events, ZombieService.EVENT_ATTACKED)[0]
	var alice_hit: Dictionary = _events_of_type(watch_a.zombie_events, ZombieService.EVENT_ATTACKED)[0]
	var bob_hit: Dictionary = _events_of_type(watch_b.zombie_events, ZombieService.EVENT_ATTACKED)[0]
	assert_eq([server_hit["zombie_id"], server_hit["target_id"], server_hit["wound_type"]], [zombie_id, alice_id, "bite"], "the server decided: the zombie bit alice")
	assert_eq(server_hit["infection"], SurvivalService.EVENT_PLAYER_INFECTED, "... and the bite infected her")
	assert_true(zombie_settings.attack_body_parts.has(str(server_hit["body_part"])), "body part %s" % str(server_hit["body_part"]))
	assert_eq(alice_hit["infection"], server_hit["infection"], "alice learns her infection result")
	assert_eq(alice_hit["target_health_after"], server_hit["target_health_after"], "and her exact health")
	assert_false(bob_hit.has("infection") or bob_hit.has("target_health_after"), "bob gets neither (docs/15 P2-9)")
	assert_eq(Observer.observable(bob_hit), Observer.observable(server_hit), "bob sees who was hit, how and where")
	assert_eq(Observer.observable(alice_hit), Observer.observable(server_hit))
	assert_eq(bob_hit["sequence"], alice_hit["sequence"], "same place in the event stream")
	assert_eq([bob_hit["target_id"], bob_hit["wound_type"], bob_hit["body_part"], bob_hit["damage"], bob_hit["target_died"]], [alice_id, "bite", server_hit["body_part"], zombie_settings.bite_damage, false])
	var agreed: bool = await _eventually(func() -> bool: return _owner_mirror_matches(watch_a, world, alice_id) and not watch_a.survival_mirror.wounds().is_empty())
	assert_true(agreed, "alice's own mirror equals the server's health, wounds and infection stage")
	assert_eq(watch_a.survival_mirror.infection_stage(), "latent")
	assert_eq(_survival(world).infection_stage(alice_id), InfectionState.Stage.LATENT, "server and owner agree on the stage")
	assert_true(watch_a.survival_mirror.health() < survival_settings.max_health, "alice lost health")
	var bob_saw_wound: bool = await _eventually(func() -> bool: return not _events_of_type(watch_b.survival_events, SurvivalService.EVENT_PLAYER_WOUNDED).is_empty())
	assert_true(bob_saw_wound, "bob is told that alice was wounded")
	var public_wounds: Array[Dictionary] = _events_of_type(watch_b.survival_events, SurvivalService.EVENT_PLAYER_WOUNDED)
	if not public_wounds.is_empty():
		assert_eq([public_wounds[0]["scope"], public_wounds[0]["player_id"], public_wounds[0]["body_part"], public_wounds[0]["wound_type"], public_wounds[0]["died"]], [ClientSurvivalState.SCOPE_PUBLIC, alice_id, server_hit["body_part"], "bite", false])
	assert_eq(watch_b.survival_mirror.infection_stage(), "none", "bob's own state is untouched")
	assert_eq(watch_b.survival_mirror.health(), _survival(world).get_vitals(bob_id).health)
	assert_eq(watch_b.survival_mirror.health(), survival_settings.max_health)
	assert_true(watch_b.survival_mirror.is_alive(alice_id), "bob knows alice is alive")

	# --- item 7: manipulated requests in the middle of the fight -------------
	await _settle()
	var max_health: float = zombie_settings.max_health
	assert_eq(_zombies(world).get_zombie(zombie_id).health, max_health, "nobody has hit the zombie yet")
	var bob_position: Vector3 = world.get_player(bob_id).position
	var bob_stamina: float = _survival(world).get_vitals(bob_id).stamina
	var server: NetworkService = _cluster.server
	var bad_type_before: int = server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE)
	var bad_aim_before: int = server.rejected_intent_count(CombatService.REASON_BAD_AIM_YAW)
	var bad_direction_before: int = server.rejected_intent_count(IntentValidator.REASON_BAD_DIRECTION)
	var limited_before: int = server.rejected_intent_count(NetworkService.RATE_LIMITED)
	var bob_aim: float = watch_b.aim_at_zombie(zombie_id)
	# The request has no player argument; a player id put where the request
	# number belongs is just a malformed request from bob.
	watch_b.combat.send_raw_melee_request(alice_id, bob_aim)
	watch_b.combat.send_raw_melee_request(FORGED_REQUEST_ID, OUT_OF_RANGE_YAW)
	watch_b.combat.send_raw_melee_request(FORGED_REQUEST_ID + 1, NAN)
	b.send_raw_move_intent(HUGE_SEQUENCE, SPEED_HACK_DIRECTION, 0.0)
	var refused: bool = await _eventually(func() -> bool:
		return (
			server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE) == bad_type_before + 1
			and server.rejected_intent_count(CombatService.REASON_BAD_AIM_YAW) == bad_aim_before + 2
			and server.rejected_intent_count(IntentValidator.REASON_BAD_DIRECTION) == bad_direction_before + 1
			and watch_b.melee_results.size() == 2
		))
	assert_true(refused, "the server refused all four manipulated requests")
	await _settle()
	assert_eq(watch_b.melee_results, [[FORGED_REQUEST_ID, false, CombatService.REASON_BAD_AIM_YAW], [FORGED_REQUEST_ID + 1, false, CombatService.REASON_BAD_AIM_YAW]])
	assert_eq(_zombies(world).get_zombie(zombie_id).health, max_health, "the zombie was not touched")
	assert_eq(world.get_player(bob_id).position, bob_position, "bob did not move")
	assert_eq(_survival(world).get_vitals(bob_id).stamina, bob_stamina, "no stamina spent")
	assert_eq(_combat(world).cooldown_remaining(bob_id), 0.0, "no cooldown started")
	assert_eq(_combat_module(server).recent_events().size(), 0, "no combat event was produced")
	assert_eq(watch_a.combat_events.size() + watch_b.combat_events.size(), 0)

	# A flood of valid requests: one swing, the rest refused.
	bob_aim = watch_b.aim_at_zombie(zombie_id)
	for index: int in range(FLOOD_REQUESTS):
		watch_b.combat.request_melee_attack(bob_aim)
	var flooded: bool = await _eventually(func() -> bool:
		return watch_b.melee_results.size() == 2 + FLOOD_REQUESTS and watch_a.combat_events.size() == 1 and watch_b.combat_events.size() == 1)
	assert_true(flooded, "every flood request was answered and one swing replicated")
	if not flooded:
		return
	var accepted: int = 0
	var limited: int = 0
	var cooling: int = 0
	for row: Array in watch_b.melee_results.slice(2):
		if row[1] == true:
			accepted += 1
		elif row[2] == NetworkService.RATE_LIMITED:
			limited += 1
		elif row[2] == CombatService.REASON_ON_COOLDOWN:
			cooling += 1
	assert_eq(accepted, 1, "exactly one swing was accepted")
	assert_eq(accepted + limited + cooling, FLOOD_REQUESTS, "the rest hit the rate limit or the cooldown")
	assert_true(limited >= FLOOD_REQUESTS - _config.combat_net.melee_intent_burst - 1, "rate limited: %d" % limited)
	assert_eq(server.rejected_intent_count(NetworkService.RATE_LIMITED) - limited_before, limited)
	var first_swing: Dictionary = _combat_module(server).recent_events()[0]
	assert_eq(watch_a.combat_events[0], first_swing, "alice received the server's event")
	assert_eq(watch_b.combat_events[0], first_swing, "bob received the server's event")
	assert_eq([first_swing[ClientCombatState.KEY_SEQUENCE], first_swing[ClientCombatState.KEY_ATTACKER_ID], first_swing[ClientCombatState.KEY_WEAPON_ID], first_swing[ClientCombatState.KEY_HIT], first_swing[ClientCombatState.KEY_TARGET_ID]], [1, bob_id, PIPE_ID, true, zombie_id], "the attacker is the sending peer's player")
	var first_damage: float = first_swing[ClientCombatState.KEY_DAMAGE]
	assert_true(first_damage >= pipe.base_damage * _config.combat.damage_roll_min and first_damage <= pipe.base_damage * _config.combat.damage_roll_max, "damage %.3f is one unwounded pipe hit" % first_damage)
	assert_eq(_zombies(world).get_zombie(zombie_id).health, max_health - first_damage, "the flood cost the zombie exactly one hit")
	assert_eq(first_swing[ClientCombatState.KEY_TARGET_HEALTH_AFTER], max_health - first_damage)
	assert_eq([_combat(world).cooldown_remaining(alice_id), _survival(world).get_vitals(alice_id).stamina], [0.0, survival_settings.max_stamina], "nothing bob sent acted as alice")
	var fraction: float = (max_health - first_damage) / max_health
	var health_mirrored: bool = await _eventually(func() -> bool:
		return _approx(watch_a.zombie_mirror.get_zombie(zombie_id)["health_fraction"], fraction, DAMAGE_TOLERANCE) and _approx(watch_b.zombie_mirror.get_zombie(zombie_id)["health_fraction"], fraction, DAMAGE_TOLERANCE))
	assert_true(health_mirrored, "both zombie mirrors show the health left by that hit")

	# --- item 3: both clients fight the zombie until it dies ------------------
	var sent_a: int = 0
	var sent_b: int = watch_b.melee_results.size()
	var next_a: int = Time.get_ticks_msec()
	var next_b: int = Time.get_ticks_msec() + SWING_INTERVAL_MSEC
	var fight_deadline: int = Time.get_ticks_msec() + int(FIGHT_MAX_SEC * 1000.0)
	while Time.get_ticks_msec() < fight_deadline:
		if watch_a.zombie_state(zombie_id) == "dead" and watch_b.zombie_state(zombie_id) == "dead":
			break
		var now: int = Time.get_ticks_msec()
		if now >= next_a:
			if watch_a.combat.request_melee_attack(watch_a.aim_at_zombie(zombie_id)) != CombatNetModule.NO_REQUEST:
				sent_a += 1
			next_a = now + SWING_INTERVAL_MSEC
		if now >= next_b:
			if watch_b.combat.request_melee_attack(watch_b.aim_at_zombie(zombie_id)) != CombatNetModule.NO_REQUEST:
				sent_b += 1
			next_b = now + SWING_INTERVAL_MSEC
		await tree.process_frame
	assert_eq([watch_a.zombie_state(zombie_id), watch_b.zombie_state(zombie_id)], ["dead", "dead"], "both mirrors show the zombie dead")
	assert_false(_zombies(world).get_zombie(zombie_id) == null or _zombies(world).get_zombie(zombie_id).is_alive(), "the server's zombie is dead")
	var answered: bool = await _eventually(func() -> bool: return watch_a.melee_results.size() == sent_a and watch_b.melee_results.size() == sent_b)
	assert_true(answered, "every request got its answer (%d/%d, %d/%d)" % [watch_a.melee_results.size(), sent_a, watch_b.melee_results.size(), sent_b])
	await _settle()
	# Same events, same order, same payload on the server and both clients.
	# No field is left out of this comparison.
	var record: Array[Dictionary] = _combat_module(server).recent_events()
	assert_eq(watch_a.combat_events, record, "alice's combat events are the server's record")
	assert_eq(watch_b.combat_events, record, "bob's combat events are the server's record")
	assert_eq(_combat_module(a).recent_events(), _combat_module(b).recent_events(), "combat mirrors agree")
	assert_eq(_column(record, ClientCombatState.KEY_SEQUENCE), range(1, record.size() + 1), "no gap in the sequence")
	var hits: Array[Dictionary] = []
	var health_left: float = max_health
	var kills: int = 0
	var hitters: Dictionary[String, int] = {}
	for event: Dictionary in record:
		assert_eq(event[ClientCombatState.KEY_WEAPON_ID], PIPE_ID)
		if event[ClientCombatState.KEY_HIT] != true:
			assert_eq(kills, 1, "a swing aimed from the client's mirrors only misses once the zombie is dead (#%d)" % event[ClientCombatState.KEY_SEQUENCE])
			continue
		var attacker_id: String = event[ClientCombatState.KEY_ATTACKER_ID]
		var damage: float = event[ClientCombatState.KEY_DAMAGE]
		assert_eq(event[ClientCombatState.KEY_TARGET_ID], zombie_id, "every hit is on the same zombie")
		assert_true(damage > 0.0 and damage <= pipe.base_damage * _config.combat.damage_roll_max, "damage %.3f" % damage)
		assert_true(_approx(event[ClientCombatState.KEY_TARGET_HEALTH_AFTER], maxf(health_left - damage, 0.0), DAMAGE_TOLERANCE), "health chain at #%d" % event[ClientCombatState.KEY_SEQUENCE])
		health_left = event[ClientCombatState.KEY_TARGET_HEALTH_AFTER]
		assert_eq(event[ClientCombatState.KEY_TARGET_DIED], health_left <= 0.0, "death is announced by the blow that empties the health")
		if event[ClientCombatState.KEY_TARGET_DIED] == true:
			kills += 1
		hitters[attacker_id] = int(hitters.get(attacker_id, 0)) + 1
		hits.append(event)
	assert_eq(kills, 1, "the zombie died exactly once")
	assert_eq(health_left, 0.0)
	assert_true(hitters.has(alice_id) and hitters.has(bob_id), "both players hit it: %s" % str(hitters))
	for watch: Observer in watchers:
		assert_eq(watch.accepted_swings(), _column(record, ClientCombatState.KEY_ATTACKER_ID).count(watch.local_id()), "one event per accepted swing of %s" % watch.local_id())
	# The zombie module told the same story (docs/15 §6.10).
	var damaged: Array[Dictionary] = _events_of_zombie(server_zombie_events, zombie_id, [ZombieService.EVENT_DAMAGED])
	assert_eq(damaged.size(), hits.size(), "one zombie_damaged per hit")
	for index: int in range(mini(damaged.size(), hits.size())):
		assert_eq([damaged[index]["source_id"], damaged[index]["damage"], damaged[index]["health_after"], damaged[index]["died"]], [hits[index][ClientCombatState.KEY_ATTACKER_ID], hits[index][ClientCombatState.KEY_DAMAGE], hits[index][ClientCombatState.KEY_TARGET_HEALTH_AFTER], hits[index][ClientCombatState.KEY_TARGET_DIED]], "hit %d" % index)
	assert_eq(watch_a.arrival, watch_b.arrival, "zombie and combat events interleave identically on both clients")
	var damaged_seen: int = 0
	var hits_seen: int = 0
	var died_seen: bool = false
	for row: Array in watch_a.arrival:
		var arrived: Dictionary = row[1]
		if row[0] == Observer.CHANNEL_ZOMBIE and arrived["zombie_id"] == zombie_id:
			if arrived["event_type"] == ZombieService.EVENT_DAMAGED:
				damaged_seen += 1
			elif arrived["event_type"] == ZombieService.EVENT_DIED:
				died_seen = true
		elif row[0] == Observer.CHANNEL_COMBAT and arrived[ClientCombatState.KEY_HIT] == true:
			hits_seen += 1
			assert_true(damaged_seen >= hits_seen, "zombie_damaged arrives before its melee_attack (hit %d)" % hits_seen)
			if arrived[ClientCombatState.KEY_TARGET_DIED] == true:
				assert_true(died_seen, "zombie_died arrives before the killing melee_attack")
	for watch: Observer in watchers:
		var corpse: Dictionary = watch.death_rows.get(zombie_id, {})
		assert_eq([corpse.get("state", ""), corpse.get("health_fraction", -1.0)], ["dead", 0.0], "%s's mirror already showed the corpse when the death was announced" % watch.local_id())

	# ... and then it is removed everywhere.
	var removed: bool = await _eventually(func() -> bool:
		return not _zombies(world).has_zombie(zombie_id) and not watch_a.zombie_mirror.has_zombie(zombie_id) and not watch_b.zombie_mirror.has_zombie(zombie_id))
	assert_true(removed, "the corpse is removed from the server and both mirrors")
	var streamed: bool = await _eventually(func() -> bool:
		return watch_a.zombie_events.size() == server_zombie_events.size() and watch_b.zombie_events.size() == server_zombie_events.size())
	assert_true(streamed, "all %d zombie events reached both clients" % server_zombie_events.size())
	var expected_stream: Array[Dictionary] = _observable_list(server_zombie_events)
	for watch: Observer in watchers:
		assert_eq(_observable_list(watch.zombie_events), expected_stream, "%s received every zombie event the server produced, in order" % watch.local_id())
		assert_eq(_column(watch.zombie_events, ClientZombieState.KEY_SEQUENCE), range(1, server_zombie_events.size() + 1))
		assert_eq(watch.zombie_mirror.zombie_ids(), PackedStringArray([far_id]), "only the other zombie is left")
	assert_eq(watch_a.mirror_states.get(zombie_id, []), watch_b.mirror_states.get(zombie_id, []), "both mirrors went through the same states")
	var states: Array = watch_a.mirror_states.get(zombie_id, [])
	assert_true(states.has("attack") and not states.is_empty() and states[states.size() - 1] == "dead", "states: %s" % str(states))
	var lifecycle: PackedStringArray = []
	for event: Dictionary in _events_of_zombie(watch_b.zombie_events, zombie_id, [ZombieService.EVENT_SPAWNED, ZombieService.EVENT_DIED, ZombieService.EVENT_REMOVED]):
		lifecycle.append(str(event["event_type"]))
	assert_eq(lifecycle, PackedStringArray([ZombieService.EVENT_SPAWNED, ZombieService.EVENT_DIED, ZombieService.EVENT_REMOVED]))
	assert_true(world.registry.is_tombstoned(zombie_id), "its id is never reused")

	# --- item 2 again, over the whole fight: who learned what ----------------
	var bites: Array[Dictionary] = _events_of_type(server_zombie_events, ZombieService.EVENT_ATTACKED)
	var alice_bites: Array[Dictionary] = _events_of_type(watch_a.zombie_events, ZombieService.EVENT_ATTACKED)
	assert_eq(_column(alice_bites, "infection"), _column(bites, "infection"), "alice got every infection result")
	assert_eq(_column(alice_bites, "target_health_after"), _column(bites, "target_health_after"), "and her health after every bite")
	assert_eq(_column(bites, "target_id").count(alice_id), bites.size(), "the zombie only ever attacked alice")
	for event: Dictionary in watch_b.zombie_events:
		assert_false(event.has("infection") or event.has("target_health_after"), "no private field in bob's %s" % event["event_type"])
	var public_keys: Array = ["scope", "event_type", "player_id", "body_part", "wound_type", "died", "world_time"]
	var bob_heard_of_alice: int = 0
	for event: Dictionary in watch_b.survival_events:
		if event["player_id"] != alice_id:
			continue
		bob_heard_of_alice += 1
		assert_eq([event["scope"], event["event_type"]], [ClientSurvivalState.SCOPE_PUBLIC, SurvivalService.EVENT_PLAYER_WOUNDED], "bob only hears of alice's wounds")
		var keys: Array = event.keys()
		keys.sort()
		var allowed: Array = public_keys.duplicate()
		allowed.sort()
		assert_eq(keys, allowed, "no health, damage, wound detail or infection in it")
	assert_eq(bob_heard_of_alice, bites.size(), "one public wound per bite")
	assert_eq(_events_of_type(watch_a.survival_events, SurvivalService.EVENT_PLAYER_INFECTED).size(), 1, "alice was told once that she is infected")
	assert_eq(watch_b.survival_mirror.infection_stage(), "none")
	var final_agreement: bool = await _eventually(func() -> bool: return _owner_mirror_matches(watch_a, world, alice_id))
	assert_true(final_agreement, "after the fight alice's mirror equals the server again")
	var alice_vitals: PlayerVitals = _survival(world).get_vitals(alice_id)
	assert_true(alice_vitals.is_alive(), "alice survived (health %.2f after %d bites)" % [alice_vitals.health, bites.size()])
	assert_eq(alice_vitals.injuries.size(), bites.size(), "one wound per bite")
	assert_eq(watch_a.survival_mirror.wounds().size(), bites.size())
	assert_eq(alice_vitals.infection.stage, InfectionState.Stage.LATENT)
	var stamina_lag: float = survival_settings.stamina_regen_per_world_sec * SNAPSHOT_PERIODS_OF_LAG / _config.survival_net.owner_snapshot_rate_hz
	assert_true(_approx(watch_a.survival_mirror.stamina(), alice_vitals.stamina, stamina_lag), "stamina follows with the owner snapshot")
	_assert_no_error_logs("session 1")

	# --- item 6: save -> server gone -> load ---------------------------------
	var generation_before: int = SaveService.new(_root).current_generation(WORLD)
	await _cluster.shutdown()
	_cluster = null
	assert_true(SaveService.new(_root).current_generation(WORLD) > generation_before, "the server saved on shutdown")
	# The old world object no longer ticks: this is what was written.
	var saved_alice: Dictionary = _survival(world).to_player_fragment(alice_id)
	var saved_bob: Dictionary = _survival(world).to_player_fragment(bob_id)
	var saved_zombies: Dictionary = _zombies(world).to_world_document()
	var saved_combat: Dictionary = _combat(world).to_world_document()
	var saved_far: ZombieState = _zombies(world).get_zombie(far_id)
	var saved_alice_position: Vector3 = world.get_player(alice_id).position
	var saved_bob_position: Vector3 = world.get_player(bob_id).position
	var saved_time: float = world.clock.world_time_sec
	var saved_wounds: int = alice_vitals.injuries.size()
	var saved_health: float = alice_vitals.health
	world = null

	var persistence2: WorldPersistence = _persistence()
	var world2: ServerWorld = persistence2.load_or_create(WORLD)
	assert_not_null(world2, "world restored from the save")
	if world2 == null:
		return
	var vitals2: PlayerVitals = _survival(world2).get_vitals(alice_id)
	assert_not_null(vitals2, "alice's survival state was saved")
	if vitals2 == null:
		return
	assert_true(_approx_equal(_survival(world2).to_player_fragment(alice_id), saved_alice), "alice's health, wounds and infection are restored")
	assert_true(_approx_equal(_survival(world2).to_player_fragment(bob_id), saved_bob), "bob's survival state is restored")
	assert_true(_approx(vitals2.health, saved_health, SAVE_TOLERANCE), "health %.6f" % vitals2.health)
	assert_eq(vitals2.injuries.size(), saved_wounds)
	assert_eq(vitals2.infection.stage, InfectionState.Stage.LATENT, "still infected, same stage")
	assert_true(vitals2.infection.stage_elapsed_world_sec > 0.0, "time already spent in the stage is kept")
	assert_true(_approx_equal(_zombies(world2).to_world_document(), saved_zombies), "the zombie document is restored")
	assert_eq(_zombies(world2).zombie_ids(), PackedStringArray([far_id]), "the dead zombie is gone, the other one is there")
	assert_false(_zombies(world2).has_zombie(zombie_id))
	assert_true(world2.registry.is_tombstoned(zombie_id), "the dead zombie's id stays retired")
	var far2: ZombieState = _zombies(world2).get_zombie(far_id)
	assert_true(far2.position.distance_to(saved_far.position) <= POSITION_SAVE_TOLERANCE_M, "its position is restored")
	assert_eq([far2.state, far2.health], [saved_far.state, saved_far.health], "and its state and health")
	assert_eq(_combat(world2).to_world_document(), saved_combat, "damage rolls continue where they stopped")
	assert_true(world2.get_player(alice_id).position.distance_to(saved_alice_position) <= POSITION_SAVE_TOLERANCE_M)
	assert_true(world2.get_player(bob_id).position.distance_to(saved_bob_position) <= POSITION_SAVE_TOLERANCE_M)
	assert_true(_approx(world2.clock.world_time_sec, saved_time, WORLD_TIME_TOLERANCE_SEC), "world time is restored")
	assert_eq(_carried_definitions(world2, alice_id), PackedStringArray([PIPE_ID]))
	assert_eq(_carried_definitions(world2, bob_id), PackedStringArray([PIPE_ID]))
	assert_eq(world2.inventory.world_item_ids().size(), 0, "picked up pipes are not back in the world")
	# What the loaded world holds before anyone is online (the clock is paused).
	var loaded_far_row: Dictionary = {}
	for row: Dictionary in _zombies(world2).snapshot_rows():
		if row["id"] == far_id:
			loaded_far_row = {"position": row["position"], "yaw": row["yaw"], "state": row["state"], "health_fraction": row["health_fraction"]}
	var loaded_alice_wounds: Array[Dictionary] = _wound_dicts(world2, alice_id)
	var loaded_alice_health: float = vitals2.health
	var loaded_bob: PlayerVitals = _survival(world2).get_vitals(bob_id)
	var loaded_bob_health: float = loaded_bob.health
	var loaded_bob_stamina: float = loaded_bob.stamina
	var loaded_time: float = world2.clock.world_time_sec

	# ------------------------------------------------------------ session 2
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(world2, persistence2), OK)
	var a_joined: Dictionary = {}
	var b_joined: Dictionary = {}
	var a2: NetworkService = await _join_and_capture("alice", a_joined)
	var b2: NetworkService = await _join_and_capture("bob", b_joined)
	if a2 == null or b2 == null:
		fail("clients did not rejoin")
		return
	assert_eq([a_joined["player_id"], b_joined["player_id"]], [alice_id, bob_id], "the same players")
	assert_eq(a_joined["health"], loaded_alice_health, "alice's join snapshot carries her restored health")
	assert_eq(a_joined["wounds"], loaded_alice_wounds, "... her wounds")
	assert_eq(a_joined["infection_stage"], "latent", "... and her infection stage")
	assert_eq(a_joined["alive"], true)
	assert_eq(a_joined["inventory"], PackedStringArray([PIPE_ID]))
	assert_eq(a_joined["zombie_ids"], PackedStringArray([far_id]), "alice's mirror lists the surviving zombie only")
	assert_eq((a_joined["zombies"] as Dictionary).get(far_id, {}), loaded_far_row, "... exactly as it was saved")
	assert_true((a_joined["position"] as Vector3).distance_to(saved_alice_position) <= POSITION_SAVE_TOLERANCE_M, "alice is where she stood")
	assert_eq([b_joined["health"], b_joined["stamina"], b_joined["wounds"], b_joined["infection_stage"]], [loaded_bob_health, loaded_bob_stamina, [], "none"], "bob's join snapshot carries his own restored state")
	assert_eq(b_joined["inventory"], PackedStringArray([PIPE_ID]))
	assert_eq(b_joined["zombie_ids"], PackedStringArray([far_id]))
	assert_eq(((b_joined["zombies"] as Dictionary).get(far_id, {}) as Dictionary).get("state", ""), loaded_far_row["state"])
	assert_eq([a_joined["world_items"], b_joined["world_items"]], [0, 0])
	# The restored state is live: alice still bleeds and still owns her pipe.
	var watch_a2: Observer = Observer.new(a2)
	var watch_b2: Observer = Observer.new(b2)
	var bleeding: bool = await _eventually(func() -> bool:
		return world2.clock.world_time_sec > loaded_time + RESUME_SEC and _owner_mirror_matches(watch_a2, world2, alice_id) and watch_a2.survival_mirror.health() < loaded_alice_health)
	assert_true(bleeding, "the restored wounds keep bleeding and the owner mirror follows")
	assert_true(watch_a2.combat.request_melee_attack(YAW_MINUS_Z) != CombatNetModule.NO_REQUEST)
	var swung: bool = await _eventually(func() -> bool: return watch_a2.combat_events.size() == 1 and watch_b2.combat_events.size() == 1)
	assert_true(swung, "a swing after the restart reaches both clients")
	if swung:
		assert_eq(watch_a2.combat_events[0], watch_b2.combat_events[0])
		assert_eq([watch_a2.combat_events[0][ClientCombatState.KEY_SEQUENCE], watch_a2.combat_events[0][ClientCombatState.KEY_ATTACKER_ID], watch_a2.combat_events[0][ClientCombatState.KEY_WEAPON_ID], watch_a2.combat_events[0][ClientCombatState.KEY_HIT]], [1, alice_id, PIPE_ID, false], "alice swings the restored pipe at nothing")
	var tolerance_m: float = zombie_settings.chase_speed_mps * SNAPSHOT_PERIODS_OF_LAG / _config.zombie_net.snapshot_rate_hz
	var far_synced: bool = await _eventually(func() -> bool:
		var server_far: ZombieState = _zombies(world2).get_zombie(far_id)
		for watch: Observer in [watch_a2, watch_b2]:
			if not watch.zombie_mirror.has_zombie(far_id) or (watch.zombie_mirror.get_zombie(far_id)["position"] as Vector3).distance_to(server_far.position) > tolerance_m:
				return false
		return true)
	assert_true(far_synced, "both mirrors follow the restored zombie")

	# docs/12 §2.7: a player who drops and comes back gets the same content.
	# Alice (wounded, infected) leaves; she does not change while offline.
	_cluster.remove_client(a2)
	var gone: bool = await _eventually(func() -> bool: return not world2.is_online(alice_id) and not watch_b2.survival_mirror.has_player(alice_id))
	assert_true(gone, "the server and bob noticed that alice left")
	var offline_health: float = _survival(world2).get_vitals(alice_id).health
	var offline_wounds: Array[Dictionary] = _wound_dicts(world2, alice_id)
	var a_back: Dictionary = {}
	var a3: NetworkService = await _join_and_capture("alice", a_back)
	if a3 == null:
		fail("alice did not come back")
		return
	assert_eq([a_back["player_id"], a_back["health"], a_back["wounds"], a_back["infection_stage"]], [alice_id, offline_health, offline_wounds, "latent"], "alice comes back to the state she left with")
	assert_eq([a_back["inventory"], a_back["zombie_ids"]], [PackedStringArray([PIPE_ID]), PackedStringArray([far_id])])
	var watch_a3: Observer = Observer.new(a3)
	var back: bool = await _eventually(func() -> bool: return watch_b2.survival_mirror.is_alive(alice_id) and _owner_mirror_matches(watch_a3, world2, alice_id))
	assert_true(back, "bob sees her again and her mirror follows the server")
	# The combat event stream continues for both: bob's swing is number 2.
	assert_true(watch_b2.combat.request_melee_attack(YAW_MINUS_Z) != CombatNetModule.NO_REQUEST)
	var continued: bool = await _eventually(func() -> bool: return watch_a3.combat_events.size() == 1 and watch_b2.combat_events.size() == 2)
	assert_true(continued, "a swing after the reconnect reaches both clients")
	if continued:
		assert_eq(watch_a3.combat_events[0], watch_b2.combat_events[1])
		assert_eq([watch_a3.combat_events[0][ClientCombatState.KEY_SEQUENCE], watch_a3.combat_events[0][ClientCombatState.KEY_ATTACKER_ID]], [2, bob_id], "the rejoined client starts after the events it missed")
	_assert_no_error_logs("session 2")


# ============================================================ item 4: wounds

func test_leg_wound_slows_server_movement_by_the_configured_factor() -> void:
	_config.zombie.attack_body_parts = PackedStringArray(["left_leg"])
	_config.zombie.bite_chance = 1.0
	_config.zombie.attack_cooldown_sec = NEVER_SEC
	var settings: SurvivalSettings = _config.survival
	var world: ServerWorld = _start_plain()
	assert_not_null(world, "server started")
	if world == null:
		return
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var watch_a: Observer = Observer.new(a)
	var alice_id: String = watch_a.local_id()
	var bob_id: String = b.client_state.local_player_id
	# Both stand on the spawn point; a zombie that sees two equally near
	# players takes the smaller id (docs/09 §14.9).
	assert_true(alice_id < bob_id, "alice is the zombie's target")
	_spawn(world, world.get_player(alice_id).position + CLOSE_ZOMBIE_OFFSET, YAW_PLUS_Z)
	var wounded: bool = await _eventually(func() -> bool: return watch_a.survival_mirror.wounds().size() == 1 and _owner_mirror_matches(watch_a, world, alice_id))
	assert_true(wounded, "the zombie bit alice once and her mirror shows the wound")
	if not wounded:
		return
	var wound: Dictionary = watch_a.survival_mirror.wounds()[0]
	assert_eq([wound["body_part"], wound["wound_type"]], ["left_leg", "bite"])
	var severity: float = wound["severity"]
	assert_eq(severity, _config.zombie.bite_damage / settings.wound_severity_reference_damage, "severity = damage / reference damage")
	# The factor a client can predict from its own wound and the settings.
	var expected: float = clampf(1.0 - settings.movement_penalty_per_severity * severity, settings.min_movement_multiplier, 1.0)
	assert_true(expected < 1.0 and expected > settings.min_movement_multiplier, "a real penalty above the floor: %.3f" % expected)
	assert_true(_approx(world.player_movement_multiplier(alice_id), expected, SAVE_TOLERANCE), "server factor for alice")
	assert_eq(world.player_movement_multiplier(bob_id), 1.0, "bob is unhurt")

	# Both send the same move intent for the same server ticks.
	var direction: Vector2 = Vector2(1.0, 0.0)
	var yaw: float = _yaw_of(direction)
	for tick: int in range(WARMUP_TICKS):
		a.send_move_intent(direction, yaw)
		b.send_move_intent(direction, yaw)
		await tree.physics_frame
	# One server tick passes between two samples, so each sample pair is the
	# distance the server granted for one tick.
	var full_step: float = world.gameplay.move_speed_mps / float(Engine.physics_ticks_per_second)
	var alice_from: Vector3 = world.get_player(alice_id).position
	var bob_from: Vector3 = world.get_player(bob_id).position
	var alice_at: Vector3 = alice_from
	var bob_at: Vector3 = bob_from
	var alice_steps: int = 0
	var bob_steps: int = 0
	var odd_steps: PackedStringArray = []
	for tick: int in range(MEASURE_TICKS):
		a.send_move_intent(direction, yaw)
		b.send_move_intent(direction, yaw)
		await tree.physics_frame
		var alice_step: float = world.get_player(alice_id).position.distance_to(alice_at)
		var bob_step: float = world.get_player(bob_id).position.distance_to(bob_at)
		alice_at = world.get_player(alice_id).position
		bob_at = world.get_player(bob_id).position
		# A tick without a fresh input (only after a stall longer than the
		# input timeout) grants nothing; every other tick grants the full step.
		if _approx(alice_step, full_step * expected, STEP_TOLERANCE_M):
			alice_steps += 1
		elif alice_step != 0.0:
			odd_steps.append("alice %.6f" % alice_step)
		if _approx(bob_step, full_step, STEP_TOLERANCE_M):
			bob_steps += 1
		elif bob_step != 0.0:
			odd_steps.append("bob %.6f" % bob_step)
	var alice_walked: float = alice_at.distance_to(alice_from)
	var bob_walked: float = bob_at.distance_to(bob_from)
	for index: int in range(STOP_INTENTS):
		a.send_move_intent(Vector2.ZERO, yaw)
		b.send_move_intent(Vector2.ZERO, yaw)
		await tree.physics_frame
	assert_eq(odd_steps, PackedStringArray(), "every tick grants %.5f m to bob and %.5f m to alice" % [full_step, full_step * expected])
	assert_true(bob_steps > MEASURE_TICKS / 2 and alice_steps == bob_steps, "both walked the same ticks (%d / %d of %d)" % [alice_steps, bob_steps, MEASURE_TICKS])
	assert_true(_approx(bob_walked, full_step * float(bob_steps), SPEED_TOLERANCE), "bob walked at full speed: %.4f m in %d ticks" % [bob_walked, bob_steps])
	assert_true(_approx(alice_walked, full_step * expected * float(alice_steps), SPEED_TOLERANCE), "alice walked %.4f m in %d ticks" % [alice_walked, alice_steps])
	assert_true(_approx(alice_walked / bob_walked, expected, SPEED_TOLERANCE), "speed ratio %.4f equals the predicted factor %.4f" % [alice_walked / bob_walked, expected])
	assert_true(alice_walked < bob_walked, "the wounded player is slower")
	await _settle()
	var seen: bool = await _eventually(func() -> bool:
		var server_position: Vector3 = world.get_player(alice_id).position
		return a.client_state.position_of(alice_id).distance_to(server_position) < MIRROR_POSITION_TOLERANCE_M and b.client_state.position_of(alice_id).distance_to(server_position) < MIRROR_POSITION_TOLERANCE_M)
	assert_true(seen, "both clients see where the slowed player ended up")
	assert_eq(_survival(world).get_vitals(alice_id).injuries.size(), 1, "still the one wound")
	_assert_no_error_logs("leg wound")


func test_arm_wound_reduces_melee_damage_by_the_configured_factor() -> void:
	_config.zombie.attack_body_parts = PackedStringArray(["right_arm"])
	_config.zombie.bite_chance = 1.0
	_config.zombie.attack_cooldown_sec = NEVER_SEC
	var settings: SurvivalSettings = _config.survival
	var fists: MeleeWeaponDefinition = _config.melee_weapons.get_definition(UNARMED_ID)
	var world: ServerWorld = _start_plain()
	assert_not_null(world, "server started")
	if world == null or fists == null:
		fail("no server or no unarmed weapon")
		return
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var watch_a: Observer = Observer.new(clients[0])
	var watch_b: Observer = Observer.new(clients[1])
	var alice_id: String = watch_a.local_id()
	var bob_id: String = watch_b.local_id()
	assert_true(alice_id < bob_id, "alice is the zombie's target")
	var zombie_id: String = _spawn(world, world.get_player(alice_id).position + CLOSE_ZOMBIE_OFFSET, YAW_PLUS_Z)
	var wounded: bool = await _eventually(func() -> bool: return watch_a.survival_mirror.wounds().size() == 1 and _owner_mirror_matches(watch_a, world, alice_id) and watch_b.zombie_mirror.has_zombie(zombie_id))
	assert_true(wounded, "the zombie bit alice once and her mirror shows the wound")
	if not wounded:
		return
	var wound: Dictionary = watch_a.survival_mirror.wounds()[0]
	assert_eq([wound["body_part"], wound["wound_type"]], ["right_arm", "bite"])
	var severity: float = wound["severity"]
	var expected: float = clampf(1.0 - settings.handling_penalty_per_severity * severity, settings.min_handling_multiplier, 1.0)
	assert_true(expected < 1.0 and expected > settings.min_handling_multiplier, "a real penalty above the floor: %.3f" % expected)
	assert_eq(watch_b.survival_mirror.wounds().size(), 0, "bob is unhurt")

	# Alice swings first, bob second: the server rolls damage in that order
	# with the saved combat RNG (docs/09 §14.10), so both rolls are known.
	var rolls: RandomNumberGenerator = RandomNumberGenerator.new()
	rolls.seed = _config.combat.rng_seed
	var alice_roll: float = rolls.randf_range(_config.combat.damage_roll_min, _config.combat.damage_roll_max)
	var bob_roll: float = rolls.randf_range(_config.combat.damage_roll_min, _config.combat.damage_roll_max)
	assert_true(watch_a.combat.request_melee_attack(watch_a.aim_at_zombie(zombie_id)) != CombatNetModule.NO_REQUEST)
	var first: bool = await _eventually(func() -> bool: return watch_a.combat_events.size() == 1 and watch_b.combat_events.size() == 1)
	assert_true(first, "alice's swing replicated")
	assert_true(watch_b.combat.request_melee_attack(watch_b.aim_at_zombie(zombie_id)) != CombatNetModule.NO_REQUEST)
	var second: bool = await _eventually(func() -> bool: return watch_a.combat_events.size() == 2 and watch_b.combat_events.size() == 2)
	assert_true(second, "bob's swing replicated")
	if not first or not second:
		return
	await _settle()
	var record: Array[Dictionary] = _combat_module(_cluster.server).recent_events()
	assert_eq(watch_a.combat_events, record, "alice received the server's events")
	assert_eq(watch_b.combat_events, record, "bob received the server's events")
	assert_eq(_column(record, ClientCombatState.KEY_ATTACKER_ID), [alice_id, bob_id])
	assert_eq(_column(record, ClientCombatState.KEY_HIT), [true, true])
	assert_eq(_column(record, ClientCombatState.KEY_WEAPON_ID), [UNARMED_ID, UNARMED_ID])
	var alice_damage: float = record[0][ClientCombatState.KEY_DAMAGE]
	var bob_damage: float = record[1][ClientCombatState.KEY_DAMAGE]
	assert_true(_approx(bob_damage, fists.base_damage * bob_roll, DAMAGE_TOLERANCE), "bob: base x roll = %.4f, got %.4f" % [fists.base_damage * bob_roll, bob_damage])
	assert_true(_approx(alice_damage, fists.base_damage * expected * alice_roll, DAMAGE_TOLERANCE), "alice: base x %.3f x roll = %.4f, got %.4f" % [expected, fists.base_damage * expected * alice_roll, alice_damage])
	assert_true(alice_damage / alice_roll < bob_damage / bob_roll, "the arm wound makes the same weapon weaker")
	assert_true(_approx((alice_damage / alice_roll) / (bob_damage / bob_roll), expected, DAMAGE_TOLERANCE), "by exactly the predicted factor")
	assert_true(_approx(_zombies(world).get_zombie(zombie_id).health, _config.zombie.max_health - alice_damage - bob_damage, DAMAGE_TOLERANCE), "the server's zombie lost both hits")
	assert_eq(_survival(world).get_vitals(alice_id).injuries.size(), 1, "still the one wound")
	_assert_no_error_logs("arm wound")


# ============================================================ item 5: infection

func test_infection_stages_follow_the_configured_durations_and_reach_only_the_owner() -> void:
	var quick: Dictionary = await _run_infection(QUICK_LATENT_SEC, QUICK_EARLY_SEC)
	await _cluster.shutdown()
	_cluster = null
	_config = _new_config()
	var slow: Dictionary = await _run_infection(SLOW_LATENT_SEC, SLOW_EARLY_SEC)
	if quick.is_empty() or slow.is_empty():
		return
	assert_true(_approx(quick["latent"], QUICK_LATENT_SEC, WORLD_TIME_TOLERANCE_SEC) and _approx(quick["early"], QUICK_EARLY_SEC, WORLD_TIME_TOLERANCE_SEC), "first settings: %s" % str(quick))
	assert_true(_approx(slow["latent"], SLOW_LATENT_SEC, WORLD_TIME_TOLERANCE_SEC) and _approx(slow["early"], SLOW_EARLY_SEC, WORLD_TIME_TOLERANCE_SEC), "second settings: %s" % str(slow))
	assert_true(slow["latent"] > quick["latent"] and slow["early"] < quick["early"], "changing the settings changes the progression")


## One server run with the given stage durations (world seconds). A zombie
## bites alice; the run ends when her mirror shows "progressing". Returns
## the measured server durations {latent, early}, or {} on failure.
func _run_infection(latent_sec: float, early_sec: float) -> Dictionary:
	_config.zombie.bite_chance = 1.0
	_config.survival.infection_chance_bite = 1.0
	_config.survival.infection_latent_hours = latent_sec / SECONDS_PER_HOUR
	_config.survival.infection_early_hours = early_sec / SECONDS_PER_HOUR
	var settings: SurvivalSettings = _config.survival
	var world: ServerWorld = _start_plain()
	assert_not_null(world, "server started")
	if world == null:
		return {}
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return {}
	var watch_a: Observer = Observer.new(clients[0])
	var watch_b: Observer = Observer.new(clients[1])
	var alice_id: String = watch_a.local_id()
	var bob_id: String = watch_b.local_id()
	assert_true(alice_id < bob_id, "alice is the zombie's target")
	_spawn(world, world.get_player(alice_id).position + CLOSE_ZOMBIE_OFFSET, YAW_PLUS_Z)
	# Server truth, sampled every frame: world time at which each stage began.
	var entered: Dictionary[String, float] = {}
	var progressed: bool = await _eventually(func() -> bool:
		var infection: InfectionState = _survival(world).get_vitals(alice_id).infection
		var stage: String = InfectionState.stage_name(infection.stage)
		if not entered.has(stage):
			entered[stage] = infection.stage_entered_at_world_time
		return entered.has("progressing") and watch_a.survival_mirror.infection_stage() == "progressing")
	assert_true(progressed, "alice reached 'progressing' on the server and in her mirror (%s)" % str(entered))
	if not progressed or not entered.has("latent") or not entered.has("early"):
		fail("a stage was skipped: %s" % str(entered))
		return {}
	var infected_at: float = _survival(world).get_vitals(alice_id).infection.infected_at_world_time
	var measured: Dictionary = {"latent": entered["early"] - infected_at, "early": entered["progressing"] - entered["early"]}
	assert_eq(entered["latent"], infected_at, "the latent stage starts with the bite")
	assert_true(_approx(measured["latent"], settings.infection_stage_duration_world_sec(InfectionState.Stage.LATENT, InfectionState.Exposure.BITE), WORLD_TIME_TOLERANCE_SEC), "latent lasted %.6f s" % measured["latent"])
	assert_true(_approx(measured["early"], settings.infection_stage_duration_world_sec(InfectionState.Stage.EARLY, InfectionState.Exposure.BITE), WORLD_TIME_TOLERANCE_SEC), "early lasted %.6f s" % measured["early"])
	# The owner got each step, with the server's times, in order.
	var steps: Array[Dictionary] = []
	for event: Dictionary in watch_a.survival_events:
		if event["event_type"] == SurvivalService.EVENT_PLAYER_INFECTED or event["event_type"] == SurvivalService.EVENT_PLAYER_INFECTION_STAGE_CHANGED:
			steps.append(event)
	assert_eq(_column(steps, "event_type"), [SurvivalService.EVENT_PLAYER_INFECTED, SurvivalService.EVENT_PLAYER_INFECTION_STAGE_CHANGED, SurvivalService.EVENT_PLAYER_INFECTION_STAGE_CHANGED])
	if steps.size() != 3:
		return {}
	assert_eq(_column(steps, "world_time"), [infected_at, entered["early"], entered["progressing"]], "the owner's events carry the server's stage times")
	assert_eq([steps[1]["from"], steps[1]["to"], steps[2]["from"], steps[2]["to"]], ["latent", "early", "early", "progressing"])
	assert_eq(watch_a.infection_stages, PackedStringArray(["latent", "early", "progressing"]), "her mirror showed each stage as it was announced")
	assert_eq(_survival(world).infection_stage(alice_id), InfectionState.Stage.PROGRESSING)
	assert_true(_survival(world).get_vitals(alice_id).is_alive(), "alice is alive")
	# The other client learns nothing about it.
	await _settle()
	for event: Dictionary in watch_b.survival_events:
		assert_eq([event["player_id"], event["scope"], event["event_type"]], [alice_id, ClientSurvivalState.SCOPE_PUBLIC, SurvivalService.EVENT_PLAYER_WOUNDED], "bob only hears of alice's wounds")
		assert_false(event.has("from") or event.has("to") or event.has("exposure") or event.has("chance") or event.has("infection_stage"))
	for event: Dictionary in watch_b.zombie_events:
		assert_false(event.has("infection"), "no infection result in bob's zombie events")
	assert_eq(watch_b.survival_mirror.infection_stage(), "none")
	assert_eq(_survival(world).infection_stage(bob_id), InfectionState.Stage.NONE)
	_assert_no_error_logs("infection %.1f/%.1f" % [latent_sec, early_sec])
	return measured
