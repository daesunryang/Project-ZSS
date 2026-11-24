class_name ProceduralBuilding
extends RefCounted
## One building of the generated map (F-33, docs/09 §15.3.1): the outer
## shell and the containers as a MapBuildingDefinition (so MapBuildingPlan
## and everything that reads map buildings works on it), plus the interior
## walls and doors that cut it into rooms. Made by ProceduralMapGenerator;
## pure data.

## Keys of summary().
const KEY_BUILDING_ID: String = "building_id"
const KEY_ARCHETYPE_ID: String = "archetype_id"
const KEY_BUILDING_TYPE: String = "building_type"
const KEY_ORIGIN: String = "origin"
const KEY_SIZE: String = "size"
const KEY_DOOR_SIDE: String = "door_side"
const KEY_DOOR_OFFSET: String = "door_offset"
const KEY_LOOT_TABLE_ID: String = "loot_table_id"
const KEY_CONTAINERS: String = "containers"
const KEY_INTERIOR: String = "interior"

## The cell the whole building lies in.
var cell: Vector2i = Vector2i.ZERO
var archetype_id: String = ""
## Outer shell (floors, outer walls, one outer door) and containers.
var definition: MapBuildingDefinition = null
## Interior edge pieces ({definition_id, tile, rotation}, MapBuildingPlan
## keys): walls and one door per interior wall.
var interior_pieces: Array[Dictionary] = []


func building_id() -> String:
	return definition.building_id if definition != null else ""


## The tiles the building covers.
func footprint() -> Rect2i:
	return MapBuildingPlan.footprint(definition)


## Every structure piece in placing order: the floors (when wanted), the
## outer edges, then the interior edges.
func pieces(place_floors: bool = true) -> Array[Dictionary]:
	var all: Array[Dictionary] = []
	for piece: Dictionary in MapBuildingPlan.structure_pieces(definition):
		if place_floors or str(piece[MapBuildingPlan.KEY_DEFINITION_ID]) != definition.floor_definition_id:
			all.append(piece)
	all.append_array(interior_pieces)
	return all


## Number of interior doors.
func interior_door_count() -> int:
	var doors: int = 0
	for piece: Dictionary in interior_pieces:
		if str(piece[MapBuildingPlan.KEY_DEFINITION_ID]) == definition.door_definition_id:
			doors += 1
	return doors


## Everything that decides what is placed, JSON-safe: two buildings with
## the same summary are the same building.
func summary() -> Dictionary:
	var containers: Array = []
	for placement: MapContainerPlacement in definition.containers:
		containers.append([placement.definition_id, placement.tile_offset.x, placement.tile_offset.y])
	var interior: Array = []
	for piece: Dictionary in interior_pieces:
		var tile: Vector2i = piece[MapBuildingPlan.KEY_TILE]
		interior.append([str(piece[MapBuildingPlan.KEY_DEFINITION_ID]), tile.x, tile.y, int(piece[MapBuildingPlan.KEY_ROTATION])])
	return {
		KEY_BUILDING_ID: definition.building_id,
		KEY_ARCHETYPE_ID: archetype_id,
		KEY_BUILDING_TYPE: definition.building_type,
		KEY_ORIGIN: [definition.origin_tile.x, definition.origin_tile.y],
		KEY_SIZE: [definition.size_tiles.x, definition.size_tiles.y],
		KEY_DOOR_SIDE: definition.door_side,
		KEY_DOOR_OFFSET: definition.door_offset,
		KEY_LOOT_TABLE_ID: definition.loot_table_id,
		KEY_CONTAINERS: containers,
		KEY_INTERIOR: interior,
	}
