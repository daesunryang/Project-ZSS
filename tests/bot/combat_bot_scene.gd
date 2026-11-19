class_name CombatBotScene
extends Resource
## One fight for the headless combat bot (docs/12 §9.3): where the player
## starts, which zombies stand where, what lies on the ground and what the
## run must achieve. A scene is data only: every `*.tres` in
## `res://tests/bot/scenes` is run by `tests/scenarios/combat_bot_test.gd`,
## so a new fight (a boss, later) is a new file, not new code.
##
## Everything a scene prepares is placed BEFORE the fight starts (zombies,
## items, the test map). During the fight the bot only sends what a player
## client sends (CombatBotRunner).

const SCENE_DIRECTORY: String = "res://tests/bot/scenes"
const SCENE_EXTENSION: String = ".tres"
const SCENE_ID_PATTERN: String = "^[a-z][a-z0-9_]*$"
const DEFAULT_QUANTITY: int = 1

## Stable name: the key of the results log and of the baseline table.
@export var scene_id: String = ""
## What the scene is, for the printed table (Korean, like the docs).
@export var title: String = ""
## Seed of every server RNG of the run (zombies, combat rolls, infection).
@export var rng_seed: int = 1

@export_group("Start")
## Where the player appears (GameplaySettings.player_spawn_position).
@export var player_spawn: Vector3 = Vector3.ZERO
## The player lies prone when the fight starts (it asked for it with the
## posture intent during the preparation, like a player who was sneaking).
@export var start_prone: bool = false
## The world gets the shipped test map (walls, doors, containers).
@export var use_test_map: bool = false

@export_group("Zombies")
## One zombie per entry, relative to `player_spawn`.
@export var zombie_offsets: PackedVector3Array = []
## Facing of each zombie in degrees (yaw 0 faces -Z). Empty = every zombie
## faces the player's start; otherwise one entry per zombie.
@export var zombie_yaws_deg: PackedFloat32Array = []

@export_group("Items on the ground")
@export var item_definition_ids: PackedStringArray = []
## Relative to `player_spawn`, one entry per item.
@export var item_offsets: PackedVector3Array = []
## Empty = one of each; otherwise one entry per item.
@export var item_quantities: PackedInt32Array = []

@export_group("Outcome")
## The fight is given up after this much SIMULATED time (server ticks,
## docs/12 §1.1), never after real time.
@export_range(1.0, 3600.0) var max_sim_sec: float = 60.0
## True = the run fails when the bot does not kill every zombie in time.
## False = the result is only recorded (a fight nobody expects to win yet).
@export var expect_cleared: bool = true
## True = the scene is run twice and both runs must give the same result.
@export var verify_repeat: bool = true


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if RegEx.create_from_string(SCENE_ID_PATTERN).search(scene_id) == null:
		errors.append("scene_id must be snake_case, got '%s'" % scene_id)
	if zombie_offsets.is_empty():
		errors.append("%s: a scene needs at least one zombie" % scene_id)
	if not zombie_yaws_deg.is_empty() and zombie_yaws_deg.size() != zombie_offsets.size():
		errors.append("%s: zombie_yaws_deg must be empty or have one entry per zombie" % scene_id)
	if item_definition_ids.size() != item_offsets.size():
		errors.append("%s: item_definition_ids and item_offsets must have the same length" % scene_id)
	if not item_quantities.is_empty() and item_quantities.size() != item_definition_ids.size():
		errors.append("%s: item_quantities must be empty or have one entry per item" % scene_id)
	if not player_spawn.is_finite() or max_sim_sec <= 0.0:
		errors.append("%s: player_spawn must be finite and max_sim_sec > 0" % scene_id)
	return errors


## World position of zombie `index`.
func zombie_position(index: int) -> Vector3:
	return player_spawn + zombie_offsets[index]


## Yaw (radians) of zombie `index`: the configured one, or towards the
## player's start.
func zombie_yaw(index: int) -> float:
	if not zombie_yaws_deg.is_empty():
		return deg_to_rad(zombie_yaws_deg[index])
	return ZombiePerception.yaw_towards(-zombie_offsets[index], 0.0)


func item_quantity(index: int) -> int:
	return DEFAULT_QUANTITY if item_quantities.is_empty() else item_quantities[index]


## The development seed that puts this scene's items on the ground.
func to_world_seed() -> DevWorldSeed:
	var world_seed: DevWorldSeed = DevWorldSeed.new()
	world_seed.item_definition_ids = item_definition_ids.duplicate()
	var positions: PackedVector3Array = []
	var quantities: PackedInt32Array = []
	for index: int in range(item_definition_ids.size()):
		positions.append(player_spawn + item_offsets[index])
		quantities.append(item_quantity(index))
	world_seed.item_positions = positions
	world_seed.item_quantities = quantities
	return world_seed


## Every scene file of `directory`, sorted by file name. A file that is not
## a CombatBotScene is reported in `errors` (and skipped).
static func load_directory(errors: PackedStringArray, directory: String = SCENE_DIRECTORY) -> Array[CombatBotScene]:
	var scenes: Array[CombatBotScene] = []
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		errors.append("scene directory not found: %s" % directory)
		return scenes
	var names: PackedStringArray = []
	for file_name: String in dir.get_files():
		# An exported project lists "x.tres.remap"; the tests run from source.
		if file_name.ends_with(SCENE_EXTENSION):
			names.append(file_name)
	names.sort()
	var seen: Dictionary[String, String] = {}
	for file_name: String in names:
		var path: String = directory.path_join(file_name)
		var scene: CombatBotScene = ResourceLoader.load(path) as CombatBotScene
		if scene == null:
			errors.append("not a CombatBotScene: %s" % path)
			continue
		errors.append_array(scene.validate())
		if seen.has(scene.scene_id):
			errors.append("scene_id '%s' is used by %s and %s" % [scene.scene_id, seen[scene.scene_id], file_name])
			continue
		seen[scene.scene_id] = file_name
		scenes.append(scene)
	return scenes
