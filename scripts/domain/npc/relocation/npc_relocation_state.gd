class_name NpcRelocationState
extends NpcComponent
## The move of one NPC to another shelter (F-30, docs/09 §17.15): whether
## it is moving, why, where to and how far it has got. Saved with the NPC,
## so a move goes on after a restart and after its cell left memory; only
## NpcRelocation changes it. The action itself (its step and timer) is the
## behaviour component's, the walk the executor component's, what it
## carries the behaviour component's inventory.
##
## Document (whole numbers and names only: a save never rounds any of it):
##   {phase: "" | "choosing" | "packing" | "travelling" | "settling",
##    reason: why it moves ("" = it does not move):
##            "no_supplies" | "danger" | "hurt" | "attacked",
##    target_building_id, target_tile: [x, z]: the building it moves to and
##            its home tile there (from "packing" on; its own home when it
##            gave a destination up and found nothing else),
##    scan_index: cells it has listed while choosing,
##    container_index: the container of its home it walks to or packs,
##    packed: it has taken what it carries out of its home,
##    packed_units: units it took out of its home for this move,
##    leg_failures: legs in a row that found no way,
##    started_day: the calendar day the move (or its last choice) began,
##    from_here: it chooses from where it stands and may go back home (it
##            gave a destination up),
##    attacked: somebody attacked it at home (F-32 sets it): it moves,
##    last_settled_day: the calendar day it last moved in (-1 = never),
##    moves: how often it has moved,
##    no_choice_until_world_sec: it found nowhere to go and looks again
##            from this calendar second on}
## A key whose value is the default is left out: the document of an NPC
## that never moved is empty. An NPC saved before this component existed
## gets an empty one.

const COMPONENT_ID: String = "relocation"
const SCHEMA_VERSION: int = 1

const PHASE_NONE: String = ""
## Standing, listing the buildings it could move to.
const PHASE_CHOOSING: String = "choosing"
## At home: walking to a container, or taking things out of it.
const PHASE_PACKING: String = "packing"
## On the way, leg by leg.
const PHASE_TRAVELLING: String = "travelling"
## On the home tile of the new home.
const PHASE_SETTLING: String = "settling"
const PHASES: PackedStringArray = [PHASE_NONE, PHASE_CHOOSING, PHASE_PACKING, PHASE_TRAVELLING, PHASE_SETTLING]

const REASON_NO_SUPPLIES: String = "no_supplies"
const REASON_DANGER: String = "danger"
const REASON_HURT: String = "hurt"
const REASON_ATTACKED: String = "attacked"
const REASONS: PackedStringArray = [REASON_NO_SUPPLIES, REASON_DANGER, REASON_HURT, REASON_ATTACKED]

const NO_CONTAINER: int = -1
const NEVER: int = -1
const MAX_SAFE_INT: int = 9007199254740991

const KEY_PHASE: String = "phase"
const KEY_REASON: String = "reason"
const KEY_TARGET: String = "target_building_id"
const KEY_TARGET_TILE: String = "target_tile"
const KEY_SCAN_INDEX: String = "scan_index"
const KEY_CONTAINER_INDEX: String = "container_index"
const KEY_PACKED: String = "packed"
const KEY_PACKED_UNITS: String = "packed_units"
const KEY_LEG_FAILURES: String = "leg_failures"
const KEY_STARTED_DAY: String = "started_day"
const KEY_FROM_HERE: String = "from_here"
const KEY_ATTACKED: String = "attacked"
const KEY_LAST_SETTLED_DAY: String = "last_settled_day"
const KEY_MOVES: String = "moves"
const KEY_NO_CHOICE_UNTIL: String = "no_choice_until_world_sec"

var phase: String = PHASE_NONE
var reason: String = ""
var target_building_id: String = ""
var target_tile: Vector2i = Vector2i.ZERO
var scan_index: int = 0
var container_index: int = NO_CONTAINER
var packed: bool = false
var packed_units: int = 0
var leg_failures: int = 0
var started_day: int = 0
var from_here: bool = false
var attacked: bool = false
var last_settled_day: int = NEVER
var moves: int = 0
var no_choice_until_world_sec: int = 0


static func make() -> NpcComponent:
	return NpcRelocationState.new()


## The relocation component of an NPC, or null.
static func of(npc: NpcState) -> NpcRelocationState:
	return npc.component(COMPONENT_ID) as NpcRelocationState if npc != null else null


func component_id() -> String:
	return COMPONENT_ID


func schema_version() -> int:
	return SCHEMA_VERSION


func is_moving() -> bool:
	return phase != PHASE_NONE


func has_target() -> bool:
	return not target_building_id.is_empty()


## A move begins: the NPC chooses where to.
func begin(why: String, day: int) -> void:
	clear_move()
	phase = PHASE_CHOOSING
	reason = why
	started_day = maxi(day, 0)


## The NPC chooses again (it gave its destination up), from where it stands.
func choose_again(day: int) -> void:
	phase = PHASE_CHOOSING
	target_building_id = ""
	target_tile = Vector2i.ZERO
	scan_index = 0
	container_index = NO_CONTAINER
	leg_failures = 0
	started_day = maxi(day, 0)
	from_here = true


## Forgets the move it is in the middle of. What it knows (when it last
## moved, how often) stays.
func clear_move() -> void:
	phase = PHASE_NONE
	reason = ""
	target_building_id = ""
	target_tile = Vector2i.ZERO
	scan_index = 0
	container_index = NO_CONTAINER
	packed = false
	packed_units = 0
	leg_failures = 0
	started_day = 0
	from_here = false


func to_document() -> Dictionary:
	var document: Dictionary = {}
	if is_moving():
		document[KEY_PHASE] = phase
		document[KEY_REASON] = reason
		document[KEY_STARTED_DAY] = started_day
		if has_target():
			document[KEY_TARGET] = target_building_id
			document[KEY_TARGET_TILE] = [target_tile.x, target_tile.y]
		if scan_index != 0:
			document[KEY_SCAN_INDEX] = scan_index
		if container_index != NO_CONTAINER:
			document[KEY_CONTAINER_INDEX] = container_index
		if packed:
			document[KEY_PACKED] = true
		if packed_units != 0:
			document[KEY_PACKED_UNITS] = packed_units
		if leg_failures != 0:
			document[KEY_LEG_FAILURES] = leg_failures
		if from_here:
			document[KEY_FROM_HERE] = true
	if attacked:
		document[KEY_ATTACKED] = true
	if last_settled_day != NEVER:
		document[KEY_LAST_SETTLED_DAY] = last_settled_day
	if moves != 0:
		document[KEY_MOVES] = moves
	if no_choice_until_world_sec != 0:
		document[KEY_NO_CHOICE_UNTIL] = no_choice_until_world_sec
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
		return errors
	var moving: bool = str(saved_phase) != PHASE_NONE
	var saved_reason: Variant = document.get(KEY_REASON, "")
	if typeof(saved_reason) != TYPE_STRING or (moving != REASONS.has(str(saved_reason))) or (not moving and not str(saved_reason).is_empty()):
		errors.append("reason and phase do not agree")
	var saved_target: Variant = document.get(KEY_TARGET, "")
	if typeof(saved_target) != TYPE_STRING or not (str(saved_target).is_empty() or ItemInstance.is_valid_definition_id(str(saved_target))):
		errors.append("target_building_id must be a snake_case id or empty")
		return errors
	var has_saved_target: bool = not str(saved_target).is_empty()
	var saved_tile: Variant = document.get(KEY_TARGET_TILE, [0, 0])
	if typeof(saved_tile) != TYPE_ARRAY or (saved_tile as Array).size() != 2 or not NpcHome._is_tile_value((saved_tile as Array)[0]) or not NpcHome._is_tile_value((saved_tile as Array)[1]):
		errors.append("target_tile must be two whole numbers")
	if has_saved_target and not moving:
		errors.append("a target without a move")
	# From packing on a move knows where it goes; while choosing it does not.
	if moving and has_saved_target == (str(saved_phase) == PHASE_CHOOSING):
		errors.append("phase and target_building_id do not agree")
	if not _is_whole(document.get(KEY_CONTAINER_INDEX, NO_CONTAINER), NO_CONTAINER):
		errors.append("container_index must be a whole number >= -1")
	if not _is_whole(document.get(KEY_LAST_SETTLED_DAY, NEVER), NEVER):
		errors.append("last_settled_day must be a whole number >= -1")
	for key: String in [KEY_SCAN_INDEX, KEY_PACKED_UNITS, KEY_LEG_FAILURES, KEY_STARTED_DAY, KEY_MOVES, KEY_NO_CHOICE_UNTIL]:
		if not _is_whole(document.get(key, 0), 0):
			errors.append("%s must be a whole number >= 0" % key)
	for key: String in [KEY_PACKED, KEY_FROM_HERE, KEY_ATTACKED]:
		if typeof(document.get(key, false)) != TYPE_BOOL:
			errors.append("%s must be true or false" % key)
	if not errors.is_empty():
		return errors
	phase = str(saved_phase)
	reason = str(saved_reason)
	target_building_id = str(saved_target)
	target_tile = Vector2i(int((saved_tile as Array)[0]), int((saved_tile as Array)[1])) if has_saved_target else Vector2i.ZERO
	scan_index = int(document.get(KEY_SCAN_INDEX, 0))
	container_index = int(document.get(KEY_CONTAINER_INDEX, NO_CONTAINER))
	packed = bool(document.get(KEY_PACKED, false))
	packed_units = int(document.get(KEY_PACKED_UNITS, 0))
	leg_failures = int(document.get(KEY_LEG_FAILURES, 0))
	started_day = int(document.get(KEY_STARTED_DAY, 0))
	from_here = bool(document.get(KEY_FROM_HERE, false))
	attacked = bool(document.get(KEY_ATTACKED, false))
	last_settled_day = int(document.get(KEY_LAST_SETTLED_DAY, NEVER))
	moves = int(document.get(KEY_MOVES, 0))
	no_choice_until_world_sec = int(document.get(KEY_NO_CHOICE_UNTIL, 0))
	return errors


static func _is_whole(value: Variant, least: int) -> bool:
	return ItemInstance.is_integer_value(value) and float(value) >= float(least) and float(value) <= float(MAX_SAFE_INT)
