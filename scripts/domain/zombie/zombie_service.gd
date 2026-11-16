class_name ZombieService
extends ServerSystem
## Server-authoritative common infected (docs/02 §6). System id "zombie";
## registered by ServerComposition after "survival" and "noise", which it
## uses through `world.get_system(...)`. Navigation is registered later and
## queried at movement time through its system id. No networking here.
##
## Public API:
##   spawn_zombie(world, position, yaw = 0.0) -> ActionResult
##   apply_damage_to_zombie(zombie_id, amount, source_id) -> ActionResult
##   has_zombie(id), get_zombie(id) -> ZombieState (read-only), zombie_ids(),
##   zombie_count(), living_count()
##   snapshot_rows() -> Array[Dictionary]   (network read surface)
##   drain_events() -> Array[Dictionary]    (network read surface)
##   on_player_died(world, player_id, cause, infection_stage)
##       hook for SurvivalService.player_died, connected by ServerComposition
##
## Player zombies (P2-T5, docs/00 ADR-008, docs/09 §14.20): a player whose
## death matches ZombieSettings.player_death_zombie_rule (default: the
## infection killed it) leaves one ordinary zombie at the place and facing
## of the death. It is spawned like any other zombie (same id series, same
## "zombie_spawned" event, saved with the others) and nothing in its state or
## events says which player it was. At `max_active_zombies` the spawn is
## skipped, logged and counted; it is not retried. A death reported while
## this system is inside its own step (a zombie killed the player) is
## spawned at the end of that step.
##
## Cadence (CLAUDE.md §6): movement is integrated for every living zombie
## each server tick; the AI decision (sensing, state changes, attacks) runs
## once per `ai_period_sec` per zombie through a BucketScheduler, at most
## `max_ai_updates_per_tick` decisions per tick (the rest wait in a queue).
## Everything runs on action time (WorldClock.action_time_sec, real seconds,
## docs/09 §14.16): speeds are metres per real second and every duration,
## cooldown and deadline is real seconds, whatever the calendar time scale.
## Nothing happens while the clock is paused. Only the `world_time` field of
## events is calendar time (WorldClock.world_time_sec), like the events of
## every other system.
##
## AI decision priority (one decision, highest first):
##   1. sight   - a living online player inside range and view cone:
##                chase, or attack when within attack range. The range
##                towards a player is the sight range times that player's
##                visibility (P2-T11, docs/09 §14.26: posture and movement,
##                asked from ServerWorld.player_visibility_multiplier; see
##                _sight_range_to for the target being chased)
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
## World cells (P3-1, docs/03 §3.2, docs/09 §15.1). Every zombie in memory
## is in ServerWorld.cell_index (kind "zombie") under the cell of its
## position; the index follows a zombie that crosses a border. Only zombies
## in ACTIVE cells are "awake": movement, AI decisions (sight, hearing,
## attacks) and corpse removal run for them alone, so the cost of a tick
## follows the active area, not the world. A zombie in a cell that is only
## in memory is frozen exactly as it is and goes on when its cell becomes
## active. In a world without a cell service every zombie is awake.
##   - A zombie that walks from an active cell into a cell that is in
##     memory but not active crosses the border and freezes there. It never
##     enters a cell that is not in memory: that step is refused and it
##     stays where it is (`blocked_move_count`).
##   - Noise is heard by awake zombies only. A zombie that wakes does not
##     hear what rang before it woke, even if that noise is still audible:
##     a noise that reaches into a non-active cell is lost there.
##   - Server rules can still damage a frozen zombie; it notices its
##     attacker when it wakes.
##   - A cell's zombies leave memory and come back unchanged through
##     to_cell_document / restore_cell_document / release_cell. No event is
##     recorded for that (ZombieNetModule tells clients).
##
## Save: world_state.json `systems.zombie` =
##   {schema_version, rng_seed, rng_state, zombies: [ZombieState.to_dict()]}
## and, per cell document, `systems.zombie` =
##   {schema_version, zombies: [ZombieState.to_dict()]}.
## Not saved: the AI queue and scheduler phase (after a load every zombie
## decides again within one AI period) and undrained events.

const SYSTEM_ID: String = "zombie"
const SCHEMA_VERSION: int = 1
## Version of this system's part of a cell document (P3-1).
const CELL_SCHEMA_VERSION: int = 1
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

## Action time is a sum of tick lengths. A deadline computed as "an earlier
## now + duration" can therefore be a few ulps later than the clock of the
## tick it is meant for; an attack whose deadline is this close counts as
## ready (otherwise it waits one whole AI period longer).
const TIME_EPSILON_SEC: float = 0.000001

## Diagnostics (tests / profiling).
var last_ai_update_count: int = 0
var total_ai_update_count: int = 0
var dropped_event_count: int = 0
## Zombies spawned where a player died / such spawns skipped (zombie limit
## or another spawn failure). Since the server started; not saved.
var player_zombie_count: int = 0
var skipped_player_zombie_count: int = 0
## Steps refused because the zombie would have entered a cell that is not
## in memory (P3-1). Since the server started; not saved.
var blocked_move_count: int = 0
## Steps that ended short of where the zombie was heading because something
## stood in the way (P3-4a: ServerWorld.resolve_movement). Since the server
## started; not saved.
var obstructed_move_count: int = 0
## Search slices processed in the last tick, and new searches started since
## server start. Node/time values are diagnostics and never game decisions.
var last_plan_count: int = 0
var total_plan_count: int = 0
var last_plan_node_count: int = 0
var last_plan_msec: float = 0.0
var last_step_msec: float = 0.0
var _plan_counts_by_zombie: Dictionary[String, int] = {}
var _search_restart_counts_by_zombie: Dictionary[String, int] = {}
var _search_completion_counts_by_zombie: Dictionary[String, int] = {}
var _last_completed_search_nodes_by_zombie: Dictionary[String, int] = {}

var _settings: ZombieSettings
var _ids: EntityIdGenerator
var _registry: EntityRegistry
var _clock: WorldClock
## The world this system is registered with (weak: the world owns it).
var _world_ref: WeakRef = null
## Zombies in memory. Insertion order = the order they were spawned or
## loaded = save order (deterministic iteration).
var _zombies: Dictionary[String, ZombieState] = {}
## Zombies in ACTIVE cells (alive or corpses): the only ones that are
## stepped (P3-1).
var _awake: Dictionary[String, bool] = {}
## zombie_id -> cell coordinates of its position (to notice a border
## crossing without building a cell id every tick).
var _zombie_cells: Dictionary[String, Vector2i] = {}
## Zombies that walked into a non-active cell during this step.
var _falling_asleep: PackedStringArray = []
var _scheduler: BucketScheduler
## Zombies waiting for their AI decision, in due order.
var _ai_queue: Array[String] = []
var _ai_queued: Dictionary[String, bool] = {}
var _events: Array[Dictionary] = []
## Placement RNG (dev seeding, future spawners). State is saved.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
## True while step() runs: a player zombie requested then waits in
## `_pending_player_zombies` ({player_id, position, yaw}) until the step is
## over, so the step never changes the zombie set it is working on.
var _stepping: bool = false
var _pending_player_zombies: Array[Dictionary] = []
## Ephemeral paths, resumable searches and planning deadlines. They are not
## saved: a loaded zombie plans against structures currently in memory.
var _navigation_states: Dictionary[String, _NavigationState] = {}
## FIFO planning requests survive tick boundaries. A dictionary prevents a
## zombie from occupying more than one queue slot while its goal is updated.
var _navigation_plan_queue: Array[String] = []
var _navigation_plan_goals: Dictionary[String, Vector3] = {}


class _NavigationState extends RefCounted:
	var waypoints: Array[Vector3] = []
	var waypoint_index: int = 0
	var planned_goal: Vector3 = Vector3.ZERO
	var expires_at: float = 0.0
	var next_plan_at: float = 0.0
	var waiting_for_plan: bool = false
	var search: GridPathSearch
	var search_goal: Vector3 = Vector3.ZERO
	var search_blocking_edge_count: int = 0

	func has_path() -> bool:
		return waypoint_index < waypoints.size()

	func clear_path() -> void:
		waypoints.clear()
		waypoint_index = 0


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
	zombie.next_wander_at = _clock.action_time_sec + _wander_pause(zombie)
	_zombies[zombie_id] = zombie
	_place(world, zombie)
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
		# A frozen zombie notices its attacker when its cell is simulated.
		if _awake.has(zombie_id):
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


## Zombies that are stepped now: those in ACTIVE cells (P3-1).
func simulated_count() -> int:
	return _awake.size()


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

func on_registered(world: ServerWorld) -> void:
	_world_ref = weakref(world)


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


func step(world: ServerWorld, action_delta: float, _world_delta: float) -> void:
	var started_usec: int = Time.get_ticks_usec()
	last_ai_update_count = 0
	last_plan_count = 0
	last_plan_node_count = 0
	last_plan_msec = 0.0
	_stepping = true
	_step_zombies(world, action_delta)
	_stepping = false
	_spawn_pending_player_zombies(world)
	last_step_msec = float(Time.get_ticks_usec() - started_usec) / 1000.0


## Hook for SurvivalService.player_died (ServerComposition connects it;
## docs/00 ADR-008). Leaves one zombie where the player died when the death
## matches ZombieSettings.player_death_zombie_rule. Survival does not know
## this system; this system reads only the cause and the infection stage.
func on_player_died(world: ServerWorld, player_id: String, cause: String, infection_stage: InfectionState.Stage) -> void:
	if not _death_leaves_zombie(cause, infection_stage):
		return
	var player: PlayerState = world.get_player(player_id) if world != null else null
	if player == null:
		GameLogger.warning("zombie", "player zombie not spawned", {"player_id": player_id, "reason": ServerWorld.REASON_UNKNOWN_PLAYER, "operation": "on_player_died"})
		skipped_player_zombie_count += 1
		return
	var request: Dictionary = {"player_id": player_id, "position": player.position, "yaw": player.yaw}
	if _stepping:
		_pending_player_zombies.append(request)
		return
	_spawn_player_zombie(world, request)


## True when a death with this cause / infection stage leaves a zombie under
## the configured rule.
func _death_leaves_zombie(cause: String, infection_stage: InfectionState.Stage) -> bool:
	match _settings.player_death_zombie_rule:
		ZombieSettings.PlayerDeathZombieRule.INFECTION_DEATH:
			return SurvivalService.is_infection_death(cause)
		ZombieSettings.PlayerDeathZombieRule.INFECTED_AT_DEATH:
			return infection_stage != InfectionState.Stage.NONE or SurvivalService.is_infection_death(cause)
	return false


func _spawn_pending_player_zombies(world: ServerWorld) -> void:
	if _pending_player_zombies.is_empty():
		return
	var requests: Array[Dictionary] = _pending_player_zombies
	_pending_player_zombies = []
	for request: Dictionary in requests:
		_spawn_player_zombie(world, request)


## Spawns the zombie of one dead player. A refused spawn (zombie limit) is
## skipped for good: logged and counted, never retried.
func _spawn_player_zombie(world: ServerWorld, request: Dictionary) -> void:
	var player_id: String = str(request["player_id"])
	var result: ActionResult = spawn_zombie(world, request["position"] as Vector3, float(request["yaw"]))
	if not result.ok:
		skipped_player_zombie_count += 1
		GameLogger.warning("zombie", "player zombie not spawned", {"player_id": player_id, "reason": result.reason, "operation": "spawn_player_zombie"})
		return
	player_zombie_count += 1
	# Server log only: clients are never told which player a zombie was.
	GameLogger.info("zombie", "player zombie spawned", {"entity_id": str(result.event.get("zombie_id", "")), "player_id": player_id})


## One tick of movement and AI decisions for the zombies in ACTIVE cells
## (P3-1): zombies in other cells are not looked at.
func _step_zombies(world: ServerWorld, action_delta: float) -> void:
	if action_delta <= 0.0 or _awake.is_empty():
		return
	var now: float = _clock.action_time_sec
	_remove_old_corpses(now)
	for zombie_id: String in _awake:
		_move(world, _zombies[zombie_id], action_delta)
	_drain_navigation_plans(world)
	for zombie_id: String in _falling_asleep:
		_sleep(zombie_id)
	_falling_asleep.clear()
	for zombie_id: String in _scheduler.advance(action_delta):
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
		if zombie == null or not zombie.is_alive() or zombie.state == ZombieState.State.DORMANT or not _awake.has(zombie_id):
			continue
		_think(context, zombie)
		last_ai_update_count += 1
	total_ai_update_count += last_ai_update_count


## `zombies` holds the zombies that are NOT saved with a cell document
## (P3-1): all of them in a world without a saved cell store, and in saves
## written before cells existed; normally none on a dedicated server.
func to_world_document() -> Dictionary:
	var world: ServerWorld = _world()
	var zombies: Array[Dictionary] = []
	for zombie_id: String in _zombies:
		if world != null and world.saves_cell_document(world.cell_index.cell_of(zombie_id)):
			continue
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
	var world: ServerWorld = _world()
	for zombie: ZombieState in restored:
		_registry.register(zombie.zombie_id, ENTITY_KIND_ZOMBIE)
		_ids.reserve_existing_id(zombie.zombie_id)
		_zombies[zombie.zombie_id] = zombie
		_place(world, zombie)
	return errors


# ------------------------------------------------------------ world cells

## The cell became ACTIVE: its zombies are stepped from now on. They do not
## hear what rang before they woke (see the header).
func on_cell_activated(world: ServerWorld, cell_id: String) -> void:
	for zombie_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_ZOMBIE):
		var zombie: ZombieState = _zombies.get(zombie_id, null)
		if zombie == null:
			continue
		zombie.last_noise_time = maxf(zombie.last_noise_time, _clock.action_time_sec)
		_wake(zombie)


## The cell is no longer ACTIVE: its zombies freeze as they are.
func on_cell_deactivated(world: ServerWorld, cell_id: String) -> void:
	for zombie_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_ZOMBIE):
		_sleep(zombie_id)


## The zombies of one cell as save data ({} = none), sorted by id.
func to_cell_document(cell_id: String) -> Dictionary:
	var world: ServerWorld = _world()
	if world == null:
		return {}
	var zombies: Array[Dictionary] = []
	for zombie_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_ZOMBIE):
		if _zombies.has(zombie_id):
			zombies.append(_zombies[zombie_id].to_dict())
	if zombies.is_empty():
		return {}
	return {"schema_version": CELL_SCHEMA_VERSION, "zombies": zombies}


## Brings the saved zombies of a cell back, exactly as they were saved (ids,
## positions, state, health, timers, RNG). Validates first: on any error
## nothing changes. A zombie that is already in memory wins over its saved
## copy, and a zombie whose id was retired stays gone (both are skipped and
## logged; this only happens when a cell file is older than the rest of the
## save).
func restore_cell_document(world: ServerWorld, cell_id: String, document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != CELL_SCHEMA_VERSION:
		errors.append("zombie: cell %s: unsupported schema_version" % cell_id)
		return errors
	var entries: Variant = document.get("zombies", null)
	if typeof(entries) != TYPE_ARRAY:
		errors.append("zombie: cell %s: zombies must be an array" % cell_id)
		return errors
	var restored: Array[ZombieState] = []
	var seen: Dictionary[String, bool] = {}
	var skipped: PackedStringArray = []
	for entry: Variant in (entries as Array):
		var zombie: ZombieState = ZombieState.from_dict(entry as Dictionary, _settings.max_health) if typeof(entry) == TYPE_DICTIONARY else null
		if zombie == null:
			errors.append("zombie: cell %s: invalid zombie entry" % cell_id)
			continue
		if seen.has(zombie.zombie_id):
			errors.append("zombie: cell %s: duplicate id %s" % [cell_id, zombie.zombie_id])
			continue
		seen[zombie.zombie_id] = true
		if _zombies.has(zombie.zombie_id) or _registry.has(zombie.zombie_id) or _registry.is_tombstoned(zombie.zombie_id):
			skipped.append(zombie.zombie_id)
			continue
		restored.append(zombie)
	if not errors.is_empty():
		return errors
	if not skipped.is_empty():
		GameLogger.warning("zombie", "saved zombies skipped: already in memory or removed", {"cell_id": cell_id, "zombies": ", ".join(skipped), "operation": "restore_cell"})
	for zombie: ZombieState in restored:
		_registry.register(zombie.zombie_id, ENTITY_KIND_ZOMBIE)
		_ids.reserve_existing_id(zombie.zombie_id)
		_zombies[zombie.zombie_id] = zombie
		_place(world, zombie)
	return errors


## Forgets the zombies of a cell (it was saved). Their ids are released,
## not retired: they still exist.
func release_cell(world: ServerWorld, cell_id: String) -> void:
	for zombie_id: String in world.cell_index.entities_in_cell(cell_id, ENTITY_KIND_ZOMBIE):
		_sleep(zombie_id)
		_zombies.erase(zombie_id)
		_navigation_states.erase(zombie_id)
		_zombie_cells.erase(zombie_id)
		world.cell_index.remove(zombie_id)
		_registry.release(zombie_id)


func _world() -> ServerWorld:
	return _world_ref.get_ref() as ServerWorld if _world_ref != null else null


## Records which cell a zombie that just came into memory is in and wakes
## it when that cell is simulated. Without a world (a service used on its
## own) every zombie is awake.
func _place(world: ServerWorld, zombie: ZombieState) -> void:
	if world == null:
		_wake(zombie)
		return
	var cell: Vector2i = world.cell_coords_at(zombie.position)
	var cell_id: String = world.cell_id_of(cell)
	_zombie_cells[zombie.zombie_id] = cell
	world.cell_index.put(zombie.zombie_id, ENTITY_KIND_ZOMBIE, cell_id)
	if world.is_cell_simulated(cell_id):
		_wake(zombie)
	else:
		_sleep(zombie.zombie_id)


## The zombie is stepped from now on; a living one decides once per period.
func _wake(zombie: ZombieState) -> void:
	_awake[zombie.zombie_id] = true
	if zombie.is_alive():
		_scheduler.add(zombie.zombie_id)


## The zombie is no longer stepped (frozen as it is).
func _sleep(zombie_id: String) -> void:
	_awake.erase(zombie_id)
	_scheduler.remove(zombie_id)
	if _ai_queued.erase(zombie_id):
		_ai_queue.erase(zombie_id)


## The zombie's position left the cell it was in. It may walk on into a cell
## that is in memory (it is frozen after this step when that cell is not
## active), but never into one that is not: then the step is undone.
func _cross_border(world: ServerWorld, zombie: ZombieState, previous: Vector3, cell: Vector2i) -> void:
	var cell_id: String = world.cell_id_of(cell)
	if not world.is_cell_loaded(cell_id):
		zombie.position = previous
		if zombie.state == ZombieState.State.IDLE or zombie.state == ZombieState.State.SEARCH:
			zombie.has_move_target = false
		blocked_move_count += 1
		return
	_zombie_cells[zombie.zombie_id] = cell
	world.cell_index.put(zombie.zombie_id, ENTITY_KIND_ZOMBIE, cell_id)
	if not world.is_cell_simulated(cell_id):
		_falling_asleep.append(zombie.zombie_id)


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
	var target: PlayerState = context.world.get_player(target_id)
	if target == null or context.world.is_line_blocked(zombie.position, target.position):
		return
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
## kept while it stays visible; ties resolve by player id order. The sight
## range towards each player is the zombie's range times that player's
## visibility (P2-T11, _sight_range_to).
func _visible_target(context: _Context, zombie: ZombieState) -> String:
	var half_angle: float = deg_to_rad(_settings.sight_half_angle_deg)
	var best_id: String = ""
	var best_distance: float = INF
	for player_id: String in context.online_ids:
		if not _is_valid_target(context, player_id):
			continue
		var player_position: Vector3 = context.world.get_player(player_id).position
		if not ZombiePerception.can_see(zombie.position, zombie.yaw, player_position, _sight_range_to(context, zombie, player_id), half_angle):
			continue
		if context.world.is_line_blocked(zombie.position, player_position):
			continue
		if player_id == zombie.target_player_id:
			return player_id
		var distance: float = ZombiePerception.flat_distance(zombie.position, player_position)
		if distance < best_distance:
			best_distance = distance
			best_id = player_id
	return best_id


## Distance at which this zombie can see `player_id` now (P2-T11): its sight
## range (with the light factor) times how visible the player is. The
## visibility is what the world's systems say (posture, movement:
## ServerWorld.player_visibility_multiplier); this system knows nothing about
## postures. The target the zombie is chasing or attacking and saw at its
## last decision is never less visible than
## ZombieSettings.tracked_target_min_visibility, so with the default (1.0)
## lying down in front of a zombie that already sees you does not hide you:
## the chase ends only out of its full range or view cone.
func _sight_range_to(context: _Context, zombie: ZombieState, player_id: String) -> float:
	var visibility: float = clampf(context.world.player_visibility_multiplier(player_id), 0.0, 1.0)
	var engaged: bool = zombie.state == ZombieState.State.CHASE or zombie.state == ZombieState.State.ATTACK
	if engaged and zombie.target_visible and zombie.target_player_id == player_id:
		visibility = maxf(visibility, _settings.tracked_target_min_visibility)
	return _settings.effective_sight_range_m() * visibility


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
	GameLogger.debug("zombie", "state changed", {"entity_id": zombie.zombie_id, "from": ZombieState.state_name(previous), "to": ZombieState.state_name(next), "cause": cause, "world_time": _clock.world_time_sec, "action_time": context.now})


# ------------------------------------------------------------ movement

## Movement towards the current goal. An unobstructed move stays bit-for-bit
## on the old straight-line path. When the segment is blocked, a bounded and
## budgeted grid path may provide intermediate waypoints; failure falls back
## to the same blocked straight step used before P3-6.
func _move(world: ServerWorld, zombie: ZombieState, action_delta: float) -> void:
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
		_cancel_navigation(zombie.zombie_id)
		if zombie.state == ZombieState.State.IDLE or zombie.state == ZombieState.State.SEARCH:
			zombie.has_move_target = false
		elif zombie.state == ZombieState.State.CHASE:
			_face(zombie, goal)
		return
	var movement_goal: Vector3 = goal
	var movement_stop_distance: float = stop_distance
	var navigation: NavigationService = world.get_system(NavigationService.SYSTEM_ID) as NavigationService
	var nav_state: _NavigationState = _navigation_states.get(zombie.zombie_id, null)
	if nav_state != null and nav_state.has_path():
		_advance_navigation_waypoint(nav_state, zombie.position)
	var needs_replan: bool = false
	if nav_state != null and nav_state.has_path() and navigation != null:
		needs_replan = ZombiePerception.flat_distance(nav_state.planned_goal, goal) > navigation.settings.replan_goal_distance_m
		if not needs_replan and _clock.action_time_sec >= nav_state.expires_at:
			# Keep a still-valid detour instead of oscillating between equal wall
			# ends. If structure removal opened the direct route, drop it now.
			needs_replan = not world.is_line_blocked(zombie.position, goal)
			if not needs_replan:
				nav_state.expires_at = _clock.action_time_sec + navigation.settings.replan_timeout_sec
		needs_replan = needs_replan or world.is_line_blocked(zombie.position, nav_state.waypoints[nav_state.waypoint_index])
		if needs_replan:
			nav_state.clear_path()
	var known_blocked: bool = nav_state != null and (nav_state.waiting_for_plan or _clock.action_time_sec < nav_state.next_plan_at)
	var direct_blocked: bool = false
	if navigation != null and (nav_state == null or not nav_state.has_path()):
		direct_blocked = known_blocked or world.is_line_blocked(zombie.position, goal)
	if navigation != null and ((nav_state == null or not nav_state.has_path()) and direct_blocked or needs_replan):
		_try_plan(navigation, zombie, goal)
		nav_state = _navigation_states.get(zombie.zombie_id, null)
	if nav_state != null and nav_state.has_path():
		_advance_navigation_waypoint(nav_state, zombie.position)
		if nav_state.has_path():
			movement_goal = nav_state.waypoints[nav_state.waypoint_index]
			if nav_state.waypoint_index < nav_state.waypoints.size() - 1:
				movement_stop_distance = 0.0
	var movement_offset: Vector3 = Vector3(movement_goal.x - zombie.position.x, 0.0, movement_goal.z - zombie.position.z)
	var movement_distance: float = movement_offset.length()
	var waypoint_arrive_distance: float = _settings.arrive_radius_m
	if nav_state != null and nav_state.has_path() and nav_state.waypoint_index < nav_state.waypoints.size() - 1:
		# Intermediate tile centres preserve the edge-valid path. The wider
		# gameplay arrival radius is only safe for the final destination.
		waypoint_arrive_distance = minf(waypoint_arrive_distance, 0.05)
	if movement_distance <= maxf(movement_stop_distance, waypoint_arrive_distance):
		if nav_state != null and nav_state.has_path():
			nav_state.waypoint_index += 1
		return
	var direction: Vector3 = movement_offset / movement_distance
	var travel: float = minf(speed * action_delta, movement_distance - movement_stop_distance)
	var previous: Vector3 = zombie.position
	var wanted: Vector3 = world.clamp_to_world(zombie.position + direction * travel)
	zombie.position = world.resolve_movement(ENTITY_KIND_ZOMBIE, previous, wanted)
	if zombie.position != wanted:
		obstructed_move_count += 1
		_clear_navigation_path(zombie.zombie_id)
		if zombie.state == ZombieState.State.IDLE or zombie.state == ZombieState.State.SEARCH:
			zombie.has_move_target = false
	zombie.yaw = ZombiePerception.yaw_towards(direction, zombie.yaw)
	var cell: Vector2i = world.cell_coords_at(zombie.position)
	if cell != _zombie_cells.get(zombie.zombie_id, cell):
		_cross_border(world, zombie, previous, cell)


func _try_plan(navigation: NavigationService, zombie: ZombieState, goal: Vector3) -> void:
	var state: _NavigationState = _navigation_states.get(zombie.zombie_id, null)
	if state == null:
		state = _NavigationState.new()
		_navigation_states[zombie.zombie_id] = state
	if _clock.action_time_sec < state.next_plan_at:
		return
	_navigation_plan_goals[zombie.zombie_id] = goal
	if state.waiting_for_plan:
		return
	state.waiting_for_plan = true
	_navigation_plan_queue.append(zombie.zombie_id)


func _drain_navigation_plans(world: ServerWorld) -> void:
	var navigation: NavigationService = world.get_system(NavigationService.SYSTEM_ID) as NavigationService
	if navigation == null or _navigation_plan_queue.is_empty():
		return
	var started_usec: int = Time.get_ticks_usec()
	var remaining_nodes: int = navigation.settings.max_planning_nodes_per_tick
	# Only requests present at tick start receive a turn. Pending searches are
	# appended to the tail and cannot consume a second slice in this tick.
	var round_size: int = mini(_navigation_plan_queue.size(), navigation.settings.max_plans_per_tick)
	var round_turns: int = 0
	while not _navigation_plan_queue.is_empty() and round_turns < round_size:
		if remaining_nodes <= 0:
			break
		if navigation.settings.max_planning_msec_per_tick > 0.0 and last_plan_count > 0 and float(Time.get_ticks_usec() - started_usec) / 1000.0 >= navigation.settings.max_planning_msec_per_tick:
			break
		var zombie_id: String = _navigation_plan_queue.pop_front()
		round_turns += 1
		var goal: Vector3 = _navigation_plan_goals.get(zombie_id, Vector3.ZERO)
		var state: _NavigationState = _navigation_states.get(zombie_id, null)
		var zombie: ZombieState = _zombies.get(zombie_id, null)
		if state == null or not state.waiting_for_plan:
			_navigation_plan_goals.erase(zombie_id)
			continue
		if zombie == null or not zombie.is_alive() or not _awake.has(zombie_id):
			state.waiting_for_plan = false
			state.search = null
			_navigation_plan_goals.erase(zombie_id)
			continue
		last_plan_count += 1
		var edge_count: int = navigation.blocking_edge_count()
		var goal_changed: bool = state.search != null and ZombiePerception.flat_distance(state.search_goal, goal) > navigation.settings.replan_goal_distance_m
		var blockers_changed: bool = state.search != null and state.search_blocking_edge_count != edge_count
		if goal_changed or blockers_changed:
			state.search = null
			_search_restart_counts_by_zombie[zombie_id] = _search_restart_counts_by_zombie.get(zombie_id, 0) + 1
		if state.search == null:
			state.clear_path()
			state.search = navigation.begin_search(zombie.position, goal)
			state.search_goal = goal
			state.search_blocking_edge_count = edge_count
			total_plan_count += 1
			_plan_counts_by_zombie[zombie_id] = _plan_counts_by_zombie.get(zombie_id, 0) + 1
		if state.search == null:
			state.waiting_for_plan = false
			_navigation_plan_goals.erase(zombie_id)
			continue
		var slice: int = mini(remaining_nodes, navigation.settings.max_search_nodes_per_tick)
		var result: GridPathResult = state.search.advance(slice)
		var expanded: int = state.search.last_advance_expanded_nodes
		last_plan_node_count += expanded
		remaining_nodes -= expanded
		if not state.search.is_finished():
			_navigation_plan_queue.append(zombie_id)
			continue
		state.waiting_for_plan = false
		state.next_plan_at = _clock.action_time_sec + navigation.settings.min_plan_interval_sec
		state.search = null
		_navigation_plan_goals.erase(zombie_id)
		_search_completion_counts_by_zombie[zombie_id] = _search_completion_counts_by_zombie.get(zombie_id, 0) + 1
		_last_completed_search_nodes_by_zombie[zombie_id] = result.expanded_nodes
		if not result.found:
			continue
		state.waypoints = result.waypoints
		state.planned_goal = state.search_goal
		state.expires_at = _clock.action_time_sec + navigation.settings.replan_timeout_sec
	last_plan_msec = float(Time.get_ticks_usec() - started_usec) / 1000.0


## Diagnostic count used by fairness and starvation tests.
func navigation_plan_count_of(zombie_id: String) -> int:
	return _plan_counts_by_zombie.get(zombie_id, 0)


## Diagnostic count of pending searches invalidated by a moved goal or a
## changed live blocking-edge count.
func navigation_search_restart_count_of(zombie_id: String) -> int:
	return _search_restart_counts_by_zombie.get(zombie_id, 0)


func navigation_search_completion_count_of(zombie_id: String) -> int:
	return _search_completion_counts_by_zombie.get(zombie_id, 0)


func navigation_last_completed_search_nodes_of(zombie_id: String) -> int:
	return _last_completed_search_nodes_by_zombie.get(zombie_id, 0)


func navigation_is_waiting_for_plan(zombie_id: String) -> bool:
	var state: _NavigationState = _navigation_states.get(zombie_id, null)
	return state != null and state.waiting_for_plan


func navigation_search_expanded_nodes_of(zombie_id: String) -> int:
	var state: _NavigationState = _navigation_states.get(zombie_id, null)
	return state.search.result.expanded_nodes if state != null and state.search != null else 0


func _advance_navigation_waypoint(state: _NavigationState, position: Vector3) -> void:
	while state.has_path():
		var arrive_distance: float = _settings.arrive_radius_m if state.waypoint_index == state.waypoints.size() - 1 else minf(_settings.arrive_radius_m, 0.05)
		if ZombiePerception.flat_distance(position, state.waypoints[state.waypoint_index]) > arrive_distance:
			break
		state.waypoint_index += 1


func _clear_navigation_path(zombie_id: String) -> void:
	var state: _NavigationState = _navigation_states.get(zombie_id, null)
	if state != null:
		state.clear_path()


func _cancel_navigation(zombie_id: String) -> void:
	var state: _NavigationState = _navigation_states.get(zombie_id, null)
	if state != null:
		state.clear_path()
		state.search = null
		state.waiting_for_plan = false
	_navigation_plan_goals.erase(zombie_id)


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
	zombie.died_at = _clock.action_time_sec
	zombie.target_player_id = ""
	zombie.target_visible = false
	zombie.has_move_target = false
	zombie.alerted_by = ""
	_scheduler.remove(zombie.zombie_id)
	_navigation_states.erase(zombie.zombie_id)
	_push_event(EVENT_DIED, zombie.zombie_id, {"source_id": source_id})


## Removes corpses older than corpse_remove_delay_sec and tombstones
## their ids (never reused). Only corpses in ACTIVE cells are looked at: one
## in a frozen cell goes as soon as its cell is simulated again.
func _remove_old_corpses(now: float) -> void:
	var expired: PackedStringArray = []
	for zombie_id: String in _awake:
		var zombie: ZombieState = _zombies[zombie_id]
		if not zombie.is_alive() and now - zombie.died_at >= _settings.corpse_remove_delay_sec:
			expired.append(zombie_id)
	var world: ServerWorld = _world()
	for zombie_id: String in expired:
		_sleep(zombie_id)
		_zombies.erase(zombie_id)
		_zombie_cells.erase(zombie_id)
		if world != null:
			world.cell_index.remove(zombie_id)
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


## Per-step lookups shared by all AI decisions of one tick. `now` is action
## time.
class _Context extends RefCounted:
	var world: ServerWorld = null
	var survival: SurvivalService = null
	var noise: NoiseService = null
	var online_ids: PackedStringArray = []
	var now: float = 0.0
