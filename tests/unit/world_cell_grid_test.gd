extends TestCase
## P3-1: pure world cell domain (docs/03 §3, docs/09 §15.1): settings, cell
## coordinates and ids, neighbourhoods, the lifecycle transition table and
## the entity index. No world, no nodes.

const SIZE: float = 10.0


func _settings(size: float = SIZE, half: float = 50.0) -> WorldCellSettings:
	var settings: WorldCellSettings = WorldCellSettings.new()
	settings.cell_size_m = size
	settings.bounds_min_m = Vector2(-half, -half)
	settings.bounds_max_m = Vector2(half, half)
	return settings


func _grid(size: float = SIZE, half: float = 50.0) -> WorldCellGrid:
	return WorldCellGrid.new(_settings(size, half))


func _ids(cells: Array[Vector2i]) -> PackedStringArray:
	var ids: PackedStringArray = []
	for cell: Vector2i in cells:
		ids.append(WorldCellGrid.id_of(cell))
	return ids


# ------------------------------------------------------------ settings

func test_default_settings_are_valid_and_cover_the_map() -> void:
	var settings: WorldCellSettings = WorldCellSettings.new()
	assert_eq(settings.validate().size(), 0)
	assert_eq(settings.bounds_max_m - settings.bounds_min_m, Vector2(4000.0, 4000.0), "the 4 km x 4 km map (F-33)")
	assert_true(settings.preload_radius_cells > settings.active_radius_cells)
	assert_eq(settings.validate_play_area(GameplaySettings.new().world_half_extent_m).size(), 0)
	var grid: WorldCellGrid = WorldCellGrid.new(settings)
	assert_true(grid.cell_count() > (settings.preload_radius_cells * 2 + 1) * (settings.preload_radius_cells * 2 + 1), "some cells are out of one player's reach, so cells do unload in play")


func test_default_tuning_file_matches_the_script_defaults() -> void:
	var loaded: WorldCellSettings = WorldCellSettings.load_or_default()
	var defaults: WorldCellSettings = WorldCellSettings.new()
	assert_eq(loaded.validate().size(), 0)
	for property: String in ["cell_size_m", "bounds_min_m", "bounds_max_m", "active_radius_cells", "preload_radius_cells", "deactivate_delay_sec", "unload_delay_sec", "preload_lookahead_sec", "refresh_period_sec", "max_preload_loads_per_refresh", "retry_delay_sec"]:
		assert_eq(loaded.get(property), defaults.get(property), property)


func test_invalid_settings_are_reported() -> void:
	var settings: WorldCellSettings = _settings()
	settings.cell_size_m = 0.0
	assert_true(settings.validate().size() > 0)
	settings = _settings()
	settings.bounds_max_m = Vector2(-60.0, 50.0)
	assert_true(settings.validate().size() > 0, "empty bounds")
	settings = _settings()
	settings.active_radius_cells = 3
	settings.preload_radius_cells = 3
	assert_true(settings.validate().size() > 0, "the preload ring must be wider than the active area")
	settings = _settings()
	settings.unload_delay_sec = -1.0
	assert_true(settings.validate().size() > 0)
	settings = _settings()
	assert_eq(settings.validate_play_area(50.0).size(), 0)
	assert_true(settings.validate_play_area(50.5).size() > 0, "the play area must lie inside the cell bounds")


# ------------------------------------------------------------ coordinates

func test_cell_of_uses_world_origin_based_coordinates() -> void:
	var grid: WorldCellGrid = _grid()
	assert_eq(grid.cell_of(Vector3(0.0, 0.0, 0.0)), Vector2i(0, 0))
	assert_eq(grid.cell_of(Vector3(9.999, 3.0, 0.0)), Vector2i(0, 0), "height does not matter")
	assert_eq(grid.cell_of(Vector3(25.0, 0.0, 31.0)), Vector2i(2, 3))
	assert_eq(grid.cell_of(Vector3(-0.001, 0.0, 0.0)), Vector2i(-1, 0), "negative coordinates round down, not towards zero")
	assert_eq(grid.cell_of(Vector3(-25.0, 0.0, -31.0)), Vector2i(-3, -4))


func test_exact_borders_belong_to_the_cell_they_start() -> void:
	var grid: WorldCellGrid = _grid()
	assert_eq(grid.cell_of(Vector3(10.0, 0.0, 0.0)), Vector2i(1, 0))
	assert_eq(grid.cell_of(Vector3(-10.0, 0.0, 0.0)), Vector2i(-1, 0))
	assert_eq(grid.cell_of(Vector3(0.0, 0.0, 20.0)), Vector2i(0, 2))
	assert_eq(grid.cell_of(Vector3(0.0, 0.0, -20.0)), Vector2i(0, -2))


func test_positions_on_or_outside_the_bounds_belong_to_the_edge_cells() -> void:
	var grid: WorldCellGrid = _grid()
	assert_eq(grid.min_cell, Vector2i(-5, -5))
	assert_eq(grid.max_cell, Vector2i(4, 4))
	assert_eq(grid.cell_count(), 100)
	assert_eq(grid.cell_of(Vector3(50.0, 0.0, 50.0)), Vector2i(4, 4), "the far border is inside the last cell")
	assert_eq(grid.cell_of(Vector3(-50.0, 0.0, -50.0)), Vector2i(-5, -5))
	assert_eq(grid.cell_of(Vector3(1000.0, 0.0, -1000.0)), Vector2i(4, -5))
	assert_eq(grid.cell_of(Vector3(NAN, 0.0, INF)), Vector2i(0, 0), "a broken position never yields a cell outside the map")
	assert_true(grid.contains_position(Vector3(50.0, 0.0, -50.0)))
	assert_false(grid.contains_position(Vector3(50.01, 0.0, 0.0)))
	assert_false(grid.contains_position(Vector3(NAN, 0.0, 0.0)))


func test_bounds_that_are_no_multiple_of_the_cell_size_get_partial_edge_cells() -> void:
	var grid: WorldCellGrid = _grid(20.0, 50.0)
	assert_eq(grid.min_cell, Vector2i(-3, -3), "[-60, -40) holds -50")
	assert_eq(grid.max_cell, Vector2i(2, 2), "[40, 60) holds 50")
	assert_eq(grid.cell_of(Vector3(50.0, 0.0, -50.0)), Vector2i(2, -3))


func test_cell_corners_and_centres() -> void:
	var grid: WorldCellGrid = _grid()
	assert_eq(grid.cell_min_corner(Vector2i(-2, 3)), Vector3(-20.0, 0.0, 30.0))
	assert_eq(grid.cell_center(Vector2i(-2, 3)), Vector3(-15.0, 0.0, 35.0))
	assert_eq(grid.cell_of(grid.cell_center(Vector2i(-5, 4))), Vector2i(-5, 4))


# ------------------------------------------------------------ ids

func test_cell_ids_are_stable_and_round_trip() -> void:
	assert_eq(WorldCellGrid.id_of(Vector2i(0, 0)), "cell_0_0")
	assert_eq(WorldCellGrid.id_of(Vector2i(-3, 12)), "cell_-3_12")
	assert_eq(WorldCellGrid.id_of(Vector2i(0, 0)), DevWorldSeed.DEV_CELL_ID, "the id written by Phase 1 and 2 saves is a cell id")
	for cell: Vector2i in [Vector2i(0, 0), Vector2i(-5, 4), Vector2i(17, -230)]:
		assert_eq(WorldCellGrid.parse_id(WorldCellGrid.id_of(cell)), cell)
	var grid: WorldCellGrid = _grid()
	assert_eq(grid.cell_id_at(Vector3(-0.5, 0.0, 49.0)), "cell_-1_4")


func test_malformed_cell_ids_are_rejected() -> void:
	for bad: String in ["", "cell", "cell_1", "cell_1_2_3", "cell_a_1", "cell_1.5_2", "cell_+1_2", "cell_01_2", "cell_-0_2", "Cell_1_2", "cell_1_2 ", "../cell_1_2", "cell_1_99999999999999999999"]:
		assert_null(WorldCellGrid.parse_id(bad), bad)
	var grid: WorldCellGrid = _grid()
	assert_true(grid.is_valid_cell_id("cell_-5_4"))
	assert_false(grid.is_valid_cell_id("cell_5_0"), "outside the map")
	assert_false(grid.is_valid_cell_id("cell_x_0"))


# ------------------------------------------------------------ neighbourhoods

func test_cells_within_is_a_square_clipped_to_the_map() -> void:
	var grid: WorldCellGrid = _grid()
	assert_eq(_ids(grid.cells_within(Vector2i(0, 0), 0)), PackedStringArray(["cell_0_0"]))
	var square: Array[Vector2i] = grid.cells_within(Vector2i(0, 0), 1)
	assert_eq(square.size(), 9)
	assert_eq(square[0], Vector2i(-1, -1), "sorted by x, then z")
	assert_eq(square[8], Vector2i(1, 1))
	assert_eq(grid.cells_within(Vector2i(1, -2), 2).size(), 25)
	var corner: Array[Vector2i] = grid.cells_within(Vector2i(4, 4), 1)
	assert_eq(_ids(corner), PackedStringArray(["cell_3_3", "cell_3_4", "cell_4_3", "cell_4_4"]))
	assert_eq(grid.cells_within(Vector2i(0, 0), 100).size(), 100, "never more than the map")
	assert_eq(grid.cells_within(Vector2i(0, 0), -1).size(), 0)


func test_ring_and_neighbours() -> void:
	var grid: WorldCellGrid = _grid()
	assert_eq(_ids(grid.ring(Vector2i(2, 2), 0)), PackedStringArray(["cell_2_2"]))
	assert_eq(grid.ring(Vector2i(0, 0), 1).size(), 8)
	assert_eq(grid.ring(Vector2i(0, 0), 2).size(), 16)
	for cell: Vector2i in grid.ring(Vector2i(0, 0), 2):
		assert_eq(WorldCellGrid.distance(cell, Vector2i(0, 0)), 2)
	assert_eq(grid.neighbours(Vector2i(-5, -5)).size(), 3, "a corner cell has three neighbours")
	assert_false(grid.neighbours(Vector2i(1, 1)).has(Vector2i(1, 1)))
	assert_eq(WorldCellGrid.distance(Vector2i(-2, 1), Vector2i(1, -1)), 3, "Chebyshev distance")


func test_signature_tells_grids_apart() -> void:
	assert_eq(_grid().signature(), _grid().signature())
	assert_ne(_grid().signature(), _grid(20.0).signature())
	assert_ne(_grid().signature(), _grid(SIZE, 100.0).signature())
	assert_true(SaveService.is_json_safe(_grid().signature()))


# ------------------------------------------------------------ lifecycle table

func test_lifecycle_allows_only_the_documented_transitions() -> void:
	var allowed: Array = [
		[WorldCellLifecycle.State.UNLOADED, WorldCellLifecycle.State.LOADING],
		[WorldCellLifecycle.State.LOADING, WorldCellLifecycle.State.PRELOADED],
		[WorldCellLifecycle.State.LOADING, WorldCellLifecycle.State.UNLOADED],
		[WorldCellLifecycle.State.PRELOADED, WorldCellLifecycle.State.ACTIVE],
		[WorldCellLifecycle.State.ACTIVE, WorldCellLifecycle.State.PRELOADED],
		[WorldCellLifecycle.State.PRELOADED, WorldCellLifecycle.State.SAVING],
		[WorldCellLifecycle.State.SAVING, WorldCellLifecycle.State.UNLOADING],
		[WorldCellLifecycle.State.SAVING, WorldCellLifecycle.State.PRELOADED],
		[WorldCellLifecycle.State.UNLOADING, WorldCellLifecycle.State.UNLOADED],
	]
	var count: int = 0
	for from: int in range(WorldCellLifecycle.STATE_NAMES.size()):
		for to: int in range(WorldCellLifecycle.STATE_NAMES.size()):
			var expected: bool = allowed.has([from, to])
			assert_eq(WorldCellLifecycle.can_transition(from, to), expected, "%s -> %s" % [WorldCellLifecycle.state_name(from), WorldCellLifecycle.state_name(to)])
			count += 1
	assert_eq(count, 36)


func test_lifecycle_state_meanings() -> void:
	assert_eq(WorldCellLifecycle.state_name(WorldCellLifecycle.State.ACTIVE), "active")
	assert_eq(WorldCellLifecycle.state_name(99), "")
	for state: int in [WorldCellLifecycle.State.PRELOADED, WorldCellLifecycle.State.ACTIVE, WorldCellLifecycle.State.SAVING]:
		assert_true(WorldCellLifecycle.is_loaded(state))
	for state: int in [WorldCellLifecycle.State.UNLOADED, WorldCellLifecycle.State.LOADING, WorldCellLifecycle.State.UNLOADING]:
		assert_false(WorldCellLifecycle.is_loaded(state))
	for state: int in range(WorldCellLifecycle.STATE_NAMES.size()):
		assert_eq(WorldCellLifecycle.is_simulated(state), state == WorldCellLifecycle.State.ACTIVE, "only an active cell is simulated")
	assert_false(WorldCellLifecycle.can_transition(-1, 0))


# ------------------------------------------------------------ entity index

func test_index_tracks_which_cell_an_entity_is_in() -> void:
	var index: WorldCellIndex = WorldCellIndex.new()
	assert_eq(index.put("item_000002", "item", "cell_0_0"), "")
	assert_eq(index.put("zombie_000003", "zombie", "cell_0_0"), "")
	assert_eq(index.put("item_000001", "item", "cell_0_0"), "")
	assert_eq(index.put("zombie_000004", "zombie", "cell_-1_2"), "")
	assert_eq(index.size(), 4)
	assert_eq(index.cell_of("zombie_000003"), "cell_0_0")
	assert_eq(index.kind_of("zombie_000003"), "zombie")
	assert_eq(index.cell_of("nobody"), "")
	assert_true(index.has("item_000001"))
	assert_eq(index.entities_in_cell("cell_0_0"), PackedStringArray(["item_000001", "item_000002", "zombie_000003"]), "sorted by id")
	assert_eq(index.entities_in_cell("cell_0_0", "item"), PackedStringArray(["item_000001", "item_000002"]))
	assert_eq(index.entities_in_cell("cell_0_0", "zombie"), PackedStringArray(["zombie_000003"]))
	assert_eq(index.entities_in_cell("cell_9_9").size(), 0)
	assert_eq(index.count_in_cell("cell_0_0"), 3)
	assert_eq(index.count_in_cell("cell_0_0", "item"), 2)
	assert_eq(index.occupied_cell_ids(), PackedStringArray(["cell_-1_2", "cell_0_0"]))


func test_index_moves_an_entity_that_crosses_a_border() -> void:
	var index: WorldCellIndex = WorldCellIndex.new()
	index.put("zombie_000001", "zombie", "cell_0_0")
	assert_eq(index.put("zombie_000001", "zombie", "cell_0_0"), "cell_0_0", "same cell: nothing moves")
	assert_eq(index.put("zombie_000001", "zombie", "cell_1_0"), "cell_0_0", "returns the cell it left")
	assert_eq(index.cell_of("zombie_000001"), "cell_1_0")
	assert_eq(index.entities_in_cell("cell_0_0").size(), 0)
	assert_eq(index.entities_in_cell("cell_1_0"), PackedStringArray(["zombie_000001"]))
	assert_eq(index.occupied_cell_ids(), PackedStringArray(["cell_1_0"]), "an emptied cell is not listed")
	assert_eq(index.size(), 1)


func test_index_remove_and_invalid_input() -> void:
	var index: WorldCellIndex = WorldCellIndex.new()
	index.put("item_000001", "item", "cell_0_0")
	index.put("zombie_000002", "zombie", "cell_0_0")
	assert_true(index.remove("item_000001"))
	assert_false(index.remove("item_000001"))
	assert_false(index.has("item_000001"))
	assert_eq(index.entities_in_cell("cell_0_0"), PackedStringArray(["zombie_000002"]))
	GameLogger.set_capture(true)
	assert_eq(index.put("", "item", "cell_0_0"), "")
	assert_eq(index.put("item_000009", "", "cell_0_0"), "")
	assert_eq(index.put("item_000009", "item", ""), "")
	GameLogger.set_capture(false)
	assert_eq(index.size(), 1, "invalid entries are refused")
	index.put("item_000003", "item", "cell_2_2")
	assert_eq(index.remove_kind("item"), 1)
	assert_eq(index.size(), 1)
	assert_eq(index.occupied_cell_ids(), PackedStringArray(["cell_0_0"]))
