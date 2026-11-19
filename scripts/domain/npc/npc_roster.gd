class_name NpcRoster
extends Resource
## Who lives in a world before anybody played in it (P4-1, docs/13 §16.3 D1
## and D5, docs/09 §17.1): a list of NpcDefinition ids for one map. Data
## only (a `.tres` in `res://resources/definitions/npcs/rosters/`);
## NpcService places every NPC of the roster on its home spot exactly once
## per world and records that in the world save.
##
## A world records which roster it was given (`roster_id`,
## `content_version` and the NPC id of every definition). A roster that
## changes after a world got it is NOT placed again in that world
## (PROVISIONAL, docs/15 P4-006).

## The roster a dedicated server gives its world.
const DEFAULT_PATH: String = "res://resources/definitions/npcs/rosters/dev_npc_roster.tres"

## Stable snake_case id. Recorded in the world save: never rename it.
@export var roster_id: String = ""
## Raised when the roster changes (recorded with the world; see the header).
@export_range(1, 1000000) var content_version: int = 1
## The map content whose buildings the home and work spots of the NPCs name
## (MapContentDefinition.map_id).
@export var map_id: String = ""
## NpcDefinition ids, in placing order. One NPC per entry.
@export var npc_definition_ids: PackedStringArray = []


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(roster_id):
		errors.append("roster_id '%s' must be snake_case" % roster_id)
	if content_version < 1:
		errors.append("roster %s: content_version must be >= 1" % roster_id)
	if not ItemInstance.is_valid_definition_id(map_id):
		errors.append("roster %s: map_id '%s' must be snake_case" % [roster_id, map_id])
	var seen: Dictionary[String, bool] = {}
	for definition_id: String in npc_definition_ids:
		if seen.has(definition_id):
			errors.append("roster %s: %s is listed twice" % [roster_id, definition_id])
		seen[definition_id] = true
	return errors


## Errors of the roster against the definitions, the map it is placed in
## and the population limit: every entry names a definition, every home spot
## (and every work spot that is given) is a free tile inside a building of
## the map, and no two NPCs share a home spot.
func validate_against(definitions: NpcCatalog, map_content: MapContentDefinition, grid: StructureGrid, max_npcs: int) -> PackedStringArray:
	var errors: PackedStringArray = []
	if map_content == null:
		errors.append("roster %s: needs the map content %s" % [roster_id, map_id])
		return errors
	if map_content.map_id != map_id:
		errors.append("roster %s: is for the map content %s, not %s" % [roster_id, map_id, map_content.map_id])
		return errors
	if npc_definition_ids.size() > max_npcs:
		errors.append("roster %s: %d NPCs are more than max_npcs (%d)" % [roster_id, npc_definition_ids.size(), max_npcs])
	var homes: Dictionary[Vector2i, String] = {}
	for definition_id: String in npc_definition_ids:
		var definition: NpcDefinition = definitions.get_definition(definition_id) if definitions != null else null
		if definition == null:
			errors.append("roster %s: unknown npc definition %s" % [roster_id, definition_id])
			continue
		if definition.home_building_id.is_empty():
			errors.append("roster %s: %s has no home spot" % [roster_id, definition_id])
			continue
		var home_error: String = spot_error(map_content, definition.home_building_id, definition.home_tile_offset)
		if not home_error.is_empty():
			errors.append("roster %s: %s: home spot %s" % [roster_id, definition_id, home_error])
			continue
		var home_tile: Vector2i = building_of(map_content, definition.home_building_id).origin_tile + definition.home_tile_offset
		if homes.has(home_tile):
			errors.append("roster %s: %s and %s have the same home spot" % [roster_id, homes[home_tile], definition_id])
		homes[home_tile] = definition_id
		if not definition.work_building_id.is_empty():
			var work_error: String = spot_error(map_content, definition.work_building_id, definition.work_tile_offset)
			if not work_error.is_empty():
				errors.append("roster %s: %s: work spot %s" % [roster_id, definition_id, work_error])
	# The spots must also be positions of this world's building grid.
	if grid == null:
		errors.append("roster %s: needs the building grid" % roster_id)
	return errors


## The building of a map content with this id, or null.
static func building_of(map_content: MapContentDefinition, building_id: String) -> MapBuildingDefinition:
	if map_content == null:
		return null
	for building: MapBuildingDefinition in map_content.buildings:
		if building != null and building.building_id == building_id:
			return building
	return null


## "" when `tile_offset` is a tile inside the building `building_id` of the
## map that no container of the map stands on; otherwise what is wrong.
static func spot_error(map_content: MapContentDefinition, building_id: String, tile_offset: Vector2i) -> String:
	var building: MapBuildingDefinition = building_of(map_content, building_id)
	if building == null:
		return "names the unknown building %s" % building_id
	if not _is_inside(building, tile_offset):
		return "%s lies outside the building %s" % [str(tile_offset), building_id]
	for placement: MapContainerPlacement in building.containers:
		if placement != null and placement.tile_offset == tile_offset:
			return "%s is the tile of a container of %s" % [str(tile_offset), building_id]
	return ""


## World position of a spot: the centre of the tile `tile_offset` of the
## building `building_id`. null when the map has no such building or the
## tile lies outside it.
static func spot_position(map_content: MapContentDefinition, grid: StructureGrid, building_id: String, tile_offset: Vector2i) -> Variant:
	var building: MapBuildingDefinition = building_of(map_content, building_id)
	if building == null or grid == null or not _is_inside(building, tile_offset):
		return null
	return grid.tile_center(building.origin_tile + tile_offset)


## The roster at `path`, or null (logged) when there is none.
static func load_or_null(path: String = DEFAULT_PATH) -> NpcRoster:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcRoster:
		return loaded as NpcRoster
	GameLogger.warning("config", "npc roster missing; the world gets no NPCs", {"path": path, "operation": "load_settings"})
	return null


static func _is_inside(building: MapBuildingDefinition, tile_offset: Vector2i) -> bool:
	return tile_offset.x >= 0 and tile_offset.y >= 0 and tile_offset.x < building.size_tiles.x and tile_offset.y < building.size_tiles.y
