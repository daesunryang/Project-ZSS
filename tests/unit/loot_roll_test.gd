extends TestCase
## P3-3 (docs/03 §6, docs/09 §15.3): loot tables are data and a roll is a
## pure function of the table and a seed. The seed of a container comes from
## the world's loot seed and the container's id, so the same container holds
## the same things in every run and two containers hold different things.
## Pure: no world, no nodes.

const WORLD_SEED: int = 4242
const SAMPLE_COUNT: int = 200


func _table() -> LootTable:
	var table: LootTable = LootTable.new()
	table.table_id = "roll_test"
	table.rolls_min = 2
	table.rolls_max = 5
	table.nothing_weight = 1.0
	table.item_definition_ids = PackedStringArray(["dev_food_ration", "dev_water_bottle", "dev_bandage"])
	table.weights = PackedFloat32Array([3.0, 2.0, 1.0])
	table.quantities_min = PackedInt32Array([1, 1, 1])
	table.quantities_max = PackedInt32Array([3, 2, 1])
	return table


func _signature(stacks: Array[Dictionary]) -> String:
	var parts: PackedStringArray = []
	for stack: Dictionary in stacks:
		parts.append("%s x%d" % [str(stack["definition_id"]), int(stack["quantity"])])
	return ", ".join(parts)


func test_the_same_seed_gives_the_same_stacks() -> void:
	var table: LootTable = _table()
	for index: int in range(SAMPLE_COUNT):
		var roll_seed: int = LootRoller.seed_for(WORLD_SEED, "container_%06d" % index)
		assert_eq(_signature(LootRoller.roll(table, roll_seed)), _signature(LootRoller.roll(table, roll_seed)), "container %d" % index)


func test_the_seed_depends_on_the_world_seed_and_the_container_id() -> void:
	var seen: Dictionary[int, bool] = {}
	for index: int in range(SAMPLE_COUNT):
		seen[LootRoller.seed_for(WORLD_SEED, "container_%06d" % index)] = true
	assert_eq(seen.size(), SAMPLE_COUNT, "every container has its own seed")
	assert_eq(LootRoller.seed_for(WORLD_SEED, "container_000001"), LootRoller.seed_for(WORLD_SEED, "container_000001"), "no clock and no global state is involved")
	assert_ne(LootRoller.seed_for(WORLD_SEED, "container_000001"), LootRoller.seed_for(WORLD_SEED + 1, "container_000001"), "another world seed gives another roll")
	assert_true(LootRoller.seed_for(WORLD_SEED, "container_000001") >= 0, "seeds are not negative")


func test_containers_differ_and_rolls_stay_inside_the_table() -> void:
	var table: LootTable = _table()
	var signatures: Dictionary[String, int] = {}
	var allowed: Dictionary[String, int] = {"dev_food_ration": 3, "dev_water_bottle": 2, "dev_bandage": 1}
	var found_empty_roll: bool = false
	for index: int in range(SAMPLE_COUNT):
		var stacks: Array[Dictionary] = LootRoller.roll(table, LootRoller.seed_for(WORLD_SEED, "container_%06d" % index))
		signatures[_signature(stacks)] = 1
		assert_true(stacks.size() <= table.rolls_max, "never more stacks than rolls")
		if stacks.size() < table.rolls_min:
			found_empty_roll = true
		for stack: Dictionary in stacks:
			var definition_id: String = str(stack["definition_id"])
			assert_true(allowed.has(definition_id), "only items of the table are found: " + definition_id)
			assert_true(int(stack["quantity"]) >= 1 and int(stack["quantity"]) <= int(allowed.get(definition_id, 0)), "quantity inside the entry's range")
	assert_true(signatures.size() > 20, "containers of one table do not all hold the same (%d different results)" % signatures.size())
	assert_true(found_empty_roll, "a roll may find nothing (nothing_weight)")


func test_a_table_without_rolls_or_entries_gives_nothing() -> void:
	var empty: LootTable = LootTable.new()
	empty.table_id = "empty"
	empty.rolls_min = 0
	empty.rolls_max = 0
	assert_eq(LootRoller.roll(empty, 7).size(), 0)
	assert_eq(LootRoller.roll(null, 7).size(), 0, "no table = nothing to find")
	var nothing_only: LootTable = LootTable.new()
	nothing_only.table_id = "nothing_only"
	nothing_only.rolls_min = 3
	nothing_only.rolls_max = 3
	nothing_only.nothing_weight = 1.0
	assert_eq(nothing_only.validate().size(), 0)
	assert_eq(LootRoller.roll(nothing_only, 7).size(), 0)


func test_table_validation() -> void:
	assert_eq(_table().validate().size(), 0, "the test table is valid")
	var uneven: LootTable = _table()
	uneven.weights = PackedFloat32Array([1.0])
	assert_true(uneven.validate().size() > 0, "parallel arrays must have one length")
	var bad_rolls: LootTable = _table()
	bad_rolls.rolls_min = 4
	bad_rolls.rolls_max = 2
	assert_true(bad_rolls.validate().size() > 0)
	var bad_weight: LootTable = _table()
	bad_weight.weights = PackedFloat32Array([3.0, 0.0, 1.0])
	assert_true(bad_weight.validate().size() > 0, "an entry that can never be picked is a mistake")
	var bad_quantity: LootTable = _table()
	bad_quantity.quantities_min = PackedInt32Array([1, 3, 1])
	assert_true(bad_quantity.validate().size() > 0)
	var items: ItemCatalog = ItemCatalog.load_directory()
	assert_eq(_table().validate_against(items).size(), 0)
	var unknown_item: LootTable = _table()
	unknown_item.item_definition_ids = PackedStringArray(["dev_food_ration", "no_such_item", "dev_bandage"])
	assert_true(unknown_item.validate_against(items).size() > 0, "an entry must name an item that exists")
	var too_many: LootTable = _table()
	too_many.quantities_max = PackedInt32Array([3, 2, 1000])
	assert_true(too_many.validate_against(items).size() > 0, "a roll may not be more than one stack holds")


func test_the_shipped_tables_and_container_definitions_are_valid() -> void:
	var items: ItemCatalog = ItemCatalog.load_directory()
	var tables: LootTableCatalog = LootTableCatalog.load_directory()
	assert_true(tables.size() >= 3, "tables for several building types are shipped")
	assert_eq(tables.validate_against(items).size(), 0, "; ".join(tables.validate_against(items)))
	var definitions: ContainerCatalog = ContainerCatalog.load_directory()
	assert_true(definitions.has("dev_crate") and definitions.has("dev_cabinet"), "a crate and a cabinet are shipped")
	assert_eq(definitions.validate_against(tables).size(), 0, "; ".join(definitions.validate_against(tables)))
	for definition_id: String in definitions.definition_ids():
		assert_true(definitions.get_definition(definition_id).slot_count >= 1)
	var settings: ContainerSettings = ContainerSettings.load_or_default()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	# The shipped tables do not all hold the same things.
	var contents: Dictionary[String, bool] = {}
	for table_id: String in tables.table_ids():
		contents[", ".join(tables.get_table(table_id).item_definition_ids)] = true
	assert_true(contents.size() >= 3, "tables differ by building type")
