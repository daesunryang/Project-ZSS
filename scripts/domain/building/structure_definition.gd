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
## Bounds of `build_costs`: kinds of items one piece may need, and units of
## one kind. They bound a structure row on the wire (ClientStructureState).
const MAX_COST_KINDS: int = 8
const MAX_COST_QUANTITY: int = 10000
const FULL_PERCENT: int = 100

@export var definition_id: String = ""
@export var display_name: String = ""
@export_enum("tile", "edge") var placement: int = Placement.TILE
## True when the standing piece stops the server-side movement of players
## and zombies (a door: only while it is closed). Edge pieces only: the
## collision looks at tile edges, not at tiles.
@export var blocks_movement: bool = false
## True when players can open and close the piece (edge pieces only).
@export var is_door: bool = false
## Optional placeholder mesh size in metres. Vector3.ZERO uses the standard
## tile / edge dimensions from ClientPresentationSettings. This keeps
## furniture-like tile pieces data-driven without changing network rows.
@export var visual_size_m: Vector3 = Vector3.ZERO
## ContainerDefinition created when this piece completes. Empty means the
## structure never becomes a container.
@export var container_definition_id: String = ""
## Health of the completed piece. Nothing damages structures yet (P3-4a).
@export_range(1.0, 1000000.0) var max_health: float = 100.0
## What building one piece costs (docs/04 §5: a blueprint defines the
## material requirement): item definition id -> quantity. Recorded on the
## placed piece (StructureInstance.inventory_costs); players deliver these
## materials to the blueprint (P3-5, BuildingService.try_deliver). {} = a
## piece that needs no materials.
@export var build_costs: Dictionary[String, int] = {}
## Work one piece takes from nothing to completed: seconds (action time,
## docs/00 ADR-006) of ONE worker whose handling multiplier is 1. More
## workers and a lower multiplier scale it (BuildingService). PROVISIONAL
## (docs/15 P3-126).
@export_range(0.1, 100000.0) var build_work_sec: float = 5.0
## Refund rule (docs/04 §5: part of the structure definition): the share of
## the DELIVERED materials, in whole percent, that comes back as world items
## when the unfinished piece is cancelled / when the completed piece is
## demolished. Each kind is rounded down, so a refund never exceeds what was
## delivered; the rest is gone. PROVISIONAL (docs/15 P3-133, P3-134).
@export_range(0, 100) var cancel_refund_percent: int = 100
@export_range(0, 100) var demolish_refund_percent: int = 50


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
	if not visual_size_m.is_finite() or visual_size_m.x < 0.0 or visual_size_m.y < 0.0 or visual_size_m.z < 0.0 or (visual_size_m != Vector3.ZERO and (visual_size_m.x <= 0.0 or visual_size_m.y <= 0.0 or visual_size_m.z <= 0.0)):
		errors.append("%s: visual_size_m must be zero or positive on every axis" % definition_id)
	if not container_definition_id.is_empty() and not ItemInstance.is_valid_definition_id(container_definition_id):
		errors.append("%s: container_definition_id must be snake_case or empty" % definition_id)
	if not is_finite(max_health) or max_health <= 0.0:
		errors.append("%s: max_health must be > 0" % definition_id)
	if build_costs.size() > MAX_COST_KINDS:
		errors.append("%s: build_costs names more than %d kinds of items" % [definition_id, MAX_COST_KINDS])
	for item_id: String in build_costs:
		if not ItemInstance.is_valid_definition_id(item_id) or build_costs[item_id] < 1 or build_costs[item_id] > MAX_COST_QUANTITY:
			errors.append("%s: build_costs must map item definition ids to quantities 1..%d" % [definition_id, MAX_COST_QUANTITY])
			break
	if not is_finite(build_work_sec) or build_work_sec <= 0.0:
		errors.append("%s: build_work_sec must be > 0" % definition_id)
	for percent: int in [cancel_refund_percent, demolish_refund_percent]:
		if percent < 0 or percent > FULL_PERCENT:
			errors.append("%s: refund percents must be 0..%d" % [definition_id, FULL_PERCENT])
			break
	return errors


## What comes back of `delivered` (item definition id -> units) at `percent`:
## each kind rounded down, kinds that round to nothing left out. Whole-number
## math, so 100 percent is exactly what was delivered and no refund is ever
## larger than it.
static func refund_of(delivered: Dictionary[String, int], percent: int) -> Dictionary[String, int]:
	var refund: Dictionary[String, int] = {}
	var share: int = clampi(percent, 0, FULL_PERCENT)
	for item_id: String in delivered:
		# Whole-number division on purpose: a refund is rounded down.
		var units: int = delivered[item_id] * share / FULL_PERCENT
		if units > 0:
			refund[item_id] = units
	return refund
