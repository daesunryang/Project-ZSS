extends TestCase
## P2-T15 client view (docs/09 §14.29, docs/11 §2.13) in a real (headless)
## client session: GameBootstrap with its ClientView against a real server.
##   - every item lying in the world has a marker with its name and quantity,
##     and the markers follow the mirror (put down, picked up by anybody);
##   - the HUD lists the carried stacks, marks the selected one and names the
##     pickup candidate;
##   - the cursor keys, the drop key (one unit / the whole stack with the
##     modifier) and the pickup key are driven through the real input actions
##     (Input.action_press), so the input branch of ClientView is covered.
## What a real window shows cannot be checked here (docs/15 §14.6).

const WORLD: String = "ground_transfer_view_test_world"
const WAIT_MSEC: int = 8000
const SETTLE_TICKS: int = 20
const FOOD: String = "dev_food_ration"
const WATER: String = "dev_water_bottle"
const BANDAGE: String = "dev_bandage"
const CELL: String = DevWorldSeed.DEV_CELL_ID
const FOOD_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const WATER_AT: Vector3 = Vector3(-0.5, 0.0, 1.5)
const FAR_AT: Vector3 = Vector3(30.0, 0.0, 0.0)
const NOWHERE: Vector3 = Vector3(40.0, 0.0, 40.0)
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60

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
	net_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	net_settings.pickup_intent_burst = GENEROUS_BURST
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.inventory_net = InventoryNetSettings.new()
	_config.inventory_net.drop_intent_rate_per_sec = GENEROUS_RATE
	_config.inventory_net.drop_intent_burst = GENEROUS_BURST
	_cluster = NetTestCluster.new(tree, net_settings, _config)
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


## Starts a real client session (GameBootstrap with its ClientView) that
## connects to the test server. Its multiplayer root is the bootstrap node,
## so the NetworkService RPC path equals the server's.
func _start_session(player_key: String) -> GameBootstrap:
	var bootstrap: GameBootstrap = GameBootstrap.new()
	bootstrap.name = "GroundViewSession_%d" % Time.get_ticks_usec()
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


func _hold(action: StringName) -> void:
	Input.action_press(action)
	_held_actions.append(action)


func _release(action: StringName) -> void:
	Input.action_release(action)
	_held_actions.erase(action)


func _pause(seconds: float) -> void:
	await tree.create_timer(seconds).timeout


func _markers(view: ClientView) -> Node3D:
	return view.get_node("%WorldItems") as Node3D


func _marker_text(view: ClientView, item_id: String) -> String:
	var marker: Node3D = _markers(view).get_node_or_null(WorldItemMarkers.MARKER_PREFIX + item_id) as Node3D
	return (marker.get_node(WorldItemMarkers.LABEL_NODE) as Label3D).text if marker != null else "<no marker>"


func _hud(view: ClientView) -> String:
	return (view.get_node("%InventoryLabel") as Label).text


func _notice(view: ClientView) -> String:
	var label: Label = view.get_node("%ConsumeResultLabel") as Label
	return label.text if label.visible else ""


## [definition, quantity] of what a player carries on the server, in slot order.
func _server_rows(player_id: String) -> Array:
	var rows: Array = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		rows.append([item.definition_id, item.quantity])
	return rows


# ------------------------------------------------------------ the view

func test_the_view_shows_ground_items_the_cursor_and_puts_the_selected_stack_down() -> void:
	assert_true(_start_server(), "server started")
	var food: String = _world.inventory.spawn_world_item(FOOD, 3, CELL, FOOD_AT)
	var water: String = _world.inventory.spawn_world_item(WATER, 2, CELL, WATER_AT)
	var far: String = _world.inventory.spawn_world_item(BANDAGE, 1, CELL, FAR_AT)
	var bootstrap: GameBootstrap = _start_session("viewer")
	if bootstrap == null:
		return
	var network: NetworkService = bootstrap.get_network()
	var view: ClientView = bootstrap.get_client_view() as ClientView
	assert_not_null(view)
	assert_true(await _wait(func() -> bool: return not network.client_state.local_player_id.is_empty()), "the session joined")
	var viewer_id: String = network.client_state.local_player_id
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var food_name: String = catalog.get_definition(FOOD).display_name
	var water_name: String = catalog.get_definition(WATER).display_name
	var presentation: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_true(view.is_game_input_enabled(), "the player has a character: game input is on")

	# --- every item lying in the world has a marker with its name and quantity.
	assert_true(await _wait(func() -> bool: return _markers(view).get_child_count() == 3), "three markers (%d)" % _markers(view).get_child_count())
	assert_eq(_marker_text(view, food), "%s x3" % food_name)
	assert_eq(_marker_text(view, water), "%s x2" % water_name)
	var food_marker: Node3D = _markers(view).get_node(WorldItemMarkers.MARKER_PREFIX + food) as Node3D
	assert_eq(food_marker.position, FOOD_AT, "where the item lies")
	assert_eq(_markers(view).get_node(WorldItemMarkers.MARKER_PREFIX + far).position, FAR_AT, "items far away are shown too")
	# --- the HUD: nothing carried, the nearest item in reach is the candidate.
	assert_true(await _wait(func() -> bool: return view.pickup_candidate_id() == food), "the nearest item in reach is the pickup candidate (%s)" % view.pickup_candidate_id())
	assert_contains(_hud(view), "소지품: 없음")
	assert_contains(_hud(view), "줍기 [E]: %s x3" % food_name)
	assert_eq(view.selected_item_id(), "", "nothing carried, nothing selected")

	# --- the pickup key takes the candidate; its marker goes, the cursor lands on it.
	await _press(ClientInputActions.PICKUP)
	assert_true(await _wait(func() -> bool: return network.client_state.has_inventory_item(food)), "the pickup key picked the candidate up")
	assert_true(await _wait(func() -> bool: return _markers(view).get_child_count() == 2), "its marker is gone")
	assert_null(_markers(view).get_node_or_null(WorldItemMarkers.MARKER_PREFIX + food))
	assert_true(await _wait(func() -> bool: return view.selected_item_id() == food), "the cursor is on the only stack")
	assert_contains(_hud(view), "> %s x3" % food_name)
	assert_true(await _wait(func() -> bool: return _notice(view) == "줍기 승인"), "the pickup result is shown (%s)" % _notice(view))
	assert_true(await _wait(func() -> bool: return view.pickup_candidate_id() == water), "the next nearest item is the candidate now")
	assert_contains(_hud(view), "줍기 [E]: %s x2" % water_name)
	await _press(ClientInputActions.PICKUP)
	assert_true(await _wait(func() -> bool: return network.client_state.has_inventory_item(water)), "the second pickup")
	assert_eq(view.selected_item_id(), food, "the cursor stays on its stack when another one arrives")
	assert_true(await _wait(func() -> bool: return _hud(view).contains("  %s x2" % water_name)), "the new stack is listed (%s)" % _hud(view))
	assert_true(await _wait(func() -> bool: return view.pickup_candidate_id().is_empty()), "nothing else lies in reach")
	assert_contains(_hud(view), "줍기 [E]: 가까이에 없음")

	# --- the cursor keys walk the stacks and wrap.
	await _press(ClientInputActions.SELECT_NEXT)
	assert_eq(view.selected_item_id(), water, "next")
	assert_contains(_hud(view), "> %s x2" % water_name)
	assert_contains(_hud(view), "  %s x3" % food_name)
	await _press(ClientInputActions.SELECT_NEXT)
	assert_eq(view.selected_item_id(), food, "after the last comes the first")
	await _press(ClientInputActions.SELECT_PREVIOUS)
	assert_eq(view.selected_item_id(), water, "before the first comes the last")

	# --- the drop key puts ONE unit of the selected stack down.
	await _press(ClientInputActions.DROP)
	assert_true(await _wait(func() -> bool: return _server_rows(viewer_id) == [[FOOD, 3], [WATER, 1]]), "server: one unit of the selected stack was put down (%s)" % str(_server_rows(viewer_id)))
	assert_true(await _wait(func() -> bool: return _markers(view).get_child_count() == 2), "the unit has a marker")
	var lying_ids: PackedStringArray = _world.inventory.world_item_ids()
	lying_ids.remove_at(lying_ids.find(far))
	assert_eq(lying_ids.size(), 1)
	var unit: String = lying_ids[0]
	assert_eq(_marker_text(view, unit), "%s x1" % water_name)
	assert_true(await _wait(func() -> bool: return _hud(view).contains("> %s x1" % water_name)), "the HUD shows the smaller stack (%s)" % _hud(view))
	assert_true(await _wait(func() -> bool: return _notice(view) == "내려놓기 승인"), "the drop result is shown (%s)" % _notice(view))
	assert_eq(view.selected_item_id(), water, "the cursor stays on the stack")

	# --- with the stack modifier held the whole selected stack goes down.
	await _press(ClientInputActions.SELECT_NEXT)
	assert_eq(view.selected_item_id(), food)
	await _pause(presentation.drop_min_interval_sec + 0.1)
	_hold(ClientInputActions.DROP_STACK)
	await _press(ClientInputActions.DROP)
	_release(ClientInputActions.DROP_STACK)
	assert_true(await _wait(func() -> bool: return _server_rows(viewer_id) == [[WATER, 1]]), "server: the whole selected stack was put down (%s)" % str(_server_rows(viewer_id)))
	assert_true(await _wait(func() -> bool: return _marker_text(view, food) == "%s x3" % food_name), "the stack lies there under its own id")
	assert_true(await _wait(func() -> bool: return view.selected_item_id() == water), "the cursor moved to the stack that is left")
	assert_eq(_markers(view).get_child_count(), 3)

	# --- another player picks one of them up: its marker goes away here too.
	var b: NetworkService = await _cluster.join_client("bob")
	assert_not_null(b)
	if b == null:
		return
	b.request_pickup(unit)
	assert_true(await _wait(func() -> bool: return _markers(view).get_node_or_null(WorldItemMarkers.MARKER_PREFIX + unit) == null), "an item somebody else picked up has no marker")
	assert_eq(_server_rows(viewer_id), [[WATER, 1]], "nothing arrived in the viewer's inventory")

	# --- nothing in reach: the pickup key sends nothing and says so.
	_world.get_player(viewer_id).position = NOWHERE
	assert_true(await _wait(func() -> bool: return view.pickup_candidate_id().is_empty()), "nothing lies in reach over there")
	var pickups: Array[Array] = []
	network.pickup_result.connect(func(request_id: int, ok: bool, reason: String) -> void: pickups.append([request_id, ok, reason]))
	await _press(ClientInputActions.PICKUP)
	assert_true(await _wait(func() -> bool: return _notice(view) == ClientPresentationFormatter.nothing_to_pick_up_text()), "a local notice (%s)" % _notice(view))
	await _settle()
	assert_eq(pickups.size(), 0, "no pickup request was sent")
	assert_eq(_cluster.server.rejected_intent_count(InventoryService.REASON_TOO_FAR), 0, "the server never had to refuse a pickup as too far")
