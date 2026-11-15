class_name ZombieNetModule
extends NetModule
## Zombie replication (P2-N1a, docs/09 §14.12; scoped per client since P3-2,
## docs/09 §15.2): the server sends zombie state and zombie events to the
## joined clients; clients mirror them in `client_state` (ClientZombieState).
## Server -> client only: this module has no client -> server RPC. Assembled
## in ServerComposition.install_net_modules() on every peer.
##
## RPC table (wire format: ZombieNetProtocol):
##   server -> client  _rpc_zombie_snapshot(tick:int, rows:Array)
##       unreliable_ordered, channel 2 (NetworkSettings.CHANNEL_ENTITY_SNAPSHOT)
##       The zombies this client is told about, every 1/snapshot_rate_hz s,
##       split into messages of `snapshot_rows_per_message` rows that share
##       one tick. Clients drop older ticks.
##   server -> client  _rpc_zombie_events(tick:int, first_sequence:int, events:Array)
##       reliable, channel 0 (NetworkSettings.CHANNEL_RELIABLE)
##       The events of this server tick about zombies this client is told
##       about, in order; events[i] has sequence first_sequence + i. The
##       `infection` and `target_health_after` fields of zombie_attacked are
##       only in the copy sent to the attacked player (docs/15 P2-9, P2-85).
## Initial state: join fragment {tick, event_sequence, rows} with the zombies
## of the joining peer's cells.
##
## `tick` counts this module's server physics ticks. It orders snapshots
## and lets the mirror tell whether a snapshot is older than an event.
##
## This module is the only consumer of ZombieService.drain_events(). Other
## server-side code that needs the events connects to
## `server_events_drained` (every domain event, whoever is told about it).
##
## Scope (P3-2). Every joined peer has its own stream: the set of zombies it
## was told about ("known"), its own event sequence (1, 2, ... from its
## join, without holes) and its own snapshots. A zombie is to be known to a
## peer exactly while it is in a cell the peer is interested in
## (NetworkService.is_cell_of_interest: the cells around the peer's player
## that the server has in memory). Without an interest module every peer is
## told about every zombie in memory, as before P3-2.
##   - zombie_spawned goes to the peers interested in the zombie's cell; they
##     know the zombie from then on.
##   - every other domain event goes to the peers that know its zombie.
##     zombie_removed ends that knowledge.
##   - Reconciliation, once per snapshot (10 Hz by default): every zombie in
##     memory is compared with every peer's cells. A zombie that should be
##     known and is not is sent as the wire event `zombie_entered` (position,
##     facing, state, health: it appears as what it is); a zombie that is
##     known and should not be is sent as `zombie_left`. This one pass covers
##     a zombie walking across the border of a peer's area, a peer walking,
##     a peer entering the world, and cells entering or leaving the server's
##     memory. A zombie therefore appears / disappears up to one snapshot
##     period after it crossed (docs/15 P3-040).
##   - Snapshot rows go to the peers that know the zombie.
##   - The player a zombie attacked is always sent that event (it carries
##     the player's own infection result); should that player not know the
##     zombie it is first told about it (ensure_known). The next
##     reconciliation takes the zombie away again if it is outside the
##     player's cells.
## The scope events are made here, not by ZombieService: no zombie was
## spawned or removed in the world, so they are NOT part of
## `server_events_drained`.

## Server: the raw domain events drained this tick, oldest first.
signal server_events_drained(events: Array[Dictionary])

const MODULE_NAME: String = "ZombieNet"

## Client: the mirror. Stays empty on the server.
var client_state: ClientZombieState
## Server diagnostics: snapshot messages, snapshot rows and events sent,
## each counted once per receiving peer.
var sent_snapshot_message_count: int = 0
var sent_snapshot_row_count: int = 0
var sent_event_count: int = 0
var unsendable_event_count: int = 0
## Server diagnostics: zombies a peer had to be told about because an event
## was addressed to its player (see ensure_known).
var forced_known_count: int = 0
## Client diagnostics: messages not sent by the server; snapshot messages,
## snapshot rows and events received from it.
var ignored_sender_count: int = 0
var received_snapshot_message_count: int = 0
var received_snapshot_row_count: int = 0
var received_event_count: int = 0

var _settings: ZombieNetSettings
var _zombies: ZombieService = null
var _world: ServerWorld = null
var _tick: int = 0
var _snapshot_elapsed: float = 0.0
## peer_id -> what that peer was told and still has to be told.
var _streams: Dictionary[int, PeerStream] = {}


## One peer's zombie stream.
class PeerStream extends RefCounted:
	## Ids of the zombies the peer was told about (its mirror's members).
	var known: Dictionary[String, bool] = {}
	## Sequence of the newest event queued for the peer (the first is 1).
	var sequence: int = 0
	## Wire events queued but not yet sent; the last one has `sequence`.
	var pending: Array[Dictionary] = []


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


func on_player_left(peer_id: int, _player_id: String) -> void:
	_streams.erase(peer_id)


func server_physics(delta: float) -> void:
	if _zombies == null:
		return
	_tick += 1
	_collect_events()
	_snapshot_elapsed += delta
	var period: float = 1.0 / _settings.snapshot_rate_hz
	var snapshot_due: bool = _snapshot_elapsed >= period
	var rows_by_peer: Dictionary[int, Array] = {}
	if snapshot_due:
		# Keep the remainder so the average rate is exact, but never burst.
		_snapshot_elapsed = minf(_snapshot_elapsed - period, period)
		rows_by_peer = _reconcile()
	# Events first: a zombie that entered a peer's view is in its mirror
	# before the snapshot rows of the same tick are sent.
	_send_pending_events()
	if snapshot_due:
		_send_snapshots(rows_by_peer)


## The zombies of the joining peer's cells as they are right now, and the
## start of that peer's own event stream. Events still queued in
## ZombieService are drained first and go to the peers that are already
## streaming; the joiner gets their result in these rows and nothing twice.
## For a peer that is streaming already (the join handshake never asks
## twice; a tool or a test might) the fragment is only a description of what
## a join would deliver now: that peer's stream is left as it is, and
## `event_sequence` is where its stream stands.
func build_join_fragment(player_id: String) -> Dictionary:
	if _zombies == null:
		return {}
	_collect_events()
	var peer_id: int = network.peer_of_player(player_id)
	var stream: PeerStream = _streams.get(peer_id, null)
	var joining: bool = stream == null
	if joining:
		stream = PeerStream.new()
		if peer_id != 0:
			_streams[peer_id] = stream
	var rows: Array = []
	for row: Dictionary in _zombies.snapshot_rows():
		var zombie_id: String = str(row.get("id", ""))
		if not network.is_cell_of_interest(peer_id, _world.cell_index.cell_of(zombie_id)):
			continue
		var encoded: Array = _encode_row(row)
		if encoded.is_empty():
			continue
		rows.append(encoded)
		if joining:
			stream.known[zombie_id] = true
	return {
		ZombieNetProtocol.KEY_TICK: _tick,
		ZombieNetProtocol.KEY_EVENT_SEQUENCE: stream.sequence,
		ZombieNetProtocol.KEY_ROWS: rows,
	}


## Server: true when `peer_id` was told about this zombie (it is in that
## client's mirror). For modules whose events name a zombie.
func knows_zombie(peer_id: int, zombie_id: String) -> bool:
	var stream: PeerStream = _streams.get(peer_id, null)
	return stream != null and stream.known.has(zombie_id)


## Server: makes sure `peer_id` was told about this zombie before a message
## that names it is sent to that peer: an unknown zombie that exists is sent
## as `zombie_entered` at once (with everything queued before it). Returns
## false when the zombie does not exist or the peer has no stream. The next
## reconciliation decides whether the zombie stays in the peer's mirror.
func ensure_known(peer_id: int, zombie_id: String) -> bool:
	var stream: PeerStream = _streams.get(peer_id, null)
	if stream == null or _zombies == null:
		return false
	if stream.known.has(zombie_id):
		return true
	if not _force_known(stream, zombie_id):
		return false
	_send_stream(peer_id, stream)
	return true


## Drains the domain queue and queues every event for the peers it is for.
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
		_route(wire)
	server_events_drained.emit(drained)


## Queues one wire event for the peers that are to get it (see "Scope").
func _route(wire: Dictionary) -> void:
	var zombie_id: String = str(wire[ZombieNetProtocol.KEY_ZOMBIE_ID])
	var event_type: String = str(wire[ZombieNetProtocol.KEY_EVENT_TYPE])
	if event_type == ZombieService.EVENT_SPAWNED:
		# A zombie that is already gone again was never shown to anybody.
		if not _zombies.has_zombie(zombie_id):
			return
		var cell_id: String = _world.cell_index.cell_of(zombie_id)
		for peer_id: int in _streams:
			var stream: PeerStream = _streams[peer_id]
			if not stream.known.has(zombie_id) and network.is_cell_of_interest(peer_id, cell_id):
				stream.known[zombie_id] = true
				_queue(stream, wire)
		return
	var owner_id: String = ZombieNetProtocol.private_owner(wire)
	var shared: Dictionary = ZombieNetProtocol.public_event(wire)
	for peer_id: int in _streams:
		var stream: PeerStream = _streams[peer_id]
		var is_owner: bool = not owner_id.is_empty() and network.player_of_peer(peer_id) == owner_id
		if not stream.known.has(zombie_id):
			# The attacked player is told what hit it, whatever its cells say.
			if not is_owner or not _force_known(stream, zombie_id):
				continue
		_queue(stream, wire if is_owner else shared)
		if event_type == ZombieService.EVENT_REMOVED:
			stream.known.erase(zombie_id)


func _queue(stream: PeerStream, wire: Dictionary) -> void:
	stream.sequence += 1
	stream.pending.append(wire)


## Tells a peer about a zombie outside its cells (queues `zombie_entered`).
## False when the zombie is not in memory.
func _force_known(stream: PeerStream, zombie_id: String) -> bool:
	for row: Dictionary in _zombies.snapshot_rows():
		if str(row.get("id", "")) != zombie_id:
			continue
		if not _queue_entered(stream, row):
			return false
		forced_known_count += 1
		return true
	return false


func _queue_entered(stream: PeerStream, row: Dictionary) -> bool:
	var wire: Dictionary = ZombieNetProtocol.entered_event(row, _world.clock.world_time_sec)
	if wire.is_empty():
		unsendable_event_count += 1
		GameLogger.error("net", "zombie event does not fit the wire format", {"entity_id": str(row.get("id", "")), "event_type": ZombieNetProtocol.EVENT_ENTERED, "operation": "queue_entered"})
		return false
	stream.known[str(row["id"])] = true
	_queue(stream, wire)
	return true


## Brings every peer's known zombies in line with its cells (see "Scope")
## and returns the snapshot rows of each peer: peer_id -> Array of wire rows
## (server spawn order).
func _reconcile() -> Dictionary[int, Array]:
	var rows_by_peer: Dictionary[int, Array] = {}
	var seen_by_peer: Dictionary[int, Dictionary] = {}
	for peer_id: int in _streams:
		rows_by_peer[peer_id] = []
		seen_by_peer[peer_id] = {}
	if _streams.is_empty():
		return rows_by_peer
	# cell_id -> the streaming peers interested in it (asked once per cell).
	var peers_by_cell: Dictionary[String, PackedInt32Array] = {}
	for row: Dictionary in _zombies.snapshot_rows():
		var zombie_id: String = str(row.get("id", ""))
		var cell_id: String = _world.cell_index.cell_of(zombie_id)
		if not peers_by_cell.has(cell_id):
			peers_by_cell[cell_id] = network.peers_interested_in(cell_id)
		var peers: PackedInt32Array = peers_by_cell[cell_id]
		if peers.is_empty():
			continue
		var encoded: Array = _encode_row(row)
		if encoded.is_empty():
			continue
		for peer_id: int in peers:
			var stream: PeerStream = _streams.get(peer_id, null)
			if stream == null:
				continue
			if not stream.known.has(zombie_id) and not _queue_entered(stream, row):
				continue
			seen_by_peer[peer_id][zombie_id] = true
			rows_by_peer[peer_id].append(encoded)
	var world_time: float = _world.clock.world_time_sec
	for peer_id: int in _streams:
		var stream: PeerStream = _streams[peer_id]
		var seen: Dictionary = seen_by_peer[peer_id]
		if stream.known.size() == seen.size():
			continue
		for zombie_id: String in stream.known.keys():
			if seen.has(zombie_id):
				continue
			stream.known.erase(zombie_id)
			_queue(stream, ZombieNetProtocol.left_event(zombie_id, world_time))
	return rows_by_peer


func _send_pending_events() -> void:
	for peer_id: int in _streams:
		_send_stream(peer_id, _streams[peer_id])


## Sends what is queued for one peer, in messages of `events_per_message`.
func _send_stream(peer_id: int, stream: PeerStream) -> void:
	if stream.pending.is_empty():
		return
	if network.can_send_to(peer_id):
		var first_sequence: int = stream.sequence - stream.pending.size() + 1
		var offset: int = 0
		while offset < stream.pending.size():
			var message: Array[Dictionary] = stream.pending.slice(offset, offset + _settings.events_per_message)
			_rpc_zombie_events.rpc_id(peer_id, _tick, first_sequence + offset, message)
			offset += message.size()
			sent_event_count += message.size()
	# A peer that cannot be sent to is on its way out.
	stream.pending.clear()


func _send_snapshots(rows_by_peer: Dictionary[int, Array]) -> void:
	for peer_id: int in rows_by_peer:
		var rows: Array = rows_by_peer[peer_id]
		if rows.is_empty() or not network.can_send_to(peer_id):
			continue
		var offset: int = 0
		while offset < rows.size():
			var chunk: Array = rows.slice(offset, offset + _settings.snapshot_rows_per_message)
			_rpc_zombie_snapshot.rpc_id(peer_id, _tick, chunk)
			sent_snapshot_message_count += 1
			sent_snapshot_row_count += chunk.size()
			offset += chunk.size()


## Wire row of one ZombieService.snapshot_rows() entry, [] (logged) when it
## does not fit the format.
func _encode_row(row: Dictionary) -> Array:
	var encoded: Array = ZombieNetProtocol.encode_row(row)
	if encoded.is_empty():
		GameLogger.error("net", "zombie row does not fit the wire format", {"entity_id": str(row.get("id", "")), "operation": "encode_rows"})
	return encoded


# ------------------------------------------------------------ client side

func apply_join_fragment(fragment: Dictionary) -> void:
	received_snapshot_message_count = 0
	received_snapshot_row_count = 0
	received_event_count = 0
	client_state.apply_join(fragment)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_zombie_snapshot(tick: Variant, rows: Variant) -> void:
	if not _from_server("zombie_snapshot"):
		return
	received_snapshot_message_count += 1
	if typeof(rows) == TYPE_ARRAY:
		received_snapshot_row_count += (rows as Array).size()
	client_state.apply_snapshot(tick, rows)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_zombie_events(tick: Variant, first_sequence: Variant, events: Variant) -> void:
	if not _from_server("zombie_events"):
		return
	if typeof(events) == TYPE_ARRAY:
		received_event_count += (events as Array).size()
	client_state.apply_events(tick, first_sequence, events)


## Client: true while handling an RPC the server sent. Anything else (a
## local call, another sender, the server role itself) is ignored and logged.
func _from_server(message: String) -> bool:
	if network != null and network.is_from_server():
		return true
	ignored_sender_count += 1
	GameLogger.warning("net", "zombie payload not sent by the server ignored", {"message": message, "sender": multiplayer.get_remote_sender_id() if is_inside_tree() else 0, "operation": "receive"})
	return false
