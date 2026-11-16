class_name ContainerIntentPolicy
extends RefCounted
## Pure client-side choice of what the container keys ask for (P3-3, docs/09
## §15.3), from the mirrors. It only picks a container, a stack and a
## quantity; whether a container opens and whether an item moves is decided
## by the server.
##
## There are five keys:
##   open key      open the nearest container in reach; with a container open
##                 (or being searched) close it
##   cursor keys   move the cursor over the stacks inside the open container
##                 (local only)
##   take key      units of the stack under that cursor into the inventory
##   put key       units of the stack under the INVENTORY cursor
##                 (InventorySelectionPolicy) into the open container

## What the open key means in the current state.
enum OpenAction { NONE, OPEN, CLOSE }
## Returned when there is no container / no stack to name.
const NO_CONTAINER: String = ""
const NO_SELECTION: String = ""
## Returned by take_quantity / put_quantity when there is nothing to ask
## for. Not a quantity the server accepts.
const NOTHING_TO_MOVE: int = -1


## Nearest container by mirrored position within `max_distance_m` (the range
## included), or NO_CONTAINER. `containers` is the mirror
## ClientContainerState.containers. Ties go to the smaller id, so the
## candidate does not flicker between two containers at the same distance.
## A suggestion only: the server checks its own positions and range.
static func nearest_container_id(origin: Vector3, containers: Dictionary, max_distance_m: float) -> String:
	var nearest_id: String = NO_CONTAINER
	var nearest_distance_squared: float = INF
	if is_nan(max_distance_m) or max_distance_m < 0.0:
		return nearest_id
	var limit_squared: float = max_distance_m * max_distance_m
	for container_id: Variant in containers:
		if typeof(container_id) != TYPE_STRING or typeof(containers[container_id]) != TYPE_DICTIONARY:
			continue
		var position: Variant = (containers[container_id] as Dictionary).get(ClientContainerState.KEY_POSITION, null)
		if typeof(position) != TYPE_VECTOR3:
			continue
		var distance_squared: float = origin.distance_squared_to(position as Vector3)
		if distance_squared > limit_squared:
			continue
		if distance_squared < nearest_distance_squared or (is_equal_approx(distance_squared, nearest_distance_squared) and str(container_id) < nearest_id):
			nearest_distance_squared = distance_squared
			nearest_id = container_id
	return nearest_id


## What the open key asks for: close the container that is open or being
## searched (`phase` is the mirror's), otherwise open `candidate_id` when
## there is one.
static func open_key_action(phase: String, candidate_id: String) -> OpenAction:
	if phase == ClientContainerState.PHASE_OPEN or phase == ClientContainerState.PHASE_SEARCHING:
		return OpenAction.CLOSE
	return OpenAction.OPEN if not candidate_id.is_empty() else OpenAction.NONE


## True when the take and the put key may ask for something: a container is
## open (not merely being searched).
static func can_transfer(phase: String) -> bool:
	return phase == ClientContainerState.PHASE_OPEN


## Ids of the stacks inside the open container in cursor order: by slot,
## then by id. `contents` is ClientContainerState.contents(). A row that is
## no stack (no id, no quantity of at least 1) cannot be selected.
static func ordered_item_ids(contents: Array[Dictionary]) -> PackedStringArray:
	var rows: Array[Array] = []
	for entry: Dictionary in contents:
		if quantity_of_row(entry) < 1:
			continue
		var slot: Variant = entry.get(ClientContainerState.KEY_SLOT, null)
		rows.append([int(slot) if typeof(slot) == TYPE_INT else InventorySelectionPolicy.NO_SLOT_INDEX, str(entry[ClientContainerState.KEY_ITEM_ID])])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] if a[0] != b[0] else str(a[1]) < str(b[1]))
	var ids: PackedStringArray = []
	for row: Array in rows:
		ids.append(str(row[1]))
	return ids


## Position of a stack in the cursor order, -1 when it is not inside.
static func index_of(contents: Array[Dictionary], item_instance_id: String) -> int:
	return ordered_item_ids(contents).find(item_instance_id)


## The stack the cursor is on after the content changed: `selected_id` while
## that stack is still inside; otherwise the stack that now is at
## `last_index`, or the nearest one; NO_SELECTION when it is empty.
static func resolve(contents: Array[Dictionary], selected_id: String, last_index: int) -> String:
	var ids: PackedStringArray = ordered_item_ids(contents)
	if ids.is_empty():
		return NO_SELECTION
	if ids.has(selected_id):
		return selected_id
	return ids[clampi(last_index, 0, ids.size() - 1)]


## The stack one step from `selected_id`: forwards for a positive
## `direction`, backwards for a negative one, wrapping at both ends.
static func step(contents: Array[Dictionary], selected_id: String, direction: int) -> String:
	var ids: PackedStringArray = ordered_item_ids(contents)
	if ids.is_empty():
		return NO_SELECTION
	var index: int = ids.find(selected_id)
	if index < 0:
		return ids[ids.size() - 1] if direction < 0 else ids[0]
	return ids[posmod(index + signi(direction), ids.size())]


## How many units of the stack `item_instance_id` inside the open container
## a take key press asks for: the whole stack as the server knows it
## (InventoryService.WHOLE_STACK) with the stack modifier held, otherwise
## `unit_quantity` but never more than the mirror says the stack holds.
## NOTHING_TO_MOVE when the stack is not inside or `unit_quantity` is below 1.
static func take_quantity(contents: Array[Dictionary], item_instance_id: String, unit_quantity: int, whole_stack: bool) -> int:
	for entry: Dictionary in contents:
		var held: int = quantity_of_row(entry)
		if held < 1 or str(entry[ClientContainerState.KEY_ITEM_ID]) != item_instance_id:
			continue
		if whole_stack:
			return InventoryService.WHOLE_STACK
		return mini(unit_quantity, held) if unit_quantity >= 1 else NOTHING_TO_MOVE
	return NOTHING_TO_MOVE


## How many units of the carried stack `item_instance_id` a put key press
## asks for: the same rule as putting a stack down
## (InventorySelectionPolicy.drop_quantity), against the mirrored inventory.
static func put_quantity(inventory: Array[Dictionary], item_instance_id: String, unit_quantity: int, whole_stack: bool) -> int:
	var quantity: int = InventorySelectionPolicy.drop_quantity(inventory, item_instance_id, unit_quantity, whole_stack)
	return NOTHING_TO_MOVE if quantity == InventorySelectionPolicy.NOTHING_TO_DROP else quantity


## Units of a content row that is a stack (a non-empty String id and a whole
## quantity of at least 1), otherwise 0.
static func quantity_of_row(entry: Dictionary) -> int:
	var item_id: Variant = entry.get(ClientContainerState.KEY_ITEM_ID, null)
	var quantity: Variant = entry.get(ClientContainerState.KEY_QUANTITY, null)
	if typeof(item_id) != TYPE_STRING or str(item_id).is_empty():
		return 0
	if not ItemInstance.is_integer_value(quantity) or int(quantity) < 1:
		return 0
	return int(quantity)
