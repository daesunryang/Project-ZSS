class_name NpcScavenging
extends RefCounted
## The scavenging trip of an NPC that lives alone (F-29, docs/09 §17.14):
## what the action "scavenge" does. A helper of NpcBehaviours, which owns
## the action's step and timer, walks the NPC (NpcExecutor.begin_move) and
## reports to the decision layer; this class chooses the building, searches
## its containers, takes what is useful, and puts the surplus away at home.
##
## One trip:
##   1. An NPC that carries loot of a trip that was cut short walks home
##      and puts it away; that is the whole trip.
##   2. Otherwise a building is chosen (pick_target): its own home the
##      first time (what its containers hold besides food: a bandage, a
##      weapon), then the nearest generated building around its home that
##      it has not emptied and does not remember as dangerous.
##   3. It walks to each container of the building that is in memory, in
##      the order of the building's placements, searches it for
##      search_duration_sec (the container's loot is rolled as a player's
##      first search would roll it, ContainerService.search_now) and takes
##      what it can use and carry: treatments first, then a better weapon
##      than the one it carries (the old one is left in the container),
##      then food and drinks, but only as many units as it still wants
##      (NpcSurvivalSense.wanted_food / wanted_drinks: it does not empty
##      the neighbourhood). From its own home it takes only treatments and
##      a weapon: the food stays where it eats.
##   4. The building is written down (NpcScavengeState.visited): "empty",
##      or "left" when food or drinks stayed behind (it wanted or could
##      carry no more).
##   5. It walks home, stays stow_duration_sec and puts food, drinks and
##      spare weapons into the containers of its home. It keeps its best
##      weapon and its treatments on it.
## A building it finds no way to is written down as "blocked" and tried
## again after blocked_forget_days.
##
## Which buildings: generated buildings with at least one container whose
## middle is within radius_m of the middle of its home, in a cell that is
## simulated and completely built (an NPC never goes where the world is not
## running, and never builds a cell itself). Not its home, not the home of
## another NPC of the roster, not one it emptied, not one it remembers as
## too dangerous (NpcSurvivalSense.danger_at >= danger_limit). A building
## it left food or drinks in is searched again only while it wants food or
## drinks. The nearest
## to where it stands wins, every unit of danger counting as danger_cost_m;
## ties go to the smaller building id.
##
## Cost: the buildings of a cell are listed from the generator's plan of
## the cell (about 0.1 ms a cell, up to 0.5 ms) and kept. So that the first
## choice of a neighbourhood does not plan a dozen cells in one tick, the
## cells around the home of an NPC that wakes are queued and planned one
## per tick (queue_cells_of / warm_one). A choice plans whatever is still
## missing, so what is chosen never depends on what was planned before.
##
## Everything a trip is in the middle of is in the NPC's components
## (NpcScavengeState, NpcBehaviourState, NpcExecutorState): a trip goes on
## after a restart and after the NPC's cell left memory.

## begin() / a step could not go on: there is no building to search.
const FAIL_NO_TARGET: String = "no_target"
## What a step of the trip tells NpcBehaviours.
const STEP_CONTINUES: String = ""
const STEP_DONE: String = "done"
## Keys of the info of a finished trip.
const INFO_BUILDING: String = "building_id"
const INFO_TAKEN: String = "taken_units"
const INFO_STOWED: String = "stowed_units"
## Cells whose building lists are kept (the cache is emptied when full).
## (F-30: an NPC that chooses where to move looks at well over a hundred.)
const MAX_CACHED_CELLS: int = 1024
const KEY_ID: String = "id"
const KEY_CENTER: String = "center"
## MapBuildingDefinition.building_type of the building (F-30).
const KEY_TYPE: String = "type"
## True when an NPC can live in the building (F-30; only in the entries of
## a cell that was listed with it).
const KEY_LIVABLE: String = "livable"

## Diagnostics (tests / profiling).
var trip_count: int = 0
var search_count: int = 0
var taken_unit_count: int = 0
var stowed_unit_count: int = 0
var last_candidate_count: int = 0
var last_avoided_count: int = 0
## Cells within reach the last pick_target() could not look into: not
## simulated, or not completely built yet.
var last_unseen_cell_count: int = 0
var last_pick_usec: int = 0
var warmed_cell_count: int = 0

var _sense: NpcSurvivalSense
var _settings: NpcScavengeSettings
var _homes: NpcHomes
var _grid: StructureGrid
## Walks an NPC: (npc_id, state: NpcBehaviourState, goal: Vector3, run: bool)
## -> "" or a failure code (NpcBehaviours._move).
var _mover: Callable
## cell -> [{id, center}] of its generated buildings that have a container.
var _cells: Dictionary[Vector2i, Array] = {}
## The cells of `_cells` whose entries say whether an NPC can live there.
var _livable_cells: Dictionary[Vector2i, bool] = {}
## Cells that are planned ahead, one per tick.
var _warm_queue: Array[Vector2i] = []


func _init(sense: NpcSurvivalSense, grid: StructureGrid, mover: Callable) -> void:
	_sense = sense
	_settings = sense.settings
	_homes = sense.homes()
	_grid = grid
	_mover = mover


func sense() -> NpcSurvivalSense:
	return _sense


# ------------------------------------------------------------ the trip

## Starts a trip. "" when the NPC is on its way, or a failure code.
func begin(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> String:
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	var home: NpcHome = NpcHome.of(npc)
	if trip == null or home == null or not home.is_generated():
		return NpcActionExecutor.FAIL_UNSUPPORTED
	trip.clear_trip()
	if _can_stow(world, state.inventory_id, home):
		var code: String = _go_home(npc, state, trip, home, home.building_id)
		if code.is_empty():
			trip_count += 1
		return code
	var tried: Dictionary[String, bool] = {}
	while true:
		var building_id: String = pick_target(world, npcs, npc, tried)
		if building_id.is_empty():
			trip.clear_trip()
			if last_unseen_cell_count == 0:
				# Everything around it that it could look into is emptied, blocked,
				# too dangerous or somebody else's (F-30: a reason to move away).
				trip.no_target_streak += 1
				npcs.mark_npc_dirty(npc.npc_id)
			return FAIL_NO_TARGET
		tried[building_id] = true
		trip.clear_trip()
		trip.phase = NpcScavengeState.PHASE_TO_CONTAINER
		trip.building_id = building_id
		var code: String = _go_to_next_container(world, npc, state, trip, 0)
		if code == STEP_CONTINUES:
			trip_count += 1
			trip.no_target_streak = 0
			npcs.mark_npc_dirty(npc.npc_id)
			return ""
		# No container of it is in memory, or no walk could begin: the next.
		trip.note_visit(building_id, NpcScavengeState.RESULT_BLOCKED, _day(world), _settings.max_visited)
	return FAIL_NO_TARGET


## The walk of the trip is over. STEP_CONTINUES (the NPC searches or stows
## now: NpcBehaviours counts the timer down), or a failure code.
func on_walk_done(_world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState) -> String:
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	if trip == null or not trip.is_on_trip():
		return NpcActionExecutor.FAIL_TARGET_GONE
	state.step = NpcBehaviourState.STEP_PERFORMING
	if trip.phase == NpcScavengeState.PHASE_TO_CONTAINER:
		trip.phase = NpcScavengeState.PHASE_SEARCHING
		state.timer_usec = maxi(NpcBehaviourSettings.to_usec(_settings.search_duration_sec), 1)
	else:
		trip.phase = NpcScavengeState.PHASE_STOWING
		state.timer_usec = maxi(NpcBehaviourSettings.to_usec(_settings.stow_duration_sec), 1)
	npcs.mark_npc_dirty(npc.npc_id)
	return STEP_CONTINUES


## The timer of a search or of the stowing ran out. STEP_CONTINUES (it
## walks on), STEP_DONE (the trip is over: `info` is filled in), or a
## failure code.
func on_timer(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, info: Dictionary) -> String:
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	var home: NpcHome = NpcHome.of(npc)
	if trip == null or home == null or not trip.is_on_trip():
		return NpcActionExecutor.FAIL_TARGET_GONE
	npcs.mark_npc_dirty(npc.npc_id)
	if trip.phase != NpcScavengeState.PHASE_SEARCHING and trip.phase != NpcScavengeState.PHASE_STOWING:
		return NpcActionExecutor.FAIL_TARGET_GONE
	if trip.phase == NpcScavengeState.PHASE_STOWING:
		info[INFO_BUILDING] = trip.building_id
		info[INFO_TAKEN] = trip.taken_units
		info[INFO_STOWED] = _stow(world, npcs, npc, state, home)
		trip.clear_trip()
		return STEP_DONE
	var at_home: bool = trip.building_id == home.building_id
	_search(world, npcs, npc, state, trip, at_home)
	var code: String = _go_to_next_container(world, npc, state, trip, trip.container_index + 1)
	if code == STEP_CONTINUES:
		return STEP_CONTINUES
	# Every container was searched (or it can carry no more). A walk to the
	# next container that could not even begin leaves the rest for another day.
	var result: String = NpcScavengeState.RESULT_LEFT if trip.left_useful else NpcScavengeState.RESULT_EMPTY
	trip.note_visit(trip.building_id, result if code == FAIL_NO_TARGET else NpcScavengeState.RESULT_BLOCKED, _day(world), _settings.max_visited)
	if at_home or not _has_container(world, home.building_id):
		info[INFO_BUILDING] = trip.building_id
		info[INFO_TAKEN] = trip.taken_units
		info[INFO_STOWED] = 0
		trip.clear_trip()
		return STEP_DONE
	# The way home belongs to the same trip: what it took is still counted.
	var taken: int = trip.taken_units
	var home_code: String = _go_home(npc, state, trip, home, trip.building_id)
	if not home_code.is_empty():
		trip.clear_trip()
		return home_code
	trip.taken_units = taken
	return STEP_CONTINUES


## The trip failed with `code` (the walk found no way, ...): a building it
## could not reach is written down, the trip is forgotten.
func on_failed(world: ServerWorld, npc: NpcState, code: String) -> void:
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	if trip == null:
		return
	if trip.phase == NpcScavengeState.PHASE_TO_CONTAINER and code == NpcActionExecutor.FAIL_NO_PATH:
		trip.note_visit(trip.building_id, NpcScavengeState.RESULT_BLOCKED, _day(world), _settings.max_visited)
	trip.clear_trip()


## The trip was cancelled (a zombie, a need): what it carries it keeps, and
## the building stays unsearched.
func on_cancelled(npc: NpcState) -> void:
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	if trip != null:
		trip.clear_trip()


# ------------------------------------------------------------ choosing a building

## The building the NPC searches next ("" = none), see the header.
## Buildings in `without` are not looked at.
func pick_target(world: ServerWorld, npcs: NpcService, npc: NpcState, without: Dictionary[String, bool] = {}) -> String:
	var started_usec: int = Time.get_ticks_usec()
	last_candidate_count = 0
	last_avoided_count = 0
	last_unseen_cell_count = 0
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	var home: NpcHome = NpcHome.of(npc)
	var generator: ProceduralMapGenerator = _homes.generator() if _homes != null else null
	var map: ProceduralMapService = world.get_system(ProceduralMapService.SYSTEM_ID) as ProceduralMapService if world != null else null
	var raw_home_center: Variant = _homes.building_center(home.building_id) if home != null and home.is_generated() else null
	if trip == null or generator == null or map == null or raw_home_center == null:
		return ""
	if trip.result_of(home.building_id).is_empty() and not without.has(home.building_id) and _has_container(world, home.building_id):
		last_pick_usec = Time.get_ticks_usec() - started_usec
		return home.building_id
	var home_center: Vector3 = raw_home_center
	var now: float = world.clock.world_time_sec
	var day: int = _day(world)
	var limit: float = _sense.danger_limit(npc)
	var wants_more: bool = _sense.wanted_food(world, npc) > 0 or _sense.wanted_drinks(world, npc) > 0
	var best_id: String = ""
	var best_cost: float = INF
	for cell: Vector2i in cells_around(world, home_center, _settings.radius_m):
		var cell_id: String = WorldCellGrid.id_of(cell)
		if not world.is_cell_simulated(cell_id) or not map.is_cell_complete(cell_id):
			last_unseen_cell_count += 1
			continue
		for building: Dictionary in buildings_of(generator, cell):
			var building_id: String = str(building[KEY_ID])
			var center: Vector3 = building[KEY_CENTER]
			if building_id == home.building_id or without.has(building_id) or _flat_distance(center, home_center) > _settings.radius_m:
				continue
			var result: String = trip.result_of(building_id)
			if result == NpcScavengeState.RESULT_EMPTY or (result == NpcScavengeState.RESULT_LEFT and not wants_more) or (result == NpcScavengeState.RESULT_BLOCKED and day - trip.day_of(building_id) < _settings.blocked_forget_days):
				continue
			if npcs.is_seeded_home(building_id):
				continue
			last_candidate_count += 1
			var danger: float = _sense.danger_at(npc, center, now)
			if danger >= limit:
				last_avoided_count += 1
				continue
			var cost: float = _flat_distance(center, npc.position) + danger * _settings.danger_cost_m
			if cost < best_cost or (cost == best_cost and building_id < best_id):
				best_cost = cost
				best_id = building_id
	last_pick_usec = Time.get_ticks_usec() - started_usec
	return best_id


## The cells a building within `radius_m` of `center` can stand in (sorted
## by x, then z). A building never crosses a cell border: a cell whose
## nearest point is beyond the radius holds none that is near enough.
func cells_around(world: ServerWorld, center: Vector3, radius_m: float) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var cell_size: float = world.cell_grid.cell_size_m
	for cell: Vector2i in world.cell_grid.cells_within(world.cell_grid.cell_of(center), ceili(radius_m / cell_size)):
		var low: Vector3 = world.cell_grid.cell_min_corner(cell)
		var nearest: Vector3 = Vector3(clampf(center.x, low.x, low.x + cell_size), 0.0, clampf(center.z, low.z, low.z + cell_size))
		if _flat_distance(nearest, center) <= radius_m:
			cells.append(cell)
	return cells


## Queues the cells around the home of an NPC that lives alone to be
## planned ahead (NpcBehaviours, when the NPC wakes).
func queue_cells_of(world: ServerWorld, npc: NpcState) -> void:
	var home: NpcHome = NpcHome.of(npc)
	var raw_center: Variant = _homes.building_center(home.building_id) if home != null and home.is_generated() and _homes != null else null
	if world == null or raw_center == null:
		return
	for cell: Vector2i in cells_around(world, raw_center as Vector3, _settings.radius_m):
		if not _cells.has(cell) and not _warm_queue.has(cell):
			_warm_queue.append(cell)


## Plans one queued cell (NpcBehaviours, once per tick).
func warm_one() -> void:
	var generator: ProceduralMapGenerator = _homes.generator() if _homes != null and not _warm_queue.is_empty() else null
	while generator != null and not _warm_queue.is_empty():
		var cell: Vector2i = _warm_queue.pop_front()
		if not _cells.has(cell):
			buildings_of(generator, cell)
			warmed_cell_count += 1
			return
	_warm_queue.clear()


## True when the buildings of a cell are listed (and, `with_livable`, the
## list says where an NPC can live): buildings_of() then plans nothing.
func is_listed(cell: Vector2i, with_livable: bool = false) -> bool:
	return _cells.has(cell) and (not with_livable or _livable_cells.has(cell))


## [{id, center, type}] of the generated buildings of a cell that have a
## container (planned once per cell, then kept). `with_livable` (F-30):
## every entry also says whether an NPC can live in the building
## (`livable`, NpcHomePicker.is_home); a cell that was listed without it is
## planned once more.
func buildings_of(generator: ProceduralMapGenerator, cell: Vector2i, with_livable: bool = false) -> Array:
	if _cells.has(cell) and (not with_livable or _livable_cells.has(cell)):
		return _cells[cell]
	var listed: Array = []
	for building: ProceduralBuilding in generator.plan_cell(cell).buildings:
		var definition: MapBuildingDefinition = building.definition
		if definition == null or definition.containers.is_empty():
			continue
		var low: Vector3 = _grid.tile_center(definition.origin_tile)
		var high: Vector3 = _grid.tile_center(definition.origin_tile + definition.size_tiles - Vector2i.ONE)
		var entry: Dictionary = {KEY_ID: building.building_id(), KEY_CENTER: (low + high) * 0.5, KEY_TYPE: definition.building_type}
		if with_livable:
			entry[KEY_LIVABLE] = NpcHomePicker.is_home(building)
		listed.append(entry)
	if _cells.size() >= MAX_CACHED_CELLS and not _cells.has(cell):
		_cells.clear()
		_livable_cells.clear()
	_cells[cell] = listed
	if with_livable:
		_livable_cells[cell] = true
	return listed


# ------------------------------------------------------------ steps

## Walks the NPC to the first container of the trip's building, from
## `from_index` on, that is in memory. STEP_CONTINUES when it walks,
## FAIL_NO_TARGET when no container is left, or the walk's failure code.
func _go_to_next_container(world: ServerWorld, npc: NpcState, state: NpcBehaviourState, trip: NpcScavengeState, from_index: int) -> String:
	var containers: Array[ContainerInstance] = _sense.containers_of(world, trip.building_id)
	if from_index > 0 and world.inventory.items_in_inventory(state.inventory_id).size() >= state.capacity() and trip.left_useful:
		# Its hands are full: the rest of the building waits for another trip.
		return FAIL_NO_TARGET
	for index: int in range(maxi(from_index, 0), containers.size()):
		var place: Variant = _homes.container_position(trip.building_id, index)
		if containers[index] == null or place == null:
			continue
		var code: String = _mover.call(npc.npc_id, state, place as Vector3, false)
		if not code.is_empty():
			return code
		trip.phase = NpcScavengeState.PHASE_TO_CONTAINER
		trip.container_index = index
		return STEP_CONTINUES
	return FAIL_NO_TARGET


## Walks the NPC to its home tile to put the loot away. `trip_building_id`:
## the building the trip searched (its home on a trip that only puts loot
## away). "" or a failure code.
func _go_home(npc: NpcState, state: NpcBehaviourState, trip: NpcScavengeState, home: NpcHome, trip_building_id: String) -> String:
	var code: String = _mover.call(npc.npc_id, state, _grid.tile_center(home.tile), false)
	if not code.is_empty():
		return code
	trip.clear_trip()
	trip.phase = NpcScavengeState.PHASE_TO_HOME
	trip.building_id = trip_building_id
	return ""


## Searches the container the NPC stands at and takes what is useful.
func _search(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, trip: NpcScavengeState, at_home: bool) -> void:
	var containers: Array[ContainerInstance] = _sense.containers_of(world, trip.building_id)
	var container: ContainerInstance = containers[trip.container_index] if trip.container_index >= 0 and trip.container_index < containers.size() else null
	var service: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
	if container == null or service == null or not service.search_now(world, container.container_id):
		return
	search_count += 1
	var kinds: PackedStringArray = [NpcSurvivalSense.KIND_MEDICAL, NpcSurvivalSense.KIND_WEAPON]
	if not at_home:
		kinds.append_array(PackedStringArray([NpcSurvivalSense.KIND_FOOD, NpcSurvivalSense.KIND_DRINK]))
	# Units of food and drinks it still wants; anything else it takes whole.
	var wanted: Dictionary = {NpcSurvivalSense.KIND_FOOD: _sense.wanted_food(world, npc), NpcSurvivalSense.KIND_DRINK: _sense.wanted_drinks(world, npc)}
	var taken: int = 0
	for kind: String in kinds:
		for item: ItemInstance in NpcSurvivalSense.items_of(world, container.inventory_id):
			var definition: ItemDefinition = world.inventory.definition_of(item.item_instance_id)
			if _sense.kind_of(definition) != kind:
				continue
			if kind == NpcSurvivalSense.KIND_WEAPON and not _make_room_for_weapon(world, state, container, definition):
				continue
			var offered: int = item.quantity
			var moved: int = _move_units(world, container.inventory_id, item, state.inventory_id, state.capacity(), int(wanted.get(kind, offered)))
			taken += moved
			if wanted.has(kind):
				wanted[kind] = int(wanted[kind]) - moved
				if moved < offered:
					trip.left_useful = true
	if taken > 0:
		trip.taken_units += taken
		taken_unit_count += taken
		npcs.mark_cell_save_dirty(container.cell_id)
	GameLogger.debug("npc", "an NPC searched a container", {"entity_id": npc.npc_id, "container_id": container.container_id, "building_id": trip.building_id, "taken_units": taken, "operation": "scavenge"})


## True when the weapon `definition` is better than what the NPC carries:
## the weapon it carries is then put into the container to make room.
func _make_room_for_weapon(world: ServerWorld, state: NpcBehaviourState, container: ContainerInstance, definition: ItemDefinition) -> bool:
	var found: MeleeWeaponDefinition = _sense.weapon_of(definition)
	var carried: ItemInstance = _sense.best_weapon_item(world, state.inventory_id)
	if found == null:
		return false
	if carried == null:
		return true
	if found.base_damage <= _sense.weapon_of(world.inventory.definition_of(carried.item_instance_id)).base_damage:
		return false
	var units: int = carried.quantity
	return _move_units(world, state.inventory_id, carried, container.inventory_id, container.slot_count) == units


# ------------------------------------------------------------ for a move (F-30)

## Queues cells to be planned ahead, one per tick (see warm_one).
func queue_cells(cells: Array[Vector2i]) -> void:
	for cell: Vector2i in cells:
		if not _cells.has(cell) and not _warm_queue.has(cell):
			_warm_queue.append(cell)


## Moves as many units of `item` as fit (see _move_units).
func carry_units(world: ServerWorld, from_inventory_id: String, item: ItemInstance, to_inventory_id: String, capacity: int, limit: int = -1) -> int:
	return _move_units(world, from_inventory_id, item, to_inventory_id, capacity, limit)


## True when the NPC should take the weapon `definition` out of
## `container`: it is better than the one it carries, which was put into
## the container to make room (see _make_room_for_weapon).
func takes_weapon(world: ServerWorld, state: NpcBehaviourState, container: ContainerInstance, definition: ItemDefinition) -> bool:
	return _make_room_for_weapon(world, state, container, definition)


## Puts what the NPC carries and what belongs into a home into the
## containers of its home (see _stow). Returns the units put away.
func stow_at_home(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, home: NpcHome) -> int:
	return _stow(world, npcs, npc, state, home)


## Puts food, drinks and spare weapons into the containers of the home
## (the first that has room). Returns the units put away.
func _stow(world: ServerWorld, npcs: NpcService, npc: NpcState, state: NpcBehaviourState, home: NpcHome) -> int:
	var keep: ItemInstance = _sense.best_weapon_item(world, state.inventory_id)
	var stowed: int = 0
	for item: ItemInstance in NpcSurvivalSense.items_of(world, state.inventory_id):
		if not _is_stowable(world, item, keep):
			continue
		for container: ContainerInstance in _sense.containers_of(world, home.building_id):
			if container == null:
				continue
			var left: int = item.quantity
			var moved: int = _move_units(world, state.inventory_id, item, container.inventory_id, container.slot_count)
			if moved > 0:
				stowed += moved
				npcs.mark_cell_save_dirty(container.cell_id)
			if moved == left:
				break
	stowed_unit_count += stowed
	# What the home holds now, for when its cell is not in memory.
	_sense.home_supplies(world, npc)
	return stowed


## True when the NPC carries something that belongs into its home and a
## container of the home that is in memory has room for some of it.
func _can_stow(world: ServerWorld, inventory_id: String, home: NpcHome) -> bool:
	var keep: ItemInstance = _sense.best_weapon_item(world, inventory_id)
	var containers: Array[ContainerInstance] = _sense.containers_of(world, home.building_id)
	for item: ItemInstance in NpcSurvivalSense.items_of(world, inventory_id):
		if not _is_stowable(world, item, keep):
			continue
		for container: ContainerInstance in containers:
			if container != null and _room_for(world, item, container.inventory_id, container.slot_count) > 0:
				return true
	return false


func _is_stowable(world: ServerWorld, item: ItemInstance, kept_weapon: ItemInstance) -> bool:
	match _sense.kind_of(world.inventory.definition_of(item.item_instance_id)):
		NpcSurvivalSense.KIND_FOOD, NpcSurvivalSense.KIND_DRINK:
			return true
		NpcSurvivalSense.KIND_WEAPON:
			return kept_weapon == null or item.item_instance_id != kept_weapon.item_instance_id
	return false


## Moves as many units of `item` as fit from one inventory into another
## (`capacity`: the slots of the receiving one), at most `limit` (< 0 =
## the whole stack). Returns the units moved.
static func _move_units(world: ServerWorld, from_inventory_id: String, item: ItemInstance, to_inventory_id: String, capacity: int, limit: int = -1) -> int:
	if limit == 0:
		return 0
	var units: int = _room_for(world, item, to_inventory_id, capacity)
	if limit > 0:
		units = mini(units, limit)
	if units < 1:
		return 0
	return units if world.inventory.transfer_item(from_inventory_id, item.item_instance_id, to_inventory_id, units).ok else 0


## Units of `item` an inventory with `capacity` slots could take now: the
## whole stack when it has a free slot, otherwise what its stacks of the
## same kind still take (the rule of InventoryService.transfer_item).
static func _room_for(world: ServerWorld, item: ItemInstance, to_inventory_id: String, capacity: int) -> int:
	var definition: ItemDefinition = world.inventory.definition_of(item.item_instance_id)
	if definition == null or item.quantity < 1 or not world.inventory.has_inventory(to_inventory_id):
		return 0
	var held: Array[ItemInstance] = world.inventory.items_in_inventory(to_inventory_id)
	if held.size() < capacity:
		return item.quantity
	var room: int = 0
	for other: ItemInstance in held:
		if other.definition_id == item.definition_id and other.condition == item.condition and other.quality == item.quality:
			room += maxi(definition.max_stack - other.quantity, 0)
	return mini(item.quantity, room)


## True when a container of the building is in memory.
func _has_container(world: ServerWorld, building_id: String) -> bool:
	for container: ContainerInstance in _sense.containers_of(world, building_id):
		if container != null:
			return true
	return false


func _day(world: ServerWorld) -> int:
	return maxi(floori(world.clock.world_time_sec / _settings.day_length_world_sec), 0)


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
