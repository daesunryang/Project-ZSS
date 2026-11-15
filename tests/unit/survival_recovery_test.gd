extends TestCase
## B3: bleeding, natural recovery, starvation/dehydration damage and
## server-authoritative death/respawn (docs/02 §2-§3, docs/15 §6).

const WORLD: String = "survival_recovery_test_world"
const EPSILON: float = 0.001

var _settings: SurvivalSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = SurvivalSettings.new()
	_root = "user://test_saves/recovery_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.survival = _settings
	# These tests state calendar rules in world seconds. A 1x clock makes
	# step_systems(x) advance exactly x world seconds; the 24x default and the
	# action-time rules are covered by time_axes_test (P2-T1).
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = 1.0
	return config


func _world() -> ServerWorld:
	return ServerComposition.create_world(WORLD, _config())


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


func _captured_text() -> String:
	return "\n".join(GameLogger.captured_lines())


func test_wound_bleeding_is_tuned_saved_state_and_can_be_stopped() -> void:
	_settings.bleeding_min_severity = 0.25
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var small: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.LEFT_ARM, Wound.Type.LACERATION, 10.0))
	assert_false(bool((small.event["wound"] as Dictionary)["is_bleeding"]), "severity below the configured threshold does not bleed")
	var hit: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.LACERATION, 25.0))
	var wound_id: String = str((hit.event["wound"] as Dictionary)["wound_id"])
	assert_true(bool((hit.event["wound"] as Dictionary)["is_bleeding"]))
	var stopped: ActionResult = survival.stop_bleeding(alice.player_id, wound_id)
	assert_true(stopped.ok, stopped.reason)
	assert_eq(stopped.event["event_type"], SurvivalService.EVENT_PLAYER_BLEEDING_STOPPED)
	assert_false(survival.get_vitals(alice.player_id).injuries[1].is_bleeding)
	assert_eq(survival.stop_bleeding(alice.player_id, wound_id).reason, SurvivalService.REASON_NOT_BLEEDING)
	assert_eq(survival.stop_bleeding(alice.player_id, "wound_999999").reason, SurvivalService.REASON_UNKNOWN_WOUND)
	assert_eq(survival.stop_bleeding("player_999999", wound_id).reason, SurvivalService.REASON_UNKNOWN_PLAYER)


func test_bleeding_damages_health_and_blocks_natural_recovery() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var hit: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.LACERATION, 25.0))
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var wound_id: String = str((hit.event["wound"] as Dictionary)["wound_id"])
	var health_after_hit: float = vitals.health
	var severity: float = vitals.injuries[0].severity
	world.step_systems(10.0)
	var expected_bleed: float = _settings.bleeding_health_loss_per_severity_per_world_sec * _settings.bleeding_type_multiplier(Wound.Type.LACERATION) * severity * 10.0
	assert_true(_near(vitals.health, health_after_hit - expected_bleed), "bleeding uses world time and configured type/severity rate")
	assert_eq(vitals.injuries[0].severity, severity, "bleeding wound does not naturally heal")
	survival.stop_bleeding(alice.player_id, wound_id)
	var before_recovery: float = vitals.health
	world.step_systems(10.0)
	assert_true(_near(vitals.health, minf(before_recovery + _settings.health_recovery_per_world_sec * 10.0, _settings.max_health)))
	assert_true(vitals.injuries[0].severity < severity, "stopped wound heals while all needs are good")


func test_natural_recovery_requires_all_good_needs_and_removes_healed_wounds() -> void:
	_settings.wound_recovery_per_world_sec = 0.1
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	survival.apply_damage(alice.player_id, DamageInput.create("fall", BodyPart.Part.LEFT_LEG, Wound.Type.BRUISE, 5.0))
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = _settings.need_caution_threshold
	var frozen_health: float = vitals.health
	var frozen_severity: float = vitals.injuries[0].severity
	world.step_systems(1.0)
	assert_eq(vitals.health, frozen_health)
	assert_eq(vitals.injuries[0].severity, frozen_severity)
	vitals.hunger = 0.0
	world.step_systems(1.0)
	assert_true(vitals.health > frozen_health)
	assert_eq(vitals.injuries.size(), 0, "severity zero wounds are removed")


func test_starvation_and_dehydration_use_dedicated_damage_path_with_cause_log() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = _settings.need_max
	vitals.thirst = _settings.need_max
	var before: float = vitals.health
	world.step_systems(10.0)
	var expected: float = before - (_settings.starvation_health_loss_per_world_sec + _settings.dehydration_health_loss_per_world_sec) * 10.0
	assert_true(_near(vitals.health, expected))
	assert_eq(vitals.injuries.size(), 0, "survival damage does not fabricate a combat wound")
	assert_contains(_captured_text(), "cause=starvation_dehydration")


func test_paused_and_offline_players_have_no_time_based_change() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.LACERATION, 25.0))
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var before: Dictionary = vitals.to_dict()
	survival.step(world, 0.0, 0.0)
	assert_eq(vitals.to_dict(), before, "paused world_delta changes nothing")
	world.leave(alice.player_id)
	world.step_systems(1000.0)
	assert_eq(vitals.to_dict(), before, "offline state does not bleed, heal, age or respawn")


func test_death_records_time_and_respawn_resets_state_position_and_input() -> void:
	_settings.respawn_delay_sec = 10.0
	_settings.respawn_hunger = 1.0
	_settings.respawn_thirst = 2.0
	_settings.respawn_fatigue = 3.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var inventory_id: String = alice.inventory_id
	alice.position = Vector3(12.0, 0.0, -8.0)
	assert_eq(world.set_move_input(alice.player_id, 1, Vector2.RIGHT, 0.5, 0), "")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 50.0
	vitals.thirst = 60.0
	vitals.fatigue = 70.0
	vitals.infection.stage = InfectionState.Stage.LATENT
	var lethal: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.BITE, 500.0))
	assert_eq(lethal.event["event_type"], SurvivalService.EVENT_PLAYER_WOUNDED, "B1 contract: lethal hits stay player_wounded with died=true")
	assert_true(lethal.event["died"])
	assert_eq(vitals.died_at_world_time, 0.0)
	world.step_systems(9.0)
	assert_false(vitals.is_alive())
	world.step_systems(1.0)
	assert_true(vitals.is_alive())
	assert_eq(vitals.health, _settings.max_health)
	assert_eq(vitals.stamina, _settings.max_stamina)
	assert_eq(vitals.hunger, _settings.respawn_hunger)
	assert_eq(vitals.thirst, _settings.respawn_thirst)
	assert_eq(vitals.fatigue, _settings.respawn_fatigue)
	assert_eq(vitals.died_at_world_time, PlayerVitals.NOT_DEAD_TIME)
	assert_eq(vitals.injuries.size(), 0)
	assert_eq(vitals.infection.stage, InfectionState.Stage.NONE)
	assert_eq(alice.position, world.clamp_to_world(world.gameplay.player_spawn_position))
	assert_eq(alice.inventory_id, inventory_id, "inventory is retained")
	var spawn: Vector3 = alice.position
	world.step_movement(1.0, 0, 1000)
	assert_eq(alice.position, spawn, "pre-death movement input was cleared")
	assert_contains(_captured_text(), "event_type=player_respawned")


func test_health_and_wound_progression_are_independent_of_tick_size() -> void:
	_settings.max_health = 1000.0
	_settings.wound_recovery_per_world_sec = 0.0001
	var results: Array[Array] = []
	for tick_sec: float in [0.1, 1.0, 10.0]:
		var world: ServerWorld = _world()
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("alice_%s" % str(tick_sec))
		var hit: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create("fall", BodyPart.Part.LEFT_ARM, Wound.Type.BRUISE, 25.0))
		assert_true(hit.ok)
		var elapsed: float = 0.0
		while elapsed < 100.0 - EPSILON:
			world.step_systems(tick_sec)
			elapsed += tick_sec
		var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
		results.append([vitals.health, vitals.injuries[0].severity])
	assert_true(_near(float(results[0][0]), float(results[1][0])) and _near(float(results[1][0]), float(results[2][0])), "health is tick-size independent: %s" % str(results))
	assert_true(_near(float(results[0][1]), float(results[1][1])) and _near(float(results[1][1]), float(results[2][1])), "wound healing is tick-size independent: %s" % str(results))


func test_survival_death_and_respawn_boundaries_are_independent_of_tick_size() -> void:
	_settings.starvation_health_loss_per_world_sec = 0.05
	_settings.dehydration_health_loss_per_world_sec = 0.05
	_settings.respawn_delay_sec = 10.0
	var results: Array[Array] = []
	for tick_sec: float in [0.1, 1.0, 25.0]:
		var world: ServerWorld = _world()
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("boundary_%s" % str(tick_sec))
		var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
		vitals.health = 1.0
		vitals.hunger = _settings.need_max
		vitals.thirst = _settings.need_max
		var elapsed: float = 0.0
		while elapsed < 25.0 - EPSILON:
			world.step_systems(tick_sec)
			elapsed += tick_sec
		results.append([vitals.health, vitals.hunger, vitals.thirst, vitals.died_at_world_time])
		assert_true(vitals.is_alive(), "player respawned in every tick schedule")
	assert_true(_near(float(results[0][0]), float(results[1][0])) and _near(float(results[1][0]), float(results[2][0])), "health/death/respawn result: %s" % str(results))
	assert_true(_near(float(results[0][1]), float(results[1][1])) and _near(float(results[1][1]), float(results[2][1])), "post-respawn hunger result: %s" % str(results))
	assert_true(_near(float(results[0][2]), float(results[1][2])) and _near(float(results[1][2]), float(results[2][2])), "post-respawn thirst result: %s" % str(results))
	assert_eq(results[0][3], PlayerVitals.NOT_DEAD_TIME)
	assert_eq(results[1][3], PlayerVitals.NOT_DEAD_TIME)
	assert_eq(results[2][3], PlayerVitals.NOT_DEAD_TIME)


func test_b3_state_survives_save_restart_and_v1_defaults_are_supported() -> void:
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config())
	var world: ServerWorld = persistence.load_or_create(WORLD)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var lethal: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.LACERATION, 500.0))
	assert_true(bool((lethal.event["wound"] as Dictionary)["is_bleeding"]))
	var expected: Dictionary = survival.to_player_fragment(alice.player_id)
	assert_eq(persistence.save(world), OK)
	var reloaded: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config()).load_or_create(WORLD)
	assert_eq(_survival(reloaded).to_player_fragment(alice.player_id), expected)

	var v1: Dictionary = expected.duplicate(true)
	v1["schema_version"] = 1
	v1.erase("died_at_world_time")
	for wound: Dictionary in (v1["injuries"] as Array):
		wound.erase("is_bleeding")
	var parsed: Array = PlayerVitals.from_dict(v1, _settings)
	assert_true((parsed[1] as PackedStringArray).is_empty(), ", ".join(parsed[1]))
	var migrated: PlayerVitals = parsed[0]
	assert_eq(migrated.died_at_world_time, PlayerVitals.NOT_DEAD_TIME)
	assert_false(migrated.injuries[0].is_bleeding)
	var invalid: Dictionary = expected.duplicate(true)
	invalid["died_at_world_time"] = -2.0
	assert_false((PlayerVitals.from_dict(invalid, _settings)[1] as PackedStringArray).is_empty())


func test_settings_validation_rejects_invalid_b3_tuning() -> void:
	assert_true(SurvivalSettings.new().validate().is_empty())
	var bad_threshold: SurvivalSettings = SurvivalSettings.new()
	bad_threshold.bleeding_min_severity = 1.1
	assert_false(bad_threshold.validate().is_empty())
	var bad_rate: SurvivalSettings = SurvivalSettings.new()
	bad_rate.health_recovery_per_world_sec = -1.0
	assert_false(bad_rate.validate().is_empty())
	var bad_need_reset: SurvivalSettings = SurvivalSettings.new()
	bad_need_reset.respawn_thirst = bad_need_reset.need_max + 1.0
	assert_false(bad_need_reset.validate().is_empty())
