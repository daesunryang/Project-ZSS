class_name InventoryService
extends RefCounted
## Server-authoritative item state and transactions (docs/08 §8, docs/14 §6).
##
## Owns every ItemInstance, the world positions of items lying in the world,
## and player inventories. All mutations go through methods here and are
## all-or-nothing: a failed command changes nothing. Requests are processed
## in call order, so of two concurrent pickups of the same item only the
## first one succeeds. No Node references; fully unit-testable.

const ENTITY_KIND_ITEM: String = "item"
const ENTITY_KIND_INVENTORY: String = "inventory"
const SLOT_PREFIX: String = "slot_"
const EVENT_ITEM_PICKED_UP: String = "item_picked_up"

## Failure reason codes (stable, sent to clients).
const REASON_UNKNOWN_INVENTORY: String = "unknown_inventory"
const REASON_UNKNOWN_ITEM: String = "unknown_item"
const REASON_NOT_IN_WORLD: String = "item_not_in_world"
const REASON_TOO_FAR: String = "too_far"
const REASON_INVENTORY_FULL: String = "inventory_full"

const SNAPSHOT_ITEMS: String = "items"
const SNAPSHOT_POSITIONS: String = "world_item_positions"
const SNAPSHOT_INVENTORIES: String = "inventories"

var _catalog: ItemCatalog
var _ids: EntityIdGenerator
var _registry: EntityRegistry
var _pickup_range_m: float
var _items: Dictionary[String, ItemInstance] = {}
var _world_positions: Dictionary[String, Vector3] = {}
## inventory_id -> slot capacity
var _inventories: Dictionary[String, int] = {}


func _init(catalog: ItemCatalog, ids: EntityIdGenerator, registry: EntityRegistry, pickup_range_m: float) -> void:
	_catalog = catalog
	_ids = ids
	_registry = registry
	_pickup_range_m = pickup_range_m


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
	return item.item_instance_id


## Moves a world item into `inventory_id` if the actor (at the server-known
## `actor_position`) is within range and there is a free slot.
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
	var slot_id: String = _first_free_slot(inventory_id)
	if slot_id.is_empty():
		return _reject(REASON_INVENTORY_FULL, inventory_id, item_instance_id)

	# Commit: every check passed, apply all changes together.
	var from_cell: String = item.location_id
	item.location_type = ItemInstance.LOCATION_INVENTORY
	item.location_id = inventory_id
	item.slot_id = slot_id
	_world_positions.erase(item_instance_id)
	GameLogger.info("inventory", "item picked up", {"entity_id": item_instance_id, "inventory_id": inventory_id, "slot_id": slot_id})
	return ActionResult.success({
		"event_type": EVENT_ITEM_PICKED_UP,
		"item_instance_id": item_instance_id,
		"inventory_id": inventory_id,
		"slot_id": slot_id,
		"from_cell_id": from_cell,
	})


func get_item(item_instance_id: String) -> ItemInstance:
	return _items.get(item_instance_id, null)


func has_inventory(inventory_id: String) -> bool:
	return _inventories.has(inventory_id)


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


## Plain-data snapshot for saving (sorted, deterministic).
func to_snapshot() -> Dictionary:
	var item_ids: PackedStringArray = PackedStringArray(_items.keys())
	item_ids.sort()
	var items: Array[Dictionary] = []
	for item_id: String in item_ids:
		items.append(_items[item_id].to_dict())
	var positions: Dictionary = {}
	for item_id: String in world_item_ids():
		var p: Vector3 = _world_positions[item_id]
		positions[item_id] = [p.x, p.y, p.z]
	var inventories: Dictionary = {}
	for inventory_id: String in _inventories:
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
	for inventory_id: String in _inventories:
		_ids.reserve_existing_id(inventory_id)
		if not _registry.has(inventory_id):
			_registry.register(inventory_id, ENTITY_KIND_INVENTORY)
	for item_id: String in _items:
		_ids.reserve_existing_id(item_id)
		if not _registry.has(item_id):
			_registry.register(item_id, ENTITY_KIND_ITEM)
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


func _reject(reason: String, inventory_id: String, item_instance_id: String) -> ActionResult:
	GameLogger.info("inventory", "pickup rejected", {"entity_id": item_instance_id, "inventory_id": inventory_id, "reason": reason, "operation": "try_pickup"})
	return ActionResult.failure(reason)
