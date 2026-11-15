class_name DamageInput
extends RefCounted
## Server-computed damage to apply to a player (built by combat/zombie
## systems, never by clients). `amount` is in health points.

const REASON_BAD_AMOUNT: String = "bad_damage_amount"
const REASON_BAD_BODY_PART: String = "bad_body_part"
const REASON_BAD_WOUND_TYPE: String = "bad_wound_type"
const REASON_BAD_SOURCE: String = "bad_damage_source"

var source_id: String = ""
var body_part: BodyPart.Part = BodyPart.Part.TORSO
var wound_type: Wound.Type = Wound.Type.BRUISE
var amount: float = 0.0


static func create(source: String, part: BodyPart.Part, type: Wound.Type, damage_amount: float) -> DamageInput:
	var damage: DamageInput = DamageInput.new()
	damage.source_id = source
	damage.body_part = part
	damage.wound_type = type
	damage.amount = damage_amount
	return damage


## "" when valid, otherwise a reason code.
func validate() -> String:
	if not is_finite(amount) or amount <= 0.0:
		return REASON_BAD_AMOUNT
	if not BodyPart.is_valid(body_part):
		return REASON_BAD_BODY_PART
	if not Wound.is_valid_type(wound_type):
		return REASON_BAD_WOUND_TYPE
	if source_id.is_empty():
		return REASON_BAD_SOURCE
	return ""
