class_name AttackIntentPolicy
extends RefCounted
## Clock-independent client flood guard. Server rules remain authoritative.

var _minimum_interval_sec: float
var _has_sent: bool = false
var _last_sent_sec: float = 0.0


func _init(minimum_interval_sec: float) -> void:
	_minimum_interval_sec = minimum_interval_sec


## Returns true only when connected and the local minimum interval elapsed.
## A true result records the injected time; false while offline records nothing.
func should_send(is_connected: bool, now_sec: float) -> bool:
	if not is_connected:
		return false
	if _has_sent and now_sec - _last_sent_sec < _minimum_interval_sec:
		return false
	_has_sent = true
	_last_sent_sec = now_sec
	return true


func reset() -> void:
	_has_sent = false
	_last_sent_sec = 0.0
