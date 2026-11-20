extends TestCase
## P2-T11 (user decision 2026-11-15, docs/00 ADR-017, docs/09 §14.26): a
## player can lie prone, and how well a zombie sees a player depends on the
## player's posture and movement: a moving player is seen best, a sleeping
## player a little less, a prone player least. Server rules only, no network.

const WORLD: String = "posture_test_world"
const NEVER: float = 1.0e9
const EPSILON: float = 0.001
const TICK: float = 0.05
const INPUT_TIMEOUT_MSEC: int = 1000
const LETHAL_DAMAGE: float = 100000.0
const AIM_MINUS_Z: float = 0.0
const FOOD: String = "t11_food"
## Yaw facing -Z (the zombie convention: yaw 0 looks along -Z).
const YAW_MINUS_Z: float = 0.0
const SIGHT_RANGE: float = 20.0

var _settings: PostureSettings = null
var _survival_settings: SurvivalSettings = null
var _zombie_settings: ZombieSettings = null
var _noise_settings: PlayerNoiseSettings = null
var _gameplay: GameplaySettings = null
var _now_msec: int = 0
var _sequence: int = 0


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = PostureSettings.new()
	_survival_settings = SurvivalSettings.new()
	_survival_settings.respawn_delay_sec = NEVER
	_survival_settings.health_recovery_per_world_sec = 0.0
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER
	_zombie_settings.sight_range_m = SIGHT_RANGE
	# Sight only: these tests are about what a zombie sees.
	_zombie_settings.hearing_multiplier = 0.0
	_noise_settings = PlayerNoiseSettings.new()
	_gameplay = GameplaySettings.new()
	_now_msec = 0
	_sequence = 0


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var food: ItemDefinition = ItemDefinition.new()
	food.definition_id = FOOD
	food.max_stack = 5
	food.consume_hunger_reduction = 30.0
	catalog.add(food)
	return catalog


func _world() -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.gameplay = _gameplay
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = 1.0
	config.catalog = _catalog()
	config.dev_seed = DevWorldSeed.new()
	config.survival = _survival_settings
	config.zombie = _zombie_settings
	config.player_noise = _noise_settings
	config.posture = _settings
	return ServerComposition.create_world(WORLD, config)


func _posture(world: ServerWorld) -> PostureService:
	return world.get_system(PostureService.SYSTEM_ID) as PostureService


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _noise(world: ServerWorld) -> NoiseService:
	return world.get_system(NoiseService.SYSTEM_ID) as NoiseService


func _near(actual: float, expected: float, tolerance: float = EPSILON) -> bool:
	return absf(actual - expected) <= tolerance


func _want(world: ServerWorld, player: PlayerState, posture: PlayerPosture.Kind) -> ActionResult:
	return _posture(world).request_posture(world, player.player_id, posture)


## One server tick: movement, then the systems (the order NetworkService uses).
func _tick(world: ServerWorld, delta: float = TICK) -> void:
	_now_msec += roundi(delta * 1000.0)
	world.step_movement(delta, _now_msec, INPUT_TIMEOUT_MSEC)
	world.step_systems(delta)


## Keeps `player` walking along `direction` for `seconds`.
func _walk(world: ServerWorld, player: PlayerState, direction: Vector2, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		_sequence += 1
		assert_eq(world.set_move_input(player.player_id, _sequence, direction, 0.0, _now_msec), "")
		_tick(world)


## Stands still for `seconds` (the move input goes stale / is zero).
func _stand(world: ServerWorld, player: PlayerState, seconds: float) -> void:
	_sequence += 1
	assert_eq(world.set_move_input(player.player_id, _sequence, Vector2.ZERO, 0.0, _now_msec), "")
	for tick: int in range(roundi(seconds / TICK)):
		_tick(world)


func _spawn_zombie(world: ServerWorld, position: Vector3, yaw: float = YAW_MINUS_Z) -> String:
	var result: ActionResult = _zombies(world).spawn_zombie(world, position, yaw)
	return str(result.event.get("zombie_id", ""))


func _zombie_state(world: ServerWorld, zombie_id: String) -> String:
	return ZombieState.state_name(_zombies(world).get_zombie(zombie_id).state)


## A fresh world with one zombie at the origin looking along -Z and "alice"
## `distance` metres in front of it, in `posture`, standing still unless
## `walking`. Returns true when the zombie sees her within a few decisions.
func _zombie_sees(posture: PlayerPosture.Kind, distance: float, walking: bool = false) -> bool:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	alice.position = Vector3(0.0, 0.0, -distance)
	# Let the placement (a jump) age out of the movement memory.
	_stand(world, alice, _settings.moving_memory_sec + 4.0 * TICK)
	if posture != PlayerPosture.Kind.STANDING:
		var wanted: ActionResult = _want(world, alice, posture)
		if not wanted.ok:
			fail("test setup: posture refused: " + wanted.reason)
	var zombie_id: String = _spawn_zombie(world, Vector3.ZERO)
	var seen: bool = false
	for tick: int in range(roundi(1.5 / TICK)):
		if walking:
			# Sideways (along X), slowly enough to stay at about this distance.
			_sequence += 1
			world.set_move_input(alice.player_id, _sequence, Vector2(1.0 if tick % 2 == 0 else -1.0, 0.0), 0.0, _now_msec)
		_tick(world)
		if _zombies(world).get_zombie(zombie_id).target_player_id == alice.player_id:
			seen = true
			break
	return seen


# ------------------------------------------------------------ data

func test_shipped_posture_settings_and_validation() -> void:
	var shipped: PostureSettings = PostureSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	# The order the user decided: moving > sleeping > prone.
	assert_eq(shipped.standing_moving_visibility, 1.0, "a moving, standing player is the reference")
	assert_true(shipped.resting_visibility < shipped.standing_moving_visibility, "a sleeper is seen less than a moving player")
	assert_true(shipped.prone_moving_visibility < shipped.resting_visibility, "lying prone hides better than sleeping")
	assert_true(shipped.prone_still_visibility < shipped.prone_moving_visibility)
	assert_true(shipped.standing_still_visibility <= shipped.standing_moving_visibility and shipped.standing_still_visibility > shipped.resting_visibility)
	assert_true(shipped.prone_movement_multiplier > 0.0 and shipped.prone_movement_multiplier < 1.0, "prone is slow")
	assert_true(shipped.prone_footstep_loudness_multiplier < 1.0, "and quiet")
	assert_eq([shipped.standing_moving_visibility, shipped.standing_still_visibility, shipped.resting_visibility, shipped.prone_moving_visibility, shipped.prone_still_visibility], [1.0, 0.8, 0.6, 0.4, 0.2])
	assert_eq(shipped.prone_footstep_loudness_multiplier, 0.5)
	assert_true(shipped.prone_blocks_attack)
	assert_eq(ZombieSettings.load_or_default().tracked_target_min_visibility, 1.0)
	assert_eq(PlayerPosture.NAMES, PackedStringArray(["standing", "prone", "resting"]))
	assert_eq(PlayerPosture.from_name("prone"), int(PlayerPosture.Kind.PRONE))
	assert_eq(PlayerPosture.from_name("crouching"), PlayerPosture.INVALID)
	assert_false(PlayerPosture.is_valid(3))
	assert_false(PlayerPosture.is_valid(-1))
	# Each broken value is exactly one error.
	var broken: Array[Callable] = [
		func(s: PostureSettings) -> void: s.prone_still_visibility = -0.1,
		func(s: PostureSettings) -> void: s.standing_still_visibility = NAN,
		func(s: PostureSettings) -> void: s.resting_visibility = 1.0,
		func(s: PostureSettings) -> void: s.prone_moving_visibility = s.resting_visibility,
		func(s: PostureSettings) -> void: s.prone_still_visibility = s.prone_moving_visibility + 0.05,
		func(s: PostureSettings) -> void: s.moving_memory_sec = -1.0,
		func(s: PostureSettings) -> void: s.prone_movement_multiplier = 1.5,
		func(s: PostureSettings) -> void: s.prone_footstep_loudness_multiplier = -1.0,
		func(s: PostureSettings) -> void: s.prone_footstep_stride_multiplier = 0.0,
		func(s: PostureSettings) -> void: s.max_pending_events = 0,
	]
	for index: int in broken.size():
		var settings: PostureSettings = PostureSettings.new()
		broken[index].call(settings)
		assert_eq(settings.validate().size(), 1, "broken value %d: %s" % [index, "; ".join(settings.validate())])
	var zombie: ZombieSettings = ZombieSettings.new()
	zombie.tracked_target_min_visibility = 1.5
	assert_eq(zombie.validate().size(), 1, "; ".join(zombie.validate()))
	# The table itself.
	var settings: PostureSettings = PostureSettings.new()
	assert_eq(settings.visibility(PlayerPosture.Kind.STANDING, true), settings.standing_moving_visibility)
	assert_eq(settings.visibility(PlayerPosture.Kind.STANDING, false), settings.standing_still_visibility)
	assert_eq(settings.visibility(PlayerPosture.Kind.RESTING, false), settings.resting_visibility)
	assert_eq(settings.visibility(PlayerPosture.Kind.RESTING, true), settings.resting_visibility, "a sleeper does not move")
	assert_eq(settings.visibility(PlayerPosture.Kind.PRONE, true), settings.prone_moving_visibility)
	assert_eq(settings.visibility(PlayerPosture.Kind.PRONE, false), settings.prone_still_visibility)


func test_posture_system_is_composed_and_saves_nothing() -> void:
	var world: ServerWorld = _world()
	var ids: PackedStringArray = world.system_ids()
	assert_true(ids.has(PostureService.SYSTEM_ID))
	assert_true(ids.find(SurvivalService.SYSTEM_ID) < ids.find(PostureService.SYSTEM_ID), "after survival, whose rest it reads")
	assert_true(ids.find(PostureService.SYSTEM_ID) < ids.find(PlayerNoiseService.SYSTEM_ID), "before the footsteps")
	assert_true(ids.find(PostureService.SYSTEM_ID) < ids.find(ZombieService.SYSTEM_ID), "before the zombies")
	var alice: PlayerState = world.join("alice")
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	# Session state: nothing about a posture is written.
	assert_eq(_posture(world).to_world_document(), {})
	assert_eq(_posture(world).to_player_fragment(alice.player_id), {})
	var documents: Dictionary = world.to_documents()
	assert_false((documents["world_state"][ServerWorld.KEY_SYSTEMS] as Dictionary).has(PostureService.SYSTEM_ID))
	assert_false((documents["players"][alice.player_id][ServerWorld.KEY_SYSTEMS] as Dictionary).has(PostureService.SYSTEM_ID))
	assert_not_contains(JSON.stringify(documents), "prone")


# ------------------------------------------------------------ changing posture

func test_going_prone_and_standing_up() -> void:
	var world: ServerWorld = _world()
	var posture: PostureService = _posture(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.STANDING, "everybody starts standing")
	assert_eq(posture.posture_of("player_999999"), PlayerPosture.Kind.STANDING)
	assert_eq(_want(world, alice, PlayerPosture.Kind.STANDING).reason, PostureService.REASON_ALREADY_IN_POSTURE)

	var down: ActionResult = _want(world, alice, PlayerPosture.Kind.PRONE)
	assert_true(down.ok, down.reason)
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.PRONE)
	assert_true(posture.is_prone(alice.player_id))
	assert_false(posture.is_prone(bob.player_id), "a posture is per player")
	assert_eq(down.event.get("event_type", ""), PostureService.EVENT_POSTURE_CHANGED)
	assert_eq(down.event.get("player_id", ""), alice.player_id)
	assert_eq(down.event.get("posture", ""), "prone")
	assert_eq(down.event.get("previous", ""), "standing")
	assert_eq(down.event.get("world_time", -1.0), world.clock.world_time_sec)
	assert_true(SaveService.is_json_safe(down.event))
	assert_eq(_want(world, alice, PlayerPosture.Kind.PRONE).reason, PostureService.REASON_ALREADY_IN_POSTURE)
	assert_true(posture.is_prone(alice.player_id), "a refused request changes nothing")

	var up: ActionResult = _want(world, alice, PlayerPosture.Kind.STANDING)
	assert_true(up.ok, up.reason)
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.STANDING)
	assert_eq(up.event.get("posture", ""), "standing")
	assert_eq(up.event.get("previous", ""), "prone")
	# Both changes are queued for the network layer, in order, once each.
	var postures: Array = []
	for event: Dictionary in posture.drain_events():
		postures.append(str(event.get("posture", "")))
	assert_eq(postures, ["prone", "standing"])

	# Who cannot change posture, and what is no posture.
	assert_eq(posture.request_posture(world, "player_999999", PlayerPosture.Kind.PRONE).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_eq(posture.request_posture(world, alice.player_id, 7).reason, PostureService.REASON_BAD_POSTURE)
	assert_eq(posture.request_posture(world, alice.player_id, -1).reason, PostureService.REASON_BAD_POSTURE)
	assert_eq(posture.request_posture(null, alice.player_id, PlayerPosture.Kind.PRONE).reason, PostureService.REASON_UNAVAILABLE)
	world.leave(bob.player_id)
	assert_eq(_want(world, bob, PlayerPosture.Kind.PRONE).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_true(_survival(world).apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(_want(world, alice, PlayerPosture.Kind.PRONE).reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(posture.drain_events().size(), 0, "refused requests report nothing")


func test_a_player_without_a_character_has_no_posture_to_change() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.dev_seed = DevWorldSeed.new()
	config.zombie = _zombie_settings
	config.posture = _settings
	config.require_character_creation = true
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	var ghost: PlayerState = world.join("ghost")
	assert_false(world.is_online(ghost.player_id), "connected, not in the world")
	assert_eq(_want(world, ghost, PlayerPosture.Kind.PRONE).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_eq(_posture(world).posture_of(ghost.player_id), PlayerPosture.Kind.STANDING)
	assert_eq(_posture(world).drain_events().size(), 0)


func test_prone_and_sleep_are_one_posture_model() -> void:
	var world: ServerWorld = _world()
	var posture: PostureService = _posture(world)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	# Lying down to sleep from prone: the posture is "resting", not prone.
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	assert_true(_want(world, alice, PlayerPosture.Kind.RESTING).ok, "the wanted-posture request can also lie down to sleep")
	assert_true(survival.is_resting(alice.player_id), "it is the rest of the survival rules")
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.RESTING)
	assert_false(posture.is_prone(alice.player_id))
	assert_eq(_want(world, alice, PlayerPosture.Kind.RESTING).reason, SurvivalService.REASON_ALREADY_RESTING)
	# Getting up from sleep: standing, not prone again.
	assert_true(_want(world, alice, PlayerPosture.Kind.STANDING).ok)
	assert_false(survival.is_resting(alice.player_id))
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.STANDING)
	# The rest request of the survival system keeps the model consistent too.
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	assert_true(survival.start_rest(alice.player_id).ok)
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.RESTING)
	# A hit wakes the sleeper: it stands.
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.BRUISE, 5.0)).ok)
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.STANDING)
	# From sleep straight to prone: wakes and lies prone.
	assert_true(survival.start_rest(alice.player_id).ok)
	posture.drain_events()
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	assert_false(survival.is_resting(alice.player_id))
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.PRONE)
	var postures: Array = []
	for event: Dictionary in posture.drain_events():
		postures.append(str(event.get("posture", "")))
	assert_eq(postures, ["standing", "prone"], "woken, then prone")
	# A player in danger cannot lie down to sleep (P2-T10), also through here,
	# and stays as it was.
	survival.get_vitals(alice.player_id).thirst = _survival_settings.need_danger_threshold
	assert_eq(_want(world, alice, PlayerPosture.Kind.RESTING).reason, SurvivalService.REASON_CANNOT_REST_PREFIX + SurvivalService.REST_END_THIRST)
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.PRONE, "a refused request changes nothing")


func test_death_leaving_and_a_new_character_end_prone() -> void:
	_survival_settings.respawn_delay_sec = 1.0
	var world: ServerWorld = _world()
	var posture: PostureService = _posture(world)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	assert_true(_want(world, bob, PlayerPosture.Kind.PRONE).ok)
	posture.drain_events()
	# Death: reported, so every mirror forgets the prone posture.
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.STANDING, "a dead character has no posture")
	var events: Array[Dictionary] = posture.drain_events()
	assert_eq(events.size(), 1)
	assert_eq(events[0].get("player_id", ""), alice.player_id)
	assert_eq(events[0].get("posture", ""), "standing")
	# The next character starts standing.
	world.step_systems(2.0)
	assert_true(survival.is_alive(alice.player_id), "the new character started")
	assert_eq(posture.posture_of(alice.player_id), PlayerPosture.Kind.STANDING)
	assert_true(world.player_movement_multiplier(alice.player_id) >= 1.0)
	# Leaving: silently (the player is gone for everybody); back standing.
	posture.drain_events()
	world.leave(bob.player_id)
	assert_eq(posture.posture_of(bob.player_id), PlayerPosture.Kind.STANDING)
	assert_eq(posture.drain_events().size(), 0)
	world.join("bob")
	assert_eq(posture.posture_of(bob.player_id), PlayerPosture.Kind.STANDING, "a returning player stands")


# ------------------------------------------------------------ what prone changes

func test_a_prone_player_crawls_slowly() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var start: float = alice.position.x
	_walk(world, alice, Vector2(1, 0), 1.0)
	var walked: float = alice.position.x - start
	assert_true(_near(walked, _gameplay.move_speed_mps, 0.01), "standing: full speed (%f)" % walked)
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	assert_true(_near(world.player_movement_multiplier(alice.player_id), _settings.prone_movement_multiplier))
	start = alice.position.x
	_walk(world, alice, Vector2(1, 0), 1.0)
	var crawled: float = alice.position.x - start
	assert_true(_near(crawled, _gameplay.move_speed_mps * _settings.prone_movement_multiplier, 0.01), "prone: %f" % crawled)
	assert_true(crawled > 0.0 and crawled < walked)
	# The prone factor multiplies with the survival penalties (a leg wound).
	assert_true(_survival(world).apply_damage(alice.player_id, DamageInput.create("zombie_000001", BodyPart.Part.LEFT_LEG, Wound.Type.BRUISE, 25.0)).ok)
	var wounded: float = _survival(world).movement_speed_multiplier(alice.player_id)
	assert_true(wounded < 1.0)
	assert_true(_near(world.player_movement_multiplier(alice.player_id), wounded * _settings.prone_movement_multiplier))
	# Up again: only the wound slows.
	assert_true(_want(world, alice, PlayerPosture.Kind.STANDING).ok)
	assert_true(_near(world.player_movement_multiplier(alice.player_id), wounded))


func test_a_prone_player_cannot_attack_but_handles_items() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var combat: CombatService = world.get_system(CombatService.SYSTEM_ID) as CombatService
	var alice: PlayerState = world.join("alice")
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	vitals.hunger = 50.0
	var lying_id: String = world.inventory.spawn_world_item(FOOD, 2, DevWorldSeed.DEV_CELL_ID, alice.position)
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	assert_eq(world.player_attack_block_reason(alice.player_id), PostureService.REASON_PLAYER_PRONE)
	assert_eq(world.player_action_block_reason(alice.player_id), "", "prone blocks attacks, not actions")
	var stamina: float = vitals.stamina
	combat.drain_events()
	var swing: ActionResult = combat.request_melee_attack(world, alice.player_id, AIM_MINUS_Z)
	assert_false(swing.ok)
	assert_eq(swing.reason, PostureService.REASON_PLAYER_PRONE, "no melee attack while prone")
	assert_eq(vitals.stamina, stamina, "a refused swing costs no stamina")
	assert_eq(combat.cooldown_remaining(alice.player_id), 0.0, "and starts no cooldown")
	assert_eq(combat.drain_events().size(), 0, "and is not an event")
	# Items: pick up, use, put down, all while prone.
	assert_true(world.try_pickup(alice.player_id, lying_id).ok, "a prone player picks up")
	assert_true(ItemConsumption.try_consume(world, alice.player_id, lying_id).ok, "eats")
	assert_true(vitals.hunger < 50.0)
	assert_true(world.try_drop_item(alice.player_id, lying_id).ok, "and puts down")
	assert_true(_posture(world).is_prone(alice.player_id), "none of it changes the posture")
	# Up again: attacks work.
	assert_true(_want(world, alice, PlayerPosture.Kind.STANDING).ok)
	assert_eq(world.player_attack_block_reason(alice.player_id), "")
	assert_true(combat.request_melee_attack(world, alice.player_id, AIM_MINUS_Z).ok)
	# A sleeper's attack is refused as resting (every action is blocked).
	assert_true(_want(world, alice, PlayerPosture.Kind.RESTING).ok)
	assert_eq(world.player_attack_block_reason(alice.player_id), SurvivalService.REASON_PLAYER_RESTING)
	# The setting can allow attacks while prone.
	_settings.prone_blocks_attack = false
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	assert_eq(world.player_attack_block_reason(alice.player_id), "")


func test_a_prone_player_makes_quieter_footsteps() -> void:
	_noise_settings.stride_length_m = 1.0
	_noise_settings.footstep_loudness = 10.0
	_noise_settings.min_speed_mps = 0.1
	var world: ServerWorld = _world()
	var noise: NoiseService = _noise(world)
	var player_noise: PlayerNoiseService = world.get_system(PlayerNoiseService.SYSTEM_ID) as PlayerNoiseService
	var alice: PlayerState = world.join("alice")
	_tick(world)
	# Standing: one footstep per stride at the configured loudness.
	_walk(world, alice, Vector2(1, 0), 1.0)
	var standing_steps: int = player_noise.total_footstep_count
	assert_true(absi(standing_steps - roundi(_gameplay.move_speed_mps / _noise_settings.stride_length_m)) <= 1, "standing footsteps: %d" % standing_steps)
	var loudest: float = 0.0
	for perception: NoisePerception in noise.query_audible(alice.position, 1.0, NoiseService.SINCE_ALWAYS):
		loudest = maxf(loudest, perception.event.loudness)
	assert_true(_near(loudest, _noise_settings.footstep_loudness), "standing loudness %f" % loudest)
	# Let the standing footsteps expire, then crawl.
	_stand(world, alice, 10.0)
	assert_eq(noise.active_count(), 0)
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	var from: Vector3 = alice.position
	_walk(world, alice, Vector2(1, 0), 2.0)
	var crawled: float = alice.position.x - from.x
	var prone_steps: int = player_noise.total_footstep_count - standing_steps
	var prone_stride: float = _noise_settings.stride_length_m * _settings.prone_footstep_stride_multiplier
	assert_true(absi(prone_steps - floori(crawled / prone_stride)) <= 1, "prone footsteps: %d over %f m" % [prone_steps, crawled])
	assert_true(prone_steps >= 1)
	var heard: Array[NoisePerception] = noise.query_audible(alice.position, 1.0, NoiseService.SINCE_ALWAYS)
	assert_true(heard.size() >= 1, "the crawl is heard next to the player")
	for perception: NoisePerception in heard:
		assert_true(_near(perception.event.loudness, _noise_settings.footstep_loudness * _settings.prone_footstep_loudness_multiplier), "prone loudness %f" % perception.event.loudness)
	# A crawling player is heard from less far away.
	var standing_reach: float = noise.max_audible_distance(_noise_settings.footstep_loudness, 1.0)
	var prone_reach: float = noise.max_audible_distance(_noise_settings.footstep_loudness * _settings.prone_footstep_loudness_multiplier, 1.0)
	assert_true(prone_reach < standing_reach, "%f vs %f" % [prone_reach, standing_reach])


func test_moving_is_what_the_server_moved_the_player() -> void:
	var world: ServerWorld = _world()
	var posture: PostureService = _posture(world)
	var alice: PlayerState = world.join("alice")
	_tick(world)
	assert_false(posture.is_moving(alice.player_id), "a player that has not moved is still")
	assert_true(_near(posture.visibility_multiplier(alice.player_id), _settings.standing_still_visibility))
	_walk(world, alice, Vector2(1, 0), 0.3)
	assert_true(posture.is_moving(alice.player_id))
	assert_true(_near(posture.visibility_multiplier(alice.player_id), _settings.standing_moving_visibility))
	assert_true(_near(world.player_visibility_multiplier(alice.player_id), _settings.standing_moving_visibility), "the world hook reports it")
	# Stopping: still "moving" for the memory time, then still.
	_stand(world, alice, _settings.moving_memory_sec * 0.5)
	assert_true(posture.is_moving(alice.player_id), "a brief stop is not hiding")
	_stand(world, alice, _settings.moving_memory_sec)
	assert_false(posture.is_moving(alice.player_id))
	# A move intent that moves nothing (a sleeper's) is not movement.
	assert_true(_want(world, alice, PlayerPosture.Kind.RESTING).ok)
	_walk(world, alice, Vector2(1, 0), 0.5)
	assert_false(posture.is_moving(alice.player_id), "what counts is the server position, not the request")
	assert_true(_near(posture.visibility_multiplier(alice.player_id), _settings.resting_visibility))
	# Prone: still and crawling.
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	_stand(world, alice, _settings.moving_memory_sec + 2.0 * TICK)
	assert_true(_near(posture.visibility_multiplier(alice.player_id), _settings.prone_still_visibility))
	_walk(world, alice, Vector2(1, 0), 0.3)
	assert_true(posture.is_moving(alice.player_id))
	assert_true(_near(posture.visibility_multiplier(alice.player_id), _settings.prone_moving_visibility))
	# Unknown and offline players are not hidden by this system.
	assert_eq(posture.visibility_multiplier("player_999999"), 1.0)
	world.leave(alice.player_id)
	assert_false(posture.is_moving(alice.player_id))


# ------------------------------------------------------------ zombie sight

func test_at_the_same_distance_a_standing_player_is_seen_and_a_prone_one_is_not() -> void:
	# Between the prone and the standing sight distance.
	var distance: float = SIGHT_RANGE * (_settings.prone_still_visibility + _settings.standing_still_visibility) * 0.5
	assert_true(_zombie_sees(PlayerPosture.Kind.STANDING, distance), "standing still at %f m: seen" % distance)
	assert_false(_zombie_sees(PlayerPosture.Kind.PRONE, distance), "prone at %f m: not seen" % distance)
	# Close enough, a prone player is seen too: hard to see, not invisible.
	assert_true(_zombie_sees(PlayerPosture.Kind.PRONE, SIGHT_RANGE * _settings.prone_still_visibility - 1.0))


func test_sight_distance_follows_the_visibility_order() -> void:
	const MARGIN: float = 0.5
	var cases: Array[Array] = [
		# [posture, walking, visibility factor]
		[PlayerPosture.Kind.STANDING, true, _settings.standing_moving_visibility],
		[PlayerPosture.Kind.STANDING, false, _settings.standing_still_visibility],
		[PlayerPosture.Kind.RESTING, false, _settings.resting_visibility],
		[PlayerPosture.Kind.PRONE, false, _settings.prone_still_visibility],
	]
	for case: Array in cases:
		var reach: float = SIGHT_RANGE * float(case[2])
		var label: String = "%s%s (x%.2f)" % [PlayerPosture.name_of(case[0]), " moving" if bool(case[1]) else "", float(case[2])]
		assert_true(_zombie_sees(case[0], reach - MARGIN, case[1]), "%s is seen just inside %f m" % [label, reach])
		assert_false(_zombie_sees(case[0], reach + MARGIN, case[1]), "%s is not seen just outside %f m" % [label, reach])
	# A sleeper is seen less well than a moving player, better than a prone one.
	var between_sleep_and_moving: float = SIGHT_RANGE * (_settings.resting_visibility + _settings.standing_moving_visibility) * 0.5
	assert_true(_zombie_sees(PlayerPosture.Kind.STANDING, between_sleep_and_moving, true))
	assert_false(_zombie_sees(PlayerPosture.Kind.RESTING, between_sleep_and_moving))
	var between_prone_and_sleep: float = SIGHT_RANGE * (_settings.prone_still_visibility + _settings.resting_visibility) * 0.5
	assert_true(_zombie_sees(PlayerPosture.Kind.RESTING, between_prone_and_sleep), "sleeping is no stealth")
	assert_false(_zombie_sees(PlayerPosture.Kind.PRONE, between_prone_and_sleep))


func test_going_prone_in_front_of_a_chasing_zombie_does_not_end_the_chase() -> void:
	for tracked_floor: float in [1.0, 0.0]:
		_zombie_settings.tracked_target_min_visibility = tracked_floor
		# Slow zombies: the distance stays about the same during the test.
		_zombie_settings.chase_speed_mps = 0.1
		var world: ServerWorld = _world()
		var alice: PlayerState = world.join("alice")
		var distance: float = SIGHT_RANGE * (_settings.prone_still_visibility + _settings.standing_still_visibility) * 0.5
		alice.position = Vector3(0.0, 0.0, -distance)
		_stand(world, alice, _settings.moving_memory_sec + 4.0 * TICK)
		var zombie_id: String = _spawn_zombie(world, Vector3.ZERO)
		_stand(world, alice, 1.5)
		assert_eq(_zombie_state(world, zombie_id), "chase", "the zombie saw the standing player")
		assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
		_stand(world, alice, 2.0)
		var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
		assert_eq(_zombie_state(world, zombie_id), "chase", "visibility does not end a pursuit inside 30 m")
		assert_eq(zombie.target_player_id, alice.player_id)
		assert_eq(zombie.target_visible, tracked_floor >= 1.0, "the floor still controls whether the pursued target is currently seen")


func test_a_lost_target_that_lies_prone_is_not_found_again() -> void:
	# The chase ends beyond the pursuit distance; after that the prone
	# factor counts. The zombie stands and keeps facing where it lost her.
	_zombie_settings.chase_speed_mps = 0.1
	_zombie_settings.search_speed_mps = 0.0
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var distance: float = SIGHT_RANGE * (_settings.prone_still_visibility + _settings.standing_still_visibility) * 0.5
	alice.position = Vector3(0.0, 0.0, -distance)
	_stand(world, alice, _settings.moving_memory_sec + 4.0 * TICK)
	var zombie_id: String = _spawn_zombie(world, Vector3.ZERO)
	_stand(world, alice, 1.5)
	assert_eq(_zombie_state(world, zombie_id), "chase")
	# Far beyond the 30 m pursuit distance: the chase ends.
	alice.position = Vector3(0.0, 0.0, -SIGHT_RANGE * 5.0)
	assert_true(_want(world, alice, PlayerPosture.Kind.PRONE).ok)
	_stand(world, alice, 1.5)
	assert_eq(_zombie_state(world, zombie_id), "search", "beyond the pursuit distance the target is lost")
	# Back at the old distance, prone: not seen again.
	alice.position = Vector3(0.0, 0.0, -distance)
	_stand(world, alice, 2.0)
	assert_eq(_zombie_state(world, zombie_id), "search")
	assert_ne(_zombies(world).get_zombie(zombie_id).target_player_id, alice.player_id, "prone at %f m: stays hidden" % distance)
	# Standing up at the same place: seen.
	assert_true(_want(world, alice, PlayerPosture.Kind.STANDING).ok)
	_stand(world, alice, 1.5)
	assert_eq(_zombies(world).get_zombie(zombie_id).target_player_id, alice.player_id, "standing: seen again")


# ------------------------------------------------------------ world hooks

func test_world_factors_are_products_and_ignore_invalid_values() -> void:
	var world: ServerWorld = ServerWorld.new(WORLD, GameplaySettings.new(), ItemCatalog.new())
	var hidden: _FactorSystem = _FactorSystem.new("hidden", 0.5)
	var also: _FactorSystem = _FactorSystem.new("also", 0.5)
	assert_eq(world.register_system(hidden), OK)
	assert_eq(world.register_system(also), OK)
	assert_true(_near(world.player_visibility_multiplier("p"), 0.25), "factors multiply")
	assert_true(_near(world.player_footstep_loudness_multiplier("p"), 0.25))
	assert_true(_near(world.player_footstep_stride_multiplier("p"), 0.25))
	also.factor = 4.0
	assert_eq(world.player_visibility_multiplier("p"), 1.0, "visibility is clamped: a system can only hide")
	assert_true(_near(world.player_footstep_loudness_multiplier("p"), 2.0), "footstep factors are not clamped to 1")
	for bad: float in [NAN, INF, -1.0]:
		also.factor = bad
		assert_true(_near(world.player_visibility_multiplier("p"), 0.5), "an invalid factor is ignored: %s" % str(bad))
		assert_true(_near(world.player_footstep_loudness_multiplier("p"), 0.5))
		assert_true(_near(world.player_footstep_stride_multiplier("p"), 0.5))
	# Attack blocks: whatever blocks every action first, then attacks only.
	also.factor = 1.0
	assert_eq(world.player_attack_block_reason("p"), "")
	also.attack_block = "no_attack"
	assert_eq(world.player_attack_block_reason("p"), "no_attack")
	assert_eq(world.player_action_block_reason("p"), "", "an attack block is no action block")
	also.action_block = "no_action"
	assert_eq(world.player_attack_block_reason("p"), "no_action")
	assert_eq(ServerWorld.new(WORLD, GameplaySettings.new(), ItemCatalog.new()).player_visibility_multiplier("p"), 1.0, "no systems: fully visible")


## Test double: the same factor for every hook.
class _FactorSystem extends ServerSystem:
	var id: String = ""
	var factor: float = 1.0
	var attack_block: String = ""
	var action_block: String = ""

	func _init(system_id: String, value: float) -> void:
		id = system_id
		factor = value

	func get_system_id() -> String:
		return id

	func player_visibility_multiplier(_player_id: String) -> float:
		return factor

	func player_footstep_loudness_multiplier(_player_id: String) -> float:
		return factor

	func player_footstep_stride_multiplier(_player_id: String) -> float:
		return factor

	func player_attack_block_reason(_player_id: String) -> String:
		return attack_block

	func player_action_block_reason(_player_id: String) -> String:
		return action_block
