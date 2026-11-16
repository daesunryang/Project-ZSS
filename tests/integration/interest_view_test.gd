extends TestCase
## P3-2 client view (docs/09 §15.2, docs/11 §2.15) in a real (headless)
## client session: GameBootstrap with its ClientView against a real server.
##   - the ground and the map edges have the size the SERVER described with
##     the join (the server here runs a map that differs from the shipped
##     settings the client session loads for itself);
##   - the HUD names the world cell the local player is in;
##   - item markers and zombie visuals follow the mirror as the player walks
##     and things come into and leave its cells;
##   - the cell overlay is switched with its real input action.
## What a real window shows cannot be checked here (docs/15 §15.2).

const WORLD: String = "interest_view_test_world"
const WAIT_MSEC: int = 8000
const SETTLE_TICKS: int = 20
const NEVER: float = 1.0e9
## The map of the test server: 20 m cells, 160 m x 160 m, not centred.
const CELL_M: float = 20.0
const BOUNDS_MIN: Vector2 = Vector2(-60.0, -60.0)
const BOUNDS_MAX: Vector2 = Vector2(100.0, 100.0)
const SPAWN: Vector3 = Vector3(-50.0, 0.0, -50.0)
const NEAR_ITEM_AT: Vector3 = Vector3(-47.0, 0.0, -47.0)
const FAR_ITEM_AT: Vector3 = Vector3(50.0, 0.0, 50.0)
const NEAR_ZOMBIE_AT: Vector3 = Vector3(-50.0, 0.0, -15.0)
const FAR_ZOMBIE_AT: Vector3 = Vector3(50.0, 0.0, 15.0)
const FAR_PLACE: Vector3 = Vector3(45.0, 0.0, 45.0)
const NEAR_PLACE: Vector3 = SPAWN

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _session_root: Node = null
var _held_actions: Array[StringName] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_cluster = null
	_session_root = null
	_world = null
	_held_actions = []


func after_each() -> void:
	for action: StringName in _held_actions:
		if InputMap.has_action(action):
			Input.action_release(action)
	if _session_root != null and is_instance_valid(_session_root):
		var path: NodePath = _session_root.get_path()
		_session_root.free()
		tree.set_multiplayer(null, path)
	if _cluster != null:
		await _cluster.shutdown()
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func _settle() -> void:
	for tick: int in range(SETTLE_TICKS):
		await tree.physics_frame


func _start_server() -> bool:
	var net_settings: NetworkSettings = NetworkSettings.new()
	net_settings.autosave_interval_sec = 0.0
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.gameplay.world_half_extent_m = 60.0
	_config.gameplay.player_spawn_position = SPAWN
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.wander_pause_min_sec = NEVER
	_config.zombie.wander_pause_max_sec = NEVER
	_config.zombie.sight_range_m = 0.0
	_config.world_cells = WorldCellSettings.new()
	_config.world_cells.cell_size_m = CELL_M
	_config.world_cells.bounds_min_m = BOUNDS_MIN
	_config.world_cells.bounds_max_m = BOUNDS_MAX
	_config.world_cells.refresh_period_sec = 0.0
	_config.world_cells.preload_lookahead_sec = 0.0
	_config.interest = InterestSettings.new()
	_cluster = NetTestCluster.new(tree, net_settings, _config)
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


## Starts a real client session (GameBootstrap with its ClientView) that
## connects to the test server. Its multiplayer root is the bootstrap node,
## so the NetworkService RPC path equals the server's. The session loads the
## shipped settings for itself: nothing of the test server's map is in them.
func _start_session(player_key: String) -> GameBootstrap:
	var bootstrap: GameBootstrap = GameBootstrap.new()
	bootstrap.name = "InterestViewSession_%d" % Time.get_ticks_usec()
	_session_root = bootstrap
	tree.root.add_child(bootstrap)
	tree.set_multiplayer(SceneMultiplayer.new(), bootstrap.get_path())
	var args: PackedStringArray = PackedStringArray(["--client", "--connect=%s:%d" % [NetTestCluster.HOST, _cluster.port], "--player-key=" + player_key])
	var launch: LaunchConfig = LaunchConfig.parse(args, false)
	if not launch.errors.is_empty() or bootstrap.start(launch, AppSettings.load_or_default()) != OK:
		fail("the client session did not start: %s" % "; ".join(launch.errors))
		return null
	return bootstrap


## One key press of an input action as the view sees it: pressed at the
## start of a physics frame, held for two frames, released.
func _press(action: StringName) -> void:
	await tree.physics_frame
	Input.action_press(action)
	_held_actions.append(action)
	await tree.physics_frame
	await tree.physics_frame
	Input.action_release(action)
	_held_actions.erase(action)
	await tree.physics_frame


func _map_root(view: ClientView) -> Node3D:
	return view.get_node("%WorldMap") as Node3D


func _map_label(view: ClientView) -> String:
	var label: Label = view.get_node("%MapLabel") as Label
	return label.text if label.visible else ""


func _has_marker(view: ClientView, item_id: String) -> bool:
	return view.has_world_item_visual(item_id)


func _has_zombie_visual(view: ClientView, zombie_id: String) -> bool:
	return view.has_zombie_visual(zombie_id)


func _overlay(view: ClientView) -> Node3D:
	return _map_root(view).get_node_or_null(WorldMapVisuals.OVERLAY_NODE) as Node3D


func _has_cell_label(view: ClientView, cell_id: String) -> bool:
	var labels: Node = _overlay(view).get_node(WorldMapVisuals.OVERLAY_LABELS_NODE)
	var label: Node = labels.get_node_or_null(WorldMapVisuals.LABEL_PREFIX + cell_id)
	return label != null and not label.is_queued_for_deletion()


func _spawn_item(position: Vector3) -> String:
	return _world.inventory.spawn_world_item("dev_test_item", 1, _world.cell_id_at(position), position)


func _spawn_zombie(position: Vector3) -> String:
	var zombies: ZombieService = _world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	return str(zombies.spawn_zombie(_world, position, 0.0).event.get("zombie_id", ""))


# ------------------------------------------------------------ the view

func test_the_view_draws_the_servers_map_and_follows_the_players_cells() -> void:
	assert_true(_start_server(), "server started")
	var near_item: String = _spawn_item(NEAR_ITEM_AT)
	var far_item: String = _spawn_item(FAR_ITEM_AT)
	var near_zombie: String = _spawn_zombie(NEAR_ZOMBIE_AT)
	var far_zombie: String = _spawn_zombie(FAR_ZOMBIE_AT)
	var bootstrap: GameBootstrap = _start_session("viewer")
	if bootstrap == null:
		return
	var network: NetworkService = bootstrap.get_network()
	var view: ClientView = bootstrap.get_client_view() as ClientView
	assert_not_null(view)
	assert_eq(_map_root(view).get_child_count(), 0, "no map before the server described one")
	assert_eq(_map_label(view), "")
	assert_true(await _wait(func() -> bool: return not network.client_state.local_player_id.is_empty()), "the session joined")
	var viewer_id: String = network.client_state.local_player_id
	var presentation: ClientPresentationSettings = ClientPresentationSettings.load_or_default()

	# --- the ground and the edges are the map the server runs ---
	assert_true(await _wait(func() -> bool: return _map_root(view).get_node_or_null(WorldMapVisuals.GROUND_NODE) != null), "the ground was built")
	var ground: MeshInstance3D = _map_root(view).get_node(WorldMapVisuals.GROUND_NODE) as MeshInstance3D
	assert_eq((ground.mesh as PlaneMesh).size, Vector2(160.0, 160.0), "as large as the map of the server, not the 500 m of the shipped settings")
	assert_eq(ground.position, Vector3(20.0, 0.0, 20.0), "and where it is")
	var edges: Node3D = _map_root(view).get_node(WorldMapVisuals.EDGES_NODE) as Node3D
	assert_eq(edges.get_child_count(), 4, "one wall per edge")
	var low_x: MeshInstance3D = edges.get_node(WorldMapPresentation.EDGE_NAMES[0]) as MeshInstance3D
	assert_eq(low_x.position, Vector3(BOUNDS_MIN.x - presentation.map_edge_thickness_m * 0.5, presentation.map_edge_height_m * 0.5, 20.0))
	assert_eq((low_x.mesh as BoxMesh).size, Vector3(presentation.map_edge_thickness_m, presentation.map_edge_height_m, 160.0))
	var high_z: MeshInstance3D = edges.get_node(WorldMapPresentation.EDGE_NAMES[3]) as MeshInstance3D
	assert_eq(high_z.position.z, BOUNDS_MAX.y + presentation.map_edge_thickness_m * 0.5)

	# --- the HUD names the cell; markers and zombies are those of its cells ---
	assert_true(await _wait(func() -> bool: return view.current_cell_id() == "cell_-3_-3"), "the player stands in cell_-3_-3 (%s)" % view.current_cell_id())
	assert_contains(_map_label(view), "cell_-3_-3")
	assert_contains(_map_label(view), "꺼짐")
	assert_true(await _wait(func() -> bool: return _has_marker(view, near_item) and _has_zombie_visual(view, near_zombie)), "what is near is shown")
	# A snapshot moves the existing MultiMesh instance without adding a node.
	var zombie_mirror: ClientZombieState = (network.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state
	var moved_zombie: Vector3 = NEAR_ZOMBIE_AT + Vector3.RIGHT
	assert_eq(zombie_mirror.apply_snapshot(zombie_mirror.last_snapshot_tick + 1, [[near_zombie, moved_zombie, 0.25, 0, 1.0]]), "")
	assert_eq(view.zombie_visual_transform(near_zombie).origin, moved_zombie + Vector3.UP * presentation.zombie_capsule_height_m * 0.5, "snapshot moved the batched zombie transform")
	assert_false(_has_marker(view, far_item), "an item five cells away is not")
	assert_false(_has_zombie_visual(view, far_zombie), "nor a zombie there")

	# --- the player walks to the far corner: the view follows the mirror ---
	_world.get_player(viewer_id).position = FAR_PLACE
	assert_true(await _wait(func() -> bool: return view.current_cell_id() == "cell_2_2"), "the HUD follows the player")
	assert_contains(_map_label(view), "cell_2_2")
	assert_contains(_map_label(view), "x 45, z 45")
	assert_true(await _wait(func() -> bool: return _has_marker(view, far_item) and _has_zombie_visual(view, far_zombie)), "what lies there appeared")
	assert_true(await _wait(func() -> bool: return not _has_marker(view, near_item) and not _has_zombie_visual(view, near_zombie)), "and what was left behind is gone")
	assert_eq((view.get_node("%WorldItems/WorldItemBodies") as MultiMeshInstance3D).multimesh.instance_count, 1, "exactly the markers of the mirror")

	# --- the cell overlay is off until its key is pressed ---
	assert_false(view.is_cell_overlay_visible())
	assert_false(_overlay(view).visible)
	await _press(ClientInputActions.CELL_OVERLAY)
	assert_true(view.is_cell_overlay_visible(), "the overlay key switched it on")
	assert_true(_overlay(view).visible)
	assert_contains(_map_label(view), "켜짐")
	assert_true(_has_cell_label(view, "cell_2_2"), "the cell the player is in is labelled")
	assert_true(_has_cell_label(view, "cell_-1_-1"), "and the cells up to three away")
	assert_false(_has_cell_label(view, "cell_-2_-2"), "but not the one four away")
	# Cells -1..4 on both axes: seven lines each way.
	var visuals_lines: MeshInstance3D = _overlay(view).get_node(WorldMapVisuals.OVERLAY_LINES_NODE) as MeshInstance3D
	assert_eq((visuals_lines.mesh as ArrayMesh).surface_get_array_len(0), 28, "fourteen border segments")
	# The overlay follows the player.
	_world.get_player(viewer_id).position = NEAR_PLACE
	assert_true(await _wait(func() -> bool: return view.current_cell_id() == "cell_-3_-3" and _has_cell_label(view, "cell_-3_-3")), "the overlay was rebuilt around the new cell")
	assert_false(_has_cell_label(view, "cell_2_2"))
	assert_true(_has_cell_label(view, "cell_0_0"), "up to three cells from the corner of the map")
	await _press(ClientInputActions.CELL_OVERLAY)
	assert_false(view.is_cell_overlay_visible(), "pressed again: off")
	assert_false(_overlay(view).visible)
	assert_contains(_map_label(view), "꺼짐")
	await _settle()
	assert_true(_has_marker(view, near_item), "back where she started, the player sees the first item again")
	assert_false(_has_marker(view, far_item))
