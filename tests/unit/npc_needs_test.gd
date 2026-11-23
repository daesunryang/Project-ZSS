extends TestCase
## P4-2: NPC hunger, thirst and fatigue (docs/09 §17.2). Needs use
## calendar time, integrate to an absolute baseline so evaluation cadence does
## not change the result, expose the next category boundary, and persist as the
## single NpcComponent slot `needs`.

const WORLD: String = "npc_needs_test_world"
const NPC_DEFINITION: String = "t42_resident"
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const HOME_CELL: String = "cell_0_0"
const EPSILON: float = 0.000001

var _settings: NpcNeedSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = NpcNeedSettings.new()


func after_each() -> void:
	GameLogger.set_capture(false)


func _definition() -> NpcDefinition:
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = NPC_DEFINITION
	definition.display_name = "욕구 테스트 주민"
	return definition


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached Resources: replace, never edit.
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = 1.0
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.starvation_health_loss_per_world_sec = 0.0
	config.survival.dehydration_health_loss_per_world_sec = 0.0
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 10.0
	config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	config.world_cells.active_radius_cells = 0
	config.world_cells.preload_radius_cells = 1
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.preload_lookahead_sec = 0.0
	config.npc = NpcSettings.new()
	config.npc_definitions = NpcCatalog.new()
	config.npc_definitions.add(_definition())
	config.npc_needs = _settings
	return config


func _world() -> ServerWorld:
	return ServerComposition.create_world(WORLD, _config())


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _spawn(world: ServerWorld) -> String:
	world.join("alice")
	world.step_systems(0.1)
	var result: ActionResult = _npcs(world).spawn_npc(world, NPC_DEFINITION, SPAWN)
	assert_true(result.ok, result.reason)
	return str(result.event.get(NpcService.KEY_NPC_ID, ""))


func _needs(world: ServerWorld, npc_id: String) -> NpcNeeds:
	return _npcs(world).get_npc(npc_id).component(NpcNeeds.COMPONENT_ID) as NpcNeeds


func _fresh_needs(settings: NpcNeedSettings = null) -> NpcNeeds:
	var needs: NpcNeeds = NpcNeeds.new(settings if settings != null else _settings)
	var npc: NpcState = NpcState.new()
	npc.npc_id = "npc_000001"
	npc.definition_id = NPC_DEFINITION
	needs.on_created(npc, _definition(), WorldClock.new(1.0, false))
	return needs


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value, "", false, true)) as Dictionary


func test_shipped_settings_define_only_three_changing_needs() -> void:
	var shipped: NpcNeedSettings = NpcNeedSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_eq(shipped.defined_kinds, NpcNeedKind.DEFINED_KINDS)
	assert_eq(NpcNeedKind.SIMULATED_KINDS, PackedStringArray(["hunger", "thirst", "fatigue"]))
	for kind: String in NpcNeedKind.ZERO_RATE_KINDS:
		for activity: String in NpcNeedKind.ACTIVITIES:
			assert_eq(shipped.rate_per_world_sec(kind, activity), 0.0, "%s exists as definition data but does not change" % kind)
	assert_true(shipped.rate_per_world_sec(NpcNeedKind.FATIGUE, NpcNeedKind.RESTING) < 0.0)
	# The night sleep (F-6) recovers more slowly than a nap, so it lasts
	# longer (user choice 2026-11-23, "3").
	assert_true(shipped.rate_per_world_sec(NpcNeedKind.FATIGUE, NpcNeedKind.SLEEPING) < 0.0)
	assert_true(shipped.sleep_fatigue_hours_from_max > shipped.rest_fatigue_hours_from_max, "a night sleep is slower than a nap")
	assert_eq(shipped.rate_per_world_sec(NpcNeedKind.HUNGER, NpcNeedKind.SLEEPING), shipped.rate_per_world_sec(NpcNeedKind.HUNGER, NpcNeedKind.IDLE), "hunger keeps its idle rate in sleep")
	assert_true(shipped.rate_per_world_sec(NpcNeedKind.FATIGUE, NpcNeedKind.WORKING) > shipped.rate_per_world_sec(NpcNeedKind.FATIGUE, NpcNeedKind.IDLE))
	assert_eq(shipped.default_personality_modifier, 1.0)
	assert_eq(shipped.default_ability_modifier, 1.0)

	var broken: NpcNeedSettings = NpcNeedSettings.new()
	broken.caution_threshold = broken.danger_threshold
	broken.defined_kinds = PackedStringArray([NpcNeedKind.HUNGER, NpcNeedKind.HUNGER])
	broken.default_personality_modifier = 0.0
	assert_true(broken.validate().size() >= 3)


func test_component_is_registered_with_initial_values_and_calendar_baseline() -> void:
	var world: ServerWorld = _world()
	var npc_id: String = _spawn(world)
	var needs: NpcNeeds = _needs(world, npc_id)
	assert_not_null(needs, "ServerComposition registers the needs component")
	if needs == null:
		return
	assert_eq(needs.component_id(), NpcNeeds.COMPONENT_ID)
	assert_eq(needs.activity(), NpcNeedKind.IDLE)
	assert_true(_near(needs.last_updated_world_time(), world.clock.world_time_sec))
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		assert_eq(needs.value(kind), 0.0)
		assert_eq(needs.category(kind), NpcNeedKind.Category.NORMAL)
	assert_eq(needs.personality_modifier(), 1.0)
	assert_eq(needs.ability_modifier(), 1.0)
	assert_true(needs.has_definition(NpcNeedKind.WARMTH))
	assert_false(needs.is_simulated(NpcNeedKind.WARMTH))


func test_interval_integration_is_identical_at_one_or_ten_second_cadence() -> void:
	var every_second: NpcNeeds = _fresh_needs()
	var every_ten_seconds: NpcNeeds = _fresh_needs()
	for second: int in range(1, 3601):
		every_second.advance_to(float(second))
	for second: int in range(10, 3601, 10):
		every_ten_seconds.advance_to(float(second))
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		assert_true(_near(every_second.value(kind), every_ten_seconds.value(kind)), "%s: 1s=%f, 10s=%f" % [kind, every_second.value(kind), every_ten_seconds.value(kind)])
	assert_eq(every_second.to_document(), every_ten_seconds.to_document(), "the saved baseline and values are cadence-independent")


func test_rest_lowers_fatigue_and_work_accelerates_it() -> void:
	_settings.fatigue_hours_to_max = 10.0
	_settings.rest_fatigue_hours_from_max = 4.0
	_settings.working_fatigue_rate_multiplier = 2.0
	var resting: NpcNeeds = _fresh_needs()
	resting.advance_to(8.0 * NpcNeedSettings.SECONDS_PER_HOUR)
	assert_true(_near(resting.value(NpcNeedKind.FATIGUE), 80.0))
	assert_true(resting.set_activity(NpcNeedKind.RESTING, 8.0 * NpcNeedSettings.SECONDS_PER_HOUR).ok)
	resting.advance_to(9.0 * NpcNeedSettings.SECONDS_PER_HOUR)
	assert_true(_near(resting.value(NpcNeedKind.FATIGUE), 55.0), "one rest hour removes 25 fatigue")
	assert_true(resting.value(NpcNeedKind.HUNGER) > 0.0 and resting.value(NpcNeedKind.THIRST) > 0.0, "hunger and thirst still rise while resting")
	_settings.sleep_fatigue_hours_from_max = 10.0
	assert_true(resting.set_activity(NpcNeedKind.SLEEPING, 9.0 * NpcNeedSettings.SECONDS_PER_HOUR).ok)
	resting.advance_to(10.0 * NpcNeedSettings.SECONDS_PER_HOUR)
	assert_true(_near(resting.value(NpcNeedKind.FATIGUE), 45.0), "one hour of night sleep removes 10 fatigue: %f" % resting.value(NpcNeedKind.FATIGUE))

	var idle: NpcNeeds = _fresh_needs()
	idle.advance_to(NpcNeedSettings.SECONDS_PER_HOUR)
	var working: NpcNeeds = _fresh_needs()
	assert_true(working.set_activity(NpcNeedKind.WORKING, 0.0).ok)
	working.advance_to(NpcNeedSettings.SECONDS_PER_HOUR)
	assert_true(_near(working.value(NpcNeedKind.FATIGUE), idle.value(NpcNeedKind.FATIGUE) * 2.0))
	assert_eq(working.set_activity("fighting", NpcNeedSettings.SECONDS_PER_HOUR).reason, NpcNeeds.REASON_BAD_ACTIVITY)


func test_next_category_boundary_is_returned_as_an_absolute_calendar_time() -> void:
	_settings.hunger_hours_to_max = 1.0
	var needs: NpcNeeds = _fresh_needs()
	var caution_at: float = _settings.caution_threshold / _settings.need_max * NpcNeedSettings.SECONDS_PER_HOUR
	var danger_at: float = _settings.danger_threshold / _settings.need_max * NpcNeedSettings.SECONDS_PER_HOUR
	assert_true(_near(needs.next_category_boundary_world_time(), caution_at))
	var next_boundary: float = needs.advance_to(caution_at)
	assert_eq(needs.category(NpcNeedKind.HUNGER), NpcNeedKind.Category.CAUTION)
	assert_true(_near(next_boundary, danger_at), "advance_to returns the next boundary after the interval")
	var after_danger: float = needs.advance_to(danger_at)
	assert_eq(needs.category(NpcNeedKind.HUNGER), NpcNeedKind.Category.DANGER)
	assert_true(after_danger > danger_at, "another simulated need may have the next boundary, but hunger's passed boundary is never returned again")
	assert_true(is_inf(needs.advance_to(danger_at - 1.0)), "calendar time never moves backwards")


func test_satisfy_reduces_one_need_reports_source_and_marks_the_npc_dirty() -> void:
	var direct: NpcNeeds = _fresh_needs()
	direct.advance_to(24.0 * NpcNeedSettings.SECONDS_PER_HOUR)
	var before: float = direct.value(NpcNeedKind.HUNGER)
	var satisfied: ActionResult = direct.satisfy(NpcNeedKind.HUNGER, 15.0, "dev_food")
	assert_true(satisfied.ok, satisfied.reason)
	assert_true(_near(direct.value(NpcNeedKind.HUNGER), maxf(before - 15.0, 0.0)))
	assert_eq(satisfied.event.get("source", ""), "dev_food")
	assert_eq(satisfied.event.get("need", ""), NpcNeedKind.HUNGER)
	assert_true(_near(float(satisfied.event.get("applied_amount", -1.0)), minf(before, 15.0)))
	assert_eq(direct.satisfy(NpcNeedKind.WARMTH, 1.0, "fire").reason, NpcNeeds.REASON_UNSUPPORTED_NEED)
	assert_eq(direct.satisfy(NpcNeedKind.HUNGER, 0.0, "food").reason, NpcNeeds.REASON_BAD_AMOUNT)
	assert_eq(direct.satisfy(NpcNeedKind.HUNGER, 1.0, "").reason, NpcNeeds.REASON_BAD_SOURCE)

	var world: ServerWorld = _world()
	var npc_id: String = _spawn(world)
	var dirty_cells: PackedStringArray = []
	_npcs(world).cell_save_dirty.connect(func(cell_id: String) -> void: dirty_cells.append(cell_id))
	world.step_systems(10.0)
	assert_true(_needs(world, npc_id).satisfy(NpcNeedKind.HUNGER, 1.0, "dev_food").ok)
	assert_true(dirty_cells.has(HOME_CELL), "a saved value change calls NpcService.mark_npc_dirty")


func test_needs_save_restore_and_reject_a_broken_component_document() -> void:
	var world: ServerWorld = _world()
	var npc_id: String = _spawn(world)
	var needs: NpcNeeds = _needs(world, npc_id)
	assert_true(needs.set_activity(NpcNeedKind.WORKING, world.clock.world_time_sec).ok)
	needs.advance_to(world.clock.world_time_sec + 1234.0)
	needs.set_rate_modifiers(1.25, 0.8, needs.last_updated_world_time())
	needs.satisfy(NpcNeedKind.THIRST, 0.5, "well")
	var before: Dictionary = _json(_npcs(world).npc_document(npc_id)[NpcState.KEY_COMPONENTS][NpcNeeds.COMPONENT_ID])
	assert_true(SaveService.is_json_safe(before))

	var documents: Dictionary = _json(world.to_documents())
	var restored: ServerWorld = _world()
	assert_eq(restored.restore_documents(documents["world_state"], documents["players"]).size(), 0)
	var restored_needs: NpcNeeds = _needs(restored, npc_id)
	assert_not_null(restored_needs)
	if restored_needs != null:
		assert_eq(_json(restored_needs.to_document()), _json(needs.to_document()))
		assert_eq(_json(_npcs(restored).npc_document(npc_id)[NpcState.KEY_COMPONENTS][NpcNeeds.COMPONENT_ID]), before)

	var broken: Dictionary = _json(documents)
	var npc_rows: Array = broken["world_state"]["systems"][NpcService.SYSTEM_ID][NpcService.KEY_NPCS]
	npc_rows[0][NpcState.KEY_COMPONENTS][NpcNeeds.COMPONENT_ID]["last_updated_world_time"] = "yesterday"
	var refused: ServerWorld = _world()
	assert_contains("; ".join(refused.restore_documents(broken["world_state"], broken["players"])), "last_updated_world_time")
	assert_eq(_npcs(refused).npc_count(), 0, "component validation changes nothing on error")


func test_schema_two_json_round_trip_keeps_every_saved_float_bit_exact() -> void:
	var needs: NpcNeeds = _fresh_needs()
	var segment_at: float = 0.0015432098765432098
	assert_true(needs.set_rate_modifiers(0.016666666666666666, 0.30000000000000004, segment_at).ok)
	needs.advance_to(segment_at + 0.016666666666666666)
	var document: Dictionary = needs.to_document()
	document[NpcComponent.KEY_SCHEMA_VERSION] = needs.schema_version()
	var round_tripped: Dictionary = _json(document)
	assert_eq(int(round_tripped[NpcComponent.KEY_SCHEMA_VERSION]), needs.schema_version())
	round_tripped.erase(NpcComponent.KEY_SCHEMA_VERSION)
	document.erase(NpcComponent.KEY_SCHEMA_VERSION)
	assert_eq(round_tripped, document, "schema 2 contains lossless float64 strings, not parser-rounded JSON numbers")
	round_tripped[NpcComponent.KEY_SCHEMA_VERSION] = needs.schema_version()

	var restored: NpcNeeds = NpcNeeds.new(_settings)
	assert_eq(restored.restore_document(round_tripped).size(), 0)
	assert_eq(restored.to_document(), needs.to_document())
	assert_true(restored.last_updated_world_time() == needs.last_updated_world_time())
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		assert_true(restored.value(kind) == needs.value(kind), "%s value is bit-equal" % kind)


func test_schema_one_numeric_document_is_still_readable() -> void:
	var elapsed: float = 10.0
	var rates: Dictionary = {}
	var values: Dictionary = {}
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		var rate: float = _settings.rate_per_world_sec(kind, NpcNeedKind.IDLE)
		rates[kind] = rate
		values[kind] = rate * elapsed
	var legacy: Dictionary = {
		NpcComponent.KEY_SCHEMA_VERSION: NpcNeeds.LEGACY_SCHEMA_VERSION,
		NpcNeeds.KEY_VALUES: values,
		NpcNeeds.KEY_ACTIVITY: NpcNeedKind.IDLE,
		NpcNeeds.KEY_PERSONALITY_MODIFIER: 1.0,
		NpcNeeds.KEY_ABILITY_MODIFIER: 1.0,
		NpcNeeds.KEY_LAST_UPDATED: elapsed,
		NpcNeeds.KEY_SEGMENT_STARTED: 0.0,
		NpcNeeds.KEY_SEGMENT_VALUES: {NpcNeedKind.HUNGER: 0.0, NpcNeedKind.THIRST: 0.0, NpcNeedKind.FATIGUE: 0.0},
		NpcNeeds.KEY_SEGMENT_RATES: rates,
	}
	var restored: NpcNeeds = NpcNeeds.new(_settings)
	assert_eq(restored.restore_document(_json(legacy)).size(), 0, "schema 1 numbers remain loadable after their historical parser rounding")
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		assert_true(_near(restored.value(kind), float(values[kind])))
	var migrated: Dictionary = restored.to_document()
	assert_eq(typeof((migrated[NpcNeeds.KEY_VALUES] as Dictionary)[NpcNeedKind.HUNGER]), TYPE_STRING, "the next save writes schema 2 float64 strings")


func test_a_tuning_change_does_not_invalidate_or_rewrite_a_saved_rate_segment() -> void:
	_settings.hunger_hours_to_max = 48.0
	var original: NpcNeeds = _fresh_needs()
	original.advance_to(1000.0)
	var document: Dictionary = original.to_document()
	document[NpcComponent.KEY_SCHEMA_VERSION] = original.schema_version()
	var value_at_save: float = original.value(NpcNeedKind.HUNGER)
	var old_rate: float = _settings.rate_per_world_sec(NpcNeedKind.HUNGER, NpcNeedKind.IDLE)

	var retuned: NpcNeedSettings = NpcNeedSettings.new()
	retuned.hunger_hours_to_max = 12.0
	var restored: NpcNeeds = NpcNeeds.new(retuned)
	assert_eq(restored.restore_document(_json(document)).size(), 0, "retuning does not make an old save corrupt")
	restored.advance_to(2000.0)
	assert_true(_near(restored.value(NpcNeedKind.HUNGER), value_at_save + old_rate * 1000.0), "the already-started segment keeps its saved rate")
	assert_true(restored.value(NpcNeedKind.HUNGER) < retuned.rate_per_world_sec(NpcNeedKind.HUNGER, NpcNeedKind.IDLE) * 2000.0, "the new rate waits for the next activity/modifier segment")
