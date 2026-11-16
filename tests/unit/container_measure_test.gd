extends TestCase
## P3-3 measurements (docs/15 §15.3): what containers cost the server. These
## print numbers of this machine; they are not limits (CLAUDE.md §6: no
## performance claim without a measurement). The assertions only check that
## the measured runs did what they were meant to do.

const WORLD: String = "container_measure_world"
const NEVER: float = 1.0e9
const TICK: float = 1.0 / 60.0
const TICKS: int = 2000
const TRANSFERS: int = 2000
const BULK: String = "t33m_bulk"
const BULK_MAX: int = 1000
const BOX: String = "t33m_box"
const VIEWERS: int = 8
const STORE_AT: Vector3 = Vector3(1.0, 0.0, 0.0)


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


func _world() -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.gameplay = GameplaySettings.new()
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.containers = ContainerSettings.new()
	config.containers.search_duration_sec = 0.0
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var bulk: ItemDefinition = ItemDefinition.new()
	bulk.definition_id = BULK
	bulk.max_stack = BULK_MAX
	catalog.add(bulk)
	config.catalog = catalog
	config.container_definitions = ContainerCatalog.new()
	var box: ContainerDefinition = ContainerDefinition.new()
	box.definition_id = BOX
	box.slot_count = 12
	config.container_definitions.add(box)
	return ServerComposition.create_world(WORLD, config)


func _containers(world: ServerWorld) -> ContainerService:
	return world.get_system(ContainerService.SYSTEM_ID) as ContainerService


## Microseconds per call of ContainerService.step with what is open now.
func _step_usec(world: ServerWorld) -> float:
	var service: ContainerService = _containers(world)
	var started: int = Time.get_ticks_usec()
	for tick: int in range(TICKS):
		service.step(world, TICK, TICK)
	return float(Time.get_ticks_usec() - started) / float(TICKS)


func test_measure_the_server_cost_of_an_open_container_with_several_viewers() -> void:
	var world: ServerWorld = _world()
	var service: ContainerService = _containers(world)
	var players: Array[PlayerState] = []
	for index: int in range(VIEWERS):
		players.append(world.join("viewer_%d" % index))
	var created: ActionResult = service.create_container(world, BOX, STORE_AT)
	assert_true(created.ok, created.reason)
	var box_id: String = str(created.event["container_id"])
	var item_id: String = world.inventory.spawn_world_item(BULK, BULK_MAX, world.cell_id_at(Vector3.ZERO), Vector3.ZERO)
	assert_true(world.try_pickup(players[0].player_id, item_id).ok)
	# 1. The per-tick check of the open sessions.
	var idle_usec: float = _step_usec(world)
	assert_true(service.try_open(world, players[0].player_id, box_id).ok)
	var one_usec: float = _step_usec(world)
	for index: int in range(1, VIEWERS):
		assert_true(service.try_open(world, players[index].player_id, box_id).ok)
	var many_usec: float = _step_usec(world)
	assert_eq(service.viewers_of(box_id).size(), VIEWERS, "every session survived the measured ticks")
	print("[measure] container step per server tick: %.2f us with nothing open, %.2f us with 1 viewer, %.2f us with %d viewers of one container" % [idle_usec, one_usec, many_usec, VIEWERS])
	# 2. One put and one take (rule + transaction + the event with the viewer
	#    list), with one viewer and with many.
	service.drain_events()
	var started: int = Time.get_ticks_usec()
	var moved: int = 0
	for index: int in range(TRANSFERS):
		var carried: Array[ItemInstance] = world.inventory.items_in_inventory(players[0].inventory_id)
		if service.try_put(world, players[0].player_id, box_id, carried[0].item_instance_id, 1).ok:
			moved += 1
		var inside: Array[Dictionary] = service.contents_of(box_id)
		if service.try_take(world, players[0].player_id, box_id, str(inside[0]["item_instance_id"]), 1).ok:
			moved += 1
		service.drain_events()
	var pair_usec: float = float(Time.get_ticks_usec() - started) / float(TRANSFERS)
	assert_eq(moved, TRANSFERS * 2, "every measured put and take was accepted")
	var total: int = 0
	for item: ItemInstance in world.inventory.items_in_inventory(players[0].inventory_id):
		total += item.quantity
	for entry: Dictionary in service.contents_of(box_id):
		total += int(entry["quantity"])
	assert_eq(total, BULK_MAX, "and no unit was lost on the way")
	print("[measure] one put + one take of one unit (rules, transaction, events for %d viewers): %.1f us" % [VIEWERS, pair_usec])
	# 3. Opening a searched container (the content snapshot for the opener).
	for index: int in range(1, VIEWERS):
		service.try_close(world, players[index].player_id, box_id)
	started = Time.get_ticks_usec()
	for index: int in range(TRANSFERS):
		service.try_open(world, players[1].player_id, box_id)
		service.try_close(world, players[1].player_id, box_id)
	print("[measure] one open + one close of a searched container: %.1f us" % (float(Time.get_ticks_usec() - started) / float(TRANSFERS)))
	service.drain_events()
