class_name NpcDecider
extends RefCounted
## What an NPC does when its turn to think comes (P4-3, docs/09 §17.3). The
## scheduler (NpcScheduler) decides WHEN an NPC thinks and calls decide();
## WHAT it then does is P4-4, which extends this class. This base class is
## "no decision": the NPC stands still.

## Reason of a decision whose period came round (the other reasons are the
## interrupts that were asked for, see NpcScheduler.request_interrupt).
const REASON_PERIOD: String = "period"


## The scheduler this decider was given to. Keep a WEAK reference only: the
## scheduler owns the decider.
func on_attached(_scheduler: NpcScheduler) -> void:
	return


## `npc` is awake and it is its turn. `reasons` says why, without
## duplicates: REASON_PERIOD first when its period came round, then the
## interrupts that are due, oldest first. Called at most once per NPC and
## tick. Random numbers come from `npc.rng` only. Interrupts asked for in
## here (also for this NPC) are handled in a later tick.
func decide(_world: ServerWorld, _npcs: NpcService, _npc: NpcState, _reasons: PackedStringArray, _scheduler: NpcScheduler) -> void:
	return
