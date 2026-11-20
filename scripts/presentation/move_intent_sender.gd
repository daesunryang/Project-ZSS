class_name MoveIntentSender
extends RefCounted
## Stateful, clock-independent movement send policy. Callers inject `now_sec`.

var _resend_interval_sec: float
var _direction_epsilon: float
var _yaw_epsilon_rad: float
var _has_sent: bool = false
var _last_direction: Vector2 = Vector2.ZERO
var _last_yaw: float = 0.0
var _last_sprinting: bool = false
var _last_sent_sec: float = 0.0


func _init(resend_interval_sec: float, direction_epsilon: float, yaw_epsilon_rad: float) -> void:
	_resend_interval_sec = resend_interval_sec
	_direction_epsilon = direction_epsilon
	_yaw_epsilon_rad = yaw_epsilon_rad


## True once for stop, on moving changes, and periodically while held.
## A true result records the send at the injected time.
func should_send(direction: Vector2, yaw: float, now_sec: float, sprinting: bool = false) -> bool:
	if direction.is_zero_approx():
		if _has_sent and not _last_direction.is_zero_approx():
			_remember(Vector2.ZERO, yaw, false, now_sec)
			return true
		return false
	if not _has_sent:
		_remember(direction, yaw, sprinting, now_sec)
		return true
	var direction_changed: bool = direction.distance_to(_last_direction) > _direction_epsilon
	var yaw_changed: bool = absf(angle_difference(_last_yaw, yaw)) > _yaw_epsilon_rad
	var sprint_changed: bool = sprinting != _last_sprinting
	var resend_due: bool = now_sec - _last_sent_sec >= _resend_interval_sec
	if direction_changed or yaw_changed or sprint_changed or resend_due:
		_remember(direction, yaw, sprinting, now_sec)
		return true
	return false


func reset() -> void:
	_has_sent = false
	_last_direction = Vector2.ZERO
	_last_yaw = 0.0
	_last_sprinting = false
	_last_sent_sec = 0.0


func _remember(direction: Vector2, yaw: float, sprinting: bool, now_sec: float) -> void:
	_has_sent = true
	_last_direction = direction
	_last_yaw = yaw
	_last_sprinting = sprinting
	_last_sent_sec = now_sec
