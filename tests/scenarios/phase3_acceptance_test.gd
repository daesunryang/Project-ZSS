extends TestCase
## Phase 3 acceptance (docs/13 §5: "cells can be walked through, saved and
## restored, and two players see the same structure"; docs/03 §9, docs/04
## §12). One server and two or three clients talk over real ENet sockets on
## localhost with the production composition, the way a dedicated server
## runs it: the world is created by WorldPersistence on real files, so it
## gets the dev world seed (wood, nails, food, water near the spawn point)
## and the shipped 500 m test map (8 buildings, 370 structures, 21
## containers), and released cells go to cell files.
##
## Nothing is isolated: pickup, drop, place, deliver, work, door and
## container intents, the cell lifecycle, the interest cells, zombie AI with
## path finding, footsteps and all NetModules run as shipped. Server-side
## calls are used only to move players (set their server position: a 200 m
## walk would take a minute), to put zombies into the world (there is no
## other source of a zombie at a known place), and to read the authoritative
## state that the client mirrors and the restored world are compared with.
## Waits are limited in server ticks (docs/12 §1.1), never real time.
##
## Settings that differ from the production tuning files (new resource
## instances; the cached defaults are never edited):
##   zombie.dev_spawn_count 12 -> 0           the tests place their zombies
##   world_cells.preload_lookahead_sec 4 -> 0  players are moved by setting
##                                             their position; the speed of
##                                             such a jump would preload
##                                             cells along a line
##   world_cells.deactivate_delay_sec 5 -> 0.5 a cell nobody wants is
##   world_cells.unload_delay_sec 20 -> 1      released within the test
##   network autosave 60 s -> off              saves happen at known points
##   CompositionConfig.map_content null -> the shipped test map (what the
##                                             dedicated server uses)

const WORLD: String = "phase3_world"
## Limits of the waits, in server ticks (60 per simulated second).
const WAIT_TICKS: int = 600
const BUILD_TICKS: int = 1800
const SETTLE_TICKS: int = 20
const DEACTIVATE_SEC: float = 0.5
const UNLOAD_SEC: float = 1.0
## JSON keeps about 14 significant digits; positions are 32-bit floats.
const TOLERANCE: float = 1.0e-6
const MIRROR_POSITION_TOLERANCE_M: float = 0.01
## Items of the dev world seed and where it puts them
## (data/tuning/dev_world_seed.tres).
const WOOD: String = "dev_wood"
const NAILS: String = "dev_nails"
const FOOD: String = "dev_food_ration"
const WATER: String = "dev_water_bottle"
const TEST_ITEM: String = "dev_test_item"
const WOOD_AT: Vector3 = Vector3(4.0, 0.0, 3.0)
const NAILS_AT: Vector3 = Vector3(-4.0, 0.0, 3.0)
const FOOD_AT: Vector3 = Vector3(2.0, 0.0, 2.0)
const OTHER_FOOD_AT: Vector3 = Vector3(2.0, 0.0, -2.0)
const WATER_AT: Vector3 = Vector3(-2.0, 0.0, 2.0)
const TEST_ITEM_AT: Vector3 = Vector3(6.0, 0.0, 0.0)
## Where a player stands to pick an item up (pickup range 2.5 m).
const PICKUP_OFFSET: Vector3 = Vector3(0.0, 0.0, 0.5)
## The shipped structures.
const WALL: String = "dev_wall"
const FLOOR: String = "dev_floor"
const DOOR: String = "dev_door"
const WALL_COSTS: Dictionary = {"dev_wood": 4, "dev_nails": 2}
## The wall the players build: the -Z edge of tile (0, 6), the line z = 6
## for x in [0, 1], on open ground between the spawn point and the shed.
const WALL_TILE: Vector2i = Vector2i(0, 6)
const WALL_ROTATION: int = 0
const WALL_Z: float = 6.0
const BUILDER_AT: Vector3 = Vector3(0.3, 0.0, 7.5)
const WATCHER_AT: Vector3 = Vector3(0.7, 0.0, 7.2)
## Beside the wall, where nothing is in the way.
const BESIDE_THE_WALL_AT: Vector3 = Vector3(2.5, 0.0, 7.2)
## house_a of the test map: tiles x 8..12, z 8..11 (origin (8, 8), 5 x 4),
## its door on the -Z side at tile (10, 8), a cabinet at tile (12, 11).
const HOUSE_MIN: Vector2 = Vector2(8.0, 8.0)
const HOUSE_MAX: Vector2 = Vector2(13.0, 12.0)
const HOUSE_DOOR_TILE: Vector2i = Vector2i(10, 8)
const HOUSE_DOOR_ROTATION: int = 0
const HOUSE_WALL_TILE: Vector2i = Vector2i(8, 8)
const OUTSIDE_THE_DOOR: Vector3 = Vector3(10.5, 0.0, 6.8)
const ALSO_OUTSIDE_THE_DOOR: Vector3 = Vector3(10.0, 0.0, 6.5)
const BY_THE_HOUSE_WALL: Vector3 = Vector3(8.5, 0.0, 6.5)
const CABINET_AT: Vector3 = Vector3(12.5, 0.0, 11.5)
const CABINET_STAND: Vector3 = Vector3(12.5, 0.0, 10.5)
const ALSO_CABINET_STAND: Vector3 = Vector3(11.5, 0.0, 10.0)
## Far away: the cell cell_4_4 (x and z 200..250), four cells from the
## spawn cell, so nobody standing at the spawn point keeps it in memory.
const FAR: Vector3 = Vector3(215.0, 0.0, 215.0)
const FAR_CELL: String = "cell_4_4"
const FAR_FLOOR_TILE: Vector2i = Vector2i(215, 216)
## A walk from FAR to the spawn cell, one cell border (on both axes) per step.
const ROUTE_IN: PackedVector3Array = [Vector3(165.0, 0.0, 165.0), Vector3(115.0, 0.0, 115.0), Vector3(65.0, 0.0, 65.0), Vector3(15.0, 0.0, 15.0)]
const ROUTE_OUT: PackedVector3Array = [Vector3(65.0, 0.0, 65.0), Vector3(115.0, 0.0, 115.0), Vector3(165.0, 0.0, 165.0), Vector3(215.0, 0.0, 215.0)]
## Just west of the border x = 0 (cell_-1_-1 | cell_0_-1), on open ground.
const BORDER_WEST_OF: Vector3 = Vector3(-1.5, 0.0, -35.0)
## A floor both players ask for in the same frame (docs/04 §10).
const CONTESTED_TILE: Vector2i = Vector2i(1, 8)
## Zombies: one in the far cell, one in cell_3_3 (kept in memory by a player
## at the spawn point, but outside its interest cells and not simulated),
## one in cell_-2_-2 (inside the interest cells of the spawn point). All
## more than the sight range (25 m) away from where players stand.
const FAR_ZOMBIE_AT: Vector3 = Vector3(240.0, 0.0, 240.0)
const MIDDLE_ZOMBIE_AT: Vector3 = Vector3(190.0, 0.0, 190.0)
const NEAR_ZOMBIE_AT: Vector3 = Vector3(-70.0, 0.0, -70.0)
## Yaw 0 faces -Z (docs/09 §14.9).
const YAW_PLUS_Z: float = PI
## The navigation case: a zombie outside the closed door of house_a, facing
## it, and a player inside who walks to and fro (footsteps go through walls).
const ZOMBIE_AT_THE_DOOR: Vector3 = Vector3(10.5, 0.0, 6.0)
const INSIDE_WEST: Vector3 = Vector3(9.5, 0.0, 9.5)
const INSIDE_STRIDE_TICKS: int = 36
const INSIDE_LAPS: int = 3
## Move intents: sent every few ticks (the move channel is unreliable and the
## server forgets an input after 0.5 s), then a few zero intents to stop.
const INTENT_EVERY_TICKS: int = 5
const STOP_INTENTS: int = 3
## 90 ticks at 4 m/s is 6 m: far beyond the wall from where players stand.
const WALK_TICKS: int = 90
## 45 ticks is 3 m: from outside the door of house_a to well inside.
const WALK_IN_TICKS: int = 45
const COLLISION_SKIN_M: float = 0.05
const PROGRESS_TO_STOP_AT: float = 0.4
const PUT_FOOD: int = 2
const MISSING_CONTAINER_ID: String = "container_999999"
const MISSING_STRUCTURE_ID: String = "structure_999999"
const MISSING_ITEM_ID: String = "item_999999"
const FAR_PLACE_TILE: Vector2i = Vector2i(20, 30)

var _root: String = ""
var _net_settings: NetworkSettings = null
var _config: CompositionConfig = null
var _cluster: NetTestCluster = null
var _persistence: WorldPersistence = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/phase3_%d" % Time.get_ticks_usec()
	_net_settings = NetworkSettings.new()
	_net_settings.autosave_interval_sec = 0.0
	_config = _new_config()
	_cluster = null
	_persistence = null
	_world = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
		_cluster = null
	# The worlds hold connections to lambdas of this test: let them go.
	_world = null
	_persistence = null
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ============================================================ setup

## Production settings; the resources the tests change are copies.
func _new_config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.zombie = config.zombie.duplicate() as ZombieSettings
	config.zombie.dev_spawn_count = 0
	config.world_cells = config.world_cells.duplicate() as WorldCellSettings
	config.world_cells.preload_lookahead_sec = 0.0
	config.world_cells.deactivate_delay_sec = DEACTIVATE_SEC
	config.world_cells.unload_delay_sec = UNLOAD_SEC
	config.map_content = MapContentDefinition.load_or_null()
	return config


## A server start: the world as WorldPersistence finds it on disk (a new one
## the first time, seeded with the dev items and the test map).
func _load_from_disk() -> bool:
	_persistence = WorldPersistence.new(SaveService.new(_root), _config)
	_world = _persistence.load_or_create(WORLD)
	if _world == null:
		fail("the world could not be loaded or created")
		return false
	return true


func _serve() -> bool:
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	if _cluster.start_server(_world, _persistence) != OK:
		fail("the server did not start")
		return false
	return true


func _start() -> bool:
	return _load_from_disk() and _serve()


func _join(player_key: String) -> NetworkService:
	var client: NetworkService = await _cluster.join_client(player_key)
	if client == null:
		fail("%s did not join" % player_key)
	return client


func _id(client: NetworkService) -> String:
	return client.client_state.local_player_id


func _peer(client: NetworkService) -> int:
	return _cluster.server.peer_of_player(_id(client))


## Polls once per frame; the limit is in server ticks (docs/12 §1.1).
func _until(condition: Callable, max_ticks: int = WAIT_TICKS) -> bool:
	return await _cluster.wait_ticks_until(condition, max_ticks)


func _settle() -> void:
	await _cluster.wait_ticks(SETTLE_TICKS)


## Puts a player somewhere on the server and waits until its own client has
## seen that position (so the server has looked at it since).
func _move(client: NetworkService, position: Vector3) -> void:
	var player_id: String = _id(client)
	_world.get_player(player_id).position = position
	var arrived: bool = await _until(func() -> bool: return client.client_state.position_of(player_id).distance_to(position) < MIRROR_POSITION_TOLERANCE_M)
	if not arrived:
		fail("%s never saw itself at %s" % [player_id, str(position)])
	await _settle()


## Walks players with move intents for `ticks` server ticks, then stops them.
func _walk(clients: Array[NetworkService], direction: Vector2, ticks: int) -> void:
	for tick: int in range(ticks):
		if tick % INTENT_EVERY_TICKS == 0:
			for client: NetworkService in clients:
				client.send_move_intent(direction, 0.0)
		await tree.physics_frame
	for stop: int in range(STOP_INTENTS):
		for client: NetworkService in clients:
			client.send_move_intent(Vector2.ZERO, 0.0)
		await tree.physics_frame
	await _settle()


func _server_position(client: NetworkService) -> Vector3:
	return _world.get_player(_id(client)).position


func _building(world: ServerWorld = _world) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _containers(world: ServerWorld = _world) -> ContainerService:
	return world.get_system(ContainerService.SYSTEM_ID) as ContainerService


func _zombies(world: ServerWorld = _world) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _cells(world: ServerWorld = _world) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _map(world: ServerWorld = _world) -> MapContentService:
	return world.get_system(MapContentService.SYSTEM_ID) as MapContentService


func _survival(world: ServerWorld = _world) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


## Preparation only: puts a zombie into the server world.
func _spawn_zombie(position: Vector3, yaw: float) -> String:
	var spawned: ActionResult = _zombies().spawn_zombie(_world, position, yaw)
	if not spawned.ok:
		fail("test setup: zombie refused: " + spawned.reason)
		return ""
	return str(spawned.event.get("zombie_id", ""))


# ============================================================ requests

## Sends one request (`send` returns its id) and waits for its answer on a
## result signal of the shape (request_id, ok, reason): [ok, reason].
func _ask(result_signal: Signal, send: Callable) -> Array:
	var answers: Dictionary = {}
	var record: Callable = func(request_id: int, ok: bool, reason: String) -> void: answers[request_id] = [ok, reason]
	result_signal.connect(record)
	var request_id: int = send.call()
	await _until(func() -> bool: return answers.has(request_id))
	result_signal.disconnect(record)
	return answers.get(request_id, [false, "no_answer"])


## The same for StructureNet answers: [ok, reason, structure_id].
func _ask_structure(client: NetworkService, send: Callable) -> Array:
	var answers: Dictionary = {}
	var record: Callable = func(request_id: int, ok: bool, reason: String, structure_id: String) -> void: answers[request_id] = [ok, reason, structure_id]
	_structure_net(client).structure_result.connect(record)
	var request_id: int = send.call()
	await _until(func() -> bool: return answers.has(request_id))
	_structure_net(client).structure_result.disconnect(record)
	return answers.get(request_id, [false, "no_answer", ""])


func _pickup(client: NetworkService, item_id: String) -> Array:
	return await _ask(client.pickup_result, func() -> int: return client.request_pickup(item_id))


func _drop(client: NetworkService, item_id: String, quantity: int) -> Array:
	var module: InventoryNetModule = client.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	return await _ask(module.drop_result, func() -> int: return module.request_drop(item_id, quantity))


func _container_ask(client: NetworkService, send: Callable) -> Array:
	return await _ask(_container_net(client).container_result, send)


## Walks to an item of the dev seed and picks it up through the network.
func _pick_up_seeded(client: NetworkService, definition_id: String, at: Vector3) -> String:
	await _move(client, at + PICKUP_OFFSET)
	var item_id: String = _item_near(definition_id, at)
	var answer: Array = await _pickup(client, item_id)
	if answer != [true, ""]:
		fail("test setup: %s could not pick up %s: %s" % [_id(client), definition_id, str(answer)])
	return item_id


## The world item of a kind lying at a place (in server memory).
func _item_near(definition_id: String, at: Vector3) -> String:
	for item_id: String in _world.inventory.world_item_ids():
		if _world.inventory.get_item(item_id).definition_id == definition_id and _world.inventory.world_position_of(item_id).distance_to(at) < 0.5:
			return item_id
	fail("test setup: no %s at %s" % [definition_id, str(at)])
	return ""


## Picks up the dev wood (20) and nails (30) a wall needs.
func _gather_materials(client: NetworkService) -> void:
	await _pick_up_seeded(client, WOOD, WOOD_AT)
	await _pick_up_seeded(client, NAILS, NAILS_AT)


## What a player carries, as its own client's mirror has it: {id: [kind, units]}.
func _mirror_carried(client: NetworkService) -> Dictionary:
	var carried: Dictionary = {}
	for entry: Dictionary in client.client_state.inventory:
		carried[str(entry["item_instance_id"])] = [str(entry["definition_id"]), int(entry["quantity"])]
	return carried


func _server_carried(player_id: String, world: ServerWorld = _world) -> Dictionary:
	var carried: Dictionary = {}
	for item: ItemInstance in world.inventory.items_in_inventory(world.get_player(player_id).inventory_id):
		carried[item.item_instance_id] = [item.definition_id, item.quantity]
	return carried


func _units(carried: Dictionary, definition_id: String) -> int:
	var units: int = 0
	for item_id: String in carried:
		if str(carried[item_id][0]) == definition_id:
			units += int(carried[item_id][1])
	return units


# ============================================================ structures

func _structure_net(client: NetworkService) -> StructureNetModule:
	return client.get_module(StructureNetModule.MODULE_NAME) as StructureNetModule


func _structures(client: NetworkService) -> ClientStructureState:
	return _structure_net(client).client_state


## The server's structure as a client mirror holds it.
func _server_entry(structure_id: String) -> Dictionary:
	var row: Dictionary = _building().public_row(_building().get_structure(structure_id))
	return {
		"definition_id": row["definition_id"], "tile": Vector2i(int(row["x"]), int(row["z"])), "rotation": row["rotation"], "state": row["state"],
		"door_open": row["door_open"], "health_fraction": row["health_fraction"], "progress": row["progress"], "delivered": row["delivered"], "required": row["required"],
	}


func _mirrors_agree(clients: Array[NetworkService], structure_id: String) -> bool:
	if not _building().has_structure(structure_id):
		return false
	var expected: Dictionary = _server_entry(structure_id)
	for client: NetworkService in clients:
		if not _structures(client).has_structure(structure_id) or _structures(client).get_structure(structure_id) != expected:
			return false
	return true


## The seeded structure of house_a at a tile and rotation.
func _house_piece(definition_id: String, tile: Vector2i, rotation: int) -> String:
	for structure_id: String in _building().structure_ids():
		var structure: StructureInstance = _building().get_structure(structure_id)
		if structure.definition_id == definition_id and structure.tile == tile and structure.rotation == rotation:
			return structure_id
	fail("test setup: house_a has no %s at %s" % [definition_id, str(tile)])
	return ""


func _house_door() -> String:
	return _house_piece(DOOR, HOUSE_DOOR_TILE, HOUSE_DOOR_ROTATION)


func _is_inside_the_house(position: Vector3) -> bool:
	return position.x > HOUSE_MIN.x and position.x < HOUSE_MAX.x and position.z > HOUSE_MIN.y and position.z < HOUSE_MAX.y


## Places the wall blueprint through `client` and returns its id.
func _place_wall(client: NetworkService) -> String:
	var answer: Array = await _ask_structure(client, func() -> int: return _structure_net(client).request_place(WALL, WALL_TILE, WALL_ROTATION))
	if not bool(answer[0]):
		fail("test setup: the wall was not placed: %s" % str(answer))
	return str(answer[2])


# ============================================================ containers

func _container_net(client: NetworkService) -> ContainerNetModule:
	return client.get_module(ContainerNetModule.MODULE_NAME) as ContainerNetModule


func _container_mirror(client: NetworkService) -> ClientContainerState:
	return _container_net(client).client_state


## The seeded container standing at a place.
func _container_at(at: Vector3) -> String:
	for container_id: String in _containers().container_ids():
		if _containers().get_container(container_id).position.distance_to(at) < 0.01:
			return container_id
	fail("test setup: no container at %s" % str(at))
	return ""


## {item id: [kind, units]} of what a client sees in the container it opened.
func _mirror_contents(client: NetworkService) -> Dictionary:
	var contents: Dictionary = {}
	for entry: Dictionary in _container_mirror(client).contents():
		contents[str(entry[ClientContainerState.KEY_ITEM_ID])] = [str(entry[ClientContainerState.KEY_DEFINITION_ID]), int(entry[ClientContainerState.KEY_QUANTITY])]
	return contents


func _server_contents(container_id: String, world: ServerWorld = _world) -> Dictionary:
	var contents: Dictionary = {}
	for entry: Dictionary in _containers(world).contents_of(container_id):
		contents[str(entry["item_instance_id"])] = [str(entry["definition_id"]), int(entry["quantity"])]
	return contents


## Opens a container through `client` and waits until it is open (a first
## search takes ContainerSettings.search_duration_sec).
func _open(client: NetworkService, container_id: String) -> bool:
	var answer: Array = await _container_ask(client, func() -> int: return _container_net(client).request_open(container_id))
	if answer != [true, ""]:
		fail("%s could not open %s: %s" % [_id(client), container_id, str(answer)])
		return false
	return await _until(func() -> bool: return _container_mirror(client).open_container_id() == container_id and _container_mirror(client).phase() == ClientContainerState.PHASE_OPEN)


# ============================================================ what a client is told

## What the server has in the interest cells of this client's peer:
## {items: {id: units}, zombies: {id: true}, structures: {id: state},
## containers: {id: searched}}.
func _server_scope(client: NetworkService) -> Dictionary:
	var peer: int = _peer(client)
	var items: Dictionary = {}
	for item_id: String in _world.inventory.world_item_ids():
		if _cluster.server.is_cell_of_interest(peer, _world.cell_index.cell_of(item_id)):
			items[item_id] = _world.inventory.get_item(item_id).quantity
	var zombies: Dictionary = {}
	for zombie_id: String in _zombies().zombie_ids():
		if _cluster.server.is_cell_of_interest(peer, _world.cell_index.cell_of(zombie_id)):
			zombies[zombie_id] = true
	var structures: Dictionary = {}
	for structure_id: String in _building().structure_ids():
		var structure: StructureInstance = _building().get_structure(structure_id)
		if _cluster.server.is_cell_of_interest(peer, structure.cell_id):
			structures[structure_id] = StructureInstance.STATE_NAMES[structure.construction_state]
	var containers: Dictionary = {}
	for container_id: String in _containers().container_ids():
		var container: ContainerInstance = _containers().get_container(container_id)
		if _cluster.server.is_cell_of_interest(peer, container.cell_id):
			containers[container_id] = container.searched
	return {"items": items, "zombies": zombies, "structures": structures, "containers": containers}


## The same, as the client's mirrors hold it.
func _mirror_scope(client: NetworkService) -> Dictionary:
	var items: Dictionary = {}
	for item_id: String in client.client_state.world_items:
		items[item_id] = int(client.client_state.world_items[item_id]["quantity"])
	var zombies: Dictionary = {}
	var zombie_mirror: ClientZombieState = (client.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
	for zombie_id: String in zombie_mirror.zombie_ids():
		zombies[zombie_id] = true
	var structures: Dictionary = {}
	for structure_id: String in _structures(client).structure_ids():
		structures[structure_id] = str(_structures(client).get_structure(structure_id)["state"])
	var containers: Dictionary = {}
	for container_id: String in _container_mirror(client).container_ids():
		containers[container_id] = bool(_container_mirror(client).get_container(container_id)[ClientContainerState.KEY_SEARCHED])
	return {"items": items, "zombies": zombies, "structures": structures, "containers": containers}


## "" when the client's mirrors hold exactly what the server has in its
## interest cells: nothing missing, nothing extra (a ghost), nothing stale.
func _scope_diff(client: NetworkService) -> String:
	var expected: Dictionary = _server_scope(client)
	var actual: Dictionary = _mirror_scope(client)
	var problems: PackedStringArray = []
	for kind: String in expected:
		var want: Dictionary = expected[kind]
		var have: Dictionary = actual[kind]
		for key: String in want:
			if not have.has(key):
				problems.append("%s %s missing" % [kind, key])
			elif have[key] != want[key]:
				problems.append("%s %s is %s, on the server %s" % [kind, key, str(have[key]), str(want[key])])
		for key: String in have:
			if not want.has(key):
				problems.append("%s %s is a ghost" % [kind, key])
	return "; ".join(problems.slice(0, 8))


func _matches_server(client: NetworkService) -> bool:
	return await _until(func() -> bool: return _scope_diff(client).is_empty())


## Every id a client's mirrors ever added or removed, per kind.
class Appearances:
	extends RefCounted
	var added: Dictionary = {"items": {}, "zombies": {}, "structures": {}, "containers": {}}
	var removed: Dictionary = {"items": {}, "zombies": {}, "structures": {}, "containers": {}}

	func count(log: Dictionary, kind: String, entity_id: String) -> int:
		return int((log[kind] as Dictionary).get(entity_id, 0))

	func note(log: Dictionary, kind: String, entity_id: String) -> void:
		(log[kind] as Dictionary)[entity_id] = count(log, kind, entity_id) + 1


func _watch(client: NetworkService) -> Appearances:
	var seen: Appearances = Appearances.new()
	var inventory_net: InventoryNetModule = client.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	inventory_net.world_items_added.connect(func(ids: PackedStringArray) -> void:
		for item_id: String in ids:
			seen.note(seen.added, "items", item_id))
	inventory_net.world_items_removed.connect(func(ids: PackedStringArray) -> void:
		for item_id: String in ids:
			seen.note(seen.removed, "items", item_id))
	var zombie_mirror: ClientZombieState = (client.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
	zombie_mirror.zombie_added.connect(func(zombie_id: String) -> void: seen.note(seen.added, "zombies", zombie_id))
	zombie_mirror.zombie_removed.connect(func(zombie_id: String) -> void: seen.note(seen.removed, "zombies", zombie_id))
	_structures(client).structure_added.connect(func(structure_id: String) -> void: seen.note(seen.added, "structures", structure_id))
	_structures(client).structure_removed.connect(func(structure_id: String) -> void: seen.note(seen.removed, "structures", structure_id))
	_container_mirror(client).container_added.connect(func(container_id: String) -> void: seen.note(seen.added, "containers", container_id))
	_container_mirror(client).container_removed.connect(func(container_id: String) -> void: seen.note(seen.removed, "containers", container_id))
	return seen


## No mirror refused a payload or was told to remove what it did not have.
func _clean(clients: Array[NetworkService]) -> void:
	for client: NetworkService in clients:
		var zombie_mirror: ClientZombieState = (client.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
		assert_eq(_structures(client).rejected_payload_count, 0, "%s: no structure payload was refused" % _id(client))
		assert_eq(_structures(client).unknown_removal_count, 0, "%s: no removal of a structure the mirror did not have" % _id(client))
		assert_eq(_structures(client).unknown_work_stop_count, 0)
		assert_eq(_structure_net(client).rejected_payload_count, 0)
		assert_eq(_container_mirror(client).rejected_payload_count, 0, "%s: no container payload was refused" % _id(client))
		assert_eq(_container_mirror(client).unknown_removal_count, 0, "%s: no removal of a container the mirror did not have" % _id(client))
		assert_eq(_container_mirror(client).stale_contents_count, 0)
		assert_eq(zombie_mirror.rejected_payload_count, 0, "%s: no zombie payload was refused" % _id(client))
		assert_eq(zombie_mirror.event_gap_count, 0, "%s: no hole in the zombie event stream" % _id(client))
	assert_eq(_structure_net(_cluster.server).unsendable_row_count, 0)


# ============================================================ save state

## Everything of the world that is saved, in memory (or only of one cell):
## world items, structures, containers with their content, zombies and
## (whole world only) what the given players carry.
func _snapshot(world: ServerWorld, player_ids: PackedStringArray, cell_id: String = "") -> Dictionary:
	var items: Dictionary = {}
	for item_id: String in world.inventory.world_item_ids():
		if cell_id.is_empty() or world.cell_index.cell_of(item_id) == cell_id:
			var item: ItemInstance = world.inventory.get_item(item_id)
			var at: Vector3 = world.inventory.world_position_of(item_id)
			items[item_id] = [item.definition_id, item.quantity, [at.x, at.y, at.z]]
	var structures: Dictionary = {}
	for structure_id: String in _building(world).structure_ids():
		var structure: StructureInstance = _building(world).get_structure(structure_id)
		if cell_id.is_empty() or structure.cell_id == cell_id:
			structures[structure_id] = structure.to_dict()
	var containers: Dictionary = {}
	for container_id: String in _containers(world).container_ids():
		var container: ContainerInstance = _containers(world).get_container(container_id)
		if cell_id.is_empty() or container.cell_id == cell_id:
			var data: Dictionary = container.to_dict()
			data["contents"] = Array(_containers(world).contents_of(container_id))
			containers[container_id] = data
	var zombies: Dictionary = {}
	for zombie_id: String in _zombies(world).zombie_ids():
		if cell_id.is_empty() or world.cell_index.cell_of(zombie_id) == cell_id:
			zombies[zombie_id] = _zombies(world).get_zombie(zombie_id).to_dict()
	var carried: Dictionary = {}
	if cell_id.is_empty():
		for player_id: String in player_ids:
			var held: Dictionary = {}
			for item: ItemInstance in world.inventory.items_in_inventory(world.get_player(player_id).inventory_id):
				held[item.item_instance_id] = [item.definition_id, item.quantity, item.slot_id]
			carried[player_id] = held
	return {"items": items, "structures": structures, "containers": containers, "zombies": zombies, "carried": carried}


## `base` plus the entities of the cell snapshots in `parts` ({cell: snapshot}).
func _merged(base: Dictionary, parts: Dictionary) -> Dictionary:
	var result: Dictionary = base.duplicate(true)
	for cell_id: String in parts:
		var part: Dictionary = parts[cell_id]
		for kind: String in ["items", "structures", "containers", "zombies"]:
			for entity_id: String in part[kind]:
				if (result[kind] as Dictionary).has(entity_id):
					fail("%s %s is both in memory and in the released cell %s" % [kind, entity_id, cell_id])
				(result[kind] as Dictionary)[entity_id] = part[kind][entity_id]
	return result


## {kind: units} of every item a snapshot holds: lying in the world, inside
## containers, inside structures (delivered materials) and carried. An item
## id found twice fails the test.
func _unit_totals(snapshot: Dictionary) -> Dictionary:
	var totals: Dictionary = {}
	var ids: Dictionary = {}
	var add: Callable = func(item_id: String, definition_id: String, units: int) -> void:
		if not item_id.is_empty():
			if ids.has(item_id):
				fail("%s is in two places" % item_id)
			ids[item_id] = true
		totals[definition_id] = int(totals.get(definition_id, 0)) + units
	for item_id: String in snapshot["items"]:
		add.call(item_id, str(snapshot["items"][item_id][0]), int(snapshot["items"][item_id][1]))
	for container_id: String in snapshot["containers"]:
		for entry: Dictionary in snapshot["containers"][container_id]["contents"]:
			add.call(str(entry["item_instance_id"]), str(entry["definition_id"]), int(entry["quantity"]))
	for structure_id: String in snapshot["structures"]:
		var delivered: Dictionary = snapshot["structures"][structure_id][StructureInstance.KEY_DELIVERED]
		for definition_id: String in delivered:
			add.call("", definition_id, int(delivered[definition_id]))
	for player_id: String in snapshot["carried"]:
		var held: Dictionary = snapshot["carried"][player_id]
		for item_id: String in held:
			add.call(item_id, str(held[item_id][0]), int(held[item_id][1]))
	return totals


## Equal with a tolerance on numbers (JSON round trip).
func _same(a: Variant, b: Variant) -> bool:
	if (typeof(a) == TYPE_FLOAT or typeof(a) == TYPE_INT) and (typeof(b) == TYPE_FLOAT or typeof(b) == TYPE_INT):
		return absf(float(a) - float(b)) <= TOLERANCE
	if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY:
		if (a as Array).size() != (b as Array).size():
			return false
		for index: int in range((a as Array).size()):
			if not _same(a[index], b[index]):
				return false
		return true
	if typeof(a) == TYPE_DICTIONARY and typeof(b) == TYPE_DICTIONARY:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for key: Variant in (a as Dictionary):
			if not (b as Dictionary).has(key) or not _same(a[key], b[key]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


## "" when two snapshots hold the same, else what differs (first few).
func _snapshot_diff(before: Dictionary, after: Dictionary) -> String:
	var problems: PackedStringArray = []
	for kind: String in before:
		var was: Dictionary = before[kind]
		var now: Dictionary = after[kind]
		for key: String in was:
			if not now.has(key):
				problems.append("%s %s lost" % [kind, key])
			elif not _same(was[key], now[key]):
				problems.append("%s %s was %s, is %s" % [kind, key, str(was[key]), str(now[key])])
		for key: String in now:
			if not was.has(key):
				problems.append("%s %s appeared" % [kind, key])
	return "; ".join(problems.slice(0, 6))


## Snapshots of every cell at the moment it is released ({cell: snapshot}),
## forgotten again when the cell is loaded back.
func _capture_released_cells() -> Dictionary:
	var released: Dictionary = {}
	# The lambdas read the member, not a local copy of the world: a world
	# referenced from a connection to its own signal would never be freed.
	_cells().cell_unloading.connect(func(cell_id: String) -> void: released[cell_id] = _snapshot(_world, PackedStringArray(), cell_id))
	_cells().cell_loaded.connect(func(cell_id: String) -> void: released.erase(cell_id))
	return released


# ============================================================ 1. cells

func test_a_player_walks_across_cells_and_its_mirrors_follow_the_cells_the_server_loads_and_releases() -> void:
	if not _start():
		return
	var a: NetworkService = await _join("alice")
	var c: NetworkService = await _join("carol")
	if a == null or c == null:
		return
	var transitions: Array = []
	_cells().cell_state_changed.connect(func(cell_id: String, from: int, to: int) -> void:
		if cell_id == FAR_CELL:
			transitions.append([WorldCellLifecycle.STATE_NAMES[from], WorldCellLifecycle.STATE_NAMES[to]]))
	var far_loads: Array[Dictionary] = []
	var far_releases: Array[Dictionary] = []
	_cells().cell_loaded.connect(func(cell_id: String) -> void:
		if cell_id == FAR_CELL:
			far_loads.append(_snapshot(_world, PackedStringArray(), FAR_CELL)))
	_cells().cell_unloading.connect(func(cell_id: String) -> void:
		if cell_id == FAR_CELL:
			far_releases.append(_snapshot(_world, PackedStringArray(), FAR_CELL)))
	var near_zombie: String = _spawn_zombie(NEAR_ZOMBIE_AT, 0.0)
	var middle_zombie: String = _spawn_zombie(MIDDLE_ZOMBIE_AT, YAW_PLUS_Z)
	# Both stand at the spawn point: the same cells, the buildings of the map.
	assert_true(await _matches_server(a), "alice is told what is around the spawn point: %s" % _scope_diff(a))
	assert_true(await _matches_server(c), "carol too: %s" % _scope_diff(c))
	assert_eq(_mirror_scope(a), _mirror_scope(c), "two players at the spawn point see the same")
	assert_eq(_structures(a).structure_count(), _map().content().piece_count(), "every piece of the test map, once")
	assert_eq(_container_mirror(a).container_count(), _map().content().container_count())
	assert_true(_mirror_scope(a)["zombies"].has(near_zombie))
	assert_false(_mirror_scope(a)["zombies"].has(middle_zombie), "the zombie three cells away is in memory but not in alice's cells")
	assert_true(_world.is_cell_loaded(_world.cell_id_at(MIDDLE_ZOMBIE_AT)))
	assert_false(_world.is_cell_simulated(_world.cell_id_at(MIDDLE_ZOMBIE_AT)), "and not simulated")
	assert_false(_world.is_cell_loaded(FAR_CELL), "nobody is near the far cell")
	var item_id: String = await _pick_up_seeded(c, TEST_ITEM, TEST_ITEM_AT)

	# Carol goes far away; from now on every appearance is counted.
	await _move(c, FAR)
	assert_true(await _matches_server(c), "carol at the far cell: %s" % _scope_diff(c))
	assert_eq(_structures(c).structure_count(), 0, "no structure out there")
	assert_true(_cells().is_simulated(FAR_CELL), "the far cell is active while she is there")
	var seen_by_a: Appearances = _watch(a)
	var seen_by_c: Appearances = _watch(c)
	# She leaves things there: the item she carried, a floor blueprint; a
	# zombie stands there too.
	assert_eq(await _drop(c, item_id, InventoryService.WHOLE_STACK), [true, ""])
	var placed: Array = await _ask_structure(c, func() -> int: return _structure_net(c).request_place(FLOOR, FAR_FLOOR_TILE, 0))
	assert_true(bool(placed[0]), "the floor blueprint was placed: %s" % str(placed))
	var far_floor: String = str(placed[2])
	var far_zombie: String = _spawn_zombie(FAR_ZOMBIE_AT, YAW_PLUS_Z)
	assert_eq(_world.cell_index.cell_of(item_id), FAR_CELL)
	assert_eq(_building().get_structure(far_floor).cell_id, FAR_CELL)
	assert_eq(_world.cell_index.cell_of(far_zombie), FAR_CELL)
	assert_true(await _matches_server(c), "carol sees what is in her cells: %s" % _scope_diff(c))
	assert_true(_mirror_scope(c)["items"].has(item_id) and _mirror_scope(c)["structures"].has(far_floor) and _mirror_scope(c)["zombies"].has(far_zombie))
	assert_true(_mirror_scope(c)["zombies"].has(middle_zombie), "and the zombie of cell_3_3, one cell away from her")
	assert_true(await _matches_server(a), "alice still sees exactly her cells: %s" % _scope_diff(a))

	# She walks back to the spawn cell, one border at a time.
	for step: Vector3 in ROUTE_IN:
		await _move(c, step)
		assert_true(await _matches_server(c), "carol at %s: %s" % [str(step), _scope_diff(c)])
		assert_true(_cells().is_simulated(_world.cell_id_at(step)), "the cell she stands in is active")
		assert_true(await _matches_server(a), "alice: %s" % _scope_diff(a))
	# The far cell is released by the server's rules: deactivated, saved, unloaded.
	assert_true(await _until(func() -> bool: return _cells().state_of(FAR_CELL) == WorldCellLifecycle.State.UNLOADED), "the far cell was released")
	assert_false(_zombies().has_zombie(far_zombie), "its zombie left server memory")
	assert_false(_building().has_structure(far_floor), "and its blueprint")
	assert_true(_world.inventory.get_item(item_id) == null, "and its item")
	assert_true(SaveService.new(_root).saved_cell_ids(WORLD).has(FAR_CELL), "into a cell file")
	assert_true(await _matches_server(c), "carol at the spawn cell: %s" % _scope_diff(c))
	assert_false(_mirror_scope(c)["zombies"].has(far_zombie), "nothing of the far cell is left in her mirrors")
	assert_false(_mirror_scope(c)["items"].has(item_id))
	assert_false(_mirror_scope(c)["structures"].has(far_floor))
	assert_eq(_structures(c).structure_count(), _map().content().piece_count(), "she sees the buildings of the map")

	# And walks out again: the far cell comes back from its file, as it was.
	for step: Vector3 in ROUTE_OUT:
		await _move(c, step)
		assert_true(await _matches_server(c), "carol at %s: %s" % [str(step), _scope_diff(c)])
		assert_true(await _matches_server(a), "alice: %s" % _scope_diff(a))
	assert_true(_mirror_scope(c)["zombies"].has(far_zombie) and _mirror_scope(c)["items"].has(item_id) and _mirror_scope(c)["structures"].has(far_floor), "the far zombie, item and blueprint are back in her mirrors")
	assert_eq(_structures(c).structure_count(), 1)
	assert_eq(_container_mirror(c).container_count(), 0)
	assert_eq(far_releases.size(), 1, "the far cell was released once")
	assert_eq(far_loads.size(), 2, "and loaded twice")
	if far_releases.size() == 1 and far_loads.size() == 2:
		assert_eq(_snapshot_diff(far_releases[0], far_loads[1]), "", "the cell came back exactly as it was released")
		assert_eq((far_loads[1]["zombies"] as Dictionary).size(), 1)
		assert_eq((far_loads[1]["items"] as Dictionary).size(), 1)
		assert_eq((far_loads[1]["structures"] as Dictionary).size(), 1)
	assert_eq(transitions, [
		["unloaded", "loading"], ["loading", "preloaded"], ["preloaded", "active"],
		["active", "preloaded"], ["preloaded", "saving"], ["saving", "unloading"], ["unloading", "unloaded"],
		["unloaded", "loading"], ["loading", "preloaded"], ["preloaded", "active"],
	], "the far cell went through the lifecycle of docs/03 §3.2")

	# No ghost, no duplicate: everything appeared once per time it came into
	# her cells, and the far things never reached alice.
	for kind_and_id: Array in [["items", item_id], ["structures", far_floor], ["zombies", far_zombie]]:
		assert_eq(seen_by_c.count(seen_by_c.added, kind_and_id[0], kind_and_id[1]), 2, "%s %s appeared twice for carol (made there, came back)" % kind_and_id)
		assert_eq(seen_by_c.count(seen_by_c.removed, kind_and_id[0], kind_and_id[1]), 1, "and went once")
		assert_eq(seen_by_a.count(seen_by_a.added, kind_and_id[0], kind_and_id[1]), 0, "alice never heard of %s %s" % kind_and_id)
	for container_id: String in _containers().container_ids():
		assert_eq(seen_by_c.count(seen_by_c.added, "containers", container_id), 1, "carol gained %s once on her way in" % container_id)
		assert_eq(seen_by_c.count(seen_by_c.removed, "containers", container_id), 1, "and lost it once on her way out")
	var map_piece: String = _house_door()
	assert_eq(seen_by_c.count(seen_by_c.added, "structures", map_piece), 1)
	assert_eq(seen_by_c.count(seen_by_c.removed, "structures", map_piece), 1)
	for kind: String in ["items", "zombies", "structures", "containers"]:
		assert_eq((seen_by_a.added[kind] as Dictionary).size(), 0, "alice, standing still, gained no %s" % kind)
		assert_eq((seen_by_a.removed[kind] as Dictionary).size(), 0, "and lost none")
	# A real walk (move intents, not a jump) across a cell border.
	await _move(a, BORDER_WEST_OF)
	var from_cell: String = _world.cell_id_at(_server_position(a))
	await _walk([a] as Array[NetworkService], Vector2(1.0, 0.0), WALK_IN_TICKS)
	var to_cell: String = _world.cell_id_at(_server_position(a))
	assert_ne(from_cell, to_cell, "alice walked from %s into %s" % [from_cell, to_cell])
	assert_true(_server_position(a).x > BORDER_WEST_OF.x + 2.0, "nothing stopped her at the border: %s" % str(_server_position(a)))
	assert_true(await _matches_server(a), "and her mirrors follow: %s" % _scope_diff(a))
	# One session all the way: no new join, no loading screen.
	assert_eq(_cluster.server.joined_peer_count(), 2)
	assert_eq(_cluster.server.rejected_intent_count(), 0)
	_clean([a, c])


# ============================================================ 2. one structure, two players

func test_two_players_see_the_same_wall_at_every_stage_and_it_blocks_them_both() -> void:
	if not _start():
		return
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	await _gather_materials(a)
	await _move(a, BUILDER_AT)
	await _move(b, WATCHER_AT)
	# Arrays, not PackedStringArrays: the lambdas below append to the same object.
	var a_states: Array[String] = []
	var b_states: Array[String] = []
	var watched: Array[String] = [""]
	for pair: Array in [[a, a_states], [b, b_states]]:
		var client: NetworkService = pair[0]
		var states: Array[String] = pair[1]
		var note: Callable = func(structure_id: String) -> void:
			if structure_id == watched[0]:
				var state: String = str(_structures(client).get_structure(structure_id)["state"])
				if states.is_empty() or states[states.size() - 1] != state:
					states.append(state)
		_structures(client).structure_added.connect(note)
		_structures(client).structure_changed.connect(note)

	# Blueprint.
	var answer: Array = await _ask_structure(a, func() -> int: return _structure_net(a).request_place(WALL, WALL_TILE, WALL_ROTATION))
	assert_true(bool(answer[0]), "alice placed the wall: %s" % str(answer))
	var wall_id: String = str(answer[2])
	watched[0] = wall_id
	a_states.append(str(_structures(a).get_structure(wall_id).get("state", "")))
	if _structures(b).has_structure(wall_id):
		b_states.append(str(_structures(b).get_structure(wall_id)["state"]))
	assert_true(await _until(func() -> bool: return _mirrors_agree([a, b], wall_id)), "both see the blueprint as the server has it")
	assert_eq(_structures(b).get_structure(wall_id)["state"], "blueprint")
	assert_eq(_structures(b).get_structure(wall_id)["required"], WALL_COSTS)
	assert_eq(_structures(b).get_structure(wall_id)["delivered"], {})
	# Server rules, clearly refused (docs/04 §12): no materials yet, the slot is taken.
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_work(wall_id, true)), [false, BuildingService.REASON_MATERIALS_MISSING, ""])
	assert_eq(await _ask_structure(b, func() -> int: return _structure_net(b).request_place(WALL, WALL_TILE, WALL_ROTATION)), [false, BuildingService.REASON_SLOT_OCCUPIED, ""])
	assert_eq(_building().structure_count(), _map().content().piece_count() + 1)
	# Both ask for the same slot in the same frame: the server takes one.
	var contested: Dictionary = {}
	var record_a: Callable = func(request_id: int, ok: bool, reason: String, structure_id: String) -> void: contested["alice"] = [request_id, ok, reason, structure_id]
	var record_b: Callable = func(request_id: int, ok: bool, reason: String, structure_id: String) -> void: contested["bob"] = [request_id, ok, reason, structure_id]
	_structure_net(a).structure_result.connect(record_a)
	_structure_net(b).structure_result.connect(record_b)
	_structure_net(a).request_place(FLOOR, CONTESTED_TILE, 0)
	_structure_net(b).request_place(FLOOR, CONTESTED_TILE, 0)
	assert_true(await _until(func() -> bool: return contested.size() == 2), "both were answered")
	_structure_net(a).structure_result.disconnect(record_a)
	_structure_net(b).structure_result.disconnect(record_b)
	var granted: int = 0
	var floor_id: String = ""
	for player_key: String in contested:
		if bool(contested[player_key][1]):
			granted += 1
			floor_id = str(contested[player_key][3])
		else:
			assert_eq(contested[player_key][2], BuildingService.REASON_SLOT_OCCUPIED, "the other one is told the slot is taken")
	assert_eq(granted, 1, "exactly one placement was granted: %s" % str(contested))
	assert_true(await _until(func() -> bool: return _mirrors_agree([a, b], floor_id)), "both see the one floor")
	assert_eq(_building().structure_count(), _map().content().piece_count() + 2)

	# Materials.
	var wood_before: int = _units(_server_carried(_id(a)), WOOD)
	var nails_before: int = _units(_server_carried(_id(a)), NAILS)
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_deliver(wall_id)), [true, "", wall_id])
	assert_true(await _until(func() -> bool: return _mirrors_agree([a, b], wall_id)), "both see the materials in the blueprint")
	assert_eq(_structures(b).get_structure(wall_id)["delivered"], WALL_COSTS)
	assert_eq(_units(_server_carried(_id(a)), WOOD), wood_before - 4, "the wood left alice's inventory")
	assert_eq(_units(_server_carried(_id(a)), NAILS), nails_before - 2)
	assert_true(await _until(func() -> bool: return _mirror_carried(a) == _server_carried(_id(a))), "alice's own mirror shows it")
	assert_eq(_units(_mirror_carried(b), WOOD), 0, "bob is told nothing about alice's inventory")

	# Half the work: stopped, the exact progress reaches both.
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_work(wall_id, true)), [true, "", wall_id])
	assert_true(await _until(func() -> bool: return _building().get_structure(wall_id).construction_progress >= PROGRESS_TO_STOP_AT, BUILD_TICKS))
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_work(wall_id, false)), [true, "", wall_id])
	assert_true(await _until(func() -> bool: return _mirrors_agree([a, b], wall_id) and _structures(b).workers.is_empty()), "both see the half built wall with its exact progress")
	assert_eq(_structures(b).get_structure(wall_id)["state"], "constructing")
	var half: float = float(_structures(b).get_structure(wall_id)["progress"])
	assert_true(half >= PROGRESS_TO_STOP_AT and half < 1.0, "half built: %f" % half)

	# The rest of the work: completed.
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_work(wall_id, true)), [true, "", wall_id])
	assert_true(await _until(func() -> bool: return _mirror_state(b, wall_id) == "constructing" and _structures(b).work_of(_id(a)) == wall_id), "bob sees alice work")
	assert_true(await _until(func() -> bool: return _building().get_structure(wall_id).construction_state == StructureInstance.State.COMPLETED, BUILD_TICKS), "the wall was completed")
	assert_true(await _until(func() -> bool: return _mirrors_agree([a, b], wall_id) and _structures(a).workers.is_empty() and _structures(b).workers.is_empty()), "both see the completed wall")
	assert_eq(_structures(b).get_structure(wall_id)["health_fraction"], 1.0)
	assert_eq(a_states, ["blueprint", "constructing", "completed"] as Array[String],"alice's mirror went through the stages in order")
	assert_eq(b_states, a_states, "bob's mirror went through the same stages")
	assert_eq(ConstructionTestKit.lying(_world, WOOD) + ConstructionTestKit.built_in(_world, WOOD) + _units(_server_carried(_id(a)), WOOD) + _units(_server_carried(_id(b)), WOOD), 40, "no wood was made or lost")

	# The completed wall stops both players' server movement.
	assert_true(_server_position(a).z > WALL_Z and _server_position(b).z > WALL_Z)
	await _walk([a, b] as Array[NetworkService], Vector2(0.0, -1.0), WALK_TICKS)
	for client: NetworkService in [a, b]:
		var at: Vector3 = _server_position(client)
		assert_true(at.z >= WALL_Z and at.z <= WALL_Z + COLLISION_SKIN_M + 0.01, "%s stopped at the wall: %s" % [_id(client), str(at)])
	for viewer: NetworkService in [a, b]:
		for walker: NetworkService in [a, b]:
			var server_at: Vector3 = _server_position(walker)
			assert_true(await _until(func() -> bool: return viewer.client_state.position_of(_id(walker)).distance_to(server_at) < MIRROR_POSITION_TOLERANCE_M), "%s sees %s stopped at the wall" % [_id(viewer), _id(walker)])
	# Beside the wall nothing is in the way.
	await _move(b, BESIDE_THE_WALL_AT)
	await _walk([b] as Array[NetworkService], Vector2(0.0, -1.0), WALK_TICKS)
	assert_true(_server_position(b).z < WALL_Z - 1.0, "beside the wall bob walks on: %s" % str(_server_position(b)))
	# Somebody else's wall cannot be demolished.
	await _move(b, WATCHER_AT)
	assert_eq(await _ask_structure(b, func() -> int: return _structure_net(b).request_demolish(wall_id)), [false, BuildingService.REASON_NOT_OWNER, ""])
	assert_true(_building().has_structure(wall_id))

	# A door of the test map: alice opens it, bob sees it open; bob closes it.
	var door_id: String = _house_door()
	await _move(a, OUTSIDE_THE_DOOR)
	await _move(b, ALSO_OUTSIDE_THE_DOOR)
	assert_true(await _until(func() -> bool: return _mirrors_agree([a, b], door_id)))
	assert_false(bool(_structures(b).get_structure(door_id)["door_open"]), "the door of the map starts closed")
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_door(door_id, true)), [true, "", door_id])
	assert_true(await _until(func() -> bool: return bool(_structures(b).get_structure(door_id)["door_open"])), "bob sees the door alice opened")
	assert_true(_mirrors_agree([a, b], door_id))
	await _walk([a] as Array[NetworkService], Vector2(0.0, 1.0), WALK_IN_TICKS)
	assert_true(_is_inside_the_house(_server_position(a)), "alice walked in through the open door: %s" % str(_server_position(a)))
	assert_eq(await _ask_structure(b, func() -> int: return _structure_net(b).request_door(door_id, false)), [true, "", door_id])
	assert_true(await _until(func() -> bool: return not bool(_structures(a).get_structure(door_id)["door_open"])), "alice sees bob close it")
	await _walk([a] as Array[NetworkService], Vector2(0.0, -1.0), WALK_TICKS)
	assert_true(_is_inside_the_house(_server_position(a)), "the closed door keeps her in: %s" % str(_server_position(a)))
	_clean([a, b])


func _mirror_state(client: NetworkService, structure_id: String) -> String:
	if not _structures(client).has_structure(structure_id):
		return ""
	return str(_structures(client).get_structure(structure_id)["state"])


# ============================================================ 3. containers

func test_what_one_player_puts_into_a_container_another_takes_out_and_a_far_player_never_learns() -> void:
	if not _start():
		return
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	var c: NetworkService = await _join("carol")
	if a == null or b == null or c == null:
		return
	await _move(c, FAR)
	var carol_told: Array[int] = [0]
	for container_signal: Signal in [_container_mirror(c).changed, _container_mirror(c).session_changed, _container_mirror(c).contents_changed]:
		container_signal.connect(func() -> void: carol_told[0] += 1)
	var bob_contents: Array[int] = [0]
	_container_mirror(b).contents_changed.connect(func() -> void: bob_contents[0] += 1)
	var food_id: String = await _pick_up_seeded(a, FOOD, FOOD_AT)
	var cabinet_id: String = _container_at(CABINET_AT)
	assert_false(_containers().get_container(cabinet_id).searched, "nobody searched the cabinet of house_a yet")
	assert_true(_container_mirror(b).has_container(cabinet_id), "bob is told the cabinet exists")
	assert_false(_container_mirror(c).has_container(cabinet_id), "carol is not")

	# Alice searches it (once: the loot is rolled now) and puts food in.
	await _move(a, CABINET_STAND)
	await _move(b, ALSO_CABINET_STAND)
	assert_true(await _open(a, cabinet_id), "alice searched and opened the cabinet")
	assert_eq(_containers().loot_roll_count, 1)
	assert_eq(_mirror_contents(a), _server_contents(cabinet_id), "alice sees what is inside")
	var food_total: int = _units(_server_carried(_id(a)), FOOD) + _units(_server_contents(cabinet_id), FOOD) + ConstructionTestKit.lying(_world, FOOD)
	assert_eq(await _container_ask(a, func() -> int: return _container_net(a).request_put(cabinet_id, food_id, PUT_FOOD)), [true, ""])
	assert_true(await _until(func() -> bool: return _mirror_contents(a) == _server_contents(cabinet_id) and _mirror_carried(a) == _server_carried(_id(a))), "alice sees her food inside and less in her hands")
	assert_eq(_units(_server_carried(_id(a)), FOOD), 3 - PUT_FOOD)
	assert_eq(await _container_ask(a, func() -> int: return _container_net(a).request_close(cabinet_id)), [true, ""])
	await _move(a, Vector3.ZERO)
	# Bob stood next to it and did not open it: he was told no content.
	assert_true(_container_mirror(b).contents().is_empty())
	assert_eq(bob_contents[0], 0, "no content reached bob before he opened it")
	assert_true(bool(_container_mirror(b).get_container(cabinet_id)[ClientContainerState.KEY_SEARCHED]), "only that it was searched")

	# Later bob opens it (no new search) and takes alice's food out.
	assert_true(await _open(b, cabinet_id), "bob opened the searched cabinet")
	assert_eq(_containers().loot_roll_count, 1, "nothing rolled again")
	assert_eq(_mirror_contents(b), _server_contents(cabinet_id), "bob sees what alice left")
	var food_stack: String = ""
	for item_id: String in _mirror_contents(b):
		if str(_mirror_contents(b)[item_id][0]) == FOOD and int(_mirror_contents(b)[item_id][1]) >= PUT_FOOD:
			food_stack = item_id
	assert_false(food_stack.is_empty(), "the food alice put in: %s" % str(_mirror_contents(b)))
	var units_in_stack: int = int(_mirror_contents(b)[food_stack][1])
	assert_eq(await _container_ask(b, func() -> int: return _container_net(b).request_take(cabinet_id, food_stack, InventoryService.WHOLE_STACK)), [true, ""])
	assert_true(await _until(func() -> bool: return _mirror_carried(b) == _server_carried(_id(b)) and _mirror_contents(b) == _server_contents(cabinet_id)), "bob carries it and sees it gone")
	assert_eq(_units(_server_carried(_id(b)), FOOD), units_in_stack)
	assert_eq(_units(_server_carried(_id(a)), FOOD) + _units(_server_carried(_id(b)), FOOD) + _units(_server_contents(cabinet_id), FOOD) + ConstructionTestKit.lying(_world, FOOD), food_total, "no food was made or lost")

	# Carol, far away, was never told anything, and asking reveals nothing.
	assert_eq(_container_mirror(c).container_count(), 0)
	assert_eq(carol_told[0], 0, "no container row, session or content reached carol")
	var real: Array = [
		await _container_ask(c, func() -> int: return _container_net(c).request_open(cabinet_id)),
		await _container_ask(c, func() -> int: return _container_net(c).request_take(cabinet_id, food_stack, InventoryService.WHOLE_STACK)),
	]
	var invented: Array = [
		await _container_ask(c, func() -> int: return _container_net(c).request_open(MISSING_CONTAINER_ID)),
		await _container_ask(c, func() -> int: return _container_net(c).request_take(MISSING_CONTAINER_ID, food_stack, InventoryService.WHOLE_STACK)),
	]
	assert_eq(real, [[false, ContainerService.REASON_UNKNOWN_CONTAINER], [false, ContainerService.REASON_UNKNOWN_CONTAINER]], "the cabinet is answered like a container that does not exist")
	assert_eq(real, invented)
	await _settle()
	assert_eq(carol_told[0], 0)
	assert_true(_container_mirror(c).contents().is_empty())
	_clean([a, b, c])


# ============================================================ 4. navigation

func test_a_zombie_outside_a_closed_door_stays_out_until_a_player_inside_opens_it() -> void:
	if not _start():
		return
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var door_id: String = _house_door()
	await _move(b, INSIDE_WEST)
	var zombie_id: String = _spawn_zombie(ZOMBIE_AT_THE_DOOR, YAW_PLUS_Z)
	var health: float = _survival().get_vitals(_id(b)).health
	var bob_attacked: Array[int] = [0]
	var bob_zombies: ClientZombieState = (b.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
	var alice_zombies: ClientZombieState = (a.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
	bob_zombies.event_received.connect(func(event: Dictionary) -> void:
		if str(event.get("event_type", "")) == ZombieService.EVENT_ATTACKED and str(event.get("zombie_id", "")) == zombie_id:
			bob_attacked[0] += 1)
	var seen: Dictionary = {"inside": false, "chase": false, "visible": false, "investigate": false}
	var watch: Callable = func() -> void:
		var zombie: ZombieState = _zombies().get_zombie(zombie_id)
		if zombie != null:
			seen["inside"] = bool(seen["inside"]) or _is_inside_the_house(zombie.position)
			seen["chase"] = bool(seen["chase"]) or zombie.state == ZombieState.State.CHASE
			seen["visible"] = bool(seen["visible"]) or zombie.target_visible
			seen["investigate"] = bool(seen["investigate"]) or zombie.state == ZombieState.State.INVESTIGATE
	tree.physics_frame.connect(watch)
	assert_true(await _until(func() -> bool: return alice_zombies.has_zombie(zombie_id) and bob_zombies.has_zombie(zombie_id)), "both are told about the zombie")

	# Bob walks to and fro inside: the zombie hears him through the walls,
	# but the door is closed.
	for lap: int in range(INSIDE_LAPS):
		await _walk([b] as Array[NetworkService], Vector2(1.0, 0.0), INSIDE_STRIDE_TICKS)
		await _walk([b] as Array[NetworkService], Vector2(-1.0, 0.0), INSIDE_STRIDE_TICKS)
	assert_true(bool(seen["investigate"]), "the zombie heard bob and wanted to go there")
	assert_false(bool(seen["inside"]), "it did not get in through the closed door")
	assert_false(bool(seen["visible"]) or bool(seen["chase"]), "nor saw bob through it")
	assert_eq(_survival().get_vitals(_id(b)).health, health, "nor hit him")
	assert_eq(bob_attacked[0], 0)
	assert_false(_is_inside_the_house(alice_zombies.get_zombie(zombie_id)["position"]), "alice sees it outside")

	# Bob opens the door: the zombie gets in, and both see it inside.
	await _move(b, INSIDE_WEST + Vector3(1.0, 0.0, 0.0))
	assert_eq(await _ask_structure(b, func() -> int: return _structure_net(b).request_door(door_id, true)), [true, "", door_id])
	assert_true(await _until(func() -> bool: return bool(_structures(a).get_structure(door_id)["door_open"])), "alice sees the door open")
	assert_true(await _until(func() -> bool: return bool(seen["inside"]), BUILD_TICKS), "the zombie got in through the open door: %s" % str(_zombies().get_zombie(zombie_id).position))
	for client: NetworkService in [a, b]:
		var mirror: ClientZombieState = (client.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
		assert_true(await _until(func() -> bool: return _is_inside_the_house(mirror.get_zombie(zombie_id)["position"])), "%s sees it inside" % _id(client))
	assert_true(await _until(func() -> bool: return bob_attacked[0] > 0, BUILD_TICKS), "and now it reaches bob")
	assert_true(_survival().get_vitals(_id(b)).health < health)
	tree.physics_frame.disconnect(watch)
	_clean([a, b])


# ============================================================ 5. save and restore

func test_a_world_with_loaded_and_released_cells_survives_a_server_restart_identical() -> void:
	if not _start():
		return
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	var c: NetworkService = await _join("carol")
	if a == null or b == null or c == null:
		return
	var player_ids: PackedStringArray = [_id(a), _id(b), _id(c)]
	var released: Dictionary = _capture_released_cells()
	var near_zombie: String = _spawn_zombie(NEAR_ZOMBIE_AT, 0.0)
	var middle_zombie: String = _spawn_zombie(MIDDLE_ZOMBIE_AT, YAW_PLUS_Z)
	# Alice: a wall blueprint with its materials, worked on and stopped.
	await _gather_materials(a)
	await _move(a, BUILDER_AT)
	var wall_id: String = await _place_wall(a)
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_deliver(wall_id)), [true, "", wall_id])
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_work(wall_id, true)), [true, "", wall_id])
	assert_true(await _until(func() -> bool: return _building().get_structure(wall_id).construction_progress >= PROGRESS_TO_STOP_AT, BUILD_TICKS))
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_work(wall_id, false)), [true, "", wall_id])
	# She opens the door of house_a, searches its cabinet and puts food in.
	var door_id: String = _house_door()
	await _move(a, OUTSIDE_THE_DOOR)
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_door(door_id, true)), [true, "", door_id])
	var food_id: String = await _pick_up_seeded(a, FOOD, FOOD_AT)
	var cabinet_id: String = _container_at(CABINET_AT)
	await _move(a, CABINET_STAND)
	assert_true(await _open(a, cabinet_id))
	assert_eq(await _container_ask(a, func() -> int: return _container_net(a).request_put(cabinet_id, food_id, PUT_FOOD)), [true, ""])
	assert_eq(await _container_ask(a, func() -> int: return _container_net(a).request_close(cabinet_id)), [true, ""])
	await _move(a, BUILDER_AT)
	# Bob drops one of his water bottles near the spawn point.
	var water_id: String = await _pick_up_seeded(b, WATER, WATER_AT)
	assert_eq(await _drop(b, water_id, 1), [true, ""])
	# Carol leaves an item, a floor blueprint and a zombie in the far cell
	# and comes back: that cell is released before the server stops.
	var item_id: String = await _pick_up_seeded(c, TEST_ITEM, TEST_ITEM_AT)
	await _move(c, FAR)
	var far_zombie: String = _spawn_zombie(FAR_ZOMBIE_AT, YAW_PLUS_Z)
	assert_eq(await _drop(c, item_id, InventoryService.WHOLE_STACK), [true, ""])
	var placed: Array = await _ask_structure(c, func() -> int: return _structure_net(c).request_place(FLOOR, FAR_FLOOR_TILE, 0))
	assert_true(bool(placed[0]), str(placed))
	var far_floor: String = str(placed[2])
	for step: Vector3 in ROUTE_IN:
		await _move(c, step)
	assert_true(await _until(func() -> bool: return _cells().state_of(FAR_CELL) == WorldCellLifecycle.State.UNLOADED), "the far cell was released")
	assert_true(released.has(FAR_CELL), "and what it held was noted")
	assert_true(_world.is_cell_loaded(_world.cell_id_at(Vector3.ZERO)), "the spawn cell is still in memory")
	assert_true(_world.is_cell_loaded(_world.cell_id_at(MIDDLE_ZOMBIE_AT)), "and so is cell_3_3 (not simulated)")

	# What the world holds at the moment the server stops, wherever it is.
	var wall: StructureInstance = _building().get_structure(wall_id)
	assert_eq(wall.construction_state, StructureInstance.State.CONSTRUCTING)
	assert_eq(wall.delivered_materials, WALL_COSTS)
	var progress: float = wall.construction_progress
	var before: Dictionary = _merged(_snapshot(_world, player_ids), released)
	var totals: Dictionary = _unit_totals(before)
	assert_true((before["zombies"] as Dictionary).has(far_zombie) and (before["structures"] as Dictionary).has(far_floor) and (before["items"] as Dictionary).has(item_id), "the far cell's content is part of it")
	assert_eq(int(totals.get(WOOD, 0)), 40)
	assert_eq(int(totals.get(NAILS, 0)), 30)
	var searched: int = 0
	for container_id: String in before["containers"]:
		searched += 1 if bool(before["containers"][container_id]["searched"]) else 0
	assert_eq(searched, 1, "one container was searched")
	await _cluster.shutdown()
	_cluster = null

	# The restart: a new world from the files.
	var old_world: ServerWorld = _world
	if not _load_from_disk():
		return
	assert_ne(_world, old_world)
	assert_true(_map().is_seeded(), "the world knows its map was seeded")
	assert_eq(_map().last_seed_report.size(), 0, "and does not seed it again")
	assert_eq(_cells().loaded_cell_ids().size(), 0, "a server start brings no cell into memory")
	assert_eq(_cells().load_all_saved_cells(_world), PackedStringArray(), "every cell file loads")
	var after: Dictionary = _snapshot(_world, player_ids)
	assert_eq(_snapshot_diff(before, after), "", "structures, containers with their content, world items, zombies and inventories came back identical")
	assert_eq(_unit_totals(after), totals, "every unit of every kind exists as often as before")
	assert_eq(_building().structure_count(), _map().content().piece_count() + 2, "the map's pieces once, plus the wall and the floor")
	assert_eq(_containers().container_count(), _map().content().container_count(), "the map's containers once")
	assert_true(_building().get_structure(door_id).door_open, "the door is still open")
	assert_true(_same(_building().get_structure(wall_id).construction_progress, progress), "the wall's progress is kept")
	assert_true(_zombies().has_zombie(near_zombie) and _zombies().has_zombie(middle_zombie) and _zombies().has_zombie(far_zombie))

	# Over the network: the players come back to what they left.
	if not _serve():
		return
	a = await _join("alice")
	b = await _join("bob")
	c = await _join("carol")
	if a == null or b == null or c == null:
		return
	for client: NetworkService in [a, b, c]:
		var saved: Dictionary = {}
		var held: Dictionary = before["carried"][_id(client)]
		for held_id: String in held:
			saved[held_id] = [held[held_id][0], held[held_id][1]]
		assert_eq(_mirror_carried(client), saved, "%s carries what she or he carried" % _id(client))
	assert_true(await _until(func() -> bool: return _mirrors_agree([a, b], wall_id) and _mirrors_agree([a, b], door_id)), "alice and bob see the half built wall and the open door")
	assert_eq(_structures(a).get_structure(wall_id)["delivered"], WALL_COSTS)
	assert_true(await _until(func() -> bool: return b.client_state.world_items.size() > 0 and _scope_diff(b).is_empty()), "bob is told what lies around him: %s" % _scope_diff(b))
	# The cabinet is searched and holds what alice left; nothing is rolled.
	await _move(a, CABINET_STAND)
	assert_true(await _open(a, cabinet_id))
	assert_eq(_mirror_contents(a), _server_contents(cabinet_id))
	var before_contents: Dictionary = {}
	for entry: Dictionary in before["containers"][cabinet_id]["contents"]:
		before_contents[str(entry["item_instance_id"])] = [str(entry["definition_id"]), int(entry["quantity"])]
	assert_eq(_mirror_contents(a), before_contents, "the same stacks with the same ids")
	assert_eq(_containers().loot_roll_count, 0, "no loot was rolled again")
	assert_eq(await _container_ask(a, func() -> int: return _container_net(a).request_close(cabinet_id)), [true, ""])
	# The construction goes on where it stopped.
	await _move(a, BUILDER_AT)
	assert_eq(await _ask_structure(a, func() -> int: return _structure_net(a).request_work(wall_id, true)), [true, "", wall_id])
	assert_true(await _until(func() -> bool: return _building().get_structure(wall_id).construction_state == StructureInstance.State.COMPLETED, BUILD_TICKS), "the wall was completed after the restart")
	assert_true(await _until(func() -> bool: return _mirrors_agree([a, b], wall_id)), "and both see it completed")
	_clean([a, b, c])


# ============================================================ 6. forged requests

func test_forged_building_and_container_requests_are_refused_and_reveal_nothing() -> void:
	if not _start():
		return
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	var c: NetworkService = await _join("carol")
	if a == null or b == null or c == null:
		return
	await _gather_materials(a)
	await _move(a, BUILDER_AT)
	await _move(b, WATCHER_AT)
	await _move(c, FAR)
	var wall_id: String = await _place_wall(a)
	var cabinet_id: String = _container_at(CABINET_AT)
	var food_lying: String = _item_near(FOOD, OTHER_FOOD_AT)
	var map_wall: String = _house_piece(WALL, HOUSE_WALL_TILE, 0)
	assert_true(await _until(func() -> bool: return _mirrors_agree([a, b], wall_id)))
	var wood_stack: String = ""
	for held_id: String in _server_carried(_id(a)):
		if str(_server_carried(_id(a))[held_id][0]) == WOOD:
			wood_stack = held_id
	var structures_before: Array[Dictionary] = _building().rows()
	var alice_carried: Dictionary = _server_carried(_id(a))
	var cabinet_contents: Dictionary = _server_contents(cabinet_id)
	var rejected: int = _cluster.server.rejected_intent_count()

	# Bob: a placement out of reach, a delivery of what he does not carry,
	# a cancel of alice's blueprint, a demolition of a wall of the map.
	assert_eq(await _ask_structure(b, func() -> int: return _structure_net(b).request_place(WALL, FAR_PLACE_TILE, 0)), [false, BuildingService.REASON_TOO_FAR, ""])
	var not_carried: Array = [false, InventoryService.REASON_NOT_IN_INVENTORY, ""]
	assert_eq(await _ask_structure(b, func() -> int: return _structure_net(b).request_deliver(wall_id, wood_stack, 0)), not_carried, "alice's wood")
	assert_eq(await _ask_structure(b, func() -> int: return _structure_net(b).request_deliver(wall_id, food_lying, 0)), not_carried, "food lying on the ground")
	assert_eq(await _ask_structure(b, func() -> int: return _structure_net(b).request_deliver(wall_id, MISSING_ITEM_ID, 0)), not_carried, "an id nobody has: the same answer")
	assert_eq(await _ask_structure(b, func() -> int: return _structure_net(b).request_cancel(wall_id)), [false, BuildingService.REASON_NOT_OWNER, ""])
	await _move(b, BY_THE_HOUSE_WALL)
	assert_eq(await _ask_structure(b, func() -> int: return _structure_net(b).request_demolish(map_wall)), [false, BuildingService.REASON_NOT_OWNER, ""], "a wall of the map belongs to nobody who could demolish it")
	# Carol, far away: the cabinet and the house door are answered like ids
	# that do not exist.
	var real: Array = [
		await _container_ask(c, func() -> int: return _container_net(c).request_open(cabinet_id)),
		await _container_ask(c, func() -> int: return _container_net(c).request_take(cabinet_id, MISSING_ITEM_ID, InventoryService.WHOLE_STACK)),
		await _ask_structure(c, func() -> int: return _structure_net(c).request_door(_house_door(), true)),
	]
	var invented: Array = [
		await _container_ask(c, func() -> int: return _container_net(c).request_open(MISSING_CONTAINER_ID)),
		await _container_ask(c, func() -> int: return _container_net(c).request_take(MISSING_CONTAINER_ID, MISSING_ITEM_ID, InventoryService.WHOLE_STACK)),
		await _ask_structure(c, func() -> int: return _structure_net(c).request_door(MISSING_STRUCTURE_ID, true)),
	]
	assert_eq(real, [[false, ContainerService.REASON_UNKNOWN_CONTAINER], [false, ContainerService.REASON_UNKNOWN_CONTAINER], [false, BuildingService.REASON_UNKNOWN_STRUCTURE, ""]])
	assert_eq(real, invented, "a far peer cannot tell a real id from an invented one")

	# Nothing changed anywhere, every refusal was counted.
	await _settle()
	assert_eq(_building().rows(), structures_before, "the structures are untouched")
	assert_eq(_server_carried(_id(a)), alice_carried, "alice's inventory is untouched")
	assert_eq(_server_contents(cabinet_id), cabinet_contents, "the cabinet is untouched")
	assert_false(_containers().get_container(cabinet_id).searched, "and still unsearched")
	assert_true(_world.inventory.world_item_ids().has(food_lying), "the food still lies there")
	assert_eq(_cluster.server.rejected_intent_count() - rejected, 12, "every forged request was refused and counted")
	assert_true(await _until(func() -> bool: return _mirrors_agree([a, b], wall_id)))
	assert_eq(_container_mirror(c).container_count(), 0)
	assert_eq(_structures(c).structure_count(), 0)
	_clean([a, b, c])
