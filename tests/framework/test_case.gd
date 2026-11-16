class_name TestCase
extends RefCounted
## Base class for tests run by tests/run_tests.gd (dependency-free runner).
##
## Every method named `test_*` is a test. Optional hooks: `before_each()`,
## `after_each()` (may be coroutines). Integration tests can use `tree` to add
## nodes and `await next_frame()`.
## A test fails if any assertion fails. Engine/script errors are additionally
## caught by tools/run_tests.sh, which fails the run on any "SCRIPT ERROR"
## or "ERROR:" line (a GDScript runtime error aborts a function silently).

## Set by the runner before each test.
var tree: SceneTree = null

var _failures: PackedStringArray = []
var _assertion_count: int = 0


func before_each() -> void:
	return


func after_each() -> void:
	return


## Waits one process frame (integration tests only).
func next_frame() -> void:
	await tree.process_frame


func assert_true(condition: bool, message: String = "") -> void:
	_assertion_count += 1
	if not condition:
		_fail("expected true", message)


## Upper bound on a REAL-TIME measurement (milliseconds). Real time depends on
## the machine and on everything else it runs, so by default this only warns
## (docs/12 §1.1); set ZSS_STRICT_TIMING=1 to make it a failing assertion,
## e.g. on a quiet machine before recording numbers in docs/15.
func assert_time_bound(value_ms: float, bound_ms: float, message: String = "") -> void:
	if OS.get_environment("ZSS_STRICT_TIMING") == "1":
		assert_true(value_ms < bound_ms, "%s: %.3f ms (bound %.3f ms)" % [message, value_ms, bound_ms])
		return
	_assertion_count += 1
	if value_ms >= bound_ms:
		print("[timing] WARNING over bound (not failing; ZSS_STRICT_TIMING=1 makes it fail): %s: %.3f ms (bound %.3f ms)" % [message, value_ms, bound_ms])


func assert_false(condition: bool, message: String = "") -> void:
	_assertion_count += 1
	if condition:
		_fail("expected false", message)


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	_assertion_count += 1
	if typeof(actual) != typeof(expected) or actual != expected:
		_fail("expected <%s> (%s) but got <%s> (%s)" % [
			str(expected), type_string(typeof(expected)), str(actual), type_string(typeof(actual))
		], message)


func assert_ne(actual: Variant, unexpected: Variant, message: String = "") -> void:
	_assertion_count += 1
	if typeof(actual) == typeof(unexpected) and actual == unexpected:
		_fail("did not expect <%s>" % str(unexpected), message)


func assert_null(value: Variant, message: String = "") -> void:
	_assertion_count += 1
	if value != null:
		_fail("expected null but got <%s>" % str(value), message)


func assert_not_null(value: Variant, message: String = "") -> void:
	_assertion_count += 1
	if value == null:
		_fail("expected non-null", message)


func assert_contains(haystack: String, needle: String, message: String = "") -> void:
	_assertion_count += 1
	if not haystack.contains(needle):
		_fail("expected <%s> to contain <%s>" % [haystack, needle], message)


func assert_not_contains(haystack: String, needle: String, message: String = "") -> void:
	_assertion_count += 1
	if haystack.contains(needle):
		_fail("expected <%s> not to contain <%s>" % [haystack, needle], message)


## Explicit failure.
func fail(message: String) -> void:
	_assertion_count += 1
	_fail("failed", message)


# --- runner interface -------------------------------------------------------

func reset_results() -> void:
	_failures = PackedStringArray()
	_assertion_count = 0


func get_failures() -> PackedStringArray:
	return _failures


func get_assertion_count() -> int:
	return _assertion_count


func _fail(reason: String, message: String) -> void:
	_failures.append(reason if message.is_empty() else "%s: %s" % [message, reason])
