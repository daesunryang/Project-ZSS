class_name NpcHomeLayout
extends RefCounted
## What an NPC uses in a building it lives in, derived from the building
## itself (F-28, docs/09 §17.13): where it stands at home, its bed, its
## water, and the containers its food is in. Pure: the same building gives
## the same layout, so nobody writes spots for thousands of generated
## buildings by hand and nothing of this is saved.
##
## The rules (all tiles are inside the building; a tile a container stands
## on and the tile behind the outer door are never a bed, water or home
## tile):
##   bed    the free tile along the outer wall that is farthest from the
##          outer door;
##   water  the free tile along the outer wall that is nearest to the outer
##          door (not the bed);
##   home   the free tile nearest to the middle of the building (not the
##          bed, not the water): where the NPC is placed, the centre of its
##          wandering, and where it sleeps without a bed;
##   food   every container of the building, on the container's own tile.
## Ties go to the smaller x, then the smaller z. A building too small for a
## bed, water and a home tile has no layout (is_valid() false).
##
## The spots have ids made from the building id: "<building>_bed",
## "<building>_water", "<building>_food_<container index>". spot() gives
## the NpcSpotDefinition of one.

const SUFFIX_BED: String = "bed"
const SUFFIX_WATER: String = "water"
const SUFFIX_FOOD: String = "food"
const SEPARATOR: String = "_"
const NO_TILE: Vector2i = Vector2i(-1, -1)

var building_id: String = ""
var building_type: String = ""
## The building's first tile and its size, in tiles of the world grid.
var origin_tile: Vector2i = Vector2i.ZERO
var size_tiles: Vector2i = Vector2i.ZERO
## Tiles counted from origin_tile.
var home_offset: Vector2i = NO_TILE
var bed_offset: Vector2i = NO_TILE
var water_offset: Vector2i = NO_TILE
## One per container of the building, in the order of its placements.
var food_offsets: Array[Vector2i] = []


## The layout of a building (never null; see is_valid()).
static func of(building: MapBuildingDefinition) -> NpcHomeLayout:
	var layout: NpcHomeLayout = NpcHomeLayout.new()
	if building == null:
		return layout
	layout.building_id = building.building_id
	layout.building_type = building.building_type
	layout.origin_tile = building.origin_tile
	layout.size_tiles = building.size_tiles
	var taken: Dictionary[Vector2i, bool] = {}
	for placement: MapContainerPlacement in building.containers:
		if placement != null:
			layout.food_offsets.append(placement.tile_offset)
			taken[placement.tile_offset] = true
	var door: Vector2i = (MapBuildingPlan.door_piece(building)[MapBuildingPlan.KEY_TILE] as Vector2i) - building.origin_tile
	taken[door] = true
	var size: Vector2i = building.size_tiles
	# Twice the middle, so it stays a whole number.
	var middle2: Vector2i = size - Vector2i.ONE
	var bed_distance: int = -1
	for x: int in range(size.x):
		for z: int in range(size.y):
			var offset: Vector2i = Vector2i(x, z)
			if taken.has(offset) or not _is_along_wall(offset, size):
				continue
			var distance: int = (offset - door).length_squared()
			if distance > bed_distance:
				bed_distance = distance
				layout.bed_offset = offset
	if layout.bed_offset == NO_TILE:
		return layout
	taken[layout.bed_offset] = true
	var water_distance: int = -1
	for x: int in range(size.x):
		for z: int in range(size.y):
			var offset: Vector2i = Vector2i(x, z)
			if taken.has(offset) or not _is_along_wall(offset, size):
				continue
			var distance: int = (offset - door).length_squared()
			if water_distance < 0 or distance < water_distance:
				water_distance = distance
				layout.water_offset = offset
	if layout.water_offset == NO_TILE:
		return layout
	taken[layout.water_offset] = true
	var home_distance: int = -1
	for x: int in range(size.x):
		for z: int in range(size.y):
			var offset: Vector2i = Vector2i(x, z)
			if taken.has(offset):
				continue
			var distance: int = (offset * 2 - middle2).length_squared()
			if home_distance < 0 or distance < home_distance:
				home_distance = distance
				layout.home_offset = offset
	return layout


## True when the building has a home tile, a bed and water.
func is_valid() -> bool:
	return home_offset != NO_TILE and bed_offset != NO_TILE and water_offset != NO_TILE


func home_tile() -> Vector2i:
	return origin_tile + home_offset


func bed_spot_id() -> String:
	return building_id + SEPARATOR + SUFFIX_BED


func water_spot_id() -> String:
	return building_id + SEPARATOR + SUFFIX_WATER


func food_spot_id(container_index: int) -> String:
	return building_id + SEPARATOR + SUFFIX_FOOD + SEPARATOR + str(container_index)


## The spot ids of one kind (NpcSpotDefinition.KIND_*; "" = every kind),
## sorted. A layout that is not valid has none. No work spot: nobody works
## in a home.
func spot_ids(kind: String = "") -> PackedStringArray:
	var ids: PackedStringArray = []
	if not is_valid():
		return ids
	if kind.is_empty() or kind == NpcSpotDefinition.KIND_BED:
		ids.append(bed_spot_id())
	if kind.is_empty() or kind == NpcSpotDefinition.KIND_WATER:
		ids.append(water_spot_id())
	if kind.is_empty() or kind == NpcSpotDefinition.KIND_FOOD:
		for index: int in range(food_offsets.size()):
			ids.append(food_spot_id(index))
	ids.sort()
	return ids


## The definition of one of this layout's spots, or null. A bed and the
## water are for one NPC at a time; a food container is not.
func spot(spot_id: String) -> NpcSpotDefinition:
	if not is_valid() or not spot_id.begins_with(building_id + SEPARATOR):
		return null
	var suffix: String = spot_id.substr(building_id.length() + 1)
	var made: NpcSpotDefinition = NpcSpotDefinition.new()
	made.spot_id = spot_id
	made.building_id = building_id
	if suffix == SUFFIX_BED:
		made.kind = NpcSpotDefinition.KIND_BED
		made.tile_offset = bed_offset
	elif suffix == SUFFIX_WATER:
		made.kind = NpcSpotDefinition.KIND_WATER
		made.tile_offset = water_offset
	elif suffix.begins_with(SUFFIX_FOOD + SEPARATOR) and suffix.substr(SUFFIX_FOOD.length() + 1).is_valid_int():
		var index: int = suffix.substr(SUFFIX_FOOD.length() + 1).to_int()
		if index < 0 or index >= food_offsets.size() or food_spot_id(index) != spot_id:
			return null
		made.kind = NpcSpotDefinition.KIND_FOOD
		made.tile_offset = food_offsets[index]
		made.exclusive = false
	else:
		return null
	return made


## The building id a generated spot id names ("" = it is not the id of a
## spot of a layout): everything before "_bed", "_water" or "_food_<n>".
static func building_id_of_spot(spot_id: String) -> String:
	for suffix: String in [SUFFIX_BED, SUFFIX_WATER]:
		if spot_id.ends_with(SEPARATOR + suffix):
			return spot_id.substr(0, spot_id.length() - suffix.length() - 1)
	var at: int = spot_id.rfind(SEPARATOR + SUFFIX_FOOD + SEPARATOR)
	return spot_id.substr(0, at) if at > 0 else ""


static func _is_along_wall(offset: Vector2i, size: Vector2i) -> bool:
	return offset.x == 0 or offset.y == 0 or offset.x == size.x - 1 or offset.y == size.y - 1
