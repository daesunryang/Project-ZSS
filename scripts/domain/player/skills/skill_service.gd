class_name SkillService
extends ServerSystem
## Server-authoritative player skill levels (F-9, FD-3, FD-8). System id
## "skills". No networking here (SkillNetModule), no nodes.
##
## What it owns: the experience of every player's current character
## (PlayerSkills), saved as the player file fragment "skills". Only server
## rules add experience: a client never sends experience, a level or a cost.
##
## Public API:
##   add_xp(player_id, skill_id, amount) -> ActionResult
##       reasons: unknown_skill, bad_amount, invalid_player
##   record_structure_built(player_id)   building experience for one finished
##                                       structure (BuildingService)
##   record_repair_done(player_id)       repair experience for one finished
##                                       repair (hook for F-10)
##   level_of(player_id, skill_id), xp_of(player_id, skill_id)
##   reduced_costs(player_id, skill_id, costs)  the material costs a player
##       pays with its level of `skill_id` (SkillRules.reduced_costs);
##       BuildingService uses "building", F-10 uses "repair"
##   rows_of(player_id)                  one row per skill for the owner HUD
##   drain_changed_players()             players whose skills changed since
##                                       the last call (SkillNetModule)
##
## Characters (docs/00 ADR-007, permanent death): skills belong to the
## character. A new character after a death starts at level 1 in every
## skill (on_character_started). PROVISIONAL (docs/15 F9-005).

const SYSTEM_ID: String = "skills"
const SKILL_BUILDING: String = "building"
const SKILL_REPAIR: String = "repair"

const REASON_UNKNOWN_SKILL: String = "unknown_skill"
const REASON_BAD_AMOUNT: String = "bad_amount"
const REASON_INVALID_PLAYER: String = "invalid_player"

## Row keys (rows_of, SkillNetModule, ClientSkillState).
const KEY_SKILL_ID: String = "skill_id"
const KEY_LEVEL: String = "level"
const KEY_XP: String = "xp"
const KEY_LEVEL_START_XP: String = "level_start_xp"
const KEY_NEXT_LEVEL_XP: String = "next_level_xp"

var _settings: SkillSettings
## player id -> skills of its current character.
var _skills: Dictionary[String, PlayerSkills] = {}
## player id -> true: changed since drain_changed_players().
var _changed: Dictionary[String, bool] = {}


func _init(settings: SkillSettings) -> void:
	_settings = settings


func get_system_id() -> String:
	return SYSTEM_ID


func settings() -> SkillSettings:
	return _settings


# ------------------------------------------------------------ rules

## Adds experience to one skill of a player, up to the cap. Success event:
## {player_id, skill_id, xp, level, level_before}.
func add_xp(player_id: String, skill_id: String, amount: int) -> ActionResult:
	if not _settings.has_skill(skill_id):
		return ActionResult.failure(REASON_UNKNOWN_SKILL)
	if amount <= 0:
		return ActionResult.failure(REASON_BAD_AMOUNT)
	if not PlayerState.is_valid_player_id(player_id):
		return ActionResult.failure(REASON_INVALID_PLAYER)
	var skills: PlayerSkills = _skills.get(player_id, null)
	if skills == null:
		skills = PlayerSkills.new()
		_skills[player_id] = skills
	var before: int = skills.xp_of(skill_id)
	var level_before: int = SkillRules.level_for_xp(before, _settings)
	var after: int = mini(before + amount, _settings.max_xp())
	skills.xp[skill_id] = after
	var level: int = SkillRules.level_for_xp(after, _settings)
	if after != before:
		_changed[player_id] = true
	if level != level_before:
		GameLogger.info("skills", "skill level up", {"player_id": player_id, "skill_id": skill_id, "level": level, "xp": after})
	return ActionResult.success({"player_id": player_id, "skill_id": skill_id, "xp": after, "level": level, "level_before": level_before})


## Building experience for one structure whose work this player finished.
func record_structure_built(player_id: String) -> ActionResult:
	if _settings.building_xp_per_structure <= 0:
		return ActionResult.success()
	return add_xp(player_id, SKILL_BUILDING, _settings.building_xp_per_structure)


## Repair experience for one finished repair. Hook for F-10 (weapon repair);
## nothing calls it yet.
func record_repair_done(player_id: String) -> ActionResult:
	if _settings.repair_xp_per_repair <= 0:
		return ActionResult.success()
	return add_xp(player_id, SKILL_REPAIR, _settings.repair_xp_per_repair)


func xp_of(player_id: String, skill_id: String) -> int:
	var skills: PlayerSkills = _skills.get(player_id, null)
	return skills.xp_of(skill_id) if skills != null else 0


## Level 1..max_level (1 for an unknown player or skill).
func level_of(player_id: String, skill_id: String) -> int:
	return SkillRules.level_for_xp(xp_of(player_id, skill_id), _settings)


## The material costs `player_id` pays with its level of `skill_id`. An
## unknown skill or player pays the full costs (level 1).
func reduced_costs(player_id: String, skill_id: String, costs: Dictionary[String, int]) -> Dictionary[String, int]:
	return SkillRules.reduced_costs(costs, level_of(player_id, skill_id), _settings)


## One row per skill, in settings order: {skill_id, level, xp,
## level_start_xp, next_level_xp}. JSON- and RPC-safe.
func rows_of(player_id: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for skill_id: String in _settings.skill_ids:
		var progress: Dictionary = SkillRules.progress_of(xp_of(player_id, skill_id), _settings)
		rows.append({
			KEY_SKILL_ID: skill_id,
			KEY_LEVEL: int(progress["level"]),
			KEY_XP: int(progress["xp"]),
			KEY_LEVEL_START_XP: int(progress["level_start_xp"]),
			KEY_NEXT_LEVEL_XP: int(progress["next_level_xp"]),
		})
	return rows


func drain_changed_players() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_changed.keys())
	_changed.clear()
	return ids


# ------------------------------------------------------------ ServerSystem hooks

func on_character_started(_world: ServerWorld, player_id: String) -> void:
	if _skills.has(player_id):
		_skills.erase(player_id)
		_changed[player_id] = true
		GameLogger.info("skills", "skills reset for a new character", {"player_id": player_id})


func to_player_fragment(player_id: String) -> Dictionary:
	var skills: PlayerSkills = _skills.get(player_id, null)
	return {} if skills == null or skills.xp.is_empty() else skills.to_dict()


func restore_player_fragment(player_id: String, fragment: Dictionary) -> PackedStringArray:
	var parsed: Array = PlayerSkills.from_dict(fragment, _settings)
	var errors: PackedStringArray = parsed[1]
	if not errors.is_empty():
		var prefixed: PackedStringArray = []
		for error: String in errors:
			prefixed.append("%s: %s" % [player_id, error])
		return prefixed
	_skills[player_id] = parsed[0]
	return PackedStringArray()
