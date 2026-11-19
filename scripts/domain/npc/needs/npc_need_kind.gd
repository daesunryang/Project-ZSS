class_name NpcNeedKind
extends RefCounted
## Stable need and activity ids used by the NPC `needs` component (P4-2,
## docs/09 §17.2). Only hunger, thirst and fatigue are simulated in Phase 4.
## The other ids remain definition data with zero rates (docs/13 §16.3 D13).

enum Category { NORMAL, CAUTION, DANGER }

const HUNGER: String = "hunger"
const THIRST: String = "thirst"
const FATIGUE: String = "fatigue"
const WARMTH: String = "warmth"
const HYGIENE: String = "hygiene"
const COMPANIONSHIP: String = "companionship"
const BELONGING: String = "belonging"
const INTIMACY: String = "intimacy"
const FAMILY_CONTACT: String = "family_contact"
const AUTONOMY: String = "autonomy"
const COMPETENCE: String = "competence"
const PURPOSE: String = "purpose"
const RECREATION: String = "recreation"

const SIMULATED_KINDS: PackedStringArray = [HUNGER, THIRST, FATIGUE]
const ZERO_RATE_KINDS: PackedStringArray = [
	WARMTH, HYGIENE,
	COMPANIONSHIP, BELONGING, INTIMACY, FAMILY_CONTACT,
	AUTONOMY, COMPETENCE, PURPOSE, RECREATION,
]
const DEFINED_KINDS: PackedStringArray = [
	HUNGER, THIRST, FATIGUE,
	WARMTH, HYGIENE,
	COMPANIONSHIP, BELONGING, INTIMACY, FAMILY_CONTACT,
	AUTONOMY, COMPETENCE, PURPOSE, RECREATION,
]

const IDLE: String = "idle"
const RESTING: String = "resting"
const WORKING: String = "working"
const ACTIVITIES: PackedStringArray = [IDLE, RESTING, WORKING]
const CATEGORY_NAMES: PackedStringArray = ["normal", "caution", "danger"]


static func is_defined(kind: String) -> bool:
	return DEFINED_KINDS.has(kind)


static func is_simulated(kind: String) -> bool:
	return SIMULATED_KINDS.has(kind)


static func is_valid_activity(activity: String) -> bool:
	return ACTIVITIES.has(activity)


## Category of a raw need value. A larger value is worse.
static func category_for(value: float, caution_threshold: float, danger_threshold: float) -> Category:
	if value >= danger_threshold:
		return Category.DANGER
	if value >= caution_threshold:
		return Category.CAUTION
	return Category.NORMAL


static func category_name(category: Category) -> String:
	return CATEGORY_NAMES[category]
