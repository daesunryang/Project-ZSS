extends TestCase
## P3-1: save layout of world cells (docs/10 §3, docs/09 §15.1):
## SaveService cell files, the world v3 -> v4 migration and the rules of
## bringing saved world items back into memory.

const TEST_ROOT: String = "user://test_saves"
const WORLD: String = "cell_save_world"
const PICKUP_RANGE: float = 2.5

var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = TEST_ROOT.path_join("cells_%d" % Time.get_ticks_usec())


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _world_doc(value: int = 1) -> Dictionary:
	return {"schema_version": SaveMigrations.WORLD_SCHEMA_VERSION, "world_id": WORLD, "value": value}


## A cell document with `count` marker entries (the save layer does not look
## inside "world_items").
func _cell_doc(cell_id: String, count: int) -> Dictionary:
	var items: Array = []
	for index: int in range(count):
		items.append({"marker": index})
	return WorldCellDocument.create(cell_id, {"items": items} if count > 0 else {}, {})


func _cell_path(service: SaveService, cell_id: String) -> String:
	return service.world_dir(WORLD).path_join(SaveService.cell_file(cell_id))


func _corrupt(path: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("{ not json")
	file.close()


# ------------------------------------------------------------ SaveService

func test_cells_are_saved_as_their_own_files_and_read_one_by_one() -> void:
	var service: SaveService = SaveService.new(_root)
	assert_eq(service.save_world(WORLD, _world_doc(), {}, {"cell_0_0": _cell_doc("cell_0_0", 2), "cell_-3_12": _cell_doc("cell_-3_12", 1)}), OK)
	assert_true(FileAccess.file_exists(_cell_path(service, "cell_0_0")))
	assert_true(FileAccess.file_exists(service.world_dir(WORLD).path_join("cells/cell_-3_12.json")), "docs/10 §3: cells/<cell_id>.json")
	var reader: SaveService = SaveService.new(_root)
	var loaded: Dictionary = reader.load_world(WORLD)
	assert_eq(loaded["error"], OK)
	assert_eq(loaded["cell_ids"], PackedStringArray(["cell_-3_12", "cell_0_0"]), "the world lists its cells but does not read them")
	assert_false((loaded["world_state"] as Dictionary).has("cells"))
	var cell: Dictionary = reader.load_cell(WORLD, "cell_-3_12")
	assert_eq(cell["error"], OK)
	assert_eq((cell["document"] as Dictionary)["cell_id"], "cell_-3_12")
	assert_eq(int((cell["document"] as Dictionary)["schema_version"]), WorldCellDocument.SCHEMA_VERSION)
	assert_eq((((cell["document"] as Dictionary)["world_items"] as Dictionary)["items"] as Array).size(), 1)


func test_a_cell_without_a_file_is_an_empty_cell() -> void:
	var service: SaveService = SaveService.new(_root)
	assert_eq(service.save_world(WORLD, _world_doc(), {}, {"cell_0_0": _cell_doc("cell_0_0", 1)}), OK)
	var cell: Dictionary = service.load_cell(WORLD, "cell_4_4")
	assert_eq(cell["error"], OK)
	assert_true((cell["document"] as Dictionary).is_empty())
	assert_eq(service.load_cell(WORLD, "../world_state")["error"], ERR_INVALID_PARAMETER, "only cell ids name a cell file")
	assert_eq(service.load_cell(WORLD, "cell_x_y")["error"], ERR_INVALID_PARAMETER)
	assert_eq(service.save_world(WORLD, _world_doc(), {}, {"not_a_cell": _cell_doc("not_a_cell", 1)}), ERR_INVALID_PARAMETER)
	assert_eq(service.current_generation(WORLD), 1, "a refused save changes nothing")


func test_cells_that_are_not_in_a_save_keep_their_files() -> void:
	var service: SaveService = SaveService.new(_root)
	assert_eq(service.save_world(WORLD, _world_doc(1), {}, {"cell_0_0": _cell_doc("cell_0_0", 1), "cell_1_0": _cell_doc("cell_1_0", 1)}), OK)
	# cell_1_0 was released: the next saves only carry cell_0_0.
	assert_eq(service.save_world(WORLD, _world_doc(2), {}, {"cell_0_0": _cell_doc("cell_0_0", 3)}), OK)
	assert_eq(service.save_world(WORLD, _world_doc(3), {}, {}), OK)
	assert_eq(service.saved_cell_ids(WORLD), PackedStringArray(["cell_0_0", "cell_1_0"]))
	assert_eq((((service.load_cell(WORLD, "cell_1_0")["document"] as Dictionary)["world_items"] as Dictionary)["items"] as Array).size(), 1)
	assert_eq((((service.load_cell(WORLD, "cell_0_0")["document"] as Dictionary)["world_items"] as Dictionary)["items"] as Array).size(), 3)
	assert_eq(service.current_generation(WORLD), 3)


func test_an_emptied_cell_loses_its_file_and_an_empty_cell_never_gets_one() -> void:
	var service: SaveService = SaveService.new(_root)
	assert_eq(service.save_world(WORLD, _world_doc(), {}, {"cell_0_0": _cell_doc("cell_0_0", 1), "cell_2_2": _cell_doc("cell_2_2", 0)}), OK)
	assert_false(FileAccess.file_exists(_cell_path(service, "cell_2_2")))
	assert_eq(service.saved_cell_ids(WORLD), PackedStringArray(["cell_0_0"]))
	# Everything in cell_0_0 was taken.
	assert_eq(service.save_world(WORLD, _world_doc(), {}, {"cell_0_0": _cell_doc("cell_0_0", 0)}), OK)
	assert_eq(service.saved_cell_ids(WORLD).size(), 0)
	assert_false(FileAccess.file_exists(_cell_path(service, "cell_0_0")), "no stale file that could bring the items back")
	assert_true((service.load_cell(WORLD, "cell_0_0")["document"] as Dictionary).is_empty())
	assert_true(FileAccess.file_exists(service.world_dir(WORLD).path_join("backups/gen_1/cells/cell_0_0.json")), "the previous generation is still in the backups")


func test_replace_cells_drops_every_cell_file_that_is_not_in_the_save() -> void:
	var service: SaveService = SaveService.new(_root)
	assert_eq(service.save_world(WORLD, _world_doc(), {}, {"cell_0_0": _cell_doc("cell_0_0", 1), "cell_1_0": _cell_doc("cell_1_0", 1), "cell_2_0": _cell_doc("cell_2_0", 1)}), OK)
	assert_eq(service.save_world(WORLD, _world_doc(), {}, {"cell_0_0": _cell_doc("cell_0_0", 2), "cell_5_5": _cell_doc("cell_5_5", 1)}, true), OK)
	assert_eq(service.saved_cell_ids(WORLD), PackedStringArray(["cell_0_0", "cell_5_5"]))
	assert_false(FileAccess.file_exists(_cell_path(service, "cell_1_0")))
	assert_false(FileAccess.file_exists(_cell_path(service, "cell_2_0")))
	assert_true(FileAccess.file_exists(service.world_dir(WORLD).path_join(SaveService.WORLD_STATE_FILE)), "only cell files are replaced")


func test_a_corrupt_cell_file_falls_back_to_its_backup_and_does_not_stop_the_world() -> void:
	var service: SaveService = SaveService.new(_root)
	var cells: Dictionary = {"cell_0_0": _cell_doc("cell_0_0", 1), "cell_1_0": _cell_doc("cell_1_0", 1)}
	assert_eq(service.save_world(WORLD, _world_doc(1), {}, cells), OK)
	cells["cell_0_0"] = _cell_doc("cell_0_0", 2)
	assert_eq(service.save_world(WORLD, _world_doc(2), {}, cells), OK)
	_corrupt(_cell_path(service, "cell_0_0"))
	var world: Dictionary = service.load_world(WORLD)
	assert_eq(world["error"], OK, "the world itself loads")
	assert_eq(int((world["world_state"] as Dictionary)["value"]), 2)
	var restored: Dictionary = service.load_cell(WORLD, "cell_0_0")
	assert_eq(restored["error"], OK)
	assert_eq((((restored["document"] as Dictionary)["world_items"] as Dictionary)["items"] as Array).size(), 1, "the copy of the generation before")
	assert_true((restored["warnings"] as PackedStringArray).size() > 0)
	assert_eq(service.load_cell(WORLD, "cell_1_0")["error"], OK, "other cells are not affected")
	# No readable copy anywhere: this one cell fails, nothing else.
	SaveService.remove_tree(service.world_dir(WORLD).path_join(SaveService.BACKUPS_DIR))
	assert_eq(service.load_cell(WORLD, "cell_0_0")["error"], ERR_FILE_CORRUPT)
	assert_eq(service.load_cell(WORLD, "cell_1_0")["error"], OK)
	assert_eq(service.load_world(WORLD)["error"], OK)


func test_a_cell_document_from_a_newer_build_is_not_read() -> void:
	var service: SaveService = SaveService.new(_root)
	var newer: Dictionary = _cell_doc("cell_0_0", 1)
	newer["schema_version"] = SaveMigrations.CELL_SCHEMA_VERSION + 1
	assert_eq(service.save_world(WORLD, _world_doc(), {}, {"cell_0_0": newer}), OK)
	assert_eq(service.load_cell(WORLD, "cell_0_0")["error"], ERR_FILE_CORRUPT)
	var no_version: Dictionary = _cell_doc("cell_1_0", 1)
	no_version.erase("schema_version")
	assert_eq(service.save_world(WORLD, _world_doc(), {}, {"cell_1_0": no_version}), ERR_INVALID_DATA, "every document needs a schema_version")


# ------------------------------------------------------------ versions

func test_versions_and_the_world_migration_to_cells() -> void:
	assert_eq(SaveMigrations.WORLD_SCHEMA_VERSION, 4)
	assert_eq(ServerWorld.SCHEMA_VERSION, SaveMigrations.WORLD_SCHEMA_VERSION)
	assert_eq(SaveMigrations.CELL_SCHEMA_VERSION, WorldCellDocument.SCHEMA_VERSION)
	var old: Dictionary = {
		"schema_version": 3, "world_id": WORLD, "world_time_sec": 10.0, "action_time_sec": 5.0,
		"inventory": {"items": [{"item_instance_id": "item_000001"}], "world_item_positions": {"item_000001": [1.0, 0.0, 2.0]}, "inventories": {}},
		"systems": {"zombie": {"schema_version": 1, "zombies": [{"zombie_id": "zombie_000002"}]}},
	}
	var migrated: Dictionary = SaveMigrations.defaults()[SaveService.CATEGORY_WORLD].migrate(old)
	assert_eq(int(migrated["schema_version"]), 4)
	var expected: Dictionary = old.duplicate(true)
	expected["schema_version"] = 4
	assert_eq(migrated, expected, "nothing is lost or moved: the server sorts the entities into cells when it loads them")
	assert_eq(int(old["schema_version"]), 3, "the input is not modified")
	var from_v1: Dictionary = SaveMigrations.defaults()[SaveService.CATEGORY_WORLD].migrate({"schema_version": 1, "world_id": WORLD})
	assert_eq(int(from_v1["schema_version"]), 4, "the whole chain still runs")
	assert_true(from_v1.has("action_time_sec"))
	assert_true(SaveMigrations.defaults()[SaveService.CATEGORY_WORLD].migrate({"schema_version": 5}).is_empty(), "no downgrade")


func test_cell_document_helpers() -> void:
	var empty: Dictionary = WorldCellDocument.create("cell_0_0", {}, {})
	assert_true(WorldCellDocument.is_empty(empty))
	assert_true(WorldCellDocument.is_empty({}))
	assert_false(WorldCellDocument.is_empty(WorldCellDocument.create("cell_0_0", {"items": []}, {})))
	assert_false(WorldCellDocument.is_empty(WorldCellDocument.create("cell_0_0", {}, {"zombie": {"zombies": []}})))
	assert_eq(WorldCellDocument.validate(empty, "cell_0_0").size(), 0)
	assert_true(WorldCellDocument.validate(empty, "cell_1_0").size() > 0, "a document of another cell")
	assert_true(WorldCellDocument.validate({"schema_version": 2, "cell_id": "cell_0_0", "world_items": {}, "systems": {}}, "cell_0_0").size() > 0)
	assert_true(WorldCellDocument.validate({"schema_version": 1, "cell_id": "cell_0_0", "world_items": [], "systems": {}}, "cell_0_0").size() > 0)
	assert_true(SaveService.is_json_safe(empty))


# ------------------------------------------------------------ world items of a cell

func _inventory(ids: EntityIdGenerator, registry: EntityRegistry) -> InventoryService:
	return InventoryService.new(ItemCatalog.load_directory(), ids, registry, PICKUP_RANGE)


func test_world_items_of_a_cell_leave_memory_and_come_back_unchanged() -> void:
	var registry: EntityRegistry = EntityRegistry.new()
	var service: InventoryService = _inventory(EntityIdGenerator.new(), registry)
	var here: String = service.spawn_world_item("dev_food_ration", 3, "cell_0_0", Vector3(1.0, 0.0, 2.0))
	var there: String = service.spawn_world_item("dev_test_item", 1, "cell_1_0", Vector3(60.0, 0.0, 2.0))
	var bag: String = service.create_inventory(4)
	var carried: String = service.spawn_world_item("dev_test_item", 1, "cell_0_0", Vector3(1.0, 0.0, 1.0))
	assert_true(service.try_pickup(bag, carried, Vector3(1.0, 0.0, 1.0)).ok)
	assert_eq(service.world_item_ids_in_cell("cell_0_0"), PackedStringArray([here]), "a carried item is in no cell")
	var snapshot: Dictionary = JSON.parse_string(JSON.stringify(service.cell_snapshot("cell_0_0")))
	assert_eq((snapshot["items"] as Array).size(), 1)
	assert_true(service.cell_snapshot("cell_9_9").is_empty())
	var committed: Array[Dictionary] = []
	service.transaction_committed.connect(func(event: Dictionary) -> void: committed.append(event))
	assert_eq(service.release_cell("cell_0_0"), 1)
	assert_null(service.get_item(here))
	assert_false(registry.has(here))
	assert_false(registry.is_tombstoned(here), "released, not retired")
	assert_not_null(service.get_item(there), "other cells stay")
	assert_not_null(service.get_item(carried), "carried items stay")
	assert_eq(service.restore_cell_snapshot("cell_0_0", snapshot).size(), 0)
	var item: ItemInstance = service.get_item(here)
	assert_eq(item.quantity, 3)
	assert_eq(item.definition_id, "dev_food_ration")
	assert_eq(item.location_id, "cell_0_0")
	assert_eq(service.world_position_of(here), Vector3(1.0, 0.0, 2.0))
	assert_eq(registry.kind_of(here), InventoryService.ENTITY_KIND_ITEM)
	assert_eq(committed.size(), 0, "no transaction: nothing changed hands")


func test_a_saved_copy_never_doubles_or_revives_an_item() -> void:
	var registry: EntityRegistry = EntityRegistry.new()
	var service: InventoryService = _inventory(EntityIdGenerator.new(), registry)
	var bag: String = service.create_inventory(4)
	var picked: String = service.spawn_world_item("dev_test_item", 1, "cell_0_0", Vector3(1.0, 0.0, 1.0))
	var eaten: String = service.spawn_world_item("dev_food_ration", 1, "cell_0_0", Vector3(1.0, 0.0, 1.0))
	var lying: String = service.spawn_world_item("dev_test_item", 1, "cell_0_0", Vector3(2.0, 0.0, 1.0))
	# The cell file is from before: it still has all three.
	var stale: Dictionary = JSON.parse_string(JSON.stringify(service.cell_snapshot("cell_0_0")))
	assert_true(service.try_pickup(bag, picked, Vector3(1.0, 0.0, 1.0)).ok)
	assert_true(service.try_pickup(bag, eaten, Vector3(1.0, 0.0, 1.0)).ok)
	assert_true(service.remove_item(bag, eaten, 1).ok, "used up: its id is retired")
	service.release_cell("cell_0_0")
	assert_eq(service.restore_cell_snapshot("cell_0_0", stale).size(), 0)
	assert_eq(service.world_item_ids(), PackedStringArray([lying]), "only the item that really lay there comes back")
	assert_eq(service.get_item(picked).location_type, ItemInstance.LOCATION_INVENTORY, "the carried item was not touched")
	assert_null(service.get_item(eaten), "the used-up item stays gone")
	assert_eq(service.item_count(), 2)
	# Loading the same document again changes nothing either.
	assert_eq(service.restore_cell_snapshot("cell_0_0", stale).size(), 0)
	assert_eq(service.item_count(), 2)


func test_a_broken_cell_snapshot_changes_nothing() -> void:
	var service: InventoryService = _inventory(EntityIdGenerator.new(), EntityRegistry.new())
	var good: Dictionary = {"schema_version": 1, "item_instance_id": "item_000050", "definition_id": "dev_test_item", "quantity": 1, "location_type": "world", "location_id": "cell_0_0", "slot_id": null}
	var cases: Array[Dictionary] = [
		{"items": "nope", "world_item_positions": {}},
		{"items": [good], "world_item_positions": {}},
		{"items": [good], "world_item_positions": {"item_000050": [1.0, "x", 0.0]}},
		{"items": [good, good], "world_item_positions": {"item_000050": [1.0, 0.0, 0.0]}},
		{"items": [{"item_instance_id": "item_000050"}], "world_item_positions": {"item_000050": [1.0, 0.0, 0.0]}},
	]
	var unknown: Dictionary = good.duplicate()
	unknown["definition_id"] = "no_such_item"
	cases.append({"items": [unknown], "world_item_positions": {"item_000050": [1.0, 0.0, 0.0]}})
	var carried: Dictionary = good.duplicate()
	carried["location_type"] = "inventory"
	cases.append({"items": [carried], "world_item_positions": {"item_000050": [1.0, 0.0, 0.0]}})
	for snapshot: Dictionary in cases:
		assert_true(service.restore_cell_snapshot("cell_0_0", snapshot).size() > 0, str(snapshot))
		assert_eq(service.item_count(), 0, "nothing was added")
	assert_eq(service.restore_cell_snapshot("cell_0_0", {"items": [good], "world_item_positions": {"item_000050": [1.0, 0.0, 0.0]}}).size(), 0)
	assert_eq(service.item_count(), 1)


func test_reassigning_cells_follows_positions() -> void:
	var service: InventoryService = _inventory(EntityIdGenerator.new(), EntityRegistry.new())
	var near: String = service.spawn_world_item("dev_test_item", 1, "cell_0_0", Vector3(1.0, 0.0, 1.0))
	var far: String = service.spawn_world_item("dev_test_item", 1, "cell_0_0", Vector3(-70.0, 0.0, 120.0))
	var grid: WorldCellGrid = WorldCellGrid.new()
	assert_eq(service.reassign_world_item_cells(grid.cell_id_at), 1)
	assert_eq(service.get_item(near).location_id, "cell_0_0")
	assert_eq(service.get_item(far).location_id, "cell_-2_2")
	assert_eq(service.world_item_ids_in_cell("cell_-2_2"), PackedStringArray([far]))
	assert_eq(service.world_item_ids_in_cell("cell_0_0"), PackedStringArray([near]))


func test_registry_release_is_not_a_removal() -> void:
	var registry: EntityRegistry = EntityRegistry.new()
	var removed: PackedStringArray = []
	registry.entity_removed.connect(func(entity_id: String, _kind: String) -> void: removed.append(entity_id))
	assert_eq(registry.register("item_000001", "item"), OK)
	assert_eq(registry.release("item_000001"), OK)
	assert_false(registry.has("item_000001"))
	assert_false(registry.is_tombstoned("item_000001"))
	assert_eq(removed.size(), 0)
	assert_eq(registry.release("item_000001"), ERR_DOES_NOT_EXIST)
	assert_eq(registry.register("item_000001", "item"), OK, "it can come back")


# ------------------------------------------------------------ save cost and backups

func _items_in(service: SaveService, cell_id: String) -> int:
	return (((service.load_cell(WORLD, cell_id)["document"] as Dictionary)["world_items"] as Dictionary)["items"] as Array).size()


func test_an_unchanged_cell_file_is_not_written_or_backed_up_again() -> void:
	var service: SaveService = SaveService.new(_root)
	var backups: String = service.world_dir(WORLD).path_join(SaveService.BACKUPS_DIR)
	var cells: Dictionary = {"cell_0_0": _cell_doc("cell_0_0", 1), "cell_1_0": _cell_doc("cell_1_0", 1)}
	assert_eq(service.save_world(WORLD, _world_doc(1), {}, cells), OK)
	assert_eq(service.save_world(WORLD, _world_doc(2), {}, cells), OK)
	assert_true(FileAccess.file_exists(backups.path_join("gen_1/world_state.json")), "what a save replaces is backed up")
	assert_false(FileAccess.file_exists(backups.path_join("gen_1/cells/cell_0_0.json")), "an untouched cell file is not copied again")
	assert_eq(service.saved_cell_ids(WORLD), PackedStringArray(["cell_0_0", "cell_1_0"]), "but it stays part of the save")
	cells["cell_0_0"] = _cell_doc("cell_0_0", 2)
	assert_eq(service.save_world(WORLD, _world_doc(3), {}, cells), OK)
	assert_true(FileAccess.file_exists(backups.path_join("gen_2/cells/cell_0_0.json")), "a changed cell file is backed up before it is replaced")
	assert_false(FileAccess.file_exists(backups.path_join("gen_2/cells/cell_1_0.json")))
	assert_eq(_items_in(service, "cell_0_0"), 2)
	assert_eq(_items_in(service, "cell_1_0"), 1)
	# Somebody else wrote the save in between: what this service remembers
	# about the files is worthless and it writes its cells again.
	assert_eq(SaveService.new(_root).save_world(WORLD, _world_doc(4), {}, {"cell_1_0": _cell_doc("cell_1_0", 5)}), OK)
	assert_eq(_items_in(service, "cell_1_0"), 5)
	assert_eq(service.save_world(WORLD, _world_doc(5), {}, cells), OK)
	assert_eq(_items_in(service, "cell_1_0"), 1, "the cell was written although its content is what this service wrote last")
	assert_eq(service.current_generation(WORLD), 5)


func test_the_only_backup_of_a_quiet_cell_survives_pruning() -> void:
	var service: SaveService = SaveService.new(_root, 1)
	var backups: String = service.world_dir(WORLD).path_join(SaveService.BACKUPS_DIR)
	assert_eq(service.save_world(WORLD, _world_doc(1), {}, {"cell_0_0": _cell_doc("cell_0_0", 1)}), OK)
	var cells: Dictionary = {"cell_0_0": _cell_doc("cell_0_0", 2)}
	for value: int in range(2, 9):
		assert_eq(service.save_world(WORLD, _world_doc(value), {}, cells), OK)
	assert_true(FileAccess.file_exists(backups.path_join("gen_1/cells/cell_0_0.json")), "the newest backup copy of the cell file is kept, however old")
	assert_false(FileAccess.file_exists(backups.path_join("gen_1/world_state.json")), "copies that have a newer copy are pruned")
	assert_false(DirAccess.dir_exists_absolute(backups.path_join("gen_3")), "a pruned generation without such copies is gone")
	assert_true(FileAccess.file_exists(backups.path_join("gen_7/world_state.json")), "the newest generation is kept whole")
	_corrupt(_cell_path(service, "cell_0_0"))
	assert_eq(_items_in(service, "cell_0_0"), 1, "and it is what a broken cell file falls back to")
