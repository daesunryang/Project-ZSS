class_name MapContentService
extends ServerSystem
## Places the map content (MapContentDefinition: buildings and the
## containers inside them) in a world, exactly once (P3-3, docs/03 §6,
## docs/00 ADR-026, docs/09 §15.3). System id "map_content".
##
## Every building is placed through the server rules of the systems that own
## the entities: BuildingService.place_structure for floors, walls and the
## door, at once followed by BuildingService.complete_structure (since P3-5
## a placed piece is a blueprint; a map building stands completed, needs no
## materials and, having none delivered, refunds nothing), and
## ContainerService.create_container for the containers. This system owns
## no entity; it only remembers what it placed.
##
## Once per world: the world save records, per map id, the buildings that
## were placed and whether the map is complete. ensure_seeded() does nothing
## for a complete map, so neither a server restart nor a cell that is loaded
## again places anything twice. The record is saved in the same generation
## as the cells it describes.
##   - a new world is seeded when it is created (seed_new_world);
##   - a world that was saved before the map content existed (no record) is
##     seeded the first time a server starts it (WorldPersistence calls
##     ensure_seeded): a piece whose slot a player's structure already takes
##     is left out (PROVISIONAL, docs/15 P3-078);
##   - a world that was seeded keeps what it has when the content changes.
##
## Cells: structures and containers can only be placed in a cell that is in
## memory. The seeding brings the cells of a building into memory
## (WorldCellService.load_cell_now), places the building and, whenever
## `seeding_batch_cells` cells were loaded this way, saves and releases them
## (release_cells_now), so the whole map is never in memory at once. A world
## without a cell store keeps what was loaded (it never releases a cell), a
## world without a cell service has everything in memory anyway.
##
## Pieces that cannot be placed: `slot_occupied` (something stands there
## already) and `blocked_by_entity` (a zombie or a player stands in a wall's
## way: the completion is refused, and the blueprint is removed again
## without a refund) are left out, counted and logged; the building counts
## as placed. Any
## other refusal aborts the seeding with an error: the content does not fit
## the world, and a server must not start with half a map silently.

const SYSTEM_ID: String = "map_content"
const SCHEMA_VERSION: int = 1
const KEY_MAPS: String = "maps"
const KEY_CONTENT_VERSION: String = "content_version"
const KEY_BUILDINGS: String = "buildings"
const KEY_COMPLETE: String = "complete"
## Keys of last_seed_report.
const REPORT_BUILDINGS: String = "buildings"
const REPORT_STRUCTURES: String = "structures"
const REPORT_CONTAINERS: String = "containers"
const REPORT_SKIPPED_STRUCTURES: String = "skipped_structures"
const REPORT_SKIPPED_CONTAINERS: String = "skipped_containers"
const REPORT_CELLS_LOADED: String = "cells_loaded"
const REPORT_RELEASES: String = "releases"
const REPORT_USEC: String = "usec"
## Refusals of a structure piece that leave the piece out instead of
## aborting the seeding.
const SKIPPABLE_STRUCTURE_REASONS: PackedStringArray = [BuildingService.REASON_SLOT_OCCUPIED, BuildingService.REASON_BLOCKED_BY_ENTITY]

## Diagnostics: what the last ensure_seeded() that placed something did
## ({} = nothing was placed since this system was created): buildings,
## structures and containers placed, pieces left out, cells it brought into
## memory, how often it saved and released them, and how long it took
## (microseconds, wall clock).
var last_seed_report: Dictionary = {}

var _content: MapContentDefinition
var _structures: StructureCatalog
## map_id -> {content_version: int, buildings: Array of building ids,
## complete: bool}: what this world was seeded with.
var _maps: Dictionary[String, Dictionary] = {}


## `content` null = this world is given no map content (tests, tools).
func _init(content: MapContentDefinition, structures: StructureCatalog) -> void:
	_content = content
	_structures = structures


func get_system_id() -> String:
	return SYSTEM_ID


## The map content this system places (null = none).
func content() -> MapContentDefinition:
	return _content


## True when the world was completely seeded with the map `map_id` (the
## configured content's by default).
func is_seeded(map_id: String = "") -> bool:
	var key: String = map_id if not map_id.is_empty() else (_content.map_id if _content != null else "")
	return bool((_maps.get(key, {}) as Dictionary).get(KEY_COMPLETE, false))


## Ids of the buildings of a map that were placed in this world.
func seeded_building_ids(map_id: String) -> PackedStringArray:
	var ids: PackedStringArray = []
	for building_id: Variant in (_maps.get(map_id, {}) as Dictionary).get(KEY_BUILDINGS, []):
		ids.append(str(building_id))
	return ids


## A brand-new world gets the map content at once.
func seed_new_world(world: ServerWorld) -> Error:
	return ensure_seeded(world)


## Places every building of the configured content that this world does not
## have yet, and records it. Does nothing when there is no content or the
## map is complete. Returns OK, or an error (logged) when a cell could not
## be loaded, a piece was refused for a reason that is no skip, or the cells
## could not be saved: the map is then not marked complete and the next call
## goes on where this one stopped.
func ensure_seeded(world: ServerWorld) -> Error:
	if _content == null:
		return OK
	var map_id: String = _content.map_id
	var record: Dictionary = _maps.get(map_id, {})
	if bool(record.get(KEY_COMPLETE, false)):
		if int(record.get(KEY_CONTENT_VERSION, 0)) != _content.content_version:
			GameLogger.info("map", "the map content changed since this world was seeded; the world keeps what it has", {"world_id": world.world_id, "map_id": map_id, "seeded_version": int(record.get(KEY_CONTENT_VERSION, 0)), "content_version": _content.content_version})
		return OK
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	var containers: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
	if building == null or containers == null:
		GameLogger.error("map", "the map content needs the building and the container system", {"world_id": world.world_id, "map_id": map_id, "operation": "seed_map"})
		return ERR_UNCONFIGURED
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	var started_usec: int = Time.get_ticks_usec()
	if record.is_empty():
		record = {KEY_CONTENT_VERSION: _content.content_version, KEY_BUILDINGS: [], KEY_COMPLETE: false}
		_maps[map_id] = record
	var placed_ids: Array = record[KEY_BUILDINGS]
	var report: Dictionary = {REPORT_BUILDINGS: 0, REPORT_STRUCTURES: 0, REPORT_CONTAINERS: 0, REPORT_SKIPPED_STRUCTURES: 0, REPORT_SKIPPED_CONTAINERS: 0, REPORT_CELLS_LOADED: 0, REPORT_RELEASES: 0, REPORT_USEC: 0}
	var loaded_here: Array[String] = []
	var error: Error = OK
	for definition: MapBuildingDefinition in _content.buildings:
		if placed_ids.has(definition.building_id):
			continue
		error = _place_building(world, building, containers, cells, definition, loaded_here, report)
		if error != OK:
			break
		placed_ids.append(definition.building_id)
		report[REPORT_BUILDINGS] = int(report[REPORT_BUILDINGS]) + 1
		if loaded_here.size() >= _content.seeding_batch_cells:
			error = _release(world, cells, loaded_here, report)
			if error != OK:
				break
	if error == OK:
		record[KEY_COMPLETE] = true
		error = _release(world, cells, loaded_here, report)
	report[REPORT_USEC] = Time.get_ticks_usec() - started_usec
	last_seed_report = report
	if error != OK:
		GameLogger.error("map", "the map content could not be placed completely", {"world_id": world.world_id, "map_id": map_id, "error": error_string(error), "buildings_placed": placed_ids.size(), "operation": "seed_map"})
		return error
	GameLogger.info("map", "map content seeded", {"world_id": world.world_id, "map_id": map_id, "content_version": _content.content_version, "buildings": int(report[REPORT_BUILDINGS]), "structures": int(report[REPORT_STRUCTURES]), "containers": int(report[REPORT_CONTAINERS]), "skipped_structures": int(report[REPORT_SKIPPED_STRUCTURES]), "skipped_containers": int(report[REPORT_SKIPPED_CONTAINERS]), "cells_loaded": int(report[REPORT_CELLS_LOADED]), "msec": float(int(report[REPORT_USEC])) / 1000.0})
	return OK


# ------------------------------------------------------------ ServerSystem

## What this world was seeded with ({} = nothing yet).
func to_world_document() -> Dictionary:
	if _maps.is_empty():
		return {}
	var maps: Dictionary = {}
	for map_id: String in _maps:
		maps[map_id] = {
			KEY_CONTENT_VERSION: int(_maps[map_id][KEY_CONTENT_VERSION]),
			KEY_BUILDINGS: (_maps[map_id][KEY_BUILDINGS] as Array).duplicate(),
			KEY_COMPLETE: bool(_maps[map_id][KEY_COMPLETE]),
		}
	return {"schema_version": SCHEMA_VERSION, KEY_MAPS: maps}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != SCHEMA_VERSION:
		errors.append("map_content: unsupported schema_version")
		return errors
	var maps: Variant = document.get(KEY_MAPS, null)
	if typeof(maps) != TYPE_DICTIONARY:
		errors.append("map_content: maps must be an object")
		return errors
	var restored: Dictionary[String, Dictionary] = {}
	for key: Variant in (maps as Dictionary):
		var entry: Variant = (maps as Dictionary)[key]
		if typeof(entry) != TYPE_DICTIONARY or not ItemInstance.is_integer_value((entry as Dictionary).get(KEY_CONTENT_VERSION, null)) or typeof((entry as Dictionary).get(KEY_BUILDINGS, null)) != TYPE_ARRAY or typeof((entry as Dictionary).get(KEY_COMPLETE, null)) != TYPE_BOOL:
			errors.append("map_content: invalid record of map %s" % str(key))
			continue
		var building_ids: Array = []
		for building_id: Variant in ((entry as Dictionary)[KEY_BUILDINGS] as Array):
			if typeof(building_id) != TYPE_STRING:
				errors.append("map_content: invalid building id in the record of map %s" % str(key))
				continue
			building_ids.append(str(building_id))
		restored[str(key)] = {KEY_CONTENT_VERSION: int((entry as Dictionary)[KEY_CONTENT_VERSION]), KEY_BUILDINGS: building_ids, KEY_COMPLETE: bool((entry as Dictionary)[KEY_COMPLETE])}
	if errors.is_empty():
		_maps = restored
	return errors


# ------------------------------------------------------------ internals

## Places one building: brings its cells into memory, then its structure
## pieces, then its containers.
func _place_building(world: ServerWorld, building: BuildingService, containers: ContainerService, cells: WorldCellService, definition: MapBuildingDefinition, loaded_here: Array[String], report: Dictionary) -> Error:
	var pieces: Array[Dictionary] = MapBuildingPlan.structure_pieces(definition)
	for cell_id: String in _cells_of(world, building.grid, definition, pieces):
		if world.is_cell_loaded(cell_id):
			continue
		if cells == null or not cells.load_cell_now(world, cell_id):
			GameLogger.error("map", "a cell of the map content could not be loaded", {"world_id": world.world_id, "cell_id": cell_id, "building_id": definition.building_id, "operation": "seed_map"})
			return ERR_CANT_OPEN
		loaded_here.append(cell_id)
		report[REPORT_CELLS_LOADED] = int(report[REPORT_CELLS_LOADED]) + 1
	for piece: Dictionary in pieces:
		var placed: ActionResult = building.place_structure(world, str(piece[MapBuildingPlan.KEY_DEFINITION_ID]), piece[MapBuildingPlan.KEY_TILE] as Vector2i, int(piece[MapBuildingPlan.KEY_ROTATION]))
		if placed.ok:
			placed = _complete_piece(world, building, str(placed.event.get(BuildingService.KEY_STRUCTURE_ID, "")))
		if placed.ok:
			report[REPORT_STRUCTURES] = int(report[REPORT_STRUCTURES]) + 1
		elif SKIPPABLE_STRUCTURE_REASONS.has(placed.reason):
			report[REPORT_SKIPPED_STRUCTURES] = int(report[REPORT_SKIPPED_STRUCTURES]) + 1
			GameLogger.warning("map", "a piece of the map content was left out", {"world_id": world.world_id, "building_id": definition.building_id, "definition_id": str(piece[MapBuildingPlan.KEY_DEFINITION_ID]), "tile": str(piece[MapBuildingPlan.KEY_TILE]), "reason": placed.reason, "operation": "seed_map"})
		else:
			GameLogger.error("map", "a piece of the map content was refused", {"world_id": world.world_id, "building_id": definition.building_id, "definition_id": str(piece[MapBuildingPlan.KEY_DEFINITION_ID]), "tile": str(piece[MapBuildingPlan.KEY_TILE]), "reason": placed.reason, "operation": "seed_map"})
			return ERR_INVALID_DATA
	for index: int in range(definition.containers.size()):
		var placement: MapContainerPlacement = definition.containers[index]
		var created: ActionResult = containers.create_container(world, placement.definition_id, MapBuildingPlan.container_position(definition, placement, building.grid), definition.loot_table_of(placement), MapBuildingPlan.container_source_key(_content.map_id, definition.building_id, index))
		if created.ok:
			report[REPORT_CONTAINERS] = int(report[REPORT_CONTAINERS]) + 1
		elif created.reason == ContainerService.REASON_SOURCE_EXISTS:
			# It was placed by a seeding that did not get as far as its record.
			report[REPORT_SKIPPED_CONTAINERS] = int(report[REPORT_SKIPPED_CONTAINERS]) + 1
		else:
			GameLogger.error("map", "a container of the map content was refused", {"world_id": world.world_id, "building_id": definition.building_id, "definition_id": placement.definition_id, "reason": created.reason, "operation": "seed_map"})
			return ERR_INVALID_DATA
	return OK


## A map piece stands completed (P3-5: a placed piece is a blueprint unless
## BuildingSettings.instant_completion is on). When the completion is
## refused (somebody stands in a wall's edge: blocked_by_entity), the
## blueprint is removed again without a refund and the refusal is returned,
## so the piece counts as left out like a refused placement.
func _complete_piece(world: ServerWorld, building: BuildingService, structure_id: String) -> ActionResult:
	var structure: StructureInstance = building.get_structure(structure_id)
	if structure == null:
		return ActionResult.failure(BuildingService.REASON_UNKNOWN_STRUCTURE)
	if not structure.is_under_construction():
		return ActionResult.success({BuildingService.KEY_STRUCTURE_ID: structure_id})
	var completed: ActionResult = building.complete_structure(world, structure_id)
	if not completed.ok:
		building.remove_structure(world, structure_id)
	return completed


## Ids of the cells a building's pieces and containers lie in, sorted.
func _cells_of(world: ServerWorld, grid: StructureGrid, definition: MapBuildingDefinition, pieces: Array[Dictionary]) -> PackedStringArray:
	var seen: Dictionary[String, bool] = {}
	for piece: Dictionary in pieces:
		var structure: StructureDefinition = _structures.get_definition(str(piece[MapBuildingPlan.KEY_DEFINITION_ID]))
		var placement: int = structure.placement if structure != null else StructureDefinition.Placement.TILE
		seen[world.cell_id_at(grid.slot_home(StructureGrid.slot_of(placement, piece[MapBuildingPlan.KEY_TILE] as Vector2i, int(piece[MapBuildingPlan.KEY_ROTATION]))))] = true
	for placement: MapContainerPlacement in definition.containers:
		seen[world.cell_id_at(MapBuildingPlan.container_position(definition, placement, grid))] = true
	var ids: PackedStringArray = PackedStringArray(seen.keys())
	ids.sort()
	return ids


## Saves and releases the cells this seeding brought into memory. A world
## without a cell store keeps them (it never releases a cell).
func _release(world: ServerWorld, cells: WorldCellService, loaded_here: Array[String], report: Dictionary) -> Error:
	if cells == null or loaded_here.is_empty():
		return OK
	if cells.get_store() == null:
		loaded_here.clear()
		return OK
	var error: Error = cells.release_cells_now(world, PackedStringArray(loaded_here))
	if error != OK:
		return error
	loaded_here.clear()
	report[REPORT_RELEASES] = int(report[REPORT_RELEASES]) + 1
	return OK
