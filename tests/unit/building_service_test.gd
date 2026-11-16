extends TestCase
## P3-4a: grid structures on the server (docs/04 §2-§4, §10, §12, docs/00
## ADR-024, docs/09 §15.4): definitions, the runtime model, placement and
## every refusal, occupancy, doors, demolition, and the movement of players
## and zombies against walls and doors. World cells and saving:
## building_cell_test.gd. Grid math: structure_grid_test.gd.
## These tests are about pieces that stand: they run with the dev switch
## BuildingSettings.instant_completion on (off by default since P3-5). The
## construction flow: building_construction_test.gd.

const WORLD: String = "building_test_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
const LETHAL_DAMAGE: float = 100000.0
const INPUT_TIMEOUT_MSEC: int = 500
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const SPAWN_TILE: Vector2i = Vector2i(5, 5)
const FLOOR: String = "dev_floor"
const WALL: String = "dev_wall"
const DOOR: String = "dev_door"
const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X
const LOW_Z: int = StructureGrid.Layer.EDGE_LOW_Z

var _building_settings: BuildingSettings = null
var _zombie_settings: ZombieSettings = null
var _sequence: int = 0
var _now_msec: int = 0


func before_each() -> void:
	GameLogger.set_capture(true)
	_building_settings = BuildingSettings.new()
	_building_settings.instant_completion = true
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER
	_sequence = 0
	_now_msec = 0


func after_each() -> void:
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	# from_defaults() hands out shared cached resources: replace, never edit.
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.player_noise = PlayerNoiseSettings.new()
	config.player_noise.footstep_loudness = 0.0
	config.zombie = _zombie_settings
	config.building = _building_settings
	# 10 m cells; everything within 20 m of a player is in memory.
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


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _kill(world: ServerWorld, player: PlayerState) -> void:
	if not _survival(world).apply_damage(player.player_id, DamageInput.create("test_source", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok:
		fail("test setup: lethal damage failed")


func _id(result: ActionResult) -> String:
	return str(result.event.get(BuildingService.KEY_STRUCTURE_ID, ""))


## Pushes one move intent per tick for `seconds` and steps the movement.
func _walk(world: ServerWorld, player: PlayerState, direction: Vector2, seconds: float, tick: float = TICK) -> void:
	for index: int in range(roundi(seconds / tick)):
		_sequence += 1
		_now_msec += 10
		world.set_move_input(player.player_id, _sequence, direction, 0.0, _now_msec)
		world.step_movement(tick, _now_msec, INPUT_TIMEOUT_MSEC)


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _spawn_zombie(world: ServerWorld, position: Vector3, facing: Vector3) -> String:
	return str(_zombies(world).spawn_zombie(world, position, ZombiePerception.yaw_towards(facing, 0.0)).event["zombie_id"])


# ------------------------------------------------------------ data

func test_default_definitions_and_settings_load_and_are_composed() -> void:
	var catalog: StructureCatalog = StructureCatalog.load_directory()
	# P3-3b added the buildable storage box to the shipped definitions.
	assert_eq(catalog.definition_ids(), PackedStringArray([DOOR, FLOOR, "dev_storage_box", WALL]))
	var floor_definition: StructureDefinition = catalog.get_definition(FLOOR)
	var wall: StructureDefinition = catalog.get_definition(WALL)
	var door: StructureDefinition = catalog.get_definition(DOOR)
	assert_true(floor_definition.placement == StructureDefinition.Placement.TILE and not floor_definition.blocks_movement and not floor_definition.is_door)
	assert_true(wall.is_edge() and wall.blocks_movement and not wall.is_door)
	assert_true(door.is_edge() and door.blocks_movement and door.is_door)
	for definition_id: String in catalog.definition_ids():
		assert_eq(catalog.get_definition(definition_id).validate().size(), 0, definition_id)
	assert_true(ResourceLoader.exists(BuildingSettings.DEFAULT_PATH))
	var loaded: BuildingSettings = BuildingSettings.load_or_default()
	assert_eq(loaded.validate().size(), 0, "; ".join(loaded.validate()))
	assert_true(is_equal_approx(loaded.grid_module_m, 1.0), "docs/04 §2: a 1 m module to start with")
	assert_false(loaded.instant_completion, "P3-5: the shipped default is the blueprint flow, the dev rule is a switch")
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var ids: PackedStringArray = ServerComposition.create_world(WORLD, config).system_ids()
	assert_true(ids.has(BuildingService.SYSTEM_ID))
	assert_true(ids.find(BuildingService.SYSTEM_ID) > ids.find(ZombieService.SYSTEM_ID), "after the zombies a placement looks at")
	config.building = null
	assert_true(config.validate().size() > 0, "composition validation knows the building settings")


func test_definitions_and_settings_are_validated() -> void:
	var broken: StructureDefinition = StructureDefinition.new()
	broken.definition_id = "Bad Id"
	broken.placement = StructureDefinition.Placement.TILE
	broken.blocks_movement = true
	broken.is_door = true
	broken.max_health = 0.0
	broken.build_costs = {"Not An Item": 0}
	assert_true(broken.validate().size() >= 5, "; ".join(broken.validate()))
	var catalog: StructureCatalog = StructureCatalog.new()
	assert_eq(catalog.add(broken), ERR_INVALID_DATA)
	var wall: StructureDefinition = StructureDefinition.new()
	wall.definition_id = "test_wall"
	wall.placement = StructureDefinition.Placement.EDGE
	wall.blocks_movement = true
	wall.build_costs = {"missing_item": 2}
	assert_eq(catalog.add(wall), OK)
	assert_eq(catalog.add(wall), ERR_ALREADY_EXISTS)
	assert_eq(catalog.validate_against(ItemCatalog.load_directory()).size(), 1, "a cost must name an item that exists")
	var settings: BuildingSettings = BuildingSettings.new()
	settings.grid_module_m = 0.0
	settings.placement_range_m = -1.0
	settings.blocker_clearance_m = NAN
	settings.max_structures_per_cell = 0
	settings.collision_skin_m = 5.0
	settings.max_pending_events = 0
	assert_true(settings.validate().size() >= 5, "; ".join(settings.validate()))


# ------------------------------------------------------------ placement

func test_a_placed_structure_has_the_required_fields_and_is_completed_at_once() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	world.step_systems(10.0)
	var placed: ActionResult = service.try_place(world, alice.player_id, WALL, Vector2i(6, 5), 1)
	assert_true(placed.ok, placed.reason)
	var structure_id: String = _id(placed)
	assert_true(StructureInstance.is_valid_structure_id(structure_id), structure_id)
	var structure: StructureInstance = service.get_structure(structure_id)
	assert_not_null(structure)
	# docs/04 §4.
	assert_eq(structure.structure_id, structure_id)
	assert_eq(structure.definition_id, WALL)
	assert_eq(structure.owner_shelter_id, "", "no shelters yet")
	assert_eq(structure.cell_id, "cell_0_0")
	assert_eq(structure.tile, Vector2i(6, 5))
	assert_eq(structure.rotation, 1)
	assert_eq(structure.construction_state, StructureInstance.State.COMPLETED, "the dev rule: completed at once")
	assert_true(is_equal_approx(structure.health, StructureCatalog.load_directory().get_definition(WALL).max_health))
	assert_true(is_equal_approx(structure.material_quality, 1.0))
	assert_eq(structure.inventory_costs, StructureCatalog.load_directory().get_definition(WALL).build_costs, "what the definition says it costs")
	assert_eq(structure.delivered_materials.size(), 0, "the dev rule: nothing was paid")
	assert_eq(structure.construction_progress, 1.0)
	assert_eq(structure.connections.size(), 0)
	assert_true(is_equal_approx(structure.last_modified_at, world.clock.world_time_sec) and structure.last_modified_at > 0.0, "calendar world time")
	assert_eq(structure.placed_by, alice.player_id)
	assert_false(structure.door_open)
	# The id is a registered entity of the world, and the structure is in the
	# cell index.
	assert_eq(world.registry.kind_of(structure_id), BuildingService.ENTITY_KIND_STRUCTURE)
	assert_eq(world.cell_index.cell_of(structure_id), "cell_0_0")
	assert_eq(world.cell_index.kind_of(structure_id), BuildingService.ENTITY_KIND_STRUCTURE)
	assert_eq(service.structure_ids(), PackedStringArray([structure_id]))
	assert_eq(service.structure_id_at(Vector3i(7, 5, LOW_X)), structure_id, "the +X side of tile (6, 5) is the edge x = 7")
	assert_true(service.is_edge_blocked(Vector3i(7, 5, LOW_X)))
	# The event is the public row plus who and where; nothing private.
	var events: Array[Dictionary] = service.drain_events()
	assert_eq(events.size(), 1)
	assert_eq(events[0], placed.event)
	assert_eq(events[0]["event_type"], BuildingService.EVENT_PLACED)
	assert_eq(events[0]["player_id"], alice.player_id)
	assert_eq(events[0]["cell_id"], "cell_0_0")
	var required: Dictionary = {}
	for item_id: String in structure.inventory_costs:
		required[item_id] = structure.inventory_costs[item_id]
	assert_eq(service.public_row(structure), {"structure_id": structure_id, "definition_id": WALL, "x": 6, "z": 5, "rotation": 1, "state": "completed", "door_open": false, "health_fraction": 1.0, "progress": 1.0, "delivered": {}, "required": required})
	assert_true(SaveService.is_json_safe(events[0]) and SaveService.is_json_safe(structure.to_dict()))
	assert_eq(service.drain_events().size(), 0)


func test_costs_of_the_definition_are_recorded_but_nothing_is_taken() -> void:
	var world: ServerWorld = _world()
	var catalog: StructureCatalog = StructureCatalog.new()
	var crate_wall: StructureDefinition = StructureDefinition.new()
	crate_wall.definition_id = "test_costly_wall"
	crate_wall.placement = StructureDefinition.Placement.EDGE
	crate_wall.blocks_movement = true
	crate_wall.build_costs = {"dev_test_item": 3}
	assert_eq(catalog.add(crate_wall), OK)
	var service: BuildingService = BuildingService.new(BuildingSettings.new(), catalog, world.ids, world.registry, world.clock)
	service.on_registered(world)
	var alice: PlayerState = world.join("alice")
	var before: int = world.inventory.items_in_inventory(alice.inventory_id).size()
	var placed: ActionResult = service.try_place(world, alice.player_id, "test_costly_wall", SPAWN_TILE, 0)
	assert_true(placed.ok, placed.reason)
	var costs: Dictionary[String, int] = {"dev_test_item": 3}
	assert_eq(service.get_structure(_id(placed)).inventory_costs, costs)
	assert_eq(world.inventory.items_in_inventory(alice.inventory_id).size(), before, "P3-4a: materials are neither checked nor taken")


func test_every_placement_refusal_has_its_own_reason_and_changes_nothing() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	world.leave(bob.player_id)
	var ids_before: int = world.ids.get_next_sequence()
	# Who asks.
	assert_eq(service.try_place(world, "player_999999", WALL, SPAWN_TILE, 0).reason, ServerWorld.REASON_NOT_ONLINE, "a player nobody knows")
	assert_eq(service.try_place(world, bob.player_id, WALL, SPAWN_TILE, 0).reason, ServerWorld.REASON_NOT_ONLINE, "a player who left")
	# What is asked.
	assert_eq(service.try_place(world, alice.player_id, "no_such_structure", SPAWN_TILE, 0).reason, BuildingService.REASON_UNKNOWN_DEFINITION)
	assert_eq(service.try_place(world, alice.player_id, WALL, SPAWN_TILE, 4).reason, BuildingService.REASON_BAD_ROTATION)
	assert_eq(service.try_place(world, alice.player_id, WALL, SPAWN_TILE, -1).reason, BuildingService.REASON_BAD_ROTATION)
	assert_eq(service.try_place(world, alice.player_id, WALL, Vector2i(50, 5), 0).reason, BuildingService.REASON_OUT_OF_BOUNDS, "one tile past the play area")
	assert_eq(service.try_place(world, alice.player_id, FLOOR, Vector2i(5, -51), 0).reason, BuildingService.REASON_OUT_OF_BOUNDS)
	assert_eq(service.try_place(world, alice.player_id, FLOOR, Vector2i(2000000000, 5), 0).reason, BuildingService.REASON_OUT_OF_BOUNDS, "far outside any map")
	# Where the player is: the server position decides.
	assert_eq(service.try_place(world, alice.player_id, FLOOR, Vector2i(10, 5), 0).reason, BuildingService.REASON_TOO_FAR, "5 m away with a 4 m range")
	assert_true(service.try_place(world, alice.player_id, FLOOR, Vector2i(9, 5), 0).ok, "4 m away is in range")
	assert_eq(service.try_place(world, alice.player_id, WALL, Vector2i(9, 5), 1).reason, BuildingService.REASON_TOO_FAR, "the far side of that tile is 4.5 m away")
	assert_eq(service.structure_count(), 1)
	# The slot.
	assert_eq(service.try_place(world, alice.player_id, FLOOR, Vector2i(9, 5), 2).reason, BuildingService.REASON_SLOT_OCCUPIED, "another facing is still the same tile")
	# Somebody in the way of a blocking piece.
	assert_eq(service.try_place(world, alice.player_id, WALL, Vector2i(5, 6), 0).reason, "", "0.5 m from the edge z = 6 is clear")
	alice.position = Vector3(5.5, 0.0, 5.2)
	assert_eq(service.try_place(world, alice.player_id, WALL, SPAWN_TILE, 0).reason, BuildingService.REASON_BLOCKED_BY_ENTITY, "the placer stands 0.2 m from the edge z = 5")
	assert_true(service.try_place(world, alice.player_id, FLOOR, SPAWN_TILE, 0).ok, "a floor under one's feet is fine")
	alice.position = SPAWN
	var zombie_id: String = _spawn_zombie(world, Vector3(4.9, 0.0, 5.5), Vector3(-1.0, 0.0, 0.0))
	assert_eq(service.try_place(world, alice.player_id, WALL, SPAWN_TILE, 3).reason, BuildingService.REASON_BLOCKED_BY_ENTITY, "a zombie 0.1 m from the edge x = 5, on the other side of it")
	assert_true(_zombies(world).apply_damage_to_zombie(zombie_id, LETHAL_DAMAGE, "test_source").ok)
	assert_true(service.try_place(world, alice.player_id, WALL, SPAWN_TILE, 3).ok, "a corpse is not in the way")
	assert_eq(world.ids.get_next_sequence(), ids_before + 4 + 1, "four structures and the zombie: a refused request uses no id")
	# The state of the player.
	assert_true(_survival(world).start_rest(alice.player_id).ok)
	assert_eq(service.try_place(world, alice.player_id, FLOOR, Vector2i(4, 5), 0).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_true(_survival(world).stop_rest(alice.player_id).ok)
	_kill(world, alice)
	assert_eq(service.try_place(world, alice.player_id, FLOOR, Vector2i(4, 5), 0).reason, SurvivalService.REASON_PLAYER_DEAD)
	# Four structures exist; the refused requests left nothing.
	assert_eq(service.structure_count(), 4)
	assert_eq(service.drain_events().size(), 4)


func test_cell_limit_and_unloaded_cell_refuse_a_placement() -> void:
	_building_settings.max_structures_per_cell = 2
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	assert_true(service.try_place(world, alice.player_id, FLOOR, Vector2i(5, 5), 0).ok)
	assert_true(service.try_place(world, alice.player_id, FLOOR, Vector2i(6, 5), 0).ok)
	assert_eq(service.try_place(world, alice.player_id, FLOOR, Vector2i(7, 5), 0).reason, BuildingService.REASON_LIMIT, "the cell is full")
	# A server rule cannot build in a cell that is not in memory either: its
	# occupancy is not known.
	assert_false(world.is_cell_loaded("cell_4_4"))
	assert_eq(service.place_structure(world, FLOOR, Vector2i(45, 45), 0).reason, BuildingService.REASON_CELL_NOT_LOADED)
	assert_true(service.place_structure(world, FLOOR, Vector2i(15, 5), 0).ok, "a loaded cell with room, no range for a server rule")
	assert_eq(service.get_structure(service.structure_ids()[2]).placed_by, "")


func test_two_requests_for_one_slot_exactly_one_wins() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	alice.position = Vector3(5.5, 0.0, 5.5)
	bob.position = Vector3(7.5, 0.0, 5.5)
	# The same edge, asked for from its two sides in the same tick.
	var first: ActionResult = service.try_place(world, alice.player_id, WALL, Vector2i(6, 5), 1)
	var second: ActionResult = service.try_place(world, bob.player_id, DOOR, Vector2i(7, 5), 3)
	assert_true(first.ok, "the first request in server order wins")
	assert_eq(second.reason, BuildingService.REASON_SLOT_OCCUPIED)
	assert_eq(service.structure_count(), 1)
	assert_eq(service.get_structure(_id(first)).placed_by, alice.player_id)
	# A floor and the four sides of one tile are five different slots.
	for rotation: int in range(StructureGrid.ROTATION_COUNT):
		var side: ActionResult = service.try_place(world, bob.player_id, WALL, Vector2i(8, 5), rotation)
		# The -X side of tile (8, 5) is the +X side of (7, 5): free.
		assert_true(side.ok, "side %d: %s" % [rotation, side.reason])
	assert_true(service.try_place(world, bob.player_id, FLOOR, Vector2i(8, 5), 0).ok)
	assert_eq(service.structure_count(), 6)
	for rotation: int in range(StructureGrid.ROTATION_COUNT):
		assert_eq(service.try_place(world, bob.player_id, DOOR, Vector2i(8, 5), rotation).reason, BuildingService.REASON_SLOT_OCCUPIED)
	assert_eq(service.blocking_edge_count(), 5)


func test_blueprint_rule_takes_the_slot_but_blocks_nothing() -> void:
	_building_settings.instant_completion = false
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	alice.position = Vector3(5.5, 0.0, 5.02)
	var placed: ActionResult = service.try_place(world, alice.player_id, DOOR, SPAWN_TILE, 0)
	assert_true(placed.ok, "a blueprint may be placed where somebody stands: " + placed.reason)
	var structure: StructureInstance = service.get_structure(_id(placed))
	assert_eq(structure.construction_state, StructureInstance.State.BLUEPRINT)
	assert_true(is_equal_approx(structure.health, 0.0))
	assert_false(structure.is_standing())
	assert_false(service.is_edge_blocked(Vector3i(5, 5, LOW_Z)), "only a standing piece blocks")
	assert_eq(service.try_place(world, alice.player_id, WALL, SPAWN_TILE, 0).reason, BuildingService.REASON_SLOT_OCCUPIED, "but the slot is taken")
	assert_eq(service.try_set_door(world, alice.player_id, structure.structure_id, true).reason, BuildingService.REASON_NOT_USABLE, "a blueprint door cannot be used")
	assert_eq(service.public_row(structure)["state"], "blueprint")
	assert_eq(world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, Vector3(5.5, 0.0, 5.5), Vector3(5.5, 0.0, 4.5)), Vector3(5.5, 0.0, 4.5))


# ------------------------------------------------------------ doors

func test_doors_open_and_close_for_any_living_player_in_range() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var door_id: String = _id(service.try_place(world, alice.player_id, DOOR, SPAWN_TILE, 1))
	var wall_id: String = _id(service.try_place(world, alice.player_id, WALL, SPAWN_TILE, 3))
	var slot: Vector3i = Vector3i(6, 5, LOW_X)
	assert_false(service.get_structure(door_id).door_open, "a new door is closed")
	assert_true(service.is_edge_blocked(slot))
	service.drain_events()
	world.step_systems(5.0)
	# Bob did not place it; he may use it.
	var opened: ActionResult = service.try_set_door(world, bob.player_id, door_id, true)
	assert_true(opened.ok, opened.reason)
	assert_true(service.get_structure(door_id).door_open)
	assert_false(service.is_edge_blocked(slot), "an open door does not block")
	assert_eq(opened.event["event_type"], BuildingService.EVENT_CHANGED)
	assert_eq(opened.event["cause"], BuildingService.CAUSE_DOOR)
	assert_eq(opened.event["player_id"], bob.player_id)
	assert_eq(opened.event["door_open"], true)
	assert_true(is_equal_approx(service.get_structure(door_id).last_modified_at, world.clock.world_time_sec))
	assert_eq(service.try_set_door(world, bob.player_id, door_id, true).reason, BuildingService.REASON_DOOR_ALREADY_IN_STATE, "the wanted state, not a toggle")
	assert_true(service.try_set_door(world, alice.player_id, door_id, false).ok)
	assert_true(service.is_edge_blocked(slot), "closed again")
	assert_eq(service.drain_events().size(), 2)
	# Refusals.
	assert_eq(service.try_set_door(world, alice.player_id, "structure_999999", true).reason, BuildingService.REASON_UNKNOWN_STRUCTURE)
	assert_eq(service.try_set_door(world, alice.player_id, wall_id, true).reason, BuildingService.REASON_NOT_A_DOOR)
	assert_eq(service.try_set_door(world, "player_999999", door_id, true).reason, ServerWorld.REASON_NOT_ONLINE)
	bob.position = Vector3(9.0, 0.0, 5.5)
	assert_eq(service.try_set_door(world, bob.player_id, door_id, true).reason, BuildingService.REASON_TOO_FAR, "3 m from the door with a 2.5 m range")
	bob.position = Vector3(8.4, 0.0, 5.5)
	assert_true(service.try_set_door(world, bob.player_id, door_id, true).ok, "2.4 m is in range")
	# Nobody shuts a door on somebody standing in it.
	alice.position = Vector3(6.1, 0.0, 5.5)
	assert_eq(service.try_set_door(world, bob.player_id, door_id, false).reason, BuildingService.REASON_BLOCKED_BY_ENTITY)
	alice.position = SPAWN
	assert_true(_survival(world).start_rest(bob.player_id).ok)
	assert_eq(service.try_set_door(world, bob.player_id, door_id, false).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_true(_survival(world).stop_rest(bob.player_id).ok)
	_kill(world, bob)
	assert_eq(service.try_set_door(world, bob.player_id, door_id, false).reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_true(service.get_structure(door_id).door_open, "refusals changed nothing")
	# A server rule can use the door without an actor.
	assert_true(service.set_door_open(world, door_id, false).ok)
	assert_eq(service.set_door_open(world, wall_id, false).reason, BuildingService.REASON_NOT_A_DOOR)


func test_a_door_can_start_open_by_setting() -> void:
	_building_settings.door_starts_open = true
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	alice.position = Vector3(5.5, 0.0, 5.02)
	var placed: ActionResult = service.try_place(world, alice.player_id, DOOR, SPAWN_TILE, 0)
	assert_true(placed.ok, "an open door blocks nobody, so it can be placed on somebody: " + placed.reason)
	assert_true(service.get_structure(_id(placed)).door_open)
	assert_false(service.is_edge_blocked(Vector3i(5, 5, LOW_Z)))


# ------------------------------------------------------------ demolition

func test_only_the_placer_demolishes_and_the_id_is_never_used_again() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var wall_id: String = _id(service.try_place(world, alice.player_id, WALL, SPAWN_TILE, 1))
	var slot: Vector3i = Vector3i(6, 5, LOW_X)
	service.drain_events()
	assert_eq(service.try_demolish(world, bob.player_id, wall_id).reason, BuildingService.REASON_NOT_OWNER, "bob did not place it")
	assert_eq(service.try_demolish(world, alice.player_id, "structure_999999").reason, BuildingService.REASON_UNKNOWN_STRUCTURE)
	assert_eq(service.try_demolish(world, "player_999999", wall_id).reason, ServerWorld.REASON_NOT_ONLINE)
	alice.position = Vector3(11.0, 0.0, 5.5)
	assert_eq(service.try_demolish(world, alice.player_id, wall_id).reason, BuildingService.REASON_TOO_FAR, "5 m away with a 4 m range")
	alice.position = SPAWN
	assert_true(_survival(world).start_rest(alice.player_id).ok)
	assert_eq(service.try_demolish(world, alice.player_id, wall_id).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_true(_survival(world).stop_rest(alice.player_id).ok)
	assert_true(service.has_structure(wall_id), "refusals changed nothing")
	var removed: ActionResult = service.try_demolish(world, alice.player_id, wall_id)
	assert_true(removed.ok, removed.reason)
	assert_eq(removed.event["event_type"], BuildingService.EVENT_REMOVED)
	assert_eq(removed.event["structure_id"], wall_id)
	assert_eq(removed.event["player_id"], alice.player_id)
	assert_false(service.has_structure(wall_id))
	assert_eq(service.structure_id_at(slot), "")
	assert_false(service.is_edge_blocked(slot))
	assert_false(world.cell_index.has(wall_id))
	assert_true(world.registry.is_tombstoned(wall_id), "a demolished structure's id is retired")
	assert_eq(service.try_demolish(world, alice.player_id, wall_id).reason, BuildingService.REASON_UNKNOWN_STRUCTURE)
	# The slot is free again; the next structure there is a new entity.
	var again: String = _id(service.try_place(world, bob.player_id, WALL, SPAWN_TILE, 1))
	assert_ne(again, wall_id)
	assert_eq(service.structure_id_at(slot), again)
	# A structure placed by a server rule belongs to nobody.
	var ruled: String = _id(service.place_structure(world, FLOOR, SPAWN_TILE, 0))
	assert_eq(service.try_demolish(world, alice.player_id, ruled).reason, BuildingService.REASON_NOT_OWNER)
	assert_true(service.remove_structure(world, ruled).ok)
	assert_eq(service.remove_structure(world, ruled).reason, BuildingService.REASON_UNKNOWN_STRUCTURE)
	_kill(world, bob)
	assert_eq(service.try_demolish(world, bob.player_id, again).reason, SurvivalService.REASON_PLAYER_DEAD)


func test_pending_events_are_bounded() -> void:
	_building_settings.max_pending_events = 3
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	world.join("alice")
	for x: int in range(5):
		assert_true(service.place_structure(world, FLOOR, Vector2i(x, 5), 0).ok)
	assert_eq(service.dropped_event_count, 2)
	var events: Array[Dictionary] = service.drain_events()
	assert_eq(events.size(), 3)
	assert_eq(events[0]["x"], 2, "the oldest were dropped")


# ------------------------------------------------------------ movement: players

func test_movement_without_structures_is_exactly_as_before() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var expected: Vector3 = SPAWN
	var direction: Vector2 = Vector2(0.6, -0.8)
	for index: int in range(40):
		expected = MovementRules.step(expected, direction, world.gameplay.move_speed_mps, TICK, world.gameplay.world_half_extent_m)
	_walk(world, alice, direction, 2.0)
	assert_eq(alice.position, expected, "bit for bit the same as the movement rule alone")
	# Floors and structures that are not in the way change nothing either.
	var service: BuildingService = _building(world)
	assert_true(service.place_structure(world, FLOOR, Vector2i(6, 3), 0).ok)
	assert_true(service.place_structure(world, WALL, Vector2i(20, 20), 0).ok)
	var bob: PlayerState = world.join("bob")
	_walk(world, bob, direction, 2.0)
	assert_eq(bob.position, expected, "a floor on the way and a wall elsewhere")
	assert_eq(world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, SPAWN, expected), expected)


func test_a_wall_and_a_closed_door_stop_a_player_and_an_open_door_and_a_floor_do_not() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var skin: float = _building_settings.collision_skin_m
	# A wall on the +X side of tile (7, 5): the edge x = 8. A floor before it.
	assert_true(service.place_structure(world, FLOOR, Vector2i(6, 5), 0).ok)
	var wall_id: String = _id(service.place_structure(world, WALL, Vector2i(7, 5), 1, alice.player_id))
	_walk(world, alice, Vector2(1.0, 0.0), 2.0)
	assert_true(absf(alice.position.x - (8.0 - skin)) < 0.0001, "stopped in front of the wall at %s" % str(alice.position))
	assert_true(is_equal_approx(alice.position.z, 5.5))
	_walk(world, alice, Vector2(1.0, 0.0), 1.0)
	assert_true(alice.position.x < 8.0, "pushing on does not get through")
	# Walking away is free.
	_walk(world, alice, Vector2(-1.0, 0.0), 0.5)
	assert_true(absf(alice.position.x - (8.0 - skin - 2.0)) < 0.001, "walked back: %s" % str(alice.position))
	# Replace the wall with a door: closed it stops, open it lets through.
	alice.position = Vector3(7.5, 0.0, 5.5)
	assert_true(service.try_demolish(world, alice.player_id, wall_id).ok)
	var door_id: String = _id(service.try_place(world, alice.player_id, DOOR, Vector2i(7, 5), 1))
	_walk(world, alice, Vector2(1.0, 0.0), 1.0)
	assert_true(absf(alice.position.x - (8.0 - skin)) < 0.0001, "a closed door stops: %s" % str(alice.position))
	assert_true(service.try_set_door(world, alice.player_id, door_id, true).ok)
	_walk(world, alice, Vector2(1.0, 0.0), 0.5)
	assert_true(absf(alice.position.x - (8.0 - skin + 2.0)) < 0.001, "through the open door: %s" % str(alice.position))
	# From the other side, closed again.
	alice.position = Vector3(9.5, 0.0, 5.5)
	assert_true(service.set_door_open(world, door_id, false).ok)
	_walk(world, alice, Vector2(-1.0, 0.0), 1.0)
	assert_true(absf(alice.position.x - (8.0 + skin)) < 0.0001, "stopped on the other side: %s" % str(alice.position))


func test_one_large_step_does_not_tunnel_and_diagonals_do_not_cut_corners() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var skin: float = _building_settings.collision_skin_m
	assert_true(service.place_structure(world, WALL, Vector2i(7, 5), 1).ok)
	# One movement step of 5 s (20 m) through a wall 2.5 m away.
	_walk(world, alice, Vector2(1.0, 0.0), 5.0, 5.0)
	assert_true(absf(alice.position.x - (8.0 - skin)) < 0.0001, "a 20 m step stops at the thin wall: %s" % str(alice.position))
	# A room corner: walls on the +X and the +Z side of tile (5, 5). A diagonal
	# step from the middle of the tile goes exactly through the corner (6, 6).
	assert_true(service.place_structure(world, WALL, SPAWN_TILE, 1).ok)
	assert_true(service.place_structure(world, WALL, SPAWN_TILE, 2).ok)
	alice.position = SPAWN
	_walk(world, alice, Vector2(1.0, 1.0).normalized(), 1.0)
	assert_true(alice.position.x < 6.0 and alice.position.z < 6.0, "the corner holds: %s" % str(alice.position))
	assert_eq(service.grid.tile_of(alice.position), SPAWN_TILE)
	# Diagonally into one wall the player slides along it (the default rule
	# for players) until the next wall.
	alice.position = Vector3(5.2, 0.0, 5.2)
	_walk(world, alice, Vector2(1.0, 0.25).normalized(), 2.0)
	assert_true(alice.position.x < 6.0 and alice.position.x > 6.0 - skin - 0.0001 and alice.position.z < 6.0 and alice.position.z > 6.0 - skin - 0.0001, "slid into the corner: %s" % str(alice.position))
	var resting: Vector3 = alice.position
	_walk(world, alice, Vector2(1.0, 0.25).normalized(), 0.5)
	assert_eq(alice.position, resting, "and rests there without jitter")
	# Outside the room, a diagonal past the outer tip of the corner is free:
	# tile (6, 6) is reachable from (7, 5)... but not from inside the room.
	alice.position = Vector3(6.5, 0.0, 5.5)
	_walk(world, alice, Vector2(-1.0, 0.0), 1.0)
	assert_true(alice.position.x > 6.0, "the room cannot be entered through its wall: %s" % str(alice.position))
	# Sliding is a setting: a mover kind that is not listed just stops.
	var stopped: Vector3 = world.resolve_movement(ZombieService.ENTITY_KIND_ZOMBIE, Vector3(5.2, 0.0, 5.2), Vector3(6.4, 0.0, 5.5))
	var slid: Vector3 = world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, Vector3(5.2, 0.0, 5.2), Vector3(6.4, 0.0, 5.5))
	assert_true(stopped.z < 5.45 and is_equal_approx(slid.z, 5.5), "zombie stops at %s, player slides to %s" % [str(stopped), str(slid)])


# ------------------------------------------------------------ movement: zombies

func test_a_zombie_stops_at_a_wall_and_walks_through_an_open_door() -> void:
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var zombies: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	alice.position = Vector3(9.5, 0.0, 5.5)
	# A door on the edge x = 6 between the zombie and the player, with walls
	# beside it. P3-6 makes the closed door opaque as well as impassable.
	var door_id: String = _id(service.place_structure(world, DOOR, Vector2i(6, 5), 3))
	assert_true(service.place_structure(world, WALL, Vector2i(6, 4), 3).ok)
	assert_true(service.place_structure(world, WALL, Vector2i(6, 6), 3).ok)
	var zombie_id: String = _spawn_zombie(world, Vector3(2.5, 0.0, 5.5), Vector3(1.0, 0.0, 0.0))
	_run(world, 4.0)
	var zombie: ZombieState = zombies.get_zombie(zombie_id)
	assert_eq(zombie.state, ZombieState.State.IDLE, "it cannot see the player through the closed door")
	assert_eq(zombie.position, Vector3(2.5, 0.0, 5.5))
	var blocked_before: int = zombies.obstructed_move_count
	assert_eq(blocked_before, 0, "it does not push against what it cannot see")
	var logged_before: int = GameLogger.captured_lines().size()
	var ai_before: int = zombies.total_ai_update_count
	_run(world, 5.0)
	assert_eq(zombie.position, Vector3(2.5, 0.0, 5.5), "it stays there: %s" % str(zombie.position))
	assert_eq(zombies.obstructed_move_count, blocked_before)
	assert_eq(GameLogger.captured_lines().size(), logged_before, "an unseen player causes no state log")
	assert_true(zombies.total_ai_update_count - ai_before <= 11, "and decides no more often than its AI period: %d" % (zombies.total_ai_update_count - ai_before))
	assert_true(_survival(world).is_alive(alice.player_id))
	# The door opens: the zombie comes through.
	assert_true(service.set_door_open(world, door_id, true).ok)
	_run(world, 2.0)
	assert_true(zombie.position.x > 6.0, "through the open door: %s" % str(zombie.position))


func test_a_walled_in_zombie_gives_up_its_waypoint_and_never_leaves() -> void:
	_zombie_settings.wander_pause_min_sec = 0.1
	_zombie_settings.wander_pause_max_sec = 0.2
	_zombie_settings.sight_range_m = 0.0
	var world: ServerWorld = _world()
	var service: BuildingService = _building(world)
	var zombies: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	# The player stands behind the zombie's back, out of its view cone.
	alice.position = Vector3(5.5, 0.0, 9.5)
	var tile: Vector2i = Vector2i(5, 3)
	var zombie_id: String = _spawn_zombie(world, service.grid.tile_center(tile), Vector3(0.0, 0.0, -1.0))
	for rotation: int in range(StructureGrid.ROTATION_COUNT):
		assert_true(service.place_structure(world, WALL, tile, rotation).ok, "0.5 m from each wall is clear")
	_run(world, 60.0)
	var zombie: ZombieState = zombies.get_zombie(zombie_id)
	assert_eq(service.grid.tile_of(zombie.position), tile, "still inside its four walls: %s" % str(zombie.position))
	assert_true(zombies.obstructed_move_count > 0, "it did walk into them")
	assert_true(zombies.obstructed_move_count < 200, "but gave each waypoint up when it was stopped: %d" % zombies.obstructed_move_count)
	assert_eq(zombie.state, ZombieState.State.IDLE)
