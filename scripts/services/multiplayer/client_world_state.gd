class_name ClientWorldState
extends RefCounted
## Client-side mirror of what the server has told this client. Pure data;
## never authoritative and never sent back to the server.

signal changed

## Keys of a world item entry (same as InventoryService.describe_world_item).
const KEY_ITEM_ID: String = "item_instance_id"
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_QUANTITY: String = "quantity"
const KEY_POSITION: String = "position"
## Longest item / definition id accepted from the server.
const ITEM_ID_MAX_LENGTH: int = IntentValidator.ENTITY_ID_MAX_LENGTH

var local_player_id: String = ""
## player_id -> {"position": Vector3, "yaw": float}
var players: Dictionary[String, Dictionary] = {}
## item_instance_id -> {"definition_id", "quantity", "position"}
var world_items: Dictionary[String, Dictionary] = {}
## Local player's inventory: Array of ItemInstance dictionaries.
var inventory: Array[Dictionary] = []
## Server tick of the newest applied position snapshot.
var last_snapshot_tick: int = -1


## Applies the initial snapshot sent with join acceptance.
func apply_join(player_id: String, snapshot: Dictionary) -> void:
	local_player_id = player_id
	players.clear()
	world_items.clear()
	inventory.clear()
	last_snapshot_tick = -1
	for entry: Dictionary in snapshot.get("players", []):
		players[str(entry["player_id"])] = {"position": entry["position"], "yaw": entry["yaw"]}
	for entry: Dictionary in snapshot.get("world_items", []):
		world_items[str(entry["item_instance_id"])] = entry
	for entry: Dictionary in snapshot.get("inventory", []):
		inventory.append(entry)
	changed.emit()


func apply_player_joined(player_id: String, position: Vector3, yaw: float) -> void:
	players[player_id] = {"position": position, "yaw": yaw}
	changed.emit()


func apply_player_left(player_id: String) -> void:
	players.erase(player_id)
	changed.emit()


func position_of(player_id: String) -> Vector3:
	var entry: Dictionary = players.get(player_id, {})
	return entry.get("position", Vector3.ZERO)


## Applies an unreliable position snapshot; older ticks are dropped.
## Returns false when the snapshot was stale or malformed.
func apply_position_snapshot(tick: int, entries: Array) -> bool:
	if tick <= last_snapshot_tick:
		return false
	for entry: Variant in entries:
		if typeof(entry) != TYPE_ARRAY or (entry as Array).size() != 3:
			return false
		var row: Array = entry
		if typeof(row[0]) != TYPE_STRING or typeof(row[1]) != TYPE_VECTOR3 or typeof(row[2]) != TYPE_FLOAT:
			return false
	last_snapshot_tick = tick
	for entry: Variant in entries:
		var row: Array = entry
		players[str(row[0])] = {"position": row[1], "yaw": row[2]}
	changed.emit()
	return true


func apply_world_item_removed(item_instance_id: String) -> void:
	world_items.erase(item_instance_id)
	changed.emit()


## True when `entry` is a world item as the server describes it:
## {item_instance_id: String 1..64, definition_id: snake_case String,
##  quantity: int >= 1, position: finite Vector3}.
static func is_valid_world_item(entry: Variant) -> bool:
	if typeof(entry) != TYPE_DICTIONARY:
		return false
	var data: Dictionary = entry
	var item_id: Variant = data.get(KEY_ITEM_ID, null)
	var definition_id: Variant = data.get(KEY_DEFINITION_ID, null)
	var quantity: Variant = data.get(KEY_QUANTITY, null)
	var position: Variant = data.get(KEY_POSITION, null)
	if typeof(item_id) != TYPE_STRING or typeof(definition_id) != TYPE_STRING or typeof(quantity) != TYPE_INT or typeof(position) != TYPE_VECTOR3:
		return false
	if str(item_id).is_empty() or str(item_id).length() > ITEM_ID_MAX_LENGTH:
		return false
	if str(definition_id).length() > ITEM_ID_MAX_LENGTH or not ItemInstance.is_valid_definition_id(str(definition_id)):
		return false
	return int(quantity) >= 1 and (position as Vector3).is_finite()


## Adds/replaces an item lying in the world (P2-T2: an item was put down).
## Only the known fields are kept. Returns false (no change) when malformed.
func apply_world_item_added(entry: Dictionary) -> bool:
	if not is_valid_world_item(entry):
		return false
	var item_id: String = str(entry[KEY_ITEM_ID])
	world_items[item_id] = {
		KEY_ITEM_ID: item_id,
		KEY_DEFINITION_ID: str(entry[KEY_DEFINITION_ID]),
		KEY_QUANTITY: int(entry[KEY_QUANTITY]),
		KEY_POSITION: entry[KEY_POSITION],
	}
	changed.emit()
	return true


## Adds/replaces an item in the local inventory mirror (validated dict).
func apply_inventory_item(item: Dictionary) -> bool:
	if not ItemInstance.validate_dict(item).is_empty():
		return false
	for index: int in range(inventory.size()):
		if inventory[index]["item_instance_id"] == item["item_instance_id"]:
			inventory[index] = item
			changed.emit()
			return true
	inventory.append(item)
	changed.emit()
	return true


## Removes an item from the local inventory mirror (P2-T2: it was put down,
## used up or taken away). Returns false (no change) when it is not there.
func apply_inventory_item_removed(item_instance_id: String) -> bool:
	for index: int in range(inventory.size()):
		if str(inventory[index]["item_instance_id"]) == item_instance_id:
			inventory.remove_at(index)
			changed.emit()
			return true
	return false


func has_inventory_item(item_instance_id: String) -> bool:
	for entry: Dictionary in inventory:
		if str(entry["item_instance_id"]) == item_instance_id:
			return true
	return false


## A copy of the mirrored inventory entry (ItemInstance dictionary), or {}
## when the item is not in the local inventory.
func get_inventory_item(item_instance_id: String) -> Dictionary:
	for entry: Dictionary in inventory:
		if str(entry["item_instance_id"]) == item_instance_id:
			return entry.duplicate()
	return {}
