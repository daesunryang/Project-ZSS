extends TestCase
## P2-T15 client side (docs/09 §14.29, docs/11 §2.13): the inventory cursor,
## the drop keys, the HUD inventory list, the markers of items lying in the
## world, the pickup candidate and the texts. Pure logic plus the marker
## nodes; the client only names an item and a quantity, the server decides
## (tests/unit/ground_transfer_test.gd).

const FOOD_ID: String = "dev_food_ration"
const WATER_ID: String = "dev_water_bottle"
const BANDAGE_ID: String = "dev_bandage"
const EPSILON: float = 0.0001

var _root: Node3D = null


func test_development_item_display_names_are_korean() -> void:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var expected: Dictionary[String, String] = {
		"dev_bandage": "붕대",
		"dev_cure": "치료제",
		"dev_food_ration": "전투식량",
		"dev_water_bottle": "생수",
		"dev_melee_pipe": "쇠파이프",
		"dev_nails": "못",
		"dev_wood": "목재",
		"dev_test_item": "시험용 물건",
	}
	for definition_id: String in expected:
		assert_eq(catalog.get_definition(definition_id).display_name, expected[definition_id], definition_id)


func after_each() -> void:
	if _root != null and is_instance_valid(_root):
		_root.free()
	_root = null
	# Leave no action behind: other tests register them with other settings.
	for action: StringName in InputMap.get_actions():
		if not str(action).begins_with("ui_"):
			InputMap.erase_action(action)


func _entry(item_id: Variant, definition_id: Variant, quantity: Variant, slot: Variant = "slot_0") -> Dictionary:
	return {"schema_version": 1, "item_instance_id": item_id, "definition_id": definition_id, "quantity": quantity, "location_type": "inventory", "location_id": "inventory_000001", "slot_id": slot}


func _inventory() -> Array[Dictionary]:
	# Mirror order is arrival order; the cursor goes by slot number.
	return [
		_entry("item_000007", WATER_ID, 2, "slot_10"),
		_entry("item_000003", FOOD_ID, 3, "slot_0"),
		{"junk": true},
		_entry("item_000005", BANDAGE_ID, 1, "slot_2"),
		_entry("item_000009", FOOD_ID, "many", "slot_1"),
	]


func _world_item(item_id: String, definition_id: String, quantity: int, position: Vector3) -> Dictionary:
	return {"item_instance_id": item_id, "definition_id": definition_id, "quantity": quantity, "position": position}


# ------------------------------------------------------------ the cursor

func test_the_cursor_walks_the_carried_stacks_in_slot_order_and_wraps() -> void:
	var inventory: Array[Dictionary] = _inventory()
	assert_eq(InventorySelectionPolicy.ordered_item_ids(inventory), PackedStringArray(["item_000003", "item_000005", "item_000007"]), "by slot number (slot_2 before slot_10), malformed rows skipped")
	assert_eq(InventorySelectionPolicy.index_of(inventory, "item_000005"), 1)
	assert_eq(InventorySelectionPolicy.index_of(inventory, "item_999999"), -1)
	assert_eq(InventorySelectionPolicy.index_of(inventory, "item_000009"), -1, "a malformed row cannot be selected")
	# Forwards and backwards, wrapping at both ends.
	assert_eq(InventorySelectionPolicy.step(inventory, "item_000003", 1), "item_000005")
	assert_eq(InventorySelectionPolicy.step(inventory, "item_000005", 1), "item_000007")
	assert_eq(InventorySelectionPolicy.step(inventory, "item_000007", 1), "item_000003", "after the last comes the first")
	assert_eq(InventorySelectionPolicy.step(inventory, "item_000003", -1), "item_000007", "before the first comes the last")
	assert_eq(InventorySelectionPolicy.step(inventory, "item_000007", -1), "item_000005")
	assert_eq(InventorySelectionPolicy.step(inventory, "item_000005", 3), "item_000007", "only the direction counts: one step")
	assert_eq(InventorySelectionPolicy.step(inventory, "item_000005", 0), "item_000005", "no direction, no move")
	# Nothing selected yet: forwards starts at the first, backwards at the last.
	assert_eq(InventorySelectionPolicy.step(inventory, "", 1), "item_000003")
	assert_eq(InventorySelectionPolicy.step(inventory, "", -1), "item_000007")
	assert_eq(InventorySelectionPolicy.step(inventory, "item_999999", 1), "item_000003")
	var empty: Array[Dictionary] = []
	assert_eq(InventorySelectionPolicy.step(empty, "item_000003", 1), InventorySelectionPolicy.NO_SELECTION)
	assert_eq(InventorySelectionPolicy.ordered_item_ids(empty).size(), 0)


func test_the_cursor_stays_on_its_item_and_moves_on_when_the_item_is_gone() -> void:
	var inventory: Array[Dictionary] = _inventory()
	assert_eq(InventorySelectionPolicy.resolve(inventory, "item_000005", 0), "item_000005", "the selected item is still there: keep it, whatever its index was")
	assert_eq(InventorySelectionPolicy.resolve(inventory, "", 0), "item_000003", "nothing selected: the first stack")
	# The selected stack left the inventory (put down, used up): the cursor
	# takes the stack that is now at its place, or the last one.
	assert_eq(InventorySelectionPolicy.resolve(inventory, "item_000004", 1), "item_000005")
	assert_eq(InventorySelectionPolicy.resolve(inventory, "item_000004", 2), "item_000007")
	assert_eq(InventorySelectionPolicy.resolve(inventory, "item_000004", 7), "item_000007", "past the end: the last stack")
	assert_eq(InventorySelectionPolicy.resolve(inventory, "item_000004", -3), "item_000003")
	var empty: Array[Dictionary] = []
	assert_eq(InventorySelectionPolicy.resolve(empty, "item_000005", 1), InventorySelectionPolicy.NO_SELECTION, "nothing carried, nothing selected")


func test_how_many_units_a_drop_key_asks_for() -> void:
	var inventory: Array[Dictionary] = _inventory()
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_000003", 1, false), 1, "the configured quantity")
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_000003", 2, false), 2)
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_000003", 5, false), 3, "never more than the mirrored stack holds")
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_000005", 1, false), 1)
	# With the stack modifier: the whole stack as the server knows it.
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_000003", 1, true), InventoryService.WHOLE_STACK)
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_000003", 0, true), InventoryService.WHOLE_STACK, "the unit setting does not matter then")
	# Nothing to ask for.
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_000003", 0, false), InventorySelectionPolicy.NOTHING_TO_DROP)
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_000003", -2, false), InventorySelectionPolicy.NOTHING_TO_DROP)
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_999999", 1, false), InventorySelectionPolicy.NOTHING_TO_DROP, "an item that is not in the mirror")
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_999999", 1, true), InventorySelectionPolicy.NOTHING_TO_DROP)
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "item_000009", 1, false), InventorySelectionPolicy.NOTHING_TO_DROP, "a malformed mirror row")
	assert_eq(InventorySelectionPolicy.drop_quantity(inventory, "", 1, false), InventorySelectionPolicy.NOTHING_TO_DROP, "nothing selected")
	assert_true(InventorySelectionPolicy.NOTHING_TO_DROP < InventoryService.WHOLE_STACK, "\"nothing\" is no quantity the server accepts")


# ------------------------------------------------------------ keys

func test_cursor_and_drop_keys_are_actions_driven_by_settings() -> void:
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	var defaults: ClientPresentationSettings = ClientPresentationSettings.new()
	for property: String in ["select_previous_key", "select_next_key", "drop_key", "drop_stack_modifier_key", "drop_quantity", "drop_min_interval_sec", "pickup_candidate_range_m", "world_item_marker_size_m", "world_item_label_margin_m", "world_item_label_font_size"]:
		assert_eq(defaults.get(property), shipped.get(property), "the script default of %s agrees with the shipped resource" % property)
	assert_eq(shipped.select_previous_key, KEY_Z)
	assert_eq(shipped.select_next_key, KEY_X)
	assert_eq(shipped.drop_key, KEY_Q)
	assert_eq(shipped.drop_stack_modifier_key, KEY_CTRL)
	assert_eq(shipped.drop_quantity, 1, "one unit per key press")
	ClientInputActions.register(CameraSettings.new(), defaults)
	var expected: Dictionary[StringName, Key] = {
		ClientInputActions.SELECT_PREVIOUS: defaults.select_previous_key,
		ClientInputActions.SELECT_NEXT: defaults.select_next_key,
		ClientInputActions.DROP: defaults.drop_key,
		ClientInputActions.DROP_STACK: defaults.drop_stack_modifier_key,
	}
	for action: StringName in expected:
		var events: Array[InputEvent] = InputMap.action_get_events(action)
		assert_eq(events.size(), 1, str(action))
		assert_eq((events[0] as InputEventKey).physical_keycode, expected[action], str(action))
	assert_eq(ClientInputActions.USE_ACTION_KINDS.size(), 4, "the same four use keys")
	# The one-key hand-over is gone: no action, no setting.
	assert_false(InputMap.has_action(&"hand_over"), "no hand-over action is registered")
	for property: Dictionary in defaults.get_property_list():
		assert_false(str(property["name"]).begins_with("hand_over"), "no hand-over setting: " + str(property["name"]))
	# Validation: every key set, at least one unit, and all keys different.
	var invalid: ClientPresentationSettings = ClientPresentationSettings.new()
	invalid.select_previous_key = KEY_NONE
	invalid.select_next_key = KEY_NONE
	invalid.drop_key = KEY_NONE
	invalid.drop_stack_modifier_key = KEY_NONE
	invalid.drop_quantity = 0
	invalid.drop_min_interval_sec = 0.0
	invalid.pickup_candidate_range_m = 0.0
	invalid.world_item_marker_size_m = 0.0
	assert_eq(invalid.validate().size(), 8, "; ".join(invalid.validate()))
	var own: Dictionary[String, Key] = defaults.assigned_keys()
	for changed: String in ["select_previous_key", "select_next_key", "drop_key", "drop_stack_modifier_key"]:
		for other: String in own:
			if other == changed:
				continue
			var shared: ClientPresentationSettings = ClientPresentationSettings.new()
			shared.set(changed, own[other])
			assert_eq(shared.validate().size(), 1, "%s must differ from %s: %s" % [changed, other, "; ".join(shared.validate())])
	# Movement and pickup keys belong to the camera settings: a clash is found.
	var camera: CameraSettings = CameraSettings.load_or_default()
	assert_eq(shipped.keys_shared_with(camera).size(), 0, "the shipped keys do not clash: %s" % ", ".join(shipped.keys_shared_with(camera)))
	var clashing: ClientPresentationSettings = ClientPresentationSettings.new()
	clashing.drop_key = camera.pickup_key
	clashing.select_next_key = camera.move_left_key
	assert_eq(clashing.keys_shared_with(camera), PackedStringArray(["select_next_key", "drop_key"]))


func test_a_use_key_uses_or_treats_and_never_hands_over() -> void:
	for kind: ConsumeIntentPolicy.Kind in [ConsumeIntentPolicy.Kind.FOOD, ConsumeIntentPolicy.Kind.DRINK, ConsumeIntentPolicy.Kind.BANDAGE, ConsumeIntentPolicy.Kind.CURE]:
		assert_eq(ConsumeIntentPolicy.use_mode(kind, false), ConsumeIntentPolicy.UseMode.ON_SELF, "no modifier: use it myself")
		assert_eq(ConsumeIntentPolicy.use_mode(kind, true), ConsumeIntentPolicy.UseMode.ON_OTHER, "the treat-other modifier: use it on the other player")
	assert_eq(ConsumeIntentPolicy.UseMode.size(), 2, "using an item on myself or on somebody: there is no hand-over mode")


# ------------------------------------------------------------ HUD

func test_the_inventory_hud_lists_the_stacks_and_marks_the_selected_one() -> void:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var food: String = catalog.get_definition(FOOD_ID).display_name
	var water: String = catalog.get_definition(WATER_ID).display_name
	var bandage: String = catalog.get_definition(BANDAGE_ID).display_name
	assert_false(food.is_empty() or water.is_empty() or bandage.is_empty(), "the shipped items have names")
	var empty: Array[Dictionary] = []
	assert_eq(ClientPresentationFormatter.build_inventory_lines(empty, catalog, "", settings), PackedStringArray(["소지품: 없음"]))
	var inventory: Array[Dictionary] = _inventory()
	assert_eq(ClientPresentationFormatter.build_inventory_lines(inventory, catalog, "item_000005", settings), PackedStringArray([
		"소지품 (3) | 선택 [Z/X] 내려놓기 [Q] 묶음째 [Ctrl+Q]",
		"  %s x3" % food,
		"> %s x1" % bandage,
		"  %s x2" % water,
	]), "one line per stack in slot order, the cursor on the selected one, the keys in the header")
	# Nothing selected (or an id that is not carried): no cursor.
	var unselected: PackedStringArray = ClientPresentationFormatter.build_inventory_lines(inventory, catalog, "", settings)
	assert_eq(unselected.size(), 4)
	for index: int in range(1, unselected.size()):
		assert_true(unselected[index].begins_with("  "), unselected[index])
	# The keys come from the settings; without a catalog the ids are shown.
	settings.select_previous_key = KEY_COMMA
	settings.select_next_key = KEY_PERIOD
	settings.drop_key = KEY_T
	settings.drop_stack_modifier_key = KEY_ALT
	var custom: PackedStringArray = ClientPresentationFormatter.build_inventory_lines(inventory, null, "item_000003", settings)
	assert_eq(custom[0], "소지품 (3) | 선택 [Comma/Period] 내려놓기 [T] 묶음째 [Alt+T]")
	assert_eq(custom[1], "> %s x3" % FOOD_ID)
	# More stacks than lines: a window around the cursor, the rest counted.
	settings = ClientPresentationSettings.new()
	settings.hud_inventory_line_count = 3
	var many: Array[Dictionary] = []
	for index: int in range(7):
		many.append(_entry("item_%06d" % (index + 1), FOOD_ID, index + 1, "slot_%d" % index))
	assert_eq(ClientPresentationFormatter.build_inventory_lines(many, catalog, "item_000001", settings), PackedStringArray([
		"소지품 (7) | 선택 [Z/X] 내려놓기 [Q] 묶음째 [Ctrl+Q]",
		"> %s x1" % food,
		"  %s x2" % food,
		"  %s x3" % food,
		"  ... 아래 4개",
	]))
	assert_eq(ClientPresentationFormatter.build_inventory_lines(many, catalog, "item_000004", settings), PackedStringArray([
		"소지품 (7) | 선택 [Z/X] 내려놓기 [Q] 묶음째 [Ctrl+Q]",
		"  ... 위 2개",
		"  %s x3" % food,
		"> %s x4" % food,
		"  %s x5" % food,
		"  ... 아래 2개",
	]), "the cursor is always inside the window")
	assert_eq(ClientPresentationFormatter.build_inventory_lines(many, catalog, "item_000007", settings), PackedStringArray([
		"소지품 (7) | 선택 [Z/X] 내려놓기 [Q] 묶음째 [Ctrl+Q]",
		"  ... 위 4개",
		"  %s x5" % food,
		"  %s x6" % food,
		"> %s x7" % food,
	]))


func test_the_pickup_candidate_is_the_nearest_item_in_reach() -> void:
	var items: Dictionary[String, Dictionary] = {
		"item_far": _world_item("item_far", FOOD_ID, 3, Vector3(10.0, 0.0, 0.0)),
		"item_near": _world_item("item_near", WATER_ID, 2, Vector3(2.0, 0.0, 0.0)),
		"item_bad": {"position": "not a vector"},
	}
	assert_eq(InputIntentMath.nearest_world_item_id(Vector3.ZERO, items), "item_near", "without a range: the nearest, however far")
	assert_eq(InputIntentMath.nearest_world_item_id(Vector3.ZERO, items, 2.5), "item_near")
	assert_eq(InputIntentMath.nearest_world_item_id(Vector3.ZERO, items, 2.0), "item_near", "exactly at the range is in reach")
	assert_eq(InputIntentMath.nearest_world_item_id(Vector3.ZERO, items, 1.99), "", "nothing in reach")
	assert_eq(InputIntentMath.nearest_world_item_id(Vector3(9.0, 0.0, 0.0), items, 2.5), "item_far")
	assert_eq(InputIntentMath.nearest_world_item_id(Vector3.ZERO, items, -1.0), "", "an invalid range reaches nothing")
	# The HUD line.
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var water: String = catalog.get_definition(WATER_ID).display_name
	assert_eq(ClientPresentationFormatter.build_pickup_lines(items["item_near"], catalog, KEY_E), PackedStringArray(["줍기 [E]: %s x2" % water]))
	assert_eq(ClientPresentationFormatter.build_pickup_lines({}, catalog, KEY_E), PackedStringArray(["줍기 [E]: 가까이에 없음"]))
	assert_eq(ClientPresentationFormatter.build_pickup_lines(items["item_bad"], catalog, KEY_E), PackedStringArray(["줍기 [E]: 가까이에 없음"]), "a malformed mirror row is no candidate")
	assert_eq(ClientPresentationFormatter.build_pickup_lines(items["item_near"], null, KEY_R), PackedStringArray(["줍기 [R]: %s x2" % WATER_ID]), "the key and, without a catalog, the id")


func test_result_sentences() -> void:
	assert_eq(ClientPresentationFormatter.format_drop_result(true, ""), "내려놓기 승인")
	var drop_sentences: Dictionary[String, String] = {
		InventoryService.REASON_NOT_IN_INVENTORY: "가지고 있지",
		InventoryService.REASON_BAD_QUANTITY: "수량",
	}
	for reason: String in drop_sentences:
		var text: String = ClientPresentationFormatter.format_drop_result(false, reason)
		assert_true(text.begins_with("내려놓기 거부: "), text)
		assert_contains(text, drop_sentences[reason], reason)
		assert_not_contains(text, reason, "a sentence, not the code: " + reason)
	# Everything else keeps its code, so nothing is hidden from the player.
	for reason: String in [NetworkService.RATE_LIMITED, SurvivalService.REASON_PLAYER_RESTING, SurvivalService.REASON_PLAYER_DEAD]:
		assert_eq(ClientPresentationFormatter.format_drop_result(false, reason), "내려놓기 거부: %s" % reason)
	assert_eq(ClientPresentationFormatter.format_pickup_result(true, ""), "줍기 승인")
	var pickup_sentences: Dictionary[String, String] = {
		InventoryService.REASON_INVENTORY_FULL: "가득",
		InventoryService.REASON_TOO_FAR: "멉니다",
		InventoryService.REASON_NOT_IN_WORLD: "없는",
		InventoryService.REASON_UNKNOWN_ITEM: "없는",
	}
	for reason: String in pickup_sentences:
		var text: String = ClientPresentationFormatter.format_pickup_result(false, reason)
		assert_true(text.begins_with("줍기 거부: "), text)
		assert_contains(text, pickup_sentences[reason], reason)
		assert_not_contains(text, reason, "a sentence, not the code: " + reason)
	assert_eq(ClientPresentationFormatter.format_pickup_result(false, NetworkService.RATE_LIMITED), "줍기 거부: %s" % NetworkService.RATE_LIMITED)
	assert_eq(ClientPresentationFormatter.nothing_selected_text(), "내려놓을 아이템이 없습니다")
	assert_eq(ClientPresentationFormatter.nothing_to_pick_up_text(), "가까이에 주울 것이 없습니다")
	# The target line no longer offers a hand-over.
	var line: String = ClientPresentationFormatter.build_treat_target_lines({"alive": true}, "민수", ClientPresentationSettings.new())[0]
	assert_eq(line, "줄 대상: 민수 | 음식 [Shift+F] 물 [Shift+G] 붕대 [Shift+B] 치료제 [Shift+V]")
	assert_not_contains(line, "건네기")


# ------------------------------------------------------------ markers of items lying in the world

func test_every_item_lying_in_the_world_gets_a_marker_with_its_name_and_quantity() -> void:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var food: String = catalog.get_definition(FOOD_ID).display_name
	assert_eq(ClientPresentationFormatter.world_item_label(_world_item("item_000001", FOOD_ID, 3, Vector3.ZERO), catalog), "%s x3" % food)
	assert_eq(ClientPresentationFormatter.world_item_label(_world_item("item_000001", "not_in_this_catalog", 1, Vector3.ZERO), catalog), "not_in_this_catalog x1", "an unknown definition is shown by its id")
	assert_eq(ClientPresentationFormatter.world_item_label(_world_item("item_000001", FOOD_ID, 2, Vector3.ZERO), null), "%s x2" % FOOD_ID)
	assert_eq(ClientPresentationFormatter.world_item_label({"position": Vector3.ZERO}, catalog), "", "a malformed row has no label")

	_root = Node3D.new()
	tree.root.add_child(_root)
	var markers: WorldItemMarkers = WorldItemMarkers.new(_root, catalog, settings)
	var at: Vector3 = Vector3(2.0, 0.0, -3.0)
	var items: Dictionary[String, Dictionary] = {
		"item_000001": _world_item("item_000001", FOOD_ID, 3, at),
		"item_000002": _world_item("item_000002", WATER_ID, 1, Vector3(-1.0, 0.0, 4.0)),
		"item_bad": {"position": "not a vector"},
	}
	markers.sync(items)
	assert_eq(markers.marker_count(), 2, "one marker per item, none for a malformed row")
	assert_eq(markers.body_instance_count(), 2, "both boxes are instances in one batch")
	assert_eq(markers.transform_of("item_000001").origin, at + Vector3.UP * settings.world_item_marker_size_m * 0.5, "where the mirror says the item lies")
	var batch: MultiMeshInstance3D = _root.get_node(WorldItemMarkers.BATCH_NODE) as MultiMeshInstance3D
	assert_true(batch.multimesh.mesh is BoxMesh, "a placeholder box")
	assert_eq((batch.multimesh.mesh as BoxMesh).size, Vector3.ONE * settings.world_item_marker_size_m)
	assert_eq((batch.material_override as StandardMaterial3D).albedo_color, settings.world_item_marker_color)
	var label: Label3D = markers.label_of("item_000001")
	assert_not_null(label)
	assert_eq(label.text, "%s x3" % food)
	assert_eq(label.billboard, BaseMaterial3D.BILLBOARD_ENABLED, "the label faces the camera")
	assert_true(label.position.y >= settings.world_item_marker_size_m + settings.world_item_label_margin_m - EPSILON, "above the box")
	assert_eq(label.font_size, settings.world_item_label_font_size)
	assert_true(absf(label.pixel_size - settings.world_item_label_pixel_size) < EPSILON)
	assert_eq(label.modulate, settings.world_item_label_color)

	# The mirror changes: a quantity, a position, an item gone, a new item.
	items["item_000001"] = _world_item("item_000001", FOOD_ID, 2, at + Vector3(1.0, 0.0, 0.0))
	items.erase("item_000002")
	items["item_000003"] = _world_item("item_000003", BANDAGE_ID, 1, Vector3.ZERO)
	markers.sync(items)
	assert_eq(markers.marker_count(), 2)
	assert_eq(label.text, "%s x2" % food)
	assert_eq(markers.transform_of("item_000001").origin, at + Vector3(1.0, settings.world_item_marker_size_m * 0.5, 0.0))
	assert_false(markers.has_marker("item_000002"), "an item that was picked up has no marker")
	assert_null(_root.get_node_or_null(WorldItemMarkers.MARKER_PREFIX + "item_000002"), "its node left the tree at once")
	assert_true(markers.has_marker("item_000003"))
	# Syncing the same mirror again changes nothing.
	markers.sync(items)
	assert_eq(markers.body_instance_count(), 2)
	# Everything picked up.
	markers.sync({})
	assert_eq(markers.marker_count(), 0)
	assert_eq(markers.body_instance_count(), 0)
	assert_eq(_root.get_child_count(), 1, "the empty batch node is retained")


func test_world_item_labels_keep_the_nearest_configured_count_and_all_bodies() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	settings.world_item_label_distance_m = 3.1
	settings.world_item_label_max_count = 2
	_root = Node3D.new()
	tree.root.add_child(_root)
	var markers := WorldItemMarkers.new(_root, ItemCatalog.load_directory(), settings)
	var items: Dictionary = {
		"item_000001": _world_item("item_000001", FOOD_ID, 1, Vector3.ZERO),
		"item_000002": _world_item("item_000002", FOOD_ID, 1, Vector3.RIGHT),
		"item_000003": _world_item("item_000003", FOOD_ID, 1, Vector3.RIGHT * 3.0),
		"item_000004": _world_item("item_000004", FOOD_ID, 1, Vector3.RIGHT * 10.0),
	}
	markers.sync(items, Vector3.ZERO)
	assert_eq(markers.body_instance_count(), 4)
	assert_eq(markers.label_count(), 2)
	assert_not_null(markers.label_of("item_000001"))
	assert_not_null(markers.label_of("item_000002"))
	assert_null(markers.label_of("item_000003"), "a farther in-range item loses to the cap")
	assert_null(markers.label_of("item_000004"), "distance still limits labels")
	markers.update_focus(Vector3.RIGHT * 3.0)
	assert_eq(markers.body_instance_count(), 4, "moving label focus never removes bodies")
	assert_eq(markers.label_count(), 2)
	assert_not_null(markers.label_of("item_000003"))
	assert_not_null(markers.label_of("item_000002"))
