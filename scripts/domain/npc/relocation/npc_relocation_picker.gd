class_name NpcRelocationPicker
extends RefCounted
## Chooses the building an NPC moves to (F-30, docs/09 §17.15). Pure: the
## lists of the cells' buildings and the `Query` give the same building
## every time, whatever was planned or cached before. No random number.
##
## A candidate is a generated building an NPC can live in
## (NpcHomePicker.is_home: a home tile, a bed, water, a container) that
##   - is not its own home, and not taken (the home of another NPC, or the
##     destination of another NPC's move);
##   - it does not remember as emptied or, lately, as unreachable (`skip`);
##   - it does not remember as too dangerous (the danger at its middle is
##     below `danger_limit`);
##   - stands between `min_distance_m` and `max_distance_m` from `anchor`
##     (the middle of its home).
## The cheapest candidate wins; ties go to the smaller building id. Cost,
## in metres:
##     the distance from `origin` (where the NPC stands)
##   + danger at its middle x danger_cost_m
##   + other_type_cost_m when it is not a house
##   - prospect_bonus_m x the buildings with a container around it (its own
##     cell and the eight around it; itself not counted) that are neither
##     taken nor in `skip`, at most prospect_cap.
## Without a candidate: its own home when `allow_return`, otherwise "".

const KEY_ID: String = "id"
const KEY_CENTER: String = "center"
const KEY_TYPE: String = "type"
## In an entry of a list made for a move: true when an NPC can live there.
const KEY_LIVABLE: String = "livable"
const NEIGHBOUR_CELLS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]


## What one choice needs to know.
class Query:
	extends RefCounted
	## Where the NPC stands, and the middle of its home.
	var origin: Vector3 = Vector3.ZERO
	var anchor: Vector3 = Vector3.ZERO
	var min_distance_m: float = 0.0
	var max_distance_m: float = 0.0
	var home_building_id: String = ""
	var allow_return: bool = false
	## {building_id: anything}: buildings somebody lives in or moves to.
	var taken: Dictionary = {}
	## {building_id: anything}: buildings it remembers as emptied or blocked.
	var skip: Dictionary = {}
	## [[Vector3 place, float weight]]: what it remembers as dangerous.
	var danger_sources: Array[Array] = []
	var danger_radius_m: float = 1.0
	var danger_limit: float = INF
	var danger_cost_m: float = 0.0
	var house_types: PackedStringArray = []
	var other_type_cost_m: float = 0.0
	var prospect_bonus_m: float = 0.0
	var prospect_cap: int = 0


## Diagnostics of the last choose().
var last_cell_count: int = 0
var last_building_count: int = 0
var last_candidate_count: int = 0
var last_avoided_count: int = 0
var last_cost_m: float = 0.0


## The building to move to ("" = none). `cells`: the cells to look at.
## `buildings_of`: (cell: Vector2i) -> Array of {id, center, type} of the
## cell's generated buildings that have a container. `is_livable`:
## (entry: Dictionary) -> bool.
func choose(cells: Array[Vector2i], buildings_of: Callable, is_livable: Callable, query: Query) -> String:
	last_cell_count = cells.size()
	last_building_count = 0
	last_candidate_count = 0
	last_avoided_count = 0
	last_cost_m = 0.0
	# Per cell: its buildings, and how many of them are worth a search.
	var lists: Dictionary[Vector2i, Array] = {}
	var prospects: Dictionary[Vector2i, int] = {}
	for cell: Vector2i in cells:
		var listed: Array = buildings_of.call(cell)
		lists[cell] = listed
		var count: int = 0
		for entry: Dictionary in listed:
			var id: String = str(entry[KEY_ID])
			if id != query.home_building_id and not query.taken.has(id) and not query.skip.has(id):
				count += 1
		prospects[cell] = count
		last_building_count += listed.size()
	var best_id: String = ""
	var best_cost: float = INF
	for cell: Vector2i in cells:
		var around: int = -1
		for entry: Dictionary in lists[cell]:
			var id: String = str(entry[KEY_ID])
			if id == query.home_building_id or query.taken.has(id) or query.skip.has(id):
				continue
			var center: Vector3 = entry[KEY_CENTER]
			var from_anchor: float = _flat_distance(center, query.anchor)
			if from_anchor < query.min_distance_m or from_anchor > query.max_distance_m:
				continue
			if not bool(is_livable.call(entry)):
				continue
			last_candidate_count += 1
			var danger: float = danger_at(center, query)
			if danger >= query.danger_limit:
				last_avoided_count += 1
				continue
			if around < 0:
				around = 0
				for offset: Vector2i in NEIGHBOUR_CELLS:
					around += int(prospects.get(cell + offset, 0))
			# Itself is one of the buildings counted around it.
			var cost: float = _flat_distance(center, query.origin) + danger * query.danger_cost_m - float(mini(maxi(around - 1, 0), query.prospect_cap)) * query.prospect_bonus_m
			if not query.house_types.has(str(entry.get(KEY_TYPE, ""))):
				cost += query.other_type_cost_m
			if cost < best_cost or (cost == best_cost and id < best_id):
				best_cost = cost
				best_id = id
	if best_id.is_empty():
		return query.home_building_id if query.allow_return else ""
	last_cost_m = best_cost
	return best_id


## The danger an NPC remembers at a place: the sum over the sources within
## danger_radius_m of weight x nearness (as NpcSurvivalSense.danger_at).
static func danger_at(place: Vector3, query: Query) -> float:
	var total: float = 0.0
	for source: Array in query.danger_sources:
		var distance: float = _flat_distance(source[0] as Vector3, place)
		if distance < query.danger_radius_m:
			total += float(source[1]) * (1.0 - distance / query.danger_radius_m)
	return total


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
