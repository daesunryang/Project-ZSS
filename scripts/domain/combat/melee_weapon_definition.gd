class_name MeleeWeaponDefinition
extends Resource
## Static definition of one melee weapon (docs/02 §5.1, docs/00 ADR-005).
## Files live in `res://resources/definitions/melee_weapons/*.tres` and are
## loaded by MeleeWeaponCatalog. Every number is PROVISIONAL (docs/15 §6.3
## P2-40) and must be balanced by play-testing. Times are world seconds.

enum Category { UNARMED, BLUNT, BLADE, AXE }

## Save/network names, indexed by Category.
const CATEGORY_NAMES: PackedStringArray = ["unarmed", "blunt", "blade", "axe"]
const WEAPON_ID_PATTERN: String = "^[a-z][a-z0-9_]*$"
const FULL_CIRCLE_DEG: float = 360.0

## Stable snake_case id (sent in combat events).
@export var weapon_id: String = ""
@export var display_name: String = ""
@export var category: Category = Category.UNARMED
## ItemDefinition id that grants this weapon while it is carried. Empty only
## for UNARMED weapons, which need no item.
@export var item_definition_id: String = ""
## Damage of one hit before the handling and random factors.
@export_range(0.001, 100000.0) var base_damage: float = 1.0
## Reach from the attacker's position to the target's position, metres (XZ).
@export_range(0.01, 100.0) var range_m: float = 1.0
## Full opening angle of the swing, centred on the aim direction, degrees.
@export_range(0.0, 360.0) var arc_angle_deg: float = 90.0
## World seconds before the same player may attack again.
@export_range(0.0, 1000.0) var cooldown_sec: float = 1.0
## Stamina spent per swing (hit or miss).
@export_range(0.0, 10000.0) var stamina_cost: float = 0.0
## NoiseService loudness of one swing (hit or miss). 0 = silent.
@export_range(0.0, 100000.0) var noise_loudness: float = 0.0
## NoiseSettings.frequency_profiles entry used for the swing noise.
@export var noise_frequency_profile: String = "broadband"


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if RegEx.create_from_string(WEAPON_ID_PATTERN).search(weapon_id) == null:
		errors.append("weapon_id '%s' must be snake_case" % weapon_id)
	if category < 0 or category >= CATEGORY_NAMES.size():
		errors.append("weapon %s has an unknown category" % weapon_id)
	if category == Category.UNARMED and not item_definition_id.is_empty():
		errors.append("unarmed weapon %s must not need an item" % weapon_id)
	if category != Category.UNARMED and not ItemInstance.is_valid_definition_id(item_definition_id):
		errors.append("weapon %s needs a snake_case item_definition_id" % weapon_id)
	if not is_finite(base_damage) or base_damage <= 0.0:
		errors.append("weapon %s base_damage must be > 0" % weapon_id)
	if not is_finite(range_m) or range_m <= 0.0:
		errors.append("weapon %s range_m must be > 0" % weapon_id)
	if not is_finite(arc_angle_deg) or arc_angle_deg < 0.0 or arc_angle_deg > FULL_CIRCLE_DEG:
		errors.append("weapon %s arc_angle_deg must be within [0, 360]" % weapon_id)
	if not is_finite(cooldown_sec) or cooldown_sec < 0.0:
		errors.append("weapon %s cooldown_sec must be >= 0" % weapon_id)
	if not is_finite(stamina_cost) or stamina_cost < 0.0:
		errors.append("weapon %s stamina_cost must be >= 0" % weapon_id)
	if not is_finite(noise_loudness) or noise_loudness < 0.0:
		errors.append("weapon %s noise_loudness must be >= 0" % weapon_id)
	return errors


static func category_name(value: Category) -> String:
	return CATEGORY_NAMES[value]
