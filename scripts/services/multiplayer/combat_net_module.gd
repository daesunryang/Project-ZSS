class_name CombatNetModule
extends NetModule
## Melee attack intent and combat event replication (P2-N1b, docs/09 §14.13).
## Network only: every rule is in CombatService (docs/09 §14.10).
##
## RPC table (channel 0 = reliable ordered):
##   client -> server  _rpc_request_melee_attack(request_id:int, aim_yaw:float)   reliable, ch0
##   server -> owner   _rpc_melee_result(request_id:int, ok:bool, reason:String)  reliable, ch0
##   server -> clients _rpc_combat_events(events:Array[Dictionary])               reliable, ch0
##
## Request: a client sends an intent only: its own request id and the aim
## direction. There is no player, position, target, weapon or damage
## argument; the attacker is the player of the sending peer
## (NetworkService.sender_player_id()) and everything else is decided by
## CombatService from server state. Server checks, in order: joined
## (`not_joined`), argument types (`bad_type`), request id >= 0
## (`bad_sequence`), finite aim within the combat bound (`bad_aim_yaw`),
## request rate (`rate_limited`), then CombatService's own rules (its reason
## codes: `player_dead`, `attack_on_cooldown`, `not_enough_stamina`, ...).
## Every refusal is counted (NetworkService.rejected_intent_count) and
## changes nothing.
##
## Result: sent to the requester only, for every request of a joined peer
## whose request id is usable (int >= 0). `reason` is "" exactly when ok.
##
## Events: every server tick this module empties CombatService.drain_events()
## (it is the only consumer) and sends the public form of each event to all
## joined peers, in the order the server decided them, numbered with a
## per-session sequence (1, 2, ...). All peers get the same payload
## (ClientCombatState documents it). A request's result is sent before the
## event of the swing it caused (same ordered channel). Events are not
## replayed to late joiners: the join fragment carries the newest sequence
## number already sent, and a new client starts after it.
##
## Client surface (presentation): request_melee_attack(), the signals below,
## recent_events() / last_event_sequence(). The mirror has no authority.

## Client: answer to one of this client's own requests.
signal melee_result(request_id: int, ok: bool, reason: String)
## Client: one combat event, in server order (a copy; see ClientCombatState).
signal combat_event(event: Dictionary)

const MODULE_NAME: String = "CombatNet"
## Intent name in rejection logs.
const INTENT_MELEE_ATTACK: String = "melee_attack"
## Returned by request_melee_attack() when nothing was sent.
const NO_REQUEST: int = 0
## Protocol limit: a client drops an event message with more entries. The
## server's CombatNetSettings.max_events_per_message may not exceed it.
const MAX_EVENTS_PER_MESSAGE: int = 64
## Longest reason code a client accepts in a result.
const REASON_MAX_LENGTH: int = 64
## Join fragment key: newest event sequence number already broadcast.
const FRAGMENT_LAST_SEQUENCE: String = "last_sequence"

## Client: validated mirror of the broadcast events. Server: record of what
## was broadcast. Never authoritative.
var events: ClientCombatState
## Client: event payloads from the server that failed validation.
var rejected_event_count: int = 0

var _settings: CombatNetSettings
var _max_abs_aim_yaw: float
# --- server state ---
var _world: ServerWorld = null
var _combat: CombatService = null
var _limiter: RateLimiter = null
# --- client state ---
var _last_request_id: int = NO_REQUEST


## `max_abs_aim_yaw` is CombatSettings.max_abs_aim_yaw, so the network check
## and the combat rule agree on the range.
func _init(settings: CombatNetSettings, max_abs_aim_yaw: float) -> void:
	name = MODULE_NAME
	_settings = settings
	_max_abs_aim_yaw = max_abs_aim_yaw
	events = ClientCombatState.new(settings.recent_event_capacity)


# ------------------------------------------------------------ pure rules

## "" when the arguments of a melee request are usable, otherwise a reason
## code. Types first, so wrongly typed input never reaches a conversion.
static func validate_melee_request(request_id: Variant, aim_yaw: Variant, max_abs_aim_yaw: float) -> String:
	if typeof(request_id) != TYPE_INT or typeof(aim_yaw) != TYPE_FLOAT:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	if not MeleeHitRules.is_valid_aim_yaw(float(aim_yaw), max_abs_aim_yaw):
		return CombatService.REASON_BAD_AIM_YAW
	return ""


## Public (broadcast) form of a CombatService event, or {} for an event
## type this module does not replicate. Only the listed fields are copied,
## so a field added to the server event is never sent by accident.
## `include_damage` = CombatNetSettings.broadcast_damage_numbers.
static func to_public_event(server_event: Dictionary, sequence: int, include_damage: bool) -> Dictionary:
	if str(server_event.get("event_type", "")) != CombatService.EVENT_MELEE_ATTACK:
		return {}
	var public: Dictionary = {
		ClientCombatState.KEY_SEQUENCE: sequence,
		ClientCombatState.KEY_EVENT_TYPE: ClientCombatState.EVENT_MELEE_ATTACK,
		ClientCombatState.KEY_ATTACKER_ID: str(server_event.get("attacker_id", "")),
		ClientCombatState.KEY_WEAPON_ID: str(server_event.get("weapon_id", "")),
		ClientCombatState.KEY_AIM_YAW: _number(server_event.get("aim_yaw", null)),
		ClientCombatState.KEY_POSITION: _vector(server_event.get("position", null)),
		ClientCombatState.KEY_HIT: server_event.get("hit", false) == true,
		ClientCombatState.KEY_TARGET_ID: str(server_event.get("target_id", "")),
		ClientCombatState.KEY_TARGET_DIED: server_event.get("target_died", false) == true,
		ClientCombatState.KEY_WORLD_TIME: _number(server_event.get("world_time", null)),
	}
	if include_damage:
		public[ClientCombatState.KEY_DAMAGE] = _number(server_event.get("damage", null))
		public[ClientCombatState.KEY_TARGET_HEALTH_AFTER] = _number(server_event.get("target_health_after", null))
	return public


## int/float as float; anything else NAN (fails the event validation).
static func _number(value: Variant) -> float:
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return float(value)
	return NAN


## [x, y, z] as Vector3; anything else a non-finite vector.
static func _vector(value: Variant) -> Vector3:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 3:
		return Vector3(NAN, NAN, NAN)
	var parts: Array = value
	return Vector3(_number(parts[0]), _number(parts[1]), _number(parts[2]))


# ------------------------------------------------------------ NetModule hooks

func on_server_started(world: ServerWorld) -> void:
	_world = world
	_combat = world.get_system(CombatService.SYSTEM_ID) as CombatService
	_limiter = RateLimiter.new(_settings.melee_intent_rate_per_sec, _settings.melee_intent_burst)
	if _combat == null:
		GameLogger.warning("net", "combat system not registered, melee requests will be refused", {"world_id": world.world_id, "module": MODULE_NAME, "operation": "on_server_started"})


func on_player_left(peer_id: int, _player_id: String) -> void:
	if _limiter != null:
		_limiter.forget(peer_id)


## Server: forwards the combat events of this tick to every joined peer.
func server_physics(_delta: float) -> void:
	if network == null or not network.is_server() or _combat == null:
		return
	var drained: Array[Dictionary] = _combat.drain_events()
	if drained.is_empty():
		return
	var batch: Array = []
	for server_event: Dictionary in drained:
		var public: Dictionary = to_public_event(server_event, events.last_sequence + 1, _settings.broadcast_damage_numbers)
		# The server holds its own output to the rule its clients apply.
		var reason: String = ClientCombatState.REASON_UNKNOWN_EVENT if public.is_empty() else events.apply_event(public)
		if not reason.is_empty():
			GameLogger.error("net", "combat event not replicated", {"event_type": str(server_event.get("event_type", "")), "reason": reason, "module": MODULE_NAME, "operation": "broadcast_events"})
			continue
		batch.append(public)
	_broadcast(batch)


func build_join_fragment(_player_id: String) -> Dictionary:
	return {FRAGMENT_LAST_SEQUENCE: events.last_sequence}


func apply_join_fragment(fragment: Dictionary) -> void:
	var baseline: Variant = fragment.get(FRAGMENT_LAST_SEQUENCE, ClientCombatState.NO_SEQUENCE)
	events.reset(int(baseline) if typeof(baseline) == TYPE_INT else ClientCombatState.NO_SEQUENCE)
	_last_request_id = NO_REQUEST


# ------------------------------------------------------------ server side

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_melee_attack(request_id: Variant, aim_yaw: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The attacker is whoever owns the sending peer, never an argument.
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, INTENT_MELEE_ATTACK, NetworkService.NOT_JOINED)
		return
	var reason: String = validate_melee_request(request_id, aim_yaw, _max_abs_aim_yaw)
	if not reason.is_empty():
		network.reject_intent(peer_id, INTENT_MELEE_ATTACK, reason, player_id)
		if typeof(request_id) == TYPE_INT and int(request_id) >= 0:
			_send_result(peer_id, int(request_id), false, reason)
		return
	if not _limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, INTENT_MELEE_ATTACK, NetworkService.RATE_LIMITED, player_id)
		_send_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED)
		return
	if _combat == null:
		network.reject_intent(peer_id, INTENT_MELEE_ATTACK, CombatService.REASON_UNAVAILABLE, player_id)
		_send_result(peer_id, int(request_id), false, CombatService.REASON_UNAVAILABLE)
		return
	var result: ActionResult = _combat.request_melee_attack(_world, player_id, float(aim_yaw))
	if not result.ok:
		# Cooldown, stamina, death: normal play, counted but not logged here.
		network.count_rejection(result.reason)
		_send_result(peer_id, int(request_id), false, result.reason)
		return
	_send_result(peer_id, int(request_id), true, "")
	GameLogger.debug("net", "melee attack accepted", {"peer_id": peer_id, "player_id": player_id, "request_id": int(request_id), "entity_id": str(result.event.get("target_id", ""))})


func _send_result(peer_id: int, request_id: int, ok: bool, reason: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_melee_result.rpc_id(peer_id, request_id, ok, reason)


## Sends `batch` to every joined peer, split into messages of at most
## `max_events_per_message` events. Same content and order for everyone.
func _broadcast(batch: Array) -> void:
	var peers: PackedInt32Array = network.joined_peers()
	var per_message: int = clampi(_settings.max_events_per_message, 1, MAX_EVENTS_PER_MESSAGE)
	var offset: int = 0
	while offset < batch.size():
		var message: Array = batch.slice(offset, offset + per_message)
		offset += message.size()
		for peer_id: int in peers:
			if network.can_send_to(peer_id):
				_rpc_combat_events.rpc_id(peer_id, message)


# ------------------------------------------------------------ client side

## Asks the server for one melee swing aimed at `aim_yaw` (radians, yaw 0 =
## -Z). Returns the request id the `melee_result` signal will carry, or
## NO_REQUEST when nothing was sent (not a joined client).
func request_melee_attack(aim_yaw: float) -> int:
	if network == null or not network.is_client() or network.client_state.local_player_id.is_empty():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_melee_request(_last_request_id, aim_yaw)
	return _last_request_id


## Sends an arbitrary request without any client-side check (tests:
## malformed or premature input through the real RPC path).
func send_raw_melee_request(request_id: Variant, aim_yaw: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_melee_attack.rpc_id(NetworkService.SERVER_PEER_ID, request_id, aim_yaw)


## Copies of the newest combat events, oldest first. Client: received from
## the server. Server: what it broadcast.
func recent_events() -> Array[Dictionary]:
	return events.recent_events()


## Sequence number of the newest event (0 = none yet).
func last_event_sequence() -> int:
	return events.last_sequence


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_melee_result(request_id: Variant, ok: Variant, reason: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if typeof(request_id) != TYPE_INT or typeof(ok) != TYPE_BOOL or typeof(reason) != TYPE_STRING:
		return
	var reason_code: String = reason
	# "" exactly when the request was accepted.
	if int(request_id) < 0 or reason_code.length() > REASON_MAX_LENGTH or bool(ok) != reason_code.is_empty():
		return
	melee_result.emit(int(request_id), bool(ok), reason_code)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_combat_events(payload: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if typeof(payload) != TYPE_ARRAY or (payload as Array).size() > MAX_EVENTS_PER_MESSAGE:
		_reject_payload(ClientCombatState.REASON_BAD_EVENT)
		return
	for entry: Variant in payload as Array:
		var reason: String = events.apply_event(entry)
		if not reason.is_empty():
			_reject_payload(reason)
			continue
		combat_event.emit(events.last_event())


func _reject_payload(reason: String) -> void:
	rejected_event_count += 1
	GameLogger.warning("net", "combat event payload dropped", {"reason": reason, "module": MODULE_NAME, "operation": "apply_events"})
