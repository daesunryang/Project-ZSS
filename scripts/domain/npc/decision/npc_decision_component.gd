class_name NpcDecisionComponent
extends NpcComponent
## What one NPC is doing and why it may not choose something else yet (P4-4,
## docs/09 §17.6): the part of the decider's state that belongs to one NPC
## and is saved with it, so an NPC that left memory, or a server that was
## restarted, goes on with the same action and makes the same decisions
## (docs/13 §16.3 D11). Only NpcUtilityDecider changes it.
##
## All times are microseconds of the scheduler's clock
## (NpcScheduler.clock_usec): whole numbers, a save never rounds them.
##
## Document: {state: "idle" | "navigate" | "perform" | "recover",
##            action_id: "" | the running action,
##            action_started_at_usec: int (-1 = no action),
##            target: {...} (what the executor was given),
##            cooldowns: {action_id: until_usec},
##            failures: {action_id: failures in a row},
##            last_failure: {} | {action_id, code, at_usec},
##            recover_until_usec: int (-1 = not recovering),
##            decision_count: int}
## The decision records (the ring the debug overlay reads) are NOT saved.

const COMPONENT_ID: String = "decision"
const SCHEMA_VERSION: int = 1
const NO_TIME: int = -1
## Largest time a document may hold (2^53 - 1, JSON-exact).
const MAX_TIME: int = NpcScheduleComponent.NO_TIME
## Most actions that can be on cooldown at once.
const MAX_COOLDOWNS: int = 64
const CODE_MAX_LENGTH: int = 48

const KEY_STATE: String = "state"
const KEY_ACTION_ID: String = "action_id"
const KEY_ACTION_STARTED: String = "action_started_at_usec"
const KEY_TARGET: String = "target"
const KEY_COOLDOWNS: String = "cooldowns"
const KEY_FAILURES: String = "failures"
const KEY_LAST_FAILURE: String = "last_failure"
const KEY_RECOVER_UNTIL: String = "recover_until_usec"
const KEY_DECISION_COUNT: String = "decision_count"
const KEY_CODE: String = "code"
const KEY_AT: String = "at_usec"

## One of NpcDecisionState.RESTING_STATES between two decisions.
var state: String = NpcDecisionState.IDLE
## The action the executor runs for this NPC ("" = none).
var action_id: String = ""
var action_started_at_usec: int = NO_TIME
var target: Dictionary = {}
## action_id -> clock time until which it is no candidate.
var cooldowns: Dictionary[String, int] = {}
## action_id -> failures in a row (cleared when the action is done).
var failures: Dictionary[String, int] = {}
var last_failure: Dictionary = {}
var recover_until_usec: int = NO_TIME
## Decisions made for this NPC so far (the sequence number of its records).
var decision_count: int = 0
## Transitions the state machine refused (a bug of the decider; tests
## expect 0). Not saved.
var illegal_transition_count: int = 0

var _catalog: NpcActionCatalog
var _records: Array[Dictionary] = []
var _npc_id: String = ""


func _init(catalog: NpcActionCatalog = null) -> void:
	_catalog = catalog


static func create(catalog: NpcActionCatalog) -> NpcComponent:
	return NpcDecisionComponent.new(catalog)


func component_id() -> String:
	return COMPONENT_ID


func schema_version() -> int:
	return SCHEMA_VERSION


func on_attached(_world: ServerWorld, npc: NpcState) -> void:
	_npc_id = npc.npc_id


# ------------------------------------------------------------ state machine

## Changes the state when NpcDecisionState allows it. A refused change is
## counted and logged, and the state stays.
func transition(to: String) -> bool:
	if not NpcDecisionState.can_transition(state, to):
		illegal_transition_count += 1
		GameLogger.error("npc", "illegal npc decision state transition", {"entity_id": _npc_id, "from": state, "to": to, "operation": "decision_transition"})
		return false
	state = to
	return true


## True while the executor runs an action of this NPC.
func is_running() -> bool:
	return NpcDecisionState.is_running(state) and not action_id.is_empty()


func set_action(id: String, action_target: Dictionary, now_usec: int) -> void:
	action_id = id
	target = action_target.duplicate(true)
	action_started_at_usec = now_usec


func clear_action() -> void:
	action_id = ""
	target = {}
	action_started_at_usec = NO_TIME


## Clock time until which `id` is no candidate (NO_TIME = it is one).
func cooldown_until(id: String) -> int:
	return cooldowns.get(id, NO_TIME)


func is_on_cooldown(id: String, now_usec: int) -> bool:
	return cooldown_until(id) > now_usec


## Forgets the cooldowns that are over.
func prune_cooldowns(now_usec: int) -> void:
	for id: String in cooldowns.keys():
		if cooldowns[id] <= now_usec:
			cooldowns.erase(id)


## Writes down a failure of `id` and returns how many it has had in a row.
func note_failure(id: String, code: String, now_usec: int) -> int:
	var count: int = int(failures.get(id, 0)) + 1
	failures[id] = count
	last_failure = {KEY_ACTION_ID: id, KEY_CODE: code, KEY_AT: now_usec}
	return count


func set_cooldown(id: String, until_usec: int) -> void:
	if cooldowns.size() < MAX_COOLDOWNS or cooldowns.has(id):
		cooldowns[id] = mini(until_usec, MAX_TIME)


# ------------------------------------------------------------ records

## Adds a decision record to the ring (the oldest is dropped beyond
## `capacity`).
func push_record(record: Dictionary, capacity: int) -> void:
	_records.append(record)
	while _records.size() > maxi(capacity, 1):
		_records.pop_front()


## The decision records that are kept, oldest first. Read-only.
func records() -> Array[Dictionary]:
	return _records


## The latest decision record ({} = none since this NPC came into memory).
func last_record() -> Dictionary:
	return _records[_records.size() - 1] if not _records.is_empty() else {}


# ------------------------------------------------------------ label

## What other players see this NPC do (docs/09 §17.5): the running
## action's label while it is performed, its walking label on the way there,
## "idle" otherwise.
func label() -> String:
	if not is_running() or _catalog == null:
		return NpcActionDefinition.LABEL_IDLE
	var action: NpcActionDefinition = _catalog.get_action(action_id)
	if action == null:
		return NpcActionDefinition.LABEL_IDLE
	return action.navigate_label if state == NpcDecisionState.NAVIGATE else action.observable_label


## The observable action label of an NPC: the function NpcNetModule is given
## (set_action_label_source). "idle" for an NPC without this component.
static func label_of(npc: NpcState) -> String:
	var component: NpcDecisionComponent = npc.component(COMPONENT_ID) as NpcDecisionComponent if npc != null else null
	return component.label() if component != null else NpcActionDefinition.LABEL_IDLE


# ------------------------------------------------------------ save

func to_document() -> Dictionary:
	return {
		KEY_STATE: state,
		KEY_ACTION_ID: action_id,
		KEY_ACTION_STARTED: action_started_at_usec,
		KEY_TARGET: target.duplicate(true),
		KEY_COOLDOWNS: _sorted(cooldowns),
		KEY_FAILURES: _sorted(failures),
		KEY_LAST_FAILURE: last_failure.duplicate(),
		KEY_RECOVER_UNTIL: recover_until_usec,
		KEY_DECISION_COUNT: decision_count,
	}


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get(NpcComponent.KEY_SCHEMA_VERSION, null)) or int(document[NpcComponent.KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("unsupported schema_version")
		return errors
	var saved_state: Variant = document.get(KEY_STATE, null)
	if typeof(saved_state) != TYPE_STRING or not NpcDecisionState.RESTING_STATES.has(str(saved_state)):
		errors.append("state must be idle, navigate, perform or recover")
	var saved_action: Variant = document.get(KEY_ACTION_ID, null)
	if typeof(saved_action) != TYPE_STRING or (not str(saved_action).is_empty() and not _is_action_id(str(saved_action))):
		errors.append("action_id must be an action id or empty")
	for key: String in [KEY_ACTION_STARTED, KEY_RECOVER_UNTIL]:
		if not _is_time(document.get(key, null), NO_TIME):
			errors.append("%s must be a whole number >= -1" % key)
	if not _is_time(document.get(KEY_DECISION_COUNT, null), 0):
		errors.append("decision_count must be a whole number >= 0")
	var saved_target: Variant = document.get(KEY_TARGET, null)
	if typeof(saved_target) != TYPE_DICTIONARY or not SaveService.is_json_safe(saved_target):
		errors.append("target must be an object")
	var saved_cooldowns: Variant = document.get(KEY_COOLDOWNS, null)
	if not _is_action_table(saved_cooldowns, 0) or (saved_cooldowns as Dictionary).size() > MAX_COOLDOWNS:
		errors.append("cooldowns must be {action_id: usec}, at most %d" % MAX_COOLDOWNS)
	var saved_failures: Variant = document.get(KEY_FAILURES, null)
	if not _is_action_table(saved_failures, 1):
		errors.append("failures must be {action_id: count >= 1}")
	var saved_failure: Variant = document.get(KEY_LAST_FAILURE, null)
	if typeof(saved_failure) != TYPE_DICTIONARY or not _is_failure(saved_failure as Dictionary):
		errors.append("last_failure must be {} or {action_id, code, at_usec}")
	if not errors.is_empty():
		return errors
	var running: bool = NpcDecisionState.is_running(str(saved_state))
	if running == str(saved_action).is_empty() or running != (int(document[KEY_ACTION_STARTED]) != NO_TIME):
		errors.append("an action and its start time belong to the states navigate and perform, and only to them")
	if (str(saved_state) == NpcDecisionState.RECOVER) != (int(document[KEY_RECOVER_UNTIL]) != NO_TIME):
		errors.append("recover_until_usec belongs to the state recover, and only to it")
	if not running and not (saved_target as Dictionary).is_empty():
		errors.append("a target without an action")
	if not errors.is_empty():
		return errors
	state = str(saved_state)
	action_id = str(saved_action)
	action_started_at_usec = int(document[KEY_ACTION_STARTED])
	target = (saved_target as Dictionary).duplicate(true)
	cooldowns.clear()
	for id: Variant in (saved_cooldowns as Dictionary):
		cooldowns[str(id)] = int((saved_cooldowns as Dictionary)[id])
	failures.clear()
	for id: Variant in (saved_failures as Dictionary):
		failures[str(id)] = int((saved_failures as Dictionary)[id])
	last_failure = {}
	if not (saved_failure as Dictionary).is_empty():
		last_failure = {KEY_ACTION_ID: str(saved_failure[KEY_ACTION_ID]), KEY_CODE: str(saved_failure[KEY_CODE]), KEY_AT: int(saved_failure[KEY_AT])}
	recover_until_usec = int(document[KEY_RECOVER_UNTIL])
	decision_count = int(document[KEY_DECISION_COUNT])
	return errors


static func _sorted(table: Dictionary) -> Dictionary:
	var ids: PackedStringArray = PackedStringArray(table.keys())
	ids.sort()
	var result: Dictionary = {}
	for id: String in ids:
		result[id] = table[id]
	return result


static func _is_action_id(id: String) -> bool:
	return NpcComponent.is_valid_id(id) and id.length() <= NpcActionDefinition.ID_MAX_LENGTH


static func _is_time(value: Variant, least: int) -> bool:
	return ItemInstance.is_integer_value(value) and float(value) >= float(least) and float(value) <= float(MAX_TIME)


static func _is_action_table(value: Variant, least: int) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		return false
	for id: Variant in (value as Dictionary):
		if typeof(id) != TYPE_STRING or not _is_action_id(str(id)) or not _is_time((value as Dictionary)[id], least):
			return false
	return true


static func _is_failure(value: Dictionary) -> bool:
	if value.is_empty():
		return true
	if value.size() != 3 or typeof(value.get(KEY_ACTION_ID, null)) != TYPE_STRING or typeof(value.get(KEY_CODE, null)) != TYPE_STRING:
		return false
	return _is_action_id(str(value[KEY_ACTION_ID])) and NpcComponent.is_valid_id(str(value[KEY_CODE])) and str(value[KEY_CODE]).length() <= CODE_MAX_LENGTH and _is_time(value.get(KEY_AT, null), 0)
