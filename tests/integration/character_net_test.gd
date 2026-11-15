extends TestCase
## P2-T9 (docs/00 ADR-015): character name and appearance over real ENet
## (server + 2..3 clients). A player creates its character with a request;
## the server validates and stores it and every client sees the same name
## and appearance. Until a player has a character nobody else is told about
## it. After a death the player creates the next character itself. Also:
## manipulated requests, late joiners, saving and restarting, the client
## that creates without a screen, and the world that needs no creation.

const WORLD: String = "character_net_test_world"
const WAIT_MSEC: int = 8000
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const LETHAL_DAMAGE: float = 100000.0
## Long enough that a test can look at the dead character first.
const DELAY_SEC: float = 1.5
const FORGED_REQUEST_ID: int = 777
const ALICE_NAME: String = "Alice Kim"
const BOB_NAME: String = "김철수"
const ALICE_LOOK: Dictionary = {"top_color": "red", "hair_style": "ponytail", "height": "tall", "skin_tone": "tone_5"}
const BOB_LOOK: Dictionary = {"top_color": "navy", "body_type": "heavy"}

var _cluster: NetTestCluster = null
var _net_settings: NetworkSettings = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _save_root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_save_root = ""
	_net_settings = NetworkSettings.new()
	_net_settings.autosave_interval_sec = 0.0
	_net_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	_net_settings.pickup_intent_burst = GENEROUS_BURST
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.respawn_delay_sec = DELAY_SEC
	_config.survival_net = SurvivalNetSettings.new()
	_config.survival_net.owner_snapshot_rate_hz = 20.0
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.character = CharacterSettings.new()
	_config.character.create_intent_rate_per_sec = GENEROUS_RATE
	_config.character.create_intent_burst = GENEROUS_BURST
	# What a dedicated server runs: players create their characters.
	_config.require_character_creation = true
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	_world = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	if not _save_root.is_empty():
		SaveService.remove_tree(_save_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _start_server() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


func _join(player_key: String) -> NetworkService:
	var client: NetworkService = await _cluster.join_client(player_key)
	if client == null:
		fail("%s did not join" % player_key)
	return client


func _module(service: NetworkService) -> CharacterNetModule:
	return service.get_module(CharacterNetModule.MODULE_NAME) as CharacterNetModule


func _mirror(service: NetworkService) -> ClientCharacterState:
	return _module(service).client_state


func _vitals_mirror(service: NetworkService) -> ClientSurvivalState:
	return (service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule).client_state


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _full_look(overrides: Dictionary) -> Dictionary:
	var selection: Dictionary = _config.appearance.default_selection()
	selection.merge(overrides, true)
	return selection


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


## Lets the server run some ticks so anything still in flight arrives.
func _settle() -> void:
	for tick: int in range(SETTLE_TICKS):
		await tree.physics_frame


## Rows [request_id, ok, reason] of every creation result of `service`.
func _results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).create_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Sends one creation request and waits for its answer: [ok, reason].
func _create(client: NetworkService, character_name: String, look: Dictionary) -> Array:
	var rows: Array[Array] = _results_of(client)
	var request_id: int = _module(client).request_create_character(character_name, look)
	if request_id == CharacterNetModule.NO_REQUEST:
		fail("the creation request was not sent")
		return [false, "not_sent"]
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	if not answered:
		fail("the creation request was not answered")
		return [false, "no_answer"]
	if int(rows[0][0]) != request_id:
		fail("the answer carries another request id: %s" % str(rows[0]))
	return [rows[0][1], rows[0][2]]


func _kill(player_id: String) -> void:
	var result: ActionResult = _survival().apply_damage(player_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE))
	if not result.ok:
		fail("test setup: kill failed: " + result.reason)


## "" when `client` sees the character of `player_id` exactly as the server
## has it, otherwise what differs.
func _character_mismatch(client: NetworkService, player_id: String) -> String:
	var state: PlayerState = _world.get_player(player_id)
	var mirror: ClientCharacterState = _mirror(client)
	if state == null or not state.has_character():
		return "" if not mirror.has_character(player_id) else "the mirror has a character the server does not"
	if not mirror.has_character(player_id):
		return "the mirror has no character of %s" % player_id
	if mirror.character_name(player_id) != state.character.name:
		return "name %s vs %s" % [mirror.character_name(player_id), state.character.name]
	if mirror.appearance(player_id) != state.character.appearance:
		return "appearance %s vs %s" % [str(mirror.appearance(player_id)), str(state.character.appearance)]
	return ""


func _sees(client: NetworkService, player_id: String) -> bool:
	return client.client_state.players.has(player_id) and _mirror(client).has_character(player_id) and _vitals_mirror(client).has_player(player_id)


## True when nothing on `client` knows `player_id`.
func _knows_nothing_about(client: NetworkService, player_id: String) -> bool:
	return not client.client_state.players.has(player_id) and not _mirror(client).has_character(player_id) and not _vitals_mirror(client).has_player(player_id)


func _assert_everybody_sees(clients: Array, player_ids: Array, label: String) -> void:
	for client: NetworkService in clients:
		for player_id: String in player_ids:
			var ok: bool = await _wait(func() -> bool: return _sees(client, player_id) and _character_mismatch(client, player_id).is_empty())
			assert_true(ok, "%s: %s sees %s (%s)" % [label, client.client_state.local_player_id, player_id, _character_mismatch(client, player_id)])


# ------------------------------------------------------------ 1. creating the first character

func test_a_player_is_invisible_until_it_creates_its_character() -> void:
	assert_true(_start_server(), "server started")
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var b_joined: Array = []
	b.player_joined.connect(func(player_id: String) -> void: b_joined.append(player_id))
	var a_changes: Array = []
	_mirror(a).character_changed.connect(func(player_id: String) -> void: a_changes.append(player_id))
	await _settle()

	# Both are connected, neither is in the world.
	assert_eq(Array(_world.connected_player_ids()), [alice_id, bob_id])
	assert_eq(_world.online_player_ids().size(), 0)
	assert_true(_knows_nothing_about(a, alice_id) and _knows_nothing_about(a, bob_id), "alice sees nobody, not even herself")
	assert_true(_knows_nothing_about(b, alice_id) and _knows_nothing_about(b, bob_id), "bob sees nobody")
	assert_true(_mirror(a).can_create_character(), "alice is told she may create a character")
	assert_eq(_mirror(a).creation_block_reason(), "")
	assert_true(_mirror(b).can_create_character())
	assert_eq(_mirror(a).local_player_id, alice_id)

	# Bob creates his character: alice (still without one) sees him, and he
	# still does not see her.
	assert_eq(await _create(b, BOB_NAME, BOB_LOOK), [true, ""])
	await _assert_everybody_sees([a, b], [bob_id], "bob created")
	assert_eq(_world.get_player(bob_id).character.name, BOB_NAME)
	assert_eq(_world.get_player(bob_id).character.appearance, _full_look(BOB_LOOK))
	assert_eq(_mirror(a).character_name(bob_id), BOB_NAME)
	assert_eq(_mirror(a).appearance(bob_id), _full_look(BOB_LOOK))
	assert_eq(Array(_world.online_player_ids()), [bob_id])
	await _settle()
	assert_true(_knows_nothing_about(b, alice_id), "bob knows nothing about the player who has no character")
	assert_false(b_joined.has(alice_id), "bob was never told that alice joined")
	assert_true(_knows_nothing_about(a, alice_id), "alice is not in her own view of the world either")
	assert_false(_mirror(b).can_create_character(), "bob has a living character now")
	assert_eq(_mirror(b).creation_block_reason(), SurvivalService.REASON_CHARACTER_ALIVE)

	# Alice creates hers: the server, alice and bob agree.
	assert_eq(await _create(a, "  Alice   Kim ", ALICE_LOOK), [true, ""])
	await _assert_everybody_sees([a, b], [alice_id, bob_id], "alice created")
	var alice: PlayerState = _world.get_player(alice_id)
	assert_eq(alice.character.name, ALICE_NAME, "the server keeps the cleaned name")
	assert_eq(alice.character.appearance, _full_look(ALICE_LOOK))
	for client: NetworkService in [a, b]:
		assert_eq(_mirror(client).character_name(alice_id), ALICE_NAME)
		assert_eq(_mirror(client).appearance(alice_id), _full_look(ALICE_LOOK))
		assert_true(_vitals_mirror(client).is_alive(alice_id))
		assert_eq(client.client_state.position_of(alice_id), _config.gameplay.player_spawn_position)
	assert_true(b_joined.has(alice_id), "now bob is told that alice is there")
	assert_true(a_changes.has(alice_id) and a_changes.has(bob_id), "the mirror announces every character")
	assert_eq(Array(_mirror(a).player_ids()), [alice_id, bob_id])
	# The owner's own vitals arrive once the character exists.
	assert_true(await _wait(func() -> bool: return _vitals_mirror(a).health() == _config.survival.max_health), "alice has vitals")
	# The generation stays with the owner (docs/00 ADR-009).
	assert_eq(_mirror(a).character_generation(alice_id), 1)
	assert_eq(_mirror(b).character_generation(alice_id), 0, "bob is not told which character of alice this is")
	assert_eq(_mirror(b).character_generation(bob_id), 1)
	assert_eq(_cluster.server.rejected_intent_count(), 0, "nothing was refused on the way")


func test_a_late_joiner_gets_every_character_and_stays_invisible_itself() -> void:
	assert_true(_start_server(), "server started")
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	assert_eq(await _create(a, ALICE_NAME, ALICE_LOOK), [true, ""])
	assert_eq(await _create(b, BOB_NAME, BOB_LOOK), [true, ""])
	await _assert_everybody_sees([a, b], [alice_id, bob_id], "two characters")

	var c: NetworkService = await _join("carol")
	if c == null:
		return
	var carol_id: String = c.client_state.local_player_id
	# Straight from the join snapshot: no waiting for later messages.
	assert_eq(_mirror(c).character_name(alice_id), ALICE_NAME)
	assert_eq(_mirror(c).appearance(alice_id), _full_look(ALICE_LOOK))
	assert_eq(_mirror(c).character_name(bob_id), BOB_NAME)
	assert_eq(_mirror(c).appearance(bob_id), _full_look(BOB_LOOK))
	assert_true(c.client_state.players.has(alice_id) and c.client_state.players.has(bob_id))
	assert_true(_vitals_mirror(c).is_alive(alice_id) and _vitals_mirror(c).is_alive(bob_id), "the survival rows came without an own character")
	assert_false(_mirror(c).has_character(carol_id))
	assert_true(_mirror(c).can_create_character())
	await _settle()
	assert_true(_knows_nothing_about(a, carol_id) and _knows_nothing_about(b, carol_id), "nobody sees carol yet")
	# Carol leaves again without a character: still nobody hears of her.
	var left: Array = []
	a.player_left.connect(func(player_id: String) -> void: left.append(player_id))
	_cluster.remove_client(c)
	assert_true(await _wait(func() -> bool: return not _world.is_player_connected(carol_id)), "carol left")
	await _settle()
	assert_eq(left, [], "nobody was told that a player without a character left")
	# And comes back: same player, still without a character, then creates one.
	var c2: NetworkService = await _join("carol")
	if c2 == null:
		return
	assert_eq(c2.client_state.local_player_id, carol_id, "carol is the same player")
	assert_false(_world.has_character(carol_id))
	assert_eq(await _create(c2, "Carol", {}), [true, ""])
	await _assert_everybody_sees([a, b, c2], [alice_id, bob_id, carol_id], "carol created")
	assert_eq(_mirror(a).appearance(carol_id), _config.appearance.default_selection(), "an empty selection is the default look")


# ------------------------------------------------------------ 2. death and the next character

func test_after_a_death_the_player_creates_the_next_character() -> void:
	assert_true(_start_server(), "server started")
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	assert_eq(await _create(a, ALICE_NAME, ALICE_LOOK), [true, ""])
	assert_eq(await _create(b, BOB_NAME, BOB_LOOK), [true, ""])
	await _assert_everybody_sees([a, b], [alice_id, bob_id], "two characters")
	assert_true(await _wait(func() -> bool: return not _mirror(a).can_create_character()), "alice knows she has a character")

	_world.get_player(alice_id).position = Vector3(3.0, 0.0, -2.0)
	_kill(alice_id)
	assert_true(await _wait(func() -> bool: return not _vitals_mirror(a).is_alive(alice_id) and not _vitals_mirror(b).is_alive(alice_id)), "both see alice dead")
	# Too early: the server says so and nothing changes.
	assert_true(await _wait(func() -> bool: return _mirror(a).creation_block_reason() == SurvivalService.REASON_RESPAWN_WAIT), "alice is told to wait")
	assert_eq(await _create(a, "Second One", {}), [false, SurvivalService.REASON_RESPAWN_WAIT])
	assert_eq(_world.get_player(alice_id).character.name, ALICE_NAME)
	# The delay passes; the server tells alice (and nobody else) that she may.
	assert_true(await _wait(func() -> bool: return _mirror(a).can_create_character()), "alice may create the next character")
	assert_false(_mirror(b).can_create_character(), "bob's own state is unchanged")
	# Nothing starts by itself, however long she takes.
	await _wait(func() -> bool: return false, int(DELAY_SEC * 1000.0))
	assert_false(_survival().is_alive(alice_id), "still dead: no character was created")
	assert_eq(_world.get_player(alice_id).character_generation, 1)
	assert_eq(_mirror(b).character_name(alice_id), ALICE_NAME, "the dead character keeps its name")

	var second_look: Dictionary = {"top_color": "green", "hair_style": "bald", "hair_color": "white", "body_type": "slim"}
	assert_eq(await _create(a, "Second One", second_look), [true, ""])
	assert_true(await _wait(func() -> bool: return _vitals_mirror(a).is_alive(alice_id) and _vitals_mirror(b).is_alive(alice_id)), "both see alice alive again")
	await _assert_everybody_sees([a, b], [alice_id, bob_id], "second character")
	var alice: PlayerState = _world.get_player(alice_id)
	assert_eq(alice.character.name, "Second One")
	assert_eq(alice.character.appearance, _full_look(second_look))
	assert_eq(alice.character_generation, 2)
	assert_eq(alice.position, _config.gameplay.player_spawn_position)
	for client: NetworkService in [a, b]:
		assert_eq(_mirror(client).character_name(alice_id), "Second One", "the new name reached %s" % client.client_state.local_player_id)
		assert_eq(_mirror(client).appearance(alice_id), _full_look(second_look))
	assert_eq(_mirror(a).character_generation(alice_id), 2)
	assert_true(await _wait(func() -> bool: return _vitals_mirror(a).character_generation() == 2), "the survival mirror agrees")
	assert_eq(_mirror(b).character_generation(alice_id), 0)
	assert_true(await _wait(func() -> bool: return b.client_state.position_of(alice_id).distance_to(_config.gameplay.player_spawn_position) < 0.01), "bob sees her at the spawn point")
	assert_true(await _wait(func() -> bool: return not _mirror(a).can_create_character()), "and she cannot create another one")
	assert_eq(_mirror(a).creation_block_reason(), SurvivalService.REASON_CHARACTER_ALIVE)
	assert_eq(_mirror(b).character_name(bob_id), BOB_NAME, "bob is untouched")


# ------------------------------------------------------------ 3. manipulated requests

func test_manipulated_creation_requests_are_rejected_and_change_nothing() -> void:
	assert_true(_start_server(), "server started")
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var server: NetworkService = _cluster.server
	var module: CharacterNetModule = _module(a)
	var a_results: Array[Array] = _results_of(a)
	var before: Dictionary = _world.get_player(alice_id).to_dict()
	var huge_look: Dictionary = {}
	for index: int in range(5000):
		huge_look["slot_%d" % index] = "x"

	# [request id, name, appearance, expected reason, answered]
	var cases: Array[Array] = [
		[1, "x".repeat(_config.character.name_max_length + 1), {}, CharacterNameRules.REASON_TOO_LONG, true],
		[2, "x".repeat(100000), {}, CharacterNetModule.REASON_PAYLOAD_TOO_LARGE, true],
		[3, "al!ce", {}, CharacterNameRules.REASON_BAD_CHARACTERS, true],
		[4, "al\nice", {}, CharacterNameRules.REASON_BAD_CHARACTERS, true],
		[5, "<b>bold</b>", {}, CharacterNameRules.REASON_BAD_CHARACTERS, true],
		[6, "", {}, CharacterNameRules.REASON_EMPTY, true],
		[7, "a", {}, CharacterNameRules.REASON_TOO_SHORT, true],
		[8, "alice", {"top_color": "ultraviolet"}, AppearanceCatalog.REASON_UNKNOWN_OPTION, true],
		[9, "alice", {"tail": "long"}, AppearanceCatalog.REASON_UNKNOWN_SLOT, true],
		[10, "alice", huge_look, CharacterNetModule.REASON_PAYLOAD_TOO_LARGE, true],
		[11, 42, {}, IntentValidator.REASON_BAD_TYPE, true],
		[12, null, {}, IntentValidator.REASON_BAD_TYPE, true],
		[13, "alice", ["top_color", "red"], IntentValidator.REASON_BAD_TYPE, true],
		[14, "alice", "red", IntentValidator.REASON_BAD_TYPE, true],
		[15, "alice", {"top_color": Color.RED}, IntentValidator.REASON_BAD_TYPE, true],
		[16, "alice", {7: "red"}, IntentValidator.REASON_BAD_TYPE, true],
		[17, "alice", {"top_color": "r".repeat(5000)}, CharacterNetModule.REASON_PAYLOAD_TOO_LARGE, true],
		["x", "alice", {}, IntentValidator.REASON_BAD_TYPE, false],
		[4.0, "alice", {}, IntentValidator.REASON_BAD_TYPE, false],
		[-1, "alice", {}, IntentValidator.REASON_BAD_SEQUENCE, false],
	]
	var expected_results: Array = []
	var expected_counts: Dictionary = {}
	for row: Array in cases:
		module.send_raw_create_request(row[0], row[1], row[2])
		expected_counts[row[3]] = int(expected_counts.get(row[3], 0)) + 1
		if row[4]:
			expected_results.append([row[0], false, row[3]])
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == cases.size()), "every request was refused (%d of %d)" % [server.rejected_intent_count(), cases.size()])
	await _settle()
	assert_eq(a_results, expected_results, "answers go to usable request ids only, in order")
	for reason: String in expected_counts:
		assert_eq(server.rejected_intent_count(reason), expected_counts[reason], "rejection counter of %s" % reason)
	assert_eq(_world.get_player(alice_id).to_dict(), before, "alice is untouched")
	assert_false(_world.is_online(alice_id))
	assert_true(_knows_nothing_about(b, alice_id))

	# A request cannot name the player to create a character for: the handler
	# takes three arguments and the engine refuses a call with more (reported
	# as an engine error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_create_character.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, "Mallory", {}, bob_id)
	await _settle()
	Engine.print_error_messages = true
	assert_false(_world.has_character(bob_id), "bob got no character from alice's request")
	assert_eq(server.rejected_intent_count(), cases.size(), "the call the engine refused never reached the handler")

	# A living character cannot be replaced or changed.
	a_results.clear()
	assert_eq(await _create(a, ALICE_NAME, ALICE_LOOK), [true, ""])
	await _assert_everybody_sees([a, b], [alice_id], "alice created")
	a_results.clear()
	module.send_raw_create_request(30, "Other Name", {"top_color": "green"})
	module.send_raw_create_request(31, ALICE_NAME, {"top_color": "green"})
	assert_true(await _wait(func() -> bool: return a_results.size() == 2), "alice was answered")
	assert_eq(a_results, [[30, false, SurvivalService.REASON_CHARACTER_ALIVE], [31, false, SurvivalService.REASON_CHARACTER_ALIVE]])
	assert_eq(server.rejected_intent_count(SurvivalService.REASON_CHARACTER_ALIVE), 2)
	assert_eq(_world.get_player(alice_id).character.name, ALICE_NAME)
	assert_eq(_world.get_player(alice_id).character.appearance, _full_look(ALICE_LOOK))
	assert_eq(_world.get_player(alice_id).character_generation, 1)
	await _settle()
	assert_eq(_mirror(b).appearance(alice_id), _full_look(ALICE_LOOK), "bob's view did not change")

	# Forged server messages: a client cannot give anybody a name, tell a
	# client it may create, or answer a request. Real ENet path: the engine
	# refuses these (the sender is not the authority) and reports each as an
	# engine error, the expected outcome, so printing is off for this block.
	var b_results: Array[Array] = _results_of(b)
	var server_results: Array[Array] = _results_of(server)
	var forged_row: Dictionary = {"player_id": alice_id, "name": "Forged", "appearance": _full_look({}), "character_generation": 9}
	Engine.print_error_messages = false
	for target: int in [NetworkService.SERVER_PEER_ID, b.multiplayer.get_unique_id()]:
		module._rpc_character_rows.rpc_id(target, [forged_row])
		module._rpc_creation_state.rpc_id(target, false, SurvivalService.REASON_CHARACTER_ALIVE)
		module._rpc_create_result.rpc_id(target, FORGED_REQUEST_ID, true, "")
	await _settle()
	Engine.print_error_messages = true
	# Script-level guard, independent of the engine (sender id 0 here), and a
	# client never acts on a request addressed to it.
	_module(b)._rpc_character_rows([forged_row])
	_module(b)._rpc_creation_state(false, SurvivalService.REASON_CHARACTER_ALIVE)
	_module(b)._rpc_create_result(FORGED_REQUEST_ID, true, "")
	_module(b)._rpc_request_create_character(FORGED_REQUEST_ID, "Forged", {})
	await _settle()
	assert_eq(b_results.size() + server_results.size(), 0, "nothing forged was delivered")
	assert_eq(_mirror(b).character_name(alice_id), ALICE_NAME, "bob's mirror was not changed")
	assert_true(_mirror(b).can_create_character(), "bob's creation state is the server's (he has no character)")
	assert_false(_mirror(server).has_character(alice_id), "the server keeps no mirror")
	assert_eq(_world.get_player(alice_id).character.name, ALICE_NAME)
	assert_false(_world.has_character(bob_id))


func test_a_creation_request_before_the_join_is_rejected() -> void:
	assert_true(_start_server(), "server started")
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var results: Array[Array] = _results_of(stranger)
	var connected: bool = await _wait(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	assert_eq(_module(stranger).request_create_character("Mallory", {}), CharacterNetModule.NO_REQUEST, "the client API sends nothing before the join")
	_module(stranger).send_raw_create_request(1, "Mallory", {})
	assert_true(await _wait(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 1), "the server refused the request of a peer that has not joined")
	await _settle()
	assert_eq(_cluster.server.rejected_intent_count(), 1, "exactly the raw request reached the server")
	assert_eq(results.size(), 0, "an unjoined peer is told nothing")
	assert_eq(_world.known_player_count(), 0)


func test_a_creation_flood_is_rate_limited_per_peer() -> void:
	const BURST: int = 2
	const FLOOD: int = 6
	# One new token every 100 seconds: only the burst passes within the test.
	_config.character.create_intent_rate_per_sec = 0.01
	_config.character.create_intent_burst = BURST
	assert_true(_start_server(), "server started")
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var alice_id: String = a.client_state.local_player_id
	var a_results: Array[Array] = _results_of(a)
	var requests: Array = []
	# Bad names first, so a refused request cannot be mistaken for a created character.
	for index: int in range(FLOOD):
		requests.append(_module(a).request_create_character("!", {}))
	assert_true(await _wait(func() -> bool: return a_results.size() == FLOOD), "every request was answered (%d)" % a_results.size())
	await _settle()
	var expected: Array = []
	for index: int in range(FLOOD):
		expected.append([requests[index], false, CharacterNameRules.REASON_TOO_SHORT if index < BURST else NetworkService.RATE_LIMITED])
	assert_eq(a_results, expected, "only the burst reaches the rules")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST, "rejection counter")
	assert_eq(await _create(a, ALICE_NAME, {}), [false, NetworkService.RATE_LIMITED], "a good request is limited too")
	assert_false(_world.has_character(alice_id))
	# The bucket is per peer: bob can still create.
	assert_eq(await _create(b, BOB_NAME, {}), [true, ""])


func test_a_player_without_a_character_cannot_act_over_the_network() -> void:
	assert_true(_start_server(), "server started")
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	assert_eq(await _create(b, BOB_NAME, {}), [true, ""])
	var server: NetworkService = _cluster.server
	var item_id: String = _world.inventory.spawn_world_item("dev_test_item", 1, DevWorldSeed.DEV_CELL_ID, _config.gameplay.player_spawn_position)
	var pickups: Array[Array] = []
	a.pickup_result.connect(func(request_id: int, ok: bool, reason: String) -> void: pickups.append([request_id, ok, reason]))
	var melee: Array[Array] = []
	var combat: CombatNetModule = a.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule
	combat.melee_result.connect(func(request_id: int, ok: bool, reason: String) -> void: melee.append([request_id, ok, reason]))
	var rests: Array[Array] = []
	var survival_net: SurvivalNetModule = a.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule
	survival_net.rest_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rests.append([request_id, ok, reason]))
	var before: Vector3 = _world.get_player(alice_id).position
	for tick: int in range(20):
		a.send_move_intent(Vector2(1.0, 0.0), 0.0)
		await tree.physics_frame
	var inventory_net: InventoryNetModule = a.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	var drops: Array[Array] = []
	inventory_net.drop_result.connect(func(request_id: int, ok: bool, reason: String) -> void: drops.append([request_id, ok, reason]))
	var consumes: Array[Array] = []
	inventory_net.consume_result.connect(func(request_id: int, ok: bool, reason: String) -> void: consumes.append([request_id, ok, reason]))
	a.request_pickup(item_id)
	combat.request_melee_attack(0.0)
	survival_net.request_rest(true)
	inventory_net.request_drop(item_id)
	inventory_net.request_consume(item_id)
	assert_true(await _wait(func() -> bool: return pickups.size() == 1 and melee.size() == 1 and rests.size() == 1 and drops.size() == 1 and consumes.size() == 1), "every request was answered")
	assert_eq(pickups[0].slice(1), [false, ServerWorld.REASON_NOT_ONLINE])
	assert_eq(melee[0].slice(1), [false, ServerWorld.REASON_NOT_ONLINE])
	assert_eq(drops[0].slice(1), [false, ServerWorld.REASON_NOT_ONLINE])
	assert_eq(consumes[0].slice(1), [false, ServerWorld.REASON_NOT_ONLINE])
	assert_eq(rests[0][1], false, "no lying down without a character")
	assert_eq(_world.get_player(alice_id).position, before, "the move intents moved nothing")
	assert_true(server.rejected_intent_count(ServerWorld.REASON_NOT_ONLINE) >= 20, "move intents were refused (%d)" % server.rejected_intent_count(ServerWorld.REASON_NOT_ONLINE))
	assert_false(_survival().has_player(alice_id))
	assert_eq(_world.inventory.get_item(item_id).location_type, ItemInstance.LOCATION_WORLD)
	await _settle()
	assert_true(_knows_nothing_about(b, alice_id), "bob still sees nothing of alice")
	assert_false(b.client_state.players.has(alice_id), "no position row of alice was broadcast")
	# With a character the same client moves.
	assert_eq(await _create(a, ALICE_NAME, {}), [true, ""])
	for tick: int in range(30):
		a.send_move_intent(Vector2(1.0, 0.0), 0.0)
		await tree.physics_frame
	assert_true(_world.get_player(alice_id).position.x > before.x, "alice walks")
	assert_true(await _wait(func() -> bool: return b.client_state.position_of(alice_id).x > before.x), "and bob sees her walk")
	assert_true(_world.is_online(bob_id))


# ------------------------------------------------------------ 4. saving and restarting

func test_characters_survive_a_server_restart() -> void:
	_save_root = "user://test_saves/character_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	var c: NetworkService = await _join("carol")
	if a == null or b == null or c == null:
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var carol_id: String = c.client_state.local_player_id
	var save: SaveService = SaveService.new(_save_root)
	var generation: int = save.current_generation(WORLD)
	assert_eq(await _create(a, ALICE_NAME, ALICE_LOOK), [true, ""])
	# A created character is saved at once.
	assert_true(save.current_generation(WORLD) > generation, "the creation wrote the world")
	var saved: Dictionary = save.load_world(WORLD)
	assert_eq(saved["error"], OK)
	var saved_alice: Dictionary = (saved["players"] as Dictionary)[alice_id]
	assert_eq(saved_alice[PlayerState.KEY_CHARACTER], {"name": ALICE_NAME, "appearance": _full_look(ALICE_LOOK)}, "name and appearance are in the player file")
	assert_null(((saved["players"] as Dictionary)[bob_id] as Dictionary)[PlayerState.KEY_CHARACTER], "bob has none yet")
	assert_eq(await _create(b, BOB_NAME, BOB_LOOK), [true, ""])
	# Alice dies and creates her second character; carol never creates one.
	_kill(alice_id)
	assert_true(await _wait(func() -> bool: return _mirror(a).can_create_character()), "alice may create the next character")
	var second_look: Dictionary = {"top_color": "purple", "height": "very_short"}
	assert_eq(await _create(a, "Second One", second_look), [true, ""])
	assert_eq(_world.get_player(alice_id).character_generation, 2)

	# --- full restart: the clients quit, then the server saves and stops ---
	await _cluster.shutdown()
	_cluster = null
	_world = null
	var persistence2: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence2.load_or_create(WORLD)
	assert_not_null(_world, "world restored from save")
	if _world == null:
		return
	assert_eq(_world.get_player(alice_id).character.name, "Second One")
	assert_eq(_world.get_player(alice_id).character.appearance, _full_look(second_look))
	assert_eq(_world.get_player(alice_id).character_generation, 2)
	assert_eq(_world.get_player(bob_id).character.name, BOB_NAME)
	assert_eq(_world.get_player(bob_id).character.appearance, _full_look(BOB_LOOK))
	assert_eq(_world.get_player(bob_id).character_generation, 1)
	assert_false(_world.has_character(carol_id))
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _join("alice")
	var b2: NetworkService = await _join("bob")
	var c2: NetworkService = await _join("carol")
	if a2 == null or b2 == null or c2 == null:
		return
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	# Alice and bob are in the world at once, with what they created.
	await _assert_everybody_sees([a2, b2, c2], [alice_id, bob_id], "session 2")
	assert_eq(_mirror(b2).character_name(alice_id), "Second One")
	assert_eq(_mirror(a2).character_generation(alice_id), 2)
	assert_false(_mirror(a2).can_create_character())
	assert_eq(_mirror(a2).creation_block_reason(), SurvivalService.REASON_CHARACTER_ALIVE)
	# Carol left without a character and still has to create one.
	assert_eq(c2.client_state.local_player_id, carol_id)
	assert_true(_mirror(c2).can_create_character())
	await _settle()
	assert_true(_knows_nothing_about(a2, carol_id))
	assert_eq(await _create(c2, "Carol", {"top_color": "yellow"}), [true, ""])
	await _assert_everybody_sees([a2, b2, c2], [alice_id, bob_id, carol_id], "carol created in session 2")
	assert_eq(_world.get_player(carol_id).character_generation, 1)


# ------------------------------------------------------------ 5. other configurations

func test_without_required_creation_everybody_has_a_default_character() -> void:
	_config.require_character_creation = false
	assert_true(_start_server(), "server started")
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	# In the world at once, as before P2-T9, and with a (default) character.
	await _assert_everybody_sees([a, b], [alice_id, bob_id], "default characters")
	for client: NetworkService in [a, b]:
		assert_eq(_mirror(client).character_name(alice_id), _config.character.default_name)
		assert_eq(_mirror(client).appearance(bob_id), _config.appearance.default_selection())
		assert_false(_mirror(client).can_create_character())
	assert_eq(await _create(a, ALICE_NAME, ALICE_LOOK), [false, SurvivalService.REASON_CHARACTER_ALIVE])
	# The next character starts by itself and keeps the profile.
	_kill(alice_id)
	assert_true(await _wait(func() -> bool: return _world.get_player(alice_id).character_generation == 2 and _vitals_mirror(b).is_alive(alice_id)), "alice's next character started by itself")
	assert_eq(_world.get_player(alice_id).character.name, _config.character.default_name)
	assert_eq(_mirror(b).character_name(alice_id), _config.character.default_name)
	assert_true(await _wait(func() -> bool: return _mirror(a).character_generation(alice_id) == 2), "alice's mirror follows the generation")


func test_the_generation_can_be_shared_by_configuration() -> void:
	_config.character.share_character_generation = true
	_config.survival.respawn_delay_sec = 0.2
	assert_true(_start_server(), "server started")
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var alice_id: String = a.client_state.local_player_id
	assert_eq(await _create(a, ALICE_NAME, {}), [true, ""])
	assert_eq(await _create(b, BOB_NAME, {}), [true, ""])
	assert_true(await _wait(func() -> bool: return _mirror(b).character_generation(alice_id) == 1), "bob is told alice's generation")
	_kill(alice_id)
	assert_true(await _wait(func() -> bool: return _mirror(a).can_create_character()), "alice may create the next character")
	assert_eq(await _create(a, "Second One", {}), [true, ""])
	assert_true(await _wait(func() -> bool: return _mirror(b).character_generation(alice_id) == 2), "and that it went up")
	# A late joiner gets it in the join snapshot.
	var c: NetworkService = await _join("carol")
	if c == null:
		return
	assert_eq(_mirror(c).character_generation(alice_id), 2)


func test_duplicate_names_can_be_refused_over_the_network() -> void:
	_config.character.allow_duplicate_names = false
	assert_true(_start_server(), "server started")
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	assert_eq(await _create(a, "Rick Grimes", {}), [true, ""])
	assert_eq(await _create(b, "rick grimes", {}), [false, ServerWorld.REASON_NAME_TAKEN])
	assert_false(_world.has_character(b.client_state.local_player_id))
	assert_eq(_cluster.server.rejected_intent_count(ServerWorld.REASON_NAME_TAKEN), 1)
	assert_eq(await _create(b, "Daryl", {}), [true, ""])


func test_a_client_without_a_screen_creates_its_character_by_itself() -> void:
	assert_true(_start_server(), "server started")
	# What `--character-name=` does: set before the connection starts.
	var a: NetworkService = _cluster.add_client("alice")
	_module(a).set_auto_create("Headless Hank", {"top_color": "orange"})
	var b: NetworkService = await _join("bob")
	if b == null:
		return
	assert_true(await _wait(func() -> bool: return not a.client_state.local_player_id.is_empty()), "alice joined")
	var alice_id: String = a.client_state.local_player_id
	assert_true(_module(a).is_auto_create_enabled())
	assert_false(_module(b).is_auto_create_enabled())
	await _assert_everybody_sees([a, b], [alice_id], "created without a request from the test")
	assert_eq(_world.get_player(alice_id).character.name, "Headless Hank")
	assert_eq(_world.get_player(alice_id).character.appearance, _full_look({"top_color": "orange"}))
	assert_false(_world.has_character(b.client_state.local_player_id), "bob has no automatic character")
	# After a death it creates the next one as soon as the server allows it.
	_kill(alice_id)
	assert_true(await _wait(func() -> bool: return _world.get_player(alice_id).character_generation == 2 and _survival().is_alive(alice_id)), "the next character was created without a screen")
	assert_eq(_world.get_player(alice_id).character.name, "Headless Hank")
	assert_eq(_cluster.server.rejected_intent_count(), 0, "it never asked too early")

	# A name the server refuses turns the automatic path off (no request loop).
	var c: NetworkService = _cluster.add_client("carol")
	_module(c).set_auto_create("!", {})
	var failed: Array[Array] = _results_of(c)
	assert_true(await _wait(func() -> bool: return failed.size() == 1), "the automatic request was answered")
	assert_eq(failed[0].slice(1), [false, CharacterNameRules.REASON_TOO_SHORT])
	await _settle()
	assert_eq(failed.size(), 1, "it is not sent again")
	assert_false(_module(c).is_auto_create_enabled())
	assert_true(_mirror(c).can_create_character(), "the player can still create one itself")


# ------------------------------------------------------------ 6. contract

func test_default_settings_protocol_and_request_validation() -> void:
	assert_eq(BuildInfo.PROTOCOL_VERSION, 11, "the creation intent and the character rows changed the protocol (7); 8 since P2-T10..T12, 9 since the hand-over RPCs (P2-T14), 10 since they were withdrawn and the drop intent got a quantity (P2-T15), 11 since the trade RPCs (P2-T16)")
	assert_eq(CharacterNetModule.MODULE_NAME, "CharacterNet")
	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	assert_not_null(_module(service), "the composition installs the module on every peer")
	assert_eq(CharacterNetModule.validate_create_request(1, "alice", {}), "")
	assert_eq(CharacterNetModule.validate_create_request(0, "alice", {"top_color": "red"}), "")
	assert_eq(CharacterNetModule.validate_create_request(1, "", {}), "", "the name rules are the world's business")
	assert_eq(CharacterNetModule.validate_create_request("1", "alice", {}), IntentValidator.REASON_BAD_TYPE)
	assert_eq(CharacterNetModule.validate_create_request(1.0, "alice", {}), IntentValidator.REASON_BAD_TYPE)
	assert_eq(CharacterNetModule.validate_create_request(1, &"alice", {}), IntentValidator.REASON_BAD_TYPE)
	assert_eq(CharacterNetModule.validate_create_request(1, "alice", null), IntentValidator.REASON_BAD_TYPE)
	assert_eq(CharacterNetModule.validate_create_request(-5, "alice", {}), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(CharacterNetModule.validate_create_request(1, "x".repeat(CharacterNameRules.HARD_MAX_LENGTH), {}), "")
	assert_eq(CharacterNetModule.validate_create_request(1, "x".repeat(CharacterNameRules.HARD_MAX_LENGTH + 1), {}), CharacterNetModule.REASON_PAYLOAD_TOO_LARGE)
	var too_many: Dictionary = {}
	for index: int in range(AppearanceCatalog.MAX_SLOTS + 1):
		too_many["slot_%d" % index] = "x"
	assert_eq(CharacterNetModule.validate_create_request(1, "alice", too_many), CharacterNetModule.REASON_PAYLOAD_TOO_LARGE)
	assert_eq(_module(service).request_create_character("alice", {}), CharacterNetModule.NO_REQUEST, "nothing is sent while not joined")
	# Channel 0, reliable; the creation request from any peer, everything else only from the server.
	var rpc_config: Dictionary = (_module(service).get_script() as Script).get_rpc_config()
	var expected_modes: Dictionary[String, int] = {
		"_rpc_request_create_character": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_create_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_character_rows": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_creation_state": MultiplayerAPI.RPC_MODE_AUTHORITY,
	}
	assert_eq(rpc_config.size(), expected_modes.size(), "no other RPC exists")
	for method: String in expected_modes:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), expected_modes[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	var settings: CharacterSettings = CharacterSettings.load_or_default()
	assert_true(settings.create_intent_rate_per_sec > 0.0 and settings.create_intent_burst >= 1)
	assert_true(settings.save_after_create)
	service.free()


func test_the_client_mirror_validates_its_payloads() -> void:
	var mirror: ClientCharacterState = ClientCharacterState.new(_config.character, _config.appearance)
	var changes: Array = []
	mirror.character_changed.connect(func(player_id: String) -> void: changes.append(player_id))
	var states: Array = []
	mirror.creation_state_changed.connect(func(can_create: bool, reason: String) -> void: states.append([can_create, reason]))
	assert_false(mirror.can_create_character(), "nothing is known before the join")
	assert_eq(mirror.creation_block_reason(), ClientCharacterState.REASON_NOT_JOINED)
	var row: Dictionary = {"player_id": "player_000002", "name": BOB_NAME, "appearance": _full_look(BOB_LOOK), "character_generation": 0}
	var good: Dictionary = {"schema_version": ClientCharacterState.SCHEMA_VERSION, "characters": [row], "self": {"can_create": true, "reason": ""}}
	assert_true(mirror.apply_join("player_000001", good))
	assert_eq(mirror.character_name("player_000002"), BOB_NAME)
	assert_eq(mirror.appearance("player_000002"), _full_look(BOB_LOOK))
	assert_true(mirror.can_create_character())
	assert_eq(changes, ["player_000002"])
	assert_eq(states, [[true, ""]])
	# The mirror hands out copies.
	mirror.appearance("player_000002")["top_color"] = "red"
	assert_eq(mirror.appearance("player_000002"), _full_look(BOB_LOOK))
	assert_eq(mirror.character_name("player_999999"), "", "unknown players have no name")
	assert_eq(mirror.appearance("player_999999"), {})
	assert_eq(mirror.character_generation("player_999999"), 0)

	# Malformed join fragments change nothing.
	var bad_fragments: Array = [
		{},
		{"schema_version": ClientCharacterState.SCHEMA_VERSION + 1, "characters": [], "self": {"can_create": true, "reason": ""}},
		{"schema_version": ClientCharacterState.SCHEMA_VERSION, "characters": "none", "self": {"can_create": true, "reason": ""}},
		{"schema_version": ClientCharacterState.SCHEMA_VERSION, "characters": [], "self": {"can_create": true, "reason": "character_alive"}},
		{"schema_version": ClientCharacterState.SCHEMA_VERSION, "characters": [], "self": {"can_create": 1, "reason": ""}},
		{"schema_version": ClientCharacterState.SCHEMA_VERSION, "characters": [row, row], "self": {"can_create": false, "reason": "character_alive"}},
		{"schema_version": ClientCharacterState.SCHEMA_VERSION, "characters": [], "self": {"can_create": true, "reason": ""}, "extra": 1},
	]
	for fragment: Dictionary in bad_fragments:
		assert_false(mirror.apply_join("player_000001", fragment), "refused: %s" % str(fragment).left(90))
	assert_eq(mirror.character_name("player_000002"), BOB_NAME, "the earlier state is kept")

	# Malformed rows are dropped one by one.
	var bad_rows: Array = [
		"row", 5, null,
		{"player_id": "player_000003", "name": "Carol", "appearance": _full_look({})},
		{"player_id": "", "name": "Carol", "appearance": _full_look({}), "character_generation": 0},
		{"player_id": "p".repeat(_config.character.max_player_id_length + 1), "name": "Carol", "appearance": _full_look({}), "character_generation": 0},
		{"player_id": "player_000003", "name": "", "appearance": _full_look({}), "character_generation": 0},
		{"player_id": "player_000003", "name": "x".repeat(CharacterNameRules.HARD_MAX_LENGTH + 1), "appearance": _full_look({}), "character_generation": 0},
		{"player_id": "player_000003", "name": "Ca\nrol", "appearance": _full_look({}), "character_generation": 0},
		{"player_id": "player_000003", "name": " Carol", "appearance": _full_look({}), "character_generation": 0},
		{"player_id": "player_000003", "name": 7, "appearance": _full_look({}), "character_generation": 0},
		{"player_id": "player_000003", "name": "Carol", "appearance": {"top_color": "red"}, "character_generation": 0},
		{"player_id": "player_000003", "name": "Carol", "appearance": _full_look({"top_color": "ultraviolet"}), "character_generation": 0},
		{"player_id": "player_000003", "name": "Carol", "appearance": "red", "character_generation": 0},
		{"player_id": "player_000003", "name": "Carol", "appearance": _full_look({}), "character_generation": -1},
		{"player_id": "player_000003", "name": "Carol", "appearance": _full_look({}), "character_generation": 1.5},
		{"player_id": "player_000003", "name": "Carol", "appearance": _full_look({}), "character_generation": 0, "health": 50.0},
	]
	assert_eq(mirror.apply_rows(bad_rows), 0)
	assert_false(mirror.has_character("player_000003"))
	var mixed: Array = [bad_rows[4], {"player_id": "player_000003", "name": "Carol", "appearance": _full_look({}), "character_generation": 3}]
	assert_eq(mirror.apply_rows(mixed), 1, "a valid row next to an invalid one is kept")
	assert_eq(mirror.character_generation("player_000003"), 3)
	var too_many: Array = []
	for index: int in range(CharacterNetModule.MAX_ROWS_PER_MESSAGE + 1):
		too_many.append({"player_id": "player_%06d" % (index + 10), "name": "Carol", "appearance": _full_look({}), "character_generation": 0})
	assert_eq(mirror.apply_rows(too_many), 0, "an oversized message is dropped whole")

	# Creation state.
	states.clear()
	assert_true(mirror.apply_creation_state(false, "respawn_wait"))
	assert_true(mirror.apply_creation_state(false, "respawn_wait"))
	assert_eq(states, [[false, "respawn_wait"]], "the signal fires on changes only")
	for bad: Array in [[true, "respawn_wait"], [false, ""], [1, ""], [true, 5], [false, "r".repeat(CharacterNetModule.REASON_MAX_LENGTH + 1)], [null, null]]:
		assert_false(mirror.apply_creation_state(bad[0], bad[1]), "refused: %s" % str(bad).left(60))
	assert_false(mirror.can_create_character())
	assert_eq(mirror.creation_block_reason(), "respawn_wait")

	# Leaving.
	var removed: Array = []
	mirror.character_removed.connect(func(player_id: String) -> void: removed.append(player_id))
	mirror.remove_player("player_000002")
	mirror.remove_player("player_000002")
	assert_eq(removed, ["player_000002"])
	assert_false(mirror.has_character("player_000002"))
	assert_true(mirror.rejected_payload_count > 0)
