class_name MapBuildingPlan
extends RefCounted
## Turns a MapBuildingDefinition into what is placed in the world (P3-3,
## docs/09 §15.3). Pure: no world, no nodes. MapContentService places the
## result through BuildingService.place_structure and
## ContainerService.create_container.
##
## A building of w x d tiles is w * d floor pieces and one edge piece on
## every outer tile side: 2 * (w + d) of them, all walls except the one that
## is the door.

## Keys of one structure piece.
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_TILE: String = "tile"
const KEY_ROTATION: String = "rotation"
## Rotations of an edge piece that put it on a side of its tile
## (StructureGrid.SIDE_DIRECTIONS).
const SIDE_LOW_Z: int = 0
const SIDE_HIGH_X: int = 1
const SIDE_HIGH_Z: int = 2
const SIDE_LOW_X: int = 3
## Rotation of a floor piece (a direction only).
const FLOOR_ROTATION: int = 0
const SOURCE_SEPARATOR: String = "/"


## The structure pieces of a building, in placing order: the floors (x, then
## z), then the outer edges side by side (-Z, +Z, -X, +X; each from its low
## end). Each piece is {definition_id: String, tile: Vector2i, rotation: int}.
static func structure_pieces(building: MapBuildingDefinition) -> Array[Dictionary]:
	var pieces: Array[Dictionary] = []
	var origin: Vector2i = building.origin_tile
	var size: Vector2i = building.size_tiles
	for x: int in range(size.x):
		for z: int in range(size.y):
			pieces.append(_piece(building.floor_definition_id, origin + Vector2i(x, z), FLOOR_ROTATION))
	for x: int in range(size.x):
		pieces.append(_piece(_edge_definition(building, SIDE_LOW_Z, x), origin + Vector2i(x, 0), SIDE_LOW_Z))
	for x: int in range(size.x):
		pieces.append(_piece(_edge_definition(building, SIDE_HIGH_Z, x), origin + Vector2i(x, size.y - 1), SIDE_HIGH_Z))
	for z: int in range(size.y):
		pieces.append(_piece(_edge_definition(building, SIDE_LOW_X, z), origin + Vector2i(0, z), SIDE_LOW_X))
	for z: int in range(size.y):
		pieces.append(_piece(_edge_definition(building, SIDE_HIGH_X, z), origin + Vector2i(size.x - 1, z), SIDE_HIGH_X))
	return pieces


## Number of pieces structure_pieces() gives for a building of this size.
static func piece_count(size_tiles: Vector2i) -> int:
	return size_tiles.x * size_tiles.y + 2 * (size_tiles.x + size_tiles.y)


## The door piece of a building (one of structure_pieces()).
static func door_piece(building: MapBuildingDefinition) -> Dictionary:
	var along: Vector2i = Vector2i(building.door_offset, 0) if building.door_side == SIDE_LOW_Z or building.door_side == SIDE_HIGH_Z else Vector2i(0, building.door_offset)
	var far_side: Vector2i = Vector2i.ZERO
	if building.door_side == SIDE_HIGH_Z:
		far_side = Vector2i(0, building.size_tiles.y - 1)
	elif building.door_side == SIDE_HIGH_X:
		far_side = Vector2i(building.size_tiles.x - 1, 0)
	return _piece(building.door_definition_id, building.origin_tile + along + far_side, building.door_side)


## Where a container of a building stands: the centre of its tile.
static func container_position(building: MapBuildingDefinition, placement: MapContainerPlacement, grid: StructureGrid) -> Vector3:
	return grid.tile_center(building.origin_tile + placement.tile_offset)


## The source key of the container at `index` of a building: what
## ContainerService.create_container gets, so the same placement never
## becomes two containers.
static func container_source_key(map_id: String, building_id: String, index: int) -> String:
	return SOURCE_SEPARATOR.join(PackedStringArray([map_id, building_id, str(index)]))


## The tiles a building covers, as a rectangle (position = origin, size).
static func footprint(building: MapBuildingDefinition) -> Rect2i:
	return Rect2i(building.origin_tile, building.size_tiles)


static func _edge_definition(building: MapBuildingDefinition, side: int, offset: int) -> String:
	return building.door_definition_id if side == building.door_side and offset == building.door_offset else building.wall_definition_id


static func _piece(definition_id: String, tile: Vector2i, rotation: int) -> Dictionary:
	return {KEY_DEFINITION_ID: definition_id, KEY_TILE: tile, KEY_ROTATION: rotation}
