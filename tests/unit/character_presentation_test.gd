extends TestCase
## P2-T9 (docs/00 ADR-015): pure client-side logic of the character
## creation screen and the placeholder look, no nodes: appearance -> capsule
## size and colour, the selection model of the screen (cycling, random),
## the texts of refusal reasons, when the screen opens, and the launch
## argument that creates a character without a screen.

const BASE_RADIUS: float = 0.4
const BASE_HEIGHT: float = 1.8
const FALLBACK: Color = Color(0.1, 0.2, 0.3, 1.0)
const EPSILON: float = 0.0001


func _option(option_id: String, color: Color = Color.WHITE, scale: float = 1.0) -> AppearanceOption:
	var option: AppearanceOption = AppearanceOption.new()
	option.option_id = option_id
	option.display_name = "name of " + option_id
	option.color = color
	option.scale = scale
	return option


func _slot(slot_id: String, kind: String, role: String, options: Array[AppearanceOption], default_id: String, order: int) -> AppearanceSlot:
	var slot: AppearanceSlot = AppearanceSlot.new()
	slot.slot_id = slot_id
	slot.display_name = "name of " + slot_id
	slot.kind = kind
	slot.visual_role = role
	slot.options = options
	slot.default_option_id = default_id
	slot.sort_order = order
	return slot


func _catalog() -> AppearanceCatalog:
	var catalog: AppearanceCatalog = AppearanceCatalog.new()
	catalog.add(_slot("height", AppearanceSlot.KIND_SCALE, AppearanceSlot.ROLE_CAPSULE_HEIGHT, [_option("short", Color.WHITE, 0.9), _option("average"), _option("tall", Color.WHITE, 1.1)], "average", 10))
	catalog.add(_slot("body_type", AppearanceSlot.KIND_SCALE, AppearanceSlot.ROLE_CAPSULE_RADIUS, [_option("slim", Color.WHITE, 0.8), _option("average"), _option("heavy", Color.WHITE, 1.25)], "average", 20))
	catalog.add(_slot("hair_style", AppearanceSlot.KIND_STYLE, AppearanceSlot.ROLE_NONE, [_option("short"), _option("long"), _option("bald")], "short", 30))
	catalog.add(_slot("top_color", AppearanceSlot.KIND_COLOR, AppearanceSlot.ROLE_CAPSULE_COLOR, [_option("red", Color.RED), _option("green", Color.GREEN), _option("blue", Color.BLUE)], "blue", 40))
	return catalog


func _rules() -> CharacterRules:
	return CharacterRules.new(CharacterSettings.new(), _catalog())


func _look(selection: Dictionary) -> Dictionary:
	return CharacterCapsuleLook.build(_catalog(), selection, BASE_RADIUS, BASE_HEIGHT, FALLBACK)


# ------------------------------------------------------------ appearance -> capsule

func test_the_default_look_is_the_usual_capsule_in_the_default_colour() -> void:
	var look: Dictionary = _look(_catalog().default_selection())
	assert_true(absf(float(look[CharacterCapsuleLook.KEY_RADIUS]) - BASE_RADIUS) < EPSILON)
	assert_true(absf(float(look[CharacterCapsuleLook.KEY_HEIGHT]) - BASE_HEIGHT) < EPSILON)
	assert_eq(look[CharacterCapsuleLook.KEY_COLOR], Color.BLUE)


func test_top_colour_height_and_body_type_show_on_the_capsule() -> void:
	var look: Dictionary = _look({"height": "tall", "body_type": "heavy", "hair_style": "bald", "top_color": "red"})
	assert_eq(look[CharacterCapsuleLook.KEY_COLOR], Color.RED, "the top colour is the capsule colour")
	assert_true(absf(float(look[CharacterCapsuleLook.KEY_HEIGHT]) - BASE_HEIGHT * 1.1) < EPSILON, "height scales the capsule height")
	assert_true(absf(float(look[CharacterCapsuleLook.KEY_RADIUS]) - BASE_RADIUS * 1.25) < EPSILON, "body type scales the radius")
	var small: Dictionary = _look({"height": "short", "body_type": "slim", "hair_style": "long", "top_color": "green"})
	assert_true(float(small[CharacterCapsuleLook.KEY_HEIGHT]) < BASE_HEIGHT and float(small[CharacterCapsuleLook.KEY_RADIUS]) < BASE_RADIUS)
	# A slot without a visual role changes nothing that is drawn.
	assert_eq(_look({"height": "tall", "body_type": "heavy", "hair_style": "short", "top_color": "red"}), look)


func test_an_unknown_or_missing_selection_falls_back_to_the_base_capsule() -> void:
	var look: Dictionary = _look({})
	assert_eq(look[CharacterCapsuleLook.KEY_COLOR], FALLBACK, "no row yet: the caller's colour")
	assert_true(absf(float(look[CharacterCapsuleLook.KEY_RADIUS]) - BASE_RADIUS) < EPSILON)
	assert_true(absf(float(look[CharacterCapsuleLook.KEY_HEIGHT]) - BASE_HEIGHT) < EPSILON)
	var broken: Dictionary = _look({"height": "gigantic", "body_type": 7, "top_color": "ultraviolet"})
	assert_eq(broken, look, "ids this client does not know are ignored")
	# No appearance data at all.
	var bare: Dictionary = CharacterCapsuleLook.build(AppearanceCatalog.new(), {"top_color": "red"}, BASE_RADIUS, BASE_HEIGHT, FALLBACK)
	assert_eq(bare, look)


func test_the_capsule_stays_a_valid_capsule() -> void:
	# The widest body on the shortest height: a capsule is at least as high as
	# it is wide.
	var catalog: AppearanceCatalog = AppearanceCatalog.new()
	catalog.add(_slot("height", AppearanceSlot.KIND_SCALE, AppearanceSlot.ROLE_CAPSULE_HEIGHT, [_option("flat", Color.WHITE, 0.25)], "flat", 10))
	catalog.add(_slot("body_type", AppearanceSlot.KIND_SCALE, AppearanceSlot.ROLE_CAPSULE_RADIUS, [_option("round", Color.WHITE, 4.0)], "round", 20))
	var look: Dictionary = CharacterCapsuleLook.build(catalog, catalog.default_selection(), BASE_RADIUS, BASE_HEIGHT, FALLBACK)
	assert_true(float(look[CharacterCapsuleLook.KEY_HEIGHT]) >= 2.0 * float(look[CharacterCapsuleLook.KEY_RADIUS]) - EPSILON)


func test_every_shipped_selection_gives_a_valid_capsule() -> void:
	var catalog: AppearanceCatalog = AppearanceCatalog.load_directory()
	var settings: CameraSettings = CameraSettings.load_or_default()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 9
	var colors: Dictionary = {}
	var heights: Dictionary = {}
	var radii: Dictionary = {}
	for round_index: int in range(200):
		var look: Dictionary = CharacterCapsuleLook.build(catalog, catalog.random_selection(rng), settings.capsule_radius_m, settings.capsule_height_m, FALLBACK)
		var radius: float = float(look[CharacterCapsuleLook.KEY_RADIUS])
		var height: float = float(look[CharacterCapsuleLook.KEY_HEIGHT])
		if radius <= 0.0 or height < radius * 2.0:
			fail("invalid capsule %s" % str(look))
			return
		colors[look[CharacterCapsuleLook.KEY_COLOR]] = true
		heights[snappedf(height, 0.001)] = true
		radii[snappedf(radius, 0.001)] = true
	assert_true(colors.size() >= 8, "top colours are visible (%d)" % colors.size())
	assert_true(heights.size() >= 4, "heights are visible (%d)" % heights.size())
	assert_true(radii.size() >= 4, "body types are visible (%d)" % radii.size())
	assert_false(colors.has(FALLBACK))


# ------------------------------------------------------------ the selection model of the screen

func test_the_model_starts_with_the_default_selection() -> void:
	var model: CharacterCreationModel = CharacterCreationModel.new(_rules())
	assert_eq(model.selection(), _catalog().default_selection())
	assert_eq(model.option_id("top_color"), "blue")
	assert_eq(model.option("top_color").color, Color.BLUE)
	assert_eq(model.option_id("no_such_slot"), "")
	assert_null(model.option("no_such_slot"))
	# The model hands out copies.
	model.selection()["top_color"] = "red"
	assert_eq(model.option_id("top_color"), "blue")


func test_cycling_walks_the_options_of_a_slot_and_wraps() -> void:
	var model: CharacterCreationModel = CharacterCreationModel.new(_rules())
	assert_eq(model.cycle("top_color", 1), "red", "after the last option comes the first")
	assert_eq(model.cycle("top_color", 1), "green")
	assert_eq(model.cycle("top_color", 1), "blue")
	assert_eq(model.cycle("top_color", -1), "green")
	assert_eq(model.cycle("top_color", -1), "red")
	assert_eq(model.cycle("top_color", -1), "blue", "before the first comes the last")
	assert_eq(model.cycle("top_color", 7), "red", "any step wraps")
	assert_eq(model.cycle("no_such_slot", 1), "")
	assert_eq(model.option_id("hair_style"), "short", "other slots are untouched")
	assert_true(_catalog().is_complete_selection(model.selection()))


func test_selecting_randomising_and_resetting() -> void:
	var model: CharacterCreationModel = CharacterCreationModel.new(_rules())
	assert_true(model.select("hair_style", "bald"))
	assert_false(model.select("hair_style", "mohawk"), "only options of the slot")
	assert_false(model.select("tail", "long"))
	assert_eq(model.option_id("hair_style"), "bald")
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 3
	var seen: Dictionary = {}
	for round_index: int in range(60):
		model.randomize_selection(rng)
		if not _catalog().is_complete_selection(model.selection()):
			fail("a random selection must be valid: %s" % str(model.selection()))
			return
		seen[str(model.selection())] = true
	assert_true(seen.size() > 10, "the random button gives different looks (%d)" % seen.size())
	model.reset()
	assert_eq(model.selection(), _catalog().default_selection())


func test_the_model_checks_a_name_with_the_rules_of_the_server() -> void:
	var model: CharacterCreationModel = CharacterCreationModel.new(_rules())
	model.select("top_color", "red")
	var result: ActionResult = model.check("  Rick   Grimes ")
	assert_true(result.ok, result.reason)
	assert_eq(result.event["name"], "Rick Grimes")
	assert_eq(result.event["appearance"]["top_color"], "red")
	assert_eq(model.check("a").reason, CharacterNameRules.REASON_TOO_SHORT)
	assert_eq(model.check("al!ce").reason, CharacterNameRules.REASON_BAD_CHARACTERS)
	# The same answers as the server-side rules give.
	for raw: String in ["", "a", "al!ce", "x".repeat(40), "김철수", "Rick Grimes"]:
		assert_eq(model.check(raw).reason, _rules().check_request(raw, model.selection()).reason, "same rule: %s" % raw)


# ------------------------------------------------------------ texts and policy

func test_every_refusal_reason_has_a_text() -> void:
	var settings: CharacterSettings = CharacterSettings.new()
	var reasons: PackedStringArray = [
		CharacterNameRules.REASON_EMPTY, CharacterNameRules.REASON_TOO_SHORT, CharacterNameRules.REASON_TOO_LONG,
		CharacterNameRules.REASON_BAD_CHARACTERS, CharacterNameRules.REASON_BANNED, ServerWorld.REASON_NAME_TAKEN,
		AppearanceCatalog.REASON_UNKNOWN_SLOT, AppearanceCatalog.REASON_UNKNOWN_OPTION, AppearanceCatalog.REASON_TOO_LARGE,
		SurvivalService.REASON_CHARACTER_ALIVE, SurvivalService.REASON_RESPAWN_WAIT, NetworkService.RATE_LIMITED,
		CharacterNetModule.REASON_PAYLOAD_TOO_LARGE, IntentValidator.REASON_BAD_TYPE,
	]
	var texts: Dictionary = {}
	for reason: String in reasons:
		var text: String = ClientPresentationFormatter.format_creation_reason(reason, settings)
		assert_false(text.is_empty(), reason)
		assert_not_contains(text, reason, "a known reason is explained, not shown as a code")
		texts[text] = true
	assert_true(texts.size() >= 10, "different reasons read differently")
	assert_contains(ClientPresentationFormatter.format_creation_reason(CharacterNameRules.REASON_TOO_SHORT, settings), str(settings.name_min_length))
	assert_contains(ClientPresentationFormatter.format_creation_reason(CharacterNameRules.REASON_TOO_LONG, settings), str(settings.name_max_length))
	assert_contains(ClientPresentationFormatter.format_creation_reason("some_new_code", settings), "some_new_code", "an unknown code is shown as it is")
	assert_eq(ClientPresentationFormatter.format_creation_reason("", settings), "")
	var rule: String = ClientPresentationFormatter.format_name_rule(settings)
	assert_contains(rule, str(settings.name_min_length))
	assert_contains(rule, str(settings.name_max_length))


func test_the_hud_shows_the_name_of_the_local_character() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var vitals: Dictionary = {
		"alive": true, "health": 80.0, "stamina": 50.0,
		"needs": {"hunger": "good", "thirst": "good", "fatigue": "good"},
		"wounds": [], "infection_stage": "none", "character_generation": 2, "resting": false,
	}
	assert_eq(ClientPresentationFormatter.build_survival_lines(vitals, settings)[0], "캐릭터 #2", "no name known: the generation alone, as before")
	vitals["character_name"] = "김철수"
	assert_eq(ClientPresentationFormatter.build_survival_lines(vitals, settings)[0], "김철수 | 캐릭터 #2")
	vitals["character_generation"] = 0
	assert_not_contains(ClientPresentationFormatter.build_survival_lines(vitals, settings)[0], "김철수", "nothing before the server told which character this is")
	assert_false(ClientPresentationFormatter.creation_hint(true).is_empty())
	assert_ne(ClientPresentationFormatter.creation_hint(true), ClientPresentationFormatter.creation_hint(false), "the first character and the one after a death read differently")


func test_the_screen_opens_only_when_the_player_must_create_a_character() -> void:
	assert_true(CharacterCreationScreen.should_open(true, false), "the server allows it and nothing creates automatically")
	assert_false(CharacterCreationScreen.should_open(false, false), "a living character, or the wait after a death")
	assert_false(CharacterCreationScreen.should_open(true, true), "--character-name creates without a screen")
	assert_false(CharacterCreationScreen.should_open(false, true))


func test_presentation_settings_carry_the_name_tag_tuning() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	assert_true(settings.name_tag_margin_m > 0.0 and settings.name_tag_pixel_size > 0.0 and settings.name_tag_font_size > 0)
	var broken: ClientPresentationSettings = ClientPresentationSettings.new()
	broken.name_tag_pixel_size = 0.0
	assert_true(broken.validate().size() > 0)
	broken = ClientPresentationSettings.new()
	broken.name_tag_font_size = 0
	assert_true(broken.validate().size() > 0)
	assert_contains(settings.death_message, "새 캐릭터")
	assert_not_contains(settings.death_message, "부활")


# ------------------------------------------------------------ launch argument

func test_the_character_name_argument_is_parsed_for_clients() -> void:
	var config: LaunchConfig = LaunchConfig.parse(PackedStringArray(["--client", "--connect=127.0.0.1:24680", "--player-key=alice", "--character-name=Rick Grimes"]), false)
	assert_eq(config.errors.size(), 0, "; ".join(config.errors))
	assert_eq(config.character_name, "Rick Grimes")
	var korean: LaunchConfig = LaunchConfig.parse(PackedStringArray(["--client", "--character-name=김철수"]), false)
	assert_eq(korean.errors.size(), 0, "; ".join(korean.errors))
	assert_eq(korean.character_name, "김철수")
	assert_eq(LaunchConfig.parse(PackedStringArray(["--client"]), false).character_name, "", "no argument: the creation screen is used")
	assert_true(LaunchConfig.parse(PackedStringArray(["--client", "--character-name="]), false).errors.size() > 0, "an empty name is an error")
	assert_true(LaunchConfig.parse(PackedStringArray(["--client", "--character-name=" + "x".repeat(CharacterNameRules.HARD_MAX_LENGTH + 1)]), false).errors.size() > 0, "far too long")
	assert_true(LaunchConfig.parse(PackedStringArray(["--server", "--character-name=Rick"]), false).errors.size() > 0, "a server has no character")
