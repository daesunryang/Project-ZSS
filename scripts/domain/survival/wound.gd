class_name Wound
extends RefCounted
## One injury on one body part (docs/02 §2.2). Bleeding is persistent state:
## treatment can stop it without changing the wound type or severity.

enum Type { BRUISE, LACERATION, FRACTURE, BURN, BITE, SCRATCH }

## Save/network names, indexed by Type.
const TYPE_NAMES: PackedStringArray = ["bruise", "laceration", "fracture", "burn", "bite", "scratch"]
const MAX_SEVERITY: float = 1.0

var wound_id: String = ""
var body_part: BodyPart.Part = BodyPart.Part.TORSO
var wound_type: Type = Type.BRUISE
## 0..1, derived from damage amount (SurvivalSettings.wound_severity_reference_damage).
var severity: float = 0.0
var is_bleeding: bool = false
## Entity that caused it (zombie id, player id, "environment", ...).
var source_id: String = ""
var created_at_world_time: float = 0.0


static func is_valid_type(value: int) -> bool:
	return value >= 0 and value < TYPE_NAMES.size()


static func type_name(type: Type) -> String:
	return TYPE_NAMES[type]


func to_dict() -> Dictionary:
	return {
		"wound_id": wound_id,
		"body_part": BodyPart.to_name(body_part),
		"wound_type": TYPE_NAMES[wound_type],
		"severity": severity,
		"is_bleeding": is_bleeding,
		"source_id": source_id,
		"created_at_world_time": created_at_world_time,
	}


## Returns null when `data` is malformed.
static func from_dict(data: Dictionary) -> Wound:
	var part: int = BodyPart.from_name(str(data.get("body_part", "")))
	var type: int = TYPE_NAMES.find(str(data.get("wound_type", "")))
	var severity_value: Variant = data.get("severity", null)
	var created: Variant = data.get("created_at_world_time", 0.0)
	var bleeding: Variant = data.get("is_bleeding", false)
	if part < 0 or type < 0 or typeof(data.get("wound_id", null)) != TYPE_STRING or str(data["wound_id"]).is_empty():
		return null
	if not (typeof(severity_value) == TYPE_FLOAT or typeof(severity_value) == TYPE_INT):
		return null
	if float(severity_value) < 0.0 or float(severity_value) > MAX_SEVERITY:
		return null
	if not (typeof(created) == TYPE_FLOAT or typeof(created) == TYPE_INT) or not is_finite(float(created)):
		return null
	if typeof(bleeding) != TYPE_BOOL:
		return null
	var wound: Wound = Wound.new()
	wound.wound_id = str(data["wound_id"])
	wound.body_part = part as BodyPart.Part
	wound.wound_type = type as Type
	wound.severity = float(severity_value)
	wound.is_bleeding = bool(bleeding)
	wound.source_id = str(data.get("source_id", ""))
	wound.created_at_world_time = float(created)
	return wound
