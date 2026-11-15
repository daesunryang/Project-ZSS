extends TestCase
## P2-0: ServerSystem registration, hooks, clock stepping, persistence of
## system documents / player fragments and v1 -> v2 save migration.

const WORLD: String = "seam_test_world"

var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/seam_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _new_world() -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	return ServerComposition.create_world(WORLD, config)


func test_registration_validation() -> void:
	var world: ServerWorld = _new_world()
	assert_eq(world.register_system(TestCounterSystem.new()), OK)
	assert_eq(world.register_system(TestCounterSystem.new()), ERR_ALREADY_EXISTS)
	assert_eq(world.register_system(ServerSystem.new()), ERR_INVALID_PARAMETER, "base class has no id")
	assert_eq(world.system_ids(), PackedStringArray([SurvivalService.SYSTEM_ID, NoiseService.SYSTEM_ID, ZombieService.SYSTEM_ID, CombatService.SYSTEM_ID, TestCounterSystem.SYSTEM_ID]), "composition systems first, then registration order")
	assert_not_null(world.get_system(TestCounterSystem.SYSTEM_ID))
	assert_null(world.get_system("missing"))


func test_hooks_and_clock_stepping() -> void:
	var world: ServerWorld = _new_world()
	var system: TestCounterSystem = TestCounterSystem.new()
	world.register_system(system)
	assert_eq(world.seed_new_world(DevWorldSeed.new()), OK)
	assert_eq(system.seeded, 1)
	assert_eq(world.step_systems(1.0), 0.0, "clock paused while nobody is online")
	var alice: PlayerState = world.join("alice")
	var world_delta: float = world.step_systems(0.5)
	assert_eq(world_delta, 0.5 * world.clock.time_scale)
	assert_eq(system.steps, 2, "systems step even while paused")
	assert_eq(system.world_time_seen, world_delta)
	world.leave(alice.player_id)
	assert_eq(system.online_events, PackedStringArray(["online:" + alice.player_id, "offline:" + alice.player_id]))


func test_system_state_survives_save_and_restart() -> void:
	var save: SaveService = SaveService.new(_root)
	var world: ServerWorld = _new_world()
	var system: TestCounterSystem = TestCounterSystem.new()
	world.register_system(system)
	world.seed_new_world(DevWorldSeed.new())
	var alice: PlayerState = world.join("alice")
	world.step_systems(2.0)
	system.total = 42
	var documents: Dictionary = world.to_documents()
	assert_eq(save.save_world(WORLD, documents["world_state"], documents["players"]), OK)

	var loaded: Dictionary = SaveService.new(_root).load_world(WORLD)
	assert_eq(loaded["error"], OK)
	var restored_world: ServerWorld = _new_world()
	var restored: TestCounterSystem = TestCounterSystem.new()
	restored_world.register_system(restored)
	assert_eq(restored_world.restore_documents(loaded["world_state"], loaded["players"]).size(), 0)
	assert_eq(restored.total, 42, "world document restored")
	assert_eq(restored.per_player.get(alice.player_id, 0), 1, "player fragment restored")
	assert_eq(restored_world.clock.world_time_sec, world.clock.world_time_sec, "world time restored")
	assert_true(restored_world.clock.world_time_sec > 0.0)


func test_missing_and_unknown_system_documents() -> void:
	var world: ServerWorld = _new_world()
	world.seed_new_world(DevWorldSeed.new())
	var documents: Dictionary = world.to_documents()
	var state: Dictionary = documents["world_state"]
	(state[ServerWorld.KEY_SYSTEMS] as Dictionary)["removed_system"] = {"schema_version": 1}
	var restored_world: ServerWorld = _new_world()
	var restored: TestCounterSystem = TestCounterSystem.new()
	restored.total = 7
	restored_world.register_system(restored)
	assert_eq(restored_world.restore_documents(state, documents["players"]).size(), 0, "unknown system data is ignored")
	assert_eq(restored.total, 7, "system without saved data keeps its defaults")


func test_corrupt_system_document_fails_restore() -> void:
	var world: ServerWorld = _new_world()
	world.register_system(TestCounterSystem.new())
	var documents: Dictionary = world.to_documents()
	var state: Dictionary = documents["world_state"]
	(state[ServerWorld.KEY_SYSTEMS] as Dictionary)[TestCounterSystem.SYSTEM_ID] = {"schema_version": 99}
	var restored_world: ServerWorld = _new_world()
	restored_world.register_system(TestCounterSystem.new())
	assert_true(restored_world.restore_documents(state, documents["players"]).size() > 0)


func test_phase1_v1_save_is_migrated() -> void:
	# A Phase 1 save: schema 1 documents without world_time_sec / systems.
	var world: ServerWorld = _new_world()
	world.seed_new_world(DevWorldSeed.load_or_default())
	var alice: PlayerState = world.join("alice")
	alice.position = Vector3(2, 0, 3)
	var documents: Dictionary = world.to_documents()
	var state: Dictionary = documents["world_state"]
	state["schema_version"] = 1
	state.erase(ServerWorld.KEY_WORLD_TIME)
	state.erase(ServerWorld.KEY_SYSTEMS)
	var players: Dictionary = documents["players"]
	var player_doc: Dictionary = players[alice.player_id]
	player_doc["schema_version"] = 1
	player_doc.erase(ServerWorld.KEY_SYSTEMS)
	assert_eq(SaveService.new(_root).save_world(WORLD, state, players), OK)

	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), CompositionConfig.from_defaults())
	var restored: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(restored, "v1 save loads through migration")
	if restored == null:
		return
	assert_eq(restored.clock.world_time_sec, 0.0)
	assert_eq(restored.get_player(alice.player_id).position, Vector3(2, 0, 3))
	assert_eq(restored.inventory.world_item_ids().size(), 1)
	var migrated: Dictionary = SaveMigrations.world_v1_to_v2({"schema_version": 1})
	assert_eq(int(migrated["schema_version"]), 2)
	assert_eq(migrated["systems"], {})
