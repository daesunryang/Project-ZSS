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
const SCHEMA_VERSION: int = 1
## World document key: the WorldCellGrid.signature() the save was cut with.
const KEY_GRID: String = "grid"
## Float tolerance for delays measured in summed tick lengths.
const TIME_EPSILON_SEC: float = 0.000001
## Float tolerance when a saved grid is compared with the current one.
const GRID_EPSILON_M: float = 0.0001

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
## WorldCellGrid.signature() of the world this system is registered with.
var _grid_signature: Dictionary = {}
## The restored save was cut with another grid (see needs_repartition).
var _repartition_needed: bool = false


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


## Brings every cell the store has a document for into memory (tools,
## tests, anything that must look at the whole world at once). The cells
## become PRELOADED and are released again by the normal rules. Returns the
## ids of the cells that could not be loaded.
func load_all_saved_cells(world: ServerWorld) -> PackedStringArray:
	var failed: PackedStringArray = []
	if _store == null:
		return failed
	var now: float = world.clock.action_time_sec
	for cell_id: String in _store.saved_cell_ids():
		if state_of(cell_id) == WorldCellLifecycle.State.UNLOADED and not _load(world, cell_id, now):
			failed.append(cell_id)
	return failed


## Loads the cell of every entity that is in memory in a cell that is not
## loaded (see "strays" in the header). Part of every look; also called
## before a save, so that a save never writes a cell without what was
## saved for it before.
func adopt_strays(world: ServerWorld) -> void:
	var now: float = world.clock.action_time_sec
	for cell_id: String in world.cell_index.occupied_cell_ids():
		if state_of(cell_id) == WorldCellLifecycle.State.UNLOADED and _may_try(cell_id, now):
			_load(world, cell_id, now)


# ------------------------------------------------------------ saving

## True when a world save made now writes the entities of this cell into
## the cell's own document, so they must not be in the world document too:
## the cell is in memory and the store is the world save. With a memory
## store (or none) every entity in memory is saved in the world document.
func saves_cell_document(cell_id: String) -> bool:
	return _store != null and _store.saves_loaded_cells() and is_loaded(cell_id)


## The cell documents of a world save made now ({cell_id: document}):
##   - store of a saved world: every cell that is in memory (the files of
##     the other cells are already in the save);
##   - memory store: every cell that is NOT in memory (the released ones),
##     so the returned documents are the whole world;
##   - no store: none.
## Strays get their cell loaded first, so a cell document is never written
## without what was saved for that cell before.
func cell_documents_for_save(world: ServerWorld) -> Dictionary:
	adopt_strays(world)
	var documents: Dictionary = {}
	if _store == null:
		return documents
	if _store.saves_loaded_cells():
		for cell_id: String in loaded_cell_ids():
			documents[cell_id] = world.cell_document(cell_id)
	else:
		for cell_id: String in _store.saved_cell_ids():
			if not is_loaded(cell_id):
				documents[cell_id] = _store.document_of(cell_id)
	return documents


## True when the world save being made must replace every saved cell file
## (the world was partitioned again).
func replaces_saved_cells() -> bool:
	return _store != null and _store.replaces_saved_cells()


## A world save succeeded.
func on_world_saved() -> void:
	if _store != null and _store.replaces_saved_cells():
		_store.saved_cells_replaced()


## True when the restored save was cut with another cell grid (the cell
## size or the map bounds changed since): its cell documents do not match
## this world's cells. Whoever restores the world must then bring every
## saved cell into memory (ServerWorld.repartition_from) before the cell
## store is used.
func needs_repartition() -> bool:
	return _repartition_needed


## Takes the cell documents that came with restored world documents
## (ServerWorld.restore_documents). Returns errors.
func restore_cell_documents(world: ServerWorld, documents: Dictionary) -> PackedStringArray:
	if documents.is_empty():
		return PackedStringArray()
	if _repartition_needed:
		var errors: PackedStringArray = world.repartition_from(documents)
		if errors.is_empty():
			_repartition_needed = false
		return errors
	if _store == null or _store.saves_loaded_cells():
		return PackedStringArray(["cell documents can only be restored into a memory cell store"])
	_store.replace_documents(documents)
	return PackedStringArray()


## Every saved cell was brought into memory for the new grid.
func repartition_done() -> void:
	_repartition_needed = false


# ------------------------------------------------------------ ServerSystem

func on_registered(world: ServerWorld) -> void:
	_grid_signature = world.cell_grid.signature()


func to_world_document() -> Dictionary:
	return {"schema_version": SCHEMA_VERSION, KEY_GRID: _grid_signature.duplicate(true)}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != SCHEMA_VERSION:
		errors.append("world_cells: unsupported schema_version")
		return errors
	var saved: Variant = document.get(KEY_GRID, null)
	if typeof(saved) != TYPE_DICTIONARY:
		errors.append("world_cells: grid must be an object")
		return errors
	_repartition_needed = not _same_grid(saved as Dictionary, _grid_signature)
	if _repartition_needed:
		GameLogger.warning("cells", "the save was cut with another cell grid; its cells are sorted again", {"saved": str(saved), "current": str(_grid_signature), "operation": "restore_world"})
	return errors


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
## that was not saved. A batch in which no cell holds an entity and no cell
## has a saved document has nothing to save: its cells go through the same
## states without the store being asked (most cells of a map are empty, and
## a save writes the whole world).
func _unload(world: ServerWorld, cell_ids: PackedStringArray, now: float) -> void:
	var saved_ids: PackedStringArray = _store.saved_cell_ids()
	var anything_to_save: bool = false
	for cell_id: String in cell_ids:
		_set_state(cell_id, WorldCellLifecycle.State.SAVING)
		if world.cell_index.count_in_cell(cell_id) > 0 or saved_ids.has(cell_id):
			anything_to_save = true
	var error: Error = _store.save_cells(world, cell_ids) if anything_to_save else OK
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


## True when two WorldCellGrid signatures describe the same grid.
static func _same_grid(a: Dictionary, b: Dictionary) -> bool:
	var numbers_a: Array = _grid_numbers(a)
	var numbers_b: Array = _grid_numbers(b)
	if numbers_a.is_empty() or numbers_a.size() != numbers_b.size():
		return false
	for index: int in range(numbers_a.size()):
		if absf(float(numbers_a[index]) - float(numbers_b[index])) > GRID_EPSILON_M:
			return false
	return true


## The numbers of a grid signature in a fixed order; [] when it is malformed.
static func _grid_numbers(signature: Dictionary) -> Array:
	var numbers: Array = [signature.get(WorldCellGrid.KEY_CELL_SIZE, null)]
	for key: String in [WorldCellGrid.KEY_BOUNDS_MIN, WorldCellGrid.KEY_BOUNDS_MAX]:
		var corner: Variant = signature.get(key, null)
		if typeof(corner) != TYPE_ARRAY or (corner as Array).size() != 2:
			return []
		numbers.append_array(corner as Array)
	for value: Variant in numbers:
		if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
			return []
	return numbers


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
