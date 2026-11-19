extends SceneTree
## Render-side companion for perf_bench.gd --serve.

const EXIT_OK: int = 0
const EXIT_FAILED: int = 1
const CONNECT_TIMEOUT_SECONDS: float = 10.0
const DEFAULT_MEASURE_SECONDS: float = 10.0
const DEFAULT_WARMUP_SECONDS: float = 2.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene_error: Error = change_scene_to_file("res://scenes/main/main.tscn")
	if scene_error != OK:
		printerr("error: could not load the client scene: " + error_string(scene_error))
		quit(EXIT_FAILED)
		return
	var bootstrap: GameBootstrap = await _wait_for_bootstrap()
	if bootstrap == null:
		printerr("error: client bootstrap did not start")
		quit(EXIT_FAILED)
		return
	var network: NetworkService = bootstrap.get_network()
	if network == null:
		printerr("error: performance client has no network service")
		quit(EXIT_FAILED)
		return
	var zombie_module: ZombieNetModule = network.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule
	if zombie_module == null:
		printerr("error: performance client has no zombie module")
		quit(EXIT_FAILED)
		return
	var expected_zombies: int = _environment_int("ZSS_PERF_EXPECT_ZOMBIES", 0)
	var connected: bool = await _wait_for_mirror(network, zombie_module.client_state, expected_zombies)
	if not connected:
		printerr("error: performance client did not receive the stress scene in time")
		quit(EXIT_FAILED)
		return
	var warmup_seconds: float = _environment_float("ZSS_PERF_WARMUP_SECONDS", DEFAULT_WARMUP_SECONDS)
	await _wait_seconds(warmup_seconds)
	var measure_seconds: float = _environment_float("ZSS_PERF_CLIENT_SECONDS", DEFAULT_MEASURE_SECONDS)
	var frame_msec: Array[float] = await _measure_frames(measure_seconds)
	var total_msec: float = _sum(frame_msec)
	var average_fps: float = float(frame_msec.size()) * 1000.0 / total_msec if total_msec > 0.0 else 0.0
	var slow_count: int = maxi(1, ceili(float(frame_msec.size()) * 0.01))
	var slowest: Array[float] = frame_msec.duplicate()
	slowest.sort()
	slowest.reverse()
	var slow_msec: float = 0.0
	for index: int in range(mini(slow_count, slowest.size())):
		slow_msec += slowest[index]
	var one_percent_low: float = 1000.0 / (slow_msec / float(slow_count)) if slow_msec > 0.0 else 0.0
	var display_driver: String = DisplayServer.get_name()
	var gpu_measured: bool = display_driver != "headless"
	var report: Dictionary = {
		"schema_version": 1,
		"display_driver": display_driver,
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"video_adapter": RenderingServer.get_video_adapter_name() if gpu_measured else "GPU not measured (headless)",
		"gpu_measured": gpu_measured,
		"seconds": total_msec / 1000.0,
		"frames": frame_msec.size(),
		"fps_average": average_fps,
		"fps_1_percent_low": one_percent_low,
		"slowest_1_percent_frames": slow_count,
		"mirrored_zombies": zombie_module.client_state.zombie_count(),
	}
	print("[perf-client] %d frames in %.3f s; average %.2f FPS; 1%% low %.2f FPS; display=%s; zombies=%d" % [frame_msec.size(), total_msec / 1000.0, average_fps, one_percent_low, display_driver, zombie_module.client_state.zombie_count()])
	if not gpu_measured:
		print("[perf-client] headless display: GPU FPS was not measured")
	print("PERF_CLIENT_JSON=" + JSON.stringify(report))
	quit(EXIT_OK)


func _wait_for_bootstrap() -> GameBootstrap:
	var started_usec: int = Time.get_ticks_usec()
	while _elapsed_seconds(started_usec) < CONNECT_TIMEOUT_SECONDS:
		await process_frame
		var scene: Node = current_scene
		if scene == null:
			continue
		var bootstrap: GameBootstrap = scene.get_node_or_null("GameBootstrap") as GameBootstrap
		if bootstrap != null and bootstrap.get_network() != null:
			return bootstrap
	return null


func _wait_for_mirror(network: NetworkService, zombies: ClientZombieState, expected_zombies: int) -> bool:
	var started_usec: int = Time.get_ticks_usec()
	while _elapsed_seconds(started_usec) < CONNECT_TIMEOUT_SECONDS:
		if not network.client_state.local_player_id.is_empty() and (expected_zombies <= 0 or zombies.zombie_count() >= expected_zombies):
			return true
		await process_frame
	return false


func _wait_seconds(seconds: float) -> void:
	var started_usec: int = Time.get_ticks_usec()
	while _elapsed_seconds(started_usec) < seconds:
		await process_frame


func _measure_frames(seconds: float) -> Array[float]:
	var result: Array[float] = []
	var measurement_started_usec: int = Time.get_ticks_usec()
	var previous_usec: int = measurement_started_usec
	while _elapsed_seconds(measurement_started_usec) < seconds:
		await process_frame
		var now_usec: int = Time.get_ticks_usec()
		result.append(float(now_usec - previous_usec) / 1000.0)
		previous_usec = now_usec
	return result


func _environment_int(name: String, fallback: int) -> int:
	var text: String = OS.get_environment(name)
	return int(text) if text.is_valid_int() else fallback


func _environment_float(name: String, fallback: float) -> float:
	var text: String = OS.get_environment(name)
	return float(text) if text.is_valid_float() and float(text) > 0.0 else fallback


func _sum(values: Array[float]) -> float:
	var total: float = 0.0
	for value: float in values:
		total += value
	return total


func _elapsed_seconds(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000000.0
