class_name InterestSettings
extends Resource
## Per-client replication scope by world cell (P3-2, docs/09 §15.2). Defaults
## in `res://data/tuning/interest_settings.tres`. Every value is PROVISIONAL
## (docs/15 §15.2 P3-031..): nothing here was chosen by playing or by
## measuring a real network.
##
## A joined peer is told about the entities of the cells around its player's
## SERVER position (CellInterest). The area is a square of cells, like the
## areas of WorldCellSettings: with 50 m cells and a radius of 2 a client
## sees at least 100 m and at most 150 m in every direction.

const DEFAULT_PATH: String = "res://data/tuning/interest_settings.tres"

## Cells within this many cells of the cell a peer's player is in (a square,
## Chebyshev distance) become of interest to that peer.
@export_range(0, 64) var interest_radius_cells: int = 2
## Hysteresis: a cell that is of interest stays so until it is more than
## `interest_radius_cells + keep_margin_cells` cells away. With a margin of
## at least 1, walking to and fro across one cell border changes nothing
## after the first crossing.
@export_range(0, 64) var keep_margin_cells: int = 1


## Farthest cell (in cells) a peer may still be told about.
func keep_radius_cells() -> int:
	return interest_radius_cells + keep_margin_cells


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if interest_radius_cells < 0:
		errors.append("interest interest_radius_cells must be >= 0")
	if keep_margin_cells < 0:
		errors.append("interest keep_margin_cells must be >= 0")
	return errors


## Errors when a peer could be interested in a cell the server does not keep
## in memory around that peer's player: the whole kept area (radius + margin)
## must lie inside the preload area of the cell lifecycle. (A cell that is
## not in memory is never announced anyway, see CellInterest; this check
## keeps the two settings from silently disagreeing.)
func validate_against(world_cells: WorldCellSettings) -> PackedStringArray:
	var errors: PackedStringArray = []
	if world_cells == null:
		errors.append("interest settings need the world cell settings")
		return errors
	if keep_radius_cells() > world_cells.preload_radius_cells:
		errors.append("interest interest_radius_cells + keep_margin_cells (%d) must be <= world cells preload_radius_cells (%d)" % [keep_radius_cells(), world_cells.preload_radius_cells])
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> InterestSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is InterestSettings:
		return loaded as InterestSettings
	GameLogger.warning("config", "interest settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return InterestSettings.new()
