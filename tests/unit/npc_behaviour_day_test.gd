extends TestCase
## P4-5b: the decision layer and the behaviours joined, in the composition
## of a dedicated server (docs/09 §17.8): the shipped settings, the test
## map with its buildings, doors and containers, the five dev NPCs, the
## shipped NPC spots. Nobody tells the NPCs anything: over a day of the
## calendar they eat, drink, rest and work; they run from a zombie they
## see; two runs with the same seed decide the same; a run that is saved,
## restarted and restored goes on as one that was never stopped; and what
## 25 of them cost per tick is measured. Headless, fixed ticks of 1/20 s:
## a calendar day (one real hour at the shipped time scale) is 72000 ticks.

const WORLD: String = "npc_behaviour_day_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
const TICKS_PER_HOUR: int = 3000
const DAY_TICKS: int = 24 * TICKS_PER_HOUR


## One run: the world, its decider, and what was seen.
class Run:
	extends RefCounted
	var world: ServerWorld = null
	var decider: NpcUtilityDecider = null
	var behaviours: NpcBehaviours = null
	var alice: PlayerState = null
	var tick: int = 0
	## "<tick> <npc> <sequence> <outcome> <chosen> <state after>" per decision.
	var decisions: PackedStringArray = []
	## "<tick> <event> <npc> <action> [<code>]" per behaviour event.
	var events: PackedStringArray = []
	## npc_id -> {need kind: the highest value seen at a decision}.
	var highest: Dictionary = {}
	## npc_id -> {need kind: decisions at which it was in the danger category}.
	var danger_decisions: Dictionary = {}
	var decision_counts: Dictionary = {}
	## npc_id -> {label: true}: the labels other players would have seen.
	var labels: Dictionary = {}
	var _danger: float = 75.0

	func watch(danger_threshold: float) -> void:
		_danger = danger_threshold
		decider.decided.connect(_on_decided)
		behaviours.behaviour_started.connect(func(npc_id: String, action_id: String, _info: Dictionary) -> void: events.append("%d started %s %s" % [tick, npc_id, action_id]))
		behaviours.behaviour_finished.connect(func(npc_id: String, action_id: String, _info: Dictionary) -> void: events.append("%d finished %s %s" % [tick, npc_id, action_id]))
		behaviours.behaviour_failed.connect(func(npc_id: String, action_id: String, code: String) -> void: events.append("%d failed %s %s %s" % [tick, npc_id, action_id, code]))
		behaviours.behaviour_cancelled.connect(func(npc_id: String, action_id: String) -> void: events.append("%d cancelled %s %s" % [tick, npc_id, action_id]))

	func _on_decided(npc_id: String, record: Dictionary) -> void:
		decisions.append("%d %s %d %s %s %s" % [tick, npc_id, int(record[NpcUtilityDecider.KEY_SEQUENCE]), str(record[NpcUtilityDecider.KEY_OUTCOME]), str(record[NpcUtilityDecider.KEY_CHOSEN]), str(record[NpcUtilityDecider.KEY_STATE_AFTER])])
		var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService
		var needs: NpcNeeds = npcs.get_npc(npc_id).component(NpcNeeds.COMPONENT_ID) as NpcNeeds
		if not highest.has(npc_id):
			highest[npc_id] = {}
			danger_decisions[npc_id] = {}
		decision_counts[npc_id] = int(decision_counts.get(npc_id, 0)) + 1
		for kind: String in NpcNeedKind.SIMULATED_KINDS:
			var value: float = needs.value(kind)
			highest[npc_id][kind] = maxf(float(highest[npc_id].get(kind, 0.0)), value)
			if value >= _danger:
				danger_decisions[npc_id][kind] = int(danger_decisions[npc_id].get(kind, 0)) + 1

	func step() -> void:
		world.step_systems(TICK)
		tick += 1

	## Lets go of the world (the world's signals hold this object).
	func finish() -> void:
		world = null
		decider = null
		behaviours = null
		alice = null

	func see_labels() -> void:
		var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService
		for npc_id: String in npcs.npc_ids():
			if not labels.has(npc_id):
				labels[npc_id] = {}
			labels[npc_id][NpcDecisionComponent.label_of(npcs.get_npc(npc_id))] = true

	func npcs() -> NpcService:
		return world.get_system(NpcService.SYSTEM_ID) as NpcService

	func count_of(npc_id: String, action_id: String) -> int:
		return (npcs().get_npc(npc_id).component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState).count_of(action_id)

	## The longest run of the same failure of one NPC with no success of
	## that NPC in between.
	func longest_failure_streak() -> int:
		var streak: Dictionary = {}
		var last: Dictionary = {}
		var longest: int = 0
		for line: String in events:
			var parts: PackedStringArray = line.split(" ")
			if parts[1] == "finished":
				streak[parts[2]] = 0
			elif parts[1] == "failed":
				var what: String = "%s %s" % [parts[3], parts[4]]
				streak[parts[2]] = int(streak.get(parts[2], 0)) + 1 if str(last.get(parts[2], "")) == what else 1
				last[parts[2]] = what
				longest = maxi(longest, int(streak[parts[2]]))
		return longest


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _config(decider: NpcUtilityDecider) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.survival = SurvivalSettings.load_or_default().duplicate() as SurvivalSettings
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.load_or_default().duplicate() as ZombieSettings
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = WorldCellSettings.load_or_default().duplicate() as WorldCellSettings
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.preload_lookahead_sec = 0.0
	config.map_content = MapContentDefinition.load_or_null()
	config.npc_roster = NpcRoster.load_or_null()
	config.npc_decider = decider
	return config


func _decider() -> NpcUtilityDecider:
	return NpcUtilityDecider.new(NpcDecisionSettings.load_or_default(), NpcActionCatalog.load_directory(), NpcNeedSettings.load_or_default())


## A world of the dedicated server's composition; `documents` = restored
## from a save, otherwise a new world seeded with the map and the roster.
func _begin(documents: Dictionary = {}) -> Run:
	var run: Run = Run.new()
	run.decider = _decider()
	var config: CompositionConfig = _config(run.decider)
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	run.world = ServerComposition.create_world(WORLD, config)
	(run.world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	if documents.is_empty():
		assert_eq(run.world.seed_new_world(DevWorldSeed.new()), OK)
	else:
		assert_eq(run.world.restore_documents(documents["world_state"], documents["players"], documents["cells"]).size(), 0)
	var adapter: NpcBehaviourExecutor = run.decider.executor() as NpcBehaviourExecutor
	assert_not_null(adapter, "the composition gives the utility decider the behaviour executor")
	run.behaviours = adapter.behaviours() if adapter != null else null
	run.watch(NpcNeedSettings.load_or_default().danger_threshold)
	run.alice = run.world.join("alice")
	return run


## A save is text. Full precision, as SaveService writes it.
func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value, "", true, true)) as Dictionary


func _npc_documents(run: Run) -> Dictionary:
	var result: Dictionary = {}
	for npc_id: String in run.npcs().npc_ids():
		var document: Dictionary = run.npcs().npc_document(npc_id)
		document.erase(NpcState.KEY_LAST_SIMULATED)
		result[npc_id] = document
	return result


# ------------------------------------------------------------ a day

func test_five_npcs_eat_drink_rest_and_work_through_a_calendar_day_by_themselves() -> void:
	var run: Run = _begin()
	var ids: PackedStringArray = run.npcs().npc_ids()
	assert_eq(ids.size(), 5, "the dev roster")
	var started_msec: int = Time.get_ticks_msec()
	var stage_msec: PackedFloat32Array = []
	for tick: int in range(DAY_TICKS):
		run.step()
		stage_msec.append(run.npcs().last_step_msec)
		if tick % 20 == 0:
			run.see_labels()
	stage_msec.sort()
	print("[npc day] NPC stages per tick with 5 NPCs: median %.4f ms, 99%% %.4f ms, worst %.4f ms" % [stage_msec[stage_msec.size() / 2], stage_msec[stage_msec.size() * 99 / 100], stage_msec[stage_msec.size() - 1]])
	var elapsed_msec: int = Time.get_ticks_msec() - started_msec
	assert_true(run.world.clock.world_time_sec >= 86400.0 - 1.0, "a calendar day passed: %f" % run.world.clock.world_time_sec)
	print("[npc day] %d ticks in %d ms; %d decisions, %d behaviour events" % [DAY_TICKS, elapsed_msec, run.decisions.size(), run.events.size()])
	var catalog: NpcCatalog = NpcCatalog.load_directory()
	for npc_id: String in ids:
		var state: NpcBehaviourState = run.npcs().get_npc(npc_id).component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState
		var seen: PackedStringArray = PackedStringArray((run.labels[npc_id] as Dictionary).keys())
		seen.sort()
		var rests: int = state.count_of("rest") + state.count_of("rest_cut")
		print("[npc day] %s %s: eat %d drink %d rest %d (%d to the end) work %d wander %d failed %d, worked %.0f s, highest hunger %.1f thirst %.1f fatigue %.1f, decisions %d, labels %s" % [
			npc_id, run.npcs().get_npc(npc_id).definition_id,
			state.count_of("eat"), state.count_of("drink"), rests, state.count_of("rest"), state.count_of("work"), state.count_of("wander"), state.count_of("failed"),
			float(state.worked_usec) / 1000000.0,
			float(run.highest[npc_id]["hunger"]), float(run.highest[npc_id]["thirst"]), float(run.highest[npc_id]["fatigue"]),
			int(run.decision_counts[npc_id]), ",".join(seen)])
		assert_true(state.count_of("eat") >= 1, "%s ate" % npc_id)
		assert_true(state.count_of("drink") >= 2, "%s drank" % npc_id)
		# (The decision layer ends a rest once the fatigue is low enough for
		# something else; a rest that was lain down for counts.)
		assert_true(rests >= 1, "%s rested" % npc_id)
		assert_true(state.count_of("work") >= 1 and state.worked_usec > 0, "%s worked" % npc_id)
		# No need is left to grow: none ever reaches the danger category.
		for kind: String in NpcNeedKind.SIMULATED_KINDS:
			assert_true(float(run.highest[npc_id][kind]) < 75.0, "%s %s stays below danger: %f" % [npc_id, kind, float(run.highest[npc_id][kind])])
			assert_eq(int((run.danger_decisions[npc_id] as Dictionary).get(kind, 0)), 0)
		# What other players would have seen (docs/09 §17.5).
		for label: String in ["walk", "eat", "sleep", "work"]:
			assert_true((run.labels[npc_id] as Dictionary).has(label), "%s was seen to %s (%s)" % [npc_id, label, ",".join(seen)])
		assert_not_null(catalog.get_definition(run.npcs().get_npc(npc_id).definition_id))
	var failures: PackedStringArray = []
	for line: String in run.events:
		if line.get_slice(" ", 1) == "failed":
			failures.append(line)
	print("[npc day] failures: %d, longest streak of one failure %d; first: %s" % [failures.size(), run.longest_failure_streak(), "; ".join(failures.slice(0, 5))])
	assert_true(run.longest_failure_streak() <= 3, "no NPC is stuck in one failure: %d in a row" % run.longest_failure_streak())
	assert_true(failures.size() * 20 <= run.events.size(), "failures are rare: %d of %d events" % [failures.size(), run.events.size()])
	assert_true(run.behaviours.stocked_count >= 1, "the food containers were stocked")
	assert_true(run.behaviours.movement_executor().doors_opened_count > 0, "they went through doors")
	assert_eq(run.behaviours.movement_executor().doors_left_open_count, 0)
	run.finish()


# ------------------------------------------------------------ the same again

const SCRIPT_HOURS: float = 9.0
## How far a number of the needs component (P4-2) may be off after a save
## and a restore. Everything else must be the same to the last digit.
const NEEDS_TOLERANCE: float = 0.000000001
const SAVE_HOURS: Array[float] = [5.6, 7.3]


## "" when two documents are the same, otherwise where they differ first.
func _first_difference(actual: Variant, expected: Variant, path: String) -> String:
	if typeof(actual) == TYPE_DICTIONARY and typeof(expected) == TYPE_DICTIONARY:
		var keys: Array = (expected as Dictionary).keys()
		for key: Variant in (actual as Dictionary).keys():
			if not keys.has(key):
				keys.append(key)
		keys.sort()
		for key: Variant in keys:
			if not (actual as Dictionary).has(key) or not (expected as Dictionary).has(key):
				return "%s.%s is only in one of them" % [path, str(key)]
			var inner: String = _first_difference((actual as Dictionary)[key], (expected as Dictionary)[key], "%s.%s" % [path, str(key)])
			if not inner.is_empty():
				return inner
		return ""
	if typeof(actual) == TYPE_ARRAY and typeof(expected) == TYPE_ARRAY:
		if (actual as Array).size() != (expected as Array).size():
			return "%s has %d entries, expected %d" % [path, (actual as Array).size(), (expected as Array).size()]
		for index: int in range((actual as Array).size()):
			var inner: String = _first_difference((actual as Array)[index], (expected as Array)[index], "%s[%d]" % [path, index])
			if not inner.is_empty():
				return inner
		return ""
	if typeof(actual) == typeof(expected) and actual == expected:
		return ""
	if NEEDS_TOLERANCE > 0.0 and path.contains(".components.needs.") and typeof(actual) == TYPE_FLOAT and typeof(expected) == TYPE_FLOAT and absf(float(actual) - float(expected)) <= NEEDS_TOLERANCE:
		return ""
	return "%s is %s, expected %s" % [path, var_to_str(actual), var_to_str(expected)]


func _compare_lines(actual: PackedStringArray, expected: PackedStringArray, what: String) -> void:
	for index: int in range(mini(actual.size(), expected.size())):
		if actual[index] != expected[index]:
			fail("%s: line %d is \"%s\", expected \"%s\"" % [what, index, actual[index], expected[index]])
			return
	assert_eq(actual.size(), expected.size(), "%s: the same number of lines" % what)


func test_the_same_seed_decides_the_same_and_a_restored_run_goes_on_as_one_that_never_stopped() -> void:
	var ticks: int = roundi(SCRIPT_HOURS * float(TICKS_PER_HOUR))
	# The run that goes on. Its documents are taken on the way.
	var run: Run = _begin()
	var saves: Dictionary[int, Dictionary] = {}
	for hours: float in SAVE_HOURS:
		saves[roundi(hours * float(TICKS_PER_HOUR))] = {}
	for tick: int in range(ticks):
		if saves.has(tick):
			saves[tick] = _json(run.world.to_documents())
		run.step()
	var expected_documents: Dictionary = _json(_npc_documents(run))
	assert_true(run.decisions.size() > 500, "the NPCs decide: %d decisions" % run.decisions.size())
	var happened: String = " ".join(run.events)
	for what: String in ["finished", "drink", "work", "rest", "cancelled"]:
		assert_contains(happened, what, "the hours cover %s" % what)
	# The same seed again: the same decisions and events in the same ticks.
	var twin: Run = _begin()
	for tick: int in range(ticks):
		twin.step()
	_compare_lines(twin.decisions, run.decisions, "a second run's decisions")
	_compare_lines(twin.events, run.events, "a second run's events")
	assert_eq(_json(_npc_documents(twin)), expected_documents, "a second run ends the same")
	twin.finish()
	# Saved, restarted, restored: it goes on as the run that never stopped.
	for save_tick: int in saves:
		var busy: int = 0
		for line: String in run.events:
			busy += 1 if line.get_slice(" ", 0).to_int() < save_tick and line.get_slice(" ", 1) == "started" else 0
		var restored: Run = _begin(saves[save_tick])
		restored.tick = save_tick
		for tick: int in range(save_tick, ticks):
			restored.step()
		var expected_decisions: PackedStringArray = []
		for line: String in run.decisions:
			if line.get_slice(" ", 0).to_int() >= save_tick:
				expected_decisions.append(line)
		var expected_events: PackedStringArray = []
		for line: String in run.events:
			if line.get_slice(" ", 0).to_int() >= save_tick:
				expected_events.append(line)
		assert_true(busy > 0 and expected_events.size() > 10, "saved at tick %d: things happen before and after" % save_tick)
		_compare_lines(restored.decisions, expected_decisions, "saved at tick %d: decisions" % save_tick)
		_compare_lines(restored.events, expected_events, "saved at tick %d: events" % save_tick)
		var actual_documents: Dictionary = _json(_npc_documents(restored))
		for npc_id: String in expected_documents:
			var difference: String = _first_difference(actual_documents.get(npc_id, {}), expected_documents[npc_id], npc_id)
			assert_eq(difference, "", "saved at tick %d: every NPC ends the same, to the last digit" % save_tick)
		restored.finish()
	# And then a zombie comes to somebody who is at work.
	var worker: String = ""
	for npc_id: String in run.npcs().npc_ids():
		var state: NpcBehaviourState = run.npcs().get_npc(npc_id).component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState
		if worker.is_empty() and state.action_id == NpcBehaviours.ACTION_WORK and state.step == NpcBehaviourState.STEP_PERFORMING:
			worker = npc_id
	assert_ne(worker, "", "somebody is at work at nine in the morning")
	if worker.is_empty():
		run.finish()
		return
	var npc: NpcState = run.npcs().get_npc(worker)
	var needs: NpcNeeds = npc.component(NpcNeeds.COMPONENT_ID) as NpcNeeds
	assert_eq(needs.activity(), NpcNeedKind.WORKING)
	var stood: Vector3 = npc.position
	var zombie_at: Vector3 = stood + Vector3(1.0, 0.0, 0.0)
	var zombies: ZombieService = run.world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	assert_true(zombies.spawn_zombie(run.world, zombie_at).ok)
	var events_before: int = run.events.size()
	var fled_label: bool = false
	for tick: int in range(60):
		run.step()
		fled_label = fled_label or NpcDecisionComponent.label_of(npc) == "flee"
	var after: PackedStringArray = run.events.slice(events_before)
	var mine: PackedStringArray = []
	for line: String in after:
		if line.get_slice(" ", 2) == worker:
			mine.append(line.substr(line.find(" ") + 1))
	assert_true(mine.size() >= 2, "the worker reacts: %s" % ", ".join(mine))
	if mine.size() >= 2:
		assert_eq(mine[0], "cancelled %s work" % worker, "it stops working")
		assert_eq(mine[1], "started %s flee" % worker, "and flees")
	assert_true(fled_label, "other players see it flee")
	assert_eq(needs.activity(), NpcNeedKind.IDLE, "fleeing is not working")
	assert_true(npc.position.distance_to(zombie_at) > stood.distance_to(zombie_at) + 1.0, "it got away from the zombie: %f m" % npc.position.distance_to(zombie_at))
	var record: Dictionary = (npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent).last_record()
	assert_true(run.decider.hard_interrupt_count >= 1)
	assert_true(str(record.get(NpcUtilityDecider.KEY_CHOSEN, "")) == "flee" or run.decisions[run.decisions.size() - 1].contains("flee") or " ".join(run.decisions.slice(run.decisions.size() - 40)).contains("flee"))
	run.finish()


# ------------------------------------------------------------ cost

func test_measure_the_npc_stages_with_25_npcs() -> void:
	var run: Run = _begin()
	var definitions: PackedStringArray = NpcRoster.load_or_null().npc_definition_ids
	# Twenty more, in a ring around the middle of the map (outdoors).
	for index: int in range(20):
		var angle: float = TAU * float(index) / 20.0
		var spawned: ActionResult = run.npcs().spawn_npc(run.world, definitions[index % definitions.size()], Vector3(cos(angle) * 4.0, 0.0, sin(angle) * 4.0))
		assert_true(spawned.ok, spawned.reason)
	assert_eq(run.npcs().npc_count(), 25)
	# Six calendar hours, into the first drinks and rests.
	var ticks: int = 6 * TICKS_PER_HOUR
	var stage_msec: PackedFloat32Array = []
	var tick_usec: PackedInt32Array = []
	var busiest: int = 0
	for tick: int in range(ticks):
		var started_usec: int = Time.get_ticks_usec()
		run.step()
		tick_usec.append(Time.get_ticks_usec() - started_usec)
		stage_msec.append(run.npcs().last_step_msec)
		busiest = maxi(busiest, int(run.behaviours.movement_executor().diagnostics()["active"]))
	stage_msec.sort()
	tick_usec.sort()
	var median: float = stage_msec[stage_msec.size() / 2]
	var worst: float = stage_msec[stage_msec.size() - 1]
	print("[npc measure] 25 NPCs, %d ticks at 20 Hz: NPC stages per tick median %.4f ms, 99%% %.4f ms, worst %.4f ms; whole server tick median %.4f ms, worst %.4f ms; at most %d NPCs acting at once; %d decisions, %d behaviour events" % [
		ticks, median, stage_msec[stage_msec.size() * 99 / 100], worst,
		float(tick_usec[tick_usec.size() / 2]) / 1000.0, float(tick_usec[tick_usec.size() - 1]) / 1000.0,
		busiest, run.decisions.size(), run.events.size()])
	assert_true(run.events.size() > 50, "the 25 act: %d events" % run.events.size())
	assert_true(busiest >= 10)
	# docs/13 §16.4: the whole NPC stage with 25 NPCs, median <= 1.0 ms,
	# worst <= 2.0 ms. A target, measured on whatever machine runs this.
	assert_time_bound(median, 1.0, "NPC stages, 25 NPCs, median")
	assert_time_bound(worst, 2.0, "NPC stages, 25 NPCs, worst")
	run.finish()
