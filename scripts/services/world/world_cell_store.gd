class_name WorldCellStore
extends RefCounted
## Where the entities of unloaded world cells are kept (P3-1, docs/09
## §15.1). WorldCellService saves a cell here before it releases it and
## reads it back when the cell is loaded again (docs/03 §3.2).
##
## This base class keeps the cell documents in memory: for tests and tools.
## Nothing here survives the process. A dedicated server uses
## SaveWorldCellStore, whose cell documents are files of the world save. A
## WorldCellService without any store never releases a cell.
##
## Documents are WorldCellDocument dictionaries. They are stored after a
## JSON round trip, so a memory store hands back exactly what a file would
## (whole numbers come back as floats).

const KEY_ERROR: String = "error"
const KEY_DOCUMENT: String = "document"

## cell_id -> saved document (cells that hold nothing are not kept).
var _documents: Dictionary[String, Dictionary] = {}


## True when every cell that is in memory is written to this store with
## every world save (the store is the world save itself). Then the world
## document holds no entity of a loaded cell. False: the world document
## holds the entities that are in memory and this store only the cells that
## were released.
func saves_loaded_cells() -> bool:
	return false


## The saved document of a cell: {"error": Error, "document": Dictionary}.
## OK with an empty document = nothing was ever saved for this cell (an
## empty cell). An error = the cell cannot be loaded now.
func load_cell(cell_id: String) -> Dictionary:
	var document: Dictionary = _documents.get(cell_id, {})
	return {KEY_ERROR: OK, KEY_DOCUMENT: document.duplicate(true)}


## Saves these cells of `world` (they are in memory) so that they can be
## released. All or nothing: on an error no saved document changed.
func save_cells(world: ServerWorld, cell_ids: PackedStringArray) -> Error:
	var saved: Dictionary[String, Dictionary] = {}
	for cell_id: String in cell_ids:
		var document: Dictionary = world.cell_document(cell_id)
		if not SaveService.is_json_safe(document):
			GameLogger.error("cells", "cell document contains non-JSON values", {"world_id": world.world_id, "cell_id": cell_id, "operation": "save_cells"})
			return ERR_INVALID_DATA
		var copy: Variant = JSON.parse_string(JSON.stringify(document))
		if typeof(copy) != TYPE_DICTIONARY:
			return ERR_INVALID_DATA
		saved[cell_id] = copy as Dictionary
	for cell_id: String in saved:
		if WorldCellDocument.is_empty(saved[cell_id]):
			_documents.erase(cell_id)
		else:
			_documents[cell_id] = saved[cell_id]
	return OK


## Ids of the cells this store has a document for, sorted.
func saved_cell_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_documents.keys())
	ids.sort()
	return ids


## Copy of the stored document of a cell ({} = none).
func document_of(cell_id: String) -> Dictionary:
	return (_documents.get(cell_id, {}) as Dictionary).duplicate(true)


## Replaces the stored documents ({cell_id: document}; used when a world
## is restored from documents that were taken with a memory store).
func replace_documents(documents: Dictionary) -> void:
	_documents.clear()
	for key: Variant in documents:
		if typeof(documents[key]) == TYPE_DICTIONARY and not WorldCellDocument.is_empty(documents[key] as Dictionary):
			_documents[str(key)] = (documents[key] as Dictionary).duplicate(true)
