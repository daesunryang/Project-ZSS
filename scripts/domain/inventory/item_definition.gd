class_name ItemDefinition
extends Resource
## Static item definition (docs/00 ADR-005). Instances reference it by
## `definition_id` only; Resources are never stored in saves.

@export var definition_id: String = ""
@export var display_name: String = ""
## Largest quantity one stack may hold.
@export_range(1, 10000) var max_stack: int = 1
## Consumption effect (P2-T3, docs/00 ADR-010): need units taken off the
## consumer's hunger / thirst when ONE unit of this item is eaten or drunk
## (same unit as SurvivalSettings.need_max). Both 0 = not consumable.
## PROVISIONAL values (docs/15 P2-120).
@export_range(0.0, 10000.0) var consume_hunger_reduction: float = 0.0
@export_range(0.0, 10000.0) var consume_thirst_reduction: float = 0.0


## True when eating/drinking one unit lowers at least one need.
func is_consumable() -> bool:
	return consume_hunger_reduction > 0.0 or consume_thirst_reduction > 0.0


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(definition_id):
		errors.append("definition_id '%s' must be snake_case" % definition_id)
	if max_stack < 1:
		errors.append("max_stack must be >= 1")
	for reduction: float in [consume_hunger_reduction, consume_thirst_reduction]:
		if not is_finite(reduction) or reduction < 0.0:
			errors.append("consume reductions must be finite and >= 0")
			break
	return errors
