extends TestCase
## P4-6: emotion and memory data attached to an NPC. Both components are
## lazy (no per-frame decay), server-owned, and survive a cell release.

const WORLD: String = "npc_mind_world"
const DEFINITION_ID: String = "t46_survivor"
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const FAR: Vector3 = Vector3(45.5, 0.0, 45.5)
const TICK: float = 0.1
const RELEASE_SEC: float = 1.0

var _cell_settings: WorldCellSettings = null
var _mind_settings: NpcMindSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
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
	_mind_settings = NpcMindSettings.new()


func after_each() -> void:
	GameLogger.set_capture(false)


func _definition() -> NpcDefinition:
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = DEFINITION_ID
	definition.display_name = "마음 테스트"
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
	config.npc_definitions.add(_definition())
	config.npc_mind = _mind_settings
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


func _spawn(world: ServerWorld) -> String:
	var result: ActionResult = _npcs(world).spawn_npc(world, DEFINITION_ID, SPAWN)
	assert_true(result.ok, result.reason)
	return str(result.event.get(NpcService.KEY_NPC_ID, ""))


func _emotions(world: ServerWorld, npc_id: String) -> NpcEmotions:
	return _npcs(world).get_npc(npc_id).component(NpcEmotions.COMPONENT_ID) as NpcEmotions


func _memories(world: ServerWorld, npc_id: String) -> NpcMemoryStore:
	return _npcs(world).get_npc(npc_id).component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore


func _participants(entity_id: String, role: String = "actor") -> Array[Dictionary]:
	return [{"entity_id": entity_id, "role": role}]


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


func _record(store: NpcMemoryStore, event_id: String, event_type: String, importance: float, long_term: bool = false, strength: float = 1.0) -> ActionResult:
	return store.record_memory(
		event_id,
		event_type,
		_participants("npc_000999"),
		Vector3(3.0, 0.0, 4.0),
		0.0,
		NpcMemory.OBSERVATION_DIRECT,
		importance,
		0.5,
		PackedStringArray(["help"]),
		strength,
		long_term
	)


func test_settings_and_composition_install_all_three_mind_components() -> void:
	assert_eq(_mind_settings.validate().size(), 0)
	assert_eq(_mind_settings.max_memories, 64, "docs/13 §16.4")
	var bad: NpcMindSettings = NpcMindSettings.new()
	bad.emotion_half_life_world_sec = 0.0
	bad.memory_half_life_world_sec = INF
	bad.max_memories = 0
	assert_eq(bad.validate().size(), 3)
	var world: ServerWorld = _world()
	world.join("alice")
	_run(world, TICK)
	var npc_id: String = _spawn(world)
	var npc: NpcState = _npcs(world).get_npc(npc_id)
	# Other tickets register their own components too (P4-2 needs, P4-3
	# schedule); this test owns only the three mind components.
	for component_id: String in [NpcEmotions.COMPONENT_ID, NpcMemoryStore.COMPONENT_ID, RelationshipStore.COMPONENT_ID]:
		assert_true(npc.component_ids().has(component_id), "the composition installs " + component_id)
	assert_not_null(_emotions(world, npc_id))
	assert_not_null(_memories(world, npc_id))
	assert_not_null(npc.component(RelationshipStore.COMPONENT_ID))


func test_thirteen_emotions_decay_lazily_from_the_saved_time() -> void:
	var world: ServerWorld = _world()
	world.join("alice")
	_run(world, TICK)
	var npc_id: String = _spawn(world)
	var emotions: NpcEmotions = _emotions(world, npc_id)
	assert_eq(NpcEmotions.AXES.size(), 13, "docs/05 §5")
	assert_eq(emotions.emotion_values_at(10.0).size(), 13)
	for axis: String in NpcEmotions.AXES:
		assert_eq(emotions.value_at(axis, 10.0), 0.0, axis)
	var applied: ActionResult = emotions.apply_emotion("fear", 0.8, 10.0)
	assert_true(applied.ok, applied.reason)
	assert_eq(emotions.value_at("fear", 10.0), 0.8)
	assert_true(absf(emotions.value_at("fear", 10.0 + _mind_settings.emotion_half_life_world_sec) - 0.4) < 0.000001, "one half-life halves the saved value")
	var before_query: Dictionary = emotions.to_document()
	emotions.value_at("fear", 10.0 + _mind_settings.emotion_half_life_world_sec * 2.0)
	assert_eq(emotions.to_document(), before_query, "a read calculates decay without a tick or a write")
	assert_eq(emotions.apply_emotion("not_an_emotion", 0.1, 10.0).reason, NpcEmotions.REASON_UNKNOWN_EMOTION)
	assert_eq(emotions.apply_emotion("fear", NAN, 10.0).reason, NpcEmotions.REASON_BAD_VALUE)
	assert_eq(emotions.apply_emotion("fear", 0.1, 9.0).reason, NpcEmotions.REASON_TIME_REWIND)
	assert_eq(emotions.apply_emotion("fear", 1.0, 10.0).event["value"], 1.0, "emotion axes are normalized and clamped")


func test_memories_merge_the_same_event_decay_and_evict_by_importance() -> void:
	_mind_settings.max_memories = 2
	_mind_settings.memory_half_life_world_sec = 100.0
	var world: ServerWorld = _world()
	world.join("alice")
	_run(world, TICK)
	var npc_id: String = _spawn(world)
	var memories: NpcMemoryStore = _memories(world, npc_id)
	var protected_result: ActionResult = _record(memories, "event_000100", "rescue", 0.1, true, 0.8)
	assert_true(protected_result.ok, protected_result.reason)
	var ordinary: ActionResult = _record(memories, "event_000101", "conversation", 0.6)
	assert_true(ordinary.ok, ordinary.reason)
	var ordinary_id: String = str(ordinary.event["memory_id"])
	var merged: ActionResult = memories.record_memory(
		"event_000101",
		"conversation",
		_participants("player_000001", "witness"),
		Vector3(3.0, 0.0, 4.0),
		0.0,
		NpcMemory.OBSERVATION_WITNESSED,
		0.7,
		0.8,
		PackedStringArray(["kindness"]),
		0.5,
		false
	)
	assert_true(merged.ok, merged.reason)
	assert_true(bool(merged.event["merged"]))
	assert_eq(str(merged.event["memory_id"]), ordinary_id)
	var merged_memory: NpcMemory = memories.memory(ordinary_id)
	assert_eq(merged_memory.repetition_count, 2)
	assert_eq(merged_memory.importance, 0.7)
	assert_true(merged_memory.interpretation_tags.has("help") and merged_memory.interpretation_tags.has("kindness"))
	assert_eq(merged_memory.participants.size(), 2)
	assert_true(absf(memories.strength_at(ordinary_id, merged_memory.strength_stored_at + 100.0) - 0.5) < 0.000001)
	# The protected low-importance memory is never an eviction candidate.
	var important: ActionResult = _record(memories, "event_000102", "escape", 0.9)
	assert_true(important.ok, important.reason)
	assert_eq(str(important.event["evicted_memory_id"]), ordinary_id)
	assert_null(memories.memory(ordinary_id))
	assert_not_null(memories.memory_for_event("event_000100"))
	# A new least-important unprotected memory is the candidate itself, so it
	# is not retained and cannot evict a more important one.
	var forgotten: ActionResult = _record(memories, "event_000103", "small_talk", 0.05)
	assert_false(forgotten.ok)
	assert_eq(forgotten.reason, NpcMemoryStore.REASON_NOT_RETAINED)
	assert_eq(memories.count(), 2)


func test_emotions_memories_and_event_ids_survive_cell_release_and_reload() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var alice: PlayerState = world.join("alice")
	_run(world, TICK)
	var npc_id: String = _spawn(world)
	var emotions: NpcEmotions = _emotions(world, npc_id)
	var memories: NpcMemoryStore = _memories(world, npc_id)
	assert_true(emotions.apply_emotion("hope", 0.75, 5.0).ok)
	var recorded: ActionResult = _record(memories, "", "hunger_satisfied", 0.8)
	assert_true(recorded.ok, recorded.reason)
	var event_id: String = str(recorded.event["event_id"])
	assert_true(event_id.begins_with("event_"), "P4 has an id, not an event ledger")
	var memory_id: String = str(recorded.event["memory_id"])
	var before: Dictionary = (_npcs(world).npc_document(npc_id)[NpcState.KEY_COMPONENTS] as Dictionary).duplicate(true)
	alice.position = FAR
	_run(world, RELEASE_SEC)
	assert_false(_npcs(world).has_npc(npc_id), "the NPC and components left memory")
	alice.position = SPAWN
	_run(world, TICK)
	assert_true(_npcs(world).has_npc(npc_id))
	var after: Dictionary = (_npcs(world).npc_document(npc_id)[NpcState.KEY_COMPONENTS] as Dictionary).duplicate(true)
	# Every component but the schedule (P4-3): back in a simulated cell the
	# NPC's overdue turn comes at once and its next turn moves on, which is
	# what a schedule is for (npc_scheduler_test.gd checks its round trip).
	for components: Dictionary in [before, after]:
		assert_true(components.erase(NpcScheduleComponent.COMPONENT_ID), "the composition schedules the NPC")
	assert_eq(_json(after), _json(before), "the JSON save data is identical after the cell round trip")
	assert_eq(_emotions(world, npc_id).value_at("hope", 5.0), 0.75)
	assert_eq(_memories(world, npc_id).memory(memory_id).event_id, event_id)
	var next_event_id: String = _memories(world, npc_id).issue_event_id()
	assert_true(next_event_id.begins_with("event_"))
	assert_ne(next_event_id, event_id, "the shared saved id sequence never reuses an event id")
