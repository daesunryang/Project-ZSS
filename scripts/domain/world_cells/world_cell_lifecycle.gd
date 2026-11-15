class_name WorldCellLifecycle
extends RefCounted
## States of one world cell on the server and the transitions between them
## (P3-1, docs/03 §3.2, docs/00 ADR-023). Pure rules, no state.
##
##   UNLOADED   the cell's entities are not in memory; they are in the save.
##   LOADING    its saved entities are being brought into memory.
##   PRELOADED  in memory, not simulated ("사전 로딩 셀", docs/03 §3.1).
##   ACTIVE     in memory and simulated.
##   SAVING     its entities are being saved before they are released.
##   UNLOADING  saved; its entities are being released from memory.
##
## docs/03 §3.2 names the main path UNLOADED -> LOADING -> ACTIVE -> SAVING
## -> UNLOADING. PRELOADED is the step between "loaded" and "simulated" on
## the way in and on the way out:
##
##   UNLOADED -> LOADING -> PRELOADED <-> ACTIVE
##                  |           |
##                  v           v
##               UNLOADED     SAVING -> UNLOADING -> UNLOADED
##            (load failed)     |
##                              v
##                          PRELOADED (save failed: nothing is released)

enum State { UNLOADED, LOADING, PRELOADED, ACTIVE, SAVING, UNLOADING }

## Log / diagnostic names, indexed by State.
const STATE_NAMES: PackedStringArray = ["unloaded", "loading", "preloaded", "active", "saving", "unloading"]

const _ALLOWED: Dictionary = {
	State.UNLOADED: [State.LOADING],
	State.LOADING: [State.PRELOADED, State.UNLOADED],
	State.PRELOADED: [State.ACTIVE, State.SAVING],
	State.ACTIVE: [State.PRELOADED],
	State.SAVING: [State.UNLOADING, State.PRELOADED],
	State.UNLOADING: [State.UNLOADED],
}


## True when a cell in state `from` may go to state `to`.
static func can_transition(from: int, to: int) -> bool:
	return _ALLOWED.has(from) and (_ALLOWED[from] as Array).has(to)


## Name of a state, "" for a value that is no state.
static func state_name(state: int) -> String:
	return STATE_NAMES[state] if state >= 0 and state < STATE_NAMES.size() else ""


## True while the cell's entities are in memory and complete.
static func is_loaded(state: int) -> bool:
	return state == State.PRELOADED or state == State.ACTIVE or state == State.SAVING


## True while the cell's entities are simulated (AI, senses, attacks).
static func is_simulated(state: int) -> bool:
	return state == State.ACTIVE
