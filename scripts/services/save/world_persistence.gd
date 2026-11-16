class_name WorldPersistence
extends RefCounted
## Loads/saves a ServerWorld through SaveService. Server only.
##
## World cells (P3-1, docs/09 §15.1): a world loaded or created here keeps
## its released cells in the save itself (SaveWorldCellStore). Loading a
## world brings no cell into memory; the server reads a cell file when a
## player comes near. Every save() is one generation of the whole world:
## world_state.json, the players and every cell that is in memory. That is
## also how a cell is saved before it is released, and why a shutdown save
## flushes every loaded cell.

var _save: SaveService
var _config: CompositionConfig


## Worlds are always built through ServerComposition so loaded and new
## worlds have the same registered systems.
func _init(save_service: SaveService, config: CompositionConfig) -> void:
	_save = save_service
	_config = config


## Returns the saved world, a freshly seeded world when no save exists, or
## null when the save exists but cannot be restored (never silently replaced).
func load_or_create(world_id: String) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(world_id, _config)
	if world == null:
		return null
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	var store: SaveWorldCellStore = SaveWorldCellStore.new(_save, self, world_id)
	if cells != null:
		cells.set_store(store)
	if not _save.has_save(world_id):
		if world.seed_new_world(_config.dev_seed) != OK:
			return null
		if save(world) != OK:
			return null
		return world
	var loaded: Dictionary = _save.load_world(world_id)
	if loaded["error"] != OK:
		GameLogger.fatal("save", "existing save could not be loaded", {"world_id": world_id, "error": error_string(loaded["error"]), "operation": "load_world"})
		return null
	var errors: PackedStringArray = world.restore_documents(loaded["world_state"], loaded["players"])
	if not errors.is_empty():
		GameLogger.fatal("save", "save failed integrity checks", {"world_id": world_id, "errors": "; ".join(errors), "operation": "restore_world"})
		return null
	if cells != null and cells.needs_repartition() and not _repartition(world, cells, store, loaded["cell_ids"] as PackedStringArray):
		return null
	# P3-3: a world that was saved before it got the configured map content
	# gets it now, once (a new world got it when it was seeded). The seeding
	# saves what it placed; a world that has it already is left alone.
	var map_content: MapContentService = world.get_system(MapContentService.SYSTEM_ID) as MapContentService
	if map_content != null and map_content.ensure_seeded(world) != OK:
		GameLogger.fatal("save", "the map content could not be placed in the saved world", {"world_id": world_id, "operation": "seed_map"})
		return null
	return world


## Saves the whole world now and stamps players with the save time.
func save(world: ServerWorld) -> Error:
	var now: int = int(Time.get_unix_time_from_system())
	for player_id: String in world.online_player_ids():
		world.get_player(player_id).last_saved_at_utc = now
	var documents: Dictionary = world.to_documents()
	var error: Error = _save.save_world(world.world_id, documents["world_state"], documents["players"], documents["cells"], bool(documents["replace_cells"]))
	if error == OK:
		var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
		if cells != null:
			cells.on_world_saved()
	return error


## The save was cut with another cell grid (the cell size or the map bounds
## were changed): reads every cell file, gives every entity the cell of its
## position in the new grid and writes the whole world again, replacing the
## old cell files in one generation. False (logged) when a cell file cannot
## be read or restored: the save is then left as it is.
func _repartition(world: ServerWorld, cells: WorldCellService, store: SaveWorldCellStore, cell_ids: PackedStringArray) -> bool:
	var documents: Dictionary = {}
	for cell_id: String in cell_ids:
		var loaded: Dictionary = _save.load_cell(world.world_id, cell_id)
		if loaded["error"] != OK:
			GameLogger.fatal("save", "cell file could not be read for the new cell grid", {"world_id": world.world_id, "cell_id": cell_id, "error": error_string(loaded["error"]), "operation": "repartition"})
			return false
		documents[cell_id] = loaded["document"]
	var errors: PackedStringArray = world.repartition_from(documents)
	if not errors.is_empty():
		GameLogger.fatal("save", "saved cells could not be sorted into the new cell grid", {"world_id": world.world_id, "errors": "; ".join(errors), "operation": "repartition"})
		return false
	store.discard_saved_cells()
	cells.repartition_done()
	if save(world) != OK:
		return false
	GameLogger.info("save", "world partitioned for the new cell grid", {"world_id": world.world_id, "old_cells": cell_ids.size(), "cells": _save.saved_cell_ids(world.world_id).size()})
	return true
