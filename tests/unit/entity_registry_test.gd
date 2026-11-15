extends TestCase
## EntityIdGenerator / EntityRegistry: uniqueness, no reuse, restore.


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


func test_generator_produces_sequential_unique_ids() -> void:
	var generator: EntityIdGenerator = EntityIdGenerator.new()
	assert_eq(generator.next_id("item"), "item_000001")
	assert_eq(generator.next_id("player"), "player_000002")
	assert_eq(generator.get_next_sequence(), 3)


func test_generator_rejects_invalid_kind() -> void:
	var generator: EntityIdGenerator = EntityIdGenerator.new()
	assert_eq(generator.next_id("Bad Kind"), "")
	assert_eq(generator.next_id(""), "")
	assert_eq(generator.get_next_sequence(), EntityIdGenerator.FIRST_SEQUENCE)


func test_generator_never_rewinds() -> void:
	var generator: EntityIdGenerator = EntityIdGenerator.new()
	assert_eq(generator.restore_next_sequence(10), OK)
	assert_eq(generator.restore_next_sequence(5), ERR_INVALID_PARAMETER)
	assert_eq(generator.next_id("item"), "item_000010")


func test_reserve_existing_id_skips_past_loaded_ids() -> void:
	var generator: EntityIdGenerator = EntityIdGenerator.new()
	generator.reserve_existing_id("item_000041")
	generator.reserve_existing_id("item_000007")
	generator.reserve_existing_id("not-an-id")
	assert_eq(generator.next_id("item"), "item_000042")


func test_registry_rejects_duplicates_and_reuse() -> void:
	var registry: EntityRegistry = EntityRegistry.new()
	assert_eq(registry.register("item_000001", "item"), OK)
	assert_eq(registry.register("item_000001", "item"), ERR_ALREADY_EXISTS)
	assert_eq(registry.remove("item_000001"), OK)
	assert_false(registry.has("item_000001"))
	assert_eq(registry.register("item_000001", "item"), ERR_ALREADY_IN_USE)
	assert_eq(registry.remove("item_000001"), ERR_DOES_NOT_EXIST)


func test_registry_queries_are_sorted_by_kind() -> void:
	var registry: EntityRegistry = EntityRegistry.new()
	registry.register("item_000003", "item")
	registry.register("player_000002", "player")
	registry.register("item_000001", "item")
	assert_eq(registry.ids_of_kind("item"), PackedStringArray(["item_000001", "item_000003"]))
	assert_eq(registry.kind_of("player_000002"), "player")
	assert_eq(registry.kind_of("missing"), "")
	assert_eq(registry.count(), 3)


func test_tombstones_survive_restore() -> void:
	var registry: EntityRegistry = EntityRegistry.new()
	registry.register("item_000001", "item")
	registry.remove("item_000001")
	var restored: EntityRegistry = EntityRegistry.new()
	restored.restore_tombstones(registry.tombstones())
	assert_eq(restored.register("item_000001", "item"), ERR_ALREADY_IN_USE)
