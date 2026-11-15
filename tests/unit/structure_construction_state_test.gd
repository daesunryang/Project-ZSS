extends TestCase
## P3-5: what the client mirror of structures (ClientStructureState, docs/09
## §15.5) accepts about a construction: the progress and the materials of a
## row, who is working, and the join fragment that carries both. Every
## payload is validated before anything changes. No network:
## tests/integration/construction_net_test.gd.

const WALL: String = "dev_wall"
const FLOOR: String = "dev_floor"
const WOOD: String = "dev_wood"
const NAILS: String = "dev_nails"
const ALICE: String = "player_000001"
const BOB: String = "player_000002"
const FIRST: String = "structure_000001"
const SECOND: String = "structure_000002"

var _state: ClientStructureState = null
var _settings: StructureNetSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = StructureNetSettings.new()
	_state = ClientStructureState.new(_settings, StructureCatalog.load_directory())


func after_each() -> void:
	GameLogger.set_capture(false)


## A wall under construction: 3 of 4 wood delivered, 2 nails missing.
func _row(structure_id: String, progress: Variant = 0.25, delivered: Variant = null, required: Variant = null, state: String = "constructing") -> Array:
	return [structure_id, WALL, 1, 2, 1, state, false, 0.0, progress, {WOOD: 3} if delivered == null else delivered, {WOOD: 4, NAILS: 2} if required == null else required]


func _fragment(rows: Array, workers: Array) -> Dictionary:
	return {ClientStructureState.KEY_SCHEMA_VERSION: ClientStructureState.SCHEMA_VERSION, ClientStructureState.KEY_STRUCTURES: rows, ClientStructureState.KEY_WORKERS: workers}


func test_a_row_carries_the_progress_and_the_materials_of_a_construction() -> void:
	assert_eq(_state.apply_rows([_row(FIRST)]), 1)
	assert_eq(_state.get_structure(FIRST), {
		"definition_id": WALL, "tile": Vector2i(1, 2), "rotation": 1, "state": "constructing", "door_open": false, "health_fraction": 0.0,
		"progress": 0.25, "delivered": {WOOD: 3}, "required": {WOOD: 4, NAILS: 2},
	})
	# A later row replaces it: more materials, more progress, then completed.
	assert_eq(_state.apply_rows([_row(FIRST, 0.5, {WOOD: 4, NAILS: 2})]), 1)
	assert_eq(_state.get_structure(FIRST)["progress"], 0.5)
	assert_eq(_state.get_structure(FIRST)["delivered"], {WOOD: 4, NAILS: 2})
	assert_eq(_state.apply_rows([_row(FIRST, 1.0, {WOOD: 4, NAILS: 2}, null, "completed")]), 1)
	assert_eq(_state.get_structure(FIRST)["state"], "completed")
	# A free piece and a blueprint nobody brought anything to.
	assert_true(_state.is_valid_row(_row(SECOND, 0.0, {}, {}, "blueprint")))
	assert_true(_state.is_valid_row(_row(SECOND, 0.0, {}, null, "blueprint")))
	assert_true(_state.is_valid_row(_row(SECOND, 1.0, {}, null, "completed")), "a piece nothing was paid for (the dev switch)")
	# The mirror keeps its own copy of what it was sent.
	var required: Dictionary = {WOOD: 4}
	assert_eq(_state.apply_rows([_row(SECOND, 0.0, {}, required, "blueprint")]), 1)
	required[WOOD] = 99
	assert_eq(_state.get_structure(SECOND)["required"], {WOOD: 4})
	assert_eq(_state.rejected_payload_count, 0)


func test_malformed_construction_fields_are_refused() -> void:
	assert_eq(_state.apply_rows([_row(FIRST)]), 1)
	var before: Dictionary = _state.get_structure(FIRST).duplicate(true)
	var too_many_kinds: Dictionary = {}
	for index: int in range(StructureDefinition.MAX_COST_KINDS + 1):
		too_many_kinds["material_%d" % index] = 1
	var bad_rows: Array = [
		# progress
		_row(FIRST, -0.1), _row(FIRST, 1.01), _row(FIRST, NAN), _row(FIRST, INF), _row(FIRST, 1), _row(FIRST, "half"), _row(FIRST, null),
		# required
		_row(FIRST, 0.25, {}, []), _row(FIRST, 0.25, {}, "wood"), _row(FIRST, 0.25, {}, {WOOD: 0}), _row(FIRST, 0.25, {}, {WOOD: -4}),
		_row(FIRST, 0.25, {}, {WOOD: StructureDefinition.MAX_COST_QUANTITY + 1}), _row(FIRST, 0.25, {}, {WOOD: 4.0}), _row(FIRST, 0.25, {}, {7: 4}),
		_row(FIRST, 0.25, {}, {"Not An Item": 4}), _row(FIRST, 0.25, {}, {"w".repeat(100): 4}), _row(FIRST, 0.25, {}, too_many_kinds),
		# delivered: a part of what is required, never more
		_row(FIRST, 0.25, []), _row(FIRST, 0.25, 3), _row(FIRST, 0.25, {WOOD: 5}), _row(FIRST, 0.25, {WOOD: 0}), _row(FIRST, 0.25, {WOOD: 3.0}),
		_row(FIRST, 0.25, {"dev_test_item": 1}), _row(FIRST, 0.25, {WOOD: 1}, {}), _row(FIRST, 0.25, {7: 1}),
		# the right values in a row of the P3-4a length
		_row(FIRST).slice(0, 8),
	]
	for row: Variant in bad_rows:
		assert_false(_state.is_valid_row(row), str(row))
	assert_eq(_state.apply_rows(bad_rows), 0)
	assert_eq(_state.rejected_payload_count, bad_rows.size())
	assert_eq(_state.get_structure(FIRST), before, "nothing changed")


func test_work_changes_say_who_is_working_on_what() -> void:
	assert_eq(_state.apply_rows([_row(FIRST), _row(SECOND, 0.1, {}, {})]), 2)
	var heard: Array[Array] = []
	var change_count: Array[int] = [0]
	_state.work_changed.connect(func(player_id: String, structure_id: String, working: bool, reason: String) -> void: heard.append([player_id, structure_id, working, reason]))
	_state.changed.connect(func() -> void: change_count[0] += 1)
	assert_true(_state.apply_work_change(ALICE, FIRST, true, ""))
	assert_true(_state.apply_work_change(BOB, FIRST, true, ""))
	assert_eq(_state.work_of(ALICE), FIRST)
	assert_eq(_state.workers_of(FIRST), PackedStringArray([ALICE, BOB]))
	assert_eq(_state.workers_of(SECOND).size(), 0)
	assert_eq(_state.work_of("player_000009"), "")
	# One structure at a time: a start elsewhere moves the worker.
	assert_true(_state.apply_work_change(BOB, FIRST, false, "switched"))
	assert_true(_state.apply_work_change(BOB, SECOND, true, ""))
	assert_eq(_state.work_of(BOB), SECOND)
	assert_true(_state.apply_work_change(ALICE, FIRST, false, "materials_missing"))
	assert_eq(_state.work_of(ALICE), "")
	assert_eq(heard, [[ALICE, FIRST, true, ""], [BOB, FIRST, true, ""], [BOB, FIRST, false, "switched"], [BOB, SECOND, true, ""], [ALICE, FIRST, false, "materials_missing"]])
	assert_eq(change_count[0], 5, "one `changed` per applied work change")
	# A stop for somebody the mirror does not have there is ignored, not an error.
	assert_true(_state.apply_work_change(ALICE, FIRST, false, "stopped"))
	assert_true(_state.apply_work_change(BOB, FIRST, false, "stopped"), "bob works on the other structure")
	assert_eq(_state.unknown_work_stop_count, 2)
	assert_eq(_state.work_of(BOB), SECOND)
	assert_eq(heard.size(), 5)
	assert_eq(_state.rejected_payload_count, 0)
	# A structure that is removed takes its workers with it.
	assert_eq(_state.apply_removed([SECOND]), 1)
	assert_eq(_state.work_of(BOB), "")
	assert_eq(heard.back(), [BOB, SECOND, false, ClientStructureState.REASON_STRUCTURE_REMOVED])
	assert_eq(_state.workers.size(), 0)


func test_malformed_work_changes_are_refused() -> void:
	assert_eq(_state.apply_rows([_row(FIRST)]), 1)
	assert_true(_state.apply_work_change(ALICE, FIRST, true, ""))
	var heard: Array[int] = [0]
	_state.work_changed.connect(func(_player_id: String, _structure_id: String, _working: bool, _reason: String) -> void: heard[0] += 1)
	var bad: Array[Array] = [
		[7, FIRST, true, ""],
		["zombie_000001", FIRST, true, ""],
		["player_" + "1".repeat(100), FIRST, true, ""],
		["", FIRST, true, ""],
		[BOB, 7, true, ""],
		[BOB, "wall", true, ""],
		[BOB, "structure_" + "1".repeat(100), true, ""],
		[BOB, FIRST, 1, ""],
		[BOB, FIRST, "yes", ""],
		[BOB, FIRST, true, null],
		[BOB, FIRST, true, "because"],
		[ALICE, FIRST, false, ""],
		[ALICE, FIRST, false, "r".repeat(ClientStructureState.REASON_MAX_LENGTH + 1)],
		# Nobody can work on a structure the mirror does not have.
		[BOB, SECOND, true, ""],
	]
	for change: Array in bad:
		assert_false(_state.apply_work_change(change[0], change[1], change[2], change[3]), str(change))
	assert_eq(_state.rejected_payload_count, bad.size())
	assert_eq(heard[0], 0)
	assert_eq(_state.workers, {ALICE: FIRST} as Dictionary[String, String], "the mirror is as it was")


func test_a_join_fragment_carries_the_constructions_and_who_works_on_them() -> void:
	assert_eq(_state.apply_rows([_row("structure_000009")]), 1)
	assert_true(_state.apply_work_change(ALICE, "structure_000009", true, ""))
	assert_true(_state.apply_join(_fragment([_row(FIRST), _row(SECOND, 0.0, {}, {WOOD: 2}, "blueprint")], [[ALICE, FIRST], [BOB, FIRST]])))
	assert_eq(_state.structure_ids(), PackedStringArray([FIRST, SECOND]), "what was there before the join is gone")
	assert_eq(_state.get_structure(FIRST)["progress"], 0.25)
	assert_eq(_state.get_structure(SECOND)["required"], {WOOD: 2})
	assert_eq(_state.workers_of(FIRST), PackedStringArray([ALICE, BOB]))
	assert_eq(_state.workers.size(), 2)
	# {} = the server has no building system.
	assert_true(_state.apply_join({}))
	assert_eq(_state.structure_count() + _state.workers.size(), 0)
	var too_many: Array = []
	for index: int in range(ClientStructureState.MAX_WORKER_ROWS + 1):
		too_many.append(["player_%06d" % (index + 1), FIRST])
	var bad_fragments: Array[Dictionary] = [
		{"schema_version": 2, "structures": [_row(FIRST)]},
		{"schema_version": 1, "structures": [_row(FIRST)], "workers": []},
		_fragment([_row(FIRST)], [[ALICE, SECOND]]),
		_fragment([_row(FIRST)], [[ALICE, FIRST], [ALICE, FIRST]]),
		_fragment([_row(FIRST)], [[ALICE]]),
		_fragment([_row(FIRST)], [[ALICE, FIRST, true]]),
		_fragment([_row(FIRST)], [["zombie_000001", FIRST]]),
		_fragment([_row(FIRST)], [[ALICE, 7]]),
		_fragment([_row(FIRST)], ["alice"]),
		_fragment([_row(FIRST)], too_many),
		{"schema_version": 2, "structures": [_row(FIRST)], "workers": {}},
		_fragment([_row(FIRST, 2.0)], []),
	]
	for fragment: Dictionary in bad_fragments:
		assert_eq(_state.apply_rows([_row("structure_000009")]), 1)
		assert_true(_state.apply_work_change(ALICE, "structure_000009", true, ""))
		assert_false(_state.apply_join(fragment), str(fragment).left(200))
		assert_eq(_state.structure_count() + _state.workers.size(), 0, "a refused join leaves an empty mirror")
	assert_eq(_state.rejected_payload_count, bad_fragments.size())


func test_the_row_the_server_makes_for_a_construction_passes_the_client_check() -> void:
	var catalog: StructureCatalog = ConstructionTestKit.structures()
	var state: ClientStructureState = ClientStructureState.new(_settings, catalog)
	var world: ServerWorld = ServerWorld.new("row_world", GameplaySettings.new(), ConstructionTestKit.items())
	var service: BuildingService = BuildingService.new(BuildingSettings.new(), catalog, world.ids, world.registry, world.clock)
	assert_eq(world.register_system(service), OK)
	var alice: PlayerState = world.join("alice")
	assert_true(ConstructionTestKit.give(world, alice, ConstructionTestKit.PLANK, 3))
	var placed: ActionResult = service.try_place(world, alice.player_id, ConstructionTestKit.WALL, Vector2i(0, 0), 1)
	assert_true(placed.ok, placed.reason)
	var wall_id: String = str(placed.event["structure_id"])
	var delivered: ActionResult = service.try_deliver(world, alice.player_id, wall_id)
	assert_true(delivered.ok, delivered.reason)
	for event: Dictionary in [placed.event, delivered.event]:
		var row: Array = ClientStructureState.encode_row(event)
		assert_eq(row.size(), ClientStructureState.ROW_SIZE)
		assert_true(state.is_valid_row(row), str(row))
		# After a transfer the values keep their types.
		var transferred: Variant = bytes_to_var(var_to_bytes(row))
		assert_true(state.is_valid_row(transferred), str(transferred))
	var row: Array = ClientStructureState.encode_row(delivered.event)
	assert_eq(row[ClientStructureState.ROW_PROGRESS], 0.0)
	assert_eq(row[ClientStructureState.ROW_DELIVERED], {ConstructionTestKit.PLANK: 3})
	assert_eq(row[ClientStructureState.ROW_REQUIRED], {ConstructionTestKit.PLANK: 4, ConstructionTestKit.NAIL: 2})
	# Nothing private goes onto the wire: not who placed it, not who delivered.
	assert_false(str(row).contains(alice.player_id))
	# A row without the construction keys is no row.
	var incomplete: Dictionary = delivered.event.duplicate(true)
	incomplete.erase("delivered")
	assert_eq(ClientStructureState.encode_row(incomplete), [])
	incomplete = delivered.event.duplicate(true)
	incomplete["required"] = "planks"
	assert_eq(ClientStructureState.encode_row(incomplete), [])
