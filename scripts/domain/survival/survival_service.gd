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
##   apply_infection_treatment(player_id, source_id) -> ActionResult
##   infection_stage(player_id) -> InfectionState.Stage
##   check_reduce_needs(player_id, hunger, thirst) -> String   (preflight)
##   reduce_needs(player_id, hunger, thirst, source_id) -> ActionResult
##   drain_events() -> Array[Dictionary]             (network read surface)
##
##   need_category(player_id, NeedKind.Kind) -> NeedKind.Category
##   worst_need_category(player_id) -> NeedKind.Category
##
## B3 adds bleeding/recovery/death/respawn. B4 adds configured infection
## stages, effects and treatment. Time rules run only for online players.
##
## Two time axes (docs/00 ADR-006, docs/09 §14.16):
##   calendar time (world_delta, WorldClock.world_time_sec): needs, infection
##     stages and their health loss, bleeding, natural health/wound recovery,
##     starvation and dehydration.
##   action time (action_delta, WorldClock.action_time_sec, real seconds):
##     stamina regeneration, the respawn delay and the interval that batches
##     "player_survival_damage" events.
## The integrator walks the calendar interval of a tick; inside one tick the
## two clocks advance linearly, so an action-time amount or deadline is
## converted with the ratio of that tick. The result does not depend on tick
## size. The `world_time` of every event and the `*_world_time` fields of
## wounds and infection are calendar time.

const SYSTEM_ID: String = "survival"
const ENTITY_KIND_WOUND: String = "wound"

const EVENT_PLAYER_WOUNDED: String = "player_wounded"
const EVENT_PLAYER_BLEEDING_STOPPED: String = "player_bleeding_stopped"
const EVENT_PLAYER_SURVIVAL_DAMAGE: String = "player_survival_damage"
const EVENT_PLAYER_DIED: String = "player_died"
const EVENT_PLAYER_RESPAWNED: String = "player_respawned"
const EVENT_PLAYER_INFECTED: String = "player_infected"
const EVENT_INFECTION_RESISTED: String = "infection_exposure_resisted"
const EVENT_PLAYER_INFECTION_STAGE_CHANGED: String = "player_infection_stage_changed"
const EVENT_PLAYER_INFECTION_CURED: String = "player_infection_cured"
const EVENT_NEED_CATEGORY_CHANGED: String = "need_category_changed"
## Hunger and/or thirst were lowered (eating, drinking; P2-T3).
const EVENT_PLAYER_NEEDS_REDUCED: String = "player_needs_reduced"

const REASON_UNKNOWN_PLAYER: String = "unknown_player"
## A need amount that is not finite, negative, or both amounts are 0.
const REASON_BAD_NEED_AMOUNT: String = "bad_need_amount"
const REASON_PLAYER_DEAD: String = "player_dead"
const REASON_ALREADY_INFECTED: String = "already_infected"
const REASON_BAD_EXPOSURE: String = "bad_exposure"
const REASON_UNKNOWN_WOUND: String = "unknown_wound"
const REASON_NOT_BLEEDING: String = "not_bleeding"
const REASON_NOT_INFECTED: String = "not_infected"
const REASON_TOO_LATE: String = "too_late"

const CAUSE_COMBAT: String = "combat"
const CAUSE_BLEEDING: String = "bleeding"
const CAUSE_STARVATION: String = "starvation"
const CAUSE_DEHYDRATION: String = "dehydration"
const CAUSE_STARVATION_DEHYDRATION: String = "starvation_dehydration"
const CAUSE_INFECTION: String = "infection"
const DEATH_SEARCH_ITERATIONS: int = 48
## Action time is a sum of tick lengths; a report interval that is due within
## this tolerance counts as elapsed.
const DAMAGE_REPORT_EPSILON_SEC: float = 0.000001

const FULL_MULTIPLIER: float = 1.0
const DEAD_MULTIPLIER: float = 0.0

var _settings: SurvivalSettings
var _ids: EntityIdGenerator
var _clock: WorldClock
var _vitals: Dictionary[String, PlayerVitals] = {}
var _online: Dictionary[String, bool] = {}
var _events: Array[Dictionary] = []
## Events discarded because the configured pending queue was full.
var dropped_event_count: int = 0
## Time-based damage not yet reported, per player:
## {"since": action time of the first unreported tick, "bleeding", "starvation",
## "dehydration", "infection": accumulated damage}. Health is already applied;
## only the event/log is batched (docs/15 P2-88). Transient, not saved.
var _pending_damage: Dictionary[String, Dictionary] = {}
## Clock mapping of the tick being integrated (set by step()). Calendar and
## action time advance linearly inside one tick:
##   action = _step_action_start + (world - _step_world_start) * _step_action_per_world_sec
var _step_world_start: float = 0.0
var _step_action_start: float = 0.0
var _step_action_end: float = 0.0
## Action seconds per calendar second in this tick (1 / time scale; 0 when a
## caller passes no action time).
var _step_action_per_world_sec: float = 0.0


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


## Returns and clears queued JSON-safe events in occurrence order.
func drain_events() -> Array[Dictionary]:
	var drained: Array[Dictionary] = _events
	_events = []
	return drained


func is_alive(player_id: String) -> bool:
	var vitals: PlayerVitals = _vitals.get(player_id, null)
	return vitals != null and vitals.is_alive()


## Current server-authoritative infection stage; NONE for an unknown player.
func infection_stage(player_id: String) -> InfectionState.Stage:
	var vitals: PlayerVitals = _vitals.get(player_id, null)
	return InfectionState.Stage.NONE if vitals == null else vitals.infection.stage


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
	var event: Dictionary = {
		"event_type": EVENT_PLAYER_WOUNDED,
		"player_id": player_id,
		"source_id": damage.source_id,
		"damage": damage.amount,
		"health_after": vitals.health,
		"died": died,
		"world_time": _clock.world_time_sec,
		"wound": wound.to_dict(),
	}
	_push_event(event)
	if died:
		_mark_dead(player_id, vitals, _clock.world_time_sec, _clock.action_time_sec, CAUSE_COMBAT)
	GameLogger.info("survival", "player wounded", {
		"player_id": player_id, "entity_id": wound.wound_id, "source_id": damage.source_id,
		"body_part": BodyPart.to_name(wound.body_part), "wound_type": Wound.type_name(wound.wound_type),
		"damage": damage.amount, "health": vitals.health, "died": died,
	})
	return ActionResult.success(event)


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
	_push_event(event)
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
		vitals.infection.stage_elapsed_world_sec = 0.0
		GameLogger.info("survival", "player infected", {"player_id": player_id, "source_id": source_id, "exposure": event["exposure"]})
	_push_event(event)
	return ActionResult.success(event)


## Clears infection through the configured maximum treatable stage. Item,
## quality and medical-skill checks are intentionally left to a later ticket.
func apply_infection_treatment(player_id: String, source_id: String) -> ActionResult:
	var reason: String = _check_living(player_id)
	if not reason.is_empty():
		return ActionResult.failure(reason)
	var vitals: PlayerVitals = _vitals[player_id]
	if not vitals.infection.is_infected():
		return ActionResult.failure(REASON_NOT_INFECTED)
	if vitals.infection.stage > _settings.infection_treatment_max_stage:
		return ActionResult.failure(REASON_TOO_LATE)
	var previous: InfectionState.Stage = vitals.infection.stage
	vitals.infection = InfectionState.new()
	var event: Dictionary = {
		"event_type": EVENT_PLAYER_INFECTION_CURED,
		"player_id": player_id,
		"source_id": source_id,
		"from": InfectionState.stage_name(previous),
		"world_time": _clock.world_time_sec,
	}
	_push_event(event)
	GameLogger.info("survival", "player infection cured", event)
	return ActionResult.success(event)


## "" when reduce_needs() with these arguments would succeed now, otherwise
## its failure reason. Changes nothing: callers that must commit something
## else together with the reduction (ItemConsumption) check first.
func check_reduce_needs(player_id: String, hunger_amount: float, thirst_amount: float) -> String:
	if not is_finite(hunger_amount) or not is_finite(thirst_amount) or hunger_amount < 0.0 or thirst_amount < 0.0:
		return REASON_BAD_NEED_AMOUNT
	if hunger_amount <= 0.0 and thirst_amount <= 0.0:
		return REASON_BAD_NEED_AMOUNT
	return _check_living(player_id)


## Lowers hunger and thirst by the given need units (server rule entry, e.g.
## eating and drinking; P2-T3). A need never drops below 0. Fatigue is not
## touched. Success event (also queued and logged):
##   {event_type: "player_needs_reduced", player_id, source_id,
##    hunger_reduced, thirst_reduced (what was actually taken off),
##    hunger_after, thirst_after, world_time}
## followed in the queue by "need_category_changed" for every category that
## changed. Failure reasons: bad_need_amount, unknown_player, player_dead;
## a refused call changes nothing.
func reduce_needs(player_id: String, hunger_amount: float, thirst_amount: float, source_id: String) -> ActionResult:
	var reason: String = check_reduce_needs(player_id, hunger_amount, thirst_amount)
	if not reason.is_empty():
		GameLogger.warning("survival", "need reduction rejected", {"player_id": player_id, "source_id": source_id, "reason": reason, "operation": "reduce_needs"})
		return ActionResult.failure(reason)
	var vitals: PlayerVitals = _vitals[player_id]
	var hunger_before: NeedKind.Category = need_category(player_id, NeedKind.Kind.HUNGER)
	var thirst_before: NeedKind.Category = need_category(player_id, NeedKind.Kind.THIRST)
	var hunger_reduced: float = minf(vitals.hunger, hunger_amount)
	var thirst_reduced: float = minf(vitals.thirst, thirst_amount)
	vitals.hunger = maxf(vitals.hunger - hunger_reduced, 0.0)
	vitals.thirst = maxf(vitals.thirst - thirst_reduced, 0.0)
	var event: Dictionary = {
		"event_type": EVENT_PLAYER_NEEDS_REDUCED,
		"player_id": player_id,
		"source_id": source_id,
		"hunger_reduced": hunger_reduced,
		"thirst_reduced": thirst_reduced,
		"hunger_after": vitals.hunger,
		"thirst_after": vitals.thirst,
		"world_time": _clock.world_time_sec,
	}
	_push_event(event)
	GameLogger.info("survival", "player needs reduced", event)
	_report_need_category_change(player_id, vitals, NeedKind.Kind.HUNGER, hunger_before)
	_report_need_category_change(player_id, vitals, NeedKind.Kind.THIRST, thirst_before)
	return ActionResult.success(event)


# ------------------------------------------------------------ ServerSystem

## Server movement factor (ServerWorld.step_movement): wounds, needs, death.
func player_movement_multiplier(player_id: String) -> float:
	return movement_speed_multiplier(player_id)


func on_player_online(_world: ServerWorld, player_id: String) -> void:
	_online[player_id] = true
	if not _vitals.has(player_id):
		_vitals[player_id] = PlayerVitals.create_default(_settings, _seed_for(player_id))
	elif not _vitals[player_id].is_alive():
		# A dead player from an older fragment has no death timestamp (schema v1)
		# or no action death time (before v4). Start the development respawn
		# delay on the first online instant after migration.
		var dead: PlayerVitals = _vitals[player_id]
		if dead.died_at_world_time == PlayerVitals.NOT_DEAD_TIME:
			dead.died_at_world_time = _clock.world_time_sec
		if dead.died_at_action_time == PlayerVitals.NOT_DEAD_TIME:
			dead.died_at_action_time = _clock.action_time_sec


func on_player_offline(_world: ServerWorld, player_id: String) -> void:
	_online.erase(player_id)
	var vitals: PlayerVitals = _vitals.get(player_id, null)
	if vitals != null:
		_flush_survival_damage(player_id, vitals, _clock.world_time_sec)


func step(world: ServerWorld, action_delta: float, world_delta: float) -> void:
	if world_delta <= 0.0:
		return
	var action_elapsed: float = action_delta if is_finite(action_delta) and action_delta > 0.0 else 0.0
	# ServerWorld advances its clock before systems. The fallbacks also make
	# direct unit calls deterministic when the supplied test clock stayed at 0.
	var step_start: float = maxf(_clock.world_time_sec - world_delta, 0.0)
	var step_end: float = step_start + world_delta
	_step_world_start = step_start
	_step_action_end = maxf(_clock.action_time_sec, action_elapsed)
	_step_action_start = _step_action_end - action_elapsed
	_step_action_per_world_sec = action_elapsed / world_delta
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

## Advances alternating living/dead portions of one calendar interval (the
## tick set up by step()). This lets a large tick cross an exact death or
## respawn boundary with the same result as many small ticks. The respawn
## delay is action time: its deadline is mapped into the calendar interval
## of the tick.
func _advance_player(world: ServerWorld, player_id: String, vitals: PlayerVitals, start_time: float, end_time: float) -> void:
	var cursor: float = start_time
	while cursor < end_time:
		if not vitals.is_alive():
			if vitals.died_at_world_time == PlayerVitals.NOT_DEAD_TIME:
				vitals.died_at_world_time = cursor
			if vitals.died_at_action_time == PlayerVitals.NOT_DEAD_TIME:
				vitals.died_at_action_time = _action_time_at(cursor)
			var respawn_action_at: float = vitals.died_at_action_time + _settings.respawn_delay_sec
			if respawn_action_at > _step_action_end:
				return
			# A deadline that passed before this tick (offline) fires at once.
			var respawn_at: float = clampf(_world_time_at(respawn_action_at), cursor, end_time)
			if not _respawn(world, player_id, vitals, respawn_at):
				return
			cursor = respawn_at
			continue
		var remaining: float = end_time - cursor
		var infection_boundary: float = _infection_time_to_boundary(vitals)
		var crosses_infection_boundary: bool = infection_boundary >= 0.0 and infection_boundary <= remaining
		var segment: float = infection_boundary if crosses_infection_boundary else remaining
		if segment <= 0.0:
			_advance_infection_stage(player_id, vitals, cursor)
			if vitals.infection.stage == InfectionState.Stage.ZOMBIFIED:
				_mark_dead(player_id, vitals, cursor, _action_time_at(cursor), CAUSE_INFECTION)
			continue
		var death_offset: float = _survival_death_offset(vitals, segment)
		if death_offset < 0.0:
			_advance_living(player_id, vitals, segment, cursor)
			cursor += segment
			if crosses_infection_boundary:
				_advance_infection_stage(player_id, vitals, cursor)
				if vitals.infection.stage == InfectionState.Stage.ZOMBIFIED:
					_mark_dead(player_id, vitals, cursor, _action_time_at(cursor), CAUSE_INFECTION)
				continue
			return
		var cause: String = _survival_damage_cause(vitals, death_offset)
		_advance_living(player_id, vitals, death_offset, cursor)
		vitals.health = 0.0
		cursor += death_offset
		_mark_dead(player_id, vitals, cursor, _action_time_at(cursor), cause)


## Applies continuous living-player rules for exactly `elapsed` calendar
## seconds starting at calendar time `start_time` of the current tick.
func _advance_living(player_id: String, vitals: PlayerVitals, elapsed: float, start_time: float) -> void:
	if elapsed <= 0.0:
		return
	var recovery_duration: float = _natural_recovery_duration(vitals, elapsed)
	var recovery: float = _settings.health_recovery_per_world_sec * recovery_duration
	var bleeding_damage: float = _bleeding_rate(vitals) * elapsed
	var starvation_damage: float = _settings.starvation_health_loss_per_world_sec * _need_time_at_max(vitals, NeedKind.Kind.HUNGER, elapsed)
	var dehydration_damage: float = _settings.dehydration_health_loss_per_world_sec * _need_time_at_max(vitals, NeedKind.Kind.THIRST, elapsed)
	var infection_damage: float = _settings.infection_health_loss_per_world_sec(vitals.infection.stage) * elapsed
	var total_damage: float = bleeding_damage + starvation_damage + dehydration_damage + infection_damage
	if recovery > 0.0:
		vitals.health = minf(vitals.health + recovery, _settings.max_health)
	if recovery_duration > 0.0 and _settings.wound_recovery_per_world_sec > 0.0:
		_heal_wounds(vitals, recovery_duration)
	if total_damage > 0.0:
		vitals.health = maxf(vitals.health - total_damage, 0.0)
		_accumulate_survival_damage(player_id, vitals, start_time, start_time + elapsed, bleeding_damage, starvation_damage, dehydration_damage, infection_damage)
	var stamina_recovery: float = _stamina_recovery(vitals, elapsed)
	if stamina_recovery > 0.0:
		vitals.stamina = minf(vitals.stamina + stamina_recovery, _settings.max_stamina)
	_advance_needs(player_id, vitals, elapsed)
	if vitals.infection.is_infected() and vitals.infection.stage != InfectionState.Stage.ZOMBIFIED:
		vitals.infection.stage_elapsed_world_sec += elapsed


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
	damage += _settings.infection_health_loss_per_world_sec(vitals.infection.stage) * elapsed
	return recovered - damage


## Duration for which all needs remain GOOD. Bleeding or an active infection
## health-loss effect makes it zero.
func _natural_recovery_duration(vitals: PlayerVitals, elapsed: float) -> float:
	if _has_bleeding(vitals) or _settings.infection_health_loss_per_world_sec(vitals.infection.stage) > 0.0:
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


## Stamina regained during `elapsed` calendar seconds of the current tick.
## The rate is per action second; the worst-need multiplier is integrated
## across every (calendar) threshold crossed during the interval instead of
## applying the end category to the whole tick.
func _stamina_recovery(vitals: PlayerVitals, elapsed: float) -> float:
	if _settings.stamina_regen_per_sec <= 0.0:
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
		recovered += _settings.stamina_regen_per_sec * _settings.stamina_regen_multiplier(category) * (segment_end - segment_start)
	# `recovered` was summed over calendar seconds: convert to action seconds.
	return recovered * _step_action_per_world_sec * _settings.infection_stamina_regen_multiplier(vitals.infection.stage)


func _worst_need_category_at(vitals: PlayerVitals, elapsed: float) -> NeedKind.Category:
	var worst: NeedKind.Category = NeedKind.Category.GOOD
	for kind_index: int in NeedKind.KIND_NAMES.size():
		var kind: NeedKind.Kind = kind_index as NeedKind.Kind
		var projected: float = minf(_need_value(vitals, kind) + _settings.need_rate_per_world_sec(kind) * elapsed, _settings.need_max)
		var category: NeedKind.Category = NeedKind.category_for(projected, _settings.need_caution_threshold, _settings.need_danger_threshold)
		worst = maxi(worst, category) as NeedKind.Category
	return worst


func _survival_damage_cause(vitals: PlayerVitals, elapsed: float, bleeding_damage: float = -1.0, starvation_damage: float = -1.0, dehydration_damage: float = -1.0, infection_damage: float = -1.0) -> String:
	var has_bleeding: bool = bleeding_damage > 0.0 if bleeding_damage >= 0.0 else _bleeding_rate(vitals) * elapsed > 0.0
	var has_starvation: bool = starvation_damage > 0.0 if starvation_damage >= 0.0 else _settings.starvation_health_loss_per_world_sec * _need_time_at_max(vitals, NeedKind.Kind.HUNGER, elapsed) > 0.0
	var has_dehydration: bool = dehydration_damage > 0.0 if dehydration_damage >= 0.0 else _settings.dehydration_health_loss_per_world_sec * _need_time_at_max(vitals, NeedKind.Kind.THIRST, elapsed) > 0.0
	var has_infection: bool = infection_damage > 0.0 if infection_damage >= 0.0 else _settings.infection_health_loss_per_world_sec(vitals.infection.stage) * elapsed > 0.0
	var need_cause: String = ""
	if has_starvation and has_dehydration:
		need_cause = CAUSE_STARVATION_DEHYDRATION
	elif has_starvation:
		need_cause = CAUSE_STARVATION
	elif has_dehydration:
		need_cause = CAUSE_DEHYDRATION
	var cause: String = need_cause
	if has_bleeding:
		cause = CAUSE_BLEEDING if cause.is_empty() else "%s_%s" % [CAUSE_BLEEDING, cause]
	if has_infection:
		cause = CAUSE_INFECTION if cause.is_empty() else "%s_%s" % [cause, CAUSE_INFECTION]
	return cause


func _infection_time_to_boundary(vitals: PlayerVitals) -> float:
	var stage: InfectionState.Stage = vitals.infection.stage
	if stage < InfectionState.Stage.LATENT or stage > InfectionState.Stage.TERMINAL:
		return -1.0
	var duration: float = _settings.infection_stage_duration_world_sec(stage, vitals.infection.exposure)
	return maxf(duration - vitals.infection.stage_elapsed_world_sec, 0.0)


func _advance_infection_stage(player_id: String, vitals: PlayerVitals, world_time: float) -> void:
	var previous: InfectionState.Stage = vitals.infection.stage
	if previous < InfectionState.Stage.LATENT or previous >= InfectionState.Stage.ZOMBIFIED:
		return
	vitals.infection.stage = (int(previous) + 1) as InfectionState.Stage
	vitals.infection.stage_entered_at_world_time = world_time
	vitals.infection.stage_elapsed_world_sec = 0.0
	var event: Dictionary = {
		"event_type": EVENT_PLAYER_INFECTION_STAGE_CHANGED,
		"player_id": player_id,
		"from": InfectionState.stage_name(previous),
		"to": InfectionState.stage_name(vitals.infection.stage),
		"world_time": world_time,
	}
	_push_event(event)
	GameLogger.info("survival", "player infection stage changed", event)


## Adds one tick's time-based damage to the player's unreported total and
## reports it once the configured interval (action time) has passed.
## `start_time`/`end_time` are calendar instants of the current tick. Health was already
## reduced by the caller; batching only limits events and log lines.
func _accumulate_survival_damage(player_id: String, vitals: PlayerVitals, start_time: float, end_time: float, bleeding: float, starvation: float, dehydration: float, infection: float) -> void:
	var pending: Dictionary = _pending_damage.get(player_id, {})
	if pending.is_empty():
		pending = {"since": _action_time_at(start_time), "bleeding": 0.0, "starvation": 0.0, "dehydration": 0.0, "infection": 0.0}
		_pending_damage[player_id] = pending
	pending["bleeding"] = float(pending["bleeding"]) + bleeding
	pending["starvation"] = float(pending["starvation"]) + starvation
	pending["dehydration"] = float(pending["dehydration"]) + dehydration
	pending["infection"] = float(pending["infection"]) + infection
	if _action_time_at(end_time) - float(pending["since"]) + DAMAGE_REPORT_EPSILON_SEC >= _settings.survival_damage_event_interval_sec:
		_flush_survival_damage(player_id, vitals, end_time)


## Reports and clears the player's unreported time-based damage, if any.
func _flush_survival_damage(player_id: String, vitals: PlayerVitals, world_time: float) -> void:
	var pending: Dictionary = _pending_damage.get(player_id, {})
	if pending.is_empty():
		return
	_pending_damage.erase(player_id)
	var bleeding: float = float(pending["bleeding"])
	var starvation: float = float(pending["starvation"])
	var dehydration: float = float(pending["dehydration"])
	var infection: float = float(pending["infection"])
	var total: float = bleeding + starvation + dehydration + infection
	if total <= 0.0:
		return
	var event: Dictionary = {
		"event_type": EVENT_PLAYER_SURVIVAL_DAMAGE,
		"player_id": player_id,
		"cause": _survival_damage_cause(vitals, 0.0, bleeding, starvation, dehydration, infection),
		"damage": total,
		"health_after": vitals.health,
		"world_time": world_time,
	}
	_push_event(event)
	GameLogger.info("survival", "player survival damage", event)


## `world_time` (calendar) stamps the death and its events; `action_time`
## starts the respawn delay.
func _mark_dead(player_id: String, vitals: PlayerVitals, world_time: float, action_time: float, cause: String) -> void:
	vitals.health = 0.0
	vitals.died_at_world_time = world_time
	vitals.died_at_action_time = action_time
	# Report damage taken up to the death before the death itself.
	_flush_survival_damage(player_id, vitals, world_time)
	var event: Dictionary = {
		"event_type": EVENT_PLAYER_DIED,
		"player_id": player_id,
		"cause": cause,
		"world_time": world_time,
	}
	_push_event(event)
	GameLogger.info("survival", "player died", event)


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
	vitals.died_at_action_time = PlayerVitals.NOT_DEAD_TIME
	_pending_damage.erase(player_id)
	var state: PlayerState = world.get_player(player_id)
	var event: Dictionary = {
		"event_type": EVENT_PLAYER_RESPAWNED,
		"player_id": player_id,
		"position": [state.position.x, state.position.y, state.position.z],
		"world_time": world_time,
	}
	_push_event(event)
	GameLogger.info("survival", "player respawned", event)
	return true

## Action time at a calendar instant of the tick set up by step().
func _action_time_at(world_time: float) -> float:
	return _step_action_start + (world_time - _step_world_start) * _step_action_per_world_sec


## Calendar instant of the current tick at which the action clock reaches
## `action_time`: the tick start if that already passed, INF if action time
## does not advance in this tick.
func _world_time_at(action_time: float) -> float:
	var wait: float = action_time - _step_action_start
	if wait <= 0.0:
		return _step_world_start
	if _step_action_per_world_sec <= 0.0:
		return INF
	return _step_world_start + wait / _step_action_per_world_sec


## Raises each need by rate * world_delta (clamped to need_max) and logs
## category changes so balance problems are visible in server logs.
func _advance_needs(player_id: String, vitals: PlayerVitals, world_delta: float) -> void:
	for kind_index: int in NeedKind.KIND_NAMES.size():
		var kind: NeedKind.Kind = kind_index as NeedKind.Kind
		var before: NeedKind.Category = need_category(player_id, kind)
		var raised: float = minf(_need_value(vitals, kind) + _settings.need_rate_per_world_sec(kind) * world_delta, _settings.need_max)
		vitals.set(NeedKind.kind_name(kind), raised)
		_report_need_category_change(player_id, vitals, kind, before)


## Queues and logs "need_category_changed" when the category of `kind`
## differs from `before`.
func _report_need_category_change(player_id: String, vitals: PlayerVitals, kind: NeedKind.Kind, before: NeedKind.Category) -> void:
	var after: NeedKind.Category = need_category(player_id, kind)
	if after == before:
		return
	var event: Dictionary = {
		"event_type": EVENT_NEED_CATEGORY_CHANGED,
		"player_id": player_id, "need": NeedKind.kind_name(kind),
		"category": NeedKind.category_name(after), "value": _need_value(vitals, kind),
		"world_time": _clock.world_time_sec,
	}
	_push_event(event)
	GameLogger.info("survival", "need category changed", event)


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


func _push_event(event: Dictionary) -> void:
	_events.append(event.duplicate(true))
	while _events.size() > _settings.max_pending_events:
		_events.pop_front()
		dropped_event_count += 1
