extends TestCase
## InventoryService.transfer_item (added in P2-T14, docs/09 §14.28): a
## quantity of an item moves from one inventory into another. All or
## nothing, the units are conserved and ids stay unique.
##
## The player rule that called it (the one-sided hand-over,
## ServerWorld.try_hand_over_item) was withdrawn in P2-T15 (docs/00 ADR-021:
## items travel over the ground or through a trade), and its tests went with
## it. The transaction stays as a server rule entry and keeps these tests
## (this file was tests/unit/hand_over_test.gd). The stack layouts are built
## with pickups that do not merge (merging on pickup: ground_transfer_test.gd).

const CELL: String = "cell_0_0"
const PICKUP_RANGE: float = 2.0
const MISSING_ITEM_ID: String = "item_999999"
const MISSING_INVENTORY_ID: String = "inventory_999999"
## Food: stacks of up to FOOD_MAX, one unit takes FOOD_HUNGER off the hunger.
const FOOD: String = "t14_food"
const FOOD_MAX: int = 5
const FOOD_HUNGER: float = 30.0
## An item without any use, one per slot.
const PLAIN: String = "t14_plain"
## An item without any use that stacks up to BULK_MAX.
const BULK: String = "t14_bulk"
const BULK_MAX: int = 10
const SOAK_SEED: int = 20261115
const SOAK_ROUNDS: int = 300

var _catalog: ItemCatalog = null
var _ids: EntityIdGenerator = null
var _registry: EntityRegistry = null
var _service: InventoryService = null
var _events: Array[Dictionary] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_catalog = _new_catalog(ItemCatalog.new())
	_ids = EntityIdGenerator.new()
	_registry = EntityRegistry.new()
	_service = InventoryService.new(_catalog, _ids, _registry, PICKUP_RANGE)
	# These tests place several stacks of one kind side by side with pickups.
	_service.merge_on_pickup = false
	_events = []
	# The listener captures the array, not this test object (no reference cycle).
	var events: Array[Dictionary] = _events
	_service.transaction_committed.connect(func(event: Dictionary) -> void: events.append(event))


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _new_catalog(catalog: ItemCatalog) -> ItemCatalog:
	var food: ItemDefinition = ItemDefinition.new()
	food.definition_id = FOOD
	food.max_stack = FOOD_MAX
	food.consume_hunger_reduction = FOOD_HUNGER
	catalog.add(food)
	var plain: ItemDefinition = ItemDefinition.new()
	plain.definition_id = PLAIN
	plain.max_stack = 1
	catalog.add(plain)
	var bulk: ItemDefinition = ItemDefinition.new()
	bulk.definition_id = BULK
	bulk.max_stack = BULK_MAX
	catalog.add(bulk)
	return catalog


## Spawns an item at the origin and puts it into `inventory_id` (bare service).
func _put(inventory_id: String, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = _service.spawn_world_item(definition_id, quantity, CELL, Vector3.ZERO)
	var result: ActionResult = _service.try_pickup(inventory_id, item_id, Vector3.ZERO)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


## [slot, definition, quantity] of everything in an inventory, in slot order.
func _rows(service: InventoryService, inventory_id: String) -> Array:
	var rows: Array = []
	for item: ItemInstance in service.items_in_inventory(inventory_id):
		rows.append([item.slot_id, item.definition_id, item.quantity])
	return rows


## Units per definition over every item that exists (carried or lying).
func _totals(service: InventoryService) -> Dictionary:
	var totals: Dictionary = {}
	for entry: Dictionary in service.to_snapshot()[InventoryService.SNAPSHOT_ITEMS]:
		var definition_id: String = str(entry["definition_id"])
		totals[definition_id] = int(totals.get(definition_id, 0)) + int(entry["quantity"])
	return totals


# ------------------------------------------------------------ the transaction

func test_a_whole_stack_moves_as_it_is_and_keeps_its_id() -> void:
	var mine: String = _service.create_inventory(3)
	var theirs: String = _service.create_inventory(3)
	_put(theirs, PLAIN)
	var item_id: String = _put(mine, BULK, 4)
	var next_sequence: int = _ids.get_next_sequence()
	_events.clear()

	var result: ActionResult = _service.transfer_item(mine, item_id, theirs, 4)
	assert_true(result.ok, result.reason)
	assert_eq(_rows(_service, mine), [], "the giver holds nothing any more")
	assert_eq(_rows(_service, theirs), [["slot_0", PLAIN, 1], ["slot_1", BULK, 4]], "the stack took the receiver's first free slot")
	var item: ItemInstance = _service.get_item(item_id)
	assert_not_null(item, "the same instance, now carried by the receiver")
	assert_eq(item.location_type, ItemInstance.LOCATION_INVENTORY)
	assert_eq(item.location_id, theirs)
	assert_eq(_service.item_count(), 2, "nothing was created or lost")
	assert_eq(_ids.get_next_sequence(), next_sequence, "no new id was needed")
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(result.event, {
		"event_type": InventoryService.EVENT_ITEM_TRANSFERRED,
		"from_inventory_id": mine,
		"to_inventory_id": theirs,
		"item_instance_id": item_id,
		"definition_id": BULK,
		"quantity": 4,
		"remaining_quantity": 0,
		"received": [{"item_instance_id": item_id, "quantity": 4}],
	})
	assert_true(SaveService.is_json_safe(result.event))
	assert_eq(_events, [result.event], "listeners are told once, with the same event")
	# The slot it left is free again.
	assert_eq(_service.get_item(_put(mine, PLAIN)).slot_id, "slot_0")


func test_part_of_a_stack_arrives_as_a_new_instance_with_a_new_id() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(2)
	var item_id: String = _put(mine, BULK, 6)
	_service.get_item(item_id).condition = 0.75
	_service.get_item(item_id).quality = 0.5
	_events.clear()

	var result: ActionResult = _service.transfer_item(mine, item_id, theirs, 2)
	assert_true(result.ok, result.reason)
	assert_eq(_rows(_service, mine), [["slot_0", BULK, 4]], "the rest stays where it was")
	assert_eq(_rows(_service, theirs), [["slot_0", BULK, 2]])
	assert_eq(result.event.get("remaining_quantity", -1), 4)
	assert_eq(result.event.get("quantity", -1), 2)
	var received: Array = result.event.get("received", [])
	assert_eq(received.size(), 1, str(received))
	var new_id: String = str((received[0] as Dictionary).get("item_instance_id", ""))
	assert_eq((received[0] as Dictionary).get("quantity", -1), 2)
	assert_ne(new_id, item_id, "two stacks cannot share one id")
	assert_true(EntityIdGenerator.sequence_of(new_id) > EntityIdGenerator.sequence_of(item_id), "a fresh id: " + new_id)
	assert_eq(_registry.kind_of(new_id), InventoryService.ENTITY_KIND_ITEM, "the new instance is registered")
	var arrived: ItemInstance = _service.get_item(new_id)
	assert_not_null(arrived)
	assert_eq(arrived.definition_id, BULK)
	assert_eq(arrived.location_type, ItemInstance.LOCATION_INVENTORY)
	assert_eq(arrived.location_id, theirs)
	assert_eq(arrived.condition, 0.75, "the units keep their condition")
	assert_eq(arrived.quality, 0.5, "and their quality")
	assert_eq(_service.item_count(), 2)
	assert_eq(_totals(_service), {BULK: 6}, "six units before, six after")
	assert_eq(_events, [result.event])


func test_units_merge_into_the_receivers_stack_of_the_same_definition() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(2)
	var item_id: String = _put(mine, BULK, 6)
	var stack_id: String = _put(theirs, BULK, 3)
	var next_sequence: int = _ids.get_next_sequence()
	_events.clear()

	var part: ActionResult = _service.transfer_item(mine, item_id, theirs, 4)
	assert_true(part.ok, part.reason)
	assert_eq(_rows(_service, mine), [["slot_0", BULK, 2]])
	assert_eq(_rows(_service, theirs), [["slot_0", BULK, 7]], "merged: the receiver still has one stack")
	assert_eq(part.event.get("received", []), [{"item_instance_id": stack_id, "quantity": 4}])
	assert_eq(part.event.get("remaining_quantity", -1), 2)
	assert_eq(_ids.get_next_sequence(), next_sequence, "a merge needs no new id")

	# The rest of the stack merges away entirely: the giver's instance is
	# gone and its id is retired for good.
	var rest: ActionResult = _service.transfer_item(mine, item_id, theirs, 2)
	assert_true(rest.ok, rest.reason)
	assert_eq(_rows(_service, mine), [])
	assert_eq(_rows(_service, theirs), [["slot_0", BULK, 9]])
	assert_eq(rest.event.get("received", []), [{"item_instance_id": stack_id, "quantity": 2}])
	assert_eq(rest.event.get("remaining_quantity", -1), 0)
	assert_null(_service.get_item(item_id), "the emptied instance no longer exists")
	assert_false(_registry.has(item_id))
	assert_true(_registry.is_tombstoned(item_id), "its id is never used again")
	assert_eq(_service.item_count(), 1)
	assert_eq(_totals(_service), {BULK: 9})
	assert_eq(_events.size(), 2, "one event per hand-over")
	assert_eq(_service.transfer_item(mine, item_id, theirs, 1).reason, InventoryService.REASON_UNKNOWN_ITEM, "it cannot be handed over twice")
	var next_id: String = _put(mine, BULK, 1)
	assert_true(EntityIdGenerator.sequence_of(next_id) > EntityIdGenerator.sequence_of(item_id))


func test_what_does_not_fit_a_stack_overflows_into_a_free_slot() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(4)
	var item_id: String = _put(mine, BULK, 5)
	var first: String = _put(theirs, BULK, 8)
	_put(theirs, PLAIN)
	var second: String = _put(theirs, BULK, 9)
	_events.clear()

	# Four of five: two fill the first stack, one the second, one is left
	# over and becomes a stack of its own in the free slot.
	var part: ActionResult = _service.transfer_item(mine, item_id, theirs, 4)
	assert_true(part.ok, part.reason)
	assert_eq(_rows(_service, mine), [["slot_0", BULK, 1]])
	assert_eq(_rows(_service, theirs), [["slot_0", BULK, BULK_MAX], ["slot_1", PLAIN, 1], ["slot_2", BULK, BULK_MAX], ["slot_3", BULK, 1]], "no stack exceeds max_stack")
	var received: Array = part.event.get("received", [])
	assert_eq(received.size(), 3, str(received))
	assert_eq(received[0], {"item_instance_id": first, "quantity": 2}, "stacks are filled in slot order")
	assert_eq(received[1], {"item_instance_id": second, "quantity": 1})
	assert_eq((received[2] as Dictionary).get("quantity", -1), 1)
	var overflow_id: String = str((received[2] as Dictionary).get("item_instance_id", ""))
	assert_false([item_id, first, second].has(overflow_id), "the overflow is a new instance")
	assert_eq(_totals(_service), {BULK: 22, PLAIN: 1})

	# A whole stack that overflows: what is left over is the giver's own
	# instance, moved (no new id).
	var other: String = _service.create_inventory(2)
	var almost_full: String = _put(other, BULK, 8)
	var whole: String = _put(mine, BULK, 5)
	var next_sequence: int = _ids.get_next_sequence()
	var moved: ActionResult = _service.transfer_item(mine, whole, other, 5)
	assert_true(moved.ok, moved.reason)
	assert_eq(_rows(_service, other), [["slot_0", BULK, BULK_MAX], ["slot_1", BULK, 3]])
	assert_eq(moved.event.get("received", []), [{"item_instance_id": almost_full, "quantity": 2}, {"item_instance_id": whole, "quantity": 3}])
	assert_eq(moved.event.get("remaining_quantity", -1), 0)
	assert_eq(_service.get_item(whole).location_id, other)
	assert_eq(_ids.get_next_sequence(), next_sequence)
	assert_eq(_totals(_service), {BULK: 35, PLAIN: 1})


func test_stacks_are_filled_by_slot_number_not_by_slot_name() -> void:
	const CAPACITY: int = 12
	var mine: String = _service.create_inventory(1)
	var theirs: String = _service.create_inventory(CAPACITY)
	var item_id: String = _put(mine, BULK, 3)
	var in_slot_2: String = ""
	var in_slot_10: String = ""
	for index: int in range(11):
		if index == 2:
			in_slot_2 = _put(theirs, BULK, BULK_MAX - 1)
		elif index == 10:
			in_slot_10 = _put(theirs, BULK, BULK_MAX - 1)
		else:
			_put(theirs, PLAIN)
	assert_eq(_service.get_item(in_slot_2).slot_id, "slot_2")
	assert_eq(_service.get_item(in_slot_10).slot_id, "slot_10")
	assert_eq(InventoryService.slot_index_of("slot_10"), 10)
	# One unit goes to slot 2 although "slot_10" sorts before "slot_2" as text;
	# three units fill slot 2, then slot 10, then the free slot 11.
	var one: ActionResult = _service.transfer_item(mine, item_id, theirs, 1)
	assert_true(one.ok, one.reason)
	assert_eq(one.event.get("received", []), [{"item_instance_id": in_slot_2, "quantity": 1}])
	var other: String = _service.create_inventory(1)
	var more: String = _put(other, BULK, 3)
	assert_true(_service.transfer_item(mine, item_id, other, 2).ok, "the rest goes elsewhere")
	assert_eq(_service.get_item(more).quantity, 5)
	var rest: ActionResult = _service.transfer_item(other, more, theirs, 3)
	assert_true(rest.ok, rest.reason)
	var received: Array = rest.event.get("received", [])
	assert_eq(received.size(), 2, str(received))
	assert_eq(received[0], {"item_instance_id": in_slot_10, "quantity": 1})
	assert_eq((received[1] as Dictionary).get("quantity", -1), 2)
	assert_eq(_service.get_item(str((received[1] as Dictionary)["item_instance_id"])).slot_id, "slot_11")
	assert_eq(_totals(_service), {BULK: 2 * BULK_MAX + 4, PLAIN: 9})


func test_a_receiver_without_room_refuses_the_whole_hand_over() -> void:
	var mine: String = _service.create_inventory(3)
	var theirs: String = _service.create_inventory(2)
	var item_id: String = _put(mine, BULK, 6)
	var single: String = _put(mine, PLAIN)
	_put(theirs, PLAIN)
	var stack_id: String = _put(theirs, BULK, 8)
	var before: Dictionary = _service.to_snapshot()
	var next_sequence: int = _ids.get_next_sequence()
	_events.clear()

	# Two units would fit into the stack, the third would not: nothing moves.
	assert_eq(_service.transfer_item(mine, item_id, theirs, 3).reason, InventoryService.REASON_INVENTORY_FULL, "part of it fits")
	assert_eq(_service.transfer_item(mine, item_id, theirs, 6).reason, InventoryService.REASON_INVENTORY_FULL, "the whole stack")
	assert_eq(_service.transfer_item(mine, single, theirs, 1).reason, InventoryService.REASON_INVENTORY_FULL, "no stack to join and no free slot")
	assert_eq(_service.to_snapshot(), before, "a refused hand-over changes nothing")
	assert_eq(_ids.get_next_sequence(), next_sequence, "no id was used up")
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(_events.size(), 0, "a refused hand-over tells no listener")
	# What fits into a stack entirely is taken although every slot is in use.
	assert_true(_service.transfer_item(mine, item_id, theirs, 2).ok)
	assert_eq(_service.get_item(stack_id).quantity, BULK_MAX)
	assert_eq(_service.get_item(item_id).quantity, 4)


func test_stacks_of_another_condition_or_quality_are_not_merged() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(3)
	var item_id: String = _put(mine, BULK, 3)
	var worn: String = _put(theirs, BULK, 3)
	var poor: String = _put(theirs, BULK, 3)
	_service.get_item(worn).condition = 0.5
	_service.get_item(poor).quality = 0.25
	assert_true(_service.transfer_item(mine, item_id, theirs, 3).ok)
	assert_eq(_rows(_service, theirs), [["slot_0", BULK, 3], ["slot_1", BULK, 3], ["slot_2", BULK, 3]], "each stack kept its own units")
	assert_eq(_service.get_item(worn).condition, 0.5)
	assert_eq(_service.get_item(item_id).condition, ItemInstance.MAX_UNIT_VALUE)
	assert_eq(_service.get_item(item_id).location_id, theirs)


func test_transfer_failures_change_nothing() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(2)
	var carried: String = _put(mine, BULK, 3)
	var other: String = _put(theirs, BULK, 3)
	var lying: String = _service.spawn_world_item(BULK, 3, CELL, Vector3.ZERO)
	var before: Dictionary = _service.to_snapshot()
	var next_sequence: int = _ids.get_next_sequence()
	_events.clear()

	assert_eq(_service.transfer_item(MISSING_INVENTORY_ID, carried, theirs, 1).reason, InventoryService.REASON_UNKNOWN_INVENTORY)
	assert_eq(_service.transfer_item(mine, MISSING_ITEM_ID, theirs, 1).reason, InventoryService.REASON_UNKNOWN_ITEM)
	assert_eq(_service.transfer_item(mine, other, theirs, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "someone else's item")
	assert_eq(_service.transfer_item(mine, lying, theirs, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "an item lying in the world")
	for bad: int in [0, -1, 4, 9223372036854775807]:
		assert_eq(_service.transfer_item(mine, carried, theirs, bad).reason, InventoryService.REASON_BAD_QUANTITY, "quantity %d" % bad)
	assert_eq(_service.transfer_item(mine, carried, MISSING_INVENTORY_ID, 1).reason, InventoryService.REASON_UNKNOWN_INVENTORY, "no such receiver")
	assert_eq(_service.transfer_item(mine, carried, mine, 1).reason, InventoryService.REASON_SAME_INVENTORY, "an inventory hands nothing to itself")
	assert_eq(_service.to_snapshot(), before, "a refused hand-over changes nothing")
	assert_eq(_ids.get_next_sequence(), next_sequence)
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(_events.size(), 0)


## Many hand-overs back and forth, accepted and refused, in a fixed random
## order: the units of every definition are conserved, no id appears twice,
## no stack is empty or larger than max_stack and no inventory holds more
## stacks than it has slots.
func test_units_are_conserved_and_ids_stay_unique_over_many_hand_overs() -> void:
	const CAPACITY: int = 4
	var inventories: Array[String] = [_service.create_inventory(CAPACITY), _service.create_inventory(CAPACITY), _service.create_inventory(CAPACITY)]
	_put(inventories[0], BULK, 10)
	_put(inventories[0], BULK, 7)
	_put(inventories[0], FOOD, 5)
	_put(inventories[0], PLAIN)
	_put(inventories[1], BULK, 4)
	_put(inventories[1], FOOD, 2)
	_put(inventories[2], FOOD, 5)
	_put(inventories[2], PLAIN)
	var totals: Dictionary = _totals(_service)
	var ever_seen: Dictionary = {}
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = SOAK_SEED
	var accepted: int = 0
	var refused: int = 0
	var consistent: bool = true
	for round_index: int in range(SOAK_ROUNDS):
		var from_id: String = inventories[rng.randi_range(0, inventories.size() - 1)]
		var to_id: String = inventories[rng.randi_range(0, inventories.size() - 1)]
		var carried: Array[ItemInstance] = _service.items_in_inventory(from_id)
		if carried.is_empty():
			continue
		var item: ItemInstance = carried[rng.randi_range(0, carried.size() - 1)]
		var before: Dictionary = _service.to_snapshot()
		# Sometimes one more than the stack holds (a refusal).
		var result: ActionResult = _service.transfer_item(from_id, item.item_instance_id, to_id, rng.randi_range(1, item.quantity + 1))
		if result.ok:
			accepted += 1
		else:
			refused += 1
			consistent = consistent and _service.to_snapshot() == before
		consistent = consistent and _totals(_service) == totals
		for inventory_id: String in inventories:
			var slots: Dictionary = {}
			for held: ItemInstance in _service.items_in_inventory(inventory_id):
				consistent = consistent and held.quantity >= 1 and held.quantity <= _catalog.get_definition(held.definition_id).max_stack
				consistent = consistent and not slots.has(held.slot_id)
				slots[held.slot_id] = true
			consistent = consistent and slots.size() <= CAPACITY
		# An id belongs to one definition for ever (ids are never reused).
		for entry: Dictionary in _service.to_snapshot()[InventoryService.SNAPSHOT_ITEMS]:
			var seen_as: String = str(ever_seen.get(entry["item_instance_id"], entry["definition_id"]))
			consistent = consistent and seen_as == str(entry["definition_id"]) and not _registry.is_tombstoned(str(entry["item_instance_id"]))
			ever_seen[entry["item_instance_id"]] = entry["definition_id"]
		if not consistent:
			fail("inconsistent after round %d: %s" % [round_index, str(_service.to_snapshot())])
			return
	assert_true(consistent)
	assert_true(accepted > 50, "enough hand-overs were accepted: %d" % accepted)
	assert_true(refused > 10, "and enough refused: %d" % refused)
	assert_eq(_totals(_service), totals, "every unit is still there, none was copied")
	for retired: String in _registry.tombstones():
		assert_null(_service.get_item(retired), "a retired id names no item")



func test_transferred_stacks_survive_a_snapshot_round_trip() -> void:
	var mine: String = _service.create_inventory(4)
	var theirs: String = _service.create_inventory(4)
	var food: String = _put(mine, FOOD, 4)
	var bulk: String = _put(mine, BULK, 6)
	var plain: String = _put(mine, PLAIN)
	var their_bulk: String = _put(theirs, BULK, 8)
	# Part of a stack (a new instance), a whole stack that merges and
	# overflows (the instance moves), a single item (moves as it is) and a
	# rest that merges away (its id is retired).
	var part: ActionResult = _service.transfer_item(mine, food, theirs, 3)
	assert_true(part.ok, part.reason)
	var their_food: String = str(((part.event["received"] as Array)[0] as Dictionary)["item_instance_id"])
	assert_true(_service.transfer_item(mine, bulk, theirs, 6).ok)
	assert_true(_service.transfer_item(mine, plain, theirs, 1).ok)
	assert_true(_service.transfer_item(mine, food, theirs, 1).ok)
	assert_eq(_rows(_service, mine), [])
	var their_rows: Array = _rows(_service, theirs)
	assert_eq(their_rows, [["slot_0", BULK, BULK_MAX], ["slot_1", FOOD, 4], ["slot_2", BULK, 4], ["slot_3", PLAIN, 1]])
	var totals: Dictionary = _totals(_service)

	# Snapshot -> JSON -> a brand-new service (a server restart).
	var json_text: String = JSON.stringify(_service.to_snapshot())
	var restored_ids: EntityIdGenerator = EntityIdGenerator.new()
	var restored_registry: EntityRegistry = EntityRegistry.new()
	restored_registry.restore_tombstones(_registry.tombstones())
	var restored: InventoryService = InventoryService.new(_catalog, restored_ids, restored_registry, PICKUP_RANGE)
	assert_eq(restored.restore_snapshot(JSON.parse_string(json_text) as Dictionary).size(), 0)
	assert_eq(JSON.stringify(restored.to_snapshot()), json_text, "the same items, ids, slots and quantities")
	assert_eq(_rows(restored, mine), [])
	assert_eq(_rows(restored, theirs), their_rows)
	assert_eq(_totals(restored), totals)
	assert_eq(restored.get_item(their_food).location_id, theirs)
	assert_eq(restored.get_item(bulk).location_id, theirs, "the moved instance kept its id")
	assert_eq(restored.get_item(their_bulk).quantity, BULK_MAX)
	assert_null(restored.get_item(food))
	assert_true(restored_registry.is_tombstoned(food), "the id of the stack that merged away stays retired after a restart")
	# The transaction goes on in the restored service.
	assert_true(restored.transfer_item(theirs, their_food, mine, 2).ok)
	assert_eq(_rows(restored, mine), [["slot_0", FOOD, 2]])
	assert_eq(_totals(restored), totals)
