extends TestCase
## P2-T15 (user decision 2026-11-16, docs/00 ADR-021, docs/09 §14.29): items
## travel between players over the ground. A player puts units of a carried
## stack down, anybody close by picks them up, and what is picked up joins
## the stacks the picker already carries. The one-sided hand-over of P2-T14
## is gone: no rule puts an item into another player's inventory.
##   InventoryService.drop_item    with a quantity: a part of a stack becomes
##                                 a new item lying in the world.
##   InventoryService.try_pickup   merges into carried stacks of the same kind.
##   ServerWorld.try_drop_item     the rule (who may put what down, where).
## Server rules only, no network (tests/integration/ground_transfer_net_test.gd).

const WORLD: String = "ground_transfer_test_world"
const CELL: String = "cell_0_0"
const PICKUP_RANGE: float = 2.0
const HALF_EXTENT: float = 50.0
const NEVER: float = 1.0e9
const LETHAL_DAMAGE: float = 100000.0
const ZOMBIE: String = "zombie_000001"
const MISSING_ITEM_ID: String = "item_999999"
const MISSING_INVENTORY_ID: String = "inventory_999999"
const DROP_AT: Vector3 = Vector3(3.5, 0.0, -7.25)
## Food: stacks of up to FOOD_MAX.
const FOOD: String = "t15_food"
const FOOD_MAX: int = 5
const FOOD_HUNGER: float = 30.0
## An item without any use, one per slot.
const PLAIN: String = "t15_plain"
## An item without any use that stacks up to BULK_MAX.
const BULK: String = "t15_bulk"
const BULK_MAX: int = 10
const SOAK_SEED: int = 20261116
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
	_service = InventoryService.new(_catalog, _ids, _registry, PICKUP_RANGE, HALF_EXTENT)
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


## Spawns an item at the origin (bare service).
func _lying(definition_id: String, quantity: int = 1) -> String:
	return _service.spawn_world_item(definition_id, quantity, CELL, Vector3.ZERO)


## Puts a new stack into `inventory_id` WITHOUT merging it into the stacks
## already there (a test layout, built with pickups).
func _put(inventory_id: String, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = _lying(definition_id, quantity)
	var merging: bool = _service.merge_on_pickup
	_service.merge_on_pickup = false
	var result: ActionResult = _service.try_pickup(inventory_id, item_id, Vector3.ZERO)
	_service.merge_on_pickup = merging
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


func _world() -> ServerWorld:
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


# ------------------------------------------------------------ putting a part of a stack down

func test_a_part_of_a_stack_is_put_down_as_a_new_item_in_the_world() -> void:
	var mine: String = _service.create_inventory(2)
	var item_id: String = _put(mine, BULK, 6)
	_service.get_item(item_id).condition = 0.75
	_service.get_item(item_id).quality = 0.5
	_events.clear()

	var result: ActionResult = _service.drop_item(mine, item_id, CELL, DROP_AT, 2)
	assert_true(result.ok, result.reason)
	assert_eq(_rows(_service, mine), [["slot_0", BULK, 4]], "the rest stays where it was")
	assert_eq(_service.get_item(item_id).location_type, ItemInstance.LOCATION_INVENTORY, "the carried stack is still carried")
	assert_eq(_service.world_item_ids().size(), 1, "one item lies in the world")
	var lying_id: String = _service.world_item_ids()[0]
	assert_ne(lying_id, item_id, "two stacks cannot share one id")
	assert_true(EntityIdGenerator.sequence_of(lying_id) > EntityIdGenerator.sequence_of(item_id), "a fresh id: " + lying_id)
	assert_eq(_registry.kind_of(lying_id), InventoryService.ENTITY_KIND_ITEM, "the new instance is registered")
	var lying: ItemInstance = _service.get_item(lying_id)
	assert_eq(lying.definition_id, BULK)
	assert_eq(lying.quantity, 2)
	assert_eq(lying.location_type, ItemInstance.LOCATION_WORLD)
	assert_eq(lying.location_id, CELL)
	assert_eq(lying.slot_id, "")
	assert_eq(lying.condition, 0.75, "the units keep their condition")
	assert_eq(lying.quality, 0.5, "and their quality")
	assert_eq(_service.world_position_of(lying_id), DROP_AT)
	assert_eq(_totals(_service), {BULK: 6}, "six units before, six after")
	assert_eq(result.event, {
		"event_type": InventoryService.EVENT_ITEM_UNITS_DROPPED,
		"inventory_id": mine,
		"item_instance_id": item_id,
		"definition_id": BULK,
		"quantity": 2,
		"remaining_quantity": 4,
		"world_item_instance_id": lying_id,
		"cell_id": CELL,
		"position": [DROP_AT.x, DROP_AT.y, DROP_AT.z],
	})
	assert_true(SaveService.is_json_safe(result.event))
	assert_eq(_events, [result.event], "listeners are told once, with the same event")
	assert_eq(_registry.tombstones().size(), 0, "no id was retired")


func test_the_whole_stack_is_put_down_as_it_is() -> void:
	var mine: String = _service.create_inventory(3)
	var by_default: String = _put(mine, BULK, 4)
	var by_marker: String = _put(mine, BULK, 3)
	var by_count: String = _put(mine, BULK, 7)
	var next_sequence: int = _ids.get_next_sequence()
	_events.clear()

	# No quantity, the "whole stack" marker and exactly the stack's size all
	# mean the same: the instance itself goes to the world and keeps its id.
	assert_true(_service.drop_item(mine, by_default, CELL, DROP_AT).ok)
	assert_true(_service.drop_item(mine, by_marker, CELL, DROP_AT, InventoryService.WHOLE_STACK).ok)
	var counted: ActionResult = _service.drop_item(mine, by_count, CELL, DROP_AT, 7)
	assert_true(counted.ok, counted.reason)
	assert_eq(counted.event, {
		"event_type": InventoryService.EVENT_ITEMS_DROPPED,
		"inventory_id": mine,
		"item_instance_ids": [by_count],
		"cell_id": CELL,
		"position": [DROP_AT.x, DROP_AT.y, DROP_AT.z],
	}, "the event of a whole stack is the one of P2-T2")
	assert_eq(_rows(_service, mine), [])
	assert_eq(_service.world_item_ids(), PackedStringArray([by_default, by_marker, by_count]), "the same three instances")
	assert_eq(_service.get_item(by_count).quantity, 7)
	assert_eq(_ids.get_next_sequence(), next_sequence, "a whole stack needs no new id")
	assert_eq(_events.size(), 3)


func test_a_refused_drop_of_units_changes_nothing() -> void:
	var mine: String = _service.create_inventory(2)
	var theirs: String = _service.create_inventory(2)
	var carried: String = _put(mine, BULK, 3)
	var other: String = _put(theirs, BULK, 3)
	var lying: String = _lying(BULK, 3)
	var before: Dictionary = _service.to_snapshot()
	var next_sequence: int = _ids.get_next_sequence()
	_events.clear()

	for bad: int in [-1, -9223372036854775807, 4, 1000000, 9223372036854775807]:
		assert_eq(_service.drop_item(mine, carried, CELL, DROP_AT, bad).reason, InventoryService.REASON_BAD_QUANTITY, "quantity %d" % bad)
	assert_eq(_service.drop_item(MISSING_INVENTORY_ID, carried, CELL, DROP_AT, 1).reason, InventoryService.REASON_UNKNOWN_INVENTORY)
	assert_eq(_service.drop_item(mine, MISSING_ITEM_ID, CELL, DROP_AT, 1).reason, InventoryService.REASON_UNKNOWN_ITEM)
	assert_eq(_service.drop_item(mine, other, CELL, DROP_AT, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "someone else's item")
	assert_eq(_service.drop_item(mine, lying, CELL, DROP_AT, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "an item lying in the world")
	# Ownership before the quantity: nothing is learnt about a stack that is
	# not carried.
	assert_eq(_service.drop_item(mine, other, CELL, DROP_AT, 99).reason, InventoryService.REASON_NOT_IN_INVENTORY)
	assert_eq(_service.drop_item(mine, carried, "", DROP_AT, 1).reason, InventoryService.REASON_BAD_CELL)
	assert_eq(_service.drop_item(mine, carried, CELL, Vector3(HALF_EXTENT + 1.0, 0.0, 0.0), 1).reason, InventoryService.REASON_BAD_POSITION)
	assert_eq(_service.drop_item(mine, carried, CELL, Vector3(NAN, 0.0, 0.0), 1).reason, InventoryService.REASON_BAD_POSITION)
	assert_eq(_service.to_snapshot(), before, "a refused drop changes nothing")
	assert_eq(_ids.get_next_sequence(), next_sequence, "no id was used up")
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(_events.size(), 0, "a refused drop tells no listener")


# ------------------------------------------------------------ picking up merges

func test_a_picked_up_item_joins_the_carried_stack_of_the_same_kind() -> void:
	assert_true(_service.merge_on_pickup, "merging is the default")
	var mine: String = _service.create_inventory(3)
	_put(mine, PLAIN)
	var stack_id: String = _put(mine, BULK, 3)
	var lying: String = _lying(BULK, 4)
	var next_sequence: int = _ids.get_next_sequence()
	_events.clear()

	var result: ActionResult = _service.try_pickup(mine, lying, Vector3.ZERO)
	assert_true(result.ok, result.reason)
	assert_eq(_rows(_service, mine), [["slot_0", PLAIN, 1], ["slot_1", BULK, 7]], "merged: still one stack, no new slot")
	assert_null(_service.get_item(lying), "the instance that merged away no longer exists")
	assert_false(_registry.has(lying))
	assert_true(_registry.is_tombstoned(lying), "its id is never used again")
	assert_eq(_service.world_item_ids().size(), 0, "nothing lies in the world any more")
	assert_eq(_ids.get_next_sequence(), next_sequence, "a merge needs no new id")
	assert_eq(_totals(_service), {PLAIN: 1, BULK: 7})
	assert_eq(result.event, {
		"event_type": InventoryService.EVENT_ITEM_PICKED_UP,
		"item_instance_id": lying,
		"inventory_id": mine,
		"slot_id": "",
		"from_cell_id": CELL,
		"definition_id": BULK,
		"quantity": 4,
		"merged": [{"item_instance_id": stack_id, "quantity": 4}],
	}, "slot_id \"\" = the picked-up instance is gone, its units are in `merged`")
	assert_true(SaveService.is_json_safe(result.event))
	assert_eq(_events, [result.event])
	assert_eq(_service.try_pickup(mine, lying, Vector3.ZERO).reason, InventoryService.REASON_UNKNOWN_ITEM, "it cannot be picked up twice")


func test_what_does_not_fit_the_stacks_keeps_its_id_in_a_free_slot() -> void:
	var mine: String = _service.create_inventory(4)
	var first: String = _put(mine, BULK, 8)
	_put(mine, PLAIN)
	var second: String = _put(mine, BULK, 9)
	var lying: String = _lying(BULK, 5)
	_events.clear()

	# Two units fill the first stack, one the second, two are left over: the
	# picked-up instance itself takes the free slot with what is left.
	var result: ActionResult = _service.try_pickup(mine, lying, Vector3.ZERO)
	assert_true(result.ok, result.reason)
	assert_eq(_rows(_service, mine), [["slot_0", BULK, BULK_MAX], ["slot_1", PLAIN, 1], ["slot_2", BULK, BULK_MAX], ["slot_3", BULK, 2]], "no stack exceeds max_stack")
	assert_eq(_service.get_item(lying).slot_id, "slot_3", "the same instance, now carried")
	assert_eq(result.event.get("slot_id", ""), "slot_3")
	assert_eq(result.event.get("quantity", -1), 5, "the units that were picked up")
	assert_eq(result.event.get("merged", []), [{"item_instance_id": first, "quantity": 2}, {"item_instance_id": second, "quantity": 1}], "stacks are filled in slot order")
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(_totals(_service), {BULK: 22, PLAIN: 1})

	# Nothing to join: the item takes the first free slot as it always did.
	var other: String = _service.create_inventory(2)
	var alone: String = _lying(FOOD, 3)
	var plain: ActionResult = _service.try_pickup(other, alone, Vector3.ZERO)
	assert_true(plain.ok, plain.reason)
	assert_eq(_rows(_service, other), [["slot_0", FOOD, 3]])
	assert_eq(plain.event.get("merged", ["x"]), [], "nothing merged")
	assert_eq(plain.event.get("slot_id", ""), "slot_0")


func test_a_full_inventory_still_takes_what_fits_its_stacks_entirely() -> void:
	var mine: String = _service.create_inventory(2)
	_put(mine, PLAIN)
	var stack_id: String = _put(mine, BULK, 8)
	var too_many: String = _lying(BULK, 3)
	var single: String = _lying(PLAIN)
	var fits: String = _lying(BULK, 2)
	var before: Dictionary = _service.to_snapshot()
	_events.clear()

	# Two of three would fit the stack, the third has no slot: nothing is
	# picked up (never a part of a stack).
	assert_eq(_service.try_pickup(mine, too_many, Vector3.ZERO).reason, InventoryService.REASON_INVENTORY_FULL, "part of it fits")
	assert_eq(_service.try_pickup(mine, single, Vector3.ZERO).reason, InventoryService.REASON_INVENTORY_FULL, "no stack to join and no free slot")
	assert_eq(_service.to_snapshot(), before, "a refused pickup changes nothing")
	assert_eq(_registry.tombstones().size(), 0)
	assert_eq(_events.size(), 0)
	# What fits a stack entirely is taken although every slot is in use.
	assert_true(_service.try_pickup(mine, fits, Vector3.ZERO).ok)
	assert_eq(_service.get_item(stack_id).quantity, BULK_MAX)
	assert_null(_service.get_item(fits))


func test_units_of_another_condition_or_quality_are_not_merged() -> void:
	var mine: String = _service.create_inventory(4)
	var worn: String = _put(mine, BULK, 3)
	var poor: String = _put(mine, BULK, 3)
	_service.get_item(worn).condition = 0.5
	_service.get_item(poor).quality = 0.25
	var lying: String = _lying(BULK, 3)
	assert_true(_service.try_pickup(mine, lying, Vector3.ZERO).ok)
	assert_eq(_rows(_service, mine), [["slot_0", BULK, 3], ["slot_1", BULK, 3], ["slot_2", BULK, 3]], "each stack kept its own units")
	assert_eq(_service.get_item(worn).condition, 0.5, "no unit's condition was averaged away")
	assert_eq(_service.get_item(lying).condition, ItemInstance.MAX_UNIT_VALUE)
	# A worn item lying in the world joins the worn stack only.
	var worn_lying: String = _lying(BULK, 2)
	_service.get_item(worn_lying).condition = 0.5
	assert_true(_service.try_pickup(mine, worn_lying, Vector3.ZERO).ok)
	assert_eq(_service.get_item(worn).quantity, 5)
	assert_eq(_service.get_item(lying).quantity, 3)


func test_merging_on_pickup_can_be_switched_off() -> void:
	_service.merge_on_pickup = false
	var mine: String = _service.create_inventory(3)
	var stack_id: String = _put(mine, BULK, 3)
	var lying: String = _lying(BULK, 4)
	var result: ActionResult = _service.try_pickup(mine, lying, Vector3.ZERO)
	assert_true(result.ok, result.reason)
	assert_eq(_rows(_service, mine), [["slot_0", BULK, 3], ["slot_1", BULK, 4]], "every picked-up item takes a slot of its own")
	assert_eq(_service.get_item(stack_id).quantity, 3)
	assert_eq(result.event.get("merged", ["x"]), [])
	# The setting of the game, and the world that passes it on.
	var shipped: GameplaySettings = GameplaySettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_true(shipped.merge_stacks_on_pickup, "the shipped rule merges")
	assert_eq(GameplaySettings.new().merge_stacks_on_pickup, shipped.merge_stacks_on_pickup, "the script default agrees with the shipped resource")
	assert_true(_world().inventory.merge_on_pickup)
	_gameplay.merge_stacks_on_pickup = false
	assert_false(_world().inventory.merge_on_pickup, "the world hands the setting to its inventory")


## Many drops of parts and pickups among three inventories, accepted and
## refused, in a fixed random order: the units of every definition are
## conserved, no id is used twice, no stack is empty or larger than
## max_stack and no inventory holds more stacks than it has slots.
func test_units_are_conserved_over_many_drops_and_pickups() -> void:
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
	var dropped: int = 0
	var picked: int = 0
	var refused: int = 0
	var consistent: bool = true
	for round_index: int in range(SOAK_ROUNDS):
		var inventory_id: String = inventories[rng.randi_range(0, inventories.size() - 1)]
		var before: Dictionary = _service.to_snapshot()
		var result: ActionResult = null
		var lying: PackedStringArray = _service.world_item_ids()
		if not lying.is_empty() and rng.randf() < 0.55:
			result = _service.try_pickup(inventory_id, lying[rng.randi_range(0, lying.size() - 1)], Vector3.ZERO)
			picked += 1 if result.ok else 0
		else:
			var carried: Array[ItemInstance] = _service.items_in_inventory(inventory_id)
			if carried.is_empty():
				continue
			var item: ItemInstance = carried[rng.randi_range(0, carried.size() - 1)]
			# From "the whole stack" (0) to one more than the stack holds (a refusal).
			result = _service.drop_item(inventory_id, item.item_instance_id, CELL, Vector3.ZERO, rng.randi_range(0, item.quantity + 1))
			dropped += 1 if result.ok else 0
		if not result.ok:
			refused += 1
			consistent = consistent and _service.to_snapshot() == before
		consistent = consistent and _totals(_service) == totals
		for held_in: String in inventories:
			var slots: Dictionary = {}
			for held: ItemInstance in _service.items_in_inventory(held_in):
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
	assert_true(dropped > 40, "enough drops were accepted: %d" % dropped)
	assert_true(picked > 40, "enough pickups were accepted: %d" % picked)
	assert_true(refused > 10, "and enough requests refused: %d" % refused)
	assert_eq(_totals(_service), totals, "every unit is still there, none was copied")
	for retired: String in _registry.tombstones():
		assert_null(_service.get_item(retired), "a retired id names no item")


# ------------------------------------------------------------ the rule

func test_a_player_puts_one_unit_down_and_another_player_picks_it_up() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	alice.position = Vector3(4.0, 0.0, -3.0)
	bob.position = alice.position + Vector3(1.0, 0.0, 0.0)
	var food: String = _give(world, alice, FOOD, 3)
	var bobs: String = _give(world, bob, FOOD, 1)
	var alice_before: Dictionary = survival.to_player_fragment(alice.player_id)
	var bob_before: Dictionary = survival.to_player_fragment(bob.player_id)
	survival.drain_events()

	# Three single units, one after the other, each a new item at alice's feet.
	var lying_ids: Array = []
	for index: int in range(2):
		var dropped: ActionResult = world.try_drop_item(alice.player_id, food, 1)
		assert_true(dropped.ok, dropped.reason)
		assert_eq(dropped.event.get("event_type", ""), InventoryService.EVENT_ITEM_UNITS_DROPPED)
		assert_eq(dropped.event.get("position", []), [alice.position.x, alice.position.y, alice.position.z], "where the server knows alice to be")
		assert_eq(dropped.event.get("cell_id", ""), world.cell_id_at(alice.position), "in the cell of that position (P3-1)")
		lying_ids.append(str(dropped.event.get("world_item_instance_id", "")))
	# The last unit is the stack itself.
	var last: ActionResult = world.try_drop_item(alice.player_id, food, 1)
	assert_true(last.ok, last.reason)
	assert_eq(last.event.get("event_type", ""), InventoryService.EVENT_ITEMS_DROPPED, "the last unit is the whole stack")
	lying_ids.append(food)
	assert_eq(_rows(world.inventory, alice.inventory_id), [], "alice carries nothing any more")
	assert_eq(world.inventory.world_item_ids().size(), 3, "three items lie on the ground")
	assert_eq(_rows(world.inventory, bob.inventory_id), [["slot_0", FOOD, 1]], "nothing reached bob's inventory by itself")

	# Bob picks them up: they pile into the stack he has, not into three slots.
	for lying_id: String in lying_ids:
		var picked: ActionResult = world.try_pickup(bob.player_id, lying_id)
		assert_true(picked.ok, picked.reason)
	assert_eq(_rows(world.inventory, bob.inventory_id), [["slot_0", FOOD, 4]], "one stack of four")
	assert_eq(world.inventory.get_item(bobs).quantity, 4)
	assert_eq(world.inventory.world_item_ids().size(), 0)
	assert_eq(_rows(world.inventory, carol.inventory_id), [], "nobody else got anything")
	assert_eq(_totals(world.inventory), {FOOD: 4})
	# Moving items is not using them: nobody's vitals changed.
	assert_eq(survival.to_player_fragment(alice.player_id), alice_before)
	assert_eq(survival.to_player_fragment(bob.player_id), bob_before)
	assert_eq(survival.drain_events().size(), 0, "no survival event")
	# Bob keeps it for later and eats when he wants to.
	survival.get_vitals(bob.player_id).hunger = 50.0
	assert_true(ItemConsumption.try_consume(world, bob.player_id, bobs).ok)
	assert_eq(world.inventory.get_item(bobs).quantity, 3)


func test_who_can_put_what_down() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var posture: PostureService = world.get_system(PostureService.SYSTEM_ID) as PostureService
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 3)
	var bobs: String = _give(world, bob, FOOD, 2)
	var lying: String = world.inventory.spawn_world_item(PLAIN, 1, DevWorldSeed.DEV_CELL_ID, alice.position)
	var before: Dictionary = world.to_documents()
	# Only an item the player carries, and only as many units as it holds.
	assert_eq(world.try_drop_item(alice.player_id, bobs, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "bob's food")
	assert_eq(world.try_drop_item(alice.player_id, lying, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "an item lying in the world")
	assert_eq(world.try_drop_item(alice.player_id, MISSING_ITEM_ID, 1).reason, InventoryService.REASON_UNKNOWN_ITEM)
	assert_eq(world.try_drop_item(alice.player_id, bob.player_id, 1).reason, InventoryService.REASON_UNKNOWN_ITEM, "a player id is no item")
	for bad: int in [-1, 4, 9223372036854775807]:
		assert_eq(world.try_drop_item(alice.player_id, food, bad).reason, InventoryService.REASON_BAD_QUANTITY, "quantity %d" % bad)
	assert_eq(world.try_drop_item("player_999999", food, 1).reason, ServerWorld.REASON_NOT_ONLINE, "an unknown player")
	# Asleep: must get up first. Dead: its belongings lie on the ground anyway.
	assert_true(survival.start_rest(alice.player_id).ok)
	assert_eq(world.try_drop_item(alice.player_id, food, 1).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_true(survival.is_resting(alice.player_id), "a refused request does not wake")
	assert_true(survival.stop_rest(alice.player_id).ok)
	assert_eq(JSON.stringify(world.to_documents()), JSON.stringify(before), "no refused request changed anything")
	# Prone: can put things down.
	assert_true(posture.request_posture(world, alice.player_id, PlayerPosture.Kind.PRONE).ok)
	assert_true(world.try_drop_item(alice.player_id, food, 1).ok, "a prone player can put an item down")
	assert_true(posture.is_prone(alice.player_id), "and stays prone")
	_kill(world, bob)
	assert_true(world.is_player_dead(bob.player_id))
	assert_false(world.is_player_dead(alice.player_id))
	assert_false(ServerSystem.new().player_is_dead(bob.player_id), "a system that knows nothing of death calls nobody dead")
	assert_eq(world.try_drop_item(bob.player_id, bobs, 1).reason, SurvivalService.REASON_PLAYER_DEAD)
	world.leave(alice.player_id)
	assert_eq(world.try_drop_item(alice.player_id, food, 1).reason, ServerWorld.REASON_NOT_ONLINE, "an offline player")
	assert_eq(world.inventory.get_item(food).quantity, 2)


func test_no_rule_moves_an_item_into_another_players_inventory() -> void:
	var world: ServerWorld = _world()
	# The one-sided hand-over of P2-T14 and its range are gone (ADR-021).
	assert_false(world.has_method("try_hand_over_item"), "the hand-over rule was withdrawn")
	var has_range: bool = false
	for property: Dictionary in GameplaySettings.new().get_property_list():
		has_range = has_range or str(property["name"]) == "hand_over_range_m"
	assert_false(has_range, "its range setting went with it")
	# What a player can do with an item it carries: put it down or use it.
	# Neither names another inventory.
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 2)
	assert_true(world.try_drop_item(alice.player_id, food, 1).ok)
	assert_eq(_rows(world.inventory, bob.inventory_id), [], "a drop next to bob puts nothing into his inventory")
	assert_eq(world.inventory.world_item_ids().size(), 1, "it lies on the ground until somebody picks it up")


# ------------------------------------------------------------ save round trip

func test_parts_put_down_and_merged_pickups_survive_a_save_round_trip() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 4)
	var bulk: String = _give(world, alice, BULK, 6)
	var bobs_bulk: String = _give(world, bob, BULK, 8)
	# A part of a stack lies on the ground, another part was picked up and
	# merged away (its id is retired), a whole stack overflowed into a slot.
	var part: ActionResult = world.try_drop_item(alice.player_id, food, 3)
	assert_true(part.ok, part.reason)
	var lying_food: String = str(part.event["world_item_instance_id"])
	var units: ActionResult = world.try_drop_item(alice.player_id, bulk, 2)
	assert_true(units.ok, units.reason)
	var lying_bulk: String = str(units.event["world_item_instance_id"])
	assert_true(world.try_pickup(bob.player_id, lying_bulk).ok)
	assert_true(world.try_drop_item(alice.player_id, bulk).ok)
	assert_true(world.try_pickup(bob.player_id, bulk).ok)
	assert_eq(_rows(world.inventory, alice.inventory_id), [["slot_0", FOOD, 1]])
	var bob_rows: Array = _rows(world.inventory, bob.inventory_id)
	assert_eq(bob_rows, [["slot_0", BULK, BULK_MAX], ["slot_1", BULK, 4]])
	assert_eq(world.inventory.world_item_ids(), PackedStringArray([lying_food]))
	var totals: Dictionary = _totals(world.inventory)

	# Save documents -> JSON -> a brand-new world.
	var documents: Dictionary = JSON.parse_string(JSON.stringify(world.to_documents())) as Dictionary
	var restored: ServerWorld = _world()
	var errors: PackedStringArray = restored.restore_documents(documents["world_state"], documents["players"])
	assert_eq(errors.size(), 0, "; ".join(errors))
	assert_eq(JSON.stringify(restored.inventory.to_snapshot()), JSON.stringify(world.inventory.to_snapshot()), "the same items, ids, slots, quantities and positions")
	assert_eq(_rows(restored.inventory, bob.inventory_id), bob_rows)
	assert_eq(_totals(restored.inventory), totals)
	assert_eq(restored.inventory.get_item(lying_food).quantity, 3)
	assert_eq(restored.inventory.world_position_of(lying_food), alice.position)
	assert_eq(restored.inventory.get_item(bobs_bulk).quantity, BULK_MAX)
	assert_null(restored.inventory.get_item(lying_bulk))
	assert_true(restored.registry.is_tombstoned(lying_bulk), "the id of the item that merged away stays retired after a restart")
	var fresh: String = restored.inventory.spawn_world_item(PLAIN, 1, DevWorldSeed.DEV_CELL_ID, Vector3.ZERO)
	assert_true(EntityIdGenerator.sequence_of(fresh) > EntityIdGenerator.sequence_of(lying_bulk), "new ids continue after every id ever used: " + fresh)
	# The game goes on in the restored world: alice picks her food up again.
	var alice_again: PlayerState = restored.join("alice")
	assert_true(restored.try_pickup(alice_again.player_id, lying_food).ok)
	assert_eq(_rows(restored.inventory, alice.inventory_id), [["slot_0", FOOD, 4]], "it joined the unit she kept")
