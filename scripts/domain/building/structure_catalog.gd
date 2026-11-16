class_name StructureCatalog
extends RefCounted
## Read-only lookup of StructureDefinition resources by definition_id (the
## structure counterpart of ItemCatalog). Used by the server rules and by the
## client mirror, which checks that a replicated structure names a definition
## it has.

const DEFAULT_DIRECTORY: String = "res://resources/definitions/structures"

var _definitions: Dictionary[String, StructureDefinition] = {}


## Adds a definition. Fails on invalid or duplicate ids.
func add(definition: StructureDefinition) -> Error:
	var errors: PackedStringArray = definition.validate()
	if not errors.is_empty():
		GameLogger.error("building", "invalid structure definition", {"definition_id": definition.definition_id, "errors": "; ".join(errors), "operation": "catalog_add"})
		return ERR_INVALID_DATA
	if _definitions.has(definition.definition_id):
		GameLogger.error("building", "duplicate structure definition", {"definition_id": definition.definition_id, "operation": "catalog_add"})
		return ERR_ALREADY_EXISTS
	_definitions[definition.definition_id] = definition
	return OK


func has(definition_id: String) -> bool:
	return _definitions.has(definition_id)


func get_definition(definition_id: String) -> StructureDefinition:
	return _definitions.get(definition_id, null)


## Definition ids, sorted.
func definition_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_definitions.keys())
	ids.sort()
	return ids


func size() -> int:
	return _definitions.size()


## Errors of the catalog against the item catalog: every build cost must
## name an item that exists. (Each definition was validated when it was
## added.)
func validate_against(items: ItemCatalog, containers: ContainerCatalog = null) -> PackedStringArray:
	var errors: PackedStringArray = []
	for definition_id: String in definition_ids():
		for item_id: String in _definitions[definition_id].build_costs:
			if items == null or not items.has(item_id):
				errors.append("structure %s: build cost names unknown item %s" % [definition_id, item_id])
		var container_id: String = _definitions[definition_id].container_definition_id
		if containers != null and not container_id.is_empty() and not containers.has(container_id):
			errors.append("structure %s: container definition %s does not exist" % [definition_id, container_id])
	return errors


## Loads every StructureDefinition `.tres` in `directory`.
static func load_directory(directory: String = DEFAULT_DIRECTORY) -> StructureCatalog:
	var catalog: StructureCatalog = StructureCatalog.new()
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		GameLogger.error("building", "structure definition directory missing", {"path": directory, "operation": "catalog_load"})
		return catalog
	for file_name: String in dir.get_files():
		# Exported builds list remapped resources with a ".remap" suffix.
		var resource_name: String = file_name.trim_suffix(".remap")
		if not resource_name.ends_with(".tres"):
			continue
		var definition: StructureDefinition = ResourceLoader.load(directory.path_join(resource_name)) as StructureDefinition
		if definition == null:
			GameLogger.error("building", "not a structure definition", {"path": resource_name, "operation": "catalog_load"})
			continue
		catalog.add(definition)
	return catalog
