class_name MapContainerPlacement
extends Resource
## One container inside a building of the map content (P3-3, docs/09 §15.3
## "맵 정의 형식"). Part of a MapBuildingDefinition.

## ContainerDefinition.definition_id.
@export var definition_id: String = ""
## The tile of the building it stands on, counted from the building's
## `origin_tile` (0 .. size - 1 on both axes). It stands at the centre of
## that tile; one container per tile.
@export var tile_offset: Vector2i = Vector2i.ZERO
## The loot table of this container. "" = the building's `loot_table_id`,
## and when that is empty too the container definition's own.
@export var loot_table_id: String = ""
