class_name NpcSpotDefinition
extends Resource
## One place an NPC goes to do something (P4-5a, docs/13 §16.3 D7, docs/09
## §17.7): a bed, a work place, a water point, the food container of a
## house. Pure data, part of an NpcSpotSet. No owner and no ration rule
## (D7); who may use a spot right now is the reservation table's business
## (NpcReservations).

const KIND_BED: String = "bed"
const KIND_WORK: String = "work"
const KIND_WATER: String = "water"
## The tile of a container that holds food (MapContainerPlacement).
const KIND_FOOD: String = "food"
const KINDS: PackedStringArray = [KIND_BED, KIND_WORK, KIND_WATER, KIND_FOOD]

## Stable snake_case id, unique in its set. Saved with the NPCs that use or
## reserved the spot: never rename it.
@export var spot_id: String = ""
## One of the KIND_ constants.
@export var kind: String = KIND_BED
## MapBuildingDefinition.building_id of the building the spot is in. "" =
## the spot is outdoors and `tile_offset` is a tile of the world grid.
@export var building_id: String = ""
## The tile, counted from the building's `origin_tile` (0 .. size - 1). The
## NPC stands at the centre of that tile.
@export var tile_offset: Vector2i = Vector2i.ZERO
## True: one NPC at a time (it must be reserved to be used). False: any
## number of NPCs (a food container).
@export var exclusive: bool = true


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not NpcComponent.is_valid_id(spot_id):
		errors.append("spot_id '%s' must be snake_case" % spot_id)
	if not KINDS.has(kind):
		errors.append("spot %s: unknown kind '%s'" % [spot_id, kind])
	if not building_id.is_empty() and not ItemInstance.is_valid_definition_id(building_id):
		errors.append("spot %s: building_id '%s' must be snake_case" % [spot_id, building_id])
	return errors
