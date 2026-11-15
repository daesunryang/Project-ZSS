extends TestCase
## P2-T14 client side, pure logic (no nodes): the hand-over modifier key, what
## a use key means with which modifier held, how many units are asked for,
## the HUD target line and the texts. The client only names an item, a target
## and a quantity; the server decides (tests/unit/hand_over_test.gd).

const FOOD_ID: String = "dev_food_ration"
const BANDAGE_ID: String = "dev_bandage"
const GIVER: String = "player_000001"
const RECEIVER: String = "player_000002"


func _entry(item_id: Variant, definition_id: Variant, quantity: Variant) -> Dictionary:
	return {"schema_version": 1, "item_instance_id": item_id, "definition_id": definition_id, "quantity": quantity, "location_type": "inventory", "location_id": "inventory_000001", "slot_id": "slot_0"}


func test_the_hand_over_modifier_is_a_key_of_its_own_driven_by_settings() -> void:
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_eq(shipped.hand_over_modifier_key, KEY_CTRL)
	assert_eq(shipped.hand_over_quantity, 1, "one unit per key press")
	var defaults: ClientPresentationSettings = ClientPresentationSettings.new()
	assert_eq(defaults.hand_over_modifier_key, shipped.hand_over_modifier_key, "the script default agrees with the shipped resource")
	assert_eq(defaults.hand_over_quantity, shipped.hand_over_quantity)
	assert_ne(defaults.hand_over_modifier_key, defaults.treat_other_modifier_key, "handing over and using on another player are different keys")
	ClientInputActions.register(CameraSettings.new(), defaults)
	var events: Array[InputEvent] = InputMap.action_get_events(ClientInputActions.HAND_OVER)
	assert_eq(events.size(), 1)
	assert_eq((events[0] as InputEventKey).physical_keycode, defaults.hand_over_modifier_key)
	# The other use actions are untouched.
	assert_eq(InputMap.action_get_events(ClientInputActions.TREAT_OTHER).size(), 1)
	assert_eq(ClientInputActions.USE_ACTION_KINDS.size(), 4, "the same four use keys")
	# Validation: set, at least one unit, and different from every other key.
	var invalid: ClientPresentationSettings = ClientPresentationSettings.new()
	invalid.hand_over_modifier_key = KEY_NONE
	invalid.hand_over_quantity = 0
	assert_eq(invalid.validate().size(), 2, "; ".join(invalid.validate()))
	for other: Key in [defaults.treat_other_modifier_key, defaults.consume_key, defaults.drink_key, defaults.bandage_key, defaults.cure_key, defaults.rest_key, defaults.prone_key]:
		var shared: ClientPresentationSettings = ClientPresentationSettings.new()
		shared.hand_over_modifier_key = other
		assert_eq(shared.validate().size(), 1, "the hand-over modifier must differ from %s: %s" % [OS.get_keycode_string(other), "; ".join(shared.validate())])


func test_what_a_use_key_means_with_which_modifier() -> void:
	for kind: ConsumeIntentPolicy.Kind in [ConsumeIntentPolicy.Kind.FOOD, ConsumeIntentPolicy.Kind.DRINK, ConsumeIntentPolicy.Kind.BANDAGE, ConsumeIntentPolicy.Kind.CURE]:
		assert_eq(ConsumeIntentPolicy.use_mode(kind, false, false), ConsumeIntentPolicy.UseMode.ON_SELF, "no modifier: use it myself")
		assert_eq(ConsumeIntentPolicy.use_mode(kind, true, false), ConsumeIntentPolicy.UseMode.ON_OTHER, "the treat-other modifier: use it on the other player")
		assert_eq(ConsumeIntentPolicy.use_mode(kind, false, true), ConsumeIntentPolicy.UseMode.HAND_OVER, "the hand-over modifier: hand it over")
		assert_eq(ConsumeIntentPolicy.use_mode(kind, true, true), ConsumeIntentPolicy.UseMode.HAND_OVER, "both held: handing over wins (the item is kept, nothing is used up)")


func test_how_many_units_a_hand_over_key_asks_for() -> void:
	var inventory: Array[Dictionary] = [
		_entry("item_000001", BANDAGE_ID, 1),
		_entry("item_000002", FOOD_ID, 3),
		_entry("item_000003", FOOD_ID, "many"),
		{"item_instance_id": "item_000004"},
	]
	assert_eq(ConsumeIntentPolicy.hand_over_quantity(inventory, "item_000002", 1), 1, "the configured quantity")
	assert_eq(ConsumeIntentPolicy.hand_over_quantity(inventory, "item_000002", 3), 3)
	assert_eq(ConsumeIntentPolicy.hand_over_quantity(inventory, "item_000002", 5), 3, "never more than the mirrored stack holds")
	assert_eq(ConsumeIntentPolicy.hand_over_quantity(inventory, "item_000001", 5), 1)
	assert_eq(ConsumeIntentPolicy.hand_over_quantity(inventory, "item_000002", 0), 0, "nothing to ask for")
	assert_eq(ConsumeIntentPolicy.hand_over_quantity(inventory, "item_000002", -2), 0)
	assert_eq(ConsumeIntentPolicy.hand_over_quantity(inventory, "item_999999", 1), 0, "an item that is not in the mirror")
	assert_eq(ConsumeIntentPolicy.hand_over_quantity(inventory, "item_000003", 1), 0, "a malformed mirror row")
	assert_eq(ConsumeIntentPolicy.hand_over_quantity(inventory, "item_000004", 1), 0)
	assert_eq(ConsumeIntentPolicy.hand_over_quantity([] as Array[Dictionary], "item_000002", 1), 0)


func test_the_hud_target_line_names_the_hand_over_keys() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var lines: PackedStringArray = ClientPresentationFormatter.build_treat_target_lines({"alive": true}, "민수", settings)
	assert_eq(lines, PackedStringArray(["줄 대상: 민수 | 음식 [Shift+F] 물 [Shift+G] 붕대 [Shift+B] 치료제 [Shift+V] | 건네기 [Ctrl+F/G/B/V]"]), "one line: the use keys as before, then the hand-over keys in short")
	settings.hand_over_modifier_key = KEY_ALT
	settings.consume_key = KEY_T
	settings.cure_key = KEY_N
	assert_contains(ClientPresentationFormatter.build_treat_target_lines({"alive": true}, "민수", settings)[0], "건네기 [Alt+T/G/B/N]", "the keys come from the settings")
	assert_eq(ClientPresentationFormatter.build_treat_target_lines({"alive": true}, "", settings), PackedStringArray(["줄 대상: 없음 (가까이서 바라보기)"]), "nobody in reach: no key list")
	assert_true(ClientPresentationFormatter.build_treat_target_lines({"alive": false}, "민수", settings).is_empty(), "a dead character hands nothing over")
	assert_true(ClientPresentationFormatter.build_treat_target_lines({}, "민수", settings).is_empty(), "no owner mirror, no line")


func test_result_sentences_and_notice_lines() -> void:
	assert_eq(ClientPresentationFormatter.format_hand_over_result(true, ""), "건네기 승인")
	# What the giver can do something about is told as a sentence.
	var sentences: Dictionary[String, String] = {
		ServerWorld.REASON_TARGET_TOO_FAR: "멉니다",
		ServerWorld.REASON_TARGET_DEAD: "사망",
		ServerWorld.REASON_TARGET_UNAVAILABLE: "없습니다",
		ServerWorld.REASON_TARGET_INVENTORY_FULL: "가득",
		ServerWorld.REASON_TARGET_IS_SELF: "자신",
		InventoryService.REASON_BAD_QUANTITY: "수량",
		InventoryService.REASON_NOT_IN_INVENTORY: "가지고 있지",
	}
	for reason: String in sentences:
		var text: String = ClientPresentationFormatter.format_hand_over_result(false, reason)
		assert_true(text.begins_with("건네기 거부: "), text)
		assert_contains(text, sentences[reason], reason)
		assert_not_contains(text, reason, "a sentence, not the code: " + reason)
	# Everything else keeps its code, so nothing is hidden from the player.
	for reason: String in [NetworkService.RATE_LIMITED, SurvivalService.REASON_PLAYER_RESTING, SurvivalService.REASON_PLAYER_DEAD]:
		assert_eq(ClientPresentationFormatter.format_hand_over_result(false, reason), "건네기 거부: %s" % reason)
	# Notices: the receiver is told who, what and how many; a bystander only
	# that one player handed something to another.
	var names: Dictionary = {GIVER: "영희", RECEIVER: "민수"}
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var food_name: String = catalog.get_definition(FOOD_ID).display_name
	assert_false(food_name.is_empty(), "the shipped food has a name")
	var received: Dictionary = {"scope": "target", "giver_id": GIVER, "receiver_id": RECEIVER, "definition_id": FOOD_ID, "quantity": 2, "world_time": 1.0}
	assert_eq(ClientPresentationFormatter.format_hand_over_notice(received, names, catalog), "영희이(가) 나에게 %s x2 건넴" % food_name)
	assert_eq(ClientPresentationFormatter.format_hand_over_notice(received, {}, catalog), "%s이(가) 나에게 %s x2 건넴" % [GIVER, food_name], "without names the ids are shown")
	var unknown: Dictionary = received.duplicate()
	unknown["definition_id"] = "not_in_this_catalog"
	assert_contains(ClientPresentationFormatter.format_hand_over_notice(unknown, names, catalog), "not_in_this_catalog x2", "an unknown definition is shown by its id")
	assert_contains(ClientPresentationFormatter.format_hand_over_notice(received, names, null), "%s x2" % FOOD_ID, "without a catalog too")
	var seen: Dictionary = {"scope": "public", "giver_id": GIVER, "receiver_id": RECEIVER, "world_time": 1.0}
	var seen_text: String = ClientPresentationFormatter.format_hand_over_notice(seen, names, catalog)
	assert_eq(seen_text, "영희 → 민수 물건 건넴")
	assert_ne(seen_text, ClientPresentationFormatter.format_treatment_notice({"scope": "public", "user_id": GIVER, "target_id": RECEIVER, "world_time": 1.0}, names, catalog), "handing over is told apart from tending")
	# A bystander's line cannot name the item even when a malformed caller
	# passes one along.
	var leaky: Dictionary = seen.duplicate()
	leaky["definition_id"] = FOOD_ID
	leaky["quantity"] = 2
	assert_eq(ClientPresentationFormatter.format_hand_over_notice(leaky, names, catalog), seen_text)
	assert_eq(ClientPresentationFormatter.format_hand_over_notice(seen, {}, catalog), "%s → %s 물건 건넴" % [GIVER, RECEIVER])
	assert_eq(ClientPresentationFormatter.format_hand_over_notice({"scope": "owner"}, names, catalog), "")
	assert_eq(ClientPresentationFormatter.format_hand_over_notice({}, names, catalog), "")
