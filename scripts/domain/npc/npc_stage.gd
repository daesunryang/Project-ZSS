class_name NpcStage
extends RefCounted
## One kind of work done for the NPCs every server tick (P4-1, docs/09
## §17.1 "단계 계약"): the scheduler (P4-3), the executor (P4-5a), ... Later
## tickets add a stage by adding a file that extends this class and one
## line in ServerComposition (NpcService.add_stage); NpcService stays as it
## is. P4-1 has no stage: NPCs stand still.
##
## NpcService calls the stages in the order they were added:
##   - on_npc_entered / on_npc_left: an NPC came into memory (spawned, or
##     its cell was loaded) or left it (its cell was released, or `retired`:
##     it was removed for good). An NPC that is not in memory cannot be
##     reached; what must survive belongs in an NpcComponent.
##   - on_npc_woke / on_npc_slept: its cell became simulated (ACTIVE) or
##     stopped being simulated. Only NPCs that are awake are simulated
##     (docs/13 §16.3 D4); a sleeping one keeps its state as it is.
##     Order: entered, woke, ..., slept, left.
##   - step: once per tick, after the cell changes of that tick. Both deltas
##     are 0 while the world clock is paused. A stage never runs the full AI
##     of every NPC every tick (AGENTS.md §6): it looks at
##     NpcService.awake_npc_ids() and keeps its own cadence.
##   - to_world_document / restore_world_document: what the stage itself
##     must keep across a restart (not per NPC: that is a component). Saved
##     in world_state.json under systems.npc.stages.<stage_id>.

## Unique snake_case id; also the save key. Must be overridden.
func stage_id() -> String:
	return ""


func on_npc_entered(_world: ServerWorld, _npc: NpcState) -> void:
	return


func on_npc_left(_world: ServerWorld, _npc: NpcState, _retired: bool) -> void:
	return


func on_npc_woke(_world: ServerWorld, _npc: NpcState) -> void:
	return


func on_npc_slept(_world: ServerWorld, _npc: NpcState) -> void:
	return


func step(_world: ServerWorld, _npcs: NpcService, _action_delta: float, _world_delta: float) -> void:
	return


## World-level save document of this stage ({} = nothing to save).
## JSON-safe.
func to_world_document() -> Dictionary:
	return {}


## Restores the document; returns errors (non-empty = discard the world).
## Not called when the save has no document for this stage.
func restore_world_document(_document: Dictionary) -> PackedStringArray:
	return PackedStringArray()
