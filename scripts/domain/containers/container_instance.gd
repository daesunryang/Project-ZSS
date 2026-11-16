class_name ContainerInstance
extends RefCounted
## Runtime state of one container standing in the world (P3-3, docs/09
## §15.3, docs/14 §3 "ContainerInstance"). Its items are not stored here: they
## are ItemInstances of the world's InventoryService, carried in the
## inventory `inventory_id` (a detached inventory, which leaves memory and
## comes back together with this container). Serialized with `to_dict()` /
## `from_dict()`; no Node or Resource references.

const ENTITY_KIND: String = "container"

const KEY_CONTAINER_ID: String = "container_id"
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_CELL_ID: String = "cell_id"
const KEY_POSITION: String = "position"
const KEY_INVENTORY_ID: String = "inventory_id"
const KEY_SLOT_COUNT: String = "slot_count"
const KEY_LOOT_TABLE_ID: String = "loot_table_id"
const KEY_SEARCHED: String = "searched"
const KEY_SOURCE_KEY: String = "source_key"
const KEY_CREATED_AT: String = "created_at"
const KEY_LOOT_SEED: String = "loot_seed"
## Largest loot seed a save can carry exactly: saves are JSON, whose numbers
## are doubles (2^53 - 1).
const MAX_LOOT_SEED: int = 9007199254740991

## Stable id, unique in the world and never reused: `container_<number>`.
var container_id: String = ""
## ContainerDefinition.definition_id.
var definition_id: String = ""
## The world cell of `position` (decided again from the position when the
## container is restored).
var cell_id: String = ""
var position: Vector3 = Vector3.ZERO
## The inventory of the InventoryService that holds the content.
var inventory_id: String = ""
## Number of stacks it holds (the definition's value when it was created).
var slot_count: int = 1
## The table its loot is rolled from at the first search ("" = none).
var loot_table_id: String = ""
## true once the loot was rolled (or there never was any to roll). It never
## becomes false again: a container is filled at most once.
var searched: bool = false
## What placed it, for a container of the map content ("<map>/<building>/
## <index>"); "" for any other. At most one container per key exists.
var source_key: String = ""
## Calendar world time at which it was created.
var created_at: float = 0.0
## The world's loot seed when the container was created
## (ContainerSettings.loot_seed). Its loot is rolled from this seed and its
## id (LootRoller.seed_for), so changing the setting later never changes what
## a container that exists already holds. 0..MAX_LOOT_SEED.
var loot_seed: int = 0


func to_dict() -> Dictionary:
	return {
		KEY_CONTAINER_ID: container_id,
		KEY_DEFINITION_ID: definition_id,
		KEY_CELL_ID: cell_id,
		KEY_POSITION: [position.x, position.y, position.z],
		KEY_INVENTORY_ID: inventory_id,
		KEY_SLOT_COUNT: slot_count,
		KEY_LOOT_TABLE_ID: loot_table_id,
		KEY_SEARCHED: searched,
		KEY_SOURCE_KEY: source_key,
		KEY_CREATED_AT: created_at,
		KEY_LOOT_SEED: loot_seed,
	}


## Builds an instance from saved data. Returns null when the data is
## malformed (the shape only: whether the definition exists and the content
## fits is checked by ContainerService).
static func from_dict(data: Dictionary) -> ContainerInstance:
	for key: String in [KEY_CONTAINER_ID, KEY_DEFINITION_ID, KEY_INVENTORY_ID, KEY_LOOT_TABLE_ID, KEY_SOURCE_KEY]:
		if typeof(data.get(key, null)) != TYPE_STRING:
			return null
	if str(data[KEY_CONTAINER_ID]).is_empty() or str(data[KEY_INVENTORY_ID]).is_empty():
		return null
	if not ItemInstance.is_valid_definition_id(str(data[KEY_DEFINITION_ID])):
		return null
	var raw_position: Variant = data.get(KEY_POSITION, null)
	if typeof(raw_position) != TYPE_ARRAY or (raw_position as Array).size() != 3:
		return null
	for component: Variant in (raw_position as Array):
		if not _is_number(component) or not is_finite(float(component)):
			return null
	if not ItemInstance.is_integer_value(data.get(KEY_SLOT_COUNT, null)) or int(data[KEY_SLOT_COUNT]) < 1:
		return null
	if typeof(data.get(KEY_SEARCHED, null)) != TYPE_BOOL:
		return null
	if not _is_number(data.get(KEY_CREATED_AT, null)) or not is_finite(float(data[KEY_CREATED_AT])):
		return null
	if not ItemInstance.is_integer_value(data.get(KEY_LOOT_SEED, null)) or not is_valid_loot_seed(int(data[KEY_LOOT_SEED])):
		return null
	var container: ContainerInstance = ContainerInstance.new()
	container.container_id = str(data[KEY_CONTAINER_ID])
	container.definition_id = str(data[KEY_DEFINITION_ID])
	container.cell_id = str(data.get(KEY_CELL_ID, ""))
	container.position = Vector3(float(raw_position[0]), float(raw_position[1]), float(raw_position[2]))
	container.inventory_id = str(data[KEY_INVENTORY_ID])
	container.slot_count = int(data[KEY_SLOT_COUNT])
	container.loot_table_id = str(data[KEY_LOOT_TABLE_ID])
	container.searched = bool(data[KEY_SEARCHED])
	container.source_key = str(data[KEY_SOURCE_KEY])
	container.created_at = float(data[KEY_CREATED_AT])
	container.loot_seed = int(data[KEY_LOOT_SEED])
	return container


## True when `value` can be a loot seed: a save carries it exactly.
static func is_valid_loot_seed(value: int) -> bool:
	return value >= 0 and value <= MAX_LOOT_SEED


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT
