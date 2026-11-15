class_name BodyPart
extends RefCounted
## Body parts that can be injured (docs/02 §2.2). Saved by name.

enum Part { HEAD, TORSO, LEFT_ARM, RIGHT_ARM, LEFT_HAND, RIGHT_HAND, LEFT_LEG, RIGHT_LEG, LEFT_FOOT, RIGHT_FOOT }

## Save/network names, indexed by Part.
const NAMES: PackedStringArray = [
	"head", "torso", "left_arm", "right_arm", "left_hand", "right_hand",
	"left_leg", "right_leg", "left_foot", "right_foot",
]


static func is_valid(value: int) -> bool:
	return value >= 0 and value < NAMES.size()


static func to_name(part: Part) -> String:
	return NAMES[part]


## Part for a saved name, or -1.
static func from_name(part_name: String) -> int:
	return NAMES.find(part_name)


## Arms/hands: weapon handling, crafting, carrying (docs/02 §2.2).
static func affects_handling(part: Part) -> bool:
	return part in [Part.LEFT_ARM, Part.RIGHT_ARM, Part.LEFT_HAND, Part.RIGHT_HAND]


## Legs/feet: movement speed, evasion, running (docs/02 §2.2).
static func affects_movement(part: Part) -> bool:
	return part in [Part.LEFT_LEG, Part.RIGHT_LEG, Part.LEFT_FOOT, Part.RIGHT_FOOT]
