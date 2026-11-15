extends TestCase
## P2-T8 (user decision 2026-11-15): resting lowers fatigue, on the server,
## no network. SurvivalService.start_rest / stop_rest: while a player rests
## its fatigue falls at the configured calendar-time rate (never below 0),
## hunger and thirst keep rising, it cannot move, attack or handle items,
## and a hit wakes it. Death and leaving end the rest. Resting is not saved.

const WORLD: String = "rest_test_world"
const NEVER: float = 1.0e9
const EPSILON: float = 0.001
const SECONDS_PER_HOUR: float = 3600.0
const INPUT_TIMEOUT_MSEC: int = 1000
const LETHAL_DAMAGE: float = 100000.0
const LIGHT_DAMAGE: float = 5.0
const FOOD: String = "t8_food"
const AIM_MINUS_Z: float = 0.0
## Real seconds of the tick-size comparison and the small tick it is cut into.
const COMPARE_REAL_SEC: float = 25.0
const SMALL_TICK_SEC: float = 1.0 / 60.0

var _settings: SurvivalSettings = null
var _clock: WorldClockSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = ""
	_settings = SurvivalSettings.new()
	_settings.respawn_delay_sec = NEVER
	# Calendar rules are stated in world seconds here unless a test says
	# otherwise (1x clock: step_systems(x) advances x world seconds).
	_clock = WorldClockSettings.new()
	_clock.time_scale = 1.0


func after_each() -> void:
	if not _root.is_empty():
		SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var food: ItemDefinition = ItemDefinition.new()
	food.definition_id = FOOD
	food.max_stack = 5
	food.consume_hunger_reduction = 30.0
	catalog.add(food)
	return catalog


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.survival = _settings
	config.clock = _clock
	config.catalog = _catalog()
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	return config


func _world() -> ServerWorld:
	return ServerComposition.create_world(WORLD, _config())


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _combat(world: ServerWorld) -> CombatService:
	return world.get_system(CombatService.SYSTEM_ID) as CombatService


func _events_of(events: Array[Dictionary], event_type: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == event_type:
			matching.append(event)
	return matching


func _near(actual: float, expected: float, tolerance: float = EPSILON) -> bool:
	return absf(actual - expected) <= tolerance


## Fatigue taken off per world second of rest.
func _rest_rate() -> float:
	return _settings.need_max / (_settings.rest_fatigue_hours_from_max * SECONDS_PER_HOUR)


## Moves +X for one second and returns the distance covered.
func _walk_one_second(world: ServerWorld, player: PlayerState, sequence: int) -> float:
	var before: float = player.position.x
	assert_eq(world.set_move_input(player.player_id, sequence, Vector2(1, 0), 0.0, 0), "")
	world.step_movement(1.0, 0, INPUT_TIMEOUT_MSEC)
	return player.position.x - before


func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, DevWorldSeed.DEV_CELL_ID, player.position)
	var result: ActionResult = world.try_pickup(player.player_id, item_id)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


# ------------------------------------------------------------ settings

func test_rest_settings_are_shipped_and_validated() -> void:
	var shipped: SurvivalSettings = SurvivalSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_true(shipped.rest_fatigue_hours_from_max > 0.0, "resting lowers fatigue")
	assert_true(shipped.rest_fatigue_hours_from_max < shipped.fatigue_hours_to_max, "rest recovers faster than fatigue builds up")
	assert_eq(shipped.rest_hunger_thirst_rate_multiplier, 1.0, "hunger and thirst keep rising while resting")
	for bad: float in [0.0, -1.0, NAN, INF]:
		var broken: SurvivalSettings = SurvivalSettings.new()
		broken.rest_fatigue_hours_from_max = bad
		assert_eq(broken.validate().size(), 1, "rest hours %s: %s" % [str(bad), "; ".join(broken.validate())])
	for bad: float in [-0.5, NAN, INF]:
		var broken: SurvivalSettings = SurvivalSettings.new()
		broken.rest_hunger_thirst_rate_multiplier = bad
		assert_eq(broken.validate().size(), 1, "multiplier %s: %s" % [str(bad), "; ".join(broken.validate())])


# ------------------------------------------------------------ start / stop

func test_start_and_stop_rest_report_events_and_reject_bad_states() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	survival.drain_events()
	assert_false(survival.is_resting(alice.player_id))
	assert_eq(survival.stop_rest(alice.player_id).reason, SurvivalService.REASON_NOT_RESTING, "nobody gets up who is not lying")

	var started: ActionResult = survival.start_rest(alice.player_id)
	assert_true(started.ok, started.reason)
	assert_true(survival.is_resting(alice.player_id))
	assert_false(survival.is_resting(bob.player_id), "resting is per player")
	assert_eq(started.event.get("event_type", ""), SurvivalService.EVENT_PLAYER_REST_STARTED)
	assert_eq(started.event.get("player_id", ""), alice.player_id)
	assert_eq(started.event.get("world_time", -1.0), world.clock.world_time_sec, "calendar time stamp")
	assert_true(SaveService.is_json_safe(started.event))
	assert_eq(survival.start_rest(alice.player_id).reason, SurvivalService.REASON_ALREADY_RESTING)
	assert_true(survival.is_resting(alice.player_id), "a refused request changes nothing")

	var stopped: ActionResult = survival.stop_rest(alice.player_id)
	assert_true(stopped.ok, stopped.reason)
	assert_false(survival.is_resting(alice.player_id))
	assert_eq(stopped.event.get("event_type", ""), SurvivalService.EVENT_PLAYER_REST_ENDED)
	assert_eq(stopped.event.get("cause", ""), SurvivalService.REST_END_REQUESTED)
	assert_true(SaveService.is_json_safe(stopped.event))
	# Both facts are queued for the network layer, in order, once each.
	var events: Array[Dictionary] = survival.drain_events()
	var types: Array = []
	for event: Dictionary in events:
		types.append(str(event.get("event_type", "")))
	assert_eq(types, [SurvivalService.EVENT_PLAYER_REST_STARTED, SurvivalService.EVENT_PLAYER_REST_ENDED])

	# Unknown, offline and dead players do not rest.
	assert_eq(survival.start_rest("player_999999").reason, SurvivalService.REASON_UNKNOWN_PLAYER)
	assert_eq(survival.stop_rest("player_999999").reason, SurvivalService.REASON_UNKNOWN_PLAYER)
	world.leave(bob.player_id)
	assert_eq(survival.start_rest(bob.player_id).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	survival.drain_events()
	assert_eq(survival.start_rest(alice.player_id).reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_false(survival.is_resting(alice.player_id))
	assert_false(survival.is_resting("player_999999"))
	assert_eq(survival.drain_events().size(), 0, "refused requests report nothing")


# ------------------------------------------------------------ fatigue

func test_resting_lowers_fatigue_at_the_configured_rate_while_other_needs_rise() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var resting: PlayerVitals = survival.get_vitals(alice.player_id)
	var awake: PlayerVitals = survival.get_vitals(bob.player_id)
	for vitals: PlayerVitals in [resting, awake]:
		vitals.fatigue = 80.0
		vitals.hunger = 10.0
		vitals.thirst = 10.0
	assert_true(survival.start_rest(alice.player_id).ok)
	world.step_systems(SECONDS_PER_HOUR)
	# One world hour of rest takes need_max / rest hours off; it does not rise.
	assert_true(_near(resting.fatigue, 80.0 - _settings.need_max / _settings.rest_fatigue_hours_from_max), "fatigue after 1h of rest: %f" % resting.fatigue)
	assert_true(_near(awake.fatigue, 80.0 + _settings.need_max / _settings.fatigue_hours_to_max), "awake fatigue after 1h: %f" % awake.fatigue)
	# Hunger and thirst rise as they do awake.
	assert_true(_near(resting.hunger, awake.hunger) and _near(resting.thirst, awake.thirst), "hunger %f / %f, thirst %f / %f" % [resting.hunger, awake.hunger, resting.thirst, awake.thirst])
	assert_true(_near(resting.hunger, 10.0 + _settings.need_max / _settings.hunger_hours_to_max))
	assert_true(_near(resting.thirst, 10.0 + _settings.need_max / _settings.thirst_hours_to_max))
	# Getting up: fatigue climbs again from where it is.
	assert_true(survival.stop_rest(alice.player_id).ok)
	var after_rest: float = resting.fatigue
	world.step_systems(SECONDS_PER_HOUR)
	assert_true(_near(resting.fatigue, after_rest + _settings.need_max / _settings.fatigue_hours_to_max))


func test_fatigue_never_drops_below_zero_and_categories_are_reported() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.fatigue = 80.0
	assert_eq(survival.need_category(alice.player_id, NeedKind.Kind.FATIGUE), NeedKind.Category.DANGER)
	assert_true(survival.start_rest(alice.player_id).ok)
	survival.drain_events()
	# Far longer than a full recovery.
	world.step_systems(2.0 * _settings.rest_fatigue_hours_from_max * SECONDS_PER_HOUR)
	assert_eq(vitals.fatigue, 0.0, "fatigue stops at 0")
	assert_eq(survival.need_category(alice.player_id, NeedKind.Kind.FATIGUE), NeedKind.Category.GOOD)
	assert_true(survival.is_resting(alice.player_id), "a rested player stays down until it gets up")
	world.step_systems(SECONDS_PER_HOUR)
	assert_eq(vitals.fatigue, 0.0, "and stays at 0 while resting")
	var changes: Array[Dictionary] = []
	for event: Dictionary in _events_of(survival.drain_events(), SurvivalService.EVENT_NEED_CATEGORY_CHANGED):
		if str(event.get("need", "")) == "fatigue":
			changes.append(event)
	assert_true(changes.size() >= 1, "the better fatigue category is reported")
	assert_eq(changes[changes.size() - 1].get("category", ""), "good")


func test_hunger_and_thirst_growth_while_resting_is_a_setting() -> void:
	_settings.rest_hunger_thirst_rate_multiplier = 0.5
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_true(survival.start_rest(alice.player_id).ok)
	world.step_systems(SECONDS_PER_HOUR)
	assert_true(_near(vitals.hunger, 0.5 * _settings.need_max / _settings.hunger_hours_to_max), "hunger %f" % vitals.hunger)
	assert_true(_near(vitals.thirst, 0.5 * _settings.need_max / _settings.thirst_hours_to_max), "thirst %f" % vitals.thirst)
	assert_true(survival.stop_rest(alice.player_id).ok)
	var hunger: float = vitals.hunger
	world.step_systems(SECONDS_PER_HOUR)
	assert_true(_near(vitals.hunger, hunger + _settings.need_max / _settings.hunger_hours_to_max), "awake again: the full rate")


func test_rest_result_does_not_depend_on_tick_size() -> void:
	# Game clock (24x), a tick long enough to cross the fatigue caution
	# threshold mid-tick: the big tick and the 60 Hz ticks must agree on
	# fatigue, the other needs, natural recovery (which starts when fatigue
	# becomes good) and stamina regeneration (whose need penalty ends then).
	_clock.time_scale = 24.0
	_settings.stamina_regen_per_sec = 1.0
	var results: Array[Dictionary] = []
	var tick_counts: Array[int] = [1, int(round(COMPARE_REAL_SEC / SMALL_TICK_SEC)), 7]
	for ticks: int in tick_counts:
		var world: ServerWorld = _world()
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("alice")
		var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
		vitals.fatigue = _settings.need_caution_threshold + 1.0
		vitals.health = 50.0
		vitals.stamina = 0.0
		assert_true(survival.start_rest(alice.player_id).ok)
		for tick: int in ticks:
			world.step_systems(COMPARE_REAL_SEC / float(ticks))
		results.append({"fatigue": vitals.fatigue, "hunger": vitals.hunger, "thirst": vitals.thirst, "health": vitals.health, "stamina": vitals.stamina})
	var world_sec: float = COMPARE_REAL_SEC * 24.0
	var expected_fatigue: float = _settings.need_caution_threshold + 1.0 - _rest_rate() * world_sec
	assert_true(expected_fatigue < _settings.need_caution_threshold, "the comparison crosses the caution threshold")
	# Recovery runs from the moment fatigue is good.
	var good_from_world_sec: float = 1.0 / _rest_rate()
	var expected_health: float = 50.0 + _settings.health_recovery_per_world_sec * (world_sec - good_from_world_sec)
	for index: int in results.size():
		var result: Dictionary = results[index]
		var label: String = "%d tick(s): %s" % [tick_counts[index], str(result)]
		assert_true(_near(float(result["fatigue"]), expected_fatigue), label)
		assert_true(_near(float(result["health"]), expected_health, 0.01), label)
		for key: String in result:
			assert_true(_near(float(result[key]), float(results[0][key]), 0.01), "%s differs from one big tick: %s" % [key, label])
	assert_true(float(results[0]["health"]) > 50.0 and float(results[0]["stamina"]) > 0.0)


func test_rest_runs_on_calendar_time() -> void:
	# The same real time at 1x and at 24x: fatigue falls 24 times as far.
	var lowered: Dictionary = {}
	for scale: float in [1.0, 24.0]:
		_clock = WorldClockSettings.new()
		_clock.time_scale = scale
		var world: ServerWorld = _world()
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("alice")
		var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
		vitals.fatigue = 90.0
		assert_true(survival.start_rest(alice.player_id).ok)
		for tick: int in 600:
			world.step_systems(0.1)
		lowered[scale] = 90.0 - vitals.fatigue
	assert_true(_near(float(lowered[1.0]), _rest_rate() * 60.0), "1x: 60 world seconds of rest: %f" % float(lowered[1.0]))
	assert_true(_near(float(lowered[24.0]), 24.0 * float(lowered[1.0])), "24x: %f vs 1x: %f" % [float(lowered[24.0]), float(lowered[1.0])])
	# The shipped numbers: fatigue at its maximum is gone after this much rest.
	var shipped: SurvivalSettings = SurvivalSettings.load_or_default()
	var real_minutes: float = shipped.rest_fatigue_hours_from_max * 60.0 / WorldClockSettings.load_or_default().time_scale
	assert_true(real_minutes > 0.0 and real_minutes <= 60.0, "full recovery in real minutes: %f" % real_minutes)


# ------------------------------------------------------------ what a resting player cannot do

func test_a_resting_player_cannot_move() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	assert_true(_walk_one_second(world, alice, 1) > 0.0, "awake: the player moves")
	assert_true(survival.start_rest(alice.player_id).ok)
	assert_eq(world.player_movement_multiplier(alice.player_id), 0.0)
	assert_eq(survival.player_movement_multiplier(alice.player_id), 0.0)
	var position: Vector3 = alice.position
	assert_eq(_walk_one_second(world, alice, 2), 0.0, "a move intent of a resting player moves nothing")
	assert_eq(alice.position, position)
	assert_true(survival.is_resting(alice.player_id), "a move intent does not wake the player")
	assert_true(survival.stop_rest(alice.player_id).ok)
	assert_eq(world.player_movement_multiplier(alice.player_id), 1.0)
	assert_true(absf(_walk_one_second(world, alice, 3) - world.gameplay.move_speed_mps) < EPSILON, "up again: full speed")


func test_a_resting_player_cannot_attack_or_handle_items() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var combat: CombatService = _combat(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 50.0
	var food_id: String = _give(world, alice, FOOD, 2)
	var lying_id: String = world.inventory.spawn_world_item(FOOD, 1, DevWorldSeed.DEV_CELL_ID, alice.position)
	assert_true(survival.start_rest(alice.player_id).ok)
	assert_eq(survival.player_action_block_reason(alice.player_id), SurvivalService.REASON_PLAYER_RESTING)
	assert_eq(world.player_action_block_reason(alice.player_id), SurvivalService.REASON_PLAYER_RESTING)
	var stamina: float = vitals.stamina
	var before_items: Dictionary = world.inventory.to_snapshot()
	combat.drain_events()

	var swing: ActionResult = combat.request_melee_attack(world, alice.player_id, AIM_MINUS_Z)
	assert_false(swing.ok)
	assert_eq(swing.reason, SurvivalService.REASON_PLAYER_RESTING, "no melee attack while resting")
	assert_eq(vitals.stamina, stamina, "a refused swing costs no stamina")
	assert_eq(combat.cooldown_remaining(alice.player_id), 0.0, "and starts no cooldown")
	assert_eq(combat.drain_events().size(), 0, "and is not an event")
	assert_eq(world.try_pickup(alice.player_id, lying_id).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_eq(world.try_drop_item(alice.player_id, food_id).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, food_id).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_eq(world.inventory.to_snapshot(), before_items, "no item changed")
	assert_eq(vitals.hunger, 50.0)
	assert_true(survival.is_resting(alice.player_id), "refused actions do not wake the player")

	# Up again: everything works.
	assert_true(survival.stop_rest(alice.player_id).ok)
	assert_eq(world.player_action_block_reason(alice.player_id), "")
	assert_true(combat.request_melee_attack(world, alice.player_id, AIM_MINUS_Z).ok)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, food_id).ok)
	assert_true(world.try_pickup(alice.player_id, lying_id).ok)
	# (P2-T15: the picked-up unit joined the stack she carries.)
	assert_true(world.try_drop_item(alice.player_id, food_id).ok)


# ------------------------------------------------------------ what ends a rest

func test_a_hit_wakes_a_resting_player() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.fatigue = 60.0
	assert_true(survival.start_rest(alice.player_id).ok)
	survival.drain_events()
	var hit: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.LEFT_ARM, Wound.Type.BRUISE, LIGHT_DAMAGE))
	assert_true(hit.ok, hit.reason)
	assert_false(survival.is_resting(alice.player_id), "damage wakes the player")
	assert_true(survival.is_alive(alice.player_id))
	var events: Array[Dictionary] = survival.drain_events()
	var types: Array = []
	for event: Dictionary in events:
		types.append(str(event.get("event_type", "")))
	assert_eq(types, [SurvivalService.EVENT_PLAYER_WOUNDED, SurvivalService.EVENT_PLAYER_REST_ENDED], "the hit, then the waking")
	assert_eq(events[1].get("cause", ""), SurvivalService.REST_END_DAMAGED)
	assert_eq(events[1].get("player_id", ""), alice.player_id)
	# Awake: it can move again and fatigue rises again.
	assert_true(world.player_movement_multiplier(alice.player_id) > 0.0)
	var fatigue: float = vitals.fatigue
	world.step_systems(SECONDS_PER_HOUR)
	assert_true(vitals.fatigue > fatigue, "fatigue rises again")
	# A hit on somebody who is not resting reports no waking.
	survival.drain_events()
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.LEFT_ARM, Wound.Type.BRUISE, LIGHT_DAMAGE)).ok)
	assert_eq(_events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_REST_ENDED).size(), 0)


func test_death_and_leaving_end_a_rest() -> void:
	_settings.respawn_delay_sec = 1.0
	# P2-T10: a hit no longer kills a sleeper and time-based damage wakes it
	# first, so the only death lying down is turning at the end of the
	# terminal stage with the infection wake stage switched off.
	_settings.rest_wake_infection_stage = InfectionState.Stage.NONE
	# Only the turning itself is reported: the terminal stage costs no health.
	_settings.infection_terminal_health_loss_per_world_sec = 0.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var infection: InfectionState = survival.get_vitals(alice.player_id).infection
	infection.stage = InfectionState.Stage.TERMINAL
	infection.stage_elapsed_world_sec = _settings.infection_stage_duration_world_sec(InfectionState.Stage.TERMINAL, infection.exposure) - 1.0
	assert_true(survival.start_rest(alice.player_id).ok)
	assert_true(survival.start_rest(bob.player_id).ok)
	survival.drain_events()

	# Death: the rest ends before the death is reported.
	world.step_systems(1.5)
	assert_false(survival.is_alive(alice.player_id), "alice turned in her sleep")
	assert_false(survival.is_resting(alice.player_id))
	var types: Array = []
	var ended: Array[Dictionary] = []
	for event: Dictionary in survival.drain_events():
		if str(event.get("player_id", "")) != alice.player_id:
			continue
		types.append(str(event.get("event_type", "")))
		if str(event.get("event_type", "")) == SurvivalService.EVENT_PLAYER_REST_ENDED:
			ended.append(event)
	assert_eq(types, [SurvivalService.EVENT_PLAYER_INFECTION_STAGE_CHANGED, SurvivalService.EVENT_PLAYER_REST_ENDED, SurvivalService.EVENT_PLAYER_DIED])
	assert_eq(ended[0].get("cause", ""), SurvivalService.REST_END_DIED)
	# The next character starts standing.
	world.step_systems(2.0)
	assert_true(survival.is_alive(alice.player_id), "the new character started")
	assert_false(survival.is_resting(alice.player_id))
	assert_true(world.player_movement_multiplier(alice.player_id) > 0.0)

	# Leaving: the rest ends silently (the player is gone for everybody).
	survival.drain_events()
	world.leave(bob.player_id)
	assert_false(survival.is_resting(bob.player_id))
	assert_eq(_events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_REST_ENDED).size(), 0)
	world.join("bob")
	assert_false(survival.is_resting(bob.player_id), "a returning player stands")
	assert_true(world.player_movement_multiplier(bob.player_id) > 0.0)


func test_time_based_damage_runs_during_rest_and_wakes_before_it_kills() -> void:
	# Bleeding keeps running while the player rests. Until P2-T10 it could
	# kill a sleeper; now the sleeper wakes at the configured health and the
	# death, if it comes, comes awake (details: sleep_tuning_test.gd).
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.LACERATION, 20.0)).ok)
	assert_true(survival.start_rest(alice.player_id).ok)
	var health: float = vitals.health
	world.step_systems(600.0)
	assert_true(vitals.health < health, "bleeding continues during rest")
	assert_true(survival.is_resting(alice.player_id), "time-based damage above the wake threshold does not wake")
	survival.drain_events()
	world.step_systems(100.0 * SECONDS_PER_HOUR)
	assert_false(survival.is_alive(alice.player_id), "the player bled out")
	assert_false(survival.is_resting(alice.player_id), "a dead character does not rest")
	var ended: Array[Dictionary] = _events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_REST_ENDED)
	assert_eq(ended.size(), 1)
	assert_eq(ended[0].get("cause", ""), SurvivalService.REST_END_LOW_HEALTH, "the sleeper was woken first: it did not die lying down")


# ------------------------------------------------------------ saving

func test_resting_is_not_saved_but_the_lowered_fatigue_is() -> void:
	_root = "user://test_saves/rest_%d" % Time.get_ticks_usec()
	var config: CompositionConfig = _config()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), config)
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	if world == null:
		return
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.fatigue = 70.0
	var without_rest: Dictionary = survival.to_player_fragment(alice.player_id)
	assert_true(survival.start_rest(alice.player_id).ok)
	assert_eq(survival.to_player_fragment(alice.player_id), without_rest, "resting adds nothing to the saved fragment")
	assert_eq(int(without_rest["schema_version"]), PlayerVitals.SCHEMA_VERSION, "the fragment schema is unchanged")
	world.step_systems(SECONDS_PER_HOUR)
	var fatigue_after: float = vitals.fatigue
	assert_true(fatigue_after < 70.0)
	# Saved while the player is still lying down (e.g. an autosave).
	assert_eq(persistence.save(world), OK)

	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), config).load_or_create(WORLD)
	assert_not_null(restored, "world restored from save")
	if restored == null:
		return
	var restored_survival: SurvivalService = _survival(restored)
	assert_true(_near(restored_survival.get_vitals(alice.player_id).fatigue, fatigue_after), "the lowered fatigue was saved")
	assert_false(restored_survival.is_resting(alice.player_id), "nobody rests after a restart")
	restored.join("alice")
	assert_false(restored_survival.is_resting(alice.player_id))
	assert_true(restored.player_movement_multiplier(alice.player_id) > 0.0, "the returning player can move")
	assert_true(restored_survival.start_rest(alice.player_id).ok, "and lie down again")
