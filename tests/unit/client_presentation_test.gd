extends TestCase
## Pure client presentation formatting, attack policy and tuning coverage.

const ACTIONS: Array[StringName] = [
	ClientInputActions.MOVE_FORWARD,
	ClientInputActions.MOVE_BACKWARD,
	ClientInputActions.MOVE_LEFT,
	ClientInputActions.MOVE_RIGHT,
	ClientInputActions.PICKUP,
	ClientInputActions.ATTACK,
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
