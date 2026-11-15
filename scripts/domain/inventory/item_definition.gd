class_name ItemDefinition
extends Resource
## Static item definition (docs/00 ADR-005). Instances reference it by
## `definition_id` only; Resources are never stored in saves.

@export var definition_id: String = ""
@export var display_name: String = ""
## Largest quantity one stack may hold.
@export_range(1, 10000) var max_stack: int = 1


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(definition_id):
		errors.append("definition_id '%s' must be snake_case" % definition_id)
	if max_stack < 1:
		errors.append("max_stack must be >= 1")
	return errors
