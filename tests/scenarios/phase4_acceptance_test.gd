extends TestCase
## P4-Z: the Phase 4 acceptance scenario (docs/13 §16.1, completion
## criterion §16 / §6): in the composition of a dedicated server (the test
## map, the ten dev NPCs, a fixed seed; NpcLifeRun says what differs) the
## NPCs live by themselves.
##   1. Three calendar days without anybody telling them anything: they eat,
##      drink, rest (to the end) and work every day, no need stays in the
##      danger category, nobody is stuck in one failure.
##   2. A zombie that an NPC at work sees: the work stops, the NPC flees.
##   3. The same seed twice: the same decisions and events in the same ticks.
##   4. Saved at day 1.5 through WorldPersistence into real files, a new
##      server started from those files: it goes on as the run that never
##      stopped, to the last bit of every NPC component.
##   5. The NPCs' cells are released in the middle of a day and loaded
##      again: the NPCs come back as they left and go on.
##   6. Two clients see the same NPC rows; nothing private is on the wire.
##   7. (ZSS_NPC_SOAK=1 only) ten calendar days.
## Headless, fixed ticks of 1/20 s: a calendar day (one real hour at the
## shipped time scale 24) is 72000 ticks. The cost per tick is measured in
## tests/unit/npc_measure_test.gd.

const WORLD: String = "phase4_acceptance_world"
const TICK: float = 0.05
const TICKS_PER_HOUR: int = 3000
const DAY_TICKS: int = 24 * TICKS_PER_HOUR
const DAYS: int = 3
## Day 1.5: noon of the second day (the NPCs are at work).
const SAVE_TICK: int = DAY_TICKS * 3 / 2
## How long the second run with the same seed goes: past the save.
const TWIN_TICKS: int = 2 * DAY_TICKS
const RATION: String = "dev_food_ration"

## Bounds of the three days (PROVISIONAL, docs/15 §17.10).
## A need may be in the danger category for at most this long per NPC over
## the three days (calendar minutes).
const DANGER_BOUND_CALENDAR_MIN: float = 30.0
## The same failure of one NPC in a row with nothing finished in between.
const FAILURE_STREAK_BOUND: int = 3
## At least this often per NPC and calendar day.
## "rest" is lying down: the nap (rest) and, since F-6, the night sleep.
const MIN_PER_DAY: Dictionary = {"eat": 1, "drink": 2, "rest": 1, "work": 1}

const SOAK_ENV: String = "ZSS_NPC_SOAK"
const SOAK_DAYS: int = 10

var _root: String = ""
var _cluster: NetTestCluster = null


## How often an NPC did `action` on a day; "rest" counts the naps and the
## night sleeps that ended by themselves (F-6).
func _times(day: Dictionary, action: String) -> int:
	return int(day[action]) + (int(day["sleep"]) if action == "rest" else 0)


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/phase4_%d" % Time.get_ticks_usec()
	_cluster = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
		_cluster = null
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _calendar_min(ticks: int) -> float:
	return float(ticks) * TICK * WorldClockSettings.load_or_default().time_scale / 60.0


func _hour_of(run: NpcLifeRun) -> float:
	return fmod(run.world.clock.world_time_sec, 86400.0) / 3600.0


## Prints what every NPC did per day and over the whole run.
func _log_days(run: NpcLifeRun, tag: String) -> void:
	for npc_id: String in run.npcs().npc_ids():
		var per_day: PackedStringArray = []
		for index: int in range(run.days.size()):
			var day: Dictionary = run.days[index][npc_id]
			per_day.append("d%d eat %d drink %d sleep %d(+%d cut) nap %d(+%d cut) work %d wander %d failed %d worked %.1fh" % [index + 1, day["eat"], day["drink"], day["sleep"], day["sleep_cut"], day["rest"], day["rest_cut"], day["work"], day["wander"], day["failed"], float(day["worked_usec"]) / 1000000.0 * 24.0 / 3600.0])
		var danger: PackedStringArray = []
		for kind: String in NpcNeedKind.SIMULATED_KINDS:
			danger.append("%s %.0f" % [kind, _calendar_min(int((run.danger_ticks[npc_id] as Dictionary).get(kind, 0)))])
		var seen: PackedStringArray = PackedStringArray((run.labels.get(npc_id, {}) as Dictionary).keys())
		seen.sort()
		print("[%s] %s %s: %s | highest hunger %.1f thirst %.1f fatigue %.1f | danger calendar min: %s | decisions %d | labels %s" % [
			tag, npc_id, run.npcs().get_npc(npc_id).definition_id, "; ".join(per_day),
			float(run.highest[npc_id]["hunger"]), float(run.highest[npc_id]["thirst"]), float(run.highest[npc_id]["fatigue"]),
			", ".join(danger), int(run.decision_counts[npc_id]), ",".join(seen)])
	var failures: Dictionary = run.failure_counts()
	var listed: PackedStringArray = []
	for what: String in failures:
		listed.append("%s x%d" % [what, int(failures[what])])
	listed.sort()
	print("[%s] %d decisions, %d behaviour events; failures: %s; longest streak of one failure %d; actions that could not begin: %s" % [tag, run.decisions.size(), run.events.size(), ", ".join(listed) if not listed.is_empty() else "none", run.longest_failure_streak(), str(run.refusal_counts())])


func _error_lines() -> PackedStringArray:
	var result: PackedStringArray = []
	for line: String in GameLogger.captured_lines():
		if line.contains("[ERROR]") or line.contains("[FATAL]"):
			result.append(line)
	return result


func _eaten(run: NpcLifeRun) -> int:
	var total: int = 0
	for npc_id: String in run.npcs().npc_ids():
		total += run.behaviour_of(npc_id).count_of("eat")
	return total


func _carried(run: NpcLifeRun) -> int:
	var total: int = 0
	for npc_id: String in run.npcs().npc_ids():
		for item: ItemInstance in run.behaviour_of(npc_id).carried_items():
			total += item.quantity if item.definition_id == RATION else 0
	return total


# ------------------------------------------------------------ 1, 3, 4

func test_five_npcs_live_three_days_and_a_restarted_server_goes_on_the_same() -> void:
	var root_a: String = _root.path_join("a")
	var root_b: String = _root.path_join("b")
	var started_msec: int = Time.get_ticks_msec()
	var run: NpcLifeRun = NpcLifeRun.begin_on_disk(WORLD, root_a, TICK)
	assert_not_null(run, "a new world on disk with the map and the roster")
	if run == null:
		return
	var ids: PackedStringArray = run.npcs().npc_ids()
	run.step()
	ids = run.npcs().npc_ids()
	assert_eq(ids.size(), 10, "the dev roster is in memory around the spawn point")
	var saved: bool = false
	var twin_documents: Dictionary = {}
	for day: int in range(DAYS):
		while run.tick < (day + 1) * DAY_TICKS:
			if run.tick == SAVE_TICK:
				# 4. The save of a running server, and a copy of its files for
				# the server that will be started from them.
				assert_eq(run.persistence.save(run.world), OK, "the save at day 1.5")
				assert_eq(NpcLifeRun.copy_tree(ProjectSettings.globalize_path(root_a), ProjectSettings.globalize_path(root_b)), OK)
				saved = true
			if run.tick == TWIN_TICKS:
				twin_documents = NpcLifeRun.as_saved(run.npc_documents())
			run.step()
			if run.tick % 20 == 0:
				run.see_labels()
		run.close_day()
	var first_msec: int = Time.get_ticks_msec() - started_msec
	assert_true(saved)
	assert_true(run.world.clock.world_time_sec >= float(DAYS) * 86400.0 - 1.0, "three calendar days passed: %f" % run.world.clock.world_time_sec)
	assert_true(run.world.online_player_ids().has(run.observer.player_id), "the player was there the whole time")
	print("[p4-z] %d ticks (%d calendar days at 20 Hz) in %d ms" % [run.tick, DAYS, first_msec])
	_log_days(run, "p4-z")

	# 1. They live.
	for npc_id: String in ids:
		for index: int in range(DAYS):
			var day: Dictionary = run.days[index][npc_id]
			for action: String in MIN_PER_DAY:
				assert_true(_times(day, action) >= int(MIN_PER_DAY[action]), "%s on day %d: %s %d times (at least %d)" % [npc_id, index + 1, action, _times(day, action), int(MIN_PER_DAY[action])])
			assert_true(int(day["worked_usec"]) > 0, "%s worked on day %d" % [npc_id, index + 1])
		for kind: String in NpcNeedKind.SIMULATED_KINDS:
			var minutes: float = _calendar_min(int((run.danger_ticks[npc_id] as Dictionary).get(kind, 0)))
			assert_true(minutes <= DANGER_BOUND_CALENDAR_MIN, "%s: %s in the danger category for %.0f calendar minutes (at most %.0f)" % [npc_id, kind, minutes, DANGER_BOUND_CALENDAR_MIN])
		for label: String in ["walk", "eat", "sleep", "work"]:
			assert_true((run.labels[npc_id] as Dictionary).has(label), "%s was seen to %s" % [npc_id, label])
	assert_true(run.longest_failure_streak() <= FAILURE_STREAK_BOUND, "nobody is stuck in one failure: %d in a row" % run.longest_failure_streak())
	# The food: 40 units per house (20 until 2026-11-23), nothing refills them (docs/15 P4-213).
	var eaten: int = _eaten(run)
	var left: int = run.units_in_containers(RATION)
	var stocked: int = run.behaviours.stocked_count * 40
	print("[p4-z] food: %d containers stocked (%d units), %d eaten in %d days by 10 NPCs, %d carried, %d left in the containers: at this rate %.1f more days" % [run.behaviours.stocked_count, stocked, eaten, DAYS, _carried(run), left, float(left) / maxf(float(eaten) / float(DAYS), 0.001)])
	assert_eq(stocked - eaten - _carried(run), left, "every unit is in a container, carried or eaten")
	assert_eq(int(run.failure_counts().get("eat no_resource", 0)) + int(run.refusal_counts().get("eat", 0)), 0, "the food lasts three days: nobody goes without")
	assert_true(run.behaviours.movement_executor().doors_opened_count > 0, "they went through doors")
	assert_eq(run.behaviours.movement_executor().doors_left_open_count, 0)
	assert_eq(_error_lines().size(), 0, "no errors in three days: %s" % "; ".join(_error_lines().slice(0, 3)))
	var expected_documents: Dictionary = NpcLifeRun.as_saved(run.npc_documents())
	var expected_world: Dictionary = NpcLifeRun.as_saved(run.world.to_documents())

	# 4. The server started from the files of day 1.5.
	var restored: NpcLifeRun = NpcLifeRun.begin_on_disk(WORLD, root_b, TICK)
	assert_not_null(restored, "the save of day 1.5 loads")
	if restored != null:
		assert_eq(restored.observer.player_id, run.observer.player_id, "the same player comes back")
		restored.tick = SAVE_TICK
		restored.run_ticks(DAYS * DAY_TICKS - SAVE_TICK, 0)
		var expected_decisions: PackedStringArray = NpcLifeRun.lines_from(run.decisions, SAVE_TICK)
		var expected_events: PackedStringArray = NpcLifeRun.lines_from(run.events, SAVE_TICK)
		assert_true(expected_decisions.size() > 1000 and expected_events.size() > 100, "things happen after the save: %d decisions, %d events" % [expected_decisions.size(), expected_events.size()])
		assert_eq(NpcLifeRun.first_line_difference(restored.decisions, expected_decisions), "", "restarted at day 1.5: the same decisions")
		assert_eq(NpcLifeRun.first_line_difference(restored.events, expected_events), "", "restarted at day 1.5: the same events")
		var actual_documents: Dictionary = NpcLifeRun.as_saved(restored.npc_documents())
		assert_eq(NpcLifeRun.differences(actual_documents, expected_documents, "npcs"), "", "restarted at day 1.5: every NPC component ends the same, to the last bit")
		var actual_world: Dictionary = NpcLifeRun.as_saved(restored.world.to_documents())
		assert_eq(NpcLifeRun.differences(actual_world, expected_world, "world"), "", "restarted at day 1.5: the whole world ends the same")
		print("[p4-z] final state hash: uninterrupted %s, restarted at day 1.5 %s (NPC documents %s / %s)" % [NpcLifeRun.hash_of(expected_world).left(16), NpcLifeRun.hash_of(actual_world).left(16), NpcLifeRun.hash_of(expected_documents).left(16), NpcLifeRun.hash_of(actual_documents).left(16)])
		assert_eq(NpcLifeRun.hash_of(actual_world), NpcLifeRun.hash_of(expected_world), "the final state hash")
		restored.finish()

	# 3. The same seed again (a world in memory, never saved).
	var twin: NpcLifeRun = NpcLifeRun.begin_in_memory(WORLD, TICK)
	assert_not_null(twin)
	if twin != null:
		twin.run_ticks(TWIN_TICKS, 0)
		assert_eq(NpcLifeRun.first_line_difference(twin.decisions, NpcLifeRun.lines_from(run.decisions, 0, TWIN_TICKS)), "", "the same seed: the same decisions")
		assert_eq(NpcLifeRun.first_line_difference(twin.events, NpcLifeRun.lines_from(run.events, 0, TWIN_TICKS)), "", "the same seed: the same events")
		assert_eq(NpcLifeRun.first_difference(NpcLifeRun.as_saved(twin.npc_documents()), twin_documents, "npcs"), "", "the same seed: the same NPCs after two days")
		print("[p4-z] same seed twice: %d decisions and %d events over 2 days are the same" % [twin.decisions.size(), twin.events.size()])
		twin.finish()
	print("[p4-z] the whole test took %d ms" % (Time.get_ticks_msec() - started_msec))
	run.finish()


# ------------------------------------------------------------ 2

func test_an_npc_at_work_that_sees_a_zombie_stops_working_and_flees() -> void:
	var run: NpcLifeRun = NpcLifeRun.begin_in_memory(WORLD, TICK)
	assert_not_null(run)
	if run == null:
		return
	# Until somebody is at its work place in the morning.
	run.run_ticks(9 * TICKS_PER_HOUR, 0)
	var worker: String = ""
	for attempt: int in range(2 * TICKS_PER_HOUR):
		for npc_id: String in run.npcs().npc_ids():
			var state: NpcBehaviourState = run.behaviour_of(npc_id)
			if worker.is_empty() and state.action_id == NpcBehaviours.ACTION_WORK and state.step == NpcBehaviourState.STEP_PERFORMING:
				worker = npc_id
		if not worker.is_empty():
			break
		run.step()
	assert_ne(worker, "", "somebody is at work between nine and eleven")
	if worker.is_empty():
		run.finish()
		return
	var npc: NpcState = run.npcs().get_npc(worker)
	var needs: NpcNeeds = npc.component(NpcNeeds.COMPONENT_ID) as NpcNeeds
	assert_eq(needs.activity(), NpcNeedKind.WORKING)
	assert_eq(NpcDecisionComponent.label_of(npc), "work")
	var worked_before: int = run.behaviour_of(worker).worked_usec
	var stood: Vector3 = npc.position
	# A zombie in the same room, in plain view.
	var zombie_at: Vector3 = stood
	for offset: Vector3 in [Vector3(1.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(0.0, 0.0, -1.0)]:
		if zombie_at == stood and not run.world.is_line_blocked(stood, stood + offset):
			zombie_at = stood + offset
	assert_ne(zombie_at, stood, "test setup: a place next to the worker with a clear line")
	var zombies: ZombieService = run.world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	assert_true(zombies.spawn_zombie(run.world, zombie_at).ok)
	var events_before: int = run.events.size()
	var hard_before: int = run.decider.hard_interrupt_count
	var spawned_tick: int = run.tick
	var fled_label: bool = false
	var reacted_tick: int = -1
	for tick: int in range(60):
		run.step()
		fled_label = fled_label or NpcDecisionComponent.label_of(npc) == "flee"
		if reacted_tick < 0 and run.behaviour_of(worker).action_id == NpcBehaviours.ACTION_FLEE:
			reacted_tick = run.tick
	var mine: PackedStringArray = []
	for line: String in run.events.slice(events_before):
		if line.get_slice(" ", 2) == worker:
			mine.append(line.substr(line.find(" ") + 1))
	print("[p4-z zombie] %s at work at %.2f h; a zombie 1 m away: %s; fleeing after %d ticks (%.2f s); %.1f m from it 3 s later" % [worker, _hour_of(run), ", ".join(mine), reacted_tick - spawned_tick, float(reacted_tick - spawned_tick) * TICK, npc.position.distance_to(zombie_at)])
	assert_true(mine.size() >= 2, "the worker reacts: %s" % ", ".join(mine))
	if mine.size() >= 2:
		assert_eq(mine[0], "cancelled %s work" % worker, "it stops working")
		assert_eq(mine[1], "started %s flee" % worker, "and flees")
	assert_true(reacted_tick >= 0 and reacted_tick - spawned_tick <= 12, "within the threat check period (0.5 s) and a tick")
	assert_true(fled_label, "other players see it flee")
	assert_eq(needs.activity(), NpcNeedKind.IDLE, "fleeing is not working")
	assert_true(run.decider.hard_interrupt_count > hard_before, "a hard interrupt, not a utility choice")
	assert_true(npc.position.distance_to(zombie_at) > stood.distance_to(zombie_at) + 1.0, "it got away from the zombie: %f m" % npc.position.distance_to(zombie_at))
	assert_true(run.behaviour_of(worker).worked_usec >= worked_before, "the time it worked is kept")
	run.finish()


# ------------------------------------------------------------ 5

func test_npc_cells_released_in_the_middle_of_a_day_come_back_and_the_npcs_go_on() -> void:
	const CORNER: Vector3 = Vector3(-240.0, 0.0, -240.0)
	# Longer than the shipped deactivate (5 s) + unload (20 s) delays.
	const AWAY_TICKS: int = 600
	var run: NpcLifeRun = NpcLifeRun.begin_on_disk(WORLD, _root.path_join("cells"), TICK)
	assert_not_null(run)
	if run == null:
		return
	# Ten in the morning: at work, on the way, at the water.
	run.run_ticks(10 * TICKS_PER_HOUR, 0)
	var npcs: NpcService = run.npcs()
	var ids: PackedStringArray = npcs.npc_ids()
	assert_eq(ids.size(), 10)
	var busy: int = 0
	var counts_before: Dictionary = {}
	for npc_id: String in ids:
		busy += 1 if run.behaviour_of(npc_id).is_running() else 0
		counts_before[npc_id] = run.counts_of(npc_id)
	assert_true(busy >= 3, "they are in the middle of things: %d of 10 act" % busy)
	var home: Vector3 = run.observer.position
	# The player leaves: the cells go to sleep, then out of memory (into
	# their files). What every NPC was when it stopped is kept.
	var asleep: Dictionary = {}
	run.observer.position = CORNER
	var gone_tick: int = -1
	for tick: int in range(AWAY_TICKS):
		run.step()
		for npc_id: String in npcs.npc_ids():
			if not npcs.is_awake(npc_id):
				asleep[npc_id] = NpcLifeRun.as_saved(npcs.npc_document(npc_id))
		if gone_tick < 0 and npcs.npc_count() == 0:
			gone_tick = tick
	assert_eq(npcs.npc_count(), 0, "the NPCs left memory with their cells")
	assert_eq(asleep.size(), 10, "every NPC slept before it left")
	assert_eq(npcs.population_count(), 10, "the world still knows its ten")
	var on_disk: PackedStringArray = SaveService.new(_root.path_join("cells")).saved_cell_ids(WORLD)
	assert_true(on_disk.size() > 0, "the cells are in files")
	var decisions_away: int = run.decisions.size()
	# The player comes back.
	var entered: Dictionary = {}
	var on_entered: Callable = func(npc_id: String) -> void: entered[npc_id] = NpcLifeRun.as_saved(npcs.npc_document(npc_id))
	npcs.npc_entered.connect(on_entered)
	run.observer.position = home
	var back_tick: int = run.tick
	run.step()
	npcs.npc_entered.disconnect(on_entered)
	assert_eq(npcs.npc_ids(), ids, "the same ten are back")
	assert_eq(entered.size(), 10)
	for npc_id: String in ids:
		assert_eq(NpcLifeRun.first_difference(entered.get(npc_id, {}), asleep.get(npc_id, {}), npc_id), "", "%s comes back as it left, to the last bit" % npc_id)
	# And they go on: three more calendar hours.
	run.run_ticks(3 * TICKS_PER_HOUR, 0)
	var after: PackedStringArray = NpcLifeRun.lines_from(run.events, back_tick)
	var failed: PackedStringArray = []
	var finished: Dictionary = {}
	for line: String in after:
		if line.get_slice(" ", 1) == "failed":
			failed.append(line)
		elif line.get_slice(" ", 1) == "finished":
			finished[line.get_slice(" ", 2)] = true
	print("[p4-z cells] released after %d ticks away (%d cell files), back at tick %d: %d decisions and %d events in the 3 h after, failures: %s" % [gone_tick, on_disk.size(), back_tick, run.decisions.size() - decisions_away, after.size(), "; ".join(failed) if not failed.is_empty() else "none"])
	assert_eq(failed.size(), 0, "nothing was lost on the way: no action fails after the cells came back")
	for npc_id: String in ids:
		assert_true(npcs.is_awake(npc_id), "%s is awake" % npc_id)
		assert_true(finished.has(npc_id), "%s finished something after it came back" % npc_id)
		var now: Dictionary = run.counts_of(npc_id)
		for name: String in now:
			assert_true(int(now[name]) >= int(counts_before[npc_id][name]), "%s: the count of %s was kept" % [npc_id, name])
	assert_true(run.longest_failure_streak() <= FAILURE_STREAK_BOUND)
	run.finish()


# ------------------------------------------------------------ 6

const NET_WAIT_TICKS: int = 600
## Names of server-only NPC data that must not be in what a client is sent
## (docs/13 §16.3 D9, docs/09 §17.5).
const PRIVATE_WORDS: PackedStringArray = [
	"dev_npc_", "definition", "component", "needs", "hunger", "thirst", "fatigue", "emotion", "memor", "relationship",
	"personality", "courage", "conscientiousness", "skill", "goal", "rng", "seed", "schedule", "decision", "behaviour",
	"executor", "job", "home_building", "work_building", "background", "inventory", "worked", "counts", "simulation_tier",
]


func _npc_module(service: NetworkService) -> NpcNetModule:
	return service.get_module(NpcNetModule.MODULE_NAME) as NpcNetModule


func _mirror(service: NetworkService) -> ClientNpcState:
	return _npc_module(service).client_state


func _rows(service: NetworkService) -> Dictionary:
	var rows: Dictionary = {}
	for npc_id: String in _mirror(service).npc_ids():
		rows[npc_id] = _mirror(service).get_npc(npc_id)
	return rows


func test_two_clients_see_the_same_npcs_and_nothing_private_is_sent() -> void:
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	var decider: NpcUtilityDecider = NpcLifeRun.new_decider()
	var config: CompositionConfig = NpcLifeRun.config(decider)
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	assert_not_null(world)
	if world == null:
		return
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	assert_eq(world.seed_new_world(DevWorldSeed.new()), OK)
	_cluster = NetTestCluster.new(tree, network_settings, config)
	assert_eq(_cluster.start_server(world, null), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	assert_true(a != null and b != null, "two clients joined")
	if a == null or b == null:
		return
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _mirror(a).npc_count() == 10 and _mirror(b).npc_count() == 10, NET_WAIT_TICKS), "both clients know the ten NPCs")
	# They start to act by themselves (their first decision comes within 2 s
	# or 10 s): both clients see a label that is not "idle".
	var acting: Callable = func() -> bool:
		for npc_id: String in _mirror(a).npc_ids():
			var label: String = str(_mirror(a).get_npc(npc_id).get(NpcNetProtocol.KEY_ACTION_LABEL, ""))
			if label != "idle" and str(_mirror(b).get_npc(npc_id).get(NpcNetProtocol.KEY_ACTION_LABEL, "")) == label:
				return true
		return false
	assert_true(await _cluster.wait_ticks_until(acting, NET_WAIT_TICKS), "both clients see an NPC do something")
	# The same rows on both, and they are the server's public state.
	var same: Callable = func() -> bool: return _rows(a) == _rows(b) and _rows(a).size() == 10
	assert_true(await _cluster.wait_ticks_until(same, NET_WAIT_TICKS), "both clients hold the same NPC rows")
	var rows: Dictionary = _rows(a)
	var public_keys: Array = [NpcNetProtocol.KEY_NPC_ID, NpcNetProtocol.KEY_NAME, NpcNetProtocol.KEY_APPEARANCE, NpcNetProtocol.KEY_POSITION, NpcNetProtocol.KEY_YAW, NpcNetProtocol.KEY_ACTION_LABEL, NpcNetProtocol.KEY_POSTURE, NpcNetProtocol.KEY_CONDITION, NpcNetProtocol.KEY_REACTION]
	public_keys.sort()
	var labels_seen: PackedStringArray = []
	for npc_id: String in npcs.npc_ids():
		assert_true(rows.has(npc_id), "%s is on the clients" % npc_id)
		if not rows.has(npc_id):
			continue
		var row: Dictionary = rows[npc_id]
		var keys: Array = row.keys()
		keys.sort()
		assert_eq(keys, public_keys, "a row is the seven public values and nothing else")
		assert_eq(row[NpcNetProtocol.KEY_NAME], npcs.definition_of(npc_id).display_name)
		assert_true(NpcNetProtocol.ACTION_LABELS.has(str(row[NpcNetProtocol.KEY_ACTION_LABEL])))
		assert_true((row[NpcNetProtocol.KEY_POSITION] as Vector3).distance_to(npcs.get_npc(npc_id).position) < 2.0, "%s is where the server has it (within a snapshot)" % npc_id)
		labels_seen.append("%s=%s" % [npc_id, str(row[NpcNetProtocol.KEY_ACTION_LABEL])])
	# What is sent: the join fragment of each client, and the events and
	# snapshots the mirrors took (they refuse anything but public rows).
	for client: NetworkService in [a, b]:
		var wire_text: String = var_to_str(_npc_module(_cluster.server).build_join_fragment(client.client_state.local_player_id)) + var_to_str(_mirror(client).recent_events())
		assert_true(wire_text.length() > 200, "test setup: there is something on the wire")
		for word: String in PRIVATE_WORDS:
			assert_not_contains(wire_text, word, "nothing private on the wire: " + word)
		assert_eq(_mirror(client).rejected_payload_count, 0)
		assert_eq(_mirror(client).event_gap_count, 0)
	print("[p4-z net] two clients, the same %d rows: %s" % [labels_seen.size(), ", ".join(labels_seen)])


# ------------------------------------------------------------ 7

func test_soak_ten_calendar_days() -> void:
	if OS.get_environment(SOAK_ENV) != "1":
		print("[p4-z soak] skipped (set %s=1 to run ten calendar days)" % SOAK_ENV)
		assert_true(true)
		return
	var started_msec: int = Time.get_ticks_msec()
	var run: NpcLifeRun = NpcLifeRun.begin_in_memory(WORLD, TICK)
	assert_not_null(run)
	if run == null:
		return
	# The first day (from 0) at whose end the food containers are empty.
	var empty_day: int = -1
	var empty_tick: int = -1
	for day: int in range(SOAK_DAYS):
		run.run_ticks(DAY_TICKS)
		run.close_day()
		var left: int = run.units_in_containers(RATION)
		if empty_day < 0 and run.behaviours.stocked_count == 3 and left == 0:
			empty_day = day
			empty_tick = run.tick
		print("[p4-z soak] day %d: %d rations left in the containers, %d eaten so far" % [day + 1, left, _eaten(run)])
	_log_days(run, "p4-z soak")
	var refused_after: Dictionary = run.refusal_counts(empty_tick) if empty_tick >= 0 else {}
	print("[p4-z soak] %d days in %d ms; the food containers were empty at the end of day %s; after that: eating could not begin %d times" % [SOAK_DAYS, Time.get_ticks_msec() - started_msec, str(empty_day + 1) if empty_day >= 0 else "(never)", int(refused_after.get("eat", 0))])
	assert_true(run.world.clock.world_time_sec >= float(SOAK_DAYS) * 86400.0 - 1.0)
	for npc_id: String in run.npcs().npc_ids():
		for index: int in range(SOAK_DAYS):
			var day: Dictionary = run.days[index][npc_id]
			if empty_day < 0 or index < empty_day:
				# With food: a whole life, as in the three days.
				for action: String in MIN_PER_DAY:
					assert_true(_times(day, action) >= int(MIN_PER_DAY[action]), "%s on day %d: %s %d times" % [npc_id, index + 1, action, _times(day, action)])
			else:
				# Without food (40 units per house and nothing refills them,
				# docs/15 P4-213): what the rules say happens, not a stall. The
				# NPC still drinks and lies down, and it does something else
				# when it cannot eat. An NPC whose hunger is in the danger
				# category refuses to work (D3) and is woken by it (P4-172).
				assert_true(int(day["drink"]) >= int(MIN_PER_DAY["drink"]), "%s on day %d without food: drink %d times" % [npc_id, index + 1, int(day["drink"])])
				assert_true(int(day["rest"]) + int(day["rest_cut"]) + int(day["sleep"]) + int(day["sleep_cut"]) >= 1, "%s on day %d without food: it lies down" % [npc_id, index + 1])
				assert_true(int(day["work"]) + int(day["wander"]) >= 1, "%s on day %d without food: it goes on with something" % [npc_id, index + 1])
		for kind: String in [NpcNeedKind.THIRST, NpcNeedKind.FATIGUE]:
			var minutes: float = _calendar_min(int((run.danger_ticks[npc_id] as Dictionary).get(kind, 0)))
			assert_true(minutes <= DANGER_BOUND_CALENDAR_MIN * float(SOAK_DAYS) / float(DAYS), "%s: %s in danger for %.0f calendar minutes" % [npc_id, kind, minutes])
		if empty_day < 0:
			assert_true(_calendar_min(int((run.danger_ticks[npc_id] as Dictionary).get(NpcNeedKind.HUNGER, 0))) <= DANGER_BOUND_CALENDAR_MIN * float(SOAK_DAYS) / float(DAYS))
	if empty_day >= 0 and empty_day < SOAK_DAYS - 1:
		assert_true(int(refused_after.get("eat", 0)) > 0, "without food the NPCs try to eat and cannot (no_resource)")
	# Nobody is stuck in one failing behaviour.
	assert_true(run.longest_failure_streak() <= FAILURE_STREAK_BOUND, "nobody is stuck in one failure: %d in a row" % run.longest_failure_streak())
	assert_eq(_error_lines().size(), 0, "no errors: %s" % "; ".join(_error_lines().slice(0, 3)))
	run.finish()
