class_name CombatBotRunner
extends RefCounted
## Plays one CombatBotScene with the combat bot and reports what happened
## (docs/12 §9.3). One server and ONE client in this process, connected over
## a real ENet socket on localhost with the production composition
## (NetTestCluster); the bot is that client.
##
## What the bot may do: only what a player's client does. It reads its own
## client mirrors (positions, zombies, own vitals, posture, inventory, world
## items, structures) and sends client intents through the normal request
## functions: move + facing, melee attack, posture, pickup, item use, door.
## It never calls a server API to hurt a zombie, to move itself or to change
## its own state. CombatBotPolicy decides; this class only translates.
##
## What the harness does on the server, and why:
##   - preparation before the fight: the scene's items are the world seed,
##     the zombies are placed with ZombieService.spawn_zombie at a fixed
##     action time (like every scenario test places its zombies);
##   - reading `world.clock.action_time_sec` to start at that fixed time;
##   - after the fight, counting the living zombies to confirm what the
##     client believed.
##
## Same seed -> same result. Three things make a run repeatable:
##   1. Lockstep. Each server tick the harness carries everything that is on
##      the wire across itself (`_sync`: a marker of the test-only
##      CombatBotSyncModule goes to the server and back while both sockets
##      are polled) before the bot looks and again after it acted, so the
##      bot always sees the state after the previous tick and its intents
##      always reach the server before the next one. Without this the frame
##      in which a packet arrives depends on the machine. The bot also joins
##      at a fixed server tick and the fight starts at a fixed action time.
##   2. No real-time rule can bite: request rate limits and the "move input
##      is too old" timeout are measured in real time by the server, so the
##      run uses generous values (see `_new_net_settings`, `_new_config`).
##      The limits themselves are tested in the *_net_test files.
##   3. ENet may drop unreliable packets (move intents, position / zombie
##      snapshots) when it thinks the line is slow or over a bandwidth
##      limit. The server host of the run has no bandwidth limit (see
##      `_set_up` for why it has one otherwise), the throttle of both ends
##      is told never to slow down (`_keep_unreliable_packets`), and a run
##      in which the throttle is not fully open is an error
##      (`_check_unreliable_packets_pass`).
## The fight is bounded by SIMULATED time (server ticks, docs/12 §1.1).

const WORLD: String = "combat_bot_world"
const PLAYER_KEY: String = "combat_bot"
## Server tick (counted from the server's start) at which the bot asks to
## join.
const JOIN_AT_SERVER_TICK: int = 60
## Action time (seconds since the bot joined; the clock is paused while
## nobody is online) at which a prone start is requested and at which the
## zombies are placed and the fight starts.
const PREPARE_AT_SEC: float = 1.0
const FIGHT_AT_SEC: float = 2.0
const TIME_EPSILON_SEC: float = 1.0e-6
## Real time a sync may take before the run is given up as broken (the
## answer normally comes within two polls).
const SYNC_TIMEOUT_MSEC: int = 5000
## Ticks before a refused swing is tried again.
const RETRY_TICKS: int = 6
## Ticks between two item uses.
const CONSUME_RETRY_TICKS: int = 30
## Ticks added to the weapon cooldown before the next swing is asked for.
const COOLDOWN_SLACK_TICKS: int = 1
## The bot picks an item up from this much inside the pickup range.
const PICKUP_MARGIN_M: float = 0.3
const ARENA_RADIUS_M: float = 40.0
## Digits printed of a traced position (enough to see a float difference).
const TRACE_POSITION_FORMAT: String = "(%.7f, %.7f)"
## The fight runs up to this many times faster than real time: the engine
## is asked for SIM_SPEED times as many physics ticks per real second and
## Engine.time_scale is raised by the same factor, so the delta of one tick
## (ticks per second / time scale) stays exactly what the game runs with
## (1/60 s; a power of two keeps the division exact). Simulated time is
## counted in ticks, so the results do not depend on it; a busy machine just
## gets fewer ticks per second.
const SIM_SPEED: int = 4
## Request limits that never refuse the bot (real-time rules, see above;
## with SIM_SPEED the bot sends up to 240 move intents per real second).
const GENEROUS_RATE_PER_SEC: float = 10000.0
const GENEROUS_BURST: int = 10000
const MOVE_INPUT_TIMEOUT_SEC: float = 10.0
## ENetPacketPeer.throttle_configure: ENet's defaults for the interval and
## the acceleration, and no deceleration (never start dropping).
const THROTTLE_INTERVAL_MSEC: int = 5000
const THROTTLE_ACCELERATION: int = 2
const THROTTLE_DECELERATION: int = 0
const SERVER_PEER_ID: int = 1
## ENetConnection.bandwidth_limit: 0 = no limit.
const UNLIMITED_BANDWIDTH: int = 0

const END_CLEARED: String = "cleared"
const END_DEAD: String = "dead"
const END_TIMEOUT: String = "timeout"
const END_ERROR: String = "error"
## Keys of a result that must be equal when a scene is run twice.
const REPEATABLE_KEYS: PackedStringArray = ["scene_id", "seed", "end", "cleared", "sim_ticks", "health_lost", "hits_landed", "hits_taken", "swings", "kills", "zombies"]

var tree: SceneTree
## Prints one line per swing result and zombie hit, and a status line every
## `trace_every_ticks` ticks (ZSS_BOT_TRACE=<ticks>). The lines are kept and
## printed after the fight: printing during it would change how fast the
## frames go, and the trace is for finding what depends on that.
var trace: bool = false
var trace_every_ticks: int = 30
var _trace_lines: PackedStringArray = []

var _scene: CombatBotScene = null
var _config: CompositionConfig = null
var _cluster: NetTestCluster = null
var _world: ServerWorld = null
var _client: NetworkService = null
var _player_id: String = ""
var _grid: StructureGrid = null
var _zombie_mirror: ClientZombieState = null
var _survival_mirror: ClientSurvivalState = null
var _posture_mirror: ClientPostureState = null
var _structure_mirror: ClientStructureState = null
var _combat: CombatNetModule = null
var _posture: PostureNetModule = null
var _inventory: InventoryNetModule = null
var _structures: StructureNetModule = null
## The two ends of the bot's ENet connection.
var _to_server: ENetPacketPeer = null
var _to_client: ENetPacketPeer = null
var _sync_module: CombatBotSyncModule = null
## "" or why the lockstep broke (the run is then an error).
var _sync_error: String = ""

## Server ticks per simulated second (the engine's value before SIM_SPEED).
var _ticks_per_sec: float = 60.0
var _tick: int = 0
var _swing_sent_tick: int = 0
var _swing_ready_tick: int = 0
var _swing_cooldown_ticks: int = 0
var _melee_pending: bool = false
var _posture_pending: bool = false
var _pickup_pending: bool = false
var _consume_pending: bool = false
var _consume_ready_tick: int = 0
var _door_pending: bool = false
var _scene_zombies: Dictionary[String, bool] = {}
var _kills: int = 0
var _hits_landed: int = 0
var _hits_taken: int = 0
var _swings: int = 0
var _weapon_id: String = ""


func _init(scene_tree: SceneTree) -> void:
	tree = scene_tree


## Runs `scene` once (one runner plays one run: make a new one for the next).
## The result always has every key of `_new_result`; `error` is "" unless
## the run could not be set up or its lockstep broke.
func run(scene: CombatBotScene) -> Dictionary:
	_scene = scene
	var result: Dictionary = _new_result(scene)
	var started_msec: int = Time.get_ticks_msec()
	# More ticks per real second, the same simulated time per tick (see
	# SIM_SPEED). Put back before returning.
	var engine_ticks_per_sec: int = Engine.physics_ticks_per_second
	var engine_time_scale: float = Engine.time_scale
	_ticks_per_sec = float(engine_ticks_per_sec)
	Engine.physics_ticks_per_second = engine_ticks_per_sec * SIM_SPEED
	Engine.time_scale = engine_time_scale * float(SIM_SPEED)
	var error: String = await _set_up()
	if error.is_empty():
		error = await _prepare()
	if error.is_empty():
		await _fight(result)
	else:
		result["end"] = END_ERROR
		result["error"] = error
	if _cluster != null:
		await _cluster.shutdown()
		_cluster = null
	_world = null
	Engine.physics_ticks_per_second = engine_ticks_per_sec
	Engine.time_scale = engine_time_scale
	for line: String in _trace_lines:
		print(line)
	result["real_msec"] = Time.get_ticks_msec() - started_msec
	return result


## True when two results of the same scene agree on everything a repeat
## must reproduce (real time is not part of it).
static func same_outcome(a: Dictionary, b: Dictionary) -> bool:
	for key: String in REPEATABLE_KEYS:
		if a.get(key, null) != b.get(key, null):
			return false
	return true


# ------------------------------------------------------------ set-up

func _new_result(scene: CombatBotScene) -> Dictionary:
	return {
		"scene_id": scene.scene_id,
		"seed": scene.rng_seed,
		"end": END_TIMEOUT,
		"cleared": false,
		"sim_ticks": 0,
		"sim_sec": 0.0,
		"health_start": 0.0,
		"health_lost": 0.0,
		"hits_landed": 0,
		"hits_taken": 0,
		"swings": 0,
		"kills": 0,
		"zombies": scene.zombie_offsets.size(),
		"weapon": "",
		"real_msec": 0,
		"error": "",
	}


## Production settings; what the scene and the harness change are copies.
func _new_config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = config.gameplay.duplicate() as GameplaySettings
	config.gameplay.player_spawn_position = _scene.player_spawn
	config.dev_seed = _scene.to_world_seed()
	config.map_content = MapContentDefinition.load_or_null() if _scene.use_test_map else null
	# The scene places its own zombies; every server RNG starts at its seed.
	config.zombie = config.zombie.duplicate() as ZombieSettings
	config.zombie.dev_spawn_count = 0
	config.zombie.rng_seed = _scene.rng_seed
	config.combat = config.combat.duplicate() as CombatSettings
	config.combat.rng_seed = _scene.rng_seed
	config.survival = config.survival.duplicate() as SurvivalSettings
	config.survival.rng_seed = _scene.rng_seed
	# Real-time request limits that must never refuse the bot.
	config.combat_net = config.combat_net.duplicate() as CombatNetSettings
	config.combat_net.melee_intent_rate_per_sec = GENEROUS_RATE_PER_SEC
	config.combat_net.melee_intent_burst = GENEROUS_BURST
	config.posture_net = config.posture_net.duplicate() as PostureNetSettings
	config.posture_net.posture_intent_rate_per_sec = GENEROUS_RATE_PER_SEC
	config.posture_net.posture_intent_burst = GENEROUS_BURST
	config.inventory_net = config.inventory_net.duplicate() as InventoryNetSettings
	config.inventory_net.consume_intent_rate_per_sec = GENEROUS_RATE_PER_SEC
	config.inventory_net.consume_intent_burst = GENEROUS_BURST
	config.structure_net = config.structure_net.duplicate() as StructureNetSettings
	config.structure_net.door_intent_rate_per_sec = GENEROUS_RATE_PER_SEC
	config.structure_net.door_intent_burst = GENEROUS_BURST
	# Path planning must not be cut short by a real-time budget.
	config.navigation = config.navigation.duplicate() as NavigationSettings
	config.navigation.max_search_msec = 0.0
	config.navigation.max_planning_msec_per_tick = 0.0
	return config


func _new_net_settings() -> NetworkSettings:
	var settings: NetworkSettings = NetworkSettings.new()
	settings.autosave_interval_sec = 0.0
	settings.move_intent_rate_per_sec = GENEROUS_RATE_PER_SEC
	settings.move_intent_burst = GENEROUS_BURST
	settings.pickup_intent_rate_per_sec = GENEROUS_RATE_PER_SEC
	settings.pickup_intent_burst = GENEROUS_BURST
	settings.move_input_timeout_sec = MOVE_INPUT_TIMEOUT_SEC
	return settings


## Starts the server, joins the bot's client and hooks up what it listens
## to. Returns "" or what went wrong.
func _set_up() -> String:
	_config = _new_config()
	var errors: PackedStringArray = _config.validate()
	if not errors.is_empty():
		return "invalid config: %s" % "; ".join(errors)
	_grid = StructureGrid.new(_config.building.grid_module_m)
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null or _world.seed_new_world(_config.dev_seed) != OK:
		return "the world could not be created and seeded"
	_cluster = NetTestCluster.new(tree, _new_net_settings(), _config)
	_cluster.extra_module_factories.append(func() -> NetModule: return CombatBotSyncModule.new())
	if _cluster.start_server(_world, null) != OK:
		return "the server did not start"
	# Godot 4.7.2: ENetMultiplayerPeer.create_server(port, clients, channels)
	# with channels > 0 gives the host an INCOMING BANDWIDTH LIMIT of
	# (channels + 2) bytes per second (measured here 2026-11-19: with the
	# game's 3 channels a client's ENet throttle limit drops to 1/32 in
	# alternate seconds and most of its move intents never leave it; docs/15
	# §16.6). The bot must not depend on which intents survive, so its server
	# host is told there is no limit before the client connects.
	var server_peer: ENetMultiplayerPeer = _cluster.server.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if server_peer == null or server_peer.host == null:
		return "the server has no ENet host"
	server_peer.host.bandwidth_limit(UNLIMITED_BANDWIDTH, UNLIMITED_BANDWIDTH)
	# The client connects at once but asks to join at a fixed server tick:
	# how long the connection takes depends on the machine, and everything
	# the server counts from its start (snapshot periods) or from the first
	# player (the action clock) must be at the same point in every run.
	_client = _cluster.add_client(PLAYER_KEY, false)
	_sync_module = _client.get_module(CombatBotSyncModule.MODULE_NAME) as CombatBotSyncModule
	for tick: int in range(JOIN_AT_SERVER_TICK):
		await tree.physics_frame
	if _client.multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return "the bot's client was not connected after %d server ticks" % JOIN_AT_SERVER_TICK
	_client.send_join_request(BuildInfo.PROTOCOL_VERSION, BuildInfo.game_version(), PLAYER_KEY)
	_sync()
	_player_id = _client.client_state.local_player_id
	if _player_id.is_empty():
		return "the bot's client did not join (%s)" % _sync_error
	_zombie_mirror = (_client.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
	_survival_mirror = (_client.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule).client_state
	_posture = _client.get_module(PostureNetModule.MODULE_NAME) as PostureNetModule
	_posture_mirror = _posture.client_state
	_structures = _client.get_module(StructureNetModule.MODULE_NAME) as StructureNetModule
	_structure_mirror = _structures.client_state
	_combat = _client.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule
	_inventory = _client.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	_zombie_mirror.event_received.connect(_on_zombie_event)
	_combat.combat_event.connect(_on_combat_event)
	_combat.melee_result.connect(_on_melee_result)
	_posture.posture_result.connect(_on_posture_result)
	_client.pickup_result.connect(_on_pickup_result)
	_inventory.consume_result.connect(_on_consume_result)
	_structures.structure_result.connect(_on_structure_result)
	return _keep_unreliable_packets()


## Tells ENet on both ends of the bot's connection never to slow its
## unreliable packets down (never to drop one because the line seems slow).
func _keep_unreliable_packets() -> String:
	var client_peer: ENetMultiplayerPeer = _client.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	var server_peer: ENetMultiplayerPeer = _cluster.server.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	var bot_peer_id: int = _cluster.server.peer_of_player(_player_id)
	if client_peer == null or server_peer == null or bot_peer_id == 0:
		return "the connection of the bot was not found"
	_to_server = client_peer.get_peer(SERVER_PEER_ID)
	_to_client = server_peer.get_peer(bot_peer_id)
	if _to_server == null or _to_client == null:
		return "the ENet peers of the bot were not found"
	_to_server.throttle_configure(THROTTLE_INTERVAL_MSEC, THROTTLE_ACCELERATION, THROTTLE_DECELERATION)
	_to_client.throttle_configure(THROTTLE_INTERVAL_MSEC, THROTTLE_ACCELERATION, THROTTLE_DECELERATION)
	return ""


## Ends the run as an error when ENet stopped letting every unreliable
## packet through on either end (its throttle is below the full scale): a
## dropped move intent or snapshot makes the result depend on the machine.
func _check_unreliable_packets_pass() -> void:
	if not _sync_error.is_empty():
		return
	var up: float = _to_server.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE)
	var down: float = _to_client.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE)
	if up < float(ENetPacketPeer.PACKET_THROTTLE_SCALE) or down < float(ENetPacketPeer.PACKET_THROTTLE_SCALE):
		_sync_error = "ENet is dropping unreliable packets at tick %d (throttle client->server %d, server->client %d of %d)" % [_tick, int(up), int(down), ENetPacketPeer.PACKET_THROTTLE_SCALE]


## Waits for the fixed start time, lies down first when the scene says so,
## then places the zombies. Returns "" or what went wrong.
func _prepare() -> String:
	if _world.clock.action_time_sec > PREPARE_AT_SEC:
		return "the bot joined too late to start at a fixed time"
	await _step_until_action_time(PREPARE_AT_SEC)
	if _scene.start_prone:
		_posture_pending = _posture.request_posture(PlayerPosture.Kind.PRONE) != PostureNetModule.NO_REQUEST
		_sync()
	await _step_until_action_time(FIGHT_AT_SEC)
	if not _sync_error.is_empty():
		return _sync_error
	if _scene.start_prone and not _posture_mirror.is_prone(_player_id):
		return "the bot did not get to lie down before the fight"
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	for index: int in range(_scene.zombie_offsets.size()):
		var spawned: ActionResult = zombies.spawn_zombie(_world, _scene.zombie_position(index), _scene.zombie_yaw(index))
		if not spawned.ok:
			return "zombie %d could not be placed: %s" % [index, spawned.reason]
		_scene_zombies[str(spawned.event.get("zombie_id", ""))] = true
	return ""


## One server tick at a time (each followed by a sync) until the world's
## action clock reaches `time_sec`.
func _step_until_action_time(time_sec: float) -> void:
	while _world.clock.action_time_sec < time_sec - TIME_EPSILON_SEC and _sync_error.is_empty():
		await tree.physics_frame
		_sync()


## Carries everything that is on the wire between the bot's client and the
## server, in both directions, now: sends a marker and polls both ends until
## the server's answer is back (CombatBotSyncModule). When it returns, the
## server has handled everything the client sent and the client has applied
## everything the server sent. False (and `_sync_error`) when the answer
## does not come within SYNC_TIMEOUT_MSEC of real time: the run is void.
func _sync() -> bool:
	if not _sync_error.is_empty():
		return false
	var marker: int = _sync_module.send_marker()
	var give_up_msec: int = Time.get_ticks_msec() + SYNC_TIMEOUT_MSEC
	while _sync_module.answered < marker:
		_client.multiplayer.poll()
		_cluster.server.multiplayer.poll()
		if Time.get_ticks_msec() > give_up_msec:
			_sync_error = "the connection between the bot and the server stopped answering (marker %d)" % marker
			return false
	return true


# ------------------------------------------------------------ the fight

func _fight(result: Dictionary) -> void:
	var policy: CombatBotPolicy = CombatBotPolicy.new()
	var max_ticks: int = ceili(_scene.max_sim_sec * _ticks_per_sec)
	_sync()
	var health_start: float = _survival_mirror.health()
	result["health_start"] = health_start
	var end: String = END_TIMEOUT
	_tick = 0
	while _tick < max_ticks and _sync_error.is_empty():
		# The signal comes before the server's physics step of this tick:
		# the bot sees the world after the previous tick and what it sends
		# now is on the server before the step.
		await tree.physics_frame
		_sync()
		if _kills >= _scene_zombies.size():
			end = END_CLEARED
			break
		var obs: CombatBotPolicy.Observation = _observe()
		if not obs.alive:
			end = END_DEAD
			break
		var action: CombatBotPolicy.Action = policy.decide(obs)
		if trace and _tick % trace_every_ticks == 0:
			var nearest: Dictionary = CombatBotPolicy.nearest_zombie(obs)
			var nearest_text: String = "-"
			if not nearest.is_empty():
				var nearest_position: Vector3 = nearest["position"]
				nearest_text = "%s %s at %s, %.2f m" % [str(nearest["id"]), str(nearest["state"]), TRACE_POSITION_FORMAT % [nearest_position.x, nearest_position.z], ZombiePerception.flat_distance(obs.position, nearest_position)]
			_trace_lines.append("[bot] tick %d: at %s health %.1f stamina %.1f, %d zombie(s), nearest %s, ready=%s move=%s" % [
				_tick, TRACE_POSITION_FORMAT % [obs.position.x, obs.position.z], _survival_mirror.health(), obs.stamina, obs.zombies.size(),
				nearest_text, str(obs.swing_ready), str(action.move),
			])
		_act(action)
		_sync()
		_check_unreliable_packets_pass()
		_tick += 1
	# The last answers and the last step's events.
	await tree.physics_frame
	_sync()
	var living: int = _living_scene_zombies()
	if trace:
		_trace_lines.append("[bot] server refused %d intent(s) in this run" % _cluster.server.rejected_intent_count())
		var shown: int = 0
		for line: String in GameLogger.captured_lines():
			if shown < 20 and (line.contains("[WARNING]") or line.contains("[ERROR]")):
				_trace_lines.append("[bot] server log: %s" % line)
				shown += 1
	if not _sync_error.is_empty():
		end = END_ERROR
		result["error"] = _sync_error
	elif end == END_CLEARED and living > 0:
		end = END_ERROR
		result["error"] = "the client counted every zombie dead but the server has %d alive" % living
	result["end"] = end
	result["cleared"] = end == END_CLEARED
	result["sim_ticks"] = _tick
	result["sim_sec"] = float(_tick) / _ticks_per_sec
	result["health_lost"] = health_start - (_survival_mirror.health() if _survival_mirror.is_alive(_player_id) else 0.0)
	result["hits_landed"] = _hits_landed
	result["hits_taken"] = _hits_taken
	result["swings"] = _swings
	result["kills"] = _kills
	result["weapon"] = _weapon_id


## Everything the policy gets, read from the bot's own client mirrors.
func _observe() -> CombatBotPolicy.Observation:
	var obs: CombatBotPolicy.Observation = CombatBotPolicy.Observation.new()
	var state: ClientWorldState = _client.client_state
	obs.alive = _survival_mirror.is_alive(_player_id)
	obs.position = state.position_of(_player_id)
	obs.prone = _posture_mirror.is_prone(_player_id)
	obs.stamina = _survival_mirror.stamina()
	for wound: Dictionary in _survival_mirror.wounds():
		if bool(wound.get("is_bleeding", false)):
			obs.bleeding = true
			break
	for zombie_id: String in _zombie_mirror.zombie_ids():
		var row: Dictionary = _zombie_mirror.get_zombie(zombie_id)
		if str(row["state"]) != ClientZombieState.STATE_DEAD:
			obs.zombies.append({"id": zombie_id, "position": row["position"], "state": str(row["state"])})
	var weapon: MeleeWeaponDefinition = _carried_weapon(state)
	_weapon_id = weapon.weapon_id
	_swing_cooldown_ticks = ceili(weapon.cooldown_sec * _ticks_per_sec) + COOLDOWN_SLACK_TICKS
	obs.weapon_range_m = weapon.range_m
	obs.weapon_stamina_cost = weapon.stamina_cost
	obs.swing_ready = not _melee_pending and _tick >= _swing_ready_tick
	var pickup_reach_m: float = _config.gameplay.pickup_range_m - PICKUP_MARGIN_M
	for item_id: String in state.world_items:
		var entry: Dictionary = state.world_items[item_id]
		if _is_wanted(str(entry[ClientWorldState.KEY_DEFINITION_ID])) and ZombiePerception.flat_distance(obs.position, entry[ClientWorldState.KEY_POSITION]) <= pickup_reach_m:
			obs.reachable_pickups.append(item_id)
	obs.reachable_pickups.sort()
	for item: Dictionary in state.inventory:
		var definition: ItemDefinition = _config.catalog.get_definition(str(item.get("definition_id", "")))
		if definition != null and definition.treat_bleeding_wound_count > 0:
			obs.bandage_item_id = str(item.get("item_instance_id", ""))
			break
	for structure_id: String in _structure_mirror.structure_ids():
		var entry: Dictionary = _structure_mirror.get_structure(structure_id)
		var definition: StructureDefinition = _config.structures.get_definition(str(entry[ClientStructureState.KEY_DEFINITION_ID]))
		if definition != null and definition.is_door and not bool(entry[ClientStructureState.KEY_DOOR_OPEN]):
			obs.closed_doors.append({"id": structure_id, "position": _grid.slot_anchor(_structure_mirror.slot_of(structure_id))})
	obs.door_range_m = _config.building.door_interact_range_m
	obs.posture_pending = _posture_pending
	obs.pickup_pending = _pickup_pending
	obs.consume_pending = _consume_pending or _tick < _consume_ready_tick
	obs.door_pending = _door_pending
	obs.arena_center = _scene.player_spawn
	obs.arena_radius_m = ARENA_RADIUS_M
	return obs


## The weapon the server would let the bot swing: decided, like on the
## server, by the carried items and the combat settings (static data every
## client has); bare hands when nothing carried is a weapon.
func _carried_weapon(state: ClientWorldState) -> MeleeWeaponDefinition:
	var items: Array[Dictionary] = state.inventory.duplicate()
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _slot_index(a) < _slot_index(b))
	var definition_ids: PackedStringArray = []
	for item: Dictionary in items:
		definition_ids.append(str(item.get("definition_id", "")))
	var weapon: MeleeWeaponDefinition = _config.melee_weapons.pick_for_items(definition_ids, _config.combat.inventory_weapon_rule)
	return weapon if weapon != null else _config.melee_weapons.get_definition(_config.combat.unarmed_weapon_id)


static func _slot_index(item: Dictionary) -> int:
	return str(item.get("slot_id", "")).trim_prefix(InventoryService.SLOT_PREFIX).to_int()


## Worth picking up: a weapon or something that stops bleeding.
func _is_wanted(definition_id: String) -> bool:
	if _config.melee_weapons.for_item(definition_id) != null:
		return true
	var definition: ItemDefinition = _config.catalog.get_definition(definition_id)
	return definition != null and definition.treat_bleeding_wound_count > 0


## Sends the action as client intents (the only way the bot acts).
func _act(action: CombatBotPolicy.Action) -> void:
	_client.send_move_intent(action.move, action.yaw)
	if action.attack and not _melee_pending:
		_melee_pending = _combat.request_melee_attack(action.aim_yaw) != CombatNetModule.NO_REQUEST
		_swing_sent_tick = _tick
	if action.stand_up and not _posture_pending:
		_posture_pending = _posture.request_posture(PlayerPosture.Kind.STANDING) != PostureNetModule.NO_REQUEST
	if not action.pickup_item_id.is_empty() and not _pickup_pending:
		_client.request_pickup(action.pickup_item_id)
		_pickup_pending = true
	if not action.consume_item_id.is_empty() and not _consume_pending:
		_consume_pending = _inventory.request_consume(action.consume_item_id) != InventoryNetModule.NO_REQUEST
	if not action.open_door_id.is_empty() and not _door_pending:
		_door_pending = _structures.request_door(action.open_door_id, true) != StructureNetModule.NO_REQUEST


## Server truth, read after the fight: how many of the scene's zombies live.
func _living_scene_zombies() -> int:
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var living: int = 0
	for zombie_id: String in _scene_zombies:
		var zombie: ZombieState = zombies.get_zombie(zombie_id)
		if zombie != null and zombie.is_alive():
			living += 1
	return living


# ------------------------------------------------------------ what the client hears

func _on_zombie_event(event: Dictionary) -> void:
	var event_type: String = str(event.get("event_type", ""))
	var zombie_id: String = str(event.get("zombie_id", ""))
	if event_type == ZombieService.EVENT_DIED and _scene_zombies.has(zombie_id):
		_kills += 1
	elif event_type == ZombieService.EVENT_ATTACKED and str(event.get("target_id", "")) == _player_id:
		_hits_taken += 1
		if trace:
			_trace_lines.append("[bot] tick %d: %s hit the bot (%s, %s)" % [_tick, zombie_id, str(event.get("wound_type", "")), str(event.get("damage", ""))])


func _on_combat_event(event: Dictionary) -> void:
	if str(event.get(ClientCombatState.KEY_ATTACKER_ID, "")) != _player_id:
		return
	if bool(event.get(ClientCombatState.KEY_HIT, false)):
		_hits_landed += 1
	if trace:
		_trace_lines.append("[bot] tick %d: swing %s target=%s died=%s" % [_tick, "hit" if bool(event.get(ClientCombatState.KEY_HIT, false)) else "missed", str(event.get(ClientCombatState.KEY_TARGET_ID, "")), str(event.get(ClientCombatState.KEY_TARGET_DIED, false))])


func _on_melee_result(_request_id: int, ok: bool, reason: String) -> void:
	_melee_pending = false
	if ok:
		_swings += 1
		_swing_ready_tick = _swing_sent_tick + _swing_cooldown_ticks
	else:
		_swing_ready_tick = _tick + RETRY_TICKS
		if trace:
			_trace_lines.append("[bot] tick %d: swing refused (%s)" % [_tick, reason])


func _on_posture_result(_request_id: int, _ok: bool, _reason: String) -> void:
	_posture_pending = false


func _on_pickup_result(_request_id: int, _ok: bool, _reason: String) -> void:
	_pickup_pending = false


## The own wounds arrive with the next vitals snapshot: until then the
## mirror still shows the wound bleeding, so the next bandage waits.
func _on_consume_result(_request_id: int, _ok: bool, _reason: String) -> void:
	_consume_pending = false
	_consume_ready_tick = _tick + CONSUME_RETRY_TICKS


func _on_structure_result(_request_id: int, _ok: bool, _reason: String, _structure_id: String) -> void:
	_door_pending = false
