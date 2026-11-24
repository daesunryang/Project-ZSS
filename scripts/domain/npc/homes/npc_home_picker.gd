class_name NpcHomePicker
extends RefCounted
## Chooses the generated building one NPC lives in (F-28, docs/09 §17.13).
## Pure: the generator (so the world seed), the settings, the label of the
## NPC (its definition id) and the buildings that are taken already give the
## same building every time, so a world places its NPCs the same way
## whenever it is asked, and an NPC that joins a roster later does not move
## the others.
##
## The rules:
##   - one NPC per building: a building in `taken` is never chosen;
##   - houses first (NpcHomeSettings.home_building_types); only when no
##     such building is found, any building. A building must have a valid
##     NpcHomeLayout and at least one container;
##   - spread: `countryside_per_mille` of the NPCs live outside every town
##     (a building in a cell beside a road between towns). The others go to
##     the town that has the fewest NPCs so far (ties: an order drawn from
##     the label), so ten NPCs never share one town while others are empty;
##   - bounded: a town is searched by looking at `cell_attempts` of its
##     cells, the countryside by looking at `cell_attempts` cells along the
##     roads. Nothing plans the whole map.

## Hex digits of a hash used as a seed: 60 bits, always a positive int.
const SEED_HEX_DIGITS: int = 15
const PER_MILLE: int = 1000

## Diagnostics of the last pick(): cells whose plan was asked for.
var last_planned_cell_count: int = 0

var _generator: ProceduralMapGenerator
var _settings: NpcHomeSettings


func _init(generator: ProceduralMapGenerator, settings: NpcHomeSettings) -> void:
	_generator = generator
	_settings = settings if settings != null else NpcHomeSettings.new()


## The building for the NPC `label`, or null when the map has no free
## building for it. `taken`: {building_id: anything} of the homes of the
## NPCs before it.
func pick(label: String, taken: Dictionary) -> ProceduralBuilding:
	last_planned_cell_count = 0
	if _generator == null or not _generator.is_usable():
		return null
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = ("f28|home|%d|%s" % [_generator.world_seed, label]).sha256_text().substr(0, SEED_HEX_DIGITS).hex_to_int()
	var towns: Array[Dictionary] = _generator.towns()
	var per_town: Dictionary[int, int] = {}
	var rural_count: int = 0
	for building_id: Variant in taken:
		var parsed: Dictionary = ProceduralMapGenerator.parse_building_id(str(building_id))
		var town: int = _generator.town_of(parsed[ProceduralMapGenerator.KEY_PARSED_CELL] as Vector2i) if not parsed.is_empty() else -1
		if town < 0:
			rural_count += 1
		else:
			per_town[town] = int(per_town.get(town, 0)) + 1
	# The share is kept exactly: with 300 of a thousand, the 4th, 7th and
	# 10th NPC live in the countryside.
	var rural: bool = (rural_count + 1) * PER_MILLE <= (taken.size() + 1) * _settings.countryside_per_mille
	for houses_only: bool in [true, false]:
		var found: ProceduralBuilding = null
		if rural or towns.is_empty():
			found = _find_rural(rng, taken, houses_only)
		if found == null:
			found = _find_in_towns(rng, towns, per_town, taken, houses_only)
		if found == null and not rural:
			found = _find_rural(rng, taken, houses_only)
		if found != null:
			return found
	return null


## True when an NPC can live in this building at all.
static func is_home(building: ProceduralBuilding) -> bool:
	return building != null and building.definition != null and not building.definition.containers.is_empty() and NpcHomeLayout.of(building.definition).is_valid()


# ------------------------------------------------------------ internals

## The towns, fewest NPCs first; among equals in an order drawn from `rng`.
func _find_in_towns(rng: RandomNumberGenerator, towns: Array[Dictionary], per_town: Dictionary[int, int], taken: Dictionary, houses_only: bool) -> ProceduralBuilding:
	var order: Array[Array] = []
	for town: Dictionary in towns:
		var index: int = int(town[ProceduralMapGenerator.KEY_TOWN_INDEX])
		order.append([int(per_town.get(index, 0)), rng.randi(), index])
	order.sort_custom(func(a: Array, b: Array) -> bool:
		if int(a[0]) != int(b[0]):
			return int(a[0]) < int(b[0])
		return int(a[1]) < int(b[1]) if int(a[1]) != int(b[1]) else int(a[2]) < int(b[2]))
	for entry: Array in order:
		var found: ProceduralBuilding = _find_in_town(rng, towns[int(entry[2])], taken, houses_only)
		if found != null:
			return found
	return null


func _find_in_town(rng: RandomNumberGenerator, town: Dictionary, taken: Dictionary, houses_only: bool) -> ProceduralBuilding:
	var corner: Vector2i = town[ProceduralMapGenerator.KEY_TOWN_CORNER]
	var index: int = int(town[ProceduralMapGenerator.KEY_TOWN_INDEX])
	var radius_cells: int = _radius_cells(float(town[ProceduralMapGenerator.KEY_TOWN_RADIUS_M]))
	for _attempt: int in range(_settings.cell_attempts):
		var cell: Vector2i = corner + Vector2i(rng.randi_range(-radius_cells, radius_cells - 1), rng.randi_range(-radius_cells, radius_cells - 1))
		if _generator.cell_kind(cell) != ProceduralMapGenerator.CellKind.TOWN or _generator.town_of(cell) != index:
			continue
		var found: ProceduralBuilding = _pick_in_cell(rng, cell, taken, houses_only)
		if found != null:
			return found
	return null


## A building in a cell beside a road between towns; without roads, in any
## cell outside the towns.
func _find_rural(rng: RandomNumberGenerator, taken: Dictionary, houses_only: bool) -> ProceduralBuilding:
	var roads: Array[Dictionary] = _generator.roads()
	var low: Vector2i = _generator.min_cell()
	var high: Vector2i = _generator.max_cell()
	for _attempt: int in range(_settings.cell_attempts):
		var cell: Vector2i = Vector2i.ZERO
		if roads.is_empty():
			cell = Vector2i(rng.randi_range(low.x, high.x), rng.randi_range(low.y, high.y))
		else:
			var road: Dictionary = roads[rng.randi_range(0, roads.size() - 1)]
			var from: Vector2i = road[ProceduralMapGenerator.KEY_ROAD_FROM]
			var to: Vector2i = road[ProceduralMapGenerator.KEY_ROAD_TO]
			var side: int = rng.randi_range(-1, 0)
			if from.y == to.y:
				cell = Vector2i(rng.randi_range(mini(from.x, to.x), maxi(from.x, to.x) - 1), from.y + side)
			else:
				cell = Vector2i(from.x + side, rng.randi_range(mini(from.y, to.y), maxi(from.y, to.y) - 1))
		var kind: int = _generator.cell_kind(cell)
		if kind != ProceduralMapGenerator.CellKind.ROADSIDE and kind != ProceduralMapGenerator.CellKind.WILD:
			continue
		var found: ProceduralBuilding = _pick_in_cell(rng, cell, taken, houses_only)
		if found != null:
			return found
	return null


## One of the free buildings of a cell an NPC can live in, or null.
func _pick_in_cell(rng: RandomNumberGenerator, cell: Vector2i, taken: Dictionary, houses_only: bool) -> ProceduralBuilding:
	last_planned_cell_count += 1
	var free: Array[ProceduralBuilding] = []
	for building: ProceduralBuilding in _generator.plan_cell(cell).buildings:
		if taken.has(building.building_id()) or not is_home(building):
			continue
		if houses_only and not _settings.home_building_types.has(building.definition.building_type):
			continue
		free.append(building)
	return free[rng.randi_range(0, free.size() - 1)] if not free.is_empty() else null


func _radius_cells(radius_m: float) -> int:
	return maxi(ceili(radius_m / _generator.cell_size_m()), 1)
