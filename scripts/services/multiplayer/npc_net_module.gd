class_name NpcNetModule
extends NetModule
## Server-to-client NPC replication (P4-7, docs/09 §17.5). Every peer has
## its own known set and reliable event sequence. At the configured snapshot
## tick (5 Hz by default), the module reconciles that set against
## NetworkService interest cells, queues npc_entered/npc_left and observable
## action-label changes on channel 0, then sends compact position rows on
## channel 2. No client intent exists here.
##
## F-25: an NPC's public condition (ok / hurt / dead) is part of its full
## row and changes with npc_condition_changed, exactly like the action
## label. It comes from one injected read-only function; without one every
## NPC is "ok".

const MODULE_NAME: String = "NpcNet"

var client_state: ClientNpcState
var sent_snapshot_message_count: int = 0
var sent_snapshot_row_count: int = 0
var sent_event_count: int = 0
var unsendable_row_count: int = 0
var invalid_action_label_count: int = 0
var invalid_condition_count: int = 0
var ignored_sender_count: int = 0

var _settings: NpcNetSettings
var _npcs: NpcService = null
var _world: ServerWorld = null
var _tick: int = 0
var _snapshot_elapsed: float = 0.0
var _streams: Dictionary[int, PeerStream] = {}
## P4-4 replaces the default idle with one injected read-only function.
var _action_label_source: Callable = Callable()
## F-25: `(NpcState) -> one of NpcNetProtocol.CONDITIONS`.
var _condition_source: Callable = Callable()


class PeerStream extends RefCounted:
	var known: Dictionary[String, bool] = {}
	var action_labels: Dictionary[String, String] = {}
	var conditions: Dictionary[String, String] = {}
	var sequence: int = 0
	var pending: Array[Dictionary] = []


func _init(settings: NpcNetSettings = null, action_label_source: Callable = Callable(), condition_source: Callable = Callable()) -> void:
	name = MODULE_NAME
	_settings = settings if settings != null else NpcNetSettings.new()
	_action_label_source = action_label_source
	_condition_source = condition_source
	client_state = ClientNpcState.new(_settings)


## Server seam for P4-4: a function `(NpcState) -> one of ACTION_LABELS`.
## Invalid results are logged and fall back to idle; no private state is sent.
func set_action_label_source(source: Callable) -> Error:
	if not source.is_valid():
		return ERR_INVALID_PARAMETER
	_action_label_source = source
	return OK


func on_server_started(world: ServerWorld) -> void:
	_npcs = world.get_system(NpcService.SYSTEM_ID) as NpcService
	if _npcs == null:
		GameLogger.info("net", "world has no npc system, npc replication is off", {"world_id": world.world_id, "module": MODULE_NAME})
		return
	_world = world


func on_player_left(peer_id: int, _player_id: String) -> void:
	_streams.erase(peer_id)


func server_physics(delta: float) -> void:
	if _npcs == null:
		return
	_tick += 1
	_snapshot_elapsed += delta
	var period: float = 1.0 / _settings.snapshot_rate_hz
	if _snapshot_elapsed < period:
		return
	_snapshot_elapsed = minf(_snapshot_elapsed - period, period)
	var rows_by_peer: Dictionary[int, Array] = _reconcile()
	_send_pending_events()
	_send_snapshots(rows_by_peer)


func build_join_fragment(player_id: String) -> Dictionary:
	if _npcs == null:
		return {}
	var peer_id: int = network.peer_of_player(player_id)
	var stream: PeerStream = _streams.get(peer_id, null)
	var joining: bool = stream == null
	if joining:
		stream = PeerStream.new()
		if peer_id != 0:
			_streams[peer_id] = stream
	var rows: Array = []
	for npc_id: String in _npcs.npc_ids():
		if not network.is_cell_of_interest(peer_id, _world.cell_index.cell_of(npc_id)):
			continue
		var source: Dictionary = _public_source(npc_id)
		var row: Array = NpcNetProtocol.encode_public_row(source)
		if row.is_empty():
			_log_bad_row(npc_id, "join")
			continue
		rows.append(row)
		if joining:
			stream.known[npc_id] = true
			stream.action_labels[npc_id] = str(source[NpcNetProtocol.KEY_ACTION_LABEL])
			stream.conditions[npc_id] = str(source[NpcNetProtocol.KEY_CONDITION])
	return {
		NpcNetProtocol.KEY_TICK: _tick,
		NpcNetProtocol.KEY_EVENT_SEQUENCE: stream.sequence,
		NpcNetProtocol.KEY_ROWS: rows,
	}


func knows_npc(peer_id: int, npc_id: String) -> bool:
	var stream: PeerStream = _streams.get(peer_id, null)
	return stream != null and stream.known.has(npc_id)


## Reconciles membership only here (the snapshot tick), and returns compact
## position rows for every peer. Events are queued before snapshots are sent.
func _reconcile() -> Dictionary[int, Array]:
	var rows_by_peer: Dictionary[int, Array] = {}
	var seen_by_peer: Dictionary[int, Dictionary] = {}
	for peer_id: int in _streams:
		rows_by_peer[peer_id] = []
		seen_by_peer[peer_id] = {}
	if _streams.is_empty():
		return rows_by_peer
	var peers_by_cell: Dictionary[String, PackedInt32Array] = {}
	for npc_id: String in _npcs.npc_ids():
		var cell_id: String = _world.cell_index.cell_of(npc_id)
		if not peers_by_cell.has(cell_id):
			peers_by_cell[cell_id] = network.peers_interested_in(cell_id)
		var peers: PackedInt32Array = peers_by_cell[cell_id]
		if peers.is_empty():
			continue
		var source: Dictionary = _public_source(npc_id)
		var public_row: Array = NpcNetProtocol.encode_public_row(source)
		var snapshot_row: Array = NpcNetProtocol.encode_snapshot_row(source)
		if public_row.is_empty() or snapshot_row.is_empty():
			_log_bad_row(npc_id, "reconcile")
			continue
		var action_label: String = str(source[NpcNetProtocol.KEY_ACTION_LABEL])
		var condition: String = str(source[NpcNetProtocol.KEY_CONDITION])
		for peer_id: int in peers:
			var stream: PeerStream = _streams.get(peer_id, null)
			if stream == null:
				continue
			if not stream.known.has(npc_id):
				_queue_entered(stream, public_row)
			else:
				if str(stream.action_labels.get(npc_id, NpcNetProtocol.ACTION_IDLE)) != action_label:
					stream.action_labels[npc_id] = action_label
					_queue(stream, NpcNetProtocol.action_changed_event(npc_id, action_label, _world.clock.world_time_sec))
				if str(stream.conditions.get(npc_id, NpcNetProtocol.CONDITION_OK)) != condition:
					stream.conditions[npc_id] = condition
					_queue(stream, NpcNetProtocol.condition_changed_event(npc_id, condition, _world.clock.world_time_sec))
			seen_by_peer[peer_id][npc_id] = true
			rows_by_peer[peer_id].append(snapshot_row)
	var world_time: float = _world.clock.world_time_sec
	for peer_id: int in _streams:
		var stream: PeerStream = _streams[peer_id]
		var seen: Dictionary = seen_by_peer[peer_id]
		for npc_id: String in stream.known.keys():
			if seen.has(npc_id):
				continue
			stream.known.erase(npc_id)
			stream.action_labels.erase(npc_id)
			stream.conditions.erase(npc_id)
			_queue(stream, NpcNetProtocol.left_event(npc_id, world_time))
	return rows_by_peer


## The sole server-side observable-label seam. P4-7 itself always returns
## idle; an injected P4-4 source can return the other protocol labels.
func _action_label(npc: NpcState) -> String:
	if not _action_label_source.is_valid():
		return NpcNetProtocol.ACTION_IDLE
	var value: Variant = _action_label_source.call(npc)
	if typeof(value) == TYPE_STRING and NpcNetProtocol.ACTION_LABELS.has(str(value)):
		return str(value)
	invalid_action_label_count += 1
	GameLogger.warning("net", "invalid observable NPC action label; idle sent", {"entity_id": npc.npc_id, "label": str(value), "operation": "npc_action_label"})
	return NpcNetProtocol.ACTION_IDLE


## The sole server-side seam for the public condition (F-25). An invalid
## result is logged and sent as "ok": nothing private can take its place.
func _condition(npc: NpcState) -> String:
	if not _condition_source.is_valid():
		return NpcNetProtocol.CONDITION_OK
	var value: Variant = _condition_source.call(npc)
	if typeof(value) == TYPE_STRING and NpcNetProtocol.CONDITIONS.has(str(value)):
		return str(value)
	invalid_condition_count += 1
	GameLogger.warning("net", "invalid public NPC condition; ok sent", {"entity_id": npc.npc_id, "condition": str(value), "operation": "npc_condition"})
	return NpcNetProtocol.CONDITION_OK


## Builds only the explicit public source. Definition id, traits, skills,
## components, RNG, needs, mind and goals have no path into this Dictionary.
func _public_source(npc_id: String) -> Dictionary:
	var npc: NpcState = _npcs.get_npc(npc_id)
	var definition: NpcDefinition = _npcs.definition_of(npc_id)
	if npc == null or definition == null:
		return {}
	return {
		NpcNetProtocol.KEY_NPC_ID: npc.npc_id,
		NpcNetProtocol.KEY_NAME: definition.display_name,
		NpcNetProtocol.KEY_APPEARANCE: definition.appearance.duplicate(),
		NpcNetProtocol.KEY_POSITION: npc.position,
		NpcNetProtocol.KEY_YAW: npc.yaw,
		NpcNetProtocol.KEY_ACTION_LABEL: _action_label(npc),
		NpcNetProtocol.KEY_POSTURE: NpcNetProtocol.POSTURE_STANDING,
		NpcNetProtocol.KEY_CONDITION: _condition(npc),
	}


func _queue_entered(stream: PeerStream, public_row: Array) -> void:
	var npc_id: String = str(public_row[NpcNetProtocol.PUBLIC_ID])
	stream.known[npc_id] = true
	stream.action_labels[npc_id] = NpcNetProtocol.ACTION_LABELS[int(public_row[NpcNetProtocol.PUBLIC_ACTION])]
	stream.conditions[npc_id] = NpcNetProtocol.CONDITIONS[int(public_row[NpcNetProtocol.PUBLIC_CONDITION])]
	_queue(stream, NpcNetProtocol.entered_event(public_row, _world.clock.world_time_sec))


func _queue(stream: PeerStream, event: Dictionary) -> void:
	if event.is_empty():
		return
	stream.sequence += 1
	stream.pending.append(event)


func _send_pending_events() -> void:
	for peer_id: int in _streams:
		var stream: PeerStream = _streams[peer_id]
		if stream.pending.is_empty():
			continue
		if network.can_send_to(peer_id):
			var first_sequence: int = stream.sequence - stream.pending.size() + 1
			var offset: int = 0
			while offset < stream.pending.size():
				var message: Array[Dictionary] = stream.pending.slice(offset, offset + _settings.events_per_message)
				_rpc_npc_events.rpc_id(peer_id, _tick, first_sequence + offset, message)
				sent_event_count += message.size()
				offset += message.size()
		stream.pending.clear()


func _send_snapshots(rows_by_peer: Dictionary[int, Array]) -> void:
	for peer_id: int in rows_by_peer:
		var rows: Array = rows_by_peer[peer_id]
		if rows.is_empty() or not network.can_send_to(peer_id):
			continue
		var offset: int = 0
		while offset < rows.size():
			var chunk: Array = rows.slice(offset, offset + _settings.snapshot_rows_per_message)
			_rpc_npc_snapshot.rpc_id(peer_id, _tick, chunk)
			sent_snapshot_message_count += 1
			sent_snapshot_row_count += chunk.size()
			offset += chunk.size()


func _log_bad_row(npc_id: String, operation: String) -> void:
	unsendable_row_count += 1
	GameLogger.error("net", "npc public row does not fit the wire format", {"entity_id": npc_id, "operation": operation})


func apply_join_fragment(fragment: Dictionary) -> void:
	client_state.apply_join(fragment)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_npc_snapshot(tick: Variant, rows: Variant) -> void:
	if not _from_server("npc_snapshot"):
		return
	client_state.apply_snapshot(tick, rows)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_npc_events(tick: Variant, first_sequence: Variant, events: Variant) -> void:
	if not _from_server("npc_events"):
		return
	client_state.apply_events(tick, first_sequence, events)


func _from_server(message: String) -> bool:
	if network != null and network.is_from_server():
		return true
	ignored_sender_count += 1
	GameLogger.warning("net", "npc payload not sent by the server ignored", {"message": message, "sender": multiplayer.get_remote_sender_id() if is_inside_tree() else 0, "operation": "receive"})
	return false
