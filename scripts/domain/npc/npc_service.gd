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
##   refresh_simulation(world, npc_id)
##       a component changed whether its NPC may be simulated
##       (NpcComponent.blocks_simulation, F-25: it died): the NPC sleeps for
##       good, or wakes when nothing blocks it and its cell is simulated.
##   get_stage(stage_id)      the stage with this id, or null
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
## Homes (F-28, docs/09 §17.13): in a world with a generated map every NPC
## of the roster lives alone in a generated building chosen with the world
## seed (NpcHomePicker; one NPC per building, spread over the towns and the
## countryside). The roster record keeps which building each definition got
## (`homes`), the NPC keeps it in its NpcHome component. The cell of a home
## is brought into memory and built completely before the NPC is put into
## it, its containers are searched (their loot is rolled) and one of them
## gets the home stock (NpcHomeSettings), once. In a world without a
## generated map (tests, tools) the NPCs are placed on the home spots their
## definitions name, as before. NPCs a world placed that way before it had
## lone homes are moved to their generated home once, the first time each
## is in memory (one per tick, in step(); a dead NPC stays where it is).
##
## Moving (F-30, docs/09 §17.15): an NPC that lives alone may move to
## another generated building by itself (NpcRelocation). While it is on its
## way the building it moves to is claimed for it (`home_claims`, saved
## with the world, so the claim holds while the NPC's cell is not in
## memory); when it moves in, the roster record's `homes` names the new
## building and the old one is free. is_seeded_home() is true for both
## kinds, so nobody searches or takes a building somebody lives in or
## moves to. Nothing here places or relocates an NPC that moved by itself.
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
##                          complete,
##                          homes: {definition_id: building_id}}},   (F-28;
##                          only definitions with a generated home)
##    home_claims: {building_id: npc_id},       (F-30; left out when empty)
##                     buildings an NPC is moving to, and the homes of
##                     NPCs that are in no roster
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
## F-28: {definition_id: generated building id} of a roster record.
const KEY_HOMES: String = "homes"
## F-30: world document: {building_id: npc_id}.
const KEY_HOME_CLAIMS: String = "home_claims"
const MAX_HOME_CLAIMS: int = 4096
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
## F-28: NPCs placed in a generated home, homes chosen, and how long the
## choosing took (microseconds, wall clock; part of `usec`).
const REPORT_GENERATED_HOMES: String = "generated_homes"
const REPORT_HOMES_CHOSEN: String = "homes_chosen"
const REPORT_CHOOSING_USEC: String = "choosing_usec"

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
## F-28: NPCs moved from the hand-made map to a generated home since this
## system was created, and how long the slowest move took (microseconds).
var relocated_count: int = 0
var max_relocation_usec: int = 0

var _settings: NpcSettings
var _definitions: NpcCatalog
var _roster: NpcRoster
var _map_content: MapContentDefinition
var _grid: StructureGrid
## F-28: where NPCs live (null = on the home spots of their definitions).
var _homes: NpcHomes = null
## NPCs in memory that wait to be moved to their generated home.
var _pending_relocations: Dictionary[String, bool] = {}
## F-30: building_id -> the NPC that moves there (or, for an NPC of no
## roster, lives there).
var _home_claims: Dictionary[String, String] = {}
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

## F-28: gives this system the homes of the world (ServerComposition, before
## the world is seeded or restored). Without it every NPC of the roster is
## placed on the home spot its definition names.
func set_homes(homes: NpcHomes) -> void:
	_homes = homes



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


## Applies NpcComponent.blocks_simulation() after a component changed its
## answer (F-25): a blocked NPC that is awake sleeps now and stays asleep;
## one that is no longer blocked wakes when its cell is simulated. False
## for an NPC that is not in memory.
func refresh_simulation(world: ServerWorld, npc_id: String) -> bool:
	var npc: NpcState = _npcs.get(npc_id, null)
	if world == null or npc == null:
		return false
	if _is_blocked(npc):
		_sleep(world, npc)
	elif world.is_cell_simulated(world.cell_index.cell_of(npc_id)):
		_wake(world, npc)
	return true


## The stage with this id (see add_stage), or null.
func get_stage(stage_id: String) -> NpcStage:
	for stage: NpcStage in _stages:
		if stage.stage_id() == stage_id:
			return stage
	return null


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


## The generated building a definition of a roster lives in, as it was
## chosen for this world ("" = none: it lives where its definition says).
func seeded_home(roster_id: String, definition_id: String) -> String:
	return str(((_rosters.get(roster_id, {}) as Dictionary).get(KEY_HOMES, {}) as Dictionary).get(definition_id, ""))


## True when the generated building is taken: the home of an NPC of a
## roster (as this world chose it, or as the NPC moved, F-30), or claimed
## by an NPC that is moving there. Nobody searches or takes such a building
## (F-29).
func is_seeded_home(building_id: String) -> bool:
	if building_id.is_empty():
		return false
	if _home_claims.has(building_id):
		return true
	for roster_id: String in _rosters:
		var homes: Dictionary = (_rosters[roster_id] as Dictionary).get(KEY_HOMES, {})
		for definition_id: Variant in homes:
			if str(homes[definition_id]) == building_id:
				return true
	return false


## Every taken building (see is_seeded_home): {building_id: true}.
func taken_home_ids() -> Dictionary:
	var taken: Dictionary = {}
	for building_id: String in _home_claims:
		taken[building_id] = true
	for roster_id: String in _rosters:
		var homes: Dictionary = (_rosters[roster_id] as Dictionary).get(KEY_HOMES, {})
		for definition_id: Variant in homes:
			taken[str(homes[definition_id])] = true
	return taken


## The NPC a building is claimed for ("" = nobody; see claim_home).
func home_claim_holder(building_id: String) -> String:
	return str(_home_claims.get(building_id, ""))


## The buildings claimed for an NPC, sorted.
func claimed_homes_of(npc_id: String) -> PackedStringArray:
	var held: PackedStringArray = []
	for building_id: String in _home_claims:
		if _home_claims[building_id] == npc_id:
			held.append(building_id)
	held.sort()
	return held


## F-30: claims a generated building for an NPC that moves there: from now
## on it is taken (is_seeded_home). False (nothing changes) when the
## building is somebody's home or claimed for another NPC. True when the
## NPC holds the claim already.
func claim_home(npc_id: String, building_id: String) -> bool:
	if npc_id.is_empty() or building_id.is_empty():
		return false
	if _home_claims.has(building_id):
		return _home_claims[building_id] == npc_id
	if is_seeded_home(building_id):
		return false
	_home_claims[building_id] = npc_id
	return true


## Gives the claim of an NPC on a building up (its move there was
## abandoned). Nothing happens when the NPC does not hold it.
func release_home_claim(npc_id: String, building_id: String) -> void:
	if str(_home_claims.get(building_id, "")) == npc_id and not npc_id.is_empty():
		_home_claims.erase(building_id)


## Gives every claim of an NPC up, except the one on `except`.
func release_home_claims(npc_id: String, except: String = "") -> void:
	for building_id: String in claimed_homes_of(npc_id):
		if building_id != except:
			_home_claims.erase(building_id)


## F-30: the NPC lives in `building_id` from now on. For an NPC of a
## roster the roster record's `homes` names the building (so nothing
## places or relocates the NPC again, and its old home is free) and its
## claims are given up; for an NPC of no roster a claim on the building is
## what keeps it taken (its other claims are given up). Calling it again
## with the same building changes nothing.
func settle_home(npc_id: String, building_id: String) -> void:
	var npc: NpcState = _npcs.get(npc_id, null)
	if npc == null or building_id.is_empty():
		return
	for roster_id: String in _rosters:
		var record: Dictionary = _rosters[roster_id]
		if str((record[KEY_NPCS] as Dictionary).get(npc.definition_id, "")) != npc_id:
			continue
		var homes: Dictionary = record.get(KEY_HOMES, {})
		if str(homes.get(npc.definition_id, "")) != building_id:
			homes[npc.definition_id] = building_id
			record[KEY_HOMES] = homes
		release_home_claims(npc_id)
		return
	release_home_claims(npc_id, building_id)
	_home_claims[building_id] = npc_id


## Number of NPCs in memory that wait to be moved to their generated home.
func pending_relocation_count() -> int:
	return _pending_relocations.size()


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
	var report: Dictionary = {REPORT_NPCS: 0, REPORT_CELLS_LOADED: 0, REPORT_RELEASES: 0, REPORT_USEC: 0, REPORT_GENERATED_HOMES: 0, REPORT_HOMES_CHOSEN: 0, REPORT_CHOOSING_USEC: 0}
	var started_usec: int = Time.get_ticks_usec()
	if not record.is_empty() and _choose_homes(world, record, report) > 0:
		# A world that placed its NPCs before it had lone homes: they move
		# when they are in memory (step()).
		for npc_id: String in npc_ids():
			if not _relocation_target(_npcs[npc_id]).is_empty():
				_pending_relocations[npc_id] = true
		report[REPORT_USEC] = Time.get_ticks_usec() - started_usec
		last_seed_report = report
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
	if record.is_empty():
		record = {KEY_CONTENT_VERSION: _roster.content_version, KEY_NPCS: {}, KEY_COMPLETE: false}
		_rosters[roster_id] = record
	_choose_homes(world, record, report)
	var placed: Dictionary = record[KEY_NPCS]
	var loaded_here: Array[String] = []
	var error: Error = OK
	for definition_id: String in _roster.npc_definition_ids:
		if placed.has(definition_id):
			continue
		error = _place_roster_npc(world, cells, definition_id, record, loaded_here, report)
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
	GameLogger.info("npc", "npc roster seeded", {"world_id": world.world_id, "roster_id": roster_id, "content_version": _roster.content_version, "npcs": int(report[REPORT_NPCS]), "generated_homes": int(report[REPORT_GENERATED_HOMES]), "cells_loaded": int(report[REPORT_CELLS_LOADED]), "msec": float(int(report[REPORT_USEC])) / 1000.0})
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
	if not _pending_relocations.is_empty():
		_relocate_next(world)
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
	if _population.is_empty() and _rosters.is_empty() and npcs.is_empty() and stage_documents.is_empty() and _home_claims.is_empty():
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
		var homes: Dictionary = (_rosters[roster_id] as Dictionary).get(KEY_HOMES, {})
		if not homes.is_empty():
			rosters[roster_id][KEY_HOMES] = homes.duplicate()
	var document: Dictionary = {"schema_version": SCHEMA_VERSION, KEY_POPULATION: population, KEY_ROSTERS: rosters}
	if not _home_claims.is_empty():
		var claims: Dictionary = {}
		var claimed: PackedStringArray = PackedStringArray(_home_claims.keys())
		claimed.sort()
		for building_id: String in claimed:
			claims[building_id] = _home_claims[building_id]
		document[KEY_HOME_CLAIMS] = claims
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
	var claims: Dictionary[String, String] = _read_home_claims(document.get(KEY_HOME_CLAIMS, {}), errors)
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
	_home_claims = claims
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
	if not _relocation_target(npc).is_empty():
		_pending_relocations[npc.npc_id] = true
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
	_pending_relocations.erase(npc.npc_id)
	if retired:
		# Gone for good: what was claimed for it is free (F-30).
		release_home_claims(npc.npc_id)
	world.cell_index.remove(npc.npc_id)
	npc_left.emit(npc.npc_id, retired)


## True when one of the NPC's components keeps it from being simulated.
func _is_blocked(npc: NpcState) -> bool:
	for component_id: String in npc.component_ids():
		if npc.component(component_id).blocks_simulation():
			return true
	return false


## The NPC is simulated from now on (never one a component blocks, F-25).
func _wake(world: ServerWorld, npc: NpcState) -> void:
	if _awake.has(npc.npc_id) or _is_blocked(npc):
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


## F-30: {building_id: npc_id}; absent in a save from before NPCs moved.
func _read_home_claims(raw: Variant, errors: PackedStringArray) -> Dictionary[String, String]:
	var claims: Dictionary[String, String] = {}
	if typeof(raw) != TYPE_DICTIONARY or (raw as Dictionary).size() > MAX_HOME_CLAIMS:
		errors.append("npc: home_claims must be an object")
		return claims
	for building_id: Variant in (raw as Dictionary):
		var npc_id: Variant = (raw as Dictionary)[building_id]
		if typeof(building_id) != TYPE_STRING or not ItemInstance.is_valid_definition_id(str(building_id)) or typeof(npc_id) != TYPE_STRING or not NpcState.is_valid_npc_id(str(npc_id)):
			errors.append("npc: invalid home claim %s" % str(building_id))
			continue
		claims[str(building_id)] = str(npc_id)
	return claims


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
		# F-28: absent in a save from before lone homes.
		var saved_homes: Variant = (entry as Dictionary).get(KEY_HOMES, {})
		if typeof(saved_homes) != TYPE_DICTIONARY:
			errors.append("npc: invalid homes in the record of roster %s" % str(roster_id))
			continue
		var homes: Dictionary = {}
		for definition_id: Variant in (saved_homes as Dictionary):
			var building_id: Variant = (saved_homes as Dictionary)[definition_id]
			if typeof(definition_id) != TYPE_STRING or typeof(building_id) != TYPE_STRING or not ItemInstance.is_valid_definition_id(str(building_id)):
				errors.append("npc: invalid home in the record of roster %s" % str(roster_id))
				continue
			homes[str(definition_id)] = str(building_id)
		if not homes.is_empty():
			rosters[str(roster_id)][KEY_HOMES] = homes
	return rosters


## Places one NPC of the roster on its home spot: brings the cell of the
## spot into memory, spawns the NPC and records its id. With a generated
## home (F-28, the record's `homes`): the cell is built completely first,
## and the NPC is given its home and the home its stock.
func _place_roster_npc(world: ServerWorld, cells: WorldCellService, definition_id: String, record: Dictionary, loaded_here: Array[String], report: Dictionary) -> Error:
	var placed: Dictionary = record[KEY_NPCS]
	var definition: NpcDefinition = _definitions.get_definition(definition_id)
	var layout: NpcHomeLayout = _homes.layout_of(str((record.get(KEY_HOMES, {}) as Dictionary).get(definition_id, ""))) if _homes != null and definition != null else null
	var home: Variant = null
	if layout != null:
		home = _grid.tile_center(layout.home_tile())
	elif definition != null:
		home = NpcRoster.spot_position(_map_content, _grid, definition.home_building_id, definition.home_tile_offset)
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
	if layout != null:
		_build_home_cell(world, cell_id)
	var spawned: ActionResult = spawn_npc(world, definition_id, home as Vector3)
	if not spawned.ok:
		GameLogger.error("npc", "an NPC of the roster was refused", {"world_id": world.world_id, "definition_id": definition_id, "reason": spawned.reason, "operation": "seed_roster"})
		return ERR_INVALID_DATA
	placed[definition_id] = str(spawned.event[KEY_NPC_ID])
	report[REPORT_NPCS] = int(report[REPORT_NPCS]) + 1
	if layout != null:
		_move_in(world, _npcs[str(spawned.event[KEY_NPC_ID])], layout)
		report[REPORT_GENERATED_HOMES] = int(report[REPORT_GENERATED_HOMES]) + 1
	return OK


# ------------------------------------------------------------ homes (F-28)

## Gives every definition of the roster that has none a generated home in
## the record (`homes`), when this world gives lone homes. A definition
## whose NPC was placed already gets one only with
## NpcHomeSettings.relocate_existing. Returns how many were chosen.
func _choose_homes(world: ServerWorld, record: Dictionary, report: Dictionary) -> int:
	if _homes == null or not _homes.gives_lone_homes():
		return 0
	var started_usec: int = Time.get_ticks_usec()
	var homes: Dictionary = record.get(KEY_HOMES, {})
	var placed: Dictionary = record[KEY_NPCS]
	var taken: Dictionary = {}
	for definition_id: Variant in homes:
		taken[str(homes[definition_id])] = true
	var picker: NpcHomePicker = NpcHomePicker.new(_homes.generator(), _homes.settings)
	var chosen: int = 0
	var planned_cells: int = 0
	for definition_id: String in _roster.npc_definition_ids:
		if homes.has(definition_id) or (placed.has(definition_id) and not _homes.settings.relocate_existing):
			continue
		var building: ProceduralBuilding = picker.pick(definition_id, taken)
		planned_cells += picker.last_planned_cell_count
		if building == null:
			GameLogger.warning("npc", "no generated building is free for an NPC of the roster; it lives where its definition says", {"world_id": world.world_id, "definition_id": definition_id, "operation": "choose_homes"})
			continue
		homes[definition_id] = building.building_id()
		taken[building.building_id()] = true
		chosen += 1
	if chosen > 0:
		record[KEY_HOMES] = homes
		report[REPORT_HOMES_CHOSEN] = int(report[REPORT_HOMES_CHOSEN]) + chosen
		report[REPORT_CHOOSING_USEC] = int(report[REPORT_CHOOSING_USEC]) + Time.get_ticks_usec() - started_usec
		GameLogger.info("npc", "generated homes chosen for the roster", {"world_id": world.world_id, "roster_id": _roster.roster_id, "homes": chosen, "cells_planned": planned_cells, "msec": float(Time.get_ticks_usec() - started_usec) / 1000.0})
	return chosen


## Builds everything the generated map puts into a cell that is in memory
## now, so an NPC is never put into a house whose walls come later.
func _build_home_cell(world: ServerWorld, cell_id: String) -> void:
	var map: ProceduralMapService = world.get_system(ProceduralMapService.SYSTEM_ID) as ProceduralMapService
	if map != null:
		map.finish_cell_now(world, cell_id)


## The NPC (in memory, standing in the building) lives there from now on:
## its home component names the building, the containers of the building are
## searched (their loot is rolled), and the first of them that has room gets
## the home stock. Called once per NPC and home.
func _move_in(world: ServerWorld, npc: NpcState, layout: NpcHomeLayout) -> void:
	var home: NpcHome = NpcHome.of(npc)
	if home != null:
		home.set_generated(layout.building_id, layout.home_tile())
	mark_npc_dirty(npc.npc_id)
	var containers: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
	if containers == null:
		return
	var left: PackedInt32Array = _homes.stock_stacks()
	for index: int in range(layout.food_offsets.size()):
		var container_id: String = containers.container_id_of_source(MapBuildingPlan.container_source_key(ProceduralMapGenerator.MAP_ID, layout.building_id, index))
		if container_id.is_empty() or not containers.search_now(world, container_id):
			continue
		var container: ContainerInstance = containers.get_container(container_id)
		while not left.is_empty() and not world.inventory.spawn_detached_item(container.inventory_id, _homes.settings.stock_item_id, left[0]).is_empty():
			left.remove_at(0)
			mark_cell_save_dirty(container.cell_id)
	if not left.is_empty():
		GameLogger.warning("npc", "the home stock did not fit the containers of a home", {"world_id": world.world_id, "entity_id": npc.npc_id, "building_id": layout.building_id, "stacks_left": left.size(), "operation": "move_in"})


## The generated building an NPC in memory must still be moved to ("" =
## none): an NPC of the roster that lives where its definition says, in a
## world that has chosen a generated home for its definition.
func _relocation_target(npc: NpcState) -> String:
	if _homes == null or _roster == null or not _homes.settings.relocate_existing:
		return ""
	var record: Dictionary = _rosters.get(_roster.roster_id, {})
	var target: String = str((record.get(KEY_HOMES, {}) as Dictionary).get(npc.definition_id, ""))
	if target.is_empty() or str((record.get(KEY_NPCS, {}) as Dictionary).get(npc.definition_id, "")) != npc.npc_id:
		return ""
	var home: NpcHome = NpcHome.of(npc)
	return target if home != null and not home.is_generated() else ""


## Moves one waiting NPC (the smallest id) to its generated home: the cell
## of the home is brought into memory and built, the NPC is put on its home
## tile and moves in. What it was doing is not cancelled: a walk fails at
## its next step (the way is gone) and the decision layer chooses again.
## A dead NPC stays where it lies. An NPC that cannot be moved now (its
## home's cell cannot be loaded) is tried again when it comes into memory
## the next time.
func _relocate_next(world: ServerWorld) -> void:
	var ids: PackedStringArray = PackedStringArray(_pending_relocations.keys())
	ids.sort()
	var npc_id: String = ids[0]
	_pending_relocations.erase(npc_id)
	var npc: NpcState = _npcs.get(npc_id, null)
	var target: String = _relocation_target(npc) if npc != null else ""
	if target.is_empty() or _is_blocked(npc):
		return
	var started_usec: int = Time.get_ticks_usec()
	var layout: NpcHomeLayout = _homes.layout_of(target)
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	if layout == null:
		GameLogger.error("npc", "the generated home of an NPC does not exist on this map", {"world_id": world.world_id, "entity_id": npc_id, "building_id": target, "operation": "relocate"})
		return
	var position: Vector3 = _grid.tile_center(layout.home_tile())
	var cell_id: String = world.cell_id_at(position)
	if not world.is_cell_loaded(cell_id) and (cells == null or not cells.load_cell_now(world, cell_id)):
		GameLogger.error("npc", "the cell of a generated home could not be loaded", {"world_id": world.world_id, "entity_id": npc_id, "cell_id": cell_id, "operation": "relocate"})
		return
	_build_home_cell(world, cell_id)
	var from_cell_id: String = world.cell_index.cell_of(npc_id)
	if not set_npc_transform(world, npc_id, position, npc.yaw):
		GameLogger.error("npc", "an NPC could not be put into its generated home", {"world_id": world.world_id, "entity_id": npc_id, "cell_id": cell_id, "operation": "relocate"})
		return
	_move_in(world, npc, layout)
	relocated_count += 1
	max_relocation_usec = maxi(max_relocation_usec, Time.get_ticks_usec() - started_usec)
	GameLogger.info("npc", "an NPC of the hand-made map moved to its generated home", {"world_id": world.world_id, "entity_id": npc_id, "building_id": target, "from_cell_id": from_cell_id, "cell_id": cell_id})


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
