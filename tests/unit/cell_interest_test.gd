extends TestCase
## P3-2: which cells a peer is told about (CellInterest, docs/09 §15.2) and
## the settings behind it. Pure bookkeeping: no nodes, no network. Positions
## are given directly, as the server would read them from its players.

const PEER_A: int = 11
const PEER_B: int = 22
const CELL_M: float = 10.0

var _settings: InterestSettings = null
var _grid: WorldCellGrid = null
var _interest: CellInterest = null
## "gained:<peer>:<cell>" / "lost:<peer>:<cell>", in the order emitted.
var _log: PackedStringArray = []
## Cells the fake world does NOT have in memory (see _is_loaded).
var _unloaded: Dictionary[String, bool] = {}


func before_each() -> void:
	_settings = InterestSettings.new()
	_settings.interest_radius_cells = 2
	_settings.keep_margin_cells = 1
	_log = PackedStringArray()
	_unloaded = {}
	_build(Vector2(-100.0, -100.0), Vector2(100.0, 100.0))


## The signal handlers below capture this test, which holds the tracker:
## letting go of it here breaks that cycle (both are reference counted).
func after_each() -> void:
	_interest = null


## A 20 x 20 map of 10 m cells unless told otherwise.
func _build(bounds_min: Vector2, bounds_max: Vector2, gate: bool = false) -> void:
	var cells: WorldCellSettings = WorldCellSettings.new()
	cells.cell_size_m = CELL_M
	cells.bounds_min_m = bounds_min
	cells.bounds_max_m = bounds_max
	_grid = WorldCellGrid.new(cells)
	_interest = CellInterest.new(_grid, _settings, _is_loaded if gate else Callable())
	_interest.cell_gained.connect(func(peer_id: int, cell_id: String) -> void: _log.append("gained:%d:%s" % [peer_id, cell_id]))
	_interest.cell_lost.connect(func(peer_id: int, cell_id: String) -> void: _log.append("lost:%d:%s" % [peer_id, cell_id]))


func _is_loaded(cell_id: String) -> bool:
	return not _unloaded.has(cell_id)


## Centre of a cell.
func _at(cx: int, cz: int) -> Vector3:
	return Vector3((float(cx) + 0.5) * CELL_M, 0.0, (float(cz) + 0.5) * CELL_M)


func _ids(cells: Array[Vector2i]) -> PackedStringArray:
	var ids: PackedStringArray = []
	for cell: Vector2i in cells:
		ids.append(WorldCellGrid.id_of(cell))
	return ids


func _count(prefix: String) -> int:
	var count: int = 0
	for line: String in _log:
		if line.begins_with(prefix):
			count += 1
	return count


# ------------------------------------------------------------ the area

func test_a_peer_is_told_about_the_square_of_cells_around_its_player() -> void:
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	assert_eq(_interest.cell_count_of(PEER_A), 25, "radius 2 = 5 x 5 cells")
	assert_eq(_interest.cells_of(PEER_A), _ids(_grid.cells_within(Vector2i(0, 0), 2)), "in cell order")
	assert_true(_interest.is_interested(PEER_A, "cell_2_-2"), "a corner of the square")
	assert_false(_interest.is_interested(PEER_A, "cell_3_0"), "one cell further is not")
	assert_false(_interest.is_interested(PEER_A, "cell_0_-3"))
	# Anywhere inside the same cell gives the same cells: the area follows the
	# cell, not the exact position.
	_interest.update_peer(PEER_A, true, Vector3(0.01, 0.0, 9.99))
	assert_eq(_interest.cell_count_of(PEER_A), 25)
	assert_eq(_log.size(), 0, "nothing changed")


func test_the_area_is_cut_off_at_the_edge_of_the_map() -> void:
	_interest.begin_peer(PEER_A, true, _at(9, 9))
	assert_eq(_interest.cell_count_of(PEER_A), 9, "the corner cell sees 3 x 3 cells")
	assert_eq(_interest.cells_of(PEER_A), _ids(_grid.cells_within(Vector2i(9, 9), 2)))
	assert_false(_interest.is_interested(PEER_A, "cell_10_9"), "there is no cell beyond the edge")
	# A position on or beyond the edge belongs to the edge cell.
	_interest.begin_peer(PEER_B, true, Vector3(100.0, 0.0, 250.0))
	assert_eq(_interest.cells_of(PEER_B), _interest.cells_of(PEER_A))
	_interest.begin_peer(PEER_B, true, _at(-10, 0))
	assert_eq(_interest.cell_count_of(PEER_B), 15, "at the middle of an edge: 3 x 5 cells")


func test_negative_coordinates_round_down_like_the_cell_grid() -> void:
	_interest.begin_peer(PEER_A, true, Vector3(-0.001, 0.0, -0.001))
	assert_true(_interest.is_interested(PEER_A, "cell_-1_-1"), "x = -0.001 is in cell -1")
	assert_true(_interest.is_interested(PEER_A, "cell_-3_-3"))
	assert_true(_interest.is_interested(PEER_A, "cell_1_1"))
	assert_false(_interest.is_interested(PEER_A, "cell_2_0"))
	assert_false(_interest.is_interested(PEER_A, "cell_-4_-1"))
	assert_eq(_interest.cells_of(PEER_A)[0], "cell_-3_-3", "cell order is by coordinates, not by text")
	assert_eq(_interest.cells_of(PEER_A)[24], "cell_1_1")


func test_a_radius_of_zero_is_the_players_own_cell() -> void:
	_settings.interest_radius_cells = 0
	_settings.keep_margin_cells = 0
	_interest.begin_peer(PEER_A, true, _at(3, -4))
	assert_eq(_interest.cells_of(PEER_A), PackedStringArray(["cell_3_-4"]))


# ------------------------------------------------------------ notifications

func test_beginning_a_peer_emits_nothing_and_updating_announces_changes() -> void:
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	assert_eq(_log.size(), 0, "the first cells travel with the join snapshot")
	assert_true(_interest.has_peer(PEER_A))
	# One cell to the east: the column x = 3 comes into the square. Nothing is
	# lost: the column x = -2 is 3 cells away, within the keep radius.
	_interest.update_peer(PEER_A, true, _at(1, 0))
	assert_eq(_log, PackedStringArray(["gained:11:cell_3_-2", "gained:11:cell_3_-1", "gained:11:cell_3_0", "gained:11:cell_3_1", "gained:11:cell_3_2"]))
	assert_eq(_interest.gained_count, 5)
	assert_eq(_interest.lost_count, 0)


func test_a_peer_that_was_never_begun_gains_everything_it_wants() -> void:
	_interest.update_peer(PEER_A, true, _at(0, 0))
	assert_eq(_count("gained:11:"), 25)
	assert_eq(_count("lost:"), 0)
	assert_eq(_log[0], "gained:11:cell_-2_-2", "in cell order")
	assert_eq(_log[24], "gained:11:cell_2_2")


func test_losses_are_announced_before_gains() -> void:
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	# Two cells east at once: column x = -2 is now 4 cells away (lost), the
	# columns x = 3 and x = 4 are new.
	_interest.update_peer(PEER_A, true, _at(2, 0))
	assert_eq(_count("lost:11:"), 5)
	assert_eq(_count("gained:11:"), 10)
	for index: int in range(5):
		assert_true(_log[index].begins_with("lost:11:cell_-2_"), "the first five lines are the lost column: %s" % _log[index])
	assert_eq(_log[5], "gained:11:cell_3_-2")
	assert_eq(_log[14], "gained:11:cell_4_2")
	assert_false(_interest.is_interested(PEER_A, "cell_-2_0"))
	assert_true(_interest.is_interested(PEER_A, "cell_-1_0"), "kept: 3 cells away")
	assert_true(_interest.is_interested(PEER_A, "cell_4_0"))


func test_the_queries_already_have_the_change_while_its_signal_is_handled() -> void:
	var seen: Array[bool] = []
	_interest.cell_gained.connect(func(peer_id: int, cell_id: String) -> void: seen.append(_interest.is_interested(peer_id, cell_id)))
	_interest.cell_lost.connect(func(peer_id: int, cell_id: String) -> void: seen.append(not _interest.is_interested(peer_id, cell_id)))
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	_interest.update_peer(PEER_A, true, _at(2, 0))
	assert_eq(seen.size(), 15)
	assert_false(seen.has(false), "a gained cell is listed and a lost cell is not, inside the handlers")


# ------------------------------------------------------------ hysteresis

func test_walking_to_and_fro_across_a_border_changes_nothing_after_the_first_crossing() -> void:
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	# Step counter: twenty crossings of the border between cell 0 and cell 1.
	for step: int in range(20):
		_interest.update_peer(PEER_A, true, Vector3(10.2 if step % 2 == 0 else 9.8, 0.0, 5.0))
	assert_eq(_count("gained:11:"), 5, "only the first crossing brought a new column in")
	assert_eq(_count("lost:11:"), 0, "and nothing ever went away")
	assert_eq(_interest.cell_count_of(PEER_A), 30, "the union of both squares stays")
	assert_eq(_interest.update_count, 20)
	assert_eq(_interest.recompute_count, 20, "every crossing was looked at")


func test_without_a_margin_every_crossing_drops_and_brings_a_column() -> void:
	_settings.keep_margin_cells = 0
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	for step: int in range(4):
		_interest.update_peer(PEER_A, true, Vector3(10.2 if step % 2 == 0 else 9.8, 0.0, 5.0))
	assert_eq(_count("gained:11:"), 20, "this is the flicker the margin is there to prevent")
	assert_eq(_count("lost:11:"), 20)
	assert_eq(_interest.cell_count_of(PEER_A), 25)


func test_a_kept_cell_goes_once_it_is_beyond_the_keep_radius() -> void:
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	_interest.update_peer(PEER_A, true, _at(1, 0))
	assert_true(_interest.is_interested(PEER_A, "cell_-2_0"), "3 cells away: kept")
	_interest.update_peer(PEER_A, true, _at(2, 0))
	assert_false(_interest.is_interested(PEER_A, "cell_-2_0"), "4 cells away: gone")
	assert_true(_interest.is_interested(PEER_A, "cell_-1_0"))
	# Coming back does not bring it in again until it is inside the radius.
	_interest.update_peer(PEER_A, true, _at(1, 0))
	assert_false(_interest.is_interested(PEER_A, "cell_-2_0"), "3 cells away, but it was dropped: not of interest")
	_interest.update_peer(PEER_A, true, _at(0, 0))
	assert_true(_interest.is_interested(PEER_A, "cell_-2_0"), "2 cells away: of interest again")


func test_standing_in_a_cell_costs_no_recomputation() -> void:
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	for step: int in range(100):
		_interest.update_peer(PEER_A, true, Vector3(float(step) * 0.09, 0.0, 5.0))
	assert_eq(_interest.update_count, 100)
	assert_eq(_interest.recompute_count, 0, "the player never left cell 0")
	assert_eq(_log.size(), 0)


func test_a_jump_across_the_map_replaces_every_cell() -> void:
	_interest.begin_peer(PEER_A, true, _at(-9, -9))
	_interest.update_peer(PEER_A, true, _at(7, 7))
	assert_eq(_count("lost:11:"), 16, "the 4 x 4 cells near the first corner")
	assert_eq(_count("gained:11:"), 25)
	assert_eq(_interest.cells_of(PEER_A), _ids(_grid.cells_within(Vector2i(7, 7), 2)))


# ------------------------------------------------------------ not in the world

func test_a_peer_without_a_character_has_no_cells_until_it_enters_the_world() -> void:
	_interest.begin_peer(PEER_A, false, _at(0, 0))
	assert_true(_interest.has_peer(PEER_A))
	assert_eq(_interest.cell_count_of(PEER_A), 0)
	assert_false(_interest.is_interested(PEER_A, "cell_0_0"))
	_interest.update_peer(PEER_A, false, _at(5, 5))
	assert_eq(_log.size(), 0, "it still has no position that counts")
	_interest.update_peer(PEER_A, true, _at(0, 0))
	assert_eq(_count("gained:11:"), 25, "it entered the world")
	_interest.update_peer(PEER_A, false, _at(0, 0))
	assert_eq(_count("lost:11:"), 25, "and left it again")
	assert_eq(_interest.cell_count_of(PEER_A), 0)
	# What it wanted before does not linger: entering elsewhere starts afresh.
	_interest.update_peer(PEER_A, true, _at(1, 0))
	assert_false(_interest.is_interested(PEER_A, "cell_-2_0"))
	assert_eq(_interest.cell_count_of(PEER_A), 25)


# ------------------------------------------------------------ several peers

func test_who_is_interested_in_a_cell() -> void:
	_interest.begin_peer(PEER_B, true, _at(4, 0))
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	assert_eq(_interest.peer_ids(), PackedInt32Array([PEER_A, PEER_B]))
	assert_eq(_interest.peers_for_cell("cell_2_0"), PackedInt32Array([PEER_A, PEER_B]), "both squares cover it; sorted")
	assert_eq(_interest.peers_for_cell("cell_0_0"), PackedInt32Array([PEER_A]))
	assert_eq(_interest.peers_for_cell("cell_6_0"), PackedInt32Array([PEER_B]))
	assert_eq(_interest.peers_for_cell("cell_9_9"), PackedInt32Array())
	assert_eq(_interest.peers_for_cell("not_a_cell"), PackedInt32Array())
	assert_false(_interest.is_interested(99, "cell_0_0"), "an unknown peer is interested in nothing")
	assert_eq(_interest.cells_of(99), PackedStringArray())
	# One peer moving tells nothing about the other.
	_interest.update_peer(PEER_A, true, _at(1, 0))
	assert_eq(_count("gained:22:") + _count("lost:22:"), 0)


func test_a_peer_that_left_is_forgotten_without_any_signal() -> void:
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	_interest.begin_peer(PEER_B, true, _at(0, 0))
	_interest.remove_peer(PEER_A)
	assert_eq(_log.size(), 0)
	assert_false(_interest.has_peer(PEER_A))
	assert_eq(_interest.peers_for_cell("cell_0_0"), PackedInt32Array([PEER_B]))
	assert_eq(_interest.cell_count_of(PEER_A), 0)
	_interest.remove_peer(PEER_A)
	assert_eq(_interest.peer_ids(), PackedInt32Array([PEER_B]), "removing twice is harmless")


func test_beginning_a_peer_again_starts_it_afresh() -> void:
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	_interest.begin_peer(PEER_A, true, _at(8, 8))
	assert_eq(_log.size(), 0)
	assert_eq(_interest.cells_of(PEER_A), _ids(_grid.cells_within(Vector2i(8, 8), 2)))
	assert_eq(_interest.peers_for_cell("cell_0_0"), PackedInt32Array(), "nothing is left of the first start")


# ------------------------------------------------------------ cells in memory

func test_a_cell_that_is_not_in_memory_is_of_interest_to_nobody() -> void:
	_build(Vector2(-100.0, -100.0), Vector2(100.0, 100.0), true)
	_unloaded["cell_1_0"] = true
	_unloaded["cell_2_2"] = true
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	_interest.begin_peer(PEER_B, true, _at(8, 8))
	assert_eq(_interest.cell_count_of(PEER_A), 23)
	assert_false(_interest.is_interested(PEER_A, "cell_1_0"))
	# It comes into memory: only the peer that wants it gains it.
	_unloaded.erase("cell_1_0")
	_interest.notify_cell_loaded("cell_1_0")
	assert_eq(_log, PackedStringArray(["gained:11:cell_1_0"]))
	assert_true(_interest.is_interested(PEER_A, "cell_1_0"))
	_interest.notify_cell_loaded("cell_1_0")
	assert_eq(_log.size(), 1, "told once")
	# A cell nobody wants comes and goes without a signal.
	_interest.notify_cell_loaded("cell_5_5")
	_interest.notify_cell_unloading("cell_5_5")
	_interest.notify_cell_loaded("not_a_cell")
	assert_eq(_log.size(), 1)


func test_a_cell_leaving_memory_is_lost_and_comes_back_when_it_is_loaded_again() -> void:
	_build(Vector2(-100.0, -100.0), Vector2(100.0, 100.0), true)
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	_interest.begin_peer(PEER_B, true, _at(2, 0))
	_unloaded["cell_1_1"] = true
	_interest.notify_cell_unloading("cell_1_1")
	assert_eq(_log, PackedStringArray(["lost:11:cell_1_1", "lost:22:cell_1_1"]), "both peers had it; in peer order")
	assert_eq(_interest.peers_for_cell("cell_1_1"), PackedInt32Array())
	# Moving inside the area while the cell is away does not bring it back.
	_interest.update_peer(PEER_A, true, _at(1, 0))
	assert_false(_interest.is_interested(PEER_A, "cell_1_1"))
	_log = PackedStringArray()
	_unloaded.erase("cell_1_1")
	_interest.notify_cell_loaded("cell_1_1")
	assert_eq(_log, PackedStringArray(["gained:11:cell_1_1", "gained:22:cell_1_1"]))


func test_a_cell_that_is_away_when_a_peer_walks_up_is_gained_when_it_loads() -> void:
	_build(Vector2(-100.0, -100.0), Vector2(100.0, 100.0), true)
	_unloaded["cell_3_0"] = true
	_interest.begin_peer(PEER_A, true, _at(0, 0))
	_interest.update_peer(PEER_A, true, _at(1, 0))
	assert_eq(_count("gained:11:"), 4, "the column x = 3 without the cell that is away")
	assert_false(_log.has("gained:11:cell_3_0"))
	_unloaded.erase("cell_3_0")
	_interest.notify_cell_loaded("cell_3_0")
	assert_eq(_log[_log.size() - 1], "gained:11:cell_3_0")


# ------------------------------------------------------------ settings

func test_default_settings_are_valid_and_fit_the_default_cell_lifecycle() -> void:
	var defaults: InterestSettings = InterestSettings.new()
	assert_eq(defaults.validate(), PackedStringArray())
	assert_eq(defaults.interest_radius_cells, 2)
	assert_eq(defaults.keep_margin_cells, 1)
	assert_eq(defaults.keep_radius_cells(), 3)
	assert_eq(defaults.validate_against(WorldCellSettings.new()), PackedStringArray(), "kept area 3 <= preload radius 3")
	var loaded: InterestSettings = InterestSettings.load_or_default()
	assert_eq(loaded.interest_radius_cells, defaults.interest_radius_cells, "the data file holds the same values as the code defaults")
	assert_eq(loaded.keep_margin_cells, defaults.keep_margin_cells)
	assert_eq(loaded.validate_against(WorldCellSettings.load_or_default()), PackedStringArray())


func test_settings_that_cannot_work_are_refused() -> void:
	var settings: InterestSettings = InterestSettings.new()
	settings.interest_radius_cells = -1
	assert_eq(settings.validate().size(), 1)
	settings.interest_radius_cells = 2
	settings.keep_margin_cells = -1
	assert_eq(settings.validate().size(), 1)


func test_the_interest_area_may_not_reach_beyond_what_the_server_keeps_in_memory() -> void:
	var cells: WorldCellSettings = WorldCellSettings.new()
	cells.active_radius_cells = 2
	cells.preload_radius_cells = 3
	var settings: InterestSettings = InterestSettings.new()
	settings.interest_radius_cells = 3
	settings.keep_margin_cells = 0
	assert_eq(settings.validate_against(cells), PackedStringArray(), "exactly the preload area is allowed")
	settings.keep_margin_cells = 1
	var errors: PackedStringArray = settings.validate_against(cells)
	assert_eq(errors.size(), 1, "radius 3 + margin 1 reaches cells the server has released")
	assert_contains(errors[0], "preload_radius_cells")
	settings.interest_radius_cells = 4
	settings.keep_margin_cells = 0
	assert_eq(settings.validate_against(cells).size(), 1)
	assert_eq(settings.validate_against(null).size(), 1, "the two settings are checked together or not at all")


func test_the_composition_checks_the_two_settings_against_each_other() -> void:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate(), PackedStringArray(), "the shipped settings fit together")
	# from_defaults() hands out shared cached resources: replace, never edit.
	config.interest = InterestSettings.new()
	config.interest.interest_radius_cells = 9
	var errors: PackedStringArray = config.validate()
	assert_eq(errors.size(), 1)
	assert_contains(errors[0], "interest")
	config.interest = null
	assert_contains("; ".join(config.validate()), "interest")
