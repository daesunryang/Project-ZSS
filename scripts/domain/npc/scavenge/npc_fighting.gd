class_name NpcFighting
extends RefCounted
## One melee swing of an NPC at a zombie (F-29, docs/09 §17.14): what the
## action "fight" does every time its timer runs out. A helper of
## NpcBehaviours. The rules are the players' melee rules
## (scripts/domain/combat/), applied to an NPC:
##   - the weapon is the best melee weapon it carries (the highest base
##     damage, CombatSettings.WeaponRule.HIGHEST_DAMAGE), bare hands
##     otherwise;
##   - the zombie must be alive and within reach (XZ): the weapon's range,
##     but at least NpcScavengeSettings.fight_range_m. NPCs are points and
##     do not step up to a zombie, and a zombie stops at its own attack
##     range: with a shorter weapon an NPC would never land a hit
##     (docs/15 F29-008);
##   - damage = weapon.base_damage x uniform(damage_roll_min,
##     damage_roll_max), the roll from the NPC's own saved generator (the
##     combat system's generator is the players');
##   - ZombieService.apply_damage_to_zombie(zombie, damage, npc id): the
##     zombie notices its attacker like a player's;
##   - a hit takes one use off the weapon item; at 0 uses it breaks and is
##     gone (FD-3);
##   - the swing is heard (NoiseService), hit or miss.
## What an NPC does not have: stamina (a swing costs none) and the handling
## factor of arm wounds (docs/15 F29-009). NPCs never hit players or other
## NPCs here (F-32).

## Keys of what swing() returns.
const KEY_HIT: String = "hit"
const KEY_DIED: String = "died"
const KEY_IN_REACH: String = "in_reach"
const KEY_COOLDOWN_SEC: String = "cooldown_sec"
const KEY_WEAPON_ID: String = "weapon_id"
const KEY_DAMAGE: String = "damage"
const DEFAULT_COOLDOWN_SEC: float = 1.0

## Diagnostics (tests).
var swing_count: int = 0
var hit_count: int = 0
var kill_count: int = 0
var broken_weapon_count: int = 0

var _weapons: MeleeWeaponCatalog
var _combat: CombatSettings


func _init(weapons: MeleeWeaponCatalog, combat: CombatSettings) -> void:
	_weapons = weapons
	_combat = combat if combat != null else CombatSettings.new()


## The weapon the NPC would swing now (bare hands without a carried
## weapon; null only when the data has no unarmed weapon).
func weapon_of(world: ServerWorld, inventory_id: String) -> MeleeWeaponDefinition:
	if _weapons == null:
		return null
	var ids: PackedStringArray = []
	for item: ItemInstance in NpcSurvivalSense.items_of(world, inventory_id):
		ids.append(item.definition_id)
	var carried: MeleeWeaponDefinition = _weapons.pick_for_items(ids, CombatSettings.WeaponRule.HIGHEST_DAMAGE)
	return carried if carried != null else _weapons.get_definition(_combat.unarmed_weapon_id)


## How far the NPC's swing reaches now (see the header).
func reach_of(world: ServerWorld, inventory_id: String, min_reach_m: float) -> float:
	var weapon: MeleeWeaponDefinition = weapon_of(world, inventory_id)
	return maxf(weapon.range_m if weapon != null else 0.0, min_reach_m)


## The nearest living zombie within `reach_m` of the NPC (XZ; ties: the
## smaller id), "" when there is none.
static func nearest_zombie(world: ServerWorld, npc: NpcState, reach_m: float) -> String:
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService if world != null else null
	if zombies == null:
		return ""
	var best_id: String = ""
	var best_distance: float = INF
	for zombie_id: String in zombies.zombie_ids():
		var zombie: ZombieState = zombies.get_zombie(zombie_id)
		if zombie == null or not zombie.is_alive():
			continue
		var distance: float = ZombiePerception.flat_distance(npc.position, zombie.position)
		if distance <= reach_m and (distance < best_distance or (distance == best_distance and zombie_id < best_id)):
			best_distance = distance
			best_id = zombie_id
	return best_id


## One swing of `npc` at `zombie_id` (see the header): {in_reach, hit, died,
## cooldown_sec, weapon_id, damage}. Out of reach: nothing happens.
func swing(world: ServerWorld, npcs: NpcService, npc: NpcState, inventory_id: String, zombie_id: String, min_reach_m: float) -> Dictionary:
	var result: Dictionary = {KEY_IN_REACH: false, KEY_HIT: false, KEY_DIED: false, KEY_COOLDOWN_SEC: DEFAULT_COOLDOWN_SEC, KEY_WEAPON_ID: "", KEY_DAMAGE: 0.0}
	var weapon: MeleeWeaponDefinition = weapon_of(world, inventory_id)
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var zombie: ZombieState = zombies.get_zombie(zombie_id) if zombies != null else null
	if weapon == null or zombie == null or not zombie.is_alive() or ZombiePerception.flat_distance(npc.position, zombie.position) > maxf(weapon.range_m, min_reach_m):
		return result
	result[KEY_IN_REACH] = true
	result[KEY_COOLDOWN_SEC] = weapon.cooldown_sec
	result[KEY_WEAPON_ID] = weapon.weapon_id
	swing_count += 1
	# It turns to what it hits.
	npcs.set_npc_transform(world, npc.npc_id, npc.position, ZombiePerception.yaw_towards(zombie.position - npc.position, npc.yaw))
	var amount: float = MeleeHitRules.damage(weapon.base_damage, 1.0, npc.rng.randf_range(_combat.damage_roll_min, _combat.damage_roll_max))
	npcs.mark_npc_dirty(npc.npc_id)
	var applied: ActionResult = zombies.apply_damage_to_zombie(zombie_id, amount, npc.npc_id)
	if applied.ok:
		hit_count += 1
		result[KEY_HIT] = true
		result[KEY_DAMAGE] = amount
		result[KEY_DIED] = bool(applied.event["died"])
		if bool(applied.event["died"]):
			kill_count += 1
		_wear(world, npc, inventory_id, weapon)
	if weapon.noise_loudness > 0.0:
		var noise: NoiseService = world.get_system(NoiseService.SYSTEM_ID) as NoiseService
		if noise != null:
			noise.emit(npc.npc_id, npc.position, weapon.noise_loudness, weapon.noise_frequency_profile)
	GameLogger.info("npc", "an NPC swung at a zombie", {"entity_id": npc.npc_id, "zombie_id": zombie_id, "weapon_id": weapon.weapon_id, "hit": result[KEY_HIT], "damage": amount, "died": result[KEY_DIED]})
	return result


## One use off the carried item of a weapon that hit (the lowest slot);
## at 0 uses it breaks.
func _wear(world: ServerWorld, npc: NpcState, inventory_id: String, weapon: MeleeWeaponDefinition) -> void:
	if not weapon.wears() or weapon.item_definition_id.is_empty():
		return
	for item: ItemInstance in NpcSurvivalSense.items_of(world, inventory_id):
		if item.definition_id != weapon.item_definition_id:
			continue
		var uses: int = maxi(weapon.uses_left(item.condition) - 1, 0)
		if uses > 0:
			world.inventory.set_item_condition(inventory_id, item.item_instance_id, weapon.condition_for_uses(uses))
		elif world.inventory.remove_item(inventory_id, item.item_instance_id, 1).ok:
			broken_weapon_count += 1
			GameLogger.info("npc", "an NPC's weapon broke", {"entity_id": npc.npc_id, "weapon_id": weapon.weapon_id, "operation": "fight"})
		return
