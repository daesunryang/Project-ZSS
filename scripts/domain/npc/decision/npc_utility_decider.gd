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
##      (-> Interrupt -> Recover, the action gets a retry cooldown).
##   3. Hard interrupt: a visible zombie (NpcThreatSense) starts the flee
##      action whatever the NPC does, unless it already flees or the flee
##      action is on its retry cooldown.
##   4. Recover: until its cooldown is over nothing is chosen.
##   5. Minimum duration: a running action that started less than its
##      min_duration ago is kept without looking at the candidates. So is,
##      for as long as it runs, an action with `runs_until_done` (the
##      rest): only the executor's report, a hard interrupt, or another
##      need of the NPC in the DANGER category ends it (docs/15 P4-172).
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
## one number of `npc.rng` per action of the catalog (none when
## `score_jitter` is 0), every time is the scheduler's integer clock.

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

## Record "hard_interrupt".
const HARD_THREAT: String = "threat_visible"

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
	_take_reports(npc, state, reasons, now, record, scheduler)
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
func _take_reports(npc: NpcState, state: NpcDecisionComponent, reasons: PackedStringArray, now: int, record: Dictionary, scheduler: NpcScheduler) -> void:
	for reason: String in reasons:
		if not state.is_running():
			break
		if reason == NpcActionExecutor.REPORT_ARRIVED:
			if state.state == NpcDecisionState.NAVIGATE:
				_move(state, NpcDecisionState.PERFORM, record)
		elif reason == NpcActionExecutor.REPORT_DONE:
			record[KEY_COMPLETED] = state.action_id
			state.failures.erase(state.action_id)
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
	var target: Dictionary = {
		NpcActionExecutor.TARGET_THREAT_ID: threat[NpcThreatSense.KEY_THREAT_ID],
		NpcActionExecutor.TARGET_THREAT_POSITION: threat[NpcThreatSense.KEY_THREAT_POSITION],
	}
	_begin(world, npcs, npc, state, flee, target, now, record, scheduler, OUTCOME_SWITCHED if was_running else OUTCOME_STARTED)
	return true


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
	if current != null and current.runs_until_done and not _other_need_in_danger(needs, current.need_kind):
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
		best = _fallback(state, needs, definition, now)
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
		var jitter: float = npc.rng.randf() if _settings.score_jitter > 0.0 else 0.0
		var code: String = _precondition(action, state, needs, definition, now)
		if not code.is_empty():
			(record[KEY_REJECTED] as Array).append({KEY_ACTION_ID: action_id, KEY_CODE: code})
			continue
		ranked.append(NpcUtilityScorer.score(
			action, _settings,
			_need_urgency(needs, action.need_kind),
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
func _precondition(action: NpcActionDefinition, state: NpcDecisionComponent, needs: NpcNeeds, definition: NpcDefinition, now: int) -> String:
	if not action.selectable:
		return REJECT_NOT_SELECTABLE
	if state.is_on_cooldown(action.action_id, now):
		return REJECT_COOLDOWN
	if action.requires_job and (definition == null or definition.job_role.is_empty() or definition.work_building_id.is_empty()):
		return REJECT_NO_JOB
	if action.min_need_urgency > 0.0 and _need_urgency(needs, action.need_kind) + URGENCY_EPSILON < action.min_need_urgency:
		return REJECT_NEED_LOW
	if action.blocked_by_danger_need and needs != null:
		for kind: String in NpcNeedKind.SIMULATED_KINDS:
			if needs.value(kind) + NEED_VALUE_EPSILON >= _need_settings.danger_threshold:
				return REJECT_NEED_DANGER
	return ""


## The fallback action when it may run now (it need not be selectable).
func _fallback(state: NpcDecisionComponent, needs: NpcNeeds, definition: NpcDefinition, now: int) -> NpcActionDefinition:
	var action: NpcActionDefinition = _catalog.get_action(_settings.fallback_action_id) if not _settings.fallback_action_id.is_empty() else null
	if action == null:
		return null
	var code: String = _precondition(action, state, needs, definition, now)
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


func _min_duration_sec(action: NpcActionDefinition) -> float:
	return action.min_duration_sec if action.min_duration_sec >= 0.0 else _settings.default_min_duration_sec


func _move(state: NpcDecisionComponent, to: String, record: Dictionary) -> void:
	if state.transition(to):
		(record[KEY_PATH] as Array).append(to)
