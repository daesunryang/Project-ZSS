extends TestCase
## P4-1: NPC identity (docs/09 §17.1). Static definitions and the dev
## roster, the runtime NpcState with its stable id and its own random
## generator, the server rules of NpcService (spawn, remove, move, the
## population limit), and the two seams later tickets build on: NpcComponent
## (state of one NPC that is saved with it) and NpcStage (work done for the
## NPCs every tick). NPCs do not think or move by themselves yet. Server
## rules only, no nodes. Cells and saves: npc_cell_persistence_test.gd.

const WORLD: String = "npc_state_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const NURSE: String = "t41_nurse"
const BUILDER: String = "t41_builder"
const KIND: String = NpcService.ENTITY_KIND
## 10 m cells: SPAWN and BESIDE are in cell (0, 0).
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const BESIDE: Vector3 = Vector3(6.5, 0.0, 5.5)
const HOME_CELL: String = "cell_0_0"
const NEXT_CELL: String = "cell_1_0"
const IN_NEXT_CELL: Vector3 = Vector3(12.5, 0.0, 5.5)
## Three cells away: not in memory while the player stands at SPAWN.
const FAR: Vector3 = Vector3(45.5, 0.0, 45.5)
const COUNTER: String = "t41_counter"
const LATE: String = "t41_late"


## A component with one saved number.
class CounterComponent:
	extends NpcComponent
	var id: String = COUNTER
	var value: int = 0
	var created_for: String = ""
	var created_at_world_time: float = -1.0
	var attached: int = 0
	var detached: int = 0
	var retired: bool = false

	func component_id() -> String:
		return id

	func on_created(npc: NpcState, definition: NpcDefinition, clock: WorldClock) -> void:
		created_for = "%s/%s" % [npc.npc_id, definition.definition_id]
		created_at_world_time = clock.world_time_sec
		value = 7

	func on_attached(_world: ServerWorld, _npc: NpcState) -> void:
		attached += 1

	func on_detached(_world: ServerWorld, _npc: NpcState, was_retired: bool) -> void:
		detached += 1
		retired = was_retired

	func to_document() -> Dictionary:
		return {"value": value}

	func restore_document(document: Dictionary) -> PackedStringArray:
		var errors: PackedStringArray = []
		if not ItemInstance.is_integer_value(document.get("value", null)):
			errors.append("value must be an integer")
			return errors
		value = int(document["value"])
		return errors


## A stage that records what it is told.
class RecordingStage:
	extends NpcStage
	var log: PackedStringArray = []
	var steps: int = 0
	var awake_seen: int = 0
	var saved_number: int = 0

	func stage_id() -> String:
		return "t41_stage"

	func on_npc_entered(_world: ServerWorld, npc: NpcState) -> void:
		log.append("entered:" + npc.npc_id)

	func on_npc_left(_world: ServerWorld, npc: NpcState, retired: bool) -> void:
		log.append("%s:%s" % ["retired" if retired else "left", npc.npc_id])

	func on_npc_woke(_world: ServerWorld, npc: NpcState) -> void:
		log.append("woke:" + npc.npc_id)

	func on_npc_slept(_world: ServerWorld, npc: NpcState) -> void:
		log.append("slept:" + npc.npc_id)

	func step(_world: ServerWorld, npcs: NpcService, _action_delta: float, _world_delta: float) -> void:
		steps += 1
		awake_seen = npcs.awake_count()

	func to_world_document() -> Dictionary:
		return {"saved_number": saved_number} if saved_number != 0 else {}

	func restore_world_document(document: Dictionary) -> PackedStringArray:
		if not ItemInstance.is_integer_value(document.get("saved_number", null)):
			return PackedStringArray(["saved_number must be an integer"])
		saved_number = int(document["saved_number"])
		return PackedStringArray()


var _cell_settings: WorldCellSettings = null
var _settings: NpcSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	# 10 m cells on a 100 m map. Only the player's own cell is active, one
	# ring is kept in memory.
	_cell_settings = WorldCellSettings.new()
	_cell_settings.cell_size_m = 10.0
	_cell_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_cell_settings.bounds_max_m = Vector2(50.0, 50.0)
	_cell_settings.active_radius_cells = 0
	_cell_settings.preload_radius_cells = 1
	_cell_settings.preload_lookahead_sec = 0.0
	_cell_settings.deactivate_delay_sec = 0.0
	_cell_settings.unload_delay_sec = 0.5
	_cell_settings.refresh_period_sec = 0.0
	_cell_settings.max_preload_loads_per_refresh = 1000
	_settings = NpcSettings.new()


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _definition(definition_id: String, display_name: String) -> NpcDefinition:
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = definition_id
	definition.display_name = display_name
	return definition


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = _cell_settings
	config.npc = _settings
	config.npc_definitions = NpcCatalog.new()
	config.npc_definitions.add(_definition(NURSE, "간호사"))
	config.npc_definitions.add(_definition(BUILDER, "목수"))
	return config


func _world(store: WorldCellStore = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	return world


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _spawn(world: ServerWorld, definition_id: String, position: Vector3, yaw: float = 0.0) -> String:
	var spawned: ActionResult = _npcs(world).spawn_npc(world, definition_id, position, yaw)
	if not spawned.ok:
		fail("test setup: npc refused: " + spawned.reason)
		return ""
	return str(spawned.event.get(NpcService.KEY_NPC_ID, ""))


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


func _log_text() -> String:
	return " | ".join(GameLogger.captured_lines())


func _counter() -> NpcComponent:
	return CounterComponent.new()


func _late() -> NpcComponent:
	var component: CounterComponent = CounterComponent.new()
	component.id = LATE
	return component


# ------------------------------------------------------------ data

func test_the_shipped_dev_roster_is_five_valid_npcs_in_test_map_buildings() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_null(config.npc_roster, "tests and tools: no NPCs by default")
	var roster: NpcRoster = NpcRoster.load_or_null()
	assert_not_null(roster, "the dev roster ships")
	if roster == null:
		return
	assert_eq(roster.validate().size(), 0, "; ".join(roster.validate()))
	assert_eq(roster.npc_definition_ids.size(), 5, "docs/13 §16.3 D1: five NPCs")
	config.map_content = MapContentDefinition.load_or_null()
	config.npc_roster = roster
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var grid: StructureGrid = StructureGrid.new(config.building.grid_module_m)
	var names: Dictionary[String, bool] = {}
	var homes: Dictionary[Vector3, bool] = {}
	for definition_id: String in roster.npc_definition_ids:
		var definition: NpcDefinition = config.npc_definitions.get_definition(definition_id)
		assert_not_null(definition, definition_id)
		if definition == null:
			continue
		assert_eq(definition.validate().size(), 0, "; ".join(definition.validate()))
		assert_false(definition.display_name.is_empty())
		names[definition.display_name] = true
		assert_true(config.appearance.is_complete_selection(definition.appearance), "%s names an option of every appearance slot" % definition_id)
		assert_eq(definition.personality().size(), 11, "docs/05 §3: eleven traits")
		for trait_name: String in definition.personality():
			var value: float = float(definition.personality()[trait_name])
			assert_true(value >= 0.0 and value <= 1.0, "%s.%s is within 0..1" % [definition_id, trait_name])
		assert_eq(definition.skills().size(), NpcDefinition.SKILL_NAMES.size())
		assert_true(NpcDefinition.JOB_ROLES.has(definition.job_role), "%s has a job role" % definition_id)
		assert_false(definition.work_building_id.is_empty(), "%s has a work spot" % definition_id)
		var home: Variant = NpcRoster.spot_position(config.map_content, grid, definition.home_building_id, definition.home_tile_offset)
		assert_true(home is Vector3, "%s has a home spot inside a building of the map" % definition_id)
		if home is Vector3:
			homes[home as Vector3] = true
	assert_eq(names.size(), 5, "five different names")
	assert_eq(homes.size(), 5, "five different home spots")
	# The five are not copies of each other.
	var first: NpcDefinition = config.npc_definitions.get_definition(roster.npc_definition_ids[0])
	var second: NpcDefinition = config.npc_definitions.get_definition(roster.npc_definition_ids[1])
	assert_ne(first.personality(), second.personality())


func test_definition_and_roster_validation_refuses_bad_data() -> void:
	var definition: NpcDefinition = _definition("Bad Id", "")
	definition.age_group = "ancient"
	definition.courage = 1.5
	definition.skill_medical = -0.1
	definition.job_role = "wizard"
	definition.background_tags = PackedStringArray(["nurse", "nurse", "Not Snake"])
	definition.home_tile_offset = Vector2i(-1, 0)
	var errors: String = "; ".join(definition.validate())
	for expected: String in ["definition_id", "display_name", "age_group", "courage", "skill_medical", "job_role", "background_tags", "home_tile_offset"]:
		assert_contains(errors, expected)
	assert_eq(_definition(NURSE, "간호사").validate().size(), 0, "the defaults of a named definition are valid")
	# A catalog refuses invalid and duplicate definitions.
	var catalog: NpcCatalog = NpcCatalog.new()
	assert_eq(catalog.add(definition), ERR_INVALID_DATA)
	assert_eq(catalog.add(_definition(NURSE, "간호사")), OK)
	assert_eq(catalog.add(_definition(NURSE, "또 간호사")), ERR_ALREADY_EXISTS)
	# A roster must name definitions that exist, with home spots inside
	# buildings of its map, one NPC per spot, and fit the population limit.
	var config: CompositionConfig = CompositionConfig.from_defaults()
	var map: MapContentDefinition = MapContentDefinition.load_or_null()
	var grid: StructureGrid = StructureGrid.new(config.building.grid_module_m)
	var roster: NpcRoster = NpcRoster.new()
	roster.roster_id = "t41_roster"
	roster.map_id = map.map_id
	roster.npc_definition_ids = PackedStringArray([NURSE, BUILDER, "t41_missing"])
	var nurse: NpcDefinition = _definition(NURSE, "간호사")
	nurse.home_building_id = "house_a"
	nurse.home_tile_offset = Vector2i(1, 1)
	var builder: NpcDefinition = _definition(BUILDER, "목수")
	builder.home_building_id = "house_a"
	builder.home_tile_offset = Vector2i(1, 1)
	builder.work_building_id = "no_such_building"
	catalog.add(builder)
	catalog.get_definition(NURSE).home_building_id = "house_a"
	catalog.get_definition(NURSE).home_tile_offset = Vector2i(99, 0)
	errors = "; ".join(roster.validate_against(catalog, map, grid, 50))
	assert_contains(errors, "t41_missing")
	assert_contains(errors, "outside", "a home tile outside its building")
	assert_contains(errors, "no_such_building")
	catalog.get_definition(NURSE).home_tile_offset = Vector2i(1, 1)
	assert_contains("; ".join(roster.validate_against(catalog, map, grid, 50)), "same home spot")
	catalog.get_definition(NURSE).home_tile_offset = Vector2i(0, 3)
	assert_contains("; ".join(roster.validate_against(catalog, map, grid, 50)), "container", "house_a has a cabinet on that tile")
	assert_contains("; ".join(roster.validate_against(catalog, map, grid, 2)), "max_npcs")
	assert_contains("; ".join(roster.validate_against(catalog, null, grid, 50)), "map content")
	roster.roster_id = "Bad Id"
	roster.npc_definition_ids = PackedStringArray([NURSE, NURSE])
	assert_contains("; ".join(roster.validate()), "roster_id")
	assert_contains("; ".join(roster.validate()), "twice")
	# Settings.
	var settings: NpcSettings = NpcSettings.new()
	assert_eq(settings.validate().size(), 0)
	assert_eq(settings.max_npcs, 50, "docs/13 §16.3 D1: the configured limit")
	settings.max_npcs = 0
	settings.world_seed = -1
	assert_eq(settings.validate().size(), 2)
	assert_eq(NpcSettings.load_or_default().validate().size(), 0, "the shipped settings are valid")


# ------------------------------------------------------------ state

func test_npc_state_round_trips_through_json_and_refuses_malformed_data() -> void:
	var npc: NpcState = NpcState.new()
	npc.npc_id = "npc_000042"
	npc.definition_id = NURSE
	npc.position = Vector3(1.25, 0.0, -3.5)
	npc.yaw = 0.75
	npc.created_at = 120.0
	npc.last_simulated_world_time = 360.5
	npc.rng.seed = NpcState.seed_for(20261119, npc.npc_id)
	npc.rng.randi()
	var saved: Dictionary = _json(npc.to_dict())
	assert_true(SaveService.is_json_safe(npc.to_dict()))
	assert_eq(int(saved[NpcState.KEY_SCHEMA_VERSION]), NpcState.SCHEMA_VERSION)
	var restored: NpcState = NpcState.from_dict(saved)
	assert_not_null(restored)
	if restored == null:
		return
	assert_eq(restored.to_dict(), npc.to_dict(), "nothing is lost on the way through JSON")
	assert_eq(restored.rng.state, npc.rng.state, "64-bit generator state survives JSON")
	assert_eq(restored.rng.randi(), npc.rng.randi(), "and goes on with the same numbers")
	assert_eq(restored.simulation_tier, NpcState.TIER_FROZEN, "the tier is decided at run time, not saved")
	assert_false(saved.has("simulation_tier"))
	# Malformed data gives no state.
	for broken: Array in [
		[NpcState.KEY_NPC_ID, "zombie_000001"],
		[NpcState.KEY_NPC_ID, 12],
		[NpcState.KEY_DEFINITION_ID, "Not Snake"],
		[NpcState.KEY_POSITION, [0.0, 0.0]],
		[NpcState.KEY_POSITION, [0.0, "x", 0.0]],
		[NpcState.KEY_YAW, "north"],
		[NpcState.KEY_RNG_STATE, "abc"],
		[NpcState.KEY_RNG_SEED, 12.5],
		[NpcState.KEY_CREATED_AT, null],
		[NpcState.KEY_COMPONENTS, []],
		[NpcState.KEY_COMPONENTS, {"Bad Id": {"schema_version": 1}}],
		[NpcState.KEY_COMPONENTS, {COUNTER: {"value": 1}}],
		[NpcState.KEY_SCHEMA_VERSION, 99],
	]:
		var data: Dictionary = _json(npc.to_dict())
		data[broken[0]] = broken[1]
		assert_null(NpcState.from_dict(data), "%s = %s is refused" % [broken[0], str(broken[1])])
	# The seed of an NPC depends on the world seed and its id only.
	assert_eq(NpcState.seed_for(1, "npc_000001"), NpcState.seed_for(1, "npc_000001"))
	assert_ne(NpcState.seed_for(1, "npc_000001"), NpcState.seed_for(1, "npc_000002"))
	assert_ne(NpcState.seed_for(1, "npc_000001"), NpcState.seed_for(2, "npc_000001"))
	assert_true(NpcState.seed_for(9007199254740991, "npc_999999") >= 0)


# ------------------------------------------------------------ server rules

func test_spawned_npcs_get_stable_unique_ids_and_their_own_random_generators() -> void:
	var world: ServerWorld = _world()
	var service: NpcService = _npcs(world)
	assert_eq(service.npc_count(), 0, "a world from a plain composition has no NPCs")
	assert_false((world.to_documents()["world_state"]["systems"] as Dictionary).has(NpcService.SYSTEM_ID), "and its save has nothing about them")
	world.join("alice")
	_run(world, TICK)
	var nurse_id: String = _spawn(world, NURSE, BESIDE, 0.5)
	var builder_id: String = _spawn(world, BUILDER, SPAWN)
	assert_true(NpcState.is_valid_npc_id(nurse_id), nurse_id)
	assert_ne(nurse_id, builder_id)
	assert_eq(service.npc_ids(), PackedStringArray([nurse_id, builder_id]) if nurse_id < builder_id else PackedStringArray([builder_id, nurse_id]))
	assert_eq(world.registry.kind_of(nurse_id), KIND)
	assert_eq(world.cell_index.cell_of(nurse_id), HOME_CELL)
	assert_eq(world.cell_index.kind_of(nurse_id), KIND)
	assert_eq(service.npc_ids_in_cell(HOME_CELL).size(), 2)
	var nurse: NpcState = service.get_npc(nurse_id)
	assert_eq(nurse.definition_id, NURSE)
	assert_eq(nurse.position, BESIDE)
	assert_eq(nurse.yaw, 0.5)
	assert_eq(service.definition_of(nurse_id).display_name, "간호사")
	assert_eq(service.population_count(), 2)
	# NPC seed = world seed + NPC id; never the engine's global generator.
	assert_eq(nurse.rng.seed, NpcState.seed_for(_settings.world_seed, nurse_id))
	assert_ne(nurse.rng.seed, service.get_npc(builder_id).rng.seed)
	var again: ServerWorld = _world()
	again.join("alice")
	_run(again, TICK)
	seed(12345)
	var same_id: String = _spawn(again, NURSE, BESIDE, 0.5)
	assert_eq(same_id, nurse_id, "ids are counters: the same steps give the same ids")
	assert_eq(_npcs(again).get_npc(same_id).rng.state, nurse.rng.state, "and the same generator, whatever the global one does")
	# Refusals change nothing.
	var sequence: int = world.ids.get_next_sequence()
	assert_eq(service.spawn_npc(world, "t41_nobody", SPAWN).reason, NpcService.REASON_UNKNOWN_DEFINITION)
	assert_eq(service.spawn_npc(world, NURSE, Vector3(NAN, 0.0, 0.0)).reason, NpcService.REASON_BAD_POSITION)
	assert_eq(service.spawn_npc(world, NURSE, Vector3(51.0, 0.0, 0.0)).reason, NpcService.REASON_BAD_POSITION, "outside the play area")
	assert_eq(service.spawn_npc(world, NURSE, SPAWN, INF).reason, NpcService.REASON_BAD_POSITION)
	assert_eq(world.ids.get_next_sequence(), sequence, "a refused spawn spends no id")
	assert_eq(service.npc_count(), 2)


func test_spawn_is_refused_in_a_cell_that_is_not_in_memory_and_over_the_limit() -> void:
	_settings.max_npcs = 2
	var world: ServerWorld = _world(WorldCellStore.new())
	var service: NpcService = _npcs(world)
	world.join("alice")
	_run(world, TICK)
	assert_eq(service.spawn_npc(world, NURSE, FAR).reason, NpcService.REASON_CELL_NOT_LOADED)
	_spawn(world, NURSE, BESIDE)
	_spawn(world, BUILDER, SPAWN)
	var refused: ActionResult = service.spawn_npc(world, NURSE, SPAWN)
	assert_eq(refused.reason, NpcService.REASON_LIMIT, "docs/13 §16.3 D1: a spawn over the limit is refused")
	assert_contains(_log_text(), "npc limit reached", "and logged")
	assert_eq(service.npc_count(), 2)


func test_a_removed_npc_is_retired_for_good() -> void:
	var world: ServerWorld = _world()
	var service: NpcService = _npcs(world)
	world.join("alice")
	_run(world, TICK)
	var nurse_id: String = _spawn(world, NURSE, BESIDE)
	var saved: Dictionary = _json(service.to_world_document())
	var removed: ActionResult = service.remove_npc(world, nurse_id)
	assert_true(removed.ok, removed.reason)
	assert_false(service.has_npc(nurse_id))
	assert_false(world.registry.has(nurse_id))
	assert_true(world.registry.is_tombstoned(nurse_id), "the id is retired, never reused")
	assert_false(world.cell_index.has(nurse_id))
	assert_eq(service.population_count(), 0)
	assert_eq(service.remove_npc(world, nurse_id).reason, NpcService.REASON_UNKNOWN_NPC)
	assert_ne(_spawn(world, NURSE, BESIDE), nurse_id, "a new NPC gets a new id")
	# A save from before the removal cannot bring it back into this world.
	assert_true(service.restore_world_document(saved).size() > 0, "the world document names a retired id")
	assert_false(service.has_npc(nurse_id))


func test_npcs_stand_still_and_use_no_random_numbers() -> void:
	var world: ServerWorld = _world()
	var service: NpcService = _npcs(world)
	world.join("alice")
	var nurse_id: String = _spawn(world, NURSE, BESIDE, 1.0)
	var before: Dictionary = service.get_npc(nurse_id).to_dict()
	_run(world, 5.0)
	assert_true(service.is_awake(nurse_id), "the NPC is in the player's cell: simulated")
	var after: Dictionary = service.get_npc(nurse_id).to_dict()
	# P4-3: its turns to think come and go (npc_scheduler_test.gd); nobody
	# decides anything yet, so nothing else may change.
	for document: Dictionary in [before, after]:
		(document[NpcState.KEY_COMPONENTS] as Dictionary).erase(NpcScheduleComponent.COMPONENT_ID)
	assert_eq(after, before, "P4-1: an NPC does not move, turn or roll anything")
	assert_eq(service.blocked_move_count, 0)


func test_moving_an_npc_keeps_the_cell_index_and_stops_at_cells_not_in_memory() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var service: NpcService = _npcs(world)
	world.join("alice")
	_run(world, TICK)
	var nurse_id: String = _spawn(world, NURSE, BESIDE)
	assert_true(service.is_awake(nurse_id))
	assert_eq(service.get_npc(nurse_id).simulation_tier, NpcState.TIER_NEAR)
	assert_true(service.set_npc_transform(world, nurse_id, Vector3(7.0, 0.0, 6.0), 0.25))
	assert_eq(service.get_npc(nurse_id).position, Vector3(7.0, 0.0, 6.0))
	assert_eq(service.get_npc(nurse_id).yaw, 0.25)
	assert_eq(world.cell_index.cell_of(nurse_id), HOME_CELL)
	# Into the next cell: in memory but not simulated (active radius 0).
	assert_true(service.set_npc_transform(world, nurse_id, IN_NEXT_CELL, 0.0))
	assert_eq(world.cell_index.cell_of(nurse_id), NEXT_CELL)
	assert_false(service.is_awake(nurse_id), "it freezes in a cell that is not simulated")
	assert_eq(service.get_npc(nurse_id).simulation_tier, NpcState.TIER_FROZEN)
	# Never into a cell that is not in memory, never out of the map.
	assert_false(service.set_npc_transform(world, nurse_id, FAR, 0.0))
	assert_false(service.set_npc_transform(world, nurse_id, Vector3(60.0, 0.0, 0.0), 0.0))
	assert_false(service.set_npc_transform(world, nurse_id, Vector3(NAN, 0.0, 0.0), 0.0))
	assert_eq(service.get_npc(nurse_id).position, IN_NEXT_CELL, "a refused move changes nothing")
	assert_eq(service.blocked_move_count, 3)
	assert_false(service.set_npc_transform(world, "npc_999999", SPAWN, 0.0))
	# The tier of an awake NPC is the scheduler's to set; a frozen one stays frozen.
	assert_false(service.set_simulation_tier(nurse_id, NpcState.TIER_FAR))
	assert_true(service.set_npc_transform(world, nurse_id, BESIDE, 0.0))
	assert_true(service.is_awake(nurse_id), "back in the active cell it is simulated again")
	assert_true(service.set_simulation_tier(nurse_id, NpcState.TIER_FAR))
	assert_eq(service.get_npc(nurse_id).simulation_tier, NpcState.TIER_FAR)
	assert_false(service.set_simulation_tier(nurse_id, NpcState.TIER_FROZEN), "frozen is decided by the cell")
	assert_false(service.set_simulation_tier(nurse_id, "warp"))


# ------------------------------------------------------------ components

func test_components_are_created_saved_and_restored_with_their_npc() -> void:
	var world: ServerWorld = _world()
	var service: NpcService = _npcs(world)
	assert_eq(service.register_component(COUNTER, _counter), OK)
	assert_eq(service.register_component(COUNTER, _counter), ERR_ALREADY_EXISTS)
	assert_eq(service.register_component("Bad Id", _counter), ERR_INVALID_PARAMETER)
	assert_eq(service.register_component("t41_other", _counter), ERR_INVALID_DATA, "the factory must make a component with the registered id")
	world.join("alice")
	_run(world, 2.0)
	var nurse_id: String = _spawn(world, NURSE, BESIDE)
	var nurse: NpcState = service.get_npc(nurse_id)
	var counter: CounterComponent = nurse.component(COUNTER) as CounterComponent
	assert_not_null(counter, "a new NPC gets every registered component")
	if counter == null:
		return
	assert_eq(counter.created_for, "%s/%s" % [nurse_id, NURSE])
	assert_eq(counter.created_at_world_time, world.clock.world_time_sec)
	assert_eq(counter.attached, 1)
	# The composition registers its own components (P4-2 needs, and later
	# tickets more); compare with an NPC of a world built the same way but
	# without the test component, so the list stays exact.
	var plain_world: ServerWorld = _world()
	plain_world.join("alice")
	_run(plain_world, 2.0)
	var plain_id: String = _spawn(plain_world, NURSE, BESIDE)
	var expected: Array = Array(_npcs(plain_world).get_npc(plain_id).component_ids())
	assert_false(expected.has(COUNTER))
	expected.append(COUNTER)
	expected.sort()
	var actual: Array = Array(nurse.component_ids())
	actual.sort()
	assert_eq(actual, expected)
	assert_null(nurse.component("t41_nothing"))
	counter.value = 31
	var document: Dictionary = _json(service.npc_document(nurse_id))
	var slot: Dictionary = (document[NpcState.KEY_COMPONENTS] as Dictionary)[COUNTER]
	assert_eq(int(slot["schema_version"]), 1, "the service stamps the component's version")
	assert_eq(int(slot["value"]), 31)
	# A late registration is refused: every NPC must have had the chance.
	assert_eq(service.register_component(LATE, _late), ERR_UNAVAILABLE)
	# Restored in another world that knows one more component: the saved
	# one is restored, the new one is created fresh.
	var saved: Dictionary = _json(world.to_documents())
	var second: ServerWorld = _world()
	assert_eq(_npcs(second).register_component(COUNTER, _counter), OK)
	assert_eq(_npcs(second).register_component(LATE, _late), OK)
	assert_eq(second.restore_documents(saved["world_state"], saved["players"]).size(), 0)
	var restored: NpcState = _npcs(second).get_npc(nurse_id)
	assert_not_null(restored)
	if restored == null:
		return
	assert_eq((restored.component(COUNTER) as CounterComponent).value, 31)
	assert_eq((restored.component(COUNTER) as CounterComponent).created_for, "", "a restored component is not created again")
	assert_eq((restored.component(LATE) as CounterComponent).value, 7, "a component added after the save starts fresh")
	assert_eq((restored.component(LATE) as CounterComponent).created_for, "%s/%s" % [nurse_id, NURSE])
	# Restored in a world that does NOT know the component: its document is
	# kept as it is and saved again, so nothing is lost.
	var both: Dictionary = _json(second.to_documents())
	var third: ServerWorld = _world()
	assert_eq(third.restore_documents(both["world_state"], both["players"]).size(), 0)
	assert_null(_npcs(third).get_npc(nurse_id).component(COUNTER))
	assert_contains(_log_text(), "unregistered npc component")
	assert_eq(_json(_npcs(third).npc_document(nurse_id))[NpcState.KEY_COMPONENTS], _json(_npcs(second).npc_document(nurse_id))[NpcState.KEY_COMPONENTS], "the documents of unknown components survive a save")
	# A component that refuses its document refuses the whole restore.
	both = _json(both)
	((((both["world_state"]["systems"] as Dictionary)[NpcService.SYSTEM_ID] as Dictionary)[NpcService.KEY_NPCS] as Array)[0][NpcState.KEY_COMPONENTS] as Dictionary)[COUNTER]["value"] = "many"
	var fourth: ServerWorld = _world()
	_npcs(fourth).register_component(COUNTER, _counter)
	assert_contains("; ".join(fourth.restore_documents(both["world_state"], both["players"])), "value must be an integer")
	assert_eq(_npcs(fourth).npc_count(), 0, "validate first: nothing came into memory")
	assert_false(fourth.registry.has(nurse_id))
	# Removing an NPC tells its components that it is gone for good.
	service.remove_npc(world, nurse_id)
	assert_eq(counter.detached, 1)
	assert_true(counter.retired)


# ------------------------------------------------------------ stages

func test_stages_hear_of_npcs_and_are_stepped_and_saved() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var service: NpcService = _npcs(world)
	var stage: RecordingStage = RecordingStage.new()
	assert_eq(service.add_stage(stage), OK)
	assert_eq(service.add_stage(RecordingStage.new()), ERR_ALREADY_EXISTS)
	assert_eq(service.add_stage(NpcStage.new()), ERR_INVALID_PARAMETER, "the base class has no id")
	var alice: PlayerState = world.join("alice")
	_run(world, TICK)
	var nurse_id: String = _spawn(world, NURSE, BESIDE)
	assert_eq(stage.log, PackedStringArray(["entered:" + nurse_id, "woke:" + nurse_id]))
	var steps: int = stage.steps
	_run(world, TICK)
	assert_eq(stage.steps, steps + 1, "stepped once per tick")
	assert_eq(stage.awake_seen, 1)
	assert_true(service.last_step_msec >= 0.0)
	# The player walks away: the cell stops being simulated, then leaves memory.
	stage.log.clear()
	alice.position = FAR
	_run(world, TICK)
	assert_eq(stage.log, PackedStringArray(["slept:" + nurse_id]))
	_run(world, 2.0)
	assert_eq(stage.log, PackedStringArray(["slept:" + nurse_id, "left:" + nurse_id]))
	assert_eq(stage.awake_seen, 0)
	alice.position = SPAWN
	_run(world, TICK)
	assert_eq(stage.log.slice(2), PackedStringArray(["entered:" + nurse_id, "woke:" + nurse_id]))
	stage.log.clear()
	service.remove_npc(world, nurse_id)
	assert_eq(stage.log, PackedStringArray(["slept:" + nurse_id, "retired:" + nurse_id]))
	# A stage's own document is part of the world document.
	stage.saved_number = 5
	var saved: Dictionary = _json(world.to_documents())
	assert_eq(int((((saved["world_state"]["systems"] as Dictionary)[NpcService.SYSTEM_ID] as Dictionary)[NpcService.KEY_STAGES] as Dictionary)["t41_stage"]["saved_number"]), 5)
	var second: ServerWorld = _world(WorldCellStore.new())
	var second_stage: RecordingStage = RecordingStage.new()
	_npcs(second).add_stage(second_stage)
	assert_eq(second.restore_documents(_json(saved["world_state"]), _json(saved["players"]), _json(saved["cells"])).size(), 0)
	assert_eq(second_stage.saved_number, 5)
	# A world without that stage keeps the document for the next save.
	var third: ServerWorld = _world(WorldCellStore.new())
	assert_eq(third.restore_documents(_json(saved["world_state"]), _json(saved["players"]), _json(saved["cells"])).size(), 0)
	assert_eq(int((((_json(third.to_documents()["world_state"])["systems"] as Dictionary)[NpcService.SYSTEM_ID] as Dictionary)[NpcService.KEY_STAGES] as Dictionary)["t41_stage"]["saved_number"]), 5)
