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
## Initial state is sent inside _rpc_join_accepted; later deltas use the same
## reliable channel, so they always arrive after the snapshot.

signal server_started(port: int)
signal join_accepted(player_id: String)
signal join_rejected(reason: String)
signal connection_failed
signal server_disconnected
## Server and client: a player became visible / went away.
signal player_joined(player_id: String)
signal player_left(player_id: String)

enum Mode { NONE, SERVER, CLIENT }

const SERVER_PEER_ID: int = 1
const REASON_SERVER_FULL: String = "server_full"
const REASON_ALREADY_JOINED: String = "already_joined"
const REASON_KEY_IN_USE: String = "player_key_in_use"
const REASON_HANDSHAKE_TIMEOUT: String = "handshake_timeout"
const MSEC_PER_SEC: float = 1000.0

var client_state: ClientWorldState = ClientWorldState.new()

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
# --- client state ---
var _player_key: String = ""
var _auto_join: bool = true


# ============================================================ lifecycle

## Starts listening. `persistence` may be null (no saving, tests only).
func start_server(world: ServerWorld, persistence: WorldPersistence, settings: NetworkSettings, port: int) -> Error:
	if _mode != Mode.NONE:
		return ERR_ALREADY_IN_USE
	_settings = settings
	_world = world
	_persistence = persistence
	_peer = ENetMultiplayerPeer.new()
	if settings.bind_address != "*":
		_peer.set_bind_ip(settings.bind_address)
	var error: Error = _peer.create_server(port, settings.max_players + NetworkSettings.TRANSPORT_HEADROOM, NetworkSettings.CHANNEL_COUNT)
	if error != OK:
		GameLogger.error("net", "failed to start server", {"port": port, "error": error_string(error), "operation": "start_server"})
		_peer = null
		return error
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_mode = Mode.SERVER
	GameLogger.info("net", "server listening", {"port": port, "max_players": settings.max_players, "protocol": BuildInfo.PROTOCOL_VERSION, "world_id": world.world_id})
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
	multiplayer.multiplayer_peer = _peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_mode = Mode.CLIENT
	GameLogger.info("net", "connecting", {"address": address, "port": port})
	return OK


## Closes the connection. A server saves the world first.
func stop() -> void:
	if _mode == Mode.NONE:
		return
	if _mode == Mode.SERVER:
		for peer_id: int in _peer_players.keys():
			_world.leave(_peer_players[peer_id])
		_peer_players.clear()
		_persist("shutdown")
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


## Server: number of peers that completed the handshake.
func joined_peer_count() -> int:
	return _peer_players.size()


func _process(delta: float) -> void:
	if _mode == Mode.SERVER:
		_server_process(delta)


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
	_world.leave(player_id)
	_persist("player_left")
	for other: int in _peer_players:
		if _can_send_to(other):
			_rpc_player_left.rpc_id(other, player_id)
	GameLogger.info("net", "player disconnected", {"peer_id": peer_id, "player_id": player_id})
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
			_persist("autosave")


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
	for other: int in _peer_players:
		if other != peer_id and _can_send_to(other):
			_rpc_player_joined.rpc_id(other, state.player_id, state.position, state.yaw)
	GameLogger.info("net", "join accepted", {"peer_id": peer_id, "player_id": state.player_id, "client_game_version": str(game_version)})
	player_joined.emit(state.player_id)


func _reject_join(peer_id: int, reason: String) -> void:
	_pending_peers.erase(peer_id)
	GameLogger.warning("net", "join rejected", {"peer_id": peer_id, "reason": reason, "operation": "request_join"})
	if _can_send_to(peer_id):
		_rpc_join_rejected.rpc_id(peer_id, reason)
	_kick_at_msec[peer_id] = Time.get_ticks_msec() + int(_settings.reject_disconnect_delay_sec * MSEC_PER_SEC)


## True while the ENet peer is fully connected. Peers that are already
## disconnecting (e.g. several clients quitting at once) must not be sent to.
func _can_send_to(peer_id: int) -> bool:
	if _peer == null:
		return false
	var packet_peer: ENetPacketPeer = _peer.get_peer(peer_id)
	return packet_peer != null and packet_peer.get_state() == ENetPacketPeer.STATE_CONNECTED


func _build_join_snapshot(player_id: String) -> Dictionary:
	var players: Array[Dictionary] = []
	for online_id: String in _world.online_player_ids():
		var state: PlayerState = _world.get_player(online_id)
		players.append({"player_id": online_id, "position": state.position, "yaw": state.yaw})
	var items: Array[Dictionary] = []
	for item_id: String in _world.inventory.world_item_ids():
		items.append(_world.inventory.describe_world_item(item_id))
	var carried: Array[Dictionary] = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		carried.append(item.to_dict())
	return {"players": players, "world_items": items, "inventory": carried}


func _persist(reason: String) -> void:
	if _persistence == null:
		return
	var error: Error = _persistence.save(_world)
	if error != OK:
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


func _is_from_server() -> bool:
	return _mode == Mode.CLIENT and multiplayer.get_remote_sender_id() == SERVER_PEER_ID


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_join_accepted(player_id: Variant, snapshot: Variant) -> void:
	if not _is_from_server() or typeof(player_id) != TYPE_STRING or typeof(snapshot) != TYPE_DICTIONARY:
		return
	client_state.apply_join(str(player_id), snapshot as Dictionary)
	GameLogger.info("net", "joined world", {"player_id": player_id, "players": client_state.players.size(), "world_items": client_state.world_items.size()})
	join_accepted.emit(str(player_id))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_join_rejected(reason: Variant) -> void:
	if not _is_from_server():
		return
	GameLogger.warning("net", "join rejected by server", {"reason": str(reason)})
	join_rejected.emit(str(reason))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_player_joined(player_id: Variant, position: Variant, yaw: Variant) -> void:
	if not _is_from_server() or typeof(player_id) != TYPE_STRING or typeof(position) != TYPE_VECTOR3 or typeof(yaw) != TYPE_FLOAT:
		return
	client_state.apply_player_joined(str(player_id), position as Vector3, float(yaw))
	player_joined.emit(str(player_id))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_player_left(player_id: Variant) -> void:
	if not _is_from_server() or typeof(player_id) != TYPE_STRING:
		return
	client_state.apply_player_left(str(player_id))
	player_left.emit(str(player_id))
