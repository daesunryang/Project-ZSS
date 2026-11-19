class_name NpcSpotSet
extends Resource
## The NPC spots of one map (P4-5a, docs/13 §16.3 D7, docs/09 §17.7): beds,
## work places, water points and food containers, as data beside the map
## content (`res://resources/definitions/npc_spots/`). Nothing is placed in
## the world for a spot: it is a named tile. The executor (NpcExecutor)
## walks NPCs to spots and keeps the reservations.

## The spots a dedicated server uses (the dev test map).
const DEFAULT_PATH: String = "res://resources/definitions/npc_spots/dev_test_map_spots.tres"

## Stable snake_case id.
@export var spot_set_id: String = ""
## MapContentDefinition.map_id of the map these spots belong to. A world
## with another map (or none) uses none of the spots that name a building.
@export var map_id: String = ""
@export var spots: Array[NpcSpotDefinition] = []

var _by_id: Dictionary[String, NpcSpotDefinition] = {}
var _indexed_count: int = -1


func get_spot(spot_id: String) -> NpcSpotDefinition:
	_index()
	return _by_id.get(spot_id, null)


func has_spot(spot_id: String) -> bool:
	_index()
	return _by_id.has(spot_id)


## Every spot id, sorted. `kind` and `building_id` narrow the list ("" =
## any).
func spot_ids(kind: String = "", building_id: String = "") -> PackedStringArray:
	_index()
	var ids: PackedStringArray = []
	for spot_id: String in _by_id:
		var spot: NpcSpotDefinition = _by_id[spot_id]
		if (kind.is_empty() or spot.kind == kind) and (building_id.is_empty() or spot.building_id == building_id):
			ids.append(spot_id)
	ids.sort()
	return ids


## The world tile of a spot, or null: the spot names a building that
## `map_content` does not have (also when there is no map content).
func tile_of(spot: NpcSpotDefinition, map_content: MapContentDefinition) -> Variant:
	if spot == null:
		return null
	if spot.building_id.is_empty():
		return spot.tile_offset
	if map_content == null or map_content.map_id != map_id:
		return null
	var building: MapBuildingDefinition = NpcRoster.building_of(map_content, spot.building_id)
	return building.origin_tile + spot.tile_offset if building != null else null


## Where an NPC stands to use each spot: {spot_id: Vector3}, only the spots
## that have a place in this world (see tile_of).
func positions(map_content: MapContentDefinition, grid: StructureGrid) -> Dictionary[String, Vector3]:
	var result: Dictionary[String, Vector3] = {}
	for spot: NpcSpotDefinition in spots:
		var tile: Variant = tile_of(spot, map_content)
		if spot != null and tile != null and grid != null:
			result[spot.spot_id] = grid.tile_center(tile as Vector2i)
	return result


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(spot_set_id):
		errors.append("spot_set_id '%s' must be snake_case" % spot_set_id)
	if not map_id.is_empty() and not ItemInstance.is_valid_definition_id(map_id):
		errors.append("spot set %s: map_id '%s' must be snake_case" % [spot_set_id, map_id])
	var seen: Dictionary[String, bool] = {}
	# Two exclusive spots on one tile would be one place with two names.
	var taken: Dictionary[String, String] = {}
	for spot: NpcSpotDefinition in spots:
		if spot == null:
			errors.append("spot set %s: a spot entry is empty" % spot_set_id)
			continue
		for message: String in spot.validate():
			errors.append("spot set %s: %s" % [spot_set_id, message])
		if seen.has(spot.spot_id):
			errors.append("spot set %s: duplicate spot_id %s" % [spot_set_id, spot.spot_id])
		seen[spot.spot_id] = true
		if spot.exclusive:
			var place: String = "%s|%d|%d" % [spot.building_id, spot.tile_offset.x, spot.tile_offset.y]
			if taken.has(place):
				errors.append("spot set %s: %s and %s are the same tile" % [spot_set_id, taken[place], spot.spot_id])
			taken[place] = spot.spot_id
		if not spot.building_id.is_empty() and map_id.is_empty():
			errors.append("spot set %s: %s names a building but the set names no map" % [spot_set_id, spot.spot_id])
	return errors


## Errors of the spots against the map they belong to: every building
## exists, every tile lies inside its building (or, outdoors, inside the
## play area), and a food spot is the tile of a container of its building.
## A set of another map is not checked (it is not used).
func validate_against(map_content: MapContentDefinition, grid: StructureGrid, world_half_extent_m: float) -> PackedStringArray:
	var errors: PackedStringArray = []
	for spot: NpcSpotDefinition in spots:
		if spot == null:
			continue
		var label: String = "spot set %s: %s" % [spot_set_id, spot.spot_id]
		if spot.building_id.is_empty():
			if grid != null and not grid.is_tile_inside(spot.tile_offset, world_half_extent_m):
				errors.append("%s: lies outside the play area" % label)
			if spot.kind == NpcSpotDefinition.KIND_FOOD:
				errors.append("%s: a food spot must be a container of a building" % label)
			continue
		if map_content == null or map_content.map_id != map_id:
			continue
		var building: MapBuildingDefinition = NpcRoster.building_of(map_content, spot.building_id)
		if building == null:
			errors.append("%s: names the unknown building %s" % [label, spot.building_id])
			continue
		var offset: Vector2i = spot.tile_offset
		if offset.x < 0 or offset.y < 0 or offset.x >= building.size_tiles.x or offset.y >= building.size_tiles.y:
			errors.append("%s: %s lies outside the building %s" % [label, str(offset), spot.building_id])
			continue
		var on_container: bool = false
		for placement: MapContainerPlacement in building.containers:
			on_container = on_container or (placement != null and placement.tile_offset == offset)
		if spot.kind == NpcSpotDefinition.KIND_FOOD and not on_container:
			errors.append("%s: no container stands on that tile" % label)
		elif spot.kind != NpcSpotDefinition.KIND_FOOD and on_container:
			errors.append("%s: %s is the tile of a container of %s" % [label, str(offset), spot.building_id])
	return errors


## The spot set at `path`, or null (logged) when there is none.
static func load_or_null(path: String = DEFAULT_PATH) -> NpcSpotSet:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcSpotSet:
		return loaded as NpcSpotSet
	GameLogger.warning("config", "npc spots missing; NPCs have no beds, work places or water", {"path": path, "operation": "load_settings"})
	return null


func _index() -> void:
	if _indexed_count == spots.size():
		return
	_by_id.clear()
	for spot: NpcSpotDefinition in spots:
		if spot != null:
			_by_id[spot.spot_id] = spot
	_indexed_count = spots.size()
