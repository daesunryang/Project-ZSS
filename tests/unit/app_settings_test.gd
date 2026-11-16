extends TestCase
## AppSettings: shipped defaults load and validate.


func test_shipped_settings_load_and_validate() -> void:
	assert_true(ResourceLoader.exists(AppSettings.DEFAULT_PATH))
	var settings: AppSettings = AppSettings.load_or_default()
	assert_not_null(settings)
	assert_eq(settings.validate().size(), 0, ", ".join(settings.validate()))
	assert_true(settings.background_world_saves, "PERF-1 ships background saves on")


func test_invalid_values_are_reported() -> void:
	var settings: AppSettings = AppSettings.new()
	settings.log_level = "LOUD"
	settings.default_world_id = "Not Valid"
	assert_eq(settings.validate().size(), 2)


func test_missing_resource_falls_back_to_defaults() -> void:
	GameLogger.set_capture(true)
	var settings: AppSettings = AppSettings.load_or_default("res://data/tuning/does_not_exist.tres")
	var lines: PackedStringArray = GameLogger.captured_lines()
	GameLogger.set_capture(false)
	assert_not_null(settings)
	assert_eq(settings.validate().size(), 0)
	assert_eq(lines.size(), 1)
	assert_contains(lines[0], "[WARNING] [config]")
