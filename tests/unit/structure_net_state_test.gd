extends TestCase
## P3-4a: the client mirror of structures (ClientStructureState, docs/09
## §15.4) validates every payload before it changes anything, and the wire
## row of a structure. No network: tests/integration/structure_net_test.gd.

const WALL: String = "dev_wall"
const DOOR: String = "dev_door"
const FLOOR: String = "dev_floor"
const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X

var _state: ClientStructureState = null
var _settings: StructureNetSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = StructureNetSettings.new()
	_state = ClientStructureState.new(_settings, StructureCatalog.load_directory())


func after_each() -> void:
	GameLogger.set_capture(false)


func _row(structure_id: String, definition_id: String = WALL, x: int = 1, z: int = 2, rotation: int = 1, state: String = "completed", door_open: bool = false, health: float = 1.0) -> Array:
	return [structure_id, definition_id, x, z, rotation, state, door_open, health, 1.0, {}, {}]


func _fragment(rows: Array) -> Dictionary:
	return {ClientStructureState.KEY_SCHEMA_VERSION: ClientStructureState.SCHEMA_VERSION, ClientStructureState.KEY_STRUCTURES: rows, ClientStructureState.KEY_WORKERS: []}


func test_rows_add_change_and_remove_structures() -> void:
	var added: PackedStringArray = []
	var changed: PackedStringArray = []
	var removed: PackedStringArray = []
	var change_count: Array[int] = [0]
	_state.structure_added.connect(func(structure_id: String) -> void: added.append(structure_id))
	_state.structure_changed.connect(func(structure_id: String) -> void: changed.append(structure_id))
	_state.structure_removed.connect(func(structure_id: String) -> void: removed.append(structure_id))
	_state.changed.connect(func() -> void: change_count[0] += 1)
	assert_eq(_state.apply_rows([_row("structure_000001"), _row("structure_000002", DOOR, 4, 4, 0)]), 2)
	assert_eq(_state.structure_ids(), PackedStringArray(["structure_000001", "structure_000002"]))
	assert_eq(_state.get_structure("structure_000001"), {"definition_id": WALL, "tile": Vector2i(1, 2), "rotation": 1, "state": "completed", "door_open": false, "health_fraction": 1.0, "progress": 1.0, "delivered": {}, "required": {}})
	assert_eq(_state.slot_of("structure_000001"), Vector3i(2, 2, LOW_X), "the +X side of tile (1, 2)")
	assert_eq(_state.structure_id_at(Vector3i(2, 2, LOW_X)), "structure_000001")
	assert_eq(Array(added), ["structure_000001", "structure_000002"])
	# A row for a known id is a change: the door opens.
	assert_eq(_state.apply_rows([_row("structure_000002", DOOR, 4, 4, 0, "completed", true)]), 1)
	assert_true(bool(_state.get_structure("structure_000002")["door_open"]))
	assert_eq(Array(changed), ["structure_000002"])
	assert_eq(_state.structure_count(), 2)
	# Removal; an id the mirror does not have is ignored, not an error.
	assert_eq(_state.apply_removed(["structure_000001", "structure_000077"]), 1)
	assert_eq(Array(removed), ["structure_000001"])
	assert_false(_state.has_structure("structure_000001"))
	assert_eq(_state.structure_id_at(Vector3i(2, 2, LOW_X)), "")
	assert_eq(_state.unknown_removal_count, 1)
	assert_eq(_state.rejected_payload_count, 0)
	assert_eq(change_count[0], 3, "one `changed` per applied message")
	assert_eq(_state.get_structure("structure_000404"), {})
	assert_eq(_state.slot_of("structure_000404"), Vector3i.ZERO)


func test_a_join_fragment_replaces_the_mirror_or_is_refused_as_a_whole() -> void:
	assert_eq(_state.apply_rows([_row("structure_000009")]), 1)
	assert_true(_state.apply_join(_fragment([_row("structure_000001"), _row("structure_000002", FLOOR, 0, 0, 3)])))
	assert_eq(_state.structure_ids(), PackedStringArray(["structure_000001", "structure_000002"]), "what was there before the join is gone")
	assert_eq(_state.structure_id_at(Vector3i(0, 0, StructureGrid.Layer.TILE)), "structure_000002")
	# {} = the server has no building system.
	assert_true(_state.apply_join({}))
	assert_eq(_state.structure_count(), 0)
	var bad_fragments: Array[Dictionary] = [
		{"schema_version": 2},
		{"schema_version": 2, "structures": []},
		{"schema_version": 1, "structures": [], "workers": []},
		{"schema_version": 3, "structures": [], "workers": []},
		{"schema_version": 2.0, "structures": [], "workers": []},
		{"schema_version": 2, "structures": {}, "workers": []},
		{"schema_version": 2, "structures": [], "workers": [], "extra": true},
		_fragment([_row("structure_000001"), _row("structure_000001", FLOOR)]),
		_fragment([_row("structure_000001"), "not a row"]),
		_fragment([_row("structure_000001"), _row("structure_000002", "no_such_definition")]),
	]
	for fragment: Dictionary in bad_fragments:
		assert_eq(_state.apply_rows([_row("structure_000009")]), 1)
		assert_false(_state.apply_join(fragment), str(fragment))
		assert_eq(_state.structure_count(), 0, "a refused join leaves an empty mirror: %s" % str(fragment))
	assert_eq(_state.rejected_payload_count, bad_fragments.size())
	_settings.max_mirror_structures = 1
	assert_false(_state.apply_join(_fragment([_row("structure_000001"), _row("structure_000002", FLOOR)])), "more structures than the mirror holds")


func test_malformed_rows_are_counted_and_change_nothing() -> void:
	assert_eq(_state.apply_rows([_row("structure_000001")]), 1)
	var before: Dictionary = _state.get_structure("structure_000001").duplicate(true)
	var bad_rows: Array = [
		"row",
		[],
		_row("structure_000002").slice(0, 10),
		_row("structure_000002").slice(0, 8),
		_row("structure_000002") + [0],
		_row("zombie_000002"),
		_row(""),
		_row("structure_" + "1".repeat(80)),
		_row("structure_000002", "no_such_definition"),
		_row("structure_000002", WALL, StructureGrid.MAX_TILE_COORD + 1),
		_row("structure_000002", WALL, 0, -StructureGrid.MAX_TILE_COORD - 1),
		_row("structure_000002", WALL, 0, 0, 4),
		_row("structure_000002", WALL, 0, 0, -1),
		_row("structure_000002", WALL, 0, 0, 0, "standing"),
		_row("structure_000002", WALL, 0, 0, 0, "completed", true),
		_row("structure_000002", WALL, 0, 0, 0, "completed", false, 1.5),
		_row("structure_000002", WALL, 0, 0, 0, "completed", false, -0.1),
		_row("structure_000002", WALL, 0, 0, 0, "completed", false, NAN),
		["structure_000002", WALL, 1.0, 2, 1, "completed", false, 1.0, 1.0, {}, {}],
		["structure_000002", WALL, 1, 2, "1", "completed", false, 1.0, 1.0, {}, {}],
		["structure_000002", WALL, 1, 2, 1, "completed", 0, 1.0, 1.0, {}, {}],
		["structure_000002", WALL, 1, 2, 1, "completed", false, 1, 1.0, {}, {}],
		[7, WALL, 1, 2, 1, "completed", false, 1.0, 1.0, {}, {}],
		["structure_000002", null, 1, 2, 1, "completed", false, 1.0, 1.0, {}, {}],
	]
	for row: Variant in bad_rows:
		assert_false(_state.is_valid_row(row), str(row))
	# Each row is checked on its own: the good row in the same message applies.
	assert_eq(_state.apply_rows(bad_rows + [_row("structure_000003", FLOOR)]), 1)
	assert_eq(_state.rejected_payload_count, bad_rows.size())
	assert_eq(_state.structure_ids(), PackedStringArray(["structure_000001", "structure_000003"]))
	assert_eq(_state.get_structure("structure_000001"), before)
	# Messages that are no list, or too long, are refused as a whole.
	var rejected: int = _state.rejected_payload_count
	assert_eq(_state.apply_rows("rows"), 0)
	assert_eq(_state.apply_rows({}), 0)
	var too_many: Array = []
	for index: int in range(ClientStructureState.MAX_ROWS_PER_MESSAGE + 1):
		too_many.append(_row("structure_%06d" % (100 + index), FLOOR, index, 0))
	assert_eq(_state.apply_rows(too_many), 0)
	assert_eq(_state.apply_removed("structure_000001"), 0)
	assert_eq(_state.apply_removed(too_many), 0)
	assert_eq(_state.apply_removed([7, null, "zombie_000001", "structure_" + "1".repeat(80)]), 0)
	assert_eq(_state.rejected_payload_count, rejected + 5 + 4)
	assert_eq(_state.structure_count(), 2)
	# A full mirror takes no new structure but still follows the ones it has.
	_settings.max_mirror_structures = 2
	assert_eq(_state.apply_rows([_row("structure_000004", FLOOR, 9, 9), _row("structure_000003", FLOOR, 5, 5)]), 1)
	assert_false(_state.has_structure("structure_000004"))
	assert_eq(_state.get_structure("structure_000003")["tile"], Vector2i(5, 5))


func test_the_wire_row_of_a_server_row_passes_the_client_check() -> void:
	var public_row: Dictionary = {"structure_id": "structure_000012", "definition_id": DOOR, "x": -3, "z": 40, "rotation": 2, "state": "completed", "door_open": true, "health_fraction": 0.5, "progress": 1.0, "delivered": {"dev_wood": 3}, "required": {"dev_wood": 3, "dev_nails": 2}}
	var row: Array = ClientStructureState.encode_row(public_row)
	assert_eq(row, ["structure_000012", DOOR, -3, 40, 2, "completed", true, 0.5, 1.0, {"dev_wood": 3}, {"dev_wood": 3, "dev_nails": 2}])
	assert_true(_state.is_valid_row(row))
	# Extra keys of an event (who, where, when) do not go onto the wire.
	var event: Dictionary = public_row.duplicate()
	event.merge({"event_type": "structure_placed", "player_id": "player_000001", "cell_id": "cell_0_4", "world_time": 12.0})
	assert_eq(ClientStructureState.encode_row(event), row)
	assert_eq(row.size(), ClientStructureState.ROW_SIZE)
	var incomplete: Dictionary = public_row.duplicate()
	incomplete.erase("rotation")
	assert_eq(ClientStructureState.encode_row(incomplete), [])
	# After a transfer the values keep their types.
	var transferred: Variant = bytes_to_var(var_to_bytes(row))
	assert_true(_state.is_valid_row(transferred), str(transferred))
	# Every state name of the server is a state the mirror accepts.
	for state_name: String in StructureInstance.STATE_NAMES:
		assert_true(_state.is_valid_row(_row("structure_000001", WALL, 0, 0, 0, state_name)), state_name)
