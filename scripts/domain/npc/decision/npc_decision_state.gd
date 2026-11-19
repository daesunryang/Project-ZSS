class_name NpcDecisionState
extends RefCounted
## The bounded state machine of an NPC's behaviour (P4-4, docs/05 §10,
## docs/09 §17.6): the seven states and the transitions that are allowed.
## Names are stable (they are saved and shown by the debug overlay).
##
## Between two decisions an NPC is in one of RESTING_STATES; EVALUATE, PLAN
## and INTERRUPT are passed through inside one decision (a decision takes no
## time), and are written into the decision record's "path".

## No action. A turn or an event starts an evaluation.
const IDLE: String = "idle"
## The candidates are scored.
const EVALUATE: String = "evaluate"
## The chosen action is handed to the executor (target, reservation).
const PLAN: String = "plan"
## The executor moves the NPC to where the action happens.
const NAVIGATE: String = "navigate"
## The executor performs the action (eating, resting, working, ...).
const PERFORM: String = "perform"
## The running action is stopped: a hard interrupt, a better action, or the
## executor reported a failure.
const INTERRUPT: String = "interrupt"
## After a failure: nothing is chosen until a short cooldown is over.
const RECOVER: String = "recover"

const ALL: PackedStringArray = [IDLE, EVALUATE, PLAN, NAVIGATE, PERFORM, INTERRUPT, RECOVER]
## The states an NPC can be in between two decisions (the only ones a save
## can hold).
const RESTING_STATES: PackedStringArray = [IDLE, NAVIGATE, PERFORM, RECOVER]
## The states in which the executor runs an action of the NPC.
const RUNNING_STATES: PackedStringArray = [NAVIGATE, PERFORM]

## from -> the states it may change to.
const TRANSITIONS: Dictionary = {
	IDLE: [EVALUATE, INTERRUPT],
	# back to NAVIGATE / PERFORM: the running action is kept.
	EVALUATE: [IDLE, PLAN, NAVIGATE, PERFORM, INTERRUPT],
	PLAN: [NAVIGATE, RECOVER],
	# IDLE: the action is done (an action without a perform part too).
	NAVIGATE: [PERFORM, EVALUATE, INTERRUPT, IDLE],
	PERFORM: [EVALUATE, INTERRUPT, IDLE],
	INTERRUPT: [PLAN, RECOVER, IDLE],
	RECOVER: [EVALUATE, INTERRUPT],
}


static func is_state(state: String) -> bool:
	return ALL.has(state)


static func is_running(state: String) -> bool:
	return RUNNING_STATES.has(state)


static func can_transition(from: String, to: String) -> bool:
	return TRANSITIONS.has(from) and (TRANSITIONS[from] as Array).has(to)
