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
## More eating / drinking effects (F-1, docs/09 §14.18.1; PROVISIONAL values,
## docs/15 §21 F1-001..): fatigue taken off (coffee, energy drink) and health
## given back (cooked food), in the units of SurvivalSettings.need_max and
## max_health. They belong to eating: an item with health, a sickness chance,
## a mood change or the tremor flag must also lower a need (validate()).
@export_range(0.0, 10000.0) var consume_fatigue_reduction: float = 0.0
@export_range(0.0, 10000.0) var consume_health_restore: float = 0.0
## Chance (0..1) that eating / drinking one unit makes the eater sick (raw
## meat and fish, dirty water). Rolled with the eater's saved survival RNG;
## what sickness does is a server rule (SurvivalSettings.food_sickness_*).
## 0 = no roll: the RNG is not touched.
@export_range(0.0, 1.0) var consume_sickness_chance: float = 0.0
## Data only, NOT applied (F-1 stub, docs/15 F1-006): players have no mood
## and no aim sway yet. Alcohol carries a mood change and the hand-tremor
## flag so a later mood / aiming rule can read them from the definition.
@export_range(-100.0, 100.0) var consume_mood_change: float = 0.0
@export var consume_causes_hand_tremor: bool = false
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


## True when eating / drinking one unit lowers at least one need (hunger,
## thirst or, since F-1, fatigue).
func lowers_needs() -> bool:
	return consume_hunger_reduction > 0.0 or consume_thirst_reduction > 0.0 or consume_fatigue_reduction > 0.0


## True when eating / drinking one unit may make the eater sick (F-1).
func may_sicken() -> bool:
	return consume_sickness_chance > 0.0


## True when one unit stops bleeding wounds.
func stops_bleeding() -> bool:
	return treat_bleeding_wound_count > 0


## True when one unit treats something (bandage, cure). Treatments are what
## a player can use on another player (P2-T12, ItemConsumption.try_use_on).
func is_treatment() -> bool:
	return stops_bleeding() or cures_infection


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(definition_id):
		errors.append("definition_id '%s' must be snake_case" % definition_id)
	if max_stack < 1:
		errors.append("max_stack must be >= 1")
	for reduction: float in [consume_hunger_reduction, consume_thirst_reduction, consume_fatigue_reduction, consume_health_restore]:
		if not is_finite(reduction) or reduction < 0.0:
			errors.append("consume reductions must be finite and >= 0")
			break
	if not is_finite(consume_sickness_chance) or consume_sickness_chance < 0.0 or consume_sickness_chance > 1.0:
		errors.append("consume_sickness_chance must be within [0, 1]")
	if not is_finite(consume_mood_change):
		errors.append("consume_mood_change must be finite")
	# Health, sickness, mood and tremor are parts of eating / drinking.
	var eating_extra: bool = consume_health_restore > 0.0 or consume_sickness_chance > 0.0 or consume_mood_change != 0.0 or consume_causes_hand_tremor
	if eating_extra and not lowers_needs():
		errors.append("health, sickness, mood and tremor effects need an eating / drinking effect (hunger, thirst or fatigue)")
	if treat_bleeding_wound_count < 0:
		errors.append("treat_bleeding_wound_count must be >= 0")
	return errors
