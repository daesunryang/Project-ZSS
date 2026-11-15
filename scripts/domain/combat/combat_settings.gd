class_name CombatSettings
extends Resource
## Combat tuning that is not part of one weapon (docs/02 §5). Defaults in
## `res://data/tuning/combat_settings.tres`. Every value is PROVISIONAL
## (docs/15 §6.3 P2-41..P2-46). Weapon numbers live in MeleeWeaponDefinition.

const DEFAULT_PATH: String = "res://data/tuning/combat_settings.tres"

## How the weapon of an attack is found. There is no equipment slot yet
## (docs/15 P2-41), so the carried items decide:
##   UNARMED_ONLY   - always the unarmed weapon
##   FIRST_SLOT     - the weapon item in the lowest inventory slot
##   HIGHEST_DAMAGE - the carried weapon with the highest base damage
enum WeaponRule { UNARMED_ONLY, FIRST_SLOT, HIGHEST_DAMAGE }

## MeleeWeaponDefinition used when no carried item grants a weapon.
@export var unarmed_weapon_id: String = "unarmed"
@export var inventory_weapon_rule: WeaponRule = WeaponRule.HIGHEST_DAMAGE
## Each hit multiplies its damage by a factor drawn uniformly from
## [damage_roll_min, damage_roll_max] with the saved combat RNG.
@export_range(0.001, 100.0) var damage_roll_min: float = 0.9
@export_range(0.001, 100.0) var damage_roll_max: float = 1.1
## Largest |aim_yaw| accepted from a request, radians (one full turn, the
## same bound as the move intent yaw).
@export_range(0.001, 1000.0) var max_abs_aim_yaw: float = TAU
## Seed of the combat RNG (damage rolls). Its state is saved with the world.
@export var rng_seed: int = 0
## Undrained events kept for the network layer; the oldest are dropped.
@export_range(1, 1000000) var max_pending_events: int = 256
## docs/00: PvP is disabled by default. The flag only reserves the option:
## there is no player-versus-player implementation, so `true` is rejected by
## validate() instead of silently doing nothing (docs/15 P2-45).
@export var pvp_enabled: bool = false


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if RegEx.create_from_string(MeleeWeaponDefinition.WEAPON_ID_PATTERN).search(unarmed_weapon_id) == null:
		errors.append("combat unarmed_weapon_id must be a snake_case weapon id")
	if inventory_weapon_rule < 0 or inventory_weapon_rule > WeaponRule.HIGHEST_DAMAGE:
		errors.append("combat inventory_weapon_rule is unknown")
	if not is_finite(damage_roll_min) or not is_finite(damage_roll_max) or damage_roll_min <= 0.0 or damage_roll_max < damage_roll_min:
		errors.append("combat damage rolls must satisfy 0 < damage_roll_min <= damage_roll_max")
	if not is_finite(max_abs_aim_yaw) or max_abs_aim_yaw <= 0.0:
		errors.append("combat max_abs_aim_yaw must be > 0")
	if max_pending_events < 1:
		errors.append("combat max_pending_events must be >= 1")
	if pvp_enabled:
		errors.append("combat pvp_enabled is not supported yet (docs/00: PvP disabled by default)")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> CombatSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is CombatSettings:
		return loaded as CombatSettings
	GameLogger.warning("config", "combat settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return CombatSettings.new()
