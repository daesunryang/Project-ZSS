class_name CharacterProfile
extends RefCounted
## Who a character is to the eye: its name and its appearance selection
## (docs/00 ADR-015, docs/09 §14.24). Part of PlayerState; saved in the
## player file as {"name": String, "appearance": {slot_id: option_id}}.
##
## This class checks the document's shape only. Whether the name satisfies
## the name rules and the ids exist in the appearance data is decided by
## CharacterRules when a character is created; a saved profile is repaired
## against today's data when it is loaded (CharacterRules.restore_profile).

const KEY_NAME: String = "name"
const KEY_APPEARANCE: String = "appearance"

var name: String = ""
## slot id -> option id.
var appearance: Dictionary = {}


static func create(character_name: String, selection: Dictionary) -> CharacterProfile:
	var profile: CharacterProfile = CharacterProfile.new()
	profile.name = character_name
	profile.appearance = selection.duplicate()
	return profile


func copy() -> CharacterProfile:
	return create(name, appearance)


func to_dict() -> Dictionary:
	return {KEY_NAME: name, KEY_APPEARANCE: appearance.duplicate()}


## Returns null when `data` is malformed.
static func from_dict(data: Variant) -> CharacterProfile:
	if not validate_dict(data).is_empty():
		return null
	var document: Dictionary = data
	return create(str(document[KEY_NAME]), document[KEY_APPEARANCE] as Dictionary)


static func validate_dict(data: Variant) -> PackedStringArray:
	var errors: PackedStringArray = []
	if typeof(data) != TYPE_DICTIONARY:
		errors.append("character must be an object")
		return errors
	var document: Dictionary = data
	var character_name: Variant = document.get(KEY_NAME, null)
	if typeof(character_name) != TYPE_STRING or (character_name as String).is_empty() or (character_name as String).length() > CharacterNameRules.HARD_MAX_LENGTH:
		errors.append("character name must be a string of 1..%d characters" % CharacterNameRules.HARD_MAX_LENGTH)
	var selection: Variant = document.get(KEY_APPEARANCE, null)
	if typeof(selection) != TYPE_DICTIONARY:
		errors.append("character appearance must be an object")
		return errors
	if (selection as Dictionary).size() > AppearanceCatalog.MAX_SLOTS:
		errors.append("character appearance has too many entries")
		return errors
	for key: Variant in (selection as Dictionary):
		var value: Variant = (selection as Dictionary)[key]
		if typeof(key) != TYPE_STRING or typeof(value) != TYPE_STRING:
			errors.append("character appearance must map strings to strings")
			break
		if (key as String).length() > AppearanceSlot.ID_MAX_LENGTH or (value as String).length() > AppearanceSlot.ID_MAX_LENGTH:
			errors.append("character appearance ids are too long")
			break
	return errors
