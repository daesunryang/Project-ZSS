class_name BuildingSettings
extends Resource
## Building grid and placement tuning (P3-4a, docs/04 §2, docs/00 ADR-024).
## Defaults in `res://data/tuning/building_settings.tres`. Every value is
## PROVISIONAL (docs/15 §15.4 P3-091..) until play-tested: the user tunes
## numbers and rules at the end of Phase 3.

const DEFAULT_PATH: String = "res://data/tuning/building_settings.tres"

@export_group("Grid")
## Edge of one square building tile, metres (docs/04 §2: start with a 1 m
## module). Tile (tx, tz) covers [tx * m, (tx + 1) * m) on X and on Z, world
## origin based. Changing it moves every saved structure: saves keep tile
## coordinates, not metres.
@export_range(0.1, 100.0) var grid_module_m: float = 1.0

@export_group("Placement")
## Largest distance between the placing player (server position) and the
## piece (centre of a tile piece, middle of an edge piece), metres.
@export_range(0.1, 100.0) var placement_range_m: float = 4.0
## Largest distance between a player and a structure it demolishes, metres.
@export_range(0.1, 100.0) var demolish_range_m: float = 4.0
## Largest distance between a player and a door it opens or closes, metres.
@export_range(0.1, 100.0) var door_interact_range_m: float = 2.5
## Dev rule (docs/00 ADR-024): a placed structure is `completed` at once.
## false = it is placed as a `blueprint` that takes its slot but blocks
## nothing; the blueprint -> work -> completed flow is P3-5.
@export var instant_completion: bool = true
## A newly placed door is open (true) or closed (false).
@export var door_starts_open: bool = false
## A blocking piece (a wall, a closed door) cannot be placed, and a door
## cannot be closed, while a living player or a living zombie is closer than
## this to its edge, metres. 0 = no such check.
@export_range(0.0, 10.0) var blocker_clearance_m: float = 0.3
## Structures one world cell may hold in memory (all states). A placement
## beyond it is refused. Bounds what one cell document and one cell
## announcement can carry.
@export_range(1, 1000000) var max_structures_per_cell: int = 4000
## Material quality given to a placed piece (1 = normal). Nothing reads it
## yet; materials are P3-5.
@export_range(0.0, 10.0) var default_material_quality: float = 1.0

@export_group("Collision")
## A mover that is stopped by a blocking edge ends this far in front of it,
## metres, so it never stands on the edge line itself. Must be smaller than
## half a module.
@export_range(0.001, 1.0) var collision_skin_m: float = 0.05
## Kinds of movers (entity kinds: "player", "zombie") that keep the part of
## a blocked step that runs along the blocking edge (sliding). Every other
## mover simply stops in front of the edge.
@export var sliding_mover_kinds: PackedStringArray = PackedStringArray(["player"])

@export_group("Events")
## Structure events kept between two drains (BuildingService.drain_events).
## The network module drains every server tick; this only bounds a world
## that nobody drains.
@export_range(1, 1000000) var max_pending_events: int = 4096


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(grid_module_m) or grid_module_m <= 0.0:
		errors.append("building grid_module_m must be > 0")
	for value: float in [placement_range_m, demolish_range_m, door_interact_range_m]:
		if not is_finite(value) or value <= 0.0:
			errors.append("building ranges must be > 0")
			break
	if not is_finite(blocker_clearance_m) or blocker_clearance_m < 0.0:
		errors.append("building blocker_clearance_m must be >= 0")
	if max_structures_per_cell < 1:
		errors.append("building max_structures_per_cell must be >= 1")
	if not is_finite(default_material_quality) or default_material_quality < 0.0:
		errors.append("building default_material_quality must be >= 0")
	if not is_finite(collision_skin_m) or collision_skin_m <= 0.0 or collision_skin_m * 2.0 >= grid_module_m:
		errors.append("building collision_skin_m must be > 0 and smaller than half a module")
	if max_pending_events < 1:
		errors.append("building max_pending_events must be >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> BuildingSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is BuildingSettings:
		return loaded as BuildingSettings
	GameLogger.warning("config", "building settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return BuildingSettings.new()
