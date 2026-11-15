extends TestCase
## P2-A1: NoiseService — emit validation, distance/time attenuation, expiry
## on action time (real seconds; the clock here runs its calendar 24x faster
## to show that the scale does not matter, P2-T1), spatial grid query ==
## brute-force query, per-cell cache.

const WORLD: String = "noise_test_world"
const SOURCE: String = "player_000001"
const HALF_EXTENT: float = 250.0
const EPSILON: float = 0.0001
const CALENDAR_SCALE: float = 24.0

var _settings: NoiseSettings = null
var _clock: WorldClock = null
var _noise: NoiseService = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = NoiseSettings.new()
	_clock = WorldClock.new(CALENDAR_SCALE, true)
	_noise = NoiseService.new(_settings, _clock, HALF_EXTENT)


func after_each() -> void:
	GameLogger.set_capture(false)


## Advances the clock by `seconds` of real time and steps the noise system
## the way ServerWorld does (action delta, calendar delta).
func _advance(seconds: float) -> void:
	var world_delta: float = _clock.step(seconds, true)
	_noise.step(null, _clock.last_action_delta, world_delta)


func _emit(position: Vector3, loudness: float, source: String = SOURCE) -> ActionResult:
	return _noise.emit(source, position, loudness, _settings.default_profile)


func _ids(perceptions: Array[NoisePerception]) -> PackedStringArray:
	var ids: PackedStringArray = []
	for perception: NoisePerception in perceptions:
		ids.append(perception.event.noise_id)
	return ids


func test_default_settings_resource_is_valid() -> void:
	var loaded: NoiseSettings = NoiseSettings.load_or_default()
	assert_eq(loaded.validate().size(), 0, "; ".join(loaded.validate()))
	assert_true(ResourceLoader.exists(NoiseSettings.DEFAULT_PATH), "tuning resource exists")
	var broken: NoiseSettings = NoiseSettings.new()
	broken.cell_size_m = 0.0
	broken.default_profile = "missing"
	assert_true(broken.validate().size() >= 2)


func test_emit_returns_event_with_documented_fields() -> void:
	_clock.step(3.0, true)
	var result: ActionResult = _noise.emit(SOURCE, Vector3(10, 0, -4), 30.0, "low", {"room": "garage"})
	assert_true(result.ok, result.reason)
	assert_eq(result.event["event_type"], NoiseService.EVENT_NOISE_EMITTED)
	assert_eq(result.event["source_id"], SOURCE)
	assert_eq(result.event["position"], [10.0, 0.0, -4.0])
	assert_eq(result.event["loudness"], 30.0)
	assert_eq(result.event["frequency_profile"], "low")
	assert_eq(result.event["event_time"], 3.0)
	assert_true(SaveService.is_json_safe(result.event), "event is JSON-safe")
	var event: NoiseEvent = _noise.get_event(str(result.event["noise_id"]))
	assert_not_null(event)
	assert_eq(event.occlusion_context, {"room": "garage"})
	assert_eq(_noise.active_count(), 1)


func test_noise_ids_cannot_collide_with_saved_entity_ids() -> void:
	var first: String = str(_emit(Vector3.ZERO, 10.0).event["noise_id"])
	var second: String = str(_emit(Vector3.ZERO, 10.0).event["noise_id"])
	assert_ne(first, second)
	assert_eq(EntityIdGenerator.sequence_of(first), -1, "not a <kind>_<sequence> entity id")
	assert_true(first.begins_with(NoiseService.NOISE_ID_PREFIX))
	assert_false(EntityIdGenerator.new().is_valid_kind(first.get_slice(NoiseService.NOISE_ID_SEPARATOR, 0) + NoiseService.NOISE_ID_SEPARATOR))


func test_invalid_emits_are_rejected_without_state_change() -> void:
	assert_eq(_emit(Vector3.ZERO, NAN).reason, NoiseService.REASON_BAD_LOUDNESS)
	assert_eq(_emit(Vector3.ZERO, INF).reason, NoiseService.REASON_BAD_LOUDNESS)
	assert_eq(_emit(Vector3.ZERO, -INF).reason, NoiseService.REASON_BAD_LOUDNESS)
	assert_eq(_emit(Vector3.ZERO, 0.0).reason, NoiseService.REASON_BAD_LOUDNESS)
	assert_eq(_emit(Vector3.ZERO, -5.0).reason, NoiseService.REASON_BAD_LOUDNESS)
	assert_eq(_emit(Vector3.ZERO, _settings.max_loudness * 1.001).reason, NoiseService.REASON_LOUDNESS_TOO_HIGH)
	assert_eq(_emit(Vector3.ZERO, 1.0e30).reason, NoiseService.REASON_LOUDNESS_TOO_HIGH)
	assert_eq(_emit(Vector3(NAN, 0, 0), 10.0).reason, NoiseService.REASON_BAD_POSITION)
	assert_eq(_emit(Vector3(0, INF, 0), 10.0).reason, NoiseService.REASON_BAD_POSITION)
	assert_eq(_emit(Vector3(HALF_EXTENT + 1.0, 0, 0), 10.0).reason, NoiseService.REASON_OUT_OF_WORLD)
	assert_eq(_emit(Vector3(0, 0, -1.0e20), 10.0).reason, NoiseService.REASON_OUT_OF_WORLD)
	assert_eq(_emit(Vector3.ZERO, 10.0, "").reason, NoiseService.REASON_BAD_SOURCE)
	assert_eq(_noise.emit(SOURCE, Vector3.ZERO, 10.0, "ultrasonic").reason, NoiseService.REASON_BAD_PROFILE)
	assert_eq(_noise.emit(SOURCE, Vector3.ZERO, 10.0, _settings.default_profile, {"node": Vector3.ZERO}).reason, NoiseService.REASON_BAD_OCCLUSION_CONTEXT)
	assert_eq(_noise.active_count(), 0)
	assert_true(_emit(Vector3.ZERO, _settings.max_loudness).ok, "max loudness itself is allowed")


func test_invalid_queries_return_nothing() -> void:
	_emit(Vector3.ZERO, 50.0)
	assert_eq(_noise.query_audible(Vector3(NAN, 0, 0), 1.0, NoiseService.SINCE_ALWAYS).size(), 0)
	assert_eq(_noise.query_audible(Vector3(1.0e20, 0, 0), 1.0, NoiseService.SINCE_ALWAYS).size(), 0)
	assert_eq(_noise.query_audible(Vector3.ZERO, NAN, NoiseService.SINCE_ALWAYS).size(), 0)
	assert_eq(_noise.query_audible(Vector3.ZERO, -1.0, NoiseService.SINCE_ALWAYS).size(), 0)
	assert_eq(_noise.query_audible(Vector3.ZERO, 0.0, NoiseService.SINCE_ALWAYS).size(), 0, "deaf listener")
	assert_eq(_noise.query_audible(Vector3.ZERO, 1.0, NAN).size(), 0)
	assert_eq(_noise.query_audible(Vector3.ZERO, 1.0, NoiseService.SINCE_ALWAYS).size(), 1)


func test_intensity_attenuates_with_distance() -> void:
	_emit(Vector3.ZERO, 40.0)
	var near: Array[NoisePerception] = _noise.query_audible(Vector3(5, 0, 0), 1.0, NoiseService.SINCE_ALWAYS)
	var far: Array[NoisePerception] = _noise.query_audible(Vector3(0, 0, 20), 1.0, NoiseService.SINCE_ALWAYS)
	assert_eq(near.size(), 1)
	assert_eq(far.size(), 1)
	assert_true(absf(near[0].intensity - (40.0 - 5.0 * _settings.distance_attenuation_per_m)) < EPSILON)
	assert_true(absf(far[0].intensity - (40.0 - 20.0 * _settings.distance_attenuation_per_m)) < EPSILON)
	assert_true(absf(near[0].distance - 5.0) < EPSILON)
	assert_true(near[0].intensity > far[0].intensity)


func test_distance_boundary() -> void:
	_emit(Vector3.ZERO, 40.0)
	var limit: float = _noise.max_audible_distance(40.0, 1.0)
	assert_true(absf(limit - (40.0 - _settings.min_audible_intensity) / _settings.distance_attenuation_per_m) < EPSILON)
	assert_eq(_noise.query_audible(Vector3(limit - 0.01, 0, 0), 1.0, NoiseService.SINCE_ALWAYS).size(), 1, "just inside")
	assert_eq(_noise.query_audible(Vector3(limit + 0.01, 0, 0), 1.0, NoiseService.SINCE_ALWAYS).size(), 0, "just outside")
	assert_eq(_noise.query_audible(Vector3(0, 0, -(limit + 0.01)), 1.0, NoiseService.SINCE_ALWAYS).size(), 0)
	# Better hearing extends the range, worse hearing shrinks it.
	assert_eq(_noise.query_audible(Vector3(limit + 5.0, 0, 0), 2.0, NoiseService.SINCE_ALWAYS).size(), 1)
	assert_eq(_noise.query_audible(Vector3(limit - 5.0, 0, 0), 0.5, NoiseService.SINCE_ALWAYS).size(), 0)
	# Hearing above the configured cap is clamped, not trusted.
	var capped: float = _noise.max_audible_distance(40.0, _settings.max_hearing_multiplier)
	assert_eq(_noise.max_audible_distance(40.0, _settings.max_hearing_multiplier * 10.0), capped)


func test_intensity_decays_with_action_time_and_expires() -> void:
	_emit(Vector3.ZERO, 40.0)
	var listener: Vector3 = Vector3(10, 0, 0)
	var fresh: float = _noise.query_audible(listener, 1.0, NoiseService.SINCE_ALWAYS)[0].intensity
	_advance(_settings.event_lifetime_sec * 0.5)
	var half: Array[NoisePerception] = _noise.query_audible(listener, 1.0, NoiseService.SINCE_ALWAYS)
	assert_eq(half.size(), 1)
	assert_true(absf(half[0].intensity - (40.0 * 0.5 - 10.0 * _settings.distance_attenuation_per_m)) < EPSILON, "linear time decay")
	assert_true(half[0].intensity < fresh)
	# A faded noise is no longer audible far away although it still exists.
	assert_eq(_noise.query_audible(Vector3(30, 0, 0), 1.0, NoiseService.SINCE_ALWAYS).size(), 0)
	assert_eq(_noise.active_count(), 1)
	_advance(_settings.event_lifetime_sec * 0.5)
	assert_eq(_noise.query_audible(Vector3.ZERO, 1.0, NoiseService.SINCE_ALWAYS).size(), 0, "expired")
	assert_eq(_noise.active_count(), 0, "expired events are removed")


func test_expired_events_are_inaudible_even_before_cleanup() -> void:
	_emit(Vector3.ZERO, 40.0)
	_clock.step(_settings.event_lifetime_sec + 1.0, true)
	assert_eq(_noise.active_count(), 1, "step() has not run yet")
	assert_eq(_noise.query_audible(Vector3.ZERO, 1.0, NoiseService.SINCE_ALWAYS).size(), 0)
	assert_eq(_noise.purge_expired(), 1)
	assert_eq(_noise.active_count(), 0)


func test_no_expiry_while_world_clock_is_paused() -> void:
	_emit(Vector3.ZERO, 40.0)
	var before: float = _noise.query_audible(Vector3(3, 0, 0), 1.0, NoiseService.SINCE_ALWAYS)[0].intensity
	for tick: int in range(600):
		var world_delta: float = _clock.step(1.0, false)  # nobody online -> paused
		assert_eq(world_delta, 0.0)
		assert_eq(_clock.last_action_delta, 0.0, "action time is paused too")
		_noise.step(null, _clock.last_action_delta, world_delta)
	assert_eq(_clock.action_time_sec, 0.0)
	assert_eq(_noise.active_count(), 1, "real time alone never expires noise")
	assert_eq(_noise.query_audible(Vector3(3, 0, 0), 1.0, NoiseService.SINCE_ALWAYS)[0].intensity, before)


func test_since_filters_older_events() -> void:
	var old_id: String = str(_emit(Vector3.ZERO, 40.0).event["noise_id"])
	_clock.step(1.0, true)
	var new_id: String = str(_emit(Vector3(1, 0, 0), 40.0).event["noise_id"])
	assert_eq(_ids(_noise.query_audible(Vector3.ZERO, 1.0, NoiseService.SINCE_ALWAYS)).size(), 2)
	assert_eq(_ids(_noise.query_audible(Vector3.ZERO, 1.0, 0.0)), PackedStringArray([new_id]), "event_time must be > since")
	assert_eq(_noise.query_audible(Vector3.ZERO, 1.0, 1.0).size(), 0)
	assert_true(_ids(_noise.query_audible(Vector3.ZERO, 1.0, -0.5)).has(old_id))


func test_results_are_sorted_strongest_first() -> void:
	var quiet: String = str(_emit(Vector3(2, 0, 0), 10.0).event["noise_id"])
	var loud: String = str(_emit(Vector3(2, 0, 0), 60.0).event["noise_id"])
	var twin: String = str(_emit(Vector3(2, 0, 0), 10.0).event["noise_id"])
	assert_eq(_ids(_noise.query_audible(Vector3.ZERO, 1.0, NoiseService.SINCE_ALWAYS)), PackedStringArray([loud, quiet, twin]), "ties keep emit order")


func test_grid_query_matches_brute_force() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 20261115
	for index: int in range(120):
		var position: Vector3 = Vector3(rng.randf_range(-HALF_EXTENT, HALF_EXTENT), 0.0, rng.randf_range(-HALF_EXTENT, HALF_EXTENT))
		assert_true(_emit(position, rng.randf_range(1.5, _settings.max_loudness), "src_%d" % index).ok)
		_clock.step(rng.randf_range(0.0, 0.05), true)
	# Events exactly on cell borders and world corners.
	for corner: Vector3 in [Vector3(-HALF_EXTENT, 0, -HALF_EXTENT), Vector3(HALF_EXTENT, 0, HALF_EXTENT), Vector3(_settings.cell_size_m, 0, -_settings.cell_size_m), Vector3.ZERO]:
		assert_true(_emit(corner, 35.0).ok)
	var compared: int = 0
	var audible_total: int = 0
	for index: int in range(300):
		var listener: Vector3 = Vector3(rng.randf_range(-HALF_EXTENT, HALF_EXTENT), 0.0, rng.randf_range(-HALF_EXTENT, HALF_EXTENT))
		if index % 10 == 0:
			listener = Vector3(snappedf(listener.x, _settings.cell_size_m), 0.0, snappedf(listener.z, _settings.cell_size_m))
		var hearing: float = [0.5, 1.0, 2.0, _settings.max_hearing_multiplier][index % 4]
		var since: float = NoiseService.SINCE_ALWAYS if index % 3 == 0 else _clock.action_time_sec * 0.5
		var grid: Array[NoisePerception] = _noise.query_audible(listener, hearing, since)
		var brute: Array[NoisePerception] = _noise.query_audible_brute_force(listener, hearing, since)
		if _ids(grid) != _ids(brute):
			fail("grid/brute mismatch at %s hearing %s: %s vs %s" % [str(listener), str(hearing), str(_ids(grid)), str(_ids(brute))])
			return
		for row: int in range(grid.size()):
			if grid[row].intensity != brute[row].intensity:
				fail("intensity mismatch at %s" % str(listener))
				return
		compared += 1
		audible_total += grid.size()
	assert_eq(compared, 300)
	assert_true(audible_total > 300, "the scenario actually exercises audible noise (got %d)" % audible_total)


func test_same_cell_queries_share_cached_candidates() -> void:
	for index: int in range(20):
		_emit(Vector3(index * 3.0, 0, 0), 30.0)
	assert_eq(_noise.cache_miss_count, 0)
	var base: Vector3 = Vector3(1, 0, 1)
	_noise.query_audible(base, 1.0, NoiseService.SINCE_ALWAYS)
	assert_eq(_noise.cache_miss_count, 1)
	assert_eq(_noise.cache_hit_count, 0)
	for index: int in range(10):
		# Different positions inside the same grid cell.
		var listener: Vector3 = base + Vector3(index * 0.5, 0, index * 0.25)
		var grid: Array[NoisePerception] = _noise.query_audible(listener, 1.0, NoiseService.SINCE_ALWAYS)
		assert_eq(_ids(grid), _ids(_noise.query_audible_brute_force(listener, 1.0, NoiseService.SINCE_ALWAYS)))
	assert_eq(_noise.cache_miss_count, 1, "one cell scan for the whole group")
	assert_eq(_noise.cache_hit_count, 10)
	# A new event invalidates the cache, so it is never stale.
	var fresh: String = str(_emit(Vector3(2, 0, 2), 30.0).event["noise_id"])
	assert_true(_ids(_noise.query_audible(base, 1.0, NoiseService.SINCE_ALWAYS)).has(fresh))
	assert_eq(_noise.cache_miss_count, 2)
	# Expiry invalidates it as well.
	_advance(_settings.event_lifetime_sec + 1.0)
	assert_eq(_noise.query_audible(base, 1.0, NoiseService.SINCE_ALWAYS).size(), 0)


func test_capacity_evicts_oldest_events() -> void:
	_settings.max_active_events = 5
	var first: String = str(_emit(Vector3.ZERO, 20.0).event["noise_id"])
	for index: int in range(5):
		assert_true(_emit(Vector3(index, 0, 0), 20.0).ok)
	assert_eq(_noise.active_count(), 5)
	assert_null(_noise.get_event(first), "oldest event evicted")
	assert_eq(_noise.evicted_count, 1)
	assert_eq(_noise.query_audible(Vector3.ZERO, 1.0, NoiseService.SINCE_ALWAYS).size(), 5)


func test_occlusion_interface_scales_loudness() -> void:
	_emit(Vector3.ZERO, 40.0)
	var listener: Vector3 = Vector3(10, 0, 0)
	var open_air: float = _noise.query_audible(listener, 1.0, NoiseService.SINCE_ALWAYS)[0].intensity
	_noise.set_occlusion(_HalfOcclusion.new())
	var muffled: Array[NoisePerception] = _noise.query_audible(listener, 1.0, NoiseService.SINCE_ALWAYS)
	assert_eq(muffled.size(), 1)
	assert_true(absf(muffled[0].intensity - (40.0 * 0.5 - 10.0 * _settings.distance_attenuation_per_m)) < EPSILON)
	assert_true(muffled[0].intensity < open_air)
	assert_eq(_ids(_noise.query_audible(listener, 1.0, NoiseService.SINCE_ALWAYS)), _ids(_noise.query_audible_brute_force(listener, 1.0, NoiseService.SINCE_ALWAYS)))
	_noise.set_occlusion(null)
	assert_eq(_noise.query_audible(listener, 1.0, NoiseService.SINCE_ALWAYS)[0].intensity, open_air, "null restores the open-air default")


func test_composition_registers_noise_and_nothing_is_saved() -> void:
	var world: ServerWorld = ServerComposition.create_world(WORLD, CompositionConfig.from_defaults())
	var noise: NoiseService = world.get_system(NoiseService.SYSTEM_ID) as NoiseService
	assert_not_null(noise)
	assert_eq(world.seed_new_world(DevWorldSeed.new()), OK)
	var alice: PlayerState = world.join("alice")
	assert_true(noise.emit(alice.player_id, alice.position, 20.0, "broadband").ok)
	world.step_systems(0.05)
	assert_eq(noise.active_count(), 1)
	var documents: Dictionary = world.to_documents()
	var systems: Dictionary = (documents["world_state"] as Dictionary)[ServerWorld.KEY_SYSTEMS]
	assert_false(systems.has(NoiseService.SYSTEM_ID), "noise is transient and never saved")
	var restored: ServerWorld = ServerComposition.create_world(WORLD, CompositionConfig.from_defaults())
	assert_eq(restored.restore_documents(documents["world_state"], documents["players"]).size(), 0)
	assert_eq((restored.get_system(NoiseService.SYSTEM_ID) as NoiseService).active_count(), 0, "noise list is empty after a restart")


## Test double: everything is half as loud (e.g. behind a wall).
class _HalfOcclusion extends NoiseOcclusion:
	func transmission(_event: NoiseEvent, _listener_position: Vector3) -> float:
		return 0.5
