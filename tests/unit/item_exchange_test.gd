extends TestCase
## P2-T16 (docs/00 ADR-022, docs/09 §14.30): InventoryService.exchange_items,
## the one transaction behind a completed trade. Two inventories give each
## other units of items they carry, all or nothing:
##   - what leaves the one inventory is exactly what arrives in the other
##     (units are conserved per definition);
##   - item instance ids stay unique and are never reused;
##   - both inventories must fit what comes in AFTER what goes out has left;
##     if either does not, nothing changes at all;
##   - incoming units join stacks of the same kind first (the rule of
##     transfer_item and try_pickup).
## No network and no trade rules here (tests/unit/trade_service_test.gd).

const CELL: String = "cell_0_0"
const PICKUP_RANGE: float = 2.0
const MISSING_ITEM_ID: String = "item_999999"
const MISSING_INVENTORY_ID: String = "inventory_999999"
const FOOD: String = "t16_food"
const FOOD_MAX: int = 5
const PLAIN: String = "t16_plain"
const BULK: String = "t16_bulk"
const BULK_MAX: int = 10
const SOAK_SEED: int = 20261116
const SOAK_ROUNDS: int = 300

var _catalog: ItemCatalog = null
var _ids: EntityIdGenerator = null
var _registry: EntityRegistry = null
var _service: InventoryService = null
var _events: Array[Dictionary] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_catalog = ItemCatalog.new()
	var food: ItemDefinition = ItemDefinition.new()
	food.definition_id = FOOD
	food.max_stack = FOOD_MAX
	_catalog.add(food)
	var plain: ItemDefinition = ItemDefinition.new()
	plain.definition_id = PLAIN
	plain.max_stack = 1
	_catalog.add(plain)
	var bulk: ItemDefinition = ItemDefinition.new()
	bulk.definition_id = BULK
	bulk.max_stack = BULK_MAX
	_catalog.add(bulk)
	_ids = EntityIdGenerator.new()
	_registry = EntityRegistry.new()
	_service = InventoryService.new(_catalog, _ids, _registry, PICKUP_RANGE)
	# Stack layouts are built with pickups that do not merge.
	_service.merge_on_pickup = false
	_events = []
	# The listener captures the array, not this test object (no reference cycle).
	var events: Array[Dictionary] = _events
	_service.transaction_committed.connect(func(event: Dictionary) -> void: events.append(event))


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## Spawns an item at the origin and puts it into `inventory_id` as a stack of
## its own.
func _put(inventory_id: String, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = _service.spawn_world_item(definition_id, quantity, CELL, Vector3.ZERO)
	var result: ActionResult = _service.try_pickup(inventory_id, item_id, Vector3.ZERO)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


func _give(item_id: String, quantity: int) -> Dictionary:
	return {"item_instance_id": item_id, "quantity": quantity}


## [slot, definition, quantity] of everything in an inventory, in slot order.
func _rows(inventory_id: String) -> Array:
	var rows: Array = []
	for item: ItemInstance in _service.items_in_inventory(inventory_id):
		rows.append([item.slot_id, item.definition_id, item.quantity])
	return rows


## Units per definition over every item that exists (carried or lying).
func _totals() -> Dictionary:
	var totals: Dictionary = {}
	for entry: Dictionary in _service.to_snapshot()[InventoryService.SNAPSHOT_ITEMS]:
		var definition_id: String = str(entry["definition_id"])
		totals[definition_id] = int(totals.get(definition_id, 0)) + int(entry["quantity"])
	return totals


## Units per definition carried in one inventory.
func _units_in(inventory_id: String) -> Dictionary:
	var units: Dictionary = {}
	for item: ItemInstance in _service.items_in_inventory(inventory_id):
		units[item.definition_id] = int(units.get(item.definition_id, 0)) + item.quantity
	return units


func _side(event: Dictionary, index: int) -> Dictionary:
	var sides: Array = event.get("sides", [])
	return sides[index] if index < sides.size() and typeof(sides[index]) == TYPE_DICTIONARY else {}


# ------------------------------------------------------------ the exchange

func test_two_inventories_swap_whole_stacks_and_the_instances_keep_their_ids() -> void:
	var mine: String = _service.create_inventory(3)
	var theirs: String = _service.create_inventory(3)
	var food: String = _put(mine, FOOD, 4)
	var kept: String = _put(mine, PLAIN)
	var bulk: String = _put(theirs, BULK, 6)
	var next_sequence: int = _ids.get_next_sequence()
	_events.clear()

	var result: ActionResult = _service.exchange_items(mine, [_give(food, 4)], theirs, [_give(bulk, 6)])
	assert_true(result.ok, result.reason)
	assert_eq(_rows(mine), [["slot_0", BULK, 6], ["slot_1", PLAIN, 1]], "the stack that came in took the slot the other one left")
	assert_eq(_rows(theirs), [["slot_0", FOOD, 4]])
	assert_eq(_service.get_item(food).location_id, theirs, "the same instance, now in the other inventory")
	assert_eq(_service.get_item(bulk).location_id, mine)
	assert_eq(_service.get_item(kept).slot_id, "slot_1", "what was not offered did not move")
	assert_eq(_service.item_count(), 3, "nothing was created or lost")
	assert_eq(_ids.get_next_sequence(), next_sequence, "whole stacks need no new id")
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(result.event, {
		"event_type": InventoryService.EVENT_ITEMS_EXCHANGED,
		"sides": [
			{
				"inventory_id": mine,
				"gave": [{"item_instance_id": food, "definition_id": FOOD, "quantity": 4}],
				"removed_item_instance_ids": [food],
				"changed_item_instance_ids": [bulk],
			},
			{
				"inventory_id": theirs,
				"gave": [{"item_instance_id": bulk, "definition_id": BULK, "quantity": 6}],
				"removed_item_instance_ids": [bulk],
				"changed_item_instance_ids": [food],
			},
		],
	})
	assert_true(SaveService.is_json_safe(result.event))
	assert_eq(_events, [result.event], "ONE transaction: listeners are told once, with the same event")


func test_parts_of_stacks_arrive_as_new_instances_and_units_are_conserved() -> void:
	var mine: String = _service.create_inventory(3)
	var theirs: String = _service.create_inventory(3)
	var food: String = _put(mine, FOOD, 5)
	var bulk: String = _put(theirs, BULK, 9)
	_service.get_item(bulk).condition = 0.75
	_service.get_item(bulk).quality = 0.5
	var totals: Dictionary = _totals()
	_events.clear()

	var result: ActionResult = _service.exchange_items(mine, [_give(food, 2)], theirs, [_give(bulk, 4)])
	assert_true(result.ok, result.reason)
	assert_eq(_rows(mine), [["slot_0", FOOD, 3], ["slot_1", BULK, 4]], "the rest stays, the part that came in is a stack of its own")
	assert_eq(_rows(theirs), [["slot_0", BULK, 5], ["slot_1", FOOD, 2]])
	assert_eq(_totals(), totals, "every unit is still there, none was copied")
	var my_side: Dictionary = _side(result.event, 0)
	var their_side: Dictionary = _side(result.event, 1)
	assert_eq(my_side.get("removed_item_instance_ids", ["x"]), [], "nothing left my inventory entirely")
	var my_changed: Array = my_side.get("changed_item_instance_ids", [])
	assert_eq(my_changed.size(), 2, str(my_changed))
	assert_eq(my_changed[0], food, "my smaller stack")
	var arrived_id: String = str(my_changed[1])
	assert_false([food, bulk].has(arrived_id), "two stacks cannot share one id")
	assert_true(EntityIdGenerator.sequence_of(arrived_id) > EntityIdGenerator.sequence_of(bulk), "a fresh id: " + arrived_id)
	assert_eq(_registry.kind_of(arrived_id), InventoryService.ENTITY_KIND_ITEM, "the new instance is registered")
	var arrived: ItemInstance = _service.get_item(arrived_id)
	assert_eq(arrived.definition_id, BULK)
	assert_eq(arrived.quantity, 4)
	assert_eq(arrived.location_id, mine)
	assert_eq(arrived.condition, 0.75, "the units keep their condition")
	assert_eq(arrived.quality, 0.5, "and their quality")
	var their_changed: Array = their_side.get("changed_item_instance_ids", [])
	assert_eq(their_changed.size(), 2, str(their_changed))
	assert_eq(their_changed[0], bulk)
	assert_ne(str(their_changed[1]), arrived_id, "each new stack has an id of its own")
	assert_eq(_service.get_item(str(their_changed[1])).quantity, 2)
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(_events.size(), 1)


func test_incoming_units_join_stacks_of_the_same_kind_first() -> void:
	var mine: String = _service.create_inventory(4)
	var theirs: String = _service.create_inventory(4)
	var my_food: String = _put(mine, FOOD, 4)
	var my_bulk: String = _put(mine, BULK, 3)
	var their_food: String = _put(theirs, FOOD, 3)
	var their_bulk: String = _put(theirs, BULK, 9)
	var their_second: String = _put(theirs, FOOD, 5)
	var totals: Dictionary = _totals()

	# I give 2 of my 4 food and my whole bulk stack; they give a whole food
	# stack of 3. My food stack (2 left) takes all 3, so their instance merges
	# away. Their other food stack is full, so my 2 food become a new stack in
	# the slot their stack left; their bulk stack (9) takes 1 of my 3 and the
	# rest keeps its id in the next free slot.
	var result: ActionResult = _service.exchange_items(mine, [_give(my_food, 2), _give(my_bulk, 3)], theirs, [_give(their_food, 3)])
	assert_true(result.ok, result.reason)
	assert_eq(_rows(mine), [["slot_0", FOOD, 5]], "what came in joined the rest of the stack I gave from")
	assert_eq(_rows(theirs), [["slot_0", FOOD, 2], ["slot_1", BULK, BULK_MAX], ["slot_2", FOOD, 5], ["slot_3", BULK, 2]], "no stack exceeds max_stack")
	assert_eq(_totals(), totals)
	assert_null(_service.get_item(their_food), "their stack merged away entirely")
	assert_true(_registry.is_tombstoned(their_food), "its id is never used again")
	assert_eq(_service.get_item(my_bulk).location_id, theirs, "the left-over of a whole stack is the same instance, moved")
	assert_eq(_service.get_item(my_bulk).quantity, 2)
	assert_eq(_service.get_item(their_bulk).quantity, BULK_MAX)
	assert_eq(_service.get_item(their_second).quantity, 5, "a full stack takes nothing; my 2 food had to find room elsewhere")
	assert_eq(_side(result.event, 0).get("removed_item_instance_ids", []), [my_bulk])
	assert_eq(_side(result.event, 0).get("changed_item_instance_ids", []), [my_food])
	assert_eq(_side(result.event, 1).get("removed_item_instance_ids", []), [their_food])


func test_a_gift_moves_one_way_and_empty_offers_exchange_nothing() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(2)
	var food: String = _put(mine, FOOD, 3)
	var before: Dictionary = _service.to_snapshot()
	_events.clear()
	assert_eq(_service.exchange_items(mine, [], theirs, []).reason, InventoryService.REASON_NOTHING_TO_EXCHANGE)
	assert_eq(_service.to_snapshot(), before)
	assert_eq(_events.size(), 0)
	# One side gives, the other gives nothing.
	var result: ActionResult = _service.exchange_items(mine, [_give(food, 1)], theirs, [])
	assert_true(result.ok, result.reason)
	assert_eq(_rows(mine), [["slot_0", FOOD, 2]])
	assert_eq(_rows(theirs), [["slot_0", FOOD, 1]])
	assert_eq(_side(result.event, 1).get("gave", ["x"]), [])
	# And the other way round.
	var back: ActionResult = _service.exchange_items(mine, [], theirs, [_give(str(_side(result.event, 1)["changed_item_instance_ids"][0]), 1)])
	assert_true(back.ok, back.reason)
	assert_eq(_rows(mine), [["slot_0", FOOD, 3]], "it merged back into the stack it came from")
	assert_eq(_rows(theirs), [])


func test_full_inventories_can_swap_because_what_goes_out_leaves_first() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(2)
	var my_a: String = _put(mine, PLAIN)
	var my_b: String = _put(mine, FOOD, FOOD_MAX)
	var their_a: String = _put(theirs, BULK, BULK_MAX)
	var their_b: String = _put(theirs, PLAIN)
	# Neither inventory has a free slot, but each gives up a whole stack.
	var result: ActionResult = _service.exchange_items(mine, [_give(my_b, FOOD_MAX)], theirs, [_give(their_a, BULK_MAX)])
	assert_true(result.ok, result.reason)
	assert_eq(_rows(mine), [["slot_0", PLAIN, 1], ["slot_1", BULK, BULK_MAX]])
	assert_eq(_rows(theirs), [["slot_0", FOOD, FOOD_MAX], ["slot_1", PLAIN, 1]])
	assert_eq(_service.get_item(my_a).location_id, mine)
	assert_eq(_service.get_item(their_b).location_id, theirs)


func test_when_either_side_cannot_take_what_comes_in_nothing_changes_at_all() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(2)
	var my_plain: String = _put(mine, PLAIN)
	var my_food: String = _put(mine, FOOD, 4)
	var their_bulk: String = _put(theirs, BULK, 6)
	var their_plain: String = _put(theirs, PLAIN)
	var before: Dictionary = _service.to_snapshot()
	var next_sequence: int = _ids.get_next_sequence()
	_events.clear()

	# I give a PART of my food (my slot stays in use) and would get their bulk
	# stack: no slot for it. Their side would have been fine.
	assert_eq(_service.exchange_items(mine, [_give(my_food, 2)], theirs, [_give(their_bulk, 6)]).reason, InventoryService.REASON_FIRST_INVENTORY_FULL, "the first inventory has no room")
	# The same the other way round names the other inventory.
	assert_eq(_service.exchange_items(theirs, [_give(their_bulk, 6)], mine, [_give(my_food, 2)]).reason, InventoryService.REASON_SECOND_INVENTORY_FULL)
	# They would get a part of my food (a new stack) while giving nothing up.
	assert_eq(_service.exchange_items(mine, [_give(my_food, 1)], theirs, []).reason, InventoryService.REASON_SECOND_INVENTORY_FULL, "a gift needs room too")
	# One of two offered stacks fits, the other does not: still nothing moves.
	assert_eq(_service.exchange_items(mine, [_give(my_plain, 1), _give(my_food, 2)], theirs, [_give(their_plain, 1)]).reason, InventoryService.REASON_SECOND_INVENTORY_FULL, "part of the offer fits")
	assert_eq(_service.to_snapshot(), before, "a refused exchange changes nothing, on either side")
	assert_eq(_ids.get_next_sequence(), next_sequence, "no id was used up")
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(_events.size(), 0, "a refused exchange tells no listener")
	# Whole stacks for whole stacks works.
	assert_true(_service.exchange_items(mine, [_give(my_food, 4)], theirs, [_give(their_bulk, 6)]).ok)


func test_invalid_offers_are_refused_and_change_nothing() -> void:
	var mine: String = _service.create_inventory(3)
	var theirs: String = _service.create_inventory(3)
	var food: String = _put(mine, FOOD, 3)
	var bulk: String = _put(theirs, BULK, 3)
	var lying: String = _service.spawn_world_item(BULK, 3, CELL, Vector3.ZERO)
	var before: Dictionary = _service.to_snapshot()
	var next_sequence: int = _ids.get_next_sequence()
	_events.clear()

	assert_eq(_service.exchange_items(MISSING_INVENTORY_ID, [], theirs, [_give(bulk, 1)]).reason, InventoryService.REASON_UNKNOWN_INVENTORY)
	assert_eq(_service.exchange_items(mine, [_give(food, 1)], MISSING_INVENTORY_ID, []).reason, InventoryService.REASON_UNKNOWN_INVENTORY)
	assert_eq(_service.exchange_items(mine, [_give(food, 1)], mine, [_give(food, 1)]).reason, InventoryService.REASON_SAME_INVENTORY, "an inventory trades nothing with itself")
	# Only what the giving inventory carries.
	assert_eq(_service.exchange_items(mine, [_give(bulk, 1)], theirs, []).reason, InventoryService.REASON_NOT_IN_INVENTORY, "the other side's item offered as my own")
	assert_eq(_service.exchange_items(mine, [_give(food, 1)], theirs, [_give(food, 1)]).reason, InventoryService.REASON_NOT_IN_INVENTORY, "my item offered by the other side")
	assert_eq(_service.exchange_items(mine, [_give(lying, 1)], theirs, []).reason, InventoryService.REASON_NOT_IN_INVENTORY, "an item lying in the world")
	assert_eq(_service.exchange_items(mine, [_give(MISSING_ITEM_ID, 1)], theirs, []).reason, InventoryService.REASON_UNKNOWN_ITEM)
	# Ownership before the quantity: nothing is learnt about a foreign stack.
	assert_eq(_service.exchange_items(mine, [_give(bulk, 99)], theirs, []).reason, InventoryService.REASON_NOT_IN_INVENTORY)
	for bad: int in [0, -1, 4, 9223372036854775807]:
		assert_eq(_service.exchange_items(mine, [_give(food, bad)], theirs, []).reason, InventoryService.REASON_BAD_QUANTITY, "quantity %d" % bad)
	# The same stack twice in one offer would give away more than it holds.
	assert_eq(_service.exchange_items(mine, [_give(food, 2), _give(food, 2)], theirs, []).reason, InventoryService.REASON_DUPLICATE_ITEM)
	# Malformed offer entries.
	var malformed: Array = ["item", null, 5, [], {}, {"item_instance_id": food}, {"quantity": 1}, {"item_instance_id": 7, "quantity": 1}, {"item_instance_id": food, "quantity": "1"}, {"item_instance_id": food, "quantity": 1.0}]
	for entry: Variant in malformed:
		assert_eq(_service.exchange_items(mine, [entry], theirs, []).reason, InventoryService.REASON_BAD_OFFER, "rejected: %s" % str(entry))
		assert_eq(_service.exchange_items(mine, [_give(food, 1)], theirs, [entry]).reason, InventoryService.REASON_BAD_OFFER, "the second offer too: %s" % str(entry))
	assert_eq(_service.to_snapshot(), before, "a refused exchange changes nothing")
	assert_eq(_ids.get_next_sequence(), next_sequence)
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(_events.size(), 0)


func test_stacks_of_another_condition_or_quality_are_not_merged() -> void:
	var mine: String = _service.create_inventory(3)
	var theirs: String = _service.create_inventory(3)
	var fresh: String = _put(mine, BULK, 3)
	var worn: String = _put(theirs, BULK, 3)
	_service.get_item(worn).condition = 0.5
	var result: ActionResult = _service.exchange_items(mine, [_give(fresh, 1)], theirs, [_give(worn, 1)])
	assert_true(result.ok, result.reason)
	assert_eq(_rows(mine), [["slot_0", BULK, 2], ["slot_1", BULK, 1]], "the worn unit did not join the fresh stack")
	assert_eq(_rows(theirs), [["slot_0", BULK, 2], ["slot_1", BULK, 1]])
	assert_eq(_service.get_item(fresh).condition, ItemInstance.MAX_UNIT_VALUE, "no unit's condition was averaged away")
	var arrived: ItemInstance = _service.get_item(str(_side(result.event, 0)["changed_item_instance_ids"][1]))
	assert_eq(arrived.condition, 0.5)


## Many exchanges between three inventories, accepted and refused, in a
## fixed random order: the units of every definition are conserved, what
## each side gave is exactly what the other side gained, no id appears twice
## or comes back, no stack is empty or larger than max_stack and no
## inventory holds more stacks than it has slots.
func test_units_are_conserved_and_ids_stay_unique_over_many_exchanges() -> void:
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
	var totals: Dictionary = _totals()
	var ever_seen: Dictionary = {}
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = SOAK_SEED
	var accepted: int = 0
	var refused: int = 0
	var consistent: bool = true
	for round_index: int in range(SOAK_ROUNDS):
		var first: String = inventories[rng.randi_range(0, inventories.size() - 1)]
		var second: String = inventories[rng.randi_range(0, inventories.size() - 1)]
		var offers: Array[Array] = [[], []]
		var expected: Array[Dictionary] = [_units_in(first), _units_in(second)]
		var sides: Array[String] = [first, second]
		for side: int in range(2):
			for item: ItemInstance in _service.items_in_inventory(sides[side]):
				if rng.randf() < 0.4:
					# Sometimes one more than the stack holds (a refusal).
					var quantity: int = rng.randi_range(1, item.quantity + (1 if rng.randf() < 0.1 else 0))
					offers[side].append(_give(item.item_instance_id, quantity))
					expected[side][item.definition_id] = int(expected[side].get(item.definition_id, 0)) - quantity
					expected[1 - side][item.definition_id] = int(expected[1 - side].get(item.definition_id, 0)) + quantity
		var before: Dictionary = _service.to_snapshot()
		var result: ActionResult = _service.exchange_items(first, offers[0], second, offers[1])
		if result.ok:
			accepted += 1
			for side: int in range(2):
				var now: Dictionary = _units_in(sides[side])
				for definition_id: Variant in expected[side]:
					consistent = consistent and int(now.get(definition_id, 0)) == int(expected[side][definition_id])
		else:
			refused += 1
			consistent = consistent and _service.to_snapshot() == before
		consistent = consistent and _totals() == totals
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
	assert_true(accepted > 40, "enough exchanges were accepted: %d" % accepted)
	assert_true(refused > 40, "and enough refused: %d" % refused)
	assert_eq(_totals(), totals, "every unit is still there, none was copied")
	for retired: String in _registry.tombstones():
		assert_null(_service.get_item(retired), "a retired id names no item")


func test_an_exchange_survives_a_snapshot_round_trip() -> void:
	var mine: String = _service.create_inventory(3)
	var theirs: String = _service.create_inventory(3)
	var food: String = _put(mine, FOOD, 4)
	var plain: String = _put(mine, PLAIN)
	var their_food: String = _put(theirs, FOOD, 3)
	var bulk: String = _put(theirs, BULK, 6)
	# 2 of my 4 food fill their stack to 5 (no new instance), my single item
	# moves as it is, a part of their bulk becomes a new instance here.
	var result: ActionResult = _service.exchange_items(mine, [_give(food, 2), _give(plain, 1)], theirs, [_give(bulk, 4)])
	assert_true(result.ok, result.reason)
	var my_rows: Array = _rows(mine)
	var their_rows: Array = _rows(theirs)
	assert_eq(my_rows, [["slot_0", FOOD, 2], ["slot_1", BULK, 4]])
	assert_eq(their_rows, [["slot_0", FOOD, 5], ["slot_1", BULK, 2], ["slot_2", PLAIN, 1]])
	var totals: Dictionary = _totals()
	var json_text: String = JSON.stringify(_service.to_snapshot())
	var restored_registry: EntityRegistry = EntityRegistry.new()
	restored_registry.restore_tombstones(_registry.tombstones())
	var restored_ids: EntityIdGenerator = EntityIdGenerator.new()
	var restored: InventoryService = InventoryService.new(_catalog, restored_ids, restored_registry, PICKUP_RANGE)
	assert_eq(restored.restore_snapshot(JSON.parse_string(json_text) as Dictionary).size(), 0)
	assert_eq(JSON.stringify(restored.to_snapshot()), json_text, "the same items, ids, slots and quantities")
	assert_eq(restored.get_item(plain).location_id, theirs)
	assert_eq(restored.get_item(their_food).quantity, 5)
	# The transaction goes on in the restored service, with ids that never
	# come back.
	var again: ActionResult = restored.exchange_items(mine, [_give(food, 1)], theirs, [_give(plain, 1)])
	assert_true(again.ok, again.reason)
	var new_id: String = str((again.event["sides"] as Array)[1]["changed_item_instance_ids"][-1])
	for used: String in [food, plain, their_food, bulk]:
		assert_true(EntityIdGenerator.sequence_of(new_id) > EntityIdGenerator.sequence_of(used), "new ids continue after every id ever used: " + new_id)
	var restored_totals: Dictionary = {}
	for entry: Dictionary in restored.to_snapshot()[InventoryService.SNAPSHOT_ITEMS]:
		restored_totals[str(entry["definition_id"])] = int(restored_totals.get(str(entry["definition_id"]), 0)) + int(entry["quantity"])
	assert_eq(restored_totals, totals)
