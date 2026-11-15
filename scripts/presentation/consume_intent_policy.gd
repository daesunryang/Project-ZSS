class_name ConsumeIntentPolicy
extends RefCounted
## Pure client-side choice of what a use key asks for (P2-T3, P2-T6, P2-T7;
## with a modifier held: on another player, P2-T12, or handed over, P2-T14).
## It only picks an item id from the mirrored inventory; whether that item
## may be used or handed over, and what it does, is decided by the server.
##
## There is one key per kind of item (docs/15 P2-144), because one "first
## usable item" key cannot choose between food, water, a bandage and a cure.

## What a use key asks for. An item with several effects is of several kinds.
enum Kind { FOOD, DRINK, BANDAGE, CURE }
## What a use key press means, depending on the modifier keys held.
enum UseMode { ON_SELF, ON_OTHER, HAND_OVER }


## What pressing the key of `kind` asks for with these modifier keys held
## (P2-T12, P2-T14): nothing held = use the item myself; the treat-other
## modifier = use it on the other player; the hand-over modifier = hand the
## item itself over. With both held, handing over wins: it uses nothing up.
static func use_mode(kind: Kind, treat_other_held: bool, hand_over_held: bool) -> UseMode:
	if hand_over_held:
		return UseMode.HAND_OVER
	if treat_other_held and is_usable_on_others(kind):
		return UseMode.ON_OTHER
	return UseMode.ON_SELF


## How many units of the mirrored item `item_instance_id` a hand-over key
## press asks for (P2-T14): `wanted` (the setting), but never more than the
## mirror says the stack holds. 0 = nothing to ask for (the item is not in
## the mirror, its row is malformed, or `wanted` is below 1). The server
## checks the quantity against its own stack.
static func hand_over_quantity(inventory: Array[Dictionary], item_instance_id: String, wanted: int) -> int:
	if wanted < 1:
		return 0
	for entry: Dictionary in inventory:
		var item_id: Variant = entry.get("item_instance_id", null)
		if typeof(item_id) != TYPE_STRING or str(item_id) != item_instance_id:
			continue
		var quantity: Variant = entry.get("quantity", null)
		if not ItemInstance.is_integer_value(quantity) or int(quantity) < 1:
			return 0
		return mini(wanted, int(quantity))
	return 0


## True when `definition` is an item of `kind`: food lowers hunger, a drink
## lowers thirst, a bandage stops bleeding, a cure clears an infection. False
## for null.
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
		Kind.CURE:
			return definition.cures_infection
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


## True when the key of `kind` also has an "on another player" form: the
## treatments (P2-T12) and food and drink (P2-T13, docs/00 ADR-019), so every
## kind there is now. Whether the server allows it is the server's rule
## (GameplaySettings.allow_feeding_others for food and drink).
static func is_usable_on_others(kind: Kind) -> bool:
	match kind:
		Kind.FOOD, Kind.DRINK, Kind.BANDAGE, Kind.CURE:
			return true
	return false
