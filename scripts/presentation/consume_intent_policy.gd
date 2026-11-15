class_name ConsumeIntentPolicy
extends RefCounted
## Pure client-side choice of what a use key asks for (P2-T3, P2-T6). It
## only picks an item id from the mirrored inventory; whether that item may
## be used, and what it does, is decided by the server.
##
## There is one key per kind of item (docs/15 P2-144), because one "first
## usable item" key cannot choose between food, water and a bandage.

## What a use key asks for. An item with several effects is of several kinds.
enum Kind { FOOD, DRINK, BANDAGE }


## True when `definition` is an item of `kind`: food lowers hunger, a drink
## lowers thirst, a bandage stops bleeding. False for null.
static func is_kind(definition: ItemDefinition, kind: Kind) -> bool:
	if definition == null:
		return false
	match kind:
		Kind.FOOD:
			return definition.consume_hunger_reduction > 0.0
		Kind.DRINK:
			return definition.consume_thirst_reduction > 0.0
		Kind.BANDAGE:
			return definition.stops_bleeding()
	return false


## Id of the first entry of the mirrored inventory whose definition is of
## `kind`, in mirror order (the order the server sent the items), or "" when
## there is none. Entries that are not usable ItemInstance dictionaries and
## unknown definitions are skipped.
static func first_item_id_of_kind(inventory: Array[Dictionary], catalog: ItemCatalog, kind: Kind) -> String:
	if catalog == null:
		return ""
	for entry: Dictionary in inventory:
		var item_id: Variant = entry.get("item_instance_id", null)
		var definition_id: Variant = entry.get("definition_id", null)
		if typeof(item_id) != TYPE_STRING or typeof(definition_id) != TYPE_STRING or str(item_id).is_empty():
			continue
		if is_kind(catalog.get_definition(str(definition_id)), kind):
			return str(item_id)
	return ""


## Units of `kind` in the mirrored inventory (all stacks summed). Malformed
## entries and unknown definitions count as 0.
static func count_of_kind(inventory: Array[Dictionary], catalog: ItemCatalog, kind: Kind) -> int:
	if catalog == null:
		return 0
	var total: int = 0
	for entry: Dictionary in inventory:
		var definition_id: Variant = entry.get("definition_id", null)
		var quantity: Variant = entry.get("quantity", null)
		if typeof(definition_id) != TYPE_STRING or not ItemInstance.is_integer_value(quantity) or int(quantity) < 1:
			continue
		if is_kind(catalog.get_definition(str(definition_id)), kind):
			total += int(quantity)
	return total
