extends TestCase
## P2-T12 (user decision 2026-11-15, docs/00 ADR-018, docs/09 §14.27): a
## bandage or a cure can be used on another player who is close by.
## ItemConsumption.try_use_on: the user names an item it carries and a target
## player; everything else (who is where, who is alive, what the target
## needs) is decided from server state. Either the unit leaves the user's
## inventory and the target is treated, or nothing changes. Server rules
## only, no network.

const WORLD: String = "treat_other_test_world"
const NEVER: float = 1.0e9
const EPSILON: float = 0.001
const LETHAL_DAMAGE: float = 100000.0
const BANDAGE: String = "t12_bandage"
const CURE: String = "t12_cure"
const FOOD: String = "t12_food"
const KIT: String = "t12_kit"
const PLAIN: String = "t12_plain"
const STACK_MAX: int = 5
const ZOMBIE: String = "zombie_000001"
const MISSING_ITEM_ID: String = "item_999999"
const MISSING_PLAYER_ID: String = "player_999999"

var _settings: SurvivalSettings = null
var _gameplay: GameplaySettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = SurvivalSettings.new()
	_settings.respawn_delay_sec = NEVER
	_settings.health_recovery_per_world_sec = 0.0
	_settings.wound_recovery_per_world_sec = 0.0
	_settings.infection_chance_bite = 1.0
	_gameplay = GameplaySettings.new()


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _definition(definition_id: String, bleeding_wounds: int, cures: bool, hunger: float) -> ItemDefinition:
	var definition: ItemDefinition = ItemDefinition.new()
	definition.definition_id = definition_id
	definition.max_stack = STACK_MAX
	definition.treat_bleeding_wound_count = bleeding_wounds
	definition.cures_infection = cures
	definition.consume_hunger_reduction = hunger
	return definition


func _catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	catalog.add(_definition(BANDAGE, 1, false, 0.0))
	catalog.add(_definition(CURE, 0, true, 0.0))
	catalog.add(_definition(FOOD, 0, false, 30.0))
	catalog.add(_definition(KIT, 1, true, 0.0))
	catalog.add(_definition(PLAIN, 0, false, 0.0))
	return catalog


func _world(require_creation: bool = false) -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.gameplay = _gameplay
	config.survival = _settings
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = 1.0
	config.catalog = _catalog()
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.require_character_creation = require_creation
	return ServerComposition.create_world(WORLD, config)


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, DevWorldSeed.DEV_CELL_ID, player.position)
	var result: ActionResult = world.try_pickup(player.player_id, item_id)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


## Wounds `player` with a bleeding laceration and returns the wound id.
func _wound(world: ServerWorld, player: PlayerState, amount: float = 20.0) -> String:
	var hit: ActionResult = _survival(world).apply_damage(player.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.LACERATION, amount))
	if not hit.ok:
		fail("test setup: damage failed: " + hit.reason)
		return ""
	return str((hit.event["wound"] as Dictionary)["wound_id"])


func _infect(world: ServerWorld, player: PlayerState, stage: InfectionState.Stage = InfectionState.Stage.LATENT) -> void:
	var result: ActionResult = _survival(world).apply_infection_exposure(player.player_id, InfectionState.Exposure.BITE, ZOMBIE)
	if not result.ok or str(result.event.get("event_type", "")) != SurvivalService.EVENT_PLAYER_INFECTED:
		fail("test setup: infection failed")
	_survival(world).get_vitals(player.player_id).infection.stage = stage


func _last_treatable_stage() -> InfectionState.Stage:
	return _settings.infection_treatment_max_stage as InfectionState.Stage


func _first_untreatable_stage() -> InfectionState.Stage:
	return (int(_last_treatable_stage()) + 1) as InfectionState.Stage


func _bleeding_count(world: ServerWorld, player: PlayerState) -> int:
	return _survival(world).bleeding_wound_ids(player.player_id).size()


func _quantity(world: ServerWorld, item_id: String) -> int:
	var item: ItemInstance = world.inventory.get_item(item_id)
	return 0 if item == null else item.quantity


## Everything a refused request must leave alone.
func _state(world: ServerWorld, players: Array) -> Dictionary:
	var fragments: Dictionary = {}
	for player: PlayerState in players:
		fragments[player.player_id] = _survival(world).to_player_fragment(player.player_id)
	return {"inventory": world.inventory.to_snapshot(), "survival": fragments}


func _transactions_of(world: ServerWorld) -> Array[Dictionary]:
	var transactions: Array[Dictionary] = []
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void: transactions.append(event))
	return transactions


## Asserts that the request is refused with `reason` and changed nothing.
func _assert_refused(world: ServerWorld, players: Array, user: PlayerState, item_id: String, target_id: String, reason: String, label: String) -> void:
	var before: Dictionary = _state(world, players)
	_survival(world).drain_events()
	var transactions: Array[Dictionary] = _transactions_of(world)
	var result: ActionResult = ItemConsumption.try_use_on(world, user.player_id, item_id, target_id)
	assert_false(result.ok, label)
	assert_eq(result.reason, reason, label)
	assert_eq(_state(world, players), before, label + ": nothing changed")
	assert_eq(transactions.size(), 0, label + ": no inventory transaction")
	assert_eq(_survival(world).drain_events().size(), 0, label + ": no survival event")


# ------------------------------------------------------------ data

func test_shipped_settings_and_item_kinds() -> void:
	var shipped: GameplaySettings = GameplaySettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_true(shipped.treat_range_m > 0.0, "a treatment needs the other player close by")
	assert_true(shipped.allow_feeding_others, "food and drink can be given to others by default (P2-T13, ADR-019)")
	assert_true(GameplaySettings.new().allow_feeding_others, "the script default agrees with the shipped resource")
	for bad: float in [0.0, -1.0, NAN, INF]:
		var broken: GameplaySettings = GameplaySettings.new()
		broken.treat_range_m = bad
		assert_eq(broken.validate().size(), 1, "treat range %s: %s" % [str(bad), "; ".join(broken.validate())])
	var catalog: ItemCatalog = _catalog()
	assert_true(catalog.get_definition(BANDAGE).is_treatment())
	assert_true(catalog.get_definition(CURE).is_treatment())
	assert_true(catalog.get_definition(KIT).is_treatment())
	assert_false(catalog.get_definition(FOOD).is_treatment(), "food is no treatment")
	assert_false(catalog.get_definition(PLAIN).is_treatment())
	assert_true(ItemCatalog.load_directory().get_definition("dev_bandage").is_treatment())
	assert_true(ItemCatalog.load_directory().get_definition("dev_cure").is_treatment())
	assert_false(ItemCatalog.load_directory().get_definition("dev_water_bottle").is_treatment())
	# Which refusals say something about the target's condition.
	for reason: String in [SurvivalService.REASON_NOT_BLEEDING, SurvivalService.REASON_NOT_INFECTED, SurvivalService.REASON_TOO_LATE]:
		assert_true(ItemConsumption.is_target_state_refusal(reason), reason)
	for reason: String in ["", ItemConsumption.REASON_TARGET_DEAD, ItemConsumption.REASON_TARGET_TOO_FAR, ItemConsumption.REASON_TARGET_UNAVAILABLE, ItemConsumption.REASON_NOT_USABLE_ON_OTHERS, InventoryService.REASON_NOT_IN_INVENTORY, SurvivalService.REASON_PLAYER_DEAD]:
		assert_false(ItemConsumption.is_target_state_refusal(reason), reason)


# ------------------------------------------------------------ bandage

func test_a_bandage_stops_the_other_players_worst_bleeding() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var bandages: String = _give(world, alice, BANDAGE, 3)
	var light: String = _wound(world, bob, 15.0)
	var heavy: String = _wound(world, bob, 40.0)
	# Alice bleeds too: her bandage on bob must not touch her own wound.
	var alices_wound: String = _wound(world, alice, 30.0)
	survival.drain_events()
	var transactions: Array[Dictionary] = _transactions_of(world)

	var result: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, bandages, bob.player_id)
	assert_true(result.ok, result.reason)
	assert_eq(survival.bleeding_wound_ids(bob.player_id), PackedStringArray([light]), "bob's worst wound stopped bleeding")
	assert_eq(survival.bleeding_wound_ids(alice.player_id), PackedStringArray([alices_wound]), "alice's own wound still bleeds")
	assert_eq(_quantity(world, bandages), 2, "one unit left alice's stack")
	assert_eq(world.inventory.get_item(bandages).location_id, alice.inventory_id, "the rest is still alice's")
	assert_eq(transactions.size(), 1, "one inventory transaction")
	assert_eq(transactions[0].get("event_type", ""), InventoryService.EVENT_ITEM_REMOVED)
	assert_eq(transactions[0].get("inventory_id", ""), alice.inventory_id)
	# The result event.
	assert_eq(result.event.get("event_type", ""), ItemConsumption.EVENT_ITEM_USED_ON_PLAYER)
	assert_eq(result.event.get("player_id", ""), alice.player_id, "who used the item")
	assert_eq(result.event.get("target_id", ""), bob.player_id, "on whom")
	assert_eq(result.event.get("item_instance_id", ""), bandages)
	assert_eq(result.event.get("definition_id", ""), BANDAGE)
	assert_eq(result.event.get("remaining_quantity", -1), 2)
	assert_eq(result.event.get("bleeding_stopped_wound_ids", []), [heavy])
	assert_eq(result.event.get("infection_cured_from", "x"), ItemConsumption.NOT_CURED)
	assert_true(SaveService.is_json_safe(result.event))
	# The survival events are about bob (his owner events), not about alice.
	var events: Array[Dictionary] = survival.drain_events()
	assert_eq(events.size(), 1, str(events))
	assert_eq(events[0].get("event_type", ""), SurvivalService.EVENT_PLAYER_BLEEDING_STOPPED)
	assert_eq(events[0].get("player_id", ""), bob.player_id)
	assert_eq(events[0].get("wound_id", ""), heavy)
	# Once more: the other wound. Then nothing bleeds and the bandage is kept.
	assert_true(ItemConsumption.try_use_on(world, alice.player_id, bandages, bob.player_id).ok)
	assert_eq(_bleeding_count(world, bob), 0)
	_assert_refused(world, [alice, bob], alice, bandages, bob.player_id, SurvivalService.REASON_NOT_BLEEDING, "nothing bleeds on bob")
	assert_eq(_quantity(world, bandages), 1, "a treatment is never wasted")
	assert_eq(_bleeding_count(world, alice), 1, "alice bleeds on: the request was about bob")


# ------------------------------------------------------------ cure

func test_a_cure_clears_the_other_players_treatable_infection() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var cures: String = _give(world, alice, CURE, 3)
	# A healthy target: refused, the cure is kept.
	_assert_refused(world, [alice, bob], alice, cures, bob.player_id, SurvivalService.REASON_NOT_INFECTED, "bob is not infected")
	# Too late: refused, kept.
	_infect(world, bob, _first_untreatable_stage())
	_assert_refused(world, [alice, bob], alice, cures, bob.player_id, SurvivalService.REASON_TOO_LATE, "bob's infection is past treatment")
	# Treatable: cured.
	var last_treatable: InfectionState.Stage = _last_treatable_stage()
	survival.get_vitals(bob.player_id).infection.stage = last_treatable
	survival.drain_events()
	var result: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, cures, bob.player_id)
	assert_true(result.ok, result.reason)
	assert_eq(survival.infection_stage(bob.player_id), InfectionState.Stage.NONE, "bob is cured")
	assert_eq(_quantity(world, cures), 2)
	assert_eq(result.event.get("infection_cured_from", ""), InfectionState.stage_name(last_treatable))
	assert_eq(result.event.get("bleeding_stopped_wound_ids", ["x"]), [])
	var events: Array[Dictionary] = survival.drain_events()
	assert_eq(events.size(), 1, str(events))
	assert_eq(events[0].get("event_type", ""), SurvivalService.EVENT_PLAYER_INFECTION_CURED)
	assert_eq(events[0].get("player_id", ""), bob.player_id, "the cure is bob's event")
	assert_eq(events[0].get("source_id", ""), cures)
	# Alice's own infection is not touched by a cure she uses on bob.
	_infect(world, alice)
	_infect(world, bob)
	assert_true(ItemConsumption.try_use_on(world, alice.player_id, cures, bob.player_id).ok)
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.LATENT, "alice is still infected")
	assert_eq(survival.infection_stage(bob.player_id), InfectionState.Stage.NONE)


func test_an_item_with_both_treatments_applies_what_the_target_needs() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var kits: String = _give(world, alice, KIT, 4)
	_assert_refused(world, [alice, bob], alice, kits, bob.player_id, SurvivalService.REASON_NOT_BLEEDING, "nothing to treat: the first treatment's reason")
	var wound_id: String = _wound(world, bob)
	var bleeding_only: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, kits, bob.player_id)
	assert_true(bleeding_only.ok, bleeding_only.reason)
	assert_eq(bleeding_only.event.get("bleeding_stopped_wound_ids", []), [wound_id])
	assert_eq(bleeding_only.event.get("infection_cured_from", "x"), ItemConsumption.NOT_CURED)
	_infect(world, bob)
	var infection_only: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, kits, bob.player_id)
	assert_true(infection_only.ok, infection_only.reason)
	assert_eq(infection_only.event.get("infection_cured_from", ""), "latent")
	assert_eq(survival.infection_stage(bob.player_id), InfectionState.Stage.NONE)
	assert_eq(_quantity(world, kits), 2)


# ------------------------------------------------------------ the target

func test_who_can_be_treated() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var bandages: String = _give(world, alice, BANDAGE, 5)
	_wound(world, bob)
	_wound(world, carol)
	var everybody: Array = [alice, bob, carol]
	# No such player, and a player that is away: one reason for both.
	_assert_refused(world, everybody, alice, bandages, MISSING_PLAYER_ID, ItemConsumption.REASON_TARGET_UNAVAILABLE, "unknown player")
	_assert_refused(world, everybody, alice, bandages, "zombie_000001", ItemConsumption.REASON_TARGET_UNAVAILABLE, "not a player id")
	world.leave(carol.player_id)
	_assert_refused(world, everybody, alice, bandages, carol.player_id, ItemConsumption.REASON_TARGET_UNAVAILABLE, "offline player")
	assert_eq(_bleeding_count(world, carol), 1, "an offline player's wound is not treated")
	# A dead player.
	assert_true(survival.apply_damage(bob.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	_assert_refused(world, everybody, alice, bandages, bob.player_id, ItemConsumption.REASON_TARGET_DEAD, "dead player")
	assert_eq(_quantity(world, bandages), 5)


func test_a_player_without_a_character_is_no_target_and_no_user() -> void:
	var world: ServerWorld = _world(true)
	var alice: PlayerState = world.join("alice")
	assert_true(world.create_character(alice.player_id, "Alice", {}).ok)
	var ghost: PlayerState = world.join("ghost")
	assert_true(world.is_player_connected(ghost.player_id) and not world.is_online(ghost.player_id), "connected, without a character")
	var bandages: String = _give(world, alice, BANDAGE, 2)
	_assert_refused(world, [alice], alice, bandages, ghost.player_id, ItemConsumption.REASON_TARGET_UNAVAILABLE, "a player without a character")
	_wound(world, alice)
	var result: ActionResult = ItemConsumption.try_use_on(world, ghost.player_id, bandages, alice.player_id)
	assert_false(result.ok)
	assert_eq(result.reason, ServerWorld.REASON_NOT_ONLINE, "a player without a character cannot treat anybody")
	assert_eq(_bleeding_count(world, alice), 1)
	assert_eq(_quantity(world, bandages), 2)


func test_the_target_must_be_within_the_treat_range_of_the_server_positions() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var bandages: String = _give(world, alice, BANDAGE, 5)
	_wound(world, bob)
	_wound(world, bob)
	_wound(world, bob)
	var range_m: float = _gameplay.treat_range_m
	bob.position = alice.position + Vector3(range_m + 0.01, 0.0, 0.0)
	_assert_refused(world, [alice, bob], alice, bandages, bob.player_id, ItemConsumption.REASON_TARGET_TOO_FAR, "just out of range")
	bob.position = alice.position + Vector3(0.0, 0.0, 100.0)
	_assert_refused(world, [alice, bob], alice, bandages, bob.player_id, ItemConsumption.REASON_TARGET_TOO_FAR, "far away")
	# Exactly at the range and anywhere closer: accepted.
	bob.position = alice.position + Vector3(range_m, 0.0, 0.0)
	assert_true(ItemConsumption.try_use_on(world, alice.player_id, bandages, bob.player_id).ok, "at the range")
	bob.position = alice.position + Vector3(0.0, 0.0, -range_m * 0.5)
	assert_true(ItemConsumption.try_use_on(world, alice.player_id, bandages, bob.player_id).ok, "inside the range")
	# The range is a setting.
	_gameplay.treat_range_m = 50.0
	bob.position = alice.position + Vector3(40.0, 0.0, 0.0)
	assert_true(ItemConsumption.try_use_on(world, alice.player_id, bandages, bob.player_id).ok, "a longer configured range")
	assert_eq(_quantity(world, bandages), 2)


func test_a_sleeping_or_prone_target_can_be_treated_and_is_not_woken() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var posture: PostureService = world.get_system(PostureService.SYSTEM_ID) as PostureService
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var bandages: String = _give(world, alice, BANDAGE, 5)
	_wound(world, bob)
	_wound(world, bob)
	_wound(world, alice)
	assert_true(survival.start_rest(bob.player_id).ok)
	assert_true(ItemConsumption.try_use_on(world, alice.player_id, bandages, bob.player_id).ok, "a sleeping player can be bandaged")
	assert_true(survival.is_resting(bob.player_id), "and sleeps on")
	assert_eq(_bleeding_count(world, bob), 1)
	assert_true(survival.stop_rest(bob.player_id).ok)
	assert_true(posture.request_posture(world, bob.player_id, PlayerPosture.Kind.PRONE).ok)
	assert_true(ItemConsumption.try_use_on(world, alice.player_id, bandages, bob.player_id).ok, "a prone player can be bandaged")
	assert_true(posture.is_prone(bob.player_id))
	assert_eq(_bleeding_count(world, bob), 0)
	# The user: prone may treat, asleep may not (it cannot act at all).
	_wound(world, bob)
	assert_true(posture.request_posture(world, alice.player_id, PlayerPosture.Kind.PRONE).ok)
	assert_true(ItemConsumption.try_use_on(world, alice.player_id, bandages, bob.player_id).ok, "a prone player can treat")
	_wound(world, bob)
	assert_true(survival.start_rest(alice.player_id).ok)
	_assert_refused(world, [alice, bob], alice, bandages, bob.player_id, SurvivalService.REASON_PLAYER_RESTING, "a sleeping player treats nobody")
	assert_true(survival.is_resting(alice.player_id), "a refused request does not wake")


# ------------------------------------------------------------ the user and the item

func test_who_can_treat_and_with_what() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var bandages: String = _give(world, alice, BANDAGE, 2)
	var bobs: String = _give(world, bob, BANDAGE, 1)
	var plain: String = _give(world, alice, PLAIN, 1)
	var lying: String = world.inventory.spawn_world_item(BANDAGE, 1, DevWorldSeed.DEV_CELL_ID, alice.position)
	_wound(world, bob)
	var everybody: Array = [alice, bob, carol]
	# Only the user's own carried item.
	_assert_refused(world, everybody, alice, bobs, bob.player_id, InventoryService.REASON_NOT_IN_INVENTORY, "bob's own bandage")
	_assert_refused(world, everybody, alice, lying, bob.player_id, InventoryService.REASON_NOT_IN_INVENTORY, "a bandage lying in the world")
	_assert_refused(world, everybody, alice, MISSING_ITEM_ID, bob.player_id, InventoryService.REASON_UNKNOWN_ITEM, "no such item")
	_assert_refused(world, everybody, alice, bob.player_id, bob.player_id, InventoryService.REASON_UNKNOWN_ITEM, "a player id is no item")
	_assert_refused(world, everybody, alice, plain, bob.player_id, ItemConsumption.REASON_NOT_CONSUMABLE, "an item without any use")
	# The item is checked before the target: an item the user does not hold
	# says nothing about any target.
	_assert_refused(world, everybody, alice, bobs, MISSING_PLAYER_ID, InventoryService.REASON_NOT_IN_INVENTORY, "unowned item, unknown target")
	# Who cannot use anything.
	_assert_refused(world, everybody, carol, bandages, bob.player_id, InventoryService.REASON_NOT_IN_INVENTORY, "carol does not hold alice's bandage")
	var unknown: ActionResult = ItemConsumption.try_use_on(world, MISSING_PLAYER_ID, bandages, bob.player_id)
	assert_eq(unknown.reason, ServerWorld.REASON_NOT_ONLINE, "an unknown user")
	world.leave(carol.player_id)
	assert_eq(ItemConsumption.try_use_on(world, carol.player_id, bandages, bob.player_id).reason, ServerWorld.REASON_NOT_ONLINE, "an offline user")
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	var dead: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, bandages, bob.player_id)
	assert_eq(dead.reason, SurvivalService.REASON_PLAYER_DEAD, "a dead user")
	assert_eq(_bleeding_count(world, bob), 1, "bob was never treated")


func test_food_is_not_given_to_others_when_the_setting_forbids_it() -> void:
	_gameplay.allow_feeding_others = false
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 3)
	survival.get_vitals(bob.player_id).hunger = 50.0
	survival.get_vitals(alice.player_id).hunger = 50.0
	_assert_refused(world, [alice, bob], alice, food, bob.player_id, ItemConsumption.REASON_NOT_USABLE_ON_OTHERS, "food on another player")
	# The item kind is checked before the target's condition and before the
	# distance: food never tells anything about a target.
	bob.position = alice.position + Vector3(500.0, 0.0, 0.0)
	_assert_refused(world, [alice, bob], alice, food, bob.player_id, ItemConsumption.REASON_NOT_USABLE_ON_OTHERS, "food on a far player")
	bob.position = alice.position
	# With the setting on, the target is fed and the user is not.
	_gameplay.allow_feeding_others = true
	var fed: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, food, bob.player_id)
	assert_true(fed.ok, fed.reason)
	assert_true(absf(survival.get_vitals(bob.player_id).hunger - 20.0) < EPSILON, "bob was fed: %f" % survival.get_vitals(bob.player_id).hunger)
	assert_eq(survival.get_vitals(alice.player_id).hunger, 50.0, "alice was not")
	assert_true(absf(float(fed.event.get("hunger_reduced", 0.0)) - 30.0) < EPSILON)
	assert_eq(_quantity(world, food), 2)


## P2-T13 (user decision 2026-11-15, docs/00 ADR-019): with the default
## settings food can be given to another player close by. The unit is the
## giver's, the lower hunger is the receiver's.
func test_by_default_food_is_given_to_another_player_close_by() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var food: String = _give(world, alice, FOOD, 4)
	survival.get_vitals(alice.player_id).hunger = 80.0
	survival.get_vitals(bob.player_id).hunger = 50.0
	survival.drain_events()
	var transactions: Array[Dictionary] = _transactions_of(world)

	var fed: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, food, bob.player_id)
	assert_true(fed.ok, fed.reason)
	assert_eq(fed.event.get("event_type", ""), ItemConsumption.EVENT_ITEM_USED_ON_PLAYER)
	assert_eq(fed.event.get("player_id", ""), alice.player_id, "the giver")
	assert_eq(fed.event.get("target_id", ""), bob.player_id, "the receiver")
	assert_true(absf(float(fed.event.get("hunger_reduced", 0.0)) - 30.0) < EPSILON)
	assert_eq(fed.event.get("bleeding_stopped_wound_ids", []), [], "food treats nothing")
	assert_true(absf(survival.get_vitals(bob.player_id).hunger - 20.0) < EPSILON, "bob was fed: %f" % survival.get_vitals(bob.player_id).hunger)
	assert_eq(survival.get_vitals(alice.player_id).hunger, 80.0, "the giver stays hungry")
	assert_eq(_quantity(world, food), 3, "one unit left the giver's stack")
	assert_eq(transactions.size(), 1, "one inventory transaction")
	assert_eq(world.inventory.items_in_inventory(bob.inventory_id).size(), 0, "nothing entered bob's inventory: he was fed")

	# Like eating oneself (ADR-013): a receiver who is not hungry still uses
	# the unit up. Food says nothing about the receiver.
	survival.get_vitals(bob.player_id).hunger = 0.0
	var wasted: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, food, bob.player_id)
	assert_true(wasted.ok, wasted.reason)
	assert_eq(survival.get_vitals(bob.player_id).hunger, 0.0)
	assert_eq(_quantity(world, food), 2)

	# The receiver must be in reach, alive and in the world; the food is kept.
	bob.position = alice.position + Vector3(_gameplay.treat_range_m + 0.5, 0.0, 0.0)
	_assert_refused(world, [alice, bob], alice, food, bob.player_id, ItemConsumption.REASON_TARGET_TOO_FAR, "food for a player out of reach")
	bob.position = alice.position
	_assert_refused(world, [alice, bob], alice, food, MISSING_PLAYER_ID, ItemConsumption.REASON_TARGET_UNAVAILABLE, "food for nobody")
	assert_true(survival.apply_damage(carol.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	_assert_refused(world, [alice, bob, carol], alice, food, carol.player_id, ItemConsumption.REASON_TARGET_DEAD, "food for the dead")
	# A sleeping receiver is fed and sleeps on.
	survival.get_vitals(bob.player_id).fatigue = 60.0
	survival.get_vitals(bob.player_id).hunger = 40.0
	assert_true(survival.start_rest(bob.player_id).ok, "bob lies down")
	assert_true(ItemConsumption.try_use_on(world, alice.player_id, food, bob.player_id).ok)
	assert_true(survival.is_resting(bob.player_id), "bob was not woken")
	assert_true(absf(survival.get_vitals(bob.player_id).hunger - 10.0) < EPSILON)
	assert_eq(_quantity(world, food), 1)


func test_using_an_item_on_oneself_is_the_usual_use() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var bandages: String = _give(world, alice, BANDAGE, 3)
	var food: String = _give(world, alice, FOOD, 2)
	var wound_id: String = _wound(world, alice)
	_wound(world, bob)
	# No target and the own id both mean "myself".
	for target: String in [ItemConsumption.NO_TARGET, alice.player_id]:
		if _bleeding_count(world, alice) == 0:
			wound_id = _wound(world, alice)
		var result: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, bandages, target)
		assert_true(result.ok, result.reason)
		assert_eq(result.event.get("event_type", ""), ItemConsumption.EVENT_ITEM_CONSUMED, "the event of a self-use")
		assert_eq(result.event.get("bleeding_stopped_wound_ids", []), [wound_id])
		assert_eq(_bleeding_count(world, alice), 0)
	assert_eq(_bleeding_count(world, bob), 1, "bob is not treated by a self-use")
	assert_eq(_quantity(world, bandages), 1)
	# Food on oneself is always allowed, whatever the setting for others says.
	survival.get_vitals(alice.player_id).hunger = 50.0
	assert_true(ItemConsumption.try_use_on(world, alice.player_id, food, ItemConsumption.NO_TARGET).ok)
	assert_true(survival.get_vitals(alice.player_id).hunger < 50.0)
	# And refusals of a self-use are the usual ones.
	assert_eq(ItemConsumption.try_use_on(world, alice.player_id, bandages, alice.player_id).reason, SurvivalService.REASON_NOT_BLEEDING)


func test_the_check_order_reveals_nothing_before_the_request_is_legitimate() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var cures: String = _give(world, alice, CURE, 1)
	_infect(world, bob, _first_untreatable_stage())
	# Far away: the distance is refused before the infection is looked at,
	# so a cure cannot test a player across the map.
	bob.position = alice.position + Vector3(100.0, 0.0, 0.0)
	_assert_refused(world, [alice, bob], alice, cures, bob.player_id, ItemConsumption.REASON_TARGET_TOO_FAR, "far infected target")
	# Close: now the condition answers.
	bob.position = alice.position
	_assert_refused(world, [alice, bob], alice, cures, bob.player_id, SurvivalService.REASON_TOO_LATE, "close infected target")
	# Dead comes before the distance (both are public facts).
	assert_true(_survival(world).apply_damage(bob.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	bob.position = alice.position + Vector3(100.0, 0.0, 0.0)
	_assert_refused(world, [alice, bob], alice, cures, bob.player_id, ItemConsumption.REASON_TARGET_DEAD, "far dead target")
