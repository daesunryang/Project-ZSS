class_name TestTiers
extends RefCounted
## The test tiers (docs/12 §9): which test file belongs to P0 ("the game does
## not work when this breaks") and which to P1 (everything else). The data is
## `tests/test_tiers.cfg`, one line per test file:
##
##   <tier> <path from the project root>      e.g.  p0 tests/unit/save_service_test.gd
##
## Empty lines and lines starting with `#` are ignored. The same file is read
## by tests/run_tests.gd (`--tier=`) and by tools/test_changed.sh, so the
## format stays this simple on purpose.

const DEFAULT_PATH: String = "res://tests/test_tiers.cfg"
const RES_PREFIX: String = "res://"
const TIER_P0: String = "p0"
const TIER_P1: String = "p1"
## Accepted by select(): every tier.
const TIER_ALL: String = "all"
const TIERS: PackedStringArray = [TIER_P0, TIER_P1]
const COMMENT_PREFIX: String = "#"
const FIELDS_PER_LINE: int = 2

## Project path ("tests/unit/x_test.gd") -> tier.
var tier_by_path: Dictionary[String, String] = {}
## Project path -> how many lines name it (1 when the file is fine).
var line_count_by_path: Dictionary[String, int] = {}
## Lines that could not be read (wrong field count, unknown tier).
var errors: PackedStringArray = []


## Reads the tier file. A missing file gives an empty table with an error.
static func load_file(path: String = DEFAULT_PATH) -> TestTiers:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		var missing: TestTiers = TestTiers.new()
		missing.errors.append("tier file not found: %s" % path)
		return missing
	return parse(file.get_as_text())


## Builds the table from the text of a tier file.
static func parse(text: String) -> TestTiers:
	var tiers: TestTiers = TestTiers.new()
	var line_number: int = 0
	for raw_line: String in text.split("\n"):
		line_number += 1
		var line: String = raw_line.strip_edges()
		if line.is_empty() or line.begins_with(COMMENT_PREFIX):
			continue
		var fields: PackedStringArray = line.split(" ", false)
		if fields.size() != FIELDS_PER_LINE:
			tiers.errors.append("line %d: expected '<tier> <path>', got '%s'" % [line_number, line])
			continue
		if not TIERS.has(fields[0]):
			tiers.errors.append("line %d: unknown tier '%s'" % [line_number, fields[0]])
			continue
		var path: String = to_project_path(fields[1])
		tiers.line_count_by_path[path] = int(tiers.line_count_by_path.get(path, 0)) + 1
		tiers.tier_by_path[path] = fields[0]
	return tiers


## "res://tests/unit/x_test.gd" -> "tests/unit/x_test.gd".
static func to_project_path(path: String) -> String:
	return path.trim_prefix(RES_PREFIX)


## Tier of a test file ("" when the file is not classified).
func tier_of(path: String) -> String:
	return str(tier_by_path.get(to_project_path(path), ""))


## Every classified path of `tier`, sorted.
func paths_of(tier: String) -> PackedStringArray:
	var paths: PackedStringArray = []
	for path: String in tier_by_path:
		if tier_by_path[path] == tier:
			paths.append(path)
	paths.sort()
	return paths


## What is wrong between the table and the test files that exist: a file
## without a tier, a file named on more than one line, a line for a file
## that does not exist. Empty when every file is classified exactly once.
func problems_for(existing_files: PackedStringArray) -> PackedStringArray:
	var problems: PackedStringArray = errors.duplicate()
	var existing: Dictionary[String, bool] = {}
	for file_path: String in existing_files:
		var path: String = to_project_path(file_path)
		existing[path] = true
		if not tier_by_path.has(path):
			problems.append("not classified: %s" % path)
	for path: String in line_count_by_path:
		if line_count_by_path[path] > 1:
			problems.append("classified %d times: %s" % [line_count_by_path[path], path])
		if not existing.has(path):
			problems.append("classified but missing: %s" % path)
	problems.sort()
	return problems


## The files of `candidates` a run takes: with neither a tier nor patterns,
## all of them; otherwise every file of `tier` (TIER_ALL = every file) plus
## every file whose path contains one of `patterns`. Order is kept.
func select(candidates: PackedStringArray, tier: String, patterns: PackedStringArray) -> PackedStringArray:
	if tier.is_empty() and patterns.is_empty():
		return candidates.duplicate()
	var selected: PackedStringArray = []
	for candidate: String in candidates:
		var path: String = to_project_path(candidate)
		var taken: bool = tier == TIER_ALL or (not tier.is_empty() and tier_of(path) == tier)
		for pattern: String in patterns:
			if not pattern.is_empty() and path.contains(pattern):
				taken = true
				break
		if taken:
			selected.append(candidate)
	return selected
