class_name PlayerSkills
extends RefCounted
## The skill experience of one player's current character (F-9): skill id ->
## experience, 0..SkillSettings.max_xp(). A skill without an entry has 0
## (level 1). Saved as the "skills" fragment of the player file
## (SkillService.to_player_fragment).
##
## Fragment format (schema 1): {"schema_version": 1, "xp": {skill id: int}}.

const SCHEMA_VERSION: int = 1
const KEY_XP: String = "xp"

var xp: Dictionary[String, int] = {}


func xp_of(skill_id: String) -> int:
	return int(xp.get(skill_id, 0))


func to_dict() -> Dictionary:
	var saved: Dictionary = {}
	for skill_id: String in xp:
		saved[skill_id] = xp[skill_id]
	return {"schema_version": SCHEMA_VERSION, KEY_XP: saved}


## [PlayerSkills or null, errors]. Skills the settings no longer list are
## dropped with a warning (a removed skill must not make a save unloadable);
## experience above the cap is lowered to it.
static func from_dict(data: Dictionary, settings: SkillSettings) -> Array:
	var errors: PackedStringArray = []
	if not data.has("schema_version") or not ItemInstance.is_integer_value(data["schema_version"]) or int(data["schema_version"]) != SCHEMA_VERSION:
		errors.append("unsupported skills schema_version")
		return [null, errors]
	if typeof(data.get(KEY_XP, null)) != TYPE_DICTIONARY:
		errors.append("skills xp must be an object")
		return [null, errors]
	var skills: PlayerSkills = PlayerSkills.new()
	var saved: Dictionary = data[KEY_XP]
	for key: Variant in saved:
		var skill_id: String = str(key)
		var value: Variant = saved[key]
		if not ItemInstance.is_integer_value(value) or int(value) < 0:
			errors.append("skill %s xp must be an integer >= 0" % skill_id)
			continue
		if not settings.has_skill(skill_id):
			GameLogger.warning("skills", "saved experience of an unknown skill dropped", {"skill_id": skill_id, "operation": "restore_skills"})
			continue
		skills.xp[skill_id] = mini(int(value), settings.max_xp())
	if not errors.is_empty():
		return [null, errors]
	return [skills, errors]
