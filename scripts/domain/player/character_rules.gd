class_name CharacterRules
extends RefCounted
## The rules of "a character with this name and this appearance" (docs/00
## ADR-015, docs/09 §14.24): CharacterSettings (name rules) plus the
## AppearanceCatalog (what can be chosen). Pure: no nodes, no world.
## ServerWorld uses it to decide a creation request, the creation screen
## uses the same object to check what the player typed before sending.

const REASON_BAD_TYPE: String = "bad_type"

var settings: CharacterSettings
var catalog: AppearanceCatalog


func _init(character_settings: CharacterSettings, appearance_catalog: AppearanceCatalog) -> void:
	settings = character_settings
	catalog = appearance_catalog


## Checks an untrusted creation request. Success event:
##   {"name": cleaned name, "appearance": {slot_id: option_id} for every slot}
## Failure: bad_type (name is not a String / appearance is not a Dictionary
## of Strings), then the name's reason (CharacterNameRules.REASON_*), then
## the appearance's (AppearanceCatalog.REASON_*).
func check_request(raw_name: Variant, raw_appearance: Variant) -> ActionResult:
	if typeof(raw_name) != TYPE_STRING or typeof(raw_appearance) != TYPE_DICTIONARY:
		return ActionResult.failure(REASON_BAD_TYPE)
	var name_result: ActionResult = CharacterNameRules.check(raw_name as String, settings)
	if not name_result.ok:
		return name_result
	var appearance_result: ActionResult = catalog.check_selection(raw_appearance)
	if not appearance_result.ok:
		return appearance_result
	return ActionResult.success({
		CharacterProfile.KEY_NAME: name_result.event["name"],
		CharacterProfile.KEY_APPEARANCE: appearance_result.event["appearance"],
	})


## The profile described by a successful check_request() result.
static func profile_of(result: ActionResult) -> CharacterProfile:
	return CharacterProfile.create(str(result.event[CharacterProfile.KEY_NAME]), result.event[CharacterProfile.KEY_APPEARANCE] as Dictionary)


## The character of a player that never chose: the default name and the
## default option of every slot.
func default_profile() -> CharacterProfile:
	return CharacterProfile.create(settings.default_name, catalog.default_selection())


## A loaded profile brought in line with today's appearance data (see
## AppearanceCatalog.restore_selection). The saved name is kept as it is,
## even if the name rules changed since.
func restore_profile(saved: CharacterProfile) -> CharacterProfile:
	return CharacterProfile.create(saved.name, catalog.restore_selection(saved.appearance))
