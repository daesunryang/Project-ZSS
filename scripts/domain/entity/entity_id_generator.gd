class_name EntityIdGenerator
extends RefCounted
## Generates stable, never-reused entity ids of the form `<kind>_<sequence>`
## (docs/14 §1). The next sequence number is part of the world save, so ids
## stay unique across server restarts.
##
## PROVISIONAL (docs/15 P1-2): counter-based ids instead of UUIDs. They are
## deterministic (testable, reproducible) and unique within one world.

const KIND_PATTERN: String = "^[a-z][a-z0-9]*$"
const SEQUENCE_DIGITS: int = 6
const FIRST_SEQUENCE: int = 1

var _next_sequence: int = FIRST_SEQUENCE
var _kind_regex: RegEx = RegEx.create_from_string(KIND_PATTERN)


## Returns a new id such as `item_000042`. Returns "" for an invalid kind.
func next_id(kind: String) -> String:
	if not is_valid_kind(kind):
		GameLogger.error("entity", "invalid entity kind", {"kind": kind, "operation": "next_id"})
		return ""
	var id: String = "%s_%0*d" % [kind, SEQUENCE_DIGITS, _next_sequence]
	_next_sequence += 1
	return id


func is_valid_kind(kind: String) -> bool:
	return _kind_regex.search(kind) != null


func get_next_sequence() -> int:
	return _next_sequence


## Restores the counter from a save. Refuses to move backwards (id reuse).
func restore_next_sequence(value: int) -> Error:
	if value < FIRST_SEQUENCE:
		return ERR_INVALID_PARAMETER
	if value < _next_sequence:
		GameLogger.error("entity", "refusing to rewind id sequence", {"current": _next_sequence, "requested": value, "operation": "restore_sequence"})
		return ERR_INVALID_PARAMETER
	_next_sequence = value
	return OK


## Makes sure a loaded id can never be generated again.
func reserve_existing_id(id: String) -> void:
	var sequence: int = sequence_of(id)
	if sequence >= _next_sequence:
		_next_sequence = sequence + 1


## Sequence number embedded in an id, or -1 if the id has another format.
static func sequence_of(id: String) -> int:
	var separator: int = id.rfind("_")
	if separator <= 0:
		return -1
	var digits: String = id.substr(separator + 1)
	if digits.is_empty() or not digits.is_valid_int():
		return -1
	return int(digits)
