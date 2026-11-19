class_name NpcCatalog
extends RefCounted
## Read-only lookup of NpcDefinition resources by definition_id (P4-1,
## docs/09 §17.1; the NPC counterpart of ContainerCatalog).

const DEFAULT_DIRECTORY: String = "res://resources/definitions/npcs"

var _definitions: Dictionary[String, NpcDefinition] = {}


## Adds a definition. Fails on invalid or duplicate ids.
func add(definition: NpcDefinition) -> Error:
	var errors: PackedStringArray = definition.validate()
	if not errors.is_empty():
		GameLogger.error("npc", "invalid npc definition", {"definition_id": definition.definition_id, "errors": "; ".join(errors), "operation": "catalog_add"})
		return ERR_INVALID_DATA
	if _definitions.has(definition.definition_id):
		GameLogger.error("npc", "duplicate npc definition", {"definition_id": definition.definition_id, "operation": "catalog_add"})
		return ERR_ALREADY_EXISTS
	_definitions[definition.definition_id] = definition
	return OK


func has(definition_id: String) -> bool:
	return _definitions.has(definition_id)


func get_definition(definition_id: String) -> NpcDefinition:
	return _definitions.get(definition_id, null)


## Definition ids, sorted.
func definition_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_definitions.keys())
	ids.sort()
	return ids


func size() -> int:
	return _definitions.size()


## Errors of every definition against the appearance data. (Each definition
## itself was validated when it was added.)
func validate_against(appearance_catalog: AppearanceCatalog) -> PackedStringArray:
	var errors: PackedStringArray = []
	for definition_id: String in definition_ids():
		errors.append_array(_definitions[definition_id].validate_against(appearance_catalog))
	return errors


## Loads every NpcDefinition `.tres` in `directory` (not its subfolders:
## rosters live in one).
static func load_directory(directory: String = DEFAULT_DIRECTORY) -> NpcCatalog:
	var catalog: NpcCatalog = NpcCatalog.new()
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		GameLogger.error("npc", "npc definition directory missing", {"path": directory, "operation": "catalog_load"})
		return catalog
	var file_names: PackedStringArray = dir.get_files()
	file_names.sort()
	for file_name: String in file_names:
		# Exported builds list remapped resources with a ".remap" suffix.
		var resource_name: String = file_name.trim_suffix(".remap")
		if not resource_name.ends_with(".tres"):
			continue
		var definition: NpcDefinition = ResourceLoader.load(directory.path_join(resource_name)) as NpcDefinition
		if definition == null:
			GameLogger.error("npc", "not an npc definition", {"path": resource_name, "operation": "catalog_load"})
			continue
		catalog.add(definition)
	return catalog
