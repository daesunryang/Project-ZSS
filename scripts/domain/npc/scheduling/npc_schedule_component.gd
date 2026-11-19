class_name NpcScheduleComponent
extends NpcComponent
## When one NPC thinks next (P4-3, docs/09 §17.3): the part of the
## scheduler's state that belongs to one NPC and is saved with it, so an NPC
## that left memory, or a server that was restarted, goes on exactly where
## it was (docs/13 §16.3 D11). Only NpcScheduler changes it.
##
## All times are microseconds of the scheduler's own clock
## (NpcScheduler.clock_usec): whole numbers, so a save never rounds them.
##
## Document: {next_decision_at_usec: int (-1 = never scheduled),
##            tier: "near" | "far",
##            interrupts: {reason: at_usec}}

const COMPONENT_ID: String = "schedule"
const NEVER_SCHEDULED: int = -1
## "No time": later than every time of the clock (2^53 - 1, JSON-exact).
const NO_TIME: int = 9007199254740991
## Most interrupts (asked for or timed) one NPC can wait for at once.
const MAX_INTERRUPTS: int = 16
const KEY_NEXT_DECISION: String = "next_decision_at_usec"
const KEY_TIER: String = "tier"
const KEY_INTERRUPTS: String = "interrupts"

## Clock time of the NPC's next periodic decision.
var next_decision_at_usec: int = NEVER_SCHEDULED
## The tier the NPC's schedule follows while it is awake (NpcState does not
## save its tier: a frozen NPC has none).
var tier: String = NpcState.TIER_NEAR
## reason -> clock time from which that interrupt is due.
var interrupts: Dictionary[String, int] = {}


static func make() -> NpcComponent:
	return NpcScheduleComponent.new()


func component_id() -> String:
	return COMPONENT_ID


func is_scheduled() -> bool:
	return next_decision_at_usec != NEVER_SCHEDULED


## Clock time of the earliest interrupt (NO_TIME = none).
func earliest_interrupt_usec() -> int:
	var earliest: int = NO_TIME
	for reason: String in interrupts:
		earliest = mini(earliest, interrupts[reason])
	return earliest


## Clock time at which this NPC must be looked at next (NO_TIME = never).
func earliest_usec() -> int:
	return mini(earliest_interrupt_usec(), next_decision_at_usec if is_scheduled() else NO_TIME)


## Removes and returns the interrupts that are due at `now_usec`, oldest
## first (then by name).
func take_due_interrupts(now_usec: int) -> PackedStringArray:
	var due: Array[Array] = []
	for reason: String in interrupts:
		if interrupts[reason] <= now_usec:
			due.append([interrupts[reason], reason])
	due.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]) if int(a[0]) != int(b[0]) else str(a[1]) < str(b[1]))
	var reasons: PackedStringArray = []
	for entry: Array in due:
		reasons.append(str(entry[1]))
		interrupts.erase(str(entry[1]))
	return reasons


func to_document() -> Dictionary:
	var saved: Dictionary = {}
	var reasons: PackedStringArray = PackedStringArray(interrupts.keys())
	reasons.sort()
	for reason: String in reasons:
		saved[reason] = interrupts[reason]
	return {KEY_NEXT_DECISION: next_decision_at_usec, KEY_TIER: tier, KEY_INTERRUPTS: saved}


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	var next_at: Variant = document.get(KEY_NEXT_DECISION, null)
	if not _is_time(next_at, NEVER_SCHEDULED):
		errors.append("next_decision_at_usec must be a whole number >= -1")
	var saved_tier: Variant = document.get(KEY_TIER, null)
	if typeof(saved_tier) != TYPE_STRING or not NpcState.SIMULATED_TIERS.has(str(saved_tier)):
		errors.append("tier must be near or far")
	var saved: Variant = document.get(KEY_INTERRUPTS, null)
	if typeof(saved) != TYPE_DICTIONARY or (saved as Dictionary).size() > MAX_INTERRUPTS:
		errors.append("interrupts must be an object of at most %d entries" % MAX_INTERRUPTS)
		return errors
	for reason: Variant in (saved as Dictionary):
		if typeof(reason) != TYPE_STRING or not is_valid_reason(str(reason)) or not _is_time((saved as Dictionary)[reason], 0):
			errors.append("invalid interrupt %s" % str(reason))
	if not errors.is_empty():
		return errors
	next_decision_at_usec = int(next_at)
	tier = str(saved_tier)
	interrupts.clear()
	for reason: Variant in (saved as Dictionary):
		interrupts[str(reason)] = int((saved as Dictionary)[reason])
	return errors


## True for a name an interrupt may have: snake_case, and not the name of
## the periodic reason.
static func is_valid_reason(reason: String) -> bool:
	return reason != NpcDecider.REASON_PERIOD and NpcComponent.is_valid_id(reason)


static func _is_time(value: Variant, least: int) -> bool:
	return ItemInstance.is_integer_value(value) and float(value) >= float(least) and float(value) <= float(NO_TIME)
