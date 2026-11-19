extends TestCase
## P4-Z: what the NPC stages cost per server tick with 5, 25 and 50 NPCs
## (100 only with ZSS_NPC_MEASURE_100=1), against the budget of docs/13
## §16.4. The composition of a dedicated server (NpcLifeRun), the same map
## for every count: the five dev NPCs plus copies of them placed in rings
## around the spawn point (they share the houses, beds, water and work
## places of the five, so the larger counts also fight over spots).
##
## One long run per count instead of repetitions: the first 5.5 calendar
## hours go by in ticks of 1/20 s (nothing is measured), then 3 calendar
## hours are measured in ticks of 1/60 s, the tick of a server (27000
## ticks). Those hours hold the first drinks (06:00), the end of the night
## and the walk to work (08:00): the busiest part of a day.
##
## Every number is wall clock time on whatever machine runs this, with
## whatever else runs there. The bounds are assert_time_bound: a warning
## unless ZSS_STRICT_TIMING=1.
##
## The run is deterministic: the same tick does the same work every time.
## So the 25 NPC run is made three times and every tick's SMALLEST time of
## the three is kept beside the raw numbers: a slow tick that is slow in
## all three is the code, one that is slow once is the machine (docs/15
## §17.10).

const WORLD: String = "npc_measure_world"
const WARM_TICK: float = 0.05
const WARM_TICKS: int = 16500
const MEASURE_TICK: float = 1.0 / 60.0
const MEASURE_TICKS: int = 27000
const RING_SIZE: int = 20
const RING_FIRST_RADIUS_M: float = 3.0
const HUNDRED_ENV: String = "ZSS_NPC_MEASURE_100"
## How many of the slowest ticks are printed with what each stage took.
const WORST_SHOWN: int = 5
const DOCUMENT_REPEATS: int = 25
const REPEATS_25: int = 3


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


static func _percentile(sorted: PackedFloat32Array, fraction: float) -> float:
	return sorted[mini(int(float(sorted.size()) * fraction), sorted.size() - 1)]


## Runs the measurement with `count` NPCs. {} when the world could not be
## made, otherwise {median, p99, worst, tick_median, tick_worst,
## documents_median} in ms.
func _measure(count: int, repeats: int = 1) -> Dictionary:
	var result: Dictionary = {}
	# Per tick, the smallest NPC stage time of the repeats.
	var least: PackedFloat32Array = []
	for repeat: int in range(repeats):
		var one: Dictionary = _measure_once(count, least)
		if one.is_empty():
			return {}
		if repeat == 0:
			result = one
	var sorted: PackedFloat32Array = least.duplicate()
	sorted.sort()
	result["repeatable_worst"] = sorted[sorted.size() - 1]
	result["repeatable_p99"] = _percentile(sorted, 0.99)
	if repeats > 1:
		var over: int = 0
		var worst_tick: int = 0
		for tick: int in range(least.size()):
			over += 1 if least[tick] > 2.0 else 0
			worst_tick = tick if least[tick] > least[worst_tick] else worst_tick
		print("[npc measure] %d NPCs, every tick's smallest time of %d runs (what the code costs, without what the machine did): 99%% %.4f ms, worst %.4f ms (tick %d), %d ticks over 2 ms" % [count, repeats, float(result["repeatable_p99"]), float(result["repeatable_worst"]), worst_tick, over])
	return result


func _measure_once(count: int, least: PackedFloat32Array) -> Dictionary:
	var run: NpcLifeRun = NpcLifeRun.begin_in_memory(WORLD, WARM_TICK, maxi(count, 50))
	assert_not_null(run)
	if run == null:
		return {}
	var npcs: NpcService = run.npcs()
	run.step()
	var definitions: PackedStringArray = NpcRoster.load_or_null().npc_definition_ids
	var extra: int = count - npcs.npc_count()
	for index: int in range(extra):
		var ring: int = index / RING_SIZE
		var angle: float = TAU * float(index % RING_SIZE) / float(RING_SIZE)
		var radius: float = RING_FIRST_RADIUS_M + float(ring)
		var spawned: ActionResult = npcs.spawn_npc(run.world, definitions[index % definitions.size()], Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
		assert_true(spawned.ok, spawned.reason)
	assert_eq(npcs.npc_count(), count)
	run.run_ticks(WARM_TICKS - 1, 0)
	var scheduler: NpcScheduler = run.decider.scheduler()
	var sensor: NpcThreatSensor = run.decider.threat_sensor()
	var executor: NpcExecutor = run.behaviours.movement_executor()
	run.tick_sec = MEASURE_TICK
	var events_before: int = run.events.size()
	var decisions_before: int = run.decisions.size()
	var searches_before: int = executor.total_search_count
	var stage_msec: PackedFloat32Array = []
	var tick_msec: PackedFloat32Array = []
	# Per tick: [stages ms, tick, scheduler+decider us, sensor us, executor us,
	# behaviours us, decisions, plan nodes, plan turns, moves, whole tick ms,
	# doors opened or closed, searches begun, actions begun].
	var rows: Array[Array] = []
	var busiest: int = 0
	var doors: int = executor.doors_opened_count + executor.doors_closed_count
	var searches: int = executor.total_search_count
	var begun: int = run.behaviours.started_count
	# What a thing costs on average: [usec, count] of the ticks that did
	# only that thing.
	var plan_cost: Array[int] = [0, 0]
	var move_cost: Array[int] = [0, 0]
	var decision_cost: Array[int] = [0, 0]
	var begin_cost: Array[int] = [0, 0]
	for tick: int in range(MEASURE_TICKS):
		var started_usec: int = Time.get_ticks_usec()
		run.step()
		var whole: float = float(Time.get_ticks_usec() - started_usec) / 1000.0
		tick_msec.append(whole)
		stage_msec.append(npcs.last_step_msec)
		var doors_now: int = executor.doors_opened_count + executor.doors_closed_count
		rows.append([npcs.last_step_msec, tick, scheduler.last_step_usec, sensor.last_step_usec, executor.last_step_usec, run.behaviours.last_step_usec, scheduler.last_decision_count, executor.last_plan_node_count, executor.last_plan_turn_count, executor.last_move_count, whole, doors_now - doors, executor.total_search_count - searches, run.behaviours.started_count - begun])
		if least.size() <= tick:
			least.append(npcs.last_step_msec)
		else:
			least[tick] = minf(least[tick], npcs.last_step_msec)
		if executor.last_plan_node_count > 0 and doors_now == doors:
			plan_cost[0] += executor.last_step_usec
			plan_cost[1] += executor.last_plan_node_count
		elif executor.last_move_count > 0 and doors_now == doors:
			move_cost[0] += executor.last_step_usec
			move_cost[1] += executor.last_move_count
		if scheduler.last_decision_count > 0:
			if run.behaviours.started_count > begun:
				begin_cost[0] += scheduler.last_step_usec
				begin_cost[1] += run.behaviours.started_count - begun
			else:
				decision_cost[0] += scheduler.last_step_usec
				decision_cost[1] += scheduler.last_decision_count
		doors = doors_now
		searches = executor.total_search_count
		begun = run.behaviours.started_count
		busiest = maxi(busiest, int(executor.diagnostics()["active"]))
	# The NPC documents of a save (docs/13 §16.4: 25 NPCs <= 2 ms).
	var document_msec: PackedFloat32Array = []
	for repeat: int in range(DOCUMENT_REPEATS):
		var started_usec: int = Time.get_ticks_usec()
		for npc_id: String in npcs.npc_ids():
			npcs.npc_document(npc_id)
		document_msec.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)
	document_msec.sort()
	stage_msec.sort()
	tick_msec.sort()
	var result: Dictionary = {
		"median": _percentile(stage_msec, 0.5), "p99": _percentile(stage_msec, 0.99), "worst": stage_msec[stage_msec.size() - 1],
		"tick_median": _percentile(tick_msec, 0.5), "tick_p99": _percentile(tick_msec, 0.99), "tick_worst": tick_msec[tick_msec.size() - 1],
		"documents_median": _percentile(document_msec, 0.5),
	}
	var over_2ms: int = 0
	for value: float in stage_msec:
		over_2ms += 1 if value > 2.0 else 0
	print("[npc measure] %d NPCs, %d ticks at 60 Hz (calendar 05:30-08:30): NPC stages per tick median %.4f ms, 99%% %.4f ms, worst %.4f ms, %d ticks over 2 ms; whole server tick median %.4f ms, 99%% %.4f ms, worst %.4f ms; at most %d NPCs acting at once; %d decisions, %d behaviour events, %d path searches (peak %d plan nodes in a tick); NPC documents of a save: median %.4f ms" % [
		count, MEASURE_TICKS, float(result["median"]), float(result["p99"]), float(result["worst"]), over_2ms,
		float(result["tick_median"]), float(result["tick_p99"]), float(result["tick_worst"]), busiest,
		run.decisions.size() - decisions_before, run.events.size() - events_before, executor.total_search_count - searches_before, executor.peak_plan_nodes_per_tick,
		float(result["documents_median"])])
	print("[npc measure] %d NPCs, average cost: a path node %.0f us (executor time of the ticks that planned, per node; their moves included), a move %.0f us (ticks that only moved), a decision that keeps or ends something %.0f us, a tick in which an action begins %.0f us per action (scheduler + decider + finding the spot + starting the search)" % [
		count, float(plan_cost[0]) / maxf(float(plan_cost[1]), 1.0), float(move_cost[0]) / maxf(float(move_cost[1]), 1.0), float(decision_cost[0]) / maxf(float(decision_cost[1]), 1.0), float(begin_cost[0]) / maxf(float(begin_cost[1]), 1.0)])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	for index: int in range(mini(WORST_SHOWN, rows.size())):
		var row: Array = rows[index]
		var named: float = float(int(row[2]) + int(row[3]) + int(row[4]) + int(row[5])) / 1000.0
		print("[npc measure] %d NPCs, slowest tick #%d (tick %d): stages %.3f ms = scheduler+decider %.3f + threat sensor %.3f + executor %.3f + behaviours %.3f (+ %.3f outside the stages' own clocks); %d decisions, %d actions begun, %d searches begun, %d plan nodes in %d turns, %d moves, %d doors; whole tick %.3f ms" % [
			count, index + 1, int(row[1]), float(row[0]), float(int(row[2])) / 1000.0, float(int(row[3])) / 1000.0, float(int(row[4])) / 1000.0, float(int(row[5])) / 1000.0, float(row[0]) - named,
			int(row[6]), int(row[13]), int(row[12]), int(row[7]), int(row[8]), int(row[9]), int(row[11]), float(row[10])])
	assert_true(run.events.size() - events_before > count, "the %d act: %d events" % [count, run.events.size() - events_before])
	run.finish()
	return result


func test_measure_the_npc_stages_with_5_npcs() -> void:
	var result: Dictionary = _measure(5)
	if result.is_empty():
		return
	# docs/13 §16.4: 5 NPCs, median <= 0.3 ms.
	assert_time_bound(float(result["median"]), 0.3, "NPC stages, 5 NPCs, median")


func test_measure_the_npc_stages_with_25_npcs() -> void:
	var result: Dictionary = _measure(25, REPEATS_25)
	if result.is_empty():
		return
	# docs/13 §16.4: 25 NPCs, median <= 1.0 ms, worst <= 2.0 ms; the NPC
	# documents of a save <= 2 ms. The worst is the repeatable one (every
	# tick's smallest time of three runs); the raw worst is printed above.
	assert_time_bound(float(result["median"]), 1.0, "NPC stages, 25 NPCs, median")
	assert_time_bound(float(result["repeatable_worst"]), 2.0, "NPC stages, 25 NPCs, worst (repeatable)")
	assert_time_bound(float(result["documents_median"]), 2.0, "NPC documents of a save, 25 NPCs")


func test_measure_the_npc_stages_with_50_npcs() -> void:
	# The limit of the shipped settings (D1). No budget is written for it.
	var result: Dictionary = _measure(50)
	assert_false(result.is_empty())


func test_measure_the_npc_stages_with_100_npcs() -> void:
	if OS.get_environment(HUNDRED_ENV) != "1":
		print("[npc measure] 100 NPCs skipped (set %s=1)" % HUNDRED_ENV)
		assert_true(true)
		return
	var result: Dictionary = _measure(100)
	assert_false(result.is_empty())
