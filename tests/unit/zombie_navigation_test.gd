extends TestCase
## P3-6: zombie paths, structure-blocked sight/melee, planning budgets and
## active-cell gating. BuildingService remains a black-box dependency.

const WORLD: String = "zombie_navigation_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
const WALL: String = "dev_wall"
const DOOR: String = "dev_door"

var _navigation: NavigationSettings
var _zombie: ZombieSettings
var _slow_edge_building: BuildingService
var _slow_edge_query: bool = false


func before_each() -> void:
	GameLogger.set_capture(true)
	_navigation = NavigationSettings.new()
	_navigation.max_search_radius_m = 30.0
	_navigation.max_expanded_nodes = 4096
	_navigation.max_plans_per_tick = 8
	_navigation.max_planning_nodes_per_tick = 100000
	_navigation.max_search_nodes_per_tick = 100000
	_navigation.max_planning_msec_per_tick = 0.0
	_navigation.min_plan_interval_sec = 0.1
	_navigation.replan_timeout_sec = 0.25
	_navigation.replan_goal_distance_m = 0.5
	_zombie = ZombieSettings.new()
	_zombie.dev_spawn_count = 0
	_zombie.ai_period_sec = 1000.0
	_zombie.ai_bucket_count = 10
	_zombie.wander_pause_min_sec = NEVER
	_zombie.wander_pause_max_sec = NEVER
	_zombie.max_active_zombies = 128
	_slow_edge_building = null
	_slow_edge_query = false


func after_each() -> void:
	GameLogger.set_capture(false)


func _config(active_radius: int = 3) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 80.0
	config.gameplay.player_spawn_position = Vector3(7.5, 0.0, 5.5)
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.player_noise = PlayerNoiseSettings.new()
	config.player_noise.footstep_loudness = 0.0
	config.zombie = _zombie
	config.navigation = _navigation
	config.building = BuildingSettings.new()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 10.0
	config.world_cells.bounds_min_m = Vector2(-80.0, -80.0)
	config.world_cells.bounds_max_m = Vector2(80.0, 80.0)
	config.world_cells.active_radius_cells = active_radius
	config.world_cells.preload_radius_cells = maxi(active_radius + 1, 4)
	config.world_cells.preload_lookahead_sec = 0.0
	config.world_cells.refresh_period_sec = 0.0
	return config


func _world(active_radius: int = 3) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config(active_radius))
	world.seed_new_world(DevWorldSeed.new())
	return world


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _navigation_service(world: ServerWorld) -> NavigationService:
	return world.get_system(NavigationService.SYSTEM_ID) as NavigationService


func _edge_query_with_optional_slowdown(slot: Vector3i) -> bool:
	if _slow_edge_query:
		var deadline_usec: int = Time.get_ticks_usec() + 50
		while Time.get_ticks_usec() < deadline_usec:
			pass
	return _slow_edge_building.is_edge_blocked(slot)


func _spawn_chaser(world: ServerWorld, position: Vector3, player: PlayerState) -> String:
	var service: ZombieService = _zombies(world)
	var result: ActionResult = service.spawn_zombie(world, position, ZombiePerception.yaw_towards(player.position - position, 0.0))
	var zombie: ZombieState = service.get_zombie(str(result.event["zombie_id"]))
	zombie.state = ZombieState.State.CHASE
	zombie.target_player_id = player.player_id
	zombie.target_visible = true
	zombie.focus_position = player.position
	return zombie.zombie_id


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


## Since P3-5 a placed piece is a blueprint that blocks nothing: these tests
## need standing walls and doors, so the server rule completes each piece at
## once (the same path the map content uses).
func _place_completed(world: ServerWorld, definition: String, tile: Vector2i, rotation: int) -> ActionResult:
	var placed: ActionResult = _building(world).place_structure(world, definition, tile, rotation)
	if placed.ok:
		var completed: ActionResult = _building(world).complete_structure(world, str(placed.event[BuildingService.KEY_STRUCTURE_ID]))
		assert_true(completed.ok, "complete %s at %s: %s" % [definition, str(tile), completed.reason])
	return placed


func _place_vertical_barrier(world: ServerWorld, x: int, z_from: int, z_to: int, door_z: int = 1000000) -> String:
	var door_id: String = ""
	for z: int in range(z_from, z_to + 1):
		var definition: String = DOOR if z == door_z else WALL
		var placed: ActionResult = _place_completed(world, definition, Vector2i(x, z), 3)
		assert_true(placed.ok, "place %s at %d,%d: %s" % [definition, x, z, placed.reason])
		if z == door_z:
			door_id = str(placed.event[BuildingService.KEY_STRUCTURE_ID])
	return door_id


func _place_closed_building(world: ServerWorld, open_door: bool) -> String:
	_place_vertical_barrier(world, 6, 3, 7)
	var door_id: String = _place_vertical_barrier(world, 11, 3, 7, 5)
	for x: int in range(6, 11):
		assert_true(_place_completed(world, WALL, Vector2i(x, 3), 0).ok)
		assert_true(_place_completed(world, WALL, Vector2i(x, 8), 0).ok)
	if open_door:
		assert_true(_building(world).set_door_open(world, door_id, true).ok)
	return door_id


func test_navigation_settings_load_validate_and_compose_after_building() -> void:
	var loaded: NavigationSettings = NavigationSettings.load_or_default()
	assert_true(ResourceLoader.exists(NavigationSettings.DEFAULT_PATH))
	assert_eq(loaded.validate().size(), 0, "; ".join(loaded.validate()))
	assert_eq(loaded.max_planning_nodes_per_tick, 48)
	assert_eq(loaded.max_search_nodes_per_tick, 8)
	assert_eq(loaded.max_search_msec, 0.0)
	assert_eq(loaded.max_planning_msec_per_tick, 0.0)
	var broken: NavigationSettings = NavigationSettings.new()
	broken.max_expanded_nodes = 0
	broken.max_search_radius_m = 0.0
	broken.max_search_msec = -1.0
	broken.replan_goal_distance_m = -1.0
	broken.replan_timeout_sec = 0.0
	broken.min_plan_interval_sec = -1.0
	broken.max_plans_per_tick = 0
	broken.max_planning_nodes_per_tick = 0
	broken.max_search_nodes_per_tick = 0
	broken.max_planning_msec_per_tick = -1.0
	assert_eq(broken.validate().size(), 10)
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var ids: PackedStringArray = ServerComposition.create_world(WORLD, config).system_ids()
	assert_true(ids.find(NavigationService.SYSTEM_ID) > ids.find(BuildingService.SYSTEM_ID))
	config.navigation = null
	assert_true(config.validate().size() > 0)


func test_chasing_zombie_walks_around_a_wall() -> void:
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(9.5, 0.0, 5.5)
	_place_vertical_barrier(world, 6, 3, 7)
	var zombie_id: String = _spawn_chaser(world, Vector3(2.5, 0.0, 5.5), player)
	_run(world, 5.0)
	var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
	assert_true(zombie.position.x > 6.0, "went around the wall: %s" % str(zombie.position))
	assert_true(_zombies(world).total_plan_count > 0)


func test_hidden_pursuit_inside_break_distance_walks_around_wall_and_reaches_target() -> void:
	_zombie.ai_period_sec = 0.1
	_zombie.ai_bucket_count = 1
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(9.5, 0.0, 5.5)
	var zombie_id: String = str(_zombies(world).spawn_zombie(world, Vector3(2.5, 0.0, 5.5), -PI / 2.0).event["zombie_id"])
	_run(world, 0.2)
	assert_eq(_zombies(world).get_zombie(zombie_id).state, ZombieState.State.CHASE, "saw the unobstructed target first")
	_place_vertical_barrier(world, 6, 3, 7)
	_run(world, 5.0)
	var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
	assert_true(ZombiePerception.flat_distance(zombie.position, player.position) <= _zombie.attack_range_m, "kept pursuit and went around the wall: %s" % str(zombie.position))
	assert_true(zombie.state == ZombieState.State.CHASE or zombie.state == ZombieState.State.ATTACK)
	assert_eq(zombie.target_player_id, player.player_id)
	assert_true(_zombies(world).total_plan_count > 0)


func test_closed_door_keeps_chaser_out_and_opening_is_seen_by_replan() -> void:
	_navigation.max_search_radius_m = 5.0
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(7.5, 0.0, 5.5)
	var door_id: String = _place_vertical_barrier(world, 6, -1, 11, 5)
	var zombie_id: String = _spawn_chaser(world, Vector3(4.5, 0.0, 5.5), player)
	_run(world, 1.0)
	var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
	assert_true(zombie.position.x < 6.0, "closed door: %s" % str(zombie.position))
	assert_true(_building(world).set_door_open(world, door_id, true).ok)
	_run(world, 1.5)
	assert_true(zombie.position.x > 6.0, "next plan sees the open door: %s" % str(zombie.position))


func test_wall_blocks_sight_and_melee_but_open_door_does_not() -> void:
	_zombie.ai_period_sec = 0.1
	_zombie.ai_bucket_count = 1
	_zombie.attack_windup_sec = 0.0
	var wall_world: ServerWorld = _world()
	var wall_player: PlayerState = wall_world.join("wall_player")
	wall_player.position = Vector3(6.5, 0.0, 5.5)
	var wall_health: float = (wall_world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService).get_vitals(wall_player.player_id).health
	assert_true(_place_completed(wall_world, WALL, Vector2i(5, 5), 1).ok)
	var wall_zombie: String = str(_zombies(wall_world).spawn_zombie(wall_world, Vector3(5.5, 0.0, 5.5), -PI / 2.0).event["zombie_id"])
	_run(wall_world, 1.0)
	assert_eq(_zombies(wall_world).get_zombie(wall_zombie).state, ZombieState.State.IDLE, "cannot see through wall")
	assert_eq((wall_world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService).get_vitals(wall_player.player_id).health, wall_health, "cannot hit through wall")

	var door_world: ServerWorld = _world()
	var door_player: PlayerState = door_world.join("door_player")
	door_player.position = Vector3(6.5, 0.0, 5.5)
	var door_health: float = (door_world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService).get_vitals(door_player.player_id).health
	var placed: ActionResult = _place_completed(door_world, DOOR, Vector2i(5, 5), 1)
	assert_true(placed.ok)
	assert_true(_building(door_world).set_door_open(door_world, str(placed.event[BuildingService.KEY_STRUCTURE_ID]), true).ok)
	_zombies(door_world).spawn_zombie(door_world, Vector3(5.5, 0.0, 5.5), -PI / 2.0)
	_run(door_world, 1.0)
	assert_true((door_world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService).get_vitals(door_player.player_id).health < door_health, "open door permits sight and melee")


func test_planning_is_capped_per_tick_for_one_hundred_zombies() -> void:
	_navigation.max_plans_per_tick = 7
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(9.5, 0.0, 5.5)
	_place_vertical_barrier(world, 6, -20, 30)
	for index: int in range(100):
		_spawn_chaser(world, Vector3(2.5 + float(index % 4) * 0.05, 0.0, 5.05 + float(index / 4) * 0.035), player)
	world.step_systems(TICK)
	assert_eq(_zombies(world).last_plan_count, 7)
	assert_eq(_zombies(world).total_plan_count, 7)


func test_node_budget_defers_requests_in_fifo_order_without_starvation() -> void:
	_navigation.max_plans_per_tick = 100
	_navigation.max_planning_nodes_per_tick = 1
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(9.5, 0.0, 5.5)
	_place_vertical_barrier(world, 6, -20, 30)
	var ids: PackedStringArray = []
	for index: int in range(12):
		ids.append(_spawn_chaser(world, Vector3(2.5, 0.0, 4.5 + float(index) * 0.05), player))
	world.step_systems(TICK)
	assert_eq(_zombies(world).last_plan_count, 1, "one expanded node exhausted this tick's deterministic budget")
	assert_eq(_zombies(world).last_plan_node_count, 1)
	assert_eq(_zombies(world).navigation_plan_count_of(ids[0]), 1)
	assert_eq(_zombies(world).navigation_plan_count_of(ids[11]), 0, "the tail waits instead of planning over budget")
	for tick: int in range(11):
		world.step_systems(TICK)
	for zombie_id: String in ids:
		assert_eq(_zombies(world).navigation_plan_count_of(zombie_id), 1, "%s received one FIFO turn" % zombie_id)
	assert_eq(_zombies(world).total_plan_count, 12, "no early zombie replanned before every queued zombie had a turn")


func _run_determinism_scenario(with_slow_edge_query: bool) -> Dictionary:
	_navigation.max_expanded_nodes = 256
	_navigation.max_planning_nodes_per_tick = 48
	_navigation.max_search_nodes_per_tick = 4
	_navigation.max_plans_per_tick = 3
	_navigation.max_search_msec = 0.0
	_navigation.max_planning_msec_per_tick = 0.0
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(9.5, 0.0, 5.5)
	_place_vertical_barrier(world, 6, 2, 8)
	var ids: PackedStringArray = []
	for index: int in range(6):
		ids.append(_spawn_chaser(world, Vector3(2.5, 0.0, 4.25 + float(index) * 0.5), player))
	_slow_edge_building = _building(world)
	_slow_edge_query = with_slow_edge_query
	_navigation_service(world)._edge_query = Callable(self, "_edge_query_with_optional_slowdown")
	var positions: Array[Vector3] = []
	var plan_counts: PackedInt32Array = PackedInt32Array()
	var plan_turns: int = 0
	for tick: int in range(24):
		player.position.z = 4.5 + float((tick / 3) % 3)
		world.step_systems(TICK)
		for zombie_id: String in ids:
			positions.append(_zombies(world).get_zombie(zombie_id).position)
		plan_counts.append(_zombies(world).last_plan_count)
		plan_turns += _zombies(world).last_plan_count
	return {"positions": positions, "plan_counts": plan_counts, "plan_turns": plan_turns, "total_plan_count": _zombies(world).total_plan_count}


func test_fixed_seed_navigation_is_identical_with_a_slow_edge_query() -> void:
	var normal: Dictionary = _run_determinism_scenario(false)
	var slowed: Dictionary = _run_determinism_scenario(true)
	assert_true(int(normal["total_plan_count"]) > 0)
	assert_true(int(normal["plan_turns"]) > int(normal["total_plan_count"]), "at least one search resumed on a later tick")
	assert_eq(slowed["positions"], normal["positions"], "wall-clock slowdown cannot change positions")
	assert_eq(slowed["plan_counts"], normal["plan_counts"], "wall-clock slowdown cannot change per-tick plan counts")
	assert_eq(slowed["total_plan_count"], normal["total_plan_count"])


func test_pending_search_restarts_when_the_goal_moves_beyond_the_threshold() -> void:
	_navigation.max_search_nodes_per_tick = 1
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(9.5, 0.0, 5.5)
	_place_vertical_barrier(world, 6, -12, 12)
	var zombie_id: String = _spawn_chaser(world, Vector3(2.5, 0.0, 5.5), player)
	world.step_systems(TICK)
	assert_true(_zombies(world).navigation_is_waiting_for_plan(zombie_id))
	player.position = Vector3(9.5, 0.0, 7.5)
	world.step_systems(TICK)
	assert_eq(_zombies(world).navigation_search_restart_count_of(zombie_id), 1)
	assert_true(_zombies(world).navigation_is_waiting_for_plan(zombie_id))


func test_pending_search_restarts_when_a_door_changes_the_blocking_edges() -> void:
	_navigation.max_search_nodes_per_tick = 1
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(9.5, 0.0, 5.5)
	var door_id: String = _place_vertical_barrier(world, 6, -12, 12, 5)
	var zombie_id: String = _spawn_chaser(world, Vector3(2.5, 0.0, 5.5), player)
	world.step_systems(TICK)
	assert_true(_zombies(world).navigation_is_waiting_for_plan(zombie_id))
	assert_true(_building(world).set_door_open(world, door_id, true).ok)
	world.step_systems(TICK)
	assert_eq(_zombies(world).navigation_search_restart_count_of(zombie_id), 1)


func test_round_robin_resumed_searches_all_complete_within_a_tick_bound() -> void:
	_navigation.max_plans_per_tick = 4
	_navigation.max_planning_nodes_per_tick = 4
	_navigation.max_search_nodes_per_tick = 1
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(9.5, 0.0, 5.5)
	_place_vertical_barrier(world, 6, 0, 10)
	var ids: PackedStringArray = []
	for index: int in range(12):
		ids.append(_spawn_chaser(world, Vector3(2.5, 0.0, 4.9 + float(index) * 0.1), player))
	var completed_tick: int = -1
	for tick: int in range(160):
		world.step_systems(TICK)
		var all_completed: bool = true
		for zombie_id: String in ids:
			all_completed = all_completed and _zombies(world).navigation_search_completion_count_of(zombie_id) > 0
		if all_completed:
			completed_tick = tick + 1
			break
	if completed_tick < 0:
		var pending_nodes: PackedInt32Array = PackedInt32Array()
		var completions: PackedInt32Array = PackedInt32Array()
		var plans: PackedInt32Array = PackedInt32Array()
		var waits: Array[bool] = []
		for zombie_id: String in ids:
			pending_nodes.append(_zombies(world).navigation_search_expanded_nodes_of(zombie_id))
			completions.append(_zombies(world).navigation_search_completion_count_of(zombie_id))
			plans.append(_zombies(world).navigation_plan_count_of(zombie_id))
			waits.append(_zombies(world).navigation_is_waiting_for_plan(zombie_id))
		print("[diagnostic] fairness nodes=%s completions=%s plans=%s waits=%s total=%d" % [str(pending_nodes), str(completions), str(plans), str(waits), _zombies(world).total_plan_count])
	else:
		print("[measure] P3-6d round-robin: 12 one-node-slice searches completed by tick %d (%.2f s)" % [completed_tick, float(completed_tick) * TICK])
	assert_true(completed_tick > 0 and completed_tick <= 160, "all 12 searches completed by tick %d" % completed_tick)
	for zombie_id: String in ids:
		assert_true(_zombies(world).navigation_search_completion_count_of(zombie_id) > 0, zombie_id)


func test_default_navigation_reaches_around_a_forty_metre_wall_within_twenty_seconds() -> void:
	_navigation = NavigationSettings.load_or_default()
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(9.5, 0.0, 5.5)
	_place_vertical_barrier(world, 6, -14, 25)
	var zombie_id: String = _spawn_chaser(world, Vector3(2.5, 0.0, 5.5), player)
	var gap_tick: int = -1
	var reached_tick: int = -1
	var first_path_tick: int = -1
	var first_path_nodes: int = 0
	for tick: int in range(roundi(20.0 / TICK)):
		world.step_systems(TICK)
		var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
		if first_path_tick < 0 and _zombies(world).navigation_search_completion_count_of(zombie_id) > 0:
			first_path_tick = tick + 1
			first_path_nodes = _zombies(world).navigation_last_completed_search_nodes_of(zombie_id)
		if gap_tick < 0 and zombie.position.x > 6.0:
			gap_tick = tick + 1
		if ZombiePerception.flat_distance(zombie.position, player.position) <= _zombie.chase_stop_distance_m + 0.1:
			reached_tick = tick + 1
			break
	print("[acceptance] P3-6d default 40 m wall: path %d nodes, tick %d (%.2f s); gap tick %d (%.2f s), player tick %d (%.2f s)" % [first_path_nodes, first_path_tick, float(first_path_tick) * TICK, gap_tick, float(gap_tick) * TICK, reached_tick, float(reached_tick) * TICK])
	assert_true(gap_tick > 0)
	assert_true(first_path_tick > 1, "the default search resumed across ticks")
	assert_true(reached_tick > 0 and reached_tick <= roundi(20.0 / TICK))


func test_default_navigation_uses_a_far_side_open_door_but_not_a_closed_one() -> void:
	_navigation = NavigationSettings.load_or_default()
	var open_world: ServerWorld = _world()
	var open_player: PlayerState = open_world.join("open")
	open_player.position = Vector3(8.5, 0.0, 5.5)
	_place_closed_building(open_world, true)
	var open_zombie_id: String = _spawn_chaser(open_world, Vector3(2.5, 0.0, 5.5), open_player)
	_run(open_world, 12.0)
	var open_zombie: ZombieState = _zombies(open_world).get_zombie(open_zombie_id)
	assert_true(ZombiePerception.flat_distance(open_zombie.position, open_player.position) <= _zombie.chase_stop_distance_m + 0.1, "entered through the far-side open door: %s" % str(open_zombie.position))

	var closed_world: ServerWorld = _world()
	var closed_player: PlayerState = closed_world.join("closed")
	closed_player.position = Vector3(8.5, 0.0, 5.5)
	_place_closed_building(closed_world, false)
	var closed_zombie_id: String = _spawn_chaser(closed_world, Vector3(2.5, 0.0, 5.5), closed_player)
	_run(closed_world, 12.0)
	var closed_position: Vector3 = _zombies(closed_world).get_zombie(closed_zombie_id).position
	var inside: bool = closed_position.x > 6.0 and closed_position.x < 11.0 and closed_position.z > 3.0 and closed_position.z < 8.0
	assert_false(inside, "closed building kept the zombie outside: %s" % str(closed_position))


func test_one_zombie_is_rate_limited_between_failed_plans() -> void:
	_navigation.max_search_radius_m = 5.0
	_navigation.min_plan_interval_sec = 0.3
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(7.5, 0.0, 5.5)
	_place_vertical_barrier(world, 6, -1, 11)
	_spawn_chaser(world, Vector3(4.5, 0.0, 5.5), player)
	world.step_systems(TICK)
	assert_eq(_zombies(world).total_plan_count, 1)
	for tick: int in range(5):
		world.step_systems(TICK)
	assert_eq(_zombies(world).total_plan_count, 1, "no retry inside the per-zombie interval")
	world.step_systems(TICK)
	assert_eq(_zombies(world).total_plan_count, 2)


func test_inactive_zombie_is_not_moved_or_planned() -> void:
	var world: ServerWorld = _world(0)
	var player: PlayerState = world.join("alice")
	player.position = Vector3(5.5, 0.0, 5.5)
	assert_true(_place_completed(world, WALL, Vector2i(10, 0), 1).ok)
	var zombie_id: String = _spawn_chaser(world, Vector3(15.5, 0.0, 5.5), player)
	var before: Vector3 = _zombies(world).get_zombie(zombie_id).position
	_run(world, 1.0)
	assert_eq(_zombies(world).get_zombie(zombie_id).position, before)
	assert_eq(_zombies(world).total_plan_count, 0)


## P3-5 and P3-3b: blueprints (a wall that is placed but not built) and the
## storage box (a tile piece) are no blocking edges, so the path finder and
## the line checks ignore them: the zombie keeps the plain straight step.
func test_blueprints_and_a_storage_box_block_neither_paths_nor_sight() -> void:
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(9.5, 0.0, 5.5)
	for z: int in range(-1, 12):
		assert_true(_building(world).place_structure(world, WALL, Vector2i(6, z), 3).ok, "blueprint wall at z %d" % z)
	var box: ActionResult = _place_completed(world, "dev_storage_box", Vector2i(4, 5), 0)
	assert_true(box.ok, "storage box: %s" % box.reason)
	assert_true(_building(world).get_structure(str(box.event[BuildingService.KEY_STRUCTURE_ID])).is_standing())
	assert_eq(_navigation_service(world).blocking_edge_count(), 0, "nothing here is a blocking edge")
	var from: Vector3 = Vector3(2.5, 0.0, 5.5)
	assert_false(world.is_line_blocked(from, player.position), "sight passes over the box and through the blueprints")
	var path: GridPathResult = _navigation_service(world).find_path(from, player.position)
	assert_true(path.found)
	assert_eq(path.waypoints.back(), player.position)
	for waypoint: Vector3 in path.waypoints:
		assert_eq(waypoint.z, 5.5, "the straight way: %s" % str(path.waypoints))
	var zombie_id: String = _spawn_chaser(world, from, player)
	_run(world, 3.0)
	assert_true(_zombies(world).get_zombie(zombie_id).position.x > 6.0, "it walked straight through: %s" % str(_zombies(world).get_zombie(zombie_id).position))
	assert_eq(_zombies(world).total_plan_count, 0, "and never needed a path")
	assert_eq(_zombies(world).obstructed_move_count, 0)


func test_no_structures_preserves_the_straight_step_exactly() -> void:
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = Vector3(20.5, 0.0, 5.5)
	var zombie_id: String = _spawn_chaser(world, Vector3(2.5, 0.0, 5.5), player)
	var before: Vector3 = _zombies(world).get_zombie(zombie_id).position
	world.step_systems(TICK)
	var expected: Vector3 = before + Vector3(1.0, 0.0, 0.0) * _zombie.chase_speed_mps * TICK
	assert_eq(_zombies(world).get_zombie(zombie_id).position, expected)
	assert_eq(_zombies(world).total_plan_count, 0)
	assert_false(_navigation_service(world).is_line_blocked(before, player.position))
