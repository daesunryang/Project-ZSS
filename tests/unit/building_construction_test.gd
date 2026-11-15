extends TestCase
## P3-5: how a structure is built on the server (docs/04 §3, §5, §12,
## docs/00 ADR-025, docs/09 §15.5): what a definition costs, the blueprint,
## delivering materials, work over action time, every reason work stops, the
## states, completion (also with somebody standing in the edge), and what a
## cancellation or a demolition returns. No nodes, no waiting: the world
## clock is stepped by hand. Saving and cells:
## building_construction_save_test.gd. Network: construction_net_test.gd.

const WORLD: String = "construction_test_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
const LETHAL_DAMAGE: float = 100000.0
const TOLERANCE: float = 0.0005
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const SPAWN_TILE: Vector2i = Vector2i(5, 5)
const FAR_AWAY: Vector3 = Vector3(15.5, 0.0, 5.5)
const PLANK: String = ConstructionTestKit.PLANK
const NAIL: String = ConstructionTestKit.NAIL
const JUNK: String = "dev_test_item"
const WALL: String = ConstructionTestKit.WALL
const FLOOR: String = ConstructionTestKit.FLOOR
const DOOR: String = ConstructionTestKit.DOOR
const FREE_WALL: String = ConstructionTestKit.FREE_WALL
const ENDLESS_WALL: String = ConstructionTestKit.ENDLESS_WALL
const LOSSY_WALL: String = ConstructionTestKit.LOSSY_WALL
const BIG_FLOOR: String = ConstructionTestKit.BIG_FLOOR
const WALL_WORK_SEC: float = ConstructionTestKit.WALL_WORK_SEC
const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X
const LOW_Z: int = StructureGrid.Layer.EDGE_LOW_Z
## The +X side of the spawn tile: the edge x = 6, half a metre from SPAWN.
const EAST: int = 1
const EAST_SLOT: Vector3i = Vector3i(6, 5, LOW_X)
const NORTH: int = 0
const WEST: int = 3

var _building_settings: BuildingSettings = null
var _clock_settings: WorldClockSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_building_settings = BuildingSettings.new()
	_clock_settings = WorldClockSettings.new()


func after_each() -> void:
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	# from_defaults() hands out shared cached resources: replace, never edit.
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = _clock_settings
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.zombie.wander_pause_min_sec = NEVER
	config.zombie.wander_pause_max_sec = NEVER
	# A zombie in these tests only stands somewhere: it senses nobody.
	config.zombie.sight_range_m = 0.0
	config.zombie.hearing_multiplier = 0.0
	config.catalog = ConstructionTestKit.items()
	config.structures = ConstructionTestKit.structures()
	config.building = _building_settings
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 10.0
	config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	config.world_cells.active_radius_cells = 1
	config.world_cells.preload_radius_cells = 2
	config.world_cells.preload_lookahead_sec = 0.0
	config.world_cells.refresh_period_sec = 0.0
	return config


func _world() -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	world.seed_new_world(DevWorldSeed.new())
	return world


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _id(result: ActionResult) -> String:
	return str(result.event.get(BuildingService.KEY_STRUCTURE_ID, ""))


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int) -> void:
	if not ConstructionTestKit.give(world, player, definition_id, quantity):
		fail("test setup: could not give %d %s" % [quantity, definition_id])


func _kill(world: ServerWorld, player: PlayerState) -> void:
	if not _survival(world).apply_damage(player.player_id, DamageInput.create("test_source", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok:
		fail("test setup: lethal damage failed")


## Places a piece for `player` next to the spawn tile and returns its id.
func _place(world: ServerWorld, player: PlayerState, definition_id: String, rotation: int = EAST, tile: Vector2i = SPAWN_TILE) -> String:
	var placed: ActionResult = _building(world).try_place(world, player.player_id, definition_id, tile, rotation)
	if not placed.ok:
		fail("test setup: %s was not placed: %s" % [definition_id, placed.reason])
	return _id(placed)


## The events of one type (and cause) among `events`.
func _events_of(events: Array[Dictionary], event_type: String, cause: String = "") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in events:
		if event["event_type"] == event_type and (cause.is_empty() or str(event.get("cause", "")) == cause):
			result.append(event)
	return result


func _near(a: float, b: float) -> bool:
	return absf(a - b) <= TOLERANCE


# ------------------------------------------------------------ definitions

func test_a_definition_says_what_it_costs_how_much_work_it_is_and_what_comes_back() -> void:
	var catalog: StructureCatalog = ConstructionTestKit.structures()
	var wall: StructureDefinition = catalog.get_definition(WALL)
	assert_eq(wall.validate().size(), 0, "; ".join(wall.validate()))
	var costs: Dictionary[String, int] = {PLANK: 4, NAIL: 2}
	assert_eq(wall.build_costs, costs)
	assert_true(wall.build_work_sec > 0.0 and wall.cancel_refund_percent == 100 and wall.demolish_refund_percent == 50)
	assert_eq(catalog.validate_against(ConstructionTestKit.items()).size(), 0)
	assert_eq(catalog.validate_against(ItemCatalog.load_directory()).size() > 0, true, "a cost must name an item that exists")
	# One broken value at a time.
	var breakers: Array[Callable] = [
		func(d: StructureDefinition) -> void: d.build_costs = {PLANK: 0},
		func(d: StructureDefinition) -> void: d.build_costs = {PLANK: -3},
		func(d: StructureDefinition) -> void: d.build_costs = {PLANK: StructureDefinition.MAX_COST_QUANTITY + 1},
		func(d: StructureDefinition) -> void: d.build_costs = {"Not An Item": 1},
		func(d: StructureDefinition) -> void: d.build_work_sec = 0.0,
		func(d: StructureDefinition) -> void: d.build_work_sec = -1.0,
		func(d: StructureDefinition) -> void: d.build_work_sec = NAN,
		func(d: StructureDefinition) -> void: d.cancel_refund_percent = 101,
		func(d: StructureDefinition) -> void: d.cancel_refund_percent = -1,
		func(d: StructureDefinition) -> void: d.demolish_refund_percent = 200,
	]
	for index: int in range(breakers.size()):
		var broken: StructureDefinition = ConstructionTestKit.structures().get_definition(WALL)
		breakers[index].call(broken)
		assert_true(broken.validate().size() > 0, "broken definition %d is refused" % index)
		assert_eq(StructureCatalog.new().add(broken), ERR_INVALID_DATA, "and the catalog does not take it (%d)" % index)
	var too_many_kinds: StructureDefinition = ConstructionTestKit.structures().get_definition(WALL)
	for index: int in range(StructureDefinition.MAX_COST_KINDS + 1):
		too_many_kinds.build_costs["test_material_%d" % index] = 1
	assert_true(too_many_kinds.validate().size() > 0, "more kinds of materials than a row carries")
	# The refund rule: whole units, rounded down, never more than delivered.
	var delivered: Dictionary[String, int] = {PLANK: 5, NAIL: 3}
	var half: Dictionary[String, int] = {PLANK: 2, NAIL: 1}
	var quarter: Dictionary[String, int] = {PLANK: 1}
	var nothing: Dictionary[String, int] = {}
	assert_eq(StructureDefinition.refund_of(delivered, 100), delivered, "everything")
	assert_eq(StructureDefinition.refund_of(delivered, 50), half)
	assert_eq(StructureDefinition.refund_of(delivered, 25), quarter, "0.75 nails is no nail")
	assert_eq(StructureDefinition.refund_of(delivered, 0), nothing)
	assert_eq(StructureDefinition.refund_of(nothing, 100), nothing)
	for percent: int in range(-10, 120):
		var refund: Dictionary[String, int] = StructureDefinition.refund_of(delivered, percent)
		for item_id: String in refund:
			assert_true(refund[item_id] >= 1 and refund[item_id] <= delivered[item_id], "%d%% of %s" % [percent, item_id])


func test_the_shipped_definitions_cost_materials_the_new_world_has() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var seeded: Dictionary[String, int] = {}
	for index: int in range(config.dev_seed.item_definition_ids.size()):
		var item_id: String = config.dev_seed.item_definition_ids[index]
		seeded[item_id] = int(seeded.get(item_id, 0)) + config.dev_seed.quantity_at(index)
	var needed: Dictionary[String, int] = {}
	for definition_id: String in config.structures.definition_ids():
		var definition: StructureDefinition = config.structures.get_definition(definition_id)
		assert_true(definition.build_costs.size() > 0, "%s costs something" % definition_id)
		assert_true(definition.build_work_sec > 0.0, definition_id)
		for item_id: String in definition.build_costs:
			assert_true(config.catalog.has(item_id), "%s needs %s, an item that exists" % [definition_id, item_id])
			needed[item_id] = int(needed.get(item_id, 0)) + definition.build_costs[item_id]
	# docs/04 §5: wood and nails / hardware to begin with; a new world holds
	# enough to build one of each piece.
	assert_true(needed.has("dev_wood") and needed.has("dev_nails"), str(needed))
	for item_id: String in needed:
		assert_true(int(seeded.get(item_id, 0)) >= needed[item_id], "the new world has %d %s, one of each piece needs %d" % [int(seeded.get(item_id, 0)), item_id, needed[item_id]])
	# The blueprint flow is what ships; the dev rule is a switch.
	var shipped: BuildingSettings = BuildingSettings.load_or_default()
	assert_false(shipped.instant_completion)
	assert_false(BuildingSettings.new().instant_completion, "and the script default agrees")
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	var broken: BuildingSettings = BuildingSettings.new()
	broken.deliver_range_m = 0.0
	assert_true(broken.validate().size() > 0)
	broken = BuildingSettings.new()
	broken.work_range_m = NAN
	assert_true(broken.validate().size() > 0)
	broken = BuildingSettings.new()
	broken.max_workers_per_structure = 0
	assert_true(broken.validate().size() > 0)
	broken = BuildingSettings.new()
	broken.progress_event_step = 0.0
	assert_true(broken.validate().size() > 0)
	broken = BuildingSettings.new()
	broken.completion_retry_interval_sec = 0.0
	assert_true(broken.validate().size() > 0)


# ------------------------------------------------------------ blueprint

func test_a_placement_makes_a_blueprint_that_takes_its_slot_and_nothing_else() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	_give(world, alice, PLANK, 10)
	_give(world, alice, NAIL, 5)
	var placed: ActionResult = service.try_place(world, alice.player_id, WALL, SPAWN_TILE, EAST)
	assert_true(placed.ok, placed.reason)
	var structure: StructureInstance = service.get_structure(_id(placed))
	assert_eq(structure.construction_state, StructureInstance.State.BLUEPRINT)
	assert_eq(structure.construction_progress, 0.0)
	assert_eq(structure.health, 0.0)
	assert_eq(structure.delivered_materials.size(), 0)
	var costs: Dictionary[String, int] = {PLANK: 4, NAIL: 2}
	assert_eq(structure.inventory_costs, costs, "what the definition asks for")
	assert_eq(structure.missing_materials(), costs)
	assert_eq(structure.material_share(), 0.0)
	assert_true(structure.is_under_construction() and not structure.is_standing())
	# Placing takes nothing: materials are brought afterwards.
	assert_eq(ConstructionTestKit.carried(world, alice, PLANK), 10)
	assert_eq(ConstructionTestKit.carried(world, alice, NAIL), 5)
	# It takes its slot and blocks nothing.
	assert_eq(service.structure_id_at(EAST_SLOT), structure.structure_id)
	assert_eq(service.try_place(world, alice.player_id, DOOR, SPAWN_TILE, EAST).reason, BuildingService.REASON_SLOT_OCCUPIED)
	assert_false(service.is_edge_blocked(EAST_SLOT))
	assert_eq(world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, SPAWN, Vector3(7.5, 0.0, 5.5)), Vector3(7.5, 0.0, 5.5), "a blueprint lets everybody through")
	# What everybody may see of it.
	assert_eq(service.public_row(structure), {
		"structure_id": structure.structure_id, "definition_id": WALL, "x": 5, "z": 5, "rotation": EAST, "state": "blueprint", "door_open": false,
		"health_fraction": 0.0, "progress": 0.0, "delivered": {}, "required": {PLANK: 4, NAIL: 2},
	})
	var events: Array[Dictionary] = service.drain_events()
	assert_eq(events.size(), 1)
	assert_eq(events[0]["event_type"], BuildingService.EVENT_PLACED)
	assert_eq(events[0]["required"], {PLANK: 4, NAIL: 2})
	assert_true(SaveService.is_json_safe(events[0]) and SaveService.is_json_safe(structure.to_dict()))
	assert_false(events[0].has("placed_by"), "who placed it is not in the public row")


# ------------------------------------------------------------ delivery

func test_a_delivery_takes_only_what_is_still_needed() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	_give(world, alice, PLANK, 10)
	_give(world, alice, NAIL, 5)
	var planks: String = ConstructionTestKit.stacks(world, alice, PLANK)[0]
	var nails: String = ConstructionTestKit.stacks(world, alice, NAIL)[0]
	var wall_id: String = _place(world, alice, WALL)
	var structure: StructureInstance = service.get_structure(wall_id)
	service.drain_events()
	var committed: Array[Dictionary] = []
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void: committed.append(event))
	var planks_before: int = ConstructionTestKit.total(world, [alice], PLANK)
	var nails_before: int = ConstructionTestKit.total(world, [alice], NAIL)

	# A part of what is needed.
	var first: ActionResult = service.try_deliver(world, alice.player_id, wall_id, planks, 3)
	assert_true(first.ok, first.reason)
	var three_planks: Dictionary[String, int] = {PLANK: 3}
	assert_eq(structure.delivered_materials, three_planks)
	assert_eq(ConstructionTestKit.carried(world, alice, PLANK), 7)
	assert_eq(first.event["event_type"], BuildingService.EVENT_CHANGED)
	assert_eq(first.event["cause"], BuildingService.CAUSE_MATERIALS)
	assert_eq(first.event["delivered_now"], {PLANK: 3})
	assert_eq(first.event["delivered"], {PLANK: 3}, "the row everybody gets")
	assert_eq(first.event["player_id"], alice.player_id)
	assert_true(_near(structure.material_share(), 0.5), "3 of 6 units")
	# "As many as needed" from a stack that holds more: only the one missing.
	var second: ActionResult = service.try_deliver(world, alice.player_id, wall_id, planks, BuildingService.AS_MUCH_AS_NEEDED)
	assert_true(second.ok, second.reason)
	assert_eq(second.event["delivered_now"], {PLANK: 1})
	assert_eq(ConstructionTestKit.carried(world, alice, PLANK), 6, "six planks stay with alice")
	# That kind is complete now.
	assert_eq(service.try_deliver(world, alice.player_id, wall_id, planks, 1).reason, BuildingService.REASON_MATERIAL_NOT_NEEDED)
	# Asking for more than is missing takes what is missing.
	var third: ActionResult = service.try_deliver(world, alice.player_id, wall_id, nails, 5)
	assert_true(third.ok, third.reason)
	assert_eq(third.event["delivered_now"], {NAIL: 2})
	assert_eq(ConstructionTestKit.carried(world, alice, NAIL), 3)
	assert_eq(structure.delivered_materials, structure.inventory_costs)
	assert_eq(structure.material_share(), 1.0)
	assert_eq(structure.missing_materials().size(), 0)
	assert_eq(service.try_deliver(world, alice.player_id, wall_id, nails, 1).reason, BuildingService.REASON_MATERIALS_COMPLETE)
	assert_eq(service.try_deliver(world, alice.player_id, wall_id).reason, BuildingService.REASON_MATERIALS_COMPLETE)
	# Delivering is not building: it is still a blueprint with no work done.
	assert_eq(structure.construction_state, StructureInstance.State.BLUEPRINT)
	assert_eq(structure.construction_progress, 0.0)
	# Nothing was created or lost.
	assert_eq(ConstructionTestKit.total(world, [alice], PLANK), planks_before)
	assert_eq(ConstructionTestKit.total(world, [alice], NAIL), nails_before)
	assert_eq(ConstructionTestKit.built_in(world, PLANK), 4)
	# The inventory side: one `items_taken` per delivery, the stacks stay.
	assert_eq(committed.size(), 3)
	for event: Dictionary in committed:
		assert_eq(event["event_type"], InventoryService.EVENT_ITEMS_TAKEN)
		assert_eq(event["inventory_id"], alice.inventory_id)
	assert_eq(committed[0]["taken"], [{"item_instance_id": planks, "definition_id": PLANK, "quantity": 3, "remaining_quantity": 7}])
	assert_eq(world.inventory.get_item(planks).quantity, 6)
	assert_eq(service.drain_events().size(), 3, "one structure event per delivery, none for a refusal")

	# A stack that is used up is gone for good.
	var bob: PlayerState = world.join("bob")
	_give(world, bob, PLANK, 2)
	var bobs_planks: String = ConstructionTestKit.stacks(world, bob, PLANK)[0]
	var floor_id: String = _place(world, bob, FLOOR)
	assert_true(service.try_deliver(world, bob.player_id, floor_id, bobs_planks, 2).ok)
	assert_null(world.inventory.get_item(bobs_planks))
	assert_true(world.registry.is_tombstoned(bobs_planks), "its id is never used again")
	assert_eq(ConstructionTestKit.carried(world, bob, PLANK), 0)
	assert_eq(service.get_structure(floor_id).delivered_materials[PLANK], 2)


func test_one_request_delivers_everything_carried_that_is_needed() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	_give(world, alice, PLANK, 3)
	_give(world, alice, NAIL, 1)
	_give(world, alice, JUNK, 1)
	var wall_id: String = _place(world, alice, WALL)
	var structure: StructureInstance = service.get_structure(wall_id)
	var delivered: ActionResult = service.try_deliver(world, alice.player_id, wall_id)
	assert_true(delivered.ok, delivered.reason)
	assert_eq(delivered.event["delivered_now"], {PLANK: 3, NAIL: 1}, "everything she had of the needed kinds")
	assert_eq(ConstructionTestKit.carried(world, alice, PLANK) + ConstructionTestKit.carried(world, alice, NAIL), 0)
	assert_eq(ConstructionTestKit.carried(world, alice, JUNK), 1, "what the wall does not need stays")
	assert_eq(service.try_deliver(world, alice.player_id, wall_id).reason, BuildingService.REASON_NO_MATERIALS, "she carries nothing it needs any more")
	# Two stacks of one kind: the missing unit comes from the first.
	_give(world, alice, PLANK, 13)
	_give(world, alice, NAIL, 5)
	assert_eq(ConstructionTestKit.stacks(world, alice, PLANK).size(), 2)
	var rest: ActionResult = service.try_deliver(world, alice.player_id, wall_id)
	assert_true(rest.ok, rest.reason)
	assert_eq(rest.event["delivered_now"], {PLANK: 1, NAIL: 1})
	assert_eq(ConstructionTestKit.carried(world, alice, PLANK), 12)
	assert_eq(ConstructionTestKit.carried(world, alice, NAIL), 4)
	assert_eq(structure.delivered_materials, structure.inventory_costs)
	assert_eq(service.try_deliver(world, alice.player_id, wall_id).reason, BuildingService.REASON_MATERIALS_COMPLETE)
	# "Everything" has no quantity.
	var floor_id: String = _place(world, alice, FLOOR)
	assert_eq(service.try_deliver(world, alice.player_id, floor_id, BuildingService.ANY_CARRIED_ITEM, 1).reason, InventoryService.REASON_BAD_QUANTITY)
	assert_eq(service.get_structure(floor_id).delivered_materials.size(), 0)


func test_every_delivery_refusal_has_its_own_reason_and_changes_nothing() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	world.leave(carol.player_id)
	for player: PlayerState in [alice, bob]:
		_give(world, player, PLANK, 6)
		_give(world, player, NAIL, 6)
	_give(world, alice, JUNK, 1)
	var planks: String = ConstructionTestKit.stacks(world, alice, PLANK)[0]
	var junk: String = ConstructionTestKit.stacks(world, alice, JUNK)[0]
	var bobs_planks: String = ConstructionTestKit.stacks(world, bob, PLANK)[0]
	var lying: String = world.inventory.spawn_world_item(PLANK, 4, "cell_0_0", SPAWN)
	var wall_id: String = _place(world, alice, WALL)
	var done_id: String = _place(world, alice, FLOOR)
	assert_true(service.complete_structure(world, done_id).ok)
	service.drain_events()
	# Materials leave an inventory as `items_taken` (bob's death below drops
	# what he carries: another transaction).
	var committed: Array[int] = [0]
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void:
		if event["event_type"] == InventoryService.EVENT_ITEMS_TAKEN:
			committed[0] += 1)
	var alice_id: String = alice.player_id
	# Who asks.
	assert_eq(service.try_deliver(world, "player_999999", wall_id, planks, 1).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_eq(service.try_deliver(world, carol.player_id, wall_id).reason, ServerWorld.REASON_NOT_ONLINE, "a player who left")
	assert_true(_survival(world).start_rest(alice_id).ok)
	assert_eq(service.try_deliver(world, alice_id, wall_id, planks, 1).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_true(_survival(world).stop_rest(alice_id).ok)
	# What it is delivered to.
	assert_eq(service.try_deliver(world, alice_id, "structure_999999", planks, 1).reason, BuildingService.REASON_UNKNOWN_STRUCTURE)
	assert_eq(service.try_deliver(world, alice_id, done_id, planks, 1).reason, BuildingService.REASON_NOT_UNDER_CONSTRUCTION, "a finished piece takes nothing")
	# Where the player is: the server position decides.
	alice.position = Vector3(6.0 + _building_settings.deliver_range_m + 0.1, 0.0, 5.5)
	assert_eq(service.try_deliver(world, alice_id, wall_id, planks, 1).reason, BuildingService.REASON_TOO_FAR)
	alice.position = SPAWN
	# What is delivered: only what the player carries.
	assert_eq(service.try_deliver(world, alice_id, wall_id, "item_999999", 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "an item nobody has")
	assert_eq(service.try_deliver(world, alice_id, wall_id, lying, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "an item lying in the world")
	assert_eq(service.try_deliver(world, alice_id, wall_id, bobs_planks, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "bob's planks, named by alice")
	assert_eq(service.try_deliver(world, alice_id, wall_id, junk, 1).reason, BuildingService.REASON_MATERIAL_NOT_NEEDED, "the wall needs no junk")
	assert_eq(service.try_deliver(world, alice_id, wall_id, planks, -1).reason, InventoryService.REASON_BAD_QUANTITY)
	assert_eq(service.try_deliver(world, alice_id, wall_id, planks, 7).reason, InventoryService.REASON_BAD_QUANTITY, "more than the stack holds")
	assert_eq(service.try_deliver(world, alice_id, wall_id, planks, 2000000000).reason, InventoryService.REASON_BAD_QUANTITY)
	# A dead character delivers nothing.
	_kill(world, bob)
	assert_eq(service.try_deliver(world, bob.player_id, wall_id, bobs_planks, 1).reason, SurvivalService.REASON_PLAYER_DEAD)
	# Nothing changed anywhere.
	assert_eq(service.get_structure(wall_id).delivered_materials.size(), 0)
	assert_eq(ConstructionTestKit.carried(world, alice, PLANK), 6)
	assert_eq(ConstructionTestKit.carried(world, alice, JUNK), 1)
	assert_eq(world.inventory.get_item(lying).quantity, 4)
	assert_eq(committed[0], 0, "no materials left any inventory")
	assert_eq(service.drain_events().size(), 0, "and no structure event recorded")


func test_several_players_deliver_to_one_blueprint() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	_give(world, alice, PLANK, 3)
	_give(world, bob, PLANK, 5)
	_give(world, bob, NAIL, 2)
	var wall_id: String = _place(world, alice, WALL)
	var structure: StructureInstance = service.get_structure(wall_id)
	var planks_before: int = ConstructionTestKit.total(world, [alice, bob], PLANK)
	# Bob did not place it; anybody may bring materials.
	assert_eq(service.try_deliver(world, alice.player_id, wall_id).event["delivered_now"], {PLANK: 3})
	assert_eq(service.try_deliver(world, bob.player_id, wall_id).event["delivered_now"], {PLANK: 1, NAIL: 2}, "bob adds only what alice left open")
	assert_eq(structure.delivered_materials, structure.inventory_costs)
	assert_eq(ConstructionTestKit.carried(world, bob, PLANK), 4)
	assert_eq(ConstructionTestKit.total(world, [alice, bob], PLANK), planks_before)


# ------------------------------------------------------------ work

func test_progress_never_exceeds_the_share_of_materials_delivered() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	_give(world, alice, PLANK, 4)
	_give(world, alice, NAIL, 2)
	var planks: String = ConstructionTestKit.stacks(world, alice, PLANK)[0]
	var wall_id: String = _place(world, alice, WALL)
	var structure: StructureInstance = service.get_structure(wall_id)
	# Nothing delivered: nothing can be built (docs/04 §12: a clear failure).
	assert_eq(service.try_set_work(world, alice.player_id, wall_id, true).reason, BuildingService.REASON_MATERIALS_MISSING)
	_run(world, 1.0)
	assert_eq(structure.construction_progress, 0.0)
	# Half of the materials: work stops at one half.
	assert_true(service.try_deliver(world, alice.player_id, wall_id, planks, 3).ok)
	assert_true(service.try_set_work(world, alice.player_id, wall_id, true).ok)
	_run(world, 4.0)
	assert_true(_near(structure.construction_progress, 4.0 / WALL_WORK_SEC), "four seconds of ten: %f" % structure.construction_progress)
	assert_eq(service.work_of(alice.player_id), wall_id)
	service.drain_events()
	_run(world, 3.0)
	assert_eq(structure.construction_progress, 0.5, "docs/04 §5: progress stops where the materials end")
	assert_eq(structure.construction_state, StructureInstance.State.CONSTRUCTING)
	assert_eq(service.work_of(alice.player_id), "", "and the worker is told to stop")
	var events: Array[Dictionary] = service.drain_events()
	var stops: Array[Dictionary] = _events_of(events, BuildingService.EVENT_WORK_STOPPED)
	assert_eq(stops.size(), 1)
	assert_eq(stops[0]["reason"], BuildingService.REASON_MATERIALS_MISSING)
	assert_eq(stops[0]["player_id"], alice.player_id)
	assert_eq(stops[0]["structure_id"], wall_id)
	assert_eq(_events_of(events, BuildingService.EVENT_CHANGED, BuildingService.CAUSE_PROGRESS).back()["progress"], 0.5, "the row holds the progress it stopped at")
	assert_eq(service.try_set_work(world, alice.player_id, wall_id, true).reason, BuildingService.REASON_MATERIALS_MISSING)
	_run(world, 2.0)
	assert_eq(structure.construction_progress, 0.5, "nothing moves without materials")
	# The rest arrives: the work can go on to the end.
	assert_true(service.try_deliver(world, alice.player_id, wall_id).ok)
	assert_eq(structure.material_share(), 1.0)
	assert_true(service.try_set_work(world, alice.player_id, wall_id, true).ok)
	_run(world, 5.5)
	assert_eq(structure.construction_progress, 1.0)
	assert_eq(structure.construction_state, StructureInstance.State.COMPLETED)


func test_work_follows_action_time_the_handling_multiplier_and_the_number_of_workers() -> void:
	var results: Dictionary[float, float] = {}
	for scale: float in [1.0, 24.0]:
		_clock_settings = WorldClockSettings.new()
		_clock_settings.time_scale = scale
		var world: ServerWorld = _world()
		var service: BuildingService = _building(world)
		var survival: SurvivalService = _survival(world)
		var alice: PlayerState = world.join("alice")
		var bob: PlayerState = world.join("bob")
		var alone: String = _place(world, alice, FREE_WALL, EAST)
		var hurt: String = _place(world, alice, FREE_WALL, WEST)
		var together: String = _place(world, alice, FREE_WALL, NORTH)
		# An unhurt, rested worker does one second of work per second.
		assert_eq(survival.handling_multiplier(alice.player_id), 1.0)
		assert_true(service.try_set_work(world, alice.player_id, alone, true).ok)
		_run(world, 2.0)
		assert_true(_near(service.get_structure(alone).construction_progress, 2.0 / WALL_WORK_SEC), "scale %f: %f" % [scale, service.get_structure(alone).construction_progress])
		results[scale] = service.get_structure(alone).construction_progress
		assert_true(service.try_set_work(world, alice.player_id, alone, false).ok)
		# A wounded arm: the same multiplier that weakens a melee hit.
		assert_true(survival.apply_damage(bob.player_id, DamageInput.create("test_source", BodyPart.Part.RIGHT_ARM, Wound.Type.BRUISE, 20.0)).ok)
		var handling: float = survival.handling_multiplier(bob.player_id)
		assert_true(handling < 0.95 and handling > 0.0, "bob's arm is hurt: %f" % handling)
		assert_true(service.try_set_work(world, bob.player_id, hurt, true).ok)
		var expected: float = 0.0
		for tick: int in range(20):
			world.step_systems(TICK)
			expected += TICK * survival.handling_multiplier(bob.player_id) / WALL_WORK_SEC
		assert_true(_near(service.get_structure(hurt).construction_progress, expected), "work x handling: %f, expected %f" % [service.get_structure(hurt).construction_progress, expected])
		assert_true(service.get_structure(hurt).construction_progress < 1.0 / WALL_WORK_SEC * 0.96, "slower than an unhurt worker")
		# Two workers on one piece add up.
		assert_true(service.try_set_work(world, alice.player_id, together, true).ok)
		assert_true(service.try_set_work(world, bob.player_id, together, true).ok, "bob switches to the third wall")
		assert_eq(service.workers_of(together), PackedStringArray([alice.player_id, bob.player_id]))
		assert_eq(service.workers_of(hurt).size(), 0)
		expected = 0.0
		for tick: int in range(20):
			world.step_systems(TICK)
			expected += TICK * (1.0 + survival.handling_multiplier(bob.player_id)) / WALL_WORK_SEC
		assert_true(_near(service.get_structure(together).construction_progress, expected), "both: %f, expected %f" % [service.get_structure(together).construction_progress, expected])
		assert_true(service.get_structure(together).construction_progress > 1.0 / WALL_WORK_SEC, "faster than one worker")
	assert_true(_near(results[1.0], results[24.0]), "docs/00 ADR-006: building is action time, the calendar scale does not matter")


func test_every_refusal_to_start_or_stop_work_has_its_own_reason() -> void:
	_building_settings.max_workers_per_structure = 2
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var dave: PlayerState = world.join("dave")
	world.leave(dave.player_id)
	var wall_id: String = _place(world, alice, ENDLESS_WALL, EAST)
	var costly_id: String = _place(world, alice, WALL, WEST)
	var done_id: String = _place(world, alice, FREE_WALL, NORTH)
	assert_true(service.complete_structure(world, done_id).ok)
	service.drain_events()
	var alice_id: String = alice.player_id
	assert_eq(service.try_set_work(world, "player_999999", wall_id, true).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_eq(service.try_set_work(world, dave.player_id, wall_id, true).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_true(_survival(world).start_rest(alice_id).ok)
	assert_eq(service.try_set_work(world, alice_id, wall_id, true).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_true(_survival(world).stop_rest(alice_id).ok)
	assert_eq(service.try_set_work(world, alice_id, "structure_999999", true).reason, BuildingService.REASON_UNKNOWN_STRUCTURE)
	assert_eq(service.try_set_work(world, alice_id, done_id, true).reason, BuildingService.REASON_NOT_UNDER_CONSTRUCTION)
	assert_eq(service.try_set_work(world, alice_id, costly_id, true).reason, BuildingService.REASON_MATERIALS_MISSING)
	alice.position = Vector3(6.0 + _building_settings.work_range_m + 0.1, 0.0, 5.5)
	assert_eq(service.try_set_work(world, alice_id, wall_id, true).reason, BuildingService.REASON_TOO_FAR, "the server position decides")
	alice.position = SPAWN
	assert_eq(service.drain_events().size(), 0, "a refusal records nothing")
	assert_eq(service.worker_count(), 0)
	# Stopping what was never started.
	assert_eq(service.try_set_work(world, alice_id, wall_id, false).reason, BuildingService.REASON_NOT_WORKING)
	assert_true(service.try_set_work(world, alice_id, wall_id, true).ok)
	assert_eq(service.try_set_work(world, alice_id, wall_id, true).reason, BuildingService.REASON_ALREADY_WORKING)
	assert_eq(service.try_set_work(world, alice_id, costly_id, false).reason, BuildingService.REASON_NOT_WORKING, "she works on the other wall")
	assert_eq(service.try_set_work(world, alice_id, "", false).reason, BuildingService.REASON_NOT_WORKING)
	assert_eq(service.try_set_work(world, dave.player_id, wall_id, false).reason, ServerWorld.REASON_NOT_ONLINE)
	# The crew is full.
	assert_true(service.try_set_work(world, bob.player_id, wall_id, true).ok)
	assert_eq(service.try_set_work(world, carol.player_id, wall_id, true).reason, BuildingService.REASON_TOO_MANY_WORKERS)
	assert_eq(service.workers_of(wall_id), PackedStringArray([alice_id, bob.player_id]))
	assert_eq(service.worker_rows(), [[alice_id, wall_id], [bob.player_id, wall_id]])
	# A dead character does not start.
	_kill(world, carol)
	assert_eq(service.try_set_work(world, carol.player_id, wall_id, true).reason, SurvivalService.REASON_PLAYER_DEAD)


func test_every_reason_work_stops() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var wall_id: String = _place(world, alice, ENDLESS_WALL, EAST)
	var other_id: String = _place(world, alice, ENDLESS_WALL, WEST)
	var structure: StructureInstance = service.get_structure(wall_id)
	var alice_id: String = alice.player_id
	# [what happens, the reason the worker stops with]. Each case starts with
	# alice working and ends with her not working and the wall not moving.
	var cases: Array[Array] = [
		[func() -> void: assert_true(service.try_set_work(world, alice_id, wall_id, false).ok), BuildingService.STOP_REQUESTED],
		[func() -> void: alice.position = FAR_AWAY, BuildingService.REASON_TOO_FAR],
		[func() -> void: assert_true(survival.start_rest(alice_id).ok), SurvivalService.REASON_PLAYER_RESTING],
		[func() -> void: assert_true(service.try_set_work(world, alice_id, other_id, true).ok), BuildingService.STOP_SWITCHED],
		[func() -> void: service.stop_work(alice_id, "server_rule"), "server_rule"],
		[func() -> void: world.leave(alice_id), ServerWorld.REASON_NOT_ONLINE],
	]
	for case: Array in cases:
		var reason: String = case[1]
		assert_true(service.try_set_work(world, alice_id, wall_id, true).ok, "before %s" % reason)
		_run(world, 1.0)
		service.drain_events()
		(case[0] as Callable).call()
		_run(world, TICK)
		var events: Array[Dictionary] = service.drain_events()
		var stops: Array[Dictionary] = _events_of(events, BuildingService.EVENT_WORK_STOPPED)
		assert_eq(stops.size(), 1, reason)
		if stops.size() == 1:
			assert_eq(stops[0]["reason"], reason)
			assert_eq(stops[0]["player_id"], alice_id)
			assert_eq(stops[0]["structure_id"], wall_id)
			assert_eq(stops[0]["cell_id"], "cell_0_0")
		assert_false(service.workers_of(wall_id).has(alice_id), reason)
		# The last worker left: the row with the exact progress came first.
		var rows: Array[Dictionary] = []
		for row: Dictionary in _events_of(events, BuildingService.EVENT_CHANGED, BuildingService.CAUSE_PROGRESS):
			if row["structure_id"] == wall_id:
				rows.append(row)
		assert_true(rows.size() >= 1 and rows.back()["progress"] == structure.construction_progress, "%s: the clients get the progress it stopped at" % reason)
		var progress: float = structure.construction_progress
		assert_true(progress > 0.0)
		_run(world, 1.0)
		assert_eq(structure.construction_progress, progress, "%s: nobody works, nothing moves" % reason)
		# Back to the start for the next case.
		if survival.is_resting(alice_id):
			assert_true(survival.stop_rest(alice_id).ok)
		if not world.is_online(alice_id):
			alice = world.join("alice")
		if not service.work_of(alice_id).is_empty():
			service.stop_work(alice_id, BuildingService.STOP_REQUESTED)
		alice.position = SPAWN
		service.drain_events()
	# Death, and the piece going away, with two workers.
	assert_true(service.try_set_work(world, alice_id, wall_id, true).ok)
	assert_true(service.try_set_work(world, bob.player_id, wall_id, true).ok)
	_run(world, 0.5)
	service.drain_events()
	_kill(world, bob)
	_run(world, TICK)
	var after_death: Array[Dictionary] = _events_of(service.drain_events(), BuildingService.EVENT_WORK_STOPPED)
	assert_eq(after_death.size(), 1)
	assert_eq(after_death[0]["reason"], SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(after_death[0]["player_id"], bob.player_id)
	assert_eq(service.workers_of(wall_id), PackedStringArray([alice_id]), "alice goes on")
	var before: float = structure.construction_progress
	_run(world, 0.5)
	assert_true(structure.construction_progress > before)
	assert_true(service.try_cancel(world, alice_id, wall_id).ok)
	var after_cancel: Array[Dictionary] = service.drain_events()
	assert_eq(_events_of(after_cancel, BuildingService.EVENT_WORK_STOPPED).size(), 1)
	assert_eq(_events_of(after_cancel, BuildingService.EVENT_WORK_STOPPED)[0]["reason"], BuildingService.STOP_REMOVED)
	assert_eq(after_cancel.back()["event_type"], BuildingService.EVENT_REMOVED, "the worker stops before the piece goes")
	assert_eq(service.worker_count(), 0)
	# A cell that leaves memory takes the work on its structures with it.
	assert_true(service.try_set_work(world, alice_id, other_id, true).ok)
	service.drain_events()
	service.release_cell(world, "cell_0_0")
	var after_release: Array[Dictionary] = service.drain_events()
	assert_eq(after_release.size(), 1)
	assert_eq(after_release[0]["reason"], BuildingService.STOP_UNLOADED)
	assert_eq(service.worker_count(), 0)


func test_a_worker_that_leaves_the_world_stops_at_once_even_when_the_clock_stops() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var wall_id: String = _place(world, alice, ENDLESS_WALL)
	var structure: StructureInstance = service.get_structure(wall_id)
	assert_true(service.try_set_work(world, alice.player_id, wall_id, true).ok)
	_run(world, 0.5)
	service.drain_events()
	# The only player leaves: the world clock stops with nobody online, so
	# no tick would ever notice. The work ends with the connection.
	world.leave(alice.player_id)
	assert_eq(service.worker_count(), 0)
	var events: Array[Dictionary] = service.drain_events()
	assert_eq(events.size(), 2, "the row with the progress it stopped at, then the stop")
	assert_eq(events[0]["cause"], BuildingService.CAUSE_PROGRESS)
	assert_eq(events[0]["progress"], structure.construction_progress)
	assert_eq(events[1]["event_type"], BuildingService.EVENT_WORK_STOPPED)
	assert_eq(events[1]["reason"], ServerWorld.REASON_NOT_ONLINE)
	var progress: float = structure.construction_progress
	_run(world, 2.0)
	# Coming back is not working again: she has to ask.
	alice = world.join("alice")
	_run(world, 1.0)
	assert_eq(service.work_of(alice.player_id), "")
	assert_eq(structure.construction_progress, progress, "nothing was built while she was away or after she came back")
	assert_eq(service.drain_events().size(), 0)


func test_every_worker_of_a_piece_stops_in_the_tick_it_is_finished_starved_or_removed() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var crew: Array[PlayerState] = [alice, bob, carol]
	# Finished: three workers, three "work_finished" with the completion.
	var wall_id: String = _place(world, alice, FREE_WALL, EAST)
	for player: PlayerState in crew:
		assert_true(service.try_set_work(world, player.player_id, wall_id, true).ok)
	service.drain_events()
	_run(world, WALL_WORK_SEC / 3.0 + 0.5)
	assert_eq(service.get_structure(wall_id).construction_state, StructureInstance.State.COMPLETED, "three workers, a third of the time")
	var finished: Array[Dictionary] = _events_of(service.drain_events(), BuildingService.EVENT_WORK_STOPPED)
	assert_eq(finished.size(), 3)
	for stop: Dictionary in finished:
		assert_eq(stop["reason"], BuildingService.STOP_FINISHED)
	assert_eq(service.worker_count(), 0, "nobody is left working on a finished wall")
	# The materials run out for both workers at once.
	_give(world, alice, PLANK, 3)
	var costly_id: String = _place(world, alice, WALL, WEST)
	assert_true(service.try_deliver(world, alice.player_id, costly_id).ok)
	assert_true(service.try_set_work(world, alice.player_id, costly_id, true).ok)
	assert_true(service.try_set_work(world, bob.player_id, costly_id, true).ok)
	service.drain_events()
	_run(world, WALL_WORK_SEC / 2.0)
	var starved: Array[Dictionary] = _events_of(service.drain_events(), BuildingService.EVENT_WORK_STOPPED)
	assert_eq(starved.size(), 2)
	for stop: Dictionary in starved:
		assert_eq(stop["reason"], BuildingService.REASON_MATERIALS_MISSING)
	assert_eq(service.get_structure(costly_id).construction_progress, 0.5)
	assert_eq(service.worker_count(), 0)
	# Two of three walk away in one tick; the third goes on.
	var endless_id: String = _place(world, alice, ENDLESS_WALL, NORTH)
	for player: PlayerState in crew:
		assert_true(service.try_set_work(world, player.player_id, endless_id, true).ok)
	var listed: PackedStringArray = service.workers_of(endless_id)
	listed.clear()
	assert_eq(service.workers_of(endless_id).size(), 3, "the list handed out is a copy")
	service.drain_events()
	alice.position = FAR_AWAY
	bob.position = FAR_AWAY
	world.step_systems(TICK)
	var left: Array[Dictionary] = _events_of(service.drain_events(), BuildingService.EVENT_WORK_STOPPED)
	assert_eq(left.size(), 2, "both are noticed in the same tick")
	assert_eq(left[0]["reason"], BuildingService.REASON_TOO_FAR)
	assert_eq(left[1]["reason"], BuildingService.REASON_TOO_FAR)
	assert_eq(service.workers_of(endless_id), PackedStringArray([carol.player_id]))
	var before: float = service.get_structure(endless_id).construction_progress
	_run(world, 1.0)
	assert_true(service.get_structure(endless_id).construction_progress > before, "carol goes on")
	# The piece goes away under two workers.
	alice.position = SPAWN
	bob.position = SPAWN
	assert_true(service.try_set_work(world, bob.player_id, endless_id, true).ok)
	service.drain_events()
	assert_true(service.try_cancel(world, alice.player_id, endless_id).ok)
	var removed: Array[Dictionary] = _events_of(service.drain_events(), BuildingService.EVENT_WORK_STOPPED)
	assert_eq(removed.size(), 2)
	for stop: Dictionary in removed:
		assert_eq(stop["reason"], BuildingService.STOP_REMOVED)
	assert_eq(service.worker_count(), 0)
	assert_eq(service.worker_rows(), [])


# ------------------------------------------------------------ states

func test_blueprint_constructing_completed_and_only_the_completed_piece_blocks() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	_give(world, alice, PLANK, 4)
	_give(world, alice, NAIL, 2)
	var wall_id: String = _place(world, alice, WALL)
	var structure: StructureInstance = service.get_structure(wall_id)
	assert_true(service.try_deliver(world, alice.player_id, wall_id).ok)
	assert_eq(structure.construction_state, StructureInstance.State.BLUEPRINT, "materials alone do not start the construction")
	service.drain_events()
	var started: ActionResult = service.try_set_work(world, alice.player_id, wall_id, true)
	assert_true(started.ok, started.reason)
	assert_eq(started.event["event_type"], BuildingService.EVENT_WORK_STARTED)
	assert_eq(started.event["structure_id"], wall_id)
	assert_eq(structure.construction_state, StructureInstance.State.BLUEPRINT, "asking to work is not work yet")
	# The first bit of work makes it `constructing`, and that is announced.
	world.step_systems(TICK)
	assert_eq(structure.construction_state, StructureInstance.State.CONSTRUCTING)
	var first: Array[Dictionary] = service.drain_events()
	assert_eq(first.size(), 2, "work started, then the row")
	assert_eq(first[1]["event_type"], BuildingService.EVENT_CHANGED)
	assert_eq(first[1]["cause"], BuildingService.CAUSE_PROGRESS)
	assert_eq(first[1]["state"], "constructing")
	assert_true(_near(float(first[1]["progress"]), TICK / WALL_WORK_SEC))
	# Half way: it still blocks nothing and is no wall yet.
	_run(world, 5.0)
	assert_true(_near(structure.construction_progress, 0.5 + TICK / WALL_WORK_SEC))
	assert_false(service.is_edge_blocked(EAST_SLOT))
	assert_eq(world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, SPAWN, Vector3(7.5, 0.0, 5.5)), Vector3(7.5, 0.0, 5.5), "a half built wall lets everybody through")
	assert_eq(structure.health, 0.0)
	# To the end.
	_run(world, 5.0)
	assert_eq(structure.construction_state, StructureInstance.State.COMPLETED)
	assert_eq(structure.construction_progress, 1.0)
	assert_eq(structure.health, 100.0, "full health when it is completed")
	assert_true(service.is_edge_blocked(EAST_SLOT), "the completed wall blocks")
	assert_true(world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, SPAWN, Vector3(7.5, 0.0, 5.5)).x < 6.0)
	assert_eq(service.work_of(alice.player_id), "")
	# Events: far fewer than ticks, in order, and the last one is the completion.
	var events: Array[Dictionary] = service.drain_events()
	var rows: Array[Dictionary] = _events_of(events, BuildingService.EVENT_CHANGED)
	var ticks: int = roundi(WALL_WORK_SEC / TICK)
	assert_true(rows.size() >= 15 and rows.size() <= 25, "about one row per %d%% of progress, not one per tick (%d rows, %d ticks)" % [roundi(_building_settings.progress_event_step * 100.0), rows.size(), ticks])
	var previous: float = 0.0
	for row: Dictionary in rows:
		assert_true(float(row["progress"]) >= previous)
		previous = float(row["progress"])
	assert_eq(rows.back()["cause"], BuildingService.CAUSE_COMPLETED)
	assert_eq(rows.back()["state"], "completed")
	assert_eq(rows.back()["health_fraction"], 1.0)
	assert_eq(rows.back()["delivered"], {PLANK: 4, NAIL: 2}, "the materials stay in the wall")
	var stops: Array[Dictionary] = _events_of(events, BuildingService.EVENT_WORK_STOPPED)
	assert_eq(stops.size(), 1)
	assert_eq(stops[0]["reason"], BuildingService.STOP_FINISHED)
	# A finished piece takes no more work or materials.
	assert_eq(service.try_set_work(world, alice.player_id, wall_id, true).reason, BuildingService.REASON_NOT_UNDER_CONSTRUCTION)
	_run(world, 1.0)
	assert_eq(service.drain_events().size(), 0, "nothing more happens to it")

	# A door can be used only once it is built.
	_give(world, alice, PLANK, 3)
	_give(world, alice, NAIL, 1)
	var door_id: String = _place(world, alice, DOOR, WEST)
	assert_eq(service.try_set_door(world, alice.player_id, door_id, true).reason, BuildingService.REASON_NOT_USABLE)
	assert_true(service.try_deliver(world, alice.player_id, door_id).ok)
	assert_true(service.try_set_work(world, alice.player_id, door_id, true).ok)
	_run(world, ConstructionTestKit.DOOR_WORK_SEC + 0.5)
	assert_eq(service.get_structure(door_id).construction_state, StructureInstance.State.COMPLETED)
	assert_true(service.is_edge_blocked(Vector3i(5, 5, LOW_X)), "a new door is closed")
	assert_true(service.try_set_door(world, alice.player_id, door_id, true).ok)


func test_a_finished_wall_waits_until_nobody_stands_in_its_edge() -> void:
	_building_settings.completion_retry_interval_sec = 0.25
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var wall_id: String = _place(world, alice, FREE_WALL, EAST)
	var structure: StructureInstance = service.get_structure(wall_id)
	# Bob stands 10 cm from the edge the wall will close.
	bob.position = Vector3(6.1, 0.0, 5.5)
	assert_true(service.try_set_work(world, alice.player_id, wall_id, true).ok)
	service.drain_events()
	_run(world, WALL_WORK_SEC + 1.0)
	assert_eq(structure.construction_progress, 1.0, "the work is done")
	assert_eq(structure.construction_state, StructureInstance.State.CONSTRUCTING, "but it does not close on bob")
	assert_false(service.is_edge_blocked(EAST_SLOT))
	assert_eq(service.awaiting_clearance_count(), 1)
	assert_eq(service.work_of(alice.player_id), "", "nobody has to keep working")
	var events: Array[Dictionary] = service.drain_events()
	assert_eq(_events_of(events, BuildingService.EVENT_WORK_STOPPED)[0]["reason"], BuildingService.STOP_FINISHED)
	var rows: Array[Dictionary] = _events_of(events, BuildingService.EVENT_CHANGED)
	assert_eq(rows.back()["progress"], 1.0)
	assert_eq(rows.back()["state"], "constructing", "the clients see: finished, waiting")
	assert_eq(_events_of(events, BuildingService.EVENT_CHANGED, BuildingService.CAUSE_COMPLETED).size(), 0)
	assert_eq(service.try_set_work(world, alice.player_id, wall_id, true).reason, BuildingService.REASON_BLOCKED_BY_ENTITY, "there is nothing left to work on")
	assert_eq(world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, bob.position, Vector3(5.5, 0.0, 5.5)), Vector3(5.5, 0.0, 5.5), "bob can still walk through")
	_run(world, 3.0)
	assert_eq(structure.construction_state, StructureInstance.State.CONSTRUCTING)
	assert_eq(service.drain_events().size(), 0, "waiting records nothing")
	# Bob steps away: the wall completes by itself.
	bob.position = Vector3(8.5, 0.0, 5.5)
	_run(world, 0.5)
	assert_eq(structure.construction_state, StructureInstance.State.COMPLETED)
	assert_true(service.is_edge_blocked(EAST_SLOT))
	assert_eq(service.awaiting_clearance_count(), 0)
	var completed: Array[Dictionary] = service.drain_events()
	assert_eq(completed.size(), 1)
	assert_eq(completed[0]["cause"], BuildingService.CAUSE_COMPLETED)
	assert_eq(service.worker_count(), 0, "and nobody worked for it")

	# The same for a zombie; a piece that blocks nothing never waits.
	var zombie_id: String = str(zombies.spawn_zombie(world, Vector3(4.9, 0.0, 5.5), 0.0).event["zombie_id"])
	var west_id: String = _place(world, alice, FREE_WALL, WEST)
	assert_true(service.try_set_work(world, alice.player_id, west_id, true).ok)
	_run(world, WALL_WORK_SEC + 1.0)
	assert_eq(service.get_structure(west_id).construction_state, StructureInstance.State.CONSTRUCTING, "a zombie stands in the edge")
	assert_eq(service.awaiting_clearance_count(), 1)
	assert_true(zombies.apply_damage_to_zombie(zombie_id, LETHAL_DAMAGE, "test_source").ok)
	_run(world, 0.5)
	assert_eq(service.get_structure(west_id).construction_state, StructureInstance.State.COMPLETED, "a dead zombie is not in the way")
	_give(world, alice, PLANK, 2)
	var floor_id: String = _place(world, alice, FLOOR)
	assert_true(service.try_deliver(world, alice.player_id, floor_id).ok)
	assert_true(service.try_set_work(world, alice.player_id, floor_id, true).ok)
	_run(world, ConstructionTestKit.FLOOR_WORK_SEC + 0.5)
	assert_eq(service.get_structure(floor_id).construction_state, StructureInstance.State.COMPLETED, "a floor completes under the feet of who built it")


# ------------------------------------------------------------ cancel, demolish

func test_a_cancellation_returns_the_delivered_materials_as_world_items() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	_give(world, alice, PLANK, 6)
	_give(world, bob, NAIL, 4)
	var players: Array = [alice, bob]
	var planks_before: int = ConstructionTestKit.total(world, players, PLANK)
	var nails_before: int = ConstructionTestKit.total(world, players, NAIL)
	var wall_id: String = _place(world, alice, WALL)
	assert_true(service.try_deliver(world, alice.player_id, wall_id, ConstructionTestKit.stacks(world, alice, PLANK)[0], 3).ok)
	assert_true(service.try_deliver(world, bob.player_id, wall_id).ok)
	assert_true(service.try_set_work(world, bob.player_id, wall_id, true).ok)
	_run(world, 2.0)
	assert_eq(service.get_structure(wall_id).construction_state, StructureInstance.State.CONSTRUCTING)
	service.drain_events()
	var committed: Array[Dictionary] = []
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void: committed.append(event))
	# Who may: only the placer, alive, awake, in range.
	assert_eq(service.try_cancel(world, bob.player_id, wall_id).reason, BuildingService.REASON_NOT_OWNER, "bob brought nails and worked, but alice placed it")
	assert_eq(service.try_cancel(world, alice.player_id, "structure_999999").reason, BuildingService.REASON_UNKNOWN_STRUCTURE)
	alice.position = Vector3(6.0 + _building_settings.demolish_range_m + 0.1, 0.0, 5.5)
	assert_eq(service.try_cancel(world, alice.player_id, wall_id).reason, BuildingService.REASON_TOO_FAR)
	alice.position = SPAWN
	assert_true(_survival(world).start_rest(alice.player_id).ok)
	assert_eq(service.try_cancel(world, alice.player_id, wall_id).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_true(_survival(world).stop_rest(alice.player_id).ok)
	assert_eq(service.try_demolish(world, alice.player_id, wall_id).reason, BuildingService.REASON_UNDER_CONSTRUCTION, "an unfinished piece is cancelled, not demolished")
	assert_true(service.has_structure(wall_id))
	assert_eq(committed.size(), 0)

	var cancelled: ActionResult = service.try_cancel(world, alice.player_id, wall_id)
	assert_true(cancelled.ok, cancelled.reason)
	assert_eq(cancelled.event["event_type"], BuildingService.EVENT_REMOVED)
	assert_eq(cancelled.event["cause"], BuildingService.CAUSE_CANCELLED)
	assert_eq(cancelled.event["refund"], {PLANK: 3, NAIL: 2}, "everything that was delivered")
	assert_false(service.has_structure(wall_id))
	assert_true(world.registry.is_tombstoned(wall_id), "its id is never used again")
	assert_eq(service.structure_id_at(EAST_SLOT), "", "the slot is free")
	assert_eq(service.work_of(bob.player_id), "", "bob's work ended with it")
	# The materials lie in the world, at the piece, in its cell, as items
	# anybody can pick up.
	var refund_ids: Array = cancelled.event["refund_item_instance_ids"]
	assert_eq(refund_ids.size(), 2)
	var lying: Dictionary = {}
	for item_id: String in refund_ids:
		var item: ItemInstance = world.inventory.get_item(item_id)
		assert_eq(item.location_type, ItemInstance.LOCATION_WORLD)
		assert_eq(item.location_id, "cell_0_0")
		assert_eq(world.cell_index.cell_of(item_id), "cell_0_0", "indexed in the cell like any dropped item")
		assert_eq(world.cell_index.kind_of(item_id), InventoryService.ENTITY_KIND_ITEM)
		assert_eq(world.inventory.world_position_of(item_id), Vector3(6.5, 0.0, 5.5), "the centre of the tile the edge belongs to")
		lying[item.definition_id] = item.quantity
	assert_eq(lying, {PLANK: 3, NAIL: 2})
	assert_eq(committed.size(), 1)
	assert_eq(committed[0]["event_type"], InventoryService.EVENT_ITEMS_DROPPED, "announced like a drop, so the clients get them")
	assert_eq(committed[0]["inventory_id"], "", "no inventory lost anything")
	assert_eq(committed[0]["item_instance_ids"], refund_ids)
	# Exactly conserved.
	assert_eq(ConstructionTestKit.total(world, players, PLANK), planks_before)
	assert_eq(ConstructionTestKit.total(world, players, NAIL), nails_before)
	assert_true(world.try_pickup(alice.player_id, str(refund_ids[0])).ok, "and they can be picked up again")
	assert_eq(ConstructionTestKit.total(world, players, PLANK), planks_before)

	# Nothing delivered: nothing comes back, and no item is made.
	var empty_id: String = _place(world, alice, WALL)
	var items_before: int = world.inventory.item_count()
	var empty: ActionResult = service.try_cancel(world, alice.player_id, empty_id)
	assert_true(empty.ok, empty.reason)
	assert_eq(empty.event["refund"], {})
	assert_eq(empty.event["refund_item_instance_ids"], [])
	assert_eq(world.inventory.item_count(), items_before)


func test_refunds_follow_the_definition_and_never_create_or_lose_a_unit_beyond_it() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var players: Array = [alice]
	_give(world, alice, PLANK, 40)
	_give(world, alice, NAIL, 10)
	var planks: int = ConstructionTestKit.total(world, players, PLANK)
	var nails: int = ConstructionTestKit.total(world, players, NAIL)

	# A definition that returns half on a cancel: 5 planks -> 2, 3 nails -> 1.
	var lossy_id: String = _place(world, alice, LOSSY_WALL)
	assert_true(service.try_deliver(world, alice.player_id, lossy_id).ok)
	var lossy: ActionResult = service.try_cancel(world, alice.player_id, lossy_id)
	assert_true(lossy.ok, lossy.reason)
	assert_eq(lossy.event["refund"], {PLANK: 2, NAIL: 1})
	planks -= 3
	nails -= 2
	assert_eq(ConstructionTestKit.total(world, players, PLANK), planks, "exactly the three planks the rule keeps are gone")
	assert_eq(ConstructionTestKit.total(world, players, NAIL), nails)

	# More units than one stack holds come back as several items.
	var big_id: String = _place(world, alice, BIG_FLOOR)
	assert_true(service.try_deliver(world, alice.player_id, big_id).ok)
	assert_eq(service.get_structure(big_id).delivered_materials[PLANK], ConstructionTestKit.BIG_FLOOR_PLANKS)
	var big: ActionResult = service.try_cancel(world, alice.player_id, big_id)
	assert_true(big.ok, big.reason)
	var sizes: Array = []
	for item_id: String in big.event["refund_item_instance_ids"]:
		sizes.append(world.inventory.get_item(item_id).quantity)
	assert_eq(sizes, [10, 10, 5], "no stack above the item's max_stack")
	assert_eq(ConstructionTestKit.total(world, players, PLANK), planks)

	# A wall built to the end, then demolished: half comes back.
	var wall_id: String = _place(world, alice, WALL)
	assert_true(service.try_deliver(world, alice.player_id, wall_id).ok)
	assert_true(service.try_set_work(world, alice.player_id, wall_id, true).ok)
	_run(world, WALL_WORK_SEC + 0.5)
	assert_eq(service.get_structure(wall_id).construction_state, StructureInstance.State.COMPLETED)
	assert_eq(ConstructionTestKit.total(world, players, PLANK), planks, "building conserves: the planks are in the wall")
	assert_eq(service.try_cancel(world, alice.player_id, wall_id).reason, BuildingService.REASON_NOT_UNDER_CONSTRUCTION, "a finished piece is demolished, not cancelled")
	var demolished: ActionResult = service.try_demolish(world, alice.player_id, wall_id)
	assert_true(demolished.ok, demolished.reason)
	assert_eq(demolished.event["cause"], BuildingService.CAUSE_DEMOLISHED)
	assert_eq(demolished.event["refund"], {PLANK: 2, NAIL: 1}, "half of 4 planks and 2 nails")
	planks -= 2
	nails -= 1
	assert_eq(ConstructionTestKit.total(world, players, PLANK), planks)
	assert_eq(ConstructionTestKit.total(world, players, NAIL), nails)

	# A piece nothing was paid for returns nothing: no unit is ever created.
	var free_id: String = _place(world, alice, WALL)
	assert_true(service.complete_structure(world, free_id).ok)
	var free: ActionResult = service.try_demolish(world, alice.player_id, free_id)
	assert_true(free.ok, free.reason)
	assert_eq(free.event["refund"], {})
	assert_eq(ConstructionTestKit.total(world, players, PLANK), planks)
	# A server rule removes without a refund unless it says otherwise.
	var ruled_id: String = _place(world, alice, WALL)
	assert_true(service.try_deliver(world, alice.player_id, ruled_id).ok)
	assert_eq(service.remove_structure(world, ruled_id).event["refund"], {})
	planks -= 4
	nails -= 2
	assert_eq(ConstructionTestKit.total(world, players, PLANK), planks)
	# (What came back so far lies in the world; she needs new planks.)
	_give(world, alice, PLANK, 10)
	planks += 10
	var kept_id: String = _place(world, alice, WALL)
	assert_true(service.try_deliver(world, alice.player_id, kept_id).ok)
	assert_eq(service.remove_structure(world, kept_id, 100).event["refund"], {PLANK: 4, NAIL: 2})
	assert_eq(ConstructionTestKit.total(world, players, PLANK), planks)
	assert_eq(ConstructionTestKit.total(world, players, NAIL), nails)


# ------------------------------------------------------------ switches, rules

func test_the_dev_switch_still_completes_a_placement_at_once() -> void:
	_building_settings.instant_completion = true
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	_give(world, alice, PLANK, 4)
	var wall_id: String = _place(world, alice, WALL)
	var structure: StructureInstance = service.get_structure(wall_id)
	assert_eq(structure.construction_state, StructureInstance.State.COMPLETED)
	assert_eq(structure.construction_progress, 1.0)
	assert_eq(structure.delivered_materials.size(), 0, "nothing was paid")
	assert_true(service.is_edge_blocked(EAST_SLOT))
	assert_eq(ConstructionTestKit.carried(world, alice, PLANK), 4)
	assert_eq(service.try_deliver(world, alice.player_id, wall_id).reason, BuildingService.REASON_NOT_UNDER_CONSTRUCTION)
	assert_eq(service.try_set_work(world, alice.player_id, wall_id, true).reason, BuildingService.REASON_NOT_UNDER_CONSTRUCTION)
	assert_eq(service.try_demolish(world, alice.player_id, wall_id).event["refund"], {})


func test_a_server_rule_completes_a_piece_unless_somebody_stands_in_its_edge() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var wall_id: String = _place(world, alice, WALL)
	var structure: StructureInstance = service.get_structure(wall_id)
	bob.position = Vector3(6.1, 0.0, 5.5)
	assert_eq(service.complete_structure(world, wall_id).reason, BuildingService.REASON_BLOCKED_BY_ENTITY)
	assert_eq(structure.construction_state, StructureInstance.State.BLUEPRINT, "all or nothing")
	assert_eq(structure.construction_progress, 0.0)
	bob.position = SPAWN
	var endless_id: String = _place(world, alice, ENDLESS_WALL, WEST)
	assert_true(service.try_set_work(world, bob.player_id, endless_id, true).ok)
	service.drain_events()
	var completed: ActionResult = service.complete_structure(world, wall_id)
	assert_true(completed.ok, completed.reason)
	assert_eq(completed.event["cause"], BuildingService.CAUSE_COMPLETED)
	assert_eq(structure.construction_state, StructureInstance.State.COMPLETED)
	assert_true(service.is_edge_blocked(EAST_SLOT))
	assert_eq(structure.delivered_materials.size(), 0)
	assert_eq(service.complete_structure(world, wall_id).reason, BuildingService.REASON_NOT_UNDER_CONSTRUCTION)
	assert_eq(service.complete_structure(world, "structure_999999").reason, BuildingService.REASON_UNKNOWN_STRUCTURE)
	# Its workers stop.
	assert_true(service.complete_structure(world, endless_id).ok)
	assert_eq(service.work_of(bob.player_id), "")
	assert_eq(_events_of(service.drain_events(), BuildingService.EVENT_WORK_STOPPED)[0]["reason"], BuildingService.STOP_FINISHED)
