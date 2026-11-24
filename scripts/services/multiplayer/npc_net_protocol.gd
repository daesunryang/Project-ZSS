class_name NpcNetProtocol
extends RefCounted
## Exact public wire format for NPC replication (P4-7). This is the privacy
## boundary: encoders copy only the listed observable fields. Adding a field
## to NpcState, NpcDefinition or an NpcComponent cannot make it leave the
## server unless this file is deliberately changed.
##
## Full public row (join fragment and npc_entered):
##   [npc_id, Korean/display name, appearance selection, position, yaw,
##    action-label index, posture index, condition index]
## Position snapshot row (5 Hz, channel 2): [npc_id, position, yaw]. Static
## identity is not repeated. Observable action-label changes use channel 0.
##
## Condition (F-25, docs/09 §17.12): all that anybody is told of an NPC's
## body is one of CONDITIONS - "ok", "hurt" (it bleeds or is badly hurt) or
## "dead" (the entity is the body). Health numbers, wounds and infection
## never leave the server. A change is the npc_condition_changed event.

const MAX_ROWS_PER_MESSAGE: int = 64
const MAX_EVENTS_PER_MESSAGE: int = 64
const MAX_ID_LENGTH: int = 64
const MAX_APPEARANCE_SLOTS: int = 16
const MAX_APPEARANCE_ID_LENGTH: int = 16
const MAX_ABS_YAW: float = TAU

## P4-4/P4-5 fill the injected server source later; names are protocol data.
const ACTION_LABELS: PackedStringArray = ["idle", "walk", "eat", "sleep", "work", "flee"]
const ACTION_IDLE: String = "idle"
const POSTURES: PackedStringArray = PlayerPosture.NAMES
const POSTURE_STANDING: String = "standing"
const CONDITIONS: PackedStringArray = [NpcVitals.CONDITION_OK, NpcVitals.CONDITION_HURT, NpcVitals.CONDITION_DEAD]
const CONDITION_OK: String = NpcVitals.CONDITION_OK
const CONDITION_DEAD: String = NpcVitals.CONDITION_DEAD

const KEY_TICK: String = "tick"
const KEY_EVENT_SEQUENCE: String = "event_sequence"
const KEY_ROWS: String = "rows"
const KEY_EVENT_TYPE: String = "event_type"
const KEY_NPC_ID: String = "npc_id"
const KEY_WORLD_TIME: String = "world_time"
const KEY_ROW: String = "row"
const KEY_NAME: String = "name"
const KEY_APPEARANCE: String = "appearance"
const KEY_POSITION: String = "position"
const KEY_YAW: String = "yaw"
const KEY_ACTION_LABEL: String = "action_label"
const KEY_POSTURE: String = "posture"
const KEY_CONDITION: String = "condition"

const EVENT_ENTERED: String = "npc_entered"
const EVENT_LEFT: String = "npc_left"
const EVENT_ACTION_CHANGED: String = "npc_action_changed"
const EVENT_CONDITION_CHANGED: String = "npc_condition_changed"

const REASON_BAD_ROW: String = "bad_row"
const REASON_BAD_EVENT: String = "bad_event"
const REASON_BAD_EVENT_TYPE: String = "bad_event_type"
const REASON_BAD_EVENT_FIELD: String = "bad_event_field"
const REASON_UNKNOWN_EVENT_FIELD: String = "unknown_event_field"

const PUBLIC_ID: int = 0
const PUBLIC_NAME: int = 1
const PUBLIC_APPEARANCE: int = 2
const PUBLIC_POSITION: int = 3
const PUBLIC_YAW: int = 4
const PUBLIC_ACTION: int = 5
const PUBLIC_POSTURE: int = 6
const PUBLIC_CONDITION: int = 7
const PUBLIC_ROW_SIZE: int = 8

const SNAPSHOT_ID: int = 0
const SNAPSHOT_POSITION: int = 1
const SNAPSHOT_YAW: int = 2
const SNAPSHOT_ROW_SIZE: int = 3


## Server: copies exactly the public fields from `source`, or [] when they
## cannot form a client-displayable row. Extra keys are deliberately ignored.
static func encode_public_row(source: Dictionary) -> Array:
	var action_index: int = ACTION_LABELS.find(str(source.get(KEY_ACTION_LABEL, "")))
	var posture_index: int = POSTURES.find(str(source.get(KEY_POSTURE, "")))
	var condition_index: int = CONDITIONS.find(str(source.get(KEY_CONDITION, "")))
	var row: Array = [
		source.get(KEY_NPC_ID, null),
		source.get(KEY_NAME, null),
		(source.get(KEY_APPEARANCE, {}) as Dictionary).duplicate() if typeof(source.get(KEY_APPEARANCE, null)) == TYPE_DICTIONARY else null,
		source.get(KEY_POSITION, null),
		_float_number(source.get(KEY_YAW, null)),
		action_index,
		posture_index,
		condition_index,
	]
	return row if public_row_error(row).is_empty() else []


static func public_row_error(value: Variant) -> String:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != PUBLIC_ROW_SIZE:
		return REASON_BAD_ROW
	var row: Array = value
	if not _valid_npc_id(row[PUBLIC_ID]) or not _valid_name(row[PUBLIC_NAME]):
		return REASON_BAD_ROW
	if not _valid_appearance(row[PUBLIC_APPEARANCE]):
		return REASON_BAD_ROW
	if not _valid_position(row[PUBLIC_POSITION]) or not _valid_yaw(row[PUBLIC_YAW]):
		return REASON_BAD_ROW
	if typeof(row[PUBLIC_ACTION]) != TYPE_INT or int(row[PUBLIC_ACTION]) < 0 or int(row[PUBLIC_ACTION]) >= ACTION_LABELS.size():
		return REASON_BAD_ROW
	if typeof(row[PUBLIC_POSTURE]) != TYPE_INT or int(row[PUBLIC_POSTURE]) < 0 or int(row[PUBLIC_POSTURE]) >= POSTURES.size():
		return REASON_BAD_ROW
	if typeof(row[PUBLIC_CONDITION]) != TYPE_INT or int(row[PUBLIC_CONDITION]) < 0 or int(row[PUBLIC_CONDITION]) >= CONDITIONS.size():
		return REASON_BAD_ROW
	return ""


static func decode_public_row(row: Array) -> Dictionary:
	return {
		KEY_NPC_ID: str(row[PUBLIC_ID]),
		KEY_NAME: str(row[PUBLIC_NAME]),
		KEY_APPEARANCE: (row[PUBLIC_APPEARANCE] as Dictionary).duplicate(),
		KEY_POSITION: row[PUBLIC_POSITION] as Vector3,
		KEY_YAW: float(row[PUBLIC_YAW]),
		KEY_ACTION_LABEL: ACTION_LABELS[int(row[PUBLIC_ACTION])],
		KEY_POSTURE: POSTURES[int(row[PUBLIC_POSTURE])],
		KEY_CONDITION: CONDITIONS[int(row[PUBLIC_CONDITION])],
	}


## Server: compact position row. Extra source data is never copied.
static func encode_snapshot_row(source: Dictionary) -> Array:
	var row: Array = [source.get(KEY_NPC_ID, null), source.get(KEY_POSITION, null), _float_number(source.get(KEY_YAW, null))]
	return row if snapshot_row_error(row).is_empty() else []


static func snapshot_row_error(value: Variant) -> String:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != SNAPSHOT_ROW_SIZE:
		return REASON_BAD_ROW
	var row: Array = value
	if not _valid_npc_id(row[SNAPSHOT_ID]) or not _valid_position(row[SNAPSHOT_POSITION]) or not _valid_yaw(row[SNAPSHOT_YAW]):
		return REASON_BAD_ROW
	return ""


static func decode_snapshot_row(row: Array) -> Dictionary:
	return {
		KEY_NPC_ID: str(row[SNAPSHOT_ID]),
		KEY_POSITION: row[SNAPSHOT_POSITION] as Vector3,
		KEY_YAW: float(row[SNAPSHOT_YAW]),
	}


static func entered_event(public_row: Array, world_time: float) -> Dictionary:
	if not is_finite(world_time) or not public_row_error(public_row).is_empty():
		return {}
	return {
		KEY_EVENT_TYPE: EVENT_ENTERED,
		KEY_NPC_ID: str(public_row[PUBLIC_ID]),
		KEY_WORLD_TIME: world_time,
		KEY_ROW: public_row.duplicate(true),
	}


static func left_event(npc_id: String, world_time: float) -> Dictionary:
	var event: Dictionary = {KEY_EVENT_TYPE: EVENT_LEFT, KEY_NPC_ID: npc_id, KEY_WORLD_TIME: world_time}
	return event if event_error(event).is_empty() else {}


static func action_changed_event(npc_id: String, action_label: String, world_time: float) -> Dictionary:
	var event: Dictionary = {
		KEY_EVENT_TYPE: EVENT_ACTION_CHANGED,
		KEY_NPC_ID: npc_id,
		KEY_WORLD_TIME: world_time,
		KEY_ACTION_LABEL: action_label,
	}
	return event if event_error(event).is_empty() else {}


static func condition_changed_event(npc_id: String, condition: String, world_time: float) -> Dictionary:
	var event: Dictionary = {
		KEY_EVENT_TYPE: EVENT_CONDITION_CHANGED,
		KEY_NPC_ID: npc_id,
		KEY_WORLD_TIME: world_time,
		KEY_CONDITION: condition,
	}
	return event if event_error(event).is_empty() else {}


## Client: exact event validation. Unknown fields are rejected so a server
## bug cannot silently expose a new NPC detail.
static func event_error(value: Variant) -> String:
	if typeof(value) != TYPE_DICTIONARY:
		return REASON_BAD_EVENT
	var event: Dictionary = value
	var event_type: Variant = event.get(KEY_EVENT_TYPE, null)
	if typeof(event_type) != TYPE_STRING or not [EVENT_ENTERED, EVENT_LEFT, EVENT_ACTION_CHANGED, EVENT_CONDITION_CHANGED].has(str(event_type)):
		return REASON_BAD_EVENT_TYPE
	if not _valid_npc_id(event.get(KEY_NPC_ID, null)) or not _valid_number(event.get(KEY_WORLD_TIME, null)):
		return REASON_BAD_EVENT_FIELD
	var expected: PackedStringArray = [KEY_EVENT_TYPE, KEY_NPC_ID, KEY_WORLD_TIME]
	match str(event_type):
		EVENT_ENTERED:
			expected.append(KEY_ROW)
			if not event.has(KEY_ROW) or not public_row_error(event[KEY_ROW]).is_empty():
				return REASON_BAD_EVENT_FIELD
			if str((event[KEY_ROW] as Array)[PUBLIC_ID]) != str(event[KEY_NPC_ID]):
				return REASON_BAD_EVENT_FIELD
		EVENT_ACTION_CHANGED:
			expected.append(KEY_ACTION_LABEL)
			if typeof(event.get(KEY_ACTION_LABEL, null)) != TYPE_STRING or not ACTION_LABELS.has(str(event[KEY_ACTION_LABEL])):
				return REASON_BAD_EVENT_FIELD
		EVENT_CONDITION_CHANGED:
			expected.append(KEY_CONDITION)
			if typeof(event.get(KEY_CONDITION, null)) != TYPE_STRING or not CONDITIONS.has(str(event[KEY_CONDITION])):
				return REASON_BAD_EVENT_FIELD
	if not _has_exact_keys(event, expected):
		return REASON_UNKNOWN_EVENT_FIELD
	return ""


static func _valid_npc_id(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and (value as String).length() <= MAX_ID_LENGTH and NpcState.is_valid_npc_id(value as String)


static func _valid_name(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var display_name: String = value
	if display_name.is_empty() or display_name.length() > NpcDefinition.NAME_MAX_LENGTH or display_name.strip_edges() != display_name:
		return false
	for index: int in display_name.length():
		var codepoint: int = display_name.unicode_at(index)
		if codepoint <= 0x1F or (codepoint >= 0x7F and codepoint <= 0x9F):
			return false
	return true


static func _valid_appearance(value: Variant) -> bool:
	if typeof(value) != TYPE_DICTIONARY or (value as Dictionary).is_empty() or (value as Dictionary).size() > MAX_APPEARANCE_SLOTS:
		return false
	for slot_id: Variant in (value as Dictionary):
		var option_id: Variant = (value as Dictionary)[slot_id]
		if typeof(slot_id) != TYPE_STRING or typeof(option_id) != TYPE_STRING:
			return false
		if (slot_id as String).length() > MAX_APPEARANCE_ID_LENGTH or (option_id as String).length() > MAX_APPEARANCE_ID_LENGTH:
			return false
		if not ItemInstance.is_valid_definition_id(slot_id as String) or not ItemInstance.is_valid_definition_id(option_id as String):
			return false
	return true


static func _valid_position(value: Variant) -> bool:
	return typeof(value) == TYPE_VECTOR3 and (value as Vector3).is_finite()


static func _valid_yaw(value: Variant) -> bool:
	return _valid_number(value) and absf(float(value)) <= MAX_ABS_YAW


static func _valid_number(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT and is_finite(float(value))


static func _float_number(value: Variant) -> Variant:
	return float(value) if typeof(value) == TYPE_INT else value


static func _has_exact_keys(data: Dictionary, expected: PackedStringArray) -> bool:
	if data.size() != expected.size():
		return false
	for key: Variant in data:
		if typeof(key) != TYPE_STRING or not expected.has(str(key)):
			return false
	return true
