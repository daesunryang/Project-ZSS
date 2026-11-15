class_name BuildingService
extends ServerSystem
## Server-authoritative grid structures: floors, walls, doors (P3-4a,
## docs/04 §2-§4, §10, docs/00 ADR-024, docs/09 §15.4). System id
## "building". No networking here (StructureNetModule), no nodes.
##
## What it owns: every structure that is in memory (StructureInstance), the
## occupancy index (which slot of the building grid holds which structure)
## and the set of edges that block movement. The server alone decides:
## clients send intents (definition, tile, rotation; a structure id), never a
## position of their own, an owner or a result.
##
## Public API (every ActionResult failure carries a reason code below):
##   try_place(world, player_id, definition_id, tile, rotation)
##   try_demolish(world, player_id, structure_id)
##   try_set_door(world, player_id, structure_id, open)
##       requests of a player, checked against the player's server state
##   place_structure(world, definition_id, tile, rotation, placed_by = "")
##   remove_structure(world, structure_id)
##   set_door_open(world, structure_id, open)
##       the same changes as server rules (no actor, no range)
##   has_structure, get_structure (read-only), structure_ids,
##   structure_count, structure_id_at(slot), is_edge_blocked(slot),
##   public_row, rows, rows_in_cell, structure_ids_in_cell
##   drain_events() -> Array[Dictionary]      (network read surface)
##
## Placement checks, in this order (the first that fails is the reason; a
## refused request changes nothing):
##   1. the player is in the world              not_online
##   2. the player can act                      player_dead, player_resting
##   3. the definition exists                   unknown_structure_definition
##   4. the rotation is 0..3                    bad_rotation
##   5. the tile is inside the play area        out_of_bounds
##   6. the piece is within placement range of
##      the player's SERVER position            too_far
##   7. the piece's cell is in memory           cell_not_loaded
##   8. its slot is free                        slot_occupied
##   9. no living player or zombie stands in a
##      blocking piece's way                    blocked_by_entity
##  10. the cell holds fewer than the limit     structure_limit
## Coordinates are whole tiles, so a request cannot be off the grid. Two
## requests for one slot are handled one after the other: the first takes
## the slot, the second gets slot_occupied (docs/04 §10).
##
## PROVISIONAL rules (docs/15 §15.4):
##   - a placed structure is `completed` at once (BuildingSettings.
##     instant_completion; P3-5 switches to blueprint -> work -> completed).
##     Nothing is paid: `inventory_costs` only records the definition's
##     costs.
##   - any living player may place and may open or close any door; only the
##     player who placed a structure may demolish it.
##   - only a standing piece (completed or damaged) blocks movement; a
##     blueprint takes its slot but blocks nothing.
##
## Movement (ServerSystem.resolve_movement_step): completed walls and
## closed doors stop players and zombies; floors and open doors do not. See
## StructureGrid.resolve_step. With no blocking edge in memory a step is
## returned untouched.
##
## World cells (docs/09 §15.1): every structure in memory is in
## ServerWorld.cell_index (kind "structure") under the cell of its slot
## (StructureGrid.slot_home). A cell's structures leave memory and come
## back unchanged through to_cell_document / restore_cell_document /
## release_cell; no event is recorded for that (StructureNetModule tells the
## clients). Structures are not simulated, so activation changes nothing.
##
## Events (drain_events; JSON-safe; every event has event_type, world_time,
## player_id ("" = a server rule), cell_id and the public row of the
## structure: structure_id, definition_id, x, z, rotation, state,
## door_open, health_fraction):
##   structure_placed     the structure exists now
##   structure_changed    {cause: "door"} its door was opened or closed
##   structure_removed    it was demolished (the row is its last state)
##
## Save: per cell document `systems.building` =
##   {schema_version, structures: [StructureInstance.to_dict()]}
## and world_state.json `systems.building`, the same shape, for structures
## that are not saved with a cell document (a world without a saved cell
## store). A save without either has no structures. Not saved: events.

const SYSTEM_ID: String = "building"
const SCHEMA_VERSION: int = 1
## Version of this system's part of a cell document.
const CELL_SCHEMA_VERSION: int = 1
const ENTITY_KIND_STRUCTURE: String = StructureInstance.ENTITY_KIND
const KEY_STRUCTURES: String = "structures"

const EVENT_PLACED: String = "structure_placed"
const EVENT_CHANGED: String = "structure_changed"
const EVENT_REMOVED: String = "structure_removed"
const CAUSE_DOOR: String = "door"

const REASON_UNKNOWN_DEFINITION: String = "unknown_structure_definition"
const REASON_BAD_ROTATION: String = "bad_rotation"
const REASON_OUT_OF_BOUNDS: String = "out_of_bounds"
const REASON_TOO_FAR: String = "too_far"
const REASON_CELL_NOT_LOADED: String = "cell_not_loaded"
const REASON_SLOT_OCCUPIED: String = "slot_occupied"
const REASON_BLOCKED_BY_ENTITY: String = "blocked_by_entity"
const REASON_LIMIT: String = "structure_limit"
const REASON_ID_FAILED: String = "structure_id_failed"
const REASON_UNKNOWN_STRUCTURE: String = "unknown_structure"
const REASON_NOT_OWNER: String = "not_owner"
const REASON_NOT_A_DOOR: String = "not_a_door"
const REASON_NOT_USABLE: String = "structure_not_usable"
const REASON_DOOR_ALREADY_IN_STATE: String = "door_already_in_state"
## The world has no building system (StructureNetModule answers with it).
const REASON_UNAVAILABLE: String = "building_unavailable"

## Public row keys (events, StructureNetModule).
const KEY_STRUCTURE_ID: String = "structure_id"
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_X: String = "x"
const KEY_Z: String = "z"
const KEY_ROTATION: String = "rotation"
const KEY_STATE: String = "state"
const KEY_DOOR_OPEN: String = "door_open"
const KEY_HEALTH_FRACTION: String = "health_fraction"

## The building grid of this world (module size from the settings).
var grid: StructureGrid
## Diagnostics: events dropped because nobody drained them.
var dropped_event_count: int = 0

var _settings: BuildingSettings
var _catalog: StructureCatalog
var _ids: EntityIdGenerator
var _registry: EntityRegistry
var _clock: WorldClock
## The world this system is registered with (weak: the world owns it).
var _world_ref: WeakRef = null
## Structures in memory. Insertion order = the order they were placed or
## loaded (deterministic iteration).
var _structures: Dictionary[String, StructureInstance] = {}
## Occupancy: StructureGrid.slot_key -> structure id (every state).
var _slots: Dictionary[int, String] = {}
## Edge slots that cannot be crossed now: slot_key -> true.
var _blocking: Dictionary[int, bool] = {}
## Mover kinds that slide along a blocking edge (from the settings).
var _sliding_kinds: Dictionary[String, bool] = {}
var _events: Array[Dictionary] = []


func _init(settings: BuildingSettings, catalog: StructureCatalog, ids: EntityIdGenerator, registry: EntityRegistry, clock: WorldClock) -> void:
	_settings = settings
	_catalog = catalog
	_ids = ids
	_registry = registry
	_clock = clock
	grid = StructureGrid.new(settings.grid_module_m)
	for kind: String in settings.sliding_mover_kinds:
		_sliding_kinds[kind] = true


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ player requests

## A player places a structure (docs/04 §3 step 4-6, without materials).
## See the header for the checks. Success event: structure_placed.
func try_place(world: ServerWorld, player_id: String, definition_id: String, tile: Vector2i, rotation: int) -> ActionResult:
	var blocked: String = _actor_block_reason(world, player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var reason: String = _request_reason(world, definition_id, tile, rotation)
	if not reason.is_empty():
		return ActionResult.failure(reason)
	var definition: StructureDefinition = _catalog.get_definition(definition_id)
	var slot: Vector3i = StructureGrid.slot_of(definition.placement, tile, rotation)
	if StructureGrid.flat_distance(world.get_player(player_id).position, grid.slot_anchor(slot)) > _settings.placement_range_m:
		return ActionResult.failure(REASON_TOO_FAR)
	return _place(world, definition, tile, rotation, slot, player_id)


## A player demolishes a structure: it leaves the world and its id is never
## used again. Only the player who placed it may (PROVISIONAL). Checks, in
## order: not_online, player_dead / player_resting, unknown_structure (also
## a structure of a cell that is not in memory), not_owner, too_far. Success
## event: structure_removed.
func try_demolish(world: ServerWorld, player_id: String, structure_id: String) -> ActionResult:
	var blocked: String = _actor_block_reason(world, player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var structure: StructureInstance = _structures.get(structure_id, null)
	if structure == null:
		return ActionResult.failure(REASON_UNKNOWN_STRUCTURE)
	if structure.placed_by != player_id:
		return ActionResult.failure(REASON_NOT_OWNER)
	if StructureGrid.flat_distance(world.get_player(player_id).position, grid.slot_anchor(_slot_of(structure))) > _settings.demolish_range_m:
		return ActionResult.failure(REASON_TOO_FAR)
	return _remove(world, structure, player_id)


## A player opens (`open` true) or closes a door. The request names the
## state it wants, not a toggle, so a client that is one step behind gets a
## refusal instead of the opposite action. Any living player may
## (PROVISIONAL). Checks, in order: not_online, player_dead /
## player_resting, unknown_structure, not_a_door, too_far,
## structure_not_usable (not standing), door_already_in_state,
## blocked_by_entity (closing on somebody). Success event: structure_changed.
func try_set_door(world: ServerWorld, player_id: String, structure_id: String, open: bool) -> ActionResult:
	var blocked: String = _actor_block_reason(world, player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var structure: StructureInstance = _structures.get(structure_id, null)
	if structure == null:
		return ActionResult.failure(REASON_UNKNOWN_STRUCTURE)
	var definition: StructureDefinition = _catalog.get_definition(structure.definition_id)
	if definition == null or not definition.is_door:
		return ActionResult.failure(REASON_NOT_A_DOOR)
	if StructureGrid.flat_distance(world.get_player(player_id).position, grid.slot_anchor(_slot_of(structure))) > _settings.door_interact_range_m:
		return ActionResult.failure(REASON_TOO_FAR)
	return _set_door(world, structure, definition, open, player_id)


# ------------------------------------------------------------ server rules

## Places a structure as a server rule: no actor and no range, everything
## else as for a player (checks 3-5 and 7-10 of the header). `placed_by` is
## the player who may demolish it ("" = nobody).
func place_structure(world: ServerWorld, definition_id: String, tile: Vector2i, rotation: int, placed_by: String = "") -> ActionResult:
	if world == null:
		return ActionResult.failure(REASON_UNAVAILABLE)
	var reason: String = _request_reason(world, definition_id, tile, rotation)
	if not reason.is_empty():
		return ActionResult.failure(reason)
	var definition: StructureDefinition = _catalog.get_definition(definition_id)
	return _place(world, definition, tile, rotation, StructureGrid.slot_of(definition.placement, tile, rotation), placed_by)


## Removes a structure as a server rule. Failure: unknown_structure.
func remove_structure(world: ServerWorld, structure_id: String) -> ActionResult:
	var structure: StructureInstance = _structures.get(structure_id, null)
	if world == null or structure == null:
		return ActionResult.failure(REASON_UNKNOWN_STRUCTURE)
	return _remove(world, structure, "")


## Opens or closes a door as a server rule. Failures: unknown_structure,
## not_a_door, structure_not_usable, door_already_in_state,
## blocked_by_entity.
func set_door_open(world: ServerWorld, structure_id: String, open: bool) -> ActionResult:
	var structure: StructureInstance = _structures.get(structure_id, null)
	if world == null or structure == null:
		return ActionResult.failure(REASON_UNKNOWN_STRUCTURE)
	var definition: StructureDefinition = _catalog.get_definition(structure.definition_id)
	if definition == null or not definition.is_door:
		return ActionResult.failure(REASON_NOT_A_DOOR)
	return _set_door(world, structure, definition, open, "")


# ------------------------------------------------------------ read surface

func has_structure(structure_id: String) -> bool:
	return _structures.has(structure_id)


## Read-only view of one structure (null if it is not in memory). Do not
## mutate.
func get_structure(structure_id: String) -> StructureInstance:
	return _structures.get(structure_id, null)


## Ids of the structures in memory, in the order they came into memory.
func structure_ids() -> PackedStringArray:
	return PackedStringArray(_structures.keys())


func structure_count() -> int:
	return _structures.size()


## Id of the structure in a slot (StructureGrid.slot_of), "" when it is free.
func structure_id_at(slot: Vector3i) -> String:
	return _slots.get(StructureGrid.slot_key(slot), "")


## True when movement cannot cross this edge slot now.
func is_edge_blocked(slot: Vector3i) -> bool:
	return _blocking.has(StructureGrid.slot_key(slot))


## Number of edges that block movement now.
func blocking_edge_count() -> int:
	return _blocking.size()


## The slot a structure takes (its definition decides tile or edge).
func slot_of_structure(structure_id: String) -> Vector3i:
	var structure: StructureInstance = _structures.get(structure_id, null)
	return _slot_of(structure) if structure != null else Vector3i.ZERO


## What everybody may know about a structure (replication row):
##   {structure_id, definition_id, x, z, rotation, state, door_open,
##    health_fraction (0..1)}
## Not in it: who placed it, the shelter, the costs.
func public_row(structure: StructureInstance) -> Dictionary:
	var definition: StructureDefinition = _catalog.get_definition(structure.definition_id)
	var max_health: float = definition.max_health if definition != null else 0.0
	return {
		KEY_STRUCTURE_ID: structure.structure_id,
		KEY_DEFINITION_ID: structure.definition_id,
		KEY_X: structure.tile.x,
		KEY_Z: structure.tile.y,
		KEY_ROTATION: structure.rotation,
		KEY_STATE: StructureInstance.state_name(structure.construction_state),
		KEY_DOOR_OPEN: structure.door_open,
		KEY_HEALTH_FRACTION: clampf(structure.health / max_health, 0.0, 1.0) if max_health > 0.0 else 0.0,
	}


## Public rows of every structure in memory, in structure_ids() order.
func rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for structure_id: String in _structures:
		result.append(public_row(_structures[structure_id]))
	return result


## Ids of the structures of one cell that are in memory, sorted.
func structure_ids_in_cell(world: ServerWorld, cell_id: String) -> PackedStringArray:
	return world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_STRUCTURE)


## Public rows of the structures of one cell, sorted by id.
func rows_in_cell(world: ServerWorld, cell_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for structure_id: String in structure_ids_in_cell(world, cell_id):
		if _structures.has(structure_id):
			result.append(public_row(_structures[structure_id]))
	return result


## Returns and clears the events recorded since the previous call (oldest
## first). At most `max_pending_events` are kept between calls.
func drain_events() -> Array[Dictionary]:
	var drained: Array[Dictionary] = _events
	_events = []
	return drained


# ------------------------------------------------------------ ServerSystem

func on_registered(world: ServerWorld) -> void:
	_world_ref = weakref(world)


func constrains_movement() -> bool:
	return true


## Completed walls and closed doors stop the step; see the header.
func resolve_movement_step(mover_kind: String, from: Vector3, to: Vector3) -> Vector3:
	if _blocking.is_empty():
		return to
	return grid.resolve_step(from, to, _blocking, _settings.collision_skin_m, _sliding_kinds.has(mover_kind))


## The structures that are NOT saved with a cell document ({} = none): all
## of them in a world without a saved cell store, normally none on a
## dedicated server.
func to_world_document() -> Dictionary:
	var world: ServerWorld = _world()
	var structures: Array[Dictionary] = []
	for structure_id: String in _structures:
		var structure: StructureInstance = _structures[structure_id]
		if world != null and world.saves_cell_document(structure.cell_id):
			continue
		structures.append(structure.to_dict())
	if structures.is_empty():
		return {}
	return {"schema_version": SCHEMA_VERSION, KEY_STRUCTURES: structures}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var world: ServerWorld = _world()
	if world == null:
		return PackedStringArray(["building: not registered with a world"])
	var errors: PackedStringArray = []
	var restored: Array[StructureInstance] = _read_structures(document, SCHEMA_VERSION, "building", true, errors)
	if not errors.is_empty():
		return errors
	for structure: StructureInstance in restored:
		_adopt(world, structure)
	return errors


# ------------------------------------------------------------ world cells

## The structures of one cell as save data ({} = none), sorted by id.
func to_cell_document(cell_id: String) -> Dictionary:
	var world: ServerWorld = _world()
	if world == null:
		return {}
	var structures: Array[Dictionary] = []
	for structure_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_STRUCTURE):
		if _structures.has(structure_id):
			structures.append(_structures[structure_id].to_dict())
	if structures.is_empty():
		return {}
	return {"schema_version": CELL_SCHEMA_VERSION, KEY_STRUCTURES: structures}


## Brings the saved structures of a cell back, exactly as they were saved
## (ids, slot, state, health, door). Validates first: on any error nothing
## changes. A structure that is already in memory wins over its saved copy,
## a structure whose id was retired stays gone, and a saved structure whose
## slot is taken by another structure in memory is left out (all are
## skipped and logged; this only happens when a cell file is older than the
## rest of the save). The cell of each structure is decided by its slot, not
## by `cell_id`, so documents cut with another cell grid restore as well.
func restore_cell_document(world: ServerWorld, cell_id: String, document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	var restored: Array[StructureInstance] = _read_structures(document, CELL_SCHEMA_VERSION, "building: cell %s" % cell_id, false, errors)
	if not errors.is_empty():
		return errors
	for structure: StructureInstance in restored:
		_adopt(world, structure)
	return errors


## Forgets the structures of a cell (it was saved). Their ids are released,
## not retired: they still exist.
func release_cell(world: ServerWorld, cell_id: String) -> void:
	for structure_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_STRUCTURE):
		var structure: StructureInstance = _structures.get(structure_id, null)
		if structure != null:
			_forget(structure)
		world.cell_index.remove(structure_id)
		_registry.release(structure_id)


# ------------------------------------------------------------ internals

func _world() -> ServerWorld:
	return _world_ref.get_ref() as ServerWorld if _world_ref != null else null


## "" when the player may make a building request now: it is in the world
## and no system blocks its actions (dead, asleep).
func _actor_block_reason(world: ServerWorld, player_id: String) -> String:
	if world == null or not world.is_online(player_id) or world.get_player(player_id) == null:
		return ServerWorld.REASON_NOT_ONLINE
	return world.player_action_block_reason(player_id)


## "" when the request names an existing definition, a rotation and a tile
## of the play area.
func _request_reason(world: ServerWorld, definition_id: String, tile: Vector2i, rotation: int) -> String:
	if not _catalog.has(definition_id):
		return REASON_UNKNOWN_DEFINITION
	if not StructureGrid.is_valid_rotation(rotation):
		return REASON_BAD_ROTATION
	if not grid.is_tile_inside(tile, world.gameplay.world_half_extent_m):
		return REASON_OUT_OF_BOUNDS
	return ""


func _slot_of(structure: StructureInstance) -> Vector3i:
	var definition: StructureDefinition = _catalog.get_definition(structure.definition_id)
	var placement: int = definition.placement if definition != null else StructureDefinition.Placement.TILE
	return StructureGrid.slot_of(placement, structure.tile, structure.rotation)


## The world-state checks of a placement and the placement itself.
func _place(world: ServerWorld, definition: StructureDefinition, tile: Vector2i, rotation: int, slot: Vector3i, placed_by: String) -> ActionResult:
	var cell_id: String = world.cell_id_at(grid.slot_home(slot))
	if not world.is_cell_loaded(cell_id):
		return ActionResult.failure(REASON_CELL_NOT_LOADED)
	if _slots.has(StructureGrid.slot_key(slot)):
		return ActionResult.failure(REASON_SLOT_OCCUPIED)
	var door_open: bool = definition.is_door and _settings.door_starts_open
	var will_block: bool = _settings.instant_completion and definition.blocks_movement and not door_open
	if will_block and _is_entity_in_the_way(world, slot):
		return ActionResult.failure(REASON_BLOCKED_BY_ENTITY)
	if world.cell_index.count_in_cell(cell_id, ENTITY_KIND_STRUCTURE) >= _settings.max_structures_per_cell:
		return ActionResult.failure(REASON_LIMIT)
	var structure_id: String = _ids.next_id(ENTITY_KIND_STRUCTURE)
	if structure_id.is_empty() or _registry.register(structure_id, ENTITY_KIND_STRUCTURE) != OK:
		GameLogger.error("building", "structure id could not be registered", {"entity_id": structure_id, "definition_id": definition.definition_id, "operation": "place"})
		return ActionResult.failure(REASON_ID_FAILED)
	var structure: StructureInstance = StructureInstance.new()
	structure.structure_id = structure_id
	structure.definition_id = definition.definition_id
	structure.tile = tile
	structure.rotation = rotation
	structure.construction_state = StructureInstance.State.COMPLETED if _settings.instant_completion else StructureInstance.State.BLUEPRINT
	structure.health = definition.max_health if _settings.instant_completion else 0.0
	structure.material_quality = _settings.default_material_quality
	for item_id: String in definition.build_costs:
		structure.inventory_costs[item_id] = definition.build_costs[item_id]
	structure.last_modified_at = _clock.world_time_sec
	structure.placed_by = placed_by
	structure.door_open = door_open
	_structures[structure_id] = structure
	_index(world, structure, definition)
	GameLogger.info("building", "structure placed", {"entity_id": structure_id, "definition_id": definition.definition_id, "player_id": placed_by, "cell_id": structure.cell_id, "x": tile.x, "z": tile.y, "rotation": rotation})
	return ActionResult.success(_push_event(EVENT_PLACED, structure, placed_by, {}))


func _remove(world: ServerWorld, structure: StructureInstance, player_id: String) -> ActionResult:
	_forget(structure)
	world.cell_index.remove(structure.structure_id)
	# Tombstoned: the id of a demolished structure is never used again.
	_registry.remove(structure.structure_id)
	structure.last_modified_at = _clock.world_time_sec
	GameLogger.info("building", "structure removed", {"entity_id": structure.structure_id, "definition_id": structure.definition_id, "player_id": player_id, "cell_id": structure.cell_id})
	return ActionResult.success(_push_event(EVENT_REMOVED, structure, player_id, {}))


func _set_door(world: ServerWorld, structure: StructureInstance, definition: StructureDefinition, open: bool, player_id: String) -> ActionResult:
	if not structure.is_standing():
		return ActionResult.failure(REASON_NOT_USABLE)
	if structure.door_open == open:
		return ActionResult.failure(REASON_DOOR_ALREADY_IN_STATE)
	if not open and definition.blocks_movement and _is_entity_in_the_way(world, _slot_of(structure)):
		return ActionResult.failure(REASON_BLOCKED_BY_ENTITY)
	structure.door_open = open
	structure.last_modified_at = _clock.world_time_sec
	_refresh_blocking(structure, definition)
	GameLogger.info("building", "door changed", {"entity_id": structure.structure_id, "player_id": player_id, "open": open})
	return ActionResult.success(_push_event(EVENT_CHANGED, structure, player_id, {"cause": CAUSE_DOOR}))


## Puts a structure that just came into memory into the occupancy index,
## the cell index and (when it blocks) the blocking set.
func _index(world: ServerWorld, structure: StructureInstance, definition: StructureDefinition) -> void:
	var slot: Vector3i = StructureGrid.slot_of(definition.placement, structure.tile, structure.rotation)
	structure.cell_id = world.cell_id_at(grid.slot_home(slot))
	world.cell_index.put(structure.structure_id, ENTITY_KIND_STRUCTURE, structure.cell_id)
	_slots[StructureGrid.slot_key(slot)] = structure.structure_id
	_refresh_blocking(structure, definition)


## Takes a structure out of this system's own maps (not the cell index, not
## the registry: the caller decides between remove and release).
func _forget(structure: StructureInstance) -> void:
	var key: int = StructureGrid.slot_key(_slot_of(structure))
	if _slots.get(key, "") == structure.structure_id:
		_slots.erase(key)
		_blocking.erase(key)
	_structures.erase(structure.structure_id)


## Registers a restored structure and brings it into memory.
func _adopt(world: ServerWorld, structure: StructureInstance) -> void:
	_registry.register(structure.structure_id, ENTITY_KIND_STRUCTURE)
	_ids.reserve_existing_id(structure.structure_id)
	_structures[structure.structure_id] = structure
	_index(world, structure, _catalog.get_definition(structure.definition_id))


func _refresh_blocking(structure: StructureInstance, definition: StructureDefinition) -> void:
	var key: int = StructureGrid.slot_key(StructureGrid.slot_of(definition.placement, structure.tile, structure.rotation))
	if definition.blocks_movement and structure.is_standing() and not (definition.is_door and structure.door_open):
		_blocking[key] = true
	else:
		_blocking.erase(key)


## True when a living player or a living zombie is closer than
## `blocker_clearance_m` to this edge slot. Only the zombies of the cells
## the edge (plus the clearance) touches are looked at.
func _is_entity_in_the_way(world: ServerWorld, slot: Vector3i) -> bool:
	var clearance: float = _settings.blocker_clearance_m
	if clearance <= 0.0:
		return false
	for player_id: String in world.online_player_ids():
		if not world.is_player_dead(player_id) and grid.distance_to_edge(world.get_player(player_id).position, slot) < clearance:
			return true
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	if zombies == null:
		return false
	var ends: PackedVector2Array = grid.edge_ends(slot)
	var seen: Dictionary[String, bool] = {}
	for corner: Vector2 in [ends[0] - Vector2(clearance, clearance), Vector2(ends[1].x + clearance, ends[0].y - clearance), Vector2(ends[0].x - clearance, ends[1].y + clearance), ends[1] + Vector2(clearance, clearance)]:
		var cell_id: String = world.cell_id_at(Vector3(corner.x, 0.0, corner.y))
		if seen.has(cell_id):
			continue
		seen[cell_id] = true
		for zombie_id: String in world.cell_index.entities_in_cell(cell_id, ZombieService.ENTITY_KIND_ZOMBIE):
			var zombie: ZombieState = zombies.get_zombie(zombie_id)
			if zombie != null and zombie.is_alive() and grid.distance_to_edge(zombie.position, slot) < clearance:
				return true
	return false


## Reads and checks the structures of a save document. On any error
## `errors` is filled and the result must not be used. `strict` (the world
## document): a structure whose id is already known or retired is an error.
## Otherwise (a cell document) such a structure, and one whose slot is taken
## by a structure in memory, is skipped and logged.
func _read_structures(document: Dictionary, expected_version: int, context: String, strict: bool, errors: PackedStringArray) -> Array[StructureInstance]:
	var restored: Array[StructureInstance] = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != expected_version:
		errors.append("%s: unsupported schema_version" % context)
		return restored
	var entries: Variant = document.get(KEY_STRUCTURES, null)
	if typeof(entries) != TYPE_ARRAY:
		errors.append("%s: structures must be an array" % context)
		return restored
	var seen_ids: Dictionary[String, bool] = {}
	var seen_slots: Dictionary[int, bool] = {}
	var skipped: PackedStringArray = []
	for entry: Variant in (entries as Array):
		var structure: StructureInstance = StructureInstance.from_dict(entry as Dictionary) if typeof(entry) == TYPE_DICTIONARY else null
		if structure == null:
			errors.append("%s: invalid structure entry" % context)
			continue
		var definition: StructureDefinition = _catalog.get_definition(structure.definition_id)
		if definition == null:
			errors.append("%s: unknown definition %s for %s" % [context, structure.definition_id, structure.structure_id])
			continue
		if structure.health > definition.max_health or (structure.door_open and not definition.is_door):
			errors.append("%s: %s does not fit its definition" % [context, structure.structure_id])
			continue
		var key: int = StructureGrid.slot_key(StructureGrid.slot_of(definition.placement, structure.tile, structure.rotation))
		if seen_ids.has(structure.structure_id) or seen_slots.has(key):
			errors.append("%s: duplicate id or slot %s" % [context, structure.structure_id])
			continue
		seen_ids[structure.structure_id] = true
		seen_slots[key] = true
		var known: bool = _structures.has(structure.structure_id) or _registry.has(structure.structure_id) or _registry.is_tombstoned(structure.structure_id)
		if known or _slots.has(key):
			if strict:
				errors.append("%s: duplicate or removed id, or taken slot: %s" % [context, structure.structure_id])
			else:
				skipped.append(structure.structure_id)
			continue
		restored.append(structure)
	if errors.is_empty() and not skipped.is_empty():
		GameLogger.warning("building", "saved structures skipped: already in memory, removed, or their slot is taken", {"context": context, "structures": ", ".join(skipped), "operation": "restore"})
	return restored


## Records one event: the frame plus the structure's public row.
func _push_event(event_type: String, structure: StructureInstance, player_id: String, fields: Dictionary) -> Dictionary:
	var event: Dictionary = {"event_type": event_type, "world_time": _clock.world_time_sec, "player_id": player_id, "cell_id": structure.cell_id}
	event.merge(public_row(structure))
	event.merge(fields)
	_events.append(event)
	while _events.size() > _settings.max_pending_events:
		_events.pop_front()
		dropped_event_count += 1
	return event
