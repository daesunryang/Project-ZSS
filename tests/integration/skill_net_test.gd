extends TestCase
## F-9: skill levels over real ENet (server + 2 clients). Skills are owner
## only: each client mirrors its own rows, from the join snapshot and from
## every change the server makes; nobody learns another player's levels.
## A client sends nothing about skills. Rules: tests/unit/skill_test.gd.

const WORLD: String = "skill_net_test_world"
const NEVER: float = 1.0e9
const WAIT_MSEC: int = 8000
const SETTLE_TICKS: int = 20
const FROZEN_NEED_HOURS: float = 100000.0
const BUILDING: String = SkillService.SKILL_BUILDING
const REPAIR: String = SkillService.SKILL_REPAIR

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	var net_settings: NetworkSettings = NetworkSettings.new()
	net_settings.autosave_interval_sec = 0.0
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.hunger_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.thirst_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.fatigue_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.respawn_delay_sec = NEVER
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.skills = SkillSettings.new()
	_cluster = NetTestCluster.new(tree, net_settings, _config)
	_world = ServerComposition.create_world(WORLD, _config)
	_world.seed_new_world(_config.dev_seed)


func after_each() -> void:
	if _cluster != null:
		await _cluster.shutdown()
	GameLogger.set_capture(false)


func _skills() -> SkillService:
	return _world.get_system(SkillService.SYSTEM_ID) as SkillService


func _mirror(service: NetworkService) -> ClientSkillState:
	return (service.get_module(SkillNetModule.MODULE_NAME) as SkillNetModule).client_state


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return condition.call()


func test_each_owner_mirrors_its_own_skills_and_nobody_else_sees_them() -> void:
	assert_eq(_cluster.start_server(_world, null), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	assert_true(await _wait(func() -> bool: return _mirror(a).rows.size() == 2 and _mirror(b).rows.size() == 2), "both got their rows with the join")
	assert_eq(_mirror(a).rows, _skills().rows_of(alice_id))
	assert_eq(_mirror(a).level_of(BUILDING), 1)

	# The server gives alice experience; only alice hears of it.
	var b_changes: Array[int] = [0]
	_mirror(b).changed.connect(func() -> void: b_changes[0] += 1)
	assert_true(_skills().add_xp(alice_id, BUILDING, 260).ok)
	assert_true(_skills().record_repair_done(alice_id).ok)
	assert_true(await _wait(func() -> bool: return _mirror(a).level_of(BUILDING) == 3), "alice's mirror follows the server")
	assert_eq(_mirror(a).rows, _skills().rows_of(alice_id), "the same rows as the server")
	await _cluster.wait_ticks(SETTLE_TICKS)
	assert_eq(b_changes[0], 0, "bob was told nothing about alice")
	assert_eq(_mirror(b).rows, _skills().rows_of(bob_id), "bob's mirror holds his own rows only")
	assert_eq(_mirror(b).level_of(BUILDING), 1)
	assert_eq(_mirror(a).rejected_count + _mirror(b).rejected_count, 0, "every message was valid")

	# A new client of alice gets her levels in the join snapshot.
	_cluster.remove_client(a)
	assert_true(await _wait(func() -> bool: return not _world.is_online(alice_id)), "alice left")
	var a2: NetworkService = await _cluster.join_client("alice")
	if a2 == null:
		fail("alice did not rejoin")
		return
	assert_true(await _wait(func() -> bool: return _mirror(a2).level_of(BUILDING) == 3), "rejoined with her levels")
	assert_eq(_mirror(a2).rows, _skills().rows_of(alice_id))

	# A new character starts at level 1 and the owner is told.
	assert_true(_world.start_new_character(alice_id).ok)
	assert_true(await _wait(func() -> bool: return _mirror(a2).level_of(BUILDING) == 1), "reset for the new character")
	assert_eq(SkillNetModule.MODULE_NAME, "SkillNet")
