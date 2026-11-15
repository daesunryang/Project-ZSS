class_name InventorySelectionPolicy
extends RefCounted
## Pure client-side choice of WHICH carried item the inventory cursor is on
## and how many units a drop key asks for (P2-T15, docs/09 §14.29). It only
## picks an item id and a quantity from the mirrored inventory; whether the
## item may be put down is decided by the server.
##
## The cursor walks the carried stacks in slot order (the mirror itself is
## in arrival order). A row that is no usable ItemInstance dictionary (no
## id, no quantity of at least 1) is not a stack and cannot be selected.

## Returned when the mirror holds nothing to select.
const NO_SELECTION: String = ""
## Returned by drop_quantity when there is nothing to ask for. Not a
## quantity the server accepts.
const NOTHING_TO_DROP: int = -1
## Sort position of a row without a usable slot id (after every slot).
const NO_SLOT_INDEX: int = 1 << 30


## Ids of the carried stacks in cursor order: by slot number ("slot_2"
## before "slot_10"), then by id.
static func ordered_item_ids(inventory: Array[Dictionary]) -> PackedStringArray:
	var rows: Array[Array] = []
	for entry: Dictionary in inventory:
		if quantity_of_row(entry) < 1:
			continue
		rows.append([_slot_index(entry.get("slot_id", null)), str(entry["item_instance_id"])])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] if a[0] != b[0] else str(a[1]) < str(b[1]))
	var ids: PackedStringArray = []
	for row: Array in rows:
		ids.append(str(row[1]))
	return ids


## Position of an item in the cursor order, -1 when it is not a carried stack.
static func index_of(inventory: Array[Dictionary], item_instance_id: String) -> int:
	return ordered_item_ids(inventory).find(item_instance_id)


## The item the cursor is on after the mirror changed: `selected_id` while
## that stack is still carried; otherwise the stack that now is at
## `last_index` (the cursor's previous position), or the nearest one;
## NO_SELECTION when nothing is carried.
static func resolve(inventory: Array[Dictionary], selected_id: String, last_index: int) -> String:
	var ids: PackedStringArray = ordered_item_ids(inventory)
	if ids.is_empty():
		return NO_SELECTION
	if ids.has(selected_id):
		return selected_id
	return ids[clampi(last_index, 0, ids.size() - 1)]


## The item one step from `selected_id`: forwards for a positive `direction`,
## backwards for a negative one, wrapping at both ends. Without a valid
## selection forwards starts at the first stack and backwards at the last.
static func step(inventory: Array[Dictionary], selected_id: String, direction: int) -> String:
	var ids: PackedStringArray = ordered_item_ids(inventory)
	if ids.is_empty():
		return NO_SELECTION
	var index: int = ids.find(selected_id)
	if index < 0:
		return ids[ids.size() - 1] if direction < 0 else ids[0]
	return ids[posmod(index + signi(direction), ids.size())]


## How many units of the mirrored stack `item_instance_id` a drop key press
## asks for: the whole stack as the server knows it
## (InventoryService.WHOLE_STACK) with the stack modifier held, otherwise
## `unit_quantity` (the setting) but never more than the mirror says the
## stack holds. NOTHING_TO_DROP when the item is not a carried stack of the
## mirror or `unit_quantity` is below 1. The server checks the quantity
## against its own stack.
static func drop_quantity(inventory: Array[Dictionary], item_instance_id: String, unit_quantity: int, whole_stack: bool) -> int:
	for entry: Dictionary in inventory:
		var held: int = quantity_of_row(entry)
		if held < 1 or str(entry["item_instance_id"]) != item_instance_id:
			continue
		if whole_stack:
			return InventoryService.WHOLE_STACK
		return mini(unit_quantity, held) if unit_quantity >= 1 else NOTHING_TO_DROP
	return NOTHING_TO_DROP


## Units of a mirror row that is a carried stack (a non-empty String id and
## a whole quantity of at least 1), otherwise 0.
static func quantity_of_row(entry: Dictionary) -> int:
	var item_id: Variant = entry.get("item_instance_id", null)
	var quantity: Variant = entry.get("quantity", null)
	if typeof(item_id) != TYPE_STRING or str(item_id).is_empty():
		return 0
	if not ItemInstance.is_integer_value(quantity) or int(quantity) < 1:
		return 0
	return int(quantity)


static func _slot_index(slot_id: Variant) -> int:
	if typeof(slot_id) != TYPE_STRING or not str(slot_id).begins_with(InventoryService.SLOT_PREFIX):
		return NO_SLOT_INDEX
	var digits: String = str(slot_id).trim_prefix(InventoryService.SLOT_PREFIX)
	return digits.to_int() if digits.is_valid_int() else NO_SLOT_INDEX
