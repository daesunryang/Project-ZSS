class_name AppearanceSlot
extends Resource
## One customisable part of a character's appearance (docs/00 ADR-015,
## docs/09 §14.24): body type, height, skin tone, hair style, ... Static
## definition data, one `.tres` per slot in
## `res://resources/definitions/appearance/`. Adding a slot or an option is a
## data change: the server validation, the save format, the replication and
## the creation screen all read the slots from AppearanceCatalog.
##
## A character stores "slot id -> option id". Colours are a palette (the
## options of a slot), never free RGB: the server only has to check that the
## id exists, and nothing unsuitable can be sent (docs/15 P2-161).

## What the options of a slot mean.
const KIND_STYLE: String = "style"  # a named shape (hair style); no value
const KIND_COLOR: String = "color"  # AppearanceOption.color
const KIND_SCALE: String = "scale"  # AppearanceOption.scale
const KINDS: PackedStringArray = [KIND_STYLE, KIND_COLOR, KIND_SCALE]

## How the placeholder capsule shows the slot until character models exist
## (docs/11 §2.8). "" = stored and replicated, but not visible yet.
const ROLE_NONE: String = ""
const ROLE_CAPSULE_COLOR: String = "capsule_color"    # needs kind "color"
const ROLE_CAPSULE_HEIGHT: String = "capsule_height"  # needs kind "scale"
const ROLE_CAPSULE_RADIUS: String = "capsule_radius"  # needs kind "scale"
const ROLES: PackedStringArray = [ROLE_NONE, ROLE_CAPSULE_COLOR, ROLE_CAPSULE_HEIGHT, ROLE_CAPSULE_RADIUS]

const ID_PATTERN: String = "^[a-z][a-z0-9_]*$"
## Longest slot / option id (also the longest id a client accepts).
const ID_MAX_LENGTH: int = 64
## Sanity bounds of a scale option.
const MIN_SCALE: float = 0.25
const MAX_SCALE: float = 4.0

## Stable snake_case id. Saved and sent over the network: never rename it.
@export var slot_id: String = ""
## Text shown in the character creation screen.
@export var display_name: String = ""
## Position in the creation screen (ascending; ties by slot id).
@export var sort_order: int = 0
## One of KINDS.
@export var kind: String = KIND_STYLE
## One of ROLES.
@export var visual_role: String = ROLE_NONE
@export var options: Array[AppearanceOption] = []
## The option of a character that never chose (older saves, headless
## clients, a slot added later).
@export var default_option_id: String = ""


func option_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for option: AppearanceOption in options:
		ids.append(option.option_id)
	return ids


func has_option(option_id: String) -> bool:
	return index_of(option_id) >= 0


## Position of the option in `options`, or -1.
func index_of(option_id: String) -> int:
	for index: int in options.size():
		if options[index] != null and options[index].option_id == option_id:
			return index
	return -1


## The option with this id, or null.
func get_option(option_id: String) -> AppearanceOption:
	var index: int = index_of(option_id)
	return options[index] if index >= 0 else null


static func is_valid_id(id: String) -> bool:
	return not id.is_empty() and id.length() <= ID_MAX_LENGTH and RegEx.create_from_string(ID_PATTERN).search(id) != null


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_valid_id(slot_id):
		errors.append("slot_id must be snake_case (1..%d characters)" % ID_MAX_LENGTH)
	if display_name.is_empty():
		errors.append("display_name must not be empty")
	if not KINDS.has(kind):
		errors.append("unknown kind '%s'" % kind)
	if not ROLES.has(visual_role):
		errors.append("unknown visual_role '%s'" % visual_role)
	elif visual_role == ROLE_CAPSULE_COLOR and kind != KIND_COLOR:
		errors.append("visual_role %s needs kind %s" % [visual_role, KIND_COLOR])
	elif (visual_role == ROLE_CAPSULE_HEIGHT or visual_role == ROLE_CAPSULE_RADIUS) and kind != KIND_SCALE:
		errors.append("visual_role %s needs kind %s" % [visual_role, KIND_SCALE])
	if options.is_empty():
		errors.append("a slot needs at least one option")
	var seen: Dictionary[String, bool] = {}
	for option: AppearanceOption in options:
		if option == null:
			errors.append("an option is missing")
			continue
		if not is_valid_id(option.option_id):
			errors.append("option id '%s' must be snake_case (1..%d characters)" % [option.option_id.left(ID_MAX_LENGTH), ID_MAX_LENGTH])
		elif seen.has(option.option_id):
			errors.append("duplicate option id '%s'" % option.option_id)
		seen[option.option_id] = true
		if option.display_name.is_empty():
			errors.append("option '%s' has no display_name" % option.option_id.left(ID_MAX_LENGTH))
		if kind == KIND_SCALE and (not is_finite(option.scale) or option.scale < MIN_SCALE or option.scale > MAX_SCALE):
			errors.append("option '%s' scale must be within [%s, %s]" % [option.option_id.left(ID_MAX_LENGTH), str(MIN_SCALE), str(MAX_SCALE)])
	if not has_option(default_option_id):
		errors.append("default_option_id '%s' is not one of the options" % default_option_id.left(ID_MAX_LENGTH))
	return errors
