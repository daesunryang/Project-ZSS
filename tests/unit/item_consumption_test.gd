extends TestCase
## P2-T3 (docs/00 ADR-010): eating and drinking on the server, no network.
## SurvivalService.reduce_needs lowers hunger/thirst, ItemConsumption removes
## one unit of a carried consumable item and applies its effect as one
## all-or-nothing rule. Also: the shipped food/water definitions, the
## development seed and the save round trip.

const WORLD: String = "item_consumption_test_world"
const NEVER: float = 1.0e9
const EPSILON: float = 0.000001
const FOOD: String = "t3_food"
const WATER: String = "t3_water"
const STEW: String = "t3_stew"
const PLAIN: String = "t3_plain"
const FOOD_HUNGER: float = 30.0
const WATER_THIRST: float = 45.0
const STEW_HUNGER: float = 20.0
const STEW_THIRST: float = 10.0
const STACK_MAX: int = 5
const LETHAL_DAMAGE: float = 100000.0

var _settings: SurvivalSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = ""
	_settings = SurvivalSettings.new()
	# Only the consumption rule moves needs in these tests.
	_settings.respawn_delay_sec = NEVER


func after_each() -> void:
	if not _root.is_empty():
		SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.new()
	catalog.add(_definition(FOOD, FOOD_HUNGER, 0.0))
	catalog.add(_definition(WATER, 0.0, WATER_THIRST))
	catalog.add(_definition(STEW, STEW_HUNGER, STEW_THIRST))
	catalog.add(_definition(PLAIN, 0.0, 0.0))
	return catalog


func _definition(definition_id: String, hunger: float, thirst: float) -> ItemDefinition:
	var definition: ItemDefinition = ItemDefinition.new()
	definition.definition_id = definition_id
	definition.max_stack = STACK_MAX
	definition.consume_hunger_reduction = hunger
	definition.consume_thirst_reduction = thirst
	return definition


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.survival = _settings
	config.catalog = _catalog()
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	return config


func _world() -> ServerWorld:
	return ServerComposition.create_world(WORLD, _config())


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


## Puts a new item into the player's inventory (spawned where the player
## stands, then picked up).
func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, DevWorldSeed.DEV_CELL_ID, player.position)
	var result: ActionResult = world.try_pickup(player.player_id, item_id)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


func _events_of(events: Array[Dictionary], event_type: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == event_type:
			matching.append(event)
	return matching


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


## Listens to committed inventory transactions of `world`.
func _transactions_of(world: ServerWorld) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void: events.append(event))
	return events


# ------------------------------------------------------------ SurvivalService.reduce_needs

func test_reduce_needs_lowers_hunger_and_thirst_and_reports_it() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 60.0
	vitals.thirst = 80.0
	vitals.fatigue = 50.0
	survival.drain_events()
	var result: ActionResult = survival.reduce_needs(alice.player_id, 25.0, 30.0, "item_000001")
	assert_true(result.ok, result.reason)
	assert_true(_near(vitals.hunger, 35.0), "hunger %f" % vitals.hunger)
	assert_true(_near(vitals.thirst, 50.0), "thirst %f" % vitals.thirst)
	assert_eq(vitals.fatigue, 50.0, "fatigue is not touched")
	assert_eq(result.event.get("event_type", ""), SurvivalService.EVENT_PLAYER_NEEDS_REDUCED)
	assert_eq(result.event.get("player_id", ""), alice.player_id)
	assert_eq(result.event.get("source_id", ""), "item_000001")
	assert_true(_near(float(result.event.get("hunger_reduced", -1.0)), 25.0))
	assert_true(_near(float(result.event.get("thirst_reduced", -1.0)), 30.0))
	assert_true(_near(float(result.event.get("hunger_after", -1.0)), 35.0))
	assert_true(_near(float(result.event.get("thirst_after", -1.0)), 50.0))
	assert_eq(result.event.get("world_time", -1.0), world.clock.world_time_sec, "calendar time stamp")
	# The same fact is queued for the server log / network layer, followed by
	# the category changes it caused (hunger caution -> good, thirst danger -> caution).
	var events: Array[Dictionary] = survival.drain_events()
	assert_eq(_events_of(events, SurvivalService.EVENT_PLAYER_NEEDS_REDUCED).size(), 1)
	var categories: Dictionary = {}
	for event: Dictionary in _events_of(events, SurvivalService.EVENT_NEED_CATEGORY_CHANGED):
		categories[event["need"]] = event["category"]
	assert_eq(categories, {"hunger": "good", "thirst": "caution"})
	assert_eq(survival.need_category(alice.player_id, NeedKind.Kind.HUNGER), NeedKind.Category.GOOD)
	assert_eq(survival.need_category(alice.player_id, NeedKind.Kind.THIRST), NeedKind.Category.CAUTION)
	assert_true(SaveService.is_json_safe(result.event), "event is JSON-safe")


func test_reduce_needs_never_goes_below_zero() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 10.0
	vitals.thirst = 0.0
	var result: ActionResult = survival.reduce_needs(alice.player_id, 40.0, 40.0, "item_000001")
	assert_true(result.ok, result.reason)
	assert_eq(vitals.hunger, 0.0)
	assert_eq(vitals.thirst, 0.0)
	assert_true(_near(float(result.event.get("hunger_reduced", -1.0)), 10.0), "only what was there is reported")
	assert_eq(float(result.event.get("thirst_reduced", -1.0)), 0.0)
	# One of the two amounts may be zero (a drink does not feed).
	vitals.hunger = 50.0
	vitals.thirst = 50.0
	assert_true(survival.reduce_needs(alice.player_id, 0.0, 20.0, "item_000002").ok)
	assert_eq(vitals.hunger, 50.0)
	assert_true(_near(vitals.thirst, 30.0))


func test_reduce_needs_rejects_dead_unknown_players_and_bad_amounts() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 60.0
	vitals.thirst = 60.0
	survival.drain_events()
	for bad: Array in [[NAN, 1.0], [1.0, INF], [-1.0, 5.0], [5.0, -0.5], [0.0, 0.0]]:
		var refused: ActionResult = survival.reduce_needs(alice.player_id, float(bad[0]), float(bad[1]), "item_000001")
		assert_eq(refused.reason, SurvivalService.REASON_BAD_NEED_AMOUNT, str(bad))
		assert_eq(survival.check_reduce_needs(alice.player_id, float(bad[0]), float(bad[1])), SurvivalService.REASON_BAD_NEED_AMOUNT)
	assert_eq(survival.reduce_needs("player_999999", 5.0, 5.0, "item_000001").reason, SurvivalService.REASON_UNKNOWN_PLAYER)
	assert_eq(survival.check_reduce_needs(alice.player_id, 5.0, 0.0), "", "the preflight accepts a usable request")
	assert_eq(vitals.hunger, 60.0, "the preflight changes nothing")
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.LACERATION, LETHAL_DAMAGE)).ok)
	survival.drain_events()
	var dead: ActionResult = survival.reduce_needs(alice.player_id, 5.0, 5.0, "item_000001")
	assert_false(dead.ok)
	assert_eq(dead.reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(survival.check_reduce_needs(alice.player_id, 5.0, 5.0), SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(vitals.hunger, 60.0, "a refused request changes nothing")
	assert_eq(vitals.thirst, 60.0)
	assert_eq(survival.drain_events().size(), 0, "a refused request reports nothing")


# ------------------------------------------------------------ ItemConsumption

func test_consuming_removes_one_unit_and_lowers_the_need() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 70.0
	vitals.thirst = 70.0
	var food_id: String = _give(world, alice, FOOD, 2)
	var transactions: Array[Dictionary] = _transactions_of(world)
	var first: ActionResult = ItemConsumption.try_consume(world, alice.player_id, food_id)
	assert_true(first.ok, first.reason)
	assert_eq(world.inventory.get_item(food_id).quantity, 1, "one unit left the stack")
	assert_true(_near(vitals.hunger, 70.0 - FOOD_HUNGER), "hunger %f" % vitals.hunger)
	assert_eq(vitals.thirst, 70.0, "food does not quench thirst")
	assert_eq(first.event.get("event_type", ""), ItemConsumption.EVENT_ITEM_CONSUMED)
	assert_eq(first.event.get("player_id", ""), alice.player_id)
	assert_eq(first.event.get("item_instance_id", ""), food_id)
	assert_eq(first.event.get("definition_id", ""), FOOD)
	assert_eq(first.event.get("remaining_quantity", -1), 1)
	assert_true(_near(float(first.event.get("hunger_reduced", -1.0)), FOOD_HUNGER))
	assert_eq(float(first.event.get("thirst_reduced", -1.0)), 0.0)
	assert_true(SaveService.is_json_safe(first.event))
	assert_eq(transactions.size(), 1, "exactly one inventory transaction per consumption")
	assert_eq(transactions[0].get("event_type", ""), InventoryService.EVENT_ITEM_REMOVED)
	assert_eq(transactions[0].get("removed_quantity", 0), ItemConsumption.CONSUMED_QUANTITY)

	# The last unit: the instance is gone and its id is retired.
	var second: ActionResult = ItemConsumption.try_consume(world, alice.player_id, food_id)
	assert_true(second.ok, second.reason)
	assert_eq(second.event.get("remaining_quantity", -1), 0)
	assert_null(world.inventory.get_item(food_id))
	assert_true(world.registry.is_tombstoned(food_id))
	assert_true(_near(vitals.hunger, 70.0 - 2.0 * FOOD_HUNGER))
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, food_id).reason, InventoryService.REASON_UNKNOWN_ITEM, "nothing is left to eat")

	# An item with both effects applies both; a need already at 0 stays there.
	var stew_id: String = _give(world, alice, STEW)
	var water_id: String = _give(world, alice, WATER)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, stew_id).ok)
	assert_true(_near(vitals.hunger, 0.0), "70 - 30 - 30 - 20 is floored at 0: %f" % vitals.hunger)
	assert_true(_near(vitals.thirst, 70.0 - STEW_THIRST))
	assert_true(ItemConsumption.try_consume(world, alice.player_id, water_id).ok)
	assert_true(_near(vitals.thirst, 70.0 - STEW_THIRST - WATER_THIRST))
	assert_eq(world.inventory.items_in_inventory(alice.inventory_id).size(), 0)


func test_a_refused_consumption_changes_neither_the_item_nor_the_needs() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 70.0
	vitals.thirst = 70.0
	var food_id: String = _give(world, alice, FOOD, 3)
	var plain_id: String = _give(world, alice, PLAIN)
	var bobs_food: String = _give(world, bob, FOOD)
	var lying_food: String = world.inventory.spawn_world_item(FOOD, 1, DevWorldSeed.DEV_CELL_ID, alice.position)
	var transactions: Array[Dictionary] = _transactions_of(world)
	survival.drain_events()
	var before_items: Dictionary = world.inventory.to_snapshot()
	var before_vitals: Dictionary = vitals.to_dict()

	assert_eq(ItemConsumption.try_consume(world, alice.player_id, plain_id).reason, ItemConsumption.REASON_NOT_CONSUMABLE)
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, bobs_food).reason, InventoryService.REASON_NOT_IN_INVENTORY, "somebody else's item")
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, lying_food).reason, InventoryService.REASON_NOT_IN_INVENTORY, "an item lying in the world")
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, "item_999999").reason, InventoryService.REASON_UNKNOWN_ITEM)
	assert_eq(ItemConsumption.try_consume(world, "player_999999", food_id).reason, ServerWorld.REASON_NOT_ONLINE)
	world.leave(bob.player_id)
	assert_eq(ItemConsumption.try_consume(world, bob.player_id, bobs_food).reason, ServerWorld.REASON_NOT_ONLINE, "an offline player does not eat")
	assert_eq(world.inventory.to_snapshot(), before_items, "no item changed")
	assert_eq(vitals.to_dict(), before_vitals, "no need changed")

	# A dead player keeps the item.
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.LACERATION, LETHAL_DAMAGE)).ok)
	survival.drain_events()
	var dead: ActionResult = ItemConsumption.try_consume(world, alice.player_id, food_id)
	assert_false(dead.ok)
	assert_eq(dead.reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(world.inventory.to_snapshot(), before_items, "a dead player's item is not used up")
	assert_eq(vitals.hunger, 70.0)
	assert_eq(transactions.size(), 0, "no inventory transaction was committed")
	assert_eq(survival.drain_events().size(), 0, "no survival event was queued")


func test_a_world_without_survival_cannot_consume() -> void:
	# No survival system registered: the item must not disappear for nothing.
	var world: ServerWorld = ServerWorld.new(WORLD, GameplaySettings.new(), _catalog())
	var alice: PlayerState = world.join("alice")
	var food_id: String = _give(world, alice, FOOD, 2)
	var result: ActionResult = ItemConsumption.try_consume(world, alice.player_id, food_id)
	assert_false(result.ok)
	assert_eq(result.reason, ItemConsumption.REASON_UNAVAILABLE)
	assert_eq(world.inventory.get_item(food_id).quantity, 2)


# ------------------------------------------------------------ data

func test_item_definitions_carry_the_consumption_effect() -> void:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var food: ItemDefinition = catalog.get_definition("dev_food_ration")
	var water: ItemDefinition = catalog.get_definition("dev_water_bottle")
	assert_not_null(food, "the development food item is shipped")
	assert_not_null(water, "the development water item is shipped")
	if food == null or water == null:
		return
	assert_true(food.is_consumable())
	assert_true(food.consume_hunger_reduction > 0.0, "food lowers hunger")
	assert_true(water.is_consumable())
	assert_true(water.consume_thirst_reduction > 0.0, "water lowers thirst")
	assert_eq(food.validate().size(), 0, "; ".join(food.validate()))
	assert_eq(water.validate().size(), 0, "; ".join(water.validate()))
	assert_false(catalog.get_definition("dev_test_item").is_consumable(), "existing items are not consumable")
	assert_false(catalog.get_definition("dev_melee_pipe").is_consumable())
	assert_false(ItemDefinition.new().is_consumable(), "not consumable unless the data says so")
	var negative: ItemDefinition = _definition("t3_bad", -1.0, 0.0)
	assert_true(negative.validate().size() > 0, "a negative effect is invalid data")
	var not_finite: ItemDefinition = _definition("t3_nan", 0.0, NAN)
	assert_true(not_finite.validate().size() > 0)
	assert_eq(ItemCatalog.new().add(negative), ERR_INVALID_DATA, "the catalog refuses it")


func test_the_default_new_world_has_food_water_and_a_weapon() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var no_zombies: ZombieSettings = ZombieSettings.new()
	no_zombies.dev_spawn_count = 0
	config.zombie = no_zombies
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	assert_eq(world.seed_new_world(config.dev_seed), OK)
	var hunger_units: float = 0.0
	var thirst_units: float = 0.0
	var by_definition: Dictionary = {}
	var spawn: Vector3 = config.gameplay.player_spawn_position
	for item_id: String in world.inventory.world_item_ids():
		var item: ItemInstance = world.inventory.get_item(item_id)
		var definition: ItemDefinition = config.catalog.get_definition(item.definition_id)
		by_definition[item.definition_id] = int(by_definition.get(item.definition_id, 0)) + item.quantity
		hunger_units += definition.consume_hunger_reduction * float(item.quantity)
		thirst_units += definition.consume_thirst_reduction * float(item.quantity)
		assert_true(world.inventory.world_position_of(item_id).distance_to(spawn) <= 10.0, "%s lies near the spawn point" % item.definition_id)
	assert_true(int(by_definition.get("dev_food_ration", 0)) >= 2, "food: %s" % str(by_definition))
	assert_true(int(by_definition.get("dev_water_bottle", 0)) >= 2, "water: %s" % str(by_definition))
	assert_eq(int(by_definition.get("dev_melee_pipe", 0)), 1, "one development weapon")
	assert_eq(int(by_definition.get("dev_test_item", 0)), 1, "the Phase 1 test item is still there")
	# Enough to bring a need at its maximum back to 0 at least once.
	assert_true(hunger_units >= config.survival.need_max, "hunger units in the world: %f" % hunger_units)
	assert_true(thirst_units >= config.survival.need_max, "thirst units in the world: %f" % thirst_units)


func test_dev_seed_quantities_are_validated_and_applied() -> void:
	var dev_seed: DevWorldSeed = DevWorldSeed.new()
	dev_seed.item_definition_ids = PackedStringArray([FOOD, WATER])
	dev_seed.item_positions = PackedVector3Array([Vector3(1, 0, 0), Vector3(2, 0, 0)])
	assert_eq(dev_seed.validate().size(), 0, "no quantities = one of each")
	assert_eq(dev_seed.quantity_at(0), 1)
	dev_seed.item_quantities = PackedInt32Array([3])
	assert_true(dev_seed.validate().size() > 0, "quantities must match the item list")
	dev_seed.item_quantities = PackedInt32Array([3, 0])
	assert_true(dev_seed.validate().size() > 0, "a quantity below 1 is invalid")
	dev_seed.item_quantities = PackedInt32Array([3, STACK_MAX])
	assert_eq(dev_seed.validate().size(), 0, "; ".join(dev_seed.validate()))
	var world: ServerWorld = _world()
	assert_eq(world.seed_new_world(dev_seed), OK)
	var quantities: Dictionary = {}
	for item_id: String in world.inventory.world_item_ids():
		var item: ItemInstance = world.inventory.get_item(item_id)
		quantities[item.definition_id] = item.quantity
	assert_eq(quantities, {FOOD: 3, WATER: STACK_MAX})
	# More than a stack holds is refused when the world is seeded.
	dev_seed.item_quantities = PackedInt32Array([3, STACK_MAX + 1])
	assert_eq(_world().seed_new_world(dev_seed), ERR_INVALID_DATA)


# ------------------------------------------------------------ save round trip

func test_consumed_items_and_lowered_needs_survive_a_save_round_trip() -> void:
	_root = "user://test_saves/consumption_%d" % Time.get_ticks_usec()
	var config: CompositionConfig = _config()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), config)
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	if world == null:
		return
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 80.0
	vitals.thirst = 90.0
	var food_id: String = _give(world, alice, FOOD, 3)
	var water_id: String = _give(world, alice, WATER, 1)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, food_id).ok)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, water_id).ok)
	var hunger_after: float = vitals.hunger
	var thirst_after: float = vitals.thirst
	assert_eq(persistence.save(world), OK)

	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), config).load_or_create(WORLD)
	assert_not_null(restored, "world restored from save")
	if restored == null:
		return
	var restored_vitals: PlayerVitals = _survival(restored).get_vitals(alice.player_id)
	assert_true(_near(restored_vitals.hunger, hunger_after), "hunger %f" % restored_vitals.hunger)
	assert_true(_near(restored_vitals.thirst, thirst_after), "thirst %f" % restored_vitals.thirst)
	assert_true(_near(restored_vitals.hunger, 80.0 - FOOD_HUNGER))
	assert_eq(restored.inventory.get_item(food_id).quantity, 2, "the smaller stack was saved")
	assert_null(restored.inventory.get_item(water_id), "the used-up item is not restored")
	assert_true(restored.registry.is_tombstoned(water_id))
	# The restored world keeps eating from the same stack.
	restored.join("alice")
	assert_true(ItemConsumption.try_consume(restored, alice.player_id, food_id).ok)
	assert_eq(restored.inventory.get_item(food_id).quantity, 1)
