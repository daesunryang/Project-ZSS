extends TestCase
## P2-T9 (docs/00 ADR-015): pure rules of character names and appearance.
## No nodes, no world: name clean-up and validation, the appearance
## definitions (data), selections sent by a client, random selections, the
## saved profile and the shipped data files.

const SLOT_COLOR: String = "top_color"
const SLOT_STYLE: String = "hair_style"
const SLOT_SCALE: String = "height"


# ------------------------------------------------------------ helpers

func _settings() -> CharacterSettings:
	return CharacterSettings.new()


func _option(option_id: String, display_name: String = "", color: Color = Color.WHITE, scale: float = 1.0) -> AppearanceOption:
	var option: AppearanceOption = AppearanceOption.new()
	option.option_id = option_id
	option.display_name = display_name if not display_name.is_empty() else option_id
	option.color = color
	option.scale = scale
	return option


func _slot(slot_id: String, kind: String, option_ids: Array, default_id: String, role: String = AppearanceSlot.ROLE_NONE, order: int = 0) -> AppearanceSlot:
	var slot: AppearanceSlot = AppearanceSlot.new()
	slot.slot_id = slot_id
	slot.display_name = slot_id
	slot.kind = kind
	slot.visual_role = role
	slot.sort_order = order
	for option_id: Variant in option_ids:
		slot.options.append(_option(str(option_id)))
	slot.default_option_id = default_id
	return slot


func _catalog() -> AppearanceCatalog:
	var catalog: AppearanceCatalog = AppearanceCatalog.new()
	catalog.add(_slot(SLOT_SCALE, AppearanceSlot.KIND_SCALE, ["short", "average", "tall"], "average", AppearanceSlot.ROLE_CAPSULE_HEIGHT, 10))
	catalog.add(_slot(SLOT_STYLE, AppearanceSlot.KIND_STYLE, ["short", "long", "bald"], "short", AppearanceSlot.ROLE_NONE, 20))
	catalog.add(_slot(SLOT_COLOR, AppearanceSlot.KIND_COLOR, ["red", "green", "blue"], "blue", AppearanceSlot.ROLE_CAPSULE_COLOR, 30))
	return catalog


func _name_reason(raw: String, settings: CharacterSettings = null) -> String:
	return CharacterNameRules.check(raw, settings if settings != null else _settings()).reason


func _clean_name(raw: String, settings: CharacterSettings = null) -> String:
	var result: ActionResult = CharacterNameRules.check(raw, settings if settings != null else _settings())
	return str(result.event.get("name", "<rejected: %s>" % result.reason))


# ------------------------------------------------------------ settings

func test_default_settings_are_valid_and_the_shipped_file_loads() -> void:
	var settings: CharacterSettings = _settings()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	assert_eq(settings.name_min_length, 2)
	assert_eq(settings.name_max_length, 16)
	assert_true(settings.allow_duplicate_names, "duplicate names are allowed by default")
	assert_eq(settings.banned_words.size(), 0, "the banned word list is an empty seam")
	assert_false(settings.share_character_generation, "the generation stays with the owner by default")
	assert_true(ResourceLoader.exists(CharacterSettings.DEFAULT_PATH))
	var loaded: CharacterSettings = CharacterSettings.load_or_default()
	assert_eq(loaded.validate().size(), 0, "; ".join(loaded.validate()))
	assert_true(loaded.server_requires_character_creation, "a real server asks every player to create a character")
	assert_eq(CharacterNameRules.check(loaded.default_name, loaded).reason, "", "the default name is itself a valid name")


func test_invalid_settings_are_reported() -> void:
	var settings: CharacterSettings = _settings()
	settings.name_min_length = 5
	settings.name_max_length = 4
	assert_true(settings.validate().size() > 0, "max below min")
	settings = _settings()
	settings.name_max_length = CharacterNameRules.HARD_MAX_LENGTH + 1
	assert_true(settings.validate().size() > 0, "above the protocol limit")
	settings = _settings()
	settings.allowed_codepoint_ranges = PackedInt32Array([0x41, 0x5A, 0x61])
	assert_true(settings.validate().size() > 0, "ranges come in pairs")
	settings = _settings()
	settings.allowed_codepoint_ranges = PackedInt32Array([0x5A, 0x41])
	assert_true(settings.validate().size() > 0, "a range must be ordered")
	settings = _settings()
	settings.allowed_codepoint_ranges = PackedInt32Array([0x00, 0x7A])
	assert_true(settings.validate().size() > 0, "control characters can never be allowed")
	settings = _settings()
	settings.default_name = "!!"
	assert_true(settings.validate().size() > 0, "the default name must pass the name rules")
	settings = _settings()
	settings.create_intent_rate_per_sec = 0.0
	assert_true(settings.validate().size() > 0)
	settings = _settings()
	settings.banned_words = PackedStringArray([""])
	assert_true(settings.validate().size() > 0, "an empty banned word would ban every name")


# ------------------------------------------------------------ names

func test_names_within_the_length_range_are_accepted() -> void:
	var settings: CharacterSettings = _settings()
	settings.name_min_length = 2
	settings.name_max_length = 6
	assert_eq(_name_reason("ab", settings), "", "exactly the minimum")
	assert_eq(_name_reason("abcdef", settings), "", "exactly the maximum")
	assert_eq(_name_reason("a", settings), CharacterNameRules.REASON_TOO_SHORT)
	assert_eq(_name_reason("abcdefg", settings), CharacterNameRules.REASON_TOO_LONG)


func test_length_counts_characters_not_bytes() -> void:
	var settings: CharacterSettings = _settings()
	settings.name_min_length = 2
	settings.name_max_length = 3
	assert_eq(_name_reason("철수", settings), "", "two Hangul syllables are two characters")
	assert_eq(_name_reason("김철수", settings), "")
	assert_eq(_name_reason("김철수맨", settings), CharacterNameRules.REASON_TOO_LONG)
	assert_eq(_name_reason("김", settings), CharacterNameRules.REASON_TOO_SHORT)


func test_hangul_latin_digits_and_inner_spaces_are_allowed_by_default() -> void:
	for name: String in ["김철수", "Alice", "alice99", "Rick Grimes", "생존자 7", "ZED", "007"]:
		assert_eq(_name_reason(name), "", "accepted: %s" % name)
		assert_eq(_clean_name(name), name, "unchanged: %s" % name)


func test_characters_outside_the_allowed_ranges_are_refused() -> void:
	for name: String in ["al!ce", "<b>bob</b>", "a_b", "a-b", "名前です", "アリス", "ㅋㅋㅋ", "émile", "a" + char(0x3000) + "b", "a" + char(0xA0) + "b", "🙂🙂", "a.b", "a/b", "a" + char(0x5C) + "b", "a'b"]:
		assert_eq(_name_reason(name), CharacterNameRules.REASON_BAD_CHARACTERS, "refused: %s" % name)


func test_control_characters_inside_a_name_are_refused_not_removed() -> void:
	for name: String in ["al\tice", "al\nice", "al\rice", "al" + char(0x1B) + "ice", "al" + char(0x7F) + "ice", "al" + char(0x85) + "ice", "al" + char(0x200B) + "ice", "al" + char(0x202E) + "ice"]:
		assert_eq(_name_reason(name), CharacterNameRules.REASON_BAD_CHARACTERS, "refused: %s" % name.c_escape())


func test_outer_whitespace_is_trimmed_and_space_runs_collapse() -> void:
	assert_eq(_clean_name("  alice  "), "alice")
	assert_eq(_clean_name("\talice\n"), "alice", "tabs and line breaks at the ends are cut off")
	assert_eq(_clean_name("Rick    Grimes"), "Rick Grimes")
	assert_eq(_clean_name("  김   철 수 "), "김 철 수")
	assert_eq(CharacterNameRules.sanitize("  a   b  "), "a b")
	# The length is checked after the clean-up.
	var settings: CharacterSettings = _settings()
	settings.name_max_length = 5
	assert_eq(_name_reason("   alice   ", settings), "")
	assert_eq(_name_reason("a      b", settings), "", "three characters after collapsing")


func test_empty_and_blank_names_are_refused() -> void:
	assert_eq(_name_reason(""), CharacterNameRules.REASON_EMPTY)
	assert_eq(_name_reason("     "), CharacterNameRules.REASON_EMPTY)
	assert_eq(_name_reason("\t\n"), CharacterNameRules.REASON_EMPTY)


func test_a_huge_name_is_refused_before_it_is_processed() -> void:
	var huge: String = "a".repeat(200000)
	assert_eq(_name_reason(huge), CharacterNameRules.REASON_TOO_LONG)
	# Even when it would shrink below the limit after trimming.
	assert_eq(_name_reason(" ".repeat(CharacterNameRules.HARD_MAX_LENGTH + 1) + "ab"), CharacterNameRules.REASON_TOO_LONG)


func test_allowed_ranges_are_configuration() -> void:
	var settings: CharacterSettings = _settings()
	# Latin letters only: no digits, no Hangul, no space.
	settings.allowed_codepoint_ranges = PackedInt32Array([0x41, 0x5A, 0x61, 0x7A])
	settings.default_name = "Survivor"
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	assert_eq(_name_reason("Alice", settings), "")
	assert_eq(_name_reason("Alice9", settings), CharacterNameRules.REASON_BAD_CHARACTERS)
	assert_eq(_name_reason("김철수", settings), CharacterNameRules.REASON_BAD_CHARACTERS)
	assert_eq(_name_reason("Al ice", settings), CharacterNameRules.REASON_BAD_CHARACTERS, "space is only allowed when it is in a range")
	# Adding a range (Hiragana) is a data change.
	settings.allowed_codepoint_ranges = PackedInt32Array([0x41, 0x5A, 0x61, 0x7A, 0x3041, 0x3096])
	assert_eq(_name_reason("ありす", settings), "")


func test_banned_words_are_a_seam_that_is_empty_by_default() -> void:
	assert_eq(_name_reason("Admin"), "", "nothing is banned by default")
	var settings: CharacterSettings = _settings()
	settings.banned_words = PackedStringArray(["admin", "운영자"])
	assert_eq(_name_reason("Admin", settings), CharacterNameRules.REASON_BANNED, "case does not matter")
	assert_eq(_name_reason("xXadminXx", settings), CharacterNameRules.REASON_BANNED, "inside a longer name")
	assert_eq(_name_reason("ad min", settings), CharacterNameRules.REASON_BANNED, "spaces do not hide it")
	assert_eq(_name_reason("게임 운영자", settings), CharacterNameRules.REASON_BANNED)
	assert_eq(_name_reason("Alice", settings), "")


# ------------------------------------------------------------ appearance definitions

func test_a_valid_slot_passes_and_knows_its_options() -> void:
	var slot: AppearanceSlot = _slot(SLOT_COLOR, AppearanceSlot.KIND_COLOR, ["red", "green"], "green", AppearanceSlot.ROLE_CAPSULE_COLOR)
	assert_eq(slot.validate().size(), 0, "; ".join(slot.validate()))
	assert_eq(Array(slot.option_ids()), ["red", "green"])
	assert_true(slot.has_option("red"))
	assert_false(slot.has_option("blue"))
	assert_eq(slot.index_of("green"), 1)
	assert_eq(slot.index_of("blue"), -1)
	assert_eq(slot.get_option("red").option_id, "red")
	assert_null(slot.get_option("blue"))


func test_invalid_slots_are_reported() -> void:
	var duplicate: AppearanceSlot = _slot(SLOT_COLOR, AppearanceSlot.KIND_COLOR, ["red", "red"], "red")
	assert_true(duplicate.validate().size() > 0, "duplicate option id")
	var bad_default: AppearanceSlot = _slot(SLOT_COLOR, AppearanceSlot.KIND_COLOR, ["red", "green"], "blue")
	assert_true(bad_default.validate().size() > 0, "the default must be one of the options")
	var empty: AppearanceSlot = _slot(SLOT_COLOR, AppearanceSlot.KIND_COLOR, [], "")
	assert_true(empty.validate().size() > 0, "a slot needs options")
	var bad_id: AppearanceSlot = _slot("Top Color", AppearanceSlot.KIND_COLOR, ["red"], "red")
	assert_true(bad_id.validate().size() > 0, "slot ids are snake_case")
	var bad_option_id: AppearanceSlot = _slot(SLOT_COLOR, AppearanceSlot.KIND_COLOR, ["Bright Red"], "Bright Red")
	assert_true(bad_option_id.validate().size() > 0, "option ids are snake_case")
	var bad_kind: AppearanceSlot = _slot(SLOT_COLOR, "texture", ["red"], "red")
	assert_true(bad_kind.validate().size() > 0)
	var bad_role: AppearanceSlot = _slot(SLOT_COLOR, AppearanceSlot.KIND_COLOR, ["red"], "red", "capsule_glow")
	assert_true(bad_role.validate().size() > 0)
	var role_mismatch: AppearanceSlot = _slot(SLOT_STYLE, AppearanceSlot.KIND_STYLE, ["short"], "short", AppearanceSlot.ROLE_CAPSULE_HEIGHT)
	assert_true(role_mismatch.validate().size() > 0, "a size role needs a scale slot")
	var bad_scale: AppearanceSlot = _slot(SLOT_SCALE, AppearanceSlot.KIND_SCALE, ["tall"], "tall")
	bad_scale.options[0].scale = 0.0
	assert_true(bad_scale.validate().size() > 0, "a scale must be positive")
	var unnamed: AppearanceSlot = _slot(SLOT_COLOR, AppearanceSlot.KIND_COLOR, ["red"], "red")
	unnamed.options[0].display_name = ""
	assert_true(unnamed.validate().size() > 0, "every option has display text")


func test_the_catalog_refuses_invalid_and_duplicate_slots() -> void:
	GameLogger.set_capture(true)
	var catalog: AppearanceCatalog = AppearanceCatalog.new()
	assert_eq(catalog.add(_slot(SLOT_COLOR, AppearanceSlot.KIND_COLOR, ["red"], "red")), OK)
	assert_eq(catalog.add(_slot(SLOT_COLOR, AppearanceSlot.KIND_COLOR, ["blue"], "blue")), ERR_ALREADY_EXISTS, "duplicate slot id")
	assert_eq(catalog.add(_slot(SLOT_STYLE, AppearanceSlot.KIND_STYLE, ["short"], "long")), ERR_INVALID_DATA, "default not among the options")
	assert_eq(catalog.size(), 1)
	# Two slots cannot drive the same part of the placeholder capsule.
	var first: AppearanceSlot = _slot("a_color", AppearanceSlot.KIND_COLOR, ["red"], "red", AppearanceSlot.ROLE_CAPSULE_COLOR)
	var second: AppearanceSlot = _slot("b_color", AppearanceSlot.KIND_COLOR, ["red"], "red", AppearanceSlot.ROLE_CAPSULE_COLOR)
	var roles: AppearanceCatalog = AppearanceCatalog.new()
	assert_eq(roles.add(first), OK)
	assert_eq(roles.add(second), ERR_ALREADY_EXISTS, "one slot per visual role")
	GameLogger.set_capture(false)


func test_slots_are_listed_in_their_configured_order() -> void:
	var catalog: AppearanceCatalog = AppearanceCatalog.new()
	catalog.add(_slot("zeta", AppearanceSlot.KIND_STYLE, ["a"], "a", AppearanceSlot.ROLE_NONE, 5))
	catalog.add(_slot("alpha", AppearanceSlot.KIND_STYLE, ["a"], "a", AppearanceSlot.ROLE_NONE, 20))
	catalog.add(_slot("beta", AppearanceSlot.KIND_STYLE, ["a"], "a", AppearanceSlot.ROLE_NONE, 20))
	assert_eq(Array(catalog.slot_ids()), ["zeta", "alpha", "beta"], "sort order first, then the id")
	assert_eq(catalog.slots().size(), 3)
	assert_eq(catalog.get_slot("beta").slot_id, "beta")
	assert_null(catalog.get_slot("gamma"))
	assert_eq(catalog.slot_with_role(AppearanceSlot.ROLE_CAPSULE_COLOR), null)


# ------------------------------------------------------------ selections

func test_a_complete_valid_selection_is_accepted_unchanged() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var wanted: Dictionary = {SLOT_SCALE: "tall", SLOT_STYLE: "bald", SLOT_COLOR: "red"}
	var result: ActionResult = catalog.check_selection(wanted)
	assert_true(result.ok, result.reason)
	assert_eq(result.event["appearance"], wanted)
	assert_true(catalog.is_complete_selection(wanted))


func test_missing_slots_get_their_default_option() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var result: ActionResult = catalog.check_selection({SLOT_COLOR: "green"})
	assert_true(result.ok, result.reason)
	assert_eq(result.event["appearance"], {SLOT_SCALE: "average", SLOT_STYLE: "short", SLOT_COLOR: "green"})
	var empty: ActionResult = catalog.check_selection({})
	assert_true(empty.ok, empty.reason)
	assert_eq(empty.event["appearance"], catalog.default_selection())
	assert_eq(catalog.default_selection(), {SLOT_SCALE: "average", SLOT_STYLE: "short", SLOT_COLOR: "blue"})
	assert_false(catalog.is_complete_selection({SLOT_COLOR: "green"}), "a mirror row must name every slot")


func test_unknown_slots_and_options_are_refused() -> void:
	var catalog: AppearanceCatalog = _catalog()
	assert_eq(catalog.check_selection({"tail": "long"}).reason, AppearanceCatalog.REASON_UNKNOWN_SLOT)
	assert_eq(catalog.check_selection({SLOT_COLOR: "ultraviolet"}).reason, AppearanceCatalog.REASON_UNKNOWN_OPTION)
	# An option of another slot is not an option of this one.
	assert_eq(catalog.check_selection({SLOT_COLOR: "bald"}).reason, AppearanceCatalog.REASON_UNKNOWN_OPTION)
	assert_eq(catalog.check_selection({SLOT_COLOR: ""}).reason, AppearanceCatalog.REASON_UNKNOWN_OPTION)
	assert_false(catalog.is_complete_selection({SLOT_SCALE: "tall", SLOT_STYLE: "bald", SLOT_COLOR: "ultraviolet"}))
	assert_false(catalog.is_complete_selection({SLOT_SCALE: "tall", SLOT_STYLE: "bald", SLOT_COLOR: "red", "tail": "long"}))


func test_wrongly_typed_selections_are_refused() -> void:
	var catalog: AppearanceCatalog = _catalog()
	for bad: Variant in [null, 1, "red", [SLOT_COLOR, "red"], Color.RED, 1.5, true]:
		assert_eq(catalog.check_selection(bad).reason, AppearanceCatalog.REASON_BAD_TYPE, "refused: %s" % str(bad))
		assert_false(catalog.is_complete_selection(bad))
	assert_eq(catalog.check_selection({SLOT_COLOR: 3}).reason, AppearanceCatalog.REASON_BAD_TYPE, "option ids are strings")
	assert_eq(catalog.check_selection({SLOT_COLOR: Color.RED}).reason, AppearanceCatalog.REASON_BAD_TYPE, "no free RGB: only palette ids")
	assert_eq(catalog.check_selection({7: "red"}).reason, AppearanceCatalog.REASON_BAD_TYPE, "slot ids are strings")
	assert_eq(catalog.check_selection({SLOT_COLOR: ["red"]}).reason, AppearanceCatalog.REASON_BAD_TYPE)
	assert_eq(catalog.check_selection({SLOT_COLOR: null}).reason, AppearanceCatalog.REASON_BAD_TYPE)


func test_an_oversized_selection_is_refused_before_it_is_walked() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var huge: Dictionary = {}
	for index: int in range(5000):
		huge["slot_%d" % index] = "x"
	assert_eq(catalog.check_selection(huge).reason, AppearanceCatalog.REASON_TOO_LARGE)
	# One entry more than there are slots is already too many.
	var one_more: Dictionary = catalog.default_selection()
	one_more["extra"] = "x"
	assert_eq(catalog.check_selection(one_more).reason, AppearanceCatalog.REASON_TOO_LARGE)
	# A huge id is just an unknown id.
	assert_eq(catalog.check_selection({"s".repeat(100000): "red"}).reason, AppearanceCatalog.REASON_UNKNOWN_SLOT)
	assert_eq(catalog.check_selection({SLOT_COLOR: "r".repeat(100000)}).reason, AppearanceCatalog.REASON_UNKNOWN_OPTION)


func test_a_refused_selection_does_not_change_the_input() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var input: Dictionary = {SLOT_COLOR: "green"}
	var result: ActionResult = catalog.check_selection(input)
	assert_eq(input, {SLOT_COLOR: "green"}, "the caller's dictionary is not filled in")
	(result.event["appearance"] as Dictionary)[SLOT_COLOR] = "red"
	assert_eq(input[SLOT_COLOR], "green")


func test_random_selections_are_always_valid_and_cover_the_options() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 20261115
	var seen: Dictionary = {}
	for round_index: int in range(300):
		var selection: Dictionary = catalog.random_selection(rng)
		if not catalog.is_complete_selection(selection):
			fail("invalid random selection: %s" % str(selection))
			return
		for slot_id: String in selection:
			seen["%s/%s" % [slot_id, selection[slot_id]]] = true
	assert_eq(seen.size(), 9, "every option of every slot came up in 300 draws")
	# Same seed, same sequence.
	var first: RandomNumberGenerator = RandomNumberGenerator.new()
	first.seed = 7
	var second: RandomNumberGenerator = RandomNumberGenerator.new()
	second.seed = 7
	assert_eq(catalog.random_selection(first), catalog.random_selection(second))
	assert_eq(AppearanceCatalog.new().random_selection(rng), {}, "an empty catalog gives an empty selection")


func test_saved_selections_survive_data_changes() -> void:
	GameLogger.set_capture(true)
	var catalog: AppearanceCatalog = _catalog()
	# A slot added after the save gets its default; a removed slot and a
	# removed option are dropped / replaced instead of failing the load.
	var restored: Dictionary = catalog.restore_selection({SLOT_COLOR: "red", "tail": "long", SLOT_STYLE: "mohawk"})
	assert_eq(restored, {SLOT_SCALE: "average", SLOT_STYLE: "short", SLOT_COLOR: "red"})
	assert_true(catalog.is_complete_selection(restored))
	assert_eq(catalog.restore_selection({}), catalog.default_selection())
	assert_eq(catalog.restore_selection({SLOT_COLOR: 5}), catalog.default_selection(), "a broken value falls back to the default")
	GameLogger.set_capture(false)


# ------------------------------------------------------------ profile and rules

func test_a_profile_round_trips_through_its_document() -> void:
	var profile: CharacterProfile = CharacterProfile.create("김철수", {SLOT_COLOR: "red", SLOT_STYLE: "bald"})
	var document: Dictionary = profile.to_dict()
	assert_true(SaveService.is_json_safe(document), "the document is JSON-safe")
	var parsed: CharacterProfile = CharacterProfile.from_dict(JSON.parse_string(JSON.stringify(document)))
	assert_not_null(parsed)
	assert_eq(parsed.name, "김철수")
	assert_eq(parsed.appearance, {SLOT_COLOR: "red", SLOT_STYLE: "bald"})
	# The copy is independent.
	var copy: CharacterProfile = profile.copy()
	copy.appearance[SLOT_COLOR] = "blue"
	copy.name = "other"
	assert_eq(profile.appearance[SLOT_COLOR], "red")
	assert_eq(profile.name, "김철수")
	document["appearance"][SLOT_COLOR] = "green"
	assert_eq(profile.appearance[SLOT_COLOR], "red", "to_dict() hands out a copy")


func test_malformed_profile_documents_are_refused() -> void:
	var good: Dictionary = CharacterProfile.create("alice", {SLOT_COLOR: "red"}).to_dict()
	assert_eq(CharacterProfile.validate_dict(good).size(), 0)
	for bad: Variant in [null, 3, "alice", [], {"name": "alice"}, {"appearance": {}}, {"name": "", "appearance": {}}, {"name": 5, "appearance": {}}, {"name": "alice", "appearance": []}, {"name": "alice", "appearance": {SLOT_COLOR: 3}}, {"name": "alice", "appearance": {3: "red"}}, {"name": "a".repeat(CharacterNameRules.HARD_MAX_LENGTH + 1), "appearance": {}}]:
		assert_true(CharacterProfile.validate_dict(bad).size() > 0, "refused: %s" % str(bad).left(80))
		assert_null(CharacterProfile.from_dict(bad))
	var too_many: Dictionary = {}
	for index: int in range(AppearanceCatalog.MAX_SLOTS + 1):
		too_many["slot_%d" % index] = "x"
	assert_true(CharacterProfile.validate_dict({"name": "alice", "appearance": too_many}).size() > 0)


func test_rules_check_a_whole_request() -> void:
	var rules: CharacterRules = CharacterRules.new(_settings(), _catalog())
	var result: ActionResult = rules.check_request("  Rick   Grimes ", {SLOT_COLOR: "red"})
	assert_true(result.ok, result.reason)
	assert_eq(result.event["name"], "Rick Grimes", "the cleaned name is what the server keeps")
	assert_eq(result.event["appearance"], {SLOT_SCALE: "average", SLOT_STYLE: "short", SLOT_COLOR: "red"})
	var profile: CharacterProfile = CharacterRules.profile_of(result)
	assert_eq(profile.name, "Rick Grimes")
	assert_eq(profile.appearance[SLOT_COLOR], "red")
	# Types first, then the name, then the appearance.
	assert_eq(rules.check_request(5, {}).reason, CharacterRules.REASON_BAD_TYPE)
	assert_eq(rules.check_request(null, {}).reason, CharacterRules.REASON_BAD_TYPE)
	assert_eq(rules.check_request(["alice"], {}).reason, CharacterRules.REASON_BAD_TYPE)
	assert_eq(rules.check_request(&"alice", {}).reason, CharacterRules.REASON_BAD_TYPE, "a StringName is not a String")
	assert_eq(rules.check_request("alice", "red").reason, CharacterRules.REASON_BAD_TYPE)
	assert_eq(rules.check_request("a", {SLOT_COLOR: "ultraviolet"}).reason, CharacterNameRules.REASON_TOO_SHORT)
	assert_eq(rules.check_request("alice", {SLOT_COLOR: "ultraviolet"}).reason, AppearanceCatalog.REASON_UNKNOWN_OPTION)


func test_rules_give_a_default_profile_and_repair_saved_ones() -> void:
	GameLogger.set_capture(true)
	var settings: CharacterSettings = _settings()
	var rules: CharacterRules = CharacterRules.new(settings, _catalog())
	var default_profile: CharacterProfile = rules.default_profile()
	assert_eq(default_profile.name, settings.default_name)
	assert_eq(default_profile.appearance, _catalog().default_selection())
	var repaired: CharacterProfile = rules.restore_profile(CharacterProfile.create("old name!", {SLOT_COLOR: "red", "tail": "long"}))
	assert_eq(repaired.name, "old name!", "a saved name is kept even when today's rules would refuse it")
	assert_eq(repaired.appearance, {SLOT_SCALE: "average", SLOT_STYLE: "short", SLOT_COLOR: "red"})
	# Rules without any slot (a bare world in a test) still work.
	var bare: CharacterRules = CharacterRules.new(settings, AppearanceCatalog.new())
	assert_true(bare.check_request("alice", {}).ok)
	assert_eq(bare.default_profile().appearance, {})
	GameLogger.set_capture(false)


# ------------------------------------------------------------ shipped data

func test_the_shipped_appearance_data_is_valid_and_varied() -> void:
	var catalog: AppearanceCatalog = AppearanceCatalog.load_directory()
	assert_eq(catalog.validate().size(), 0, "; ".join(catalog.validate()))
	assert_eq(Array(catalog.slot_ids()), ["body_type", "height", "skin_tone", "hair_style", "hair_color", "top_color", "bottom_color"])
	for slot: AppearanceSlot in catalog.slots():
		assert_eq(slot.validate().size(), 0, "%s: %s" % [slot.slot_id, "; ".join(slot.validate())])
		assert_false(slot.display_name.is_empty(), "%s has display text" % slot.slot_id)
		var minimum: int = 8 if slot.kind == AppearanceSlot.KIND_COLOR else (6 if slot.slot_id == "hair_style" else 4)
		assert_true(slot.options.size() >= minimum, "%s has %d options (at least %d)" % [slot.slot_id, slot.options.size(), minimum])
	assert_eq(catalog.slot_with_role(AppearanceSlot.ROLE_CAPSULE_COLOR).slot_id, "top_color")
	assert_eq(catalog.slot_with_role(AppearanceSlot.ROLE_CAPSULE_HEIGHT).slot_id, "height")
	assert_eq(catalog.slot_with_role(AppearanceSlot.ROLE_CAPSULE_RADIUS).slot_id, "body_type")
	# The default of a scale slot leaves the placeholder at its usual size.
	for role: String in [AppearanceSlot.ROLE_CAPSULE_HEIGHT, AppearanceSlot.ROLE_CAPSULE_RADIUS]:
		var slot: AppearanceSlot = catalog.slot_with_role(role)
		assert_eq(slot.get_option(slot.default_option_id).scale, 1.0, "%s default scale" % slot.slot_id)
	# Colours of one palette differ from each other.
	for slot: AppearanceSlot in catalog.slots():
		if slot.kind != AppearanceSlot.KIND_COLOR:
			continue
		var colors: Dictionary = {}
		for option: AppearanceOption in slot.options:
			colors[option.color.to_html(false)] = true
		assert_eq(colors.size(), slot.options.size(), "%s: every option has its own colour" % slot.slot_id)
	assert_true(catalog.is_complete_selection(catalog.default_selection()))


func test_the_default_composition_carries_the_character_rules() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_not_null(config.character)
	assert_not_null(config.appearance)
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	assert_eq(config.appearance.size(), 7)
	assert_false(config.require_character_creation, "compositions built for tests and tools create a default character on join")
