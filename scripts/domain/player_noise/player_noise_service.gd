class_name PlayerNoiseService
extends ServerSystem
## Server-authoritative player movement noise: footsteps (docs/02 §5.3).
## System id "player_noise"; registered by ServerComposition after "noise"
## (it emits into it) and before "zombie" (the listeners), so a footstep can
## be heard in the same tick. No networking, no client input: the only
## source is how far the server moved each player.
##
## Each server tick, for every online living player, the XZ distance
## between the previous and the current server position is added to that
## player's stride. Every `stride_length_m` a footstep is emitted with
## NoiseService.emit(player_id, point on the path, footstep_loudness,
## footstep_frequency_profile). Tick length does not change the result:
## several steps of one long tick are placed along the path.
##
## No footsteps:
##   - standing still, or slower than `min_speed_mps`
##   - dead players (their stride is forgotten, a respawn starts a new one)
##   - offline players (forgotten on leave)
##   - while the world clock is paused (action_delta == 0); movement made
##     during the pause is not counted afterwards
##   - teleports: a position change faster than `teleport_speed_mps`
##     (respawn, admin move); the stride restarts
##   - footstep_loudness == 0 or no noise system registered
## A player is first seen in step(), so the position change between joining
## and the first tick is never a footstep.
##
## Speeds use `action_delta` (real seconds, docs/09 §14.16):
## ServerWorld.step_movement() integrates player movement in real seconds,
## so the walking/teleport thresholds do not depend on the calendar time
## scale.
##
## Persistence: none. The state is the distance walked since the last
## footstep (less than one stride per player); after a restart everybody is
## offline and strides start at 0 (docs/15 P2-50).

const SYSTEM_ID: String = "player_noise"

## Diagnostics (tests / profiling).
var last_footstep_count: int = 0
var total_footstep_count: int = 0

var _settings: PlayerNoiseSettings
## player_id -> server position at the previous step.
var _last_position: Dictionary[String, Vector3] = {}
## player_id -> metres walked since that player's last footstep.
var _carried_m: Dictionary[String, float] = {}


func _init(settings: PlayerNoiseSettings) -> void:
	_settings = settings


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ ServerSystem

func on_player_offline(_world: ServerWorld, player_id: String) -> void:
	_forget(player_id)


func step(world: ServerWorld, action_delta: float, _world_delta: float) -> void:
	last_footstep_count = 0
	var noise: NoiseService = world.get_system(NoiseService.SYSTEM_ID) as NoiseService
	if noise == null or _settings.footstep_loudness <= 0.0:
		return
	var survival: SurvivalService = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	# Sorted ids: footsteps of one tick are emitted in a deterministic order.
	for player_id: String in world.online_player_ids():
		var player: PlayerState = world.get_player(player_id)
		if player == null:
			continue
		if survival != null and not survival.is_alive(player_id):
			_forget(player_id)
			continue
		if not _last_position.has(player_id):
			_last_position[player_id] = player.position
			_carried_m[player_id] = FootstepRules.NO_DISTANCE
			continue
		var from: Vector3 = _last_position[player_id]
		_last_position[player_id] = player.position
		if action_delta <= 0.0:
			continue
		_advance_stride(noise, player, from, action_delta)
	total_footstep_count += last_footstep_count


# ------------------------------------------------------------ internals

## Adds this tick's movement to the player's stride and emits the footsteps
## it completes.
func _advance_stride(noise: NoiseService, player: PlayerState, from: Vector3, action_delta: float) -> void:
	var player_id: String = player.player_id
	var moved: float = FootstepRules.flat_distance(from, player.position)
	if FootstepRules.is_teleport(moved, action_delta, _settings.teleport_speed_mps):
		_carried_m[player_id] = FootstepRules.NO_DISTANCE
		return
	if not FootstepRules.is_walking(moved, action_delta, _settings.min_speed_mps):
		return
	var carried: float = _carried_m[player_id]
	_carried_m[player_id] = FootstepRules.carried_after(carried, moved, _settings.stride_length_m)
	for position: Vector3 in FootstepRules.footstep_positions(from, player.position, carried, _settings.stride_length_m, _settings.max_footsteps_per_tick):
		var emitted: ActionResult = noise.emit(player_id, position, _settings.footstep_loudness, _settings.footstep_frequency_profile)
		if emitted.ok:
			last_footstep_count += 1
		else:
			GameLogger.warning("player_noise", "footstep noise rejected", {"player_id": player_id, "reason": emitted.reason, "operation": "footstep"})


func _forget(player_id: String) -> void:
	_last_position.erase(player_id)
	_carried_m.erase(player_id)
