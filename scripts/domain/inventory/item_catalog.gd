class_name ItemCatalog
extends RefCounted
## Read-only lookup of ItemDefinition resources by definition_id.

const DEFAULT_DIRECTORY: String = "res://resources/definitions/items"

var _definitions: Dictionary[String, ItemDefinition] = {}


## Adds a definition. Fails on invalid or duplicate ids.
func add(definition: ItemDefinition) -> Error:
	var errors: PackedStringArray = definition.validate()
	if not errors.is_empty():
		GameLogger.error("inventory", "invalid item definition", {"definition_id": definition.definition_id, "errors": "; ".join(errors), "operation": "catalog_add"})
		return ERR_INVALID_DATA
	if _definitions.has(definition.definition_id):
		GameLogger.error("inventory", "duplicate item definition", {"definition_id": definition.definition_id, "operation": "catalog_add"})
		return ERR_ALREADY_EXISTS
	_definitions[definition.definition_id] = definition
	return OK


func has(definition_id: String) -> bool:
	return _definitions.has(definition_id)


func get_definition(definition_id: String) -> ItemDefinition:
	return _definitions.get(definition_id, null)


func size() -> int:
	return _definitions.size()


## Loads every ItemDefinition `.tres` in `directory`.
static func load_directory(directory: String = DEFAULT_DIRECTORY) -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.new()
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		GameLogger.error("inventory", "item definition directory missing", {"path": directory, "operation": "catalog_load"})
		return catalog
	for file_name: String in dir.get_files():
		# Exported builds list remapped resources with a ".remap" suffix.
		var resource_name: String = file_name.trim_suffix(".remap")
		if not resource_name.ends_with(".tres"):
			continue
		var definition: ItemDefinition = ResourceLoader.load(directory.path_join(resource_name)) as ItemDefinition
		if definition == null:
			GameLogger.error("inventory", "not an item definition", {"path": resource_name, "operation": "catalog_load"})
			continue
		catalog.add(definition)
	return catalog
