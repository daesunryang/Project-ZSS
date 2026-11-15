class_name PlayerVitals
extends RefCounted
## Server-side survival state of one player (docs/02 §2.1, Phase 2 subset).
## Saved as the "survival" fragment of players/<id>.json.
## B1 fields: health, stamina, hunger/thirst/fatigue (progression is B2),
## injuries, infection, per-player RNG. Not yet: body_temperature, stress,
## hygiene (later phases).

const SCHEMA_VERSION: int = 3
const LEGACY_SCHEMA_VERSION: int = 1
const B3_SCHEMA_VERSION: int = 2
const NOT_DEAD_TIME: float = -1.0

var health: float = 0.0
var stamina: float = 0.0
## 0 = fine ... SurvivalSettings.need_max = worst.
var hunger: float = 0.0
var thirst: float = 0.0
var fatigue: float = 0.0
var injuries: Array[Wound] = []
var infection: InfectionState = InfectionState.new()
## World time at death; NOT_DEAD_TIME while alive. Added in schema v2.
var died_at_world_time: float = NOT_DEAD_TIME
## Deterministic per-player RNG (infection rolls). State is saved.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


## Full-health vitals with a deterministic RNG seed.
static func create_default(settings: SurvivalSettings, rng_seed: int) -> PlayerVitals:
	var vitals: PlayerVitals = PlayerVitals.new()
	vitals.health = settings.max_health
	vitals.stamina = settings.max_stamina
	vitals.rng.seed = rng_seed
	return vitals


func is_alive() -> bool:
	return health > 0.0


func to_dict() -> Dictionary:
	var wounds: Array[Dictionary] = []
	for wound: Wound in injuries:
		wounds.append(wound.to_dict())
	return {
		"schema_version": SCHEMA_VERSION,
		"health": health,
		"stamina": stamina,
		"hunger": hunger,
		"thirst": thirst,
		"fatigue": fatigue,
		"injuries": wounds,
		"infection": infection.to_dict(),
		"died_at_world_time": died_at_world_time,
		# 64-bit values are stored as strings: JSON numbers would lose precision.
		"rng_seed": str(rng.seed),
		"rng_state": str(rng.state),
	}


## Returns [vitals, errors]. `vitals` is null when errors is non-empty.
static func from_dict(data: Dictionary, settings: SurvivalSettings) -> Array:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(data.get("schema_version", null)) or int(data["schema_version"]) not in [LEGACY_SCHEMA_VERSION, B3_SCHEMA_VERSION, SCHEMA_VERSION]:
		errors.append("survival: unsupported schema_version")
		return [null, errors]
	var schema_version: int = int(data["schema_version"])
	var vitals: PlayerVitals = PlayerVitals.new()
	var limits: Dictionary = {
		"health": settings.max_health, "stamina": settings.max_stamina,
		"hunger": settings.need_max, "thirst": settings.need_max, "fatigue": settings.need_max,
	}
	var health_valid: bool = true
	for key: String in limits:
		var value: Variant = data.get(key, null)
		if not (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) or not is_finite(float(value)) or float(value) < 0.0 or float(value) > float(limits[key]):
			errors.append("survival: %s out of range" % key)
			if key == "health":
				health_valid = false
			continue
		vitals.set(key, float(value))
	var wounds: Variant = data.get("injuries", [])
	if typeof(wounds) != TYPE_ARRAY:
		errors.append("survival: injuries must be an array")
	else:
		for entry: Variant in (wounds as Array):
			var wound: Wound = Wound.from_dict(entry as Dictionary) if typeof(entry) == TYPE_DICTIONARY else null
			if wound == null:
				errors.append("survival: invalid wound")
				continue
			vitals.injuries.append(wound)
	var infection_data: Variant = data.get("infection", null)
	var infection: InfectionState = InfectionState.from_dict(infection_data as Dictionary) if typeof(infection_data) == TYPE_DICTIONARY else null
	if infection == null:
		errors.append("survival: invalid infection state")
	else:
		vitals.infection = infection
	var died_at: Variant = data.get("died_at_world_time", NOT_DEAD_TIME)
	if not (typeof(died_at) == TYPE_FLOAT or typeof(died_at) == TYPE_INT) or not is_finite(float(died_at)) or (float(died_at) != NOT_DEAD_TIME and float(died_at) < 0.0):
		errors.append("survival: died_at_world_time out of range")
	else:
		vitals.died_at_world_time = float(died_at)
		if health_valid and schema_version >= B3_SCHEMA_VERSION and ((vitals.health > 0.0 and vitals.died_at_world_time != NOT_DEAD_TIME) or (vitals.health <= 0.0 and vitals.died_at_world_time == NOT_DEAD_TIME)):
			errors.append("survival: health/death timestamp mismatch")
	var seed_text: String = str(data.get("rng_seed", ""))
	var state_text: String = str(data.get("rng_state", ""))
	if not seed_text.is_valid_int() or not state_text.is_valid_int():
		errors.append("survival: invalid rng seed/state")
	else:
		vitals.rng.seed = seed_text.to_int()
		vitals.rng.state = state_text.to_int()
	if not errors.is_empty():
		return [null, errors]
	return [vitals, errors]
