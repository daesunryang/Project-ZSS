extends TestCase
## F-31 over real ENet (docs/09 §17.16): a player talks with an NPC. The
## talker names the NPC and the choice it makes; the server decides from its
## own state and sends the lines and choices to the talker only. Everybody
## else learns one thing: the NPC's public reaction is "talk". Rules of the
## conversation itself: the domain tests of NpcDialogue; the pure parts of
## the module: tests/unit/npc_dialogue_net_state_test.gd.

const WORLD: String = "npc_dialogue_net_world"
## Both clients stand here: one metre from the east edge of cell_0_0.
const SPAWN: Vector3 = Vector3(9.0, 0.0, 5.0)
## In talking range, in the same cell.
const NEAR: Vector3 = Vector3(9.0, 0.0, 3.9)
## In the same cell (so the clients know the NPC), out of talking range.
const FAR: Vector3 = Vector3(2.0, 0.0, 5.0)
## In talking range, but in cell_1_0: with an interest radius of 0 no client
## is told about an NPC there.
const OUTSIDE_INTEREST: Vector3 = Vector3(10.5, 0.0, 5.0)
## Where the server puts a player that "walked away": in the same cell,
## farther from NEAR than a conversation bears.
const WALKED_AWAY: Vector3 = Vector3(3.0, 0.0, 5.0)
const FRIENDLY: String = "f31_net_friendly"
const TIMID: String = "f31_net_timid"
const FRIENDLY_NAME: String = "말 잘 받는 사람"
const TIMID_NAME: String = "겁 많은 사람"
const MISSING_NPC_ID: String = "npc_999999"
const FOOD: String = "dev_food_ration"
const MAX_WAIT_TICKS: int = 240
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 120.0
const GENEROUS_BURST: int = 120
const LETHAL_DAMAGE: float = 500.0
## Every RPC of the dialogue module.
const DIALOGUE_RPCS: Dictionary[String, int] = {
	"_rpc_request_talk": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_request_choose": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_request_end": MultiplayerAPI.RPC_MODE_ANY_PEER,
	"_rpc_dialogue_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
	"_rpc_dialogue_ended": MultiplayerAPI.RPC_MODE_AUTHORITY,
}


## NPCs that have the behaviour layer (and so an inventory) but never decide
## to do anything: they stand where they were put.
class IdleDecider:
	extends NpcDecider


var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _save_root: String = ""
## client -> rows [request_id, ok, reason] of its dialogue results.
var _results: Dictionary = {}
## client -> the views of the conversations the server ended.
var _ended: Dictionary = {}


func before_each() -> void:
	GameLogger.set_capture(true)
	_save_root = ""
	_results = {}
	_ended = {}
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	network_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	network_settings.pickup_intent_burst = GENEROUS_BURST
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.gameplay.world_half_extent_m = 50.0
	_config.gameplay.player_spawn_position = SPAWN
	_config.clock = WorldClockSettings.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.map_content = null
	_config.world_cells = WorldCellSettings.new()
	_config.world_cells.cell_size_m = 10.0
	_config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	_config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	_config.world_cells.active_radius_cells = 0
	_config.world_cells.preload_radius_cells = 1
	_config.world_cells.preload_lookahead_sec = 0.0
	_config.world_cells.refresh_period_sec = 0.0
	_config.world_cells.max_preload_loads_per_refresh = 1000
	_config.interest = InterestSettings.new()
	_config.interest.interest_radius_cells = 0
	_config.interest.keep_margin_cells = 0
	_config.npc = NpcSettings.new()
	_config.npc_definitions = NpcCatalog.new()
	_config.npc_definitions.add(_definition(FRIENDLY, FRIENDLY_NAME, 1.0))
	_config.npc_definitions.add(_definition(TIMID, TIMID_NAME, 0.0))
	_config.npc_net = NpcNetSettings.new()
	# The behaviour layer gives the NPCs an inventory (a gift needs one); the
	# decider that chooses nothing keeps them where they stand.
	_config.npc_behaviour = NpcBehaviourSettings.new()
	_config.npc_decider = IdleDecider.new()
	_config.npc_scavenge = null
	_config.npc_relocation = null
	_config.npc_health = NpcHealthSettings.new()
	# A stranger frightens the timid NPC enough to refuse (0.34 with these
	# traits) and the friendly one not at all.
	_config.npc_social = NpcSocialSettings.new()
	_config.npc_social.refuse_fear = 0.3
	_config.npc_dialogue_net = NpcDialogueNetSettings.new()
	_config.npc_dialogue_net.dialogue_intent_rate_per_sec = GENEROUS_RATE
	_config.npc_dialogue_net.dialogue_intent_burst = GENEROUS_BURST
	_cluster = NetTestCluster.new(tree, network_settings, _config)


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	if not _save_root.is_empty():
		SaveService.remove_tree(_save_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## `nature` 1 = outgoing, agreeable, brave and calm; 0 = the opposite.
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


func _start() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null or _world.seed_new_world(DevWorldSeed.new()) != OK:
		return false
	return _cluster.start_server(_world, null) == OK


func _join(player_key: String) -> NetworkService:
	var client: NetworkService = await _cluster.join_client(player_key)
	if client == null:
		fail("test setup: %s did not join" % player_key)
		return null
	var rows: Array = []
	var ended: Array = []
	_module(client).dialogue_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	_module(client).dialogue_ended.connect(func(view: Dictionary) -> void: ended.append(view))
	_results[client] = rows
	_ended[client] = ended
	return client


func _npcs() -> NpcService:
	return _world.get_system(NpcService.SYSTEM_ID) as NpcService


func _dialogue() -> NpcDialogue:
	var social: NpcSocial = NpcSocial.of_world(_world)
	return social.dialogue() if social != null else null


func _module(service: NetworkService) -> NpcDialogueNetModule:
	return service.get_module(NpcDialogueNetModule.MODULE_NAME) as NpcDialogueNetModule


func _talk(service: NetworkService) -> ClientDialogueState:
	return _module(service).client_state


func _npc_module(service: NetworkService) -> NpcNetModule:
	return service.get_module(NpcNetModule.MODULE_NAME) as NpcNetModule


func _npc_mirror(service: NetworkService) -> ClientNpcState:
	return _npc_module(service).client_state


func _rows(service: NetworkService) -> Array:
	return _results[service]


func _spawn(definition_id: String = FRIENDLY, position: Vector3 = NEAR) -> String:
	var result: ActionResult = _npcs().spawn_npc(_world, definition_id, position)
	if not result.ok:
		fail("test setup: NPC spawn refused: " + result.reason)
		return ""
	return str(result.event[NpcService.KEY_NPC_ID])


## Waits until every client of `clients` has the NPC in its mirror.
func _known(clients: Array[NetworkService], npc_id: String) -> bool:
	var known: Callable = func() -> bool:
		for client: NetworkService in clients:
			if not _npc_mirror(client).has_npc(npc_id):
				return false
		return true
	var ok: bool = await _cluster.wait_ticks_until(known, MAX_WAIT_TICKS)
	if not ok:
		fail("test setup: %s did not reach the clients" % npc_id)
	return ok


## Sends one request through `send` (it returns the request id, or sends a
## raw request and returns the id it used) and waits for its answer:
## [ok, reason].
func _answer(client: NetworkService, send: Callable) -> Array:
	var rows: Array = _rows(client)
	var before: int = rows.size()
	var request_id: int = send.call()
	if request_id == NpcDialogueNetModule.NO_REQUEST:
		fail("the dialogue request was not sent")
		return [false, "not_sent"]
	var answered: bool = await _cluster.wait_ticks_until(func() -> bool: return rows.size() > before, MAX_WAIT_TICKS)
	if not answered:
		fail("no answer to dialogue request %d" % request_id)
		return [false, "no_answer"]
	var row: Array = rows[rows.size() - 1]
	assert_eq(row[0], request_id, "the answer names the request")
	assert_eq(rows.size(), before + 1, "one answer per request")
	return [row[1], row[2]]


func _start_talk(client: NetworkService, npc_id: String) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_start(npc_id))


func _choose(client: NetworkService, choice_id: String) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_choose(choice_id))


func _end_talk(client: NetworkService) -> Array:
	return await _answer(client, func() -> int: return _module(client).request_end())


func _raw_talk(client: NetworkService, request_id: int, npc_id: Variant) -> Array:
	return await _answer(client, func() -> int:
		_module(client).send_raw_talk_request(request_id, npc_id)
		return request_id)


func _raw_choose(client: NetworkService, request_id: int, npc_id: Variant, turn: Variant, choice_id: Variant) -> Array:
	return await _answer(client, func() -> int:
		_module(client).send_raw_choose_request(request_id, npc_id, turn, choice_id)
		return request_id)


func _reaction_is(clients: Array[NetworkService], npc_id: String, reaction: String, wanted: bool = true) -> Callable:
	return func() -> bool:
		for client: NetworkService in clients:
			if (_npc_mirror(client).reaction_of(npc_id) == reaction) != wanted:
				return false
		return true


func _choice_ids(client: NetworkService) -> PackedStringArray:
	var ids: PackedStringArray = []
	for entry: Array in _talk(client).choices:
		ids.append(str(entry[0]))
	return ids


## What a player carries on the server, as the dictionaries its client
## mirrors, sorted by item id.
func _server_inventory(player_id: String) -> Array:
	var entries: Array = []
	for item: ItemInstance in _world.inventory.items_in_inventory(_world.get_player(player_id).inventory_id):
		entries.append(item.to_dict())
	entries.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return str(left["item_instance_id"]) < str(right["item_instance_id"]))
	return entries


func _mirror_inventory(client: NetworkService) -> Array:
	var entries: Array = []
	for entry: Dictionary in client.client_state.inventory:
		entries.append(entry.duplicate(true))
	entries.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return str(left["item_instance_id"]) < str(right["item_instance_id"]))
	return entries


## A view without the NPC's line (NpcDialogue.view_of() has the state of a
## conversation, not the words that were said last).
func _without_line(view: Dictionary) -> Dictionary:
	var copy: Dictionary = view.duplicate(true)
	copy.erase(NpcDialogue.KEY_LINE)
	return copy


## Units of `definition_id` in an inventory on the server.
func _units(inventory_id: String, definition_id: String) -> int:
	var total: int = 0
	for item: ItemInstance in _world.inventory.items_in_inventory(inventory_id):
		if item.definition_id == definition_id:
			total += item.quantity
	return total


# ------------------------------------------------------------ 1. who is told what

func test_the_talker_gets_lines_and_choices_and_a_bystander_only_sees_the_reaction() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var both: Array[NetworkService] = [a, b]
	var npc_id: String = _spawn()
	if not await _known(both, npc_id):
		return
	var alice_id: String = a.client_state.local_player_id
	assert_ne(_npc_mirror(a).reaction_of(npc_id), "talk")
	var bob_changes: Array = [0]
	_talk(b).changed.connect(func() -> void: bob_changes[0] += 1)

	# Alice asks: she gets the NPC's line and what she can answer.
	assert_eq(await _start_talk(a, npc_id), [true, ""])
	var talk: ClientDialogueState = _talk(a)
	assert_true(talk.open)
	assert_eq(talk.npc_id, npc_id)
	assert_eq(talk.npc_name, FRIENDLY_NAME)
	assert_eq(talk.turn, 1)
	assert_false(talk.line.is_empty(), "the NPC said something")
	assert_eq(talk.end_reason, "")
	var first_line: String = talk.line
	var first_choices: PackedStringArray = _choice_ids(a)
	assert_true(first_choices.has(NpcDialogue.CHOICE_GREET) and first_choices.has(NpcDialogue.CHOICE_LEAVE), "greet and leave are offered: %s" % ", ".join(first_choices))
	assert_eq(_without_line(talk.snapshot()), _without_line(NpcDialogueNetModule.wire_view(_dialogue().view_of(alice_id))), "the mirror is the server's view")
	assert_eq(_dialogue().talker_of(npc_id), alice_id)

	# Everybody sees that the NPC is talking, and Bob sees nothing else.
	assert_true(await _cluster.wait_ticks_until(_reaction_is(both, npc_id, "talk"), MAX_WAIT_TICKS), "both clients see the reaction 'talk'")
	assert_false(_talk(b).open)
	assert_eq(_talk(b).snapshot(), {}, "the bystander's mirror holds no view")
	assert_eq(bob_changes[0], 0)
	assert_eq(_rows(b).size(), 0, "the bystander got no result")
	assert_eq((_ended[b] as Array).size(), 0)
	var bystander_wire: String = var_to_str(_npc_mirror(b).recent_events()) + var_to_str(_npc_mirror(b).get_npc(npc_id)) + var_to_str(_npc_module(_cluster.server).build_join_fragment(b.client_state.local_player_id))
	assert_not_contains(bystander_wire, first_line, "the line is not in anything the bystander was sent")
	assert_not_contains(bystander_wire, "player_", "nor who the NPC talks with")
	for word: String in ["trust", "fear", "liking", "record", "choice", "turn"]:
		assert_not_contains(bystander_wire, word, "nothing but the label: " + word)
	var keys: Array = _npc_mirror(b).get_npc(npc_id).keys()
	assert_eq(keys.size(), 9, "the public row: eight values and the reaction")

	# A choice: the next line, to Alice only.
	assert_eq(await _choose(a, NpcDialogue.CHOICE_GREET), [true, ""])
	assert_true(talk.open)
	assert_eq(talk.turn, 2)
	assert_false(talk.line.is_empty())
	assert_false(_choice_ids(a).has(NpcDialogue.CHOICE_GREET), "one greeting per conversation")
	assert_eq(await _choose(a, NpcDialogue.CHOICE_WHO), [true, ""])
	assert_eq(talk.turn, 3)
	assert_eq(_without_line(talk.snapshot()), _without_line(NpcDialogueNetModule.wire_view(_dialogue().view_of(alice_id))))

	# Alice leaves: the conversation is over and the NPC shows it.
	assert_eq(await _choose(a, NpcDialogue.CHOICE_LEAVE), [true, ""])
	assert_false(talk.open)
	assert_eq(talk.end_reason, NpcDialogue.END_PLAYER_LEFT)
	assert_eq(talk.choices, [])
	assert_eq(_dialogue().session_count(), 0)
	assert_true(await _cluster.wait_ticks_until(_reaction_is(both, npc_id, "talk", false), MAX_WAIT_TICKS), "the reaction 'talk' is gone on both clients")
	assert_eq(_module(a).request_choose(NpcDialogue.CHOICE_GREET), NpcDialogueNetModule.NO_REQUEST, "nothing to choose without a conversation")
	assert_eq(await _end_talk(a), [false, NpcDialogue.REASON_NOT_TALKING], "ending no conversation is refused")

	# The end key: start again and end without a choice.
	assert_eq(await _start_talk(a, npc_id), [true, ""])
	assert_true(talk.open)
	assert_eq(await _end_talk(a), [true, ""])
	assert_false(talk.open)
	assert_eq(talk.end_reason, NpcDialogue.END_PLAYER_LEFT)
	await _cluster.wait_ticks(SETTLE_TICKS)
	assert_eq(_rows(b).size(), 0)
	assert_eq(bob_changes[0], 0, "nothing of the whole conversation reached the bystander's dialogue mirror")
	assert_eq((_ended[a] as Array).size(), 0, "what the player ended itself is answered, not announced")
	for client: NetworkService in both:
		assert_eq(_module(client).rejected_payload_count, 0)
		assert_eq(_talk(client).rejected_payload_count, 0)
		assert_eq(_npc_mirror(client).rejected_payload_count, 0)
		assert_eq(_npc_mirror(client).event_gap_count, 0)
	assert_eq(_npc_module(_cluster.server).invalid_reaction_count, 0)
	assert_eq(_module(_cluster.server).unsendable_view_count, 0)
	assert_eq(_module(_cluster.server).cut_text_count, 0)


func test_an_npc_that_will_not_talk_says_so_and_no_conversation_begins() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	if a == null:
		return
	var npc_id: String = _spawn(TIMID)
	if not await _known([a] as Array[NetworkService], npc_id):
		return
	# The request was looked at (ok), the answer is a conversation that never
	# began: the line it said and why.
	assert_eq(await _start_talk(a, npc_id), [true, ""])
	var talk: ClientDialogueState = _talk(a)
	assert_false(talk.open)
	assert_eq(talk.npc_id, npc_id)
	assert_eq(talk.npc_name, TIMID_NAME)
	assert_eq(talk.end_reason, NpcDialogue.END_REFUSED)
	assert_false(talk.line.is_empty(), "it said why not")
	assert_eq(talk.choices, [])
	assert_eq(_dialogue().session_count(), 0)
	assert_eq(_dialogue().partner_of(npc_id), "")
	# Asking again at once is answered the same way.
	assert_eq(await _start_talk(a, npc_id), [true, ""])
	assert_false(talk.open)
	assert_eq(talk.end_reason, NpcDialogue.END_REFUSED)
	await _cluster.wait_ticks(SETTLE_TICKS)
	assert_ne(_npc_mirror(a).reaction_of(npc_id), "talk", "an NPC that refused does not show 'talk'")
	assert_eq(_module(a).rejected_payload_count, 0)


# ------------------------------------------------------------ 2. requests that are refused

func test_far_unknown_uninteresting_and_dead_npcs_cannot_be_talked_to() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	if a == null:
		return
	var near_id: String = _spawn()
	var far_id: String = _spawn(FRIENDLY, FAR)
	var outside_id: String = _spawn(FRIENDLY, OUTSIDE_INTEREST)
	if not await _known([a] as Array[NetworkService], near_id) or not await _known([a] as Array[NetworkService], far_id):
		return
	var server: NetworkService = _cluster.server
	var peer_id: int = server.peer_of_player(a.client_state.local_player_id)
	# Too far: the server's distance, whatever the client thinks.
	assert_eq(await _start_talk(a, far_id), [false, NpcDialogue.REASON_TOO_FAR])
	assert_eq(_talk(a).last_error, NpcDialogue.REASON_TOO_FAR)
	assert_false(_talk(a).open)
	# An NPC outside the cells this peer is told about: it stands in talking
	# range on the server, but for this peer it does not exist. The answer is
	# the one for an id nobody has.
	await _cluster.wait_ticks(SETTLE_TICKS)
	assert_not_null(_npcs().get_npc(outside_id), "the NPC is there on the server")
	assert_true(_npcs().get_npc(outside_id).position.distance_to(SPAWN) < _config.npc_social.talk_range_m, "and in talking range")
	assert_false(_npc_mirror(a).has_npc(outside_id))
	assert_false(_npc_module(server).knows_npc(peer_id, outside_id))
	var outside_answer: Array = await _start_talk(a, outside_id)
	var missing_answer: Array = await _start_talk(a, MISSING_NPC_ID)
	assert_eq(outside_answer, [false, NpcDialogue.REASON_UNKNOWN_NPC])
	assert_eq(missing_answer, outside_answer, "an NPC out of interest is answered exactly like one that does not exist")
	assert_eq(server.rejected_intent_count(NpcDialogue.REASON_UNKNOWN_NPC), 2)
	assert_eq(_dialogue().partner_of(outside_id), "", "nothing began on the server")
	# A choice naming it is refused the same way.
	assert_eq(await _raw_choose(a, 900, outside_id, 1, NpcDialogue.CHOICE_GREET), [false, NpcDialogue.REASON_UNKNOWN_NPC])
	# A dead NPC: its body is still there to see, but it does not talk.
	assert_true(NpcHealth.of_world(_world).apply_damage(near_id, DamageInput.create("test_source", BodyPart.Part.TORSO, Wound.Type.LACERATION, LETHAL_DAMAGE)).ok)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _npc_mirror(a).is_dead(near_id), MAX_WAIT_TICKS))
	assert_eq(await _start_talk(a, near_id), [false, NpcDialogue.REASON_NPC_DEAD])
	assert_eq(_dialogue().session_count(), 0)
	assert_eq(_dialogue().started_count, 0, "no conversation ever began")
	assert_eq(_module(a).rejected_payload_count, 0)


func test_stale_turns_bad_choices_and_choices_without_a_conversation_change_nothing() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	if a == null:
		return
	var npc_id: String = _spawn()
	var far_id: String = _spawn(FRIENDLY, FAR)
	if not await _known([a] as Array[NetworkService], npc_id) or not await _known([a] as Array[NetworkService], far_id):
		return
	var alice_id: String = a.client_state.local_player_id
	# A choice before any conversation.
	assert_eq(await _raw_choose(a, 500, npc_id, 1, NpcDialogue.CHOICE_GREET), [false, NpcDialogue.REASON_NOT_TALKING])
	assert_eq(await _start_talk(a, npc_id), [true, ""])
	var view: Dictionary = _talk(a).snapshot()
	# A choice for an older or a later view.
	assert_eq(await _raw_choose(a, 501, npc_id, 0, NpcDialogue.CHOICE_GREET), [false, NpcDialogue.REASON_STALE_TURN])
	assert_eq(await _raw_choose(a, 502, npc_id, 5, NpcDialogue.CHOICE_GREET), [false, NpcDialogue.REASON_STALE_TURN])
	# A choice the view does not offer (a well-formed id).
	assert_eq(await _raw_choose(a, 503, npc_id, 1, "trade:7"), [false, NpcDialogue.REASON_BAD_CHOICE])
	assert_eq(await _raw_choose(a, 504, npc_id, 1, "give:0"), [false, NpcDialogue.REASON_BAD_CHOICE], "a gift outside the give list")
	assert_eq(await _raw_choose(a, 505, npc_id, 1, NpcDialogue.CHOICE_BACK), [false, NpcDialogue.REASON_BAD_CHOICE])
	# A choice naming an NPC the player does not talk with.
	assert_eq(await _raw_choose(a, 506, far_id, 1, NpcDialogue.CHOICE_GREET), [false, NpcDialogue.REASON_NOT_TALKING])
	# Nothing of it touched the conversation: the same view, on both sides.
	assert_true(_talk(a).open)
	assert_eq(_talk(a).snapshot(), view)
	assert_eq(_without_line(NpcDialogueNetModule.wire_view(_dialogue().view_of(alice_id))), _without_line(view))
	assert_eq(_dialogue().choice_count, 0, "no choice was made")
	assert_eq(_talk(a).last_error, NpcDialogue.REASON_NOT_TALKING)
	# And it goes on.
	assert_eq(await _choose(a, NpcDialogue.CHOICE_GREET), [true, ""])
	assert_eq(_talk(a).turn, 2)
	assert_eq(_talk(a).last_error, "")
	# The choice that was good a moment ago is stale now.
	assert_eq(await _raw_choose(a, 507, npc_id, 1, NpcDialogue.CHOICE_WHO), [false, NpcDialogue.REASON_STALE_TURN])
	assert_eq(_talk(a).turn, 2)
	assert_eq(_module(a).rejected_payload_count, 0)


func test_malformed_requests_are_refused_and_counted() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	if a == null:
		return
	var npc_id: String = _spawn()
	if not await _known([a] as Array[NetworkService], npc_id):
		return
	var module: NpcDialogueNetModule = _module(a)
	var server: NetworkService = _cluster.server
	var bad_type: String = IntentValidator.REASON_BAD_TYPE
	# Requests whose id cannot be used get no answer at all.
	module.send_raw_talk_request("1", npc_id)
	module.send_raw_talk_request(null, npc_id)
	module.send_raw_talk_request(-1, npc_id)
	module.send_raw_choose_request(2.5, npc_id, 1, NpcDialogue.CHOICE_GREET)
	module.send_raw_choose_request(-7, npc_id, 1, NpcDialogue.CHOICE_GREET)
	module.send_raw_end_request("x")
	module.send_raw_end_request([1])
	module.send_raw_end_request(-3)
	# Requests with a usable id are told why.
	var expected: Array = []
	var requests: Array = [
		[func() -> void: module.send_raw_talk_request(10, 12345), 10, bad_type],
		[func() -> void: module.send_raw_talk_request(11, [npc_id]), 11, bad_type],
		[func() -> void: module.send_raw_talk_request(12, {"npc_id": npc_id}), 12, bad_type],
		[func() -> void: module.send_raw_talk_request(13, "not an id"), 13, NpcDialogueNetModule.REASON_BAD_NPC_ID],
		[func() -> void: module.send_raw_talk_request(14, ""), 14, NpcDialogueNetModule.REASON_BAD_NPC_ID],
		[func() -> void: module.send_raw_talk_request(15, "npc_" + "1".repeat(200)), 15, NpcDialogueNetModule.REASON_BAD_NPC_ID],
		[func() -> void: module.send_raw_talk_request(16, a.client_state.local_player_id), 16, NpcDialogueNetModule.REASON_BAD_NPC_ID],
		[func() -> void: module.send_raw_choose_request(17, npc_id, "1", NpcDialogue.CHOICE_GREET), 17, bad_type],
		[func() -> void: module.send_raw_choose_request(18, npc_id, 1, null), 18, bad_type],
		[func() -> void: module.send_raw_choose_request(19, npc_id, 1, 0), 19, bad_type],
		[func() -> void: module.send_raw_choose_request(20, 7, 1, NpcDialogue.CHOICE_GREET), 20, bad_type],
		[func() -> void: module.send_raw_choose_request(21, npc_id, -1, NpcDialogue.CHOICE_GREET), 21, NpcDialogueNetModule.REASON_BAD_TURN],
		[func() -> void: module.send_raw_choose_request(22, npc_id, 1, "GREET!"), 22, NpcDialogueNetModule.REASON_BAD_CHOICE_ID],
		[func() -> void: module.send_raw_choose_request(23, npc_id, 1, "x".repeat(NpcDialogue.CHOICE_ID_MAX_LENGTH + 1)), 23, NpcDialogueNetModule.REASON_BAD_CHOICE_ID],
		[func() -> void: module.send_raw_choose_request(24, npc_id, 1, "give:0;give:1"), 24, NpcDialogueNetModule.REASON_BAD_CHOICE_ID],
		[func() -> void: module.send_raw_choose_request(25, npc_id, 1, "y".repeat(100000)), 25, NpcDialogueNetModule.REASON_BAD_CHOICE_ID],
		[func() -> void: module.send_raw_choose_request(26, "nobody", 1, NpcDialogue.CHOICE_GREET), 26, NpcDialogueNetModule.REASON_BAD_NPC_ID],
	]
	for request: Array in requests:
		(request[0] as Callable).call()
		expected.append([request[1], false, request[2]])
	# A good request last: the channel is ordered, so when its answer is here
	# every answer before it is too.
	var good_id: int = module.request_start(npc_id)
	assert_ne(good_id, NpcDialogueNetModule.NO_REQUEST)
	var all_rows: Array = _rows(a)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return all_rows.size() == expected.size() + 1, MAX_WAIT_TICKS), "every request with a usable id was answered: %d of %d" % [all_rows.size(), expected.size() + 1])
	await _cluster.wait_ticks(SETTLE_TICKS)
	var rows: Array = all_rows.duplicate()
	var last: Variant = rows.pop_back()
	assert_eq(last, [good_id, true, ""], "the good request was answered last")
	assert_eq(rows, expected, "each malformed request with a usable id got its reason, in order, and nothing else did")
	assert_eq(server.rejected_intent_count(bad_type), 7 + 5, "the malformed types, with and without a usable request id")
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_SEQUENCE), 3)
	assert_eq(server.rejected_intent_count(NpcDialogueNetModule.REASON_BAD_NPC_ID), 5)
	assert_eq(server.rejected_intent_count(NpcDialogueNetModule.REASON_BAD_TURN), 1)
	assert_eq(server.rejected_intent_count(NpcDialogueNetModule.REASON_BAD_CHOICE_ID), 4)
	# None of it began, changed or ended anything: the one conversation is
	# the good request's.
	assert_eq(_dialogue().started_count, 1)
	assert_eq(_dialogue().choice_count, 0)
	assert_eq(_dialogue().session_count(), 1)
	assert_true(_talk(a).open)
	assert_eq(_talk(a).turn, 1)
	assert_eq(module.rejected_payload_count, 0, "every answer of the server was well formed")


func test_requests_beyond_the_rate_limit_are_refused() -> void:
	# Two requests at once, then practically none: what is refused does not
	# depend on how fast this machine is.
	_config.npc_dialogue_net.dialogue_intent_rate_per_sec = 0.01
	_config.npc_dialogue_net.dialogue_intent_burst = 2
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	if a == null:
		return
	var far_id: String = _spawn(FRIENDLY, FAR)
	if not await _known([a] as Array[NetworkService], far_id):
		return
	var module: NpcDialogueNetModule = _module(a)
	for request_id: int in range(1, 7):
		module.send_raw_talk_request(request_id, far_id)
	var rows: Array = _rows(a)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return rows.size() == 6, MAX_WAIT_TICKS), "every request was answered")
	var limited: String = NetworkService.RATE_LIMITED
	assert_eq(rows, [[1, false, NpcDialogue.REASON_TOO_FAR], [2, false, NpcDialogue.REASON_TOO_FAR], [3, false, limited], [4, false, limited], [5, false, limited], [6, false, limited]])
	assert_eq(_cluster.server.rejected_intent_count(limited), 4)
	# The limit is one bucket for the three intents.
	module.send_raw_end_request(7)
	module.send_raw_choose_request(8, far_id, 1, NpcDialogue.CHOICE_GREET)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return rows.size() == 8, MAX_WAIT_TICKS))
	assert_eq(rows[6], [7, false, limited])
	assert_eq(rows[7], [8, false, limited])
	assert_eq(_dialogue().started_count, 0)


func test_a_peer_that_has_not_joined_is_refused_and_told_nothing() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	if a == null:
		return
	var npc_id: String = _spawn()
	if not await _known([a] as Array[NetworkService], npc_id):
		return
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var rows: Array = []
	_module(stranger).dialogue_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	var connected: bool = await _cluster.wait_until(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	assert_eq(_module(stranger).request_start(npc_id), NpcDialogueNetModule.NO_REQUEST, "the client API sends nothing before the join")
	assert_eq(_module(stranger).request_end(), NpcDialogueNetModule.NO_REQUEST)
	_module(stranger).send_raw_talk_request(1, npc_id)
	_module(stranger).send_raw_choose_request(2, npc_id, 1, NpcDialogue.CHOICE_GREET)
	_module(stranger).send_raw_end_request(3)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 3, MAX_WAIT_TICKS), "the server refused all three")
	await _cluster.wait_ticks(SETTLE_TICKS)
	assert_eq(rows.size(), 0, "an unjoined peer is told nothing")
	assert_eq(_dialogue().started_count, 0)
	assert_false(_talk(stranger).open)


func test_a_world_without_the_social_layer_answers_dialogue_unavailable() -> void:
	_config.npc_social = null
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	if a == null:
		return
	var npc_id: String = _spawn()
	if not await _known([a] as Array[NetworkService], npc_id):
		return
	assert_null(_dialogue())
	assert_eq(await _start_talk(a, npc_id), [false, NpcDialogue.REASON_UNAVAILABLE])
	assert_eq(await _raw_choose(a, 40, npc_id, 1, NpcDialogue.CHOICE_GREET), [false, NpcDialogue.REASON_UNAVAILABLE])
	assert_eq(await _end_talk(a), [false, NpcDialogue.REASON_UNAVAILABLE])
	assert_eq(_npc_mirror(a).reaction_of(npc_id), "none", "an NPC without the social component shows no reaction")
	assert_eq(_npc_module(_cluster.server).invalid_reaction_count, 0)


# ------------------------------------------------------------ 3. the server ends it

func test_a_conversation_the_server_ends_reaches_the_talker_only() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var both: Array[NetworkService] = [a, b]
	var npc_id: String = _spawn()
	if not await _known(both, npc_id):
		return
	var alice_id: String = a.client_state.local_player_id
	assert_eq(await _start_talk(a, npc_id), [true, ""])
	assert_true(await _cluster.wait_ticks_until(_reaction_is(both, npc_id, "talk"), MAX_WAIT_TICKS))
	# Alice walks away (the server's position; nothing is asked of it).
	_world.get_player(alice_id).position = WALKED_AWAY
	var ended: Array = _ended[a]
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return ended.size() == 1, MAX_WAIT_TICKS), "the talker was told")
	var view: Dictionary = ended[0]
	assert_eq(view[NpcDialogue.KEY_NPC_ID], npc_id)
	assert_eq(view[NpcDialogue.KEY_OPEN], false)
	assert_eq(view[NpcDialogue.KEY_END_REASON], NpcDialogue.END_TOO_FAR)
	assert_false(_talk(a).open)
	assert_eq(_talk(a).end_reason, NpcDialogue.END_TOO_FAR)
	assert_eq(_talk(a).npc_id, npc_id)
	assert_eq(_dialogue().session_count(), 0)
	assert_eq(_rows(a).size(), 1, "an end the server decided is no answer to a request")
	assert_true(await _cluster.wait_ticks_until(_reaction_is(both, npc_id, "talk", false), MAX_WAIT_TICKS), "the NPC no longer shows 'talk'")
	await _cluster.wait_ticks(SETTLE_TICKS)
	assert_eq(ended.size(), 1, "told once")
	assert_eq((_ended[b] as Array).size(), 0, "the bystander was told nothing")
	assert_eq(_rows(b).size(), 0)
	assert_eq(_talk(b).snapshot(), {})
	# From where she stands now she cannot begin again.
	assert_eq(await _start_talk(a, npc_id), [false, NpcDialogue.REASON_TOO_FAR])
	assert_eq(_module(a).rejected_payload_count, 0)
	assert_eq(_module(b).rejected_payload_count, 0)


func test_a_peer_that_disconnects_in_a_conversation_frees_the_npc() -> void:
	assert_true(_start())
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var npc_id: String = _spawn()
	if not await _known([a, b] as Array[NetworkService], npc_id):
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	assert_eq(await _start_talk(a, npc_id), [true, ""])
	# An NPC talks to one player at a time.
	assert_eq(await _start_talk(b, npc_id), [false, NpcDialogue.REASON_NPC_TALKING])
	assert_false(_talk(b).open)
	assert_eq(_dialogue().partner_of(npc_id), alice_id)
	# Alice's client goes away without a word.
	_results.erase(a)
	_ended.erase(a)
	_cluster.remove_client(a)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return _dialogue().partner_of(npc_id).is_empty(), MAX_WAIT_TICKS), "the server ended her conversation")
	assert_eq(_dialogue().session_count(), 0)
	assert_false(_dialogue().is_talking(alice_id))
	# Bob can talk to it now.
	assert_eq(await _start_talk(b, npc_id), [true, ""])
	assert_true(_talk(b).open)
	assert_eq(_dialogue().partner_of(npc_id), bob_id)
	assert_true(await _cluster.wait_ticks_until(_reaction_is([b] as Array[NetworkService], npc_id, "talk"), MAX_WAIT_TICKS))
	assert_eq((_ended[b] as Array).size(), 0)
	assert_eq(_module(b).rejected_payload_count, 0)


# ------------------------------------------------------------ 4. a gift

func test_a_gift_moves_the_item_the_mirror_follows_and_it_is_saved_at_once() -> void:
	_save_root = "user://test_saves/npc_dialogue_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _join("alice")
	var b: NetworkService = await _join("bob")
	if a == null or b == null:
		return
	var npc_id: String = _spawn()
	if not await _known([a, b] as Array[NetworkService], npc_id):
		return
	var alice_id: String = a.client_state.local_player_id
	var alice: PlayerState = _world.get_player(alice_id)
	var npc_inventory: String = NpcSurvivalSense.inventory_of(_npcs().get_npc(npc_id))
	assert_false(npc_inventory.is_empty(), "test setup: the NPC has an inventory")
	if npc_inventory.is_empty():
		return
	# Alice picks two rations up through her client, so her mirror has them.
	var item_id: String = _world.inventory.spawn_world_item(FOOD, 2, _world.cell_id_at(alice.position), alice.position)
	a.request_pickup(item_id)
	assert_true(await _cluster.wait_ticks_until(func() -> bool: return a.client_state.has_inventory_item(item_id), MAX_WAIT_TICKS), "test setup: pickup")
	await _cluster.wait_ticks(SETTLE_TICKS)
	var bob_mirror_before: Array = _mirror_inventory(b)
	var save: SaveService = SaveService.new(_save_root)

	# Talking and looking at the give list moves and saves nothing.
	var generation: int = save.current_generation(WORLD)
	assert_eq(await _start_talk(a, npc_id), [true, ""])
	assert_eq(await _choose(a, NpcDialogue.CHOICE_GIVE), [true, ""])
	var give_choices: PackedStringArray = _choice_ids(a)
	assert_eq(give_choices, PackedStringArray(["give:0", NpcDialogue.CHOICE_BACK]), "the one kind of thing she carries, and back")
	await _cluster.wait_ticks(SETTLE_TICKS)
	assert_eq(save.current_generation(WORLD), generation, "nothing of a conversation without a gift is saved")
	assert_eq(_units(alice.inventory_id, FOOD), 2)
	assert_eq(_units(npc_inventory, FOOD), 0)

	# The gift: one unit really moves, and when the answer is here the mirror
	# has the change already and the world is on disk.
	assert_eq(await _choose(a, "give:0"), [true, ""])
	assert_eq(save.current_generation(WORLD), generation + 1, "the gift was saved before the answer went out")
	assert_eq(_units(alice.inventory_id, FOOD), 1, "one unit left the player")
	assert_eq(_units(npc_inventory, FOOD), 1, "and is in the NPC's inventory")
	assert_eq(_mirror_inventory(a), _server_inventory(alice_id), "the talker's inventory mirror equals the server's when the answer arrives")
	assert_eq(int(_mirror_inventory(a)[0]["quantity"]), 1)
	assert_true(_talk(a).open, "the conversation goes on")
	assert_false(_talk(a).line.is_empty(), "the NPC said something about it")

	# The second unit: the stack is gone from the server and from the mirror.
	assert_eq(await _choose(a, NpcDialogue.CHOICE_GIVE), [true, ""])
	assert_eq(await _choose(a, "give:0"), [true, ""])
	assert_eq(save.current_generation(WORLD), generation + 2)
	assert_eq(_units(alice.inventory_id, FOOD), 0)
	assert_eq(_units(npc_inventory, FOOD), 2, "no unit was lost or made")
	assert_false(a.client_state.has_inventory_item(item_id), "the stack left the mirror")
	assert_eq(_mirror_inventory(a), _server_inventory(alice_id))
	# Nothing left to give: the list is not shown, nothing moves.
	assert_eq(await _choose(a, NpcDialogue.CHOICE_GIVE), [true, ""])
	assert_false(_choice_ids(a).has("give:0"))
	assert_eq(await _raw_choose(a, 700, npc_id, _talk(a).turn, "give:0"), [false, NpcDialogue.REASON_BAD_CHOICE])
	assert_eq(await _choose(a, NpcDialogue.CHOICE_LEAVE), [true, ""])
	await _cluster.wait_ticks(SETTLE_TICKS)
	assert_eq(save.current_generation(WORLD), generation + 2, "and only the two gifts were saved")
	assert_eq(_units(npc_inventory, FOOD), 2)
	# The bystander's inventory mirror was sent nothing of it.
	assert_eq(_mirror_inventory(b), bob_mirror_before, "nobody else is sent another player's inventory change")
	assert_eq(_module(a).rejected_payload_count, 0)
	assert_eq((a.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule).rejected_payload_count, 0)


# ------------------------------------------------------------ 5. the wire

func test_the_rpcs_are_reliable_on_channel_zero_and_the_protocol_is_twenty_one() -> void:
	assert_eq(BuildInfo.PROTOCOL_VERSION, 21, "the reaction field, npc_reaction_changed and the NpcDialogueNet RPCs are protocol 21 (F-31)")
	assert_true(_start())
	var module: NpcDialogueNetModule = _module(_cluster.server)
	assert_not_null(module, "the module is installed on servers and clients")
	assert_eq(module.request_start("npc_000001"), NpcDialogueNetModule.NO_REQUEST, "a server asks for nothing")
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	assert_eq(rpc_config.size(), DIALOGUE_RPCS.size(), "no other RPC exists")
	for method: String in DIALOGUE_RPCS:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), DIALOGUE_RPCS[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	# The reaction rides on the NPC module's reliable events: no new RPC there.
	assert_eq((NpcNetModule as Script).get_rpc_config().size(), 2)
	# A joining peer is sent nothing of anybody's conversation.
	var a: NetworkService = await _join("alice")
	if a == null:
		return
	assert_eq(module.build_join_fragment(a.client_state.local_player_id), {})
	assert_false(_talk(a).open)
	assert_eq(_talk(a).snapshot(), {})
