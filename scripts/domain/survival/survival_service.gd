class_name SurvivalService
extends ServerSystem
## Server-authoritative player survival state (docs/02 §2-§3, §7).
## System id "survival"; registered by ServerComposition.
##
## Public API for other systems (combat, zombies). Callers never mutate the
## returned PlayerVitals; all changes go through these methods.
##   is_alive(player_id) -> bool
##   try_spend_stamina(player_id, amount) -> bool
##   handling_multiplier(player_id) -> float        (arms/hands wounds)
##   movement_speed_multiplier(player_id) -> float  (legs/feet wounds)
##   apply_damage(player_id, DamageInput) -> ActionResult
##   stop_bleeding(player_id, wound_id) -> ActionResult
##   apply_infection_exposure(player_id, InfectionState.Exposure, source_id) -> ActionResult
##
##   need_category(player_id, NeedKind.Kind) -> NeedKind.Category
##   worst_need_category(player_id) -> NeedKind.Category
##
## B3 adds persistent bleeding, conditional natural recovery, need-max health
## damage, and delayed development respawn. Time rules run only for online
## players and consume world_delta, never real_delta.

const SYSTEM_ID: String = "survival"
const ENTITY_KIND_WOUND: String = "wound"

const EVENT_PLAYER_WOUNDED: String = "player_wounded"
const EVENT_PLAYER_BLEEDING_STOPPED: String = "player_bleeding_stopped"
const EVENT_PLAYER_SURVIVAL_DAMAGE: String = "player_survival_damage"
const EVENT_PLAYER_DIED: String = "player_died"
const EVENT_PLAYER_RESPAWNED: String = "player_respawned"
const EVENT_PLAYER_INFECTED: String = "player_infected"
const EVENT_INFECTION_RESISTED: String = "infection_exposure_resisted"

const REASON_UNKNOWN_PLAYER: String = "unknown_player"
const REASON_PLAYER_DEAD: String = "player_dead"
const REASON_ALREADY_INFECTED: String = "already_infected"
const REASON_BAD_EXPOSURE: String = "bad_exposure"
const REASON_UNKNOWN_WOUND: String = "unknown_wound"
const REASON_NOT_BLEEDING: String = "not_bleeding"

const CAUSE_COMBAT: String = "combat"
const CAUSE_BLEEDING: String = "bleeding"
const CAUSE_STARVATION: String = "starvation"
const CAUSE_DEHYDRATION: String = "dehydration"
const CAUSE_STARVATION_DEHYDRATION: String = "starvation_dehydration"
const DEATH_SEARCH_ITERATIONS: int = 48

const FULL_MULTIPLIER: float = 1.0
const DEAD_MULTIPLIER: float = 0.0

var _settings: SurvivalSettings
var _ids: EntityIdGenerator
var _clock: WorldClock
var _vitals: Dictionary[String, PlayerVitals] = {}
var _online: Dictionary[String, bool] = {}


func _init(settings: SurvivalSettings, ids: EntityIdGenerator, clock: WorldClock) -> void:
	_settings = settings
	_ids = ids
	_clock = clock


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ public API

func has_player(player_id: String) -> bool:
	return _vitals.has(player_id)


## Read-only view of a player's vitals (null if unknown). Do not mutate.
func get_vitals(player_id: String) -> PlayerVitals:
	return _vitals.get(player_id, null)


func is_alive(player_id: String) -> bool:
	var vitals: PlayerVitals = _vitals.get(player_id, null)
	return vitals != null and vitals.is_alive()


## Spends stamina if the player is alive and has enough. Invalid amounts
## (negative, NaN) are refused.
func try_spend_stamina(player_id: String, amount: float) -> bool:
	var vitals: PlayerVitals = _vitals.get(player_id, null)
	if vitals == null or not vitals.is_alive() or not is_finite(amount) or amount < 0.0:
		return false
	if vitals.stamina < amount:
		return false
	vitals.stamina -= amount
	return true


## Weapon handling factor from arm/hand wounds (1.0 = unhurt, 0 if dead).
func handling_multiplier(player_id: String) -> float:
	return _wound_multiplier(player_id, true, _settings.handling_penalty_per_severity, _settings.min_handling_multiplier)


## Movement speed factor from leg/foot wounds and the worst need category
## (1.0 = unhurt and well fed, 0 if dead, never below the configured floor).
func movement_speed_multiplier(player_id: String) -> float:
	var wound_factor: float = _wound_multiplier(player_id, false, _settings.movement_penalty_per_severity, _settings.min_movement_multiplier)
	if wound_factor <= DEAD_MULTIPLIER:
		return wound_factor
	var need_factor: float = _settings.need_movement_multiplier(worst_need_category(player_id))
	return clampf(wound_factor * need_factor, _settings.min_movement_multiplier, FULL_MULTIPLIER)


## Display category of one need (GOOD for unknown players or needs).
func need_category(player_id: String, kind: NeedKind.Kind) -> NeedKind.Category:
	var vitals: PlayerVitals = _vitals.get(player_id, null)
	if vitals == null or not NeedKind.is_valid_kind(kind):
		return NeedKind.Category.GOOD
	return NeedKind.category_for(_need_value(vitals, kind), _settings.need_caution_threshold, _settings.need_danger_threshold)


## Worst category across hunger, thirst and fatigue.
func worst_need_category(player_id: String) -> NeedKind.Category:
	var worst: NeedKind.Category = NeedKind.Category.GOOD
	for kind_index: int in NeedKind.KIND_NAMES.size():
		worst = maxi(worst, need_category(player_id, kind_index as NeedKind.Kind)) as NeedKind.Category
	return worst


## Applies server-computed damage: records a wound, reduces health and marks
## death at 0. Success event:
##   {event_type: "player_wounded", player_id, source_id, damage, health_after,
##    died: bool, world_time, wound: Wound.to_dict()}
## Failure reasons: DamageInput.REASON_*, unknown_player, player_dead.
func apply_damage(player_id: String, damage: DamageInput) -> ActionResult:
	var reason: String = damage.validate()
	if reason.is_empty():
		reason = _check_living(player_id)
	if not reason.is_empty():
		GameLogger.warning("survival", "damage rejected", {"player_id": player_id, "source_id": damage.source_id, "reason": reason, "operation": "apply_damage"})
		return ActionResult.failure(reason)
	var vitals: PlayerVitals = _vitals[player_id]
	var wound: Wound = Wound.new()
	wound.wound_id = _ids.next_id(ENTITY_KIND_WOUND)
	wound.body_part = damage.body_part
	wound.wound_type = damage.wound_type
	wound.severity = clampf(damage.amount / _settings.wound_severity_reference_damage, 0.0, Wound.MAX_SEVERITY)
	wound.is_bleeding = _settings.wound_starts_bleeding(wound.wound_type, wound.severity)
	wound.source_id = damage.source_id
	wound.created_at_world_time = _clock.world_time_sec
	if vitals.injuries.size() < _settings.max_wounds_per_player:
		vitals.injuries.append(wound)
	vitals.health = maxf(vitals.health - damage.amount, 0.0)
	var died: bool = not vitals.is_alive()
	if died:
		_mark_dead(player_id, vitals, _clock.world_time_sec, CAUSE_COMBAT)
	GameLogger.info("survival", "player wounded", {
		"player_id": player_id, "entity_id": wound.wound_id, "source_id": damage.source_id,
		"body_part": BodyPart.to_name(wound.body_part), "wound_type": Wound.type_name(wound.wound_type),
		"damage": damage.amount, "health": vitals.health, "died": died,
	})
	return ActionResult.success({
		"event_type": EVENT_PLAYER_WOUNDED,
		"player_id": player_id,
		"source_id": damage.source_id,
		"damage": damage.amount,
		"health_after": vitals.health,
		"died": died,
		"world_time": _clock.world_time_sec,
		"wound": wound.to_dict(),
	})


## Stops one recorded wound from bleeding. Medical-item consumption is owned
## by a later ticket; this is the server-authoritative treatment seam.
func stop_bleeding(player_id: String, wound_id: String) -> ActionResult:
	var reason: String = _check_living(player_id)
	if not reason.is_empty():
		return ActionResult.failure(reason)
	var target: Wound = null
	for wound: Wound in _vitals[player_id].injuries:
		if wound.wound_id == wound_id:
			target = wound
			break
	if target == null:
		return ActionResult.failure(REASON_UNKNOWN_WOUND)
	if not target.is_bleeding:
		return ActionResult.failure(REASON_NOT_BLEEDING)
	target.is_bleeding = false
	var event: Dictionary = {
		"event_type": EVENT_PLAYER_BLEEDING_STOPPED,
		"player_id": player_id,
		"wound_id": wound_id,
		"world_time": _clock.world_time_sec,
	}
	GameLogger.info("survival", "player bleeding stopped", event)
	return ActionResult.success(event)


## Rolls an infection exposure with the player's saved RNG.
## Success events: "player_infected" (stage -> latent) or
## "infection_exposure_resisted"; both carry {player_id, exposure, source_id,
## chance, world_time}. Failure reasons: bad_exposure, unknown_player,
## player_dead, already_infected (callers may ignore that one).
func apply_infection_exposure(player_id: String, exposure: InfectionState.Exposure, source_id: String) -> ActionResult:
	var reason: String = "" if InfectionState.is_valid_exposure(exposure) else REASON_BAD_EXPOSURE
	if reason.is_empty():
		reason = _check_living(player_id)
	if reason.is_empty() and _vitals[player_id].infection.is_infected():
		reason = REASON_ALREADY_INFECTED
	if not reason.is_empty():
		return ActionResult.failure(reason)
	var vitals: PlayerVitals = _vitals[player_id]
	var chance: float = _settings.infection_chance(exposure)
	var infected: bool = vitals.rng.randf() < chance
	var event: Dictionary = {
		"event_type": EVENT_PLAYER_INFECTED if infected else EVENT_INFECTION_RESISTED,
		"player_id": player_id,
		"exposure": InfectionState.EXPOSURE_NAMES[exposure],
		"source_id": source_id,
		"chance": chance,
		"world_time": _clock.world_time_sec,
	}
	if infected:
		vitals.infection.stage = InfectionState.Stage.LATENT
		vitals.infection.exposure = exposure
		vitals.infection.source_id = source_id
		vitals.infection.infected_at_world_time = _clock.world_time_sec
		vitals.infection.stage_entered_at_world_time = _clock.world_time_sec
		GameLogger.info("survival", "player infected", {"player_id": player_id, "source_id": source_id, "exposure": event["exposure"]})
	return ActionResult.success(event)


# ------------------------------------------------------------ ServerSystem

func on_player_online(_world: ServerWorld, player_id: String) -> void:
	_online[player_id] = true
	if not _vitals.has(player_id):
		_vitals[player_id] = PlayerVitals.create_default(_settings, _seed_for(player_id))
	elif not _vitals[player_id].is_alive() and _vitals[player_id].died_at_world_time == PlayerVitals.NOT_DEAD_TIME:
		# A schema-v1 dead player had no death timestamp. Start the development
		# respawn delay on the first online world instant after migration.
		_vitals[player_id].died_at_world_time = _clock.world_time_sec


func on_player_offline(_world: ServerWorld, player_id: String) -> void:
	_online.erase(player_id)


func step(world: ServerWorld, _real_delta: float, world_delta: float) -> void:
	if world_delta <= 0.0:
		return
	# ServerWorld advances its clock before systems. The fallback also makes
	# direct unit calls deterministic when the supplied test clock stayed at 0.
	var step_start: float = maxf(_clock.world_time_sec - world_delta, 0.0)
	var step_end: float = step_start + world_delta
	for player_id: String in _online:
		var vitals: PlayerVitals = _vitals.get(player_id, null)
		if vitals == null:
			continue
		_advance_player(world, player_id, vitals, step_start, step_end)


func to_player_fragment(player_id: String) -> Dictionary:
	var vitals: PlayerVitals = _vitals.get(player_id, null)
	return {} if vitals == null else vitals.to_dict()


func restore_player_fragment(player_id: String, fragment: Dictionary) -> PackedStringArray:
	var parsed: Array = PlayerVitals.from_dict(fragment, _settings)
	var errors: PackedStringArray = parsed[1]
	if not errors.is_empty():
		var prefixed: PackedStringArray = []
		for error: String in errors:
			prefixed.append("%s: %s" % [player_id, error])
		return prefixed
	var vitals: PlayerVitals = parsed[0]
	for wound: Wound in vitals.injuries:
		_ids.reserve_existing_id(wound.wound_id)
	_vitals[player_id] = vitals
	return PackedStringArray()


# ------------------------------------------------------------ internals

## Advances alternating living/dead portions of one world-time interval. This
## lets a large tick cross an exact death or respawn boundary with the same
## result as many small ticks.
func _advance_player(world: ServerWorld, player_id: String, vitals: PlayerVitals, start_time: float, end_time: float) -> void:
	var cursor: float = start_time
	while cursor < end_time:
		if not vitals.is_alive():
			if vitals.died_at_world_time == PlayerVitals.NOT_DEAD_TIME:
				vitals.died_at_world_time = cursor
			var respawn_at: float = vitals.died_at_world_time + _settings.respawn_delay_world_sec
			if respawn_at > end_time:
				return
			if not _respawn(world, player_id, vitals, respawn_at):
				return
			cursor = maxf(cursor, respawn_at)
			continue
		var remaining: float = end_time - cursor
		var death_offset: float = _survival_death_offset(vitals, remaining)
		if death_offset < 0.0:
			_advance_living(player_id, vitals, remaining, cursor)
			return
		var cause: String = _survival_damage_cause(vitals, death_offset)
		_advance_living(player_id, vitals, death_offset, cursor)
		vitals.health = 0.0
		cursor += death_offset
		_mark_dead(player_id, vitals, cursor, cause)


## Applies continuous living-player rules for exactly `elapsed` world seconds.
func _advance_living(player_id: String, vitals: PlayerVitals, elapsed: float, start_time: float) -> void:
	if elapsed <= 0.0:
		return
	var recovery_duration: float = _natural_recovery_duration(vitals, elapsed)
	var recovery: float = _settings.health_recovery_per_world_sec * recovery_duration
	var bleeding_damage: float = _bleeding_rate(vitals) * elapsed
	var starvation_damage: float = _settings.starvation_health_loss_per_world_sec * _need_time_at_max(vitals, NeedKind.Kind.HUNGER, elapsed)
	var dehydration_damage: float = _settings.dehydration_health_loss_per_world_sec * _need_time_at_max(vitals, NeedKind.Kind.THIRST, elapsed)
	var total_damage: float = bleeding_damage + starvation_damage + dehydration_damage
	if recovery > 0.0:
		vitals.health = minf(vitals.health + recovery, _settings.max_health)
	if recovery_duration > 0.0 and _settings.wound_recovery_per_world_sec > 0.0:
		_heal_wounds(vitals, recovery_duration)
	if total_damage > 0.0:
		vitals.health = maxf(vitals.health - total_damage, 0.0)
		GameLogger.info("survival", "player survival damage", {
			"event_type": EVENT_PLAYER_SURVIVAL_DAMAGE,
			"player_id": player_id,
			"cause": _survival_damage_cause(vitals, elapsed, bleeding_damage, starvation_damage, dehydration_damage),
			"damage": total_damage,
			"health_after": vitals.health,
			"world_time": start_time + elapsed,
		})
	var stamina_recovery: float = _stamina_recovery(vitals, elapsed)
	if stamina_recovery > 0.0:
		vitals.stamina = minf(vitals.stamina + stamina_recovery, _settings.max_stamina)
	_advance_needs(player_id, vitals, elapsed)


## -1 when survival damage cannot kill during elapsed; otherwise the first
## death offset. Bisection is deterministic and much tighter than gameplay's
## 1e-3 tolerance while handling different need-max crossing times.
func _survival_death_offset(vitals: PlayerVitals, elapsed: float) -> float:
	if _health_after_elapsed(vitals, elapsed) > 0.0:
		return -1.0
	var low: float = 0.0
	var high: float = elapsed
	for _iteration: int in DEATH_SEARCH_ITERATIONS:
		var middle: float = (low + high) * 0.5
		if _health_after_elapsed(vitals, middle) > 0.0:
			low = middle
		else:
			high = middle
	return high


func _health_after_elapsed(vitals: PlayerVitals, elapsed: float) -> float:
	var recovered: float = minf(
		vitals.health + _settings.health_recovery_per_world_sec * _natural_recovery_duration(vitals, elapsed),
		_settings.max_health
	)
	var damage: float = _bleeding_rate(vitals) * elapsed
	damage += _settings.starvation_health_loss_per_world_sec * _need_time_at_max(vitals, NeedKind.Kind.HUNGER, elapsed)
	damage += _settings.dehydration_health_loss_per_world_sec * _need_time_at_max(vitals, NeedKind.Kind.THIRST, elapsed)
	return recovered - damage


## Duration for which all needs remain GOOD. Bleeding makes it zero.
func _natural_recovery_duration(vitals: PlayerVitals, elapsed: float) -> float:
	if _has_bleeding(vitals):
		return 0.0
	var duration: float = elapsed
	for kind_index: int in NeedKind.KIND_NAMES.size():
		var kind: NeedKind.Kind = kind_index as NeedKind.Kind
		var value: float = _need_value(vitals, kind)
		if value >= _settings.need_caution_threshold:
			return 0.0
		var rate: float = _settings.need_rate_per_world_sec(kind)
		if rate > 0.0:
			duration = minf(duration, (_settings.need_caution_threshold - value) / rate)
	return maxf(duration, 0.0)


func _need_time_at_max(vitals: PlayerVitals, kind: NeedKind.Kind, elapsed: float) -> float:
	var value: float = _need_value(vitals, kind)
	if value >= _settings.need_max:
		return elapsed
	var rate: float = _settings.need_rate_per_world_sec(kind)
	if rate <= 0.0:
		return 0.0
	return maxf(elapsed - (_settings.need_max - value) / rate, 0.0)


func _bleeding_rate(vitals: PlayerVitals) -> float:
	var rate: float = 0.0
	for wound: Wound in vitals.injuries:
		if wound.is_bleeding:
			rate += _settings.bleeding_health_loss_per_severity_per_world_sec * _settings.bleeding_type_multiplier(wound.wound_type) * wound.severity
	return rate


func _has_bleeding(vitals: PlayerVitals) -> bool:
	for wound: Wound in vitals.injuries:
		if wound.is_bleeding:
			return true
	return false


func _heal_wounds(vitals: PlayerVitals, elapsed: float) -> void:
	var reduction: float = _settings.wound_recovery_per_world_sec * elapsed
	for index: int in range(vitals.injuries.size() - 1, -1, -1):
		var wound: Wound = vitals.injuries[index]
		wound.severity = maxf(wound.severity - reduction, 0.0)
		if wound.severity <= 0.0:
			vitals.injuries.remove_at(index)


## Integrates the worst-need stamina multiplier across every threshold crossed
## during the interval instead of applying the end category to the whole tick.
func _stamina_recovery(vitals: PlayerVitals, elapsed: float) -> float:
	if _settings.stamina_regen_per_world_sec <= 0.0:
		return 0.0
	var boundaries: Array[float] = [0.0, elapsed]
	for kind_index: int in NeedKind.KIND_NAMES.size():
		var kind: NeedKind.Kind = kind_index as NeedKind.Kind
		var value: float = _need_value(vitals, kind)
		var rate: float = _settings.need_rate_per_world_sec(kind)
		if rate <= 0.0:
			continue
		for threshold: float in [_settings.need_caution_threshold, _settings.need_danger_threshold]:
			var crossing: float = (threshold - value) / rate
			if crossing > 0.0 and crossing < elapsed:
				boundaries.append(crossing)
	boundaries.sort()
	var recovered: float = 0.0
	for index: int in range(boundaries.size() - 1):
		var segment_start: float = boundaries[index]
		var segment_end: float = boundaries[index + 1]
		var category: NeedKind.Category = _worst_need_category_at(vitals, (segment_start + segment_end) * 0.5)
		recovered += _settings.stamina_regen_per_world_sec * _settings.stamina_regen_multiplier(category) * (segment_end - segment_start)
	return recovered


func _worst_need_category_at(vitals: PlayerVitals, elapsed: float) -> NeedKind.Category:
	var worst: NeedKind.Category = NeedKind.Category.GOOD
	for kind_index: int in NeedKind.KIND_NAMES.size():
		var kind: NeedKind.Kind = kind_index as NeedKind.Kind
		var projected: float = minf(_need_value(vitals, kind) + _settings.need_rate_per_world_sec(kind) * elapsed, _settings.need_max)
		var category: NeedKind.Category = NeedKind.category_for(projected, _settings.need_caution_threshold, _settings.need_danger_threshold)
		worst = maxi(worst, category) as NeedKind.Category
	return worst


func _survival_damage_cause(vitals: PlayerVitals, elapsed: float, bleeding_damage: float = -1.0, starvation_damage: float = -1.0, dehydration_damage: float = -1.0) -> String:
	var has_bleeding: bool = bleeding_damage > 0.0 if bleeding_damage >= 0.0 else _bleeding_rate(vitals) * elapsed > 0.0
	var has_starvation: bool = starvation_damage > 0.0 if starvation_damage >= 0.0 else _settings.starvation_health_loss_per_world_sec * _need_time_at_max(vitals, NeedKind.Kind.HUNGER, elapsed) > 0.0
	var has_dehydration: bool = dehydration_damage > 0.0 if dehydration_damage >= 0.0 else _settings.dehydration_health_loss_per_world_sec * _need_time_at_max(vitals, NeedKind.Kind.THIRST, elapsed) > 0.0
	var need_cause: String = ""
	if has_starvation and has_dehydration:
		need_cause = CAUSE_STARVATION_DEHYDRATION
	elif has_starvation:
		need_cause = CAUSE_STARVATION
	elif has_dehydration:
		need_cause = CAUSE_DEHYDRATION
	if has_bleeding and not need_cause.is_empty():
		return "%s_%s" % [CAUSE_BLEEDING, need_cause]
	if has_bleeding:
		return CAUSE_BLEEDING
	return need_cause


func _mark_dead(player_id: String, vitals: PlayerVitals, world_time: float, cause: String) -> void:
	vitals.health = 0.0
	vitals.died_at_world_time = world_time
	GameLogger.info("survival", "player died", {
		"event_type": EVENT_PLAYER_DIED,
		"player_id": player_id,
		"cause": cause,
		"world_time": world_time,
	})


func _respawn(world: ServerWorld, player_id: String, vitals: PlayerVitals, world_time: float) -> bool:
	if not world.respawn_player_at_spawn(player_id):
		GameLogger.error("survival", "respawn rejected for missing world player", {"player_id": player_id, "operation": "respawn_player"})
		return false
	vitals.health = _settings.max_health
	vitals.stamina = _settings.max_stamina
	vitals.hunger = _settings.respawn_hunger
	vitals.thirst = _settings.respawn_thirst
	vitals.fatigue = _settings.respawn_fatigue
	vitals.injuries.clear()
	vitals.infection = InfectionState.new()
	vitals.died_at_world_time = PlayerVitals.NOT_DEAD_TIME
	GameLogger.info("survival", "player respawned", {
		"event_type": EVENT_PLAYER_RESPAWNED,
		"player_id": player_id,
		"world_time": world_time,
	})
	return true

## Raises each need by rate * world_delta (clamped to need_max) and logs
## category changes so balance problems are visible in server logs.
func _advance_needs(player_id: String, vitals: PlayerVitals, world_delta: float) -> void:
	for kind_index: int in NeedKind.KIND_NAMES.size():
		var kind: NeedKind.Kind = kind_index as NeedKind.Kind
		var before: NeedKind.Category = need_category(player_id, kind)
		var raised: float = minf(_need_value(vitals, kind) + _settings.need_rate_per_world_sec(kind) * world_delta, _settings.need_max)
		vitals.set(NeedKind.kind_name(kind), raised)
		var after: NeedKind.Category = need_category(player_id, kind)
		if after != before:
			GameLogger.info("survival", "need category changed", {
				"player_id": player_id, "need": NeedKind.kind_name(kind),
				"category": NeedKind.category_name(after), "value": raised,
			})


func _need_value(vitals: PlayerVitals, kind: NeedKind.Kind) -> float:
	return float(vitals.get(NeedKind.kind_name(kind)))


func _check_living(player_id: String) -> String:
	var vitals: PlayerVitals = _vitals.get(player_id, null)
	if vitals == null:
		return REASON_UNKNOWN_PLAYER
	if not vitals.is_alive():
		return REASON_PLAYER_DEAD
	return ""


func _wound_multiplier(player_id: String, handling: bool, penalty: float, minimum: float) -> float:
	var vitals: PlayerVitals = _vitals.get(player_id, null)
	if vitals == null:
		return FULL_MULTIPLIER
	if not vitals.is_alive():
		return DEAD_MULTIPLIER
	var total_severity: float = 0.0
	for wound: Wound in vitals.injuries:
		var relevant: bool = BodyPart.affects_handling(wound.body_part) if handling else BodyPart.affects_movement(wound.body_part)
		if relevant:
			total_severity += wound.severity
	return clampf(FULL_MULTIPLIER - penalty * total_severity, minimum, FULL_MULTIPLIER)


func _seed_for(player_id: String) -> int:
	return ("%d:%s" % [_settings.rng_seed, player_id]).hash()
