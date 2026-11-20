extends TestCase
## P2-B5a: server movement speed is scaled by the systems' per-player
## movement multipliers (survival wounds/needs, death).

const WORLD: String = "movement_multiplier_test_world"
const INPUT_TIMEOUT_MSEC: int = 1000
const EPSILON: float = 0.0001


## Test double: a system that reports a fixed multiplier.
class FixedMultiplierSystem extends ServerSystem:
	var system_id: String = "fixed_multiplier"
	var multiplier: float = 1.0

	func get_system_id() -> String:
		return system_id

	func player_movement_multiplier(_player_id: String) -> float:
		return multiplier


var _survival_settings: SurvivalSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_survival_settings = SurvivalSettings.new()
	# Keep survival time rules out of these movement checks.
	_survival_settings.health_recovery_per_world_sec = 0.0
	_survival_settings.wound_recovery_per_world_sec = 0.0


func after_each() -> void:
	GameLogger.set_capture(false)


func _world() -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.survival = _survival_settings
	# from_defaults() returns cached, shared resources: never mutate them.
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	return ServerComposition.create_world(WORLD, config)


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


## Moves +X for one second and returns the distance covered.
func _walk_one_second(world: ServerWorld, player: PlayerState, sequence: int) -> float:
	var before: float = player.position.x
	assert_eq(world.set_move_input(player.player_id, sequence, Vector2(1, 0), 0.0, 0), "")
	world.step_movement(1.0, 0, INPUT_TIMEOUT_MSEC)
	return player.position.x - before


func _run_one_second(world: ServerWorld, player: PlayerState, sequence: int) -> float:
	var before: float = player.position.x
	assert_eq(world.set_move_input(player.player_id, sequence, Vector2(1, 0), 0.0, 0, true), "")
	world.step_movement(1.0, 0, INPUT_TIMEOUT_MSEC)
	return player.position.x - before


func test_healthy_player_moves_at_full_speed() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	assert_true(absf(_walk_one_second(world, alice, 1) - world.gameplay.move_speed_mps) < EPSILON)
	assert_eq(world.player_movement_multiplier(alice.player_id), 1.0)


func test_server_authorizes_run_speed_and_spends_stamina() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var survival: SurvivalService = _survival(world)
	var stamina_before: float = survival.get_vitals(alice.player_id).stamina
	assert_true(absf(_run_one_second(world, alice, 1) - world.gameplay.run_speed_mps) < EPSILON)
	assert_true(world.is_player_sprinting(alice.player_id))
	assert_true(absf(survival.get_vitals(alice.player_id).stamina - (stamina_before - _survival_settings.sprint_stamina_cost_per_sec)) < EPSILON)


func test_zero_stamina_and_prone_players_cannot_run() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var survival: SurvivalService = _survival(world)
	survival.get_vitals(alice.player_id).stamina = 0.0
	assert_true(absf(_run_one_second(world, alice, 1) - world.gameplay.move_speed_mps) < EPSILON, "zero stamina falls back to walking")
	assert_false(world.is_player_sprinting(alice.player_id))
	survival.get_vitals(alice.player_id).stamina = _survival_settings.max_stamina
	var posture: PostureService = world.get_system(PostureService.SYSTEM_ID) as PostureService
	assert_true(posture.request_posture(world, alice.player_id, PlayerPosture.Kind.PRONE).ok)
	var moved: float = _run_one_second(world, alice, 2)
	assert_true(absf(moved - world.gameplay.move_speed_mps * PostureSettings.load_or_default().prone_movement_multiplier) < EPSILON, "prone stays crawl-speed")
	assert_false(world.is_player_sprinting(alice.player_id))


func test_leg_wound_slows_server_movement() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.LEFT_LEG, Wound.Type.BRUISE, 25.0))
	var expected: float = survival.movement_speed_multiplier(alice.player_id)
	assert_true(expected < 1.0 and expected > 0.0, "leg wound gives a partial multiplier: %f" % expected)
	var moved: float = _walk_one_second(world, alice, 1)
	assert_true(absf(moved - world.gameplay.move_speed_mps * expected) < EPSILON, "moved %f" % moved)


func test_arm_wound_does_not_slow_movement() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	_survival(world).apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.LEFT_ARM, Wound.Type.BRUISE, 25.0))
	assert_true(absf(_walk_one_second(world, alice, 1) - world.gameplay.move_speed_mps) < EPSILON)


func test_dead_player_cannot_move() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	_survival(world).apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.LACERATION, 500.0))
	assert_eq(world.player_movement_multiplier(alice.player_id), 0.0)
	assert_eq(_walk_one_second(world, alice, 1), 0.0, "dead players stay where they died")


func test_multipliers_of_all_systems_are_multiplied_and_clamped() -> void:
	var world: ServerWorld = ServerWorld.new(WORLD, GameplaySettings.new(), ItemCatalog.load_directory())
	var first: FixedMultiplierSystem = FixedMultiplierSystem.new()
	var second: FixedMultiplierSystem = FixedMultiplierSystem.new()
	second.system_id = "fixed_multiplier_b"
	assert_eq(world.register_system(first), OK)
	assert_eq(world.register_system(second), OK)
	var alice: PlayerState = world.join("alice")
	first.multiplier = 0.5
	second.multiplier = 0.5
	assert_true(absf(world.player_movement_multiplier(alice.player_id) - 0.25) < EPSILON, "product of systems")
	assert_true(absf(_walk_one_second(world, alice, 1) - world.gameplay.move_speed_mps * 0.25) < EPSILON)
	first.multiplier = 3.0
	second.multiplier = 1.0
	assert_eq(world.player_movement_multiplier(alice.player_id), 1.0, "systems can never speed a player up")
	first.multiplier = -2.0
	assert_eq(world.player_movement_multiplier(alice.player_id), 0.0, "negative values stop the player")
	first.multiplier = NAN
	assert_eq(world.player_movement_multiplier(alice.player_id), 0.0, "invalid values stop the player")


func test_world_without_systems_keeps_phase1_speed() -> void:
	var world: ServerWorld = ServerWorld.new(WORLD, GameplaySettings.new(), ItemCatalog.load_directory())
	var alice: PlayerState = world.join("alice")
	assert_eq(world.player_movement_multiplier(alice.player_id), 1.0)
	assert_true(absf(_walk_one_second(world, alice, 1) - world.gameplay.move_speed_mps) < EPSILON)
