extends TestCase
## P2-T6 (user decision 2026-11-15): a bandage stops bleeding, on the server,
## no network. SurvivalService.stop_worst_bleeding picks the worst bleeding
## wounds; ItemConsumption uses up one unit of a carried bandage and stops
## the bleeding as one all-or-nothing rule. A bandage is refused (and kept)
## when nothing bleeds. Also: the shipped bandage definition, the
## development seed and the save round trip.

const WORLD: String = "bandage_test_world"
const NEVER: float = 1.0e9
const EPSILON: float = 0.000001
const BANDAGE: String = "t6_bandage"
const BIG_BANDAGE: String = "t6_big_bandage"
const FOOD: String = "t6_food"
const SOUP_BANDAGE: String = "t6_soup_bandage"
const PLAIN: String = "t6_plain"
const FOOD_HUNGER: float = 30.0
const BIG_BANDAGE_WOUNDS: int = 2
const STACK_MAX: int = 5
const LETHAL_DAMAGE: float = 100000.0
## Damage amounts (severity = amount / 50): all of them bleed with the
## default settings (threshold 0.25).
const LACERATION_DAMAGE: float = 20.0
const BITE_DAMAGE: float = 15.0
const SCRATCH_DAMAGE: float = 25.0
const BRUISE_DAMAGE: float = 10.0
const STEP_SEC: float = 600.0

var _settings: SurvivalSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = ""
	_settings = SurvivalSettings.new()
	_settings.respawn_delay_sec = NEVER
	# Only bleeding moves health in these tests.
	_settings.health_recovery_per_world_sec = 0.0
	_settings.wound_recovery_per_world_sec = 0.0


func after_each() -> void:
	if not _root.is_empty():
		SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.new()
	catalog.add(_definition(BANDAGE, 1, 0.0))
	catalog.add(_definition(BIG_BANDAGE, BIG_BANDAGE_WOUNDS, 0.0))
	catalog.add(_definition(FOOD, 0, FOOD_HUNGER))
	catalog.add(_definition(SOUP_BANDAGE, 1, FOOD_HUNGER))
	catalog.add(_definition(PLAIN, 0, 0.0))
	return catalog


func _definition(definition_id: String, bleeding_wounds: int, hunger: float) -> ItemDefinition:
	var definition: ItemDefinition = ItemDefinition.new()
	definition.definition_id = definition_id
	definition.max_stack = STACK_MAX
	definition.treat_bleeding_wound_count = bleeding_wounds
	definition.consume_hunger_reduction = hunger
	return definition


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.survival = _settings
	config.catalog = _catalog()
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	# Calendar rules are stated in world seconds here (1x clock).
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = 1.0
	return config


func _world() -> ServerWorld:
	return ServerComposition.create_world(WORLD, _config())


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, DevWorldSeed.DEV_CELL_ID, player.position)
	var result: ActionResult = world.try_pickup(player.player_id, item_id)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


## Wounds the player and returns the wound id.
func _wound(survival: SurvivalService, player_id: String, type: Wound.Type, amount: float, part: BodyPart.Part = BodyPart.Part.TORSO) -> String:
	var hit: ActionResult = survival.apply_damage(player_id, DamageInput.create("zombie_000001", part, type, amount))
	if not hit.ok:
		fail("test setup: damage failed: " + hit.reason)
		return ""
	return str((hit.event["wound"] as Dictionary)["wound_id"])


func _wound_of(vitals: PlayerVitals, wound_id: String) -> Wound:
	for wound: Wound in vitals.injuries:
		if wound.wound_id == wound_id:
			return wound
	return null


func _events_of(events: Array[Dictionary], event_type: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == event_type:
			matching.append(event)
	return matching


func _transactions_of(world: ServerWorld) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void: events.append(event))
	return events


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


# ------------------------------------------------------------ SurvivalService.stop_worst_bleeding

func test_bleeding_wounds_are_ordered_worst_first() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	# Health loss per second: scratch 0.5 x 0.25, laceration 0.4 x 1.0, bite 0.3 x 0.75.
	var scratch_id: String = _wound(survival, alice.player_id, Wound.Type.SCRATCH, SCRATCH_DAMAGE)
	var bruise_id: String = _wound(survival, alice.player_id, Wound.Type.BRUISE, BRUISE_DAMAGE)
	var laceration_id: String = _wound(survival, alice.player_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	var bite_id: String = _wound(survival, alice.player_id, Wound.Type.BITE, BITE_DAMAGE)
	assert_eq(Array(survival.bleeding_wound_ids(alice.player_id)), [laceration_id, bite_id, scratch_id], "fastest health loss first; a bruise does not bleed")
	assert_false(survival.bleeding_wound_ids(alice.player_id).has(bruise_id))
	assert_eq(survival.bleeding_wound_ids("player_999999").size(), 0, "nothing for an unknown player")
	# Equal wounds: the older one first.
	var bob: PlayerState = world.join("bob")
	var first: String = _wound(survival, bob.player_id, Wound.Type.BITE, BITE_DAMAGE, BodyPart.Part.LEFT_ARM)
	var second: String = _wound(survival, bob.player_id, Wound.Type.BITE, BITE_DAMAGE, BodyPart.Part.RIGHT_ARM)
	assert_eq(Array(survival.bleeding_wound_ids(bob.player_id)), [first, second])


func test_stop_worst_bleeding_stops_the_worst_wounds_and_reports_each() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var scratch_id: String = _wound(survival, alice.player_id, Wound.Type.SCRATCH, SCRATCH_DAMAGE)
	var laceration_id: String = _wound(survival, alice.player_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	var bite_id: String = _wound(survival, alice.player_id, Wound.Type.BITE, BITE_DAMAGE)
	survival.drain_events()
	assert_eq(survival.check_stop_worst_bleeding(alice.player_id, 1), "", "the preflight accepts a usable request")
	assert_true(_wound_of(vitals, laceration_id).is_bleeding, "the preflight changes nothing")

	var one: ActionResult = survival.stop_worst_bleeding(alice.player_id, 1, "item_000001")
	assert_true(one.ok, one.reason)
	assert_false(_wound_of(vitals, laceration_id).is_bleeding, "the worst wound was treated")
	assert_true(_wound_of(vitals, bite_id).is_bleeding, "one unit of work, one wound")
	assert_true(_wound_of(vitals, scratch_id).is_bleeding)
	assert_eq(one.event.get("event_type", ""), SurvivalService.EVENT_PLAYER_BLEEDING_TREATED)
	assert_eq(one.event.get("player_id", ""), alice.player_id)
	assert_eq(one.event.get("source_id", ""), "item_000001")
	assert_eq(one.event.get("wound_ids", []), [laceration_id])
	assert_eq(one.event.get("remaining_bleeding_wounds", -1), 2)
	assert_eq(one.event.get("world_time", -1.0), world.clock.world_time_sec, "calendar time stamp")
	assert_true(SaveService.is_json_safe(one.event), "event is JSON-safe")
	# The wound itself stays: type and severity are unchanged (docs/02 §2.2).
	assert_eq(_wound_of(vitals, laceration_id).wound_type, Wound.Type.LACERATION)
	assert_true(_near(_wound_of(vitals, laceration_id).severity, LACERATION_DAMAGE / _settings.wound_severity_reference_damage))
	# Each stopped wound is queued as the existing owner-replicated event.
	var stopped: Array[Dictionary] = _events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_BLEEDING_STOPPED)
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0].get("wound_id", ""), laceration_id)

	# More capacity than bleeding wounds: everything left is treated.
	var rest: ActionResult = survival.stop_worst_bleeding(alice.player_id, 5, "item_000002")
	assert_true(rest.ok, rest.reason)
	assert_eq(rest.event.get("wound_ids", []), [bite_id, scratch_id], "worst first")
	assert_eq(rest.event.get("remaining_bleeding_wounds", -1), 0)
	assert_eq(survival.bleeding_wound_ids(alice.player_id).size(), 0)
	assert_eq(_events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_BLEEDING_STOPPED).size(), 2)
	assert_eq(vitals.injuries.size(), 3, "no wound was removed")


func test_stop_worst_bleeding_rejects_when_nothing_bleeds_dead_unknown_and_bad_counts() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	_wound(survival, alice.player_id, Wound.Type.BRUISE, BRUISE_DAMAGE)
	survival.drain_events()
	var before: Dictionary = vitals.to_dict()
	assert_eq(survival.check_stop_worst_bleeding(alice.player_id, 1), SurvivalService.REASON_NOT_BLEEDING)
	var dry: ActionResult = survival.stop_worst_bleeding(alice.player_id, 1, "item_000001")
	assert_false(dry.ok)
	assert_eq(dry.reason, SurvivalService.REASON_NOT_BLEEDING, "a wound that does not bleed needs no bandage")
	assert_eq(survival.stop_worst_bleeding("player_999999", 1, "item_000001").reason, SurvivalService.REASON_UNKNOWN_PLAYER)
	_wound(survival, alice.player_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	survival.drain_events()
	before = vitals.to_dict()
	for bad: int in [0, -1]:
		assert_eq(survival.check_stop_worst_bleeding(alice.player_id, bad), SurvivalService.REASON_BAD_WOUND_COUNT, str(bad))
		assert_eq(survival.stop_worst_bleeding(alice.player_id, bad, "item_000001").reason, SurvivalService.REASON_BAD_WOUND_COUNT, str(bad))
	assert_eq(vitals.to_dict(), before, "a refused request changes nothing")
	assert_eq(survival.drain_events().size(), 0, "a refused request reports nothing")
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.LACERATION, LETHAL_DAMAGE)).ok)
	survival.drain_events()
	assert_eq(survival.check_stop_worst_bleeding(alice.player_id, 1), SurvivalService.REASON_PLAYER_DEAD)
	var dead: ActionResult = survival.stop_worst_bleeding(alice.player_id, 1, "item_000001")
	assert_false(dead.ok)
	assert_eq(dead.reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(survival.drain_events().size(), 0)


# ------------------------------------------------------------ ItemConsumption with a bandage

func test_a_bandage_stops_the_worst_bleeding_and_the_bleeding_damage() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var bite_id: String = _wound(survival, alice.player_id, Wound.Type.BITE, BITE_DAMAGE)
	var bandage_id: String = _give(world, alice, BANDAGE, 2)
	# Bleeding costs health while it lasts.
	var before_bleeding: float = vitals.health
	world.step_systems(STEP_SEC)
	var bled: float = before_bleeding - vitals.health
	var expected: float = _settings.bleeding_health_loss_per_severity_per_world_sec * _settings.bleeding_type_multiplier(Wound.Type.BITE) * (BITE_DAMAGE / _settings.wound_severity_reference_damage) * STEP_SEC
	assert_true(absf(bled - expected) <= 0.001, "bleeding took %f health (expected %f)" % [bled, expected])
	survival.drain_events()
	var transactions: Array[Dictionary] = _transactions_of(world)

	var used: ActionResult = ItemConsumption.try_consume(world, alice.player_id, bandage_id)
	assert_true(used.ok, used.reason)
	assert_false(_wound_of(vitals, bite_id).is_bleeding, "the wound no longer bleeds")
	assert_eq(world.inventory.get_item(bandage_id).quantity, 1, "one bandage left the stack")
	assert_eq(used.event.get("event_type", ""), ItemConsumption.EVENT_ITEM_CONSUMED)
	assert_eq(used.event.get("definition_id", ""), BANDAGE)
	assert_eq(used.event.get("remaining_quantity", -1), 1)
	assert_eq(used.event.get("bleeding_stopped_wound_ids", []), [bite_id])
	assert_eq(float(used.event.get("hunger_reduced", -1.0)), 0.0, "a bandage feeds nobody")
	assert_true(SaveService.is_json_safe(used.event))
	assert_eq(transactions.size(), 1, "exactly one inventory transaction per use")
	assert_eq(transactions[0].get("event_type", ""), InventoryService.EVENT_ITEM_REMOVED)
	assert_eq(transactions[0].get("removed_quantity", 0), ItemConsumption.CONSUMED_QUANTITY)
	var events: Array[Dictionary] = survival.drain_events()
	assert_eq(_events_of(events, SurvivalService.EVENT_PLAYER_BLEEDING_STOPPED).size(), 1, "exactly one wound was reported as stopped")

	# No more bleeding damage from now on.
	var after_bandage: float = vitals.health
	world.step_systems(STEP_SEC)
	assert_eq(vitals.health, after_bandage, "health no longer drops")
	assert_eq(_events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_SURVIVAL_DAMAGE).size(), 0, "no bleeding damage is reported")


func test_one_bandage_treats_as_many_wounds_as_its_definition_says() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var scratch_id: String = _wound(survival, alice.player_id, Wound.Type.SCRATCH, SCRATCH_DAMAGE)
	var laceration_id: String = _wound(survival, alice.player_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	var bite_id: String = _wound(survival, alice.player_id, Wound.Type.BITE, BITE_DAMAGE)
	var small_id: String = _give(world, alice, BANDAGE, 1)
	var big_id: String = _give(world, alice, BIG_BANDAGE, 1)
	# The plain bandage: the worst wound only; its last unit removes the item.
	var first: ActionResult = ItemConsumption.try_consume(world, alice.player_id, small_id)
	assert_true(first.ok, first.reason)
	assert_eq(first.event.get("bleeding_stopped_wound_ids", []), [laceration_id])
	assert_eq(first.event.get("remaining_quantity", -1), 0)
	assert_null(world.inventory.get_item(small_id))
	assert_true(world.registry.is_tombstoned(small_id))
	assert_eq(Array(survival.bleeding_wound_ids(alice.player_id)), [bite_id, scratch_id])
	# The larger dressing: two wounds with one unit.
	var second: ActionResult = ItemConsumption.try_consume(world, alice.player_id, big_id)
	assert_true(second.ok, second.reason)
	assert_eq(second.event.get("bleeding_stopped_wound_ids", []), [bite_id, scratch_id])
	assert_eq(survival.bleeding_wound_ids(alice.player_id).size(), 0)
	assert_eq(vitals.injuries.size(), 3)
	assert_eq(world.inventory.items_in_inventory(alice.inventory_id).size(), 0)


func test_a_bandage_is_refused_and_kept_when_nothing_bleeds() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	# Alice has a wound that does not bleed; bob bleeds and has no bandage.
	_wound(survival, alice.player_id, Wound.Type.BRUISE, BRUISE_DAMAGE)
	var bobs_wound: String = _wound(survival, bob.player_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	var bandage_id: String = _give(world, alice, BANDAGE, 3)
	var plain_id: String = _give(world, alice, PLAIN)
	var bobs_bandage: String = world.inventory.spawn_world_item(BANDAGE, 1, DevWorldSeed.DEV_CELL_ID, alice.position)
	var transactions: Array[Dictionary] = _transactions_of(world)
	survival.drain_events()
	var before_items: Dictionary = world.inventory.to_snapshot()
	var before_alice: Dictionary = vitals.to_dict()
	var before_bob: Dictionary = survival.get_vitals(bob.player_id).to_dict()

	var refused: ActionResult = ItemConsumption.try_consume(world, alice.player_id, bandage_id)
	assert_false(refused.ok)
	assert_eq(refused.reason, SurvivalService.REASON_NOT_BLEEDING, "nothing to treat: the bandage is not wasted")
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, plain_id).reason, ItemConsumption.REASON_NOT_CONSUMABLE)
	assert_eq(ItemConsumption.try_consume(world, bob.player_id, bandage_id).reason, InventoryService.REASON_NOT_IN_INVENTORY, "bob cannot use alice's bandage")
	assert_eq(ItemConsumption.try_consume(world, bob.player_id, bobs_bandage).reason, InventoryService.REASON_NOT_IN_INVENTORY, "a bandage lying in the world")
	assert_eq(ItemConsumption.try_consume(world, bob.player_id, "item_999999").reason, InventoryService.REASON_UNKNOWN_ITEM)
	world.leave(bob.player_id)
	assert_eq(ItemConsumption.try_consume(world, bob.player_id, bandage_id).reason, ServerWorld.REASON_NOT_ONLINE)

	assert_eq(world.inventory.to_snapshot(), before_items, "no item changed")
	assert_eq(world.inventory.get_item(bandage_id).quantity, 3, "the stack is whole")
	assert_eq(vitals.to_dict(), before_alice, "alice's wounds are unchanged")
	assert_eq(survival.get_vitals(bob.player_id).to_dict(), before_bob, "bob still bleeds")
	assert_true(_wound_of(survival.get_vitals(bob.player_id), bobs_wound).is_bleeding)
	assert_eq(transactions.size(), 0, "no inventory transaction was committed")
	assert_eq(survival.drain_events().size(), 0, "no survival event was queued")


func test_a_dead_player_cannot_use_a_bandage() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var wound_id: String = _wound(survival, alice.player_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	var bandage_id: String = _give(world, alice, BANDAGE, 2)
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_false(survival.is_alive(alice.player_id))
	survival.drain_events()
	var transactions: Array[Dictionary] = _transactions_of(world)
	# Since P2-T4 the death put the bandages down where she died.
	var after_death: Dictionary = world.inventory.to_snapshot()
	var dead: ActionResult = ItemConsumption.try_consume(world, alice.player_id, bandage_id)
	assert_false(dead.ok)
	assert_eq(dead.reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(world.inventory.to_snapshot(), after_death, "a dead player's bandage is not used up")
	assert_eq(world.inventory.get_item(bandage_id).quantity, 2)
	assert_true(_wound_of(vitals, wound_id).is_bleeding, "the dead character's wound is not treated")
	assert_eq(transactions.size(), 0)
	assert_eq(survival.drain_events().size(), 0)


func test_an_item_with_food_and_bandage_effects_applies_what_applies() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 70.0
	var soup_id: String = _give(world, alice, SOUP_BANDAGE, 2)
	# Not bleeding: it is still food (the eating rule has no precondition).
	var eaten: ActionResult = ItemConsumption.try_consume(world, alice.player_id, soup_id)
	assert_true(eaten.ok, eaten.reason)
	assert_true(_near(vitals.hunger, 70.0 - FOOD_HUNGER))
	assert_eq(eaten.event.get("bleeding_stopped_wound_ids", []), [])
	# Bleeding: both effects with one unit.
	var wound_id: String = _wound(survival, alice.player_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	var both: ActionResult = ItemConsumption.try_consume(world, alice.player_id, soup_id)
	assert_true(both.ok, both.reason)
	assert_true(_near(vitals.hunger, 70.0 - 2.0 * FOOD_HUNGER))
	assert_eq(both.event.get("bleeding_stopped_wound_ids", []), [wound_id])
	assert_false(_wound_of(vitals, wound_id).is_bleeding)
	assert_null(world.inventory.get_item(soup_id))
	# Plain food is unaffected by the new effect: eaten while bleeding or not.
	var food_id: String = _give(world, alice, FOOD)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, food_id).ok)


# ------------------------------------------------------------ data

func test_item_definitions_carry_the_bandage_effect() -> void:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var bandage: ItemDefinition = catalog.get_definition("dev_bandage")
	assert_not_null(bandage, "the development bandage is shipped")
	if bandage == null:
		return
	assert_true(bandage.stops_bleeding())
	assert_true(bandage.treat_bleeding_wound_count >= 1)
	assert_true(bandage.is_consumable(), "a bandage can be used up")
	assert_false(bandage.lowers_needs(), "a bandage is not food")
	assert_eq(bandage.validate().size(), 0, "; ".join(bandage.validate()))
	assert_true(bandage.max_stack >= 1)
	# Existing items: food and water are still consumable and stop no bleeding.
	for definition_id: String in ["dev_food_ration", "dev_water_bottle"]:
		assert_true(catalog.get_definition(definition_id).is_consumable(), definition_id)
		assert_true(catalog.get_definition(definition_id).lowers_needs(), definition_id)
		assert_false(catalog.get_definition(definition_id).stops_bleeding(), definition_id)
	assert_false(catalog.get_definition("dev_melee_pipe").is_consumable())
	assert_false(ItemDefinition.new().stops_bleeding(), "no effect unless the data says so")
	var negative: ItemDefinition = _definition("t6_bad", -1, 0.0)
	assert_true(negative.validate().size() > 0, "a negative wound count is invalid data")
	assert_eq(ItemCatalog.new().add(negative), ERR_INVALID_DATA, "the catalog refuses it")


func test_the_default_new_world_has_bandages() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var no_zombies: ZombieSettings = ZombieSettings.new()
	no_zombies.dev_spawn_count = 0
	config.zombie = no_zombies
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	assert_eq(world.seed_new_world(config.dev_seed), OK)
	var bandages: int = 0
	var spawn: Vector3 = config.gameplay.player_spawn_position
	for item_id: String in world.inventory.world_item_ids():
		var item: ItemInstance = world.inventory.get_item(item_id)
		if item.definition_id != "dev_bandage":
			continue
		bandages += item.quantity
		assert_true(world.inventory.world_position_of(item_id).distance_to(spawn) <= 10.0, "the bandages lie near the spawn point")
	assert_true(bandages >= 2, "bandages in a new world: %d" % bandages)


# ------------------------------------------------------------ save round trip

func test_a_used_bandage_and_the_stopped_bleeding_survive_a_save_round_trip() -> void:
	_root = "user://test_saves/bandage_%d" % Time.get_ticks_usec()
	var config: CompositionConfig = _config()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), config)
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	if world == null:
		return
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var treated_id: String = _wound(survival, alice.player_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	var untreated_id: String = _wound(survival, alice.player_id, Wound.Type.BITE, BITE_DAMAGE)
	var bandage_id: String = _give(world, alice, BANDAGE, 3)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, bandage_id).ok)
	assert_eq(persistence.save(world), OK)

	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), config).load_or_create(WORLD)
	assert_not_null(restored, "world restored from save")
	if restored == null:
		return
	var restored_survival: SurvivalService = _survival(restored)
	var restored_vitals: PlayerVitals = restored_survival.get_vitals(alice.player_id)
	assert_eq(restored_vitals.injuries.size(), 2)
	assert_false(_wound_of(restored_vitals, treated_id).is_bleeding, "the treated wound stays treated")
	assert_true(_wound_of(restored_vitals, untreated_id).is_bleeding, "the other wound still bleeds")
	assert_eq(restored.inventory.get_item(bandage_id).quantity, 2, "the smaller stack was saved")
	# The restored world keeps treating from the same stack.
	restored.join("alice")
	var again: ActionResult = ItemConsumption.try_consume(restored, alice.player_id, bandage_id)
	assert_true(again.ok, again.reason)
	assert_eq(again.event.get("bleeding_stopped_wound_ids", []), [untreated_id])
	assert_eq(restored_survival.bleeding_wound_ids(alice.player_id).size(), 0)
	assert_eq(restored.inventory.get_item(bandage_id).quantity, 1)
	assert_eq(ItemConsumption.try_consume(restored, alice.player_id, bandage_id).reason, SurvivalService.REASON_NOT_BLEEDING, "nothing left to treat")
