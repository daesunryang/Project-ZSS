class_name NpcDebugNetModule
extends NetModule
## Development-only private NPC debug subscription (P4-8). One peer may
## subscribe to one NPC. The server samples at the configured 2 Hz only when
## enabled, authorized, interested and connected; otherwise NpcDebugQuery is
## never called.

const MODULE_NAME: String = "NpcDebugNet"
const INTENT_SUBSCRIBE: String = "npc_debug_subscribe"
const INTENT_UNSUBSCRIBE: String = "npc_debug_unsubscribe"
const REASON_SERVER_DISABLED: String = "server_debug_disabled"
const REASON_NOT_ALLOWED: String = "npc_debug_not_allowed"
const REASON_BAD_NPC_ID: String = "bad_npc_id"
const REASON_UNAVAILABLE: String = "npc_debug_unavailable"

var client_state: NpcDebugClientState = NpcDebugClientState.new()
var sent_snapshot_count: int = 0
var sent_missing_count: int = 0
var rejected_request_count: int = 0
var ignored_sender_count: int = 0

var _settings: NpcDebugSettings
var _world: ServerWorld = null
var _npcs: NpcService = null
var _query: NpcDebugQuery = null
var _limiter: RateLimiter = null
var _subscriptions: Dictionary[int, String] = {}
var _sample_elapsed: float = 0.0


func _init(settings: NpcDebugSettings = null) -> void:
	name = MODULE_NAME
	_settings = settings if settings != null else NpcDebugSettings.new()


func on_server_started(world: ServerWorld) -> void:
	_world = world
	_npcs = world.get_system(NpcService.SYSTEM_ID) as NpcService
	_query = NpcDebugQuery.from_world(world)
	_limiter = RateLimiter.new(_settings.request_rate_per_sec, _settings.request_burst)
	if _query == null or _npcs == null:
		GameLogger.warning("net", "npc debug query is unavailable", {"world_id": world.world_id, "module": MODULE_NAME, "operation": "start"})


func on_player_left(peer_id: int, _player_id: String) -> void:
	_subscriptions.erase(peer_id)
	if _limiter != null:
		_limiter.forget(peer_id)


func server_physics(delta: float) -> void:
	if not _settings.enabled or _query == null or _npcs == null or _subscriptions.is_empty():
		return
	_sample_elapsed += delta
	var period: float = 1.0 / _settings.update_rate_hz
	if _sample_elapsed + 0.000001 < period:
		return
	_sample_elapsed = fmod(_sample_elapsed, period)
	for peer_id: int in _subscriptions.keys():
		if not network.can_send_to(peer_id) or not _is_allowed_peer(peer_id):
			_subscriptions.erase(peer_id)
			continue
		var npc_id: String = _subscriptions[peer_id]
		var payload: Dictionary = _missing(npc_id)
		if _npcs.has_npc(npc_id) and network.is_cell_of_interest(peer_id, _world.cell_index.cell_of(npc_id)):
			payload = _query.inspect_npc(npc_id)
		else:
			sent_missing_count += 1
		_rpc_debug_snapshot.rpc_id(peer_id, npc_id, bool(payload.get("found", false)), payload)
		sent_snapshot_count += 1


func build_join_fragment(player_id: String) -> Dictionary:
	var peer_id: int = network.peer_of_player(player_id)
	var allowed: bool = _settings.enabled and _is_allowed_player(player_id)
	return _status_payload(peer_id, "" if allowed else (REASON_SERVER_DISABLED if not _settings.enabled else REASON_NOT_ALLOWED))


func apply_join_fragment(fragment: Dictionary) -> void:
	client_state.apply_join(fragment)


func subscription_count() -> int:
	return _subscriptions.size()


func query_inspect_count() -> int:
	return _query.inspect_count if _query != null else 0


func request_subscribe(npc_id: String) -> bool:
	if network == null or not network.is_client() or not NpcState.is_valid_npc_id(npc_id):
		return false
	_rpc_request_subscribe.rpc_id(NetworkService.SERVER_PEER_ID, npc_id)
	return true


func request_unsubscribe() -> bool:
	if network == null or not network.is_client():
		return false
	_rpc_request_unsubscribe.rpc_id(NetworkService.SERVER_PEER_ID)
	return true


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_subscribe(npc_id: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		_refuse(peer_id, NetworkService.NOT_JOINED, INTENT_SUBSCRIBE)
		return
	if not _settings.enabled:
		_refuse(peer_id, REASON_SERVER_DISABLED, INTENT_SUBSCRIBE)
		return
	if not _is_allowed_player(player_id):
		_refuse(peer_id, REASON_NOT_ALLOWED, INTENT_SUBSCRIBE)
		return
	if typeof(npc_id) != TYPE_STRING or not NpcState.is_valid_npc_id(str(npc_id)):
		_refuse(peer_id, REASON_BAD_NPC_ID, INTENT_SUBSCRIBE)
		return
	if _query == null or _npcs == null:
		_refuse(peer_id, REASON_UNAVAILABLE, INTENT_SUBSCRIBE)
		return
	if _limiter != null and not _limiter.allow(peer_id, Time.get_ticks_msec()):
		_refuse(peer_id, NetworkService.RATE_LIMITED, INTENT_SUBSCRIBE)
		return
	var first: bool = _subscriptions.is_empty()
	_subscriptions[peer_id] = str(npc_id)
	if first:
		_sample_elapsed = 0.0
	_send_status(peer_id, "")


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_unsubscribe() -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		_refuse(peer_id, NetworkService.NOT_JOINED, INTENT_UNSUBSCRIBE)
		return
	if _limiter != null and not _limiter.allow(peer_id, Time.get_ticks_msec()):
		_refuse(peer_id, NetworkService.RATE_LIMITED, INTENT_UNSUBSCRIBE)
		return
	_subscriptions.erase(peer_id)
	_send_status(peer_id, "" if _settings.enabled and _is_allowed_player(player_id) else (REASON_SERVER_DISABLED if not _settings.enabled else REASON_NOT_ALLOWED))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_debug_status(payload: Variant) -> void:
	if not _from_server("npc_debug_status") or typeof(payload) != TYPE_DICTIONARY:
		return
	client_state.apply_status(payload as Dictionary)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_debug_snapshot(npc_id: Variant, found: Variant, payload: Variant) -> void:
	if not _from_server("npc_debug_snapshot"):
		return
	client_state.apply_snapshot(npc_id, found, payload)


func _refuse(peer_id: int, reason: String, intent: String) -> void:
	rejected_request_count += 1
	_subscriptions.erase(peer_id)
	network.reject_intent(peer_id, intent, reason, network.player_of_peer(peer_id))
	_send_status(peer_id, reason)


func _send_status(peer_id: int, reason: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_debug_status.rpc_id(peer_id, _status_payload(peer_id, reason))


func _status_payload(peer_id: int, reason: String) -> Dictionary:
	var player_id: String = network.player_of_peer(peer_id) if network != null else ""
	return {
		NpcDebugClientState.KEY_SCHEMA_VERSION: NpcDebugClientState.SCHEMA_VERSION,
		NpcDebugClientState.KEY_SERVER_ENABLED: _settings.enabled,
		NpcDebugClientState.KEY_ALLOWED: _settings.enabled and _is_allowed_player(player_id),
		NpcDebugClientState.KEY_REASON: reason,
		NpcDebugClientState.KEY_SUBSCRIBED_NPC_ID: _subscriptions.get(peer_id, ""),
		NpcDebugClientState.KEY_UPDATE_RATE_HZ: _settings.update_rate_hz if _settings.enabled else 0.0,
	}


func _is_allowed_peer(peer_id: int) -> bool:
	return _is_allowed_player(network.player_of_peer(peer_id))


func _is_allowed_player(player_id: String) -> bool:
	var player: PlayerState = _world.get_player(player_id) if _world != null else null
	return player != null and _settings.allows(player.player_key)


func _missing(npc_id: String) -> Dictionary:
	return {NpcDebugClientState.KEY_SCHEMA_VERSION: NpcDebugQuery.SCHEMA_VERSION, "found": false, "npc_id": npc_id}


func _from_server(message: String) -> bool:
	if network != null and network.is_from_server():
		return true
	ignored_sender_count += 1
	GameLogger.warning("net", "npc debug payload not sent by the server ignored", {"message": message, "sender": multiplayer.get_remote_sender_id() if is_inside_tree() else 0, "operation": "receive"})
	return false
