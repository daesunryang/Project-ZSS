class_name BucketScheduler
extends RefCounted
## Central bucketed scheduler (docs/09 §7, CLAUDE.md §6): spreads periodic
## work for many entities across ticks instead of running everything every
## frame or creating one Timer node per entity.
##
## Each id is assigned to one of `bucket_count` buckets round-robin in
## registration order (deterministic). `advance(delta)` returns the ids whose
## bucket came due; every id is returned exactly once per `period_sec` of
## advanced time. One call never returns an id more than once, even for a
## huge delta (at most one full period is processed per call; the rest of
## the backlog is dropped so a stall cannot cause a burst spiral).

## Relative tolerance so float accumulation (e.g. 60 x 1/60 s) still
## completes a full period.
const SLOT_EPSILON_RATIO: float = 1e-6

var period_sec: float
var bucket_count: int

var _buckets: Array[PackedStringArray] = []
var _bucket_of: Dictionary[String, int] = {}
var _next_bucket: int = 0
var _cursor: int = 0
var _elapsed: float = 0.0


func _init(period: float, buckets: int) -> void:
	period_sec = maxf(period, 0.0001)
	bucket_count = maxi(buckets, 1)
	for index: int in range(bucket_count):
		_buckets.append(PackedStringArray())


## Adds an id (no-op if already present). Returns its bucket index.
func add(id: String) -> int:
	if _bucket_of.has(id):
		return _bucket_of[id]
	var bucket: int = _next_bucket
	_next_bucket = (_next_bucket + 1) % bucket_count
	_buckets[bucket].append(id)
	_bucket_of[id] = bucket
	return bucket


func remove(id: String) -> void:
	if not _bucket_of.has(id):
		return
	var bucket: int = _bucket_of[id]
	var index: int = _buckets[bucket].find(id)
	if index >= 0:
		_buckets[bucket].remove_at(index)
	_bucket_of.erase(id)


func has(id: String) -> bool:
	return _bucket_of.has(id)


func size() -> int:
	return _bucket_of.size()


func bucket_of(id: String) -> int:
	return _bucket_of.get(id, -1)


## Advances time and returns the ids due in this call, in bucket order then
## registration order.
func advance(delta: float) -> PackedStringArray:
	var due: PackedStringArray = []
	if not is_finite(delta) or delta <= 0.0:
		return due
	var slot: float = period_sec / float(bucket_count)
	var epsilon: float = slot * SLOT_EPSILON_RATIO
	_elapsed += delta
	var slots_run: int = 0
	while _elapsed + epsilon >= slot and slots_run < bucket_count:
		_elapsed = maxf(_elapsed - slot, 0.0)
		due.append_array(_buckets[_cursor])
		_cursor = (_cursor + 1) % bucket_count
		slots_run += 1
	if slots_run == bucket_count and _elapsed >= slot:
		_elapsed = fmod(_elapsed, slot)
	return due
