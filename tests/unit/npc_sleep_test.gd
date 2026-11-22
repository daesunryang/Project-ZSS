extends TestCase
## F-6: the night sleep and the naps of the five dev NPCs, in the
## composition of a dedicated server (NpcLifeRun: the shipped settings, map,
## roster, spots and actions; docs/09 §17.11). Nobody tells the NPCs
## anything. Over the first day and the night after it every NPC goes to bed
## at its own bedtime (NpcDefinition.bedtime_hour: the morning types before
## the evening types), sleeps until its fatigue is 0, does not go to bed a
## second time in that night, and naps only when its fatigue is high.
## The rules themselves are tested piece by piece in npc_decision_test.gd
## (bedtime, once a night, nap threshold, waking on danger, save) and
## npc_behaviour_test.gd (until fatigue 0, where it sleeps). Headless, fixed
## ticks of 1/20 s: a calendar hour (150 real seconds at the shipped time
## scale) is 3000 ticks.

const WORLD: String = "npc_sleep_world"
const TICK: float = 0.05
const TICKS_PER_HOUR: int = 3000
## From midnight of day 1 to 05:00 of day 2.
const RUN_HOURS: int = 29
const NOON_TICK: int = 12 * TICKS_PER_HOUR
## An NPC that is busy at its bedtime (eating, a nap that is not over) goes
## to bed this much later at most.
const LATEST_HOURS_AFTER_BEDTIME: float = 2.0


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


func test_over_a_day_every_dev_npc_sleeps_once_from_its_own_bedtime_until_fatigue_is_zero() -> void:
	var run: NpcLifeRun = NpcLifeRun.begin_in_memory(WORLD, TICK)
	assert_not_null(run, "test setup: the world")
	if run == null:
		return
	assert_eq(run.world.clock.time_scale, 24.0, "test setup: the shipped time scale")
	var nap_threshold: float = NpcActionCatalog.load_directory().get_action(NpcBehaviours.ACTION_REST).min_need_urgency * NpcNeedSettings.load_or_default().need_max
	# npc_id -> [[tick, fatigue], ...]: the night sleeps that ended by
	# themselves, and the naps that began.
	var slept: Dictionary = {}
	var napped: Dictionary = {}
	run.behaviours.behaviour_finished.connect(func(npc_id: String, action_id: String, info: Dictionary) -> void:
		if action_id == NpcBehaviours.ACTION_SLEEP:
			(slept.get_or_add(npc_id, []) as Array).append([run.tick, float(info.get(NpcNeedKind.FATIGUE, -1.0))]))
	run.behaviours.behaviour_started.connect(func(npc_id: String, action_id: String, _info: Dictionary) -> void:
		if action_id == NpcBehaviours.ACTION_REST:
			var needs: NpcNeeds = run.npcs().get_npc(npc_id).component(NpcNeeds.COMPONENT_ID) as NpcNeeds
			(napped.get_or_add(npc_id, []) as Array).append([run.tick, needs.value(NpcNeedKind.FATIGUE)]))
	run.run_ticks(RUN_HOURS * TICKS_PER_HOUR)
	var ids: PackedStringArray = run.npcs().npc_ids()
	assert_eq(ids.size(), 5, "the five dev NPCs")
	# [bedtime counted from midnight of day 1, hour it went to bed]
	var nights: Array[Array] = []
	for npc_id: String in ids:
		var definition: NpcDefinition = run.npcs().definition_of(npc_id)
		var bedtime: float = definition.bedtime_hour if definition.bedtime_hour >= 12.0 else definition.bedtime_hour + 24.0
		var went_to_bed: PackedInt32Array = []
		for line: String in run.events:
			var parts: PackedStringArray = line.split(" ")
			if parts[1] == "started" and parts[2] == npc_id and parts[3] == NpcBehaviours.ACTION_SLEEP and parts[0].to_int() >= NOON_TICK:
				went_to_bed.append(parts[0].to_int())
		var ended: Array = []
		for entry: Array in slept.get(npc_id, []):
			if int(entry[0]) >= NOON_TICK:
				ended.append(entry)
		print("[npc sleep] %s %s: bedtime %.2f, went to bed at %s, the night sleep ended at %s; naps began at %s" % [
			npc_id, definition.definition_id, definition.bedtime_hour,
			str(Array(went_to_bed).map(func(tick: int) -> String: return "%.2f h" % (float(tick) / TICKS_PER_HOUR))),
			str(ended.map(func(entry: Array) -> String: return "%.2f h (fatigue %.3f)" % [float(entry[0]) / TICKS_PER_HOUR, float(entry[1])])),
			str((napped.get(npc_id, []) as Array).map(func(entry: Array) -> String: return "%.2f h (fatigue %.1f)" % [float(entry[0]) / TICKS_PER_HOUR, float(entry[1])]))])
		assert_true(went_to_bed.size() >= 1, "%s goes to bed in the evening" % definition.definition_id)
		if went_to_bed.is_empty():
			continue
		var first_hour: float = float(went_to_bed[0]) / TICKS_PER_HOUR
		assert_true(first_hour >= bedtime - 0.001, "%s goes to bed at %.2f, not before its bedtime %.2f" % [definition.definition_id, first_hour, bedtime])
		assert_true(first_hour < bedtime + LATEST_HOURS_AFTER_BEDTIME, "%s goes to bed at %.2f, soon after its bedtime %.2f" % [definition.definition_id, first_hour, bedtime])
		nights.append([bedtime, first_hour])
		# It sleeps until its fatigue is 0, once.
		assert_eq(ended.size(), 1, "%s: one night sleep that ended by itself" % definition.definition_id)
		if ended.size() == 1:
			assert_eq(float(ended[0][1]), 0.0, "%s slept until its fatigue was 0" % definition.definition_id)
			assert_true(went_to_bed[went_to_bed.size() - 1] < int(ended[0][0]), "%s does not go to bed again in the same night" % definition.definition_id)
		assert_true((run.labels[npc_id] as Dictionary).has("sleep"), "other players saw %s sleep" % definition.definition_id)
		# A nap begins only at high fatigue.
		for entry: Array in napped.get(npc_id, []):
			assert_true(float(entry[1]) >= nap_threshold - 0.01, "%s began a nap at fatigue %.2f" % [definition.definition_id, float(entry[1])])
	# The morning types are in bed before the evening types.
	nights.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for index: int in range(1, nights.size()):
		assert_true(float(nights[index - 1][1]) < float(nights[index][1]), "bedtime %.2f is in bed (%.2f) before bedtime %.2f (%.2f)" % [float(nights[index - 1][0]), float(nights[index - 1][1]), float(nights[index][0]), float(nights[index][1])])
	assert_eq(run.longest_failure_streak() < 5, true, "nobody is stuck: %s" % str(run.failure_counts()))
	run.finish()
