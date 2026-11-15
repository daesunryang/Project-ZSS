class_name StructureInstance
extends RefCounted
## Runtime state of one placed structure (docs/04 §4, docs/14 §3, docs/00
## ADR-005, ADR-024). Plain data: no Node or Resource references. Other
## systems treat it as read-only; every change goes through BuildingService.
##
## The required fields of docs/04 §4:
##   structure_id        stable, unique, never reused (`structure_<n>` from
##                       the world's EntityIdGenerator / EntityRegistry)
##   definition_id       StructureDefinition
##   owner_shelter_id    "" until shelters exist
##   cell_id             world cell of the piece (decided by its slot)
##   transform           grid coordinates: `tile` and `rotation` (quarter
##                       turns, StructureGrid). No metres: the module size
##                       turns them into a position.
##   construction_state  blueprint, constructing, completed, damaged,
##                       destroyed
##   health              0..definition.max_health
##   material_quality    1 = normal (nothing reads it yet)
##   inventory_costs     item definition id -> quantity the piece needs
##                       (the definition's build_costs when it was placed)
##   connections         ids of connected structures (always empty in
##                       P3-4a; rooms and support come later)
##   last_modified_at    calendar world time (WorldClock.world_time_sec) of
##                       the last change (docs/14 §2)
## and four more:
##   placed_by           player id of whoever placed it ("" = a server rule).
##                       Decides who may cancel or demolish it until shelters
##                       exist.
##   door_open           doors only: open (true) or closed.
##   construction_progress  P3-5: share of the work that is done, 0..1. 0 for
##                       a blueprint, above 0 while constructing, 1 for a
##                       standing piece. Never above material_share().
##   delivered_materials P3-5: item definition id -> units that players put
##                       into the piece (never more than inventory_costs).
##                       What a cancel or a demolition refunds is a share of
##                       this, so nothing is ever returned that was not paid.
##
## Construction (docs/04 §3, docs/00 ADR-025): blueprint (placed, no work
## yet) -> constructing (work has begun) -> completed.

enum State { BLUEPRINT, CONSTRUCTING, COMPLETED, DAMAGED, DESTROYED }

## Save / network names, indexed by State.
const STATE_NAMES: PackedStringArray = ["blueprint", "constructing", "completed", "damaged", "destroyed"]
const ENTITY_KIND: String = "structure"
const STRUCTURE_ID_PATTERN: String = "^structure_[0-9]+$"
const KEY_TILE: String = "tile"
const KEY_ROTATION: String = "rotation"
const KEY_PROGRESS: String = "construction_progress"
const KEY_DELIVERED: String = "delivered_materials"
const NO_PROGRESS: float = 0.0
const FULL_PROGRESS: float = 1.0

var structure_id: String = ""
var definition_id: String = ""
var owner_shelter_id: String = ""
var cell_id: String = ""
var tile: Vector2i = Vector2i.ZERO
var rotation: int = 0
var construction_state: State = State.BLUEPRINT
var health: float = 0.0
var material_quality: float = 1.0
var inventory_costs: Dictionary[String, int] = {}
var connections: PackedStringArray = []
var last_modified_at: float = 0.0
var placed_by: String = ""
var door_open: bool = false
var construction_progress: float = NO_PROGRESS
var delivered_materials: Dictionary[String, int] = {}


## True while the piece stands in the world as built: completed or damaged.
## Only a standing piece can block movement or be used (a door).
func is_standing() -> bool:
	return construction_state == State.COMPLETED or construction_state == State.DAMAGED


## True while the piece is being built: a blueprint or under construction.
## Only then can materials be delivered to it and work be done on it.
func is_under_construction() -> bool:
	return construction_state == State.BLUEPRINT or construction_state == State.CONSTRUCTING


## Units of one material that are still missing.
func missing_units(item_id: String) -> int:
	return maxi(int(inventory_costs.get(item_id, 0)) - int(delivered_materials.get(item_id, 0)), 0)


## What is still missing: item definition id -> units (> 0), in the order of
## inventory_costs. {} = every material is there.
func missing_materials() -> Dictionary[String, int]:
	var missing: Dictionary[String, int] = {}
	for item_id: String in inventory_costs:
		var units: int = missing_units(item_id)
		if units > 0:
			missing[item_id] = units
	return missing


## Share of the materials that was delivered, 0..1: delivered units over
## required units, all kinds counted together (docs/15 P3-127). 1 for a
## piece that needs nothing. Work can never take the progress above it
## (docs/04 §5).
func material_share() -> float:
	var required: int = 0
	var delivered: int = 0
	for item_id: String in inventory_costs:
		required += inventory_costs[item_id]
		delivered += mini(int(delivered_materials.get(item_id, 0)), inventory_costs[item_id])
	return FULL_PROGRESS if required <= 0 else float(delivered) / float(required)


static func state_name(value: State) -> String:
	return STATE_NAMES[value]


## State for a save / network name, or -1.
static func state_from_name(value: String) -> int:
	return STATE_NAMES.find(value)


static func is_valid_structure_id(value: String) -> bool:
	return RegEx.create_from_string(STRUCTURE_ID_PATTERN).search(value) != null


func to_dict() -> Dictionary:
	var costs: Dictionary = {}
	for item_id: String in inventory_costs:
		costs[item_id] = inventory_costs[item_id]
	var delivered: Dictionary = {}
	for item_id: String in delivered_materials:
		delivered[item_id] = delivered_materials[item_id]
	return {
		"structure_id": structure_id,
		"definition_id": definition_id,
		"owner_shelter_id": owner_shelter_id,
		"cell_id": cell_id,
		"transform": {KEY_TILE: [tile.x, tile.y], KEY_ROTATION: rotation},
		"construction_state": STATE_NAMES[construction_state],
		"health": health,
		"material_quality": material_quality,
		"inventory_costs": costs,
		"connections": Array(connections),
		"last_modified_at": last_modified_at,
		"placed_by": placed_by,
		"door_open": door_open,
		KEY_PROGRESS: construction_progress,
		KEY_DELIVERED: delivered,
	}


## A structure entry saved before P3-5 (building document schema 1) in the
## current shape. P3-4a had no construction: a standing piece was built at
## once and nothing was paid for it, so it is fully done and holds no
## materials; a blueprint (only made with the dev switch off) has no work
## done. Returns a new dictionary; entries that already have the fields are
## returned as they are.
static func upgrade_v1_entry(data: Dictionary) -> Dictionary:
	var upgraded: Dictionary = data.duplicate(true)
	if not upgraded.has(KEY_PROGRESS):
		var state: String = str(upgraded.get("construction_state", ""))
		var standing: bool = state == STATE_NAMES[State.COMPLETED] or state == STATE_NAMES[State.DAMAGED]
		upgraded[KEY_PROGRESS] = FULL_PROGRESS if standing else NO_PROGRESS
	if not upgraded.has(KEY_DELIVERED):
		upgraded[KEY_DELIVERED] = {}
	return upgraded


## Builds an instance from saved data, or null when `data` is malformed.
## Checks the shape only: whether the definition exists, whether the health
## fits it and where the piece stands is for BuildingService to check. The
## saved `cell_id` is read but the service decides the cell from the slot.
static func from_dict(data: Dictionary) -> StructureInstance:
	var id: Variant = data.get("structure_id", null)
	if typeof(id) != TYPE_STRING or not is_valid_structure_id(str(id)):
		return null
	var definition: Variant = data.get("definition_id", null)
	if typeof(definition) != TYPE_STRING or not ItemInstance.is_valid_definition_id(str(definition)):
		return null
	for key: String in ["owner_shelter_id", "cell_id", "placed_by", "construction_state"]:
		if typeof(data.get(key, null)) != TYPE_STRING:
			return null
	var state_index: int = state_from_name(str(data["construction_state"]))
	if state_index < 0:
		return null
	var transform: Variant = data.get("transform", null)
	if typeof(transform) != TYPE_DICTIONARY:
		return null
	var saved_tile: Variant = (transform as Dictionary).get(KEY_TILE, null)
	var saved_rotation: Variant = (transform as Dictionary).get(KEY_ROTATION, null)
	if typeof(saved_tile) != TYPE_ARRAY or (saved_tile as Array).size() != 2:
		return null
	if not ItemInstance.is_integer_value(saved_tile[0]) or not ItemInstance.is_integer_value(saved_tile[1]) or not ItemInstance.is_integer_value(saved_rotation):
		return null
	var grid_tile: Vector2i = Vector2i(int(saved_tile[0]), int(saved_tile[1]))
	if not StructureGrid.is_valid_tile(grid_tile) or not StructureGrid.is_valid_rotation(int(saved_rotation)):
		return null
	for key: String in ["health", "material_quality", "last_modified_at"]:
		var number: Variant = data.get(key, null)
		if not (typeof(number) == TYPE_FLOAT or typeof(number) == TYPE_INT) or not is_finite(float(number)) or float(number) < 0.0:
			return null
	if typeof(data.get("door_open", null)) != TYPE_BOOL:
		return null
	var costs: Variant = data.get("inventory_costs", null)
	if typeof(costs) != TYPE_DICTIONARY:
		return null
	var links: Variant = data.get("connections", null)
	if typeof(links) != TYPE_ARRAY:
		return null
	var progress: Variant = data.get(KEY_PROGRESS, null)
	if not (typeof(progress) == TYPE_FLOAT or typeof(progress) == TYPE_INT) or not is_finite(float(progress)) or float(progress) < NO_PROGRESS or float(progress) > FULL_PROGRESS:
		return null
	var delivered: Variant = data.get(KEY_DELIVERED, null)
	if typeof(delivered) != TYPE_DICTIONARY:
		return null
	var structure: StructureInstance = StructureInstance.new()
	for item_id: Variant in (costs as Dictionary):
		var quantity: Variant = (costs as Dictionary)[item_id]
		if typeof(item_id) != TYPE_STRING or not ItemInstance.is_valid_definition_id(str(item_id)) or not ItemInstance.is_integer_value(quantity) or int(quantity) < 1:
			return null
		structure.inventory_costs[str(item_id)] = int(quantity)
	for link: Variant in (links as Array):
		if typeof(link) != TYPE_STRING or not is_valid_structure_id(str(link)):
			return null
		structure.connections.append(str(link))
	# Delivered materials are a part of the costs: a kind the piece does not
	# need, or more units than it needs, is not a structure this code wrote.
	for item_id: Variant in (delivered as Dictionary):
		var units: Variant = (delivered as Dictionary)[item_id]
		if typeof(item_id) != TYPE_STRING or not ItemInstance.is_integer_value(units) or int(units) < 1 or int(units) > int(structure.inventory_costs.get(str(item_id), 0)):
			return null
		structure.delivered_materials[str(item_id)] = int(units)
	structure.construction_progress = float(progress)
	structure.structure_id = str(id)
	structure.definition_id = str(definition)
	structure.owner_shelter_id = str(data["owner_shelter_id"])
	structure.cell_id = str(data["cell_id"])
	structure.tile = grid_tile
	structure.rotation = int(saved_rotation)
	structure.construction_state = state_index as State
	structure.health = float(data["health"])
	structure.material_quality = float(data["material_quality"])
	structure.last_modified_at = float(data["last_modified_at"])
	structure.placed_by = str(data["placed_by"])
	structure.door_open = bool(data["door_open"])
	return structure
