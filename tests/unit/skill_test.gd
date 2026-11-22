extends TestCase
## F-9: player skill levels (FD-3, FD-8). The experience -> level curve, the
## material reduction table (levels 1, 5, 10; rounded up; never below 1),
## the server system (experience, caps, reset for a new character), the
## building skill applied to structure costs and given for finished work,
## save -> load of the "skills" player fragment, the client mirror and the
## HUD text. No nodes. Network: tests/integration/skill_net_test.gd.

const WORLD: String = "skill_test_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const SPAWN_TILE: Vector2i = Vector2i(5, 5)
const EAST: int = 1
const WEST: int = 3
const PLANK: String = ConstructionTestKit.PLANK
const NAIL: String = ConstructionTestKit.NAIL
const WALL: String = ConstructionTestKit.WALL
const FREE_WALL: String = ConstructionTestKit.FREE_WALL
const WALL_WORK_SEC: float = ConstructionTestKit.WALL_WORK_SEC
const BUILDING: String = SkillService.SKILL_BUILDING
const REPAIR: String = SkillService.SKILL_REPAIR

var _settings: SkillSettings = null
var _building_settings: BuildingSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = SkillSettings.new()
	_building_settings = BuildingSettings.new()


func after_each() -> void:
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	# from_defaults() hands out shared cached resources: replace, never edit.
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.catalog = ConstructionTestKit.items()
	config.structures = ConstructionTestKit.structures()
	config.building = _building_settings
	config.skills = _settings
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 10.0
	config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	config.world_cells.active_radius_cells = 1
	config.world_cells.preload_radius_cells = 2
	config.world_cells.preload_lookahead_sec = 0.0
	config.world_cells.refresh_period_sec = 0.0
	return config


func _world() -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	world.seed_new_world(DevWorldSeed.new())
	return world


func _skills(world: ServerWorld) -> SkillService:
	return world.get_system(SkillService.SYSTEM_ID) as SkillService


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _set_level(world: ServerWorld, player_id: String, skill_id: String, level: int) -> void:
	var needed: int = SkillRules.xp_to_reach(level, _settings) - _skills(world).xp_of(player_id, skill_id)
	if needed > 0 and not _skills(world).add_xp(player_id, skill_id, needed).ok:
		fail("test setup: could not raise %s to level %d" % [skill_id, level])
	assert_eq(_skills(world).level_of(player_id, skill_id), level, "test setup: level")


## Same materials and units, whatever the dictionaries are typed as.
func _assert_costs(actual: Dictionary, expected: Dictionary, message: String) -> void:
	assert_eq(actual.size(), expected.size(), message + " (kinds)")
	for item_id: Variant in expected:
		assert_eq(int(actual.get(item_id, -1)), int(expected[item_id]), "%s (%s)" % [message, str(item_id)])


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


# ------------------------------------------------------------ rules

func test_the_shipped_settings_are_valid_and_broken_ones_are_refused() -> void:
	var shipped: SkillSettings = SkillSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_eq(shipped.max_level, 10, "FD-8: 10 levels")
	assert_eq(shipped.max_cost_reduction_percent, 50, "FD-8: at most 50%")
	assert_true(shipped.has_skill(BUILDING) and shipped.has_skill(REPAIR))
	assert_eq(_settings.validate().size(), 0, "the script defaults are valid too")
	var breakers: Array[Callable] = [
		func(s: SkillSettings) -> void: s.skill_ids = PackedStringArray(),
		func(s: SkillSettings) -> void: s.skill_ids = PackedStringArray(["building", "building"]),
		func(s: SkillSettings) -> void: s.skill_ids = PackedStringArray(["Not Snake"]),
		func(s: SkillSettings) -> void: s.level_xp = PackedInt32Array([100, 200]),
		func(s: SkillSettings) -> void: s.level_xp = PackedInt32Array([100, 100, 450, 700, 1000, 1400, 1900, 2500, 3200]),
		func(s: SkillSettings) -> void: s.level_xp = PackedInt32Array([0, 250, 450, 700, 1000, 1400, 1900, 2500, 3200]),
		func(s: SkillSettings) -> void: s.max_cost_reduction_percent = 100,
		func(s: SkillSettings) -> void: s.building_xp_per_structure = -1,
	]
	for index: int in range(breakers.size()):
		var broken: SkillSettings = SkillSettings.new()
		breakers[index].call(broken)
		assert_true(broken.validate().size() > 0, "broken settings %d are refused" % index)


func test_experience_gives_levels_one_to_ten() -> void:
	assert_eq(SkillRules.level_for_xp(0, _settings), 1)
	assert_eq(SkillRules.level_for_xp(-5, _settings), 1, "no level below 1")
	assert_eq(SkillRules.level_for_xp(99, _settings), 1)
	assert_eq(SkillRules.level_for_xp(100, _settings), 2, "exactly the threshold reaches the level")
	assert_eq(SkillRules.level_for_xp(249, _settings), 2)
	assert_eq(SkillRules.level_for_xp(250, _settings), 3)
	assert_eq(SkillRules.level_for_xp(3199, _settings), 9)
	assert_eq(SkillRules.level_for_xp(3200, _settings), 10)
	assert_eq(SkillRules.level_for_xp(1000000, _settings), 10, "no level above 10")
	var previous: int = 1
	for xp: int in range(0, 3400, 7):
		var level: int = SkillRules.level_for_xp(xp, _settings)
		assert_true(level >= previous and level <= previous + 1, "the level never falls and never skips at %d" % xp)
		previous = level
	for level: int in range(1, 11):
		assert_eq(SkillRules.level_for_xp(SkillRules.xp_to_reach(level, _settings), _settings), level, "xp_to_reach(%d)" % level)
	var middle: Dictionary = SkillRules.progress_of(260, _settings)
	assert_eq(middle, {"level": 3, "xp": 260, "level_start_xp": 250, "next_level_xp": 450})
	var top: Dictionary = SkillRules.progress_of(999999, _settings)
	assert_eq(top, {"level": 10, "xp": 3200, "level_start_xp": 3200, "next_level_xp": SkillRules.NO_NEXT_LEVEL}, "capped at the last threshold")


func test_the_material_reduction_table_rounds_up_and_never_goes_below_one() -> void:
	# FD-8: about 5.5% a level, 50% at level 10, rounded up.
	assert_true(absf(SkillRules.reduction_fraction(1, _settings)) < 1.0e-9, "level 1 saves nothing")
	assert_true(absf(SkillRules.reduction_fraction(2, _settings) - 0.0555556) < 1.0e-6, "one level: 50/9 %")
	assert_true(absf(SkillRules.reduction_fraction(10, _settings) - 0.5) < 1.0e-9, "level 10 saves half")
	# base -> [level 1, level 5, level 10]. Level 5 keeps 7/9 of the cost.
	var table: Dictionary[int, Array] = {
		1: [1, 1, 1],
		2: [2, 2, 1],
		3: [3, 3, 2],
		4: [4, 4, 2],
		5: [5, 4, 3],
		9: [9, 7, 5],
		10: [10, 8, 5],
		18: [18, 14, 9],
		100: [100, 78, 50],
	}
	for base: int in table:
		var expected: Array = table[base]
		assert_eq(SkillRules.reduced_quantity(base, 1, _settings), expected[0], "%d at level 1" % base)
		assert_eq(SkillRules.reduced_quantity(base, 5, _settings), expected[1], "%d at level 5" % base)
		assert_eq(SkillRules.reduced_quantity(base, 10, _settings), expected[2], "%d at level 10" % base)
	for base: int in range(1, 200):
		var last: int = base
		for level: int in range(1, 11):
			var cost: int = SkillRules.reduced_quantity(base, level, _settings)
			var exact: float = float(base) * (1.0 - SkillRules.reduction_fraction(level, _settings))
			assert_true(cost >= 1, "never below 1 (%d, level %d)" % [base, level])
			assert_true(cost <= last, "a higher level never costs more (%d, level %d)" % [base, level])
			assert_true(float(cost) >= exact - 1.0e-6 and float(cost) < exact + 1.0, "rounded up (%d, level %d: %d for %f)" % [base, level, cost, exact])
			last = cost
	assert_eq(SkillRules.reduced_quantity(7, 0, _settings), 7, "a level below 1 counts as 1")
	assert_eq(SkillRules.reduced_quantity(10, 99, _settings), 5, "a level above 10 counts as 10")
	var costs: Dictionary[String, int] = {PLANK: 4, NAIL: 1}
	var at_ten: Dictionary[String, int] = {PLANK: 2, NAIL: 1}
	_assert_costs(SkillRules.reduced_costs(costs, 10, _settings), at_ten, "every material")
	_assert_costs(costs, {PLANK: 4, NAIL: 1}, "the input is not changed")


# ------------------------------------------------------------ the system

func test_the_server_adds_experience_up_to_the_cap_and_refuses_bad_requests() -> void:
	var world: ServerWorld = _world()
	var skills: SkillService = _skills(world)
	var alice: PlayerState = world.join("alice")
	assert_eq(skills.level_of(alice.player_id, BUILDING), 1, "everybody starts at level 1")
	assert_eq(skills.drain_changed_players().size(), 0)
	var gained: ActionResult = skills.add_xp(alice.player_id, BUILDING, 120)
	assert_true(gained.ok)
	assert_eq(gained.event["level"], 2)
	assert_eq(gained.event["level_before"], 1)
	assert_eq(skills.xp_of(alice.player_id, BUILDING), 120)
	assert_eq(skills.level_of(alice.player_id, REPAIR), 1, "skills are separate")
	assert_eq(skills.drain_changed_players(), PackedStringArray([alice.player_id]))
	assert_eq(skills.drain_changed_players().size(), 0, "drained")
	assert_eq(skills.add_xp(alice.player_id, "cooking", 10).reason, SkillService.REASON_UNKNOWN_SKILL)
	assert_eq(skills.add_xp(alice.player_id, BUILDING, 0).reason, SkillService.REASON_BAD_AMOUNT)
	assert_eq(skills.add_xp(alice.player_id, BUILDING, -50).reason, SkillService.REASON_BAD_AMOUNT)
	assert_eq(skills.add_xp("not a player", BUILDING, 10).reason, SkillService.REASON_INVALID_PLAYER)
	assert_eq(skills.xp_of(alice.player_id, BUILDING), 120, "refusals change nothing")
	assert_true(skills.add_xp(alice.player_id, BUILDING, 1000000).ok)
	assert_eq(skills.xp_of(alice.player_id, BUILDING), _settings.max_xp(), "capped")
	assert_eq(skills.level_of(alice.player_id, BUILDING), 10)
	skills.drain_changed_players()
	assert_true(skills.add_xp(alice.player_id, BUILDING, 5).ok)
	assert_eq(skills.drain_changed_players().size(), 0, "nothing changed at the cap")
	assert_true(skills.record_repair_done(alice.player_id).ok, "the repair hook for F-10")
	assert_eq(skills.xp_of(alice.player_id, REPAIR), _settings.repair_xp_per_repair)
	var rows: Array[Dictionary] = skills.rows_of(alice.player_id)
	assert_eq(rows.size(), 2)
	assert_eq(rows[0], {"skill_id": BUILDING, "level": 10, "xp": 3200, "level_start_xp": 3200, "next_level_xp": SkillRules.NO_NEXT_LEVEL})
	assert_eq(rows[1], {"skill_id": REPAIR, "level": 1, "xp": 10, "level_start_xp": 0, "next_level_xp": 100})
	var repair_costs: Dictionary[String, int] = {NAIL: 3}
	var halved: Dictionary[String, int] = {NAIL: 2}
	_assert_costs(skills.reduced_costs(alice.player_id, REPAIR, repair_costs), repair_costs, "repair level 1 pays everything")
	_assert_costs(skills.reduced_costs(alice.player_id, BUILDING, repair_costs), halved, "the function F-10 uses, with a skill id")


func test_a_new_character_starts_at_level_one() -> void:
	var world: ServerWorld = _world()
	var skills: SkillService = _skills(world)
	var alice: PlayerState = world.join("alice")
	_set_level(world, alice.player_id, BUILDING, 4)
	skills.drain_changed_players()
	assert_true(world.start_new_character(alice.player_id).ok)
	assert_eq(skills.level_of(alice.player_id, BUILDING), 1, "permanent death: the skills went with the character")
	assert_eq(skills.drain_changed_players(), PackedStringArray([alice.player_id]), "the owner is told")


# ------------------------------------------------------------ building

func test_the_building_level_lowers_what_a_placed_structure_needs() -> void:
	var world: ServerWorld = _world()
	var building: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	_set_level(world, alice.player_id, BUILDING, 10)
	_set_level(world, bob.player_id, BUILDING, 5)
	var full: Dictionary[String, int] = {PLANK: 4, NAIL: 2}
	var alice_costs: Dictionary[String, int] = {PLANK: 2, NAIL: 1}
	var bob_costs: Dictionary[String, int] = {PLANK: 4, NAIL: 2}
	var placed: ActionResult = building.try_place(world, alice.player_id, WALL, SPAWN_TILE, EAST)
	assert_true(placed.ok, placed.reason)
	var wall: StructureInstance = building.get_structure(str(placed.event[BuildingService.KEY_STRUCTURE_ID]))
	_assert_costs(wall.inventory_costs, alice_costs, "level 10: half, rounded up")
	_assert_costs(building.public_row(wall)[BuildingService.KEY_REQUIRED], alice_costs, "the clients see what the server will ask for")
	var bob_wall: ActionResult = building.try_place(world, bob.player_id, WALL, SPAWN_TILE, WEST)
	assert_true(bob_wall.ok, bob_wall.reason)
	_assert_costs(building.get_structure(str(bob_wall.event[BuildingService.KEY_STRUCTURE_ID])).inventory_costs, bob_costs, "level 5: 4 * 7/9 = 3.1 -> 4, 2 * 7/9 = 1.6 -> 2")
	var ruled: ActionResult = building.place_structure(world, WALL, SPAWN_TILE, 0)
	assert_true(ruled.ok, ruled.reason)
	_assert_costs(building.get_structure(str(ruled.event[BuildingService.KEY_STRUCTURE_ID])).inventory_costs, full, "a server rule pays the full costs")
	# Alice really builds it with half the materials.
	if not ConstructionTestKit.give(world, alice, PLANK, 4) or not ConstructionTestKit.give(world, alice, NAIL, 2):
		fail("test setup: materials")
		return
	assert_true(building.try_deliver(world, alice.player_id, wall.structure_id).ok)
	assert_eq(ConstructionTestKit.carried(world, alice, PLANK), 2, "only two planks were taken")
	assert_eq(ConstructionTestKit.carried(world, alice, NAIL), 1)
	assert_true(building.try_set_work(world, alice.player_id, wall.structure_id, true).ok)
	_run(world, WALL_WORK_SEC + 1.0)
	assert_eq(wall.construction_state, StructureInstance.State.COMPLETED)


func test_finishing_the_work_on_a_structure_gives_every_worker_building_experience() -> void:
	var world: ServerWorld = _world()
	var building: BuildingService = _building(world)
	var skills: SkillService = _skills(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var wall_id: String = str(building.try_place(world, carol.player_id, FREE_WALL, SPAWN_TILE, EAST).event.get(BuildingService.KEY_STRUCTURE_ID, ""))
	assert_false(wall_id.is_empty())
	assert_eq(skills.xp_of(carol.player_id, BUILDING), 0, "placing gives nothing")
	assert_true(building.try_set_work(world, alice.player_id, wall_id, true).ok)
	assert_true(building.try_set_work(world, bob.player_id, wall_id, true).ok)
	_run(world, WALL_WORK_SEC / 4.0)
	assert_eq(skills.xp_of(alice.player_id, BUILDING), 0, "unfinished work gives nothing")
	_run(world, WALL_WORK_SEC)
	assert_eq(building.get_structure(wall_id).construction_state, StructureInstance.State.COMPLETED)
	assert_eq(skills.xp_of(alice.player_id, BUILDING), _settings.building_xp_per_structure)
	assert_eq(skills.xp_of(bob.player_id, BUILDING), _settings.building_xp_per_structure)
	assert_eq(skills.xp_of(carol.player_id, BUILDING), 0, "the one who only placed it did not build it")
	_run(world, 2.0)
	assert_eq(skills.xp_of(alice.player_id, BUILDING), _settings.building_xp_per_structure, "once per structure")


func test_the_dev_switch_and_a_server_rule_give_no_experience() -> void:
	_building_settings.instant_completion = true
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	assert_true(_building(world).try_place(world, alice.player_id, FREE_WALL, SPAWN_TILE, EAST).ok)
	assert_eq(_skills(world).xp_of(alice.player_id, BUILDING), 0)


# ------------------------------------------------------------ saving

func test_skills_are_saved_with_the_player_and_come_back() -> void:
	var world: ServerWorld = _world()
	var skills: SkillService = _skills(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	assert_true(skills.add_xp(alice.player_id, BUILDING, 777).ok)
	assert_true(skills.add_xp(alice.player_id, REPAIR, 42).ok)
	var documents: Dictionary = world.to_documents()
	assert_true(SaveService.is_json_safe(documents["players"]))
	var alice_doc: Dictionary = documents["players"][alice.player_id]
	var fragment: Dictionary = (alice_doc["systems"] as Dictionary)[SkillService.SYSTEM_ID]
	assert_eq(fragment["schema_version"], PlayerSkills.SCHEMA_VERSION)
	assert_false((documents["players"][bob.player_id]["systems"] as Dictionary).has(SkillService.SYSTEM_ID), "nothing to save for a player without experience")
	assert_eq(int(alice_doc.get("schema_version", 0)), PlayerState.SCHEMA_VERSION, "the player file format itself is unchanged")

	var restored: ServerWorld = ServerComposition.create_world(WORLD, _config())
	var errors: PackedStringArray = restored.restore_documents(_json(documents["world_state"]), _json(documents["players"]), _json(documents["cells"]))
	assert_eq(errors.size(), 0, "; ".join(errors))
	var skills2: SkillService = _skills(restored)
	assert_eq(skills2.xp_of(alice.player_id, BUILDING), 777)
	assert_eq(skills2.level_of(alice.player_id, BUILDING), 5)
	assert_eq(skills2.xp_of(alice.player_id, REPAIR), 42)
	assert_eq(skills2.xp_of(bob.player_id, BUILDING), 0)
	assert_eq(skills2.rows_of(alice.player_id), skills.rows_of(alice.player_id))


func test_a_broken_skills_fragment_is_refused_and_old_or_removed_skills_are_handled() -> void:
	var ok: Array = PlayerSkills.from_dict({"schema_version": 1, "xp": {"building": 50.0, "gone_skill": 9, "repair": 999999}}, _settings)
	assert_eq((ok[1] as PackedStringArray).size(), 0)
	var skills: PlayerSkills = ok[0]
	assert_eq(skills.xp_of(BUILDING), 50, "a JSON number reads as an integer")
	assert_false(skills.xp.has("gone_skill"), "a skill no longer listed is dropped")
	assert_eq(skills.xp_of(REPAIR), _settings.max_xp(), "above the cap is lowered to it")
	for broken: Dictionary in [
		{"xp": {}},
		{"schema_version": 2, "xp": {}},
		{"schema_version": 1},
		{"schema_version": 1, "xp": []},
		{"schema_version": 1, "xp": {"building": -1}},
		{"schema_version": 1, "xp": {"building": 1.5}},
		{"schema_version": 1, "xp": {"building": "10"}},
	]:
		var parsed: Array = PlayerSkills.from_dict(broken, _settings)
		assert_null(parsed[0], str(broken))
		assert_true((parsed[1] as PackedStringArray).size() > 0, str(broken))
	var world: ServerWorld = _world()
	assert_true(_skills(world).restore_player_fragment("player_1", {"schema_version": 1, "xp": {"building": -3}}).size() > 0, "the world refuses it")


# ------------------------------------------------------------ client mirror and HUD

func test_the_client_mirror_takes_only_valid_snapshots() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	assert_true(_skills(world).add_xp(alice.player_id, BUILDING, 260).ok)
	var good: Dictionary = {"schema_version": ClientSkillState.SCHEMA_VERSION, "skills": _skills(world).rows_of(alice.player_id)}
	var mirror: ClientSkillState = ClientSkillState.new(_settings)
	assert_true(mirror.apply_snapshot(good.duplicate(true)))
	assert_eq(mirror.level_of(BUILDING), 3)
	assert_eq(mirror.level_of(REPAIR), 1)
	assert_eq(mirror.level_of("unknown"), 1)
	var row: Dictionary = (good["skills"] as Array)[0]
	var forged_rows: Array = [
		[row, row],
		[{"skill_id": "cooking", "level": 1, "xp": 0, "level_start_xp": 0, "next_level_xp": 100}],
		[{"skill_id": BUILDING, "level": 11, "xp": 0, "level_start_xp": 0, "next_level_xp": 100}],
		[{"skill_id": BUILDING, "level": 3, "xp": 260.0, "level_start_xp": 250, "next_level_xp": 450}],
		[{"skill_id": BUILDING, "level": 3, "xp": 99999, "level_start_xp": 250, "next_level_xp": 450}],
		[{"skill_id": BUILDING, "level": 3, "xp": 260, "level_start_xp": 250}],
		[row, (good["skills"] as Array)[1], row],
	]
	for rows: Array in forged_rows:
		assert_false(mirror.apply_snapshot({"schema_version": ClientSkillState.SCHEMA_VERSION, "skills": rows}), str(rows))
	assert_false(mirror.apply_snapshot({"schema_version": 99, "skills": []}))
	assert_false(mirror.apply_snapshot({"skills": []}))
	assert_eq(mirror.level_of(BUILDING), 3, "a refused snapshot changes nothing")


func test_the_hud_shows_each_level_and_its_experience() -> void:
	assert_eq(SkillPresentationFormatter.build_skill_lines([] as Array[Dictionary]).size(), 0, "nothing before the server told")
	var rows: Array[Dictionary] = [
		{"skill_id": BUILDING, "level": 3, "xp": 260, "level_start_xp": 250, "next_level_xp": 450},
		{"skill_id": REPAIR, "level": 10, "xp": 3200, "level_start_xp": 3200, "next_level_xp": SkillRules.NO_NEXT_LEVEL},
	]
	var lines: PackedStringArray = SkillPresentationFormatter.build_skill_lines(rows)
	assert_eq(lines, PackedStringArray(["건축 Lv 3 (경험치 260/450) | 수리 Lv 10 (최고)"]))
