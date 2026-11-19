extends SceneTree
## Fixed-seed server stress bench. Run through tools/perf_bench.sh.

const EXIT_OK: int = 0
const EXIT_FAILED: int = 1
const EXIT_BAD_ARGUMENTS: int = 2
const DEFAULT_SEED: int = 424242
const DEFAULT_TICKS: int = 600
const DEFAULT_PLAYERS: int = 4
const DEFAULT_WORLD_ITEMS: int = 256
const DEFAULT_DELTA: float = 1.0 / 60.0
const DEFAULT_SAVE_EVERY: int = 300
const DEFAULT_PORT: int = 24689
const DEFAULT_LIVE_SECONDS: float = 18.0
const LIVE_WARMUP_SECONDS: float = 1.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var options: Dictionary = _parse_options(OS.get_cmdline_user_args())
	var errors: PackedStringArray = options.get("errors", PackedStringArray()) as PackedStringArray
	if not errors.is_empty():
		for error: String in errors:
			printerr("error: " + error)
		quit(EXIT_BAD_ARGUMENTS)
		return
	if bool(options["serve"]):
		await _run_live_server(options)
		return
	_run_core_bench(options)


func _run_core_bench(options: Dictionary) -> void:
	GameLogger.set_capture(true)
	var scenario: PerfBenchScenario = _make_scenario(options)
	if not scenario.is_valid():
		GameLogger.set_capture(false)
		printerr("error: " + scenario.setup_error)
		quit(EXIT_FAILED)
		return
	var profile_network: NetworkService = NetworkService.new()
	var module_error: Error = ServerComposition.install_net_modules(profile_network, scenario.config)
	if module_error != OK:
		GameLogger.set_capture(false)
		printerr("error: network module composition failed: " + error_string(module_error))
		quit(EXIT_FAILED)
		return
	var modules: Array[NetModule] = []
	for child: Node in profile_network.get_children():
		if child is NetModule:
			var module: NetModule = child as NetModule
			modules.append(module)
			module.on_server_started(scenario.world)

	var samples: Dictionary[String, Array] = {}
	var tick_count: int = int(options["ticks"])
	var delta: float = float(options["delta"])
	var save_every: int = int(options["save_every"])
	var run_started_usec: int = Time.get_ticks_usec()
	for tick: int in range(tick_count):
		var tick_started_usec: int = Time.get_ticks_usec()
		var now_msec: int = roundi(float(tick) * delta * 1000.0)
		scenario.prepare_bot_inputs(tick, now_msec)
		_measure_call(samples, "movement", func() -> void:
			scenario.world.step_movement(delta, now_msec, PerfBenchScenario.INPUT_TIMEOUT_MSEC)
		)
		var clock_started_usec: int = Time.get_ticks_usec()
		var world_delta: float = scenario.world.clock.step(delta, not scenario.world.online_player_ids().is_empty())
		var action_delta: float = scenario.world.clock.last_action_delta
		_add_sample(samples, "clock", _elapsed_msec(clock_started_usec))
		for system_id: String in scenario.world.system_ids():
			var system: ServerSystem = scenario.world.get_system(system_id)
			_measure_call(samples, system_id, func() -> void:
				system.step(scenario.world, action_delta, world_delta)
			)
		_measure_call(samples, "network_flush", func() -> void:
			for module: NetModule in modules:
				module.server_physics(delta)
			_build_position_rows(scenario.world)
		)
		var save_msec: float = 0.0
		if save_every > 0 and (tick + 1) % save_every == 0:
			var save_started_usec: int = Time.get_ticks_usec()
			scenario.world.to_documents()
			save_msec = _elapsed_msec(save_started_usec)
		_add_sample(samples, "save_request", save_msec)
		_add_sample(samples, "tick", _elapsed_msec(tick_started_usec))
	var wall_msec: float = _elapsed_msec(run_started_usec)
	var report: Dictionary = _build_report(scenario, options, samples, wall_msec)
	profile_network.free()
	GameLogger.set_capture(false)
	_print_human_report(report)
	print("PERF_BENCH_JSON=" + JSON.stringify(report))
	quit(EXIT_OK)


func _run_live_server(options: Dictionary) -> void:
	GameLogger.set_capture(true)
	var scenario: PerfBenchScenario = _make_scenario(options)
	if not scenario.is_valid():
		GameLogger.set_capture(false)
		printerr("error: " + scenario.setup_error)
		quit(EXIT_FAILED)
		return
	# Match the production RPC path: /root/Main/GameBootstrap/NetworkService.
	var host_root: Node = Node.new()
	host_root.name = "Main"
	root.add_child(host_root)
	var bootstrap_root: Node = Node.new()
	bootstrap_root.name = "GameBootstrap"
	host_root.add_child(bootstrap_root)
	var service: NetworkService = NetworkService.new()
	service.name = "NetworkService"
	bootstrap_root.add_child(service)
	var module_error: Error = ServerComposition.install_net_modules(service, scenario.config)
	if module_error != OK:
		GameLogger.set_capture(false)
		printerr("error: network module composition failed: " + error_string(module_error))
		quit(EXIT_FAILED)
		return
	var network_settings: NetworkSettings = NetworkSettings.load_or_default()
	var port: int = int(options["port"])
	var start_error: Error = service.start_server(scenario.world, null, network_settings, port)
	if start_error != OK:
		GameLogger.set_capture(false)
		printerr("error: live bench server failed: " + error_string(start_error))
		quit(EXIT_FAILED)
		return
	GameLogger.set_capture(false)
	print("PERF_BENCH_SERVER_READY port=%d zombies=%d" % [port, scenario.zombie_count])
	var tick_samples: Array[float] = []
	var live_started_usec: int = Time.get_ticks_usec()
	var live_seconds: float = float(options["seconds"])
	var tick: int = 0
	while _elapsed_msec(live_started_usec) < live_seconds * 1000.0:
		scenario.prepare_bot_inputs(tick, Time.get_ticks_msec())
		await physics_frame
		tick += 1
		if _elapsed_msec(live_started_usec) >= LIVE_WARMUP_SECONDS * 1000.0 and Performance.has_custom_monitor(NetworkService.MONITOR_TICK_MSEC):
			tick_samples.append(float(Performance.get_custom_monitor(NetworkService.MONITOR_TICK_MSEC)))
	var live_report: Dictionary = {
		"mode": "live_server",
		"seed": scenario.seed,
		"counts": scenario.counts(),
		"ticks": tick_samples.size(),
		"tick_median_ms": _percentile(tick_samples, 0.50),
		"tick_p95_ms": _percentile(tick_samples, 0.95),
		"tick_max_ms": _maximum(tick_samples),
		"digest": scenario.state_digest(),
	}
	service.stop()
	host_root.free()
	print("PERF_BENCH_LIVE_JSON=" + JSON.stringify(live_report))
	quit(EXIT_OK)


func _make_scenario(options: Dictionary) -> PerfBenchScenario:
	return PerfBenchScenario.create(
		int(options["seed"]),
		int(options["players"]),
		int(options["zombies"]),
		int(options["items"])
	)


func _build_report(scenario: PerfBenchScenario, options: Dictionary, samples: Dictionary[String, Array], wall_msec: float) -> Dictionary:
	var tick_samples: Array[float] = _float_samples(samples["tick"] as Array)
	var total_tick_msec: float = _sum(tick_samples)
	var functions: Array[Dictionary] = []
	for name: String in samples:
		if name == "tick":
			continue
		var function_samples: Array[float] = _float_samples(samples[name] as Array)
		functions.append({
			"name": name,
			"median_ms": _percentile(function_samples, 0.50),
			"p95_ms": _percentile(function_samples, 0.95),
			"max_ms": _maximum(function_samples),
			"share_percent": 100.0 * _sum(function_samples) / total_tick_msec if total_tick_msec > 0.0 else 0.0,
		})
	functions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["share_percent"]) > float(b["share_percent"]))
	var top: Array[Dictionary] = []
	for index: int in range(mini(3, functions.size())):
		top.append(functions[index])
	var ticks: int = int(options["ticks"])
	return {
		"schema_version": 1,
		"mode": "core",
		"date": Time.get_date_string_from_system(true),
		"engine": Engine.get_version_info().get("string", "unknown"),
		"machine": "%s; %s" % [OS.get_name(), OS.get_processor_name()],
		"seed": scenario.seed,
		"requested_counts": {"players": scenario.player_count, "zombies": scenario.zombie_count, "world_items": scenario.world_item_count},
		"counts": scenario.counts(),
		"ticks": ticks,
		"fixed_delta": float(options["delta"]),
		"save_every": int(options["save_every"]),
		"tick": {
			"median_ms": _percentile(tick_samples, 0.50),
			"p95_ms": _percentile(tick_samples, 0.95),
			"max_ms": _maximum(tick_samples),
		},
		"achievable_server_tps": float(ticks) * 1000.0 / wall_msec if wall_msec > 0.0 else 0.0,
		"functions": functions,
		"top_bottlenecks": top,
		"digest": scenario.state_digest(),
		"network_note": "module flush plus player snapshot row build; socket/GPU cost is measured only by the live client run",
	}


func _print_human_report(report: Dictionary) -> void:
	var tick: Dictionary = report["tick"] as Dictionary
	print("[perf] seed=%d ticks=%d delta=%.6f digest=%s" % [int(report["seed"]), int(report["ticks"]), float(report["fixed_delta"]), str(report["digest"])])
	print("[perf] server tick median %.3f ms | p95 %.3f ms | max %.3f ms | achievable %.1f ticks/s" % [float(tick["median_ms"]), float(tick["p95_ms"]), float(tick["max_ms"]), float(report["achievable_server_tps"])])
	print("[perf] function                         median       p95       max     share")
	for entry: Dictionary in (report["functions"] as Array):
		print("[perf] %-30s %8.3f  %8.3f  %8.3f  %7.2f%%" % [str(entry["name"]), float(entry["median_ms"]), float(entry["p95_ms"]), float(entry["max_ms"]), float(entry["share_percent"])])


func _parse_options(args: PackedStringArray) -> Dictionary:
	var cap: int = ZombieSettings.load_or_default().max_active_zombies
	var options: Dictionary = {
		"seed": DEFAULT_SEED,
		"ticks": DEFAULT_TICKS,
		"players": DEFAULT_PLAYERS,
		"zombies": cap,
		"items": DEFAULT_WORLD_ITEMS,
		"delta": DEFAULT_DELTA,
		"save_every": DEFAULT_SAVE_EVERY,
		"serve": false,
		"port": DEFAULT_PORT,
		"seconds": DEFAULT_LIVE_SECONDS,
		"errors": PackedStringArray(),
	}
	var errors: PackedStringArray = options["errors"] as PackedStringArray
	for arg: String in args:
		if arg == "--serve":
			options["serve"] = true
		elif arg.begins_with("--seed="):
			_parse_int_option(options, errors, "seed", arg.trim_prefix("--seed="), -2147483648, 2147483647)
		elif arg.begins_with("--ticks="):
			_parse_int_option(options, errors, "ticks", arg.trim_prefix("--ticks="), 1, 10000000)
		elif arg.begins_with("--players="):
			_parse_int_option(options, errors, "players", arg.trim_prefix("--players="), 1, 128)
		elif arg.begins_with("--zombies="):
			_parse_int_option(options, errors, "zombies", arg.trim_prefix("--zombies="), 1, cap)
		elif arg.begins_with("--items="):
			_parse_int_option(options, errors, "items", arg.trim_prefix("--items="), 0, 100000)
		elif arg.begins_with("--save-every="):
			_parse_int_option(options, errors, "save_every", arg.trim_prefix("--save-every="), 0, 10000000)
		elif arg.begins_with("--port="):
			_parse_int_option(options, errors, "port", arg.trim_prefix("--port="), 1, 65535)
		elif arg.begins_with("--delta="):
			_parse_float_option(options, errors, "delta", arg.trim_prefix("--delta="), 0.000001, 10.0)
		elif arg.begins_with("--seconds="):
			_parse_float_option(options, errors, "seconds", arg.trim_prefix("--seconds="), 1.0, 3600.0)
		else:
			errors.append("unknown bench argument '%s'" % arg)
	return options


func _parse_int_option(options: Dictionary, errors: PackedStringArray, key: String, text: String, minimum: int, maximum: int) -> void:
	if not text.is_valid_int() or int(text) < minimum or int(text) > maximum:
		errors.append("--%s must be within [%d, %d]" % [key.replace("_", "-"), minimum, maximum])
		return
	options[key] = int(text)


func _parse_float_option(options: Dictionary, errors: PackedStringArray, key: String, text: String, minimum: float, maximum: float) -> void:
	if not text.is_valid_float() or not is_finite(float(text)) or float(text) < minimum or float(text) > maximum:
		errors.append("--%s must be within [%s, %s]" % [key.replace("_", "-"), str(minimum), str(maximum)])
		return
	options[key] = float(text)


func _measure_call(samples: Dictionary[String, Array], name: String, callable: Callable) -> void:
	var started_usec: int = Time.get_ticks_usec()
	callable.call()
	_add_sample(samples, name, _elapsed_msec(started_usec))


func _add_sample(samples: Dictionary[String, Array], name: String, value: float) -> void:
	if not samples.has(name):
		samples[name] = []
	(samples[name] as Array).append(value)


func _build_position_rows(world: ServerWorld) -> Array:
	var rows: Array = []
	for player_id: String in world.online_player_ids():
		var player: PlayerState = world.get_player(player_id)
		rows.append([player_id, player.position, player.yaw])
	return rows


func _float_samples(values: Array) -> Array[float]:
	var result: Array[float] = []
	for value: Variant in values:
		result.append(float(value))
	return result


func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array[float] = values.duplicate()
	sorted.sort()
	var index: int = clampi(ceili(fraction * float(sorted.size())) - 1, 0, sorted.size() - 1)
	return sorted[index]


func _maximum(values: Array[float]) -> float:
	var maximum: float = 0.0
	for value: float in values:
		maximum = maxf(maximum, value)
	return maximum


func _sum(values: Array[float]) -> float:
	var total: float = 0.0
	for value: float in values:
		total += value
	return total


func _elapsed_msec(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0
