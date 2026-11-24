class_name WorldCellSettings
extends Resource
## World cell grid and cell lifecycle tuning (P3-1, docs/03 §3, docs/00
## ADR-023). Defaults in `res://data/tuning/world_cell_settings.tres`.
## Every value is PROVISIONAL (docs/15 §15.1 P3-001..) until play-tested.
##
## The defaults are the 4 km x 4 km map of F-33 (docs/09 §15.3.1) with the
## 50 m cells the 500 m test map was built with: an 80 x 80 grid, so a
## walking player crosses a cell border every ~12 s and cells really load
## and unload in play. Nothing is kept per cell of the grid, only per cell
## in memory. (docs/03 names 256 m or 512 m cells as candidates for a large
## world; a generated block is one 50 m cell, so the size stayed.)
## With an active radius of 2 everything within 100 m of a player
## is simulated, which covers zombie sight (25 m) and the farthest audible
## noise (99 m) of the Phase 2 defaults.
## All durations are action time (real seconds, docs/09 §14.16).

const DEFAULT_PATH: String = "res://data/tuning/world_cell_settings.tres"

@export_group("Grid")
## Edge of one square cell on the XZ plane, metres. Cell (cx, cz) covers
## [cx * size, (cx + 1) * size) on X and the same on Z: world coordinates
## stay world-origin based.
@export_range(1.0, 10000.0) var cell_size_m: float = 50.0
## Map rectangle (x, z), metres. Cells exist only inside it; a position on
## or beyond its far edge belongs to the last cell.
@export var bounds_min_m: Vector2 = Vector2(-2000.0, -2000.0)
@export var bounds_max_m: Vector2 = Vector2(2000.0, 2000.0)

@export_group("Interest")
## Cells within this many cells of an online player's cell (a square) are
## ACTIVE: simulated.
@export_range(0, 64) var active_radius_cells: int = 2
## Cells within this many cells are kept in memory (PRELOADED when not
## active). Must be greater than `active_radius_cells`, so that an active
## cell never borders an unloaded one.
@export_range(1, 64) var preload_radius_cells: int = 3
## A player's position this many seconds ahead (server position and server
## velocity) also keeps the cells around it in memory (docs/03 §3.1). The
## look-ahead reaches at most one cell; 0 turns it off.
@export_range(0.0, 60.0) var preload_lookahead_sec: float = 4.0

@export_group("Hysteresis")
## An active cell that is no longer wanted stays active this long.
@export_range(0.0, 3600.0) var deactivate_delay_sec: float = 5.0
## A preloaded cell that is no longer wanted stays in memory this long
## before it is saved and released.
@export_range(0.0, 3600.0) var unload_delay_sec: float = 20.0

@export_group("Scheduling")
## Seconds between two looks at the players' cells (0 = every server tick).
@export_range(0.0, 60.0) var refresh_period_sec: float = 0.25
## Cells of the outer preload ring loaded per look. Cells a player needs now
## (the active area and the ring next to it) are never held back.
@export_range(1, 10000) var max_preload_loads_per_refresh: int = 2
## A cell whose load or save failed is tried again after this long.
@export_range(0.0, 3600.0) var retry_delay_sec: float = 5.0


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(cell_size_m) or cell_size_m <= 0.0:
		errors.append("world cells cell_size_m must be > 0")
	if not bounds_min_m.is_finite() or not bounds_max_m.is_finite() or bounds_max_m.x <= bounds_min_m.x or bounds_max_m.y <= bounds_min_m.y:
		errors.append("world cells bounds must be finite and bounds_max_m > bounds_min_m")
	if active_radius_cells < 0:
		errors.append("world cells active_radius_cells must be >= 0")
	if preload_radius_cells <= active_radius_cells:
		errors.append("world cells preload_radius_cells must be > active_radius_cells")
	for value: float in [preload_lookahead_sec, deactivate_delay_sec, unload_delay_sec, refresh_period_sec, retry_delay_sec]:
		if not is_finite(value) or value < 0.0:
			errors.append("world cells durations must be finite and >= 0")
			break
	if max_preload_loads_per_refresh < 1:
		errors.append("world cells max_preload_loads_per_refresh must be >= 1")
	return errors


## Errors when the square play area (GameplaySettings.world_half_extent_m
## around the origin) is not inside the cell bounds: every position a player,
## a zombie or an item can have must fall into a cell of its own.
func validate_play_area(world_half_extent_m: float) -> PackedStringArray:
	var errors: PackedStringArray = []
	if -world_half_extent_m < bounds_min_m.x or -world_half_extent_m < bounds_min_m.y or world_half_extent_m > bounds_max_m.x or world_half_extent_m > bounds_max_m.y:
		errors.append("world cells bounds must contain the play area (world_half_extent_m)")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> WorldCellSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is WorldCellSettings:
		return loaded as WorldCellSettings
	GameLogger.warning("config", "world cell settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return WorldCellSettings.new()
