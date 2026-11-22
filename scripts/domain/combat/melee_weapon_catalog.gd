class_name MeleeWeaponCatalog
extends RefCounted
## Read-only lookup of MeleeWeaponDefinition resources by weapon id and by
## the item that grants them (same pattern as ItemCatalog).

const DEFAULT_DIRECTORY: String = "res://resources/definitions/melee_weapons"

var _definitions: Dictionary[String, MeleeWeaponDefinition] = {}
## item definition id -> weapon id
var _weapon_ids_by_item: Dictionary[String, String] = {}


## Adds a definition. Fails on invalid data, a duplicate weapon id or an
## item that already grants another weapon.
func add(definition: MeleeWeaponDefinition) -> Error:
	var errors: PackedStringArray = definition.validate()
	if not errors.is_empty():
		GameLogger.error("combat", "invalid melee weapon definition", {"weapon_id": definition.weapon_id, "errors": "; ".join(errors), "operation": "catalog_add"})
		return ERR_INVALID_DATA
	if _definitions.has(definition.weapon_id):
		GameLogger.error("combat", "duplicate melee weapon definition", {"weapon_id": definition.weapon_id, "operation": "catalog_add"})
		return ERR_ALREADY_EXISTS
	if not definition.item_definition_id.is_empty():
		if _weapon_ids_by_item.has(definition.item_definition_id):
			GameLogger.error("combat", "item already grants another melee weapon", {"weapon_id": definition.weapon_id, "definition_id": definition.item_definition_id, "operation": "catalog_add"})
			return ERR_ALREADY_EXISTS
		_weapon_ids_by_item[definition.item_definition_id] = definition.weapon_id
	_definitions[definition.weapon_id] = definition
	return OK


func has(weapon_id: String) -> bool:
	return _definitions.has(weapon_id)


func get_definition(weapon_id: String) -> MeleeWeaponDefinition:
	return _definitions.get(weapon_id, null)


func size() -> int:
	return _definitions.size()


## All weapon ids, sorted.
func weapon_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_definitions.keys())
	ids.sort()
	return ids


## Weapon granted by carrying an item of `item_definition_id`, or null.
func for_item(item_definition_id: String) -> MeleeWeaponDefinition:
	return _definitions.get(_weapon_ids_by_item.get(item_definition_id, ""), null)


## Weapon chosen by `rule` for the carried items (`item_definition_ids` in
## inventory slot order), or null when no carried item grants one.
## HIGHEST_DAMAGE ties resolve to the smaller weapon id.
func pick_for_items(item_definition_ids: PackedStringArray, rule: CombatSettings.WeaponRule) -> MeleeWeaponDefinition:
	if rule == CombatSettings.WeaponRule.UNARMED_ONLY:
		return null
	var best: MeleeWeaponDefinition = null
	for item_definition_id: String in item_definition_ids:
		var candidate: MeleeWeaponDefinition = for_item(item_definition_id)
		if candidate == null:
			continue
		if rule == CombatSettings.WeaponRule.FIRST_SLOT:
			return candidate
		if best == null or candidate.base_damage > best.base_damage or (candidate.base_damage == best.base_damage and candidate.weapon_id < best.weapon_id):
			best = candidate
	return best


## Checks the catalog against the data it refers to: the unarmed weapon
## exists and needs no item, weapon items exist in the item catalog and do
## not stack (each carries its own durability), and the swing noise is
## accepted by the noise system.
func validate_against(unarmed_weapon_id: String, items: ItemCatalog, noise: NoiseSettings) -> PackedStringArray:
	var errors: PackedStringArray = []
	var unarmed: MeleeWeaponDefinition = get_definition(unarmed_weapon_id)
	if unarmed == null:
		errors.append("melee weapon catalog has no unarmed weapon '%s'" % unarmed_weapon_id)
	elif not unarmed.item_definition_id.is_empty():
		errors.append("unarmed weapon '%s' must not need an item" % unarmed_weapon_id)
	for weapon_id: String in weapon_ids():
		var weapon: MeleeWeaponDefinition = _definitions[weapon_id]
		if not weapon.item_definition_id.is_empty() and not items.has(weapon.item_definition_id):
			errors.append("melee weapon %s refers to unknown item %s" % [weapon_id, weapon.item_definition_id])
		elif weapon.wears() and items.get_definition(weapon.item_definition_id).max_stack != 1:
			# One item = one weapon with its own uses left (F-3 durability).
			errors.append("melee weapon %s item %s must not stack (max_stack 1)" % [weapon_id, weapon.item_definition_id])
		if weapon.noise_loudness > noise.max_loudness:
			errors.append("melee weapon %s noise_loudness exceeds noise max_loudness" % weapon_id)
		if weapon.noise_loudness > 0.0 and not noise.is_valid_profile(weapon.noise_frequency_profile):
			errors.append("melee weapon %s has unknown noise_frequency_profile %s" % [weapon_id, weapon.noise_frequency_profile])
	return errors


## Loads every MeleeWeaponDefinition `.tres` in `directory`.
static func load_directory(directory: String = DEFAULT_DIRECTORY) -> MeleeWeaponCatalog:
	var catalog: MeleeWeaponCatalog = MeleeWeaponCatalog.new()
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		GameLogger.error("combat", "melee weapon definition directory missing", {"path": directory, "operation": "catalog_load"})
		return catalog
	var file_names: PackedStringArray = dir.get_files()
	file_names.sort()
	for file_name: String in file_names:
		# Exported builds list remapped resources with a ".remap" suffix.
		var resource_name: String = file_name.trim_suffix(".remap")
		if not resource_name.ends_with(".tres"):
			continue
		var definition: MeleeWeaponDefinition = ResourceLoader.load(directory.path_join(resource_name)) as MeleeWeaponDefinition
		if definition == null:
			GameLogger.error("combat", "not a melee weapon definition", {"path": resource_name, "operation": "catalog_load"})
			continue
		catalog.add(definition)
	return catalog
