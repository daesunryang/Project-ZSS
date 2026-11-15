extends TestCase
## P2-T16 client view (docs/09 §14.30, docs/11 §2.14) in a real (headless)
## client session: GameBootstrap with its ClientView against a real server
## and a second client. The trade keys are driven through the real input
## actions (Input.action_press), so the input branch of ClientView is
## covered: asking the player the camera looks at, accepting, declining,
## putting the selected stack into the offer, confirming and cancelling, and
## the HUD block with both offers. What a real window shows cannot be
## checked here (docs/15 §14.7).

const WORLD: String = "trade_view_test_world"
const WAIT_MSEC: int = 8000
const SETTLE_TICKS: int = 20
const FOOD: String = "dev_food_ration"
const WATER: String = "dev_water_bottle"
const CELL: String = DevWorldSeed.DEV_CELL_ID
const FOOD_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const WATER_AT: Vector3 = Vector3(-0.5, 0.0, 1.5)
const FAR_AWAY: Vector3 = Vector3(40.0, 0.0, 40.0)
const GENEROUS_RATE: float = 120.0
const GENEROUS_BURST: int = 120

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _session_root: Node = null
var _held_actions: Array[StringName] = []
var _key_pause_sec: float = 0.3


func before_each() -> void:
	GameLogger.set_capture(true)
	_cluster = null
	_session_root = null
	_world = null
	_held_actions = []
	# Longer than the client's flood guard between two trade keys.
	_key_pause_sec = ClientPresentationSettings.load_or_default().trade_min_interval_sec + 0.1


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
	_config.trade = TradeSettings.new()
	_config.trade_net = TradeNetSettings.new()
	_config.trade_net.trade_intent_rate_per_sec = GENEROUS_RATE
	_config.trade_net.trade_intent_burst = GENEROUS_BURST
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
	bootstrap.name = "TradeViewSession_%d" % Time.get_ticks_usec()
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
## start of a physics frame, held for two frames, released. Then a pause
## longer than the view's flood guard, so the next key is not swallowed.
func _press(action: StringName) -> void:
	await tree.physics_frame
	Input.action_press(action)
	_held_actions.append(action)
	await tree.physics_frame
	await tree.physics_frame
	Input.action_release(action)
	_held_actions.erase(action)
	await tree.create_timer(_key_pause_sec).timeout


func _trade() -> TradeService:
	return _world.get_system(TradeService.SYSTEM_ID) as TradeService


func _module(service: NetworkService) -> TradeNetModule:
	return service.get_module(TradeNetModule.MODULE_NAME) as TradeNetModule


func _hud(view: ClientView) -> String:
	var label: Label = view.get_node("%TradeLabel") as Label
	return label.text if label.visible else "<hidden>"


func _notice(view: ClientView) -> String:
	var label: Label = view.get_node("%ConsumeResultLabel") as Label
	return label.text if label.visible else ""


func _event_log(view: ClientView) -> String:
	var label: Label = view.get_node("%EventLogLabel") as Label
	return label.text if label.visible else ""


## [definition, quantity] of what a player carries on the server, in slot order.
func _server_rows(player_id: String) -> Array:
	var rows: Array = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		rows.append([item.definition_id, item.quantity])
	return rows


## What a player offers in its session on the server: [definition, quantity].
func _server_offer(player_id: String) -> Array:
	var rows: Array = []
	var session: TradeSession = _trade().session_of(player_id)
	if session == null:
		return rows
	for entry: Dictionary in session.offers[player_id]:
		rows.append([entry[TradeSession.KEY_DEFINITION_ID], entry[TradeSession.KEY_QUANTITY]])
	return rows


# ------------------------------------------------------------ the view

func test_the_view_asks_offers_confirms_and_cancels_through_the_trade_keys() -> void:
	assert_true(_start_server(), "server started")
	var food: String = _world.inventory.spawn_world_item(FOOD, 3, CELL, FOOD_AT)
	var water: String = _world.inventory.spawn_world_item(WATER, 2, CELL, WATER_AT)
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
	# Nobody else is there yet.
	assert_true(await _wait(func() -> bool: return _hud(view) == "거래 요청 [T]: 상대 없음 (가까이서 바라보기)"), "nobody to ask (%s)" % _hud(view))
	await _press(ClientInputActions.TRADE_REQUEST)
	assert_eq(_notice(view), ClientPresentationFormatter.no_treat_target_text(), "a local notice, no request")
	assert_eq(_trade().session_count(), 0)

	# The viewer picks its food up; bob joins next to it and picks the water up.
	await _press(ClientInputActions.PICKUP)
	assert_true(await _wait(func() -> bool: return network.client_state.has_inventory_item(food)), "the viewer carries the food")
	var b: NetworkService = await _cluster.join_client("bob")
	assert_not_null(b)
	if b == null:
		return
	var bob_id: String = b.client_state.local_player_id
	b.request_pickup(water)
	assert_true(await _wait(func() -> bool: return b.client_state.has_inventory_item(water)), "bob carries the water")
	var bob_name: String = _world.get_player(bob_id).character.name
	assert_false(bob_name.is_empty())

	# --- the request key asks the player the camera looks at.
	assert_true(await _wait(func() -> bool: return _hud(view) == "거래 요청 [T]: %s" % bob_name), "bob is whom the request key would ask (%s)" % _hud(view))
	await _press(ClientInputActions.TRADE_REQUEST)
	assert_true(await _wait(func() -> bool: return _trade().session_of(viewer_id) != null), "the server has the request")
	var session: TradeSession = _trade().session_of(viewer_id)
	assert_eq(session.requester_id, viewer_id)
	assert_eq(session.target_id, bob_id, "only the looked-at player's id was sent")
	assert_true(await _wait(func() -> bool: return _hud(view) == "거래 요청 중: %s | 취소 [N]" % bob_name), "the HUD shows the pending request (%s)" % _hud(view))
	# The accept key does nothing to one's own request; a second request key neither.
	await _press(ClientInputActions.TRADE_ACCEPT)
	await _press(ClientInputActions.TRADE_REQUEST)
	assert_eq(session.phase, TradeSession.PHASE_REQUESTED)
	assert_eq(_cluster.server.rejected_intent_count(TradeService.REASON_ALREADY_TRADING) + _cluster.server.rejected_intent_count(TradeService.REASON_NO_SUCH_REQUEST), 0, "the view sent nothing the server had to refuse")
	_module(b).request_accept(session.session_id)
	assert_true(await _wait(func() -> bool: return _hud(view).begins_with("거래 중: %s" % bob_name)), "the HUD shows the open session (%s)" % _hud(view))
	assert_contains(_hud(view), "내 제안 (미확정): (없음)")
	assert_contains(_hud(view), "상대 제안 (미확정): (없음)")
	assert_contains(_hud(view), "올리기 [O] 내리기 [P] | 확정 [Y] | 거래 취소 [N]")

	# --- the offer keys put units of the stack under the cursor into the offer.
	assert_eq(view.selected_item_id(), food)
	await _press(ClientInputActions.TRADE_OFFER_ADD)
	assert_true(await _wait(func() -> bool: return _server_offer(viewer_id) == [[FOOD, 1]]), "one unit (%s)" % str(_server_offer(viewer_id)))
	await _press(ClientInputActions.TRADE_OFFER_ADD)
	await _press(ClientInputActions.TRADE_OFFER_ADD)
	assert_true(await _wait(func() -> bool: return _server_offer(viewer_id) == [[FOOD, 3]]), "one more per press (%s)" % str(_server_offer(viewer_id)))
	await _press(ClientInputActions.TRADE_OFFER_ADD)
	assert_eq(_server_offer(viewer_id), [[FOOD, 3]], "never more than the stack holds")
	await _press(ClientInputActions.TRADE_OFFER_REMOVE)
	assert_true(await _wait(func() -> bool: return _server_offer(viewer_id) == [[FOOD, 2]]), "one fewer (%s)" % str(_server_offer(viewer_id)))
	assert_true(await _wait(func() -> bool: return _hud(view).contains("내 제안 (미확정): %s x2" % food_name)), "the HUD shows the own offer (%s)" % _hud(view))
	_module(b).request_offer(session.session_id, water, 2)
	assert_true(await _wait(func() -> bool: return _hud(view).contains("상대 제안 (미확정): %s x2" % water_name)), "and the other side's (%s)" % _hud(view))
	assert_eq(_server_rows(viewer_id), [[FOOD, 3]], "an offer moves nothing")

	# --- the accept key confirms what the HUD shows, and takes it back.
	await _press(ClientInputActions.TRADE_ACCEPT)
	assert_true(await _wait(func() -> bool: return session.confirmed[viewer_id]), "confirmed with the revision the mirror shows")
	assert_true(await _wait(func() -> bool: return _hud(view).contains("내 제안 (확정)") and _hud(view).contains("확정 취소 [Y]")), "the HUD shows it (%s)" % _hud(view))
	await _press(ClientInputActions.TRADE_ACCEPT)
	assert_true(await _wait(func() -> bool: return not session.confirmed[viewer_id]), "pressed again: taken back")
	await _press(ClientInputActions.TRADE_ACCEPT)
	assert_true(await _wait(func() -> bool: return session.confirmed[viewer_id]))
	assert_eq(_server_rows(viewer_id), [[FOOD, 3]], "one confirmation moves nothing")
	_module(b).request_confirm(session.session_id, session.revision, true)
	assert_true(await _wait(func() -> bool: return _server_rows(viewer_id) == [[FOOD, 1], [WATER, 2]]), "the exchange happened (%s)" % str(_server_rows(viewer_id)))
	assert_eq(_server_rows(bob_id), [[FOOD, 2]])
	assert_true(await _wait(func() -> bool: return _notice(view) == "거래 완료: %s" % bob_name), "the result is shown (%s)" % _notice(view))
	assert_true(await _wait(func() -> bool: return _hud(view) == "거래 요청 [T]: %s" % bob_name), "the HUD is back to whom to ask (%s)" % _hud(view))
	assert_true(await _wait(func() -> bool: return network.client_state.inventory.size() == 2), "the viewer's inventory mirror has both stacks")

	# --- a request addressed to the viewer: the decline key declines it.
	_module(b).request_trade(viewer_id)
	assert_true(await _wait(func() -> bool: return _hud(view) == "%s의 거래 요청 | 수락 [Y] 거절 [N]" % bob_name), "the HUD shows who asks (%s)" % _hud(view))
	await _press(ClientInputActions.TRADE_DECLINE)
	assert_true(await _wait(func() -> bool: return _trade().session_of(viewer_id) == null), "declined")
	assert_true(await _wait(func() -> bool: return _notice(view) == "거래 요청을 거절했습니다"), "(%s)" % _notice(view))
	# --- asked again: the accept key accepts, the decline key then cancels.
	_module(b).request_trade(viewer_id)
	assert_true(await _wait(func() -> bool: return _hud(view).ends_with("수락 [Y] 거절 [N]")))
	await _press(ClientInputActions.TRADE_ACCEPT)
	assert_true(await _wait(func() -> bool: return _trade().session_of(viewer_id) != null and _trade().session_of(viewer_id).phase == TradeSession.PHASE_OPEN), "accepted")
	assert_true(await _wait(func() -> bool: return _hud(view).begins_with("거래 중: ")))
	await _press(ClientInputActions.TRADE_DECLINE)
	assert_true(await _wait(func() -> bool: return _trade().session_of(viewer_id) == null), "cancelled")
	assert_true(await _wait(func() -> bool: return _notice(view) == "거래를 취소했습니다"), "(%s)" % _notice(view))
	# --- the other side ends it: the viewer is told who and why.
	_module(b).request_trade(viewer_id)
	assert_true(await _wait(func() -> bool: return _hud(view).ends_with("수락 [Y] 거절 [N]")))
	_world.get_player(bob_id).position = FAR_AWAY
	assert_true(await _wait(func() -> bool: return _notice(view) == "거래 취소: 서로 너무 멀어졌습니다"), "(%s)" % _notice(view))
	assert_true(await _wait(func() -> bool: return _hud(view) == "거래 요청 [T]: 상대 없음 (가까이서 바라보기)"), "bob is out of reach (%s)" % _hud(view))

	# --- two other players trade: one line in the event log, nothing else.
	var c: NetworkService = await _cluster.join_client("carol")
	assert_not_null(c)
	if c == null:
		return
	var carol_id: String = c.client_state.local_player_id
	_world.get_player(carol_id).position = FAR_AWAY
	var bobs_food: String = _world.inventory.items_in_inventory(_world.get_player(bob_id).inventory_id)[0].item_instance_id
	_module(b).request_trade(carol_id)
	assert_true(await _wait(func() -> bool: return _trade().session_of(carol_id) != null))
	var other: TradeSession = _trade().session_of(carol_id)
	_module(c).request_accept(other.session_id)
	assert_true(await _wait(func() -> bool: return other.phase == TradeSession.PHASE_OPEN))
	_module(b).request_offer(other.session_id, bobs_food, 2)
	assert_true(await _wait(func() -> bool: return other.revision == 1))
	_module(b).request_confirm(other.session_id, 1, true)
	_module(c).request_confirm(other.session_id, 1, true)
	assert_true(await _wait(func() -> bool: return _server_rows(carol_id) == [[FOOD, 2]]), "bob gave carol his food")
	var carol_name: String = _world.get_player(carol_id).character.name
	assert_true(await _wait(func() -> bool: return _event_log(view).contains("거래")), "the viewer's event log has a line (%s)" % _event_log(view))
	var names: Array = [[bob_id, bob_name], [carol_id, carol_name]]
	names.sort_custom(func(left: Array, right: Array) -> bool: return str(left[0]) < str(right[0]))
	assert_contains(_event_log(view), "%s ↔ %s 거래" % [names[0][1], names[1][1]])
	assert_not_contains(_event_log(view), food_name, "what they traded is not shown: the viewer was never told")
	assert_true(await _wait(func() -> bool: return _hud(view) == "거래 요청 [T]: 상대 없음 (가까이서 바라보기)"), "and the viewer's own trade block shows no trade (%s)" % _hud(view))
	await _settle()
	assert_eq((network.get_module(TradeNetModule.MODULE_NAME) as TradeNetModule).client_state.rejected_payload_count, 0, "every server message passed the view's checks")
