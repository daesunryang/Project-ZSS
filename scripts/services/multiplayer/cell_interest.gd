class_name CellInterest
extends RefCounted
## Which world cells each joined peer is told about (P3-2, docs/09 §15.2).
## Pure bookkeeping: no nodes, no RPC, and nothing about items, zombies or
## any other kind of entity. Whoever replicates entities that live in cells
## asks this object who is to be told and listens to its two signals.
## InterestNetModule owns one on the server and feeds it.
##
## A peer's cells are decided from the SERVER position of its player only
## (nothing a client sends reaches this class):
##   - every cell within `interest_radius_cells` of the cell the player is in
##     (a square, Chebyshev distance, cells of the map only) becomes of
##     interest;
##   - hysteresis: a cell that is of interest stays so until it is more than
##     `interest_radius_cells + keep_margin_cells` cells away. Walking to and
##     fro across a cell border therefore changes nothing after the first
##     crossing (no clock is involved);
##   - a peer whose player is not in the world (no character yet) has no
##     cells at all;
##   - a cell the server does not have in memory is of interest to nobody:
##     when it comes into memory the peers that want it gain it, and when it
##     is about to leave memory the peers that have it lose it. So "peer P is
##     interested in cell C" always means "P is to be told what is in C now".
##
## Contract for listeners:
##   - `cell_gained(peer_id, cell_id)`: tell that peer everything that is in
##     the cell now;
##   - `cell_lost(peer_id, cell_id)`: take everything of that cell away from
##     that peer (the entities can still be read while the signal is handled);
##   - an entity that appears in, changes in or leaves a cell is announced to
##     `peers_for_cell(cell_id)` only;
##   - begin_peer() gives a peer its first cells WITHOUT signals: they are
##     delivered with the join snapshot the caller is building (cells_of()).
## Within one update a peer first loses cells, then gains cells, each in cell
## order (x, then z).

## The peer is to be told about the entities of this cell from now on.
signal cell_gained(peer_id: int, cell_id: String)
## The peer is no longer told about this cell: what it was told is removed.
signal cell_lost(peer_id: int, cell_id: String)

## Diagnostics (tests / profiling): calls of update_peer, the ones that had
## to work the cells out again, and cells gained / lost since the start.
var update_count: int = 0
var recompute_count: int = 0
var gained_count: int = 0
var lost_count: int = 0

var _grid: WorldCellGrid
var _settings: InterestSettings
## (cell_id: String) -> bool: is the cell in the server's memory. An invalid
## Callable means that every cell is (a world without a cell lifecycle).
var _is_loaded: Callable
## peer_id -> its scope.
var _scopes: Dictionary[int, PeerScope] = {}
## cell_id -> {peer_id: true}: the peers that are told about the cell.
var _peers_by_cell: Dictionary[String, Dictionary] = {}


## One peer's cells.
class PeerScope extends RefCounted:
	var in_world: bool = false
	var center: Vector2i = Vector2i.ZERO
	## Cells the peer wants by position and hysteresis (in memory or not).
	var wanted: Dictionary[Vector2i, bool] = {}
	## cell -> its id: the wanted cells that are in memory = the cells the
	## peer is told about.
	var told: Dictionary[Vector2i, String] = {}


func _init(grid: WorldCellGrid, settings: InterestSettings, is_cell_loaded: Callable = Callable()) -> void:
	_grid = grid if grid != null else WorldCellGrid.new()
	_settings = settings if settings != null else InterestSettings.new()
	_is_loaded = is_cell_loaded


# ------------------------------------------------------------ peers

## Starts tracking a peer that is joining: works out its cells from its
## player's server position and emits NOTHING. The caller delivers the
## entities of cells_of(peer_id) with the join snapshot. `in_world` false (a
## joined player without a character) gives the peer no cells.
func begin_peer(peer_id: int, in_world: bool, position: Vector3) -> void:
	remove_peer(peer_id)
	var scope: PeerScope = PeerScope.new()
	_scopes[peer_id] = scope
	scope.in_world = in_world
	scope.center = _grid.cell_of(position)
	scope.wanted = _wanted_cells(scope)
	for cell: Vector2i in scope.wanted:
		var cell_id: String = WorldCellGrid.id_of(cell)
		if _loaded(cell_id):
			_tell(peer_id, scope, cell_id, cell)


## Looks at a peer's player again (every server tick, and at once when the
## player enters the world) and emits cell_lost / cell_gained for what
## changed. Cheap while the player stays in its cell. A peer that was never
## begun starts without cells, so everything it wants is gained.
func update_peer(peer_id: int, in_world: bool, position: Vector3) -> void:
	update_count += 1
	var scope: PeerScope = _scopes.get(peer_id, null)
	if scope == null:
		scope = PeerScope.new()
		_scopes[peer_id] = scope
	var center: Vector2i = _grid.cell_of(position)
	if in_world == scope.in_world and (not in_world or center == scope.center):
		return
	recompute_count += 1
	scope.in_world = in_world
	scope.center = center
	scope.wanted = _wanted_cells(scope)
	var lost: Array[Vector2i] = []
	for cell: Vector2i in scope.told:
		if not scope.wanted.has(cell):
			lost.append(cell)
	# Cell ids (strings) are only made for cells that are new to the peer.
	var gained: Array[Vector2i] = []
	for cell: Vector2i in scope.wanted:
		if not scope.told.has(cell) and _loaded(WorldCellGrid.id_of(cell)):
			gained.append(cell)
	lost.sort_custom(_cell_before)
	gained.sort_custom(_cell_before)
	for cell: Vector2i in lost:
		_untell_and_emit(peer_id, scope, cell)
	for cell: Vector2i in gained:
		_tell_and_emit(peer_id, scope, WorldCellGrid.id_of(cell), cell)


## Forgets a peer that left. Nothing is emitted: nobody is there to be told.
func remove_peer(peer_id: int) -> void:
	var scope: PeerScope = _scopes.get(peer_id, null)
	if scope == null:
		return
	for cell: Vector2i in scope.told:
		_forget_peer_of_cell(peer_id, scope.told[cell])
	_scopes.erase(peer_id)


func has_peer(peer_id: int) -> bool:
	return _scopes.has(peer_id)


## Tracked peer ids, sorted.
func peer_ids() -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array(_scopes.keys())
	ids.sort()
	return ids


# ------------------------------------------------------------ cells in memory

## A cell came into the server's memory: the peers that want it gain it.
func notify_cell_loaded(cell_id: String) -> void:
	var parsed: Variant = WorldCellGrid.parse_id(cell_id)
	if parsed == null:
		return
	var cell: Vector2i = parsed
	for peer_id: int in peer_ids():
		var scope: PeerScope = _scopes[peer_id]
		if scope.wanted.has(cell) and not scope.told.has(cell):
			_tell_and_emit(peer_id, scope, cell_id, cell)


## A cell is about to leave the server's memory (its entities can still be
## read): the peers that were told about it lose it. They keep wanting it and
## gain it again when it comes back while they are still near.
func notify_cell_unloading(cell_id: String) -> void:
	var parsed: Variant = WorldCellGrid.parse_id(cell_id)
	if parsed == null:
		return
	var cell: Vector2i = parsed
	for peer_id: int in peers_for_cell(cell_id):
		_untell_and_emit(peer_id, _scopes[peer_id], cell)


# ------------------------------------------------------------ queries

## True when `peer_id` is to be told about the entities of `cell_id`.
func is_interested(peer_id: int, cell_id: String) -> bool:
	var members: Dictionary = _peers_by_cell.get(cell_id, {})
	return members.has(peer_id)


## The peers that are to be told about the entities of `cell_id`, sorted.
func peers_for_cell(cell_id: String) -> PackedInt32Array:
	var members: Dictionary = _peers_by_cell.get(cell_id, {})
	var peers: PackedInt32Array = PackedInt32Array(members.keys())
	peers.sort()
	return peers


## Ids of the cells `peer_id` is told about, in cell order (x, then z).
func cells_of(peer_id: int) -> PackedStringArray:
	var ids: PackedStringArray = []
	var scope: PeerScope = _scopes.get(peer_id, null)
	if scope == null:
		return ids
	var cells: Array[Vector2i] = []
	for cell: Vector2i in scope.told:
		cells.append(cell)
	cells.sort_custom(_cell_before)
	for cell: Vector2i in cells:
		ids.append(scope.told[cell])
	return ids


## Number of cells `peer_id` is told about.
func cell_count_of(peer_id: int) -> int:
	var scope: PeerScope = _scopes.get(peer_id, null)
	return scope.told.size() if scope != null else 0


# ------------------------------------------------------------ internals

## The cells a scope wants at its centre: the square around it, plus the
## cells it wanted before that are still within the keep radius.
func _wanted_cells(scope: PeerScope) -> Dictionary[Vector2i, bool]:
	var wanted: Dictionary[Vector2i, bool] = {}
	if not scope.in_world:
		return wanted
	var keep_radius: int = _settings.keep_radius_cells()
	for cell: Vector2i in scope.wanted:
		if WorldCellGrid.distance(cell, scope.center) <= keep_radius:
			wanted[cell] = true
	for cell: Vector2i in _grid.cells_within(scope.center, _settings.interest_radius_cells):
		wanted[cell] = true
	return wanted


func _loaded(cell_id: String) -> bool:
	return not _is_loaded.is_valid() or bool(_is_loaded.call(cell_id))


func _tell(peer_id: int, scope: PeerScope, cell_id: String, cell: Vector2i) -> void:
	scope.told[cell] = cell_id
	if not _peers_by_cell.has(cell_id):
		_peers_by_cell[cell_id] = {}
	_peers_by_cell[cell_id][peer_id] = true


func _tell_and_emit(peer_id: int, scope: PeerScope, cell_id: String, cell: Vector2i) -> void:
	_tell(peer_id, scope, cell_id, cell)
	gained_count += 1
	cell_gained.emit(peer_id, cell_id)


## Like a gain, a loss is recorded before its signal is emitted: while
## `cell_lost` is handled the queries already answer without that cell.
func _untell_and_emit(peer_id: int, scope: PeerScope, cell: Vector2i) -> void:
	if not scope.told.has(cell):
		return
	var cell_id: String = scope.told[cell]
	scope.told.erase(cell)
	_forget_peer_of_cell(peer_id, cell_id)
	lost_count += 1
	cell_lost.emit(peer_id, cell_id)


func _forget_peer_of_cell(peer_id: int, cell_id: String) -> void:
	var members: Dictionary = _peers_by_cell.get(cell_id, {})
	members.erase(peer_id)
	if members.is_empty():
		_peers_by_cell.erase(cell_id)


static func _cell_before(a: Vector2i, b: Vector2i) -> bool:
	return a.x < b.x if a.x != b.x else a.y < b.y
