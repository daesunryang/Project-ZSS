class_name NetTestCluster
extends RefCounted
## Runs one server and N clients inside a single SceneTree, each in its own
## subtree with its own SceneMultiplayer, talking over real ENet sockets on
## localhost. Used by integration/scenario tests.
## Every service gets the production NetModules from
## ServerComposition.install_net_modules(); tests may add test-only modules
## via `extra_module_factories` (Callables returning a new NetModule).
##
## Timing (docs/12 §1.1): while a cluster runs, the engine does at most one
## physics tick per frame (`Engine.max_physics_steps_per_frame = 1`). The
## server steps in physics ticks, the network is polled once per frame. With
## the engine default (8) a slow frame is caught up with a burst of server
## ticks and no poll in between, so on a loaded machine a client sees the
## server several ticks later than on an idle one and anything a test steers
## by the client's mirrors (walking up to a zombie, stopping) goes further.
## With one tick per frame a slow machine runs the simulation more slowly
## instead, and every tick is followed by a poll. Restored when the last
## cluster is shut down (a cluster never shut down leaves it at 1).

const HOST: String = "127.0.0.1"
const PORT_BASE: int = 25000
const PORT_SPAN: int = 10000
const PORT_ATTEMPTS: int = 8
const DEFAULT_WAIT_FRAMES: int = 600
const NO_SAVED_STEPS: int = -1

## The engine's steps per frame before the first cluster changed it, and
## how many clusters were made and not shut down yet.
static var _saved_physics_steps: int = NO_SAVED_STEPS
static var _live_clusters: int = 0

var tree: SceneTree
var settings: NetworkSettings
var config: CompositionConfig
var extra_module_factories: Array[Callable] = []
var port: int = 0
var server: NetworkService = null
var clients: Array[NetworkService] = []
var _roots: Array[Node] = []
var _counter: int = 0
var _live: bool = true


func _init(scene_tree: SceneTree, network_settings: NetworkSettings, composition: CompositionConfig = null) -> void:
	tree = scene_tree
	settings = network_settings
	config = composition if composition != null else CompositionConfig.from_defaults()
	if _live_clusters == 0:
		_saved_physics_steps = Engine.max_physics_steps_per_frame
	_live_clusters += 1
	Engine.max_physics_steps_per_frame = 1


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
	return add_client_with_settings(player_key, settings, auto_join)


## Adds a client with an explicit transport contract. Compression mismatch
## tests use this because normal clusters intentionally share one resource.
func add_client_with_settings(player_key: String, client_settings: NetworkSettings, auto_join: bool = true) -> NetworkService:
	var client: NetworkService = _make_service("TestClient")
	clients.append(client)
	client.start_client(HOST, port, player_key, client_settings, auto_join)
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


## Polls `condition` once per frame; true when it held before `max_ticks`
## server (physics) ticks passed. The limit is simulated time, so a slow
## machine does not shorten it; use this when the condition waits for
## something the simulation does (a timer, a cooldown, a corpse removal).
func wait_ticks_until(condition: Callable, max_ticks: int) -> bool:
	var last_tick: int = Engine.get_physics_frames() + max_ticks
	while Engine.get_physics_frames() < last_tick:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


## Waits exactly `count` server (physics) ticks: a window of simulated time.
func wait_ticks(count: int) -> void:
	for tick: int in range(count):
		await tree.physics_frame


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
	if _live:
		_live = false
		_live_clusters -= 1
		if _live_clusters == 0 and _saved_physics_steps != NO_SAVED_STEPS:
			Engine.max_physics_steps_per_frame = _saved_physics_steps
			_saved_physics_steps = NO_SAVED_STEPS
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
	ServerComposition.install_net_modules(service, config)
	for factory: Callable in extra_module_factories:
		service.register_module(factory.call() as NetModule)
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
