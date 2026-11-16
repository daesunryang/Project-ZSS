class_name InventoryService
extends RefCounted
## Server-authoritative item state and transactions (docs/08 §8, docs/14 §6).
##
## Owns every ItemInstance, the world positions of items lying in the world,
## and player inventories. All mutations go through methods here and are
## all-or-nothing: a failed command changes nothing. Requests are processed
## in call order, so of two concurrent pickups of the same item only the
## first one succeeds. No Node references; fully unit-testable.
##
## Transactions (server only; each returns an ActionResult whose `event` is
## the committed fact, or a REASON_* code and no change):
##   try_pickup      world -> inventory; the units join the carried stacks of
##                   the same kind first (P2-T15)
##   drop_item       inventory -> world: the whole stack (P2-T2) or a part of
##                   it, which becomes a new item (P2-T15)
##   drop_all_items  every item of one inventory -> world (P2-T2)
##   remove_item     a quantity leaves the game; at 0 the instance is deleted
##                   and its id is retired for good (P2-T2)
##   transfer_item   a quantity moves from one inventory into another,
##                   merging into the receiver's stacks (P2-T14). Since P3-3
##                   it is how a player puts items into a container and takes
##                   them out (ContainerService; one side is the container's
##                   detached inventory, see "detached inventories" below).
##                   No rule moves items between two players with it (docs/00
##                   ADR-021).
##   take_items      units of several carried stacks leave an inventory at
##                   once because a server rule put them into something
##                   that is not an item any more (building materials,
##                   P3-5). Announced as `items_taken`.
##   place_world_items  new items come to lie in the world that no inventory
##                   gave (materials a structure returns, P3-5). Announced as
##                   `items_dropped` with an empty `inventory_id`.
## Every committed transaction is also announced through
## `transaction_committed`, synchronously and in commit order, once the state
## is final. InventoryNetModule replicates from it (docs/09 §14.17), so
## clients see changes in the order the server committed them.
##
## World cells (P3-1, docs/09 §15.1). A world item's `location_id` is the id
## of the cell it lies in, and every world item in memory is in the world's
## WorldCellIndex (kind "item"). The items of one cell can be taken out of
## memory and brought back unchanged:
##   cell_snapshot          the world items of one cell, as save data
##   restore_cell_snapshot  brings the saved world items of a cell back
##   release_cell           forgets the world items of a cell (after they
##                          were saved); their ids are NOT retired
## Carried items never leave memory with a cell. These three announce
## nothing through `transaction_committed`: no item changed hands.
## The transactions keep the index right (tests/unit/item_moves_in_cells_test.gd):
##   - an item that comes to lie in the world is indexed under the cell the
##     caller names, whether it is a whole stack or the new instance a part
##     of a stack becomes (drop_item, drop_all_items);
##   - an item that is picked up leaves the index, whether it keeps its id in
##     a slot or merges into carried stacks. One that merged completely is
##     retired (tombstoned), not released: restore_cell_snapshot skips
##     retired ids and ids that are in memory, so a saved copy of its cell
##     never brings its units back a second time;
##   - transfer_item and exchange_items only touch carried items: no cell.

## A transaction was committed. `event` is a copy of the ActionResult event.
signal transaction_committed(event: Dictionary)
## A committed transaction changed a world item in this cell.
signal cell_save_dirty(cell_id: String)

const ENTITY_KIND_ITEM: String = "item"
const ENTITY_KIND_INVENTORY: String = "inventory"
const SLOT_PREFIX: String = "slot_"
## {item_instance_id (the item that lay in the world), inventory_id,
##  slot_id (where that instance is carried now; "" = it merged away
##  entirely and no longer exists), from_cell_id, definition_id,
##  quantity (units picked up), merged: Array of {item_instance_id, quantity}
##  (carried stacks that grew, and by how many units; see try_pickup)}.
const EVENT_ITEM_PICKED_UP: String = "item_picked_up"
## {inventory_id, item_instance_ids: Array of String (slot order), cell_id,
##  position: [x, y, z]}. Used by drop_item and by drop_all_items, and by
## place_world_items (P3-5) with `inventory_id` "": items that came to lie
## in the world without leaving an inventory.
const EVENT_ITEMS_DROPPED: String = "items_dropped"
## {inventory_id, item_instance_id, definition_id, removed_quantity,
##  remaining_quantity}. remaining_quantity 0 = the instance no longer exists.
const EVENT_ITEM_REMOVED: String = "item_removed"
## {from_inventory_id, to_inventory_id, item_instance_id (the giver's stack),
##  definition_id, quantity (units moved), remaining_quantity (what the
##  giver's stack still holds; 0 = that instance left the giver's inventory),
##  received: Array of {item_instance_id, quantity} (the receiver's instances
##  that grew or arrived, and by how many units; see transfer_item)}.
const EVENT_ITEM_TRANSFERRED: String = "item_transferred"

## Failure reason codes (stable, sent to clients).
const REASON_UNKNOWN_INVENTORY: String = "unknown_inventory"
const REASON_UNKNOWN_ITEM: String = "unknown_item"
const REASON_NOT_IN_WORLD: String = "item_not_in_world"
const REASON_TOO_FAR: String = "too_far"
const REASON_INVENTORY_FULL: String = "inventory_full"
## The item exists but is not carried in the given inventory (it lies in the
## world or is in another inventory).
const REASON_NOT_IN_INVENTORY: String = "item_not_in_inventory"
## Quantity below 1 or above what the stack holds.
const REASON_BAD_QUANTITY: String = "bad_quantity"
## Position not finite or outside the play area.
const REASON_BAD_POSITION: String = "bad_position"
const REASON_BAD_CELL: String = "bad_cell"
## Quantity argument of drop_item that means "the whole stack, however many
## units the server knows it to hold" (P2-T15).
const WHOLE_STACK: int = 0
## {inventory_id, item_instance_id (the carried stack, which stays),
##  definition_id, quantity (units put down), remaining_quantity,
##  world_item_instance_id (the new instance lying in the world), cell_id,
##  position: [x, y, z]}. A part of a stack was put down (drop_item, P2-T15).
const EVENT_ITEM_UNITS_DROPPED: String = "item_units_dropped"
## A transfer names the same inventory as giver and receiver.
const REASON_SAME_INVENTORY: String = "same_inventory"
## No new item id could be registered (never expected; nothing changed).
const REASON_ID_UNAVAILABLE: String = "id_unavailable"
## Two inventories gave each other units of items (exchange_items, P2-T16):
## {sides: [first, second]}, each side
##  {inventory_id,
##   gave: Array of {item_instance_id, definition_id, quantity} (what this
##     inventory gave, in the order of its offer),
##   removed_item_instance_ids: Array of String (ids that were in this
##     inventory before and are not any more: moved over or merged away),
##   changed_item_instance_ids: Array of String (ids that are in this
##     inventory now and were not before, or hold another quantity; slot
##     order)}.
const EVENT_ITEMS_EXCHANGED: String = "items_exchanged"
## Keys of one entry of an offer given to exchange_items.
const OFFER_ITEM_ID: String = "item_instance_id"
const OFFER_QUANTITY: String = "quantity"
## An offer entry is no {item_instance_id: String, quantity: int}.
const REASON_BAD_OFFER: String = "bad_offer"
## One offer names the same stack twice.
const REASON_DUPLICATE_ITEM: String = "duplicate_item"
## Both offers are empty.
const REASON_NOTHING_TO_EXCHANGE: String = "nothing_to_exchange"
## The first / the second inventory of an exchange cannot take everything
## that would come in, even after what it gives has left.
const REASON_FIRST_INVENTORY_FULL: String = "first_inventory_full"
const REASON_SECOND_INVENTORY_FULL: String = "second_inventory_full"
## Units of carried stacks went into something a server rule keeps outside
## the inventory system (take_items, P3-5: materials delivered to a
## structure): {inventory_id, taken: Array of {item_instance_id,
##  definition_id, quantity (units taken), remaining_quantity (what the
##  stack still holds; 0 = the instance no longer exists)}}, in the order
## they were asked for. InventoryNetModule tells the owner of the inventory
## but schedules no save for it: whoever calls take_items decides when the
## world is saved (docs/00 ADR-025).
const EVENT_ITEMS_TAKEN: String = "items_taken"
## A request names an item definition the catalog does not have.
const REASON_UNKNOWN_DEFINITION: String = "unknown_item_definition"
## Nothing was asked for (an empty list).
const REASON_NOTHING_TO_MOVE: String = "nothing_to_move"

const SNAPSHOT_ITEMS: String = "items"
const SNAPSHOT_POSITIONS: String = "world_item_positions"
const SNAPSHOT_INVENTORIES: String = "inventories"

var _catalog: ItemCatalog
var _ids: EntityIdGenerator
var _registry: EntityRegistry
var _pickup_range_m: float
## Half size of the square play area; nothing can be dropped outside it.
var _world_half_extent_m: float
var _items: Dictionary[String, ItemInstance] = {}
var _world_positions: Dictionary[String, Vector3] = {}
## inventory_id -> slot capacity
var _inventories: Dictionary[String, int] = {}
## Which cell every world item in memory is in (kind ENTITY_KIND_ITEM).
var _cell_index: WorldCellIndex
## true: a picked-up stack joins the carried stacks of the same kind
## (try_pickup). ServerWorld sets it from
## GameplaySettings.merge_stacks_on_pickup.
var merge_on_pickup: bool = true


## `world_half_extent_m` bounds drop positions (ServerWorld passes
## GameplaySettings.world_half_extent_m); the default is unbounded.
## `cell_index` is the world's entity index (ServerWorld.cell_index); a
## service built without one keeps its own.
func _init(catalog: ItemCatalog, ids: EntityIdGenerator, registry: EntityRegistry, pickup_range_m: float, world_half_extent_m: float = INF, cell_index: WorldCellIndex = null) -> void:
	_catalog = catalog
	_ids = ids
	_registry = registry
	_pickup_range_m = pickup_range_m
	_world_half_extent_m = world_half_extent_m
	_cell_index = cell_index if cell_index != null else WorldCellIndex.new()


## Creates an empty inventory and returns its id ("" on failure).
func create_inventory(capacity: int) -> String:
	if capacity < 1:
		GameLogger.error("inventory", "invalid inventory capacity", {"capacity": capacity, "operation": "create_inventory"})
		return ""
	var inventory_id: String = _ids.next_id(ENTITY_KIND_INVENTORY)
	if _registry.register(inventory_id, ENTITY_KIND_INVENTORY) != OK:
		return ""
	_inventories[inventory_id] = capacity
	return inventory_id


## Places a new item in the world. Returns its id ("" on failure).
func spawn_world_item(definition_id: String, quantity: int, cell_id: String, position: Vector3) -> String:
	var definition: ItemDefinition = _catalog.get_definition(definition_id)
	if definition == null:
		GameLogger.error("inventory", "spawn of unknown item definition", {"definition_id": definition_id, "operation": "spawn_world_item"})
		return ""
	if quantity < 1 or quantity > definition.max_stack:
		GameLogger.error("inventory", "spawn quantity out of range", {"definition_id": definition_id, "quantity": quantity, "operation": "spawn_world_item"})
		return ""
	var item: ItemInstance = ItemInstance.new()
	item.item_instance_id = _ids.next_id(ENTITY_KIND_ITEM)
	item.definition_id = definition_id
	item.quantity = quantity
	item.location_type = ItemInstance.LOCATION_WORLD
	item.location_id = cell_id
	if _registry.register(item.item_instance_id, ENTITY_KIND_ITEM) != OK:
		return ""
	_items[item.item_instance_id] = item
	_world_positions[item.item_instance_id] = position
	_index_world_item(item)
	return item.item_instance_id


## Moves a world item into `inventory_id` if the actor (at the server-known
## `actor_position`) is within range and the inventory can take all of it.
## All or nothing: never a part of the stack.
##
## Where the units go (P2-T15; the same rule as transfer_item):
##   1. into the carried stacks of the same definition with the same
##      condition and quality, lowest slot number first, each up to the
##      definition's max_stack (only while `merge_on_pickup` is true);
##   2. what is left over stays ONE stack: the picked-up instance itself takes
##      the first free slot and keeps its id.
## If something is left over and there is no free slot the pickup is refused
## (`inventory_full`). If nothing is left over, the picked-up instance is
## deleted and its id retired (docs/14 §1): the event's `slot_id` is "" then
## and `merged` says which carried stacks took its units.
## Either way the instance leaves the cell index (P3-1): it no longer lies in
## a cell, and a retired id is never restored from a cell's save data.
func try_pickup(inventory_id: String, item_instance_id: String, actor_position: Vector3) -> ActionResult:
	if not _inventories.has(inventory_id):
		return _reject(REASON_UNKNOWN_INVENTORY, inventory_id, item_instance_id)
	var item: ItemInstance = _items.get(item_instance_id, null)
	if item == null:
		return _reject(REASON_UNKNOWN_ITEM, inventory_id, item_instance_id)
	if item.location_type != ItemInstance.LOCATION_WORLD or not _world_positions.has(item_instance_id):
		return _reject(REASON_NOT_IN_WORLD, inventory_id, item_instance_id)
	if actor_position.distance_to(_world_positions[item_instance_id]) > _pickup_range_m:
		return _reject(REASON_TOO_FAR, inventory_id, item_instance_id)
	# Plan: which carried stacks take how many units, and what is left.
	var quantity: int = item.quantity
	var fills: Array[Array] = _plan_fills(inventory_id, item, quantity) if merge_on_pickup else ([] as Array[Array])
	var left: int = quantity - _filled_units(fills)
	var slot_id: String = ""
	if left > 0:
		slot_id = _first_free_slot(inventory_id)
		if slot_id.is_empty():
			return _reject(REASON_INVENTORY_FULL, inventory_id, item_instance_id)

	# Commit: every check passed, apply all changes together.
	var from_cell: String = item.location_id
	var merged: Array = _apply_fills(fills)
	_world_positions.erase(item_instance_id)
	_cell_index.remove(item_instance_id)
	if left > 0:
		item.quantity = left
		item.location_type = ItemInstance.LOCATION_INVENTORY
		item.location_id = inventory_id
		item.slot_id = slot_id
	else:
		_items.erase(item_instance_id)
		if _registry.remove(item_instance_id) != OK:
			GameLogger.error("inventory", "picked-up item was not registered", {"entity_id": item_instance_id, "inventory_id": inventory_id, "operation": "try_pickup"})
	GameLogger.info("inventory", "item picked up", {"entity_id": item_instance_id, "inventory_id": inventory_id, "slot_id": slot_id, "quantity": quantity, "merged_stacks": merged.size()})
	return _commit({
		"event_type": EVENT_ITEM_PICKED_UP,
		"item_instance_id": item_instance_id,
		"inventory_id": inventory_id,
		"slot_id": slot_id,
		"from_cell_id": from_cell,
		"definition_id": item.definition_id,
		"quantity": quantity,
		"merged": merged,
	})


## Moves units of one carried item from `inventory_id` to the world at
## `position` in `cell_id`. The caller supplies a server-known position.
##   - `quantity` WHOLE_STACK (the default) or exactly what the stack holds:
##     the instance itself goes to the world and keeps its id (event
##     `items_dropped`, P2-T2).
##   - 1 <= `quantity` < the stack (P2-T15): the carried stack only gets
##     smaller and the units become a NEW instance with a new id lying in
##     the world, with the stack's condition and quality (event
##     `item_units_dropped`). Two stacks never share an id.
## Anything else is `bad_quantity`. The units are conserved either way, and
## what lies in the world afterwards is in the cell index under `cell_id`
## (P3-1; ServerWorld passes the cell of `position`).
func drop_item(inventory_id: String, item_instance_id: String, cell_id: String, position: Vector3, quantity: int = WHOLE_STACK) -> ActionResult:
	const OPERATION: String = "drop_item"
	if not _inventories.has(inventory_id):
		return _reject(REASON_UNKNOWN_INVENTORY, inventory_id, item_instance_id, OPERATION)
	var item: ItemInstance = _items.get(item_instance_id, null)
	if item == null:
		return _reject(REASON_UNKNOWN_ITEM, inventory_id, item_instance_id, OPERATION)
	if not _is_carried_in(item, inventory_id):
		return _reject(REASON_NOT_IN_INVENTORY, inventory_id, item_instance_id, OPERATION)
	if quantity != WHOLE_STACK and (quantity < 1 or quantity > item.quantity):
		return _reject(REASON_BAD_QUANTITY, inventory_id, item_instance_id, OPERATION)
	var place_error: String = _validate_world_place(cell_id, position)
	if not place_error.is_empty():
		return _reject(place_error, inventory_id, item_instance_id, OPERATION)
	if quantity == WHOLE_STACK or quantity == item.quantity:
		# Commit: every check passed.
		_move_to_world(item, cell_id, position)
		GameLogger.info("inventory", "item dropped", {"entity_id": item_instance_id, "inventory_id": inventory_id, "cell_id": cell_id})
		return _commit(_dropped_event(inventory_id, [item_instance_id], cell_id, position))
	# A part of the stack. The one thing that could still fail is the new id:
	# taken before anything changes.
	var new_id: String = _ids.next_id(ENTITY_KIND_ITEM)
	if new_id.is_empty() or _registry.register(new_id, ENTITY_KIND_ITEM) != OK:
		GameLogger.error("inventory", "no id for a dropped part of a stack", {"entity_id": item_instance_id, "inventory_id": inventory_id, "operation": OPERATION})
		return _reject(REASON_ID_UNAVAILABLE, inventory_id, item_instance_id, OPERATION)

	# Commit: every check passed.
	var remaining: int = item.quantity - quantity
	item.quantity = remaining
	var lying: ItemInstance = ItemInstance.new()
	lying.item_instance_id = new_id
	lying.definition_id = item.definition_id
	lying.quantity = quantity
	lying.condition = item.condition
	lying.quality = item.quality
	_items[new_id] = lying
	_move_to_world(lying, cell_id, position)
	GameLogger.info("inventory", "item units dropped", {"entity_id": item_instance_id, "inventory_id": inventory_id, "cell_id": cell_id, "quantity": quantity, "remaining": remaining, "world_item_id": new_id})
	return _commit({
		"event_type": EVENT_ITEM_UNITS_DROPPED,
		"inventory_id": inventory_id,
		"item_instance_id": item_instance_id,
		"definition_id": item.definition_id,
		"quantity": quantity,
		"remaining_quantity": remaining,
		"world_item_instance_id": new_id,
		"cell_id": cell_id,
		"position": [position.x, position.y, position.z],
	})


## Moves every item carried in `inventory_id` to the world at `position`
## (all or nothing). An empty inventory succeeds and announces nothing.
func drop_all_items(inventory_id: String, cell_id: String, position: Vector3) -> ActionResult:
	const OPERATION: String = "drop_all_items"
	if not _inventories.has(inventory_id):
		return _reject(REASON_UNKNOWN_INVENTORY, inventory_id, "", OPERATION)
	var place_error: String = _validate_world_place(cell_id, position)
	if not place_error.is_empty():
		return _reject(place_error, inventory_id, "", OPERATION)

	# Commit: nothing below can fail.
	var dropped_ids: Array = []
	for item: ItemInstance in items_in_inventory(inventory_id):
		_move_to_world(item, cell_id, position)
		dropped_ids.append(item.item_instance_id)
	var event: Dictionary = _dropped_event(inventory_id, dropped_ids, cell_id, position)
	if dropped_ids.is_empty():
		return ActionResult.success(event)
	GameLogger.info("inventory", "inventory dropped", {"inventory_id": inventory_id, "items": dropped_ids.size(), "cell_id": cell_id})
	return _commit(event)


## Takes `quantity` (1..stack size) of a carried item out of the game. A
## stack that still holds something only gets smaller; at 0 the instance is
## deleted and its id is tombstoned, so it is never used again (docs/14 §1).
func remove_item(inventory_id: String, item_instance_id: String, quantity: int) -> ActionResult:
	const OPERATION: String = "remove_item"
	if not _inventories.has(inventory_id):
		return _reject(REASON_UNKNOWN_INVENTORY, inventory_id, item_instance_id, OPERATION)
	var item: ItemInstance = _items.get(item_instance_id, null)
	if item == null:
		return _reject(REASON_UNKNOWN_ITEM, inventory_id, item_instance_id, OPERATION)
	if not _is_carried_in(item, inventory_id):
		return _reject(REASON_NOT_IN_INVENTORY, inventory_id, item_instance_id, OPERATION)
	if quantity < 1 or quantity > item.quantity:
		return _reject(REASON_BAD_QUANTITY, inventory_id, item_instance_id, OPERATION)

	# Commit: every check passed.
	var remaining: int = item.quantity - quantity
	if remaining > 0:
		item.quantity = remaining
	else:
		_items.erase(item_instance_id)
		if _registry.remove(item_instance_id) != OK:
			GameLogger.error("inventory", "removed item was not registered", {"entity_id": item_instance_id, "inventory_id": inventory_id, "operation": OPERATION})
	GameLogger.info("inventory", "item removed", {"entity_id": item_instance_id, "inventory_id": inventory_id, "removed": quantity, "remaining": remaining})
	return _commit({
		"event_type": EVENT_ITEM_REMOVED,
		"inventory_id": inventory_id,
		"item_instance_id": item_instance_id,
		"definition_id": item.definition_id,
		"removed_quantity": quantity,
		"remaining_quantity": remaining,
	})


## Moves `quantity` (1..stack size) units of an item carried in
## `from_inventory_id` into `to_inventory_id` (P2-T14: one player hands an
## item over to another). All or nothing, and the units are conserved: what
## leaves the one inventory is exactly what arrives in the other.
##
## Where the units go in the receiving inventory:
##   1. into its stacks of the same definition with the same condition and
##      quality, lowest slot number first, each up to the definition's
##      max_stack;
##   2. what is left over becomes ONE stack in its first free slot.
## If something is left over and there is no free slot, the whole transfer is
## refused (`inventory_full`): never a part of what was asked for.
##
## Item instance ids (docs/14 §1: unique, never reused):
##   - nothing is left over (everything merged): no instance arrives. If the
##     giver's stack is emptied, that instance is deleted and its id retired.
##   - something is left over and the giver's stack is emptied: the giver's
##     instance itself moves into the free slot and keeps its id.
##   - something is left over and the giver keeps a rest: the left-over units
##     become a NEW instance with a new id (two stacks never share an id).
## The event's `received` lists every instance of the receiving inventory
## that grew or arrived, in the order above, with the units it gained.
func transfer_item(from_inventory_id: String, item_instance_id: String, to_inventory_id: String, quantity: int) -> ActionResult:
	const OPERATION: String = "transfer_item"
	if not _inventories.has(from_inventory_id):
		return _reject(REASON_UNKNOWN_INVENTORY, from_inventory_id, item_instance_id, OPERATION)
	var item: ItemInstance = _items.get(item_instance_id, null)
	if item == null:
		return _reject(REASON_UNKNOWN_ITEM, from_inventory_id, item_instance_id, OPERATION)
	if not _is_carried_in(item, from_inventory_id):
		return _reject(REASON_NOT_IN_INVENTORY, from_inventory_id, item_instance_id, OPERATION)
	if quantity < 1 or quantity > item.quantity:
		return _reject(REASON_BAD_QUANTITY, from_inventory_id, item_instance_id, OPERATION)
	if not _inventories.has(to_inventory_id):
		return _reject(REASON_UNKNOWN_INVENTORY, to_inventory_id, item_instance_id, OPERATION)
	if to_inventory_id == from_inventory_id:
		return _reject(REASON_SAME_INVENTORY, from_inventory_id, item_instance_id, OPERATION)

	# Plan: which stacks of the receiver take how many units, and what is left.
	var fills: Array[Array] = _plan_fills(to_inventory_id, item, quantity)
	var left: int = quantity - _filled_units(fills)
	var free_slot: String = ""
	if left > 0:
		free_slot = _first_free_slot(to_inventory_id)
		if free_slot.is_empty():
			return _reject(REASON_INVENTORY_FULL, to_inventory_id, item_instance_id, OPERATION)
	var empties_stack: bool = quantity == item.quantity
	# The one thing that could still fail: a new id for a left-over part of a
	# stack. Taken before anything changes.
	var new_id: String = ""
	if left > 0 and not empties_stack:
		new_id = _ids.next_id(ENTITY_KIND_ITEM)
		if new_id.is_empty() or _registry.register(new_id, ENTITY_KIND_ITEM) != OK:
			GameLogger.error("inventory", "no id for a transferred stack", {"entity_id": item_instance_id, "inventory_id": to_inventory_id, "operation": OPERATION})
			return _reject(REASON_ID_UNAVAILABLE, to_inventory_id, item_instance_id, OPERATION)

	# Commit: every check passed, apply all changes together.
	var received: Array = _apply_fills(fills)
	var remaining: int = item.quantity - quantity
	if not empties_stack:
		item.quantity = remaining
		if left > 0:
			var arrived: ItemInstance = ItemInstance.new()
			arrived.item_instance_id = new_id
			arrived.definition_id = item.definition_id
			arrived.quantity = left
			arrived.condition = item.condition
			arrived.quality = item.quality
			arrived.location_type = ItemInstance.LOCATION_INVENTORY
			arrived.location_id = to_inventory_id
			arrived.slot_id = free_slot
			_items[new_id] = arrived
			received.append({"item_instance_id": new_id, "quantity": left})
	elif left > 0:
		item.quantity = left
		item.location_id = to_inventory_id
		item.slot_id = free_slot
		received.append({"item_instance_id": item_instance_id, "quantity": left})
	else:
		_items.erase(item_instance_id)
		if _registry.remove(item_instance_id) != OK:
			GameLogger.error("inventory", "transferred item was not registered", {"entity_id": item_instance_id, "inventory_id": from_inventory_id, "operation": OPERATION})
	GameLogger.info("inventory", "item transferred", {"entity_id": item_instance_id, "inventory_id": from_inventory_id, "to_inventory_id": to_inventory_id, "quantity": quantity, "remaining": remaining})
	return _commit({
		"event_type": EVENT_ITEM_TRANSFERRED,
		"from_inventory_id": from_inventory_id,
		"to_inventory_id": to_inventory_id,
		"item_instance_id": item_instance_id,
		"definition_id": item.definition_id,
		"quantity": quantity,
		"remaining_quantity": remaining,
		"received": received,
	})


## Two inventories give each other units of items they carry, in ONE
## transaction (P2-T16: a completed trade, docs/09 §14.30). `first_gives` /
## `second_gives` are offers: arrays of {item_instance_id: String,
## quantity: int}, each naming a stack of the giving inventory and
## 1..its size units of it. One offer may be empty (a gift), not both.
##
## All or nothing. The whole exchange is planned before anything changes:
##   - what leaves the one inventory is exactly what arrives in the other,
##     so the units of every definition are conserved;
##   - each inventory must fit what comes in AFTER what it gives has left:
##     a slot that an offered whole stack frees can take an incoming stack,
##     so two full inventories can swap. If either cannot take everything,
##     the exchange is refused (`first_inventory_full` /
##     `second_inventory_full`) and nothing changes on either side;
##   - incoming units go into the receiving inventory's stacks of the same
##     kind first (same definition, condition and quality; lowest slot number
##     first; up to max_stack; also into the rest of a stack it gives from
##     and into stacks that arrived earlier in this exchange), and what is
##     left over of one offered stack becomes ONE stack in its lowest free
##     slot (the rule of transfer_item and try_pickup).
##
## Item instance ids (docs/14 §1: unique, never reused), per offered stack:
##   - everything merged, the giver keeps a rest: no instance arrives;
##   - everything merged, the stack is emptied: its instance is deleted and
##     its id retired;
##   - something is left over and the whole stack was offered: that instance
##     itself moves over and keeps its id;
##   - something is left over and the giver keeps a rest: the left-over
##     units become a NEW instance with a new id.
## New ids are taken before anything changes.
##
## Failure reasons, in check order: unknown_inventory, same_inventory, then
## per offer entry (first offer, then second) bad_offer, unknown_item,
## item_not_in_inventory, bad_quantity, duplicate_item; nothing_to_exchange;
## first_inventory_full / second_inventory_full; id_unavailable.
func exchange_items(first_inventory_id: String, first_gives: Array, second_inventory_id: String, second_gives: Array) -> ActionResult:
	const OPERATION: String = "exchange_items"
	if not _inventories.has(first_inventory_id):
		return _reject(REASON_UNKNOWN_INVENTORY, first_inventory_id, "", OPERATION)
	if not _inventories.has(second_inventory_id):
		return _reject(REASON_UNKNOWN_INVENTORY, second_inventory_id, "", OPERATION)
	if first_inventory_id == second_inventory_id:
		return _reject(REASON_SAME_INVENTORY, first_inventory_id, "", OPERATION)
	var inventory_ids: Array[String] = [first_inventory_id, second_inventory_id]
	var offers: Array[Array] = [first_gives, second_gives]
	# 1. The offers: rows [ItemInstance, units], and how much leaves each stack.
	var gives: Array[Array] = [[], []]
	var leaving: Dictionary[String, int] = {}
	for side: int in range(2):
		for entry: Variant in offers[side]:
			if typeof(entry) != TYPE_DICTIONARY or typeof((entry as Dictionary).get(OFFER_ITEM_ID, null)) != TYPE_STRING or typeof((entry as Dictionary).get(OFFER_QUANTITY, null)) != TYPE_INT:
				return _reject(REASON_BAD_OFFER, inventory_ids[side], "", OPERATION)
			var item_id: String = str((entry as Dictionary)[OFFER_ITEM_ID])
			var units: int = int((entry as Dictionary)[OFFER_QUANTITY])
			var item: ItemInstance = _items.get(item_id, null)
			if item == null:
				return _reject(REASON_UNKNOWN_ITEM, inventory_ids[side], item_id, OPERATION)
			# Ownership before the quantity: nothing is learnt about a stack the
			# giving inventory does not carry.
			if not _is_carried_in(item, inventory_ids[side]):
				return _reject(REASON_NOT_IN_INVENTORY, inventory_ids[side], item_id, OPERATION)
			if units < 1 or units > item.quantity:
				return _reject(REASON_BAD_QUANTITY, inventory_ids[side], item_id, OPERATION)
			if leaving.has(item_id):
				return _reject(REASON_DUPLICATE_ITEM, inventory_ids[side], item_id, OPERATION)
			leaving[item_id] = units
			gives[side].append([item, units])
	if gives[0].is_empty() and gives[1].is_empty():
		return _reject(REASON_NOTHING_TO_EXCHANGE, first_inventory_id, "", OPERATION)
	# 2. Each inventory after what it gives has left: planned stacks ("rows":
	#    {item: the instance or null for one still to be created, source: the
	#    stack its kind comes from, quantity, slot}) in slot order, and its
	#    free slots.
	var before: Array[Dictionary] = [_quantities_in(first_inventory_id), _quantities_in(second_inventory_id)]
	var rows: Array[Array] = [[], []]
	var free_slots: Array[Array] = [[], []]
	for side: int in range(2):
		var used: Dictionary[int, bool] = {}
		for item: ItemInstance in items_in_inventory(inventory_ids[side]):
			var remaining: int = item.quantity - int(leaving.get(item.item_instance_id, 0))
			if remaining < 1:
				continue
			var slot: int = slot_index_of(item.slot_id)
			used[slot] = true
			rows[side].append({"item": item, "source": item, "quantity": remaining, "slot": slot})
		rows[side].sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["slot"]) < int(b["slot"]))
		for slot: int in range(_inventories[inventory_ids[side]]):
			if not used.has(slot):
				free_slots[side].append(slot)
	# 3. What comes in, offer entry by offer entry.
	var created: Array[Dictionary] = []
	var merged_away: Array[ItemInstance] = []
	for side: int in range(2):
		for give: Array in gives[1 - side]:
			var source: ItemInstance = give[0]
			var left: int = int(give[1])
			var whole_stack: bool = left == source.quantity
			var definition: ItemDefinition = _catalog.get_definition(source.definition_id)
			var max_stack: int = definition.max_stack if definition != null else 0
			for row: Dictionary in rows[side]:
				if left == 0:
					break
				if not _stacks_with(row["source"] as ItemInstance, source) or int(row["quantity"]) >= max_stack:
					continue
				var units: int = mini(max_stack - int(row["quantity"]), left)
				row["quantity"] = int(row["quantity"]) + units
				left -= units
			if left == 0:
				if whole_stack:
					merged_away.append(source)
				continue
			if free_slots[side].is_empty():
				return _reject(REASON_FIRST_INVENTORY_FULL if side == 0 else REASON_SECOND_INVENTORY_FULL, inventory_ids[side], source.item_instance_id, OPERATION)
			var arrived: Dictionary = {"item": source if whole_stack else null, "source": source, "quantity": left, "slot": int(free_slots[side].pop_front())}
			var at: int = 0
			while at < rows[side].size() and int((rows[side][at] as Dictionary)["slot"]) < int(arrived["slot"]):
				at += 1
			rows[side].insert(at, arrived)
			if not whole_stack:
				created.append(arrived)
	# 4. The one thing that could still fail: ids for the new stacks. Taken
	#    before anything changes.
	for row: Dictionary in created:
		var new_id: String = _ids.next_id(ENTITY_KIND_ITEM)
		if new_id.is_empty() or _registry.has(new_id) or _registry.is_tombstoned(new_id):
			GameLogger.error("inventory", "no id for an exchanged stack", {"inventory_id": first_inventory_id, "to_inventory_id": second_inventory_id, "operation": OPERATION})
			return _reject(REASON_ID_UNAVAILABLE, first_inventory_id, "", OPERATION)
		row["new_id"] = new_id
	for row: Dictionary in created:
		if _registry.register(str(row["new_id"]), ENTITY_KIND_ITEM) != OK:
			GameLogger.error("inventory", "id of an exchanged stack could not be registered", {"entity_id": str(row["new_id"]), "operation": OPERATION})
			return _reject(REASON_ID_UNAVAILABLE, first_inventory_id, "", OPERATION)

	# Commit: every check passed, apply all changes together.
	var gave: Array[Array] = [[], []]
	for side: int in range(2):
		for give: Array in gives[side]:
			var given: ItemInstance = give[0]
			gave[side].append({"item_instance_id": given.item_instance_id, "definition_id": given.definition_id, "quantity": int(give[1])})
	for side: int in range(2):
		for row: Dictionary in rows[side]:
			var item: ItemInstance = row["item"]
			if item == null:
				var source: ItemInstance = row["source"]
				item = ItemInstance.new()
				item.item_instance_id = str(row["new_id"])
				item.definition_id = source.definition_id
				item.condition = source.condition
				item.quality = source.quality
				_items[item.item_instance_id] = item
			item.quantity = int(row["quantity"])
			item.location_type = ItemInstance.LOCATION_INVENTORY
			item.location_id = inventory_ids[side]
			item.slot_id = "%s%d" % [SLOT_PREFIX, int(row["slot"])]
	for item: ItemInstance in merged_away:
		_items.erase(item.item_instance_id)
		if _registry.remove(item.item_instance_id) != OK:
			GameLogger.error("inventory", "exchanged item was not registered", {"entity_id": item.item_instance_id, "operation": OPERATION})
	var sides: Array = []
	for side: int in range(2):
		var now: Dictionary[String, int] = _quantities_in(inventory_ids[side])
		var removed: Array = []
		for item_id: String in before[side]:
			if not now.has(item_id):
				removed.append(item_id)
		removed.sort()
		var changed: Array = []
		for row: Dictionary in rows[side]:
			var held_id: String = (row["item"] as ItemInstance).item_instance_id if row["item"] != null else str(row["new_id"])
			if int(before[side].get(held_id, 0)) != int(now.get(held_id, 0)):
				changed.append(held_id)
		sides.append({"inventory_id": inventory_ids[side], "gave": gave[side], "removed_item_instance_ids": removed, "changed_item_instance_ids": changed})
	GameLogger.info("inventory", "items exchanged", {"inventory_id": first_inventory_id, "to_inventory_id": second_inventory_id, "first_gave": gave[0].size(), "second_gave": gave[1].size()})
	return _commit({"event_type": EVENT_ITEMS_EXCHANGED, "sides": sides})


## Takes units of carried stacks out of `inventory_id` in one transaction
## (P3-5: a player delivers building materials). `takes` is an Array of
## {item_instance_id: String, quantity: int (1..the stack)}; every entry
## must name a different stack carried in that inventory. All or nothing: on
## any refusal nothing changes. A stack that still holds something only gets
## smaller; an emptied one is deleted and its id retired (docs/14 §1).
## The units are not items any more afterwards: the caller keeps count of
## them (BuildingService: StructureInstance.delivered_materials) and gives
## them back with place_world_items. Event: EVENT_ITEMS_TAKEN.
## Failures: unknown_inventory, nothing_to_move, bad_offer, duplicate_item,
## unknown_item, item_not_in_inventory, bad_quantity.
func take_items(inventory_id: String, takes: Array) -> ActionResult:
	const OPERATION: String = "take_items"
	if not _inventories.has(inventory_id):
		return _reject(REASON_UNKNOWN_INVENTORY, inventory_id, "", OPERATION)
	if takes.is_empty():
		return _reject(REASON_NOTHING_TO_MOVE, inventory_id, "", OPERATION)
	var seen: Dictionary[String, bool] = {}
	var planned: Array[Array] = []
	for entry: Variant in takes:
		if typeof(entry) != TYPE_DICTIONARY or typeof((entry as Dictionary).get(OFFER_ITEM_ID, null)) != TYPE_STRING or typeof((entry as Dictionary).get(OFFER_QUANTITY, null)) != TYPE_INT:
			return _reject(REASON_BAD_OFFER, inventory_id, "", OPERATION)
		var item_id: String = (entry as Dictionary)[OFFER_ITEM_ID]
		var quantity: int = (entry as Dictionary)[OFFER_QUANTITY]
		if seen.has(item_id):
			return _reject(REASON_DUPLICATE_ITEM, inventory_id, item_id, OPERATION)
		seen[item_id] = true
		var item: ItemInstance = _items.get(item_id, null)
		if item == null:
			return _reject(REASON_UNKNOWN_ITEM, inventory_id, item_id, OPERATION)
		if not _is_carried_in(item, inventory_id):
			return _reject(REASON_NOT_IN_INVENTORY, inventory_id, item_id, OPERATION)
		if quantity < 1 or quantity > item.quantity:
			return _reject(REASON_BAD_QUANTITY, inventory_id, item_id, OPERATION)
		planned.append([item, quantity])

	# Commit: every check passed.
	var taken: Array = []
	for row: Array in planned:
		var item: ItemInstance = row[0]
		var quantity: int = row[1]
		var remaining: int = item.quantity - quantity
		if remaining > 0:
			item.quantity = remaining
		else:
			_items.erase(item.item_instance_id)
			if _registry.remove(item.item_instance_id) != OK:
				GameLogger.error("inventory", "taken item was not registered", {"entity_id": item.item_instance_id, "inventory_id": inventory_id, "operation": OPERATION})
		taken.append({"item_instance_id": item.item_instance_id, "definition_id": item.definition_id, "quantity": quantity, "remaining_quantity": remaining})
	GameLogger.info("inventory", "items taken", {"inventory_id": inventory_id, "stacks": taken.size()})
	return _commit({"event_type": EVENT_ITEMS_TAKEN, "inventory_id": inventory_id, "taken": taken})


## Puts new items into the world at `position` in `cell_id` that did not
## come out of an inventory (P3-5: the materials a cancelled or demolished
## structure returns). `quantities` maps item definition id -> units (>= 1);
## each kind becomes as few stacks as its max_stack allows, in the order of
## the sorted definition ids. All or nothing. The new items are in the cell
## index like any dropped item. Event: EVENT_ITEMS_DROPPED with
## `inventory_id` "" (no inventory lost anything) and, in addition,
## `placed`: Array of {item_instance_id, definition_id, quantity}; so
## InventoryNetModule announces them to the clients exactly like a drop.
## Failures: nothing_to_move, unknown_item_definition, bad_quantity,
## bad_cell, bad_position, id_unavailable.
func place_world_items(quantities: Dictionary, cell_id: String, position: Vector3) -> ActionResult:
	const OPERATION: String = "place_world_items"
	if quantities.is_empty():
		return _reject(REASON_NOTHING_TO_MOVE, "", "", OPERATION)
	var place_error: String = _validate_world_place(cell_id, position)
	if not place_error.is_empty():
		return _reject(place_error, "", "", OPERATION)
	var definition_ids: PackedStringArray = []
	for key: Variant in quantities:
		if typeof(key) != TYPE_STRING or not _catalog.has(str(key)):
			return _reject(REASON_UNKNOWN_DEFINITION, "", str(key), OPERATION)
		if typeof(quantities[key]) != TYPE_INT or int(quantities[key]) < 1:
			return _reject(REASON_BAD_QUANTITY, "", str(key), OPERATION)
		definition_ids.append(str(key))
	definition_ids.sort()
	# Stacks to make: [definition_id, units].
	var stacks: Array[Array] = []
	for definition_id: String in definition_ids:
		var max_stack: int = _catalog.get_definition(definition_id).max_stack
		var left: int = quantities[definition_id]
		while left > 0:
			var units: int = mini(left, max_stack)
			stacks.append([definition_id, units])
			left -= units
	# The one thing that could still fail are the new ids: taken before
	# anything changes, and given back when one of them fails.
	var new_ids: PackedStringArray = []
	for index: int in range(stacks.size()):
		var new_id: String = _ids.next_id(ENTITY_KIND_ITEM)
		if new_id.is_empty() or _registry.register(new_id, ENTITY_KIND_ITEM) != OK:
			for registered: String in new_ids:
				_registry.release(registered)
			GameLogger.error("inventory", "no id for an item placed in the world", {"cell_id": cell_id, "operation": OPERATION})
			return _reject(REASON_ID_UNAVAILABLE, "", "", OPERATION)
		new_ids.append(new_id)

	# Commit: nothing below can fail.
	var placed: Array = []
	for index: int in range(stacks.size()):
		var item: ItemInstance = ItemInstance.new()
		item.item_instance_id = new_ids[index]
		item.definition_id = stacks[index][0]
		item.quantity = stacks[index][1]
		_items[item.item_instance_id] = item
		_move_to_world(item, cell_id, position)
		placed.append({"item_instance_id": item.item_instance_id, "definition_id": item.definition_id, "quantity": item.quantity})
	GameLogger.info("inventory", "items placed in the world", {"cell_id": cell_id, "items": placed.size()})
	var event: Dictionary = _dropped_event("", Array(new_ids), cell_id, position)
	event["placed"] = placed
	return _commit(event)


## item_instance_id -> quantity of everything carried in an inventory.
func _quantities_in(inventory_id: String) -> Dictionary[String, int]:
	var quantities: Dictionary[String, int] = {}
	for item: ItemInstance in items_in_inventory(inventory_id):
		quantities[item.item_instance_id] = item.quantity
	return quantities


## Number of a slot id ("slot_7" -> 7).
static func slot_index_of(slot_id: String) -> int:
	return slot_id.trim_prefix(SLOT_PREFIX).to_int()


func get_item(item_instance_id: String) -> ItemInstance:
	return _items.get(item_instance_id, null)


## Static definition of an existing item instance (null when the item or its
## definition is unknown). Read-only.
func definition_of(item_instance_id: String) -> ItemDefinition:
	var item: ItemInstance = _items.get(item_instance_id, null)
	return null if item == null else _catalog.get_definition(item.definition_id)


func has_inventory(inventory_id: String) -> bool:
	return _inventories.has(inventory_id)


## Number of item instances that exist (lying in the world or carried).
func item_count() -> int:
	return _items.size()


## Items held in an inventory, sorted by slot.
func items_in_inventory(inventory_id: String) -> Array[ItemInstance]:
	var result: Array[ItemInstance] = []
	for item: ItemInstance in _items.values():
		if item.location_type == ItemInstance.LOCATION_INVENTORY and item.location_id == inventory_id:
			result.append(item)
	result.sort_custom(func(a: ItemInstance, b: ItemInstance) -> bool: return a.slot_id < b.slot_id)
	return result


## Ids of items lying in the world, sorted.
func world_item_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_world_positions.keys())
	ids.sort()
	return ids


func world_position_of(item_instance_id: String) -> Vector3:
	return _world_positions.get(item_instance_id, Vector3.ZERO)


## Network/presentation view of one world item (no internal references).
func describe_world_item(item_instance_id: String) -> Dictionary:
	var item: ItemInstance = _items[item_instance_id]
	return {
		"item_instance_id": item.item_instance_id,
		"definition_id": item.definition_id,
		"quantity": item.quantity,
		"position": _world_positions[item_instance_id],
	}


## Ids of the world items in memory that lie in one cell, sorted.
func world_item_ids_in_cell(cell_id: String) -> PackedStringArray:
	return _cell_index.entities_in_cell(cell_id, ENTITY_KIND_ITEM)


## Save data of the world items of one cell: {items: [ItemInstance.to_dict()],
## world_item_positions: {id: [x, y, z]}}, sorted by id. {} for a cell
## without world items.
func cell_snapshot(cell_id: String) -> Dictionary:
	var item_ids: PackedStringArray = world_item_ids_in_cell(cell_id)
	if item_ids.is_empty():
		return {}
	var items: Array[Dictionary] = []
	var positions: Dictionary = {}
	for item_id: String in item_ids:
		items.append(_items[item_id].to_dict())
		var p: Vector3 = _world_positions[item_id]
		positions[item_id] = [p.x, p.y, p.z]
	return {SNAPSHOT_ITEMS: items, SNAPSHOT_POSITIONS: positions}


## Brings the saved world items of a cell (cell_snapshot) back into memory:
## the same ids, definitions, stacks and positions. Everything is validated
## first; on any error nothing changes and the errors are returned.
##
## The item in memory wins over its saved copy (docs/03 §6: loading a cell
## never creates an item a second time): an entry whose id is already in
## memory (it was picked up, or it is a world item that never left memory)
## or whose id was retired (the item was used up) is skipped and logged. This
## only happens when a cell file is older than the rest of the save (it was
## restored from a backup).
func restore_cell_snapshot(cell_id: String, snapshot: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if cell_id.is_empty():
		return PackedStringArray(["cell id is empty"])
	var items: Variant = snapshot.get(SNAPSHOT_ITEMS, [])
	var positions: Variant = snapshot.get(SNAPSHOT_POSITIONS, {})
	if typeof(items) != TYPE_ARRAY or typeof(positions) != TYPE_DICTIONARY:
		return PackedStringArray(["cell %s: items must be an array and world_item_positions an object" % cell_id])
	var new_items: Dictionary[String, ItemInstance] = {}
	var new_positions: Dictionary[String, Vector3] = {}
	var skipped: PackedStringArray = []
	for entry: Variant in (items as Array):
		var item: ItemInstance = ItemInstance.from_dict(entry as Dictionary) if typeof(entry) == TYPE_DICTIONARY else null
		if item == null:
			errors.append("cell %s: invalid item entry" % cell_id)
			continue
		var item_id: String = item.item_instance_id
		if new_items.has(item_id) or skipped.has(item_id):
			errors.append("cell %s: duplicate item id %s" % [cell_id, item_id])
			continue
		if _items.has(item_id) or _registry.has(item_id) or _registry.is_tombstoned(item_id):
			skipped.append(item_id)
			continue
		if item.location_type != ItemInstance.LOCATION_WORLD:
			errors.append("cell %s: item %s does not lie in the world" % [cell_id, item_id])
		if not _catalog.has(item.definition_id):
			errors.append("cell %s: unknown definition %s for %s" % [cell_id, item.definition_id, item_id])
		var position: Variant = _position_from((positions as Dictionary).get(item_id, null))
		if position == null:
			errors.append("cell %s: bad or missing position for %s" % [cell_id, item_id])
			continue
		new_items[item_id] = item
		new_positions[item_id] = position
	if (positions as Dictionary).size() != (items as Array).size():
		errors.append("cell %s: world_item_positions does not match items" % cell_id)
	if not errors.is_empty():
		return errors
	if not skipped.is_empty():
		GameLogger.warning("inventory", "saved world items skipped: already in memory or removed", {"cell_id": cell_id, "items": ", ".join(skipped), "operation": "restore_cell"})
	for item_id: String in new_items:
		var item: ItemInstance = new_items[item_id]
		item.location_id = cell_id
		item.slot_id = ""
		_items[item_id] = item
		_world_positions[item_id] = new_positions[item_id]
		_ids.reserve_existing_id(item_id)
		_registry.register(item_id, ENTITY_KIND_ITEM)
		_index_world_item(item)
	return errors


## Forgets the world items of a cell (call only after they were saved,
## CLAUDE.md §6). Their ids are released, not retired: the items still exist
## in the save and come back with restore_cell_snapshot(). Returns how many
## items left memory.
func release_cell(cell_id: String) -> int:
	var item_ids: PackedStringArray = world_item_ids_in_cell(cell_id)
	for item_id: String in item_ids:
		_items.erase(item_id)
		_world_positions.erase(item_id)
		_cell_index.remove(item_id)
		_registry.release(item_id)
	return item_ids.size()


## Gives every world item in memory the cell `resolver` (Callable(Vector3)
## -> String) names for its position. For saves whose cell ids were written
## for another grid, or before cells existed (P3-1: every item said
## "cell_0_0"). Returns how many items changed their cell.
func reassign_world_item_cells(resolver: Callable) -> int:
	var changed: int = 0
	for item_id: String in _world_positions:
		var item: ItemInstance = _items[item_id]
		var cell_id: String = str(resolver.call(_world_positions[item_id]))
		if cell_id.is_empty() or cell_id == item.location_id:
			continue
		item.location_id = cell_id
		_index_world_item(item)
		changed += 1
	return changed


# ---------------------------------------------------- detached inventories
# P3-3 (docs/09 §15.3). A detached inventory belongs to an entity standing in
# the world (a container), not to a player. It is an inventory like any
# other for the transactions (transfer_item between a player's inventory and
# a container's inventory IS "put in" / "take out", with the merging and the
# all-or-nothing rule of every transfer), but its owner saves it and takes it
# out of memory:
#   create_detached_inventory    a new, empty one
#   spawn_detached_item          a new item inside one (loot)
#   detached_snapshot            its capacity and items, as save data
#   check_detached_snapshot      errors of such save data (changes nothing)
#   restore_detached_snapshot    brings one back with its saved id and items
#   release_detached_inventory   forgets one and its items (after a save)
# to_snapshot() leaves detached inventories and their items out. None of
# these six announces anything through `transaction_committed`: no item
# changed hands.

## Key of detached_snapshot(): the slot capacity.
const DETACHED_CAPACITY: String = "capacity"
## inventory_id -> true for every detached inventory in memory.
var _detached: Dictionary[String, bool] = {}


## Creates an empty detached inventory and returns its id ("" on failure).
func create_detached_inventory(capacity: int) -> String:
	var inventory_id: String = create_inventory(capacity)
	if not inventory_id.is_empty():
		_detached[inventory_id] = true
	return inventory_id


func is_detached_inventory(inventory_id: String) -> bool:
	return _detached.has(inventory_id)


## Creates a new item in the first free slot of a detached inventory (it
## does not join another stack). Returns its id, "" when the definition is
## unknown, the quantity is no stack of it, or the inventory is no detached
## one or has no free slot.
func spawn_detached_item(inventory_id: String, definition_id: String, quantity: int) -> String:
	const OPERATION: String = "spawn_detached_item"
	var definition: ItemDefinition = _catalog.get_definition(definition_id)
	if not _detached.has(inventory_id) or definition == null or quantity < 1 or quantity > definition.max_stack:
		GameLogger.error("inventory", "item cannot be created in this inventory", {"inventory_id": inventory_id, "definition_id": definition_id, "quantity": quantity, "operation": OPERATION})
		return ""
	var slot_id: String = _first_free_slot(inventory_id)
	if slot_id.is_empty():
		return ""
	var item: ItemInstance = ItemInstance.new()
	item.item_instance_id = _ids.next_id(ENTITY_KIND_ITEM)
	item.definition_id = definition_id
	item.quantity = quantity
	item.location_type = ItemInstance.LOCATION_INVENTORY
	item.location_id = inventory_id
	item.slot_id = slot_id
	if _registry.register(item.item_instance_id, ENTITY_KIND_ITEM) != OK:
		return ""
	_items[item.item_instance_id] = item
	return item.item_instance_id


## Save data of one detached inventory: {capacity: int, items:
## [ItemInstance.to_dict()]} in slot order. {} when it is none.
func detached_snapshot(inventory_id: String) -> Dictionary:
	if not _detached.has(inventory_id):
		return {}
	var held: Array[ItemInstance] = items_in_inventory(inventory_id)
	held.sort_custom(func(a: ItemInstance, b: ItemInstance) -> bool: return slot_index_of(a.slot_id) < slot_index_of(b.slot_id))
	var items: Array[Dictionary] = []
	for item: ItemInstance in held:
		items.append(item.to_dict())
	return {DETACHED_CAPACITY: _inventories[inventory_id], SNAPSHOT_ITEMS: items}


## Errors of the save data of a detached inventory (detached_snapshot) that
## is to come back as `inventory_id`; empty = restore_detached_snapshot will
## accept it. Changes nothing.
func check_detached_snapshot(inventory_id: String, snapshot: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if inventory_id.is_empty() or _inventories.has(inventory_id) or _registry.has(inventory_id) or _registry.is_tombstoned(inventory_id):
		return PackedStringArray(["inventory %s is empty, in memory or removed" % inventory_id])
	var capacity: Variant = snapshot.get(DETACHED_CAPACITY, null)
	var items: Variant = snapshot.get(SNAPSHOT_ITEMS, null)
	if not ItemInstance.is_integer_value(capacity) or int(capacity) < 1 or typeof(items) != TYPE_ARRAY:
		return PackedStringArray(["inventory %s: capacity must be >= 1 and items an array" % inventory_id])
	var seen_ids: Dictionary[String, bool] = {}
	var seen_slots: Dictionary[int, bool] = {}
	for entry: Variant in (items as Array):
		var item: ItemInstance = ItemInstance.from_dict(entry as Dictionary) if typeof(entry) == TYPE_DICTIONARY else null
		if item == null:
			errors.append("inventory %s: invalid item entry" % inventory_id)
			continue
		var slot: int = slot_index_of(item.slot_id) if item.slot_id.begins_with(SLOT_PREFIX) and item.slot_id.trim_prefix(SLOT_PREFIX).is_valid_int() else -1
		if item.location_type != ItemInstance.LOCATION_INVENTORY or item.location_id != inventory_id:
			errors.append("inventory %s: item %s is not in it" % [inventory_id, item.item_instance_id])
		elif slot < 0 or slot >= int(capacity) or seen_slots.has(slot):
			errors.append("inventory %s: bad or doubled slot of %s" % [inventory_id, item.item_instance_id])
		elif seen_ids.has(item.item_instance_id):
			errors.append("inventory %s: duplicate item id %s" % [inventory_id, item.item_instance_id])
		elif not _catalog.has(item.definition_id):
			errors.append("inventory %s: unknown definition %s for %s" % [inventory_id, item.definition_id, item.item_instance_id])
		seen_ids[item.item_instance_id] = true
		seen_slots[slot] = true
	return errors


## Brings a saved detached inventory (detached_snapshot) back into memory
## under its saved id, with the same item ids, stacks and slots. Everything
## is validated first (check_detached_snapshot); on any error nothing
## changes and the errors are returned.
##
## The item in memory wins over its saved copy, as in restore_cell_snapshot:
## an item whose id is already in memory (somebody took it out) or was
## retired (it merged away or was used up) is skipped and logged. This only
## happens when the save data is older than the rest of the save.
func restore_detached_snapshot(inventory_id: String, snapshot: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = check_detached_snapshot(inventory_id, snapshot)
	if not errors.is_empty():
		return errors
	_inventories[inventory_id] = int(snapshot[DETACHED_CAPACITY])
	_detached[inventory_id] = true
	_ids.reserve_existing_id(inventory_id)
	_registry.register(inventory_id, ENTITY_KIND_INVENTORY)
	var skipped: PackedStringArray = []
	for entry: Variant in (snapshot[SNAPSHOT_ITEMS] as Array):
		var item: ItemInstance = ItemInstance.from_dict(entry as Dictionary)
		var item_id: String = item.item_instance_id
		if _items.has(item_id) or _registry.has(item_id) or _registry.is_tombstoned(item_id):
			skipped.append(item_id)
			continue
		_items[item_id] = item
		_ids.reserve_existing_id(item_id)
		_registry.register(item_id, ENTITY_KIND_ITEM)
	if not skipped.is_empty():
		GameLogger.warning("inventory", "saved container items skipped: already in memory or removed", {"inventory_id": inventory_id, "items": ", ".join(skipped), "operation": "restore_detached"})
	return errors


## Forgets a detached inventory and the items in it (call only after they
## were saved, CLAUDE.md §6). The ids are released, not retired: everything
## still exists in the save and comes back with restore_detached_snapshot().
## Returns how many items left memory.
func release_detached_inventory(inventory_id: String) -> int:
	if not _detached.has(inventory_id):
		return 0
	var held: Array[ItemInstance] = items_in_inventory(inventory_id)
	for item: ItemInstance in held:
		_items.erase(item.item_instance_id)
		_registry.release(item.item_instance_id)
	_inventories.erase(inventory_id)
	_detached.erase(inventory_id)
	_registry.release(inventory_id)
	return held.size()


## Plain-data snapshot for saving (sorted, deterministic). `saved_with_cell`
## (Callable(cell_id: String) -> bool, P3-1) names the cells whose world
## items are saved in a document of their own (cell_snapshot): those items
## are left out here. Without it every item is in the snapshot. Detached
## inventories and their items are never in it (P3-3: their owner saves
## them).
func to_snapshot(saved_with_cell: Callable = Callable()) -> Dictionary:
	var item_ids: PackedStringArray = PackedStringArray(_items.keys())
	item_ids.sort()
	var items: Array[Dictionary] = []
	var positions: Dictionary = {}
	for item_id: String in item_ids:
		var item: ItemInstance = _items[item_id]
		var in_world: bool = _world_positions.has(item_id)
		if in_world and saved_with_cell.is_valid() and bool(saved_with_cell.call(item.location_id)):
			continue
		if not in_world and _detached.has(item.location_id):
			continue
		items.append(item.to_dict())
		if in_world:
			var p: Vector3 = _world_positions[item_id]
			positions[item_id] = [p.x, p.y, p.z]
	var inventories: Dictionary = {}
	for inventory_id: String in _inventories:
		if not _detached.has(inventory_id):
			inventories[inventory_id] = _inventories[inventory_id]
	return {SNAPSHOT_ITEMS: items, SNAPSHOT_POSITIONS: positions, SNAPSHOT_INVENTORIES: inventories}


## Replaces all state from a snapshot. Validates everything first; on any
## error nothing is changed and the errors are returned.
func restore_snapshot(snapshot: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	var new_items: Dictionary[String, ItemInstance] = {}
	var new_positions: Dictionary[String, Vector3] = {}
	var new_inventories: Dictionary[String, int] = {}

	var inventories: Variant = snapshot.get(SNAPSHOT_INVENTORIES, {})
	if typeof(inventories) != TYPE_DICTIONARY:
		return PackedStringArray(["inventories must be an object"])
	for key: Variant in (inventories as Dictionary):
		var capacity: Variant = (inventories as Dictionary)[key]
		if not ItemInstance.is_integer_value(capacity) or int(capacity) < 1:
			errors.append("inventory %s has invalid capacity" % str(key))
			continue
		new_inventories[str(key)] = int(capacity)

	var items: Variant = snapshot.get(SNAPSHOT_ITEMS, [])
	if typeof(items) != TYPE_ARRAY:
		return PackedStringArray(["items must be an array"])
	for entry: Variant in (items as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			errors.append("item entry is not an object")
			continue
		var item: ItemInstance = ItemInstance.from_dict(entry as Dictionary)
		if item == null:
			errors.append("invalid item entry")
			continue
		if new_items.has(item.item_instance_id):
			errors.append("duplicate item id " + item.item_instance_id)
			continue
		if not _catalog.has(item.definition_id):
			errors.append("unknown definition %s for %s" % [item.definition_id, item.item_instance_id])
		if item.location_type == ItemInstance.LOCATION_INVENTORY and not new_inventories.has(item.location_id):
			errors.append("item %s references missing inventory %s" % [item.item_instance_id, item.location_id])
		new_items[item.item_instance_id] = item

	var positions: Variant = snapshot.get(SNAPSHOT_POSITIONS, {})
	if typeof(positions) != TYPE_DICTIONARY:
		return PackedStringArray(["world_item_positions must be an object"])
	for key: Variant in (positions as Dictionary):
		var position: Vector3 = Vector3.ZERO
		var raw: Variant = (positions as Dictionary)[key]
		if typeof(raw) != TYPE_ARRAY or (raw as Array).size() != 3:
			errors.append("bad position for " + str(key))
			continue
		position = Vector3(float((raw as Array)[0]), float((raw as Array)[1]), float((raw as Array)[2]))
		new_positions[str(key)] = position
	for item_id: String in new_items:
		var is_world: bool = new_items[item_id].location_type == ItemInstance.LOCATION_WORLD
		if is_world != new_positions.has(item_id):
			errors.append("world position mismatch for " + item_id)

	if not errors.is_empty():
		return errors
	_items = new_items
	_world_positions = new_positions
	_inventories = new_inventories
	_detached.clear()
	for inventory_id: String in _inventories:
		_ids.reserve_existing_id(inventory_id)
		if not _registry.has(inventory_id):
			_registry.register(inventory_id, ENTITY_KIND_INVENTORY)
	_cell_index.remove_kind(ENTITY_KIND_ITEM)
	for item_id: String in _items:
		_ids.reserve_existing_id(item_id)
		if not _registry.has(item_id):
			_registry.register(item_id, ENTITY_KIND_ITEM)
		if _world_positions.has(item_id):
			_index_world_item(_items[item_id])
	return errors


func _first_free_slot(inventory_id: String) -> String:
	var used: Dictionary[String, bool] = {}
	for item: ItemInstance in items_in_inventory(inventory_id):
		used[item.slot_id] = true
	for index: int in range(_inventories[inventory_id]):
		var slot_id: String = "%s%d" % [SLOT_PREFIX, index]
		if not used.has(slot_id):
			return slot_id
	return ""


func _is_carried_in(item: ItemInstance, inventory_id: String) -> bool:
	return item.location_type == ItemInstance.LOCATION_INVENTORY and item.location_id == inventory_id


## True when the units of `incoming` may join the stack `stack`: the same
## definition, condition and quality (units that differ stay apart, so no
## unit's condition is averaged away).
func _stacks_with(stack: ItemInstance, incoming: ItemInstance) -> bool:
	return (
		stack.definition_id == incoming.definition_id
		and is_equal_approx(stack.condition, incoming.condition)
		and is_equal_approx(stack.quality, incoming.quality)
	)


## Plans where `quantity` units of `incoming` go among the stacks carried in
## `inventory_id`: the stacks of the same kind (_stacks_with) that have room,
## lowest slot number first, each up to the definition's max_stack. Returns
## rows [ItemInstance, units]; the units no stack takes are
## `quantity - _filled_units(rows)`. Changes nothing.
func _plan_fills(inventory_id: String, incoming: ItemInstance, quantity: int) -> Array[Array]:
	var definition: ItemDefinition = _catalog.get_definition(incoming.definition_id)
	var max_stack: int = definition.max_stack if definition != null else 0
	var left: int = quantity
	var fills: Array[Array] = []
	# By slot number (items_in_inventory sorts slot ids as text: "slot_10"
	# before "slot_2").
	var stacks: Array[ItemInstance] = items_in_inventory(inventory_id)
	stacks.sort_custom(func(a: ItemInstance, b: ItemInstance) -> bool: return slot_index_of(a.slot_id) < slot_index_of(b.slot_id))
	for stack: ItemInstance in stacks:
		if left == 0:
			break
		if stack == incoming or not _stacks_with(stack, incoming) or stack.quantity >= max_stack:
			continue
		var units: int = mini(max_stack - stack.quantity, left)
		fills.append([stack, units])
		left -= units
	return fills


## Units a plan of _plan_fills puts into existing stacks.
func _filled_units(fills: Array[Array]) -> int:
	var total: int = 0
	for fill: Array in fills:
		total += int(fill[1])
	return total


## Applies a plan of _plan_fills. Returns [{item_instance_id, quantity}] of
## the stacks that grew, in plan order.
func _apply_fills(fills: Array[Array]) -> Array:
	var grown: Array = []
	for fill: Array in fills:
		var stack: ItemInstance = fill[0]
		stack.quantity += int(fill[1])
		grown.append({"item_instance_id": stack.item_instance_id, "quantity": int(fill[1])})
	return grown


## "" when an item may be put down at `position` in `cell_id`, else a reason.
func _validate_world_place(cell_id: String, position: Vector3) -> String:
	if cell_id.is_empty():
		return REASON_BAD_CELL
	if not position.is_finite() or absf(position.x) > _world_half_extent_m or absf(position.z) > _world_half_extent_m:
		return REASON_BAD_POSITION
	return ""


func _move_to_world(item: ItemInstance, cell_id: String, position: Vector3) -> void:
	item.location_type = ItemInstance.LOCATION_WORLD
	item.location_id = cell_id
	item.slot_id = ""
	_world_positions[item.item_instance_id] = position
	_index_world_item(item)


## Puts a world item into the cell index under its `location_id`. An item
## without a cell id (never written by the server rules) stays unindexed.
func _index_world_item(item: ItemInstance) -> void:
	if not item.location_id.is_empty():
		_cell_index.put(item.item_instance_id, ENTITY_KIND_ITEM, item.location_id)


## Vector3 for a saved [x, y, z] array of finite numbers, or null.
static func _position_from(value: Variant) -> Variant:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 3:
		return null
	for component: Variant in (value as Array):
		if not (typeof(component) == TYPE_FLOAT or typeof(component) == TYPE_INT) or not is_finite(float(component)):
			return null
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _dropped_event(inventory_id: String, item_instance_ids: Array, cell_id: String, position: Vector3) -> Dictionary:
	return {
		"event_type": EVENT_ITEMS_DROPPED,
		"inventory_id": inventory_id,
		"item_instance_ids": item_instance_ids,
		"cell_id": cell_id,
		"position": [position.x, position.y, position.z],
	}


## Announces a committed transaction and wraps it as the command result.
## Listeners get their own copy, so they cannot alter the caller's result.
func _commit(event: Dictionary) -> ActionResult:
	var from_cell_id: String = str(event.get("from_cell_id", ""))
	var cell_id: String = str(event.get("cell_id", ""))
	if not from_cell_id.is_empty():
		cell_save_dirty.emit(from_cell_id)
	if not cell_id.is_empty() and cell_id != from_cell_id:
		cell_save_dirty.emit(cell_id)
	transaction_committed.emit(event.duplicate(true))
	return ActionResult.success(event)


func _reject(reason: String, inventory_id: String, item_instance_id: String, operation: String = "try_pickup") -> ActionResult:
	var message: String = "pickup rejected" if operation == "try_pickup" else "item transaction rejected"
	GameLogger.info("inventory", message, {"entity_id": item_instance_id, "inventory_id": inventory_id, "reason": reason, "operation": operation})
	return ActionResult.failure(reason)
