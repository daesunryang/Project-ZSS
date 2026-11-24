class_name NpcHealth
extends NpcStage
## The NPCs' bodies (F-25, docs/09 §17.12): damage, bleeding, infection,
## treatment, death, the body and its rising as a zombie. Stage id "health".
## The state is the NpcVitals component; the numbers of wounds, bleeding and
## infection are the players' (SurvivalSettings), the rest NpcHealthSettings.
## No networking here: NpcNetModule sends only NpcVitals.condition_of().
##
## Public API (every ActionResult failure carries a reason code below):
##   apply_damage(npc_id, damage)
##       a server-made hit. Success event: {event_type: "npc_wounded",
##       npc_id, source_id, damage, health_after, died, world_time, wound}.
##   apply_infection_exposure(npc_id, exposure, source_id)
##       the players' roll (SurvivalSettings.infection_chance) from the
##       NPC's own generator. Event "npc_infected" or
##       "infection_exposure_resisted".
##   check_treatment(npc_id, definition) -> "" or why the item does nothing
##   apply_treatment(npc_id, definition, source_id)
##       stops the worst bleeding wounds and / or cures the infection, like
##       the players' items. Event {event_type: "npc_treated", npc_id,
##       source_id, bleeding_stopped_wound_ids, infection_cured_from}.
##   is_living_target(npc_id), living_target_ids(), has_npc(npc_id),
##   vitals_of(npc_id), position_of(npc_id)
##
## Who calls it: zombies through NpcZombieTargets, a player's melee swing
## through NpcMeleeTargets, a player's bandage or cure through
## ItemConsumption.try_use_on, and the NPC itself (self treatment below).
## Only NPCs that are awake can be hit or treated: one in a cell that is
## not simulated is frozen as it is (docs/13 §16.3 D4).
##
## Time (calendar seconds, like the players' survival): every tick, each
## awake NPC that is hurt loses health to its bleeding wounds and its
## infection stage, or - with neither - recovers health and heals wounds.
## The tick is cut at infection stage boundaries and at the moment of
## death, so the result does not depend on the tick length. An NPC that is
## whole is not looked at: per tick this stage costs the hurt NPCs and the
## bodies only. Hunger and thirst do not hurt an NPC yet (docs/15 F25-005).
##
## Self treatment: an awake NPC that bleeds, or is infected at a stage a
## cure still helps, uses the first fitting item it carries (slot order),
## at most once per NpcHealthSettings.self_treat_cooldown_world_sec. It is
## a rule of this stage, not a scored action: the NPC does not stop what it
## is doing (docs/15 F25-004).
##
## Death (health 0, or the infection reached its end):
##   1. the vitals record when, of what and by whom;
##   2. everything it carries is put on the ground where it stands
##      (InventoryService.drop_all_items, like a dead player: ADR-012);
##   3. whether the body rises is decided (settings; docs/15 F25-001);
##   4. the NPC stops being simulated for good
##      (NpcService.refresh_simulation): it decides and moves no more;
##   5. awake NPCs within witness_range_m and a free line remember it
##      ("npc_died", one shared event id) and feel fear and grief;
##   6. `npc_died` is emitted.
## The entity stays in the world as the body. In a simulated cell, a body
## that rises is replaced by one zombie at its place
## (ZombieService.spawn_zombie) once rise_at_world_time has come; a refused
## spawn is tried again later. A body that does not rise is taken out after
## body_remove_delay_world_sec. Either way NpcService.remove_npc retires
## the id; the roster record of the world keeps it, so that NPC is never
## placed again.

signal npc_damaged(npc_id: String, source_id: String)
signal npc_died(npc_id: String, cause: String, killer_id: String)
## The body became the zombie `zombie_id` (server-side only: clients are
## never told which NPC a zombie was).
signal npc_rose(npc_id: String, zombie_id: String)
signal npc_body_removed(npc_id: String)

const STAGE_ID: String = "health"

const EVENT_WOUNDED: String = "npc_wounded"
const EVENT_INFECTED: String = "npc_infected"
const EVENT_INFECTION_RESISTED: String = SurvivalService.EVENT_INFECTION_RESISTED
const EVENT_TREATED: String = "npc_treated"
const MEMORY_EVENT_DIED: String = "npc_died"

const REASON_UNAVAILABLE: String = "npc_health_unavailable"
const REASON_UNKNOWN_NPC: String = NpcService.REASON_UNKNOWN_NPC
const REASON_NPC_DEAD: String = "npc_dead"
## An NPC whose cell is not simulated cannot be touched.
const REASON_NPC_FROZEN: String = "npc_frozen"
const REASON_ALREADY_INFECTED: String = SurvivalService.REASON_ALREADY_INFECTED
const REASON_BAD_EXPOSURE: String = SurvivalService.REASON_BAD_EXPOSURE
const REASON_NOT_BLEEDING: String = SurvivalService.REASON_NOT_BLEEDING
const REASON_NOT_INFECTED: String = SurvivalService.REASON_NOT_INFECTED
const REASON_TOO_LATE: String = SurvivalService.REASON_TOO_LATE
const REASON_NOT_A_TREATMENT: String = "not_a_treatment"

const NOT_CURED: String = ""
const TAG_DEATH: String = "death"
const TAG_KILLED_BY_PLAYER: String = "killed_by_player"
const TAG_KILLED_BY_ZOMBIE: String = "killed_by_zombie"
const TAG_TURNED: String = "turned"
const ZOMBIE_ID_PREFIX: String = "zombie_"

## Diagnostics (tests / profiling).
var death_count: int = 0
var rise_count: int = 0
var refused_rise_count: int = 0
var body_removed_count: int = 0
var self_treat_count: int = 0
var last_hurt_count: int = 0

var _survival: SurvivalSettings
var _settings: NpcHealthSettings
var _npcs_ref: WeakRef = null
var _world_ref: WeakRef = null
## Awake NPCs whose body changes with time (hurt and alive).
var _hurt: Dictionary[String, bool] = {}
## Dead NPCs in memory (the bodies).
var _bodies: Dictionary[String, bool] = {}


func _init(survival: SurvivalSettings, settings: NpcHealthSettings) -> void:
	_survival = survival
	_settings = settings


## Registers the vitals component and this stage with `npcs`. null when
## either is refused (NPCs exist already, or a duplicate).
static func install(npcs: NpcService, survival: SurvivalSettings, settings: NpcHealthSettings) -> NpcHealth:
	if npcs == null or survival == null or settings == null:
		return null
	var health: NpcHealth = NpcHealth.new(survival, settings)
	if npcs.register_component(NpcVitals.COMPONENT_ID, NpcVitals.create.bind(survival, settings)) != OK or npcs.add_stage(health) != OK:
		return null
	health._npcs_ref = weakref(npcs)
	return health


## The health stage of `world` (null: it has no NPCs, or no NPC health).
static func of_world(world: ServerWorld) -> NpcHealth:
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService if world != null else null
	return npcs.get_stage(STAGE_ID) as NpcHealth if npcs != null else null


func stage_id() -> String:
	return STAGE_ID


# ------------------------------------------------------------ queries

## True for an NPC that is in memory (alive or a body).
func has_npc(npc_id: String) -> bool:
	var npcs: NpcService = _npcs()
	return npcs != null and npcs.has_npc(npc_id)


## The vitals of an NPC in memory (read-only), or null.
func vitals_of(npc_id: String) -> NpcVitals:
	var npcs: NpcService = _npcs()
	return NpcVitals.of(npcs.get_npc(npc_id)) if npcs != null else null


func position_of(npc_id: String) -> Vector3:
	var npcs: NpcService = _npcs()
	var npc: NpcState = npcs.get_npc(npc_id) if npcs != null else null
	return npc.position if npc != null else Vector3.ZERO


## True for an NPC that can be sensed, hit and treated now: alive and awake.
func is_living_target(npc_id: String) -> bool:
	var npcs: NpcService = _npcs()
	return npcs != null and npcs.is_awake(npc_id)


## Ids of those NPCs, sorted.
func living_target_ids() -> PackedStringArray:
	var npcs: NpcService = _npcs()
	return npcs.awake_npc_ids() if npcs != null else PackedStringArray()


## Ids of the bodies in memory, sorted.
func body_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_bodies.keys())
	ids.sort()
	return ids


# ------------------------------------------------------------ damage

## One server-made hit on an awake, living NPC (see the header).
func apply_damage(npc_id: String, damage: DamageInput) -> ActionResult:
	var reason: String = damage.validate() if damage != null else DamageInput.REASON_BAD_AMOUNT
	if reason.is_empty():
		reason = _check_touchable(npc_id)
	if not reason.is_empty():
		GameLogger.warning("npc", "damage rejected", {"entity_id": npc_id, "reason": reason, "operation": "apply_damage"})
		return ActionResult.failure(reason)
	var world: ServerWorld = _world()
	var npcs: NpcService = _npcs()
	var npc: NpcState = npcs.get_npc(npc_id)
	var vitals: NpcVitals = NpcVitals.of(npc)
	var now: float = world.clock.world_time_sec
	var wound: Wound = Wound.new()
	wound.wound_id = world.ids.next_id("wound")
	wound.body_part = damage.body_part
	wound.wound_type = damage.wound_type
	wound.severity = clampf(damage.amount / _survival.wound_severity_reference_damage, 0.0, Wound.MAX_SEVERITY)
	wound.is_bleeding = _survival.wound_starts_bleeding(damage.wound_type, wound.severity)
	wound.source_id = damage.source_id
	wound.created_at_world_time = now
	if vitals.injuries.size() < _survival.max_wounds_per_player:
		vitals.injuries.append(wound)
	vitals.health = maxf(vitals.health - damage.amount, 0.0)
	var died: bool = vitals.health <= 0.0
	_hurt[npc_id] = true
	npcs.mark_npc_dirty(npc_id)
	var event: Dictionary = {
		"event_type": EVENT_WOUNDED,
		"npc_id": npc_id,
		"source_id": damage.source_id,
		"damage": damage.amount,
		"health_after": vitals.health,
		"died": died,
		"world_time": now,
		"wound": wound.to_dict(),
	}
	if died:
		_die(world, npcs, npc, vitals, now, SurvivalService.CAUSE_COMBAT, damage.source_id)
	npc_damaged.emit(npc_id, damage.source_id)
	return ActionResult.success(event)


## A zombie's bite or scratch (or blood) reached an awake, living NPC: the
## players' chance, rolled from the NPC's own generator.
func apply_infection_exposure(npc_id: String, exposure: InfectionState.Exposure, source_id: String) -> ActionResult:
	if not InfectionState.is_valid_exposure(exposure):
		return ActionResult.failure(REASON_BAD_EXPOSURE)
	var reason: String = _check_touchable(npc_id)
	if not reason.is_empty():
		return ActionResult.failure(reason)
	var world: ServerWorld = _world()
	var npcs: NpcService = _npcs()
	var npc: NpcState = npcs.get_npc(npc_id)
	var vitals: NpcVitals = NpcVitals.of(npc)
	if vitals.infection.is_infected():
		return ActionResult.failure(REASON_ALREADY_INFECTED)
	var now: float = world.clock.world_time_sec
	var chance: float = _survival.infection_chance(exposure)
	var infected: bool = npc.rng.randf() < chance
	if infected:
		vitals.infection.stage = InfectionState.Stage.LATENT
		vitals.infection.exposure = exposure
		vitals.infection.source_id = source_id
		vitals.infection.infected_at_world_time = now
		vitals.infection.stage_entered_at_world_time = now
		vitals.infection.stage_elapsed_world_sec = 0.0
		_hurt[npc_id] = true
		GameLogger.info("npc", "npc infected", {"entity_id": npc_id, "source_id": source_id, "exposure": InfectionState.EXPOSURE_NAMES[exposure]})
	# The generator moved either way: it is saved with the NPC.
	npcs.mark_npc_dirty(npc_id)
	return ActionResult.success({
		"event_type": EVENT_INFECTED if infected else EVENT_INFECTION_RESISTED,
		"npc_id": npc_id,
		"exposure": InfectionState.EXPOSURE_NAMES[exposure],
		"source_id": source_id,
		"chance": chance,
		"world_time": now,
	})


# ------------------------------------------------------------ treatment

## "" when `definition` would do something for this NPC now, otherwise why
## not: unknown_npc, npc_dead, npc_frozen, not_a_treatment, not_bleeding,
## not_infected, too_late (the first treatment that cannot be given).
func check_treatment(npc_id: String, definition: ItemDefinition) -> String:
	var reason: String = _check_touchable(npc_id)
	if not reason.is_empty():
		return reason
	if definition == null or not definition.is_treatment():
		return REASON_NOT_A_TREATMENT
	var vitals: NpcVitals = vitals_of(npc_id)
	var refusal: String = ""
	if definition.stops_bleeding():
		if vitals.is_bleeding():
			return ""
		refusal = REASON_NOT_BLEEDING
	if definition.cures_infection:
		var infection_reason: String = _infection_treatment_refusal(vitals)
		if infection_reason.is_empty():
			return ""
		if refusal.is_empty():
			refusal = infection_reason
	return refusal


## Gives the treatment (see the header). The caller has taken the item.
func apply_treatment(npc_id: String, definition: ItemDefinition, source_id: String) -> ActionResult:
	var reason: String = check_treatment(npc_id, definition)
	if not reason.is_empty():
		return ActionResult.failure(reason)
	var world: ServerWorld = _world()
	var npcs: NpcService = _npcs()
	var vitals: NpcVitals = vitals_of(npc_id)
	var stopped: Array = []
	if definition.stops_bleeding():
		for wound: Wound in _worst_bleeding(vitals, definition.treat_bleeding_wound_count):
			wound.is_bleeding = false
			stopped.append(wound.wound_id)
	var cured_from: String = NOT_CURED
	if definition.cures_infection and _infection_treatment_refusal(vitals).is_empty():
		cured_from = InfectionState.stage_name(vitals.infection.stage)
		vitals.infection = InfectionState.new()
	npcs.mark_npc_dirty(npc_id)
	GameLogger.info("npc", "npc treated", {"entity_id": npc_id, "source_id": source_id, "wounds": stopped.size(), "cured_from": cured_from})
	return ActionResult.success({
		"event_type": EVENT_TREATED,
		"npc_id": npc_id,
		"source_id": source_id,
		"bleeding_stopped_wound_ids": stopped,
		"infection_cured_from": cured_from,
		"world_time": world.clock.world_time_sec,
	})


# ------------------------------------------------------------ NpcStage

func on_npc_entered(world: ServerWorld, npc: NpcState) -> void:
	_world_ref = weakref(world)
	var vitals: NpcVitals = NpcVitals.of(npc)
	if vitals != null and not vitals.is_alive():
		_bodies[npc.npc_id] = true


func on_npc_left(_world_now: ServerWorld, npc: NpcState, _retired: bool) -> void:
	_hurt.erase(npc.npc_id)
	_bodies.erase(npc.npc_id)


func on_npc_woke(_world_now: ServerWorld, npc: NpcState) -> void:
	var vitals: NpcVitals = NpcVitals.of(npc)
	if vitals != null and not vitals.is_untouched():
		_hurt[npc.npc_id] = true


func on_npc_slept(_world_now: ServerWorld, npc: NpcState) -> void:
	_hurt.erase(npc.npc_id)


func step(world: ServerWorld, npcs: NpcService, _action_delta: float, world_delta: float) -> void:
	_world_ref = weakref(world)
	last_hurt_count = _hurt.size()
	if _hurt.is_empty() and _bodies.is_empty():
		return
	var now: float = world.clock.world_time_sec
	if world_delta > 0.0 and not _hurt.is_empty():
		var hurt_ids: PackedStringArray = PackedStringArray(_hurt.keys())
		hurt_ids.sort()
		for npc_id: String in hurt_ids:
			var npc: NpcState = npcs.get_npc(npc_id)
			var vitals: NpcVitals = NpcVitals.of(npc)
			if vitals == null or not vitals.is_alive() or not npcs.is_awake(npc_id):
				_hurt.erase(npc_id)
				continue
			_advance(world, npcs, npc, vitals, now - world_delta, world_delta)
			if vitals.is_alive():
				_treat_itself(world, npcs, npc, vitals, now)
			if vitals.is_untouched():
				_hurt.erase(npc_id)
			npcs.mark_npc_dirty(npc_id)
	if not _bodies.is_empty():
		_step_bodies(world, npcs, now)


# ------------------------------------------------------------ time

## Advances one living NPC by `elapsed` calendar seconds that began at
## `start_time`, cut at infection stage boundaries and at its death.
func _advance(world: ServerWorld, npcs: NpcService, npc: NpcState, vitals: NpcVitals, start_time: float, elapsed: float) -> void:
	var time: float = start_time
	var remaining: float = elapsed
	while remaining > 0.0 and vitals.is_alive():
		var segment: float = remaining
		var crosses_stage: bool = false
		var infection: InfectionState = vitals.infection
		if infection.is_infected() and infection.stage != InfectionState.Stage.ZOMBIFIED:
			var to_boundary: float = maxf(_survival.infection_stage_duration_world_sec(infection.stage, infection.exposure) - infection.stage_elapsed_world_sec, 0.0)
			if to_boundary <= segment:
				segment = to_boundary
				crosses_stage = true
		var bleeding_rate: float = _bleeding_rate(vitals)
		var infection_rate: float = _survival.infection_health_loss_per_world_sec(infection.stage) if infection.is_infected() else 0.0
		var loss_rate: float = bleeding_rate + infection_rate
		if loss_rate > 0.0:
			var time_to_death: float = vitals.health / loss_rate
			if time_to_death <= segment:
				vitals.health = 0.0
				_die(world, npcs, npc, vitals, time + time_to_death, _loss_cause(bleeding_rate, infection_rate), "")
				return
			vitals.health -= loss_rate * segment
		elif segment > 0.0:
			vitals.health = minf(vitals.health + _survival.health_recovery_per_world_sec * segment, vitals.max_health())
			_heal_wounds(vitals, segment)
		time += segment
		remaining -= segment
		if infection.is_infected():
			infection.stage_elapsed_world_sec += segment
		if crosses_stage:
			infection.stage = (infection.stage + 1) as InfectionState.Stage
			infection.stage_entered_at_world_time = time
			infection.stage_elapsed_world_sec = 0.0
			if infection.stage == InfectionState.Stage.ZOMBIFIED:
				vitals.health = 0.0
				_die(world, npcs, npc, vitals, time, SurvivalService.CAUSE_INFECTION, "")
				return


func _bleeding_rate(vitals: NpcVitals) -> float:
	var rate: float = 0.0
	for wound: Wound in vitals.injuries:
		if wound.is_bleeding:
			rate += _survival.bleeding_health_loss_per_severity_per_world_sec * _survival.bleeding_type_multiplier(wound.wound_type) * wound.severity
	return rate


func _heal_wounds(vitals: NpcVitals, elapsed: float) -> void:
	var reduction: float = _survival.wound_recovery_per_world_sec * elapsed
	for index: int in range(vitals.injuries.size() - 1, -1, -1):
		var wound: Wound = vitals.injuries[index]
		wound.severity = maxf(wound.severity - reduction, 0.0)
		if wound.severity <= 0.0:
			vitals.injuries.remove_at(index)


static func _loss_cause(bleeding_rate: float, infection_rate: float) -> String:
	if bleeding_rate > 0.0 and infection_rate > 0.0:
		return SurvivalService.CAUSE_BLEEDING + SurvivalService.CAUSE_SEPARATOR + SurvivalService.CAUSE_INFECTION
	return SurvivalService.CAUSE_BLEEDING if bleeding_rate > 0.0 else SurvivalService.CAUSE_INFECTION


# ------------------------------------------------------------ self treatment

## The NPC uses a treatment it carries when one would help (see the
## header). One look per cooldown, whether or not it found something.
func _treat_itself(world: ServerWorld, npcs: NpcService, npc: NpcState, vitals: NpcVitals, now: float) -> void:
	if not _settings.self_treat_enabled or now < vitals.self_treat_ready_at_world_time:
		return
	var needs_cure: bool = vitals.infection.is_infected() and _infection_treatment_refusal(vitals).is_empty()
	if not vitals.is_bleeding() and not needs_cure:
		return
	vitals.self_treat_ready_at_world_time = now + _settings.self_treat_cooldown_world_sec
	var carried: NpcBehaviourState = npc.component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState
	if carried == null or carried.inventory_id.is_empty():
		return
	for item: ItemInstance in carried.carried_items():
		var definition: ItemDefinition = world.inventory.definition_of(item.item_instance_id)
		if not check_treatment(npc.npc_id, definition).is_empty():
			continue
		var item_id: String = item.item_instance_id
		var removal: ActionResult = world.inventory.remove_item(carried.inventory_id, item_id, 1)
		if not removal.ok:
			GameLogger.warning("npc", "an NPC could not use its treatment", {"entity_id": npc.npc_id, "item_id": item_id, "reason": removal.reason, "operation": "self_treat"})
			continue
		if apply_treatment(npc.npc_id, definition, item_id).ok:
			self_treat_count += 1
		return


# ------------------------------------------------------------ death

func _die(world: ServerWorld, npcs: NpcService, npc: NpcState, vitals: NpcVitals, world_time: float, cause: String, killer_id: String) -> void:
	vitals.health = 0.0
	vitals.died_at_world_time = maxf(world_time, 0.0)
	vitals.death_cause = cause
	vitals.killer_id = killer_id
	_hurt.erase(npc.npc_id)
	_bodies[npc.npc_id] = true
	death_count += 1
	_leave_belongings(world, npc)
	var may_rise: bool = (_settings.infected_rise and (vitals.infection.is_infected() or SurvivalService.is_infection_death(cause))) or (_settings.bitten_rise and vitals.has_bite())
	# The roll is made only for a body that may rise: other deaths leave the
	# NPC's generator as it was.
	if may_rise and (_settings.rise_chance >= 1.0 or npc.rng.randf() < _settings.rise_chance):
		vitals.rise_at_world_time = vitals.died_at_world_time + _settings.rise_delay_world_sec
	else:
		vitals.rise_at_world_time = NpcVitals.NO_RISE_TIME
	npcs.mark_npc_dirty(npc.npc_id)
	npcs.refresh_simulation(world, npc.npc_id)
	_tell_witnesses(world, npcs, npc, vitals)
	GameLogger.info("npc", "npc died", {"entity_id": npc.npc_id, "cause": cause, "killer_id": killer_id, "rises": vitals.rise_at_world_time >= 0.0})
	npc_died.emit(npc.npc_id, cause, killer_id)


## Everything the NPC carries is put on the ground where it died (ADR-012:
## it does not disappear, anyone can pick it up).
func _leave_belongings(world: ServerWorld, npc: NpcState) -> void:
	var carried: NpcBehaviourState = npc.component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState
	if carried == null or carried.inventory_id.is_empty():
		return
	var position: Vector3 = world.clamp_to_world(npc.position)
	var dropped: ActionResult = world.inventory.drop_all_items(carried.inventory_id, world.cell_id_at(position), position)
	if not dropped.ok:
		GameLogger.error("npc", "a dead NPC's belongings could not be dropped", {"entity_id": npc.npc_id, "reason": dropped.reason, "operation": "leave_belongings"})


## Awake NPCs that could see the death remember it and feel it. No social
## rule here: only the memory and the two emotions (docs/15 F25-007).
func _tell_witnesses(world: ServerWorld, npcs: NpcService, dead: NpcState, vitals: NpcVitals) -> void:
	if _settings.witness_range_m <= 0.0:
		return
	var participants: Array[Dictionary] = [{"entity_id": dead.npc_id, "role": "target"}]
	var tags: PackedStringArray = [TAG_DEATH]
	if NpcMemory.is_valid_participant_id(vitals.killer_id) and vitals.killer_id != dead.npc_id:
		participants.append({"entity_id": vitals.killer_id, "role": "actor"})
		if not NpcState.is_valid_npc_id(vitals.killer_id):
			tags.append(TAG_KILLED_BY_PLAYER)
	elif vitals.killer_id.begins_with(ZOMBIE_ID_PREFIX):
		tags.append(TAG_KILLED_BY_ZOMBIE)
	if vitals.rise_at_world_time >= 0.0 and SurvivalService.is_infection_death(vitals.death_cause):
		tags.append(TAG_TURNED)
	var now: float = world.clock.world_time_sec
	var event_time: float = minf(vitals.died_at_world_time, now)
	var event_id: String = ""
	for witness_id: String in npcs.awake_npc_ids():
		if witness_id == dead.npc_id:
			continue
		var witness: NpcState = npcs.get_npc(witness_id)
		if ZombiePerception.flat_distance(witness.position, dead.position) > _settings.witness_range_m or world.is_line_blocked(witness.position, dead.position):
			continue
		var memories: NpcMemoryStore = witness.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
		if memories != null:
			var recorded: ActionResult = memories.record_memory(event_id, MEMORY_EVENT_DIED, participants, dead.position, event_time, NpcMemory.OBSERVATION_WITNESSED, _settings.death_memory_importance, _settings.death_memory_intensity, tags)
			if recorded.ok:
				event_id = str(recorded.event.get("event_id", event_id))
			else:
				GameLogger.warning("npc", "a death was not remembered", {"entity_id": witness_id, "reason": recorded.reason, "operation": "tell_witnesses"})
		var emotions: NpcEmotions = witness.component(NpcEmotions.COMPONENT_ID) as NpcEmotions
		if emotions != null:
			emotions.apply_emotion("fear", _settings.witness_fear, now)
			emotions.apply_emotion("grief", _settings.witness_grief, now)


# ------------------------------------------------------------ bodies

## Bodies in simulated cells: the ones whose time has come rise or are
## taken out. A body in a cell that is not simulated waits (frozen).
func _step_bodies(world: ServerWorld, npcs: NpcService, now: float) -> void:
	for npc_id: String in body_ids():
		var npc: NpcState = npcs.get_npc(npc_id)
		var vitals: NpcVitals = NpcVitals.of(npc)
		if vitals == null or vitals.is_alive():
			_bodies.erase(npc_id)
			continue
		if not world.is_cell_simulated(world.cell_index.cell_of(npc_id)):
			continue
		if vitals.rise_at_world_time >= 0.0:
			if now >= vitals.rise_at_world_time:
				_rise(world, npcs, npc, vitals, now)
		elif now >= vitals.died_at_world_time + _settings.body_remove_delay_world_sec:
			_remove_body(world, npcs, npc_id)


## One zombie where the body lies; the body is gone. A refused spawn (the
## zombie limit) keeps the body and is tried again later.
func _rise(world: ServerWorld, npcs: NpcService, npc: NpcState, vitals: NpcVitals, now: float) -> void:
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	if zombies == null:
		# A world without zombies: the body simply stays its time.
		vitals.rise_at_world_time = NpcVitals.NO_RISE_TIME
		npcs.mark_npc_dirty(npc.npc_id)
		return
	var spawned: ActionResult = zombies.spawn_zombie(world, npc.position, npc.yaw)
	if not spawned.ok:
		refused_rise_count += 1
		vitals.rise_at_world_time = now + _settings.rise_retry_world_sec
		npcs.mark_npc_dirty(npc.npc_id)
		GameLogger.warning("npc", "a dead NPC could not rise; it is tried again", {"entity_id": npc.npc_id, "reason": spawned.reason, "operation": "rise"})
		return
	rise_count += 1
	var npc_id: String = npc.npc_id
	var zombie_id: String = str(spawned.event.get("zombie_id", ""))
	# Server log only: clients are never told which NPC a zombie was.
	GameLogger.info("npc", "a dead NPC rose as a zombie", {"entity_id": npc_id, "zombie_id": zombie_id})
	_take_out(world, npcs, npc_id)
	npc_rose.emit(npc_id, zombie_id)


func _remove_body(world: ServerWorld, npcs: NpcService, npc_id: String) -> void:
	body_removed_count += 1
	_take_out(world, npcs, npc_id)
	npc_body_removed.emit(npc_id)


func _take_out(world: ServerWorld, npcs: NpcService, npc_id: String) -> void:
	var removed: ActionResult = npcs.remove_npc(world, npc_id)
	if not removed.ok:
		GameLogger.error("npc", "a body could not be taken out of the world", {"entity_id": npc_id, "reason": removed.reason, "operation": "remove_body"})
	_bodies.erase(npc_id)


# ------------------------------------------------------------ internals

func _npcs() -> NpcService:
	return _npcs_ref.get_ref() as NpcService if _npcs_ref != null else null


func _world() -> ServerWorld:
	return _world_ref.get_ref() as ServerWorld if _world_ref != null else null


## "" when the NPC is in memory, alive and awake.
func _check_touchable(npc_id: String) -> String:
	var npcs: NpcService = _npcs()
	if npcs == null or _world() == null:
		return REASON_UNAVAILABLE
	var vitals: NpcVitals = NpcVitals.of(npcs.get_npc(npc_id))
	if vitals == null:
		return REASON_UNKNOWN_NPC
	if not vitals.is_alive():
		return REASON_NPC_DEAD
	if not npcs.is_awake(npc_id):
		return REASON_NPC_FROZEN
	return ""


## "" when a cure helps now (the players' rule: not past
## SurvivalSettings.infection_treatment_max_stage).
func _infection_treatment_refusal(vitals: NpcVitals) -> String:
	if not vitals.infection.is_infected():
		return REASON_NOT_INFECTED
	if vitals.infection.stage > _survival.infection_treatment_max_stage:
		return REASON_TOO_LATE
	return ""


## Up to `count` bleeding wounds, worst first (type multiplier x severity,
## ties by list order): the players' order.
func _worst_bleeding(vitals: NpcVitals, count: int) -> Array[Wound]:
	var bleeding: Array[Wound] = []
	for wound: Wound in vitals.injuries:
		if wound.is_bleeding:
			bleeding.append(wound)
	var order: Dictionary[String, int] = {}
	for index: int in bleeding.size():
		order[bleeding[index].wound_id] = index
	bleeding.sort_custom(func(a: Wound, b: Wound) -> bool:
		var weight_a: float = _survival.bleeding_type_multiplier(a.wound_type) * a.severity
		var weight_b: float = _survival.bleeding_type_multiplier(b.wound_type) * b.severity
		return weight_a > weight_b if weight_a != weight_b else order[a.wound_id] < order[b.wound_id])
	return bleeding.slice(0, maxi(count, 0))
