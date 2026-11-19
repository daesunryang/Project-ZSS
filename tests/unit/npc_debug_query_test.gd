extends TestCase
## P4-8: the server-only NPC debug query reads one in-memory NPC without
## changing it and produces a stable multi-line dump for headless logs.

const WORLD: String = "npc_debug_query_world"
const DEFINITION_ID: String = "npc_debug_subject"
const SPAWN: Vector3 = Vector3(5.0, 0.0, 5.0)
const TICK: float = 0.05


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 10.0
	config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	config.world_cells.active_radius_cells = 1
	config.world_cells.preload_radius_cells = 1
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.max_preload_loads_per_refresh = 1000
	config.npc = NpcSettings.new()
	config.npc_definitions = NpcCatalog.new()
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = DEFINITION_ID
	definition.display_name = "디버그 대상"
	definition.appearance = config.appearance.default_selection()
	config.npc_definitions.add(definition)
	config.npc_debug = NpcDebugSettings.new()
	return config


func _start() -> Dictionary:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_not_null(world)
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	world.join("debugger")
	world.step_systems(TICK)
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService
	var spawned: ActionResult = npcs.spawn_npc(world, DEFINITION_ID, SPAWN + Vector3(1.0, 0.0, 0.0))
	assert_true(spawned.ok, "test setup: NPC spawned")
	var npc_id: String = str(spawned.event.get(NpcService.KEY_NPC_ID, ""))
	return {"world": world, "npcs": npcs, "npc_id": npc_id, "query": NpcDebugQuery.from_world(world)}


func test_query_collects_private_components_path_schedule_seed_and_recent_reason() -> void:
	var started: Dictionary = _start()
	var world: ServerWorld = started.world
	var npcs: NpcService = started.npcs
	var npc_id: String = started.npc_id
	var query: NpcDebugQuery = started.query
	assert_not_null(query)
	var npc: NpcState = npcs.get_npc(npc_id)

	var decision: NpcDecisionComponent = npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent
	decision.last_failure = {NpcDecisionComponent.KEY_ACTION_ID: "eat", NpcDecisionComponent.KEY_CODE: "no_resource", NpcDecisionComponent.KEY_AT: 120000}
	decision.push_record({
		NpcUtilityDecider.KEY_SEQUENCE: 7,
		NpcUtilityDecider.KEY_AT_USEC: 120000,
		NpcUtilityDecider.KEY_CANDIDATES: [
			{"action_id": "eat", "score": 0.9, "values": {"hunger": 0.8}, "terms": {"hunger": 0.8}},
			{"action_id": "rest", "score": 0.4, "values": {"fatigue": 0.3}, "terms": {"fatigue": 0.3}},
		],
		NpcUtilityDecider.KEY_OUTCOME: NpcUtilityDecider.OUTCOME_FAILED,
	}, 8)
	var emotions: NpcEmotions = npc.component(NpcEmotions.COMPONENT_ID) as NpcEmotions
	assert_true(emotions.apply_emotion("fear", 0.75, world.clock.world_time_sec).ok)
	var relationships: RelationshipStore = npc.component(RelationshipStore.COMPONENT_ID) as RelationshipStore
	var relation: RelationshipState = RelationshipState.new()
	relation.source_entity_id = npc_id
	relation.target_entity_id = "player_1"
	relation.trust = 0.25
	relation.fear = 0.5
	relation.status = "wary"
	assert_true(relationships.put_relationship(relation).ok)
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	assert_true(memories.record_memory("event_900", "saw_zombie", [{"entity_id": npc_id, "role": "witness"}], npc.position, world.clock.world_time_sec, "direct", 0.8, 0.7, PackedStringArray(["danger"])).ok)

	var before: Dictionary = npc.to_dict()
	var result: Dictionary = query.inspect_npc(npc_id)
	assert_true(result.get("found", false))
	assert_eq(result.get("npc_id", ""), npc_id)
	assert_eq(result.get("name", ""), "디버그 대상")
	assert_eq((result.get("candidates", []) as Array).size(), 2)
	assert_true(is_equal_approx(float((result.get("emotions", {}) as Dictionary).get("fear", 0.0)), 0.75))
	assert_eq((result.get("relationships", []) as Array).size(), 1)
	assert_eq((result.get("memories", []) as Array).size(), 1)
	assert_true((result.get("needs", {}) as Dictionary).has(NpcNeedKind.HUNGER))
	assert_true(result.has("action"))
	assert_true(result.has("path"))
	assert_true(result.has("destination"))
	assert_true(result.has("lod"))
	assert_true(result.has("schedule"))
	assert_true(result.has("seed"))
	assert_eq((result.get("failure", {}) as Dictionary).get("code", ""), "no_resource")
	assert_eq(npc.to_dict(), before, "debug query is read-only")
	assert_eq(query.inspect_count, 1)


func test_missing_npc_and_headless_dump_are_explicit_and_human_readable() -> void:
	var started: Dictionary = _start()
	var query: NpcDebugQuery = started.query
	var missing: Dictionary = query.inspect_npc("npc_999999")
	assert_false(missing.get("found", true))
	assert_eq(missing.get("npc_id", ""), "npc_999999")
	var dump: String = query.dump_npc(started.npc_id)
	assert_contains(dump, "NPC 디버그: 디버그 대상")
	assert_contains(dump, "상태:")
	assert_contains(dump, "욕구:")
	assert_contains(dump, "감정:")
	assert_contains(dump, "관계:")
	assert_contains(dump, "기억:")
	assert_contains(dump, "스케줄:")
	assert_contains(dump, "seed:")
	assert_true(dump.count("\n") >= 5, "dump is multiple lines")
