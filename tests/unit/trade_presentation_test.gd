extends TestCase
## P2-T16 client side, pure logic (no nodes; docs/09 §14.30, docs/11 §2.14):
## the trade keys, what they mean in which state of the mirrored session,
## how many units an offer key asks for, the HUD block and the texts. The
## client only names things; the server decides
## (tests/unit/trade_service_test.gd).

const FOOD_ID: String = "dev_food_ration"
const WATER_ID: String = "dev_water_bottle"
const BANDAGE_ID: String = "dev_bandage"
const ME: String = "player_000001"
const OTHER: String = "player_000002"
const THIRD: String = "player_000003"
const NAMES: Dictionary = {ME: "영희", OTHER: "민수", THIRD: "철수"}


func after_each() -> void:
	# Leave no action behind: other tests register them with other settings.
	for action: StringName in InputMap.get_actions():
		if not str(action).begins_with("ui_"):
			InputMap.erase_action(action)


func _entry(item_id: Variant, definition_id: Variant, quantity: Variant, slot: Variant = "slot_0") -> Dictionary:
	return {"schema_version": 1, "item_instance_id": item_id, "definition_id": definition_id, "quantity": quantity, "location_type": "inventory", "location_id": "inventory_000001", "slot_id": slot}


## A session state as the server sends it to the party ME.
func _state(phase: String, requester_id: String, changes: Dictionary = {}) -> Dictionary:
	var state: Dictionary = {
		"session_id": 3,
		"phase": phase,
		"requester_id": requester_id,
		"target_id": OTHER if requester_id == ME else ME,
		"revision": 0,
		"my_offer": [],
		"their_offer": [],
		"my_confirmed": false,
		"their_confirmed": false,
		"change": TradeService.CHANGE_OPENED,
		"outcome": "",
		"cause": "",
		"by_player_id": "",
		"world_time": 1.0,
	}
	state.merge(changes, true)
	return state


func _closed(cause: String, by_player_id: String, requester_id: String = ME) -> Dictionary:
	return _state(TradeSession.PHASE_CLOSED, requester_id, {"change": TradeService.CHANGE_CLOSED, "outcome": TradeSession.OUTCOME_CANCELLED, "cause": cause, "by_player_id": by_player_id})


# ------------------------------------------------------------ keys

func test_trade_keys_are_actions_driven_by_settings_and_clash_with_no_other_key() -> void:
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	var defaults: ClientPresentationSettings = ClientPresentationSettings.new()
	var trade_keys: PackedStringArray = ["trade_request_key", "trade_accept_key", "trade_decline_key", "trade_offer_add_key", "trade_offer_remove_key"]
	for property: String in ["trade_request_key", "trade_accept_key", "trade_decline_key", "trade_offer_add_key", "trade_offer_remove_key", "trade_offer_step", "trade_min_interval_sec"]:
		assert_eq(defaults.get(property), shipped.get(property), "the script default of %s agrees with the shipped resource" % property)
	assert_eq(shipped.trade_request_key, KEY_T)
	assert_eq(shipped.trade_accept_key, KEY_Y)
	assert_eq(shipped.trade_decline_key, KEY_N)
	assert_eq(shipped.trade_offer_add_key, KEY_O)
	assert_eq(shipped.trade_offer_remove_key, KEY_P)
	assert_eq(shipped.trade_offer_step, 1, "one unit per key press")
	ClientInputActions.register(CameraSettings.new(), defaults)
	var expected: Dictionary[StringName, Key] = {
		ClientInputActions.TRADE_REQUEST: defaults.trade_request_key,
		ClientInputActions.TRADE_ACCEPT: defaults.trade_accept_key,
		ClientInputActions.TRADE_DECLINE: defaults.trade_decline_key,
		ClientInputActions.TRADE_OFFER_ADD: defaults.trade_offer_add_key,
		ClientInputActions.TRADE_OFFER_REMOVE: defaults.trade_offer_remove_key,
	}
	for action: StringName in expected:
		var events: Array[InputEvent] = InputMap.action_get_events(action)
		assert_eq(events.size(), 1, str(action))
		assert_eq((events[0] as InputEventKey).physical_keycode, expected[action], str(action))
	# Validation: every key set, at least one unit, a positive interval.
	var invalid: ClientPresentationSettings = ClientPresentationSettings.new()
	for key_name: String in trade_keys:
		invalid.set(key_name, KEY_NONE)
	invalid.trade_offer_step = 0
	invalid.trade_min_interval_sec = 0.0
	assert_eq(invalid.validate().size(), 7, "; ".join(invalid.validate()))
	# No trade key is any other key of the client: every pair is checked.
	var own: Dictionary[String, Key] = defaults.assigned_keys()
	# 17 since the cell overlay key (P3-2, world_map_presentation_test.gd), 22
	# since the five container keys (P3-3, container_presentation_test.gd), 30
	# since the nine building keys (P3-3b/P3-4b, build_presentation_test.gd),
	# 32 since the NPC debug overlay key (P4-8, F4); 34 since the NPC talk and
	# talk end keys (F-31, Enter and Escape).
	assert_eq(own.size(), 34, "every key of the presentation settings is in the list: %s" % ", ".join(PackedStringArray(own.keys())))
	for changed: String in trade_keys:
		assert_true(own.has(changed), changed)
		for other: String in own:
			if other == changed:
				continue
			var shared: ClientPresentationSettings = ClientPresentationSettings.new()
			shared.set(changed, own[other])
			assert_eq(shared.validate().size(), 1, "%s must differ from %s: %s" % [changed, other, "; ".join(shared.validate())])
	# Nor a movement or pickup key (those belong to the camera settings).
	var camera: CameraSettings = CameraSettings.load_or_default()
	assert_eq(shipped.keys_shared_with(camera).size(), 0, "the shipped keys do not clash: %s" % ", ".join(shipped.keys_shared_with(camera)))
	var clashing: ClientPresentationSettings = ClientPresentationSettings.new()
	clashing.trade_accept_key = camera.move_forward_key
	clashing.trade_request_key = camera.pickup_key
	assert_eq(clashing.keys_shared_with(camera), PackedStringArray(["trade_request_key", "trade_accept_key"]))


# ------------------------------------------------------------ what the keys mean

func test_what_the_trade_keys_mean_in_each_state_of_the_session() -> void:
	const NO_SESSION: String = ""
	# The request key asks only while the local player is in no trade.
	assert_true(TradeIntentPolicy.can_request(NO_SESSION))
	assert_false(TradeIntentPolicy.can_request(TradeSession.PHASE_REQUESTED))
	assert_false(TradeIntentPolicy.can_request(TradeSession.PHASE_OPEN))
	# The accept key: answers a request addressed to me, confirms in a session
	# and takes a confirmation back. It does nothing to my own request.
	assert_eq(TradeIntentPolicy.accept_action(NO_SESSION, false, false), TradeIntentPolicy.AcceptAction.NONE)
	assert_eq(TradeIntentPolicy.accept_action(TradeSession.PHASE_REQUESTED, false, false), TradeIntentPolicy.AcceptAction.ACCEPT, "I was asked")
	assert_eq(TradeIntentPolicy.accept_action(TradeSession.PHASE_REQUESTED, true, false), TradeIntentPolicy.AcceptAction.NONE, "nobody accepts its own request")
	assert_eq(TradeIntentPolicy.accept_action(TradeSession.PHASE_OPEN, false, false), TradeIntentPolicy.AcceptAction.CONFIRM)
	assert_eq(TradeIntentPolicy.accept_action(TradeSession.PHASE_OPEN, true, false), TradeIntentPolicy.AcceptAction.CONFIRM)
	assert_eq(TradeIntentPolicy.accept_action(TradeSession.PHASE_OPEN, true, true), TradeIntentPolicy.AcceptAction.UNCONFIRM, "pressing it again takes the confirmation back")
	assert_eq(TradeIntentPolicy.accept_action(TradeSession.PHASE_CLOSED, true, false), TradeIntentPolicy.AcceptAction.NONE)
	# The decline key: declines, withdraws or cancels.
	assert_eq(TradeIntentPolicy.decline_action(NO_SESSION, false), TradeIntentPolicy.DeclineAction.NONE)
	assert_eq(TradeIntentPolicy.decline_action(TradeSession.PHASE_REQUESTED, false), TradeIntentPolicy.DeclineAction.DECLINE)
	assert_eq(TradeIntentPolicy.decline_action(TradeSession.PHASE_REQUESTED, true), TradeIntentPolicy.DeclineAction.WITHDRAW)
	assert_eq(TradeIntentPolicy.decline_action(TradeSession.PHASE_OPEN, false), TradeIntentPolicy.DeclineAction.CANCEL)
	assert_eq(TradeIntentPolicy.decline_action(TradeSession.PHASE_OPEN, true), TradeIntentPolicy.DeclineAction.CANCEL)
	assert_eq(TradeIntentPolicy.decline_action(TradeSession.PHASE_CLOSED, true), TradeIntentPolicy.DeclineAction.NONE)


func test_how_many_units_an_offer_key_asks_for() -> void:
	var inventory: Array[Dictionary] = [
		_entry("item_000001", FOOD_ID, 3),
		_entry("item_000002", BANDAGE_ID, 1, "slot_1"),
		_entry("item_000003", WATER_ID, "many", "slot_2"),
	]
	var nothing: Array = []
	var offer: Array = [{"item_instance_id": "item_000001", "definition_id": FOOD_ID, "quantity": 2}, {"item_instance_id": "item_000009", "definition_id": WATER_ID, "quantity": 2}]
	# Adding: one more unit of the selected stack, up to what the mirror says
	# the stack holds.
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, nothing, "item_000001", 1), 1, "the first unit")
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, offer, "item_000001", 1), 3)
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, offer, "item_000001", 5), 3, "never more than the stack holds")
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, nothing, "item_000002", 3), 1)
	var full: Array = [{"item_instance_id": "item_000001", "definition_id": FOOD_ID, "quantity": 3}]
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, full, "item_000001", 1), TradeIntentPolicy.NO_CHANGE, "everything is offered already")
	# Removing: fewer units, down to 0 = out of the offer.
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, offer, "item_000001", -1), 1)
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, offer, "item_000001", -2), 0, "the last unit takes the stack out of the offer")
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, offer, "item_000001", -9), 0)
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, nothing, "item_000001", -1), TradeIntentPolicy.NO_CHANGE, "nothing of it is offered")
	# An offered stack that is not carried any more can only come out.
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, offer, "item_000009", 1), 0)
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, offer, "item_000009", -1), 0)
	# Nothing to ask for.
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, nothing, "item_999999", 1), TradeIntentPolicy.NO_CHANGE, "an item that is not in the mirror")
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, nothing, "", 1), TradeIntentPolicy.NO_CHANGE, "nothing selected")
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, nothing, "item_000003", 1), TradeIntentPolicy.NO_CHANGE, "a malformed mirror row")
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, offer, "item_000001", 0), TradeIntentPolicy.NO_CHANGE, "no step, no change")
	var malformed_offer: Array = ["junk", {"item_instance_id": "item_000001"}, {"item_instance_id": "item_000001", "definition_id": FOOD_ID, "quantity": 2}]
	assert_eq(TradeIntentPolicy.offer_quantity_after(inventory, malformed_offer, "item_000001", 1), 3, "malformed offer rows are skipped")
	assert_true(TradeIntentPolicy.NO_CHANGE < 0, "\"nothing\" is no quantity the server accepts")


# ------------------------------------------------------------ HUD

func test_the_trade_hud_shows_whom_to_ask_the_request_and_both_offers() -> void:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var food: String = catalog.get_definition(FOOD_ID).display_name
	var water: String = catalog.get_definition(WATER_ID).display_name
	var bandage: String = catalog.get_definition(BANDAGE_ID).display_name
	# No trade: whom the request key would ask.
	assert_eq(ClientPresentationFormatter.build_trade_lines({}, ME, NAMES, "민수", true, catalog, settings), PackedStringArray(["거래 요청 [T]: 민수"]))
	assert_eq(ClientPresentationFormatter.build_trade_lines({}, ME, NAMES, "", true, catalog, settings), PackedStringArray(["거래 요청 [T]: 상대 없음 (가까이서 바라보기)"]))
	assert_true(ClientPresentationFormatter.build_trade_lines({}, ME, NAMES, "민수", false, catalog, settings).is_empty(), "a dead character asks nobody")
	# A request that waits for its answer.
	assert_eq(ClientPresentationFormatter.build_trade_lines(_state(TradeSession.PHASE_REQUESTED, ME), ME, NAMES, "", true, catalog, settings), PackedStringArray(["거래 요청 중: 민수 | 취소 [N]"]), "I asked")
	assert_eq(ClientPresentationFormatter.build_trade_lines(_state(TradeSession.PHASE_REQUESTED, OTHER), ME, NAMES, "", true, catalog, settings), PackedStringArray(["민수의 거래 요청 | 수락 [Y] 거절 [N]"]), "I was asked")
	assert_eq(ClientPresentationFormatter.build_trade_lines(_state(TradeSession.PHASE_REQUESTED, OTHER), ME, {}, "", true, catalog, settings)[0], "%s의 거래 요청 | 수락 [Y] 거절 [N]" % OTHER, "without names the ids are shown")
	# An open session: both offers and both confirmation states.
	var open: Dictionary = _state(TradeSession.PHASE_OPEN, ME, {
		"revision": 3,
		"my_offer": [{"item_instance_id": "item_000001", "definition_id": FOOD_ID, "quantity": 2}, {"item_instance_id": "item_000002", "definition_id": BANDAGE_ID, "quantity": 1}],
		"their_offer": [{"definition_id": WATER_ID, "quantity": 3}],
		"their_confirmed": true,
	})
	assert_eq(ClientPresentationFormatter.build_trade_lines(open, ME, NAMES, "", true, catalog, settings), PackedStringArray([
		"거래 중: 민수",
		"내 제안 (미확정): %s x2, %s x1" % [food, bandage],
		"상대 제안 (확정): %s x3" % water,
		"올리기 [O] 내리기 [P] | 확정 [Y] | 거래 취소 [N]",
	]))
	open["my_confirmed"] = true
	open["their_confirmed"] = false
	open["their_offer"] = []
	var confirmed: PackedStringArray = ClientPresentationFormatter.build_trade_lines(open, ME, NAMES, "", true, catalog, settings)
	assert_eq(confirmed[1], "내 제안 (확정): %s x2, %s x1" % [food, bandage])
	assert_eq(confirmed[2], "상대 제안 (미확정): (없음)", "an empty offer is shown as such")
	assert_eq(confirmed[3], "올리기 [O] 내리기 [P] | 확정 취소 [Y] | 거래 취소 [N]", "the accept key takes the confirmation back now")
	# The keys come from the settings; without a catalog the ids are shown.
	settings.trade_request_key = KEY_K
	settings.trade_accept_key = KEY_ENTER
	settings.trade_decline_key = KEY_BACKSPACE
	settings.trade_offer_add_key = KEY_EQUAL
	settings.trade_offer_remove_key = KEY_MINUS
	assert_eq(ClientPresentationFormatter.build_trade_lines({}, ME, NAMES, "민수", true, catalog, settings)[0], "거래 요청 [K]: 민수")
	var custom: PackedStringArray = ClientPresentationFormatter.build_trade_lines(open, ME, NAMES, "", true, null, settings)
	assert_eq(custom[1], "내 제안 (확정): %s x2, %s x1" % [FOOD_ID, BANDAGE_ID])
	assert_eq(custom[3], "올리기 [Equal] 내리기 [Minus] | 확정 취소 [Enter] | 거래 취소 [Backspace]")
	# The offer text alone.
	assert_eq(ClientPresentationFormatter.format_trade_offer([], catalog), "(없음)")
	assert_eq(ClientPresentationFormatter.format_trade_offer([{"definition_id": "not_in_this_catalog", "quantity": 4}, "junk", {"definition_id": WATER_ID}], catalog), "not_in_this_catalog x4", "unknown definitions by id, malformed rows skipped")


func test_result_sentences_closed_texts_and_the_bystanders_line() -> void:
	# An accepted request needs no text: the HUD shows the new state.
	assert_eq(ClientPresentationFormatter.format_trade_result(true, ""), "")
	var sentences: Dictionary[String, String] = {
		TradeService.REASON_TARGET_TOO_FAR: "멉니다",
		TradeService.REASON_TARGET_DEAD: "사망",
		TradeService.REASON_TARGET_UNAVAILABLE: "없습니다",
		TradeService.REASON_TARGET_RESTING: "자고",
		TradeService.REASON_TARGET_BUSY: "다른 거래",
		TradeService.REASON_TARGET_IS_SELF: "자신",
		TradeService.REASON_ALREADY_TRADING: "이미 거래",
		TradeService.REASON_STALE_OFFER: "바뀌었",
		TradeService.REASON_OFFER_CHANGED: "바뀌었",
		TradeService.REASON_NOTHING_OFFERED: "올린",
		TradeService.REASON_INVENTORY_FULL: "내 소지품",
		TradeService.REASON_OTHER_INVENTORY_FULL: "상대의 소지품",
		TradeService.REASON_OFFER_FULL: "더 올릴",
		TradeService.REASON_SESSION_CANCELLED: "끝났",
		TradeService.REASON_NOT_IN_SESSION: "끝났",
		TradeService.REASON_NO_SUCH_REQUEST: "끝났",
		InventoryService.REASON_NOT_IN_INVENTORY: "가지고 있지",
		InventoryService.REASON_BAD_QUANTITY: "수량",
	}
	for reason: String in sentences:
		var text: String = ClientPresentationFormatter.format_trade_result(false, reason)
		assert_true(text.begins_with("거래 거부: "), text)
		assert_contains(text, sentences[reason], reason)
		assert_not_contains(text, reason, "a sentence, not the code: " + reason)
	# Everything else keeps its code, so nothing is hidden from the player.
	for reason: String in [NetworkService.RATE_LIMITED, SurvivalService.REASON_PLAYER_RESTING, SurvivalService.REASON_PLAYER_DEAD, TradeService.REASON_OFFER_UNCHANGED]:
		assert_eq(ClientPresentationFormatter.format_trade_result(false, reason), "거래 거부: %s" % reason)

	# How a trade ended, for the two parties.
	var completed: Dictionary = _state(TradeSession.PHASE_CLOSED, ME, {"change": TradeService.CHANGE_CLOSED, "outcome": TradeSession.OUTCOME_COMPLETED})
	assert_eq(ClientPresentationFormatter.format_trade_closed(completed, ME, NAMES), "거래 완료: 민수")
	assert_eq(ClientPresentationFormatter.format_trade_closed(completed, ME, {}), "거래 완료: %s" % OTHER)
	var endings: Array[Array] = [
		[TradeService.CAUSE_DECLINED, OTHER, "민수이(가) 거래 요청을 거절했습니다"],
		[TradeService.CAUSE_DECLINED, ME, "거래 요청을 거절했습니다"],
		[TradeService.CAUSE_WITHDRAWN, OTHER, "민수이(가) 거래 요청을 취소했습니다"],
		[TradeService.CAUSE_WITHDRAWN, ME, "거래 요청을 취소했습니다"],
		[TradeService.CAUSE_CANCELLED, OTHER, "민수이(가) 거래를 취소했습니다"],
		[TradeService.CAUSE_CANCELLED, ME, "거래를 취소했습니다"],
		[TradeService.CAUSE_TOO_FAR, "", "거래 취소: 서로 너무 멀어졌습니다"],
		[TradeService.CAUSE_PLAYER_DEAD, OTHER, "거래 취소: 상대가 사망했습니다"],
		[TradeService.CAUSE_PLAYER_DEAD, ME, "거래 취소: 사망했습니다"],
		[TradeService.CAUSE_PLAYER_RESTING, OTHER, "거래 취소: 상대가 잠들었습니다"],
		[TradeService.CAUSE_PLAYER_RESTING, ME, "거래 취소: 잠들었습니다"],
		[TradeService.CAUSE_DISCONNECTED, OTHER, "거래 취소: 상대가 접속을 끊었습니다"],
		[TradeService.CAUSE_NEW_CHARACTER, OTHER, "거래 취소: 상대가 새 캐릭터를 시작했습니다"],
		[TradeService.CAUSE_NEW_CHARACTER, ME, "거래 취소: 새 캐릭터를 시작했습니다"],
		[TradeService.CAUSE_REQUEST_TIMEOUT, "", "거래 요청이 응답 없이 취소됐습니다"],
		[TradeService.CAUSE_IDLE_TIMEOUT, "", "거래 취소: 오랫동안 진행이 없었습니다"],
		["some_future_cause", "", "거래 취소: some_future_cause"],
	]
	for ending: Array in endings:
		assert_eq(ClientPresentationFormatter.format_trade_closed(_closed(str(ending[0]), str(ending[1])), ME, NAMES), str(ending[2]), "%s by '%s'" % [ending[0], ending[1]])
	assert_eq(ClientPresentationFormatter.format_trade_closed({}, ME, NAMES), "")
	assert_eq(ClientPresentationFormatter.format_trade_closed(_state(TradeSession.PHASE_OPEN, ME), ME, NAMES), "", "an open session did not end")

	# Changes inside a session that deserve a notice.
	var failed_other: Dictionary = _state(TradeSession.PHASE_OPEN, ME, {"change": TradeService.CHANGE_EXCHANGE_FAILED, "cause": TradeService.CAUSE_INVENTORY_FULL, "by_player_id": OTHER})
	assert_eq(ClientPresentationFormatter.format_trade_change(failed_other, ME), "교환 실패: 상대의 소지품에 자리가 없습니다")
	var failed_mine: Dictionary = _state(TradeSession.PHASE_OPEN, ME, {"change": TradeService.CHANGE_EXCHANGE_FAILED, "cause": TradeService.CAUSE_INVENTORY_FULL, "by_player_id": ME})
	assert_eq(ClientPresentationFormatter.format_trade_change(failed_mine, ME), "교환 실패: 내 소지품에 자리가 없습니다")
	assert_eq(ClientPresentationFormatter.format_trade_change(_state(TradeSession.PHASE_OPEN, ME, {"change": TradeService.CHANGE_EXCHANGE_FAILED, "cause": "something"}), ME), "교환 실패: something")
	assert_eq(ClientPresentationFormatter.format_trade_change(_state(TradeSession.PHASE_OPEN, ME, {"change": TradeService.CHANGE_OFFER_ADJUSTED}), ME), "제안이 소지품에 맞게 바뀌었습니다. 다시 확정하세요")
	for quiet: String in [TradeService.CHANGE_REQUESTED, TradeService.CHANGE_OPENED, TradeService.CHANGE_OFFER, TradeService.CHANGE_CONFIRMED, TradeService.CHANGE_UNCONFIRMED, TradeService.CHANGE_CLOSED]:
		assert_eq(ClientPresentationFormatter.format_trade_change(_state(TradeSession.PHASE_OPEN, ME, {"change": quiet}), ME), "", quiet + " needs no notice")

	# What a bystander is told: that the two traded. Never what.
	var notice: Dictionary = {"player_ids": [ME, OTHER], "world_time": 1.0}
	assert_eq(ClientPresentationFormatter.format_trade_notice(notice, NAMES), "영희 ↔ 민수 거래")
	assert_eq(ClientPresentationFormatter.format_trade_notice(notice, {}), "%s ↔ %s 거래" % [ME, OTHER], "without names the ids are shown")
	var leaky: Dictionary = notice.duplicate(true)
	leaky["definition_id"] = FOOD_ID
	leaky["quantity"] = 2
	assert_eq(ClientPresentationFormatter.format_trade_notice(leaky, NAMES), "영희 ↔ 민수 거래", "a bystander's line cannot name an item even when a malformed caller passes one along")
	assert_eq(ClientPresentationFormatter.format_trade_notice({}, NAMES), "")
	assert_eq(ClientPresentationFormatter.format_trade_notice({"player_ids": [ME]}, NAMES), "")
	assert_ne(ClientPresentationFormatter.format_trade_notice(notice, NAMES), ClientPresentationFormatter.format_treatment_notice({"scope": "public", "user_id": ME, "target_id": OTHER, "world_time": 1.0}, NAMES, null), "a trade is told apart from tending")
