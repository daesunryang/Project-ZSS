class_name ZombieTargetSource
extends RefCounted
## Somebody other than a player that zombies can see, chase and attack
## (F-25, docs/09 §17.12). ZombieService knows players itself; everything
## else that can be bitten registers one of these
## (ZombieService.add_target_source). The NPCs' one is NpcZombieTargets.
##
## A target id is a world entity id that is not a player id. A zombie keeps
## it where it keeps a player id (ZombieState.target_player_id), so the
## zombie save format is unchanged.
##
## Rules for an implementation:
##   - target_ids() lists only targets that are alive and simulated now, in
##     a stable order (the same world gives the same list);
##   - is_target(id) is true exactly for those;
##   - receive_attack() decides the damage and the infection itself (the
##     zombie only says what it did). Success event:
##       {health_after: float, died: bool, infection: String}
##     `infection` is what the exposure did (an event type or a refusal
##     reason), like the player's.


## Ids of the targets zombies can sense now.
func target_ids() -> PackedStringArray:
	return PackedStringArray()


## True when `target_id` is one of this source's targets and can be sensed
## and attacked now.
func is_target(_target_id: String) -> bool:
	return false


func target_position(_target_id: String) -> Vector3:
	return Vector3.ZERO


## How visible the target is, 0..1 (1 = the zombie's full sight range).
func target_visibility(_target_id: String) -> float:
	return 1.0


## A zombie's bite or scratch landed on `target_id`.
func receive_attack(_target_id: String, _damage: DamageInput, _exposure: InfectionState.Exposure) -> ActionResult:
	return ActionResult.failure("unknown_target")
