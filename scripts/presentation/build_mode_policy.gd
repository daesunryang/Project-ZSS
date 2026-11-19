class_name BuildModePolicy
extends RefCounted
## Pure client-side geometry for build previews and structure targeting.
## Results are suggestions only; BuildingService remains authoritative.

const NO_HIT: Dictionary = {"hit": false}
const AIM_SAMPLE_STEP_FRACTION: float = 0.25
const AIM_RANGE_EPSILON_M: float = 0.0001


static func ground_hit(ray_origin: Vector3, ray_direction: Vector3, ground_y: float, ray_length_m: float) -> Variant:
	if not ray_origin.is_finite() or not ray_direction.is_finite() or ray_length_m <= 0.0:
		return null
	var direction: Vector3 = ray_direction.normalized()
	if direction.is_zero_approx() or is_zero_approx(direction.y):
		return null
	var distance: float = (ground_y - ray_origin.y) / direction.y
	if distance < 0.0 or distance > ray_length_m:
		return null
	return ray_origin + direction * distance


## Picks the grid slot nearest the ground point under the centre ray while
## keeping its anchor in placement range and off the tile/edges occupied by
## the local player. This only moves the client ghost; the server still owns
## placement validation.
static func aimed_placement(ray_origin: Vector3, ray_direction: Vector3, ground_y: float, ray_length_m: float, player_position: Vector3, placement_range_m: float, definition: StructureDefinition, grid: StructureGrid, rotation_steps: int) -> Dictionary:
	if definition == null or grid == null or placement_range_m <= 0.0 or not player_position.is_finite():
		return NO_HIT
	var hit: Variant = ground_hit(ray_origin, ray_direction, ground_y, ray_length_m)
	if not hit is Vector3:
		return NO_HIT
	var ground_point: Vector3 = hit as Vector3
	var flat_aim: Vector2 = Vector2(ground_point.x - player_position.x, ground_point.z - player_position.z)
	if flat_aim.is_zero_approx():
		flat_aim = Vector2(ray_direction.x, ray_direction.z)
	if flat_aim.is_zero_approx():
		return NO_HIT
	var forward: Vector2 = flat_aim.normalized()
	var preferred_distance: float = minf(flat_aim.length(), placement_range_m)
	var step_m: float = maxf(grid.module_m * AIM_SAMPLE_STEP_FRACTION, AIM_RANGE_EPSILON_M)
	var step_count: int = ceili(placement_range_m / step_m) + 1
	var candidate: Dictionary = _placement_at_distance(player_position, ground_y, forward, preferred_distance, definition, grid, rotation_steps)
	if _candidate_fits_aim(candidate, definition, grid, player_position, placement_range_m):
		return candidate
	# Search nearest to the intended point. A far intersection searches back
	# toward the player; an intersection on the player searches forward.
	for index: int in range(1, step_count + 1):
		var delta_m: float = float(index) * step_m
		var inward_distance: float = preferred_distance - delta_m
		if inward_distance >= 0.0:
			candidate = _placement_at_distance(player_position, ground_y, forward, inward_distance, definition, grid, rotation_steps)
			if _candidate_fits_aim(candidate, definition, grid, player_position, placement_range_m):
				return candidate
		var outward_distance: float = preferred_distance + delta_m
		if outward_distance <= placement_range_m:
			candidate = _placement_at_distance(player_position, ground_y, forward, outward_distance, definition, grid, rotation_steps)
			if _candidate_fits_aim(candidate, definition, grid, player_position, placement_range_m):
				return candidate
	return NO_HIT


static func _placement_at_distance(player_position: Vector3, ground_y: float, forward: Vector2, distance_m: float, definition: StructureDefinition, grid: StructureGrid, rotation_steps: int) -> Dictionary:
	var point: Vector3 = Vector3(
		player_position.x + forward.x * distance_m,
		ground_y,
		player_position.z + forward.y * distance_m
	)
	return placement_at(point, definition, grid, rotation_steps)


static func _candidate_fits_aim(candidate: Dictionary, definition: StructureDefinition, grid: StructureGrid, player_position: Vector3, placement_range_m: float) -> bool:
	if candidate.is_empty() or not bool(candidate.get("hit", false)):
		return false
	var anchor: Vector3 = candidate["anchor"]
	if StructureGrid.flat_distance(player_position, anchor) > placement_range_m + AIM_RANGE_EPSILON_M:
		return false
	var player_tile: Vector2i = grid.tile_of(player_position)
	if not definition.is_edge():
		return candidate["tile"] != player_tile
	var slot: Vector3i = candidate["slot"]
	for rotation: int in range(StructureGrid.ROTATION_COUNT):
		if slot == StructureGrid.slot_of(StructureDefinition.Placement.EDGE, player_tile, rotation):
			return false
	return true


## Placement at a ground point. Edge pieces start at the nearest edge; each
## rotation step advances to the next edge clockwise.
static func placement_at(hit: Vector3, definition: StructureDefinition, grid: StructureGrid, rotation_steps: int) -> Dictionary:
	if definition == null or grid == null or not hit.is_finite():
		return NO_HIT
	var tile: Vector2i = grid.tile_of(hit)
	var rotation: int = posmod(rotation_steps, StructureGrid.ROTATION_COUNT)
	if definition.is_edge():
		var low: Vector3 = Vector3(float(tile.x) * grid.module_m, hit.y, float(tile.y) * grid.module_m)
		var local: Vector2 = Vector2(hit.x - low.x, hit.z - low.z)
		var distances: Array[float] = [local.y, grid.module_m - local.x, grid.module_m - local.y, local.x]
		var nearest: int = 0
		for side: int in range(1, distances.size()):
			if distances[side] < distances[nearest]:
				nearest = side
		rotation = posmod(nearest + rotation_steps, StructureGrid.ROTATION_COUNT)
	var slot: Vector3i = StructureGrid.slot_of(definition.placement, tile, rotation)
	return {"hit": true, "tile": tile, "rotation": rotation, "slot": slot, "anchor": grid.slot_anchor(slot)}


static func preview_is_valid(candidate: Dictionary, mirror: ClientStructureState, player_position: Vector3, bounds_min: Vector2, bounds_max: Vector2, placement_range_m: float, module_m: float) -> bool:
	if candidate.is_empty() or not bool(candidate.get("hit", false)) or mirror == null:
		return false
	var tile: Vector2i = candidate["tile"]
	var low: Vector2 = Vector2(float(tile.x) * module_m, float(tile.y) * module_m)
	var high: Vector2 = low + Vector2.ONE * module_m
	if low.x < bounds_min.x or low.y < bounds_min.y or high.x > bounds_max.x or high.y > bounds_max.y:
		return false
	if not mirror.structure_id_at(candidate["slot"]).is_empty():
		return false
	return StructureGrid.flat_distance(player_position, candidate["anchor"]) <= placement_range_m


## Structure closest to the camera ray inside `reach_m`. The target radius
## is presentation-only; the server checks the actual action range again.
static func target_structure(ray_origin: Vector3, ray_direction: Vector3, player_position: Vector3, mirror: ClientStructureState, grid: StructureGrid, ray_length_m: float, reach_m: float, target_radius_m: float) -> String:
	if mirror == null or grid == null or reach_m <= 0.0 or target_radius_m <= 0.0:
		return ""
	var direction: Vector3 = ray_direction.normalized()
	var best_id: String = ""
	var best_along: float = INF
	for structure_id: String in mirror.structure_ids():
		var anchor: Vector3 = grid.slot_anchor(mirror.slot_of(structure_id))
		var relative: Vector3 = anchor - ray_origin
		var along: float = relative.dot(direction)
		if along < 0.0 or along > ray_length_m or along >= best_along:
			continue
		if StructureGrid.flat_distance(player_position, anchor) > reach_m:
			continue
		if (relative - direction * along).length() <= target_radius_m:
			best_id = structure_id
			best_along = along
	return best_id
