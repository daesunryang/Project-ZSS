class_name SaveWorldCellStore
extends WorldCellStore
## The cell store of a saved world (P3-1, docs/10 §3, docs/09 §15.1): the
## cell documents are the files cells/<cell_id>.json of the world save.
## WorldPersistence gives one to the world's WorldCellService.
##
## Saving cells here is saving the WORLD: world_state.json, every player
## and every cell that is in memory go into one save generation
## (WorldPersistence.save). A cell file alone could contradict the rest (a
## zombie that walked from one cell into another would be in both files or
## in neither), so there is no way to write just one.

var _save: SaveService
var _persistence: WorldPersistence
var _world_id: String
## True while the cell files on disk are not valid for this world's grid
## and wait to be replaced by the next save (see discard_saved_cells).
var _discard_saved: bool = false


func _init(save_service: SaveService, persistence: WorldPersistence, world_id: String) -> void:
	_save = save_service
	_persistence = persistence
	_world_id = world_id


func saves_loaded_cells() -> bool:
	return true


func load_cell(cell_id: String) -> Dictionary:
	if _discard_saved:
		return {KEY_ERROR: OK, KEY_DOCUMENT: {}}
	var loaded: Dictionary = _save.load_cell(_world_id, cell_id)
	for warning: String in (loaded["warnings"] as PackedStringArray):
		GameLogger.warning("save", "cell file problem", {"world_id": _world_id, "cell_id": cell_id, "detail": warning, "operation": "load_cell"})
	return {KEY_ERROR: loaded["error"], KEY_DOCUMENT: loaded["document"]}


## Saves the whole world (see the header); the cells in `_cell_ids` are in
## memory and so part of it.
func save_cells(world: ServerWorld, _cell_ids: PackedStringArray) -> Error:
	return _persistence.save(world)


func request_save_cells(world: ServerWorld, _cell_ids: PackedStringArray, completed: Callable) -> void:
	_persistence.request_save(world, completed)


func saved_cell_ids() -> PackedStringArray:
	return PackedStringArray() if _discard_saved else _save.saved_cell_ids(_world_id)


func document_of(cell_id: String) -> Dictionary:
	return load_cell(cell_id)[KEY_DOCUMENT] as Dictionary


## Not supported: the documents of this store are files.
func replace_documents(_documents: Dictionary) -> void:
	GameLogger.error("save", "cell documents of a saved world cannot be replaced in memory", {"world_id": _world_id, "operation": "replace_documents"})


## The cell files on disk were written for another cell grid and their
## entities are all in memory now: from here on no cell has a saved
## document, until the next save writes the new set (WorldPersistence).
func discard_saved_cells() -> void:
	_discard_saved = true


## True while the next save must replace every cell file.
func replaces_saved_cells() -> bool:
	return _discard_saved


## The save that replaced the cell files succeeded.
func saved_cells_replaced() -> void:
	_discard_saved = false
