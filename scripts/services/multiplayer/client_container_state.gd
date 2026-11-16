class_name ClientContainerState
extends RefCounted
## Client-side mirror of the containers the server told this client about,
## and of the one container the local player has open (P3-3, docs/09 §15.3).
## No authority: everything here is observation. Every payload is validated;
## what does not fit is counted (rejected_payload_count) and left out.
##
## The containers: `containers` = container_id -> {definition_id, position:
## Vector3, searched: bool}. Only the containers of the cells around the
## local player are in it (the server takes the others away again).
##
## The session of the local player: which container is being searched or is
## open (open_container_id, phase, search_sec) and, while it is open, what is
## inside (contents). Nobody else's session ever reaches this client, and no
## content of a container that this client has not open.
##
## Wire formats:
##   container row   [container_id, definition_id, x, y, z, searched]
##   item row        [item_instance_id, definition_id, quantity, slot]
##   join fragment   {schema_version: 1, containers: [container row, ...]}

## A container appeared in / changed in / left the mirror.
signal container_added(container_id: String)
signal container_changed(container_id: String)
signal container_removed(container_id: String)
## The set of containers or one of them changed (one emit per message).
signal changed
## The local player's session changed: another container, another phase.
signal session_changed
## What is inside the open container changed.
signal contents_changed
## The local player's session ended: by request, or for the `reason` the
## server gives (ContainerService.REASON_*).
signal session_closed(container_id: String, reason: String)

const SCHEMA_VERSION: int = 1
const KEY_SCHEMA_VERSION: String = "schema_version"
const KEY_CONTAINERS: String = "containers"
## Mirror entry keys.
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_POSITION: String = "position"
const KEY_SEARCHED: String = "searched"
## Keys of one entry of contents().
const KEY_ITEM_ID: String = "item_instance_id"
const KEY_QUANTITY: String = "quantity"
const KEY_SLOT: String = "slot"
## Container row layout.
const ROW_SIZE: int = 6
const ROW_ID: int = 0
const ROW_DEFINITION: int = 1
const ROW_X: int = 2
const ROW_Y: int = 3
const ROW_Z: int = 4
const ROW_SEARCHED: int = 5
## Item row layout.
const ITEM_ROW_SIZE: int = 4
const ITEM_ID: int = 0
const ITEM_DEFINITION: int = 1
const ITEM_QUANTITY: int = 2
const ITEM_SLOT: int = 3
## Protocol limits: rows / removed ids in one message, stacks in one
## container, the longest search a client believes.
const MAX_ROWS_PER_MESSAGE: int = 256
const MAX_IDS_PER_MESSAGE: int = 256
const MAX_CONTENT_ENTRIES: int = 64
const MAX_SEARCH_SEC: float = 3600.0
## Defensive bounds for server-generated strings.
const MAX_ID_LENGTH: int = 64
const MAX_REASON_LENGTH: int = 64
## Phases of the local session (the server's names).
const PHASE_NONE: String = ContainerService.PHASE_NONE
const PHASE_SEARCHING: String = ContainerService.PHASE_SEARCHING
const PHASE_OPEN: String = ContainerService.PHASE_OPEN
const PHASE_CLOSED: String = ContainerService.PHASE_CLOSED

## container_id -> mirror entry (see the header).
var containers: Dictionary[String, Dictionary] = {}
## Diagnostics: payloads / rows that failed validation; removals of ids the
## mirror did not have; content changes for a container that is not open.
var rejected_payload_count: int = 0
var unknown_removal_count: int = 0
var stale_contents_count: int = 0

var _settings: ContainerNetSettings
var _catalog: ContainerCatalog
var _open_id: String = ""
var _phase: String = PHASE_NONE
var _search_sec: float = 0.0
## item_instance_id -> {definition_id, quantity, slot} of the open container.
var _items: Dictionary[String, Dictionary] = {}


func _init(settings: ContainerNetSettings = null, catalog: ContainerCatalog = null) -> void:
	_settings = settings if settings != null else ContainerNetSettings.new()
	_catalog = catalog if catalog != null else ContainerCatalog.new()


# ------------------------------------------------------------ read surface

func has_container(container_id: String) -> bool:
	return containers.has(container_id)


## Copy of one mirror entry ({} when it is not in the mirror).
func get_container(container_id: String) -> Dictionary:
	return (containers.get(container_id, {}) as Dictionary).duplicate()


func container_ids() -> PackedStringArray:
	return PackedStringArray(containers.keys())


func container_count() -> int:
	return containers.size()


## The container the local player searches or has open ("" = none).
func open_container_id() -> String:
	return _open_id


## PHASE_SEARCHING, PHASE_OPEN, or PHASE_NONE.
func phase() -> String:
	return _phase


## How long the search that is running takes in all (0 when none runs).
func search_sec() -> float:
	return _search_sec


## What is inside the open container, in slot order:
## [{item_instance_id, definition_id, quantity, slot}]. Empty while nothing
## is open.
func contents() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for item_id: String in _items:
		var entry: Dictionary = _items[item_id].duplicate()
		entry[KEY_ITEM_ID] = item_id
		entries.append(entry)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a[KEY_SLOT]) < int(b[KEY_SLOT]))
	return entries


# ------------------------------------------------------------ apply

## Replaces the mirror with the join fragment and forgets any session. An
## invalid fragment is refused as a whole and leaves the mirror empty.
## Returns true when the fragment was applied.
func apply_join(fragment: Dictionary) -> bool:
	var had_any: bool = not containers.is_empty() or not _open_id.is_empty()
	containers = {}
	_clear_session()
	if fragment.is_empty():
		if had_any:
			changed.emit()
		return true
	if fragment.size() != 2 or not fragment.has(KEY_SCHEMA_VERSION) or not fragment.has(KEY_CONTAINERS):
		return _reject("join_fragment")
	if typeof(fragment[KEY_SCHEMA_VERSION]) != TYPE_INT or int(fragment[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		return _reject("join_schema")
	if typeof(fragment[KEY_CONTAINERS]) != TYPE_ARRAY or (fragment[KEY_CONTAINERS] as Array).size() > _settings.max_mirror_containers:
		return _reject("join_containers")
	var loaded: Dictionary[String, Dictionary] = {}
	for value: Variant in fragment[KEY_CONTAINERS] as Array:
		if not is_valid_row(value) or loaded.has(str((value as Array)[ROW_ID])):
			return _reject("join_row")
		loaded[str((value as Array)[ROW_ID])] = _entry_of(value as Array)
	containers = loaded
	changed.emit()
	for container_id: String in containers:
		container_added.emit(container_id)
	return true


## Applies one message of rows (containers that appeared or changed). Each
## row is validated on its own; returns the number applied.
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
		var container_id: String = row[ROW_ID]
		var known: bool = containers.has(container_id)
		if not known and containers.size() >= _settings.max_mirror_containers:
			_reject("mirror_full")
			continue
		containers[container_id] = _entry_of(row)
		applied += 1
		if known:
			container_changed.emit(container_id)
		else:
			container_added.emit(container_id)
	if applied > 0:
		changed.emit()
	return applied


## Applies one message of removed container ids (they left the cells this
## client is told about); returns the number removed. A container that was
## open is closed with it.
func apply_removed(ids: Variant) -> int:
	if typeof(ids) != TYPE_ARRAY or (ids as Array).size() > MAX_IDS_PER_MESSAGE:
		_reject("removed")
		return 0
	var removed: int = 0
	for value: Variant in ids as Array:
		if typeof(value) != TYPE_STRING or not _is_valid_id(str(value)):
			_reject("removed_id")
			continue
		var container_id: String = value
		if not containers.has(container_id):
			unknown_removal_count += 1
			continue
		containers.erase(container_id)
		removed += 1
		container_removed.emit(container_id)
		if container_id == _open_id:
			_clear_session()
			session_changed.emit()
			session_closed.emit(container_id, ContainerService.REASON_CONTAINER_GONE)
	if removed > 0:
		changed.emit()
	return removed


## Applies the state of the local player's session on one container:
##   "searching"  the search of `search_sec` seconds started (no items);
##   "open"       the container is open and holds `items` (item rows);
##   "closed"     the session ended for `reason`.
## False (counted) when the payload does not fit; nothing changes then.
func apply_session(container_id: Variant, phase_name: Variant, reason: Variant, search_seconds: Variant, items: Variant) -> bool:
	if typeof(container_id) != TYPE_STRING or typeof(phase_name) != TYPE_STRING or typeof(reason) != TYPE_STRING or typeof(items) != TYPE_ARRAY:
		return _reject("session_type")
	if typeof(search_seconds) != TYPE_FLOAT and typeof(search_seconds) != TYPE_INT:
		return _reject("session_type")
	var id: String = container_id
	var seconds: float = float(search_seconds)
	if not _is_valid_id(id) or str(reason).length() > MAX_REASON_LENGTH or not is_finite(seconds) or seconds < 0.0 or seconds > MAX_SEARCH_SEC:
		return _reject("session_value")
	if phase_name == PHASE_CLOSED:
		if not (items as Array).is_empty():
			return _reject("session_closed_items")
		if id != _open_id:
			# The session it ends is gone already (its container left the mirror).
			return true
		_clear_session()
		session_changed.emit()
		session_closed.emit(id, str(reason))
		changed.emit()
		return true
	if phase_name != PHASE_SEARCHING and phase_name != PHASE_OPEN:
		return _reject("session_phase")
	if not containers.has(id):
		return _reject("session_unknown_container")
	var loaded: Dictionary[String, Dictionary] = {}
	if phase_name == PHASE_SEARCHING:
		if not (items as Array).is_empty():
			return _reject("session_search_items")
	else:
		if not _read_item_rows(items as Array, loaded):
			return _reject("session_items")
	_open_id = id
	_phase = phase_name
	_search_sec = seconds if phase_name == PHASE_SEARCHING else 0.0
	_items = loaded
	session_changed.emit()
	contents_changed.emit()
	changed.emit()
	return true


## Applies a change of what is inside the open container: `changed_rows`
## (item rows: stacks that arrived or hold another quantity now) and
## `removed_ids` (stacks that are not inside any more). A change for a
## container that is not open here is ignored (counted): it was closed
## meanwhile. False (counted) when the payload does not fit.
func apply_items(container_id: Variant, changed_rows: Variant, removed_ids: Variant) -> bool:
	if typeof(container_id) != TYPE_STRING or typeof(changed_rows) != TYPE_ARRAY or typeof(removed_ids) != TYPE_ARRAY:
		return _reject("items_type")
	if not _is_valid_id(str(container_id)) or (removed_ids as Array).size() > MAX_CONTENT_ENTRIES:
		return _reject("items_value")
	var incoming: Dictionary[String, Dictionary] = {}
	if not _read_item_rows(changed_rows as Array, incoming):
		return _reject("items_rows")
	for value: Variant in removed_ids as Array:
		if typeof(value) != TYPE_STRING or not _is_valid_id(str(value)):
			return _reject("items_removed_id")
	if str(container_id) != _open_id or _phase != PHASE_OPEN:
		stale_contents_count += 1
		return true
	for value: Variant in removed_ids as Array:
		_items.erase(str(value))
	for item_id: String in incoming:
		_items[item_id] = incoming[item_id]
	if _items.size() > MAX_CONTENT_ENTRIES:
		return _reject("items_overflow")
	contents_changed.emit()
	changed.emit()
	return true


# ------------------------------------------------------------ validation

## True when `value` is a container row this mirror accepts.
func is_valid_row(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != ROW_SIZE:
		return false
	var row: Array = value
	if typeof(row[ROW_ID]) != TYPE_STRING or typeof(row[ROW_DEFINITION]) != TYPE_STRING or typeof(row[ROW_SEARCHED]) != TYPE_BOOL:
		return false
	if not _is_valid_id(str(row[ROW_ID])) or not _catalog.has(str(row[ROW_DEFINITION])):
		return false
	for index: int in [ROW_X, ROW_Y, ROW_Z]:
		if typeof(row[index]) != TYPE_FLOAT and typeof(row[index]) != TYPE_INT:
			return false
		if not is_finite(float(row[index])):
			return false
	return true


## True when `value` is an item row: ids of sane length, a quantity of at
## least 1 and a slot a container can have.
static func is_valid_item_row(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != ITEM_ROW_SIZE:
		return false
	var row: Array = value
	if typeof(row[ITEM_ID]) != TYPE_STRING or typeof(row[ITEM_DEFINITION]) != TYPE_STRING or typeof(row[ITEM_QUANTITY]) != TYPE_INT or typeof(row[ITEM_SLOT]) != TYPE_INT:
		return false
	if not _is_valid_id(str(row[ITEM_ID])) or str(row[ITEM_DEFINITION]).length() > MAX_ID_LENGTH or not ItemInstance.is_valid_definition_id(str(row[ITEM_DEFINITION])):
		return false
	return int(row[ITEM_QUANTITY]) >= 1 and int(row[ITEM_SLOT]) >= 0 and int(row[ITEM_SLOT]) < MAX_CONTENT_ENTRIES


## Reads item rows into `out` (item id -> entry). False when there are too
## many, one does not fit, or an id comes twice.
func _read_item_rows(rows: Array, out: Dictionary[String, Dictionary]) -> bool:
	if rows.size() > MAX_CONTENT_ENTRIES:
		return false
	for value: Variant in rows:
		if not is_valid_item_row(value) or out.has(str((value as Array)[ITEM_ID])):
			return false
		var row: Array = value
		out[str(row[ITEM_ID])] = {KEY_DEFINITION_ID: str(row[ITEM_DEFINITION]), KEY_QUANTITY: int(row[ITEM_QUANTITY]), KEY_SLOT: int(row[ITEM_SLOT])}
	return true


static func _is_valid_id(id: String) -> bool:
	return not id.is_empty() and id.length() <= MAX_ID_LENGTH


func _entry_of(row: Array) -> Dictionary:
	return {
		KEY_DEFINITION_ID: str(row[ROW_DEFINITION]),
		KEY_POSITION: Vector3(float(row[ROW_X]), float(row[ROW_Y]), float(row[ROW_Z])),
		KEY_SEARCHED: bool(row[ROW_SEARCHED]),
	}


func _clear_session() -> void:
	_open_id = ""
	_phase = PHASE_NONE
	_search_sec = 0.0
	_items = {}


func _reject(kind: String) -> bool:
	rejected_payload_count += 1
	GameLogger.warning("container_net", "container payload dropped", {"kind": kind, "operation": "apply_payload"})
	return false
