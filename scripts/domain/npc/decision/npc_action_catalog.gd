class_name NpcActionCatalog
extends RefCounted
## Read-only lookup of NpcActionDefinition resources by action_id (P4-4,
## docs/09 §17.6; the counterpart of NpcCatalog).

const DEFAULT_DIRECTORY: String = "res://resources/definitions/npc_actions"

var _actions: Dictionary[String, NpcActionDefinition] = {}
var _ids: PackedStringArray = []


## Adds an action. Fails on invalid or duplicate ids.
func add(action: NpcActionDefinition) -> Error:
	if action == null:
		return ERR_INVALID_PARAMETER
	var errors: PackedStringArray = action.validate()
	if not errors.is_empty():
		GameLogger.error("npc", "invalid npc action definition", {"action_id": action.action_id, "errors": "; ".join(errors), "operation": "action_catalog_add"})
		return ERR_INVALID_DATA
	if _actions.has(action.action_id):
		GameLogger.error("npc", "duplicate npc action definition", {"action_id": action.action_id, "operation": "action_catalog_add"})
		return ERR_ALREADY_EXISTS
	_actions[action.action_id] = action
	_ids.append(action.action_id)
	_ids.sort()
	return OK


func has(action_id: String) -> bool:
	return _actions.has(action_id)


func get_action(action_id: String) -> NpcActionDefinition:
	return _actions.get(action_id, null)


## Action ids, sorted: the order in which candidates are looked at.
func action_ids() -> PackedStringArray:
	return _ids


func size() -> int:
	return _actions.size()


## Loads every NpcActionDefinition `.tres` in `directory`.
static func load_directory(directory: String = DEFAULT_DIRECTORY) -> NpcActionCatalog:
	var catalog: NpcActionCatalog = NpcActionCatalog.new()
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		GameLogger.error("npc", "npc action directory missing", {"path": directory, "operation": "action_catalog_load"})
		return catalog
	var file_names: PackedStringArray = dir.get_files()
	file_names.sort()
	for file_name: String in file_names:
		# Exported builds list remapped resources with a ".remap" suffix.
		var resource_name: String = file_name.trim_suffix(".remap")
		if not resource_name.ends_with(".tres"):
			continue
		var action: NpcActionDefinition = ResourceLoader.load(directory.path_join(resource_name)) as NpcActionDefinition
		if action == null:
			GameLogger.error("npc", "not an npc action definition", {"path": resource_name, "operation": "action_catalog_load"})
			continue
		catalog.add(action)
	return catalog
