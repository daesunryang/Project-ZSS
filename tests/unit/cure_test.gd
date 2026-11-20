extends TestCase
## P2-T7 (user decision 2026-11-15): a cure item clears the infection while
## it is still treatable, on the server, no network. ItemConsumption uses up
## one unit of a carried cure and calls the existing treatment rule
## (SurvivalService.apply_infection_treatment: through the configured stage
## only) as one all-or-nothing rule. A cure is refused and kept when the
## player is not infected or the infection is too far along. Also: the
## shipped cure definition, the development seed and the save round trip.

const WORLD: String = "cure_test_world"
const NEVER: float = 1.0e9
const EPSILON: float = 0.000001
const CURE: String = "t7_cure"
const BANDAGE: String = "t7_bandage"
const FIRST_AID: String = "t7_first_aid"
const PLAIN: String = "t7_plain"
const STACK_MAX: int = 5
const LETHAL_DAMAGE: float = 100000.0
const LACERATION_DAMAGE: float = 20.0
const SECONDS_PER_HOUR: float = 3600.0
## Every infection stage lasts this long in these tests (world hours).
const STAGE_HOURS: float = 1.0
## Needs do not move on their own (the longest allowed climb).
const FROZEN_NEED_HOURS: float = 100000.0
const ZOMBIE: String = "zombie_000001"

var _settings: SurvivalSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = ""
	_settings = SurvivalSettings.new()
	_settings.respawn_delay_sec = NEVER
	# A bite always infects; only the infection moves in these tests.
	_settings.infection_chance_bite = 1.0
	_settings.infection_latent_hours = STAGE_HOURS
	_settings.infection_early_hours = STAGE_HOURS
	_settings.infection_progressing_hours = STAGE_HOURS
	_settings.infection_severe_hours = STAGE_HOURS
	_settings.infection_terminal_hours = STAGE_HOURS
	_settings.hunger_hours_to_max = FROZEN_NEED_HOURS
	_settings.thirst_hours_to_max = FROZEN_NEED_HOURS
	_settings.fatigue_hours_to_max = FROZEN_NEED_HOURS
	_settings.health_recovery_per_world_sec = 0.0
	_settings.wound_recovery_per_world_sec = 0.0


func after_each() -> void:
	if not _root.is_empty():
		SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.new()
	catalog.add(_definition(CURE, true, 0))
	catalog.add(_definition(BANDAGE, false, 1))
	catalog.add(_definition(FIRST_AID, true, 1))
	catalog.add(_definition(PLAIN, false, 0))
	return catalog


func _definition(definition_id: String, cures: bool, bleeding_wounds: int) -> ItemDefinition:
	var definition: ItemDefinition = ItemDefinition.new()
	definition.definition_id = definition_id
	definition.max_stack = STACK_MAX
	definition.cures_infection = cures
	definition.treat_bleeding_wound_count = bleeding_wounds
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


## Infects the player with a bite (the configured chance is 1).
func _infect(survival: SurvivalService, player_id: String) -> void:
	var exposed: ActionResult = survival.apply_infection_exposure(player_id, InfectionState.Exposure.BITE, ZOMBIE)
	if not exposed.ok or survival.infection_stage(player_id) != InfectionState.Stage.LATENT:
		fail("test setup: infection failed: " + exposed.reason)


## Infects the player and lets world time pass until `stage` is reached.
func _infect_to_stage(world: ServerWorld, survival: SurvivalService, player_id: String, stage: InfectionState.Stage) -> void:
	_infect(survival, player_id)
	var stages_to_pass: int = int(stage) - int(InfectionState.Stage.LATENT)
	if stages_to_pass > 0:
		# Half a stage past the boundary.
		world.step_systems((float(stages_to_pass) + 0.5) * STAGE_HOURS * SECONDS_PER_HOUR)
	if survival.infection_stage(player_id) != stage:
		fail("test setup: stage is %s" % InfectionState.stage_name(survival.infection_stage(player_id)))


func _last_treatable_stage() -> InfectionState.Stage:
	return _settings.infection_treatment_max_stage as InfectionState.Stage


func _first_untreatable_stage() -> InfectionState.Stage:
	return (int(_last_treatable_stage()) + 1) as InfectionState.Stage


func _treatable_stages() -> Array[InfectionState.Stage]:
	var stages: Array[InfectionState.Stage] = []
	for stage_value: int in range(int(InfectionState.Stage.LATENT), int(_last_treatable_stage()) + 1):
		stages.append(stage_value as InfectionState.Stage)
	return stages


func _untreatable_living_stages() -> Array[InfectionState.Stage]:
	var stages: Array[InfectionState.Stage] = []
	for stage_value: int in range(int(_first_untreatable_stage()), int(InfectionState.Stage.TERMINAL) + 1):
		stages.append(stage_value as InfectionState.Stage)
	return stages


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


# ------------------------------------------------------------ SurvivalService preflight

func test_the_treatment_preflight_agrees_with_the_treatment_rule() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	assert_eq(survival.check_infection_treatment(alice.player_id), SurvivalService.REASON_NOT_INFECTED)
	assert_eq(survival.check_infection_treatment("player_999999"), SurvivalService.REASON_UNKNOWN_PLAYER)
	_infect(survival, alice.player_id)
	survival.drain_events()
	assert_eq(survival.check_infection_treatment(alice.player_id), "", "a latent infection is treatable")
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.LATENT, "the preflight changes nothing")
	assert_eq(survival.drain_events().size(), 0, "the preflight reports nothing")
	var first_untreatable: InfectionState.Stage = _first_untreatable_stage()
	world.step_systems((float(int(first_untreatable) - int(InfectionState.Stage.LATENT)) + 0.5) * STAGE_HOURS * SECONDS_PER_HOUR)
	assert_eq(survival.infection_stage(alice.player_id), first_untreatable)
	assert_eq(survival.check_infection_treatment(alice.player_id), SurvivalService.REASON_TOO_LATE)
	assert_eq(survival.apply_infection_treatment(alice.player_id, "item_000001").reason, SurvivalService.REASON_TOO_LATE, "the rule itself is unchanged")
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(survival.check_infection_treatment(alice.player_id), SurvivalService.REASON_PLAYER_DEAD)


# ------------------------------------------------------------ ItemConsumption with a cure

func test_a_cure_clears_a_treatable_infection_and_uses_one_unit() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var treatable_stages: Array[InfectionState.Stage] = _treatable_stages()
	var cure_id: String = _give(world, alice, CURE, treatable_stages.size())
	for stage: InfectionState.Stage in treatable_stages:
		var stage_label: String = InfectionState.stage_name(stage)
		_infect_to_stage(world, survival, alice.player_id, stage)
		survival.drain_events()
		var transactions: Array[Dictionary] = _transactions_of(world)
		var quantity_before: int = world.inventory.get_item(cure_id).quantity
		var used: ActionResult = ItemConsumption.try_consume(world, alice.player_id, cure_id)
		assert_true(used.ok, "%s: %s" % [stage_label, used.reason])
		assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.NONE, "%s: the infection is gone" % stage_label)
		assert_false(vitals.infection.is_infected())
		assert_eq(used.event.get("event_type", ""), ItemConsumption.EVENT_ITEM_CONSUMED)
		assert_eq(used.event.get("definition_id", ""), CURE)
		assert_eq(used.event.get("infection_cured_from", ""), stage_label, "the event names the stage that was cured")
		assert_eq(used.event.get("remaining_quantity", -1), quantity_before - 1)
		assert_eq(used.event.get("bleeding_stopped_wound_ids", []), [])
		assert_true(SaveService.is_json_safe(used.event))
		assert_eq(transactions.size(), 1, "%s: exactly one inventory transaction per use" % stage_label)
		assert_eq(transactions[0].get("event_type", ""), InventoryService.EVENT_ITEM_REMOVED)
		assert_eq(transactions[0].get("removed_quantity", 0), ItemConsumption.CONSUMED_QUANTITY)
		var cured: Array[Dictionary] = _events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_INFECTION_CURED)
		assert_eq(cured.size(), 1, "%s: the existing cure event is queued once" % stage_label)
		assert_eq(cured[0].get("from", ""), stage_label)
		assert_eq(cured[0].get("source_id", ""), cure_id, "the item is the source of the cure")
		# The infection no longer progresses.
		world.step_systems(3.0 * STAGE_HOURS * SECONDS_PER_HOUR)
		assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.NONE, "%s: a cured player stays healthy" % stage_label)
		survival.drain_events()
	# Every configured treatable stage used one unit: the instance is gone and its id is retired.
	assert_null(world.inventory.get_item(cure_id))
	assert_true(world.registry.is_tombstoned(cure_id))
	assert_true(survival.is_alive(alice.player_id))


func test_a_cure_is_refused_and_kept_when_it_is_too_late() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	for stage: InfectionState.Stage in _untreatable_living_stages():
		var stage_label: String = InfectionState.stage_name(stage)
		var player: PlayerState = world.join("player_" + stage_label)
		var cure_id: String = _give(world, player, CURE, 2)
		_infect_to_stage(world, survival, player.player_id, stage)
		survival.drain_events()
		var transactions: Array[Dictionary] = _transactions_of(world)
		var before_items: Dictionary = world.inventory.to_snapshot()
		var before_vitals: Dictionary = survival.get_vitals(player.player_id).to_dict()
		var refused: ActionResult = ItemConsumption.try_consume(world, player.player_id, cure_id)
		assert_false(refused.ok, stage_label)
		assert_eq(refused.reason, SurvivalService.REASON_TOO_LATE, stage_label)
		assert_eq(world.inventory.to_snapshot(), before_items, "%s: the cure is not used up" % stage_label)
		assert_eq(world.inventory.get_item(cure_id).quantity, 2)
		assert_eq(survival.get_vitals(player.player_id).to_dict(), before_vitals, "%s: the infection is unchanged" % stage_label)
		assert_eq(survival.infection_stage(player.player_id), stage)
		assert_eq(transactions.size(), 0, "%s: no inventory transaction" % stage_label)
		assert_eq(survival.drain_events().size(), 0, "%s: no survival event" % stage_label)
		world.leave(player.player_id)


func test_a_cure_is_refused_and_kept_by_a_healthy_player_and_other_refusals() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var cure_id: String = _give(world, alice, CURE, 3)
	var plain_id: String = _give(world, alice, PLAIN)
	var lying_cure: String = world.inventory.spawn_world_item(CURE, 1, DevWorldSeed.DEV_CELL_ID, alice.position)
	# Bob is infected and has no cure; alice is healthy and has three.
	_infect(survival, bob.player_id)
	survival.drain_events()
	var transactions: Array[Dictionary] = _transactions_of(world)
	var before_items: Dictionary = world.inventory.to_snapshot()
	var before_alice: Dictionary = survival.get_vitals(alice.player_id).to_dict()
	var before_bob: Dictionary = survival.get_vitals(bob.player_id).to_dict()

	var healthy: ActionResult = ItemConsumption.try_consume(world, alice.player_id, cure_id)
	assert_false(healthy.ok)
	assert_eq(healthy.reason, SurvivalService.REASON_NOT_INFECTED, "nothing to cure: the cure is not wasted")
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, plain_id).reason, ItemConsumption.REASON_NOT_CONSUMABLE)
	assert_eq(ItemConsumption.try_consume(world, bob.player_id, cure_id).reason, InventoryService.REASON_NOT_IN_INVENTORY, "bob cannot use alice's cure")
	assert_eq(ItemConsumption.try_consume(world, bob.player_id, lying_cure).reason, InventoryService.REASON_NOT_IN_INVENTORY, "a cure lying in the world")
	assert_eq(ItemConsumption.try_consume(world, bob.player_id, "item_999999").reason, InventoryService.REASON_UNKNOWN_ITEM)
	world.leave(bob.player_id)
	assert_eq(ItemConsumption.try_consume(world, bob.player_id, cure_id).reason, ServerWorld.REASON_NOT_ONLINE)

	assert_eq(world.inventory.to_snapshot(), before_items, "no item changed")
	assert_eq(world.inventory.get_item(cure_id).quantity, 3, "the stack is whole")
	assert_eq(survival.get_vitals(alice.player_id).to_dict(), before_alice)
	assert_eq(survival.get_vitals(bob.player_id).to_dict(), before_bob, "bob is still infected")
	assert_eq(survival.infection_stage(bob.player_id), InfectionState.Stage.LATENT)
	assert_eq(transactions.size(), 0, "no inventory transaction was committed")
	assert_eq(survival.drain_events().size(), 0, "no survival event was queued")

	# A dead player's cure is not used up (its items lie where it died, P2-T4).
	_infect(survival, alice.player_id)
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	survival.drain_events()
	transactions.clear()
	var after_death: Dictionary = world.inventory.to_snapshot()
	var dead: ActionResult = ItemConsumption.try_consume(world, alice.player_id, cure_id)
	assert_false(dead.ok)
	assert_eq(dead.reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(world.inventory.to_snapshot(), after_death)
	assert_eq(survival.get_vitals(alice.player_id).infection.stage, InfectionState.Stage.LATENT, "the dead character's infection is not treated")
	assert_eq(transactions.size(), 0)
	assert_eq(survival.drain_events().size(), 0)


func test_the_treatable_stage_comes_from_the_settings() -> void:
	# The item carries no stage of its own: the server rule decides.
	_settings.infection_treatment_max_stage = InfectionState.Stage.LATENT
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var cure_id: String = _give(world, alice, CURE, 2)
	_infect_to_stage(world, survival, alice.player_id, InfectionState.Stage.EARLY)
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, cure_id).reason, SurvivalService.REASON_TOO_LATE, "early is too late with this setting")
	assert_eq(world.inventory.get_item(cure_id).quantity, 2)
	_settings.infection_treatment_max_stage = InfectionState.Stage.SEVERE
	world.step_systems(2.0 * STAGE_HOURS * SECONDS_PER_HOUR)
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.SEVERE)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, cure_id).ok, "severe is treatable with this setting")
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.NONE)
	assert_eq(world.inventory.get_item(cure_id).quantity, 1)


func test_a_cured_player_can_be_infected_and_cured_again() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var cure_id: String = _give(world, alice, CURE, 2)
	_infect(survival, alice.player_id)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, cure_id).ok)
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, cure_id).reason, SurvivalService.REASON_NOT_INFECTED, "the second dose has nothing to cure")
	assert_eq(world.inventory.get_item(cure_id).quantity, 1)
	# No immunity: the next bite infects again (the stage clock starts over).
	_infect(survival, alice.player_id)
	assert_eq(survival.get_vitals(alice.player_id).infection.stage_elapsed_world_sec, 0.0)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, cure_id).ok)
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.NONE)
	assert_null(world.inventory.get_item(cure_id))


func test_an_item_with_cure_and_bandage_effects_applies_what_applies() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	var kit_id: String = _give(world, alice, FIRST_AID, 4)
	var bandage_id: String = _give(world, alice, BANDAGE, 1)
	# Healthy and not bleeding: nothing applies, the first treatment's reason.
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, kit_id).reason, SurvivalService.REASON_NOT_BLEEDING)
	assert_eq(world.inventory.get_item(kit_id).quantity, 4)
	# Infected only: the cure applies, the bandage part is skipped.
	_infect(survival, alice.player_id)
	var cured: ActionResult = ItemConsumption.try_consume(world, alice.player_id, kit_id)
	assert_true(cured.ok, cured.reason)
	assert_eq(cured.event.get("infection_cured_from", ""), "latent")
	assert_eq(cured.event.get("bleeding_stopped_wound_ids", []), [])
	# Bleeding and infected: both with one unit.
	var hit: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.LACERATION, LACERATION_DAMAGE))
	var wound_id: String = str((hit.event["wound"] as Dictionary)["wound_id"])
	_infect(survival, alice.player_id)
	var both: ActionResult = ItemConsumption.try_consume(world, alice.player_id, kit_id)
	assert_true(both.ok, both.reason)
	assert_eq(both.event.get("bleeding_stopped_wound_ids", []), [wound_id])
	assert_eq(both.event.get("infection_cured_from", ""), "latent")
	assert_false(vitals.injuries[0].is_bleeding)
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.NONE)
	# Bleeding, too late to cure: the bandage part still applies.
	survival.apply_damage(alice.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.LEFT_ARM, Wound.Type.LACERATION, LACERATION_DAMAGE))
	var first_untreatable: InfectionState.Stage = _first_untreatable_stage()
	_infect_to_stage(world, survival, alice.player_id, first_untreatable)
	var late: ActionResult = ItemConsumption.try_consume(world, alice.player_id, kit_id)
	assert_true(late.ok, late.reason)
	assert_eq((late.event.get("bleeding_stopped_wound_ids", []) as Array).size(), 1)
	assert_eq(late.event.get("infection_cured_from", "x"), "", "nothing was cured")
	assert_eq(survival.infection_stage(alice.player_id), first_untreatable)
	assert_eq(world.inventory.get_item(kit_id).quantity, 1)
	# A plain bandage does not cure and a plain cure does not bandage.
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, bandage_id).reason, SurvivalService.REASON_NOT_BLEEDING)


# ------------------------------------------------------------ data

func test_item_definitions_carry_the_cure_effect() -> void:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var cure: ItemDefinition = catalog.get_definition("dev_cure")
	assert_not_null(cure, "the development cure is shipped")
	if cure == null:
		return
	assert_true(cure.cures_infection)
	assert_true(cure.is_consumable(), "a cure can be used up")
	assert_false(cure.lowers_needs(), "a cure is not food")
	assert_false(cure.stops_bleeding(), "a cure is not a bandage")
	assert_eq(cure.validate().size(), 0, "; ".join(cure.validate()))
	for definition_id: String in ["dev_food_ration", "dev_water_bottle", "dev_bandage", "dev_melee_pipe", "dev_test_item"]:
		assert_false(catalog.get_definition(definition_id).cures_infection, definition_id)
	assert_false(ItemDefinition.new().cures_infection, "no effect unless the data says so")
	assert_false(ItemDefinition.new().is_consumable())


func test_the_default_new_world_has_a_few_cures() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var no_zombies: ZombieSettings = ZombieSettings.new()
	no_zombies.dev_spawn_count = 0
	config.zombie = no_zombies
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	assert_eq(world.seed_new_world(config.dev_seed), OK)
	var cures: int = 0
	var bandages: int = 0
	var expected_cures: int = 0
	for index: int in config.dev_seed.item_definition_ids.size():
		if config.dev_seed.item_definition_ids[index] == "dev_cure":
			expected_cures += config.dev_seed.quantity_at(index)
	var spawn: Vector3 = config.gameplay.player_spawn_position
	for item_id: String in world.inventory.world_item_ids():
		var item: ItemInstance = world.inventory.get_item(item_id)
		if item.definition_id == "dev_bandage":
			bandages += item.quantity
		if item.definition_id != "dev_cure":
			continue
		cures += item.quantity
		assert_true(world.inventory.world_position_of(item_id).distance_to(spawn) <= 10.0, "the cure lies near the spawn point")
	assert_eq(cures, expected_cures, "the new world contains the configured cure quantity")
	assert_true(cures >= 1, "cures in a new world: %d" % cures)
	assert_true(cures <= bandages, "a cure is rarer than a bandage (%d cures, %d bandages)" % [cures, bandages])
	# The shipped resource and script default describe the same treatment window.
	assert_eq(config.survival.infection_treatment_max_stage, SurvivalSettings.new().infection_treatment_max_stage)


# ------------------------------------------------------------ save round trip

func test_a_used_cure_and_the_cleared_infection_survive_a_save_round_trip() -> void:
	_root = "user://test_saves/cure_%d" % Time.get_ticks_usec()
	var config: CompositionConfig = _config()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), config)
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	if world == null:
		return
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var cure_id: String = _give(world, alice, CURE, 3)
	_infect_to_stage(world, survival, alice.player_id, _last_treatable_stage())
	_infect(survival, bob.player_id)
	assert_true(ItemConsumption.try_consume(world, alice.player_id, cure_id).ok)
	assert_eq(persistence.save(world), OK)

	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), config).load_or_create(WORLD)
	assert_not_null(restored, "world restored from save")
	if restored == null:
		return
	var restored_survival: SurvivalService = _survival(restored)
	assert_eq(restored_survival.infection_stage(alice.player_id), InfectionState.Stage.NONE, "the cured player stays cured")
	assert_eq(restored_survival.get_vitals(alice.player_id).infection.to_dict(), InfectionState.new().to_dict(), "no trace of the infection is saved")
	assert_eq(restored_survival.infection_stage(bob.player_id), InfectionState.Stage.LATENT, "the untreated player is still infected")
	assert_eq(restored.inventory.get_item(cure_id).quantity, 2, "the smaller stack was saved")
	# The restored world: nothing to cure for alice, bob has no cure.
	restored.join("alice")
	assert_eq(ItemConsumption.try_consume(restored, alice.player_id, cure_id).reason, SurvivalService.REASON_NOT_INFECTED)
	assert_eq(restored.inventory.get_item(cure_id).quantity, 2)
