class_name NpcHome
extends NpcComponent
## Where one NPC lives (F-28, docs/09 §17.13): the part of an NPC's state
## that says which building is its home. Saved with the NPC, because a home
## is not a fact of the definition any more: a lone NPC got a generated
## building chosen with the world seed, and later tickets let it move
## (F-30).
##
## Two sources:
##   "definition"  the home (and the work place) its NpcDefinition names on
##                 the hand-made map. Every NPC starts like this: a
##                 hand-spawned NPC, an NPC of a world without a generated
##                 map, and an NPC that was saved before this component
##                 existed.
##   "generated"   a building of the generated map (`building_id`, a
##                 ProceduralMapGenerator id) and the tile it stands on when
##                 it is at home (`tile`, a tile of the world grid). Such an
##                 NPC lives alone and has no work place: nothing sends it
##                 to work (the action "work" is refused with no_job).
##
## Document: {source} or {source: "generated", building_id, tile: [x, z]}.

const COMPONENT_ID: String = "home"
const SOURCE_DEFINITION: String = "definition"
const SOURCE_GENERATED: String = "generated"
const KEY_SOURCE: String = "source"
const KEY_BUILDING_ID: String = "building_id"
const KEY_TILE: String = "tile"
## Largest tile coordinate a document may name (far beyond any world).
const MAX_TILE: int = 10000000

var source: String = SOURCE_DEFINITION
## A generated home only.
var building_id: String = ""
var tile: Vector2i = Vector2i.ZERO


static func make() -> NpcComponent:
	return NpcHome.new()


## The home component of an NPC, or null (an NPC without one: a world whose
## composition does not register it).
static func of(npc: NpcState) -> NpcHome:
	return npc.component(COMPONENT_ID) as NpcHome if npc != null else null


func component_id() -> String:
	return COMPONENT_ID


func is_generated() -> bool:
	return source == SOURCE_GENERATED


## Makes a generated building this NPC's home.
func set_generated(new_building_id: String, home_tile: Vector2i) -> void:
	source = SOURCE_GENERATED
	building_id = new_building_id
	tile = home_tile


## True when the NPC has a place to work at: only an NPC that lives where
## its definition says, and whose definition names a work building.
func has_work_place(definition: NpcDefinition) -> bool:
	return source == SOURCE_DEFINITION and definition != null and not definition.work_building_id.is_empty()


func to_document() -> Dictionary:
	if source != SOURCE_GENERATED:
		return {KEY_SOURCE: SOURCE_DEFINITION}
	return {KEY_SOURCE: SOURCE_GENERATED, KEY_BUILDING_ID: building_id, KEY_TILE: [tile.x, tile.y]}


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	var saved_source: Variant = document.get(KEY_SOURCE, null)
	if typeof(saved_source) != TYPE_STRING or (str(saved_source) != SOURCE_DEFINITION and str(saved_source) != SOURCE_GENERATED):
		errors.append("source must be definition or generated")
		return errors
	if str(saved_source) == SOURCE_DEFINITION:
		source = SOURCE_DEFINITION
		building_id = ""
		tile = Vector2i.ZERO
		return errors
	var saved_id: Variant = document.get(KEY_BUILDING_ID, null)
	var saved_tile: Variant = document.get(KEY_TILE, null)
	if typeof(saved_id) != TYPE_STRING or not ItemInstance.is_valid_definition_id(str(saved_id)):
		errors.append("building_id must be a snake_case id")
	if typeof(saved_tile) != TYPE_ARRAY or (saved_tile as Array).size() != 2 or not _is_tile_value((saved_tile as Array)[0]) or not _is_tile_value((saved_tile as Array)[1]):
		errors.append("tile must be two whole numbers")
	if not errors.is_empty():
		return errors
	set_generated(str(saved_id), Vector2i(int((saved_tile as Array)[0]), int((saved_tile as Array)[1])))
	return errors


static func _is_tile_value(value: Variant) -> bool:
	return ItemInstance.is_integer_value(value) and absf(float(value)) <= float(MAX_TILE)
