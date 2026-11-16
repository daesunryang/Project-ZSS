class_name MapContentDefinition
extends Resource
## What stands on a map before anybody played on it (P3-3, docs/03 §6,
## docs/13 §5 "500m × 500m 테스트 맵", §11 "건물 5~10개", docs/09 §15.3 "맵 정의
## 형식"): buildings made of structure pieces, with containers inside. Data
## only (a `.tres` in `res://resources/definitions/maps/`); MapContentService
## places it in a world exactly once.
##
## A world records which map content it was seeded with (`map_id`,
## `content_version` and the buildings that were placed). Content that
## changes after a world was seeded is NOT placed again in that world
## (PROVISIONAL, docs/15 P3-079).

## The map content a dedicated server seeds its world with.
const DEFAULT_PATH: String = "res://resources/definitions/maps/dev_test_map.tres"

## Stable snake_case id. Recorded in the world save: never rename it.
@export var map_id: String = ""
## Raised when the content changes (recorded with the world; see the header).
@export_range(1, 1000000) var content_version: int = 1
## How many world cells the seeding brings into memory before it saves and
## releases them again. The whole map is never in memory at once.
@export_range(1, 100000) var seeding_batch_cells: int = 16
@export var buildings: Array[MapBuildingDefinition] = []


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(map_id):
		errors.append("map_id '%s' must be snake_case" % map_id)
	if content_version < 1:
		errors.append("map %s: content_version must be >= 1" % map_id)
	if seeding_batch_cells < 1:
		errors.append("map %s: seeding_batch_cells must be >= 1" % map_id)
	var seen: Dictionary[String, bool] = {}
	var footprints: Array[Rect2i] = []
	for building: MapBuildingDefinition in buildings:
		if building == null:
			errors.append("map %s: a building entry is empty" % map_id)
			continue
		errors.append_array(building.validate())
		if seen.has(building.building_id):
			errors.append("map %s: duplicate building_id %s" % [map_id, building.building_id])
		seen[building.building_id] = true
		# One tile of room on every side: two buildings never share an edge
		# (a wall of the one would take the slot of a wall of the other).
		var footprint: Rect2i = MapBuildingPlan.footprint(building)
		for other: Rect2i in footprints:
			if footprint.grow(1).intersects(other):
				errors.append("map %s: building %s overlaps or touches another building" % [map_id, building.building_id])
				break
		footprints.append(footprint)
	return errors


## Errors of the content against the definitions and the world it is placed
## in: every piece names a structure definition of the right kind, every
## container a container definition and a loot table that exist, and every
## tile lies inside the play area.
func validate_against(structures: StructureCatalog, container_definitions: ContainerCatalog, loot_tables: LootTableCatalog, grid: StructureGrid, world_half_extent_m: float) -> PackedStringArray:
	var errors: PackedStringArray = []
	for building: MapBuildingDefinition in buildings:
		if building == null:
			continue
		var label: String = "map %s: building %s" % [map_id, building.building_id]
		var floor_definition: StructureDefinition = structures.get_definition(building.floor_definition_id)
		var wall_definition: StructureDefinition = structures.get_definition(building.wall_definition_id)
		var door_definition: StructureDefinition = structures.get_definition(building.door_definition_id)
		if floor_definition == null or floor_definition.is_edge():
			errors.append("%s: floor %s must be a tile piece" % [label, building.floor_definition_id])
		if wall_definition == null or not wall_definition.is_edge() or not wall_definition.blocks_movement or wall_definition.is_door:
			errors.append("%s: wall %s must be an edge piece that blocks movement" % [label, building.wall_definition_id])
		if door_definition == null or not door_definition.is_door:
			errors.append("%s: door %s must be a door" % [label, building.door_definition_id])
		var footprint: Rect2i = MapBuildingPlan.footprint(building)
		if not grid.is_tile_inside(footprint.position, world_half_extent_m) or not grid.is_tile_inside(footprint.end - Vector2i.ONE, world_half_extent_m):
			errors.append("%s: lies outside the play area" % label)
		for placement: MapContainerPlacement in building.containers:
			if placement == null:
				continue
			var definition: ContainerDefinition = container_definitions.get_definition(placement.definition_id)
			if definition == null:
				errors.append("%s: unknown container %s" % [label, placement.definition_id])
				continue
			var table_id: String = building.loot_table_of(placement)
			if not table_id.is_empty() and not loot_tables.has(table_id):
				errors.append("%s: unknown loot table %s" % [label, table_id])
	return errors


## Number of structure pieces and containers of the whole content.
func piece_count() -> int:
	var total: int = 0
	for building: MapBuildingDefinition in buildings:
		total += MapBuildingPlan.piece_count(building.size_tiles)
	return total


func container_count() -> int:
	var total: int = 0
	for building: MapBuildingDefinition in buildings:
		total += building.containers.size()
	return total


## The map content at `path`, or null (logged) when there is none.
static func load_or_null(path: String = DEFAULT_PATH) -> MapContentDefinition:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is MapContentDefinition:
		return loaded as MapContentDefinition
	GameLogger.warning("config", "map content missing; the world gets no buildings", {"path": path, "operation": "load_settings"})
	return null
