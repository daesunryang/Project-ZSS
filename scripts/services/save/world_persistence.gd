class_name WorldPersistence
extends RefCounted
## Loads/saves a ServerWorld through SaveService. Server only.
##
## World cells (P3-1, docs/09 §15.1): a world loaded or created here keeps
## its released cells in the save itself (SaveWorldCellStore). Loading a
## world brings no cell into memory; the server reads a cell file when a
## player comes near. Every save() is one generation of the whole world:
## world_state.json, the players and every cell that is in memory. That is
## also how a cell is saved before it is released, and why a shutdown save
## flushes every loaded cell.

signal save_completed(request_id: int, error: Error)

var _save: SaveService
var _config: CompositionConfig
var _background_saving: bool = true
var _writer: Callable
var _next_request_id: int = 0
var _next_task_token: int = 0
## {task_id, token, snapshot, world, request_ids, callbacks}
var _active: Dictionary = {}
## Newest snapshot plus every request it coalesces.
var _pending: Dictionary = {}
var _worker_results: Dictionary[int, Dictionary] = {}
var _result_mutex: Mutex = Mutex.new()
var _request_results: Dictionary[int, Error] = {}
var _last_save_error: Error = OK

## Diagnostics exposed through server Performance custom monitors.
var last_save_build_msec: float = 0.0
var last_save_documents_msec: float = 0.0
var last_save_snapshot_msec: float = 0.0
var last_save_validation_msec: float = 0.0
var last_save_write_msec: float = 0.0
var saves_coalesced: int = 0


## Worlds are always built through ServerComposition so loaded and new
## worlds have the same registered systems.
## `background_saving` defaults false for direct test/tool constructions that
## historically require immediate disk state. Production passes AppSettings'
## default-on value explicitly; background tests opt in explicitly as well.
func _init(save_service: SaveService, config: CompositionConfig, background_saving: bool = false, writer: Callable = Callable()) -> void:
	_save = save_service
	_config = config
	_background_saving = background_saving
	_writer = writer if writer.is_valid() else SaveService.write_snapshot


## Returns the saved world, a freshly seeded world when no save exists, or
## null when the save exists but cannot be restored (never silently replaced).
func load_or_create(world_id: String) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(world_id, _config)
	if world == null:
		return null
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	var store: SaveWorldCellStore = SaveWorldCellStore.new(_save, self, world_id)
	if cells != null:
		cells.set_store(store)
	if not _save.has_save(world_id):
		if world.seed_new_world(_config.dev_seed) != OK:
			return null
		if save(world) != OK:
			return null
		return world
	var loaded: Dictionary = _save.load_world(world_id)
	if loaded["error"] != OK:
		GameLogger.fatal("save", "existing save could not be loaded", {"world_id": world_id, "error": error_string(loaded["error"]), "operation": "load_world"})
		return null
	var errors: PackedStringArray = world.restore_documents(loaded["world_state"], loaded["players"])
	if not errors.is_empty():
		GameLogger.fatal("save", "save failed integrity checks", {"world_id": world_id, "errors": "; ".join(errors), "operation": "restore_world"})
		return null
	if cells != null and cells.needs_repartition() and not _repartition(world, cells, store, loaded["cell_ids"] as PackedStringArray):
		return null
	# P3-3: a world that was saved before it got the configured map content
	# gets it now, once (a new world got it when it was seeded). The seeding
	# saves what it placed; a world that has it already is left alone.
	var map_content: MapContentService = world.get_system(MapContentService.SYSTEM_ID) as MapContentService
	if map_content != null and map_content.ensure_seeded(world) != OK:
		GameLogger.fatal("save", "the map content could not be placed in the saved world", {"world_id": world_id, "operation": "seed_map"})
		return null
	return world


## Saves the whole world now and waits until it is on disk. Existing callers
## use this blocking contract for startup, restart tests and explicit flushes.
func save(world: ServerWorld) -> Error:
	return save_now_and_wait(world)


## Builds a main-thread snapshot and requests a save. With background saving
## enabled, serialization and every file operation run in WorkerThreadPool.
## Requests received while one write runs replace one pending snapshot; all
## their callbacks complete with that one follow-up write.
func request_save(world: ServerWorld, completed: Callable = Callable(), keep_result: bool = false) -> int:
	_next_request_id += 1
	var request_id: int = _next_request_id
	var built: Dictionary = _build_snapshot(world)
	var error: Error = int(built["error"])
	if error != OK:
		_finish_requests([request_id], [completed], [keep_result], error)
		return request_id
	var request: Dictionary = {
		"snapshot": built["snapshot"],
		"cell_cache_updates": built.get("cell_cache_updates", {}),
		"world": world,
		"request_ids": [request_id],
		"callbacks": [completed],
		"keep_results": [keep_result],
	}
	if not _background_saving:
		var result: Dictionary = _write_snapshot(request["snapshot"] as Dictionary)
		_complete_request_batch(request, result)
	elif _active.is_empty():
		_start_worker(request)
	else:
		if _pending.is_empty():
			_pending = request
		else:
			_pending["snapshot"] = request["snapshot"]
			_pending["cell_cache_updates"] = request["cell_cache_updates"]
			_pending["world"] = world
			(_pending["request_ids"] as Array).append(request_id)
			(_pending["callbacks"] as Array).append(completed)
			(_pending["keep_results"] as Array).append(keep_result)
		saves_coalesced += 1
	return request_id


## Saves the newest state and blocks for the write that contains it. If a
## previous write is in flight this becomes the single coalesced follow-up.
## Every WorkerThreadPool task is waited here or in _finish_worker().
func save_now_and_wait(world: ServerWorld) -> Error:
	var request_id: int = request_save(world, Callable(), true)
	while not _request_results.has(request_id):
		if _active.is_empty():
			return FAILED
		_finish_worker(int(_active["token"]))
	var error: Error = _request_results[request_id]
	_request_results.erase(request_id)
	return error


## Waits for an already requested save and any coalesced follow-up. Used by
## shutdown when persist() has just captured the final world state.
func flush() -> Error:
	var error: Error = OK
	while not _active.is_empty():
		var token: int = int(_active["token"])
		_finish_worker(token)
		if _last_save_error != OK:
			error = _last_save_error
	return error


func is_save_in_flight() -> bool:
	return not _active.is_empty()


func _build_snapshot(world: ServerWorld) -> Dictionary:
	var started_usec: int = Time.get_ticks_usec()
	var now: int = int(Time.get_unix_time_from_system())
	for player_id: String in world.online_player_ids():
		world.get_player(player_id).last_saved_at_utc = now
	var documents_started_usec: int = Time.get_ticks_usec()
	var documents: Dictionary = world.to_documents()
	last_save_documents_msec = float(Time.get_ticks_usec() - documents_started_usec) / 1000.0
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	var cache_updates: Dictionary = cells.take_save_cache_updates() if cells != null else {}
	var snapshot_started_usec: int = Time.get_ticks_usec()
	# to_documents() returns fresh immutable save data; cached cell documents
	# are replaced, never mutated. Validation and serialization belong to the
	# worker, so the main thread neither walks nor deep-copies the full tree.
	var built: Dictionary = _save.build_snapshot(world.world_id, documents["world_state"], documents["players"], documents["cells"], bool(documents["replace_cells"]), false, false)
	last_save_snapshot_msec = float(Time.get_ticks_usec() - snapshot_started_usec) / 1000.0
	built["cell_cache_updates"] = cache_updates
	last_save_build_msec = float(Time.get_ticks_usec() - started_usec) / 1000.0
	if int(built["error"]) != OK:
		GameLogger.error("save", str(built["message"]), {"world_id": world.world_id, "error": error_string(int(built["error"])), "operation": "build_save"})
	return built


func _start_worker(request: Dictionary) -> void:
	_next_task_token += 1
	var token: int = _next_task_token
	var task_id: int = WorkerThreadPool.add_task(_worker_write.bind(token, request["snapshot"] as Dictionary), false, "world save")
	request["token"] = token
	request["task_id"] = task_id
	_active = request


func _worker_write(token: int, snapshot: Dictionary) -> void:
	var result: Dictionary = _write_snapshot(snapshot)
	_result_mutex.lock()
	_worker_results[token] = result
	_result_mutex.unlock()
	call_deferred("_finish_worker", token)


func _write_snapshot(snapshot: Dictionary) -> Dictionary:
	var started_usec: int = Time.get_ticks_usec()
	var result: Dictionary = _writer.call(_save.root_path(), _save.backup_keep(), snapshot)
	result["write_msec"] = float(Time.get_ticks_usec() - started_usec) / 1000.0
	return result


func _finish_worker(token: int) -> void:
	if _active.is_empty() or int(_active["token"]) != token:
		return
	WorkerThreadPool.wait_for_task_completion(int(_active["task_id"]))
	_result_mutex.lock()
	var result: Dictionary = _worker_results.get(token, {"error": FAILED, "message": "worker returned no result", "write_msec": 0.0})
	_worker_results.erase(token)
	_result_mutex.unlock()
	var completed_request: Dictionary = _active
	_active = {}
	if not _pending.is_empty():
		var next: Dictionary = _pending
		_pending = {}
		_start_worker(next)
	_complete_request_batch(completed_request, result)


func _complete_request_batch(request: Dictionary, result: Dictionary) -> void:
	last_save_write_msec = float(result.get("write_msec", 0.0))
	last_save_validation_msec = float(result.get("validation_msec", 0.0))
	var world: ServerWorld = request["world"] as ServerWorld
	var error: Error = int(result.get("error", FAILED))
	_last_save_error = error
	if error == OK:
		var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
		if cells != null:
			cells.on_world_saved(request.get("cell_cache_updates", {}))
		GameLogger.info("save", "world saved", {"world_id": world.world_id, "generation": result.get("generation", 0), "documents": result.get("documents", 0), "written": result.get("written", 0), "write_msec": last_save_write_msec})
	else:
		GameLogger.error("save", str(result.get("message", "world save failed")), {"world_id": world.world_id, "error": error_string(error), "operation": "save_world"})
	_finish_requests(request["request_ids"] as Array, request["callbacks"] as Array, request["keep_results"] as Array, error)


func _finish_requests(request_ids: Array, callbacks: Array, keep_results: Array, error: Error) -> void:
	for index: int in range(request_ids.size()):
		var request_id: int = int(request_ids[index])
		if bool(keep_results[index]):
			_request_results[request_id] = error
		var callback: Callable = callbacks[index]
		if callback.is_valid():
			callback.call(error)
		save_completed.emit(request_id, error)


## The save was cut with another cell grid (the cell size or the map bounds
## were changed): reads every cell file, gives every entity the cell of its
## position in the new grid and writes the whole world again, replacing the
## old cell files in one generation. False (logged) when a cell file cannot
## be read or restored: the save is then left as it is.
func _repartition(world: ServerWorld, cells: WorldCellService, store: SaveWorldCellStore, cell_ids: PackedStringArray) -> bool:
	var documents: Dictionary = {}
	for cell_id: String in cell_ids:
		var loaded: Dictionary = _save.load_cell(world.world_id, cell_id)
		if loaded["error"] != OK:
			GameLogger.fatal("save", "cell file could not be read for the new cell grid", {"world_id": world.world_id, "cell_id": cell_id, "error": error_string(loaded["error"]), "operation": "repartition"})
			return false
		documents[cell_id] = loaded["document"]
	var errors: PackedStringArray = world.repartition_from(documents)
	if not errors.is_empty():
		GameLogger.fatal("save", "saved cells could not be sorted into the new cell grid", {"world_id": world.world_id, "errors": "; ".join(errors), "operation": "repartition"})
		return false
	store.discard_saved_cells()
	cells.repartition_done()
	if save(world) != OK:
		return false
	GameLogger.info("save", "world partitioned for the new cell grid", {"world_id": world.world_id, "old_cells": cell_ids.size(), "cells": _save.saved_cell_ids(world.world_id).size()})
	return true
