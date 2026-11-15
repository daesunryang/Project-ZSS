class_name WorldClock
extends RefCounted
## Server-authoritative world time (docs/03 §4: the single real<->world time
## conversion). World time is seconds since world creation, saved with the
## world. PROVISIONAL defaults (docs/15 §6): time_scale 1.0 (real time) and
## pause while no player is online (docs/00 proposal).

var world_time_sec: float = 0.0
var time_scale: float = 1.0
var pause_when_empty: bool = true


func _init(scale: float = 1.0, pause_if_empty: bool = true) -> void:
	time_scale = scale
	pause_when_empty = pause_if_empty


## Advances world time and returns the world-time delta for this tick
## (0 while paused). Negative or non-finite real deltas are ignored.
func step(real_delta: float, any_player_online: bool) -> float:
	if not is_finite(real_delta) or real_delta <= 0.0:
		return 0.0
	if pause_when_empty and not any_player_online:
		return 0.0
	var world_delta: float = real_delta * time_scale
	world_time_sec += world_delta
	return world_delta


func is_paused(any_player_online: bool) -> bool:
	return pause_when_empty and not any_player_online


## Restores a saved world time. Rejects negative / non-finite values.
func restore(value: float) -> Error:
	if not is_finite(value) or value < 0.0:
		return ERR_INVALID_PARAMETER
	world_time_sec = value
	return OK
