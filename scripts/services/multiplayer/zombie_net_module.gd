class_name ZombieNetModule
extends NetModule
## Zombie replication (P2-N1a, docs/09 §14.12): the server sends zombie
## state and zombie events to every joined client; clients mirror them in
## `client_state` (ClientZombieState). Server -> client only: this module
## has no client -> server RPC. Assembled in
## ServerComposition.install_net_modules() on every peer.
##
## RPC table (wire format: ZombieNetProtocol):
##   server -> clients  _rpc_zombie_snapshot(tick:int, rows:Array)
##       unreliable_ordered, channel 2 (NetworkSettings.CHANNEL_ENTITY_SNAPSHOT)
##       All zombies every 1/snapshot_rate_hz s, split into messages of
##       `snapshot_rows_per_message` rows that share one tick. Clients drop
##       older ticks.
##   server -> clients  _rpc_zombie_events(tick:int, first_sequence:int, events:Array)
##       reliable, channel 0 (NetworkSettings.CHANNEL_RELIABLE)
##       ZombieService.drain_events() of this server tick, in order;
##       events[i] has sequence first_sequence + i. The `infection` and
##       `target_health_after` fields of zombie_attacked are only in the
##       copy sent to the attacked player (docs/15 P2-9, P2-85).
## Initial state: join fragment {tick, event_sequence, rows} with every
## zombie; `event_sequence` is the last event already reflected in `rows`.
##
## `tick` counts this module's server physics ticks. It orders snapshots
## and lets the mirror tell whether a snapshot is older than an event.
##
## This module is the only consumer of ZombieService.drain_events(). Other
## server-side code that needs the events connects to
## `server_events_drained`.
## No interest management: every client gets every zombie (docs/15 P2-83).
##
## World cells (P3-1, docs/09 §15.1): "every zombie" is every zombie the
## server has in memory. When a cell comes into memory its zombies are
## announced to the clients as `zombie_spawned` wire events, and when a cell
## is about to leave memory as `zombie_removed` wire events: the two events
## that change a mirror's membership anyway, in the same reliable, numbered
## stream, so nothing changes in the wire format. They are made here, not by
## ZombieService: no zombie was spawned or removed in the world, so they are
## NOT part of `server_events_drained`. A zombie announced this way shows as
## idle with full health until the next snapshot (at most one snapshot
## period) corrects its state and health (docs/15 P3-015).

## Server: the raw domain events drained this tick, oldest first.
signal server_events_drained(events: Array[Dictionary])

const MODULE_NAME: String = "ZombieNet"

## Client: the mirror. Stays empty on the server.
var client_state: ClientZombieState
## Diagnostics.
var sent_snapshot_message_count: int = 0
var sent_event_count: int = 0
var unsendable_event_count: int = 0
var ignored_sender_count: int = 0

var _settings: ZombieNetSettings
var _zombies: ZombieService = null
var _world: ServerWorld = null
var _cells: WorldCellService = null
var _tick: int = 0
var _snapshot_elapsed: float = 0.0
## Sequence of the newest drained event (the first event is 1).
var _event_sequence: int = 0
## Full wire events drained but not yet sent; the last one has
## `_event_sequence`.
var _pending: Array[Dictionary] = []


func _init(settings: ZombieNetSettings = null) -> void:
	name = MODULE_NAME
	_settings = settings if settings != null else ZombieNetSettings.new()
	client_state = ClientZombieState.new(_settings)


# ------------------------------------------------------------ server side

func on_server_started(world: ServerWorld) -> void:
	_zombies = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	if _zombies == null:
		GameLogger.info("net", "world has no zombie system, zombie replication is off", {"world_id": world.world_id, "module": MODULE_NAME})
		return
	_world = world
	_cells = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	if _cells != null:
		_cells.cell_loaded.connect(_on_cell_loaded)
		_cells.cell_unloading.connect(_on_cell_unloading)


func _exit_tree() -> void:
	if _cells == null:
		return
	if _cells.cell_loaded.is_connected(_on_cell_loaded):
		_cells.cell_loaded.disconnect(_on_cell_loaded)
	if _cells.cell_unloading.is_connected(_on_cell_unloading):
		_cells.cell_unloading.disconnect(_on_cell_unloading)


## P3-1: the zombies of a cell that came into memory appear on the clients.
func _on_cell_loaded(cell_id: String) -> void:
	_announce_cell(cell_id, ZombieService.EVENT_SPAWNED)


## P3-1: the zombies of a cell that is about to leave memory disappear from
## the clients.
func _on_cell_unloading(cell_id: String) -> void:
	_announce_cell(cell_id, ZombieService.EVENT_REMOVED)


## Queues one wire event of `event_type` for every zombie of the cell,
## after the domain events recorded so far (the order clients see is the
## order things happened on the server).
func _announce_cell(cell_id: String, event_type: String) -> void:
	if _zombies == null or network == null or not network.is_server():
		return
	var zombie_ids: PackedStringArray = _world.cell_index.entities_in_cell(cell_id, ZombieService.ENTITY_KIND_ZOMBIE)
	if zombie_ids.is_empty():
		return
	_collect_events()
	for zombie_id: String in zombie_ids:
		var zombie: ZombieState = _zombies.get_zombie(zombie_id)
		if zombie == null:
			continue
		var event: Dictionary = {
			ZombieNetProtocol.KEY_EVENT_TYPE: event_type,
			ZombieNetProtocol.KEY_ZOMBIE_ID: zombie_id,
			ZombieNetProtocol.KEY_WORLD_TIME: _world.clock.world_time_sec,
		}
		if event_type == ZombieService.EVENT_SPAWNED:
			event["position"] = [zombie.position.x, zombie.position.y, zombie.position.z]
			event["yaw"] = zombie.yaw
		var wire: Dictionary = ZombieNetProtocol.encode_event(event)
		if wire.is_empty():
			unsendable_event_count += 1
			GameLogger.error("net", "zombie event does not fit the wire format", {"entity_id": zombie_id, "event_type": event_type, "cell_id": cell_id, "operation": "announce_cell"})
			continue
		_event_sequence += 1
		_pending.append(wire)


func server_physics(delta: float) -> void:
	if _zombies == null:
		return
	_tick += 1
	_collect_events()
	_send_pending_events()
	_snapshot_elapsed += delta
	var period: float = 1.0 / _settings.snapshot_rate_hz
	if _snapshot_elapsed >= period:
		# Keep the remainder so the average rate is exact, but never burst.
		_snapshot_elapsed = minf(_snapshot_elapsed - period, period)
		_broadcast_snapshot()


## Every zombie as it is right now. Events still queued in ZombieService are
## drained first so their sequence numbers are covered by `event_sequence`;
## they go out with the next tick and the joiner skips them.
func build_join_fragment(_player_id: String) -> Dictionary:
	if _zombies == null:
		return {}
	_collect_events()
	return {
		ZombieNetProtocol.KEY_TICK: _tick,
		ZombieNetProtocol.KEY_EVENT_SEQUENCE: _event_sequence,
		ZombieNetProtocol.KEY_ROWS: _encode_rows(),
	}


## Drains the domain queue into `_pending`, giving each event a sequence.
func _collect_events() -> void:
	var drained: Array[Dictionary] = _zombies.drain_events()
	if drained.is_empty():
		return
	for event: Dictionary in drained:
		var wire: Dictionary = ZombieNetProtocol.encode_event(event)
		if wire.is_empty():
			unsendable_event_count += 1
			GameLogger.error("net", "zombie event does not fit the wire format", {"entity_id": str(event.get("zombie_id", "")), "event_type": str(event.get("event_type", "")), "operation": "collect_events"})
			continue
		_event_sequence += 1
		_pending.append(wire)
	server_events_drained.emit(drained)


func _send_pending_events() -> void:
	if _pending.is_empty():
		return
	var peers: PackedInt32Array = network.joined_peers()
	var first_sequence: int = _event_sequence - _pending.size() + 1
	var offset: int = 0
	while offset < _pending.size() and not peers.is_empty():
		var full: Array[Dictionary] = _pending.slice(offset, offset + _settings.events_per_message)
		var shared: Array[Dictionary] = []
		for event: Dictionary in full:
			shared.append(ZombieNetProtocol.public_event(event))
		for peer_id: int in peers:
			if network.can_send_to(peer_id):
				_rpc_zombie_events.rpc_id(peer_id, _tick, first_sequence + offset, _events_for(network.player_of_peer(peer_id), full, shared))
		offset += full.size()
		sent_event_count += full.size()
	# With nobody joined the events are dropped: a later joiner gets their
	# result in its join snapshot.
	_pending.clear()


## The message for one viewer: public events, except that events whose
## private fields belong to `player_id` are sent in full (docs/15 P2-9).
func _events_for(player_id: String, full: Array[Dictionary], shared: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = shared
	if player_id.is_empty():
		return result
	for index: int in range(full.size()):
		if is_same(full[index], shared[index]) or ZombieNetProtocol.private_owner(full[index]) != player_id:
			continue
		if is_same(result, shared):
			result = shared.duplicate()
		result[index] = full[index]
	return result


func _broadcast_snapshot() -> void:
	var peers: PackedInt32Array = network.joined_peers()
	if peers.is_empty():
		return
	var rows: Array = _encode_rows()
	var offset: int = 0
	while offset < rows.size():
		var chunk: Array = rows.slice(offset, offset + _settings.snapshot_rows_per_message)
		for peer_id: int in peers:
			if network.can_send_to(peer_id):
				_rpc_zombie_snapshot.rpc_id(peer_id, _tick, chunk)
		sent_snapshot_message_count += 1
		offset += chunk.size()


func _encode_rows() -> Array:
	var rows: Array = []
	for row: Dictionary in _zombies.snapshot_rows():
		var encoded: Array = ZombieNetProtocol.encode_row(row)
		if encoded.is_empty():
			GameLogger.error("net", "zombie row does not fit the wire format", {"entity_id": str(row.get("id", "")), "operation": "encode_rows"})
			continue
		rows.append(encoded)
	return rows


# ------------------------------------------------------------ client side

func apply_join_fragment(fragment: Dictionary) -> void:
	client_state.apply_join(fragment)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_zombie_snapshot(tick: Variant, rows: Variant) -> void:
	if not _from_server("zombie_snapshot"):
		return
	client_state.apply_snapshot(tick, rows)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_zombie_events(tick: Variant, first_sequence: Variant, events: Variant) -> void:
	if not _from_server("zombie_events"):
		return
	client_state.apply_events(tick, first_sequence, events)


## Client: true while handling an RPC the server sent. Anything else (a
## local call, another sender, the server role itself) is ignored and logged.
func _from_server(message: String) -> bool:
	if network != null and network.is_from_server():
		return true
	ignored_sender_count += 1
	GameLogger.warning("net", "zombie payload not sent by the server ignored", {"message": message, "sender": multiplayer.get_remote_sender_id() if is_inside_tree() else 0, "operation": "receive"})
	return false
