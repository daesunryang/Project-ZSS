class_name AppearanceCatalog
extends RefCounted
## Read-only lookup of the appearance slots (docs/00 ADR-015, docs/09
## §14.24) and the pure rules of an appearance selection. The same catalog
## is used by the server (validation, saving), the network module (rows a
## client accepts) and the creation screen (widgets), so a slot added to the
## data directory shows up everywhere without code changes.
##
## A selection is a Dictionary "slot id -> option id" (both Strings).
##   check_selection()    what a client sent: strict, missing slots get the
##                        slot's default option (docs/15 P2-162)
##   restore_selection()  what a save holds: lenient, repaired against the
##                        data of today
##   is_complete_selection()  what a mirror accepts: every slot, valid ids

const DEFAULT_DIRECTORY: String = "res://resources/definitions/appearance"
## Protocol and save limit on the number of slots.
const MAX_SLOTS: int = 64

const REASON_BAD_TYPE: String = "bad_type"
## More entries than there are slots.
const REASON_TOO_LARGE: String = "appearance_too_large"
const REASON_UNKNOWN_SLOT: String = "unknown_appearance_slot"
const REASON_UNKNOWN_OPTION: String = "unknown_appearance_option"

var _slots: Dictionary[String, AppearanceSlot] = {}
## Slot ids in display order (sort_order, then id).
var _order: PackedStringArray = []


## Adds a slot. Fails on an invalid slot, a duplicate id, a second slot with
## the same visual role, or when the catalog is full.
func add(slot: AppearanceSlot) -> Error:
	var errors: PackedStringArray = slot.validate()
	if not errors.is_empty():
		GameLogger.error("character", "invalid appearance slot", {"slot_id": slot.slot_id.left(AppearanceSlot.ID_MAX_LENGTH), "errors": "; ".join(errors), "operation": "catalog_add"})
		return ERR_INVALID_DATA
	if _slots.has(slot.slot_id):
		GameLogger.error("character", "duplicate appearance slot", {"slot_id": slot.slot_id, "operation": "catalog_add"})
		return ERR_ALREADY_EXISTS
	if slot.visual_role != AppearanceSlot.ROLE_NONE and slot_with_role(slot.visual_role) != null:
		GameLogger.error("character", "two appearance slots with the same visual role", {"slot_id": slot.slot_id, "visual_role": slot.visual_role, "operation": "catalog_add"})
		return ERR_ALREADY_EXISTS
	if _slots.size() >= MAX_SLOTS:
		GameLogger.error("character", "too many appearance slots", {"slot_id": slot.slot_id, "limit": MAX_SLOTS, "operation": "catalog_add"})
		return ERR_OUT_OF_MEMORY
	_slots[slot.slot_id] = slot
	_order.append(slot.slot_id)
	var ordered: Array = Array(_order)
	ordered.sort_custom(func(a: String, b: String) -> bool:
		var first: AppearanceSlot = _slots[a]
		var second: AppearanceSlot = _slots[b]
		return first.sort_order < second.sort_order or (first.sort_order == second.sort_order and a < b))
	_order = PackedStringArray(ordered)
	return OK


func size() -> int:
	return _slots.size()


## Slot ids in display order.
func slot_ids() -> PackedStringArray:
	return _order.duplicate()


## Slots in display order.
func slots() -> Array[AppearanceSlot]:
	var result: Array[AppearanceSlot] = []
	for slot_id: String in _order:
		result.append(_slots[slot_id])
	return result


func get_slot(slot_id: String) -> AppearanceSlot:
	return _slots.get(slot_id, null)


## The slot the placeholder capsule shows with `role`, or null.
func slot_with_role(role: String) -> AppearanceSlot:
	for slot_id: String in _order:
		if _slots[slot_id].visual_role == role:
			return _slots[slot_id]
	return null


## Every slot with its default option.
func default_selection() -> Dictionary:
	var selection: Dictionary = {}
	for slot_id: String in _order:
		selection[slot_id] = _slots[slot_id].default_option_id
	return selection


## Checks a selection sent by a client. Success event:
##   {"appearance": {slot_id: option_id}}  (every slot; a slot the client did
##   not send has its default option)
## Failure reasons: bad_type (not a Dictionary, or a key / value that is not
## a String), appearance_too_large (more entries than slots),
## unknown_appearance_slot, unknown_appearance_option. `raw` is not changed.
func check_selection(raw: Variant) -> ActionResult:
	if typeof(raw) != TYPE_DICTIONARY:
		return ActionResult.failure(REASON_BAD_TYPE)
	var given: Dictionary = raw
	# Before walking it: a valid selection never has more entries than slots.
	if given.size() > _slots.size():
		return ActionResult.failure(REASON_TOO_LARGE)
	var selection: Dictionary = default_selection()
	for key: Variant in given:
		var value: Variant = given[key]
		if typeof(key) != TYPE_STRING or typeof(value) != TYPE_STRING:
			return ActionResult.failure(REASON_BAD_TYPE)
		var slot: AppearanceSlot = _slots.get(key as String, null)
		if slot == null:
			return ActionResult.failure(REASON_UNKNOWN_SLOT)
		if not slot.has_option(value as String):
			return ActionResult.failure(REASON_UNKNOWN_OPTION)
		selection[key as String] = value as String
	return ActionResult.success({"appearance": selection})


## True when `selection` names every slot of this catalog, nothing else, and
## every option exists (the form the server stores and replicates).
func is_complete_selection(selection: Variant) -> bool:
	if typeof(selection) != TYPE_DICTIONARY or (selection as Dictionary).size() != _slots.size():
		return false
	var given: Dictionary = selection
	for key: Variant in given:
		if typeof(key) != TYPE_STRING or typeof(given[key]) != TYPE_STRING:
			return false
		var slot: AppearanceSlot = _slots.get(key as String, null)
		if slot == null or not slot.has_option(given[key] as String):
			return false
	return true


## Repairs a saved selection against today's data: slots that no longer
## exist are dropped, options that no longer exist and slots added since
## fall back to the slot's default. Never fails: a data change must not make
## a save unloadable.
func restore_selection(saved: Dictionary) -> Dictionary:
	var selection: Dictionary = default_selection()
	for key: Variant in saved:
		var slot: AppearanceSlot = _slots.get(key as String, null) if typeof(key) == TYPE_STRING else null
		if slot == null:
			GameLogger.warning("character", "saved appearance slot no longer exists (dropped)", {"slot_id": str(key).left(AppearanceSlot.ID_MAX_LENGTH), "operation": "restore_selection"})
			continue
		var value: Variant = saved[key]
		if typeof(value) != TYPE_STRING or not slot.has_option(value as String):
			GameLogger.warning("character", "saved appearance option no longer exists (default used)", {"slot_id": slot.slot_id, "option_id": str(value).left(AppearanceSlot.ID_MAX_LENGTH), "operation": "restore_selection"})
			continue
		selection[slot.slot_id] = value as String
	return selection


## A uniformly random option for every slot (the creation screen's random
## button). Always a complete, valid selection.
func random_selection(rng: RandomNumberGenerator) -> Dictionary:
	var selection: Dictionary = {}
	for slot_id: String in _order:
		var slot: AppearanceSlot = _slots[slot_id]
		selection[slot_id] = slot.options[rng.randi_range(0, slot.options.size() - 1)].option_id
	return selection


## Errors of the catalog as a whole (slots are validated when added).
func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	for slot_id: String in _order:
		for error: String in _slots[slot_id].validate():
			errors.append("appearance slot %s: %s" % [slot_id, error])
	return errors


## Loads every AppearanceSlot `.tres` in `directory`.
static func load_directory(directory: String = DEFAULT_DIRECTORY) -> AppearanceCatalog:
	var catalog: AppearanceCatalog = AppearanceCatalog.new()
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		GameLogger.error("character", "appearance definition directory missing", {"path": directory, "operation": "catalog_load"})
		return catalog
	var file_names: PackedStringArray = dir.get_files()
	file_names.sort()
	for file_name: String in file_names:
		# Exported builds list remapped resources with a ".remap" suffix.
		var resource_name: String = file_name.trim_suffix(".remap")
		if not resource_name.ends_with(".tres"):
			continue
		var slot: AppearanceSlot = ResourceLoader.load(directory.path_join(resource_name)) as AppearanceSlot
		if slot == null:
			GameLogger.error("character", "not an appearance slot", {"path": resource_name, "operation": "catalog_load"})
			continue
		catalog.add(slot)
	return catalog
