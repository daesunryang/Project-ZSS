class_name ServerSystem
extends RefCounted
## Base class for server-side simulation systems plugged into ServerWorld
## (survival, noise, zombies, combat, ...). Systems are registered once by
## ServerComposition, stepped every server physics tick, and persisted:
##   world_state.json  -> "systems": {system_id: to_world_document()}
##   players/<id>.json -> "systems": {system_id: to_player_fragment(id)}
## Documents must be JSON-safe (SaveService.is_json_safe) and contain
## "schema_version". Systems must not hold Node references.
##
## Default implementations are intentional no-ops for optional hooks;
## get_system_id() must be overridden.


## Unique snake_case id; also the save key. Must be overridden.
func get_system_id() -> String:
	return ""


## Called once when a brand-new world is created (not for loaded saves).
func seed_new_world(_world: ServerWorld) -> Error:
	return OK


## Called every server physics tick. `world_delta` is 0 while the world
## clock is paused. Use BucketScheduler for per-entity cadence.
func step(_world: ServerWorld, _real_delta: float, _world_delta: float) -> void:
	return


func on_player_online(_world: ServerWorld, _player_id: String) -> void:
	return


func on_player_offline(_world: ServerWorld, _player_id: String) -> void:
	return


## Factor applied to this player's server movement speed (1.0 = no effect,
## 0.0 = cannot move). ServerWorld multiplies the factors of all systems and
## clamps the product to [0, 1], so a system can only slow a player down.
func player_movement_multiplier(_player_id: String) -> float:
	return 1.0


## World-level save document ({} = nothing to save).
func to_world_document() -> Dictionary:
	return {}


## Restores the world document; returns errors (non-empty = discard world).
## Not called when the save has no document for this system.
func restore_world_document(_document: Dictionary) -> PackedStringArray:
	return PackedStringArray()


## Per-player save fragment ({} = nothing to save for this player).
func to_player_fragment(_player_id: String) -> Dictionary:
	return {}


## Restores one player's fragment; returns errors.
func restore_player_fragment(_player_id: String, _fragment: Dictionary) -> PackedStringArray:
	return PackedStringArray()
