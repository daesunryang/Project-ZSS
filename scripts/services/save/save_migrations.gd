class_name SaveMigrations
extends RefCounted
## Production migration chains for saved documents (docs/10 §6).
## SaveService uses defaults() when no migrator is injected.
##
## world_state  v1 -> v2 (Phase 2 P2-0): adds "world_time_sec" and "systems".
## player       v1 -> v2 (Phase 2 P2-0): adds "systems" (per-system fragments).

const WORLD_SCHEMA_VERSION: int = 2
const PLAYER_SCHEMA_VERSION: int = 2


static func defaults() -> Dictionary[String, SaveMigrator]:
	var world_steps: Dictionary[int, Callable] = {1: func(doc: Dictionary) -> Dictionary: return world_v1_to_v2(doc)}
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


static func player_v1_to_v2(document: Dictionary) -> Dictionary:
	var result: Dictionary = document.duplicate(true)
	if not result.has("systems"):
		result["systems"] = {}
	result["schema_version"] = 2
	return result
