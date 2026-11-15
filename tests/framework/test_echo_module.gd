class_name TestEchoModule
extends NetModule
## Test double for the NetModule seam: join fragment, validated
## client->server intent and server->client broadcast through its own RPCs.

const MODULE_NAME: String = "TestEcho"

var server_started: bool = false
var joined: PackedStringArray = []
var left: PackedStringArray = []
var physics_ticks: int = 0
## Server: (player_id, text) pairs received.
var received: Array[Array] = []
## Client: join fragment and broadcasts received.
var join_fragment: Dictionary = {}
var broadcasts: PackedStringArray = []


func _init() -> void:
	name = MODULE_NAME


func on_server_started(_world: ServerWorld) -> void:
	server_started = true


func on_player_joined(_peer_id: int, player_id: String) -> void:
	joined.append(player_id)


func on_player_left(_peer_id: int, player_id: String) -> void:
	left.append(player_id)


func server_physics(_delta: float) -> void:
	physics_ticks += 1


func build_join_fragment(player_id: String) -> Dictionary:
	return {"greeting": "hello " + player_id}


func apply_join_fragment(fragment: Dictionary) -> void:
	join_fragment = fragment


## Client API.
func send_echo(text: Variant) -> void:
	_rpc_echo.rpc_id(NetworkService.SERVER_PEER_ID, text)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_echo(text: Variant) -> void:
	if not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, "echo", NetworkService.NOT_JOINED)
		return
	if typeof(text) != TYPE_STRING:
		network.reject_intent(peer_id, "echo", IntentValidator.REASON_BAD_TYPE, player_id)
		return
	received.append([player_id, str(text)])
	for peer: int in network.joined_peers():
		if network.can_send_to(peer):
			_rpc_broadcast.rpc_id(peer, "%s:%s" % [player_id, str(text)])


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_broadcast(line: Variant) -> void:
	if not network.is_from_server() or typeof(line) != TYPE_STRING:
		return
	broadcasts.append(str(line))
