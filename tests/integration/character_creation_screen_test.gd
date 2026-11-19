extends TestCase
## P2-T9 (docs/00 ADR-015): the character creation screen and the way the
## client shows characters, in a real (headless) SceneTree.
##   - the screen scene instantiates without errors and builds one row of
##     widgets per appearance slot from the data definitions;
##   - confirming emits the creation payload (name + selection), and a name
##     the rules refuse never leaves the screen;
##   - a real client session (GameBootstrap + ClientView) against a real
##     server: the screen opens after the join and after a death, game input
##     is off while it is open, and the capsule and the name tag follow the
##     created character.

const WORLD: String = "character_screen_test_world"
const WAIT_MSEC: int = 8000
const SETTLE_TICKS: int = 20
const LETHAL_DAMAGE: float = 100000.0
const DELAY_SEC: float = 0.5
const EPSILON: float = 0.0001

var _screen: CharacterCreationScreen = null
var _requests: Array[Array] = []
var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _session_root: Node = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_screen = null
	_requests = []
	_cluster = null
	_session_root = null
	_world = null


func after_each() -> void:
	if _screen != null and is_instance_valid(_screen):
		_screen.free()
	if _session_root != null and is_instance_valid(_session_root):
		var path: NodePath = _session_root.get_path()
		_session_root.free()
		tree.set_multiplayer(null, path)
	if _cluster != null:
		await _cluster.shutdown()
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _shipped_rules() -> CharacterRules:
	return CharacterRules.new(CharacterSettings.load_or_default(), AppearanceCatalog.load_directory())


## Instantiates the screen scene, adds it to the tree and sets it up.
func _open_screen(rules: CharacterRules) -> CharacterCreationScreen:
	var scene: PackedScene = load(CharacterCreationScreen.SCENE_PATH) as PackedScene
	if scene == null:
		fail("the creation screen scene does not load")
		return null
	_screen = scene.instantiate() as CharacterCreationScreen
	if _screen == null:
		fail("the scene root is not a CharacterCreationScreen")
		return null
	tree.root.add_child(_screen)
	_screen.setup(rules, 20261115)
	_screen.create_requested.connect(func(character_name: String, appearance: Dictionary) -> void: _requests.append([character_name, appearance]))
	return _screen


func _press(button: Variant) -> void:
	var control: BaseButton = button as BaseButton
	if control == null or control.disabled:
		fail("button missing or disabled")
		return
	control.pressed.emit()


func _press_action(action: StringName) -> void:
	await tree.physics_frame
	Input.action_press(action)
	await tree.physics_frame
	await tree.physics_frame
	Input.action_release(action)
	await tree.physics_frame


func _name_edit(screen: CharacterCreationScreen) -> LineEdit:
	return screen.get_node("%NameEdit") as LineEdit


func _error_label(screen: CharacterCreationScreen) -> Label:
	return screen.get_node("%ErrorLabel") as Label


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


# ------------------------------------------------------------ the screen alone

func test_the_screen_builds_one_row_per_appearance_slot_from_the_data() -> void:
	var rules: CharacterRules = _shipped_rules()
	var screen: CharacterCreationScreen = _open_screen(rules)
	if screen == null:
		return
	assert_false(screen.is_open(), "hidden until it is opened")
	assert_eq(Array(screen.slot_ids()), Array(rules.catalog.slot_ids()), "one row per slot, in the order of the data")
	assert_eq(screen.selection(), rules.catalog.default_selection())
	for slot: AppearanceSlot in rules.catalog.slots():
		var row: Control = screen.slot_row(slot.slot_id)
		assert_not_null(row, "row of %s" % slot.slot_id)
		if row == null:
			continue
		assert_eq((row.get_node("SlotName") as Label).text, slot.display_name, "the slot text comes from the data")
		assert_eq((row.get_node("Value") as Label).text, slot.get_option(slot.default_option_id).display_name, "the option text comes from the data")
		assert_true(row.get_node("Previous") is Button and row.get_node("Next") is Button)
		var swatch: ColorRect = row.get_node("Swatch") as ColorRect
		assert_eq(swatch.visible, slot.kind == AppearanceSlot.KIND_COLOR, "%s: a colour swatch only for colour slots" % slot.slot_id)
		if slot.kind == AppearanceSlot.KIND_COLOR:
			assert_eq(swatch.color, slot.get_option(slot.default_option_id).color)
	assert_eq(_name_edit(screen).max_length, rules.settings.name_max_length, "the field takes no more than a name may have")
	screen.open(true)
	assert_true(screen.is_open())
	assert_true(screen.visible)
	screen.close()
	assert_false(screen.visible)


func test_a_slot_added_to_the_data_appears_on_the_screen() -> void:
	var catalog: AppearanceCatalog = AppearanceCatalog.load_directory()
	var extra: AppearanceSlot = AppearanceSlot.new()
	extra.slot_id = "glasses"
	extra.display_name = "안경"
	extra.kind = AppearanceSlot.KIND_STYLE
	extra.sort_order = 45
	for option_id: String in ["none", "round", "square"]:
		var option: AppearanceOption = AppearanceOption.new()
		option.option_id = option_id
		option.display_name = "안경 " + option_id
		extra.options.append(option)
	extra.default_option_id = "none"
	assert_eq(catalog.add(extra), OK)
	var screen: CharacterCreationScreen = _open_screen(CharacterRules.new(CharacterSettings.new(), catalog))
	if screen == null:
		return
	assert_eq(screen.slot_ids().size(), 8)
	assert_eq(Array(screen.slot_ids()).find("glasses"), 4, "between hair style (40) and hair colour (50)")
	var row: Control = screen.slot_row("glasses")
	assert_not_null(row)
	assert_eq((row.get_node("SlotName") as Label).text, "안경")
	_press(row.get_node("Next"))
	assert_eq(screen.selection()["glasses"], "round")
	assert_eq((row.get_node("Value") as Label).text, "안경 round")
	screen.open(true)
	_name_edit(screen).text = "Rick Grimes"
	_press(screen.get_node("%ConfirmButton"))
	assert_eq(_requests.size(), 1)
	assert_eq((_requests[0][1] as Dictionary).get("glasses", ""), "round", "the new slot is part of the payload")


func test_previous_next_and_random_change_the_selection() -> void:
	var rules: CharacterRules = _shipped_rules()
	var screen: CharacterCreationScreen = _open_screen(rules)
	if screen == null:
		return
	var slot: AppearanceSlot = rules.catalog.get_slot("top_color")
	var row: Control = screen.slot_row("top_color")
	var start: int = slot.index_of(slot.default_option_id)
	_press(row.get_node("Next"))
	var next: AppearanceOption = slot.options[(start + 1) % slot.options.size()]
	assert_eq(screen.selection()["top_color"], next.option_id)
	assert_eq((row.get_node("Value") as Label).text, next.display_name)
	assert_eq((row.get_node("Swatch") as ColorRect).color, next.color)
	_press(row.get_node("Previous"))
	_press(row.get_node("Previous"))
	var previous: AppearanceOption = slot.options[(start - 1 + slot.options.size()) % slot.options.size()]
	assert_eq(screen.selection()["top_color"], previous.option_id)
	# Walking a whole slot comes back to where it started.
	for step: int in range(slot.options.size()):
		_press(row.get_node("Next"))
	assert_eq(screen.selection()["top_color"], previous.option_id)
	# The random button: always a valid selection, and the rows follow it.
	var seen: Dictionary = {}
	for round_index: int in range(20):
		_press(screen.get_node("%RandomButton"))
		var selection: Dictionary = screen.selection()
		if not rules.catalog.is_complete_selection(selection):
			fail("the random button gave an invalid selection: %s" % str(selection))
			return
		seen[str(selection)] = true
		for slot_id: String in rules.catalog.slot_ids():
			var shown: String = (screen.slot_row(slot_id).get_node("Value") as Label).text
			assert_eq(shown, rules.catalog.get_slot(slot_id).get_option(selection[slot_id]).display_name, "row %s follows the model" % slot_id)
	assert_true(seen.size() > 5, "the random button gives different looks")
	assert_eq(_requests.size(), 0, "changing the look sends nothing")


func test_confirming_emits_the_creation_payload() -> void:
	var rules: CharacterRules = _shipped_rules()
	var screen: CharacterCreationScreen = _open_screen(rules)
	if screen == null:
		return
	screen.open(true)
	_press(screen.slot_row("hair_style").get_node("Next"))
	_press(screen.slot_row("height").get_node("Previous"))
	var expected: Dictionary = screen.selection()
	assert_ne(expected, rules.catalog.default_selection())
	_name_edit(screen).text = "  김   철수 "
	_press(screen.get_node("%ConfirmButton"))
	assert_eq(_requests.size(), 1, "one request")
	assert_eq(_requests[0][0], "김 철수", "the cleaned name")
	assert_eq(_requests[0][1], expected, "every slot with the chosen option")
	assert_true(rules.catalog.is_complete_selection(_requests[0][1]))
	assert_true(rules.check_request(_requests[0][0], _requests[0][1]).ok, "what leaves the screen passes the server's rules")
	# While the answer is pending nothing more is sent.
	assert_true(screen.is_busy())
	assert_true((screen.get_node("%ConfirmButton") as Button).disabled)
	_name_edit(screen).text_submitted.emit("김 철수")
	assert_eq(_requests.size(), 1)
	# The payload is a copy: later clicks do not change what was sent.
	screen.show_server_reason("")
	_press(screen.slot_row("hair_style").get_node("Next"))
	assert_eq(_requests[0][1], expected)
	# Enter in the name field confirms too.
	_name_edit(screen).text_submitted.emit(_name_edit(screen).text)
	assert_eq(_requests.size(), 2)


func test_a_name_the_rules_refuse_never_leaves_the_screen() -> void:
	var rules: CharacterRules = _shipped_rules()
	var screen: CharacterCreationScreen = _open_screen(rules)
	if screen == null:
		return
	screen.open(true)
	assert_eq(_error_label(screen).text, "", "no message at first")
	for bad: String in ["", "a", "al!ce", "<script>"]:
		_name_edit(screen).text = bad
		_press(screen.get_node("%ConfirmButton"))
		assert_eq(_requests.size(), 0, "not sent: '%s'" % bad)
		assert_false(_error_label(screen).text.is_empty(), "the player is told why: '%s'" % bad)
		assert_false(screen.is_busy())
	assert_eq(_error_label(screen).text, ClientPresentationFormatter.format_creation_reason(CharacterNameRules.REASON_BAD_CHARACTERS, rules.settings))
	# A good name clears the message and goes out.
	_name_edit(screen).text = "Rick Grimes"
	_press(screen.get_node("%ConfirmButton"))
	assert_eq(_requests.size(), 1)
	assert_eq(_error_label(screen).text, "")


func test_the_screen_shows_the_reason_the_server_gives() -> void:
	var rules: CharacterRules = _shipped_rules()
	var screen: CharacterCreationScreen = _open_screen(rules)
	if screen == null:
		return
	screen.open(false)
	_name_edit(screen).text = "Rick Grimes"
	_press(screen.get_node("%ConfirmButton"))
	assert_true(screen.is_busy())
	screen.show_server_reason(ServerWorld.REASON_NAME_TAKEN)
	assert_false(screen.is_busy(), "the player can try again")
	assert_false((screen.get_node("%ConfirmButton") as Button).disabled)
	assert_eq(_error_label(screen).text, ClientPresentationFormatter.format_creation_reason(ServerWorld.REASON_NAME_TAKEN, rules.settings))
	assert_eq(_name_edit(screen).text, "Rick Grimes", "what was typed stays")
	screen.show_server_reason("some_future_code")
	assert_contains(_error_label(screen).text, "some_future_code")
	# Reopening starts clean but keeps the name and the look of last time.
	_press(screen.slot_row("top_color").get_node("Next"))
	var look: Dictionary = screen.selection()
	screen.close()
	screen.open(false)
	assert_eq(_error_label(screen).text, "")
	assert_false(screen.is_busy())
	assert_eq(screen.selection(), look)
	assert_eq(_name_edit(screen).text, "Rick Grimes")


# ------------------------------------------------------------ a real client session

func _start_server() -> bool:
	var net_settings: NetworkSettings = NetworkSettings.new()
	net_settings.autosave_interval_sec = 0.0
	_config = CompositionConfig.from_defaults()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.respawn_delay_sec = DELAY_SEC
	_config.survival_net = SurvivalNetSettings.new()
	_config.survival_net.owner_snapshot_rate_hz = 20.0
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.character = CharacterSettings.new()
	_config.character.create_intent_rate_per_sec = 60.0
	_config.character.create_intent_burst = 60
	_config.require_character_creation = true
	_cluster = NetTestCluster.new(tree, net_settings, _config)
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


## Starts a real client session (GameBootstrap with its ClientView) that
## connects to the test server. Its multiplayer root is the bootstrap node,
## so the NetworkService RPC path equals the server's.
func _start_session(player_key: String, extra_args: PackedStringArray = PackedStringArray()) -> GameBootstrap:
	var bootstrap: GameBootstrap = GameBootstrap.new()
	bootstrap.name = "ScreenTestSession_%d" % Time.get_ticks_usec()
	_session_root = bootstrap
	tree.root.add_child(bootstrap)
	tree.set_multiplayer(SceneMultiplayer.new(), bootstrap.get_path())
	var args: PackedStringArray = PackedStringArray(["--client", "--connect=%s:%d" % [NetTestCluster.HOST, _cluster.port], "--player-key=" + player_key])
	args.append_array(extra_args)
	var launch: LaunchConfig = LaunchConfig.parse(args, false)
	if not launch.errors.is_empty() or bootstrap.start(launch, AppSettings.load_or_default()) != OK:
		fail("the client session did not start: %s" % "; ".join(launch.errors))
		return null
	return bootstrap


func _kill(player_id: String) -> void:
	var survival: SurvivalService = _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	var result: ActionResult = survival.apply_damage(player_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE))
	if not result.ok:
		fail("test setup: kill failed: " + result.reason)


func _visual(view: ClientView, player_id: String) -> Node3D:
	return view.get_node("%Players").get_node_or_null("Player_" + player_id) as Node3D


func _tag_text(view: ClientView, player_id: String) -> String:
	var visual: Node3D = _visual(view, player_id)
	return (visual.get_node("NameTag") as Label3D).text if visual != null else "<no visual>"


func test_the_client_view_opens_the_screen_and_shows_the_created_character() -> void:
	assert_true(_start_server(), "server started")
	var bootstrap: GameBootstrap = _start_session("viewer")
	if bootstrap == null:
		return
	var network: NetworkService = bootstrap.get_network()
	var view: ClientView = bootstrap.get_client_view() as ClientView
	assert_not_null(view)
	assert_true(await _wait(func() -> bool: return not network.client_state.local_player_id.is_empty()), "the session joined")
	var viewer_id: String = network.client_state.local_player_id
	var screen: CharacterCreationScreen = view.get_node("%CharacterCreationScreen") as CharacterCreationScreen
	assert_not_null(screen)
	# No character yet: the screen opens and game input is off.
	assert_true(await _wait(func() -> bool: return screen.is_open()), "the creation screen opened after the join")
	assert_false(view.is_game_input_enabled(), "no move / attack input while the screen is open")
	assert_null(_visual(view, viewer_id), "no capsule without a character")
	assert_false(_world.is_online(viewer_id))
	assert_eq(Array(screen.slot_ids()), Array(_config.appearance.slot_ids()))

	# Another player with a character is shown with its name and look.
	var b: NetworkService = await _cluster.join_client("bob")
	assert_not_null(b)
	if b == null:
		return
	var bob_id: String = b.client_state.local_player_id
	(b.get_module(CharacterNetModule.MODULE_NAME) as CharacterNetModule).request_create_character("Bob", {"top_color": "green", "height": "very_short"})
	assert_true(await _wait(func() -> bool: return _visual(view, bob_id) != null and _tag_text(view, bob_id) == "Bob"), "bob's capsule carries his name (%s)" % _tag_text(view, bob_id))

	# Create the character through the screen's widgets.
	(screen.get_node("%NameEdit") as LineEdit).text = "View Tester"
	var top_slot: AppearanceSlot = _config.appearance.get_slot("top_color")
	while screen.selection()["top_color"] != "red":
		_press(screen.slot_row("top_color").get_node("Next"))
	while screen.selection()["height"] != "very_tall":
		_press(screen.slot_row("height").get_node("Next"))
	while screen.selection()["body_type"] != "heavy":
		_press(screen.slot_row("body_type").get_node("Next"))
	_press(screen.get_node("%ConfirmButton"))
	assert_true(await _wait(func() -> bool: return _world.has_character(viewer_id)), "the server created the character")
	var state: PlayerState = _world.get_player(viewer_id)
	assert_eq(state.character.name, "View Tester")
	assert_eq(state.character.appearance["top_color"], "red")
	assert_eq(state.character.appearance["height"], "very_tall")
	assert_true(await _wait(func() -> bool: return not screen.is_open()), "the screen closed after the server accepted")
	assert_true(view.is_game_input_enabled(), "game input is back")

	# The world shows it: capsule colour and size, name above the capsule.
	assert_true(await _wait(func() -> bool: return _visual(view, viewer_id) != null and _tag_text(view, viewer_id) == "View Tester"), "own capsule with the name (%s)" % _tag_text(view, viewer_id))
	var camera_settings: CameraSettings = CameraSettings.load_or_default()
	var expected: Dictionary = CharacterCapsuleLook.build(_config.appearance, state.character.appearance, camera_settings.capsule_radius_m, camera_settings.capsule_height_m, Color.BLACK)
	var body: MeshInstance3D = _visual(view, viewer_id).get_node("Body") as MeshInstance3D
	var mesh: CapsuleMesh = body.mesh as CapsuleMesh
	assert_true(absf(mesh.radius - float(expected[CharacterCapsuleLook.KEY_RADIUS])) < EPSILON, "body type -> radius")
	assert_true(absf(mesh.height - float(expected[CharacterCapsuleLook.KEY_HEIGHT])) < EPSILON, "height -> capsule height")
	assert_true(mesh.height > camera_settings.capsule_height_m and mesh.radius > camera_settings.capsule_radius_m)
	assert_eq((body.material_override as StandardMaterial3D).albedo_color, top_slot.get_option("red").color, "top colour -> capsule colour")
	var tag: Label3D = _visual(view, viewer_id).get_node("NameTag") as Label3D
	assert_true(tag.position.y > mesh.height, "the name is above the capsule")
	assert_eq(tag.billboard, BaseMaterial3D.BILLBOARD_ENABLED)
	# Bob's capsule is his own: another colour and a smaller size.
	var bob_body: MeshInstance3D = _visual(view, bob_id).get_node("Body") as MeshInstance3D
	assert_eq((bob_body.material_override as StandardMaterial3D).albedo_color, top_slot.get_option("green").color)
	assert_true((bob_body.mesh as CapsuleMesh).height < camera_settings.capsule_height_m)
	# Build mode fades only this client's private capsule material and name tag;
	# the remote player's presentation is untouched, and leaving restores both.
	var presentation: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	await _press_action(ClientInputActions.BUILD_MODE)
	var local_material: StandardMaterial3D = body.material_override as StandardMaterial3D
	var bob_material: StandardMaterial3D = bob_body.material_override as StandardMaterial3D
	assert_true(absf(local_material.albedo_color.a - presentation.build_mode_local_player_alpha) < EPSILON)
	assert_eq(local_material.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA)
	assert_true(absf(tag.modulate.a - presentation.build_mode_local_player_alpha) < EPSILON)
	assert_eq(bob_material.albedo_color.a, 1.0, "another player's capsule stays opaque")
	assert_eq((_visual(view, bob_id).get_node("NameTag") as Label3D).modulate.a, 1.0, "another player's name stays opaque")
	await _press_action(ClientInputActions.BUILD_MODE)
	local_material = body.material_override as StandardMaterial3D
	assert_eq(local_material.albedo_color.a, 1.0, "leaving build mode restores the capsule")
	assert_eq(local_material.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED)
	assert_eq(tag.modulate.a, 1.0, "leaving build mode restores the name tag")

	# Death: the capsule lies down in the dead colour and keeps its name; the
	# screen opens again once the server allows the next character.
	_kill(viewer_id)
	assert_true(await _wait(func() -> bool: return (body.material_override as StandardMaterial3D).albedo_color == presentation.dead_player_color), "the dead capsule is dark")
	assert_true(absf(body.rotation.x - presentation.dead_tilt_rad) < EPSILON, "and lies down")
	assert_eq(tag.text, "View Tester")
	assert_true(await _wait(func() -> bool: return screen.is_open()), "the creation screen opened after the death")
	assert_false(view.is_game_input_enabled())
	(screen.get_node("%NameEdit") as LineEdit).text = "Second Try"
	while screen.selection()["top_color"] != "yellow":
		_press(screen.slot_row("top_color").get_node("Next"))
	_press(screen.get_node("%ConfirmButton"))
	assert_true(await _wait(func() -> bool: return state.character_generation == 2 and not screen.is_open()), "the second character was created through the screen")
	assert_true(await _wait(func() -> bool: return _tag_text(view, viewer_id) == "Second Try"), "the name tag follows (%s)" % _tag_text(view, viewer_id))
	assert_true(await _wait(func() -> bool: return (body.material_override as StandardMaterial3D).albedo_color == top_slot.get_option("yellow").color), "the capsule has the new colour and stands")
	assert_true(absf(body.rotation.x) < EPSILON)
	# Bob leaves: his capsule and name go away.
	_cluster.remove_client(b)
	assert_true(await _wait(func() -> bool: return _visual(view, bob_id) == null), "bob's capsule is gone")


func test_a_session_started_with_a_character_name_needs_no_screen() -> void:
	assert_true(_start_server(), "server started")
	var bootstrap: GameBootstrap = _start_session("auto", PackedStringArray(["--character-name=Auto Annie"]))
	if bootstrap == null:
		return
	var network: NetworkService = bootstrap.get_network()
	var view: ClientView = bootstrap.get_client_view() as ClientView
	assert_true(await _wait(func() -> bool: return not network.client_state.local_player_id.is_empty()), "the session joined")
	var player_id: String = network.client_state.local_player_id
	assert_true(await _wait(func() -> bool: return _world.has_character(player_id)), "the character was created from the launch argument")
	assert_eq(_world.get_player(player_id).character.name, "Auto Annie")
	assert_eq(_world.get_player(player_id).character.appearance, _config.appearance.default_selection())
	await _settle()
	var screen: CharacterCreationScreen = view.get_node("%CharacterCreationScreen") as CharacterCreationScreen
	assert_false(screen.is_open(), "the screen never opened")
	assert_true(view.is_game_input_enabled())
	assert_true(await _wait(func() -> bool: return _tag_text(view, player_id) == "Auto Annie"), "the name is shown")
