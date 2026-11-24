class_name NpcZombieTargets
extends ZombieTargetSource
## Lets zombies see, chase and attack the NPCs (F-25, docs/09 §17.12): the
## living NPCs that are awake. A bite or a scratch becomes a wound and an
## infection roll of NpcHealth. Holds the stage weakly (the NPC system owns
## it).

var _health_ref: WeakRef


func _init(health: NpcHealth) -> void:
	_health_ref = weakref(health)


func target_ids() -> PackedStringArray:
	var health: NpcHealth = _health()
	return health.living_target_ids() if health != null else PackedStringArray()


func is_target(target_id: String) -> bool:
	var health: NpcHealth = _health()
	return health != null and health.is_living_target(target_id)


func target_position(target_id: String) -> Vector3:
	var health: NpcHealth = _health()
	return health.position_of(target_id) if health != null else Vector3.ZERO


func receive_attack(target_id: String, damage: DamageInput, exposure: InfectionState.Exposure) -> ActionResult:
	var health: NpcHealth = _health()
	if health == null:
		return ActionResult.failure(NpcHealth.REASON_UNAVAILABLE)
	var hit: ActionResult = health.apply_damage(target_id, damage)
	if not hit.ok:
		return hit
	var infection: ActionResult = health.apply_infection_exposure(target_id, exposure, damage.source_id)
	return ActionResult.success({
		"health_after": float(hit.event["health_after"]),
		"died": bool(hit.event["died"]),
		"infection": str(infection.event["event_type"]) if infection.ok else infection.reason,
	})


func _health() -> NpcHealth:
	return _health_ref.get_ref() as NpcHealth
