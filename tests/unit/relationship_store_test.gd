extends TestCase
## P4-6: directional relationship records owned by each NPC. Scores do not
## infer or advance status; Phase 5 owns those rules.

const WORLD: String = "relationship_store_world"
const FIRST_DEFINITION: String = "t46_first"
const SECOND_DEFINITION: String = "t46_second"
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const BESIDE: Vector3 = Vector3(6.5, 0.0, 5.5)
const FAR: Vector3 = Vector3(45.5, 0.0, 45.5)
const TICK: float = 0.1

var _cell_settings: WorldCellSettings = null


func before_each() -> void:
	_cell_settings = WorldCellSettings.new()
	_cell_settings.cell_size_m = 10.0
	_cell_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_cell_settings.bounds_max_m = Vector2(50.0, 50.0)
	_cell_settings.active_radius_cells = 0
	_cell_settings.preload_radius_cells = 1
	_cell_settings.preload_lookahead_sec = 0.0
	_cell_settings.deactivate_delay_sec = 0.0
	_cell_settings.unload_delay_sec = 0.5
	_cell_settings.refresh_period_sec = 0.0
	_cell_settings.max_preload_loads_per_refresh = 1000


func _definition(definition_id: String) -> NpcDefinition:
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = definition_id
	definition.display_name = definition_id
	return definition


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = 1.0e9
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = _cell_settings
	config.npc = NpcSettings.new()
	config.npc_definitions = NpcCatalog.new()
	config.npc_definitions.add(_definition(FIRST_DEFINITION))
	config.npc_definitions.add(_definition(SECOND_DEFINITION))
	config.npc_mind = NpcMindSettings.new()
	return config


func _world(store: WorldCellStore = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	return world


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _spawn(world: ServerWorld, definition_id: String, position: Vector3) -> String:
	var result: ActionResult = _npcs(world).spawn_npc(world, definition_id, position)
	assert_true(result.ok, result.reason)
	return str(result.event.get(NpcService.KEY_NPC_ID, ""))


func _store(world: ServerWorld, npc_id: String) -> RelationshipStore:
	return _npcs(world).get_npc(npc_id).component(RelationshipStore.COMPONENT_ID) as RelationshipStore


func _relationship(source_id: String, target_id: String, trust: float, liking: float, status: String) -> RelationshipState:
	var state: RelationshipState = RelationshipState.new()
	state.source_entity_id = source_id
	state.target_entity_id = target_id
	state.trust = trust
	state.liking = liking
	state.respect = 0.4
	state.fear = 0.1
	state.resentment = 0.2
	state.attraction = 0.3
	state.jealousy = 0.05
	state.dependence = 0.25
	state.status = status
	state.last_interaction_time = 12.0
	return state


func test_relationship_state_validates_and_round_trips_all_contract_fields() -> void:
	var state: RelationshipState = _relationship("npc_000001", "player_000002", 0.7, 0.8, "friend")
	assert_eq(state.validate().size(), 0)
	var restored: RelationshipState = RelationshipState.from_document(JSON.parse_string(JSON.stringify(state.to_document())) as Dictionary)
	assert_not_null(restored)
	if restored != null:
		assert_eq(restored.to_document(), state.to_document())
	state.target_entity_id = state.source_entity_id
	assert_contains("; ".join(state.validate()), "target")
	state.target_entity_id = "zombie_000001"
	assert_contains("; ".join(state.validate()), "target")
	state.target_entity_id = "player_000002"
	state.trust = 1.1
	assert_contains("; ".join(state.validate()), "trust")
	assert_null(RelationshipState.from_document({"source_entity_id": "npc_000001"}))


func test_a_to_b_and_b_to_a_are_separate_and_status_is_not_derived() -> void:
	var world: ServerWorld = _world()
	world.join("alice")
	_run(world, TICK)
	var first_id: String = _spawn(world, FIRST_DEFINITION, SPAWN)
	var second_id: String = _spawn(world, SECOND_DEFINITION, BESIDE)
	var first_store: RelationshipStore = _store(world, first_id)
	var second_store: RelationshipStore = _store(world, second_id)
	assert_true(first_store.put_relationship(_relationship(first_id, second_id, 0.9, 0.8, "stranger")).ok)
	assert_true(second_store.put_relationship(_relationship(second_id, first_id, 0.2, 0.3, "friend")).ok)
	assert_eq(first_store.relationship(second_id).trust, 0.9)
	assert_eq(second_store.relationship(first_id).trust, 0.2)
	assert_eq(first_store.relationship(second_id).status, "stranger", "high scores never advance status automatically")
	assert_eq(second_store.relationship(first_id).status, "friend")
	var changed_scores: RelationshipState = _relationship(first_id, second_id, 1.0, 1.0, "stranger")
	assert_true(first_store.put_relationship(changed_scores).ok)
	assert_eq(first_store.relationship(second_id).status, "stranger")
	assert_eq(first_store.relationship_ids(), PackedStringArray([second_id]))
	assert_eq(first_store.put_relationship(_relationship(second_id, first_id, 0.5, 0.5, "stranger")).reason, RelationshipStore.REASON_WRONG_SOURCE)


func test_npc_and_player_targets_survive_cell_release_with_the_owner() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var alice: PlayerState = world.join("alice")
	_run(world, TICK)
	var first_id: String = _spawn(world, FIRST_DEFINITION, SPAWN)
	var second_id: String = _spawn(world, SECOND_DEFINITION, BESIDE)
	var store: RelationshipStore = _store(world, first_id)
	assert_true(store.put_relationship(_relationship(first_id, second_id, 0.6, 0.7, "acquaintance")).ok)
	assert_true(store.put_relationship(_relationship(first_id, alice.player_id, 0.4, 0.5, "stranger")).ok)
	var before: Dictionary = store.to_document().duplicate(true)
	alice.position = FAR
	_run(world, 1.0)
	assert_false(_npcs(world).has_npc(first_id))
	alice.position = SPAWN
	_run(world, TICK)
	var restored: RelationshipStore = _store(world, first_id)
	assert_eq(restored.to_document(), before)
	assert_eq(restored.relationship(second_id).source_entity_id, first_id)
	assert_eq(restored.relationship(alice.player_id).target_entity_id, alice.player_id)
