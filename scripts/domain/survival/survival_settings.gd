class_name SurvivalSettings
extends Resource
## Survival tuning (docs/02 §2.1: units/ranges in settings). Defaults in
## `res://data/tuning/survival_settings.tres`. Every value is PROVISIONAL
## (docs/15 §6) and must be balanced by play-testing.

const DEFAULT_PATH: String = "res://data/tuning/survival_settings.tres"

@export_range(1.0, 10000.0) var max_health: float = 100.0
@export_range(1.0, 10000.0) var max_stamina: float = 100.0
## Upper end of hunger/thirst/fatigue (0 = fine, max = worst). Progression is B2.
@export_range(1.0, 10000.0) var need_max: float = 100.0
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
