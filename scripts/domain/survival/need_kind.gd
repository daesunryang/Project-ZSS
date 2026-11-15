class_name NeedKind
extends RefCounted
## Survival needs that accumulate over time (docs/02 §3) and the display
## categories derived from them. 0 = fine ... need_max = worst.

enum Kind { HUNGER, THIRST, FATIGUE }
enum Category { GOOD, CAUTION, DANGER }

## Save/network names, indexed by Kind / Category.
const KIND_NAMES: PackedStringArray = ["hunger", "thirst", "fatigue"]
const CATEGORY_NAMES: PackedStringArray = ["good", "caution", "danger"]


static func is_valid_kind(value: int) -> bool:
	return value >= 0 and value < KIND_NAMES.size()


static func kind_name(kind: Kind) -> String:
	return KIND_NAMES[kind]


static func category_name(category: Category) -> String:
	return CATEGORY_NAMES[category]


## Category of a raw need value: >= danger -> DANGER, >= caution -> CAUTION.
static func category_for(value: float, caution_threshold: float, danger_threshold: float) -> Category:
	if value >= danger_threshold:
		return Category.DANGER
	if value >= caution_threshold:
		return Category.CAUTION
	return Category.GOOD
