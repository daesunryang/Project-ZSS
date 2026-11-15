extends TestCase
## P2-0: WorldClock and BucketScheduler.


func test_clock_scales_and_pauses_when_empty() -> void:
	var clock: WorldClock = WorldClock.new(60.0, true)
	assert_eq(clock.step(1.0, false), 0.0, "paused without players")
	assert_true(clock.is_paused(false))
	assert_eq(clock.step(0.5, true), 30.0)
	assert_eq(clock.world_time_sec, 30.0)
	assert_eq(clock.action_time_sec, 0.5, "action time is not scaled")
	assert_eq(clock.step(-1.0, true), 0.0, "negative delta ignored")
	assert_eq(clock.step(NAN, true), 0.0, "NaN delta ignored")
	var always_on: WorldClock = WorldClock.new(1.0, false)
	assert_eq(always_on.step(2.0, false), 2.0, "pause_when_empty=false keeps running")


func test_clock_restore_validation() -> void:
	var clock: WorldClock = WorldClock.new()
	assert_eq(clock.restore(123.5), OK)
	assert_eq(clock.world_time_sec, 123.5)
	assert_eq(clock.restore(-1.0), ERR_INVALID_PARAMETER)
	assert_eq(clock.restore(INF), ERR_INVALID_PARAMETER)
	assert_eq(clock.world_time_sec, 123.5)


func test_clock_settings_defaults() -> void:
	var settings: WorldClockSettings = WorldClockSettings.load_or_default()
	assert_eq(settings.validate().size(), 0)
	var clock: WorldClock = settings.create_clock()
	assert_eq(clock.time_scale, settings.time_scale)
	assert_eq(clock.pause_when_empty, settings.pause_when_empty)


func test_scheduler_runs_each_id_once_per_period() -> void:
	var scheduler: BucketScheduler = BucketScheduler.new(1.0, 4)
	for index: int in range(10):
		scheduler.add("z%d" % index)
	var seen: Dictionary[String, int] = {}
	var max_per_tick: int = 0
	for tick: int in range(60):  # 60 ticks of 1/60 s = exactly one period
		var due: PackedStringArray = scheduler.advance(1.0 / 60.0)
		max_per_tick = maxi(max_per_tick, due.size())
		for id: String in due:
			seen[id] = seen.get(id, 0) + 1
	assert_eq(seen.size(), 10, "every id ran")
	for id: String in seen:
		assert_eq(seen[id], 1, "ran exactly once: " + id)
	assert_true(max_per_tick <= 3, "work is spread over ticks (max %d per tick)" % max_per_tick)


func test_scheduler_is_deterministic_and_handles_removal() -> void:
	var a: BucketScheduler = BucketScheduler.new(0.5, 2)
	var b: BucketScheduler = BucketScheduler.new(0.5, 2)
	for id: String in ["x", "y", "z"]:
		a.add(id)
		b.add(id)
	assert_eq(a.bucket_of("z"), 0, "round-robin assignment")
	assert_eq(a.advance(0.25), b.advance(0.25))
	a.remove("y")
	assert_false(a.has("y"))
	assert_eq(a.advance(0.25), PackedStringArray(), "bucket of removed id is empty")
	assert_eq(a.add("x"), a.bucket_of("x"), "re-adding is a no-op")
	assert_eq(a.size(), 2)


func test_scheduler_never_repeats_ids_in_one_call() -> void:
	var scheduler: BucketScheduler = BucketScheduler.new(1.0, 4)
	scheduler.add("a")
	scheduler.add("b")
	var due: PackedStringArray = scheduler.advance(100.0)
	assert_eq(due.size(), 2, "huge delta processes at most one period")
	assert_eq(scheduler.advance(0.0), PackedStringArray())
