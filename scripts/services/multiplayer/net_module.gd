class_name NetModule
extends Node
## Base class for feature network modules (zombies, combat, survival, ...).
##
## A module is a child node of NetworkService with the same node name on
## every peer (set `name` in _init), so its own @rpc methods have matching
## paths. It is registered with NetworkService.register_module() before the
## service starts (ServerComposition.install_net_modules does this).
## Rules (CLAUDE.md §5): client->server RPCs take Variant args and are
## validated + rate limited on the server; server->client RPCs use
## @rpc("authority", ...) and re-check `network.is_from_server()`; every
## server send is guarded with `network.can_send_to(peer_id)`.
##
## Default hook implementations are intentional no-ops.

## Set by NetworkService.register_module().
var network: NetworkService = null


## Server: the service started; `world` is the authoritative world.
func on_server_started(_world: ServerWorld) -> void:
	return


## Server: a peer completed the join handshake (called after the join
## snapshot was sent, so module messages arrive after it).
func on_player_joined(_peer_id: int, _player_id: String) -> void:
	return


## Server: a joined peer left (after ServerWorld.leave()).
func on_player_left(_peer_id: int, _player_id: String) -> void:
	return


## Server: every physics tick, after ServerWorld systems stepped.
func server_physics(_delta: float) -> void:
	return


## Server: module part of the join snapshot for `player_id`
## (sent as snapshot["modules"][name]). Must be RPC-encodable, no Objects.
func build_join_fragment(_player_id: String) -> Dictionary:
	return {}


## Client: apply this module's part of the join snapshot ({} if absent).
func apply_join_fragment(_fragment: Dictionary) -> void:
	return
