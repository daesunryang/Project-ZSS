class_name StructureDefinition
extends Resource
## Static definition of a grid structure (docs/04 §2, docs/00 ADR-005,
## ADR-024). Instances (StructureInstance) reference it by `definition_id`
## only; Resources are never stored in saves. One `.tres` per definition in
## `res://resources/definitions/structures/`, loaded by StructureCatalog.
##
## Where a piece sits on the building grid (StructureGrid):
##   TILE  it fills one grid tile (a floor). One tile piece per tile.
##   EDGE  it stands on one side of a tile (a wall, a door). The side is
##         chosen by the rotation of the placed piece; one edge piece per
##         edge, whichever of the two tiles it was placed from.
## A door is an edge piece: it takes the same slot a wall would take
## (docs/04 §2 "문/창문: 벽 슬롯"), not a slot inside a wall. PROVISIONAL
## (docs/15 P3-092, P3-093).

enum Placement { TILE, EDGE }

## Save / log names, indexed by Placement.
const PLACEMENT_NAMES: PackedStringArray = ["tile", "edge"]

@export var definition_id: String = ""
@export var display_name: String = ""
@export_enum("tile", "edge") var placement: int = Placement.TILE
## True when the standing piece stops the server-side movement of players
## and zombies (a door: only while it is closed). Edge pieces only: the
## collision looks at tile edges, not at tiles.
@export var blocks_movement: bool = false
## True when players can open and close the piece (edge pieces only).
@export var is_door: bool = false
## Health of the completed piece. Nothing damages structures yet (P3-4a).
@export_range(1.0, 1000000.0) var max_health: float = 100.0
## What building one piece costs: item definition id -> quantity. Recorded on
## the placed piece (StructureInstance.inventory_costs). NOT checked and NOT
## taken from anybody in P3-4a: blueprints and materials are P3-5.
@export var build_costs: Dictionary[String, int] = {}


func is_edge() -> bool:
	return placement == Placement.EDGE


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(definition_id):
		errors.append("definition_id '%s' must be snake_case" % definition_id)
	if placement != Placement.TILE and placement != Placement.EDGE:
		errors.append("%s: unknown placement" % definition_id)
	if blocks_movement and placement != Placement.EDGE:
		errors.append("%s: only edge pieces can block movement" % definition_id)
	if is_door and placement != Placement.EDGE:
		errors.append("%s: a door must be an edge piece" % definition_id)
	if not is_finite(max_health) or max_health <= 0.0:
		errors.append("%s: max_health must be > 0" % definition_id)
	for item_id: String in build_costs:
		if not ItemInstance.is_valid_definition_id(item_id) or build_costs[item_id] < 1:
			errors.append("%s: build_costs must map item definition ids to quantities >= 1" % definition_id)
			break
	return errors
