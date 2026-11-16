extends TestCase
## P3-6 on top of P3-3 (docs/09 §15.6, §15.3): the buildings of the shipped
## test map (MapContentService, dev_test_map.tres) are completed walls with
## one closed door, placed through the server rules. Zombies find their way
## into such a building through its open door, not through a closed one, and
## neither see nor hit a player inside through its walls or closed door.
## Uses the whole shipped map (8 buildings, seeded once per world, the same
## way map_content_test.gd does) and the shipped navigation settings; the
## building looked at is house_a (origin tile (8, 8), 5 x 4 tiles, the door
## on its -Z side at tile (10, 8)). Server rules only, no nodes.

const WORLD: String = "map_navigation_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
const BUILDING_ID: String = "house_a"
const DOOR: String = "dev_door"
## Inside house_a, in the middle of the building.
const INSIDE: Vector3 = Vector3(10.5, 0.0, 10.5)
## Outside house_a, behind its +Z wall: the straight way is blocked and the
## door is on the far (-Z) side.
const BEHIND_THE_FAR_WALL: Vector3 = Vector3(10.5, 0.0, 15.5)

var _zombie: ZombieSettings


func before_each() -> void:
	GameLogger.set_capture(true)
	_zombie = ZombieSettings.new()
	_zombie.dev_spawn_count = 0
	_zombie.ai_period_sec = 1000.0
	_zombie.ai_bucket_count = 10
	_zombie.wander_pause_min_sec = NEVER
	_zombie.wander_pause_max_sec = NEVER


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## The shipped composition with the shipped test map and the shipped
## navigation settings; nothing that moves or makes noise by itself.
func _world() -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.player_noise = PlayerNoiseSettings.new()
	config.player_noise.footstep_loudness = 0.0
	config.zombie = _zombie
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.preload_lookahead_sec = 0.0
	config.map_content = MapContentDefinition.load_or_null()
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(null)
	var error: Error = world.seed_new_world(DevWorldSeed.new())
	if error != OK:
		fail("test setup: the world could not be seeded: " + error_string(error))
	return world


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _house() -> MapBuildingDefinition:
	var content: MapContentDefinition = MapContentDefinition.load_or_null()
	assert_not_null(content, "the test map is shipped")
	for building: MapBuildingDefinition in content.buildings:
		if building.building_id == BUILDING_ID:
			return building
	fail("the shipped test map has no %s" % BUILDING_ID)
	return null


## The seeded door of house_a: found by what the map data says it is.
func _door_id(world: ServerWorld) -> String:
	var piece: Dictionary = MapBuildingPlan.door_piece(_house())
	var building: BuildingService = _building(world)
	for structure_id: String in building.structure_ids():
		var structure: StructureInstance = building.get_structure(structure_id)
		if structure.definition_id == DOOR and structure.tile == (piece[MapBuildingPlan.KEY_TILE] as Vector2i) and structure.rotation == int(piece[MapBuildingPlan.KEY_ROTATION]):
			return structure_id
	fail("the door of %s was not placed" % BUILDING_ID)
	return ""


func _is_inside(position: Vector3) -> bool:
	var footprint: Rect2i = MapBuildingPlan.footprint(_house())
	return position.x > float(footprint.position.x) and position.x < float(footprint.end.x) and position.z > float(footprint.position.y) and position.z < float(footprint.end.y)


func _spawn_chaser(world: ServerWorld, position: Vector3, player: PlayerState) -> ZombieState:
	var service: ZombieService = _zombies(world)
	var result: ActionResult = service.spawn_zombie(world, position, ZombiePerception.yaw_towards(player.position - position, 0.0))
	assert_true(result.ok, "spawn: %s" % result.reason)
	var zombie: ZombieState = service.get_zombie(str(result.event["zombie_id"]))
	zombie.state = ZombieState.State.CHASE
	zombie.target_player_id = player.player_id
	zombie.target_visible = true
	zombie.focus_position = player.position
	return zombie


## Steps the world until the zombie is inside house_a or the time is up.
## Returns the seconds it took, or -1 when it never got in.
func _seconds_until_inside(world: ServerWorld, zombie: ZombieState, seconds: float) -> float:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)
		if _is_inside(zombie.position):
			return float(tick + 1) * TICK
	return -1.0


# ------------------------------------------------------------ tests

func test_the_seeded_building_is_walls_and_a_closed_door_the_path_finder_sees() -> void:
	var world: ServerWorld = _world()
	var building: BuildingService = _building(world)
	var house: MapBuildingDefinition = _house()
	var door_id: String = _door_id(world)
	assert_true(building.get_structure(door_id).is_standing(), "a seeded door is completed, not a blueprint")
	assert_false(building.get_structure(door_id).door_open, "and starts closed")
	# Every outer edge of the house blocks: the walls and the closed door.
	for piece: Dictionary in MapBuildingPlan.structure_pieces(house):
		var definition: StructureDefinition = CompositionConfig.from_defaults().structures.get_definition(str(piece[MapBuildingPlan.KEY_DEFINITION_ID]))
		if definition.placement != StructureDefinition.Placement.EDGE:
			continue
		var slot: Vector3i = StructureGrid.slot_of(definition.placement, piece[MapBuildingPlan.KEY_TILE] as Vector2i, int(piece[MapBuildingPlan.KEY_ROTATION]))
		assert_true(building.is_edge_blocked(slot), "edge %s of %s blocks" % [str(slot), str(piece)])
	var door_slot: Vector3i = building.slot_of_structure(door_id)
	assert_true(world.is_line_blocked(BEHIND_THE_FAR_WALL, INSIDE), "the +Z wall hides the inside")
	assert_true(world.is_line_blocked(Vector3(10.5, 0.0, 6.5), INSIDE), "and so does the closed door")
	var navigation: NavigationService = world.get_system(NavigationService.SYSTEM_ID) as NavigationService
	var closed: GridPathResult = navigation.find_path(BEHIND_THE_FAR_WALL, INSIDE)
	assert_false(closed.found, "no way in while the door is closed")
	assert_true(building.set_door_open(world, door_id, true).ok)
	assert_false(building.is_edge_blocked(door_slot), "an open door is no blocking edge")
	assert_false(world.is_line_blocked(Vector3(10.5, 0.0, 6.5), INSIDE), "and no blocking line")
	var open: GridPathResult = navigation.find_path(BEHIND_THE_FAR_WALL, INSIDE)
	assert_true(open.found, "the way in through the open door")
	var through_the_door: bool = false
	for waypoint: Vector3 in open.waypoints:
		through_the_door = through_the_door or (waypoint.z < 8.0 + 0.5 and absf(waypoint.x - 10.5) < 0.6)
	assert_true(through_the_door, "the path goes round to the door: %s" % str(open.waypoints))


func test_a_zombie_outside_reaches_a_player_inside_through_the_open_door() -> void:
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = INSIDE
	assert_true(_building(world).set_door_open(world, _door_id(world), true).ok)
	var zombie: ZombieState = _spawn_chaser(world, BEHIND_THE_FAR_WALL, player)
	var seconds: float = _seconds_until_inside(world, zombie, 20.0)
	print("[measure] P3-6 seeded house_a, open far-side door: the zombie got in after %.2f s (%d searches)" % [seconds, _zombies(world).total_plan_count])
	assert_true(seconds > 0.0, "through the open door within 20 s: %s" % str(zombie.position))
	assert_true(_zombies(world).total_plan_count > 0, "it needed a path, the straight way is a wall")


func test_a_zombie_outside_does_not_get_through_the_closed_door() -> void:
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	player.position = INSIDE
	var zombie: ZombieState = _spawn_chaser(world, BEHIND_THE_FAR_WALL, player)
	assert_eq(_seconds_until_inside(world, zombie, 20.0), -1.0, "never inside: %s" % str(zombie.position))
	assert_true(_survival(world).is_alive(player.player_id))
	# Opening the door later lets it in (the next search sees the open edge).
	assert_true(_building(world).set_door_open(world, _door_id(world), true).ok)
	assert_true(_seconds_until_inside(world, zombie, 20.0) > 0.0, "in after the door opened: %s" % str(zombie.position))


func test_the_seeded_closed_door_blocks_sight_and_melee_and_the_open_one_does_not() -> void:
	_zombie.ai_period_sec = 0.1
	_zombie.ai_bucket_count = 1
	_zombie.attack_windup_sec = 0.0
	var world: ServerWorld = _world()
	var player: PlayerState = world.join("alice")
	# Just inside the closed door, the zombie just outside it, facing it,
	# within sight and attack range.
	player.position = Vector3(10.5, 0.0, 8.6)
	var position: Vector3 = Vector3(10.5, 0.0, 7.5)
	var spawned: ActionResult = _zombies(world).spawn_zombie(world, position, ZombiePerception.yaw_towards(player.position - position, 0.0))
	assert_true(spawned.ok)
	var zombie: ZombieState = _zombies(world).get_zombie(str(spawned.event["zombie_id"]))
	var health: float = _survival(world).get_vitals(player.player_id).health
	for tick: int in range(roundi(2.0 / TICK)):
		world.step_systems(TICK)
	assert_eq(zombie.state, ZombieState.State.IDLE, "it does not see the player through the closed door")
	assert_eq(_survival(world).get_vitals(player.player_id).health, health, "nor hits it")
	assert_true(_building(world).set_door_open(world, _door_id(world), true).ok)
	for tick: int in range(roundi(2.0 / TICK)):
		world.step_systems(TICK)
	assert_true(_survival(world).get_vitals(player.player_id).health < health, "the open door lets it see and hit")
