extends TestCase
## The server's ENet host has no bandwidth limit (docs/15 TT-001, docs/08
## §14.1), over real ENet with the production composition.
##
## Behaviour under test: a client that sends one move intent per server tick
## for five seconds gets (nearly) all of them to the server, in order, and
## ENet's packet throttle limit stays fully open on both ends the whole
## time.
##
## Why it can break: Godot 4.7.2's ENetMultiplayerPeer.create_server() with
## max_channels > 0 leaves the host with a tiny incoming bandwidth limit.
## Clients are told that limit when they connect, and ENet on the client
## then drops most unreliable packets (move intents) before they leave it:
## about a second after joining the throttle limit falls from 32 to 1 and
## the server hears a handful of intents per second. NetworkService lifts
## the limit right after it creates each host.
##
## Existing test files: network_movement_test.gd moves for half a second
## (too short to see the limit), network_session_test.gd covers joining and
## the compression contract.

const WORLD: String = "enet_bandwidth_test"
const PLAYER_KEY: String = "alice"
## Five seconds of intents: ENet recomputes its bandwidth throttle once a
## second, so the limit shows well inside this window.
const SEND_TICKS: int = 300
## Ticks waited for the last intents to arrive.
const SETTLE_TICKS: int = 30
## Share of the ticks in which the server must have heard something new. The
## channel is unreliable and a busy machine may lose or bunch a few. With
## the bandwidth limit in place the share was 0.80 at normal speed (241 of
## 300, measured 2026-11-19) and far lower when ticks come faster than real
## time; the throttle limit below is the exact check.
const MIN_HEARD_SHARE: float = 0.9
## The newest intent the server holds may be this many behind the last sent.
const MAX_TAIL_GAP: int = 5
const MOVE_DIRECTION: Vector2 = Vector2(1.0, 0.0)
const SERVER_PEER_ID: int = 1
## The request rate limit is measured in real time and is not under test.
const GENEROUS_RATE_PER_SEC: float = 240.0
const GENEROUS_BURST: int = 240

var _cluster: NetTestCluster = null
var _settings: NetworkSettings = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = NetworkSettings.new()
	_settings.autosave_interval_sec = 0.0
	_settings.move_intent_rate_per_sec = GENEROUS_RATE_PER_SEC
	_settings.move_intent_burst = GENEROUS_BURST
	_cluster = NetTestCluster.new(tree, _settings)
	_world = ServerWorld.new(WORLD, GameplaySettings.new(), ItemCatalog.load_directory())


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func test_five_seconds_of_move_intents_reach_the_server_and_the_throttle_stays_open() -> void:
	assert_eq(_cluster.start_server(_world, null), OK)
	var client: NetworkService = await _cluster.join_client(PLAYER_KEY)
	if client == null:
		fail("the client did not join")
		return
	var player_id: String = client.client_state.local_player_id
	var to_server: ENetPacketPeer = (client.multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(SERVER_PEER_ID)
	var to_client: ENetPacketPeer = (_cluster.server.multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(_cluster.server.peer_of_player(player_id))
	assert_not_null(to_server, "the client's ENet peer")
	assert_not_null(to_client, "the server's ENet peer")
	if to_server == null or to_client == null:
		return
	var full: float = float(ENetPacketPeer.PACKET_THROTTLE_SCALE)
	var lowest_limit_up: float = full
	var lowest_limit_down: float = full
	var heard_ticks: int = 0
	var went_back: bool = false
	var last_heard: int = _world.last_move_sequence(player_id)
	assert_eq(last_heard, ServerWorld.NO_MOVE_SEQUENCE, "nothing was sent yet")
	for tick: int in range(SEND_TICKS):
		# The client's sequence numbers are 1, 2, 3, ...: one per call.
		client.send_move_intent(MOVE_DIRECTION, 0.0)
		await tree.physics_frame
		var heard: int = _world.last_move_sequence(player_id)
		if heard > last_heard:
			heard_ticks += 1
		elif heard < last_heard:
			went_back = true
		last_heard = heard
		lowest_limit_up = minf(lowest_limit_up, to_server.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_LIMIT))
		lowest_limit_down = minf(lowest_limit_down, to_client.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_LIMIT))
	await _cluster.wait_ticks(SETTLE_TICKS)
	last_heard = _world.last_move_sequence(player_id)
	print("[enet] %d move intents sent in %d ticks: the server heard something new in %d ticks, newest sequence %d; lowest throttle limit client->server %d, server->client %d of %d" % [
		SEND_TICKS, SEND_TICKS, heard_ticks, last_heard, int(lowest_limit_up), int(lowest_limit_down), ENetPacketPeer.PACKET_THROTTLE_SCALE,
	])
	assert_eq(lowest_limit_up, full, "the client's throttle limit towards the server stays fully open (the server host has no incoming bandwidth limit)")
	assert_eq(lowest_limit_down, full, "the server's throttle limit towards the client stays fully open (the client host has no incoming bandwidth limit)")
	assert_false(went_back, "the server never goes back to an older intent")
	assert_true(heard_ticks >= ceili(float(SEND_TICKS) * MIN_HEARD_SHARE), "the server heard a new intent in %d of %d ticks (at least %d)" % [heard_ticks, SEND_TICKS, ceili(float(SEND_TICKS) * MIN_HEARD_SHARE)])
	assert_true(last_heard >= SEND_TICKS - MAX_TAIL_GAP and last_heard <= SEND_TICKS, "the newest intent on the server is one of the last sent: %d of %d" % [last_heard, SEND_TICKS])
	assert_eq(_cluster.server.rejected_intent_count(), 0, "the server refused none of them")
