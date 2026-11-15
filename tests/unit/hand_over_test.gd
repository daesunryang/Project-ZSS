extends TestCase
## P2-T14 (user decision 2026-11-15 "건네기도 추가", docs/00 ADR-020, docs/09
## §14.28): a player hands an item it carries over to another player close
## by. The units move into the other player's inventory, to keep or to use
## later; nobody is fed or treated by it.
##   InventoryService.transfer_item   the transaction: all or nothing, units
##                                    are conserved, ids stay unique.
##   ServerWorld.try_hand_over_item   the rule: who may hand what to whom,
##                                    decided from server state only.
## Server rules only, no network (tests/integration/hand_over_net_test.gd).

const WORLD: String = "hand_over_test_world"
const CELL: String = "cell_0_0"
const PICKUP_RANGE: float = 2.0
const NEVER: float = 1.0e9
const EPSILON: float = 0.001
const LETHAL_DAMAGE: float = 100000.0
const ZOMBIE: String = "zombie_000001"
const MISSING_ITEM_ID: String = "item_999999"
const MISSING_PLAYER_ID: String = "player_999999"
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
var _settings: SurvivalSettings = null
var _gameplay: GameplaySettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_catalog = _new_catalog(ItemCatalog.new())
	_ids = EntityIdGenerator.new()
	_registry = EntityRegistry.new()
	_service = InventoryService.new(_catalog, _ids, _registry, PICKUP_RANGE)
	_events = []
	# The listener captures the array, not this test object (no reference cycle).
	var events: Array[Dictionary] = _events
	_service.transaction_committed.connect(func(event: Dictionary) -> void: events.append(event))
	_settings = SurvivalSettings.new()
	_settings.respawn_delay_sec = NEVER
	_settings.health_recovery_per_world_sec = 0.0
	_settings.wound_recovery_per_world_sec = 0.0
	_gameplay = GameplaySettings.new()


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


func _world(require_creation: bool = false) -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.gameplay = _gameplay
	config.survival = _settings
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = 1.0
	config.catalog = _new_catalog(ItemCatalog.load_directory())
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.require_character_creation = require_creation
	return ServerComposition.create_world(WORLD, config)


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


## Spawns an item where `player` stands and lets it pick the item up.
func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, DevWorldSeed.DEV_CELL_ID, player.position)
	var result: ActionResult = world.try_pickup(player.player_id, item_id)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


func _kill(world: ServerWorld, player: PlayerState) -> void:
	if not _survival(world).apply_damage(player.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok:
		fail("test setup: lethal damage failed")


func _quantity(world: ServerWorld, item_id: String) -> int:
	var item: ItemInstance = world.inventory.get_item(item_id)
	return 0 if item == null else item.quantity


func _transactions_of(world: ServerWorld) -> Array[Dictionary]:
	var transactions: Array[Dictionary] = []
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void: transactions.append(event))
	return transactions


## Asserts that the hand-over is refused with `reason` and that nothing at
## all changed: every item, every player, every system, the id counter and
## the retired ids (the whole save document), no transaction, no event.
func _assert_refused(world: ServerWorld, giver_id: String, item_id: String, target_id: String, quantity: int, reason: String, label: String) -> void:
	var before: Dictionary = world.to_documents()
	_survival(world).drain_events()
	var transactions: Array[Dictionary] = _transactions_of(world)
	var result: ActionResult = world.try_hand_over_item(giver_id, item_id, target_id, quantity)
	assert_false(result.ok, label)
	assert_eq(result.reason, reason, label)
	assert_eq(world.to_documents(), before, label + ": nothing changed")
	assert_eq(transactions.size(), 0, label + ": no inventory transaction")
	assert_eq(_survival(world).drain_events().size(), 0, label + ": no survival event")


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


# ------------------------------------------------------------ the rule

func test_shipped_settings_and_reason_codes() -> void:
	var shipped: GameplaySettings = GameplaySettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_true(shipped.hand_over_range_m > 0.0, "handing over needs the other player close by")
	assert_eq(GameplaySettings.new().hand_over_range_m, shipped.hand_over_range_m, "the script default agrees with the shipped resource")
	for bad: float in [0.0, -1.0, NAN, INF]:
		var broken: GameplaySettings = GameplaySettings.new()
		broken.hand_over_range_m = bad
		assert_eq(broken.validate().size(), 1, "hand-over range %s: %s" % [str(bad), "; ".join(broken.validate())])
	# The codes that mean the same as for a use on another player are the same.
	assert_eq(ServerWorld.REASON_TARGET_UNAVAILABLE, ItemConsumption.REASON_TARGET_UNAVAILABLE)
	assert_eq(ServerWorld.REASON_TARGET_DEAD, ItemConsumption.REASON_TARGET_DEAD)
	assert_eq(ServerWorld.REASON_TARGET_TOO_FAR, ItemConsumption.REASON_TARGET_TOO_FAR)
	assert_ne(ServerWorld.REASON_TARGET_INVENTORY_FULL, InventoryService.REASON_INVENTORY_FULL, "whose inventory is full is part of the code")


func test_a_player_hands_part_of_a_stack_to_another_player_close_by() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var food: String = _give(world, alice, FOOD, 3)
	survival.get_vitals(alice.player_id).hunger = 80.0
	survival.get_vitals(bob.player_id).hunger = 50.0
	var bob_before: Dictionary = survival.to_player_fragment(bob.player_id)
	var alice_before: Dictionary = survival.to_player_fragment(alice.player_id)
	survival.drain_events()
	var transactions: Array[Dictionary] = _transactions_of(world)

	var result: ActionResult = world.try_hand_over_item(alice.player_id, food, bob.player_id, 2)
	assert_true(result.ok, result.reason)
	assert_eq(_rows(world.inventory, alice.inventory_id), [["slot_0", FOOD, 1]], "one unit stays with alice")
	assert_eq(_rows(world.inventory, bob.inventory_id), [["slot_0", FOOD, 2]], "two units are bob's now")
	assert_eq(_rows(world.inventory, carol.inventory_id), [], "nobody else got anything")
	assert_eq(transactions.size(), 1, "one inventory transaction")
	assert_eq(transactions[0].get("event_type", ""), InventoryService.EVENT_ITEM_TRANSFERRED)
	assert_eq(transactions[0].get("from_inventory_id", ""), alice.inventory_id)
	assert_eq(transactions[0].get("to_inventory_id", ""), bob.inventory_id)
	# Handing over is not feeding: nobody's vitals changed.
	assert_eq(survival.to_player_fragment(bob.player_id), bob_before, "bob was handed food, not fed")
	assert_eq(survival.to_player_fragment(alice.player_id), alice_before)
	assert_eq(survival.drain_events().size(), 0, "no survival event")
	# The result event.
	assert_eq(result.event.get("event_type", ""), ServerWorld.EVENT_ITEM_HANDED_OVER)
	assert_eq(result.event.get("player_id", ""), alice.player_id, "who handed it over")
	assert_eq(result.event.get("target_id", ""), bob.player_id, "to whom")
	assert_eq(result.event.get("item_instance_id", ""), food)
	assert_eq(result.event.get("definition_id", ""), FOOD)
	assert_eq(result.event.get("quantity", -1), 2)
	assert_eq(result.event.get("remaining_quantity", -1), 1)
	var received: Array = result.event.get("received", [])
	assert_eq(received.size(), 1, str(received))
	var bobs_food: String = str((received[0] as Dictionary).get("item_instance_id", ""))
	assert_ne(bobs_food, food)
	assert_eq(world.inventory.get_item(bobs_food).location_id, bob.inventory_id)
	assert_true(SaveService.is_json_safe(result.event))
	# Bob keeps it for later and eats it when he wants to.
	var eaten: ActionResult = ItemConsumption.try_consume(world, bob.player_id, bobs_food)
	assert_true(eaten.ok, eaten.reason)
	assert_true(absf(survival.get_vitals(bob.player_id).hunger - (50.0 - FOOD_HUNGER)) < EPSILON, "bob ate what he was handed: %f" % survival.get_vitals(bob.player_id).hunger)
	assert_eq(_quantity(world, bobs_food), 1)
	# Alice cannot use what she gave away, and the last unit goes too.
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, bobs_food).reason, InventoryService.REASON_NOT_IN_INVENTORY)
	assert_true(world.try_hand_over_item(alice.player_id, food, bob.player_id, 1).ok)
	assert_eq(_rows(world.inventory, alice.inventory_id), [])
	assert_eq(_rows(world.inventory, bob.inventory_id), [["slot_0", FOOD, 2]], "merged into the stack bob already has")
	assert_null(world.inventory.get_item(food), "alice's emptied stack is gone")


func test_any_item_can_be_handed_over() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	# An item without any use, a weapon, a treatment: the rule is about items.
	for definition_id: String in [PLAIN, "dev_melee_pipe", "dev_cure", "dev_test_item"]:
		var item_id: String = _give(world, alice, definition_id)
		var result: ActionResult = world.try_hand_over_item(alice.player_id, item_id, bob.player_id, 1)
		assert_true(result.ok, "%s: %s" % [definition_id, result.reason])
		assert_eq(world.inventory.get_item(item_id).location_id, bob.inventory_id, definition_id + " is bob's now")
	assert_eq(world.inventory.items_in_inventory(alice.inventory_id).size(), 0)
	assert_eq(world.inventory.items_in_inventory(bob.inventory_id).size(), 4)
	# A weapon works for whoever carries it: bob attacks with the pipe he was
	# handed, alice with her bare hands.
	var combat: CombatService = world.get_system(CombatService.SYSTEM_ID) as CombatService
	var unarmed: String = combat.weapon_for(world, alice.player_id).weapon_id
	assert_ne(combat.weapon_for(world, bob.player_id).weapon_id, unarmed, "the pipe is bob's weapon now")


func test_who_can_hand_something_over_and_what() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var posture: PostureService = world.get_system(PostureService.SYSTEM_ID) as PostureService
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var food: String = _give(world, alice, FOOD, 3)
	var bobs: String = _give(world, bob, FOOD, 2)
	var lying: String = world.inventory.spawn_world_item(FOOD, 1, DevWorldSeed.DEV_CELL_ID, alice.position)
	# Only an item the giver carries.
	_assert_refused(world, alice.player_id, bobs, bob.player_id, 1, InventoryService.REASON_NOT_IN_INVENTORY, "bob's own food")
	_assert_refused(world, alice.player_id, bobs, carol.player_id, 1, InventoryService.REASON_NOT_IN_INVENTORY, "bob's food to carol: nobody moves another player's item")
	_assert_refused(world, alice.player_id, lying, bob.player_id, 1, InventoryService.REASON_NOT_IN_INVENTORY, "food lying in the world")
	_assert_refused(world, alice.player_id, MISSING_ITEM_ID, bob.player_id, 1, InventoryService.REASON_UNKNOWN_ITEM, "no such item")
	_assert_refused(world, alice.player_id, bob.player_id, bob.player_id, 1, InventoryService.REASON_UNKNOWN_ITEM, "a player id is no item")
	_assert_refused(world, alice.player_id, alice.inventory_id, bob.player_id, 1, InventoryService.REASON_UNKNOWN_ITEM, "an inventory id is no item")
	# Only as many units as the stack holds, and at least one.
	for bad: int in [0, -1, -9223372036854775807, 4, 1000000, 9223372036854775807]:
		_assert_refused(world, alice.player_id, food, bob.player_id, bad, InventoryService.REASON_BAD_QUANTITY, "quantity %d" % bad)
	# Who cannot hand anything over.
	_assert_refused(world, MISSING_PLAYER_ID, food, bob.player_id, 1, ServerWorld.REASON_NOT_ONLINE, "an unknown giver")
	_assert_refused(world, carol.player_id, food, bob.player_id, 1, InventoryService.REASON_NOT_IN_INVENTORY, "carol does not hold alice's food")
	world.leave(carol.player_id)
	_assert_refused(world, carol.player_id, food, bob.player_id, 1, ServerWorld.REASON_NOT_ONLINE, "an offline giver")
	# Prone: can hand things over. Asleep: must get up first (and is not woken
	# by the refused request).
	assert_true(posture.request_posture(world, alice.player_id, PlayerPosture.Kind.PRONE).ok)
	assert_true(world.try_hand_over_item(alice.player_id, food, bob.player_id, 1).ok, "a prone player can hand an item over")
	assert_true(posture.is_prone(alice.player_id), "and stays prone")
	assert_true(posture.request_posture(world, alice.player_id, PlayerPosture.Kind.STANDING).ok)
	assert_true(survival.start_rest(alice.player_id).ok)
	_assert_refused(world, alice.player_id, food, bob.player_id, 1, SurvivalService.REASON_PLAYER_RESTING, "a sleeping player hands nothing over")
	assert_true(survival.is_resting(alice.player_id), "a refused request does not wake")
	assert_true(survival.stop_rest(alice.player_id).ok)
	# The dead hand nothing over (their belongings lie on the ground anyway).
	_kill(world, bob)
	_assert_refused(world, bob.player_id, bobs, alice.player_id, 1, SurvivalService.REASON_PLAYER_DEAD, "a dead giver")
	assert_eq(_quantity(world, food), 2)


func test_who_can_be_handed_something() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var food: String = _give(world, alice, FOOD, 5)
	# Not oneself.
	_assert_refused(world, alice.player_id, food, alice.player_id, 1, ServerWorld.REASON_TARGET_IS_SELF, "to oneself")
	# No such player, something that is no player, a player that is away: one
	# reason for all, so player ids cannot be probed.
	_assert_refused(world, alice.player_id, food, MISSING_PLAYER_ID, 1, ServerWorld.REASON_TARGET_UNAVAILABLE, "unknown player")
	_assert_refused(world, alice.player_id, food, "", 1, ServerWorld.REASON_TARGET_UNAVAILABLE, "nobody")
	_assert_refused(world, alice.player_id, food, ZOMBIE, 1, ServerWorld.REASON_TARGET_UNAVAILABLE, "a zombie id")
	_assert_refused(world, alice.player_id, food, bob.inventory_id, 1, ServerWorld.REASON_TARGET_UNAVAILABLE, "an inventory id is no player")
	world.leave(carol.player_id)
	_assert_refused(world, alice.player_id, food, carol.player_id, 1, ServerWorld.REASON_TARGET_UNAVAILABLE, "offline player")
	assert_eq(world.inventory.items_in_inventory(carol.inventory_id).size(), 0, "an offline player's inventory is not touched")
	# Within the range, measured between the server's positions.
	var range_m: float = _gameplay.hand_over_range_m
	bob.position = alice.position + Vector3(range_m + 0.01, 0.0, 0.0)
	_assert_refused(world, alice.player_id, food, bob.player_id, 1, ServerWorld.REASON_TARGET_TOO_FAR, "just out of range")
	bob.position = alice.position + Vector3(0.0, 0.0, 100.0)
	_assert_refused(world, alice.player_id, food, bob.player_id, 1, ServerWorld.REASON_TARGET_TOO_FAR, "far away")
	bob.position = alice.position + Vector3(range_m, 0.0, 0.0)
	assert_true(world.try_hand_over_item(alice.player_id, food, bob.player_id, 1).ok, "at the range")
	bob.position = alice.position + Vector3(0.0, 0.0, -range_m * 0.5)
	assert_true(world.try_hand_over_item(alice.player_id, food, bob.player_id, 1).ok, "inside the range")
	# The range is a setting of its own.
	_gameplay.hand_over_range_m = 50.0
	_gameplay.treat_range_m = 1.0
	bob.position = alice.position + Vector3(40.0, 0.0, 0.0)
	assert_true(world.try_hand_over_item(alice.player_id, food, bob.player_id, 1).ok, "a longer configured range")
	# Not the dead.
	bob.position = alice.position
	_kill(world, bob)
	assert_true(world.is_player_dead(bob.player_id))
	assert_false(world.is_player_dead(alice.player_id))
	assert_false(world.is_player_dead(MISSING_PLAYER_ID), "nobody is dead who is not known")
	assert_false(ServerSystem.new().player_is_dead(bob.player_id), "a system that knows nothing of death calls nobody dead")
	_assert_refused(world, alice.player_id, food, bob.player_id, 1, ServerWorld.REASON_TARGET_DEAD, "dead player")
	assert_eq(_quantity(world, food), 2)


func test_a_player_without_a_character_neither_gives_nor_receives() -> void:
	var world: ServerWorld = _world(true)
	var alice: PlayerState = world.join("alice")
	assert_true(world.create_character(alice.player_id, "Alice", {}).ok)
	var ghost: PlayerState = world.join("ghost")
	assert_true(world.is_player_connected(ghost.player_id) and not world.is_online(ghost.player_id), "connected, without a character")
	var food: String = _give(world, alice, FOOD, 2)
	_assert_refused(world, alice.player_id, food, ghost.player_id, 1, ServerWorld.REASON_TARGET_UNAVAILABLE, "to a player without a character")
	_assert_refused(world, ghost.player_id, food, alice.player_id, 1, ServerWorld.REASON_NOT_ONLINE, "from a player without a character")
	assert_eq(_quantity(world, food), 2)


func test_a_sleeping_or_prone_player_can_be_handed_something_and_is_not_woken() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var posture: PostureService = world.get_system(PostureService.SYSTEM_ID) as PostureService
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 4)
	assert_true(survival.start_rest(bob.player_id).ok)
	assert_true(world.try_hand_over_item(alice.player_id, food, bob.player_id, 1).ok, "a sleeping player can be handed something")
	assert_true(survival.is_resting(bob.player_id), "and sleeps on")
	assert_eq(_rows(world.inventory, bob.inventory_id), [["slot_0", FOOD, 1]])
	assert_true(survival.stop_rest(bob.player_id).ok)
	assert_true(posture.request_posture(world, bob.player_id, PlayerPosture.Kind.PRONE).ok)
	assert_true(world.try_hand_over_item(alice.player_id, food, bob.player_id, 2).ok, "a prone player can be handed something")
	assert_true(posture.is_prone(bob.player_id), "and stays prone")
	assert_eq(_rows(world.inventory, bob.inventory_id), [["slot_0", FOOD, 3]])
	assert_eq(_quantity(world, food), 1)


func test_a_full_receiver_refuses_and_nothing_changes() -> void:
	_gameplay.inventory_slot_capacity = 2
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 4)
	var plain: String = _give(world, alice, PLAIN)
	var bobs_plain: String = _give(world, bob, PLAIN)
	var bobs_food: String = _give(world, bob, FOOD, 3)
	_assert_refused(world, alice.player_id, plain, bob.player_id, 1, ServerWorld.REASON_TARGET_INVENTORY_FULL, "no free slot")
	_assert_refused(world, alice.player_id, food, bob.player_id, 3, ServerWorld.REASON_TARGET_INVENTORY_FULL, "two would fit bob's stack, the third would not")
	_assert_refused(world, alice.player_id, food, bob.player_id, 4, ServerWorld.REASON_TARGET_INVENTORY_FULL, "the whole stack")
	# What fits bob's stack entirely is handed over.
	assert_true(world.try_hand_over_item(alice.player_id, food, bob.player_id, 2).ok)
	assert_eq(_quantity(world, bobs_food), FOOD_MAX)
	assert_eq(_quantity(world, food), 2)
	_assert_refused(world, alice.player_id, food, bob.player_id, 1, ServerWorld.REASON_TARGET_INVENTORY_FULL, "bob's stack is full now")
	# Once bob makes room it works.
	assert_true(world.try_drop_item(bob.player_id, bobs_plain).ok)
	assert_true(world.try_hand_over_item(alice.player_id, food, bob.player_id, 2).ok)
	assert_eq(_rows(world.inventory, bob.inventory_id), [["slot_0", FOOD, 2], ["slot_1", FOOD, FOOD_MAX]])
	assert_eq(_rows(world.inventory, alice.inventory_id), [["slot_1", PLAIN, 1]])


func test_the_check_order_reveals_nothing_before_the_request_is_legitimate() -> void:
	_gameplay.inventory_slot_capacity = 1
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var food: String = _give(world, alice, FOOD, 2)
	var bobs: String = _give(world, bob, PLAIN)
	# The giver's own state comes first.
	assert_true(survival.start_rest(alice.player_id).ok)
	_assert_refused(world, alice.player_id, bobs, MISSING_PLAYER_ID, 0, SurvivalService.REASON_PLAYER_RESTING, "a sleeping giver learns nothing about items or targets")
	assert_true(survival.stop_rest(alice.player_id).ok)
	# Then the item: an item the giver does not hold says nothing about its
	# stack or about any target.
	_assert_refused(world, alice.player_id, bobs, MISSING_PLAYER_ID, 1, InventoryService.REASON_NOT_IN_INVENTORY, "unowned item, unknown target")
	_assert_refused(world, alice.player_id, bobs, bob.player_id, 99, InventoryService.REASON_NOT_IN_INVENTORY, "unowned item, quantity beyond its stack")
	_assert_refused(world, alice.player_id, MISSING_ITEM_ID, alice.player_id, 1, InventoryService.REASON_UNKNOWN_ITEM, "no item, to oneself")
	# Then the quantity, before anything about the target.
	_assert_refused(world, alice.player_id, food, MISSING_PLAYER_ID, 3, InventoryService.REASON_BAD_QUANTITY, "too many, unknown target")
	_assert_refused(world, alice.player_id, food, alice.player_id, 0, InventoryService.REASON_BAD_QUANTITY, "none, to oneself")
	# Far away: the distance is refused before the inventory is looked at, so
	# nobody's inventory can be probed from across the map.
	bob.position = alice.position + Vector3(100.0, 0.0, 0.0)
	_assert_refused(world, alice.player_id, food, bob.player_id, 1, ServerWorld.REASON_TARGET_TOO_FAR, "a far player with a full inventory")
	bob.position = alice.position
	_assert_refused(world, alice.player_id, food, bob.player_id, 1, ServerWorld.REASON_TARGET_INVENTORY_FULL, "the same player close by")
	# Dead comes before the distance (both are public facts), away before dead.
	_kill(world, bob)
	bob.position = alice.position + Vector3(100.0, 0.0, 0.0)
	_assert_refused(world, alice.player_id, food, bob.player_id, 1, ServerWorld.REASON_TARGET_DEAD, "far dead target")
	_kill(world, carol)
	world.leave(carol.player_id)
	_assert_refused(world, alice.player_id, food, carol.player_id, 1, ServerWorld.REASON_TARGET_UNAVAILABLE, "a dead player that is away")


# ------------------------------------------------------------ save round trip

func test_both_inventories_survive_a_save_round_trip() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 4)
	var bulk: String = _give(world, alice, BULK, 6)
	var plain: String = _give(world, alice, PLAIN)
	var bobs_bulk: String = _give(world, bob, BULK, 8)
	# Part of a stack (a new instance at bob), a whole stack that merges and
	# overflows (alice's instance moves), a single item (moves as it is) and a
	# rest that merges away (its id is retired).
	var part: ActionResult = world.try_hand_over_item(alice.player_id, food, bob.player_id, 3)
	assert_true(part.ok, part.reason)
	var bobs_food: String = str(((part.event["received"] as Array)[0] as Dictionary)["item_instance_id"])
	assert_true(world.try_hand_over_item(alice.player_id, bulk, bob.player_id, 6).ok)
	assert_true(world.try_hand_over_item(alice.player_id, plain, bob.player_id, 1).ok)
	assert_true(world.try_hand_over_item(alice.player_id, food, bob.player_id, 1).ok)
	assert_eq(_rows(world.inventory, alice.inventory_id), [])
	var bob_rows: Array = _rows(world.inventory, bob.inventory_id)
	assert_eq(bob_rows, [["slot_0", BULK, BULK_MAX], ["slot_1", FOOD, 4], ["slot_2", BULK, 4], ["slot_3", PLAIN, 1]])
	var totals: Dictionary = _totals(world.inventory)

	# Save documents -> JSON -> a brand-new world.
	var documents: Dictionary = JSON.parse_string(JSON.stringify(world.to_documents())) as Dictionary
	var restored: ServerWorld = _world()
	var errors: PackedStringArray = restored.restore_documents(documents["world_state"], documents["players"])
	assert_eq(errors.size(), 0, "; ".join(errors))
	assert_eq(_rows(restored.inventory, alice.inventory_id), [], "alice's inventory after the restart")
	assert_eq(_rows(restored.inventory, bob.inventory_id), bob_rows, "bob's inventory after the restart")
	assert_eq(JSON.stringify(restored.inventory.to_snapshot()), JSON.stringify(world.inventory.to_snapshot()), "the same items, ids, slots and quantities")
	assert_eq(_totals(restored.inventory), totals)
	assert_eq(restored.inventory.get_item(bobs_food).location_id, bob.inventory_id)
	assert_eq(restored.inventory.get_item(bulk).location_id, bob.inventory_id, "the moved instance kept its id")
	assert_eq(restored.inventory.get_item(bobs_bulk).quantity, BULK_MAX)
	assert_null(restored.inventory.get_item(food))
	assert_true(restored.registry.is_tombstoned(food), "the id of the stack that merged away stays retired after a restart")
	var fresh: String = restored.inventory.spawn_world_item(PLAIN, 1, DevWorldSeed.DEV_CELL_ID, Vector3.ZERO)
	assert_true(EntityIdGenerator.sequence_of(fresh) > EntityIdGenerator.sequence_of(bobs_food), "new ids continue after every id ever used: " + fresh)
	# The game goes on in the restored world: bob hands something back.
	var back_to: PlayerState = restored.join("alice")
	var bob_again: PlayerState = restored.join("bob")
	assert_true(restored.try_hand_over_item(bob_again.player_id, bobs_food, back_to.player_id, 2).ok)
	assert_eq(_rows(restored.inventory, alice.inventory_id), [["slot_0", FOOD, 2]])
	assert_eq(_totals(restored.inventory), {BULK: 14, FOOD: 4, PLAIN: 2})
