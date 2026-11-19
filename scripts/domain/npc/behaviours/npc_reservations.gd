class_name NpcReservations
extends RefCounted
## Who holds which NPC spot right now (P4-5a, docs/09 §17.7): one NPC per
## spot, one spot per NPC. A plain table without rules of its own: WHEN a
## spot is taken and given back is the executor's business (NpcExecutor),
## and what must survive a restart is saved with the NPC
## (NpcExecutorState.reserved_spot_id), not here. Only NPCs that are awake
## are in the table.

var _holder_of: Dictionary[String, String] = {}
var _spot_of: Dictionary[String, String] = {}


## Gives `spot_id` to `npc_id`. False (nothing changes) when another NPC
## holds it. An NPC that held another spot gives that one back.
func claim(spot_id: String, npc_id: String) -> bool:
	if spot_id.is_empty() or npc_id.is_empty():
		return false
	var holder: String = _holder_of.get(spot_id, "")
	if holder == npc_id:
		return true
	if not holder.is_empty():
		return false
	release_of(npc_id)
	_holder_of[spot_id] = npc_id
	_spot_of[npc_id] = spot_id
	return true


## Gives back whatever `npc_id` holds. Returns that spot ("" = none).
func release_of(npc_id: String) -> String:
	var spot_id: String = _spot_of.get(npc_id, "")
	if not spot_id.is_empty():
		_spot_of.erase(npc_id)
		_holder_of.erase(spot_id)
	return spot_id


## The NPC that holds a spot ("" = it is free).
func holder_of(spot_id: String) -> String:
	return _holder_of.get(spot_id, "")


## The spot an NPC holds ("" = none).
func spot_of(npc_id: String) -> String:
	return _spot_of.get(npc_id, "")


## True when nobody, or `for_npc_id`, holds the spot.
func is_free(spot_id: String, for_npc_id: String = "") -> bool:
	var holder: String = _holder_of.get(spot_id, "")
	return holder.is_empty() or holder == for_npc_id


func count() -> int:
	return _holder_of.size()
