class_name MapBuildingDefinition
extends Resource
## One building of the map content (P3-3, docs/03 §6, docs/13 §11, docs/09
## §15.3 "맵 정의 형식"): a rectangle of floor tiles with a wall on every outer
## edge, one door in one of those edges, and containers inside. Pure data: it
## names structure and container definitions and whole tiles of the building
## grid (StructureGrid). MapBuildingPlan turns it into the pieces to place.
## Part of a MapContentDefinition.

## Stable snake_case id, unique in its map. Recorded in the world save when
## the building was placed: never rename it.
@export var building_id: String = ""
## What kind of building it is (house, store, clinic, ...). A label for
## people and logs; the loot is decided by `loot_table_id`.
@export var building_type: String = ""
## The tile with the smallest x and z of the building.
@export var origin_tile: Vector2i = Vector2i.ZERO
## Width (x) and depth (z) in tiles.
@export var size_tiles: Vector2i = Vector2i(4, 4)
## StructureDefinition ids of the floor (a tile piece), the walls (edge
## pieces that block movement) and the door (an edge piece that is a door).
@export var floor_definition_id: String = "dev_floor"
@export var wall_definition_id: String = "dev_wall"
@export var door_definition_id: String = "dev_door"
## Which outer side the door is in, as the rotation of an edge piece
## (StructureGrid.SIDE_DIRECTIONS): 0 = -Z, 1 = +X, 2 = +Z, 3 = -X.
@export_range(0, 3) var door_side: int = 2
## Which tile along that side, counted from the low end (0 .. length - 1).
@export_range(0, 10000) var door_offset: int = 0
## The loot table of the containers in this building (docs/03 §6: tables per
## building type). "" = each container definition's own table.
@export var loot_table_id: String = ""
@export var containers: Array[MapContainerPlacement] = []


## Number of tiles along the side the door is in.
func door_side_length() -> int:
	return size_tiles.x if door_side == 0 or door_side == 2 else size_tiles.y


## The loot table a container placement of this building gets ("" = the
## container definition decides).
func loot_table_of(placement: MapContainerPlacement) -> String:
	return placement.loot_table_id if not placement.loot_table_id.is_empty() else loot_table_id


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(building_id):
		errors.append("building_id '%s' must be snake_case" % building_id)
	if size_tiles.x < 1 or size_tiles.y < 1:
		errors.append("building %s: size_tiles must be at least 1 x 1" % building_id)
		return errors
	if not StructureGrid.is_valid_rotation(door_side):
		errors.append("building %s: door_side must be 0..3" % building_id)
	elif door_offset < 0 or door_offset >= door_side_length():
		errors.append("building %s: door_offset must be inside the door's side" % building_id)
	for definition_id: String in [floor_definition_id, wall_definition_id, door_definition_id]:
		if not ItemInstance.is_valid_definition_id(definition_id):
			errors.append("building %s: floor, wall and door must name structure definitions" % building_id)
			break
	var taken: Dictionary[Vector2i, bool] = {}
	for placement: MapContainerPlacement in containers:
		if placement == null or not ItemInstance.is_valid_definition_id(placement.definition_id):
			errors.append("building %s: a container names no definition" % building_id)
			continue
		var offset: Vector2i = placement.tile_offset
		if offset.x < 0 or offset.y < 0 or offset.x >= size_tiles.x or offset.y >= size_tiles.y:
			errors.append("building %s: container %s stands outside the building" % [building_id, placement.definition_id])
		elif taken.has(offset):
			errors.append("building %s: two containers on tile %s" % [building_id, str(offset)])
		taken[offset] = true
	return errors
