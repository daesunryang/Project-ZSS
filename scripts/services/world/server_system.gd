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


## Called once by ServerWorld.register_system() when this system was added
## to `world` (before seeding / restoring). A system that must reach the
## world outside the hooks below (which all receive it) may keep a WEAK
## reference here: the world owns its systems, so a strong reference would
## be a cycle and never be freed (P2-T4).
func on_registered(_world: ServerWorld) -> void:
	return


## Called once when a brand-new world is created (not for loaded saves).
func seed_new_world(_world: ServerWorld) -> Error:
	return OK


## Called every server physics tick with the two time deltas of this tick
## (docs/09 §14.16, docs/00 ADR-006):
##   action_delta  real seconds; use it for anything that plays out in real
##                 time (movement, cooldowns, AI cadence, noise lifetime).
##   world_delta   calendar seconds = action_delta * WorldClock.time_scale;
##                 use it for slow calendar rules (needs, infection, healing).
## Both are 0 while the world clock is paused (and only then), so a system
## never sees real time pass in a paused world. The matching timestamps are
## WorldClock.action_time_sec and WorldClock.world_time_sec.
## Use BucketScheduler for per-entity cadence.
func step(_world: ServerWorld, _action_delta: float, _world_delta: float) -> void:
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


## "" when this system lets the player act (pick up, put down, use an item,
## attack), otherwise a stable reason code such as "player_dead" or
## "player_resting". ServerWorld asks every system before a pickup or a drop
## and refuses it with the first reason (P2-T4: a dead character is
## finished); ItemConsumption and CombatService ask through
## ServerWorld.player_action_block_reason (P2-T8: a resting player must get
## up first). Movement is not asked here: see player_movement_multiplier.
func player_action_block_reason(_player_id: String) -> String:
	return ""


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
