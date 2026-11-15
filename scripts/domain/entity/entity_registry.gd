class_name EntityRegistry
extends RefCounted
## Server-side index of persistent entities by stable id (docs/09 §4).
##
## Stores only ids, kinds and plain data records (never Node references, so
## the registry is safe to snapshot). Removed ids are tombstoned and can
## never be registered again (docs/14 §1 "삭제된 ID를 재사용하지 않는다").

signal entity_registered(entity_id: String, kind: String)
signal entity_removed(entity_id: String, kind: String)

var _kinds: Dictionary[String, String] = {}
var _tombstones: Dictionary[String, bool] = {}


## Registers an id. Fails on empty, duplicate or previously removed ids.
func register(entity_id: String, kind: String) -> Error:
	if entity_id.is_empty() or kind.is_empty():
		GameLogger.error("entity", "register with empty id or kind", {"entity_id": entity_id, "kind": kind, "operation": "register"})
		return ERR_INVALID_PARAMETER
	if _kinds.has(entity_id):
		GameLogger.error("entity", "duplicate entity id", {"entity_id": entity_id, "operation": "register"})
		return ERR_ALREADY_EXISTS
	if _tombstones.has(entity_id):
		GameLogger.error("entity", "attempt to reuse removed entity id", {"entity_id": entity_id, "operation": "register"})
		return ERR_ALREADY_IN_USE
	_kinds[entity_id] = kind
	entity_registered.emit(entity_id, kind)
	return OK


## Removes an id and tombstones it.
func remove(entity_id: String) -> Error:
	if not _kinds.has(entity_id):
		return ERR_DOES_NOT_EXIST
	var kind: String = _kinds[entity_id]
	_kinds.erase(entity_id)
	_tombstones[entity_id] = true
	entity_removed.emit(entity_id, kind)
	return OK


## Takes an id out of the registry WITHOUT tombstoning it (P3-1): the entity
## still exists, but it left memory with its cell (docs/03 §3.2) and is
## registered again when that cell is loaded. `entity_removed` is not
## emitted: nothing was removed from the world.
func release(entity_id: String) -> Error:
	if not _kinds.has(entity_id):
		return ERR_DOES_NOT_EXIST
	_kinds.erase(entity_id)
	return OK


func has(entity_id: String) -> bool:
	return _kinds.has(entity_id)


## Kind of a registered id, or "" when unknown.
func kind_of(entity_id: String) -> String:
	return _kinds.get(entity_id, "")


## Sorted ids of one kind (deterministic order).
func ids_of_kind(kind: String) -> PackedStringArray:
	var ids: PackedStringArray = []
	for entity_id: String in _kinds:
		if _kinds[entity_id] == kind:
			ids.append(entity_id)
	ids.sort()
	return ids


func count() -> int:
	return _kinds.size()


func is_tombstoned(entity_id: String) -> bool:
	return _tombstones.has(entity_id)


## Tombstoned ids (persisted so removal survives restarts).
func tombstones() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_tombstones.keys())
	ids.sort()
	return ids


func restore_tombstones(ids: PackedStringArray) -> void:
	for entity_id: String in ids:
		_tombstones[entity_id] = true
