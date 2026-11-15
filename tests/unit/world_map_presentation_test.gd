extends TestCase
## P3-2 (docs/09 §15.2): the client's placeholder map. Pure parts only: the
## map layout a client accepts from the server (ClientWorldMap), where the
## ground, the edges and the cell borders go (WorldMapPresentation), the HUD
## line (ClientPresentationFormatter.build_map_lines) and the overlay key
## (ClientPresentationSettings, ClientInputActions). The nodes themselves:
## tests/integration/interest_view_test.gd.

const FLOAT_TOLERANCE: float = 0.0001


## The layout the server would send for a map of `size_m` cells between the
## two corners.
func _fragment(size_m: float, bounds_min: Vector2, bounds_max: Vector2) -> Dictionary:
	var settings: WorldCellSettings = WorldCellSettings.new()
	settings.cell_size_m = size_m
	settings.bounds_min_m = bounds_min
	settings.bounds_max_m = bounds_max
	return ClientWorldMap.describe(WorldCellGrid.new(settings))


func _map(size_m: float, bounds_min: Vector2, bounds_max: Vector2) -> ClientWorldMap:
	var map: ClientWorldMap = ClientWorldMap.new()
	map.apply(_fragment(size_m, bounds_min, bounds_max))
	return map


func _segments(points: PackedVector3Array) -> Array[Array]:
	var segments: Array[Array] = []
	for index: int in range(0, points.size(), 2):
		segments.append([points[index], points[index + 1]])
	return segments


# ------------------------------------------------------------ the layout from the server

func test_the_client_takes_the_map_layout_the_server_describes() -> void:
	var map: ClientWorldMap = ClientWorldMap.new()
	assert_false(map.is_known())
	assert_eq(map.cell_id_at(Vector3(10.0, 0.0, 10.0)), "", "no layout, no cell")
	var changes: Array[int] = [0]
	map.changed.connect(func() -> void: changes[0] += 1)
	# Not the shipped settings: the client must use what it is sent.
	assert_eq(map.apply(_fragment(20.0, Vector2(-60.0, -40.0), Vector2(100.0, 80.0))), "")
	assert_true(map.is_known())
	assert_eq(changes[0], 1)
	assert_eq(map.cell_size_m, 20.0)
	assert_eq(map.bounds_min, Vector2(-60.0, -40.0))
	assert_eq(map.bounds_max, Vector2(100.0, 80.0))
	assert_eq(map.extent(), Vector2(160.0, 120.0))
	assert_eq(map.center(), Vector2(20.0, 20.0))
	assert_eq(map.cell_id_at(Vector3(10.0, 0.0, 10.0)), "cell_0_0")
	assert_eq(map.cell_id_at(Vector3(-0.5, 5.0, 39.9)), "cell_-1_1", "negative coordinates round down, height is ignored")
	assert_eq(map.cell_id_at(Vector3(1000.0, 0.0, -1000.0)), "cell_4_-2", "beyond the map: the edge cell")
	# The client's grid is the server's grid.
	var server_settings: WorldCellSettings = WorldCellSettings.new()
	server_settings.cell_size_m = 20.0
	server_settings.bounds_min_m = Vector2(-60.0, -40.0)
	server_settings.bounds_max_m = Vector2(100.0, 80.0)
	var server_grid: WorldCellGrid = WorldCellGrid.new(server_settings)
	assert_eq(map.grid.signature(), server_grid.signature())
	assert_eq(map.grid.min_cell, server_grid.min_cell)
	assert_eq(map.grid.max_cell, server_grid.max_cell)


func test_the_shipped_test_map_is_five_hundred_metres_of_fifty_metre_cells() -> void:
	var map: ClientWorldMap = ClientWorldMap.new()
	assert_eq(map.apply(ClientWorldMap.describe(WorldCellGrid.new(WorldCellSettings.load_or_default()))), "")
	assert_eq(map.extent(), Vector2(500.0, 500.0))
	assert_eq(map.cell_size_m, 50.0)
	assert_eq(map.grid.cell_count(), 100)


func test_a_layout_that_cannot_be_drawn_is_refused_and_the_map_stays_unknown() -> void:
	var good: Dictionary = _fragment(50.0, Vector2(-250.0, -250.0), Vector2(250.0, 250.0))
	var bad: Array = [
		{},
		{"cell_size_m": 50.0},
		_with(good, "cell_size_m", 0.0),
		_with(good, "cell_size_m", -5.0),
		_with(good, "cell_size_m", NAN),
		_with(good, "cell_size_m", "50"),
		_with(good, "bounds_min_m", [0.0]),
		_with(good, "bounds_min_m", "none"),
		_with(good, "bounds_min_m", [INF, 0.0]),
		_with(good, "bounds_max_m", [-250.0, 250.0]),
		_with(good, "bounds_max_m", [250.0, -250.0]),
		_with(good, "bounds_max_m", [250.0, "250"]),
		_with(good, "cell_size_m", 0.0001),
		_with(good, "extra", 1),
	]
	for fragment: Variant in bad:
		assert_ne(ClientWorldMap.fragment_error(fragment), "", "refused: %s" % str(fragment))
	assert_ne(ClientWorldMap.fragment_error("not a dictionary"), "")
	assert_eq(ClientWorldMap.fragment_error(good), "")
	assert_eq(ClientWorldMap.fragment_error(_with(good, "cell_size_m", 50)), "", "an integer size is a number")
	var map: ClientWorldMap = ClientWorldMap.new()
	assert_eq(map.apply(good), "")
	var changes: Array[int] = [0]
	map.changed.connect(func() -> void: changes[0] += 1)
	assert_eq(map.apply(_with(good, "cell_size_m", 0.0)), ClientWorldMap.REASON_BAD_CELL_SIZE)
	assert_false(map.is_known(), "a refused layout does not leave the old one in place")
	assert_eq(changes[0], 1, "the views are told the map is gone")
	assert_eq(map.cell_id_at(Vector3.ZERO), "")
	map.clear()
	assert_eq(changes[0], 1, "clearing an unknown map changes nothing")


func _with(fragment: Dictionary, key: String, value: Variant) -> Dictionary:
	var copy: Dictionary = fragment.duplicate(true)
	copy[key] = value
	return copy


# ------------------------------------------------------------ ground and edges

func test_the_ground_covers_exactly_the_map_the_server_described() -> void:
	var ground: Dictionary = WorldMapPresentation.ground(Vector2(-250.0, -250.0), Vector2(250.0, 250.0))
	assert_eq(ground[WorldMapPresentation.KEY_SIZE], Vector2(500.0, 500.0))
	assert_eq(ground[WorldMapPresentation.KEY_POSITION], Vector3.ZERO)
	# A map that is not centred on the origin and not square.
	ground = WorldMapPresentation.ground(Vector2(-60.0, -40.0), Vector2(100.0, 80.0))
	assert_eq(ground[WorldMapPresentation.KEY_SIZE], Vector2(160.0, 120.0))
	assert_eq(ground[WorldMapPresentation.KEY_POSITION], Vector3(20.0, 0.0, 20.0))


func test_the_four_edge_walls_stand_just_outside_the_map() -> void:
	var boxes: Array[Dictionary] = WorldMapPresentation.edge_boxes(Vector2(-250.0, -250.0), Vector2(250.0, 250.0), 3.0, 0.5)
	assert_eq(boxes.size(), 4)
	var names: PackedStringArray = []
	for box: Dictionary in boxes:
		names.append(str(box[WorldMapPresentation.KEY_NAME]))
	assert_eq(names, WorldMapPresentation.EDGE_NAMES)
	# The wall at the low x edge: its inner face is x = -250.
	var low_x: Dictionary = boxes[0]
	assert_eq(low_x[WorldMapPresentation.KEY_SIZE], Vector3(0.5, 3.0, 500.0))
	assert_eq(low_x[WorldMapPresentation.KEY_POSITION], Vector3(-250.25, 1.5, 0.0))
	assert_true(absf((low_x[WorldMapPresentation.KEY_POSITION] as Vector3).x + 0.25 - (-250.0)) < FLOAT_TOLERANCE, "inner face on the map edge")
	var high_x: Dictionary = boxes[1]
	assert_eq(high_x[WorldMapPresentation.KEY_POSITION], Vector3(250.25, 1.5, 0.0))
	# The walls along x reach over the corners.
	var low_z: Dictionary = boxes[2]
	assert_eq(low_z[WorldMapPresentation.KEY_SIZE], Vector3(501.0, 3.0, 0.5))
	assert_eq(low_z[WorldMapPresentation.KEY_POSITION], Vector3(0.0, 1.5, -250.25))
	assert_eq(boxes[3][WorldMapPresentation.KEY_POSITION], Vector3(0.0, 1.5, 250.25))
	# Every wall stands on the ground.
	for box: Dictionary in boxes:
		var position: Vector3 = box[WorldMapPresentation.KEY_POSITION]
		var size: Vector3 = box[WorldMapPresentation.KEY_SIZE]
		assert_true(absf(position.y - size.y * 0.5) < FLOAT_TOLERANCE)


# ------------------------------------------------------------ cell overlay

func test_the_overlay_draws_every_border_of_the_cells_around_the_player_once() -> void:
	var map: ClientWorldMap = _map(50.0, Vector2(-250.0, -250.0), Vector2(250.0, 250.0))
	var center: Vector2i = map.grid.cell_of(Vector3(10.0, 0.0, 10.0))
	assert_eq(WorldMapPresentation.overlay_cells(map.grid, center, 1).size(), 9)
	var segments: Array[Array] = _segments(WorldMapPresentation.cell_border_segments(map.grid, map.bounds_min, map.bounds_max, center, 1, 0.05))
	# 3 x 3 cells: four lines each way.
	assert_eq(segments.size(), 8)
	assert_eq(segments[0], [Vector3(-50.0, 0.05, -50.0), Vector3(-50.0, 0.05, 100.0)], "the first line of constant x")
	assert_eq(segments[3], [Vector3(100.0, 0.05, -50.0), Vector3(100.0, 0.05, 100.0)], "the last one")
	assert_eq(segments[4], [Vector3(-50.0, 0.05, -50.0), Vector3(100.0, 0.05, -50.0)], "the first line of constant z")
	assert_eq(segments[7], [Vector3(-50.0, 0.05, 100.0), Vector3(100.0, 0.05, 100.0)])
	for segment: Array in segments:
		assert_ne(segment[0], segment[1], "no line of zero length")
	assert_eq(segments.size(), _unique(segments).size(), "no line twice")


func test_the_overlay_stops_at_the_edge_of_the_map() -> void:
	var map: ClientWorldMap = _map(50.0, Vector2(-250.0, -250.0), Vector2(250.0, 250.0))
	# The corner cell with a radius of 2: 3 x 3 cells are on the map.
	var center: Vector2i = map.grid.cell_of(Vector3(240.0, 0.0, 240.0))
	assert_eq(center, Vector2i(4, 4))
	var segments: Array[Array] = _segments(WorldMapPresentation.cell_border_segments(map.grid, map.bounds_min, map.bounds_max, center, 2, 0.0))
	assert_eq(segments.size(), 8)
	for segment: Array in segments:
		for point: Vector3 in segment:
			assert_true(point.x >= 100.0 and point.x <= 250.0 and point.z >= 100.0 and point.z <= 250.0, "inside the shown cells: %s" % str(point))
	# A radius of zero is the player's own cell.
	assert_eq(_segments(WorldMapPresentation.cell_border_segments(map.grid, map.bounds_min, map.bounds_max, center, 0, 0.0)).size(), 4)
	assert_eq(WorldMapPresentation.cell_border_segments(map.grid, map.bounds_min, map.bounds_max, center, -1, 0.0).size(), 0)


func test_a_map_that_is_no_multiple_of_the_cell_size_is_cut_at_its_edge() -> void:
	# 50 m cells on a map of 120 m x 80 m: the last cells reach beyond it.
	var map: ClientWorldMap = _map(50.0, Vector2(0.0, 0.0), Vector2(120.0, 80.0))
	assert_eq(map.grid.max_cell, Vector2i(2, 1))
	var segments: Array[Array] = _segments(WorldMapPresentation.cell_border_segments(map.grid, map.bounds_min, map.bounds_max, Vector2i(1, 0), 5, 0.0))
	assert_eq(segments.size(), 7, "four lines of constant x, three of constant z")
	assert_eq(segments[3], [Vector3(120.0, 0.0, 0.0), Vector3(120.0, 0.0, 80.0)], "the last border is the map edge, not x = 150")
	assert_eq(segments[6], [Vector3(0.0, 0.0, 80.0), Vector3(120.0, 0.0, 80.0)], "and z = 80, not z = 100")
	var labels: Array[Dictionary] = WorldMapPresentation.cell_labels(map.grid, map.bounds_min, map.bounds_max, Vector2i(1, 0), 5, 2.0)
	assert_eq(labels.size(), 6)
	assert_eq(labels[5][WorldMapPresentation.KEY_TEXT], "cell_2_1")
	assert_eq(labels[5][WorldMapPresentation.KEY_POSITION], Vector3(110.0, 2.0, 65.0), "in the middle of the part that is on the map")


func test_every_shown_cell_is_labelled_with_its_id() -> void:
	var map: ClientWorldMap = _map(50.0, Vector2(-250.0, -250.0), Vector2(250.0, 250.0))
	var center: Vector2i = map.grid.cell_of(Vector3(-10.0, 0.0, 10.0))
	var labels: Array[Dictionary] = WorldMapPresentation.cell_labels(map.grid, map.bounds_min, map.bounds_max, center, 1, 2.5)
	assert_eq(labels.size(), 9)
	assert_eq(labels[0][WorldMapPresentation.KEY_TEXT], "cell_-2_-1")
	assert_eq(labels[0][WorldMapPresentation.KEY_POSITION], Vector3(-75.0, 2.5, -25.0))
	assert_eq(labels[4][WorldMapPresentation.KEY_TEXT], "cell_-1_0", "the player's own cell is the middle one")
	assert_eq(labels[4][WorldMapPresentation.KEY_POSITION], Vector3(-25.0, 2.5, 25.0))
	for entry: Dictionary in labels:
		assert_eq(map.cell_id_at(entry[WorldMapPresentation.KEY_POSITION]), entry[WorldMapPresentation.KEY_TEXT], "a label stands in the cell it names")


func _unique(segments: Array[Array]) -> Dictionary:
	var seen: Dictionary = {}
	for segment: Array in segments:
		seen[str(segment)] = true
	return seen


# ------------------------------------------------------------ HUD line and key

func test_the_hud_line_names_the_cell_the_position_and_the_overlay_key() -> void:
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	assert_eq(ClientPresentationFormatter.build_map_lines("", Vector3.ZERO, false, settings), PackedStringArray(), "no cell, no line")
	var lines: PackedStringArray = ClientPresentationFormatter.build_map_lines("cell_-4_3", Vector3(-199.6, 0.0, 151.2), false, settings)
	assert_eq(lines.size(), 1)
	assert_contains(lines[0], "cell_-4_3")
	assert_contains(lines[0], "x -200, z 151")
	assert_contains(lines[0], "[F3]")
	assert_contains(lines[0], "꺼짐")
	lines = ClientPresentationFormatter.build_map_lines("cell_0_0", Vector3(1.0, 0.0, 2.0), true, settings)
	assert_contains(lines[0], "켜짐")
	settings.cell_overlay_key = KEY_F4
	assert_contains(ClientPresentationFormatter.build_map_lines("cell_0_0", Vector3.ZERO, true, settings)[0], "[F4]", "the key shown is the key set")


func test_the_overlay_key_is_a_key_of_its_own() -> void:
	var defaults: ClientPresentationSettings = ClientPresentationSettings.new()
	assert_eq(defaults.validate(), PackedStringArray())
	assert_eq(defaults.cell_overlay_key, KEY_F3)
	assert_false(defaults.cell_overlay_initially_visible, "off until somebody asks for it")
	assert_eq(defaults.assigned_keys()["cell_overlay_key"], KEY_F3)
	var shipped: ClientPresentationSettings = ClientPresentationSettings.load_or_default()
	assert_eq(shipped.validate(), PackedStringArray())
	assert_eq(shipped.cell_overlay_key, defaults.cell_overlay_key, "the data file holds the same key as the code default")
	assert_eq(shipped.keys_shared_with(CameraSettings.load_or_default()).size(), 0)
	# Every key that was taken before this ticket is another key.
	var taken: Array[Key] = [KEY_W, KEY_A, KEY_S, KEY_D, KEY_E, KEY_F, KEY_G, KEY_B, KEY_V, KEY_R, KEY_C, KEY_Q, KEY_Z, KEY_X, KEY_T, KEY_Y, KEY_N, KEY_O, KEY_P, KEY_SHIFT, KEY_CTRL]
	assert_false(taken.has(shipped.cell_overlay_key))
	# A clash is caught by the settings check.
	var clashing: ClientPresentationSettings = ClientPresentationSettings.new()
	clashing.cell_overlay_key = clashing.drop_key
	assert_eq(clashing.validate().size(), 1)
	clashing.cell_overlay_key = KEY_NONE
	assert_true(clashing.validate().size() >= 1)
	clashing = ClientPresentationSettings.new()
	clashing.cell_overlay_key = KEY_W
	assert_eq(clashing.keys_shared_with(CameraSettings.new()), PackedStringArray(["cell_overlay_key"]))
	clashing = ClientPresentationSettings.new()
	clashing.map_edge_height_m = 0.0
	assert_eq(clashing.validate().size(), 1)
	clashing = ClientPresentationSettings.new()
	clashing.cell_overlay_radius_cells = -1
	assert_eq(clashing.validate().size(), 1)


func test_the_overlay_key_becomes_an_input_action() -> void:
	ClientInputActions.register(CameraSettings.new(), ClientPresentationSettings.new())
	assert_true(InputMap.has_action(ClientInputActions.CELL_OVERLAY))
	var events: Array[InputEvent] = InputMap.action_get_events(ClientInputActions.CELL_OVERLAY)
	assert_eq(events.size(), 1)
	assert_eq((events[0] as InputEventKey).physical_keycode, KEY_F3)
