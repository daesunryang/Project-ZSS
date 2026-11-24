class_name NpcBehaviourState
extends NpcComponent
## What one NPC's behaviour is in the middle of, what it carries and what it
## has done (P4-5b, docs/09 §17.8). Saved with the NPC; only NpcBehaviours
## changes it. Where the NPC walks and which spot it holds is the executor's
## component (NpcExecutorState); the action it chose is the decision
## component's.
##
## Document (whole numbers and names only: a save never rounds any of it):
##   {action_id: "" | the behaviour that runs,
##    step: "" | "going" | "performing",
##    timer_usec: int (-1 = no timer of its own),
##    spot_id: the spot the behaviour uses ("" = none),
##    counts: {eat, drink, rest, work, wander, flee, failed, <action>_cut}
##             behaviours that were completed, that failed, and that were
##             cut short while they were being done,
##    worked_usec: int      action time spent working at a work place,
##    inventory_id: the NPC's own detached inventory ("" = none yet),
##    items: [ItemInstance.to_dict()]   what it carries}
##
## The inventory is a detached inventory of the world's InventoryService
## (like a container's): taken in on_attached(), given back in
## on_detached(). An NPC that is removed for good takes what it carries out
## of the game with it.

const COMPONENT_ID: String = "behaviour"
const SCHEMA_VERSION: int = 1

const STEP_NONE: String = ""
## On the way to where the behaviour happens.
const STEP_GOING: String = "going"
## There, doing it.
const STEP_PERFORMING: String = "performing"
const STEPS: PackedStringArray = [STEP_NONE, STEP_GOING, STEP_PERFORMING]
const NO_TIMER: int = -1
const MAX_SAFE_INT: int = 9007199254740991
const COUNT_FAILED: String = "failed"

const KEY_ACTION_ID: String = "action_id"
const KEY_STEP: String = "step"
const KEY_TIMER: String = "timer_usec"
const KEY_SPOT: String = "spot_id"
const KEY_COUNTS: String = "counts"
const KEY_WORKED: String = "worked_usec"
const KEY_INVENTORY_ID: String = "inventory_id"
const KEY_ITEMS: String = "items"

var action_id: String = ""
var step: String = STEP_NONE
var timer_usec: int = NO_TIMER
var spot_id: String = ""
## name (an action id, or "failed") -> how often.
var counts: Dictionary[String, int] = {}
var worked_usec: int = 0
var inventory_id: String = ""

var _slots: int = 4
## Slots of the inventory while the NPC is in memory (see on_attached).
var _capacity: int = 4
## What the NPC carries while it is NOT in memory (and until on_attached()).
var _saved_items: Array = []
var _world_ref: WeakRef = null
var _npc_id: String = ""


func _init(settings: NpcBehaviourSettings = null) -> void:
	_slots = settings.inventory_slots if settings != null else 4


static func create(settings: NpcBehaviourSettings) -> NpcComponent:
	return NpcBehaviourState.new(settings)


func component_id() -> String:
	return COMPONENT_ID


func schema_version() -> int:
	return SCHEMA_VERSION


func is_running() -> bool:
	return not action_id.is_empty()


func count_of(name: String) -> int:
	return counts.get(name, 0)


func add_count(name: String) -> void:
	counts[name] = count_of(name) + 1


func clear_action() -> void:
	action_id = ""
	step = STEP_NONE
	timer_usec = NO_TIMER
	spot_id = ""


## The NPC is in memory: its inventory comes into the world's
## InventoryService (a new one for an NPC that never had one).
func on_attached(world: ServerWorld, npc: NpcState) -> void:
	_world_ref = weakref(world)
	_npc_id = npc.npc_id
	if not inventory_id.is_empty():
		_capacity = maxi(_slots, _highest_slot() + 1)
		var snapshot: Dictionary = {InventoryService.DETACHED_CAPACITY: _capacity, InventoryService.SNAPSHOT_ITEMS: _saved_items}
		var errors: PackedStringArray = world.inventory.restore_detached_snapshot(inventory_id, snapshot)
		if errors.is_empty():
			_saved_items = []
			return
		GameLogger.error("npc", "an NPC's saved inventory could not be restored; it starts with an empty one", {"entity_id": npc.npc_id, "inventory_id": inventory_id, "errors": "; ".join(errors), "operation": "restore_inventory"})
	_capacity = _slots
	inventory_id = world.inventory.create_detached_inventory(_slots)
	_saved_items = []


## The NPC leaves memory: what it carries stays in this component (it
## comes back with the NPC), or leaves the game with an NPC that is removed.
func on_detached(world: ServerWorld, _npc: NpcState, retired: bool) -> void:
	if inventory_id.is_empty() or not world.inventory.is_detached_inventory(inventory_id):
		return
	if retired:
		for item: ItemInstance in world.inventory.items_in_inventory(inventory_id):
			world.inventory.remove_item(inventory_id, item.item_instance_id, item.quantity)
		_saved_items = []
	else:
		_saved_items = _live_items(world)
	world.inventory.release_detached_inventory(inventory_id)
	_world_ref = null


## Slots of the NPC's inventory (F-29: how much it can carry).
func capacity() -> int:
	return _capacity


## What the NPC carries, in slot order.
func carried_items() -> Array[ItemInstance]:
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	var held: Array[ItemInstance] = world.inventory.items_in_inventory(inventory_id) if world != null and not inventory_id.is_empty() else ([] as Array[ItemInstance])
	held.sort_custom(func(a: ItemInstance, b: ItemInstance) -> bool: return InventoryService.slot_index_of(a.slot_id) < InventoryService.slot_index_of(b.slot_id))
	return held


func to_document() -> Dictionary:
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	var saved_counts: Dictionary = {}
	var names: PackedStringArray = PackedStringArray(counts.keys())
	names.sort()
	for name: String in names:
		saved_counts[name] = counts[name]
	return {
		KEY_ACTION_ID: action_id,
		KEY_STEP: step,
		KEY_TIMER: timer_usec,
		KEY_SPOT: spot_id,
		KEY_COUNTS: saved_counts,
		KEY_WORKED: worked_usec,
		KEY_INVENTORY_ID: inventory_id,
		KEY_ITEMS: _live_items(world) if world != null and world.inventory.is_detached_inventory(inventory_id) else _saved_items.duplicate(true),
	}


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get(KEY_SCHEMA_VERSION, null)) or int(document[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("unsupported schema_version")
		return errors
	for key: String in [KEY_ACTION_ID, KEY_SPOT]:
		var name: Variant = document.get(key, null)
		if typeof(name) != TYPE_STRING or not (str(name).is_empty() or NpcComponent.is_valid_id(str(name))):
			errors.append("%s must be a snake_case name or empty" % key)
	if typeof(document.get(KEY_STEP, null)) != TYPE_STRING or not STEPS.has(str(document[KEY_STEP])):
		errors.append("step must be going, performing or empty")
	if not _is_whole(document.get(KEY_TIMER, null), NO_TIMER):
		errors.append("timer_usec must be a whole number >= -1")
	if not _is_whole(document.get(KEY_WORKED, null), 0):
		errors.append("worked_usec must be a whole number >= 0")
	var saved_counts: Variant = document.get(KEY_COUNTS, null)
	if typeof(saved_counts) != TYPE_DICTIONARY:
		errors.append("counts must be an object")
	else:
		for name: Variant in (saved_counts as Dictionary):
			if typeof(name) != TYPE_STRING or not NpcComponent.is_valid_id(str(name)) or not _is_whole((saved_counts as Dictionary)[name], 0):
				errors.append("invalid count %s" % str(name))
	var saved_inventory: Variant = document.get(KEY_INVENTORY_ID, null)
	var items: Variant = document.get(KEY_ITEMS, null)
	if typeof(saved_inventory) != TYPE_STRING or str(saved_inventory).length() > ID_MAX_LENGTH:
		errors.append("inventory_id must be a short string")
	if typeof(items) != TYPE_ARRAY:
		errors.append("items must be a list")
	if not errors.is_empty():
		return errors
	for entry: Variant in (items as Array):
		var item: ItemInstance = ItemInstance.from_dict(entry as Dictionary) if typeof(entry) == TYPE_DICTIONARY else null
		if item == null or item.location_type != ItemInstance.LOCATION_INVENTORY or item.location_id != str(saved_inventory) or str(saved_inventory).is_empty():
			errors.append("every item must be an item of this NPC's inventory")
			break
	if (str(document[KEY_ACTION_ID]).is_empty()) != (str(document[KEY_STEP]) == STEP_NONE):
		errors.append("action_id and step do not agree")
	if not errors.is_empty():
		return errors
	action_id = str(document[KEY_ACTION_ID])
	step = str(document[KEY_STEP])
	timer_usec = int(document[KEY_TIMER])
	spot_id = str(document[KEY_SPOT])
	worked_usec = int(document[KEY_WORKED])
	counts.clear()
	for name: Variant in (saved_counts as Dictionary):
		counts[str(name)] = int((saved_counts as Dictionary)[name])
	inventory_id = str(saved_inventory)
	_saved_items = (items as Array).duplicate(true)
	return errors


func _live_items(world: ServerWorld) -> Array:
	return (world.inventory.detached_snapshot(inventory_id).get(InventoryService.SNAPSHOT_ITEMS, []) as Array).duplicate(true)


## The highest slot number of the saved items (-1 = none): an inventory
## saved with more slots than the setting has now keeps them.
func _highest_slot() -> int:
	var highest: int = -1
	for entry: Variant in _saved_items:
		var item: ItemInstance = ItemInstance.from_dict(entry as Dictionary)
		if item != null:
			highest = maxi(highest, InventoryService.slot_index_of(item.slot_id))
	return highest


static func _is_whole(value: Variant, least: int) -> bool:
	return ItemInstance.is_integer_value(value) and float(value) >= float(least) and float(value) <= float(MAX_SAFE_INT)
