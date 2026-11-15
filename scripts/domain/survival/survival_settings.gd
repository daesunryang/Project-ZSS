class_name SurvivalSettings
extends Resource
## Survival tuning (docs/02 §2.1: units/ranges in settings). Defaults in
## `res://data/tuning/survival_settings.tres`. Every value is PROVISIONAL
## (docs/15 §6) and must be balanced by play-testing.
##
## Time units (docs/00 ADR-006, docs/09 §14.16): names with `world_sec` or
## `hours` are calendar time (world seconds / world hours; with the default
## time scale 24 one world hour is 2.5 real minutes). Names ending in plain
## `_sec` are action time (real seconds): stamina regeneration, the respawn
## delay and the damage event interval.

const DEFAULT_PATH: String = "res://data/tuning/survival_settings.tres"
const SECONDS_PER_HOUR: float = 3600.0

@export_range(1.0, 10000.0) var max_health: float = 100.0
@export_range(1.0, 10000.0) var max_stamina: float = 100.0
## Upper end of hunger/thirst/fatigue (0 = fine, max = worst).
@export_range(1.0, 10000.0) var need_max: float = 100.0
## World hours for a need to climb from 0 to need_max (docs/15 P2-4, PROVISIONAL).
@export_range(0.01, 100000.0) var hunger_hours_to_max: float = 48.0
@export_range(0.01, 100000.0) var thirst_hours_to_max: float = 24.0
@export_range(0.01, 100000.0) var fatigue_hours_to_max: float = 18.0
## Rest (P2-T8, docs/15 P2-150, PROVISIONAL). World hours of lying down that
## bring fatigue from need_max to 0 (calendar time; 8 world hours = 20 real
## minutes at the default time scale 24). Fatigue does not rise while resting.
@export_range(0.01, 100000.0) var rest_fatigue_hours_from_max: float = 8.0
## Factor on the hunger and thirst growth while resting (1.0 = as when
## awake, 0 = they do not rise during rest).
@export_range(0.0, 100.0) var rest_hunger_thirst_rate_multiplier: float = 1.0
## Category boundaries: value >= caution -> CAUTION, >= danger -> DANGER.
@export_range(0.0, 10000.0) var need_caution_threshold: float = 40.0
@export_range(0.0, 10000.0) var need_danger_threshold: float = 75.0
## Penalties from the worst need category (docs/02 §3 stepwise penalties):
## stamina regen multiplier and movement speed multiplier (1.0 = no penalty).
@export_range(0.0, 1.0) var caution_stamina_regen_multiplier: float = 0.75
@export_range(0.0, 1.0) var danger_stamina_regen_multiplier: float = 0.4
@export_range(0.0, 1.0) var caution_movement_multiplier: float = 0.9
@export_range(0.0, 1.0) var danger_movement_multiplier: float = 0.6
## Stamina regained per real second (action time) while alive.
@export_range(0.0, 1000.0) var stamina_regen_per_sec: float = 5.0
## Damage amount that produces a severity-1.0 wound (severity = amount / this).
@export_range(0.1, 10000.0) var wound_severity_reference_damage: float = 50.0
## Wounds kept per player; further wounds still deal damage but are not listed.
@export_range(1, 1000) var max_wounds_per_player: int = 64
## Undrained survival events kept for the network layer; oldest are dropped.
@export_range(1, 1000000) var max_pending_events: int = 256
## Real seconds (action time) of time-based damage (bleeding, starvation,
## dehydration, infection) summed into one "player_survival_damage" event.
## 0 = one event per tick. Health is applied every tick regardless (docs/15 P2-88).
@export_range(0.0, 3600.0) var survival_damage_event_interval_sec: float = 1.0
## Handling multiplier = 1 - penalty * sum(arm/hand severity), clamped to min.
@export_range(0.0, 10.0) var handling_penalty_per_severity: float = 0.5
@export_range(0.0, 1.0) var min_handling_multiplier: float = 0.25
## Movement multiplier = 1 - penalty * sum(leg/foot severity), clamped to min.
@export_range(0.0, 10.0) var movement_penalty_per_severity: float = 0.5
@export_range(0.0, 1.0) var min_movement_multiplier: float = 0.25
## B3 bleeding and recovery. A wound starts bleeding when its severity reaches
## the threshold and its type multiplier is positive. All defaults are
## PROVISIONAL (docs/15 P2-13..P2-16).
@export_range(0.0, 1.0) var bleeding_min_severity: float = 0.25
@export_range(0.0, 1000.0) var bleeding_health_loss_per_severity_per_world_sec: float = 0.01
@export_range(0.0, 100.0) var bleeding_bruise_multiplier: float = 0.0
@export_range(0.0, 100.0) var bleeding_laceration_multiplier: float = 1.0
@export_range(0.0, 100.0) var bleeding_fracture_multiplier: float = 0.0
@export_range(0.0, 100.0) var bleeding_burn_multiplier: float = 0.0
@export_range(0.0, 100.0) var bleeding_bite_multiplier: float = 0.75
@export_range(0.0, 100.0) var bleeding_scratch_multiplier: float = 0.25
@export_range(0.0, 1000.0) var health_recovery_per_world_sec: float = 0.02
@export_range(0.0, 1.0) var wound_recovery_per_world_sec: float = 0.0001
## Health loss while the corresponding need is exactly at need_max.
@export_range(0.0, 1000.0) var starvation_health_loss_per_world_sec: float = 0.005
@export_range(0.0, 1000.0) var dehydration_health_loss_per_world_sec: float = 0.01
## Development respawn policy (docs/15 P2-6/P2-17). The delay is real
## seconds (action time).
@export_range(0.0, 1000000.0) var respawn_delay_sec: float = 10.0
@export_range(0.0, 10000.0) var respawn_hunger: float = 0.0
@export_range(0.0, 10000.0) var respawn_thirst: float = 0.0
@export_range(0.0, 10000.0) var respawn_fatigue: float = 0.0
## Infection chance per exposure (docs/02 §7.1: bites are very high risk).
@export_range(0.0, 1.0) var infection_chance_bite: float = 0.95
@export_range(0.0, 1.0) var infection_chance_scratch: float = 0.15
@export_range(0.0, 1.0) var infection_chance_blood: float = 0.05
## Base duration of each progressing stage in world hours (docs/15 P2-7).
@export_range(0.000001, 100000.0) var infection_latent_hours: float = 2.0
@export_range(0.000001, 100000.0) var infection_early_hours: float = 6.0
@export_range(0.000001, 100000.0) var infection_progressing_hours: float = 12.0
@export_range(0.000001, 100000.0) var infection_severe_hours: float = 12.0
@export_range(0.000001, 100000.0) var infection_terminal_hours: float = 6.0
## Exposure-specific duration factor (1.0 = base duration).
@export_range(0.000001, 1000.0) var infection_bite_time_multiplier: float = 1.0
@export_range(0.000001, 1000.0) var infection_scratch_time_multiplier: float = 1.0
@export_range(0.000001, 1000.0) var infection_blood_time_multiplier: float = 1.0
## Stage effects. Stamina factors multiply need penalties; health loss adds to
## bleeding/starvation/dehydration damage (docs/15 P2-19, PROVISIONAL).
@export_range(0.0, 1.0) var infection_latent_stamina_regen_multiplier: float = 1.0
@export_range(0.0, 1.0) var infection_early_stamina_regen_multiplier: float = 1.0
@export_range(0.0, 1.0) var infection_progressing_stamina_regen_multiplier: float = 0.8
@export_range(0.0, 1.0) var infection_severe_stamina_regen_multiplier: float = 0.5
@export_range(0.0, 1.0) var infection_terminal_stamina_regen_multiplier: float = 0.2
@export_range(0.0, 1000.0) var infection_latent_health_loss_per_world_sec: float = 0.0
@export_range(0.0, 1000.0) var infection_early_health_loss_per_world_sec: float = 0.0
@export_range(0.0, 1000.0) var infection_progressing_health_loss_per_world_sec: float = 0.0001
@export_range(0.0, 1000.0) var infection_severe_health_loss_per_world_sec: float = 0.0005
@export_range(0.0, 1000.0) var infection_terminal_health_loss_per_world_sec: float = 0.002
## Treatment succeeds through this stage (inclusive).
@export_enum("Latent:1", "Early:2", "Progressing:3", "Severe:4", "Terminal:5") var infection_treatment_max_stage: int = InfectionState.Stage.EARLY
## Base seed for per-player infection RNG (seed = hash("<base>:<player_id>")).
@export var rng_seed: int = 0


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if max_health <= 0.0 or max_stamina <= 0.0 or need_max <= 0.0:
		errors.append("max_health, max_stamina and need_max must be > 0")
	if stamina_regen_per_sec < 0.0:
		errors.append("stamina_regen_per_sec must be >= 0")
	if hunger_hours_to_max <= 0.0 or thirst_hours_to_max <= 0.0 or fatigue_hours_to_max <= 0.0:
		errors.append("need *_hours_to_max must be > 0")
	if not is_finite(rest_fatigue_hours_from_max) or rest_fatigue_hours_from_max <= 0.0:
		errors.append("rest_fatigue_hours_from_max must be finite and > 0")
	if not is_finite(rest_hunger_thirst_rate_multiplier) or rest_hunger_thirst_rate_multiplier < 0.0:
		errors.append("rest_hunger_thirst_rate_multiplier must be finite and >= 0")
	if need_caution_threshold < 0.0 or need_caution_threshold >= need_danger_threshold or need_danger_threshold > need_max:
		errors.append("need thresholds must satisfy 0 <= caution < danger <= need_max")
	for multiplier: float in [caution_stamina_regen_multiplier, danger_stamina_regen_multiplier, caution_movement_multiplier, danger_movement_multiplier]:
		if multiplier < 0.0 or multiplier > 1.0:
			errors.append("need penalty multipliers must be within [0, 1]")
			break
	if danger_stamina_regen_multiplier > caution_stamina_regen_multiplier or danger_movement_multiplier > caution_movement_multiplier:
		errors.append("danger penalties must not be milder than caution penalties")
	if wound_severity_reference_damage <= 0.0:
		errors.append("wound_severity_reference_damage must be > 0")
	if max_wounds_per_player < 1:
		errors.append("max_wounds_per_player must be >= 1")
	if max_pending_events < 1:
		errors.append("survival max_pending_events must be >= 1")
	if not is_finite(survival_damage_event_interval_sec) or survival_damage_event_interval_sec < 0.0:
		errors.append("survival_damage_event_interval_sec must be >= 0")
	for chance: float in [infection_chance_bite, infection_chance_scratch, infection_chance_blood]:
		if chance < 0.0 or chance > 1.0:
			errors.append("infection chances must be within [0, 1]")
			break
	var infection_durations: Array[float] = [
		infection_latent_hours, infection_early_hours, infection_progressing_hours,
		infection_severe_hours, infection_terminal_hours,
	]
	for duration: float in infection_durations:
		if duration <= 0.0 or not is_finite(duration):
			errors.append("infection stage durations must be finite and > 0")
			break
	for time_multiplier: float in [infection_bite_time_multiplier, infection_scratch_time_multiplier, infection_blood_time_multiplier]:
		if time_multiplier <= 0.0 or not is_finite(time_multiplier):
			errors.append("infection time multipliers must be finite and > 0")
			break
	for stamina_multiplier: float in [infection_latent_stamina_regen_multiplier, infection_early_stamina_regen_multiplier, infection_progressing_stamina_regen_multiplier, infection_severe_stamina_regen_multiplier, infection_terminal_stamina_regen_multiplier]:
		if stamina_multiplier < 0.0 or stamina_multiplier > 1.0 or not is_finite(stamina_multiplier):
			errors.append("infection stamina multipliers must be finite and within [0, 1]")
			break
	for health_loss: float in [infection_latent_health_loss_per_world_sec, infection_early_health_loss_per_world_sec, infection_progressing_health_loss_per_world_sec, infection_severe_health_loss_per_world_sec, infection_terminal_health_loss_per_world_sec]:
		if health_loss < 0.0 or not is_finite(health_loss):
			errors.append("infection health loss rates must be finite and >= 0")
			break
	if infection_treatment_max_stage < InfectionState.Stage.LATENT or infection_treatment_max_stage > InfectionState.Stage.TERMINAL:
		errors.append("infection treatment max stage must be latent through terminal")
	if min_handling_multiplier < 0.0 or min_handling_multiplier > 1.0 or min_movement_multiplier < 0.0 or min_movement_multiplier > 1.0:
		errors.append("minimum multipliers must be within [0, 1]")
	if bleeding_min_severity < 0.0 or bleeding_min_severity > Wound.MAX_SEVERITY:
		errors.append("bleeding_min_severity must be within [0, 1]")
	var non_negative_rates: Array[float] = [
		bleeding_health_loss_per_severity_per_world_sec,
		health_recovery_per_world_sec, wound_recovery_per_world_sec,
		starvation_health_loss_per_world_sec, dehydration_health_loss_per_world_sec,
		respawn_delay_sec,
	]
	for rate: float in non_negative_rates:
		if rate < 0.0 or not is_finite(rate):
			errors.append("B3 rates and respawn delay must be finite and >= 0")
			break
	var bleeding_multipliers: Array[float] = [
		bleeding_bruise_multiplier, bleeding_laceration_multiplier,
		bleeding_fracture_multiplier, bleeding_burn_multiplier,
		bleeding_bite_multiplier, bleeding_scratch_multiplier,
	]
	for multiplier: float in bleeding_multipliers:
		if multiplier < 0.0 or not is_finite(multiplier):
			errors.append("bleeding type multipliers must be finite and >= 0")
			break
	for reset_need: float in [respawn_hunger, respawn_thirst, respawn_fatigue]:
		if reset_need < 0.0 or reset_need > need_max or not is_finite(reset_need):
			errors.append("respawn needs must be within [0, need_max]")
			break
	return errors


## Need units gained per world second for a need kind (NeedKind.Kind).
func need_rate_per_world_sec(kind: NeedKind.Kind) -> float:
	var hours: float
	match kind:
		NeedKind.Kind.HUNGER:
			hours = hunger_hours_to_max
		NeedKind.Kind.THIRST:
			hours = thirst_hours_to_max
		_:
			hours = fatigue_hours_to_max
	return need_max / (hours * SECONDS_PER_HOUR)


## Need units per world second for a need kind while the player rests
## (P2-T8): fatigue falls (a negative rate), hunger and thirst rise at their
## usual rate times `rest_hunger_thirst_rate_multiplier`.
func resting_need_rate_per_world_sec(kind: NeedKind.Kind) -> float:
	if kind == NeedKind.Kind.FATIGUE:
		return -need_max / (rest_fatigue_hours_from_max * SECONDS_PER_HOUR)
	return need_rate_per_world_sec(kind) * rest_hunger_thirst_rate_multiplier


## Stamina regen factor for a worst-need category.
func stamina_regen_multiplier(category: NeedKind.Category) -> float:
	match category:
		NeedKind.Category.DANGER:
			return danger_stamina_regen_multiplier
		NeedKind.Category.CAUTION:
			return caution_stamina_regen_multiplier
		_:
			return 1.0


## Movement speed factor for a worst-need category.
func need_movement_multiplier(category: NeedKind.Category) -> float:
	match category:
		NeedKind.Category.DANGER:
			return danger_movement_multiplier
		NeedKind.Category.CAUTION:
			return caution_movement_multiplier
		_:
			return 1.0


## Chance for an exposure type (InfectionState.Exposure).
func infection_chance(exposure: InfectionState.Exposure) -> float:
	match exposure:
		InfectionState.Exposure.BITE:
			return infection_chance_bite
		InfectionState.Exposure.SCRATCH:
			return infection_chance_scratch
		_:
			return infection_chance_blood


## Configured active world seconds in a stage for an exposure route.
func infection_stage_duration_world_sec(stage: InfectionState.Stage, exposure: InfectionState.Exposure) -> float:
	var hours: float = 0.0
	match stage:
		InfectionState.Stage.LATENT:
			hours = infection_latent_hours
		InfectionState.Stage.EARLY:
			hours = infection_early_hours
		InfectionState.Stage.PROGRESSING:
			hours = infection_progressing_hours
		InfectionState.Stage.SEVERE:
			hours = infection_severe_hours
		InfectionState.Stage.TERMINAL:
			hours = infection_terminal_hours
		_:
			return 0.0
	return hours * SECONDS_PER_HOUR * infection_exposure_time_multiplier(exposure)


func infection_exposure_time_multiplier(exposure: InfectionState.Exposure) -> float:
	match exposure:
		InfectionState.Exposure.BITE:
			return infection_bite_time_multiplier
		InfectionState.Exposure.SCRATCH:
			return infection_scratch_time_multiplier
		_:
			return infection_blood_time_multiplier


func infection_stamina_regen_multiplier(stage: InfectionState.Stage) -> float:
	match stage:
		InfectionState.Stage.LATENT:
			return infection_latent_stamina_regen_multiplier
		InfectionState.Stage.EARLY:
			return infection_early_stamina_regen_multiplier
		InfectionState.Stage.PROGRESSING:
			return infection_progressing_stamina_regen_multiplier
		InfectionState.Stage.SEVERE:
			return infection_severe_stamina_regen_multiplier
		InfectionState.Stage.TERMINAL:
			return infection_terminal_stamina_regen_multiplier
		InfectionState.Stage.ZOMBIFIED:
			return 0.0
		_:
			return 1.0


func infection_health_loss_per_world_sec(stage: InfectionState.Stage) -> float:
	match stage:
		InfectionState.Stage.LATENT:
			return infection_latent_health_loss_per_world_sec
		InfectionState.Stage.EARLY:
			return infection_early_health_loss_per_world_sec
		InfectionState.Stage.PROGRESSING:
			return infection_progressing_health_loss_per_world_sec
		InfectionState.Stage.SEVERE:
			return infection_severe_health_loss_per_world_sec
		InfectionState.Stage.TERMINAL:
			return infection_terminal_health_loss_per_world_sec
		_:
			return 0.0


## Bleeding rate factor for one Wound.Type.
func bleeding_type_multiplier(type: Wound.Type) -> float:
	match type:
		Wound.Type.BRUISE:
			return bleeding_bruise_multiplier
		Wound.Type.LACERATION:
			return bleeding_laceration_multiplier
		Wound.Type.FRACTURE:
			return bleeding_fracture_multiplier
		Wound.Type.BURN:
			return bleeding_burn_multiplier
		Wound.Type.BITE:
			return bleeding_bite_multiplier
		_:
			return bleeding_scratch_multiplier


func wound_starts_bleeding(type: Wound.Type, severity: float) -> bool:
	return severity >= bleeding_min_severity and bleeding_type_multiplier(type) > 0.0


static func load_or_default(path: String = DEFAULT_PATH) -> SurvivalSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is SurvivalSettings:
		return loaded as SurvivalSettings
	GameLogger.warning("config", "survival settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return SurvivalSettings.new()
