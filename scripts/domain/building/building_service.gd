class_name BuildingService
extends ServerSystem
## Server-authoritative grid structures: floors, walls, doors (P3-4a,
## docs/04 §2-§4, §10, docs/00 ADR-024, docs/09 §15.4) and how they are
## built: blueprint -> materials -> work -> completed (P3-5, docs/04 §3, §5,
## docs/00 ADR-025, docs/09 §15.5). System id "building". No networking here
## (StructureNetModule), no nodes.
##
## What it owns: every structure that is in memory (StructureInstance), the
## occupancy index (which slot of the building grid holds which structure),
## the set of edges that block movement, and who is working on what (not
## saved). The server alone decides: clients send intents (definition, tile,
## rotation; a structure id; a carried item), never a position of their own,
## an owner, an amount of progress or a result.
##
## Public API (every ActionResult failure carries a reason code below):
##   try_place(world, player_id, definition_id, tile, rotation)
##   try_deliver(world, player_id, structure_id, item_instance_id, quantity)
##   try_set_work(world, player_id, structure_id, working)
##   try_cancel(world, player_id, structure_id)
##   try_demolish(world, player_id, structure_id)
##   try_set_door(world, player_id, structure_id, open)
##       requests of a player, checked against the player's server state
##   place_structure(world, definition_id, tile, rotation, placed_by = "")
##   complete_structure(world, structure_id)
##   remove_structure(world, structure_id, refund_percent = 0)
##   set_door_open(world, structure_id, open)
##   stop_work(player_id, reason)
##       the same changes as server rules (no actor, no range)
##   has_structure, get_structure (read-only), structure_ids,
##   structure_count, structure_id_at(slot), is_edge_blocked(slot),
##   public_row, rows, rows_in_cell, structure_ids_in_cell,
##   work_of(player_id), workers_of(structure_id), worker_rows(),
##   worker_count(), awaiting_clearance_count()
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
## Construction (P3-5; every rule the docs leave open is PROVISIONAL,
## docs/15 §15.5):
##   - A placement makes a `blueprint`: it takes its slot, blocks nothing,
##     costs nothing yet and has no work done. `inventory_costs` is what it
##     needs (the definition's build_costs when it was placed).
##     BuildingSettings.instant_completion (off by default; tests and
##     development) makes it `completed` at once instead, with nothing paid.
##   - try_deliver: a player in range puts carried items of a kind the piece
##     still needs into it. Only what is still missing is taken; the units
##     leave the inventory (InventoryService.take_items) and are counted in
##     `delivered_materials`. Checks, in order: not_online, player_dead /
##     player_resting, unknown_structure, structure_not_under_construction,
##     too_far, materials_complete, then the item: item_not_in_inventory
##     (unknown, lying in the world or somebody else's: one reason, so
##     nothing can be probed), bad_quantity, material_not_needed. With
##     `item_instance_id` "" every carried stack of a needed kind is used
##     (no_materials_carried when there is none).
##   - try_set_work(.., true): the player starts working on the piece. Work
##     is done in step(): every tick each worker adds
##     action_delta * handling_multiplier seconds of work (SurvivalService:
##     wounds and fatigue; 1 without a survival system); the workers of one
##     piece simply add up. progress = work / definition.build_work_sec, and
##     it never exceeds material_share() (docs/04 §5). The piece becomes
##     `constructing` with the first bit of work. Checks, in order:
##     not_online, player_dead / player_resting, unknown_structure,
##     structure_not_under_construction, too_far, already_working,
##     blocked_by_entity (the work is done, see below), materials_missing
##     (nothing can be done until more is delivered), too_many_workers. A
##     player works on one piece at a time: starting on another one stops
##     the work on the first ("switched").
##   - A worker stops (event structure_work_stopped with the reason) when it
##     asks to (try_set_work(.., false): "stopped"), is further away than
##     work_range_m (too_far), dies (player_dead), falls asleep
##     (player_resting), leaves the world (not_online), when the materials
##     run out (materials_missing), the work is done (work_finished) or the
##     piece goes away (structure_removed, structure_unloaded).
##   - Completion: at progress 1 the piece becomes `completed`, gets its
##     full health and starts to block. A blocking piece does not complete
##     while a living player or zombie stands within blocker_clearance_m of
##     its edge: it stays `constructing` at progress 1, nobody has to work
##     again, and it completes by itself once the edge is clear (looked at
##     every completion_retry_interval_sec).
##   - try_cancel removes an UNFINISHED piece, try_demolish a finished one;
##     each refuses the other state (structure_not_under_construction /
##     structure_under_construction), so a client that is one step behind
##     never demolishes what it meant to cancel. Only the player who placed
##     the piece may do either (not_owner). Both return a share of the
##     DELIVERED materials (StructureDefinition.cancel_refund_percent /
##     demolish_refund_percent, each kind rounded down) as new world items at
##     the centre of the piece's home tile (InventoryService.
##     place_world_items); the rest is gone. Nothing is ever returned that
##     was not delivered, so a piece completed by the dev switch or by a
##     server rule returns nothing.
##   - any living player may place, deliver, work and open or close any door.
##   - only a standing piece (completed or damaged) blocks movement.
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
## player_id ("" = a server rule) and cell_id). Structure events also carry
## the public row of the structure (structure_id, definition_id, x, z,
## rotation, state, door_open, health_fraction, progress, delivered,
## required):
##   structure_placed     the structure exists now
##   structure_changed    {cause}: "door" its door was opened or closed;
##                        "materials" {delivered_now: {item id: units}} a
##                        player delivered materials; "progress" work moved
##                        it on (recorded when it became `constructing`,
##                        every BuildingSettings.progress_event_step, when
##                        the last worker stopped and when it is finished but
##                        waits for a clear edge); "completed"
##   structure_removed    {cause: "cancelled" / "demolished" / "" (server
##                        rule), refund: {item id: units},
##                        refund_item_instance_ids} the row is its last state
## Work events carry structure_id only:
##   structure_work_started   the player works on the structure now
##   structure_work_stopped   {reason} it no longer does
##
## Save: per cell document `systems.building` =
##   {schema_version, structures: [StructureInstance.to_dict()]}
## and world_state.json `systems.building`, the same shape, for structures
## that are not saved with a cell document (a world without a saved cell
## store). A save without either has no structures. Schema 2 (P3-5) added
## construction_progress and delivered_materials to every structure;
## schema 1 documents (P3-4a) are read and upgraded
## (StructureInstance.upgrade_v1_entry). Not saved: events, who is working
## (after a restart or a cell reload nobody works; the progress stays).

const SYSTEM_ID: String = "building"
const SCHEMA_VERSION: int = 2
## Version of this system's part of a cell document.
const CELL_SCHEMA_VERSION: int = 2
## The schema before P3-5 (no construction fields); still read.
const SCHEMA_VERSION_P3_4A: int = 1
const ENTITY_KIND_STRUCTURE: String = StructureInstance.ENTITY_KIND
const KEY_STRUCTURES: String = "structures"

const EVENT_PLACED: String = "structure_placed"
const EVENT_CHANGED: String = "structure_changed"
const EVENT_REMOVED: String = "structure_removed"
const EVENT_WORK_STARTED: String = "structure_work_started"
const EVENT_WORK_STOPPED: String = "structure_work_stopped"
const CAUSE_DOOR: String = "door"
const CAUSE_MATERIALS: String = "materials"
const CAUSE_PROGRESS: String = "progress"
const CAUSE_COMPLETED: String = "completed"
const CAUSE_CANCELLED: String = "cancelled"
const CAUSE_DEMOLISHED: String = "demolished"

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
## P3-5. The request needs a piece that is still being built / a piece that
## is not being built any more.
const REASON_NOT_UNDER_CONSTRUCTION: String = "structure_not_under_construction"
const REASON_UNDER_CONSTRUCTION: String = "structure_under_construction"
## Every material is there already.
const REASON_MATERIALS_COMPLETE: String = "materials_complete"
## The piece does not need this kind of item (any more).
const REASON_MATERIAL_NOT_NEEDED: String = "material_not_needed"
## The player carries nothing the piece still needs.
const REASON_NO_MATERIALS: String = "no_materials_carried"
## Work cannot go on until more materials are delivered. Also a reason a
## worker stops.
const REASON_MATERIALS_MISSING: String = "materials_missing"
const REASON_ALREADY_WORKING: String = "already_working"
const REASON_NOT_WORKING: String = "not_working"
const REASON_TOO_MANY_WORKERS: String = "too_many_workers"
## The materials to return could not be put into the world (nothing changed).
const REASON_REFUND_FAILED: String = "refund_failed"
## Why a worker stopped, besides the refusal reasons above (too_far,
## player_dead, player_resting, not_online, materials_missing).
const STOP_REQUESTED: String = "stopped"
const STOP_SWITCHED: String = "switched"
const STOP_FINISHED: String = "work_finished"
const STOP_REMOVED: String = "structure_removed"
const STOP_UNLOADED: String = "structure_unloaded"
## try_deliver: "" as the item = every carried stack of a needed kind;
## 0 as the quantity = as many units as the piece still needs.
const ANY_CARRIED_ITEM: String = ""
const AS_MUCH_AS_NEEDED: int = 0
## Float slack when a progress is compared with the material share: a save
## is text, and a progress read back from it may differ in its last bits.
const PROGRESS_TOLERANCE: float = 0.000001

## Public row keys (events, StructureNetModule).
const KEY_STRUCTURE_ID: String = "structure_id"
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_X: String = "x"
const KEY_Z: String = "z"
const KEY_ROTATION: String = "rotation"
const KEY_STATE: String = "state"
const KEY_DOOR_OPEN: String = "door_open"
const KEY_HEALTH_FRACTION: String = "health_fraction"
## P3-5: share of the work done (0..1), materials delivered and materials
## needed ({item definition id: units}).
const KEY_PROGRESS: String = "progress"
const KEY_DELIVERED: String = "delivered"
const KEY_REQUIRED: String = "required"

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
## Who works on what (not saved): player id -> structure id, in the order
## the work started, and structure id -> its workers in that order.
var _work_of: Dictionary[String, String] = {}
var _crews: Dictionary[String, PackedStringArray] = {}
## Progress each structure had in the last event recorded for it (or when
## it came into memory): decides when the next progress event is due.
var _announced: Dictionary[String, float] = {}
## Structures whose work is done but whose edge was not clear: structure id
## -> true. Looked at again every completion_retry_interval_sec.
var _awaiting: Dictionary[String, bool] = {}
var _retry_elapsed: float = 0.0


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

## A player places a structure (docs/04 §3 step 4-6): a blueprint that
## waits for materials and work. See the header for the checks. Success
## event: structure_placed.
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


## A player delivers materials to an unfinished structure (docs/04 §3 step
## 6, §5). `item_instance_id` names a carried stack and `quantity` how many
## units of it at most (AS_MUCH_AS_NEEDED = as many as the piece still
## needs; more than the stack holds is bad_quantity); ANY_CARRIED_ITEM takes
## from every carried stack of a needed kind, in slot order, and then
## `quantity` must be AS_MUCH_AS_NEEDED. Never more is taken than is still
## missing. See the header for the checks. Success event: structure_changed
## {cause: "materials", delivered_now: {item definition id: units taken}}.
func try_deliver(world: ServerWorld, player_id: String, structure_id: String, item_instance_id: String = ANY_CARRIED_ITEM, quantity: int = AS_MUCH_AS_NEEDED) -> ActionResult:
	var blocked: String = _actor_block_reason(world, player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var structure: StructureInstance = _structures.get(structure_id, null)
	if structure == null:
		return ActionResult.failure(REASON_UNKNOWN_STRUCTURE)
	if not structure.is_under_construction():
		return ActionResult.failure(REASON_NOT_UNDER_CONSTRUCTION)
	var player: PlayerState = world.get_player(player_id)
	if StructureGrid.flat_distance(player.position, grid.slot_anchor(_slot_of(structure))) > _settings.deliver_range_m:
		return ActionResult.failure(REASON_TOO_FAR)
	var missing: Dictionary[String, int] = structure.missing_materials()
	if missing.is_empty():
		return ActionResult.failure(REASON_MATERIALS_COMPLETE)
	var takes: Array = []
	if item_instance_id == ANY_CARRIED_ITEM:
		if quantity != AS_MUCH_AS_NEEDED:
			return ActionResult.failure(InventoryService.REASON_BAD_QUANTITY)
		for carried: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
			var wanted: int = missing.get(carried.definition_id, 0)
			if wanted <= 0:
				continue
			var units: int = mini(carried.quantity, wanted)
			takes.append({InventoryService.OFFER_ITEM_ID: carried.item_instance_id, InventoryService.OFFER_QUANTITY: units})
			missing[carried.definition_id] = wanted - units
		if takes.is_empty():
			return ActionResult.failure(REASON_NO_MATERIALS)
	else:
		var item: ItemInstance = world.inventory.get_item(item_instance_id)
		# One reason for an id nobody has, an item lying in the world and an
		# item somebody else carries: a request cannot probe item ids.
		if item == null or item.location_type != ItemInstance.LOCATION_INVENTORY or item.location_id != player.inventory_id:
			return ActionResult.failure(InventoryService.REASON_NOT_IN_INVENTORY)
		if quantity < AS_MUCH_AS_NEEDED or quantity > item.quantity:
			return ActionResult.failure(InventoryService.REASON_BAD_QUANTITY)
		var needed: int = missing.get(item.definition_id, 0)
		if needed <= 0:
			return ActionResult.failure(REASON_MATERIAL_NOT_NEEDED)
		var offered: int = item.quantity if quantity == AS_MUCH_AS_NEEDED else quantity
		takes.append({InventoryService.OFFER_ITEM_ID: item_instance_id, InventoryService.OFFER_QUANTITY: mini(offered, needed)})
	# The units leave the inventory and are counted in the structure in this
	# one call: no save can see the one without the other.
	var taken: ActionResult = world.inventory.take_items(player.inventory_id, takes)
	if not taken.ok:
		return ActionResult.failure(taken.reason)
	var delivered_now: Dictionary = {}
	for entry: Dictionary in taken.event["taken"]:
		var item_id: String = entry["definition_id"]
		var units: int = entry["quantity"]
		structure.delivered_materials[item_id] = int(structure.delivered_materials.get(item_id, 0)) + units
		delivered_now[item_id] = int(delivered_now.get(item_id, 0)) + units
	structure.last_modified_at = _clock.world_time_sec
	GameLogger.info("building", "materials delivered", {"entity_id": structure_id, "player_id": player_id, "materials": str(delivered_now), "material_share": structure.material_share()})
	return ActionResult.success(_push_event(EVENT_CHANGED, structure, player_id, {"cause": CAUSE_MATERIALS, "delivered_now": delivered_now}))


## A player starts (`working` true) or stops working on an unfinished
## structure. The request names the state it wants, not a toggle. Starting:
## see the header for the checks; a player that works elsewhere switches.
## Stopping: not_online, not_working (the player does not work on THAT
## structure). Success event: structure_work_started /
## structure_work_stopped {reason: "stopped"}.
func try_set_work(world: ServerWorld, player_id: String, structure_id: String, working: bool) -> ActionResult:
	if not working:
		if world == null or not world.is_online(player_id):
			return ActionResult.failure(ServerWorld.REASON_NOT_ONLINE)
		if structure_id.is_empty() or _work_of.get(player_id, "") != structure_id:
			return ActionResult.failure(REASON_NOT_WORKING)
		return ActionResult.success(_stop_work(player_id, STOP_REQUESTED))
	var blocked: String = _actor_block_reason(world, player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var structure: StructureInstance = _structures.get(structure_id, null)
	if structure == null:
		return ActionResult.failure(REASON_UNKNOWN_STRUCTURE)
	if not structure.is_under_construction():
		return ActionResult.failure(REASON_NOT_UNDER_CONSTRUCTION)
	if StructureGrid.flat_distance(world.get_player(player_id).position, grid.slot_anchor(_slot_of(structure))) > _settings.work_range_m:
		return ActionResult.failure(REASON_TOO_FAR)
	if _work_of.get(player_id, "") == structure_id:
		return ActionResult.failure(REASON_ALREADY_WORKING)
	if structure.construction_progress >= StructureInstance.FULL_PROGRESS:
		# The work is done: it only waits for whoever stands in its edge.
		return ActionResult.failure(REASON_BLOCKED_BY_ENTITY)
	# (The slack: a saved progress comes back a few float bits smaller.)
	if structure.construction_progress >= structure.material_share() - PROGRESS_TOLERANCE:
		return ActionResult.failure(REASON_MATERIALS_MISSING)
	var crew: PackedStringArray = _crews.get(structure_id, PackedStringArray())
	if crew.size() >= _settings.max_workers_per_structure:
		return ActionResult.failure(REASON_TOO_MANY_WORKERS)
	if _work_of.has(player_id):
		_stop_work(player_id, STOP_SWITCHED)
	_work_of[player_id] = structure_id
	crew.append(player_id)
	_crews[structure_id] = crew
	GameLogger.info("building", "work started", {"entity_id": structure_id, "player_id": player_id, "workers": crew.size()})
	return ActionResult.success(_push_work_event(EVENT_WORK_STARTED, player_id, structure_id, structure.cell_id, ""))


## A player cancels an unfinished structure it placed: the piece leaves the
## world, its id is never used again, and the definition's
## cancel_refund_percent of the delivered materials comes back as world
## items. Checks, in order: not_online, player_dead / player_resting,
## unknown_structure, structure_not_under_construction (a finished piece is
## demolished, not cancelled), not_owner, too_far (demolish_range_m),
## refund_failed. Success event: structure_removed {cause: "cancelled"}.
func try_cancel(world: ServerWorld, player_id: String, structure_id: String) -> ActionResult:
	var blocked: String = _actor_block_reason(world, player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var structure: StructureInstance = _structures.get(structure_id, null)
	if structure == null:
		return ActionResult.failure(REASON_UNKNOWN_STRUCTURE)
	if not structure.is_under_construction():
		return ActionResult.failure(REASON_NOT_UNDER_CONSTRUCTION)
	if structure.placed_by != player_id:
		return ActionResult.failure(REASON_NOT_OWNER)
	if StructureGrid.flat_distance(world.get_player(player_id).position, grid.slot_anchor(_slot_of(structure))) > _settings.demolish_range_m:
		return ActionResult.failure(REASON_TOO_FAR)
	var definition: StructureDefinition = _catalog.get_definition(structure.definition_id)
	return _remove(world, structure, player_id, definition.cancel_refund_percent if definition != null else 0, CAUSE_CANCELLED)


## A player demolishes a finished structure: it leaves the world, its id is
## never used again, and the definition's demolish_refund_percent of the
## delivered materials comes back as world items. Only the player who
## placed it may (PROVISIONAL). Checks, in order: not_online, player_dead /
## player_resting, unknown_structure (also a structure of a cell that is not
## in memory), structure_under_construction (an unfinished piece is
## cancelled, not demolished), not_owner, too_far, refund_failed. Success
## event: structure_removed {cause: "demolished"}.
func try_demolish(world: ServerWorld, player_id: String, structure_id: String) -> ActionResult:
	var blocked: String = _actor_block_reason(world, player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var structure: StructureInstance = _structures.get(structure_id, null)
	if structure == null:
		return ActionResult.failure(REASON_UNKNOWN_STRUCTURE)
	if structure.is_under_construction():
		return ActionResult.failure(REASON_UNDER_CONSTRUCTION)
	if structure.placed_by != player_id:
		return ActionResult.failure(REASON_NOT_OWNER)
	if StructureGrid.flat_distance(world.get_player(player_id).position, grid.slot_anchor(_slot_of(structure))) > _settings.demolish_range_m:
		return ActionResult.failure(REASON_TOO_FAR)
	var definition: StructureDefinition = _catalog.get_definition(structure.definition_id)
	return _remove(world, structure, player_id, definition.demolish_refund_percent if definition != null else 0, CAUSE_DEMOLISHED)


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


## Completes an unfinished structure as a server rule, whatever materials
## and work it has (seeded buildings, tests). All or nothing: a blocking
## piece with somebody in its edge stays as it is. Its workers stop.
## Nothing is paid, so nothing more is refunded later than was delivered.
## Failures: unknown_structure, structure_not_under_construction,
## blocked_by_entity. Success event: structure_changed {cause: "completed"}.
func complete_structure(world: ServerWorld, structure_id: String) -> ActionResult:
	var structure: StructureInstance = _structures.get(structure_id, null)
	if world == null or structure == null:
		return ActionResult.failure(REASON_UNKNOWN_STRUCTURE)
	if not structure.is_under_construction():
		return ActionResult.failure(REASON_NOT_UNDER_CONSTRUCTION)
	var definition: StructureDefinition = _catalog.get_definition(structure.definition_id)
	if _blocks_when_standing(structure, definition) and _is_entity_in_the_way(world, _slot_of(structure)):
		return ActionResult.failure(REASON_BLOCKED_BY_ENTITY)
	_release_crew(structure_id, STOP_FINISHED)
	return ActionResult.success(_complete(structure, definition))


## Removes a structure as a server rule, in whatever state it is.
## `refund_percent` (0..100) of its delivered materials comes back as world
## items; the default returns nothing. Failures: unknown_structure,
## refund_failed.
func remove_structure(world: ServerWorld, structure_id: String, refund_percent: int = 0) -> ActionResult:
	var structure: StructureInstance = _structures.get(structure_id, null)
	if world == null or structure == null:
		return ActionResult.failure(REASON_UNKNOWN_STRUCTURE)
	return _remove(world, structure, "", refund_percent, "")


## Stops a player's work as a server rule ({} when it was not working).
## Returns the structure_work_stopped event.
func stop_work(player_id: String, reason: String) -> Dictionary:
	return _stop_work(player_id, reason)


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


## The structure a player is working on, "" when it is not working.
func work_of(player_id: String) -> String:
	return _work_of.get(player_id, "")


## The players working on a structure, in the order they started (a copy).
func workers_of(structure_id: String) -> PackedStringArray:
	return _crews.get(structure_id, PackedStringArray()).duplicate()


## Everybody who is working: [player_id, structure_id] rows in the order
## the work started (StructureNetModule: join fragment).
func worker_rows() -> Array:
	var result: Array = []
	for player_id: String in _work_of:
		result.append([player_id, _work_of[player_id]])
	return result


func worker_count() -> int:
	return _work_of.size()


## Structures whose work is done and that wait for a clear edge.
func awaiting_clearance_count() -> int:
	return _awaiting.size()


## What everybody may know about a structure (replication row):
##   {structure_id, definition_id, x, z, rotation, state, door_open,
##    health_fraction (0..1), progress (0..1), delivered: {item definition
##    id: units}, required: {item definition id: units}}
## A structure and what is in it is something anybody standing there can
## see (docs/00 ADR-009). Not in it: who placed it, the shelter.
func public_row(structure: StructureInstance) -> Dictionary:
	var definition: StructureDefinition = _catalog.get_definition(structure.definition_id)
	var max_health: float = definition.max_health if definition != null else 0.0
	var delivered: Dictionary = {}
	for item_id: String in structure.delivered_materials:
		delivered[item_id] = structure.delivered_materials[item_id]
	var required: Dictionary = {}
	for item_id: String in structure.inventory_costs:
		required[item_id] = structure.inventory_costs[item_id]
	return {
		KEY_STRUCTURE_ID: structure.structure_id,
		KEY_DEFINITION_ID: structure.definition_id,
		KEY_X: structure.tile.x,
		KEY_Z: structure.tile.y,
		KEY_ROTATION: structure.rotation,
		KEY_STATE: StructureInstance.state_name(structure.construction_state),
		KEY_DOOR_OPEN: structure.door_open,
		KEY_HEALTH_FRACTION: clampf(structure.health / max_health, 0.0, 1.0) if max_health > 0.0 else 0.0,
		KEY_PROGRESS: structure.construction_progress,
		KEY_DELIVERED: delivered,
		KEY_REQUIRED: required,
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


## P3-5: the work of this tick. Action time only (docs/00 ADR-006): a
## worker builds as fast at any calendar time scale, and nothing moves while
## the world clock is paused.
func step(world: ServerWorld, action_delta: float, _world_delta: float) -> void:
	if action_delta <= 0.0:
		return
	if not _crews.is_empty():
		_advance_work(world, action_delta)
	if _awaiting.is_empty():
		_retry_elapsed = 0.0
		return
	_retry_elapsed += action_delta
	if _retry_elapsed >= _settings.completion_retry_interval_sec:
		_retry_elapsed = 0.0
		_retry_completions(world)


## A player that left the world works on nothing.
func on_player_offline(_world: ServerWorld, player_id: String) -> void:
	_stop_work(player_id, ServerWorld.REASON_NOT_ONLINE)


## A new character does not inherit the work of the one that died.
func on_character_started(_world: ServerWorld, player_id: String) -> void:
	_stop_work(player_id, SurvivalService.REASON_PLAYER_DEAD)


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
## not retired: they still exist. Whoever worked on one of them stops.
func release_cell(world: ServerWorld, cell_id: String) -> void:
	for structure_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_STRUCTURE):
		_release_crew(structure_id, STOP_UNLOADED)
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
	structure.construction_progress = StructureInstance.FULL_PROGRESS if _settings.instant_completion else StructureInstance.NO_PROGRESS
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


## Takes a structure out of the world and returns `refund_percent` of its
## delivered materials as world items at the centre of its home tile (always
## inside the structure's own cell, which is in memory). The refund is made
## first: when it fails, nothing has changed.
func _remove(world: ServerWorld, structure: StructureInstance, player_id: String, refund_percent: int, cause: String) -> ActionResult:
	var refund: Dictionary[String, int] = StructureDefinition.refund_of(structure.delivered_materials, refund_percent)
	var refund_ids: Array = []
	if not refund.is_empty():
		var placed: ActionResult = world.inventory.place_world_items(refund, structure.cell_id, grid.slot_home(_slot_of(structure)))
		if not placed.ok:
			GameLogger.error("building", "materials could not be returned", {"entity_id": structure.structure_id, "player_id": player_id, "reason": placed.reason, "operation": "remove"})
			return ActionResult.failure(REASON_REFUND_FAILED)
		refund_ids = placed.event["item_instance_ids"]
	_release_crew(structure.structure_id, STOP_REMOVED)
	_forget(structure)
	world.cell_index.remove(structure.structure_id)
	# Tombstoned: the id of a removed structure is never used again.
	_registry.remove(structure.structure_id)
	structure.last_modified_at = _clock.world_time_sec
	var returned: Dictionary = {}
	for item_id: String in refund:
		returned[item_id] = refund[item_id]
	GameLogger.info("building", "structure removed", {"entity_id": structure.structure_id, "definition_id": structure.definition_id, "player_id": player_id, "cell_id": structure.cell_id, "cause": cause, "refund": str(returned)})
	return ActionResult.success(_push_event(EVENT_REMOVED, structure, player_id, {"cause": cause, "refund": returned, "refund_item_instance_ids": refund_ids}))


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
	_announced.erase(structure.structure_id)
	_awaiting.erase(structure.structure_id)


## Registers a restored structure and brings it into memory.
func _adopt(world: ServerWorld, structure: StructureInstance) -> void:
	_registry.register(structure.structure_id, ENTITY_KIND_STRUCTURE)
	_ids.reserve_existing_id(structure.structure_id)
	_structures[structure.structure_id] = structure
	_index(world, structure, _catalog.get_definition(structure.definition_id))
	_announced[structure.structure_id] = structure.construction_progress
	# Finished before it left memory but not completed: it still waits for
	# a clear edge.
	if structure.is_under_construction() and structure.construction_progress >= StructureInstance.FULL_PROGRESS:
		_awaiting[structure.structure_id] = true


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
	var version: Variant = document.get("schema_version", null)
	if not ItemInstance.is_integer_value(version) or (int(version) != expected_version and int(version) != SCHEMA_VERSION_P3_4A):
		errors.append("%s: unsupported schema_version" % context)
		return restored
	var from_p3_4a: bool = int(version) == SCHEMA_VERSION_P3_4A
	var entries: Variant = document.get(KEY_STRUCTURES, null)
	if typeof(entries) != TYPE_ARRAY:
		errors.append("%s: structures must be an array" % context)
		return restored
	var seen_ids: Dictionary[String, bool] = {}
	var seen_slots: Dictionary[int, bool] = {}
	var skipped: PackedStringArray = []
	for entry: Variant in (entries as Array):
		var data: Variant = entry
		if from_p3_4a and typeof(entry) == TYPE_DICTIONARY:
			data = StructureInstance.upgrade_v1_entry(entry as Dictionary)
		var structure: StructureInstance = StructureInstance.from_dict(data as Dictionary) if typeof(data) == TYPE_DICTIONARY else null
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
		if not _is_construction_consistent(structure):
			errors.append("%s: %s has a progress that does not fit its state or its materials" % [context, structure.structure_id])
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
	if event_type != EVENT_REMOVED:
		_announced[structure.structure_id] = structure.construction_progress
	_record(event)
	return event


## Records one work event (no structure row: nothing about the structure
## changed).
func _push_work_event(event_type: String, player_id: String, structure_id: String, cell_id: String, reason: String) -> Dictionary:
	var event: Dictionary = {"event_type": event_type, "world_time": _clock.world_time_sec, "player_id": player_id, "cell_id": cell_id, KEY_STRUCTURE_ID: structure_id}
	if event_type == EVENT_WORK_STOPPED:
		event["reason"] = reason
	_record(event)
	return event


func _record(event: Dictionary) -> void:
	_events.append(event)
	while _events.size() > _settings.max_pending_events:
		_events.pop_front()
		dropped_event_count += 1


# ------------------------------------------------------------ construction

## True when the standing piece would stop movement on its edge.
func _blocks_when_standing(structure: StructureInstance, definition: StructureDefinition) -> bool:
	return definition != null and definition.blocks_movement and not (definition.is_door and structure.door_open)


## The state, the progress and the materials of a saved structure agree
## with each other.
func _is_construction_consistent(structure: StructureInstance) -> bool:
	var progress: float = structure.construction_progress
	if structure.is_standing():
		return progress >= StructureInstance.FULL_PROGRESS
	if structure.construction_state == StructureInstance.State.BLUEPRINT and progress > StructureInstance.NO_PROGRESS:
		return false
	if structure.construction_state == StructureInstance.State.CONSTRUCTING and progress <= StructureInstance.NO_PROGRESS:
		return false
	return not structure.is_under_construction() or progress <= structure.material_share() + PROGRESS_TOLERANCE


## "" while the player can go on working on `structure`.
func _work_block_reason(world: ServerWorld, player_id: String, structure: StructureInstance) -> String:
	var blocked: String = _actor_block_reason(world, player_id)
	if not blocked.is_empty():
		return blocked
	if StructureGrid.flat_distance(world.get_player(player_id).position, grid.slot_anchor(_slot_of(structure))) > _settings.work_range_m:
		return REASON_TOO_FAR
	return ""


## One tick of work: every worker that can still work adds
## action_delta * its handling multiplier seconds of work to its structure.
func _advance_work(world: ServerWorld, action_delta: float) -> void:
	var survival: SurvivalService = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	for structure_id: String in _crews.keys():
		var structure: StructureInstance = _structures.get(structure_id, null)
		if structure == null or not structure.is_under_construction():
			_release_crew(structure_id, STOP_REMOVED)
			continue
		var work_sec: float = 0.0
		# A copy: a worker that stops leaves the crew while it is looked at
		# (packed arrays are shared, not copied, when they are handed around).
		for player_id: String in _crews[structure_id].duplicate():
			var reason: String = _work_block_reason(world, player_id, structure)
			if not reason.is_empty():
				_stop_work(player_id, reason)
				continue
			work_sec += action_delta * (survival.handling_multiplier(player_id) if survival != null else 1.0)
		if work_sec > 0.0 and _crews.has(structure_id):
			_add_work(world, structure, work_sec)


## Adds `work_sec` seconds of work to a structure under construction, up to
## what its delivered materials allow (docs/04 §5).
func _add_work(world: ServerWorld, structure: StructureInstance, work_sec: float) -> void:
	var definition: StructureDefinition = _catalog.get_definition(structure.definition_id)
	var cap: float = structure.material_share()
	var progress: float = minf(structure.construction_progress + work_sec / definition.build_work_sec, cap)
	if progress > structure.construction_progress:
		structure.construction_progress = progress
		structure.last_modified_at = _clock.world_time_sec
	var started: bool = structure.construction_state == StructureInstance.State.BLUEPRINT and progress > StructureInstance.NO_PROGRESS
	if started:
		structure.construction_state = StructureInstance.State.CONSTRUCTING
		GameLogger.info("building", "construction started", {"entity_id": structure.structure_id, "definition_id": structure.definition_id})
	if progress >= StructureInstance.FULL_PROGRESS:
		_release_crew(structure.structure_id, STOP_FINISHED)
		_finish(world, structure, definition)
	elif progress >= cap:
		# The materials ran out: the clients get the progress it stopped at.
		_push_event(EVENT_CHANGED, structure, "", {"cause": CAUSE_PROGRESS})
		_release_crew(structure.structure_id, REASON_MATERIALS_MISSING)
	elif started or progress - float(_announced.get(structure.structure_id, StructureInstance.NO_PROGRESS)) >= _settings.progress_event_step:
		_push_event(EVENT_CHANGED, structure, "", {"cause": CAUSE_PROGRESS})


## The work on `structure` is done: it is completed, unless it would block
## an edge somebody stands in (then it waits and is looked at again). True
## when it was completed.
func _finish(world: ServerWorld, structure: StructureInstance, definition: StructureDefinition) -> bool:
	if _blocks_when_standing(structure, definition) and _is_entity_in_the_way(world, _slot_of(structure)):
		if not _awaiting.has(structure.structure_id):
			_awaiting[structure.structure_id] = true
			GameLogger.info("building", "a finished structure waits for a clear edge", {"entity_id": structure.structure_id, "definition_id": structure.definition_id})
			_push_event(EVENT_CHANGED, structure, "", {"cause": CAUSE_PROGRESS})
		return false
	_complete(structure, definition)
	return true


## Makes an unfinished structure a completed one. Returns the event.
func _complete(structure: StructureInstance, definition: StructureDefinition) -> Dictionary:
	_awaiting.erase(structure.structure_id)
	structure.construction_state = StructureInstance.State.COMPLETED
	structure.construction_progress = StructureInstance.FULL_PROGRESS
	structure.health = definition.max_health
	structure.last_modified_at = _clock.world_time_sec
	_refresh_blocking(structure, definition)
	GameLogger.info("building", "structure completed", {"entity_id": structure.structure_id, "definition_id": structure.definition_id, "cell_id": structure.cell_id})
	return _push_event(EVENT_CHANGED, structure, "", {"cause": CAUSE_COMPLETED})


## Looks again at the finished structures that waited for a clear edge.
func _retry_completions(world: ServerWorld) -> void:
	for structure_id: String in _awaiting.keys():
		var structure: StructureInstance = _structures.get(structure_id, null)
		if structure == null or not structure.is_under_construction():
			_awaiting.erase(structure_id)
			continue
		_finish(world, structure, _catalog.get_definition(structure.definition_id))


## Stops the work of one player ({} when it was not working). When the last
## worker of a structure that is still being built leaves, an event with its
## exact progress is recorded first, so the clients do not keep a value that
## is up to one progress step old.
func _stop_work(player_id: String, reason: String) -> Dictionary:
	var structure_id: String = _work_of.get(player_id, "")
	if structure_id.is_empty():
		return {}
	_work_of.erase(player_id)
	var crew: PackedStringArray = _crews.get(structure_id, PackedStringArray())
	var index: int = crew.find(player_id)
	if index >= 0:
		crew.remove_at(index)
	if crew.is_empty():
		_crews.erase(structure_id)
	else:
		_crews[structure_id] = crew
	var structure: StructureInstance = _structures.get(structure_id, null)
	var keeps_going: bool = reason != STOP_REMOVED and reason != STOP_UNLOADED and reason != STOP_FINISHED
	if structure != null and crew.is_empty() and keeps_going and structure.is_under_construction() and structure.construction_progress != float(_announced.get(structure_id, StructureInstance.NO_PROGRESS)):
		_push_event(EVENT_CHANGED, structure, "", {"cause": CAUSE_PROGRESS})
	GameLogger.info("building", "work stopped", {"entity_id": structure_id, "player_id": player_id, "reason": reason})
	return _push_work_event(EVENT_WORK_STOPPED, player_id, structure_id, structure.cell_id if structure != null else "", reason)


## Stops everybody who works on one structure.
func _release_crew(structure_id: String, reason: String) -> void:
	# A copy: _stop_work takes each worker out of the crew it is walking.
	for player_id: String in workers_of(structure_id):
		_stop_work(player_id, reason)
