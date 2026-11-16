extends TestCase
## P3-3 (docs/03 §6, docs/13 §5 and §11, docs/09 §15.3): the map content,
## buildings made of structure pieces with containers inside, is data and is
## placed in a world exactly once, through the server rules of the building
## and the container system. The seeding brings the cells it needs into
## memory, places and releases them again. Server rules only, a memory cell
## store or none, no nodes. Real files and a server restart:
## tests/integration/container_persistence_test.gd.

const WORLD: String = "map_content_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const MAP_ID: String = "dev_test_map"
const KIND_STRUCTURE: String = BuildingService.ENTITY_KIND_STRUCTURE
const KIND_CONTAINER: String = ContainerService.ENTITY_KIND_CONTAINER
## How close to its target a step must end to count as "got through".
const REACHED_M: float = 0.01


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## The shipped composition with the shipped test map and nothing that moves
## by itself. The building settings are the SHIPPED ones on purpose: what a
## server-placed structure starts as is part of what these tests pin.
func _config(content: MapContentDefinition = null) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.preload_lookahead_sec = 0.0
	config.map_content = content if content != null else MapContentDefinition.load_or_null()
	return config


func _world(store: WorldCellStore = null, config: CompositionConfig = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, config if config != null else _config())
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	return world


func _seeded(store: WorldCellStore = null, config: CompositionConfig = null) -> ServerWorld:
	var world: ServerWorld = _world(store, config)
	var error: Error = world.seed_new_world(DevWorldSeed.new())
	if error != OK:
		fail("test setup: the world could not be seeded: " + error_string(error))
	return world


func _map(world: ServerWorld) -> MapContentService:
	return world.get_system(MapContentService.SYSTEM_ID) as MapContentService


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _containers(world: ServerWorld) -> ContainerService:
	return world.get_system(ContainerService.SYSTEM_ID) as ContainerService


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


## A building of the given size with a door in the middle of its -Z side.
func _building_definition(building_id: String, origin: Vector2i, size: Vector2i) -> MapBuildingDefinition:
	var building: MapBuildingDefinition = MapBuildingDefinition.new()
	building.building_id = building_id
	building.building_type = "test"
	building.origin_tile = origin
	building.size_tiles = size
	building.door_side = 0
	building.door_offset = 0
	return building


func _container_placement(definition_id: String, offset: Vector2i) -> MapContainerPlacement:
	var placement: MapContainerPlacement = MapContainerPlacement.new()
	placement.definition_id = definition_id
	placement.tile_offset = offset
	return placement


func _content(buildings: Array[MapBuildingDefinition]) -> MapContentDefinition:
	var content: MapContentDefinition = MapContentDefinition.new()
	content.map_id = "unit_test_map"
	content.buildings = buildings
	return content


# ------------------------------------------------------------ data

func test_the_shipped_test_map_is_valid_data_with_five_to_ten_buildings() -> void:
	var content: MapContentDefinition = MapContentDefinition.load_or_null()
	assert_not_null(content, "the test map is shipped as a resource")
	if content == null:
		return
	assert_eq(content.map_id, MAP_ID)
	assert_eq(content.validate().size(), 0, "; ".join(content.validate()))
	assert_true(content.buildings.size() >= 5 and content.buildings.size() <= 10, "5 to 10 buildings (docs/13 §11): %d" % content.buildings.size())
	var config: CompositionConfig = _config(content)
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var tables_by_type: Dictionary[String, String] = {}
	for building: MapBuildingDefinition in content.buildings:
		assert_true(building.containers.size() >= 1, building.building_id + " has a container inside")
		assert_false(building.building_type.is_empty())
		assert_false(building.loot_table_id.is_empty(), building.building_id + " names its loot table")
		tables_by_type[building.building_type] = building.loot_table_id
		var doors: int = 0
		for piece: Dictionary in MapBuildingPlan.structure_pieces(building):
			if str(piece[MapBuildingPlan.KEY_DEFINITION_ID]) == building.door_definition_id:
				doors += 1
		assert_eq(doors, 1, building.building_id + " has exactly one door")
	var tables: Dictionary[String, bool] = {}
	for building_type: String in tables_by_type:
		tables[tables_by_type[building_type]] = true
	assert_true(tables_by_type.size() >= 4, "several building types")
	assert_true(tables.size() >= 4, "loot tables differ by building type (docs/03 §6)")
	# The buildings stand inside the area the dev zombies do not spawn in, so
	# no zombie stands in a wall's way when a new world is seeded.
	var zombie: ZombieSettings = ZombieSettings.load_or_default()
	var grid: StructureGrid = StructureGrid.new(config.building.grid_module_m)
	for building: MapBuildingDefinition in content.buildings:
		var footprint: Rect2i = MapBuildingPlan.footprint(building)
		for corner: Vector2i in [footprint.position, Vector2i(footprint.end.x, footprint.position.y), Vector2i(footprint.position.x, footprint.end.y), footprint.end]:
			var position: Vector3 = Vector3(float(corner.x) * grid.module_m, 0.0, float(corner.y) * grid.module_m)
			assert_true(position.distance_to(zombie.dev_spawn_center) < zombie.dev_spawn_min_radius_m, building.building_id + " lies inside the zombie-free start area")


func test_a_building_plan_is_floors_walls_and_one_door() -> void:
	var building: MapBuildingDefinition = _building_definition("plan", Vector2i(-2, 5), Vector2i(3, 2))
	building.door_side = 1
	building.door_offset = 1
	building.containers = [_container_placement("dev_crate", Vector2i(2, 0))]
	var pieces: Array[Dictionary] = MapBuildingPlan.structure_pieces(building)
	assert_eq(pieces.size(), 3 * 2 + 2 * (3 + 2))
	assert_eq(MapBuildingPlan.piece_count(building.size_tiles), pieces.size())
	var floors: Dictionary[Vector2i, bool] = {}
	var edges: Dictionary[int, String] = {}
	for piece: Dictionary in pieces:
		var tile: Vector2i = piece[MapBuildingPlan.KEY_TILE]
		var definition_id: String = piece[MapBuildingPlan.KEY_DEFINITION_ID]
		assert_true(MapBuildingPlan.footprint(building).has_point(tile), "every piece is placed from a tile of the building")
		if definition_id == building.floor_definition_id:
			floors[tile] = true
		else:
			edges[StructureGrid.slot_key(StructureGrid.slot_of(StructureDefinition.Placement.EDGE, tile, int(piece[MapBuildingPlan.KEY_ROTATION])))] = definition_id
	assert_eq(floors.size(), 6, "one floor on every tile")
	assert_eq(edges.size(), 10, "one piece on every outer edge, none twice")
	var doors: Array = edges.values().filter(func(id: String) -> bool: return id == building.door_definition_id)
	assert_eq(doors.size(), 1, "one of them is the door")
	var door: Dictionary = MapBuildingPlan.door_piece(building)
	assert_eq(door[MapBuildingPlan.KEY_TILE], Vector2i(0, 6), "the +X side, second tile along z")
	assert_eq(door[MapBuildingPlan.KEY_ROTATION], 1)
	assert_true(pieces.has(door), "the door piece is one of the pieces")
	var grid: StructureGrid = StructureGrid.new(1.0)
	assert_eq(MapBuildingPlan.container_position(building, building.containers[0], grid), Vector3(0.5, 0.0, 5.5), "a container stands at the centre of its tile")
	assert_eq(MapBuildingPlan.container_source_key("m", "plan", 0), "m/plan/0")


func test_map_validation_refuses_content_that_cannot_be_placed() -> void:
	var good: MapContentDefinition = _content([_building_definition("a", Vector2i(10, 10), Vector2i(3, 3)), _building_definition("b", Vector2i(14, 10), Vector2i(3, 3))])
	assert_eq(good.validate().size(), 0, "one tile between two buildings is enough: " + "; ".join(good.validate()))
	var touching: MapContentDefinition = _content([_building_definition("a", Vector2i(10, 10), Vector2i(3, 3)), _building_definition("b", Vector2i(13, 10), Vector2i(3, 3))])
	assert_true(touching.validate().size() > 0, "two buildings may not share a wall")
	var twice: MapContentDefinition = _content([_building_definition("a", Vector2i(10, 10), Vector2i(3, 3)), _building_definition("a", Vector2i(20, 10), Vector2i(3, 3))])
	assert_true(twice.validate().size() > 0, "building ids are unique")
	var bad_door: MapBuildingDefinition = _building_definition("door", Vector2i(10, 10), Vector2i(3, 3))
	bad_door.door_offset = 3
	assert_true(bad_door.validate().size() > 0, "the door must be in the side")
	var outside_container: MapBuildingDefinition = _building_definition("box", Vector2i(10, 10), Vector2i(3, 3))
	outside_container.containers = [_container_placement("dev_crate", Vector2i(3, 0))]
	assert_true(outside_container.validate().size() > 0, "a container stands inside its building")
	var stacked: MapBuildingDefinition = _building_definition("stack", Vector2i(10, 10), Vector2i(3, 3))
	stacked.containers = [_container_placement("dev_crate", Vector2i(1, 1)), _container_placement("dev_cabinet", Vector2i(1, 1))]
	assert_true(stacked.validate().size() > 0, "one container per tile")
	var empty: MapBuildingDefinition = _building_definition("flat", Vector2i(10, 10), Vector2i(0, 3))
	assert_true(empty.validate().size() > 0)
	# Against the definitions and the world.
	var config: CompositionConfig = _config(good)
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var wall_as_floor: MapBuildingDefinition = _building_definition("w", Vector2i(10, 10), Vector2i(3, 3))
	wall_as_floor.floor_definition_id = "dev_wall"
	assert_true(_config(_content([wall_as_floor])).validate().size() > 0, "the floor must be a tile piece")
	var floor_as_wall: MapBuildingDefinition = _building_definition("f", Vector2i(10, 10), Vector2i(3, 3))
	floor_as_wall.wall_definition_id = "dev_floor"
	assert_true(_config(_content([floor_as_wall])).validate().size() > 0, "walls must be blocking edge pieces")
	var wall_as_door: MapBuildingDefinition = _building_definition("d", Vector2i(10, 10), Vector2i(3, 3))
	wall_as_door.door_definition_id = "dev_wall"
	assert_true(_config(_content([wall_as_door])).validate().size() > 0, "the door must be a door")
	var unknown_container: MapBuildingDefinition = _building_definition("c", Vector2i(10, 10), Vector2i(3, 3))
	unknown_container.containers = [_container_placement("no_such_container", Vector2i(1, 1))]
	assert_true(_config(_content([unknown_container])).validate().size() > 0)
	var unknown_table: MapBuildingDefinition = _building_definition("t", Vector2i(10, 10), Vector2i(3, 3))
	unknown_table.loot_table_id = "no_such_table"
	unknown_table.containers = [_container_placement("dev_crate", Vector2i(1, 1))]
	assert_true(_config(_content([unknown_table])).validate().size() > 0)
	var off_map: MapBuildingDefinition = _building_definition("o", Vector2i(248, 10), Vector2i(3, 3))
	assert_true(_config(_content([off_map])).validate().size() > 0, "a building lies inside the play area")


func test_compositions_get_no_map_content_unless_they_ask_for_it() -> void:
	assert_null(CompositionConfig.from_defaults().map_content, "tests and tools: no map content by default")
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	assert_eq(world.seed_new_world(config.dev_seed), OK)
	world.join("alice")
	assert_not_null(_map(world), "the system is always registered")
	assert_null(_map(world).content())
	assert_eq(_building(world).structure_count(), 0)
	assert_eq(_containers(world).container_count(), 0)
	assert_false((world.to_documents()["world_state"]["systems"] as Dictionary).has(MapContentService.SYSTEM_ID), "nothing was seeded: nothing is recorded")
	assert_not_null(MapContentDefinition.load_or_null(), "a dedicated server asks for the shipped test map")


# ------------------------------------------------------------ seeding

func test_a_new_world_is_seeded_exactly_once() -> void:
	var content: MapContentDefinition = MapContentDefinition.load_or_null()
	var world: ServerWorld = _seeded()
	var map: MapContentService = _map(world)
	assert_true(map.is_seeded(), "seeding a new world places the map content")
	assert_eq(map.seeded_building_ids(MAP_ID).size(), content.buildings.size())
	assert_eq(_building(world).structure_count(), content.piece_count(), "every floor, wall and door")
	assert_eq(_containers(world).container_count(), content.container_count(), "every container")
	assert_eq(int(map.last_seed_report[MapContentService.REPORT_STRUCTURES]), content.piece_count())
	assert_eq(int(map.last_seed_report[MapContentService.REPORT_SKIPPED_STRUCTURES]), 0)
	# Every container is where its building says, unsearched, with the
	# building's loot table and a source key of its own.
	var grid: StructureGrid = _building(world).grid
	var seen_sources: Dictionary[String, bool] = {}
	for container_id: String in _containers(world).container_ids():
		var container: ContainerInstance = _containers(world).get_container(container_id)
		assert_false(container.searched, "nothing is rolled when the map is seeded")
		assert_false(container.source_key.is_empty())
		seen_sources[container.source_key] = true
	assert_eq(seen_sources.size(), content.container_count())
	var first: MapBuildingDefinition = content.buildings[0]
	var expected_at: Vector3 = MapBuildingPlan.container_position(first, first.containers[0], grid)
	var found: bool = false
	for container_id: String in _containers(world).container_ids():
		var container: ContainerInstance = _containers(world).get_container(container_id)
		if container.position.is_equal_approx(expected_at):
			found = true
			assert_eq(container.definition_id, first.containers[0].definition_id)
			assert_eq(container.loot_table_id, first.loot_table_id, "the building's table, not the definition's own")
	assert_true(found, "the first container stands on its tile")
	# Asking again places nothing: not now, not after a restart.
	var sequence: int = world.ids.get_next_sequence()
	assert_eq(map.ensure_seeded(world), OK)
	assert_eq(world.ids.get_next_sequence(), sequence, "no id was spent: nothing was placed")
	assert_eq(_building(world).structure_count(), content.piece_count())
	var documents: Dictionary = world.to_documents()
	var record: Dictionary = ((documents["world_state"]["systems"] as Dictionary)[MapContentService.SYSTEM_ID] as Dictionary)[MapContentService.KEY_MAPS][MAP_ID]
	assert_true(record[MapContentService.KEY_COMPLETE], "the world state records that the map was seeded")
	assert_eq((record[MapContentService.KEY_BUILDINGS] as Array).size(), content.buildings.size())
	var restored: ServerWorld = _world()
	assert_eq(restored.restore_documents(_json(documents["world_state"]), _json(documents["players"])).size(), 0)
	assert_true(_map(restored).is_seeded())
	assert_eq(_map(restored).ensure_seeded(restored), OK)
	assert_eq(_building(restored).structure_count(), content.piece_count(), "a restart seeds nothing")
	assert_eq(_containers(restored).container_count(), content.container_count())
	assert_eq(restored.ids.get_next_sequence(), sequence)
	assert_eq(_map(restored).last_seed_report.size(), 0, "the restored world never placed anything")


func test_seeded_structures_are_completed_and_block_movement() -> void:
	# The shipped building settings: if a server-placed structure stops being
	# `completed` (blueprints), this test says so.
	var content: MapContentDefinition = MapContentDefinition.load_or_null()
	var world: ServerWorld = _seeded()
	var building: BuildingService = _building(world)
	var grid: StructureGrid = building.grid
	for structure_id: String in building.structure_ids():
		var structure: StructureInstance = building.get_structure(structure_id)
		if structure.construction_state != StructureInstance.State.COMPLETED or not structure.is_standing():
			fail("%s (%s) was seeded as %s, not completed" % [structure_id, structure.definition_id, StructureInstance.state_name(structure.construction_state)])
			return
		assert_eq(structure.placed_by, "", "map structures belong to nobody: no player can demolish them")
		# P3-5: completed by the server rule, without materials or work.
		assert_eq(structure.construction_progress, StructureInstance.FULL_PROGRESS)
		assert_eq(structure.delivered_materials, {}, "no materials went in, so none can ever come back (P3-134)")
	for definition: MapBuildingDefinition in content.buildings:
		var door: Dictionary = MapBuildingPlan.door_piece(definition)
		for piece: Dictionary in MapBuildingPlan.structure_pieces(definition):
			if str(piece[MapBuildingPlan.KEY_DEFINITION_ID]) == definition.floor_definition_id:
				continue
			var tile: Vector2i = piece[MapBuildingPlan.KEY_TILE]
			var rotation: int = piece[MapBuildingPlan.KEY_ROTATION]
			var slot: Vector3i = StructureGrid.slot_of(StructureDefinition.Placement.EDGE, tile, rotation)
			assert_true(building.is_edge_blocked(slot), "%s: every outer edge blocks (the door is closed)" % definition.building_id)
			# A step from the tile inside to the tile outside does not get through.
			var inside: Vector3 = grid.tile_center(tile)
			var outside: Vector3 = grid.tile_center(tile + StructureGrid.SIDE_DIRECTIONS[rotation])
			assert_true(world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, inside, outside).distance_to(outside) > REACHED_M, "%s: a player cannot walk out through %s" % [definition.building_id, str(piece[MapBuildingPlan.KEY_DEFINITION_ID])])
			assert_true(world.resolve_movement(ZombieService.ENTITY_KIND_ZOMBIE, outside, inside).distance_to(inside) > REACHED_M, "%s: a zombie cannot walk in" % definition.building_id)
		# The door opens: that one edge lets a player through, the others do not.
		var door_slot: Vector3i = StructureGrid.slot_of(StructureDefinition.Placement.EDGE, door[MapBuildingPlan.KEY_TILE] as Vector2i, int(door[MapBuildingPlan.KEY_ROTATION]))
		var door_id: String = building.structure_id_at(door_slot)
		assert_false(door_id.is_empty(), definition.building_id + " has its door")
		assert_true(building.set_door_open(world, door_id, true).ok)
		var door_inside: Vector3 = grid.tile_center(door[MapBuildingPlan.KEY_TILE] as Vector2i)
		var door_outside: Vector3 = grid.tile_center((door[MapBuildingPlan.KEY_TILE] as Vector2i) + StructureGrid.SIDE_DIRECTIONS[int(door[MapBuildingPlan.KEY_ROTATION])])
		assert_true(world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, door_outside, door_inside).distance_to(door_inside) <= REACHED_M, definition.building_id + ": the open door is the way in")
		# Inside, nothing is in the way between the door and a container.
		for placement: MapContainerPlacement in definition.containers:
			var at: Vector3 = MapBuildingPlan.container_position(definition, placement, grid)
			assert_true(world.resolve_movement(ServerWorld.ENTITY_KIND_PLAYER, door_inside, at).distance_to(at) <= REACHED_M, definition.building_id + ": the containers can be reached from the door")


func test_a_piece_whose_edge_somebody_stands_in_is_left_out_without_a_trace() -> void:
	# One small building; a player stands right on one of its outer walls
	# while the map is seeded (an existing world started again).
	var definition: MapBuildingDefinition = _building_definition("hut", Vector2i(4, 4), Vector2i(2, 2))
	var buildings: Array[MapBuildingDefinition] = [definition]
	var config: CompositionConfig = _config(_content(buildings))
	var world: ServerWorld = _world(null, config)
	var building: BuildingService = _building(world)
	var pieces: Array[Dictionary] = MapBuildingPlan.structure_pieces(definition)
	var wall: Dictionary = {}
	for piece: Dictionary in pieces:
		if str(piece[MapBuildingPlan.KEY_DEFINITION_ID]) == definition.wall_definition_id:
			wall = piece
			break
	var wall_slot: Vector3i = StructureGrid.slot_of(StructureDefinition.Placement.EDGE, wall[MapBuildingPlan.KEY_TILE] as Vector2i, int(wall[MapBuildingPlan.KEY_ROTATION]))
	var alice: PlayerState = world.join("alice")
	alice.position = building.grid.slot_anchor(wall_slot)
	var sequence_before: int = world.ids.get_next_sequence()
	assert_eq(_map(world).ensure_seeded(world), OK, "a blocked piece does not stop the seeding")
	assert_true(_map(world).is_seeded())
	assert_eq(int(_map(world).last_seed_report[MapContentService.REPORT_SKIPPED_STRUCTURES]), 1, "the wall she stands in is left out")
	assert_eq(building.structure_count(), pieces.size() - 1, "every other piece stands")
	assert_eq(building.structure_id_at(wall_slot), "", "no blueprint is left behind in that edge")
	assert_false(building.is_edge_blocked(wall_slot))
	for structure_id: String in building.structure_ids():
		assert_eq(building.get_structure(structure_id).construction_state, StructureInstance.State.COMPLETED)
	assert_true(world.ids.get_next_sequence() > sequence_before)


func test_seeding_loads_the_cells_it_needs_and_releases_them_again() -> void:
	var content: MapContentDefinition = MapContentDefinition.load_or_null()
	for batch: int in [content.seeding_batch_cells, 1]:
		var batched: MapContentDefinition = content.duplicate() as MapContentDefinition
		batched.seeding_batch_cells = batch
		var store: WorldCellStore = WorldCellStore.new()
		var world: ServerWorld = _seeded(store, _config(batched))
		var map: MapContentService = _map(world)
		var label: String = "batch of %d cells" % batch
		assert_true(map.is_seeded(), label)
		assert_eq(_cells(world).loaded_cell_ids().size(), 0, label + ": no cell stays in memory after the seeding")
		assert_eq(_building(world).structure_count(), 0, label + ": the structures left memory with their cells")
		assert_eq(_containers(world).container_count(), 0, label)
		assert_true(int(map.last_seed_report[MapContentService.REPORT_CELLS_LOADED]) >= 2, label + ": the buildings lie in several cells")
		assert_true(int(map.last_seed_report[MapContentService.REPORT_RELEASES]) >= (1 if batch > 1 else 2), label + ": the cells were saved and released (%d times)" % int(map.last_seed_report[MapContentService.REPORT_RELEASES]))
		assert_true(store.saved_cell_ids().size() >= 2, label)
		# Everything is in the saved cells, once.
		assert_eq(_cells(world).load_all_saved_cells(world).size(), 0)
		assert_eq(_building(world).structure_count(), content.piece_count(), label + ": every piece, none twice")
		assert_eq(_containers(world).container_count(), content.container_count(), label)
		# A building across a cell border is whole.
		var cells_with_structures: Dictionary[String, bool] = {}
		for structure_id: String in _building(world).structure_ids():
			cells_with_structures[world.cell_index.cell_of(structure_id)] = true
		assert_true(cells_with_structures.size() >= 2, label)
		assert_eq(map.ensure_seeded(world), OK)
		assert_eq(_building(world).structure_count(), content.piece_count(), label + ": asking again places nothing")
	# A player who walks to a building finds it.
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _seeded(store)
	assert_eq(_building(world).structure_count(), 0)
	var alice: PlayerState = world.join("alice")
	world.step_systems(TICK)
	assert_eq(_building(world).structure_count(), content.piece_count(), "all buildings are near the spawn point: their cells are in memory now")
	assert_eq(_containers(world).container_count(), content.container_count())
	assert_true(_map(world).is_seeded())
	assert_eq(alice.position, Vector3.ZERO)


func test_a_world_saved_before_the_map_content_gets_it_once() -> void:
	var content: MapContentDefinition = MapContentDefinition.load_or_null()
	# A world played without map content: a player built a wall where a
	# building of the map will stand.
	var old_config: CompositionConfig = _config()
	old_config.map_content = null
	var old_world: ServerWorld = _seeded(null, old_config)
	var alice: PlayerState = old_world.join("alice")
	var first: MapBuildingDefinition = content.buildings[0]
	var taken: Dictionary = MapBuildingPlan.structure_pieces(first)[first.size_tiles.x * first.size_tiles.y]
	var own_wall: ActionResult = _building(old_world).place_structure(old_world, "dev_wall", taken[MapBuildingPlan.KEY_TILE] as Vector2i, int(taken[MapBuildingPlan.KEY_ROTATION]), alice.player_id)
	assert_true(own_wall.ok, own_wall.reason)
	var own_wall_id: String = str(own_wall.event[BuildingService.KEY_STRUCTURE_ID])
	var documents: Dictionary = old_world.to_documents()
	assert_false((documents["world_state"]["systems"] as Dictionary).has(MapContentService.SYSTEM_ID), "the old save knows nothing of map content")
	# The same save, started by a server that has the map content.
	var world: ServerWorld = _world()
	assert_eq(world.restore_documents(_json(documents["world_state"]), _json(documents["players"])).size(), 0, "the old save loads")
	var map: MapContentService = _map(world)
	assert_false(map.is_seeded())
	assert_eq(map.ensure_seeded(world), OK)
	assert_true(map.is_seeded(), "an existing world gets the map content the first time it is started with it")
	assert_eq(int(map.last_seed_report[MapContentService.REPORT_SKIPPED_STRUCTURES]), 1, "the piece whose slot the player's wall takes is left out")
	assert_eq(_building(world).structure_count(), content.piece_count(), "the player's wall stands in for that piece")
	assert_eq(_building(world).get_structure(own_wall_id).placed_by, alice.player_id, "what a player built is not replaced")
	assert_eq(_containers(world).container_count(), content.container_count())
	var sequence: int = world.ids.get_next_sequence()
	assert_eq(map.ensure_seeded(world), OK)
	assert_eq(world.ids.get_next_sequence(), sequence, "once: the second start places nothing")
	# An interrupted seeding goes on where it stopped and doubles nothing:
	# the record says the last building is missing, but it stands already.
	var interrupted: Dictionary = _json(world.to_documents()["world_state"])
	var record: Dictionary = ((interrupted["systems"] as Dictionary)[MapContentService.SYSTEM_ID] as Dictionary)[MapContentService.KEY_MAPS][MAP_ID]
	record[MapContentService.KEY_COMPLETE] = false
	(record[MapContentService.KEY_BUILDINGS] as Array).pop_back()
	var resumed: ServerWorld = _world()
	assert_eq(resumed.restore_documents(interrupted, _json(world.to_documents()["players"])).size(), 0)
	assert_false(_map(resumed).is_seeded())
	assert_eq(_map(resumed).ensure_seeded(resumed), OK)
	var last: MapBuildingDefinition = content.buildings[content.buildings.size() - 1]
	assert_eq(int(_map(resumed).last_seed_report[MapContentService.REPORT_BUILDINGS]), 1, "only the building the record does not list")
	assert_eq(int(_map(resumed).last_seed_report[MapContentService.REPORT_STRUCTURES]), 0)
	assert_eq(int(_map(resumed).last_seed_report[MapContentService.REPORT_SKIPPED_STRUCTURES]), MapBuildingPlan.piece_count(last.size_tiles), "its pieces stand already")
	assert_eq(int(_map(resumed).last_seed_report[MapContentService.REPORT_SKIPPED_CONTAINERS]), last.containers.size(), "and so do its containers")
	assert_eq(_building(resumed).structure_count(), content.piece_count())
	assert_eq(_containers(resumed).container_count(), content.container_count())
	assert_true(_map(resumed).is_seeded())
	# A broken record is refused.
	assert_true(_map(resumed).restore_world_document({"schema_version": 99}).size() > 0)
	assert_true(_map(resumed).restore_world_document({"schema_version": MapContentService.SCHEMA_VERSION, MapContentService.KEY_MAPS: {MAP_ID: {"complete": "yes"}}}).size() > 0)


func test_measure_how_long_seeding_the_test_map_takes() -> void:
	# A measurement of this machine, not a limit (docs/15 §15.3).
	var content: MapContentDefinition = MapContentDefinition.load_or_null()
	var without_store: ServerWorld = _seeded()
	var with_store: ServerWorld = _seeded(WorldCellStore.new())
	var plain: Dictionary = _map(without_store).last_seed_report
	var stored: Dictionary = _map(with_store).last_seed_report
	print("[measure] map seeding (%d buildings, %d structures, %d containers): %.1f ms in memory, %.1f ms with a memory cell store (%d cells loaded, %d release)" % [content.buildings.size(), content.piece_count(), content.container_count(), float(int(plain[MapContentService.REPORT_USEC])) / 1000.0, float(int(stored[MapContentService.REPORT_USEC])) / 1000.0, int(stored[MapContentService.REPORT_CELLS_LOADED]), int(stored[MapContentService.REPORT_RELEASES])])
	assert_eq(int(plain[MapContentService.REPORT_STRUCTURES]), content.piece_count())
	assert_eq(int(stored[MapContentService.REPORT_STRUCTURES]), content.piece_count())
	assert_true(int(plain[MapContentService.REPORT_USEC]) > 0)
