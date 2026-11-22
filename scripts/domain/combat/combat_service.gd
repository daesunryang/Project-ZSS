class_name CombatService
extends ServerSystem
## Server-authoritative melee combat (docs/02 §5.2). System id "combat";
## registered by ServerComposition after "survival", "noise" and "zombie",
## which it uses through `world.get_system(...)`. No networking here: the
## network layer (P2-N1) calls request_melee_attack() from its RPC handler
## and forwards drain_events().
##
## Public API:
##   request_melee_attack(world, player_id, aim_yaw) -> ActionResult
##   weapon_for(world, player_id) -> MeleeWeaponDefinition (null = unknown player)
##   cooldown_remaining(player_id) -> float (real seconds, 0 = ready)
##   drain_events() -> Array[Dictionary]    (network read surface)
##
## A request carries the attacker and an aim direction only. Position,
## target, weapon, damage, hit/miss and death are decided here from server
## state: the player's server position, the weapon found in the player's
## inventory (CombatSettings.inventory_weapon_rule) and the zombies inside
## the weapon's range and arc. The target is the nearest living zombie in
## the arc (ties: smaller zombie id). Players are never targets (PvP is
## disabled, docs/00).
##
## Validation order (first failure wins, nothing changes on failure):
##   combat_unavailable  - no world, or survival/zombie system not registered
##   bad_aim_yaw         - NaN, infinite or |aim_yaw| > max_abs_aim_yaw
##   unknown_player      - not a player of this world
##   not_online          - the player is not connected
##   player_dead         - the player is dead
##   player_resting      - the player is lying down (P2-T8), or any other
##                         reason a system blocks the player's actions or its
##                         attacks (ServerWorld.player_attack_block_reason;
##                         P2-T11: "player_prone" for a prone player)
##   no_weapon           - no usable weapon definition (configuration error)
##   attack_on_cooldown  - the previous swing's cooldown is still running
##   not_enough_stamina  - less stamina than the weapon's cost
##
## Time: cooldowns run on action time (WorldClock.action_time_sec, real
## seconds, docs/09 §14.16), so the calendar time scale does not change how
## often a player can swing. The event field `world_time` is calendar time
## (WorldClock.world_time_sec), like the events of every other system.
##
## An accepted swing always spends stamina, starts the cooldown and makes
## noise at the attacker's position, hit or miss. On a hit:
##   damage = weapon.base_damage x SurvivalService.handling_multiplier
##            x uniform(damage_roll_min, damage_roll_max)   (saved RNG)
## applied with ZombieService.apply_damage_to_zombie(target, damage, player).
##
## Durability (F-3, FD-3): every hit that lands takes one use off the
## carried item that granted the weapon (the lowest slot holding an item of
## that weapon). Misses cost nothing. Uses left are kept in the item's
## ItemInstance.condition (uses / max_durability, see
## MeleeWeaponDefinition.uses_left), so they are saved and replicated with
## the item as before: InventoryService.set_item_condition announces the
## change and InventoryNetModule sends the owner the changed item. At 0 uses
## the item breaks: it is removed (InventoryService.remove_item), the owner
## is told it is gone, and the next swing uses the next carried weapon or
## bare hands. Bare hands never wear.
##
## Events (drain_events and ActionResult.event; JSON-safe):
##   melee_attack {event_type, attacker_id, weapon_id, aim_yaw (wrapped to
##     [-PI, PI]), position: [x, y, z] (attacker), hit: bool,
##     target_id ("" on a miss), damage, target_health_after, target_died,
##     world_time, weapon_item_id ("" = bare hands), durability_left (uses
##     left after this swing; UNBREAKABLE for bare hands), weapon_broke}
## The last three are server-side only: CombatNetModule.to_public_event does
## not send them (clients see the item change in their own inventory).
## On a miss damage and target_health_after are 0 and target_died is false.
##
## Save: world_state.json `systems.combat` =
##   {schema_version, rng_seed, rng_state}  (64-bit values as strings).
## Not saved: cooldowns (at most a few real seconds; after a restart every
## player may attack at once, docs/15 P2-44) and undrained events.

const SYSTEM_ID: String = "combat"
const SCHEMA_VERSION: int = 1

const EVENT_MELEE_ATTACK: String = "melee_attack"

const REASON_UNAVAILABLE: String = "combat_unavailable"
const REASON_BAD_AIM_YAW: String = "bad_aim_yaw"
## Shared with the systems that own these states (same codes for clients).
const REASON_UNKNOWN_PLAYER: String = SurvivalService.REASON_UNKNOWN_PLAYER
const REASON_NOT_ONLINE: String = ServerWorld.REASON_NOT_ONLINE
const REASON_PLAYER_DEAD: String = SurvivalService.REASON_PLAYER_DEAD
const REASON_NO_WEAPON: String = "no_weapon"
const REASON_ON_COOLDOWN: String = "attack_on_cooldown"
const REASON_NOT_ENOUGH_STAMINA: String = "not_enough_stamina"

const NO_TARGET: String = ""
const READY: float = 0.0
## durability_left of a swing with bare hands (they never wear).
const UNBREAKABLE: int = -1
const NO_ITEM: String = ""

## Diagnostics (tests / profiling).
var dropped_event_count: int = 0

var _settings: CombatSettings
var _weapons: MeleeWeaponCatalog
var _clock: WorldClock
## player_id -> action time at which the player may attack again. Kept while
## the player is offline so reconnecting does not reset a cooldown.
var _ready_at: Dictionary[String, float] = {}
var _events: Array[Dictionary] = []
## Damage rolls. One RNG for all attacks; its state is saved.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init(settings: CombatSettings, weapons: MeleeWeaponCatalog, clock: WorldClock) -> void:
	_settings = settings
	_weapons = weapons
	_clock = clock
	_rng.seed = settings.rng_seed


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ public API

## One melee swing by `player_id` aimed at `aim_yaw` (radians, yaw 0 = -Z).
## See the header for validation, effects and the event format.
func request_melee_attack(world: ServerWorld, player_id: String, aim_yaw: float) -> ActionResult:
	var survival: SurvivalService = null
	var zombies: ZombieService = null
	if world != null:
		survival = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
		zombies = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	if survival == null or zombies == null:
		return _reject(player_id, REASON_UNAVAILABLE)
	if not MeleeHitRules.is_valid_aim_yaw(aim_yaw, _settings.max_abs_aim_yaw):
		return _reject(player_id, REASON_BAD_AIM_YAW)
	var player: PlayerState = world.get_player(player_id)
	if player == null:
		return _reject(player_id, REASON_UNKNOWN_PLAYER)
	if not world.is_online(player_id):
		return _reject(player_id, REASON_NOT_ONLINE)
	if not survival.has_player(player_id):
		return _reject(player_id, REASON_UNKNOWN_PLAYER)
	if not survival.is_alive(player_id):
		return _reject(player_id, REASON_PLAYER_DEAD)
	# A resting player must get up before it can attack (P2-T8) and a prone
	# player must stand up (P2-T11).
	var blocked: String = world.player_attack_block_reason(player_id)
	if not blocked.is_empty():
		return _reject(player_id, blocked)
	var weapon: MeleeWeaponDefinition = _resolve_weapon(world, player)
	if weapon == null:
		return _reject(player_id, REASON_NO_WEAPON)
	var now: float = _clock.action_time_sec
	if now < _ready_at.get(player_id, READY):
		return _reject(player_id, REASON_ON_COOLDOWN)
	# Last check: it spends the stamina, so nothing may fail after it.
	if not survival.try_spend_stamina(player_id, weapon.stamina_cost):
		return _reject(player_id, REASON_NOT_ENOUGH_STAMINA)

	_ready_at[player_id] = now + weapon.cooldown_sec
	var yaw: float = wrapf(aim_yaw, -PI, PI)
	var event: Dictionary = {
		"event_type": EVENT_MELEE_ATTACK,
		"attacker_id": player_id,
		"weapon_id": weapon.weapon_id,
		"aim_yaw": yaw,
		"position": [player.position.x, player.position.y, player.position.z],
		"hit": false,
		"target_id": NO_TARGET,
		"damage": MeleeHitRules.NO_DAMAGE,
		"target_health_after": 0.0,
		"target_died": false,
		"world_time": _clock.world_time_sec,
		"weapon_item_id": NO_ITEM,
		"durability_left": UNBREAKABLE,
		"weapon_broke": false,
	}
	var weapon_item: ItemInstance = _weapon_item(world, player, weapon)
	if weapon_item != null:
		event["weapon_item_id"] = weapon_item.item_instance_id
		event["durability_left"] = weapon.uses_left(weapon_item.condition)
	var target_id: String = _pick_zombie(zombies, player.position, yaw, weapon)
	if not target_id.is_empty():
		_hit(zombies, survival, player_id, weapon, target_id, event)
	if bool(event["hit"]) and weapon_item != null:
		_wear(world, player, weapon, weapon_item, event)
	_make_noise(world, player, weapon)
	_push_event(event)
	GameLogger.info("combat", "melee attack", {
		"player_id": player_id, "entity_id": str(event["target_id"]), "weapon_id": weapon.weapon_id,
		"hit": event["hit"], "damage": event["damage"], "died": event["target_died"],
	})
	return ActionResult.success(event)


## The melee weapon `player_id` would attack with now (unarmed when no
## carried item grants one). Null for an unknown player.
func weapon_for(world: ServerWorld, player_id: String) -> MeleeWeaponDefinition:
	var player: PlayerState = world.get_player(player_id) if world != null else null
	if player == null:
		return null
	return _resolve_weapon(world, player)


## Real seconds (action time) until `player_id` may attack again (0 = ready).
func cooldown_remaining(player_id: String) -> float:
	return maxf(_ready_at.get(player_id, READY) - _clock.action_time_sec, READY)


## Returns and clears the events recorded since the previous call (oldest
## first). At most `max_pending_events` are kept between calls.
func drain_events() -> Array[Dictionary]:
	var drained: Array[Dictionary] = _events
	_events = []
	return drained


# ------------------------------------------------------------ ServerSystem

func to_world_document() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		# 64-bit values are stored as strings: JSON numbers would lose precision.
		"rng_seed": str(_rng.seed),
		"rng_state": str(_rng.state),
	}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != SCHEMA_VERSION:
		errors.append("combat: unsupported schema_version")
		return errors
	var seed_text: String = str(document.get("rng_seed", ""))
	var state_text: String = str(document.get("rng_state", ""))
	if not seed_text.is_valid_int() or not state_text.is_valid_int():
		errors.append("combat: invalid rng seed/state")
		return errors
	_rng.seed = seed_text.to_int()
	_rng.state = state_text.to_int()
	return errors


# ------------------------------------------------------------ internals

## Weapon from the carried items by the configured rule, else unarmed.
func _resolve_weapon(world: ServerWorld, player: PlayerState) -> MeleeWeaponDefinition:
	var carried: MeleeWeaponDefinition = null
	if _settings.inventory_weapon_rule != CombatSettings.WeaponRule.UNARMED_ONLY:
		carried = _weapons.pick_for_items(_carried_definition_ids(world, player), _settings.inventory_weapon_rule)
	return carried if carried != null else _weapons.get_definition(_settings.unarmed_weapon_id)


## Definition ids of the player's items ordered by numeric slot index
## (InventoryService sorts slot ids as text: "slot_10" before "slot_2").
func _carried_definition_ids(world: ServerWorld, player: PlayerState) -> PackedStringArray:
	var items: Array[ItemInstance] = world.inventory.items_in_inventory(player.inventory_id)
	items.sort_custom(func(a: ItemInstance, b: ItemInstance) -> bool: return _slot_index(a.slot_id) < _slot_index(b.slot_id))
	var definition_ids: PackedStringArray = []
	for item: ItemInstance in items:
		definition_ids.append(item.definition_id)
	return definition_ids


static func _slot_index(slot_id: String) -> int:
	return slot_id.trim_prefix(InventoryService.SLOT_PREFIX).to_int()


## The carried item that grants `weapon` and wears when it hits: the one in
## the lowest slot (numeric order). Null for bare hands or when no carried
## item grants it.
func _weapon_item(world: ServerWorld, player: PlayerState, weapon: MeleeWeaponDefinition) -> ItemInstance:
	if not weapon.wears() or weapon.item_definition_id.is_empty():
		return null
	var best: ItemInstance = null
	for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
		if item.definition_id != weapon.item_definition_id:
			continue
		if best == null or _slot_index(item.slot_id) < _slot_index(best.slot_id):
			best = item
	return best


## Takes one use off the item of a weapon that hit (FD-3); at 0 uses the
## item breaks and leaves the game. Fills in durability_left / weapon_broke.
## A refused inventory change is logged and loses only the wear.
func _wear(world: ServerWorld, player: PlayerState, weapon: MeleeWeaponDefinition, item: ItemInstance, event: Dictionary) -> void:
	var uses: int = maxi(weapon.uses_left(item.condition) - 1, 0)
	event["durability_left"] = uses
	if uses > 0:
		var worn: ActionResult = world.inventory.set_item_condition(player.inventory_id, item.item_instance_id, weapon.condition_for_uses(uses))
		if not worn.ok:
			GameLogger.error("combat", "weapon wear rejected", {"player_id": player.player_id, "entity_id": item.item_instance_id, "weapon_id": weapon.weapon_id, "reason": worn.reason, "operation": "melee_wear"})
		return
	var broken: ActionResult = world.inventory.remove_item(player.inventory_id, item.item_instance_id, 1)
	if not broken.ok:
		GameLogger.error("combat", "broken weapon not removed", {"player_id": player.player_id, "entity_id": item.item_instance_id, "weapon_id": weapon.weapon_id, "reason": broken.reason, "operation": "melee_break"})
		return
	event["weapon_broke"] = true
	GameLogger.info("combat", "weapon broke", {"player_id": player.player_id, "entity_id": item.item_instance_id, "weapon_id": weapon.weapon_id, "operation": "melee_break"})


## Nearest living zombie inside the weapon's range and arc ("" = none).
func _pick_zombie(zombies: ZombieService, origin: Vector3, aim_yaw: float, weapon: MeleeWeaponDefinition) -> String:
	var candidate_ids: PackedStringArray = []
	var candidate_positions: PackedVector3Array = []
	for zombie_id: String in zombies.zombie_ids():
		var zombie: ZombieState = zombies.get_zombie(zombie_id)
		if zombie == null or not zombie.is_alive():
			continue
		candidate_ids.append(zombie_id)
		candidate_positions.append(zombie.position)
	return MeleeHitRules.pick_target(origin, aim_yaw, weapon.range_m, weapon.arc_angle_deg, candidate_ids, candidate_positions)


## Rolls and applies the damage of a hit and fills in the event. The roll is
## only made for swings that have a target.
func _hit(zombies: ZombieService, survival: SurvivalService, player_id: String, weapon: MeleeWeaponDefinition, target_id: String, event: Dictionary) -> void:
	var roll: float = _rng.randf_range(_settings.damage_roll_min, _settings.damage_roll_max)
	var amount: float = MeleeHitRules.damage(weapon.base_damage, survival.handling_multiplier(player_id), roll)
	var applied: ActionResult = zombies.apply_damage_to_zombie(target_id, amount, player_id)
	if not applied.ok:
		# E.g. a handling factor of 0 from the settings: the swing connects
		# with nothing and is reported as a miss.
		GameLogger.warning("combat", "hit rejected by the zombie system", {"player_id": player_id, "entity_id": target_id, "reason": applied.reason, "operation": "melee_attack"})
		return
	event["hit"] = true
	event["target_id"] = target_id
	event["damage"] = amount
	event["target_health_after"] = float(applied.event["health_after"])
	event["target_died"] = bool(applied.event["died"])


## Every swing is heard, hit or miss (docs/02 §5.3). A weapon with loudness
## 0 is silent; a missing noise system only loses the noise.
func _make_noise(world: ServerWorld, player: PlayerState, weapon: MeleeWeaponDefinition) -> void:
	if weapon.noise_loudness <= 0.0:
		return
	var noise: NoiseService = world.get_system(NoiseService.SYSTEM_ID) as NoiseService
	if noise == null:
		return
	var emitted: ActionResult = noise.emit(player.player_id, player.position, weapon.noise_loudness, weapon.noise_frequency_profile)
	if not emitted.ok:
		GameLogger.warning("combat", "attack noise rejected", {"player_id": player.player_id, "weapon_id": weapon.weapon_id, "reason": emitted.reason, "operation": "melee_attack"})


func _push_event(event: Dictionary) -> void:
	_events.append(event)
	while _events.size() > _settings.max_pending_events:
		_events.pop_front()
		dropped_event_count += 1


func _reject(player_id: String, reason: String) -> ActionResult:
	GameLogger.debug("combat", "melee attack rejected", {"player_id": player_id, "reason": reason, "operation": "request_melee_attack"})
	return ActionResult.failure(reason)
