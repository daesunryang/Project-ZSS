class_name ProceduralBuildingArchetype
extends Resource
## One kind of building the procedural map makes (F-33, docs/09 §15.3.1): a
## size range, the loot table and the containers of its type, and how often
## it is cut into rooms. Data only; ProceduralMapGenerator turns it into
## buildings. Part of ProceduralMapSettings.

## Where an archetype is used.
enum Zone { RESIDENTIAL = 0, COMMERCIAL = 1, RURAL = 2 }

## Smallest side of a building: a tile in the middle and one on each side.
const MIN_SIDE_TILES: int = 3
## Smallest room an interior wall may leave.
const MIN_ROOM_SPAN_TILES: int = 2

## Stable snake_case id, unique in the settings.
@export var archetype_id: String = ""
## MapBuildingDefinition.building_type of the buildings it makes.
@export var building_type: String = "house"
@export_enum("residential", "commercial", "rural") var zone: int = Zone.RESIDENTIAL
## How often it is chosen among the archetypes of its zone that fit a lot.
@export_range(1, 1000) var weight: int = 10
## Smallest and largest size in tiles: x = the long side, y = the short side.
## Which world axis the long side lies on is rolled per building.
@export var min_size_tiles: Vector2i = Vector2i(5, 4)
@export var max_size_tiles: Vector2i = Vector2i(7, 6)
## An interior wall with one door cuts the long side into rooms of about
## this many tiles (0 = one room).
@export_range(0, 1000) var room_span_tiles: int = 0
## The most interior walls one building gets.
@export_range(0, 16) var max_partitions: int = 2
## Loot table of its containers (LootTableDefinition.table_id).
@export var loot_table_id: String = ""
## Container definitions its containers are chosen from.
@export var container_definition_ids: PackedStringArray = []
@export_range(0, 64) var min_containers: int = 1
@export_range(0, 64) var max_containers: int = 2
@export var floor_definition_id: String = "dev_floor"
@export var wall_definition_id: String = "dev_wall"
@export var door_definition_id: String = "dev_door"


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	var label: String = "procedural archetype %s" % archetype_id
	if not ItemInstance.is_valid_definition_id(archetype_id):
		errors.append("procedural archetype_id '%s' must be snake_case" % archetype_id)
	if building_type.is_empty():
		errors.append("%s: building_type must not be empty" % label)
	if zone < Zone.RESIDENTIAL or zone > Zone.RURAL:
		errors.append("%s: zone must be residential, commercial or rural" % label)
	if weight < 1:
		errors.append("%s: weight must be >= 1" % label)
	if min_size_tiles.x < MIN_SIDE_TILES or min_size_tiles.y < MIN_SIDE_TILES:
		errors.append("%s: min_size_tiles must be at least %d x %d" % [label, MIN_SIDE_TILES, MIN_SIDE_TILES])
	if min_size_tiles.y > min_size_tiles.x or max_size_tiles.y > max_size_tiles.x:
		errors.append("%s: sizes are (long side, short side)" % label)
	if max_size_tiles.x < min_size_tiles.x or max_size_tiles.y < min_size_tiles.y:
		errors.append("%s: max_size_tiles must be >= min_size_tiles" % label)
	if room_span_tiles != 0 and room_span_tiles < MIN_ROOM_SPAN_TILES:
		errors.append("%s: room_span_tiles must be 0 or >= %d" % [label, MIN_ROOM_SPAN_TILES])
	if max_partitions < 0:
		errors.append("%s: max_partitions must be >= 0" % label)
	if min_containers < 0 or max_containers < min_containers:
		errors.append("%s: container counts must be 0 <= min <= max" % label)
	if max_containers > 0 and container_definition_ids.is_empty():
		errors.append("%s: containers need container_definition_ids" % label)
	if max_containers > wall_tile_count(min_size_tiles) - 1:
		errors.append("%s: more containers than wall tiles of its smallest size" % label)
	for definition_id: String in [floor_definition_id, wall_definition_id, door_definition_id]:
		if not ItemInstance.is_valid_definition_id(definition_id):
			errors.append("%s: floor, wall and door must name structure definitions" % label)
			break
	return errors


## Number of tiles of a building that touch its outer wall.
static func wall_tile_count(size: Vector2i) -> int:
	if size.x <= 2 or size.y <= 2:
		return size.x * size.y
	return 2 * (size.x + size.y) - 4
