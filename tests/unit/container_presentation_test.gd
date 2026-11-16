extends TestCase
## P3-3 (docs/09 §15.3, docs/11 §2.16): the pure client-side logic of the
## container keys and the container HUD: which container the open key names,
## what it means with a container open, the cursor on the stacks inside, how
## many units a take / put key asks for, the keys themselves, the HUD lines
## and the result sentences, and the placeholder markers. No network: the
## mirrors are plain dictionaries here. The real client session:
## tests/integration/container_view_test.gd.

const NEAR_ID: String = "container_000010"
const FAR_ID: String = "container_000011"
const CRATE: String = "dev_crate"
const CABINET: String = "dev_cabinet"
const FOOD: String = "dev_food_ration"
const WATER: String = "dev_water_bottle"
const RANGE_M: float = 2.5

var _settings: ClientPresentationSettings = null
var _items: ItemCatalog = null
var _containers: ContainerCatalog = null


func before_each() -> void:
	_settings = ClientPresentationSettings.new()
	_items = ItemCatalog.load_directory()
	_containers = ContainerCatalog.load_directory()


func _container(definition_id: String, position: Vector3, searched: bool = false) -> Dictionary:
	return {ClientContainerState.KEY_DEFINITION_ID: definition_id, ClientContainerState.KEY_POSITION: position, ClientContainerState.KEY_SEARCHED: searched}


func _entry(item_id: String, definition_id: String, quantity: int, slot: int) -> Dictionary:
	return {ClientContainerState.KEY_ITEM_ID: item_id, ClientContainerState.KEY_DEFINITION_ID: definition_id, ClientContainerState.KEY_QUANTITY: quantity, ClientContainerState.KEY_SLOT: slot}


func _contents() -> Array[Dictionary]:
	return [_entry("item_30", WATER, 2, 4), _entry("item_10", FOOD, 3, 0), _entry("item_20", FOOD, 1, 2)]


func _carried(item_id: String, definition_id: String, quantity: int, slot: int) -> Dictionary:
	return {"item_instance_id": item_id, "definition_id": definition_id, "quantity": quantity, "slot_id": "slot_%d" % slot}


# ------------------------------------------------------------ choices

func test_the_open_key_names_the_nearest_container_in_reach() -> void:
	var containers: Dictionary = {
		FAR_ID: _container(CRATE, Vector3(2.0, 0.0, 0.0)),
		NEAR_ID: _container(CABINET, Vector3(0.0, 0.0, 1.0)),
		"container_000012": _container(CRATE, Vector3(30.0, 0.0, 0.0)),
	}
	assert_eq(ContainerIntentPolicy.nearest_container_id(Vector3.ZERO, containers, RANGE_M), NEAR_ID)
	assert_eq(ContainerIntentPolicy.nearest_container_id(Vector3(2.0, 0.0, 0.0), containers, RANGE_M), FAR_ID, "it follows the player")
	assert_eq(ContainerIntentPolicy.nearest_container_id(Vector3(10.0, 0.0, 0.0), containers, RANGE_M), ContainerIntentPolicy.NO_CONTAINER, "nothing in reach")
	assert_eq(ContainerIntentPolicy.nearest_container_id(Vector3(0.0, 0.0, 1.0 + RANGE_M), containers, RANGE_M), NEAR_ID, "the range itself is in reach")
	assert_eq(ContainerIntentPolicy.nearest_container_id(Vector3.ZERO, containers, -1.0), ContainerIntentPolicy.NO_CONTAINER)
	assert_eq(ContainerIntentPolicy.nearest_container_id(Vector3.ZERO, containers, NAN), ContainerIntentPolicy.NO_CONTAINER)
	assert_eq(ContainerIntentPolicy.nearest_container_id(Vector3.ZERO, {}, RANGE_M), ContainerIntentPolicy.NO_CONTAINER)
	# Two at the same distance: always the same one.
	var twins: Dictionary = {"container_b": _container(CRATE, Vector3(1.0, 0.0, 0.0)), "container_a": _container(CRATE, Vector3(-1.0, 0.0, 0.0))}
	assert_eq(ContainerIntentPolicy.nearest_container_id(Vector3.ZERO, twins, RANGE_M), "container_a")
	# Rows that are no containers are passed over.
	var broken: Dictionary = {"x": {"position": "here"}, 7: _container(CRATE, Vector3.ZERO), "y": "nothing", NEAR_ID: _container(CABINET, Vector3(1.0, 0.0, 0.0))}
	assert_eq(ContainerIntentPolicy.nearest_container_id(Vector3.ZERO, broken, RANGE_M), NEAR_ID)


func test_what_the_open_key_means_depends_on_the_session() -> void:
	assert_eq(ContainerIntentPolicy.open_key_action(ClientContainerState.PHASE_NONE, NEAR_ID), ContainerIntentPolicy.OpenAction.OPEN)
	assert_eq(ContainerIntentPolicy.open_key_action(ClientContainerState.PHASE_NONE, ""), ContainerIntentPolicy.OpenAction.NONE, "nothing in reach: nothing to ask")
	assert_eq(ContainerIntentPolicy.open_key_action(ClientContainerState.PHASE_OPEN, NEAR_ID), ContainerIntentPolicy.OpenAction.CLOSE)
	assert_eq(ContainerIntentPolicy.open_key_action(ClientContainerState.PHASE_OPEN, ""), ContainerIntentPolicy.OpenAction.CLOSE)
	assert_eq(ContainerIntentPolicy.open_key_action(ClientContainerState.PHASE_SEARCHING, NEAR_ID), ContainerIntentPolicy.OpenAction.CLOSE, "the same key gives a search up")
	assert_true(ContainerIntentPolicy.can_transfer(ClientContainerState.PHASE_OPEN))
	assert_false(ContainerIntentPolicy.can_transfer(ClientContainerState.PHASE_SEARCHING), "nothing is taken or put while the search runs")
	assert_false(ContainerIntentPolicy.can_transfer(ClientContainerState.PHASE_NONE))


func test_the_container_cursor_walks_the_stacks_in_slot_order() -> void:
	var contents: Array[Dictionary] = _contents()
	assert_eq(ContainerIntentPolicy.ordered_item_ids(contents), PackedStringArray(["item_10", "item_20", "item_30"]))
	assert_eq(ContainerIntentPolicy.index_of(contents, "item_20"), 1)
	assert_eq(ContainerIntentPolicy.index_of(contents, "item_99"), -1)
	assert_eq(ContainerIntentPolicy.step(contents, "item_10", 1), "item_20")
	assert_eq(ContainerIntentPolicy.step(contents, "item_30", 1), "item_10", "it wraps at the end")
	assert_eq(ContainerIntentPolicy.step(contents, "item_10", -1), "item_30", "and at the start")
	assert_eq(ContainerIntentPolicy.step(contents, "", 1), "item_10", "without a selection forwards starts at the first stack")
	assert_eq(ContainerIntentPolicy.step(contents, "", -1), "item_30")
	var nothing: Array[Dictionary] = []
	assert_eq(ContainerIntentPolicy.step(nothing, "item_10", 1), ContainerIntentPolicy.NO_SELECTION)
	# The cursor stays on its stack while it is inside, and takes the stack at
	# its place when somebody took it out.
	assert_eq(ContainerIntentPolicy.resolve(contents, "item_20", 1), "item_20")
	var without_second: Array[Dictionary] = [contents[0], contents[1]]
	assert_eq(ContainerIntentPolicy.resolve(without_second, "item_20", 1), "item_30", "the stack that is at that place now")
	assert_eq(ContainerIntentPolicy.resolve(without_second, "item_20", 7), "item_30", "or the last one")
	assert_eq(ContainerIntentPolicy.resolve(nothing, "item_20", 1), ContainerIntentPolicy.NO_SELECTION)
	# Rows that are no stacks cannot be selected.
	var odd: Array[Dictionary] = [{"quantity": 3}, _entry("", FOOD, 1, 0), _entry("item_5", FOOD, 0, 1), _entry("item_6", FOOD, 2, 3)]
	assert_eq(ContainerIntentPolicy.ordered_item_ids(odd), PackedStringArray(["item_6"]))


func test_how_many_units_the_take_and_the_put_key_ask_for() -> void:
	var contents: Array[Dictionary] = _contents()
	assert_eq(ContainerIntentPolicy.take_quantity(contents, "item_10", 1, false), 1, "one press, one unit")
	assert_eq(ContainerIntentPolicy.take_quantity(contents, "item_10", 5, false), 3, "never more than the mirror says is there")
	assert_eq(ContainerIntentPolicy.take_quantity(contents, "item_10", 1, true), InventoryService.WHOLE_STACK, "with the modifier: the stack as the server knows it")
	assert_eq(ContainerIntentPolicy.take_quantity(contents, "item_99", 1, false), ContainerIntentPolicy.NOTHING_TO_MOVE)
	assert_eq(ContainerIntentPolicy.take_quantity(contents, "item_99", 1, true), ContainerIntentPolicy.NOTHING_TO_MOVE)
	assert_eq(ContainerIntentPolicy.take_quantity(contents, "item_10", 0, false), ContainerIntentPolicy.NOTHING_TO_MOVE)
	assert_eq(ContainerIntentPolicy.take_quantity(contents, "", 1, false), ContainerIntentPolicy.NOTHING_TO_MOVE)
	var inventory: Array[Dictionary] = [_carried("item_40", FOOD, 4, 0), _carried("item_41", WATER, 1, 1)]
	assert_eq(ContainerIntentPolicy.put_quantity(inventory, "item_40", 1, false), 1)
	assert_eq(ContainerIntentPolicy.put_quantity(inventory, "item_41", 3, false), 1)
	assert_eq(ContainerIntentPolicy.put_quantity(inventory, "item_40", 1, true), InventoryService.WHOLE_STACK)
	assert_eq(ContainerIntentPolicy.put_quantity(inventory, "item_10", 1, false), ContainerIntentPolicy.NOTHING_TO_MOVE, "a stack inside the container is not carried")
	assert_eq(ContainerIntentPolicy.put_quantity(inventory, "", 1, true), ContainerIntentPolicy.NOTHING_TO_MOVE)


# ------------------------------------------------------------ keys

func test_the_container_keys_are_settings_with_collision_checks() -> void:
	assert_eq(_settings.validate().size(), 0, "; ".join(_settings.validate()))
	assert_eq(_settings.container_open_key, KEY_H)
	assert_eq(_settings.container_previous_key, KEY_J)
	assert_eq(_settings.container_next_key, KEY_K)
	assert_eq(_settings.container_take_key, KEY_U)
	assert_eq(_settings.container_put_key, KEY_I)
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_eq(shipped.keys_shared_with(CameraSettings.load_or_default()).size(), 0, "no shipped key is also a movement or pickup key")
	var own: Dictionary[String, Key] = _settings.assigned_keys()
	for key_name: String in ["container_open_key", "container_previous_key", "container_next_key", "container_take_key", "container_put_key"]:
		assert_true(own.has(key_name), key_name + " is in the collision check")
	# A container key on a key that is taken already is refused.
	for taken: Key in [_settings.drop_key, _settings.select_next_key, _settings.trade_accept_key, _settings.rest_key, _settings.cell_overlay_key, _settings.container_take_key]:
		var clash: ClientPresentationSettings = ClientPresentationSettings.new()
		clash.container_open_key = taken
		assert_true(clash.validate().size() > 0, "%s is taken" % OS.get_keycode_string(taken))
	var unset: ClientPresentationSettings = ClientPresentationSettings.new()
	unset.container_put_key = KEY_NONE
	assert_true(unset.validate().size() > 0)
	# The pickup key belongs to the camera settings: that clash is reported too.
	var on_pickup: ClientPresentationSettings = ClientPresentationSettings.new()
	on_pickup.container_open_key = CameraSettings.new().pickup_key
	assert_eq(Array(on_pickup.keys_shared_with(CameraSettings.new())), ["container_open_key"])
	for field: String in ["container_transfer_quantity", "container_min_interval_sec", "container_candidate_range_m", "hud_container_line_count", "container_marker_size_m"]:
		var broken: ClientPresentationSettings = ClientPresentationSettings.new()
		broken.set(field, 0)
		assert_true(broken.validate().size() > 0, field + " must be positive")
	# The actions exist with the configured keys.
	ClientInputActions.register(CameraSettings.new(), _settings)
	var expected: Dictionary[StringName, Key] = {
		ClientInputActions.CONTAINER_OPEN: _settings.container_open_key,
		ClientInputActions.CONTAINER_PREVIOUS: _settings.container_previous_key,
		ClientInputActions.CONTAINER_NEXT: _settings.container_next_key,
		ClientInputActions.CONTAINER_TAKE: _settings.container_take_key,
		ClientInputActions.CONTAINER_PUT: _settings.container_put_key,
	}
	for action: StringName in expected:
		assert_true(InputMap.has_action(action), str(action))
		var events: Array[InputEvent] = InputMap.action_get_events(action)
		assert_eq(events.size(), 1)
		assert_eq((events[0] as InputEventKey).physical_keycode, expected[action], str(action))


# ------------------------------------------------------------ HUD

func test_the_hud_block_follows_the_session() -> void:
	var none: Array[Dictionary] = []
	# No session: the candidate, or nothing at all.
	assert_eq(ClientPresentationFormatter.build_container_lines(ClientContainerState.PHASE_NONE, "", 0.0, none, _items, "", "", true, _settings).size(), 0, "no container in reach: the block is hidden")
	var candidate: PackedStringArray = ClientPresentationFormatter.build_container_lines(ClientContainerState.PHASE_NONE, "", 0.0, none, _items, "", "수납장 (수색 전)", true, _settings)
	assert_eq(candidate, PackedStringArray(["보관함 열기 [H]: 수납장 (수색 전)"]))
	# Searching: no content is shown.
	var searching: PackedStringArray = ClientPresentationFormatter.build_container_lines(ClientContainerState.PHASE_SEARCHING, "수납장", 1.5, _contents(), _items, "", "", true, _settings)
	assert_eq(searching.size(), 1)
	assert_contains(searching[0], "수납장 수색 중")
	assert_contains(searching[0], "1.5초")
	assert_contains(searching[0], "[H]")
	# Open: a header with every key, then the stacks in slot order.
	var open: PackedStringArray = ClientPresentationFormatter.build_container_lines(ClientContainerState.PHASE_OPEN, "수납장", 0.0, _contents(), _items, "item_20", "", true, _settings)
	assert_eq(open.size(), 4)
	assert_contains(open[0], "수납장 (3)")
	for key_text: String in ["[J/K]", "꺼내기 [U]", "넣기 [I]", "닫기 [H]", "Ctrl"]:
		assert_contains(open[0], key_text)
	var food_name: String = ClientPresentationFormatter.item_display_name(FOOD, _items)
	var water_name: String = ClientPresentationFormatter.item_display_name(WATER, _items)
	assert_eq(open[1], "  %s x3" % food_name)
	assert_eq(open[2], "> %s x1" % food_name, "the cursor marks its stack")
	assert_eq(open[3], "  %s x2" % water_name)
	var empty: PackedStringArray = ClientPresentationFormatter.build_container_lines(ClientContainerState.PHASE_OPEN, "나무 상자", 0.0, none, _items, "", "", true, _settings)
	assert_eq(empty.size(), 2)
	assert_contains(empty[0], "나무 상자 (0)")
	assert_contains(empty[1], "비어 있음")
	# More stacks than lines: a window around the cursor.
	_settings.hud_container_line_count = 3
	var many: Array[Dictionary] = []
	for index: int in range(8):
		many.append(_entry("item_%d" % index, FOOD, index + 1, index))
	var window: PackedStringArray = ClientPresentationFormatter.build_container_lines(ClientContainerState.PHASE_OPEN, "수납장", 0.0, many, _items, "item_5", "", true, _settings)
	assert_eq(window.size(), 6, "header, above, three stacks, below")
	assert_contains(window[1], "위 4개")
	assert_eq(window[3], "> %s x6" % food_name)
	assert_contains(window[5], "아래 1개")
	# A dead character sees no container block.
	assert_eq(ClientPresentationFormatter.build_container_lines(ClientContainerState.PHASE_OPEN, "수납장", 0.0, _contents(), _items, "", "", false, _settings).size(), 0)


func test_results_and_closures_are_told_in_sentences() -> void:
	assert_eq(ClientPresentationFormatter.format_container_result(true, ""), "", "an accepted request shows in the HUD block")
	var sentences: Dictionary[String, String] = {
		ContainerService.REASON_TOO_FAR: "너무 멉니다",
		ContainerService.REASON_UNKNOWN_CONTAINER: "그런 보관함이 없습니다",
		ContainerService.REASON_NOT_OPEN: "먼저 보관함을 여세요",
		ContainerService.REASON_SEARCHING: "수색 중",
		ContainerService.REASON_ALREADY_OPEN: "이미 열려",
		ContainerService.REASON_ITEM_NOT_INSIDE: "보관함에 없는",
		ContainerService.REASON_ITEM_NOT_CARRIED: "가지고 있지 않은",
		ContainerService.REASON_CONTAINER_FULL: "보관함이 가득",
		InventoryService.REASON_INVENTORY_FULL: "소지품이 가득",
		InventoryService.REASON_BAD_QUANTITY: "수량",
		NetworkService.RATE_LIMITED: "너무 잦습니다",
	}
	for reason: String in sentences:
		var text: String = ClientPresentationFormatter.format_container_result(false, reason)
		assert_contains(text, sentences[reason], reason)
		assert_not_contains(text, reason, "a sentence, not the code")
	assert_contains(ClientPresentationFormatter.format_container_result(false, "some_new_reason"), "some_new_reason", "an unknown reason keeps its code")
	assert_eq(ClientPresentationFormatter.format_container_closed(ContainerService.REASON_CLOSED), "", "the player closed it: nothing to tell")
	assert_eq(ClientPresentationFormatter.format_container_closed(ContainerService.REASON_SWITCHED), "")
	assert_eq(ClientPresentationFormatter.format_container_closed("player_dead"), "")
	assert_contains(ClientPresentationFormatter.format_container_closed(ContainerService.REASON_TOO_FAR), "멀어져")
	assert_contains(ClientPresentationFormatter.format_container_closed(ContainerService.REASON_INTERRUPTED), "수색이 중단")
	assert_contains(ClientPresentationFormatter.format_container_closed(ContainerService.REASON_CONTAINER_GONE), "범위")
	assert_contains(ClientPresentationFormatter.format_container_closed("player_resting"), "누워서")
	assert_contains(ClientPresentationFormatter.format_container_closed("other"), "other")
	for text: String in [ClientPresentationFormatter.nothing_to_open_text(), ClientPresentationFormatter.container_not_open_text(), ClientPresentationFormatter.nothing_to_take_text(), ClientPresentationFormatter.nothing_to_put_text()]:
		assert_false(text.is_empty())


# ------------------------------------------------------------ markers

func test_labels_and_markers_follow_the_mirror() -> void:
	var crate_name: String = _containers.get_definition(CRATE).display_name
	assert_false(crate_name.is_empty(), "shipped definitions have a name")
	assert_eq(ClientPresentationFormatter.container_label(_container(CRATE, Vector3.ZERO, false), _containers), "%s (수색 전)" % crate_name)
	assert_eq(ClientPresentationFormatter.container_label(_container(CRATE, Vector3.ZERO, true), _containers), crate_name)
	assert_eq(ClientPresentationFormatter.container_label(_container("unknown_thing", Vector3.ZERO, true), _containers), "unknown_thing", "without a definition: the id")
	assert_eq(ClientPresentationFormatter.container_label({}, _containers), "")
	var root: Node3D = Node3D.new()
	var markers: ContainerMarkers = ContainerMarkers.new(root, _containers, _settings)
	var mirror: Dictionary = {NEAR_ID: _container(CRATE, Vector3(3.0, 0.0, 4.0)), FAR_ID: _container(CABINET, Vector3(-2.0, 0.0, 1.0), true), "broken": {"position": 3}}
	markers.sync(mirror)
	assert_eq(markers.marker_count(), 2, "one marker per container, none for a broken row")
	var marker: Node3D = markers.marker_of(NEAR_ID)
	assert_not_null(marker)
	assert_eq(marker.name, StringName(ContainerMarkers.MARKER_PREFIX + NEAR_ID))
	assert_eq(marker.position, Vector3(3.0, 0.0, 4.0))
	assert_eq((marker.get_node(ContainerMarkers.LABEL_NODE) as Label3D).text, "%s (수색 전)" % crate_name)
	var body: MeshInstance3D = marker.get_node(ContainerMarkers.BODY_NODE) as MeshInstance3D
	assert_eq((body.mesh as BoxMesh).size, Vector3.ONE * _settings.container_marker_size_m)
	assert_eq((body.material_override as StandardMaterial3D).albedo_color, _settings.container_marker_color)
	assert_eq(((markers.marker_of(FAR_ID).get_node(ContainerMarkers.BODY_NODE) as MeshInstance3D).material_override as StandardMaterial3D).albedo_color, _settings.container_searched_marker_color, "a searched container looks different")
	# Searched: the same marker, another label and colour.
	mirror[NEAR_ID] = _container(CRATE, Vector3(3.0, 0.0, 4.0), true)
	markers.sync(mirror)
	assert_eq(markers.marker_of(NEAR_ID), marker, "the marker is updated, not replaced")
	assert_eq((marker.get_node(ContainerMarkers.LABEL_NODE) as Label3D).text, crate_name)
	assert_eq((body.material_override as StandardMaterial3D).albedo_color, _settings.container_searched_marker_color)
	# Out of the mirror: out of the world.
	mirror.erase(FAR_ID)
	markers.sync(mirror)
	assert_eq(markers.marker_count(), 1)
	assert_null(markers.marker_of(FAR_ID))
	assert_eq(root.get_child_count(), 1)
	markers.sync({})
	assert_eq(markers.marker_count(), 0)
	root.free()
