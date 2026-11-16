class_name ContainerCatalog
extends RefCounted
## Read-only lookup of ContainerDefinition resources by definition_id (the
## container counterpart of ItemCatalog). Used by the server rules and by the
## client mirror, which checks that a replicated container names a definition
## it has.

const DEFAULT_DIRECTORY: String = "res://resources/definitions/containers"

var _definitions: Dictionary[String, ContainerDefinition] = {}


## Adds a definition. Fails on invalid or duplicate ids.
func add(definition: ContainerDefinition) -> Error:
	var errors: PackedStringArray = definition.validate()
	if not errors.is_empty():
		GameLogger.error("containers", "invalid container definition", {"definition_id": definition.definition_id, "errors": "; ".join(errors), "operation": "catalog_add"})
		return ERR_INVALID_DATA
	if _definitions.has(definition.definition_id):
		GameLogger.error("containers", "duplicate container definition", {"definition_id": definition.definition_id, "operation": "catalog_add"})
		return ERR_ALREADY_EXISTS
	_definitions[definition.definition_id] = definition
	return OK


func has(definition_id: String) -> bool:
	return _definitions.has(definition_id)


func get_definition(definition_id: String) -> ContainerDefinition:
	return _definitions.get(definition_id, null)


## Definition ids, sorted.
func definition_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_definitions.keys())
	ids.sort()
	return ids


func size() -> int:
	return _definitions.size()


## The largest slot count of any definition (0 for an empty catalog).
func max_slot_count() -> int:
	var largest: int = 0
	for definition_id: String in _definitions:
		largest = maxi(largest, _definitions[definition_id].slot_count)
	return largest


## Errors of the catalog against the loot tables: a definition's table must
## exist. (Each definition was validated when it was added.)
func validate_against(loot_tables: LootTableCatalog) -> PackedStringArray:
	var errors: PackedStringArray = []
	for definition_id: String in definition_ids():
		var table_id: String = _definitions[definition_id].loot_table_id
		if not table_id.is_empty() and (loot_tables == null or not loot_tables.has(table_id)):
			errors.append("container %s: unknown loot table %s" % [definition_id, table_id])
	return errors


## Loads every ContainerDefinition `.tres` in `directory`.
static func load_directory(directory: String = DEFAULT_DIRECTORY) -> ContainerCatalog:
	var catalog: ContainerCatalog = ContainerCatalog.new()
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		GameLogger.error("containers", "container definition directory missing", {"path": directory, "operation": "catalog_load"})
		return catalog
	for file_name: String in dir.get_files():
		# Exported builds list remapped resources with a ".remap" suffix.
		var resource_name: String = file_name.trim_suffix(".remap")
		if not resource_name.ends_with(".tres"):
			continue
		var definition: ContainerDefinition = ResourceLoader.load(directory.path_join(resource_name)) as ContainerDefinition
		if definition == null:
			GameLogger.error("containers", "not a container definition", {"path": resource_name, "operation": "catalog_load"})
			continue
		catalog.add(definition)
	return catalog
