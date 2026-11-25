extends TestCase
## P4-3: the NPC scheduler (docs/09 §17.3). WHEN an NPC thinks: once per
## period of its tier whatever the tick length, never more decisions in a
## tick than the cap, interrupts and timed interrupts that do not wait for
## the period (one decision per NPC and tick), the near / far tier from the
## distance to the nearest player, nothing for NPCs whose cell is not
## simulated or while the world is paused, and the same decisions whether a
## run goes on or is saved, restarted and restored in between (docs/13
## §16.3 D11). WHAT an NPC decides is P4-4: the decider here only writes
## down that it was asked. Server rules only, no nodes; ticks are stepped by
## hand, nothing depends on real time.

const WORLD: String = "npc_scheduler_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
const NURSE: String = "t43_nurse"
const PERIOD: String = NpcDecider.REASON_PERIOD
## 10 m cells; the player's cell and one ring around it are simulated, two
## rings are in memory.
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
## 20 m beside SPAWN: in memory but not simulated while the player is there.
const LOADED_NOT_ACTIVE: Vector3 = Vector3(25.5, 0.0, 5.5)
const FAR_AWAY: Vector3 = Vector3(45.5, 0.0, 45.5)
const NEAR_PERIOD: float = 1.0
const FAR_PERIOD: float = 4.0
const NEAR_RADIUS: float = 6.0
const NEAR_MARGIN: float = 1.0


## Writes down every decision it is asked for: "<tick> <npc> <reasons>".
class Recorder:
	extends NpcDecider
	var log: PackedStringArray = []
	var tick: int = 0
	## reason -> reason: seeing the first, the NPC asks for the second.
	var echo: Dictionary[String, String] = {}
	## True: it writes nothing down (the measurement: the scheduler alone).
	var silent: bool = false
	var _scheduler: WeakRef = null

	func on_attached(scheduler: NpcScheduler) -> void:
		_scheduler = weakref(scheduler)

	func scheduler() -> NpcScheduler:
		return _scheduler.get_ref() as NpcScheduler if _scheduler != null else null

	func decide(_world: ServerWorld, _npcs: NpcService, npc: NpcState, reasons: PackedStringArray, from: NpcScheduler) -> void:
		if silent:
			return
		log.append("%d %s %s" % [tick, npc.npc_id, ",".join(reasons)])
		for reason: String in reasons:
			if echo.has(reason):
				from.request_interrupt(npc.npc_id, echo[reason])

	## Ticks in which `npc_id` decided.
	func ticks_of(npc_id: String) -> PackedInt32Array:
		var ticks: PackedInt32Array = []
		for line: String in log:
			if line.get_slice(" ", 1) == npc_id:
				ticks.append(line.get_slice(" ", 0).to_int())
		return ticks

	## The lines of one tick, without the tick: "<npc> <reasons>".
	func at(wanted_tick: int) -> PackedStringArray:
		var lines: PackedStringArray = []
		for line: String in log:
			if line.get_slice(" ", 0).to_int() == wanted_tick:
				lines.append(line.substr(line.find(" ") + 1))
		return lines

	## Most decisions in one tick.
	func peak() -> int:
		var counts: Dictionary[int, int] = {}
		var most: int = 0
		for line: String in log:
			var line_tick: int = line.get_slice(" ", 0).to_int()
			counts[line_tick] = int(counts.get(line_tick, 0)) + 1
			most = maxi(most, counts[line_tick])
		return most


var _cell_settings: WorldCellSettings = null
var _schedule: NpcScheduleSettings = null
var _recorder: Recorder = null


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
	_schedule.decision_near_period_sec = NEAR_PERIOD
	_schedule.decision_far_period_sec = FAR_PERIOD
	_schedule.decision_bucket_count = 5
	_schedule.max_decisions_per_tick = 2
	_schedule.near_radius_m = NEAR_RADIUS
	_schedule.near_exit_margin_m = NEAR_MARGIN
	_schedule.tier_period_sec = 0.5
	_recorder = Recorder.new()


func after_each() -> void:
	GameLogger.set_capture(false)
	_recorder = null


# ------------------------------------------------------------ helpers

func _config(recorder: Recorder) -> CompositionConfig:
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
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = _cell_settings
	config.npc = NpcSettings.new()
	config.npc_definitions = NpcCatalog.new()
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = NURSE
	definition.display_name = "간호사"
	config.npc_definitions.add(definition)
	config.npc_schedule = _schedule
	config.npc_decider = recorder
	return config


func _world(recorder: Recorder = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config(recorder if recorder != null else _recorder))
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	return world


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


## Steps the world; the recorder's tick is the number of the step.
func _run(world: ServerWorld, ticks: int, delta: float = TICK, recorder: Recorder = null) -> void:
	var counted: Recorder = recorder if recorder != null else _recorder
	for index: int in range(ticks):
		counted.tick += 1
		world.step_systems(delta)


func _spawn(world: ServerWorld, position: Vector3) -> String:
	var spawned: ActionResult = _npcs(world).spawn_npc(world, NURSE, position)
	if not spawned.ok:
		fail("test setup: npc refused: " + spawned.reason)
		return ""
	return str(spawned.event.get(NpcService.KEY_NPC_ID, ""))


## A world with a player at SPAWN and NPCs at `positions`.
func _start(positions: Array[Vector3], recorder: Recorder = null) -> Dictionary:
	var world: ServerWorld = _world(recorder)
	var alice: PlayerState = world.join("alice")
	world.step_systems(TICK)
	var ids: PackedStringArray = []
	for position: Vector3 in positions:
		ids.append(_spawn(world, position))
	return {"world": world, "alice": alice, "ids": ids, "scheduler": (recorder if recorder != null else _recorder).scheduler()}


## Positions within the near radius of SPAWN.
func _near_spots(count: int) -> Array[Vector3]:
	var spots: Array[Vector3] = []
	for index: int in range(count):
		spots.append(SPAWN + Vector3(0.5 + 0.5 * float(index), 0.0, 0.5))
	return spots


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


func _schedule_document(world: ServerWorld, npc_id: String) -> Dictionary:
	return ((_npcs(world).npc_document(npc_id)[NpcState.KEY_COMPONENTS] as Dictionary).get(NpcScheduleComponent.COMPONENT_ID, {}) as Dictionary)


func _stage_document(world: ServerWorld) -> Dictionary:
	var npc_part: Dictionary = (world.to_documents()["world_state"]["systems"] as Dictionary).get(NpcService.SYSTEM_ID, {})
	return (npc_part.get(NpcService.KEY_STAGES, {}) as Dictionary).get(NpcScheduler.STAGE_ID, {})


## Steps until `npc_id` has no periodic decision for the next `quiet_sec`.
func _until_quiet(world: ServerWorld, scheduler: NpcScheduler, npc_id: String, quiet_sec: float) -> void:
	for guard: int in range(1000):
		if scheduler.next_decision_in_sec(npc_id) > quiet_sec:
			return
		_run(world, 1)
	fail("test setup: %s never became quiet" % npc_id)


# ------------------------------------------------------------ data

func test_the_shipped_settings_are_the_planned_budget_and_bad_settings_are_refused() -> void:
	var shipped: NpcScheduleSettings = NpcScheduleSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0)
	# docs/13 §16.4: near 2 s, far 10 s, 10 buckets, 2 decisions per tick,
	# near = nearest player within 30 m.
	assert_eq(shipped.decision_near_period_sec, 2.0)
	assert_eq(shipped.decision_far_period_sec, 10.0)
	assert_eq(shipped.decision_bucket_count, 10)
	assert_eq(shipped.max_decisions_per_tick, 2)
	assert_eq(shipped.near_radius_m, 30.0)
	assert_eq(NpcScheduleSettings.new().validate().size(), 0, "the code defaults are valid too")
	for change: Array in [
		["decision_near_period_sec", 0.0],
		["decision_far_period_sec", NAN],
		["decision_far_period_sec", 1.0],
		["decision_bucket_count", 0],
		["max_decisions_per_tick", 0],
		["near_radius_m", -1.0],
		["near_exit_margin_m", INF],
		["tier_period_sec", 0.0],
		["tier_period_sec", 0.000001],
	]:
		var settings: NpcScheduleSettings = NpcScheduleSettings.new()
		settings.set(str(change[0]), change[1])
		assert_true(settings.validate().size() > 0, "%s = %s must be refused" % [str(change[0]), str(change[1])])
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate(), PackedStringArray())
	assert_eq(config.npc_schedule, shipped, "the composition uses the shipped settings")
	assert_null(config.npc_decider, "and decides nothing before P4-4")
	config.npc_schedule = NpcScheduleSettings.new()
	config.npc_schedule.max_decisions_per_tick = 0
	assert_true(config.validate().size() > 0, "the composition checks the schedule settings")


func test_the_default_composition_schedules_every_npc_and_decides_nothing() -> void:
	# No decider (the default before P4-4): the turns still come.
	var config: CompositionConfig = _config(_recorder)
	config.npc_decider = null
	# P4-5b: and no behaviour layer, so the composition's own decider has no
	# executor and decides nothing.
	config.npc_behaviour = null
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	world.join("alice")
	world.step_systems(TICK)
	var npc_id: String = _spawn(world, SPAWN + Vector3(1.0, 0.0, 0.0))
	var npc: NpcState = _npcs(world).get_npc(npc_id)
	assert_not_null(npc.component(NpcScheduleComponent.COMPONENT_ID), "every NPC has the schedule component")
	var before: Dictionary = _npcs(world).npc_document(npc_id)
	for tick: int in range(roundi(3.0 / TICK)):
		world.step_systems(TICK)
	var after: Dictionary = _npcs(world).npc_document(npc_id)
	assert_eq(after[NpcState.KEY_POSITION], before[NpcState.KEY_POSITION], "an NPC without decisions stands still")
	assert_eq(after[NpcState.KEY_RNG_STATE], before[NpcState.KEY_RNG_STATE], "the scheduler uses no random numbers")
	var schedule: NpcScheduleComponent = npc.component(NpcScheduleComponent.COMPONENT_ID) as NpcScheduleComponent
	assert_true(schedule.is_scheduled())
	assert_true(schedule.next_decision_at_usec > NpcScheduleSettings.to_usec(2.5), "its turns came and went: the next one is ahead")


# ------------------------------------------------------------ periods

func test_every_npc_decides_once_per_period_whatever_the_tick_length() -> void:
	var counts_by_delta: Array[Dictionary] = []
	for delta: float in [1.0 / 60.0, TICK, 0.1]:
		var recorder: Recorder = Recorder.new()
		var started: Dictionary = _start(_near_spots(5), recorder)
		var world: ServerWorld = started["world"]
		var scheduler: NpcScheduler = started["scheduler"]
		var ids: PackedStringArray = started["ids"]
		var buckets: Dictionary[int, bool] = {}
		for npc_id: String in ids:
			buckets[scheduler.bucket_of(npc_id)] = true
		assert_eq(buckets.size(), 5, "five NPCs made one after the other are in five buckets")
		_run(world, roundi(9.5 / delta), delta, recorder)
		var counts: Dictionary = {}
		for npc_id: String in ids:
			var ticks: PackedInt32Array = recorder.ticks_of(npc_id)
			counts[npc_id] = ticks.size()
			assert_true(ticks.size() == 9 or ticks.size() == 10, "9.5 s of a 1 s period: 9 or 10 turns, got %d (tick %f)" % [ticks.size(), delta])
			var turn_ticks: int = roundi(NEAR_PERIOD / delta)
			for index: int in range(1, ticks.size()):
				# 1/60 s ticks are 16667 µs on the schedule clock: a turn may
				# fall one tick early or late, never drift.
				assert_true(absi(ticks[index] - ticks[index - 1] - turn_ticks) <= 1, "turns are one period apart (tick %f)" % delta)
		assert_eq(recorder.peak(), 1, "the buckets spread the turns over the period (tick %f)" % delta)
		assert_eq(scheduler.total_decision_count, recorder.log.size())
		assert_eq(scheduler.total_interrupt_count, 0)
		for line: String in recorder.log:
			assert_eq(line.get_slice(" ", 2), PERIOD)
		counts_by_delta.append(counts)
	assert_eq(counts_by_delta[1], counts_by_delta[0], "60 Hz and 20 Hz ticks give every NPC the same number of turns")
	assert_eq(counts_by_delta[2], counts_by_delta[0], "10 Hz too")


func test_a_tick_runs_no_more_decisions_than_the_cap_and_nobody_is_skipped() -> void:
	# One bucket: all five turns come in the same tick.
	_schedule.decision_bucket_count = 1
	var started: Dictionary = _start(_near_spots(5))
	var world: ServerWorld = started["world"]
	var scheduler: NpcScheduler = started["scheduler"]
	var ids: PackedStringArray = started["ids"]
	_run(world, roundi(5.5 / TICK))
	assert_eq(_recorder.peak(), 2)
	assert_eq(scheduler.peak_decisions_per_tick, 2)
	for npc_id: String in ids:
		assert_eq(_recorder.ticks_of(npc_id).size(), 5, "5.5 s of a 1 s period: five turns each")
	# The first round: the lowest ids first, the rest in the next ticks.
	var first_tick: int = _recorder.log[0].get_slice(" ", 0).to_int()
	assert_eq(_recorder.at(first_tick), PackedStringArray([ids[0] + " " + PERIOD, ids[1] + " " + PERIOD]))
	assert_eq(_recorder.at(first_tick + 1), PackedStringArray([ids[2] + " " + PERIOD, ids[3] + " " + PERIOD]))
	assert_eq(_recorder.at(first_tick + 2), PackedStringArray([ids[4] + " " + PERIOD]))
	assert_eq(_recorder.at(first_tick + 3).size(), 0)
	# A tick longer than several periods: one turn each, not one per period
	# that went by.
	_recorder.log.clear()
	_run(world, 1, 2.7)
	assert_eq(_recorder.log.size(), 2)
	assert_eq(scheduler.last_decision_count, 2)
	assert_eq(scheduler.last_deferred_count, 3, "three are due and wait")
	_run(world, 1)
	assert_eq(scheduler.last_deferred_count, 1)
	_run(world, 3)
	assert_eq(_recorder.log.size(), 5, "everybody had exactly one turn")
	assert_eq(scheduler.last_deferred_count, 0)
	assert_eq(scheduler.last_decision_count, 0)


# ------------------------------------------------------------ interrupts

func test_an_interrupt_does_not_wait_for_the_period_and_runs_once_per_npc_and_tick() -> void:
	var started: Dictionary = _start(_near_spots(2))
	var world: ServerWorld = started["world"]
	var scheduler: NpcScheduler = started["scheduler"]
	var first: String = started["ids"][0]
	var second: String = started["ids"][1]
	_until_quiet(world, scheduler, first, 0.4)
	var ahead: float = scheduler.next_decision_in_sec(first)
	_recorder.log.clear()
	assert_true(scheduler.request_interrupt(first, "saw_zombie"))
	_run(world, 1)
	assert_true(_recorder.at(_recorder.tick).has(first + " saw_zombie"), "decided in the very next tick: " + str(_recorder.log))
	assert_eq(scheduler.last_interrupt_count, 1)
	assert_eq(scheduler.total_interrupt_count, 1)
	assert_true(absf(scheduler.next_decision_in_sec(first) - (ahead - TICK)) < 0.000001, "the periodic turn stays where it was")
	# Two reasons before the same tick are one decision.
	assert_true(scheduler.request_interrupt(first, "noise"))
	assert_true(scheduler.request_interrupt(first, "saw_zombie"))
	assert_true(scheduler.request_interrupt(first, "noise"), "asking twice is asking once")
	_run(world, 1)
	assert_eq(_recorder.ticks_of(first).size(), 2)
	assert_true(_recorder.at(_recorder.tick).has(first + " noise,saw_zombie"), str(_recorder.log))
	# An interrupt asked for while deciding is the next tick's.
	_recorder.echo["first_thing"] = "second_thing"
	assert_true(scheduler.request_interrupt(first, "first_thing"))
	_run(world, 1)
	assert_true(_recorder.at(_recorder.tick).has(first + " first_thing"))
	assert_false(_recorder.at(_recorder.tick).has(first + " second_thing"), "one decision per NPC and tick")
	_run(world, 1)
	assert_true(_recorder.at(_recorder.tick).has(first + " second_thing"))
	assert_eq(_recorder.ticks_of(first).size(), 4)
	# Refused: nobody, a name that is not snake_case, the periodic reason,
	# and an NPC that is not simulated.
	assert_false(scheduler.request_interrupt("npc_999999", "noise"))
	assert_false(scheduler.request_interrupt(first, "Bad Reason"))
	assert_false(scheduler.request_interrupt(first, PERIOD))
	var frozen: String = _spawn(world, LOADED_NOT_ACTIVE)
	assert_false(_npcs(world).is_awake(frozen))
	assert_false(scheduler.request_interrupt(frozen, "noise"), "a frozen NPC hears nothing")
	assert_false(scheduler.schedule_interrupt(frozen, "noise", 1.0))
	assert_eq(_schedule_document(world, frozen)[NpcScheduleComponent.KEY_INTERRUPTS], {})
	# A periodic turn and an interrupt in the same tick are one decision.
	_until_quiet(world, scheduler, second, 0.4)
	_run(world, roundi(scheduler.next_decision_in_sec(second) / TICK) - 1)
	assert_true(scheduler.next_decision_in_sec(second) <= TICK + 0.000001)
	assert_true(scheduler.request_interrupt(second, "noise"))
	var turns: int = _recorder.ticks_of(second).size()
	_run(world, 1)
	assert_true(_recorder.at(_recorder.tick).has(second + " period,noise"), str(_recorder.at(_recorder.tick)))
	assert_eq(_recorder.ticks_of(second).size(), turns + 1)


func test_interrupts_go_first_when_the_cap_is_full() -> void:
	_schedule.max_decisions_per_tick = 1
	_schedule.decision_bucket_count = 1
	var started: Dictionary = _start(_near_spots(3))
	var world: ServerWorld = started["world"]
	var scheduler: NpcScheduler = started["scheduler"]
	var ids: PackedStringArray = started["ids"]
	# All three periodic turns come in the next tick; the last NPC is
	# interrupted as well.
	_run(world, roundi(scheduler.next_decision_in_sec(ids[0]) / TICK) - 1)
	assert_true(scheduler.request_interrupt(ids[2], "saw_zombie"))
	_run(world, 1)
	assert_eq(_recorder.log, PackedStringArray(["%d %s period,saw_zombie" % [_recorder.tick, ids[2]]]))
	assert_eq(scheduler.last_deferred_count, 2)
	_run(world, 2)
	assert_eq(_recorder.at(_recorder.tick - 1), PackedStringArray([ids[0] + " " + PERIOD]))
	assert_eq(_recorder.at(_recorder.tick), PackedStringArray([ids[1] + " " + PERIOD]))
	# Interrupts among themselves: who asked first.
	_until_quiet(world, scheduler, ids[0], 0.5)
	_recorder.log.clear()
	assert_true(scheduler.request_interrupt(ids[1], "noise"))
	assert_true(scheduler.request_interrupt(ids[0], "noise"))
	_run(world, 1)
	# Both asked before the same tick: the same moment, so the lower id.
	assert_eq(_recorder.at(_recorder.tick), PackedStringArray([ids[0] + " noise"]))
	assert_true(scheduler.request_interrupt(ids[2], "noise"))
	_run(world, 1)
	assert_eq(_recorder.at(_recorder.tick), PackedStringArray([ids[1] + " noise"]), "the one that waits longer goes before the one that just asked")
	_run(world, 1)
	assert_eq(_recorder.at(_recorder.tick), PackedStringArray([ids[2] + " noise"]))


func test_timed_interrupts_come_when_their_time_is_up() -> void:
	# A long period: the periodic turns stay out of the way.
	_schedule.decision_near_period_sec = 30.0
	_schedule.decision_far_period_sec = 30.0
	var started: Dictionary = _start(_near_spots(1))
	var world: ServerWorld = started["world"]
	var scheduler: NpcScheduler = started["scheduler"]
	var npc_id: String = started["ids"][0]
	_recorder.log.clear()
	assert_true(scheduler.schedule_interrupt(npc_id, "hungry", 0.5))
	var start_tick: int = _recorder.tick
	_run(world, 9)
	assert_eq(_recorder.log.size(), 0, "0.45 s: not yet")
	_run(world, 1)
	assert_eq(_recorder.log, PackedStringArray(["%d %s hungry" % [start_tick + 10, npc_id]]))
	assert_eq(_schedule_document(world, npc_id)[NpcScheduleComponent.KEY_INTERRUPTS], {}, "a timer that came is gone")
	# Asking again for the same reason moves the timer.
	_recorder.log.clear()
	start_tick = _recorder.tick
	assert_true(scheduler.schedule_interrupt(npc_id, "hungry", 0.2))
	assert_true(scheduler.schedule_interrupt(npc_id, "hungry", 0.5))
	assert_true(scheduler.schedule_interrupt(npc_id, "thirsty", 0.3))
	_run(world, 20)
	assert_eq(_recorder.log, PackedStringArray(["%d %s thirsty" % [start_tick + 6, npc_id], "%d %s hungry" % [start_tick + 10, npc_id]]))
	# Cancelled timers never come.
	_recorder.log.clear()
	assert_true(scheduler.schedule_interrupt(npc_id, "hungry", 0.2))
	assert_true(scheduler.cancel_interrupt(npc_id, "hungry"))
	assert_false(scheduler.cancel_interrupt(npc_id, "hungry"), "nothing left to cancel")
	_run(world, 20)
	assert_eq(_recorder.log.size(), 0)
	# Calendar time: the world clock's scale turns it into action time.
	start_tick = _recorder.tick
	assert_true(scheduler.schedule_interrupt_world(world, npc_id, "shift_starts", 0.5 * world.clock.time_scale))
	_run(world, 20)
	assert_eq(_recorder.log, PackedStringArray(["%d %s shift_starts" % [start_tick + 10, npc_id]]))
	# Refused: a time that is not a time, a bad name, too many at once.
	assert_false(scheduler.schedule_interrupt(npc_id, "hungry", -1.0))
	assert_false(scheduler.schedule_interrupt(npc_id, "hungry", NAN))
	assert_false(scheduler.schedule_interrupt(npc_id, "hungry", 1.0e30))
	assert_false(scheduler.schedule_interrupt(npc_id, "Bad Reason", 1.0))
	for index: int in range(NpcScheduleComponent.MAX_INTERRUPTS):
		assert_true(scheduler.schedule_interrupt(npc_id, "reason_%d" % index, 100.0))
	var refused: int = scheduler.refused_request_count
	assert_false(scheduler.schedule_interrupt(npc_id, "one_too_many", 100.0))
	assert_false(scheduler.request_interrupt(npc_id, "one_too_many"))
	assert_eq(scheduler.refused_request_count, refused + 2)
	assert_true(scheduler.schedule_interrupt(npc_id, "reason_0", 50.0), "a reason that waits already can still be moved")


# ------------------------------------------------------------ tiers

func test_the_tier_follows_the_distance_to_the_nearest_player() -> void:
	var started: Dictionary = _start([SPAWN + Vector3(3.0, 0.0, 0.0), SPAWN + Vector3(10.0, 0.0, 0.0)])
	var world: ServerWorld = started["world"]
	var scheduler: NpcScheduler = started["scheduler"]
	var alice: PlayerState = started["alice"]
	var close: String = started["ids"][0]
	var distant: String = started["ids"][1]
	var service: NpcService = _npcs(world)
	# Decided when they woke: 3 m is near, 10 m is far.
	assert_eq(service.get_npc(close).simulation_tier, NpcState.TIER_NEAR)
	assert_eq(service.get_npc(distant).simulation_tier, NpcState.TIER_FAR)
	assert_eq(scheduler.tier_of(distant), NpcState.TIER_FAR)
	assert_eq([scheduler.near_count, scheduler.far_count], [1, 1])
	_run(world, roundi(8.5 / TICK))
	assert_true(_recorder.ticks_of(close).size() >= 8, "a near NPC thinks every second")
	assert_eq(_recorder.ticks_of(distant).size(), 2, "a far one every four")
	# The player walks over to the far one.
	alice.position = SPAWN + Vector3(9.0, 0.0, 0.0)
	_run(world, roundi(0.5 / TICK))
	assert_eq(service.get_npc(distant).simulation_tier, NpcState.TIER_NEAR, "looked at again within the tier period")
	assert_eq(service.get_npc(close).simulation_tier, NpcState.TIER_NEAR, "6 m: at the edge it stays what it was")
	assert_true(scheduler.next_decision_in_sec(distant) <= NEAR_PERIOD + 0.000001, "a NPC that became near does not sit out its far period")
	alice.position = SPAWN + Vector3(10.5, 0.0, 0.0)
	_run(world, roundi(0.5 / TICK))
	assert_eq(service.get_npc(close).simulation_tier, NpcState.TIER_FAR, "7.5 m: beyond the margin")
	assert_eq([scheduler.near_count, scheduler.far_count], [1, 1])
	var turns: int = _recorder.ticks_of(distant).size()
	var far_turns: int = _recorder.ticks_of(close).size()
	_run(world, roundi(8.0 / TICK))
	assert_true(_recorder.ticks_of(distant).size() - turns >= 7)
	assert_true(_recorder.ticks_of(close).size() - far_turns <= 3, "the one left behind slowed down")
	# Back inside the margin but not inside the radius: far stays far.
	alice.position = SPAWN + Vector3(9.5, 0.0, 0.0)
	_run(world, roundi(0.5 / TICK))
	assert_eq(service.get_npc(close).simulation_tier, NpcState.TIER_FAR, "6.5 m: within the margin it stays what it was")
	var report: Dictionary = scheduler.diagnostics()
	assert_eq(int(report[NpcScheduler.DIAG_NEAR]), 1)
	assert_eq(int(report[NpcScheduler.DIAG_FAR]), 1)
	assert_true(report.has(NpcScheduler.DIAG_DECISIONS) and report.has(NpcScheduler.DIAG_INTERRUPTS) and report.has(NpcScheduler.DIAG_DEFERRED) and report.has(NpcScheduler.DIAG_STEP_USEC))


# ------------------------------------------------------------ sleeping, pausing

func test_npcs_of_cells_that_are_not_simulated_and_of_a_paused_world_do_not_think() -> void:
	var started: Dictionary = _start(_near_spots(2))
	var world: ServerWorld = started["world"]
	var scheduler: NpcScheduler = started["scheduler"]
	var alice: PlayerState = started["alice"]
	var ids: PackedStringArray = started["ids"]
	var service: NpcService = _npcs(world)
	_run(world, roundi(2.5 / TICK))
	assert_true(_recorder.log.size() >= 4)
	# The player leaves: the cell stops being simulated (and later leaves
	# memory with its NPCs).
	alice.position = FAR_AWAY
	_run(world, 1)
	assert_eq(service.awake_count(), 0)
	_recorder.log.clear()
	assert_false(scheduler.schedule_interrupt(ids[0], "hungry", 0.2), "a sleeping NPC takes no timers")
	_run(world, roundi(5.0 / TICK))
	assert_eq(_recorder.log.size(), 0, "nobody thinks in a cell that is not simulated")
	assert_eq([scheduler.near_count, scheduler.far_count], [0, 0])
	assert_false(service.has_npc(ids[0]), "the cell left memory")
	var scans: int = scheduler.scan_count
	_run(world, roundi(2.0 / TICK))
	assert_eq(scheduler.scan_count, scans, "and nothing is looked at")
	# Back: both turns are long overdue and come at once, then every second.
	alice.position = SPAWN
	_run(world, 1)
	assert_eq(service.awake_count(), 2)
	var woke: PackedStringArray = _recorder.at(_recorder.tick)
	woke.sort()
	assert_eq(woke, PackedStringArray([ids[0] + " " + PERIOD, ids[1] + " " + PERIOD]))
	_run(world, roundi(2.0 / TICK))
	assert_eq(_recorder.ticks_of(ids[0]).size(), 3)
	# Nobody online: the clock stands still and so does the schedule.
	var clock: int = scheduler.clock_usec()
	assert_true(scheduler.request_interrupt(ids[0], "noise"))
	world.leave(alice.player_id)
	_recorder.log.clear()
	_run(world, roundi(3.0 / TICK))
	assert_eq(_recorder.log.size(), 0)
	assert_eq(scheduler.clock_usec(), clock)


func test_ticks_without_a_turn_look_at_nobody() -> void:
	_schedule.decision_near_period_sec = 2.0
	_schedule.decision_far_period_sec = 2.0
	var started: Dictionary = _start(_near_spots(5))
	var world: ServerWorld = started["world"]
	var scheduler: NpcScheduler = started["scheduler"]
	var ticks: int = roundi(10.0 / TICK)
	_run(world, ticks)
	assert_eq(scheduler.total_decision_count, 25, "five NPCs, five turns each")
	assert_eq(scheduler.scan_count, 25, "only the ticks that have a turn look at the NPCs, the other %d do not" % (ticks - 25))


# ------------------------------------------------------------ save and restore

## One tick of a fixed script: the player walks away from the NPCs and back
## (they go far, fall asleep, leave memory, come back), and interrupts and
## timers are asked for before and after the step.
func _scripted_tick(world: ServerWorld, recorder: Recorder, alice: PlayerState, ids: PackedStringArray, tick: int, seen: Dictionary = {}) -> void:
	var scheduler: NpcScheduler = recorder.scheduler()
	seen["far"] = bool(seen.get("far", false)) or scheduler.far_count > 0
	seen["near"] = bool(seen.get("near", false)) or scheduler.near_count > 0
	seen["asleep"] = bool(seen.get("asleep", false)) or (_npcs(world).npc_count() > _npcs(world).awake_count() and tick > 0)
	seen["out_of_memory"] = bool(seen.get("out_of_memory", false)) or _npcs(world).npc_count() < ids.size()
	seen["deferred"] = bool(seen.get("deferred", false)) or scheduler.last_deferred_count > 0
	var phase: int = tick % 200
	alice.position = Vector3(5.5 + 0.35 * float(mini(phase, 200 - phase)), 0.0, 5.5)
	if tick % 37 == 5:
		scheduler.request_interrupt(ids[tick % ids.size()], "poke")
	if tick % 53 == 11:
		scheduler.schedule_interrupt(ids[(tick / 53) % ids.size()], "timer", 0.73)
	if tick % 29 == 3:
		scheduler.schedule_interrupt_world(world, ids[(tick / 29) % ids.size()], "calendar", 31.0)
	recorder.tick = tick
	world.step_systems(TICK)
	if tick % 41 == 7:
		scheduler.request_interrupt(ids[(tick / 41) % ids.size()], "late")


const SCRIPT_SPOTS: Array[Vector3] = [
	Vector3(6.5, 0.0, 5.5), Vector3(8.5, 0.0, 5.5), Vector3(3.5, 0.0, 5.5),
	Vector3(12.5, 0.0, 5.5), Vector3(17.5, 0.0, 5.5), Vector3(24.5, 0.0, 5.5),
]
const SCRIPT_TICKS: int = 600


func _schedules(world: ServerWorld) -> Dictionary:
	var result: Dictionary = {}
	for npc_id: String in _npcs(world).npc_ids():
		result[npc_id] = _schedule_document(world, npc_id)
	return result


func test_a_run_that_is_saved_restarted_and_restored_decides_like_one_that_goes_on() -> void:
	# The run that goes on.
	var recorder: Recorder = Recorder.new()
	var started: Dictionary = _start(SCRIPT_SPOTS, recorder)
	var world: ServerWorld = started["world"]
	var ids: PackedStringArray = started["ids"]
	var seen: Dictionary = {}
	for tick: int in range(SCRIPT_TICKS):
		_scripted_tick(world, recorder, started["alice"], ids, tick, seen)
	var expected: PackedStringArray = recorder.log
	for what: String in ["near", "far", "asleep", "out_of_memory", "deferred"]:
		assert_true(bool(seen.get(what, false)), "the script covers NPCs that are %s" % what)
	assert_true(expected.size() > 100, "the script makes the NPCs think: %d decisions" % expected.size())
	var reasons: String = " ".join(expected)
	for reason: String in [PERIOD, "poke", "timer", "calendar", "late"]:
		assert_contains(reasons, reason, "the script covers %s" % reason)
	var expected_schedules: Dictionary = _json(_schedules(world))
	var expected_stage: Dictionary = _json(_stage_document(world))
	assert_true(int(expected_stage.get(NpcScheduler.KEY_CLOCK, 0)) > 0, "the stage saves its clock")
	# The same run, saved after tick `save_at - 1` and restored into a new
	# world (a restart): 49, 131, 295 and 418 are right after a "late"
	# interrupt was asked for, with the player near, half way, far, and near.
	for save_at: int in [49, 131, 295, 418]:
		var before: Recorder = Recorder.new()
		var first: Dictionary = _start(SCRIPT_SPOTS, before)
		var first_world: ServerWorld = first["world"]
		assert_eq(first["ids"], ids, "the same NPCs")
		for tick: int in range(save_at):
			_scripted_tick(first_world, before, first["alice"], ids, tick)
		# A save is text: the documents go through JSON.
		var documents: Dictionary = _json(first_world.to_documents())
		var after: Recorder = Recorder.new()
		var second_world: ServerWorld = _world(after)
		assert_eq(second_world.restore_documents(documents["world_state"], documents["players"], documents["cells"]).size(), 0)
		var alice: PlayerState = second_world.join("alice")
		for tick: int in range(save_at, SCRIPT_TICKS):
			_scripted_tick(second_world, after, alice, ids, tick)
		var actual: PackedStringArray = before.log.duplicate()
		actual.append_array(after.log)
		assert_true(before.log.size() > 0 and after.log.size() > 0)
		assert_eq(actual.size(), expected.size(), "saved at %d: the same number of decisions" % save_at)
		for index: int in range(mini(actual.size(), expected.size())):
			if actual[index] != expected[index]:
				fail("saved at %d: decision %d is \"%s\", the run that went on has \"%s\"" % [save_at, index, actual[index], expected[index]])
				break
		assert_eq(_json(_schedules(second_world)), expected_schedules, "saved at %d: every NPC's schedule ends the same" % save_at)
		assert_eq(_json(_stage_document(second_world)), expected_stage, "saved at %d: the clock ends the same" % save_at)
		var total: int = before.scheduler().total_decision_count + after.scheduler().total_decision_count
		assert_eq(total, expected.size())


func test_what_is_saved_and_what_a_restore_refuses() -> void:
	# A world whose NPCs were never scheduled saves nothing of the stage.
	var empty: ServerWorld = _world()
	empty.join("alice")
	_run(empty, 20)
	assert_false((empty.to_documents()["world_state"]["systems"] as Dictionary).has(NpcService.SYSTEM_ID), "no NPC: the save looks as it did before NPCs")
	var started: Dictionary = _start(_near_spots(1))
	var world: ServerWorld = started["world"]
	var scheduler: NpcScheduler = started["scheduler"]
	var npc_id: String = started["ids"][0]
	_run(world, 30)
	assert_true(scheduler.schedule_interrupt(npc_id, "hungry", 5.0))
	assert_eq(scheduler.clock_usec(), 30 * 50000)
	assert_eq(_json(_stage_document(world)), {"schema_version": 1.0, NpcScheduler.KEY_CLOCK: 1500000.0})
	var schedule: Dictionary = _json(_schedule_document(world, npc_id))
	assert_eq(schedule[NpcScheduleComponent.KEY_TIER], NpcState.TIER_NEAR)
	assert_eq(schedule[NpcScheduleComponent.KEY_INTERRUPTS], {"hungry": 6500000.0})
	assert_true(float(schedule[NpcScheduleComponent.KEY_NEXT_DECISION]) > 1500000.0)
	assert_eq(int(schedule[NpcComponent.KEY_SCHEMA_VERSION]), 1)
	# Broken documents are refused whole.
	var documents: Dictionary = _json(world.to_documents())
	for broken: Array in [
		[NpcScheduleComponent.KEY_NEXT_DECISION, 1.5],
		[NpcScheduleComponent.KEY_NEXT_DECISION, -2],
		[NpcScheduleComponent.KEY_TIER, NpcState.TIER_FROZEN],
		[NpcScheduleComponent.KEY_INTERRUPTS, []],
		[NpcScheduleComponent.KEY_INTERRUPTS, {"Bad Reason": 1}],
		[NpcScheduleComponent.KEY_INTERRUPTS, {PERIOD: 1}],
		[NpcScheduleComponent.KEY_INTERRUPTS, {"hungry": -1}],
		[NpcScheduleComponent.KEY_INTERRUPTS, {"hungry": "soon"}],
	]:
		var copy: Dictionary = documents.duplicate(true)
		var npc_part: Dictionary = (copy["world_state"]["systems"] as Dictionary)[NpcService.SYSTEM_ID]
		(((npc_part[NpcService.KEY_NPCS] as Array)[0][NpcState.KEY_COMPONENTS] as Dictionary)[NpcScheduleComponent.COMPONENT_ID] as Dictionary)[broken[0]] = broken[1]
		var target: ServerWorld = _world(Recorder.new())
		assert_true(target.restore_documents(copy["world_state"], copy["players"], copy["cells"]).size() > 0, "%s = %s must be refused" % [str(broken[0]), str(broken[1])])
		assert_eq(_npcs(target).npc_count(), 0)
	for broken_stage: Dictionary in [{}, {"schema_version": 2, NpcScheduler.KEY_CLOCK: 5}, {"schema_version": 1}, {"schema_version": 1, NpcScheduler.KEY_CLOCK: -1}, {"schema_version": 1, NpcScheduler.KEY_CLOCK: 0.5}]:
		var copy: Dictionary = documents.duplicate(true)
		var npc_part: Dictionary = (copy["world_state"]["systems"] as Dictionary)[NpcService.SYSTEM_ID]
		(npc_part[NpcService.KEY_STAGES] as Dictionary)[NpcScheduler.STAGE_ID] = broken_stage
		var target: ServerWorld = _world(Recorder.new())
		assert_true(target.restore_documents(copy["world_state"], copy["players"], copy["cells"]).size() > 0, "stage document %s must be refused" % str(broken_stage))
	# An NPC saved before the scheduler existed starts a fresh schedule.
	var old: Dictionary = documents.duplicate(true)
	var old_part: Dictionary = (old["world_state"]["systems"] as Dictionary)[NpcService.SYSTEM_ID]
	((old_part[NpcService.KEY_NPCS] as Array)[0][NpcState.KEY_COMPONENTS] as Dictionary).erase(NpcScheduleComponent.COMPONENT_ID)
	old_part.erase(NpcService.KEY_STAGES)
	var later: Recorder = Recorder.new()
	var restored: ServerWorld = _world(later)
	assert_eq(restored.restore_documents(old["world_state"], old["players"], old["cells"]).size(), 0)
	restored.join("alice")
	_run(restored, roundi(1.5 / TICK), TICK, later)
	assert_true(later.ticks_of(npc_id).size() >= 1, "it gets its turns")
	# A save that lost the stage's clock but kept the NPC's schedule: the
	# NPC does not wait for a time the new clock reaches much later.
	_run(world, roundi(60.0 / TICK))
	var no_clock: Dictionary = _json(world.to_documents())
	((no_clock["world_state"]["systems"] as Dictionary)[NpcService.SYSTEM_ID] as Dictionary).erase(NpcService.KEY_STAGES)
	var lost: Recorder = Recorder.new()
	var lost_world: ServerWorld = _world(lost)
	assert_eq(lost_world.restore_documents(no_clock["world_state"], no_clock["players"], no_clock["cells"]).size(), 0)
	lost_world.join("alice")
	_run(lost_world, roundi(1.5 / TICK), TICK, lost)
	assert_true(lost.ticks_of(npc_id).size() >= 1, "its turns come again within a period")


# ------------------------------------------------------------ measurement

## docs/13 §16.4: the whole NPC stage of 25 NPCs is to stay within 1.0 ms
## per tick (median). With nobody deciding anything this is the scheduler
## alone. Real time is only reported (assert_time_bound).
func test_measure_the_scheduler_alone_with_25_npcs() -> void:
	_schedule = NpcScheduleSettings.load_or_default().duplicate() as NpcScheduleSettings
	_schedule.near_radius_m = NEAR_RADIUS
	_recorder.silent = true
	var spots: Array[Vector3] = []
	for index: int in range(25):
		spots.append(SPAWN + Vector3(float(index % 5) - 2.0, 0.0, float(index / 5) - 2.0))
	var started: Dictionary = _start(spots)
	var world: ServerWorld = started["world"]
	var scheduler: NpcScheduler = started["scheduler"]
	var samples: PackedInt32Array = []
	var idle: PackedInt32Array = []
	var busy: PackedInt32Array = []
	for tick: int in range(roundi(20.0 * 60.0)):
		world.step_systems(1.0 / 60.0)
		samples.append(scheduler.last_step_usec)
		if scheduler.last_decision_count == 0:
			idle.append(scheduler.last_step_usec)
		else:
			busy.append(scheduler.last_step_usec)
	assert_eq(scheduler.near_count + scheduler.far_count, 25)
	assert_eq(scheduler.total_decision_count, 25 * 10, "25 NPCs, 20 s of a 2 s period")
	assert_eq(scheduler.peak_decisions_per_tick, 2, "the cap")
	samples.sort()
	idle.sort()
	busy.sort()
	var median_ms: float = float(samples[samples.size() / 2]) / 1000.0
	var worst_ms: float = float(samples[samples.size() - 1]) / 1000.0
	print("[p4-3] scheduler alone, 25 NPCs, 1200 ticks: median %.4f ms, worst %.4f ms; %d ticks without a decision: median %.4f ms; %d ticks with decisions: median %.4f ms" % [median_ms, worst_ms, idle.size(), float(idle[idle.size() / 2]) / 1000.0, busy.size(), float(busy[busy.size() / 2]) / 1000.0])
	assert_time_bound(median_ms, 1.0, "scheduler step, median")
	assert_time_bound(worst_ms, 2.0, "scheduler step, worst")
