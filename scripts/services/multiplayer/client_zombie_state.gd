class_name ClientZombieState
extends RefCounted
## Client-side mirror of the server's zombies (P2-N1a, docs/09 §14.12).
## Pure data: never authoritative, never sent back to the server. Owned by
## ZombieNetModule (`module.client_state`); presentation reads it.
##
## Read surface:
##   zombies / zombie_ids() / has_zombie(id) / get_zombie(id) / zombie_count()
##     zombie_id -> {position: Vector3, yaw: float, state: String
##     (ZombieState.STATE_NAMES), health_fraction: float 0..1}, spawn order
##   signals changed, zombie_added(id), zombie_removed(id),
##     event_received(event)
##   recent_events(), events_after(sequence): newest events, oldest first;
##     each is the server event (docs/09 §14.9) plus `sequence` (1-based
##     position in the server's event stream)
##
## Sources and ordering:
##   - Membership (which zombies exist) only changes through the reliable
##     channel: the join snapshot and zombie_spawned / zombie_removed events.
##     Snapshots never add a zombie, so a late snapshot cannot resurrect a
##     removed one.
##   - position / yaw / health_fraction follow the newest position snapshot
##     (older ticks are dropped). zombie_died also sets health_fraction 0.
##   - state follows zombie_state_changed / zombie_died events at once and
##     snapshots otherwise. A snapshot older than the last event applied to
##     a zombie may move it but cannot change its state or health back
##     (channels 0 and 2 are not ordered against each other).
##   - Events carry a sequence number; events at or below the sequence of
##     the join snapshot are already part of it and are skipped.
##
## Every payload is validated (ZombieNetProtocol); malformed input is
## counted, logged and leaves the mirror untouched. No interpolation or
## prediction here (docs/15 P2-84).

signal changed
signal zombie_added(zombie_id: String)
signal zombie_removed(zombie_id: String)
## One validated server event, in server order, after the mirror was updated.
signal event_received(event: Dictionary)

const REASON_BAD_TYPE: String = "bad_type"
const REASON_BAD_TICK: String = "bad_tick"
const REASON_BAD_SEQUENCE: String = "bad_sequence"
const REASON_BAD_FRAGMENT: String = "bad_fragment"
const REASON_TOO_MANY_ROWS: String = "too_many_rows"
const REASON_BAD_EVENT_COUNT: String = "bad_event_count"
const REASON_DUPLICATE_ID: String = "duplicate_zombie_id"
const REASON_MIRROR_FULL: String = "mirror_full"
## Not errors: an older snapshot, or a snapshot before the join snapshot.
const REASON_STALE: String = "stale"
const REASON_NOT_JOINED: String = "not_joined"
const KEY_SEQUENCE: String = "sequence"
const STATE_IDLE: String = "idle"
const STATE_DEAD: String = "dead"
const NO_TICK: int = -1

## zombie_id -> {"position", "yaw", "state", "health_fraction"} (spawn order).
var zombies: Dictionary[String, Dictionary] = {}
## Server tick of the newest applied snapshot (join snapshot included).
var last_snapshot_tick: int = NO_TICK
## Sequence of the newest event that is reflected in this mirror.
var last_event_sequence: int = 0
## Diagnostics: malformed payloads/events ignored, stale snapshots dropped,
## holes seen in the event sequence.
var rejected_payload_count: int = 0
var stale_snapshot_count: int = 0
var event_gap_count: int = 0

var _settings: ZombieNetSettings
var _joined: bool = false
## zombie_id -> server tick of the last event applied to it.
var _event_ticks: Dictionary[String, int] = {}
var _recent_events: Array[Dictionary] = []


func _init(settings: ZombieNetSettings = null) -> void:
	_settings = settings if settings != null else ZombieNetSettings.new()


# ------------------------------------------------------------ read surface

func has_zombie(zombie_id: String) -> bool:
	return zombies.has(zombie_id)


## Mirror entry of one zombie ({} if unknown). Do not mutate.
func get_zombie(zombie_id: String) -> Dictionary:
	return zombies.get(zombie_id, {})


## Mirrored zombie ids in server spawn order.
func zombie_ids() -> PackedStringArray:
	return PackedStringArray(zombies.keys())


func zombie_count() -> int:
	return zombies.size()


## The newest events (at most `recent_event_capacity`), oldest first.
func recent_events() -> Array[Dictionary]:
	return _recent_events.duplicate()


## Kept events with a sequence greater than `sequence`, oldest first. A
## poller remembers the last sequence it handled and asks for the rest.
func events_after(sequence: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in _recent_events:
		if int(event[KEY_SEQUENCE]) > sequence:
			result.append(event)
	return result


# ------------------------------------------------------------ apply

## Replaces the mirror with the join snapshot fragment
## {tick: int, event_sequence: int, rows: Array}; {} means "no zombies".
## Returns "" or a reason code (the mirror is then empty).
func apply_join(fragment: Dictionary) -> String:
	zombies.clear()
	_event_ticks.clear()
	_recent_events.clear()
	last_snapshot_tick = NO_TICK
	last_event_sequence = 0
	_joined = true
	var reason: String = "" if fragment.is_empty() else _load_join(fragment)
	if not reason.is_empty():
		zombies.clear()
		_event_ticks.clear()
		last_snapshot_tick = NO_TICK
		last_event_sequence = 0
		_reject("zombie join snapshot ignored", reason, "apply_join")
	changed.emit()
	return reason


## Applies one position snapshot message (`rows` of ZombieNetProtocol wire
## rows). Older ticks are dropped; the same tick is accepted because one
## snapshot may be split into several messages. One bad row rejects the
## whole message. Returns "" or a reason code.
func apply_snapshot(tick: Variant, rows: Variant) -> String:
	if typeof(tick) != TYPE_INT or typeof(rows) != TYPE_ARRAY:
		return _reject("zombie snapshot ignored", REASON_BAD_TYPE, "apply_snapshot")
	if int(tick) < 0:
		return _reject("zombie snapshot ignored", REASON_BAD_TICK, "apply_snapshot")
	var entries: Array = rows
	if entries.size() > ZombieNetProtocol.MAX_ROWS_PER_MESSAGE:
		return _reject("zombie snapshot ignored", REASON_TOO_MANY_ROWS, "apply_snapshot")
	for entry: Variant in entries:
		var reason: String = ZombieNetProtocol.row_error(entry)
		if not reason.is_empty():
			return _reject("zombie snapshot ignored", reason, "apply_snapshot")
	if not _joined:
		return REASON_NOT_JOINED
	if int(tick) < last_snapshot_tick:
		stale_snapshot_count += 1
		return REASON_STALE
	last_snapshot_tick = int(tick)
	var dirty: bool = false
	for entry: Variant in entries:
		var row: Array = entry
		var zombie_id: String = row[ZombieNetProtocol.ROW_ID]
		if not zombies.has(zombie_id):
			continue  # not spawned yet for this client, or already removed
		var current: Dictionary = zombies[zombie_id]
		var next: Dictionary = ZombieNetProtocol.decode_row(row)
		if int(tick) < int(_event_ticks.get(zombie_id, NO_TICK)):
			# Built before an event we already applied: movement only.
			next["state"] = current["state"]
			next["health_fraction"] = current["health_fraction"]
		if next != current:
			zombies[zombie_id] = next
			dirty = true
	if dirty:
		changed.emit()
	return ""


## Applies one reliable event message: `events[i]` has sequence
## `first_sequence + i` and happened at server tick `tick`. Events at or
## below last_event_sequence are skipped; a malformed event is skipped and
## counted but still consumes its sequence number. Returns "" or the reason
## the whole message was ignored.
func apply_events(tick: Variant, first_sequence: Variant, events: Variant) -> String:
	if typeof(tick) != TYPE_INT or typeof(first_sequence) != TYPE_INT or typeof(events) != TYPE_ARRAY:
		return _reject("zombie events ignored", REASON_BAD_TYPE, "apply_events")
	if int(tick) < 0:
		return _reject("zombie events ignored", REASON_BAD_TICK, "apply_events")
	if int(first_sequence) < 1:
		return _reject("zombie events ignored", REASON_BAD_SEQUENCE, "apply_events")
	var entries: Array = events
	if entries.is_empty() or entries.size() > ZombieNetProtocol.MAX_EVENTS_PER_MESSAGE:
		return _reject("zombie events ignored", REASON_BAD_EVENT_COUNT, "apply_events")
	if not _joined:
		return _reject("zombie events ignored", REASON_NOT_JOINED, "apply_events")
	var dirty: bool = false
	for index: int in range(entries.size()):
		var sequence: int = int(first_sequence) + index
		if sequence <= last_event_sequence:
			continue  # already reflected in the join snapshot
		if sequence > last_event_sequence + 1:
			event_gap_count += 1
			GameLogger.warning("net", "zombie event sequence gap", {"expected": last_event_sequence + 1, "received": sequence, "operation": "apply_events"})
		last_event_sequence = sequence
		var reason: String = ZombieNetProtocol.event_error(entries[index])
		if not reason.is_empty():
			_reject("zombie event ignored", reason, "apply_events", {"sequence": sequence})
			continue
		var event: Dictionary = (entries[index] as Dictionary).duplicate(true)
		event[KEY_SEQUENCE] = sequence
		if _apply_event(event, int(tick)):
			dirty = true
		_recent_events.append(event)
		while _recent_events.size() > _settings.recent_event_capacity:
			_recent_events.pop_front()
		event_received.emit(event)
	if dirty:
		changed.emit()
	return ""


# ------------------------------------------------------------ internals

func _load_join(fragment: Dictionary) -> String:
	var tick: Variant = fragment.get(ZombieNetProtocol.KEY_TICK, null)
	var sequence: Variant = fragment.get(ZombieNetProtocol.KEY_EVENT_SEQUENCE, null)
	var rows: Variant = fragment.get(ZombieNetProtocol.KEY_ROWS, null)
	if typeof(tick) != TYPE_INT or typeof(sequence) != TYPE_INT or typeof(rows) != TYPE_ARRAY:
		return REASON_BAD_FRAGMENT
	if int(tick) < 0 or int(sequence) < 0:
		return REASON_BAD_FRAGMENT
	if (rows as Array).size() > _settings.max_mirrored_zombies:
		return REASON_TOO_MANY_ROWS
	for entry: Variant in (rows as Array):
		var reason: String = ZombieNetProtocol.row_error(entry)
		if not reason.is_empty():
			return reason
		var row: Array = entry
		var zombie_id: String = row[ZombieNetProtocol.ROW_ID]
		if zombies.has(zombie_id):
			return REASON_DUPLICATE_ID
		zombies[zombie_id] = ZombieNetProtocol.decode_row(row)
		_event_ticks[zombie_id] = int(tick)
	last_snapshot_tick = int(tick)
	last_event_sequence = int(sequence)
	return ""


## Updates the mirror for one validated event. True when it changed.
func _apply_event(event: Dictionary, tick: int) -> bool:
	var zombie_id: String = event[ZombieNetProtocol.KEY_ZOMBIE_ID]
	match str(event[ZombieNetProtocol.KEY_EVENT_TYPE]):
		ZombieService.EVENT_SPAWNED:
			var is_new: bool = not zombies.has(zombie_id)
			if is_new and zombies.size() >= _settings.max_mirrored_zombies:
				_reject("zombie not mirrored", REASON_MIRROR_FULL, "apply_events", {"entity_id": zombie_id})
				return false
			var point: Array = event["position"]
			zombies[zombie_id] = {
				"position": Vector3(point[0], point[1], point[2]),
				"yaw": float(event["yaw"]),
				"state": STATE_IDLE,
				"health_fraction": 1.0,
			}
			_event_ticks[zombie_id] = tick
			if is_new:
				zombie_added.emit(zombie_id)
			return true
		ZombieService.EVENT_STATE_CHANGED:
			return _set_fields(zombie_id, tick, {"state": str(event["to"])})
		ZombieService.EVENT_DIED:
			return _set_fields(zombie_id, tick, {"state": STATE_DEAD, "health_fraction": 0.0})
		ZombieService.EVENT_REMOVED:
			_event_ticks.erase(zombie_id)
			if not zombies.erase(zombie_id):
				return false
			zombie_removed.emit(zombie_id)
			return true
	return false


func _set_fields(zombie_id: String, tick: int, fields: Dictionary) -> bool:
	if not zombies.has(zombie_id):
		return false
	_event_ticks[zombie_id] = tick
	var entry: Dictionary = zombies[zombie_id]
	var dirty: bool = false
	for key: String in fields:
		if entry[key] != fields[key]:
			entry[key] = fields[key]
			dirty = true
	return dirty


func _reject(message: String, reason: String, operation: String, context: Dictionary = {}) -> String:
	rejected_payload_count += 1
	var details: Dictionary = {"reason": reason, "operation": operation}
	details.merge(context)
	GameLogger.warning("net", message, details)
	return reason
