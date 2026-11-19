class_name NpcScheduler
extends NpcStage
## WHEN every NPC thinks (P4-3, docs/09 §17.3, docs/13 §16.4, AGENTS.md §6).
## One NpcStage, stage id "scheduler". It never runs the AI of every NPC
## every tick: it gives each awake NPC a turn once per period of its tier,
## runs the interrupts that must not wait for that turn, and calls the
## decider (NpcDecider) for the NPCs whose turn it is, at most
## `max_decisions_per_tick` per tick. WHAT an NPC decides is the decider's
## business (P4-4); without one this stage decides nothing. Moving the NPCs
## (P4-5a) and sending them to the clients (P4-7) are other stages and
## modules with their own cadence.
##
## The schedule clock. All times here are whole microseconds of this stage's
## own clock, which advances by the action delta of every tick (rounded to
## a microsecond) while the world runs. It is saved exactly (an integer),
## and every NPC's next times are saved with the NPC (NpcScheduleComponent),
## so a run that is saved, restarted and restored makes the same decisions
## in the same ticks as a run that goes on (docs/13 §16.3 D11). The clock
## starts with the first NPC that is ever scheduled: a world without NPCs
## saves nothing of this stage.
##
## Buckets. A period is cut into `decision_bucket_count` slots. An NPC's
## bucket is its id number modulo the bucket count (stateless: nothing to
## save, the same in every run), and its periodic turns are at
##     k * period + bucket * (period / bucket_count)      (clock time)
## for the period of its tier ("near": the nearest online player is within
## `near_radius_m`; "far": the other awake NPCs). A turn that was missed (a
## long tick, a sleeping cell) is made up once, not once per missed period.
## core/BucketScheduler is NOT used: its phase is a private float sum that
## can neither be saved nor restored through its API, and D11 needs exactly
## that. The grid above gives the same spread.
##
## Interrupts. request_interrupt(npc_id, reason) asks for a decision in the
## next tick; schedule_interrupt(npc_id, reason, delay) asks for one when a
## time is up (the next category boundary of a need, the start of a shift).
## Both are saved with the NPC. In a tick, the NPCs with a due interrupt go
## first (who waits longest first), then the periodic turns (most overdue
## first), ties by id; an NPC decides at most once per tick, with every
## reason that is due. Interrupts count against the cap like periodic turns
## (docs/13 §16.4).
##
## Tiers. Every `tier_period_sec` (bucketed like the turns) an awake NPC's
## distance to the nearest online player is looked at again:
## NpcService.set_simulation_tier(near / far). NPCs of cells that are not
## simulated are frozen (docs/13 §16.3 D4): they have no turns and take no
## interrupts, and go on with the schedule they had when they wake.
##
## Cost: a tick in which nothing is due compares a few integers.

const STAGE_ID: String = "scheduler"
const SCHEMA_VERSION: int = 1
const KEY_SCHEMA_VERSION: String = "schema_version"
const KEY_CLOCK: String = "clock_usec"
const NO_TIME: int = NpcScheduleComponent.NO_TIME
## Longest delay of a timed interrupt (about 31 years).
const MAX_DELAY_SEC: float = 1.0e9
## Keys of diagnostics().
const DIAG_DECISIONS: String = "decisions"
const DIAG_INTERRUPTS: String = "interrupts"
const DIAG_DEFERRED: String = "deferred"
const DIAG_NEAR: String = "near"
const DIAG_FAR: String = "far"
const DIAG_STEP_USEC: String = "step_usec"
const DIAG_TOTAL_DECISIONS: String = "total_decisions"
const DIAG_TOTAL_INTERRUPTS: String = "total_interrupts"
const DIAG_PEAK_DECISIONS: String = "peak_decisions_per_tick"
## Keys of schedule_info().
const INFO_TIER: String = "tier"
const INFO_BUCKET: String = "bucket"
const INFO_NEXT_DECISION_IN_SEC: String = "next_decision_in_sec"
const INFO_INTERRUPTS: String = "interrupts"

## Diagnostics (tests / profiling / the debug overlay of P4-8). "last": of
## the latest tick. An "interrupt" is a decision with at least one reason
## other than the period. `last_deferred_count`: NPCs whose turn was due but
## did not fit the cap. `scan_count`: ticks in which the awake NPCs were
## looked through for due turns (the other ticks cost a few comparisons).
## `last_step_usec`: wall clock time of this stage's step, the decider
## included.
var last_decision_count: int = 0
var last_interrupt_count: int = 0
var last_deferred_count: int = 0
var total_decision_count: int = 0
var total_interrupt_count: int = 0
var peak_decisions_per_tick: int = 0
var near_count: int = 0
var far_count: int = 0
var scan_count: int = 0
var tier_check_count: int = 0
var refused_request_count: int = 0
var last_step_usec: int = 0

var _settings: NpcScheduleSettings
var _decider: NpcDecider = NpcDecider.new()
var _near_period_usec: int
var _far_period_usec: int
var _tier_slot_usec: int
var _bucket_count: int
var _near_radius_sq: float
var _far_radius_sq: float
## The schedule clock (see the header) and whether it runs yet.
var _now_usec: int = 0
var _started: bool = false
## Awake NPCs: npc_id -> its schedule.
var _awake: Dictionary[String, NpcScheduleComponent] = {}
## bucket -> ids of the awake NPCs in it (for the tier checks).
var _buckets: Array[PackedStringArray] = []
## Not later than the earliest time anything of an awake NPC is due. May be
## too early (then one tick looks and finds nothing), never too late.
var _earliest_usec: int = NO_TIME
var _npcs_ref: WeakRef = null
var _warned_missing_component: bool = false


func _init(settings: NpcScheduleSettings) -> void:
	_settings = settings
	_bucket_count = maxi(settings.decision_bucket_count, 1)
	_near_period_usec = maxi(NpcScheduleSettings.to_usec(settings.decision_near_period_sec), _bucket_count)
	_far_period_usec = maxi(NpcScheduleSettings.to_usec(settings.decision_far_period_sec), _near_period_usec)
	_tier_slot_usec = maxi(NpcScheduleSettings.to_usec(settings.tier_period_sec) / _bucket_count, 1)
	_near_radius_sq = settings.near_radius_m * settings.near_radius_m
	var far_radius: float = settings.near_radius_m + settings.near_exit_margin_m
	_far_radius_sq = far_radius * far_radius
	for index: int in range(_bucket_count):
		_buckets.append(PackedStringArray())


## Gives `npcs` the schedule component and a scheduler stage (the one line
## of ServerComposition). `decider` null = no decision. Returns the stage,
## or null when either registration fails.
static func install(npcs: NpcService, settings: NpcScheduleSettings, decider: NpcDecider = null) -> NpcScheduler:
	if npcs == null or settings == null:
		return null
	var scheduler: NpcScheduler = NpcScheduler.new(settings)
	scheduler.set_decider(decider)
	if npcs.register_component(NpcScheduleComponent.COMPONENT_ID, NpcScheduleComponent.make) != OK or npcs.add_stage(scheduler) != OK:
		return null
	scheduler._npcs_ref = weakref(npcs)
	return scheduler


func stage_id() -> String:
	return STAGE_ID


## Who is asked when an NPC's turn comes (P4-4). null = no decision.
func set_decider(decider: NpcDecider) -> void:
	_decider = decider if decider != null else NpcDecider.new()
	_decider.on_attached(self)


# ------------------------------------------------------------ interrupts

## Asks for a decision of `npc_id` in the next tick, with `reason`
## (snake_case) among its reasons. Asking again for a reason that already
## waits changes nothing. False (nothing happens): the NPC is not awake, the
## name is not a reason, or the NPC already waits for
## NpcScheduleComponent.MAX_INTERRUPTS other reasons.
func request_interrupt(npc_id: String, reason: String) -> bool:
	return _set_interrupt(npc_id, reason, _now_usec, true)


## Asks for a decision of `npc_id` once `delay_action_sec` (>= 0, real
## seconds) of the running world have passed. One timer per reason: asking
## again moves it. Refused like request_interrupt, and for a delay that is
## not a time.
func schedule_interrupt(npc_id: String, reason: String, delay_action_sec: float) -> bool:
	if not is_finite(delay_action_sec) or delay_action_sec < 0.0 or delay_action_sec > MAX_DELAY_SEC:
		return false
	return _set_interrupt(npc_id, reason, _now_usec + NpcScheduleSettings.to_usec(delay_action_sec), false)


## The same with a delay in calendar seconds (docs/09 §14.16), which is
## what needs and day times are counted in. The world clock's scale turns
## it into action time when this is called; a scale that changes later does
## not move the timer.
func schedule_interrupt_world(world: ServerWorld, npc_id: String, reason: String, delay_world_sec: float) -> bool:
	if world == null or world.clock.time_scale <= 0.0:
		return false
	return schedule_interrupt(npc_id, reason, delay_world_sec / world.clock.time_scale)


## Forgets an interrupt that still waits. False when there was none.
func cancel_interrupt(npc_id: String, reason: String) -> bool:
	var schedule: NpcScheduleComponent = _awake.get(npc_id, null)
	if schedule == null or not schedule.interrupts.erase(reason):
		return false
	_mark_dirty(npc_id)
	return true


# ------------------------------------------------------------ queries

## The schedule clock, microseconds.
func clock_usec() -> int:
	return _now_usec


## The bucket of an NPC id (0 .. decision_bucket_count - 1).
func bucket_of(npc_id: String) -> int:
	return npc_id.get_slice("_", 1).to_int() % _bucket_count


## The tier of an NPC as this stage sees it: near, far, or frozen (it is
## not awake).
func tier_of(npc_id: String) -> String:
	var schedule: NpcScheduleComponent = _awake.get(npc_id, null)
	return schedule.tier if schedule != null else NpcState.TIER_FROZEN


## Seconds until the next periodic turn of an awake NPC (0 = it is due);
## -1 for an NPC that is not awake.
func next_decision_in_sec(npc_id: String) -> float:
	var schedule: NpcScheduleComponent = _awake.get(npc_id, null)
	if schedule == null:
		return -1.0
	return float(maxi(schedule.next_decision_at_usec - _now_usec, 0)) / float(NpcScheduleSettings.USEC_PER_SEC)


## What the debug overlay shows of one awake NPC ({} = not awake): tier,
## bucket, seconds to the next periodic turn, and the interrupts that wait
## ({reason: seconds from now}).
func schedule_info(npc_id: String) -> Dictionary:
	var schedule: NpcScheduleComponent = _awake.get(npc_id, null)
	if schedule == null:
		return {}
	var waiting: Dictionary = {}
	for reason: String in schedule.interrupts:
		waiting[reason] = float(maxi(schedule.interrupts[reason] - _now_usec, 0)) / float(NpcScheduleSettings.USEC_PER_SEC)
	return {INFO_TIER: schedule.tier, INFO_BUCKET: bucket_of(npc_id), INFO_NEXT_DECISION_IN_SEC: next_decision_in_sec(npc_id), INFO_INTERRUPTS: waiting}


func diagnostics() -> Dictionary:
	return {
		DIAG_DECISIONS: last_decision_count,
		DIAG_INTERRUPTS: last_interrupt_count,
		DIAG_DEFERRED: last_deferred_count,
		DIAG_NEAR: near_count,
		DIAG_FAR: far_count,
		DIAG_STEP_USEC: last_step_usec,
		DIAG_TOTAL_DECISIONS: total_decision_count,
		DIAG_TOTAL_INTERRUPTS: total_interrupt_count,
		DIAG_PEAK_DECISIONS: peak_decisions_per_tick,
	}


# ------------------------------------------------------------ NpcStage

## The NPC's cell is simulated from now on. A schedule that is already
## there is taken up as it was saved (its tier too: the next tier check
## corrects it); an NPC that never had one gets its tier from where it
## stands and its first turn at its bucket's next slot.
func on_npc_woke(world: ServerWorld, npc: NpcState) -> void:
	var schedule: NpcScheduleComponent = npc.component(NpcScheduleComponent.COMPONENT_ID) as NpcScheduleComponent
	if schedule == null:
		if not _warned_missing_component:
			_warned_missing_component = true
			GameLogger.error("npc", "an NPC has no schedule component: it will never think", {"entity_id": npc.npc_id, "operation": "schedule"})
		return
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService
	_npcs_ref = weakref(npcs)
	_started = true
	_awake[npc.npc_id] = schedule
	_buckets[bucket_of(npc.npc_id)].append(npc.npc_id)
	if not schedule.is_scheduled():
		schedule.tier = _tier_at(world, npc.position, "")
		schedule.next_decision_at_usec = _next_turn_usec(schedule.tier, bucket_of(npc.npc_id), _now_usec)
		npcs.mark_npc_dirty(npc.npc_id)
	elif schedule.next_decision_at_usec > _now_usec + _period_usec(schedule.tier):
		# Never true for a schedule this clock made (a turn is at most one
		# period ahead): the save lost the clock, or the periods were
		# shortened. The NPC must not wait for a time that never comes.
		schedule.next_decision_at_usec = _next_turn_usec(schedule.tier, bucket_of(npc.npc_id), _now_usec)
		npcs.mark_npc_dirty(npc.npc_id)
	npcs.set_simulation_tier(npc.npc_id, schedule.tier)
	if schedule.tier == NpcState.TIER_NEAR:
		near_count += 1
	else:
		far_count += 1
	_earliest_usec = mini(_earliest_usec, schedule.earliest_usec())


## The NPC's cell is no longer simulated: its schedule stays as it is.
func on_npc_slept(_world: ServerWorld, npc: NpcState) -> void:
	var schedule: NpcScheduleComponent = _awake.get(npc.npc_id, null)
	if schedule == null:
		return
	_awake.erase(npc.npc_id)
	var bucket: int = bucket_of(npc.npc_id)
	var index: int = _buckets[bucket].find(npc.npc_id)
	if index >= 0:
		_buckets[bucket].remove_at(index)
	if schedule.tier == NpcState.TIER_NEAR:
		near_count -= 1
	else:
		far_count -= 1


func step(world: ServerWorld, npcs: NpcService, action_delta: float, _world_delta: float) -> void:
	last_decision_count = 0
	last_interrupt_count = 0
	last_deferred_count = 0
	last_step_usec = 0
	# A paused world (both deltas 0) and a world without NPCs: nothing runs,
	# not even the clock.
	if not _started or not is_finite(action_delta) or action_delta <= 0.0:
		return
	var previous_usec: int = _now_usec
	_now_usec += NpcScheduleSettings.to_usec(action_delta)
	if _awake.is_empty():
		return
	var started_usec: int = Time.get_ticks_usec()
	_check_tiers(world, npcs, previous_usec)
	if _earliest_usec <= _now_usec:
		_run_decisions(world, npcs)
	last_step_usec = Time.get_ticks_usec() - started_usec


func to_world_document() -> Dictionary:
	if not _started:
		return {}
	return {KEY_SCHEMA_VERSION: SCHEMA_VERSION, KEY_CLOCK: _now_usec}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get(KEY_SCHEMA_VERSION, null)) or int(document[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("npc scheduler: unsupported schema_version")
		return errors
	var clock: Variant = document.get(KEY_CLOCK, null)
	if not ItemInstance.is_integer_value(clock) or float(clock) < 0.0 or float(clock) > float(NO_TIME):
		errors.append("npc scheduler: clock_usec must be a whole number >= 0")
		return errors
	_now_usec = int(clock)
	_started = true
	return errors


# ------------------------------------------------------------ internals

## Puts an interrupt of an awake NPC at `at_usec`. `keep_earlier`: a reason
## that already waits for an earlier time stays there (asking twice).
func _set_interrupt(npc_id: String, reason: String, at_usec: int, keep_earlier: bool) -> bool:
	var schedule: NpcScheduleComponent = _awake.get(npc_id, null)
	if schedule == null or not NpcScheduleComponent.is_valid_reason(reason):
		return false
	if schedule.interrupts.has(reason):
		if keep_earlier and schedule.interrupts[reason] <= at_usec:
			return true
	elif schedule.interrupts.size() >= NpcScheduleComponent.MAX_INTERRUPTS:
		refused_request_count += 1
		GameLogger.warning("npc", "an NPC waits for too many interrupts; the new one is refused", {"entity_id": npc_id, "reason": reason, "operation": "interrupt"})
		return false
	schedule.interrupts[reason] = mini(at_usec, NO_TIME)
	_earliest_usec = mini(_earliest_usec, at_usec)
	_mark_dirty(npc_id)
	return true


func _mark_dirty(npc_id: String) -> void:
	var npcs: NpcService = _npcs_ref.get_ref() as NpcService if _npcs_ref != null else null
	if npcs != null:
		npcs.mark_npc_dirty(npc_id)


func _period_usec(tier: String) -> int:
	return _near_period_usec if tier == NpcState.TIER_NEAR else _far_period_usec


## The first periodic turn of a bucket of a tier that is later than
## `after_usec` (clock time).
func _next_turn_usec(tier: String, bucket: int, after_usec: int) -> int:
	var period: int = _period_usec(tier)
	var offset: int = bucket * (period / _bucket_count)
	if after_usec < offset:
		return offset
	return ((after_usec - offset) / period + 1) * period + offset


## Looks again at the tier of the NPCs whose bucket's tier slot came up
## since `previous_usec` (every bucket at most once per tick).
func _check_tiers(world: ServerWorld, npcs: NpcService, previous_usec: int) -> void:
	var from_slot: int = previous_usec / _tier_slot_usec
	var to_slot: int = _now_usec / _tier_slot_usec
	if to_slot == from_slot:
		return
	var players: PackedVector3Array = []
	var players_read: bool = false
	for slot: int in range(maxi(from_slot + 1, to_slot - _bucket_count + 1), to_slot + 1):
		var ids: PackedStringArray = _buckets[slot % _bucket_count]
		if ids.is_empty():
			continue
		if not players_read:
			players = _player_positions(world)
			players_read = true
		for npc_id: String in ids:
			var npc: NpcState = npcs.get_npc(npc_id)
			var schedule: NpcScheduleComponent = _awake[npc_id]
			tier_check_count += 1
			var tier: String = _tier_from(players, npc.position, schedule.tier)
			if tier != schedule.tier:
				_change_tier(npcs, npc_id, schedule, tier)


func _change_tier(npcs: NpcService, npc_id: String, schedule: NpcScheduleComponent, tier: String) -> void:
	schedule.tier = tier
	npcs.set_simulation_tier(npc_id, tier)
	if tier == NpcState.TIER_NEAR:
		near_count += 1
		far_count -= 1
		# It does not sit out a far period: its near turns start now. (An
		# NPC that became far keeps the turn it already had.)
		schedule.next_decision_at_usec = mini(schedule.next_decision_at_usec, _next_turn_usec(tier, bucket_of(npc_id), _now_usec))
		_earliest_usec = mini(_earliest_usec, schedule.next_decision_at_usec)
	else:
		near_count -= 1
		far_count += 1
	npcs.mark_npc_dirty(npc_id)


func _player_positions(world: ServerWorld) -> PackedVector3Array:
	var positions: PackedVector3Array = []
	for player_id: String in world.online_player_ids():
		var player: PlayerState = world.get_player(player_id)
		if player != null:
			positions.append(player.position)
	return positions


func _tier_at(world: ServerWorld, position: Vector3, current_tier: String) -> String:
	return _tier_from(_player_positions(world), position, current_tier)


## near within the radius, far beyond radius + margin, in between what it
## was (far when it was nothing yet).
func _tier_from(players: PackedVector3Array, position: Vector3, current_tier: String) -> String:
	var nearest_sq: float = INF
	for player_position: Vector3 in players:
		nearest_sq = minf(nearest_sq, position.distance_squared_to(player_position))
	if nearest_sq <= _near_radius_sq:
		return NpcState.TIER_NEAR
	if nearest_sq > _far_radius_sq or current_tier != NpcState.TIER_NEAR:
		return NpcState.TIER_FAR
	return NpcState.TIER_NEAR


## Runs the turns that are due, interrupts first, up to the cap. Only
## called in a tick in which something may be due.
func _run_decisions(world: ServerWorld, npcs: NpcService) -> void:
	scan_count += 1
	# [class (0 interrupt, 1 periodic), due since, npc id]
	var due: Array[Array] = []
	# The earliest time of the NPCs that are not due now.
	var later_usec: int = NO_TIME
	for npc_id: String in _awake:
		var schedule: NpcScheduleComponent = _awake[npc_id]
		var interrupt_at: int = NO_TIME if schedule.interrupts.is_empty() else schedule.earliest_interrupt_usec()
		if interrupt_at <= _now_usec:
			due.append([0, interrupt_at, npc_id])
		elif schedule.next_decision_at_usec <= _now_usec:
			due.append([1, schedule.next_decision_at_usec, npc_id])
		else:
			later_usec = mini(later_usec, mini(interrupt_at, schedule.next_decision_at_usec))
	if due.size() > 1:
		due.sort_custom(_is_due_before)
	var limit: int = mini(due.size(), _settings.max_decisions_per_tick)
	last_deferred_count = due.size() - limit
	# What is due next: the turns that do not fit now (still due), then,
	# below, the new times of those that decide; whatever a decider asks
	# for lowers it by itself (_set_interrupt, on_npc_woke).
	_earliest_usec = _now_usec if last_deferred_count > 0 else later_usec
	for index: int in range(limit):
		var npc_id: String = str(due[index][2])
		# A decision before this one may have put it to sleep or removed it.
		var schedule: NpcScheduleComponent = _awake.get(npc_id, null)
		var npc: NpcState = npcs.get_npc(npc_id)
		if schedule == null or npc == null:
			continue
		var reasons: PackedStringArray = []
		if schedule.next_decision_at_usec <= _now_usec:
			reasons.append(NpcDecider.REASON_PERIOD)
			schedule.next_decision_at_usec = _next_turn_usec(schedule.tier, bucket_of(npc_id), _now_usec)
		var interrupts: PackedStringArray = schedule.take_due_interrupts(_now_usec)
		reasons.append_array(interrupts)
		npcs.mark_npc_dirty(npc_id)
		last_decision_count += 1
		if not interrupts.is_empty():
			last_interrupt_count += 1
		_decider.decide(world, npcs, npc, reasons, self)
		_earliest_usec = mini(_earliest_usec, schedule.earliest_usec())
	total_decision_count += last_decision_count
	total_interrupt_count += last_interrupt_count
	peak_decisions_per_tick = maxi(peak_decisions_per_tick, last_decision_count)


static func _is_due_before(a: Array, b: Array) -> bool:
	if int(a[0]) != int(b[0]):
		return int(a[0]) < int(b[0])
	if int(a[1]) != int(b[1]):
		return int(a[1]) < int(b[1])
	return str(a[2]) < str(b[2])
