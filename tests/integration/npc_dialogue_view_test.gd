extends TestCase
## F-31 client view (docs/09 §17.16) in a real (headless) client session:
## GameBootstrap with its ClientView against a real server.
##   - the panel names whom the talk key would ask;
##   - the talk key, a number key and the end key are driven through the
##     real input actions (Input.action_press), so the input branch of
##     ClientView is covered: the NPC's line and the numbered answers show,
##     a number key answers, the end key ends, and the last line stays for a
##     moment;
##   - the NPC's name tag shows its reaction ("대화 중" while it talks);
##   - an NPC that will not talk shows its line and why.
## What a real window shows cannot be checked here.

const WORLD: String = "npc_dialogue_view_test_world"
const WAIT_MSEC: int = 8000
const SETTLE_TICKS: int = 20
## The player spawns at the origin.
const NEAR: Vector3 = Vector3(0.0, 0.0, -1.5)
const NEARER: Vector3 = Vector3(0.0, 0.0, 1.0)
const FRIENDLY: String = "f31_view_friendly"
const TIMID: String = "f31_view_timid"
const FRIENDLY_NAME: String = "말 잘 받는 사람"
const TIMID_NAME: String = "겁 많은 사람"
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _session_root: Node = null
var _held_actions: Array[StringName] = []
var _presentation: ClientPresentationSettings = null
var _key_pause_sec: float = 0.4


func before_each() -> void:
	GameLogger.set_capture(true)
	_cluster = null
	_session_root = null
	_world = null
	_held_actions = []
	_presentation = ClientPresentationSettings.load_or_default()
	# Longer than the client's flood guard between two talk keys.
	_key_pause_sec = _presentation.npc_talk_min_interval_sec + 0.1


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


func _definition(definition_id: String, display_name: String, nature: float) -> NpcDefinition:
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = definition_id
	definition.display_name = display_name
	definition.appearance = _config.appearance.default_selection()
	definition.extraversion = nature
	definition.agreeableness = nature
	definition.courage = nature
	definition.risk_tolerance = nature
	definition.neuroticism = 1.0 - nature
	return definition


## NPCs that stand still (no behaviour layer), the shipped lines.
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
	_config.npc = NpcSettings.new()
	_config.npc_definitions = NpcCatalog.new()
	_config.npc_definitions.add(_definition(FRIENDLY, FRIENDLY_NAME, 1.0))
	_config.npc_definitions.add(_definition(TIMID, TIMID_NAME, 0.0))
	_config.npc_behaviour = null
	_config.npc_health = null
	_config.npc_social = NpcSocialSettings.new()
	_config.npc_social.refuse_fear = 0.3
	_config.npc_dialogue_net = NpcDialogueNetSettings.new()
	_config.npc_dialogue_net.dialogue_intent_rate_per_sec = GENEROUS_RATE
	_config.npc_dialogue_net.dialogue_intent_burst = GENEROUS_BURST
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
	bootstrap.name = "NpcDialogueViewSession_%d" % Time.get_ticks_usec()
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


func _pause(seconds: float) -> void:
	await tree.create_timer(seconds).timeout


func _spawn(definition_id: String, position: Vector3) -> String:
	var npcs: NpcService = _world.get_system(NpcService.SYSTEM_ID) as NpcService
	var result: ActionResult = npcs.spawn_npc(_world, definition_id, position)
	if not result.ok:
		fail("test setup: NPC spawn refused: " + result.reason)
		return ""
	return str(result.event[NpcService.KEY_NPC_ID])


func _dialogue() -> NpcDialogue:
	return NpcSocial.of_world(_world).dialogue()


func _notice(view: ClientView) -> String:
	var label: Label = view.get_node("%ConsumeResultLabel") as Label
	return label.text if label.visible else ""


func _tag(view: ClientView, npc_id: String) -> String:
	var anchor: Node = (view.get_node("%Npcs") as Node3D).get_node_or_null(NpcVisuals.LABEL_PREFIX + npc_id)
	return (anchor.get_node(NpcVisuals.LABEL_NODE) as Label3D).text if anchor != null else "<no tag>"


# ------------------------------------------------------------ the view

func test_the_keys_talk_answer_and_end_and_the_panel_and_the_tag_follow() -> void:
	assert_true(_start_server(), "server started")
	var bootstrap: GameBootstrap = _start_session("viewer")
	if bootstrap == null:
		return
	var view: ClientView = bootstrap.get_client_view() as ClientView
	var network: NetworkService = bootstrap.get_network()
	assert_true(await _wait(func() -> bool: return not network.client_state.local_player_id.is_empty()), "the session joined")
	var viewer_id: String = network.client_state.local_player_id
	var talk_key: String = ClientPresentationFormatter.key_label(_presentation.npc_talk_key)
	var end_key: String = ClientPresentationFormatter.key_label(_presentation.npc_talk_end_key)
	var mirror: ClientDialogueState = (network.get_module(NpcDialogueNetModule.MODULE_NAME) as NpcDialogueNetModule).client_state
	# Nobody near: no panel, and the talk key says so without asking the server.
	await _settle()
	assert_eq(view.dialogue_panel_text(), "")
	assert_eq(view.talk_candidate_id(), "")
	await _press(ClientInputActions.NPC_TALK)
	assert_eq(_notice(view), NpcTalkPresentationFormatter.nobody_to_talk_to_text())
	assert_eq(_dialogue().started_count + _dialogue().refused_count, 0)
	await _pause(_key_pause_sec)

	# An NPC in reach: the panel names it.
	var npc_id: String = _spawn(FRIENDLY, NEAR)
	assert_true(await _wait(func() -> bool: return view.talk_candidate_id() == npc_id), "the NPC is the talk candidate")
	assert_true(await _wait(func() -> bool: return view.dialogue_panel_text() == "말 걸기 [%s]: %s" % [talk_key, FRIENDLY_NAME]), "the hint: " + view.dialogue_panel_text())
	assert_true(_tag(view, npc_id).begins_with(FRIENDLY_NAME), "its name tag: " + _tag(view, npc_id))
	assert_not_contains(_tag(view, npc_id), "대화 중")

	# The talk key: the NPC's line and the numbered answers.
	await _press(ClientInputActions.NPC_TALK)
	assert_true(await _wait(func() -> bool: return mirror.open), "the conversation opened")
	assert_eq(_dialogue().talker_of(npc_id), viewer_id)
	var lines: PackedStringArray = view.dialogue_panel_text().split("\n")
	assert_eq(lines[0], FRIENDLY_NAME)
	assert_eq(lines[1], "\"%s\"" % mirror.line)
	assert_eq(lines.size(), 2 + mirror.choices.size() + 1, "name, line, one row per answer, the keys")
	for index: int in mirror.choices.size():
		assert_eq(lines[2 + index], "%d. %s" % [index + 1, str(mirror.choices[index][1])])
	assert_contains(lines[lines.size() - 1], "[%s]" % end_key)
	assert_eq(str(mirror.choices[0][0]), NpcDialogue.CHOICE_GREET, "the first answer is the greeting")
	assert_true(await _wait(func() -> bool: return _tag(view, npc_id) == FRIENDLY_NAME + " [대화 중]"), "the name tag shows it talks: " + _tag(view, npc_id))
	# The talk key does nothing while a conversation is open.
	await _pause(_key_pause_sec)
	await _press(ClientInputActions.NPC_TALK)
	await _settle()
	assert_eq(mirror.turn, 1)

	# Number key 1: the greeting. The panel shows the next line.
	var first_line: String = mirror.line
	await _pause(_key_pause_sec)
	await _press(ClientInputActions.talk_choice_action(1))
	assert_true(await _wait(func() -> bool: return mirror.turn == 2), "the answer was taken")
	assert_eq(_dialogue().choice_count, 1)
	assert_true(await _wait(func() -> bool: return view.dialogue_panel_text().split("\n")[1] == "\"%s\"" % mirror.line), "the panel shows the new line")
	assert_ne(mirror.line, first_line)
	# A number without an answer asks nothing.
	await _pause(_key_pause_sec)
	await _press(ClientInputActions.talk_choice_action(9))
	assert_eq(_notice(view), NpcTalkPresentationFormatter.no_such_choice_text())
	await _settle()
	assert_eq(mirror.turn, 2)
	assert_eq(_dialogue().choice_count, 1)

	# The end key: the conversation is over; the tag goes back.
	await _pause(_key_pause_sec)
	await _press(ClientInputActions.NPC_TALK_END)
	assert_true(await _wait(func() -> bool: return not mirror.open), "the conversation ended")
	assert_eq(mirror.end_reason, NpcDialogue.END_PLAYER_LEFT)
	assert_eq(_dialogue().session_count(), 0)
	assert_true(await _wait(func() -> bool: return not _tag(view, npc_id).contains("대화 중")), "the tag no longer says it talks")
	# The last view stays for a moment (here: the name, nothing was said at
	# the end), then the hint comes back.
	assert_eq(view.dialogue_panel_text().split("\n")[0], FRIENDLY_NAME)
	assert_true(await _wait(func() -> bool: return view.dialogue_panel_text() == "말 걸기 [%s]: %s" % [talk_key, FRIENDLY_NAME], int(_presentation.npc_talk_closed_duration_sec * 1000.0) + WAIT_MSEC), "the hint is back: " + view.dialogue_panel_text())

	# An NPC that will not talk, nearer than the first: its line and why.
	var timid_id: String = _spawn(TIMID, NEARER)
	assert_true(await _wait(func() -> bool: return view.talk_candidate_id() == timid_id), "the nearer NPC is the candidate")
	await _pause(_key_pause_sec)
	await _press(ClientInputActions.NPC_TALK)
	assert_true(await _wait(func() -> bool: return mirror.npc_id == timid_id and mirror.end_reason == NpcDialogue.END_REFUSED), "it refused")
	assert_false(mirror.open)
	var refused: PackedStringArray = view.dialogue_panel_text().split("\n")
	assert_eq(refused, PackedStringArray([TIMID_NAME, "\"%s\"" % mirror.line, "(%s)" % NpcTalkPresentationFormatter.end_reason_text(NpcDialogue.END_REFUSED)]))
	await _settle()
	assert_not_contains(_tag(view, timid_id), "대화 중")
	assert_eq(mirror.rejected_payload_count, 0)
