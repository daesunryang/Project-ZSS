class_name NpcHomeSettings
extends Resource
## Where the NPCs of a roster live in a world that has a generated map
## (F-28, docs/09 §17.13): each alone in a generated building chosen with
## the world seed. Defaults in `res://data/tuning/npc_home_settings.tres`.
## Every value is PROVISIONAL (docs/15 §24) until play-tested.

const DEFAULT_PATH: String = "res://data/tuning/npc_home_settings.tres"
const PER_MILLE_MAX: int = 1000

## true: in a world with a generated map (ProceduralMapService) every NPC of
## the roster gets a generated building of its own. false, or a world
## without a generated map: the NPCs live on the home spots their
## definitions name (the hand-made map; tests and tools).
@export var lone_homes: bool = true
## MapBuildingDefinition.building_type of the buildings an NPC lives in.
## Other buildings are only taken when no such building is found.
@export var home_building_types: PackedStringArray = ["house"]
## How many of a thousand NPCs live outside every town (a farm beside a
## road). The others are spread over the towns, the town with the fewest
## NPCs first.
@export_range(0, 1000) var countryside_per_mille: int = 300
## Cells that are looked at per town (and for the countryside) to find a
## free building. Bounds what choosing one home costs.
@export_range(1, 10000) var cell_attempts: int = 64
## What an NPC has in its home when it is placed there, besides the loot of
## the building's containers: this many units of this item in one container
## ("" or 0 = nothing). Given once; never refilled.
@export var stock_item_id: String = "dev_food_ration"
@export_range(0, 10000) var stock_units: int = 6
## true: NPCs of the roster that a world placed on the hand-made map before
## it had lone homes are moved to a generated home, once (the first time
## each is in memory). false: they stay where they are.
@export var relocate_existing: bool = true


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if home_building_types.is_empty():
		errors.append("npc home home_building_types must not be empty")
	if countryside_per_mille < 0 or countryside_per_mille > PER_MILLE_MAX:
		errors.append("npc home countryside_per_mille must be within 0..%d" % PER_MILLE_MAX)
	if cell_attempts < 1:
		errors.append("npc home cell_attempts must be >= 1")
	if stock_units < 0 or (stock_units > 0) != (not stock_item_id.is_empty()):
		errors.append("npc home stock_item_id and stock_units go together")
	return errors


## Errors against the item data: what a home is stocked with is food.
func validate_against(items: ItemCatalog) -> PackedStringArray:
	var errors: PackedStringArray = []
	if stock_units > 0 and items != null:
		var stock: ItemDefinition = items.get_definition(stock_item_id)
		if stock == null or stock.consume_hunger_reduction <= 0.0:
			errors.append("npc home stock item %s must be food" % stock_item_id)
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NpcHomeSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcHomeSettings:
		return loaded as NpcHomeSettings
	GameLogger.warning("config", "npc home settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcHomeSettings.new()
