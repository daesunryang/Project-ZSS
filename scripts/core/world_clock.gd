class_name WorldClock
extends RefCounted
## Server-authoritative world clock (docs/03 §4: the single real<->world time
## conversion). It keeps two times, both saved with the world (docs/00
## ADR-006, docs/09 §14.16):
##
##   calendar time  `world_time_sec`   world seconds since world creation.
##                  Advances real_delta * time_scale. Day/night and slow
##                  body rules (needs, infection stages, bleeding, recovery,
##                  starvation) run on it.
##   action time    `action_time_sec`  real seconds the world has been
##                  running. Advances real_delta. Everything a player acts
##                  against in real time runs on it (zombies, noise, melee
##                  cooldowns, footsteps, stamina regeneration, respawn delay).
##
## Both stop together while the clock is paused (nobody online and
## `pause_when_empty`). A bare WorldClock.new() is a real-time clock (scale
## 1); the game's clock is built by WorldClockSettings.create_clock()
## (default scale 24: one world day per real hour, paused while empty).

## Calendar time, world seconds.
var world_time_sec: float = 0.0
## Action time, real seconds (paused together with the calendar).
var action_time_sec: float = 0.0
## World (calendar) seconds per real second.
var time_scale: float = 1.0
var pause_when_empty: bool = true
## Deltas applied by the latest step() (both 0 while paused or for an
## ignored delta).
var last_world_delta: float = 0.0
var last_action_delta: float = 0.0


func _init(scale: float = 1.0, pause_if_empty: bool = true) -> void:
	time_scale = scale
	pause_when_empty = pause_if_empty


## Advances both times and returns the calendar delta of this tick (0 while
## paused); the action delta is `last_action_delta`. Negative, zero or
## non-finite real deltas are ignored.
func step(real_delta: float, any_player_online: bool) -> float:
	last_world_delta = 0.0
	last_action_delta = 0.0
	if not is_finite(real_delta) or real_delta <= 0.0:
		return 0.0
	if pause_when_empty and not any_player_online:
		return 0.0
	last_action_delta = real_delta
	last_world_delta = real_delta * time_scale
	action_time_sec += last_action_delta
	world_time_sec += last_world_delta
	return last_world_delta


func is_paused(any_player_online: bool) -> bool:
	return pause_when_empty and not any_player_online


## Restores a saved calendar time. Rejects negative / non-finite values.
func restore(value: float) -> Error:
	if not is_finite(value) or value < 0.0:
		return ERR_INVALID_PARAMETER
	world_time_sec = value
	return OK


## Restores a saved action time. Rejects negative / non-finite values.
func restore_action_time(value: float) -> Error:
	if not is_finite(value) or value < 0.0:
		return ERR_INVALID_PARAMETER
	action_time_sec = value
	return OK
