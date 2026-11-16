class_name ContainerDefinition
extends Resource
## Static definition of a container: a thing standing in the world that
## holds items (a crate, a cabinet; P3-3, docs/00 ADR-005, ADR-026, docs/09
## §15.3). Instances (ContainerInstance) reference it by `definition_id`
## only; Resources are never stored in saves. One `.tres` per definition in
## `res://resources/definitions/containers/`, loaded by ContainerCatalog.

## Stable snake_case id. Saved and sent over the network: never rename it.
@export var definition_id: String = ""
## Text shown above the container and in the HUD.
@export var display_name: String = ""
## Number of item stacks the container holds.
@export_range(1, 1000) var slot_count: int = 12
## The loot table a container of this kind is filled from when it is searched
## for the first time (LootTable.table_id). "" = nothing is ever found in it
## by itself (a storage box players fill). Whoever places a container may
## name another table (the map content does, per building).
@export var loot_table_id: String = ""


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(definition_id):
		errors.append("container definition_id '%s' must be snake_case" % definition_id)
	if slot_count < 1:
		errors.append("container %s: slot_count must be >= 1" % definition_id)
	if not loot_table_id.is_empty() and not ItemInstance.is_valid_definition_id(loot_table_id):
		errors.append("container %s: loot_table_id '%s' must be snake_case or empty" % [definition_id, loot_table_id])
	return errors
