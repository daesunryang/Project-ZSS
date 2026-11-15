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
##   apply_infection_exposure(player_id, InfectionState.Exposure, source_id) -> ActionResult
##
## B1 scope: state, damage/wounds, death flag, stamina spend/regen,
## multipliers, infection exposure roll (NONE -> LATENT). Needs progression
## (B2), bleeding/healing/respawn (B3), infection stage progression (B4) and
## replication (B5) come later.

const SYSTEM_ID: String = "survival"
const ENTITY_KIND_WOUND: String = "wound"

const EVENT_PLAYER_WOUNDED: String = "player_wounded"
const EVENT_PLAYER_INFECTED: String = "player_infected"
const EVENT_INFECTION_RESISTED: String = "infection_exposure_resisted"

const REASON_UNKNOWN_PLAYER: String = "unknown_player"
const REASON_PLAYER_DEAD: String = "player_dead"
const REASON_ALREADY_INFECTED: String = "already_infected"
const REASON_BAD_EXPOSURE: String = "bad_exposure"

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


## Movement speed factor from leg/foot wounds (1.0 = unhurt, 0 if dead).
func movement_speed_multiplier(player_id: String) -> float:
	return _wound_multiplier(player_id, false, _settings.movement_penalty_per_severity, _settings.min_movement_multiplier)


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
	wound.source_id = damage.source_id
	wound.created_at_world_time = _clock.world_time_sec
	if vitals.injuries.size() < _settings.max_wounds_per_player:
		vitals.injuries.append(wound)
	vitals.health = maxf(vitals.health - damage.amount, 0.0)
	var died: bool = not vitals.is_alive()
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


func on_player_offline(_world: ServerWorld, player_id: String) -> void:
	_online.erase(player_id)


func step(_world: ServerWorld, _real_delta: float, world_delta: float) -> void:
	if world_delta <= 0.0 or _settings.stamina_regen_per_world_sec <= 0.0:
		return
	for player_id: String in _online:
		var vitals: PlayerVitals = _vitals.get(player_id, null)
		if vitals != null and vitals.is_alive():
			vitals.stamina = minf(vitals.stamina + _settings.stamina_regen_per_world_sec * world_delta, _settings.max_stamina)


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
