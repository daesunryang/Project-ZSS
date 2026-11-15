extends TestCase
## GameBootstrap in a real SceneTree: server builds the empty world with no
## presentation; client builds the world plus the client view.

var _bootstrap: GameBootstrap = null
var _save_root: String = ""


func _server_args() -> PackedStringArray:
	return PackedStringArray(["--server", "--port=%d" % (26000 + randi() % 9000), "--save-root=" + _save_root])


func before_each() -> void:
	GameLogger.set_capture(true)
	_save_root = "user://test_saves/bootstrap_%d" % Time.get_ticks_usec()
	_bootstrap = GameBootstrap.new()
	tree.root.add_child(_bootstrap)


func after_each() -> void:
	if is_instance_valid(_bootstrap):
		_bootstrap.queue_free()
		await next_frame()
	_bootstrap = null
	SaveService.remove_tree(_save_root)
	GameLogger.set_capture(false)


func test_server_session_has_world_and_no_presentation() -> void:
	var config: LaunchConfig = LaunchConfig.parse(_server_args(), false)
	var result: Error = _bootstrap.start(config, AppSettings.load_or_default())
	await next_frame()
	assert_eq(result, OK)
	assert_eq(_bootstrap.get_role_name(), "server")
	assert_not_null(_bootstrap.get_world())
	assert_true(_bootstrap.get_world().is_world_ready())
	assert_eq(_bootstrap.get_world().get_world_id(), "dev_empty_world")
	assert_eq(_bootstrap.get_world().get_cell_count(), 0)
	assert_null(_bootstrap.get_client_view())
	assert_eq(_count_nodes_of_class(_bootstrap, "Camera3D"), 0, "server must not create cameras")
	assert_eq(_count_nodes_of_class(_bootstrap, "CanvasLayer"), 0, "server must not create UI")
	assert_not_null(_bootstrap.get_network())
	assert_true(_bootstrap.get_network().is_server())
	assert_true(SaveService.new(_save_root).has_save("dev_empty_world"), "new world is saved immediately")
	# P2-T9: a dedicated server asks every player to create its character.
	assert_true(_bootstrap.get_network().get_world().require_character_creation, "the real server requires character creation")
	assert_not_null(_bootstrap.get_network().get_module(CharacterNetModule.MODULE_NAME))


func test_client_session_has_world_and_presentation() -> void:
	var config: LaunchConfig = LaunchConfig.parse(PackedStringArray(["--client", "--world-id=client_test_world"]), false)
	var result: Error = _bootstrap.start(config, AppSettings.load_or_default())
	await next_frame()
	assert_eq(result, OK)
	assert_eq(_bootstrap.get_role_name(), "client")
	assert_eq(_bootstrap.get_world().get_world_id(), "client_test_world")
	assert_not_null(_bootstrap.get_client_view())
	assert_eq(_count_nodes_of_class(_bootstrap, "Camera3D"), 1)
	assert_null(_bootstrap.get_network(), "client without --connect stays offline")


func test_start_twice_is_rejected() -> void:
	var config: LaunchConfig = LaunchConfig.parse(PackedStringArray(["--client"]), false)
	var settings: AppSettings = AppSettings.load_or_default()
	assert_eq(_bootstrap.start(config, settings), OK)
	assert_eq(_bootstrap.start(config, settings), ERR_ALREADY_IN_USE)


func test_world_rejects_invalid_id() -> void:
	var world: GameWorld = (load(GameBootstrap.WORLD_SCENE_PATH) as PackedScene).instantiate() as GameWorld
	assert_eq(world.setup("Bad Id"), ERR_INVALID_PARAMETER)
	world.free()


func _count_nodes_of_class(root: Node, class_name_text: String) -> int:
	var count: int = 1 if root.is_class(class_name_text) else 0
	for child: Node in root.get_children():
		count += _count_nodes_of_class(child, class_name_text)
	return count
