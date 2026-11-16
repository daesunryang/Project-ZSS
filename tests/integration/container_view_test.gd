extends TestCase
## P3-3 client view (docs/09 §15.3, docs/11 §2.16) in a real (headless)
## client session: GameBootstrap with its ClientView against a real server.
##   - every container the client is told about has a marker with its name,
##     and "수색 전" until somebody searched it;
##   - the HUD names the container the open key would open, shows a running
##     search, and lists what is inside the open container with a cursor;
##   - the open key, the container cursor keys, the take key and the put key
##     (one unit / the whole stack with the modifier) are driven through the
##     real input actions (Input.action_press), so the input branch of
##     ClientView is covered.
## What a real window shows cannot be checked here (docs/15 §15.3).

const WORLD: String = "container_view_test_world"
const WAIT_MSEC: int = 8000
const SETTLE_TICKS: int = 20
const FOOD: String = "dev_food_ration"
const WATER: String = "dev_water_bottle"
const CABINET: String = "dev_cabinet"
const CRATE: String = "dev_crate"
const SEARCH_SEC: float = 0.6
## The player spawns at the origin: the cabinet is the nearest container in
## reach, the crate is out of reach until the player stands at BY_CRATE, the
## third container is far away.
const CABINET_AT: Vector3 = Vector3(1.5, 0.0, 0.0)
const CRATE_AT: Vector3 = Vector3(-4.0, 0.0, 0.0)
const BY_CRATE: Vector3 = Vector3(-3.0, 0.0, 0.0)
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


## The shipped definitions (a real client session has no others); the
## first search takes SEARCH_SEC.
func _start_server() -> bool:
	var net_settings: NetworkSettings = NetworkSettings.new()
	net_settings.autosave_interval_sec = 0.0
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.containers = ContainerSettings.new()
	_config.containers.search_duration_sec = SEARCH_SEC
	_config.container_net = ContainerNetSettings.new()
	_config.container_net.container_intent_rate_per_sec = GENEROUS_RATE
	_config.container_net.container_intent_burst = GENEROUS_BURST
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
	bootstrap.name = "ContainerViewSession_%d" % Time.get_ticks_usec()
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


func _containers() -> ContainerService:
	return _world.get_system(ContainerService.SYSTEM_ID) as ContainerService


func _markers(view: ClientView) -> Node3D:
	return view.get_node("%Containers") as Node3D


func _marker_text(view: ClientView, container_id: String) -> String:
	var label: Label3D = view.container_visual_label(container_id)
	return label.text if label != null else "<no marker>"


## The container block of the HUD ("" while it is hidden).
func _hud(view: ClientView) -> String:
	var label: Label = view.get_node("%ContainerLabel") as Label
	return label.text if label.visible else ""


func _notice(view: ClientView) -> String:
	var label: Label = view.get_node("%ConsumeResultLabel") as Label
	return label.text if label.visible else ""


## [definition, quantity] of what a container / a player holds on the server.
func _stored(container_id: String) -> Array:
	var rows: Array = []
	for entry: Dictionary in _containers().contents_of(container_id):
		rows.append([entry["definition_id"], entry["quantity"]])
	return rows


func _carried(player_id: String) -> Array:
	var rows: Array = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		rows.append([item.definition_id, item.quantity])
	return rows


func _create(definition_id: String, position: Vector3) -> String:
	var created: ActionResult = _containers().create_container(_world, definition_id, position)
	if not created.ok:
		fail("test setup: container refused: " + created.reason)
		return ""
	return str(created.event.get("container_id", ""))


# ------------------------------------------------------------ the view

func test_the_view_shows_containers_and_the_keys_search_take_and_put() -> void:
	assert_true(_start_server(), "server started")
	# The viewer exists and carries two stacks before its session joins. A
	# helper searched and emptied the crate, so what is in it later is only
	# what the viewer puts in.
	var viewer_state: PlayerState = _world.join("viewer")
	var carried_ids: Array[String] = []
	for stack: Array in [[FOOD, 3], [WATER, 2]]:
		var item_id: String = _world.inventory.spawn_world_item(str(stack[0]), int(stack[1]), _world.cell_id_at(Vector3.ZERO), Vector3.ZERO)
		assert_true(_world.try_pickup(viewer_state.player_id, item_id).ok)
		carried_ids.append(item_id)
	var cabinet_id: String = _create(CABINET, CABINET_AT)
	var crate_id: String = _create(CRATE, CRATE_AT)
	var far_id: String = _create(CRATE, FAR_AT)
	_world.leave(viewer_state.player_id)
	_config.containers.search_duration_sec = 0.0
	var helper: PlayerState = _world.join("helper")
	helper.position = BY_CRATE
	assert_true(_containers().try_open(_world, helper.player_id, crate_id).ok)
	for entry: Dictionary in _containers().contents_of(crate_id):
		assert_true(_containers().try_take(_world, helper.player_id, crate_id, str(entry["item_instance_id"]), InventoryService.WHOLE_STACK).ok)
	_world.leave(helper.player_id)
	_config.containers.search_duration_sec = SEARCH_SEC
	assert_eq(_stored(crate_id), [])

	var bootstrap: GameBootstrap = _start_session("viewer")
	if bootstrap == null:
		return
	var network: NetworkService = bootstrap.get_network()
	var view: ClientView = bootstrap.get_client_view() as ClientView
	assert_not_null(view)
	assert_true(await _wait(func() -> bool: return not network.client_state.local_player_id.is_empty()), "the session joined")
	var viewer_id: String = network.client_state.local_player_id
	var mirror: ClientContainerState = (network.get_module(ContainerNetModule.MODULE_NAME) as ContainerNetModule).client_state
	var definitions: ContainerCatalog = ContainerCatalog.load_directory()
	var items: ItemCatalog = ItemCatalog.load_directory()
	var cabinet_name: String = definitions.get_definition(CABINET).display_name
	var crate_name: String = definitions.get_definition(CRATE).display_name
	var food_name: String = items.get_definition(FOOD).display_name
	var water_name: String = items.get_definition(WATER).display_name
	var presentation: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	var guard: float = presentation.container_min_interval_sec + 0.1

	# --- every container has a marker with its name and its search state.
	assert_true(await _wait(func() -> bool: return ((_markers(view).get_node(ContainerMarkers.UNSEARCHED_BATCH_NODE) as MultiMeshInstance3D).multimesh.instance_count + (_markers(view).get_node(ContainerMarkers.SEARCHED_BATCH_NODE) as MultiMeshInstance3D).multimesh.instance_count) == 3), "three batched markers")
	assert_eq(_marker_text(view, cabinet_id), "%s (수색 전)" % cabinet_name)
	assert_eq(_marker_text(view, crate_id), crate_name, "a searched container says so")
	assert_eq(_marker_text(view, far_id), "<no marker>", "far container bodies have no Label3D")
	assert_eq(view.container_visual_transform(cabinet_id).origin, CABINET_AT + Vector3.UP * ClientPresentationSettings.new().container_marker_size_m * 0.5, "where the container stands")
	# --- the HUD names what the open key would open: the nearest in reach.
	assert_true(await _wait(func() -> bool: return view.container_candidate_id() == cabinet_id), "the nearest container in reach is the candidate (%s)" % view.container_candidate_id())
	assert_eq(_hud(view), "보관함 열기 [H]: %s (수색 전)" % cabinet_name)

	# --- the open key starts the search; the HUD shows it, then the content.
	await _press(ClientInputActions.CONTAINER_OPEN)
	assert_true(await _wait(func() -> bool: return mirror.phase() == ClientContainerState.PHASE_SEARCHING), "the search started")
	assert_true(await _wait(func() -> bool: return _hud(view).contains("%s 수색 중" % cabinet_name)), "the HUD shows the search (%s)" % _hud(view))
	assert_not_contains(_hud(view), " x", "and nothing about the content yet")
	assert_true(await _wait(func() -> bool: return mirror.phase() == ClientContainerState.PHASE_OPEN), "the search completed")
	var found: Array = _stored(cabinet_id)
	assert_true(await _wait(func() -> bool: return _hud(view).contains("%s (%d)" % [cabinet_name, found.size()])), "the HUD lists the content (%s)" % _hud(view))
	for row: Array in found:
		assert_contains(_hud(view), "%s x%d" % [items.get_definition(str(row[0])).display_name, int(row[1])])
	assert_true(await _wait(func() -> bool: return _marker_text(view, cabinet_id) == cabinet_name), "the marker shows that it was searched")
	# --- walking away closes it; the player is told why.
	_world.get_player(viewer_id).position = BY_CRATE
	assert_true(await _wait(func() -> bool: return mirror.phase() == ClientContainerState.PHASE_NONE), "out of reach: the server closed it")
	assert_true(await _wait(func() -> bool: return _notice(view) == ClientPresentationFormatter.format_container_closed(ContainerService.REASON_TOO_FAR)), "a notice says why (%s)" % _notice(view))
	assert_true(await _wait(func() -> bool: return view.container_candidate_id() == crate_id), "the crate is the candidate over here")
	assert_eq(_hud(view), "보관함 열기 [H]: %s" % crate_name)

	# --- a searched container opens at once; it is empty.
	await _pause(guard)
	await _press(ClientInputActions.CONTAINER_OPEN)
	assert_true(await _wait(func() -> bool: return mirror.phase() == ClientContainerState.PHASE_OPEN and mirror.open_container_id() == crate_id), "the crate is open")
	assert_true(await _wait(func() -> bool: return _hud(view).contains("%s (0)" % crate_name)), "the header (%s)" % _hud(view))
	assert_contains(_hud(view), "비어 있음")
	assert_eq(view.selected_container_item_id(), "", "nothing inside, nothing selected")
	# --- the put key puts ONE unit of the stack under the inventory cursor in.
	assert_eq(view.selected_item_id(), carried_ids[0], "the inventory cursor is on the food")
	await _pause(guard)
	await _press(ClientInputActions.CONTAINER_PUT)
	assert_true(await _wait(func() -> bool: return _stored(crate_id) == [[FOOD, 1]]), "server: one unit went in (%s)" % str(_stored(crate_id)))
	assert_eq(_carried(viewer_id), [[FOOD, 2], [WATER, 2]])
	assert_true(await _wait(func() -> bool: return _hud(view).contains("> %s x1" % food_name)), "the HUD lists it under the cursor (%s)" % _hud(view))
	# --- with the stack modifier held the whole selected stack goes in.
	await _press(ClientInputActions.SELECT_NEXT)
	assert_eq(view.selected_item_id(), carried_ids[1], "the inventory cursor is on the water")
	await _pause(guard)
	_hold(ClientInputActions.DROP_STACK)
	await _press(ClientInputActions.CONTAINER_PUT)
	_release(ClientInputActions.DROP_STACK)
	assert_true(await _wait(func() -> bool: return _stored(crate_id) == [[FOOD, 1], [WATER, 2]]), "server: the whole stack went in (%s)" % str(_stored(crate_id)))
	assert_eq(_carried(viewer_id), [[FOOD, 2]])
	assert_true(await _wait(func() -> bool: return _hud(view).contains("  %s x2" % water_name)), "the HUD lists the second stack (%s)" % _hud(view))
	assert_contains(_hud(view), "%s (2)" % crate_name)
	# --- the container cursor walks the stacks inside and wraps.
	var inside: Array[Dictionary] = _containers().contents_of(crate_id)
	var stored_food: String = str(inside[0]["item_instance_id"])
	var stored_water: String = str(inside[1]["item_instance_id"])
	assert_eq(view.selected_container_item_id(), stored_food)
	await _press(ClientInputActions.CONTAINER_NEXT)
	assert_eq(view.selected_container_item_id(), stored_water, "next")
	assert_contains(_hud(view), "> %s x2" % water_name)
	await _press(ClientInputActions.CONTAINER_NEXT)
	assert_eq(view.selected_container_item_id(), stored_food, "after the last comes the first")
	await _press(ClientInputActions.CONTAINER_PREVIOUS)
	assert_eq(view.selected_container_item_id(), stored_water, "before the first comes the last")
	# --- the take key takes ONE unit of the stack under the container cursor.
	await _pause(guard)
	await _press(ClientInputActions.CONTAINER_TAKE)
	assert_true(await _wait(func() -> bool: return _stored(crate_id) == [[FOOD, 1], [WATER, 1]]), "server: one unit came out (%s)" % str(_stored(crate_id)))
	assert_true(await _wait(func() -> bool: return _carried(viewer_id) == [[FOOD, 2], [WATER, 1]]), "and is carried (%s)" % str(_carried(viewer_id)))
	assert_true(await _wait(func() -> bool: return _hud(view).contains("> %s x1" % water_name)), "the HUD shows the smaller stack (%s)" % _hud(view))
	assert_eq(view.selected_container_item_id(), stored_water, "the cursor stays on its stack")
	# --- with the stack modifier held the whole stack comes out.
	await _pause(guard)
	_hold(ClientInputActions.DROP_STACK)
	await _press(ClientInputActions.CONTAINER_TAKE)
	_release(ClientInputActions.DROP_STACK)
	assert_true(await _wait(func() -> bool: return _stored(crate_id) == [[FOOD, 1]]), "server: the whole stack came out (%s)" % str(_stored(crate_id)))
	assert_true(await _wait(func() -> bool: return _carried(viewer_id) == [[FOOD, 2], [WATER, 2]]), "it joined the carried stack (%s)" % str(_carried(viewer_id)))
	assert_true(await _wait(func() -> bool: return view.selected_container_item_id() == stored_food), "the cursor moved to the stack that is left")
	assert_eq(_cluster.server.rejected_intent_count(), 0, "the server refused nothing")

	# --- the open key closes the open container.
	await _pause(guard)
	await _press(ClientInputActions.CONTAINER_OPEN)
	assert_true(await _wait(func() -> bool: return mirror.phase() == ClientContainerState.PHASE_NONE), "closed")
	assert_true(await _wait(func() -> bool: return _hud(view) == "보관함 열기 [H]: %s" % crate_name), "the HUD names the candidate again (%s)" % _hud(view))
	# --- nothing open: the take key sends nothing and says so.
	var results: Array[Array] = []
	(network.get_module(ContainerNetModule.MODULE_NAME) as ContainerNetModule).container_result.connect(func(request_id: int, ok: bool, reason: String) -> void: results.append([request_id, ok, reason]))
	await _pause(guard)
	await _press(ClientInputActions.CONTAINER_TAKE)
	assert_true(await _wait(func() -> bool: return _notice(view) == ClientPresentationFormatter.container_not_open_text()), "a local notice (%s)" % _notice(view))
	# --- nothing in reach: the block is hidden and the open key says so.
	_world.get_player(viewer_id).position = NOWHERE
	assert_true(await _wait(func() -> bool: return view.container_candidate_id().is_empty()), "no container in reach over there")
	assert_true(await _wait(func() -> bool: return _hud(view).is_empty()), "the block is hidden")
	await _pause(guard)
	await _press(ClientInputActions.CONTAINER_OPEN)
	assert_true(await _wait(func() -> bool: return _notice(view) == ClientPresentationFormatter.nothing_to_open_text()), "a local notice (%s)" % _notice(view))
	await _settle()
	assert_eq(results.size(), 0, "no request was sent for either")
	assert_eq(_cluster.server.rejected_intent_count(), 0)
	assert_eq(mirror.rejected_payload_count, 0)
	# The far container body is still shown; only its label has a range.
	assert_true(view.has_container_visual(far_id))
	assert_eq(_markers(view).get_child_count(), 2, "only the two body batches remain when every label is far")
