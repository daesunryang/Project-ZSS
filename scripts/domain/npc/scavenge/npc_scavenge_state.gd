class_name NpcScavengeState
extends NpcComponent
## What one NPC knows about the buildings around it and the trip it is on
## (F-29, docs/09 §17.14). Saved with the NPC, so a trip goes on after a
## restart and after its cell left memory (docs/13 §16.3 D11); only
## NpcScavenging changes it. The action itself (its step and timer) is the
## behaviour component's, the walk the executor component's, what it
## carries the behaviour component's inventory.
##
## Document (whole numbers and names only: a save never rounds any of it):
##   {phase: "" | "to_container" | "searching" | "to_home" | "stowing",
##    building_id: the building the trip searches, also on the way home
##             from it; its own home on a trip that only puts loot away
##             ("" = no trip),
##    container_index: the container it walks to or searches (-1 = none),
##    taken_units: units it took on this trip,
##    left_useful: it left something useful behind on this trip,
##    visited: [{building_id, result: "empty" | "left" | "blocked", day}]
##             oldest first, at most NpcScavengeSettings.max_visited,
##    home_food_units, home_medical_units: what its home held when it last
##             looked (used while the home's cell is not in memory)}
## A key whose value is the default (no trip, nothing visited, 0) is left
## out: the document of an NPC that never scavenged is empty, so NPCs that
## do not live alone cost a save nothing. An NPC saved before this
## component existed gets an empty one.

const COMPONENT_ID: String = "scavenge"
const SCHEMA_VERSION: int = 1

const PHASE_NONE: String = ""
## Walking to a container of the building.
const PHASE_TO_CONTAINER: String = "to_container"
## Standing at the container, searching it.
const PHASE_SEARCHING: String = "searching"
## Walking home with what it found.
const PHASE_TO_HOME: String = "to_home"
## At home, putting it away.
const PHASE_STOWING: String = "stowing"
const PHASES: PackedStringArray = [PHASE_NONE, PHASE_TO_CONTAINER, PHASE_SEARCHING, PHASE_TO_HOME, PHASE_STOWING]

## Nothing useful is left in the building.
const RESULT_EMPTY: String = "empty"
## Something useful is left (it could not carry more): it comes back.
const RESULT_LEFT: String = "left"
## It found no way there (tried again after blocked_forget_days).
const RESULT_BLOCKED: String = "blocked"
const RESULTS: PackedStringArray = [RESULT_EMPTY, RESULT_LEFT, RESULT_BLOCKED]

const NO_CONTAINER: int = -1
const MAX_SAFE_INT: int = 9007199254740991
## Most visits a document may hold (far above any setting).
const MAX_VISITED: int = 512

const KEY_PHASE: String = "phase"
const KEY_BUILDING_ID: String = "building_id"
const KEY_CONTAINER_INDEX: String = "container_index"
const KEY_TAKEN_UNITS: String = "taken_units"
const KEY_LEFT_USEFUL: String = "left_useful"
const KEY_VISITED: String = "visited"
const KEY_RESULT: String = "result"
const KEY_DAY: String = "day"
const KEY_HOME_FOOD: String = "home_food_units"
const KEY_HOME_MEDICAL: String = "home_medical_units"

var phase: String = PHASE_NONE
var building_id: String = ""
var container_index: int = NO_CONTAINER
var taken_units: int = 0
var left_useful: bool = false
## [{building_id, result, day}], oldest first; one entry per building.
var visited: Array[Dictionary] = []
var home_food_units: int = 0
var home_medical_units: int = 0


static func make() -> NpcComponent:
	return NpcScavengeState.new()


## The scavenge component of an NPC, or null.
static func of(npc: NpcState) -> NpcScavengeState:
	return npc.component(COMPONENT_ID) as NpcScavengeState if npc != null else null


func component_id() -> String:
	return COMPONENT_ID


func schema_version() -> int:
	return SCHEMA_VERSION


func is_on_trip() -> bool:
	return phase != PHASE_NONE


## Ends the trip (done, failed or cancelled). What it knows stays.
func clear_trip() -> void:
	phase = PHASE_NONE
	building_id = ""
	container_index = NO_CONTAINER
	taken_units = 0
	left_useful = false


## The result of the NPC's last visit of a building ("" = never there).
func result_of(visited_building_id: String) -> String:
	for entry: Dictionary in visited:
		if str(entry[KEY_BUILDING_ID]) == visited_building_id:
			return str(entry[KEY_RESULT])
	return ""


## The calendar day of that visit (-1 = never there).
func day_of(visited_building_id: String) -> int:
	for entry: Dictionary in visited:
		if str(entry[KEY_BUILDING_ID]) == visited_building_id:
			return int(entry[KEY_DAY])
	return -1


## Writes a visit down (the newest last; an older visit of the same
## building is replaced). At most `capacity` are kept.
func note_visit(visited_building_id: String, result: String, day: int, capacity: int) -> void:
	if visited_building_id.is_empty() or not RESULTS.has(result):
		return
	for index: int in range(visited.size() - 1, -1, -1):
		if str(visited[index][KEY_BUILDING_ID]) == visited_building_id:
			visited.remove_at(index)
	visited.append({KEY_BUILDING_ID: visited_building_id, KEY_RESULT: result, KEY_DAY: maxi(day, 0)})
	while visited.size() > maxi(capacity, 1):
		visited.remove_at(0)


func to_document() -> Dictionary:
	var saved: Array = []
	for entry: Dictionary in visited:
		saved.append({KEY_BUILDING_ID: str(entry[KEY_BUILDING_ID]), KEY_RESULT: str(entry[KEY_RESULT]), KEY_DAY: int(entry[KEY_DAY])})
	var document: Dictionary = {}
	if is_on_trip():
		document[KEY_PHASE] = phase
		document[KEY_BUILDING_ID] = building_id
		document[KEY_CONTAINER_INDEX] = container_index
		document[KEY_TAKEN_UNITS] = taken_units
		document[KEY_LEFT_USEFUL] = left_useful
	if not saved.is_empty():
		document[KEY_VISITED] = saved
	if home_food_units != 0:
		document[KEY_HOME_FOOD] = home_food_units
	if home_medical_units != 0:
		document[KEY_HOME_MEDICAL] = home_medical_units
	return document


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get(KEY_SCHEMA_VERSION, null)) or int(document[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("unsupported schema_version")
		return errors
	# A key that is not there has its default (see to_document).
	var saved_phase: Variant = document.get(KEY_PHASE, PHASE_NONE)
	if typeof(saved_phase) != TYPE_STRING or not PHASES.has(str(saved_phase)):
		errors.append("phase is unknown")
	var saved_building: Variant = document.get(KEY_BUILDING_ID, "")
	if typeof(saved_building) != TYPE_STRING or not (str(saved_building).is_empty() or ItemInstance.is_valid_definition_id(str(saved_building))):
		errors.append("building_id must be a snake_case id or empty")
	if not _is_whole(document.get(KEY_CONTAINER_INDEX, NO_CONTAINER), NO_CONTAINER):
		errors.append("container_index must be a whole number >= -1")
	for key: String in [KEY_TAKEN_UNITS, KEY_HOME_FOOD, KEY_HOME_MEDICAL]:
		if not _is_whole(document.get(key, 0), 0):
			errors.append("%s must be a whole number >= 0" % key)
	if typeof(document.get(KEY_LEFT_USEFUL, false)) != TYPE_BOOL:
		errors.append("left_useful must be true or false")
	var saved_visited: Variant = document.get(KEY_VISITED, [])
	if typeof(saved_visited) != TYPE_ARRAY or (saved_visited as Array).size() > MAX_VISITED:
		errors.append("visited must be a list")
	if not errors.is_empty():
		return errors
	var restored: Array[Dictionary] = []
	var seen: Dictionary[String, bool] = {}
	for raw: Variant in (saved_visited as Array):
		if typeof(raw) != TYPE_DICTIONARY:
			errors.append("a visit must be an object")
			return errors
		var entry: Dictionary = raw
		var id: Variant = entry.get(KEY_BUILDING_ID, null)
		var result: Variant = entry.get(KEY_RESULT, null)
		if typeof(id) != TYPE_STRING or not ItemInstance.is_valid_definition_id(str(id)) or seen.has(str(id)) or typeof(result) != TYPE_STRING or not RESULTS.has(str(result)) or not _is_whole(entry.get(KEY_DAY, null), 0):
			errors.append("invalid visit")
			return errors
		seen[str(id)] = true
		restored.append({KEY_BUILDING_ID: str(id), KEY_RESULT: str(result), KEY_DAY: int(entry[KEY_DAY])})
	if (str(saved_phase) == PHASE_NONE) != str(saved_building).is_empty():
		errors.append("phase and building_id do not agree")
		return errors
	phase = str(saved_phase)
	building_id = str(saved_building)
	container_index = int(document.get(KEY_CONTAINER_INDEX, NO_CONTAINER))
	taken_units = int(document.get(KEY_TAKEN_UNITS, 0))
	left_useful = bool(document.get(KEY_LEFT_USEFUL, false))
	visited = restored
	home_food_units = int(document.get(KEY_HOME_FOOD, 0))
	home_medical_units = int(document.get(KEY_HOME_MEDICAL, 0))
	return errors


static func _is_whole(value: Variant, least: int) -> bool:
	return ItemInstance.is_integer_value(value) and float(value) >= float(least) and float(value) <= float(MAX_SAFE_INT)
