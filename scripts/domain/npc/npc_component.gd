class_name NpcComponent
extends RefCounted
## One part of an NPC's state that is saved with the NPC (P4-1, docs/09
## §17.1 "구성 요소 계약"): its needs, its schedule, its inventory, its
## emotions, ... Later tickets add a component by adding a file that extends
## this class and one registration line in ServerComposition
## (NpcService.register_component); NpcState and NpcService stay as they
## are.
##
## Life of a component (one instance per NPC and component id):
##   1. the factory given to register_component() makes it;
##   2. on_created() for a brand-new NPC, and for an NPC that was saved
##      before this component existed; OR restore_document() with what
##      to_document() returned before (plus "schema_version");
##   3. on_attached() once the NPC is in memory (spawned, or its cell or
##      world document was restored);
##   4. on_detached() when the NPC leaves memory: its cell was saved and
##      released (`retired` false: it still exists and comes back through
##      2 and 3), or it was removed from the world for good (`retired` true).
##
## Rules:
##   - to_document() is JSON-safe (SaveService.is_json_safe): no Node,
##     Resource or RID, 64-bit numbers as strings. NpcService adds
##     "schema_version" (schema_version()) to it; do not use that key.
##   - restore_document() validates first and changes nothing but this
##     component: it runs before the NPC is in memory, and when it (or any
##     other part of the same document) reports an error, the NPC and
##     everything else of that document are not loaded.
##   - Whatever reaches outside the component (a detached inventory, a
##     reservation) is taken in on_attached() and given back in
##     on_detached().
##   - After changing what to_document() returns, tell
##     NpcService.mark_npc_dirty(npc_id): a missed call could lose the
##     change in a crash (the cell document is cached between saves).
##   - Random numbers come from the NPC's own generator (NpcState.rng),
##     never from the engine's global one.

const KEY_SCHEMA_VERSION: String = "schema_version"
const ID_PATTERN: String = "^[a-z][a-z0-9_]*$"
const ID_MAX_LENGTH: int = 64


## Stable snake_case id; also the key of this component's slot in the NPC's
## save document. Must be overridden.
func component_id() -> String:
	return ""


## Version of what to_document() returns (>= 1). restore_document() gets the
## saved version and migrates older documents itself.
func schema_version() -> int:
	return 1


## Fresh values for an NPC that has no saved document of this component.
## `clock` gives both time axes (docs/09 §14.16).
func on_created(_npc: NpcState, _definition: NpcDefinition, _clock: WorldClock) -> void:
	return


## The NPC is in memory now.
func on_attached(_world: ServerWorld, _npc: NpcState) -> void:
	return


## The NPC leaves memory. `retired` true = it was removed from the world.
func on_detached(_world: ServerWorld, _npc: NpcState, _retired: bool) -> void:
	return


## Save data of this component ({} = nothing but the version).
func to_document() -> Dictionary:
	return {}


## Restores what to_document() returned; `document` also has
## "schema_version". Returns errors (non-empty = the NPC is not loaded).
func restore_document(_document: Dictionary) -> PackedStringArray:
	return PackedStringArray()


static func is_valid_id(id: String) -> bool:
	return id.length() <= ID_MAX_LENGTH and RegEx.create_from_string(ID_PATTERN).search(id) != null
