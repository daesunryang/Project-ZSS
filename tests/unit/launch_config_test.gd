extends TestCase
## LaunchConfig: role resolution and argument validation.


func test_defaults_to_client_without_arguments() -> void:
	var config: LaunchConfig = LaunchConfig.parse(PackedStringArray(), false)
	assert_eq(config.role, LaunchConfig.Role.CLIENT)
	assert_eq(config.role_source, "default")
	assert_eq(config.run_frames, LaunchConfig.RUN_FOREVER)
	assert_true(config.errors.is_empty())


func test_server_argument_selects_server() -> void:
	var config: LaunchConfig = LaunchConfig.parse(PackedStringArray(["--server"]), false)
	assert_true(config.is_server())
	assert_eq(config.role_source, "argument")
	assert_eq(config.role_name(), "server")


func test_dedicated_build_defaults_to_server() -> void:
	var config: LaunchConfig = LaunchConfig.parse(PackedStringArray(), true)
	assert_true(config.is_server())
	assert_eq(config.role_source, "feature_tag")


func test_dedicated_build_rejects_client_argument() -> void:
	var config: LaunchConfig = LaunchConfig.parse(PackedStringArray(["--client"]), true)
	assert_eq(config.errors.size(), 1)


func test_server_and_client_are_mutually_exclusive() -> void:
	var config: LaunchConfig = LaunchConfig.parse(PackedStringArray(["--server", "--client"]), false)
	assert_eq(config.errors.size(), 1)
	assert_contains(config.errors[0], "mutually exclusive")


func test_parses_overrides() -> void:
	var args: PackedStringArray = ["--log-level=debug", "--world-id=test_world_2", "--run-frames=30"]
	var config: LaunchConfig = LaunchConfig.parse(args, false)
	assert_true(config.errors.is_empty(), ", ".join(config.errors))
	assert_eq(config.log_level_override, "DEBUG")
	assert_eq(config.world_id_override, "test_world_2")
	assert_eq(config.run_frames, 30)


func test_rejects_invalid_values_and_unknown_arguments() -> void:
	var args: PackedStringArray = ["--log-level=loud", "--world-id=../escape", "--run-frames=-1", "--nope"]
	var config: LaunchConfig = LaunchConfig.parse(args, false)
	assert_eq(config.errors.size(), 4, ", ".join(config.errors))


func test_world_id_validation() -> void:
	assert_true(LaunchConfig.is_valid_world_id("dev_empty_world"))
	assert_false(LaunchConfig.is_valid_world_id(""))
	assert_false(LaunchConfig.is_valid_world_id("Upper"))
	assert_false(LaunchConfig.is_valid_world_id("a/b"))
	assert_false(LaunchConfig.is_valid_world_id("x".repeat(LaunchConfig.MAX_WORLD_ID_LENGTH + 1)))


func test_parses_network_arguments() -> void:
	var args: PackedStringArray = ["--client", "--connect=127.0.0.1:25001", "--player-key=alice", "--port=24000"]
	var config: LaunchConfig = LaunchConfig.parse(args, false)
	assert_true(config.errors.is_empty(), ", ".join(config.errors))
	assert_eq(config.connect_address, "127.0.0.1")
	assert_eq(config.connect_port, 25001)
	assert_eq(config.player_key, "alice")
	assert_eq(config.port_override, 24000)
	var server: LaunchConfig = LaunchConfig.parse(PackedStringArray(["--server", "--save-root=user://smoke"]), false)
	assert_eq(server.save_root_override, "user://smoke")


func test_rejects_bad_network_arguments() -> void:
	assert_eq(LaunchConfig.parse(PackedStringArray(["--port=0"]), false).errors.size(), 1)
	assert_eq(LaunchConfig.parse(PackedStringArray(["--port=70000"]), false).errors.size(), 1)
	assert_eq(LaunchConfig.parse(PackedStringArray(["--connect=host:x", "--player-key=a"]), false).errors.size(), 1)
	assert_eq(LaunchConfig.parse(PackedStringArray(["--connect=host"]), false).errors.size(), 1, "needs player key")
	assert_eq(LaunchConfig.parse(PackedStringArray(["--server", "--connect=h", "--player-key=a"]), false).errors.size(), 1)
	assert_eq(LaunchConfig.parse(PackedStringArray(["--save-root=/etc"]), false).errors.size(), 1)
	assert_eq(LaunchConfig.parse(PackedStringArray(["--save-root=user://../x"]), false).errors.size(), 1)
