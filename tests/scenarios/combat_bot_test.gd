extends TestCase
## The headless combat bot (docs/12 §9.3): a bot that plays only with a
## player client's intents (move, facing, melee attack, posture, pickup,
## item use, door) over the real network path fights every scene of
## `res://tests/bot/scenes` and leaves, per scene: cleared or not, the
## simulated time, the health lost, hits landed and taken.
##
## Behaviour under test:
##   - every scene file is valid data;
##   - a scene that is expected to be cleared is cleared within its
##     simulated-time limit;
##   - a scene run twice with the same seed gives the same result.
## Time and health are recorded, not asserted (they move with every tuning
## change; the baseline with its date is in docs/12 §9.4). Passing says the
## fights can still be won by a simple player, not that they are fun.
##
## Environment:
##   ZSS_BOT_SCENE=<id>[,<id>]  only these scenes
##   ZSS_BOT_TRACE=<ticks>      one line per swing and per hit taken, and
##                              the bot's status every <ticks> ticks (30)
##   ZSS_BOT_LOG=<path>         results log (default user://combat_bot/results.log)
##   ZSS_GIT_REV                written to the log (set by tools/run_tests.sh)

const ENV_SCENES: String = "ZSS_BOT_SCENE"
const ENV_TRACE: String = "ZSS_BOT_TRACE"
const ENV_LOG: String = "ZSS_BOT_LOG"
const ENV_REV: String = "ZSS_GIT_REV"
const DEFAULT_LOG_PATH: String = "user://combat_bot/results.log"
const SCENE_SEPARATOR: String = ","
const REPEAT_SAME: String = "same"
const REPEAT_DIFFERS: String = "DIFFERS"
const REPEAT_SKIPPED: String = "not checked"
const MSEC_PER_SEC: float = 1000.0
const TABLE_FORMAT: String = "[bot] %-26s %-8s %8s %8s %7s %7s %7s %6s  %s"


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


func test_the_scene_files_are_valid_data() -> void:
	var errors: PackedStringArray = []
	var scenes: Array[CombatBotScene] = CombatBotScene.load_directory(errors)
	assert_eq("; ".join(errors), "", "every file of %s is a valid scene" % CombatBotScene.SCENE_DIRECTORY)
	assert_true(scenes.size() >= 1, "there is at least one scene")
	var config: CompositionConfig = CompositionConfig.from_defaults()
	for scene: CombatBotScene in scenes:
		for definition_id: String in scene.item_definition_ids:
			assert_true(config.catalog.has(definition_id), "%s: item %s exists" % [scene.scene_id, definition_id])
		assert_true(scene.zombie_offsets.size() <= config.zombie.max_active_zombies, "%s: no more zombies than the server allows" % scene.scene_id)


func test_the_bot_fights_every_scene_and_a_repeat_gives_the_same_result() -> void:
	var errors: PackedStringArray = []
	var scenes: Array[CombatBotScene] = _chosen(CombatBotScene.load_directory(errors))
	assert_eq("; ".join(errors), "", "the scene files load")
	assert_true(not scenes.is_empty(), "at least one scene is run (%s=%s)" % [ENV_SCENES, OS.get_environment(ENV_SCENES)])
	var rows: Array[Dictionary] = []
	for scene: CombatBotScene in scenes:
		var result: Dictionary = await _run(scene)
		var repeat: String = REPEAT_SKIPPED
		assert_eq(str(result["error"]), "", "%s: the run was set up" % scene.scene_id)
		if scene.expect_cleared:
			assert_true(bool(result["cleared"]), "%s: the bot kills every zombie within %.0f simulated seconds (ended: %s, kills %d/%d, health lost %.1f)" % [scene.scene_id, scene.max_sim_sec, str(result["end"]), int(result["kills"]), int(result["zombies"]), float(result["health_lost"])])
		if scene.verify_repeat and str(result["error"]).is_empty():
			var again: Dictionary = await _run(scene)
			var same: bool = CombatBotRunner.same_outcome(result, again)
			repeat = REPEAT_SAME if same else REPEAT_DIFFERS
			assert_true(same, "%s: the same seed gives the same result (first %s, second %s)" % [scene.scene_id, _outcome_text(result), _outcome_text(again)])
			result["real_msec"] = int(result["real_msec"]) + int(again["real_msec"])
		result["repeat"] = repeat
		result["title"] = scene.title
		result["expect_cleared"] = scene.expect_cleared
		rows.append(result)
	_print_table(rows)
	_append_to_log(rows)


# ------------------------------------------------------------ helpers

func _run(scene: CombatBotScene) -> Dictionary:
	var runner: CombatBotRunner = CombatBotRunner.new(tree)
	var trace_ticks: int = OS.get_environment(ENV_TRACE).to_int()
	runner.trace = trace_ticks > 0
	if trace_ticks > 0:
		runner.trace_every_ticks = trace_ticks
	return await runner.run(scene)


## The scenes named in ZSS_BOT_SCENE, or all of them.
func _chosen(scenes: Array[CombatBotScene]) -> Array[CombatBotScene]:
	var wanted: PackedStringArray = OS.get_environment(ENV_SCENES).split(SCENE_SEPARATOR, false)
	if wanted.is_empty():
		return scenes
	var chosen: Array[CombatBotScene] = []
	for scene: CombatBotScene in scenes:
		if wanted.has(scene.scene_id):
			chosen.append(scene)
	return chosen


func _outcome_text(result: Dictionary) -> String:
	var parts: PackedStringArray = []
	for key: String in CombatBotRunner.REPEATABLE_KEYS:
		parts.append("%s=%s" % [key, str(result.get(key, ""))])
	return " ".join(parts)


func _print_table(rows: Array[Dictionary]) -> void:
	print(TABLE_FORMAT % ["scene", "end", "sim s", "hp lost", "landed", "taken", "swings", "kills", "repeat"])
	for row: Dictionary in rows:
		print(TABLE_FORMAT % [
			str(row["scene_id"]), str(row["end"]), "%.2f" % float(row["sim_sec"]), "%.1f" % float(row["health_lost"]),
			str(row["hits_landed"]), str(row["hits_taken"]), str(row["swings"]),
			"%d/%d" % [int(row["kills"]), int(row["zombies"])], str(row["repeat"]),
		])


## One line per scene, appended: the history of the bot's results.
func _append_to_log(rows: Array[Dictionary]) -> void:
	var path: String = OS.get_environment(ENV_LOG)
	if path.is_empty():
		path = DEFAULT_LOG_PATH
	var directory: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory) and DirAccess.make_dir_recursive_absolute(directory) != OK:
		fail("the results log directory could not be made: %s" % directory)
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		fail("the results log could not be opened: %s" % path)
		return
	file.seek_end()
	var revision: String = OS.get_environment(ENV_REV)
	var stamp: String = Time.get_datetime_string_from_system(true) + "Z"
	for row: Dictionary in rows:
		file.store_line("%s rev=%s scene=%s seed=%d end=%s cleared=%s expect_cleared=%s sim_sec=%.3f sim_ticks=%d health_lost=%.3f hits_landed=%d hits_taken=%d swings=%d kills=%d/%d weapon=%s repeat=%s real_sec=%.1f" % [
			stamp, revision if not revision.is_empty() else "unknown", str(row["scene_id"]), int(row["seed"]), str(row["end"]),
			str(row["cleared"]), str(row["expect_cleared"]), float(row["sim_sec"]), int(row["sim_ticks"]), float(row["health_lost"]),
			int(row["hits_landed"]), int(row["hits_taken"]), int(row["swings"]), int(row["kills"]), int(row["zombies"]),
			str(row["weapon"]), str(row["repeat"]).replace(" ", "_"), float(row["real_msec"]) / MSEC_PER_SEC,
		])
	file.close()
	print("[bot] results appended to %s" % ProjectSettings.globalize_path(path))
