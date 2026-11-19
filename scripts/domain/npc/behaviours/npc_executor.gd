class_name NpcExecutor
extends NpcStage
## HOW an NPC carries out what was decided (P4-5a, docs/09 §17.7, docs/13
## §16.3 D7 / D8 / D11 / D12, §16.4). One NpcStage, stage id "executor",
## added AFTER the scheduler: an action that a decision begins is planned
## and started in the same tick. WHAT an NPC does and when it changes its
## mind is the decision layer's business (P4-4); the things it does at a
## place (eat, drink, rest, work) are P4-5b.
##
## Actions (one per NPC at a time; begin_* refuses a busy NPC, cancel()
## ends what it does):
##   begin_move(npc_id, target, run = false, target_entity_id = "")
##       walk to a position. `target_entity_id` (optional): the thing the
##       NPC walks to; when it leaves the world's registry on the way the
##       action fails with target_gone.
##   begin_use_spot(npc_id, spot_id, duration_sec, run = false)
##       walk to a spot of the NpcSpotSet and stay there for
##       `duration_sec` of action time (HOLD = until cancelled). An
##       exclusive spot is reserved from the moment the action begins.
## Both return an ActionResult. A refusal (the reasons REASON_*) is an
## answer: nothing was begun and nobody is interrupted.
##
## What the decision layer hears (NpcScheduler.request_interrupt; the names
## are snake_case because the scheduler takes nothing else, so the failure
## code is appended with an underscore, see failure_code_of):
##   "action_arrived"        a use_spot action reached its spot
##   "action_done"           the action is complete
##   "action_failed_<code>"  path_not_found (no path within the search
##                           bounds), path_blocked (the walk was blocked
##                           more often than max_replans_per_action),
##                           target_gone (the target entity or the spot no
##                           longer exists), spot_reserved (the spot was
##                           taken while this NPC slept)
##   "reservation_lost"      a spot reserved by hand was taken while this
##                           NPC slept (no action failed)
## A cancelled action tells nobody. last_outcome() keeps the last result.
##
## Walking (D12): NPCs are points and pass through each other. Every tick a
## walking NPC takes ONE step towards its next waypoint, asks
## ServerWorld.resolve_movement("npc", ...) for it once and moves through
## NpcService.set_npc_transform. A step never goes past a waypoint. A step
## that does not end where it should (a new wall, a cell that is not in
## memory) makes the NPC stand, wait min_replan_interval_sec and search
## again; after max_replans_per_action more searches the action fails.
##
## Doors (D8): the NPC's searches use the option "doors are passable"
## (GridPathSearch), so their result does not depend on which doors are
## open. When the edge between the NPC's tile and its next waypoint's tile
## is a closed door, it opens it (BuildingService.set_door_open: a server
## rule, public like a player's door), stands door_pause_sec, walks
## through, and closes it when it reaches the waypoint behind it. It also
## closes it when the action ends or plans again. It only closes doors it
## opened itself; a door that cannot be closed (somebody stands in it) is
## left open and counted in doors_left_open_count.
##
## Planning budget (docs/13 §16.4): searches wait in a FIFO. Every tick the
## first max_plans_per_tick of them get a turn of at most
## max_search_nodes_per_tick nodes, until max_planning_nodes_per_tick nodes
## are used; a search that is not finished goes to the back. The searches
## are NavigationService.begin_search (its radius and node bound apply).
##
## Spots and reservations (D7): one NPC per exclusive spot, one spot per
## NPC. reserve() / release() by hand, or begin_use_spot, which gives the
## spot back when the action ends (done, failed or cancelled) unless it was
## reserved by hand before. Only NPCs that are awake hold a spot: one that
## falls asleep gives it up and takes it back when it wakes, unless
## somebody took it meanwhile (then: spot_reserved / reservation_lost). An
## NPC that is removed holds nothing.
##
## Save (D11): everything an NPC is in the middle of is in its component
## (NpcExecutorState): the action, the waypoints still ahead, the timers,
## the doors it opened, its reservation, its place in the queue and how
## many nodes its running search has expanded. A running search itself is
## not saved; after a restore it is run again up to that many nodes, which
## gives the same search, so a restored run walks in the same ticks as one
## that went on. This stage saves one number: the next queue place.
## NPCs are handled in the order of their ids, never in the order they
## happened to come into memory.
##
## Cost: a tick in which no NPC acts looks at nothing.

const STAGE_ID: String = "executor"
## A decider that has this method is given the executor by ServerComposition.
const DECIDER_HOOK: StringName = &"on_executor_attached"
const SCHEMA_VERSION: int = 1
const KEY_SCHEMA_VERSION: String = "schema_version"
const KEY_NEXT_PLAN_SEQ: String = "next_plan_seq"

const INTERRUPT_DONE: String = "action_done"
const INTERRUPT_ARRIVED: String = "action_arrived"
const INTERRUPT_FAILED_PREFIX: String = "action_failed_"
const INTERRUPT_RESERVATION_LOST: String = "reservation_lost"
## Failure codes (after INTERRUPT_FAILED_PREFIX, and in last_outcome()).
const FAIL_PATH_NOT_FOUND: String = "path_not_found"
const FAIL_PATH_BLOCKED: String = "path_blocked"
const FAIL_TARGET_GONE: String = "target_gone"
const FAIL_SPOT_RESERVED: String = "spot_reserved"
## Reasons a request is refused with.
const REASON_UNAVAILABLE: String = "executor_unavailable"
const REASON_UNKNOWN_NPC: String = "unknown_npc"
const REASON_NOT_AWAKE: String = "npc_not_awake"
const REASON_BUSY: String = "npc_busy"
const REASON_BAD_TARGET: String = "bad_target"
const REASON_BAD_DURATION: String = "bad_duration"
const REASON_UNKNOWN_SPOT: String = "unknown_spot"
const REASON_SPOT_RESERVED: String = "spot_reserved"
## duration_sec of a use that lasts until it is cancelled.
const HOLD: float = -1.0
## Longest duration of a use (about 31 years).
const MAX_DURATION_SEC: float = 1.0e9
## Keys of action_info() and last_outcome().
const INFO_PHASE: String = "phase"
const INFO_KIND: String = "kind"
const INFO_TARGET: String = "target"
const INFO_SPOT: String = "spot_id"
const INFO_WAYPOINTS: String = "waypoints"
const INFO_RESERVED_SPOT: String = "reserved_spot_id"
const OUTCOME_RESULT: String = "result"
const OUTCOME_CODE: String = "code"

## Diagnostics (tests / profiling / the debug overlay of P4-8). "last": of
## the latest tick. Plan nodes and turns: what the FIFO used. Moves: NPCs
## that took a step. `total_search_count`: searches begun (not the ones run
## again after a restore). `total_replan_count`: searches asked for because
## a walk was blocked. `dropped_interrupt_count`: results the scheduler did
## not take (the NPC already waits for too many interrupts).
var last_plan_node_count: int = 0
var last_plan_turn_count: int = 0
var last_move_count: int = 0
var peak_plan_nodes_per_tick: int = 0
var peak_search_nodes_per_tick: int = 0
var peak_plan_turns_per_tick: int = 0
var total_search_count: int = 0
var total_replan_count: int = 0
var doors_opened_count: int = 0
var doors_closed_count: int = 0
var doors_left_open_count: int = 0
var dropped_interrupt_count: int = 0
var last_step_usec: int = 0

var _settings: NpcExecutorSettings
var _structures: StructureCatalog = null
var _grid: StructureGrid = null
var _spots: NpcSpotSet = null
## spot_id -> where an NPC stands to use it (only spots of this world).
var _spot_positions: Dictionary[String, Vector3] = {}
var _reservations: NpcReservations = NpcReservations.new()
var _scheduler_ref: WeakRef = null
var _npcs_ref: WeakRef = null
var _world_ref: WeakRef = null
## Awake NPCs: npc_id -> its state.
var _awake: Dictionary[String, NpcExecutorState] = {}
## Awake NPCs that are in the middle of an action.
var _active: Dictionary[String, NpcExecutorState] = {}
## The ids of _active in the order they are handled (rebuilt when stale).
var _order: PackedStringArray = []
var _order_stale: bool = false
## NPCs that woke and were not looked at yet (see _settle).
var _woken: PackedStringArray = []
## The planning FIFO: npc ids, by NpcExecutorState.plan_seq.
var _queue: Array[String] = []
var _searches: Dictionary[String, GridPathSearch] = {}
var _next_plan_seq: int = 0


func _init(settings: NpcExecutorSettings = null) -> void:
	_settings = settings if settings != null else NpcExecutorSettings.new()


## Gives `npcs` the executor component and stage (the one line of
## ServerComposition, after NpcScheduler.install). `scheduler`: who is told
## about results (null = nobody). `structures`: to tell a door from a wall.
## `spots` with `map_content`: the NPC spots of this world (spots that name
## a building need the map content they belong to). Returns the stage, or
## null when a registration fails.
static func install(npcs: NpcService, settings: NpcExecutorSettings, scheduler: NpcScheduler, structures: StructureCatalog, grid: StructureGrid, spots: NpcSpotSet = null, map_content: MapContentDefinition = null) -> NpcExecutor:
	if npcs == null or settings == null or grid == null:
		return null
	var executor: NpcExecutor = NpcExecutor.new(settings)
	executor._structures = structures
	executor._grid = grid
	executor._spots = spots
	if spots != null:
		executor._spot_positions = spots.positions(map_content, grid)
	executor._scheduler_ref = weakref(scheduler) if scheduler != null else null
	if npcs.register_component(NpcExecutorState.COMPONENT_ID, NpcExecutorState.make) != OK or npcs.add_stage(executor) != OK:
		return null
	executor._npcs_ref = weakref(npcs)
	return executor


func stage_id() -> String:
	return STAGE_ID


## The failure code of an "action_failed_<code>" interrupt reason ("" for
## any other reason).
static func failure_code_of(reason: String) -> String:
	return reason.substr(INTERRUPT_FAILED_PREFIX.length()) if reason.begins_with(INTERRUPT_FAILED_PREFIX) else ""


# ------------------------------------------------------------ actions

## Starts walking `npc_id` to `target` (see the header). Refused with
## unknown_npc, npc_not_awake, npc_busy, bad_target (not finite, outside
## the play area, or `target_entity_id` is not in the world).
func begin_move(npc_id: String, target: Vector3, run: bool = false, target_entity_id: String = "") -> ActionResult:
	var refusal: String = _begin_refusal(npc_id)
	if not refusal.is_empty():
		return ActionResult.failure(refusal)
	var world: ServerWorld = _world()
	if not target.is_finite() or world.clamp_to_world(target) != target:
		return ActionResult.failure(REASON_BAD_TARGET)
	if not target_entity_id.is_empty() and (target_entity_id.length() > NpcComponent.ID_MAX_LENGTH or not world.registry.has(target_entity_id)):
		return ActionResult.failure(REASON_BAD_TARGET)
	var state: NpcExecutorState = _awake[npc_id]
	state.clear_action()
	state.kind = NpcExecutorState.KIND_MOVE
	state.target = target
	state.run = run
	state.target_entity_id = target_entity_id
	_start_planning(npc_id, state)
	return ActionResult.success()


## Starts walking `npc_id` to the spot and using it for `duration_sec`
## (>= 0, or HOLD). Refused with unknown_npc, npc_not_awake, npc_busy,
## unknown_spot (also a spot that has no place in this world),
## bad_duration, spot_reserved (another NPC holds the spot).
func begin_use_spot(npc_id: String, spot_id: String, duration_sec: float, run: bool = false) -> ActionResult:
	var refusal: String = _begin_refusal(npc_id)
	if not refusal.is_empty():
		return ActionResult.failure(refusal)
	if not _spot_positions.has(spot_id):
		return ActionResult.failure(REASON_UNKNOWN_SPOT)
	if not is_finite(duration_sec) or duration_sec > MAX_DURATION_SEC or (duration_sec < 0.0 and duration_sec != HOLD):
		return ActionResult.failure(REASON_BAD_DURATION)
	var state: NpcExecutorState = _awake[npc_id]
	if _spots.get_spot(spot_id).exclusive and state.reserved_spot_id != spot_id:
		if not _reservations.claim(spot_id, npc_id):
			return ActionResult.failure(REASON_SPOT_RESERVED)
		state.reserved_spot_id = spot_id
		state.reservation_auto = true
	state.clear_action()
	state.kind = NpcExecutorState.KIND_USE_SPOT
	state.target = _spot_positions[spot_id]
	state.run = run
	state.spot_id = spot_id
	state.use_usec = NpcExecutorState.FOREVER if duration_sec == HOLD else NpcExecutorSettings.to_usec(duration_sec)
	_start_planning(npc_id, state)
	return ActionResult.success()


## Ends what an awake NPC is doing, where it stands: the doors it opened
## are closed, a spot the action reserved is given back, nobody is told.
## False when it was doing nothing (or is not awake).
func cancel(npc_id: String) -> bool:
	_settle()
	var state: NpcExecutorState = _active.get(npc_id, null)
	if state == null:
		return false
	_finish(npc_id, state, NpcExecutorState.RESULT_CANCELLED, "")
	return true


## True while an NPC that is in memory is in the middle of an action (also
## a sleeping one: its action is frozen as it is).
func is_busy(npc_id: String) -> bool:
	_settle()
	var state: NpcExecutorState = _state_of(npc_id)
	return state != null and state.is_busy()


## idle, planning, moving or using (NpcExecutorState.PHASE_*); idle for an
## NPC that is not in memory.
func phase_of(npc_id: String) -> String:
	_settle()
	var state: NpcExecutorState = _state_of(npc_id)
	return state.phase if state != null else NpcExecutorState.PHASE_IDLE


## What an NPC that is in memory is doing ({} = not in memory): phase,
## kind, target, spot_id, the waypoints still ahead (Array[Vector3], for
## the debug overlay's path line) and its reserved spot.
func action_info(npc_id: String) -> Dictionary:
	_settle()
	var state: NpcExecutorState = _state_of(npc_id)
	if state == null:
		return {}
	return {
		INFO_PHASE: state.phase,
		INFO_KIND: state.kind,
		INFO_TARGET: state.target,
		INFO_SPOT: state.spot_id,
		INFO_WAYPOINTS: state.remaining_waypoints(),
		INFO_RESERVED_SPOT: state.reserved_spot_id,
	}


## How the last action of an NPC that is in memory ended ({} = not in
## memory): {result: "" | "done" | "failed" | "cancelled", code: the
## failure code}. Saved with the NPC.
func last_outcome(npc_id: String) -> Dictionary:
	_settle()
	var state: NpcExecutorState = _state_of(npc_id)
	if state == null:
		return {}
	return {OUTCOME_RESULT: state.last_result, OUTCOME_CODE: state.last_code}


# ------------------------------------------------------------ spots

## Reserves an exclusive spot for an awake NPC by hand: it stays reserved
## until release(), whatever the NPC does. A spot the NPC held before is
## given back. Refused with unknown_npc, npc_not_awake, unknown_spot (also
## a spot that is not exclusive), spot_reserved.
func reserve(npc_id: String, spot_id: String) -> ActionResult:
	_settle()
	var state: NpcExecutorState = _awake.get(npc_id, null)
	if state == null:
		return ActionResult.failure(REASON_NOT_AWAKE if _state_of(npc_id) != null else REASON_UNKNOWN_NPC)
	if not _spot_positions.has(spot_id) or not _spots.get_spot(spot_id).exclusive:
		return ActionResult.failure(REASON_UNKNOWN_SPOT)
	if not _reservations.claim(spot_id, npc_id):
		return ActionResult.failure(REASON_SPOT_RESERVED)
	state.reserved_spot_id = spot_id
	state.reservation_auto = false
	_mark_dirty(npc_id)
	return ActionResult.success()


## Gives back the spot an awake NPC holds. False when it held none.
func release(npc_id: String) -> bool:
	_settle()
	var state: NpcExecutorState = _awake.get(npc_id, null)
	if state == null or state.reserved_spot_id.is_empty():
		return false
	_drop_reservation(npc_id, state)
	return true


## The NPC that holds a spot ("" = nobody).
func holder_of(spot_id: String) -> String:
	_settle()
	return _reservations.holder_of(spot_id)


## The spot an NPC that is in memory holds, or wants back when it wakes.
func reserved_spot_of(npc_id: String) -> String:
	_settle()
	var state: NpcExecutorState = _state_of(npc_id)
	return state.reserved_spot_id if state != null else ""


## True when the spot exists and nobody, or `for_npc_id`, holds it.
func is_spot_free(spot_id: String, for_npc_id: String = "") -> bool:
	_settle()
	return _spot_positions.has(spot_id) and _reservations.is_free(spot_id, for_npc_id)


## The spots of this world nobody holds, sorted by id; `kind` and
## `building_id` narrow the list ("" = any).
func free_spot_ids(kind: String = "", building_id: String = "") -> PackedStringArray:
	_settle()
	var ids: PackedStringArray = []
	if _spots == null:
		return ids
	for spot_id: String in _spots.spot_ids(kind, building_id):
		if _spot_positions.has(spot_id) and _reservations.is_free(spot_id):
			ids.append(spot_id)
	return ids


func has_spot(spot_id: String) -> bool:
	return _spot_positions.has(spot_id)


## Where an NPC stands to use a spot (Vector3), or null.
func spot_position(spot_id: String) -> Variant:
	return _spot_positions[spot_id] if _spot_positions.has(spot_id) else null


## The spot's definition (kind, building, exclusive), or null.
func spot_definition(spot_id: String) -> NpcSpotDefinition:
	return _spots.get_spot(spot_id) if _spot_positions.has(spot_id) else null


## The planning queue, who is next first.
func queued_npc_ids() -> PackedStringArray:
	_settle()
	return PackedStringArray(_queue)


func diagnostics() -> Dictionary:
	return {
		"plan_nodes": last_plan_node_count,
		"plan_turns": last_plan_turn_count,
		"moves": last_move_count,
		"queued": _queue.size(),
		"active": _active.size(),
		"reserved": _reservations.count(),
		"step_usec": last_step_usec,
		"peak_plan_nodes_per_tick": peak_plan_nodes_per_tick,
		"total_searches": total_search_count,
		"total_replans": total_replan_count,
		"doors_opened": doors_opened_count,
		"doors_closed": doors_closed_count,
		"doors_left_open": doors_left_open_count,
	}


# ------------------------------------------------------------ NpcStage

func on_npc_woke(world: ServerWorld, npc: NpcState) -> void:
	var state: NpcExecutorState = npc.component(NpcExecutorState.COMPONENT_ID) as NpcExecutorState
	if state == null:
		return
	_world_ref = weakref(world)
	_npcs_ref = weakref(world.get_system(NpcService.SYSTEM_ID))
	_awake[npc.npc_id] = state
	# What it holds and where it stands in the queue is settled later, in the
	# order of the ids: NPCs wake in no particular order.
	_woken.append(npc.npc_id)


## The NPC's cell is no longer simulated: its action stays as it is, its
## running search is dropped (it starts again when the NPC wakes), and the
## spot it holds is free for others until then.
func on_npc_slept(_world_now: ServerWorld, npc: NpcState) -> void:
	var npc_id: String = npc.npc_id
	var state: NpcExecutorState = _awake.get(npc_id, null)
	if state == null:
		return
	_awake.erase(npc_id)
	var woken_index: int = _woken.find(npc_id)
	if woken_index >= 0:
		# It woke and slept again before anybody looked: it holds nothing.
		_woken.remove_at(woken_index)
		return
	if _active.erase(npc_id):
		_order_stale = true
	_queue.erase(npc_id)
	if _searches.erase(npc_id) and state.plan_expanded != 0:
		state.plan_expanded = 0
		_mark_dirty(npc_id)
	_reservations.release_of(npc_id)


## An NPC that is removed for good closes the doors it opened.
func on_npc_left(world: ServerWorld, npc: NpcState, retired: bool) -> void:
	var state: NpcExecutorState = npc.component(NpcExecutorState.COMPONENT_ID) as NpcExecutorState
	if retired and state != null:
		_close_doors(world, npc.npc_id, state)


func step(world: ServerWorld, npcs: NpcService, action_delta: float, _world_delta: float) -> void:
	last_plan_node_count = 0
	last_plan_turn_count = 0
	last_move_count = 0
	last_step_usec = 0
	# A paused world (both deltas 0): nothing runs.
	if not is_finite(action_delta) or action_delta <= 0.0:
		return
	_world_ref = weakref(world)
	_npcs_ref = weakref(npcs)
	_settle()
	if _active.is_empty():
		return
	var started_usec: int = Time.get_ticks_usec()
	var delta_usec: int = NpcExecutorSettings.to_usec(action_delta)
	var order: PackedStringArray = _ordered()
	# 1. What ends an action whatever it is doing, and the waits of planners.
	for npc_id: String in order:
		var state: NpcExecutorState = _active.get(npc_id, null)
		if state == null:
			continue
		if not state.target_entity_id.is_empty() and not world.registry.has(state.target_entity_id):
			_finish(npc_id, state, NpcExecutorState.RESULT_FAILED, FAIL_TARGET_GONE)
		elif state.phase == NpcExecutorState.PHASE_PLANNING and state.plan_seq == NpcExecutorState.NOT_QUEUED:
			state.timer_usec = maxi(state.timer_usec - delta_usec, 0)
			if state.timer_usec == 0:
				_enqueue(npc_id, state)
			_mark_dirty(npc_id)
	# 2. The searches, within the budget.
	_drain_plans(world, npcs)
	# 3. One step, or one tick of staying, per NPC.
	for npc_id: String in order:
		var state: NpcExecutorState = _active.get(npc_id, null)
		var npc: NpcState = npcs.get_npc(npc_id)
		if state == null or npc == null:
			continue
		if state.phase == NpcExecutorState.PHASE_MOVING:
			_walk(world, npcs, npc, state, action_delta, delta_usec)
		elif state.phase == NpcExecutorState.PHASE_USING and state.timer_usec != NpcExecutorState.FOREVER:
			state.timer_usec = maxi(state.timer_usec - delta_usec, 0)
			_mark_dirty(npc_id)
			if state.timer_usec == 0:
				_finish(npc_id, state, NpcExecutorState.RESULT_DONE, "")
	peak_plan_nodes_per_tick = maxi(peak_plan_nodes_per_tick, last_plan_node_count)
	peak_plan_turns_per_tick = maxi(peak_plan_turns_per_tick, last_plan_turn_count)
	last_step_usec = Time.get_ticks_usec() - started_usec


func to_world_document() -> Dictionary:
	if _next_plan_seq == 0:
		return {}
	return {KEY_SCHEMA_VERSION: SCHEMA_VERSION, KEY_NEXT_PLAN_SEQ: _next_plan_seq}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get(KEY_SCHEMA_VERSION, null)) or int(document[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("npc executor: unsupported schema_version")
		return errors
	var next_seq: Variant = document.get(KEY_NEXT_PLAN_SEQ, null)
	if not ItemInstance.is_integer_value(next_seq) or float(next_seq) < 0.0 or float(next_seq) > float(NpcExecutorState.MAX_SAFE_INT):
		errors.append("npc executor: next_plan_seq must be a whole number >= 0")
		return errors
	_next_plan_seq = int(next_seq)
	return errors


# ------------------------------------------------------------ internals

func _world() -> ServerWorld:
	return _world_ref.get_ref() as ServerWorld if _world_ref != null else null


func _npcs() -> NpcService:
	return _npcs_ref.get_ref() as NpcService if _npcs_ref != null else null


func _building() -> BuildingService:
	var world: ServerWorld = _world()
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService if world != null else null


## The state of an NPC that is in memory (awake or not), or null.
func _state_of(npc_id: String) -> NpcExecutorState:
	if _awake.has(npc_id):
		return _awake[npc_id]
	var npcs: NpcService = _npcs()
	var npc: NpcState = npcs.get_npc(npc_id) if npcs != null else null
	return npc.component(NpcExecutorState.COMPONENT_ID) as NpcExecutorState if npc != null else null


func _mark_dirty(npc_id: String) -> void:
	var npcs: NpcService = _npcs()
	if npcs != null:
		npcs.mark_npc_dirty(npc_id)


## "" when an action can begin for `npc_id`, otherwise why not.
func _begin_refusal(npc_id: String) -> String:
	_settle()
	if _world() == null or _npcs() == null:
		return REASON_UNAVAILABLE
	var state: NpcExecutorState = _awake.get(npc_id, null)
	if state == null:
		return REASON_NOT_AWAKE if _state_of(npc_id) != null else REASON_UNKNOWN_NPC
	return REASON_BUSY if state.is_busy() else ""


## Looks at the NPCs that woke since the last look, in the order of their
## ids: each takes back the spot it held (unless somebody took it or the
## spot is gone) and its place among the NPCs that act. Called before
## anything else reads or changes the tables, so the order in which NPCs
## happened to wake never matters.
func _settle() -> void:
	if _woken.is_empty():
		return
	var woken: PackedStringArray = _sorted(Array(_woken))
	_woken = PackedStringArray()
	for npc_id: String in woken:
		var state: NpcExecutorState = _awake.get(npc_id, null)
		if state == null:
			continue
		var lost_spot: String = ""
		var lost_code: String = ""
		if not state.reserved_spot_id.is_empty():
			if not _spot_positions.has(state.reserved_spot_id):
				lost_code = FAIL_TARGET_GONE
			elif not _reservations.claim(state.reserved_spot_id, npc_id):
				lost_code = FAIL_SPOT_RESERVED
			if not lost_code.is_empty():
				lost_spot = state.reserved_spot_id
				state.reserved_spot_id = ""
				state.reservation_auto = false
				_mark_dirty(npc_id)
		var action_failed: bool = false
		if state.is_busy():
			_active[npc_id] = state
			_order_stale = true
			if state.kind == NpcExecutorState.KIND_USE_SPOT and not _spot_positions.has(state.spot_id):
				_finish(npc_id, state, NpcExecutorState.RESULT_FAILED, FAIL_TARGET_GONE)
				action_failed = true
			elif not lost_spot.is_empty() and state.spot_id == lost_spot:
				_finish(npc_id, state, NpcExecutorState.RESULT_FAILED, lost_code)
				action_failed = true
			elif state.phase == NpcExecutorState.PHASE_PLANNING and state.plan_seq != NpcExecutorState.NOT_QUEUED:
				_insert_in_queue(npc_id, state.plan_seq)
		if not lost_spot.is_empty() and not action_failed:
			_tell(npc_id, INTERRUPT_RESERVATION_LOST)


## The ids of the NPCs that act, sorted (by length first: npc_10 after
## npc_9, whatever the padding).
func _ordered() -> PackedStringArray:
	if _order_stale:
		_order = _sorted(_active.keys())
		_order_stale = false
	return _order


static func _sorted(ids: Array) -> PackedStringArray:
	ids.sort_custom(func(a: String, b: String) -> bool: return a.length() < b.length() if a.length() != b.length() else a < b)
	return PackedStringArray(ids)


func _start_planning(npc_id: String, state: NpcExecutorState) -> void:
	state.phase = NpcExecutorState.PHASE_PLANNING
	_active[npc_id] = state
	_order_stale = true
	_enqueue(npc_id, state)
	_mark_dirty(npc_id)


## Puts the NPC at the back of the planning queue.
func _enqueue(npc_id: String, state: NpcExecutorState) -> void:
	state.plan_seq = _next_plan_seq
	_next_plan_seq += 1
	_queue.append(npc_id)


## Puts an NPC whose place was saved back where it stood.
func _insert_in_queue(npc_id: String, plan_seq: int) -> void:
	var index: int = _queue.size()
	while index > 0 and _active[_queue[index - 1]].plan_seq > plan_seq:
		index -= 1
	_queue.insert(index, npc_id)


func _drain_plans(world: ServerWorld, npcs: NpcService) -> void:
	if _queue.is_empty():
		return
	var navigation: NavigationService = world.get_system(NavigationService.SYSTEM_ID) as NavigationService
	var remaining: int = _settings.max_planning_nodes_per_tick
	# Only the searches that waited at the start of the tick get a turn: one
	# that goes to the back cannot have a second turn in the same tick.
	var turns: int = mini(_queue.size(), _settings.max_plans_per_tick)
	while last_plan_turn_count < turns and remaining > 0 and not _queue.is_empty():
		var npc_id: String = _queue.pop_front()
		last_plan_turn_count += 1
		var state: NpcExecutorState = _active.get(npc_id, null)
		var npc: NpcState = npcs.get_npc(npc_id)
		if state == null or npc == null:
			continue
		var search: GridPathSearch = _searches.get(npc_id, null)
		if search == null:
			search = navigation.begin_search(npc.position, state.target, _settings.max_search_nodes) if navigation != null else null
			if search == null:
				_finish(npc_id, state, NpcExecutorState.RESULT_FAILED, FAIL_PATH_NOT_FOUND)
				continue
			search.set_door_query(Callable(self, "_is_door_edge"))
			if state.plan_expanded > 0:
				# A search that was running when the world was saved: run it
				# again up to where it was (not counted: it is the same work).
				search.advance(state.plan_expanded)
				state.plan_expanded = search.result.expanded_nodes
			else:
				total_search_count += 1
			_searches[npc_id] = search
		if not search.is_finished():
			search.advance(mini(remaining, _settings.max_search_nodes_per_tick))
			var expanded: int = search.last_advance_expanded_nodes
			remaining -= expanded
			last_plan_node_count += expanded
			peak_search_nodes_per_tick = maxi(peak_search_nodes_per_tick, expanded)
			state.plan_expanded += expanded
		_mark_dirty(npc_id)
		if not search.is_finished():
			_enqueue(npc_id, state)
			continue
		_searches.erase(npc_id)
		state.plan_seq = NpcExecutorState.NOT_QUEUED
		state.plan_expanded = 0
		if not search.result.found:
			_finish(npc_id, state, NpcExecutorState.RESULT_FAILED, FAIL_PATH_NOT_FOUND)
			continue
		state.waypoints = search.result.waypoints
		state.waypoint_index = 0
		state.timer_usec = 0
		state.phase = NpcExecutorState.PHASE_MOVING


## The door query of the NPCs' searches: a standing door is an edge a
## walker opens.
func _is_door_edge(slot: Vector3i) -> bool:
	return not _door_id_at(_building(), slot).is_empty()


## Id of the standing door in an edge slot ("" = none).
func _door_id_at(building: BuildingService, slot: Vector3i) -> String:
	if building == null or _structures == null:
		return ""
	var structure_id: String = building.structure_id_at(slot)
	if structure_id.is_empty():
		return ""
	var structure: StructureInstance = building.get_structure(structure_id)
	var definition: StructureDefinition = _structures.get_definition(structure.definition_id) if structure != null else null
	return structure_id if definition != null and definition.is_door and structure.is_standing() else ""


## One step of a walking NPC (see the header).
func _walk(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcExecutorState, action_delta: float, delta_usec: int) -> void:
	var npc_id: String = npc.npc_id
	if state.timer_usec > 0:
		# In front of a door it just opened.
		state.timer_usec = maxi(state.timer_usec - delta_usec, 0)
		_mark_dirty(npc_id)
		if state.timer_usec > 0:
			return
	if state.waypoint_index >= state.waypoints.size():
		_arrive(world, npc_id, state)
		return
	var from: Vector3 = npc.position
	var waypoint: Vector3 = state.waypoints[state.waypoint_index]
	var offset: Vector3 = Vector3(waypoint.x - from.x, 0.0, waypoint.z - from.z)
	var distance: float = offset.length()
	if distance > 0.0:
		# The edge to the next tile: a closed door is opened, a wall is not
		# walked into.
		var here: Vector2i = _grid.tile_of(from)
		var hop: Vector2i = _grid.tile_of(waypoint) - here
		if absi(hop.x) + absi(hop.y) == 1:
			var slot: Vector3i = Vector3i(here.x + maxi(hop.x, 0), here.y, StructureGrid.Layer.EDGE_LOW_X) if hop.x != 0 else Vector3i(here.x, here.y + maxi(hop.y, 0), StructureGrid.Layer.EDGE_LOW_Z)
			var building: BuildingService = _building()
			if building != null and building.is_edge_blocked(slot):
				var door_id: String = _door_id_at(building, slot)
				if door_id.is_empty() or state.opened_doors.size() >= NpcExecutorState.MAX_OPENED_DOORS or not building.set_door_open(world, door_id, true).ok:
					_blocked(world, npc_id, state)
					return
				doors_opened_count += 1
				if not state.opened_doors.has(door_id):
					state.opened_doors.append(door_id)
				state.timer_usec = NpcExecutorSettings.to_usec(_settings.door_pause_sec)
				_mark_dirty(npc_id)
				if state.timer_usec > 0:
					return
		var reach: float = (_settings.run_speed_mps if state.run else _settings.walk_speed_mps) * action_delta
		var arrives: bool = distance <= reach
		var wanted: Vector3 = Vector3(waypoint.x, from.y, waypoint.z) if arrives else from + offset * (reach / distance)
		var resolved: Vector3 = world.resolve_movement(NpcService.ENTITY_KIND, from, wanted)
		var yaw: float = atan2(-offset.x, -offset.z)
		last_move_count += 1
		if resolved != wanted or not npcs.set_npc_transform(world, npc_id, wanted, yaw):
			if resolved != wanted and resolved != from:
				npcs.set_npc_transform(world, npc_id, resolved, yaw)
			# (A step may also end in a cell that is not simulated: asleep.)
			if _active.has(npc_id):
				_blocked(world, npc_id, state)
			return
		if not arrives:
			return
	# At the waypoint: the door behind it is closed.
	state.waypoint_index += 1
	_mark_dirty(npc_id)
	_close_doors(world, npc_id, state)
	if state.waypoint_index >= state.waypoints.size() and _active.has(npc_id):
		_arrive(world, npc_id, state)


## The walk is over: the NPC stands on its target.
func _arrive(world: ServerWorld, npc_id: String, state: NpcExecutorState) -> void:
	var npcs: NpcService = _npcs()
	var npc: NpcState = npcs.get_npc(npc_id) if npcs != null else null
	if npc != null and npc.position != state.target:
		# Only the height can differ: every step is flat.
		npcs.set_npc_transform(world, npc_id, state.target, npc.yaw)
	if state.kind != NpcExecutorState.KIND_USE_SPOT:
		_finish(npc_id, state, NpcExecutorState.RESULT_DONE, "")
		return
	state.waypoints = []
	state.waypoint_index = 0
	state.phase = NpcExecutorState.PHASE_USING
	state.timer_usec = state.use_usec
	_mark_dirty(npc_id)
	_tell(npc_id, INTERRUPT_ARRIVED)
	if state.use_usec == 0:
		_finish(npc_id, state, NpcExecutorState.RESULT_DONE, "")


## The walk did not get where it should: wait, then search again, or fail.
func _blocked(world: ServerWorld, npc_id: String, state: NpcExecutorState) -> void:
	if state.replans >= _settings.max_replans_per_action:
		_finish(npc_id, state, NpcExecutorState.RESULT_FAILED, FAIL_PATH_BLOCKED)
		return
	_close_doors(world, npc_id, state)
	state.replans += 1
	total_replan_count += 1
	state.waypoints = []
	state.waypoint_index = 0
	state.phase = NpcExecutorState.PHASE_PLANNING
	state.plan_seq = NpcExecutorState.NOT_QUEUED
	state.plan_expanded = 0
	state.timer_usec = NpcExecutorSettings.to_usec(_settings.min_replan_interval_sec)
	if state.timer_usec == 0:
		_enqueue(npc_id, state)
	_mark_dirty(npc_id)


## Closes the doors the NPC opened (see the header).
func _close_doors(world: ServerWorld, npc_id: String, state: NpcExecutorState) -> void:
	if state.opened_doors.is_empty():
		return
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService if world != null else null
	for door_id: String in state.opened_doors:
		var closed: ActionResult = building.set_door_open(world, door_id, false) if building != null else null
		if closed != null and closed.ok:
			doors_closed_count += 1
		elif closed != null and closed.reason == BuildingService.REASON_BLOCKED_BY_ENTITY:
			doors_left_open_count += 1
			GameLogger.info("npc", "an NPC could not close the door it opened: somebody stands in it", {"entity_id": npc_id, "structure_id": door_id, "operation": "close_door"})
	state.opened_doors = PackedStringArray()
	_mark_dirty(npc_id)


## Ends the action of an awake NPC: see cancel() for what is cleaned up.
## `result` done or failed tells the decision layer.
func _finish(npc_id: String, state: NpcExecutorState, result: String, code: String) -> void:
	_close_doors(_world(), npc_id, state)
	if _active.erase(npc_id):
		_order_stale = true
	_queue.erase(npc_id)
	_searches.erase(npc_id)
	state.clear_action()
	state.last_result = result
	state.last_code = code
	if state.reservation_auto and not state.reserved_spot_id.is_empty():
		_drop_reservation(npc_id, state)
	_mark_dirty(npc_id)
	if result == NpcExecutorState.RESULT_DONE:
		_tell(npc_id, INTERRUPT_DONE)
	elif result == NpcExecutorState.RESULT_FAILED:
		_tell(npc_id, INTERRUPT_FAILED_PREFIX + code)


func _drop_reservation(npc_id: String, state: NpcExecutorState) -> void:
	_reservations.release_of(npc_id)
	state.reserved_spot_id = ""
	state.reservation_auto = false
	_mark_dirty(npc_id)


## Asks the scheduler for a decision of `npc_id` in the next tick.
func _tell(npc_id: String, reason: String) -> void:
	var scheduler: NpcScheduler = _scheduler_ref.get_ref() as NpcScheduler if _scheduler_ref != null else null
	if scheduler == null:
		return
	if not scheduler.request_interrupt(npc_id, reason):
		dropped_interrupt_count += 1
		GameLogger.warning("npc", "the scheduler did not take an action result", {"entity_id": npc_id, "reason": reason, "operation": "tell"})
