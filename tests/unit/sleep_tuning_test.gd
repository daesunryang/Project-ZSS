extends TestCase
## P2-T10 (user decision 2026-11-15, docs/00 ADR-016, docs/09 §14.25): sleep
## is shorter and safer, and fatigue also lowers work ability.
##   - shipped rest rate: fatigue from its maximum to 0 in about 8 real minutes
##   - the fatigue category lowers the handling multiplier (melee damage)
##   - a sleeper wakes by itself when hunger / thirst becomes dangerous, when
##     its health falls to the configured fraction, or when the infection
##     reaches the configured stage: nobody dies of time-based damage lying
##     down, whatever the tick size
##   - a player in such danger cannot lie down (no lie down / wake flapping)
##   - a hit on a sleeper hurts and wakes but does not kill; later hits do
## Server rules only, no network.

const WORLD: String = "sleep_tuning_test_world"
const NEVER: float = 1.0e9
const EPSILON: float = 0.001
const SECONDS_PER_HOUR: float = 3600.0
const LETHAL_DAMAGE: float = 100000.0
const AIM_MINUS_Z: float = 0.0
const TICK: float = 0.05
## Real seconds of the tick-size comparison and the small tick it is cut into.
const COMPARE_REAL_SEC: float = 60.0
const SMALL_TICK_SEC: float = 1.0 / 60.0
const ZOMBIE: String = "zombie_000001"

var _settings: SurvivalSettings = null
var _clock: WorldClockSettings = null
var _zombie_settings: ZombieSettings = null
var _combat_settings: CombatSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = SurvivalSettings.new()
	_settings.respawn_delay_sec = NEVER
	# Calendar rules are stated in world seconds here unless a test says
	# otherwise (1x clock: step_systems(x) advances x world seconds).
	_clock = WorldClockSettings.new()
	_clock.time_scale = 1.0
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER
	_combat_settings = CombatSettings.new()
	_combat_settings.damage_roll_min = 1.0
	_combat_settings.damage_roll_max = 1.0


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _world() -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.survival = _settings
	config.clock = _clock
	config.dev_seed = DevWorldSeed.new()
	config.zombie = _zombie_settings
	config.combat = _combat_settings
	return ServerComposition.create_world(WORLD, config)


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _events_of(events: Array[Dictionary], event_type: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == event_type:
			matching.append(event)
	return matching


func _types_of(events: Array[Dictionary]) -> Array:
	var types: Array = []
	for event: Dictionary in events:
		types.append(str(event.get("event_type", "")))
	return types


func _near(actual: float, expected: float, tolerance: float = EPSILON) -> bool:
	return absf(actual - expected) <= tolerance


func _hit(amount: float, part: BodyPart.Part = BodyPart.Part.TORSO, type: Wound.Type = Wound.Type.BRUISE) -> DamageInput:
	return DamageInput.create(ZOMBIE, part, type, amount)


## Health lost per world second by one bleeding laceration of `damage`.
func _laceration_rate(damage: float) -> float:
	var severity: float = clampf(damage / _settings.wound_severity_reference_damage, 0.0, 1.0)
	return _settings.bleeding_health_loss_per_severity_per_world_sec * _settings.bleeding_laceration_multiplier * severity


# ------------------------------------------------------------ settings

func test_shipped_sleep_settings_and_validation() -> void:
	var shipped: SurvivalSettings = SurvivalSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	var real_minutes: float = shipped.rest_fatigue_hours_from_max * 60.0 / WorldClockSettings.load_or_default().time_scale
	assert_true(_near(real_minutes, 8.0, 0.5), "fatigue from its maximum to 0 takes about 8 real minutes: %f" % real_minutes)
	assert_true(shipped.rest_wake_on_need_danger, "dangerous hunger / thirst wakes")
	assert_true(_near(shipped.rest_wake_health_fraction, 0.3), "low health wakes at 30%")
	assert_eq(shipped.rest_wake_infection_stage, int(InfectionState.Stage.TERMINAL))
	assert_true(_near(shipped.rest_hit_min_health, 1.0), "a hit on a sleeper leaves at least 1 health")
	assert_true(shipped.fatigue_caution_handling_multiplier < 1.0, "fatigue lowers work ability")
	assert_true(shipped.fatigue_danger_handling_multiplier < shipped.fatigue_caution_handling_multiplier)
	assert_true(_near(shipped.rest_wake_health(), shipped.max_health * shipped.rest_wake_health_fraction))
	# Each broken value is exactly one error.
	var broken: Array[Callable] = [
		func(s: SurvivalSettings) -> void: s.rest_wake_health_fraction = 0.0,
		func(s: SurvivalSettings) -> void: s.rest_wake_health_fraction = 1.0,
		func(s: SurvivalSettings) -> void: s.rest_wake_health_fraction = NAN,
		func(s: SurvivalSettings) -> void: s.rest_wake_infection_stage = -1,
		func(s: SurvivalSettings) -> void: s.rest_wake_infection_stage = InfectionState.Stage.ZOMBIFIED,
		func(s: SurvivalSettings) -> void: s.rest_hit_min_health = 0.0,
		func(s: SurvivalSettings) -> void: s.rest_hit_min_health = NAN,
		func(s: SurvivalSettings) -> void: s.rest_hit_min_health = s.max_health + 1.0,
		func(s: SurvivalSettings) -> void: s.fatigue_caution_handling_multiplier = 1.5,
		func(s: SurvivalSettings) -> void: s.fatigue_danger_handling_multiplier = -0.1,
		func(s: SurvivalSettings) -> void: s.fatigue_danger_handling_multiplier = s.fatigue_caution_handling_multiplier + 0.1,
	]
	for index: int in broken.size():
		var settings: SurvivalSettings = SurvivalSettings.new()
		broken[index].call(settings)
		assert_eq(settings.validate().size(), 1, "broken value %d: %s" % [index, "; ".join(settings.validate())])


# ------------------------------------------------------------ fatigue and work ability

func test_fatigue_lowers_handling() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_eq(survival.handling_multiplier(alice.player_id), 1.0, "rested: full work ability")
	vitals.fatigue = _settings.need_caution_threshold
	assert_true(_near(survival.handling_multiplier(alice.player_id), _settings.fatigue_caution_handling_multiplier), "caution: %f" % survival.handling_multiplier(alice.player_id))
	vitals.fatigue = _settings.need_danger_threshold
	assert_true(_near(survival.handling_multiplier(alice.player_id), _settings.fatigue_danger_handling_multiplier), "danger: %f" % survival.handling_multiplier(alice.player_id))
	# Only fatigue counts: hunger and thirst do not lower handling.
	vitals.fatigue = 0.0
	vitals.hunger = _settings.need_max
	vitals.thirst = _settings.need_max
	assert_eq(survival.handling_multiplier(alice.player_id), 1.0, "hunger and thirst are not fatigue")
	vitals.hunger = 0.0
	vitals.thirst = 0.0
	# Arm wounds and fatigue multiply.
	assert_true(survival.apply_damage(alice.player_id, _hit(25.0, BodyPart.Part.RIGHT_ARM)).ok)
	var wound_only: float = survival.handling_multiplier(alice.player_id)
	assert_true(_near(wound_only, 1.0 - _settings.handling_penalty_per_severity * 0.5), "the arm wound alone: %f" % wound_only)
	vitals.fatigue = _settings.need_danger_threshold
	assert_true(_near(survival.handling_multiplier(alice.player_id), wound_only * _settings.fatigue_danger_handling_multiplier), "wound x fatigue: %f" % survival.handling_multiplier(alice.player_id))
	# Never below the configured floor.
	assert_true(survival.apply_damage(alice.player_id, _hit(40.0, BodyPart.Part.LEFT_HAND)).ok)
	assert_true(_near(survival.handling_multiplier(alice.player_id), _settings.min_handling_multiplier), "floor: %f" % survival.handling_multiplier(alice.player_id))
	# A leg wound and movement are not touched by this rule.
	vitals.injuries.clear()
	assert_true(_near(survival.movement_speed_multiplier(alice.player_id), _settings.danger_movement_multiplier), "movement keeps its own need penalty")
	# Dead: nothing can be handled.
	assert_true(survival.apply_damage(alice.player_id, _hit(LETHAL_DAMAGE)).ok)
	assert_eq(survival.handling_multiplier(alice.player_id), 0.0)
	assert_eq(survival.handling_multiplier("player_999999"), 1.0, "unknown players are not penalised")


func test_a_tired_player_deals_less_melee_damage() -> void:
	# Blind zombies: they stand still as targets.
	_zombie_settings.sight_range_m = 0.0
	_zombie_settings.hearing_multiplier = 0.0
	_zombie_settings.max_health = LETHAL_DAMAGE
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var combat: CombatService = world.get_system(CombatService.SYSTEM_ID) as CombatService
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var base: float = combat.weapon_for(world, alice.player_id).base_damage
	var cooldown: float = combat.weapon_for(world, alice.player_id).cooldown_sec
	assert_true(_zombies(world).spawn_zombie(world, alice.position + Vector3(0.0, 0.0, -1.0)).ok)
	var damages: Array[float] = []
	for fatigue: float in [0.0, _settings.need_caution_threshold, _settings.need_danger_threshold]:
		vitals.fatigue = fatigue
		vitals.stamina = _settings.max_stamina
		var swing: ActionResult = combat.request_melee_attack(world, alice.player_id, AIM_MINUS_Z)
		assert_true(swing.ok and bool(swing.event["hit"]), "the swing at fatigue %f hits: %s" % [fatigue, swing.reason])
		damages.append(float(swing.event["damage"]))
		world.clock.step(cooldown + TICK, true)
	assert_true(_near(damages[0], base), "rested: full damage %f" % damages[0])
	assert_true(_near(damages[1], base * _settings.fatigue_caution_handling_multiplier), "caution: %f" % damages[1])
	assert_true(_near(damages[2], base * _settings.fatigue_danger_handling_multiplier), "danger: %f" % damages[2])
	assert_true(damages[2] < damages[1] and damages[1] < damages[0])


# ------------------------------------------------------------ waking in danger

func test_a_sleeper_wakes_when_thirst_or_hunger_becomes_dangerous() -> void:
	for kind: String in ["thirst", "hunger"]:
		var world: ServerWorld = _world()
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("alice")
		var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
		vitals.fatigue = 90.0
		vitals.set(kind, _settings.need_danger_threshold - 1.0)
		assert_eq(survival.rest_danger(alice.player_id), SurvivalService.NO_DANGER, "caution is not danger")
		assert_true(survival.start_rest(alice.player_id).ok, "a player in caution may lie down")
		survival.drain_events()
		var start_time: float = world.clock.world_time_sec
		var hours: float = _settings.thirst_hours_to_max if kind == "thirst" else _settings.hunger_hours_to_max
		var crossing_sec: float = 1.0 / (_settings.need_max / (hours * SECONDS_PER_HOUR))
		# One tick far beyond the crossing.
		world.step_systems(crossing_sec * 3.0)
		assert_false(survival.is_resting(alice.player_id), "%s woke the sleeper" % kind)
		assert_true(survival.is_alive(alice.player_id))
		var ended: Array[Dictionary] = _events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_REST_ENDED)
		assert_eq(ended.size(), 1, "one waking")
		assert_eq(ended[0].get("cause", ""), kind, "the owner event says why")
		assert_true(_near(float(ended[0].get("world_time", -1.0)), start_time + crossing_sec, 0.01), "woken at the crossing inside the tick: %f vs %f" % [float(ended[0].get("world_time", -1.0)), start_time + crossing_sec])
		assert_true(SurvivalService.REST_END_CAUSES.has(kind))
		# Fatigue fell until the waking and has risen since.
		var rested: float = 90.0 - crossing_sec * _settings.need_max / (_settings.rest_fatigue_hours_from_max * SECONDS_PER_HOUR)
		var expected: float = rested + 2.0 * crossing_sec * _settings.need_max / (_settings.fatigue_hours_to_max * SECONDS_PER_HOUR)
		assert_true(_near(vitals.fatigue, expected, 0.01), "fatigue %f, expected %f" % [vitals.fatigue, expected])
		assert_eq(survival.rest_danger(alice.player_id), kind)


func test_dangerous_needs_do_not_wake_when_the_setting_is_off() -> void:
	_settings.rest_wake_on_need_danger = false
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.thirst = _settings.need_danger_threshold + 1.0
	assert_true(survival.start_rest(alice.player_id).ok, "the setting also allows lying down")
	world.step_systems(600.0)
	assert_true(survival.is_resting(alice.player_id))
	# Dehydration still cannot kill a sleeper: the health threshold wakes it.
	vitals.thirst = _settings.need_max
	world.step_systems(1000.0 * SECONDS_PER_HOUR)
	var ended: Array[Dictionary] = _events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_REST_ENDED)
	assert_eq(ended.size(), 1)
	assert_eq(ended[0].get("cause", ""), SurvivalService.REST_END_LOW_HEALTH)


func test_a_bleeding_sleeper_wakes_at_the_health_threshold_and_never_dies_lying_down() -> void:
	const WOUND_DAMAGE: float = 20.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_true(survival.apply_damage(alice.player_id, _hit(WOUND_DAMAGE, BodyPart.Part.TORSO, Wound.Type.LACERATION)).ok)
	var health: float = vitals.health
	assert_true(survival.start_rest(alice.player_id).ok, "a bleeding player above the threshold may lie down")
	survival.drain_events()
	var start_time: float = world.clock.world_time_sec
	var rate: float = _laceration_rate(WOUND_DAMAGE)
	var wake_sec: float = (health - _settings.rest_wake_health()) / rate
	# Shortly before the threshold: still asleep, still bleeding.
	world.step_systems(wake_sec - 10.0)
	assert_true(survival.is_resting(alice.player_id))
	assert_true(_near(vitals.health, _settings.rest_wake_health() + 10.0 * rate), "health %f" % vitals.health)
	# One huge tick: the sleeper wakes at the threshold, bleeds on awake and
	# only then dies. It never dies lying down.
	world.step_systems(1000.0 * SECONDS_PER_HOUR)
	assert_false(survival.is_alive(alice.player_id), "an awake player still bleeds out")
	var events: Array[Dictionary] = survival.drain_events()
	var ended: Array[Dictionary] = _events_of(events, SurvivalService.EVENT_PLAYER_REST_ENDED)
	var died: Array[Dictionary] = _events_of(events, SurvivalService.EVENT_PLAYER_DIED)
	assert_eq(ended.size(), 1, "types: %s" % str(_types_of(events)))
	assert_eq(ended[0].get("cause", ""), SurvivalService.REST_END_LOW_HEALTH, "woken by low health, not ended by death")
	assert_true(_near(float(ended[0].get("world_time", -1.0)), start_time + wake_sec, 0.01), "woken exactly at the threshold inside the tick")
	assert_eq(died.size(), 1)
	assert_true(_near(float(died[0].get("world_time", -1.0)), start_time + health / rate, 0.01), "the death comes later, awake")
	var types: Array = _types_of(events)
	assert_true(types.find(SurvivalService.EVENT_PLAYER_REST_ENDED) < types.find(SurvivalService.EVENT_PLAYER_DIED))


func test_waking_does_not_depend_on_tick_size() -> void:
	# Game clock (24x). Thirst crosses into danger mid-way: the big tick, the
	# 60 Hz ticks and an odd tick count must agree on when the sleeper woke
	# and on everything that followed.
	_clock.time_scale = 24.0
	_settings.stamina_regen_per_sec = 1.0
	var results: Array[Dictionary] = []
	var tick_counts: Array[int] = [1, int(round(COMPARE_REAL_SEC / SMALL_TICK_SEC)), 7]
	for ticks: int in tick_counts:
		var world: ServerWorld = _world()
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("alice")
		var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
		vitals.fatigue = 90.0
		vitals.thirst = _settings.need_danger_threshold - 1.0
		vitals.stamina = 0.0
		assert_true(survival.apply_damage(alice.player_id, _hit(15.0, BodyPart.Part.TORSO, Wound.Type.LACERATION)).ok)
		assert_true(survival.start_rest(alice.player_id).ok)
		survival.drain_events()
		var woke_at: float = -1.0
		for tick: int in ticks:
			world.step_systems(COMPARE_REAL_SEC / float(ticks))
			for event: Dictionary in _events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_REST_ENDED):
				assert_eq(event.get("cause", ""), SurvivalService.REST_END_THIRST)
				woke_at = float(event["world_time"])
		assert_false(survival.is_resting(alice.player_id), "%d tick(s): woken" % ticks)
		results.append({"woke_at": woke_at, "fatigue": vitals.fatigue, "thirst": vitals.thirst, "health": vitals.health, "stamina": vitals.stamina})
	var crossing_world_sec: float = 1.0 / (_settings.need_max / (_settings.thirst_hours_to_max * SECONDS_PER_HOUR))
	assert_true(crossing_world_sec < COMPARE_REAL_SEC * 24.0, "the comparison crosses the threshold")
	for index: int in results.size():
		var result: Dictionary = results[index]
		var label: String = "%d tick(s): %s" % [tick_counts[index], str(result)]
		assert_true(_near(float(result["woke_at"]), crossing_world_sec, 0.05), label)
		for key: String in result:
			assert_true(_near(float(result[key]), float(results[0][key]), 0.05), "%s differs from one big tick: %s" % [key, label])


func test_the_terminal_stage_wakes_and_only_an_unwoken_sleeper_turns_lying_down() -> void:
	const STAGE_HOURS: float = 1.0
	for wake_stage: int in [InfectionState.Stage.TERMINAL, InfectionState.Stage.NONE]:
		_settings = SurvivalSettings.new()
		_settings.respawn_delay_sec = NEVER
		_settings.rest_wake_infection_stage = wake_stage
		_settings.infection_chance_bite = 1.0
		for stage_hours: String in ["infection_latent_hours", "infection_early_hours", "infection_progressing_hours", "infection_severe_hours", "infection_terminal_hours"]:
			_settings.set(stage_hours, STAGE_HOURS)
		# The stages themselves cost no health here: only the stage wakes.
		_settings.infection_progressing_health_loss_per_world_sec = 0.0
		_settings.infection_severe_health_loss_per_world_sec = 0.0
		_settings.infection_terminal_health_loss_per_world_sec = 0.0
		var world: ServerWorld = _world()
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("alice")
		assert_true(survival.apply_infection_exposure(alice.player_id, InfectionState.Exposure.BITE, ZOMBIE).ok)
		assert_true(survival.start_rest(alice.player_id).ok, "an infected player may sleep before the wake stage")
		survival.drain_events()
		var start_time: float = world.clock.world_time_sec
		# One tick across every stage.
		world.step_systems(6.0 * STAGE_HOURS * SECONDS_PER_HOUR)
		var events: Array[Dictionary] = survival.drain_events()
		var ended: Array[Dictionary] = _events_of(events, SurvivalService.EVENT_PLAYER_REST_ENDED)
		assert_false(survival.is_alive(alice.player_id), "turning does not depend on sleep")
		assert_eq(ended.size(), 1, "types: %s" % str(_types_of(events)))
		if wake_stage == InfectionState.Stage.TERMINAL:
			assert_eq(ended[0].get("cause", ""), SurvivalService.REST_END_INFECTION, "woken when the terminal stage began")
			assert_true(_near(float(ended[0].get("world_time", -1.0)), start_time + 4.0 * STAGE_HOURS * SECONDS_PER_HOUR, 0.01))
		else:
			assert_eq(ended[0].get("cause", ""), SurvivalService.REST_END_DIED, "with the wake stage off the sleeper turns lying down")
			assert_true(_near(float(ended[0].get("world_time", -1.0)), start_time + 5.0 * STAGE_HOURS * SECONDS_PER_HOUR, 0.01))


# ------------------------------------------------------------ lying down in danger

func test_a_player_in_danger_cannot_lie_down() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var cases: Array[Array] = [
		[func() -> void: vitals.health = _settings.rest_wake_health(), SurvivalService.REST_END_LOW_HEALTH],
		[func() -> void: vitals.thirst = _settings.need_danger_threshold, SurvivalService.REST_END_THIRST],
		[func() -> void: vitals.hunger = _settings.need_danger_threshold, SurvivalService.REST_END_HUNGER],
		[func() -> void: vitals.infection.stage = InfectionState.Stage.TERMINAL, SurvivalService.REST_END_INFECTION],
	]
	for case: Array in cases:
		vitals.health = _settings.max_health
		vitals.thirst = 0.0
		vitals.hunger = 0.0
		vitals.infection = InfectionState.new()
		(case[0] as Callable).call()
		survival.drain_events()
		assert_eq(survival.rest_danger(alice.player_id), case[1])
		var refused: ActionResult = survival.start_rest(alice.player_id)
		assert_false(refused.ok)
		assert_eq(refused.reason, SurvivalService.REASON_CANNOT_REST_PREFIX + str(case[1]))
		assert_false(survival.is_resting(alice.player_id), "a refused request changes nothing")
		assert_eq(survival.drain_events().size(), 0, "and reports nothing")
	# Several dangers at once: health first, then thirst, hunger, infection.
	vitals.health = 1.0
	vitals.thirst = _settings.need_max
	vitals.hunger = _settings.need_max
	assert_eq(survival.rest_danger(alice.player_id), SurvivalService.REST_END_LOW_HEALTH)
	vitals.health = _settings.max_health
	assert_eq(survival.rest_danger(alice.player_id), SurvivalService.REST_END_THIRST)
	# Fatigue is never a danger: an exhausted player may always sleep.
	vitals.thirst = 0.0
	vitals.hunger = 0.0
	vitals.infection = InfectionState.new()
	vitals.fatigue = _settings.need_max
	assert_eq(survival.rest_danger(alice.player_id), SurvivalService.NO_DANGER)
	assert_true(survival.start_rest(alice.player_id).ok)
	assert_eq(survival.rest_danger("player_999999"), SurvivalService.NO_DANGER)


func test_a_woken_player_cannot_lie_down_again_at_once() -> void:
	# No flapping: whatever woke the sleeper also refuses the next lie-down,
	# tick after tick, until the danger is dealt with.
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.thirst = _settings.need_danger_threshold - 0.5
	assert_true(survival.start_rest(alice.player_id).ok)
	var woke: bool = false
	for tick: int in 2000:
		world.step_systems(1.0)
		if not survival.is_resting(alice.player_id):
			woke = true
			break
	assert_true(woke, "thirst woke the sleeper")
	survival.drain_events()
	for tick: int in 10:
		assert_eq(survival.start_rest(alice.player_id).reason, SurvivalService.REASON_CANNOT_REST_PREFIX + SurvivalService.REST_END_THIRST, "tick %d after waking" % tick)
		world.step_systems(TICK)
	assert_eq(_events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_REST_STARTED).size(), 0)
	# Drinking removes the danger; then lying down works and lasts.
	assert_true(survival.reduce_needs(alice.player_id, 0.0, 50.0, "test").ok)
	assert_true(survival.start_rest(alice.player_id).ok)
	world.step_systems(60.0)
	assert_true(survival.is_resting(alice.player_id))


# ------------------------------------------------------------ hits on a sleeper

func test_a_hit_on_a_sleeper_hurts_and_wakes_but_does_not_kill() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_true(survival.start_rest(alice.player_id).ok)
	survival.drain_events()
	var first: ActionResult = survival.apply_damage(alice.player_id, _hit(LETHAL_DAMAGE))
	assert_true(first.ok, first.reason)
	assert_true(survival.is_alive(alice.player_id), "the hit taken asleep does not kill")
	assert_true(_near(vitals.health, _settings.rest_hit_min_health), "health %f" % vitals.health)
	assert_false(survival.is_resting(alice.player_id), "and wakes")
	# The event contract of apply_damage is unchanged.
	assert_eq(first.event.get("event_type", ""), SurvivalService.EVENT_PLAYER_WOUNDED)
	assert_eq(first.event.get("died", true), false)
	assert_true(_near(float(first.event.get("health_after", -1.0)), _settings.rest_hit_min_health))
	assert_eq(first.event.get("damage", 0.0), LETHAL_DAMAGE, "the damage dealt is reported as it was")
	assert_eq(vitals.injuries.size(), 1, "the wound is recorded")
	var events: Array[Dictionary] = survival.drain_events()
	assert_eq(_types_of(events), [SurvivalService.EVENT_PLAYER_WOUNDED, SurvivalService.EVENT_PLAYER_REST_ENDED])
	assert_eq(events[1].get("cause", ""), SurvivalService.REST_END_DAMAGED)
	# Awake now: the next hit, even in the same tick, follows the usual rules.
	var second: ActionResult = survival.apply_damage(alice.player_id, _hit(LETHAL_DAMAGE))
	assert_true(second.ok, second.reason)
	assert_eq(second.event.get("died", false), true)
	assert_false(survival.is_alive(alice.player_id), "a hit on an awake player kills")
	assert_eq(_types_of(survival.drain_events()), [SurvivalService.EVENT_PLAYER_WOUNDED, SurvivalService.EVENT_PLAYER_DIED])


func test_a_light_hit_on_a_sleeper_is_applied_in_full_and_never_heals() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_true(survival.start_rest(alice.player_id).ok)
	assert_true(survival.apply_damage(alice.player_id, _hit(8.0)).ok)
	assert_true(_near(vitals.health, _settings.max_health - 8.0), "an ordinary hit costs what it costs: %f" % vitals.health)
	# A sleeper already below the floor is not healed up to it by a hit.
	vitals.health = _settings.max_health
	assert_true(survival.start_rest(alice.player_id).ok)
	vitals.health = _settings.rest_hit_min_health * 0.5
	assert_true(survival.apply_damage(alice.player_id, _hit(LETHAL_DAMAGE)).ok)
	assert_true(_near(vitals.health, _settings.rest_hit_min_health * 0.5), "health %f" % vitals.health)
	assert_true(survival.is_alive(alice.player_id))
	assert_false(survival.is_resting(alice.player_id))


func test_zombie_attacks_on_a_sleeper_the_first_hit_is_survived_later_hits_kill() -> void:
	# Every zombie hit would kill a full-health player.
	_zombie_settings.bite_damage = LETHAL_DAMAGE
	_zombie_settings.scratch_damage = LETHAL_DAMAGE
	# No bleeding: only hits change health in this test.
	_settings.bleeding_bite_multiplier = 0.0
	_settings.bleeding_scratch_multiplier = 0.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var zombies: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_true(survival.start_rest(alice.player_id).ok)
	# Next to the sleeper, facing her (yaw 0 looks along -Z).
	assert_true(zombies.spawn_zombie(world, alice.position + Vector3(0.0, 0.0, 1.0), 0.0).ok)
	zombies.drain_events()
	var attack_times: Array[float] = []
	var health_after_first: float = -1.0
	var alive_after_first: bool = false
	var resting_after_first: bool = true
	for tick: int in 400:
		world.step_systems(TICK)
		for event: Dictionary in _events_of(zombies.drain_events(), ZombieService.EVENT_ATTACKED):
			attack_times.append(world.clock.action_time_sec)
			if attack_times.size() == 1:
				health_after_first = vitals.health
				alive_after_first = survival.is_alive(alice.player_id)
				resting_after_first = survival.is_resting(alice.player_id)
				assert_eq(event.get("target_died", true), false, "the zombie's event agrees")
		if attack_times.size() >= 2:
			break
	assert_eq(attack_times.size(), 2, "the zombie attacked twice")
	assert_true(alive_after_first, "the sleeper survived the first hit")
	assert_true(_near(health_after_first, _settings.rest_hit_min_health), "with the floor health: %f" % health_after_first)
	assert_false(resting_after_first, "and was woken by it")
	assert_true(attack_times[1] - attack_times[0] >= _zombie_settings.attack_cooldown_sec - EPSILON, "the second hit comes one cooldown later: %f" % (attack_times[1] - attack_times[0]))
	assert_false(survival.is_alive(alice.player_id), "the second hit, on an awake player, kills")
