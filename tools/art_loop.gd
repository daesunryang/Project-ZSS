extends SceneTree
## Development tool: keeps the files of the art loop (docs/19_art_loop.md).
## Run it through tools/art_loop.sh. Not used by the game.
##
## Commands (after "--"):
##   start  <job> <goal in the user's own words>
##   round  <job> [--user-said-continue=<the user's words>] <png> [<png>...]
##          next round folder, snapshot copies, metrics, scores.json entry
##   pack   <job> --out=<empty folder outside the project>
##          what a reviewer may see (rubric, reference pictures, snapshots)
##          and the exact reviewer prompt
##   record <job>
##          reads rNN/reviews/reviewer_*.json, averages, decides
##   report <job>
##          score table, metric trend, best round, stop reasons
##
## Exit codes: 0 done, 1 wrong use or file problem, 2 refused (the loop is
## stopped, scores are missing, or the user's slots are still empty).
## The loop never approves art; "stopped" always means "show the user".

const MetricsLib: GDScript = preload("res://tools/art_metrics_lib.gd")
const LoopLib: GDScript = preload("res://tools/art_loop_lib.gd")
const LOOP_ROOT: String = "res://art/loop"
const SETTINGS_FILE: String = "settings.json"
const RUBRIC_FILE: String = "rubric.md"
const PROMPT_FILE: String = "reviewer_prompt.md"
const REFERENCE_DIR: String = "reference"
const RUNS_DIR: String = "runs"
const JOB_FILE: String = "job.json"
const SCORES_FILE: String = "scores.json"
const METRICS_FILE: String = "metrics.json"
const SNAPSHOTS_DIR: String = "snapshots"
const REVIEWS_DIR: String = "reviews"
const REVIEW_PREFIX: String = "reviewer_"
const PACK_DIR: String = "pack"
const PACK_PROMPT_FILE: String = "prompt.md"
## Marks a part of rubric.md only the user may fill in.
const SLOT_MARKER: String = "[빈칸"
const IMAGE_EXTENSIONS: PackedStringArray = ["png", "jpg", "jpeg", "webp"]
const ARG_CONTINUE: String = "--user-said-continue="
const ARG_OUT: String = "--out="
const JOB_NAME_PATTERN: String = "^[a-z0-9][a-z0-9_-]*$"
const EXIT_OK: int = 0
const EXIT_ERROR: int = 1
const EXIT_REFUSED: int = 2

var _root: String = ""
var _settings: Dictionary = {}
var _loop: Dictionary = {}


func _initialize() -> void:
	quit(_main(OS.get_cmdline_user_args()))


func _main(args: PackedStringArray) -> int:
	if args.size() < 2:
		return _error("usage: art_loop.sh start|round|pack|record|report <job> ...")
	_root = ProjectSettings.globalize_path(LOOP_ROOT)
	var settings: Variant = _read_json(_root.path_join(SETTINGS_FILE))
	if not (settings is Dictionary):
		return _error("settings could not be read: " + _root.path_join(SETTINGS_FILE))
	_settings = settings
	_loop = LoopLib.merged_loop(_settings.get("loop", {}))
	var job: String = args[1]
	var pattern: RegEx = RegEx.create_from_string(JOB_NAME_PATTERN)
	if pattern.search(job) == null:
		return _error("job name must use a-z, 0-9, - and _ only: " + job)
	var rest: PackedStringArray = args.slice(2)
	match args[0]:
		"start":
			return _start(job, rest)
		"round":
			return _round(job, rest)
		"pack":
			return _pack(job, rest)
		"record":
			return _record(job)
		"report":
			return _report(job)
	return _error("unknown command: " + args[0])


func _start(job: String, rest: PackedStringArray) -> int:
	var goal: String = " ".join(rest).strip_edges()
	if goal.is_empty():
		return _error("start needs the goal in the user's own words")
	var job_dir: String = _job_dir(job)
	if FileAccess.file_exists(job_dir.path_join(JOB_FILE)):
		return _error("job already exists: " + job_dir)
	DirAccess.make_dir_recursive_absolute(job_dir)
	var job_data: Dictionary = {
		"job": job,
		"goal_user_words": goal,
		"created_at": _now(),
		"user_continues": [],
	}
	if not _write_json(job_dir.path_join(JOB_FILE), job_data):
		return EXIT_ERROR
	if not _write_json(job_dir.path_join(SCORES_FILE), {"job": job, "rounds": [], "decision": {}}):
		return EXIT_ERROR
	print("[art-loop] job started: %s" % job_dir)
	_print_missing_slots()
	return EXIT_OK


func _round(job: String, rest: PackedStringArray) -> int:
	var user_words: String = ""
	var sources: PackedStringArray = []
	for arg: String in rest:
		if arg.begins_with(ARG_CONTINUE):
			user_words = arg.substr(ARG_CONTINUE.length()).strip_edges()
		else:
			sources.append(arg)
	if sources.is_empty():
		return _error("round needs at least one snapshot image")
	var job_dir: String = _job_dir(job)
	var job_data: Variant = _read_json(job_dir.path_join(JOB_FILE))
	var scores_data: Variant = _read_json(job_dir.path_join(SCORES_FILE))
	if not (job_data is Dictionary) or not (scores_data is Dictionary):
		return _error("job not found (run start first): " + job_dir)
	var job_info: Dictionary = job_data
	var scores: Dictionary = scores_data
	var rounds: Array = scores["rounds"]
	var before: Dictionary = LoopLib.decide(rounds, _loop, _settings.get("regression", {}))
	if str(before["status"]) == LoopLib.STATUS_SCORE_PENDING:
		print("[art-loop] REFUSED: round r%02d has no reviewer scores yet (run record first)" % rounds.size())
		return EXIT_REFUSED
	if str(before["status"]) == LoopLib.STATUS_STOPPED:
		if user_words.is_empty():
			print("[art-loop] REFUSED: the loop is stopped (%s)." % ", ".join(before["reasons"]))
			print("[art-loop] Show the user the report. Go on only when the user says so,")
			print("[art-loop] then pass their words: %s\"...\"" % ARG_CONTINUE)
			return EXIT_REFUSED
		var continues: Array = job_info.get("user_continues", [])
		continues.append({"after_round": rounds.size(), "user_words": user_words, "at": _now()})
		job_info["user_continues"] = continues
		if not _write_json(job_dir.path_join(JOB_FILE), job_info):
			return EXIT_ERROR

	var number: int = rounds.size() + 1
	var round_name: String = "r%02d" % number
	var round_dir: String = job_dir.path_join(round_name)
	var snapshot_dir: String = round_dir.path_join(SNAPSHOTS_DIR)
	if DirAccess.dir_exists_absolute(round_dir):
		return _error("round folder already exists: " + round_dir)
	var names: PackedStringArray = []
	for source: String in sources:
		if not FileAccess.file_exists(source):
			return _error("snapshot not found: " + source)
		if names.has(source.get_file()):
			return _error("two snapshots share the name: " + source.get_file())
		names.append(source.get_file())
	DirAccess.make_dir_recursive_absolute(snapshot_dir)
	DirAccess.make_dir_recursive_absolute(round_dir.path_join(REVIEWS_DIR))
	var metrics_settings: Dictionary = MetricsLib.merged_settings(_settings.get("metrics", {}))
	var measured: Array = []
	for source: String in sources:
		var target: String = snapshot_dir.path_join(source.get_file())
		if DirAccess.copy_absolute(source, target) != OK:
			return _error("could not copy snapshot: " + source)
		var metrics: Dictionary = MetricsLib.measure_file(target, metrics_settings)
		if metrics.is_empty():
			return _error("snapshot is not a readable image: " + source)
		measured.append(metrics)
	var totals: Dictionary = LoopLib.metric_totals(measured)
	var metrics_report: Dictionary = {"settings": metrics_settings, "snapshots": measured, "totals": totals}
	if not _write_json(round_dir.path_join(METRICS_FILE), metrics_report):
		return EXIT_ERROR
	rounds.append({
		"round": number,
		"at": _now(),
		"snapshots": names,
		"signature": LoopLib.snapshot_signature(measured),
		"metrics": totals,
		"reviews": [],
		"scores": null,
	})
	var decision: Dictionary = LoopLib.decide(rounds, _loop, _settings.get("regression", {}))
	scores["decision"] = decision
	if not _write_json(job_dir.path_join(SCORES_FILE), scores):
		return EXIT_ERROR
	print("[art-loop] %s: %d snapshot(s) -> %s" % [round_name, names.size(), snapshot_dir])
	print("[art-loop] metrics: " + JSON.stringify(totals))
	_print_decision(decision)
	return EXIT_OK


func _pack(job: String, rest: PackedStringArray) -> int:
	var out_dir: String = ""
	for arg: String in rest:
		if arg.begins_with(ARG_OUT):
			out_dir = arg.substr(ARG_OUT.length())
	if out_dir.is_empty():
		return _error("pack needs --out=<empty folder outside the project>")
	var project_dir: String = ProjectSettings.globalize_path("res://").simplify_path()
	if out_dir.simplify_path().to_lower().begins_with(project_dir.to_lower()):
		return _error("the pack must be outside the project so a reviewer cannot read the history")
	var job_dir: String = _job_dir(job)
	var scores_data: Variant = _read_json(job_dir.path_join(SCORES_FILE))
	if not (scores_data is Dictionary):
		return _error("job not found: " + job_dir)
	var scores: Dictionary = scores_data
	var rounds: Array = scores["rounds"]
	if rounds.is_empty():
		return _error("no round yet (run round first)")
	var latest: Dictionary = rounds[rounds.size() - 1]
	var round_dir: String = job_dir.path_join("r%02d" % int(latest["round"]))
	var pack_dir: String = out_dir.path_join(PACK_DIR)
	var pack_reference: String = pack_dir.path_join(REFERENCE_DIR)
	if DirAccess.dir_exists_absolute(pack_dir):
		return _error("pack folder already exists: " + pack_dir)
	DirAccess.make_dir_recursive_absolute(pack_reference)
	if DirAccess.copy_absolute(_root.path_join(RUBRIC_FILE), pack_dir.path_join(RUBRIC_FILE)) != OK:
		return _error("could not copy the rubric")
	var reference_lines: PackedStringArray = []
	for file_name: String in _reference_images():
		DirAccess.copy_absolute(
			_root.path_join(REFERENCE_DIR).path_join(file_name), pack_reference.path_join(file_name)
		)
		reference_lines.append("- %s/%s" % [REFERENCE_DIR, file_name])
	# Snapshots get neutral names: a reviewer must not learn the job or the round.
	var snapshot_lines: PackedStringArray = []
	var index: int = 0
	var snapshot_names: Array = latest["snapshots"]
	for snapshot: Variant in snapshot_names:
		index += 1
		var source: String = round_dir.path_join(SNAPSHOTS_DIR).path_join(str(snapshot))
		var neutral: String = "snapshot_%02d.%s" % [index, str(snapshot).get_extension().to_lower()]
		if DirAccess.copy_absolute(source, pack_dir.path_join(neutral)) != OK:
			return _error("could not copy snapshot: " + source)
		snapshot_lines.append("- " + neutral)
	var template: String = FileAccess.get_file_as_string(_root.path_join(PROMPT_FILE))
	if template.is_empty():
		return _error("reviewer prompt template is missing: " + PROMPT_FILE)
	var prompt: String = template.replace("{{PACK_DIR}}", pack_dir)
	prompt = prompt.replace("{{SNAPSHOT_LIST}}", "\n".join(snapshot_lines))
	prompt = prompt.replace(
		"{{REFERENCE_LIST}}", "(없음)" if reference_lines.is_empty() else "\n".join(reference_lines)
	)
	var prompt_path: String = out_dir.path_join(PACK_PROMPT_FILE)
	var file: FileAccess = FileAccess.open(prompt_path, FileAccess.WRITE)
	if file == null:
		return _error("could not write: " + prompt_path)
	file.store_string(prompt)
	file.close()
	print("[art-loop] review pack: " + pack_dir)
	print("[art-loop] reviewer prompt: " + prompt_path)
	print("[art-loop] save each answer as %s" % round_dir.path_join(REVIEWS_DIR).path_join(REVIEW_PREFIX + "<n>.json"))
	print("----- reviewer prompt (give exactly this, to %d new reviewers) -----" % int(_loop["reviewers"]))
	print(prompt)
	print("----- end of reviewer prompt -----")
	if _print_missing_slots():
		return EXIT_REFUSED
	return EXIT_OK


func _record(job: String) -> int:
	if _print_missing_slots():
		return EXIT_REFUSED
	var job_dir: String = _job_dir(job)
	var scores_data: Variant = _read_json(job_dir.path_join(SCORES_FILE))
	if not (scores_data is Dictionary):
		return _error("job not found: " + job_dir)
	var scores: Dictionary = scores_data
	var rounds: Array = scores["rounds"]
	if rounds.is_empty():
		return _error("no round yet (run round first)")
	var latest: Dictionary = rounds[rounds.size() - 1]
	if latest.get("scores") is Dictionary:
		return _error("round r%02d is already scored" % int(latest["round"]))
	var reviews_dir: String = job_dir.path_join("r%02d" % int(latest["round"])).path_join(REVIEWS_DIR)
	var files: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(reviews_dir)
	if dir != null:
		for file_name: String in dir.get_files():
			if file_name.begins_with(REVIEW_PREFIX) and file_name.get_extension() == "json":
				files.append(file_name)
	files.sort()
	var wanted: int = int(_loop["reviewers"])
	if files.size() != wanted:
		return _error("expected %d reviewer answers in %s, found %d" % [wanted, reviews_dir, files.size()])
	var reviews: Array = []
	for file_name: String in files:
		var review: Variant = _read_json(reviews_dir.path_join(file_name))
		var problems: PackedStringArray = LoopLib.validate_review(review, _loop)
		if not problems.is_empty():
			return _error("%s: %s" % [file_name, "; ".join(problems)])
		reviews.append(review)
	latest["reviews"] = files
	latest["scores"] = LoopLib.average_reviews(reviews, _loop)
	var decision: Dictionary = LoopLib.decide(rounds, _loop, _settings.get("regression", {}))
	scores["decision"] = decision
	if not _write_json(job_dir.path_join(SCORES_FILE), scores):
		return EXIT_ERROR
	print("[art-loop] r%02d scores: %s" % [int(latest["round"]), JSON.stringify(latest["scores"])])
	_print_decision(decision)
	return EXIT_OK


func _report(job: String) -> int:
	var job_dir: String = _job_dir(job)
	var job_data: Variant = _read_json(job_dir.path_join(JOB_FILE))
	var scores_data: Variant = _read_json(job_dir.path_join(SCORES_FILE))
	if not (job_data is Dictionary) or not (scores_data is Dictionary):
		return _error("job not found: " + job_dir)
	var job_info: Dictionary = job_data
	var scores: Dictionary = scores_data
	var rounds: Array = scores["rounds"]
	var decision: Dictionary = LoopLib.decide(rounds, _loop, _settings.get("regression", {}))
	print("[art-loop] 작업: %s" % job)
	print("[art-loop] 목표(사용자 말 그대로): %s" % str(job_info.get("goal_user_words", "")))
	print("[art-loop] 점수표와 수치 추이 (점수 %d~%d, 수치는 적을수록 깨끗함. 색 수는 참고용):" % [
		int(_loop["score_min"]), int(_loop["score_max"]),
	])
	for line: String in LoopLib.report_lines(rounds, _loop):
		print("  " + line)
	var show_round: int = int(decision["best_round"])
	var show_label: String = "가장 점수가 높은 회차"
	if show_round == 0 and not rounds.is_empty():
		show_round = rounds.size()
		show_label = "채점된 회차가 아직 없어 마지막 회차"
	if show_round > 0:
		var entry: Dictionary = rounds[show_round - 1]
		print("[art-loop] %s: r%02d — 스냅샷:" % [show_label, show_round])
		var snapshot_names: Array = entry["snapshots"]
		for snapshot: Variant in snapshot_names:
			print("  " + job_dir.path_join("r%02d" % show_round).path_join(SNAPSHOTS_DIR).path_join(str(snapshot)))
	_print_decision(decision)
	_print_missing_slots()
	print("[art-loop] 이 루프는 그림을 승인하지 않습니다. 위 그림과 표를 사용자에게 보여 주고 물어보세요.")
	return EXIT_OK


func _print_decision(decision: Dictionary) -> void:
	print("[art-loop] status: %s" % str(decision["status"]))
	var details: PackedStringArray = decision["details"]
	for line: String in details:
		print("[art-loop]   " + line)
	match str(decision["status"]):
		LoopLib.STATUS_STOPPED:
			var reasons: PackedStringArray = decision["reasons"]
			print("[art-loop] STOP (%s): show the user the report and ask. Nothing is approved." % ", ".join(reasons))
		LoopLib.STATUS_SCORE_PENDING:
			print("[art-loop] next: pack, two new reviewers, then record")
		_:
			print("[art-loop] next: another round may start")


## Prints what the user still has to provide. Returns true when something is missing.
func _print_missing_slots() -> bool:
	var missing: PackedStringArray = []
	if _reference_images().is_empty():
		missing.append("기준 그림이 없습니다: art/loop/reference/ 에 사용자가 고른 그림을 넣어야 합니다.")
	var rubric: String = FileAccess.get_file_as_string(_root.path_join(RUBRIC_FILE))
	var slots: int = rubric.count(SLOT_MARKER)
	if rubric.is_empty():
		missing.append("기준표가 없습니다: art/loop/rubric.md")
	elif slots > 0:
		missing.append("기준표에 사용자가 채울 빈칸이 %d곳 남아 있습니다: art/loop/rubric.md" % slots)
	if missing.is_empty():
		return false
	print("[art-loop] NOT READY FOR REVIEWERS — 검토자 채점을 시작할 수 없습니다:")
	for line: String in missing:
		print("[art-loop]   " + line)
	print("[art-loop]   빈칸은 사용자만 채웁니다. 대신 지어내지 말고 사용자에게 물어보세요.")
	return true


func _reference_images() -> PackedStringArray:
	var images: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(_root.path_join(REFERENCE_DIR))
	if dir == null:
		return images
	for file_name: String in dir.get_files():
		if IMAGE_EXTENSIONS.has(file_name.get_extension().to_lower()):
			images.append(file_name)
	images.sort()
	return images


func _job_dir(job: String) -> String:
	return _root.path_join(RUNS_DIR).path_join(job)


func _now() -> String:
	return Time.get_datetime_string_from_system(false, true)


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return _whole_numbers(JSON.parse_string(FileAccess.get_file_as_string(path)))


## JSON reads every number as a float; whole ones go back to int so the files
## this tool rewrites keep "round": 1 instead of 1.0.
func _whole_numbers(value: Variant) -> Variant:
	if value is float:
		var number: float = value
		if number == floorf(number) and absf(number) < 1.0e15:
			return int(number)
	elif value is Array:
		var list: Array = value
		for i: int in range(list.size()):
			list[i] = _whole_numbers(list[i])
	elif value is Dictionary:
		var dictionary: Dictionary = value
		for key: Variant in dictionary.keys():
			dictionary[key] = _whole_numbers(dictionary[key])
	return value


func _write_json(path: String, data: Dictionary) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("[art-loop] could not write: " + path)
		return false
	file.store_string(JSON.stringify(data, "\t") + "\n")
	file.close()
	return true


func _error(message: String) -> int:
	printerr("[art-loop] " + message)
	return EXIT_ERROR
