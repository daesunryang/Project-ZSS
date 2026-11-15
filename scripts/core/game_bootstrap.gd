class_name GameBootstrap
extends Node
## Starts a client or server session (docs/09 §4 GameBootstrap).
##
## Lifecycle: created by Main, `start()` called once, then lives as long as
## the session. Server sessions never load presentation scenes; scene paths
## are loaded lazily per role so the server does not even load client
## resources.

signal session_started(role_name: String, world_id: String)

const WORLD_SCENE_PATH: String = "res://scenes/world/game_world.tscn"
const CLIENT_VIEW_SCENE_PATH: String = "res://scenes/main/client_view.tscn"

var _world: GameWorld = null
var _client_view: Node = null
var _role_name: String = ""


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


func _load_scene(path: String) -> PackedScene:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		GameLogger.error("bootstrap", "failed to load scene", {"path": path, "operation": "load_scene"})
	return scene
