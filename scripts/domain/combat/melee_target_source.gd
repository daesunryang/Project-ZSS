class_name MeleeTargetSource
extends RefCounted
## Somebody other than a zombie that a player's melee swing can hit (F-25,
## docs/09 §17.12). CombatService knows zombies itself; everything else that
## can be hit registers one of these (CombatService.add_target_source). The
## NPCs' one is NpcMeleeTargets. Players are never targets (PvP is off).
##
## Rules for an implementation:
##   - melee_target_ids() lists only targets that are alive and simulated
##     now, in a stable order;
##   - apply_melee_damage() decides what the hit does to the target (the
##     wound, death). `amount` is the server's damage of this swing.
##     Success event: {health_after: float, died: bool}.


## Ids of what can be hit now.
func melee_target_ids() -> PackedStringArray:
	return PackedStringArray()


func melee_target_position(_target_id: String) -> Vector3:
	return Vector3.ZERO


## A swing of `attacker_id` with `weapon` landed on `target_id`.
func apply_melee_damage(_target_id: String, _amount: float, _attacker_id: String, _weapon: MeleeWeaponDefinition) -> ActionResult:
	return ActionResult.failure("unknown_target")
