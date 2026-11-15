class_name WorldCellDocument
extends RefCounted
## Save document of one world cell (P3-1, docs/10 §3 `cells/<cell_id>.json`,
## docs/09 §15.1): everything that lies in the cell and can leave memory
## with it. Pure helpers; the content comes from the owners of the entities.
##
##   {schema_version: 1,
##    cell_id: "cell_<cx>_<cz>",
##    world_items: InventoryService.cell_snapshot()   ({} = none),
##    systems: {system_id: ServerSystem.to_cell_document()}}
##
## Players are never part of a cell document. No Node references, RIDs or
## runtime ids; JSON-safe.

const SCHEMA_VERSION: int = 1
const KEY_SCHEMA_VERSION: String = "schema_version"
const KEY_CELL_ID: String = "cell_id"
const KEY_WORLD_ITEMS: String = "world_items"
const KEY_SYSTEMS: String = "systems"


static func create(cell_id: String, world_items: Dictionary, systems: Dictionary) -> Dictionary:
	return {
		KEY_SCHEMA_VERSION: SCHEMA_VERSION,
		KEY_CELL_ID: cell_id,
		KEY_WORLD_ITEMS: world_items,
		KEY_SYSTEMS: systems,
	}


## True when the document holds no entity at all ({} counts as empty).
static func is_empty(document: Dictionary) -> bool:
	var world_items: Variant = document.get(KEY_WORLD_ITEMS, {})
	var systems: Variant = document.get(KEY_SYSTEMS, {})
	var no_items: bool = typeof(world_items) == TYPE_DICTIONARY and (world_items as Dictionary).is_empty()
	var no_systems: bool = typeof(systems) == TYPE_DICTIONARY and (systems as Dictionary).is_empty()
	return no_items and no_systems


## Errors of the document's own frame (version, cell id, shape). The content
## is checked by whoever restores it.
static func validate(document: Dictionary, cell_id: String) -> PackedStringArray:
	var errors: PackedStringArray = []
	var version: Variant = document.get(KEY_SCHEMA_VERSION, null)
	if not ItemInstance.is_integer_value(version) or int(version) != SCHEMA_VERSION:
		errors.append("cell %s: unsupported schema_version" % cell_id)
		return errors
	if typeof(document.get(KEY_CELL_ID, null)) != TYPE_STRING or str(document[KEY_CELL_ID]) != cell_id:
		errors.append("cell %s: document is for another cell" % cell_id)
	if typeof(document.get(KEY_WORLD_ITEMS, null)) != TYPE_DICTIONARY:
		errors.append("cell %s: world_items must be an object" % cell_id)
	if typeof(document.get(KEY_SYSTEMS, null)) != TYPE_DICTIONARY:
		errors.append("cell %s: systems must be an object" % cell_id)
	return errors
