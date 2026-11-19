extends SceneTree
## Headless test runner. Usage (via tools/run_tests.sh):
##   godot --headless --path . --script res://tests/run_tests.gd [-- <options>]
##
## Discovers `*_test.gd` under tests/unit, tests/integration, tests/scenarios,
## runs every `test_*` method and exits with 0 (all passed) or 1.
## A test with zero assertions counts as a failure (no silent "pass").
##
## Options (docs/12 §9):
##   --filter=<substring>   only the tests whose "file.gd::test_name" contains it
##   --tier=p0|p1|all       only the test files of that tier (tests/test_tiers.cfg)
##   --files=<a>,<b>,...    also the test files whose path contains one of these
##   --list                 print the chosen files and stop (exit 0)
## --tier and --files add up (a file of the tier OR a named file); --filter
## then narrows the tests inside the chosen files. Without --tier and --files
## every file is run.

const TEST_DIRS: PackedStringArray = ["res://tests/unit", "res://tests/integration", "res://tests/scenarios"]
const TEST_SUFFIX: String = "_test.gd"
const TEST_PREFIX: String = "test_"
const ARG_FILTER: String = "--filter="
const ARG_TIER: String = "--tier="
const ARG_FILES: String = "--files="
const ARG_LIST: String = "--list"
const FILES_SEPARATOR: String = ","
const UNCLASSIFIED: String = "unclassified"
const MSEC_PER_SEC: float = 1000.0
const EXIT_PASS: int = 0
const EXIT_FAIL: int = 1

var _passed: int = 0
var _failed: int = 0
var _failure_report: PackedStringArray = []
## Real milliseconds spent in the test files of each tier (a measurement of
## this machine at this moment, printed and never asserted).
var _msec_by_tier: Dictionary[String, int] = {}


func _initialize() -> void:
	# Run after the tree is fully initialized so integration tests can use it.
	_run.call_deferred()


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var filter: String = _parse_value(args, ARG_FILTER)
	var tier: String = _parse_value(args, ARG_TIER)
	var patterns: PackedStringArray = _parse_value(args, ARG_FILES).split(FILES_SEPARATOR, false)
	var discovered: PackedStringArray = discover_test_files()
	var tiers: TestTiers = TestTiers.load_file()
	if not tier.is_empty() and tier != TestTiers.TIER_ALL and not TestTiers.TIERS.has(tier):
		print("[test] unknown tier '%s' (use p0, p1 or all)" % tier)
		quit(EXIT_FAIL)
		return
	var files: PackedStringArray = tiers.select(discovered, tier, patterns)
	print("[test] discovered %d test file(s), running %d%s%s%s" % [
		discovered.size(), files.size(),
		"" if tier.is_empty() else " tier=" + tier,
		"" if patterns.is_empty() else " files=" + FILES_SEPARATOR.join(patterns),
		"" if filter.is_empty() else " filter=" + filter,
	])
	if args.has(ARG_LIST):
		for path: String in files:
			print("[test] LIST %s %s" % [_tier_label(tiers, path), TestTiers.to_project_path(path)])
		quit(EXIT_PASS)
		return

	for path: String in files:
		var started_msec: int = Time.get_ticks_msec()
		var ran: int = await _run_file(path, filter)
		if ran > 0:
			var elapsed_msec: int = Time.get_ticks_msec() - started_msec
			var label: String = _tier_label(tiers, path)
			_msec_by_tier[label] = int(_msec_by_tier.get(label, 0)) + elapsed_msec
			print("[test] FILE %s %s %d ms" % [label, TestTiers.to_project_path(path), elapsed_msec])

	print("")
	for line: String in _failure_report:
		print(line)
	var time_parts: PackedStringArray = []
	var total_msec: int = 0
	for label: String in _msec_by_tier:
		total_msec += _msec_by_tier[label]
		time_parts.append("%s %.1f s" % [label, float(_msec_by_tier[label]) / MSEC_PER_SEC])
	print("[test] TIME (real, this machine now): %s; total %.1f s" % [", ".join(time_parts), float(total_msec) / MSEC_PER_SEC])
	var total: int = _passed + _failed
	print("[test] RESULT: %d passed, %d failed, %d total" % [_passed, _failed, total])
	if total == 0:
		print("[test] no tests were run")
		quit(EXIT_FAIL)
		return
	quit(EXIT_PASS if _failed == 0 else EXIT_FAIL)


## Every test file of the project ("res://tests/.../x_test.gd"), sorted.
static func discover_test_files() -> PackedStringArray:
	var files: PackedStringArray = []
	for dir_path: String in TEST_DIRS:
		_collect_test_files(dir_path, files)
	files.sort()
	return files


## Runs the tests of one file; returns how many were started (a file that
## cannot be loaded counts as one failed test).
func _run_file(path: String, filter: String) -> int:
	var script: GDScript = load(path) as GDScript
	if script == null or not script.can_instantiate():
		_record_failure(path, "<load>", PackedStringArray(["script failed to load or compile"]))
		return 1
	var instance: Object = script.new()
	if not (instance is TestCase):
		_record_failure(path, "<load>", PackedStringArray(["script does not extend TestCase"]))
		return 1
	var test_case: TestCase = instance as TestCase
	var methods: PackedStringArray = []
	for method: Dictionary in script.get_script_method_list():
		var method_name: String = str(method["name"])
		if method_name.begins_with(TEST_PREFIX) and not methods.has(method_name):
			methods.append(method_name)
	var ran: int = 0
	for method_name: String in methods:
		var full_name: String = "%s::%s" % [path.get_file(), method_name]
		if not filter.is_empty() and not full_name.contains(filter):
			continue
		ran += 1
		test_case.tree = self
		test_case.reset_results()
		await test_case.before_each()
		await test_case.call(method_name)
		await test_case.after_each()
		var failures: PackedStringArray = test_case.get_failures()
		if failures.is_empty() and test_case.get_assertion_count() == 0:
			failures = PackedStringArray(["test made no assertions"])
		if failures.is_empty():
			_passed += 1
			print("[test] PASS %s (%d assertions)" % [full_name, test_case.get_assertion_count()])
		else:
			_record_failure(path, method_name, failures)
	return ran


func _record_failure(path: String, method_name: String, failures: PackedStringArray) -> void:
	_failed += 1
	var full_name: String = "%s::%s" % [path.get_file(), method_name]
	print("[test] FAIL %s" % full_name)
	for failure: String in failures:
		_failure_report.append("[test]   %s -> %s" % [full_name, failure])


static func _collect_test_files(dir_path: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for sub_dir: String in dir.get_directories():
		_collect_test_files(dir_path.path_join(sub_dir), out)
	for file_name: String in dir.get_files():
		if file_name.ends_with(TEST_SUFFIX):
			out.append(dir_path.path_join(file_name))


func _tier_label(tiers: TestTiers, path: String) -> String:
	var tier: String = tiers.tier_of(path)
	return UNCLASSIFIED if tier.is_empty() else tier


## Value of the first "<prefix><value>" argument ("" when there is none).
func _parse_value(args: PackedStringArray, prefix: String) -> String:
	for arg: String in args:
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""
