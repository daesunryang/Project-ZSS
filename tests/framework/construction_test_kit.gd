class_name ConstructionTestKit
extends RefCounted
## Test data and helpers for the construction tests (P3-5, docs/09 §15.5):
## materials and structure definitions that belong to the tests, so that
## tuning the development definitions never changes what a test expects.
## Everything here is built fresh on every call: nothing is a cached
## Resource of CompositionConfig.from_defaults().

const PLANK: String = "test_plank"
const NAIL: String = "test_nail"
const PLANK_STACK: int = 10
const NAIL_STACK: int = 50

## An edge piece that blocks: 4 planks and 2 nails, 10 s of work, everything
## back on a cancel, half back on a demolition.
const WALL: String = "test_wall"
const WALL_WORK_SEC: float = 10.0
## A tile piece: 2 planks, 4 s of work.
const FLOOR: String = "test_floor"
const FLOOR_WORK_SEC: float = 4.0
## A door: 3 planks and 1 nail, 6 s of work.
const DOOR: String = "test_door"
const DOOR_WORK_SEC: float = 6.0
## A wall that needs no materials: 10 s of work.
const FREE_WALL: String = "test_free_wall"
## A wall that needs no materials and is never finished within a test.
const ENDLESS_WALL: String = "test_endless_wall"
const ENDLESS_WORK_SEC: float = 100000.0
## A wall that returns only a part: 5 planks and 3 nails; half back on a
## cancel, a quarter back on a demolition.
const LOSSY_WALL: String = "test_lossy_wall"
## A tile piece that needs more planks than one stack holds: 25.
const BIG_FLOOR: String = "test_big_floor"
const BIG_FLOOR_PLANKS: int = 25


## The shipped items plus the two test materials.
static func items() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	catalog.add(_item(PLANK, PLANK_STACK))
	catalog.add(_item(NAIL, NAIL_STACK))
	return catalog


## The test structures (none of the shipped ones).
static func structures() -> StructureCatalog:
	var catalog: StructureCatalog = StructureCatalog.new()
	catalog.add(_structure(WALL, StructureDefinition.Placement.EDGE, true, false, {PLANK: 4, NAIL: 2}, WALL_WORK_SEC, 100, 50))
	catalog.add(_structure(FLOOR, StructureDefinition.Placement.TILE, false, false, {PLANK: 2}, FLOOR_WORK_SEC, 100, 50))
	catalog.add(_structure(DOOR, StructureDefinition.Placement.EDGE, true, true, {PLANK: 3, NAIL: 1}, DOOR_WORK_SEC, 100, 50))
	catalog.add(_structure(FREE_WALL, StructureDefinition.Placement.EDGE, true, false, {}, WALL_WORK_SEC, 100, 50))
	catalog.add(_structure(ENDLESS_WALL, StructureDefinition.Placement.EDGE, true, false, {}, ENDLESS_WORK_SEC, 100, 50))
	catalog.add(_structure(LOSSY_WALL, StructureDefinition.Placement.EDGE, true, false, {PLANK: 5, NAIL: 3}, WALL_WORK_SEC, 50, 25))
	catalog.add(_structure(BIG_FLOOR, StructureDefinition.Placement.TILE, false, false, {PLANK: BIG_FLOOR_PLANKS}, FLOOR_WORK_SEC, 100, 50))
	return catalog


## Puts `quantity` units of an item into a player's inventory (through the
## world: spawned at its feet and picked up, one stack at a time). Returns
## false when that failed.
static func give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int) -> bool:
	var max_stack: int = _max_stack(definition_id)
	var left: int = quantity
	while left > 0:
		var units: int = mini(left, max_stack)
		var item_id: String = world.inventory.spawn_world_item(definition_id, units, world.cell_id_at(player.position), player.position)
		if item_id.is_empty() or not world.try_pickup(player.player_id, item_id).ok:
			return false
		left -= units
	return true


## Units of one kind a player carries.
static func carried(world: ServerWorld, player: PlayerState, definition_id: String) -> int:
	var units: int = 0
	for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
		if item.definition_id == definition_id:
			units += item.quantity
	return units


## Ids of the stacks of one kind a player carries, in slot order.
static func stacks(world: ServerWorld, player: PlayerState, definition_id: String) -> PackedStringArray:
	var ids: PackedStringArray = []
	for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
		if item.definition_id == definition_id:
			ids.append(item.item_instance_id)
	return ids


## Units of one kind lying in the world (in memory).
static func lying(world: ServerWorld, definition_id: String) -> int:
	var units: int = 0
	for item_id: String in world.inventory.world_item_ids():
		var item: ItemInstance = world.inventory.get_item(item_id)
		if item.definition_id == definition_id:
			units += item.quantity
	return units


## Units of one kind that are inside structures (in memory).
static func built_in(world: ServerWorld, definition_id: String) -> int:
	var service: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	var units: int = 0
	for structure_id: String in service.structure_ids():
		units += int(service.get_structure(structure_id).delivered_materials.get(definition_id, 0))
	return units


## Every unit of one kind the world knows of: carried by the given players,
## lying in the world and inside structures. What a rule must conserve.
static func total(world: ServerWorld, players: Array, definition_id: String) -> int:
	var units: int = lying(world, definition_id) + built_in(world, definition_id)
	for player: PlayerState in players:
		units += carried(world, player, definition_id)
	return units


## Stack size of the test materials; any other item is given one by one.
static func _max_stack(definition_id: String) -> int:
	if definition_id == NAIL:
		return NAIL_STACK
	return PLANK_STACK if definition_id == PLANK else 1


static func _item(definition_id: String, max_stack: int) -> ItemDefinition:
	var definition: ItemDefinition = ItemDefinition.new()
	definition.definition_id = definition_id
	definition.display_name = definition_id
	definition.max_stack = max_stack
	return definition


static func _structure(definition_id: String, placement: int, blocks: bool, door: bool, costs: Dictionary, work_sec: float, cancel_percent: int, demolish_percent: int) -> StructureDefinition:
	var definition: StructureDefinition = StructureDefinition.new()
	definition.definition_id = definition_id
	definition.display_name = definition_id
	definition.placement = placement
	definition.blocks_movement = blocks
	definition.is_door = door
	definition.max_health = 100.0
	for item_id: String in costs:
		definition.build_costs[item_id] = int(costs[item_id])
	definition.build_work_sec = work_sec
	definition.cancel_refund_percent = cancel_percent
	definition.demolish_refund_percent = demolish_percent
	return definition
