class_name NpcRelocationSettings
extends Resource
## When and where an NPC that lives alone moves to another shelter (F-30,
## docs/09 §17.15). Defaults in
## `res://data/tuning/npc_relocation_settings.tres`. Every value is
## PROVISIONAL (docs/15 §26) until play-tested. Durations ending in `_sec`
## are action time (real seconds); `_world_sec` is calendar time.

const DEFAULT_PATH: String = "res://data/tuning/npc_relocation_settings.tres"
## A leg must stay inside the path search: at most this share of its radius.
const LEG_SHARE_OF_SEARCH_RADIUS: float = 0.8

@export_group("When it moves")
## Nothing left: the NPC has searched its own home, its last
## `exhausted_tries` scavenging trips in a row found no building to search
## (every building around it is emptied, blocked, too dangerous or somebody
## else's), and it has at most this many units of food (carried + at home).
## A cautious NPC (risk tolerance 0) leaves with half as much again, a
## daring one (1) waits until it has half as much.
@export_range(0, 1000) var move_when_food_at_most: int = 3
@export_range(1, 100) var exhausted_tries: int = 2
## Repeated danger: the danger the NPC remembers at the middle of its home
## (NpcSurvivalSense.danger_at: one fresh zombie sighting there is 0.5, a
## zombie's hit 0.8) is at least this. Doubled for an NPC that is daring,
## brave and calm, halved for one that is cautious, timid and nervous
## (risk_tolerance + courage - neuroticism).
@export_range(0.0, 100.0, 0.01) var home_danger_threshold: float = 1.2
## Badly hurt at home: its health is at most this share of its maximum and
## it remembers a zombie's hit within hurt_at_home_radius_m of the middle of
## its home that is still at least hurt_memory_min_strength strong. A brave
## NPC (courage 1) leaves only at half this health, a timid one (0) at half
## as much again.
@export_range(0.0, 1.0, 0.01) var hurt_health_fraction: float = 0.5
@export_range(0.5, 1000.0, 0.5, "suffix:m") var hurt_at_home_radius_m: float = 15.0
@export_range(0.0, 1.0, 0.01) var hurt_memory_min_strength: float = 0.5
## Calendar days an NPC stays in a home it moved into before "nothing
## left" or "repeated danger" can make it move again (being badly hurt or
## attacked can at once).
@export_range(0, 1000) var min_days_between_moves: int = 1
## Calendar time after which an NPC that found no building to move to
## looks again.
@export_range(0.0, 100000000.0) var retry_choice_after_world_sec: float = 21600.0
## Calendar days after which a move that still has not arrived gives its
## destination up and chooses again from where the NPC stands.
@export_range(1, 1000) var give_up_days: int = 2

@export_group("Where to")
## Buildings whose middle is between these distances from the middle of
## its home are looked at.
@export_range(0.0, 2000.0, 1.0, "suffix:m") var min_distance_m: float = 30.0
@export_range(1.0, 2000.0, 1.0, "suffix:m") var max_distance_m: float = 300.0
## Fleeing danger (repeated danger, badly hurt, attacked) it goes at least
## this far.
@export_range(0.0, 2000.0, 1.0, "suffix:m") var danger_min_distance_m: float = 80.0
## Every building with a container around a candidate (in its cell and the
## eight cells around it) that the NPC has not emptied and nobody lives in
## makes the candidate count as this much nearer, up to `prospect_cap` of
## them: it prefers a place with things to search.
@export_range(0.0, 1000.0, 0.5, "suffix:m") var prospect_bonus_m: float = 12.0
@export_range(0, 1000) var prospect_cap: int = 8
## A building that is not a house (NpcHomeSettings.home_building_types)
## counts as this much farther.
@export_range(0.0, 1000.0, 0.5, "suffix:m") var other_type_cost_m: float = 40.0
## Cells whose buildings are listed per tick for the NPCs that choose
## where to move (for all of them together; a cell that is listed already
## costs nothing).
@export_range(1, 64) var scan_cells_per_tick: int = 1

@export_group("The move")
## How long taking things out of one container of its home takes.
@export_range(0.0, 600.0, 0.1, "suffix:s") var pack_duration_sec: float = 4.0
## How long it stays on the home tile of the new home before it lives there.
@export_range(0.0, 600.0, 0.1, "suffix:s") var settle_duration_sec: float = 5.0
## The way is walked in legs of at most this length (one path search each).
@export_range(1.0, 1000.0, 0.5, "suffix:m") var leg_length_m: float = 40.0
## After a leg that found no way it waits this long and tries a leg to the
## side; after `max_leg_failures` legs in a row it gives the destination up.
@export_range(0.0, 600.0, 0.1, "suffix:s") var leg_retry_pause_sec: float = 1.0
@export_range(1, 100) var max_leg_failures: int = 5


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	for entry: Array in [
		["home_danger_threshold", home_danger_threshold], ["retry_choice_after_world_sec", retry_choice_after_world_sec],
		["min_distance_m", min_distance_m], ["danger_min_distance_m", danger_min_distance_m], ["prospect_bonus_m", prospect_bonus_m],
		["other_type_cost_m", other_type_cost_m], ["pack_duration_sec", pack_duration_sec], ["settle_duration_sec", settle_duration_sec],
		["leg_retry_pause_sec", leg_retry_pause_sec],
	]:
		if not is_finite(float(entry[1])) or float(entry[1]) < 0.0:
			errors.append("npc relocation %s must be >= 0" % str(entry[0]))
	for entry: Array in [["max_distance_m", max_distance_m], ["hurt_at_home_radius_m", hurt_at_home_radius_m], ["leg_length_m", leg_length_m]]:
		if not is_finite(float(entry[1])) or float(entry[1]) <= 0.0:
			errors.append("npc relocation %s must be > 0" % str(entry[0]))
	for entry: Array in [["hurt_health_fraction", hurt_health_fraction], ["hurt_memory_min_strength", hurt_memory_min_strength]]:
		if not is_finite(float(entry[1])) or float(entry[1]) < 0.0 or float(entry[1]) > 1.0:
			errors.append("npc relocation %s must be within 0..1" % str(entry[0]))
	if move_when_food_at_most < 0 or exhausted_tries < 1 or min_days_between_moves < 0 or give_up_days < 1 or prospect_cap < 0 or scan_cells_per_tick < 1 or max_leg_failures < 1:
		errors.append("npc relocation counts must be positive")
	if errors.is_empty() and (min_distance_m >= max_distance_m or danger_min_distance_m >= max_distance_m):
		errors.append("npc relocation min_distance_m and danger_min_distance_m must be below max_distance_m")
	return errors


## Errors against the path search: a leg it cannot search is never walked.
func validate_against(navigation: NavigationSettings) -> PackedStringArray:
	var errors: PackedStringArray = []
	if navigation != null and leg_length_m > navigation.max_search_radius_m * LEG_SHARE_OF_SEARCH_RADIUS:
		errors.append("npc relocation leg_length_m (%s) must be at most %s of the path search radius (%s)" % [leg_length_m, LEG_SHARE_OF_SEARCH_RADIUS, navigation.max_search_radius_m])
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NpcRelocationSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcRelocationSettings:
		return loaded as NpcRelocationSettings
	GameLogger.warning("config", "npc relocation settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcRelocationSettings.new()
