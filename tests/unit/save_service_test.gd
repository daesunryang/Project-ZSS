extends TestCase
## SaveService / SaveMigrator / PlayerState persistence rules.

const TEST_ROOT: String = "user://test_saves"
const WORLD: String = "save_test_world"

var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = TEST_ROOT.path_join("run_%d" % Time.get_ticks_usec())


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _world_doc(value: int) -> Dictionary:
	return {"schema_version": 1, "world_id": WORLD, "value": value}


func _player(id: String, key: String) -> PlayerState:
	var state: PlayerState = PlayerState.new()
	state.player_id = id
	state.player_key = key
	state.position = Vector3(1.5, 0, -3.25)
	state.yaw = 0.5
	state.inventory_id = "inventory_000001"
	return state


func test_save_then_load_in_new_service_instance() -> void:
	var players: Dictionary = {"player_000002": _player("player_000002", "alice").to_dict()}
	assert_eq(SaveService.new(_root).save_world(WORLD, _world_doc(7), players), OK)
	var loaded: Dictionary = SaveService.new(_root).load_world(WORLD)
	assert_eq(loaded["error"], OK)
	assert_eq(loaded["generation"], 1)
	assert_eq(int((loaded["world_state"] as Dictionary)["value"]), 7)
	var restored: PlayerState = PlayerState.from_dict((loaded["players"] as Dictionary)["player_000002"])
	assert_not_null(restored)
	assert_eq(restored.position, Vector3(1.5, 0, -3.25))
	assert_eq(restored.player_key, "alice")
	assert_eq((loaded["warnings"] as PackedStringArray).size(), 0)


## Floats must come back bit-for-bit (P4-4 found that 14 significant digits
## changed an NPC decision at a need threshold after a restore). Godot 4.7.2's
## JSON parser still reads numbers written in exponent form (|x| < 1e-4 or
## very large, e.g. 3.3333333333333334e-13) back inexactly, so the samples are
## plain-decimal values like the game's times, needs and positions.
const PRECISION_SAMPLES: Array[float] = [1.0 / 3.0, 0.1 + 0.2, 123456.789012345678, -2.0 / 7.0e-5, 2.0 / 3.0 * 100.0]


func test_saved_floats_come_back_exactly() -> void:
	var world_doc: Dictionary = {"schema_version": SaveMigrations.WORLD_SCHEMA_VERSION, "world_id": WORLD, "samples": PRECISION_SAMPLES.duplicate()}
	var cells: Dictionary = {"cell_0_0": WorldCellDocument.create("cell_0_0", {}, {"samples": PRECISION_SAMPLES.duplicate()})}
	assert_eq(SaveService.new(_root).save_world(WORLD, world_doc, {}, cells), OK)
	var service: SaveService = SaveService.new(_root)
	var loaded: Dictionary = service.load_world(WORLD)
	assert_eq(loaded["error"], OK)
	var cell: Dictionary = service.load_cell(WORLD, "cell_0_0")
	assert_eq(cell["error"], OK)
	var world_samples: Array = (loaded["world_state"] as Dictionary)["samples"]
	var cell_samples: Array = ((cell["document"] as Dictionary)[WorldCellDocument.KEY_SYSTEMS] as Dictionary)["samples"]
	for index: int in range(PRECISION_SAMPLES.size()):
		assert_true(float(world_samples[index]) == PRECISION_SAMPLES[index], "world float %d exact" % index)
		assert_true(float(cell_samples[index]) == PRECISION_SAMPLES[index], "cell float %d exact" % index)


func test_released_cell_copy_keeps_floats_exactly() -> void:
	var copy: Dictionary = WorldCellStore.json_copy({"samples": PRECISION_SAMPLES.duplicate()}) as Dictionary
	for index: int in range(PRECISION_SAMPLES.size()):
		assert_true(float((copy["samples"] as Array)[index]) == PRECISION_SAMPLES[index], "released float %d exact" % index)


func test_missing_save_reports_not_found() -> void:
	assert_eq(SaveService.new(_root).load_world(WORLD)["error"], ERR_FILE_NOT_FOUND)


func test_invalid_documents_keep_previous_save() -> void:
	var service: SaveService = SaveService.new(_root)
	assert_eq(service.save_world(WORLD, _world_doc(1), {}), OK)
	var not_json: Dictionary = {"schema_version": 1, "where": Vector3.ONE}
	assert_eq(service.save_world(WORLD, not_json, {}), ERR_INVALID_DATA)
	assert_eq(service.save_world(WORLD, {"value": 2}, {}), ERR_INVALID_DATA)
	assert_eq(service.save_world(WORLD, _world_doc(3), {"../evil": _world_doc(3)}), ERR_INVALID_PARAMETER)
	assert_eq(service.save_world("Bad World", _world_doc(3), {}), ERR_INVALID_PARAMETER)
	var loaded: Dictionary = service.load_world(WORLD)
	assert_eq(int((loaded["world_state"] as Dictionary)["value"]), 1)
	assert_eq(loaded["generation"], 1)
	assert_false(FileAccess.file_exists(service.world_dir(WORLD).path_join("world_state.json.tmp")))


func test_corrupt_file_is_restored_from_backup() -> void:
	var service: SaveService = SaveService.new(_root)
	var players: Dictionary = {"player_000002": _player("player_000002", "bob").to_dict()}
	assert_eq(service.save_world(WORLD, _world_doc(1), players), OK)
	assert_eq(service.save_world(WORLD, _world_doc(2), players), OK)
	var file: FileAccess = FileAccess.open(service.world_dir(WORLD).path_join(SaveService.WORLD_STATE_FILE), FileAccess.WRITE)
	file.store_string("{ not json")
	file.close()
	var loaded: Dictionary = service.load_world(WORLD)
	assert_eq(loaded["error"], OK)
	assert_eq(int((loaded["world_state"] as Dictionary)["value"]), 1, "falls back to previous generation")
	assert_eq((loaded["players"] as Dictionary).size(), 1, "other files still load")
	assert_true((loaded["warnings"] as PackedStringArray).size() > 0)


func test_backups_are_pruned() -> void:
	var service: SaveService = SaveService.new(_root, 2)
	for value: int in range(6):
		assert_eq(service.save_world(WORLD, _world_doc(value), {}), OK)
	var dir: DirAccess = DirAccess.open(service.world_dir(WORLD).path_join(SaveService.BACKUPS_DIR))
	var names: PackedStringArray = dir.get_directories()
	names.sort()
	assert_eq(names, PackedStringArray(["gen_4", "gen_5"]))
	assert_eq(service.current_generation(WORLD), 6)


func test_migration_upgrades_old_documents_on_load() -> void:
	assert_eq(SaveService.new(_root).save_world(WORLD, _world_doc(5), {}), OK)
	var to_v2: Callable = func(doc: Dictionary) -> Dictionary:
		doc["value_doubled"] = int(doc["value"]) * 2
		doc["schema_version"] = 2
		return doc
	var migrations: Dictionary[int, Callable] = {1: to_v2}
	var migrators: Dictionary[String, SaveMigrator] = {SaveService.CATEGORY_WORLD: SaveMigrator.new(2, migrations)}
	var loaded: Dictionary = SaveService.new(_root, 3, migrators).load_world(WORLD)
	assert_eq(loaded["error"], OK)
	var state: Dictionary = loaded["world_state"]
	assert_eq(int(state["schema_version"]), 2)
	assert_eq(int(state["value_doubled"]), 10)


func test_migrator_rejects_unknown_versions() -> void:
	var migrator: SaveMigrator = SaveMigrator.new(2)
	assert_eq(migrator.migrate({"schema_version": 3}), {})
	assert_contains(migrator.last_error, "newer")
	assert_eq(migrator.migrate({"schema_version": 1}), {})
	assert_contains(migrator.last_error, "no migration")
	assert_eq(migrator.migrate({}), {})
	var original: Dictionary = {"schema_version": 2, "x": 1}
	assert_eq(migrator.migrate(original), original)


func test_player_state_validation() -> void:
	var data: Dictionary = _player("player_000009", "carol").to_dict()
	assert_eq(PlayerState.validate_dict(data).size(), 0)
	data["player_id"] = "admin"
	data["position"] = [1, 2]
	assert_eq(PlayerState.validate_dict(data).size(), 2)
	assert_null(PlayerState.from_dict(data))


func test_json_safety_check() -> void:
	assert_true(SaveService.is_json_safe({"a": [1, 2.5, "x", null, true, {"b": 1}]}))
	assert_false(SaveService.is_json_safe({"a": Vector3.ZERO}))
	assert_false(SaveService.is_json_safe({1: "int key"}))
	assert_false(SaveService.is_json_safe({"nan": NAN}))
