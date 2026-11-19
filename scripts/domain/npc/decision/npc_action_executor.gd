class_name NpcActionExecutor
extends RefCounted
## What carries out the action an NPC chose (P4-4 defines it, P4-5a / P4-5b
## implement it; docs/09 §17.6 "실행기 계약"). The decider (NpcUtilityDecider)
## decides WHAT an NPC does and calls begin() / cancel(); the executor moves
## the NPC, reserves spots, changes needs and inventories, and reports back
## through the scheduler's interrupts:
##
##   scheduler.request_interrupt(npc_id, REPORT_ARRIVED)
##       the NPC is where the action happens and starts performing it
##       (at most once per begin(); an action without a way to go reports
##       it at once, an action that is over when the NPC arrives - wander -
##       may skip it and report REPORT_DONE);
##   scheduler.request_interrupt(npc_id, REPORT_DONE)
##       the action is finished;
##   scheduler.request_interrupt(npc_id, failed_reason(code))
##       the action cannot go on; `code` is a snake_case failure code (the
##       FAIL_ constants, or the executor's own).
##
## Rules:
##   - One action per NPC. begin() while another action of that NPC runs is
##     never called: the decider cancels first.
##   - After REPORT_DONE, a failure report, or cancel(), the action is over
##     for the executor too: is_running() is false, whatever it reserved is
##     free, and it reports nothing more about it.
##   - cancel() reports nothing.
##   - The executor keeps what must survive a save (the action in progress,
##     the way that is left) in its own NpcComponent, so that after a
##     restore is_running() answers as before the save (docs/13 §16.3 D11).
##     The decider keeps the chosen action id and the target it gave.
##   - `target` is JSON-safe. {} = the executor finds the place from the
##     action and the NPC (its definition's home / work place, the map's NPC
##     spots). The flee action gets {threat_id, threat_position: [x, y, z]}.
##   - Random numbers from `npc.rng` only.
##
## This base class runs nothing: begin() refuses every action.

const REPORT_ARRIVED: String = "action_arrived"
const REPORT_DONE: String = "action_done"
const REPORT_FAILED_PREFIX: String = "action_failed_"

## Failure codes (any snake_case id is accepted; these are the shared ones).
## The executor does not know the action.
const FAIL_UNSUPPORTED: String = "unsupported_action"
## There is no way to the place.
const FAIL_NO_PATH: String = "no_path"
## The place or the thing the action needs is not there (any more).
const FAIL_TARGET_GONE: String = "target_gone"
## The spot is taken by another NPC.
const FAIL_RESERVED: String = "reserved"
## What the action uses up is missing (no food in the container).
const FAIL_NO_RESOURCE: String = "no_resource"
## The decider's own: the executor does not run the action the NPC's saved
## state says it runs (a save of another build).
const FAIL_LOST: String = "executor_lost"

## Keys of the flee action's target.
const TARGET_THREAT_ID: String = "threat_id"
const TARGET_THREAT_POSITION: String = "threat_position"


## Starts `action` for `npc`. Returns "" when the action runs now, or a
## failure code (nothing runs, nothing is reserved, nothing is reported).
func begin(_world: ServerWorld, _npcs: NpcService, _npc: NpcState, _action: NpcActionDefinition, _target: Dictionary) -> String:
	return FAIL_UNSUPPORTED


## True while an action of this NPC runs (from an accepted begin() until it
## is done, failed, or cancelled).
func is_running(_npc_id: String) -> bool:
	return false


## Stops the NPC's action, if one runs, and frees what it reserved.
func cancel(_world: ServerWorld, _npcs: NpcService, _npc: NpcState) -> void:
	return


## The interrupt reason that reports a failure with `code`.
static func failed_reason(code: String) -> String:
	return REPORT_FAILED_PREFIX + code


## The failure code of an interrupt reason ("" = it is not a failure report).
static func failure_code_of(reason: String) -> String:
	return reason.substr(REPORT_FAILED_PREFIX.length()) if reason.begins_with(REPORT_FAILED_PREFIX) and reason.length() > REPORT_FAILED_PREFIX.length() else ""
