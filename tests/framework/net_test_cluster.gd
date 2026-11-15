class_name NetTestCluster
extends RefCounted
## Runs one server and N clients inside a single SceneTree, each in its own
## subtree with its own SceneMultiplayer, talking over real ENet sockets on
## localhost. Used by integration/scenario tests.

const HOST: String = "127.0.0.1"
const PORT_BASE: int = 25000
const PORT_SPAN: int = 10000
const PORT_ATTEMPTS: int = 8
const DEFAULT_WAIT_FRAMES: int = 600

var tree: SceneTree
var settings: NetworkSettings
var port: int = 0
var server: NetworkService = null
var clients: Array[NetworkService] = []
var _roots: Array[Node] = []
var _counter: int = 0


func _init(scene_tree: SceneTree, network_settings: NetworkSettings) -> void:
	tree = scene_tree
	settings = network_settings


## Starts the server on a free random port.
func start_server(world: ServerWorld, persistence: WorldPersistence) -> Error:
	server = _make_service("TestServer")
	var error: Error = FAILED
	for attempt: int in range(PORT_ATTEMPTS):
		port = PORT_BASE + randi() % PORT_SPAN
		error = server.start_server(world, persistence, settings, port)
		if error == OK:
			return OK
	return error


## Adds a client and starts connecting (not yet joined).
func add_client(player_key: String, auto_join: bool = true) -> NetworkService:
	var client: NetworkService = _make_service("TestClient")
	clients.append(client)
	client.start_client(HOST, port, player_key, settings, auto_join)
	return client


## Adds a client and waits until it joined. Returns null on failure.
func join_client(player_key: String) -> NetworkService:
	var client: NetworkService = add_client(player_key)
	var ok: bool = await wait_until(func() -> bool: return not client.client_state.local_player_id.is_empty())
	return client if ok else null


## Polls `condition` once per frame; true when it held within `max_frames`.
func wait_until(condition: Callable, max_frames: int = DEFAULT_WAIT_FRAMES) -> bool:
	for frame: int in range(max_frames):
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func wait_frames(count: int) -> void:
	for frame: int in range(count):
		await tree.process_frame


## Stops and removes one client (simulates the player quitting).
func remove_client(client: NetworkService) -> void:
	clients.erase(client)
	_free_service(client)


## Stops and removes the server (simulates server shutdown; it saves).
func remove_server() -> void:
	if server != null:
		_free_service(server)
		server = null


func shutdown() -> void:
	for client: NetworkService in clients.duplicate():
		remove_client(client)
	remove_server()
	await tree.process_frame


func _make_service(prefix: String) -> NetworkService:
	_counter += 1
	var root: Node = Node.new()
	root.name = "%s%d_%d" % [prefix, _counter, Time.get_ticks_usec()]
	tree.root.add_child(root)
	tree.set_multiplayer(SceneMultiplayer.new(), root.get_path())
	var service: NetworkService = NetworkService.new()
	service.name = "NetworkService"
	root.add_child(service)
	_roots.append(root)
	return service


func _free_service(service: NetworkService) -> void:
	if not is_instance_valid(service):
		return
	var root: Node = service.get_parent()
	service.stop()
	var path: NodePath = root.get_path()
	_roots.erase(root)
	root.free()
	tree.set_multiplayer(null, path)
