extends TestCase
## P3-1: per-cell persistence through WorldPersistence and real files
## (docs/10, docs/09 §15.1): save -> process "restart" (a brand-new world
## object from disk) -> restore, with cells in memory and cells released;
## migration of a save from before cells; no regeneration; consistency of
## the generation an unload writes; re-partitioning; a corrupt cell file.

const WORLD: String = "cell_persist_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const TOLERANCE: float = 0.000001
## Standing in these four cells (one after the other) brings every cell of
## the 10 x 10 test map into memory once.
const TOUR: Array[Vector3] = [Vector3(-25.0, 0.0, -25.0), Vector3(-25.0, 0.0, 25.0), Vector3(25.0, 0.0, -25.0), Vector3(25.0, 0.0, 25.0)]

var _root: String = ""
var _settings: WorldCellSettings = null
var _zombie_settings: ZombieSettings = null
var _seed: DevWorldSeed = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/cell_persist_%d" % Time.get_ticks_usec()
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
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER
	_seed = DevWorldSeed.new()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = TOUR[3]
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.zombie = _zombie_settings
	config.dev_seed = _seed
	config.world_cells = _settings
	return config


func _save_service() -> SaveService:
	return SaveService.new(_root)


func _persistence() -> WorldPersistence:
	return WorldPersistence.new(_save_service(), _config())


## A server start: a brand-new world object built from what is on disk.
func _boot() -> ServerWorld:
	return _persistence().load_or_create(WORLD)


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _spawn_zombie(world: ServerWorld, position: Vector3, yaw: float = 0.0) -> String:
	return str(_zombies(world).spawn_zombie(world, position, yaw).event["zombie_id"])


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _move(world: ServerWorld, player_id: String, position: Vector3) -> void:
	world.get_player(player_id).position = position
	world.step_systems(TICK)


## Everything that lies in the world and is in memory now:
## {entity_id: save data (+ the position of an item)}.
func _in_memory(world: ServerWorld) -> Dictionary:
	var entities: Dictionary = {}
	for item_id: String in world.inventory.world_item_ids():
		var data: Dictionary = world.inventory.get_item(item_id).to_dict()
		var position: Vector3 = world.inventory.world_position_of(item_id)
		data["position"] = [position.x, position.y, position.z]
		entities[item_id] = data
	var zombies: ZombieService = _zombies(world)
	for zombie_id: String in zombies.zombie_ids():
		entities[zombie_id] = zombies.get_zombie(zombie_id).to_dict()
	return entities


## Walks a player through the whole map and returns every world entity
## that came into memory on the way. An entity seen twice must be the same.
func _tour(world: ServerWorld, player_id: String) -> Dictionary:
	var seen: Dictionary = {}
	for stop: Vector3 in TOUR:
		_move(world, player_id, stop)
		var here: Dictionary = _in_memory(world)
		for entity_id: String in here:
			if seen.has(entity_id) and not _approx_equal(seen[entity_id], here[entity_id]):
				fail("%s changed during the tour" % entity_id)
			seen[entity_id] = here[entity_id]
	return seen


func _read_json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary


func _world_state_file() -> Dictionary:
	return _read_json(_save_service().world_dir(WORLD).path_join(SaveService.WORLD_STATE_FILE))


func _cell_file(cell_id: String) -> Dictionary:
	return _read_json(_save_service().world_dir(WORLD).path_join(SaveService.cell_file(cell_id)))


## World items in the world document of the save on disk.
func _world_items_in_world_file() -> int:
	return ((_world_state_file()["inventory"] as Dictionary)["world_item_positions"] as Dictionary).size()


func _zombies_in_world_file() -> int:
	return ((((_world_state_file()["systems"] as Dictionary)["zombie"] as Dictionary)["zombies"]) as Array).size()


func _log_has(text: String) -> bool:
	for line: String in GameLogger.captured_lines():
		if line.contains(text):
			return true
	return false


func _approx_equal(a: Variant, b: Variant) -> bool:
	if (typeof(a) == TYPE_FLOAT or typeof(a) == TYPE_INT) and (typeof(b) == TYPE_FLOAT or typeof(b) == TYPE_INT):
		return absf(float(a) - float(b)) <= TOLERANCE
	if typeof(a) != typeof(b):
		return false
	if typeof(a) == TYPE_ARRAY:
		if (a as Array).size() != (b as Array).size():
			return false
		for index: int in range((a as Array).size()):
			if not _approx_equal(a[index], b[index]):
				return false
		return true
	if typeof(a) == TYPE_DICTIONARY:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for key: Variant in (a as Dictionary):
			if not (b as Dictionary).has(key) or not _approx_equal(a[key], b[key]):
				return false
		return true
	return a == b


func _assert_same_entities(actual: Dictionary, expected: Dictionary, context: String) -> void:
	var actual_ids: PackedStringArray = PackedStringArray(actual.keys())
	var expected_ids: PackedStringArray = PackedStringArray(expected.keys())
	actual_ids.sort()
	expected_ids.sort()
	assert_eq(actual_ids, expected_ids, context + ": the same entities")
	for entity_id: String in expected:
		if actual.has(entity_id):
			assert_true(_approx_equal(actual[entity_id], expected[entity_id]), "%s: %s is unchanged\n  expected %s\n  actual   %s" % [context, entity_id, str(expected[entity_id]), str(actual.get(entity_id, null))])


## A seed with items in three cells and zombies around the map centre.
func _use_scattered_seed() -> void:
	_seed.item_definition_ids = PackedStringArray(["dev_test_item", "dev_food_ration", "dev_water_bottle", "dev_bandage"])
	_seed.item_positions = PackedVector3Array([Vector3(22.0, 0.0, 21.0), Vector3(27.5, 0.0, 12.0), Vector3(-38.0, 0.0, -41.0), Vector3(-38.5, 0.0, -42.0)])
	_seed.item_quantities = PackedInt32Array([1, 3, 2, 1])
	_zombie_settings.dev_spawn_count = 6
	# Around the map centre: in none of the cells a test player stands in.
	_zombie_settings.dev_spawn_min_radius_m = 5.0
	_zombie_settings.dev_spawn_max_radius_m = 18.0


# ------------------------------------------------------------ new world, restart

func test_a_new_world_is_saved_in_cell_files_and_a_restart_loads_cells_on_demand() -> void:
	_use_scattered_seed()
	var first: ServerWorld = _boot()
	assert_not_null(first)
	var original: Dictionary = _in_memory(first)
	assert_eq(original.size(), 10, "4 seeded items and 6 zombies")
	# On disk: nothing of the world lies in world_state.json any more.
	var world_file: Dictionary = _world_state_file()
	assert_eq(int(world_file["schema_version"]), 4)
	assert_eq(_world_items_in_world_file(), 0)
	assert_eq(_zombies_in_world_file(), 0)
	assert_true(((world_file["systems"] as Dictionary)["world_cells"] as Dictionary).has("grid"))
	var save: SaveService = _save_service()
	var in_files: int = 0
	for cell_id: String in save.saved_cell_ids(WORLD):
		var document: Dictionary = _cell_file(cell_id)
		assert_eq(document["cell_id"], cell_id)
		assert_eq(int(document["schema_version"]), 1)
		in_files += ((document["world_items"] as Dictionary).get("items", []) as Array).size()
		in_files += ((((document["systems"] as Dictionary).get("zombie", {}) as Dictionary).get("zombies", [])) as Array).size()
	assert_eq(in_files, 10, "every entity is in exactly one cell file")
	assert_eq((_cell_file("cell_-4_-5")["world_items"] as Dictionary)["items"].size(), 2)

	# Restart: the world comes up with nothing of it in memory.
	var second: ServerWorld = _boot()
	assert_not_null(second)
	assert_eq(_in_memory(second).size(), 0)
	assert_eq(_cells(second).loaded_cell_ids().size(), 0)
	assert_eq(second.ids.get_next_sequence(), first.ids.get_next_sequence(), "ids of entities that are not in memory stay reserved")
	var player: PlayerState = second.join("alice")
	# The player stands in cell (2, 2): cells 0..4 are in memory.
	var near: Dictionary = _in_memory(second)
	assert_true(near.size() > 0 and near.size() < 10, "some of the world, not all of it: %d" % near.size())
	for entity_id: String in near:
		assert_true(_approx_equal(near[entity_id], original[entity_id]), entity_id)
	assert_eq(_cells(second).state_of("cell_-4_-5"), WorldCellLifecycle.State.UNLOADED)
	assert_null(second.inventory.get_item("item_000003"), "an item in a far cell is not in memory")
	_assert_same_entities(_tour(second, player.player_id), original, "after walking the whole map")
	assert_eq(second.ids.get_next_sequence() - first.ids.get_next_sequence(), 2, "only the new player and its inventory got ids")


func test_restart_with_some_cells_in_memory_and_some_released() -> void:
	var first: ServerWorld = _boot()
	var persistence: WorldPersistence = _persistence()
	var alice: PlayerState = first.join("alice")
	var zombies: ZombieService = _zombies(first)
	# Near the player (in memory), and far away (released a moment later).
	var near_item: String = first.inventory.spawn_world_item("dev_food_ration", 3, first.cell_id_at(Vector3(33.0, 0.0, 28.0)), Vector3(33.0, 0.0, 28.0))
	var taken_item: String = first.inventory.spawn_world_item("dev_test_item", 1, first.cell_id_at(Vector3(26.0, 0.0, 26.0)), Vector3(26.0, 0.0, 26.0))
	var near_zombie: String = _spawn_zombie(first, Vector3(41.0, 0.0, 33.0), 0.5)
	var far_item: String = first.inventory.spawn_world_item("dev_bandage", 2, first.cell_id_at(Vector3(-44.0, 0.0, -31.0)), Vector3(-44.0, 0.0, -31.0))
	var far_zombie: String = _spawn_zombie(first, Vector3(-41.0, 0.0, -36.0), -1.0)
	assert_true(zombies.apply_damage_to_zombie(far_zombie, 12.5, alice.player_id).ok)
	_run(first, 2.0)
	assert_eq(_cells(first).state_of("cell_-5_-4"), WorldCellLifecycle.State.UNLOADED, "the far cells were released (and saved)")
	assert_false(zombies.has_zombie(far_zombie))
	var far_expected: Dictionary = {far_item: _cell_file("cell_-5_-4")["world_items"]["items"][0], far_zombie: _cell_file("cell_-5_-4")["systems"]["zombie"]["zombies"][0]}
	# Things change in the cells that are in memory, then the server shuts down.
	assert_true(zombies.apply_damage_to_zombie(near_zombie, 40.0, alice.player_id).ok)
	assert_true(first.try_pickup(alice.player_id, taken_item).ok)
	var near_expected: Dictionary = _in_memory(first)
	assert_eq(near_expected.size(), 2)
	first.leave(alice.player_id)
	assert_eq(persistence.save(first), OK)
	assert_eq(float(_cell_file("cell_4_3")["systems"]["zombie"]["zombies"][0]["health"]), 60.0, "a full save flushes the cells that are in memory")

	var second: ServerWorld = _boot()
	assert_not_null(second)
	assert_eq(_in_memory(second).size(), 0)
	var back: PlayerState = second.join("alice")
	assert_eq(back.player_id, alice.player_id)
	_assert_same_entities(_in_memory(second), near_expected, "the cells that were in memory at the save")
	assert_eq(second.inventory.get_item(taken_item).location_type, ItemInstance.LOCATION_INVENTORY, "the picked-up item is carried, not lying around")
	assert_eq(second.inventory.items_in_inventory(back.inventory_id).size(), 1)
	_move(second, back.player_id, Vector3(-35.0, 0.0, -35.0))
	_run(second, 2.0)  # the cells around the spawn point are released
	var far_now: Dictionary = _in_memory(second)
	assert_true(_approx_equal(second.inventory.get_item(far_item).to_dict(), far_expected[far_item]), "the released item")
	assert_true(_approx_equal(far_now[far_zombie], far_expected[far_zombie]), "the released zombie, with the damage it had")
	assert_eq(float(far_now[far_zombie]["health"]), 87.5)
	assert_eq(far_now.size(), 2)


# ------------------------------------------------------------ old saves

func test_a_save_from_before_cells_is_migrated() -> void:
	# A world as Phase 2 wrote it: one document with every item and zombie,
	# schema 3, every world item in "cell_0_0", no cell system.
	var legacy_config: CompositionConfig = _config()
	var legacy: ServerWorld = ServerComposition.create_world(WORLD, legacy_config)
	legacy.seed_new_world(DevWorldSeed.new())
	var carrier: PlayerState = legacy.join("alice")
	var carried: String = legacy.inventory.spawn_world_item("dev_test_item", 1, "cell_0_0", carrier.position)
	assert_true(legacy.try_pickup(carrier.player_id, carried).ok)
	legacy.leave(carrier.player_id)
	for position: Vector3 in [Vector3(2.0, 0.0, 3.0), Vector3(-31.0, 0.0, 44.0), Vector3(47.0, 0.0, -47.5)]:
		legacy.inventory.spawn_world_item("dev_food_ration", 2, "cell_0_0", position)
	for position: Vector3 in [Vector3(12.0, 0.0, -18.0), Vector3(-45.0, 0.0, 41.0), Vector3(-9.0, 0.0, -9.0)]:
		_spawn_zombie(legacy, position, 1.0)
	var original: Dictionary = _in_memory(legacy)
	assert_eq(original.size(), 6)
	var documents: Dictionary = JSON.parse_string(JSON.stringify(legacy.to_documents()))
	var world_state: Dictionary = documents["world_state"]
	world_state["schema_version"] = 3
	(world_state["systems"] as Dictionary).erase("world_cells")
	assert_eq((documents["cells"] as Dictionary).size(), 0)
	assert_eq(_save_service().save_world(WORLD, world_state, documents["players"]), OK)
	assert_eq(_save_service().saved_cell_ids(WORLD).size(), 0, "an old save has no cell files")

	var world: ServerWorld = _boot()
	assert_not_null(world, "the old save loads")
	assert_eq(_in_memory(world).size(), 6, "its entities are in memory until their cells are sorted out")
	assert_eq(world.inventory.get_item("item_000005").location_id, "cell_-4_4", "every item got the cell of its position")
	var player: PlayerState = world.join("alice")
	assert_eq(player.player_id, carrier.player_id)
	assert_eq(world.inventory.get_item(carried).location_type, ItemInstance.LOCATION_INVENTORY)
	_run(world, 2.0)
	assert_true(_in_memory(world).size() < 6, "far cells were saved and released")
	assert_eq(int(_world_state_file()["schema_version"]), 4, "the first save writes the new layout")
	assert_eq(_world_items_in_world_file(), 0)
	assert_eq(_zombies_in_world_file(), 0)
	assert_true(_save_service().saved_cell_ids(WORLD).size() >= 5)
	# Expected: the same entities; only the cell id of the items follows the position now.
	var expected: Dictionary = original.duplicate(true)
	for entity_id: String in expected:
		if (expected[entity_id] as Dictionary).has("location_id"):
			var position: Array = expected[entity_id]["position"]
			expected[entity_id]["location_id"] = world.cell_id_at(Vector3(position[0], position[1], position[2]))
	_assert_same_entities(_tour(world, player.player_id), expected, "after the migration")
	world.leave(player.player_id)
	assert_eq(_persistence().save(world), OK)
	var again: ServerWorld = _boot()
	assert_eq(_in_memory(again).size(), 0)
	_assert_same_entities(_tour(again, again.join("alice").player_id), expected, "after a restart of the migrated save")


# ------------------------------------------------------------ no regeneration

func test_seeded_items_never_come_back() -> void:
	_seed.item_definition_ids = PackedStringArray(["dev_test_item", "dev_food_ration", "dev_water_bottle", "dev_bandage"])
	_seed.item_positions = PackedVector3Array([Vector3(26.0, 0.0, 25.0), Vector3(25.0, 0.0, 26.0), Vector3(24.0, 0.0, 25.0), Vector3(25.0, 0.0, 24.0)])
	var persistence: WorldPersistence = _persistence()
	var world: ServerWorld = persistence.load_or_create(WORLD)
	var alice: PlayerState = world.join("alice")
	var kept: String = "item_000001"
	var eaten: String = "item_000002"
	var moved: String = "item_000003"
	var left: String = "item_000004"
	for item_id: String in [kept, eaten, moved]:
		assert_true(world.try_pickup(alice.player_id, item_id).ok, item_id)
	assert_true(world.remove_player_item(alice.player_id, eaten, 1).ok, "used up")
	_move(world, alice.player_id, Vector3(-35.0, 0.0, -35.0))
	assert_true(world.try_drop_item(alice.player_id, moved).ok, "put down far away")
	# Three rounds of: the seed cell is released, the server restarts, the
	# cell is loaded again.
	for trip: int in range(3):
		_run(world, 2.0)
		assert_eq(_cells(world).state_of("cell_2_2"), WorldCellLifecycle.State.UNLOADED, "trip %d: the seed cell was released" % trip)
		world.leave(alice.player_id)
		assert_eq(persistence.save(world), OK)
		persistence = _persistence()
		world = persistence.load_or_create(WORLD)
		alice = world.join("alice")
		_move(world, alice.player_id, TOUR[3])
		_run(world, 2.0)
		assert_eq(world.inventory.world_item_ids(), PackedStringArray([left]), "trip %d: only the item nobody took lies at the seed point" % trip)
		assert_eq(world.inventory.items_in_inventory(alice.inventory_id).size(), 1)
		assert_eq(world.inventory.get_item(kept).location_id, alice.inventory_id)
		assert_null(world.inventory.get_item(eaten), "the used-up item is gone for good")
		assert_true(world.registry.is_tombstoned(eaten))
		_move(world, alice.player_id, Vector3(-35.0, 0.0, -35.0))
		_run(world, 2.0)
		assert_eq(world.inventory.world_item_ids(), PackedStringArray([moved]), "trip %d: the moved item lies where it was put" % trip)
	var everything: Dictionary = _tour(world, alice.player_id)
	assert_eq(everything.size(), 2, "two items lie in the world")
	assert_eq(world.inventory.item_count() - world.inventory.world_item_ids().size(), 1, "one is carried")


func test_a_cell_file_restored_from_an_older_backup_does_not_double_an_item() -> void:
	_seed.item_definition_ids = PackedStringArray(["dev_test_item", "dev_food_ration"])
	_seed.item_positions = PackedVector3Array([Vector3(26.0, 0.0, 25.0), Vector3(25.0, 0.0, 26.0)])
	var persistence: WorldPersistence = _persistence()
	var world: ServerWorld = persistence.load_or_create(WORLD)
	var alice: PlayerState = world.join("alice")
	assert_true(world.try_pickup(alice.player_id, "item_000001").ok)
	world.leave(alice.player_id)
	assert_eq(persistence.save(world), OK)
	assert_eq((_cell_file("cell_2_2")["world_items"]["items"] as Array).size(), 1)
	# The current cell file breaks; its newest readable copy is the one from
	# before the pickup (two items).
	var file: FileAccess = FileAccess.open(_save_service().world_dir(WORLD).path_join(SaveService.cell_file("cell_2_2")), FileAccess.WRITE)
	file.store_string("{ broken")
	file.close()
	var restarted: ServerWorld = _boot()
	var back: PlayerState = restarted.join("alice")
	assert_eq(_cells(restarted).state_of("cell_2_2"), WorldCellLifecycle.State.ACTIVE, "the cell loads from its backup")
	assert_eq(restarted.inventory.world_item_ids(), PackedStringArray(["item_000002"]), "the item alice carries is not put back into the world")
	assert_eq(restarted.inventory.get_item("item_000001").location_id, back.inventory_id)
	assert_eq(restarted.inventory.item_count(), 2)
	assert_true(_log_has("saved world items skipped"))


# ------------------------------------------------------------ consistency

func test_an_unload_writes_a_whole_consistent_generation() -> void:
	_settings.unload_delay_sec = 0.5
	var world: ServerWorld = _boot()
	var persistence: WorldPersistence = _persistence()
	var alice: PlayerState = world.join("alice")
	_move(world, alice.player_id, Vector3(1.0, 0.0, 5.0))
	_run(world, 1.0)  # the cells around the spawn point are released (and saved) first
	# A zombie in the player's cell, its back to the player, saved there.
	var zombie_id: String = _spawn_zombie(world, Vector3(8.0, 0.0, 5.0), ZombiePerception.yaw_towards(Vector3(1.0, 0.0, 0.0), 0.0))
	assert_eq(persistence.save(world), OK)
	assert_eq((_cell_file("cell_0_0")["systems"]["zombie"]["zombies"] as Array).size(), 1, "on disk it is in cell_0_0")
	var generation: int = _save_service().current_generation(WORLD)
	# It walks over the border into cell_1_0 and freezes there.
	assert_true((world.get_system(NoiseService.SYSTEM_ID) as NoiseService).emit("test_source", Vector3(18.0, 0.0, 5.0), 40.0, "broadband").ok)
	_run(world, 4.0)
	assert_eq(world.cell_index.cell_of(zombie_id), "cell_1_0")
	assert_eq(_save_service().current_generation(WORLD), generation, "nothing was saved meanwhile")
	var frozen: Dictionary = _zombies(world).get_zombie(zombie_id).to_dict()
	# The player walks away to the west: cell_1_0 is released, cell_0_0 stays in memory.
	_move(world, alice.player_id, Vector3(-15.0, 0.0, 5.0))
	_run(world, 1.0)
	assert_eq(_cells(world).state_of("cell_1_0"), WorldCellLifecycle.State.UNLOADED)
	assert_true(_cells(world).is_loaded("cell_0_0"))
	assert_true(_save_service().current_generation(WORLD) > generation, "releasing a cell saves")
	# The server dies here, without another save.
	var after_crash: ServerWorld = _boot()
	assert_not_null(after_crash)
	var seen: Dictionary = _tour(after_crash, after_crash.join("alice").player_id)
	assert_eq(seen.size(), 1, "the zombie exists exactly once: not lost, not in both cells")
	assert_true(_approx_equal(seen[zombie_id], frozen), "where and how it froze")
	assert_false(_save_service().saved_cell_ids(WORLD).has("cell_0_0"), "the cell it left has no file any more")


# ------------------------------------------------------------ grid change

func test_a_changed_cell_size_sorts_the_saved_world_again() -> void:
	_use_scattered_seed()
	var first: ServerWorld = _boot()
	var original: Dictionary = _in_memory(first)
	var old_cells: PackedStringArray = _save_service().saved_cell_ids(WORLD)
	assert_true(old_cells.has("cell_-4_-5"))
	# The same save, started with 20 m cells.
	_settings.cell_size_m = 20.0
	_settings.preload_radius_cells = 1
	var second: ServerWorld = _boot()
	assert_not_null(second, "the save still loads")
	assert_true(_log_has("another cell grid"))
	var new_cells: PackedStringArray = _save_service().saved_cell_ids(WORLD)
	assert_true(new_cells.has("cell_-2_-3"), "the two far items are in the 20 m cell of their position: " + str(new_cells))
	assert_false(new_cells.has("cell_-4_-5"), "no file of the old grid is left in the save")
	assert_eq((_cell_file("cell_-2_-3")["world_items"]["items"] as Array).size(), 2)
	assert_eq(float(_world_state_file()["systems"]["world_cells"]["grid"]["cell_size_m"]), 20.0)
	assert_eq(_world_items_in_world_file(), 0)
	var expected: Dictionary = original.duplicate(true)
	for entity_id: String in expected:
		if (expected[entity_id] as Dictionary).has("location_id"):
			var position: Array = expected[entity_id]["position"]
			expected[entity_id]["location_id"] = second.cell_id_at(Vector3(position[0], position[1], position[2]))
	# A restart with the same grid reads cells on demand again. Kept wide this
	# time, so the player's first look brings the whole map into memory (no
	# zombie stands in the spawn cell, so none of them is simulated).
	_settings.preload_radius_cells = 5
	var third: ServerWorld = _boot()
	assert_eq(_in_memory(third).size(), 0, "a restart with the same grid reads cells on demand again")
	assert_false(_cells(third).needs_repartition())
	third.join("alice")
	assert_eq(_zombies(third).simulated_count(), 0)
	_assert_same_entities(_in_memory(third), expected, "after the grid change")


# ------------------------------------------------------------ damage on disk

func test_a_corrupt_cell_file_keeps_that_cell_out_and_nothing_else() -> void:
	_seed.item_definition_ids = PackedStringArray(["dev_test_item", "dev_food_ration"])
	_seed.item_positions = PackedVector3Array([Vector3(26.0, 0.0, 25.0), Vector3(36.0, 0.0, 25.0)])
	assert_not_null(_boot())
	var save: SaveService = _save_service()
	var broken_path: String = save.world_dir(WORLD).path_join(SaveService.cell_file("cell_2_2"))
	var file: FileAccess = FileAccess.open(broken_path, FileAccess.WRITE)
	file.store_string("{ broken")
	file.close()
	var persistence: WorldPersistence = _persistence()
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world, "the world starts")
	var alice: PlayerState = world.join("alice")
	assert_eq(_cells(world).state_of("cell_2_2"), WorldCellLifecycle.State.UNLOADED, "the broken cell is not activated")
	assert_eq(_cells(world).state_of("cell_3_2"), WorldCellLifecycle.State.PRELOADED)
	assert_eq(world.inventory.world_item_ids(), PackedStringArray(["item_000002"]), "its neighbour is there")
	assert_true(_log_has("cell could not be loaded"))
	assert_true(_log_has("cell_id=cell_2_2"))
	assert_true(world.is_online(alice.player_id), "the player is not unloaded with a cell")
	# Saving the world does not write over the file that could not be read.
	assert_eq(persistence.save(world), OK)
	assert_eq(FileAccess.get_file_as_string(broken_path), "{ broken")
	assert_true(save.saved_cell_ids(WORLD).has("cell_2_2"))
