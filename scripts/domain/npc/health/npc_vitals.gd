class_name NpcVitals
extends NpcComponent
## One NPC's body (F-25, docs/09 §17.12): its health, its wounds, its
## infection, and - once it is dead - when and of what it died and whether
## and when its body rises as a zombie. Plain saved data; only NpcHealth
## (the stage) changes it. It uses the players' wound and infection types
## (Wound, InfectionState) and the players' numbers (SurvivalSettings).
##
## A dead NPC is never simulated again (blocks_simulation): the scheduler,
## the executor and every other stage see it as an NPC whose cell is not
## simulated. Its entity stays in the world as the body until NpcHealth
## takes it out.
##
## Document:
##   {health, injuries: [Wound.to_dict()], infection: InfectionState.to_dict(),
##    died_at_world_time (-1 = alive), death_cause, killer_id,
##    rise_at_world_time (-1 = the body does not rise),
##    self_treat_ready_at_world_time,
##    exact: {health, died_at, rise_at, self_treat_ready_at,
##            infection_elapsed, severities: [...]}}
## `exact` holds the bits of the numbers a later result is computed from
## (FloatBits, docs/15 P4-281), so a restored NPC goes on exactly as one
## that was never saved.
##
## An NPC saved before this component existed gets on_created(): full
## health, no wounds, not infected. That is the migration of old documents.

const COMPONENT_ID: String = "vitals"
const SCHEMA_VERSION: int = 1
const NOT_DEAD_TIME: float = -1.0
const NO_RISE_TIME: float = -1.0
const MAX_ID_LENGTH: int = 64

## What other players may know about an NPC's body (NpcNetProtocol).
const CONDITION_OK: String = "ok"
const CONDITION_HURT: String = "hurt"
const CONDITION_DEAD: String = "dead"

const KEY_HEALTH: String = "health"
const KEY_INJURIES: String = "injuries"
const KEY_INFECTION: String = "infection"
const KEY_DIED_AT: String = "died_at_world_time"
const KEY_DEATH_CAUSE: String = "death_cause"
const KEY_KILLER_ID: String = "killer_id"
const KEY_RISE_AT: String = "rise_at_world_time"
const KEY_SELF_TREAT_READY_AT: String = "self_treat_ready_at_world_time"
const KEY_EXACT: String = "exact"
const EXACT_HEALTH: String = "health"
const EXACT_DIED_AT: String = "died_at"
const EXACT_RISE_AT: String = "rise_at"
const EXACT_SELF_TREAT_READY_AT: String = "self_treat_ready_at"
const EXACT_INFECTION_ELAPSED: String = "infection_elapsed"
const EXACT_SEVERITIES: String = "severities"

var health: float = 0.0
var injuries: Array[Wound] = []
var infection: InfectionState = InfectionState.new()
var died_at_world_time: float = NOT_DEAD_TIME
## What killed it ("" while alive): "combat", "bleeding", "infection" or
## "bleeding_infection" (the players' cause names).
var death_cause: String = ""
## Who dealt the last blow ("" = nobody: it bled out or the infection won).
var killer_id: String = ""
var rise_at_world_time: float = NO_RISE_TIME
## Calendar time from which the NPC may treat itself again.
var self_treat_ready_at_world_time: float = 0.0

var _max_health: float = 100.0
var _max_wounds: int = 64
var _hurt_health_fraction: float = 0.5


func _init(survival: SurvivalSettings = null, settings: NpcHealthSettings = null) -> void:
	if survival != null:
		_max_health = survival.max_health
		_max_wounds = survival.max_wounds_per_player
	if settings != null:
		_hurt_health_fraction = settings.hurt_health_fraction
	health = _max_health


static func create(survival: SurvivalSettings, settings: NpcHealthSettings) -> NpcComponent:
	return NpcVitals.new(survival, settings)


## The vitals of `npc` (null: this build has no NPC health).
static func of(npc: NpcState) -> NpcVitals:
	return npc.component(COMPONENT_ID) as NpcVitals if npc != null else null


## The observable condition of `npc`: the one read-only function the
## network layer is given (NpcNetModule's condition source).
static func condition_of(npc: NpcState) -> String:
	var vitals: NpcVitals = of(npc)
	return vitals.condition() if vitals != null else CONDITION_OK


func component_id() -> String:
	return COMPONENT_ID


func schema_version() -> int:
	return SCHEMA_VERSION


func blocks_simulation() -> bool:
	return not is_alive()


func on_created(_npc: NpcState, _definition: NpcDefinition, _clock: WorldClock) -> void:
	health = _max_health
	injuries.clear()
	infection = InfectionState.new()
	died_at_world_time = NOT_DEAD_TIME
	death_cause = ""
	killer_id = ""
	rise_at_world_time = NO_RISE_TIME
	self_treat_ready_at_world_time = 0.0


## Wound ids come from the world's id sequence: a restored NPC keeps its
## ids out of the way of new ones.
func on_attached(world: ServerWorld, _npc: NpcState) -> void:
	for wound: Wound in injuries:
		world.ids.reserve_existing_id(wound.wound_id)


func is_alive() -> bool:
	return died_at_world_time < 0.0


func max_health() -> float:
	return _max_health


func is_bleeding() -> bool:
	for wound: Wound in injuries:
		if wound.is_bleeding:
			return true
	return false


## True when a zombie's bite is among its wounds.
func has_bite() -> bool:
	for wound: Wound in injuries:
		if wound.wound_type == Wound.Type.BITE:
			return true
	return false


## True when nothing about this body changes with time: full health, no
## wound, no infection. NpcHealth does not look at such an NPC.
func is_untouched() -> bool:
	return is_alive() and health >= _max_health and injuries.is_empty() and not infection.is_infected()


func condition() -> String:
	if not is_alive():
		return CONDITION_DEAD
	if is_bleeding() or health <= _max_health * _hurt_health_fraction:
		return CONDITION_HURT
	return CONDITION_OK


func to_document() -> Dictionary:
	var wounds: Array = []
	var severities: Array = []
	for wound: Wound in injuries:
		wounds.append(wound.to_dict())
		severities.append(FloatBits.encode(wound.severity))
	return {
		KEY_HEALTH: health,
		KEY_INJURIES: wounds,
		KEY_INFECTION: infection.to_dict(),
		KEY_DIED_AT: died_at_world_time,
		KEY_DEATH_CAUSE: death_cause,
		KEY_KILLER_ID: killer_id,
		KEY_RISE_AT: rise_at_world_time,
		KEY_SELF_TREAT_READY_AT: self_treat_ready_at_world_time,
		KEY_EXACT: {
			EXACT_HEALTH: FloatBits.encode(health),
			EXACT_DIED_AT: FloatBits.encode(died_at_world_time),
			EXACT_RISE_AT: FloatBits.encode(rise_at_world_time),
			EXACT_SELF_TREAT_READY_AT: FloatBits.encode(self_treat_ready_at_world_time),
			EXACT_INFECTION_ELAPSED: FloatBits.encode(infection.stage_elapsed_world_sec),
			EXACT_SEVERITIES: severities,
		},
	}


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if int(document.get(KEY_SCHEMA_VERSION, 0)) != SCHEMA_VERSION:
		errors.append("npc vitals: unsupported schema_version %s" % str(document.get(KEY_SCHEMA_VERSION, null)))
		return errors
	for key: String in [KEY_HEALTH, KEY_DIED_AT, KEY_RISE_AT, KEY_SELF_TREAT_READY_AT]:
		if not _is_number(document.get(key, null)):
			errors.append("npc vitals: %s must be a finite number" % key)
	for key: String in [KEY_DEATH_CAUSE, KEY_KILLER_ID]:
		if typeof(document.get(key, null)) != TYPE_STRING or str(document[key]).length() > MAX_ID_LENGTH:
			errors.append("npc vitals: %s must be a short string" % key)
	var raw_wounds: Variant = document.get(KEY_INJURIES, null)
	var raw_infection: Variant = document.get(KEY_INFECTION, null)
	if typeof(raw_wounds) != TYPE_ARRAY or (raw_wounds as Array).size() > _max_wounds:
		errors.append("npc vitals: injuries must be an array of at most %d wounds" % _max_wounds)
	if typeof(raw_infection) != TYPE_DICTIONARY:
		errors.append("npc vitals: infection must be a dictionary")
	if not errors.is_empty():
		return errors
	var exact: Dictionary = document[KEY_EXACT] if typeof(document.get(KEY_EXACT, null)) == TYPE_DICTIONARY else {}
	var exact_severities: Array = exact[EXACT_SEVERITIES] if typeof(exact.get(EXACT_SEVERITIES, null)) == TYPE_ARRAY else []
	var restored_wounds: Array[Wound] = []
	var seen_ids: Dictionary[String, bool] = {}
	for index: int in (raw_wounds as Array).size():
		var entry: Variant = (raw_wounds as Array)[index]
		var wound: Wound = Wound.from_dict(entry as Dictionary) if typeof(entry) == TYPE_DICTIONARY else null
		if wound == null or seen_ids.has(wound.wound_id):
			errors.append("npc vitals: injuries[%d] is not a wound" % index)
			continue
		seen_ids[wound.wound_id] = true
		if index < exact_severities.size():
			wound.severity = clampf(FloatBits.restored(wound.severity, exact_severities[index]), 0.0, Wound.MAX_SEVERITY)
		restored_wounds.append(wound)
	var restored_infection: InfectionState = InfectionState.from_dict(raw_infection as Dictionary)
	if restored_infection == null:
		errors.append("npc vitals: infection is malformed")
	var restored_health: float = FloatBits.restored(float(document[KEY_HEALTH]), exact.get(EXACT_HEALTH, null))
	var restored_died_at: float = FloatBits.restored(float(document[KEY_DIED_AT]), exact.get(EXACT_DIED_AT, null))
	if restored_health < 0.0 or restored_health > _max_health:
		errors.append("npc vitals: health must be within [0, %s]" % str(_max_health))
	# Dead and "has health" never go together (the players' rule).
	if (restored_died_at >= 0.0) != (restored_health <= 0.0):
		errors.append("npc vitals: health and died_at_world_time disagree")
	if not errors.is_empty():
		return errors
	health = restored_health
	injuries = restored_wounds
	infection = restored_infection
	infection.stage_elapsed_world_sec = maxf(FloatBits.restored(infection.stage_elapsed_world_sec, exact.get(EXACT_INFECTION_ELAPSED, null)), 0.0)
	died_at_world_time = restored_died_at if restored_died_at >= 0.0 else NOT_DEAD_TIME
	death_cause = str(document[KEY_DEATH_CAUSE])
	killer_id = str(document[KEY_KILLER_ID])
	var restored_rise_at: float = FloatBits.restored(float(document[KEY_RISE_AT]), exact.get(EXACT_RISE_AT, null))
	rise_at_world_time = restored_rise_at if restored_rise_at >= 0.0 else NO_RISE_TIME
	self_treat_ready_at_world_time = FloatBits.restored(float(document[KEY_SELF_TREAT_READY_AT]), exact.get(EXACT_SELF_TREAT_READY_AT, null))
	return errors


static func _is_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value))
