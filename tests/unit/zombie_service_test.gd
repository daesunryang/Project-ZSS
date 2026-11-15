extends TestCase
## P2-A2: ZombieService — sensing (sight vs sound), chase/attack/search,
## damage, persistence, determinism, limits, invalid input and a soak run.

const WORLD: String = "zombie_test_world"
const TICK: float = 0.05
## Yaw facing +Z (yaw 0 faces -Z).
const YAW_PLUS_Z: float = PI
const NEVER: float = 1.0e9
const POSITION_TOLERANCE: float = 0.000001

var _settings: ZombieSettings = null
var _survival_settings: SurvivalSettings = null
var _noise_settings: NoiseSettings = null
var _clock_settings: WorldClockSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = ZombieSettings.new()
	_settings.dev_spawn_count = 0
	# Idle zombies stand still unless a test wants wandering.
	_settings.wander_pause_min_sec = NEVER
	_settings.wander_pause_max_sec = NEVER
	_survival_settings = SurvivalSettings.new()
	# Isolate zombie behaviour from B3 time rules: no natural healing and no
	# respawn inside a test run (both are covered by survival_recovery_test).
	_survival_settings.health_recovery_per_world_sec = 0.0
	_survival_settings.respawn_delay_world_sec = NEVER
	_noise_settings = NoiseSettings.new()
	_clock_settings = WorldClockSettings.new()
	_root = "user://test_saves/zombie_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.clock = _clock_settings
	config.survival = _survival_settings
	config.noise = _noise_settings
	config.zombie = _settings
	return config


func _world() -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	world.seed_new_world(DevWorldSeed.new())
	return world


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _noise(world: ServerWorld) -> NoiseService:
	return world.get_system(NoiseService.SYSTEM_ID) as NoiseService


func _spawn(world: ServerWorld, position: Vector3, yaw: float = 0.0) -> String:
	var result: ActionResult = _zombies(world).spawn_zombie(world, position, yaw)
	return str(result.event.get("zombie_id", ""))


## Steps the world for `seconds` of real time, collecting zombie events.
func _run(world: ServerWorld, seconds: float, events: Array[Dictionary] = []) -> void:
	var service: ZombieService = _zombies(world)
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)
		events.append_array(service.drain_events())


## Steps until an event of `event_type` appears (true) or `max_seconds` pass.
func _run_until_event(world: ServerWorld, event_type: String, max_seconds: float, events: Array[Dictionary]) -> bool:
	var service: ZombieService = _zombies(world)
	for tick: int in range(roundi(max_seconds / TICK)):
		world.step_systems(TICK)
		var fresh: Array[Dictionary] = service.drain_events()
		events.append_array(fresh)
		for event: Dictionary in fresh:
			if event["event_type"] == event_type:
				return true
	return false


## Index of the first matching event at or after `from`, or -1.
func _find(events: Array[Dictionary], from: int, zombie_id: String, event_type: String, key: String = "", value: Variant = null) -> int:
	for index: int in range(maxi(from, 0), events.size()):
		var event: Dictionary = events[index]
		if event["zombie_id"] != zombie_id or event["event_type"] != event_type:
			continue
		if key.is_empty() or event.get(key, null) == value:
			return index
	return -1


func _count(events: Array[Dictionary], zombie_id: String, event_type: String) -> int:
	var count: int = 0
	for event: Dictionary in events:
		if event["zombie_id"] == zombie_id and event["event_type"] == event_type:
			count += 1
	return count


func _state(world: ServerWorld, zombie_id: String) -> String:
	return ZombieState.state_name(_zombies(world).get_zombie(zombie_id).state)


## Deep comparison that tolerates JSON float round-trip noise.
func _approx_equal(a: Variant, b: Variant) -> bool:
	if (typeof(a) == TYPE_FLOAT or typeof(a) == TYPE_INT) and (typeof(b) == TYPE_FLOAT or typeof(b) == TYPE_INT):
		return absf(float(a) - float(b)) <= POSITION_TOLERANCE
	if typeof(a) != typeof(b):
		return false
	if typeof(a) == TYPE_ARRAY:
		if (a as Array).size() != (b as Array).size():
			return false
		for index: int in range((a as Array).size()):
			if not _approx_equal(a[index], b[index]):
				return false
		return true
	if typeof(a) == TYPE_DICTIONARY:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for key: Variant in (a as Dictionary):
			if not (b as Dictionary).has(key) or not _approx_equal(a[key], b[key]):
				return false
		return true
	return a == b


# ------------------------------------------------------------ setup / seed

func test_default_settings_and_composition() -> void:
	var loaded: ZombieSettings = ZombieSettings.load_or_default()
	assert_eq(loaded.validate().size(), 0, "; ".join(loaded.validate()))
	assert_true(ResourceLoader.exists(ZombieSettings.DEFAULT_PATH))
	assert_true(loaded.dev_spawn_count >= 10 and loaded.dev_spawn_count <= 20, "docs/13 initial test scale")
	var broken: ZombieSettings = ZombieSettings.new()
	broken.attack_body_parts = PackedStringArray(["tail"])
	broken.chase_stop_distance_m = broken.attack_range_m + 1.0
	broken.dev_spawn_count = broken.max_active_zombies + 1
	broken.ai_period_sec = 0.0
	assert_true(broken.validate().size() >= 4, "; ".join(broken.validate()))
	var world: ServerWorld = ServerComposition.create_world(WORLD, CompositionConfig.from_defaults())
	# Later bundles register more systems (combat, ...); only the order of
	# the systems the zombies depend on is asserted here.
	var ids: PackedStringArray = world.system_ids()
	assert_true(ids.find(SurvivalService.SYSTEM_ID) >= 0 and ids.find(SurvivalService.SYSTEM_ID) < ids.find(NoiseService.SYSTEM_ID), "noise steps after survival")
	assert_true(ids.find(NoiseService.SYSTEM_ID) < ids.find(ZombieService.SYSTEM_ID), "zombies step after survival and noise")


func test_dev_seed_is_deterministic_and_uses_stable_entity_ids() -> void:
	_settings.dev_spawn_count = 12
	var first: ServerWorld = _world()
	var second: ServerWorld = _world()
	var service: ZombieService = _zombies(first)
	assert_eq(service.zombie_count(), 12)
	assert_eq(JSON.stringify(service.to_world_document()), JSON.stringify(_zombies(second).to_world_document()), "same seed -> same placement")
	assert_eq(Array(first.registry.ids_of_kind(ZombieService.ENTITY_KIND_ZOMBIE)), Array(service.zombie_ids()))
	var spawn: Vector3 = first.gameplay.player_spawn_position
	for zombie_id: String in service.zombie_ids():
		var zombie: ZombieState = service.get_zombie(zombie_id)
		assert_true(zombie_id.begins_with("zombie_"), zombie_id)
		assert_eq(first.registry.kind_of(zombie_id), ZombieService.ENTITY_KIND_ZOMBIE)
		var distance: float = ZombiePerception.flat_distance(zombie.position, spawn)
		assert_true(distance >= _settings.dev_spawn_min_radius_m - 0.001 and distance <= _settings.dev_spawn_max_radius_m + 0.001, "on the spawn ring")
		assert_true(distance - _settings.wander_radius_m > _settings.effective_sight_range_m(), "dev zombies start out of sight of the spawn point")
		assert_eq(zombie.health, _settings.max_health)
		assert_eq(zombie.state, ZombieState.State.IDLE)
	_settings.rng_seed = 777
	assert_ne(JSON.stringify(_zombies(_world()).to_world_document()), JSON.stringify(service.to_world_document()), "another seed -> another placement")


# ------------------------------------------------------------ scenarios

func test_scenario_noise_investigate_chase_attack_damage_and_infection() -> void:
	_settings.bite_chance = 1.0
	_survival_settings.infection_chance_bite = 1.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	# 30 m away, looking the other way: it can neither see nor reach her.
	var zombie_id: String = _spawn(world, Vector3(0, 0, 30), YAW_PLUS_Z)
	var events: Array[Dictionary] = []
	_run(world, 2.0, events)
	assert_eq(_state(world, zombie_id), "idle", "nothing sensed yet")
	assert_eq(_find(events, 0, zombie_id, ZombieService.EVENT_DETECTED), -1)

	assert_true(_noise(world).emit(alice.player_id, alice.position, 60.0, _noise_settings.default_profile).ok)
	assert_true(_run_until_event(world, ZombieService.EVENT_ATTACKED, 40.0, events), "the zombie reached and attacked the player")

	var heard: int = _find(events, 0, zombie_id, ZombieService.EVENT_DETECTED, "sense", ZombieService.SENSE_SOUND)
	var investigating: int = _find(events, heard, zombie_id, ZombieService.EVENT_STATE_CHANGED, "to", "investigate")
	var saw: int = _find(events, investigating, zombie_id, ZombieService.EVENT_DETECTED, "sense", ZombieService.SENSE_SIGHT)
	var chasing: int = _find(events, saw, zombie_id, ZombieService.EVENT_STATE_CHANGED, "to", "chase")
	var in_range: int = _find(events, chasing, zombie_id, ZombieService.EVENT_STATE_CHANGED, "to", "attack")
	var attacked: int = _find(events, in_range, zombie_id, ZombieService.EVENT_ATTACKED)
	assert_true(heard >= 0, "heard the noise")
	assert_eq(_find(events, 0, zombie_id, ZombieService.EVENT_DETECTED), heard, "sound was the first detection")
	assert_true(investigating > heard, "noise -> investigate")
	assert_eq(events[investigating]["cause"], ZombieService.CAUSE_NOISE)
	assert_true(saw > investigating, "then saw the player on the way")
	assert_eq(events[saw]["target_id"], alice.player_id)
	assert_true(chasing > saw and in_range > chasing and attacked > in_range, "investigate -> chase -> attack -> hit")

	var hit: Dictionary = events[attacked]
	assert_eq(hit["target_id"], alice.player_id)
	assert_eq(hit["wound_type"], "bite")
	assert_eq(hit["damage"], _settings.bite_damage)
	assert_eq(hit["infection"], SurvivalService.EVENT_PLAYER_INFECTED)
	assert_true(_settings.attack_body_parts.has(str(hit["body_part"])))
	assert_true(SaveService.is_json_safe(events), "events are JSON-safe")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_eq(vitals.health, _survival_settings.max_health - _settings.bite_damage, "damage went through survival")
	assert_eq(hit["target_health_after"], vitals.health)
	assert_eq(vitals.injuries.size(), 1)
	assert_eq(vitals.injuries[0].source_id, zombie_id)
	assert_eq(vitals.injuries[0].wound_type, Wound.Type.BITE)
	assert_eq(vitals.infection.stage, InfectionState.Stage.LATENT, "bite exposure infected the player")
	assert_eq(vitals.infection.source_id, zombie_id)
	var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
	assert_true(ZombiePerception.flat_distance(zombie.position, alice.position) <= _settings.attack_range_m)
	assert_eq(zombie.state, ZombieState.State.ATTACK)


func test_scratch_attacks_use_scratch_exposure_and_respect_cooldown() -> void:
	_settings.bite_chance = 0.0
	_survival_settings.infection_chance_scratch = 0.0
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, 1.2), 0.0)
	var events: Array[Dictionary] = []
	_run(world, 6.0, events)
	var hits: int = _count(events, zombie_id, ZombieService.EVENT_ATTACKED)
	var first: Dictionary = events[_find(events, 0, zombie_id, ZombieService.EVENT_ATTACKED)]
	assert_eq(first["wound_type"], "scratch")
	assert_eq(first["damage"], _settings.scratch_damage)
	assert_eq(first["infection"], SurvivalService.EVENT_INFECTION_RESISTED)
	assert_true(first["world_time"] >= _settings.attack_windup_sec, "wind-up before the first hit")
	# 6 s: wind-up 0.5 s, then one hit per 1.5 s cooldown (AI period 0.5 s).
	assert_true(hits >= 3 and hits <= 4, "cooldown limits the hit rate (got %d)" % hits)
	assert_eq(_survival(world).get_vitals(alice.player_id).health, _survival_settings.max_health - hits * _settings.scratch_damage)
	assert_false(_survival(world).get_vitals(alice.player_id).infection.is_infected())


func test_sight_needs_range_view_cone_and_light() -> void:
	var world: ServerWorld = _world()
	world.join("alice")  # at the origin
	var in_front: String = _spawn(world, Vector3(0, 0, 10), 0.0)
	var behind: String = _spawn(world, Vector3(0, 0, -10), 0.0)
	var beside: String = _spawn(world, Vector3(10, 0, 0), 0.0)
	var too_far: String = _spawn(world, Vector3(0, 0, _settings.sight_range_m + 5.0), 0.0)
	var events: Array[Dictionary] = []
	_run(world, 2.0, events)
	assert_eq(_state(world, in_front), "chase", "in range and in the view cone")
	assert_eq(_state(world, behind), "idle", "player is behind the zombie")
	assert_eq(_state(world, beside), "idle", "player is outside the view cone")
	assert_eq(_state(world, too_far), "idle", "player is out of sight range")
	for zombie_id: String in [behind, beside, too_far]:
		assert_eq(_count(events, zombie_id, ZombieService.EVENT_DETECTED), 0)
		assert_eq(_zombies(world).get_zombie(zombie_id).target_player_id, "")

	# Darkness shortens sight (lighting factor from settings).
	_settings.light_sight_multiplier = 0.2
	var dark_world: ServerWorld = _world()
	dark_world.join("alice")
	var dark_zombie: String = _spawn(dark_world, Vector3(0, 0, 10), 0.0)
	_run(dark_world, 2.0)
	assert_eq(_state(dark_world, dark_zombie), "idle", "10 m is beyond 25 m x 0.2")


func test_sight_and_sound_are_distinguished_and_sight_wins() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var listener: String = _spawn(world, Vector3(0, 0, -10), 0.0)  # player behind it
	var watcher: String = _spawn(world, Vector3(0, 0, 10), 0.0)  # player in front
	assert_true(_noise(world).emit(alice.player_id, alice.position, 40.0, _noise_settings.default_profile).ok)
	var events: Array[Dictionary] = []
	_run(world, 0.6, events)
	# The listener only heard: it investigates the noise position.
	var listener_first: Dictionary = events[_find(events, 0, listener, ZombieService.EVENT_DETECTED)]
	assert_eq(listener_first["sense"], ZombieService.SENSE_SOUND)
	assert_eq(listener_first["position"], [0.0, 0.0, 0.0])
	var listener_change: Dictionary = events[_find(events, 0, listener, ZombieService.EVENT_STATE_CHANGED)]
	assert_eq(listener_change["to"], "investigate")
	assert_eq(listener_change["cause"], ZombieService.CAUSE_NOISE)
	# The watcher saw and heard in the same decision: sight wins.
	var watcher_first: Dictionary = events[_find(events, 0, watcher, ZombieService.EVENT_DETECTED)]
	assert_eq(watcher_first["sense"], ZombieService.SENSE_SIGHT)
	assert_eq(watcher_first["target_id"], alice.player_id)
	var watcher_change: Dictionary = events[_find(events, 0, watcher, ZombieService.EVENT_STATE_CHANGED)]
	assert_eq(watcher_change["to"], "chase")
	assert_eq(watcher_change["cause"], ZombieService.CAUSE_SIGHT)
	_run(world, 5.0, events)
	assert_eq(_find(events, 0, watcher, ZombieService.EVENT_DETECTED, "sense", ZombieService.SENSE_SOUND), -1, "the watcher never reacted to the sound")
	assert_eq(_find(events, 0, watcher, ZombieService.EVENT_STATE_CHANGED, "to", "investigate"), -1)


func test_quiet_or_distant_noise_is_not_heard() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, -30), 0.0)
	assert_true(_noise(world).emit(alice.player_id, alice.position, 20.0, _noise_settings.default_profile).ok)
	var events: Array[Dictionary] = []
	_run(world, 2.0, events)
	assert_eq(_state(world, zombie_id), "idle", "20 loudness does not carry 30 m")
	assert_eq(_count(events, zombie_id, ZombieService.EVENT_DETECTED), 0)
	assert_eq(_count(events, zombie_id, ZombieService.EVENT_STATE_CHANGED), 0)


func test_lost_target_is_searched_then_zombie_returns_to_idle() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, 12), 0.0)
	var events: Array[Dictionary] = []
	_run(world, 1.0, events)
	assert_eq(_state(world, zombie_id), "chase")
	var last_known: Vector3 = alice.position
	alice.position = Vector3(200, 0, 200)  # gone (far out of sight)
	_run(world, 1.0, events)
	assert_eq(_state(world, zombie_id), "search", "target lost -> search")
	var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
	assert_eq(zombie.target_player_id, "")
	assert_eq(zombie.focus_position, last_known, "searches the last known position")
	_run(world, _settings.search_duration_sec + 1.0, events)
	assert_eq(_state(world, zombie_id), "idle", "gave up after the search time")
	var chase: int = _find(events, 0, zombie_id, ZombieService.EVENT_STATE_CHANGED, "to", "chase")
	var search: int = _find(events, chase, zombie_id, ZombieService.EVENT_STATE_CHANGED, "to", "search")
	var idle: int = _find(events, search, zombie_id, ZombieService.EVENT_STATE_CHANGED, "to", "idle")
	assert_true(chase >= 0 and search > chase and idle > search)
	assert_eq(events[search]["cause"], ZombieService.CAUSE_TARGET_LOST)
	assert_eq(events[idle]["cause"], ZombieService.CAUSE_SEARCH_TIMEOUT)
	assert_true(events[idle]["world_time"] - events[search]["world_time"] >= _settings.search_duration_sec)
	assert_true(ZombiePerception.flat_distance(zombie.position, last_known) <= _settings.search_radius_m + _settings.arrive_radius_m, "searched around the last known position")
	assert_eq(zombie.home_position, zombie.position, "stays where it ended up")
	_run(world, 5.0, events)
	assert_eq(_state(world, zombie_id), "idle")


func test_investigated_noise_without_target_ends_in_idle() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	alice.position = Vector3(-100, 0, -100)
	var zombie_id: String = _spawn(world, Vector3(0, 0, 0), 0.0)
	assert_true(_noise(world).emit("environment", Vector3(0, 0, 6), 30.0, _noise_settings.default_profile).ok)
	var events: Array[Dictionary] = []
	_run(world, 30.0, events)
	var investigate: int = _find(events, 0, zombie_id, ZombieService.EVENT_STATE_CHANGED, "to", "investigate")
	var search: int = _find(events, investigate, zombie_id, ZombieService.EVENT_STATE_CHANGED, "to", "search")
	var idle: int = _find(events, search, zombie_id, ZombieService.EVENT_STATE_CHANGED, "to", "idle")
	assert_true(investigate >= 0 and search > investigate and idle > search)
	assert_eq(events[search]["cause"], ZombieService.CAUSE_INVESTIGATED)
	assert_eq(_count(events, zombie_id, ZombieService.EVENT_DETECTED), 1, "one noise is investigated once")
	assert_eq(_state(world, zombie_id), "idle")


func test_idle_zombies_wander_near_home() -> void:
	_settings.wander_pause_min_sec = 0.5
	_settings.wander_pause_max_sec = 1.0
	var world: ServerWorld = _world()
	world.join("alice").position = Vector3(-200, 0, -200)
	var home: Vector3 = Vector3(50, 0, 50)
	var zombie_id: String = _spawn(world, home, 0.0)
	var farthest: float = 0.0
	var moved: bool = false
	for step: int in range(60):
		_run(world, 1.0)
		var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
		farthest = maxf(farthest, ZombiePerception.flat_distance(zombie.position, home))
		moved = moved or zombie.position != home
	assert_true(moved, "the zombie wandered")
	assert_true(farthest <= _settings.wander_radius_m + 0.001, "stays within the wander radius (%s)" % str(farthest))
	assert_eq(_state(world, zombie_id), "idle")


func test_dead_and_offline_players_are_not_targets() -> void:
	_settings.bite_chance = 1.0
	_settings.bite_damage = 60.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, 1.2), 0.0)
	var events: Array[Dictionary] = []
	_run(world, 5.0, events)
	assert_false(survival.is_alive(alice.player_id), "two bites of 60 kill the player")
	assert_eq(_count(events, zombie_id, ZombieService.EVENT_ATTACKED), 2)
	var last_hit: Dictionary = events[_find(events, 1 + _find(events, 0, zombie_id, ZombieService.EVENT_ATTACKED), zombie_id, ZombieService.EVENT_ATTACKED)]
	assert_true(last_hit["target_died"])
	events.clear()
	_run(world, _settings.search_duration_sec + 8.0, events)
	assert_eq(_count(events, zombie_id, ZombieService.EVENT_ATTACKED), 0, "no attacks on a dead player")
	assert_eq(_count(events, zombie_id, ZombieService.EVENT_DETECTED), 0, "a dead player is not detected again")
	assert_eq(_state(world, zombie_id), "idle", "attack -> search -> idle")
	assert_eq(survival.get_vitals(alice.player_id).injuries.size(), 2)

	# A player who was already dead before the zombie appeared.
	var fresh: String = _spawn(world, Vector3(0, 0, 5), 0.0)
	events.clear()
	_run(world, 3.0, events)
	assert_eq(_state(world, fresh), "idle")
	assert_eq(events.size(), 1, "only the spawn event")

	# An offline player (state kept by the world) is ignored as well.
	var bob: PlayerState = world.join("bob")
	bob.position = Vector3(0, 0, -10)
	_run(world, 1.0, events)
	assert_eq(_state(world, fresh), "chase")
	world.leave(bob.player_id)
	world.join("carol").position = Vector3(-200, 0, -200)  # keeps the clock running
	events.clear()
	_run(world, 3.0, events)
	assert_eq(_count(events, fresh, ZombieService.EVENT_ATTACKED), 0)
	assert_eq(_state(world, fresh), "search")
	assert_true(_survival(world).is_alive(bob.player_id))


# ------------------------------------------------------------ zombie damage

func test_zombie_takes_damage_dies_and_corpse_is_removed() -> void:
	var world: ServerWorld = _world()
	var service: ZombieService = _zombies(world)
	world.join("alice").position = Vector3(-200, 0, -200)
	var zombie_id: String = _spawn(world, Vector3(20, 0, 20), 0.0)
	service.drain_events()
	var hit: ActionResult = service.apply_damage_to_zombie(zombie_id, 30.0, "player_000099")
	assert_true(hit.ok, hit.reason)
	assert_eq(hit.event["event_type"], ZombieService.EVENT_DAMAGED)
	assert_eq(hit.event["health_after"], _settings.max_health - 30.0)
	assert_false(hit.event["died"])
	assert_eq(service.snapshot_rows()[0]["health_fraction"], 0.7)
	var kill: ActionResult = service.apply_damage_to_zombie(zombie_id, 1000.0, "player_000099")
	assert_true(kill.event["died"])
	assert_eq(kill.event["health_after"], 0.0)
	assert_eq(_state(world, zombie_id), "dead")
	assert_eq(service.living_count(), 0)
	assert_eq(service.zombie_count(), 1, "corpse stays for a while")
	assert_eq(service.apply_damage_to_zombie(zombie_id, 5.0, "player_000099").reason, ZombieService.REASON_ZOMBIE_DEAD)
	var events: Array[Dictionary] = service.drain_events()
	assert_eq(events.size(), 3)
	assert_eq(events[2]["event_type"], ZombieService.EVENT_DIED)
	assert_eq(events[2]["source_id"], "player_000099")
	assert_eq(service.snapshot_rows()[0]["state"], "dead")

	var corpse_position: Vector3 = service.get_zombie(zombie_id).position
	_run(world, _settings.corpse_remove_delay_sec - 1.0, events)
	assert_true(service.has_zombie(zombie_id), "not removed before the delay")
	assert_eq(service.get_zombie(zombie_id).position, corpse_position, "corpses do not move")
	_run(world, 2.0, events)
	assert_false(service.has_zombie(zombie_id))
	assert_eq(_find(events, 0, zombie_id, ZombieService.EVENT_REMOVED), events.size() - 1)
	assert_false(world.registry.has(zombie_id))
	assert_true(world.registry.is_tombstoned(zombie_id), "the id is never reused")
	assert_eq(service.snapshot_rows().size(), 0)
	var next_id: String = _spawn(world, Vector3(20, 0, 20), 0.0)
	assert_ne(next_id, zombie_id)
	assert_true(EntityIdGenerator.sequence_of(next_id) > EntityIdGenerator.sequence_of(zombie_id))


func test_hit_zombie_notices_its_attacker() -> void:
	var world: ServerWorld = _world()
	var service: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	# Attacker close behind the zombie: unseen until it is hit.
	var close: String = _spawn(world, Vector3(0, 0, -3), 0.0)
	# Attacker beyond sight range (e.g. a ranged hit): cannot be seen at all.
	var far: String = _spawn(world, Vector3(0, 0, -(_settings.sight_range_m + 10.0)), 0.0)
	var events: Array[Dictionary] = []
	_run(world, 2.0, events)
	assert_eq(_state(world, close), "idle")
	assert_true(service.apply_damage_to_zombie(close, 10.0, alice.player_id).ok)
	assert_true(service.apply_damage_to_zombie(far, 10.0, alice.player_id).ok)
	_run(world, TICK, events)
	assert_eq(_state(world, close), "chase", "turned around and saw the attacker within one tick")
	assert_eq(service.get_zombie(close).target_player_id, alice.player_id)
	assert_true(_find(events, 0, close, ZombieService.EVENT_DETECTED, "sense", ZombieService.SENSE_SIGHT) >= 0)
	assert_eq(_state(world, far), "investigate", "walks to where the hit came from")
	var noticed: Dictionary = events[_find(events, 0, far, ZombieService.EVENT_DETECTED)]
	assert_eq(noticed["sense"], ZombieService.SENSE_DAMAGE)
	assert_eq(noticed["target_id"], alice.player_id)
	assert_eq(events[_find(events, 0, far, ZombieService.EVENT_STATE_CHANGED)]["cause"], ZombieService.CAUSE_ATTACKED)
	assert_eq(service.get_zombie(far).focus_position, alice.position)
	# Damage from something that is not a living online player is not chased.
	var other: String = _spawn(world, Vector3(100, 0, 100), 0.0)
	assert_true(service.apply_damage_to_zombie(other, 10.0, "environment").ok)
	_run(world, 1.0, events)
	assert_eq(_state(world, other), "idle")


func test_invalid_input_is_rejected_without_state_change() -> void:
	_settings.max_active_zombies = 2
	var world: ServerWorld = _world()
	var service: ZombieService = _zombies(world)
	var zombie_id: String = _spawn(world, Vector3(5, 0, 5), 0.0)
	var before: String = JSON.stringify(service.to_world_document())
	var next_sequence: int = world.ids.get_next_sequence()
	assert_eq(service.apply_damage_to_zombie("zombie_999999", 5.0, "p").reason, ZombieService.REASON_UNKNOWN_ZOMBIE)
	assert_eq(service.apply_damage_to_zombie("", 5.0, "p").reason, ZombieService.REASON_UNKNOWN_ZOMBIE)
	assert_eq(service.apply_damage_to_zombie(zombie_id, NAN, "p").reason, ZombieService.REASON_BAD_AMOUNT)
	assert_eq(service.apply_damage_to_zombie(zombie_id, INF, "p").reason, ZombieService.REASON_BAD_AMOUNT)
	assert_eq(service.apply_damage_to_zombie(zombie_id, -5.0, "p").reason, ZombieService.REASON_BAD_AMOUNT)
	assert_eq(service.apply_damage_to_zombie(zombie_id, 0.0, "p").reason, ZombieService.REASON_BAD_AMOUNT)
	assert_eq(service.apply_damage_to_zombie(zombie_id, 5.0, "").reason, ZombieService.REASON_BAD_SOURCE)
	assert_eq(service.spawn_zombie(world, Vector3(NAN, 0, 0)).reason, ZombieService.REASON_BAD_POSITION)
	assert_eq(service.spawn_zombie(world, Vector3(0, INF, 0)).reason, ZombieService.REASON_BAD_POSITION)
	assert_eq(service.spawn_zombie(world, Vector3.ZERO, NAN).reason, ZombieService.REASON_BAD_POSITION)
	assert_eq(service.spawn_zombie(null, Vector3.ZERO).reason, ZombieService.REASON_BAD_POSITION)
	assert_eq(JSON.stringify(service.to_world_document()), before, "rejected requests change nothing")
	assert_eq(world.ids.get_next_sequence(), next_sequence, "no ids are consumed by rejected requests")
	assert_null(service.get_zombie("zombie_999999"))
	# Positions outside the world are clamped, the population limit is enforced.
	var clamped: String = _spawn(world, Vector3(99999, 0, -99999), 0.0)
	assert_eq(service.get_zombie(clamped).position, Vector3(world.gameplay.world_half_extent_m, 0, -world.gameplay.world_half_extent_m))
	assert_eq(service.spawn_zombie(world, Vector3.ZERO).reason, ZombieService.REASON_LIMIT)
	assert_eq(service.zombie_count(), 2)


# ------------------------------------------------------------ network surface

func test_snapshot_rows_and_event_queue() -> void:
	_settings.max_pending_events = 5
	var world: ServerWorld = _world()
	var service: ZombieService = _zombies(world)
	var ids: PackedStringArray = []
	for index: int in range(8):
		ids.append(_spawn(world, Vector3(index * 2.0, 0, 40), 0.5))
	var rows: Array[Dictionary] = service.snapshot_rows()
	assert_eq(rows.size(), 8)
	for index: int in range(rows.size()):
		var row: Dictionary = rows[index]
		assert_eq(row.keys(), ["id", "position", "yaw", "state", "health_fraction"])
		assert_eq(row["id"], ids[index], "rows are in spawn order")
		assert_eq(row["position"], Vector3(index * 2.0, 0, 40))
		assert_eq(row["yaw"], 0.5)
		assert_eq(row["state"], "idle")
		assert_eq(row["health_fraction"], 1.0)
	var events: Array[Dictionary] = service.drain_events()
	assert_eq(events.size(), 5, "undrained events are capped")
	assert_eq(service.dropped_event_count, 3)
	assert_eq(events[4]["zombie_id"], ids[7], "the newest events are kept")
	assert_eq(events[0]["event_type"], ZombieService.EVENT_SPAWNED)
	assert_eq(service.drain_events().size(), 0, "drain clears the queue")


func test_ai_decisions_are_spread_and_capped_per_tick() -> void:
	_settings.max_active_zombies = 40
	var world: ServerWorld = _world()
	var service: ZombieService = _zombies(world)
	world.join("alice").position = Vector3(-200, 0, -200)
	for index: int in range(40):
		_spawn(world, Vector3(index * 3.0, 0, 100), 0.0)
	var busiest: int = 0
	var ticks_per_period: int = roundi(_settings.ai_period_sec / TICK)
	for tick: int in range(ticks_per_period):
		world.step_systems(TICK)
		busiest = maxi(busiest, service.last_ai_update_count)
	assert_eq(service.total_ai_update_count, 40, "every zombie decided exactly once per AI period")
	assert_eq(busiest, 4, "40 zombies over 10 buckets, not all in one tick")

	# With a tight cap the backlog is carried over instead of bursting.
	_settings.max_ai_updates_per_tick = 3
	var capped_world: ServerWorld = _world()
	var capped: ZombieService = _zombies(capped_world)
	capped_world.join("alice").position = Vector3(-200, 0, -200)
	for index: int in range(40):
		_spawn(capped_world, Vector3(index * 3.0, 0, 100), 0.0)
	var over_cap: int = 0
	for tick: int in range(ticks_per_period * 4):
		capped_world.step_systems(TICK)
		if capped.last_ai_update_count > 3:
			over_cap += 1
	assert_eq(over_cap, 0, "never more than max_ai_updates_per_tick decisions in a tick")
	assert_eq(capped.total_ai_update_count, ticks_per_period * 4 * 3, "the cap is used fully while there is a backlog")


func test_nothing_happens_while_the_world_clock_is_paused() -> void:
	var world: ServerWorld = _world()
	var service: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, 10), 0.0)
	_run(world, 1.0)
	assert_eq(_state(world, zombie_id), "chase")
	world.leave(alice.player_id)  # nobody online -> clock paused
	var decisions_before: int = service.total_ai_update_count
	var before: String = JSON.stringify(service.to_world_document())
	service.drain_events()
	for tick: int in range(200):
		assert_eq(world.step_systems(TICK), 0.0)
	assert_eq(JSON.stringify(service.to_world_document()), before)
	assert_eq(service.drain_events().size(), 0)
	assert_eq(service.total_ai_update_count, decisions_before, "no AI decisions while paused")


# ------------------------------------------------------------ persistence

func test_save_recreate_load_keeps_state_and_rng() -> void:
	_settings.dev_spawn_count = 6
	_settings.dev_spawn_min_radius_m = 6.0
	_settings.dev_spawn_max_radius_m = 30.0
	_settings.wander_pause_min_sec = 0.2
	_settings.wander_pause_max_sec = 1.0
	_settings.bite_damage = 1.0
	_settings.scratch_damage = 1.0
	var world: ServerWorld = _world()
	var service: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	assert_true(_noise(world).emit(alice.player_id, alice.position, 50.0, _noise_settings.default_profile).ok)
	_run(world, 4.0)
	var ids: PackedStringArray = service.zombie_ids()
	assert_true(service.apply_damage_to_zombie(ids[0], 1000.0, alice.player_id).ok)  # a corpse
	assert_true(service.apply_damage_to_zombie(ids[1], 25.0, alice.player_id).ok)  # wounded + alerted
	_run(world, 3.0)
	var states: Dictionary = {}
	for zombie_id: String in ids:
		states[_state(world, zombie_id)] = true
	assert_true(states.size() >= 3, "the saved world has zombies in several states: %s" % str(states.keys()))

	var documents: Dictionary = world.to_documents()
	var saved: Dictionary = (documents["world_state"] as Dictionary)[ServerWorld.KEY_SYSTEMS][ZombieService.SYSTEM_ID]
	assert_eq(saved["schema_version"], ZombieService.SCHEMA_VERSION)
	assert_true(SaveService.is_json_safe(saved), "the zombie document is JSON-safe")
	assert_eq(SaveService.new(_root).save_world(WORLD, documents["world_state"], documents["players"]), OK)

	var loaded: Dictionary = SaveService.new(_root).load_world(WORLD)
	assert_eq(loaded["error"], OK)
	var restored_world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_eq(restored_world.restore_documents(loaded["world_state"], loaded["players"]).size(), 0)
	var restored: ZombieService = _zombies(restored_world)
	assert_eq(restored.zombie_ids(), ids, "same zombies with the same ids, no new ones injected")
	assert_true(_approx_equal(restored.to_world_document(), service.to_world_document()), "state survives save -> recreate -> load")
	for zombie_id: String in ids:
		var original: ZombieState = service.get_zombie(zombie_id)
		var copy: ZombieState = restored.get_zombie(zombie_id)
		assert_eq(copy.state, original.state)
		assert_eq(copy.target_player_id, original.target_player_id)
		assert_eq(copy.health, original.health)
		assert_eq(copy.rng.state, original.rng.state, "RNG state is saved exactly")
		assert_eq(restored_world.registry.kind_of(zombie_id), ZombieService.ENTITY_KIND_ZOMBIE)
	assert_eq(restored.to_world_document()["rng_state"], service.to_world_document()["rng_state"], "placement RNG continues")
	# The random sequences continue where they stopped.
	for zombie_id: String in ids:
		assert_eq(restored.get_zombie(zombie_id).rng.randi(), service.get_zombie(zombie_id).rng.randi())
	# New ids never collide with restored ones and the simulation goes on.
	var fresh_id: String = _spawn(restored_world, Vector3(100, 0, 100), 0.0)
	assert_false(ids.has(fresh_id))
	assert_true(EntityIdGenerator.sequence_of(fresh_id) > EntityIdGenerator.sequence_of(ids[ids.size() - 1]))
	assert_not_null(restored_world.join("alice"))
	_run(restored_world, 5.0)
	assert_true(restored.total_ai_update_count > 0, "restored zombies keep deciding")
	assert_eq(restored.living_count(), service.living_count() + 1)
	_run(restored_world, _settings.corpse_remove_delay_sec)
	assert_false(restored.has_zombie(ids[0]), "the restored corpse is still removed on time")


func test_world_persistence_does_not_reseed_existing_worlds() -> void:
	_settings.dev_spawn_count = 10
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config())
	var created: ServerWorld = persistence.load_or_create(WORLD)
	assert_eq(_zombies(created).zombie_count(), 10)
	var ids: PackedStringArray = _zombies(created).zombie_ids()
	_settings.dev_spawn_count = 20  # a later build with more dev zombies
	var reloaded: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config()).load_or_create(WORLD)
	assert_eq(_zombies(reloaded).zombie_ids(), ids, "an existing world keeps exactly its saved zombies")

	# A save written before the zombie system existed gets no zombies (docs/15 P2-3).
	var documents: Dictionary = created.to_documents()
	((documents["world_state"] as Dictionary)[ServerWorld.KEY_SYSTEMS] as Dictionary).erase(ZombieService.SYSTEM_ID)
	var old_world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_eq(old_world.restore_documents(documents["world_state"], documents["players"]).size(), 0)
	assert_eq(_zombies(old_world).zombie_count(), 0)


func test_corrupt_zombie_documents_are_rejected() -> void:
	var world: ServerWorld = _world()
	var service: ZombieService = _zombies(world)
	_spawn(world, Vector3(1, 0, 1), 0.0)
	var good: Dictionary = service.to_world_document()
	var variants: Array[Dictionary] = []
	var wrong_version: Dictionary = good.duplicate(true)
	wrong_version["schema_version"] = 99
	variants.append(wrong_version)
	var bad_rng: Dictionary = good.duplicate(true)
	bad_rng["rng_state"] = "not a number"
	variants.append(bad_rng)
	var no_list: Dictionary = good.duplicate(true)
	no_list["zombies"] = "none"
	variants.append(no_list)
	for change: Array in [["zombie_id", "player_000001"], ["state", "flying"], ["position", [0.0, "x", 0.0]], ["position", [0.0, 0.0]], ["health", -1.0], ["health", _settings.max_health + 1.0], ["yaw", "north"], ["target_visible", 1], ["rng_seed", "abc"], ["state", "dead"]]:
		var broken: Dictionary = good.duplicate(true)
		(broken["zombies"][0] as Dictionary)[change[0]] = change[1]
		variants.append(broken)
	var duplicated: Dictionary = good.duplicate(true)
	(duplicated["zombies"] as Array).append((duplicated["zombies"][0] as Dictionary).duplicate(true))
	variants.append(duplicated)
	for document: Dictionary in variants:
		var fresh_world: ServerWorld = ServerComposition.create_world(WORLD, _config())
		var fresh: ZombieService = _zombies(fresh_world)
		if fresh.restore_world_document(document).is_empty():
			fail("corrupt document accepted: %s" % JSON.stringify(document))
		assert_eq(fresh.zombie_count(), 0, "nothing is restored from a corrupt document")
		assert_eq(fresh_world.registry.count(), 0)
	var clean_world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_eq(_zombies(clean_world).restore_world_document(good).size(), 0)


# ------------------------------------------------------------ determinism / soak

## Scripted 30 s session; returns everything that must be reproducible.
func _simulate(rng_seed: int) -> String:
	_settings.rng_seed = rng_seed
	_settings.dev_spawn_count = 15
	_settings.dev_spawn_min_radius_m = 5.0
	_settings.dev_spawn_max_radius_m = 40.0
	_settings.wander_pause_min_sec = 0.5
	_settings.wander_pause_max_sec = 2.0
	var world: ServerWorld = _world()
	var service: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	bob.position = Vector3(30, 0, -20)
	var events: Array[Dictionary] = []
	for tick: int in range(600):
		var angle: float = tick * 0.005
		alice.position = Vector3(-200, 0, -200) if tick >= 400 else Vector3(cos(angle) * 15.0, 0.0, sin(angle) * 15.0)
		if tick % 50 == 10:
			_noise(world).emit(bob.player_id, bob.position, 45.0, _noise_settings.default_profile)
		if tick % 90 == 45:
			var ids: PackedStringArray = service.zombie_ids()
			service.apply_damage_to_zombie(ids[int(tick / 90.0) % 2], 60.0, alice.player_id)
		world.step_systems(TICK)
		events.append_array(service.drain_events())
	var documents: Dictionary = world.to_documents()
	return JSON.stringify([service.to_world_document(), events, documents["players"], service.total_ai_update_count])


func test_same_seed_gives_identical_results() -> void:
	var first: String = _simulate(42)
	var second: String = _simulate(42)
	assert_eq(first.length(), second.length())
	assert_true(first == second, "same seed + same inputs -> identical zombies, events and player damage")
	assert_true(first.contains(ZombieService.EVENT_ATTACKED), "the scenario includes attacks")
	assert_true(first.contains("\"search\""), "the scenario includes lost targets")
	assert_true(first.contains(ZombieService.EVENT_DIED), "the scenario includes zombie deaths")
	assert_true(_simulate(43) != first, "another seed gives another run")


func test_soak_hours_of_world_time_stay_within_limits() -> void:
	const WORLD_HOURS: float = 3.0
	const WORLD_SEC_PER_TICK: float = 2.0
	_clock_settings.time_scale = WORLD_SEC_PER_TICK / TICK
	_settings.dev_spawn_count = 20
	_settings.max_active_zombies = 24
	_settings.dev_spawn_min_radius_m = 5.0
	_settings.dev_spawn_max_radius_m = 120.0
	_settings.wander_pause_min_sec = 2.0
	_settings.wander_pause_max_sec = 20.0
	# Players must survive for hours so the zombies stay busy.
	_settings.bite_damage = 0.01
	_settings.scratch_damage = 0.01
	_survival_settings.max_health = 10000.0
	var world: ServerWorld = _world()
	var service: ZombieService = _zombies(world)
	var noise: NoiseService = _noise(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var half: float = world.gameplay.world_half_extent_m
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 9001
	var ticks: int = roundi(WORLD_HOURS * 3600.0 / WORLD_SEC_PER_TICK)
	var violations: PackedStringArray = []
	var event_total: int = 0
	var attack_total: int = 0
	var seen_states: Dictionary = {}
	var spawn_refusals: int = 0
	for tick: int in range(ticks):
		var angle: float = tick * 0.01
		alice.position = Vector3(cos(angle) * 60.0, 0.0, sin(angle * 0.7) * 60.0)
		if tick % 400 == 0:
			bob.position = Vector3(rng.randf_range(-half, half), 0.0, rng.randf_range(-half, half))
		if tick % 15 == 0:
			noise.emit("environment", Vector3(rng.randf_range(-150.0, 150.0), 0.0, rng.randf_range(-150.0, 150.0)), rng.randf_range(10.0, 90.0), _noise_settings.default_profile)
		if tick % 120 == 60:
			var ids: PackedStringArray = service.zombie_ids()
			service.apply_damage_to_zombie(ids[rng.randi_range(0, ids.size() - 1)], rng.randf_range(20.0, 80.0), alice.player_id)
		if tick % 200 == 100:
			# Keep the population up; beyond the limit the spawn must be refused.
			for attempt: int in range(3):
				if not service.spawn_zombie(world, Vector3(rng.randf_range(-half, half), 0.0, rng.randf_range(-half, half)), rng.randf_range(-PI, PI)).ok:
					spawn_refusals += 1
		world.step_systems(TICK)
		if service.last_ai_update_count > _settings.max_ai_updates_per_tick:
			violations.append("tick %d: %d AI decisions" % [tick, service.last_ai_update_count])
		if service.zombie_count() > _settings.max_active_zombies:
			violations.append("tick %d: %d zombies" % [tick, service.zombie_count()])
		if tick % 5 == 0:
			for event: Dictionary in service.drain_events():
				event_total += 1
				if event["event_type"] == ZombieService.EVENT_ATTACKED:
					attack_total += 1
		if tick % 50 == 0:
			for row: Dictionary in service.snapshot_rows():
				var position: Vector3 = row["position"]
				seen_states[row["state"]] = true
				if not position.is_finite() or absf(position.x) > half or absf(position.z) > half or not is_finite(float(row["yaw"])):
					violations.append("tick %d: %s at %s" % [tick, str(row["id"]), str(position)])
				if float(row["health_fraction"]) < 0.0 or float(row["health_fraction"]) > 1.0:
					violations.append("tick %d: %s health %s" % [tick, str(row["id"]), str(row["health_fraction"])])
		if violations.size() > 10:
			break
	assert_eq(violations.size(), 0, "; ".join(violations))
	assert_true(world.clock.world_time_sec >= WORLD_HOURS * 3600.0 - 1.0, "simulated %s world seconds" % str(world.clock.world_time_sec))
	assert_true(service.total_ai_update_count > ticks, "AI kept running (%d decisions)" % service.total_ai_update_count)
	assert_true(event_total > 100, "zombies kept reacting (%d events)" % event_total)
	assert_true(attack_total > 0, "zombies attacked during the soak")
	assert_true(spawn_refusals > 0, "the population limit was reached and enforced")
	for state_name: String in ["idle", "investigate", "chase", "search", "dead"]:
		assert_true(seen_states.has(state_name), "state %s occurred during the soak" % state_name)
	assert_eq(service.dropped_event_count, 0, "regular draining never overflowed the event queue")
	assert_true(noise.active_count() <= _noise_settings.max_active_events)
	assert_true(_survival(world).is_alive(alice.player_id) and _survival(world).is_alive(bob.player_id))
	# The long-running world still saves and restores cleanly.
	var documents: Dictionary = world.to_documents()
	assert_true(SaveService.is_json_safe(documents["world_state"]))
	var restored_world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_eq(restored_world.restore_documents(documents["world_state"], documents["players"]).size(), 0)
	assert_eq(_zombies(restored_world).zombie_ids(), service.zombie_ids())
	for line: String in GameLogger.captured_lines():
		if line.contains("[ERROR]") or line.contains("[FATAL]"):
			fail("error logged during soak: " + line)
			break
