extends TestCase
## P2-T4 (docs/00 ADR-007): permanent death on the server, no network.
## A character that dies leaves everything it carried where it died; after
## the configured delay (action time) the player starts a new character at
## the spawn point with an empty inventory, initial vitals and the next
## character generation. Also: saving while dead, leaving while dead, saves
## written before this rule, and the v1 fragment defect reported by P2-T1.

const WORLD: String = "permanent_death_test_world"
const SINGLE: String = "t4_single"
const STACK: String = "t4_stack"
const STACK_MAX: int = 10
const CELL: String = DevWorldSeed.DEV_CELL_ID
const DEATH_AT: Vector3 = Vector3(12.5, 0.0, -7.0)
const SPAWN_AT: Vector3 = Vector3(1.0, 0.0, 2.0)
const DELAY_SEC: float = 5.0
const TICK: float = 0.1
const LETHAL_DAMAGE: float = 100000.0
const EPSILON: float = 0.000001

var _settings: SurvivalSettings = null
var _gameplay: GameplaySettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = ""
	_settings = SurvivalSettings.new()
	_settings.respawn_delay_sec = DELAY_SEC
	_gameplay = GameplaySettings.new()
	_gameplay.player_spawn_position = SPAWN_AT


func after_each() -> void:
	if not _root.is_empty():
		SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.new()
	var single: ItemDefinition = ItemDefinition.new()
	single.definition_id = SINGLE
	catalog.add(single)
	var stack: ItemDefinition = ItemDefinition.new()
	stack.definition_id = STACK
	stack.max_stack = STACK_MAX
	catalog.add(stack)
	return catalog


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.survival = _settings
	config.gameplay = _gameplay
	config.catalog = _catalog()
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	return config


func _world() -> ServerWorld:
	return ServerComposition.create_world(WORLD, _config())


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


## Puts a new item into the player's inventory (spawned where the player
## stands, then picked up).
func _give(world: ServerWorld, player: PlayerState, definition_id: String = SINGLE, quantity: int = 1) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, CELL, player.position)
	var result: ActionResult = world.try_pickup(player.player_id, item_id)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


func _kill(world: ServerWorld, player_id: String) -> void:
	var result: ActionResult = _survival(world).apply_damage(player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE))
	if not result.ok:
		fail("test setup: kill failed: " + result.reason)


## Advances the world by `seconds` of real (action) time in fixed ticks.
func _run(world: ServerWorld, seconds: float) -> void:
	var ticks: int = roundi(seconds / TICK)
	for tick: int in range(ticks):
		world.step_systems(TICK)


func _carried_ids(world: ServerWorld, player: PlayerState) -> Array:
	var ids: Array = []
	for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
		ids.append(item.item_instance_id)
	return ids


func _events_of(events: Array[Dictionary], event_type: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == event_type:
			matching.append(event)
	return matching


func _transactions_of(world: ServerWorld) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void: events.append(event))
	return events


## Asserts that every id of `item_ids` lies in the world at `position` and
## nowhere else, exactly once.
func _assert_lying_at(world: ServerWorld, item_ids: Array, position: Vector3, label: String) -> void:
	var world_ids: Array = Array(world.inventory.world_item_ids())
	for item_id: String in item_ids:
		assert_eq(world_ids.count(item_id), 1, "%s: %s lies in the world once" % [label, item_id])
		var item: ItemInstance = world.inventory.get_item(item_id)
		assert_not_null(item, "%s: %s still exists" % [label, item_id])
		if item == null:
			continue
		assert_eq(item.location_type, ItemInstance.LOCATION_WORLD, "%s: %s is a world item" % [label, item_id])
		assert_eq(world.inventory.world_position_of(item_id), position, "%s: %s lies where the character died" % [label, item_id])


# ------------------------------------------------------------ death

func test_death_leaves_everything_where_the_character_died() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carried: Array = [_give(world, alice), _give(world, alice, STACK, 7), _give(world, alice)]
	var bobs: String = _give(world, bob)
	var total: int = world.inventory.item_count()
	alice.position = DEATH_AT
	var transactions: Array[Dictionary] = _transactions_of(world)
	survival.drain_events()

	_kill(world, alice.player_id)
	# Everything is already in the world when the lethal hit returns.
	assert_false(survival.is_alive(alice.player_id))
	assert_eq(_carried_ids(world, alice), [], "a dead character carries nothing")
	_assert_lying_at(world, carried, DEATH_AT, "at death")
	assert_eq(world.inventory.get_item(carried[1]).quantity, 7, "stacks stay whole")
	assert_eq(world.inventory.item_count(), total, "nothing was created or lost")
	assert_eq(_carried_ids(world, bob), [bobs], "other players keep their items")
	assert_eq(transactions.size(), 1, "one transaction for the whole inventory")
	assert_eq(transactions[0].get("event_type", ""), InventoryService.EVENT_ITEMS_DROPPED)
	assert_eq(transactions[0].get("item_instance_ids", []), carried, "in slot order")
	assert_eq(alice.position, DEATH_AT, "the dead character stays where it fell")
	assert_eq(alice.character_generation, PlayerState.FIRST_CHARACTER_GENERATION, "still the first character while dead")
	var events: Array[Dictionary] = survival.drain_events()
	assert_eq(_events_of(events, SurvivalService.EVENT_PLAYER_DIED).size(), 1)
	assert_eq(_events_of(events, SurvivalService.EVENT_PLAYER_RESPAWNED).size(), 0)
	# Waiting changes nothing more: the items stay, nothing is dropped twice.
	_run(world, DELAY_SEC * 0.5)
	assert_false(survival.is_alive(alice.player_id), "still dead before the delay is over")
	_assert_lying_at(world, carried, DEATH_AT, "while waiting")
	assert_eq(transactions.size(), 1)
	assert_eq(world.inventory.item_count(), total)


func test_death_by_survival_rules_and_death_while_offline_drop_items_too() -> void:
	# Dehydration kills inside the survival step.
	_settings.dehydration_health_loss_per_world_sec = 1000.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carried: Array = [_give(world, alice), _give(world, alice, STACK, 3)]
	var bobs: String = _give(world, bob, STACK, 2)
	var total: int = world.inventory.item_count()
	alice.position = DEATH_AT
	survival.get_vitals(alice.player_id).thirst = _settings.need_max
	world.step_systems(TICK)
	assert_false(survival.is_alive(alice.player_id), "alice died of thirst")
	assert_eq(_carried_ids(world, alice), [])
	_assert_lying_at(world, carried, DEATH_AT, "death in the survival step")
	# A player who is killed while offline (server rule) is treated the same.
	var bob_at: Vector3 = Vector3(-30.0, 0.0, 4.0)
	bob.position = bob_at
	world.leave(bob.player_id)
	_kill(world, bob.player_id)
	assert_eq(_carried_ids(world, bob), [])
	_assert_lying_at(world, [bobs], bob_at, "death while offline")
	assert_eq(world.inventory.item_count(), total)


func test_death_at_the_world_edge_keeps_items_inside_the_world() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var item_id: String = _give(world, alice)
	var limit: float = _gameplay.world_half_extent_m
	alice.position = Vector3(limit + 50.0, 0.0, -limit - 50.0)
	_kill(world, alice.player_id)
	assert_eq(_carried_ids(world, alice), [])
	assert_eq(world.inventory.world_position_of(item_id), Vector3(limit, 0.0, -limit), "clamped into the play area")


# ------------------------------------------------------------ new character

func test_a_new_character_starts_at_the_spawn_point_with_nothing() -> void:
	_settings.respawn_hunger = 5.0
	_settings.respawn_thirst = 6.0
	_settings.respawn_fatigue = 7.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var player_id: String = alice.player_id
	var inventory_id: String = alice.inventory_id
	var carried: Array = [_give(world, alice), _give(world, alice, STACK, 4)]
	var total: int = world.inventory.item_count()
	alice.position = DEATH_AT
	var vitals: PlayerVitals = survival.get_vitals(player_id)
	vitals.hunger = 80.0
	vitals.thirst = 70.0
	vitals.fatigue = 60.0
	assert_true(survival.apply_damage(player_id, DamageInput.create("zombie_000001", BodyPart.Part.LEFT_LEG, Wound.Type.BITE, 20.0)).ok)
	vitals.infection.stage = InfectionState.Stage.EARLY
	vitals.infection.exposure = InfectionState.Exposure.BITE
	_kill(world, player_id)
	world.set_move_input(player_id, 1, Vector2(1.0, 0.0), 0.0, 0)
	survival.drain_events()

	_run(world, DELAY_SEC - 2.0 * TICK)
	assert_false(survival.is_alive(player_id), "the delay is action time (real seconds): not over yet")
	assert_eq(alice.character_generation, PlayerState.FIRST_CHARACTER_GENERATION)
	_run(world, 4.0 * TICK)
	assert_true(survival.is_alive(player_id), "the new character started")
	assert_eq(alice.character_generation, PlayerState.FIRST_CHARACTER_GENERATION + 1, "the second character of this player")
	assert_eq(alice.player_id, player_id, "same connection identity")
	assert_eq(alice.inventory_id, inventory_id, "same (now empty) inventory container")
	assert_eq(alice.position, SPAWN_AT, "at the configured spawn point")
	assert_eq(_carried_ids(world, alice), [], "the new character starts with an empty inventory")
	_assert_lying_at(world, carried, DEATH_AT, "after the new character started")
	assert_eq(world.inventory.item_count(), total)
	assert_eq(vitals.health, _settings.max_health)
	assert_eq(vitals.stamina, _settings.max_stamina)
	assert_true(absf(vitals.hunger - _settings.respawn_hunger) < 0.01, "initial hunger: %f" % vitals.hunger)
	assert_true(absf(vitals.thirst - _settings.respawn_thirst) < 0.01, "initial thirst: %f" % vitals.thirst)
	assert_true(absf(vitals.fatigue - _settings.respawn_fatigue) < 0.01, "initial fatigue: %f" % vitals.fatigue)
	assert_eq(vitals.injuries.size(), 0, "no wounds")
	assert_eq(vitals.infection.stage, InfectionState.Stage.NONE, "no infection")
	assert_eq(vitals.died_at_world_time, PlayerVitals.NOT_DEAD_TIME)
	assert_eq(vitals.died_at_action_time, PlayerVitals.NOT_DEAD_TIME)
	# The movement intent of the dead character does not move the new one.
	world.step_movement(1.0, 0, 1000)
	assert_eq(alice.position, SPAWN_AT)
	var started: Array[Dictionary] = _events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_RESPAWNED)
	assert_eq(started.size(), 1)
	assert_eq(started[0].get("player_id", ""), player_id)
	assert_eq(started[0].get("character_generation", 0), 2)
	assert_eq(started[0].get("position", []), [SPAWN_AT.x, SPAWN_AT.y, SPAWN_AT.z])
	assert_true(SaveService.is_json_safe(started[0]))

	# Every death is a new character.
	var again: String = _give(world, alice)
	_kill(world, player_id)
	_assert_lying_at(world, [again], SPAWN_AT, "second death")
	_run(world, DELAY_SEC + 2.0 * TICK)
	assert_true(survival.is_alive(player_id))
	assert_eq(alice.character_generation, 3)
	assert_eq(_carried_ids(world, alice), [])
	assert_eq(world.inventory.item_count(), total + 1)


func test_what_a_dead_character_left_can_be_taken_by_others_but_not_by_the_dead() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var first: String = _give(world, alice)
	var second: String = _give(world, alice, STACK, 5)
	var total: int = world.inventory.item_count()
	alice.position = DEATH_AT
	bob.position = DEATH_AT + Vector3(1.0, 0.0, 0.0)
	_kill(world, alice.player_id)
	# The dead character is finished: it cannot take its things back.
	var refused: ActionResult = world.try_pickup(alice.player_id, first)
	assert_false(refused.ok)
	assert_eq(refused.reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(world.try_drop_item(alice.player_id, first).reason, SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(world.player_action_block_reason(alice.player_id), SurvivalService.REASON_PLAYER_DEAD)
	assert_eq(world.player_action_block_reason(bob.player_id), "")
	# Someone else can.
	var taken: ActionResult = world.try_pickup(bob.player_id, first)
	assert_true(taken.ok, taken.reason)
	assert_eq(_carried_ids(world, bob), [first])
	_run(world, DELAY_SEC + 2.0 * TICK)
	assert_true(survival.is_alive(alice.player_id))
	assert_eq(_carried_ids(world, alice), [], "the new character has nothing")
	assert_eq(_carried_ids(world, bob), [first], "bob keeps what he took")
	_assert_lying_at(world, [second], DEATH_AT, "the rest")
	assert_eq(world.inventory.item_count(), total)
	# The new character is a living player like any other.
	alice.position = DEATH_AT
	assert_true(world.try_pickup(alice.player_id, second).ok, "a living character can pick the stack up")


# ------------------------------------------------------------ leaving, saving

func test_leaving_while_dead_and_coming_back_starts_the_new_character_once() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	world.join("bob")
	var carried: Array = [_give(world, alice), _give(world, alice, STACK, 2)]
	var total: int = world.inventory.item_count()
	alice.position = DEATH_AT
	_kill(world, alice.player_id)
	world.leave(alice.player_id)
	# The world keeps running for bob, well past alice's delay.
	_run(world, DELAY_SEC * 3.0)
	assert_false(survival.is_alive(alice.player_id), "nothing happens to an offline player")
	assert_eq(alice.character_generation, 1)
	assert_eq(alice.position, DEATH_AT)
	_assert_lying_at(world, carried, DEATH_AT, "while alice is away")
	var back: PlayerState = world.join("alice")
	assert_eq(back.player_id, alice.player_id)
	assert_false(survival.is_alive(alice.player_id), "the join itself changes nothing")
	world.step_systems(TICK)
	assert_true(survival.is_alive(alice.player_id), "the delay passed while she was away: the new character starts at once")
	assert_eq(alice.character_generation, 2)
	assert_eq(alice.position, SPAWN_AT)
	assert_eq(_carried_ids(world, alice), [])
	_assert_lying_at(world, carried, DEATH_AT, "after alice came back")
	assert_eq(world.inventory.item_count(), total)
	_run(world, DELAY_SEC * 2.0)
	assert_eq(alice.character_generation, 2, "one death, one new character")


func test_a_death_wait_survives_a_save_and_restart() -> void:
	_root = "user://test_saves/permanent_death_%d" % Time.get_ticks_usec()
	var config: CompositionConfig = _config()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), config)
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	if world == null:
		return
	var alice: PlayerState = world.join("alice")
	var carried: Array = [_give(world, alice), _give(world, alice, STACK, 6)]
	var total: int = world.inventory.item_count()
	alice.position = DEATH_AT
	_kill(world, alice.player_id)
	_run(world, 2.0)
	assert_eq(persistence.save(world), OK)

	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), config).load_or_create(WORLD)
	assert_not_null(restored, "world restored from save")
	if restored == null:
		return
	var survival: SurvivalService = _survival(restored)
	var restored_alice: PlayerState = restored.get_player(alice.player_id)
	assert_false(survival.is_alive(alice.player_id), "still dead after the restart")
	assert_eq(restored_alice.character_generation, 1)
	assert_eq(restored_alice.position, DEATH_AT)
	assert_eq(_carried_ids(restored, restored_alice), [], "the dead character was saved without items")
	_assert_lying_at(restored, carried, DEATH_AT, "restored")
	assert_eq(restored.inventory.get_item(carried[1]).quantity, 6)
	assert_eq(restored.inventory.item_count(), total, "nothing dropped twice, nothing lost")
	# The remaining 3 of 5 seconds run after the restart.
	restored.join("alice")
	_run(restored, 2.5)
	assert_false(survival.is_alive(alice.player_id), "0.5 s of the delay is still left")
	_run(restored, 1.0)
	assert_true(survival.is_alive(alice.player_id))
	assert_eq(restored_alice.character_generation, 2)
	assert_eq(restored_alice.position, SPAWN_AT)
	assert_eq(_carried_ids(restored, restored_alice), [])
	_assert_lying_at(restored, carried, DEATH_AT, "after the new character started")
	assert_eq(restored.inventory.item_count(), total)

	# The generation is part of the saved player.
	assert_eq(WorldPersistence.new(SaveService.new(_root), config).save(restored), OK)
	var third: ServerWorld = WorldPersistence.new(SaveService.new(_root), config).load_or_create(WORLD)
	assert_not_null(third)
	if third == null:
		return
	assert_eq(third.get_player(alice.player_id).character_generation, 2)
	assert_true(_survival(third).is_alive(alice.player_id))


func test_a_dead_character_saved_with_items_by_the_old_rule_drops_them_once() -> void:
	# Before P2-T4 a dead player kept the inventory. Such a save holds a dead
	# character that still carries items: they go to the world when the new
	# character starts, exactly once.
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var carried: Array = [_give(world, alice), _give(world, alice, STACK, 3)]
	var total: int = world.inventory.item_count()
	alice.position = DEATH_AT
	var vitals: PlayerVitals = _survival(world).get_vitals(alice.player_id)
	vitals.health = 0.0
	vitals.died_at_world_time = world.clock.world_time_sec
	vitals.died_at_action_time = world.clock.action_time_sec
	world.leave(alice.player_id)
	var documents: Dictionary = world.to_documents()

	var restored: ServerWorld = _world()
	var errors: PackedStringArray = restored.restore_documents(documents["world_state"], documents["players"])
	assert_eq(errors.size(), 0, "; ".join(errors))
	var survival: SurvivalService = _survival(restored)
	var restored_alice: PlayerState = restored.get_player(alice.player_id)
	assert_false(survival.is_alive(alice.player_id))
	assert_eq(_carried_ids(restored, restored_alice), carried, "loaded as saved")
	restored.join("alice")
	_run(restored, DELAY_SEC + 2.0 * TICK)
	assert_true(survival.is_alive(alice.player_id))
	assert_eq(restored_alice.character_generation, 2)
	assert_eq(_carried_ids(restored, restored_alice), [], "the new character starts empty")
	_assert_lying_at(restored, carried, DEATH_AT, "old-rule save")
	assert_eq(restored.inventory.item_count(), total)


func test_character_generation_is_saved_and_older_player_files_are_migrated() -> void:
	var state: PlayerState = PlayerState.new()
	state.player_id = "player_000001"
	state.player_key = "alice"
	state.inventory_id = "inventory_000002"
	assert_eq(state.character_generation, PlayerState.FIRST_CHARACTER_GENERATION)
	assert_eq(PlayerState.FIRST_CHARACTER_GENERATION, 1)
	state.character_generation = 4
	var document: Dictionary = state.to_dict()
	assert_eq(int(document["schema_version"]), PlayerState.SCHEMA_VERSION)
	assert_eq(document.get("character_generation", 0), 4)
	var parsed: PlayerState = PlayerState.from_dict(document)
	assert_not_null(parsed)
	assert_eq(parsed.character_generation, 4)
	# JSON turns the number into a float.
	var from_json: Dictionary = JSON.parse_string(JSON.stringify(document))
	assert_eq(PlayerState.from_dict(from_json).character_generation, 4)
	# A player file written before P2-T4 (schema 2) is the first character.
	var older: Dictionary = document.duplicate(true)
	older.erase("character_generation")
	older["schema_version"] = 2
	var migrated: Dictionary = SaveMigrations.defaults()[SaveService.CATEGORY_PLAYER].migrate(older)
	assert_eq(int(migrated["schema_version"]), PlayerState.SCHEMA_VERSION)
	assert_eq(migrated.get("character_generation", 0), 1)
	assert_eq(PlayerState.from_dict(migrated).character_generation, 1)
	assert_eq(SaveMigrations.PLAYER_SCHEMA_VERSION, PlayerState.SCHEMA_VERSION)
	# The whole chain from a Phase 1 file.
	var phase1: Dictionary = older.duplicate(true)
	phase1["schema_version"] = 1
	assert_eq(SaveMigrations.defaults()[SaveService.CATEGORY_PLAYER].migrate(phase1).get("character_generation", 0), 1)
	for bad: Variant in [0, -1, 1.5, "2", null]:
		var broken: Dictionary = document.duplicate(true)
		broken["character_generation"] = bad
		assert_true(PlayerState.validate_dict(broken).size() > 0, "rejected: %s" % str(bad))
	var missing: Dictionary = document.duplicate(true)
	missing.erase("character_generation")
	assert_true(PlayerState.validate_dict(missing).size() > 0, "a current file must carry the generation")


# ------------------------------------------------------------ P2-T1 report: v1 fragment

func test_a_dead_player_of_a_v1_fragment_can_be_saved_again_before_logging_in() -> void:
	# A survival fragment v1 (before B3) has no death timestamp. A dead player
	# loaded from it and saved again without ever coming online was written as
	# a current fragment with health 0 and no death time, which the next load
	# refused ("health/death timestamp mismatch"): the world could not be loaded.
	_root = "user://test_saves/permanent_death_v1_%d" % Time.get_ticks_usec()
	var config: CompositionConfig = _config()
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	var alice: PlayerState = world.join("alice")
	world.join("bob")
	_kill(world, alice.player_id)
	_run(world, 1.0)
	world.leave(alice.player_id)
	var documents: Dictionary = world.to_documents()
	var players: Dictionary = documents["players"]
	var fragment: Dictionary = ((players[alice.player_id] as Dictionary)[ServerWorld.KEY_SYSTEMS] as Dictionary)[SurvivalService.SYSTEM_ID]
	fragment["schema_version"] = PlayerVitals.LEGACY_SCHEMA_VERSION
	fragment.erase("died_at_world_time")
	fragment.erase("died_at_action_time")
	assert_eq(SaveService.new(_root).save_world(WORLD, documents["world_state"], players), OK)

	# First load: the v1 fragment is read; nobody logs in; the world is saved.
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), config)
	var first: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(first, "the v1 fragment loads")
	if first == null:
		return
	assert_false(_survival(first).is_alive(alice.player_id))
	assert_eq(persistence.save(first), OK)

	# Second load: must not fail.
	var second: ServerWorld = WorldPersistence.new(SaveService.new(_root), config).load_or_create(WORLD)
	assert_not_null(second, "a world saved again with the never-seen dead player still loads: %s" % _last_fatal_line())
	if second == null:
		return
	var survival: SurvivalService = _survival(second)
	assert_false(survival.is_alive(alice.player_id))
	assert_true(survival.get_vitals(alice.player_id).died_at_world_time >= 0.0, "the dead player has a death time")
	# ... and that player still gets a new character after logging in.
	second.join("alice")
	_run(second, DELAY_SEC + 2.0 * TICK)
	assert_true(survival.is_alive(alice.player_id))
	assert_eq(second.get_player(alice.player_id).character_generation, 2)


## The last FATAL log line captured so far ("" when there is none).
func _last_fatal_line() -> String:
	var lines: PackedStringArray = GameLogger.captured_lines()
	for index: int in range(lines.size() - 1, -1, -1):
		if lines[index].contains("[FATAL]"):
			return lines[index]
	return ""


# ------------------------------------------------------------ owner mirror (no network)

func _owner_snapshot(player_id: String, generation: Variant) -> Dictionary:
	return {
		"schema_version": ClientSurvivalState.SCHEMA_VERSION, "player_id": player_id, "alive": true,
		"health": 50.0, "stamina": 50.0,
		"needs": {"hunger": "good", "thirst": "good", "fatigue": "good"},
		"wounds": [], "infection_stage": "none", "character_generation": generation, "resting": false,
	}


func test_the_owner_mirror_carries_the_character_generation() -> void:
	const PLAYER: String = "player_000001"
	var mirror: ClientSurvivalState = ClientSurvivalState.new(SurvivalNetSettings.new(), SurvivalSettings.new())
	assert_eq(mirror.character_generation(), 0, "unknown before anything arrived")
	var fragment: Dictionary = {"schema_version": ClientSurvivalState.SCHEMA_VERSION, "self": _owner_snapshot(PLAYER, 1), "players": [{"player_id": PLAYER, "alive": true, "resting": false}]}
	assert_true(mirror.apply_join(PLAYER, fragment))
	assert_eq(mirror.character_generation(), 1)
	assert_true(mirror.apply_owner_snapshot(_owner_snapshot(PLAYER, 2)))
	assert_eq(mirror.character_generation(), 2, "the next character")
	# A snapshot without a usable generation is refused as a whole.
	for bad: Variant in [0, -3, 2.0, "2", null]:
		assert_false(mirror.apply_owner_snapshot(_owner_snapshot(PLAYER, bad)), "rejected: %s" % str(bad))
	var missing: Dictionary = _owner_snapshot(PLAYER, 3)
	missing.erase("character_generation")
	assert_false(mirror.apply_owner_snapshot(missing), "the previous format is refused")
	var previous_format: Dictionary = _owner_snapshot(PLAYER, 3)
	previous_format["schema_version"] = ClientSurvivalState.SCHEMA_VERSION - 1
	assert_false(mirror.apply_owner_snapshot(previous_format))
	assert_eq(mirror.character_generation(), 2, "refused snapshots change nothing")
	assert_eq(SurvivalNetModule.SCHEMA_VERSION, ClientSurvivalState.SCHEMA_VERSION, "server and client agree on the format")
