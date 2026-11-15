class_name CharacterCreationModel
extends RefCounted
## What the character creation screen holds while the player chooses
## (docs/09 §14.24): one option per appearance slot. Pure: no nodes, so the
## cycling, the random button and the local name check are unit tested.
## Nothing here is authoritative: the server checks the request again with
## the same CharacterRules.

var rules: CharacterRules

## slot id -> option id; always a complete, valid selection.
var _selection: Dictionary = {}


func _init(character_rules: CharacterRules) -> void:
	rules = character_rules
	reset()


## Back to the default option of every slot.
func reset() -> void:
	_selection = rules.catalog.default_selection()


## A copy of the current selection {slot_id: option_id}.
func selection() -> Dictionary:
	return _selection.duplicate()


## The chosen option id of a slot ("" for an unknown slot).
func option_id(slot_id: String) -> String:
	return str(_selection.get(slot_id, ""))


## The chosen option of a slot (null for an unknown slot).
func option(slot_id: String) -> AppearanceOption:
	var slot: AppearanceSlot = rules.catalog.get_slot(slot_id)
	return slot.get_option(option_id(slot_id)) if slot != null else null


## Moves the choice of a slot by `step` options (wrapping around both
## ends). Returns the new option id ("" for an unknown slot).
func cycle(slot_id: String, step: int) -> String:
	var slot: AppearanceSlot = rules.catalog.get_slot(slot_id)
	if slot == null:
		return ""
	var index: int = posmod(slot.index_of(option_id(slot_id)) + step, slot.options.size())
	_selection[slot_id] = slot.options[index].option_id
	return option_id(slot_id)


## Chooses one option. False (no change) when the slot or option is unknown.
func select(slot_id: String, wanted_option_id: String) -> bool:
	var slot: AppearanceSlot = rules.catalog.get_slot(slot_id)
	if slot == null or not slot.has_option(wanted_option_id):
		return false
	_selection[slot_id] = wanted_option_id
	return true


## A random option for every slot (the random button).
func randomize_selection(rng: RandomNumberGenerator) -> void:
	_selection = rules.catalog.random_selection(rng)


## Checks what would be sent with the rules the server applies. Success
## event: {"name": cleaned name, "appearance": the selection}.
func check(raw_name: String) -> ActionResult:
	return rules.check_request(raw_name, _selection)
