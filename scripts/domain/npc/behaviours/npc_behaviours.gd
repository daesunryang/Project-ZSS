class_name NpcBehaviours
extends NpcStage
## WHAT the basic actions do (P4-5b, docs/09 §17.8, docs/13 §16.3 D2 / D7 /
## D10): eat, drink, rest, sleep, work, wander and flee. One NpcStage, stage id
## "behaviours", added after the executor. It stands between the decision
## layer (P4-4), whose NpcActionExecutor contract it fulfils through
## NpcBehaviourExecutor (action_executor()), and the movement executor
## (NpcExecutor, P4-5a), which walks the NPC to a spot and holds it there.
## This stage finds the place, and does what happens at the place: takes
## food out of a container, lowers a need, changes what the NPC is busy
## with for the need model, counts what was done.
##
## The actions, by NpcActionDefinition.action_id:
##   eat     An NPC that carries food eats it where it stands. Otherwise it
##           walks to a food spot (the one of its home first, then the
##           nearest), takes ONE unit of food out of the container on that
##           tile into its own inventory (InventoryService.transfer_item)
##           and eats it: after eat_duration_sec the unit is used up and
##           the item's consume effect lowers its hunger (and thirst). No
##           food there: the action fails with no_resource.
##   drink   Walks to a free water spot, stays drink_duration_sec, and its
##           thirst drops by drink_thirst_reduction. Water never runs out.
##   rest    Walks to a free bed (the one nearest to its home tile first)
##           and lies there; without a free bed it rests where it stands.
##           While it rests the need model counts it as "resting" (fatigue
##           falls over calendar time). It gets up by itself when its
##           fatigue is at most rest_until_fatigue (looked at every
##           rest_check_period_sec), or when the decision layer cancels the
##           action (a visible zombie: the flee interrupt wins). Since
##           F-6 this is the nap.
##   sleep   The night sleep (F-6, docs/09 §17.11). Like rest, with two
##           differences: without a free bed the NPC walks to its home tile
##           and sleeps there (without a home on this map: where it stands),
##           and it gets up by itself only when its fatigue is at most
##           sleep_until_fatigue (0).
##   work    (Only an NPC that has a work place: an NPC that lives alone in
##           a generated building, F-28, has none.)
##           Walks to the work spot of its work building and works there
##           for work_shift_sec ("working" for the need model: fatigue
##           rises faster). The time is added to the NPC's worked time.
##           Nothing is produced (Phase 6).
##   wander  Walks to a random place within wander_radius_m of its home
##           (two numbers of the NPC's own generator), stands there
##           wander_linger_sec, done.
##   flee    Runs flee_distance_m straight away from the threat the
##           decision layer names (target.threat_position).
## F-29 (docs/09 §17.14; only with enable_survival(), otherwise refused):
##   scavenge  A trip of an NPC that lives alone: to a building, through
##           its containers, home, the loot into the home's containers
##           (NpcScavenging).
##   treat   Stands treat_duration_sec, then uses the first item it carries
##           that treats it (NpcHealth.apply_treatment). No such item when
##           the time is over: no_resource.
##   fight   Stands and swings at the nearest zombie within reach with the
##           best weapon it carries (NpcFighting), again after every weapon
##           cooldown, until no living zombie is within reach.
## And two changes to the actions above for an NPC that lives alone:
##   drink   Farther than drink_carried_beyond_m from its home it drinks a
##           drink it carries, where it stands.
##   flee    It runs home instead of straight away when its home is far
##           enough from the threat and not behind it (not while it is
##           moving to another shelter, F-30).
## F-30 (docs/09 §17.15; only with enable_relocation(), otherwise refused):
##   relocate  An NPC that lives alone moves to another shelter: it
##           chooses a building, packs what it can carry at home, walks
##           there in legs and moves in (NpcRelocation). A move that was
##           cut short goes on when the action begins again. While an NPC
##           is in the middle of a move it rests and sleeps where it
##           stands, not in the bed of the home it is leaving.
## F-31 (docs/09 §17.16; only with enable_social(), otherwise refused):
##   meet    What an NPC does about a player it noticed (the decision
##           layer starts it, NpcSocial says how: target.mode). "watch" and
##           "talk": it stands where it is for target.hold_sec. "approach":
##           it walks up to greet_distance_m from the player, then stands.
##           "back_off": it walks back_off_distance_m away from the player,
##           then stands. A walk that cannot begin is no failure: it
##           stands instead. NpcSocial turns a standing NPC to the player.
## Any other action id is refused (unsupported_action).
##
## Reports to the decision layer (the scheduler's interrupts, P4-4's
## names): "action_arrived" when the NPC starts doing the thing at its
## place, "action_done", "action_failed_<code>" with no_path (no way, or
## blocked too often), target_gone (no such spot, or the spot is gone),
## reserved (every spot is taken, or it was taken while the NPC slept),
## no_resource (no food). The movement executor's own reports go through
## this stage (NpcExecutor.set_listener); those of an NPC whose action this
## stage did not start are passed on unchanged.
##
## Events (signals, for memories and logs of later tickets):
## behaviour_started / behaviour_finished / behaviour_failed /
## behaviour_cancelled.
##
## Food stock: a food spot's container is given the spot's stock
## (NpcSpotDefinition.stock_item_id / stock_units) once per world, the
## first time an NPC comes to eat there. Which spots were stocked is this
## stage's world document.
##
## Save: per NPC the component "behaviour" (NpcBehaviourState): the action
## and its step, its timer, the spot, the counts, what the NPC carries.
## Whole numbers and names only. Sleeping NPCs keep everything as it is.

## Emitted when an action was accepted. `info`: {spot_id} when it uses one.
signal behaviour_started(npc_id: String, action_id: String, info: Dictionary)
## Emitted when an action is complete. `info`: what it did, e.g.
## {item_definition_id, hunger} for eat, {thirst} for drink, {fatigue} for
## rest, {worked_usec} for work.
signal behaviour_finished(npc_id: String, action_id: String, info: Dictionary)
signal behaviour_failed(npc_id: String, action_id: String, code: String)
signal behaviour_cancelled(npc_id: String, action_id: String)

const STAGE_ID: String = "behaviours"
## A decider that has this method is given the stage by ServerComposition.
const DECIDER_HOOK: StringName = &"on_behaviours_attached"
const SCHEMA_VERSION: int = 1
const KEY_SCHEMA_VERSION: String = "schema_version"
const KEY_STOCKED: String = "stocked"
const MAX_STOCKED: int = 4096

const ACTION_EAT: String = "eat"
const ACTION_DRINK: String = "drink"
const ACTION_REST: String = "rest"
const ACTION_SLEEP: String = "sleep"
const ACTION_WORK: String = "work"
const ACTION_WANDER: String = "wander"
const ACTION_FLEE: String = "flee"
const ACTION_SCAVENGE: String = "scavenge"
const ACTION_TREAT: String = "treat"
const ACTION_FIGHT: String = "fight"
const ACTION_RELOCATE: String = "relocate"
const ACTION_MEET: String = NpcSocial.ACTION_MEET
const ACTIONS: PackedStringArray = [ACTION_EAT, ACTION_DRINK, ACTION_REST, ACTION_SLEEP, ACTION_WORK, ACTION_WANDER, ACTION_FLEE, ACTION_SCAVENGE, ACTION_TREAT, ACTION_FIGHT, ACTION_RELOCATE, ACTION_MEET]
## The actions of F-29: refused until enable_survival() was called.
const SURVIVAL_ACTIONS: PackedStringArray = [ACTION_SCAVENGE, ACTION_TREAT, ACTION_FIGHT]
## Count of the swings of a fight that hit / that killed.
const COUNT_FIGHT_HIT: String = "fight_hit"
const COUNT_FIGHT_KILL: String = "fight_kill"
## Count of an action that was cut short while it was being done:
## "<action id>_cut" (NpcBehaviourState.counts).
const COUNT_CUT_SUFFIX: String = "_cut"
## begin() refused because the NPC cannot act now (it is not awake).
const FAIL_NOT_READY: String = "not_ready"
## Keys of the events' info.
const INFO_SPOT: String = "spot_id"
const INFO_ITEM: String = "item_definition_id"
const INFO_WORKED: String = "worked_usec"

## Diagnostics (tests / profiling).
var started_count: int = 0
var finished_count: int = 0
var failed_count: int = 0
var cancelled_count: int = 0
var stocked_count: int = 0
var last_step_usec: int = 0

var _settings: NpcBehaviourSettings
var _executor: NpcExecutor = null
var _items: ItemCatalog = null
var _spots: NpcSpotSet = null
var _map_content: MapContentDefinition = null
var _grid: StructureGrid = null
## F-28: where each NPC lives (never null after install).
var _homes: NpcHomes = null
## F-29: null until enable_survival().
var _sense: NpcSurvivalSense = null
var _scavenging: NpcScavenging = null
var _fighting: NpcFighting = null
## F-30: null until enable_relocation().
var _relocation: NpcRelocation = null
## F-31: null until enable_social().
var _social_settings: NpcSocialSettings = null
var _adapter_ref: WeakRef = null
var _world_ref: WeakRef = null
var _npcs_ref: WeakRef = null
## Awake NPCs whose action this stage runs: npc_id -> its state.
var _running: Dictionary[String, NpcBehaviourState] = {}
var _order: PackedStringArray = []
var _order_stale: bool = false
## Food spots whose container was given its stock.
var _stocked: Dictionary[String, bool] = {}


func _init(settings: NpcBehaviourSettings = null) -> void:
	_settings = settings if settings != null else NpcBehaviourSettings.new()


## Gives `npcs` the behaviour component and stage (ServerComposition, after
## NpcExecutor.install) and makes this stage the executor's listener.
## `homes` (F-28): where the NPCs live; without it every NPC lives where its
## definition says. Returns the stage, or null when a registration fails.
static func install(npcs: NpcService, settings: NpcBehaviourSettings, executor: NpcExecutor, items: ItemCatalog, grid: StructureGrid, spots: NpcSpotSet = null, map_content: MapContentDefinition = null, homes: NpcHomes = null) -> NpcBehaviours:
	if npcs == null or settings == null or executor == null or grid == null:
		return null
	var stage: NpcBehaviours = NpcBehaviours.new(settings)
	stage._executor = executor
	stage._items = items
	stage._grid = grid
	stage._spots = spots
	stage._map_content = map_content
	stage._homes = homes if homes != null else NpcHomes.new(null, map_content, grid)
	if npcs.register_component(NpcBehaviourState.COMPONENT_ID, NpcBehaviourState.create.bind(settings)) != OK or npcs.add_stage(stage) != OK:
		return null
	stage._npcs_ref = weakref(npcs)
	executor.set_listener(Callable(stage, "_on_executor_report"))
	return stage


func stage_id() -> String:
	return STAGE_ID


## The NpcActionExecutor to give the decider (NpcUtilityDecider.set_executor).
## The decider keeps it alive.
func action_executor() -> NpcBehaviourExecutor:
	var adapter: NpcBehaviourExecutor = _adapter_ref.get_ref() as NpcBehaviourExecutor if _adapter_ref != null else null
	if adapter == null:
		adapter = NpcBehaviourExecutor.new(self)
		_adapter_ref = weakref(adapter)
	return adapter


func movement_executor() -> NpcExecutor:
	return _executor


## F-29: turns on the actions scavenge, treat and fight, and what an NPC
## that lives alone does differently when it drinks and flees
## (ServerComposition, before the world runs).
func enable_survival(sense: NpcSurvivalSense, fighting: NpcFighting) -> void:
	_sense = sense
	_fighting = fighting
	_scavenging = NpcScavenging.new(sense, _grid, Callable(self, "_move")) if sense != null else null


## The scavenging helper (null without enable_survival()).
func scavenging() -> NpcScavenging:
	return _scavenging


func fighting() -> NpcFighting:
	return _fighting


## F-30: turns on the action relocate (ServerComposition, after
## enable_survival(), before the world runs). Returns the helper that knows
## when and where an NPC moves, or null without the survival layer.
func enable_relocation(settings: NpcRelocationSettings) -> NpcRelocation:
	if _sense == null or _scavenging == null or settings == null:
		return null
	_relocation = NpcRelocation.new(settings, _sense, _scavenging, _grid, Callable(self, "_move"))
	return _relocation


## The moving helper (null without enable_relocation()).
func relocation() -> NpcRelocation:
	return _relocation


## F-31: turns the action "meet" on (how an NPC stands for, comes to or
## backs off from a player it noticed).
func enable_social(settings: NpcSocialSettings) -> void:
	_social_settings = settings


# ------------------------------------------------------------ the contract

## NpcActionExecutor.begin: "" when the action runs now, or a failure code.
func begin(world: ServerWorld, npcs: NpcService, npc: NpcState, action: NpcActionDefinition, target: Dictionary) -> String:
	var state: NpcBehaviourState = _state_of(npc)
	if world == null or npcs == null or state == null or action == null:
		return NpcActionExecutor.FAIL_UNSUPPORTED
	if not ACTIONS.has(action.action_id) or (_sense == null and SURVIVAL_ACTIONS.has(action.action_id)) or (_relocation == null and action.action_id == ACTION_RELOCATE) or (_social_settings == null and action.action_id == ACTION_MEET):
		return NpcActionExecutor.FAIL_UNSUPPORTED
	if not npcs.is_awake(npc.npc_id):
		return FAIL_NOT_READY
	_world_ref = weakref(world)
	_npcs_ref = weakref(npcs)
	# Never called while an action runs (the decider cancels first); a
	# movement somebody else began is not this stage's to keep either.
	if state.is_running():
		cancel(world, npcs, npc)
	if _executor.is_busy(npc.npc_id):
		_executor.cancel(npc.npc_id)
	var definition: NpcDefinition = npcs.definition_of(npc.npc_id)
	var code: String = ""
	match action.action_id:
		ACTION_EAT:
			code = _begin_eat(world, npc, state, definition)
		ACTION_DRINK:
			if _drinks_what_it_carries(world, npc, state, definition):
				state.step = NpcBehaviourState.STEP_PERFORMING
				state.timer_usec = maxi(NpcBehaviourSettings.to_usec(_settings.drink_duration_sec), 1)
				_report(npc.npc_id, NpcActionExecutor.REPORT_ARRIVED)
			else:
				code = _begin_at_spot(npc, state, NpcSpotDefinition.KIND_WATER, _homes.home_building_id(npc, definition), npc.position, _settings.drink_duration_sec)
		ACTION_REST:
			code = _begin_rest(world, npc, state, definition, false)
		ACTION_SLEEP:
			code = _begin_rest(world, npc, state, definition, true)
		ACTION_WORK:
			code = _begin_at_spot(npc, state, NpcSpotDefinition.KIND_WORK, _homes.work_building_id(npc, definition), _place_of(npc, definition, false), _settings.work_shift_sec)
		ACTION_WANDER:
			code = _begin_wander(world, npc, state, definition)
		ACTION_FLEE:
			code = _begin_flee(world, npc, state, target, definition)
		ACTION_SCAVENGE:
			code = _scavenging.begin(world, npcs, npc, state)
		ACTION_TREAT:
			code = _begin_treat(npc, state)
		ACTION_FIGHT:
			code = _begin_fight(world, npc, state)
		ACTION_RELOCATE:
			code = _relocation.begin(world, npcs, npc, state)
		ACTION_MEET:
			code = _begin_meet(world, npc, state, target)
	if not code.is_empty():
		state.clear_action()
		return code
	state.action_id = action.action_id
	_running[npc.npc_id] = state
	_order_stale = true
	started_count += 1
	npcs.mark_npc_dirty(npc.npc_id)
	behaviour_started.emit(npc.npc_id, action.action_id, {INFO_SPOT: state.spot_id} if not state.spot_id.is_empty() else {})
	return ""


## NpcActionExecutor.is_running: an action of this NPC (in memory) runs.
func is_running(npc_id: String) -> bool:
	if _running.has(npc_id):
		return true
	var npcs: NpcService = _npcs()
	var state: NpcBehaviourState = _state_of(npcs.get_npc(npc_id)) if npcs != null else null
	return state != null and state.is_running()


## NpcActionExecutor.cancel: stops the NPC's action where it is. Reports
## nothing.
func cancel(world: ServerWorld, npcs: NpcService, npc: NpcState) -> void:
	var state: NpcBehaviourState = _state_of(npc)
	if state == null or not state.is_running():
		return
	var action_id: String = state.action_id
	# An action that was being done when it was cut short is counted too
	# (a rest the decision layer ends because the NPC is rested enough).
	if state.step == NpcBehaviourState.STEP_PERFORMING:
		state.add_count(action_id + COUNT_CUT_SUFFIX)
	if action_id == ACTION_SCAVENGE and _scavenging != null:
		_scavenging.on_cancelled(npc)
	_end(world, npcs, npc, state)
	_executor.cancel(npc.npc_id)
	cancelled_count += 1
	behaviour_cancelled.emit(npc.npc_id, action_id)


## What the debug overlay shows of one NPC in memory ({} = not in memory):
## the running action, its step, the spot, the counts and the worked time.
func behaviour_info(npc_id: String) -> Dictionary:
	var npcs: NpcService = _npcs()
	var state: NpcBehaviourState = _state_of(npcs.get_npc(npc_id)) if npcs != null else null
	if state == null:
		return {}
	return {
		NpcBehaviourState.KEY_ACTION_ID: state.action_id,
		NpcBehaviourState.KEY_STEP: state.step,
		NpcBehaviourState.KEY_SPOT: state.spot_id,
		NpcBehaviourState.KEY_COUNTS: state.counts.duplicate(),
		NpcBehaviourState.KEY_WORKED: state.worked_usec,
	}


## True when the food spot's container was given its stock.
func is_stocked(spot_id: String) -> bool:
	return _stocked.has(spot_id)


# ------------------------------------------------------------ NpcStage

func on_npc_woke(world: ServerWorld, npc: NpcState) -> void:
	var state: NpcBehaviourState = _state_of(npc)
	if state == null:
		return
	_world_ref = weakref(world)
	_npcs_ref = weakref(world.get_system(NpcService.SYSTEM_ID))
	if state.is_running():
		_running[npc.npc_id] = state
		_order_stale = true
	if _scavenging != null:
		_scavenging.queue_cells_of(world, npc)
	if _relocation != null:
		_relocation.on_npc_woke(world, _npcs(), npc)


func on_npc_slept(_world_now: ServerWorld, npc: NpcState) -> void:
	if _running.erase(npc.npc_id):
		_order_stale = true


## The timers this stage keeps itself: eating what is carried, lingering,
## the look at a resting NPC, the time worked.
func step(world: ServerWorld, npcs: NpcService, action_delta: float, _world_delta: float) -> void:
	last_step_usec = 0
	if not is_finite(action_delta) or action_delta <= 0.0:
		return
	if _scavenging != null:
		_scavenging.warm_one()
	if _relocation != null:
		_relocation.begin_tick()
	if _running.is_empty():
		return
	var started_usec: int = Time.get_ticks_usec()
	_world_ref = weakref(world)
	_npcs_ref = weakref(npcs)
	var delta_usec: int = NpcExecutorSettings.to_usec(action_delta)
	if _order_stale:
		_order = NpcExecutor._sorted(_running.keys())
		_order_stale = false
	for npc_id: String in _order:
		var state: NpcBehaviourState = _running.get(npc_id, null)
		var npc: NpcState = npcs.get_npc(npc_id)
		if state == null or npc == null:
			continue
		# An action that needs the movement executor, which knows nothing of
		# it (a save of another build): it cannot go on.
		if (state.step == NpcBehaviourState.STEP_GOING or not state.spot_id.is_empty()) and not _executor.is_busy(npc_id):
			_fail(world, npcs, npc, state, NpcActionExecutor.FAIL_TARGET_GONE)
			continue
		if state.step != NpcBehaviourState.STEP_PERFORMING:
			continue
		if state.action_id == ACTION_WORK:
			state.worked_usec += delta_usec
			npcs.mark_npc_dirty(npc_id)
			continue
		if state.timer_usec == NpcBehaviourState.NO_TIMER:
			continue
		state.timer_usec = maxi(state.timer_usec - delta_usec, 0)
		npcs.mark_npc_dirty(npc_id)
		if state.timer_usec > 0:
			continue
		match state.action_id:
			ACTION_EAT:
				_finish_eating(world, npcs, npc, state)
			ACTION_DRINK:
				_finish_drinking_carried(world, npcs, npc, state)
			ACTION_SCAVENGE:
				_step_scavenge(world, npcs, npc, state)
			ACTION_TREAT:
				_finish_treating(world, npcs, npc, state)
			ACTION_FIGHT:
				_swing(world, npcs, npc, state)
			ACTION_RELOCATE:
				_step_relocate(world, npcs, npc, state)
			ACTION_REST, ACTION_SLEEP:
				var needs: NpcNeeds = _advanced_needs(world, npc)
				if needs == null or needs.value(NpcNeedKind.FATIGUE) <= (_settings.sleep_until_fatigue if state.action_id == ACTION_SLEEP else _settings.rest_until_fatigue):
					_executor.cancel(npc_id)
					_finish(world, npcs, npc, state, {NpcNeedKind.FATIGUE: needs.value(NpcNeedKind.FATIGUE)} if needs != null else {})
				else:
					state.timer_usec = NpcBehaviourSettings.to_usec(_settings.rest_check_period_sec)
			_:
				_finish(world, npcs, npc, state, {})
	last_step_usec = Time.get_ticks_usec() - started_usec


func to_world_document() -> Dictionary:
	if _stocked.is_empty():
		return {}
	var stocked: PackedStringArray = PackedStringArray(_stocked.keys())
	stocked.sort()
	return {KEY_SCHEMA_VERSION: SCHEMA_VERSION, KEY_STOCKED: Array(stocked)}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get(KEY_SCHEMA_VERSION, null)) or int(document[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("npc behaviours: unsupported schema_version")
		return errors
	var stocked: Variant = document.get(KEY_STOCKED, null)
	if typeof(stocked) != TYPE_ARRAY or (stocked as Array).size() > MAX_STOCKED:
		errors.append("npc behaviours: stocked must be a list")
		return errors
	for spot_id: Variant in (stocked as Array):
		if typeof(spot_id) != TYPE_STRING or not NpcComponent.is_valid_id(str(spot_id)):
			errors.append("npc behaviours: stocked holds spot ids")
			return errors
	_stocked.clear()
	for spot_id: Variant in (stocked as Array):
		_stocked[str(spot_id)] = true
	return errors


# ------------------------------------------------------------ beginning

func _begin_eat(world: ServerWorld, npc: NpcState, state: NpcBehaviourState, definition: NpcDefinition) -> String:
	if _food_stack(world, state.inventory_id) != null:
		# It carries food (an eating that was cut short): no way to go.
		state.step = NpcBehaviourState.STEP_PERFORMING
		state.timer_usec = NpcBehaviourSettings.to_usec(_settings.eat_duration_sec)
		_report(npc.npc_id, NpcActionExecutor.REPORT_ARRIVED)
		if state.timer_usec == 0:
			state.timer_usec = 1
		return ""
	# A container that is known to hold no food (it is in memory, has its
	# stock already and no food) is not walked to: the next spot is tried.
	var known_empty: Dictionary[String, bool] = {}
	while true:
		var picked: Dictionary = _pick_spot(npc, NpcSpotDefinition.KIND_FOOD, _homes.home_building_id(npc, definition), npc.position, known_empty)
		if not str(picked["code"]).is_empty():
			return NpcActionExecutor.FAIL_NO_RESOURCE if not known_empty.is_empty() else str(picked["code"])
		var spot_id: String = str(picked["spot"])
		var container: ContainerInstance = _container_at(world, spot_id)
		if container != null and (_stocked.has(spot_id) or _executor.spot_definition(spot_id).stock_units <= 0) and _food_stack(world, container.inventory_id) == null:
			known_empty[spot_id] = true
			continue
		return _use_spot(npc.npc_id, state, spot_id, _settings.eat_duration_sec)
	return NpcActionExecutor.FAIL_NO_RESOURCE


## Rest and sleep. `go_home` (the night sleep): without a bed the NPC walks
## to its home tile first.
func _begin_rest(world: ServerWorld, npc: NpcState, state: NpcBehaviourState, definition: NpcDefinition, go_home: bool) -> String:
	if _relocation != null and _relocation.is_moving(npc):
		# F-30: on its way to another shelter it lies down where it stands.
		_start_resting(world, npc, state, go_home)
		_report(npc.npc_id, NpcActionExecutor.REPORT_ARRIVED)
		return ""
	var picked: Dictionary = _pick_spot(npc, NpcSpotDefinition.KIND_BED, _homes.home_building_id(npc, definition), _place_of(npc, definition, true))
	if str(picked["code"]).is_empty():
		var code: String = _use_spot(npc.npc_id, state, str(picked["spot"]), NpcExecutor.HOLD)
		if code.is_empty():
			return ""
	if go_home:
		# No bed for it: it sleeps on its home tile, when it has one here and
		# is not there yet (the walk ends in _on_done).
		var home: Vector3 = _place_of(npc, definition, true)
		if _grid.tile_of(home) != _grid.tile_of(npc.position) and _move(npc.npc_id, state, home, false).is_empty():
			return ""
	# No bed for it: it rests where it stands. (state.action_id is set only
	# after begin returns, so the kind of sleep comes from go_home.)
	_start_resting(world, npc, state, go_home)
	_report(npc.npc_id, NpcActionExecutor.REPORT_ARRIVED)
	return ""


func _begin_at_spot(npc: NpcState, state: NpcBehaviourState, kind: String, building_id: String, near: Vector3, duration_sec: float) -> String:
	var picked: Dictionary = _pick_spot(npc, kind, building_id, near)
	if not str(picked["code"]).is_empty():
		return str(picked["code"])
	return _use_spot(npc.npc_id, state, str(picked["spot"]), duration_sec)


func _begin_wander(world: ServerWorld, npc: NpcState, state: NpcBehaviourState, definition: NpcDefinition) -> String:
	var centre: Vector3 = _place_of(npc, definition, true)
	# Always two numbers of the NPC's own generator.
	var angle: float = npc.rng.randf() * TAU
	var distance: float = sqrt(npc.rng.randf()) * _settings.wander_radius_m
	var goal: Vector3 = world.clamp_to_world(Vector3(centre.x + cos(angle) * distance, npc.position.y, centre.z + sin(angle) * distance))
	return _move(npc.npc_id, state, goal, false)


func _begin_flee(world: ServerWorld, npc: NpcState, state: NpcBehaviourState, target: Dictionary, definition: NpcDefinition) -> String:
	var raw: Variant = target.get(NpcActionExecutor.TARGET_THREAT_POSITION, null)
	var away: Vector3 = Vector3.ZERO
	var threat_known: bool = false
	if typeof(raw) == TYPE_ARRAY and (raw as Array).size() == 3:
		away = Vector3(npc.position.x - float(raw[0]), 0.0, npc.position.z - float(raw[2]))
		threat_known = away.is_finite()
	if not away.is_finite() or away.length() < 0.001:
		# On top of the threat, or no threat named: any way is away.
		var angle: float = npc.rng.randf() * TAU
		away = Vector3(cos(angle), 0.0, sin(angle))
	var goal: Vector3 = world.clamp_to_world(npc.position + away.normalized() * _settings.flee_distance_m)
	if threat_known and _sense != null and _sense.is_lone(npc) and not (_relocation != null and _relocation.is_moving(npc)):
		# F-29: home is the safe place, when it is far enough from the threat
		# and the way there does not lead towards it.
		var home: Vector3 = _place_of(npc, definition, true)
		var to_home: Vector3 = Vector3(home.x - npc.position.x, 0.0, home.z - npc.position.z)
		var home_from_threat: float = Vector2(home.x - float(raw[0]), home.z - float(raw[2])).length()
		if _grid.tile_of(home) != _grid.tile_of(npc.position) and home_from_threat >= _sense.settings.flee_home_min_threat_distance_m and to_home.dot(away) >= 0.0:
			goal = home
	return _move(npc.npc_id, state, goal, true)


# ------------------------------------------------------------ F-31: players

## The NPC stands for a player, comes over or backs off (see the header).
func _begin_meet(world: ServerWorld, npc: NpcState, state: NpcBehaviourState, target: Dictionary) -> String:
	var mode: String = str(target.get(NpcSocial.TARGET_MODE, ""))
	if not NpcSocial.MODES.has(mode):
		return NpcActionExecutor.FAIL_TARGET_GONE
	var raw: Variant = target.get(NpcSocial.TARGET_PLAYER_POSITION, null)
	var hold: Variant = target.get(NpcSocial.TARGET_HOLD_SEC, 0.0)
	var hold_sec: float = float(hold) if (typeof(hold) == TYPE_FLOAT or typeof(hold) == TYPE_INT) and is_finite(float(hold)) else 0.0
	state.meet_hold_usec = maxi(NpcBehaviourSettings.to_usec(hold_sec), 1)
	if (mode == NpcSocial.MODE_APPROACH or mode == NpcSocial.MODE_BACK_OFF) and typeof(raw) == TYPE_ARRAY and (raw as Array).size() == 3:
		var away: Vector3 = Vector3(npc.position.x - float(raw[0]), 0.0, npc.position.z - float(raw[2]))
		if away.is_finite() and away.length() >= 0.001:
			var goal: Vector3 = npc.position + away.normalized() * _social_settings.back_off_distance_m
			if mode == NpcSocial.MODE_APPROACH:
				goal = Vector3(float(raw[0]), npc.position.y, float(raw[2])) + away.normalized() * _social_settings.greet_distance_m
			if _move(npc.npc_id, state, world.clamp_to_world(goal), false).is_empty():
				return ""
	_stand_meeting(npc.npc_id, state)
	return ""


## The NPC of a "meet" stands where it is for the rest of its time.
func _stand_meeting(npc_id: String, state: NpcBehaviourState) -> void:
	state.step = NpcBehaviourState.STEP_PERFORMING
	state.timer_usec = maxi(state.meet_hold_usec, 1)
	_report(npc_id, NpcActionExecutor.REPORT_ARRIVED)


# ------------------------------------------------------------ F-29: survival

## True when the NPC drinks a drink it carries where it stands: it lives
## alone, carries one, and is farther from its home than
## drink_carried_beyond_m.
func _drinks_what_it_carries(world: ServerWorld, npc: NpcState, state: NpcBehaviourState, definition: NpcDefinition) -> bool:
	if _sense == null or not _sense.is_lone(npc) or _drink_stack(world, state.inventory_id) == null:
		return false
	var home: Vector3 = _place_of(npc, definition, true)
	return Vector2(home.x - npc.position.x, home.z - npc.position.z).length() > _sense.settings.drink_carried_beyond_m


## The first stack of a drink (it lowers thirst and not hunger, and treats
## nothing) in an inventory, by slot; null when there is none.
func _drink_stack(world: ServerWorld, inventory_id: String) -> ItemInstance:
	for item: ItemInstance in NpcSurvivalSense.items_of(world, inventory_id):
		if _sense.kind_of(world.inventory.definition_of(item.item_instance_id)) == NpcSurvivalSense.KIND_DRINK:
			return item
	return null


## The unit of drink the NPC carries is used up and lowers its thirst.
func _finish_drinking_carried(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> void:
	var stack: ItemInstance = _drink_stack(world, state.inventory_id) if _sense != null else null
	var drink: ItemDefinition = world.inventory.definition_of(stack.item_instance_id) if stack != null else null
	if drink == null or not world.inventory.remove_item(state.inventory_id, stack.item_instance_id, 1).ok:
		_fail(world, npcs, npc, state, NpcActionExecutor.FAIL_NO_RESOURCE)
		return
	var needs: NpcNeeds = _advanced_needs(world, npc)
	var info: Dictionary = {INFO_ITEM: drink.definition_id}
	if needs != null:
		needs.satisfy(NpcNeedKind.THIRST, drink.consume_thirst_reduction, "drink_%s" % drink.definition_id)
		info[NpcNeedKind.THIRST] = needs.value(NpcNeedKind.THIRST)
	_finish(world, npcs, npc, state, info)


## The timer of a scavenging trip ran out (a search, or the stowing).
func _step_scavenge(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> void:
	var info: Dictionary = {}
	var code: String = _scavenging.on_timer(world, npcs, npc, state, info) if _scavenging != null else NpcActionExecutor.FAIL_UNSUPPORTED
	if code == NpcScavenging.STEP_DONE:
		_finish(world, npcs, npc, state, info)
	elif code != NpcScavenging.STEP_CONTINUES:
		_fail(world, npcs, npc, state, code)


## F-30: the timer of a move ran out (choosing, packing, the pause before
## a leg, settling).
func _step_relocate(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> void:
	var info: Dictionary = {}
	var code: String = _relocation.on_timer(world, npcs, npc, state, info) if _relocation != null else NpcActionExecutor.FAIL_UNSUPPORTED
	if code == NpcRelocation.STEP_DONE:
		_finish(world, npcs, npc, state, info)
	elif code != NpcRelocation.STEP_CONTINUES:
		_fail(world, npcs, npc, state, code)


func _begin_treat(npc: NpcState, state: NpcBehaviourState) -> String:
	if not _sense.can_treat(npc):
		return NpcActionExecutor.FAIL_NO_RESOURCE
	state.step = NpcBehaviourState.STEP_PERFORMING
	state.timer_usec = maxi(NpcBehaviourSettings.to_usec(_sense.settings.treat_duration_sec), 1)
	_report(npc.npc_id, NpcActionExecutor.REPORT_ARRIVED)
	return ""


## The NPC uses the first item it carries that treats it.
func _finish_treating(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> void:
	var item: ItemInstance = _sense.treatment_item(npc) if _sense != null else null
	var health: NpcHealth = NpcHealth.of_world(world)
	var treatment: ItemDefinition = world.inventory.definition_of(item.item_instance_id) if item != null else null
	if treatment == null or health == null:
		_fail(world, npcs, npc, state, NpcActionExecutor.FAIL_NO_RESOURCE)
		return
	var item_id: String = item.item_instance_id
	if not world.inventory.remove_item(state.inventory_id, item_id, 1).ok or not health.apply_treatment(npc.npc_id, treatment, item_id).ok:
		_fail(world, npcs, npc, state, NpcActionExecutor.FAIL_NO_RESOURCE)
		return
	_finish(world, npcs, npc, state, {INFO_ITEM: treatment.definition_id})


func _begin_fight(world: ServerWorld, npc: NpcState, state: NpcBehaviourState) -> String:
	if _fighting == null or NpcFighting.nearest_zombie(world, npc, _fighting.reach_of(world, state.inventory_id, _sense.settings.fight_range_m)).is_empty():
		return NpcActionExecutor.FAIL_TARGET_GONE
	state.step = NpcBehaviourState.STEP_PERFORMING
	state.timer_usec = maxi(NpcBehaviourSettings.to_usec(_sense.settings.fight_windup_sec), 1)
	_report(npc.npc_id, NpcActionExecutor.REPORT_ARRIVED)
	return ""


## One swing of a fight; the fight is over when no living zombie is within
## reach any more.
func _swing(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> void:
	var reach: float = _fighting.reach_of(world, state.inventory_id, _sense.settings.fight_range_m) if _fighting != null else 0.0
	var zombie_id: String = NpcFighting.nearest_zombie(world, npc, reach)
	if zombie_id.is_empty():
		_finish(world, npcs, npc, state, {})
		return
	var swung: Dictionary = _fighting.swing(world, npcs, npc, state.inventory_id, zombie_id, _sense.settings.fight_range_m)
	if bool(swung[NpcFighting.KEY_HIT]):
		state.add_count(COUNT_FIGHT_HIT)
	if bool(swung[NpcFighting.KEY_DIED]):
		state.add_count(COUNT_FIGHT_KILL)
		if NpcFighting.nearest_zombie(world, npc, reach).is_empty():
			_finish(world, npcs, npc, state, {NpcActionExecutor.TARGET_THREAT_ID: zombie_id})
			return
	state.timer_usec = maxi(NpcBehaviourSettings.to_usec(float(swung[NpcFighting.KEY_COOLDOWN_SEC])), 1)


func _move(npc_id: String, state: NpcBehaviourState, goal: Vector3, run: bool) -> String:
	var begun: ActionResult = _executor.begin_move(npc_id, goal, run)
	if not begun.ok:
		return _refusal_code(begun.reason)
	state.step = NpcBehaviourState.STEP_GOING
	state.timer_usec = NpcBehaviourState.NO_TIMER
	return ""


func _use_spot(npc_id: String, state: NpcBehaviourState, spot_id: String, duration_sec: float) -> String:
	var begun: ActionResult = _executor.begin_use_spot(npc_id, spot_id, duration_sec)
	if not begun.ok:
		return _refusal_code(begun.reason)
	state.step = NpcBehaviourState.STEP_GOING
	state.timer_usec = NpcBehaviourState.NO_TIMER
	state.spot_id = spot_id
	return ""


## {spot, code}: the free spot of `kind` nearest to `near`, of the building
## first, then of any; code "" when there is one, target_gone when the
## world has no such spot, reserved when every one is taken. Spots in
## `without` are not looked at. An NPC that lives in a generated building
## (F-28) has the spots of that building and no others: it lives alone, far
## from the spots of the hand-made map.
func _pick_spot(npc: NpcState, kind: String, building_id: String, near: Vector3, without: Dictionary[String, bool] = {}) -> Dictionary:
	var npc_id: String = npc.npc_id
	var all: PackedStringArray = []
	if _homes.lives_in_generated_home(npc):
		for spot_id: String in _homes.generated_spot_ids(building_id, kind):
			if _executor.has_spot(spot_id) and not without.has(spot_id):
				all.append(spot_id)
	elif _spots != null:
		for spot_id: String in _spots.spot_ids(kind):
			if _executor.has_spot(spot_id) and not without.has(spot_id):
				all.append(spot_id)
	if all.is_empty():
		return {"spot": "", "code": NpcActionExecutor.FAIL_TARGET_GONE}
	for own_building: bool in [true, false]:
		if own_building and building_id.is_empty():
			continue
		var best: String = ""
		var best_distance: float = INF
		for spot_id: String in all:
			if own_building and _executor.spot_definition(spot_id).building_id != building_id:
				continue
			if not _executor.is_spot_free(spot_id, npc_id):
				continue
			var place: Vector3 = _executor.spot_position(spot_id)
			var distance: float = Vector2(place.x - near.x, place.z - near.z).length_squared()
			if distance < best_distance:
				best = spot_id
				best_distance = distance
		if not best.is_empty():
			return {"spot": best, "code": ""}
	return {"spot": "", "code": NpcActionExecutor.FAIL_RESERVED}


## The NPC's home tile (or work tile), or where it stands when it has none
## in this world.
func _place_of(npc: NpcState, definition: NpcDefinition, home: bool) -> Vector3:
	var place: Variant = _homes.home_position(npc, definition) if home else _homes.work_position(npc, definition)
	return place as Vector3 if place != null else npc.position


# ------------------------------------------------------------ the executor's reports

## NpcExecutor's listener: what the movement executor reports about an NPC.
func _on_executor_report(npc_id: String, reason: String) -> void:
	var state: NpcBehaviourState = _running.get(npc_id, null)
	var world: ServerWorld = _world()
	var npcs: NpcService = _npcs()
	var npc: NpcState = npcs.get_npc(npc_id) if npcs != null else null
	if state == null or world == null or npc == null:
		# Not an action of this stage: the decision layer hears it as it is.
		_executor.tell_scheduler(npc_id, reason)
		return
	if reason == NpcExecutor.INTERRUPT_ARRIVED:
		_on_arrived(world, npcs, npc, state)
	elif reason == NpcExecutor.INTERRUPT_DONE:
		_on_done(world, npcs, npc, state)
	elif not NpcExecutor.failure_code_of(reason).is_empty():
		var code: String = _failure_code(NpcExecutor.failure_code_of(reason))
		if state.action_id == ACTION_MEET:
			# F-31: no way to the player (or away from it) is no failure.
			_stand_meeting(npc_id, state)
			npcs.mark_npc_dirty(npc_id)
			return
		if state.action_id == ACTION_RELOCATE and _relocation != null:
			# F-30: a leg that found no way is not the end of a move.
			code = _relocation.on_walk_failed(world, npcs, npc, state, code)
			if code == NpcRelocation.STEP_CONTINUES:
				return
		_fail(world, npcs, npc, state, code)
	else:
		_executor.tell_scheduler(npc_id, reason)


## The NPC stands on the spot of its action.
func _on_arrived(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> void:
	match state.action_id:
		ACTION_EAT:
			_stock(world, npcs, state.spot_id)
			if not _take_food(world, npcs, state):
				_executor.cancel(npc.npc_id)
				_fail(world, npcs, npc, state, NpcActionExecutor.FAIL_NO_RESOURCE)
				return
			state.step = NpcBehaviourState.STEP_PERFORMING
		ACTION_REST, ACTION_SLEEP:
			_start_resting(world, npc, state, state.action_id == ACTION_SLEEP)
		ACTION_WORK:
			state.step = NpcBehaviourState.STEP_PERFORMING
			_set_activity(world, npc, NpcNeedKind.WORKING)
		_:
			state.step = NpcBehaviourState.STEP_PERFORMING
	npcs.mark_npc_dirty(npc.npc_id)
	_report(npc.npc_id, NpcActionExecutor.REPORT_ARRIVED)


## The movement executor is done: the walk is over, or the stay at the spot.
func _on_done(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> void:
	match state.action_id:
		ACTION_EAT:
			_finish_eating(world, npcs, npc, state)
		ACTION_DRINK:
			var needs: NpcNeeds = _advanced_needs(world, npc)
			if needs != null and _settings.drink_thirst_reduction > 0.0:
				needs.satisfy(NpcNeedKind.THIRST, _settings.drink_thirst_reduction, "drink_%s" % state.spot_id)
			_finish(world, npcs, npc, state, {NpcNeedKind.THIRST: needs.value(NpcNeedKind.THIRST)} if needs != null else {})
		ACTION_WORK:
			_finish(world, npcs, npc, state, {INFO_WORKED: state.worked_usec})
		ACTION_SLEEP:
			if state.step == NpcBehaviourState.STEP_GOING and state.spot_id.is_empty():
				# The walk home is over (no bed was free): it lies down there.
				_start_resting(world, npc, state, true)
				npcs.mark_npc_dirty(npc.npc_id)
				_report(npc.npc_id, NpcActionExecutor.REPORT_ARRIVED)
			else:
				_finish(world, npcs, npc, state, {})
		ACTION_WANDER:
			if _settings.wander_linger_sec > 0.0:
				state.step = NpcBehaviourState.STEP_PERFORMING
				state.timer_usec = NpcBehaviourSettings.to_usec(_settings.wander_linger_sec)
				npcs.mark_npc_dirty(npc.npc_id)
			else:
				_finish(world, npcs, npc, state, {})
		ACTION_SCAVENGE:
			# A walk of the trip is over: it searches, or puts its loot away.
			var code: String = _scavenging.on_walk_done(world, npcs, npc, state) if _scavenging != null else NpcActionExecutor.FAIL_UNSUPPORTED
			if code == NpcScavenging.STEP_CONTINUES:
				_report(npc.npc_id, NpcActionExecutor.REPORT_ARRIVED)
			else:
				_fail(world, npcs, npc, state, code)
		ACTION_MEET:
			# It came over (or backed off): it stands and looks at the player.
			_stand_meeting(npc.npc_id, state)
			npcs.mark_npc_dirty(npc.npc_id)
		ACTION_RELOCATE:
			# A walk of the move is over: it packs, or goes on to the next leg.
			var moved: String = _relocation.on_walk_done(world, npcs, npc, state) if _relocation != null else NpcActionExecutor.FAIL_UNSUPPORTED
			if moved != NpcRelocation.STEP_CONTINUES:
				_fail(world, npcs, npc, state, moved)
		_:
			_finish(world, npcs, npc, state, {})


## `night`: the night sleep (activity sleeping, slower recovery), else a nap.
func _start_resting(world: ServerWorld, npc: NpcState, state: NpcBehaviourState, night: bool) -> void:
	state.step = NpcBehaviourState.STEP_PERFORMING
	state.timer_usec = NpcBehaviourSettings.to_usec(_settings.rest_check_period_sec)
	_set_activity(world, npc, NpcNeedKind.SLEEPING if night else NpcNeedKind.RESTING)


## The unit of food the NPC carries is used up and lowers its needs.
func _finish_eating(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> void:
	var stack: ItemInstance = _food_stack(world, state.inventory_id)
	var food: ItemDefinition = world.inventory.definition_of(stack.item_instance_id) if stack != null else null
	if food == null or not world.inventory.remove_item(state.inventory_id, stack.item_instance_id, 1).ok:
		_fail(world, npcs, npc, state, NpcActionExecutor.FAIL_NO_RESOURCE)
		return
	var needs: NpcNeeds = _advanced_needs(world, npc)
	var info: Dictionary = {INFO_ITEM: food.definition_id}
	if needs != null:
		needs.satisfy(NpcNeedKind.HUNGER, food.consume_hunger_reduction, "eat_%s" % food.definition_id)
		if food.consume_thirst_reduction > 0.0:
			needs.satisfy(NpcNeedKind.THIRST, food.consume_thirst_reduction, "eat_%s" % food.definition_id)
		info[NpcNeedKind.HUNGER] = needs.value(NpcNeedKind.HUNGER)
	_finish(world, npcs, npc, state, info)


# ------------------------------------------------------------ ending

## The action is complete: counted, reported, announced.
func _finish(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, info: Dictionary) -> void:
	var action_id: String = state.action_id
	state.add_count(action_id)
	_end(world, npcs, npc, state)
	finished_count += 1
	_report(npc.npc_id, NpcActionExecutor.REPORT_DONE)
	behaviour_finished.emit(npc.npc_id, action_id, info)


func _fail(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, code: String) -> void:
	var action_id: String = state.action_id
	state.add_count(NpcBehaviourState.COUNT_FAILED)
	if action_id == ACTION_SCAVENGE and _scavenging != null:
		_scavenging.on_failed(world, npc, code)
	_end(world, npcs, npc, state)
	failed_count += 1
	_report(npc.npc_id, NpcActionExecutor.failed_reason(code))
	behaviour_failed.emit(npc.npc_id, action_id, code)


## Whatever ends the action: the NPC is busy with nothing for the need
## model, and this stage forgets the action.
func _end(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> void:
	if state.step == NpcBehaviourState.STEP_PERFORMING and (state.action_id == ACTION_REST or state.action_id == ACTION_SLEEP or state.action_id == ACTION_WORK):
		_set_activity(world, npc, NpcNeedKind.IDLE)
	state.clear_action()
	if _running.erase(npc.npc_id):
		_order_stale = true
	npcs.mark_npc_dirty(npc.npc_id)


# ------------------------------------------------------------ food

## Gives the container of a food spot its stock, once per world.
func _stock(world: ServerWorld, npcs: NpcService, spot_id: String) -> void:
	var spot: NpcSpotDefinition = _executor.spot_definition(spot_id)
	if spot == null or spot.stock_units <= 0 or _stocked.has(spot_id):
		return
	var container: ContainerInstance = _container_at(world, spot_id)
	var item: ItemDefinition = _items.get_definition(spot.stock_item_id) if _items != null else null
	if container == null:
		return
	_stocked[spot_id] = true
	if item == null:
		GameLogger.error("npc", "a food spot names a stock item that does not exist", {"spot_id": spot_id, "definition_id": spot.stock_item_id, "operation": "stock"})
		return
	var left: int = spot.stock_units
	while left > 0:
		var units: int = mini(left, item.max_stack)
		if world.inventory.spawn_detached_item(container.inventory_id, item.definition_id, units).is_empty():
			break
		left -= units
	stocked_count += 1
	npcs.mark_cell_save_dirty(container.cell_id)
	GameLogger.info("npc", "a food container was stocked", {"spot_id": spot_id, "entity_id": container.container_id, "definition_id": item.definition_id, "units": spot.stock_units - left, "operation": "stock"})


## Moves one unit of food from the spot's container into the NPC's
## inventory. False when there is no container, no food, or no room.
func _take_food(world: ServerWorld, npcs: NpcService, state: NpcBehaviourState) -> bool:
	var container: ContainerInstance = _container_at(world, state.spot_id)
	var stack: ItemInstance = _food_stack(world, container.inventory_id) if container != null else null
	if stack == null or not world.inventory.transfer_item(container.inventory_id, stack.item_instance_id, state.inventory_id, 1).ok:
		return false
	npcs.mark_cell_save_dirty(container.cell_id)
	return true


## The first stack of food (an item whose consume effect lowers hunger) in
## an inventory, by slot; null when there is none.
func _food_stack(world: ServerWorld, inventory_id: String) -> ItemInstance:
	if inventory_id.is_empty() or not world.inventory.has_inventory(inventory_id):
		return null
	var held: Array[ItemInstance] = world.inventory.items_in_inventory(inventory_id)
	held.sort_custom(func(a: ItemInstance, b: ItemInstance) -> bool: return InventoryService.slot_index_of(a.slot_id) < InventoryService.slot_index_of(b.slot_id))
	for item: ItemInstance in held:
		var definition: ItemDefinition = world.inventory.definition_of(item.item_instance_id)
		if definition != null and definition.consume_hunger_reduction > 0.0:
			return item
	return null


## The container that stands on the tile of a spot and is in memory (the
## smallest id when there are several), or null.
func _container_at(world: ServerWorld, spot_id: String) -> ContainerInstance:
	var containers: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
	var place: Variant = _executor.spot_position(spot_id)
	if containers == null or place == null:
		return null
	var tile: Vector2i = _grid.tile_of(place as Vector3)
	var ids: PackedStringArray = containers.container_ids_in_cell(world, world.cell_id_at(place as Vector3))
	ids.sort()
	for container_id: String in ids:
		var container: ContainerInstance = containers.get_container(container_id)
		if container != null and _grid.tile_of(container.position) == tile:
			return container
	return null


# ------------------------------------------------------------ helpers

func _world() -> ServerWorld:
	return _world_ref.get_ref() as ServerWorld if _world_ref != null else null


func _npcs() -> NpcService:
	return _npcs_ref.get_ref() as NpcService if _npcs_ref != null else null


func _state_of(npc: NpcState) -> NpcBehaviourState:
	return npc.component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState if npc != null else null


## The NPC's needs, brought up to now (null when it has none).
func _advanced_needs(world: ServerWorld, npc: NpcState) -> NpcNeeds:
	var needs: NpcNeeds = npc.component(NpcNeeds.COMPONENT_ID) as NpcNeeds
	if needs != null:
		needs.advance_to(maxf(world.clock.world_time_sec, needs.last_updated_world_time()))
	return needs


func _set_activity(world: ServerWorld, npc: NpcState, activity: String) -> void:
	var needs: NpcNeeds = npc.component(NpcNeeds.COMPONENT_ID) as NpcNeeds
	if needs != null:
		needs.set_activity(activity, maxf(world.clock.world_time_sec, needs.last_updated_world_time()))


func _report(npc_id: String, reason: String) -> void:
	_executor.tell_scheduler(npc_id, reason)


## The contract's failure code of a refusal of the movement executor.
static func _refusal_code(reason: String) -> String:
	match reason:
		NpcExecutor.REASON_SPOT_RESERVED:
			return NpcActionExecutor.FAIL_RESERVED
		NpcExecutor.REASON_UNKNOWN_SPOT, NpcExecutor.REASON_BAD_TARGET:
			return NpcActionExecutor.FAIL_TARGET_GONE
	return FAIL_NOT_READY


## The contract's failure code of a failure of the movement executor.
static func _failure_code(code: String) -> String:
	match code:
		NpcExecutor.FAIL_PATH_NOT_FOUND, NpcExecutor.FAIL_PATH_BLOCKED:
			return NpcActionExecutor.FAIL_NO_PATH
		NpcExecutor.FAIL_SPOT_RESERVED:
			return NpcActionExecutor.FAIL_RESERVED
	return NpcActionExecutor.FAIL_TARGET_GONE
