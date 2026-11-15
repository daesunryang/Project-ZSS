class_name ZombieService
extends ServerSystem
## Server-authoritative common infected (docs/02 §6). System id "zombie";
## registered by ServerComposition after "survival" and "noise", which it
## uses through `world.get_system(...)`. No networking here.
##
## Public API:
##   spawn_zombie(world, position, yaw = 0.0) -> ActionResult
##   apply_damage_to_zombie(zombie_id, amount, source_id) -> ActionResult
##   has_zombie(id), get_zombie(id) -> ZombieState (read-only), zombie_ids(),
##   zombie_count(), living_count()
##   snapshot_rows() -> Array[Dictionary]   (network read surface)
##   drain_events() -> Array[Dictionary]    (network read surface)
##
## Cadence (CLAUDE.md §6): movement is integrated for every living zombie
## each server tick; the AI decision (sensing, state changes, attacks) runs
## once per `ai_period_sec` per zombie through a BucketScheduler, at most
## `max_ai_updates_per_tick` decisions per tick (the rest wait in a queue).
## Everything runs on world time, so nothing happens while the clock is
## paused.
##
## AI decision priority (one decision, highest first):
##   1. sight   - a living online player inside range and view cone:
##                chase, or attack when within attack range
##   2. damage  - it was hit by a player it cannot see: turn to the attacker
##                and investigate the attacker's position
##   3. sound   - the strongest new noise: investigate its position
##   4. memory  - lost a chased target: search the last known position
##   5. timers  - investigate -> search -> idle, idle wandering
## When sight and sound happen in the same decision, sight wins and the
## noise is discarded (it will not be investigated later).
##
## Events (drain_events; every event has event_type, zombie_id, world_time;
## positions are [x, y, z] arrays, all values JSON-safe):
##   zombie_spawned        {position, yaw}
##   zombie_detected       {sense: "sight"|"sound"|"damage", target_id, position}
##   zombie_state_changed  {from, to, cause, target_id}
##   zombie_attacked       {target_id, wound_type, body_part, damage,
##                          target_health_after, target_died, infection}
##   zombie_damaged        {source_id, damage, health_after, died}
##   zombie_died           {source_id}
##   zombie_removed        {}
## `infection` is the survival result: "player_infected",
## "infection_exposure_resisted" or a failure reason such as
## "already_infected" / "player_dead".
## State change causes: sight, in_range, attacked, noise, target_lost,
## investigated, search_timeout.
##
## Failure reasons: bad_zombie_position, zombie_limit, zombie_id_failed,
## unknown_zombie, zombie_dead, bad_damage_amount, bad_damage_source.
##
## Save: world_state.json `systems.zombie` =
##   {schema_version, rng_seed, rng_state, zombies: [ZombieState.to_dict()]}.
## Not saved: the AI queue and scheduler phase (after a load every zombie
## decides again within one AI period) and undrained events.

const SYSTEM_ID: String = "zombie"
const SCHEMA_VERSION: int = 1
const ENTITY_KIND_ZOMBIE: String = "zombie"

const EVENT_SPAWNED: String = "zombie_spawned"
const EVENT_DETECTED: String = "zombie_detected"
const EVENT_STATE_CHANGED: String = "zombie_state_changed"
const EVENT_ATTACKED: String = "zombie_attacked"
const EVENT_DAMAGED: String = "zombie_damaged"
const EVENT_DIED: String = "zombie_died"
const EVENT_REMOVED: String = "zombie_removed"

const SENSE_SIGHT: String = "sight"
const SENSE_SOUND: String = "sound"
const SENSE_DAMAGE: String = "damage"

const CAUSE_SIGHT: String = "sight"
const CAUSE_IN_RANGE: String = "in_range"
const CAUSE_ATTACKED: String = "attacked"
const CAUSE_NOISE: String = "noise"
const CAUSE_TARGET_LOST: String = "target_lost"
const CAUSE_INVESTIGATED: String = "investigated"
const CAUSE_SEARCH_TIMEOUT: String = "search_timeout"

const REASON_BAD_POSITION: String = "bad_zombie_position"
const REASON_LIMIT: String = "zombie_limit"
const REASON_ID_FAILED: String = "zombie_id_failed"
const REASON_UNKNOWN_ZOMBIE: String = "unknown_zombie"
const REASON_ZOMBIE_DEAD: String = "zombie_dead"
const REASON_BAD_AMOUNT: String = "bad_damage_amount"
const REASON_BAD_SOURCE: String = "bad_damage_source"

## World time is a sum of tick lengths. A deadline computed as "an earlier
## now + duration" can therefore be a few ulps later than the clock of the
## tick it is meant for; an attack whose deadline is this close counts as
## ready (otherwise it waits one whole AI period longer).
const TIME_EPSILON_SEC: float = 0.000001

## Diagnostics (tests / profiling).
var last_ai_update_count: int = 0
var total_ai_update_count: int = 0
var dropped_event_count: int = 0

var _settings: ZombieSettings
var _ids: EntityIdGenerator
var _registry: EntityRegistry
var _clock: WorldClock
## Insertion order = spawn order = save order (deterministic iteration).
var _zombies: Dictionary[String, ZombieState] = {}
var _scheduler: BucketScheduler
## Zombies waiting for their AI decision, in due order.
var _ai_queue: Array[String] = []
var _ai_queued: Dictionary[String, bool] = {}
var _events: Array[Dictionary] = []
## Placement RNG (dev seeding, future spawners). State is saved.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init(settings: ZombieSettings, ids: EntityIdGenerator, registry: EntityRegistry, clock: WorldClock) -> void:
	_settings = settings
	_ids = ids
	_registry = registry
	_clock = clock
	_scheduler = BucketScheduler.new(settings.ai_period_sec, settings.ai_bucket_count)
	_rng.seed = settings.rng_seed


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ public API

## Creates a zombie at `position` (clamped into the world) facing `yaw`.
## Success event: zombie_spawned. Fails on non-finite input or when
## `max_active_zombies` is reached.
func spawn_zombie(world: ServerWorld, position: Vector3, yaw: float = 0.0) -> ActionResult:
	if world == null or not position.is_finite() or not is_finite(yaw):
		return _reject("spawn_zombie", "", REASON_BAD_POSITION)
	if _zombies.size() >= _settings.max_active_zombies:
		return _reject("spawn_zombie", "", REASON_LIMIT)
	var zombie_id: String = _ids.next_id(ENTITY_KIND_ZOMBIE)
	if zombie_id.is_empty() or _registry.register(zombie_id, ENTITY_KIND_ZOMBIE) != OK:
		return _reject("spawn_zombie", zombie_id, REASON_ID_FAILED)
	var zombie: ZombieState = ZombieState.new()
	zombie.zombie_id = zombie_id
	zombie.position = world.clamp_to_world(position)
	zombie.yaw = wrapf(yaw, -PI, PI)
	zombie.health = _settings.max_health
	zombie.home_position = zombie.position
	zombie.focus_position = zombie.position
	zombie.move_target = zombie.position
	zombie.rng.seed = ("%d:%s" % [_settings.rng_seed, zombie_id]).hash()
	zombie.next_wander_at = _clock.world_time_sec + _wander_pause(zombie)
	_zombies[zombie_id] = zombie
	_scheduler.add(zombie_id)
	GameLogger.debug("zombie", "zombie spawned", {"entity_id": zombie_id, "x": zombie.position.x, "z": zombie.position.z})
	return ActionResult.success(_push_event(EVENT_SPAWNED, zombie_id, {
		"position": _to_array(zombie.position), "yaw": zombie.yaw,
	}))


## Applies server-computed damage to a zombie (called by combat). A living
## zombie notices `source_id` at its next AI decision. Success event:
##   {event_type: "zombie_damaged", zombie_id, source_id, damage,
##    health_after, died, world_time}
## Failure reasons: unknown_zombie, zombie_dead, bad_damage_amount (NaN,
## infinite, <= 0), bad_damage_source (empty).
func apply_damage_to_zombie(zombie_id: String, amount: float, source_id: String) -> ActionResult:
	var zombie: ZombieState = _zombies.get(zombie_id, null)
	if zombie == null:
		return _reject("apply_damage_to_zombie", zombie_id, REASON_UNKNOWN_ZOMBIE)
	if not zombie.is_alive():
		return _reject("apply_damage_to_zombie", zombie_id, REASON_ZOMBIE_DEAD)
	if not is_finite(amount) or amount <= 0.0:
		return _reject("apply_damage_to_zombie", zombie_id, REASON_BAD_AMOUNT)
	if source_id.is_empty():
		return _reject("apply_damage_to_zombie", zombie_id, REASON_BAD_SOURCE)
	zombie.health = maxf(zombie.health - amount, 0.0)
	var died: bool = zombie.health <= 0.0
	var event: Dictionary = _push_event(EVENT_DAMAGED, zombie_id, {
		"source_id": source_id, "damage": amount, "health_after": zombie.health, "died": died,
	})
	if died:
		_kill(zombie, source_id)
	else:
		zombie.alerted_by = source_id
		_queue_ai(zombie_id, true)
	GameLogger.info("zombie", "zombie damaged", {"entity_id": zombie_id, "source_id": source_id, "damage": amount, "health": zombie.health, "died": died})
	return ActionResult.success(event)


func has_zombie(zombie_id: String) -> bool:
	return _zombies.has(zombie_id)


## Read-only view of one zombie (null if unknown). Do not mutate.
func get_zombie(zombie_id: String) -> ZombieState:
	return _zombies.get(zombie_id, null)


## All zombie ids (corpses included) in spawn order.
func zombie_ids() -> PackedStringArray:
	return PackedStringArray(_zombies.keys())


func zombie_count() -> int:
	return _zombies.size()


func living_count() -> int:
	var count: int = 0
	for zombie_id: String in _zombies:
		if _zombies[zombie_id].is_alive():
			count += 1
	return count


## Replication rows for the network layer, in spawn order:
##   {id: String, position: Vector3, yaw: float, state: String,
##    health_fraction: float (0..1)}
## Corpses are listed with state "dead" until they are removed.
func snapshot_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for zombie_id: String in _zombies:
		var zombie: ZombieState = _zombies[zombie_id]
		rows.append({
			"id": zombie_id,
			"position": zombie.position,
			"yaw": zombie.yaw,
			"state": ZombieState.state_name(zombie.state),
			"health_fraction": clampf(zombie.health / _settings.max_health, 0.0, 1.0),
		})
	return rows


## Returns and clears the events recorded since the previous call (oldest
## first). At most `max_pending_events` are kept between calls.
func drain_events() -> Array[Dictionary]:
	var drained: Array[Dictionary] = _events
	_events = []
	return drained


# ------------------------------------------------------------ ServerSystem

## Places the development zombies deterministically (same settings seed ->
## same positions). Only runs for brand-new worlds (docs/15 P2-3).
func seed_new_world(world: ServerWorld) -> Error:
	for index: int in range(_settings.dev_spawn_count):
		var angle: float = _rng.randf() * TAU
		var radius: float = _rng.randf_range(_settings.dev_spawn_min_radius_m, _settings.dev_spawn_max_radius_m)
		var yaw: float = _rng.randf_range(-PI, PI)
		var position: Vector3 = _settings.dev_spawn_center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		var result: ActionResult = spawn_zombie(world, position, yaw)
		if not result.ok:
			GameLogger.error("zombie", "dev zombie could not be spawned", {"world_id": world.world_id, "reason": result.reason, "operation": "seed_world"})
			return ERR_CANT_CREATE
	GameLogger.info("zombie", "dev zombies seeded", {"world_id": world.world_id, "count": _settings.dev_spawn_count})
	return OK


func step(world: ServerWorld, _real_delta: float, world_delta: float) -> void:
	last_ai_update_count = 0
	if world_delta <= 0.0 or _zombies.is_empty():
		return
	var now: float = _clock.world_time_sec
	_remove_old_corpses(now)
	for zombie_id: String in _zombies:
		_move(world, _zombies[zombie_id], world_delta)
	for zombie_id: String in _scheduler.advance(world_delta):
		_queue_ai(zombie_id, false)
	if _ai_queue.is_empty():
		return
	var context: _Context = _Context.new()
	context.world = world
	context.now = now
	context.survival = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	context.noise = world.get_system(NoiseService.SYSTEM_ID) as NoiseService
	context.online_ids = world.online_player_ids()
	while not _ai_queue.is_empty() and last_ai_update_count < _settings.max_ai_updates_per_tick:
		var zombie_id: String = _ai_queue.pop_front()
		_ai_queued.erase(zombie_id)
		var zombie: ZombieState = _zombies.get(zombie_id, null)
		if zombie == null or not zombie.is_alive() or zombie.state == ZombieState.State.DORMANT:
			continue
		_think(context, zombie)
		last_ai_update_count += 1
	total_ai_update_count += last_ai_update_count


func to_world_document() -> Dictionary:
	var zombies: Array[Dictionary] = []
	for zombie_id: String in _zombies:
		zombies.append(_zombies[zombie_id].to_dict())
	return {
		"schema_version": SCHEMA_VERSION,
		# 64-bit values are stored as strings: JSON numbers would lose precision.
		"rng_seed": str(_rng.seed),
		"rng_state": str(_rng.state),
		"zombies": zombies,
	}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != SCHEMA_VERSION:
		errors.append("zombie: unsupported schema_version")
		return errors
	var seed_text: String = str(document.get("rng_seed", ""))
	var state_text: String = str(document.get("rng_state", ""))
	if not seed_text.is_valid_int() or not state_text.is_valid_int():
		errors.append("zombie: invalid rng seed/state")
	var entries: Variant = document.get("zombies", null)
	if typeof(entries) != TYPE_ARRAY:
		errors.append("zombie: zombies must be an array")
		return errors
	var restored: Array[ZombieState] = []
	var seen: Dictionary[String, bool] = {}
	for entry: Variant in (entries as Array):
		var zombie: ZombieState = ZombieState.from_dict(entry as Dictionary, _settings.max_health) if typeof(entry) == TYPE_DICTIONARY else null
		if zombie == null:
			errors.append("zombie: invalid zombie entry")
			continue
		if seen.has(zombie.zombie_id) or _registry.has(zombie.zombie_id) or _registry.is_tombstoned(zombie.zombie_id):
			errors.append("zombie: duplicate or removed id " + zombie.zombie_id)
			continue
		seen[zombie.zombie_id] = true
		restored.append(zombie)
	if not errors.is_empty():
		return errors
	_rng.seed = seed_text.to_int()
	_rng.state = state_text.to_int()
	for zombie: ZombieState in restored:
		_registry.register(zombie.zombie_id, ENTITY_KIND_ZOMBIE)
		_ids.reserve_existing_id(zombie.zombie_id)
		_zombies[zombie.zombie_id] = zombie
		if zombie.is_alive():
			_scheduler.add(zombie.zombie_id)
	return errors


# ------------------------------------------------------------ AI decision

## One AI decision for one living zombie (see the priority list above).
func _think(context: _Context, zombie: ZombieState) -> void:
	var alert_id: String = ""
	var alert_position: Vector3 = Vector3.ZERO
	if not zombie.alerted_by.is_empty():
		if _is_valid_target(context, zombie.alerted_by):
			alert_id = zombie.alerted_by
			alert_position = context.world.get_player(alert_id).position
			_face(zombie, alert_position)
		zombie.alerted_by = ""
	var seen_id: String = _visible_target(context, zombie)
	if not seen_id.is_empty():
		_on_target_seen(context, zombie, seen_id)
		return
	var had_target: bool = zombie.state == ZombieState.State.CHASE or zombie.state == ZombieState.State.ATTACK
	zombie.target_visible = false
	if not alert_id.is_empty():
		_push_event(EVENT_DETECTED, zombie.zombie_id, {"sense": SENSE_DAMAGE, "target_id": alert_id, "position": _to_array(alert_position)})
		_begin_investigate(context, zombie, alert_position, alert_id, CAUSE_ATTACKED)
		return
	var heard: NoisePerception = _strongest_new_noise(context, zombie)
	if heard != null:
		_push_event(EVENT_DETECTED, zombie.zombie_id, {"sense": SENSE_SOUND, "target_id": heard.event.source_id, "position": _to_array(heard.event.position)})
		_begin_investigate(context, zombie, heard.event.position, "", CAUSE_NOISE)
		return
	if had_target:
		_begin_search(context, zombie, CAUSE_TARGET_LOST)
		return
	match zombie.state:
		ZombieState.State.INVESTIGATE:
			if context.now >= zombie.state_until or ZombiePerception.flat_distance(zombie.position, zombie.focus_position) <= _settings.arrive_radius_m:
				_begin_search(context, zombie, CAUSE_INVESTIGATED)
		ZombieState.State.SEARCH:
			if context.now >= zombie.state_until:
				_become_idle(context, zombie)
			elif not zombie.has_move_target:
				_set_waypoint(context, zombie, zombie.focus_position, _settings.search_radius_m)
		ZombieState.State.IDLE:
			if not zombie.has_move_target and context.now >= zombie.next_wander_at:
				_set_waypoint(context, zombie, zombie.home_position, _settings.wander_radius_m)
				var travel_sec: float = 0.0
				if _settings.wander_speed_mps > 0.0:
					travel_sec = ZombiePerception.flat_distance(zombie.position, zombie.move_target) / _settings.wander_speed_mps
				zombie.next_wander_at = context.now + travel_sec + _wander_pause(zombie)


func _on_target_seen(context: _Context, zombie: ZombieState, target_id: String) -> void:
	var target_position: Vector3 = context.world.get_player(target_id).position
	var engaged: bool = zombie.state == ZombieState.State.CHASE or zombie.state == ZombieState.State.ATTACK
	if not engaged or not zombie.target_visible or zombie.target_player_id != target_id:
		_push_event(EVENT_DETECTED, zombie.zombie_id, {"sense": SENSE_SIGHT, "target_id": target_id, "position": _to_array(target_position)})
	zombie.target_player_id = target_id
	zombie.target_visible = true
	zombie.focus_position = target_position
	zombie.has_move_target = false
	# Sight beats sound: noises up to now are not investigated later.
	zombie.last_noise_time = context.now
	if ZombiePerception.flat_distance(zombie.position, target_position) > _settings.attack_range_m:
		_set_state(context, zombie, ZombieState.State.CHASE, CAUSE_SIGHT)
		return
	if zombie.state != ZombieState.State.ATTACK:
		zombie.attack_ready_at = maxf(zombie.attack_ready_at, context.now + _settings.attack_windup_sec)
		_set_state(context, zombie, ZombieState.State.ATTACK, CAUSE_IN_RANGE)
	_face(zombie, target_position)
	if context.now + TIME_EPSILON_SEC >= zombie.attack_ready_at:
		_attack(context, zombie, target_id)


## Builds the DamageInput on the server and hands it to survival; the
## zombie never writes player health itself.
func _attack(context: _Context, zombie: ZombieState, target_id: String) -> void:
	zombie.attack_ready_at = context.now + _settings.attack_cooldown_sec
	if context.survival == null:
		return
	var is_bite: bool = zombie.rng.randf() < _settings.bite_chance
	var part_name: String = _settings.attack_body_parts[zombie.rng.randi_range(0, _settings.attack_body_parts.size() - 1)]
	var wound_type: Wound.Type = Wound.Type.BITE if is_bite else Wound.Type.SCRATCH
	var amount: float = _settings.bite_damage if is_bite else _settings.scratch_damage
	var damage: DamageInput = DamageInput.create(zombie.zombie_id, BodyPart.from_name(part_name) as BodyPart.Part, wound_type, amount)
	var hit: ActionResult = context.survival.apply_damage(target_id, damage)
	if not hit.ok:
		GameLogger.warning("zombie", "attack rejected by survival", {"entity_id": zombie.zombie_id, "player_id": target_id, "reason": hit.reason, "operation": "attack"})
		return
	var exposure: InfectionState.Exposure = InfectionState.Exposure.BITE if is_bite else InfectionState.Exposure.SCRATCH
	var infection: ActionResult = context.survival.apply_infection_exposure(target_id, exposure, zombie.zombie_id)
	_push_event(EVENT_ATTACKED, zombie.zombie_id, {
		"target_id": target_id,
		"wound_type": Wound.type_name(wound_type),
		"body_part": part_name,
		"damage": amount,
		"target_health_after": float(hit.event["health_after"]),
		"target_died": bool(hit.event["died"]),
		"infection": str(infection.event["event_type"]) if infection.ok else infection.reason,
	})


## Nearest visible living online player ("" = none). The current target is
## kept while it stays visible; ties resolve by player id order.
func _visible_target(context: _Context, zombie: ZombieState) -> String:
	var range_m: float = _settings.effective_sight_range_m()
	var half_angle: float = deg_to_rad(_settings.sight_half_angle_deg)
	var best_id: String = ""
	var best_distance: float = INF
	for player_id: String in context.online_ids:
		if not _is_valid_target(context, player_id):
			continue
		var player_position: Vector3 = context.world.get_player(player_id).position
		if not ZombiePerception.can_see(zombie.position, zombie.yaw, player_position, range_m, half_angle):
			continue
		if player_id == zombie.target_player_id:
			return player_id
		var distance: float = ZombiePerception.flat_distance(zombie.position, player_position)
		if distance < best_distance:
			best_distance = distance
			best_id = player_id
	return best_id


## Only living, online players can be sensed or attacked.
func _is_valid_target(context: _Context, player_id: String) -> bool:
	if not context.world.is_online(player_id) or context.world.get_player(player_id) == null:
		return false
	return context.survival == null or context.survival.is_alive(player_id)


## Strongest noise newer than the last one this zombie reacted to (null =
## none). Its own noises are ignored. Marks everything heard as handled.
func _strongest_new_noise(context: _Context, zombie: ZombieState) -> NoisePerception:
	if context.noise == null:
		return null
	var strongest: NoisePerception = null
	for perception: NoisePerception in context.noise.query_audible(zombie.position, _settings.hearing_multiplier, zombie.last_noise_time):
		zombie.last_noise_time = maxf(zombie.last_noise_time, perception.event.event_time)
		if strongest == null and perception.event.source_id != zombie.zombie_id:
			strongest = perception
	return strongest


func _begin_investigate(context: _Context, zombie: ZombieState, position: Vector3, target_id: String, cause: String) -> void:
	zombie.target_player_id = target_id
	zombie.focus_position = context.world.clamp_to_world(position)
	zombie.has_move_target = false
	zombie.state_until = context.now + _settings.investigate_timeout_sec
	_set_state(context, zombie, ZombieState.State.INVESTIGATE, cause)


## Search around focus_position: walk to it first, then to random points.
func _begin_search(context: _Context, zombie: ZombieState, cause: String) -> void:
	zombie.target_player_id = ""
	zombie.target_visible = false
	zombie.move_target = zombie.focus_position
	zombie.has_move_target = true
	zombie.state_until = context.now + _settings.search_duration_sec
	_set_state(context, zombie, ZombieState.State.SEARCH, cause)


## Back to idle; the zombie stays where it ended up (new home point).
func _become_idle(context: _Context, zombie: ZombieState) -> void:
	zombie.home_position = zombie.position
	zombie.has_move_target = false
	zombie.next_wander_at = context.now + _wander_pause(zombie)
	_set_state(context, zombie, ZombieState.State.IDLE, CAUSE_SEARCH_TIMEOUT)


## Random waypoint within `radius` of `center` (uniform over the disc).
func _set_waypoint(context: _Context, zombie: ZombieState, center: Vector3, radius: float) -> void:
	var angle: float = zombie.rng.randf() * TAU
	var distance: float = sqrt(zombie.rng.randf()) * radius
	zombie.move_target = context.world.clamp_to_world(center + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance))
	zombie.has_move_target = true


func _wander_pause(zombie: ZombieState) -> float:
	return zombie.rng.randf_range(_settings.wander_pause_min_sec, _settings.wander_pause_max_sec)


func _set_state(context: _Context, zombie: ZombieState, next: ZombieState.State, cause: String) -> void:
	if zombie.state == next:
		return
	var previous: ZombieState.State = zombie.state
	zombie.state = next
	_push_event(EVENT_STATE_CHANGED, zombie.zombie_id, {
		"from": ZombieState.state_name(previous), "to": ZombieState.state_name(next),
		"cause": cause, "target_id": zombie.target_player_id,
	})
	GameLogger.debug("zombie", "state changed", {"entity_id": zombie.zombie_id, "from": ZombieState.state_name(previous), "to": ZombieState.state_name(next), "cause": cause, "world_time": context.now})


# ------------------------------------------------------------ movement

## Straight-line movement towards the current goal (no navigation mesh or
## obstacles yet, docs/15 P2-26). Runs every tick for living zombies.
func _move(world: ServerWorld, zombie: ZombieState, world_delta: float) -> void:
	var goal: Vector3
	var speed: float
	var stop_distance: float = 0.0
	match zombie.state:
		ZombieState.State.IDLE:
			if not zombie.has_move_target:
				return
			goal = zombie.move_target
			speed = _settings.wander_speed_mps
		ZombieState.State.SEARCH:
			if not zombie.has_move_target:
				return
			goal = zombie.move_target
			speed = _settings.search_speed_mps
		ZombieState.State.INVESTIGATE:
			goal = zombie.focus_position
			speed = _settings.investigate_speed_mps
		ZombieState.State.CHASE:
			goal = _tracked_target_position(world, zombie)
			speed = _settings.chase_speed_mps
			stop_distance = _settings.chase_stop_distance_m
		ZombieState.State.ATTACK:
			_face(zombie, _tracked_target_position(world, zombie))
			return
		_:
			return
	var offset: Vector3 = Vector3(goal.x - zombie.position.x, 0.0, goal.z - zombie.position.z)
	var distance: float = offset.length()
	if distance <= maxf(stop_distance, _settings.arrive_radius_m):
		if zombie.state == ZombieState.State.IDLE or zombie.state == ZombieState.State.SEARCH:
			zombie.has_move_target = false
		elif zombie.state == ZombieState.State.CHASE:
			_face(zombie, goal)
		return
	var direction: Vector3 = offset / distance
	var travel: float = minf(speed * world_delta, distance - stop_distance)
	zombie.position = world.clamp_to_world(zombie.position + direction * travel)
	zombie.yaw = ZombiePerception.yaw_towards(direction, zombie.yaw)


## Live position of a target that was visible at the last AI decision,
## otherwise the last known position.
func _tracked_target_position(world: ServerWorld, zombie: ZombieState) -> Vector3:
	if zombie.target_visible and world.is_online(zombie.target_player_id):
		var player: PlayerState = world.get_player(zombie.target_player_id)
		if player != null:
			return player.position
	return zombie.focus_position


func _face(zombie: ZombieState, point: Vector3) -> void:
	zombie.yaw = ZombiePerception.yaw_towards(point - zombie.position, zombie.yaw)


# ------------------------------------------------------------ internals

func _kill(zombie: ZombieState, source_id: String) -> void:
	zombie.state = ZombieState.State.DEAD
	zombie.died_at = _clock.world_time_sec
	zombie.target_player_id = ""
	zombie.target_visible = false
	zombie.has_move_target = false
	zombie.alerted_by = ""
	_scheduler.remove(zombie.zombie_id)
	_push_event(EVENT_DIED, zombie.zombie_id, {"source_id": source_id})


## Removes corpses older than corpse_remove_delay_sec and tombstones
## their ids (never reused).
func _remove_old_corpses(now: float) -> void:
	var expired: PackedStringArray = []
	for zombie_id: String in _zombies:
		var zombie: ZombieState = _zombies[zombie_id]
		if not zombie.is_alive() and now - zombie.died_at >= _settings.corpse_remove_delay_sec:
			expired.append(zombie_id)
	for zombie_id: String in expired:
		_zombies.erase(zombie_id)
		_scheduler.remove(zombie_id)
		_registry.remove(zombie_id)
		_push_event(EVENT_REMOVED, zombie_id, {})
		GameLogger.debug("zombie", "corpse removed", {"entity_id": zombie_id})


## Queues one AI decision (once per zombie). `urgent` = decide first.
func _queue_ai(zombie_id: String, urgent: bool) -> void:
	if _ai_queued.has(zombie_id):
		if not urgent:
			return
		_ai_queue.erase(zombie_id)
	_ai_queued[zombie_id] = true
	if urgent:
		_ai_queue.push_front(zombie_id)
	else:
		_ai_queue.append(zombie_id)


func _push_event(event_type: String, zombie_id: String, fields: Dictionary) -> Dictionary:
	var event: Dictionary = {"event_type": event_type, "zombie_id": zombie_id, "world_time": _clock.world_time_sec}
	event.merge(fields)
	_events.append(event)
	while _events.size() > _settings.max_pending_events:
		_events.pop_front()
		dropped_event_count += 1
	return event


func _reject(operation: String, zombie_id: String, reason: String) -> ActionResult:
	GameLogger.warning("zombie", "request rejected", {"entity_id": zombie_id, "reason": reason, "operation": operation})
	return ActionResult.failure(reason)


static func _to_array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


## Per-step lookups shared by all AI decisions of one tick.
class _Context extends RefCounted:
	var world: ServerWorld = null
	var survival: SurvivalService = null
	var noise: NoiseService = null
	var online_ids: PackedStringArray = []
	var now: float = 0.0
