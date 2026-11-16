extends TestCase
## P3-3: containers, loot and the map content through WorldPersistence and
## real files (docs/10, docs/09 §15.1, §15.3): save -> process "restart" (a
## brand-new world object from disk) -> restore.
##   - a partly looted container and the items players put in come back
##     identical, from cells in memory and from released cells;
##   - loot is rolled once: never again after a restart or a cell reload;
##   - on disk every item id and every unit exists exactly once;
##   - the map content is seeded once per world, also for a save that was
##     written before it existed, and never again;
##   - over the network: items put in before a restart are taken out after.

const WORLD: String = "container_persist_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const TOLERANCE: float = 0.000001
const WAIT_MSEC: int = 8000
const SETTLE_TICKS: int = 20
const FOOD: String = "dev_food_ration"
const WATER: String = "dev_water_bottle"
const CABINET: String = "dev_cabinet"
const CRATE: String = "dev_crate"
const BOX: String = "p33p_box"
const MAP_ID: String = "dev_test_map"
## 10 m cells: HOME is where players spawn, AWAY is far enough to release it.
const HOME: Vector3 = Vector3(25.0, 0.0, 25.0)
const BESIDE: Vector3 = Vector3(26.0, 0.0, 25.0)
const ALSO_BESIDE: Vector3 = Vector3(25.0, 0.0, 26.5)
const AWAY: Vector3 = Vector3(-25.0, 0.0, -25.0)
const HOME_CELL: String = "cell_2_2"
## Longer than the unload delay.
const RELEASE_SEC: float = 3.0

var _root: String = ""
var _cluster: NetTestCluster = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/container_persist_%d" % Time.get_ticks_usec()
	_cluster = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## A 100 m map of 10 m cells; only the player's own cell is simulated, two
## rings are kept in memory, cells are released one second after nobody
## wants them. Containers open at once.
func _small_config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = HOME
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 10.0
	config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	config.world_cells.active_radius_cells = 0
	config.world_cells.preload_radius_cells = 2
	config.world_cells.preload_lookahead_sec = 0.0
	config.world_cells.deactivate_delay_sec = 0.0
	config.world_cells.unload_delay_sec = 1.0
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.max_preload_loads_per_refresh = 1000
	config.interest = InterestSettings.new()
	config.interest.interest_radius_cells = 1
	config.interest.keep_margin_cells = 1
	config.containers = ContainerSettings.new()
	config.containers.search_duration_sec = 0.0
	# The shipped containers and a storage box without loot.
	config.container_definitions = ContainerCatalog.load_directory()
	var box: ContainerDefinition = ContainerDefinition.new()
	box.definition_id = BOX
	box.slot_count = 4
	config.container_definitions.add(box)
	return config


## The shipped composition (the 500 m map and its cells) with or without the
## shipped map content, and nothing that moves by itself.
func _shipped_config(with_map: bool) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.containers = ContainerSettings.new()
	config.containers.search_duration_sec = 0.0
	config.map_content = MapContentDefinition.load_or_null() if with_map else null
	return config


func _save_service() -> SaveService:
	return SaveService.new(_root)


## A server start: a brand-new world object built from what is on disk.
func _boot(config: CompositionConfig) -> ServerWorld:
	return WorldPersistence.new(_save_service(), config).load_or_create(WORLD)


func _persistence(config: CompositionConfig) -> WorldPersistence:
	return WorldPersistence.new(_save_service(), config)


func _containers(world: ServerWorld) -> ContainerService:
	return world.get_system(ContainerService.SYSTEM_ID) as ContainerService


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _map(world: ServerWorld) -> MapContentService:
	return world.get_system(MapContentService.SYSTEM_ID) as MapContentService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _move(world: ServerWorld, player: PlayerState, position: Vector3, seconds: float = TICK) -> void:
	player.position = position
	_run(world, seconds)


func _container(world: ServerWorld, definition_id: String, position: Vector3) -> String:
	var created: ActionResult = _containers(world).create_container(world, definition_id, position)
	if not created.ok:
		fail("test setup: container refused: " + created.reason)
		return ""
	return str(created.event.get("container_id", ""))


func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, world.cell_id_at(player.position), player.position)
	if not world.try_pickup(player.player_id, item_id).ok:
		fail("test setup: pickup failed")
	return item_id


func _must(result: ActionResult, what: String) -> void:
	if not result.ok:
		fail("test setup: %s refused: %s" % [what, result.reason])


## Save data of every container in memory with its content, by id.
func _saved(world: ServerWorld) -> Dictionary:
	var service: ContainerService = _containers(world)
	var result: Dictionary = {}
	for container_id: String in service.container_ids():
		var data: Dictionary = service.get_container(container_id).to_dict()
		data["contents"] = service.contents_of(container_id)
		result[container_id] = data
	return result


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


## [definition, quantity, slot] of content entries (without the item ids).
func _shape(entries: Array[Dictionary]) -> Array:
	var rows: Array = []
	for entry: Dictionary in entries:
		rows.append([entry["definition_id"], entry["quantity"], entry["slot"]])
	return rows


func _read_json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary


## Every item of the save on disk: {item id: quantity}, from the world
## document (carried items, stray world items), every cell file (world items
## and what is inside containers). An id that is on disk twice fails the
## test.
func _items_on_disk() -> Dictionary:
	var save: SaveService = _save_service()
	var base: String = save.world_dir(WORLD)
	var found: Dictionary = {}
	var world_state: Dictionary = _read_json(base.path_join(SaveService.WORLD_STATE_FILE))
	var lists: Array = [(world_state["inventory"] as Dictionary)["items"]]
	var world_containers: Dictionary = (world_state["systems"] as Dictionary).get(ContainerService.SYSTEM_ID, {})
	for container: Dictionary in world_containers.get(ContainerService.KEY_CONTAINERS, []):
		lists.append(container[ContainerService.KEY_ITEMS])
	for cell_id: String in save.saved_cell_ids(WORLD):
		var cell: Dictionary = _read_json(base.path_join(SaveService.cell_file(cell_id)))
		lists.append((cell["world_items"] as Dictionary).get("items", []))
		var cell_containers: Dictionary = (cell["systems"] as Dictionary).get(ContainerService.SYSTEM_ID, {})
		for container: Dictionary in cell_containers.get(ContainerService.KEY_CONTAINERS, []):
			lists.append(container[ContainerService.KEY_ITEMS])
	for list: Array in lists:
		for item: Dictionary in list:
			var item_id: String = str(item["item_instance_id"])
			if found.has(item_id):
				fail("%s is on disk twice" % item_id)
			found[item_id] = [str(item["definition_id"]), int(item["quantity"])]
	return found


func _units_on_disk(definition_id: String) -> int:
	var total: int = 0
	var items: Dictionary = _items_on_disk()
	for item_id: String in items:
		if str(items[item_id][0]) == definition_id:
			total += int(items[item_id][1])
	return total


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


# ------------------------------------------------------------ containers

func test_a_partly_looted_container_and_stored_items_survive_restarts() -> void:
	var config: CompositionConfig = _small_config()
	var world: ServerWorld = _boot(config)
	assert_not_null(world)
	if world == null:
		return
	var service: ContainerService = _containers(world)
	var alice: PlayerState = world.join("alice")
	var cabinet_id: String = _container(world, CABINET, BESIDE)
	var untouched_id: String = _container(world, CABINET, Vector3(24.0, 0.0, 25.0))
	var crate_id: String = _container(world, CRATE, ALSO_BESIDE)
	# The cabinet is searched and partly looted; alice puts things into the
	# crate (which she searched first, like any container).
	var food_id: String = _give(world, alice, FOOD, 4)
	var water_id: String = _give(world, alice, WATER, 2)
	_must(service.try_open(world, alice.player_id, cabinet_id), "open")
	var looted: Array[Dictionary] = service.contents_of(cabinet_id)
	if not looted.is_empty():
		_must(service.try_take(world, alice.player_id, cabinet_id, str(looted[0]["item_instance_id"]), 1), "take")
	_must(service.try_open(world, alice.player_id, crate_id), "open")
	_must(service.try_put(world, alice.player_id, crate_id, food_id, 3), "put")
	_must(service.try_put(world, alice.player_id, crate_id, water_id, InventoryService.WHOLE_STACK), "put")
	var before: Dictionary = _saved(world)
	var rolls: int = service.loot_roll_count
	assert_eq(rolls, 2, "two containers were searched")
	var carried_before: Dictionary = {}
	for item: ItemInstance in world.inventory.items_in_inventory(alice.inventory_id):
		carried_before[item.item_instance_id] = item.quantity
	var sequence: int = world.ids.get_next_sequence()

	# 1. A save with the cells in memory, then a restart.
	assert_eq(_persistence(config).save(world), OK)
	var food_on_disk: int = _units_on_disk(FOOD)
	var water_on_disk: int = _units_on_disk(WATER)
	var disk_ids: int = _items_on_disk().size()
	var world_file: Dictionary = _read_json(_save_service().world_dir(WORLD).path_join(SaveService.WORLD_STATE_FILE))
	assert_false((world_file["systems"] as Dictionary).has(ContainerService.SYSTEM_ID), "containers of cells in memory are saved in their cell files, not in the world file")
	var cell_file: Dictionary = _read_json(_save_service().world_dir(WORLD).path_join(SaveService.cell_file(HOME_CELL)))
	assert_eq((((cell_file["systems"] as Dictionary)[ContainerService.SYSTEM_ID] as Dictionary)[ContainerService.KEY_CONTAINERS] as Array).size(), 3)
	var second: ServerWorld = _boot(config)
	assert_not_null(second, "the save loads")
	if second == null:
		return
	assert_eq(_containers(second).container_count(), 0, "a server start brings no cell into memory")
	var alice2: PlayerState = second.join("alice")
	_run(second, TICK)
	assert_true(_same(_saved(second), before), "the same containers with the same content after a restart")
	assert_true(_containers(second).get_container(cabinet_id).searched)
	assert_false(_containers(second).get_container(untouched_id).searched, "a container nobody searched is still unsearched")
	assert_eq(second.ids.get_next_sequence(), sequence, "no saved id can be handed out again")
	var carried: Dictionary = {}
	for item: ItemInstance in second.inventory.items_in_inventory(alice2.inventory_id):
		carried[item.item_instance_id] = item.quantity
	assert_eq(carried, carried_before, "what alice carries was restored")
	# Opening a searched container after the restart rolls nothing.
	_must(_containers(second).try_open(second, alice2.player_id, cabinet_id), "open")
	_must(_containers(second).try_open(second, alice2.player_id, crate_id), "open")
	assert_eq(_containers(second).loot_roll_count, 0, "no loot is rolled again after a restart")
	assert_true(_same(_saved(second), before))

	# 2. The cell is released (the unload saves the world), then a restart.
	_move(second, alice2, AWAY, RELEASE_SEC)
	assert_eq(_containers(second).container_count(), 0, "the home cell was released")
	assert_eq(_units_on_disk(FOOD), food_on_disk, "every unit is on disk once, whichever cells are in memory")
	assert_eq(_units_on_disk(WATER), water_on_disk)
	assert_eq(_items_on_disk().size(), disk_ids)
	var third: ServerWorld = _boot(config)
	assert_not_null(third)
	if third == null:
		return
	var alice3: PlayerState = third.join("alice")
	assert_eq(_containers(third).container_count(), 0, "alice is far away")
	_move(third, alice3, HOME, TICK)
	assert_true(_same(_saved(third), before), "the same containers after release, restart and reload")
	# 3. Bob takes what alice stored, the cell is released and loaded again.
	var bob: PlayerState = third.join("bob")
	_must(_containers(third).try_open(third, bob.player_id, crate_id), "open")
	for entry: Dictionary in _containers(third).contents_of(crate_id):
		_must(_containers(third).try_take(third, bob.player_id, crate_id, str(entry["item_instance_id"]), InventoryService.WHOLE_STACK), "take")
	_move(third, alice3, AWAY, TICK)
	_move(third, bob, AWAY, RELEASE_SEC)
	assert_eq(_containers(third).container_count(), 0)
	assert_eq(_units_on_disk(FOOD), food_on_disk, "taken out and saved: still every unit once")
	assert_eq(_units_on_disk(WATER), water_on_disk)
	var fourth: ServerWorld = _boot(config)
	var bob4: PlayerState = fourth.join("bob")
	_move(fourth, bob4, HOME, TICK)
	assert_eq(_containers(fourth).contents_of(crate_id).size(), 0, "the emptied crate stays empty")
	assert_true(_containers(fourth).get_container(crate_id).searched)
	var bob_food: int = 0
	for item: ItemInstance in fourth.inventory.items_in_inventory(bob4.inventory_id):
		if item.definition_id == FOOD:
			bob_food += item.quantity
	assert_true(bob_food >= 3, "bob carries what alice put in (%d)" % bob_food)
	assert_eq(_containers(fourth).loot_roll_count, 0)


func test_an_unsearched_container_holds_the_same_whenever_it_is_searched() -> void:
	# The reference: searched right after it was created.
	var config: CompositionConfig = _small_config()
	var reference: ServerWorld = ServerComposition.create_world(WORLD, config)
	var reference_alice: PlayerState = reference.join("alice")
	var reference_id: String = _container(reference, CABINET, BESIDE)
	_must(_containers(reference).try_open(reference, reference_alice.player_id, reference_id), "open")
	var expected: Array[Dictionary] = _containers(reference).contents_of(reference_id)
	# The same container, saved, restarted twice, released and reloaded
	# before anybody searches it.
	var world: ServerWorld = _boot(config)
	var alice: PlayerState = world.join("alice")
	var cabinet_id: String = _container(world, CABINET, BESIDE)
	assert_eq(cabinet_id, reference_id)
	assert_eq(_persistence(config).save(world), OK)
	world = _boot(config)
	alice = world.join("alice")
	_move(world, alice, AWAY, RELEASE_SEC)
	world = _boot(config)
	alice = world.join("alice")
	_move(world, alice, HOME, TICK)
	assert_false(_containers(world).get_container(cabinet_id).searched)
	assert_eq(_containers(world).contents_of(cabinet_id).size(), 0)
	_must(_containers(world).try_open(world, alice.player_id, cabinet_id), "open")
	assert_eq(_shape(_containers(world).contents_of(cabinet_id)), _shape(expected), "the loot is decided by the seed and the id, not by when the search happens")
	assert_eq(_containers(world).loot_roll_count, 1)


# ------------------------------------------------------------ map content

func test_a_server_world_gets_the_test_map_once_and_keeps_it() -> void:
	var content: MapContentDefinition = MapContentDefinition.load_or_null()
	var config: CompositionConfig = _shipped_config(true)
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var started_usec: int = Time.get_ticks_usec()
	var world: ServerWorld = _boot(config)
	var boot_msec: float = float(Time.get_ticks_usec() - started_usec) / 1000.0
	assert_not_null(world, "a new world with the map content starts")
	if world == null:
		return
	var report: Dictionary = _map(world).last_seed_report
	print("[measure] first server start with the test map (real files): %.1f ms in all, %.1f ms of it seeding %d structures and %d containers into %d cells (%d save and release)" % [boot_msec, float(int(report[MapContentService.REPORT_USEC])) / 1000.0, int(report[MapContentService.REPORT_STRUCTURES]), int(report[MapContentService.REPORT_CONTAINERS]), int(report[MapContentService.REPORT_CELLS_LOADED]), int(report[MapContentService.REPORT_RELEASES])])
	assert_true(_map(world).is_seeded())
	assert_eq(int(report[MapContentService.REPORT_STRUCTURES]), content.piece_count())
	assert_eq(_cells(world).loaded_cell_ids().size(), 0, "the seeding left no cell in memory")
	assert_eq(_building(world).structure_count(), 0)
	assert_true(_save_service().saved_cell_ids(WORLD).size() >= 4, "the buildings are in the cell files")
	var record: Dictionary = (((_read_json(_save_service().world_dir(WORLD).path_join(SaveService.WORLD_STATE_FILE))["systems"] as Dictionary)[MapContentService.SYSTEM_ID] as Dictionary)[MapContentService.KEY_MAPS] as Dictionary)[MAP_ID]
	assert_eq(record[MapContentService.KEY_COMPLETE], true, "the world file records that the map was seeded")
	var sequence: int = world.ids.get_next_sequence()

	# A restart seeds nothing.
	var second: ServerWorld = _boot(config)
	assert_not_null(second)
	if second == null:
		return
	assert_true(_map(second).is_seeded())
	assert_eq(_map(second).last_seed_report.size(), 0, "nothing was placed by the second start")
	assert_eq(second.ids.get_next_sequence(), sequence, "no id was spent")
	assert_eq(_cells(second).loaded_cell_ids().size(), 0)
	# A player joins: the buildings around the spawn point are there, once.
	var alice: PlayerState = second.join("alice")
	_run(second, TICK)
	assert_eq(_building(second).structure_count(), content.piece_count(), "every piece, none twice")
	assert_eq(_containers(second).container_count(), content.container_count())
	for structure_id: String in _building(second).structure_ids():
		if _building(second).get_structure(structure_id).construction_state != StructureInstance.State.COMPLETED:
			fail("%s came out of the save as something else than completed" % structure_id)
			break
	# She searches the first container of the map and takes from it.
	var first: MapBuildingDefinition = content.buildings[0]
	var at: Vector3 = MapBuildingPlan.container_position(first, first.containers[0], _building(second).grid)
	var target_id: String = ""
	for container_id: String in _containers(second).container_ids():
		if _containers(second).get_container(container_id).position.is_equal_approx(at):
			target_id = container_id
	assert_false(target_id.is_empty(), "the container of the first building is where the map says")
	alice.position = at + Vector3(0.5, 0.0, 0.0)
	_must(_containers(second).try_open(second, alice.player_id, target_id), "open")
	var found: Array[Dictionary] = _containers(second).contents_of(target_id)
	for entry: Dictionary in found:
		_must(_containers(second).try_take(second, alice.player_id, target_id, str(entry["item_instance_id"]), InventoryService.WHOLE_STACK), "take")
	assert_eq(_persistence(config).save(second), OK)
	# After another restart it is searched and empty; the others are not.
	var third: ServerWorld = _boot(config)
	var alice3: PlayerState = third.join("alice")
	_run(third, TICK)
	assert_eq(_map(third).last_seed_report.size(), 0)
	assert_eq(_building(third).structure_count(), content.piece_count())
	assert_eq(_containers(third).container_count(), content.container_count())
	var searched: int = 0
	for container_id: String in _containers(third).container_ids():
		if _containers(third).get_container(container_id).searched:
			searched += 1
	assert_eq(searched, 1, "only the container alice searched")
	assert_eq(_containers(third).contents_of(target_id).size(), 0, "what she took is not there again")
	_must(_containers(third).try_open(third, alice3.player_id, target_id), "open")
	assert_eq(_containers(third).loot_roll_count, 0, "and nothing is rolled for it again")
	var carried: int = third.inventory.items_in_inventory(alice3.inventory_id).size()
	assert_true(carried >= mini(found.size(), 1), "she still carries what she took")


func test_a_save_from_before_the_map_content_is_seeded_once_at_the_next_start() -> void:
	var content: MapContentDefinition = MapContentDefinition.load_or_null()
	# A world created and played by a server without map content.
	var old_world: ServerWorld = _boot(_shipped_config(false))
	assert_not_null(old_world)
	if old_world == null:
		return
	var alice: PlayerState = old_world.join("alice")
	_give(old_world, alice, FOOD, 2)
	assert_eq(_persistence(_shipped_config(false)).save(old_world), OK)
	assert_false(_map(old_world).is_seeded())
	assert_false((_read_json(_save_service().world_dir(WORLD).path_join(SaveService.WORLD_STATE_FILE))["systems"] as Dictionary).has(MapContentService.SYSTEM_ID))
	# The same save, started by a server that has it.
	var world: ServerWorld = _boot(_shipped_config(true))
	assert_not_null(world, "the older save loads and gets the map content")
	if world == null:
		return
	assert_true(_map(world).is_seeded())
	assert_eq(int(_map(world).last_seed_report[MapContentService.REPORT_STRUCTURES]), content.piece_count())
	var sequence: int = world.ids.get_next_sequence()
	# It was saved by the seeding itself: a crash right now loses nothing.
	var again: ServerWorld = _boot(_shipped_config(true))
	assert_not_null(again)
	if again == null:
		return
	assert_eq(_map(again).last_seed_report.size(), 0, "the next start places nothing")
	assert_eq(again.ids.get_next_sequence(), sequence)
	var alice2: PlayerState = again.join("alice")
	_run(again, TICK)
	assert_eq(_building(again).structure_count(), content.piece_count())
	assert_eq(_containers(again).container_count(), content.container_count())
	assert_eq(again.inventory.items_in_inventory(alice2.inventory_id).size(), 1, "the player of the old save is who she was")
	# A server without map content can still start that world.
	var plain: ServerWorld = _boot(_shipped_config(false))
	assert_not_null(plain, "the record of a map this server does not have is kept, not an error")
	if plain != null:
		assert_true(_map(plain).is_seeded(MAP_ID))


# ------------------------------------------------------------ network

func test_items_put_in_before_a_server_restart_are_taken_out_after_it() -> void:
	var config: CompositionConfig = _small_config()
	config.inventory_net = InventoryNetSettings.new()
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	var persistence: WorldPersistence = _persistence(config)
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	if world == null:
		return
	# Alice exists and carries food before her client joins.
	var alice_state: PlayerState = world.join("alice")
	var food_id: String = _give(world, alice_state, FOOD, 4)
	var crate_id: String = _container(world, BOX, BESIDE)
	world.leave(alice_state.player_id)
	_cluster = NetTestCluster.new(tree, network_settings, config)
	assert_eq(_cluster.start_server(world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	if a == null:
		fail("alice did not join")
		return
	var module: ContainerNetModule = a.get_module(ContainerNetModule.MODULE_NAME) as ContainerNetModule
	var results: Array[Array] = []
	module.container_result.connect(func(_request_id: int, ok: bool, reason: String) -> void: results.append([ok, reason]))
	var save: SaveService = _save_service()
	module.request_open(crate_id)
	assert_true(await _wait(func() -> bool: return results.size() == 1))
	var generation: int = save.current_generation(WORLD)
	module.request_put(crate_id, food_id, 3)
	assert_true(await _wait(func() -> bool: return results.size() == 2))
	assert_eq(results, [[true, ""], [true, ""]])
	assert_eq(save.current_generation(WORLD), generation + 1, "the put was saved before the answer went out")
	for tick: int in range(SETTLE_TICKS):
		await tree.physics_frame
	assert_eq(save.current_generation(WORLD), generation + 1, "and only once")
	assert_eq(_units_on_disk(FOOD), 4, "3 in the crate and 1 carried, each once")
	var stored: Array[Dictionary] = _containers(world).contents_of(crate_id)
	assert_eq(stored.size(), 1)
	var stored_id: String = str(stored[0]["item_instance_id"])

	# --- full restart: everything torn down, state comes only from disk ---
	await _cluster.shutdown()
	_cluster = null
	var persistence2: WorldPersistence = _persistence(config)
	var world2: ServerWorld = persistence2.load_or_create(WORLD)
	assert_not_null(world2, "world restored from save")
	if world2 == null:
		return
	_cluster = NetTestCluster.new(tree, network_settings, config)
	assert_eq(_cluster.start_server(world2, persistence2), OK)
	var b: NetworkService = await _cluster.join_client("bob")
	if b == null:
		fail("bob did not join")
		return
	var b_module: ContainerNetModule = b.get_module(ContainerNetModule.MODULE_NAME) as ContainerNetModule
	assert_true(await _wait(func() -> bool: return b_module.client_state.has_container(crate_id)), "bob is told about the crate that was saved")
	var b_results: Array[Array] = []
	b_module.container_result.connect(func(_request_id: int, ok: bool, reason: String) -> void: b_results.append([ok, reason]))
	b_module.request_open(crate_id)
	assert_true(await _wait(func() -> bool: return b_results.size() == 1))
	var seen: Array[Dictionary] = b_module.client_state.contents()
	assert_eq(seen.size(), 1, "bob sees what alice put in before the restart")
	assert_eq(seen[0][ClientContainerState.KEY_ITEM_ID], stored_id, "the same stack with the same id")
	assert_eq(seen[0][ClientContainerState.KEY_QUANTITY], 3)
	b_module.request_take(crate_id, stored_id, InventoryService.WHOLE_STACK)
	assert_true(await _wait(func() -> bool: return b_results.size() == 2))
	assert_eq(b_results, [[true, ""], [true, ""]])
	assert_true(b.client_state.has_inventory_item(stored_id), "the stack is in bob's inventory mirror")
	assert_eq(_containers(world2).contents_of(crate_id).size(), 0)
	assert_eq(_units_on_disk(FOOD), 4, "taken and saved: 3 with bob, 1 with alice")
	assert_eq(b_module.client_state.rejected_payload_count, 0)
