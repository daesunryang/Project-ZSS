extends TestCase
## B4: configured infection stages, effects, treatment, death and persistence.

const WORLD: String = "survival_infection_test_world"
const EPSILON: float = 0.001

var _settings: SurvivalSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = SurvivalSettings.new()
	_root = "user://test_saves/infection_%d" % Time.get_ticks_usec()
	_set_short_stage_durations()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.survival = _settings
	return config


func _world(world_id: String = WORLD) -> ServerWorld:
	return ServerComposition.create_world(world_id, _config())


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _set_short_stage_durations() -> void:
	_settings.infection_latent_hours = 2.0 / SurvivalSettings.SECONDS_PER_HOUR
	_settings.infection_early_hours = 3.0 / SurvivalSettings.SECONDS_PER_HOUR
	_settings.infection_progressing_hours = 4.0 / SurvivalSettings.SECONDS_PER_HOUR
	_settings.infection_severe_hours = 5.0 / SurvivalSettings.SECONDS_PER_HOUR
	_settings.infection_terminal_hours = 6.0 / SurvivalSettings.SECONDS_PER_HOUR
	_settings.infection_chance_bite = 1.0
	_settings.infection_chance_scratch = 1.0
	_settings.infection_chance_blood = 1.0


func _infect(survival: SurvivalService, player_id: String, exposure: InfectionState.Exposure = InfectionState.Exposure.BITE) -> ActionResult:
	return survival.apply_infection_exposure(player_id, exposure, "zombie_1")


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


func _captured_text() -> String:
	return "\n".join(GameLogger.captured_lines())


func test_stages_advance_at_configured_world_time_boundaries_and_are_logged() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	assert_true(_infect(survival, alice.player_id).ok)
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.LATENT)
	world.step_systems(1.999)
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.LATENT)
	world.step_systems(0.001)
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.EARLY)
	world.step_systems(3.0)
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.PROGRESSING)
	world.step_systems(4.0)
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.SEVERE)
	assert_contains(_captured_text(), "event_type=player_infection_stage_changed")
	assert_contains(_captured_text(), "from=early")
	assert_contains(_captured_text(), "to=progressing")


func test_exposure_time_multipliers_scale_each_stage_duration() -> void:
	_settings.infection_bite_time_multiplier = 0.5
	_settings.infection_scratch_time_multiplier = 1.0
	_settings.infection_blood_time_multiplier = 2.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var bite: PlayerState = world.join("bite")
	var scratch: PlayerState = world.join("scratch")
	var blood: PlayerState = world.join("blood")
	_infect(survival, bite.player_id, InfectionState.Exposure.BITE)
	_infect(survival, scratch.player_id, InfectionState.Exposure.SCRATCH)
	_infect(survival, blood.player_id, InfectionState.Exposure.BLOOD)
	world.step_systems(1.0)
	assert_eq(survival.infection_stage(bite.player_id), InfectionState.Stage.EARLY)
	assert_eq(survival.infection_stage(scratch.player_id), InfectionState.Stage.LATENT)
	assert_eq(survival.infection_stage(blood.player_id), InfectionState.Stage.LATENT)
	world.step_systems(1.0)
	assert_eq(survival.infection_stage(scratch.player_id), InfectionState.Stage.EARLY)
	assert_eq(survival.infection_stage(blood.player_id), InfectionState.Stage.LATENT)
	world.step_systems(2.0)
	assert_eq(survival.infection_stage(blood.player_id), InfectionState.Stage.EARLY)


func test_paused_offline_and_dead_players_do_not_advance_infection() -> void:
	_settings.respawn_delay_world_sec = 1000.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	_infect(survival, alice.player_id)
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var before: Dictionary = vitals.infection.to_dict()
	survival.step(world, 10.0, 0.0)
	assert_eq(vitals.infection.to_dict(), before, "paused world time changes nothing")
	world.leave(alice.player_id)
	var bob: PlayerState = world.join("bob")
	world.step_systems(100.0)
	assert_eq(vitals.infection.to_dict(), before, "offline infection does not advance while another player advances the clock")
	world.join("alice")
	survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.BITE, 500.0))
	var dead_infection: Dictionary = vitals.infection.to_dict()
	world.step_systems(100.0)
	assert_eq(vitals.infection.to_dict(), dead_infection, "dead infection does not advance")
	assert_true(survival.has_player(bob.player_id))


func test_stage_effects_multiply_need_stamina_penalty_and_add_health_damage() -> void:
	_settings.health_recovery_per_world_sec = 0.0
	_settings.infection_progressing_stamina_regen_multiplier = 0.5
	_settings.infection_progressing_health_loss_per_world_sec = 0.25
	_settings.stamina_regen_per_world_sec = 4.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	_infect(survival, alice.player_id)
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	world.step_systems(5.0)
	assert_eq(vitals.infection.stage, InfectionState.Stage.PROGRESSING)
	vitals.stamina = 0.0
	vitals.hunger = _settings.need_caution_threshold
	var before_health: float = vitals.health
	world.step_systems(1.0)
	var expected_stamina: float = _settings.stamina_regen_per_world_sec * _settings.caution_stamina_regen_multiplier * _settings.infection_progressing_stamina_regen_multiplier
	assert_true(_near(vitals.stamina, expected_stamina), "need and infection stamina multipliers compose multiplicatively")
	assert_true(_near(vitals.health, before_health - _settings.infection_progressing_health_loss_per_world_sec), "infection health damage is additive")


func test_zombified_stage_causes_infection_death_then_respawn_clears_it() -> void:
	_settings.health_recovery_per_world_sec = 0.0
	_settings.respawn_delay_world_sec = 10.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	_infect(survival, alice.player_id)
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	world.step_systems(20.0)
	assert_false(vitals.is_alive())
	assert_eq(vitals.infection.stage, InfectionState.Stage.ZOMBIFIED)
	assert_true(_near(vitals.died_at_world_time, 20.0))
	assert_contains(_captured_text(), "cause=infection")
	world.step_systems(10.0)
	assert_true(vitals.is_alive())
	assert_eq(vitals.infection.stage, InfectionState.Stage.NONE)


func test_treatment_seam_enforces_configured_max_stage_and_returns_contract_events() -> void:
	_settings.infection_treatment_max_stage = InfectionState.Stage.EARLY
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	assert_eq(survival.apply_infection_treatment(alice.player_id, "medicine_1").reason, SurvivalService.REASON_NOT_INFECTED)
	_infect(survival, alice.player_id)
	var cured: ActionResult = survival.apply_infection_treatment(alice.player_id, "medicine_1")
	assert_true(cured.ok, cured.reason)
	assert_eq(cured.event["event_type"], SurvivalService.EVENT_PLAYER_INFECTION_CURED)
	assert_eq(cured.event["from"], InfectionState.STAGE_NAMES[InfectionState.Stage.LATENT])
	assert_eq(cured.event["source_id"], "medicine_1")
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.NONE)
	assert_contains(_captured_text(), "event_type=player_infection_cured")
	_infect(survival, alice.player_id)
	world.step_systems(5.0)
	assert_eq(survival.apply_infection_treatment(alice.player_id, "medicine_2").reason, SurvivalService.REASON_TOO_LATE)
	assert_eq(survival.apply_infection_treatment("player_999999", "medicine_2").reason, SurvivalService.REASON_UNKNOWN_PLAYER)
	assert_eq(survival.infection_stage("player_999999"), InfectionState.Stage.NONE)


func test_stage_and_remaining_time_survive_save_restart_and_old_schema_defaults() -> void:
	_settings.infection_latent_hours = 5.0 / SurvivalSettings.SECONDS_PER_HOUR
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config())
	var world: ServerWorld = persistence.load_or_create(WORLD)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	_infect(survival, alice.player_id)
	world.step_systems(2.0)
	var expected_elapsed: float = survival.get_vitals(alice.player_id).infection.stage_elapsed_world_sec
	assert_eq(persistence.save(world), OK)
	var reloaded: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config()).load_or_create(WORLD)
	var restored: SurvivalService = _survival(reloaded)
	var restored_vitals: PlayerVitals = restored.get_vitals(alice.player_id)
	assert_eq(restored_vitals.infection.stage, InfectionState.Stage.LATENT)
	assert_true(_near(restored_vitals.infection.stage_elapsed_world_sec, expected_elapsed))
	reloaded.join("alice")
	reloaded.step_systems(2.999)
	assert_eq(restored.infection_stage(alice.player_id), InfectionState.Stage.LATENT)
	reloaded.step_systems(0.001)
	assert_eq(restored.infection_stage(alice.player_id), InfectionState.Stage.EARLY)

	var legacy: Dictionary = restored.to_player_fragment(alice.player_id).duplicate(true)
	legacy["schema_version"] = 2
	(legacy["infection"] as Dictionary).erase("stage_elapsed_world_sec")
	var parsed: Array = PlayerVitals.from_dict(legacy, _settings)
	assert_true((parsed[1] as PackedStringArray).is_empty(), ", ".join(parsed[1]))
	assert_eq((parsed[0] as PlayerVitals).infection.stage_elapsed_world_sec, 0.0)
	var invalid: Dictionary = restored.to_player_fragment(alice.player_id).duplicate(true)
	(invalid["infection"] as Dictionary)["stage_elapsed_world_sec"] = -1.0
	assert_false((PlayerVitals.from_dict(invalid, _settings)[1] as PackedStringArray).is_empty())


func test_infection_progression_and_effects_are_independent_of_tick_size() -> void:
	_settings.max_health = 1000.0
	_settings.health_recovery_per_world_sec = 0.0
	_settings.infection_progressing_health_loss_per_world_sec = 0.1
	_settings.infection_severe_health_loss_per_world_sec = 0.2
	_settings.infection_terminal_health_loss_per_world_sec = 0.3
	_settings.respawn_delay_world_sec = 1000.0
	var results: Array[Dictionary] = []
	for tick_sec: float in [0.1, 1.0, 20.0]:
		var world: ServerWorld = _world("%s_%s" % [WORLD, str(tick_sec)])
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("alice_%s" % str(tick_sec))
		_infect(survival, alice.player_id)
		var elapsed: float = 0.0
		while elapsed < 20.0 - EPSILON:
			var step_size: float = minf(tick_sec, 20.0 - elapsed)
			world.step_systems(step_size)
			elapsed += step_size
		var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
		results.append({"health": vitals.health, "stage": vitals.infection.stage, "died_at": vitals.died_at_world_time})
	assert_true(_near(float(results[0]["health"]), float(results[1]["health"])) and _near(float(results[1]["health"]), float(results[2]["health"])), str(results))
	assert_eq(results[0]["stage"], results[1]["stage"])
	assert_eq(results[1]["stage"], results[2]["stage"])
	assert_true(_near(float(results[0]["died_at"]), float(results[1]["died_at"])) and _near(float(results[1]["died_at"]), float(results[2]["died_at"])), str(results))


func test_settings_validation_rejects_invalid_infection_tuning() -> void:
	assert_true(SurvivalSettings.new().validate().is_empty())
	var bad_duration: SurvivalSettings = SurvivalSettings.new()
	bad_duration.infection_terminal_hours = 0.0
	assert_false(bad_duration.validate().is_empty())
	var bad_time_multiplier: SurvivalSettings = SurvivalSettings.new()
	bad_time_multiplier.infection_blood_time_multiplier = 0.0
	assert_false(bad_time_multiplier.validate().is_empty())
	var bad_effect: SurvivalSettings = SurvivalSettings.new()
	bad_effect.infection_severe_stamina_regen_multiplier = 1.1
	assert_false(bad_effect.validate().is_empty())
	var bad_treatment: SurvivalSettings = SurvivalSettings.new()
	bad_treatment.infection_treatment_max_stage = InfectionState.Stage.ZOMBIFIED
	assert_false(bad_treatment.validate().is_empty())
