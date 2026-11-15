extends TestCase
## P2-T2: InventoryService transactions that take items out of an inventory
## (drop one, drop all, remove a quantity), their ServerWorld wrappers, the
## save round trip and the client mirror methods. No network here.

const PICKUP_RANGE: float = 2.0
const HALF_EXTENT: float = 50.0
const CELL: String = "cell_0_0"
const WORLD: String = "inventory_transactions_test"
const SINGLE: String = "test_item"
const STACK: String = "test_stack"
const STACK_MAX: int = 10
const DROP_AT: Vector3 = Vector3(3.5, 0.0, -7.25)

var _catalog: ItemCatalog = null
var _ids: EntityIdGenerator = null
var _registry: EntityRegistry = null
var _service: InventoryService = null
var _events: Array[Dictionary] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_catalog = _new_catalog()
	_ids = EntityIdGenerator.new()
	_registry = EntityRegistry.new()
	_service = InventoryService.new(_catalog, _ids, _registry, PICKUP_RANGE, HALF_EXTENT)
	_events = []
	# The listener captures the array, not this test object (no reference cycle).
	var events: Array[Dictionary] = _events
	_service.transaction_committed.connect(func(event: Dictionary) -> void: events.append(event))


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _new_catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.new()
	var single: ItemDefinition = ItemDefinition.new()
	single.definition_id = SINGLE
	single.max_stack = 1
	catalog.add(single)
	var stack: ItemDefinition = ItemDefinition.new()
	stack.definition_id = STACK
	stack.max_stack = STACK_MAX
	catalog.add(stack)
	return catalog


## Spawns an item at the origin and puts it into `inventory_id`.
func _give(inventory_id: String, definition_id: String = SINGLE, quantity: int = 1) -> String:
	var item_id: String = _service.spawn_world_item(definition_id, quantity, CELL, Vector3.ZERO)
	var result: ActionResult = _service.try_pickup(inventory_id, item_id, Vector3.ZERO)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


func _event_types() -> Array:
	var types: Array = []
	for event: Dictionary in _events:
		types.append(event.get("event_type", ""))
	return types


func _ids_of(items: Array[ItemInstance]) -> Array:
	var ids: Array = []
	for item: ItemInstance in items:
		ids.append(item.item_instance_id)
	return ids


func _world(half_extent: float = HALF_EXTENT) -> ServerWorld:
	var gameplay: GameplaySettings = GameplaySettings.new()
	gameplay.world_half_extent_m = half_extent
	return ServerWorld.new(WORLD, gameplay, _new_catalog())


# ------------------------------------------------------------ drop one

func test_drop_moves_the_item_to_the_world_at_the_given_position() -> void:
	var inventory_id: String = _service.create_inventory(3)
	var item_id: String = _give(inventory_id, STACK, 4)
	_events.clear()
	var result: ActionResult = _service.drop_item(inventory_id, item_id, CELL, DROP_AT)
	assert_true(result.ok, result.reason)
	var item: ItemInstance = _service.get_item(item_id)
	assert_eq(item.location_type, ItemInstance.LOCATION_WORLD)
	assert_eq(item.location_id, CELL)
	assert_eq(item.slot_id, "", "a world item has no slot")
	assert_eq(item.quantity, 4, "the whole stack is dropped")
	assert_eq(_service.world_item_ids(), PackedStringArray([item_id]))
	assert_eq(_service.world_position_of(item_id), DROP_AT)
	assert_eq(_service.items_in_inventory(inventory_id).size(), 0)
	assert_eq(_service.item_count(), 1, "nothing was created or lost")
	assert_eq(result.event, {
		"event_type": InventoryService.EVENT_ITEMS_DROPPED,
		"inventory_id": inventory_id,
		"item_instance_ids": [item_id],
		"cell_id": CELL,
		"position": [DROP_AT.x, DROP_AT.y, DROP_AT.z],
	})
	assert_eq(_events, [result.event], "listeners are told once, with the same event")
	assert_eq(_service.describe_world_item(item_id), {"item_instance_id": item_id, "definition_id": STACK, "quantity": 4, "position": DROP_AT})


func test_drop_failures_change_nothing() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(2)
	var carried: String = _give(mine)
	var other: String = _give(theirs)
	var lying: String = _service.spawn_world_item(SINGLE, 1, CELL, Vector3(1, 0, 1))
	var before: Dictionary = _service.to_snapshot()
	var tombstones_before: PackedStringArray = _registry.tombstones()
	_events.clear()

	assert_eq(_service.drop_item("inventory_999999", carried, CELL, DROP_AT).reason, InventoryService.REASON_UNKNOWN_INVENTORY)
	assert_eq(_service.drop_item(mine, "item_999999", CELL, DROP_AT).reason, InventoryService.REASON_UNKNOWN_ITEM, "an item that does not exist")
	assert_eq(_service.drop_item(mine, other, CELL, DROP_AT).reason, InventoryService.REASON_NOT_IN_INVENTORY, "someone else's item")
	assert_eq(_service.drop_item(mine, lying, CELL, DROP_AT).reason, InventoryService.REASON_NOT_IN_INVENTORY, "an item already lying in the world")
	assert_eq(_service.drop_item(mine, carried, "", DROP_AT).reason, InventoryService.REASON_BAD_CELL)
	for outside: Vector3 in [Vector3(HALF_EXTENT + 0.5, 0, 0), Vector3(0, 0, -HALF_EXTENT - 0.5), Vector3(NAN, 0, 0), Vector3(0, INF, 0)]:
		var result: ActionResult = _service.drop_item(mine, carried, CELL, outside)
		assert_false(result.ok, "outside the world: %s" % str(outside))
		assert_eq(result.reason, InventoryService.REASON_BAD_POSITION)

	assert_eq(_service.to_snapshot(), before, "a refused drop changes nothing")
	assert_eq(_registry.tombstones(), tombstones_before)
	assert_eq(_events.size(), 0, "a refused drop tells no listener")
	assert_true(_service.drop_item(mine, carried, CELL, Vector3(HALF_EXTENT, 0, -HALF_EXTENT)).ok, "the world edge itself is inside")


func test_drop_is_committed_once_and_the_item_can_be_picked_up_again() -> void:
	var first: String = _service.create_inventory(1)
	var second: String = _service.create_inventory(1)
	var item_id: String = _give(first)
	assert_true(_service.drop_item(first, item_id, CELL, DROP_AT).ok)
	assert_eq(_service.drop_item(first, item_id, CELL, DROP_AT).reason, InventoryService.REASON_NOT_IN_INVENTORY, "a repeated drop of the same item fails")
	assert_eq(_service.try_pickup(second, item_id, Vector3.ZERO).reason, InventoryService.REASON_TOO_FAR, "it lies where it was dropped")
	assert_true(_service.try_pickup(second, item_id, DROP_AT).ok)
	assert_eq(_ids_of(_service.items_in_inventory(second)), [item_id])
	assert_eq(_service.world_item_ids().size(), 0)
	assert_eq(_service.item_count(), 1, "one item all along: no copy, no loss")
	# The slot the drop freed is usable again.
	var again: String = _give(first)
	assert_eq(_service.get_item(again).slot_id, "slot_0")


# ------------------------------------------------------------ drop all

func test_drop_all_moves_every_item_of_one_inventory_to_one_position() -> void:
	var mine: String = _service.create_inventory(4)
	var theirs: String = _service.create_inventory(4)
	var a: String = _give(mine)
	var b: String = _give(mine, STACK, 7)
	var c: String = _give(mine)
	var other: String = _give(theirs)
	_events.clear()
	var result: ActionResult = _service.drop_all_items(mine, CELL, DROP_AT)
	assert_true(result.ok, result.reason)
	assert_eq(result.event.get("event_type", ""), InventoryService.EVENT_ITEMS_DROPPED)
	assert_eq(result.event.get("inventory_id", ""), mine)
	assert_eq(result.event.get("item_instance_ids", []), [a, b, c], "slot order")
	assert_eq(_events, [result.event], "one event for the whole inventory")
	assert_eq(_service.items_in_inventory(mine).size(), 0)
	assert_eq(_service.world_item_ids(), PackedStringArray([a, b, c]))
	for item_id: String in [a, b, c]:
		assert_eq(_service.world_position_of(item_id), DROP_AT)
		assert_eq(_service.get_item(item_id).location_id, CELL)
		assert_eq(_service.get_item(item_id).slot_id, "")
	assert_eq(_service.get_item(b).quantity, 7)
	assert_eq(_ids_of(_service.items_in_inventory(theirs)), [other], "other inventories are untouched")
	assert_eq(_service.item_count(), 4)


func test_drop_all_of_an_empty_inventory_succeeds_without_an_event() -> void:
	var mine: String = _service.create_inventory(2)
	var before: Dictionary = _service.to_snapshot()
	var result: ActionResult = _service.drop_all_items(mine, CELL, DROP_AT)
	assert_true(result.ok, result.reason)
	assert_eq(result.event.get("item_instance_ids", null), [])
	assert_eq(_events.size(), 0, "nothing changed, nothing to tell")
	assert_eq(_service.to_snapshot(), before)


func test_drop_all_failures_move_nothing() -> void:
	var mine: String = _service.create_inventory(3)
	_give(mine)
	_give(mine)
	var before: Dictionary = _service.to_snapshot()
	_events.clear()
	assert_eq(_service.drop_all_items("inventory_999999", CELL, DROP_AT).reason, InventoryService.REASON_UNKNOWN_INVENTORY)
	assert_eq(_service.drop_all_items(mine, CELL, Vector3(0, 0, HALF_EXTENT * 2.0)).reason, InventoryService.REASON_BAD_POSITION)
	assert_eq(_service.drop_all_items(mine, "", DROP_AT).reason, InventoryService.REASON_BAD_CELL)
	assert_eq(_service.to_snapshot(), before, "all or nothing")
	assert_eq(_events.size(), 0)


# ------------------------------------------------------------ remove

func test_removing_part_of_a_stack_only_lowers_the_quantity() -> void:
	var mine: String = _service.create_inventory(2)
	var item_id: String = _give(mine, STACK, 5)
	_events.clear()
	var result: ActionResult = _service.remove_item(mine, item_id, 2)
	assert_true(result.ok, result.reason)
	var item: ItemInstance = _service.get_item(item_id)
	assert_not_null(item, "the instance stays")
	assert_eq(item.quantity, 3)
	assert_eq(item.location_id, mine)
	assert_eq(item.slot_id, "slot_0")
	assert_true(_registry.has(item_id))
	assert_eq(result.event, {
		"event_type": InventoryService.EVENT_ITEM_REMOVED,
		"inventory_id": mine,
		"item_instance_id": item_id,
		"definition_id": STACK,
		"removed_quantity": 2,
		"remaining_quantity": 3,
	})
	assert_eq(_events, [result.event])


func test_removing_the_whole_stack_deletes_the_instance_and_never_reuses_its_id() -> void:
	var mine: String = _service.create_inventory(1)
	var item_id: String = _give(mine, STACK, 5)
	assert_true(_service.remove_item(mine, item_id, 3).ok)
	_events.clear()
	var result: ActionResult = _service.remove_item(mine, item_id, 2)
	assert_true(result.ok, result.reason)
	assert_eq(result.event.get("remaining_quantity", -1), 0)
	assert_null(_service.get_item(item_id), "the instance is gone")
	assert_eq(_service.items_in_inventory(mine).size(), 0)
	assert_eq(_service.item_count(), 0)
	assert_false(_registry.has(item_id))
	assert_true(_registry.is_tombstoned(item_id), "the id is retired")
	assert_eq(_event_types(), [InventoryService.EVENT_ITEM_REMOVED])
	assert_eq(_service.remove_item(mine, item_id, 1).reason, InventoryService.REASON_UNKNOWN_ITEM, "it cannot be removed twice")
	# A new item gets a new id and the freed slot.
	var next_id: String = _give(mine)
	assert_ne(next_id, item_id)
	assert_true(EntityIdGenerator.sequence_of(next_id) > EntityIdGenerator.sequence_of(item_id))
	assert_eq(_service.get_item(next_id).slot_id, "slot_0")
	assert_ne(_registry.register(item_id, InventoryService.ENTITY_KIND_ITEM), OK, "the retired id cannot be registered again")


func test_remove_failures_change_nothing() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(2)
	var carried: String = _give(mine, STACK, 3)
	var other: String = _give(theirs, STACK, 3)
	var lying: String = _service.spawn_world_item(STACK, 3, CELL, Vector3.ZERO)
	var before: Dictionary = _service.to_snapshot()
	_events.clear()
	assert_eq(_service.remove_item("inventory_999999", carried, 1).reason, InventoryService.REASON_UNKNOWN_INVENTORY)
	assert_eq(_service.remove_item(mine, "item_999999", 1).reason, InventoryService.REASON_UNKNOWN_ITEM)
	assert_eq(_service.remove_item(mine, other, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "someone else's item")
	assert_eq(_service.remove_item(mine, lying, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "an item lying in the world")
	assert_eq(_service.remove_item(mine, carried, 0).reason, InventoryService.REASON_BAD_QUANTITY)
	assert_eq(_service.remove_item(mine, carried, -1).reason, InventoryService.REASON_BAD_QUANTITY)
	assert_eq(_service.remove_item(mine, carried, 4).reason, InventoryService.REASON_BAD_QUANTITY, "more than the stack holds")
	assert_eq(_service.to_snapshot(), before, "a refused removal changes nothing")
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(_events.size(), 0)


func test_pickup_is_announced_to_listeners_too() -> void:
	var mine: String = _service.create_inventory(1)
	var item_id: String = _service.spawn_world_item(SINGLE, 1, CELL, Vector3.ZERO)
	_events.clear()
	var result: ActionResult = _service.try_pickup(mine, item_id, Vector3.ZERO)
	assert_true(result.ok)
	assert_eq(_events, [result.event], "every committed transaction is announced")
	assert_eq(_event_types(), [InventoryService.EVENT_ITEM_PICKED_UP])


# ------------------------------------------------------------ save round trip

func test_snapshot_round_trip_keeps_dropped_positions_and_reduced_stacks() -> void:
	var mine: String = _service.create_inventory(3)
	var dropped: String = _give(mine)
	var reduced: String = _give(mine, STACK, 6)
	var eaten: String = _give(mine, STACK, 2)
	assert_true(_service.drop_item(mine, dropped, CELL, DROP_AT).ok)
	assert_true(_service.remove_item(mine, reduced, 4).ok)
	assert_true(_service.remove_item(mine, eaten, 2).ok)
	var json_text: String = JSON.stringify(_service.to_snapshot())
	var restored: InventoryService = InventoryService.new(_catalog, EntityIdGenerator.new(), EntityRegistry.new(), PICKUP_RANGE, HALF_EXTENT)
	assert_eq(restored.restore_snapshot(JSON.parse_string(json_text) as Dictionary).size(), 0)
	assert_eq(JSON.stringify(restored.to_snapshot()), json_text)
	assert_eq(restored.world_item_ids(), PackedStringArray([dropped]))
	assert_eq(restored.world_position_of(dropped), DROP_AT)
	assert_eq(restored.get_item(reduced).quantity, 2)
	assert_null(restored.get_item(eaten))
	assert_eq(restored.item_count(), 2)


func test_world_wrappers_use_the_server_position_and_survive_a_save_round_trip() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var kept: String = world.inventory.spawn_world_item(STACK, 5, CELL, Vector3.ZERO)
	var dropped: String = world.inventory.spawn_world_item(SINGLE, 1, CELL, Vector3.ZERO)
	var eaten: String = world.inventory.spawn_world_item(STACK, 2, CELL, Vector3.ZERO)
	var bobs: String = world.inventory.spawn_world_item(SINGLE, 1, CELL, Vector3.ZERO)
	for item_id: String in [kept, dropped, eaten]:
		assert_true(world.try_pickup(alice.player_id, item_id).ok)
	assert_true(world.try_pickup(bob.player_id, bobs).ok)
	alice.position = DROP_AT

	assert_eq(world.try_drop_item(alice.player_id, bobs).reason, InventoryService.REASON_NOT_IN_INVENTORY, "alice cannot drop bob's item")
	var drop: ActionResult = world.try_drop_item(alice.player_id, dropped)
	assert_true(drop.ok, drop.reason)
	assert_eq(world.inventory.world_position_of(dropped), DROP_AT, "dropped where the server knows the player to be")
	assert_eq(world.inventory.get_item(dropped).location_id, DevWorldSeed.DEV_CELL_ID)
	assert_true(world.remove_player_item(alice.player_id, kept, 3).ok)
	assert_true(world.remove_player_item(alice.player_id, eaten, 2).ok)
	assert_eq(world.remove_player_item(alice.player_id, bobs, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY)
	assert_eq(world.try_drop_item("player_999999", kept).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_eq(world.drop_all_player_items("player_999999").reason, ServerWorld.REASON_UNKNOWN_PLAYER)
	assert_eq(world.remove_player_item("player_999999", kept, 1).reason, ServerWorld.REASON_UNKNOWN_PLAYER)

	# Server rules may act on a player that is offline (e.g. after a death).
	world.leave(bob.player_id)
	bob.position = Vector3(-4, 0, 9)
	assert_eq(world.try_drop_item(bob.player_id, bobs).reason, ServerWorld.REASON_NOT_ONLINE, "an intent needs an online player")
	var all: ActionResult = world.drop_all_player_items(bob.player_id)
	assert_true(all.ok, all.reason)
	assert_eq(all.event.get("item_instance_ids", []), [bobs])
	assert_eq(world.inventory.world_position_of(bobs), Vector3(-4, 0, 9))

	# Save documents -> JSON -> a brand-new world.
	var documents: Dictionary = JSON.parse_string(JSON.stringify(world.to_documents())) as Dictionary
	var restored: ServerWorld = _world()
	var errors: PackedStringArray = restored.restore_documents(documents["world_state"], documents["players"])
	assert_eq(errors.size(), 0, "; ".join(errors))
	assert_eq(restored.inventory.world_item_ids(), PackedStringArray([dropped, bobs]))
	assert_eq(restored.inventory.world_position_of(dropped), DROP_AT)
	assert_eq(restored.inventory.world_position_of(bobs), Vector3(-4, 0, 9))
	assert_eq(_ids_of(restored.inventory.items_in_inventory(alice.inventory_id)), [kept])
	assert_eq(restored.inventory.get_item(kept).quantity, 2)
	assert_eq(restored.inventory.items_in_inventory(bob.inventory_id).size(), 0)
	assert_null(restored.inventory.get_item(eaten))
	assert_true(restored.registry.is_tombstoned(eaten), "the removed id stays retired after a restart")
	var fresh: String = restored.inventory.spawn_world_item(SINGLE, 1, CELL, Vector3.ZERO)
	assert_true(EntityIdGenerator.sequence_of(fresh) > EntityIdGenerator.sequence_of(bobs), "new ids continue after every id ever used: " + fresh)
	assert_ne(fresh, eaten)


func test_world_wrapper_keeps_a_drop_inside_the_world() -> void:
	const SMALL: float = 10.0
	var world: ServerWorld = _world(SMALL)
	var alice: PlayerState = world.join("alice")
	var item_id: String = world.inventory.spawn_world_item(SINGLE, 1, CELL, Vector3.ZERO)
	assert_true(world.try_pickup(alice.player_id, item_id).ok)
	assert_eq(world.inventory.drop_item(alice.inventory_id, item_id, CELL, Vector3(SMALL + 1.0, 0, 0)).reason, InventoryService.REASON_BAD_POSITION, "the world's own inventory knows the world size")
	# A player state outside the world (e.g. an old save of a larger world).
	alice.position = Vector3(SMALL * 3.0, 0, -SMALL * 3.0)
	assert_true(world.try_drop_item(alice.player_id, item_id).ok)
	assert_eq(world.inventory.world_position_of(item_id), Vector3(SMALL, 0, -SMALL))


# ------------------------------------------------------------ client mirror

func test_client_mirror_adds_world_items_and_removes_inventory_items() -> void:
	var state: ClientWorldState = ClientWorldState.new()
	var changes: Array[int] = [0]
	state.changed.connect(func() -> void: changes[0] += 1)
	var entry: Dictionary = {"item_instance_id": "item_000007", "definition_id": STACK, "quantity": 3, "position": DROP_AT}
	assert_true(state.apply_world_item_added(entry))
	assert_eq(state.world_items.keys(), ["item_000007"])
	assert_eq(state.world_items["item_000007"], entry)
	var moved: Dictionary = entry.duplicate()
	moved["position"] = Vector3.ONE
	moved["extra"] = "ignored"
	assert_true(state.apply_world_item_added(moved), "the same id is replaced")
	assert_eq(state.world_items.size(), 1)
	assert_eq(state.world_items["item_000007"]["position"], Vector3.ONE)
	assert_false(state.world_items["item_000007"].has("extra"), "only the known fields are kept")
	assert_eq(changes[0], 2)

	var bad_entries: Array = [
		{}, "junk", 7, null,
		{"item_instance_id": "", "definition_id": STACK, "quantity": 1, "position": DROP_AT},
		{"item_instance_id": "x".repeat(ClientWorldState.ITEM_ID_MAX_LENGTH + 1), "definition_id": STACK, "quantity": 1, "position": DROP_AT},
		{"item_instance_id": 5, "definition_id": STACK, "quantity": 1, "position": DROP_AT},
		{"item_instance_id": "item_000008", "definition_id": "Not Snake", "quantity": 1, "position": DROP_AT},
		{"item_instance_id": "item_000008", "definition_id": STACK, "quantity": 0, "position": DROP_AT},
		{"item_instance_id": "item_000008", "definition_id": STACK, "quantity": 1.0, "position": DROP_AT},
		{"item_instance_id": "item_000008", "definition_id": STACK, "quantity": 1, "position": [1, 2, 3]},
		{"item_instance_id": "item_000008", "definition_id": STACK, "quantity": 1, "position": Vector3(NAN, 0, 0)},
		{"item_instance_id": "item_000008", "definition_id": STACK, "quantity": 1},
	]
	for bad: Variant in bad_entries:
		assert_false(ClientWorldState.is_valid_world_item(bad), "rejected: %s" % str(bad))
		assert_false(state.apply_world_item_added(bad if typeof(bad) == TYPE_DICTIONARY else {}))
	assert_eq(state.world_items.size(), 1, "malformed entries change nothing")
	assert_eq(changes[0], 2)

	var carried: Dictionary = {"schema_version": 1, "item_instance_id": "item_000009", "definition_id": STACK, "quantity": 4, "location_type": "inventory", "location_id": "inventory_000001", "slot_id": "slot_0"}
	assert_true(state.apply_inventory_item(carried))
	assert_eq(state.get_inventory_item("item_000009").get("quantity", 0), 4)
	var fewer: Dictionary = carried.duplicate()
	fewer["quantity"] = 1
	assert_true(state.apply_inventory_item(fewer), "a changed stack replaces the entry")
	assert_eq(state.inventory.size(), 1)
	assert_eq(state.get_inventory_item("item_000009").get("quantity", 0), 1)
	assert_eq(state.get_inventory_item("item_missing"), {})
	changes[0] = 0
	assert_false(state.apply_inventory_item_removed("item_missing"), "unknown ids are ignored")
	assert_eq(changes[0], 0)
	assert_true(state.apply_inventory_item_removed("item_000009"))
	assert_false(state.has_inventory_item("item_000009"))
	assert_eq(state.inventory.size(), 0)
	assert_eq(changes[0], 1)
