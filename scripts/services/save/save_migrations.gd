class_name SaveMigrations
extends RefCounted
## Production migration chains for saved documents (docs/10 §6).
## SaveService uses defaults() when no migrator is injected.
##
## world_state  v1 -> v2 (Phase 2 P2-0): adds "world_time_sec" and "systems".
## world_state  v2 -> v3 (P2-T1): adds "action_time_sec" (WorldClock action
##              time, docs/09 §14.16).
## player       v1 -> v2 (Phase 2 P2-0): adds "systems" (per-system fragments).

const WORLD_SCHEMA_VERSION: int = 3
const PLAYER_SCHEMA_VERSION: int = 2
## Same keys as ServerWorld.KEY_WORLD_TIME / KEY_ACTION_TIME.
const KEY_WORLD_TIME: String = "world_time_sec"
const KEY_ACTION_TIME: String = "action_time_sec"


static func defaults() -> Dictionary[String, SaveMigrator]:
	var world_steps: Dictionary[int, Callable] = {
		1: func(doc: Dictionary) -> Dictionary: return world_v1_to_v2(doc),
		2: func(doc: Dictionary) -> Dictionary: return world_v2_to_v3(doc),
	}
	var player_steps: Dictionary[int, Callable] = {1: func(doc: Dictionary) -> Dictionary: return player_v1_to_v2(doc)}
	var migrators: Dictionary[String, SaveMigrator] = {
		SaveService.CATEGORY_WORLD: SaveMigrator.new(WORLD_SCHEMA_VERSION, world_steps),
		SaveService.CATEGORY_PLAYER: SaveMigrator.new(PLAYER_SCHEMA_VERSION, player_steps),
	}
	return migrators


static func world_v1_to_v2(document: Dictionary) -> Dictionary:
	var result: Dictionary = document.duplicate(true)
	if not result.has("world_time_sec"):
		result["world_time_sec"] = 0.0
	if not result.has("systems"):
		result["systems"] = {}
	result["schema_version"] = 2
	return result


## Worlds saved before P2-T1 had one clock running in real time (scale 1),
## and every saved deadline (zombie attack/search/wander times, ...) was
## written in it. Starting the action clock at the saved world time keeps
## those deadlines valid (docs/15 P2-102).
static func world_v2_to_v3(document: Dictionary) -> Dictionary:
	var result: Dictionary = document.duplicate(true)
	if not result.has(KEY_ACTION_TIME):
		var world_time: Variant = result.get(KEY_WORLD_TIME, 0.0)
		var is_number: bool = typeof(world_time) == TYPE_FLOAT or typeof(world_time) == TYPE_INT
		result[KEY_ACTION_TIME] = float(world_time) if is_number else 0.0
	result["schema_version"] = 3
	return result


static func player_v1_to_v2(document: Dictionary) -> Dictionary:
	var result: Dictionary = document.duplicate(true)
	if not result.has("systems"):
		result["systems"] = {}
	result["schema_version"] = 2
	return result
