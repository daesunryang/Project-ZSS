class_name WorldCellService
extends ServerSystem
## Cell lifecycle of the world on the server (P3-1, docs/03 §3, docs/00
## ADR-023, docs/09 §15.1). System id "world_cells"; registered FIRST by
## ServerComposition, so every other system sees this tick's cells.
##
## What it decides, from the SERVER positions of the online players only
## (nothing a client sends reaches this class):
##   ACTIVE     cells within `active_radius_cells` of a player's cell:
##              their entities are simulated.
##   PRELOADED  cells within `preload_radius_cells`, and around the place
##              a player is heading for (look-ahead): in memory, frozen.
##   UNLOADED   everything else: saved and out of memory.
## States and transitions are WorldCellLifecycle. Loading, saving and
## releasing are synchronous for now, but every step is a state of its own
## and is announced through `cell_state_changed`.
##
## Rules:
##   - A cell a player needs now (the active area and one ring around it)
##     is loaded at once; cells of the outer preload ring are loaded at most
##     `max_preload_loads_per_refresh` per look, nearest first.
##   - Hysteresis: an active cell that is no longer wanted stays active for
##     `deactivate_delay_sec`, then a preloaded cell that is no longer
##     wanted stays in memory for `unload_delay_sec` (action time). Coming
##     back in time cancels the wait, so walking along a border changes
##     nothing.
##   - A cell is released only after its store saved it (CLAUDE.md §6). When
##     the save fails the cell stays in memory and is tried again after
##     `retry_delay_sec`. Without a store no cell is ever released.
##   - A cell next to an ACTIVE cell is never released, so a simulated
##     entity cannot step into a cell that is not in memory.
##   - A failed load leaves the cell UNLOADED (not activated), logs the cell
##     id and is tried again after `retry_delay_sec`.
##   - Entities that are in memory in a cell that is not loaded ("strays":
##     a save from before cells existed, a new world's seed, a spawn far
##     from every player) get their cell loaded at the next look, merged
##     with what was saved for it.
##   - Nothing happens while the world clock is paused, except that a
##     player entering the world is looked at at once.
## Players are not unloaded with a cell.
##
## The systems are told through ServerWorld: on_cell_activated /
## on_cell_deactivated, restore_cell_document, to_cell_document,
## release_cell (ServerSystem). Network code listens to `cell_loaded` and
## `cell_unloading`.

## A cell changed its state (WorldCellLifecycle.State values).
signal cell_state_changed(cell_id: String, from: int, to: int)
## The cell's entities are in memory now (it is PRELOADED).
signal cell_loaded(cell_id: String)
## The cell was saved and its entities are about to leave memory; they can
## still be read (ServerWorld.cell_index).
signal cell_unloading(cell_id: String)
## The cell's entities left memory.
signal cell_unloaded(cell_id: String)

const SYSTEM_ID: String = "world_cells"
## Float tolerance for delays measured in summed tick lengths.
const TIME_EPSILON_SEC: float = 0.000001

## Diagnostics (tests / profiling).
var load_count: int = 0
var unload_count: int = 0
var failed_load_count: int = 0
var failed_save_count: int = 0
var refresh_count: int = 0

var _settings: WorldCellSettings
var _store: WorldCellStore = null
## cell_id -> WorldCellLifecycle.State; a cell that is not listed is UNLOADED.
var _states: Dictionary[String, int] = {}
## cell_id -> action time since which the cell is not wanted in its state.
var _idle_since: Dictionary[String, float] = {}
## cell_id -> action time before which a failed load / save is not retried.
var _retry_at: Dictionary[String, float] = {}
## player_id -> server position at the previous look (look-ahead).
var _last_positions: Dictionary[String, Vector3] = {}
var _last_refresh_time: float = 0.0
var _since_refresh: float = 0.0
var _refreshing: bool = false


func _init(settings: WorldCellSettings) -> void:
	_settings = settings


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ public API

## Sets where released cells are kept (null = never release a cell). Set it
## before any cell was released.
func set_store(store: WorldCellStore) -> void:
	_store = store


func get_store() -> WorldCellStore:
	return _store


## WorldCellLifecycle.State of a cell.
func state_of(cell_id: String) -> int:
	return _states.get(cell_id, WorldCellLifecycle.State.UNLOADED)


## True when the cell's entities are in memory and complete.
func is_loaded(cell_id: String) -> bool:
	return WorldCellLifecycle.is_loaded(state_of(cell_id))


## True when the cell's entities are simulated now.
func is_simulated(cell_id: String) -> bool:
	return state_of(cell_id) == WorldCellLifecycle.State.ACTIVE


## Ids of the cells that are in memory, sorted.
func loaded_cell_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for cell_id: String in _states:
		if WorldCellLifecycle.is_loaded(_states[cell_id]):
			ids.append(cell_id)
	ids.sort()
	return ids


## Ids of the ACTIVE cells, sorted.
func active_cell_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for cell_id: String in _states:
		if _states[cell_id] == WorldCellLifecycle.State.ACTIVE:
			ids.append(cell_id)
	ids.sort()
	return ids


## Looks at the players now and moves every cell towards the state it
## should have (see the header). Called by step() every
## `refresh_period_sec` and at once when a player enters the world or
## starts a new character.
func refresh(world: ServerWorld) -> void:
	if _refreshing:
		return
	_refreshing = true
	refresh_count += 1
	var now: float = world.clock.action_time_sec
	var grid: WorldCellGrid = world.cell_grid
	var wanted_active: Dictionary[String, bool] = {}
	# cell_id -> 0 for a cell that is needed now, else its distance in cells.
	var wanted_loaded: Dictionary[String, int] = {}
	_collect_wanted(world, now, wanted_active, wanted_loaded)
	_load_wanted(world, now, wanted_loaded)
	var activate: PackedStringArray = PackedStringArray(wanted_active.keys())
	activate.sort()
	for cell_id: String in activate:
		if state_of(cell_id) == WorldCellLifecycle.State.PRELOADED:
			_set_active(world, cell_id, true)
	var unload: PackedStringArray = []
	for cell_id: String in _states.keys():
		if _states[cell_id] == WorldCellLifecycle.State.ACTIVE:
			if wanted_active.has(cell_id):
				_idle_since.erase(cell_id)
			elif _waited(cell_id, now, _settings.deactivate_delay_sec):
				_set_active(world, cell_id, false)
		if _states[cell_id] == WorldCellLifecycle.State.PRELOADED:
			if wanted_loaded.has(cell_id):
				_idle_since.erase(cell_id)
			elif _waited(cell_id, now, _settings.unload_delay_sec) and _store != null and _may_try(cell_id, now) and not _has_active_neighbour(grid, cell_id):
				unload.append(cell_id)
	if not unload.is_empty():
		unload.sort()
		_unload(world, unload, now)
	_last_refresh_time = now
	_refreshing = false


## Loads the cell of every entity that is in memory in a cell that is not
## loaded (see "strays" in the header). Part of every look; also called
## before a save, so that a save never writes a cell without what was
## saved for it before.
func adopt_strays(world: ServerWorld) -> void:
	var now: float = world.clock.action_time_sec
	for cell_id: String in world.cell_index.occupied_cell_ids():
		if state_of(cell_id) == WorldCellLifecycle.State.UNLOADED and _may_try(cell_id, now):
			_load(world, cell_id, now)


# ------------------------------------------------------------ ServerSystem

func step(world: ServerWorld, action_delta: float, _world_delta: float) -> void:
	if action_delta <= 0.0:
		return
	_since_refresh += action_delta
	if _since_refresh + TIME_EPSILON_SEC < _settings.refresh_period_sec:
		return
	_since_refresh = 0.0
	refresh(world)


func on_player_online(world: ServerWorld, _player_id: String) -> void:
	refresh(world)


func on_player_offline(_world: ServerWorld, player_id: String) -> void:
	_last_positions.erase(player_id)


## A new character starts at the spawn point: its cells must be there now.
func on_character_started(world: ServerWorld, player_id: String) -> void:
	_last_positions.erase(player_id)
	refresh(world)


# ------------------------------------------------------------ internals

## Fills the cells the online players want active / in memory.
func _collect_wanted(world: ServerWorld, now: float, wanted_active: Dictionary[String, bool], wanted_loaded: Dictionary[String, int]) -> void:
	var grid: WorldCellGrid = world.cell_grid
	var needed_radius: int = mini(_settings.active_radius_cells + 1, _settings.preload_radius_cells)
	var online: PackedStringArray = world.online_player_ids()
	for player_id: String in online:
		var position: Vector3 = world.get_player(player_id).position
		var cell: Vector2i = grid.cell_of(position)
		for near: Vector2i in grid.cells_within(cell, _settings.preload_radius_cells):
			var distance: int = WorldCellGrid.distance(near, cell)
			var cell_id: String = WorldCellGrid.id_of(near)
			if distance <= _settings.active_radius_cells:
				wanted_active[cell_id] = true
			var rank: int = 0 if distance <= needed_radius else distance
			if not wanted_loaded.has(cell_id) or rank < wanted_loaded[cell_id]:
				wanted_loaded[cell_id] = rank
		var ahead: Vector2i = grid.cell_of(_position_ahead(player_id, position, now, grid.cell_size_m))
		if ahead != cell:
			for near: Vector2i in grid.cells_within(ahead, _settings.preload_radius_cells):
				var cell_id: String = WorldCellGrid.id_of(near)
				if not wanted_loaded.has(cell_id):
					wanted_loaded[cell_id] = maxi(WorldCellGrid.distance(near, cell), needed_radius + 1)
		_last_positions[player_id] = position
	for player_id: String in _last_positions.keys():
		if not online.has(player_id):
			_last_positions.erase(player_id)


## Where the player will be in `preload_lookahead_sec` if it keeps moving
## as it did since the previous look (server positions only). The look-ahead
## reaches at most one cell, so a teleport cannot preload half the map.
func _position_ahead(player_id: String, position: Vector3, now: float, cell_size_m: float) -> Vector3:
	var elapsed: float = now - _last_refresh_time
	if _settings.preload_lookahead_sec <= 0.0 or elapsed <= 0.0 or not _last_positions.has(player_id):
		return position
	var moved: Vector3 = position - _last_positions[player_id]
	var ahead: Vector3 = Vector3(moved.x, 0.0, moved.z) / elapsed * _settings.preload_lookahead_sec
	return position + ahead.limit_length(cell_size_m)


## Loads wanted cells that are not in memory: strays and needed cells at
## once, cells of the outer ring nearest first within the budget.
func _load_wanted(world: ServerWorld, now: float, wanted_loaded: Dictionary[String, int]) -> void:
	adopt_strays(world)
	var needed: PackedStringArray = []
	var outer: Array[Array] = []  # [rank, cell_id]
	for cell_id: String in wanted_loaded:
		if state_of(cell_id) != WorldCellLifecycle.State.UNLOADED or not _may_try(cell_id, now):
			continue
		if wanted_loaded[cell_id] == 0:
			needed.append(cell_id)
		else:
			outer.append([wanted_loaded[cell_id], cell_id])
	needed.sort()
	for cell_id: String in needed:
		_load(world, cell_id, now)
	outer.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]) if a[0] != b[0] else str(a[1]) < str(b[1]))
	for index: int in range(mini(outer.size(), _settings.max_preload_loads_per_refresh)):
		_load(world, str(outer[index][1]), now)


## UNLOADED -> LOADING -> PRELOADED, or back to UNLOADED when the cell
## cannot be loaded (logged with the cell id; retried later).
func _load(world: ServerWorld, cell_id: String, now: float) -> bool:
	if not _set_state(cell_id, WorldCellLifecycle.State.LOADING):
		return false
	var errors: PackedStringArray = []
	if _store != null:
		var loaded: Dictionary = _store.load_cell(cell_id)
		if int(loaded.get(WorldCellStore.KEY_ERROR, FAILED)) != OK:
			errors.append("store error: " + error_string(int(loaded.get(WorldCellStore.KEY_ERROR, FAILED))))
		else:
			errors = world.restore_cell_document(cell_id, loaded.get(WorldCellStore.KEY_DOCUMENT, {}) as Dictionary)
	if not errors.is_empty():
		failed_load_count += 1
		_retry_at[cell_id] = now + _settings.retry_delay_sec
		GameLogger.error("cells", "cell could not be loaded and stays inactive", {"world_id": world.world_id, "cell_id": cell_id, "errors": "; ".join(errors), "retry_in_sec": _settings.retry_delay_sec, "operation": "load_cell"})
		_set_state(cell_id, WorldCellLifecycle.State.UNLOADED)
		return false
	_retry_at.erase(cell_id)
	_idle_since.erase(cell_id)
	load_count += 1
	_set_state(cell_id, WorldCellLifecycle.State.PRELOADED)
	GameLogger.debug("cells", "cell loaded", {"world_id": world.world_id, "cell_id": cell_id, "entities": world.cell_index.count_in_cell(cell_id)})
	cell_loaded.emit(cell_id)
	return true


## PRELOADED <-> ACTIVE, telling every system.
func _set_active(world: ServerWorld, cell_id: String, active: bool) -> void:
	if not _set_state(cell_id, WorldCellLifecycle.State.ACTIVE if active else WorldCellLifecycle.State.PRELOADED):
		return
	_idle_since.erase(cell_id)
	world.notify_cell_active(cell_id, active)


## PRELOADED -> SAVING -> UNLOADING -> UNLOADED for every cell of the
## batch, or back to PRELOADED when the save failed: nothing is released
## that was not saved.
func _unload(world: ServerWorld, cell_ids: PackedStringArray, now: float) -> void:
	for cell_id: String in cell_ids:
		_set_state(cell_id, WorldCellLifecycle.State.SAVING)
	var error: Error = _store.save_cells(world, cell_ids)
	if error != OK:
		failed_save_count += 1
		GameLogger.error("cells", "cells could not be saved and stay in memory", {"world_id": world.world_id, "cell_ids": ", ".join(cell_ids), "error": error_string(error), "retry_in_sec": _settings.retry_delay_sec, "operation": "unload_cells"})
		for cell_id: String in cell_ids:
			_retry_at[cell_id] = now + _settings.retry_delay_sec
			_set_state(cell_id, WorldCellLifecycle.State.PRELOADED)
		return
	for cell_id: String in cell_ids:
		_set_state(cell_id, WorldCellLifecycle.State.UNLOADING)
		cell_unloading.emit(cell_id)
		var released: int = world.cell_index.count_in_cell(cell_id)
		world.release_cell(cell_id)
		_idle_since.erase(cell_id)
		_retry_at.erase(cell_id)
		unload_count += 1
		_set_state(cell_id, WorldCellLifecycle.State.UNLOADED)
		GameLogger.debug("cells", "cell unloaded", {"world_id": world.world_id, "cell_id": cell_id, "entities": released})
		cell_unloaded.emit(cell_id)


## Applies one transition of WorldCellLifecycle; refuses (and logs) any
## other change of state.
func _set_state(cell_id: String, to: int) -> bool:
	var from: int = state_of(cell_id)
	if not WorldCellLifecycle.can_transition(from, to):
		GameLogger.error("cells", "cell state transition refused", {"cell_id": cell_id, "from": WorldCellLifecycle.state_name(from), "to": WorldCellLifecycle.state_name(to), "operation": "set_cell_state"})
		return false
	if to == WorldCellLifecycle.State.UNLOADED:
		_states.erase(cell_id)
	else:
		_states[cell_id] = to
	cell_state_changed.emit(cell_id, from, to)
	return true


## True once the cell has been unwanted for `delay` seconds without a break
## (the wait starts with the first call).
func _waited(cell_id: String, now: float, delay: float) -> bool:
	if not _idle_since.has(cell_id):
		_idle_since[cell_id] = now
	return now - _idle_since[cell_id] + TIME_EPSILON_SEC >= delay


func _may_try(cell_id: String, now: float) -> bool:
	return not _retry_at.has(cell_id) or now + TIME_EPSILON_SEC >= _retry_at[cell_id]


func _has_active_neighbour(grid: WorldCellGrid, cell_id: String) -> bool:
	var cell: Variant = WorldCellGrid.parse_id(cell_id)
	if cell == null:
		return false
	for near: Vector2i in grid.neighbours(cell as Vector2i):
		if state_of(WorldCellGrid.id_of(near)) == WorldCellLifecycle.State.ACTIVE:
			return true
	return false
