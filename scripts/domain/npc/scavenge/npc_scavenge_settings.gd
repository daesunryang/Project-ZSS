class_name NpcScavengeSettings
extends Resource
## How an NPC that lives alone keeps itself alive (F-29, docs/09 §17.14):
## searching buildings for supplies, remembering danger, treating itself and
## fighting when it is cornered. Defaults in
## `res://data/tuning/npc_scavenge_settings.tres`. Every value is
## PROVISIONAL (docs/15 §25) until play-tested. Durations ending in `_sec`
## are action time (real seconds); `_world_sec` is calendar time.

const DEFAULT_PATH: String = "res://data/tuning/npc_scavenge_settings.tres"

@export_group("Where it searches")
## Buildings whose middle is at most this far from the NPC's home are
## searched. Keep it below NavigationSettings.max_search_radius_m: a
## building the path search cannot reach is of no use.
@export_range(1.0, 500.0, 0.5, "suffix:m") var radius_m: float = 55.0
## Buildings an NPC remembers having searched (the oldest is forgotten).
@export_range(1, 512) var max_visited: int = 48
## Calendar days after which a building it could not reach is tried again.
@export_range(1, 1000) var blocked_forget_days: int = 1
## Calendar seconds of one day (the day number of a visit).
@export_range(1.0, 10000000.0) var day_length_world_sec: float = 86400.0

@export_group("What a trip takes")
## How long searching one container takes.
@export_range(0.0, 600.0, 0.1, "suffix:s") var search_duration_sec: float = 4.0
## How long putting the loot away at home takes.
@export_range(0.0, 600.0, 0.1, "suffix:s") var stow_duration_sec: float = 3.0
## How long treating its own wound takes.
@export_range(0.0, 600.0, 0.1, "suffix:s") var treat_duration_sec: float = 4.0

@export_group("How much it wants")
## Units of food (carried + in its home) an NPC of average
## conscientiousness wants to have. The need term of the action "scavenge"
## is how far below that it is (0..1). A careful NPC wants up to half as
## much again, a careless one half as much.
@export_range(1, 1000) var food_target_units: int = 8
## Units of drinks it wants to have (its home's water never runs dry,
## docs/15 F28-006: drinks are for the way).
@export_range(0, 1000) var drink_target_units: int = 2
## Units of bandages / cures it wants to have.
@export_range(0, 1000) var medical_target_units: int = 1
## How much a missing treatment and a missing weapon count beside missing
## food (0..1). A bleeding NPC without a bandage counts as 1 whatever this is.
@export_range(0.0, 1.0, 0.01) var medical_shortage_weight: float = 0.5
@export_range(0.0, 1.0, 0.01) var weapon_shortage_weight: float = 0.3
## An NPC that is farther than this from its home drinks what it carries
## instead of walking to its water.
@export_range(0.0, 1000.0, 0.5, "suffix:m") var drink_carried_beyond_m: float = 15.0

@export_group("Remembering danger")
## Half-life of a danger memory (a zombie seen, a zombie's hit): how long
## an NPC avoids the place.
@export_range(1.0, 100000000.0) var danger_half_life_world_sec: float = 43200.0
## No second memory of a zombie seen within this distance of one that is
## younger than danger_note_interval_world_sec.
@export_range(0.0, 1000.0, 0.5, "suffix:m") var danger_merge_radius_m: float = 10.0
@export_range(0.0, 100000000.0) var danger_note_interval_world_sec: float = 1200.0
## Importance and emotional intensity (0..1) of the two memories.
@export_range(0.0, 1.0, 0.01) var seen_importance: float = 0.5
@export_range(0.0, 1.0, 0.01) var seen_intensity: float = 0.4
@export_range(0.0, 1.0, 0.01) var hurt_importance: float = 0.8
@export_range(0.0, 1.0, 0.01) var hurt_intensity: float = 0.8
## Fear added when a zombie hurts it (0..1).
@export_range(0.0, 1.0, 0.01) var hurt_fear: float = 0.3
## A danger memory counts for places within this distance of it, less the
## farther away (linear).
@export_range(0.5, 1000.0, 0.5, "suffix:m") var danger_radius_m: float = 25.0
## A building whose danger (the sum over the memories: strength x nearness
## x importance) is at least this is not searched. An NPC with risk
## tolerance 1 accepts twice as much, one with 0 half as much.
@export_range(0.0, 100.0, 0.01) var danger_avoid_threshold: float = 0.25
## Metres one unit of danger adds to a building's distance when the nearest
## is chosen.
@export_range(0.0, 10000.0, 0.5, "suffix:m") var danger_cost_m: float = 60.0

@export_group("Fleeing and fighting")
## A fleeing NPC runs home instead of straight away when its home is at
## least this far from the threat and not behind it.
@export_range(0.0, 1000.0, 0.5, "suffix:m") var flee_home_min_threat_distance_m: float = 8.0
## A zombie this near is "adjacent": the NPC can hit it and be hit.
@export_range(0.1, 100.0, 0.05, "suffix:m") var fight_range_m: float = 1.6
## An NPC that has fled for this long and still has a zombie adjacent stops
## fleeing and fights (fleeing fails).
@export_range(0.0, 600.0, 0.1, "suffix:s") var fight_after_fleeing_sec: float = 1.5
## Time before its first swing.
@export_range(0.0, 60.0, 0.05, "suffix:s") var fight_windup_sec: float = 0.4


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	for entry: Array in [
		["search_duration_sec", search_duration_sec], ["stow_duration_sec", stow_duration_sec], ["treat_duration_sec", treat_duration_sec],
		["drink_carried_beyond_m", drink_carried_beyond_m], ["danger_merge_radius_m", danger_merge_radius_m],
		["danger_note_interval_world_sec", danger_note_interval_world_sec], ["danger_avoid_threshold", danger_avoid_threshold],
		["danger_cost_m", danger_cost_m], ["flee_home_min_threat_distance_m", flee_home_min_threat_distance_m],
		["fight_after_fleeing_sec", fight_after_fleeing_sec], ["fight_windup_sec", fight_windup_sec],
	]:
		if not is_finite(float(entry[1])) or float(entry[1]) < 0.0:
			errors.append("npc scavenge %s must be >= 0" % str(entry[0]))
	for entry: Array in [["radius_m", radius_m], ["day_length_world_sec", day_length_world_sec], ["danger_half_life_world_sec", danger_half_life_world_sec], ["danger_radius_m", danger_radius_m], ["fight_range_m", fight_range_m]]:
		if not is_finite(float(entry[1])) or float(entry[1]) <= 0.0:
			errors.append("npc scavenge %s must be > 0" % str(entry[0]))
	for entry: Array in [
		["medical_shortage_weight", medical_shortage_weight], ["weapon_shortage_weight", weapon_shortage_weight],
		["seen_importance", seen_importance], ["seen_intensity", seen_intensity], ["hurt_importance", hurt_importance],
		["hurt_intensity", hurt_intensity], ["hurt_fear", hurt_fear],
	]:
		if not is_finite(float(entry[1])) or float(entry[1]) < 0.0 or float(entry[1]) > 1.0:
			errors.append("npc scavenge %s must be within 0..1" % str(entry[0]))
	if max_visited < 1 or blocked_forget_days < 1 or food_target_units < 1 or medical_target_units < 0 or drink_target_units < 0:
		errors.append("npc scavenge counts must be positive")
	return errors


## Errors against the path search: a building beyond its radius is never
## reached.
func validate_against(navigation: NavigationSettings) -> PackedStringArray:
	var errors: PackedStringArray = []
	if navigation != null and radius_m > navigation.max_search_radius_m:
		errors.append("npc scavenge radius_m (%s) must be at most the path search radius (%s)" % [radius_m, navigation.max_search_radius_m])
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NpcScavengeSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcScavengeSettings:
		return loaded as NpcScavengeSettings
	GameLogger.warning("config", "npc scavenge settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcScavengeSettings.new()
