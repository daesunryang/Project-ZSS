extends TestCase
## P2-T12 client side, pure logic (no nodes): which player a "use on another
## player" key means (TreatTargetPolicy), the keys and the texts. The choice
## is only a suggestion sent to the server, which decides from its own state.

const ME: String = "player_000001"
const NEAR: String = "player_000002"
const NEARER: String = "player_000003"
const FAR: String = "player_000004"
const RANGE: float = 2.5
const HALF_ANGLE: float = PI / 3.0
## Yaw 0 faces -Z (the camera / player convention).
const FACING_MINUS_Z: float = 0.0
const FACING_PLUS_X: float = -PI / 2.0


func _players(rows: Dictionary) -> Dictionary:
	var players: Dictionary = {}
	for player_id: String in rows:
		players[player_id] = {"position": rows[player_id], "yaw": 0.0}
	return players


func _pick(players: Dictionary, facing: float = FACING_MINUS_Z, excluded: PackedStringArray = PackedStringArray(), range_m: float = RANGE) -> String:
	return TreatTargetPolicy.pick_target(ME, players, excluded, facing, range_m, HALF_ANGLE)


func test_the_nearest_player_in_front_within_range_is_the_target() -> void:
	var players: Dictionary = _players({
		ME: Vector3.ZERO,
		NEAR: Vector3(0.5, 0.0, -2.0),
		NEARER: Vector3(-0.2, 0.0, -1.0),
		FAR: Vector3(0.0, 0.0, -10.0),
	})
	assert_eq(_pick(players), NEARER, "the nearest of the players in front")
	players.erase(NEARER)
	assert_eq(_pick(players), NEAR)
	players.erase(NEAR)
	assert_eq(_pick(players), TreatTargetPolicy.NO_TARGET, "out of range is nobody")
	assert_eq(_pick(players, FACING_MINUS_Z, PackedStringArray(), 20.0), FAR, "the range is an argument")
	assert_eq(_pick(_players({ME: Vector3.ZERO})), TreatTargetPolicy.NO_TARGET, "never oneself")
	assert_eq(_pick({}), TreatTargetPolicy.NO_TARGET, "no mirror, nobody")
	assert_eq(_pick(_players({NEAR: Vector3(0.0, 0.0, -1.0)})), TreatTargetPolicy.NO_TARGET, "without the own position there is no target")


func test_only_players_in_the_facing_direction_count() -> void:
	var players: Dictionary = _players({
		ME: Vector3.ZERO,
		NEAR: Vector3(0.0, 0.0, 2.0),     # behind when facing -Z
		NEARER: Vector3(1.5, 0.0, 0.0),   # to the right
	})
	assert_eq(_pick(players, FACING_MINUS_Z), TreatTargetPolicy.NO_TARGET, "nobody in front")
	assert_eq(_pick(players, FACING_PLUS_X), NEARER, "turned to the right")
	assert_eq(_pick(players, PI), NEAR, "turned around")
	# The edge of the cone: inside and just outside.
	var inside: Vector3 = Vector3(-sin(HALF_ANGLE - 0.05), 0.0, -cos(HALF_ANGLE - 0.05)) * 2.0
	var outside: Vector3 = Vector3(-sin(HALF_ANGLE + 0.05), 0.0, -cos(HALF_ANGLE + 0.05)) * 2.0
	assert_eq(_pick(_players({ME: Vector3.ZERO, NEAR: inside})), NEAR)
	assert_eq(_pick(_players({ME: Vector3.ZERO, NEAR: outside})), TreatTargetPolicy.NO_TARGET)
	# A player on the same spot is always reachable, whatever the facing.
	assert_eq(_pick(_players({ME: Vector3(3.0, 0.0, 3.0), NEAR: Vector3(3.0, 0.0, 3.0)}), PI), NEAR)
	# Height does not matter: the choice is made on the ground plane.
	assert_eq(_pick(_players({ME: Vector3.ZERO, NEAR: Vector3(0.0, 5.0, -1.0)})), NEAR)


func test_excluded_players_ties_and_bad_rows() -> void:
	var players: Dictionary = _players({
		ME: Vector3.ZERO,
		NEAR: Vector3(0.0, 0.0, -1.0),
		NEARER: Vector3(0.0, 0.0, -0.5),
	})
	assert_eq(_pick(players, FACING_MINUS_Z, PackedStringArray([NEARER])), NEAR, "an excluded (dead) player is skipped")
	assert_eq(_pick(players, FACING_MINUS_Z, PackedStringArray([NEARER, NEAR])), TreatTargetPolicy.NO_TARGET)
	# The same distance: the smaller id, whatever the dictionary order.
	var tie: Dictionary = _players({ME: Vector3.ZERO, FAR: Vector3(0.3, 0.0, -1.0), NEAR: Vector3(-0.3, 0.0, -1.0)})
	assert_eq(_pick(tie), NEAR)
	# Malformed mirror rows and arguments are skipped / give nobody.
	var broken: Dictionary = players.duplicate(true)
	broken["player_000009"] = {"yaw": 0.0}
	broken["player_000008"] = {"position": "here"}
	broken["player_000007"] = {"position": Vector3(NAN, 0.0, -0.1)}
	broken[5] = {"position": Vector3(0.0, 0.0, -0.1)}
	assert_eq(_pick(broken), NEARER)
	assert_eq(TreatTargetPolicy.pick_target(ME, players, PackedStringArray(), NAN, RANGE, HALF_ANGLE), TreatTargetPolicy.NO_TARGET)
	assert_eq(TreatTargetPolicy.pick_target(ME, players, PackedStringArray(), 0.0, 0.0, HALF_ANGLE), TreatTargetPolicy.NO_TARGET)
	assert_eq(TreatTargetPolicy.pick_target(ME, players, PackedStringArray(), 0.0, RANGE, -1.0), TreatTargetPolicy.NO_TARGET)
	assert_eq(TreatTargetPolicy.pick_target("", players, PackedStringArray(), 0.0, RANGE, HALF_ANGLE), TreatTargetPolicy.NO_TARGET)


func test_keys_settings_and_which_kinds_can_be_used_on_others() -> void:
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	assert_eq(shipped.treat_other_modifier_key, KEY_SHIFT)
	assert_true(shipped.treat_target_range_m > 0.0 and shipped.treat_target_half_angle_deg > 0.0)
	var camera: CameraSettings = CameraSettings.new()
	var presentation: ClientPresentationSettings = ClientPresentationSettings.new()
	ClientInputActions.register(camera, presentation)
	var events: Array[InputEvent] = InputMap.action_get_events(ClientInputActions.TREAT_OTHER)
	assert_eq(events.size(), 1)
	assert_eq((events[0] as InputEventKey).physical_keycode, presentation.treat_other_modifier_key)
	var invalid: ClientPresentationSettings = ClientPresentationSettings.new()
	invalid.treat_other_modifier_key = KEY_NONE
	invalid.treat_target_range_m = 0.0
	invalid.treat_target_half_angle_deg = 181.0
	assert_eq(invalid.validate().size(), 3, "; ".join(invalid.validate()))
	var shared: ClientPresentationSettings = ClientPresentationSettings.new()
	shared.treat_other_modifier_key = shared.bandage_key
	assert_eq(shared.validate().size(), 1, "the modifier must differ from the other keys: %s" % "; ".join(shared.validate()))
	# Only the treatment keys have an "on another player" form.
	assert_true(ConsumeIntentPolicy.is_usable_on_others(ConsumeIntentPolicy.Kind.BANDAGE))
	assert_true(ConsumeIntentPolicy.is_usable_on_others(ConsumeIntentPolicy.Kind.CURE))
	assert_false(ConsumeIntentPolicy.is_usable_on_others(ConsumeIntentPolicy.Kind.FOOD))
	assert_false(ConsumeIntentPolicy.is_usable_on_others(ConsumeIntentPolicy.Kind.DRINK))


func test_hud_target_line_result_texts_and_notices() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	assert_eq(ClientPresentationFormatter.build_treat_target_lines({"alive": true}, "민수", settings), PackedStringArray(["치료 대상: 민수 | 붕대 [Shift+B] 치료제 [Shift+V]"]))
	assert_eq(ClientPresentationFormatter.build_treat_target_lines({"alive": true}, "", settings), PackedStringArray(["치료 대상: 없음 (가까이서 바라보기)"]))
	settings.bandage_key = KEY_N
	settings.treat_other_modifier_key = KEY_CTRL
	assert_eq(ClientPresentationFormatter.build_treat_target_lines({"alive": true}, "player_000002", settings)[0], "치료 대상: player_000002 | 붕대 [Ctrl+N] 치료제 [Ctrl+V]", "the keys come from the settings")
	assert_true(ClientPresentationFormatter.build_treat_target_lines({"alive": false}, "민수", settings).is_empty(), "a dead character treats nobody")
	assert_true(ClientPresentationFormatter.build_treat_target_lines({}, "민수", settings).is_empty(), "no owner mirror, no line")
	# The server's answer. What it tells about the other player is told as a
	# sentence; everything else keeps its code.
	assert_contains(ClientPresentationFormatter.format_use_on_result(true, ""), "승인")
	var sentences: Dictionary[String, String] = {
		SurvivalService.REASON_NOT_BLEEDING: "출혈",
		SurvivalService.REASON_NOT_INFECTED: "감염",
		SurvivalService.REASON_TOO_LATE: "늦",
		ItemConsumption.REASON_TARGET_TOO_FAR: "멉니다",
		ItemConsumption.REASON_TARGET_DEAD: "사망",
		ItemConsumption.REASON_TARGET_UNAVAILABLE: "없습니다",
		ItemConsumption.REASON_NOT_USABLE_ON_OTHERS: "남에게",
	}
	for reason: String in sentences:
		var text: String = ClientPresentationFormatter.format_use_on_result(false, reason)
		assert_contains(text, sentences[reason], reason)
		assert_not_contains(text, reason, "a sentence, not the code: " + reason)
	assert_contains(ClientPresentationFormatter.format_use_on_result(false, NetworkService.RATE_LIMITED), NetworkService.RATE_LIMITED)
	assert_eq(ClientPresentationFormatter.no_treat_target_text(), "치료할 대상이 없습니다")
	# Notices: the target is told who, what and whether; a bystander only who.
	var names: Dictionary = {"player_000001": "영희", "player_000002": "민수"}
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var treated: Dictionary = {"scope": "target", "user_id": "player_000001", "target_id": "player_000002", "definition_id": "dev_bandage", "ok": true, "reason": "", "world_time": 1.0}
	var treated_text: String = ClientPresentationFormatter.format_treatment_notice(treated, names, catalog)
	assert_contains(treated_text, "영희")
	assert_contains(treated_text, catalog.get_definition("dev_bandage").display_name)
	assert_contains(treated_text, "나에게")
	var nothing: Dictionary = treated.duplicate()
	nothing["ok"] = false
	nothing["reason"] = SurvivalService.REASON_NOT_BLEEDING
	assert_contains(ClientPresentationFormatter.format_treatment_notice(nothing, names, catalog), "효과 없음")
	var seen: Dictionary = {"scope": "public", "user_id": "player_000001", "target_id": "player_000002", "world_time": 1.0}
	assert_eq(ClientPresentationFormatter.format_treatment_notice(seen, names, catalog), "영희 → 민수 치료")
	assert_eq(ClientPresentationFormatter.format_treatment_notice(seen, {}, catalog), "player_000001 → player_000002 치료", "without names the ids are shown")
	assert_eq(ClientPresentationFormatter.format_treatment_notice({"scope": "owner"}, names, catalog), "")
