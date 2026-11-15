class_name SurvivalSettings
extends Resource
## Survival tuning (docs/02 §2.1: units/ranges in settings). Defaults in
## `res://data/tuning/survival_settings.tres`. Every value is PROVISIONAL
## (docs/15 §6) and must be balanced by play-testing.

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
## Category boundaries: value >= caution -> CAUTION, >= danger -> DANGER.
@export_range(0.0, 10000.0) var need_caution_threshold: float = 40.0
@export_range(0.0, 10000.0) var need_danger_threshold: float = 75.0
## Penalties from the worst need category (docs/02 §3 stepwise penalties):
## stamina regen multiplier and movement speed multiplier (1.0 = no penalty).
@export_range(0.0, 1.0) var caution_stamina_regen_multiplier: float = 0.75
@export_range(0.0, 1.0) var danger_stamina_regen_multiplier: float = 0.4
@export_range(0.0, 1.0) var caution_movement_multiplier: float = 0.9
@export_range(0.0, 1.0) var danger_movement_multiplier: float = 0.6
## Stamina regained per world second while alive.
@export_range(0.0, 1000.0) var stamina_regen_per_world_sec: float = 5.0
## Damage amount that produces a severity-1.0 wound (severity = amount / this).
@export_range(0.1, 10000.0) var wound_severity_reference_damage: float = 50.0
## Wounds kept per player; further wounds still deal damage but are not listed.
@export_range(1, 1000) var max_wounds_per_player: int = 64
## Handling multiplier = 1 - penalty * sum(arm/hand severity), clamped to min.
@export_range(0.0, 10.0) var handling_penalty_per_severity: float = 0.5
@export_range(0.0, 1.0) var min_handling_multiplier: float = 0.25
## Movement multiplier = 1 - penalty * sum(leg/foot severity), clamped to min.
@export_range(0.0, 10.0) var movement_penalty_per_severity: float = 0.5
@export_range(0.0, 1.0) var min_movement_multiplier: float = 0.25
## Infection chance per exposure (docs/02 §7.1: bites are very high risk).
@export_range(0.0, 1.0) var infection_chance_bite: float = 0.95
@export_range(0.0, 1.0) var infection_chance_scratch: float = 0.15
@export_range(0.0, 1.0) var infection_chance_blood: float = 0.05
## Base seed for per-player infection RNG (seed = hash("<base>:<player_id>")).
@export var rng_seed: int = 0


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if max_health <= 0.0 or max_stamina <= 0.0 or need_max <= 0.0:
		errors.append("max_health, max_stamina and need_max must be > 0")
	if stamina_regen_per_world_sec < 0.0:
		errors.append("stamina_regen_per_world_sec must be >= 0")
	if hunger_hours_to_max <= 0.0 or thirst_hours_to_max <= 0.0 or fatigue_hours_to_max <= 0.0:
		errors.append("need *_hours_to_max must be > 0")
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
	for chance: float in [infection_chance_bite, infection_chance_scratch, infection_chance_blood]:
		if chance < 0.0 or chance > 1.0:
			errors.append("infection chances must be within [0, 1]")
			break
	if min_handling_multiplier < 0.0 or min_handling_multiplier > 1.0 or min_movement_multiplier < 0.0 or min_movement_multiplier > 1.0:
		errors.append("minimum multipliers must be within [0, 1]")
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


static func load_or_default(path: String = DEFAULT_PATH) -> SurvivalSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is SurvivalSettings:
		return loaded as SurvivalSettings
	GameLogger.warning("config", "survival settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return SurvivalSettings.new()
