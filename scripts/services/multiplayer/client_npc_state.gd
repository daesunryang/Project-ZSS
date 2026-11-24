class_name ClientNpcState
extends RefCounted
## Non-authoritative client mirror of the public NPC rows (P4-7). Reliable
## join/scope events own membership; unreliable position snapshots can only
## update NPCs that are already known.

signal changed
signal npc_added(npc_id: String)
signal npc_removed(npc_id: String)
signal event_received(event: Dictionary)

const KEY_SEQUENCE: String = "sequence"
const NO_TICK: int = -1
const REASON_BAD_TYPE: String = "bad_type"
const REASON_BAD_TICK: String = "bad_tick"
const REASON_BAD_SEQUENCE: String = "bad_sequence"
const REASON_BAD_FRAGMENT: String = "bad_fragment"
const REASON_TOO_MANY_ROWS: String = "too_many_rows"
const REASON_BAD_EVENT_COUNT: String = "bad_event_count"
const REASON_DUPLICATE_ID: String = "duplicate_npc_id"
const REASON_MIRROR_FULL: String = "mirror_full"
const REASON_STALE: String = "stale"
const REASON_NOT_JOINED: String = "not_joined"

## npc_id -> decoded full public row.
var npcs: Dictionary[String, Dictionary] = {}
var last_snapshot_tick: int = NO_TICK
var last_event_sequence: int = 0
var rejected_payload_count: int = 0
var stale_snapshot_count: int = 0
var event_gap_count: int = 0

var _settings: NpcNetSettings
var _joined: bool = false
var _recent_events: Array[Dictionary] = []


func _init(settings: NpcNetSettings = null) -> void:
	_settings = settings if settings != null else NpcNetSettings.new()


func has_npc(npc_id: String) -> bool:
	return npcs.has(npc_id)


## Copy of one public row, or {}. Presentation cannot mutate the mirror.
func get_npc(npc_id: String) -> Dictionary:
	return (npcs.get(npc_id, {}) as Dictionary).duplicate(true)


func npc_ids() -> PackedStringArray:
	return PackedStringArray(npcs.keys())


func npc_count() -> int:
	return npcs.size()


## The public condition of a mirrored NPC (F-25), "" for an unknown one.
func condition_of(npc_id: String) -> String:
	return str((npcs.get(npc_id, {}) as Dictionary).get(NpcNetProtocol.KEY_CONDITION, ""))


func is_dead(npc_id: String) -> bool:
	return condition_of(npc_id) == NpcNetProtocol.CONDITION_DEAD


func recent_events() -> Array[Dictionary]:
	return _recent_events.duplicate(true)


func apply_join(fragment: Dictionary) -> String:
	npcs.clear()
	_recent_events.clear()
	last_snapshot_tick = NO_TICK
	last_event_sequence = 0
	_joined = true
	var reason: String = "" if fragment.is_empty() else _load_join(fragment)
	if not reason.is_empty():
		npcs.clear()
		last_snapshot_tick = NO_TICK
		last_event_sequence = 0
		_reject("npc join snapshot ignored", reason, "apply_join")
	changed.emit()
	return reason


func apply_snapshot(tick: Variant, rows: Variant) -> String:
	if typeof(tick) != TYPE_INT or typeof(rows) != TYPE_ARRAY:
		return _reject("npc snapshot ignored", REASON_BAD_TYPE, "apply_snapshot")
	if int(tick) < 0:
		return _reject("npc snapshot ignored", REASON_BAD_TICK, "apply_snapshot")
	var entries: Array = rows
	if entries.size() > NpcNetProtocol.MAX_ROWS_PER_MESSAGE:
		return _reject("npc snapshot ignored", REASON_TOO_MANY_ROWS, "apply_snapshot")
	for entry: Variant in entries:
		var reason: String = NpcNetProtocol.snapshot_row_error(entry)
		if not reason.is_empty():
			return _reject("npc snapshot ignored", reason, "apply_snapshot")
	if not _joined:
		return REASON_NOT_JOINED
	if int(tick) < last_snapshot_tick:
		stale_snapshot_count += 1
		return REASON_STALE
	last_snapshot_tick = int(tick)
	var dirty: bool = false
	for entry: Variant in entries:
		var decoded: Dictionary = NpcNetProtocol.decode_snapshot_row(entry as Array)
		var npc_id: String = str(decoded[NpcNetProtocol.KEY_NPC_ID])
		if not npcs.has(npc_id):
			continue
		var current: Dictionary = npcs[npc_id]
		for key: String in [NpcNetProtocol.KEY_POSITION, NpcNetProtocol.KEY_YAW]:
			if current[key] != decoded[key]:
				current[key] = decoded[key]
				dirty = true
	if dirty:
		changed.emit()
	return ""


func apply_events(tick: Variant, first_sequence: Variant, events: Variant) -> String:
	if typeof(tick) != TYPE_INT or typeof(first_sequence) != TYPE_INT or typeof(events) != TYPE_ARRAY:
		return _reject("npc events ignored", REASON_BAD_TYPE, "apply_events")
	if int(tick) < 0:
		return _reject("npc events ignored", REASON_BAD_TICK, "apply_events")
	if int(first_sequence) < 1:
		return _reject("npc events ignored", REASON_BAD_SEQUENCE, "apply_events")
	var entries: Array = events
	if entries.is_empty() or entries.size() > NpcNetProtocol.MAX_EVENTS_PER_MESSAGE:
		return _reject("npc events ignored", REASON_BAD_EVENT_COUNT, "apply_events")
	if not _joined:
		return _reject("npc events ignored", REASON_NOT_JOINED, "apply_events")
	var dirty: bool = false
	for index: int in range(entries.size()):
		var sequence: int = int(first_sequence) + index
		if sequence <= last_event_sequence:
			continue
		if sequence > last_event_sequence + 1:
			event_gap_count += 1
			GameLogger.warning("net", "npc event sequence gap", {"expected": last_event_sequence + 1, "received": sequence, "operation": "apply_events"})
		last_event_sequence = sequence
		var reason: String = NpcNetProtocol.event_error(entries[index])
		if not reason.is_empty():
			_reject("npc event ignored", reason, "apply_events", {"sequence": sequence})
			continue
		var event: Dictionary = (entries[index] as Dictionary).duplicate(true)
		event[KEY_SEQUENCE] = sequence
		if _apply_event(event):
			dirty = true
		_recent_events.append(event)
		while _recent_events.size() > _settings.recent_event_capacity:
			_recent_events.pop_front()
		event_received.emit(event)
	if dirty:
		changed.emit()
	return ""


func _load_join(fragment: Dictionary) -> String:
	if fragment.size() != 3:
		return REASON_BAD_FRAGMENT
	var tick: Variant = fragment.get(NpcNetProtocol.KEY_TICK, null)
	var sequence: Variant = fragment.get(NpcNetProtocol.KEY_EVENT_SEQUENCE, null)
	var rows: Variant = fragment.get(NpcNetProtocol.KEY_ROWS, null)
	if typeof(tick) != TYPE_INT or typeof(sequence) != TYPE_INT or typeof(rows) != TYPE_ARRAY:
		return REASON_BAD_FRAGMENT
	if int(tick) < 0 or int(sequence) < 0 or (rows as Array).size() > _settings.max_mirrored_npcs:
		return REASON_BAD_FRAGMENT
	for entry: Variant in (rows as Array):
		var reason: String = NpcNetProtocol.public_row_error(entry)
		if not reason.is_empty():
			return reason
		var decoded: Dictionary = NpcNetProtocol.decode_public_row(entry as Array)
		var npc_id: String = str(decoded[NpcNetProtocol.KEY_NPC_ID])
		if npcs.has(npc_id):
			return REASON_DUPLICATE_ID
		npcs[npc_id] = decoded
	last_snapshot_tick = int(tick)
	last_event_sequence = int(sequence)
	return ""


func _apply_event(event: Dictionary) -> bool:
	var npc_id: String = str(event[NpcNetProtocol.KEY_NPC_ID])
	match str(event[NpcNetProtocol.KEY_EVENT_TYPE]):
		NpcNetProtocol.EVENT_ENTERED:
			var is_new: bool = not npcs.has(npc_id)
			if is_new and npcs.size() >= _settings.max_mirrored_npcs:
				_reject("npc not mirrored", REASON_MIRROR_FULL, "apply_events", {"entity_id": npc_id})
				return false
			npcs[npc_id] = NpcNetProtocol.decode_public_row(event[NpcNetProtocol.KEY_ROW] as Array)
			if is_new:
				npc_added.emit(npc_id)
			return true
		NpcNetProtocol.EVENT_LEFT:
			if not npcs.erase(npc_id):
				return false
			npc_removed.emit(npc_id)
			return true
		NpcNetProtocol.EVENT_ACTION_CHANGED:
			if not npcs.has(npc_id):
				return false
			var entry: Dictionary = npcs[npc_id]
			var label: String = str(event[NpcNetProtocol.KEY_ACTION_LABEL])
			if str(entry[NpcNetProtocol.KEY_ACTION_LABEL]) == label:
				return false
			entry[NpcNetProtocol.KEY_ACTION_LABEL] = label
			return true
		NpcNetProtocol.EVENT_CONDITION_CHANGED:
			if not npcs.has(npc_id):
				return false
			var row: Dictionary = npcs[npc_id]
			var condition: String = str(event[NpcNetProtocol.KEY_CONDITION])
			if str(row[NpcNetProtocol.KEY_CONDITION]) == condition:
				return false
			row[NpcNetProtocol.KEY_CONDITION] = condition
			return true
	return false


func _reject(message: String, reason: String, operation: String, context: Dictionary = {}) -> String:
	rejected_payload_count += 1
	var details: Dictionary = {"reason": reason, "operation": operation}
	details.merge(context)
	GameLogger.warning("net", message, details)
	return reason
