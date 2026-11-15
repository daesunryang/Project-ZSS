extends TestCase
## P2-T1 (docs/00 ADR-006): calendar time vs action time.
##
## Calendar time (WorldClock.world_time_sec) runs `time_scale` times faster
## than real time and drives needs, infection stages, bleeding, recovery and
## starvation. Action time (WorldClock.action_time_sec) is real seconds and
## drives zombies, noise, melee cooldowns, footsteps, stamina regeneration,
## the respawn delay and survival damage event batching. Both stop while the
## world is paused. The same real time at scale 1 and 24 must give the same
## action results and 24x the calendar results.

const WORLD: String = "time_axes_test_world"
const TICK: float = 0.05
const TICK_MSEC: int = 50
const INPUT_TIMEOUT_MSEC: int = 500
const NEVER: float = 1.0e9
const SCALE_REAL: float = 1.0
const SCALE_DAY_PER_HOUR: float = 24.0
const TOLERANCE: float = 0.001
const TIGHT: float = 0.000001
const WALK_PLUS_X: Vector2 = Vector2(1, 0)
const SECONDS_PER_HOUR: float = 3600.0

var _survival_settings: SurvivalSettings = null
var _zombie_settings: ZombieSettings = null
var _noise_settings: NoiseSettings = null
var _footstep_settings: PlayerNoiseSettings = null
var _combat_settings: CombatSettings = null
var _gameplay: GameplaySettings = null
var _pause_when_empty: bool = true
var _now_msec: int = 0
var _sequence: int = 0
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_survival_settings = SurvivalSettings.new()
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER
	_noise_settings = NoiseSettings.new()
	_footstep_settings = PlayerNoiseSettings.new()
	_combat_settings = CombatSettings.new()
	_gameplay = GameplaySettings.new()
	_pause_when_empty = true
	_now_msec = 0
	_sequence = 0
	_root = "user://test_saves/time_axes_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config(scale: float) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.gameplay = _gameplay
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = scale
	config.clock.pause_when_empty = _pause_when_empty
	config.survival = _survival_settings
	config.noise = _noise_settings
	config.player_noise = _footstep_settings
	config.zombie = _zombie_settings
	config.combat = _combat_settings
	return config


func _world(scale: float) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config(scale))
	world.seed_new_world(DevWorldSeed.new())
	return world


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _noise(world: ServerWorld) -> NoiseService:
	return world.get_system(NoiseService.SYSTEM_ID) as NoiseService


func _combat(world: ServerWorld) -> CombatService:
	return world.get_system(CombatService.SYSTEM_ID) as CombatService


func _footsteps(world: ServerWorld) -> PlayerNoiseService:
	return world.get_system(PlayerNoiseService.SYSTEM_ID) as PlayerNoiseService


## One server tick the way NetworkService runs it: movement, then systems.
func _tick(world: ServerWorld) -> void:
	_now_msec += TICK_MSEC
	world.step_movement(TICK, _now_msec, INPUT_TIMEOUT_MSEC)
	world.step_systems(TICK)


func _near(actual: float, expected: float, tolerance: float = TOLERANCE) -> bool:
	return absf(actual - expected) <= tolerance


# ------------------------------------------------------------ the clock

func test_default_scale_makes_one_world_day_per_real_hour() -> void:
	var settings: WorldClockSettings = WorldClockSettings.load_or_default()
	assert_eq(settings.time_scale, SCALE_DAY_PER_HOUR, "ADR-006: data/tuning/world_clock_settings.tres")
	assert_eq(WorldClockSettings.new().time_scale, SCALE_DAY_PER_HOUR, "the script default matches the tuning file")
	var clock: WorldClock = settings.create_clock()
	for _second: int in int(SECONDS_PER_HOUR):
		clock.step(1.0, true)
	assert_eq(clock.action_time_sec, SECONDS_PER_HOUR, "action time is real seconds")
	assert_eq(clock.world_time_sec, 24.0 * SECONDS_PER_HOUR, "one real hour is one world day")


func test_clock_advances_both_times_and_reports_both_deltas() -> void:
	var clock: WorldClock = WorldClock.new(SCALE_DAY_PER_HOUR, true)
	assert_eq(clock.step(0.5, true), 12.0, "step() returns the calendar delta")
	assert_eq(clock.last_world_delta, 12.0)
	assert_eq(clock.last_action_delta, 0.5)
	assert_eq(clock.world_time_sec, 12.0)
	assert_eq(clock.action_time_sec, 0.5)
	for bad_delta: float in [-1.0, NAN, INF, 0.0]:
		assert_eq(clock.step(bad_delta, true), 0.0, "invalid delta %s is ignored" % str(bad_delta))
		assert_eq(clock.last_world_delta, 0.0)
		assert_eq(clock.last_action_delta, 0.0)
	assert_eq(clock.world_time_sec, 12.0)
	assert_eq(clock.action_time_sec, 0.5)
	assert_eq(clock.restore_action_time(7.25), OK)
	assert_eq(clock.action_time_sec, 7.25)
	assert_eq(clock.world_time_sec, 12.0, "restoring one time leaves the other")
	for bad_time: float in [-1.0, NAN, INF]:
		assert_eq(clock.restore_action_time(bad_time), ERR_INVALID_PARAMETER)
	assert_eq(clock.action_time_sec, 7.25)


func test_both_clocks_stop_while_nobody_is_online() -> void:
	var world: ServerWorld = _world(SCALE_DAY_PER_HOUR)
	var counter: TestCounterSystem = TestCounterSystem.new()
	world.register_system(counter)
	for _tick_index: int in 20:
		assert_eq(world.step_systems(TICK), 0.0, "paused: no calendar delta")
	assert_eq(world.clock.world_time_sec, 0.0, "calendar time is paused with nobody online")
	assert_eq(world.clock.action_time_sec, 0.0, "action time is paused with nobody online")
	assert_eq(counter.steps, 20, "systems are still stepped while paused")
	assert_eq(counter.action_time_seen, 0.0, "paused systems get action_delta 0")
	assert_eq(counter.world_time_seen, 0.0, "paused systems get world_delta 0")

	var alice: PlayerState = world.join("alice")
	for _tick_index: int in 20:
		world.step_systems(TICK)
	assert_true(_near(world.clock.action_time_sec, 1.0, TIGHT), "20 ticks of 0.05 s = 1 real second")
	assert_true(_near(world.clock.world_time_sec, SCALE_DAY_PER_HOUR, TIGHT), "and 24 world seconds")
	assert_true(_near(counter.action_time_seen, 1.0, TIGHT))
	assert_true(_near(counter.world_time_seen, SCALE_DAY_PER_HOUR, TIGHT))

	# Action-time deadlines do not run out during a pause: a noise that is
	# about to expire and a corpse that is about to be removed both survive.
	var zombie_id: String = str(_zombies(world).spawn_zombie(world, Vector3(0, 0, 100)).event["zombie_id"])
	assert_true(_zombies(world).apply_damage_to_zombie(zombie_id, 1000.0, alice.player_id).ok)
	assert_true(_noise(world).emit(alice.player_id, alice.position, 10.0, _noise_settings.default_profile).ok)
	world.leave(alice.player_id)
	var paused_world_time: float = world.clock.world_time_sec
	var paused_action_time: float = world.clock.action_time_sec
	for _tick_index: int in roundi(100.0 / TICK):
		world.step_systems(TICK)
	assert_eq(world.clock.world_time_sec, paused_world_time, "calendar time stopped when the last player left")
	assert_eq(world.clock.action_time_sec, paused_action_time, "action time stopped when the last player left")
	assert_eq(_noise(world).active_count(), 1, "noise does not expire while paused")
	assert_true(_zombies(world).has_zombie(zombie_id), "the corpse is not removed while paused")

	_pause_when_empty = false
	var always_on: ServerWorld = _world(SCALE_DAY_PER_HOUR)
	always_on.step_systems(2.0)
	assert_eq(always_on.clock.action_time_sec, 2.0, "pause_when_empty = false keeps both clocks running")
	assert_eq(always_on.clock.world_time_sec, 48.0)


func test_event_world_time_is_calendar_time_in_every_system() -> void:
	# docs/09 §14.16: events of action-time systems still stamp calendar time,
	# so events of different systems share one axis. Only noise keeps its own
	# action-time stamp (it is never replicated).
	var world: ServerWorld = _world(SCALE_DAY_PER_HOUR)
	var alice: PlayerState = world.join("alice")
	for _tick_index: int in 40:
		world.step_systems(TICK)
	var calendar_now: float = world.clock.world_time_sec
	var action_now: float = world.clock.action_time_sec
	assert_true(_near(action_now, 2.0, TIGHT) and _near(calendar_now, 48.0, TIGHT), "2 real seconds = 48 world seconds")
	var spawned: ActionResult = _zombies(world).spawn_zombie(world, Vector3(0, 0, -1.0))
	assert_eq(spawned.event["world_time"], calendar_now, "zombie events")
	var swing: ActionResult = _combat(world).request_melee_attack(world, alice.player_id, 0.0)
	assert_true(swing.ok, swing.reason)
	assert_eq(swing.event["world_time"], calendar_now, "combat events")
	var zombie_events: Array[Dictionary] = _zombies(world).drain_events()
	assert_eq(zombie_events[zombie_events.size() - 1]["event_type"], ZombieService.EVENT_DAMAGED)
	assert_eq(zombie_events[zombie_events.size() - 1]["world_time"], calendar_now)
	var wounded: ActionResult = _survival(world).apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.BRUISE, 5.0))
	assert_eq(wounded.event["world_time"], calendar_now, "survival events")
	assert_eq((wounded.event["wound"] as Dictionary)["created_at_world_time"], calendar_now)
	var heard: ActionResult = _noise(world).emit("test_source", Vector3.ZERO, 10.0, _noise_settings.default_profile)
	assert_eq(heard.event["event_time"], action_now, "noise event_time is action time")
	assert_true(_near(_combat(world).cooldown_remaining(alice.player_id), 0.8, TIGHT), "the unarmed cooldown is 0.8 real seconds")


func test_survival_fragment_v4_stores_and_validates_the_action_death_time() -> void:
	var world: ServerWorld = _world(SCALE_DAY_PER_HOUR)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	for _tick_index: int in 40:
		world.step_systems(TICK)
	var alive: Dictionary = survival.to_player_fragment(alice.player_id)
	assert_eq(int(alive["schema_version"]), 4)
	assert_eq(alive["died_at_action_time"], PlayerVitals.NOT_DEAD_TIME)
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.BRUISE, 1000.0)).ok)
	var dead: Dictionary = survival.to_player_fragment(alice.player_id)
	assert_eq(dead["died_at_action_time"], world.clock.action_time_sec, "death is stamped with the action clock")
	assert_eq(dead["died_at_world_time"], world.clock.world_time_sec, "and with the calendar clock")
	var parsed: Array = PlayerVitals.from_dict(dead, _survival_settings)
	assert_true((parsed[1] as PackedStringArray).is_empty(), ", ".join(parsed[1]))
	assert_eq((parsed[0] as PlayerVitals).died_at_action_time, world.clock.action_time_sec)
	# A dead player whose respawn delay has not started yet (migrated from an
	# older fragment and saved again before coming online) is valid.
	var waiting: Dictionary = dead.duplicate(true)
	waiting["died_at_action_time"] = PlayerVitals.NOT_DEAD_TIME
	assert_true((PlayerVitals.from_dict(waiting, _survival_settings)[1] as PackedStringArray).is_empty())
	var alive_with_death_time: Dictionary = alive.duplicate(true)
	alive_with_death_time["died_at_action_time"] = 3.0
	assert_false((PlayerVitals.from_dict(alive_with_death_time, _survival_settings)[1] as PackedStringArray).is_empty(), "a living player cannot have a death time")
	for bad_value: Variant in [-2.0, "soon", NAN]:
		var broken: Dictionary = dead.duplicate(true)
		broken["died_at_action_time"] = bad_value
		assert_false((PlayerVitals.from_dict(broken, _survival_settings)[1] as PackedStringArray).is_empty(), "rejected: %s" % str(bad_value))
	# Older fragments are read without the field.
	var older: Dictionary = dead.duplicate(true)
	older["schema_version"] = 3
	older.erase("died_at_action_time")
	var migrated: Array = PlayerVitals.from_dict(older, _survival_settings)
	assert_true((migrated[1] as PackedStringArray).is_empty(), ", ".join(migrated[1]))
	assert_eq((migrated[0] as PlayerVitals).died_at_action_time, PlayerVitals.NOT_DEAD_TIME)


# ------------------------------------------------------------ action time

## Zombie movement, attacks, wandering and corpse removal for one scale.
func _zombie_outcome(scale: float) -> Dictionary:
	_zombie_settings.bite_chance = 0.0
	_zombie_settings.corpse_remove_delay_sec = 3.03
	_survival_settings.infection_chance_scratch = 0.0
	# Natural healing is a calendar rule; keep it out of the health comparison.
	_survival_settings.health_recovery_per_world_sec = 0.0
	var world: ServerWorld = _world(scale)
	var service: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	# 12 m in front of alice, facing her: sees her, chases, attacks.
	var hunter: String = str(service.spawn_zombie(world, Vector3(0, 0, 12), 0.0).event["zombie_id"])
	# Far away and looking away: walks to a heard noise, then searches.
	var listener: String = str(service.spawn_zombie(world, Vector3(150, 0, 150), 0.0).event["zombie_id"])
	var corpse: String = str(service.spawn_zombie(world, Vector3(-150, 0, -150), 0.0).event["zombie_id"])
	assert_true(service.apply_damage_to_zombie(corpse, 1000.0, alice.player_id).ok)
	assert_true(_noise(world).emit("test_source", Vector3(150, 0, 170), 60.0, _noise_settings.default_profile).ok)
	service.drain_events()
	var outcome: Dictionary = {"hit_ticks": [], "corpse_removed_tick": -1, "listener_states": []}
	for tick_index: int in roundi(14.0 / TICK):
		world.step_systems(TICK)
		for event: Dictionary in service.drain_events():
			if event["event_type"] == ZombieService.EVENT_ATTACKED:
				(outcome["hit_ticks"] as Array).append(tick_index)
			elif event["event_type"] == ZombieService.EVENT_REMOVED and event["zombie_id"] == corpse:
				outcome["corpse_removed_tick"] = tick_index
			elif event["event_type"] == ZombieService.EVENT_STATE_CHANGED and event["zombie_id"] == listener:
				(outcome["listener_states"] as Array).append([tick_index, event["to"]])
		if tick_index == roundi(2.0 / TICK) - 1:
			outcome["hunter_position_after_2s"] = service.get_zombie(hunter).position
	outcome["hunter_position"] = service.get_zombie(hunter).position
	outcome["listener_position"] = service.get_zombie(listener).position
	outcome["alice_health"] = _survival(world).get_vitals(alice.player_id).health
	outcome["action_time"] = world.clock.action_time_sec
	outcome["world_time"] = world.clock.world_time_sec
	return outcome


func test_zombie_speed_attacks_and_timers_ignore_the_time_scale() -> void:
	var real_time: Dictionary = _zombie_outcome(SCALE_REAL)
	var accelerated: Dictionary = _zombie_outcome(SCALE_DAY_PER_HOUR)
	assert_true(_near(float(accelerated["world_time"]), float(real_time["world_time"]) * SCALE_DAY_PER_HOUR), "the calendar did run 24x faster")
	assert_eq(accelerated["action_time"], real_time["action_time"])
	assert_eq(accelerated["hunter_position_after_2s"], real_time["hunter_position_after_2s"], "same distance covered in the same real time")
	var moved: float = 12.0 - (real_time["hunter_position_after_2s"] as Vector3).z
	assert_true(moved > _zombie_settings.chase_speed_mps * 1.4 and moved <= _zombie_settings.chase_speed_mps * 2.0 + TIGHT, "chase speed is metres per real second (moved %f m in 2 s)" % moved)
	assert_eq(accelerated["hit_ticks"], real_time["hit_ticks"], "same attack count at the same ticks")
	var hit_ticks: Array = real_time["hit_ticks"]
	assert_true(hit_ticks.size() >= 5 and hit_ticks.size() <= 8, "about one hit per 1.5 s cooldown after a ~3.3 s approach (got %d)" % hit_ticks.size())
	for index: int in range(1, hit_ticks.size()):
		var interval: float = float(int(hit_ticks[index]) - int(hit_ticks[index - 1])) * TICK
		assert_true(interval >= _zombie_settings.attack_cooldown_sec - TIGHT and interval <= _zombie_settings.attack_cooldown_sec + _zombie_settings.ai_period_sec + TIGHT, "attack interval is the cooldown in real seconds (%f)" % interval)
	assert_eq(accelerated["alice_health"], real_time["alice_health"], "scratches do not bleed: same damage taken")
	assert_eq(accelerated["corpse_removed_tick"], real_time["corpse_removed_tick"])
	var corpse_removed_at: float = float(int(real_time["corpse_removed_tick"]) + 1) * TICK
	assert_true(corpse_removed_at >= _zombie_settings.corpse_remove_delay_sec and corpse_removed_at <= _zombie_settings.corpse_remove_delay_sec + 2.0 * TICK, "corpse removed after the delay in real seconds (%f)" % corpse_removed_at)
	assert_eq(accelerated["listener_states"], real_time["listener_states"], "investigate/search timers run in real seconds")
	assert_true((real_time["listener_states"] as Array).size() >= 1, "the listener reacted to the noise")
	assert_eq(accelerated["listener_position"], real_time["listener_position"])


## Footsteps, noise expiry, melee cooldown, stamina regeneration and the
## respawn delay for one scale.
func _player_outcome(scale: float) -> Dictionary:
	_survival_settings.stamina_regen_per_sec = 0.5
	_survival_settings.respawn_delay_sec = 3.02
	_gameplay.player_spawn_position = Vector3(0, 0, 0)
	var world: ServerWorld = _world(scale)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var survival: SurvivalService = _survival(world)
	var combat: CombatService = _combat(world)
	var outcome: Dictionary = {"attack_ticks": [], "bob_respawn_tick": -1, "noise_gone_tick": -1}
	var tick_index: int = 0
	for _settle: int in 10:
		_tick(world)
		tick_index += 1
	assert_true(survival.apply_damage(bob.player_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, 1000.0)).ok)
	var died_tick: int = tick_index
	# Alice walks 20 m (10 strides) and swings on every tick: the cooldown
	# decides how many swings are accepted.
	for _walk_tick: int in roundi(5.0 / TICK):
		_sequence += 1
		world.set_move_input(alice.player_id, _sequence, WALK_PLUS_X, 0.0, _now_msec + TICK_MSEC)
		if combat.request_melee_attack(world, alice.player_id, 0.0).ok:
			(outcome["attack_ticks"] as Array).append(tick_index)
		_tick(world)
		tick_index += 1
		if outcome["bob_respawn_tick"] == -1 and survival.is_alive(bob.player_id):
			outcome["bob_respawn_tick"] = tick_index - died_tick
	_sequence += 1
	world.set_move_input(alice.player_id, _sequence, Vector2.ZERO, 0.0, _now_msec)
	outcome["footsteps"] = _footsteps(world).total_footstep_count
	outcome["alice_position"] = alice.position
	var stopped_tick: int = tick_index
	for _rest_tick: int in roundi(10.0 / TICK):
		_tick(world)
		tick_index += 1
		if outcome["noise_gone_tick"] == -1 and _noise(world).active_count() == 0:
			outcome["noise_gone_tick"] = tick_index - stopped_tick
	outcome["stamina"] = survival.get_vitals(alice.player_id).stamina
	outcome["cooldown_remaining"] = combat.cooldown_remaining(alice.player_id)
	outcome["action_time"] = world.clock.action_time_sec
	outcome["world_time"] = world.clock.world_time_sec
	return outcome


func test_player_action_results_ignore_the_time_scale() -> void:
	var real_time: Dictionary = _player_outcome(SCALE_REAL)
	var accelerated: Dictionary = _player_outcome(SCALE_DAY_PER_HOUR)
	assert_true(_near(float(accelerated["world_time"]), float(real_time["world_time"]) * SCALE_DAY_PER_HOUR), "the calendar did run 24x faster")
	assert_eq(accelerated["action_time"], real_time["action_time"])
	# Footsteps: 20 m at 4 m/s, one per 2 m stride.
	assert_eq(accelerated["footsteps"], real_time["footsteps"])
	assert_true(int(real_time["footsteps"]) >= 9 and int(real_time["footsteps"]) <= 10, "one footstep per 2 m stride (got %d)" % int(real_time["footsteps"]))
	assert_eq(accelerated["alice_position"], real_time["alice_position"])
	# Noise lifetime (8 s): the last noise is gone 8 real seconds after it.
	assert_eq(accelerated["noise_gone_tick"], real_time["noise_gone_tick"])
	var noise_gone_after: float = float(int(real_time["noise_gone_tick"])) * TICK
	assert_true(noise_gone_after > _noise_settings.event_lifetime_sec - 1.0 and noise_gone_after <= _noise_settings.event_lifetime_sec + 2.0 * TICK, "noise expired after its lifetime in real seconds (%f)" % noise_gone_after)
	# Melee cooldown (unarmed 0.8 s): 6 or 7 accepted swings in 5 s.
	assert_eq(accelerated["attack_ticks"], real_time["attack_ticks"])
	var attack_ticks: Array = real_time["attack_ticks"]
	assert_true(attack_ticks.size() >= 6 and attack_ticks.size() <= 7, "the weapon cooldown limits swings in real seconds (got %d)" % attack_ticks.size())
	assert_eq(accelerated["cooldown_remaining"], real_time["cooldown_remaining"])
	# Stamina: 5 per accepted swing, +0.5 per real second.
	assert_true(_near(float(accelerated["stamina"]), float(real_time["stamina"]), TIGHT), "stamina regeneration: %f vs %f" % [accelerated["stamina"], real_time["stamina"]])
	var spent: float = 5.0 * attack_ticks.size()
	var first_swing_at: float = float(int(attack_ticks[0])) * TICK
	var expected_stamina: float = _survival_settings.max_stamina - spent + _survival_settings.stamina_regen_per_sec * (float(real_time["action_time"]) - first_swing_at)
	assert_true(_near(float(real_time["stamina"]), expected_stamina, 0.05), "regen is per real second: %f vs %f" % [real_time["stamina"], expected_stamina])
	# Respawn delay (3.02 s).
	assert_eq(accelerated["bob_respawn_tick"], real_time["bob_respawn_tick"])
	var respawned_after: float = float(int(real_time["bob_respawn_tick"])) * TICK
	assert_true(respawned_after >= _survival_settings.respawn_delay_sec and respawned_after <= _survival_settings.respawn_delay_sec + TICK + TIGHT, "respawn delay in real seconds (%f)" % respawned_after)


func test_survival_damage_events_are_batched_per_real_second() -> void:
	_survival_settings.health_recovery_per_world_sec = 0.0
	_survival_settings.max_health = 10000.0
	var counts: Array[int] = []
	for scale: float in [SCALE_REAL, SCALE_DAY_PER_HOUR]:
		var world: ServerWorld = _world(scale)
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("alice")
		assert_true(survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.LACERATION, 30.0)).ok)
		survival.drain_events()
		for _tick_index: int in roundi(5.0 / TICK):
			world.step_systems(TICK)
		var count: int = 0
		for event: Dictionary in survival.drain_events():
			if event["event_type"] == SurvivalService.EVENT_PLAYER_SURVIVAL_DAMAGE:
				count += 1
		counts.append(count)
	assert_eq(counts[0], counts[1], "same number of batched events for the same real time")
	assert_true(counts[0] >= 4 and counts[0] <= 5, "about one event per real second (got %d in 5 s)" % counts[0])


# ------------------------------------------------------------ calendar time

## Needs, infection, bleeding and natural recovery for one scale.
func _calendar_outcome(scale: float, real_seconds: float, tick_sec: float) -> Dictionary:
	_survival_settings.max_health = 1000.0
	_survival_settings.infection_chance_bite = 1.0
	var world: ServerWorld = _world(scale)
	var survival: SurvivalService = _survival(world)
	var bleeder: PlayerState = world.join("bleeder")
	var healer: PlayerState = world.join("healer")
	var infected: PlayerState = world.join("infected")
	assert_true(survival.apply_damage(bleeder.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.LACERATION, 25.0)).ok)
	# A bruise does not bleed, so it heals; 200 of 1000 health leaves room for
	# 7680 world seconds of natural recovery (153.6) without reaching the cap.
	assert_true(survival.apply_damage(healer.player_id, DamageInput.create("fall", BodyPart.Part.TORSO, Wound.Type.BRUISE, 200.0)).ok)
	assert_true(survival.apply_infection_exposure(infected.player_id, InfectionState.Exposure.BITE, "zombie_1").ok)
	var bleeder_health: float = survival.get_vitals(bleeder.player_id).health
	var healer_health: float = survival.get_vitals(healer.player_id).health
	var healer_severity: float = survival.get_vitals(healer.player_id).injuries[0].severity
	for _tick_index: int in roundi(real_seconds / tick_sec):
		world.step_systems(tick_sec)
	var vitals: PlayerVitals = survival.get_vitals(infected.player_id)
	var infection_seconds: float = vitals.infection.stage_elapsed_world_sec
	if vitals.infection.stage > InfectionState.Stage.LATENT:
		infection_seconds += _survival_settings.infection_stage_duration_world_sec(InfectionState.Stage.LATENT, InfectionState.Exposure.BITE)
	return {
		"hunger": vitals.hunger, "thirst": vitals.thirst, "fatigue": vitals.fatigue,
		"infection_stage": vitals.infection.stage, "infection_seconds": infection_seconds,
		"bleeding_damage": bleeder_health - survival.get_vitals(bleeder.player_id).health,
		"health_recovered": survival.get_vitals(healer.player_id).health - healer_health,
		"wound_healed": healer_severity - survival.get_vitals(healer.player_id).injuries[0].severity,
		"world_time": world.clock.world_time_sec, "action_time": world.clock.action_time_sec,
	}


func test_calendar_rules_run_24_times_faster_at_scale_24() -> void:
	const REAL_SECONDS: float = 320.0
	const STEP: float = 0.25
	var real_time: Dictionary = _calendar_outcome(SCALE_REAL, REAL_SECONDS, STEP)
	var accelerated: Dictionary = _calendar_outcome(SCALE_DAY_PER_HOUR, REAL_SECONDS, STEP)
	assert_eq(accelerated["action_time"], real_time["action_time"], "same real time")
	assert_true(_near(float(accelerated["world_time"]), SCALE_DAY_PER_HOUR * float(real_time["world_time"])))
	for key: String in ["hunger", "thirst", "fatigue", "infection_seconds", "bleeding_damage", "health_recovered", "wound_healed"]:
		assert_true(float(real_time[key]) > 0.0, "%s changed at scale 1" % key)
		assert_true(_near(float(accelerated[key]), SCALE_DAY_PER_HOUR * float(real_time[key])), "%s is 24x: %f vs %f" % [key, accelerated[key], real_time[key]])
	# Absolute values at 24x: 320 real seconds = 7680 world seconds.
	assert_true(_near(float(accelerated["thirst"]), _survival_settings.need_max * 7680.0 / (_survival_settings.thirst_hours_to_max * SECONDS_PER_HOUR)))
	assert_eq(real_time["infection_stage"], InfectionState.Stage.LATENT, "320 s of a 2 h latent stage at scale 1")
	assert_eq(accelerated["infection_stage"], InfectionState.Stage.EARLY, "2 world hours pass in 5 real minutes at scale 24")


func test_survival_integration_is_tick_size_independent_at_scale_24() -> void:
	# Death by starvation/dehydration, the (action time) respawn delay,
	# infection stage boundaries, need category crossings inside stamina
	# regeneration (action time) and bleeding, in one run of 25 real seconds
	# (600 world seconds).
	_survival_settings.max_health = 1000.0
	_survival_settings.starvation_health_loss_per_world_sec = 0.05
	_survival_settings.dehydration_health_loss_per_world_sec = 0.05
	_survival_settings.respawn_delay_sec = 10.0
	_survival_settings.stamina_regen_per_sec = 1.0
	_survival_settings.health_recovery_per_world_sec = 0.01
	_survival_settings.infection_chance_bite = 1.0
	_survival_settings.infection_latent_hours = 100.0 / SECONDS_PER_HOUR
	_survival_settings.infection_early_hours = 150.0 / SECONDS_PER_HOUR
	_survival_settings.infection_progressing_hours = 200.0 / SECONDS_PER_HOUR
	_survival_settings.infection_severe_hours = 500.0 / SECONDS_PER_HOUR
	_survival_settings.infection_progressing_health_loss_per_world_sec = 0.1
	_survival_settings.infection_severe_health_loss_per_world_sec = 0.2
	const REAL_SECONDS: float = 25.0
	var results: Array[Dictionary] = []
	for tick_sec: float in [1.0 / 60.0, 0.1, 1.0, 25.0]:
		var world: ServerWorld = _world(SCALE_DAY_PER_HOUR)
		var survival: SurvivalService = _survival(world)
		var starving: PlayerState = world.join("starving")
		var runner: PlayerState = world.join("runner")
		var infected: PlayerState = world.join("infected")
		var bleeder: PlayerState = world.join("bleeder")
		var starving_vitals: PlayerVitals = survival.get_vitals(starving.player_id)
		starving_vitals.health = 1.0
		starving_vitals.hunger = _survival_settings.need_max
		starving_vitals.thirst = _survival_settings.need_max
		var runner_vitals: PlayerVitals = survival.get_vitals(runner.player_id)
		runner_vitals.stamina = 0.0
		# Fatigue crosses the caution threshold after 200 world seconds.
		runner_vitals.fatigue = _survival_settings.need_caution_threshold - _survival_settings.need_rate_per_world_sec(NeedKind.Kind.FATIGUE) * 200.0
		assert_true(survival.apply_infection_exposure(infected.player_id, InfectionState.Exposure.BITE, "zombie_1").ok)
		assert_true(survival.apply_damage(bleeder.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.LACERATION, 30.0)).ok)
		var respawn_action_time: float = -1.0
		var elapsed: float = 0.0
		var ticks: int = roundi(REAL_SECONDS / tick_sec)
		for _tick_index: int in ticks:
			world.step_systems(tick_sec)
			elapsed += tick_sec
			for event: Dictionary in survival.drain_events():
				if event["event_type"] == SurvivalService.EVENT_PLAYER_RESPAWNED and event["player_id"] == starving.player_id:
					respawn_action_time = float(event["world_time"]) / SCALE_DAY_PER_HOUR
		var infected_vitals: PlayerVitals = survival.get_vitals(infected.player_id)
		results.append({
			"starving_alive": starving_vitals.is_alive(), "starving_health": starving_vitals.health,
			"starving_hunger": starving_vitals.hunger, "starving_thirst": starving_vitals.thirst,
			"starving_stamina": starving_vitals.stamina, "respawned_at": respawn_action_time,
			"runner_stamina": runner_vitals.stamina, "runner_fatigue": runner_vitals.fatigue,
			"infected_stage": infected_vitals.infection.stage, "infected_elapsed": infected_vitals.infection.stage_elapsed_world_sec,
			"infected_health": infected_vitals.health,
			"bleeder_health": survival.get_vitals(bleeder.player_id).health,
		})
		assert_true(_near(world.clock.world_time_sec, REAL_SECONDS * SCALE_DAY_PER_HOUR, TOLERANCE), "600 world seconds simulated with tick %f" % tick_sec)
	var reference: Dictionary = results[0]
	for index: int in range(1, results.size()):
		for key: String in reference:
			var expected: Variant = reference[key]
			var actual: Variant = results[index][key]
			if typeof(expected) == TYPE_FLOAT:
				assert_true(_near(float(actual), float(expected)), "%s differs between tick sizes: %s vs %s" % [key, str(actual), str(expected)])
			else:
				assert_eq(actual, expected, "%s differs between tick sizes" % key)
	# Analytic checks of the reference run.
	assert_true(bool(reference["starving_alive"]), "the starving player died and respawned inside the run")
	# 1 health at 0.1/world s: dead after 10 world s (0.41667 real s), back 10 real s later.
	assert_true(_near(float(reference["respawned_at"]), 10.0 / SCALE_DAY_PER_HOUR + _survival_settings.respawn_delay_sec), "respawn delay is real seconds: %f" % reference["respawned_at"])
	# Runner: 200 world s (8.3333 real s) at full regen, then caution regen.
	var expected_runner_stamina: float = _survival_settings.stamina_regen_per_sec * (200.0 / SCALE_DAY_PER_HOUR + (REAL_SECONDS - 200.0 / SCALE_DAY_PER_HOUR) * _survival_settings.caution_stamina_regen_multiplier)
	assert_true(_near(float(reference["runner_stamina"]), expected_runner_stamina), "stamina regen is real seconds weighted by the calendar need category: %f vs %f" % [reference["runner_stamina"], expected_runner_stamina])
	# Infection: 100 + 150 + 200 world s -> severe for the remaining 150.
	assert_eq(reference["infected_stage"], InfectionState.Stage.SEVERE)
	assert_true(_near(float(reference["infected_elapsed"]), 150.0))
	assert_true(_near(float(reference["infected_health"]), _survival_settings.max_health - 200.0 * 0.1 - 150.0 * 0.2))


# ------------------------------------------------------------ persistence

func test_both_clocks_survive_save_and_restart() -> void:
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config(SCALE_DAY_PER_HOUR))
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	world.join("alice")
	for _tick_index: int in 137:
		world.step_systems(TICK)
	assert_true(world.clock.action_time_sec > 6.0 and world.clock.world_time_sec > 160.0)
	assert_eq(persistence.save(world), OK)
	var documents: Dictionary = world.to_documents()
	assert_eq(int((documents["world_state"] as Dictionary)["schema_version"]), 3, "world_state schema v3 carries the action clock")
	assert_eq((documents["world_state"] as Dictionary)[ServerWorld.KEY_ACTION_TIME], world.clock.action_time_sec)

	var reloaded: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config(SCALE_DAY_PER_HOUR)).load_or_create(WORLD)
	assert_not_null(reloaded)
	if reloaded == null:
		return
	assert_true(_near(reloaded.clock.world_time_sec, world.clock.world_time_sec, TIGHT), "calendar time restored")
	assert_true(_near(reloaded.clock.action_time_sec, world.clock.action_time_sec, TIGHT), "action time restored")
	assert_true(reloaded.clock.world_time_sec > reloaded.clock.action_time_sec * 20.0, "the two clocks are stored separately")

	var broken: Dictionary = (documents["world_state"] as Dictionary).duplicate(true)
	broken[ServerWorld.KEY_ACTION_TIME] = -5.0
	assert_false(ServerComposition.create_world(WORLD, _config(SCALE_DAY_PER_HOUR)).restore_documents(broken, documents["players"]).is_empty(), "a negative action time is rejected")
	broken.erase(ServerWorld.KEY_ACTION_TIME)
	assert_false(ServerComposition.create_world(WORLD, _config(SCALE_DAY_PER_HOUR)).restore_documents(broken, documents["players"]).is_empty(), "a current-schema document without an action time is rejected")


## Runs until the next zombie attack; returns the action time passed or -1.
func _action_time_until_attack(world: ServerWorld, max_seconds: float) -> float:
	var started: float = world.clock.action_time_sec
	var service: ZombieService = _zombies(world)
	for _tick_index: int in roundi(max_seconds / TICK):
		world.step_systems(TICK)
		for event: Dictionary in service.drain_events():
			if event["event_type"] == ZombieService.EVENT_ATTACKED:
				return world.clock.action_time_sec - started
	return -1.0


func test_saved_action_deadlines_stay_correct_after_restart() -> void:
	_zombie_settings.bite_chance = 0.0
	_zombie_settings.attack_cooldown_sec = 4.0
	_survival_settings.infection_chance_scratch = 0.0
	_survival_settings.respawn_delay_sec = 5.0
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config(SCALE_DAY_PER_HOUR))
	var world: ServerWorld = persistence.load_or_create(WORLD)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	bob.position = Vector3(200, 0, 200)
	var zombie_id: String = str(_zombies(world).spawn_zombie(world, Vector3(0, 0, 1.2), 0.0).event["zombie_id"])
	assert_true(_action_time_until_attack(world, 5.0) >= 0.0, "the zombie attacked")
	assert_true(survival.apply_damage(bob.player_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, 1000.0)).ok)
	# 1 real second later: 3 s of the attack cooldown and 4 s of the respawn
	# delay are left. The calendar moved 24 s meanwhile.
	for _tick_index: int in 20:
		world.step_systems(TICK)
	var cooldown_left: float = _zombies(world).get_zombie(zombie_id).attack_ready_at - world.clock.action_time_sec
	assert_true(_near(cooldown_left, 3.0, TIGHT), "cooldown left before saving: %f" % cooldown_left)
	assert_true(_near(survival.get_vitals(bob.player_id).died_at_action_time, world.clock.action_time_sec - 1.0, TIGHT), "death is stamped in action time")
	assert_eq(persistence.save(world), OK)

	var reloaded: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config(SCALE_DAY_PER_HOUR)).load_or_create(WORLD)
	assert_not_null(reloaded)
	if reloaded == null:
		return
	var restored_left: float = _zombies(reloaded).get_zombie(zombie_id).attack_ready_at - reloaded.clock.action_time_sec
	assert_true(_near(restored_left, cooldown_left, TIGHT), "cooldown left after loading: %f" % restored_left)
	reloaded.join("alice")
	reloaded.join("bob")
	var restored_survival: SurvivalService = _survival(reloaded)
	assert_false(restored_survival.is_alive(bob.player_id), "bob is still waiting to respawn")
	var respawned_after: float = -1.0
	var attacked_after: float = -1.0
	var started: float = reloaded.clock.action_time_sec
	for _tick_index: int in roundi(8.0 / TICK):
		reloaded.step_systems(TICK)
		if respawned_after < 0.0 and restored_survival.is_alive(bob.player_id):
			respawned_after = reloaded.clock.action_time_sec - started
		for event: Dictionary in _zombies(reloaded).drain_events():
			if attacked_after < 0.0 and event["event_type"] == ZombieService.EVENT_ATTACKED:
				attacked_after = reloaded.clock.action_time_sec - started
	assert_true(respawned_after >= 4.0 - TIGHT and respawned_after <= 4.0 + TICK + TIGHT, "the rest of the respawn delay (4 real s) ran after the restart: %f" % respawned_after)
	# The AI phase is not saved (docs/15 P2-31): up to one AI period late.
	assert_true(attacked_after >= 3.0 - TIGHT and attacked_after <= 3.0 + _zombie_settings.ai_period_sec + TICK + TIGHT, "the rest of the attack cooldown (3 real s) ran after the restart: %f" % attacked_after)


func test_pre_t1_save_without_action_time_is_migrated() -> void:
	_zombie_settings.bite_chance = 0.0
	_zombie_settings.attack_cooldown_sec = 4.0
	_survival_settings.infection_chance_scratch = 0.0
	_survival_settings.respawn_delay_sec = 5.0
	# A world as it was saved before P2-T1: real-time clock (scale 1), world
	# schema 2 without action_time_sec, survival fragments schema 3 without
	# died_at_action_time. Its zombie deadlines were written in world time.
	var old_world: ServerWorld = _world(SCALE_REAL)
	var alice: PlayerState = old_world.join("alice")
	var bob: PlayerState = old_world.join("bob")
	bob.position = Vector3(200, 0, 200)
	var zombie_id: String = str(_zombies(old_world).spawn_zombie(old_world, Vector3(0, 0, 1.2), 0.0).event["zombie_id"])
	assert_true(_action_time_until_attack(old_world, 5.0) >= 0.0, "the zombie attacked")
	assert_true(_survival(old_world).apply_damage(bob.player_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, 1000.0)).ok)
	for _tick_index: int in 20:
		old_world.step_systems(TICK)
	var saved_world_time: float = old_world.clock.world_time_sec
	var documents: Dictionary = old_world.to_documents()
	var state: Dictionary = documents["world_state"]
	state["schema_version"] = 2
	state.erase(ServerWorld.KEY_ACTION_TIME)
	var players: Dictionary = documents["players"]
	for player_id: String in players:
		var fragment: Dictionary = ((players[player_id] as Dictionary)[ServerWorld.KEY_SYSTEMS] as Dictionary)[SurvivalService.SYSTEM_ID]
		fragment["schema_version"] = 3
		fragment.erase("died_at_action_time")
	assert_eq(SaveService.new(_root).save_world(WORLD, state, players), OK)

	var migrated_state: Dictionary = SaveMigrations.world_v2_to_v3(state)
	assert_eq(int(migrated_state["schema_version"]), 3)
	assert_eq(migrated_state[ServerWorld.KEY_ACTION_TIME], saved_world_time, "pre-T1 worlds ran in real time: action time = world time")
	assert_false(state.has(ServerWorld.KEY_ACTION_TIME), "the migration does not modify its input")

	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config(SCALE_DAY_PER_HOUR)).load_or_create(WORLD)
	assert_not_null(restored, "the pre-T1 save loads through migration")
	if restored == null:
		return
	assert_true(_near(restored.clock.world_time_sec, saved_world_time, TIGHT))
	assert_true(_near(restored.clock.action_time_sec, saved_world_time, TIGHT))
	var cooldown_left: float = _zombies(restored).get_zombie(zombie_id).attack_ready_at - restored.clock.action_time_sec
	assert_true(_near(cooldown_left, 3.0, TIGHT), "the zombie's saved deadline is still 3 real seconds away: %f" % cooldown_left)
	# A dead player from an older fragment has no action death time: the
	# respawn delay starts when the player comes online again.
	var vitals: PlayerVitals = _survival(restored).get_vitals(bob.player_id)
	assert_false(vitals.is_alive())
	assert_eq(vitals.died_at_action_time, PlayerVitals.NOT_DEAD_TIME)
	restored.join("bob")
	assert_eq(vitals.died_at_action_time, restored.clock.action_time_sec)
	for _tick_index: int in roundi(4.9 / TICK):
		restored.step_systems(TICK)
	assert_false(vitals.is_alive(), "the full respawn delay runs again after migration")
	for _tick_index: int in 4:
		restored.step_systems(TICK)
	assert_true(vitals.is_alive())
	assert_true(_survival(restored).has_player(alice.player_id))
