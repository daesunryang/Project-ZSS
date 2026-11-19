class_name NpcState
extends RefCounted
## Server-side state of one NPC (P4-1, docs/14 §2 "NPCState", docs/09
## §17.1). Plain data: who it is (`npc_id`, `definition_id`), where it stands,
## its own random generator, and the slots of its components (NpcComponent:
## needs, schedule, inventory, ... added by later tickets without changing
## this class). Other systems treat it as read-only; every change goes
## through NpcService. No Node or Resource references; saved with
## to_dict() / from_dict() in the document of the cell it stands in.
##
## Components and their documents: a live component (`component()`) is one
## whose type is registered with NpcService. The saved document of a
## component whose type is NOT registered in this build stays here untouched
## and is saved again as it was, so a save never loses data because a
## feature is missing.

const ENTITY_KIND: String = "npc"
const SCHEMA_VERSION: int = 1
const NPC_ID_PATTERN: String = "^npc_[0-9]+$"
## Largest world seed a save and a `.tres` carry exactly (2^53 - 1).
const MAX_WORLD_SEED: int = 9007199254740991
## Hex digits of the SHA-256 that become an NPC's seed (15 digits = 60 bits:
## it always fits a signed 64-bit integer as a positive number).
const SEED_HEX_DIGITS: int = 15

const KEY_SCHEMA_VERSION: String = "schema_version"
const KEY_NPC_ID: String = "npc_id"
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_POSITION: String = "position"
const KEY_YAW: String = "yaw"
const KEY_CREATED_AT: String = "created_at"
const KEY_LAST_SIMULATED: String = "last_simulated_world_time"
const KEY_RNG_SEED: String = "rng_seed"
const KEY_RNG_STATE: String = "rng_state"
const KEY_COMPONENTS: String = "components"

## Simulation tiers (docs/05 §11, docs/13 §16.3 D4). "frozen": the NPC's
## cell is not simulated, nothing about it changes. "near" / "far": it is
## simulated; which of the two is the scheduler's decision (P4-3, by the
## distance to the nearest player). Decided at run time, not saved.
const TIER_FROZEN: String = "frozen"
const TIER_NEAR: String = "near"
const TIER_FAR: String = "far"
const SIMULATED_TIERS: PackedStringArray = [TIER_NEAR, TIER_FAR]

## Stable id, unique in the world and never reused: `npc_<number>`.
var npc_id: String = ""
## NpcDefinition.definition_id.
var definition_id: String = ""
var position: Vector3 = Vector3.ZERO
## Facing around Y, radians (the players' and zombies' yaw convention).
var yaw: float = 0.0
## One of the TIER_ constants. NpcService sets it; see above.
var simulation_tier: String = TIER_FROZEN
## Calendar world time at which the NPC was created.
var created_at: float = 0.0
## Calendar world time until which this NPC was simulated: the moment its
## cell stopped being simulated. Kept for the summary catch-up of far NPCs
## (docs/16 K, a later ticket). While the NPC is awake this value is old;
## its save document carries the time of the save instead
## (NpcService.npc_document), because a restored NPC is frozen as of then.
var last_simulated_world_time: float = 0.0
## The NPC's own deterministic generator (docs/05 §16). Seed and state are
## saved, so a restored NPC goes on with the same numbers.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

## component_id -> live component.
var _components: Dictionary[String, NpcComponent] = {}
## component_id -> saved document of a component that has no live instance.
var _unclaimed_documents: Dictionary = {}


## The live component with this id, or null.
func component(component_id: String) -> NpcComponent:
	return _components.get(component_id, null)


## Ids of the live components, sorted.
func component_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_components.keys())
	ids.sort()
	return ids


## Gives the NPC a live component (NpcService only). An unclaimed document
## of the same id is dropped: the component speaks for that slot now.
func set_component(live: NpcComponent) -> void:
	_components[live.component_id()] = live
	_unclaimed_documents.erase(live.component_id())


## The saved document of a component that has no live instance ({} = none).
func unclaimed_document(component_id: String) -> Dictionary:
	return _unclaimed_documents.get(component_id, {})


## Ids of the saved documents without a live component, sorted.
func unclaimed_component_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for key: Variant in _unclaimed_documents:
		ids.append(str(key))
	ids.sort()
	return ids


## Save data: JSON-safe, component slots sorted by id. Each slot is the
## component's to_document() plus its "schema_version".
func to_dict() -> Dictionary:
	var slots: Dictionary = {}
	var slot_ids: PackedStringArray = component_ids()
	slot_ids.append_array(unclaimed_component_ids())
	slot_ids.sort()
	for slot_id: String in slot_ids:
		if _components.has(slot_id):
			var document: Dictionary = _components[slot_id].to_document().duplicate(true)
			document[NpcComponent.KEY_SCHEMA_VERSION] = _components[slot_id].schema_version()
			slots[slot_id] = document
		else:
			slots[slot_id] = (_unclaimed_documents[slot_id] as Dictionary).duplicate(true)
	return {
		KEY_SCHEMA_VERSION: SCHEMA_VERSION,
		KEY_NPC_ID: npc_id,
		KEY_DEFINITION_ID: definition_id,
		KEY_POSITION: [position.x, position.y, position.z],
		KEY_YAW: yaw,
		KEY_CREATED_AT: created_at,
		KEY_LAST_SIMULATED: last_simulated_world_time,
		# 64-bit values are stored as strings: JSON numbers would lose precision.
		KEY_RNG_SEED: str(rng.seed),
		KEY_RNG_STATE: str(rng.state),
		KEY_COMPONENTS: slots,
	}


## Builds a state from saved data. Returns null when the data is malformed
## (the shape only: whether the definition exists and the components accept
## their documents is checked by NpcService). Every component document is
## unclaimed at first; NpcService hands them to the registered components.
static func from_dict(data: Dictionary) -> NpcState:
	if not ItemInstance.is_integer_value(data.get(KEY_SCHEMA_VERSION, null)) or int(data[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		return null
	if typeof(data.get(KEY_NPC_ID, null)) != TYPE_STRING or not is_valid_npc_id(str(data[KEY_NPC_ID])):
		return null
	if typeof(data.get(KEY_DEFINITION_ID, null)) != TYPE_STRING or not ItemInstance.is_valid_definition_id(str(data[KEY_DEFINITION_ID])):
		return null
	var raw_position: Variant = data.get(KEY_POSITION, null)
	if typeof(raw_position) != TYPE_ARRAY or (raw_position as Array).size() != 3:
		return null
	for coordinate: Variant in (raw_position as Array):
		if not _is_finite_number(coordinate):
			return null
	for key: String in [KEY_YAW, KEY_CREATED_AT, KEY_LAST_SIMULATED]:
		if not _is_finite_number(data.get(key, null)):
			return null
	for key: String in [KEY_RNG_SEED, KEY_RNG_STATE]:
		if typeof(data.get(key, null)) != TYPE_STRING or not str(data[key]).is_valid_int():
			return null
	var slots: Variant = data.get(KEY_COMPONENTS, null)
	if typeof(slots) != TYPE_DICTIONARY:
		return null
	for slot_id: Variant in (slots as Dictionary):
		var document: Variant = (slots as Dictionary)[slot_id]
		if typeof(slot_id) != TYPE_STRING or not NpcComponent.is_valid_id(str(slot_id)) or typeof(document) != TYPE_DICTIONARY:
			return null
		var version: Variant = (document as Dictionary).get(NpcComponent.KEY_SCHEMA_VERSION, null)
		if not ItemInstance.is_integer_value(version) or int(version) < 1:
			return null
	var npc: NpcState = NpcState.new()
	npc.npc_id = str(data[KEY_NPC_ID])
	npc.definition_id = str(data[KEY_DEFINITION_ID])
	npc.position = Vector3(float(raw_position[0]), float(raw_position[1]), float(raw_position[2]))
	npc.yaw = float(data[KEY_YAW])
	npc.created_at = float(data[KEY_CREATED_AT])
	npc.last_simulated_world_time = float(data[KEY_LAST_SIMULATED])
	npc.rng.seed = str(data[KEY_RNG_SEED]).to_int()
	npc.rng.state = str(data[KEY_RNG_STATE]).to_int()
	for slot_id: Variant in (slots as Dictionary):
		npc._unclaimed_documents[str(slot_id)] = ((slots as Dictionary)[slot_id] as Dictionary).duplicate(true)
	return npc


static func is_valid_npc_id(value: String) -> bool:
	return RegEx.create_from_string(NPC_ID_PATTERN).search(value) != null


## The seed of one NPC's generator: a hash of the world's NPC seed and the
## NPC's id (docs/13 §16.1 "NPC 시드 = 월드 시드 + NPC ID"). It does not
## depend on the engine's random generator or on how GDScript hashes
## strings. The id is unique in its world, so two NPCs get different seeds.
static func seed_for(world_seed: int, id: String) -> int:
	return ("npc|%d|%s" % [world_seed, id]).sha256_text().substr(0, SEED_HEX_DIGITS).hex_to_int()


static func _is_finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value))
