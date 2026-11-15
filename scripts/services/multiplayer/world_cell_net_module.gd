class_name WorldCellNetModule
extends NetModule
## Keeps the clients' picture of world items in step with the cells the
## server has in memory (P3-1, docs/09 §15.1). Server side only; this module
## has NO RPC of its own and so changes nothing in the protocol.
##
## The server announces to every joined peer:
##   - a cell came into memory (WorldCellService.cell_loaded): its world
##     items, with the message that announces a dropped item
##     (InventoryNetModule._rpc_world_items_added);
##   - a cell is about to leave memory (cell_unloading): each of its world
##     items, with the message that announces a picked-up item
##     (NetworkService._rpc_world_item_removed).
## So a client never keeps showing an item the server has released, and
## gets the items of a cell that is loaded while it is connected. Zombies
## are announced the same way by ZombieNetModule. A peer that joins later
## gets what is in memory at that moment in its join snapshot.
##
## Both messages belong to other nodes and are sent by name: those files are
## frozen (network_service.gd, docs/09 §14.5) or owned by another ticket
## (inventory_net_module.gd). on_server_started checks that they exist.
##
## No interest management yet: every joined peer is told about every cell
## in memory (docs/15 P3-014). Per-client scope is P3-2 and belongs here.

const MODULE_NAME: String = "WorldCellNet"
## The existing messages this module sends (see the header).
const RPC_WORLD_ITEMS_ADDED: StringName = &"_rpc_world_items_added"
const RPC_WORLD_ITEM_REMOVED: StringName = &"_rpc_world_item_removed"

## Diagnostics: world items announced as added / removed since the start.
var sent_item_add_count: int = 0
var sent_item_remove_count: int = 0

var _settings: InventoryNetSettings
var _world: ServerWorld = null
var _cells: WorldCellService = null
var _inventory_net: NetModule = null


## `settings` gives the number of world items packed into one message.
func _init(settings: InventoryNetSettings = null) -> void:
	name = MODULE_NAME
	_settings = settings if settings != null else InventoryNetSettings.new()


func _exit_tree() -> void:
	if _cells == null:
		return
	if _cells.cell_loaded.is_connected(_on_cell_loaded):
		_cells.cell_loaded.disconnect(_on_cell_loaded)
	if _cells.cell_unloading.is_connected(_on_cell_unloading):
		_cells.cell_unloading.disconnect(_on_cell_unloading)


func on_server_started(world: ServerWorld) -> void:
	_world = world
	_cells = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	if _cells == null:
		GameLogger.info("net", "world has no cell system, cell replication is off", {"world_id": world.world_id, "module": MODULE_NAME})
		return
	_inventory_net = network.get_module(InventoryNetModule.MODULE_NAME)
	if _inventory_net == null or not _inventory_net.has_method(RPC_WORLD_ITEMS_ADDED) or not network.has_method(RPC_WORLD_ITEM_REMOVED):
		GameLogger.error("net", "the world item messages are missing; cell replication is off", {"world_id": world.world_id, "module": MODULE_NAME, "operation": "on_server_started"})
		_cells = null
		return
	_cells.cell_loaded.connect(_on_cell_loaded)
	_cells.cell_unloading.connect(_on_cell_unloading)


## The world items of a cell that came into memory go to every joined peer.
func _on_cell_loaded(cell_id: String) -> void:
	if network == null or not network.is_server():
		return
	var peers: PackedInt32Array = network.joined_peers()
	if peers.is_empty():
		return
	var entries: Array = []
	for item_id: String in _world.inventory.world_item_ids_in_cell(cell_id):
		var entry: Dictionary = _world.inventory.describe_world_item(item_id)
		# The server holds its own output to the rule its clients apply.
		if not ClientWorldState.is_valid_world_item(entry):
			GameLogger.error("net", "world item not replicated", {"entity_id": item_id, "cell_id": cell_id, "module": MODULE_NAME, "operation": "cell_loaded"})
			continue
		entries.append(entry)
	var offset: int = 0
	while offset < entries.size():
		var message: Array = entries.slice(offset, offset + _settings.max_items_per_message)
		for peer_id: int in peers:
			if network.can_send_to(peer_id):
				_inventory_net.rpc_id(peer_id, RPC_WORLD_ITEMS_ADDED, message)
		offset += message.size()
		sent_item_add_count += message.size()


## The world items of a cell that is about to leave memory are taken away
## from every joined peer.
func _on_cell_unloading(cell_id: String) -> void:
	if network == null or not network.is_server():
		return
	var peers: PackedInt32Array = network.joined_peers()
	if peers.is_empty():
		return
	for item_id: String in _world.inventory.world_item_ids_in_cell(cell_id):
		for peer_id: int in peers:
			if network.can_send_to(peer_id):
				network.rpc_id(peer_id, RPC_WORLD_ITEM_REMOVED, item_id)
		sent_item_remove_count += 1
