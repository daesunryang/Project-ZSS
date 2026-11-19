class_name NpcBehaviourExecutor
extends NpcActionExecutor
## The executor the decision layer talks to (P4-5b, docs/09 §17.8): the
## NpcActionExecutor contract of P4-4, carried out by the behaviour stage
## (NpcBehaviours) on top of the movement executor of P4-5a (NpcExecutor).
## Nothing but the join: every call goes to the stage, which NpcService
## owns (this object is held by the decider, so it holds the stage weakly).

var _behaviours_ref: WeakRef = null


func _init(behaviours: NpcBehaviours) -> void:
	_behaviours_ref = weakref(behaviours)


## The behaviour stage (null when its world is gone).
func behaviours() -> NpcBehaviours:
	return _behaviours_ref.get_ref() as NpcBehaviours if _behaviours_ref != null else null


func begin(world: ServerWorld, npcs: NpcService, npc: NpcState, action: NpcActionDefinition, target: Dictionary) -> String:
	var stage: NpcBehaviours = behaviours()
	return stage.begin(world, npcs, npc, action, target) if stage != null else FAIL_UNSUPPORTED


func is_running(npc_id: String) -> bool:
	var stage: NpcBehaviours = behaviours()
	return stage != null and stage.is_running(npc_id)


func cancel(world: ServerWorld, npcs: NpcService, npc: NpcState) -> void:
	var stage: NpcBehaviours = behaviours()
	if stage != null:
		stage.cancel(world, npcs, npc)
