class_name ClientWorldState
extends RefCounted
## Client-side mirror of what the server has told this client. Pure data;
## never authoritative and never sent back to the server.

signal changed

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
