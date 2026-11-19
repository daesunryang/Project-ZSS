class_name NpcMemory
extends RefCounted
## One NPC's interpretation of one event (docs/05 §6). This is plain saved
## data; NpcMemoryStore owns ids, merging and capacity.

const OBSERVATION_DIRECT: String = "direct"
const OBSERVATION_WITNESSED: String = "witnessed"
const OBSERVATION_REPORTED: String = "reported"
const OBSERVATIONS: PackedStringArray = [OBSERVATION_DIRECT, OBSERVATION_WITNESSED, OBSERVATION_REPORTED]
const ROLES: PackedStringArray = ["actor", "target", "witness", "helper"]
const MAX_PARTICIPANTS: int = 32
const MAX_INTERPRETATION_TAGS: int = 32
const MEMORY_ID_PATTERN: String = "^memory_[0-9]+$"
const EVENT_ID_PATTERN: String = "^event_[0-9]+$"
const PLAYER_ID_PATTERN: String = "^player_[0-9]+$"

var memory_id: String = ""
var event_id: String = ""
var event_type: String = ""
## Rows: {entity_id, role}. One entity may have more than one role.
var participants: Array[Dictionary] = []
var location: Vector3 = Vector3.ZERO
var event_world_time: float = 0.0
var observation: String = OBSERVATION_DIRECT
var importance: float = 0.0
var emotional_intensity: float = 0.0
var repetition_count: int = 1
var interpretation_tags: PackedStringArray = []
var strength: float = 1.0
var strength_stored_at: float = 0.0
var decay_half_life_world_sec: float = 1.0
## Protected from importance-based capacity eviction. Strength still decays.
var long_term: bool = false


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_valid_memory_id(memory_id):
		errors.append("invalid memory_id")
	if not is_valid_event_id(event_id):
		errors.append("invalid event_id")
	if not ItemInstance.is_valid_definition_id(event_type):
		errors.append("event_type must be snake_case")
	if participants.is_empty() or participants.size() > MAX_PARTICIPANTS:
		errors.append("participants must have 1..%d rows" % MAX_PARTICIPANTS)
	var seen_participants: Dictionary[String, bool] = {}
	for participant: Dictionary in participants:
		var entity_id: Variant = participant.get("entity_id", null)
		var role: Variant = participant.get("role", null)
		if typeof(entity_id) != TYPE_STRING or not is_valid_participant_id(str(entity_id)) or typeof(role) != TYPE_STRING or not ROLES.has(str(role)):
			errors.append("invalid participant")
			continue
		var key: String = "%s|%s" % [str(entity_id), str(role)]
		if seen_participants.has(key):
			errors.append("duplicate participant role")
		seen_participants[key] = true
	if not location.is_finite():
		errors.append("location must be finite")
	if not is_finite(event_world_time) or event_world_time < 0.0:
		errors.append("event_world_time must be finite and >= 0")
	if not OBSERVATIONS.has(observation):
		errors.append("unknown observation")
	for row: Array in [["importance", importance], ["emotional_intensity", emotional_intensity], ["strength", strength]]:
		if not _is_unit(float(row[1])):
			errors.append("%s must be within 0..1" % str(row[0]))
	if repetition_count < 1:
		errors.append("repetition_count must be >= 1")
	if interpretation_tags.size() > MAX_INTERPRETATION_TAGS:
		errors.append("too many interpretation_tags")
	var seen_tags: Dictionary[String, bool] = {}
	for tag: String in interpretation_tags:
		if not ItemInstance.is_valid_definition_id(tag) or seen_tags.has(tag):
			errors.append("interpretation_tags must be different snake_case labels")
		seen_tags[tag] = true
	if not is_finite(strength_stored_at) or strength_stored_at < 0.0:
		errors.append("strength_stored_at must be finite and >= 0")
	if not is_finite(decay_half_life_world_sec) or decay_half_life_world_sec <= 0.0:
		errors.append("decay_half_life_world_sec must be finite and > 0")
	return errors


func strength_at(world_time_sec: float) -> float:
	if not is_finite(world_time_sec) or world_time_sec < strength_stored_at:
		return strength
	return strength * pow(0.5, (world_time_sec - strength_stored_at) / decay_half_life_world_sec)


func to_document() -> Dictionary:
	var participant_rows: Array[Dictionary] = []
	for participant: Dictionary in participants:
		participant_rows.append(participant.duplicate())
	return {
		"memory_id": memory_id,
		"event_id": event_id,
		"event_type": event_type,
		"participants": participant_rows,
		"location": [location.x, location.y, location.z],
		"event_world_time": event_world_time,
		"observation": observation,
		"importance": importance,
		"emotional_intensity": emotional_intensity,
		"repetition_count": repetition_count,
		"interpretation_tags": Array(interpretation_tags),
		"strength": strength,
		"strength_stored_at": strength_stored_at,
		"decay_half_life_world_sec": decay_half_life_world_sec,
		"long_term": long_term,
	}


func copy() -> NpcMemory:
	return from_document(to_document())


static func from_document(document: Dictionary) -> NpcMemory:
	var raw_participants: Variant = document.get("participants", null)
	var raw_location: Variant = document.get("location", null)
	var raw_tags: Variant = document.get("interpretation_tags", null)
	if typeof(raw_participants) != TYPE_ARRAY or typeof(raw_location) != TYPE_ARRAY or (raw_location as Array).size() != 3 or typeof(raw_tags) != TYPE_ARRAY:
		return null
	for coordinate: Variant in (raw_location as Array):
		if not _is_number(coordinate):
			return null
	for key: String in ["memory_id", "event_id", "event_type", "observation"]:
		if typeof(document.get(key, null)) != TYPE_STRING:
			return null
	for key: String in ["event_world_time", "importance", "emotional_intensity", "strength", "strength_stored_at", "decay_half_life_world_sec"]:
		if not _is_number(document.get(key, null)):
			return null
	if not ItemInstance.is_integer_value(document.get("repetition_count", null)) or typeof(document.get("long_term", null)) != TYPE_BOOL:
		return null
	var memory: NpcMemory = NpcMemory.new()
	memory.memory_id = str(document["memory_id"])
	memory.event_id = str(document["event_id"])
	memory.event_type = str(document["event_type"])
	for row: Variant in (raw_participants as Array):
		if typeof(row) != TYPE_DICTIONARY:
			return null
		memory.participants.append((row as Dictionary).duplicate())
	memory.location = Vector3(float(raw_location[0]), float(raw_location[1]), float(raw_location[2]))
	memory.event_world_time = float(document["event_world_time"])
	memory.observation = str(document["observation"])
	memory.importance = float(document["importance"])
	memory.emotional_intensity = float(document["emotional_intensity"])
	memory.repetition_count = int(document["repetition_count"])
	for tag: Variant in (raw_tags as Array):
		if typeof(tag) != TYPE_STRING:
			return null
		memory.interpretation_tags.append(str(tag))
	memory.strength = float(document["strength"])
	memory.strength_stored_at = float(document["strength_stored_at"])
	memory.decay_half_life_world_sec = float(document["decay_half_life_world_sec"])
	memory.long_term = bool(document["long_term"])
	return memory if memory.validate().is_empty() else null


static func is_valid_memory_id(value: String) -> bool:
	return RegEx.create_from_string(MEMORY_ID_PATTERN).search(value) != null


static func is_valid_event_id(value: String) -> bool:
	return RegEx.create_from_string(EVENT_ID_PATTERN).search(value) != null


static func is_valid_participant_id(value: String) -> bool:
	return NpcState.is_valid_npc_id(value) or RegEx.create_from_string(PLAYER_ID_PATTERN).search(value) != null


static func _is_unit(value: float) -> bool:
	return is_finite(value) and value >= 0.0 and value <= 1.0


static func _is_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value))
