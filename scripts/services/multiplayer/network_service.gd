class_name NetworkService
extends Node
## Connection, RPC transport and input validation (docs/08, docs/09 §4).
##
## The same script runs on server and client so RPC paths/configs match.
## Server: accepts ENet peers, runs the join handshake, validates every
## intent (type, range, rate, state) and forwards it to ServerWorld, then
## replicates results. Client: sends intents only and mirrors server state
## in ClientWorldState. Game rules live in ServerWorld, saving in
## WorldPersistence; this node only orchestrates.
##
## RPC table (channel 0 = reliable ordered, channel 1 = unreliable ordered):
##   client -> server  _rpc_request_join(protocol:int, game_version:String, player_key:String)  reliable, ch0
##   server -> client  _rpc_join_accepted(player_id:String, snapshot:Dictionary)                  reliable, ch0
##   server -> client  _rpc_join_rejected(reason:String)                                          reliable, ch0
##   server -> client  _rpc_player_joined(player_id:String, position:Vector3, yaw:float)          reliable, ch0
##   server -> client  _rpc_player_left(player_id:String)                                         reliable, ch0
##   client -> server  _rpc_move_intent(sequence:int, direction:Vector2, yaw:float)               unreliable_ordered, ch1
##   server -> client  _rpc_position_snapshot(tick:int, rows:Array[[player_id, Vector3, yaw]])    unreliable_ordered, ch1
##   client -> server  _rpc_request_pickup(request_id:int, item_instance_id:String)              reliable, ch0
##   server -> client  _rpc_pickup_result(request_id:int, ok:bool, reason:String)                 reliable, ch0
##   server -> clients _rpc_world_item_removed(item_instance_id:String)                           reliable, ch0
##   server -> owner   _rpc_inventory_item(item:Dictionary /* ItemInstance.to_dict() */)          reliable, ch0
## Pickup: the server decides with its own player position; on success the
## world is saved immediately (docs/10 §5 major transaction).
## Movement: clients send only an input direction (|d| <= 1) and facing; the
## server applies its own speed on the physics tick, clamps to the world and
## broadcasts positions. Clients never send positions. Input contract for the
## client input layer (P1-4): send the current direction every physics tick
## while it is non-zero and send Vector2.ZERO (a few times) on release; the
## server-side input timeout only covers lost packets.
## Initial state is sent inside _rpc_join_accepted; later deltas use the same
## reliable channel, so they always arrive after the snapshot.
## Channel 2 (unreliable ordered) is reserved for AI entity snapshots (Phase 2-A).
##
## Extension seam (Phase 2 P2-0): feature NetModules are registered with
## register_module() before start (ServerComposition.install_net_modules).
## They become children of this node (same name on every peer -> matching RPC
## paths), receive lifecycle hooks, contribute join snapshot fragments
## (snapshot["modules"][name]) and use the public helpers below. This file is
## frozen for feature work after P2-0.
##
## P2-T9 (docs/09 §14.24, the one change since the freeze): a joined peer
## whose player has no character yet is connected but not in the world
## (ServerWorld.is_online is false). Such a player is not announced: the
## other peers get no _rpc_player_joined / _rpc_player_left for it and the
## modules get no on_player_joined. When its first character is created the
## character module calls announce_player_entered(), which does the
## announcement the handshake skipped. Where every player has a character at
## join (ServerWorld.require_character_creation false) nothing changed.
##
## P2-T15 (docs/09 §14.29, the second change since the freeze, three lines in
## _rpc_request_pickup): a picked-up item may merge into the stacks the
## player carries and then no longer exists, so _rpc_inventory_item is sent
## only for an item that is still there. The grown stacks are replicated by
## InventoryNetModule; the pickup messages themselves are unchanged.
##
## P3-2 (docs/09 §15.2, the third change since the freeze): replication scope
## by world cell. `cell_interest` (set by InterestNetModule when the server
## starts) says which joined peers are told about the entities of a cell;
## is_cell_of_interest() / peers_interested_in() ask it, and answer "every
## joined peer" while there is none. What this node sends itself follows it:
##   - the join snapshot lists only the world items of the joining peer's
##     cells (the module fragments are built first, because the interest
##     module's fragment is what gives the peer its cells);
##   - _rpc_world_item_removed after a pickup goes to the peers that were
##     told about the cell the item lay in, not to everybody;
##   - a refused pickup tells the requester nothing about an item it was not
##     told about (_public_pickup_reason).
## Players are not scoped: player rows and position snapshots still go to
## every joined peer (docs/15 P3-041).

signal server_started(port: int)
signal join_accepted(player_id: String)
signal join_rejected(reason: String)
signal connection_failed
signal server_disconnected
## Server and client: a player became visible / went away.
signal player_joined(player_id: String)
signal player_left(player_id: String)
## Client: answer to one of this client's pickup requests.
signal pickup_result(request_id: int, ok: bool, reason: String)

enum Mode { NONE, SERVER, CLIENT }

const SERVER_PEER_ID: int = 1
const REASON_SERVER_FULL: String = "server_full"
const REASON_ALREADY_JOINED: String = "already_joined"
const REASON_KEY_IN_USE: String = "player_key_in_use"
const REASON_HANDSHAKE_TIMEOUT: String = "handshake_timeout"
const MSEC_PER_SEC: float = 1000.0
const RATE_LIMITED: String = "rate_limited"
const NOT_JOINED: String = "not_joined"

const SNAPSHOT_MODULES_KEY: String = "modules"
const MONITOR_TICK_MSEC: StringName = &"server/tick_time_ms"
const MONITOR_ZOMBIE_MSEC: StringName = &"server/zombie_step_time_ms"
const MONITOR_PLANNING_NODES: StringName = &"server/planning_nodes_per_tick"
const MONITOR_LOADED_CELLS: StringName = &"server/loaded_cells"
const MONITOR_ACTIVE_CELLS: StringName = &"server/active_cells"
const MONITOR_SAVE_BUILD_MSEC: StringName = &"server/save_build_time_ms"
const MONITOR_SAVE_WRITE_MSEC: StringName = &"server/save_write_time_ms"
const MONITOR_SAVES_COALESCED: StringName = &"server/saves_coalesced"
const PERFORMANCE_MONITORS: Array[StringName] = [MONITOR_TICK_MSEC, MONITOR_ZOMBIE_MSEC, MONITOR_PLANNING_NODES, MONITOR_LOADED_CELLS, MONITOR_ACTIVE_CELLS, MONITOR_SAVE_BUILD_MSEC, MONITOR_SAVE_WRITE_MSEC, MONITOR_SAVES_COALESCED]

static var _performance_monitor_owner: WeakRef = null

var client_state: ClientWorldState = ClientWorldState.new()
## Server (P3-2): which cells each joined peer is told about. Null (no
## interest module installed) = every joined peer is told about every cell.
var cell_interest: CellInterest = null

var _mode: Mode = Mode.NONE
var _settings: NetworkSettings = null
var _peer: ENetMultiplayerPeer = null
# --- server state ---
var _world: ServerWorld = null
var _persistence: WorldPersistence = null
var _pending_peers: Dictionary[int, int] = {}
var _peer_players: Dictionary[int, String] = {}
var _kick_at_msec: Dictionary[int, int] = {}
var _autosave_elapsed: float = 0.0
var _move_limiter: RateLimiter = null
var _pickup_limiter: RateLimiter = null
var _snapshot_elapsed: float = 0.0
var _snapshot_tick: int = 0
var _last_server_tick_msec: float = 0.0
var _owns_performance_monitors: bool = false
## Rejected intents per reason code (diagnostics and tests).
var _rejections: Dictionary[String, int] = {}
# --- client state ---
var _player_key: String = ""
var _auto_join: bool = true
var _move_sequence: int = 0
var _pickup_request_id: int = 0
# --- feature modules (both roles) ---
var _modules: Array[NetModule] = []


# ============================================================ lifecycle

## Adds a feature module as a child node. Only before start_server /
## start_client; module node names must be unique and non-empty.
func register_module(module: NetModule) -> Error:
	if _mode != Mode.NONE:
		GameLogger.error("net", "module registered after start", {"module": str(module.name), "operation": "register_module"})
		return ERR_ALREADY_IN_USE
	var module_name: String = str(module.name)
	if module_name.is_empty() or has_node(NodePath(module_name)):
		GameLogger.error("net", "module name empty or duplicate", {"module": module_name, "operation": "register_module"})
		return ERR_ALREADY_EXISTS
	module.network = self
	add_child(module)
	_modules.append(module)
	return OK


## Registered module by node name, or null.
func get_module(module_name: String) -> NetModule:
	for module: NetModule in _modules:
		if str(module.name) == module_name:
			return module
	return null


## Starts listening. `persistence` may be null (no saving, tests only).
func start_server(world: ServerWorld, persistence: WorldPersistence, settings: NetworkSettings, port: int) -> Error:
	if _mode != Mode.NONE:
		return ERR_ALREADY_IN_USE
	_settings = settings
	_world = world
	_persistence = persistence
	_move_limiter = RateLimiter.new(settings.move_intent_rate_per_sec, settings.move_intent_burst)
	_pickup_limiter = RateLimiter.new(settings.pickup_intent_rate_per_sec, settings.pickup_intent_burst)
	_peer = ENetMultiplayerPeer.new()
	if settings.bind_address != "*":
		_peer.set_bind_ip(settings.bind_address)
	var error: Error = _peer.create_server(port, settings.max_players + NetworkSettings.TRANSPORT_HEADROOM, NetworkSettings.CHANNEL_COUNT)
	if error != OK:
		GameLogger.error("net", "failed to start server", {"port": port, "error": error_string(error), "operation": "start_server"})
		_peer = null
		return error
	# No bandwidth limit, said explicitly and before anybody can connect
	# (docs/08 §14.1, docs/15 TT-001). Godot 4.7.2: create_server() with
	# max_channels > 0 leaves the host with a tiny INCOMING bandwidth limit
	# even when in_bandwidth is passed as 0 (measured; with max_channels 0
	# there is none). A connecting client is told that limit and its ENet
	# then drops most unreliable packets (move intents) before sending them.
	_peer.host.bandwidth_limit(NetworkSettings.UNLIMITED_BANDWIDTH, NetworkSettings.UNLIMITED_BANDWIDTH)
	# Compression is a host property and must be installed after create_host.
	# A different client mode cannot complete the ENet connection.
	_peer.host.compress(settings.compression_mode)
	# Clients must never reach each other directly: disable SceneMultiplayer
	# relay so every message goes through server validation (CLAUDE.md §5).
	# This also stops the engine from notifying peers that are already
	# disconnecting.
	var scene_multiplayer: SceneMultiplayer = multiplayer as SceneMultiplayer
	if scene_multiplayer != null:
		scene_multiplayer.server_relay = false
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_mode = Mode.SERVER
	for module: NetModule in _modules:
		module.on_server_started(world)
	GameLogger.info("net", "server listening", {"port": port, "max_players": settings.max_players, "protocol": BuildInfo.PROTOCOL_VERSION, "compression": NetworkSettings.compression_mode_name(settings.compression_mode), "world_id": world.world_id, "modules": _modules.size()})
	server_started.emit(port)
	return OK


## Connects to a server. With `auto_join` the join request is sent as soon
## as the transport connects (tests may disable it to send custom requests).
func start_client(address: String, port: int, player_key: String, settings: NetworkSettings, auto_join: bool = true) -> Error:
	if _mode != Mode.NONE:
		return ERR_ALREADY_IN_USE
	_settings = settings
	_player_key = player_key
	_auto_join = auto_join
	_peer = ENetMultiplayerPeer.new()
	var error: Error = _peer.create_client(address, port, NetworkSettings.CHANNEL_COUNT)
	if error != OK:
		GameLogger.error("net", "failed to create client", {"address": address, "port": port, "error": error_string(error), "operation": "start_client"})
		_peer = null
		return error
	# The client host has no limit after create_client() (measured); it is
	# said explicitly so both ends are set the same way (docs/08 §14.1).
	_peer.host.bandwidth_limit(NetworkSettings.UNLIMITED_BANDWIDTH, NetworkSettings.UNLIMITED_BANDWIDTH)
	# This must match the server. ENet reports only a failed connection when it
	# does not, so retain the configured value for the diagnostic below.
	_peer.host.compress(settings.compression_mode)
	multiplayer.multiplayer_peer = _peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_mode = Mode.CLIENT
	GameLogger.info("net", "connecting; ENet compression must match the server", {"address": address, "port": port, "compression": NetworkSettings.compression_mode_name(settings.compression_mode)})
	return OK


## Closes the connection. A server saves the world first.
func stop() -> void:
	if _mode == Mode.NONE:
		return
	if _mode == Mode.SERVER:
		for peer_id: int in _peer_players.keys():
			_world.leave(_peer_players[peer_id])
		_peer_players.clear()
		persist("shutdown", true)
		_remove_performance_monitors()
		multiplayer.peer_connected.disconnect(_on_peer_connected)
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	else:
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
		multiplayer.connection_failed.disconnect(_on_connection_failed)
		multiplayer.server_disconnected.disconnect(_on_server_disconnected)
	_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_peer = null
	_mode = Mode.NONE
	GameLogger.info("net", "network stopped")


func _exit_tree() -> void:
	stop()


func is_server() -> bool:
	return _mode == Mode.SERVER


func is_client() -> bool:
	return _mode == Mode.CLIENT


func get_world() -> ServerWorld:
	return _world


func get_settings() -> NetworkSettings:
	return _settings


## Server: player id of the peer whose RPC is being handled ("" if that peer
## has not completed the join handshake). Call only inside an RPC handler.
func sender_player_id() -> String:
	if _mode != Mode.SERVER:
		return ""
	return _peer_players.get(multiplayer.get_remote_sender_id(), "")


## Server: peer ids that completed the handshake (sorted).
func joined_peers() -> PackedInt32Array:
	var peers: PackedInt32Array = PackedInt32Array(_peer_players.keys())
	peers.sort()
	return peers


## Server: peer id of an online player, or 0.
func peer_of_player(player_id: String) -> int:
	for peer_id: int in _peer_players:
		if _peer_players[peer_id] == player_id:
			return peer_id
	return 0


## Server: player id for a joined peer, or "".
func player_of_peer(peer_id: int) -> String:
	return _peer_players.get(peer_id, "")


## Server: number of peers that completed the handshake.
func joined_peer_count() -> int:
	return _peer_players.size()


## Server (P3-2): true when `peer_id` is to be told about the entities of
## the world cell `cell_id` (docs/09 §15.2).
func is_cell_of_interest(peer_id: int, cell_id: String) -> bool:
	return cell_interest == null or cell_interest.is_interested(peer_id, cell_id)


## Server (P3-2): the joined peers that are to be told about the entities of
## the world cell `cell_id`, sorted.
func peers_interested_in(cell_id: String) -> PackedInt32Array:
	return joined_peers() if cell_interest == null else cell_interest.peers_for_cell(cell_id)


## Server: how many intents were rejected for `reason` ("" = all reasons).
func rejected_intent_count(reason: String = "") -> int:
	if not reason.is_empty():
		return _rejections.get(reason, 0)
	var total: int = 0
	for count: int in _rejections.values():
		total += count
	return total


func _process(delta: float) -> void:
	if _mode == Mode.SERVER:
		_server_process(delta)


func _physics_process(delta: float) -> void:
	if _mode != Mode.SERVER:
		return
	_register_performance_monitors()
	var started_usec: int = Time.get_ticks_usec()
	_world.step_movement(delta, Time.get_ticks_msec(), int(_settings.move_input_timeout_sec * MSEC_PER_SEC))
	_world.step_systems(delta)
	for module: NetModule in _modules:
		module.server_physics(delta)
	_snapshot_elapsed += delta
	if _snapshot_elapsed >= 1.0 / _settings.snapshot_rate_hz:
		_snapshot_elapsed = 0.0
		_broadcast_positions()
	_last_server_tick_msec = float(Time.get_ticks_usec() - started_usec) / 1000.0


func _register_performance_monitors() -> void:
	if _owns_performance_monitors:
		return
	var owner: Object = _performance_monitor_owner.get_ref() if _performance_monitor_owner != null else null
	if owner != null and owner != self:
		return
	Performance.add_custom_monitor(MONITOR_TICK_MSEC, func() -> float: return _last_server_tick_msec)
	Performance.add_custom_monitor(MONITOR_ZOMBIE_MSEC, _monitor_zombie_step_msec)
	Performance.add_custom_monitor(MONITOR_PLANNING_NODES, _monitor_planning_nodes)
	Performance.add_custom_monitor(MONITOR_LOADED_CELLS, _monitor_loaded_cells)
	Performance.add_custom_monitor(MONITOR_ACTIVE_CELLS, _monitor_active_cells)
	Performance.add_custom_monitor(MONITOR_SAVE_BUILD_MSEC, func() -> float: return _persistence.last_save_build_msec if _persistence != null else 0.0)
	Performance.add_custom_monitor(MONITOR_SAVE_WRITE_MSEC, func() -> float: return _persistence.last_save_write_msec if _persistence != null else 0.0)
	Performance.add_custom_monitor(MONITOR_SAVES_COALESCED, func() -> int: return _persistence.saves_coalesced if _persistence != null else 0)
	_performance_monitor_owner = weakref(self)
	_owns_performance_monitors = true


func _remove_performance_monitors() -> void:
	if not _owns_performance_monitors:
		return
	for monitor: StringName in PERFORMANCE_MONITORS:
		Performance.remove_custom_monitor(monitor)
	_owns_performance_monitors = false
	_performance_monitor_owner = null


func _monitor_zombie_step_msec() -> float:
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService if _world != null else null
	return zombies.last_step_msec if zombies != null else 0.0


func _monitor_planning_nodes() -> int:
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService if _world != null else null
	return zombies.last_plan_node_count if zombies != null else 0


func _monitor_loaded_cells() -> int:
	var cells: WorldCellService = _world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService if _world != null else null
	return cells.loaded_cell_ids().size() if cells != null else 0


func _monitor_active_cells() -> int:
	var cells: WorldCellService = _world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService if _world != null else null
	return cells.active_cell_ids().size() if cells != null else 0


# ============================================================ server side

func _on_peer_connected(peer_id: int) -> void:
	_pending_peers[peer_id] = Time.get_ticks_msec()
	GameLogger.info("net", "peer connected, awaiting join", {"peer_id": peer_id})


func _on_peer_disconnected(peer_id: int) -> void:
	_pending_peers.erase(peer_id)
	_kick_at_msec.erase(peer_id)
	if not _peer_players.has(peer_id):
		return
	var player_id: String = _peer_players[peer_id]
	_peer_players.erase(peer_id)
	_move_limiter.forget(peer_id)
	_pickup_limiter.forget(peer_id)
	# P2-T9: only a player that was in the world was ever announced.
	var was_in_world: bool = _world.is_online(player_id)
	_world.leave(player_id)
	for module: NetModule in _modules:
		module.on_player_left(peer_id, player_id)
	persist("player_left")
	for other: int in _peer_players:
		if was_in_world and can_send_to(other):
			_rpc_player_left.rpc_id(other, player_id)
	GameLogger.info("net", "player disconnected", {"peer_id": peer_id, "player_id": player_id})
	if was_in_world:
		player_left.emit(player_id)


func _server_process(delta: float) -> void:
	var now: int = Time.get_ticks_msec()
	var timeout_msec: int = int(_settings.handshake_timeout_sec * MSEC_PER_SEC)
	for peer_id: int in _pending_peers.keys():
		if now - _pending_peers[peer_id] > timeout_msec:
			_reject_join(peer_id, REASON_HANDSHAKE_TIMEOUT)
	for peer_id: int in _kick_at_msec.keys():
		if now >= _kick_at_msec[peer_id]:
			_kick_at_msec.erase(peer_id)
			_peer.disconnect_peer(peer_id)
	if _settings.autosave_interval_sec > 0.0:
		_autosave_elapsed += delta
		if _autosave_elapsed >= _settings.autosave_interval_sec:
			_autosave_elapsed = 0.0
			persist("autosave")


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_join(protocol_version: Variant, game_version: Variant, player_key: Variant) -> void:
	if _mode != Mode.SERVER:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if _peer_players.has(peer_id):
		GameLogger.warning("net", "duplicate join request ignored", {"peer_id": peer_id, "player_id": _peer_players[peer_id], "operation": "request_join"})
		return
	if not _pending_peers.has(peer_id):
		return  # already rejected / being disconnected
	var reason: String = IntentValidator.validate_join(protocol_version, game_version, player_key, BuildInfo.PROTOCOL_VERSION, _settings.player_key_max_length)
	if not reason.is_empty():
		_reject_join(peer_id, reason)
		return
	if _peer_players.size() >= _settings.max_players:
		_reject_join(peer_id, REASON_SERVER_FULL)
		return
	var state: PlayerState = _world.join(str(player_key))
	if state == null:
		_reject_join(peer_id, REASON_KEY_IN_USE)
		return
	_pending_peers.erase(peer_id)
	_peer_players[peer_id] = state.player_id
	_rpc_join_accepted.rpc_id(peer_id, state.player_id, _build_join_snapshot(state.player_id))
	GameLogger.info("net", "join accepted", {"peer_id": peer_id, "player_id": state.player_id, "client_game_version": str(game_version)})
	# P2-T9: a player without a character is not in the world yet; it is
	# announced by announce_player_entered() once its character exists.
	if _world.is_online(state.player_id):
		_announce_player(peer_id, state.player_id, false)


## Server (P2-T9): a joined player that was not in the world entered it (its
## first character was created). Does what the join handshake does for a
## player that is in the world at once: every joined peer gets
## _rpc_player_joined (the player's own peer too: its join snapshot did not
## contain it), modules get on_player_joined and `player_joined` is emitted.
func announce_player_entered(player_id: String) -> void:
	var peer_id: int = peer_of_player(player_id)
	if _mode != Mode.SERVER or peer_id == 0 or not _world.is_online(player_id):
		return
	_announce_player(peer_id, player_id, true)


func _announce_player(peer_id: int, player_id: String, include_own_peer: bool) -> void:
	var state: PlayerState = _world.get_player(player_id)
	for other: int in _peer_players:
		if (include_own_peer or other != peer_id) and can_send_to(other):
			_rpc_player_joined.rpc_id(other, player_id, state.position, state.yaw)
	for module: NetModule in _modules:
		module.on_player_joined(peer_id, player_id)
	player_joined.emit(player_id)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rpc_move_intent(sequence: Variant, direction: Variant, yaw: Variant) -> void:
	if _mode != Mode.SERVER:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = _peer_players.get(peer_id, "")
	if player_id.is_empty():
		reject_intent(peer_id, "move", NOT_JOINED)
		return
	var reason: String = IntentValidator.validate_move(sequence, direction, yaw)
	if not reason.is_empty():
		reject_intent(peer_id, "move", reason, player_id)
		return
	var now: int = Time.get_ticks_msec()
	if not _move_limiter.allow(peer_id, now):
		reject_intent(peer_id, "move", RATE_LIMITED, player_id)
		return
	reason = _world.set_move_input(player_id, int(sequence), direction as Vector2, float(yaw), now)
	if not reason.is_empty():
		count_rejection(reason)  # stale sequences are normal on unreliable channels


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_pickup(request_id: Variant, item_instance_id: Variant) -> void:
	if _mode != Mode.SERVER:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = _peer_players.get(peer_id, "")
	if player_id.is_empty():
		reject_intent(peer_id, "pickup", NOT_JOINED)
		return
	var reason: String = IntentValidator.validate_pickup(request_id, item_instance_id)
	if not reason.is_empty():
		reject_intent(peer_id, "pickup", reason, player_id)
		if typeof(request_id) == TYPE_INT:
			_rpc_pickup_result.rpc_id(peer_id, int(request_id), false, reason)
		return
	if not _pickup_limiter.allow(peer_id, Time.get_ticks_msec()):
		reject_intent(peer_id, "pickup", RATE_LIMITED, player_id)
		_rpc_pickup_result.rpc_id(peer_id, int(request_id), false, RATE_LIMITED)
		return
	var item_id: String = str(item_instance_id)
	var result: ActionResult = _world.try_pickup(player_id, item_id)
	if not result.ok:
		count_rejection(result.reason)
		_rpc_pickup_result.rpc_id(peer_id, int(request_id), false, _public_pickup_reason(peer_id, item_id, result.reason))
		return
	persist("item_picked_up")
	# P2-T15: a picked-up item whose units all merged into carried stacks no
	# longer exists. The stacks that grew reach the owner through InventoryNet.
	var picked: ItemInstance = _world.inventory.get_item(item_id)
	if picked != null:
		_rpc_inventory_item.rpc_id(peer_id, picked.to_dict())
	_rpc_pickup_result.rpc_id(peer_id, int(request_id), true, "")
	# P3-2: the item leaves the mirrors of the peers that were told about the
	# cell it lay in. Nobody else ever had it.
	for other: int in peers_interested_in(str(result.event.get("from_cell_id", ""))):
		if can_send_to(other):
			_rpc_world_item_removed.rpc_id(other, item_id)
	GameLogger.info("net", "pickup committed", {"peer_id": peer_id, "player_id": player_id, "entity_id": item_id, "request_id": int(request_id)})


## P3-2 (docs/00 ADR-009): the refusal a requester is told. About an item it
## was not told about it must learn nothing: an id that does not exist, an
## item somebody carries and an item lying in a cell outside the peer's
## interest (whatever the server's own range check found) all read
## `item_not_in_world`. Refusals about the requester itself (dead, resting,
## not in the world) and about an item it is told about (`too_far`,
## `inventory_full`) are passed on as they are. Counters and logs keep the
## server's own reason.
func _public_pickup_reason(peer_id: int, item_id: String, reason: String) -> String:
	if reason == InventoryService.REASON_UNKNOWN_ITEM:
		return InventoryService.REASON_NOT_IN_WORLD
	if reason != InventoryService.REASON_TOO_FAR and reason != InventoryService.REASON_INVENTORY_FULL:
		return reason
	return reason if is_cell_of_interest(peer_id, _world.cell_index.cell_of(item_id)) else InventoryService.REASON_NOT_IN_WORLD


func _broadcast_positions() -> void:
	if _peer_players.is_empty():
		return
	_snapshot_tick += 1
	var rows: Array = []
	for player_id: String in _world.online_player_ids():
		var state: PlayerState = _world.get_player(player_id)
		rows.append([player_id, state.position, state.yaw])
	for peer_id: int in _peer_players:
		if can_send_to(peer_id):
			_rpc_position_snapshot.rpc_id(peer_id, _snapshot_tick, rows)


## Server: counts and logs a rejected client intent (stable reason code).
func reject_intent(peer_id: int, intent: String, reason: String, player_id: String = "") -> void:
	count_rejection(reason)
	GameLogger.warning("net", "intent rejected", {"peer_id": peer_id, "player_id": player_id, "intent": intent, "reason": reason, "operation": "validate_intent"})


## Server: counts a rejection without logging (expected, e.g. stale input).
func count_rejection(reason: String) -> void:
	_rejections[reason] = _rejections.get(reason, 0) + 1


func _reject_join(peer_id: int, reason: String) -> void:
	_pending_peers.erase(peer_id)
	GameLogger.warning("net", "join rejected", {"peer_id": peer_id, "reason": reason, "operation": "request_join"})
	if can_send_to(peer_id):
		_rpc_join_rejected.rpc_id(peer_id, reason)
	_kick_at_msec[peer_id] = Time.get_ticks_msec() + int(_settings.reject_disconnect_delay_sec * MSEC_PER_SEC)


## True while the ENet peer is fully connected. Peers that are already
## disconnecting (e.g. several clients quitting at once) must not be sent to.
## Modules must guard every server->client send with this.
func can_send_to(peer_id: int) -> bool:
	if _peer == null:
		return false
	var packet_peer: ENetPacketPeer = _peer.get_peer(peer_id)
	return packet_peer != null and packet_peer.get_state() == ENetPacketPeer.STATE_CONNECTED


func _build_join_snapshot(player_id: String) -> Dictionary:
	var players: Array[Dictionary] = []
	for online_id: String in _world.online_player_ids():
		var state: PlayerState = _world.get_player(online_id)
		players.append({"player_id": online_id, "position": state.position, "yaw": state.yaw})
	# P3-2: the module fragments first. The interest module's fragment gives
	# the joining peer its cells; the world items below are cut to them.
	var modules: Dictionary = {}
	for module: NetModule in _modules:
		modules[str(module.name)] = module.build_join_fragment(player_id)
	var peer_id: int = peer_of_player(player_id)
	var items: Array[Dictionary] = []
	for item_id: String in _world.inventory.world_item_ids():
		if is_cell_of_interest(peer_id, _world.cell_index.cell_of(item_id)):
			items.append(_world.inventory.describe_world_item(item_id))
	var carried: Array[Dictionary] = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		carried.append(item.to_dict())
	return {"players": players, "world_items": items, "inventory": carried, SNAPSHOT_MODULES_KEY: modules}


## Server: captures the newest world state now (no-op without persistence).
## Normal requests write in the background; shutdown uses `wait` so no worker
## or coalesced newest state survives the server.
func persist(reason: String, wait: bool = false) -> void:
	if _persistence == null:
		return
	var error: Error = OK
	if wait:
		error = _persistence.save_now_and_wait(_world)
	else:
		_persistence.request_save(_world, _on_persist_completed.bind(reason))
		return
	if error != OK:
		GameLogger.error("save", "world save failed", {"world_id": _world.world_id, "reason": reason, "error": error_string(error), "operation": "persist"})


func _on_persist_completed(error: Error, reason: String) -> void:
	if error != OK and _world != null:
		GameLogger.error("save", "world save failed", {"world_id": _world.world_id, "reason": reason, "error": error_string(error), "operation": "persist"})


# ============================================================ client side

func _on_connected_to_server() -> void:
	GameLogger.info("net", "connected to server", {"peer_id": multiplayer.get_unique_id()})
	if _auto_join:
		send_join_request(BuildInfo.PROTOCOL_VERSION, BuildInfo.game_version(), _player_key)


func _on_connection_failed() -> void:
	GameLogger.error("net", "connection failed", {"operation": "connect"})
	connection_failed.emit()


func _on_server_disconnected() -> void:
	GameLogger.warning("net", "disconnected from server", {"player_id": client_state.local_player_id})
	server_disconnected.emit()


## Sends a join request. Arguments are Variant on purpose so tests can send
## malformed requests through the real RPC path.
func send_join_request(protocol_version: Variant, game_version: Variant, player_key: Variant) -> void:
	_rpc_request_join.rpc_id(SERVER_PEER_ID, protocol_version, game_version, player_key)


## Sends the current movement input (direction on XZ, |d| <= 1; facing).
func send_move_intent(direction: Vector2, yaw: float) -> void:
	_move_sequence += 1
	send_raw_move_intent(_move_sequence, direction, yaw)


## Sends an arbitrary move intent (tests use this to send malformed input
## through the real RPC path).
func send_raw_move_intent(sequence: Variant, direction: Variant, yaw: Variant) -> void:
	if _mode == Mode.CLIENT and not client_state.local_player_id.is_empty():
		_rpc_move_intent.rpc_id(SERVER_PEER_ID, sequence, direction, yaw)


## Asks the server to pick up a world item. Returns the request id that the
## `pickup_result` signal will carry.
func request_pickup(item_instance_id: String) -> int:
	_pickup_request_id += 1
	send_raw_pickup_request(_pickup_request_id, item_instance_id)
	return _pickup_request_id


## Sends an arbitrary pickup request (tests: malformed input via real RPC).
func send_raw_pickup_request(request_id: Variant, item_instance_id: Variant) -> void:
	if _mode == Mode.CLIENT and not client_state.local_player_id.is_empty():
		_rpc_request_pickup.rpc_id(SERVER_PEER_ID, request_id, item_instance_id)


## Client: true while handling an RPC sent by the server.
func is_from_server() -> bool:
	return _mode == Mode.CLIENT and multiplayer.get_remote_sender_id() == SERVER_PEER_ID


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_join_accepted(player_id: Variant, snapshot: Variant) -> void:
	if not is_from_server() or typeof(player_id) != TYPE_STRING or typeof(snapshot) != TYPE_DICTIONARY:
		return
	client_state.apply_join(str(player_id), snapshot as Dictionary)
	var fragments: Variant = (snapshot as Dictionary).get(SNAPSHOT_MODULES_KEY, {})
	for module: NetModule in _modules:
		var fragment: Variant = (fragments as Dictionary).get(str(module.name), {}) if typeof(fragments) == TYPE_DICTIONARY else {}
		module.apply_join_fragment(fragment as Dictionary if typeof(fragment) == TYPE_DICTIONARY else {})
	GameLogger.info("net", "joined world", {"player_id": player_id, "players": client_state.players.size(), "world_items": client_state.world_items.size()})
	join_accepted.emit(str(player_id))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_join_rejected(reason: Variant) -> void:
	if not is_from_server():
		return
	GameLogger.warning("net", "join rejected by server", {"reason": str(reason)})
	join_rejected.emit(str(reason))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_player_joined(player_id: Variant, position: Variant, yaw: Variant) -> void:
	if not is_from_server() or typeof(player_id) != TYPE_STRING or typeof(position) != TYPE_VECTOR3 or typeof(yaw) != TYPE_FLOAT:
		return
	client_state.apply_player_joined(str(player_id), position as Vector3, float(yaw))
	player_joined.emit(str(player_id))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_player_left(player_id: Variant) -> void:
	if not is_from_server() or typeof(player_id) != TYPE_STRING:
		return
	client_state.apply_player_left(str(player_id))
	player_left.emit(str(player_id))


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _rpc_position_snapshot(tick: Variant, rows: Variant) -> void:
	if not is_from_server() or typeof(tick) != TYPE_INT or typeof(rows) != TYPE_ARRAY:
		return
	client_state.apply_position_snapshot(int(tick), rows as Array)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_pickup_result(request_id: Variant, ok: Variant, reason: Variant) -> void:
	if not is_from_server() or typeof(request_id) != TYPE_INT or typeof(ok) != TYPE_BOOL or typeof(reason) != TYPE_STRING:
		return
	pickup_result.emit(int(request_id), bool(ok), str(reason))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_world_item_removed(item_instance_id: Variant) -> void:
	if not is_from_server() or typeof(item_instance_id) != TYPE_STRING:
		return
	client_state.apply_world_item_removed(str(item_instance_id))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_inventory_item(item: Variant) -> void:
	if not is_from_server() or typeof(item) != TYPE_DICTIONARY:
		return
	client_state.apply_inventory_item(item as Dictionary)
