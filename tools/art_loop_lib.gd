extends RefCounted
## Rules of the art loop that need no files: checking reviewer answers,
## averaging them, comparing metrics between rounds and deciding when the
## loop must stop and show the user. Settings come from the "loop" and
## "regression" blocks of art/loop/settings.json (docs/19_art_loop.md).
## Used by tools/art_loop.gd and tests/unit/art_loop_test.gd.
##
## The loop never approves art. Its only outcomes are "go on", "scores are
## still missing" and "stopped: show the user".

const STATUS_CONTINUE: String = "continue"
const STATUS_SCORE_PENDING: String = "score_pending"
const STATUS_STOPPED: String = "stopped_show_user"
const REASON_ROUND_CAP: String = "round_cap"
const REASON_PLATEAU: String = "plateau"
const REASON_METRIC_REGRESSION: String = "metric_regression"
const KEY_OVERALL: String = "overall"
## Metrics added up over a round's snapshots (the trend the user is shown).
const TOTAL_KEYS: PackedStringArray = [
	"specks", "line_breaks", "halo_px", "colors_exact", "colors_quantized",
]
const DEFAULT_LOOP: Dictionary = {
	"max_rounds": 5,
	"patience_rounds": 2,
	"min_improvement": 0.25,
	"reviewers": 2,
	"score_min": 1,
	"score_max": 5,
	"criteria": ["ai_look", "style_fit"],
}
const DEFAULT_REGRESSION: Dictionary = {
	"specks": {"abs": 2, "rel": 0.1},
	"line_breaks": {"abs": 1, "rel": 0.1},
	"halo_px": {"abs": 4, "rel": 0.1},
}


## Returns DEFAULT_LOOP with every value present in `overrides` replaced.
static func merged_loop(overrides: Dictionary) -> Dictionary:
	var merged: Dictionary = DEFAULT_LOOP.duplicate(true)
	for key: String in merged.keys():
		if overrides.has(key):
			merged[key] = overrides[key]
	return merged


## Checks one reviewer answer against the fixed shape:
##   {"scores": {"<criterion>": {"score": <whole number>, "reason": "<one line>"}, ...}}
## Returns the problems found (empty when the answer is usable).
static func validate_review(review: Variant, loop: Dictionary) -> PackedStringArray:
	var problems: PackedStringArray = []
	if not (review is Dictionary):
		problems.append("answer is not a JSON object")
		return problems
	var answer: Dictionary = review
	if not (answer.get("scores") is Dictionary):
		problems.append("missing object: scores")
		return problems
	var scores: Dictionary = answer["scores"]
	var score_min: int = int(loop["score_min"])
	var score_max: int = int(loop["score_max"])
	var criteria: Array = loop["criteria"]
	for criterion: Variant in criteria:
		var name: String = str(criterion)
		if not (scores.get(name) is Dictionary):
			problems.append("missing criterion: %s" % name)
			continue
		var entry: Dictionary = scores[name]
		var score: Variant = entry.get("score")
		if not (score is int or score is float) or float(score) != floorf(float(score)):
			problems.append("%s.score must be a whole number" % name)
		elif int(score) < score_min or int(score) > score_max:
			problems.append("%s.score must be %d..%d" % [name, score_min, score_max])
		var reason: Variant = entry.get("reason")
		if not (reason is String) or str(reason).strip_edges().is_empty():
			problems.append("%s.reason must be one line of text" % name)
		elif str(reason).strip_edges().contains("\n"):
			problems.append("%s.reason must be a single line" % name)
	for key: Variant in scores.keys():
		if not criteria.has(str(key)):
			problems.append("unknown criterion: %s" % str(key))
	return problems


## Averages valid reviewer answers per criterion; "overall" is the mean of the
## criterion averages.
static func average_reviews(reviews: Array, loop: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var criteria: Array = loop["criteria"]
	var overall: float = 0.0
	for criterion: Variant in criteria:
		var name: String = str(criterion)
		var sum: float = 0.0
		for review: Variant in reviews:
			var answer: Dictionary = review
			var scores: Dictionary = answer["scores"]
			var entry: Dictionary = scores[name]
			sum += float(entry["score"])
		var mean: float = sum / float(reviews.size())
		result[name] = mean
		overall += mean
	result[KEY_OVERALL] = overall / float(criteria.size())
	return result


## Adds the countable metrics of a round's snapshots together.
static func metric_totals(snapshots: Array) -> Dictionary:
	var totals: Dictionary = {}
	for key: String in TOTAL_KEYS:
		var sum: int = 0
		for snapshot: Variant in snapshots:
			var entry: Dictionary = snapshot
			sum += int(entry.get(key, 0))
		totals[key] = sum
	return totals


## One line per snapshot (name and size), so rounds can be told apart when a
## different set of pictures was measured.
static func snapshot_signature(snapshots: Array) -> String:
	var parts: PackedStringArray = []
	for snapshot: Variant in snapshots:
		var entry: Dictionary = snapshot
		parts.append("%s %dx%d" % [str(entry.get("file", "")), int(entry.get("width", 0)), int(entry.get("height", 0))])
	parts.sort()
	return "|".join(parts)


## Lists watched metrics that got worse from `previous` to `current`: a rise
## larger than both the rule's "abs" and its "rel" share of the previous value.
static func regressions(previous: Dictionary, current: Dictionary, rules: Dictionary) -> PackedStringArray:
	var worse: PackedStringArray = []
	for key: Variant in rules.keys():
		var name: String = str(key)
		if not previous.has(name) or not current.has(name) or not (rules[key] is Dictionary):
			continue
		var rule: Dictionary = rules[key]
		var before: int = int(previous[name])
		var after: int = int(current[name])
		var allowed: float = maxf(float(rule.get("abs", 0)), float(rule.get("rel", 0.0)) * float(before))
		if float(after - before) > allowed:
			worse.append("%s %d -> %d (allowed rise %s)" % [name, before, after, String.num(allowed, 2)])
	return worse


## Decides what the loop does next. `rounds` is the list kept in scores.json:
## each entry has "round", "metrics" (totals), "signature" and "scores"
## (null until the reviewers' answers are recorded).
## Returns {"status", "reasons", "details", "best_round", "rounds_done"}.
static func decide(rounds: Array, loop: Dictionary, regression_rules: Dictionary) -> Dictionary:
	var reasons: PackedStringArray = []
	var details: PackedStringArray = []
	var best_round: int = 0
	var best_score: float = -1.0
	var anchor: float = -1.0
	var stale_rounds: int = 0
	var min_improvement: float = float(loop["min_improvement"])
	for entry: Variant in rounds:
		var round_entry: Dictionary = entry
		if not (round_entry.get("scores") is Dictionary):
			continue
		var scores: Dictionary = round_entry["scores"]
		var overall: float = float(scores[KEY_OVERALL])
		if overall > best_score:
			best_score = overall
			best_round = int(round_entry["round"])
		if anchor < 0.0 or overall >= anchor + min_improvement:
			anchor = overall
			stale_rounds = 0
		else:
			stale_rounds += 1

	var latest_scored: bool = true
	if not rounds.is_empty():
		var latest: Dictionary = rounds[rounds.size() - 1]
		latest_scored = latest.get("scores") is Dictionary
		if rounds.size() >= 2:
			var before: Dictionary = rounds[rounds.size() - 2]
			if str(before.get("signature", "")) != str(latest.get("signature", "")):
				details.append("snapshots differ from the previous round: metrics were not compared")
			else:
				var worse: PackedStringArray = regressions(before["metrics"], latest["metrics"], regression_rules)
				if not worse.is_empty():
					reasons.append(REASON_METRIC_REGRESSION)
					for line: String in worse:
						details.append("metric got worse: " + line)
	if latest_scored and stale_rounds >= int(loop["patience_rounds"]):
		reasons.append(REASON_PLATEAU)
		details.append(
			"no rise of %s or more over %s for %d round(s)"
			% [String.num(min_improvement, 2), String.num(anchor, 2), stale_rounds]
		)
	if latest_scored and rounds.size() >= int(loop["max_rounds"]):
		reasons.append(REASON_ROUND_CAP)
		details.append("round cap reached: %d" % int(loop["max_rounds"]))

	var status: String = STATUS_CONTINUE
	if not reasons.is_empty():
		status = STATUS_STOPPED
	elif not latest_scored:
		status = STATUS_SCORE_PENDING
	return {
		"status": status,
		"reasons": reasons,
		"details": details,
		"best_round": best_round,
		"rounds_done": rounds.size(),
	}


## The table shown to the user: scores and metric totals per round.
static func report_lines(rounds: Array, loop: Dictionary) -> PackedStringArray:
	var lines: PackedStringArray = []
	var criteria: Array = loop["criteria"]
	var header: PackedStringArray = ["round"]
	for criterion: Variant in criteria:
		header.append(str(criterion))
	header.append(KEY_OVERALL)
	for key: String in TOTAL_KEYS:
		header.append(key)
	lines.append(" | ".join(header))
	for entry: Variant in rounds:
		var round_entry: Dictionary = entry
		var cells: PackedStringArray = ["r%02d" % int(round_entry["round"])]
		var scored: bool = round_entry.get("scores") is Dictionary
		for criterion: Variant in criteria + [KEY_OVERALL]:
			if scored:
				var scores: Dictionary = round_entry["scores"]
				cells.append("%.2f" % float(scores[str(criterion)]))
			else:
				cells.append("-")
		var metrics: Dictionary = round_entry.get("metrics", {})
		for key: String in TOTAL_KEYS:
			cells.append(str(int(metrics.get(key, 0))))
		lines.append(" | ".join(cells))
	return lines
