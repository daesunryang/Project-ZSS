class_name NpcDebugQuery
extends RefCounted
## Read-only, server-side view of one in-memory NPC (P4-8). It owns no NPC
## state and never advances needs, decisions, schedules or execution. The
## composition attaches one instance to ServerWorld metadata so the network
## module can find the exact scheduler/executor instances without changing
## the existing NPC contracts.

const WORLD_META: StringName = &"npc_debug_query"
const SCHEMA_VERSION: int = 1

var inspect_count: int = 0

var _world_ref: WeakRef
var _npcs: NpcService
var _scheduler: NpcScheduler
var _executor: NpcExecutor
var _settings: NpcDebugSettings


func _init(world: ServerWorld, npcs: NpcService, scheduler: NpcScheduler, executor: NpcExecutor, settings: NpcDebugSettings) -> void:
	_world_ref = weakref(world) if world != null else null
	_npcs = npcs
	_scheduler = scheduler
	_executor = executor
	_settings = settings if settings != null else NpcDebugSettings.new()


static func attach(world: ServerWorld, query: NpcDebugQuery) -> void:
	if world != null:
		world.set_meta(WORLD_META, query)


static func from_world(world: ServerWorld) -> NpcDebugQuery:
	# has_meta first: Godot 4 prints an engine error for get_meta(name, null)
	# when the key is missing (a world built without the debug query).
	if world == null or not world.has_meta(WORLD_META):
		return null
	return world.get_meta(WORLD_META) as NpcDebugQuery


## Returns a wire/JSON-safe snapshot. {found:false,npc_id} is explicit for an
## NPC that is not in memory. Callers enforce authorization and interest
## before invoking this method.
func inspect_npc(npc_id: String) -> Dictionary:
	inspect_count += 1
	var npc: NpcState = _npcs.get_npc(npc_id) if _npcs != null else null
	if npc == null:
		return {"schema_version": SCHEMA_VERSION, "found": false, "npc_id": npc_id}
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	var definition: NpcDefinition = _npcs.definition_of(npc_id)
	var decision: NpcDecisionComponent = npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent
	var record: Dictionary = decision.last_record().duplicate(true) if decision != null else {}
	var action: Dictionary = _executor.action_info(npc_id) if _executor != null else _action_from_component(npc)
	var outcome: Dictionary = _executor.last_outcome(npc_id) if _executor != null else _outcome_from_component(npc)
	var failure: Dictionary = decision.last_failure.duplicate() if decision != null else {}
	if failure.is_empty() and not outcome.is_empty() and not str(outcome.get("result", "")).is_empty():
		failure = outcome.duplicate()
	var candidates: Array = []
	var raw_candidates: Variant = record.get(NpcUtilityDecider.KEY_CANDIDATES, [])
	if typeof(raw_candidates) == TYPE_ARRAY:
		for index: int in range(mini((raw_candidates as Array).size(), _settings.top_candidate_count)):
			candidates.append(_safe((raw_candidates as Array)[index]))
	var waypoints: Array = _safe(action.get(NpcExecutor.INFO_WAYPOINTS, [])) as Array
	var destination: Variant = _safe(action.get(NpcExecutor.INFO_TARGET, []))
	var last_record_at: int = int(record.get(NpcUtilityDecider.KEY_AT_USEC, -1))
	var result: Dictionary = {
		"schema_version": SCHEMA_VERSION,
		"found": true,
		"npc_id": npc.npc_id,
		"name": definition.display_name if definition != null else npc.definition_id,
		"definition_id": npc.definition_id,
		"position": _point(npc.position),
		"state": decision.state if decision != null else str(action.get(NpcExecutor.INFO_PHASE, "idle")),
		"goal": decision.action_id if decision != null else "",
		"current_action": NpcDecisionComponent.label_of(npc),
		"action": _safe(action),
		"candidates": candidates,
		"decision_record": _safe(record),
		"needs": _needs(npc),
		"emotions": _emotions(npc, world.clock.world_time_sec if world != null else 0.0),
		"relationships": _relationships(npc),
		"memories": _memories(npc, world.clock.world_time_sec if world != null else 0.0),
		"failure": _safe(failure),
		"executor_outcome": _safe(outcome),
		"path": waypoints,
		"destination": destination,
		"lod": npc.simulation_tier,
		"schedule": _safe(_scheduler.schedule_info(npc_id) if _scheduler != null else {}),
		"scheduler_diagnostics": _safe(_scheduler.diagnostics() if _scheduler != null else {}),
		"executor_diagnostics": _safe(_executor.diagnostics() if _executor != null else {}),
		"seed": {
			"rng_seed": str(npc.rng.seed),
			"rng_state": str(npc.rng.state),
			"decision_sequence": decision.decision_count if decision != null else 0,
			"replay_id": "%s:%s:%d:%d" % [npc.npc_id, str(npc.rng.seed), decision.decision_count if decision != null else 0, last_record_at],
		},
	}
	return result


## Human-readable, multi-line form used by headless tests and soak logs.
func dump_npc(npc_id: String) -> String:
	return format_dump(inspect_npc(npc_id))


static func format_dump(snapshot: Dictionary) -> String:
	var id: String = str(snapshot.get("npc_id", ""))
	if not bool(snapshot.get("found", false)):
		return "NPC 디버그: %s\n없음" % id
	var needs: PackedStringArray = []
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		var row: Dictionary = (snapshot.get("needs", {}) as Dictionary).get(kind, {})
		needs.append("%s=%.2f(%s)" % [kind, float(row.get("value", 0.0)), str(row.get("category", ""))])
	var candidates: PackedStringArray = []
	for candidate: Variant in snapshot.get("candidates", []):
		if typeof(candidate) == TYPE_DICTIONARY:
			var candidate_row: Dictionary = candidate
			var term_parts: PackedStringArray = []
			var terms: Dictionary = candidate_row.get("terms", {})
			var term_ids: PackedStringArray = PackedStringArray(terms.keys())
			term_ids.sort()
			for term_id: String in term_ids:
				term_parts.append("%s=%.3f" % [term_id, float(terms[term_id])])
			candidates.append("%s %.3f%s" % [str(candidate_row.get("action_id", "")), float(candidate_row.get("score", 0.0)), " [%s]" % ", ".join(term_parts) if not term_parts.is_empty() else ""])
	var emotion_parts: PackedStringArray = []
	var emotions: Dictionary = snapshot.get("emotions", {})
	var emotion_ids: PackedStringArray = PackedStringArray(emotions.keys())
	emotion_ids.sort()
	for emotion_id: String in emotion_ids:
		emotion_parts.append("%s=%.2f" % [emotion_id, float(emotions[emotion_id])])
	var relationship_parts: PackedStringArray = []
	for relationship_value: Variant in snapshot.get("relationships", []):
		if typeof(relationship_value) != TYPE_DICTIONARY:
			continue
		var relationship: Dictionary = relationship_value
		var axis_parts: PackedStringArray = []
		for axis: String in RelationshipState.AXES:
			axis_parts.append("%s=%.2f" % [axis, float(relationship.get(axis, 0.0))])
		relationship_parts.append("%s(%s) %s" % [str(relationship.get("target_entity_id", "")), str(relationship.get("status", "")), ", ".join(axis_parts)])
	var memory_parts: PackedStringArray = []
	for memory_value: Variant in snapshot.get("memories", []):
		if typeof(memory_value) != TYPE_DICTIONARY:
			continue
		var memory: Dictionary = memory_value
		memory_parts.append("%s:%s strength=%.2f %s" % [str(memory.get("memory_id", "")), str(memory.get("event_type", "")), float(memory.get("current_strength", 0.0)), str(memory.get("observation", ""))])
	var failure: Dictionary = snapshot.get("failure", {})
	return "\n".join(PackedStringArray([
		"NPC 디버그: %s (%s)" % [str(snapshot.get("name", id)), id],
		"상태: %s | 목표: %s | 행동: %s" % [str(snapshot.get("state", "")), str(snapshot.get("goal", "")), str(snapshot.get("current_action", ""))],
		"LOD: %s | 위치: %s" % [str(snapshot.get("lod", "")), str(snapshot.get("position", []))],
		"후보: %s" % (", ".join(candidates) if not candidates.is_empty() else "없음"),
		"욕구: %s" % ", ".join(needs),
		"감정: %s" % (", ".join(emotion_parts) if not emotion_parts.is_empty() else "없음"),
		"관계: %s" % (" | ".join(relationship_parts) if not relationship_parts.is_empty() else "없음"),
		"기억: %s" % (" | ".join(memory_parts) if not memory_parts.is_empty() else "없음"),
		"실패: %s" % (str(failure.get("code", failure.get("result", "없음"))) if not failure.is_empty() else "없음"),
		"경로: %d waypoint | 목적지: %s" % [(snapshot.get("path", []) as Array).size(), str(snapshot.get("destination", []))],
		"스케줄: %s" % str(snapshot.get("schedule", {})),
		"seed: %s" % str(snapshot.get("seed", {})),
	]))


func _needs(npc: NpcState) -> Dictionary:
	var component: NpcNeeds = npc.component(NpcNeeds.COMPONENT_ID) as NpcNeeds
	var values: Dictionary = {}
	if component == null:
		return values
	for kind: String in NpcNeedKind.DEFINED_KINDS:
		values[kind] = {"value": component.value(kind), "category": NpcNeedKind.category_name(component.category(kind)), "simulated": component.is_simulated(kind)}
	values["activity"] = component.activity()
	return values


func _emotions(npc: NpcState, world_time: float) -> Dictionary:
	var component: NpcEmotions = npc.component(NpcEmotions.COMPONENT_ID) as NpcEmotions
	return component.emotion_values_at(world_time) if component != null else {}


func _relationships(npc: NpcState) -> Array:
	var component: RelationshipStore = npc.component(RelationshipStore.COMPONENT_ID) as RelationshipStore
	var rows: Array = []
	if component == null:
		return rows
	for target_id: String in component.relationship_ids():
		var relation: RelationshipState = component.relationship(target_id)
		if relation != null:
			rows.append(relation.to_document())
	return rows


func _memories(npc: NpcState, world_time: float) -> Array:
	var component: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	var rows: Array[Dictionary] = []
	if component == null:
		return rows
	for memory_id: String in component.memory_ids():
		var memory: NpcMemory = component.memory(memory_id)
		if memory == null:
			continue
		var row: Dictionary = memory.to_document()
		row["current_strength"] = memory.strength_at(world_time)
		rows.append(row)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var at: float = float(a.get("event_world_time", 0.0))
		var bt: float = float(b.get("event_world_time", 0.0))
		return at > bt or (at == bt and str(a.get("memory_id", "")) > str(b.get("memory_id", ""))))
	return rows.slice(0, mini(rows.size(), _settings.recent_memory_count))


func _action_from_component(npc: NpcState) -> Dictionary:
	var state: NpcExecutorState = npc.component(NpcExecutorState.COMPONENT_ID) as NpcExecutorState
	if state == null:
		return {}
	return {NpcExecutor.INFO_PHASE: state.phase, NpcExecutor.INFO_KIND: state.kind, NpcExecutor.INFO_TARGET: state.target, NpcExecutor.INFO_SPOT: state.spot_id, NpcExecutor.INFO_WAYPOINTS: state.remaining_waypoints(), NpcExecutor.INFO_RESERVED_SPOT: state.reserved_spot_id}


func _outcome_from_component(npc: NpcState) -> Dictionary:
	var state: NpcExecutorState = npc.component(NpcExecutorState.COMPONENT_ID) as NpcExecutorState
	return {NpcExecutor.OUTCOME_RESULT: state.last_result, NpcExecutor.OUTCOME_CODE: state.last_code} if state != null else {}


static func _point(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]


## Copies values into a transport-safe shape and converts engine vectors to
## number arrays. No source Dictionary or Array is returned by reference.
static func _safe(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2:
			var v2: Vector2 = value
			return [v2.x, v2.y]
		TYPE_VECTOR2I:
			var v2i: Vector2i = value
			return [v2i.x, v2i.y]
		TYPE_VECTOR3:
			return _point(value as Vector3)
		TYPE_VECTOR3I:
			var v3i: Vector3i = value
			return [v3i.x, v3i.y, v3i.z]
		TYPE_DICTIONARY:
			var copied: Dictionary = {}
			for key: Variant in (value as Dictionary):
				copied[str(key)] = _safe((value as Dictionary)[key])
			return copied
		TYPE_ARRAY:
			var copied_array: Array = []
			for item: Variant in value as Array:
				copied_array.append(_safe(item))
			return copied_array
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY:
			return _safe(Array(value))
		_:
			return value
