class_name SurvivalNetModule
extends NetModule
## Server -> client survival replication. No client -> server RPC exists.
## Detailed vitals and infection events are owner-only; other clients receive
## only alive/dead, respawn position and observable wound facts.

const MODULE_NAME: String = "SurvivalNet"
const SCHEMA_VERSION: int = 1

var client_state: ClientSurvivalState

var _net_settings: SurvivalNetSettings
var _survival_settings: SurvivalSettings
var _world: ServerWorld = null
var _survival: SurvivalService = null
var _snapshot_elapsed: float = 0.0
var _last_owner_snapshots: Dictionary[String, Dictionary] = {}


func _init(net_settings: SurvivalNetSettings, survival_settings: SurvivalSettings) -> void:
	name = MODULE_NAME
	_net_settings = net_settings
	_survival_settings = survival_settings
	client_state = ClientSurvivalState.new(net_settings, survival_settings)


func _ready() -> void:
	if network != null and not network.player_left.is_connected(_on_network_player_left):
		network.player_left.connect(_on_network_player_left)


func on_server_started(world: ServerWorld) -> void:
	_world = world
	_survival = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func on_player_joined(_peer_id: int, player_id: String) -> void:
	if _survival == null:
		return
	var status: Dictionary = _make_status(player_id)
	for peer_id: int in network.joined_peers():
		if network.can_send_to(peer_id):
			_rpc_survival_status.rpc_id(peer_id, status)


func on_player_left(_peer_id: int, player_id: String) -> void:
	_last_owner_snapshots.erase(player_id)


func build_join_fragment(player_id: String) -> Dictionary:
	if _world == null or _survival == null or not _survival.has_player(player_id):
		return {}
	var own: Dictionary = _make_owner_snapshot(player_id)
	_last_owner_snapshots[player_id] = own.duplicate(true)
	var statuses: Array[Dictionary] = []
	for online_id: String in _world.online_player_ids():
		statuses.append(_make_status(online_id))
	return {"schema_version": SCHEMA_VERSION, "self": own, "players": statuses}


func apply_join_fragment(fragment: Dictionary) -> void:
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
	}


func _make_status(player_id: String) -> Dictionary:
	return {"player_id": player_id, "alive": _survival.is_alive(player_id)}


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
