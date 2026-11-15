class_name InterestNetModule
extends NetModule
## Per-client replication scope by world cell (P3-2, docs/09 §15.2). Server
## side only: this module has NO RPC and sends nothing itself. It owns the
## CellInterest of the session, keeps it in step with the server positions
## of the joined peers' players and with the cells the server has in memory,
## and hands it to NetworkService (`network.cell_interest`), where every
## module that replicates entities living in cells finds it:
##   network.cell_interest.cell_gained / cell_lost   signals
##   network.is_cell_of_interest(peer_id, cell_id)
##   network.peers_interested_in(cell_id)
## It knows nothing about items, zombies or any other kind of entity.
##
## Order (ServerComposition registers this module FIRST):
##   - join: this module's build_join_fragment() gives the joining peer its
##     first cells without signals, before any other module builds its join
##     fragment and before NetworkService lists the world items. The join
##     data of the other modules is therefore already cut to those cells.
##   - a joined player without a character has no cells; when its first
##     character enters the world (on_player_joined) the peer gains them.
##   - every server tick, before the other modules send anything, each peer
##     is looked at again: `cell_lost` for the cells its player left behind,
##     then `cell_gained` for the new ones.
##   - a cell coming into / leaving the server's memory (WorldCellService)
##     is gained / lost by the peers that want it.
## Whose cells count: the peers whose player is in the world
## (ServerWorld.is_online), dead characters included: a dead character's
## body stays where it fell and its player keeps seeing that place until the
## next character starts (the cell lifecycle treats it the same way, docs/15
## P3-029). Only server positions are read.

const MODULE_NAME: String = "InterestNet"

## Server: the session's cell interest (null on clients and before the
## server started).
var interest: CellInterest = null

var _settings: InterestSettings
var _world: ServerWorld = null
var _cells: WorldCellService = null


func _init(settings: InterestSettings = null) -> void:
	name = MODULE_NAME
	_settings = settings if settings != null else InterestSettings.new()


func _exit_tree() -> void:
	if _cells == null:
		return
	if _cells.cell_loaded.is_connected(_on_cell_loaded):
		_cells.cell_loaded.disconnect(_on_cell_loaded)
	if _cells.cell_unloading.is_connected(_on_cell_unloading):
		_cells.cell_unloading.disconnect(_on_cell_unloading)


func on_server_started(world: ServerWorld) -> void:
	_world = world
	interest = CellInterest.new(world.cell_grid, _settings, world.is_cell_loaded)
	network.cell_interest = interest
	_cells = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	if _cells != null:
		_cells.cell_loaded.connect(_on_cell_loaded)
		_cells.cell_unloading.connect(_on_cell_unloading)


## The joining peer's first cells, without signals: the join fragments built
## after this one (and the world items NetworkService lists) are cut to
## them. This module itself has nothing to send.
func build_join_fragment(player_id: String) -> Dictionary:
	if interest == null:
		return {}
	var peer_id: int = network.peer_of_player(player_id)
	# A peer that is tracked already keeps its cells (the join handshake never
	# asks twice; starting it afresh would change them without telling anyone).
	if peer_id == 0 or interest.has_peer(peer_id):
		return {}
	var state: PlayerState = _world.get_player(player_id)
	interest.begin_peer(peer_id, _world.is_online(player_id), state.position if state != null else Vector3.ZERO)
	return {}


## The player is in the world now. For a peer that joined with a character
## nothing changes (its cells came with the join); a peer whose first
## character was just created gains its cells here.
func on_player_joined(peer_id: int, _player_id: String) -> void:
	_look_at(peer_id)


func on_player_left(peer_id: int, _player_id: String) -> void:
	if interest != null:
		interest.remove_peer(peer_id)


## Looks at every joined peer's player once per server tick. This module is
## registered first, so the other modules send with this tick's cells.
func server_physics(_delta: float) -> void:
	if interest == null:
		return
	for peer_id: int in network.joined_peers():
		_look_at(peer_id)


func _look_at(peer_id: int) -> void:
	if interest == null:
		return
	var player_id: String = network.player_of_peer(peer_id)
	if player_id.is_empty():
		return
	var state: PlayerState = _world.get_player(player_id)
	interest.update_peer(peer_id, state != null and _world.is_online(player_id), state.position if state != null else Vector3.ZERO)


func _on_cell_loaded(cell_id: String) -> void:
	if interest != null:
		interest.notify_cell_loaded(cell_id)


func _on_cell_unloading(cell_id: String) -> void:
	if interest != null:
		interest.notify_cell_unloading(cell_id)
