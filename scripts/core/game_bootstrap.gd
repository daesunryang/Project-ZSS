class_name GameBootstrap
extends Node
## Starts a client or server session (docs/09 §4 GameBootstrap).
##
## Lifecycle: created by Main, `start()` called once, then lives as long as
## the session. Server sessions never load presentation scenes; scene paths
## are loaded lazily per role so the server does not even load client
## resources.
##
## Networking: a server always loads (or creates) the authoritative world and
## listens; a client connects only when launched with --connect. The
## NetworkService node sits at GameBootstrap/NetworkService in every process
## so RPC node paths match between server and clients.

signal session_started(role_name: String, world_id: String)

const WORLD_SCENE_PATH: String = "res://scenes/world/game_world.tscn"
const CLIENT_VIEW_SCENE_PATH: String = "res://scenes/main/client_view.tscn"
const NETWORK_NODE_NAME: String = "NetworkService"

var _world: GameWorld = null
var _client_view: Node = null
var _role_name: String = ""
var _network: NetworkService = null


## Builds the session for `config`. Returns OK or an error code (already logged).
func start(config: LaunchConfig, settings: AppSettings) -> Error:
	if _world != null:
		GameLogger.error("bootstrap", "start() called twice", {"operation": "bootstrap_start"})
		return ERR_ALREADY_IN_USE
	_role_name = config.role_name()
	var world_id: String = config.world_id_override if not config.world_id_override.is_empty() else settings.default_world_id

	var world_scene: PackedScene = _load_scene(WORLD_SCENE_PATH)
	if world_scene == null:
		return ERR_CANT_OPEN
	var world: GameWorld = world_scene.instantiate() as GameWorld
	if world == null:
		GameLogger.error("bootstrap", "world scene root is not a GameWorld", {"path": WORLD_SCENE_PATH, "operation": "bootstrap_start"})
		return ERR_INVALID_DATA
	var setup_result: Error = world.setup(world_id)
	if setup_result != OK:
		world.free()
		return setup_result
	_world = world
	add_child(_world)

	if not config.is_server():
		var view_scene: PackedScene = _load_scene(CLIENT_VIEW_SCENE_PATH)
		if view_scene == null:
			return ERR_CANT_OPEN
		_client_view = view_scene.instantiate()
		add_child(_client_view)

	var network_result: Error = _start_network(config, settings, world_id)
	if network_result != OK:
		return network_result

	GameLogger.info("bootstrap", "session started", {
		"role": _role_name, "role_source": config.role_source, "world_id": world_id,
	})
	session_started.emit(_role_name, world_id)
	return OK


func get_world() -> GameWorld:
	return _world


## Client presentation root, or null on the server.
func get_client_view() -> Node:
	return _client_view


func get_role_name() -> String:
	return _role_name


## The session's NetworkService, or null for an offline client.
func get_network() -> NetworkService:
	return _network


func _start_network(config: LaunchConfig, settings: AppSettings, world_id: String) -> Error:
	if not config.is_server() and config.connect_address.is_empty():
		return OK  # offline client (no --connect)
	var network_settings: NetworkSettings = NetworkSettings.load_or_default()
	var errors: PackedStringArray = network_settings.validate()
	if not errors.is_empty():
		GameLogger.error("bootstrap", "invalid network settings", {"errors": "; ".join(errors), "operation": "start_network"})
		return ERR_INVALID_DATA
	_network = NetworkService.new()
	_network.name = NETWORK_NODE_NAME
	add_child(_network)
	if config.is_server():
		return _start_server(config, settings, network_settings, world_id)
	var port: int = config.connect_port if config.connect_port > 0 else (config.port_override if config.port_override > 0 else network_settings.port)
	return _network.start_client(config.connect_address, port, config.player_key, network_settings)


func _start_server(config: LaunchConfig, settings: AppSettings, network_settings: NetworkSettings, world_id: String) -> Error:
	var gameplay: GameplaySettings = GameplaySettings.load_or_default()
	var errors: PackedStringArray = gameplay.validate()
	if not errors.is_empty():
		GameLogger.error("bootstrap", "invalid gameplay settings", {"errors": "; ".join(errors), "operation": "start_server"})
		return ERR_INVALID_DATA
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var save_root: String = config.save_root_override if not config.save_root_override.is_empty() else settings.save_root
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(save_root, settings.save_backup_keep), gameplay, catalog)
	var server_world: ServerWorld = persistence.load_or_create(world_id, DevWorldSeed.load_or_default())
	if server_world == null:
		return ERR_FILE_CORRUPT
	var port: int = config.port_override if config.port_override > 0 else network_settings.port
	return _network.start_server(server_world, persistence, network_settings, port)


func _load_scene(path: String) -> PackedScene:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		GameLogger.error("bootstrap", "failed to load scene", {"path": path, "operation": "load_scene"})
	return scene
