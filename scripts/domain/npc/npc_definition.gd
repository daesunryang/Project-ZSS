class_name NpcDefinition
extends Resource
## Static definition of one NPC: who it is (P4-1, docs/05 §2 "정체성·능력·성격",
## docs/14 §2 "NPCDefinition", docs/09 §17.1). Data only: one `.tres` per NPC
## in `res://resources/definitions/npcs/`, loaded by NpcCatalog. The runtime
## state (NpcState) references it by `definition_id`; Resources are never
## stored in saves. Nothing here changes while the game runs.
##
## Personality (docs/05 §3) and skills (docs/05 §2.2) are 0..1. Personality
## never forces a behaviour: later tickets read it as a weight. The trait
## names are data labels, not diagnoses. Every value of the dev NPCs is
## hand-written and PROVISIONAL (docs/15 §17.1).

## docs/05 §3, in the order of that list.
const PERSONALITY_TRAITS: PackedStringArray = ["extraversion", "agreeableness", "conscientiousness", "openness", "neuroticism", "impulsivity", "self_interest", "courage", "jealousy_proneness", "animal_affinity", "risk_tolerance"]
## docs/05 §2.2. The exported property of a skill is "skill_" + its name.
const SKILL_NAMES: PackedStringArray = ["combat", "medical", "farming", "cooking", "construction", "maintenance", "crafting", "social"]
const SKILL_PROPERTY_PREFIX: String = "skill_"
const AGE_GROUPS: PackedStringArray = ["young_adult", "adult", "middle_aged", "elder"]
## docs/05 §12. "" = no job.
const JOB_ROLES: PackedStringArray = ["guard", "farming", "cooking", "medical", "construction", "maintenance", "cleaning", "gathering", "hunting", "research", "animal_care"]
const NAME_MAX_LENGTH: int = 32
const HOURS_PER_DAY: float = 24.0
const MAX_BACKGROUND_TAGS: int = 16

## Stable snake_case id. Saved with every NPC of this definition: never
## rename it.
@export var definition_id: String = ""
## The NPC's name, as shown to players.
@export var display_name: String = ""
## Appearance: {AppearanceSlot.slot_id: AppearanceOption.option_id}, the
## same selection a player character has (AppearanceCatalog).
@export var appearance: Dictionary = {}
## One of AGE_GROUPS.
@export var age_group: String = "adult"
## Where the NPC comes from and what it was (snake_case labels).
@export var background_tags: PackedStringArray = []

@export_group("Personality (docs/05 §3, 0..1)")
@export_range(0.0, 1.0) var extraversion: float = 0.5
@export_range(0.0, 1.0) var agreeableness: float = 0.5
@export_range(0.0, 1.0) var conscientiousness: float = 0.5
@export_range(0.0, 1.0) var openness: float = 0.5
@export_range(0.0, 1.0) var neuroticism: float = 0.5
@export_range(0.0, 1.0) var impulsivity: float = 0.5
@export_range(0.0, 1.0) var self_interest: float = 0.5
@export_range(0.0, 1.0) var courage: float = 0.5
@export_range(0.0, 1.0) var jealousy_proneness: float = 0.5
@export_range(0.0, 1.0) var animal_affinity: float = 0.5
@export_range(0.0, 1.0) var risk_tolerance: float = 0.5

@export_group("Skills (docs/05 §2.2, 0..1)")
@export_range(0.0, 1.0) var skill_combat: float = 0.0
@export_range(0.0, 1.0) var skill_medical: float = 0.0
@export_range(0.0, 1.0) var skill_farming: float = 0.0
@export_range(0.0, 1.0) var skill_cooking: float = 0.0
@export_range(0.0, 1.0) var skill_construction: float = 0.0
@export_range(0.0, 1.0) var skill_maintenance: float = 0.0
@export_range(0.0, 1.0) var skill_crafting: float = 0.0
@export_range(0.0, 1.0) var skill_social: float = 0.0

@export_group("Work and places")
## One of JOB_ROLES, or "" for none. What the NPC does all day is decided by
## later tickets (P4-5b); nobody assigns jobs yet (docs/13 §16.3 D6).
@export var job_role: String = ""
## Where the NPC lives: a building of the map content
## (MapBuildingDefinition.building_id) and a tile inside it, counted from
## the building's origin tile. A roster places the NPC there. "" = nowhere
## (such a definition cannot be in a roster).
@export var home_building_id: String = ""
@export var home_tile_offset: Vector2i = Vector2i.ZERO
## Where the NPC works: the same kind of reference. "" = nowhere.
@export var work_building_id: String = ""
@export var work_tile_offset: Vector2i = Vector2i.ZERO

@export_group("Sleep (F-6, docs/09 §17.11)")
## The hour of the calendar day (0 <= hour < 24) at which the NPC goes to
## bed: an early hour is a morning type, a late one (it may be past
## midnight, e.g. 0.5) an evening type. The night sleep may begin from this
## hour for NpcDecisionSettings.night_sleep_window_hours, once per night.
## PROVISIONAL per NPC (docs/15 F6-001).
@export_range(0.0, 23.99, 0.25, "suffix:h") var bedtime_hour: float = 22.0


## {trait name: value} of every personality trait, in PERSONALITY_TRAITS
## order.
func personality() -> Dictionary:
	var values: Dictionary = {}
	for trait_name: String in PERSONALITY_TRAITS:
		values[trait_name] = float(get(trait_name))
	return values


## {skill name: value} of every skill, in SKILL_NAMES order.
func skills() -> Dictionary:
	var values: Dictionary = {}
	for skill_name: String in SKILL_NAMES:
		values[skill_name] = float(get(SKILL_PROPERTY_PREFIX + skill_name))
	return values


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_valid_definition_id(definition_id):
		errors.append("npc definition_id '%s' must be snake_case" % definition_id)
	if display_name.strip_edges().is_empty() or display_name.length() > NAME_MAX_LENGTH:
		errors.append("npc %s: display_name must have 1..%d characters" % [definition_id, NAME_MAX_LENGTH])
	if not AGE_GROUPS.has(age_group):
		errors.append("npc %s: unknown age_group '%s'" % [definition_id, age_group])
	if background_tags.size() > MAX_BACKGROUND_TAGS:
		errors.append("npc %s: at most %d background_tags" % [definition_id, MAX_BACKGROUND_TAGS])
	var seen_tags: Dictionary[String, bool] = {}
	for tag: String in background_tags:
		if not ItemInstance.is_valid_definition_id(tag) or seen_tags.has(tag):
			errors.append("npc %s: background_tags must be different snake_case labels ('%s')" % [definition_id, tag])
		seen_tags[tag] = true
	for trait_name: String in PERSONALITY_TRAITS:
		if not _is_unit_value(float(get(trait_name))):
			errors.append("npc %s: %s must be within 0..1" % [definition_id, trait_name])
	for skill_name: String in SKILL_NAMES:
		if not _is_unit_value(float(get(SKILL_PROPERTY_PREFIX + skill_name))):
			errors.append("npc %s: %s%s must be within 0..1" % [definition_id, SKILL_PROPERTY_PREFIX, skill_name])
	if not job_role.is_empty() and not JOB_ROLES.has(job_role):
		errors.append("npc %s: unknown job_role '%s'" % [definition_id, job_role])
	for row: Array in [["home", home_building_id, home_tile_offset], ["work", work_building_id, work_tile_offset]]:
		var building_id: String = str(row[1])
		var offset: Vector2i = row[2]
		if not building_id.is_empty() and not ItemInstance.is_valid_definition_id(building_id):
			errors.append("npc %s: %s_building_id '%s' must be snake_case or empty" % [definition_id, row[0], building_id])
		if offset.x < 0 or offset.y < 0:
			errors.append("npc %s: %s_tile_offset must not be negative" % [definition_id, row[0]])
	if not is_finite(bedtime_hour) or bedtime_hour < 0.0 or bedtime_hour >= HOURS_PER_DAY:
		errors.append("npc %s: bedtime_hour must be within 0..24 (24 excluded)" % definition_id)
	return errors


## Errors of the appearance against the appearance data: it must name an
## option of every slot, like a player character's.
func validate_against(appearance_catalog: AppearanceCatalog) -> PackedStringArray:
	var errors: PackedStringArray = []
	if appearance_catalog != null and not appearance_catalog.is_complete_selection(appearance):
		errors.append("npc %s: appearance must name an existing option of every appearance slot" % definition_id)
	return errors


static func _is_unit_value(value: float) -> bool:
	return is_finite(value) and value >= 0.0 and value <= 1.0
