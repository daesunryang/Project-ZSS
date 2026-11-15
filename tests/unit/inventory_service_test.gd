extends TestCase
## InventoryService: pickup transaction rules, atomicity, snapshot round trip.

const PICKUP_RANGE: float = 2.0
const CELL: String = "cell_0_0"

var _service: InventoryService = null
var _catalog: ItemCatalog = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_catalog = ItemCatalog.new()
	var definition: ItemDefinition = ItemDefinition.new()
	definition.definition_id = "test_item"
	definition.max_stack = 5
	_catalog.add(definition)
	_service = _new_service()


func after_each() -> void:
	GameLogger.set_capture(false)


func _new_service() -> InventoryService:
	return InventoryService.new(_catalog, EntityIdGenerator.new(), EntityRegistry.new(), PICKUP_RANGE)


func test_shipped_catalog_contains_dev_item() -> void:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	assert_true(catalog.has("dev_test_item"))


func test_pickup_moves_item_into_inventory() -> void:
	var inventory_id: String = _service.create_inventory(2)
	var item_id: String = _service.spawn_world_item("test_item", 1, CELL, Vector3(1, 0, 0))
	var result: ActionResult = _service.try_pickup(inventory_id, item_id, Vector3.ZERO)
	assert_true(result.ok, result.reason)
	assert_eq(result.event["event_type"], InventoryService.EVENT_ITEM_PICKED_UP)
	var item: ItemInstance = _service.get_item(item_id)
	assert_eq(item.location_type, ItemInstance.LOCATION_INVENTORY)
	assert_eq(item.location_id, inventory_id)
	assert_eq(item.slot_id, "slot_0")
	assert_eq(_service.world_item_ids().size(), 0)
	assert_eq(_service.items_in_inventory(inventory_id).size(), 1)


func test_second_concurrent_pickup_fails_without_duplication() -> void:
	var first: String = _service.create_inventory(2)
	var second: String = _service.create_inventory(2)
	var item_id: String = _service.spawn_world_item("test_item", 1, CELL, Vector3.ZERO)
	assert_true(_service.try_pickup(first, item_id, Vector3.ZERO).ok)
	var late: ActionResult = _service.try_pickup(second, item_id, Vector3.ZERO)
	assert_false(late.ok)
	assert_eq(late.reason, InventoryService.REASON_NOT_IN_WORLD)
	assert_eq(_service.items_in_inventory(first).size(), 1)
	assert_eq(_service.items_in_inventory(second).size(), 0)


func test_rejections_change_nothing() -> void:
	var inventory_id: String = _service.create_inventory(1)
	var item_id: String = _service.spawn_world_item("test_item", 1, CELL, Vector3(10, 0, 0))
	var before: Dictionary = _service.to_snapshot()
	assert_eq(_service.try_pickup(inventory_id, item_id, Vector3.ZERO).reason, InventoryService.REASON_TOO_FAR)
	assert_eq(_service.try_pickup("inventory_999999", item_id, Vector3(10, 0, 0)).reason, InventoryService.REASON_UNKNOWN_INVENTORY)
	assert_eq(_service.try_pickup(inventory_id, "item_999999", Vector3.ZERO).reason, InventoryService.REASON_UNKNOWN_ITEM)
	assert_eq(_service.to_snapshot(), before)


func test_full_inventory_rejects_pickup() -> void:
	var inventory_id: String = _service.create_inventory(1)
	# A full stack (P2-T15: a picked-up item joins a carried stack that has
	# room, so "full" means no free slot AND no room in a stack of its kind).
	var a: String = _service.spawn_world_item("test_item", 5, CELL, Vector3.ZERO)
	var b: String = _service.spawn_world_item("test_item", 1, CELL, Vector3.ZERO)
	assert_true(_service.try_pickup(inventory_id, a, Vector3.ZERO).ok)
	assert_eq(_service.try_pickup(inventory_id, b, Vector3.ZERO).reason, InventoryService.REASON_INVENTORY_FULL)
	assert_eq(_service.world_item_ids(), PackedStringArray([b]))


func test_spawn_validates_definition_and_quantity() -> void:
	assert_eq(_service.spawn_world_item("unknown", 1, CELL, Vector3.ZERO), "")
	assert_eq(_service.spawn_world_item("test_item", 0, CELL, Vector3.ZERO), "")
	assert_eq(_service.spawn_world_item("test_item", 6, CELL, Vector3.ZERO), "")


func test_snapshot_round_trip_through_json() -> void:
	var inventory_id: String = _service.create_inventory(3)
	var carried: String = _service.spawn_world_item("test_item", 2, CELL, Vector3.ZERO)
	var lying: String = _service.spawn_world_item("test_item", 1, CELL, Vector3(4.5, 0, -2))
	_service.try_pickup(inventory_id, carried, Vector3.ZERO)
	var json_text: String = JSON.stringify(_service.to_snapshot())
	var parsed: Dictionary = JSON.parse_string(json_text) as Dictionary

	var ids: EntityIdGenerator = EntityIdGenerator.new()
	var restored: InventoryService = InventoryService.new(_catalog, ids, EntityRegistry.new(), PICKUP_RANGE)
	assert_eq(restored.restore_snapshot(parsed).size(), 0)
	assert_eq(JSON.stringify(restored.to_snapshot()), json_text)
	assert_eq(restored.world_position_of(lying), Vector3(4.5, 0, -2))
	assert_eq(restored.items_in_inventory(inventory_id)[0].item_instance_id, carried)
	assert_ne(ids.next_id("item"), lying, "restored ids must not be generated again")


func test_restore_rejects_inconsistent_snapshot_atomically() -> void:
	var inventory_id: String = _service.create_inventory(1)
	_service.spawn_world_item("test_item", 1, CELL, Vector3.ZERO)
	var good: Dictionary = _service.to_snapshot()
	var bad: Dictionary = good.duplicate(true)
	var item: Dictionary = (bad[InventoryService.SNAPSHOT_ITEMS] as Array)[0]
	(bad[InventoryService.SNAPSHOT_ITEMS] as Array).append(item.duplicate())
	var errors: PackedStringArray = _service.restore_snapshot(bad)
	assert_true(errors.size() > 0)
	assert_eq(_service.to_snapshot(), good, "failed restore must not change state")
	assert_true(_service.has_inventory(inventory_id))


func test_item_dict_validation() -> void:
	var valid: Dictionary = {"schema_version": 1, "item_instance_id": "item_000001", "definition_id": "test_item", "quantity": 1, "location_type": "world", "location_id": CELL}
	assert_eq(ItemInstance.validate_dict(valid).size(), 0)
	var invalid: Dictionary = valid.duplicate()
	invalid["quantity"] = 0
	invalid["location_type"] = "pocket"
	invalid["condition"] = 1.5
	assert_eq(ItemInstance.validate_dict(invalid).size(), 3)
	assert_null(ItemInstance.from_dict({"schema_version": 1}))
