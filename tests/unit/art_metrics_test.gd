extends TestCase
## Art loop metrics (tools/art_metrics_lib.gd): every count is checked on a
## picture drawn here, where the right answer is known.

const MetricsLib: GDScript = preload("res://tools/art_metrics_lib.gd")
const WHITE: Color = Color(1.0, 1.0, 1.0, 1.0)
const BLACK: Color = Color(0.0, 0.0, 0.0, 1.0)
const CLEAR: Color = Color(0.0, 0.0, 0.0, 0.0)
const RED: Color = Color(1.0, 0.0, 0.0, 1.0)
const SIZE: int = 64


func _canvas(fill: Color, size: int = SIZE) -> Image:
	var image: Image = Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	return image


func _horizontal(image: Image, y: int, from_x: int, to_x: int, color: Color = BLACK) -> void:
	for x: int in range(from_x, to_x + 1):
		image.set_pixel(x, y, color)


func _vertical(image: Image, x: int, from_y: int, to_y: int, color: Color = BLACK) -> void:
	for y: int in range(from_y, to_y + 1):
		image.set_pixel(x, y, color)


func test_clean_flat_image_has_no_defects() -> void:
	var result: Dictionary = MetricsLib.measure(_canvas(WHITE))
	assert_eq(result["specks"], 0)
	assert_eq(result["line_breaks"], 0)
	assert_eq(result["halo_px"], 0)
	assert_eq(result["colors_exact"], 1)
	assert_eq(result["has_alpha"], false)
	assert_eq(result["width"], SIZE)


func test_specks_count_small_isolated_groups_only() -> void:
	var image: Image = _canvas(WHITE)
	image.set_pixel(5, 5, BLACK)                       # 1 px speck
	_horizontal(image, 20, 10, 11)                     # 2 px speck
	image.fill_rect(Rect2i(40, 10, 2, 2), RED)         # 4 px speck
	image.fill_rect(Rect2i(30, 40, 5, 5), BLACK)       # 25 px: too large to be a speck
	image.set_pixel(55, 55, Color(0.95, 0.95, 0.95))   # too faint: part of the background
	var result: Dictionary = MetricsLib.measure(image)
	assert_eq(result["specks"], 3)
	assert_eq(result["speck_px"], 7)


func test_speck_limits_come_from_settings() -> void:
	var image: Image = _canvas(WHITE)
	image.fill_rect(Rect2i(30, 40, 5, 5), BLACK)
	image.set_pixel(5, 5, Color(0.7, 0.7, 0.7))
	assert_eq(MetricsLib.measure(image)["specks"], 1, "0.7 grey on white is past the default contrast")
	var loose: Dictionary = {"specks": {"max_px": 25}}
	assert_eq(MetricsLib.measure(image, loose)["specks"], 2, "a 25 px block counts when max_px allows it")
	var strict: Dictionary = {"specks": {"min_contrast": 200}}
	assert_eq(MetricsLib.measure(image, strict)["specks"], 0)


func test_detail_inside_a_busy_area_is_not_a_speck() -> void:
	# A dot on the border between a black half and a white half: its
	# surroundings are not flat, so it is not "isolated".
	var image: Image = _canvas(WHITE)
	image.fill_rect(Rect2i(0, 0, 32, SIZE), BLACK)
	image.set_pixel(32, 30, RED)
	assert_eq(MetricsLib.measure(image)["specks"], 0)


func test_opaque_dot_on_transparent_area_is_a_speck() -> void:
	var image: Image = _canvas(CLEAR)
	image.set_pixel(10, 10, WHITE)
	var result: Dictionary = MetricsLib.measure(image)
	assert_eq(result["specks"], 1)
	assert_eq(result["has_alpha"], true)


func test_line_breaks_count_gaps_between_stroke_ends() -> void:
	var image: Image = _canvas(WHITE)
	_horizontal(image, 8, 4, 24)        # thin line with a 4 px gap ...
	_horizontal(image, 8, 29, 50)       # ... -> 1 break
	_horizontal(image, 20, 4, 24)       # 2 px thick line with a 3 px gap ...
	_horizontal(image, 21, 4, 24)
	_horizontal(image, 20, 28, 50)      # ... -> 1 break
	_horizontal(image, 21, 28, 50)
	_horizontal(image, 32, 4, 50)       # whole line -> 0
	_horizontal(image, 44, 4, 20)       # gap of 14 px, wider than gap_max_px ...
	_horizontal(image, 44, 35, 50)      # ... -> 0
	_vertical(image, 58, 30, 50)        # whole vertical line -> 0
	var result: Dictionary = MetricsLib.measure(image)
	assert_eq(result["line_breaks"], 2)


func test_line_break_on_a_diagonal_stroke() -> void:
	var image: Image = _canvas(WHITE)
	for i: int in range(4, 60):
		if i < 28 or i > 31:            # 4 px missing in the middle
			image.set_pixel(i, i, BLACK)
	assert_eq(MetricsLib.measure(image)["line_breaks"], 1)


func test_stroke_ends_that_do_not_face_each_other_are_not_breaks() -> void:
	var image: Image = _canvas(WHITE)
	_horizontal(image, 10, 4, 30)       # two parallel lines, 4 px apart:
	_horizontal(image, 15, 4, 30)       # their ends point the same way
	_vertical(image, 45, 10, 30)        # a line ending 3 px short of the side
	_horizontal(image, 34, 30, 60)      # of another line (a "T", not a break)
	var result: Dictionary = MetricsLib.measure(image)
	assert_eq(result["line_breaks"], 0)
	assert_true(int(result["line_endpoints"]) >= 6, "the stroke ends themselves are found")


func test_short_marks_and_wide_areas_are_not_strokes() -> void:
	var image: Image = _canvas(WHITE)
	_horizontal(image, 10, 10, 12)      # two 3 px dashes facing each other:
	_horizontal(image, 10, 16, 18)      # shorter than min_stroke_px
	image.fill_rect(Rect2i(10, 30, 20, 20), BLACK)   # two wide dark blocks
	image.fill_rect(Rect2i(33, 30, 20, 20), BLACK)   # 3 px apart
	assert_eq(MetricsLib.measure(image)["line_breaks"], 0)


func test_light_strokes_are_ignored_by_the_dark_threshold() -> void:
	var image: Image = _canvas(WHITE)
	var grey: Color = Color(0.6, 0.6, 0.6)
	_horizontal(image, 8, 4, 24, grey)
	_horizontal(image, 8, 29, 50, grey)
	assert_eq(MetricsLib.measure(image)["line_breaks"], 0)
	var settings: Dictionary = {"line_breaks": {"dark_max_luma": 200}}
	assert_eq(MetricsLib.measure(image, settings)["line_breaks"], 1)


func test_halo_counts_fringe_pixels_of_another_colour() -> void:
	var image: Image = _canvas(CLEAR, 32)
	image.fill_rect(Rect2i(10, 10, 10, 10), RED)
	var soft_red: Color = Color(1.0, 0.0, 0.0, 0.5)
	var soft_white: Color = Color(1.0, 1.0, 1.0, 0.5)
	for y: int in range(10, 20):
		image.set_pixel(9, y, soft_red)      # proper soft edge: same colour
		image.set_pixel(20, y, soft_white)   # leftover white matte: halo
	var result: Dictionary = MetricsLib.measure(image)
	assert_eq(result["halo_px"], 10)
	assert_eq(result["semi_transparent_px"], 20)
	assert_eq(result["has_alpha"], true)


func test_soft_shadow_away_from_opaque_pixels_is_not_halo() -> void:
	var image: Image = _canvas(CLEAR, 32)
	image.fill_rect(Rect2i(4, 4, 6, 6), RED)
	image.fill_rect(Rect2i(20, 20, 6, 6), Color(0.0, 0.0, 0.0, 0.4))
	var result: Dictionary = MetricsLib.measure(image)
	assert_eq(result["halo_px"], 0)
	assert_eq(result["semi_transparent_px"], 36)


func test_colour_counts_skip_transparent_pixels() -> void:
	var image: Image = _canvas(CLEAR, 32)
	image.fill_rect(Rect2i(0, 0, 16, 16), RED)
	image.fill_rect(Rect2i(16, 0, 16, 16), BLACK)
	image.fill_rect(Rect2i(0, 16, 16, 16), WHITE)
	image.fill_rect(Rect2i(16, 16, 8, 16), Color8(10, 200, 30))
	image.fill_rect(Rect2i(24, 16, 4, 16), Color8(11, 200, 30))   # 1 step away
	var result: Dictionary = MetricsLib.measure(image)
	assert_eq(result["colors_exact"], 5)
	assert_eq(result["colors_quantized"], 4, "near-identical colours fall together")


func test_measure_file_reports_unreadable_files() -> void:
	assert_eq(MetricsLib.measure_file("res://tests/unit/does_not_exist.png").size(), 0)


func test_measuring_does_not_change_the_image() -> void:
	var image: Image = Image.create_empty(8, 8, false, Image.FORMAT_RGB8)
	image.fill(RED)
	var before: PackedByteArray = image.get_data()
	MetricsLib.measure(image)
	assert_eq(image.get_format(), Image.FORMAT_RGB8)
	assert_eq(image.get_data(), before)
