class_name ClientSkillState
extends RefCounted
## Non-authoritative client mirror of the local player's skill levels (F-9).
## Filled only by SkillNetModule; every incoming DTO is validated before it
## changes anything. It has no send API and decides nothing.

signal changed

## Same value as SkillNetModule.SCHEMA_VERSION.
const SCHEMA_VERSION: int = 1
const ROW_KEYS: Array[String] = [
	SkillService.KEY_SKILL_ID, SkillService.KEY_LEVEL, SkillService.KEY_XP,
	SkillService.KEY_LEVEL_START_XP, SkillService.KEY_NEXT_LEVEL_XP,
]

## Rows exactly as the server sent them (see SkillService.rows_of), in its
## order. Empty until the first valid message.
var rows: Array[Dictionary] = []
## Messages that failed validation.
var rejected_count: int = 0

var _settings: SkillSettings


func _init(settings: SkillSettings) -> void:
	_settings = settings


## Level of one skill as last told (1 when unknown).
func level_of(skill_id: String) -> int:
	for row: Dictionary in rows:
		if str(row[SkillService.KEY_SKILL_ID]) == skill_id:
			return int(row[SkillService.KEY_LEVEL])
	return SkillSettings.MIN_LEVEL


## Applies {"schema_version", "skills": [row, ...]}. False (and nothing
## changes) when anything is malformed.
func apply_snapshot(snapshot: Dictionary) -> bool:
	if snapshot.size() != 2 or not snapshot.has("schema_version") or not snapshot.has("skills"):
		return _reject("keys")
	if typeof(snapshot["schema_version"]) != TYPE_INT or int(snapshot["schema_version"]) != SCHEMA_VERSION:
		return _reject("schema")
	if typeof(snapshot["skills"]) != TYPE_ARRAY or (snapshot["skills"] as Array).size() > _settings.skill_ids.size():
		return _reject("skills")
	var parsed: Array[Dictionary] = []
	var seen: Dictionary[String, bool] = {}
	for value: Variant in snapshot["skills"] as Array:
		if typeof(value) != TYPE_DICTIONARY or not _valid_row(value as Dictionary):
			return _reject("row")
		var skill_id: String = str((value as Dictionary)[SkillService.KEY_SKILL_ID])
		if seen.has(skill_id):
			return _reject("duplicate")
		seen[skill_id] = true
		parsed.append((value as Dictionary).duplicate())
	rows = parsed
	changed.emit()
	return true


func clear() -> void:
	if rows.is_empty():
		return
	rows = []
	changed.emit()


func _valid_row(row: Dictionary) -> bool:
	if row.size() != ROW_KEYS.size():
		return false
	for key: String in ROW_KEYS:
		if not row.has(key):
			return false
	if typeof(row[SkillService.KEY_SKILL_ID]) != TYPE_STRING or not _settings.has_skill(str(row[SkillService.KEY_SKILL_ID])):
		return false
	for key: String in ROW_KEYS.slice(1):
		if typeof(row[key]) != TYPE_INT:
			return false
	var level: int = row[SkillService.KEY_LEVEL]
	var xp: int = row[SkillService.KEY_XP]
	var next_xp: int = row[SkillService.KEY_NEXT_LEVEL_XP]
	if level < SkillSettings.MIN_LEVEL or level > _settings.max_level or xp < 0 or xp > _settings.max_xp():
		return false
	if int(row[SkillService.KEY_LEVEL_START_XP]) < 0 or int(row[SkillService.KEY_LEVEL_START_XP]) > xp:
		return false
	return next_xp == SkillRules.NO_NEXT_LEVEL or next_xp > xp


func _reject(what: String) -> bool:
	rejected_count += 1
	GameLogger.warning("skill_net", "skill snapshot dropped", {"part": what, "operation": "apply_payload"})
	return false
