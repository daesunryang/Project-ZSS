class_name NpcMemoryStore
extends NpcComponent
## Bounded memories of one NPC. Duplicate event ids merge into one record;
## at capacity the weakest importance candidate is forgotten, except records
## marked long_term, which are protected. There is no WorldEvent ledger yet.

const COMPONENT_ID: String = "memories"
const SCHEMA_VERSION: int = 1
const EVENT_KIND: String = "event"
const MEMORY_KIND: String = "memory"
const REASON_UNAVAILABLE: String = "memory_store_unavailable"
const REASON_BAD_MEMORY: String = "bad_memory"
const REASON_EVENT_CONFLICT: String = "memory_event_conflict"
const REASON_NOT_RETAINED: String = "memory_not_retained"
const REASON_CAPACITY_PROTECTED: String = "memory_capacity_protected"

const KEY_MEMORIES: String = "memories"

var _settings: NpcMindSettings
var _memories: Dictionary[String, NpcMemory] = {}
var _memory_id_by_event: Dictionary[String, String] = {}
var _world_ref: WeakRef = null
var _service_ref: WeakRef = null
var _npc_id: String = ""


func _init(settings: NpcMindSettings = null) -> void:
	_settings = settings if settings != null else NpcMindSettings.new()


static func create(settings: NpcMindSettings) -> NpcComponent:
	return NpcMemoryStore.new(settings)


func component_id() -> String:
	return COMPONENT_ID


func schema_version() -> int:
	return SCHEMA_VERSION


func on_created(_npc: NpcState, _definition: NpcDefinition, _clock: WorldClock) -> void:
	_memories.clear()
	_memory_id_by_event.clear()


func on_attached(world: ServerWorld, npc: NpcState) -> void:
	_world_ref = weakref(world)
	var service: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService
	_service_ref = weakref(service) if service != null else null
	_npc_id = npc.npc_id
	for memory_id: String in memory_ids():
		world.ids.reserve_existing_id(memory_id)
		world.ids.reserve_existing_id(_memories[memory_id].event_id)


func on_detached(_world: ServerWorld, _npc: NpcState, _retired: bool) -> void:
	_world_ref = null
	_service_ref = null
	_npc_id = ""


## Issues a stable `event_<number>` from the world's persisted id sequence.
## It identifies a future ledger event but creates no ledger row in Phase 4.
func issue_event_id() -> String:
	var world: ServerWorld = _world()
	if world == null:
		return ""
	var event_id: String = world.ids.next_id(EVENT_KIND)
	if not event_id.is_empty():
		# The shared id sequence is world save data too. A standalone issuance
		# must make a later save observe that it advanced.
		_mark_dirty()
	return event_id


## Records one observation. Empty `event_id` asks the world id issuer for
## one. A duplicate event id merges participants/tags and keeps the strongest
## importance, emotional intensity, strength, reliability and protection.
func record_memory(
	event_id: String,
	event_type: String,
	participants: Array[Dictionary],
	location: Vector3,
	event_world_time: float,
	observation: String,
	importance: float,
	emotional_intensity: float,
	interpretation_tags: PackedStringArray,
	strength: float = 1.0,
	long_term: bool = false,
	decay_half_life_world_sec: float = -1.0
) -> ActionResult:
	var world: ServerWorld = _world()
	if world == null:
		return ActionResult.failure(REASON_UNAVAILABLE)
	if not is_finite(event_world_time) or event_world_time < 0.0 or event_world_time > world.clock.world_time_sec:
		return ActionResult.failure(REASON_BAD_MEMORY)
	var resolved_half_life: float = decay_half_life_world_sec if decay_half_life_world_sec > 0.0 else _settings.memory_half_life_world_sec
	var resolved_event_id: String = event_id
	# Validate all caller data before spending an id.
	var draft: NpcMemory = _make_memory("memory_1", "event_1" if event_id.is_empty() else event_id, event_type, participants, location, event_world_time, observation, importance, emotional_intensity, interpretation_tags, strength, long_term, resolved_half_life, world.clock.world_time_sec)
	if not draft.validate().is_empty():
		return ActionResult.failure(REASON_BAD_MEMORY)
	if resolved_event_id.is_empty():
		resolved_event_id = issue_event_id()
		if resolved_event_id.is_empty():
			return ActionResult.failure(REASON_UNAVAILABLE)
	if _memory_id_by_event.has(resolved_event_id):
		return _merge_existing(resolved_event_id, draft, world.clock.world_time_sec)
	draft.event_id = resolved_event_id
	var evicted_id: String = _eviction_for(draft, world.clock.world_time_sec)
	if evicted_id == REASON_CAPACITY_PROTECTED or evicted_id == REASON_NOT_RETAINED:
		return ActionResult.failure(evicted_id)
	var memory_id: String = world.ids.next_id(MEMORY_KIND)
	if memory_id.is_empty():
		return ActionResult.failure(REASON_UNAVAILABLE)
	draft.memory_id = memory_id
	if not evicted_id.is_empty():
		var evicted_event_id: String = _memories[evicted_id].event_id
		_memories.erase(evicted_id)
		_memory_id_by_event.erase(evicted_event_id)
	_memories[memory_id] = draft
	_memory_id_by_event[resolved_event_id] = memory_id
	_mark_dirty()
	return ActionResult.success({"memory_id": memory_id, "event_id": resolved_event_id, "merged": false, "evicted_memory_id": evicted_id})


func count() -> int:
	return _memories.size()


func memory_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_memories.keys())
	ids.sort()
	return ids


## Defensive copy: saved fields can only change through this store.
func memory(memory_id: String) -> NpcMemory:
	var found: NpcMemory = _memories.get(memory_id, null)
	return found.copy() if found != null else null


func memory_for_event(event_id: String) -> NpcMemory:
	return memory(_memory_id_by_event.get(event_id, ""))


func strength_at(memory_id: String, world_time_sec: float) -> float:
	var found: NpcMemory = _memories.get(memory_id, null)
	return found.strength_at(world_time_sec) if found != null else 0.0


func to_document() -> Dictionary:
	var rows: Array[Dictionary] = []
	for memory_id: String in memory_ids():
		rows.append(_memories[memory_id].to_document())
	return {KEY_MEMORIES: rows}


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get(KEY_SCHEMA_VERSION, null)) or int(document[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("unsupported schema_version")
	var rows: Variant = document.get(KEY_MEMORIES, null)
	if typeof(rows) != TYPE_ARRAY:
		errors.append("memories must be an array")
		return errors
	if (rows as Array).size() > _settings.max_memories:
		errors.append("memory count exceeds max_memories")
	var restored: Dictionary[String, NpcMemory] = {}
	var events: Dictionary[String, String] = {}
	for row: Variant in (rows as Array):
		var restored_memory: NpcMemory = NpcMemory.from_document(row as Dictionary) if typeof(row) == TYPE_DICTIONARY else null
		if restored_memory == null:
			errors.append("invalid memory row")
			continue
		if restored.has(restored_memory.memory_id):
			errors.append("duplicate memory_id %s" % restored_memory.memory_id)
		if events.has(restored_memory.event_id):
			errors.append("duplicate event_id %s" % restored_memory.event_id)
		restored[restored_memory.memory_id] = restored_memory
		events[restored_memory.event_id] = restored_memory.memory_id
	if not errors.is_empty():
		return errors
	_memories = restored
	_memory_id_by_event = events
	return errors


func _merge_existing(event_id: String, draft: NpcMemory, now: float) -> ActionResult:
	var memory_id: String = _memory_id_by_event[event_id]
	var current: NpcMemory = _memories[memory_id]
	if current.event_type != draft.event_type or current.location != draft.location or current.event_world_time != draft.event_world_time:
		return ActionResult.failure(REASON_EVENT_CONFLICT)
	var merged: NpcMemory = current.copy()
	merged.participants = _merged_participants(current.participants, draft.participants)
	merged.interpretation_tags = _merged_tags(current.interpretation_tags, draft.interpretation_tags)
	merged.observation = _stronger_observation(current.observation, draft.observation)
	merged.importance = maxf(current.importance, draft.importance)
	merged.emotional_intensity = maxf(current.emotional_intensity, draft.emotional_intensity)
	merged.repetition_count += 1
	merged.strength = maxf(current.strength_at(now), draft.strength)
	merged.strength_stored_at = now
	merged.decay_half_life_world_sec = maxf(current.decay_half_life_world_sec, draft.decay_half_life_world_sec)
	merged.long_term = current.long_term or draft.long_term
	if not merged.validate().is_empty():
		return ActionResult.failure(REASON_BAD_MEMORY)
	_memories[memory_id] = merged
	_mark_dirty()
	return ActionResult.success({"memory_id": memory_id, "event_id": event_id, "merged": true, "evicted_memory_id": ""})


## Returns an existing id to evict, "" when there is room, or one of the
## failure reasons when the candidate cannot be retained.
func _eviction_for(candidate: NpcMemory, now: float) -> String:
	if _memories.size() < _settings.max_memories:
		return ""
	var weakest: NpcMemory = null
	for memory_id: String in memory_ids():
		var existing: NpcMemory = _memories[memory_id]
		if existing.long_term:
			continue
		if weakest == null or _weaker(existing, weakest, now):
			weakest = existing
	if weakest == null:
		return REASON_CAPACITY_PROTECTED
	if candidate.long_term:
		return weakest.memory_id
	if candidate.importance < weakest.importance:
		return REASON_NOT_RETAINED
	if candidate.importance == weakest.importance and candidate.strength <= weakest.strength_at(now):
		return REASON_NOT_RETAINED
	return weakest.memory_id


func _world() -> ServerWorld:
	return _world_ref.get_ref() as ServerWorld if _world_ref != null else null


func _mark_dirty() -> void:
	var service: NpcService = _service_ref.get_ref() as NpcService if _service_ref != null else null
	if service != null and not _npc_id.is_empty():
		service.mark_npc_dirty(_npc_id)


static func _make_memory(memory_id: String, event_id: String, event_type: String, participants: Array[Dictionary], location: Vector3, event_world_time: float, observation: String, importance: float, emotional_intensity: float, tags: PackedStringArray, strength: float, long_term: bool, half_life: float, stored_at: float) -> NpcMemory:
	var memory: NpcMemory = NpcMemory.new()
	memory.memory_id = memory_id
	memory.event_id = event_id
	memory.event_type = event_type
	for participant: Dictionary in participants:
		memory.participants.append(participant.duplicate())
	memory.location = location
	memory.event_world_time = event_world_time
	memory.observation = observation
	memory.importance = importance
	memory.emotional_intensity = emotional_intensity
	memory.interpretation_tags = tags.duplicate()
	memory.strength = strength
	memory.strength_stored_at = stored_at
	memory.decay_half_life_world_sec = half_life
	memory.long_term = long_term
	return memory


static func _weaker(first: NpcMemory, second: NpcMemory, now: float) -> bool:
	if first.importance != second.importance:
		return first.importance < second.importance
	var first_strength: float = first.strength_at(now)
	var second_strength: float = second.strength_at(now)
	if first_strength != second_strength:
		return first_strength < second_strength
	if first.event_world_time != second.event_world_time:
		return first.event_world_time < second.event_world_time
	return first.memory_id < second.memory_id


static func _merged_participants(first: Array[Dictionary], second: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen: Dictionary[String, bool] = {}
	for list: Array[Dictionary] in [first, second]:
		for participant: Dictionary in list:
			var key: String = "%s|%s" % [str(participant["entity_id"]), str(participant["role"])]
			if not seen.has(key):
				seen[key] = true
				result.append(participant.duplicate())
	return result


static func _merged_tags(first: PackedStringArray, second: PackedStringArray) -> PackedStringArray:
	var result: PackedStringArray = first.duplicate()
	for tag: String in second:
		if not result.has(tag):
			result.append(tag)
	result.sort()
	return result


static func _stronger_observation(first: String, second: String) -> String:
	var ranks: Dictionary[String, int] = {NpcMemory.OBSERVATION_REPORTED: 0, NpcMemory.OBSERVATION_WITNESSED: 1, NpcMemory.OBSERVATION_DIRECT: 2}
	return first if ranks[first] >= ranks[second] else second
