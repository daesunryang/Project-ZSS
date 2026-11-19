extends TestCase
## The test tiers and the change map (docs/12 §9.1, §9.2).
## Behaviour under test:
##   - every test file of the project is in tests/test_tiers.cfg exactly once
##     (a new test file without a tier fails here), and the acceptance
##     scenarios are P0;
##   - TestTiers reports unreadable lines, duplicates and stale lines;
##   - the runner's choice: a tier, named files, or both;
##   - every line of tests/test_changes.cfg can be read and every test it
##     names exists (what the shell selector chooses for a path is checked by
##     tools/test_changed_selftest.sh).

const RUNNER: GDScript = preload("res://tests/run_tests.gd")
const CHANGE_MAP_PATH: String = "res://tests/test_changes.cfg"
const BOT_TEST: String = "tests/scenarios/combat_bot_test.gd"
const KEYWORD_TARGETS: PackedStringArray = ["none", "p0", "all", "bot", "self"]
const ACCEPTANCE: PackedStringArray = [
	"tests/scenarios/phase1_acceptance_test.gd",
	"tests/scenarios/phase2_acceptance_test.gd",
	"tests/scenarios/phase3_acceptance_test.gd",
]
const SAMPLE: String = "# comment\n\np0 tests/unit/a_test.gd\np1 tests/unit/b_test.gd\np1 res://tests/integration/c_test.gd\n"


func test_every_test_file_is_classified_exactly_once() -> void:
	var files: PackedStringArray = RUNNER.discover_test_files()
	var tiers: TestTiers = TestTiers.load_file()
	assert_true(files.size() > 0, "the runner finds the test files")
	assert_eq("\n".join(tiers.problems_for(files)), "", "tests/test_tiers.cfg names every test file once and nothing else")
	assert_eq(tiers.paths_of(TestTiers.TIER_P0).size() + tiers.paths_of(TestTiers.TIER_P1).size(), files.size(), "P0 + P1 = every test file")
	assert_true(tiers.paths_of(TestTiers.TIER_P0).size() > 0 and tiers.paths_of(TestTiers.TIER_P1).size() > 0, "both tiers are used")
	for path: String in ACCEPTANCE:
		assert_eq(tiers.tier_of(path), TestTiers.TIER_P0, "%s is P0" % path)
	assert_eq(tiers.tier_of(BOT_TEST), TestTiers.TIER_P1, "the combat bot is not in the P0 tier (it runs with combat changes)")


func test_parse_reads_tiers_and_accepts_res_paths() -> void:
	var tiers: TestTiers = TestTiers.parse(SAMPLE)
	assert_eq(tiers.errors.size(), 0)
	assert_eq(tiers.tier_of("tests/unit/a_test.gd"), "p0")
	assert_eq(tiers.tier_of("res://tests/unit/b_test.gd"), "p1")
	assert_eq(tiers.tier_of("tests/integration/c_test.gd"), "p1", "a res:// path in the file is the same file")
	assert_eq(tiers.tier_of("tests/unit/unknown_test.gd"), "", "an unclassified file has no tier")
	assert_eq(tiers.paths_of("p1"), PackedStringArray(["tests/integration/c_test.gd", "tests/unit/b_test.gd"]))
	assert_eq(tiers.problems_for(PackedStringArray(["res://tests/unit/a_test.gd", "res://tests/unit/b_test.gd", "res://tests/integration/c_test.gd"])).size(), 0)


func test_problems_name_unclassified_duplicate_stale_and_unreadable_lines() -> void:
	var tiers: TestTiers = TestTiers.parse(SAMPLE + "p1 tests/unit/a_test.gd\np2 tests/unit/d_test.gd\njust_one_field\n")
	assert_eq(tiers.errors.size(), 2, "an unknown tier and a line with one field")
	var problems: String = "\n".join(tiers.problems_for(PackedStringArray(["res://tests/unit/a_test.gd", "res://tests/unit/b_test.gd", "res://tests/unit/new_test.gd"])))
	assert_contains(problems, "not classified: tests/unit/new_test.gd")
	assert_contains(problems, "classified 2 times: tests/unit/a_test.gd")
	assert_contains(problems, "classified but missing: tests/integration/c_test.gd")
	assert_contains(problems, "unknown tier 'p2'")
	assert_contains(problems, "just_one_field")
	var missing: TestTiers = TestTiers.load_file("res://tests/no_such_tiers.cfg")
	assert_eq(missing.errors.size(), 1, "a missing tier file is an error, not an empty success")


func test_select_takes_a_tier_named_files_or_both() -> void:
	var tiers: TestTiers = TestTiers.parse(SAMPLE)
	var all: PackedStringArray = ["res://tests/integration/c_test.gd", "res://tests/unit/a_test.gd", "res://tests/unit/b_test.gd"]
	assert_eq(tiers.select(all, "", PackedStringArray()), all, "no tier and no names: every file")
	assert_eq(tiers.select(all, "p0", PackedStringArray()), PackedStringArray(["res://tests/unit/a_test.gd"]))
	assert_eq(tiers.select(all, "p1", PackedStringArray()), PackedStringArray(["res://tests/integration/c_test.gd", "res://tests/unit/b_test.gd"]))
	assert_eq(tiers.select(all, "all", PackedStringArray()), all)
	assert_eq(tiers.select(all, "", PackedStringArray(["b_test"])), PackedStringArray(["res://tests/unit/b_test.gd"]), "a name is a part of the path")
	assert_eq(tiers.select(all, "p0", PackedStringArray(["integration/"])), PackedStringArray(["res://tests/integration/c_test.gd", "res://tests/unit/a_test.gd"]), "tier and names add up, in file order")
	assert_eq(tiers.select(all, "p0", PackedStringArray(["a_test", "a_test"])), PackedStringArray(["res://tests/unit/a_test.gd"]), "a file is taken once")
	assert_eq(tiers.select(all, "", PackedStringArray(["no_such"])).size(), 0)


func test_the_change_map_names_only_tests_that_exist() -> void:
	var file: FileAccess = FileAccess.open(CHANGE_MAP_PATH, FileAccess.READ)
	assert_not_null(file, "tests/test_changes.cfg exists")
	if file == null:
		return
	var files: PackedStringArray = []
	for path: String in RUNNER.discover_test_files():
		files.append(TestTiers.to_project_path(path))
	var rule_count: int = 0
	var bot_rule_count: int = 0
	var line_number: int = 0
	for raw_line: String in file.get_as_text().split("\n"):
		line_number += 1
		var line: String = raw_line.strip_edges()
		if line.is_empty() or line.begins_with(TestTiers.COMMENT_PREFIX):
			continue
		var fields: PackedStringArray = line.split(" ", false)
		assert_true(fields.size() >= 2, "line %d has a pattern and at least one target: %s" % [line_number, line])
		if fields.size() < 2:
			continue
		rule_count += 1
		assert_not_null(RegEx.create_from_string(fields[0]), "line %d: the pattern is a regular expression: %s" % [line_number, fields[0]])
		for index: int in range(1, fields.size()):
			var target: String = fields[index]
			if target == "bot":
				bot_rule_count += 1
			if KEYWORD_TARGETS.has(target):
				continue
			var found: bool = false
			for path: String in files:
				if path.contains(target):
					found = true
					break
			assert_true(found, "line %d: target '%s' names at least one test file" % [line_number, target])
	assert_true(rule_count > 0, "the map has rules")
	assert_true(bot_rule_count > 0, "some rule asks for the combat bot")
	assert_true(files.has(BOT_TEST), "the combat bot test the selector names exists")
