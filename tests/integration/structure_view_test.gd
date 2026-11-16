extends TestCase
## P3-4b: real ClientView input against NetTestCluster. The client places a
## wall blueprint, delivers its carried materials and works it to completion.

const WORLD: String = "structure_view_test_world"
const WAIT_MSEC: int = 15000
const WOOD: String = "dev_wood"
const NAILS: String = "dev_nails"
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60

var _cluster: NetTestCluster
var _world: ServerWorld
var _session_root: Node
var _held_actions: Array[StringName] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_cluster = null
	_world = null
	_session_root = null
	_held_actions = []


func after_each() -> void:
	for action: StringName in _held_actions:
		Input.action_release(action)
	if _session_root != null and is_instance_valid(_session_root):
		var path: NodePath = _session_root.get_path()
		_session_root.free()
		tree.set_multiplayer(null, path)
	if _cluster != null:
		await _cluster.shutdown()
	GameLogger.set_capture(false)


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func _press(action: StringName) -> void:
	await tree.physics_frame
	Input.action_press(action)
	_held_actions.append(action)
	await tree.physics_frame
	await tree.physics_frame
	Input.action_release(action)
	_held_actions.erase(action)
	await tree.physics_frame


func _start_server() -> bool:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# Replace mutable cached resources, never modify from_defaults() members.
	config.gameplay = GameplaySettings.new()
	config.clock = WorldClockSettings.new()
	config.dev_seed = DevWorldSeed.new()
	config.survival = SurvivalSettings.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.building = BuildingSettings.new()
	config.structure_net = StructureNetSettings.new()
	config.structure_net.place_intent_rate_per_sec = GENEROUS_RATE
	config.structure_net.place_intent_burst = GENEROUS_BURST
	config.structure_net.deliver_intent_rate_per_sec = GENEROUS_RATE
	config.structure_net.deliver_intent_burst = GENEROUS_BURST
	config.structure_net.work_intent_rate_per_sec = GENEROUS_RATE
	config.structure_net.work_intent_burst = GENEROUS_BURST
	var net_settings: NetworkSettings = NetworkSettings.new()
	net_settings.autosave_interval_sec = 0.0
	net_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	net_settings.pickup_intent_burst = GENEROUS_BURST
	_cluster = NetTestCluster.new(tree, net_settings, config)
	_world = ServerComposition.create_world(WORLD, config)
	if _world == null:
		return false
	_world.seed_new_world(config.dev_seed)
	return _cluster.start_server(_world, null) == OK


func _start_session() -> GameBootstrap:
	var bootstrap: GameBootstrap = GameBootstrap.new()
	bootstrap.name = "StructureViewSession_%d" % Time.get_ticks_usec()
	_session_root = bootstrap
	tree.root.add_child(bootstrap)
	tree.set_multiplayer(SceneMultiplayer.new(), bootstrap.get_path())
	var args: PackedStringArray = PackedStringArray(["--client", "--connect=%s:%d" % [NetTestCluster.HOST, _cluster.port], "--player-key=builder"])
	var launch: LaunchConfig = LaunchConfig.parse(args, false)
	if not launch.errors.is_empty() or bootstrap.start(launch, AppSettings.load_or_default()) != OK:
		fail("the client session did not start: %s" % "; ".join(launch.errors))
		return null
	return bootstrap


func test_build_actions_show_blueprint_progress_and_completed_wall() -> void:
	assert_true(_start_server(), "server started")
	var wood_id: String = _world.inventory.spawn_world_item(WOOD, 4, _world.cell_id_at(Vector3.ZERO), Vector3.ZERO)
	var nails_id: String = _world.inventory.spawn_world_item(NAILS, 2, _world.cell_id_at(Vector3.ZERO), Vector3.ZERO)
	assert_false(wood_id.is_empty(), "wood was laid at spawn")
	assert_false(nails_id.is_empty(), "nails were laid at spawn")
	var bootstrap: GameBootstrap = _start_session()
	if bootstrap == null:
		return
	var network: NetworkService = bootstrap.get_network()
	var view: ClientView = bootstrap.get_client_view() as ClientView
	assert_true(await _wait(func() -> bool: return not network.client_state.local_player_id.is_empty()), "joined")
	assert_true(await _wait(func() -> bool: return view.is_game_input_enabled()), "game input enabled")
	# Aim the test camera down at a tile inside the server's placement reach.
	view.set("_pitch", -0.8)
	await tree.physics_frame
	network.request_pickup(wood_id)
	network.request_pickup(nails_id)
	assert_true(await _wait(func() -> bool: return network.client_state.has_inventory_item(wood_id) and network.client_state.has_inventory_item(nails_id)), "builder carries the materials")
	var module: StructureNetModule = network.get_module(StructureNetModule.MODULE_NAME) as StructureNetModule
	await _press(ClientInputActions.BUILD_MODE)
	await _press(ClientInputActions.BUILD_WALL)
	await _press(ClientInputActions.ATTACK)
	var placed: bool = await _wait(func() -> bool: return module.client_state.structure_count() == 1)
	assert_true(placed, "left click placed one blueprint; HUD: %s" % (view.get_node("%BuildLabel") as Label).text)
	if not placed:
		return
	var structure_id: String = module.client_state.structure_ids()[0]
	var structures: Node3D = view.get_node("%Structures") as Node3D
	assert_true(await _wait(func() -> bool: return structures.get_node_or_null("Structure_" + structure_id) != null), "the blueprint has a client node")
	var visual: Node3D = structures.get_node("Structure_" + structure_id) as Node3D
	assert_not_null(visual.get_node_or_null(StructureVisuals.LABEL_NAME), "blueprints have progress labels")
	await _press(ClientInputActions.BUILD_DELIVER)
	assert_true(await _wait(func() -> bool: return int(module.client_state.get_structure(structure_id)[ClientStructureState.KEY_DELIVERED].get(WOOD, 0)) == 4 and int(module.client_state.get_structure(structure_id)[ClientStructureState.KEY_DELIVERED].get(NAILS, 0)) == 2), "M delivered carried materials")
	await _press(ClientInputActions.BUILD_WORK)
	assert_true(await _wait(func() -> bool: return float(module.client_state.get_structure(structure_id)[ClientStructureState.KEY_PROGRESS]) > 0.0), "comma started work and progress grew")
	visual = structures.get_node("Structure_" + structure_id) as Node3D
	assert_true((visual.get_node(StructureVisuals.LABEL_NAME) as Label3D).text.contains("%"), "progress is visible")
	assert_true(await _wait(func() -> bool: return str(module.client_state.get_structure(structure_id)[ClientStructureState.KEY_STATE]) == "completed"), "the server completed the wall")
	visual = structures.get_node("Structure_" + structure_id) as Node3D
	assert_null(visual.get_node_or_null(StructureVisuals.LABEL_NAME), "the completed solid has no blueprint label")
