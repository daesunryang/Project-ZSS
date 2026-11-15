class_name ItemDefinition
extends Resource
## Static item definition (docs/00 ADR-005). Instances reference it by
## `definition_id` only; Resources are never stored in saves.
##
## Use effects: what the server applies when ONE unit of the item is used up
## (ItemConsumption, docs/09 §14.18, §14.21). An item may have several; an
## item with none cannot be used.

@export var definition_id: String = ""
@export var display_name: String = ""
## Largest quantity one stack may hold.
@export_range(1, 10000) var max_stack: int = 1
## Eating / drinking effect (P2-T3, docs/00 ADR-010): need units taken off
## the consumer's hunger / thirst (same unit as SurvivalSettings.need_max).
## Both 0 = no such effect. PROVISIONAL values (docs/15 P2-120).
@export_range(0.0, 10000.0) var consume_hunger_reduction: float = 0.0
@export_range(0.0, 10000.0) var consume_thirst_reduction: float = 0.0
## Bandaging effect (P2-T6): how many of the user's bleeding wounds one unit
## stops, worst first (SurvivalService.stop_worst_bleeding). 0 = no such
## effect; a value of at least SurvivalSettings.max_wounds_per_player treats
## every bleeding wound. PROVISIONAL (docs/15 P2-140).
@export_range(0, 10000) var treat_bleeding_wound_count: int = 0
## Cure effect (P2-T7): one unit clears the user's infection while it is
## still treatable. Up to which stage that is, is a server rule
## (SurvivalSettings.infection_treatment_max_stage), not item data.
## PROVISIONAL (docs/15 P2-146).
@export var cures_infection: bool = false


## True when using one unit has any effect (food, drink, bandage, cure).
func is_consumable() -> bool:
	return lowers_needs() or stops_bleeding() or cures_infection


## True when eating / drinking one unit lowers at least one need.
func lowers_needs() -> bool:
	return consume_hunger_reduction > 0.0 or consume_thirst_reduction > 0.0


## True when one unit stops bleeding wounds.
func stops_bleeding() -> bool:
	return treat_bleeding_wound_count > 0


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
	if treat_bleeding_wound_count < 0:
		errors.append("treat_bleeding_wound_count must be >= 0")
	return errors
