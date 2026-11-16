extends TestCase
## P3-4b pure placement/targeting and Korean building text.

const STRUCTURE_ID: String = "structure_000001"


func after_each() -> void:
	for action: StringName in InputMap.get_actions():
		if not str(action).begins_with("ui_"):
			InputMap.erase_action(action)


func _catalog() -> StructureCatalog:
	return StructureCatalog.load_directory()


func _row(definition_id: String = "dev_wall", tile: Vector2i = Vector2i.ZERO, rotation: int = 0, state: String = "blueprint") -> Array:
	var definition: StructureDefinition = _catalog().get_definition(definition_id)
	return [STRUCTURE_ID, definition_id, tile.x, tile.y, rotation, state, false, 0.0, 0.35, {}, definition.build_costs.duplicate()]


func test_ground_hit_tile_edge_rotation_and_preview_checks_are_pure() -> void:
	var grid: StructureGrid = StructureGrid.new(1.0)
	var catalog: StructureCatalog = _catalog()
	var hit: Variant = BuildModePolicy.ground_hit(Vector3(0.2, 5.0, 0.1), Vector3(0.0, -1.0, 0.0), 0.0, 10.0)
	assert_true(hit is Vector3)
	var wall: Dictionary = BuildModePolicy.placement_at(hit, catalog.get_definition("dev_wall"), grid, 0)
	assert_eq(wall.tile, Vector2i.ZERO)
	assert_eq(wall.rotation, 0, "the hit is nearest the low-Z edge")
	assert_eq(wall.slot, Vector3i(0, 0, StructureGrid.Layer.EDGE_LOW_Z))
	var rotated: Dictionary = BuildModePolicy.placement_at(hit, catalog.get_definition("dev_wall"), grid, 1)
	assert_eq(rotated.rotation, 1)
	assert_eq(rotated.slot, Vector3i(1, 0, StructureGrid.Layer.EDGE_LOW_X))
	var mirror: ClientStructureState = ClientStructureState.new(StructureNetSettings.new(), catalog)
	assert_true(BuildModePolicy.preview_is_valid(wall, mirror, Vector3(0.5, 0.0, 0.5), Vector2(-2.0, -2.0), Vector2(2.0, 2.0), 4.0, 1.0))
	assert_false(BuildModePolicy.preview_is_valid(wall, mirror, Vector3(20.0, 0.0, 20.0), Vector2(-2.0, -2.0), Vector2(2.0, 2.0), 4.0, 1.0), "range is preview-only")
	assert_true(mirror.apply_rows([_row()]) == 1)
	assert_false(BuildModePolicy.preview_is_valid(wall, mirror, Vector3.ZERO, Vector2(-2.0, -2.0), Vector2(2.0, 2.0), 4.0, 1.0), "mirror occupancy makes the ghost red")


func test_build_keys_ranges_and_actions_come_from_the_presentation_resource() -> void:
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	var keys: Dictionary[StringName, Key] = {
		ClientInputActions.BUILD_MODE: shipped.build_mode_key,
		ClientInputActions.BUILD_FLOOR: shipped.build_floor_key,
		ClientInputActions.BUILD_WALL: shipped.build_wall_key,
		ClientInputActions.BUILD_DOOR: shipped.build_door_key,
		ClientInputActions.BUILD_ROTATE: shipped.build_rotate_key,
		ClientInputActions.BUILD_DELIVER: shipped.build_deliver_key,
		ClientInputActions.BUILD_WORK: shipped.build_work_key,
		ClientInputActions.BUILD_REMOVE: shipped.build_remove_key,
	}
	assert_eq(keys.values(), [KEY_L, KEY_1, KEY_2, KEY_3, KEY_PERIOD, KEY_M, KEY_COMMA, KEY_DELETE])
	ClientInputActions.register(CameraSettings.new(), shipped)
	for action: StringName in keys:
		var events: Array[InputEvent] = InputMap.action_get_events(action)
		assert_eq(events.size(), 1, str(action))
		assert_eq((events[0] as InputEventKey).physical_keycode, keys[action], str(action))
	for range_value: float in [shipped.build_preview_range_m, shipped.structure_deliver_target_range_m, shipped.structure_work_target_range_m, shipped.structure_remove_target_range_m, shipped.structure_door_target_range_m, shipped.build_ray_length_m]:
		assert_true(range_value > 0.0)
	var invalid: ClientPresentationSettings = ClientPresentationSettings.new()
	invalid.build_mode_key = invalid.build_floor_key
	assert_eq(invalid.validate().size(), 1, "; ".join(invalid.validate()))


func test_camera_target_requires_both_aim_and_local_reach() -> void:
	var catalog: StructureCatalog = _catalog()
	var mirror: ClientStructureState = ClientStructureState.new(StructureNetSettings.new(), catalog)
	assert_eq(mirror.apply_rows([_row("dev_wall", Vector2i.ZERO, 0, "completed")]), 1)
	var grid: StructureGrid = StructureGrid.new(1.0)
	var id: String = BuildModePolicy.target_structure(Vector3(0.5, 2.0, 3.0), Vector3(0.0, -0.55, -1.0), Vector3(0.5, 0.0, 0.5), mirror, grid, 100.0, 4.0, 0.8)
	assert_eq(id, STRUCTURE_ID)
	assert_eq(BuildModePolicy.target_structure(Vector3(0.5, 2.0, 3.0), Vector3(1.0, 0.0, 0.0), Vector3(0.5, 0.0, 0.5), mirror, grid, 100.0, 4.0, 0.8), "")
	assert_eq(BuildModePolicy.target_structure(Vector3(0.5, 2.0, 3.0), Vector3(0.0, -0.55, -1.0), Vector3(20.0, 0.0, 20.0), mirror, grid, 100.0, 4.0, 0.8), "")


func test_material_progress_and_every_building_reason_have_korean_text() -> void:
	var items: ItemCatalog = ItemCatalog.load_directory()
	var text: String = StructurePresentationFormatter.material_text({"dev_wood": 4, "dev_nails": 2}, {"dev_wood": 2}, items)
	assert_true(text.contains("2/4"))
	assert_true(text.contains("0/2"))
	var entry: Dictionary = {ClientStructureState.KEY_STATE: "constructing", ClientStructureState.KEY_PROGRESS: 0.35, ClientStructureState.KEY_REQUIRED: {"dev_wood": 4}, ClientStructureState.KEY_DELIVERED: {"dev_wood": 2}}
	var summary: String = StructurePresentationFormatter.structure_summary(entry, 2, items)
	assert_true(summary.contains("35%"))
	assert_true(summary.contains("작업자 2명"))
	var reasons: PackedStringArray = PackedStringArray([
		"unknown_structure_definition", "bad_rotation", "out_of_bounds", "too_far", "cell_not_loaded", "slot_occupied", "blocked_by_entity", "structure_limit", "structure_id_failed", "unknown_structure", "not_owner", "not_a_door", "structure_not_usable", "door_already_in_state", "building_unavailable", "structure_not_under_construction", "structure_under_construction", "materials_complete", "material_not_needed", "no_materials_carried", "item_not_in_inventory", "unknown_inventory", "nothing_to_move", "bad_offer", "duplicate_item", "unknown_item", "materials_missing", "already_working", "not_working", "too_many_workers", "refund_failed",
	])
	for reason: String in reasons:
		assert_true(StructurePresentationFormatter.REASONS.has(reason), reason)
		assert_false(StructurePresentationFormatter.result_text(false, reason).contains(reason), reason)


func test_structure_visuals_follow_add_change_work_and_remove_signals() -> void:
	var root: Node3D = Node3D.new()
	var catalog: StructureCatalog = _catalog()
	var mirror: ClientStructureState = ClientStructureState.new(StructureNetSettings.new(), catalog)
	var visuals: StructureVisuals = StructureVisuals.new(root, mirror, catalog, ItemCatalog.load_directory(), StructureGrid.new(1.0), ClientPresentationSettings.new())
	assert_eq(mirror.apply_rows([_row()]), 1)
	assert_eq(visuals.count(), 1)
	var node: Node3D = visuals.visual_of(STRUCTURE_ID)
	assert_not_null(node.get_node_or_null(StructureVisuals.LABEL_NAME))
	assert_true(mirror.apply_work_change("player_000001", STRUCTURE_ID, true, ""))
	assert_true((visuals.visual_of(STRUCTURE_ID).get_node(StructureVisuals.LABEL_NAME) as Label3D).text.contains("작업자 1명"))
	assert_eq(mirror.apply_rows([_row("dev_wall", Vector2i.ZERO, 0, "completed")]), 1)
	assert_null(visuals.visual_of(STRUCTURE_ID).get_node_or_null(StructureVisuals.LABEL_NAME))
	assert_eq(mirror.apply_removed([STRUCTURE_ID]), 1)
	assert_eq(visuals.count(), 0)
	root.free()


func test_structure_nodes_are_freed_when_removed_or_dropped_by_a_join() -> void:
	var root: Node3D = Node3D.new()
	var catalog: StructureCatalog = _catalog()
	var mirror: ClientStructureState = ClientStructureState.new(StructureNetSettings.new(), catalog)
	var visuals: StructureVisuals = StructureVisuals.new(root, mirror, catalog, ItemCatalog.load_directory(), StructureGrid.new(1.0), ClientPresentationSettings.new())
	# Leaving the interest of the client arrives as `removed` ids (P3-057):
	# the node is freed, not only forgotten.
	assert_eq(mirror.apply_rows([_row()]), 1)
	var shown: Node3D = visuals.visual_of(STRUCTURE_ID)
	assert_true(is_instance_valid(shown))
	assert_eq(root.get_child_count(), 1)
	assert_eq(mirror.apply_removed([STRUCTURE_ID]), 1)
	assert_false(is_instance_valid(shown), "the removed structure's node is freed")
	assert_eq(root.get_child_count(), 0)
	# A (re)join replaces the mirror without `structure_removed`: what it
	# no longer holds is freed as well.
	assert_eq(mirror.apply_rows([_row()]), 1)
	shown = visuals.visual_of(STRUCTURE_ID)
	assert_true(mirror.apply_join({}))
	assert_false(is_instance_valid(shown), "a structure the join dropped is freed")
	assert_eq(visuals.count(), 0)
	assert_eq(root.get_child_count(), 0)
	root.free()


func test_build_hud_names_e_when_an_aimed_door_takes_it_from_the_pickup() -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var root: Node3D = Node3D.new()
	tree.root.add_child(root)
	var camera: Camera3D = Camera3D.new()
	root.add_child(camera)
	var hud: Label = Label.new()
	var settings: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	ClientInputActions.register(CameraSettings.new(), settings)
	var building: BuildingSettings = BuildingSettings.load_or_default()
	var catalog: StructureCatalog = _catalog()
	var module: StructureNetModule = StructureNetModule.new(StructureNetSettings.new(), catalog)
	var world: ClientWorldState = ClientWorldState.new()
	world.local_player_id = "player_000001"
	var presentation: BuildPresentation = BuildPresentation.new(root, hud, settings, building, catalog, ItemCatalog.load_directory(), module, world)
	var door: Array = _row("dev_door", Vector2i.ZERO, 0, "completed")
	assert_eq(module.client_state.apply_rows([door]), 1)
	var anchor: Vector3 = StructureGrid.new(building.grid_module_m).slot_anchor(module.client_state.slot_of(STRUCTURE_ID))
	camera.position = anchor + Vector3(0.0, 1.5, 1.5)
	camera.look_at(anchor)
	world.players[world.local_player_id] = {"position": anchor + Vector3(0.0, 0.0, 1.0), "yaw": 0.0}
	presentation.tick(camera, null)
	assert_eq(presentation.target_id(), STRUCTURE_ID)
	assert_true(hud.text.contains("문 열기 [E] (줍기보다 먼저)"), hud.text)
	door[ClientStructureState.ROW_DOOR_OPEN] = true
	assert_eq(module.client_state.apply_rows([door]), 1)
	presentation.tick(camera, null)
	assert_true(hud.text.contains("문 닫기 [E]"), hud.text)
	# Out of the door reach (the pickup keeps E): no door line.
	world.players[world.local_player_id] = {"position": anchor + Vector3(0.0, 0.0, settings.structure_door_target_range_m + 0.5), "yaw": 0.0}
	presentation.tick(camera, null)
	assert_false(hud.text.contains("[E]"), hud.text)
	hud.free()
	module.free()
	root.free()
