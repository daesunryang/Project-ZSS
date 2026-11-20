extends TestCase
## P2-A3: player movement noise — FootstepRules (pure) and
## PlayerNoiseService (footsteps from server-side position changes).

const WORLD: String = "player_noise_test_world"
const TICK: float = 0.05
const TICK_MSEC: int = 50
const INPUT_TIMEOUT_MSEC: int = 500
const NEVER: float = 1.0e9
const TOLERANCE: float = 0.0001
const WALK_PLUS_X: Vector2 = Vector2(1, 0)

const STRIDE: float = 2.0
const LOUDNESS: float = 8.0

var _settings: PlayerNoiseSettings = null
var _zombie_settings: ZombieSettings = null
var _survival_settings: SurvivalSettings = null
var _noise_settings: NoiseSettings = null
var _gameplay: GameplaySettings = null
var _now_msec: int = 0
var _sequence: int = 0
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = PlayerNoiseSettings.new()
	_settings.stride_length_m = STRIDE
	_settings.footstep_loudness = LOUDNESS
	_settings.min_speed_mps = 0.5
	_settings.teleport_speed_mps = 15.0
	_settings.max_footsteps_per_tick = 4
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER
	_survival_settings = SurvivalSettings.new()
	# Isolate from survival time rules (see zombie_service_test).
	_survival_settings.health_recovery_per_world_sec = 0.0
	_survival_settings.respawn_delay_sec = NEVER
	_noise_settings = NoiseSettings.new()
	_gameplay = GameplaySettings.new()
	_now_msec = 0
	_sequence = 0
	_root = "user://test_saves/player_noise_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = _gameplay
	config.clock = WorldClockSettings.new()
	config.survival = _survival_settings
	config.noise = _noise_settings
	config.zombie = _zombie_settings
	config.player_noise = _settings
	return config


func _world() -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	world.seed_new_world(DevWorldSeed.new())
	return world


func _footsteps(world: ServerWorld) -> PlayerNoiseService:
	return world.get_system(PlayerNoiseService.SYSTEM_ID) as PlayerNoiseService


func _noise(world: ServerWorld) -> NoiseService:
	return world.get_system(NoiseService.SYSTEM_ID) as NoiseService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


## One server tick the way NetworkService runs it: movement, then systems.
func _tick(world: ServerWorld) -> void:
	_now_msec += TICK_MSEC
	world.step_movement(TICK, _now_msec, INPUT_TIMEOUT_MSEC)
	world.step_systems(TICK)


## Walks `player` with a move intent (server speed x direction) for
## `seconds`, then stops (clients send a zero direction when they stop).
func _walk(world: ServerWorld, player: PlayerState, direction: Vector2, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		_sequence += 1
		world.set_move_input(player.player_id, _sequence, direction, 0.0, _now_msec + TICK_MSEC)
		_tick(world)
	_sequence += 1
	world.set_move_input(player.player_id, _sequence, Vector2.ZERO, 0.0, _now_msec)


func _sprint(world: ServerWorld, player: PlayerState, direction: Vector2, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		_sequence += 1
		world.set_move_input(player.player_id, _sequence, direction, 0.0, _now_msec + TICK_MSEC, true)
		_tick(world)
	_sequence += 1
	world.set_move_input(player.player_id, _sequence, Vector2.ZERO, 0.0, _now_msec)


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		_tick(world)


# ------------------------------------------------------------ pure rules

func test_footstep_positions_follow_the_path() -> void:
	# 1.5 m already walked since the last step, stride 2 m, 3 m more along +X:
	# steps after 0.5 m and 2.5 m.
	var positions: PackedVector3Array = FootstepRules.footstep_positions(Vector3(10, 1, 5), Vector3(13, 1, 5), 1.5, STRIDE, 8)
	assert_eq(positions.size(), 2)
	assert_true(positions[0].is_equal_approx(Vector3(10.5, 1, 5)), str(positions[0]))
	assert_true(positions[1].is_equal_approx(Vector3(12.5, 1, 5)), str(positions[1]))
	assert_true(absf(FootstepRules.carried_after(1.5, 3.0, STRIDE) - 0.5) <= TOLERANCE)
	assert_eq(FootstepRules.footstep_positions(Vector3.ZERO, Vector3(1.9, 0, 0), 0.0, STRIDE, 8).size(), 0, "less than one stride")
	assert_true(absf(FootstepRules.carried_after(0.0, 1.9, STRIDE) - 1.9) <= TOLERANCE)
	assert_eq(FootstepRules.footstep_positions(Vector3.ZERO, Vector3.ZERO, 1.9, STRIDE, 8).size(), 0, "no movement, no step")
	assert_eq(FootstepRules.footstep_positions(Vector3.ZERO, Vector3(0, 0, 9), 0.0, 1.0, 3).size(), 3, "capped per tick")
	assert_true(FootstepRules.footstep_positions(Vector3.ZERO, Vector3(0, 0, 9), 0.0, 1.0, 3)[2].is_equal_approx(Vector3(0, 0, 3)), "the earliest steps are kept")
	assert_eq(FootstepRules.footstep_positions(Vector3.ZERO, Vector3(0, 7, 0), 0.0, 1.0, 8).size(), 0, "vertical movement is not walking (XZ plane)")


func test_footstep_rules_reject_invalid_input() -> void:
	assert_eq(FootstepRules.footstep_positions(Vector3(NAN, 0, 0), Vector3(3, 0, 0), 0.0, STRIDE, 8).size(), 0)
	assert_eq(FootstepRules.footstep_positions(Vector3.ZERO, Vector3(INF, 0, 0), 0.0, STRIDE, 8).size(), 0)
	assert_eq(FootstepRules.footstep_positions(Vector3.ZERO, Vector3(3, 0, 0), NAN, STRIDE, 8).size(), 0)
	assert_eq(FootstepRules.footstep_positions(Vector3.ZERO, Vector3(3, 0, 0), 0.0, 0.0, 8).size(), 0)
	assert_eq(FootstepRules.footstep_positions(Vector3.ZERO, Vector3(3, 0, 0), 0.0, STRIDE, 0).size(), 0)
	assert_eq(FootstepRules.carried_after(NAN, 1.0, STRIDE), 0.0)
	assert_eq(FootstepRules.carried_after(1.0, 1.0, 0.0), 0.0)


func test_walking_and_teleport_thresholds() -> void:
	assert_true(FootstepRules.is_walking(0.2, 0.05, 0.5), "4 m/s")
	assert_false(FootstepRules.is_walking(0.02, 0.05, 0.5), "0.4 m/s is below the minimum speed")
	assert_false(FootstepRules.is_walking(0.0, 0.05, 0.0), "standing still is never walking")
	assert_false(FootstepRules.is_walking(0.2, 0.0, 0.5), "no time passed")
	assert_false(FootstepRules.is_walking(NAN, 0.05, 0.5))
	assert_true(FootstepRules.is_teleport(0.8, 0.05, 15.0), "16 m/s is faster than anyone walks")
	assert_false(FootstepRules.is_teleport(0.7, 0.05, 15.0), "14 m/s")
	assert_false(FootstepRules.is_teleport(0.2, 0.05, 15.0))
	assert_false(FootstepRules.is_teleport(4.4, 1.0, 15.0), "a long tick at walking speed is not a teleport")
	assert_true(FootstepRules.is_teleport(0.2, 0.0, 15.0), "movement in no time")
	assert_false(FootstepRules.is_teleport(0.0, 0.0, 15.0))
	assert_true(FootstepRules.is_teleport(NAN, 0.05, 15.0), "a broken distance is never treated as walking")
	assert_true(absf(FootstepRules.flat_distance(Vector3(1, 9, 1), Vector3(4, -3, 5)) - 5.0) <= TOLERANCE, "XZ plane only")


# ------------------------------------------------------------ setup

func test_default_settings_and_composition() -> void:
	var loaded: PlayerNoiseSettings = PlayerNoiseSettings.load_or_default()
	assert_true(ResourceLoader.exists(PlayerNoiseSettings.DEFAULT_PATH))
	assert_eq(loaded.validate().size(), 0, "; ".join(loaded.validate()))
	assert_eq(loaded.footstep_loudness, 6.0)
	assert_eq(loaded.sprint_footstep_loudness, 13.0)
	assert_eq(NoiseService.new(NoiseSettings.load_or_default(), WorldClock.new(), 250.0).max_audible_distance(loaded.footstep_loudness, 1.0), 5.0)
	assert_eq(NoiseService.new(NoiseSettings.load_or_default(), WorldClock.new(), 250.0).max_audible_distance(loaded.sprint_footstep_loudness, 1.0), 12.0)
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var ids: PackedStringArray = ServerComposition.create_world(WORLD, config).system_ids()
	assert_true(ids.find(PlayerNoiseService.SYSTEM_ID) > ids.find(NoiseService.SYSTEM_ID), "after the noise system it emits into")
	assert_true(ids.find(PlayerNoiseService.SYSTEM_ID) < ids.find(ZombieService.SYSTEM_ID), "before the zombies that listen")
	var broken: PlayerNoiseSettings = PlayerNoiseSettings.new()
	broken.stride_length_m = 0.0
	broken.footstep_loudness = -1.0
	broken.sprint_footstep_loudness = -1.0
	broken.min_speed_mps = NAN
	broken.teleport_speed_mps = 0.0
	broken.max_footsteps_per_tick = 0
	assert_true(broken.validate().size() >= 6, "; ".join(broken.validate()))
	config.player_noise = PlayerNoiseSettings.new()
	config.player_noise.footstep_loudness = config.noise.max_loudness + 1.0
	assert_true(config.validate().size() > 0, "louder than the noise system accepts")
	config.player_noise = PlayerNoiseSettings.new()
	config.player_noise.sprint_footstep_loudness = config.noise.max_loudness + 1.0
	assert_true(config.validate().size() > 0, "running louder than the noise system accepts")
	config.player_noise = PlayerNoiseSettings.new()
	config.player_noise.footstep_frequency_profile = "ultrasonic"
	assert_true(config.validate().size() > 0, "unknown frequency profile")


# ------------------------------------------------------------ footsteps

func test_footsteps_are_proportional_to_the_distance_walked() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var service: PlayerNoiseService = _footsteps(world)
	_run(world, 1.0)
	assert_eq(service.total_footstep_count, 0)
	# 5.25 s at 4 m/s = 21 m = 10.5 strides.
	_walk(world, alice, WALK_PLUS_X, 5.25)
	assert_true(absf(alice.position.x - 21.0) <= TOLERANCE)
	assert_eq(service.total_footstep_count, 10)
	var noise: NoiseService = _noise(world)
	assert_eq(noise.active_count(), 10, "one noise event per footstep")
	for step: int in range(1, 11):
		var event: NoiseEvent = noise.get_event(NoiseService.NOISE_ID_PREFIX + str(step))
		assert_not_null(event)
		assert_eq(event.source_id, alice.player_id)
		assert_eq(event.loudness, LOUDNESS)
		assert_eq(event.frequency_profile, _settings.footstep_frequency_profile)
		assert_true(event.position.is_equal_approx(Vector3(STRIDE * step, 0, 0)), "footstep %d at %s" % [step, str(event.position)])
	# 20 m more (41 m in total = 20.5 strides): twice the distance, twice the steps.
	_walk(world, alice, WALK_PLUS_X, 5.0)
	assert_eq(service.total_footstep_count, 20)


func test_one_long_tick_gives_the_same_steps_as_many_short_ones() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var service: PlayerNoiseService = _footsteps(world)
	world.step_systems(TICK)
	alice.position += Vector3(4.4, 0, 0)
	world.step_systems(1.0)
	assert_eq(service.last_footstep_count, 2)
	assert_eq(service.total_footstep_count, 2)
	assert_true(_noise(world).get_event(NoiseService.NOISE_ID_PREFIX + "1").position.is_equal_approx(Vector3(2, 0, 0)))
	assert_true(_noise(world).get_event(NoiseService.NOISE_ID_PREFIX + "2").position.is_equal_approx(Vector3(4, 0, 0)))
	# 0.4 m is carried over: 1.7 m more completes the third stride.
	alice.position += Vector3(1.7, 0, 0)
	world.step_systems(1.0)
	assert_eq(service.total_footstep_count, 3)
	world.step_systems(1.0)
	assert_eq(service.last_footstep_count, 0, "the per-tick counter resets")

	_settings.max_footsteps_per_tick = 1
	alice.position += Vector3(4.5, 0, 0)
	world.step_systems(1.5)
	assert_eq(service.last_footstep_count, 1, "capped per tick; the extra steps are dropped")


func test_running_uses_the_server_authorized_loudness() -> void:
	_settings.footstep_loudness = 6.0
	_settings.sprint_footstep_loudness = 13.0
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	_run(world, 0.1)
	_sprint(world, alice, WALK_PLUS_X, 0.5)
	var latest: NoiseEvent = _noise(world).get_event(NoiseService.NOISE_ID_PREFIX + str(_footsteps(world).total_footstep_count))
	assert_not_null(latest)
	if latest != null:
		assert_eq(latest.loudness, 13.0)
	assert_true(_survival(world).get_vitals(alice.player_id).stamina < _survival_settings.max_stamina, "running spent server stamina")


func test_standing_or_creeping_players_make_no_noise() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var service: PlayerNoiseService = _footsteps(world)
	_run(world, 5.0)
	_walk(world, alice, Vector2.ZERO, 5.0)
	assert_eq(service.total_footstep_count, 0, "standing still")
	# 10 % stick: 0.4 m/s, below min_speed_mps (0.5). 8 m in 20 s.
	_walk(world, alice, Vector2(0.1, 0), 20.0)
	assert_true(alice.position.x > 7.9)
	assert_eq(service.total_footstep_count, 0, "slower than the minimum speed")
	assert_eq(_noise(world).active_count(), 0)
	_settings.min_speed_mps = 0.0
	_walk(world, alice, Vector2(0.1, 0), 20.5)
	assert_eq(service.total_footstep_count, 4, "without a minimum speed 8.2 m make 4 steps")


func test_dead_players_make_no_noise_and_respawn_is_not_a_footstep() -> void:
	_survival_settings.respawn_delay_sec = 2.0
	_gameplay.player_spawn_position = Vector3(1, 0, 0)
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var service: PlayerNoiseService = _footsteps(world)
	_run(world, 0.5)
	_walk(world, alice, WALK_PLUS_X, 0.75)  # 3 m: one step, 1 m carried
	assert_eq(service.total_footstep_count, 1)
	var fatal: DamageInput = DamageInput.create("zombie_000099", BodyPart.Part.TORSO, Wound.Type.BITE, 1000.0)
	assert_true(_survival(world).apply_damage(alice.player_id, fatal).ok)
	# The server does not stop a dead player's movement yet; it is silent.
	_walk(world, alice, WALK_PLUS_X, 1.0)
	assert_false(_survival(world).is_alive(alice.player_id))
	assert_eq(service.total_footstep_count, 1, "dead players make no footsteps")
	# Respawn moves her 7 m back to the spawn point: not a footstep, and the
	# distance carried before death is forgotten.
	_run(world, 1.5)
	assert_true(_survival(world).is_alive(alice.player_id), "respawned")
	assert_eq(alice.position, _gameplay.player_spawn_position)
	assert_eq(service.total_footstep_count, 1)
	_walk(world, alice, WALK_PLUS_X, 0.45)  # 1.8 m
	assert_eq(service.total_footstep_count, 1, "a new life starts a new stride")
	_walk(world, alice, WALK_PLUS_X, 0.1)
	assert_eq(service.total_footstep_count, 2, "walking after the respawn is heard again")


func test_respawn_close_to_the_spawn_point_is_not_a_footstep() -> void:
	# Death and respawn inside one tick: the service never sees her dead, but
	# 2.4 m in one tick is far above any walking speed.
	_survival_settings.respawn_delay_sec = 0.0
	_settings.stride_length_m = 1.0
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var service: PlayerNoiseService = _footsteps(world)
	_run(world, 0.5)
	_walk(world, alice, WALK_PLUS_X, 0.6)  # 2.4 m from the spawn point
	var before: int = service.total_footstep_count
	assert_eq(before, 2)
	var fatal: DamageInput = DamageInput.create("zombie_000099", BodyPart.Part.TORSO, Wound.Type.BITE, 1000.0)
	assert_true(_survival(world).apply_damage(alice.player_id, fatal).ok)
	_run(world, 0.5)
	assert_true(_survival(world).is_alive(alice.player_id))
	assert_eq(alice.position, _gameplay.player_spawn_position)
	assert_eq(service.total_footstep_count, before, "the 2.4 m jump back to the spawn point is silent")


func test_offline_players_make_no_noise() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	bob.position = Vector3(50, 0, 50)
	var service: PlayerNoiseService = _footsteps(world)
	_run(world, 0.5)
	world.leave(bob.player_id)
	for tick: int in range(40):
		bob.position += Vector3(0.2, 0, 0)  # 8 m while offline
		_tick(world)
	assert_eq(service.total_footstep_count, 0, "offline players are not tracked")
	_walk(world, alice, WALK_PLUS_X, 1.1)  # 4.4 m
	assert_eq(service.total_footstep_count, 2)
	# Coming back 3 m away from where he left is not walking either.
	bob.position += Vector3(3, 0, 0)
	assert_not_null(world.join("bob"))
	_run(world, 0.5)
	assert_eq(service.total_footstep_count, 2)
	for noise_number: int in range(1, 3):
		assert_eq(_noise(world).get_event(NoiseService.NOISE_ID_PREFIX + str(noise_number)).source_id, alice.player_id)


func test_teleports_are_not_footsteps() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var service: PlayerNoiseService = _footsteps(world)
	_run(world, 0.5)
	_walk(world, alice, WALK_PLUS_X, 0.45)  # 1.8 m carried
	assert_eq(service.total_footstep_count, 0)
	alice.position = Vector3(100, 0, 100)
	_tick(world)
	assert_eq(service.total_footstep_count, 0, "a jump faster than teleport_speed_mps is not walking")
	_walk(world, alice, WALK_PLUS_X, 0.1)
	assert_eq(service.total_footstep_count, 0, "the carried distance was dropped by the jump")
	_walk(world, alice, WALK_PLUS_X, 0.45)
	assert_eq(service.total_footstep_count, 1, "normal walking continues afterwards")
	assert_true(_noise(world).get_event(NoiseService.NOISE_ID_PREFIX + "1").position.is_equal_approx(Vector3(102, 0, 100)))


func test_no_footsteps_while_the_world_clock_is_paused() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var service: PlayerNoiseService = _footsteps(world)
	_run(world, 0.5)
	for tick: int in range(100):
		alice.position += Vector3(0.2, 0, 0)
		service.step(world, 0.0, 0.0)  # both deltas 0 = clock paused
	assert_eq(service.total_footstep_count, 0)
	assert_eq(_noise(world).active_count(), 0)
	# Movement during the pause is not counted afterwards.
	_walk(world, alice, WALK_PLUS_X, 0.45)
	assert_eq(service.total_footstep_count, 0)
	_walk(world, alice, WALK_PLUS_X, 0.1)
	assert_eq(service.total_footstep_count, 1)


func test_zero_loudness_disables_footsteps() -> void:
	_settings.footstep_loudness = 0.0
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	_walk(world, alice, WALK_PLUS_X, 5.0)
	assert_eq(_footsteps(world).total_footstep_count, 0)
	assert_eq(_noise(world).active_count(), 0)


func test_footstep_noise_expires_and_nothing_is_saved() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var service: PlayerNoiseService = _footsteps(world)
	_run(world, 0.5)
	_walk(world, alice, WALK_PLUS_X, 30.25)  # 121 m
	assert_eq(service.total_footstep_count, 60)
	var per_second: float = _gameplay.move_speed_mps / STRIDE
	assert_true(_noise(world).active_count() <= ceili(_noise_settings.event_lifetime_sec * per_second) + 1, "old footsteps fade: %d active" % _noise(world).active_count())
	assert_eq(service.to_world_document().size(), 0)
	assert_eq(service.to_player_fragment(alice.player_id).size(), 0)
	var documents: Dictionary = world.to_documents()
	assert_false(((documents["world_state"] as Dictionary)[ServerWorld.KEY_SYSTEMS] as Dictionary).has(PlayerNoiseService.SYSTEM_ID), "no world document")
	assert_eq(SaveService.new(_root).save_world(WORLD, documents["world_state"], documents["players"]), OK)
	var loaded: Dictionary = SaveService.new(_root).load_world(WORLD)
	var restored_world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_eq(restored_world.restore_documents(loaded["world_state"], loaded["players"]).size(), 0)
	var restored_alice: PlayerState = restored_world.join("alice")
	_run(restored_world, 0.5)
	_walk(restored_world, restored_alice, WALK_PLUS_X, 1.1)  # 4.4 m
	assert_eq(_footsteps(restored_world).total_footstep_count, 2, "footsteps simply start again after a load")


# ------------------------------------------------------------ integration

## Alice walks past 5 m behind a zombie that faces away from her. Returns
## the zombie events of the walk.
func _walk_behind_zombie(world: ServerWorld) -> Array[Dictionary]:
	var alice: PlayerState = world.join("alice")
	alice.position = Vector3(-12, 0, 5)
	var zombies: ZombieService = _zombies(world)
	zombies.spawn_zombie(world, Vector3.ZERO, 0.0)  # faces -Z, she is on the +Z side
	_run(world, 1.0)
	zombies.drain_events()
	var events: Array[Dictionary] = []
	for tick: int in range(roundi(6.0 / TICK)):
		_sequence += 1
		world.set_move_input(alice.player_id, _sequence, WALK_PLUS_X, 0.0, _now_msec + TICK_MSEC)
		_tick(world)
		events.append_array(zombies.drain_events())
	return events


func test_zombie_hears_a_player_walking_behind_it() -> void:
	var world: ServerWorld = _world()
	var events: Array[Dictionary] = _walk_behind_zombie(world)
	var alice_id: String = world.online_player_ids()[0]
	var detections: Array[Dictionary] = events.filter(func(event: Dictionary) -> bool: return event["event_type"] == ZombieService.EVENT_DETECTED)
	assert_true(detections.size() > 0, "the zombie noticed something")
	if detections.is_empty():
		return
	assert_eq(detections[0]["sense"], ZombieService.SENSE_SOUND, "first by sound: she was never in its view cone")
	assert_eq(detections[0]["target_id"], alice_id, "the footsteps are hers")
	var heard_at: Array = detections[0]["position"]
	assert_true(absf(float(heard_at[2]) - 5.0) <= TOLERANCE and absf(float(heard_at[0])) < 5.0, "heard where she walked, within hearing distance: %s" % str(heard_at))
	var changes: Array[Dictionary] = events.filter(func(event: Dictionary) -> bool: return event["event_type"] == ZombieService.EVENT_STATE_CHANGED)
	assert_eq(changes[0]["from"], "idle")
	assert_eq(changes[0]["to"], "investigate")
	assert_eq(changes[0]["cause"], ZombieService.CAUSE_NOISE)
	assert_true(_footsteps(world).total_footstep_count >= 10)


func test_without_footsteps_the_same_walk_goes_unnoticed() -> void:
	_settings.footstep_loudness = 0.0
	var world: ServerWorld = _world()
	var events: Array[Dictionary] = _walk_behind_zombie(world)
	assert_eq(events.size(), 0, "silent walking behind the zombie: no detection, no state change")
	assert_eq(ZombieState.state_name(_zombies(world).get_zombie(_zombies(world).zombie_ids()[0]).state), "idle")
