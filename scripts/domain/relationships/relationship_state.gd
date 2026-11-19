class_name RelationshipState
extends RefCounted
## One directional evaluation (source -> target), docs/14 §3. A record is
## owned by the source NPC's RelationshipStore. All axes are independent,
## normalized data; no score changes `status` automatically in P4.

const AXES: PackedStringArray = ["trust", "liking", "respect", "fear", "resentment", "attraction", "jealousy", "dependence"]
const PLAYER_ID_PATTERN: String = "^player_[0-9]+$"

var source_entity_id: String = ""
var target_entity_id: String = ""
var trust: float = 0.0
var liking: float = 0.0
var respect: float = 0.0
var fear: float = 0.0
var resentment: float = 0.0
var attraction: float = 0.0
var jealousy: float = 0.0
var dependence: float = 0.0
var status: String = ""
var last_interaction_time: float = 0.0


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not NpcState.is_valid_npc_id(source_entity_id):
		errors.append("source_entity_id must be an NPC id")
	if not is_valid_target_id(target_entity_id) or target_entity_id == source_entity_id:
		errors.append("target_entity_id must be another NPC or player id")
	for axis: String in AXES:
		var value: float = float(get(axis))
		if not is_finite(value) or value < 0.0 or value > 1.0:
			errors.append("%s must be within 0..1" % axis)
	if not status.is_empty() and not ItemInstance.is_valid_definition_id(status):
		errors.append("status must be snake_case or empty")
	if not is_finite(last_interaction_time) or last_interaction_time < 0.0:
		errors.append("last_interaction_time must be finite and >= 0")
	return errors


func to_document() -> Dictionary:
	var document: Dictionary = {
		"source_entity_id": source_entity_id,
		"target_entity_id": target_entity_id,
		"status": status,
		"last_interaction_time": last_interaction_time,
	}
	for axis: String in AXES:
		document[axis] = float(get(axis))
	return document


func copy() -> RelationshipState:
	return from_document(to_document())


static func from_document(document: Dictionary) -> RelationshipState:
	for key: String in ["source_entity_id", "target_entity_id", "status"]:
		if typeof(document.get(key, null)) != TYPE_STRING:
			return null
	for key: String in AXES + PackedStringArray(["last_interaction_time"]):
		var value: Variant = document.get(key, null)
		if (typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT) or not is_finite(float(value)):
			return null
	var state: RelationshipState = RelationshipState.new()
	state.source_entity_id = str(document["source_entity_id"])
	state.target_entity_id = str(document["target_entity_id"])
	for axis: String in AXES:
		state.set(axis, float(document[axis]))
	state.status = str(document["status"])
	state.last_interaction_time = float(document["last_interaction_time"])
	return state if state.validate().is_empty() else null


static func is_valid_target_id(value: String) -> bool:
	return NpcState.is_valid_npc_id(value) or RegEx.create_from_string(PLAYER_ID_PATTERN).search(value) != null
