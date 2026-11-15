class_name SaveMigrations
extends RefCounted
## Production migration chains for saved documents (docs/10 §6).
## SaveService uses defaults() when no migrator is injected.
##
## world_state  v1 -> v2 (Phase 2 P2-0): adds "world_time_sec" and "systems".
## world_state  v2 -> v3 (P2-T1): adds "action_time_sec" (WorldClock action
##              time, docs/09 §14.16).
## world_state  v3 -> v4 (P3-1): world cells (docs/00 ADR-023, docs/09 §15.1).
##              From v4 on the world items and zombies of a cell may be
##              saved in that cell's own document (cells/<cell_id>.json);
##              the world document then only holds the ones that are not.
##              A v3 document holds all of them and is a valid v4 document
##              as it is: the server sorts them into cells by position when
##              it loads them and writes the cell documents with its next
##              save.
## cell         v1 (P3-1): WorldCellDocument. No older version exists.
## player       v1 -> v2 (Phase 2 P2-0): adds "systems" (per-system fragments).
## player       v2 -> v3 (P2-T4): adds "character_generation" (docs/00
##              ADR-007); every player saved before is on its first character.
## player       v3 -> v4 (P2-T9): adds "character" (docs/00 ADR-015); every
##              player saved before had a character in the world, which gets
##              the default name and the default appearance.

const WORLD_SCHEMA_VERSION: int = 4
const PLAYER_SCHEMA_VERSION: int = 4
## Same value as WorldCellDocument.SCHEMA_VERSION.
const CELL_SCHEMA_VERSION: int = 1
## Same keys as ServerWorld.KEY_WORLD_TIME / KEY_ACTION_TIME.
const KEY_WORLD_TIME: String = "world_time_sec"
const KEY_ACTION_TIME: String = "action_time_sec"
## Same key and first value as PlayerState.
const KEY_CHARACTER_GENERATION: String = "character_generation"
const FIRST_CHARACTER_GENERATION: int = 1
## Same key as PlayerState.KEY_CHARACTER.
const KEY_CHARACTER: String = "character"
## Name of a character saved before characters had names. The same text as
## the default of CharacterSettings.default_name (a migration has no access
## to settings; a test keeps the two equal).
const DEFAULT_CHARACTER_NAME: String = "생존자"


static func defaults() -> Dictionary[String, SaveMigrator]:
	var world_steps: Dictionary[int, Callable] = {
		1: func(doc: Dictionary) -> Dictionary: return world_v1_to_v2(doc),
		2: func(doc: Dictionary) -> Dictionary: return world_v2_to_v3(doc),
		3: func(doc: Dictionary) -> Dictionary: return world_v3_to_v4(doc),
	}
	var player_steps: Dictionary[int, Callable] = {
		1: func(doc: Dictionary) -> Dictionary: return player_v1_to_v2(doc),
		2: func(doc: Dictionary) -> Dictionary: return player_v2_to_v3(doc),
		3: func(doc: Dictionary) -> Dictionary: return player_v3_to_v4(doc),
	}
	var migrators: Dictionary[String, SaveMigrator] = {
		SaveService.CATEGORY_WORLD: SaveMigrator.new(WORLD_SCHEMA_VERSION, world_steps),
		SaveService.CATEGORY_PLAYER: SaveMigrator.new(PLAYER_SCHEMA_VERSION, player_steps),
		SaveService.CATEGORY_CELL: SaveMigrator.new(CELL_SCHEMA_VERSION),
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


## Worlds saved before P3-1 keep every world item and every zombie in the
## world document. Nothing has to move here (a migration knows no cell
## size): ServerWorld gives each of them the cell of its position when it
## restores the document, and the next save writes them into cell documents.
static func world_v3_to_v4(document: Dictionary) -> Dictionary:
	var result: Dictionary = document.duplicate(true)
	result["schema_version"] = 4
	return result


static func player_v1_to_v2(document: Dictionary) -> Dictionary:
	var result: Dictionary = document.duplicate(true)
	if not result.has("systems"):
		result["systems"] = {}
	result["schema_version"] = 2
	return result


## Before P2-T4 a player was one character that respawned: the first one.
static func player_v2_to_v3(document: Dictionary) -> Dictionary:
	var result: Dictionary = document.duplicate(true)
	if not result.has(KEY_CHARACTER_GENERATION):
		result[KEY_CHARACTER_GENERATION] = FIRST_CHARACTER_GENERATION
	result["schema_version"] = 3
	return result


## Before P2-T9 every saved player was in the world with a nameless
## character. It keeps playing that character: the default name and an empty
## appearance selection, which ServerWorld fills with the default option of
## every slot when it loads the world (CharacterRules.restore_profile).
static func player_v3_to_v4(document: Dictionary) -> Dictionary:
	var result: Dictionary = document.duplicate(true)
	if not result.has(KEY_CHARACTER):
		result[KEY_CHARACTER] = {"name": DEFAULT_CHARACTER_NAME, "appearance": {}}
	result["schema_version"] = 4
	return result
