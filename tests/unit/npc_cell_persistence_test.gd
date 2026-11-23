extends TestCase
## P4-1: NPCs, world cells and saves (docs/09 §15.1, §17.1). An NPC belongs
## to the cell of its position: it is in the cell index, is saved in that
## cell's document, leaves memory with the cell and comes back identical
## (id, definition, position, facing, random generator, component
## documents). The dev roster is placed once per world, in buildings of the
## test map, and never again: not after a cell reload, not after a restart.
## Every NPC id exists exactly once, in memory and on disk. Memory cell
## stores for the rules, WorldPersistence and real files for the restarts.

const WORLD: String = "npc_persist_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const TOLERANCE: float = 0.000001
const NURSE: String = "t41p_nurse"
const BUILDER: String = "t41p_builder"
const KIND: String = NpcService.ENTITY_KIND
const COUNTER: String = "t41p_counter"
## 10 m cells: SPAWN and BESIDE are in cell (0, 0); from FAR that cell is
## released.
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const BESIDE: Vector3 = Vector3(6.5, 0.0, 5.5)
const HOME_CELL: String = "cell_0_0"
const FAR: Vector3 = Vector3(45.5, 0.0, 45.5)
const BESIDE_FAR: Vector3 = Vector3(46.5, 0.0, 45.5)
const FAR_CELL: String = "cell_4_4"
## Longer than the unload delay.
const RELEASE_SEC: float = 2.0
const MAP_ID: String = "dev_test_map"
const ROSTER_ID: String = "dev_npc_roster"
## The shipped map: where players stand to have the buildings in memory, and
## a corner of the 500 m map from which every building cell is released.
const TOWN: Vector3 = Vector3(0.0, 0.0, 0.0)
const CORNER: Vector3 = Vector3(-240.0, 0.0, -240.0)
## Longer than the shipped deactivate + unload delays.
const SHIPPED_RELEASE_SEC: float = 30.0


## A component with one saved number.
class CounterComponent:
	extends NpcComponent
	var value: int = 0

	func component_id() -> String:
		return COUNTER

	func to_document() -> Dictionary:
		return {"value": value}

	func restore_document(document: Dictionary) -> PackedStringArray:
		if not ItemInstance.is_integer_value(document.get("value", null)):
			return PackedStringArray(["value must be an integer"])
		value = int(document["value"])
		return PackedStringArray()


var _cell_settings: WorldCellSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/npc_persist_%d" % Time.get_ticks_usec()
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


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _definition(definition_id: String, display_name: String) -> NpcDefinition:
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = definition_id
	definition.display_name = display_name
	return definition


## A 100 m map of 10 m cells with two test definitions and nothing that
## moves by itself.
func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# P4-5b: no behaviour layer here, so the NPCs decide nothing and stand
	# still (what NPCs do is tested in npc_behaviour_test.gd).
	config.npc_behaviour = null
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
	config.npc = NpcSettings.new()
	config.npc_definitions = NpcCatalog.new()
	config.npc_definitions.add(_definition(NURSE, "간호사"))
	config.npc_definitions.add(_definition(BUILDER, "목수"))
	return config


## The shipped composition (the 500 m map, its cells, the test map and the
## dev roster) and nothing that moves by itself.
func _shipped_config(with_roster: bool = true) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# P4-5b: no behaviour layer here, so the NPCs decide nothing and stand
	# still (what NPCs do is tested in npc_behaviour_test.gd).
	config.npc_behaviour = null
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.gameplay = GameplaySettings.load_or_default().duplicate() as GameplaySettings
	config.gameplay.player_spawn_position = TOWN
	config.world_cells = WorldCellSettings.load_or_default().duplicate() as WorldCellSettings
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.preload_lookahead_sec = 0.0
	config.map_content = MapContentDefinition.load_or_null()
	config.npc_roster = NpcRoster.load_or_null() if with_roster else null
	return config


func _world(store: WorldCellStore = null, config: CompositionConfig = null, with_component: bool = true) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, config if config != null else _config())
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	if with_component:
		_npcs(world).register_component(COUNTER, _counter)
	return world


func _counter() -> NpcComponent:
	return CounterComponent.new()


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _move(world: ServerWorld, player: PlayerState, position: Vector3, seconds: float = TICK) -> void:
	player.position = position
	_run(world, seconds)


func _spawn(world: ServerWorld, definition_id: String, position: Vector3, yaw: float = 0.0) -> String:
	var spawned: ActionResult = _npcs(world).spawn_npc(world, definition_id, position, yaw)
	if not spawned.ok:
		fail("test setup: npc refused: " + spawned.reason)
		return ""
	return str(spawned.event.get(NpcService.KEY_NPC_ID, ""))


## Save data of every NPC in memory, by id, without "simulated until": for
## an awake NPC that is the time of the document, which differs between two
## looks at the same NPC. Without its schedule too (P4-3): an awake NPC's
## next turn moves on with time; npc_scheduler_test.gd checks that a save
## and a restart keep it.
func _saved(world: ServerWorld) -> Dictionary:
	var result: Dictionary = {}
	for npc_id: String in _npcs(world).npc_ids():
		var document: Dictionary = _npcs(world).npc_document(npc_id)
		document.erase(NpcState.KEY_LAST_SIMULATED)
		(document[NpcState.KEY_COMPONENTS] as Dictionary).erase(NpcScheduleComponent.COMPONENT_ID)
		result[npc_id] = document
	return result


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


## Equal, except that numbers may differ by what a JSON round trip of a
## float loses (a save is text).
func _same(a: Variant, b: Variant) -> bool:
	if (typeof(a) == TYPE_FLOAT or typeof(a) == TYPE_INT) and (typeof(b) == TYPE_FLOAT or typeof(b) == TYPE_INT):
		return absf(float(a) - float(b)) <= TOLERANCE
	if typeof(a) != typeof(b):
		return false
	if typeof(a) == TYPE_ARRAY:
		if (a as Array).size() != (b as Array).size():
			return false
		for index: int in range((a as Array).size()):
			if not _same(a[index], b[index]):
				return false
		return true
	if typeof(a) == TYPE_DICTIONARY:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for key: Variant in (a as Dictionary):
			if not (b as Dictionary).has(key) or not _same(a[key], b[key]):
				return false
		return true
	return a == b


func _log_text() -> String:
	return " | ".join(GameLogger.captured_lines())


func _npc_part(world_state: Dictionary) -> Dictionary:
	return (world_state["systems"] as Dictionary).get(NpcService.SYSTEM_ID, {})


func _save_service() -> SaveService:
	return SaveService.new(_root)


## A server start: a brand-new world object built from what is on disk.
func _boot(config: CompositionConfig) -> ServerWorld:
	return WorldPersistence.new(_save_service(), config).load_or_create(WORLD)


func _read_json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary


## Every NPC document of the save on disk, by id: from the world document
## (strays) and every cell file. An id that is on disk twice fails the test.
func _npcs_on_disk() -> Dictionary:
	var save: SaveService = _save_service()
	var base: String = save.world_dir(WORLD)
	var found: Dictionary = {}
	var lists: Array = [_npc_part(_read_json(base.path_join(SaveService.WORLD_STATE_FILE))).get(NpcService.KEY_NPCS, [])]
	for cell_id: String in save.saved_cell_ids(WORLD):
		var cell: Dictionary = _read_json(base.path_join(SaveService.cell_file(cell_id)))
		lists.append(((cell["systems"] as Dictionary).get(NpcService.SYSTEM_ID, {}) as Dictionary).get(NpcService.KEY_NPCS, []))
	for list: Array in lists:
		for npc: Dictionary in list:
			var npc_id: String = str(npc[NpcState.KEY_NPC_ID])
			if found.has(npc_id):
				fail("%s is on disk twice" % npc_id)
			found[npc_id] = npc
	return found


## Brings the building cells of the shipped map into memory and returns the
## player standing there.
func _enter_town(world: ServerWorld, player_key: String = "alice") -> PlayerState:
	var player: PlayerState = world.join(player_key)
	_move(world, player, TOWN)
	return player


# ------------------------------------------------------------ cells

func test_npcs_leave_memory_with_their_cell_and_come_back_identical() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var service: NpcService = _npcs(world)
	var alice: PlayerState = world.join("alice")
	_run(world, 1.0)
	var nurse_id: String = _spawn(world, NURSE, BESIDE, 0.75)
	var builder_id: String = _spawn(world, BUILDER, SPAWN, -1.5)
	service.get_npc(nurse_id).rng.randf()
	(service.get_npc(nurse_id).component(COUNTER) as CounterComponent).value = 12
	assert_true(service.is_awake(nurse_id))
	assert_eq(float(service.npc_document(nurse_id)[NpcState.KEY_LAST_SIMULATED]), world.clock.world_time_sec, "an awake NPC is simulated until now")
	# The player leaves: the cell stops being simulated, is saved and released.
	_move(world, alice, FAR)
	assert_false(service.is_awake(nurse_id), "an NPC of a cell that is not simulated is frozen")
	assert_eq(service.get_npc(nurse_id).simulation_tier, NpcState.TIER_FROZEN)
	var frozen_at: float = world.clock.world_time_sec
	assert_eq(service.get_npc(nurse_id).last_simulated_world_time, frozen_at, "it remembers until when it was simulated (docs/13 §16.3 D4)")
	var before: Dictionary = _saved(world)
	_run(world, RELEASE_SEC)
	assert_true(world.clock.world_time_sec > frozen_at)
	assert_eq(service.npc_count(), 0, "the cell left memory, and its NPCs with it")
	assert_eq(service.population_count(), 2, "they still exist")
	assert_eq(service.population_ids(), PackedStringArray([nurse_id, builder_id]))
	assert_false(world.registry.has(nurse_id), "the id is released...")
	assert_false(world.registry.is_tombstoned(nurse_id), "...not retired")
	assert_false(world.cell_index.has(nurse_id))
	var document: Dictionary = store.document_of(HOME_CELL)
	var saved_npcs: Array = ((document[WorldCellDocument.KEY_SYSTEMS] as Dictionary)[NpcService.SYSTEM_ID] as Dictionary)[NpcService.KEY_NPCS]
	assert_eq(saved_npcs.size(), 2, "saved in the cell document")
	assert_eq(float(saved_npcs[0][NpcState.KEY_LAST_SIMULATED]), frozen_at, "a frozen NPC keeps the time it was frozen at")
	assert_true(SaveService.is_json_safe(document))
	assert_eq(service.remove_npc(world, nurse_id).reason, NpcService.REASON_UNKNOWN_NPC, "an NPC that is not in memory cannot be acted on")
	# A new NPC cannot take an id of one that is not in memory.
	var other_id: String = _spawn(world, NURSE, BESIDE_FAR)
	assert_false(before.has(other_id))
	assert_eq(service.population_count(), 3)
	# The player comes back: the same NPCs, exactly.
	_move(world, alice, SPAWN)
	assert_true(service.has_npc(nurse_id) and service.has_npc(builder_id))
	assert_true(service.is_awake(nurse_id))
	assert_eq(world.cell_index.cell_of(nurse_id), HOME_CELL)
	assert_eq(world.registry.kind_of(nurse_id), KIND)
	assert_eq((service.get_npc(nurse_id).component(COUNTER) as CounterComponent).value, 12)
	var after: Dictionary = _saved(world)
	after.erase(other_id)
	assert_true(_same(after, before), "id, definition, position, facing, generator and components are the same")
	assert_eq(service.get_npc(nurse_id).rng.state, str(before[nurse_id][NpcState.KEY_RNG_STATE]).to_int())
	assert_eq(service.get_npc(nurse_id).last_simulated_world_time, frozen_at, "nothing caught up yet (docs/16 K)")
	# Loading the cell again and again doubles nothing.
	for round_index: int in range(3):
		_move(world, alice, FAR, RELEASE_SEC)
		_move(world, alice, SPAWN)
	assert_eq(service.npc_ids_in_cell(HOME_CELL).size(), 2)
	assert_eq(service.population_count(), 3)


func test_the_whole_world_survives_a_document_round_trip() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var service: NpcService = _npcs(world)
	var alice: PlayerState = world.join("alice")
	_run(world, 1.0)
	var nurse_id: String = _spawn(world, NURSE, BESIDE, 0.75)
	(service.get_npc(nurse_id).component(COUNTER) as CounterComponent).value = 3
	_move(world, alice, FAR, RELEASE_SEC)
	var builder_id: String = _spawn(world, BUILDER, BESIDE_FAR)
	var sequence: int = world.ids.get_next_sequence()
	# One NPC is in a released cell, the other in memory (a memory store
	# saves those in the world document).
	var documents: Dictionary = world.to_documents()
	assert_eq((_npc_part(documents["world_state"])[NpcService.KEY_NPCS] as Array).size(), 1)
	assert_eq((documents["cells"] as Dictionary).keys(), [HOME_CELL])
	var restored: ServerWorld = _world(WorldCellStore.new())
	assert_eq(restored.restore_documents(_json(documents["world_state"]), _json(documents["players"]), _json(documents["cells"])).size(), 0)
	var restored_service: NpcService = _npcs(restored)
	assert_eq(restored_service.population_count(), 2)
	assert_eq(restored_service.npc_ids(), PackedStringArray([builder_id]), "the released cell stays released")
	assert_eq(restored.ids.get_next_sequence(), sequence, "no saved id can be handed out again")
	var alice2: PlayerState = restored.join("alice")
	_move(restored, alice2, SPAWN)
	assert_true(restored_service.has_npc(nurse_id))
	assert_eq((restored_service.get_npc(nurse_id).component(COUNTER) as CounterComponent).value, 3)
	assert_eq(restored_service.get_npc(nurse_id).yaw, 0.75)
	assert_ne(_spawn(restored, NURSE, BESIDE), nurse_id)
	# A second round trip gives the same documents: nothing drifts.
	var again: Dictionary = restored.to_documents()
	var third: ServerWorld = _world(WorldCellStore.new())
	assert_eq(third.restore_documents(_json(again["world_state"]), _json(again["players"]), _json(again["cells"])).size(), 0)
	assert_true(_same(_json(third.to_documents()["world_state"])["systems"][NpcService.SYSTEM_ID], _json(again["world_state"])["systems"][NpcService.SYSTEM_ID]))


func test_a_world_without_a_cell_store_saves_its_npcs_in_the_world_document() -> void:
	var world: ServerWorld = _world(null)
	world.join("alice")
	_run(world, TICK)
	var nurse_id: String = _spawn(world, NURSE, BESIDE)
	var documents: Dictionary = world.to_documents()
	assert_eq((documents["cells"] as Dictionary).size(), 0)
	var part: Dictionary = _npc_part(documents["world_state"])
	assert_eq(int(part["schema_version"]), NpcService.SCHEMA_VERSION)
	assert_eq((part[NpcService.KEY_NPCS] as Array).size(), 1)
	var restored: ServerWorld = _world(null)
	assert_eq(restored.restore_documents(_json(documents["world_state"]), _json(documents["players"])).size(), 0)
	assert_true(_same(_saved(restored), _saved(world)))
	assert_eq(restored.cell_index.cell_of(nurse_id), HOME_CELL, "the cell is decided by the position")
	assert_false(_npcs(restored).is_awake(nurse_id), "nobody is near: not simulated")


func test_stale_and_broken_documents_never_double_or_revive_an_npc() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var service: NpcService = _npcs(world)
	var alice: PlayerState = world.join("alice")
	_run(world, TICK)
	var nurse_id: String = _spawn(world, NURSE, BESIDE)
	var builder_id: String = _spawn(world, BUILDER, SPAWN)
	var old_cell: Dictionary = _json(world.cell_document(HOME_CELL))
	var npc_part: Dictionary = (old_cell[WorldCellDocument.KEY_SYSTEMS] as Dictionary)[NpcService.SYSTEM_ID]
	# In memory wins over a saved copy; a retired NPC stays gone.
	service.set_npc_transform(world, nurse_id, Vector3(8.0, 0.0, 8.0), 2.0)
	service.remove_npc(world, builder_id)
	assert_eq(service.restore_cell_document(world, HOME_CELL, npc_part).size(), 0)
	assert_eq(service.npc_ids(), PackedStringArray([nurse_id]))
	assert_eq(service.get_npc(nurse_id).position, Vector3(8.0, 0.0, 8.0), "the state in memory was not replaced")
	assert_contains(_log_text(), "saved npcs skipped")
	# Broken documents: validated first, nothing changes.
	_move(world, alice, FAR, RELEASE_SEC)
	assert_eq(service.npc_count(), 0)
	for broken: Dictionary in [
		{"schema_version": 99, NpcService.KEY_NPCS: []},
		{"schema_version": NpcService.CELL_SCHEMA_VERSION, NpcService.KEY_NPCS: "none"},
		{"schema_version": NpcService.CELL_SCHEMA_VERSION, NpcService.KEY_NPCS: [npc_part[NpcService.KEY_NPCS][0], {"npc_id": 5}]},
		{"schema_version": NpcService.CELL_SCHEMA_VERSION, NpcService.KEY_NPCS: [npc_part[NpcService.KEY_NPCS][0], npc_part[NpcService.KEY_NPCS][0]]},
	]:
		assert_true(service.restore_cell_document(world, HOME_CELL, _json(broken)).size() > 0)
		assert_eq(service.npc_count(), 0, "nothing came into memory")
		assert_false(world.registry.has(nurse_id))
	var unknown: Dictionary = _json(npc_part)
	(unknown[NpcService.KEY_NPCS] as Array)[0][NpcState.KEY_DEFINITION_ID] = "t41p_gone"
	assert_contains("; ".join(service.restore_cell_document(world, HOME_CELL, unknown)), "unknown definition")
	var outside: Dictionary = _json(npc_part)
	(outside[NpcService.KEY_NPCS] as Array)[0][NpcState.KEY_POSITION] = [500.0, 0.0, 0.0]
	assert_contains("; ".join(service.restore_cell_document(world, HOME_CELL, outside)), "outside the play area")
	assert_eq(service.npc_count(), 0)
	# The real cell still loads.
	_move(world, alice, SPAWN)
	assert_eq(service.npc_ids(), PackedStringArray([nurse_id]))
	# A broken world document is refused whole.
	for broken_world: Dictionary in [
		{"schema_version": 99},
		{"schema_version": NpcService.SCHEMA_VERSION, NpcService.KEY_POPULATION: [], NpcService.KEY_ROSTERS: {}, NpcService.KEY_NPCS: []},
		{"schema_version": NpcService.SCHEMA_VERSION, NpcService.KEY_POPULATION: {"zombie_000001": NURSE}, NpcService.KEY_ROSTERS: {}, NpcService.KEY_NPCS: []},
		{"schema_version": NpcService.SCHEMA_VERSION, NpcService.KEY_POPULATION: {}, NpcService.KEY_ROSTERS: {"r": {"complete": "yes"}}, NpcService.KEY_NPCS: []},
		{"schema_version": NpcService.SCHEMA_VERSION, NpcService.KEY_POPULATION: {}, NpcService.KEY_ROSTERS: {}, NpcService.KEY_NPCS: [{"npc_id": "npc_000001"}]},
	]:
		var fresh: ServerWorld = _world(WorldCellStore.new())
		assert_true(_npcs(fresh).restore_world_document(broken_world).size() > 0)
		assert_eq(_npcs(fresh).population_count(), 0)


func test_the_population_limit_counts_npcs_that_are_not_in_memory() -> void:
	var config: CompositionConfig = _config()
	config.npc.max_npcs = 2
	var world: ServerWorld = _world(WorldCellStore.new(), config)
	var service: NpcService = _npcs(world)
	var alice: PlayerState = world.join("alice")
	_run(world, TICK)
	_spawn(world, NURSE, BESIDE)
	_spawn(world, BUILDER, SPAWN)
	_move(world, alice, FAR, RELEASE_SEC)
	assert_eq(service.npc_count(), 0)
	assert_eq(service.spawn_npc(world, NURSE, BESIDE_FAR).reason, NpcService.REASON_LIMIT, "the limit is for the whole world")


# ------------------------------------------------------------ seeding

func test_the_dev_roster_is_placed_once_in_buildings_of_the_test_map() -> void:
	var config: CompositionConfig = _shipped_config()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store, config, false)
	assert_eq(world.seed_new_world(DevWorldSeed.new()), OK)
	var service: NpcService = _npcs(world)
	assert_true(service.is_seeded(), "a new world gets the roster")
	assert_eq(service.population_count(), 10)
	assert_eq(service.seeded_npc_ids(ROSTER_ID).size(), 10)
	assert_eq(int(service.last_seed_report[NpcService.REPORT_NPCS]), 10)
	assert_eq(service.npc_count(), 0, "the cells the seeding loaded were saved and released again")
	_enter_town(world)
	assert_eq(service.npc_count(), 10, "the ten are in the middle of the map")
	var grid: StructureGrid = StructureGrid.new(config.building.grid_module_m)
	var seen_definitions: Dictionary[String, bool] = {}
	for npc_id: String in service.npc_ids():
		var npc: NpcState = service.get_npc(npc_id)
		var definition: NpcDefinition = config.npc_definitions.get_definition(npc.definition_id)
		seen_definitions[npc.definition_id] = true
		var home: Vector3 = NpcRoster.spot_position(config.map_content, grid, definition.home_building_id, definition.home_tile_offset)
		assert_eq(npc.position, home, "%s stands on its home spot" % npc.definition_id)
		var building: MapBuildingDefinition = null
		for candidate: MapBuildingDefinition in config.map_content.buildings:
			if candidate.building_id == definition.home_building_id:
				building = candidate
		assert_true(MapBuildingPlan.footprint(building).has_point(grid.tile_of(npc.position)), "inside the building")
		assert_eq(npc.rng.seed, NpcState.seed_for(config.npc.world_seed, npc_id))
		assert_eq(service.seeded_npc_id(ROSTER_ID, npc.definition_id), npc_id)
	assert_eq(seen_definitions.size(), 10, "one NPC per definition of the roster")
	# Asking again places nothing: not now, not after cells came and went,
	# not after a restart.
	var sequence: int = world.ids.get_next_sequence()
	assert_eq(service.ensure_seeded(world), OK)
	assert_eq(world.ids.get_next_sequence(), sequence, "no id was spent: nobody was placed")
	var before: Dictionary = _saved(world)
	var documents: Dictionary = world.to_documents()
	var record: Dictionary = (_npc_part(documents["world_state"])[NpcService.KEY_ROSTERS] as Dictionary)[ROSTER_ID]
	assert_true(record[NpcService.KEY_COMPLETE], "the world state records that the roster was placed")
	var restored: ServerWorld = _world(WorldCellStore.new(), config, false)
	assert_eq(restored.restore_documents(_json(documents["world_state"]), _json(documents["players"]), _json(documents["cells"])).size(), 0)
	assert_true(_npcs(restored).is_seeded())
	assert_eq(_npcs(restored).ensure_seeded(restored), OK)
	assert_eq(restored.ids.get_next_sequence(), sequence, "a restart places nobody")
	assert_eq(_npcs(restored).population_count(), 10)
	assert_eq(_npcs(restored).last_seed_report.size(), 0, "the restored world never placed anybody")
	var alice2: PlayerState = restored.join("alice")
	_move(restored, alice2, TOWN)
	assert_true(_same(_saved(restored), before), "the same ten after the restart")


func test_a_world_saved_before_the_roster_gets_it_once() -> void:
	# A world played without NPCs.
	var old_config: CompositionConfig = _shipped_config(false)
	var old_world: ServerWorld = _world(WorldCellStore.new(), old_config, false)
	assert_eq(old_world.seed_new_world(DevWorldSeed.new()), OK)
	var documents: Dictionary = old_world.to_documents()
	assert_false((documents["world_state"]["systems"] as Dictionary).has(NpcService.SYSTEM_ID), "the old save knows nothing of NPCs")
	# The same save, started by a server that has the roster.
	var config: CompositionConfig = _shipped_config()
	var world: ServerWorld = _world(WorldCellStore.new(), config, false)
	assert_eq(world.restore_documents(_json(documents["world_state"]), _json(documents["players"]), _json(documents["cells"])).size(), 0, "the old save loads")
	var service: NpcService = _npcs(world)
	assert_false(service.is_seeded())
	assert_eq(service.ensure_seeded(world), OK)
	assert_true(service.is_seeded())
	assert_eq(service.population_count(), 10)
	var sequence: int = world.ids.get_next_sequence()
	assert_eq(service.ensure_seeded(world), OK)
	assert_eq(world.ids.get_next_sequence(), sequence, "once: the second start places nobody")
	# An interrupted seeding goes on where it stopped and doubles nobody.
	var interrupted: Dictionary = _json(world.to_documents())
	var record: Dictionary = (_npc_part(interrupted["world_state"])[NpcService.KEY_ROSTERS] as Dictionary)[ROSTER_ID]
	record[NpcService.KEY_COMPLETE] = false
	var resumed: ServerWorld = _world(WorldCellStore.new(), config, false)
	assert_eq(resumed.restore_documents(interrupted["world_state"], interrupted["players"], interrupted["cells"]).size(), 0)
	assert_false(_npcs(resumed).is_seeded())
	assert_eq(_npcs(resumed).ensure_seeded(resumed), OK)
	assert_true(_npcs(resumed).is_seeded())
	assert_eq(int(_npcs(resumed).last_seed_report[NpcService.REPORT_NPCS]), 0, "everybody the record lists is there already")
	assert_eq(_npcs(resumed).population_count(), 10)
	# A world without a roster places nobody and says so.
	assert_eq(_npcs(old_world).ensure_seeded(old_world), OK)
	assert_eq(_npcs(old_world).population_count(), 0)
	assert_false(_npcs(old_world).is_seeded())


# ------------------------------------------------------------ real files

func test_seeded_npcs_survive_cell_unloads_and_server_restarts_on_disk() -> void:
	var config: CompositionConfig = _shipped_config()
	var world: ServerWorld = _boot(config)
	assert_not_null(world)
	if world == null:
		return
	assert_eq(_npcs(world).npc_count(), 0, "a server start brings no cell into memory")
	assert_eq(_npcs(world).population_count(), 10)
	var on_disk: Dictionary = _npcs_on_disk()
	assert_eq(on_disk.size(), 10, "the new world was saved with its ten NPCs, each once")
	var alice: PlayerState = _enter_town(world)
	var sequence: int = world.ids.get_next_sequence()
	var before: Dictionary = _saved(world)
	assert_eq(before.size(), 10)
	var ids: PackedStringArray = _npcs(world).npc_ids()

	# 1. A save with the cells in memory, then a restart.
	assert_eq(WorldPersistence.new(_save_service(), config).save(world), OK)
	var world_file: Dictionary = _read_json(_save_service().world_dir(WORLD).path_join(SaveService.WORLD_STATE_FILE))
	assert_false(_npc_part(world_file).has(NpcService.KEY_NPCS), "NPCs of cells in memory are saved in their cell files, not in the world file")
	assert_eq((_npc_part(world_file)[NpcService.KEY_POPULATION] as Dictionary).size(), 10)
	assert_eq(_npcs_on_disk().size(), 10)
	var second: ServerWorld = _boot(config)
	assert_not_null(second, "the save loads")
	if second == null:
		return
	assert_eq(_npcs(second).npc_count(), 0)
	assert_eq(_npcs(second).population_count(), 10)
	assert_true(_npcs(second).is_seeded())
	assert_eq(second.ids.get_next_sequence(), sequence, "the restart placed nobody and no saved id can be handed out again")
	var alice2: PlayerState = second.join("alice")
	_move(second, alice2, TOWN)
	assert_eq(_npcs(second).npc_ids(), ids)
	assert_true(_same(_saved(second), before), "the same ten NPCs after a restart")

	# 2. The cells are released (the unload saves the world), then a restart.
	_move(second, alice2, CORNER, SHIPPED_RELEASE_SEC)
	assert_eq(_npcs(second).npc_count(), 0, "the town cells were released")
	assert_eq(_npcs_on_disk().size(), 10, "every NPC is on disk once, whichever cells are in memory")
	var third: ServerWorld = _boot(config)
	assert_not_null(third)
	if third == null:
		return
	assert_eq(third.ids.get_next_sequence(), sequence)
	var alice3: PlayerState = third.join("alice")
	_move(third, alice3, TOWN)
	assert_true(_same(_saved(third), before), "the same ten NPCs after an unload and a restart")
	for npc_id: String in ids:
		assert_eq(third.registry.kind_of(npc_id), KIND)
	assert_eq(_npcs(third).population_count(), 10, "no NPC was placed a second time")
	assert_false(_log_text().contains("[ERROR]"), "no errors on the way")
	assert_true(alice.player_id == alice3.player_id)


func test_a_save_on_disk_from_before_the_roster_gets_its_npcs_at_the_next_start() -> void:
	# A world a server ran without NPCs (the saves from before this ticket).
	var old_world: ServerWorld = _boot(_shipped_config(false))
	assert_not_null(old_world)
	if old_world == null:
		return
	assert_eq(_npcs_on_disk().size(), 0)
	assert_eq(_npcs(old_world).population_count(), 0)
	# The next start has the roster: the NPCs are placed and saved at once.
	var config: CompositionConfig = _shipped_config()
	var world: ServerWorld = _boot(config)
	assert_not_null(world, "the old save loads")
	if world == null:
		return
	assert_true(_npcs(world).is_seeded())
	assert_eq(_npcs(world).population_count(), 10)
	assert_eq(_npcs(world).npc_count(), 0, "the cells the seeding loaded were saved and released")
	var on_disk: Dictionary = _npcs_on_disk()
	assert_eq(on_disk.size(), 10, "what was placed is on disk before anybody joins")
	var sequence: int = world.ids.get_next_sequence()
	# And never again.
	var again: ServerWorld = _boot(config)
	assert_not_null(again)
	if again == null:
		return
	assert_eq(again.ids.get_next_sequence(), sequence, "the second start places nobody")
	assert_eq(_npcs(again).population_count(), 10)
	assert_true(_same(_npcs_on_disk(), on_disk), "and changes nothing on disk")
