class_name NpcUtilityDecider
extends NpcDecider
## WHAT an NPC does when its turn to think comes (P4-4, docs/05 §9 / §10,
## docs/09 §17.6): hard interrupts, then a normalized utility choice, inside
## a bounded state machine. The scheduler (P4-3) decides WHEN; the executor
## (NpcActionExecutor, P4-5a / P4-5b) carries the chosen action out. Without
## an executor this decider decides nothing (nobody could act).
##
## One decision, in this order:
##   1. The NPC's needs are brought up to now (NpcNeeds.advance_to).
##   2. The executor's reports among the reasons: "action_arrived"
##      (Navigate -> Perform), "action_done" (-> Idle), "action_failed_<code>"
##      (-> Interrupt -> Recover, the action gets a retry cooldown). A
##      night sleep (`requires_bedtime`) that is done is written down as
##      this night's (F-6): the NPC does not begin another one in it.
##   3. Hard interrupt: a visible zombie (NpcThreatSense) starts the flee
##      action whatever the NPC does, unless it already flees or the flee
##      action is on its retry cooldown. F-29 (with an NpcSurvivalSense):
##      the NPC remembers where it saw the zombie, and when the zombie is
##      adjacent and fleeing is blocked (the flee action is on its
##      cooldown) or fails (it has fled for fight_after_fleeing_sec and the
##      zombie is still adjacent) it starts the fight action instead and
##      keeps it while the zombie stays adjacent ("cornered").
##   4. Recover: until its cooldown is over nothing is chosen.
##   5. Minimum duration: a running action that started less than its
##      min_duration ago is kept without looking at the candidates. So is,
##      for as long as it runs, an action with `runs_until_done` (the
##      rest): only the executor's report, a hard interrupt, or another
##      need of the NPC in the DANGER category ends it (docs/15 P4-172);
##      since F-29 also a wound it could treat now (_treatment_calls).
##      F-30: the action "relocate" is like that too, and while an NPC is
##      in the middle of a move the actions with `blocked_while_moving`
##      are no candidates ("moving"); "relocate" itself is one only for an
##      NPC that moves or has a reason to ("no_move_reason" otherwise).
##      That is how a sleeper wakes on danger (F-6): a visible zombie is
##      step 3, a need in danger sends it to step 6, where an action with
##      `yields_to_danger_need` is no candidate while the NPC can eat or
##      drink. And a nap that still runs when the NPC's night sleep can
##      begin gives way to it (the nap is then no candidate: "bedtime_now").
##   6. Utility choice (NpcUtilityScorer): every action whose preconditions
##      hold is scored; the best one at or above `min_action_score` is
##      started, or kept when it is the running one (which has the
##      `current_action_bonus`). No candidate: the fallback action; none of
##      that either: Idle.
##   7. The next category boundary of the needs is put into the scheduler as
##      the timed interrupt "need_boundary".
## Every decision leaves a record (the NPC's ring in NpcDecisionComponent,
## and the signal `decided`).
##
## Determinism: the actions are looked at in id order, an evaluation draws
## one number of `npc.rng` per action of the catalog that has
## `draws_jitter` (none when `score_jitter` is 0), every time is the
## scheduler's integer clock.

## Emitted after every decision with its record (see the KEY_ constants).
signal decided(npc_id: String, record: Dictionary)

## Interrupt reasons of this ticket (the executor's are in NpcActionExecutor).
const REASON_THREAT_SEEN: String = "threat_seen"
const REASON_NEED_BOUNDARY: String = "need_boundary"
const REASON_RECOVER_DONE: String = "recover_done"

## Why an action is no candidate (record "rejected").
const REJECT_NOT_SELECTABLE: String = "not_selectable"
const REJECT_COOLDOWN: String = "cooldown"
const REJECT_NO_JOB: String = "no_job"
const REJECT_NEED_LOW: String = "need_too_low"
const REJECT_NEED_DANGER: String = "need_in_danger"
## F-6: it is not the NPC's bedtime / it has slept this night already.
const REJECT_NOT_BEDTIME: String = "not_bedtime"
const REJECT_SLEPT: String = "slept_tonight"
## F-6: the NPC's night sleep can begin now, so it does not nap instead.
const REJECT_BEDTIME_NOW: String = "bedtime_now"
## F-29: the action is for NPCs that live alone / there is nothing the NPC
## could treat itself with (or nothing to treat).
const REJECT_NOT_LONE: String = "not_lone"
const REJECT_NOTHING_TO_TREAT: String = "nothing_to_treat"
## F-30: the NPC has no reason to move / it is in the middle of a move.
const REJECT_NO_MOVE_REASON: String = "no_move_reason"
const REJECT_MOVING: String = "moving"
## A failure code the executor returned that is not a snake_case id.
const FAIL_BAD_CODE: String = "bad_failure_code"

## A save rounds floats (calendar time, need values) to 14 digits, so a run
## that was restored differs from one that went on in their last digits.
## These margins keep a decision that falls on the very moment a need
## crosses a threshold from depending on those digits (docs/15 P4-166):
## a need boundary is looked at this long (action time) after it is crossed;
const NEED_BOUNDARY_MARGIN_SEC: float = 0.001
## a boundary that is nearer than this (calendar seconds) is being crossed
## now and gets no timer of its own;
const NEED_BOUNDARY_IMMINENT_WORLD_SEC: float = 0.00001
## and a need counts as having reached a threshold from this far below it
## (need units / urgency).
const NEED_VALUE_EPSILON: float = 0.000001
const URGENCY_EPSILON: float = 0.000000001
## The bedtime of an NPC whose definition is not in the data any more.
const DEFAULT_BEDTIME_HOUR: float = 22.0

## Record "hard_interrupt".
const HARD_THREAT: String = "threat_visible"
## F-29: the zombie is adjacent and fleeing is blocked or fails.
const HARD_CORNERED: String = "cornered"

## Record "outcome".
const OUTCOME_STARTED: String = "started"
const OUTCOME_SWITCHED: String = "switched"
const OUTCOME_KEPT: String = "kept"
const OUTCOME_MIN_DURATION: String = "min_duration"
## The running action has `runs_until_done` and nothing ends it yet.
const OUTCOME_UNTIL_DONE: String = "until_done"
const OUTCOME_RECOVERING: String = "recovering"
const OUTCOME_NOTHING: String = "nothing"
const OUTCOME_FAILED: String = "failed"

## Keys of a decision record (JSON-safe).
const KEY_SEQUENCE: String = "sequence"
const KEY_AT_USEC: String = "at_usec"
const KEY_WORLD_TIME: String = "world_time"
const KEY_REASONS: String = "reasons"
const KEY_STATE_BEFORE: String = "state_before"
const KEY_ACTION_BEFORE: String = "action_before"
## The states passed through, the first being state_before.
const KEY_PATH: String = "path"
const KEY_STATE_AFTER: String = "state_after"
const KEY_ACTION_AFTER: String = "action_after"
## "" or HARD_THREAT.
const KEY_HARD_INTERRUPT: String = "hard_interrupt"
## The best candidates, best first: NpcUtilityScorer entries
## {action_id, score, fixed_priority, values: {term: 0..1}, terms: {term:
## weighted}}. Empty when the candidates were not looked at.
const KEY_CANDIDATES: String = "candidates"
## [{action_id, code}]: the actions whose preconditions failed.
const KEY_REJECTED: String = "rejected"
## The action this decision started or kept ("" = none).
const KEY_CHOSEN: String = "chosen"
const KEY_FALLBACK: String = "fallback"
const KEY_OUTCOME: String = "outcome"
## The action the executor reported done in this decision ("" = none).
const KEY_COMPLETED: String = "completed"
## {} or {action_id, code}: what failed in this decision.
const KEY_FAILURE: String = "failure"
const KEY_TARGET: String = "target"
const KEY_ACTION_ID: String = "action_id"
const KEY_CODE: String = "code"

## Diagnostics.
var decision_count: int = 0
var evaluation_count: int = 0
var failure_count: int = 0
var hard_interrupt_count: int = 0

var _settings: NpcDecisionSettings
var _catalog: NpcActionCatalog
var _need_settings: NpcNeedSettings
var _executor: NpcActionExecutor = null
var _scheduler_ref: WeakRef = null
var _sensor_ref: WeakRef = null
var _told_no_executor: bool = false
## F-29: what the NPC knows about its supplies, its wounds and danger
## (null = the survival rules of F-29 are off: nobody scavenges, treats
## itself by choice, remembers zombies or fights).
var _survival: NpcSurvivalSense = null
## F-30: when an NPC that lives alone moves to another shelter (null =
## nobody moves).
var _relocation: NpcRelocation = null


func _init(settings: NpcDecisionSettings, catalog: NpcActionCatalog, need_settings: NpcNeedSettings, action_executor: NpcActionExecutor = null) -> void:
	_settings = settings
	_catalog = catalog
	_need_settings = need_settings
	_executor = action_executor


## Gives `npcs` the decision component and the threat sensor stage (the one
## line of ServerComposition, after NpcScheduler.install with this decider).
func install(npcs: NpcService, scheduler: NpcScheduler) -> Error:
	if npcs == null or scheduler == null:
		return ERR_INVALID_PARAMETER
	var error: Error = npcs.register_component(NpcDecisionComponent.COMPONENT_ID, NpcDecisionComponent.create.bind(_catalog))
	if error != OK:
		return error
	var sensor: NpcThreatSensor = NpcThreatSensor.new(_settings, self, scheduler)
	_sensor_ref = weakref(sensor)
	return npcs.add_stage(sensor)


## The threat sensor stage install() added (null before that).
func threat_sensor() -> NpcThreatSensor:
	return _sensor_ref.get_ref() as NpcThreatSensor if _sensor_ref != null else null


func on_attached(scheduler: NpcScheduler) -> void:
	_scheduler_ref = weakref(scheduler)


## The scheduler this decider was given to (null before that).
func scheduler() -> NpcScheduler:
	return _scheduler_ref.get_ref() as NpcScheduler if _scheduler_ref != null else null


## Who carries the chosen actions out (P4-5a). null = this decider decides
## nothing.
func set_executor(action_executor: NpcActionExecutor) -> void:
	_executor = action_executor


func executor() -> NpcActionExecutor:
	return _executor


## F-29: gives the decider the NPCs' survival sense (ServerComposition).
func set_survival(sense: NpcSurvivalSense) -> void:
	_survival = sense


func survival() -> NpcSurvivalSense:
	return _survival


## F-30: gives the decider the NPCs' moves (ServerComposition).
func set_relocation(relocation: NpcRelocation) -> void:
	_relocation = relocation


func relocation() -> NpcRelocation:
	return _relocation


## F-29: true when the catalog has a selectable action an NPC treats itself
## with (`requires_treatment`): NpcHealth then leaves the treating to it.
func has_treat_action() -> bool:
	for action_id: String in _catalog.action_ids():
		var action: NpcActionDefinition = _catalog.get_action(action_id)
		if action.selectable and action.requires_treatment:
			return true
	return false


func settings() -> NpcDecisionSettings:
	return _settings


func actions() -> NpcActionCatalog:
	return _catalog


## True when a visible threat would make this NPC start to flee now: there
## is an executor and a flee action, the NPC does not flee already, and the
## flee action is not on its retry cooldown.
func may_start_fleeing(state: NpcDecisionComponent, now_usec: int) -> bool:
	var flee: NpcActionDefinition = _flee_action()
	if _executor == null or flee == null or state == null:
		return false
	if state.is_running() and state.action_id == flee.action_id:
		return false
	return not state.is_on_cooldown(flee.action_id, now_usec)


## F-29: how near (metres) a visible zombie must be for this NPC to be
## asked whether it is cornered now; 0 when it could not start to fight
## (no fight action, no survival sense, it fights already, or the fight
## action is on its retry cooldown).
func fight_alert_range(state: NpcDecisionComponent, now_usec: int) -> float:
	var fight: NpcActionDefinition = _fight_action()
	if _executor == null or fight == null or _survival == null or state == null:
		return 0.0
	if (state.is_running() and state.action_id == fight.action_id) or state.is_on_cooldown(fight.action_id, now_usec):
		return 0.0
	return _survival.settings.fight_range_m


func decide(world: ServerWorld, npcs: NpcService, npc: NpcState, reasons: PackedStringArray, scheduler: NpcScheduler) -> void:
	if _executor == null:
		if not _told_no_executor:
			_told_no_executor = true
			GameLogger.info("npc", "the npc decider has no executor: NPCs choose nothing", {"operation": "decide"})
		return
	var state: NpcDecisionComponent = npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent
	if state == null:
		return
	var now: int = scheduler.clock_usec()
	var needs: NpcNeeds = npc.component(NpcNeeds.COMPONENT_ID) as NpcNeeds
	if needs != null:
		needs.advance_to(maxf(world.clock.world_time_sec, needs.last_updated_world_time()))
	decision_count += 1
	state.decision_count += 1
	state.prune_cooldowns(now)
	var record: Dictionary = {
		KEY_SEQUENCE: state.decision_count,
		KEY_AT_USEC: now,
		KEY_WORLD_TIME: world.clock.world_time_sec,
		KEY_REASONS: Array(reasons),
		KEY_STATE_BEFORE: state.state,
		KEY_ACTION_BEFORE: state.action_id,
		KEY_PATH: [state.state],
		KEY_HARD_INTERRUPT: "",
		KEY_CANDIDATES: [],
		KEY_REJECTED: [],
		KEY_CHOSEN: "",
		KEY_FALLBACK: false,
		KEY_OUTCOME: OUTCOME_NOTHING,
		KEY_COMPLETED: "",
		KEY_FAILURE: {},
		KEY_TARGET: {},
	}
	_take_reports(world, npcs, npc, state, reasons, now, record, scheduler)
	if not _hard_interrupt(world, npcs, npc, state, now, record, scheduler):
		_choose(world, npcs, npc, state, needs, now, record, scheduler)
	record[KEY_STATE_AFTER] = state.state
	record[KEY_ACTION_AFTER] = state.action_id
	_schedule_need_boundary(world, npc, needs, scheduler)
	state.push_record(record, _settings.record_capacity)
	npcs.mark_npc_dirty(npc.npc_id)
	decided.emit(npc.npc_id, record)


# ------------------------------------------------------------ steps

## Step 2: what the executor reported about the running action.
func _take_reports(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcDecisionComponent, reasons: PackedStringArray, now: int, record: Dictionary, scheduler: NpcScheduler) -> void:
	for reason: String in reasons:
		if not state.is_running():
			break
		if reason == NpcActionExecutor.REPORT_ARRIVED:
			if state.state == NpcDecisionState.NAVIGATE:
				_move(state, NpcDecisionState.PERFORM, record)
		elif reason == NpcActionExecutor.REPORT_DONE:
			record[KEY_COMPLETED] = state.action_id
			state.failures.erase(state.action_id)
			var done: NpcActionDefinition = _catalog.get_action(state.action_id)
			if done != null and done.requires_bedtime:
				# The night sleep of this night is over (F-6).
				state.last_sleep_night = maxi(state.last_sleep_night, NpcBedtime.night_of(world.clock.world_time_sec, _settings.day_length_world_sec, _bedtime_hour(npcs.definition_of(npc.npc_id))))
			_move(state, NpcDecisionState.IDLE, record)
			state.clear_action()
		else:
			var code: String = NpcActionExecutor.failure_code_of(reason)
			if not code.is_empty():
				_fail_running(npc, state, code, now, record, scheduler)
	# The saved state says an action runs, the executor knows nothing of it.
	if state.is_running() and not _executor.is_running(npc.npc_id):
		_fail_running(npc, state, NpcActionExecutor.FAIL_LOST, now, record, scheduler)


## Step 3. True when the hard interrupt decided what the NPC does.
func _hard_interrupt(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcDecisionComponent, now: int, record: Dictionary, scheduler: NpcScheduler) -> bool:
	var flee: NpcActionDefinition = _flee_action()
	if flee == null:
		return false
	var threat: Dictionary = NpcThreatSense.nearest_visible(world, npc.position, _settings.threat_sight_range_m, NpcThreatSense.living_zombies(world))
	if threat.is_empty():
		return false
	record[KEY_HARD_INTERRUPT] = HARD_THREAT
	var seen: Dictionary = {
		NpcActionExecutor.TARGET_THREAT_ID: threat[NpcThreatSense.KEY_THREAT_ID],
		NpcActionExecutor.TARGET_THREAT_POSITION: threat[NpcThreatSense.KEY_THREAT_POSITION],
	}
	if _survival != null:
		var place: Array = threat[NpcThreatSense.KEY_THREAT_POSITION]
		_survival.note_zombie_seen(world, npc, Vector3(float(place[0]), float(place[1]), float(place[2])))
	var fight: NpcActionDefinition = _fight_action()
	if fight != null and _is_cornered(state, flee, fight, float(threat[NpcThreatSense.KEY_DISTANCE]), now):
		record[KEY_HARD_INTERRUPT] = HARD_CORNERED
		if state.is_running() and state.action_id == fight.action_id:
			record[KEY_CHOSEN] = fight.action_id
			record[KEY_OUTCOME] = OUTCOME_KEPT
			record[KEY_TARGET] = state.target.duplicate(true)
			return true
		_interrupt_with(world, npcs, npc, state, fight, seen, now, record, scheduler)
		return true
	if state.is_running() and state.action_id == flee.action_id:
		record[KEY_CHOSEN] = flee.action_id
		record[KEY_OUTCOME] = OUTCOME_KEPT
		record[KEY_TARGET] = state.target.duplicate(true)
		return true
	if state.is_on_cooldown(flee.action_id, now):
		# It cannot flee now (the flee action just failed): it goes on with
		# the ordinary choice.
		(record[KEY_REJECTED] as Array).append({KEY_ACTION_ID: flee.action_id, KEY_CODE: REJECT_COOLDOWN})
		return false
	_interrupt_with(world, npcs, npc, state, flee, seen, now, record, scheduler)
	return true


## A hard interrupt starts `action` whatever the NPC does: the running
## action is cancelled, a recovery is cut short.
func _interrupt_with(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcDecisionComponent, action: NpcActionDefinition, target: Dictionary, now: int, record: Dictionary, scheduler: NpcScheduler) -> void:
	hard_interrupt_count += 1
	var was_running: bool = state.is_running()
	if was_running:
		_executor.cancel(world, npcs, npc)
	if state.state == NpcDecisionState.RECOVER:
		state.recover_until_usec = NpcDecisionComponent.NO_TIME
		scheduler.cancel_interrupt(npc.npc_id, REASON_RECOVER_DONE)
	_move(state, NpcDecisionState.INTERRUPT, record)
	state.clear_action()
	_move(state, NpcDecisionState.PLAN, record)
	_begin(world, npcs, npc, state, action, target, now, record, scheduler, OUTCOME_SWITCHED if was_running else OUTCOME_STARTED)


## F-29: true when a zombie `distance_m` away has the NPC cornered: it is
## adjacent, the NPC could fight, and fleeing is blocked (the flee action
## is on its retry cooldown: it just failed) or fails (the NPC has fled for
## fight_after_fleeing_sec and the zombie is still adjacent). An NPC that
## fights already stays cornered while the zombie is adjacent.
func _is_cornered(state: NpcDecisionComponent, flee: NpcActionDefinition, fight: NpcActionDefinition, distance_m: float, now: int) -> bool:
	if _survival == null or distance_m > _survival.settings.fight_range_m or state.is_on_cooldown(fight.action_id, now):
		return false
	if state.is_running() and state.action_id == fight.action_id:
		return true
	if state.is_on_cooldown(flee.action_id, now):
		return true
	return state.is_running() and state.action_id == flee.action_id and now - state.action_started_at_usec >= NpcScheduleSettings.to_usec(_survival.settings.fight_after_fleeing_sec)


## Steps 4 to 6.
func _choose(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcDecisionComponent, needs: NpcNeeds, now: int, record: Dictionary, scheduler: NpcScheduler) -> void:
	if state.state == NpcDecisionState.RECOVER:
		if now < state.recover_until_usec:
			record[KEY_OUTCOME] = OUTCOME_RECOVERING
			return
		state.recover_until_usec = NpcDecisionComponent.NO_TIME
		scheduler.cancel_interrupt(npc.npc_id, REASON_RECOVER_DONE)
	var current: NpcActionDefinition = null
	if state.is_running():
		current = _catalog.get_action(state.action_id)
		if current == null:
			# The action is not in the data any more.
			_stop(world, npcs, npc, state, record)
	if current != null and now - state.action_started_at_usec < NpcScheduleSettings.to_usec(_min_duration_sec(current)):
		record[KEY_CHOSEN] = current.action_id
		record[KEY_OUTCOME] = OUTCOME_MIN_DURATION
		return
	if current != null and current.runs_until_done and not _other_need_in_danger(needs, current.need_kind) and not _night_sleep_calls(npc, current, state, needs, npcs.definition_of(npc.npc_id), now, world.clock.world_time_sec) and not _treatment_calls(npc, state, now):
		# It goes on until the executor says it is over: its own preconditions
		# (the need that started it has dropped) and the other candidates are
		# not looked at. No number is drawn, as in the minimum duration.
		record[KEY_CHOSEN] = current.action_id
		record[KEY_OUTCOME] = OUTCOME_UNTIL_DONE
		return
	var origin: String = state.state
	_move(state, NpcDecisionState.EVALUATE, record)
	var definition: NpcDefinition = npcs.definition_of(npc.npc_id)
	var best: NpcActionDefinition = _best_candidate(world, npc, state, needs, definition, now, record)
	if best == null:
		best = _fallback(npc, state, needs, definition, now, world.clock.world_time_sec)
		record[KEY_FALLBACK] = best != null
	if best == null:
		if current != null:
			_executor.cancel(world, npcs, npc)
			_move(state, NpcDecisionState.INTERRUPT, record)
			state.clear_action()
		_move(state, NpcDecisionState.IDLE, record)
		return
	if current != null and best.action_id == current.action_id:
		_move(state, origin, record)
		record[KEY_CHOSEN] = current.action_id
		record[KEY_OUTCOME] = OUTCOME_KEPT
		return
	if current != null:
		_executor.cancel(world, npcs, npc)
		_move(state, NpcDecisionState.INTERRUPT, record)
		state.clear_action()
	_move(state, NpcDecisionState.PLAN, record)
	_begin(world, npcs, npc, state, best, {}, now, record, scheduler, OUTCOME_SWITCHED if current != null else OUTCOME_STARTED)


## Step 6: scores the actions whose preconditions hold and returns the best
## one at or above the minimum score (null = none).
func _best_candidate(world: ServerWorld, npc: NpcState, state: NpcDecisionComponent, needs: NpcNeeds, definition: NpcDefinition, now: int, record: Dictionary) -> NpcActionDefinition:
	evaluation_count += 1
	var traits: Dictionary = definition.personality() if definition != null else {}
	var hour: float = NpcUtilityScorer.hour_of_day(world.clock.world_time_sec, _settings.day_length_world_sec)
	var ranked: Array[Dictionary] = []
	for action_id: String in _catalog.action_ids():
		var action: NpcActionDefinition = _catalog.get_action(action_id)
		# One number per action, candidate or not: what an NPC draws does not
		# depend on which preconditions hold.
		var jitter: float = npc.rng.randf() if _settings.score_jitter > 0.0 and action.draws_jitter else 0.0
		var code: String = _precondition(npc, action, state, needs, definition, now, world.clock.world_time_sec)
		if not code.is_empty():
			(record[KEY_REJECTED] as Array).append({KEY_ACTION_ID: action_id, KEY_CODE: code})
			continue
		ranked.append(NpcUtilityScorer.score(
			action, _settings,
			_need_term(npc, needs, action),
			NpcUtilityScorer.personality_fit(traits, action.personality_traits),
			NpcUtilityScorer.environment_fit(action, hour),
			_relationship_context(npc, action),
			_memory_context(npc, action),
			state.action_id == action_id,
			jitter))
	if ranked.size() > 1:
		ranked.sort_custom(NpcUtilityScorer.is_better)
	record[KEY_CANDIDATES] = ranked.slice(0, _settings.record_top_candidates)
	if ranked.is_empty() or float(ranked[0][NpcUtilityScorer.KEY_SCORE]) < _settings.min_action_score:
		return null
	return _catalog.get_action(str(ranked[0][NpcUtilityScorer.KEY_ACTION_ID]))


## "" when `action` may be a candidate now, or the REJECT_ code.
func _precondition(npc: NpcState, action: NpcActionDefinition, state: NpcDecisionComponent, needs: NpcNeeds, definition: NpcDefinition, now: int, world_time_sec: float) -> String:
	if not action.selectable:
		return REJECT_NOT_SELECTABLE
	if state.is_on_cooldown(action.action_id, now):
		return REJECT_COOLDOWN
	if action.requires_job and (definition == null or definition.job_role.is_empty() or not _has_work_place(npc, definition)):
		return REJECT_NO_JOB
	if action.requires_lone_home and (_survival == null or not _survival.is_lone(npc)):
		return REJECT_NOT_LONE
	if action.requires_treatment and (_survival == null or not _survival.can_treat(npc)):
		return REJECT_NOTHING_TO_TREAT
	if action.requires_move_reason and (_relocation == null or not _relocation.wants_to_move(npc)):
		return REJECT_NO_MOVE_REASON
	if action.blocked_while_moving and _relocation != null and _relocation.is_moving(npc):
		return REJECT_MOVING
	if action.min_need_urgency > 0.0 and _need_term(npc, needs, action) + URGENCY_EPSILON < action.min_need_urgency:
		return REJECT_NEED_LOW
	if action.blocked_by_danger_need and needs != null:
		for kind: String in NpcNeedKind.SIMULATED_KINDS:
			if needs.value(kind) + NEED_VALUE_EPSILON >= _need_settings.danger_threshold:
				return REJECT_NEED_DANGER
	if action.yields_to_danger_need and needs != null:
		for kind: String in NpcNeedKind.SIMULATED_KINDS:
			if kind != action.need_kind and needs.value(kind) + NEED_VALUE_EPSILON >= _need_settings.danger_threshold and _can_answer(kind, state, now):
				return REJECT_NEED_DANGER
	if _night_sleep_calls(npc, action, state, needs, definition, now, world_time_sec):
		return REJECT_BEDTIME_NOW
	if action.requires_bedtime:
		var bedtime_hour: float = _bedtime_hour(definition)
		if not NpcBedtime.is_bedtime(world_time_sec, _settings.day_length_world_sec, bedtime_hour, _settings.night_sleep_window_hours):
			return REJECT_NOT_BEDTIME
		if state.last_sleep_night >= NpcBedtime.night_of(world_time_sec, _settings.day_length_world_sec, bedtime_hour):
			return REJECT_SLEPT
	return ""


## True when a selectable action that answers the need `kind` is not on its
## retry cooldown: the NPC can do something about that need now.
func _can_answer(kind: String, state: NpcDecisionComponent, now: int) -> bool:
	for action_id: String in _catalog.action_ids():
		var action: NpcActionDefinition = _catalog.get_action(action_id)
		if action.selectable and action.need_kind == kind and not state.is_on_cooldown(action_id, now):
			return true
	return false


## True when the NPC has a place to work at. An NPC that lives alone in a
## generated building (F-28) has none: nothing sends it to work.
static func _has_work_place(npc: NpcState, definition: NpcDefinition) -> bool:
	var home: NpcHome = NpcHome.of(npc)
	return home.has_work_place(definition) if home != null else not definition.work_building_id.is_empty()


## True when `action` answers a need that a night sleep (an action with
## `requires_bedtime` and the same `need_kind`) could answer now: at its
## bedtime an NPC goes to bed instead of napping, and a nap that still runs
## at the bedtime gives way to the night sleep (F-6).
func _night_sleep_calls(npc: NpcState, action: NpcActionDefinition, state: NpcDecisionComponent, needs: NpcNeeds, definition: NpcDefinition, now: int, world_time_sec: float) -> bool:
	if action.requires_bedtime or action.need_kind.is_empty():
		return false
	for action_id: String in _catalog.action_ids():
		var other: NpcActionDefinition = _catalog.get_action(action_id)
		if other.requires_bedtime and other.need_kind == action.need_kind and _precondition(npc, other, state, needs, definition, now, world_time_sec).is_empty():
			return true
	return false


## F-29: true when the NPC could treat itself now (it is wounded, carries
## what helps, and a treating action is not on its cooldown): that ends an
## action that otherwise runs until it is done, like a need in danger does.
func _treatment_calls(npc: NpcState, state: NpcDecisionComponent, now: int) -> bool:
	if _survival == null:
		return false
	for action_id: String in _catalog.action_ids():
		var action: NpcActionDefinition = _catalog.get_action(action_id)
		if action.selectable and action.requires_treatment and not state.is_on_cooldown(action_id, now):
			return _survival.can_treat(npc)
	return false


## The bedtime of an NPC (DEFAULT_BEDTIME_HOUR without a definition).
static func _bedtime_hour(definition: NpcDefinition) -> float:
	return definition.bedtime_hour if definition != null else DEFAULT_BEDTIME_HOUR


## The fallback action when it may run now (it need not be selectable).
func _fallback(npc: NpcState, state: NpcDecisionComponent, needs: NpcNeeds, definition: NpcDefinition, now: int, world_time_sec: float) -> NpcActionDefinition:
	var action: NpcActionDefinition = _catalog.get_action(_settings.fallback_action_id) if not _settings.fallback_action_id.is_empty() else null
	if action == null:
		return null
	var code: String = _precondition(npc, action, state, needs, definition, now, world_time_sec)
	return action if code.is_empty() or code == REJECT_NOT_SELECTABLE else null


## Hands `action` to the executor (state Plan). True when it runs.
func _begin(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcDecisionComponent, action: NpcActionDefinition, target: Dictionary, now: int, record: Dictionary, scheduler: NpcScheduler, outcome: String) -> bool:
	record[KEY_CHOSEN] = action.action_id
	record[KEY_TARGET] = target.duplicate(true)
	var code: String = _executor.begin(world, npcs, npc, action, target)
	if code.is_empty():
		state.set_action(action.action_id, target, now)
		_move(state, NpcDecisionState.NAVIGATE, record)
		record[KEY_OUTCOME] = outcome
		return true
	_note_failure(npc, state, action.action_id, code, now, record)
	_recover(npc, state, now, record, scheduler)
	return false


## The running action failed (the executor said so): Interrupt, Recover.
func _fail_running(npc: NpcState, state: NpcDecisionComponent, code: String, now: int, record: Dictionary, scheduler: NpcScheduler) -> void:
	var failed_id: String = state.action_id
	_move(state, NpcDecisionState.INTERRUPT, record)
	state.clear_action()
	_note_failure(npc, state, failed_id, code, now, record)
	_recover(npc, state, now, record, scheduler)


## Writes a failure down and puts the action on its retry cooldown: the
## action's (or the default) cooldown, doubled for every failure in a row,
## at most retry_cooldown_max_sec.
func _note_failure(npc: NpcState, state: NpcDecisionComponent, action_id: String, raw_code: String, now: int, record: Dictionary) -> void:
	var code: String = raw_code if NpcComponent.is_valid_id(raw_code) and raw_code.length() <= NpcDecisionComponent.CODE_MAX_LENGTH else FAIL_BAD_CODE
	failure_count += 1
	var in_a_row: int = state.note_failure(action_id, code, now)
	var action: NpcActionDefinition = _catalog.get_action(action_id)
	var base_sec: float = action.retry_cooldown_sec if action != null and action.retry_cooldown_sec >= 0.0 else _settings.retry_cooldown_sec
	var cooldown_sec: float = minf(base_sec * pow(2.0, float(mini(in_a_row - 1, 30))), _settings.retry_cooldown_max_sec)
	if cooldown_sec > 0.0:
		state.set_cooldown(action_id, now + NpcScheduleSettings.to_usec(cooldown_sec))
	record[KEY_FAILURE] = {KEY_ACTION_ID: action_id, KEY_CODE: code}
	record[KEY_OUTCOME] = OUTCOME_FAILED
	GameLogger.debug("npc", "npc action failed", {"entity_id": npc.npc_id, "action_id": action_id, "reason": code, "failures_in_a_row": in_a_row, "operation": "decide"})


## Enters Recover (from Plan or Interrupt) and asks for a decision when its
## cooldown is over.
func _recover(npc: NpcState, state: NpcDecisionComponent, now: int, record: Dictionary, scheduler: NpcScheduler) -> void:
	_move(state, NpcDecisionState.RECOVER, record)
	state.recover_until_usec = now + NpcScheduleSettings.to_usec(_settings.recover_cooldown_sec)
	scheduler.schedule_interrupt(npc.npc_id, REASON_RECOVER_DONE, _settings.recover_cooldown_sec)


## Stops the running action without a failure: Interrupt, Idle.
func _stop(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcDecisionComponent, record: Dictionary) -> void:
	_executor.cancel(world, npcs, npc)
	_move(state, NpcDecisionState.INTERRUPT, record)
	state.clear_action()
	_move(state, NpcDecisionState.IDLE, record)


## Step 7.
func _schedule_need_boundary(world: ServerWorld, npc: NpcState, needs: NpcNeeds, scheduler: NpcScheduler) -> void:
	if needs == null:
		return
	var boundary: float = needs.next_category_boundary_world_time()
	if is_finite(boundary) and boundary - world.clock.world_time_sec > NEED_BOUNDARY_IMMINENT_WORLD_SEC:
		scheduler.schedule_interrupt(npc.npc_id, REASON_NEED_BOUNDARY, maxf(boundary - world.clock.world_time_sec, 0.0) / world.clock.time_scale + NEED_BOUNDARY_MARGIN_SEC)
	else:
		scheduler.cancel_interrupt(npc.npc_id, REASON_NEED_BOUNDARY)


# ------------------------------------------------------------ terms

func _need_urgency(needs: NpcNeeds, kind: String) -> float:
	if needs == null or kind.is_empty():
		return 0.0
	return NpcUtilityScorer.need_urgency(needs.value(kind), _need_settings.need_max)


## The need term of an action: the urgency of its simulated need, or (F-29,
## `need_is_supply_shortage`) how badly the NPC lacks supplies.
func _need_term(npc: NpcState, needs: NpcNeeds, action: NpcActionDefinition) -> float:
	if action.need_is_supply_shortage:
		return _survival.supply_shortage(npc) if _survival != null else 0.0
	return _need_urgency(needs, action.need_kind)


## Phase 5 (docs/05 §9.2 relationship_context): 0 until relationships
## change what an NPC wants.
func _relationship_context(_npc: NpcState, _action: NpcActionDefinition) -> float:
	return 0.0


## Phase 5 (docs/05 §9.2 memory_context): 0 until memories do.
func _memory_context(_npc: NpcState, _action: NpcActionDefinition) -> float:
	return 0.0


## True when a simulated need other than `own_kind` is in the DANGER
## category: what ends an action that otherwise runs until it is done.
func _other_need_in_danger(needs: NpcNeeds, own_kind: String) -> bool:
	if needs == null:
		return false
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		if kind != own_kind and needs.value(kind) + NEED_VALUE_EPSILON >= _need_settings.danger_threshold:
			return true
	return false


func _flee_action() -> NpcActionDefinition:
	return _catalog.get_action(_settings.flee_action_id) if not _settings.flee_action_id.is_empty() else null


func _fight_action() -> NpcActionDefinition:
	return _catalog.get_action(_settings.fight_action_id) if not _settings.fight_action_id.is_empty() else null


func _min_duration_sec(action: NpcActionDefinition) -> float:
	return action.min_duration_sec if action.min_duration_sec >= 0.0 else _settings.default_min_duration_sec


func _move(state: NpcDecisionComponent, to: String, record: Dictionary) -> void:
	if state.transition(to):
		(record[KEY_PATH] as Array).append(to)
