class_name PlayerVitals
extends RefCounted
## Server-side survival state of one player (docs/02 §2.1, Phase 2 subset).
## Saved as the "survival" fragment of players/<id>.json.
## B1 fields: health, stamina, hunger/thirst/fatigue (progression is B2),
## injuries, infection, per-player RNG. Not yet: body_temperature, stress,
## hygiene (later phases).

const SCHEMA_VERSION: int = 1

var health: float = 0.0
var stamina: float = 0.0
## 0 = fine ... SurvivalSettings.need_max = worst.
var hunger: float = 0.0
var thirst: float = 0.0
var fatigue: float = 0.0
var injuries: Array[Wound] = []
var infection: InfectionState = InfectionState.new()
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
		# 64-bit values are stored as strings: JSON numbers would lose precision.
		"rng_seed": str(rng.seed),
		"rng_state": str(rng.state),
	}


## Returns [vitals, errors]. `vitals` is null when errors is non-empty.
static func from_dict(data: Dictionary, settings: SurvivalSettings) -> Array:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(data.get("schema_version", null)) or int(data["schema_version"]) != SCHEMA_VERSION:
		errors.append("survival: unsupported schema_version")
		return [null, errors]
	var vitals: PlayerVitals = PlayerVitals.new()
	var limits: Dictionary = {
		"health": settings.max_health, "stamina": settings.max_stamina,
		"hunger": settings.need_max, "thirst": settings.need_max, "fatigue": settings.need_max,
	}
	for key: String in limits:
		var value: Variant = data.get(key, null)
		if not (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) or not is_finite(float(value)) or float(value) < 0.0 or float(value) > float(limits[key]):
			errors.append("survival: %s out of range" % key)
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
