extends TestCase
## F-1 (docs/09 §14.18.1, docs/15 §21): food and drink variety. The shipped
## definitions load and are valid, eating / drinking also lowers fatigue and
## gives back health, raw food and dirty water roll food sickness with the
## eater's saved RNG (deterministic, never lethal), the mood / tremor flags
## are data only, and the new items are in the shipped loot tables.

const WORLD: String = "food_drink_consumption_test_world"
const NEVER: float = 1.0e9
const EPSILON: float = 0.000001
const STACK_MAX: int = 50
## Test-only definitions (not shipped).
const ALWAYS_SICK: String = "f1_always_sick"
const HALF_SICK: String = "f1_half_sick"
const FATIGUE_ONLY: String = "f1_fatigue_only"
const ALWAYS_SICK_HUNGER: float = 10.0
const FATIGUE_ONLY_AMOUNT: float = 30.0

## The settled list (notes/feature-plan-2026-11-20.md "목록", F-1 rows).
const FOODS: PackedStringArray = [
	"canned_beans", "canned_tuna", "canned_fruit", "instant_ramen", "snack_chips",
	"chocolate_bar", "bread", "rice", "flour", "raw_meat", "raw_fish", "raw_egg",
	"raw_potato", "vegetable", "fruit",
]
const COOKED: PackedStringArray = ["grilled_meat", "grilled_fish", "boiled_egg", "baked_potato"]
## dev_water_bottle is the bottled water (생수) of the list.
const DRINKS: PackedStringArray = [
	"dev_water_bottle", "dirty_water", "boiled_water", "juice", "soda", "coffee",
	"tea", "milk", "energy_drink", "alcohol",
]
const RAW: PackedStringArray = ["raw_meat", "raw_fish", "raw_egg", "raw_potato", "dirty_water"]
## Raw -> its cooked form: cooking makes the effect bigger and safe.
const RAW_TO_COOKED: Dictionary = {
	"raw_meat": "grilled_meat", "raw_fish": "grilled_fish",
	"raw_egg": "boiled_egg", "raw_potato": "baked_potato", "dirty_water": "boiled_water",
}
const NEVER_SPOILS: PackedStringArray = ["canned_beans", "canned_tuna", "canned_fruit", "dev_water_bottle", "boiled_water", "soda", "juice"]

var _settings: SurvivalSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = SurvivalSettings.new()
	_settings.respawn_delay_sec = NEVER


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var always: ItemDefinition = _definition(ALWAYS_SICK, ALWAYS_SICK_HUNGER, 0.0, 0.0)
	always.consume_sickness_chance = 1.0
	catalog.add(always)
	var half: ItemDefinition = _definition(HALF_SICK, 1.0, 0.0, 0.0)
	half.consume_sickness_chance = 0.5
	catalog.add(half)
	catalog.add(_definition(FATIGUE_ONLY, 0.0, 0.0, FATIGUE_ONLY_AMOUNT))
	return catalog


func _definition(definition_id: String, hunger: float, thirst: float, fatigue: float) -> ItemDefinition:
	var definition: ItemDefinition = ItemDefinition.new()
	definition.definition_id = definition_id
	definition.max_stack = STACK_MAX
	definition.consume_hunger_reduction = hunger
	definition.consume_thirst_reduction = thirst
	definition.consume_fatigue_reduction = fatigue
	return definition


func _world() -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.survival = _settings
	config.catalog = _catalog()
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	return ServerComposition.create_world(WORLD, config)


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, DevWorldSeed.DEV_CELL_ID, player.position)
	var result: ActionResult = world.try_pickup(player.player_id, item_id)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


## Whether each of `count` units of `definition_id` made a fresh player
## sick, in order, as "1" / "0".
func _sickness_sequence(definition_id: String, count: int) -> String:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var item_id: String = _give(world, alice, definition_id, count)
	var sequence: String = ""
	for index: int in range(count):
		var used: ActionResult = ItemConsumption.try_consume(world, alice.player_id, item_id)
		assert_true(used.ok, used.reason)
		sequence += "1" if bool(used.event.get("sick", false)) else "0"
		# Keep the player well so nothing else changes between the rolls.
		var vitals: PlayerVitals = _survival(world).get_vitals(alice.player_id)
		vitals.health = _settings.max_health
		vitals.thirst = 0.0
	return sequence


# ------------------------------------------------------------ definitions

func test_the_settled_food_and_drink_list_is_shipped_and_valid() -> void:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var all_ids: PackedStringArray = FOODS + COOKED + DRINKS
	for definition_id: String in all_ids:
		var definition: ItemDefinition = catalog.get_definition(definition_id)
		assert_not_null(definition, "%s is shipped" % definition_id)
		if definition == null:
			continue
		assert_eq(definition.validate().size(), 0, "%s: %s" % [definition_id, "; ".join(definition.validate())])
		assert_true(definition.is_consumable(), "%s can be eaten or drunk" % definition_id)
		assert_true(definition.lowers_needs(), definition_id)
		assert_false(definition.is_treatment(), "%s is no treatment" % definition_id)
		assert_false(definition.display_name.is_empty(), "%s has a name" % definition_id)
	for definition_id: String in FOODS + COOKED:
		assert_true(catalog.get_definition(definition_id).consume_hunger_reduction > 0.0, "%s lowers hunger" % definition_id)
	for definition_id: String in DRINKS:
		assert_true(catalog.get_definition(definition_id).consume_thirst_reduction > 0.0, "%s lowers thirst" % definition_id)
	assert_eq(catalog.get_definition("dev_water_bottle").display_name, "생수", "the development water bottle is the bottled water")


func test_raw_food_and_dirty_water_risk_sickness_and_cooking_is_better() -> void:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	for definition_id: String in RAW:
		var raw: ItemDefinition = catalog.get_definition(definition_id)
		assert_true(raw.may_sicken(), "%s may make the eater sick" % definition_id)
		var cooked: ItemDefinition = catalog.get_definition(str(RAW_TO_COOKED[definition_id]))
		assert_false(cooked.may_sicken(), "%s is safe" % cooked.definition_id)
		var raw_total: float = raw.consume_hunger_reduction + raw.consume_thirst_reduction + raw.consume_health_restore
		var cooked_total: float = cooked.consume_hunger_reduction + cooked.consume_thirst_reduction + cooked.consume_health_restore
		assert_true(cooked_total > raw_total, "cooking %s makes the effect bigger" % definition_id)
	for definition_id: String in NEVER_SPOILS + COOKED:
		assert_false(catalog.get_definition(definition_id).may_sicken(), "%s is safe" % definition_id)
	# Coffee and the energy drink are what lowers fatigue; the energy drink most.
	var coffee: ItemDefinition = catalog.get_definition("coffee")
	var energy: ItemDefinition = catalog.get_definition("energy_drink")
	assert_true(coffee.consume_fatigue_reduction > 0.0, "coffee lowers fatigue")
	assert_true(energy.consume_fatigue_reduction > coffee.consume_fatigue_reduction)
	for definition_id: String in ["dev_water_bottle", "dirty_water", "raw_meat", "bread"]:
		assert_eq(catalog.get_definition(definition_id).consume_fatigue_reduction, 0.0, definition_id)
	# Cooked food gives a little health back.
	for definition_id: String in COOKED:
		assert_true(catalog.get_definition(definition_id).consume_health_restore > 0.0, "%s heals a little" % definition_id)
	# Alcohol: mood and tremor are data only (F-1 stub).
	var alcohol: ItemDefinition = catalog.get_definition("alcohol")
	assert_true(alcohol.consume_mood_change > 0.0, "alcohol lifts the mood (data only)")
	assert_true(alcohol.consume_causes_hand_tremor, "alcohol shakes the hands (data only)")
	for definition_id: String in FOODS + COOKED + DRINKS:
		if definition_id != "alcohol":
			assert_false(catalog.get_definition(definition_id).consume_causes_hand_tremor, definition_id)


func test_new_effect_fields_are_validated() -> void:
	var good: ItemDefinition = _definition("f1_good", 10.0, 0.0, 5.0)
	good.consume_health_restore = 3.0
	good.consume_sickness_chance = 0.25
	assert_eq(good.validate().size(), 0, "; ".join(good.validate()))
	var negative_fatigue: ItemDefinition = _definition("f1_bad_fatigue", 10.0, 0.0, -1.0)
	assert_true(negative_fatigue.validate().size() > 0)
	var nan_health: ItemDefinition = _definition("f1_bad_health", 10.0, 0.0, 0.0)
	nan_health.consume_health_restore = NAN
	assert_true(nan_health.validate().size() > 0)
	var chance_too_big: ItemDefinition = _definition("f1_bad_chance", 10.0, 0.0, 0.0)
	chance_too_big.consume_sickness_chance = 1.5
	assert_true(chance_too_big.validate().size() > 0)
	var heal_without_food: ItemDefinition = _definition("f1_heal_only", 0.0, 0.0, 0.0)
	heal_without_food.consume_health_restore = 5.0
	assert_true(heal_without_food.validate().size() > 0, "health back is part of eating, not a medicine")
	var tremor_without_food: ItemDefinition = _definition("f1_tremor_only", 0.0, 0.0, 0.0)
	tremor_without_food.consume_causes_hand_tremor = true
	assert_true(tremor_without_food.validate().size() > 0)
	assert_eq(ItemCatalog.new().add(chance_too_big), ERR_INVALID_DATA, "the catalog refuses it")
	var fatigue_only: ItemDefinition = _definition("f1_wake", 0.0, 0.0, 10.0)
	assert_true(fatigue_only.is_consumable() and fatigue_only.lowers_needs(), "fatigue alone is an eating effect")


# ------------------------------------------------------------ effects

func test_coffee_lowers_thirst_and_fatigue() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.thirst = 50.0
	vitals.fatigue = 60.0
	vitals.hunger = 30.0
	var coffee: ItemDefinition = _catalog().get_definition("coffee")
	var item_id: String = _give(world, alice, "coffee", 2)
	var used: ActionResult = ItemConsumption.try_consume(world, alice.player_id, item_id)
	assert_true(used.ok, used.reason)
	assert_true(_near(vitals.fatigue, 60.0 - coffee.consume_fatigue_reduction), "fatigue %f" % vitals.fatigue)
	assert_true(_near(vitals.thirst, 50.0 - coffee.consume_thirst_reduction), "thirst %f" % vitals.thirst)
	assert_eq(vitals.hunger, 30.0, "coffee does not feed")
	assert_true(_near(float(used.event.get("fatigue_reduced", -1.0)), coffee.consume_fatigue_reduction))
	assert_eq(bool(used.event.get("sick", true)), false)
	assert_true(SaveService.is_json_safe(used.event))
	# Fatigue never drops below 0.
	vitals.fatigue = 5.0
	var again: ActionResult = ItemConsumption.try_consume(world, alice.player_id, item_id)
	assert_true(again.ok, again.reason)
	assert_eq(vitals.fatigue, 0.0)
	assert_true(_near(float(again.event.get("fatigue_reduced", -1.0)), 5.0), "only what was there is reported")


func test_an_item_that_only_lowers_fatigue_can_be_used() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.fatigue = 80.0
	var item_id: String = _give(world, alice, FATIGUE_ONLY)
	var used: ActionResult = ItemConsumption.try_consume(world, alice.player_id, item_id)
	assert_true(used.ok, used.reason)
	assert_true(_near(vitals.fatigue, 80.0 - FATIGUE_ONLY_AMOUNT))
	assert_null(world.inventory.get_item(item_id), "the last unit is gone")
	assert_eq(survival.check_consume_food(alice.player_id, 0.0, 0.0, 0.0, 5.0, 0.0), SurvivalService.REASON_BAD_NEED_AMOUNT, "health alone is no food")
	assert_eq(survival.check_consume_food(alice.player_id, 1.0, 0.0, 0.0, 0.0, 2.0), SurvivalService.REASON_BAD_NEED_AMOUNT, "a chance above 1 is refused")
	assert_eq(survival.check_reduce_needs(alice.player_id, 0.0, 0.0), SurvivalService.REASON_BAD_NEED_AMOUNT, "the old entry keeps its rule")


func test_cooked_food_gives_health_back_up_to_the_maximum() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var meat: ItemDefinition = _catalog().get_definition("grilled_meat")
	vitals.hunger = 80.0
	vitals.health = 50.0
	var item_id: String = _give(world, alice, "grilled_meat", 2)
	var used: ActionResult = ItemConsumption.try_consume(world, alice.player_id, item_id)
	assert_true(used.ok, used.reason)
	assert_true(_near(vitals.health, 50.0 + meat.consume_health_restore), "health %f" % vitals.health)
	assert_true(_near(float(used.event.get("health_restored", -1.0)), meat.consume_health_restore))
	assert_true(_near(vitals.hunger, 80.0 - meat.consume_hunger_reduction))
	vitals.health = _settings.max_health - 1.0
	var again: ActionResult = ItemConsumption.try_consume(world, alice.player_id, item_id)
	assert_true(again.ok, again.reason)
	assert_eq(vitals.health, _settings.max_health, "never above the maximum")
	assert_true(_near(float(again.event.get("health_restored", -1.0)), 1.0))


func test_food_sickness_costs_health_and_thirst_but_never_kills() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 50.0
	vitals.thirst = 20.0
	vitals.health = 60.0
	var item_id: String = _give(world, alice, ALWAYS_SICK, 3)
	survival.drain_events()
	var used: ActionResult = ItemConsumption.try_consume(world, alice.player_id, item_id)
	assert_true(used.ok, used.reason)
	assert_true(bool(used.event.get("sick", false)), "chance 1 always makes sick")
	assert_true(_near(vitals.health, 60.0 - _settings.food_sickness_health_loss), "health %f" % vitals.health)
	assert_true(_near(vitals.thirst, 20.0 + _settings.food_sickness_thirst_gain), "thirst %f" % vitals.thirst)
	assert_true(_near(vitals.hunger, 50.0 - ALWAYS_SICK_HUNGER), "the food still fed")
	assert_true(_near(float(used.event.get("sickness_health_lost", -1.0)), _settings.food_sickness_health_loss))
	assert_true(_near(float(used.event.get("sickness_thirst_added", -1.0)), _settings.food_sickness_thirst_gain))
	var reduced: Array[Dictionary] = []
	for event: Dictionary in survival.drain_events():
		if str(event.get("event_type", "")) == SurvivalService.EVENT_PLAYER_NEEDS_REDUCED:
			reduced.append(event)
	assert_eq(reduced.size(), 1, "one survival event")
	assert_true(bool(reduced[0].get("sick", false)))
	# Close to the floor: food never kills.
	vitals.health = _settings.food_sickness_min_health + 1.0
	vitals.thirst = _settings.need_max - 2.0
	var near_floor: ActionResult = ItemConsumption.try_consume(world, alice.player_id, item_id)
	assert_true(near_floor.ok, near_floor.reason)
	assert_eq(vitals.health, _settings.food_sickness_min_health, "health stops at the floor")
	assert_eq(vitals.thirst, _settings.need_max, "thirst stops at the maximum")
	assert_true(survival.is_alive(alice.player_id))
	var at_floor: ActionResult = ItemConsumption.try_consume(world, alice.player_id, item_id)
	assert_true(at_floor.ok, at_floor.reason)
	assert_eq(vitals.health, _settings.food_sickness_min_health)
	assert_eq(float(at_floor.event.get("sickness_health_lost", -1.0)), 0.0)
	assert_true(survival.is_alive(alice.player_id))


func test_food_sickness_is_deterministic_and_safe_food_does_not_roll() -> void:
	var first: String = _sickness_sequence(HALF_SICK, 24)
	var second: String = _sickness_sequence(HALF_SICK, 24)
	assert_eq(first, second, "same world seed and player: the same sicknesses")
	assert_true(first.contains("1") and first.contains("0"), "a 50%% chance both happens and does not: %s" % first)
	# Food without a sickness chance leaves the saved RNG alone, so adding
	# food does not shift the infection rolls.
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = _survival(world).get_vitals(alice.player_id)
	vitals.hunger = 90.0
	var state_before: int = vitals.rng.state
	var bread_id: String = _give(world, alice, "bread", 2)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, bread_id).ok)
	assert_eq(vitals.rng.state, state_before, "no roll for safe food")
	var meat_id: String = _give(world, alice, "raw_meat")
	assert_true(ItemConsumption.try_consume(world, alice.player_id, meat_id).ok)
	assert_ne(vitals.rng.state, state_before, "raw meat rolls")


func test_mood_and_tremor_are_not_applied() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.thirst = 50.0
	var handling_before: float = survival.handling_multiplier(alice.player_id)
	var item_id: String = _give(world, alice, "alcohol")
	var used: ActionResult = ItemConsumption.try_consume(world, alice.player_id, item_id)
	assert_true(used.ok, used.reason)
	assert_eq(survival.handling_multiplier(alice.player_id), handling_before, "no tremor rule yet (F-1 stub)")
	assert_false(used.event.has("mood_change"), "no mood rule yet (F-1 stub)")


# ------------------------------------------------------------ loot

func test_the_new_items_are_in_the_loot_tables_with_sensible_rarity() -> void:
	var items: ItemCatalog = ItemCatalog.load_directory()
	var tables: LootTableCatalog = LootTableCatalog.load_directory()
	assert_eq(tables.validate_against(items).size(), 0, "; ".join(tables.validate_against(items)))
	var weight_in: Dictionary = {}
	for table_id: String in tables.table_ids():
		var table: LootTable = tables.get_table(table_id)
		assert_eq(table.validate().size(), 0, "; ".join(table.validate()))
		var weights: Dictionary = {}
		for index: int in range(table.entry_count()):
			weights[table.item_definition_ids[index]] = table.weights[index]
		weight_in[table_id] = weights
	# Every raw / ready item of the list can be found (cooked results come
	# from cooking, F-8; boiled water too).
	for definition_id: String in FOODS + DRINKS:
		if definition_id == "boiled_water":
			continue
		var found: bool = false
		for table_id: String in weight_in:
			found = found or (weight_in[table_id] as Dictionary).has(definition_id)
		assert_true(found, "%s is in some loot table" % definition_id)
	for definition_id: String in COOKED + PackedStringArray(["boiled_water"]):
		for table_id: String in weight_in:
			assert_false((weight_in[table_id] as Dictionary).has(definition_id), "%s is cooked, not looted (%s)" % [definition_id, table_id])
	# Shops sell drinks and snacks; energy drinks and alcohol are rare there.
	var store: Dictionary = weight_in["dev_store"]
	for common: String in ["soda", "snack_chips", "canned_beans"]:
		for rare: String in ["energy_drink", "alcohol"]:
			assert_true(float(store[common]) > float(store[rare]), "%s is rarer than %s in a store" % [rare, common])
	assert_false(store.has("dirty_water") or store.has("raw_meat"), "a store sells nothing raw")
	# A house: fresh meat is rarer than canned food.
	var house: Dictionary = weight_in["dev_house"]
	assert_true(float(house["raw_meat"]) < float(house["canned_beans"]))
	assert_false(house.has("energy_drink"))


func test_a_house_search_finds_varied_food_deterministically() -> void:
	var tables: LootTableCatalog = LootTableCatalog.load_directory()
	var house: LootTable = tables.get_table("dev_house")
	var kinds: Dictionary = {}
	for index: int in range(200):
		var roll_seed: int = LootRoller.seed_for(12345, "container_%06d" % index)
		var stacks: Array[Dictionary] = LootRoller.roll(house, roll_seed)
		assert_eq(str(LootRoller.roll(house, roll_seed)), str(stacks), "the same seed gives the same stacks")
		for stack: Dictionary in stacks:
			kinds[str(stack["definition_id"])] = true
	assert_true(kinds.size() >= 12, "200 houses hold many kinds of food and drink: %s" % str(kinds.keys()))
