class_name ClientStructureState
extends RefCounted
## Client-side mirror of the server's structures (P3-4a, docs/09 §15.4).
## Pure data: never authoritative, never sent back to the server. Owned by
## StructureNetModule (`module.client_state`); a presentation ticket (P3-4b)
## reads it. It has no send / RPC API.
##
## Read surface:
##   structures / structure_ids() / has_structure(id) / get_structure(id) /
##   structure_count()
##     structure_id -> {definition_id: String, tile: Vector2i,
##     rotation: int (quarter turns 0..3, StructureGrid), state: String
##     (StructureInstance.STATE_NAMES), door_open: bool,
##     health_fraction: float 0..1}, in the order they arrived
##   slot_of(id), structure_id_at(slot): the building-grid slot a structure
##     takes and what stands in a slot (StructureGrid.slot_of)
##   signals changed, structure_added(id), structure_changed(id),
##     structure_removed(id)
##
## Sources: the module's join fragment, then rows (a structure was added,
## or changed: one message for both, the mirror tells them apart by the id)
## and removals, all on the reliable ordered channel, so the mirror follows
## the server's order. A row for a known id replaces its entry; a removal of
## an unknown id is ignored (counted, not an error).
##
## Wire format. One structure is a row, an Array of ROW_SIZE values:
##   [structure_id: String, definition_id: String, x: int, z: int,
##    rotation: int, state: String, door_open: bool, health_fraction: float]
## Join fragment: {schema_version: 1, structures: [row, ...]}; {} = the
## server has no building system.
## Every payload is validated before anything changes; malformed input is
## counted, logged and leaves the mirror as it was.

signal changed
signal structure_added(structure_id: String)
signal structure_changed(structure_id: String)
signal structure_removed(structure_id: String)

## Join fragment format.
const SCHEMA_VERSION: int = 1
const KEY_SCHEMA_VERSION: String = "schema_version"
const KEY_STRUCTURES: String = "structures"
## Mirror entry keys.
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_TILE: String = "tile"
const KEY_ROTATION: String = "rotation"
const KEY_STATE: String = "state"
const KEY_DOOR_OPEN: String = "door_open"
const KEY_HEALTH_FRACTION: String = "health_fraction"
## Row layout.
const ROW_SIZE: int = 8
const ROW_ID: int = 0
const ROW_DEFINITION: int = 1
const ROW_X: int = 2
const ROW_Z: int = 3
const ROW_ROTATION: int = 4
const ROW_STATE: int = 5
const ROW_DOOR_OPEN: int = 6
const ROW_HEALTH: int = 7
## Protocol limits: rows / removed ids in one message.
const MAX_ROWS_PER_MESSAGE: int = 256
const MAX_IDS_PER_MESSAGE: int = 256
## Defensive bound for server-generated ids.
const MAX_ID_LENGTH: int = 64

## structure_id -> mirror entry (see the header). Observation, never
## authority.
var structures: Dictionary[String, Dictionary] = {}
## Diagnostics: payloads / rows that failed validation; removals of ids the
## mirror did not have.
var rejected_payload_count: int = 0
var unknown_removal_count: int = 0

var _settings: StructureNetSettings
var _catalog: StructureCatalog
## StructureGrid.slot_key -> structure_id.
var _slots: Dictionary[int, String] = {}


func _init(settings: StructureNetSettings = null, catalog: StructureCatalog = null) -> void:
	_settings = settings if settings != null else StructureNetSettings.new()
	_catalog = catalog if catalog != null else StructureCatalog.new()


# ------------------------------------------------------------ read surface

func has_structure(structure_id: String) -> bool:
	return structures.has(structure_id)


## Mirror entry of one structure ({} if unknown). Do not mutate.
func get_structure(structure_id: String) -> Dictionary:
	return structures.get(structure_id, {})


## Mirrored structure ids in the order they arrived.
func structure_ids() -> PackedStringArray:
	return PackedStringArray(structures.keys())


func structure_count() -> int:
	return structures.size()


## The building-grid slot of a mirrored structure (Vector3i.ZERO if unknown).
func slot_of(structure_id: String) -> Vector3i:
	var entry: Dictionary = structures.get(structure_id, {})
	return _slot_of_entry(entry) if not entry.is_empty() else Vector3i.ZERO


## Id of the mirrored structure in a slot, "" when the mirror has none there.
func structure_id_at(slot: Vector3i) -> String:
	return _slots.get(StructureGrid.slot_key(slot), "")


# ------------------------------------------------------------ apply

## Replaces the mirror with the join fragment. An invalid fragment is
## refused as a whole and leaves the mirror empty. Returns true when the
## fragment was applied.
func apply_join(fragment: Dictionary) -> bool:
	var had_any: bool = not structures.is_empty()
	structures = {}
	_slots = {}
	if fragment.is_empty():
		if had_any:
			changed.emit()
		return true
	if fragment.size() != 2 or not fragment.has(KEY_SCHEMA_VERSION) or not fragment.has(KEY_STRUCTURES):
		return _reject("join_fragment")
	if typeof(fragment[KEY_SCHEMA_VERSION]) != TYPE_INT or int(fragment[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		return _reject("join_schema")
	if typeof(fragment[KEY_STRUCTURES]) != TYPE_ARRAY or (fragment[KEY_STRUCTURES] as Array).size() > _settings.max_mirror_structures:
		return _reject("join_structures")
	var loaded: Dictionary[String, Dictionary] = {}
	for value: Variant in fragment[KEY_STRUCTURES] as Array:
		if not is_valid_row(value) or loaded.has(str((value as Array)[ROW_ID])):
			return _reject("join_row")
		loaded[str((value as Array)[ROW_ID])] = _entry_of(value as Array)
	structures = loaded
	for structure_id: String in structures:
		_slots[StructureGrid.slot_key(_slot_of_entry(structures[structure_id]))] = structure_id
	changed.emit()
	for structure_id: String in structures:
		structure_added.emit(structure_id)
	return true


## Applies one message of rows (structures that were added or changed).
## Each row is validated on its own; returns the number applied.
func apply_rows(rows: Variant) -> int:
	if typeof(rows) != TYPE_ARRAY or (rows as Array).size() > MAX_ROWS_PER_MESSAGE:
		_reject("rows")
		return 0
	var applied: int = 0
	for value: Variant in rows as Array:
		if not is_valid_row(value):
			_reject("row")
			continue
		var row: Array = value
		var structure_id: String = row[ROW_ID]
		var known: bool = structures.has(structure_id)
		if not known and structures.size() >= _settings.max_mirror_structures:
			_reject("mirror_full")
			continue
		if known:
			_slots.erase(StructureGrid.slot_key(_slot_of_entry(structures[structure_id])))
		structures[structure_id] = _entry_of(row)
		_slots[StructureGrid.slot_key(_slot_of_entry(structures[structure_id]))] = structure_id
		applied += 1
		if known:
			structure_changed.emit(structure_id)
		else:
			structure_added.emit(structure_id)
	if applied > 0:
		changed.emit()
	return applied


## Applies one message of removed structure ids; returns the number removed.
func apply_removed(ids: Variant) -> int:
	if typeof(ids) != TYPE_ARRAY or (ids as Array).size() > MAX_IDS_PER_MESSAGE:
		_reject("removed")
		return 0
	var removed: int = 0
	for value: Variant in ids as Array:
		if typeof(value) != TYPE_STRING or not _is_valid_id(str(value)):
			_reject("removed_id")
			continue
		var structure_id: String = value
		if not structures.has(structure_id):
			unknown_removal_count += 1
			continue
		var key: int = StructureGrid.slot_key(_slot_of_entry(structures[structure_id]))
		if _slots.get(key, "") == structure_id:
			_slots.erase(key)
		structures.erase(structure_id)
		removed += 1
		structure_removed.emit(structure_id)
	if removed > 0:
		changed.emit()
	return removed


# ------------------------------------------------------------ wire format

## The wire row for a public structure row of BuildingService
## (BuildingService.public_row; events carry the same keys). [] when the
## row has no such keys.
static func encode_row(row: Dictionary) -> Array:
	for key: String in [BuildingService.KEY_STRUCTURE_ID, BuildingService.KEY_DEFINITION_ID, BuildingService.KEY_X, BuildingService.KEY_Z, BuildingService.KEY_ROTATION, BuildingService.KEY_STATE, BuildingService.KEY_DOOR_OPEN, BuildingService.KEY_HEALTH_FRACTION]:
		if not row.has(key):
			return []
	return [
		str(row[BuildingService.KEY_STRUCTURE_ID]),
		str(row[BuildingService.KEY_DEFINITION_ID]),
		int(row[BuildingService.KEY_X]),
		int(row[BuildingService.KEY_Z]),
		int(row[BuildingService.KEY_ROTATION]),
		str(row[BuildingService.KEY_STATE]),
		bool(row[BuildingService.KEY_DOOR_OPEN]),
		float(row[BuildingService.KEY_HEALTH_FRACTION]),
	]


## True when `value` is a structure row as the server sends it (see the
## header) for a definition this client has.
func is_valid_row(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != ROW_SIZE:
		return false
	var row: Array = value
	if typeof(row[ROW_ID]) != TYPE_STRING or typeof(row[ROW_DEFINITION]) != TYPE_STRING or typeof(row[ROW_STATE]) != TYPE_STRING:
		return false
	if typeof(row[ROW_X]) != TYPE_INT or typeof(row[ROW_Z]) != TYPE_INT or typeof(row[ROW_ROTATION]) != TYPE_INT:
		return false
	if typeof(row[ROW_DOOR_OPEN]) != TYPE_BOOL or typeof(row[ROW_HEALTH]) != TYPE_FLOAT:
		return false
	if not _is_valid_id(str(row[ROW_ID])):
		return false
	var definition: StructureDefinition = _catalog.get_definition(str(row[ROW_DEFINITION]))
	if definition == null:
		return false
	if not StructureGrid.is_valid_tile(Vector2i(int(row[ROW_X]), int(row[ROW_Z]))) or not StructureGrid.is_valid_rotation(int(row[ROW_ROTATION])):
		return false
	if StructureInstance.state_from_name(str(row[ROW_STATE])) < 0:
		return false
	if bool(row[ROW_DOOR_OPEN]) and not definition.is_door:
		return false
	var health: float = row[ROW_HEALTH]
	return is_finite(health) and health >= 0.0 and health <= 1.0


func _is_valid_id(structure_id: String) -> bool:
	return structure_id.length() <= MAX_ID_LENGTH and StructureInstance.is_valid_structure_id(structure_id)


func _entry_of(row: Array) -> Dictionary:
	return {
		KEY_DEFINITION_ID: str(row[ROW_DEFINITION]),
		KEY_TILE: Vector2i(int(row[ROW_X]), int(row[ROW_Z])),
		KEY_ROTATION: int(row[ROW_ROTATION]),
		KEY_STATE: str(row[ROW_STATE]),
		KEY_DOOR_OPEN: bool(row[ROW_DOOR_OPEN]),
		KEY_HEALTH_FRACTION: float(row[ROW_HEALTH]),
	}


func _slot_of_entry(entry: Dictionary) -> Vector3i:
	var definition: StructureDefinition = _catalog.get_definition(str(entry[KEY_DEFINITION_ID]))
	var placement: int = definition.placement if definition != null else StructureDefinition.Placement.TILE
	return StructureGrid.slot_of(placement, entry[KEY_TILE] as Vector2i, int(entry[KEY_ROTATION]))


func _reject(kind: String) -> bool:
	rejected_payload_count += 1
	GameLogger.warning("structure_net", "invalid client structure payload ignored", {"kind": kind, "operation": "apply_payload"})
	return false
