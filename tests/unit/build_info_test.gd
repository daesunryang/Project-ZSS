extends TestCase
## BuildInfo: version metadata and engine pin.


func test_game_version_is_semver() -> void:
	assert_true(BuildInfo.is_valid_semver(BuildInfo.game_version()), BuildInfo.game_version())


func test_semver_validation() -> void:
	assert_true(BuildInfo.is_valid_semver("0.0.1"))
	assert_true(BuildInfo.is_valid_semver("10.20.30"))
	assert_false(BuildInfo.is_valid_semver("1.2"))
	assert_false(BuildInfo.is_valid_semver("1.2.x"))
	assert_false(BuildInfo.is_valid_semver("1..2"))


func test_running_engine_is_pinned_version() -> void:
	assert_true(BuildInfo.is_supported_engine(), BuildInfo.engine_version_string())


func test_engine_pin_rejects_other_versions() -> void:
	var beta: Dictionary = {"major": 4, "minor": 8, "patch": 0, "status": "beta"}
	assert_false(BuildInfo.is_supported_engine(beta))
	var exact: Dictionary = {"major": 4, "minor": 7, "patch": 2, "status": "stable"}
	assert_true(BuildInfo.is_supported_engine(exact))


func test_summary_contains_name_and_version() -> void:
	var summary: String = BuildInfo.summary()
	assert_contains(summary, BuildInfo.game_name())
	assert_contains(summary, BuildInfo.game_version())
