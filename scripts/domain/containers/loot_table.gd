class_name LootTable
extends Resource
## What may be found in a container that is searched for the first time
## (P3-3, docs/03 §6 "건물 유형별 루팅 테이블", docs/09 §15.3). Static data, one
## `.tres` per table in `res://resources/definitions/loot_tables/`, loaded by
## LootTableCatalog. LootRoller turns a table and a seed into stacks.
##
## A search makes between `rolls_min` and `rolls_max` rolls. Each roll picks
## one entry by weight, or nothing (`nothing_weight`), and a quantity between
## that entry's minimum and maximum. Every roll that found something is one
## stack. The entries are parallel arrays (one index = one entry), like
## DevWorldSeed, so a table is easy to write by hand.
## Every number here is PROVISIONAL (docs/15 P3-066).

## Stable snake_case id. Saved with every container that was not searched
## yet: never rename it.
@export var table_id: String = ""
@export_range(0, 1000) var rolls_min: int = 1
@export_range(0, 1000) var rolls_max: int = 3
## Weight of "this roll finds nothing", against the sum of `weights`.
@export_range(0.0, 1000000.0) var nothing_weight: float = 0.0
@export var item_definition_ids: PackedStringArray = []
@export var weights: PackedFloat32Array = []
@export var quantities_min: PackedInt32Array = []
@export var quantities_max: PackedInt32Array = []


func entry_count() -> int:
	return item_definition_ids.size()


## Sum of every entry's weight and `nothing_weight`.
func total_weight() -> float:
	var total: float = nothing_weight
	for weight: float in weights:
		total += weight
	return total


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(table_id):
		errors.append("loot table_id '%s' must be snake_case" % table_id)
	if rolls_min < 0 or rolls_max < rolls_min:
		errors.append("loot table %s: rolls must be 0 <= rolls_min <= rolls_max" % table_id)
	var count: int = entry_count()
	if weights.size() != count or quantities_min.size() != count or quantities_max.size() != count:
		errors.append("loot table %s: item_definition_ids, weights, quantities_min and quantities_max must have the same length" % table_id)
		return errors
	if not is_finite(nothing_weight) or nothing_weight < 0.0:
		errors.append("loot table %s: nothing_weight must be >= 0" % table_id)
	for index: int in range(count):
		if not ItemInstance.is_valid_definition_id(item_definition_ids[index]):
			errors.append("loot table %s: entry %d names no item definition" % [table_id, index])
		if not is_finite(weights[index]) or weights[index] <= 0.0:
			errors.append("loot table %s: entry %d must have a weight > 0" % [table_id, index])
		if quantities_min[index] < 1 or quantities_max[index] < quantities_min[index]:
			errors.append("loot table %s: entry %d must have 1 <= quantity min <= quantity max" % [table_id, index])
	if rolls_max > 0 and count == 0 and nothing_weight <= 0.0:
		errors.append("loot table %s: rolls without any entry need a nothing_weight" % table_id)
	return errors


## Errors of the table against the item definitions: every entry must name
## an item that exists, and no roll may be more than one stack of it holds.
func validate_against(items: ItemCatalog) -> PackedStringArray:
	var errors: PackedStringArray = []
	for index: int in range(mini(entry_count(), quantities_max.size())):
		var definition: ItemDefinition = items.get_definition(item_definition_ids[index]) if items != null else null
		if definition == null:
			errors.append("loot table %s: unknown item %s" % [table_id, item_definition_ids[index]])
		elif quantities_max[index] > definition.max_stack:
			errors.append("loot table %s: %s rolls up to %d but one stack holds %d" % [table_id, item_definition_ids[index], quantities_max[index], definition.max_stack])
	return errors
