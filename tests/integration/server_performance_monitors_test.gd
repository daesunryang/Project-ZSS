extends TestCase
## PERF-1: server-only diagnostic Performance monitors and shutdown cleanup.

var _cluster: NetTestCluster = null


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
		_cluster = null


func test_server_registers_diagnostic_monitors_and_removes_them_on_shutdown() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	var world: ServerWorld = ServerComposition.create_world("monitor_world", config)
	assert_eq(world.seed_new_world(DevWorldSeed.new()), OK)
	_cluster = NetTestCluster.new(tree, NetworkSettings.load_or_default(), config)
	assert_eq(_cluster.start_server(world, null), OK)
	await tree.physics_frame
	await tree.process_frame
	for monitor: StringName in NetworkService.PERFORMANCE_MONITORS:
		assert_true(Performance.has_custom_monitor(monitor), str(monitor))
		if Performance.has_custom_monitor(monitor):
			var value: Variant = Performance.get_custom_monitor(monitor)
			assert_true(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT, str(monitor))
	await _cluster.shutdown()
	_cluster = null
	for monitor: StringName in NetworkService.PERFORMANCE_MONITORS:
		assert_false(Performance.has_custom_monitor(monitor), str(monitor))
