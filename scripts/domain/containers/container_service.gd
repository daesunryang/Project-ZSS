class_name ContainerService
extends ServerSystem
## Server-authoritative containers: things standing in the world that hold
## items (P3-3, docs/00 ADR-021 "창고에 넣어서 옮기는 방식", ADR-026, docs/03 §6,
## docs/09 §15.3). System id "containers". No networking here
## (ContainerNetModule), no nodes.
##
## What it owns: every container that is in memory (ContainerInstance) and
## who has which container open (sessions; not saved). The items of a
## container are ItemInstances of the world's InventoryService, in a detached
## inventory of their own, so putting in and taking out is
## InventoryService.transfer_item with its merging and all-or-nothing rules.
## The server alone decides: clients name a container, a stack and a
## quantity, never a position, an owner or a result.
##
## Public API (every ActionResult failure carries a reason code below):
##   try_open(world, player_id, container_id)     open it, or start searching
##   try_close(world, player_id, container_id)
##   try_take(world, player_id, container_id, item_instance_id, quantity)
##   try_put(world, player_id, container_id, item_instance_id, quantity)
##       requests of a player, checked against the player's server state.
##       `quantity` is 1..the stack, or InventoryService.WHOLE_STACK.
##   create_container(world, definition_id, position, loot_table_id = "",
##                    source_key = "")
##       a server rule: a container can be created at any position of a cell
##       that is in memory, at any time (the map content does; a storage box
##       players build will).
##   has_container, get_container (read-only), container_ids,
##   container_count, container_ids_in_cell, public_row, rows_in_cell,
##   contents_of, session_phase, session_container_id, viewers_of,
##   session_count, has_source
##   drain_events() -> Array[Dictionary]          (network read surface)
##
## Checks of a request, in this order (the first that fails is the reason; a
## refused request changes nothing):
##   1. the player is in the world              not_online
##   2. the player can act                      player_dead, player_resting
##   3. the container is in memory              unknown_container
##   open:   4. within reach of the SERVER position   too_far
##           5. not open by this player already       container_already_open,
##                                                    container_searching
##   close:  4. open (or being searched) by this player  container_not_open
##   take / put:
##           4. open by this player             container_not_open,
##                                              container_searching
##           5. still within reach              too_far
##           6. the stack is where the request says   item_not_in_container
##                                                    (take), item_not_in_
##                                                    inventory (put)
##           7. the quantity is 1..the stack    bad_quantity
##           8. the other side has room         inventory_full (take),
##                                              container_full (put)
## Requests are handled one after the other, so of two players taking the
## same units exactly one succeeds and the other is refused (the stack is
## gone: item_not_in_container, or it holds less: bad_quantity).
##
## Search and loot (docs/03 §6): a container with a loot table is filled
## when it is searched for the first time, by anybody: LootRoller with the
## world's loot seed (recorded on the container when it was created, so a
## later change of the setting does not change it) and the container's id.
## That happens exactly once per
## container (`searched`, saved with it); a container that was emptied stays
## empty. The first opening takes ContainerSettings.search_duration_sec of
## action time; the searcher is told nothing about the content before it is
## over. A search ends without a result when the searcher walks out of
## reach, lies down, dies, leaves or (setting) is hit. When a search
## completes, everybody who is searching that container has it open.
##
## Sessions: a player has at most one container open; opening another closes
## the first. Any number of players may have the same container open. A
## session ends by request, when the player is out of reach or cannot act
## any more (step() looks every tick), and when the container leaves memory.
##
## World cells (docs/09 §15.1): every container in memory is in
## ServerWorld.cell_index (kind "container") under the cell of its position.
## A cell's containers leave memory and come back unchanged, content
## included, through to_cell_document / restore_cell_document / release_cell.
## Containers are not simulated, so activation changes nothing.
##
## Events (drain_events; JSON-safe; every event has event_type, world_time
## and cell_id):
##   container_added     + the public row: the container exists now
##   container_changed   + the public row: it was searched
##   container_session   {player_id, container_id, phase, reason, search_sec,
##                        items}: the player's session on that container is
##                        now "searching" (search_sec: how long), "open"
##                        (items: everything inside) or "closed" (reason)
##   container_contents  {container_id, changed: [entries], removed: [item
##                        ids], viewers: [player ids]}: what a take or a put
##                        changed inside, and who had it open at that moment
## An entry is {item_instance_id, definition_id, quantity, slot}.
##
## Save: per cell document `systems.containers` =
##   {schema_version, containers: [ContainerInstance.to_dict() + items]}
## and world_state.json `systems.containers`, the same shape, for containers
## that are not saved with a cell document (a world without a saved cell
## store). A save without either has no containers. Not saved: sessions,
## events.

const SYSTEM_ID: String = "containers"
const SCHEMA_VERSION: int = 2
## Version of this system's part of a cell document.
const CELL_SCHEMA_VERSION: int = 1
const ENTITY_KIND_CONTAINER: String = ContainerInstance.ENTITY_KIND
const KEY_CONTAINERS: String = "containers"
const KEY_WORLD_LOOT_SEED: String = "world_loot_seed"
## Key of a saved container: its items ([ItemInstance.to_dict()]).
const KEY_ITEMS: String = "items"

const EVENT_ADDED: String = "container_added"
const EVENT_REMOVED: String = "container_removed"
const EVENT_CHANGED: String = "container_changed"
const EVENT_SESSION: String = "container_session"
const EVENT_CONTENTS: String = "container_contents"
## Success events of take and put (returned, not queued).
const EVENT_ITEM_TAKEN: String = "container_item_taken"
const EVENT_ITEM_PUT: String = "container_item_put"

## Phases of a session ("" = the player has none).
const PHASE_NONE: String = ""
const PHASE_SEARCHING: String = "searching"
const PHASE_OPEN: String = "open"
const PHASE_CLOSED: String = "closed"

const REASON_UNKNOWN_DEFINITION: String = "unknown_container_definition"
const REASON_BAD_POSITION: String = "bad_position"
const REASON_UNKNOWN_LOOT_TABLE: String = "unknown_loot_table"
const REASON_CELL_NOT_LOADED: String = "cell_not_loaded"
const REASON_SOURCE_EXISTS: String = "container_source_exists"
const REASON_LIMIT: String = "container_limit"
const REASON_ID_FAILED: String = "container_id_failed"
const REASON_UNKNOWN_CONTAINER: String = "unknown_container"
const REASON_TOO_FAR: String = "too_far"
const REASON_NOT_OPEN: String = "container_not_open"
const REASON_ALREADY_OPEN: String = "container_already_open"
const REASON_SEARCHING: String = "container_searching"
const REASON_ITEM_NOT_INSIDE: String = "item_not_in_container"
const REASON_ITEM_NOT_CARRIED: String = InventoryService.REASON_NOT_IN_INVENTORY
const REASON_CONTAINER_FULL: String = "container_full"
const REASON_CONTAINER_NOT_EMPTY: String = "container_not_empty"
## The world has no container system (ContainerNetModule answers with it).
const REASON_UNAVAILABLE: String = "containers_unavailable"
## Why a session was closed, besides too_far and what blocks the player's
## actions (player_dead, player_resting): by request, because the player
## opened another container, because a hit interrupted the search, because
## the container left memory.
const REASON_CLOSED: String = "closed"
const REASON_SWITCHED: String = "switched"
const REASON_INTERRUPTED: String = "interrupted"
const REASON_CONTAINER_GONE: String = "container_unavailable"

## Public row keys (events, ContainerNetModule).
const KEY_CONTAINER_ID: String = "container_id"
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_POSITION: String = "position"
const KEY_SEARCHED: String = "searched"
## Keys of one entry of a container's content.
const ENTRY_ITEM_ID: String = "item_instance_id"
const ENTRY_DEFINITION_ID: String = "definition_id"
const ENTRY_QUANTITY: String = "quantity"
const ENTRY_SLOT: String = "slot"
## Float tolerance for a search time measured in summed tick lengths.
const TIME_EPSILON_SEC: float = 0.000001


## One player's open (or searched) container.
class Session:
	extends RefCounted
	var player_id: String = ""
	var container_id: String = ""
	## PHASE_SEARCHING or PHASE_OPEN.
	var phase: String = ""
	## Action time at which the search is over.
	var search_ends_at: float = 0.0


## Diagnostics (tests / profiling): loot rolls made since the start, and
## events dropped because nobody drained them.
var loot_roll_count: int = 0
var dropped_event_count: int = 0

var _settings: ContainerSettings
var _definitions: ContainerCatalog
var _loot_tables: LootTableCatalog
var _ids: EntityIdGenerator
var _registry: EntityRegistry
var _clock: WorldClock
## The world this system is registered with (weak: the world owns it).
var _world_ref: WeakRef = null
## Containers in memory. Insertion order = the order they were created or
## loaded (deterministic iteration).
var _containers: Dictionary[String, ContainerInstance] = {}
## source_key -> container id, for the containers in memory that have one.
var _sources: Dictionary[String, String] = {}
## player_id -> its session.
var _sessions: Dictionary[String, Session] = {}
var _events: Array[Dictionary] = []
## Resolved once for this world. -1 means a new/legacy world has not needed
## a seed yet. Positive settings are deterministic overrides; shipped 0 uses
## one explicit RNG draw. This value is stored in the world document.
var _world_loot_seed: int = -1


func _init(settings: ContainerSettings, definitions: ContainerCatalog, loot_tables: LootTableCatalog, ids: EntityIdGenerator, registry: EntityRegistry, clock: WorldClock) -> void:
	_settings = settings
	_definitions = definitions
	_loot_tables = loot_tables
	_ids = ids
	_registry = registry
	_clock = clock


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ server rules

## Creates a container as a server rule (no actor, no range). `loot_table_id`
## "" = the definition's own table (which may be none: such a container
## counts as searched and stays as empty as it is created). `source_key`
## names what placed it; a key that is already used by a container in memory
## is refused, so a caller that places the same content twice gets one
## container. Failures: unknown_container_definition, bad_position (not
## finite, or outside the play area), unknown_loot_table, cell_not_loaded,
## container_source_exists, container_limit, container_id_failed. Success
## event: container_added.
func create_container(world: ServerWorld, definition_id: String, position: Vector3, loot_table_id: String = "", source_key: String = "", structure_id: String = "") -> ActionResult:
	if world == null:
		return ActionResult.failure(REASON_UNAVAILABLE)
	var definition: ContainerDefinition = _definitions.get_definition(definition_id)
	if definition == null:
		return ActionResult.failure(REASON_UNKNOWN_DEFINITION)
	var limit: float = world.gameplay.world_half_extent_m
	if not position.is_finite() or absf(position.x) > limit or absf(position.z) > limit:
		return ActionResult.failure(REASON_BAD_POSITION)
	var table_id: String = loot_table_id if not loot_table_id.is_empty() else definition.loot_table_id
	if not table_id.is_empty() and not _loot_tables.has(table_id):
		return ActionResult.failure(REASON_UNKNOWN_LOOT_TABLE)
	var cell_id: String = world.cell_id_at(position)
	if not world.is_cell_loaded(cell_id):
		return ActionResult.failure(REASON_CELL_NOT_LOADED)
	if not source_key.is_empty() and _sources.has(source_key):
		return ActionResult.failure(REASON_SOURCE_EXISTS)
	if world.cell_index.count_in_cell(cell_id, ENTITY_KIND_CONTAINER) >= _settings.max_containers_per_cell:
		return ActionResult.failure(REASON_LIMIT)
	var container_id: String = _ids.next_id(ENTITY_KIND_CONTAINER)
	if container_id.is_empty() or _registry.register(container_id, ENTITY_KIND_CONTAINER) != OK:
		GameLogger.error("containers", "container id could not be registered", {"entity_id": container_id, "definition_id": definition_id, "operation": "create_container"})
		return ActionResult.failure(REASON_ID_FAILED)
	var inventory_id: String = world.inventory.create_detached_inventory(definition.slot_count)
	if inventory_id.is_empty():
		_registry.release(container_id)
		return ActionResult.failure(REASON_ID_FAILED)
	var container: ContainerInstance = ContainerInstance.new()
	container.container_id = container_id
	container.definition_id = definition_id
	container.position = position
	container.inventory_id = inventory_id
	container.slot_count = definition.slot_count
	container.loot_table_id = table_id
	container.searched = table_id.is_empty()
	container.source_key = source_key
	container.created_at = _clock.world_time_sec
	container.loot_seed = world_loot_seed()
	container.structure_id = structure_id
	_remember(world, container)
	GameLogger.info("containers", "container created", {"entity_id": container_id, "definition_id": definition_id, "cell_id": container.cell_id, "inventory_id": inventory_id, "loot_table_id": table_id, "source": source_key})
	return ActionResult.success(_push_row_event(EVENT_ADDED, container))


## Removes an empty container as a server rule. Player-built storage uses
## this when its owning structure is demolished. Seeded containers have no
## owning structure and are never passed here by the building system.
func remove_empty_container(world: ServerWorld, container_id: String, structure_id: String = "") -> ActionResult:
	var reason: String = empty_removal_reason(world, container_id, structure_id)
	if not reason.is_empty():
		return ActionResult.failure(reason)
	var container: ContainerInstance = _containers.get(container_id, null)
	for player_id: String in _sessions.keys():
		if _sessions[player_id].container_id == container_id:
			_close(_sessions[player_id], REASON_CONTAINER_GONE)
	var event: Dictionary = _push_row_event(EVENT_REMOVED, container)
	world.inventory.release_detached_inventory(container.inventory_id)
	_sources.erase(container.source_key)
	_containers.erase(container_id)
	world.cell_index.remove(container_id)
	_registry.remove(container_id)
	GameLogger.info("containers", "container removed", {"entity_id": container_id, "structure_id": structure_id, "operation": "remove_empty_container"})
	return ActionResult.success(event)


## Pure preflight for remove_empty_container. Empty means removal is safe.
func empty_removal_reason(world: ServerWorld, container_id: String, structure_id: String = "") -> String:
	var container: ContainerInstance = _containers.get(container_id, null)
	if world == null or container == null:
		return REASON_UNKNOWN_CONTAINER
	if not structure_id.is_empty() and container.structure_id != structure_id:
		return REASON_UNKNOWN_CONTAINER
	if not world.inventory.items_in_inventory(container.inventory_id).is_empty():
		return REASON_CONTAINER_NOT_EMPTY
	return ""


# ------------------------------------------------------------ player requests

## A player opens a container. One that was never searched is searched
## first (see the header); the result's `phase` says which. Opening another
## container while one is open closes that one. Success event:
##   {event_type: "container_session", player_id, container_id, phase}
func try_open(world: ServerWorld, player_id: String, container_id: String) -> ActionResult:
	var blocked: String = _actor_block_reason(world, player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var container: ContainerInstance = _containers.get(container_id, null)
	if container == null:
		return ActionResult.failure(REASON_UNKNOWN_CONTAINER)
	if not _is_within_reach(world, player_id, container):
		return ActionResult.failure(REASON_TOO_FAR)
	var session: Session = _sessions.get(player_id, null)
	if session != null:
		if session.container_id == container_id:
			return ActionResult.failure(REASON_SEARCHING if session.phase == PHASE_SEARCHING else REASON_ALREADY_OPEN)
		_close(session, REASON_SWITCHED)
	session = Session.new()
	session.player_id = player_id
	session.container_id = container_id
	session.phase = PHASE_SEARCHING
	session.search_ends_at = _clock.action_time_sec + _settings.search_duration_sec
	_sessions[player_id] = session
	if container.searched or _settings.search_duration_sec <= 0.0:
		_finish_search(world, container)
	else:
		_push_session_event(session, container, "", _settings.search_duration_sec, [])
		GameLogger.info("containers", "search started", {"entity_id": container_id, "player_id": player_id, "search_sec": _settings.search_duration_sec})
	return ActionResult.success({"event_type": EVENT_SESSION, "player_id": player_id, KEY_CONTAINER_ID: container_id, "phase": session.phase})


## A player closes the container it has open, or gives up searching it. May
## be asked by a player that cannot act (the session is gone by the next
## tick anyway). Failures: not_online, container_not_open.
func try_close(world: ServerWorld, player_id: String, container_id: String) -> ActionResult:
	if world == null or not world.is_online(player_id):
		return ActionResult.failure(ServerWorld.REASON_NOT_ONLINE)
	var session: Session = _sessions.get(player_id, null)
	if session == null or session.container_id != container_id:
		return ActionResult.failure(REASON_NOT_OPEN)
	_close(session, REASON_CLOSED)
	return ActionResult.success({"event_type": EVENT_SESSION, "player_id": player_id, KEY_CONTAINER_ID: container_id, "phase": PHASE_CLOSED})


## A player takes `quantity` units of a stack out of the container it has
## open (InventoryService.WHOLE_STACK = all of it). The units join the
## stacks of the same kind the player carries first; what is left over takes
## one free slot, and without one nothing is taken. Success event:
##   {event_type: "container_item_taken", player_id, container_id,
##    item_instance_id, definition_id, quantity}
func try_take(world: ServerWorld, player_id: String, container_id: String, item_instance_id: String, quantity: int) -> ActionResult:
	var reason: String = _use_block_reason(world, player_id, container_id)
	if not reason.is_empty():
		return ActionResult.failure(reason)
	var container: ContainerInstance = _containers[container_id]
	var item: ItemInstance = world.inventory.get_item(item_instance_id)
	if item == null or item.location_type != ItemInstance.LOCATION_INVENTORY or item.location_id != container.inventory_id:
		return ActionResult.failure(REASON_ITEM_NOT_INSIDE)
	var units: int = item.quantity if quantity == InventoryService.WHOLE_STACK else quantity
	if units < 1 or units > item.quantity:
		return ActionResult.failure(InventoryService.REASON_BAD_QUANTITY)
	var definition_id: String = item.definition_id
	var moved: ActionResult = world.inventory.transfer_item(container.inventory_id, item_instance_id, world.get_player(player_id).inventory_id, units)
	if not moved.ok:
		return ActionResult.failure(moved.reason)
	_push_contents_event(world, container, [item_instance_id])
	GameLogger.info("containers", "item taken", {"entity_id": container_id, "player_id": player_id, "item_instance_id": item_instance_id, "definition_id": definition_id, "quantity": units})
	return ActionResult.success({"event_type": EVENT_ITEM_TAKEN, "player_id": player_id, KEY_CONTAINER_ID: container_id, ENTRY_ITEM_ID: item_instance_id, ENTRY_DEFINITION_ID: definition_id, ENTRY_QUANTITY: units})


## A player puts `quantity` units of a stack it carries into the container
## it has open (InventoryService.WHOLE_STACK = all of it). The units join
## the stacks of the same kind lying there first; what is left over takes
## one free slot, and without one nothing is put in. Success event:
##   {event_type: "container_item_put", player_id, container_id,
##    item_instance_id, definition_id, quantity}
func try_put(world: ServerWorld, player_id: String, container_id: String, item_instance_id: String, quantity: int) -> ActionResult:
	var reason: String = _use_block_reason(world, player_id, container_id)
	if not reason.is_empty():
		return ActionResult.failure(reason)
	var container: ContainerInstance = _containers[container_id]
	var player: PlayerState = world.get_player(player_id)
	var item: ItemInstance = world.inventory.get_item(item_instance_id)
	if item == null or item.location_type != ItemInstance.LOCATION_INVENTORY or item.location_id != player.inventory_id:
		return ActionResult.failure(REASON_ITEM_NOT_CARRIED)
	var units: int = item.quantity if quantity == InventoryService.WHOLE_STACK else quantity
	if units < 1 or units > item.quantity:
		return ActionResult.failure(InventoryService.REASON_BAD_QUANTITY)
	var definition_id: String = item.definition_id
	var moved: ActionResult = world.inventory.transfer_item(player.inventory_id, item_instance_id, container.inventory_id, units)
	if not moved.ok:
		return ActionResult.failure(REASON_CONTAINER_FULL if moved.reason == InventoryService.REASON_INVENTORY_FULL else moved.reason)
	var touched: Array = []
	for entry: Variant in moved.event.get("received", []):
		touched.append(str((entry as Dictionary).get("item_instance_id", "")))
	_push_contents_event(world, container, touched)
	GameLogger.info("containers", "item put", {"entity_id": container_id, "player_id": player_id, "item_instance_id": item_instance_id, "definition_id": definition_id, "quantity": units})
	return ActionResult.success({"event_type": EVENT_ITEM_PUT, "player_id": player_id, KEY_CONTAINER_ID: container_id, ENTRY_ITEM_ID: item_instance_id, ENTRY_DEFINITION_ID: definition_id, ENTRY_QUANTITY: units})


## A player was hit (SurvivalService.player_damaged, connected by
## ServerComposition): a running search is interrupted. An open container
## stays open.
func on_player_damaged(player_id: String) -> void:
	var session: Session = _sessions.get(player_id, null)
	if session != null and session.phase == PHASE_SEARCHING and _settings.search_interrupted_by_damage:
		_close(session, REASON_INTERRUPTED)


# ------------------------------------------------------------ read surface

func has_container(container_id: String) -> bool:
	return _containers.has(container_id)


## Read-only view of one container (null if it is not in memory). Do not
## mutate.
func get_container(container_id: String) -> ContainerInstance:
	return _containers.get(container_id, null)


## Ids of the containers in memory, in the order they came into memory.
func container_ids() -> PackedStringArray:
	return PackedStringArray(_containers.keys())


func container_count() -> int:
	return _containers.size()


## True when a container in memory was created with this source key.
func has_source(source_key: String) -> bool:
	return _sources.has(source_key)


## Ids of the containers of one cell that are in memory, sorted.
func container_ids_in_cell(world: ServerWorld, cell_id: String) -> PackedStringArray:
	return world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_CONTAINER)


## What everybody near may know about a container (replication row):
##   {container_id, definition_id, position: [x, y, z], searched}
## Not in it: what is inside, the loot table, who has it open.
func public_row(container: ContainerInstance) -> Dictionary:
	return {
		KEY_CONTAINER_ID: container.container_id,
		KEY_DEFINITION_ID: container.definition_id,
		KEY_POSITION: [container.position.x, container.position.y, container.position.z],
		KEY_SEARCHED: container.searched,
	}


## Public rows of the containers of one cell, sorted by id.
func rows_in_cell(world: ServerWorld, cell_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for container_id: String in container_ids_in_cell(world, cell_id):
		if _containers.has(container_id):
			result.append(public_row(_containers[container_id]))
	return result


## What a container in memory holds, in slot order:
## [{item_instance_id, definition_id, quantity, slot}]. Only for whoever has
## it open (ContainerNetModule) and for server rules.
func contents_of(container_id: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var world: ServerWorld = _world()
	var container: ContainerInstance = _containers.get(container_id, null)
	if world == null or container == null:
		return entries
	for item: ItemInstance in world.inventory.items_in_inventory(container.inventory_id):
		entries.append(_entry_of(item))
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a[ENTRY_SLOT]) < int(b[ENTRY_SLOT]))
	return entries


## Phase of the player's session (PHASE_SEARCHING, PHASE_OPEN), or
## PHASE_NONE when it has none.
func session_phase(player_id: String) -> String:
	var session: Session = _sessions.get(player_id, null)
	return session.phase if session != null else PHASE_NONE


## The container the player has open or searches, "" when none.
func session_container_id(player_id: String) -> String:
	var session: Session = _sessions.get(player_id, null)
	return session.container_id if session != null else ""


## The players that have this container open (not the ones still searching
## it), sorted.
func viewers_of(container_id: String) -> PackedStringArray:
	var viewers: PackedStringArray = []
	for player_id: String in _sessions:
		if _sessions[player_id].container_id == container_id and _sessions[player_id].phase == PHASE_OPEN:
			viewers.append(player_id)
	viewers.sort()
	return viewers


func session_count() -> int:
	return _sessions.size()


## The seed shared by every container created in this world.
func world_loot_seed() -> int:
	if _world_loot_seed >= 0:
		return _world_loot_seed
	if _settings.loot_seed > 0:
		_world_loot_seed = _settings.loot_seed
		return _world_loot_seed
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	# One draw, kept in the JSON-exact integer range and never 0 (the
	# ContainerSettings sentinel).
	_world_loot_seed = int(rng.randi()) + 1
	return _world_loot_seed


## Returns and clears the events recorded since the previous call (oldest
## first). At most `max_pending_events` are kept between calls.
func drain_events() -> Array[Dictionary]:
	var drained: Array[Dictionary] = _events
	_events = []
	return drained


# ------------------------------------------------------------ ServerSystem

func on_registered(world: ServerWorld) -> void:
	_world_ref = weakref(world)


## Ends the sessions whose player cannot use its container any more and
## completes the searches whose time is over.
func step(world: ServerWorld, _action_delta: float, _world_delta: float) -> void:
	if _sessions.is_empty():
		return
	var now: float = _clock.action_time_sec
	for player_id: String in _sessions.keys():
		var session: Session = _sessions.get(player_id, null)
		if session == null:
			continue
		var container: ContainerInstance = _containers.get(session.container_id, null)
		var reason: String = ""
		if container == null:
			reason = REASON_CONTAINER_GONE
		elif not world.is_online(player_id):
			_sessions.erase(player_id)
			continue
		else:
			reason = world.player_action_block_reason(player_id)
			if reason.is_empty() and not _is_within_reach(world, player_id, container):
				reason = REASON_TOO_FAR
		if not reason.is_empty():
			_close(session, reason)
		elif session.phase == PHASE_SEARCHING and now + TIME_EPSILON_SEC >= session.search_ends_at:
			_finish_search(world, container)


## A player who left has nothing open (nobody is left to tell).
func on_player_offline(_world_arg: ServerWorld, player_id: String) -> void:
	_sessions.erase(player_id)


## A new character starts at the spawn point with nothing open.
func on_character_started(_world_arg: ServerWorld, player_id: String) -> void:
	var session: Session = _sessions.get(player_id, null)
	if session != null:
		_close(session, REASON_TOO_FAR)


## The resolved world loot seed plus containers that are NOT saved with a
## cell document. The seed is always present so an empty new world keeps it
## across a save/restart before any container is created.
func to_world_document() -> Dictionary:
	var world: ServerWorld = _world()
	if world == null:
		return {}
	var containers: Array[Dictionary] = []
	if not world.saves_all_loaded_entities_in_cells():
		for container_id: String in _containers:
			var container: ContainerInstance = _containers[container_id]
			if not world.saves_cell_document(container.cell_id):
				containers.append(_document_of(world, container))
	return {"schema_version": SCHEMA_VERSION, KEY_WORLD_LOOT_SEED: world_loot_seed(), KEY_CONTAINERS: containers}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var world: ServerWorld = _world()
	if world == null:
		return PackedStringArray(["containers: not registered with a world"])
	var errors: PackedStringArray = []
	var version_value: Variant = document.get("schema_version", null)
	if not ItemInstance.is_integer_value(version_value) or (
		int(version_value) != 1 and int(version_value) != SCHEMA_VERSION
	):
		return PackedStringArray(["containers: unsupported schema_version"])
	var normalized: Dictionary = document.duplicate(true)
	normalized["schema_version"] = SCHEMA_VERSION
	var restored_seed: int = -1
	if int(version_value) == SCHEMA_VERSION:
		var seed_value: Variant = document.get(KEY_WORLD_LOOT_SEED, null)
		if not ItemInstance.is_integer_value(seed_value) or not ContainerInstance.is_valid_loot_seed(int(seed_value)) or int(seed_value) <= 0:
			return PackedStringArray(["containers: invalid world_loot_seed"])
		restored_seed = int(seed_value)
	else:
		var legacy_entries: Variant = document.get(KEY_CONTAINERS, [])
		if typeof(legacy_entries) == TYPE_ARRAY and not (legacy_entries as Array).is_empty():
			var first: Variant = (legacy_entries as Array)[0]
			if typeof(first) == TYPE_DICTIONARY and ItemInstance.is_integer_value((first as Dictionary).get(ContainerInstance.KEY_LOOT_SEED, null)):
				restored_seed = int((first as Dictionary)[ContainerInstance.KEY_LOOT_SEED])
		if restored_seed <= 0:
			restored_seed = world_loot_seed()
	var restored: Array[Dictionary] = _read_containers(world, normalized, SCHEMA_VERSION, "containers", true, errors)
	if not errors.is_empty():
		return errors
	if _world_loot_seed >= 0 and _world_loot_seed != restored_seed:
		return PackedStringArray(["containers: world_loot_seed does not match the loaded world"])
	_world_loot_seed = restored_seed
	for row: Dictionary in restored:
		errors.append_array(_adopt(world, row["container"] as ContainerInstance, row[KEY_ITEMS] as Array))
	return errors


# ------------------------------------------------------------ world cells

## The containers of one cell as save data ({} = none), sorted by id.
func to_cell_document(cell_id: String) -> Dictionary:
	var world: ServerWorld = _world()
	if world == null:
		return {}
	var containers: Array[Dictionary] = []
	for container_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_CONTAINER):
		if _containers.has(container_id):
			containers.append(_document_of(world, _containers[container_id]))
	if containers.is_empty():
		return {}
	return {"schema_version": CELL_SCHEMA_VERSION, KEY_CONTAINERS: containers}


## Brings the saved containers of a cell back, exactly as they were saved
## (ids, position, whether they were searched, every stack inside with its
## id and slot). Validates first: on any error nothing changes. What is in
## memory wins over a saved copy: a container whose id is in memory or was
## retired is skipped and logged, and so is a stack inside a container whose
## id is in memory (somebody took it out) or was retired (it merged away).
## This only happens when a cell file is older than the rest of the save.
## The cell of each container is decided by its position, not by `cell_id`,
## so documents cut with another cell grid restore as well.
func restore_cell_document(world: ServerWorld, cell_id: String, document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	var restored: Array[Dictionary] = _read_containers(world, document, CELL_SCHEMA_VERSION, "containers: cell %s" % cell_id, false, errors)
	if not errors.is_empty():
		return errors
	for row: Dictionary in restored:
		errors.append_array(_adopt(world, row["container"] as ContainerInstance, row[KEY_ITEMS] as Array))
	return errors


## Forgets the containers of a cell and what is inside them (it was saved).
## Their ids are released, not retired: they still exist. Whoever had one of
## them open is told that it is closed.
func release_cell(world: ServerWorld, cell_id: String) -> void:
	for container_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_CONTAINER):
		var container: ContainerInstance = _containers.get(container_id, null)
		if container != null:
			for player_id: String in _sessions.keys():
				if _sessions[player_id].container_id == container_id:
					_close(_sessions[player_id], REASON_CONTAINER_GONE)
			world.inventory.release_detached_inventory(container.inventory_id)
			_sources.erase(container.source_key)
			_containers.erase(container_id)
		world.cell_index.remove(container_id)
		_registry.release(container_id)


# ------------------------------------------------------------ internals

func _world() -> ServerWorld:
	return _world_ref.get_ref() as ServerWorld if _world_ref != null else null


## "" when the player may make a container request now: it is in the world
## and no system blocks its actions (dead, asleep).
func _actor_block_reason(world: ServerWorld, player_id: String) -> String:
	if world == null or not world.is_online(player_id) or world.get_player(player_id) == null:
		return ServerWorld.REASON_NOT_ONLINE
	return world.player_action_block_reason(player_id)


## "" when the player may take from / put into this container now (checks
## 1-5 of the header).
func _use_block_reason(world: ServerWorld, player_id: String, container_id: String) -> String:
	var blocked: String = _actor_block_reason(world, player_id)
	if not blocked.is_empty():
		return blocked
	var container: ContainerInstance = _containers.get(container_id, null)
	if container == null:
		return REASON_UNKNOWN_CONTAINER
	var session: Session = _sessions.get(player_id, null)
	if session == null or session.container_id != container_id:
		return REASON_NOT_OPEN
	if session.phase != PHASE_OPEN:
		return REASON_SEARCHING
	if not _is_within_reach(world, player_id, container):
		return REASON_TOO_FAR
	return ""


## Distance check against the player's SERVER position.
func _is_within_reach(world: ServerWorld, player_id: String, container: ContainerInstance) -> bool:
	return world.get_player(player_id).position.distance_to(container.position) <= _settings.interact_range_m


## The container was searched (or needs no search): its loot is rolled if it
## never was, and every session on it that is still searching becomes open.
func _finish_search(world: ServerWorld, container: ContainerInstance) -> void:
	if not container.searched:
		_roll_loot(world, container)
	var entries: Array = contents_of(container.container_id)
	for player_id: String in _sessions:
		var session: Session = _sessions[player_id]
		if session.container_id != container.container_id or session.phase == PHASE_OPEN:
			continue
		session.phase = PHASE_OPEN
		_push_session_event(session, container, "", 0.0, entries.duplicate(true))


## Fills a container from its loot table. Called at most once per container:
## `searched` is set here and saved with it.
func _roll_loot(world: ServerWorld, container: ContainerInstance) -> void:
	container.searched = true
	loot_roll_count += 1
	var table: LootTable = _loot_tables.get_table(container.loot_table_id)
	# The seed the container was created with, not the setting now.
	var stacks: Array[Dictionary] = LootRoller.roll(table, LootRoller.seed_for(container.loot_seed, container.container_id), _loot_tables)
	var placed: int = 0
	for stack: Dictionary in stacks:
		if placed >= container.slot_count:
			GameLogger.warning("containers", "loot does not fit the container; the rest is left out", {"entity_id": container.container_id, "loot_table_id": container.loot_table_id, "slot_count": container.slot_count, "operation": "roll_loot"})
			break
		if not world.inventory.spawn_detached_item(container.inventory_id, str(stack[LootRoller.KEY_DEFINITION_ID]), int(stack[LootRoller.KEY_QUANTITY])).is_empty():
			placed += 1
	GameLogger.info("containers", "container searched", {"entity_id": container.container_id, "loot_table_id": container.loot_table_id, "stacks": placed})
	_push_row_event(EVENT_CHANGED, container)


## Ends a session and tells its player why.
func _close(session: Session, reason: String) -> void:
	if _sessions.get(session.player_id, null) != session:
		return
	_sessions.erase(session.player_id)
	session.phase = PHASE_CLOSED
	_push_session_event(session, _containers.get(session.container_id, null), reason, 0.0, [])


func _entry_of(item: ItemInstance) -> Dictionary:
	return {
		ENTRY_ITEM_ID: item.item_instance_id,
		ENTRY_DEFINITION_ID: item.definition_id,
		ENTRY_QUANTITY: item.quantity,
		ENTRY_SLOT: InventoryService.slot_index_of(item.slot_id),
	}


## Puts a container that just came into memory into this system's maps and
## the cell index.
func _remember(world: ServerWorld, container: ContainerInstance) -> void:
	container.cell_id = world.cell_id_at(container.position)
	_containers[container.container_id] = container
	if not container.source_key.is_empty():
		_sources[container.source_key] = container.container_id
	world.cell_index.put(container.container_id, ENTITY_KIND_CONTAINER, container.cell_id)


## Save data of one container: its own fields and its items.
func _document_of(world: ServerWorld, container: ContainerInstance) -> Dictionary:
	var document: Dictionary = container.to_dict()
	document[KEY_ITEMS] = world.inventory.detached_snapshot(container.inventory_id).get(InventoryService.SNAPSHOT_ITEMS, [])
	return document


## Registers a restored container and brings it and its items into memory.
func _adopt(world: ServerWorld, container: ContainerInstance, items: Array) -> PackedStringArray:
	var errors: PackedStringArray = world.inventory.restore_detached_snapshot(container.inventory_id, _inventory_snapshot(container, items))
	if not errors.is_empty():
		return errors
	_registry.register(container.container_id, ENTITY_KIND_CONTAINER)
	_ids.reserve_existing_id(container.container_id)
	_remember(world, container)
	return errors


func _inventory_snapshot(container: ContainerInstance, items: Array) -> Dictionary:
	return {InventoryService.DETACHED_CAPACITY: container.slot_count, InventoryService.SNAPSHOT_ITEMS: items}


## Reads and checks the containers of a save document. Returns rows
## {container: ContainerInstance, items: Array}. On any error `errors` is
## filled and the result must not be used. `strict` (the world document): a
## container whose id is already known or retired is an error. Otherwise (a
## cell document) such a container is skipped and logged.
func _read_containers(world: ServerWorld, document: Dictionary, expected_version: int, context: String, strict: bool, errors: PackedStringArray) -> Array[Dictionary]:
	var restored: Array[Dictionary] = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != expected_version:
		errors.append("%s: unsupported schema_version" % context)
		return restored
	var entries: Variant = document.get(KEY_CONTAINERS, null)
	if typeof(entries) != TYPE_ARRAY:
		errors.append("%s: containers must be an array" % context)
		return restored
	var seen: Dictionary[String, bool] = {}
	var skipped: PackedStringArray = []
	for entry: Variant in (entries as Array):
		var container: ContainerInstance = ContainerInstance.from_dict(entry as Dictionary) if typeof(entry) == TYPE_DICTIONARY else null
		var items: Variant = (entry as Dictionary).get(KEY_ITEMS, null) if container != null else null
		if container == null or typeof(items) != TYPE_ARRAY:
			errors.append("%s: invalid container entry" % context)
			continue
		if not _definitions.has(container.definition_id):
			errors.append("%s: unknown definition %s for %s" % [context, container.definition_id, container.container_id])
			continue
		if not container.searched and not container.loot_table_id.is_empty() and not _loot_tables.has(container.loot_table_id):
			errors.append("%s: unknown loot table %s for %s" % [context, container.loot_table_id, container.container_id])
			continue
		if seen.has(container.container_id) or seen.has(container.inventory_id):
			errors.append("%s: duplicate id %s" % [context, container.container_id])
			continue
		seen[container.container_id] = true
		seen[container.inventory_id] = true
		if _containers.has(container.container_id) or _registry.has(container.container_id) or _registry.is_tombstoned(container.container_id):
			if strict:
				errors.append("%s: duplicate or removed id %s" % [context, container.container_id])
			else:
				skipped.append(container.container_id)
			continue
		var content_errors: PackedStringArray = world.inventory.check_detached_snapshot(container.inventory_id, _inventory_snapshot(container, items as Array))
		if not content_errors.is_empty():
			errors.append("%s: %s: %s" % [context, container.container_id, "; ".join(content_errors)])
			continue
		restored.append({"container": container, KEY_ITEMS: items})
	if errors.is_empty() and not skipped.is_empty():
		GameLogger.warning("containers", "saved containers skipped: already in memory or removed", {"context": context, "containers": ", ".join(skipped), "operation": "restore"})
	return restored


## Records what a take or a put changed inside a container: the stacks of
## `touched_ids` that are inside now (with their quantities) and the ones
## that are not inside any more, with the players that have it open.
func _push_contents_event(world: ServerWorld, container: ContainerInstance, touched_ids: Array) -> void:
	var changed: Array = []
	var removed: Array = []
	for item_id: Variant in touched_ids:
		var item: ItemInstance = world.inventory.get_item(str(item_id))
		if item != null and item.location_type == ItemInstance.LOCATION_INVENTORY and item.location_id == container.inventory_id:
			changed.append(_entry_of(item))
		else:
			removed.append(str(item_id))
	_push_event({
		"event_type": EVENT_CONTENTS,
		"world_time": _clock.world_time_sec,
		"cell_id": container.cell_id,
		KEY_CONTAINER_ID: container.container_id,
		"changed": changed,
		"removed": removed,
		"viewers": Array(viewers_of(container.container_id)),
	})


func _push_session_event(session: Session, container: ContainerInstance, reason: String, search_sec: float, items: Array) -> void:
	_push_event({
		"event_type": EVENT_SESSION,
		"world_time": _clock.world_time_sec,
		"cell_id": container.cell_id if container != null else "",
		"player_id": session.player_id,
		KEY_CONTAINER_ID: session.container_id,
		"phase": session.phase,
		"reason": reason,
		"search_sec": search_sec,
		"items": items,
	})


## Records an event that carries the container's public row.
func _push_row_event(event_type: String, container: ContainerInstance) -> Dictionary:
	var event: Dictionary = {"event_type": event_type, "world_time": _clock.world_time_sec, "cell_id": container.cell_id}
	event.merge(public_row(container))
	_push_event(event)
	return event


func _push_event(event: Dictionary) -> void:
	mark_cell_save_dirty(str(event.get("cell_id", "")))
	_events.append(event)
	while _events.size() > _settings.max_pending_events:
		_events.pop_front()
		dropped_event_count += 1
