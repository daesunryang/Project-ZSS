extends TestCase
## P3-4a: structures in a real world save (docs/10, docs/09 §15.1, §15.4):
## save -> process "restart" (a brand-new world object from disk) ->
## restore, with some cells in memory and some released; a save from before
## structures existed; a changed cell grid. The same through the network:
## tests/integration/structure_net_test.gd.

const WORLD: String = "building_persist_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const TOLERANCE: float = 0.000001
const FLOOR: String = "dev_floor"
const WALL: String = "dev_wall"
const DOOR: String = "dev_door"
const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X
const HOME: Vector3 = Vector3(25.5, 0.0, 25.5)
const AWAY: Vector3 = Vector3(-44.5, 0.0, -34.5)
## Standing in these four cells (one after the other) brings every cell of
## the 10 x 10 test map into memory once.
const TOUR: Array[Vector3] = [Vector3(-25.0, 0.0, -25.0), Vector3(-25.0, 0.0, 25.0), Vector3(25.0, 0.0, -25.0), Vector3(25.0, 0.0, 25.0)]

var _root: String = ""
var _settings: WorldCellSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/building_persist_%d" % Time.get_ticks_usec()
	# 10 m cells on a 100 m map. Only the player's own cell is simulated, two
	# rings are kept in memory, cells are released one second after they are
	# no longer wanted.
	_settings = WorldCellSettings.new()
	_settings.cell_size_m = 10.0
	_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_settings.bounds_max_m = Vector2(50.0, 50.0)
	_settings.active_radius_cells = 0
	_settings.preload_radius_cells = 2
	_settings.preload_lookahead_sec = 0.0
	_settings.deactivate_delay_sec = 0.0
	_settings.unload_delay_sec = 1.0
	_settings.refresh_period_sec = 0.0
	_settings.max_preload_loads_per_refresh = 1000


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = HOME
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.building = BuildingSettings.new()
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = _settings
	return config


func _save_service() -> SaveService:
	return SaveService.new(_root)


func _persistence() -> WorldPersistence:
	return WorldPersistence.new(_save_service(), _config())


## A server start: a brand-new world object built from what is on disk.
func _boot() -> ServerWorld:
	return _persistence().load_or_create(WORLD)


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _move(world: ServerWorld, player: PlayerState, position: Vector3, seconds: float = TICK) -> void:
	player.position = position
	_run(world, seconds)


func _place(world: ServerWorld, definition_id: String, tile: Vector2i, rotation: int, placed_by: String = "") -> String:
	var result: ActionResult = _building(world).place_structure(world, definition_id, tile, rotation, placed_by)
	if not result.ok:
		fail("test setup: %s at %s was refused: %s" % [definition_id, str(tile), result.reason])
	return str(result.event.get(BuildingService.KEY_STRUCTURE_ID, ""))


## Save data of every structure that is in memory now, by id.
func _in_memory(world: ServerWorld) -> Dictionary:
	var service: BuildingService = _building(world)
	var result: Dictionary = {}
	for structure_id: String in service.structure_ids():
		result[structure_id] = service.get_structure(structure_id).to_dict()
	return result


## Walks a player through the whole map and returns every structure that
## came into memory on the way.
func _tour(world: ServerWorld, player: PlayerState) -> Dictionary:
	var seen: Dictionary = {}
	for stop: Vector3 in TOUR:
		_move(world, player, stop)
		seen.merge(_in_memory(world), true)
	return seen


func _read_json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary


func _world_state_file() -> Dictionary:
	return _read_json(_save_service().world_dir(WORLD).path_join(SaveService.WORLD_STATE_FILE))


func _cell_file(cell_id: String) -> Dictionary:
	return _read_json(_save_service().world_dir(WORLD).path_join(SaveService.cell_file(cell_id)))


## The structures saved in one cell file ([] = none).
func _structures_in_file(cell_id: String) -> Array:
	var systems: Dictionary = _cell_file(cell_id).get("systems", {})
	return (systems.get(BuildingService.SYSTEM_ID, {}) as Dictionary).get(BuildingService.KEY_STRUCTURES, [])


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


func test_structures_survive_a_restart_with_some_cells_in_memory_and_some_released() -> void:
	var first: ServerWorld = _boot()
	assert_not_null(first)
	var persistence: WorldPersistence = _persistence()
	var service: BuildingService = _building(first)
	var alice: PlayerState = first.join("alice")
	_run(first, 2.0)
	# Far from home: these are released (and so saved) before the shutdown.
	_move(first, alice, AWAY)
	var far_wall: String = _place(first, WALL, Vector2i(-45, -33), 0, alice.player_id)
	var far_door: String = _place(first, DOOR, Vector2i(-43, -35), 1)
	assert_true(service.set_door_open(first, far_door, true).ok)
	_move(first, alice, HOME, 2.0)
	assert_eq(_cells(first).state_of("cell_-5_-4"), WorldCellLifecycle.State.UNLOADED, "the far cells were released (and saved)")
	assert_false(service.has_structure(far_wall))
	assert_eq(_structures_in_file("cell_-5_-4").size(), 2, "they are in their cell's file")
	# At home: these are in memory when the server shuts down.
	var near_floor: String = _place(first, FLOOR, Vector2i(25, 25), 1)
	var near_wall: String = _place(first, WALL, Vector2i(26, 25), 1, alice.player_id)
	var near_door: String = _place(first, DOOR, Vector2i(26, 26), 1)
	var demolished: String = _place(first, WALL, Vector2i(26, 27), 1)
	assert_true(service.remove_structure(first, demolished).ok)
	# An edge on a cell border: x = 30 between cell (2, 2) and cell (3, 2).
	var border_wall: String = _place(first, WALL, Vector2i(29, 25), 1)
	var near_before: Dictionary = _in_memory(first)
	assert_eq(near_before.size(), 4)
	var far_before: Dictionary = {far_wall: _structures_in_file("cell_-5_-4")[0], far_door: _structures_in_file("cell_-5_-4")[1]}
	# The shutdown save.
	assert_eq(persistence.save(first), OK)
	# On disk: every structure is in exactly one cell file, none in world_state.
	assert_false((_world_state_file()["systems"] as Dictionary).has(BuildingService.SYSTEM_ID), "a saved world keeps structures in cell files only")
	var in_files: int = 0
	for cell_id: String in _save_service().saved_cell_ids(WORLD):
		for entry: Variant in _structures_in_file(cell_id):
			assert_eq((entry as Dictionary)["cell_id"], cell_id, "a structure is in the file of its own cell")
			in_files += 1
	assert_eq(in_files, 6)
	assert_eq(_structures_in_file("cell_3_2").size(), 1, "the border wall is saved with the cell on its high side")
	assert_eq(int(((_cell_file("cell_2_2")["systems"] as Dictionary)[BuildingService.SYSTEM_ID] as Dictionary)["schema_version"]), BuildingService.CELL_SCHEMA_VERSION)

	# Restart: nothing of the world is in memory.
	var second: ServerWorld = _boot()
	assert_not_null(second)
	var restored: BuildingService = _building(second)
	assert_eq(restored.structure_count(), 0)
	assert_eq(second.ids.get_next_sequence(), first.ids.get_next_sequence(), "the ids of saved structures stay reserved")
	var player: PlayerState = second.join("alice")
	assert_eq(player.player_id, alice.player_id)
	# The player is at home: the cells around it are in memory.
	assert_true(_same(_in_memory(second), near_before), "the structures at home are back exactly as they were")
	assert_false(restored.has_structure(far_wall), "a structure in a far cell is not in memory")
	assert_false(restored.has_structure(demolished))
	assert_true(second.registry.is_tombstoned(demolished), "a demolished structure stays gone for good")
	assert_true(restored.is_edge_blocked(Vector3i(27, 25, LOW_X)), "the restored wall blocks")
	assert_true(restored.is_edge_blocked(Vector3i(27, 26, LOW_X)), "and the closed door")
	assert_true(restored.is_edge_blocked(Vector3i(30, 25, LOW_X)), "and the wall on the cell border")
	assert_eq(second.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, Vector3(26.5, 0.0, 25.5), Vector3(27.5, 0.0, 25.5)).x < 27.0, true)
	assert_eq(second.cell_index.cell_of(border_wall), "cell_3_2")
	assert_eq(restored.structure_id_at(Vector3i(25, 25, StructureGrid.Layer.TILE)), near_floor)
	# The far ones come back when somebody goes there, as they were saved.
	var everything: Dictionary = _tour(second, player)
	assert_eq(everything.size(), 6)
	assert_true(_same(everything[far_wall], far_before[far_wall]) and _same(everything[far_door], far_before[far_door]), "the far structures are back as they were saved")
	_move(second, player, AWAY)
	assert_true(restored.get_structure(far_door).door_open, "the far door is still open")
	assert_eq(restored.get_structure(far_wall).placed_by, alice.player_id)
	# The world goes on: taken slots stay taken, new structures get new ids,
	# and the placer still owns the wall.
	assert_eq(restored.place_structure(second, WALL, Vector2i(-45, -33), 0).reason, BuildingService.REASON_SLOT_OCCUPIED)
	var fresh: String = _place(second, FLOOR, Vector2i(-45, -33), 0)
	assert_false(everything.has(fresh) or fresh == demolished)
	assert_true(restored.try_demolish(second, player.player_id, far_wall).ok)
	assert_eq(near_door.is_empty(), false)


func test_a_save_from_before_structures_loads_and_can_be_built_in() -> void:
	var first: ServerWorld = _boot()
	assert_not_null(first)
	var alice: PlayerState = first.join("alice")
	first.inventory.spawn_world_item("dev_test_item", 1, first.cell_id_at(HOME), HOME)
	assert_eq(_persistence().save(first), OK)
	# A world without structures writes nothing about them: these files are
	# what a save from before P3-4a looks like.
	assert_false((_world_state_file()["systems"] as Dictionary).has(BuildingService.SYSTEM_ID))
	for cell_id: String in _save_service().saved_cell_ids(WORLD):
		assert_false((_cell_file(cell_id)["systems"] as Dictionary).has(BuildingService.SYSTEM_ID), cell_id)
	assert_true(_save_service().saved_cell_ids(WORLD).size() > 0)
	var second: ServerWorld = _boot()
	assert_not_null(second, "the older save loads")
	var player: PlayerState = second.join("alice")
	assert_eq(player.player_id, alice.player_id)
	assert_eq(_building(second).structure_count(), 0)
	assert_eq(second.inventory.world_item_ids().size() > 0, true, "its items are there")
	# Building in it and saving again adds the structure to the cell file.
	var wall_id: String = _place(second, WALL, Vector2i(26, 25), 1)
	assert_eq(_persistence().save(second), OK)
	assert_eq(_structures_in_file("cell_2_2").size(), 1)
	var third: ServerWorld = _boot()
	third.join("alice")
	assert_true(_building(third).has_structure(wall_id))


func test_a_changed_cell_grid_moves_structures_to_their_new_cells() -> void:
	var first: ServerWorld = _boot()
	var alice: PlayerState = first.join("alice")
	var near_wall: String = _place(first, WALL, Vector2i(26, 25), 1)
	_move(first, alice, AWAY)
	var far_door: String = _place(first, DOOR, Vector2i(-43, -35), 1)
	assert_true(_building(first).set_door_open(first, far_door, true).ok)
	_move(first, alice, HOME, 2.0)
	assert_eq(_persistence().save(first), OK)
	assert_eq(_structures_in_file("cell_2_2").size(), 1)
	assert_eq(_structures_in_file("cell_-5_-4").size(), 1)
	# The cell size is doubled: the save is cut again when the server starts.
	_settings.cell_size_m = 20.0
	var second: ServerWorld = _boot()
	assert_not_null(second, "the save was partitioned for the new grid")
	assert_eq(_structures_in_file("cell_1_1").size(), 1, "tile (26, 25) is in cell (1, 1) of the 20 m grid")
	assert_eq((_structures_in_file("cell_1_1")[0] as Dictionary)["cell_id"], "cell_1_1")
	assert_eq(_structures_in_file("cell_-3_-2").size(), 1)
	assert_false(_save_service().saved_cell_ids(WORLD).has("cell_-5_-4"), "the old cell files are gone")
	var third: ServerWorld = _boot()
	var player: PlayerState = third.join("alice")
	var everything: Dictionary = _tour(third, player)
	assert_eq(everything.size(), 2)
	assert_eq(third.cell_index.cell_of(near_wall) if _building(third).has_structure(near_wall) else "cell_1_1", "cell_1_1")
	_move(third, player, AWAY)
	assert_true(_building(third).get_structure(far_door).door_open)
	assert_eq(_building(third).get_structure(far_door).cell_id, "cell_-3_-2")
