extends TestCase
## Art loop rules (tools/art_loop_lib.gd): reviewer answers, averages, metric
## comparison and the three stop rules. The loop never returns "approved".

const LoopLib: GDScript = preload("res://tools/art_loop_lib.gd")
const SIGNATURE: String = "a.png 64x64"


func _loop() -> Dictionary:
	return LoopLib.merged_loop({})


func _review(ai_look: Variant, style_fit: Variant) -> Dictionary:
	return {"scores": {
		"ai_look": {"score": ai_look, "reason": "one line"},
		"style_fit": {"score": style_fit, "reason": "one line"},
	}}


func _round(number: int, overall: Variant, specks: int = 0, signature: String = SIGNATURE) -> Dictionary:
	var scores: Variant = null
	if overall != null:
		scores = {"ai_look": overall, "style_fit": overall, "overall": overall}
	return {
		"round": number,
		"signature": signature,
		"metrics": {"specks": specks, "line_breaks": 0, "halo_px": 0},
		"scores": scores,
	}


func _decide(rounds: Array) -> Dictionary:
	return LoopLib.decide(rounds, _loop(), LoopLib.DEFAULT_REGRESSION)


func test_shipped_settings_match_the_defaults() -> void:
	var text: String = FileAccess.get_file_as_string("res://art/loop/settings.json")
	var parsed: Variant = JSON.parse_string(text)
	assert_true(parsed is Dictionary, "art/loop/settings.json is valid JSON")
	var settings: Dictionary = parsed
	var loop: Dictionary = LoopLib.merged_loop(settings["loop"])
	assert_eq(int(loop["max_rounds"]), 5)
	assert_eq(int(loop["patience_rounds"]), 2)
	assert_eq(int(loop["reviewers"]), 2)
	assert_eq(loop["criteria"], ["ai_look", "style_fit"])
	for key: String in LoopLib.DEFAULT_REGRESSION.keys():
		assert_true((settings["regression"] as Dictionary).has(key), key)


func test_valid_review_has_no_problems() -> void:
	assert_eq(LoopLib.validate_review(_review(4, 2), _loop()).size(), 0)
	assert_eq(LoopLib.validate_review(_review(4.0, 2.0), _loop()).size(), 0, "JSON numbers arrive as floats")


func test_bad_reviews_are_reported() -> void:
	assert_eq(LoopLib.validate_review("text", _loop()).size(), 1)
	assert_eq(LoopLib.validate_review({}, _loop()).size(), 1)
	assert_eq(LoopLib.validate_review(_review(6, 0), _loop()).size(), 2, "out of 1..5")
	assert_eq(LoopLib.validate_review(_review(3.5, 3), _loop()).size(), 1, "whole numbers only")
	var missing: Dictionary = {"scores": {"ai_look": {"score": 3, "reason": "x"}}}
	assert_eq(LoopLib.validate_review(missing, _loop()).size(), 1)
	var no_reason: Dictionary = _review(3, 3)
	no_reason["scores"]["ai_look"]["reason"] = "  "
	assert_eq(LoopLib.validate_review(no_reason, _loop()).size(), 1)
	var extra: Dictionary = _review(3, 3)
	extra["scores"]["approved"] = {"score": 5, "reason": "x"}
	assert_eq(LoopLib.validate_review(extra, _loop()).size(), 1, "no criteria beyond the rubric")


func test_two_reviews_are_averaged_per_criterion() -> void:
	var average: Dictionary = LoopLib.average_reviews([_review(4, 2), _review(5, 3)], _loop())
	assert_eq(average["ai_look"], 4.5)
	assert_eq(average["style_fit"], 2.5)
	assert_eq(average["overall"], 3.5)


func test_metric_totals_add_up_snapshots() -> void:
	var totals: Dictionary = LoopLib.metric_totals([
		{"specks": 2, "line_breaks": 1, "halo_px": 0, "colors_exact": 10, "colors_quantized": 5},
		{"specks": 3, "line_breaks": 0, "halo_px": 7, "colors_exact": 20, "colors_quantized": 6},
	])
	assert_eq(totals["specks"], 5)
	assert_eq(totals["line_breaks"], 1)
	assert_eq(totals["halo_px"], 7)
	assert_eq(totals["colors_exact"], 30)


func test_regression_needs_a_rise_past_the_allowance() -> void:
	var rules: Dictionary = LoopLib.DEFAULT_REGRESSION
	assert_eq(LoopLib.regressions({"specks": 10}, {"specks": 12}, rules).size(), 0, "abs allowance 2")
	assert_eq(LoopLib.regressions({"specks": 10}, {"specks": 13}, rules).size(), 1)
	assert_eq(LoopLib.regressions({"specks": 100}, {"specks": 110}, rules).size(), 0, "rel allowance 10%")
	assert_eq(LoopLib.regressions({"specks": 100}, {"specks": 111}, rules).size(), 1)
	assert_eq(LoopLib.regressions({"specks": 10}, {"specks": 0}, rules).size(), 0, "falling is fine")
	assert_eq(LoopLib.regressions({"colors_exact": 5}, {"colors_exact": 500}, rules).size(), 0, "colours are not watched")


func test_first_round_waits_for_scores_then_continues() -> void:
	var pending: Dictionary = _decide([_round(1, null)])
	assert_eq(pending["status"], LoopLib.STATUS_SCORE_PENDING)
	assert_eq(pending["best_round"], 0)
	var scored: Dictionary = _decide([_round(1, 3.0)])
	assert_eq(scored["status"], LoopLib.STATUS_CONTINUE)
	assert_eq(scored["best_round"], 1)


func test_rising_scores_continue() -> void:
	var decision: Dictionary = _decide([_round(1, 2.0), _round(2, 2.5), _round(3, 3.0)])
	assert_eq(decision["status"], LoopLib.STATUS_CONTINUE)
	assert_eq(decision["best_round"], 3)


func test_plateau_stops_after_two_rounds_without_a_real_rise() -> void:
	var one_flat: Dictionary = _decide([_round(1, 3.0), _round(2, 3.0)])
	assert_eq(one_flat["status"], LoopLib.STATUS_CONTINUE, "one flat round is within patience")
	var decision: Dictionary = _decide([_round(1, 3.0), _round(2, 3.1), _round(3, 3.2)])
	assert_eq(decision["status"], LoopLib.STATUS_STOPPED)
	assert_true((decision["reasons"] as PackedStringArray).has(LoopLib.REASON_PLATEAU))
	assert_eq(decision["best_round"], 3, "the best round is still the highest score")
	var falling: Dictionary = _decide([_round(1, 4.0), _round(2, 3.0), _round(3, 3.5)])
	assert_eq(falling["status"], LoopLib.STATUS_STOPPED)
	assert_eq(falling["best_round"], 1)


func test_a_real_rise_resets_the_patience() -> void:
	var decision: Dictionary = _decide([_round(1, 3.0), _round(2, 3.0), _round(3, 3.25), _round(4, 3.25)])
	assert_eq(decision["status"], LoopLib.STATUS_CONTINUE)


func test_round_cap_stops_even_while_scores_rise() -> void:
	var rounds: Array = []
	for number: int in range(1, 6):
		rounds.append(_round(number, 1.0 + 0.5 * float(number)))
	var decision: Dictionary = _decide(rounds)
	assert_eq(decision["status"], LoopLib.STATUS_STOPPED)
	assert_true((decision["reasons"] as PackedStringArray).has(LoopLib.REASON_ROUND_CAP))
	assert_eq(decision["best_round"], 5)
	rounds[4] = _round(5, null)
	assert_eq(_decide(rounds)["status"], LoopLib.STATUS_SCORE_PENDING, "the last round is scored before the cap stops the loop")


func test_metric_regression_stops_before_scoring() -> void:
	var decision: Dictionary = _decide([_round(1, 3.0, 4), _round(2, null, 9)])
	assert_eq(decision["status"], LoopLib.STATUS_STOPPED)
	assert_true((decision["reasons"] as PackedStringArray).has(LoopLib.REASON_METRIC_REGRESSION))
	assert_eq(decision["best_round"], 1)


func test_metrics_of_different_snapshots_are_not_compared() -> void:
	var decision: Dictionary = _decide([_round(1, 3.0, 4), _round(2, null, 90, "b.png 128x128")])
	assert_eq(decision["status"], LoopLib.STATUS_SCORE_PENDING)
	assert_eq((decision["details"] as PackedStringArray).size(), 1)


func test_no_outcome_is_called_approved() -> void:
	var statuses: PackedStringArray = [LoopLib.STATUS_CONTINUE, LoopLib.STATUS_SCORE_PENDING, LoopLib.STATUS_STOPPED]
	for status: String in statuses:
		assert_not_contains(status, "approv")
	var perfect: Dictionary = _decide([_round(1, 5.0)])
	assert_eq(perfect["status"], LoopLib.STATUS_CONTINUE, "a top score is still not an approval")


func test_report_lists_every_round() -> void:
	var lines: PackedStringArray = LoopLib.report_lines([_round(1, 3.0, 4), _round(2, null, 2)], _loop())
	assert_eq(lines.size(), 3)
	assert_contains(lines[0], "ai_look | style_fit | overall | specks")
	assert_contains(lines[1], "r01 | 3.00 | 3.00 | 3.00 | 4")
	assert_contains(lines[2], "r02 | - | - | - | 2")
