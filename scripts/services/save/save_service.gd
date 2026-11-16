class_name SaveService
extends RefCounted
## Versioned, atomic JSON world saves (docs/10). Server only.
##
## Layout (docs/10 §3, subset):
##   <root>/<world_id>/manifest.json
##   <root>/<world_id>/world_state.json
##   <root>/<world_id>/players/<player_id>.json
##   <root>/<world_id>/cells/<cell_id>.json     (P3-1: WorldCellDocument)
##   <root>/<world_id>/backups/gen_<N>/...      (previous generation's files)
##
## Cells (P3-1, docs/09 §15.1): a save writes the documents of the cells
## that are in memory; the files of the other cells stay as they are and
## stay listed in the manifest, so one generation is always the whole world.
## A cell without any entity has no file. One cell is read with load_cell()
## when the server loads it; load_world() only lists the cell ids.
##
## Save procedure (docs/10 §4): every document is written to `<file>.tmp`,
## read back and compared byte-for-byte; only when all temp files verify are
## the files this save replaces or removes copied to backups/gen_<old> and
## replaced by rename. The manifest (new generation) is written last. Any
## failure before the first rename leaves the previous save untouched.
## A cell file whose content did not change since this service wrote it is
## not written again (and so needs no new backup copy).
## Load: each file is parsed and migrated; a corrupt file falls back to the
## newest backup copy that parses (docs/10 §8).
## Backups: the newest `backup_keep` generations are kept whole; of older
## generations only the copies that are still the newest backup of their
## file are kept (a cell file that is rarely rewritten keeps its one copy).

const MANIFEST_FILE: String = "manifest.json"
const WORLD_STATE_FILE: String = "world_state.json"
const PLAYERS_DIR: String = "players"
const CELLS_DIR: String = "cells"
const BACKUPS_DIR: String = "backups"
const BACKUP_PREFIX: String = "gen_"
const TMP_SUFFIX: String = ".tmp"
const MANIFEST_SCHEMA_VERSION: int = 1
const CATEGORY_WORLD: String = "world"
const CATEGORY_PLAYER: String = "player"
const CATEGORY_CELL: String = "cell"
const JSON_INDENT: String = "\t"
const DEFAULT_BACKUP_KEEP: int = 3

var _root: String
var _backup_keep: int
var _migrators: Dictionary[String, SaveMigrator] = {}


## `root` is e.g. "user://saves". `migrators` maps CATEGORY_* to a migrator;
## missing categories use the production chains in SaveMigrations.defaults().
func _init(root: String, backup_keep: int = DEFAULT_BACKUP_KEEP, migrators: Dictionary[String, SaveMigrator] = {}) -> void:
	_root = root
	_backup_keep = maxi(backup_keep, 1)
	_migrators = migrators
	var defaults: Dictionary[String, SaveMigrator] = SaveMigrations.defaults()
	for category: String in [CATEGORY_WORLD, CATEGORY_PLAYER, CATEGORY_CELL]:
		if not _migrators.has(category):
			_migrators[category] = defaults[category]


func world_dir(world_id: String) -> String:
	return _root.path_join(world_id)


func root_path() -> String:
	return _root


func backup_keep() -> int:
	return _backup_keep


func has_save(world_id: String) -> bool:
	return FileAccess.file_exists(world_dir(world_id).path_join(MANIFEST_FILE))


## Current generation number (0 when there is no save).
func current_generation(world_id: String) -> int:
	var manifest: Dictionary = _read_json(world_dir(world_id).path_join(MANIFEST_FILE))
	return int(manifest.get("generation", 0))


## Relative path of a cell's file inside the world directory.
static func cell_file(cell_id: String) -> String:
	return CELLS_DIR.path_join(cell_id + ".json")


## Saves `world_state`, `players` (player_id -> document) and `cells`
## (cell_id -> WorldCellDocument: the cells that are in memory). Every
## document must contain `schema_version` and only JSON-safe values.
##
## Cell files that are not in `cells` are kept and stay listed. A cell whose
## document holds no entity gets no file, and loses the one it had.
## `replace_cells` true: `cells` is every cell of the world; every other cell
## file is dropped (the world was partitioned again, docs/09 §15.1).
func save_world(world_id: String, world_state: Dictionary, players: Dictionary, cells: Dictionary = {}, replace_cells: bool = false) -> Error:
	var built: Dictionary = build_snapshot(world_id, world_state, players, cells, replace_cells)
	if int(built["error"]) != OK:
		return _fail(str(built["message"]), world_id, int(built["error"]))
	var result: Dictionary = write_snapshot(_root, _backup_keep, built["snapshot"] as Dictionary)
	if int(result["error"]) != OK:
		return _fail(str(result["message"]), world_id, int(result["error"]))
	GameLogger.info("save", "world saved", {"world_id": world_id, "generation": result["generation"], "documents": result["documents"], "written": result["written"]})
	return OK


## Validates and deep-copies a world save on the main thread. The returned
## snapshot contains JSON-safe values only and is never mutated by the writer.
## JSON serialization deliberately happens later in write_snapshot().
func build_snapshot(world_id: String, world_state: Dictionary, players: Dictionary, cells: Dictionary = {}, replace_cells: bool = false) -> Dictionary:
	if not LaunchConfig.is_valid_world_id(world_id):
		return {"error": ERR_INVALID_PARAMETER, "message": "invalid world id", "snapshot": {}}
	var documents: Dictionary[String, Dictionary] = {WORLD_STATE_FILE: world_state}
	for player_id: Variant in players:
		if typeof(player_id) != TYPE_STRING or not PlayerState.is_valid_player_id(str(player_id)):
			return {"error": ERR_INVALID_PARAMETER, "message": "invalid player id '%s'" % str(player_id), "snapshot": {}}
		documents[PLAYERS_DIR.path_join(str(player_id) + ".json")] = players[player_id]
	# Cell files this save takes out of the manifest (cells that are empty now).
	var dropped: PackedStringArray = []
	for cell_id: Variant in cells:
		if typeof(cell_id) != TYPE_STRING or WorldCellGrid.parse_id(str(cell_id)) == null or typeof(cells[cell_id]) != TYPE_DICTIONARY:
			return {"error": ERR_INVALID_PARAMETER, "message": "invalid cell id or document '%s'" % str(cell_id), "snapshot": {}}
		if WorldCellDocument.is_empty(cells[cell_id] as Dictionary):
			dropped.append(cell_file(str(cell_id)))
		else:
			documents[cell_file(str(cell_id))] = cells[cell_id]
	for rel_path: String in documents:
		var document: Dictionary = documents[rel_path]
		if not document.has(SaveMigrator.KEY_SCHEMA_VERSION):
			return {"error": ERR_INVALID_DATA, "message": "document without schema_version: " + rel_path, "snapshot": {}}
		if not is_json_safe(document):
			return {"error": ERR_INVALID_DATA, "message": "document contains non-JSON values: " + rel_path, "snapshot": {}}
	var snapshot: Dictionary = {
		"world_id": world_id,
		"documents": documents.duplicate(true),
		"dropped": dropped.duplicate(),
		"replace_cells": replace_cells,
		"saved_at_utc": int(Time.get_unix_time_from_system()),
		"game_version": BuildInfo.game_version(),
	}
	return {"error": OK, "message": "", "snapshot": snapshot}


## Serializes and atomically writes an immutable snapshot. This entry point is
## safe for WorkerThreadPool: it creates a private writer and touches no Node,
## scene tree, ServerWorld or other live game object. Errors are returned for
## the main thread to log.
static func write_snapshot(root: String, backup_keep: int, snapshot: Dictionary) -> Dictionary:
	var writer: SaveService = SaveService.new(root, backup_keep)
	return writer._write_snapshot(snapshot)


func _write_snapshot(snapshot: Dictionary) -> Dictionary:
	var world_id: String = str(snapshot["world_id"])
	var documents: Dictionary = snapshot["documents"] as Dictionary
	var dropped: PackedStringArray = snapshot["dropped"] as PackedStringArray
	var replace_cells: bool = bool(snapshot["replace_cells"])

	var base: String = world_dir(world_id)
	if DirAccess.make_dir_recursive_absolute(base.path_join(PLAYERS_DIR)) != OK or DirAccess.make_dir_recursive_absolute(base.path_join(CELLS_DIR)) != OK:
		return _write_failure("cannot create save directory", ERR_CANT_CREATE)
	var old_generation: int = current_generation(world_id)
	var new_generation: int = old_generation + 1
	var old_files: PackedStringArray = _manifest_files(world_id)

	# A cell file whose content would not change is left alone: not written,
	# not backed up. Most cells in memory do not change between two saves, and
	# every file costs several disk operations (docs/15 P3-021).
	var texts: Dictionary[String, String] = {}
	for rel_path: String in documents:
		var text: String = JSON.stringify(documents[rel_path], JSON_INDENT, true)
		var is_cell: bool = rel_path.begins_with(CELLS_DIR + "/")
		if not (is_cell and old_files.has(rel_path) and _read_text(base.path_join(rel_path)) == text):
			texts[rel_path] = text
	# Cell files that leave the save: cells that are empty now and, when the
	# cells are replaced, every cell file that is not part of this save.
	var removed: PackedStringArray = []
	for rel_path: String in old_files:
		if rel_path.begins_with(CELLS_DIR + "/") and (dropped.has(rel_path) or (replace_cells and not documents.has(rel_path))):
			removed.append(rel_path)

	# 1-3. write temp files and verify them.
	var written: PackedStringArray = []
	for rel_path: String in texts:
		var tmp_path: String = base.path_join(rel_path + TMP_SUFFIX)
		if not _write_text(tmp_path, texts[rel_path]) or _read_text(tmp_path) != texts[rel_path]:
			_remove_files(base, written)
			DirAccess.remove_absolute(tmp_path)
			return _write_failure("temp file verification failed: " + rel_path, ERR_FILE_CANT_WRITE)
		written.append(rel_path + TMP_SUFFIX)

	# 4. back up what this save replaces or removes (and the manifest), then
	# swap the new files in. Files this save does not touch need no new copy.
	if old_generation > 0:
		var backup_dir: String = base.path_join(BACKUPS_DIR).path_join(BACKUP_PREFIX + str(old_generation))
		for rel_path: String in old_files + PackedStringArray([MANIFEST_FILE]):
			if rel_path != MANIFEST_FILE and not texts.has(rel_path) and not removed.has(rel_path):
				continue
			var source: String = base.path_join(rel_path)
			if FileAccess.file_exists(source):
				DirAccess.make_dir_recursive_absolute(backup_dir.path_join(rel_path).get_base_dir())
				if DirAccess.copy_absolute(source, backup_dir.path_join(rel_path)) != OK:
					_remove_files(base, written)
					return _write_failure("backup failed: " + rel_path, ERR_FILE_CANT_WRITE)
	for rel_path: String in texts:
		if DirAccess.rename_absolute(base.path_join(rel_path + TMP_SUFFIX), base.path_join(rel_path)) != OK:
			return _write_failure("rename failed (previous generation is in backups): " + rel_path, ERR_FILE_CANT_WRITE)

	# 5. manifest last. Files of players and of cells that are not in this
	# save stay listed; removed cell files leave the list and are deleted
	# after the manifest no longer names them.
	var files: PackedStringArray = []
	for rel_path: String in old_files:
		if not removed.has(rel_path):
			files.append(rel_path)
	for rel_path: String in documents:
		if not files.has(rel_path):
			files.append(rel_path)
	files.sort()
	var manifest: Dictionary = {
		"schema_version": MANIFEST_SCHEMA_VERSION,
		"world_id": world_id,
		"generation": new_generation,
		"saved_at_utc": int(snapshot["saved_at_utc"]),
		"game_version": str(snapshot["game_version"]),
		"files": Array(files),
	}
	var manifest_text: String = JSON.stringify(manifest, JSON_INDENT, true)
	var manifest_tmp: String = base.path_join(MANIFEST_FILE + TMP_SUFFIX)
	if not _write_text(manifest_tmp, manifest_text) or DirAccess.rename_absolute(manifest_tmp, base.path_join(MANIFEST_FILE)) != OK:
		return _write_failure("manifest write failed", ERR_FILE_CANT_WRITE)
	_remove_files(base, removed)
	_prune_backups(base, new_generation)
	return {"error": OK, "message": "", "generation": new_generation, "documents": documents.size(), "written": texts.size()}


static func _write_failure(message: String, code: Error) -> Dictionary:
	return {"error": code, "message": message, "generation": 0, "documents": 0, "written": 0}


## Ids of the cells the current save has a file for, sorted.
func saved_cell_ids(world_id: String) -> PackedStringArray:
	var ids: PackedStringArray = []
	for rel_path: String in _manifest_files(world_id):
		if rel_path.begins_with(CELLS_DIR + "/"):
			ids.append(rel_path.get_file().get_basename())
	ids.sort()
	return ids


## Loads the document of one cell (P3-1). Returns {"error": Error,
## "document": Dictionary, "warnings": PackedStringArray}. OK with an empty
## document = the save has no file for this cell (nothing lies there). A
## file that cannot be read falls back to its newest backup copy;
## ERR_FILE_CORRUPT when no copy can be read (the rest of the world is not
## affected, docs/10 §8).
func load_cell(world_id: String, cell_id: String) -> Dictionary:
	var result: Dictionary = {"error": OK, "document": {}, "warnings": PackedStringArray()}
	if WorldCellGrid.parse_id(cell_id) == null:
		result["error"] = ERR_INVALID_PARAMETER
		return result
	var rel_path: String = cell_file(cell_id)
	if not _manifest_files(world_id).has(rel_path):
		return result
	var warnings: PackedStringArray = []
	var document: Dictionary = _load_document(world_dir(world_id), rel_path, CATEGORY_CELL, warnings, "load_cell")
	result["warnings"] = warnings
	if document.is_empty():
		result["error"] = ERR_FILE_CORRUPT
		return result
	result["document"] = document
	return result


## Loads a world. Returns {"error": Error, "world_state": Dictionary,
## "players": {player_id: Dictionary}, "generation": int, "warnings":
## PackedStringArray, "cell_ids": PackedStringArray (the cells that have a
## file; their documents are read one by one with load_cell)}.
func load_world(world_id: String) -> Dictionary:
	var result: Dictionary = {"error": OK, "world_state": {}, "players": {}, "generation": 0, "warnings": PackedStringArray(), "cell_ids": PackedStringArray()}
	if not has_save(world_id):
		result["error"] = ERR_FILE_NOT_FOUND
		return result
	var base: String = world_dir(world_id)
	var manifest: Dictionary = _read_json(base.path_join(MANIFEST_FILE))
	if int(manifest.get("schema_version", 0)) != MANIFEST_SCHEMA_VERSION or str(manifest.get("world_id", "")) != world_id:
		GameLogger.error("save", "manifest invalid", {"world_id": world_id, "operation": "load_world"})
		result["error"] = ERR_FILE_CORRUPT
		return result
	result["generation"] = int(manifest.get("generation", 0))
	var warnings: PackedStringArray = []
	var world_state: Dictionary = _load_document(base, WORLD_STATE_FILE, CATEGORY_WORLD, warnings)
	if world_state.is_empty():
		result["error"] = ERR_FILE_CORRUPT
		result["warnings"] = warnings
		return result
	result["world_state"] = world_state
	var players: Dictionary = {}
	for rel_path: String in _manifest_files(world_id):
		if not rel_path.begins_with(PLAYERS_DIR + "/"):
			continue
		var document: Dictionary = _load_document(base, rel_path, CATEGORY_PLAYER, warnings)
		if document.is_empty():
			continue  # corrupt player file isolated; other data still loads
		players[rel_path.get_file().get_basename()] = document
	result["players"] = players
	result["warnings"] = warnings
	result["cell_ids"] = saved_cell_ids(world_id)
	GameLogger.info("save", "world loaded", {"world_id": world_id, "generation": result["generation"], "players": players.size(), "cells": (result["cell_ids"] as PackedStringArray).size(), "warnings": warnings.size()})
	return result


## True when `value` only contains types that survive JSON unchanged in
## meaning (null, bool, int, float, String, Array, Dictionary with String keys).
static func is_json_safe(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(float(value))
		TYPE_ARRAY:
			for entry: Variant in (value as Array):
				if not is_json_safe(entry):
					return false
			return true
		TYPE_DICTIONARY:
			for key: Variant in (value as Dictionary):
				if typeof(key) != TYPE_STRING or not is_json_safe((value as Dictionary)[key]):
					return false
			return true
		_:
			return false


func _load_document(base: String, rel_path: String, category: String, warnings: PackedStringArray, operation: String = "load_world") -> Dictionary:
	var candidates: PackedStringArray = [base.path_join(rel_path)]
	for backup: String in _backup_dirs_newest_first(base):
		candidates.append(backup.path_join(rel_path))
	for path: String in candidates:
		var document: Dictionary = _read_json(path)
		if document.is_empty():
			if FileAccess.file_exists(path):
				warnings.append("unreadable: " + path)
			continue
		var migrated: Dictionary = _migrators[category].migrate(document)
		if migrated.is_empty():
			warnings.append("migration failed for %s: %s" % [path, _migrators[category].last_error])
			continue
		if path != candidates[0]:
			warnings.append("restored %s from backup %s" % [rel_path, path])
			GameLogger.warning("save", "file restored from backup", {"file": rel_path, "backup": path, "operation": operation})
		return migrated
	GameLogger.error("save", "no readable copy of save file", {"file": rel_path, "operation": operation})
	return {}


func _manifest_files(world_id: String) -> PackedStringArray:
	var manifest: Dictionary = _read_json(world_dir(world_id).path_join(MANIFEST_FILE))
	var files: PackedStringArray = []
	for entry: Variant in manifest.get("files", []):
		files.append(str(entry))
	return files


func _backup_dirs_newest_first(base: String) -> PackedStringArray:
	var generations: Array[int] = []
	var dir: DirAccess = DirAccess.open(base.path_join(BACKUPS_DIR))
	if dir == null:
		return PackedStringArray()
	for name: String in dir.get_directories():
		var number: String = name.trim_prefix(BACKUP_PREFIX)
		if name.begins_with(BACKUP_PREFIX) and number.is_valid_int():
			generations.append(int(number))
	generations.sort()
	generations.reverse()
	var dirs: PackedStringArray = []
	for generation: int in generations:
		dirs.append(base.path_join(BACKUPS_DIR).path_join(BACKUP_PREFIX + str(generation)))
	return dirs


## Deletes backup copies outside the newest `_backup_keep` generations,
## except a copy that is the newest backup of its file: since a save only
## backs up what it replaces, a file that is rarely rewritten (the cell file
## of a quiet area) would otherwise lose its only backup.
func _prune_backups(base: String, newest_generation: int) -> void:
	var has_newer_copy: Dictionary[String, bool] = {}
	for path: String in _backup_dirs_newest_first(base):
		var generation: int = int(path.get_file().trim_prefix(BACKUP_PREFIX))
		var expired: bool = generation <= newest_generation - 1 - _backup_keep
		var rel_paths: PackedStringArray = []
		_list_files(path, "", rel_paths)
		for rel_path: String in rel_paths:
			if expired and has_newer_copy.has(rel_path):
				DirAccess.remove_absolute(path.path_join(rel_path))
			else:
				has_newer_copy[rel_path] = true
		if expired:
			_remove_empty_dirs(path)


## Collects the files under `dir_path` as paths relative to it.
static func _list_files(dir_path: String, prefix: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		out.append(prefix + file_name)
	for sub_dir: String in dir.get_directories():
		_list_files(dir_path.path_join(sub_dir), prefix + sub_dir + "/", out)


## Deletes `path` and its sub-directories as far as they are empty. True
## when `path` itself is gone.
static func _remove_empty_dirs(path: String) -> bool:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return true
	var empty: bool = dir.get_files().is_empty()
	for sub_dir: String in dir.get_directories():
		if not _remove_empty_dirs(path.path_join(sub_dir)):
			empty = false
	if empty:
		DirAccess.remove_absolute(path)
	return empty


## Recursively deletes a directory (used for backup pruning and tests).
static func remove_tree(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for sub_dir: String in dir.get_directories():
		remove_tree(path.path_join(sub_dir))
	for file_name: String in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)


func _remove_files(base: String, rel_paths: PackedStringArray) -> void:
	for rel_path: String in rel_paths:
		DirAccess.remove_absolute(base.path_join(rel_path))


func _write_text(path: String, text: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	var ok: bool = file.store_string(text)
	file.flush()
	file.close()
	return ok


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _read_json(path: String) -> Dictionary:
	var text: String = _read_text(path)
	if text.is_empty():
		return {}
	var json: JSON = JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {}
	return json.data as Dictionary


func _fail(message: String, world_id: String, code: Error) -> Error:
	GameLogger.error("save", message, {"world_id": world_id, "operation": "save_world"})
	return code
