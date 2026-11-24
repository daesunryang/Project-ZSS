class_name NpcRelocation
extends RefCounted
## An NPC that lives alone moves to another shelter (F-30, docs/09 §17.15):
## WHEN it wants to (move_reason), WHERE to (NpcRelocationPicker) and what
## the action "relocate" does. A helper of NpcBehaviours, which owns the
## action's step and timer, walks the NPC (NpcExecutor.begin_move) and
## reports to the decision layer, like NpcScavenging.
##
## When (its own decision, survival first; never for its own sake):
##   attacked     somebody attacked it at home (NpcRelocationState.attacked;
##                F-32 sets it with note_attacked());
##   hurt         it is badly hurt and remembers a zombie's hit at its home;
##   danger       the danger it remembers at its home is over its limit
##                (zombies seen there again and again);
##   no_supplies  it has searched its home, its last scavenging trips found
##                no building left to search, and its food is getting low.
## The limits depend on its personality (NpcRelocationSettings). "danger"
## and "no_supplies" wait min_days_between_moves after it moved in (an NPC
## without any food does not wait). Its home's water never runs dry
## (docs/15 F28-006), so thirst alone moves nobody.
##
## The move, in phases (NpcRelocationState.phase):
##   choosing    It stands while the buildings of the cells within
##               max_distance_m of its home are listed (from the
##               generator's plans: no cell is loaded for it). A tick
##               lists at most scan_cells_per_tick cells that are not
##               listed yet, for all NPCs together, or lets ONE NPC whose
##               cells are all listed choose (NpcRelocationPicker); never
##               both. The chosen building is claimed
##               for it (NpcService.claim_home: no other NPC takes or
##               searches it from now on). No building: the move is over
##               ("no_destination"), it looks again after
##               retry_choice_after_world_sec.
##   packing     It walks to each container of its home that is in memory
##               and takes what it can carry, in this order: food, drinks,
##               treatments, a weapon better than the one it carries.
##   travelling  It walks to the home tile of the new building in legs of at
##               most leg_length_m (one bounded path search each). A leg
##               begins only when every cell it crosses is in memory and
##               completely built (otherwise the action fails with
##               not_ready and is tried again; an NPC whose own cell is not
##               simulated is frozen like any other). A leg that finds no
##               way is tried to the side; after max_leg_failures in a row
##               the destination is given up: it is remembered as blocked,
##               its claim is given back, and the NPC chooses again from
##               where it stands (its old home is then a choice too).
##   settling    On the home tile it stays settle_duration_sec; then the
##               building is its home (NpcHome, NpcService.settle_home: the
##               roster record follows, the old home is free), the
##               containers of the new home are searched (their loot is
##               rolled as a player's first search would roll it) and what
##               it carries and what belongs into a home is put into them.
## A move that is interrupted (a zombie, a need in danger, a restart, its
## cell leaving memory) is still in its component: the action begins again
## where the move stood. While it moves, nothing sends it back to the old
## home: it does not scavenge or wander, and it rests where it stands.
## An NPC that dies gives its claim back (on_npc_died); what it carried is
## where it died (NpcHealth).
##
## Determinism: nothing here draws a random number, and what is chosen
## does not depend on what was planned or cached before. How many ticks
## the choosing takes does (a server that was restarted lists the cells
## again).

## Emitted when an NPC decided to move (it begins to choose).
signal move_started(npc_id: String, reason: String)
## Emitted when a destination was chosen and claimed.
signal destination_chosen(npc_id: String, building_id: String)
## Emitted when a destination was given up (`why`: no_path, too_long,
## taken, died).
signal move_abandoned(npc_id: String, building_id: String, why: String)
## Emitted when an NPC lives in another building now.
signal npc_relocated(npc_id: String, from_building_id: String, to_building_id: String, reason: String)

## begin() refused: the NPC has no reason to move.
const FAIL_NO_REASON: String = "no_reason"
## The move is over without a destination.
const FAIL_NO_DESTINATION: String = "no_destination"
## A leg cannot begin yet (a cell on its way is not in memory or not built).
const FAIL_NOT_READY: String = "not_ready"
## What a step tells NpcBehaviours.
const STEP_CONTINUES: String = ""
const STEP_DONE: String = "done"
## Why a destination was given up.
const WHY_NO_PATH: String = "no_path"
const WHY_TOO_LONG: String = "too_long"
const WHY_TAKEN: String = "taken"
const WHY_DIED: String = "died"
## Keys of the info of a finished move.
const INFO_FROM: String = "from_building_id"
const INFO_TO: String = "to_building_id"
const INFO_REASON: String = "reason"
const INFO_PACKED: String = "packed_units"
const INFO_STOWED: String = "stowed_units"
const TRAIT_RISK_TOLERANCE: String = "risk_tolerance"
const TRAIT_COURAGE: String = "courage"
const TRAIT_NEUROTICISM: String = "neuroticism"
## What it packs, in this order.
const PACK_ORDER: PackedStringArray = [NpcSurvivalSense.KIND_FOOD, NpcSurvivalSense.KIND_DRINK, NpcSurvivalSense.KIND_MEDICAL, NpcSurvivalSense.KIND_WEAPON]
## Degrees a leg is turned to the side after 0, 1, 2, ... legs in a row
## that found no way.
const DETOUR_DEGREES: PackedFloat32Array = [0.0, 35.0, -35.0, 70.0, -70.0, 110.0, -110.0]
## A leg to the side is this share of a straight one.
const DETOUR_LENGTH_SHARE: float = 0.6
## A timer that runs out in the next tick.
const NEXT_TICK_USEC: int = 1
## Homes whose list of cells within reach is kept.
const MAX_CACHED_REACHES: int = 64
## Cells an NPC that chooses passes per tick when they are listed already.
const MAX_SCAN_STEPS_PER_TICK: int = 64

## Diagnostics (tests / profiling).
var started_count: int = 0
var chosen_count: int = 0
var abandoned_count: int = 0
var relocated_count: int = 0
var leg_count: int = 0
var packed_unit_count: int = 0
var scanned_cell_count: int = 0
var last_choose_usec: int = 0
var max_choose_usec: int = 0
var max_scan_usec: int = 0
## The slowest packing of a container, beginning of a leg, and moving in.
var max_pack_usec: int = 0
var max_leg_usec: int = 0
var max_settle_usec: int = 0

var settings: NpcRelocationSettings

var _sense: NpcSurvivalSense
var _scavenging: NpcScavenging
var _homes: NpcHomes
var _grid: StructureGrid
var _picker: NpcRelocationPicker = NpcRelocationPicker.new()
var _world_ref: WeakRef = null
var _npcs_ref: WeakRef = null
## home building id -> the cells within max_distance_m of its middle.
var _reaches: Dictionary[String, Array] = {}
## True when an NPC chose its destination in this tick (see begin_tick).
var _chose_this_tick: bool = false
## Cells that may still be listed in this tick.
var _listings_left: int = 0
## Walks an NPC: (npc_id, state: NpcBehaviourState, goal: Vector3, run: bool)
## -> "" or a failure code (NpcBehaviours._move).
var _mover: Callable


func _init(relocation_settings: NpcRelocationSettings, sense: NpcSurvivalSense, scavenging: NpcScavenging, grid: StructureGrid, mover: Callable) -> void:
	settings = relocation_settings if relocation_settings != null else NpcRelocationSettings.new()
	_sense = sense
	_scavenging = scavenging
	_homes = sense.homes() if sense != null else null
	_grid = grid
	_mover = mover


## The world this helper reads when the decision layer asks whether an
## NPC wants to move, and when it is told about a death
## (ServerComposition, once).
func attach(world: ServerWorld, npcs: NpcService) -> void:
	_world_ref = weakref(world)
	_npcs_ref = weakref(npcs)


func picker() -> NpcRelocationPicker:
	return _picker


## A tick begins (NpcBehaviours.step, before the timers): it may list
## scan_cells_per_tick cells, or one NPC may choose its destination in it.
func begin_tick() -> void:
	_chose_this_tick = false
	_listings_left = settings.scan_cells_per_tick


# ------------------------------------------------------------ when

## True while the NPC is in the middle of a move.
func is_moving(npc: NpcState) -> bool:
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	return move != null and move.is_moving()


## True when the action "relocate" may be chosen for this NPC now: it is in
## the middle of a move, or it has a reason to move and has not just found
## that there is nowhere to go.
func wants_to_move(npc: NpcState) -> bool:
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	if world == null or move == null:
		return false
	if move.is_moving():
		return true
	if floori(world.clock.world_time_sec) < move.no_choice_until_world_sec:
		return false
	return not move_reason(world, npc).is_empty()


## Why the NPC wants to leave its home now (NpcRelocationState.REASON_*),
## or "" (see the header). The most pressing reason first.
func move_reason(world: ServerWorld, npc: NpcState) -> String:
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	var home: NpcHome = NpcHome.of(npc)
	var vitals: NpcVitals = NpcVitals.of(npc)
	if world == null or move == null or home == null or not home.is_generated() or _sense == null or (vitals != null and not vitals.is_alive()):
		return ""
	if move.attacked:
		return NpcRelocationState.REASON_ATTACKED
	var raw_center: Variant = _homes.building_center(home.building_id)
	if raw_center == null:
		return ""
	var home_center: Vector3 = raw_center
	var now: float = world.clock.world_time_sec
	if vitals != null and vitals.health <= vitals.max_health() * hurt_health_limit(npc) and _sense.remembers_hurt_near(npc, home_center, settings.hurt_at_home_radius_m, settings.hurt_memory_min_strength, now):
		return NpcRelocationState.REASON_HURT
	# It just moved in: it gives the new place a chance, unless it starves.
	var just_moved_in: bool = move.last_settled_day != NpcRelocationState.NEVER and _day(world) - move.last_settled_day < settings.min_days_between_moves
	if not just_moved_in and _sense.danger_at(npc, home_center, now) >= home_danger_limit(npc):
		return NpcRelocationState.REASON_DANGER
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	if trip != null and trip.no_target_streak >= settings.exhausted_tries and not trip.result_of(home.building_id).is_empty():
		var food: int = int(_sense.supplies(world, NpcSurvivalSense.inventory_of(npc))[NpcSurvivalSense.SUPPLY_FOOD]) + int(_sense.home_supplies(world, npc)[NpcSurvivalSense.SUPPLY_FOOD])
		if food <= food_floor(npc) and (not just_moved_in or food == 0):
			return NpcRelocationState.REASON_NO_SUPPLIES
	return ""


## The danger at its home at which this NPC leaves: the setting, doubled
## for an NPC that is daring, brave and calm, halved for the opposite.
func home_danger_limit(npc: NpcState) -> float:
	var lean: float = (_sense.trait_of(npc, TRAIT_RISK_TOLERANCE) - 0.5) + (_sense.trait_of(npc, TRAIT_COURAGE) - 0.5) - (_sense.trait_of(npc, TRAIT_NEUROTICISM) - 0.5)
	return settings.home_danger_threshold * pow(2.0, clampf(lean, -1.0, 1.0))


## The share of its health at or below which this NPC, hurt at home,
## leaves: the setting x (1.5 - courage).
func hurt_health_limit(npc: NpcState) -> float:
	return clampf(settings.hurt_health_fraction * (1.5 - _sense.trait_of(npc, TRAIT_COURAGE)), 0.0, 1.0)


## Units of food at or below which this NPC, with nothing left to search,
## leaves: the setting x (1.5 - risk tolerance), always below what it wants
## to have.
func food_floor(npc: NpcState) -> int:
	return clampi(roundi(float(settings.move_when_food_at_most) * (1.5 - _sense.trait_of(npc, TRAIT_RISK_TOLERANCE))), 0, maxi(_sense.food_target(npc) - 1, 0))


## F-32's hook: somebody attacked the NPC at its home. It moves away as
## soon as it can (the reason "attacked"). True when it was written down.
func note_attacked(npcs: NpcService, npc: NpcState) -> bool:
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	var home: NpcHome = NpcHome.of(npc)
	if move == null or home == null or not home.is_generated():
		return false
	if not move.attacked:
		move.attacked = true
		move.no_choice_until_world_sec = 0
		if npcs != null:
			npcs.mark_npc_dirty(npc.npc_id)
	return true


# ------------------------------------------------------------ the action

## Starts the action, or goes on with the move the NPC is in the middle of.
## "" when it runs, or a failure code.
func begin(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> String:
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	var home: NpcHome = NpcHome.of(npc)
	if move == null or home == null or not home.is_generated() or _scavenging == null:
		return NpcActionExecutor.FAIL_UNSUPPORTED
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	if trip != null:
		trip.clear_trip()
	if not move.is_moving():
		var reason: String = move_reason(world, npc)
		if reason.is_empty():
			return FAIL_NO_REASON
		move.begin(reason, _day(world))
		started_count += 1
		GameLogger.info("npc", "an NPC decided to move to another shelter", {"entity_id": npc.npc_id, "building_id": home.building_id, "reason": reason, "operation": "relocate"})
		move_started.emit(npc.npc_id, reason)
	elif move.phase != NpcRelocationState.PHASE_SETTLING and move.phase != NpcRelocationState.PHASE_CHOOSING and _day(world) - move.started_day > settings.give_up_days:
		_give_up(world, npcs, npc, move, WHY_TOO_LONG)
	npcs.mark_npc_dirty(npc.npc_id)
	match move.phase:
		NpcRelocationState.PHASE_PACKING:
			return _go_to_pack(world, npc, state, move, home, maxi(move.container_index, 0))
		NpcRelocationState.PHASE_SETTLING:
			if _grid.tile_of(npc.position) != move.target_tile:
				move.phase = NpcRelocationState.PHASE_TRAVELLING
				_wait(state, NEXT_TICK_USEC)
			else:
				_wait(state, NpcBehaviourSettings.to_usec(settings.settle_duration_sec))
			return ""
	# Choosing and travelling go on in the next tick (on_timer).
	_wait(state, NEXT_TICK_USEC)
	return ""


## A walk of the move is over. STEP_CONTINUES, or a failure code.
func on_walk_done(_world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> String:
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	if move == null or not move.is_moving():
		return NpcActionExecutor.FAIL_TARGET_GONE
	npcs.mark_npc_dirty(npc.npc_id)
	match move.phase:
		NpcRelocationState.PHASE_PACKING:
			_wait(state, NpcBehaviourSettings.to_usec(settings.pack_duration_sec))
			return STEP_CONTINUES
		NpcRelocationState.PHASE_TRAVELLING:
			move.leg_failures = 0
			_wait(state, NEXT_TICK_USEC)
			return STEP_CONTINUES
	return NpcActionExecutor.FAIL_TARGET_GONE


## A walk of the move failed with `code`. STEP_CONTINUES when the move
## goes on all the same (another leg, another destination), or the code the
## action fails with.
func on_walk_failed(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, code: String) -> String:
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	if move == null or not move.is_moving() or code != NpcActionExecutor.FAIL_NO_PATH:
		return code
	npcs.mark_npc_dirty(npc.npc_id)
	if move.phase == NpcRelocationState.PHASE_PACKING:
		# A container of its own home it finds no way to: it goes without.
		move.packed = true
		move.container_index = NpcRelocationState.NO_CONTAINER
		move.phase = NpcRelocationState.PHASE_TRAVELLING
		_wait(state, NEXT_TICK_USEC)
		return STEP_CONTINUES
	if move.phase != NpcRelocationState.PHASE_TRAVELLING:
		return code
	move.leg_failures += 1
	if move.leg_failures >= settings.max_leg_failures:
		_give_up(world, npcs, npc, move, WHY_NO_PATH)
		_wait(state, NEXT_TICK_USEC)
		return STEP_CONTINUES
	_wait(state, maxi(NpcBehaviourSettings.to_usec(settings.leg_retry_pause_sec), NEXT_TICK_USEC))
	return STEP_CONTINUES


## The timer of the move ran out. STEP_CONTINUES, STEP_DONE (the NPC lives
## in the new home: `info` is filled in), or a failure code.
func on_timer(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, info: Dictionary) -> String:
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	var home: NpcHome = NpcHome.of(npc)
	if move == null or home == null or not move.is_moving():
		return NpcActionExecutor.FAIL_TARGET_GONE
	npcs.mark_npc_dirty(npc.npc_id)
	match move.phase:
		NpcRelocationState.PHASE_CHOOSING:
			return _step_choosing(world, npcs, npc, state, move, home)
		NpcRelocationState.PHASE_PACKING:
			var pack_started_usec: int = Time.get_ticks_usec()
			_pack(world, npcs, npc, state, move, home)
			var packed_code: String = _go_to_pack(world, npc, state, move, home, move.container_index + 1)
			max_pack_usec = maxi(max_pack_usec, Time.get_ticks_usec() - pack_started_usec)
			return packed_code
		NpcRelocationState.PHASE_TRAVELLING:
			var leg_started_usec: int = Time.get_ticks_usec()
			var leg_code: String = _begin_leg(world, npc, state, move)
			max_leg_usec = maxi(max_leg_usec, Time.get_ticks_usec() - leg_started_usec)
			return leg_code
		NpcRelocationState.PHASE_SETTLING:
			var settle_started_usec: int = Time.get_ticks_usec()
			_settle(world, npcs, npc, state, move, home, info)
			max_settle_usec = maxi(max_settle_usec, Time.get_ticks_usec() - settle_started_usec)
			return STEP_DONE
	return NpcActionExecutor.FAIL_TARGET_GONE


## The NPC woke (its cell is simulated again, or the server started): what
## the world knows about its home and its move is brought in line with what
## the NPC knows (they are saved in different documents).
func on_npc_woke(world: ServerWorld, npcs: NpcService, npc: NpcState) -> void:
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	var home: NpcHome = NpcHome.of(npc)
	if move == null or home == null or not home.is_generated() or npcs == null:
		return
	if npcs.home_claim_holder(home.building_id) == npc.npc_id or not npcs.is_seeded_home(home.building_id):
		# (An NPC of a roster whose record names another building; an NPC of
		# no roster, whose claim is what keeps its home taken.)
		npcs.settle_home(npc.npc_id, home.building_id)
	if not move.is_moving() or not move.has_target() or move.target_building_id == home.building_id:
		npcs.release_home_claims(npc.npc_id, home.building_id if npcs.home_claim_holder(home.building_id) == npc.npc_id else "")
		return
	if not npcs.claim_home(npc.npc_id, move.target_building_id):
		# Somebody else has it by now: it chooses again from where it stands.
		_abandon_target(world, npcs, npc, move, WHY_TAKEN, false)


## The NPC died (NpcHealth.npc_died): its move is over, the building it
## was moving to is free.
func on_npc_died(npc_id: String, _cause: String, _killer_id: String) -> void:
	var npcs: NpcService = _npcs_ref.get_ref() as NpcService if _npcs_ref != null else null
	var npc: NpcState = npcs.get_npc(npc_id) if npcs != null else null
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	if move == null or not move.is_moving():
		return
	var target: String = move.target_building_id
	npcs.release_home_claim(npc_id, target)
	move.clear_move()
	npcs.mark_npc_dirty(npc_id)
	abandoned_count += 1
	move_abandoned.emit(npc_id, target, WHY_DIED)


# ------------------------------------------------------------ choosing

## One tick of choosing: lists the next cells, or chooses.
func _step_choosing(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, move: NpcRelocationState, home: NpcHome) -> String:
	var generator: ProceduralMapGenerator = _homes.generator()
	var raw_center: Variant = _homes.building_center(home.building_id)
	if generator == null or raw_center == null:
		move.clear_move()
		return NpcActionExecutor.FAIL_UNSUPPORTED
	var cells: Array[Vector2i] = _cells_in_reach(world, home.building_id, raw_center as Vector3)
	var steps: int = 0
	while move.scan_index < cells.size() and steps < MAX_SCAN_STEPS_PER_TICK:
		if not _scavenging.is_listed(cells[move.scan_index], true):
			if _listings_left <= 0 or _chose_this_tick:
				break
			# (Whether an NPC can live in a building is worked out here too, so
			# the choice at the end only compares.)
			var started_usec: int = Time.get_ticks_usec()
			_scavenging.buildings_of(generator, cells[move.scan_index], true)
			_listings_left -= 1
			scanned_cell_count += 1
			max_scan_usec = maxi(max_scan_usec, Time.get_ticks_usec() - started_usec)
		move.scan_index += 1
		steps += 1
	if move.scan_index < cells.size():
		_wait(state, NEXT_TICK_USEC)
		return STEP_CONTINUES
	if _chose_this_tick or _listings_left < settings.scan_cells_per_tick:
		# This tick listed a cell, or another NPC chose in it: this one
		# chooses in a later tick (the NPCs are stepped in the order of their
		# ids).
		_wait(state, NEXT_TICK_USEC)
		return STEP_CONTINUES
	# Every cell was passed. One that is not listed any more (the lists
	# were dropped: a restart, a full cache) is listed again first.
	for index: int in range(cells.size()):
		if not _scavenging.is_listed(cells[index], true):
			move.scan_index = index
			_wait(state, NEXT_TICK_USEC)
			return STEP_CONTINUES
	_chose_this_tick = true
	var without: Dictionary = {}
	while true:
		var building_id: String = choose_destination(world, npcs, npc, without)
		if building_id.is_empty():
			var reason: String = move.reason
			move.clear_move()
			move.no_choice_until_world_sec = floori(world.clock.world_time_sec + settings.retry_choice_after_world_sec)
			GameLogger.info("npc", "an NPC that wants to move found no building to move to", {"entity_id": npc.npc_id, "building_id": home.building_id, "reason": reason, "operation": "relocate"})
			return FAIL_NO_DESTINATION
		var layout: NpcHomeLayout = _homes.layout_of(building_id)
		if layout == null or (building_id != home.building_id and not npcs.claim_home(npc.npc_id, building_id)):
			without[building_id] = true
			continue
		move.target_building_id = building_id
		move.target_tile = layout.home_tile()
		move.scan_index = 0
		move.leg_failures = 0
		chosen_count += 1
		GameLogger.info("npc", "an NPC chose the building it moves to", {"entity_id": npc.npc_id, "building_id": building_id, "from_building_id": home.building_id, "reason": move.reason, "cost_m": _picker.last_cost_m, "candidates": _picker.last_candidate_count, "operation": "relocate"})
		destination_chosen.emit(npc.npc_id, building_id)
		break
	if move.packed or move.target_building_id == home.building_id:
		move.phase = NpcRelocationState.PHASE_TRAVELLING
		_wait(state, NEXT_TICK_USEC)
		return STEP_CONTINUES
	move.phase = NpcRelocationState.PHASE_PACKING
	return _go_to_pack(world, npc, state, move, home, 0)


## The building the NPC would move to now ("" = none; see
## NpcRelocationPicker). Buildings in `without` are not looked at. Lists
## whatever cells were not listed yet.
func choose_destination(world: ServerWorld, npcs: NpcService, npc: NpcState, without: Dictionary = {}) -> String:
	var started_usec: int = Time.get_ticks_usec()
	var move: NpcRelocationState = NpcRelocationState.of(npc)
	var home: NpcHome = NpcHome.of(npc)
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	var generator: ProceduralMapGenerator = _homes.generator() if _homes != null else null
	var raw_center: Variant = _homes.building_center(home.building_id) if home != null and home.is_generated() else null
	if world == null or npcs == null or move == null or generator == null or raw_center == null:
		return ""
	var scavenge: NpcScavengeSettings = _sense.settings
	var now: float = world.clock.world_time_sec
	var day: int = _day(world)
	var query: NpcRelocationPicker.Query = NpcRelocationPicker.Query.new()
	query.anchor = raw_center
	query.origin = npc.position if move.from_here else query.anchor
	query.min_distance_m = settings.min_distance_m if move.reason == NpcRelocationState.REASON_NO_SUPPLIES else settings.danger_min_distance_m
	query.max_distance_m = settings.max_distance_m
	query.home_building_id = home.building_id
	query.allow_return = move.from_here and not without.has(home.building_id)
	query.taken = npcs.taken_home_ids()
	query.skip = without.duplicate()
	if trip != null:
		for entry: Dictionary in trip.visited:
			var result: String = str(entry[NpcScavengeState.KEY_RESULT])
			if result == NpcScavengeState.RESULT_EMPTY or (result == NpcScavengeState.RESULT_BLOCKED and day - int(entry[NpcScavengeState.KEY_DAY]) < scavenge.blocked_forget_days):
				query.skip[str(entry[NpcScavengeState.KEY_BUILDING_ID])] = true
	query.danger_sources = _sense.danger_sources(npc, now)
	query.danger_radius_m = scavenge.danger_radius_m
	query.danger_limit = _sense.danger_limit(npc)
	query.danger_cost_m = scavenge.danger_cost_m
	query.house_types = _homes.settings.home_building_types
	query.other_type_cost_m = settings.other_type_cost_m
	query.prospect_bonus_m = settings.prospect_bonus_m
	query.prospect_cap = settings.prospect_cap
	var cells: Array[Vector2i] = _cells_in_reach(world, home.building_id, query.anchor)
	var chosen: String = _picker.choose(cells, func(cell: Vector2i) -> Array: return _scavenging.buildings_of(generator, cell, true), Callable(self, "_is_livable"), query)
	last_choose_usec = Time.get_ticks_usec() - started_usec
	max_choose_usec = maxi(max_choose_usec, last_choose_usec)
	return chosen


## The cells a building within max_distance_m of the middle of a home can
## stand in (kept per home: an NPC that chooses asks every tick).
func _cells_in_reach(world: ServerWorld, home_building_id: String, home_center: Vector3) -> Array[Vector2i]:
	if _reaches.has(home_building_id):
		return _reaches[home_building_id]
	var cells: Array[Vector2i] = _scavenging.cells_around(world, home_center, settings.max_distance_m)
	if _reaches.size() >= MAX_CACHED_REACHES:
		_reaches.clear()
	_reaches[home_building_id] = cells
	return cells


## True when an NPC can live in the building of a cell list's entry (the
## list says so: NpcScavenging.buildings_of with `with_livable`).
func _is_livable(entry: Dictionary) -> bool:
	return bool(entry.get(NpcScavenging.KEY_LIVABLE, false))


## The destination is given up: remembered as blocked, its claim given
## back, and the NPC chooses again from where it stands.
func _give_up(world: ServerWorld, npcs: NpcService, npc: NpcState, move: NpcRelocationState, why: String) -> void:
	_abandon_target(world, npcs, npc, move, why, true)


func _abandon_target(world: ServerWorld, npcs: NpcService, npc: NpcState, move: NpcRelocationState, why: String, remember_blocked: bool) -> void:
	var target: String = move.target_building_id
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	var home: NpcHome = NpcHome.of(npc)
	if remember_blocked and trip != null and not target.is_empty() and (home == null or target != home.building_id):
		trip.note_visit(target, NpcScavengeState.RESULT_BLOCKED, _day(world), _sense.settings.max_visited)
	npcs.release_home_claim(npc.npc_id, target)
	move.choose_again(_day(world))
	npcs.mark_npc_dirty(npc.npc_id)
	abandoned_count += 1
	GameLogger.info("npc", "an NPC gave up the building it was moving to", {"entity_id": npc.npc_id, "building_id": target, "reason": why, "operation": "relocate"})
	move_abandoned.emit(npc.npc_id, target, why)


# ------------------------------------------------------------ packing

## Walks the NPC to the first container of its home, from `from_index` on,
## that is in memory; when none is left the packing is over and it sets
## off. STEP_CONTINUES, or the walk's failure code.
func _go_to_pack(world: ServerWorld, npc: NpcState, state: NpcBehaviourState, move: NpcRelocationState, home: NpcHome, from_index: int) -> String:
	var containers: Array[ContainerInstance] = _sense.containers_of(world, home.building_id)
	for index: int in range(maxi(from_index, 0), containers.size()):
		var place: Variant = _homes.container_position(home.building_id, index)
		if containers[index] == null or place == null:
			continue
		move.phase = NpcRelocationState.PHASE_PACKING
		move.container_index = index
		if _grid.tile_of(place as Vector3) == _grid.tile_of(npc.position):
			_wait(state, NpcBehaviourSettings.to_usec(settings.pack_duration_sec))
			return STEP_CONTINUES
		var code: String = _mover.call(npc.npc_id, state, place as Vector3, false)
		if code.is_empty():
			return STEP_CONTINUES
		if code != NpcActionExecutor.FAIL_NO_PATH and code != NpcActionExecutor.FAIL_TARGET_GONE:
			return code
	move.packed = true
	move.container_index = NpcRelocationState.NO_CONTAINER
	move.phase = NpcRelocationState.PHASE_TRAVELLING
	_wait(state, NEXT_TICK_USEC)
	return STEP_CONTINUES


## Takes what the NPC can use and carry out of the container it stands at.
func _pack(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, move: NpcRelocationState, home: NpcHome) -> void:
	var containers: Array[ContainerInstance] = _sense.containers_of(world, home.building_id)
	var container: ContainerInstance = containers[move.container_index] if move.container_index >= 0 and move.container_index < containers.size() else null
	if container == null:
		return
	var taken: int = 0
	for kind: String in PACK_ORDER:
		for item: ItemInstance in NpcSurvivalSense.items_of(world, container.inventory_id):
			var definition: ItemDefinition = world.inventory.definition_of(item.item_instance_id)
			if _sense.kind_of(definition) != kind:
				continue
			if kind == NpcSurvivalSense.KIND_WEAPON and not _scavenging.takes_weapon(world, state, container, definition):
				continue
			taken += _scavenging.carry_units(world, container.inventory_id, item, state.inventory_id, state.capacity())
	if taken > 0:
		move.packed_units += taken
		packed_unit_count += taken
		npcs.mark_cell_save_dirty(container.cell_id)
	GameLogger.debug("npc", "an NPC packed for its move", {"entity_id": npc.npc_id, "container_id": container.container_id, "building_id": home.building_id, "taken_units": taken, "operation": "relocate"})


# ------------------------------------------------------------ travelling

## Begins the next leg of the way, or starts to settle when the NPC stands
## on the home tile of its destination.
func _begin_leg(world: ServerWorld, npc: NpcState, state: NpcBehaviourState, move: NpcRelocationState) -> String:
	var destination: Vector3 = _grid.tile_center(move.target_tile)
	if _grid.tile_of(npc.position) == move.target_tile:
		move.phase = NpcRelocationState.PHASE_SETTLING
		move.leg_failures = 0
		_wait(state, maxi(NpcBehaviourSettings.to_usec(settings.settle_duration_sec), NEXT_TICK_USEC))
		return STEP_CONTINUES
	var goal: Vector3 = leg_goal(world, npc.position, destination, move.leg_failures)
	if not _is_way_ready(world, npc.position, goal):
		return FAIL_NOT_READY
	var code: String = _mover.call(npc.npc_id, state, goal, false)
	if code.is_empty():
		leg_count += 1
	return code


## Where the next leg from `from` towards `destination` ends: the
## destination itself when it is within leg_length_m and no leg failed,
## otherwise the middle of the tile leg_length_m along the straight line,
## turned to the side by DETOUR_DEGREES[failures] after legs that found no
## way (and shorter then).
func leg_goal(world: ServerWorld, from: Vector3, destination: Vector3, failures: int) -> Vector3:
	var to: Vector3 = Vector3(destination.x - from.x, 0.0, destination.z - from.z)
	var distance: float = to.length()
	if failures <= 0 and distance <= settings.leg_length_m:
		return destination
	var length: float = minf(settings.leg_length_m, distance)
	var direction: Vector3 = to / distance if distance > 0.0 else Vector3.FORWARD
	if failures > 0:
		length = maxf(length * DETOUR_LENGTH_SHARE, _grid.module_m)
		direction = direction.rotated(Vector3.UP, deg_to_rad(DETOUR_DEGREES[failures % DETOUR_DEGREES.size()]))
	var point: Vector3 = world.clamp_to_world(Vector3(from.x + direction.x * length, from.y, from.z + direction.z * length))
	var center: Vector3 = _grid.tile_center(_grid.tile_of(point))
	return world.clamp_to_world(Vector3(center.x, from.y, center.z))


## True when every cell the straight line of a leg crosses is in memory
## and completely built: an NPC never walks where walls are still to come.
func _is_way_ready(world: ServerWorld, from: Vector3, to: Vector3) -> bool:
	var map: ProceduralMapService = world.get_system(ProceduralMapService.SYSTEM_ID) as ProceduralMapService
	var steps: int = maxi(ceili(Vector2(to.x - from.x, to.z - from.z).length() / (world.cell_grid.cell_size_m * 0.25)), 1)
	var last: String = ""
	for index: int in range(steps + 1):
		var cell_id: String = world.cell_id_at(from.lerp(to, float(index) / float(steps)))
		if cell_id == last:
			continue
		last = cell_id
		if not world.is_cell_loaded(cell_id) or (map != null and not map.is_cell_complete(cell_id)):
			return false
	return true


# ------------------------------------------------------------ settling

## The NPC lives in the building it moved to from now on.
func _settle(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, move: NpcRelocationState, home: NpcHome, info: Dictionary) -> void:
	var from_id: String = home.building_id
	var to_id: String = move.target_building_id
	var reason: String = move.reason
	var moved: bool = to_id != from_id
	if moved:
		home.set_generated(to_id, move.target_tile)
		npcs.settle_home(npc.npc_id, to_id)
		var service: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
		for container: ContainerInstance in _sense.containers_of(world, to_id):
			if container != null and service != null:
				service.search_now(world, container.container_id)
	var stowed: int = _scavenging.stow_at_home(world, npcs, npc, state, home)
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	if trip != null:
		trip.no_target_streak = 0
	info[INFO_FROM] = from_id
	info[INFO_TO] = to_id
	info[INFO_REASON] = reason
	info[INFO_PACKED] = move.packed_units
	info[INFO_STOWED] = stowed
	move.clear_move()
	if not moved:
		# Back in the home it wanted to leave (it found no other building it
		# could get to): it does not set off again at once.
		move.no_choice_until_world_sec = floori(world.clock.world_time_sec + settings.retry_choice_after_world_sec)
	if moved:
		move.attacked = false
		move.last_settled_day = _day(world)
		move.moves += 1
		relocated_count += 1
		_scavenging.queue_cells_of(world, npc)
		GameLogger.info("npc", "an NPC moved into another shelter", {"entity_id": npc.npc_id, "building_id": to_id, "from_building_id": from_id, "reason": reason, "stowed_units": stowed, "operation": "relocate"})
		npc_relocated.emit(npc.npc_id, from_id, to_id, reason)
	npcs.mark_npc_dirty(npc.npc_id)


# ------------------------------------------------------------ helpers

## The NPC stands and the action's timer runs.
static func _wait(state: NpcBehaviourState, usec: int) -> void:
	state.step = NpcBehaviourState.STEP_PERFORMING
	state.timer_usec = maxi(usec, NEXT_TICK_USEC)


func _day(world: ServerWorld) -> int:
	return maxi(floori(world.clock.world_time_sec / _sense.settings.day_length_world_sec), 0)
