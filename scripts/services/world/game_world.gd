class_name GameWorld
extends Node3D
## Root of the active world (docs/09 §5 GameWorld.tscn).
##
## Phase 0: an empty world. It owns no gameplay state yet and has no
## presentation dependency, so it runs identically on client and headless
## server. Cell streaming, entity registry and world clock are Phase 1+.

signal world_ready(world_id: String)

var _world_id: String = ""
var _is_ready: bool = false


## Initializes the world with a validated id. Must be called before entering the tree.
func setup(world_id: String) -> Error:
	if not LaunchConfig.is_valid_world_id(world_id):
		GameLogger.error("world", "rejected invalid world id", {"world_id": world_id, "operation": "world_setup"})
		return ERR_INVALID_PARAMETER
	_world_id = world_id
	return OK


func _ready() -> void:
	if _world_id.is_empty():
		GameLogger.error("world", "world entered tree without setup()", {"operation": "world_ready"})
		return
	_is_ready = true
	GameLogger.info("world", "empty world ready", {"world_id": _world_id, "cell_count": get_cell_count()})
	world_ready.emit(_world_id)


func get_world_id() -> String:
	return _world_id


func is_world_ready() -> bool:
	return _is_ready


## Number of loaded cells. Always 0 in Phase 0 (no streaming yet).
func get_cell_count() -> int:
	return %Cells.get_child_count()
