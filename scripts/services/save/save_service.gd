class_name SaveService
extends RefCounted
## Versioned, atomic JSON world saves (docs/10). Server only.
##
## Layout (docs/10 §3, Phase 1 subset):
##   <root>/<world_id>/manifest.json
##   <root>/<world_id>/world_state.json
##   <root>/<world_id>/players/<player_id>.json
##   <root>/<world_id>/backups/gen_<N>/...      (previous generation's files)
##
## Save procedure (docs/10 §4): every document is written to `<file>.tmp`,
## read back and compared byte-for-byte; only when all temp files verify are
## the current files copied to backups/gen_<old> and replaced by rename. The
## manifest (new generation) is written last. Any failure before the first
## rename leaves the previous save untouched.
## Load: each file is parsed and migrated; a corrupt file falls back to the
## newest backup copy that parses (docs/10 §8).

const MANIFEST_FILE: String = "manifest.json"
const WORLD_STATE_FILE: String = "world_state.json"
const PLAYERS_DIR: String = "players"
const BACKUPS_DIR: String = "backups"
const BACKUP_PREFIX: String = "gen_"
const TMP_SUFFIX: String = ".tmp"
const MANIFEST_SCHEMA_VERSION: int = 1
const CATEGORY_WORLD: String = "world"
const CATEGORY_PLAYER: String = "player"
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
	for category: String in [CATEGORY_WORLD, CATEGORY_PLAYER]:
		if not _migrators.has(category):
			_migrators[category] = defaults[category]


func world_dir(world_id: String) -> String:
	return _root.path_join(world_id)


func has_save(world_id: String) -> bool:
	return FileAccess.file_exists(world_dir(world_id).path_join(MANIFEST_FILE))


## Current generation number (0 when there is no save).
func current_generation(world_id: String) -> int:
	var manifest: Dictionary = _read_json(world_dir(world_id).path_join(MANIFEST_FILE))
	return int(manifest.get("generation", 0))


## Saves `world_state` and `players` (player_id -> document). Every document
## must contain `schema_version` and only JSON-safe values.
func save_world(world_id: String, world_state: Dictionary, players: Dictionary) -> Error:
	if not LaunchConfig.is_valid_world_id(world_id):
		return _fail("invalid world id", world_id, ERR_INVALID_PARAMETER)
	var documents: Dictionary[String, Dictionary] = {WORLD_STATE_FILE: world_state}
	for player_id: Variant in players:
		if typeof(player_id) != TYPE_STRING or not PlayerState.is_valid_player_id(str(player_id)):
			return _fail("invalid player id '%s'" % str(player_id), world_id, ERR_INVALID_PARAMETER)
		documents[PLAYERS_DIR.path_join(str(player_id) + ".json")] = players[player_id]
	for rel_path: String in documents:
		var document: Dictionary = documents[rel_path]
		if not document.has(SaveMigrator.KEY_SCHEMA_VERSION):
			return _fail("document without schema_version: " + rel_path, world_id, ERR_INVALID_DATA)
		if not is_json_safe(document):
			return _fail("document contains non-JSON values: " + rel_path, world_id, ERR_INVALID_DATA)

	var base: String = world_dir(world_id)
	if DirAccess.make_dir_recursive_absolute(base.path_join(PLAYERS_DIR)) != OK:
		return _fail("cannot create save directory", world_id, ERR_CANT_CREATE)

	# 1-3. write temp files and verify them.
	var written: PackedStringArray = []
	for rel_path: String in documents:
		var text: String = JSON.stringify(documents[rel_path], JSON_INDENT, true)
		var tmp_path: String = base.path_join(rel_path + TMP_SUFFIX)
		if not _write_text(tmp_path, text) or _read_text(tmp_path) != text:
			_remove_files(base, written)
			DirAccess.remove_absolute(tmp_path)
			return _fail("temp file verification failed: " + rel_path, world_id, ERR_FILE_CANT_WRITE)
		written.append(rel_path + TMP_SUFFIX)

	# 4. back up the current generation, then swap files in.
	var old_generation: int = current_generation(world_id)
	var new_generation: int = old_generation + 1
	var old_files: PackedStringArray = _manifest_files(world_id)
	if old_generation > 0:
		var backup_dir: String = base.path_join(BACKUPS_DIR).path_join(BACKUP_PREFIX + str(old_generation))
		for rel_path: String in old_files + PackedStringArray([MANIFEST_FILE]):
			var source: String = base.path_join(rel_path)
			if FileAccess.file_exists(source):
				DirAccess.make_dir_recursive_absolute(backup_dir.path_join(rel_path).get_base_dir())
				if DirAccess.copy_absolute(source, backup_dir.path_join(rel_path)) != OK:
					_remove_files(base, written)
					return _fail("backup failed: " + rel_path, world_id, ERR_FILE_CANT_WRITE)
	for rel_path: String in documents:
		if DirAccess.rename_absolute(base.path_join(rel_path + TMP_SUFFIX), base.path_join(rel_path)) != OK:
			return _fail("rename failed (previous generation is in backups): " + rel_path, world_id, ERR_FILE_CANT_WRITE)

	# 5. manifest last. Files of players not in this save stay listed.
	var files: PackedStringArray = old_files.duplicate()
	for rel_path: String in documents:
		if not files.has(rel_path):
			files.append(rel_path)
	files.sort()
	var manifest: Dictionary = {
		"schema_version": MANIFEST_SCHEMA_VERSION,
		"world_id": world_id,
		"generation": new_generation,
		"saved_at_utc": int(Time.get_unix_time_from_system()),
		"game_version": BuildInfo.game_version(),
		"files": Array(files),
	}
	var manifest_text: String = JSON.stringify(manifest, JSON_INDENT, true)
	var manifest_tmp: String = base.path_join(MANIFEST_FILE + TMP_SUFFIX)
	if not _write_text(manifest_tmp, manifest_text) or DirAccess.rename_absolute(manifest_tmp, base.path_join(MANIFEST_FILE)) != OK:
		return _fail("manifest write failed", world_id, ERR_FILE_CANT_WRITE)
	_prune_backups(base, new_generation)
	GameLogger.info("save", "world saved", {"world_id": world_id, "generation": new_generation, "documents": documents.size()})
	return OK


## Loads a world. Returns {"error": Error, "world_state": Dictionary,
## "players": {player_id: Dictionary}, "generation": int, "warnings": PackedStringArray}.
func load_world(world_id: String) -> Dictionary:
	var result: Dictionary = {"error": OK, "world_state": {}, "players": {}, "generation": 0, "warnings": PackedStringArray()}
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
	GameLogger.info("save", "world loaded", {"world_id": world_id, "generation": result["generation"], "players": players.size(), "warnings": warnings.size()})
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


func _load_document(base: String, rel_path: String, category: String, warnings: PackedStringArray) -> Dictionary:
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
			GameLogger.warning("save", "file restored from backup", {"file": rel_path, "backup": path, "operation": "load_world"})
		return migrated
	GameLogger.error("save", "no readable copy of save file", {"file": rel_path, "operation": "load_world"})
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


func _prune_backups(base: String, newest_generation: int) -> void:
	for path: String in _backup_dirs_newest_first(base):
		var generation: int = int(path.get_file().trim_prefix(BACKUP_PREFIX))
		if generation <= newest_generation - 1 - _backup_keep:
			remove_tree(path)


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
