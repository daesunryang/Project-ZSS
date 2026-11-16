extends TestCase
## P3-3b: a player-built storage box follows construction and owns one
## empty linked container only after completion.

const BOX: String = "dev_storage_box"
const WOOD: String = "dev_wood"
const NAILS: String = "dev_nails"
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const TILE: Vector2i = Vector2i(5, 5)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.building = BuildingSettings.new()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 10.0
	config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	config.world_cells.refresh_period_sec = 0.0
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.map_content = null
	return config


func _world() -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world("storage_box_test", _config())
	assert_not_null(world)
	assert_eq(world.seed_new_world(DevWorldSeed.new()), OK)
	return world


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _containers(world: ServerWorld) -> ContainerService:
	return world.get_system(ContainerService.SYSTEM_ID) as ContainerService


func _place(world: ServerWorld, player: PlayerState) -> String:
	var result: ActionResult = _building(world).try_place(world, player.player_id, BOX, TILE, 0)
	assert_true(result.ok, result.reason)
	return str(result.event.get(BuildingService.KEY_STRUCTURE_ID, ""))


func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int) -> void:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, world.cell_id_at(player.position), player.position)
	assert_false(item_id.is_empty())
	assert_true(world.try_pickup(player.player_id, item_id).ok)


func _build(world: ServerWorld, player: PlayerState, structure_id: String) -> void:
	assert_true(_building(world).try_deliver(world, player.player_id, structure_id).ok)
	assert_true(_building(world).try_set_work(world, player.player_id, structure_id, true).ok)
	var definition: StructureDefinition = _config().structures.get_definition(BOX)
	world.step_systems(definition.build_work_sec + 0.1)
	assert_eq(_building(world).get_structure(structure_id).construction_state, StructureInstance.State.COMPLETED)


func _total_units(world: ServerWorld, player: PlayerState, definition_id: String) -> int:
	var total: int = 0
	for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
		if item.definition_id == definition_id:
			total += item.quantity
	for item_id: String in world.inventory.world_item_ids():
		var item: ItemInstance = world.inventory.get_item(item_id)
		if item.definition_id == definition_id:
			total += item.quantity
	for structure_id: String in _building(world).structure_ids():
		total += int(_building(world).get_structure(structure_id).delivered_materials.get(definition_id, 0))
	for container_id: String in _containers(world).container_ids():
		for entry: Dictionary in _containers(world).contents_of(container_id):
			if entry["definition_id"] == definition_id:
				total += int(entry["quantity"])
	return total


func test_blueprint_has_no_container_and_completion_creates_one_empty_linked_container() -> void:
	var shipped: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(shipped.structures.validate_against(shipped.catalog, shipped.container_definitions).size(), 0)
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	_give(world, player, WOOD, 20)
	_give(world, player, NAILS, 20)
	var structure_id: String = _place(world, player)
	assert_eq(_containers(world).container_count(), 0, "a blueprint is not usable as storage")
	assert_eq(str(_building(world).get_structure(structure_id).get("container_id")), "")
	_build(world, player, structure_id)
	assert_eq(_containers(world).container_count(), 1)
	var structure: StructureInstance = _building(world).get_structure(structure_id)
	var container_id: String = str(structure.get("container_id"))
	assert_false(container_id.is_empty())
	var container: ContainerInstance = _containers(world).get_container(container_id)
	assert_not_null(container)
	assert_eq(str(container.get("structure_id")), structure_id)
	assert_eq(_containers(world).contents_of(container_id).size(), 0)


func test_cancel_creates_nothing_and_demolish_refuses_contents_then_removes_empty_container() -> void:
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	_give(world, player, WOOD, 20)
	_give(world, player, NAILS, 20)
	var cancelled_id: String = _place(world, player)
	assert_true(_building(world).try_deliver(world, player.player_id, cancelled_id).ok)
	assert_true(_building(world).try_cancel(world, player.player_id, cancelled_id).ok)
	assert_eq(_containers(world).container_count(), 0)

	var structure_id: String = _place(world, player)
	_build(world, player, structure_id)
	var container_id: String = str(_building(world).get_structure(structure_id).get("container_id"))
	var carried: Array[ItemInstance] = world.inventory.items_in_inventory(player.inventory_id)
	assert_true(_containers(world).try_open(world, player.player_id, container_id).ok)
	assert_true(_containers(world).try_put(world, player.player_id, container_id, carried[0].item_instance_id, 1).ok)
	assert_eq(_total_units(world, player, WOOD), 20)
	assert_eq(_total_units(world, player, NAILS), 20)
	assert_eq(_building(world).try_demolish(world, player.player_id, structure_id).reason, "container_not_empty")
	assert_true(_building(world).has_structure(structure_id))
	assert_true(_containers(world).has_container(container_id))
	var stored_id: String = str(_containers(world).contents_of(container_id)[0]["item_instance_id"])
	assert_true(_containers(world).try_take(world, player.player_id, container_id, stored_id, 1).ok)
	assert_true(_building(world).try_demolish(world, player.player_id, structure_id).ok)
	assert_false(_building(world).has_structure(structure_id))
	assert_false(_containers(world).has_container(container_id))
	assert_true(world.registry.is_tombstoned(structure_id))
	assert_true(world.registry.is_tombstoned(container_id))
	assert_eq(_total_units(world, player, WOOD), 18, "two of four delivered wood units were consumed by the 50% demolition rule")
	assert_eq(_total_units(world, player, NAILS), 19, "one of two delivered nails was consumed")


func test_save_restart_restore_keeps_both_links_and_contents() -> void:
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	_give(world, player, WOOD, 20)
	_give(world, player, NAILS, 20)
	var structure_id: String = _place(world, player)
	_build(world, player, structure_id)
	var container_id: String = str(_building(world).get_structure(structure_id).get("container_id"))
	assert_true(_containers(world).try_open(world, player.player_id, container_id).ok)
	var wood: ItemInstance = world.inventory.items_in_inventory(player.inventory_id)[0]
	assert_true(_containers(world).try_put(world, player.player_id, container_id, wood.item_instance_id, 3).ok)
	var before: Array[Dictionary] = _containers(world).contents_of(container_id)
	var documents: Dictionary = world.to_documents()

	var restored: ServerWorld = ServerComposition.create_world("storage_box_test", _config())
	assert_eq(restored.restore_documents(documents["world_state"], documents["players"], documents["cells"]).size(), 0)
	var restored_structure: StructureInstance = _building(restored).get_structure(structure_id)
	var restored_container: ContainerInstance = _containers(restored).get_container(container_id)
	assert_not_null(restored_structure)
	assert_not_null(restored_container)
	assert_eq(restored_structure.container_id, container_id)
	assert_eq(restored_container.structure_id, structure_id)
	assert_eq(_containers(restored).contents_of(container_id), before)


func test_cell_unload_reload_keeps_both_links_and_contents() -> void:
	var config: CompositionConfig = _config()
	config.world_cells.active_radius_cells = 0
	config.world_cells.preload_radius_cells = 1
	config.world_cells.preload_lookahead_sec = 0.0
	config.world_cells.deactivate_delay_sec = 0.0
	config.world_cells.unload_delay_sec = 0.1
	var world: ServerWorld = ServerComposition.create_world("storage_box_cell_test", config)
	var store: WorldCellStore = WorldCellStore.new()
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	assert_eq(world.seed_new_world(DevWorldSeed.new()), OK)
	var player: PlayerState = world.join("alice")
	_give(world, player, WOOD, 20)
	_give(world, player, NAILS, 20)
	var structure_id: String = _place(world, player)
	_build(world, player, structure_id)
	var container_id: String = _building(world).get_structure(structure_id).container_id
	assert_true(_containers(world).try_open(world, player.player_id, container_id).ok)
	var wood: ItemInstance = world.inventory.items_in_inventory(player.inventory_id)[0]
	assert_true(_containers(world).try_put(world, player.player_id, container_id, wood.item_instance_id, 2).ok)
	var before: Array[Dictionary] = _containers(world).contents_of(container_id)

	player.position = Vector3(45.5, 0.0, 45.5)
	for tick: int in range(20):
		world.step_systems(0.1)
	assert_false(_building(world).has_structure(structure_id))
	assert_false(_containers(world).has_container(container_id))
	assert_false(world.registry.is_tombstoned(structure_id))
	assert_false(world.registry.is_tombstoned(container_id))

	player.position = SPAWN
	for tick: int in range(10):
		world.step_systems(0.1)
	assert_eq(_building(world).get_structure(structure_id).container_id, container_id)
	assert_eq(_containers(world).get_container(container_id).structure_id, structure_id)
	assert_eq(_containers(world).contents_of(container_id), before)
