class_name RelationshipStore
extends NpcComponent
## Directional relationship records owned by one NPC. The target may be an
## NPC or player id. This component stores exactly the explicit status and
## scores it receives; Phase 5 defines changes and status transitions.

const COMPONENT_ID: String = "relationships"
const SCHEMA_VERSION: int = 1
const REASON_UNAVAILABLE: String = "relationship_store_unavailable"
const REASON_BAD_RELATIONSHIP: String = "bad_relationship"
const REASON_WRONG_SOURCE: String = "relationship_wrong_source"
const KEY_OWNER: String = "owner_npc_id"
const KEY_RELATIONSHIPS: String = "relationships"

var _owner_npc_id: String = ""
var _relationships: Dictionary[String, RelationshipState] = {}
var _service_ref: WeakRef = null


static func create() -> NpcComponent:
	return RelationshipStore.new()


func component_id() -> String:
	return COMPONENT_ID


func schema_version() -> int:
	return SCHEMA_VERSION


func on_created(npc: NpcState, _definition: NpcDefinition, _clock: WorldClock) -> void:
	_owner_npc_id = npc.npc_id
	_relationships.clear()


func on_attached(world: ServerWorld, npc: NpcState) -> void:
	var repaired: bool = false
	if _owner_npc_id.is_empty():
		_owner_npc_id = npc.npc_id
	elif _owner_npc_id != npc.npc_id:
		GameLogger.warning("npc", "relationship component owner repaired from its containing NPC", {"entity_id": npc.npc_id, "saved_owner": _owner_npc_id, "operation": "attach_relationships"})
		_owner_npc_id = npc.npc_id
		for target_entity_id: String in _relationships:
			_relationships[target_entity_id].source_entity_id = npc.npc_id
		repaired = true
	var service: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService
	_service_ref = weakref(service) if service != null else null
	if repaired:
		_mark_dirty()


func on_detached(_world: ServerWorld, _npc: NpcState, _retired: bool) -> void:
	_service_ref = null


## Inserts or replaces one source->target record. No score-to-status rule is
## run here: `status` is saved exactly as supplied.
func put_relationship(state: RelationshipState) -> ActionResult:
	if _owner_npc_id.is_empty():
		return ActionResult.failure(REASON_UNAVAILABLE)
	if state == null:
		return ActionResult.failure(REASON_BAD_RELATIONSHIP)
	if state.source_entity_id != _owner_npc_id:
		return ActionResult.failure(REASON_WRONG_SOURCE)
	if not state.validate().is_empty():
		return ActionResult.failure(REASON_BAD_RELATIONSHIP)
	_relationships[state.target_entity_id] = state.copy()
	_mark_dirty()
	return ActionResult.success({"source_entity_id": state.source_entity_id, "target_entity_id": state.target_entity_id, "status": state.status})


func remove_relationship(target_entity_id: String) -> ActionResult:
	if not _relationships.has(target_entity_id):
		return ActionResult.failure(REASON_BAD_RELATIONSHIP)
	_relationships.erase(target_entity_id)
	_mark_dirty()
	return ActionResult.success({"source_entity_id": _owner_npc_id, "target_entity_id": target_entity_id})


## Defensive copy: callers cannot bypass dirty marking.
func relationship(target_entity_id: String) -> RelationshipState:
	var state: RelationshipState = _relationships.get(target_entity_id, null)
	return state.copy() if state != null else null


func relationship_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_relationships.keys())
	ids.sort()
	return ids


func to_document() -> Dictionary:
	var rows: Array[Dictionary] = []
	for target_entity_id: String in relationship_ids():
		rows.append(_relationships[target_entity_id].to_document())
	return {KEY_OWNER: _owner_npc_id, KEY_RELATIONSHIPS: rows}


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get(KEY_SCHEMA_VERSION, null)) or int(document[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("unsupported schema_version")
	var owner: Variant = document.get(KEY_OWNER, null)
	if typeof(owner) != TYPE_STRING or not NpcState.is_valid_npc_id(str(owner)):
		errors.append("owner_npc_id must be an NPC id")
	var rows: Variant = document.get(KEY_RELATIONSHIPS, null)
	if typeof(rows) != TYPE_ARRAY:
		errors.append("relationships must be an array")
		return errors
	var restored: Dictionary[String, RelationshipState] = {}
	for row: Variant in (rows as Array):
		var state: RelationshipState = RelationshipState.from_document(row as Dictionary) if typeof(row) == TYPE_DICTIONARY else null
		if state == null:
			errors.append("invalid relationship row")
			continue
		if typeof(owner) == TYPE_STRING and state.source_entity_id != str(owner):
			errors.append("relationship source does not match owner")
		if restored.has(state.target_entity_id):
			errors.append("duplicate relationship target %s" % state.target_entity_id)
		restored[state.target_entity_id] = state
	if not errors.is_empty():
		return errors
	_owner_npc_id = str(owner)
	_relationships = restored
	return errors


func _mark_dirty() -> void:
	var service: NpcService = _service_ref.get_ref() as NpcService if _service_ref != null else null
	if service != null and not _owner_npc_id.is_empty():
		service.mark_npc_dirty(_owner_npc_id)
