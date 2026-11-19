extends TestCase
## Save-precision audit for every NPC component currently assembled. The
## documents come from a live NPC after its systems and mind data have run.

const WORLD: String = "npc_save_roundtrip_world"
const DEFINITION_ID: String = "precision_audit_survivor"
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const TICK: float = 0.1


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


func _definition() -> NpcDefinition:
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = DEFINITION_ID
	definition.display_name = "저장 정밀도 점검 주민"
	return definition


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = 1.0
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 10.0
	config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	config.world_cells.active_radius_cells = 0
	config.world_cells.preload_radius_cells = 1
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.preload_lookahead_sec = 0.0
	config.npc = NpcSettings.new()
	config.npc_definitions = NpcCatalog.new()
	config.npc_definitions.add(_definition())
	config.npc_needs = NpcNeedSettings.new()
	config.npc_mind = NpcMindSettings.new()
	return config


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _live_components(world: ServerWorld, npc_id: String) -> Dictionary:
	return (_npcs(world).npc_document(npc_id)[NpcState.KEY_COMPONENTS] as Dictionary).duplicate(true)


func _full_precision_json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value, "", false, true)) as Dictionary


## Empty means equal. Floats are compared through their Variant bytes so the
## assertion catches a last-bit change while allowing JSON's exact int->float
## representation for whole numbers.
func _first_bit_difference(expected: Variant, actual: Variant, path: String) -> String:
	var expected_type: int = typeof(expected)
	var actual_type: int = typeof(actual)
	if expected_type != actual_type:
		if (expected_type == TYPE_INT or expected_type == TYPE_FLOAT) and (actual_type == TYPE_INT or actual_type == TYPE_FLOAT) and float(expected) == float(actual):
			return ""
		return "%s changed type %d -> %d" % [path, expected_type, actual_type]
	if expected_type == TYPE_FLOAT:
		return "" if var_to_bytes(expected) == var_to_bytes(actual) else "%s changed float bits (%s -> %s)" % [path, str(expected), str(actual)]
	if expected_type == TYPE_DICTIONARY:
		var expected_dictionary: Dictionary = expected as Dictionary
		var actual_dictionary: Dictionary = actual as Dictionary
		if expected_dictionary.size() != actual_dictionary.size():
			return "%s changed object size" % path
		for key: Variant in expected_dictionary:
			if not actual_dictionary.has(key):
				return "%s lost key %s" % [path, str(key)]
			var difference: String = _first_bit_difference(expected_dictionary[key], actual_dictionary[key], "%s.%s" % [path, str(key)])
			if not difference.is_empty():
				return difference
		return ""
	if expected_type == TYPE_ARRAY:
		var expected_array: Array = expected as Array
		var actual_array: Array = actual as Array
		if expected_array.size() != actual_array.size():
			return "%s changed array size" % path
		for index: int in range(expected_array.size()):
			var difference: String = _first_bit_difference(expected_array[index], actual_array[index], "%s[%d]" % [path, index])
			if not difference.is_empty():
				return difference
		return ""
	return "" if expected == actual else "%s changed value (%s -> %s)" % [path, str(expected), str(actual)]


func test_live_npc_component_documents_keep_float_bits_through_json() -> void:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	world.join("alice")
	world.step_systems(TICK)
	var spawned: ActionResult = _npcs(world).spawn_npc(world, DEFINITION_ID, SPAWN)
	assert_true(spawned.ok, spawned.reason)
	var npc_id: String = str(spawned.event.get(NpcService.KEY_NPC_ID, ""))
	world.step_systems(TICK)
	var npc: NpcState = _npcs(world).get_npc(npc_id)

	var needs: NpcNeeds = npc.component(NpcNeeds.COMPONENT_ID) as NpcNeeds
	var needs_segment_at: float = world.clock.world_time_sec + 0.0015432098765432098
	assert_true(needs.set_rate_modifiers(0.016666666666666666, 0.30000000000000004, needs_segment_at).ok)
	needs.advance_to(needs_segment_at + 0.016666666666666666)

	var emotions: NpcEmotions = npc.component(NpcEmotions.COMPONENT_ID) as NpcEmotions
	assert_true(emotions.apply_emotion("hope", 0.75, world.clock.world_time_sec).ok)
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	var recorded: ActionResult = memories.record_memory(
		"",
		"precision_audit",
		[{"entity_id": "npc_000999", "role": "actor"}],
		Vector3(3.0, 0.0, 4.0),
		world.clock.world_time_sec,
		NpcMemory.OBSERVATION_DIRECT,
		0.8,
		0.7,
		PackedStringArray(["precision"]),
		0.6,
		false
	)
	assert_true(recorded.ok, recorded.reason)
	var relationships: RelationshipStore = npc.component(RelationshipStore.COMPONENT_ID) as RelationshipStore
	var relationship: RelationshipState = RelationshipState.new()
	relationship.source_entity_id = npc_id
	relationship.target_entity_id = "npc_000999"
	relationship.trust = 0.25
	relationship.liking = 0.75
	relationship.respect = 0.5
	relationship.status = "acquaintance"
	relationship.last_interaction_time = world.clock.world_time_sec
	assert_true(relationships.put_relationship(relationship).ok)

	var components: Dictionary = _live_components(world, npc_id)
	var persisted_component_ids: PackedStringArray = [
		NpcNeeds.COMPONENT_ID,
		NpcScheduleComponent.COMPONENT_ID,
		NpcDecisionComponent.COMPONENT_ID,
		NpcEmotions.COMPONENT_ID,
		NpcMemoryStore.COMPONENT_ID,
		RelationshipStore.COMPONENT_ID,
		NpcExecutorState.COMPONENT_ID,
		NpcBehaviourState.COMPONENT_ID,
	]
	for component_id: String in persisted_component_ids:
		assert_true(components.has(component_id), "live NPC has %s document" % component_id)
		if components.has(component_id):
			var original: Dictionary = components[component_id]
			var round_tripped: Dictionary = _full_precision_json(original)
			var difference: String = _first_bit_difference(original, round_tripped, component_id)
			assert_eq(difference, "", difference)