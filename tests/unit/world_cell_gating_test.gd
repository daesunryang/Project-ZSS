extends TestCase
## P3-1: simulation gating by world cells (docs/03 §3.2, docs/09 §15.1,
## CLAUDE.md §6). Zombie AI, sight, attacks and hearing run only for zombies
## in ACTIVE cells; a zombie in a cell that is merely in memory is frozen as
## it is. Also: what happens at the border of the active area, and that
## nothing is stepped for zombies outside it.

const WORLD: String = "cell_gating_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9

var _settings: WorldCellSettings = null
var _zombie_settings: ZombieSettings = null
var _spawn: Vector3 = Vector3.ZERO


## A store that cannot load some cells (they stay UNLOADED).
class BrokenCellStore extends WorldCellStore:
	var broken: Dictionary[String, bool] = {}

	func load_cell(cell_id: String) -> Dictionary:
		if broken.has(cell_id):
			return {WorldCellStore.KEY_ERROR: ERR_FILE_CORRUPT, WorldCellStore.KEY_DOCUMENT: {}}
		return super.load_cell(cell_id)


func before_each() -> void:
	GameLogger.set_capture(true)
	_spawn = Vector3(5.0, 0.0, 5.0)
	# 10 m cells. Only the player's own cell is active; its neighbours are
	# in memory but frozen. Tests that need the control case widen the area.
	_settings = WorldCellSettings.new()
	_settings.cell_size_m = 10.0
	_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_settings.bounds_max_m = Vector2(50.0, 50.0)
	_settings.active_radius_cells = 0
	_settings.preload_radius_cells = 2
	_settings.preload_lookahead_sec = 0.0
	_settings.deactivate_delay_sec = 0.0
	_settings.unload_delay_sec = NEVER
	_settings.refresh_period_sec = 0.0
	_settings.max_preload_loads_per_refresh = 1000
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER


func after_each() -> void:
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = _spawn
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = _zombie_settings
	config.world_cells = _settings
	return config


func _world(store: WorldCellStore = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	world.seed_new_world(DevWorldSeed.new())
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	return world


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _noise(world: ServerWorld) -> NoiseService:
	return world.get_system(NoiseService.SYSTEM_ID) as NoiseService


func _spawn_zombie(world: ServerWorld, position: Vector3, facing: Vector3) -> String:
	var yaw: float = ZombiePerception.yaw_towards(facing, 0.0)
	return str(_zombies(world).spawn_zombie(world, position, yaw).event["zombie_id"])


func _run(world: ServerWorld, seconds: float, events: Array[Dictionary] = []) -> void:
	var service: ZombieService = _zombies(world)
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)
		events.append_array(service.drain_events())


func _types(events: Array[Dictionary]) -> PackedStringArray:
	var types: PackedStringArray = []
	for event: Dictionary in events:
		if not types.has(str(event["event_type"])):
			types.append(str(event["event_type"]))
	return types


func _heard(events: Array[Dictionary]) -> int:
	var count: int = 0
	for event: Dictionary in events:
		if event["event_type"] == ZombieService.EVENT_DETECTED and event["sense"] == ZombieService.SENSE_SOUND:
			count += 1
	return count


# ------------------------------------------------------------ frozen vs simulated

func test_a_zombie_in_an_inactive_cell_does_not_move_sense_or_attack() -> void:
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	# 10 m in front of the player, looking straight at it, in the next cell.
	var zombie_id: String = _spawn_zombie(world, Vector3(15.0, 0.0, 5.0), Vector3(-1.0, 0.0, 0.0))
	assert_true(world.is_cell_loaded("cell_1_0") and not world.is_cell_simulated("cell_1_0"))
	var before: Dictionary = _zombies(world).get_zombie(zombie_id).to_dict()
	var health: float = _survival(world).get_vitals(player_id).health
	var events: Array[Dictionary] = []
	_zombies(world).drain_events()
	_run(world, 8.0, events)
	assert_eq(_zombies(world).get_zombie(zombie_id).to_dict(), before, "frozen exactly as it was")
	assert_eq(events.size(), 0, "no detection, no state change, no attack")
	assert_eq(_survival(world).get_vitals(player_id).health, health)
	assert_eq(_zombies(world).total_ai_update_count, 0, "not even one AI decision was made for it")
	assert_eq(_zombies(world).simulated_count(), 0)


func test_the_same_zombie_in_an_active_cell_sees_chases_and_attacks() -> void:
	_settings.active_radius_cells = 1
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	var zombie_id: String = _spawn_zombie(world, Vector3(15.0, 0.0, 5.0), Vector3(-1.0, 0.0, 0.0))
	assert_true(world.is_cell_simulated("cell_1_0"))
	var health: float = _survival(world).get_vitals(player_id).health
	var events: Array[Dictionary] = []
	_zombies(world).drain_events()
	_run(world, 8.0, events)
	var types: PackedStringArray = _types(events)
	assert_true(types.has(ZombieService.EVENT_DETECTED), "it saw the player")
	assert_true(types.has(ZombieService.EVENT_STATE_CHANGED))
	assert_true(types.has(ZombieService.EVENT_ATTACKED), "and reached and hit it")
	assert_true(_survival(world).get_vitals(player_id).health < health)
	assert_true(_zombies(world).get_zombie(zombie_id).position.distance_to(Vector3(15.0, 0.0, 5.0)) > 5.0, "it moved")
	assert_eq(_zombies(world).simulated_count(), 1)


func test_a_frozen_zombie_wakes_when_its_cell_becomes_active() -> void:
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	var zombie_id: String = _spawn_zombie(world, Vector3(25.0, 0.0, 5.0), Vector3(-1.0, 0.0, 0.0))
	var events: Array[Dictionary] = []
	_zombies(world).drain_events()
	_run(world, 3.0, events)
	assert_eq(events.size(), 0)
	# The player walks into the zombie's cell: it is active now.
	world.get_player(player_id).position = Vector3(21.0, 0.0, 5.0)
	_run(world, 3.0, events)
	assert_true(world.is_cell_simulated("cell_2_0"))
	assert_true(_types(events).has(ZombieService.EVENT_DETECTED), "it senses again")
	assert_eq(_zombies(world).simulated_count(), 1)
	assert_true(_zombies(world).has_zombie(zombie_id))


# ------------------------------------------------------------ noise

func test_noise_is_not_heard_in_an_inactive_cell_not_even_after_waking() -> void:
	_settings.active_radius_cells = 1
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	# Two cells away, with its back to the player: preloaded, not active.
	var zombie_id: String = _spawn_zombie(world, Vector3(25.0, 0.0, 5.0), Vector3(1.0, 0.0, 0.0))
	assert_false(world.is_cell_simulated("cell_2_0"))
	var events: Array[Dictionary] = []
	_zombies(world).drain_events()
	assert_true(_noise(world).emit("test_source", Vector3(27.0, 0.0, 5.0), 40.0, "broadband").ok, "a loud noise right next to it, reaching far into its cell")
	_run(world, 2.0, events)
	assert_eq(_heard(events), 0, "a frozen zombie hears nothing")
	assert_eq(ZombieState.state_name(_zombies(world).get_zombie(zombie_id).state), "idle")
	# Its cell becomes active while that noise is still ringing (8 s).
	world.get_player(player_id).position = Vector3(15.0, 0.0, 5.0)
	_run(world, 2.0, events)
	assert_true(world.is_cell_simulated("cell_2_0"))
	assert_eq(_noise(world).active_count(), 1, "the old noise is still there")
	assert_eq(_heard(events), 0, "what rang before it woke is not heard")
	# A new noise is.
	assert_true(_noise(world).emit("test_source", Vector3(35.0, 0.0, 5.0), 40.0, "broadband").ok)
	_run(world, 2.0, events)
	assert_eq(_heard(events), 1, "awake, it hears")
	assert_eq(ZombieState.state_name(_zombies(world).get_zombie(zombie_id).state), "investigate")


# ------------------------------------------------------------ borders

func test_a_zombie_that_walks_into_an_inactive_cell_freezes_there_and_goes_on_later() -> void:
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	world.get_player(player_id).position = Vector3(1.0, 0.0, 5.0)
	# In the player's (active) cell, with its back to the player.
	var zombie_id: String = _spawn_zombie(world, Vector3(8.0, 0.0, 5.0), Vector3(1.0, 0.0, 0.0))
	var events: Array[Dictionary] = []
	_zombies(world).drain_events()
	assert_true(_noise(world).emit("test_source", Vector3(18.0, 0.0, 5.0), 40.0, "broadband").ok, "a noise in the next cell")
	_run(world, 4.0, events)
	var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
	assert_eq(_heard(events), 1, "it heard it while it was in the active cell")
	assert_eq(world.cell_id_at(zombie.position), "cell_1_0", "and walked over the border")
	assert_eq(world.cell_index.cell_of(zombie_id), "cell_1_0", "the index followed it")
	assert_eq(world.cell_index.entities_in_cell("cell_0_0", ZombieService.ENTITY_KIND_ZOMBIE).size(), 0)
	assert_true(zombie.position.x < 10.2, "it froze right behind the border: " + str(zombie.position.x))
	assert_eq(ZombieState.state_name(zombie.state), "investigate", "in the state it was in")
	assert_eq(_zombies(world).simulated_count(), 0)
	var frozen_at: Vector3 = zombie.position
	_run(world, 3.0, events)
	assert_eq(zombie.position, frozen_at, "it does not move while its cell is inactive")
	# Its cell becomes active: it goes on walking to the noise.
	world.get_player(player_id).position = Vector3(11.0, 0.0, 9.5)
	_run(world, 2.0, events)
	assert_true(zombie.position.x > frozen_at.x + 1.0, "it went on")
	assert_eq(_zombies(world).simulated_count(), 1)


func test_a_zombie_never_walks_into_a_cell_that_is_not_in_memory() -> void:
	var store: BrokenCellStore = BrokenCellStore.new()
	store.broken["cell_1_0"] = true
	var world: ServerWorld = _world(store)
	var player_id: String = world.join("alice").player_id
	world.get_player(player_id).position = Vector3(1.0, 0.0, 5.0)
	assert_false(world.is_cell_loaded("cell_1_0"), "the next cell could not be loaded")
	var zombie_id: String = _spawn_zombie(world, Vector3(8.0, 0.0, 5.0), Vector3(1.0, 0.0, 0.0))
	assert_true(_noise(world).emit("test_source", Vector3(18.0, 0.0, 5.0), 40.0, "broadband").ok)
	_run(world, 4.0)
	var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
	assert_true(zombie.position.x < 10.0, "it stops at the border: " + str(zombie.position.x))
	assert_true(zombie.position.x > 9.0, "after walking up to it")
	assert_eq(world.cell_index.cell_of(zombie_id), "cell_0_0")
	assert_true(_zombies(world).blocked_move_count > 0)
	assert_eq(_zombies(world).simulated_count(), 1, "it stays simulated in its own cell")


# ------------------------------------------------------------ cost

func test_only_zombies_in_active_cells_are_stepped() -> void:
	_zombie_settings.max_active_zombies = 500
	_zombie_settings.max_ai_updates_per_tick = 1000
	var world: ServerWorld = _world()
	world.join("alice")
	var zombies: ZombieService = _zombies(world)
	# Three zombies in the player's cell (behind it), 200 spread over the
	# preloaded cells around it.
	for index: int in range(3):
		_spawn_zombie(world, Vector3(1.0 + float(index), 0.0, 1.0), Vector3(-1.0, 0.0, -1.0))
	for index: int in range(200):
		var cell: Vector2i = Vector2i(1 + index % 2, -2 + (index >> 1) % 5)
		_spawn_zombie(world, world.cell_grid.cell_center(cell) + Vector3(float(index % 7) - 3.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0))
	assert_eq(zombies.zombie_count(), 203)
	assert_eq(zombies.simulated_count(), 3)
	_run(world, 5.0)
	# One decision per zombie and AI period (0.5 s) for the three, none for
	# the two hundred.
	assert_true(zombies.total_ai_update_count >= 27 and zombies.total_ai_update_count <= 33, "AI decisions: %d" % zombies.total_ai_update_count)
	assert_eq(zombies.simulated_count(), 3)


func test_corpses_in_inactive_cells_wait_and_are_removed_once_simulated() -> void:
	_zombie_settings.corpse_remove_delay_sec = 1.0
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	var zombie_id: String = _spawn_zombie(world, Vector3(25.0, 0.0, 5.0), Vector3(1.0, 0.0, 0.0))
	assert_true(_zombies(world).apply_damage_to_zombie(zombie_id, 1000.0, player_id).ok)
	_run(world, 3.0)
	assert_true(_zombies(world).has_zombie(zombie_id), "nothing is cleaned up in a frozen cell")
	world.get_player(player_id).position = Vector3(25.0, 0.0, 8.0)
	_run(world, 0.5)
	assert_false(_zombies(world).has_zombie(zombie_id), "the overdue corpse goes as soon as its cell is simulated")
	assert_true(world.registry.is_tombstoned(zombie_id))
	assert_false(world.cell_index.has(zombie_id))


func test_a_hit_on_a_frozen_zombie_is_noticed_when_it_wakes() -> void:
	var world: ServerWorld = _world()
	var player_id: String = world.join("alice").player_id
	var zombie_id: String = _spawn_zombie(world, Vector3(15.0, 0.0, 5.0), Vector3(1.0, 0.0, 0.0))
	var events: Array[Dictionary] = []
	_zombies(world).drain_events()
	assert_true(_zombies(world).apply_damage_to_zombie(zombie_id, 10.0, player_id).ok, "server rules can still damage it")
	_run(world, 2.0, events)
	assert_eq(_types(events), PackedStringArray([ZombieService.EVENT_DAMAGED]), "it does not react while frozen")
	_settings.active_radius_cells = 1
	_run(world, 1.0, events)
	assert_true(world.is_cell_simulated("cell_1_0"))
	assert_true(_types(events).has(ZombieService.EVENT_DETECTED), "it turns on its attacker once it is simulated")


# ------------------------------------------------------------ defaults

func test_default_settings_simulate_everything_near_the_spawn_point() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.zombie = config.zombie.duplicate() as ZombieSettings
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	assert_eq(world.seed_new_world(config.dev_seed), OK)
	var zombies: ZombieService = _zombies(world)
	assert_eq(zombies.simulated_count(), 0, "nobody is there yet")
	world.join("alice")
	assert_eq(zombies.zombie_count(), config.zombie.dev_spawn_count)
	assert_eq(zombies.simulated_count(), zombies.zombie_count(), "every development zombie (40-90 m from the spawn point) is simulated, as in Phase 2")
	for item_id: String in world.inventory.world_item_ids():
		assert_true(world.is_cell_simulated(world.inventory.get_item(item_id).location_id))
	var reach: float = (world.get_system(NoiseService.SYSTEM_ID) as NoiseService).max_audible_distance(config.noise.max_loudness, config.zombie.hearing_multiplier)
	var simulated_m: float = float(config.world_cells.active_radius_cells) * config.world_cells.cell_size_m
	assert_true(simulated_m >= reach, "no audible noise reaches past the active area (%.1f m >= %.1f m)" % [simulated_m, reach])
	assert_true(simulated_m >= config.zombie.effective_sight_range_m())
