class_name PerfBenchScenario
extends RefCounted
## Fixed-seed high-load world shared by the bench and its digest tests.

const HOUSE_INSIDE: Vector3 = Vector3(10.5, 0.0, 10.5)
const HOUSE_FAR_WALL: Vector3 = Vector3(10.5, 0.0, 15.5)
const ITEM_DEFINITION: String = "dev_test_item"
const INPUT_TIMEOUT_MSEC: int = 1000

var seed: int = 0
var player_count: int = 0
var zombie_count: int = 0
var world_item_count: int = 0
var config: CompositionConfig = null
var world: ServerWorld = null
var bot_player_ids: PackedStringArray = []
var setup_error: String = ""


static func create(fixed_seed: int, players: int, zombies: int, world_items: int) -> PerfBenchScenario:
	var scenario: PerfBenchScenario = PerfBenchScenario.new()
	scenario._setup(fixed_seed, players, zombies, world_items)
	return scenario


func is_valid() -> bool:
	return world != null and setup_error.is_empty()


func prepare_bot_inputs(tick: int, now_msec: int) -> void:
	for index: int in range(bot_player_ids.size()):
		var phase: int = (tick / 90 + index + posmod(seed, 7)) % 8
		var angle: float = float(phase) * PI / 4.0
		var direction: Vector2 = Vector2(cos(angle), sin(angle)).normalized()
		world.set_move_input(bot_player_ids[index], tick + 1, direction, -angle, now_msec)


func step_deterministic(tick: int, delta: float) -> void:
	var now_msec: int = roundi(float(tick) * delta * 1000.0)
	prepare_bot_inputs(tick, now_msec)
	world.step_movement(delta, now_msec, INPUT_TIMEOUT_MSEC)
	world.step_systems(delta)


func run_ticks(ticks: int, delta: float) -> void:
	for tick: int in range(ticks):
		step_deterministic(tick, delta)


func state_digest() -> String:
	return PerfBenchState.digest(world) if world != null else ""


func counts() -> Dictionary:
	if world == null:
		return {}
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	var containers: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
	return {
		"players": world.online_player_ids().size(),
		"zombies": zombies.zombie_count() if zombies != null else 0,
		"world_items": world.inventory.world_item_ids().size(),
		"structures": building.structure_count() if building != null else 0,
		"containers": containers.container_count() if containers != null else 0,
	}


func _setup(fixed_seed: int, players: int, zombies: int, world_items: int) -> void:
	seed = fixed_seed
	player_count = players
	zombie_count = zombies
	world_item_count = world_items
	if players < 1 or zombies < 1 or world_items < 0:
		setup_error = "players and zombies must be positive and world items must be non-negative"
		return
	config = CompositionConfig.from_defaults()
	config.zombie = config.zombie.duplicate(true) as ZombieSettings
	config.zombie.dev_spawn_count = 0
	config.zombie.rng_seed = fixed_seed
	if zombies > config.zombie.max_active_zombies:
		setup_error = "requested %d zombies, but the configured cap is %d" % [zombies, config.zombie.max_active_zombies]
		return
	config.map_content = MapContentDefinition.load_or_null()
	var errors: PackedStringArray = config.validate()
	if not errors.is_empty():
		setup_error = "; ".join(errors)
		return
	world = ServerComposition.create_world("perf_bench", config)
	if world == null:
		setup_error = "server composition failed"
		return
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	if cells != null:
		cells.set_store(null)
	var seeded: Error = world.seed_new_world(DevWorldSeed.new())
	if seeded != OK:
		setup_error = "world seeding failed: %s" % error_string(seeded)
		world = null
		return
	_place_players(players)
	if cells != null:
		cells.refresh(world)
	_place_world_items(fixed_seed, world_items)
	_open_house_door()
	_place_zombies(fixed_seed, zombies)


func _place_players(players: int) -> void:
	var offsets: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(-1.0, 0.0, 0.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, -1.0),
		Vector3(1.0, 0.0, 1.0),
		Vector3(-1.0, 0.0, -1.0),
		Vector3(-1.0, 0.0, 1.0),
	]
	for index: int in range(players):
		var player: PlayerState = world.join("perf_bot_%d" % index)
		if player == null:
			setup_error = "could not join bot %d" % index
			world = null
			return
		player.position = HOUSE_INSIDE + offsets[index % offsets.size()]
		bot_player_ids.append(player.player_id)


func _place_world_items(fixed_seed: int, count: int) -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = fixed_seed ^ 0x51A7E
	for index: int in range(count):
		var position: Vector3 = Vector3(rng.randf_range(-30.0, 30.0), 0.0, rng.randf_range(-30.0, 30.0))
		var item_id: String = world.inventory.spawn_world_item(ITEM_DEFINITION, 1, world.cell_id_at(position), position)
		if item_id.is_empty():
			setup_error = "could not spawn world item %d" % index
			world = null
			return


func _open_house_door() -> void:
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	if building == null:
		return
	for structure_id: String in building.structure_ids():
		var structure: StructureInstance = building.get_structure(structure_id)
		if structure.definition_id == "dev_door" and structure.tile == Vector2i(10, 8):
			building.set_door_open(world, structure_id, true)
			return


func _place_zombies(fixed_seed: int, count: int) -> void:
	var service: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = fixed_seed
	var blocked_count: int = ceili(float(count) * 0.75)
	for index: int in range(count):
		var target_id: String = bot_player_ids[index % bot_player_ids.size()]
		var target: PlayerState = world.get_player(target_id)
		var position: Vector3
		if index < blocked_count:
			position = HOUSE_FAR_WALL + Vector3(rng.randf_range(-2.0, 2.0), 0.0, rng.randf_range(0.0, 2.5))
		else:
			var angle: float = rng.randf_range(-PI, PI)
			var radius: float = rng.randf_range(6.0, 12.0)
			position = HOUSE_INSIDE + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		var yaw: float = ZombiePerception.yaw_towards(target.position - position, 0.0)
		var spawned: ActionResult = service.spawn_zombie(world, position, yaw)
		if not spawned.ok:
			setup_error = "could not spawn zombie %d: %s" % [index, spawned.reason]
			world = null
			return
		var zombie: ZombieState = service.get_zombie(str(spawned.event["zombie_id"]))
		zombie.state = ZombieState.State.CHASE
		zombie.target_player_id = target_id
		zombie.target_visible = true
		zombie.focus_position = target.position
