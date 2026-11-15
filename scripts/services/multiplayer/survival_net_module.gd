class_name SurvivalNetModule
extends NetModule
## Survival replication and the rest intent (docs/09 §14.14, §14.23).
## Network only: every rule is in SurvivalService.
##
## RPC table (channel 0 = reliable ordered):
##   client -> server  _rpc_request_rest(request_id:int, lie_down:bool)          reliable, ch0
##   server -> owner   _rpc_rest_result(request_id:int, ok:bool, reason:String)  reliable, ch0
##   server -> owner   _rpc_survival_owner_snapshot(snapshot:Dictionary)         reliable, ch0
##   server -> clients _rpc_survival_status(status:Dictionary)                   reliable, ch0
##   server -> clients _rpc_survival_events(events:Array[Dictionary])            reliable, ch0
##
## Replication: detailed vitals, needs, wounds and infection are owner-only;
## other clients receive only alive/dead, respawn position, observable wound
## facts and whether a player is lying down (docs/00 ADR-009).
##
## Rest intent (P2-T8): the only client -> server RPC of this module. A
## client sends its own request id and the state it wants (true = lie down,
## false = get up); there is no player argument, the actor is the player of
## the sending peer. Server checks, in order: joined (`not_joined`), argument
## types (`bad_type`), request id >= 0 (`bad_sequence`), request rate
## (`rate_limited`), then SurvivalService's own rules (`player_dead`,
## `already_resting`, `not_resting`, ...). Every refusal is counted
## (NetworkService.rejected_intent_count) and changes nothing. The result
## goes to the requester only, for every request of a joined peer whose
## request id is usable (int >= 0); `reason` is "" exactly when ok. An
## accepted request is replicated before its result is sent: the requester
## gets the owner event, everybody else the public event (same ordered
## channel).
##
## Client surface (presentation): request_rest(), the `rest_result` signal
## and the mirror `client_state`. The mirror has no authority.

## Client: answer to one of this client's own rest requests.
signal rest_result(request_id: int, ok: bool, reason: String)

const MODULE_NAME: String = "SurvivalNet"
## Join fragment / owner snapshot format. 2 (P2-T4): the owner snapshot
## carries "character_generation". 3 (P2-T8): the owner snapshot and every
## status row carry "resting".
const SCHEMA_VERSION: int = 3
## Intent name in rejection logs.
const INTENT_REST: String = "rest"
## Returned by request_rest() when nothing was sent.
const NO_REQUEST: int = 0
## Longest reason code a client accepts in a result.
const REASON_MAX_LENGTH: int = 64
## The world has no survival system (composition error).
const REASON_UNAVAILABLE: String = "rest_unavailable"

var client_state: ClientSurvivalState
## Client: rest results from the server that failed validation.
var rejected_payload_count: int = 0

var _net_settings: SurvivalNetSettings
var _survival_settings: SurvivalSettings
# --- server state ---
var _world: ServerWorld = null
var _survival: SurvivalService = null
var _rest_limiter: RateLimiter = null
var _snapshot_elapsed: float = 0.0
var _last_owner_snapshots: Dictionary[String, Dictionary] = {}
# --- client state ---
var _last_rest_request_id: int = NO_REQUEST


func _init(net_settings: SurvivalNetSettings, survival_settings: SurvivalSettings) -> void:
	name = MODULE_NAME
	_net_settings = net_settings
	_survival_settings = survival_settings
	client_state = ClientSurvivalState.new(net_settings, survival_settings)


func _ready() -> void:
	if network != null and not network.player_left.is_connected(_on_network_player_left):
		network.player_left.connect(_on_network_player_left)


# ------------------------------------------------------------ pure rules

## "" when the arguments of a rest request are usable, otherwise a reason
## code. Types first, so wrongly typed input never reaches a conversion.
static func validate_rest_request(request_id: Variant, lie_down: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(lie_down) != TYPE_BOOL:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	return ""


# ------------------------------------------------------------ NetModule hooks

func on_server_started(world: ServerWorld) -> void:
	_world = world
	_survival = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	_rest_limiter = RateLimiter.new(_net_settings.rest_intent_rate_per_sec, _net_settings.rest_intent_burst)


func on_player_joined(_peer_id: int, player_id: String) -> void:
	if _survival == null:
		return
	var status: Dictionary = _make_status(player_id)
	for peer_id: int in network.joined_peers():
		if network.can_send_to(peer_id):
			_rpc_survival_status.rpc_id(peer_id, status)


func on_player_left(peer_id: int, player_id: String) -> void:
	_last_owner_snapshots.erase(player_id)
	if _rest_limiter != null:
		_rest_limiter.forget(peer_id)


func build_join_fragment(player_id: String) -> Dictionary:
	if _world == null or _survival == null:
		return {}
	var statuses: Array[Dictionary] = []
	for online_id: String in _world.online_player_ids():
		statuses.append(_make_status(online_id))
	# P2-T9: a player without a character has no vitals and is not in the
	# world. It still learns who is: the fragment has no "self" then. Its own
	# status row and owner snapshot follow once its character exists
	# (on_player_joined, _send_changed_owner_snapshots).
	if not _survival.has_player(player_id) or not _world.is_online(player_id):
		return {"schema_version": SCHEMA_VERSION, "players": statuses}
	var own: Dictionary = _make_owner_snapshot(player_id)
	_last_owner_snapshots[player_id] = own.duplicate(true)
	return {"schema_version": SCHEMA_VERSION, "self": own, "players": statuses}


func apply_join_fragment(fragment: Dictionary) -> void:
	_last_rest_request_id = NO_REQUEST
	client_state.apply_join(network.client_state.local_player_id, fragment)


func server_physics(delta: float) -> void:
	if _survival == null:
		return
	_send_events(_survival.drain_events())
	_snapshot_elapsed += delta
	var period: float = 1.0 / _net_settings.owner_snapshot_rate_hz
	if _snapshot_elapsed < period:
		return
	_snapshot_elapsed = fmod(_snapshot_elapsed, period)
	_send_changed_owner_snapshots()


# ------------------------------------------------------------ server side

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_rest(request_id: Variant, lie_down: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The actor is whoever owns the sending peer, never an argument.
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, INTENT_REST, NetworkService.NOT_JOINED)
		return
	var reason: String = validate_rest_request(request_id, lie_down)
	if not reason.is_empty():
		network.reject_intent(peer_id, INTENT_REST, reason, player_id)
		if typeof(request_id) == TYPE_INT and int(request_id) >= 0:
			_send_rest_result(peer_id, int(request_id), false, reason)
		return
	if not _rest_limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, INTENT_REST, NetworkService.RATE_LIMITED, player_id)
		_send_rest_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED)
		return
	if _survival == null:
		network.reject_intent(peer_id, INTENT_REST, REASON_UNAVAILABLE, player_id)
		_send_rest_result(peer_id, int(request_id), false, REASON_UNAVAILABLE)
		return
	var result: ActionResult = _survival.start_rest(player_id) if bool(lie_down) else _survival.stop_rest(player_id)
	if not result.ok:
		# Refusals by game state are normal play: counted, not logged as warnings.
		network.count_rejection(result.reason)
		_send_rest_result(peer_id, int(request_id), false, result.reason)
		return
	# Replicate the change now, so everybody learns it before the requester
	# gets the answer (same ordered channel).
	_send_events(_survival.drain_events())
	_send_rest_result(peer_id, int(request_id), true, "")
	GameLogger.info("net", "rest request accepted", {"peer_id": peer_id, "player_id": player_id, "request_id": int(request_id), "lie_down": bool(lie_down)})


func _send_rest_result(peer_id: int, request_id: int, ok: bool, reason: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_rest_result.rpc_id(peer_id, request_id, ok, reason)


func _send_events(events: Array[Dictionary]) -> void:
	if events.is_empty():
		return
	var by_peer: Dictionary = {}
	for source: Dictionary in events:
		var player_id: String = str(source.get("player_id", ""))
		if player_id.is_empty():
			GameLogger.warning("survival_net", "survival event without player ignored", {"event_type": str(source.get("event_type", "")), "operation": "replicate_event"})
			continue
		var owner_peer: int = network.peer_of_player(player_id)
		var owner_event: Dictionary = _owner_event(source)
		if owner_peer != 0 and not owner_event.is_empty():
			_append_peer_event(by_peer, owner_peer, owner_event)
		var public_event: Dictionary = _public_event(source)
		if public_event.is_empty():
			continue
		for peer_id: int in network.joined_peers():
			if peer_id != owner_peer:
				_append_peer_event(by_peer, peer_id, public_event)
	for peer_id: int in by_peer:
		if network.can_send_to(peer_id):
			_rpc_survival_events.rpc_id(peer_id, by_peer[peer_id])


func _send_changed_owner_snapshots() -> void:
	for peer_id: int in network.joined_peers():
		var player_id: String = network.player_of_peer(peer_id)
		if player_id.is_empty() or not _survival.has_player(player_id):
			continue
		var snapshot: Dictionary = _make_owner_snapshot(player_id)
		if _last_owner_snapshots.get(player_id, {}) == snapshot:
			continue
		_last_owner_snapshots[player_id] = snapshot.duplicate(true)
		if network.can_send_to(peer_id):
			_rpc_survival_owner_snapshot.rpc_id(peer_id, snapshot)


func _make_owner_snapshot(player_id: String) -> Dictionary:
	var vitals: PlayerVitals = _survival.get_vitals(player_id)
	var needs: Dictionary = {}
	for kind_index: int in NeedKind.KIND_NAMES.size():
		var kind: NeedKind.Kind = kind_index as NeedKind.Kind
		needs[NeedKind.kind_name(kind)] = NeedKind.category_name(_survival.need_category(player_id, kind))
	var wounds: Array[Dictionary] = []
	for wound: Wound in vitals.injuries:
		wounds.append(wound.to_dict())
	return {
		"schema_version": SCHEMA_VERSION,
		"player_id": player_id,
		"alive": vitals.is_alive(),
		"health": vitals.health,
		"stamina": vitals.stamina,
		"needs": needs,
		"wounds": wounds,
		"infection_stage": InfectionState.stage_name(vitals.infection.stage),
		# Which character of the player this is (docs/00 ADR-007). Owner only.
		"character_generation": _world.get_player(player_id).character_generation,
		# Lying down to rest (P2-T8). Also in the public status rows.
		"resting": _survival.is_resting(player_id),
	}


## Public row of one player: alive / dead and standing / lying down. Both
## are facts anybody near the player can see (docs/00 ADR-009).
func _make_status(player_id: String) -> Dictionary:
	return {"player_id": player_id, "alive": _survival.is_alive(player_id), "resting": _survival.is_resting(player_id)}


func _owner_event(source: Dictionary) -> Dictionary:
	var common: Dictionary = {
		"scope": ClientSurvivalState.SCOPE_OWNER,
		"event_type": str(source.get("event_type", "")),
		"player_id": str(source.get("player_id", "")),
	}
	match str(common["event_type"]):
		SurvivalService.EVENT_PLAYER_WOUNDED:
			common.merge({"source_id": source["source_id"], "damage": source["damage"], "health_after": source["health_after"], "died": source["died"], "world_time": source["world_time"], "wound": source["wound"]})
		SurvivalService.EVENT_PLAYER_BLEEDING_STOPPED:
			common.merge({"wound_id": source["wound_id"], "world_time": source["world_time"]})
		SurvivalService.EVENT_PLAYER_SURVIVAL_DAMAGE:
			common.merge({"cause": source["cause"], "damage": source["damage"], "health_after": source["health_after"], "world_time": source["world_time"]})
		SurvivalService.EVENT_PLAYER_DIED:
			common.merge({"cause": source["cause"], "world_time": source["world_time"]})
		SurvivalService.EVENT_PLAYER_RESPAWNED:
			common.merge({"position": source["position"], "world_time": source["world_time"]})
		SurvivalService.EVENT_PLAYER_INFECTED, SurvivalService.EVENT_INFECTION_RESISTED:
			common.merge({"exposure": source["exposure"], "source_id": source["source_id"], "chance": source["chance"], "world_time": source["world_time"]})
		SurvivalService.EVENT_PLAYER_INFECTION_STAGE_CHANGED:
			common.merge({"from": source["from"], "to": source["to"], "world_time": source["world_time"]})
		SurvivalService.EVENT_PLAYER_INFECTION_CURED:
			common.merge({"source_id": source["source_id"], "from": source["from"], "world_time": source["world_time"]})
		SurvivalService.EVENT_NEED_CATEGORY_CHANGED:
			common.merge({"need": source["need"], "category": source["category"], "world_time": source["world_time"]})
		SurvivalService.EVENT_PLAYER_REST_STARTED:
			common["world_time"] = source["world_time"]
		SurvivalService.EVENT_PLAYER_REST_ENDED:
			common.merge({"cause": source["cause"], "world_time": source["world_time"]})
		_:
			return {}
	return common


func _public_event(source: Dictionary) -> Dictionary:
	var common: Dictionary = {
		"scope": ClientSurvivalState.SCOPE_PUBLIC,
		"event_type": str(source.get("event_type", "")),
		"player_id": str(source.get("player_id", "")),
	}
	match str(common["event_type"]):
		SurvivalService.EVENT_PLAYER_WOUNDED:
			var wound: Dictionary = source["wound"]
			common.merge({"body_part": wound["body_part"], "wound_type": wound["wound_type"], "died": source["died"], "world_time": source["world_time"]})
		SurvivalService.EVENT_PLAYER_DIED:
			common["world_time"] = source["world_time"]
		SurvivalService.EVENT_PLAYER_RESPAWNED:
			common.merge({"position": source["position"], "world_time": source["world_time"]})
		# Lying down and getting up are visible to anybody (P2-T8). The cause
		# of getting up stays with the owner.
		SurvivalService.EVENT_PLAYER_REST_STARTED, SurvivalService.EVENT_PLAYER_REST_ENDED:
			common["world_time"] = source["world_time"]
		_:
			return {}
	return common


func _append_peer_event(by_peer: Dictionary, peer_id: int, event: Dictionary) -> void:
	if not by_peer.has(peer_id):
		by_peer[peer_id] = []
	(by_peer[peer_id] as Array).append(event)


func _on_network_player_left(player_id: String) -> void:
	if network != null and network.is_client():
		client_state.remove_player(player_id)


# ------------------------------------------------------------ client side

## Asks the server to lie down (true) or get up (false). Returns the request
## id the `rest_result` signal will carry, or NO_REQUEST when nothing was
## sent (not a joined client). Nothing is decided here.
func request_rest(lie_down: bool) -> int:
	if network == null or not network.is_client() or network.client_state.local_player_id.is_empty():
		return NO_REQUEST
	_last_rest_request_id += 1
	send_raw_rest_request(_last_rest_request_id, lie_down)
	return _last_rest_request_id


## Sends an arbitrary request without any client-side check (tests:
## malformed or premature input through the real RPC path).
func send_raw_rest_request(request_id: Variant, lie_down: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_rest.rpc_id(NetworkService.SERVER_PEER_ID, request_id, lie_down)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_rest_result(request_id: Variant, ok: Variant, reason: Variant) -> void:
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
	rest_result.emit(int(request_id), bool(ok), reason_code)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_survival_owner_snapshot(snapshot: Variant) -> void:
	if not network.is_from_server() or typeof(snapshot) != TYPE_DICTIONARY:
		return
	client_state.apply_owner_snapshot(snapshot as Dictionary)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_survival_status(status: Variant) -> void:
	if not network.is_from_server() or typeof(status) != TYPE_DICTIONARY:
		return
	client_state.apply_player_status(status as Dictionary)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_survival_events(events: Variant) -> void:
	if not network.is_from_server() or typeof(events) != TYPE_ARRAY:
		return
	client_state.apply_event_batch(events as Array)


func _reject_result() -> void:
	rejected_payload_count += 1
	GameLogger.warning("survival_net", "rest result dropped", {"module": MODULE_NAME, "operation": "apply_payload"})
