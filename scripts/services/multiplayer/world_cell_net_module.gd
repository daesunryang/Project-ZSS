class_name WorldCellNetModule
extends NetModule
## World cells as the clients see them (P3-1, P3-2; docs/09 §15.1, §15.2).
## This module has NO RPC of its own.
##
## 1. The map layout. The join fragment of this module is the server's cell
##    size and map rectangle (ClientWorldMap describes the format); the
##    client keeps it in `client_map`. Presentation draws the ground, the map
##    edges and the cell borders from it, never from its own settings files.
##
## 2. World items by cell (server). Every joined peer is told about the world
##    items of the cells it is interested in (NetworkService.cell_interest,
##    InterestNetModule), and only those:
##      - peer P gained cell C (it walked near, entered the world, or the
##        cell came into the server's memory): the items lying in C are sent
##        to P (InventoryNetModule.send_world_items_added);
##      - peer P lost cell C (it walked away, or the cell is about to leave
##        the server's memory): the items lying in C are taken out of P's
##        mirror (InventoryNetModule.send_world_items_removed).
##    The items a peer sees at join are in the join snapshot (NetworkService)
##    and items that are put down or picked up while a peer is told about
##    their cell are announced by InventoryNetModule / NetworkService to the
##    peers interested in that cell. Zombies are scoped by ZombieNetModule.
##
## Both messages belong to InventoryNetModule and are sent through its two
## public functions (docs/15 P3-030 is resolved: nothing is called by name).

const MODULE_NAME: String = "WorldCellNet"

## Client: the map layout the server sent with the join.
var client_map: ClientWorldMap = ClientWorldMap.new()
## Client diagnostics: join fragments that did not hold a usable layout.
var rejected_fragment_count: int = 0
## Server diagnostics: world items announced as added / removed because a
## peer gained / lost a cell, since the start.
var sent_item_add_count: int = 0
var sent_item_remove_count: int = 0

var _world: ServerWorld = null
var _interest: CellInterest = null
var _inventory_net: InventoryNetModule = null


func _init() -> void:
	name = MODULE_NAME


func _exit_tree() -> void:
	if _interest == null:
		return
	if _interest.cell_gained.is_connected(_on_cell_gained):
		_interest.cell_gained.disconnect(_on_cell_gained)
	if _interest.cell_lost.is_connected(_on_cell_lost):
		_interest.cell_lost.disconnect(_on_cell_lost)
	_interest = null


# ------------------------------------------------------------ server side

func on_server_started(world: ServerWorld) -> void:
	_world = world
	_inventory_net = network.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	if network.cell_interest == null or _inventory_net == null:
		GameLogger.error("net", "the interest module or the inventory module is missing; world items are not scoped by cell", {"world_id": world.world_id, "module": MODULE_NAME, "operation": "on_server_started"})
		return
	_interest = network.cell_interest
	_interest.cell_gained.connect(_on_cell_gained)
	_interest.cell_lost.connect(_on_cell_lost)


## The map layout: the same for every joining peer, with or without a
## character (it is no secret, and the ground must be there when the
## player enters the world).
func build_join_fragment(_player_id: String) -> Dictionary:
	return ClientWorldMap.describe(_world.cell_grid) if _world != null else {}


## The world items of a cell a peer is told about from now on.
func _on_cell_gained(peer_id: int, cell_id: String) -> void:
	if network == null or not network.is_server():
		return
	var item_ids: PackedStringArray = _world.inventory.world_item_ids_in_cell(cell_id)
	if item_ids.is_empty():
		return
	var entries: Array = []
	for item_id: String in item_ids:
		entries.append(_world.inventory.describe_world_item(item_id))
	sent_item_add_count += _inventory_net.send_world_items_added(peer_id, entries)


## The world items of a cell a peer is no longer told about.
func _on_cell_lost(peer_id: int, cell_id: String) -> void:
	if network == null or not network.is_server():
		return
	var item_ids: PackedStringArray = _world.inventory.world_item_ids_in_cell(cell_id)
	if item_ids.is_empty():
		return
	sent_item_remove_count += _inventory_net.send_world_items_removed(peer_id, Array(item_ids))


# ------------------------------------------------------------ client side

func apply_join_fragment(fragment: Dictionary) -> void:
	var reason: String = client_map.apply(fragment)
	if reason.is_empty():
		return
	rejected_fragment_count += 1
	GameLogger.warning("net", "map layout of the join snapshot ignored", {"reason": reason, "module": MODULE_NAME, "operation": "apply_join_fragment"})
