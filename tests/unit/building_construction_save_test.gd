extends TestCase
## P3-5: a structure under construction in saves and world cells (docs/04
## §12 "청사진 중단/재개/완공 후 저장과 복구가 정상이다", docs/09 §15.5): the
## two new fields of a structure document, documents written by P3-4a
## (schema 1), a cell that leaves memory in the middle of a construction and
## comes back, world documents, and what a restore refuses. Real files and a
## server restart: tests/integration/construction_net_test.gd.

const WORLD: String = "construction_save_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
const LETHAL_DAMAGE: float = 100000.0
const TOLERANCE: float = 0.000001
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const SPAWN_TILE: Vector2i = Vector2i(5, 5)
const AWAY: Vector3 = Vector3(5.5, 0.0, 25.5)
const PLANK: String = ConstructionTestKit.PLANK
const NAIL: String = ConstructionTestKit.NAIL
const WALL: String = ConstructionTestKit.WALL
const FLOOR: String = ConstructionTestKit.FLOOR
const FREE_WALL: String = ConstructionTestKit.FREE_WALL
const WALL_WORK_SEC: float = ConstructionTestKit.WALL_WORK_SEC
const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X
const EAST: int = 1
const WEST: int = 3
const NORTH: int = 0

var _cell_settings: WorldCellSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	# 10 m cells; only the player's own cell is active, one ring is kept in
	# memory, a cell is released half a second after nobody wants it.
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


func after_each() -> void:
	GameLogger.set_capture(false)


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.zombie.wander_pause_min_sec = NEVER
	config.zombie.wander_pause_max_sec = NEVER
	# A zombie in these tests only stands somewhere: it senses nobody.
	config.zombie.sight_range_m = 0.0
	config.zombie.hearing_multiplier = 0.0
	config.catalog = ConstructionTestKit.items()
	config.structures = ConstructionTestKit.structures()
	config.building = BuildingSettings.new()
	config.world_cells = _cell_settings
	return config


func _world(store: WorldCellStore = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	return world


func _seeded(store: WorldCellStore = null) -> ServerWorld:
	var world: ServerWorld = _world(store)
	world.seed_new_world(DevWorldSeed.new())
	return world


func _building(world: ServerWorld) -> BuildingService:
	return world.get_system(BuildingService.SYSTEM_ID) as BuildingService


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _move(world: ServerWorld, player: PlayerState, position: Vector3, seconds: float = TICK) -> void:
	player.position = position
	_run(world, seconds)


func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int) -> void:
	if not ConstructionTestKit.give(world, player, definition_id, quantity):
		fail("test setup: could not give %d %s" % [quantity, definition_id])


func _place(world: ServerWorld, player: PlayerState, definition_id: String, rotation: int = EAST, tile: Vector2i = SPAWN_TILE) -> String:
	var placed: ActionResult = _building(world).try_place(world, player.player_id, definition_id, tile, rotation)
	if not placed.ok:
		fail("test setup: %s was not placed: %s" % [definition_id, placed.reason])
	return str(placed.event.get(BuildingService.KEY_STRUCTURE_ID, ""))


## Save data of every structure in memory, by id.
func _saved(world: ServerWorld) -> Dictionary:
	var service: BuildingService = _building(world)
	var result: Dictionary = {}
	for structure_id: String in service.structure_ids():
		result[structure_id] = service.get_structure(structure_id).to_dict()
	return result


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


## Equal, except that numbers may differ by what a JSON round trip of a
## float loses (a save is text).
func _same(a: Variant, b: Variant) -> bool:
	if (typeof(a) == TYPE_FLOAT or typeof(a) == TYPE_INT) and (typeof(b) == TYPE_FLOAT or typeof(b) == TYPE_INT):
		return absf(float(a) - float(b)) <= TOLERANCE
	if typeof(a) != typeof(b):
		return false
	if typeof(a) == TYPE_ARRAY:
		if (a as Array).size() != (b as Array).size():
			return false
		for index: int in range((a as Array).size()):
			if not _same(a[index], b[index]):
				return false
		return true
	if typeof(a) == TYPE_DICTIONARY:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for key: Variant in (a as Dictionary):
			if not (b as Dictionary).has(key) or not _same(a[key], b[key]):
				return false
		return true
	return a == b


## A structure entry exactly as P3-4a wrote it (building document schema 1:
## no construction fields).
func _p3_4a_entry(structure_id: String, definition_id: String, tile: Vector2i, rotation: int, state: String, health: float) -> Dictionary:
	return {
		"structure_id": structure_id, "definition_id": definition_id, "owner_shelter_id": "", "cell_id": "cell_0_0",
		"transform": {"tile": [tile.x, tile.y], "rotation": rotation}, "construction_state": state, "health": health,
		"material_quality": 1.0, "inventory_costs": {}, "connections": [], "last_modified_at": 12.5, "placed_by": "player_000001", "door_open": false,
	}


## A valid saved structure in the middle of its construction, for tests that
## then break one field.
func _entry(structure_id: String, tile: Vector2i) -> Dictionary:
	var structure: StructureInstance = StructureInstance.new()
	structure.structure_id = structure_id
	structure.definition_id = WALL
	structure.tile = tile
	structure.rotation = NORTH
	structure.construction_state = StructureInstance.State.CONSTRUCTING
	structure.inventory_costs = {PLANK: 4, NAIL: 2}
	structure.delivered_materials = {PLANK: 3}
	structure.construction_progress = 0.25
	structure.cell_id = "cell_0_0"
	return _json(structure.to_dict())


func _document(structures: Array, version: int = BuildingService.CELL_SCHEMA_VERSION) -> Dictionary:
	return {"schema_version": version, BuildingService.KEY_STRUCTURES: structures}


# ------------------------------------------------------------ one structure

func test_the_construction_of_a_structure_is_in_its_save_and_bad_data_is_refused() -> void:
	var structure: StructureInstance = StructureInstance.new()
	structure.structure_id = "structure_000042"
	structure.definition_id = WALL
	structure.cell_id = "cell_0_0"
	structure.tile = Vector2i(-7, 3)
	structure.rotation = 2
	structure.construction_state = StructureInstance.State.CONSTRUCTING
	structure.inventory_costs = {PLANK: 4, NAIL: 2}
	structure.delivered_materials = {PLANK: 4, NAIL: 1}
	structure.construction_progress = 0.625
	structure.placed_by = "player_000003"
	var saved: Dictionary = structure.to_dict()
	assert_eq(saved["construction_progress"], 0.625)
	assert_eq(saved["delivered_materials"], {PLANK: 4, NAIL: 1})
	assert_eq(saved["inventory_costs"], {PLANK: 4, NAIL: 2})
	assert_eq(saved["construction_state"], "constructing")
	assert_true(SaveService.is_json_safe(saved), "no Node, RID or Object in a save")
	assert_false(saved.has("workers"), "who is working is not saved")
	var back: StructureInstance = StructureInstance.from_dict(_json(saved))
	assert_not_null(back)
	assert_eq(back.to_dict(), saved)
	assert_true(_same(back.material_share(), 5.0 / 6.0))
	var one_nail: Dictionary[String, int] = {NAIL: 1}
	assert_eq(back.missing_materials(), one_nail)
	assert_true(back.is_under_construction())
	# One broken field at a time.
	var broken: Dictionary = {
		"construction_progress": [-0.1, 1.5, NAN, INF, "half", null],
		"delivered_materials": [null, [], "planks", {PLANK: 0}, {PLANK: -1}, {PLANK: 5}, {PLANK: 1.5}, {"dev_test_item": 1}, {7: 1}, {PLANK: "two"}],
	}
	for key: String in broken:
		for value: Variant in broken[key]:
			var data: Dictionary = saved.duplicate(true)
			data[key] = value
			assert_null(StructureInstance.from_dict(data), "bad %s: %s" % [key, str(value)])
		var missing: Dictionary = saved.duplicate(true)
		missing.erase(key)
		assert_null(StructureInstance.from_dict(missing), "missing " + key)


# ------------------------------------------------------------ P3-4a saves

func test_documents_written_before_construction_existed_are_upgraded() -> void:
	var wall: Dictionary = _p3_4a_entry("structure_000011", FREE_WALL, Vector2i(3, 3), NORTH, "completed", 100.0)
	var damaged: Dictionary = _p3_4a_entry("structure_000012", FREE_WALL, Vector2i(4, 3), NORTH, "damaged", 40.0)
	var blueprint: Dictionary = _p3_4a_entry("structure_000013", FREE_WALL, Vector2i(6, 3), NORTH, "blueprint", 0.0)
	# The rule by itself.
	var upgraded: Dictionary = StructureInstance.upgrade_v1_entry(wall)
	assert_eq(upgraded["construction_progress"], 1.0, "P3-4a built a piece at once")
	assert_eq(upgraded["delivered_materials"], {}, "and nothing was paid for it")
	assert_false(wall.has("construction_progress"), "the saved entry itself is not changed")
	assert_eq(StructureInstance.upgrade_v1_entry(blueprint)["construction_progress"], 0.0)
	assert_null(StructureInstance.from_dict(wall), "the entry as P3-4a wrote it is not the current shape")
	assert_not_null(StructureInstance.from_dict(upgraded))
	assert_eq(StructureInstance.upgrade_v1_entry(upgraded), upgraded, "upgrading twice changes nothing")

	# A cell document of schema 1.
	var world: ServerWorld = _seeded()
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	var errors: PackedStringArray = service.restore_cell_document(world, "cell_0_0", _document([wall, damaged, blueprint], BuildingService.SCHEMA_VERSION_P3_4A))
	assert_eq(errors.size(), 0, "; ".join(errors))
	assert_eq(service.structure_count(), 3)
	var restored: StructureInstance = service.get_structure("structure_000011")
	assert_eq(restored.construction_state, StructureInstance.State.COMPLETED)
	assert_eq(restored.construction_progress, 1.0)
	assert_eq(restored.delivered_materials.size(), 0)
	assert_eq(restored.health, 100.0)
	assert_eq(restored.placed_by, "player_000001")
	assert_true(service.is_edge_blocked(Vector3i(3, 3, StructureGrid.Layer.EDGE_LOW_Z)), "the old wall blocks as before")
	assert_eq(service.get_structure("structure_000012").construction_state, StructureInstance.State.DAMAGED)
	assert_eq(service.get_structure("structure_000012").construction_progress, 1.0)
	assert_eq(service.get_structure("structure_000013").construction_state, StructureInstance.State.BLUEPRINT)
	assert_eq(service.get_structure("structure_000013").construction_progress, 0.0)
	# The old blueprint can be built now.
	alice.position = Vector3(6.5, 0.0, 3.5)
	assert_true(service.try_set_work(world, alice.player_id, "structure_000013", true).ok)
	_run(world, WALL_WORK_SEC + 0.5)
	assert_eq(service.get_structure("structure_000013").construction_state, StructureInstance.State.COMPLETED)
	# It is written back in the current schema.
	var rewritten: Dictionary = _json(service.to_cell_document("cell_0_0"))
	assert_eq(int(rewritten["schema_version"]), 2)
	assert_eq(BuildingService.CELL_SCHEMA_VERSION, 2)
	assert_eq(BuildingService.SCHEMA_VERSION, 2)
	for entry: Dictionary in rewritten[BuildingService.KEY_STRUCTURES]:
		assert_true(entry.has("construction_progress") and entry.has("delivered_materials"), str(entry["structure_id"]))

	# A world document of schema 1 (a world without a saved cell store).
	var other: ServerWorld = _seeded()
	assert_eq(_building(other).restore_world_document(_document([wall], BuildingService.SCHEMA_VERSION_P3_4A)).size(), 0)
	assert_eq(_building(other).get_structure("structure_000011").construction_progress, 1.0)
	# Schema 1 never had the new fields half filled in, and an unknown
	# schema is refused.
	assert_true(_building(_seeded()).restore_cell_document(world, "cell_0_0", _document([wall], 3)).size() > 0)
	assert_true(_building(_seeded()).restore_cell_document(world, "cell_0_0", _document([wall], 0)).size() > 0)
	# A current document must have the fields: no silent upgrade.
	var strict: ServerWorld = _seeded()
	assert_true(_building(strict).restore_cell_document(strict, "cell_0_0", _document([wall])).size() > 0, "a schema 2 document without the fields is broken")
	assert_eq(_building(strict).structure_count(), 0)


# ------------------------------------------------------------ cells

func test_a_cell_released_in_the_middle_of_a_construction_comes_back_as_it_was() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _seeded(store)
	var service: BuildingService = _building(world)
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var alice: PlayerState = world.join("alice")
	_run(world, 1.0)
	_give(world, alice, PLANK, 10)
	_give(world, alice, NAIL, 5)
	# A blueprint with a part of its materials; a wall half built; a wall
	# whose work is done but that waits for the zombie standing in its edge.
	var blueprint_id: String = _place(world, alice, FLOOR)
	assert_true(service.try_deliver(world, alice.player_id, blueprint_id, ConstructionTestKit.stacks(world, alice, PLANK)[0], 1).ok)
	var half_id: String = _place(world, alice, WALL, EAST)
	assert_true(service.try_deliver(world, alice.player_id, half_id).ok)
	assert_true(service.try_set_work(world, alice.player_id, half_id, true).ok)
	_run(world, 5.0)
	var zombie_id: String = str(zombies.spawn_zombie(world, Vector3(4.9, 0.0, 5.5), 0.0).event["zombie_id"])
	var waiting_id: String = _place(world, alice, FREE_WALL, WEST)
	assert_true(service.try_set_work(world, alice.player_id, waiting_id, true).ok, "she switches to the west wall")
	_run(world, WALL_WORK_SEC + 0.5)
	assert_eq(service.awaiting_clearance_count(), 1)
	assert_true(service.try_set_work(world, alice.player_id, half_id, true).ok, "and back")
	_run(world, 1.0)
	service.drain_events()
	var progress: float = service.get_structure(half_id).construction_progress
	assert_true(progress > 0.55 and progress < 0.7, "about six seconds of ten: %f" % progress)
	var planks_before: int = ConstructionTestKit.total(world, [alice], PLANK)

	# She walks away while working: the cell is saved and released.
	_move(world, alice, AWAY, 2.0)
	assert_eq(_cells(world).state_of("cell_0_0"), WorldCellLifecycle.State.UNLOADED)
	assert_eq(service.structure_count(), 0)
	assert_eq(service.worker_count(), 0, "nobody works on what is not in memory")
	assert_eq(service.awaiting_clearance_count(), 0)
	var stops: Array[Dictionary] = []
	for event: Dictionary in service.drain_events():
		if event["event_type"] == BuildingService.EVENT_WORK_STOPPED:
			stops.append(event)
	assert_eq(stops.size(), 1)
	assert_eq(stops[0]["reason"], BuildingService.REASON_TOO_FAR, "she stopped by walking away, before the cell left")
	var before: Dictionary = {}
	var saved_part: Dictionary = (store.document_of("cell_0_0")["systems"] as Dictionary)[BuildingService.SYSTEM_ID]
	assert_eq(int(saved_part["schema_version"]), BuildingService.CELL_SCHEMA_VERSION)
	for entry: Dictionary in saved_part[BuildingService.KEY_STRUCTURES]:
		before[str(entry["structure_id"])] = entry
	assert_eq(before.size(), 3)
	assert_eq(before[half_id]["construction_state"], "constructing")
	assert_eq(before[half_id]["delivered_materials"], {PLANK: 4.0, NAIL: 2.0})
	assert_true(_same(before[half_id]["construction_progress"], progress), "saved with the progress it had when she left")
	assert_eq(before[blueprint_id]["delivered_materials"], {PLANK: 1.0})
	assert_eq(before[waiting_id]["construction_progress"], 1.0)
	assert_eq(before[waiting_id]["construction_state"], "constructing")
	assert_true(SaveService.is_json_safe(store.document_of("cell_0_0")))
	assert_eq(service.try_deliver(world, alice.player_id, half_id).reason, BuildingService.REASON_UNKNOWN_STRUCTURE, "a released structure cannot be acted on")

	# She comes back: everything is as it was, and nobody is working.
	_move(world, alice, SPAWN, 0.2)
	assert_eq(_cells(world).state_of("cell_0_0"), WorldCellLifecycle.State.ACTIVE)
	assert_true(_same(_saved(world), before), "the same structures: before %s, after %s" % [str(before), str(_saved(world))])
	assert_eq(service.worker_count(), 0, "after a reload nobody works; the progress stays")
	assert_eq(service.awaiting_clearance_count(), 1, "the finished wall still waits for its edge")
	assert_false(service.is_edge_blocked(Vector3i(6, 5, LOW_X)))
	assert_eq(ConstructionTestKit.total(world, [alice], PLANK), planks_before, "no material was created or lost")
	assert_eq(service.drain_events().size(), 0, "a reload records nothing")
	# The construction goes on where it stopped.
	var resumed: float = service.get_structure(half_id).construction_progress
	assert_true(service.try_set_work(world, alice.player_id, half_id, true).ok)
	_run(world, 1.0)
	assert_true(_same(service.get_structure(half_id).construction_progress, resumed + 1.0 / WALL_WORK_SEC), "resumed, not restarted")
	_run(world, WALL_WORK_SEC)
	assert_eq(service.get_structure(half_id).construction_state, StructureInstance.State.COMPLETED)
	assert_true(service.is_edge_blocked(Vector3i(6, 5, LOW_X)))
	assert_true(service.try_deliver(world, alice.player_id, blueprint_id).ok, "the blueprint takes the rest of its materials")
	assert_eq(service.get_structure(blueprint_id).delivered_materials[PLANK], 2)
	# The waiting wall completes once the zombie is gone.
	assert_eq(service.get_structure(waiting_id).construction_state, StructureInstance.State.CONSTRUCTING)
	assert_true(zombies.apply_damage_to_zombie(zombie_id, LETHAL_DAMAGE, "test_source").ok)
	_run(world, 0.5)
	assert_eq(service.get_structure(waiting_id).construction_state, StructureInstance.State.COMPLETED)
	# A second release and reload keeps the completed state.
	_move(world, alice, AWAY, 2.0)
	_move(world, alice, SPAWN, 0.2)
	assert_eq(service.get_structure(half_id).construction_state, StructureInstance.State.COMPLETED)
	assert_eq(service.get_structure(half_id).delivered_materials[PLANK], 4)
	assert_true(service.is_edge_blocked(Vector3i(6, 5, LOW_X)))


# ------------------------------------------------------------ world documents

func test_world_documents_round_trip_a_construction() -> void:
	for with_store: bool in [true, false]:
		var world: ServerWorld = _seeded(WorldCellStore.new() if with_store else null)
		var service: BuildingService = _building(world)
		var alice: PlayerState = world.join("alice")
		_give(world, alice, PLANK, 6)
		_give(world, alice, NAIL, 2)
		var wall_id: String = _place(world, alice, WALL)
		assert_true(service.try_deliver(world, alice.player_id, wall_id).ok)
		assert_true(service.try_set_work(world, alice.player_id, wall_id, true).ok)
		_run(world, 3.0)
		var floor_id: String = _place(world, alice, FLOOR)
		var documents: Dictionary = world.to_documents()
		assert_true(SaveService.is_json_safe(documents["world_state"]))
		var part: Dictionary = (documents["world_state"]["systems"] as Dictionary)[BuildingService.SYSTEM_ID]
		assert_eq(part["schema_version"], BuildingService.SCHEMA_VERSION)
		assert_eq((part[BuildingService.KEY_STRUCTURES] as Array).size(), 2)

		var restored: ServerWorld = _world(WorldCellStore.new() if with_store else null)
		var errors: PackedStringArray = restored.restore_documents(_json(documents["world_state"]), _json(documents["players"]), _json(documents["cells"]))
		assert_eq(errors.size(), 0, "; ".join(errors))
		var service2: BuildingService = _building(restored)
		assert_true(_same(_saved(restored), _saved(world)), "the same structures, with their materials and progress")
		var wall: StructureInstance = service2.get_structure(wall_id)
		assert_eq(wall.construction_state, StructureInstance.State.CONSTRUCTING)
		assert_true(_same(wall.construction_progress, 0.3))
		var all: Dictionary[String, int] = {PLANK: 4, NAIL: 2}
		assert_eq(wall.delivered_materials, all)
		assert_eq(service2.get_structure(floor_id).construction_state, StructureInstance.State.BLUEPRINT)
		assert_eq(service2.worker_count(), 0, "who was working is not in the save")
		# The inventory the materials left is in the same documents: the two
		# planks alice kept, and none of the four in the wall.
		var player: PlayerState = restored.join("alice")
		assert_eq(ConstructionTestKit.carried(restored, player, PLANK), 2)
		assert_eq(ConstructionTestKit.carried(restored, player, NAIL), 0)
		assert_eq(ConstructionTestKit.total(restored, [player], PLANK), ConstructionTestKit.total(world, [alice], PLANK))
		# And the restored world builds on.
		assert_true(service2.try_set_work(restored, player.player_id, wall_id, true).ok)
		_run(restored, 8.0)
		assert_eq(service2.get_structure(wall_id).construction_state, StructureInstance.State.COMPLETED)


# ------------------------------------------------------------ restore validation

func test_a_restore_refuses_a_construction_whose_fields_disagree() -> void:
	var world: ServerWorld = _seeded()
	var service: BuildingService = _building(world)
	world.join("alice")
	var good: Dictionary = _entry("structure_000101", Vector2i(3, 3))
	var cases: Dictionary[String, Dictionary] = {}
	var worked_blueprint: Dictionary = _entry("structure_000102", Vector2i(4, 3))
	worked_blueprint["construction_state"] = "blueprint"
	cases["a blueprint with work done"] = worked_blueprint
	var idle_construction: Dictionary = _entry("structure_000103", Vector2i(4, 3))
	idle_construction["construction_progress"] = 0.0
	cases["a construction without any work"] = idle_construction
	var ahead: Dictionary = _entry("structure_000104", Vector2i(4, 3))
	ahead["construction_progress"] = 0.75
	cases["more progress than materials (3 of 6 delivered)"] = ahead
	var unfinished_wall: Dictionary = _entry("structure_000105", Vector2i(4, 3))
	unfinished_wall["construction_state"] = "completed"
	cases["a completed piece that is not finished"] = unfinished_wall
	var too_much: Dictionary = _entry("structure_000106", Vector2i(4, 3))
	too_much["delivered_materials"] = {PLANK: 9}
	cases["more delivered than needed"] = too_much
	var wrong_kind: Dictionary = _entry("structure_000107", Vector2i(4, 3))
	wrong_kind["delivered_materials"] = {"dev_test_item": 1}
	cases["a material the piece does not need"] = wrong_kind
	for case_name: String in cases:
		var errors: PackedStringArray = service.restore_cell_document(world, "cell_0_0", _document([good, cases[case_name]]))
		assert_true(errors.size() > 0, case_name + " is refused")
		assert_eq(service.structure_count(), 0, case_name + ": nothing was restored, not even the valid entry")
	# The valid entry alone restores, at the cap of its materials.
	var at_cap: Dictionary = _entry("structure_000108", Vector2i(4, 3))
	at_cap["construction_progress"] = 0.5
	assert_eq(service.restore_cell_document(world, "cell_0_0", _document([good, at_cap])).size(), 0)
	assert_eq(service.structure_count(), 2)
	assert_eq(service.get_structure("structure_000108").construction_progress, 0.5)
