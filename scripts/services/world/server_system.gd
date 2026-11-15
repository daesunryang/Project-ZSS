class_name ServerSystem
extends RefCounted
## Base class for server-side simulation systems plugged into ServerWorld
## (survival, noise, zombies, combat, ...). Systems are registered once by
## ServerComposition, stepped every server physics tick, and persisted:
##   world_state.json  -> "systems": {system_id: to_world_document()}
##   players/<id>.json -> "systems": {system_id: to_player_fragment(id)}
##   cells/<cell_id>.json -> "systems": {system_id: to_cell_document(cell_id)}
##                         (P3-1: entities that lie in a world cell)
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


## "" when this system lets the player make an attack, otherwise a stable
## reason code such as "player_prone" (P2-T11). Only for what blocks attacks
## but not item handling; whatever blocks every action belongs in
## player_action_block_reason. CombatService asks through
## ServerWorld.player_attack_block_reason, which asks both hooks.
func player_attack_block_reason(_player_id: String) -> String:
	return ""


## True when this system knows the player's current character to be dead
## (P2-T14). Asked through ServerWorld.is_player_dead about a player that is
## acted UPON or acted WITH (the other side of a rule between two players),
## where player_action_block_reason would also name a player that merely
## sleeps. A system that knows nothing of death answers false;
## SurvivalService answers for its dead characters.
func player_is_dead(_player_id: String) -> bool:
	return false


## How well this player can be seen (P2-T11, docs/09 §14.26): a factor on
## the distance at which a zombie's sight reaches it (1.0 = no effect, 0.0 =
## cannot be seen). ServerWorld multiplies the factors of all systems and
## clamps the product to [0, 1], so a system can only hide a player. The
## zombie system asks ServerWorld.player_visibility_multiplier and so needs
## to know nothing about postures, sleep or movement.
func player_visibility_multiplier(_player_id: String) -> float:
	return 1.0


## Factors on this player's footsteps (P2-T11): the loudness of one footstep
## and the distance walked between two of them (1.0 = no effect).
## PlayerNoiseService asks ServerWorld.player_footstep_loudness_multiplier /
## player_footstep_stride_multiplier, which multiply the factors of all
## systems.
func player_footstep_loudness_multiplier(_player_id: String) -> float:
	return 1.0


func player_footstep_stride_multiplier(_player_id: String) -> float:
	return 1.0


## "" when this system lets the player start a NEW character now, replacing
## the one it has (P2-T9, docs/09 §14.24), otherwise a stable reason code.
## ServerWorld.create_character asks every system when a player that already
## has a character wants to create another one and refuses with the first
## reason. SurvivalService answers "character_alive" while the character
## lives and "respawn_wait" until the delay after its death has passed. Not
## asked for a player's first character.
func new_character_block_reason(_player_id: String) -> String:
	return ""


## Called by ServerWorld.start_new_character() after the world-owned part of
## the change (spawn position, empty inventory, next generation, name and
## appearance) is done, so a system can reset what it keeps per character
## (SurvivalService: fresh vitals, no wounds, no infection). Not called for a
## player's first character: that one enters through on_player_online().
func on_character_started(_world: ServerWorld, _player_id: String) -> void:
	return


## World cells (P3-1, docs/09 §15.1). A system whose entities have a place
## in the world keeps them in ServerWorld.cell_index and implements the five
## hooks below, so the world can stop simulating a cell and take it out of
## memory. WorldCellService calls them through ServerWorld; a system without
## such entities ignores them.

## The cell became ACTIVE: its entities are simulated from now on.
func on_cell_activated(_world: ServerWorld, _cell_id: String) -> void:
	return


## The cell is no longer ACTIVE (it stays in memory): stop simulating its
## entities. They keep their state as it is.
func on_cell_deactivated(_world: ServerWorld, _cell_id: String) -> void:
	return


## This system's entities in one cell as save data ({} = none). JSON-safe,
## with "schema_version". Saved under `systems.{system_id}` of the cell
## document.
func to_cell_document(_cell_id: String) -> Dictionary:
	return {}


## Brings this system's saved entities of a cell back into memory, exactly
## as they were saved. Must validate everything first: on any error nothing
## changes and the errors are returned (the cell is then not loaded). Not
## called when the cell document has nothing for this system.
func restore_cell_document(_world: ServerWorld, _cell_id: String, _document: Dictionary) -> PackedStringArray:
	return PackedStringArray()


## Forgets this system's entities of a cell. Called only after the cell was
## saved (CLAUDE.md §6). Ids are released (EntityRegistry.release), never
## retired: the entities still exist.
func release_cell(_world: ServerWorld, _cell_id: String) -> void:
	return


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
