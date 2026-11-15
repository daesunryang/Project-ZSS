extends TestCase
## B2: hunger/thirst/fatigue progression, categories and behaviour penalties
## (docs/02 §3, docs/15 P2-4 / P2-12).

const WORLD: String = "survival_needs_test_world"
const SECONDS_PER_HOUR: float = 3600.0
const EPSILON: float = 0.001

var _settings: SurvivalSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = SurvivalSettings.new()
	_root = "user://test_saves/needs_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.survival = _settings
	return config


func _world() -> ServerWorld:
	return ServerComposition.create_world(WORLD, _config())


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


func test_needs_grow_at_configured_rates() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_eq(vitals.hunger, 0.0)
	survival.step(world, 0.0, SECONDS_PER_HOUR)
	assert_true(_near(vitals.hunger, _settings.need_max / _settings.hunger_hours_to_max), "hunger after 1h: %f" % vitals.hunger)
	assert_true(_near(vitals.thirst, _settings.need_max / _settings.thirst_hours_to_max), "thirst after 1h: %f" % vitals.thirst)
	assert_true(_near(vitals.fatigue, _settings.need_max / _settings.fatigue_hours_to_max), "fatigue after 1h: %f" % vitals.fatigue)
	assert_true(vitals.thirst > vitals.hunger, "thirst outpaces hunger by default")


func test_needs_clamp_at_max() -> void:
	# Isolate B2 need clamping from B3's health damage/respawn cycle.
	_settings.starvation_health_loss_per_world_sec = 0.0
	_settings.dehydration_health_loss_per_world_sec = 0.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	survival.step(world, 0.0, 1000.0 * SECONDS_PER_HOUR)
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_eq(vitals.hunger, _settings.need_max)
	assert_eq(vitals.thirst, _settings.need_max)
	assert_eq(vitals.fatigue, _settings.need_max)
	assert_true(vitals.is_alive(), "disabled B3 damage leaves this B2 clamping test alive")


func test_needs_only_progress_for_online_living_players_and_running_clock() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	world.leave(bob.player_id)
	survival.step(world, 0.0, 0.0)
	assert_eq(survival.get_vitals(alice.player_id).thirst, 0.0, "paused clock (world_delta 0) adds nothing")
	survival.step(world, 0.0, -5.0)
	assert_eq(survival.get_vitals(alice.player_id).thirst, 0.0, "negative delta is ignored")
	survival.step(world, 0.0, SECONDS_PER_HOUR)
	assert_true(survival.get_vitals(alice.player_id).thirst > 0.0)
	assert_eq(survival.get_vitals(bob.player_id).thirst, 0.0, "offline player does not age")
	survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.LACERATION, 500.0))
	var frozen: float = survival.get_vitals(alice.player_id).thirst
	survival.step(world, 0.0, _settings.respawn_delay_world_sec * 0.5)
	assert_eq(survival.get_vitals(alice.player_id).thirst, frozen, "dead player does not age before respawn")


func test_categories_follow_thresholds() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_eq(survival.need_category(alice.player_id, NeedKind.Kind.HUNGER), NeedKind.Category.GOOD)
	vitals.hunger = _settings.need_caution_threshold - 0.01
	assert_eq(survival.need_category(alice.player_id, NeedKind.Kind.HUNGER), NeedKind.Category.GOOD)
	vitals.hunger = _settings.need_caution_threshold
	assert_eq(survival.need_category(alice.player_id, NeedKind.Kind.HUNGER), NeedKind.Category.CAUTION)
	vitals.thirst = _settings.need_danger_threshold
	assert_eq(survival.need_category(alice.player_id, NeedKind.Kind.THIRST), NeedKind.Category.DANGER)
	assert_eq(survival.worst_need_category(alice.player_id), NeedKind.Category.DANGER)
	assert_eq(survival.need_category("player_999999", NeedKind.Kind.HUNGER), NeedKind.Category.GOOD, "unknown player reads as good")
	assert_eq(survival.need_category(alice.player_id, 42 as NeedKind.Kind), NeedKind.Category.GOOD, "unknown need reads as good")
	assert_eq(NeedKind.category_name(NeedKind.Category.CAUTION), "caution")


func test_need_penalties_scale_stamina_regen_and_movement() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_eq(survival.movement_speed_multiplier(alice.player_id), 1.0)

	vitals.stamina = 0.0
	survival.step(world, 0.0, 1.0)
	assert_true(_near(vitals.stamina, _settings.stamina_regen_per_world_sec), "good needs: full regen")

	vitals.fatigue = _settings.need_caution_threshold
	vitals.stamina = 0.0
	survival.step(world, 0.0, 1.0)
	assert_true(_near(vitals.stamina, _settings.stamina_regen_per_world_sec * _settings.caution_stamina_regen_multiplier), "caution regen")
	assert_true(_near(survival.movement_speed_multiplier(alice.player_id), _settings.caution_movement_multiplier))

	vitals.thirst = _settings.need_danger_threshold
	vitals.stamina = 0.0
	survival.step(world, 0.0, 1.0)
	assert_true(_near(vitals.stamina, _settings.stamina_regen_per_world_sec * _settings.danger_stamina_regen_multiplier), "danger regen uses the worst need")
	assert_true(_near(survival.movement_speed_multiplier(alice.player_id), _settings.danger_movement_multiplier))

	survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.LEFT_LEG, Wound.Type.LACERATION, 50.0))
	var combined: float = survival.movement_speed_multiplier(alice.player_id)
	assert_true(combined < _settings.danger_movement_multiplier, "leg wound stacks on top of need penalty")
	assert_true(combined >= _settings.min_movement_multiplier, "never below the movement floor")


func test_needs_survive_save_restart() -> void:
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config())
	var world: ServerWorld = persistence.load_or_create(WORLD)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	survival.step(world, 0.0, 10.0 * SECONDS_PER_HOUR)
	var before: PlayerVitals = survival.get_vitals(alice.player_id)
	var expected: Array[float] = [before.hunger, before.thirst, before.fatigue]
	assert_true(expected[0] > 0.0)
	assert_eq(persistence.save(world), OK)

	var reloaded: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config()).load_or_create(WORLD)
	var restored: PlayerVitals = _survival(reloaded).get_vitals(alice.player_id)
	assert_not_null(restored)
	# The JSON save keeps ~15 significant digits, so compare with a tolerance
	# far tighter than any gameplay-relevant difference.
	assert_true(_near(restored.hunger, expected[0]), "hunger restored: %f vs %f" % [restored.hunger, expected[0]])
	assert_true(_near(restored.thirst, expected[1]), "thirst restored: %f vs %f" % [restored.thirst, expected[1]])
	assert_true(_near(restored.fatigue, expected[2]), "fatigue restored: %f vs %f" % [restored.fatigue, expected[2]])
	assert_true(absf(restored.hunger - expected[0]) < 1e-9, "no visible drift after restart")


func test_progression_is_deterministic_regardless_of_tick_size() -> void:
	var results: Array[float] = []
	for tick_sec: float in [1.0, 60.0, 1800.0]:
		var world: ServerWorld = _world()
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("alice")
		var elapsed: float = 0.0
		while elapsed < 6.0 * SECONDS_PER_HOUR:
			survival.step(world, 0.0, tick_sec)
			elapsed += tick_sec
		results.append(survival.get_vitals(alice.player_id).thirst)
	assert_true(_near(results[0], results[1]) and _near(results[1], results[2]), "tick size does not change the outcome: %s" % str(results))


func test_settings_validation_rejects_bad_need_tuning() -> void:
	assert_true(SurvivalSettings.new().validate().is_empty())
	var bad_hours: SurvivalSettings = SurvivalSettings.new()
	bad_hours.hunger_hours_to_max = 0.0
	assert_false(bad_hours.validate().is_empty())
	var bad_order: SurvivalSettings = SurvivalSettings.new()
	bad_order.need_caution_threshold = 80.0
	bad_order.need_danger_threshold = 50.0
	assert_false(bad_order.validate().is_empty())
	var bad_over: SurvivalSettings = SurvivalSettings.new()
	bad_over.need_danger_threshold = bad_over.need_max + 1.0
	assert_false(bad_over.validate().is_empty())
	var bad_multiplier: SurvivalSettings = SurvivalSettings.new()
	bad_multiplier.danger_stamina_regen_multiplier = 1.5
	assert_false(bad_multiplier.validate().is_empty())
	var inverted: SurvivalSettings = SurvivalSettings.new()
	inverted.caution_movement_multiplier = 0.5
	inverted.danger_movement_multiplier = 0.9
	assert_false(inverted.validate().is_empty(), "danger must not be milder than caution")
