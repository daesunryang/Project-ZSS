class_name ZombieNetProtocol
extends RefCounted
## Wire format of zombie replication (P2-N1a, docs/09 §14.12). Pure static
## functions shared by the server (encode = whitelist of what may leave the
## server) and the client (validate = type, length, finite values). No
## state, no nodes.
##
## Snapshot row (join fragment and channel 2 snapshots) is a flat array:
##   [zombie_id: String, position: Vector3, yaw: float,
##    state: int (index into ZombieState.STATE_NAMES),
##    health_fraction: float (0..1)]
##
## Event (channel 0) is a Dictionary with exactly `event_type`, `zombie_id`,
## `world_time` and the fields EVENT_FIELDS lists for its type; values are
## the ones ZombieService produced (docs/09 §14.9). Fields in PRIVATE_FIELDS
## are optional: the server only sends them to the player named by the
## event's PRIVATE_OWNER_FIELD (docs/15 P2-9: the infection result of a hit
## and the target's exact health are for the attacked player alone).
##
## A domain field that is not listed here is never sent, so new server-side
## fields stay private until someone adds them on purpose.
##
## Scope events (P3-2, docs/09 §15.2). Two event types exist only on the
## wire; ZombieService never produces them:
##   zombie_entered  the zombie came into the cells this client is told
##                   about (it walked in, the client walked near, or its cell
##                   came into the server's memory). Carries what a snapshot
##                   row carries, so it shows at once as what it is.
##   zombie_left     the zombie left those cells. It still exists.
## A client can so tell "appeared / left my view" from zombie_spawned /
## zombie_removed, which say that a zombie was made or cleared away.

## Value kinds of event fields.
##   ID        non-empty String, at most MAX_ID_LENGTH
##   TEXT      String (may be empty), at most MAX_TEXT_LENGTH
##   NUMBER    finite float
##   ANGLE     finite float, |value| <= MAX_ABS_YAW
##   FLAG      bool
##   STATE     one of ZombieState.STATE_NAMES
##   POINT     [x, y, z] array of finite floats
##   FRACTION  finite float within 0..1
enum Kind { ID, TEXT, NUMBER, ANGLE, FLAG, STATE, POINT, FRACTION }

const MAX_ID_LENGTH: int = 64
const MAX_TEXT_LENGTH: int = 64
## Hard limits a client accepts per message (settings must stay below).
const MAX_ROWS_PER_MESSAGE: int = 64
const MAX_EVENTS_PER_MESSAGE: int = 64
## Same bound as client move intents (IntentValidator.MAX_ABS_YAW).
const MAX_ABS_YAW: float = TAU
## Target size of one snapshot message so it fits a single datagram.
## PROVISIONAL (docs/15 P2-82): compared against var_to_bytes() of the rows,
## which is close to but not the same as the bytes on the wire.
const SNAPSHOT_MESSAGE_BUDGET_BYTES: int = 1200

const ROW_ID: int = 0
const ROW_POSITION: int = 1
const ROW_YAW: int = 2
const ROW_STATE: int = 3
const ROW_HEALTH: int = 4
const ROW_SIZE: int = 5

## Join fragment keys (snapshot["modules"]["ZombieNet"]).
const KEY_TICK: String = "tick"
const KEY_EVENT_SEQUENCE: String = "event_sequence"
const KEY_ROWS: String = "rows"

const KEY_EVENT_TYPE: String = "event_type"
const KEY_ZOMBIE_ID: String = "zombie_id"
const KEY_WORLD_TIME: String = "world_time"

const REASON_BAD_ROW: String = "bad_row"
const REASON_BAD_EVENT: String = "bad_event"
const REASON_BAD_EVENT_TYPE: String = "bad_event_type"
const REASON_BAD_EVENT_FIELD: String = "bad_event_field"
const REASON_UNKNOWN_EVENT_FIELD: String = "unknown_event_field"

## Wire-only event types (see "Scope events" in the header).
const EVENT_ENTERED: String = "zombie_entered"
const EVENT_LEFT: String = "zombie_left"

## Fields every event carries.
const COMMON_FIELDS: Dictionary = {
	KEY_EVENT_TYPE: Kind.TEXT,
	KEY_ZOMBIE_ID: Kind.ID,
	KEY_WORLD_TIME: Kind.NUMBER,
}
## event_type -> {field: Kind}; all listed fields are required.
const EVENT_FIELDS: Dictionary = {
	ZombieService.EVENT_SPAWNED: {"position": Kind.POINT, "yaw": Kind.ANGLE},
	ZombieService.EVENT_DETECTED: {"sense": Kind.TEXT, "target_id": Kind.TEXT, "position": Kind.POINT},
	ZombieService.EVENT_STATE_CHANGED: {"from": Kind.STATE, "to": Kind.STATE, "cause": Kind.TEXT, "target_id": Kind.TEXT},
	ZombieService.EVENT_ATTACKED: {
		"target_id": Kind.ID, "wound_type": Kind.TEXT, "body_part": Kind.TEXT, "damage": Kind.NUMBER,
		"target_died": Kind.FLAG,
	},
	ZombieService.EVENT_DAMAGED: {"source_id": Kind.TEXT, "damage": Kind.NUMBER, "health_after": Kind.NUMBER, "died": Kind.FLAG},
	ZombieService.EVENT_DIED: {"source_id": Kind.TEXT},
	ZombieService.EVENT_REMOVED: {},
	EVENT_ENTERED: {"position": Kind.POINT, "yaw": Kind.ANGLE, "state": Kind.STATE, "health_fraction": Kind.FRACTION},
	EVENT_LEFT: {},
}
## event_type -> {field: Kind}; optional, owner-only fields.
## zombie_attacked: the infection result and the target's exact health are
## the attacked player's own business (docs/15 P2-9, P2-85); everyone still
## sees who was hit, how (bite/scratch, body part, damage) and whether the
## target died.
const PRIVATE_FIELDS: Dictionary = {
	ZombieService.EVENT_ATTACKED: {"target_health_after": Kind.NUMBER, "infection": Kind.TEXT},
}
## Event field naming the player who may see that event's private fields.
const PRIVATE_OWNER_FIELD: String = "target_id"


# ------------------------------------------------------------ rows

## Server: wire row for one ZombieService.snapshot_rows() entry, or [] when
## the entry does not fit the format (never sent).
static func encode_row(row: Dictionary) -> Array:
	var encoded: Array = [
		row.get("id", null),
		row.get("position", null),
		row.get("yaw", null),
		ZombieState.STATE_NAMES.find(str(row.get("state", ""))),
		row.get("health_fraction", null),
	]
	return encoded if row_error(encoded).is_empty() else []


## "" when `row` is a valid wire row, otherwise a reason code.
static func row_error(row: Variant) -> String:
	if typeof(row) != TYPE_ARRAY or (row as Array).size() != ROW_SIZE:
		return REASON_BAD_ROW
	var values: Array = row
	if not _is_valid(Kind.ID, values[ROW_ID]):
		return REASON_BAD_ROW
	if typeof(values[ROW_POSITION]) != TYPE_VECTOR3 or not (values[ROW_POSITION] as Vector3).is_finite():
		return REASON_BAD_ROW
	if not _is_valid(Kind.ANGLE, values[ROW_YAW]):
		return REASON_BAD_ROW
	if typeof(values[ROW_STATE]) != TYPE_INT or int(values[ROW_STATE]) < 0 or int(values[ROW_STATE]) >= ZombieState.STATE_NAMES.size():
		return REASON_BAD_ROW
	if not _is_valid(Kind.NUMBER, values[ROW_HEALTH]) or float(values[ROW_HEALTH]) < 0.0 or float(values[ROW_HEALTH]) > 1.0:
		return REASON_BAD_ROW
	return ""


## Client: mirror entry for a row that passed row_error().
static func decode_row(row: Array) -> Dictionary:
	return {
		"position": row[ROW_POSITION] as Vector3,
		"yaw": float(row[ROW_YAW]),
		"state": ZombieState.STATE_NAMES[int(row[ROW_STATE])],
		"health_fraction": float(row[ROW_HEALTH]),
	}


# ------------------------------------------------------------ events

## Server: full wire event (private fields included) for one domain event,
## or {} when the event is unknown or does not fit the format. Only listed
## fields are copied; integers become floats.
static func encode_event(event: Dictionary) -> Dictionary:
	var event_type: Variant = event.get(KEY_EVENT_TYPE, null)
	if typeof(event_type) != TYPE_STRING or not EVENT_FIELDS.has(event_type):
		return {}
	var wire: Dictionary = {}
	if not _copy_fields(event, wire, COMMON_FIELDS, true):
		return {}
	if not _copy_fields(event, wire, EVENT_FIELDS[event_type] as Dictionary, true):
		return {}
	if not _copy_fields(event, wire, PRIVATE_FIELDS.get(event_type, {}) as Dictionary, false):
		return {}
	return wire


## "" when `event` is a valid wire event (with or without its private
## fields), otherwise a reason code. Unknown keys are rejected.
static func event_error(event: Variant) -> String:
	if typeof(event) != TYPE_DICTIONARY:
		return REASON_BAD_EVENT
	var values: Dictionary = event
	var event_type: Variant = values.get(KEY_EVENT_TYPE, null)
	if typeof(event_type) != TYPE_STRING or not EVENT_FIELDS.has(event_type):
		return REASON_BAD_EVENT_TYPE
	var fields: Dictionary = EVENT_FIELDS[event_type]
	var private_fields: Dictionary = PRIVATE_FIELDS.get(event_type, {})
	var expected_size: int = COMMON_FIELDS.size() + fields.size()
	for key: String in COMMON_FIELDS:
		if not values.has(key) or not _is_valid(COMMON_FIELDS[key] as Kind, values[key]):
			return REASON_BAD_EVENT_FIELD
	for key: String in fields:
		if not values.has(key) or not _is_valid(fields[key] as Kind, values[key]):
			return REASON_BAD_EVENT_FIELD
	for key: String in private_fields:
		if not values.has(key):
			continue
		if not _is_valid(private_fields[key] as Kind, values[key]):
			return REASON_BAD_EVENT_FIELD
		expected_size += 1
	if values.size() != expected_size:
		return REASON_UNKNOWN_EVENT_FIELD
	return ""


## Server: the wire event that brings a zombie into a client's view, from
## one ZombieService.snapshot_rows() entry, or {} when the entry does not
## fit the format.
static func entered_event(row: Dictionary, world_time: float) -> Dictionary:
	var position: Variant = row.get("position", null)
	if typeof(position) != TYPE_VECTOR3:
		return {}
	var point: Vector3 = position
	return encode_event({
		KEY_EVENT_TYPE: EVENT_ENTERED,
		KEY_ZOMBIE_ID: row.get("id", null),
		KEY_WORLD_TIME: world_time,
		"position": [point.x, point.y, point.z],
		"yaw": row.get("yaw", null),
		"state": row.get("state", null),
		"health_fraction": row.get("health_fraction", null),
	})


## Server: the wire event that takes a zombie out of a client's view.
static func left_event(zombie_id: String, world_time: float) -> Dictionary:
	return encode_event({KEY_EVENT_TYPE: EVENT_LEFT, KEY_ZOMBIE_ID: zombie_id, KEY_WORLD_TIME: world_time})


## Player id that may receive the private fields of this wire event, or ""
## when it has none.
static func private_owner(event: Dictionary) -> String:
	var private_fields: Dictionary = PRIVATE_FIELDS.get(event.get(KEY_EVENT_TYPE, ""), {})
	for key: String in private_fields:
		if event.has(key):
			return str(event.get(PRIVATE_OWNER_FIELD, ""))
	return ""


## The event as everyone may see it: the same Dictionary when it has no
## private fields, otherwise a copy without them.
static func public_event(event: Dictionary) -> Dictionary:
	if private_owner(event).is_empty():
		return event
	var shared: Dictionary = event.duplicate()
	for key: String in (PRIVATE_FIELDS[event[KEY_EVENT_TYPE]] as Dictionary):
		shared.erase(key)
	return shared


# ------------------------------------------------------------ internals

static func _copy_fields(source: Dictionary, target: Dictionary, fields: Dictionary, required: bool) -> bool:
	for key: String in fields:
		if not source.has(key):
			if required:
				return false
			continue
		var value: Variant = _encode(fields[key] as Kind, source[key])
		if value == null:
			return false
		target[key] = value
	return true


## Wire value for a domain value, or null when it cannot be sent.
static func _encode(kind: Kind, value: Variant) -> Variant:
	var encoded: Variant = value
	match kind:
		Kind.NUMBER, Kind.ANGLE, Kind.FRACTION:
			if typeof(value) == TYPE_INT:
				encoded = float(value)
		Kind.POINT:
			if typeof(value) != TYPE_ARRAY:
				return null
			var point: Array = []
			for component: Variant in (value as Array):
				point.append(float(component) if typeof(component) == TYPE_INT else component)
			encoded = point
	return encoded if _is_valid(kind, encoded) else null


static func _is_valid(kind: Kind, value: Variant) -> bool:
	match kind:
		Kind.ID:
			return typeof(value) == TYPE_STRING and not (value as String).is_empty() and (value as String).length() <= MAX_ID_LENGTH
		Kind.TEXT:
			return typeof(value) == TYPE_STRING and (value as String).length() <= MAX_TEXT_LENGTH
		Kind.NUMBER:
			return typeof(value) == TYPE_FLOAT and is_finite(float(value))
		Kind.ANGLE:
			return typeof(value) == TYPE_FLOAT and is_finite(float(value)) and absf(float(value)) <= MAX_ABS_YAW
		Kind.FLAG:
			return typeof(value) == TYPE_BOOL
		Kind.STATE:
			return typeof(value) == TYPE_STRING and ZombieState.STATE_NAMES.has(value as String)
		Kind.FRACTION:
			return typeof(value) == TYPE_FLOAT and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= 1.0
		Kind.POINT:
			if typeof(value) != TYPE_ARRAY or (value as Array).size() != 3:
				return false
			for component: Variant in (value as Array):
				if typeof(component) != TYPE_FLOAT or not is_finite(float(component)):
					return false
			return true
	return false
