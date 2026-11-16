extends TestCase
## Pure client presentation formatting, attack policy and tuning coverage.

const ACTIONS: Array[StringName] = [
	ClientInputActions.MOVE_FORWARD,
	ClientInputActions.MOVE_BACKWARD,
	ClientInputActions.MOVE_LEFT,
	ClientInputActions.MOVE_RIGHT,
	ClientInputActions.PICKUP,
	ClientInputActions.ATTACK,
	ClientInputActions.CONSUME,
	ClientInputActions.DRINK,
	ClientInputActions.USE_BANDAGE,
	ClientInputActions.USE_CURE,
	ClientInputActions.REST,
]


func after_each() -> void:
	for action: StringName in ACTIONS:
		if InputMap.has_action(action):
			InputMap.erase_action(action)


func test_zombie_state_colors_are_driven_by_settings() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	assert_eq(ClientPresentationFormatter.zombie_color("idle", settings), settings.zombie_idle_color)
	assert_eq(ClientPresentationFormatter.zombie_color("investigate", settings), settings.zombie_investigate_color)
	assert_eq(ClientPresentationFormatter.zombie_color("chase", settings), settings.zombie_chase_color)
	assert_eq(ClientPresentationFormatter.zombie_color("attack", settings), settings.zombie_attack_color)
	assert_eq(ClientPresentationFormatter.zombie_color("search", settings), settings.zombie_search_color)
	assert_eq(ClientPresentationFormatter.zombie_color("dormant", settings), settings.zombie_dormant_color)
	assert_eq(ClientPresentationFormatter.zombie_color("dead", settings), settings.zombie_dead_color)
	assert_eq(ClientPresentationFormatter.zombie_color("unknown", settings), settings.zombie_idle_color)


func test_survival_hud_uses_categories_infection_wounds_and_death() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var vitals: Dictionary = {
		"alive": false,
		"health": 0.0,
		"stamina": 37.5,
		"needs": {"hunger": "good", "thirst": "caution", "fatigue": "danger"},
		"infection_stage": "early",
		"wounds": [
			{"is_bleeding": false},
			{"is_bleeding": true},
		],
	}
	var text: String = "\n".join(ClientPresentationFormatter.build_survival_lines(vitals, settings))
	assert_contains(text, "체력 0.0 | 스태미나 37.5")
	assert_contains(text, "허기 양호 | 갈증 주의 | 피로 위험")
	assert_contains(text, "감염 단계: 초기")
	assert_contains(text, "상처 2 | 출혈 있음")
	assert_contains(text, settings.death_message)
	assert_true(ClientPresentationFormatter.build_survival_lines({}, settings).is_empty())


func test_attack_policy_throttles_and_never_sends_while_disconnected() -> void:
	var policy: AttackIntentPolicy = AttackIntentPolicy.new(0.20)
	assert_false(policy.should_send(false, 0.0), "offline input is ignored")
	assert_true(policy.should_send(true, 0.0), "first connected input sends")
	assert_false(policy.should_send(true, 0.19), "minimum interval is enforced")
	assert_true(policy.should_send(true, 0.20), "boundary sends")
	policy.reset()
	assert_false(policy.should_send(false, 5.0), "disconnected input does not consume the first send")
	assert_true(policy.should_send(true, 5.0))


func test_shipped_presentation_settings_load_and_validate() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_true(settings.validate().is_empty())
	assert_eq(settings.attack_mouse_button, MOUSE_BUTTON_LEFT)
	assert_true(settings.hud_event_line_count > 0)
	assert_true(settings.hud_panel_color.a >= 0.8, "the real-window HUD has a readable backdrop")
	var invalid: ClientPresentationSettings = ClientPresentationSettings.new()
	invalid.attack_min_interval_sec = 0.0
	invalid.zombie_capsule_height_m = invalid.zombie_capsule_radius_m
	assert_true(invalid.validate().size() >= 2)


func test_client_view_stacks_the_left_hud_blocks_in_documented_order() -> void:
	var scene: PackedScene = load("res://scenes/main/client_view.tscn") as PackedScene
	var view: Node = scene.instantiate()
	var stack: Node = view.get_node("Hud/LeftHudPanel/LeftHudStack")
	assert_true(stack is VBoxContainer)
	assert_eq(stack.get_child_count(), 3)
	assert_eq([
		stack.get_child(0).name,
		stack.get_child(1).name,
		stack.get_child(2).name,
	], [&"SurvivalLabel", &"InventoryLabel", &"TradeLabel"])
	assert_eq(view.get_node("%SurvivalLabel").get_parent(), stack)
	assert_eq(view.get_node("%InventoryLabel").get_parent(), stack)
	view.free()


func test_attack_action_uses_settings_and_is_not_duplicated() -> void:
	var camera: CameraSettings = CameraSettings.new()
	var presentation: ClientPresentationSettings = ClientPresentationSettings.new()
	presentation.attack_mouse_button = MOUSE_BUTTON_RIGHT
	ClientInputActions.register(camera, presentation)
	assert_true(InputMap.has_action(ClientInputActions.ATTACK))
	var events: Array[InputEvent] = InputMap.action_get_events(ClientInputActions.ATTACK)
	assert_eq(events.size(), 1)
	assert_eq((events[0] as InputEventMouseButton).button_index, MOUSE_BUTTON_RIGHT)
	ClientInputActions.register(camera, presentation)
	assert_eq(InputMap.action_get_events(ClientInputActions.ATTACK).size(), 1)


func test_event_and_attack_result_text_preserve_private_infection_scope() -> void:
	var zombie_event: Dictionary = {
		"event_type": ZombieService.EVENT_ATTACKED,
		"zombie_id": "zombie_1",
		"target_id": "alice",
		"wound_type": "bite",
		"damage": 8.0,
		"target_died": false,
		"infection": SurvivalService.EVENT_PLAYER_INFECTED,
	}
	var own_text: String = ClientPresentationFormatter.format_zombie_event(zombie_event, "alice")
	assert_contains(own_text, "감염")
	assert_not_contains(ClientPresentationFormatter.format_zombie_event(zombie_event, "bob"), "감염")
	assert_contains(ClientPresentationFormatter.format_attack_result(false, "attack_on_cooldown"), "attack_on_cooldown")
	assert_contains(ClientPresentationFormatter.format_attack_result(true, ""), "승인")


# ------------------------------------------------------------ P2-T3: consume key and inventory HUD

func _consume_catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.new()
	var food: ItemDefinition = ItemDefinition.new()
	food.definition_id = "hud_food"
	food.display_name = "Canned Beans"
	food.max_stack = 5
	food.consume_hunger_reduction = 30.0
	catalog.add(food)
	var water: ItemDefinition = ItemDefinition.new()
	water.definition_id = "hud_water"
	water.max_stack = 5
	water.consume_thirst_reduction = 40.0
	catalog.add(water)
	var pipe: ItemDefinition = ItemDefinition.new()
	pipe.definition_id = "hud_pipe"
	pipe.display_name = "Pipe"
	catalog.add(pipe)
	var bandage: ItemDefinition = ItemDefinition.new()
	bandage.definition_id = "hud_bandage"
	bandage.display_name = "Bandage"
	bandage.max_stack = 5
	bandage.treat_bleeding_wound_count = 1
	catalog.add(bandage)
	var cure: ItemDefinition = ItemDefinition.new()
	cure.definition_id = "hud_cure"
	cure.display_name = "Cure"
	cure.max_stack = 3
	cure.cures_infection = true
	catalog.add(cure)
	return catalog


func _carried(item_id: String, definition_id: String, quantity: int) -> Dictionary:
	return {"schema_version": 1, "item_instance_id": item_id, "definition_id": definition_id, "quantity": quantity, "location_type": "inventory", "location_id": "inventory_000001", "slot_id": "slot_0"}


## Since P2-T6 there is one key per kind of item (food, drink, bandage)
## instead of the single "first consumable item" key of P2-T3, which could
## not choose between them.
func test_each_use_key_picks_the_first_item_of_its_kind_in_the_mirror() -> void:
	var catalog: ItemCatalog = _consume_catalog()
	var inventory: Array[Dictionary] = [
		_carried("item_000001", "hud_pipe", 1),
		_carried("item_000002", "hud_unknown", 1),
		{"definition_id": "hud_food"},
		{"definition_id": "hud_bandage"},
		_carried("item_000003", "hud_water", 2),
		_carried("item_000004", "hud_food", 1),
		_carried("item_000005", "hud_bandage", 2),
		_carried("item_000006", "hud_food", 4),
		_carried("item_000007", "hud_bandage", 1),
	]
	assert_eq(ConsumeIntentPolicy.first_item_id_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.FOOD), "item_000004", "mirror order, skipping what is not food")
	assert_eq(ConsumeIntentPolicy.first_item_id_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.DRINK), "item_000003", "mirror order, skipping what is not a drink")
	assert_eq(ConsumeIntentPolicy.first_item_id_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.BANDAGE), "item_000005", "mirror order, skipping what is not a bandage")
	assert_eq(ConsumeIntentPolicy.count_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.BANDAGE), 3, "units of every bandage stack")
	assert_eq(ConsumeIntentPolicy.count_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.FOOD), 5)
	assert_eq(ConsumeIntentPolicy.count_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.DRINK), 2)
	var nothing: Array[Dictionary] = [_carried("item_000001", "hud_pipe", 1)]
	var empty: Array[Dictionary] = []
	for kind: ConsumeIntentPolicy.Kind in [ConsumeIntentPolicy.Kind.FOOD, ConsumeIntentPolicy.Kind.DRINK, ConsumeIntentPolicy.Kind.BANDAGE]:
		assert_eq(ConsumeIntentPolicy.first_item_id_of_kind(nothing, catalog, kind), "", "nothing of that kind")
		assert_eq(ConsumeIntentPolicy.first_item_id_of_kind(empty, catalog, kind), "")
		assert_eq(ConsumeIntentPolicy.first_item_id_of_kind(inventory, null, kind), "", "no catalog, no guess")
		assert_eq(ConsumeIntentPolicy.count_of_kind(nothing, catalog, kind), 0)
		assert_eq(ConsumeIntentPolicy.count_of_kind(inventory, null, kind), 0)
		assert_false(ClientPresentationFormatter.nothing_to_use_text(kind).is_empty())
	# A drink is not food and a bandage is neither.
	assert_true(ConsumeIntentPolicy.is_kind(catalog.get_definition("hud_food"), ConsumeIntentPolicy.Kind.FOOD))
	assert_false(ConsumeIntentPolicy.is_kind(catalog.get_definition("hud_food"), ConsumeIntentPolicy.Kind.DRINK))
	assert_false(ConsumeIntentPolicy.is_kind(catalog.get_definition("hud_bandage"), ConsumeIntentPolicy.Kind.FOOD))
	assert_false(ConsumeIntentPolicy.is_kind(catalog.get_definition("hud_pipe"), ConsumeIntentPolicy.Kind.BANDAGE))
	assert_false(ConsumeIntentPolicy.is_kind(null, ConsumeIntentPolicy.Kind.BANDAGE))
	# The flood guard is the same rule as the attack guard, with its own interval.
	var policy: AttackIntentPolicy = AttackIntentPolicy.new(ClientPresentationSettings.new().consume_min_interval_sec)
	assert_false(policy.should_send(false, 0.0), "offline input sends nothing")
	assert_true(policy.should_send(true, 0.0))
	assert_false(policy.should_send(true, 0.1))
	assert_true(policy.should_send(true, 0.25))


## P2-T15: the HUD lists the carried stacks one by one (the inventory cursor
## walks them) instead of summing the stacks of a kind. The cursor itself:
## ground_transfer_presentation_test.gd.
func test_inventory_hud_lists_names_and_quantities_of_the_stacks() -> void:
	var catalog: ItemCatalog = _consume_catalog()
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var empty: Array[Dictionary] = []
	assert_eq(ClientPresentationFormatter.build_inventory_lines(empty, catalog, "", settings), PackedStringArray(["소지품: 없음"]))
	var inventory: Array[Dictionary] = [
		_carried("item_000001", "hud_food", 2),
		_carried("item_000002", "hud_pipe", 1),
		_carried("item_000003", "hud_food", 3),
		_carried("item_000004", "hud_water", 4),
		{"junk": true},
		_carried("item_000005", "hud_unknown", 1),
	]
	assert_eq(ClientPresentationFormatter.build_inventory_lines(inventory, catalog, "", settings), PackedStringArray([
		"소지품 (5) | 선택 [Z/X] 내려놓기 [Q] 묶음째 [Ctrl+Q]",
		"  Canned Beans x2",
		"  Pipe x1",
		"  Canned Beans x3",
		"  hud_water x4",
		"  hud_unknown x1",
	]), "one line per stack, the id when there is no name, malformed rows skipped")
	settings.hud_inventory_line_count = 2
	assert_eq(ClientPresentationFormatter.build_inventory_lines(inventory, catalog, "", settings), PackedStringArray([
		"소지품 (5) | 선택 [Z/X] 내려놓기 [Q] 묶음째 [Ctrl+Q]",
		"  Canned Beans x2",
		"  Pipe x1",
		"  ... 아래 3개",
	]), "the configured number of stacks, the rest counted")
	settings.hud_inventory_line_count = 1
	assert_eq(ClientPresentationFormatter.build_inventory_lines(inventory, null, "", settings)[1], "  hud_food x2", "ids when no catalog is available")


func test_consume_result_text_and_action_use_settings() -> void:
	assert_contains(ClientPresentationFormatter.format_consume_result(true, ""), "승인")
	assert_contains(ClientPresentationFormatter.format_consume_result(false, "not_consumable"), "not_consumable")
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.consume_key, KEY_F, "shipped consume key")
	assert_true(shipped.hud_inventory_line_count > 0)
	var camera: CameraSettings = CameraSettings.new()
	var presentation: ClientPresentationSettings = ClientPresentationSettings.new()
	presentation.consume_key = KEY_G
	ClientInputActions.register(camera, presentation)
	var events: Array[InputEvent] = InputMap.action_get_events(ClientInputActions.CONSUME)
	assert_eq(events.size(), 1)
	assert_eq((events[0] as InputEventKey).physical_keycode, KEY_G)
	ClientInputActions.register(camera, presentation)
	assert_eq(InputMap.action_get_events(ClientInputActions.CONSUME).size(), 1, "registered once")
	var invalid: ClientPresentationSettings = ClientPresentationSettings.new()
	invalid.consume_key = KEY_NONE
	invalid.consume_min_interval_sec = 0.0
	invalid.hud_inventory_line_count = 0
	assert_eq(invalid.validate().size(), 3, "; ".join(invalid.validate()))


# ------------------------------------------------------------ P2-T6: bandage key and bleeding HUD

func test_use_keys_are_separate_actions_driven_by_settings() -> void:
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_eq(shipped.consume_key, KEY_F, "shipped food key")
	assert_eq(shipped.drink_key, KEY_G, "shipped drink key")
	assert_eq(shipped.bandage_key, KEY_B, "shipped bandage key")
	var camera: CameraSettings = CameraSettings.new()
	var presentation: ClientPresentationSettings = ClientPresentationSettings.new()
	presentation.drink_key = KEY_H
	presentation.bandage_key = KEY_N
	ClientInputActions.register(camera, presentation)
	var expected: Dictionary = {
		ClientInputActions.CONSUME: KEY_F,
		ClientInputActions.DRINK: KEY_H,
		ClientInputActions.USE_BANDAGE: KEY_N,
	}
	for action: StringName in expected:
		var events: Array[InputEvent] = InputMap.action_get_events(action)
		assert_eq(events.size(), 1, str(action))
		assert_eq((events[0] as InputEventKey).physical_keycode, expected[action], str(action))
	ClientInputActions.register(camera, presentation)
	assert_eq(InputMap.action_get_events(ClientInputActions.USE_BANDAGE).size(), 1, "registered once")
	# Every use key maps to the kind of item it asks for.
	assert_eq(ClientInputActions.USE_ACTION_KINDS[ClientInputActions.CONSUME], ConsumeIntentPolicy.Kind.FOOD)
	assert_eq(ClientInputActions.USE_ACTION_KINDS[ClientInputActions.DRINK], ConsumeIntentPolicy.Kind.DRINK)
	assert_eq(ClientInputActions.USE_ACTION_KINDS[ClientInputActions.USE_BANDAGE], ConsumeIntentPolicy.Kind.BANDAGE)
	# Missing or shared keys are configuration errors.
	var missing: ClientPresentationSettings = ClientPresentationSettings.new()
	missing.drink_key = KEY_NONE
	missing.bandage_key = KEY_NONE
	assert_eq(missing.validate().size(), 2, "; ".join(missing.validate()))
	var shared: ClientPresentationSettings = ClientPresentationSettings.new()
	shared.bandage_key = shared.consume_key
	assert_eq(shared.validate().size(), 1, "; ".join(shared.validate()))


func test_treatment_hud_shows_bleeding_and_the_bandages_carried() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var catalog: ItemCatalog = _consume_catalog()
	var vitals: Dictionary = {
		"alive": true,
		"wounds": [{"is_bleeding": false}, {"is_bleeding": true}, {"is_bleeding": true}],
	}
	var carried: Array[Dictionary] = [
		_carried("item_000001", "hud_bandage", 2),
		_carried("item_000002", "hud_food", 4),
		_carried("item_000003", "hud_bandage", 1),
	]
	var lines: PackedStringArray = ClientPresentationFormatter.build_treatment_lines(vitals, carried, catalog, settings)
	assert_eq(lines[0], "출혈 중 (2곳) | 붕대 3개 [B]", "how many wounds bleed, how many bandages, which key")
	vitals["wounds"] = [{"is_bleeding": false}]
	var none: Array[Dictionary] = []
	assert_eq(ClientPresentationFormatter.build_treatment_lines(vitals, none, catalog, settings)[0], "출혈 없음 | 붕대 0개 [B]")
	settings.bandage_key = KEY_N
	assert_eq(ClientPresentationFormatter.build_treatment_lines(vitals, carried, catalog, settings)[0], "출혈 없음 | 붕대 3개 [N]", "the key comes from the settings")
	assert_eq(ClientPresentationFormatter.bleeding_wound_count({"wounds": [{"is_bleeding": true}, "junk", {"severity": 1.0}]}), 1, "malformed wounds are skipped")
	assert_true(ClientPresentationFormatter.build_treatment_lines({}, carried, catalog, settings).is_empty(), "no owner mirror, no line")
	# The result text names the server's reason code (e.g. nothing bleeds).
	assert_contains(ClientPresentationFormatter.format_consume_result(false, SurvivalService.REASON_NOT_BLEEDING), SurvivalService.REASON_NOT_BLEEDING)


# ------------------------------------------------------------ P2-T7: cure key and infection HUD

func test_cure_key_picks_a_cure_and_is_its_own_action() -> void:
	var catalog: ItemCatalog = _consume_catalog()
	var inventory: Array[Dictionary] = [
		_carried("item_000001", "hud_bandage", 2),
		_carried("item_000002", "hud_food", 1),
		_carried("item_000003", "hud_cure", 1),
		_carried("item_000004", "hud_cure", 2),
	]
	assert_eq(ConsumeIntentPolicy.first_item_id_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.CURE), "item_000003", "mirror order, skipping what is not a cure")
	assert_eq(ConsumeIntentPolicy.count_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.CURE), 3)
	assert_eq(ConsumeIntentPolicy.first_item_id_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.BANDAGE), "item_000001", "a cure is not a bandage")
	assert_false(ConsumeIntentPolicy.is_kind(catalog.get_definition("hud_cure"), ConsumeIntentPolicy.Kind.FOOD))
	assert_false(ConsumeIntentPolicy.is_kind(catalog.get_definition("hud_bandage"), ConsumeIntentPolicy.Kind.CURE))
	var none: Array[Dictionary] = [_carried("item_000001", "hud_bandage", 2)]
	assert_eq(ConsumeIntentPolicy.first_item_id_of_kind(none, catalog, ConsumeIntentPolicy.Kind.CURE), "")
	assert_false(ClientPresentationFormatter.nothing_to_use_text(ConsumeIntentPolicy.Kind.CURE).is_empty())
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_eq(shipped.cure_key, KEY_V, "shipped cure key")
	var camera: CameraSettings = CameraSettings.new()
	var presentation: ClientPresentationSettings = ClientPresentationSettings.new()
	presentation.cure_key = KEY_C
	ClientInputActions.register(camera, presentation)
	var events: Array[InputEvent] = InputMap.action_get_events(ClientInputActions.USE_CURE)
	assert_eq(events.size(), 1)
	assert_eq((events[0] as InputEventKey).physical_keycode, KEY_C)
	assert_eq(ClientInputActions.USE_ACTION_KINDS[ClientInputActions.USE_CURE], ConsumeIntentPolicy.Kind.CURE)
	var missing: ClientPresentationSettings = ClientPresentationSettings.new()
	missing.cure_key = KEY_NONE
	assert_eq(missing.validate().size(), 1, "; ".join(missing.validate()))
	var shared: ClientPresentationSettings = ClientPresentationSettings.new()
	shared.cure_key = shared.bandage_key
	assert_eq(shared.validate().size(), 1, "; ".join(shared.validate()))


func test_treatment_hud_shows_the_infection_and_the_cures_carried() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var catalog: ItemCatalog = _consume_catalog()
	var carried: Array[Dictionary] = [
		_carried("item_000001", "hud_cure", 2),
		_carried("item_000002", "hud_bandage", 1),
	]
	var vitals: Dictionary = {"alive": true, "wounds": [], "infection_stage": "early"}
	var lines: PackedStringArray = ClientPresentationFormatter.build_treatment_lines(vitals, carried, catalog, settings)
	assert_eq(lines.size(), 2, "one line per kind of treatment")
	assert_eq(lines[0], "출혈 없음 | 붕대 1개 [B]")
	assert_eq(lines[1], "감염: 초기 | 치료제 2개 [V]", "the owner's stage, how many cures, which key")
	vitals["infection_stage"] = "none"
	var none: Array[Dictionary] = []
	assert_eq(ClientPresentationFormatter.build_treatment_lines(vitals, none, catalog, settings)[1], "감염 없음 | 치료제 0개 [V]")
	settings.cure_key = KEY_C
	vitals["infection_stage"] = "severe"
	assert_eq(ClientPresentationFormatter.build_treatment_lines(vitals, carried, catalog, settings)[1], "감염: 중증 | 치료제 2개 [C]", "the HUD does not judge whether it is too late: the server does")
	for reason: String in [SurvivalService.REASON_NOT_INFECTED, SurvivalService.REASON_TOO_LATE]:
		assert_contains(ClientPresentationFormatter.format_consume_result(false, reason), reason)


# ------------------------------------------------------------ P2-T8: rest key, HUD and lying capsule

func test_rest_key_is_an_action_driven_by_settings() -> void:
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_eq(shipped.rest_key, KEY_R, "shipped rest key")
	assert_true(shipped.rest_min_interval_sec > 0.0)
	var camera: CameraSettings = CameraSettings.new()
	var presentation: ClientPresentationSettings = ClientPresentationSettings.new()
	presentation.rest_key = KEY_Z
	ClientInputActions.register(camera, presentation)
	var events: Array[InputEvent] = InputMap.action_get_events(ClientInputActions.REST)
	assert_eq(events.size(), 1)
	assert_eq((events[0] as InputEventKey).physical_keycode, KEY_Z)
	ClientInputActions.register(camera, presentation)
	assert_eq(InputMap.action_get_events(ClientInputActions.REST).size(), 1, "registered once")
	assert_false(ClientInputActions.USE_ACTION_KINDS.has(ClientInputActions.REST), "resting uses no item")
	var invalid: ClientPresentationSettings = ClientPresentationSettings.new()
	invalid.rest_key = KEY_NONE
	invalid.rest_min_interval_sec = 0.0
	invalid.rest_tilt_rad = 0.0
	assert_eq(invalid.validate().size(), 3, "; ".join(invalid.validate()))
	var shared: ClientPresentationSettings = ClientPresentationSettings.new()
	shared.rest_key = shared.cure_key
	assert_eq(shared.validate().size(), 1, "the rest key must differ from the use keys: %s" % "; ".join(shared.validate()))
	# The flood guard is the same rule as the attack guard, with its own interval.
	var policy: AttackIntentPolicy = AttackIntentPolicy.new(ClientPresentationSettings.new().rest_min_interval_sec)
	assert_false(policy.should_send(false, 0.0), "offline input sends nothing")
	assert_true(policy.should_send(true, 0.0))
	assert_false(policy.should_send(true, 0.1))


func test_rest_hud_line_result_text_and_lying_capsule() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	assert_eq(ClientPresentationFormatter.build_rest_lines({"alive": true, "resting": true}, settings), PackedStringArray(["휴식 중 (피로 회복) | 일어나기 [R]"]))
	assert_eq(ClientPresentationFormatter.build_rest_lines({"alive": true, "resting": false}, settings), PackedStringArray(["눕기 [R]"]))
	assert_eq(ClientPresentationFormatter.build_rest_lines({"alive": true}, settings), PackedStringArray(["눕기 [R]"]), "not resting until the server says so")
	settings.rest_key = KEY_Z
	assert_eq(ClientPresentationFormatter.build_rest_lines({"alive": true, "resting": true}, settings)[0], "휴식 중 (피로 회복) | 일어나기 [Z]", "the key comes from the settings")
	assert_true(ClientPresentationFormatter.build_rest_lines({"alive": false, "resting": false}, settings).is_empty(), "a dead character has no rest line")
	assert_true(ClientPresentationFormatter.build_rest_lines({}, settings).is_empty(), "no owner mirror, no line")
	assert_contains(ClientPresentationFormatter.format_rest_result(true, ""), "승인")
	assert_contains(ClientPresentationFormatter.format_rest_result(false, SurvivalService.REASON_ALREADY_RESTING), SurvivalService.REASON_ALREADY_RESTING)
	# Capsule pose: standing, lying down to rest, lying dead.
	assert_eq(ClientPresentationFormatter.player_tilt_rad(true, false, settings), 0.0, "standing")
	assert_eq(ClientPresentationFormatter.player_tilt_rad(true, true, settings), settings.rest_tilt_rad, "resting: lying down")
	assert_eq(ClientPresentationFormatter.player_tilt_rad(false, false, settings), settings.dead_tilt_rad, "dead")
	assert_eq(ClientPresentationFormatter.player_tilt_rad(false, true, settings), settings.dead_tilt_rad, "death wins")
	assert_false(ClientPresentationFormatter.player_is_lying(true, false))
	assert_true(ClientPresentationFormatter.player_is_lying(true, true))
	assert_true(ClientPresentationFormatter.player_is_lying(false, false))
	# The attack result names the server's reason when a resting player swings.
	assert_contains(ClientPresentationFormatter.format_attack_result(false, SurvivalService.REASON_PLAYER_RESTING), SurvivalService.REASON_PLAYER_RESTING)


# ------------------------------------------------------------ P2-T10: sleep tuning

func test_fatigue_work_line_refusal_and_wake_texts() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	# The owner sees that fatigue lowers its work ability (the category the
	# server sent; no number).
	var tired: Dictionary = {"alive": true, "resting": false, "needs": {"hunger": "danger", "thirst": "danger", "fatigue": "caution"}}
	assert_eq(ClientPresentationFormatter.build_rest_lines(tired, settings), PackedStringArray(["눕기 [R]", "피로로 작업 능력 저하 (주의)"]))
	tired["needs"]["fatigue"] = "danger"
	assert_eq(ClientPresentationFormatter.build_rest_lines(tired, settings), PackedStringArray(["눕기 [R]", "피로로 작업 능력 크게 저하 (위험)"]))
	tired["resting"] = true
	assert_eq(ClientPresentationFormatter.build_rest_lines(tired, settings).size(), 2, "also shown while resting")
	tired["needs"]["fatigue"] = "good"
	assert_eq(ClientPresentationFormatter.build_rest_lines(tired, settings).size(), 1, "hunger and thirst are not fatigue")
	tired["needs"]["fatigue"] = "danger"
	tired["alive"] = false
	assert_true(ClientPresentationFormatter.build_rest_lines(tired, settings).is_empty(), "a dead character has no such line")
	assert_eq(ClientPresentationFormatter.fatigue_work_text("good"), "")
	assert_eq(ClientPresentationFormatter.fatigue_work_text(""), "")
	# A refused lie-down says which danger is in the way.
	for danger: String in SurvivalService.REST_DANGERS:
		var text: String = ClientPresentationFormatter.format_rest_result(false, SurvivalService.REASON_CANNOT_REST_PREFIX + danger)
		assert_contains(text, "누울 수 없습니다", danger)
		assert_not_contains(text, SurvivalService.REASON_CANNOT_REST_PREFIX, "a sentence, not the code: " + danger)
	# Why the owner woke (the owner event carries the cause).
	var seen: Dictionary[String, bool] = {}
	for cause: String in [SurvivalService.REST_END_DAMAGED, SurvivalService.REST_END_LOW_HEALTH, SurvivalService.REST_END_THIRST, SurvivalService.REST_END_HUNGER, SurvivalService.REST_END_INFECTION]:
		var text: String = ClientPresentationFormatter.format_rest_ended(cause)
		assert_contains(text, "깼습니다", cause)
		assert_false(seen.has(text), "every cause has its own sentence: " + cause)
		seen[text] = true
	assert_eq(ClientPresentationFormatter.format_rest_ended(SurvivalService.REST_END_REQUESTED), "", "getting up by request needs no notice")
	assert_eq(ClientPresentationFormatter.format_rest_ended(SurvivalService.REST_END_DIED), "", "the death message covers it")
	assert_eq(ClientPresentationFormatter.format_rest_ended("unknown_cause"), "")
	# Only the owner event of a waking is turned into a notice.
	var owner_event: Dictionary = {"scope": ClientSurvivalState.SCOPE_OWNER, "event_type": SurvivalService.EVENT_PLAYER_REST_ENDED, "player_id": "player_000001", "cause": SurvivalService.REST_END_THIRST, "world_time": 1.0}
	assert_eq(ClientPresentationFormatter.format_survival_notice(owner_event), ClientPresentationFormatter.format_rest_ended(SurvivalService.REST_END_THIRST))
	var public_event: Dictionary = {"scope": ClientSurvivalState.SCOPE_PUBLIC, "event_type": SurvivalService.EVENT_PLAYER_REST_ENDED, "player_id": "player_000002", "world_time": 1.0}
	assert_eq(ClientPresentationFormatter.format_survival_notice(public_event), "", "another player's waking has no cause and no notice")
	assert_eq(ClientPresentationFormatter.format_survival_notice({"scope": ClientSurvivalState.SCOPE_OWNER, "event_type": SurvivalService.EVENT_PLAYER_REST_STARTED, "player_id": "player_000001", "world_time": 1.0}), "")


# ------------------------------------------------------------ P2-T11: prone and stealth

func test_prone_key_posture_hud_lines_and_prone_capsule() -> void:
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_eq(shipped.prone_key, KEY_C)
	var camera: CameraSettings = CameraSettings.new()
	var presentation: ClientPresentationSettings = ClientPresentationSettings.new()
	ClientInputActions.register(camera, presentation)
	var events: Array[InputEvent] = InputMap.action_get_events(ClientInputActions.PRONE)
	assert_eq(events.size(), 1)
	assert_eq((events[0] as InputEventKey).physical_keycode, presentation.prone_key)
	assert_false(ClientInputActions.USE_ACTION_KINDS.has(ClientInputActions.PRONE), "going prone uses no item")
	var invalid: ClientPresentationSettings = ClientPresentationSettings.new()
	invalid.prone_key = KEY_NONE
	invalid.prone_tilt_rad = 0.0
	assert_eq(invalid.validate().size(), 2, "; ".join(invalid.validate()))
	var shared: ClientPresentationSettings = ClientPresentationSettings.new()
	shared.prone_key = shared.rest_key
	assert_eq(shared.validate().size(), 1, "the prone key must differ from the rest and use keys: %s" % "; ".join(shared.validate()))

	# HUD: the own posture, "hidden" while prone, and the key.
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	assert_eq(ClientPresentationFormatter.build_posture_lines({"alive": true, "posture": "standing"}, settings), PackedStringArray(["자세: 서 있음 | 엎드리기 [C]"]))
	assert_eq(ClientPresentationFormatter.build_posture_lines({"alive": true, "posture": "prone"}, settings), PackedStringArray(["자세: 엎드림 (은신 중) | 일어서기 [C]"]))
	assert_eq(ClientPresentationFormatter.build_posture_lines({"alive": true, "posture": "resting"}, settings), PackedStringArray(["자세: 누워 잠 | 엎드리기 [C]"]), "sleeping is not shown as hidden")
	assert_eq(ClientPresentationFormatter.build_posture_lines({"alive": true}, settings), PackedStringArray(["자세: 서 있음 | 엎드리기 [C]"]), "standing until the server says otherwise")
	settings.prone_key = KEY_X
	assert_eq(ClientPresentationFormatter.build_posture_lines({"alive": true, "posture": "prone"}, settings)[0], "자세: 엎드림 (은신 중) | 일어서기 [X]", "the key comes from the settings")
	assert_true(ClientPresentationFormatter.build_posture_lines({"alive": false, "posture": "prone"}, settings).is_empty(), "a dead character has no posture line")
	assert_true(ClientPresentationFormatter.build_posture_lines({}, settings).is_empty(), "no owner mirror, no line")
	assert_contains(ClientPresentationFormatter.format_posture_result(true, ""), "승인")
	assert_contains(ClientPresentationFormatter.format_posture_result(false, PostureService.REASON_ALREADY_IN_POSTURE), PostureService.REASON_ALREADY_IN_POSTURE)
	assert_contains(ClientPresentationFormatter.format_posture_result(false, SurvivalService.REASON_CANNOT_REST_PREFIX + SurvivalService.REST_END_THIRST), "누울 수 없습니다", "a refused lie-down is told as for the rest key")
	assert_contains(ClientPresentationFormatter.format_attack_result(false, PostureService.REASON_PLAYER_PRONE), "엎드린", "a prone player is told why its attack is refused")

	# Capsule pose: a prone capsule leans forward and is told apart from a
	# sleeper (lying on its back) and from a dead one.
	settings = ClientPresentationSettings.new()
	var standing: float = ClientPresentationFormatter.player_pose_tilt_rad(true, false, false, settings)
	var prone: float = ClientPresentationFormatter.player_pose_tilt_rad(true, false, true, settings)
	var resting: float = ClientPresentationFormatter.player_pose_tilt_rad(true, true, false, settings)
	assert_eq(standing, 0.0)
	assert_eq(prone, -settings.prone_tilt_rad, "prone: forward")
	assert_eq(resting, settings.rest_tilt_rad, "resting: on the back")
	assert_true(prone < 0.0 and resting > 0.0 and absf(prone) != absf(resting), "prone and sleeping look different")
	assert_eq(ClientPresentationFormatter.player_pose_tilt_rad(true, true, true, settings), settings.rest_tilt_rad, "sleep wins over prone")
	assert_eq(ClientPresentationFormatter.player_pose_tilt_rad(false, false, true, settings), settings.dead_tilt_rad, "death wins over everything")
	# The capsule keeps touching the ground at any tilt.
	const RADIUS: float = 0.4
	const HEIGHT: float = 1.8
	assert_true(absf(ClientPresentationFormatter.player_body_center_height(RADIUS, HEIGHT, 0.0) - HEIGHT * 0.5) < 0.0001, "upright: half the height")
	assert_true(absf(ClientPresentationFormatter.player_body_center_height(RADIUS, HEIGHT, PI * 0.5) - RADIUS) < 0.0001, "flat: the radius")
	var prone_center: float = ClientPresentationFormatter.player_body_center_height(RADIUS, HEIGHT, prone)
	assert_true(prone_center > RADIUS and prone_center < HEIGHT * 0.5, "prone: lower than standing, not flat (%f)" % prone_center)
	# The mirror says which posture to draw: sleep from either mirror, prone
	# from the posture mirror, nothing for a dead character.
	assert_false(ClientPresentationFormatter.player_is_prone(true, false, PlayerPosture.Kind.STANDING))
	assert_true(ClientPresentationFormatter.player_is_prone(true, false, PlayerPosture.Kind.PRONE))
	assert_false(ClientPresentationFormatter.player_is_prone(true, true, PlayerPosture.Kind.PRONE), "the survival mirror already says asleep")
	assert_false(ClientPresentationFormatter.player_is_prone(false, false, PlayerPosture.Kind.PRONE))
	assert_false(ClientPresentationFormatter.player_is_prone(true, false, PlayerPosture.Kind.RESTING))


# ------------------------------------------------------------ P2-T4: permanent death

func test_survival_hud_shows_which_character_and_the_permanent_death_notice() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	var vitals: Dictionary = {
		"alive": false,
		"health": 0.0,
		"stamina": 0.0,
		"needs": {"hunger": "good", "thirst": "good", "fatigue": "good"},
		"infection_stage": "none",
		"wounds": [],
		"character_generation": 3,
	}
	var lines: PackedStringArray = ClientPresentationFormatter.build_survival_lines(vitals, settings)
	assert_eq(lines[0], "캐릭터 #3", "the owner sees which character this is")
	assert_eq(lines[lines.size() - 1], settings.death_message)
	assert_contains(settings.death_message, "새 캐릭터", "the notice says the character is over, not that it revives")
	assert_not_contains(settings.death_message, "부활")
	# No generation is shown until the server has told the owner one.
	vitals.erase("character_generation")
	assert_not_contains("\n".join(ClientPresentationFormatter.build_survival_lines(vitals, settings)), "캐릭터 #")
	vitals["character_generation"] = 0
	assert_not_contains("\n".join(ClientPresentationFormatter.build_survival_lines(vitals, settings)), "캐릭터 #")
