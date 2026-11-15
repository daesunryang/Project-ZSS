class_name NoiseService
extends ServerSystem
## Server-authoritative noise events (docs/02 §5.3). System id "noise";
## registered by ServerComposition before the systems that listen to it.
##
## Public API (other systems use `world.get_system(NoiseService.SYSTEM_ID)`):
##   emit(source_id, position, loudness, frequency_profile, occlusion_context = {}) -> ActionResult
##   query_audible(position, hearing_multiplier, since_time) -> Array[NoisePerception]
##   max_audible_distance(loudness, hearing_multiplier) -> float
##   purge_expired() -> int, active_count(), get_event(noise_id), set_occlusion(provider)
##
## emit() success event:
##   {event_type: "noise_emitted", noise_id, source_id, position: [x, y, z],
##    loudness, frequency_profile, event_time}
## Failure reasons: bad_noise_source, bad_noise_position, noise_out_of_world,
## bad_noise_loudness, noise_loudness_too_high, bad_noise_profile,
## bad_noise_occlusion_context.
##
## Time: noise runs on action time (WorldClock.action_time_sec, real seconds,
## docs/09 §14.16). `event_time`, the `since_time` of a query, the lifetime
## and the linear fade are all real seconds; the calendar time scale does
## not change how long a noise lasts.
##
## Spatial lookup: every event sits in one XZ hash cell. A query collects the
## events of the cells within hearing reach of the listener's cell once and
## caches that candidate list per (cell, reach); other listeners in the same
## cell reuse it until an event is added or removed. So N zombies standing
## together cost one cell scan, not N scans over all noises (docs/02 §6.3).
##
## Persistence: none. Noise is transient (seconds); to_world_document() is
## empty and the list starts empty after a restart. Noise ids are runtime
## only ("noise:<n>") and must never be stored in save documents.

const SYSTEM_ID: String = "noise"
const EVENT_NOISE_EMITTED: String = "noise_emitted"

const NOISE_ID_SEPARATOR: String = ":"
## Cannot collide with entity ids (`<kind>_<sequence>`, docs/15 P1-2).
const NOISE_ID_PREFIX: String = "noise:"
const FIRST_SEQUENCE: int = 1
## `since_time` that matches every event (action time is never negative).
const SINCE_ALWAYS: float = -1.0

const REASON_BAD_SOURCE: String = "bad_noise_source"
const REASON_BAD_POSITION: String = "bad_noise_position"
const REASON_OUT_OF_WORLD: String = "noise_out_of_world"
const REASON_BAD_LOUDNESS: String = "bad_noise_loudness"
const REASON_LOUDNESS_TOO_HIGH: String = "noise_loudness_too_high"
const REASON_BAD_PROFILE: String = "bad_noise_profile"
const REASON_BAD_OCCLUSION_CONTEXT: String = "bad_noise_occlusion_context"

## Diagnostics (tests / profiling): candidate-list cache use and evictions.
var cache_hit_count: int = 0
var cache_miss_count: int = 0
var evicted_count: int = 0

var _settings: NoiseSettings
var _clock: WorldClock
var _world_half_extent_m: float
var _occlusion: NoiseOcclusion = NoiseOcclusion.new()
var _next_sequence: int = FIRST_SEQUENCE
## Active events in emit order (= expiry order: one lifetime for all).
var _events: Array[NoiseEvent] = []
var _by_id: Dictionary[String, NoiseEvent] = {}
## Occupied grid cells -> events in that cell.
var _cells: Dictionary[Vector2i, Array] = {}
## (cell.x, cell.y, reach in cells) -> candidate events in emit order.
var _candidate_cache: Dictionary[Vector3i, Array] = {}
## Loudest active event (bounds the search reach).
var _loudest_active: float = 0.0


func _init(settings: NoiseSettings, clock: WorldClock, world_half_extent_m: float) -> void:
	_settings = settings
	_clock = clock
	_world_half_extent_m = world_half_extent_m


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ public API

## Records a noise at `position` made by `source_id`. All inputs are
## validated; nothing changes on failure.
func emit(source_id: String, position: Vector3, loudness: float, frequency_profile: String, occlusion_context: Dictionary = {}) -> ActionResult:
	var reason: String = _validate_emit(source_id, position, loudness, frequency_profile, occlusion_context)
	if not reason.is_empty():
		GameLogger.warning("noise", "noise rejected", {"source_id": source_id, "reason": reason, "operation": "emit"})
		return ActionResult.failure(reason)
	while _events.size() >= _settings.max_active_events:
		_remove_event(_events[0])
		evicted_count += 1
	var event: NoiseEvent = NoiseEvent.new()
	event.sequence = _next_sequence
	event.noise_id = NOISE_ID_PREFIX + str(_next_sequence)
	_next_sequence += 1
	event.source_id = source_id
	event.position = position
	event.loudness = loudness
	event.frequency_profile = frequency_profile
	event.event_time = _clock.action_time_sec
	event.occlusion_context = occlusion_context.duplicate(true)
	_events.append(event)
	_by_id[event.noise_id] = event
	var cell: Vector2i = _cell_of(position)
	if not _cells.has(cell):
		_cells[cell] = []
	_cells[cell].append(event)
	_loudest_active = maxf(_loudest_active, loudness)
	_candidate_cache.clear()
	GameLogger.debug("noise", "noise emitted", {"entity_id": event.noise_id, "source_id": source_id, "loudness": loudness, "profile": frequency_profile})
	return ActionResult.success(event.to_event_dict(EVENT_NOISE_EMITTED))


## Noises a listener at `position` can hear now, strongest first (ties in
## emit order). Only events with event_time > `since_time` are
## returned (SINCE_ALWAYS for all). Invalid input returns an empty list.
func query_audible(position: Vector3, hearing_multiplier: float, since_time: float) -> Array[NoisePerception]:
	var heard: Array[NoisePerception] = []
	if not _is_valid_query(position, hearing_multiplier, since_time) or _events.is_empty():
		return heard
	var hearing: float = minf(hearing_multiplier, _settings.max_hearing_multiplier)
	var reach: float = max_audible_distance(_loudest_active, hearing)
	if reach < 0.0:
		return heard
	var reach_cells: int = ceili(reach / _settings.cell_size_m)
	for event: NoiseEvent in _candidates(_cell_of(position), reach_cells):
		_append_if_audible(heard, event, position, hearing, since_time)
	heard.sort_custom(_stronger_first)
	return heard


## Reference implementation without the grid (tests and diagnostics): same
## result as query_audible() by checking every active event.
func query_audible_brute_force(position: Vector3, hearing_multiplier: float, since_time: float) -> Array[NoisePerception]:
	var heard: Array[NoisePerception] = []
	if not _is_valid_query(position, hearing_multiplier, since_time):
		return heard
	var hearing: float = minf(hearing_multiplier, _settings.max_hearing_multiplier)
	for event: NoiseEvent in _events:
		_append_if_audible(heard, event, position, hearing, since_time)
	heard.sort_custom(_stronger_first)
	return heard


## Largest distance at which a fresh, unoccluded noise of `loudness` is
## audible for a listener with `hearing_multiplier` (negative = never).
func max_audible_distance(loudness: float, hearing_multiplier: float) -> float:
	var hearing: float = clampf(hearing_multiplier, 0.0, _settings.max_hearing_multiplier)
	return (loudness * hearing - _settings.min_audible_intensity) / _settings.distance_attenuation_per_m


## Removes fully faded events; returns how many were removed. Called from
## step(); public so callers/tests can force a cleanup.
func purge_expired() -> int:
	var removed: int = 0
	var now: float = _clock.action_time_sec
	while not _events.is_empty() and now - _events[0].event_time >= _settings.event_lifetime_sec:
		_remove_event(_events[0])
		removed += 1
	return removed


func active_count() -> int:
	return _events.size()


## Active event by id (read-only), or null.
func get_event(noise_id: String) -> NoiseEvent:
	return _by_id.get(noise_id, null)


## Installs the occlusion provider (null = open air default).
func set_occlusion(provider: NoiseOcclusion) -> void:
	_occlusion = provider if provider != null else NoiseOcclusion.new()


# ------------------------------------------------------------ ServerSystem

## Expiry follows action time only: while the world clock is paused
## (action_delta == 0) nothing fades and nothing is removed.
func step(_world: ServerWorld, action_delta: float, _world_delta: float) -> void:
	if action_delta <= 0.0:
		return
	purge_expired()


# ------------------------------------------------------------ internals

func _validate_emit(source_id: String, position: Vector3, loudness: float, frequency_profile: String, occlusion_context: Dictionary) -> String:
	if source_id.is_empty():
		return REASON_BAD_SOURCE
	if not position.is_finite():
		return REASON_BAD_POSITION
	if not _is_inside_world(position):
		return REASON_OUT_OF_WORLD
	if not is_finite(loudness) or loudness <= 0.0:
		return REASON_BAD_LOUDNESS
	if loudness > _settings.max_loudness:
		return REASON_LOUDNESS_TOO_HIGH
	if not _settings.is_valid_profile(frequency_profile):
		return REASON_BAD_PROFILE
	if not SaveService.is_json_safe(occlusion_context):
		return REASON_BAD_OCCLUSION_CONTEXT
	return ""


func _is_valid_query(position: Vector3, hearing_multiplier: float, since_time: float) -> bool:
	if not position.is_finite() or not _is_inside_world(position):
		return false
	if not is_finite(hearing_multiplier) or hearing_multiplier <= 0.0:
		return false
	return is_finite(since_time)


func _is_inside_world(position: Vector3) -> bool:
	return absf(position.x) <= _world_half_extent_m and absf(position.z) <= _world_half_extent_m


func _cell_of(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / _settings.cell_size_m), floori(position.z / _settings.cell_size_m))


## Events of all cells within `reach_cells` of `cell`, in emit order. Cached
## per (cell, reach) until the event set changes.
func _candidates(cell: Vector2i, reach_cells: int) -> Array[NoiseEvent]:
	var key: Vector3i = Vector3i(cell.x, cell.y, reach_cells)
	var found: Array[NoiseEvent] = []
	if _candidate_cache.has(key):
		cache_hit_count += 1
		found.assign(_candidate_cache[key])
		return found
	cache_miss_count += 1
	var side: int = reach_cells * 2 + 1
	if _cells.size() <= side * side:
		# Few occupied cells: walk them instead of the whole neighbourhood.
		for occupied: Vector2i in _cells:
			if absi(occupied.x - cell.x) <= reach_cells and absi(occupied.y - cell.y) <= reach_cells:
				found.append_array(_cells[occupied])
	else:
		for x: int in range(cell.x - reach_cells, cell.x + reach_cells + 1):
			for z: int in range(cell.y - reach_cells, cell.y + reach_cells + 1):
				var neighbour: Vector2i = Vector2i(x, z)
				if _cells.has(neighbour):
					found.append_array(_cells[neighbour])
	found.sort_custom(_emitted_first)
	_candidate_cache[key] = found
	return found


func _append_if_audible(heard: Array[NoisePerception], event: NoiseEvent, position: Vector3, hearing: float, since_time: float) -> void:
	if event.event_time <= since_time:
		return
	var age: float = _clock.action_time_sec - event.event_time
	if age >= _settings.event_lifetime_sec:
		return
	var transmission: float = _occlusion.transmission(event, position)
	if is_finite(transmission):
		transmission = clampf(transmission, NoiseOcclusion.NO_TRANSMISSION, NoiseOcclusion.FULL_TRANSMISSION)
	else:
		transmission = NoiseOcclusion.FULL_TRANSMISSION
	var time_factor: float = 1.0 - maxf(age, 0.0) / _settings.event_lifetime_sec
	var distance: float = event.position.distance_to(position)
	var intensity: float = event.loudness * hearing * transmission * time_factor - distance * _settings.distance_attenuation_per_m
	if intensity < _settings.min_audible_intensity:
		return
	var perception: NoisePerception = NoisePerception.new()
	perception.event = event
	perception.intensity = intensity
	perception.distance = distance
	heard.append(perception)


func _remove_event(event: NoiseEvent) -> void:
	_events.erase(event)
	_by_id.erase(event.noise_id)
	var cell: Vector2i = _cell_of(event.position)
	if _cells.has(cell):
		_cells[cell].erase(event)
		if _cells[cell].is_empty():
			_cells.erase(cell)
	_candidate_cache.clear()
	if event.loudness >= _loudest_active:
		_loudest_active = 0.0
		for remaining: NoiseEvent in _events:
			_loudest_active = maxf(_loudest_active, remaining.loudness)


static func _stronger_first(a: NoisePerception, b: NoisePerception) -> bool:
	if a.intensity != b.intensity:
		return a.intensity > b.intensity
	return a.event.sequence < b.event.sequence


static func _emitted_first(a: NoiseEvent, b: NoiseEvent) -> bool:
	return a.sequence < b.sequence
