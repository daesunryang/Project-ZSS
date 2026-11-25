class_name NpcTalkIntentPolicy
extends RefCounted
## Pure client-side choice of what the talk keys ask for (F-31, docs/09
## §17.16), from the mirrors. It only picks ids to send: whether the NPC is
## in reach, can be seen, is alive and will talk is decided by the server.
##
## Three kinds of keys:
##   talk key      ask the nearest living NPC in reach (no conversation only)
##   number keys   the n-th answer of the view the mirror shows
##   end key       end the conversation

## Returned when there is nobody to talk to.
const NO_NPC: String = ""
## Returned when a number key names no answer.
const NO_CHOICE: String = ""


## Id of the nearest NPC of the mirror (`npcs`: ClientNpcState.npcs) that is
## no body, within `range_m` of `origin` on the XZ plane, or NO_NPC. Equal
## distances resolve to the smaller id. Malformed rows are skipped; invalid
## arguments give NO_NPC.
static func nearest_npc_id(origin: Vector3, npcs: Dictionary, range_m: float) -> String:
	if not origin.is_finite() or not is_finite(range_m) or range_m <= 0.0:
		return NO_NPC
	var best_id: String = NO_NPC
	var best_distance: float = INF
	for key: Variant in npcs:
		if typeof(key) != TYPE_STRING or typeof(npcs[key]) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = npcs[key]
		var position: Variant = row.get(NpcNetProtocol.KEY_POSITION, null)
		if typeof(position) != TYPE_VECTOR3 or not (position as Vector3).is_finite():
			continue
		if str(row.get(NpcNetProtocol.KEY_CONDITION, NpcNetProtocol.CONDITION_OK)) == NpcNetProtocol.CONDITION_DEAD:
			continue
		var distance: float = Vector2((position as Vector3).x - origin.x, (position as Vector3).z - origin.z).length()
		if distance > range_m:
			continue
		if distance < best_distance or (distance == best_distance and str(key) < best_id):
			best_distance = distance
			best_id = key
	return best_id


## True when the talk key may ask somebody: the local player is in no
## conversation and there is an NPC to ask.
static func can_start(conversation_open: bool, candidate_id: String) -> bool:
	return not conversation_open and candidate_id != NO_NPC


## The choice id the `number`-th number key (1 = the first) stands for in
## the view `choices` ([[choice_id, text], ...]), or NO_CHOICE.
static func choice_id_for_number(conversation_open: bool, choices: Array, number: int) -> String:
	if not conversation_open or number < 1 or number > choices.size():
		return NO_CHOICE
	var entry: Variant = choices[number - 1]
	if typeof(entry) != TYPE_ARRAY or (entry as Array).size() != ClientDialogueState.CHOICE_SIZE or typeof((entry as Array)[ClientDialogueState.CHOICE_ID]) != TYPE_STRING:
		return NO_CHOICE
	return (entry as Array)[ClientDialogueState.CHOICE_ID]
