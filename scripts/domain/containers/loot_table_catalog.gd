class_name LootTableCatalog
extends RefCounted
## Read-only lookup of LootTable resources by table_id (the loot counterpart
## of ItemCatalog). Server only: clients never see a loot table.

const DEFAULT_DIRECTORY: String = "res://resources/definitions/loot_tables"

var _tables: Dictionary[String, LootTable] = {}


## Adds a table. Fails on invalid or duplicate ids.
func add(table: LootTable) -> Error:
	var errors: PackedStringArray = table.validate()
	if not errors.is_empty():
		GameLogger.error("containers", "invalid loot table", {"table_id": table.table_id, "errors": "; ".join(errors), "operation": "catalog_add"})
		return ERR_INVALID_DATA
	if _tables.has(table.table_id):
		GameLogger.error("containers", "duplicate loot table", {"table_id": table.table_id, "operation": "catalog_add"})
		return ERR_ALREADY_EXISTS
	_tables[table.table_id] = table
	return OK


func has(table_id: String) -> bool:
	return _tables.has(table_id)


func get_table(table_id: String) -> LootTable:
	return _tables.get(table_id, null)


## Table ids, sorted.
func table_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_tables.keys())
	ids.sort()
	return ids


func size() -> int:
	return _tables.size()


## Errors of every table against the item definitions.
func validate_against(items: ItemCatalog) -> PackedStringArray:
	var errors: PackedStringArray = []
	for table_id: String in table_ids():
		errors.append_array(_tables[table_id].validate_against(items))
	return errors


## Loads every LootTable `.tres` in `directory`.
static func load_directory(directory: String = DEFAULT_DIRECTORY) -> LootTableCatalog:
	var catalog: LootTableCatalog = LootTableCatalog.new()
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		GameLogger.error("containers", "loot table directory missing", {"path": directory, "operation": "catalog_load"})
		return catalog
	for file_name: String in dir.get_files():
		# Exported builds list remapped resources with a ".remap" suffix.
		var resource_name: String = file_name.trim_suffix(".remap")
		if not resource_name.ends_with(".tres"):
			continue
		var table: LootTable = ResourceLoader.load(directory.path_join(resource_name)) as LootTable
		if table == null:
			GameLogger.error("containers", "not a loot table", {"path": resource_name, "operation": "catalog_load"})
			continue
		catalog.add(table)
	return catalog
