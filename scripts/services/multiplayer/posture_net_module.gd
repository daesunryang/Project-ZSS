class_name PostureNetModule
extends NetModule
## The wanted-posture intent and replication of player postures (P2-T11,
## docs/09 §14.26). Network only: every rule is in PostureService.
##
## RPC table (channel 0 = reliable ordered):
##   client -> server  _rpc_request_posture(request_id:int, posture:String)        reliable, ch0
##   server -> owner   _rpc_posture_result(request_id:int, ok:bool, reason:String)  reliable, ch0
##   server -> clients _rpc_posture_rows(rows:Array[{player_id, posture}])          reliable, ch0
##
## Intent: a client sends its own request id and the posture it WANTS
## ("standing", "prone" or "resting"), not a toggle: a mirror that is one
## step behind then gets a refusal instead of the opposite action. There is
## no player argument (the actor is the player of the sending peer) and no
## position, speed or "I am hidden" argument: whether a player is prone, how
## fast it crawls and how well it is seen are decided on the server.
## "resting" / "standing" from a rest are the rest intent of SurvivalNet
## (docs/09 §14.23) in another shape: both end in SurvivalService.start_rest
## / stop_rest and follow the same rules. Server checks, in order: joined
## (`not_joined`), argument types (`bad_type`), request id >= 0
## (`bad_sequence`), a known posture name (`bad_posture`), request rate
## (`rate_limited`), then the rule (`not_online`, `player_dead`,
## `already_in_posture`, `already_resting`, `cannot_rest_<danger>`, ...).
## Every refusal is counted (NetworkService.rejected_intent_count) and
## changes nothing. The result goes to the requester only; `reason` is ""
## exactly when ok.
##
## Replication: a posture is a fact anybody can see (docs/00 ADR-009), so
## every joined peer gets every change as a row {player_id, posture}, and a
## joining peer gets the rows of everybody in the world in its join
## fragment. Nothing else is in a row: not why the posture changed, not how
## well the player is seen. An accepted request is replicated before its
## result is sent (same ordered channel).
##
## Client surface (presentation): request_posture(), the `posture_result`
## signal and the mirror `client_state`. The mirror has no authority.

## Client: answer to one of this client's own posture requests.
signal posture_result(request_id: int, ok: bool, reason: String)

const MODULE_NAME: String = "PostureNet"
## Join fragment format.
const SCHEMA_VERSION: int = 1
## Intent name in rejection logs.
const INTENT_POSTURE: String = "posture"
## Returned by request_posture() when nothing was sent.
const NO_REQUEST: int = 0
## Longest reason code a client accepts in a result.
const REASON_MAX_LENGTH: int = 64
## Longest posture name the server looks at.
const POSTURE_NAME_MAX_LENGTH: int = 16

var client_state: ClientPostureState
## Client: results from the server that failed validation.
var rejected_payload_count: int = 0

var _settings: PostureNetSettings
# --- server state ---
var _world: ServerWorld = null
var _posture: PostureService = null
var _limiter: RateLimiter = null
# --- client state ---
var _last_request_id: int = NO_REQUEST


func _init(settings: PostureNetSettings) -> void:
	name = MODULE_NAME
	_settings = settings
	client_state = ClientPostureState.new(settings)


func _ready() -> void:
	if network != null and not network.player_left.is_connected(_on_network_player_left):
		network.player_left.connect(_on_network_player_left)


# ------------------------------------------------------------ pure rules

## "" when the arguments of a posture request are usable, otherwise a reason
## code. Types first, so wrongly typed input never reaches a conversion.
static func validate_posture_request(request_id: Variant, posture: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(posture) != TYPE_STRING:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	var posture_name: String = posture
	if posture_name.length() > POSTURE_NAME_MAX_LENGTH or PlayerPosture.from_name(posture_name) == PlayerPosture.INVALID:
		return PostureService.REASON_BAD_POSTURE
	return ""


# ------------------------------------------------------------ NetModule hooks

func on_server_started(world: ServerWorld) -> void:
	_world = world
	_posture = world.get_system(PostureService.SYSTEM_ID) as PostureService
	_limiter = RateLimiter.new(_settings.posture_intent_rate_per_sec, _settings.posture_intent_burst)


func on_player_left(peer_id: int, _player_id: String) -> void:
	if _limiter != null:
		_limiter.forget(peer_id)


func build_join_fragment(_player_id: String) -> Dictionary:
	if _world == null or _posture == null:
		return {}
	var rows: Array[Dictionary] = []
	for online_id: String in _world.online_player_ids():
		rows.append(_make_row(online_id, _posture.posture_of(online_id)))
	return {"schema_version": SCHEMA_VERSION, "players": rows}


func apply_join_fragment(fragment: Dictionary) -> void:
	_last_request_id = NO_REQUEST
	client_state.apply_join(network.client_state.local_player_id, fragment)


func server_physics(_delta: float) -> void:
	if _posture != null:
		_send_events(_posture.drain_events())


# ------------------------------------------------------------ server side

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_posture(request_id: Variant, posture: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The actor is whoever owns the sending peer, never an argument.
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, INTENT_POSTURE, NetworkService.NOT_JOINED)
		return
	var reason: String = validate_posture_request(request_id, posture)
	if not reason.is_empty():
		network.reject_intent(peer_id, INTENT_POSTURE, reason, player_id)
		if typeof(request_id) == TYPE_INT and int(request_id) >= 0:
			_send_result(peer_id, int(request_id), false, reason)
		return
	if not _limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, INTENT_POSTURE, NetworkService.RATE_LIMITED, player_id)
		_send_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED)
		return
	if _posture == null:
		network.reject_intent(peer_id, INTENT_POSTURE, PostureService.REASON_UNAVAILABLE, player_id)
		_send_result(peer_id, int(request_id), false, PostureService.REASON_UNAVAILABLE)
		return
	var result: ActionResult = _posture.request_posture(_world, player_id, PlayerPosture.from_name(str(posture)))
	if not result.ok:
		# Refusals by game state are normal play: counted, not logged as warnings.
		network.count_rejection(result.reason)
		_send_result(peer_id, int(request_id), false, result.reason)
		return
	# Replicate the change now, so everybody learns it before the requester
	# gets the answer (same ordered channel).
	_send_events(_posture.drain_events())
	_send_result(peer_id, int(request_id), true, "")
	GameLogger.info("net", "posture request accepted", {"peer_id": peer_id, "player_id": player_id, "request_id": int(request_id), "posture": str(posture)})


func _send_result(peer_id: int, request_id: int, ok: bool, reason: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_posture_result.rpc_id(peer_id, request_id, ok, reason)


## Sends the posture each event ends in to every joined peer. Only the
## player and its posture leave the server.
func _send_events(events: Array[Dictionary]) -> void:
	if events.is_empty():
		return
	var rows: Array = []
	for event: Dictionary in events:
		var player_id: String = str(event.get("player_id", ""))
		var posture: int = PlayerPosture.from_name(str(event.get("posture", "")))
		if player_id.is_empty() or posture == PlayerPosture.INVALID:
			GameLogger.warning("posture_net", "posture event not replicated", {"event_type": str(event.get("event_type", "")), "operation": "replicate_event"})
			continue
		rows.append(_make_row(player_id, posture as PlayerPosture.Kind))
	if rows.is_empty():
		return
	for peer_id: int in network.joined_peers():
		if network.can_send_to(peer_id):
			_rpc_posture_rows.rpc_id(peer_id, rows)


func _make_row(player_id: String, posture: PlayerPosture.Kind) -> Dictionary:
	return {ClientPostureState.KEY_PLAYER_ID: player_id, ClientPostureState.KEY_POSTURE: PlayerPosture.name_of(posture)}


func _on_network_player_left(player_id: String) -> void:
	if network != null and network.is_client():
		client_state.remove_player(player_id)


# ------------------------------------------------------------ client side

## Asks the server for a posture (stand, go prone, lie down to sleep).
## Returns the request id the `posture_result` signal will carry, or
## NO_REQUEST when nothing was sent (not a joined client). Nothing is decided
## here.
func request_posture(posture: PlayerPosture.Kind) -> int:
	if network == null or not network.is_client() or network.client_state.local_player_id.is_empty():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_posture_request(_last_request_id, PlayerPosture.name_of(posture))
	return _last_request_id


## Sends an arbitrary request without any client-side check (tests:
## malformed or premature input through the real RPC path).
func send_raw_posture_request(request_id: Variant, posture: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_posture.rpc_id(NetworkService.SERVER_PEER_ID, request_id, posture)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_posture_result(request_id: Variant, ok: Variant, reason: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if typeof(request_id) != TYPE_INT or typeof(ok) != TYPE_BOOL or typeof(reason) != TYPE_STRING:
		_reject_result()
		return
	var reason_code: String = reason
	# "" exactly when the request was accepted.
	if int(request_id) < 0 or reason_code.length() > REASON_MAX_LENGTH or bool(ok) != reason_code.is_empty():
		_reject_result()
		return
	posture_result.emit(int(request_id), bool(ok), reason_code)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_posture_rows(rows: Variant) -> void:
	if network == null or not network.is_from_server() or typeof(rows) != TYPE_ARRAY:
		return
	client_state.apply_rows(rows as Array)


func _reject_result() -> void:
	rejected_payload_count += 1
	GameLogger.warning("posture_net", "posture result dropped", {"module": MODULE_NAME, "operation": "apply_payload"})
