extends TestCase
## F-31 (docs/09 §17.16): the pure parts of the NPC dialogue network module
## and its client side. The wire format of a conversation view and its
## validation, the validation of the three intents and of the result, the
## client mirror, the talk key policy and the Korean text. No nodes that
## talk to a network, no ENet (tests/integration/npc_dialogue_net_test.gd).

const NPC_A: String = "npc_000001"
const NPC_B: String = "npc_000002"
const PRIVATE_SENTINEL: String = "must_never_cross_the_dialogue_wire"

var _state: ClientDialogueState = null
var _changes: Array = []
var _shown: Array[Dictionary] = []
var _closed: Array[Dictionary] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_state = ClientDialogueState.new()
	_changes = [0]
	_shown = []
	_closed = []
	_state.changed.connect(func() -> void: _changes[0] += 1)
	_state.view_shown.connect(func(view: Dictionary) -> void: _shown.append(view))
	_state.conversation_closed.connect(func(view: Dictionary) -> void: _closed.append(view))


func after_each() -> void:
	_state = null
	GameLogger.set_capture(false)


func _open_view(npc_id: String = NPC_A, turn: int = 1) -> Dictionary:
	return {
		NpcDialogue.KEY_NPC_ID: npc_id,
		NpcDialogue.KEY_NPC_NAME: "한서윤",
		NpcDialogue.KEY_OPEN: true,
		NpcDialogue.KEY_TURN: turn,
		NpcDialogue.KEY_LINE: "누구세요?",
		NpcDialogue.KEY_CHOICES: [["greet", "인사한다"], ["give:0", "통조림을 준다"], ["leave", "떠난다"]],
		NpcDialogue.KEY_END_REASON: "",
	}


func _closed_view(npc_id: String = NPC_A, end_reason: String = NpcDialogue.END_TOO_FAR, line: String = "") -> Dictionary:
	return {
		NpcDialogue.KEY_NPC_ID: npc_id,
		NpcDialogue.KEY_NPC_NAME: "한서윤",
		NpcDialogue.KEY_OPEN: false,
		NpcDialogue.KEY_TURN: 2,
		NpcDialogue.KEY_LINE: line,
		NpcDialogue.KEY_CHOICES: [],
		NpcDialogue.KEY_END_REASON: end_reason,
	}


func _with(view: Dictionary, key: String, value: Variant) -> Dictionary:
	var changed: Dictionary = view.duplicate(true)
	changed[key] = value
	return changed


# ------------------------------------------------------------ settings

func test_defaults_are_valid_and_the_composition_carries_them() -> void:
	var settings: NpcDialogueNetSettings = NpcDialogueNetSettings.new()
	assert_eq(settings.validate(), PackedStringArray())
	assert_eq(settings.dialogue_intent_rate_per_sec, 4.0)
	assert_eq(settings.dialogue_intent_burst, 6)
	assert_true(ResourceLoader.exists(NpcDialogueNetSettings.DEFAULT_PATH))
	var loaded: NpcDialogueNetSettings = NpcDialogueNetSettings.load_or_default()
	assert_eq(loaded.validate(), PackedStringArray())
	assert_eq(loaded.dialogue_intent_rate_per_sec, settings.dialogue_intent_rate_per_sec, "the shipped file holds the defaults")
	assert_eq(loaded.dialogue_intent_burst, settings.dialogue_intent_burst)
	var bad: NpcDialogueNetSettings = NpcDialogueNetSettings.new()
	bad.dialogue_intent_burst = 0
	assert_eq(bad.validate().size(), 1)
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_not_null(config.npc_dialogue_net)
	assert_eq(config.validate(), PackedStringArray(), "the shipped configuration is valid with the dialogue module")
	# A config without the settings says so (the field is not edited on the
	# shared config: a second bundle is made).
	var incomplete: CompositionConfig = CompositionConfig.from_defaults()
	incomplete.npc_dialogue_net = null
	assert_true(incomplete.validate().has("composition config is incomplete (npc_dialogue_net)"))
	var module: NpcDialogueNetModule = NpcDialogueNetModule.new(null)
	assert_eq(str(module.name), "NpcDialogueNet", "the module name is the RPC path on every peer")
	assert_eq(module.request_start(NPC_A), NpcDialogueNetModule.NO_REQUEST, "nothing is sent while offline")
	assert_eq(module.request_choose("greet"), NpcDialogueNetModule.NO_REQUEST)
	assert_eq(module.request_end(), NpcDialogueNetModule.NO_REQUEST)
	module.free()


# ------------------------------------------------------------ the view

func test_a_view_has_exactly_the_seven_keys_with_the_right_types() -> void:
	assert_eq(ClientDialogueState.view_error(_open_view()), "")
	assert_eq(ClientDialogueState.view_error(_closed_view()), "")
	assert_eq(ClientDialogueState.view_error(_closed_view(NPC_A, NpcDialogue.END_REFUSED, "가까이 오지 마세요.")), "", "an NPC that would not talk says a line")
	for end_reason: String in NpcDialogue.END_REASONS:
		assert_eq(ClientDialogueState.view_error(_closed_view(NPC_A, end_reason)), "", end_reason)
	var bad: String = ClientDialogueState.REASON_BAD_VIEW
	for not_a_view: Variant in [null, 7, "view", [], [_open_view()]]:
		assert_eq(ClientDialogueState.view_error(not_a_view), bad)
	assert_eq(ClientDialogueState.view_error({}), bad)
	# Every key is needed and no other is taken.
	for key: String in ClientDialogueState.VIEW_KEYS:
		var missing: Dictionary = _open_view()
		missing.erase(key)
		assert_eq(ClientDialogueState.view_error(missing), bad, "without " + key)
	for extra_key: String in ["trust", "fear", "relationship", "player_id", "node", "record"]:
		assert_eq(ClientDialogueState.view_error(_with(_open_view(), extra_key, PRIVATE_SENTINEL)), bad, "an unknown key is refused: " + extra_key)
	var renamed: Dictionary = _open_view()
	renamed.erase(NpcDialogue.KEY_LINE)
	renamed[7] = "누구세요?"
	assert_eq(ClientDialogueState.view_error(renamed), bad, "a key that is no String")


func test_wrong_types_and_oversized_values_are_refused() -> void:
	var bad: String = ClientDialogueState.REASON_BAD_VIEW
	var open: Dictionary = _open_view()
	var cases: Array = [
		[NpcDialogue.KEY_NPC_ID, 1], [NpcDialogue.KEY_NPC_ID, ""], [NpcDialogue.KEY_NPC_ID, "zombie_000001"], [NpcDialogue.KEY_NPC_ID, "npc_" + "1".repeat(80)],
		[NpcDialogue.KEY_NPC_NAME, 5], [NpcDialogue.KEY_NPC_NAME, "가".repeat(NpcDefinition.NAME_MAX_LENGTH + 1)], [NpcDialogue.KEY_NPC_NAME, "이름\n둘째 줄"],
		[NpcDialogue.KEY_OPEN, 1], [NpcDialogue.KEY_OPEN, "true"],
		[NpcDialogue.KEY_TURN, 1.0], [NpcDialogue.KEY_TURN, "1"], [NpcDialogue.KEY_TURN, -1], [NpcDialogue.KEY_TURN, ClientDialogueState.MAX_TURN + 1],
		[NpcDialogue.KEY_LINE, 3], [NpcDialogue.KEY_LINE, "가".repeat(ClientDialogueState.LINE_MAX_LENGTH + 1)], [NpcDialogue.KEY_LINE, "말\u0007"],
		[NpcDialogue.KEY_END_REASON, 0], [NpcDialogue.KEY_END_REASON, NpcDialogue.END_TOO_FAR],
		[NpcDialogue.KEY_CHOICES, "greet"], [NpcDialogue.KEY_CHOICES, {}], [NpcDialogue.KEY_CHOICES, []],
		[NpcDialogue.KEY_CHOICES, ["greet"]], [NpcDialogue.KEY_CHOICES, [["greet"]]], [NpcDialogue.KEY_CHOICES, [["greet", "인사", "extra"]]],
		[NpcDialogue.KEY_CHOICES, [[1, "인사"]]], [NpcDialogue.KEY_CHOICES, [["greet", 2]]], [NpcDialogue.KEY_CHOICES, [["greet", ""]]],
		[NpcDialogue.KEY_CHOICES, [["", "인사"]]], [NpcDialogue.KEY_CHOICES, [["Greet", "인사"]]], [NpcDialogue.KEY_CHOICES, [["give 0", "준다"]]],
		[NpcDialogue.KEY_CHOICES, [["g".repeat(ClientDialogueState.CHOICE_ID_MAX_LENGTH + 1), "인사"]]],
		[NpcDialogue.KEY_CHOICES, [["greet", "가".repeat(ClientDialogueState.CHOICE_TEXT_MAX_LENGTH + 1)]]],
		[NpcDialogue.KEY_CHOICES, [["greet", "인사\t한다"]]],
		[NpcDialogue.KEY_CHOICES, [["greet", "인사"], ["greet", "또 인사"]]],
	]
	for entry: Array in cases:
		assert_eq(ClientDialogueState.view_error(_with(open, str(entry[0]), entry[1])), bad, "%s = %s" % [str(entry[0]), var_to_str(entry[1]).left(60)])
	var too_many: Array = []
	for index: int in ClientDialogueState.MAX_CHOICES + 1:
		too_many.append(["give:%d" % index, "준다"])
	assert_eq(ClientDialogueState.view_error(_with(open, NpcDialogue.KEY_CHOICES, too_many)), bad, "more choices than a view carries")
	too_many.pop_back()
	assert_eq(ClientDialogueState.view_error(_with(open, NpcDialogue.KEY_CHOICES, too_many)), "", "the limit itself is fine")
	# The limits themselves are accepted.
	assert_eq(ClientDialogueState.view_error(_with(open, NpcDialogue.KEY_LINE, "가".repeat(ClientDialogueState.LINE_MAX_LENGTH))), "")
	assert_eq(ClientDialogueState.view_error(_with(open, NpcDialogue.KEY_NPC_NAME, "")), "", "an NPC without a name is shown as it is")
	# A conversation that is over offers nothing and says why.
	var closed: Dictionary = _closed_view()
	assert_eq(ClientDialogueState.view_error(_with(closed, NpcDialogue.KEY_CHOICES, [["leave", "떠난다"]])), bad)
	assert_eq(ClientDialogueState.view_error(_with(closed, NpcDialogue.KEY_END_REASON, "")), bad)
	assert_eq(ClientDialogueState.view_error(_with(closed, NpcDialogue.KEY_END_REASON, "because_trust_0.1")), bad, "only the known end reasons")
	assert_true(ClientDialogueState.LINE_MAX_LENGTH >= NpcDialogueLines.LINE_MAX_LENGTH and ClientDialogueState.CHOICE_TEXT_MAX_LENGTH >= NpcDialogueLines.CHOICE_MAX_LENGTH, "the wire carries every text the line data may hold")


func test_the_wire_view_is_a_whitelist_and_cuts_text_that_is_too_long() -> void:
	var source: Dictionary = _open_view()
	source["trust"] = 0.42
	source["record"] = {"talks": 3, "secret": PRIVATE_SENTINEL}
	source["give_items"] = ["item_000007"]
	var cut: Array = []
	var wire: Dictionary = NpcDialogueNetModule.wire_view(source, cut)
	assert_eq(wire, _open_view(), "exactly the seven keys, nothing else of the source")
	assert_eq(cut.size(), 0)
	var wire_text: String = var_to_str(wire)
	for forbidden: String in ["trust", "0.42", "record", "talks", "give_items", "item_000007", PRIVATE_SENTINEL]:
		assert_not_contains(wire_text, forbidden, "private data is absent: " + forbidden)
	# A filled-in placeholder made a text longer than the wire carries.
	var long_source: Dictionary = _open_view()
	long_source[NpcDialogue.KEY_LINE] = "가".repeat(ClientDialogueState.LINE_MAX_LENGTH + 30)
	long_source[NpcDialogue.KEY_CHOICES] = [["give:0", "나".repeat(ClientDialogueState.CHOICE_TEXT_MAX_LENGTH + 5)], ["leave", "떠난다"]]
	var cut_wire: Dictionary = NpcDialogueNetModule.wire_view(long_source, cut)
	assert_eq(cut.size(), 2, "the line and one choice were cut")
	assert_eq(str(cut_wire[NpcDialogue.KEY_LINE]).length(), ClientDialogueState.LINE_MAX_LENGTH)
	assert_eq(str(cut_wire[NpcDialogue.KEY_CHOICES][0][1]).length(), ClientDialogueState.CHOICE_TEXT_MAX_LENGTH)
	assert_eq(ClientDialogueState.view_error(cut_wire), "", "what is sent is a view a client accepts")
	# What is no view makes nothing.
	var incomplete: Dictionary = _open_view()
	incomplete.erase(NpcDialogue.KEY_TURN)
	assert_eq(NpcDialogueNetModule.wire_view(incomplete), {})
	assert_eq(NpcDialogueNetModule.wire_view(_with(_open_view(), NpcDialogue.KEY_CHOICES, "greet")), {})
	assert_eq(NpcDialogueNetModule.wire_view(_with(_open_view(), NpcDialogue.KEY_CHOICES, [["greet"]])), {})
	assert_eq(NpcDialogueNetModule.wire_view({}), {})


# ------------------------------------------------------------ intents and results

func test_the_three_intents_are_validated_types_first() -> void:
	var bad_type: String = IntentValidator.REASON_BAD_TYPE
	assert_eq(NpcDialogueNetModule.validate_talk_request(1, NPC_A), "")
	assert_eq(NpcDialogueNetModule.validate_talk_request(0, NPC_A), "", "request id 0 is usable")
	for bad: Array in [["1", NPC_A], [1.0, NPC_A], [null, NPC_A], [1, 7], [1, null], [1, [NPC_A]], [1, StringName(NPC_A)]]:
		assert_eq(NpcDialogueNetModule.validate_talk_request(bad[0], bad[1]), bad_type, var_to_str(bad))
	assert_eq(NpcDialogueNetModule.validate_talk_request(-1, NPC_A), IntentValidator.REASON_BAD_SEQUENCE)
	for bad_id: String in ["", "npc", "npc_", "player_000001", "npc_000001 ", "NPC_000001", "npc_000001;drop", "npc_000001\n", "npc_" + "9".repeat(100)]:
		assert_eq(NpcDialogueNetModule.validate_talk_request(1, bad_id), NpcDialogueNetModule.REASON_BAD_NPC_ID, bad_id.left(40))
	assert_eq(NpcDialogueNetModule.validate_choose_request(1, NPC_A, 3, "give:0"), "")
	assert_eq(NpcDialogueNetModule.validate_choose_request(1, NPC_A, 0, "leave"), "")
	for bad: Array in [[1, NPC_A, "3", "greet"], [1, NPC_A, 3.0, "greet"], [1, NPC_A, 3, 0], [1, NPC_A, 3, null], ["1", NPC_A, 3, "greet"], [1, 5, 3, "greet"], [1, NPC_A, null, "greet"]]:
		assert_eq(NpcDialogueNetModule.validate_choose_request(bad[0], bad[1], bad[2], bad[3]), bad_type, var_to_str(bad))
	assert_eq(NpcDialogueNetModule.validate_choose_request(-5, NPC_A, 3, "greet"), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(NpcDialogueNetModule.validate_choose_request(1, "nobody", 3, "greet"), NpcDialogueNetModule.REASON_BAD_NPC_ID)
	assert_eq(NpcDialogueNetModule.validate_choose_request(1, NPC_A, -1, "greet"), NpcDialogueNetModule.REASON_BAD_TURN)
	assert_eq(NpcDialogueNetModule.validate_choose_request(1, NPC_A, ClientDialogueState.MAX_TURN + 1, "greet"), NpcDialogueNetModule.REASON_BAD_TURN)
	for bad_choice: String in ["", "GREET", "give 0", "give:0\n", "주기", "x".repeat(NpcDialogue.CHOICE_ID_MAX_LENGTH + 1), "give:0;leave", "../leave"]:
		assert_eq(NpcDialogueNetModule.validate_choose_request(1, NPC_A, 3, bad_choice), NpcDialogueNetModule.REASON_BAD_CHOICE_ID, bad_choice.left(30))
	# Every choice id the rule makes fits the shape.
	for choice_id: String in [NpcDialogue.CHOICE_GREET, NpcDialogue.CHOICE_WHO, NpcDialogue.CHOICE_GIVE, NpcDialogue.CHOICE_NEWS, NpcDialogue.CHOICE_TRADE, NpcDialogue.CHOICE_JOIN, NpcDialogue.CHOICE_THREATEN, NpcDialogue.CHOICE_LEAVE, NpcDialogue.CHOICE_BACK, NpcDialogue.CHOICE_WAKE, NpcDialogue.CHOICE_GIVE_PREFIX + "7", NpcDialogue.CHOICE_TRADE_PREFIX + "7"]:
		assert_true(ClientDialogueState.is_choice_id(choice_id), choice_id)
	assert_eq(NpcDialogueNetModule.validate_end_request(4), "")
	assert_eq(NpcDialogueNetModule.validate_end_request("4"), bad_type)
	assert_eq(NpcDialogueNetModule.validate_end_request(null), bad_type)
	assert_eq(NpcDialogueNetModule.validate_end_request(-1), IntentValidator.REASON_BAD_SEQUENCE)


func test_a_result_carries_a_view_exactly_when_it_is_ok() -> void:
	assert_eq(NpcDialogueNetModule.result_error(1, true, "", _open_view()), "")
	assert_eq(NpcDialogueNetModule.result_error(1, true, "", _closed_view(NPC_A, NpcDialogue.END_REFUSED, "싫어요.")), "")
	assert_eq(NpcDialogueNetModule.result_error(1, false, "too_far", {}), "")
	for bad: Array in [["1", true, "", _open_view()], [1, 1, "", _open_view()], [1, true, null, _open_view()], [1, true, "", null], [1, true, "", [_open_view()]], [1, false, "too_far", "{}"]]:
		assert_eq(NpcDialogueNetModule.result_error(bad[0], bad[1], bad[2], bad[3]), IntentValidator.REASON_BAD_TYPE, var_to_str(bad).left(80))
	assert_eq(NpcDialogueNetModule.result_error(-1, false, "too_far", {}), IntentValidator.REASON_BAD_SEQUENCE)
	var bad_view: String = ClientDialogueState.REASON_BAD_VIEW
	assert_eq(NpcDialogueNetModule.result_error(1, true, "too_far", _open_view()), bad_view, "ok with a reason")
	assert_eq(NpcDialogueNetModule.result_error(1, false, "", {}), bad_view, "a refusal without a reason")
	assert_eq(NpcDialogueNetModule.result_error(1, false, "too_far", _open_view()), bad_view, "a refusal with a view")
	assert_eq(NpcDialogueNetModule.result_error(1, true, "", {}), bad_view, "ok without a view")
	assert_eq(NpcDialogueNetModule.result_error(1, true, "", _with(_open_view(), "trust", 0.5)), bad_view, "ok with a view that is none")
	assert_eq(NpcDialogueNetModule.result_error(1, false, "r".repeat(NpcDialogueNetModule.REASON_MAX_LENGTH + 1), {}), bad_view, "an oversized reason")


# ------------------------------------------------------------ the mirror

func test_the_mirror_follows_a_conversation_from_start_to_end() -> void:
	assert_false(_state.open)
	assert_eq(_state.snapshot(), {}, "nothing before the first conversation")
	assert_eq(_state.choice_id_at(0), "")
	assert_eq(_state.apply_view(_open_view()), "")
	assert_true(_state.open)
	assert_eq(_state.npc_id, NPC_A)
	assert_eq(_state.npc_name, "한서윤")
	assert_eq(_state.line, "누구세요?")
	assert_eq(_state.turn, 1)
	assert_eq(_state.choices.size(), 3)
	assert_eq(_state.end_reason, "")
	assert_true(_state.has_choice("give:0"))
	assert_false(_state.has_choice("trade:0"))
	assert_eq(_state.choice_id_at(1), "give:0")
	assert_eq(_state.choice_id_at(3), "")
	assert_eq(_state.choice_id_at(-1), "")
	assert_eq(_state.snapshot(), _open_view())
	assert_eq(_shown.size(), 1)
	# The next line of the same conversation.
	var second: Dictionary = _open_view(NPC_A, 2)
	second[NpcDialogue.KEY_LINE] = "고맙습니다."
	second[NpcDialogue.KEY_CHOICES] = [["leave", "떠난다"]]
	assert_eq(_state.apply_view(second), "")
	assert_eq(_state.turn, 2)
	assert_eq(_state.line, "고맙습니다.")
	assert_eq(_state.choices, [["leave", "떠난다"]])
	# The end: the last line and the reason stay for the panel.
	assert_eq(_state.apply_view(_closed_view(NPC_A, NpcDialogue.END_PLAYER_LEFT, "잘 가요.")), "")
	assert_false(_state.open)
	assert_eq(_state.line, "잘 가요.")
	assert_eq(_state.end_reason, NpcDialogue.END_PLAYER_LEFT)
	assert_eq(_state.choices, [])
	assert_eq(_state.choice_id_at(0), "", "a conversation that is over offers nothing")
	assert_eq(_closed.size(), 1)
	assert_eq(_shown.size(), 2)
	assert_eq(_changes[0], 3)
	assert_eq(_state.rejected_payload_count, 0)
	# A join starts from nothing again.
	_state.apply_join()
	assert_eq(_state.snapshot(), {})
	assert_eq(_state.npc_id, "")
	assert_eq(_state.end_reason, "")


func test_the_mirror_cannot_be_changed_through_what_it_hands_out() -> void:
	var view: Dictionary = _open_view()
	assert_eq(_state.apply_view(view), "")
	(view[NpcDialogue.KEY_CHOICES] as Array).append(["threaten", "위협한다"])
	((view[NpcDialogue.KEY_CHOICES] as Array)[0] as Array)[1] = "바뀐 글"
	assert_eq(_state.choices.size(), 3, "the applied view was copied")
	assert_eq(_state.choices[0], ["greet", "인사한다"])
	var handed: Dictionary = _state.snapshot()
	(handed[NpcDialogue.KEY_CHOICES] as Array).clear()
	assert_eq(_state.choices.size(), 3, "a snapshot is a copy")
	(_shown[0][NpcDialogue.KEY_CHOICES] as Array).clear()
	assert_eq(_state.choices.size(), 3, "so is the view of the signal")


func test_malformed_views_and_errors_do_not_open_or_change_a_conversation() -> void:
	assert_eq(_state.apply_view(_open_view()), "")
	var before: Dictionary = _state.snapshot()
	for bad: Variant in [null, {}, "view", _with(_open_view(NPC_A, 2), "fear", 0.9), _with(_open_view(NPC_A, 2), NpcDialogue.KEY_TURN, "2"), _with(_closed_view(), NpcDialogue.KEY_END_REASON, "made_up")]:
		assert_eq(_state.apply_view(bad), ClientDialogueState.REASON_BAD_VIEW)
	assert_eq(_state.rejected_payload_count, 6)
	assert_eq(_state.snapshot(), before, "nothing of a malformed view was taken")
	assert_eq(_changes[0], 1)
	# A refused request is remembered, the conversation goes on.
	_state.apply_error(NpcDialogue.REASON_STALE_TURN)
	assert_eq(_state.last_error, NpcDialogue.REASON_STALE_TURN)
	assert_true(_state.open)
	assert_eq(_state.choices.size(), 3)
	# The next good view clears the error.
	assert_eq(_state.apply_view(_open_view(NPC_A, 2)), "")
	assert_eq(_state.last_error, "")
	# "You are in no conversation" brings a mirror that thought otherwise in line.
	_state.apply_error(NpcDialogue.REASON_NOT_TALKING, true)
	assert_false(_state.open)
	assert_eq(_state.choices, [])
	assert_eq(_state.last_error, NpcDialogue.REASON_NOT_TALKING)
	# An error before any conversation opens nothing.
	_state.apply_join()
	_state.apply_error(NpcDialogue.REASON_TOO_FAR)
	assert_false(_state.open)
	assert_eq(_state.last_error, NpcDialogue.REASON_TOO_FAR)
	assert_eq(_state.snapshot(), {})


func test_the_end_of_another_conversation_does_not_close_the_one_the_mirror_is_in() -> void:
	assert_eq(_state.apply_view(_open_view(NPC_B)), "")
	# Announced by the server (not the answer to a request).
	assert_eq(_state.apply_view(_closed_view(NPC_A), false), ClientDialogueState.REASON_OTHER_NPC)
	assert_true(_state.open)
	assert_eq(_state.npc_id, NPC_B)
	assert_eq(_state.ignored_view_count, 1)
	assert_eq(_state.rejected_payload_count, 0, "it was a valid view, only not ours")
	assert_eq(_closed.size(), 0)
	# The end of the conversation it is in closes it.
	assert_eq(_state.apply_view(_closed_view(NPC_B), false), "")
	assert_false(_state.open)
	# The ANSWER to a request is what the player's conversation is now: asking
	# another NPC ended the one the mirror was in, also when that NPC refuses.
	assert_eq(_state.apply_view(_open_view(NPC_B)), "")
	assert_eq(_state.apply_view(_closed_view(NPC_A, NpcDialogue.END_REFUSED, "싫어요.")), "")
	assert_false(_state.open)
	assert_eq(_state.npc_id, NPC_A)
	assert_eq(_state.choices, [])
	assert_eq(_closed.size(), 2)
	_state.apply_join()
	_closed.clear()
	assert_eq(_state.apply_view(_open_view(NPC_B)), "")
	assert_eq(_state.apply_view(_closed_view(NPC_B), false), "")
	# A refusal of another NPC while in no conversation is shown.
	assert_eq(_state.apply_view(_closed_view(NPC_A, NpcDialogue.END_REFUSED, "저리 가요.")), "")
	assert_eq(_state.npc_id, NPC_A)
	assert_eq(_state.line, "저리 가요.")
	assert_eq(_closed.size(), 2)
	assert_eq(_state.ignored_view_count, 1)


# ------------------------------------------------------------ the keys

func test_the_talk_key_names_the_nearest_living_npc_in_reach() -> void:
	var origin: Vector3 = Vector3(5.0, 0.0, 5.0)
	var npcs: Dictionary = {
		"npc_000003": {NpcNetProtocol.KEY_POSITION: Vector3(5.0, 0.0, 7.0), NpcNetProtocol.KEY_CONDITION: "ok"},
		"npc_000002": {NpcNetProtocol.KEY_POSITION: Vector3(5.0, 0.0, 3.0), NpcNetProtocol.KEY_CONDITION: "hurt"},
		"npc_000004": {NpcNetProtocol.KEY_POSITION: Vector3(5.0, 0.0, 5.5), NpcNetProtocol.KEY_CONDITION: "dead"},
		"npc_000005": {NpcNetProtocol.KEY_POSITION: Vector3(5.0, 9.0, 6.0), NpcNetProtocol.KEY_CONDITION: "ok"},
		"npc_000006": {NpcNetProtocol.KEY_POSITION: Vector3(40.0, 0.0, 5.0), NpcNetProtocol.KEY_CONDITION: "ok"},
		"npc_000007": {NpcNetProtocol.KEY_POSITION: "here"},
		"npc_000008": "not a row",
		9: {NpcNetProtocol.KEY_POSITION: origin},
	}
	assert_eq(NpcTalkIntentPolicy.nearest_npc_id(origin, npcs, 3.0), "npc_000005", "height does not count; a body is nobody to talk to")
	npcs.erase("npc_000005")
	assert_eq(NpcTalkIntentPolicy.nearest_npc_id(origin, npcs, 3.0), "npc_000002", "equal distances: the smaller id")
	assert_eq(NpcTalkIntentPolicy.nearest_npc_id(origin, npcs, 1.9), NpcTalkIntentPolicy.NO_NPC, "nobody in reach")
	assert_eq(NpcTalkIntentPolicy.nearest_npc_id(origin, npcs, 2.0), "npc_000002", "the reach itself counts")
	assert_eq(NpcTalkIntentPolicy.nearest_npc_id(origin, {}, 3.0), NpcTalkIntentPolicy.NO_NPC)
	for bad_range: float in [0.0, -1.0, NAN, INF]:
		assert_eq(NpcTalkIntentPolicy.nearest_npc_id(origin, npcs, bad_range), NpcTalkIntentPolicy.NO_NPC)
	assert_eq(NpcTalkIntentPolicy.nearest_npc_id(Vector3(NAN, 0.0, 0.0), npcs, 3.0), NpcTalkIntentPolicy.NO_NPC)
	assert_true(NpcTalkIntentPolicy.can_start(false, "npc_000002"))
	assert_false(NpcTalkIntentPolicy.can_start(true, "npc_000002"), "not while a conversation is open")
	assert_false(NpcTalkIntentPolicy.can_start(false, NpcTalkIntentPolicy.NO_NPC))


func test_a_number_key_names_the_answer_with_that_number() -> void:
	var choices: Array = _open_view()[NpcDialogue.KEY_CHOICES]
	assert_eq(NpcTalkIntentPolicy.choice_id_for_number(true, choices, 1), "greet")
	assert_eq(NpcTalkIntentPolicy.choice_id_for_number(true, choices, 2), "give:0")
	assert_eq(NpcTalkIntentPolicy.choice_id_for_number(true, choices, 3), "leave")
	for number: int in [0, -1, 4, 9, 100]:
		assert_eq(NpcTalkIntentPolicy.choice_id_for_number(true, choices, number), NpcTalkIntentPolicy.NO_CHOICE, str(number))
	assert_eq(NpcTalkIntentPolicy.choice_id_for_number(false, choices, 1), NpcTalkIntentPolicy.NO_CHOICE, "no conversation, no answer")
	assert_eq(NpcTalkIntentPolicy.choice_id_for_number(true, ["greet", ["leave"], [3, "셋"]], 1), NpcTalkIntentPolicy.NO_CHOICE)
	assert_eq(NpcTalkIntentPolicy.choice_id_for_number(true, ["greet", ["leave"], [3, "셋"]], 3), NpcTalkIntentPolicy.NO_CHOICE)
	# The keys are 1..9 and the two settings keys, registered as actions.
	var camera: CameraSettings = CameraSettings.new()
	var presentation: ClientPresentationSettings = ClientPresentationSettings.new()
	assert_eq(presentation.validate(), PackedStringArray())
	assert_eq(presentation.keys_shared_with(camera), PackedStringArray())
	ClientInputActions.register(camera, presentation)
	var digit_keys: Array[Key] = ClientInputActions.talk_choice_keys()
	assert_eq(digit_keys.size(), 9)
	assert_eq(digit_keys[0], KEY_1)
	assert_eq(digit_keys[4], KEY_5)
	assert_eq(digit_keys[8], KEY_9)
	var expected: Dictionary[StringName, Key] = {ClientInputActions.NPC_TALK: presentation.npc_talk_key, ClientInputActions.NPC_TALK_END: presentation.npc_talk_end_key, ClientInputActions.talk_choice_action(1): KEY_1, ClientInputActions.talk_choice_action(9): KEY_9}
	for action: StringName in expected:
		assert_true(InputMap.has_action(action), str(action))
		var events: Array[InputEvent] = InputMap.action_get_events(action)
		assert_eq(events.size(), 1, str(action))
		assert_eq((events[0] as InputEventKey).physical_keycode, expected[action], str(action))
	assert_eq(presentation.npc_talk_key, KEY_ENTER, "PROVISIONAL: every letter is taken")
	assert_eq(presentation.npc_talk_end_key, KEY_ESCAPE)
	# A talk key may not be a number key, or the same key as another.
	var on_digit: ClientPresentationSettings = ClientPresentationSettings.new()
	on_digit.npc_talk_end_key = KEY_7
	assert_ne(on_digit.validate(), PackedStringArray())
	var shared: ClientPresentationSettings = ClientPresentationSettings.new()
	shared.npc_talk_key = shared.trade_request_key
	assert_ne(shared.validate(), PackedStringArray())
	var unset: ClientPresentationSettings = ClientPresentationSettings.new()
	unset.npc_talk_key = KEY_NONE
	assert_ne(unset.validate(), PackedStringArray())


# ------------------------------------------------------------ the text

func test_every_reaction_and_end_reason_has_korean_text() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	assert_eq(NpcTalkPresentationFormatter.reaction_text("none"), "")
	assert_eq(NpcTalkPresentationFormatter.reaction_text("made_up"), "")
	var words: Dictionary = {}
	for reaction: String in NpcNetProtocol.REACTIONS:
		if reaction == NpcNetProtocol.REACTION_NONE:
			continue
		var word: String = NpcTalkPresentationFormatter.reaction_text(reaction)
		assert_false(word.is_empty(), reaction)
		assert_false(words.has(word), "each reaction has its own word: " + reaction)
		words[word] = true
	assert_eq(NpcTalkPresentationFormatter.reaction_text(NpcNetProtocol.REACTION_TALK), "대화 중")
	assert_eq(NpcTalkPresentationFormatter.reaction_tag("wary", settings), " [경계]")
	assert_eq(NpcTalkPresentationFormatter.reaction_tag("none", settings), "")
	# The tag: name, body, reaction. A body shows no reaction.
	assert_eq(NpcVisuals.tag_text("이름", "ok", settings, "talk"), "이름 [대화 중]")
	assert_eq(NpcVisuals.tag_text("이름", "hurt", settings, "afraid"), "이름" + settings.npc_hurt_tag_suffix + " [겁먹음]")
	assert_eq(NpcVisuals.tag_text("이름", "dead", settings, "talk"), "이름" + settings.npc_dead_tag_suffix)
	assert_eq(NpcVisuals.tag_text("이름", "ok", settings, "none"), "이름")
	assert_eq(NpcVisuals.tag_text("이름", "ok", settings), "이름")
	for end_reason: String in NpcDialogue.END_REASONS:
		var why: String = NpcTalkPresentationFormatter.end_reason_text(end_reason)
		assert_eq(why.is_empty(), end_reason == NpcDialogue.END_PLAYER_LEFT, end_reason)
		assert_not_contains(why, end_reason, "a known reason is said in words: " + end_reason)
	assert_contains(NpcTalkPresentationFormatter.end_reason_text("new_reason"), "new_reason", "an unknown reason is shown as it is")
	assert_eq(NpcTalkPresentationFormatter.format_result(true, ""), "")
	for reason: String in [NpcDialogue.REASON_TOO_FAR, NpcDialogue.REASON_NO_LINE_OF_SIGHT, NpcDialogue.REASON_NPC_DEAD, NpcDialogue.REASON_NPC_TALKING, NpcDialogue.REASON_NPC_BUSY, NpcDialogue.REASON_NPC_UNAVAILABLE, NpcDialogue.REASON_UNKNOWN_NPC, NpcDialogue.REASON_NOT_TALKING, NpcDialogue.REASON_STALE_TURN, NpcDialogue.REASON_BAD_CHOICE, NpcDialogue.REASON_UNAVAILABLE, NetworkService.RATE_LIMITED, "player_dead", "player_resting"]:
		var text: String = NpcTalkPresentationFormatter.format_result(false, reason)
		assert_false(text.is_empty(), reason)
		assert_not_contains(text, reason, "a known reason is said in words: " + reason)
	assert_contains(NpcTalkPresentationFormatter.format_result(false, "bad_turn"), "bad_turn")


func test_the_panel_shows_the_line_the_numbered_answers_and_the_keys() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var talk_key: String = ClientPresentationFormatter.key_label(settings.npc_talk_key)
	var end_key: String = ClientPresentationFormatter.key_label(settings.npc_talk_end_key)
	# Nobody near, no conversation: nothing.
	assert_eq(NpcTalkPresentationFormatter.build_lines({}, false, "", true, true, settings), PackedStringArray())
	# Somebody in reach: the hint.
	assert_eq(NpcTalkPresentationFormatter.build_lines({}, false, "한서윤", true, true, settings), PackedStringArray(["말 걸기 [%s]: 한서윤" % talk_key]))
	# An open conversation.
	var lines: PackedStringArray = NpcTalkPresentationFormatter.build_lines(_open_view(), false, "한서윤", true, true, settings)
	assert_eq(lines, PackedStringArray(["한서윤", "\"누구세요?\"", "1. 인사한다", "2. 통조림을 준다", "3. 떠난다", "답 고르기 [1-3] | 대화 끝내기 [%s]" % end_key]))
	# In the build mode the number keys belong to the build mode.
	var building: PackedStringArray = NpcTalkPresentationFormatter.build_lines(_open_view(), false, "", true, false, settings)
	assert_eq(building.size(), lines.size())
	assert_contains(building[building.size() - 1], "건축 모드")
	assert_contains(building[building.size() - 1], end_key)
	# A conversation that just ended: the last line and why, no answers.
	var ended: PackedStringArray = NpcTalkPresentationFormatter.build_lines(_closed_view(NPC_A, NpcDialogue.END_TOO_FAR, "어디 가요?"), true, "한서윤", true, true, settings)
	assert_eq(ended, PackedStringArray(["한서윤", "\"어디 가요?\"", "(%s)" % NpcTalkPresentationFormatter.end_reason_text(NpcDialogue.END_TOO_FAR)]))
	# The player left: only the parting line.
	assert_eq(NpcTalkPresentationFormatter.build_lines(_closed_view(NPC_A, NpcDialogue.END_PLAYER_LEFT, "잘 가요."), true, "", true, true, settings), PackedStringArray(["한서윤", "\"잘 가요.\""]))
	# After a moment the panel goes back to the hint (or to nothing).
	assert_eq(NpcTalkPresentationFormatter.build_lines(_closed_view(), false, "한서윤", true, true, settings), PackedStringArray(["말 걸기 [%s]: 한서윤" % talk_key]))
	assert_eq(NpcTalkPresentationFormatter.build_lines(_closed_view(), false, "", true, true, settings), PackedStringArray())
	# Nothing while dead.
	assert_eq(NpcTalkPresentationFormatter.build_lines(_open_view(), false, "한서윤", false, true, settings), PackedStringArray())
	# More answers than number keys: the hint names the keys there are.
	var many: Dictionary = _open_view()
	var entries: Array = []
	for index: int in 11:
		entries.append(["give:%d" % index, "준다 %d" % index])
	many[NpcDialogue.KEY_CHOICES] = entries
	var many_lines: PackedStringArray = NpcTalkPresentationFormatter.build_lines(many, false, "", true, true, settings)
	assert_contains(many_lines[many_lines.size() - 1], "[1-9]")
	assert_eq(many_lines.size(), 2 + 11 + 1)


func test_the_name_tag_of_an_npc_shows_its_reaction() -> void:
	var settings: NpcNetSettings = NpcNetSettings.new()
	var mirror: ClientNpcState = ClientNpcState.new(settings)
	var source: Dictionary = {
		NpcNetProtocol.KEY_NPC_ID: NPC_A,
		NpcNetProtocol.KEY_NAME: "한서윤",
		NpcNetProtocol.KEY_APPEARANCE: {"body_scale": "average"},
		NpcNetProtocol.KEY_POSITION: Vector3(3.0, 0.0, 4.0),
		NpcNetProtocol.KEY_YAW: 0.0,
		NpcNetProtocol.KEY_ACTION_LABEL: "idle",
		NpcNetProtocol.KEY_POSTURE: "standing",
		NpcNetProtocol.KEY_CONDITION: "ok",
		NpcNetProtocol.KEY_REACTION: "wary",
	}
	assert_eq(mirror.apply_join({NpcNetProtocol.KEY_TICK: 1, NpcNetProtocol.KEY_EVENT_SEQUENCE: 0, NpcNetProtocol.KEY_ROWS: [NpcNetProtocol.encode_public_row(source)]}), "")
	var root: Node3D = Node3D.new()
	var presentation: ClientPresentationSettings = ClientPresentationSettings.new()
	var visuals: NpcVisuals = NpcVisuals.new(root, presentation)
	visuals.sync(mirror.npcs)
	assert_eq(visuals.label_of(NPC_A).text, "한서윤 [경계]")
	assert_eq(mirror.apply_events(2, 1, [NpcNetProtocol.reaction_changed_event(NPC_A, "talk", 2.0)]), "")
	visuals.sync(mirror.npcs)
	assert_eq(visuals.label_of(NPC_A).text, "한서윤 [대화 중]")
	assert_eq(mirror.apply_events(3, 2, [NpcNetProtocol.reaction_changed_event(NPC_A, "none", 3.0)]), "")
	visuals.sync(mirror.npcs)
	assert_eq(visuals.label_of(NPC_A).text, "한서윤")
	root.free()
