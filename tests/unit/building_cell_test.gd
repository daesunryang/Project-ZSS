extends TestCase
## P3-4a: structures and world cells (docs/09 §15.1, §15.4): every structure
## is indexed in the cell of its slot, is saved in that cell's document,
## leaves memory with the cell and comes back identical. Also the world
## document (worlds without a saved cell store), restore validation, a
## changed cell grid, and the save format of one structure. Real files:
## tests/integration/building_persistence_test.gd.

const WORLD: String = "building_cell_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const TOLERANCE: float = 0.000001
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const FAR: Vector3 = Vector3(45.5, 0.0, 45.5)
const FLOOR: String = "dev_floor"
const WALL: String = "dev_wall"
const DOOR: String = "dev_door"
const LOW_X: int = StructureGrid.Layer.EDGE_LOW_X
const LOW_Z: int = StructureGrid.Layer.EDGE_LOW_Z
const KIND: String = BuildingService.ENTITY_KIND_STRUCTURE

var _cell_settings: WorldCellSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	# 10 m cells on a 100 m map. Only the player's own cell is active, one
	# ring is kept in memory, a cell is released half a second after nobody
	# wants it.
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
	config.building = BuildingSettings.new()
	# These tests are about standing pieces (P3-4a): the dev switch is on.
	# Cells and saves of pieces under construction: building_construction_save_test.gd.
	config.building.instant_completion = true
	config.world_cells = _cell_settings
	return config


func _world(store: WorldCellStore = null, config: CompositionConfig = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, config if config != null else _config())
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


func _place(world: ServerWorld, definition_id: String, tile: Vector2i, rotation: int, placed_by: String = "") -> String:
	var result: ActionResult = _building(world).place_structure(world, definition_id, tile, rotation, placed_by)
	if not result.ok:
		fail("test setup: %s at %s was refused: %s" % [definition_id, str(tile), result.reason])
	return str(result.event.get(BuildingService.KEY_STRUCTURE_ID, ""))


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


func _building_cell_document(structures: Array) -> Dictionary:
	return {"schema_version": BuildingService.CELL_SCHEMA_VERSION, BuildingService.KEY_STRUCTURES: structures}


## A valid saved structure, for tests that then break one field.
func _entry(structure_id: String, definition_id: String, tile: Vector2i, rotation: int) -> Dictionary:
	var structure: StructureInstance = StructureInstance.new()
	structure.structure_id = structure_id
	structure.definition_id = definition_id
	structure.tile = tile
	structure.rotation = rotation
	structure.construction_state = StructureInstance.State.COMPLETED
	structure.construction_progress = StructureInstance.FULL_PROGRESS
	structure.health = 50.0
	structure.cell_id = "cell_0_0"
	return _json(structure.to_dict())


# ------------------------------------------------------------ cell index

func test_a_structure_is_indexed_in_the_cell_of_its_slot() -> void:
	var world: ServerWorld = _seeded()
	var service: BuildingService = _building(world)
	world.join("alice")
	var floor_id: String = _place(world, FLOOR, Vector2i(5, 5), 0)
	var inner_wall: String = _place(world, WALL, Vector2i(5, 0), 0)
	# The edge x = 10 is the border between cell (0, 0) and cell (1, 0): it
	# belongs to the cell on its high side, from whichever tile it was placed.
	var border_wall: String = _place(world, WALL, Vector2i(9, 5), 1)
	var border_door: String = _place(world, DOOR, Vector2i(10, 6), 3)
	var north_wall: String = _place(world, WALL, Vector2i(5, 9), 2)
	assert_eq(world.cell_index.entities_in_cell("cell_0_0", KIND), PackedStringArray([floor_id, inner_wall]))
	assert_eq(world.cell_index.entities_in_cell("cell_1_0", KIND), PackedStringArray([border_wall, border_door]))
	assert_eq(world.cell_index.entities_in_cell("cell_0_1", KIND), PackedStringArray([north_wall]))
	for structure_id: String in service.structure_ids():
		assert_eq(service.get_structure(structure_id).cell_id, world.cell_index.cell_of(structure_id), structure_id)
		assert_eq(world.cell_index.kind_of(structure_id), KIND)
	assert_eq(service.structure_ids_in_cell(world, "cell_1_0"), PackedStringArray([border_wall, border_door]))
	assert_eq(service.rows_in_cell(world, "cell_0_1").size(), 1)
	assert_eq(service.rows_in_cell(world, "cell_0_1")[0]["structure_id"], north_wall)
	# The same border edge from the other cell's tile is the same slot.
	assert_eq(service.place_structure(world, WALL, Vector2i(10, 5), 3).reason, BuildingService.REASON_SLOT_OCCUPIED)
	# Removal takes the structure out of the index.
	assert_true(service.remove_structure(world, border_wall).ok)
	assert_eq(world.cell_index.entities_in_cell("cell_1_0", KIND), PackedStringArray([border_door]))
	# Other kinds in the same cell are not touched.
	var item_id: String = world.inventory.spawn_world_item("dev_test_item", 1, "cell_0_0", Vector3(5.0, 0.0, 5.0))
	assert_eq(world.cell_index.entities_in_cell("cell_0_0", KIND).size(), 2)
	assert_true(world.cell_index.entities_in_cell("cell_0_0").has(item_id))


# ------------------------------------------------------------ release and reload

func test_a_released_cell_takes_its_structures_out_of_memory_and_brings_them_back_identical() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _seeded(store)
	var service: BuildingService = _building(world)
	var alice: PlayerState = world.join("alice")
	_run(world, 3.0)
	var floor_id: String = _place(world, FLOOR, Vector2i(2, 2), 3, alice.player_id)
	var wall_id: String = _place(world, WALL, Vector2i(7, 5), 1, alice.player_id)
	var open_door: String = _place(world, DOOR, Vector2i(7, 6), 1)
	var closed_door: String = _place(world, DOOR, Vector2i(7, 7), 1, alice.player_id)
	assert_true(service.set_door_open(world, open_door, true).ok)
	# A cell that stays in memory the whole time.
	var staying: String = _place(world, WALL, Vector2i(5, 12), 0)
	service.drain_events()
	var before: Dictionary = _saved(world)
	assert_eq(before.size(), 5)
	var next_id_before: int = world.ids.get_next_sequence()

	# The player walks away: cell (0, 0) is saved and released.
	_move(world, alice, Vector3(5.5, 0.0, 25.5), 2.0)
	assert_eq(_cells(world).state_of("cell_0_0"), WorldCellLifecycle.State.UNLOADED)
	assert_eq(service.structure_ids(), PackedStringArray([staying]), "only the structure of the cell that is still in memory")
	for structure_id: String in [floor_id, wall_id, open_door, closed_door]:
		assert_false(service.has_structure(structure_id))
		assert_false(world.registry.has(structure_id), "released, " + structure_id)
		assert_false(world.registry.is_tombstoned(structure_id), "not retired: it still exists")
		assert_false(world.cell_index.has(structure_id))
	assert_eq(service.blocking_edge_count(), 1, "the released walls block nothing while they are not in memory")
	assert_eq(service.structure_id_at(Vector3i(8, 5, LOW_X)), "")
	assert_eq(service.drain_events().size(), 0, "nothing was built or demolished: no event")
	var document: Dictionary = store.document_of("cell_0_0")
	var saved_part: Dictionary = (document.get("systems", {}) as Dictionary).get(BuildingService.SYSTEM_ID, {})
	assert_eq((saved_part.get(BuildingService.KEY_STRUCTURES, []) as Array).size(), 4, "they are in the cell's document")
	assert_eq(int(saved_part.get("schema_version", 0)), BuildingService.CELL_SCHEMA_VERSION)
	assert_true(SaveService.is_json_safe(document))
	# A released structure cannot be acted on.
	assert_eq(service.try_demolish(world, alice.player_id, wall_id).reason, BuildingService.REASON_UNKNOWN_STRUCTURE)

	# The player comes back: the cell is loaded with the same structures.
	_move(world, alice, SPAWN, 0.5)
	assert_eq(_cells(world).state_of("cell_0_0"), WorldCellLifecycle.State.ACTIVE)
	assert_true(_same(_saved(world), before), "every structure is back exactly as it was: before %s, after %s" % [str(before), str(_saved(world))])
	assert_eq(world.registry.kind_of(wall_id), KIND)
	assert_eq(world.cell_index.cell_of(wall_id), "cell_0_0")
	assert_true(service.is_edge_blocked(Vector3i(8, 5, LOW_X)), "the wall blocks again")
	assert_true(service.is_edge_blocked(Vector3i(8, 7, LOW_X)), "and the closed door")
	assert_false(service.is_edge_blocked(Vector3i(8, 6, LOW_X)), "the open door is still open")
	assert_eq(service.structure_id_at(Vector3i(2, 2, StructureGrid.Layer.TILE)), floor_id)
	assert_eq(world.ids.get_next_sequence(), next_id_before, "loading a cell makes no new id")
	assert_eq(service.drain_events().size(), 0)
	# The slot of a restored structure is taken; a new structure gets a new id.
	assert_eq(service.place_structure(world, DOOR, Vector2i(8, 5), 3).reason, BuildingService.REASON_SLOT_OCCUPIED)
	var fresh: String = _place(world, FLOOR, Vector2i(3, 3), 0)
	assert_false(before.has(fresh))
	# The placer may still demolish what it placed before the cell left memory.
	assert_true(service.try_demolish(world, alice.player_id, wall_id).ok)
	# And a second release / reload does not bring the demolished wall back.
	_move(world, alice, Vector3(5.5, 0.0, 25.5), 2.0)
	_move(world, alice, SPAWN, 0.5)
	assert_false(service.has_structure(wall_id))
	assert_true(world.registry.is_tombstoned(wall_id))
	assert_true(service.has_structure(fresh) and service.has_structure(closed_door))


func test_a_cell_without_structures_saves_no_building_document() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _seeded(store)
	var alice: PlayerState = world.join("alice")
	assert_eq(_building(world).to_cell_document("cell_0_0"), {})
	assert_eq(_building(world).to_world_document(), {})
	world.inventory.spawn_world_item("dev_test_item", 1, "cell_0_0", Vector3(5.0, 0.0, 5.0))
	_move(world, alice, Vector3(5.5, 0.0, 25.5), 2.0)
	assert_false((store.document_of("cell_0_0")["systems"] as Dictionary).has(BuildingService.SYSTEM_ID), "a cell document from before structures looks the same")
	_move(world, alice, SPAWN, 0.5)
	assert_eq(_cells(world).state_of("cell_0_0"), WorldCellLifecycle.State.ACTIVE, "and loads")


# ------------------------------------------------------------ world documents

func test_world_documents_round_trip_structures_in_memory_and_in_released_cells() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _seeded(store)
	var alice: PlayerState = world.join("alice")
	var near_wall: String = _place(world, WALL, Vector2i(7, 5), 1, alice.player_id)
	var near_door: String = _place(world, DOOR, Vector2i(7, 6), 1)
	assert_true(_building(world).set_door_open(world, near_door, true).ok)
	_move(world, alice, FAR, 2.0)
	var far_floor: String = _place(world, FLOOR, Vector2i(45, 45), 2)
	assert_false(_building(world).has_structure(near_wall), "cell (0, 0) was released")
	var documents: Dictionary = world.to_documents()
	# With a memory store the world document holds what is in memory and the
	# cell documents hold the released cells.
	var in_world: Array = ((documents["world_state"]["systems"] as Dictionary)[BuildingService.SYSTEM_ID] as Dictionary)[BuildingService.KEY_STRUCTURES]
	assert_eq(in_world.size(), 1)
	assert_eq(in_world[0]["structure_id"], far_floor)
	assert_true((documents["cells"] as Dictionary).has("cell_0_0"))
	assert_true(SaveService.is_json_safe(documents["world_state"]))

	var restored: ServerWorld = _world(WorldCellStore.new())
	var errors: PackedStringArray = restored.restore_documents(_json(documents["world_state"]), _json(documents["players"]), _json(documents["cells"]))
	assert_eq(errors.size(), 0, "; ".join(errors))
	var service: BuildingService = _building(restored)
	assert_eq(service.structure_ids(), PackedStringArray([far_floor]), "the structure that was in memory")
	assert_true(_same(service.get_structure(far_floor).to_dict(), _building(world).get_structure(far_floor).to_dict()), "the same structure")
	assert_eq(restored.cell_index.cell_of(far_floor), "cell_4_4")
	# The released cell comes back when somebody goes there.
	var player: PlayerState = restored.join("alice")
	_move(restored, player, SPAWN, 0.5)
	assert_true(service.has_structure(near_wall) and service.has_structure(near_door))
	assert_true(service.get_structure(near_door).door_open)
	assert_eq(service.get_structure(near_wall).placed_by, alice.player_id)
	assert_true(service.is_edge_blocked(Vector3i(8, 5, LOW_X)))
	assert_eq(restored.ids.get_next_sequence(), world.ids.get_next_sequence(), "no id of a saved structure can be handed out again")


func test_a_world_without_a_cell_store_saves_structures_in_the_world_document() -> void:
	var world: ServerWorld = _seeded()
	world.join("alice")
	var wall_id: String = _place(world, WALL, Vector2i(7, 5), 1)
	var documents: Dictionary = world.to_documents()
	assert_eq((documents["cells"] as Dictionary).size(), 0)
	var restored: ServerWorld = _world()
	assert_eq(restored.restore_documents(_json(documents["world_state"]), _json(documents["players"])).size(), 0)
	assert_true(_same(_saved(restored), _saved(world)), "the same structures")
	assert_true(_building(restored).is_edge_blocked(Vector3i(8, 5, LOW_X)))
	assert_eq(restored.registry.kind_of(wall_id), KIND)
	# A save from before structures existed has no building document at all.
	var old_world: ServerWorld = _seeded()
	old_world.join("alice")
	var old_documents: Dictionary = old_world.to_documents()
	assert_false((old_documents["world_state"]["systems"] as Dictionary).has(BuildingService.SYSTEM_ID), "no structures: no key, as in an older save")
	var from_old: ServerWorld = _world()
	assert_eq(from_old.restore_documents(_json(old_documents["world_state"]), _json(old_documents["players"])).size(), 0, "an older save loads")
	assert_eq(_building(from_old).structure_count(), 0)
	# A world document whose structure is known already is refused as a whole.
	var twice: PackedStringArray = _building(restored).restore_world_document(_json(documents["world_state"]["systems"][BuildingService.SYSTEM_ID]))
	assert_true(twice.size() > 0, "a world document is strict about ids it already has")
	assert_eq(_building(restored).structure_count(), 1)


# ------------------------------------------------------------ restore validation

func test_a_cell_document_is_validated_before_anything_changes() -> void:
	var world: ServerWorld = _seeded()
	var service: BuildingService = _building(world)
	world.join("alice")
	var good: Dictionary = _entry("structure_000101", WALL, Vector2i(3, 3), 0)
	var cases: Dictionary[String, Dictionary] = {}
	cases["wrong version"] = {"schema_version": 99, BuildingService.KEY_STRUCTURES: [good]}
	cases["no list"] = {"schema_version": BuildingService.CELL_SCHEMA_VERSION, BuildingService.KEY_STRUCTURES: "x"}
	cases["entry is no object"] = _building_cell_document([good, 7])
	var unknown_definition: Dictionary = _entry("structure_000102", "removed_definition", Vector2i(4, 3), 0)
	cases["unknown definition"] = _building_cell_document([good, unknown_definition])
	var too_healthy: Dictionary = _entry("structure_000103", WALL, Vector2i(4, 3), 0)
	too_healthy["health"] = 100000.0
	cases["health above the definition"] = _building_cell_document([good, too_healthy])
	var open_wall: Dictionary = _entry("structure_000104", WALL, Vector2i(4, 3), 0)
	open_wall["door_open"] = true
	cases["a wall that is open"] = _building_cell_document([good, open_wall])
	cases["the same id twice"] = _building_cell_document([good, _entry("structure_000101", WALL, Vector2i(4, 3), 0)])
	# Tile (3, 2) rotation 2 is the same edge as tile (3, 3) rotation 0.
	cases["the same slot twice"] = _building_cell_document([good, _entry("structure_000105", DOOR, Vector2i(3, 2), 2)])
	var bad_state: Dictionary = _entry("structure_000106", WALL, Vector2i(4, 3), 0)
	bad_state["construction_state"] = "floating"
	cases["unknown state"] = _building_cell_document([good, bad_state])
	for case_name: String in cases:
		var errors: PackedStringArray = service.restore_cell_document(world, "cell_0_0", cases[case_name])
		assert_true(errors.size() > 0, case_name + " is refused")
		assert_eq(service.structure_count(), 0, case_name + ": nothing was restored, not even the valid entry")
		assert_false(world.registry.has("structure_000101"), case_name)
	# Through the world: a broken building document keeps the cell unloaded
	# parts apart, and the valid document restores.
	assert_true(world.restore_cell_document("cell_0_0", WorldCellDocument.create("cell_0_0", {}, {BuildingService.SYSTEM_ID: cases["unknown definition"]})).size() > 0)
	assert_eq(world.restore_cell_document("cell_0_0", WorldCellDocument.create("cell_0_0", {}, {BuildingService.SYSTEM_ID: _building_cell_document([good])})).size(), 0)
	assert_eq(service.structure_ids(), PackedStringArray(["structure_000101"]))
	assert_true(world.ids.get_next_sequence() > 101, "a restored id is reserved")


func test_a_cell_document_never_doubles_or_resurrects_a_structure() -> void:
	var world: ServerWorld = _seeded()
	var service: BuildingService = _building(world)
	world.join("alice")
	var kept: String = _place(world, WALL, Vector2i(3, 3), 0)
	var demolished: String = _place(world, WALL, Vector2i(4, 3), 0)
	var saved: Dictionary = _json(service.to_cell_document("cell_0_0"))
	assert_true(service.remove_structure(world, demolished).ok)
	assert_true(service.set_door_open(world, _place(world, DOOR, Vector2i(5, 3), 0), true).ok)
	var squatter: String = _place(world, FLOOR, Vector2i(6, 3), 0)
	# An old copy of the cell (a restored backup) is loaded on top of memory.
	(saved[BuildingService.KEY_STRUCTURES] as Array).append(_entry("structure_000900", FLOOR, Vector2i(6, 3), 1))
	(saved[BuildingService.KEY_STRUCTURES] as Array).append(_entry("structure_000901", FLOOR, Vector2i(7, 3), 0))
	var before: Dictionary = _saved(world)
	assert_eq(service.restore_cell_document(world, "cell_0_0", saved).size(), 0, "skipping is not an error")
	assert_true(service.has_structure(kept))
	assert_false(service.has_structure(demolished), "a retired id stays gone")
	assert_false(service.has_structure("structure_000900"), "a slot that is taken in memory is not given to a saved structure")
	assert_eq(service.structure_id_at(Vector3i(6, 3, StructureGrid.Layer.TILE)), squatter)
	assert_true(service.has_structure("structure_000901"), "what was really missing is restored")
	var after: Dictionary = _saved(world)
	after.erase("structure_000901")
	assert_true(_same(after, before), "what was in memory is untouched")


func test_documents_cut_with_another_cell_grid_restore_into_the_cells_of_this_grid() -> void:
	var world: ServerWorld = _seeded()
	var service: BuildingService = _building(world)
	world.join("alice")
	# Saved when cells were 20 m: both structures were in "cell_0_0" then.
	var documents: Dictionary = {"cell_0_0": WorldCellDocument.create("cell_0_0", {}, {BuildingService.SYSTEM_ID: _building_cell_document([
		_entry("structure_000201", WALL, Vector2i(3, 3), 0),
		_entry("structure_000202", FLOOR, Vector2i(15, 12), 0),
	])})}
	assert_eq(world.repartition_from(documents).size(), 0)
	assert_eq(world.cell_index.cell_of("structure_000201"), "cell_0_0")
	assert_eq(world.cell_index.cell_of("structure_000202"), "cell_1_1", "indexed where its slot is in this grid")
	assert_eq(service.get_structure("structure_000202").cell_id, "cell_1_1")
	assert_eq((service.to_cell_document("cell_1_1")[BuildingService.KEY_STRUCTURES] as Array).size(), 1)
	assert_eq(((service.to_cell_document("cell_1_1")[BuildingService.KEY_STRUCTURES] as Array)[0] as Dictionary)["cell_id"], "cell_1_1")


# ------------------------------------------------------------ one structure

func test_a_structure_survives_a_json_round_trip_and_bad_data_is_refused() -> void:
	var structure: StructureInstance = StructureInstance.new()
	structure.structure_id = "structure_000042"
	structure.definition_id = DOOR
	structure.owner_shelter_id = "shelter_000007"
	structure.cell_id = "cell_-3_2"
	structure.tile = Vector2i(-27, 23)
	structure.rotation = 3
	structure.construction_state = StructureInstance.State.DAMAGED
	structure.health = 37.5
	structure.material_quality = 0.8
	structure.inventory_costs = {"dev_test_item": 4}
	structure.connections = PackedStringArray(["structure_000041"])
	structure.last_modified_at = 86400.25
	structure.placed_by = "player_000003"
	structure.door_open = true
	var saved: Dictionary = structure.to_dict()
	# Every required field of docs/04 §4 is in the save.
	for key: String in ["structure_id", "definition_id", "owner_shelter_id", "cell_id", "transform", "construction_state", "health", "material_quality", "inventory_costs", "connections", "last_modified_at"]:
		assert_true(saved.has(key), key)
	assert_eq(saved["transform"], {"tile": [-27, 23], "rotation": 3})
	assert_eq(saved["construction_state"], "damaged")
	assert_true(SaveService.is_json_safe(saved), "no Node, RID or Object in a save")
	var back: StructureInstance = StructureInstance.from_dict(_json(saved))
	assert_not_null(back)
	assert_eq(back.to_dict(), saved)
	assert_true(back.is_standing())
	assert_eq(StructureInstance.STATE_NAMES, PackedStringArray(["blueprint", "constructing", "completed", "damaged", "destroyed"]), "the states of docs/04 §4")
	# One broken field at a time.
	var broken: Dictionary = {
		"structure_id": "zombie_000001", "definition_id": "Not Snake", "owner_shelter_id": 7, "construction_state": "done",
		"health": -1.0, "material_quality": "good", "last_modified_at": NAN, "door_open": "yes", "inventory_costs": {"dev_test_item": 0},
		"connections": ["not a structure id"], "placed_by": null, "cell_id": 5,
	}
	for key: String in broken:
		var data: Dictionary = saved.duplicate(true)
		data[key] = broken[key]
		assert_null(StructureInstance.from_dict(data), "bad " + key)
		data.erase(key)
		assert_null(StructureInstance.from_dict(data), "missing " + key)
	for transform: Variant in [null, {}, {"tile": [1], "rotation": 0}, {"tile": [1.5, 2], "rotation": 0}, {"tile": [1, 2], "rotation": 4}, {"tile": [1, 2000000], "rotation": 0}, {"tile": "1,2", "rotation": 0}]:
		var data: Dictionary = saved.duplicate(true)
		data["transform"] = transform
		assert_null(StructureInstance.from_dict(data), "bad transform %s" % str(transform))
