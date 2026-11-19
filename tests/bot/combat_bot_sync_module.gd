class_name CombatBotSyncModule
extends NetModule
## Test-only NetModule of the combat bot harness (CombatBotRunner): a marker
## the client sends and the server sends straight back, on the reliable
## ordered channel. It carries no game data and changes no game state.
##
## What it is for: knowing that everything sent before the marker has
## arrived. The server answers the marker only after it handled every
## request the client sent before it, and the answer reaches the client only
## after everything the server sent before it (channel 0 is ordered; the
## datagrams of the other channels were put on the same localhost socket
## earlier and arrive in order). The harness polls both ends until the
## answer is in, so one tick's messages are never still on the wire when the
## next tick starts, however slow the machine is.

const MODULE_NAME: String = "CombatBotSync"

## Client: the highest marker the server has answered.
var answered: int = 0
var _sent: int = 0


func _init() -> void:
	name = MODULE_NAME


## Client: sends the next marker and returns its number.
func send_marker() -> int:
	_sent += 1
	_rpc_marker.rpc_id(NetworkService.SERVER_PEER_ID, _sent)
	return _sent


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_marker(number: Variant) -> void:
	if network == null or not network.is_server() or typeof(number) != TYPE_INT:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if network.can_send_to(peer_id):
		_rpc_marker_answer.rpc_id(peer_id, number)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_marker_answer(number: Variant) -> void:
	if network == null or not network.is_from_server() or typeof(number) != TYPE_INT:
		return
	answered = maxi(answered, int(number))
