class_name RateLimiter
extends RefCounted
## Token bucket per key (e.g. peer id). Time is passed in (msec) so the
## limiter is deterministic in tests.

const MSEC_PER_SEC: float = 1000.0

var _rate_per_sec: float
var _burst: float
var _tokens: Dictionary[int, float] = {}
var _last_msec: Dictionary[int, int] = {}


func _init(rate_per_sec: float, burst: int) -> void:
	_rate_per_sec = rate_per_sec
	_burst = float(maxi(burst, 1))


## Consumes one token for `key`; false when the bucket is empty.
func allow(key: int, now_msec: int) -> bool:
	var tokens: float = _tokens.get(key, _burst)
	var last: int = _last_msec.get(key, now_msec)
	tokens = minf(_burst, tokens + float(maxi(now_msec - last, 0)) / MSEC_PER_SEC * _rate_per_sec)
	_last_msec[key] = now_msec
	if tokens < 1.0:
		_tokens[key] = tokens
		return false
	_tokens[key] = tokens - 1.0
	return true


func forget(key: int) -> void:
	_tokens.erase(key)
	_last_msec.erase(key)
