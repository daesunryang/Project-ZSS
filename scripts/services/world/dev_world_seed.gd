class_name DevWorldSeed
extends Resource
## PROVISIONAL development content for a brand-new world (docs/15 P1-6):
## items placed in the world when no save exists. Real world generation /
## loot rules are Phase 3 (docs/03, docs/13).

const DEFAULT_PATH: String = "res://data/tuning/dev_world_seed.tres"
## Cell id used for all seeded items until cell streaming exists.
const DEV_CELL_ID: String = "cell_0_0"

@export var item_definition_ids: PackedStringArray = []
@export var item_positions: PackedVector3Array = []


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if item_definition_ids.size() != item_positions.size():
		errors.append("item_definition_ids and item_positions must have the same length")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> DevWorldSeed:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is DevWorldSeed:
		return loaded as DevWorldSeed
	GameLogger.warning("config", "dev world seed missing, using empty seed", {"path": path, "operation": "load_settings"})
	return DevWorldSeed.new()
