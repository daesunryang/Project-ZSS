extends TestCase
## P4-4: what an NPC decides (docs/09 §17.6). Hard interrupts, the
## normalized utility choice and the bounded state machine of
## NpcUtilityDecider: the score's terms stay within 0..1, ties are broken by
## score, fixed priority and action id, the running action is kept against a
## candidate that is only a little better and for its minimum duration, an
## NPC without a candidate falls back or stands idle, a visible zombie makes
## it flee whatever it does (not through a wall), a failure leads to Recover
## and a retry cooldown, and the same run makes the same decisions twice and
## across a save and restore (docs/13 §16.3 D11). HOW an action is carried
## out is P4-5a / P4-5b: the executor here is a stub that only writes down
## what it was asked. Server rules only, no nodes; ticks are stepped by
## hand, nothing depends on real time.

const WORLD: String = "npc_decision_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
## An NPC with a job and one without.
const WORKER: String = "t44_worker"
const DRIFTER: String = "t44_drifter"
## F-6: a morning type (bedtime 21:00) and an evening type (00:30).
const LARK: String = "t44_lark"
const OWL: String = "t44_owl"
const LARK_BEDTIME: float = 21.0
const OWL_BEDTIME: float = 0.5
const HOUR_SEC: float = 3600.0
const CHORES: String = "chores"
const WALL: String = "dev_wall"
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
## 3 m west of the player: near.
const NPC_SPOT: Vector3 = Vector3(2.5, 0.0, 5.5)
const POKE: String = "poke"
const USEC: int = NpcScheduleSettings.USEC_PER_SEC

const EAT: String = "eat"
const DRINK: String = "drink"
const REST: String = "rest"
const SLEEP: String = "sleep"
const WORK: String = "work"
const WANDER: String = "wander"
const FLEE: String = "flee"


## Writes down what the decider asks of it. Runs nothing: the tests report
## arrivals, completions and failures themselves (through the scheduler's
## interrupts, like a real executor).
class StubExecutor:
	extends NpcActionExecutor
	## "<npc> <action>" of every accepted begin().
	var begun: PackedStringArray = []
	var targets: Array[Dictionary] = []
	var cancelled: PackedStringArray = []
	## action id -> the failure code begin() answers with.
	var refuse: Dictionary[String, String] = {}
	## begin() refuses this action for an NPC whose decision count is a
	## multiple of `flaky_every` (the count is saved with the NPC, so a
	## restored run refuses the same ones).
	var flaky_action: String = ""
	var flaky_every: int = 0
	## True: it claims to run nothing.
	var lost: bool = false
	var npcs_ref: WeakRef = null

	func begin(_world: ServerWorld, _npcs: NpcService, npc: NpcState, action: NpcActionDefinition, target: Dictionary) -> String:
		if refuse.has(action.action_id):
			return refuse[action.action_id]
		if action.action_id == flaky_action and flaky_every > 0:
			var state: NpcDecisionComponent = npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent
			if state.decision_count % flaky_every == 0:
				return NpcActionExecutor.FAIL_NO_RESOURCE
		begun.append("%s %s" % [npc.npc_id, action.action_id])
		targets.append(target.duplicate(true))
		return ""

	## What a real executor reads from its own saved component, the stub
	## reads from the decider's: it "runs" what the NPC's state says.
	func is_running(npc_id: String) -> bool:
		var npcs: NpcService = npcs_ref.get_ref() as NpcService if npcs_ref != null else null
		var npc: NpcState = npcs.get_npc(npc_id) if npcs != null else null
		if lost or npc == null:
			return false
		return (npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent).is_running()

	func cancel(_world: ServerWorld, _npcs: NpcService, npc: NpcState) -> void:
		cancelled.append(npc.npc_id)


## Every decision record: the full record as JSON, and its "signature" (what
## was decided, without the float values a save rounds).
class Log:
	extends RefCounted
	var tick: int = 0
	var full: PackedStringArray = []
	var signatures: PackedStringArray = []
	var records: Array[Dictionary] = []

	func on_decided(npc_id: String, record: Dictionary) -> void:
		records.append(record)
		full.append("%d %s %s" % [tick, npc_id, JSON.stringify(record, "", true, true)])
		var candidates: PackedStringArray = []
		for candidate: Dictionary in record[NpcUtilityDecider.KEY_CANDIDATES]:
			candidates.append(str(candidate[NpcUtilityScorer.KEY_ACTION_ID]))
		var rejected: PackedStringArray = []
		for entry: Dictionary in record[NpcUtilityDecider.KEY_REJECTED]:
			rejected.append("%s:%s" % [entry[NpcUtilityDecider.KEY_ACTION_ID], entry[NpcUtilityDecider.KEY_CODE]])
		signatures.append("%d %s #%d @%d [%s] %s -> %s/%s %s hard=%s done=%s fail=%s best=%s no=%s" % [
			tick, npc_id, int(record[NpcUtilityDecider.KEY_SEQUENCE]), int(record[NpcUtilityDecider.KEY_AT_USEC]),
			",".join(PackedStringArray(record[NpcUtilityDecider.KEY_REASONS])),
			">".join(PackedStringArray(record[NpcUtilityDecider.KEY_PATH])),
			str(record[NpcUtilityDecider.KEY_CHOSEN]), str(record[NpcUtilityDecider.KEY_OUTCOME]),
			"fallback" if bool(record[NpcUtilityDecider.KEY_FALLBACK]) else "-",
			str(record[NpcUtilityDecider.KEY_HARD_INTERRUPT]), str(record[NpcUtilityDecider.KEY_COMPLETED]),
			str((record[NpcUtilityDecider.KEY_FAILURE] as Dictionary).get(NpcUtilityDecider.KEY_CODE, "")),
			",".join(candidates), ",".join(rejected)])


var _cell_settings: WorldCellSettings = null
var _schedule: NpcScheduleSettings = null
var _zombie: ZombieSettings = null
var _needs: NpcNeedSettings = null
var _settings: NpcDecisionSettings = null
var _catalog: NpcActionCatalog = null
var _stub: StubExecutor = null
var _decider: NpcUtilityDecider = null
var _log: Log = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_cell_settings = WorldCellSettings.new()
	_cell_settings.cell_size_m = 10.0
	_cell_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_cell_settings.bounds_max_m = Vector2(50.0, 50.0)
	_cell_settings.active_radius_cells = 1
	_cell_settings.preload_radius_cells = 2
	_cell_settings.preload_lookahead_sec = 0.0
	_cell_settings.deactivate_delay_sec = 0.0
	_cell_settings.unload_delay_sec = 0.5
	_cell_settings.refresh_period_sec = 0.0
	_cell_settings.max_preload_loads_per_refresh = 1000
	_schedule = NpcScheduleSettings.new()
	_schedule.decision_near_period_sec = 1.0
	_schedule.decision_far_period_sec = 4.0
	_schedule.decision_bucket_count = 5
	_schedule.max_decisions_per_tick = 8
	_schedule.near_radius_m = 8.0
	_schedule.near_exit_margin_m = 1.0
	_schedule.tier_period_sec = 0.5
	# Zombies that stand where they are put.
	_zombie = ZombieSettings.new()
	_zombie.dev_spawn_count = 0
	_zombie.ai_period_sec = 1000.0
	_zombie.wander_pause_min_sec = NEVER
	_zombie.wander_pause_max_sec = NEVER
	# Needs that do not move by themselves (the tests set them).
	_needs = NpcNeedSettings.new()
	_needs.hunger_hours_to_max = 100000.0
	_needs.thirst_hours_to_max = 100000.0
	_needs.fatigue_hours_to_max = 100000.0
	# Plain rules: no jitter, no minimum duration, no fallback, no flee action
	# unless a test asks for them.
	_settings = NpcDecisionSettings.new()
	_settings.score_jitter = 0.0
	_settings.default_min_duration_sec = 0.0
	_settings.fallback_action_id = ""
	_settings.flee_action_id = FLEE
	_catalog = NpcActionCatalog.new()
	_stub = null
	_decider = null
	_log = null


func after_each() -> void:
	GameLogger.set_capture(false)
	_stub = null
	_decider = null
	_log = null


# ------------------------------------------------------------ helpers

func _action(action_id: String, base: float, fixed_priority: int = 0) -> NpcActionDefinition:
	var action: NpcActionDefinition = NpcActionDefinition.new()
	action.action_id = action_id
	action.base_priority = base
	action.fixed_priority = fixed_priority
	return action


func _need_action(action_id: String, kind: String, weight: float = 1.0) -> NpcActionDefinition:
	var action: NpcActionDefinition = _action(action_id, 0.0)
	action.need_kind = kind
	action.need_weight = weight
	return action


func _add(action: NpcActionDefinition) -> NpcActionDefinition:
	assert_eq(_catalog.add(action), OK, "test setup: action %s" % action.action_id)
	return action


func _config(decider: NpcDecider) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# F-31: no social layer here, so the NPCs take no notice of the players
	# (noticing and talking are tested in the F-31 tests).
	config.npc_social = null
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.player_noise = PlayerNoiseSettings.new()
	config.player_noise.footstep_loudness = 0.0
	config.zombie = _zombie
	config.dev_seed = DevWorldSeed.new()
	config.building = BuildingSettings.new()
	config.world_cells = _cell_settings
	config.npc = NpcSettings.new()
	config.npc_definitions = NpcCatalog.new()
	var worker: NpcDefinition = NpcDefinition.new()
	worker.definition_id = WORKER
	worker.display_name = "일꾼"
	worker.job_role = "farming"
	worker.work_building_id = "t44_farm"
	worker.conscientiousness = 0.8
	config.npc_definitions.add(worker)
	var drifter: NpcDefinition = NpcDefinition.new()
	drifter.definition_id = DRIFTER
	drifter.display_name = "떠돌이"
	config.npc_definitions.add(drifter)
	for entry: Array in [[LARK, "아침형", LARK_BEDTIME], [OWL, "저녁형", OWL_BEDTIME]]:
		var sleeper: NpcDefinition = NpcDefinition.new()
		sleeper.definition_id = str(entry[0])
		sleeper.display_name = str(entry[1])
		sleeper.bedtime_hour = float(entry[2])
		config.npc_definitions.add(sleeper)
	config.npc_needs = _needs
	config.npc_schedule = _schedule
	config.npc_decision = _settings
	config.npc_actions = _catalog
	config.npc_decider = decider
	return config


## A world whose NPCs decide with a new NpcUtilityDecider on a new stub
## executor (kept in _decider, _stub, _log).
func _world() -> ServerWorld:
	_stub = StubExecutor.new()
	_decider = NpcUtilityDecider.new(_settings, _catalog, _needs, _stub)
	_log = Log.new()
	_decider.decided.connect(_log.on_decided)
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config(_decider))
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	_stub.npcs_ref = weakref(_npcs(world))
	return world


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _run(world: ServerWorld, ticks: int, delta: float = TICK) -> void:
	for index: int in range(ticks):
		_log.tick += 1
		world.step_systems(delta)


func _spawn(world: ServerWorld, definition_id: String, position: Vector3) -> String:
	var spawned: ActionResult = _npcs(world).spawn_npc(world, definition_id, position)
	if not spawned.ok:
		fail("test setup: npc refused: " + spawned.reason)
		return ""
	return str(spawned.event.get(NpcService.KEY_NPC_ID, ""))


## A world with a player at SPAWN and one NPC of `definition_id` at
## NPC_SPOT: {world, id}.
func _start(definition_id: String = DRIFTER) -> Dictionary:
	var world: ServerWorld = _world()
	world.join("alice")
	world.step_systems(TICK)
	return {"world": world, "id": _spawn(world, definition_id, NPC_SPOT)}


func _state(world: ServerWorld, npc_id: String) -> NpcDecisionComponent:
	return _npcs(world).get_npc(npc_id).component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent


func _need_values(world: ServerWorld, npc_id: String) -> NpcNeeds:
	return _npcs(world).get_npc(npc_id).component(NpcNeeds.COMPONENT_ID) as NpcNeeds


## Sets the three needs of an NPC (0..1 of the maximum), as of now.
func _set_needs(world: ServerWorld, npc_id: String, hunger: float, thirst: float, fatigue: float) -> void:
	var needs: NpcNeeds = _need_values(world, npc_id)
	var document: Dictionary = needs.to_document()
	var values: Dictionary = {NpcNeedKind.HUNGER: hunger * _needs.need_max, NpcNeedKind.THIRST: thirst * _needs.need_max, NpcNeedKind.FATIGUE: fatigue * _needs.need_max}
	document[NpcComponent.KEY_SCHEMA_VERSION] = NpcNeeds.SCHEMA_VERSION
	document[NpcNeeds.KEY_VALUES] = values
	document[NpcNeeds.KEY_SEGMENT_VALUES] = values.duplicate()
	document[NpcNeeds.KEY_LAST_UPDATED] = world.clock.world_time_sec
	document[NpcNeeds.KEY_SEGMENT_STARTED] = world.clock.world_time_sec
	var errors: PackedStringArray = needs.restore_document(document)
	assert_eq(errors.size(), 0, "test setup: needs: %s" % ", ".join(errors))


## Asks for a decision of `npc_id` and runs the tick in which it is made.
## Returns its record.
func _decide_now(world: ServerWorld, npc_id: String, reason: String = POKE) -> Dictionary:
	var before: int = _state(world, npc_id).decision_count
	assert_true(_decider.scheduler().request_interrupt(npc_id, reason), "test setup: interrupt %s" % reason)
	_run(world, 1)
	assert_eq(_state(world, npc_id).decision_count, before + 1, "one decision in the next tick")
	return _state(world, npc_id).last_record()


func _report(world: ServerWorld, npc_id: String, reason: String) -> Dictionary:
	return _decide_now(world, npc_id, reason)


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


func _candidate(record: Dictionary, action_id: String) -> Dictionary:
	for candidate: Dictionary in record[NpcUtilityDecider.KEY_CANDIDATES]:
		if str(candidate[NpcUtilityScorer.KEY_ACTION_ID]) == action_id:
			return candidate
	return {}


func _rejection(record: Dictionary, action_id: String) -> String:
	for entry: Dictionary in record[NpcUtilityDecider.KEY_REJECTED]:
		if str(entry[NpcUtilityDecider.KEY_ACTION_ID]) == action_id:
			return str(entry[NpcUtilityDecider.KEY_CODE])
	return ""


func _path(record: Dictionary) -> String:
	return ">".join(PackedStringArray(record.get(NpcUtilityDecider.KEY_PATH, [])))


func _place_wall(world: ServerWorld, x: int, z_from: int, z_to: int) -> void:
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	for z: int in range(z_from, z_to + 1):
		var placed: ActionResult = building.place_structure(world, WALL, Vector2i(x, z), 3)
		assert_true(placed.ok, "test setup: wall at %d,%d: %s" % [x, z, placed.reason])
		if placed.ok:
			assert_true(building.complete_structure(world, str(placed.event[BuildingService.KEY_STRUCTURE_ID])).ok)


func _spawn_zombie(world: ServerWorld, position: Vector3) -> String:
	var spawned: ActionResult = _zombies(world).spawn_zombie(world, position)
	assert_true(spawned.ok, "test setup: zombie: %s" % spawned.reason)
	return str(spawned.event.get("zombie_id", ""))


# ------------------------------------------------------------ data

func test_the_shipped_actions_and_settings_are_valid_and_bad_data_is_refused() -> void:
	var shipped: NpcDecisionSettings = NpcDecisionSettings.load_or_default()
	var actions: NpcActionCatalog = NpcActionCatalog.load_directory()
	assert_eq(shipped.validate().size(), 0, ", ".join(shipped.validate()))
	assert_eq(shipped.validate_against(actions).size(), 0, ", ".join(shipped.validate_against(actions)))
	# F-29 added fight, scavenge and treat to the seven of Phase 4, F-30
	# relocate, F-31 meet.
	assert_eq(actions.action_ids(), PackedStringArray([DRINK, EAT, "fight", FLEE, "meet", "relocate", REST, "scavenge", SLEEP, "treat", WANDER, WORK]), "the twelve actions, sorted")
	assert_false(actions.get_action(FLEE).selectable, "only the hard interrupt starts the flee action")
	assert_false(actions.get_action("fight").selectable, "only the hard interrupt starts the fight action")
	assert_eq(shipped.fallback_action_id, WANDER)
	assert_eq(shipped.flee_action_id, FLEE)
	assert_eq(shipped.fight_action_id, "fight")
	for action_id: String in actions.action_ids():
		# The actions of Phase 4 draw a number each, the later ones none: adding
		# an action does not change what an older world's NPCs draw.
		assert_eq(actions.get_action(action_id).draws_jitter, [DRINK, EAT, FLEE, REST, SLEEP, WANDER, WORK].has(action_id), "jitter of %s" % action_id)
	var config_errors: PackedStringArray = CompositionConfig.from_defaults().validate()
	assert_eq(config_errors.size(), 0, ", ".join(config_errors))
	# What other players may see is the list the wire knows.
	assert_eq(NpcActionDefinition.LABELS, NpcNetProtocol.ACTION_LABELS)
	for action_id: String in actions.action_ids():
		assert_true(NpcNetProtocol.ACTION_LABELS.has(actions.get_action(action_id).observable_label))
		assert_true(NpcNetProtocol.ACTION_LABELS.has(actions.get_action(action_id).navigate_label))
	# Bad settings.
	var bad: NpcDecisionSettings = NpcDecisionSettings.new()
	bad.current_action_bonus = 1.5
	bad.threat_check_period_sec = 0.0
	bad.retry_cooldown_sec = 20.0
	bad.retry_cooldown_max_sec = 5.0
	bad.fallback_action_id = "Not An Id"
	assert_eq(bad.validate().size(), 3, ", ".join(bad.validate()))
	bad = NpcDecisionSettings.new()
	bad.retry_cooldown_sec = 20.0
	bad.retry_cooldown_max_sec = 5.0
	assert_eq(bad.validate().size(), 1)
	bad = NpcDecisionSettings.new()
	bad.fallback_action_id = "nap"
	assert_eq(bad.validate().size(), 0)
	assert_eq(bad.validate_against(actions).size(), 1, "the fallback must be an action")
	# Bad actions.
	var action: NpcActionDefinition = _action("Bad Id", 0.5)
	assert_eq(action.validate().size(), 1)
	action = _action("nap", 1.5)
	action.need_weight = 0.5
	action.observable_label = "dance"
	action.personality_traits = {"courage": 2.0, "luck": 0.5}
	action.active_from_hour = 8.0
	action.min_duration_sec = -3.0
	assert_eq(action.validate().size(), 7, ", ".join(action.validate()))
	assert_eq(NpcActionCatalog.new().add(action), ERR_INVALID_DATA)
	var twice: NpcActionCatalog = NpcActionCatalog.new()
	assert_eq(twice.add(_action("nap", 0.5)), OK)
	assert_eq(twice.add(_action("nap", 0.2)), ERR_ALREADY_EXISTS)


func test_the_state_machine_allows_only_its_transitions() -> void:
	assert_eq(NpcDecisionState.ALL, PackedStringArray(["idle", "evaluate", "plan", "navigate", "perform", "interrupt", "recover"]))
	var allowed: Dictionary = {
		"idle": ["evaluate", "interrupt"],
		"evaluate": ["idle", "plan", "navigate", "perform", "interrupt"],
		"plan": ["navigate", "recover"],
		"navigate": ["perform", "evaluate", "interrupt", "idle"],
		"perform": ["evaluate", "interrupt", "idle"],
		"interrupt": ["plan", "recover", "idle"],
		"recover": ["evaluate", "interrupt"],
	}
	for from: String in NpcDecisionState.ALL:
		for to: String in NpcDecisionState.ALL:
			assert_eq(NpcDecisionState.can_transition(from, to), (allowed[from] as Array).has(to), "%s -> %s" % [from, to])
	assert_false(NpcDecisionState.can_transition("sleepwalk", "idle"))
	# The component refuses and counts what is not allowed.
	var state: NpcDecisionComponent = NpcDecisionComponent.new(_catalog)
	assert_false(state.transition(NpcDecisionState.PERFORM), "idle -> perform")
	assert_eq(state.state, NpcDecisionState.IDLE)
	assert_eq(state.illegal_transition_count, 1)
	assert_true(state.transition(NpcDecisionState.EVALUATE))
	assert_true(state.transition(NpcDecisionState.PLAN))
	assert_true(state.transition(NpcDecisionState.NAVIGATE))
	assert_eq(state.illegal_transition_count, 1)


func test_every_term_of_the_score_is_clamped_to_0_1() -> void:
	# Term values.
	assert_eq(NpcUtilityScorer.need_urgency(250.0, 100.0), 1.0)
	assert_eq(NpcUtilityScorer.need_urgency(-5.0, 100.0), 0.0)
	assert_eq(NpcUtilityScorer.need_urgency(40.0, 100.0), 0.4)
	assert_eq(NpcUtilityScorer.need_urgency(40.0, 0.0), 0.0)
	assert_eq(NpcUtilityScorer.need_urgency(NAN, 100.0), 0.0)
	assert_eq(NpcUtilityScorer.personality_fit({"courage": 0.8}, {}), 0.0, "no weights, no term")
	assert_eq(NpcUtilityScorer.personality_fit({"courage": 0.8}, {"courage": 1.0}), 0.8)
	assert_eq(NpcUtilityScorer.personality_fit({"courage": 0.8}, {"courage": -1.0}), 1.0 - 0.8, "a negative weight counts 1 - trait")
	assert_eq(NpcUtilityScorer.personality_fit({"courage": 7.0, "openness": -3.0}, {"courage": 50.0, "openness": 1.0}), 0.5, "traits and weights out of range are clamped")
	assert_eq(NpcUtilityScorer.personality_fit({}, {"courage": 1.0}), 0.5, "an unknown trait is the middle")
	# The window of the day.
	assert_eq(NpcUtilityScorer.hour_of_day(86400.0 * 3.0 + 3600.0 * 7.5, 86400.0), 7.5)
	assert_true(NpcUtilityScorer.in_window(9.0, 8.0, 18.0))
	assert_false(NpcUtilityScorer.in_window(18.0, 8.0, 18.0), "the end is outside")
	assert_true(NpcUtilityScorer.in_window(23.0, 22.0, 6.0), "through midnight")
	assert_true(NpcUtilityScorer.in_window(5.9, 22.0, 6.0))
	assert_false(NpcUtilityScorer.in_window(12.0, 22.0, 6.0))
	var windowed: NpcActionDefinition = _action("windowed", 0.0)
	assert_eq(NpcUtilityScorer.environment_fit(windowed, 9.0), 0.0, "no window, no term")
	windowed.active_from_hour = 8.0
	windowed.active_until_hour = 18.0
	assert_eq(NpcUtilityScorer.environment_fit(windowed, 9.0), 1.0)
	assert_eq(NpcUtilityScorer.environment_fit(windowed, 19.0), 0.0)
	# The sum: data that is far out of range (it would not pass validate())
	# still gives every term 0..1 and the score at most 6 + bonus + jitter.
	var wild: NpcActionDefinition = _action("wild", 9.0)
	wild.need_weight = 40.0
	wild.personality_weight = -3.0
	wild.environment_weight = 7.0
	wild.relationship_weight = 5.0
	wild.memory_weight = INF
	var loose: NpcDecisionSettings = NpcDecisionSettings.new()
	loose.current_action_bonus = 4.0
	loose.score_jitter = 9.0
	var scored: Dictionary = NpcUtilityScorer.score(wild, loose, 33.0, -2.0, 5.0, 8.0, NAN, true, 77.0)
	for term: String in NpcUtilityScorer.TERMS:
		for key: String in [NpcUtilityScorer.KEY_VALUES, NpcUtilityScorer.KEY_TERMS]:
			var value: float = float(scored[key][term])
			assert_true(value >= 0.0 and value <= 1.0, "%s.%s = %f" % [key, term, value])
	assert_eq(scored[NpcUtilityScorer.KEY_TERMS], {"base": 1.0, "need": 1.0, "personality": 0.0, "environment": 1.0, "relationship": 1.0, "memory": 0.0, "commitment": 1.0, "jitter": 1.0})
	assert_eq(float(scored[NpcUtilityScorer.KEY_SCORE]), 6.0)
	# The documented sum, with ordinary numbers.
	var plain: NpcActionDefinition = _action("plain", 0.25)
	plain.need_weight = 0.5
	plain.personality_weight = 0.2
	plain.environment_weight = 0.3
	var strict: NpcDecisionSettings = NpcDecisionSettings.new()
	strict.current_action_bonus = 0.15
	strict.score_jitter = 0.1
	scored = NpcUtilityScorer.score(plain, strict, 0.6, 0.5, 1.0, 0.9, 0.9, true, 0.5)
	assert_true(absf(float(scored[NpcUtilityScorer.KEY_SCORE]) - (0.25 + 0.5 * 0.6 + 0.2 * 0.5 + 0.3 * 1.0 + 0.0 + 0.0 + 0.15 + 0.1 * 0.5)) < 1.0e-12, "score %f" % float(scored[NpcUtilityScorer.KEY_SCORE]))
	assert_eq(float(scored[NpcUtilityScorer.KEY_TERMS]["relationship"]), 0.0, "weight 0: Phase 5")
	assert_eq(float(scored[NpcUtilityScorer.KEY_VALUES]["relationship"]), 0.9)


func test_a_decision_component_saves_what_it_holds_and_refuses_a_broken_document() -> void:
	var state: NpcDecisionComponent = NpcDecisionComponent.new(_catalog)
	assert_eq(state.component_id(), "decision")
	state.state = NpcDecisionState.PERFORM
	state.set_action(EAT, {"spot": [1.5, 0.0, 2.5]}, 4000000)
	state.set_cooldown(WORK, 9000000)
	state.note_failure(WORK, "no_path", 3000000)
	state.note_failure(WORK, "no_path", 3500000)
	state.decision_count = 12
	var document: Dictionary = _json(state.to_document())
	document[NpcComponent.KEY_SCHEMA_VERSION] = NpcDecisionComponent.SCHEMA_VERSION
	assert_true(SaveService.is_json_safe(state.to_document()))
	var restored: NpcDecisionComponent = NpcDecisionComponent.new(_catalog)
	assert_eq(restored.restore_document(document).size(), 0, ", ".join(restored.restore_document(document)))
	assert_eq(_json(restored.to_document()), _json(state.to_document()))
	assert_eq(restored.state, NpcDecisionState.PERFORM)
	assert_eq(restored.action_id, EAT)
	assert_eq(restored.action_started_at_usec, 4000000)
	assert_eq(restored.cooldown_until(WORK), 9000000)
	assert_true(restored.is_on_cooldown(WORK, 8999999))
	assert_false(restored.is_on_cooldown(WORK, 9000000))
	assert_eq(restored.failures, {WORK: 2} as Dictionary[String, int])
	assert_eq(restored.last_failure, {"action_id": WORK, "code": "no_path", "at_usec": 3500000})
	assert_eq(restored.decision_count, 12)
	# Broken documents change nothing.
	var breakers: Array[Callable] = [
		func(d: Dictionary) -> void: d[NpcComponent.KEY_SCHEMA_VERSION] = NpcDecisionComponent.SCHEMA_VERSION + 1,
		func(d: Dictionary) -> void: d["state"] = "evaluate",
		func(d: Dictionary) -> void: d["state"] = "idle",
		func(d: Dictionary) -> void: d["action_id"] = "",
		func(d: Dictionary) -> void: d["action_id"] = "Eat!",
		func(d: Dictionary) -> void: d["action_started_at_usec"] = -1,
		func(d: Dictionary) -> void: d["action_started_at_usec"] = 1.5,
		func(d: Dictionary) -> void: d["recover_until_usec"] = 5,
		func(d: Dictionary) -> void: d["cooldowns"] = {"work": -4},
		func(d: Dictionary) -> void: d["failures"] = {"work": 0},
		func(d: Dictionary) -> void: d["last_failure"] = {"action_id": "work"},
		func(d: Dictionary) -> void: d["target"] = "there",
		func(d: Dictionary) -> void: d.erase("decision_count"),
	]
	for index: int in range(breakers.size()):
		var broken: Dictionary = document.duplicate(true)
		breakers[index].call(broken)
		var fresh: NpcDecisionComponent = NpcDecisionComponent.new(_catalog)
		assert_true(fresh.restore_document(broken).size() > 0, "broken document %d is refused" % index)
		assert_eq(fresh.state, NpcDecisionState.IDLE, "broken document %d changes nothing" % index)
		assert_eq(fresh.decision_count, 0)


# ------------------------------------------------------------ the default composition

func test_without_an_executor_the_default_decider_decides_nothing() -> void:
	# The composition's own decider (config.npc_decider null), the shipped
	# actions and settings: without an executor NPCs stand. Since P4-5b the
	# behaviour layer gives it one, so this composition has no such layer.
	_settings = NpcDecisionSettings.load_or_default()
	_catalog = NpcActionCatalog.load_directory()
	var config: CompositionConfig = _config(null)
	config.npc_behaviour = null
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	world.join("alice")
	world.step_systems(TICK)
	var npc_id: String = _spawn(world, WORKER, NPC_SPOT)
	var npc: NpcState = _npcs(world).get_npc(npc_id)
	assert_true(npc.component_ids().has(NpcDecisionComponent.COMPONENT_ID), "every NPC has the decision component")
	var state: NpcDecisionComponent = npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent
	var before: Dictionary = _json(state.to_document())
	var rng_before: int = npc.rng.state
	assert_true(_zombies(world).spawn_zombie(world, NPC_SPOT + Vector3(0.0, 0.0, 3.0)).ok, "a zombie right beside it")
	for tick: int in range(100):
		world.step_systems(TICK)
	assert_eq(_json(state.to_document()), before, "nothing was decided")
	assert_eq(state.records().size(), 0)
	assert_eq(npc.rng.state, rng_before)
	assert_eq(NpcDecisionComponent.label_of(npc), "idle")
	assert_eq(NpcDecisionComponent.label_of(null), "idle")


# ------------------------------------------------------------ the utility choice

func test_a_hungry_npc_chooses_to_eat_and_the_record_says_why() -> void:
	_settings = NpcDecisionSettings.load_or_default()
	_catalog = NpcActionCatalog.load_directory()
	var started: Dictionary = _start(DRIFTER)
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	var npc: NpcState = _npcs(world).get_npc(npc_id)
	_set_needs(world, npc_id, 0.7, 0.1, 0.05)
	var record: Dictionary = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], EAT)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_STARTED)
	assert_eq(_path(record), "idle>evaluate>plan>navigate")
	assert_eq(record[NpcUtilityDecider.KEY_STATE_BEFORE], "idle")
	assert_eq(record[NpcUtilityDecider.KEY_STATE_AFTER], "navigate")
	assert_eq(record[NpcUtilityDecider.KEY_ACTION_AFTER], EAT)
	assert_true((record[NpcUtilityDecider.KEY_REASONS] as Array).has(POKE))
	assert_eq(_stub.begun, PackedStringArray(["%s %s" % [npc_id, EAT]]), "the executor was asked once")
	assert_eq(_stub.targets[0], {}, "the executor finds the place")
	# The candidates, best first, with their terms.
	var candidates: Array = record[NpcUtilityDecider.KEY_CANDIDATES]
	assert_eq(candidates.size(), 2, "eat and wander")
	assert_eq(candidates[0][NpcUtilityScorer.KEY_ACTION_ID], EAT)
	assert_eq(candidates[1][NpcUtilityScorer.KEY_ACTION_ID], WANDER)
	var eat: Dictionary = candidates[0]
	assert_true(absf(float(eat[NpcUtilityScorer.KEY_VALUES]["need"]) - 0.7) < 0.001, "need term %f" % float(eat[NpcUtilityScorer.KEY_VALUES]["need"]))
	var sum: float = 0.0
	for term: String in NpcUtilityScorer.TERMS:
		assert_true((eat[NpcUtilityScorer.KEY_TERMS] as Dictionary).has(term), "the record has the term %s" % term)
		sum += float(eat[NpcUtilityScorer.KEY_TERMS][term])
	assert_true(absf(sum - float(eat[NpcUtilityScorer.KEY_SCORE])) < 1.0e-12, "the score is the sum of its terms")
	assert_eq(float(eat[NpcUtilityScorer.KEY_VALUES]["relationship"]), 0.0, "Phase 5")
	assert_eq(float(eat[NpcUtilityScorer.KEY_VALUES]["memory"]), 0.0, "Phase 5")
	assert_true(float(eat[NpcUtilityScorer.KEY_TERMS]["jitter"]) <= _settings.score_jitter)
	# Why the others are no candidates.
	assert_eq(_rejection(record, DRINK), NpcUtilityDecider.REJECT_NEED_LOW)
	assert_eq(_rejection(record, REST), NpcUtilityDecider.REJECT_NEED_LOW)
	assert_eq(_rejection(record, SLEEP), NpcUtilityDecider.REJECT_NEED_LOW, "it is night, but it is not tired at all")
	assert_eq(_rejection(record, WORK), NpcUtilityDecider.REJECT_NO_JOB)
	assert_eq(_rejection(record, FLEE), NpcUtilityDecider.REJECT_NOT_SELECTABLE)
	# On the way it "walks"; where the food is it "eats".
	assert_eq(NpcDecisionComponent.label_of(npc), "walk")
	record = _report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	assert_eq(_state(world, npc_id).state, "perform")
	assert_eq(NpcDecisionComponent.label_of(npc), "eat")
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_MIN_DURATION, "eating has just begun")
	assert_eq(_path(record), "navigate>perform")
	# Done: it is idle and chooses again at once (it is not hungry now).
	assert_true(_need_values(world, npc_id).satisfy(NpcNeedKind.HUNGER, 60.0, "t44_meal").ok)
	record = _report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(record[NpcUtilityDecider.KEY_COMPLETED], EAT)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], WANDER)
	assert_eq(_path(record), "perform>idle>evaluate>plan>navigate")
	assert_eq(_rejection(record, EAT), NpcUtilityDecider.REJECT_NEED_LOW)
	assert_eq(NpcDecisionComponent.label_of(npc), "walk")
	record = _report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	assert_eq(NpcDecisionComponent.label_of(npc), "idle", "wandering looks like idling once it stands")
	assert_eq(_stub.cancelled.size(), 0)
	assert_eq(_state(world, npc_id).illegal_transition_count, 0)
	# Every term of every record is within 0..1.
	for logged: Dictionary in _log.records:
		for candidate: Dictionary in logged[NpcUtilityDecider.KEY_CANDIDATES]:
			for term: String in NpcUtilityScorer.TERMS:
				var value: float = float(candidate[NpcUtilityScorer.KEY_VALUES][term])
				assert_true(value >= 0.0 and value <= 1.0)
	assert_true(SaveService.is_json_safe(record), "a record is JSON-safe")


func test_ties_are_broken_by_score_then_fixed_priority_then_action_id() -> void:
	_add(_action("alpha", 0.3, 1))
	_add(_action("charlie", 0.3, 5))
	_add(_action("bravo", 0.3, 5))
	var started: Dictionary = _start()
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	var record: Dictionary = _decide_now(world, npc_id)
	var order: PackedStringArray = []
	for candidate: Dictionary in record[NpcUtilityDecider.KEY_CANDIDATES]:
		order.append(str(candidate[NpcUtilityScorer.KEY_ACTION_ID]))
		assert_eq(float(candidate[NpcUtilityScorer.KEY_SCORE]), 0.3, "the same score")
	assert_eq(order, PackedStringArray(["bravo", "charlie", "alpha"]), "priority 5 before 1, then the id")
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "bravo")
	# The score comes before the fixed priority.
	_catalog = NpcActionCatalog.new()
	_add(_action("alpha", 0.31, 0))
	_add(_action("bravo", 0.3, 9))
	started = _start()
	record = _decide_now(started["world"], started["id"])
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "alpha")
	# The comparison itself.
	var low: Dictionary = {"score": 0.5, "fixed_priority": 9, "action_id": "a"}
	var high: Dictionary = {"score": 0.6, "fixed_priority": 0, "action_id": "z"}
	assert_true(NpcUtilityScorer.is_better(high, low))
	assert_false(NpcUtilityScorer.is_better(low, high))
	assert_false(NpcUtilityScorer.is_better(low, low), "nothing comes before itself")


func test_jitter_comes_from_the_npcs_own_generator_only() -> void:
	_settings.score_jitter = 0.2
	_add(_action("alpha", 0.3))
	_add(_action("bravo", 0.3))
	var blocked: NpcActionDefinition = _action("charlie", 0.3)
	blocked.requires_job = true
	_add(blocked)
	var started: Dictionary = _start()
	var world: ServerWorld = started["world"]
	var npc: NpcState = _npcs(world).get_npc(started["id"])
	# The same numbers the NPC's generator gives next: one per action of the
	# catalog in id order, candidate or not.
	var twin: RandomNumberGenerator = RandomNumberGenerator.new()
	twin.seed = npc.rng.seed
	twin.state = npc.rng.state
	var expected: PackedFloat64Array = [twin.randf(), twin.randf(), twin.randf()]
	var record: Dictionary = _decide_now(world, started["id"])
	assert_eq(float(_candidate(record, "alpha")[NpcUtilityScorer.KEY_VALUES]["jitter"]), expected[0])
	assert_eq(float(_candidate(record, "bravo")[NpcUtilityScorer.KEY_VALUES]["jitter"]), expected[1])
	assert_eq(_rejection(record, "charlie"), NpcUtilityDecider.REJECT_NO_JOB)
	assert_eq(npc.rng.state, twin.state, "three numbers were drawn, whatever the preconditions")
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "alpha" if expected[0] > expected[1] else "bravo")


func test_the_running_action_is_kept_against_a_slightly_better_one() -> void:
	# Without the bonus the NPC flips at once; with it, only a candidate that
	# is better by more than the bonus replaces what it does.
	for bonus: float in [0.0, 0.15]:
		_settings = _settings.duplicate() as NpcDecisionSettings
		_settings.current_action_bonus = bonus
		_catalog = NpcActionCatalog.new()
		_add(_need_action("feed", NpcNeedKind.HUNGER))
		_add(_action("idle_work", 0.5))
		var started: Dictionary = _start()
		var world: ServerWorld = started["world"]
		var npc_id: String = started["id"]
		_set_needs(world, npc_id, 0.6, 0.0, 0.0)
		assert_eq(_decide_now(world, npc_id)[NpcUtilityDecider.KEY_CHOSEN], "feed", "0.6 against 0.5")
		_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
		# A little worse than the other now: 0.45 against 0.5.
		_set_needs(world, npc_id, 0.45, 0.0, 0.0)
		var record: Dictionary = _decide_now(world, npc_id)
		if bonus == 0.0:
			assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "idle_work", "no bonus: it flips")
			assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_SWITCHED)
			continue
		assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "feed")
		assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_KEPT)
		assert_eq(_path(record), "perform>evaluate>perform")
		assert_eq(float(_candidate(record, "feed")[NpcUtilityScorer.KEY_TERMS]["commitment"]), 0.15)
		assert_eq(float(_candidate(record, "idle_work")[NpcUtilityScorer.KEY_TERMS]["commitment"]), 0.0)
		# The need wobbles around the other's score for 20 s: no flip-flop.
		for step: int in range(40):
			_set_needs(world, npc_id, 0.45 if step % 2 == 0 else 0.55, 0.0, 0.0)
			_run(world, 10)
		assert_eq(_stub.begun.size(), 1, "one action was begun in all that time: %s" % ", ".join(_stub.begun))
		assert_eq(_stub.cancelled.size(), 0)
		assert_true(_state(world, npc_id).decision_count > 20, "it did think: %d decisions" % _state(world, npc_id).decision_count)
		# Better by more than the bonus: 0.3 + 0.15 < 0.5.
		_set_needs(world, npc_id, 0.3, 0.0, 0.0)
		record = _decide_now(world, npc_id)
		assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "idle_work")
		assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_SWITCHED)
		assert_eq(_path(record), "perform>evaluate>interrupt>plan>navigate")
		assert_eq(_stub.cancelled, PackedStringArray([npc_id]), "the executor was told to stop the old action")
		# And it does not flip back when the need is what it was.
		_set_needs(world, npc_id, 0.6, 0.0, 0.0)
		record = _decide_now(world, npc_id)
		assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "idle_work", "0.6 against 0.5 + 0.15")
		assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_KEPT)
		assert_eq(_state(world, npc_id).illegal_transition_count, 0)


func test_an_action_is_not_replaced_before_its_minimum_duration() -> void:
	var feed: NpcActionDefinition = _need_action("feed", NpcNeedKind.HUNGER)
	feed.min_duration_sec = 3.0
	_add(feed)
	_add(_action("idle_work", 0.5))
	var started: Dictionary = _start()
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	_set_needs(world, npc_id, 0.8, 0.0, 0.0)
	var record: Dictionary = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "feed")
	var started_at: int = int(record[NpcUtilityDecider.KEY_AT_USEC])
	assert_eq(_state(world, npc_id).action_started_at_usec, started_at)
	# The other action is far better at once.
	_set_needs(world, npc_id, 0.0, 0.0, 0.0)
	record = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_MIN_DURATION)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "feed")
	assert_eq(_path(record), "navigate", "the candidates were not even looked at")
	assert_eq((record[NpcUtilityDecider.KEY_CANDIDATES] as Array).size(), 0)
	_run(world, 100)
	assert_eq(_state(world, npc_id).action_id, "idle_work", "after the minimum it is replaced")
	var switched_at: int = -1
	for logged: Dictionary in _log.records:
		var age: int = int(logged[NpcUtilityDecider.KEY_AT_USEC]) - started_at
		if str(logged[NpcUtilityDecider.KEY_OUTCOME]) == NpcUtilityDecider.OUTCOME_SWITCHED:
			switched_at = age
			break
		if age > 0:
			assert_eq(logged[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_MIN_DURATION, "at %d usec" % age)
	assert_true(switched_at >= 3 * USEC, "replaced %d usec after it began" % switched_at)
	assert_true(switched_at <= 4 * USEC + USEC / 10, "at the first turn after the minimum (period 1 s): %d usec" % switched_at)
	assert_eq(_stub.cancelled.size(), 1)
	assert_eq(_stub.begun.size(), 2)


## P4-Z (docs/15 P4-172): the rest was only ever a nap, because its own
## precondition (min_need_urgency) ended it as soon as the fatigue fell
## below the level that had started it.
func test_an_action_that_runs_until_done_outlives_its_own_precondition() -> void:
	var nap: NpcActionDefinition = _need_action("nap", NpcNeedKind.FATIGUE)
	nap.min_need_urgency = 0.3
	_add(nap)
	_add(_action("idle_work", 0.2))
	var flee: NpcActionDefinition = _action(FLEE, 1.0)
	flee.selectable = false
	_add(flee)
	# Without the flag (every other action): the nap ends once the need that
	# started it is below its minimum.
	var started: Dictionary = _start()
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	_set_needs(world, npc_id, 0.0, 0.0, 0.8)
	assert_eq(_decide_now(world, npc_id)[NpcUtilityDecider.KEY_CHOSEN], "nap")
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	_set_needs(world, npc_id, 0.0, 0.0, 0.29)
	var record: Dictionary = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_SWITCHED, "the default: its precondition is looked at while it runs")
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "idle_work")
	assert_eq(_rejection(record, "nap"), NpcUtilityDecider.REJECT_NEED_LOW)
	# With the flag: it goes on, whatever the need and the other candidates.
	nap.runs_until_done = true
	started = _start()
	world = started["world"]
	npc_id = started["id"]
	var state: NpcDecisionComponent = _state(world, npc_id)
	_set_needs(world, npc_id, 0.0, 0.0, 0.8)
	assert_eq(_decide_now(world, npc_id)[NpcUtilityDecider.KEY_CHOSEN], "nap")
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	_set_needs(world, npc_id, 0.0, 0.0, 0.06)
	record = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_UNTIL_DONE)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "nap")
	assert_eq(_path(record), "perform", "the candidates were not looked at")
	assert_eq((record[NpcUtilityDecider.KEY_CANDIDATES] as Array).size(), 0)
	_run(world, 200)
	assert_eq(state.action_id, "nap", "ten seconds of turns later it still runs")
	assert_eq(state.state, NpcDecisionState.PERFORM)
	assert_eq(_stub.cancelled.size(), 0)
	# Another need in the danger category: the ordinary choice decides again
	# (the nap's own precondition fails, so something else is started).
	_set_needs(world, npc_id, 0.0, 0.76, 0.06)
	record = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_SWITCHED, "thirst in danger wakes it")
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "idle_work")
	assert_eq(_stub.cancelled.size(), 1)
	# Its own need in the danger category does not (that is what it is for).
	_set_needs(world, npc_id, 0.0, 0.0, 0.9)
	_run(world, 40)
	assert_eq(state.action_id, "nap", "test setup: it naps again")
	_set_needs(world, npc_id, 0.0, 0.0, 0.76)
	assert_eq(_decide_now(world, npc_id)[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_UNTIL_DONE)
	# The executor's report ends it.
	_set_needs(world, npc_id, 0.0, 0.0, 0.0)
	record = _report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(record[NpcUtilityDecider.KEY_COMPLETED], "nap")
	assert_ne(state.action_id, "nap")
	# And so does a zombie it sees (the hard interrupt is before the choice).
	_set_needs(world, npc_id, 0.0, 0.0, 0.9)
	_run(world, 40)
	assert_eq(state.action_id, "nap", "test setup: it naps once more")
	_set_needs(world, npc_id, 0.0, 0.0, 0.06)
	_spawn_zombie(world, Vector3(2.5, 0.0, 12.5))
	_run(world, 12)
	assert_eq(state.action_id, FLEE, "a visible zombie ends the nap")
	assert_eq(state.last_record()[NpcUtilityDecider.KEY_HARD_INTERRUPT], NpcUtilityDecider.HARD_THREAT)
	# The shipped nap (rest) and night sleep are such actions; nothing else is.
	var shipped: NpcActionCatalog = NpcActionCatalog.load_directory()
	for action_id: String in shipped.action_ids():
		# (F-29: and a scavenging trip, which is not given up half way.)
		assert_eq(shipped.get_action(action_id).runs_until_done, action_id == REST or action_id == SLEEP or action_id == "scavenge" or action_id == "relocate", "shipped %s" % action_id)


func test_an_npc_without_a_candidate_falls_back_or_stands_idle() -> void:
	# No candidate at or above the minimum score, no fallback: idle.
	_settings.min_action_score = 0.2
	_add(_action("stroll", 0.1))
	var started: Dictionary = _start()
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	var record: Dictionary = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_NOTHING)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "")
	assert_eq(_path(record), "idle>evaluate>idle")
	assert_eq((record[NpcUtilityDecider.KEY_CANDIDATES] as Array).size(), 1, "the record still shows what was too weak")
	assert_eq(_stub.begun.size(), 0)
	assert_eq(NpcDecisionComponent.label_of(_npcs(world).get_npc(npc_id)), "idle")
	# With a fallback it does that instead.
	_settings = _settings.duplicate() as NpcDecisionSettings
	_settings.fallback_action_id = "stroll"
	started = _start()
	world = started["world"]
	npc_id = started["id"]
	record = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "stroll")
	assert_true(bool(record[NpcUtilityDecider.KEY_FALLBACK]))
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_STARTED)
	assert_eq(_stub.begun, PackedStringArray(["%s stroll" % npc_id]))
	# It keeps strolling; when the stroll is over it strolls again.
	record = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_KEPT)
	record = _report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(_path(record), "navigate>idle>evaluate>plan>navigate")
	assert_eq(_stub.begun.size(), 2)
	# A fallback the executor refuses: Recover, then idle while it is on
	# its cooldown.
	_stub.refuse = {"stroll": NpcActionExecutor.FAIL_NO_PATH}
	record = _report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_FAILED)
	assert_eq(_state(world, npc_id).state, "recover")
	_run(world, 40)
	assert_eq(_state(world, npc_id).state, "idle")
	record = _state(world, npc_id).last_record()
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_NOTHING)
	assert_false(bool(record[NpcUtilityDecider.KEY_FALLBACK]))
	assert_eq(_rejection(record, "stroll"), NpcUtilityDecider.REJECT_COOLDOWN)
	assert_eq(_state(world, npc_id).illegal_transition_count, 0)


func test_preconditions_keep_actions_out_of_the_candidates() -> void:
	_catalog = NpcActionCatalog.load_directory()
	var world: ServerWorld = _world()
	world.join("alice")
	world.step_systems(TICK)
	var worker: String = _spawn(world, WORKER, NPC_SPOT)
	var drifter: String = _spawn(world, DRIFTER, NPC_SPOT + Vector3(0.0, 0.0, 1.0))
	# A job: only the NPC whose definition has one works.
	var record: Dictionary = _decide_now(world, worker)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], WORK)
	assert_eq(float(_candidate(record, WORK)[NpcUtilityScorer.KEY_VALUES]["personality"]), 0.8, "conscientiousness")
	assert_eq(float(_candidate(record, WORK)[NpcUtilityScorer.KEY_VALUES]["environment"]), 0.0, "it is midnight")
	record = _decide_now(world, drifter)
	assert_eq(_rejection(record, WORK), NpcUtilityDecider.REJECT_NO_JOB)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], WANDER)
	# A need below the action's minimum is no reason to act on it.
	assert_eq(_rejection(record, EAT), NpcUtilityDecider.REJECT_NEED_LOW)
	_set_needs(world, drifter, 0.26, 0.0, 0.0)
	assert_eq(_rejection(_decide_now(world, drifter), EAT), "", "0.26 is above eat's 0.25")
	# A need in the danger category: no work (docs/13 §16.3 D3).
	_set_needs(world, worker, 0.0, 0.74, 0.0)
	record = _report(world, worker, NpcActionExecutor.REPORT_DONE)
	assert_eq(_rejection(record, WORK), "", "0.74 is caution, not danger")
	_report(world, worker, NpcActionExecutor.REPORT_DONE)
	_set_needs(world, worker, 0.0, 0.75, 0.0)
	record = _report(world, worker, NpcActionExecutor.REPORT_DONE)
	assert_eq(_rejection(record, WORK), NpcUtilityDecider.REJECT_NEED_DANGER)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], DRINK)
	assert_eq(NpcDecisionComponent.label_of(_npcs(world).get_npc(worker)), "walk")


# ------------------------------------------------------------ failures

func test_a_failure_leads_to_recover_and_a_retry_cooldown() -> void:
	_settings.recover_cooldown_sec = 1.0
	_settings.retry_cooldown_sec = 4.0
	_settings.retry_cooldown_max_sec = 6.0
	_add(_action("first", 0.5))
	_add(_action("second", 0.3))
	var started: Dictionary = _start()
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	var state: NpcDecisionComponent = _state(world, npc_id)
	var scheduler: NpcScheduler = _decider.scheduler()
	# The executor refuses to begin.
	_stub.refuse = {"first": NpcActionExecutor.FAIL_NO_PATH}
	var record: Dictionary = _decide_now(world, npc_id)
	var failed_at: int = int(record[NpcUtilityDecider.KEY_AT_USEC])
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], "first")
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_FAILED)
	assert_eq(record[NpcUtilityDecider.KEY_FAILURE], {"action_id": "first", "code": "no_path"})
	assert_eq(_path(record), "idle>evaluate>plan>recover")
	assert_eq(state.state, "recover")
	assert_eq(state.action_id, "")
	assert_eq(state.recover_until_usec, failed_at + 1 * USEC)
	assert_eq(state.cooldown_until("first"), failed_at + 4 * USEC)
	assert_eq(state.failures, {"first": 1} as Dictionary[String, int])
	assert_eq(state.last_failure, {"action_id": "first", "code": "no_path", "at_usec": failed_at})
	assert_true(absf(float((scheduler.schedule_info(npc_id)[NpcScheduler.INFO_INTERRUPTS] as Dictionary).get(NpcUtilityDecider.REASON_RECOVER_DONE, -1.0)) - 1.0) < 0.001, "the end of Recover is a timed interrupt")
	assert_eq(NpcDecisionComponent.label_of(_npcs(world).get_npc(npc_id)), "idle")
	# While it recovers it chooses nothing.
	record = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_RECOVERING)
	assert_eq(_path(record), "recover")
	assert_eq(_stub.begun.size(), 0)
	# When Recover is over it takes the next best; the failed one is out.
	_run(world, 25)
	assert_eq(state.action_id, "second")
	var chose: Dictionary = {}
	for logged: Dictionary in _log.records:
		if str(logged[NpcUtilityDecider.KEY_CHOSEN]) == "second":
			chose = logged
			break
	assert_true((chose[NpcUtilityDecider.KEY_REASONS] as Array).has(NpcUtilityDecider.REASON_RECOVER_DONE), "reasons %s" % str(chose[NpcUtilityDecider.KEY_REASONS]))
	assert_eq(int(chose[NpcUtilityDecider.KEY_AT_USEC]) - failed_at, 1 * USEC, "in the tick in which the cooldown is over")
	assert_eq(_path(chose), "recover>evaluate>plan>navigate")
	assert_eq(_rejection(chose, "first"), NpcUtilityDecider.REJECT_COOLDOWN)
	assert_eq(state.recover_until_usec, NpcDecisionComponent.NO_TIME)
	# The executor reports that the running action failed.
	record = _report(world, npc_id, NpcActionExecutor.failed_reason(NpcActionExecutor.FAIL_TARGET_GONE))
	assert_eq(record[NpcUtilityDecider.KEY_FAILURE], {"action_id": "second", "code": "target_gone"})
	assert_eq(_path(record), "navigate>interrupt>recover")
	assert_eq(_stub.cancelled.size(), 0, "a reported failure is not cancelled again")
	assert_eq(state.failures, {"first": 1, "second": 1} as Dictionary[String, int])
	# Both are out: nothing to do until the first cooldown is over.
	_run(world, 25)
	assert_eq(state.state, "idle")
	assert_eq(state.last_record()[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_NOTHING)
	# The first one fails again: its cooldown doubles, up to the maximum.
	_run(world, 60)
	assert_eq(state.failures.get("first", 0), 2, "it was tried again after 4 s")
	assert_eq(state.cooldown_until("first") - int(state.last_failure["at_usec"]), 6 * USEC, "4 s doubled is 8 s, the most is 6 s")
	# A success clears the count.
	_stub.refuse = {}
	_run(world, 140)
	assert_eq(state.action_id, "first")
	_report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_false(state.failures.has("first"))
	# The executor does not run what the NPC's state says (a save of another
	# build): the action is lost.
	assert_true(state.is_running())
	_stub.lost = true
	record = _decide_now(world, npc_id)
	assert_eq((record[NpcUtilityDecider.KEY_FAILURE] as Dictionary).get("code", ""), NpcActionExecutor.FAIL_LOST)
	assert_eq(state.state, "recover")
	_stub.lost = false
	# A failure code that is no id is replaced.
	_stub.refuse = {"first": "No Way!", "second": "no_path"}
	_run(world, 400)
	var codes: Dictionary = {}
	for logged: Dictionary in _log.records:
		codes[str((logged[NpcUtilityDecider.KEY_FAILURE] as Dictionary).get("code", ""))] = true
	assert_true(codes.has(NpcUtilityDecider.FAIL_BAD_CODE), "codes %s" % str(codes.keys()))
	assert_eq(state.illegal_transition_count, 0)


func test_the_next_need_boundary_is_a_timed_interrupt() -> void:
	# Hunger reaches "caution" (40 of 100) after 0.4 h of the calendar = 60
	# real seconds at scale 24.
	_needs.hunger_hours_to_max = 1.0
	_add(_action("stroll", 0.3))
	var started: Dictionary = _start()
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	var scheduler: NpcScheduler = _decider.scheduler()
	assert_eq(world.clock.time_scale, 24.0)
	_decide_now(world, npc_id)
	var waiting: Dictionary = scheduler.schedule_info(npc_id)[NpcScheduler.INFO_INTERRUPTS]
	assert_true(waiting.has(NpcUtilityDecider.REASON_NEED_BOUNDARY), "interrupts %s" % str(waiting))
	var created_at: float = _npcs(world).get_npc(npc_id).created_at
	var expected_sec: float = (created_at + 0.4 * 3600.0 - world.clock.world_time_sec) / 24.0 + NpcUtilityDecider.NEED_BOUNDARY_MARGIN_SEC
	assert_true(absf(float(waiting[NpcUtilityDecider.REASON_NEED_BOUNDARY]) - expected_sec) < 0.00001, "in %f s, expected %f" % [float(waiting[NpcUtilityDecider.REASON_NEED_BOUNDARY]), expected_sec])
	# When the time is up the NPC decides for that reason, in the caution
	# category, and the next boundary (danger) is scheduled.
	var first: Dictionary = {}
	for tick: int in range(700):
		_run(world, 1, 0.1)
		for index: int in range(_log.records.size() - 1, -1, -1):
			if (_log.records[index][NpcUtilityDecider.KEY_REASONS] as Array).has(NpcUtilityDecider.REASON_NEED_BOUNDARY):
				first = _log.records[index]
		if not first.is_empty():
			break
	assert_false(first.is_empty(), "a decision for the need boundary")
	assert_eq(_need_values(world, npc_id).category(NpcNeedKind.HUNGER), NpcNeedKind.Category.CAUTION)
	assert_true(absf(float(first[NpcUtilityDecider.KEY_WORLD_TIME]) - (created_at + 0.4 * 3600.0)) <= 24.0 * 0.1 * 2.0, "at the boundary: %f" % float(first[NpcUtilityDecider.KEY_WORLD_TIME]))
	waiting = scheduler.schedule_info(npc_id)[NpcScheduler.INFO_INTERRUPTS]
	assert_true(absf(float(waiting.get(NpcUtilityDecider.REASON_NEED_BOUNDARY, -1.0)) - 0.35 * 3600.0 / 24.0) < 0.3, "danger (75) is 0.35 h later: %s" % str(waiting))


# ------------------------------------------------------------ the hard interrupt

func test_a_visible_zombie_makes_a_working_npc_flee_and_a_wall_hides_it() -> void:
	_catalog = NpcActionCatalog.load_directory()
	# Its own turn is far away: only the threat sensor can make it decide.
	_schedule.decision_near_period_sec = 100.0
	_schedule.decision_far_period_sec = 100.0
	var started: Dictionary = _start(WORKER)
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	var npc: NpcState = _npcs(world).get_npc(npc_id)
	var state: NpcDecisionComponent = _state(world, npc_id)
	assert_eq(_decide_now(world, npc_id)[NpcUtilityDecider.KEY_CHOSEN], WORK)
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	assert_eq(NpcDecisionComponent.label_of(npc), "work")
	var decisions: int = state.decision_count
	# A zombie 7 m away behind a wall: not seen.
	_place_wall(world, 6, 3, 7)
	var hidden_spot: Vector3 = Vector3(9.5, 0.0, 5.5)
	assert_true(world.is_line_blocked(NPC_SPOT, hidden_spot), "test setup: the wall blocks the line")
	_spawn_zombie(world, hidden_spot)
	_run(world, 60)
	assert_eq(state.decision_count, decisions, "nothing made it decide in 3 s")
	assert_eq(state.action_id, WORK)
	var record: Dictionary = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_HARD_INTERRUPT], "")
	assert_eq(state.action_id, WORK, "it works on")
	# A zombie 7 m away with nothing in between: it flees within a check
	# period (0.5 s) and a tick, long before its turn.
	var seen_spot: Vector3 = Vector3(2.5, 0.0, 12.5)
	assert_false(world.is_line_blocked(NPC_SPOT, seen_spot), "test setup: a clear line")
	var zombie_id: String = _spawn_zombie(world, seen_spot)
	decisions = state.decision_count
	_run(world, 12)
	assert_eq(state.decision_count, decisions + 1)
	record = state.last_record()
	assert_eq(record[NpcUtilityDecider.KEY_REASONS], [NpcUtilityDecider.REASON_THREAT_SEEN])
	assert_eq(record[NpcUtilityDecider.KEY_HARD_INTERRUPT], NpcUtilityDecider.HARD_THREAT)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], FLEE)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_SWITCHED)
	assert_eq(_path(record), "perform>interrupt>plan>navigate")
	assert_eq((record[NpcUtilityDecider.KEY_CANDIDATES] as Array).size(), 0, "a hard interrupt scores nothing")
	assert_eq(_stub.cancelled, PackedStringArray([npc_id]), "work was stopped")
	assert_eq(_stub.begun[_stub.begun.size() - 1], "%s %s" % [npc_id, FLEE])
	assert_eq(_stub.targets[_stub.targets.size() - 1], {"threat_id": zombie_id, "threat_position": [2.5, 0.0, 12.5]})
	assert_eq(state.target, {"threat_id": zombie_id, "threat_position": [2.5, 0.0, 12.5]})
	assert_eq(NpcDecisionComponent.label_of(npc), "flee")
	# While it flees and the zombie is in sight, nothing else is chosen and
	# the sensor does not ask again.
	decisions = state.decision_count
	_run(world, 60)
	assert_eq(state.decision_count, decisions)
	record = _report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_KEPT)
	assert_eq(NpcDecisionComponent.label_of(npc), "flee")
	# The flight is over but the zombie is still there: it flees again.
	record = _report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(record[NpcUtilityDecider.KEY_COMPLETED], FLEE)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], FLEE)
	assert_eq(_path(record), "perform>idle>interrupt>plan>navigate")
	# The zombie is dead: after this flight it goes back to work.
	assert_true(_zombies(world).apply_damage_to_zombie(zombie_id, 1.0e6, "t44").ok)
	record = _report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(record[NpcUtilityDecider.KEY_HARD_INTERRUPT], "")
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], WORK)
	assert_eq(state.illegal_transition_count, 0)
	assert_eq(_decider.hard_interrupt_count, 2)


func test_a_zombie_out_of_sight_range_and_a_failed_flight() -> void:
	_catalog = NpcActionCatalog.load_directory()
	_settings.threat_sight_range_m = 5.0
	_settings.recover_cooldown_sec = 0.5
	var started: Dictionary = _start(DRIFTER)
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	var state: NpcDecisionComponent = _state(world, npc_id)
	var far_zombie: String = _spawn_zombie(world, NPC_SPOT + Vector3(0.0, 0.0, 7.0))
	_run(world, 40)
	assert_eq(_decider.hard_interrupt_count, 0, "7 m is beyond the 5 m it sees")
	assert_eq(state.action_id, WANDER)
	assert_true(_zombies(world).apply_damage_to_zombie(far_zombie, 1.0e6, "t44").ok)
	# The executor cannot flee: Recover, the flee action is on its cooldown
	# (2 s), and meanwhile the NPC goes on choosing as usual.
	_stub.refuse = {FLEE: NpcActionExecutor.FAIL_NO_PATH}
	_spawn_zombie(world, NPC_SPOT + Vector3(0.0, 0.0, 3.0))
	_run(world, 12)
	assert_eq(_decider.hard_interrupt_count, 1)
	assert_eq(state.failures.get(FLEE, 0), 1)
	assert_eq(state.last_failure.get("code", ""), "no_path")
	_run(world, 20)
	assert_eq(state.action_id, WANDER, "it does what it can")
	assert_eq(_decider.hard_interrupt_count, 1, "no new attempt during the cooldown")
	var blocked: Dictionary = state.last_record()
	assert_eq(_rejection(blocked, FLEE), NpcUtilityDecider.REJECT_COOLDOWN)
	assert_eq(blocked[NpcUtilityDecider.KEY_HARD_INTERRUPT], NpcUtilityDecider.HARD_THREAT)
	_run(world, 30)
	assert_eq(state.failures.get(FLEE, 0), 2, "after the cooldown it tries again")
	assert_eq(state.illegal_transition_count, 0)


# ------------------------------------------------------------ determinism, save and restore

const SCRIPT_TICKS: int = 1000
const SCRIPT_SPOTS: Array[Vector3] = [
	Vector3(2.5, 0.0, 5.5), Vector3(4.5, 0.0, 3.5), Vector3(7.5, 0.0, 6.5),
	Vector3(3.5, 0.0, 8.5), Vector3(8.5, 0.0, 2.5), Vector3(6.5, 0.0, 9.5),
]
const SCRIPT_ZOMBIE_SPOT: Vector3 = Vector3(5.5, 0.0, 12.5)
## The need each action lowers when the stub script "finishes" it.
const SCRIPT_SATISFIES: Dictionary = {EAT: NpcNeedKind.HUNGER, DRINK: NpcNeedKind.THIRST, REST: NpcNeedKind.FATIGUE}


## The shipped actions and settings (jitter on) with needs that move fast
## enough for things to happen in 50 s.
func _use_script_rules() -> void:
	_settings = NpcDecisionSettings.load_or_default().duplicate() as NpcDecisionSettings
	_settings.recover_cooldown_sec = 0.5
	_settings.retry_cooldown_sec = 2.0
	_catalog = NpcActionCatalog.load_directory()
	_needs = NpcNeedSettings.new()
	_needs.hunger_hours_to_max = 0.15
	_needs.thirst_hours_to_max = 0.1
	_needs.fatigue_hours_to_max = 0.2
	_schedule.max_decisions_per_tick = 2


func _script_start() -> Dictionary:
	var world: ServerWorld = _world()
	_stub.flaky_action = DRINK
	_stub.flaky_every = 3
	world.join("alice")
	world.step_systems(TICK)
	var ids: PackedStringArray = []
	for index: int in range(SCRIPT_SPOTS.size()):
		ids.append(_spawn(world, WORKER if index % 2 == 0 else DRIFTER, SCRIPT_SPOTS[index]))
	return {"world": world, "ids": ids}


## One tick of a fixed script: the stub "executor" lets actions arrive,
## finish (lowering the need they answer) and fail, by what every NPC's
## SAVED state says; a zombie comes at tick 300 and dies at tick 600.
func _scripted_tick(world: ServerWorld, ids: PackedStringArray, tick: int, seen: Dictionary = {}) -> void:
	var scheduler: NpcScheduler = _decider.scheduler()
	if tick == 300:
		_spawn_zombie(world, SCRIPT_ZOMBIE_SPOT)
	if tick == 600:
		for zombie_id: String in _zombies(world).zombie_ids():
			_zombies(world).apply_damage_to_zombie(zombie_id, 1.0e6, "t44")
	for index: int in range(ids.size()):
		var state: NpcDecisionComponent = _state(world, ids[index])
		seen[state.state] = true
		seen["action:" + state.action_id] = true
		if (tick + index * 3) % 11 != 0:
			continue
		if state.state == NpcDecisionState.NAVIGATE:
			scheduler.request_interrupt(ids[index], NpcActionExecutor.REPORT_ARRIVED)
		elif state.state == NpcDecisionState.PERFORM:
			if (tick / 11 + index) % 7 == 0:
				scheduler.request_interrupt(ids[index], NpcActionExecutor.failed_reason(NpcActionExecutor.FAIL_TARGET_GONE))
			elif (tick / 11 + index) % 3 != 0:
				if SCRIPT_SATISFIES.has(state.action_id):
					_need_values(world, ids[index]).satisfy(str(SCRIPT_SATISFIES[state.action_id]), 55.0, "t44_script")
				scheduler.request_interrupt(ids[index], NpcActionExecutor.REPORT_DONE)
	_log.tick = tick
	world.step_systems(TICK)


func _decision_documents(world: ServerWorld) -> Dictionary:
	var result: Dictionary = {}
	for npc_id: String in _npcs(world).npc_ids():
		var npc: NpcState = _npcs(world).get_npc(npc_id)
		result[npc_id] = {"decision": (npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent).to_document(), "rng": str(npc.rng.state)}
	return _json(result)


func test_the_same_run_makes_the_same_decisions_twice() -> void:
	_use_script_rules()
	var runs: Array[PackedStringArray] = []
	var ends: Array[Dictionary] = []
	for run: int in range(2):
		var started: Dictionary = _script_start()
		var world: ServerWorld = started["world"]
		var seen: Dictionary = {}
		for tick: int in range(SCRIPT_TICKS):
			_scripted_tick(world, started["ids"], tick, seen)
		runs.append(_log.full)
		ends.append(_decision_documents(world))
		if run > 0:
			continue
		# The script covers what it is meant to compare.
		for what: String in ["idle", "navigate", "perform", "recover", "action:eat", "action:drink", "action:rest", "action:work", "action:wander", "action:flee"]:
			assert_true(seen.has(what), "the script covers %s" % what)
		var outcomes: Dictionary = {}
		var reasons: Dictionary = {}
		for record: Dictionary in _log.records:
			outcomes[str(record[NpcUtilityDecider.KEY_OUTCOME])] = true
			for reason: String in record[NpcUtilityDecider.KEY_REASONS]:
				reasons[reason] = true
		for outcome: String in [NpcUtilityDecider.OUTCOME_STARTED, NpcUtilityDecider.OUTCOME_SWITCHED, NpcUtilityDecider.OUTCOME_KEPT, NpcUtilityDecider.OUTCOME_MIN_DURATION, NpcUtilityDecider.OUTCOME_RECOVERING, NpcUtilityDecider.OUTCOME_FAILED]:
			assert_true(outcomes.has(outcome), "the script covers the outcome %s" % outcome)
		for reason: String in [NpcDecider.REASON_PERIOD, NpcUtilityDecider.REASON_THREAT_SEEN, NpcUtilityDecider.REASON_NEED_BOUNDARY, NpcUtilityDecider.REASON_RECOVER_DONE, NpcActionExecutor.REPORT_ARRIVED, NpcActionExecutor.REPORT_DONE, NpcActionExecutor.failed_reason(NpcActionExecutor.FAIL_TARGET_GONE)]:
			assert_true(reasons.has(reason), "the script covers the reason %s" % reason)
		for npc_id: String in started["ids"]:
			assert_eq(_state(world, npc_id).illegal_transition_count, 0)
			assert_true(_state(world, npc_id).records().size() <= _settings.record_capacity, "the ring is bounded")
			assert_eq(_state(world, npc_id).records().size(), _settings.record_capacity)
			assert_eq(_state(world, npc_id).last_record()[NpcUtilityDecider.KEY_SEQUENCE], _state(world, npc_id).decision_count)
	assert_true(runs[0].size() > 300, "the NPCs think: %d decisions" % runs[0].size())
	assert_eq(runs[1].size(), runs[0].size(), "the same number of decisions")
	for index: int in range(mini(runs[0].size(), runs[1].size())):
		if runs[0][index] != runs[1][index]:
			fail("decision %d differs:\n  %s\n  %s" % [index, runs[0][index], runs[1][index]])
			break
	assert_eq(JSON.stringify(ends[1]), JSON.stringify(ends[0]), "and the same state at the end")


func test_a_run_that_is_saved_and_restored_mid_action_decides_like_one_that_goes_on() -> void:
	_use_script_rules()
	# The run that goes on.
	var started: Dictionary = _script_start()
	var ids: PackedStringArray = started["ids"]
	for tick: int in range(SCRIPT_TICKS):
		_scripted_tick(started["world"], ids, tick)
	var expected: PackedStringArray = _log.signatures
	var expected_end: Dictionary = _decision_documents(started["world"])
	assert_true(expected.size() > 300)
	# The same run, saved before tick `save_at` and restored into a new world
	# with a new decider and a new executor (a restart).
	for save_at: int in [97, 240, 333, 512, 760]:
		var first: Dictionary = _script_start()
		var first_world: ServerWorld = first["world"]
		assert_eq(first["ids"], ids, "the same NPCs")
		for tick: int in range(save_at):
			_scripted_tick(first_world, ids, tick)
		var before: PackedStringArray = _log.signatures
		var running: int = 0
		var states: Dictionary = {}
		for npc_id: String in ids:
			running += 1 if _state(first_world, npc_id).is_running() else 0
			states[_state(first_world, npc_id).state] = true
		assert_true(running > 0, "saved at %d: mid-action (%d NPCs act, states %s)" % [save_at, running, str(states.keys())])
		# A save is text: the documents go through JSON.
		var documents: Dictionary = _json(first_world.to_documents())
		var second_world: ServerWorld = _world()
		_stub.flaky_action = DRINK
		_stub.flaky_every = 3
		assert_eq(second_world.restore_documents(documents["world_state"], documents["players"], documents["cells"]).size(), 0)
		second_world.join("alice")
		for npc_id: String in ids:
			assert_eq(_state(second_world, npc_id).records().size(), 0, "the records are not saved")
		for tick: int in range(save_at, SCRIPT_TICKS):
			_scripted_tick(second_world, ids, tick)
		var actual: PackedStringArray = before.duplicate()
		actual.append_array(_log.signatures)
		assert_true(before.size() > 0 and _log.signatures.size() > 0)
		assert_eq(actual.size(), expected.size(), "saved at %d: the same number of decisions" % save_at)
		for index: int in range(mini(actual.size(), expected.size())):
			if actual[index] != expected[index]:
				fail("saved at %d: decision %d is\n  %s\nthe run that went on has\n  %s" % [save_at, index, actual[index], expected[index]])
				break
		var end: Dictionary = _decision_documents(second_world)
		for npc_id: String in ids:
			assert_eq(JSON.stringify(end[npc_id]), JSON.stringify(expected_end[npc_id]), "saved at %d: the decision state and the generator of %s end the same" % [save_at, npc_id])


# ------------------------------------------------------------ measurement

func test_measure_the_decisions_of_25_npcs() -> void:
	# The shipped rules and the shipped schedule (2 s / 10 s, cap 2), 25 NPCs
	# near the player, 12 zombies in memory but out of sight, 20 s at 60 Hz.
	_settings = NpcDecisionSettings.load_or_default()
	_catalog = NpcActionCatalog.load_directory()
	_schedule = NpcScheduleSettings.load_or_default().duplicate() as NpcScheduleSettings
	_needs = NpcNeedSettings.new()
	_needs.hunger_hours_to_max = 0.15
	_needs.thirst_hours_to_max = 0.1
	_needs.fatigue_hours_to_max = 0.2
	var world: ServerWorld = _world()
	# Not the cost of this test writing every record down as text.
	_decider.decided.disconnect(_log.on_decided)
	world.join("alice")
	world.step_systems(TICK)
	var ids: PackedStringArray = []
	for index: int in range(25):
		ids.append(_spawn(world, WORKER if index % 2 == 0 else DRIFTER, SPAWN + Vector3(float(index % 5) - 2.0, 0.0, float(index / 5) - 2.0)))
	for index: int in range(12):
		_spawn_zombie(world, Vector3(-14.5 + float(index), 0.0, -14.5))
	var scheduler: NpcScheduler = _decider.scheduler()
	var npcs: NpcService = _npcs(world)
	var all: PackedInt32Array = []
	var busy: PackedInt32Array = []
	var stage: PackedInt32Array = []
	var sensor: PackedInt32Array = []
	for tick: int in range(20 * 60):
		for index: int in range(ids.size()):
			if (tick + index * 7) % 90 != 0:
				continue
			var state: NpcDecisionComponent = _state(world, ids[index])
			if state.state == NpcDecisionState.NAVIGATE:
				scheduler.request_interrupt(ids[index], NpcActionExecutor.REPORT_ARRIVED)
			elif state.state == NpcDecisionState.PERFORM:
				if SCRIPT_SATISFIES.has(state.action_id):
					_need_values(world, ids[index]).satisfy(str(SCRIPT_SATISFIES[state.action_id]), 55.0, "t44_measure")
				scheduler.request_interrupt(ids[index], NpcActionExecutor.REPORT_DONE)
		world.step_systems(1.0 / 60.0)
		all.append(scheduler.last_step_usec)
		stage.append(roundi(npcs.last_step_msec * 1000.0))
		if _decider.threat_sensor().last_check_count > 0:
			sensor.append(_decider.threat_sensor().last_step_usec)
		if scheduler.last_decision_count > 0:
			busy.append(scheduler.last_step_usec / scheduler.last_decision_count)
	assert_eq(_decider.decision_count, scheduler.total_decision_count)
	assert_true(_decider.decision_count >= 25 * 10, "every NPC decided at least every 2 s: %d decisions" % _decider.decision_count)
	assert_true(_decider.evaluation_count > 100, "%d evaluations" % _decider.evaluation_count)
	assert_eq(_decider.hard_interrupt_count, 0, "the zombies are out of sight")
	all.sort()
	busy.sort()
	stage.sort()
	sensor.sort()
	assert_true(sensor.size() > 100, "the sensor looked: %d ticks" % sensor.size())
	var median_ms: float = float(stage[stage.size() / 2]) / 1000.0
	var worst_ms: float = float(stage[stage.size() - 1]) / 1000.0
	print("[p4-4] 25 NPCs, 12 zombies, 1200 ticks: %d decisions (%d evaluations, %d failures); NPC stages per tick (scheduler + decider + threat sensor): median %.4f ms, worst %.4f ms; scheduler + decider alone: median %.4f ms, worst %.4f ms; per decision in the %d ticks with decisions: median %.4f ms, worst %.4f ms; threat sensor in the %d ticks it looked (%d looks): median %.4f ms, worst %.4f ms" % [
		_decider.decision_count, _decider.evaluation_count, _decider.failure_count, median_ms, worst_ms,
		float(all[all.size() / 2]) / 1000.0, float(all[all.size() - 1]) / 1000.0,
		busy.size(), float(busy[busy.size() / 2]) / 1000.0, float(busy[busy.size() - 1]) / 1000.0,
		sensor.size(), _decider.threat_sensor().check_count, float(sensor[sensor.size() / 2]) / 1000.0, float(sensor[sensor.size() - 1]) / 1000.0])
	assert_time_bound(median_ms, 1.0, "NPC stages with decisions, median")
	assert_time_bound(worst_ms, 2.0, "NPC stages with decisions, worst")


# ------------------------------------------------------------ F-6: the night sleep and naps

## The shipped night sleep, nap (rest), eat and drink without their minimum
## durations, the shipped flee action, and "chores": what an NPC does when
## nothing else calls.
func _use_sleep_rules() -> void:
	var shipped: NpcActionCatalog = NpcActionCatalog.load_directory()
	for action_id: String in [SLEEP, REST, EAT, DRINK, FLEE]:
		var action: NpcActionDefinition = shipped.get_action(action_id).duplicate() as NpcActionDefinition
		action.min_duration_sec = 0.0
		_add(action)
	_add(_action(CHORES, 0.2))


## Puts the calendar at `hour` (hours since the world began; forward only).
func _set_hour(world: ServerWorld, hour: float) -> void:
	assert_true(hour * HOUR_SEC >= world.clock.world_time_sec, "test setup: the calendar only goes forward")
	assert_eq(world.clock.restore(hour * HOUR_SEC), OK)


## A world whose calendar says `hour`, with a player and one NPC of
## `definition_id` whose fatigue is `fatigue` (0..1): {world, id}.
func _start_at(hour: float, definition_id: String, fatigue: float = 0.5) -> Dictionary:
	var world: ServerWorld = _world()
	_set_hour(world, hour)
	world.join("alice")
	world.step_systems(TICK)
	var npc_id: String = _spawn(world, definition_id, NPC_SPOT)
	_set_needs(world, npc_id, 0.0, 0.0, fatigue)
	return {"world": world, "id": npc_id}


func test_nights_are_counted_from_bedtime_to_bedtime() -> void:
	var day: float = 86400.0
	# Bedtime 21:00, window 8 h: bedtime until 05:00.
	for entry: Array in [[20.99, false, 0], [21.0, true, 1], [23.5, true, 1], [24.0 + 4.99, true, 1], [24.0 + 5.0, false, 1], [24.0 + 20.99, false, 1], [24.0 + 21.0, true, 2], [10.0 * 24.0 + 22.0, true, 11]]:
		var time: float = float(entry[0]) * HOUR_SEC
		assert_eq(NpcBedtime.is_bedtime(time, day, 21.0, 8.0), bool(entry[1]), "bedtime 21 at hour %.2f" % float(entry[0]))
		assert_eq(NpcBedtime.night_of(time, day, 21.0), int(entry[2]), "night of hour %.2f for bedtime 21" % float(entry[0]))
	# Bedtime 00:30 (an evening type): the window is inside one calendar day.
	for entry: Array in [[0.0, false, 0], [0.49, false, 0], [0.5, true, 1], [8.49, true, 1], [8.5, false, 1], [23.99, false, 1], [24.5, true, 2]]:
		var time: float = float(entry[0]) * HOUR_SEC
		assert_eq(NpcBedtime.is_bedtime(time, day, 0.5, 8.0), bool(entry[1]), "bedtime 0.5 at hour %.2f" % float(entry[0]))
		assert_eq(NpcBedtime.night_of(time, day, 0.5), int(entry[2]), "night of hour %.2f for bedtime 0.5" % float(entry[0]))
	# A save rounds the calendar time: a hair before the bedtime is the bedtime.
	assert_true(NpcBedtime.is_bedtime(21.0 * HOUR_SEC - 0.000001, day, 21.0, 8.0))
	assert_eq(NpcBedtime.night_of(21.0 * HOUR_SEC - 0.000001, day, 21.0), 1)
	# A window of the whole day, no window, and nonsense.
	assert_true(NpcBedtime.is_bedtime(15.0 * HOUR_SEC, day, 21.0, 24.0))
	assert_false(NpcBedtime.is_bedtime(22.0 * HOUR_SEC, day, 21.0, 0.0))
	assert_false(NpcBedtime.is_bedtime(22.0 * HOUR_SEC, day, NAN, 8.0))
	assert_eq(NpcBedtime.night_of(NAN, day, 21.0), 0)
	assert_eq(NpcBedtime.night_of(1000.0, 0.0, 21.0), 0)


func test_the_shipped_sleep_data_is_valid_and_bad_bedtimes_are_refused() -> void:
	var actions: NpcActionCatalog = NpcActionCatalog.load_directory()
	var sleep: NpcActionDefinition = actions.get_action(SLEEP)
	var nap: NpcActionDefinition = actions.get_action(REST)
	assert_true(sleep.requires_bedtime and sleep.runs_until_done and sleep.yields_to_danger_need, "the night sleep")
	assert_eq(sleep.need_kind, NpcNeedKind.FATIGUE)
	assert_eq(sleep.observable_label, "sleep")
	assert_false(sleep.has_window(), "the bedtime is the NPC's, not the action's")
	assert_true(not nap.requires_bedtime and nap.runs_until_done and nap.yields_to_danger_need, "the nap")
	assert_eq(nap.observable_label, "sleep")
	assert_false(nap.has_window())
	# The nap threshold (docs/15 F6-003): fatigue 70 of 100, between caution and danger.
	var needs: NpcNeedSettings = NpcNeedSettings.load_or_default()
	assert_eq(nap.min_need_urgency, 0.7)
	assert_true(nap.min_need_urgency * needs.need_max > needs.caution_threshold and nap.min_need_urgency * needs.need_max < needs.danger_threshold)
	assert_true(sleep.min_need_urgency < nap.min_need_urgency)
	# At its bedtime a tired NPC prefers the night sleep to a nap, whatever
	# the jitter says.
	var settings: NpcDecisionSettings = NpcDecisionSettings.load_or_default()
	for fatigue: float in [0.7, 0.85, 1.0]:
		var slept: float = float(NpcUtilityScorer.score(sleep, settings, fatigue, 0.0, 0.0, 0.0, 0.0, false, 0.0)[NpcUtilityScorer.KEY_SCORE])
		var napped: float = float(NpcUtilityScorer.score(nap, settings, fatigue, 0.0, 0.0, 0.0, 0.0, false, 1.0)[NpcUtilityScorer.KEY_SCORE])
		assert_true(slept > napped, "fatigue %.2f: sleep %f, nap %f" % [fatigue, slept, napped])
	assert_true(settings.night_sleep_window_hours > 0.0 and settings.night_sleep_window_hours <= 24.0)
	assert_eq(NpcBehaviourSettings.load_or_default().sleep_until_fatigue, 0.0, "FD-11: until fatigue is 0")
	assert_eq(NpcBehaviourSettings.load_or_default().validate().size(), 0)
	# Every dev NPC has a bedtime; there are morning and evening types.
	var definitions: NpcCatalog = CompositionConfig.from_defaults().npc_definitions
	var bedtimes: Dictionary = {}
	for definition_id: String in definitions.definition_ids():
		var definition: NpcDefinition = definitions.get_definition(definition_id)
		assert_eq(definition.validate().size(), 0, ", ".join(definition.validate()))
		bedtimes[definition.bedtime_hour] = true
	assert_true(bedtimes.size() >= 3, "the dev NPCs go to bed at different hours: %s" % str(bedtimes.keys()))
	assert_true(bedtimes.keys().min() < 12.0 and bedtimes.keys().max() >= 21.0, "one of them goes to bed after midnight")
	# Bad values.
	for bad_hour: float in [-0.5, 24.0, 30.0, NAN, INF]:
		var broken: NpcDefinition = NpcDefinition.new()
		broken.definition_id = "t44_broken"
		broken.display_name = "고장"
		assert_eq(broken.validate().size(), 0)
		broken.bedtime_hour = bad_hour
		assert_eq(broken.validate().size(), 1, "bedtime %f is refused" % bad_hour)
	for bad_window: float in [0.0, -1.0, 24.5, NAN]:
		var bad: NpcDecisionSettings = NpcDecisionSettings.new()
		bad.night_sleep_window_hours = bad_window
		assert_true(bad.validate().size() >= 1, "window %f is refused" % bad_window)
	var bad_behaviour: NpcBehaviourSettings = NpcBehaviourSettings.new()
	bad_behaviour.sleep_until_fatigue = -1.0
	assert_eq(bad_behaviour.validate().size(), 1)


func test_an_npc_goes_to_bed_at_its_own_bedtime_a_morning_type_before_an_evening_type() -> void:
	_use_sleep_rules()
	var world: ServerWorld = _world()
	_set_hour(world, 20.5)
	world.join("alice")
	world.step_systems(TICK)
	var lark: String = _spawn(world, LARK, NPC_SPOT)
	var owl: String = _spawn(world, OWL, NPC_SPOT + Vector3(0.0, 0.0, 1.0))
	# 20:30, both half tired: nobody's bedtime, and not tired enough for a nap.
	for npc_id: String in [lark, owl]:
		_set_needs(world, npc_id, 0.0, 0.0, 0.5)
		var early: Dictionary = _decide_now(world, npc_id)
		assert_eq(early[NpcUtilityDecider.KEY_CHOSEN], CHORES)
		assert_eq(_rejection(early, SLEEP), NpcUtilityDecider.REJECT_NOT_BEDTIME)
		assert_eq(_rejection(early, REST), NpcUtilityDecider.REJECT_NEED_LOW)
	# 21:00: the morning type goes to bed, the evening type does not.
	_set_hour(world, LARK_BEDTIME)
	var record: Dictionary = _decide_now(world, lark)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], SLEEP)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_SWITCHED)
	assert_true(absf(float(_candidate(record, SLEEP)[NpcUtilityScorer.KEY_VALUES]["need"]) - 0.5) < 0.001)
	assert_eq(NpcDecisionComponent.label_of(_npcs(world).get_npc(lark)), "walk", "on its way to bed")
	_report(world, lark, NpcActionExecutor.REPORT_ARRIVED)
	assert_eq(NpcDecisionComponent.label_of(_npcs(world).get_npc(lark)), "sleep", "what other players see")
	record = _decide_now(world, owl)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], CHORES)
	assert_eq(_rejection(record, SLEEP), NpcUtilityDecider.REJECT_NOT_BEDTIME)
	# 00:29 and 00:30 of the next day: the evening type's bedtime.
	_set_hour(world, 24.0 + OWL_BEDTIME - 0.02)
	assert_eq(_rejection(_decide_now(world, owl), SLEEP), NpcUtilityDecider.REJECT_NOT_BEDTIME)
	_set_hour(world, 24.0 + OWL_BEDTIME)
	record = _decide_now(world, owl)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], SLEEP)
	assert_eq(_state(world, lark).action_id, SLEEP, "the morning type sleeps on")
	assert_eq(_stub.begun, PackedStringArray(["%s %s" % [lark, CHORES], "%s %s" % [owl, CHORES], "%s %s" % [lark, SLEEP], "%s %s" % [owl, SLEEP]]))
	# Very tired at its bedtime: the night sleep, not a nap.
	var tired: Dictionary = _start_at(LARK_BEDTIME + 1.0, LARK, 0.95)
	record = _decide_now(tired["world"], tired["id"])
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], SLEEP)
	assert_eq(_rejection(record, REST), NpcUtilityDecider.REJECT_BEDTIME_NOW)
	# A nap that still runs when the bedtime comes gives way to the night sleep.
	var napper: Dictionary = _start_at(LARK_BEDTIME - 0.5, LARK, 0.8)
	assert_eq(_decide_now(napper["world"], napper["id"])[NpcUtilityDecider.KEY_CHOSEN], REST, "20:30 and very tired: a nap")
	_report(napper["world"], napper["id"], NpcActionExecutor.REPORT_ARRIVED)
	assert_eq(_decide_now(napper["world"], napper["id"])[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_UNTIL_DONE)
	_set_hour(napper["world"], LARK_BEDTIME)
	record = _decide_now(napper["world"], napper["id"])
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_SWITCHED)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], SLEEP)
	assert_eq(_rejection(record, REST), NpcUtilityDecider.REJECT_BEDTIME_NOW)
	# An NPC that was kept up: it may still go to bed until the window ends
	# (21:00 + 8 h = 05:00), not after.
	var late: Dictionary = _start_at(24.0 + 4.9, LARK)
	assert_eq(_decide_now(late["world"], late["id"])[NpcUtilityDecider.KEY_CHOSEN], SLEEP, "04:54: still its night")
	var missed: Dictionary = _start_at(24.0 + 5.1, LARK)
	record = _decide_now(missed["world"], missed["id"])
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], CHORES, "05:06: it has missed the night")
	assert_eq(_rejection(record, SLEEP), NpcUtilityDecider.REJECT_NOT_BEDTIME)
	# A rested NPC does not lie down just because it is its bedtime.
	var rested: Dictionary = _start_at(22.0, LARK, 0.05)
	record = _decide_now(rested["world"], rested["id"])
	assert_eq(_rejection(record, SLEEP), NpcUtilityDecider.REJECT_NEED_LOW)


func test_the_night_sleep_runs_until_it_is_done_once_a_night_and_a_nap_needs_high_fatigue() -> void:
	_use_sleep_rules()
	var started: Dictionary = _start_at(LARK_BEDTIME, LARK)
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	var state: NpcDecisionComponent = _state(world, npc_id)
	assert_eq(_decide_now(world, npc_id)[NpcUtilityDecider.KEY_CHOSEN], SLEEP)
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	assert_eq(state.last_sleep_night, NpcBedtime.NO_NIGHT, "the night is not over yet")
	# Almost rested: it sleeps on (the executor ends it at fatigue 0), though
	# its fatigue is below what would make it lie down.
	_set_needs(world, npc_id, 0.0, 0.0, 0.02)
	var record: Dictionary = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_UNTIL_DONE)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], SLEEP)
	_run(world, 100)
	assert_eq(state.action_id, SLEEP, "five seconds of turns later it still sleeps")
	assert_eq(_stub.cancelled.size(), 0)
	# 23:00, fatigue 0: the executor reports the sleep done.
	_set_hour(world, 23.0)
	_set_needs(world, npc_id, 0.0, 0.0, 0.0)
	record = _report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(record[NpcUtilityDecider.KEY_COMPLETED], SLEEP)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], CHORES)
	assert_eq(state.last_sleep_night, 1, "the first night of the world for a 21:00 bedtime")
	# Still its bedtime window, and it is tired again: not a second night
	# sleep, and no nap below the nap threshold.
	for fatigue: float in [0.5, 0.69]:
		_set_needs(world, npc_id, 0.0, 0.0, fatigue)
		record = _decide_now(world, npc_id)
		assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], CHORES, "fatigue %.2f" % fatigue)
		assert_eq(_rejection(record, SLEEP), NpcUtilityDecider.REJECT_SLEPT)
		assert_eq(_rejection(record, REST), NpcUtilityDecider.REJECT_NEED_LOW)
	# Fatigue 70: a nap.
	_set_needs(world, npc_id, 0.0, 0.0, 0.7)
	record = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], REST)
	assert_eq(_rejection(record, SLEEP), NpcUtilityDecider.REJECT_SLEPT)
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	assert_eq(NpcDecisionComponent.label_of(_npcs(world).get_npc(npc_id)), "sleep")
	_set_needs(world, npc_id, 0.0, 0.0, 0.05)
	record = _report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(record[NpcUtilityDecider.KEY_COMPLETED], REST)
	assert_eq(state.last_sleep_night, 1, "a nap is not a night")
	# The same in the afternoon of the next day: tired but not very: no sleep.
	_set_hour(world, 24.0 + 15.0)
	_set_needs(world, npc_id, 0.0, 0.0, 0.5)
	record = _decide_now(world, npc_id)
	assert_eq(_rejection(record, SLEEP), NpcUtilityDecider.REJECT_NOT_BEDTIME)
	assert_eq(_rejection(record, REST), NpcUtilityDecider.REJECT_NEED_LOW)
	# The next evening is a new night.
	_set_hour(world, 24.0 + LARK_BEDTIME)
	record = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], SLEEP)
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	_report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(state.last_sleep_night, 2)
	assert_eq(state.illegal_transition_count, 0)


func test_a_sleeper_wakes_on_danger_and_goes_back_to_bed() -> void:
	_use_sleep_rules()
	var started: Dictionary = _start_at(LARK_BEDTIME, LARK)
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	var state: NpcDecisionComponent = _state(world, npc_id)
	assert_eq(_decide_now(world, npc_id)[NpcUtilityDecider.KEY_CHOSEN], SLEEP)
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	# Thirst below the danger category: it sleeps on.
	_set_needs(world, npc_id, 0.0, 0.74, 0.4)
	assert_eq(_decide_now(world, npc_id)[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_UNTIL_DONE)
	# Thirst in danger: it gets up and drinks.
	_set_needs(world, npc_id, 0.0, 0.76, 0.4)
	var record: Dictionary = _decide_now(world, npc_id)
	assert_eq(record[NpcUtilityDecider.KEY_OUTCOME], NpcUtilityDecider.OUTCOME_SWITCHED)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], DRINK)
	assert_eq(_rejection(record, SLEEP), NpcUtilityDecider.REJECT_NEED_DANGER)
	assert_eq(_stub.cancelled, PackedStringArray([npc_id]), "the sleep was cut")
	assert_eq(state.last_sleep_night, NpcBedtime.NO_NIGHT, "a sleep that was cut is not the night's sleep")
	# In danger it does not lie down for a nap either.
	_set_needs(world, npc_id, 0.0, 0.76, 0.9)
	assert_eq(_rejection(_decide_now(world, npc_id), REST), NpcUtilityDecider.REJECT_NEED_DANGER)
	# It has drunk: back to bed, in the same night.
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	_set_needs(world, npc_id, 0.0, 0.1, 0.4)
	record = _report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(record[NpcUtilityDecider.KEY_COMPLETED], DRINK)
	assert_eq(record[NpcUtilityDecider.KEY_CHOSEN], SLEEP)
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	# Hunger in danger and nothing to eat: eating fails, and then it may lie
	# down all the same (nothing can be done about the hunger now).
	_stub.refuse[EAT] = NpcActionExecutor.FAIL_NO_RESOURCE
	_set_needs(world, npc_id, 0.8, 0.1, 0.4)
	record = _decide_now(world, npc_id)
	assert_eq(str((record[NpcUtilityDecider.KEY_FAILURE] as Dictionary).get(NpcUtilityDecider.KEY_ACTION_ID, "")), EAT)
	assert_eq(state.state, NpcDecisionState.RECOVER)
	_run(world, 30)
	assert_eq(state.action_id, SLEEP, "it went back to bed hungry")
	assert_eq(_rejection(state.last_record(), EAT), NpcUtilityDecider.REJECT_COOLDOWN)
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	assert_eq(NpcDecisionComponent.label_of(_npcs(world).get_npc(npc_id)), "sleep")
	# A zombie it can see: it flees, whatever its turn is.
	_spawn_zombie(world, Vector3(2.5, 0.0, 12.5))
	_run(world, 12)
	assert_eq(state.action_id, FLEE, "a visible zombie wakes the sleeper")
	assert_eq(state.last_record()[NpcUtilityDecider.KEY_HARD_INTERRUPT], NpcUtilityDecider.HARD_THREAT)
	assert_eq(state.last_sleep_night, NpcBedtime.NO_NIGHT)
	assert_eq(state.illegal_transition_count, 0)


func test_the_night_an_npc_slept_is_saved_and_an_older_save_has_none() -> void:
	var state: NpcDecisionComponent = NpcDecisionComponent.new(_catalog)
	state.last_sleep_night = 3
	state.decision_count = 5
	var document: Dictionary = _json(state.to_document())
	document[NpcComponent.KEY_SCHEMA_VERSION] = NpcDecisionComponent.SCHEMA_VERSION
	assert_eq(int(document[NpcDecisionComponent.KEY_LAST_SLEEP_NIGHT]), 3)
	var restored: NpcDecisionComponent = NpcDecisionComponent.new(_catalog)
	assert_eq(restored.restore_document(document).size(), 0, ", ".join(restored.restore_document(document)))
	assert_eq(restored.last_sleep_night, 3)
	assert_eq(_json(restored.to_document()), _json(state.to_document()))
	# A document of before F-6 (schema 1, no night): read, nothing slept.
	var old: Dictionary = document.duplicate(true)
	old.erase(NpcDecisionComponent.KEY_LAST_SLEEP_NIGHT)
	old[NpcComponent.KEY_SCHEMA_VERSION] = 1
	var from_old: NpcDecisionComponent = NpcDecisionComponent.new(_catalog)
	assert_eq(from_old.restore_document(old).size(), 0, ", ".join(from_old.restore_document(old)))
	assert_eq(from_old.last_sleep_night, NpcBedtime.NO_NIGHT)
	assert_eq(from_old.decision_count, 5)
	assert_eq(int(from_old.to_document()[NpcDecisionComponent.KEY_LAST_SLEEP_NIGHT]), NpcBedtime.NO_NIGHT)
	# Broken nights are refused.
	for bad: Variant in [-2, 1.5, "tonight", null]:
		var broken: Dictionary = document.duplicate(true)
		if bad == null:
			broken.erase(NpcDecisionComponent.KEY_LAST_SLEEP_NIGHT)
		else:
			broken[NpcDecisionComponent.KEY_LAST_SLEEP_NIGHT] = bad
		var fresh: NpcDecisionComponent = NpcDecisionComponent.new(_catalog)
		assert_true(fresh.restore_document(broken).size() > 0, "night %s is refused" % str(bad))
		assert_eq(fresh.decision_count, 0)
	# An NPC that slept and was saved and restored does not sleep again in
	# that night.
	_use_sleep_rules()
	var started: Dictionary = _start_at(LARK_BEDTIME, LARK)
	var world: ServerWorld = started["world"]
	var npc_id: String = started["id"]
	var live: NpcDecisionComponent = _state(world, npc_id)
	assert_eq(_decide_now(world, npc_id)[NpcUtilityDecider.KEY_CHOSEN], SLEEP)
	_report(world, npc_id, NpcActionExecutor.REPORT_ARRIVED)
	_report(world, npc_id, NpcActionExecutor.REPORT_DONE)
	assert_eq(live.last_sleep_night, 1)
	assert_true(JSON.stringify(_npcs(world).npc_document(npc_id)).contains("\"last_sleep_night\":1"), "the NPC's save data has the night")
	var component_document: Dictionary = _json(live.to_document())
	component_document[NpcComponent.KEY_SCHEMA_VERSION] = NpcDecisionComponent.SCHEMA_VERSION
	live.last_sleep_night = NpcBedtime.NO_NIGHT
	assert_eq(live.restore_document(component_document).size(), 0)
	assert_eq(live.last_sleep_night, 1)
	var record: Dictionary = _decide_now(world, npc_id)
	assert_eq(_rejection(record, SLEEP), NpcUtilityDecider.REJECT_SLEPT)
