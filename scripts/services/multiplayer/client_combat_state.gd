class_name ClientCombatState
extends RefCounted
## Bounded list of the newest public combat events (docs/09 §14.13). Pure
## data: never authoritative, never sent back to the server, never read by
## game rules.
##
## Client: mirror of what the server broadcast (CombatNetModule fills it).
## The server's module keeps one as well, as the record of what it
## broadcast (diagnostics and tests).
##
## This class owns the wire format of a public combat event and its
## validation: only a well-formed event with a newer sequence number gets
## in, and only the known keys are kept.
##
## Public event `melee_attack` (Dictionary, String keys):
##   sequence: int >= 1          server counter, +1 per broadcast event
##   event_type: "melee_attack"
##   attacker_id: String         player id
##   weapon_id: String           MeleeWeaponDefinition id
##   aim_yaw: float              radians, [-PI, PI]
##   position: Vector3           attacker's server position at the swing
##   hit: bool
##   target_id: String           zombie id, "" exactly when hit is false
##   target_died: bool           only true on a hit
##   world_time: float >= 0      server world time, seconds
##   damage: float >= 0              optional, always together with
##   target_health_after: float >= 0   the field above (server setting)

signal changed

const EVENT_MELEE_ATTACK: String = "melee_attack"

const KEY_SEQUENCE: String = "sequence"
const KEY_EVENT_TYPE: String = "event_type"
const KEY_ATTACKER_ID: String = "attacker_id"
const KEY_WEAPON_ID: String = "weapon_id"
const KEY_AIM_YAW: String = "aim_yaw"
const KEY_POSITION: String = "position"
const KEY_HIT: String = "hit"
const KEY_TARGET_ID: String = "target_id"
const KEY_TARGET_DIED: String = "target_died"
const KEY_WORLD_TIME: String = "world_time"
const KEY_DAMAGE: String = "damage"
const KEY_TARGET_HEALTH_AFTER: String = "target_health_after"
## Keys copied into the mirror, in this order. Anything else is dropped.
const REQUIRED_KEYS: PackedStringArray = [
	KEY_SEQUENCE, KEY_EVENT_TYPE, KEY_ATTACKER_ID, KEY_WEAPON_ID, KEY_AIM_YAW,
	KEY_POSITION, KEY_HIT, KEY_TARGET_ID, KEY_TARGET_DIED, KEY_WORLD_TIME,
]
const OPTIONAL_KEYS: PackedStringArray = [KEY_DAMAGE, KEY_TARGET_HEALTH_AFTER]

## Not a Dictionary, a missing key, a wrong type or a value out of range.
const REASON_BAD_EVENT: String = "bad_combat_event"
## Well-formed envelope but an event type this build does not know.
const REASON_UNKNOWN_EVENT: String = "unknown_combat_event"
## Sequence number not newer than the last applied one.
const REASON_STALE_EVENT: String = "stale_combat_event"

const FIRST_SEQUENCE: int = 1
const NO_SEQUENCE: int = 0
## Longest entity / weapon id accepted (same bound as client intents).
const ID_MAX_LENGTH: int = IntentValidator.ENTITY_ID_MAX_LENGTH
const MAX_ABS_AIM_YAW: float = PI
const MIN_CAPACITY: int = 1

## Sequence number of the newest applied event (NO_SEQUENCE = none yet).
var last_sequence: int = NO_SEQUENCE

var _capacity: int
var _events: Array[Dictionary] = []


func _init(capacity: int) -> void:
	_capacity = maxi(capacity, MIN_CAPACITY)


## Forgets every event. `baseline_sequence` is the newest sequence number
## the server had already sent (join snapshot); older ones are never applied.
func reset(baseline_sequence: int = NO_SEQUENCE) -> void:
	_events.clear()
	last_sequence = maxi(baseline_sequence, NO_SEQUENCE)
	changed.emit()


## Validates `payload` and appends a cleaned copy. Returns "" when it was
## applied, otherwise a REASON_* code (nothing changes then).
func apply_event(payload: Variant) -> String:
	var reason: String = validate_event(payload)
	if not reason.is_empty():
		return reason
	var event: Dictionary = payload
	var sequence: int = event[KEY_SEQUENCE]
	if sequence <= last_sequence:
		return REASON_STALE_EVENT
	_events.append(_clean_copy(event))
	while _events.size() > _capacity:
		_events.pop_front()
	last_sequence = sequence
	changed.emit()
	return ""


## Copies of the kept events, oldest first.
func recent_events() -> Array[Dictionary]:
	var copies: Array[Dictionary] = []
	for event: Dictionary in _events:
		copies.append(event.duplicate())
	return copies


## Copy of the newest kept event ({} when there is none).
func last_event() -> Dictionary:
	return {} if _events.is_empty() else _events[_events.size() - 1].duplicate()


func event_count() -> int:
	return _events.size()


## "" when `payload` is a well-formed public combat event, otherwise
## REASON_BAD_EVENT or REASON_UNKNOWN_EVENT. Does not look at the sequence
## order.
static func validate_event(payload: Variant) -> String:
	if typeof(payload) != TYPE_DICTIONARY:
		return REASON_BAD_EVENT
	var event: Dictionary = payload
	var event_type: Variant = event.get(KEY_EVENT_TYPE, null)
	if typeof(event_type) != TYPE_STRING:
		return REASON_BAD_EVENT
	if str(event_type) != EVENT_MELEE_ATTACK:
		return REASON_UNKNOWN_EVENT
	return "" if _is_melee_attack(event) else REASON_BAD_EVENT


static func _is_melee_attack(event: Dictionary) -> bool:
	var sequence: Variant = event.get(KEY_SEQUENCE, null)
	if typeof(sequence) != TYPE_INT or int(sequence) < FIRST_SEQUENCE:
		return false
	if not _is_id(event.get(KEY_ATTACKER_ID, null), false) or not _is_id(event.get(KEY_WEAPON_ID, null), false):
		return false
	var aim_yaw: Variant = event.get(KEY_AIM_YAW, null)
	if typeof(aim_yaw) != TYPE_FLOAT or not is_finite(float(aim_yaw)) or absf(float(aim_yaw)) > MAX_ABS_AIM_YAW:
		return false
	var position: Variant = event.get(KEY_POSITION, null)
	if typeof(position) != TYPE_VECTOR3 or not (position as Vector3).is_finite():
		return false
	var hit: Variant = event.get(KEY_HIT, null)
	var target_id: Variant = event.get(KEY_TARGET_ID, null)
	var target_died: Variant = event.get(KEY_TARGET_DIED, null)
	if typeof(hit) != TYPE_BOOL or typeof(target_died) != TYPE_BOOL or not _is_id(target_id, true):
		return false
	# A hit names its target; a miss has none and kills nothing.
	if bool(hit) == str(target_id).is_empty() or (bool(target_died) and not bool(hit)):
		return false
	if not _is_amount(event.get(KEY_WORLD_TIME, null)):
		return false
	# The damage numbers come together or not at all.
	if event.has(KEY_DAMAGE) != event.has(KEY_TARGET_HEALTH_AFTER):
		return false
	if event.has(KEY_DAMAGE) and (not _is_amount(event[KEY_DAMAGE]) or not _is_amount(event[KEY_TARGET_HEALTH_AFTER])):
		return false
	return true


## A String of at most ID_MAX_LENGTH characters (empty only if allowed).
static func _is_id(value: Variant, allow_empty: bool) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var text: String = value
	return text.length() <= ID_MAX_LENGTH and (allow_empty or not text.is_empty())


## A finite float >= 0.
static func _is_amount(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT and is_finite(float(value)) and float(value) >= 0.0


## Copy with the known keys only (validated before).
static func _clean_copy(event: Dictionary) -> Dictionary:
	var copy: Dictionary = {}
	for key: String in REQUIRED_KEYS:
		copy[key] = event[key]
	for key: String in OPTIONAL_KEYS:
		if event.has(key):
			copy[key] = event[key]
	return copy
