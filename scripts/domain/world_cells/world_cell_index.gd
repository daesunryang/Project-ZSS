class_name WorldCellIndex
extends RefCounted
## Which cell each persistent world entity that is in memory is in (P3-1,
## docs/09 §15.1). Ids and plain strings only: no Node references and no
## cell math (the owner of an entity asks ServerWorld.cell_id_at()).
##
## One index per world (ServerWorld.cell_index). The owner of a kind of
## entity keeps it up to date: InventoryService for world items ("item"),
## ZombieService for zombies ("zombie"). Later kinds (containers,
## structures) do the same. Entities of unloaded cells are not in memory
## and so not in the index.

## entity_id -> [cell_id, kind]
var _entries: Dictionary[String, Array] = {}
## cell_id -> {entity_id: kind}
var _cells: Dictionary[String, Dictionary] = {}
## cell_id -> {kind: {entity_id: true}}: the same entities by kind, so a
## question about one kind does not walk every entity of the cell (F-33: a
## town cell holds hundreds of structures and a handful of zombies).
var _by_kind: Dictionary[String, Dictionary] = {}

## Membership changes dirty both the old and new cell save documents.
signal cells_changed(previous_cell_id: String, cell_id: String)


## Puts an entity into a cell, or moves it there (a zombie crossed a
## border). Returns the cell it was in before ("" for a new entity; the same
## id when it did not move). Empty arguments are refused (logged, "").
func put(entity_id: String, kind: String, cell_id: String) -> String:
	if entity_id.is_empty() or kind.is_empty() or cell_id.is_empty():
		GameLogger.error("cells", "index entry with empty id, kind or cell", {"entity_id": entity_id, "kind": kind, "cell_id": cell_id, "operation": "index_put"})
		return ""
	var previous: String = cell_of(entity_id)
	if previous == cell_id and _entries[entity_id][1] == kind:
		return previous
	if not previous.is_empty():
		_remove_from_cell(entity_id, previous)
	_entries[entity_id] = [cell_id, kind]
	if not _cells.has(cell_id):
		_cells[cell_id] = {}
	_cells[cell_id][entity_id] = kind
	if not _by_kind.has(cell_id):
		_by_kind[cell_id] = {}
	if not _by_kind[cell_id].has(kind):
		_by_kind[cell_id][kind] = {}
	_by_kind[cell_id][kind][entity_id] = true
	cells_changed.emit(previous, cell_id)
	return previous


## Takes an entity out of the index. False when it was not in it.
func remove(entity_id: String) -> bool:
	if not _entries.has(entity_id):
		return false
	var previous: String = str(_entries[entity_id][0])
	_remove_from_cell(entity_id, previous)
	_entries.erase(entity_id)
	cells_changed.emit(previous, "")
	return true


## Takes every entity of one kind out of the index; returns how many.
func remove_kind(kind: String) -> int:
	var removed: PackedStringArray = []
	for entity_id: String in _entries:
		if _entries[entity_id][1] == kind:
			removed.append(entity_id)
	for entity_id: String in removed:
		remove(entity_id)
	return removed.size()


func has(entity_id: String) -> bool:
	return _entries.has(entity_id)


## Cell id of an entity, "" when it is not in the index.
func cell_of(entity_id: String) -> String:
	return str(_entries[entity_id][0]) if _entries.has(entity_id) else ""


## Kind of an entity, "" when it is not in the index.
func kind_of(entity_id: String) -> String:
	return str(_entries[entity_id][1]) if _entries.has(entity_id) else ""


## Ids of the entities in a cell, sorted. `kind` "" = every kind.
func entities_in_cell(cell_id: String, kind: String = "") -> PackedStringArray:
	var members: Dictionary = _cells.get(cell_id, {}) if kind.is_empty() else (_by_kind.get(cell_id, {}) as Dictionary).get(kind, {})
	var ids: PackedStringArray = PackedStringArray(members.keys())
	ids.sort()
	return ids


func count_in_cell(cell_id: String, kind: String = "") -> int:
	var members: Dictionary = _cells.get(cell_id, {})
	if kind.is_empty():
		return members.size()
	return ((_by_kind.get(cell_id, {}) as Dictionary).get(kind, {}) as Dictionary).size()


## Ids of the cells that hold at least one entity, sorted.
func occupied_cell_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_cells.keys())
	ids.sort()
	return ids


## Number of indexed entities.
func size() -> int:
	return _entries.size()


func _remove_from_cell(entity_id: String, cell_id: String) -> void:
	var members: Dictionary = _cells.get(cell_id, {})
	var kind: String = str(members.get(entity_id, ""))
	members.erase(entity_id)
	if members.is_empty():
		_cells.erase(cell_id)
	var kinds: Dictionary = _by_kind.get(cell_id, {})
	var of_kind: Dictionary = kinds.get(kind, {})
	of_kind.erase(entity_id)
	if of_kind.is_empty():
		kinds.erase(kind)
	if kinds.is_empty():
		_by_kind.erase(cell_id)
