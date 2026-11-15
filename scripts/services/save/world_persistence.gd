class_name WorldPersistence
extends RefCounted
## Loads/saves a ServerWorld through SaveService. Server only.

var _save: SaveService
var _gameplay: GameplaySettings
var _catalog: ItemCatalog


func _init(save_service: SaveService, gameplay: GameplaySettings, catalog: ItemCatalog) -> void:
	_save = save_service
	_gameplay = gameplay
	_catalog = catalog


## Returns the saved world, a freshly seeded world when no save exists, or
## null when the save exists but cannot be restored (never silently replaced).
func load_or_create(world_id: String, seed: DevWorldSeed) -> ServerWorld:
	var world: ServerWorld = ServerWorld.new(world_id, _gameplay, _catalog)
	if not _save.has_save(world_id):
		if world.seed_new_world(seed) != OK:
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
	return world


## Saves the whole world now and stamps players with the save time.
func save(world: ServerWorld) -> Error:
	var now: int = int(Time.get_unix_time_from_system())
	for player_id: String in world.online_player_ids():
		world.get_player(player_id).last_saved_at_utc = now
	var documents: Dictionary = world.to_documents()
	return _save.save_world(world.world_id, documents["world_state"], documents["players"])
