class_name DevWorldSeed
extends Resource
## PROVISIONAL development content for a brand-new world (docs/15 P1-6,
## P2-121): items placed in the world when no save exists. Real world
## generation / loot rules are Phase 3 (docs/03, docs/13).

const DEFAULT_PATH: String = "res://data/tuning/dev_world_seed.tres"
## The cell at the world origin. Before P3-1 every world item was saved with
## this id; the server now uses the cell of an item's position
## (ServerWorld.cell_id_at). Kept for tests and tools that place an item
## near the origin by hand.
const DEV_CELL_ID: String = "cell_0_0"
const DEFAULT_QUANTITY: int = 1

@export var item_definition_ids: PackedStringArray = []
@export var item_positions: PackedVector3Array = []
## Stack size of each seeded item. Empty = one of each; otherwise one entry
## per item (1..the definition's max_stack, checked when the world is seeded).
@export var item_quantities: PackedInt32Array = []


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if item_definition_ids.size() != item_positions.size():
		errors.append("item_definition_ids and item_positions must have the same length")
	if not item_quantities.is_empty() and item_quantities.size() != item_definition_ids.size():
		errors.append("item_quantities must be empty or have one entry per item")
	for quantity: int in item_quantities:
		if quantity < DEFAULT_QUANTITY:
			errors.append("item_quantities must be >= 1")
			break
	return errors


## Stack size of the seeded item at `index`.
func quantity_at(index: int) -> int:
	return DEFAULT_QUANTITY if item_quantities.is_empty() else item_quantities[index]


static func load_or_default(path: String = DEFAULT_PATH) -> DevWorldSeed:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is DevWorldSeed:
		return loaded as DevWorldSeed
	GameLogger.warning("config", "dev world seed missing, using empty seed", {"path": path, "operation": "load_settings"})
	return DevWorldSeed.new()
