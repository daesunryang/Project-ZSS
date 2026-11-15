extends SceneTree
## Headless test runner. Usage (via tools/run_tests.sh):
##   godot --headless --path . --script res://tests/run_tests.gd [-- --filter=<substring>]
##
## Discovers `*_test.gd` under tests/unit, tests/integration, tests/scenarios,
## runs every `test_*` method and exits with 0 (all passed) or 1.
## A test with zero assertions counts as a failure (no silent "pass").

const TEST_DIRS: PackedStringArray = ["res://tests/unit", "res://tests/integration", "res://tests/scenarios"]
const TEST_SUFFIX: String = "_test.gd"
const TEST_PREFIX: String = "test_"
const ARG_FILTER: String = "--filter="
const EXIT_PASS: int = 0
const EXIT_FAIL: int = 1

var _passed: int = 0
var _failed: int = 0
var _failure_report: PackedStringArray = []


func _initialize() -> void:
	# Run after the tree is fully initialized so integration tests can use it.
	_run.call_deferred()


func _run() -> void:
	var filter: String = _parse_filter(OS.get_cmdline_user_args())
	var files: PackedStringArray = []
	for dir_path: String in TEST_DIRS:
		_collect_test_files(dir_path, files)
	files.sort()
	print("[test] discovered %d test file(s)%s" % [files.size(), "" if filter.is_empty() else " filter=" + filter])

	for path: String in files:
		await _run_file(path, filter)

	print("")
	for line: String in _failure_report:
		print(line)
	var total: int = _passed + _failed
	print("[test] RESULT: %d passed, %d failed, %d total" % [_passed, _failed, total])
	if total == 0:
		print("[test] no tests were run")
		quit(EXIT_FAIL)
		return
	quit(EXIT_PASS if _failed == 0 else EXIT_FAIL)


func _run_file(path: String, filter: String) -> void:
	var script: GDScript = load(path) as GDScript
	if script == null or not script.can_instantiate():
		_record_failure(path, "<load>", PackedStringArray(["script failed to load or compile"]))
		return
	var instance: Object = script.new()
	if not (instance is TestCase):
		_record_failure(path, "<load>", PackedStringArray(["script does not extend TestCase"]))
		return
	var test_case: TestCase = instance as TestCase
	var methods: PackedStringArray = []
	for method: Dictionary in script.get_script_method_list():
		var method_name: String = str(method["name"])
		if method_name.begins_with(TEST_PREFIX) and not methods.has(method_name):
			methods.append(method_name)
	for method_name: String in methods:
		var full_name: String = "%s::%s" % [path.get_file(), method_name]
		if not filter.is_empty() and not full_name.contains(filter):
			continue
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


func _record_failure(path: String, method_name: String, failures: PackedStringArray) -> void:
	_failed += 1
	var full_name: String = "%s::%s" % [path.get_file(), method_name]
	print("[test] FAIL %s" % full_name)
	for failure: String in failures:
		_failure_report.append("[test]   %s -> %s" % [full_name, failure])


func _collect_test_files(dir_path: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for sub_dir: String in dir.get_directories():
		_collect_test_files(dir_path.path_join(sub_dir), out)
	for file_name: String in dir.get_files():
		if file_name.ends_with(TEST_SUFFIX):
			out.append(dir_path.path_join(file_name))


func _parse_filter(args: PackedStringArray) -> String:
	for arg: String in args:
		if arg.begins_with(ARG_FILTER):
			return arg.substr(ARG_FILTER.length())
	return ""
