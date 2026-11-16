extends TestCase


func test_shipped_compression_is_fastlz_and_valid() -> void:
	var settings: NetworkSettings = NetworkSettings.load_or_default()
	assert_eq(settings.compression_mode, NetworkSettings.CompressionMode.FASTLZ)
	assert_eq(settings.validate().size(), 0, ", ".join(settings.validate()))
	assert_eq(NetworkSettings.compression_mode_name(settings.compression_mode), "FASTLZ")


func test_only_enet_compression_modes_are_valid() -> void:
	var settings: NetworkSettings = NetworkSettings.new()
	for mode: int in NetworkSettings.CompressionMode.values():
		settings.compression_mode = mode
		assert_eq(settings.validate().size(), 0, NetworkSettings.compression_mode_name(mode))
	settings.compression_mode = 99
	assert_contains(", ".join(settings.validate()), "compression_mode")
