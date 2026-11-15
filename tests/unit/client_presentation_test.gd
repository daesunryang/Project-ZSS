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
	var invalid: ClientPresentationSettings = ClientPresentationSettings.new()
	invalid.attack_min_interval_sec = 0.0
	invalid.zombie_capsule_height_m = invalid.zombie_capsule_radius_m
	assert_true(invalid.validate().size() >= 2)


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
	return catalog


func _carried(item_id: String, definition_id: String, quantity: int) -> Dictionary:
	return {"schema_version": 1, "item_instance_id": item_id, "definition_id": definition_id, "quantity": quantity, "location_type": "inventory", "location_id": "inventory_000001", "slot_id": "slot_0"}


func test_consume_key_picks_the_first_consumable_item_of_the_mirror() -> void:
	var catalog: ItemCatalog = _consume_catalog()
	var inventory: Array[Dictionary] = [
		_carried("item_000001", "hud_pipe", 1),
		_carried("item_000002", "hud_unknown", 1),
		{"definition_id": "hud_food"},
		_carried("item_000003", "hud_water", 2),
		_carried("item_000004", "hud_food", 1),
	]
	assert_eq(ConsumeIntentPolicy.first_consumable_item_id(inventory, catalog), "item_000003", "mirror order, skipping what cannot be consumed")
	var nothing: Array[Dictionary] = [_carried("item_000001", "hud_pipe", 1)]
	assert_eq(ConsumeIntentPolicy.first_consumable_item_id(nothing, catalog), "", "nothing consumable")
	var empty: Array[Dictionary] = []
	assert_eq(ConsumeIntentPolicy.first_consumable_item_id(empty, catalog), "")
	assert_eq(ConsumeIntentPolicy.first_consumable_item_id(inventory, null), "", "no catalog, no guess")
	# The flood guard is the same rule as the attack guard, with its own interval.
	var policy: AttackIntentPolicy = AttackIntentPolicy.new(ClientPresentationSettings.new().consume_min_interval_sec)
	assert_false(policy.should_send(false, 0.0), "offline input sends nothing")
	assert_true(policy.should_send(true, 0.0))
	assert_false(policy.should_send(true, 0.1))
	assert_true(policy.should_send(true, 0.25))


func test_inventory_hud_lists_names_and_summed_quantities() -> void:
	var catalog: ItemCatalog = _consume_catalog()
	var empty: Array[Dictionary] = []
	assert_eq(ClientPresentationFormatter.build_inventory_lines(empty, catalog, 6), PackedStringArray(["소지품: 없음"]))
	var inventory: Array[Dictionary] = [
		_carried("item_000001", "hud_food", 2),
		_carried("item_000002", "hud_pipe", 1),
		_carried("item_000003", "hud_food", 3),
		_carried("item_000004", "hud_water", 4),
		{"junk": true},
		_carried("item_000005", "hud_unknown", 1),
	]
	assert_eq(ClientPresentationFormatter.build_inventory_lines(inventory, catalog, 6), PackedStringArray([
		"소지품 (5)",
		"Canned Beans x5",
		"Pipe x1",
		"hud_water x4",
		"hud_unknown x1",
	]), "first-seen order, same kinds summed, the id when there is no name")
	assert_eq(ClientPresentationFormatter.build_inventory_lines(inventory, catalog, 2), PackedStringArray([
		"소지품 (5)",
		"Canned Beans x5",
		"Pipe x1",
		"... 외 2종",
	]), "the configured number of kinds, the rest counted")
	assert_eq(ClientPresentationFormatter.build_inventory_lines(inventory, null, 1)[1], "hud_food x5", "ids when no catalog is available")


func test_consume_result_text_and_action_use_settings() -> void:
	assert_contains(ClientPresentationFormatter.format_consume_result(true, ""), "승인")
	assert_contains(ClientPresentationFormatter.format_consume_result(false, "not_consumable"), "not_consumable")
	assert_false(ClientPresentationFormatter.nothing_to_consume_text().is_empty())
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
