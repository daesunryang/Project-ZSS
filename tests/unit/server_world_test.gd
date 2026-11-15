extends TestCase
## ServerWorld join/leave/documents, WorldPersistence, IntentValidator, RateLimiter.

const WORLD: String = "server_world_test"

var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/sw_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	return config


func _world() -> ServerWorld:
	return ServerWorld.new(WORLD, GameplaySettings.new(), ItemCatalog.load_directory())


func test_join_creates_then_reuses_player_by_key() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	assert_not_null(alice)
	assert_true(PlayerState.is_valid_player_id(alice.player_id))
	assert_true(world.inventory.has_inventory(alice.inventory_id))
	assert_null(world.join("alice"), "same key cannot be online twice")
	world.leave(alice.player_id)
	assert_false(world.is_online(alice.player_id))
	var again: PlayerState = world.join("alice")
	assert_eq(again.player_id, alice.player_id)
	assert_eq(world.known_player_count(), 1)


func test_spawn_is_clamped_into_world() -> void:
	var gameplay: GameplaySettings = GameplaySettings.new()
	gameplay.world_half_extent_m = 10.0
	var world: ServerWorld = ServerWorld.new(WORLD, gameplay, ItemCatalog.load_directory())
	assert_eq(world.clamp_to_world(Vector3(50, 1, -50)), Vector3(10, 1, -10))


func test_persistence_round_trip_restores_players_and_items() -> void:
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), _config())
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	var alice: PlayerState = world.join("alice")
	alice.position = Vector3(3, 0, 4)
	assert_eq(persistence.save(world), OK)
	var before: String = JSON.stringify(world.to_documents(), "", true)

	var reloaded: ServerWorld = WorldPersistence.new(SaveService.new(_root), _config()).load_or_create(WORLD)
	assert_not_null(reloaded)
	assert_eq(reloaded.known_player_count(), 1)
	assert_eq(reloaded.get_player(alice.player_id).position, Vector3(3, 0, 4))
	assert_eq(reloaded.inventory.world_item_ids().size(), 1, "seed is not applied again to an existing save")
	var back: PlayerState = reloaded.join("alice")
	assert_eq(back.player_id, alice.player_id)
	reloaded.leave(back.player_id)
	assert_eq(JSON.stringify(reloaded.to_documents(), "", true), before)
	assert_ne(reloaded.ids.next_id("item"), alice.player_id)


func test_unloadable_save_is_not_replaced() -> void:
	var save: SaveService = SaveService.new(_root)
	var persistence: WorldPersistence = WorldPersistence.new(save, _config())
	assert_not_null(persistence.load_or_create(WORLD))
	var bad_state: Dictionary = {"schema_version": 1, "world_id": "other_world"}
	assert_eq(save.save_world(WORLD, bad_state, {}), OK)
	assert_null(persistence.load_or_create(WORLD))
	assert_eq(save.current_generation(WORLD), 2, "failed load must not overwrite the save")


func test_join_validation() -> void:
	var proto: int = BuildInfo.PROTOCOL_VERSION
	assert_eq(IntentValidator.validate_join(proto, "0.0.1", "alice_01", proto, 64), "")
	assert_eq(IntentValidator.validate_join(proto + 1, "0.0.1", "alice", proto, 64), IntentValidator.REASON_PROTOCOL_MISMATCH)
	assert_eq(IntentValidator.validate_join(1.0, "0.0.1", "alice", proto, 64), IntentValidator.REASON_BAD_TYPE)
	assert_eq(IntentValidator.validate_join(proto, "0.0.1", "", proto, 64), IntentValidator.REASON_BAD_PLAYER_KEY)
	assert_eq(IntentValidator.validate_join(proto, "0.0.1", "a/../b", proto, 64), IntentValidator.REASON_BAD_PLAYER_KEY)
	assert_eq(IntentValidator.validate_join(proto, "0.0.1", "x".repeat(65), proto, 64), IntentValidator.REASON_BAD_PLAYER_KEY)
	assert_eq(IntentValidator.validate_join(proto, "v".repeat(100), "alice", proto, 64), IntentValidator.REASON_BAD_TYPE)


func test_rate_limiter_token_bucket() -> void:
	var limiter: RateLimiter = RateLimiter.new(2.0, 2)
	assert_true(limiter.allow(7, 0))
	assert_true(limiter.allow(7, 0))
	assert_false(limiter.allow(7, 0), "burst exhausted")
	assert_true(limiter.allow(8, 0), "keys are independent")
	assert_false(limiter.allow(7, 400))
	assert_true(limiter.allow(7, 600), "refilled after 0.5 s at 2/s")
	limiter.forget(7)
	assert_true(limiter.allow(7, 600))
