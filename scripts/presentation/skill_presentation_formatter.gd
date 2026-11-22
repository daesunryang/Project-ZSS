class_name SkillPresentationFormatter
extends RefCounted
## HUD text of the local player's skill levels (F-9). Pure: rows in, lines
## out. Rows are ClientSkillState.rows (SkillService.rows_of format).

const SKILL_NAMES: Dictionary[String, String] = {
	SkillService.SKILL_BUILDING: "건축",
	SkillService.SKILL_REPAIR: "수리",
}


## Display name of a skill (its id when it has none).
static func skill_name(skill_id: String) -> String:
	return SKILL_NAMES.get(skill_id, skill_id)


## One line for every skill: "건축 Lv 3 (경험치 260/450) | 수리 Lv 1 (경험치 0/100)".
## Nothing while the server has told nothing.
static func build_skill_lines(rows: Array[Dictionary]) -> PackedStringArray:
	if rows.is_empty():
		return PackedStringArray()
	var parts: PackedStringArray = []
	for row: Dictionary in rows:
		parts.append(skill_text(row))
	return PackedStringArray([" | ".join(parts)])


static func skill_text(row: Dictionary) -> String:
	var name_text: String = skill_name(str(row.get(SkillService.KEY_SKILL_ID, "")))
	var level: int = int(row.get(SkillService.KEY_LEVEL, SkillSettings.MIN_LEVEL))
	var next_xp: int = int(row.get(SkillService.KEY_NEXT_LEVEL_XP, SkillRules.NO_NEXT_LEVEL))
	if next_xp == SkillRules.NO_NEXT_LEVEL:
		return "%s Lv %d (최고)" % [name_text, level]
	return "%s Lv %d (경험치 %d/%d)" % [name_text, level, int(row.get(SkillService.KEY_XP, 0)), next_xp]
