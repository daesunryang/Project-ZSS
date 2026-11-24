class_name NpcMeleeTargets
extends MeleeTargetSource
## Lets a player's melee swing hit the NPCs (F-25, docs/09 §17.12): the
## living NPCs that are awake. The swing's damage becomes one wound of
## NpcHealth: a blade or an axe cuts (laceration), a blunt weapon and bare
## hands bruise. The body part is NpcHealthSettings.melee_body_part (a
## request carries no aimed part).

var _health_ref: WeakRef
var _body_part: BodyPart.Part


func _init(health: NpcHealth, settings: NpcHealthSettings) -> void:
	_health_ref = weakref(health)
	_body_part = maxi(BodyPart.from_name(settings.melee_body_part), 0) as BodyPart.Part


func melee_target_ids() -> PackedStringArray:
	var health: NpcHealth = _health()
	return health.living_target_ids() if health != null else PackedStringArray()


func melee_target_position(target_id: String) -> Vector3:
	var health: NpcHealth = _health()
	return health.position_of(target_id) if health != null else Vector3.ZERO


func apply_melee_damage(target_id: String, amount: float, attacker_id: String, weapon: MeleeWeaponDefinition) -> ActionResult:
	var health: NpcHealth = _health()
	if health == null:
		return ActionResult.failure(NpcHealth.REASON_UNAVAILABLE)
	return health.apply_damage(target_id, DamageInput.create(attacker_id, _body_part, wound_type_of(weapon), amount))


## The wound a weapon of this kind leaves.
static func wound_type_of(weapon: MeleeWeaponDefinition) -> Wound.Type:
	if weapon != null and (weapon.category == MeleeWeaponDefinition.Category.BLADE or weapon.category == MeleeWeaponDefinition.Category.AXE):
		return Wound.Type.LACERATION
	return Wound.Type.BRUISE


func _health() -> NpcHealth:
	return _health_ref.get_ref() as NpcHealth
