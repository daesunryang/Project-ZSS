class_name NpcExecutorState
extends NpcComponent
## What one NPC is in the middle of doing (P4-5a, docs/09 §17.7): the part
## of the executor's state that belongs to one NPC and is saved with it, so
## an NPC that left memory, or a server that was restarted, goes on exactly
## where it was without planning again (docs/13 §16.3 D11). Only
## NpcExecutor changes it.
##
## All times are whole microseconds (counted down), every position is three
## 32-bit floats: a save neither rounds nor moves any of it.
##
## Document:
##   {phase: "idle" | "planning" | "moving" | "using",
##    kind: "" | "move" | "use_spot",
##    target: [x, y, z], run: bool, spot_id, target_entity_id,
##    waypoints: [[x, y, z], ...]      what is still ahead, next first
##    timer_usec: int                  using: time left (-1 = until
##                                     cancelled); moving: the pause at a
##                                     door; planning: the wait before the
##                                     next search
##    use_usec: int                    use_spot: how long to stay (-1 = until
##                                     cancelled)
##    plan_seq: int (-1 = not queued)  its place in the planning queue
##    plan_expanded: int               nodes its running search has expanded
##    replans: int                     searches after the first, this action
##    opened_doors: [structure_id]     doors it opened and still has to close
##    reserved_spot_id, reservation_auto: bool
##    last_result: "" | "done" | "failed" | "cancelled", last_code}
## The running search itself is not saved: after a restore it is run again
## up to `plan_expanded` nodes, which gives the same search.

const COMPONENT_ID: String = "executor"

const PHASE_IDLE: String = "idle"
const PHASE_PLANNING: String = "planning"
const PHASE_MOVING: String = "moving"
const PHASE_USING: String = "using"
const PHASES: PackedStringArray = [PHASE_IDLE, PHASE_PLANNING, PHASE_MOVING, PHASE_USING]
const KIND_NONE: String = ""
const KIND_MOVE: String = "move"
const KIND_USE_SPOT: String = "use_spot"
const KINDS: PackedStringArray = [KIND_NONE, KIND_MOVE, KIND_USE_SPOT]
const RESULT_NONE: String = ""
const RESULT_DONE: String = "done"
const RESULT_FAILED: String = "failed"
const RESULT_CANCELLED: String = "cancelled"
const RESULTS: PackedStringArray = [RESULT_NONE, RESULT_DONE, RESULT_FAILED, RESULT_CANCELLED]
## timer_usec / use_usec of an action that lasts until it is cancelled.
const FOREVER: int = -1
const NOT_QUEUED: int = -1
## Largest whole number a save carries exactly (2^53 - 1).
const MAX_SAFE_INT: int = 9007199254740991
const MAX_WAYPOINTS: int = 8192
const MAX_OPENED_DOORS: int = 16

const KEY_PHASE: String = "phase"
const KEY_KIND: String = "kind"
const KEY_TARGET: String = "target"
const KEY_RUN: String = "run"
const KEY_SPOT: String = "spot_id"
const KEY_TARGET_ENTITY: String = "target_entity_id"
const KEY_WAYPOINTS: String = "waypoints"
const KEY_TIMER: String = "timer_usec"
const KEY_USE: String = "use_usec"
const KEY_PLAN_SEQ: String = "plan_seq"
const KEY_PLAN_EXPANDED: String = "plan_expanded"
const KEY_REPLANS: String = "replans"
const KEY_OPENED_DOORS: String = "opened_doors"
const KEY_RESERVED_SPOT: String = "reserved_spot_id"
const KEY_RESERVATION_AUTO: String = "reservation_auto"
const KEY_LAST_RESULT: String = "last_result"
const KEY_LAST_CODE: String = "last_code"

var phase: String = PHASE_IDLE
var kind: String = KIND_NONE
var target: Vector3 = Vector3.ZERO
var run: bool = false
var spot_id: String = ""
var target_entity_id: String = ""
## The whole path of the current walk; `waypoint_index` is the next one.
var waypoints: Array[Vector3] = []
var waypoint_index: int = 0
var timer_usec: int = 0
var use_usec: int = 0
var plan_seq: int = NOT_QUEUED
var plan_expanded: int = 0
var replans: int = 0
var opened_doors: PackedStringArray = []
## The spot this NPC holds, or wants back when it wakes.
var reserved_spot_id: String = ""
## True: the current action took the reservation and gives it back when it
## ends. False: it was reserved by hand (NpcExecutor.reserve) and stays.
var reservation_auto: bool = false
var last_result: String = RESULT_NONE
var last_code: String = ""


static func make() -> NpcComponent:
	return NpcExecutorState.new()


func component_id() -> String:
	return COMPONENT_ID


func is_busy() -> bool:
	return phase != PHASE_IDLE


## The waypoints that are still ahead, next first.
func remaining_waypoints() -> Array[Vector3]:
	return waypoints.slice(waypoint_index)


## Back to "doing nothing". The reservation and the last result stay.
func clear_action() -> void:
	phase = PHASE_IDLE
	kind = KIND_NONE
	target = Vector3.ZERO
	run = false
	spot_id = ""
	target_entity_id = ""
	waypoints = []
	waypoint_index = 0
	timer_usec = 0
	use_usec = 0
	plan_seq = NOT_QUEUED
	plan_expanded = 0
	replans = 0


func to_document() -> Dictionary:
	var points: Array = []
	for index: int in range(waypoint_index, waypoints.size()):
		points.append(_point(waypoints[index]))
	return {
		KEY_PHASE: phase,
		KEY_KIND: kind,
		KEY_TARGET: _point(target),
		KEY_RUN: run,
		KEY_SPOT: spot_id,
		KEY_TARGET_ENTITY: target_entity_id,
		KEY_WAYPOINTS: points,
		KEY_TIMER: timer_usec,
		KEY_USE: use_usec,
		KEY_PLAN_SEQ: plan_seq,
		KEY_PLAN_EXPANDED: plan_expanded,
		KEY_REPLANS: replans,
		KEY_OPENED_DOORS: Array(opened_doors),
		KEY_RESERVED_SPOT: reserved_spot_id,
		KEY_RESERVATION_AUTO: reservation_auto,
		KEY_LAST_RESULT: last_result,
		KEY_LAST_CODE: last_code,
	}


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if typeof(document.get(KEY_PHASE, null)) != TYPE_STRING or not PHASES.has(str(document[KEY_PHASE])):
		errors.append("phase must be one of %s" % ", ".join(PHASES))
	if typeof(document.get(KEY_KIND, null)) != TYPE_STRING or not KINDS.has(str(document[KEY_KIND])):
		errors.append("kind must be move, use_spot or empty")
	if not _is_point(document.get(KEY_TARGET, null)):
		errors.append("target must be three finite numbers")
	for key: String in [KEY_RUN, KEY_RESERVATION_AUTO]:
		if typeof(document.get(key, null)) != TYPE_BOOL:
			errors.append("%s must be true or false" % key)
	for key: String in [KEY_SPOT, KEY_RESERVED_SPOT, KEY_LAST_CODE]:
		var name: Variant = document.get(key, null)
		if typeof(name) != TYPE_STRING or not (str(name).is_empty() or NpcComponent.is_valid_id(str(name))):
			errors.append("%s must be a snake_case name or empty" % key)
	if typeof(document.get(KEY_TARGET_ENTITY, null)) != TYPE_STRING or str(document[KEY_TARGET_ENTITY]).length() > ID_MAX_LENGTH:
		errors.append("target_entity_id must be a short string")
	if typeof(document.get(KEY_LAST_RESULT, null)) != TYPE_STRING or not RESULTS.has(str(document[KEY_LAST_RESULT])):
		errors.append("last_result must be done, failed, cancelled or empty")
	for entry: Array in [[KEY_TIMER, FOREVER], [KEY_USE, FOREVER], [KEY_PLAN_SEQ, NOT_QUEUED], [KEY_PLAN_EXPANDED, 0], [KEY_REPLANS, 0]]:
		var number: Variant = document.get(str(entry[0]), null)
		if not ItemInstance.is_integer_value(number) or float(number) < float(entry[1]) or float(number) > float(MAX_SAFE_INT):
			errors.append("%s must be a whole number >= %d" % [str(entry[0]), int(entry[1])])
	var points: Variant = document.get(KEY_WAYPOINTS, null)
	if typeof(points) != TYPE_ARRAY or (points as Array).size() > MAX_WAYPOINTS:
		errors.append("waypoints must be a list of at most %d points" % MAX_WAYPOINTS)
	else:
		for point: Variant in (points as Array):
			if not _is_point(point):
				errors.append("every waypoint must be three finite numbers")
				break
	var doors: Variant = document.get(KEY_OPENED_DOORS, null)
	if typeof(doors) != TYPE_ARRAY or (doors as Array).size() > MAX_OPENED_DOORS:
		errors.append("opened_doors must be a list of at most %d ids" % MAX_OPENED_DOORS)
	else:
		for door: Variant in (doors as Array):
			if typeof(door) != TYPE_STRING or str(door).is_empty() or str(door).length() > ID_MAX_LENGTH:
				errors.append("every opened door must be a structure id")
				break
	if not errors.is_empty():
		return errors
	if (str(document[KEY_PHASE]) == PHASE_IDLE) != (str(document[KEY_KIND]) == KIND_NONE):
		errors.append("phase and kind do not agree")
	if str(document[KEY_KIND]) == KIND_USE_SPOT and str(document[KEY_SPOT]).is_empty():
		errors.append("use_spot needs a spot_id")
	if str(document[KEY_PHASE]) == PHASE_USING and str(document[KEY_KIND]) != KIND_USE_SPOT:
		errors.append("only use_spot can be using")
	if not errors.is_empty():
		return errors
	phase = str(document[KEY_PHASE])
	kind = str(document[KEY_KIND])
	target = _to_point(document[KEY_TARGET])
	run = bool(document[KEY_RUN])
	spot_id = str(document[KEY_SPOT])
	target_entity_id = str(document[KEY_TARGET_ENTITY])
	waypoints = []
	for point: Variant in (points as Array):
		waypoints.append(_to_point(point))
	waypoint_index = 0
	timer_usec = int(document[KEY_TIMER])
	use_usec = int(document[KEY_USE])
	plan_seq = int(document[KEY_PLAN_SEQ])
	plan_expanded = int(document[KEY_PLAN_EXPANDED])
	replans = int(document[KEY_REPLANS])
	opened_doors = PackedStringArray()
	for door: Variant in (doors as Array):
		opened_doors.append(str(door))
	reserved_spot_id = str(document[KEY_RESERVED_SPOT])
	reservation_auto = bool(document[KEY_RESERVATION_AUTO])
	last_result = str(document[KEY_LAST_RESULT])
	last_code = str(document[KEY_LAST_CODE])
	return errors


static func _point(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


static func _to_point(value: Variant) -> Vector3:
	var raw: Array = value as Array
	return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))


static func _is_point(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 3:
		return false
	for coordinate: Variant in (value as Array):
		if (typeof(coordinate) != TYPE_FLOAT and typeof(coordinate) != TYPE_INT) or not is_finite(float(coordinate)):
			return false
	return true
