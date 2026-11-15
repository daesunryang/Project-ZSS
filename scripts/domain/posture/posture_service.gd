class_name PostureService
extends ServerSystem
## Server-authoritative posture of players and what follows from it (P2-T11,
## docs/00 ADR-017, docs/09 §14.26). System id "posture"; registered by
## ServerComposition after "survival" (whose rest it reads) and before
## "player_noise" and "zombie" (which ask the world for this tick's
## factors). No networking here: PostureNetModule calls request_posture()
## from its RPC handler and forwards drain_events().
##
## Posture model (PlayerPosture): STANDING, PRONE, RESTING (lying asleep).
## Resting belongs to SurvivalService (start_rest / stop_rest); this system
## owns "prone" and reports the three as one posture. A player is in exactly
## one: lying down to sleep ends prone, and a sleeper that wakes or is woken
## stands. Survival does not know this system; ServerComposition connects
## SurvivalService.rest_changed and player_died to the hooks below.
##
## Public API:
##   posture_of(player_id) -> PlayerPosture.Kind     (STANDING if unknown)
##   is_prone(player_id) -> bool
##   is_moving(player_id) -> bool
##   visibility_multiplier(player_id) -> float       (1.0 if not in the world)
##   request_posture(world, player_id, wanted) -> ActionResult
##   drain_events() -> Array[Dictionary]             (network read surface)
##
## What a posture changes (through the ServerSystem hooks, so no other system
## knows postures):
##   - Movement: a prone player moves at PostureSettings.prone_movement_multiplier
##     of its speed (player_movement_multiplier; a sleeper does not move at
##     all, which is the survival system's factor).
##   - Attacks: a prone player cannot make a melee attack ("player_prone",
##     player_attack_block_reason); it can pick up, put down and use items.
##   - Footsteps: quieter and with another stride while prone
##     (player_footstep_*_multiplier, read by PlayerNoiseService).
##   - Visibility: player_visibility_multiplier = PostureSettings.visibility(
##     posture, moving). ZombieService multiplies its sight range by the
##     world's product of these factors.
##
## Moving: a player is "moving" when the server moved it at least
## `moving_min_speed_mps` in a tick, and for `moving_memory_sec` after the
## last such tick. Only server positions count: a move request that moves
## nothing (a sleeper's) is not movement, and nothing a client says about its
## own movement is used. Positions are compared in step(), i.e. after
## ServerWorld.step_movement of the same tick. Speeds and times are action
## time (real seconds, docs/09 §14.16).
##
## Changing posture is instant (no transition time, docs/15 P2-190).
##
## Event (drain_events and ActionResult.event; JSON-safe), one per change:
##   {event_type: "player_posture_changed", player_id,
##    posture: "standing" | "prone" | "resting", previous: <the same names>,
##    world_time}
## No event when a posture ends silently: the player left, or a new character
## started (it stands).
##
## Failure reasons of request_posture, in check order: posture_unavailable
## (no world / no survival system), bad_posture, not_online (also a player
## without a character and an unknown player), unknown_player (no vitals),
## player_dead, already_in_posture, or what SurvivalService.start_rest /
## stop_rest answers (already_resting, cannot_rest_<danger>, ...). A refused
## request changes nothing.
##
## Save: nothing. Postures are session state like resting: leaving ends
## them and nobody is prone after a restart.

const SYSTEM_ID: String = "posture"
const EVENT_POSTURE_CHANGED: String = "player_posture_changed"
## Why a prone player's attack is refused (player_attack_block_reason).
const REASON_PLAYER_PRONE: String = "player_prone"
const REASON_ALREADY_IN_POSTURE: String = "already_in_posture"
const REASON_BAD_POSTURE: String = "bad_posture"
## The world has no survival system (composition error), or no world.
const REASON_UNAVAILABLE: String = "posture_unavailable"
const REASON_NOT_ONLINE: String = ServerWorld.REASON_NOT_ONLINE

const FULL_FACTOR: float = 1.0
## Value of "never moved" in `_moved_at`.
const NEVER_MOVED: float = -1.0e18

## Events discarded because the configured pending queue was full.
var dropped_event_count: int = 0

var _settings: PostureSettings
var _clock: WorldClock
## Set in on_registered(). Survival is registered before this system and
## holds no reference to it.
var _survival: SurvivalService = null
## Players lying prone. Session state, never saved.
var _prone: Dictionary[String, bool] = {}
## player_id -> server position at the previous step (players in the world).
var _last_position: Dictionary[String, Vector3] = {}
## player_id -> action time of the last tick in which the server moved it.
var _moved_at: Dictionary[String, float] = {}
var _events: Array[Dictionary] = []


func _init(settings: PostureSettings, clock: WorldClock) -> void:
	_settings = settings
	_clock = clock


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ public API

## Posture of the player; STANDING for unknown, offline and dead players.
func posture_of(player_id: String) -> PlayerPosture.Kind:
	if _survival != null and _survival.is_resting(player_id):
		return PlayerPosture.Kind.RESTING
	return PlayerPosture.Kind.PRONE if _prone.has(player_id) else PlayerPosture.Kind.STANDING


func is_prone(player_id: String) -> bool:
	return posture_of(player_id) == PlayerPosture.Kind.PRONE


## True when the server moved the player recently (see the header).
func is_moving(player_id: String) -> bool:
	if not _last_position.has(player_id):
		return false
	return _clock.action_time_sec - _moved_at.get(player_id, NEVER_MOVED) <= _settings.moving_memory_sec


## How well the player can be seen: PostureSettings.visibility of its posture
## and movement. 1.0 for a player this system does not track (not in the
## world): it hides nobody it knows nothing about.
func visibility_multiplier(player_id: String) -> float:
	if not _last_position.has(player_id):
		return FULL_FACTOR
	return _settings.visibility(posture_of(player_id), is_moving(player_id))


## The player takes the posture it wants (`wanted` is a PlayerPosture.Kind;
## an int, so untrusted values can be refused). See the header for the
## checks, the event and the failure reasons. From sleep to prone is two
## changes (it wakes, then lies prone): the returned event is the last one.
func request_posture(world: ServerWorld, player_id: String, wanted: int) -> ActionResult:
	if world == null or _survival == null:
		return ActionResult.failure(REASON_UNAVAILABLE)
	if not PlayerPosture.is_valid(wanted):
		return ActionResult.failure(REASON_BAD_POSTURE)
	if not world.is_online(player_id):
		return ActionResult.failure(REASON_NOT_ONLINE)
	if not _survival.has_player(player_id):
		return ActionResult.failure(SurvivalService.REASON_UNKNOWN_PLAYER)
	if not _survival.is_alive(player_id):
		return ActionResult.failure(SurvivalService.REASON_PLAYER_DEAD)
	var current: PlayerPosture.Kind = posture_of(player_id)
	match wanted:
		PlayerPosture.Kind.RESTING:
			# Survival decides (already_resting, cannot_rest_<danger>); the
			# posture event is recorded by on_rest_changed().
			var rested: ActionResult = _survival.start_rest(player_id)
			return ActionResult.success(_last_event_of(player_id)) if rested.ok else rested
		PlayerPosture.Kind.STANDING:
			if current == PlayerPosture.Kind.STANDING:
				return ActionResult.failure(REASON_ALREADY_IN_POSTURE)
			if current == PlayerPosture.Kind.RESTING:
				var woken: ActionResult = _survival.stop_rest(player_id)
				return ActionResult.success(_last_event_of(player_id)) if woken.ok else woken
			_prone.erase(player_id)
			return ActionResult.success(_report(player_id, PlayerPosture.Kind.STANDING, current))
		_:
			if current == PlayerPosture.Kind.PRONE:
				return ActionResult.failure(REASON_ALREADY_IN_POSTURE)
			if current == PlayerPosture.Kind.RESTING:
				var woken: ActionResult = _survival.stop_rest(player_id)
				if not woken.ok:
					return woken
			_prone[player_id] = true
			return ActionResult.success(_report(player_id, PlayerPosture.Kind.PRONE, PlayerPosture.Kind.STANDING))


## Returns and clears the events recorded since the previous call (oldest
## first). At most `max_pending_events` are kept between calls.
func drain_events() -> Array[Dictionary]:
	var drained: Array[Dictionary] = _events
	_events = []
	return drained


# ------------------------------------------------------------ hooks of other systems

## Hook for SurvivalService.rest_changed (ServerComposition connects it): the
## player lay down to sleep, or its rest ended with an event. Lying down
## ends prone; a sleeper that gets up, is woken or dies stands.
func on_rest_changed(player_id: String, resting: bool) -> void:
	if resting:
		var previous: PlayerPosture.Kind = PlayerPosture.Kind.PRONE if _prone.erase(player_id) else PlayerPosture.Kind.STANDING
		_report(player_id, PlayerPosture.Kind.RESTING, previous)
	else:
		_prone.erase(player_id)
		_report(player_id, PlayerPosture.Kind.STANDING, PlayerPosture.Kind.RESTING)


## Hook for SurvivalService.player_died: a dead character has no posture.
## Reported, so every mirror forgets a prone posture.
func on_player_died(_world: ServerWorld, player_id: String, _cause: String, _infection_stage: InfectionState.Stage) -> void:
	if _prone.erase(player_id):
		_report(player_id, PlayerPosture.Kind.STANDING, PlayerPosture.Kind.PRONE)


# ------------------------------------------------------------ ServerSystem

func on_registered(world: ServerWorld) -> void:
	_survival = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	if _survival == null:
		GameLogger.error("posture", "survival system is not registered before posture", {"world_id": world.world_id, "operation": "on_registered"})


func on_player_offline(_world: ServerWorld, player_id: String) -> void:
	# Leaving ends a posture without an event: the player is gone for everybody.
	_forget(player_id)


## The next character of a player stands (its old one died or is replaced).
## Its move to the spawn point is not movement: tracking starts over.
func on_character_started(_world: ServerWorld, player_id: String) -> void:
	_forget(player_id)


## Records which players the server moved in this tick.
func step(world: ServerWorld, action_delta: float, _world_delta: float) -> void:
	var now: float = _clock.action_time_sec
	for player_id: String in world.online_player_ids():
		var player: PlayerState = world.get_player(player_id)
		if player == null:
			continue
		if not _last_position.has(player_id):
			_last_position[player_id] = player.position
			continue
		var moved_m: float = Vector2(player.position.x - _last_position[player_id].x, player.position.z - _last_position[player_id].z).length()
		_last_position[player_id] = player.position
		if action_delta > 0.0 and is_finite(moved_m) and moved_m > 0.0 and moved_m / action_delta >= _settings.moving_min_speed_mps:
			_moved_at[player_id] = now


func player_movement_multiplier(player_id: String) -> float:
	return _settings.prone_movement_multiplier if is_prone(player_id) else FULL_FACTOR


func player_attack_block_reason(player_id: String) -> String:
	return REASON_PLAYER_PRONE if _settings.prone_blocks_attack and is_prone(player_id) else ""


func player_visibility_multiplier(player_id: String) -> float:
	return visibility_multiplier(player_id)


func player_footstep_loudness_multiplier(player_id: String) -> float:
	return _settings.prone_footstep_loudness_multiplier if is_prone(player_id) else FULL_FACTOR


func player_footstep_stride_multiplier(player_id: String) -> float:
	return _settings.prone_footstep_stride_multiplier if is_prone(player_id) else FULL_FACTOR


# ------------------------------------------------------------ internals

func _forget(player_id: String) -> void:
	_prone.erase(player_id)
	_last_position.erase(player_id)
	_moved_at.erase(player_id)


## Queues and logs one posture change; returns the event.
func _report(player_id: String, posture: PlayerPosture.Kind, previous: PlayerPosture.Kind) -> Dictionary:
	var event: Dictionary = {
		"event_type": EVENT_POSTURE_CHANGED,
		"player_id": player_id,
		"posture": PlayerPosture.name_of(posture),
		"previous": PlayerPosture.name_of(previous),
		"world_time": _clock.world_time_sec,
	}
	_events.append(event.duplicate(true))
	while _events.size() > _settings.max_pending_events:
		_events.pop_front()
		dropped_event_count += 1
	GameLogger.info("posture", "player posture changed", event)
	return event


## The newest queued event about `player_id` ({} if none): what a change
## made through the survival system reported (on_rest_changed).
func _last_event_of(player_id: String) -> Dictionary:
	for index: int in range(_events.size() - 1, -1, -1):
		if str(_events[index].get("player_id", "")) == player_id:
			return _events[index].duplicate(true)
	return {}
