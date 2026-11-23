class_name NpcService
extends ServerSystem
## Server-authoritative NPCs: who exists, where they stand and what is saved
## of them (P4-1, docs/05 §2, docs/13 §16, docs/09 §17.1). System id "npc".
## No networking here (P4-7), no nodes, and no behaviour: an NPC does not
## think or move by itself yet (P4-3, P4-4). What this system owns is the
## ground later tickets stand on.
##
## What it owns: every NPC that is in memory (NpcState), the list of every
## NPC of the world (also the ones whose cell is not in memory), which
## roster the world was given, and the two seams below.
##
## Public API (every ActionResult failure carries a reason code below):
##   spawn_npc(world, definition_id, position, yaw = 0.0)
##       a server rule: a new NPC at any position of a cell that is in
##       memory. Failures: unknown_npc_definition, bad_position (not finite,
##       or outside the play area), cell_not_loaded, npc_limit
##       (NpcSettings.max_npcs, counted over the whole world), npc_id_failed.
##   remove_npc(world, npc_id)
##       removes an NPC that is in memory for good; its id is retired.
##   set_npc_transform(world, npc_id, position, yaw) -> bool
##       the ONLY way an NPC changes its place (the executor of P4-5a calls
##       it after ServerWorld.resolve_movement). Keeps the cell index right;
##       an NPC never enters a cell that is not in memory (false, counted in
##       blocked_move_count) and freezes in one that is not simulated.
##   set_simulation_tier(npc_id, tier) -> bool    (the scheduler, P4-3)
##   mark_npc_dirty(npc_id)   something saved with the NPC changed
##   ensure_seeded(world)     places the roster, once per world
##   has_npc, get_npc (read-only), npc_ids, npc_count, npc_ids_in_cell,
##   is_awake, awake_npc_ids, awake_count, definition_of, npc_document,
##   population_count, population_ids, is_seeded, seeded_npc_ids,
##   seeded_npc_id
##
## Seams for later tickets (docs/09 §17.1). Both are filled in
## ServerComposition, before the world is seeded or restored:
##   register_component(component_id, factory)
##       state of one NPC that is saved with it (NpcComponent). Every NPC
##       has one instance of every registered component.
##   add_stage(stage)
##       work done for the NPCs every tick (NpcStage): the scheduler, the
##       executor. step() only runs the stages; with none it does nothing.
##
## Ids: `npc_<number>` from the world's EntityIdGenerator, registered in the
## world's EntityRegistry (kind "npc"). An id is never reused: an NPC that
## leaves memory with its cell is released (it still exists), an NPC that
## is removed is retired (tombstoned), and a retired or already loaded id
## in a cell document is skipped.
##
## Random numbers: every NPC has its own generator, seeded from
## NpcSettings.world_seed and its id (NpcState.seed_for) and saved with it.
## Nothing here uses the engine's global random generator.
##
## World cells (docs/09 §15.1): every NPC in memory is in
## ServerWorld.cell_index (kind "npc") under the cell of its position. Only
## NPCs of ACTIVE cells are "awake" (simulated); the others are frozen as
## they are (docs/13 §16.3 D4). A cell's NPCs leave memory and come back
## unchanged through to_cell_document / restore_cell_document /
## release_cell.
##
## Roster (docs/13 §16.3 D5): the NPCs of the configured NpcRoster are
## placed on their home spots exactly once per world. The world save
## records, per roster id, the NPC id every definition got and whether the
## roster is complete; ensure_seeded() does nothing for a complete roster,
## so neither a restart nor a cell that is loaded again places anybody
## twice. A new world is seeded when it is created; a world saved before it
## had a roster is seeded the first time a server starts it
## (WorldPersistence). Without a roster (tests, tools) nobody is placed.
##
## Save: per cell document `systems.npc` =
##   {schema_version, npcs: [NpcState.to_dict()]}
## and world_state.json `systems.npc` =
##   {schema_version,
##    population: {npc_id: definition_id},      every NPC of the world
##    rosters: {roster_id: {content_version, npcs: {definition_id: npc_id},
##                          complete}},
##    npcs: [...],     only NPCs that are not saved with a cell document
##    stages: {stage_id: NpcStage.to_world_document()}}
## A world that never had an NPC, a roster or a stage document saves
## nothing (the save looks as it did before this system existed).

const SYSTEM_ID: String = "npc"
const SCHEMA_VERSION: int = 1
## Version of this system's part of a cell document.
const CELL_SCHEMA_VERSION: int = 1
const ENTITY_KIND: String = NpcState.ENTITY_KIND
const KEY_NPCS: String = "npcs"
const KEY_POPULATION: String = "population"
const KEY_ROSTERS: String = "rosters"
const KEY_STAGES: String = "stages"
const KEY_CONTENT_VERSION: String = "content_version"
const KEY_COMPLETE: String = "complete"
## Keys of the success events.
const KEY_NPC_ID: String = "npc_id"
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_POSITION: String = "position"
const EVENT_SPAWNED: String = "npc_spawned"
const EVENT_REMOVED: String = "npc_removed"
## Keys of last_seed_report.
const REPORT_NPCS: String = "npcs"
const REPORT_CELLS_LOADED: String = "cells_loaded"
const REPORT_RELEASES: String = "releases"
const REPORT_USEC: String = "usec"

const REASON_UNAVAILABLE: String = "npcs_unavailable"
const REASON_UNKNOWN_DEFINITION: String = "unknown_npc_definition"
const REASON_BAD_POSITION: String = "bad_position"
const REASON_CELL_NOT_LOADED: String = "cell_not_loaded"
const REASON_LIMIT: String = "npc_limit"
const REASON_ID_FAILED: String = "npc_id_failed"
const REASON_UNKNOWN_NPC: String = "unknown_npc"

## An NPC came into memory (it was spawned, or its cell was loaded).
signal npc_entered(npc_id: String)
## An NPC left memory: its cell was released, or (`retired`) it was removed
## from the world for good.
signal npc_left(npc_id: String, retired: bool)
## The NPC's cell is simulated from now on / is no longer simulated.
signal npc_woke(npc_id: String)
signal npc_slept(npc_id: String)

## Diagnostics (tests / profiling): how long the stages of the last tick
## took (0 without stages), moves refused by set_npc_transform, and what
## the last ensure_seeded() that looked at the roster did ({} = it never
## had to): NPCs placed, cells it brought into memory, how often it saved
## and released them, and how long it took (microseconds, wall clock).
var last_step_msec: float = 0.0
var blocked_move_count: int = 0
var last_seed_report: Dictionary = {}

var _settings: NpcSettings
var _definitions: NpcCatalog
var _roster: NpcRoster
var _map_content: MapContentDefinition
var _grid: StructureGrid
var _ids: EntityIdGenerator
var _registry: EntityRegistry
var _clock: WorldClock
## The world this system is registered with (weak: the world owns it).
var _world_ref: WeakRef = null
## NPCs in memory.
var _npcs: Dictionary[String, NpcState] = {}
## NPCs in memory whose cell is simulated.
var _awake: Dictionary[String, bool] = {}
## Every NPC of the world, in memory or not: npc_id -> definition_id.
var _population: Dictionary[String, String] = {}
## roster_id -> {content_version: int, npcs: {definition_id: npc_id},
## complete: bool}: what this world was seeded with.
var _rosters: Dictionary[String, Dictionary] = {}
## component_id -> factory (a Callable that returns a new NpcComponent).
var _component_factories: Dictionary[String, Callable] = {}
## Sorted ids of the registered components (creation and restore order).
var _component_order: PackedStringArray = []
var _stages: Array[NpcStage] = []
## stage_id -> saved document of a stage that is not registered.
var _unclaimed_stage_documents: Dictionary = {}
## True once an NPC exists or was restored: no component can be registered
## any more (every NPC must have got every component).
var _sealed: bool = false
## Unregistered component ids already warned about (once per id).
var _warned_components: Dictionary[String, bool] = {}


## `roster` null = this world is given no NPCs (tests, tools). `map_content`
## and `grid` say where the roster's home spots are; both may be null
## without a roster.
func _init(settings: NpcSettings, definitions: NpcCatalog, roster: NpcRoster, map_content: MapContentDefinition, grid: StructureGrid, ids: EntityIdGenerator, registry: EntityRegistry, clock: WorldClock) -> void:
	_settings = settings
	_definitions = definitions
	_roster = roster
	_map_content = map_content
	_grid = grid
	_ids = ids
	_registry = registry
	_clock = clock


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ seams

## Registers a kind of component: `factory` is called without arguments and
## returns a new NpcComponent whose component_id() is `component_id`. Every
## NPC gets one instance. Must be called before the first NPC exists
## (ServerComposition): ERR_UNAVAILABLE afterwards. Other failures:
## ERR_INVALID_PARAMETER (the id is not snake_case), ERR_ALREADY_EXISTS,
## ERR_INVALID_DATA (the factory makes something else).
func register_component(component_id: String, factory: Callable) -> Error:
	if not NpcComponent.is_valid_id(component_id) or component_id == NpcComponent.KEY_SCHEMA_VERSION:
		GameLogger.error("npc", "invalid npc component id", {"component_id": component_id, "operation": "register_component"})
		return ERR_INVALID_PARAMETER
	if _component_factories.has(component_id):
		GameLogger.error("npc", "duplicate npc component", {"component_id": component_id, "operation": "register_component"})
		return ERR_ALREADY_EXISTS
	if _sealed:
		GameLogger.error("npc", "npc components must be registered before the first NPC exists", {"component_id": component_id, "operation": "register_component"})
		return ERR_UNAVAILABLE
	var sample: NpcComponent = _make_component(factory)
	if sample == null or sample.component_id() != component_id or sample.schema_version() < 1:
		GameLogger.error("npc", "the factory does not make this npc component", {"component_id": component_id, "operation": "register_component"})
		return ERR_INVALID_DATA
	_component_factories[component_id] = factory
	_component_order.append(component_id)
	_component_order.sort()
	return OK


## Adds a stage (see NpcStage). Stages are called in the order they were
## added. Failures: ERR_INVALID_PARAMETER (no snake_case id),
## ERR_ALREADY_EXISTS.
func add_stage(stage: NpcStage) -> Error:
	if stage == null or not NpcComponent.is_valid_id(stage.stage_id()):
		GameLogger.error("npc", "invalid npc stage id", {"stage_id": stage.stage_id() if stage != null else "", "operation": "add_stage"})
		return ERR_INVALID_PARAMETER
	for existing: NpcStage in _stages:
		if existing.stage_id() == stage.stage_id():
			GameLogger.error("npc", "duplicate npc stage", {"stage_id": stage.stage_id(), "operation": "add_stage"})
			return ERR_ALREADY_EXISTS
	_stages.append(stage)
	return OK


# ------------------------------------------------------------ server rules

## Creates an NPC as a server rule (no actor, no range): see the header.
## Success event: {event_type: "npc_spawned", npc_id, definition_id,
## position: [x, y, z], yaw, cell_id, world_time}.
func spawn_npc(world: ServerWorld, definition_id: String, position: Vector3, yaw: float = 0.0) -> ActionResult:
	if world == null:
		return ActionResult.failure(REASON_UNAVAILABLE)
	var definition: NpcDefinition = _definitions.get_definition(definition_id)
	if definition == null:
		return ActionResult.failure(REASON_UNKNOWN_DEFINITION)
	if not _is_valid_place(world, position) or not is_finite(yaw):
		return ActionResult.failure(REASON_BAD_POSITION)
	var cell_id: String = world.cell_id_at(position)
	if not world.is_cell_loaded(cell_id):
		return ActionResult.failure(REASON_CELL_NOT_LOADED)
	if _population.size() >= _settings.max_npcs:
		GameLogger.warning("npc", "npc limit reached; the spawn is refused", {"definition_id": definition_id, "max_npcs": _settings.max_npcs, "operation": "spawn_npc"})
		return ActionResult.failure(REASON_LIMIT)
	var npc_id: String = _ids.next_id(ENTITY_KIND)
	if npc_id.is_empty() or _registry.register(npc_id, ENTITY_KIND) != OK:
		GameLogger.error("npc", "npc id could not be registered", {"entity_id": npc_id, "definition_id": definition_id, "operation": "spawn_npc"})
		return ActionResult.failure(REASON_ID_FAILED)
	var npc: NpcState = NpcState.new()
	npc.npc_id = npc_id
	npc.definition_id = definition_id
	npc.position = position
	npc.yaw = yaw
	npc.created_at = _clock.world_time_sec
	npc.last_simulated_world_time = _clock.world_time_sec
	npc.rng.seed = NpcState.seed_for(_settings.world_seed, npc_id)
	_sealed = true
	for component_id: String in _component_order:
		var live: NpcComponent = _make_component(_component_factories[component_id])
		live.on_created(npc, definition, _clock)
		npc.set_component(live)
	_population[npc_id] = definition_id
	_enter(world, npc)
	GameLogger.info("npc", "npc spawned", {"entity_id": npc_id, "definition_id": definition_id, "cell_id": cell_id})
	return ActionResult.success({
		"event_type": EVENT_SPAWNED,
		"world_time": _clock.world_time_sec,
		"cell_id": cell_id,
		KEY_NPC_ID: npc_id,
		KEY_DEFINITION_ID: definition_id,
		KEY_POSITION: [position.x, position.y, position.z],
		"yaw": yaw,
	})


## Removes an NPC that is in memory from the world for good. Its id is
## retired and can never come back, not even from an old cell file.
## Failure: unknown_npc (also for an NPC whose cell is not in memory).
## Success event: {event_type: "npc_removed", npc_id, cell_id, world_time}.
func remove_npc(world: ServerWorld, npc_id: String) -> ActionResult:
	var npc: NpcState = _npcs.get(npc_id, null)
	if world == null or npc == null:
		return ActionResult.failure(REASON_UNKNOWN_NPC)
	var cell_id: String = world.cell_index.cell_of(npc_id)
	_leave(world, npc, true)
	_population.erase(npc_id)
	_registry.remove(npc_id)
	GameLogger.info("npc", "npc removed", {"entity_id": npc_id, "cell_id": cell_id, "operation": "remove_npc"})
	return ActionResult.success({"event_type": EVENT_REMOVED, "world_time": _clock.world_time_sec, "cell_id": cell_id, KEY_NPC_ID: npc_id})


## Puts an NPC that is in memory at `position`, facing `yaw`. True when it
## is there afterwards. Refused (false, nothing changes, counted in
## blocked_move_count) when the position or the yaw is not finite, the
## position is outside the play area, or it lies in a cell that is not in
## memory. An NPC that walks into a cell that is not simulated freezes
## there, and wakes when it comes into a simulated one. This does not check
## walls: whoever moves an NPC asks ServerWorld.resolve_movement first.
func set_npc_transform(world: ServerWorld, npc_id: String, position: Vector3, yaw: float) -> bool:
	var npc: NpcState = _npcs.get(npc_id, null)
	if world == null or npc == null:
		return false
	if not _is_valid_place(world, position) or not is_finite(yaw):
		blocked_move_count += 1
		return false
	var previous_cell_id: String = world.cell_index.cell_of(npc_id)
	var cell_id: String = world.cell_id_at(position)
	if cell_id != previous_cell_id and not world.is_cell_loaded(cell_id):
		blocked_move_count += 1
		return false
	if npc.position == position and npc.yaw == yaw:
		return true
	npc.position = position
	npc.yaw = yaw
	if cell_id == previous_cell_id:
		mark_cell_save_dirty(cell_id)
		return true
	# The index tells the world that both cells changed.
	world.cell_index.put(npc_id, ENTITY_KIND, cell_id)
	if world.is_cell_simulated(cell_id):
		_wake(world, npc)
	else:
		_sleep(world, npc)
	return true


## Sets the tier of an NPC that is awake to "near" or "far" (the scheduler's
## decision, P4-3). False for an NPC that is not awake (a frozen NPC stays
## frozen: its cell decides) and for any other tier.
func set_simulation_tier(npc_id: String, tier: String) -> bool:
	if not _awake.has(npc_id) or not NpcState.SIMULATED_TIERS.has(tier):
		return false
	_npcs[npc_id].simulation_tier = tier
	return true


## Something that is saved with this NPC changed (a component's document):
## its cell is written again at the next save.
func mark_npc_dirty(npc_id: String) -> void:
	var world: ServerWorld = _world()
	if world != null and _npcs.has(npc_id):
		mark_cell_save_dirty(world.cell_index.cell_of(npc_id))


# ------------------------------------------------------------ queries

func has_npc(npc_id: String) -> bool:
	return _npcs.has(npc_id)


## The NPC with this id when it is in memory, else null. Read-only.
func get_npc(npc_id: String) -> NpcState:
	return _npcs.get(npc_id, null)


## Ids of the NPCs in memory, sorted.
func npc_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_npcs.keys())
	ids.sort()
	return ids


## Number of NPCs in memory.
func npc_count() -> int:
	return _npcs.size()


## Ids of the NPCs in one cell (in memory), sorted.
func npc_ids_in_cell(cell_id: String) -> PackedStringArray:
	var world: ServerWorld = _world()
	return world.cell_index.entities_in_cell(cell_id, ENTITY_KIND) if world != null else PackedStringArray()


func is_awake(npc_id: String) -> bool:
	return _awake.has(npc_id)


## Ids of the NPCs that are simulated now, sorted (a deterministic order
## for whoever steps them).
func awake_npc_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_awake.keys())
	ids.sort()
	return ids


func awake_count() -> int:
	return _awake.size()


## The definition of an NPC of this world (in memory or not), or null.
func definition_of(npc_id: String) -> NpcDefinition:
	return _definitions.get_definition(_population.get(npc_id, ""))


## Number of NPCs of the whole world, in memory or not.
func population_count() -> int:
	return _population.size()


## Ids of every NPC of the world, sorted.
func population_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_population.keys())
	ids.sort()
	return ids


## Save data of one NPC in memory as it would be written now ({} = not in
## memory). For an awake NPC `last_simulated_world_time` is now: whoever
## reads the document later finds an NPC that was simulated until then.
func npc_document(npc_id: String) -> Dictionary:
	var npc: NpcState = _npcs.get(npc_id, null)
	return _document_of(npc) if npc != null else {}


## True when the world was completely given the roster `roster_id` (the
## configured roster's by default).
func is_seeded(roster_id: String = "") -> bool:
	var key: String = roster_id if not roster_id.is_empty() else (_roster.roster_id if _roster != null else "")
	return bool((_rosters.get(key, {}) as Dictionary).get(KEY_COMPLETE, false))


## Ids of the NPCs this world was given from a roster, sorted.
func seeded_npc_ids(roster_id: String) -> PackedStringArray:
	var ids: PackedStringArray = []
	var placed: Dictionary = (_rosters.get(roster_id, {}) as Dictionary).get(KEY_NPCS, {})
	for definition_id: Variant in placed:
		ids.append(str(placed[definition_id]))
	ids.sort()
	return ids


## The NPC id a definition of a roster got in this world ("" = not placed).
func seeded_npc_id(roster_id: String, definition_id: String) -> String:
	return str(((_rosters.get(roster_id, {}) as Dictionary).get(KEY_NPCS, {}) as Dictionary).get(definition_id, ""))


# ------------------------------------------------------------ roster

## Places every NPC of the configured roster that this world does not have
## yet on its home spot, and records it. Does nothing without a roster or
## for a complete one that has every definition of the roster. Returns OK, or an error (logged) when a home spot
## cannot be found, its cell cannot be loaded, the spawn is refused or the
## cells cannot be saved: the roster is then not marked complete and the
## next call goes on where this one stopped.
func ensure_seeded(world: ServerWorld) -> Error:
	if _roster == null:
		return OK
	var roster_id: String = _roster.roster_id
	var record: Dictionary = _rosters.get(roster_id, {})
	if bool(record.get(KEY_COMPLETE, false)):
		# A roster that grew since this world got it (2026-11-23: five dev
		# NPCs became ten) places the new definitions now. Who the world has
		# stays: a definition taken out of the roster keeps its NPC, and a
		# placed definition is never placed again.
		var missing: int = 0
		for definition_id: String in _roster.npc_definition_ids:
			if not (record[KEY_NPCS] as Dictionary).has(definition_id):
				missing += 1
		if missing == 0:
			if int(record.get(KEY_CONTENT_VERSION, 0)) != _roster.content_version:
				GameLogger.info("npc", "the roster changed since this world was given it; the world keeps who it has", {"world_id": world.world_id, "roster_id": roster_id, "seeded_version": int(record.get(KEY_CONTENT_VERSION, 0)), "content_version": _roster.content_version})
			return OK
		GameLogger.info("npc", "the roster grew since this world was given it; the new NPCs are placed", {"world_id": world.world_id, "roster_id": roster_id, "seeded_version": int(record.get(KEY_CONTENT_VERSION, 0)), "content_version": _roster.content_version, "missing": missing})
		record[KEY_COMPLETE] = false
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	var started_usec: int = Time.get_ticks_usec()
	if record.is_empty():
		record = {KEY_CONTENT_VERSION: _roster.content_version, KEY_NPCS: {}, KEY_COMPLETE: false}
		_rosters[roster_id] = record
	var placed: Dictionary = record[KEY_NPCS]
	var report: Dictionary = {REPORT_NPCS: 0, REPORT_CELLS_LOADED: 0, REPORT_RELEASES: 0, REPORT_USEC: 0}
	var loaded_here: Array[String] = []
	var error: Error = OK
	for definition_id: String in _roster.npc_definition_ids:
		if placed.has(definition_id):
			continue
		error = _place_roster_npc(world, cells, definition_id, placed, loaded_here, report)
		if error != OK:
			break
	if error == OK:
		record[KEY_COMPLETE] = true
		record[KEY_CONTENT_VERSION] = _roster.content_version
	var release_error: Error = _release(world, cells, loaded_here, report)
	if error == OK:
		error = release_error
	report[REPORT_USEC] = Time.get_ticks_usec() - started_usec
	last_seed_report = report
	if error != OK:
		record[KEY_COMPLETE] = false
		GameLogger.error("npc", "the roster could not be placed completely", {"world_id": world.world_id, "roster_id": roster_id, "error": error_string(error), "npcs_placed": placed.size(), "operation": "seed_roster"})
		return error
	GameLogger.info("npc", "npc roster seeded", {"world_id": world.world_id, "roster_id": roster_id, "content_version": _roster.content_version, "npcs": int(report[REPORT_NPCS]), "cells_loaded": int(report[REPORT_CELLS_LOADED]), "msec": float(int(report[REPORT_USEC])) / 1000.0})
	return OK


# ------------------------------------------------------------ ServerSystem

func on_registered(world: ServerWorld) -> void:
	_world_ref = weakref(world)


## A brand-new world gets the roster at once (after the map content, which
## is registered before this system).
func seed_new_world(world: ServerWorld) -> Error:
	return ensure_seeded(world)


## Runs the stages. Without stages (P4-1) nothing happens: NPCs stand still.
func step(world: ServerWorld, action_delta: float, world_delta: float) -> void:
	if _stages.is_empty():
		last_step_msec = 0.0
		return
	var started_usec: int = Time.get_ticks_usec()
	for stage: NpcStage in _stages:
		stage.step(world, self, action_delta, world_delta)
	last_step_msec = float(Time.get_ticks_usec() - started_usec) / 1000.0


## The roster record, the list of every NPC, the documents of the stages,
## and the NPCs that are NOT saved with a cell document (all of them in a
## world without a saved cell store, normally none on a dedicated server).
## {} when there is nothing of all that.
func to_world_document() -> Dictionary:
	var world: ServerWorld = _world()
	var npcs: Array[Dictionary] = []
	if world == null or not world.saves_all_loaded_entities_in_cells():
		for npc_id: String in npc_ids():
			if world != null and world.saves_cell_document(world.cell_index.cell_of(npc_id)):
				continue
			npcs.append(_document_of(_npcs[npc_id]))
	var stage_documents: Dictionary = _unclaimed_stage_documents.duplicate(true)
	for stage: NpcStage in _stages:
		var stage_document: Dictionary = stage.to_world_document()
		if not stage_document.is_empty():
			stage_documents[stage.stage_id()] = stage_document
	if _population.is_empty() and _rosters.is_empty() and npcs.is_empty() and stage_documents.is_empty():
		return {}
	var population: Dictionary = {}
	for npc_id: String in population_ids():
		population[npc_id] = _population[npc_id]
	var rosters: Dictionary = {}
	for roster_id: String in _rosters:
		rosters[roster_id] = {
			KEY_CONTENT_VERSION: int(_rosters[roster_id][KEY_CONTENT_VERSION]),
			KEY_NPCS: (_rosters[roster_id][KEY_NPCS] as Dictionary).duplicate(),
			KEY_COMPLETE: bool(_rosters[roster_id][KEY_COMPLETE]),
		}
	var document: Dictionary = {"schema_version": SCHEMA_VERSION, KEY_POPULATION: population, KEY_ROSTERS: rosters}
	if not npcs.is_empty():
		document[KEY_NPCS] = npcs
	if not stage_documents.is_empty():
		document[KEY_STAGES] = stage_documents
	return document


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var world: ServerWorld = _world()
	if world == null:
		return PackedStringArray(["npc: not registered with a world"])
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != SCHEMA_VERSION:
		errors.append("npc: unsupported schema_version")
		return errors
	var population: Dictionary[String, String] = _read_population(document.get(KEY_POPULATION, null), errors)
	var rosters: Dictionary[String, Dictionary] = _read_rosters(document.get(KEY_ROSTERS, null), errors)
	var stage_documents: Variant = document.get(KEY_STAGES, {})
	if typeof(stage_documents) != TYPE_DICTIONARY:
		errors.append("npc: stages must be an object")
		return errors
	for stage_id: Variant in (stage_documents as Dictionary):
		if typeof(stage_id) != TYPE_STRING or typeof((stage_documents as Dictionary)[stage_id]) != TYPE_DICTIONARY:
			errors.append("npc: invalid stage document")
	var entries: Variant = document.get(KEY_NPCS, [])
	var restored: Array[NpcState] = _read_npcs(world, entries, "npc", true, errors)
	if not errors.is_empty():
		return errors
	var unclaimed: Dictionary = (stage_documents as Dictionary).duplicate(true)
	for stage: NpcStage in _stages:
		if unclaimed.has(stage.stage_id()):
			errors.append_array(stage.restore_world_document(unclaimed[stage.stage_id()] as Dictionary))
			unclaimed.erase(stage.stage_id())
	if not errors.is_empty():
		return errors
	_unclaimed_stage_documents = unclaimed
	_population = population
	_rosters = rosters
	_sealed = _sealed or not population.is_empty()
	for npc: NpcState in restored:
		_adopt(world, npc)
	return errors


# ------------------------------------------------------------ world cells

## The cell became ACTIVE: its NPCs are simulated from now on.
func on_cell_activated(world: ServerWorld, cell_id: String) -> void:
	for npc_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND):
		var npc: NpcState = _npcs.get(npc_id, null)
		if npc != null:
			_wake(world, npc)


## The cell is no longer ACTIVE: its NPCs freeze as they are.
func on_cell_deactivated(world: ServerWorld, cell_id: String) -> void:
	for npc_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND):
		var npc: NpcState = _npcs.get(npc_id, null)
		if npc != null:
			_sleep(world, npc)


## The NPCs of one cell as save data ({} = none), sorted by id.
func to_cell_document(cell_id: String) -> Dictionary:
	var world: ServerWorld = _world()
	if world == null:
		return {}
	var npcs: Array[Dictionary] = []
	for npc_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND):
		if _npcs.has(npc_id):
			npcs.append(_document_of(_npcs[npc_id]))
	if npcs.is_empty():
		return {}
	return {"schema_version": CELL_SCHEMA_VERSION, KEY_NPCS: npcs}


## Brings the saved NPCs of a cell back, exactly as they were saved (ids,
## definition, position, facing, generator, every component document).
## Validates first: on any error nothing changes. What is in memory wins
## over a saved copy: an NPC whose id is in memory or was retired is skipped
## and logged (this only happens when a cell file is older than the rest of
## the save). The cell of each NPC is decided by its position, so documents
## cut with another cell grid restore as well.
func restore_cell_document(world: ServerWorld, cell_id: String, document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != CELL_SCHEMA_VERSION:
		errors.append("npc: cell %s: unsupported schema_version" % cell_id)
		return errors
	var restored: Array[NpcState] = _read_npcs(world, document.get(KEY_NPCS, null), "npc: cell %s" % cell_id, false, errors)
	if not errors.is_empty():
		return errors
	for npc: NpcState in restored:
		_adopt(world, npc)
	return errors


## Forgets the NPCs of a cell (it was saved). Their ids are released, not
## retired: they still exist.
func release_cell(world: ServerWorld, cell_id: String) -> void:
	for npc_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND):
		var npc: NpcState = _npcs.get(npc_id, null)
		if npc != null:
			_leave(world, npc, false)
		else:
			world.cell_index.remove(npc_id)
		_registry.release(npc_id)


# ------------------------------------------------------------ internals

func _world() -> ServerWorld:
	return _world_ref.get_ref() as ServerWorld if _world_ref != null else null


## True when an NPC may stand at this position: finite and inside the play
## area.
func _is_valid_place(world: ServerWorld, position: Vector3) -> bool:
	var limit: float = world.gameplay.world_half_extent_m
	return position.is_finite() and absf(position.x) <= limit and absf(position.z) <= limit


## A new component from a factory, or null when it makes something else.
func _make_component(factory: Callable) -> NpcComponent:
	if not factory.is_valid():
		return null
	var made: Variant = factory.call()
	return made as NpcComponent if made is NpcComponent else null


## Save data of one NPC as it is written now (see npc_document).
func _document_of(npc: NpcState) -> Dictionary:
	var document: Dictionary = npc.to_dict()
	if _awake.has(npc.npc_id):
		document[NpcState.KEY_LAST_SIMULATED] = _clock.world_time_sec
	return document


## Puts an NPC that just came into memory into this system's maps and the
## cell index, tells its components and the stages, and wakes it when its
## cell is simulated.
func _enter(world: ServerWorld, npc: NpcState) -> void:
	var cell_id: String = world.cell_id_at(npc.position)
	_npcs[npc.npc_id] = npc
	npc.simulation_tier = NpcState.TIER_FROZEN
	world.cell_index.put(npc.npc_id, ENTITY_KIND, cell_id)
	for component_id: String in npc.component_ids():
		npc.component(component_id).on_attached(world, npc)
	for stage: NpcStage in _stages:
		stage.on_npc_entered(world, npc)
	npc_entered.emit(npc.npc_id)
	if world.is_cell_simulated(cell_id):
		_wake(world, npc)


## Takes an NPC out of memory: it sleeps first, then the stages and its
## components hear that it leaves. The caller releases or retires its id.
func _leave(world: ServerWorld, npc: NpcState, retired: bool) -> void:
	_sleep(world, npc)
	for stage: NpcStage in _stages:
		stage.on_npc_left(world, npc, retired)
	for component_id: String in npc.component_ids():
		npc.component(component_id).on_detached(world, npc, retired)
	_npcs.erase(npc.npc_id)
	world.cell_index.remove(npc.npc_id)
	npc_left.emit(npc.npc_id, retired)


## The NPC is simulated from now on.
func _wake(world: ServerWorld, npc: NpcState) -> void:
	if _awake.has(npc.npc_id):
		return
	_awake[npc.npc_id] = true
	npc.simulation_tier = NpcState.TIER_NEAR
	for stage: NpcStage in _stages:
		stage.on_npc_woke(world, npc)
	npc_woke.emit(npc.npc_id)


## The NPC is no longer simulated (frozen as it is). It remembers until
## when it was simulated.
func _sleep(world: ServerWorld, npc: NpcState) -> void:
	if not _awake.erase(npc.npc_id):
		return
	npc.simulation_tier = NpcState.TIER_FROZEN
	npc.last_simulated_world_time = _clock.world_time_sec
	mark_cell_save_dirty(world.cell_index.cell_of(npc.npc_id))
	for stage: NpcStage in _stages:
		stage.on_npc_slept(world, npc)
	npc_slept.emit(npc.npc_id)


## Registers a restored NPC (already checked by _read_npcs) and brings it
## into memory.
func _adopt(world: ServerWorld, npc: NpcState) -> void:
	_registry.register(npc.npc_id, ENTITY_KIND)
	_ids.reserve_existing_id(npc.npc_id)
	_sealed = true
	if not _population.has(npc.npc_id):
		_population[npc.npc_id] = npc.definition_id
	_enter(world, npc)


## Reads and checks the NPCs of a save document, components included.
## Returns the states, not yet in memory. On any error `errors` is filled
## and the result must not be used. `strict` (the world document): an NPC
## whose id is already known or retired is an error. Otherwise (a cell
## document) such an NPC is skipped and logged.
func _read_npcs(world: ServerWorld, entries: Variant, context: String, strict: bool, errors: PackedStringArray) -> Array[NpcState]:
	var restored: Array[NpcState] = []
	if typeof(entries) != TYPE_ARRAY:
		errors.append("%s: npcs must be an array" % context)
		return restored
	var seen: Dictionary[String, bool] = {}
	var skipped: PackedStringArray = []
	for entry: Variant in (entries as Array):
		var npc: NpcState = NpcState.from_dict(entry as Dictionary) if typeof(entry) == TYPE_DICTIONARY else null
		if npc == null:
			errors.append("%s: invalid npc entry" % context)
			continue
		var definition: NpcDefinition = _definitions.get_definition(npc.definition_id)
		if definition == null:
			errors.append("%s: unknown definition %s for %s" % [context, npc.definition_id, npc.npc_id])
			continue
		if not _is_valid_place(world, npc.position):
			errors.append("%s: %s stands outside the play area" % [context, npc.npc_id])
			continue
		if seen.has(npc.npc_id):
			errors.append("%s: duplicate id %s" % [context, npc.npc_id])
			continue
		seen[npc.npc_id] = true
		if _npcs.has(npc.npc_id) or _registry.has(npc.npc_id) or _registry.is_tombstoned(npc.npc_id):
			if strict:
				errors.append("%s: duplicate or removed id %s" % [context, npc.npc_id])
			else:
				skipped.append(npc.npc_id)
			continue
		var component_errors: PackedStringArray = _restore_components(npc, definition)
		if not component_errors.is_empty():
			errors.append("%s: %s: %s" % [context, npc.npc_id, "; ".join(component_errors)])
			continue
		restored.append(npc)
	if errors.is_empty() and not skipped.is_empty():
		GameLogger.warning("npc", "saved npcs skipped: already in memory or removed", {"context": context, "npcs": ", ".join(skipped), "operation": "restore"})
	return restored


## Gives a state read from a save its live components: a registered
## component restores its saved document, or starts fresh when the NPC was
## saved before the component existed. Documents of components that are not
## registered stay with the state untouched.
func _restore_components(npc: NpcState, definition: NpcDefinition) -> PackedStringArray:
	var errors: PackedStringArray = []
	var live_components: Array[NpcComponent] = []
	for component_id: String in _component_order:
		var live: NpcComponent = _make_component(_component_factories[component_id])
		var saved: Dictionary = npc.unclaimed_document(component_id)
		if saved.is_empty():
			live.on_created(npc, definition, _clock)
		else:
			for message: String in live.restore_document(saved):
				errors.append("component %s: %s" % [component_id, message])
		live_components.append(live)
	if not errors.is_empty():
		return errors
	for live: NpcComponent in live_components:
		npc.set_component(live)
	for component_id: String in npc.unclaimed_component_ids():
		if not _warned_components.has(component_id):
			_warned_components[component_id] = true
			GameLogger.warning("npc", "save has data of an unregistered npc component (kept as it is)", {"component_id": component_id, "entity_id": npc.npc_id, "operation": "restore"})
	return errors


func _read_population(raw: Variant, errors: PackedStringArray) -> Dictionary[String, String]:
	var population: Dictionary[String, String] = {}
	if typeof(raw) != TYPE_DICTIONARY:
		errors.append("npc: population must be an object")
		return population
	for npc_id: Variant in (raw as Dictionary):
		var definition_id: Variant = (raw as Dictionary)[npc_id]
		if typeof(npc_id) != TYPE_STRING or not NpcState.is_valid_npc_id(str(npc_id)) or typeof(definition_id) != TYPE_STRING or not ItemInstance.is_valid_definition_id(str(definition_id)):
			errors.append("npc: invalid population entry %s" % str(npc_id))
			continue
		population[str(npc_id)] = str(definition_id)
	return population


func _read_rosters(raw: Variant, errors: PackedStringArray) -> Dictionary[String, Dictionary]:
	var rosters: Dictionary[String, Dictionary] = {}
	if typeof(raw) != TYPE_DICTIONARY:
		errors.append("npc: rosters must be an object")
		return rosters
	for roster_id: Variant in (raw as Dictionary):
		var entry: Variant = (raw as Dictionary)[roster_id]
		if typeof(entry) != TYPE_DICTIONARY or not ItemInstance.is_integer_value((entry as Dictionary).get(KEY_CONTENT_VERSION, null)) or typeof((entry as Dictionary).get(KEY_NPCS, null)) != TYPE_DICTIONARY or typeof((entry as Dictionary).get(KEY_COMPLETE, null)) != TYPE_BOOL:
			errors.append("npc: invalid record of roster %s" % str(roster_id))
			continue
		var placed: Dictionary = {}
		for definition_id: Variant in ((entry as Dictionary)[KEY_NPCS] as Dictionary):
			var npc_id: Variant = ((entry as Dictionary)[KEY_NPCS] as Dictionary)[definition_id]
			if typeof(definition_id) != TYPE_STRING or typeof(npc_id) != TYPE_STRING or not NpcState.is_valid_npc_id(str(npc_id)):
				errors.append("npc: invalid npc in the record of roster %s" % str(roster_id))
				continue
			placed[str(definition_id)] = str(npc_id)
		rosters[str(roster_id)] = {KEY_CONTENT_VERSION: int((entry as Dictionary)[KEY_CONTENT_VERSION]), KEY_NPCS: placed, KEY_COMPLETE: bool((entry as Dictionary)[KEY_COMPLETE])}
	return rosters


## Places one NPC of the roster on its home spot: brings the cell of the
## spot into memory, spawns the NPC and records its id.
func _place_roster_npc(world: ServerWorld, cells: WorldCellService, definition_id: String, placed: Dictionary, loaded_here: Array[String], report: Dictionary) -> Error:
	var definition: NpcDefinition = _definitions.get_definition(definition_id)
	var home: Variant = NpcRoster.spot_position(_map_content, _grid, definition.home_building_id, definition.home_tile_offset) if definition != null else null
	if not (home is Vector3):
		GameLogger.error("npc", "an NPC of the roster has no home spot on this map", {"world_id": world.world_id, "definition_id": definition_id, "operation": "seed_roster"})
		return ERR_INVALID_DATA
	var cell_id: String = world.cell_id_at(home as Vector3)
	if not world.is_cell_loaded(cell_id):
		if cells == null or not cells.load_cell_now(world, cell_id):
			GameLogger.error("npc", "the cell of a home spot could not be loaded", {"world_id": world.world_id, "cell_id": cell_id, "definition_id": definition_id, "operation": "seed_roster"})
			return ERR_CANT_OPEN
		loaded_here.append(cell_id)
		report[REPORT_CELLS_LOADED] = int(report[REPORT_CELLS_LOADED]) + 1
	var spawned: ActionResult = spawn_npc(world, definition_id, home as Vector3)
	if not spawned.ok:
		GameLogger.error("npc", "an NPC of the roster was refused", {"world_id": world.world_id, "definition_id": definition_id, "reason": spawned.reason, "operation": "seed_roster"})
		return ERR_INVALID_DATA
	placed[definition_id] = str(spawned.event[KEY_NPC_ID])
	report[REPORT_NPCS] = int(report[REPORT_NPCS]) + 1
	return OK


## Saves and releases the cells a seeding brought into memory. A world
## without a cell store keeps them (it never releases a cell).
func _release(world: ServerWorld, cells: WorldCellService, loaded_here: Array[String], report: Dictionary) -> Error:
	if cells == null or loaded_here.is_empty():
		return OK
	if cells.get_store() == null:
		loaded_here.clear()
		return OK
	var error: Error = cells.release_cells_now(world, PackedStringArray(loaded_here))
	if error != OK:
		return error
	loaded_here.clear()
	report[REPORT_RELEASES] = int(report[REPORT_RELEASES]) + 1
	return OK
