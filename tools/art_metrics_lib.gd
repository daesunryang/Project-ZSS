extends RefCounted
## Countable art defects on one image: specks, line breaks, halo pixels and
## colour counts. Pure functions on an Image (measure_file only adds loading).
## Thresholds come from the "metrics" block of art/loop/settings.json
## (docs/19_art_loop.md explains each one). Used by tools/art_metrics.gd,
## tools/art_loop.gd and tests/unit/art_metrics_test.gd.
##
## These numbers only count what a script can count. They say nothing about
## whether the art is good; that is for the reviewers and the user.

const CHANNELS: int = 4
const BYTE_MAX: int = 255
const LUMA_RED: int = 299
const LUMA_GREEN: int = 587
const LUMA_BLUE: int = 114
const LUMA_SCALE: int = 1000
const GROUP_SPECKS: String = "specks"
const GROUP_LINE_BREAKS: String = "line_breaks"
const GROUP_HALO: String = "halo"
const GROUP_COLORS: String = "colors"
## A line break needs at least one empty pixel between the two stroke ends.
const MIN_ENDPOINT_DISTANCE: int = 2
## Neighbour slots tried when walking a stroke: straight ones before diagonal ones.
const WALK_ORDER: PackedInt32Array = [0, 2, 4, 6, 1, 3, 5, 7]
const DEFAULTS: Dictionary = {
	GROUP_SPECKS: {
		"join_tolerance": 24,
		"max_px": 6,
		"min_contrast": 48,
		"ring_max_spread": 16,
	},
	GROUP_LINE_BREAKS: {
		"dark_max_luma": 80,
		"min_alpha": 128,
		"thinning_passes": 3,
		"gap_max_px": 6,
		"min_stroke_px": 6,
		"direction_walk_px": 4,
		"min_alignment": 0.5,
	},
	GROUP_HALO: {
		"transparent_max_alpha": 8,
		"opaque_min_alpha": 247,
		"radius_px": 2,
		"min_color_diff": 48,
	},
	GROUP_COLORS: {
		"quantize_bits": 4,
	},
}


## Returns DEFAULTS with every value present in `overrides` replaced.
static func merged_settings(overrides: Dictionary) -> Dictionary:
	var merged: Dictionary = DEFAULTS.duplicate(true)
	for group: String in merged.keys():
		if not (overrides.get(group) is Dictionary):
			continue
		var group_overrides: Dictionary = overrides[group]
		var group_values: Dictionary = merged[group]
		for key: String in group_values.keys():
			if group_overrides.has(key):
				group_values[key] = group_overrides[key]
	return merged


## Loads an image file and measures it. Returns {} when the file cannot be
## read as an image. The result also carries "file" (the file name).
static func measure_file(path: String, settings: Dictionary = {}) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var image: Image = Image.new()
	if image.load(path) != OK or image.is_empty():
		return {}
	var result: Dictionary = {"file": path.get_file()}
	result.merge(measure(image, settings))
	return result


## Measures one image. `settings` is the "metrics" block (missing values fall
## back to DEFAULTS). Returns counts only; every key is always present.
static func measure(image: Image, settings: Dictionary = {}) -> Dictionary:
	var merged: Dictionary = merged_settings(settings)
	var rgba: Image = image.duplicate() as Image
	if rgba.is_compressed():
		rgba.decompress()
	rgba.convert(Image.FORMAT_RGBA8)
	var width: int = rgba.get_width()
	var height: int = rgba.get_height()
	var straight: PackedByteArray = rgba.get_data()
	var premultiplied: PackedByteArray = _premultiply(straight)
	var specks: Dictionary = count_specks(premultiplied, width, height, merged[GROUP_SPECKS])
	var lines: Dictionary = count_line_breaks(straight, width, height, merged[GROUP_LINE_BREAKS])
	var halo: Dictionary = count_halo(straight, width, height, merged[GROUP_HALO])
	var halo_settings: Dictionary = merged[GROUP_HALO]
	var colors: Dictionary = count_colors(
		straight, int(halo_settings["transparent_max_alpha"]), merged[GROUP_COLORS]
	)
	return {
		"width": width,
		"height": height,
		"has_alpha": rgba.detect_alpha() != Image.ALPHA_NONE,
		"specks": int(specks["count"]),
		"speck_px": int(specks["pixels"]),
		"line_breaks": int(lines["count"]),
		"line_endpoints": int(lines["endpoints"]),
		"halo_px": int(halo["count"]),
		"semi_transparent_px": int(halo["semi_transparent"]),
		"colors_exact": int(colors["exact"]),
		"colors_quantized": int(colors["quantized"]),
	}


## Specks: connected groups (4-neighbour, every pixel within join_tolerance of
## the group's first pixel) of at most max_px pixels whose mean colour differs
## from the ring of pixels around them by min_contrast or more, while that
## ring itself is flat (mean deviation at most ring_max_spread). "Flat ring"
## is what makes the group isolated: a dot on an even area, not a detail
## inside a busy one. Colours are compared premultiplied, so an opaque dot on
## a transparent area counts too.
static func count_specks(data: PackedByteArray, width: int, height: int, settings: Dictionary) -> Dictionary:
	var join_tolerance: int = int(settings["join_tolerance"])
	var max_px: int = int(settings["max_px"])
	var min_contrast: float = float(settings["min_contrast"])
	var ring_max_spread: float = float(settings["ring_max_spread"])
	var total: int = width * height
	var labels: PackedInt32Array = PackedInt32Array()
	labels.resize(total)
	var stack: PackedInt32Array = PackedInt32Array()
	var label: int = 0
	var count: int = 0
	var pixels: int = 0
	for first: int in range(total):
		if labels[first] != 0:
			continue
		label += 1
		labels[first] = label
		var first_offset: int = first * CHANNELS
		var red: int = data[first_offset]
		var green: int = data[first_offset + 1]
		var blue: int = data[first_offset + 2]
		var alpha: int = data[first_offset + 3]
		var members: PackedInt32Array = PackedInt32Array([first])
		var size: int = 1
		var stack_size: int = 0
		if stack.is_empty():
			stack.append(first)
		else:
			stack[0] = first
		stack_size = 1
		while stack_size > 0:
			stack_size -= 1
			var index: int = stack[stack_size]
			var x: int = index % width
			for step: int in range(4):
				var neighbour: int = -1
				match step:
					0:
						if x > 0:
							neighbour = index - 1
					1:
						if x < width - 1:
							neighbour = index + 1
					2:
						if index >= width:
							neighbour = index - width
					3:
						if index + width < total:
							neighbour = index + width
				if neighbour < 0 or labels[neighbour] != 0:
					continue
				var offset: int = neighbour * CHANNELS
				if (
					absi(data[offset] - red) > join_tolerance
					or absi(data[offset + 1] - green) > join_tolerance
					or absi(data[offset + 2] - blue) > join_tolerance
					or absi(data[offset + 3] - alpha) > join_tolerance
				):
					continue
				labels[neighbour] = label
				size += 1
				if size <= max_px:
					members.append(neighbour)
				if stack_size < stack.size():
					stack[stack_size] = neighbour
				else:
					stack.append(neighbour)
				stack_size += 1
		if size > max_px:
			continue
		if _is_speck(data, width, height, labels, label, members, min_contrast, ring_max_spread):
			count += 1
			pixels += size
	return {"count": count, "pixels": pixels}


static func _is_speck(
	data: PackedByteArray,
	width: int,
	height: int,
	labels: PackedInt32Array,
	label: int,
	members: PackedInt32Array,
	min_contrast: float,
	ring_max_spread: float
) -> bool:
	var ring: Dictionary = {}
	for index: int in members:
		var x: int = index % width
		@warning_ignore("integer_division")
		var y: int = index / width
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				var nx: int = x + dx
				var ny: int = y + dy
				if nx < 0 or ny < 0 or nx >= width or ny >= height:
					continue
				var neighbour: int = ny * width + nx
				if labels[neighbour] != label:
					ring[neighbour] = true
	if ring.is_empty():
		return false
	var ring_indices: PackedInt32Array = PackedInt32Array(ring.keys())
	var member_mean: PackedFloat32Array = _mean_color(data, members)
	var ring_mean: PackedFloat32Array = _mean_color(data, ring_indices)
	var contrast: float = 0.0
	var spread: float = 0.0
	for channel: int in range(CHANNELS):
		contrast = maxf(contrast, absf(member_mean[channel] - ring_mean[channel]))
		var deviation: float = 0.0
		for index: int in ring_indices:
			deviation += absf(float(data[index * CHANNELS + channel]) - ring_mean[channel])
		spread = maxf(spread, deviation / float(ring_indices.size()))
	return contrast >= min_contrast and spread <= ring_max_spread


static func _mean_color(data: PackedByteArray, indices: PackedInt32Array) -> PackedFloat32Array:
	var mean: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for index: int in indices:
		for channel: int in range(CHANNELS):
			mean[channel] += float(data[index * CHANNELS + channel])
	for channel: int in range(CHANNELS):
		mean[channel] /= float(indices.size())
	return mean


## Line breaks: dark pixels (luma at most dark_max_luma, alpha at least
## min_alpha) are thinned towards one-pixel strokes (Zhang-Suen, at most
## thinning_passes passes, so wide dark areas stay areas). A stroke end is a
## thinned pixel with exactly one neighbour on a stroke at least min_stroke_px
## long. A break is a pair of ends with 1..gap_max_px empty pixels between
## them that point at each other (cosine at least min_alignment). Each end is
## used once, closest pairs first.
static func count_line_breaks(data: PackedByteArray, width: int, height: int, settings: Dictionary) -> Dictionary:
	var dark_max_luma: int = int(settings["dark_max_luma"])
	var min_alpha: int = int(settings["min_alpha"])
	var passes: int = int(settings["thinning_passes"])
	var gap_max: int = int(settings["gap_max_px"])
	var min_stroke: int = int(settings["min_stroke_px"])
	var walk: int = maxi(1, int(settings["direction_walk_px"]))
	var min_alignment: float = float(settings["min_alignment"])
	# The mask has a one-pixel empty border so neighbour reads need no bounds checks.
	var padded_width: int = width + 2
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(padded_width * (height + 2))
	var active: PackedInt32Array = PackedInt32Array()
	for y: int in range(height):
		for x: int in range(width):
			var offset: int = (y * width + x) * CHANNELS
			if data[offset + 3] < min_alpha:
				continue
			@warning_ignore("integer_division")
			var luma: int = (
				(data[offset] * LUMA_RED + data[offset + 1] * LUMA_GREEN + data[offset + 2] * LUMA_BLUE)
				/ LUMA_SCALE
			)
			if luma > dark_max_luma:
				continue
			var mask_index: int = (y + 1) * padded_width + x + 1
			mask[mask_index] = 1
			active.append(mask_index)
	# Clockwise from north: P2..P9 of the Zhang-Suen paper.
	var around: PackedInt32Array = PackedInt32Array([
		-padded_width, -padded_width + 1, 1, padded_width + 1,
		padded_width, padded_width - 1, -1, -padded_width - 1,
	])
	_thin(mask, active, around, passes)

	var ends: Array[Vector2i] = []
	var directions: Array[Vector2] = []
	for mask_index: int in active:
		if mask[mask_index] == 0 or _neighbour_count(mask, mask_index, around) != 1:
			continue
		var direction: Vector2 = _stroke_direction(mask, padded_width, around, mask_index, walk, min_stroke)
		if direction == Vector2.ZERO:
			continue
		@warning_ignore("integer_division")
		ends.append(Vector2i(mask_index % padded_width, mask_index / padded_width))
		directions.append(direction)
	return {"count": _pair_ends(ends, directions, gap_max, min_alignment), "endpoints": ends.size()}


static func _neighbour_count(mask: PackedByteArray, index: int, around: PackedInt32Array) -> int:
	var count: int = 0
	for offset: int in around:
		count += mask[index + offset]
	return count


static func _thin(mask: PackedByteArray, active: PackedInt32Array, around: PackedInt32Array, passes: int) -> void:
	var north: int = around[0]
	var east: int = around[2]
	var south: int = around[4]
	var west: int = around[6]
	for _pass: int in range(passes):
		var changed: bool = false
		for half: int in range(2):
			var cleared: PackedInt32Array = PackedInt32Array()
			for index: int in active:
				if mask[index] == 0:
					continue
				var p2: int = mask[index + north]
				var p4: int = mask[index + east]
				var p6: int = mask[index + south]
				var p8: int = mask[index + west]
				if half == 0:
					if p2 * p4 * p6 != 0 or p4 * p6 * p8 != 0:
						continue
				elif p2 * p4 * p8 != 0 or p2 * p6 * p8 != 0:
					continue
				var filled: int = 0
				var transitions: int = 0
				var previous: int = mask[index + around[7]]
				for offset: int in around:
					var value: int = mask[index + offset]
					filled += value
					if previous == 0 and value == 1:
						transitions += 1
					previous = value
				if filled < 2 or filled > 6 or transitions != 1:
					continue
				cleared.append(index)
			for index: int in cleared:
				mask[index] = 0
			if not cleared.is_empty():
				changed = true
		if not changed:
			return


## Walks from a stroke end back along the stroke. Returns the unit direction
## the stroke points in at its end, or ZERO when the stroke is shorter than
## `min_stroke` pixels.
static func _stroke_direction(
	mask: PackedByteArray,
	padded_width: int,
	around: PackedInt32Array,
	start: int,
	walk: int,
	min_stroke: int
) -> Vector2:
	var visited: Dictionary = {start: true}
	var current: int = start
	var anchor: int = start
	var length: int = 1
	var wanted: int = maxi(walk + 1, min_stroke)
	while length < wanted:
		var next: int = -1
		# Straight neighbours first (even slots), so staircases are followed
		# pixel by pixel instead of being cut diagonally.
		for slot: int in WALK_ORDER:
			var candidate: int = current + around[slot]
			if mask[candidate] == 1 and not visited.has(candidate):
				next = candidate
				break
		if next < 0:
			break
		visited[next] = true
		current = next
		length += 1
		if length <= walk + 1:
			anchor = current
	if length < min_stroke or anchor == start:
		return Vector2.ZERO
	@warning_ignore("integer_division")
	var from: Vector2 = Vector2(anchor % padded_width, anchor / padded_width)
	@warning_ignore("integer_division")
	var to: Vector2 = Vector2(start % padded_width, start / padded_width)
	return (to - from).normalized()


static func _pair_ends(ends: Array[Vector2i], directions: Array[Vector2], gap_max: int, min_alignment: float) -> int:
	var reach: int = gap_max + 1
	var buckets: Dictionary = {}
	for i: int in range(ends.size()):
		@warning_ignore("integer_division")
		var cell: Vector2i = Vector2i(ends[i].x / reach, ends[i].y / reach)
		if not buckets.has(cell):
			buckets[cell] = PackedInt32Array()
		var bucket: PackedInt32Array = buckets[cell]
		bucket.append(i)
		buckets[cell] = bucket
	var candidates: Array[Vector3i] = []
	for i: int in range(ends.size()):
		@warning_ignore("integer_division")
		var cell: Vector2i = Vector2i(ends[i].x / reach, ends[i].y / reach)
		for cy: int in range(cell.y - 1, cell.y + 2):
			for cx: int in range(cell.x - 1, cell.x + 2):
				var bucket: PackedInt32Array = buckets.get(Vector2i(cx, cy), PackedInt32Array())
				for j: int in bucket:
					if j <= i:
						continue
					var delta: Vector2i = ends[j] - ends[i]
					# Counted in pixel steps (diagonal steps count as one), so a
					# gap is as wide on a slanted stroke as on a level one.
					var steps: int = maxi(absi(delta.x), absi(delta.y))
					if steps < MIN_ENDPOINT_DISTANCE or steps > reach:
						continue
					var distance_squared: int = delta.length_squared()
					var toward: Vector2 = Vector2(delta).normalized()
					if directions[i].dot(toward) < min_alignment or directions[j].dot(-toward) < min_alignment:
						continue
					candidates.append(Vector3i(distance_squared, i, j))
	candidates.sort()
	var used: Dictionary = {}
	var pairs: int = 0
	for candidate: Vector3i in candidates:
		if used.has(candidate.y) or used.has(candidate.z):
			continue
		used[candidate.y] = true
		used[candidate.z] = true
		pairs += 1
	return pairs


## Halo (fringe) pixels: half-transparent pixels (alpha between
## transparent_max_alpha and opaque_min_alpha) that sit within radius_px of
## opaque pixels yet differ from every one of those opaque pixels by
## min_color_diff or more in some colour channel. Proper anti-aliasing keeps
## the colour of the edge it softens; a leftover white or black matte does
## not. Half-transparent pixels with no opaque pixel nearby (soft shadows,
## glows) are not counted.
static func count_halo(data: PackedByteArray, width: int, height: int, settings: Dictionary) -> Dictionary:
	var transparent_max: int = int(settings["transparent_max_alpha"])
	var opaque_min: int = int(settings["opaque_min_alpha"])
	var radius: int = int(settings["radius_px"])
	var min_diff: int = int(settings["min_color_diff"])
	var count: int = 0
	var semi_transparent: int = 0
	for y: int in range(height):
		for x: int in range(width):
			var offset: int = (y * width + x) * CHANNELS
			var alpha: int = data[offset + 3]
			if alpha <= transparent_max or alpha >= opaque_min:
				continue
			semi_transparent += 1
			var red: int = data[offset]
			var green: int = data[offset + 1]
			var blue: int = data[offset + 2]
			var opaque_seen: bool = false
			var matched: bool = false
			for ny: int in range(maxi(0, y - radius), mini(height, y + radius + 1)):
				for nx: int in range(maxi(0, x - radius), mini(width, x + radius + 1)):
					var other: int = (ny * width + nx) * CHANNELS
					if data[other + 3] < opaque_min:
						continue
					opaque_seen = true
					if (
						absi(data[other] - red) < min_diff
						and absi(data[other + 1] - green) < min_diff
						and absi(data[other + 2] - blue) < min_diff
					):
						matched = true
						break
				if matched:
					break
			if opaque_seen and not matched:
				count += 1
	return {"count": count, "semi_transparent": semi_transparent}


## Colour counts over visible pixels (alpha above transparent_max_alpha):
## exact RGBA values, and RGB reduced to quantize_bits per channel (steadier
## on shaded or rendered images).
static func count_colors(data: PackedByteArray, transparent_max: int, settings: Dictionary) -> Dictionary:
	var shift: int = 8 - clampi(int(settings["quantize_bits"]), 1, 8)
	var exact: Dictionary = {}
	var quantized: Dictionary = {}
	@warning_ignore("integer_division")
	var total: int = data.size() / CHANNELS
	for index: int in range(total):
		var offset: int = index * CHANNELS
		var alpha: int = data[offset + 3]
		if alpha <= transparent_max:
			continue
		var red: int = data[offset]
		var green: int = data[offset + 1]
		var blue: int = data[offset + 2]
		exact[(red << 24) | (green << 16) | (blue << 8) | alpha] = true
		quantized[((red >> shift) << 16) | ((green >> shift) << 8) | (blue >> shift)] = true
	return {"exact": exact.size(), "quantized": quantized.size()}


static func _premultiply(data: PackedByteArray) -> PackedByteArray:
	var result: PackedByteArray = data.duplicate()
	@warning_ignore("integer_division")
	var total: int = data.size() / CHANNELS
	for index: int in range(total):
		var offset: int = index * CHANNELS
		var alpha: int = data[offset + 3]
		if alpha == BYTE_MAX:
			continue
		for channel: int in range(3):
			@warning_ignore("integer_division")
			result[offset + channel] = data[offset + channel] * alpha / BYTE_MAX
	return result
