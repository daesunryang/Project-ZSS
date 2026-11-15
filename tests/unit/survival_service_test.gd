extends TestCase
## B1: SurvivalService contract — damage/wounds/death, stamina, multipliers,
## seeded infection exposure, persistence of the player fragment.

const WORLD: String = "survival_test_world"

var _settings: SurvivalSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = SurvivalSettings.new()
	_root = "user://test_saves/survival_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _world() -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.survival = _settings
	return ServerComposition.create_world(WORLD, config)


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func test_composition_registers_survival_and_online_creates_vitals() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	assert_not_null(survival)
	var alice: PlayerState = world.join("alice")
	assert_true(survival.has_player(alice.player_id))
	assert_true(survival.is_alive(alice.player_id))
	assert_eq(survival.get_vitals(alice.player_id).health, _settings.max_health)
	assert_eq(survival.handling_multiplier(alice.player_id), 1.0)
	assert_false(survival.is_alive("player_999999"))


func test_apply_damage_records_wound_and_kills_at_zero() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var hit: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create("zombie_000009", BodyPart.Part.LEFT_ARM, Wound.Type.BITE, 25.0))
	assert_true(hit.ok, hit.reason)
	assert_eq(hit.event["event_type"], SurvivalService.EVENT_PLAYER_WOUNDED)
	assert_eq(hit.event["health_after"], _settings.max_health - 25.0)
	assert_false(hit.event["died"])
	var wound: Dictionary = hit.event["wound"]
	assert_eq(wound["body_part"], "left_arm")
	assert_eq(wound["wound_type"], "bite")
	assert_eq(wound["severity"], 25.0 / _settings.wound_severity_reference_damage)
	assert_eq(survival.get_vitals(alice.player_id).injuries.size(), 1)
	var lethal: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create("zombie_000009", BodyPart.Part.TORSO, Wound.Type.LACERATION, 500.0))
	assert_true(lethal.event["died"])
	assert_eq(survival.get_vitals(alice.player_id).health, 0.0)
	assert_false(survival.is_alive(alice.player_id))
	assert_eq(survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.HEAD, Wound.Type.BRUISE, 1.0)).reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_false(survival.try_spend_stamina(alice.player_id, 1.0), "dead players cannot act")
	assert_eq(survival.movement_speed_multiplier(alice.player_id), 0.0)


func test_invalid_damage_is_rejected_without_change() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var before: Dictionary = survival.to_player_fragment(alice.player_id)
	assert_eq(survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.HEAD, Wound.Type.BRUISE, -5.0)).reason, DamageInput.REASON_BAD_AMOUNT)
	assert_eq(survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.HEAD, Wound.Type.BRUISE, NAN)).reason, DamageInput.REASON_BAD_AMOUNT)
	assert_eq(survival.apply_damage(alice.player_id, DamageInput.create("z", 42 as BodyPart.Part, Wound.Type.BRUISE, 5.0)).reason, DamageInput.REASON_BAD_BODY_PART)
	assert_eq(survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.HEAD, 9 as Wound.Type, 5.0)).reason, DamageInput.REASON_BAD_WOUND_TYPE)
	assert_eq(survival.apply_damage(alice.player_id, DamageInput.create("", BodyPart.Part.HEAD, Wound.Type.BRUISE, 5.0)).reason, DamageInput.REASON_BAD_SOURCE)
	assert_eq(survival.apply_damage("player_999999", DamageInput.create("z", BodyPart.Part.HEAD, Wound.Type.BRUISE, 5.0)).reason, SurvivalService.REASON_UNKNOWN_PLAYER)
	assert_eq(survival.to_player_fragment(alice.player_id), before)


func test_stamina_spend_and_regen_follow_action_clock() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	assert_true(survival.try_spend_stamina(alice.player_id, 40.0))
	assert_false(survival.try_spend_stamina(alice.player_id, 1000.0), "not enough stamina")
	assert_false(survival.try_spend_stamina(alice.player_id, -1.0), "negative refused")
	assert_eq(survival.get_vitals(alice.player_id).stamina, _settings.max_stamina - 40.0)
	world.step_systems(2.0)
	# Regeneration is per real second: the calendar scale (24 by default) does
	# not speed it up (P2-T1).
	assert_true(world.clock.time_scale > 1.0, "default clock is accelerated")
	var expected: float = _settings.max_stamina - 40.0 + _settings.stamina_regen_per_sec * 2.0
	assert_true(expected < _settings.max_stamina, "not capped, so the rate is visible")
	assert_true(is_equal_approx(survival.get_vitals(alice.player_id).stamina, expected), "stamina %f, expected %f" % [survival.get_vitals(alice.player_id).stamina, expected])
	world.leave(alice.player_id)
	var offline_stamina: float = survival.get_vitals(alice.player_id).stamina
	world.step_systems(10.0)
	assert_eq(survival.get_vitals(alice.player_id).stamina, offline_stamina, "no regen while paused/offline")


func test_wound_multipliers_by_body_part() -> void:
	_settings.max_health = 1000.0  # keep the player alive while stacking wounds
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var severity_half: float = _settings.wound_severity_reference_damage * 0.5
	survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.RIGHT_HAND, Wound.Type.LACERATION, severity_half))
	assert_eq(survival.handling_multiplier(alice.player_id), 1.0 - _settings.handling_penalty_per_severity * 0.5)
	assert_eq(survival.movement_speed_multiplier(alice.player_id), 1.0, "hand wound does not slow walking")
	survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.LEFT_LEG, Wound.Type.FRACTURE, severity_half))
	survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.RIGHT_FOOT, Wound.Type.FRACTURE, severity_half))
	survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.LEFT_FOOT, Wound.Type.FRACTURE, severity_half))
	assert_eq(survival.movement_speed_multiplier(alice.player_id), _settings.min_movement_multiplier, "clamped to minimum")


func test_infection_exposure_is_seeded_and_reproducible() -> void:
	_settings.infection_chance_bite = 1.0
	_settings.infection_chance_scratch = 0.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var scratch: ActionResult = survival.apply_infection_exposure(alice.player_id, InfectionState.Exposure.SCRATCH, "zombie_000001")
	assert_eq(scratch.event["event_type"], SurvivalService.EVENT_INFECTION_RESISTED)
	var bite: ActionResult = survival.apply_infection_exposure(alice.player_id, InfectionState.Exposure.BITE, "zombie_000001")
	assert_eq(bite.event["event_type"], SurvivalService.EVENT_PLAYER_INFECTED)
	var infection: InfectionState = survival.get_vitals(alice.player_id).infection
	assert_eq(infection.stage, InfectionState.Stage.LATENT)
	assert_eq(infection.source_id, "zombie_000001")
	assert_eq(survival.apply_infection_exposure(alice.player_id, InfectionState.Exposure.BITE, "z").reason, SurvivalService.REASON_ALREADY_INFECTED)
	assert_eq(survival.apply_infection_exposure(alice.player_id, 7 as InfectionState.Exposure, "z").reason, SurvivalService.REASON_BAD_EXPOSURE)

	# Same seed + same calls -> same outcomes (probabilistic chance).
	_settings.infection_chance_scratch = 0.5
	var outcomes: Array[PackedStringArray] = []
	for run: int in range(2):
		var w: ServerWorld = _world()
		var s: SurvivalService = _survival(w)
		var players: PackedStringArray = []
		var results: PackedStringArray = []
		for key: String in ["p1", "p2", "p3", "p4", "p5", "p6"]:
			var player: PlayerState = w.join(key)
			results.append(str(s.apply_infection_exposure(player.player_id, InfectionState.Exposure.SCRATCH, "z").event["event_type"]))
		outcomes.append(results)
	assert_eq(outcomes[0], outcomes[1])


func test_vitals_survive_save_restart_and_rng_continues() -> void:
	_settings.infection_chance_scratch = 0.5
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config())
	var world: ServerWorld = persistence.load_or_create(WORLD)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	survival.apply_damage(alice.player_id, DamageInput.create("zombie_000003", BodyPart.Part.HEAD, Wound.Type.SCRATCH, 10.0))
	survival.apply_infection_exposure(alice.player_id, InfectionState.Exposure.SCRATCH, "zombie_000003")
	assert_eq(persistence.save(world), OK)
	var expected_next: float = survival.get_vitals(alice.player_id).rng.randf()

	var reloaded: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config()).load_or_create(WORLD)
	assert_not_null(reloaded)
	var restored: PlayerVitals = _survival(reloaded).get_vitals(alice.player_id)
	assert_not_null(restored, "vitals restored from players/<id>.json")
	assert_eq(restored.health, _settings.max_health - 10.0)
	assert_eq(restored.injuries.size(), 1)
	assert_eq(restored.injuries[0].wound_type, Wound.Type.SCRATCH)
	assert_eq(restored.infection.stage, survival.get_vitals(alice.player_id).infection.stage)
	assert_eq(restored.rng.randf(), expected_next, "RNG state continues exactly after restart")
	assert_ne(reloaded.ids.next_id("wound"), restored.injuries[0].wound_id, "wound ids are not reused")


func test_corrupt_vitals_fragment_fails_restore() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var documents: Dictionary = world.to_documents()
	var player_doc: Dictionary = (documents["players"] as Dictionary)[alice.player_id]
	var fragment: Dictionary = (player_doc[ServerWorld.KEY_SYSTEMS] as Dictionary)[SurvivalService.SYSTEM_ID]
	fragment["health"] = 1e9
	fragment["rng_state"] = "not-a-number"
	var restored: ServerWorld = _world()
	var errors: PackedStringArray = restored.restore_documents(documents["world_state"], documents["players"])
	assert_eq(errors.size(), 2, ", ".join(errors))


func test_event_queue_preserves_order_drops_oldest_and_counts_overflow() -> void:
	_settings.max_pending_events = 2
	_settings.max_health = 1000.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	for source: String in ["first", "second", "third"]:
		assert_true(survival.apply_damage(alice.player_id, DamageInput.create(source, BodyPart.Part.TORSO, Wound.Type.BRUISE, 1.0)).ok)
	var events: Array[Dictionary] = survival.drain_events()
	assert_eq(events.size(), 2)
	assert_eq(events[0]["source_id"], "second", "oldest overflow entry was discarded")
	assert_eq(events[1]["source_id"], "third", "remaining entries preserve occurrence order")
	assert_eq(survival.dropped_event_count, 1)
	assert_true(survival.drain_events().is_empty(), "drain clears the queue")


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.survival = _settings
	return config
