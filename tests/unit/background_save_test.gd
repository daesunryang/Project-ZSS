extends TestCase
## PERF-1: immutable save snapshots, WorkerThreadPool completion, coalescing
## and the blocking flush path. Waits use completion signals/frame limits,
## never elapsed wall time.

const TEST_ROOT: String = "user://test_saves"
const WORLD: String = "background_save_world"
const MAX_WAIT_FRAMES: int = 600

var _root: String = ""


class BlockingWriter extends RefCounted:
	var gate: Semaphore = Semaphore.new()
	var mutex: Mutex = Mutex.new()
	var writes: int = 0

	func write(root: String, backup_keep: int, snapshot: Dictionary) -> Dictionary:
		mutex.lock()
		writes += 1
		var number: int = writes
		mutex.unlock()
		if number == 1:
			gate.wait()
		return SaveService.write_snapshot(root, backup_keep, snapshot)

	func write_count() -> int:
		mutex.lock()
		var count: int = writes
		mutex.unlock()
		return count


class FailingWriter extends RefCounted:
	func write(_root_path: String, _backup_keep: int, _snapshot: Dictionary) -> Dictionary:
		return {"error": ERR_FILE_CANT_WRITE, "message": "injected writer failure", "generation": 0, "documents": 0, "written": 0}


class UnsafeSaveSystem extends ServerSystem:
	func get_system_id() -> String:
		return "unsafe_save_test"

	func to_world_document() -> Dictionary:
		return {"schema_version": 1, "not_json": Vector3.ZERO}


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = TEST_ROOT.path_join("background_%d" % Time.get_ticks_usec())


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.map_content = null
	return config


func _world() -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_eq(world.seed_new_world(DevWorldSeed.new()), OK)
	return world


func _world_doc(value: int) -> Dictionary:
	return {"schema_version": SaveMigrations.WORLD_SCHEMA_VERSION, "world_id": WORLD, "value": value}


func _collect_files(path: String, prefix: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		out.append(prefix + file_name)
	for sub_dir: String in dir.get_directories():
		_collect_files(path.path_join(sub_dir), prefix + sub_dir + "/", out)


func _wait_until(condition: Callable, max_frames: int = MAX_WAIT_FRAMES) -> bool:
	for frame: int in range(max_frames):
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func test_the_same_snapshot_writes_byte_identical_sync_and_background_files() -> void:
	var service: SaveService = SaveService.new(_root.path_join("builder"))
	var baseline: Dictionary = service.build_snapshot(WORLD, _world_doc(6), {}, {"cell_0_0": WorldCellDocument.create("cell_0_0", {"items": [{"marker": 0}]}, {})})
	var built: Dictionary = service.build_snapshot(WORLD, _world_doc(7), {}, {"cell_0_0": WorldCellDocument.create("cell_0_0", {"items": [{"marker": 1}]}, {})})
	assert_eq(baseline["error"], OK)
	assert_eq(built["error"], OK)
	var sync_root: String = _root.path_join("sync")
	var background_root: String = _root.path_join("background")
	assert_eq(SaveService.write_snapshot(sync_root, 3, baseline["snapshot"])["error"], OK)
	assert_eq(SaveService.write_snapshot(background_root, 3, baseline["snapshot"])["error"], OK)
	assert_eq(SaveService.write_snapshot(sync_root, 3, built["snapshot"])["error"], OK)
	var writer: BlockingWriter = BlockingWriter.new()
	var task_id: int = WorkerThreadPool.add_task(writer.write.bind(background_root, 3, built["snapshot"]), false, "test background save")
	writer.gate.post()
	WorkerThreadPool.wait_for_task_completion(task_id)
	var sync_dir: String = sync_root.path_join(WORLD)
	var background_dir: String = background_root.path_join(WORLD)
	var sync_files: PackedStringArray = []
	var background_files: PackedStringArray = []
	_collect_files(sync_dir, "", sync_files)
	_collect_files(background_dir, "", background_files)
	sync_files.sort()
	background_files.sort()
	assert_eq(background_files, sync_files)
	for rel_path: String in sync_files:
		assert_eq(FileAccess.get_file_as_string(background_dir.path_join(rel_path)), FileAccess.get_file_as_string(sync_dir.path_join(rel_path)), rel_path)


func test_requests_in_flight_coalesce_to_one_follow_up_with_the_newest_state() -> void:
	var writer: BlockingWriter = BlockingWriter.new()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config(), true, writer.write)
	var world: ServerWorld = _world()
	var completed: Array[int] = []
	persistence.save_completed.connect(func(request_id: int, error: Error) -> void:
		assert_eq(error, OK)
		completed.append(request_id)
	)
	persistence.request_save(world)
	assert_true(await _wait_until(func() -> bool: return writer.write_count() == 1), "the first worker started")
	var player: PlayerState = world.join("newest_player")
	player.position = Vector3(12.0, 0.0, -8.0)
	for request: int in range(5):
		persistence.request_save(world)
	assert_eq(writer.write_count(), 1, "rapid requests do not start parallel writers")
	assert_eq(persistence.saves_coalesced, 5)
	writer.gate.post()
	assert_true(await _wait_until(func() -> bool: return completed.size() == 6 and not persistence.is_save_in_flight()), "both generations completed")
	assert_eq(writer.write_count(), 2, "one in flight plus one newest follow-up")
	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config(), false).load_or_create(WORLD)
	assert_not_null(restored)
	assert_not_null(restored.get_player(player.player_id), "the follow-up contains the change made during the first write")
	assert_true(restored.get_player(player.player_id).position.is_equal_approx(player.position))


func test_background_setting_off_completes_synchronously() -> void:
	var save: SaveService = SaveService.new(_root)
	var persistence: WorldPersistence = WorldPersistence.new(save, _config(), false)
	var world: ServerWorld = _world()
	var completed: Array[Error] = []
	persistence.request_save(world, func(error: Error) -> void: completed.append(error))
	assert_eq(completed, [OK])
	assert_false(persistence.is_save_in_flight())
	assert_eq(save.current_generation(WORLD), 1)


func test_blocking_flush_waits_for_the_in_flight_save_and_restores_newest_state() -> void:
	var writer: BlockingWriter = BlockingWriter.new()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config(), true, writer.write)
	var world: ServerWorld = _world()
	persistence.request_save(world)
	assert_true(await _wait_until(func() -> bool: return writer.write_count() == 1))
	var player: PlayerState = world.join("shutdown_player")
	player.position = Vector3(-20.0, 0.0, 16.0)
	writer.gate.post()
	assert_eq(persistence.save_now_and_wait(world), OK, "shutdown-style flush waits for the follow-up")
	assert_false(persistence.is_save_in_flight())
	assert_eq(writer.write_count(), 2)
	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config(), false).load_or_create(WORLD)
	assert_not_null(restored.get_player(player.player_id))
	assert_true(restored.get_player(player.player_id).position.is_equal_approx(player.position))


func test_network_shutdown_waits_for_the_in_flight_save() -> void:
	var writer: BlockingWriter = BlockingWriter.new()
	var config: CompositionConfig = _config()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), config, true, writer.write)
	var world: ServerWorld = _world()
	var cluster: NetTestCluster = NetTestCluster.new(tree, NetworkSettings.load_or_default(), config)
	assert_eq(cluster.start_server(world, persistence), OK)
	persistence.request_save(world)
	assert_true(await _wait_until(func() -> bool: return writer.write_count() == 1))
	var player: PlayerState = world.join("network_shutdown_player")
	player.position = Vector3(18.0, 0.0, -22.0)
	writer.gate.post()
	cluster.server.stop()
	assert_false(persistence.is_save_in_flight(), "NetworkService.stop waits for the coalesced final save")
	assert_eq(writer.write_count(), 2)
	await cluster.shutdown()
	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), config, false).load_or_create(WORLD)
	assert_not_null(restored.get_player(player.player_id))
	assert_true(restored.get_player(player.player_id).position.is_equal_approx(player.position))


func test_background_request_measures_only_the_main_thread_build_cost() -> void:
	var writer: BlockingWriter = BlockingWriter.new()
	var config: CompositionConfig = _config()
	config.map_content = MapContentDefinition.load_or_null()
	var save: SaveService = SaveService.new(_root)
	var prime: WorldPersistence = WorldPersistence.new(save, config, false)
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	assert_eq(world.seed_new_world(DevWorldSeed.new()), OK)
	# Seed without a store so the complete test map stays in memory, matching
	# the PERF-1 measurement scene, then give it production save semantics.
	cells.set_store(SaveWorldCellStore.new(save, prime, WORLD))
	var before_documents_started_usec: int = Time.get_ticks_usec()
	var before_documents: Dictionary = world.to_documents()
	var before_documents_msec: float = float(Time.get_ticks_usec() - before_documents_started_usec) / 1000.0
	var before_breakdown: Dictionary = world.last_document_build_usec.duplicate(true)
	var validation_started_usec: int = Time.get_ticks_usec()
	assert_true(SaveService.is_json_safe(before_documents))
	var validation_msec: float = float(Time.get_ticks_usec() - validation_started_usec) / 1000.0
	var copy_started_usec: int = Time.get_ticks_usec()
	var copied: Dictionary = before_documents.duplicate(true)
	var copy_msec: float = float(Time.get_ticks_usec() - copy_started_usec) / 1000.0
	assert_eq(copied.size(), before_documents.size())
	print("[measure] PERF3_before_documents_ms=%.3f validation_ms=%.3f deep_copy_ms=%.3f cells_built=%d breakdown_usec=%s" % [before_documents_msec, validation_msec, copy_msec, cells.last_save_cells_built, str(before_breakdown)])
	# The optimisation targets ordinary generations after the initial world
	# creation. Prime the cache without measuring this one-time build.
	assert_eq(prime.save(world), OK)
	var persistence: WorldPersistence = WorldPersistence.new(save, config, true, writer.write)
	cells.set_store(SaveWorldCellStore.new(save, persistence, WORLD))
	var started_usec: int = Time.get_ticks_usec()
	persistence.request_save(world)
	var request_msec: float = float(Time.get_ticks_usec() - started_usec) / 1000.0
	print("[measure] background_save_request_main_thread_ms=%.3f build_ms=%.3f documents_ms=%.3f snapshot_ms=%.3f cells_built=%d cells_reused=%d breakdown_usec=%s" % [request_msec, persistence.last_save_build_msec, persistence.last_save_documents_msec, persistence.last_save_snapshot_msec, cells.last_save_cells_built, cells.last_save_cells_reused, str(world.last_document_build_usec)])
	assert_time_bound(request_msec, 100.0, "370-structure test map save request on the main thread")
	assert_true(persistence.last_save_build_msec <= request_msec + 1.0)
	writer.gate.post()
	assert_true(await _wait_until(func() -> bool: return not persistence.is_save_in_flight()))


func test_successful_save_reuses_untouched_cells_and_rebuilds_only_the_changed_cell() -> void:
	var save: SaveService = SaveService.new(_root)
	var persistence: WorldPersistence = WorldPersistence.new(save, _config(), false)
	var world: ServerWorld = _world()
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	cells.set_store(SaveWorldCellStore.new(save, persistence, WORLD))
	var first_position: Vector3 = Vector3(-75.0, 0.0, 0.0)
	var second_position: Vector3 = Vector3(75.0, 0.0, 0.0)
	var first_cell: String = world.cell_id_at(first_position)
	var second_cell: String = world.cell_id_at(second_position)
	assert_ne(first_cell, second_cell)
	assert_false(world.inventory.spawn_world_item("dev_test_item", 1, first_cell, first_position).is_empty())
	assert_false(world.inventory.spawn_world_item("dev_test_item", 1, second_cell, second_position).is_empty())
	assert_eq(persistence.save(world), OK)

	world.to_documents()
	assert_eq(cells.last_save_cells_built, 0)
	assert_eq(cells.last_save_cells_reused, 2)

	assert_false(world.inventory.spawn_world_item("dev_test_item", 1, first_cell, first_position).is_empty())
	var optimized: Dictionary = world.to_documents()
	assert_eq(cells.last_save_cells_built, 1)
	assert_eq(cells.last_save_cells_reused, 1)
	cells.set_save_document_cache_enabled(false)
	var rebuilt: Dictionary = world.to_documents()
	assert_eq(JSON.stringify(optimized["cells"], "", true), JSON.stringify(rebuilt["cells"], "", true), "cached and forced cell documents are byte-identical")
	var optimized_root: String = _root.path_join("optimized")
	var rebuilt_root: String = _root.path_join("rebuilt")
	var optimized_build: Dictionary = SaveService.new(optimized_root).build_snapshot(WORLD, optimized["world_state"], optimized["players"], optimized["cells"], bool(optimized["replace_cells"]))
	var rebuilt_build: Dictionary = SaveService.new(rebuilt_root).build_snapshot(WORLD, rebuilt["world_state"], rebuilt["players"], rebuilt["cells"], bool(rebuilt["replace_cells"]))
	(optimized_build["snapshot"] as Dictionary)["saved_at_utc"] = 123
	(rebuilt_build["snapshot"] as Dictionary)["saved_at_utc"] = 123
	assert_eq(SaveService.write_snapshot(optimized_root, 3, optimized_build["snapshot"] as Dictionary)["error"], OK)
	assert_eq(SaveService.write_snapshot(rebuilt_root, 3, rebuilt_build["snapshot"] as Dictionary)["error"], OK)
	var optimized_files: PackedStringArray = []
	var rebuilt_files: PackedStringArray = []
	_collect_files(optimized_root.path_join(WORLD), "", optimized_files)
	_collect_files(rebuilt_root.path_join(WORLD), "", rebuilt_files)
	optimized_files.sort()
	rebuilt_files.sort()
	assert_eq(optimized_files, rebuilt_files)
	for rel_path: String in optimized_files:
		assert_eq(FileAccess.get_file_as_string(optimized_root.path_join(WORLD).path_join(rel_path)), FileAccess.get_file_as_string(rebuilt_root.path_join(WORLD).path_join(rel_path)), rel_path)


func test_cell_changed_during_an_in_flight_save_is_rebuilt_for_the_follow_up() -> void:
	var writer: BlockingWriter = BlockingWriter.new()
	var save: SaveService = SaveService.new(_root)
	var prime: WorldPersistence = WorldPersistence.new(save, _config(), false)
	var world: ServerWorld = _world()
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	cells.set_store(SaveWorldCellStore.new(save, prime, WORLD))
	var position: Vector3 = Vector3(75.0, 0.0, 0.0)
	var cell_id: String = world.cell_id_at(position)
	assert_false(world.inventory.spawn_world_item("dev_test_item", 1, cell_id, position).is_empty())
	# Prime the cache with a successful generation, then use a blocking
	# background writer for the generation under test.
	assert_eq(prime.save(world), OK)
	var persistence: WorldPersistence = WorldPersistence.new(save, _config(), true, writer.write)
	cells.set_store(SaveWorldCellStore.new(save, persistence, WORLD))

	# The first request reuses the cached document and remains blocked. A
	# mutation then has to make the coalesced follow-up rebuild the cell.
	persistence.request_save(world)
	assert_true(await _wait_until(func() -> bool: return writer.write_count() == 1))
	assert_eq(cells.last_save_cells_reused, 1)
	assert_false(world.inventory.spawn_world_item("dev_test_item", 1, cell_id, position + Vector3(1.0, 0.0, 0.0)).is_empty())
	persistence.request_save(world)
	assert_eq(cells.last_save_cells_built, 1)
	assert_eq(cells.last_save_cells_reused, 0)
	writer.gate.post()
	assert_true(await _wait_until(func() -> bool: return not persistence.is_save_in_flight()))
	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config(), false).load_or_create(WORLD)
	assert_not_null(restored)
	var loaded: Dictionary = save.load_cell(WORLD, cell_id)
	assert_eq(loaded["error"], OK)
	assert_eq(((loaded["document"] as Dictionary)[WorldCellDocument.KEY_WORLD_ITEMS] as Dictionary)[InventoryService.SNAPSHOT_ITEMS].size(), 2)


func test_opening_a_door_invalidates_its_cell_document() -> void:
	var config: CompositionConfig = _config()
	config.map_content = MapContentDefinition.load_or_null()
	var save: SaveService = SaveService.new(_root)
	var persistence: WorldPersistence = WorldPersistence.new(save, config, false)
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	assert_eq(world.seed_new_world(DevWorldSeed.new()), OK)
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	cells.set_store(SaveWorldCellStore.new(save, persistence, WORLD))
	assert_eq(persistence.save(world), OK)
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	var door_id: String = ""
	for structure_id: String in building.structure_ids():
		if building.get_structure(structure_id).definition_id == "dev_door":
			door_id = structure_id
			break
	assert_false(door_id.is_empty())
	var door: StructureInstance = building.get_structure(door_id)
	assert_true(building.set_door_open(world, door_id, not door.door_open).ok)
	var optimized: Dictionary = world.to_documents()
	assert_eq(cells.last_save_cells_built, 1)
	assert_true(cells.last_save_cells_reused >= 1)
	cells.set_save_document_cache_enabled(false)
	var rebuilt: Dictionary = world.to_documents()
	assert_eq(JSON.stringify(optimized["cells"], "", true), JSON.stringify(rebuilt["cells"], "", true))


## Regression (leak at exit, "resources still in use"): once background saves
## and a background cell unload completed, nothing the persistence keeps
## (active/pending request, worker callables, deferred completion, callbacks
## bound to the world) and nothing the world keeps (cell store ->
## persistence) holds the world or the persistence alive.
func test_world_and_persistence_are_freed_after_background_saves() -> void:
	var refs: Array[WeakRef] = await _save_in_background_and_drop()
	await tree.process_frame
	assert_eq(refs.size(), 2)
	assert_null(refs[0].get_ref(), "the world is freed")
	assert_null(refs[1].get_ref(), "the persistence is freed")


func _save_in_background_and_drop() -> Array[WeakRef]:
	var save: SaveService = SaveService.new(_root)
	var persistence: WorldPersistence = WorldPersistence.new(save, _config(), true)
	var world: ServerWorld = _world()
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	cells.set_store(SaveWorldCellStore.new(save, persistence, WORLD))
	var player_id: String = world.join("leak_check").player_id
	var item_id: String = world.inventory.spawn_world_item("dev_test_item", 1, "cell_-2_0", Vector3(-15.0, 0.0, 5.0))
	var completed: Array[Error] = []
	for request: int in range(3):
		persistence.request_save(world, func(error: Error) -> void: completed.append(error))
	world.get_player(player_id).position = Vector3(125.0, 0.0, 5.0)
	for tick: int in range(400):
		world.step_systems(0.1)
		if cells.state_of("cell_-2_0") == WorldCellLifecycle.State.SAVING:
			break
	assert_eq(cells.state_of("cell_-2_0"), WorldCellLifecycle.State.SAVING)
	assert_true(await _wait_until(func() -> bool: return not persistence.is_save_in_flight()))
	assert_eq(cells.state_of("cell_-2_0"), WorldCellLifecycle.State.UNLOADED, "the background unload completed")
	assert_null(world.inventory.get_item(item_id))
	assert_eq(persistence.save_now_and_wait(world), OK)
	assert_eq(completed, [OK, OK, OK] as Array[Error])
	return [weakref(world), weakref(persistence)] as Array[WeakRef]


func test_injected_background_writer_failure_keeps_the_cell_in_memory() -> void:
	var failing: FailingWriter = FailingWriter.new()
	var save: SaveService = SaveService.new(_root)
	var persistence: WorldPersistence = WorldPersistence.new(save, _config(), true, failing.write)
	var world: ServerWorld = _world()
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	cells.set_store(SaveWorldCellStore.new(save, persistence, WORLD))
	var player_id: String = world.join("cell_owner").player_id
	var item_id: String = world.inventory.spawn_world_item("dev_test_item", 1, "cell_-2_0", Vector3(-15.0, 0.0, 5.0))
	world.get_player(player_id).position = Vector3(125.0, 0.0, 5.0)
	for tick: int in range(400):
		world.step_systems(0.1)
		if cells.state_of("cell_-2_0") == WorldCellLifecycle.State.SAVING:
			break
	assert_eq(cells.state_of("cell_-2_0"), WorldCellLifecycle.State.SAVING)
	assert_true(await _wait_until(func() -> bool: return not persistence.is_save_in_flight()))
	assert_eq(cells.state_of("cell_-2_0"), WorldCellLifecycle.State.PRELOADED)
	assert_not_null(world.inventory.get_item(item_id))
	assert_eq(cells.failed_save_count, 1)


func test_worker_validation_error_is_reported_to_the_main_thread() -> void:
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config(), true)
	var world: ServerWorld = _world()
	assert_eq(world.register_system(UnsafeSaveSystem.new()), OK)
	var completed: Array[Error] = []
	persistence.request_save(world, func(error: Error) -> void: completed.append(error))
	assert_true(await _wait_until(func() -> bool: return not persistence.is_save_in_flight()))
	assert_eq(completed, [ERR_INVALID_DATA] as Array[Error])
