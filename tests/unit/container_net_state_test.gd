extends TestCase
## P3-3 (docs/09 §15.3): ClientContainerState, the client mirror of the
## containers around the local player and of the one it has open. It has no
## authority and trusts no payload: everything is validated, and what does
## not fit is counted and left out. Also the pure wire rules of
## ContainerNetModule (request validation, what a refusal tells). No
## network: tests/integration/container_net_test.gd.

const CRATE: String = "dev_crate"
const CABINET: String = "dev_cabinet"
const FIRST: String = "container_000001"
const SECOND: String = "container_000002"
const FOOD: String = "dev_food_ration"

var _state: ClientContainerState = null
var _settings: ContainerNetSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = ContainerNetSettings.new()
	_state = ClientContainerState.new(_settings, ContainerCatalog.load_directory())


func after_each() -> void:
	GameLogger.set_capture(false)


func _row(container_id: String, definition_id: String = CRATE, position: Vector3 = Vector3(1.0, 0.0, 2.0), searched: bool = false) -> Array:
	return [container_id, definition_id, position.x, position.y, position.z, searched]


func _item(item_id: String, quantity: int, slot: int, definition_id: String = FOOD) -> Array:
	return [item_id, definition_id, quantity, slot]


func _fragment(rows: Array) -> Dictionary:
	return {ClientContainerState.KEY_SCHEMA_VERSION: ClientContainerState.SCHEMA_VERSION, ClientContainerState.KEY_CONTAINERS: rows}


func _quantities() -> Dictionary:
	var result: Dictionary = {}
	for entry: Dictionary in _state.contents():
		result[entry[ClientContainerState.KEY_ITEM_ID]] = entry[ClientContainerState.KEY_QUANTITY]
	return result


func test_rows_add_change_and_remove_containers() -> void:
	var added: Array[String] = []
	var changed: Array[String] = []
	var removed: Array[String] = []
	_state.container_added.connect(func(id: String) -> void: added.append(id))
	_state.container_changed.connect(func(id: String) -> void: changed.append(id))
	_state.container_removed.connect(func(id: String) -> void: removed.append(id))
	assert_eq(_state.apply_rows([_row(FIRST), _row(SECOND, CABINET, Vector3(-3.0, 0.0, 4.5), true)]), 2)
	assert_eq(_state.container_count(), 2)
	assert_eq(added, [FIRST, SECOND])
	var first: Dictionary = _state.get_container(FIRST)
	assert_eq(first[ClientContainerState.KEY_DEFINITION_ID], CRATE)
	assert_eq(first[ClientContainerState.KEY_POSITION], Vector3(1.0, 0.0, 2.0))
	assert_eq(first[ClientContainerState.KEY_SEARCHED], false)
	assert_eq(first.size(), 3, "definition, position, searched: nothing about what is inside")
	# The same id again is a change (it was searched).
	assert_eq(_state.apply_rows([_row(FIRST, CRATE, Vector3(1.0, 0.0, 2.0), true)]), 1)
	assert_eq(changed, [FIRST])
	assert_true(_state.get_container(FIRST)[ClientContainerState.KEY_SEARCHED])
	assert_eq(_state.apply_removed([SECOND, "container_000099"]), 1)
	assert_eq(removed, [SECOND])
	assert_eq(_state.unknown_removal_count, 1, "an id the mirror does not have is no error")
	assert_false(_state.has_container(SECOND))
	assert_eq(_state.rejected_payload_count, 0)


func test_bad_rows_are_counted_and_left_out() -> void:
	var bad_rows: Array = [
		"row",
		[FIRST, CRATE, 1.0, 0.0, 2.0],
		[FIRST, CRATE, 1.0, 0.0, 2.0, false, "extra"],
		[7, CRATE, 1.0, 0.0, 2.0, false],
		["", CRATE, 1.0, 0.0, 2.0, false],
		["x".repeat(ClientContainerState.MAX_ID_LENGTH + 1), CRATE, 1.0, 0.0, 2.0, false],
		[FIRST, "no_such_definition", 1.0, 0.0, 2.0, false],
		[FIRST, CRATE, "1", 0.0, 2.0, false],
		[FIRST, CRATE, NAN, 0.0, 2.0, false],
		[FIRST, CRATE, 1.0, INF, 2.0, false],
		[FIRST, CRATE, 1.0, 0.0, 2.0, 1],
	]
	for row: Variant in bad_rows:
		assert_false(_state.is_valid_row(row), str(row))
	assert_eq(_state.apply_rows(bad_rows + [_row(SECOND)]), 1, "a bad row does not take the good one with it")
	assert_eq(_state.container_ids(), PackedStringArray([SECOND]))
	assert_eq(_state.rejected_payload_count, bad_rows.size())
	assert_eq(_state.apply_rows("rows"), 0)
	var too_many: Array = []
	for index: int in range(ClientContainerState.MAX_ROWS_PER_MESSAGE + 1):
		too_many.append(_row("container_%06d" % (100 + index)))
	assert_eq(_state.apply_rows(too_many), 0, "a message that is too long is refused as a whole")
	assert_eq(_state.apply_removed(7), 0)
	assert_eq(_state.apply_removed([7, ""]), 0)
	assert_eq(_state.container_count(), 1)
	_settings.max_mirror_containers = 1
	assert_eq(_state.apply_rows([_row(FIRST)]), 0, "the mirror has a size limit")
	assert_eq(_state.apply_rows([_row(SECOND, CABINET)]), 1, "a container it has may still change")


func test_the_join_fragment_replaces_the_mirror_or_is_refused_as_a_whole() -> void:
	assert_true(_state.apply_rows([_row(FIRST)]) == 1 and _state.apply_session(FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, [_item("item_1", 2, 0)]))
	assert_true(_state.apply_join(_fragment([_row(SECOND, CABINET)])))
	assert_eq(_state.container_ids(), PackedStringArray([SECOND]), "what was there before is gone")
	assert_eq(_state.phase(), ClientContainerState.PHASE_NONE, "a new join starts without a session")
	assert_eq(_state.contents().size(), 0)
	assert_true(_state.apply_join({}), "no fragment: no containers")
	assert_eq(_state.container_count(), 0)
	for bad: Dictionary in [
		{ClientContainerState.KEY_CONTAINERS: []},
		{ClientContainerState.KEY_SCHEMA_VERSION: 99, ClientContainerState.KEY_CONTAINERS: []},
		{ClientContainerState.KEY_SCHEMA_VERSION: ClientContainerState.SCHEMA_VERSION, ClientContainerState.KEY_CONTAINERS: "x"},
		_fragment([_row(FIRST), _row(FIRST)]),
		_fragment([_row(FIRST), ["broken"]]),
		{ClientContainerState.KEY_SCHEMA_VERSION: ClientContainerState.SCHEMA_VERSION, ClientContainerState.KEY_CONTAINERS: [], "extra": 1},
	]:
		_state.apply_rows([_row(SECOND)])
		assert_false(_state.apply_join(bad), str(bad))
		assert_eq(_state.container_count(), 0, "a refused fragment leaves the mirror empty")


func test_the_session_of_the_local_player() -> void:
	var closed: Array = []
	_state.session_closed.connect(func(id: String, reason: String) -> void: closed.append([id, reason]))
	_state.apply_rows([_row(FIRST), _row(SECOND, CABINET)])
	# Searching: no content.
	assert_true(_state.apply_session(FIRST, ClientContainerState.PHASE_SEARCHING, "", 1.5, []))
	assert_eq(_state.open_container_id(), FIRST)
	assert_eq(_state.phase(), ClientContainerState.PHASE_SEARCHING)
	assert_eq(_state.search_sec(), 1.5)
	assert_eq(_state.contents().size(), 0)
	# Open: everything inside, in slot order.
	assert_true(_state.apply_session(FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, [_item("item_2", 1, 3), _item("item_1", 4, 0)]))
	assert_eq(_state.phase(), ClientContainerState.PHASE_OPEN)
	assert_eq(_state.search_sec(), 0.0)
	var contents: Array[Dictionary] = _state.contents()
	assert_eq(contents.size(), 2)
	assert_eq(contents[0][ClientContainerState.KEY_ITEM_ID], "item_1")
	assert_eq(contents[0][ClientContainerState.KEY_QUANTITY], 4)
	assert_eq(contents[0][ClientContainerState.KEY_SLOT], 0)
	assert_eq(contents[1][ClientContainerState.KEY_ITEM_ID], "item_2")
	# Changes: a stack shrinks, one arrives, one goes.
	assert_true(_state.apply_items(FIRST, [_item("item_1", 3, 0), _item("item_3", 2, 1)], ["item_2", "item_never_there"]))
	assert_eq(_quantities(), {"item_1": 3, "item_3": 2})
	# A change for a container that is not the open one is ignored.
	assert_true(_state.apply_items(SECOND, [_item("item_9", 1, 0)], []))
	assert_eq(_state.stale_contents_count, 1)
	assert_eq(_quantities(), {"item_1": 3, "item_3": 2})
	# Another container opens (the server closes the first one before).
	assert_true(_state.apply_session(FIRST, ClientContainerState.PHASE_CLOSED, ContainerService.REASON_SWITCHED, 0.0, []))
	assert_eq(closed, [[FIRST, ContainerService.REASON_SWITCHED]])
	assert_eq(_state.phase(), ClientContainerState.PHASE_NONE)
	assert_eq(_state.contents().size(), 0)
	assert_true(_state.apply_session(SECOND, ClientContainerState.PHASE_OPEN, "", 0.0, []))
	assert_eq(_state.open_container_id(), SECOND)
	# A closure of a container that is not open here changes nothing.
	assert_true(_state.apply_session(FIRST, ClientContainerState.PHASE_CLOSED, ContainerService.REASON_TOO_FAR, 0.0, []))
	assert_eq(_state.open_container_id(), SECOND)
	assert_eq(closed.size(), 1)
	# The open container leaves the mirror: the session ends with it.
	assert_eq(_state.apply_removed([SECOND]), 1)
	assert_eq(_state.phase(), ClientContainerState.PHASE_NONE)
	assert_eq(closed[1], [SECOND, ContainerService.REASON_CONTAINER_GONE])
	assert_eq(_state.rejected_payload_count, 0)


func test_bad_session_and_content_payloads_change_nothing() -> void:
	_state.apply_rows([_row(FIRST)])
	assert_true(_state.apply_session(FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, [_item("item_1", 4, 0)]))
	var too_many: Array = []
	for index: int in range(ClientContainerState.MAX_CONTENT_ENTRIES + 1):
		too_many.append(_item("item_%d" % (100 + index), 1, index % ClientContainerState.MAX_CONTENT_ENTRIES))
	var bad_sessions: Array = [
		[7, ClientContainerState.PHASE_OPEN, "", 0.0, []],
		[FIRST, 3, "", 0.0, []],
		[FIRST, ClientContainerState.PHASE_OPEN, 5, 0.0, []],
		[FIRST, ClientContainerState.PHASE_OPEN, "", "soon", []],
		[FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, "items"],
		["", ClientContainerState.PHASE_OPEN, "", 0.0, []],
		[FIRST, "ajar", "", 0.0, []],
		[FIRST, ClientContainerState.PHASE_SEARCHING, "", -1.0, []],
		[FIRST, ClientContainerState.PHASE_SEARCHING, "", NAN, []],
		[FIRST, ClientContainerState.PHASE_SEARCHING, "", ClientContainerState.MAX_SEARCH_SEC + 1.0, []],
		[FIRST, ClientContainerState.PHASE_SEARCHING, "", 1.0, [_item("item_5", 1, 0)]],
		[FIRST, ClientContainerState.PHASE_CLOSED, "", 0.0, [_item("item_5", 1, 0)]],
		[FIRST, ClientContainerState.PHASE_CLOSED, "r".repeat(ClientContainerState.MAX_REASON_LENGTH + 1), 0.0, []],
		[SECOND, ClientContainerState.PHASE_OPEN, "", 0.0, []],
		[FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, [_item("item_5", 0, 0)]],
		[FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, [_item("item_5", 1, -1)]],
		[FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, [_item("item_5", 1, ClientContainerState.MAX_CONTENT_ENTRIES)]],
		[FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, [_item("item_5", 1, 0, "Not Snake")]],
		[FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, [_item("item_5", 1, 0), _item("item_5", 2, 1)]],
		[FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, [["item_5", FOOD, 1.0, 0]]],
		[FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, [["item_5", FOOD, 1]]],
		[FIRST, ClientContainerState.PHASE_OPEN, "", 0.0, too_many],
	]
	for payload: Array in bad_sessions:
		assert_false(_state.apply_session(payload[0], payload[1], payload[2], payload[3], payload[4]), str(payload).left(120))
		assert_eq(_state.open_container_id(), FIRST)
		assert_eq(_state.phase(), ClientContainerState.PHASE_OPEN)
		assert_eq(_quantities(), {"item_1": 4})
	assert_eq(_state.rejected_payload_count, bad_sessions.size())
	var bad_items: Array = [
		[7, [], []],
		[FIRST, "x", []],
		[FIRST, [], "x"],
		[FIRST, [_item("item_2", 0, 1)], []],
		[FIRST, [_item("item_2", 1, 1), _item("item_2", 1, 2)], []],
		[FIRST, [], [7]],
		[FIRST, [], [""]],
		[FIRST, too_many, []],
	]
	for payload: Array in bad_items:
		assert_false(_state.apply_items(payload[0], payload[1], payload[2]), str(payload).left(120))
		assert_eq(_quantities(), {"item_1": 4})


func test_request_validation_and_what_a_refusal_tells() -> void:
	assert_eq(ContainerNetModule.validate_container_request(1, FIRST), "")
	assert_eq(ContainerNetModule.validate_container_request(0, FIRST), "", "request id 0 is usable")
	assert_eq(ContainerNetModule.validate_container_request("1", FIRST), IntentValidator.REASON_BAD_TYPE)
	assert_eq(ContainerNetModule.validate_container_request(1, 7), IntentValidator.REASON_BAD_TYPE)
	assert_eq(ContainerNetModule.validate_container_request(-1, FIRST), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(ContainerNetModule.validate_container_request(1, ""), ContainerNetModule.REASON_BAD_CONTAINER_ID)
	assert_eq(ContainerNetModule.validate_container_request(1, "c".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1)), ContainerNetModule.REASON_BAD_CONTAINER_ID)
	assert_eq(ContainerNetModule.validate_item_request(1, FIRST, "item_000001", 0), "", "0 = the whole stack")
	assert_eq(ContainerNetModule.validate_item_request(1, FIRST, "item_000001", 3), "")
	assert_eq(ContainerNetModule.validate_item_request(1, FIRST, "item_000001", -1), InventoryService.REASON_BAD_QUANTITY)
	assert_eq(ContainerNetModule.validate_item_request(1, FIRST, "item_000001", 1.0), IntentValidator.REASON_BAD_TYPE)
	assert_eq(ContainerNetModule.validate_item_request(1, FIRST, 5, 1), IntentValidator.REASON_BAD_TYPE)
	assert_eq(ContainerNetModule.validate_item_request(1, FIRST, "", 1), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(ContainerNetModule.validate_item_request(1, "", "item_000001", 1), ContainerNetModule.REASON_BAD_CONTAINER_ID)
	assert_eq(ContainerNetModule.validate_item_request(-5, FIRST, "item_000001", 1), IntentValidator.REASON_BAD_SEQUENCE)
	# A refusal about a container the requester is not told about says only
	# "unknown", whatever the rule said; a refusal about the requester itself
	# is told as it is.
	for reason: String in [ContainerService.REASON_TOO_FAR, ContainerService.REASON_NOT_OPEN, ContainerService.REASON_ALREADY_OPEN, ContainerService.REASON_SEARCHING, ContainerService.REASON_ITEM_NOT_INSIDE, ContainerService.REASON_CONTAINER_FULL, ContainerService.REASON_UNKNOWN_CONTAINER]:
		assert_eq(ContainerNetModule.public_reason(reason, false, true), ContainerService.REASON_UNKNOWN_CONTAINER, reason)
		assert_eq(ContainerNetModule.public_reason(reason, true, true), reason, "a container the requester is told about: the rule's reason")
	for reason: String in ["player_dead", "player_resting", ServerWorld.REASON_NOT_ONLINE]:
		assert_eq(ContainerNetModule.public_reason(reason, false, false), reason)
	# The wire rows.
	assert_eq(ContainerNetModule.encode_row({"container_id": FIRST, "definition_id": CRATE, "position": [1, 0, 2.5], "searched": true}), [FIRST, CRATE, 1.0, 0.0, 2.5, true])
	assert_true(_state.is_valid_row(ContainerNetModule.encode_row({"container_id": FIRST, "definition_id": CRATE, "position": [1, 0, 2.5], "searched": true})))
	var rows: Array = ContainerNetModule.encode_items([{"item_instance_id": "item_1", "definition_id": FOOD, "quantity": 2, "slot": 3}, "junk"])
	assert_eq(rows, [["item_1", FOOD, 2, 3]])
	assert_true(ClientContainerState.is_valid_item_row(rows[0]))
	# Settings.
	assert_eq(ContainerNetSettings.load_or_default().validate().size(), 0)
	var broken: ContainerNetSettings = ContainerNetSettings.new()
	broken.container_intent_burst = 0
	assert_true(broken.validate().size() > 0)
	var big: ContainerCatalog = ContainerCatalog.new()
	var definition: ContainerDefinition = ContainerDefinition.new()
	definition.definition_id = "huge"
	definition.slot_count = ClientContainerState.MAX_CONTENT_ENTRIES + 1
	big.add(definition)
	assert_true(_settings.validate_against(big).size() > 0, "a container may not hold more stacks than a client accepts")
	assert_eq(_settings.validate_against(ContainerCatalog.load_directory()).size(), 0)
