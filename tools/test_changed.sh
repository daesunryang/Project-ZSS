#!/usr/bin/env bash
# Runs the tests that fit what changed (docs/12 §9.2).
#
#   tools/test_changed.sh [<base-ref>] [--dry-run] [--list] [--no-smoke] [--paths=<a>,<b>,...]
#
# What changed: `git diff --name-only <base-ref>` (committed since the base,
# staged and unstaged) plus untracked files. Without <base-ref> the base is
# the commit this branch left `main` at (git merge-base HEAD main); when
# nothing differs from it (on `main` with a clean tree) it is the previous
# commit (HEAD~1).
#
# What runs: tests/test_changes.cfg maps path patterns to tests.
#   - documents only            -> nothing
#   - any code change           -> the P0 tier + the tests the map names
#                                  + the smoke test (real processes)
#   - a path the map does not know -> the P0 tier
#   - combat / zombie / survival / navigation / posture code -> also the
#     headless combat bot
# It prints every changed path with the rule that chose its tests, then the
# commands. tools/check.sh stays the full gate before a merge.
#
#   --dry-run    print the choice and the commands, run nothing
#   --list       print the chosen test files (starts Godot), run nothing
#   --no-smoke   leave the smoke test out
#   --paths=...  use these paths instead of asking git (for trying the map)
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
MAP_FILE="$PROJECT_DIR/tests/test_changes.cfg"
BOT_TEST="tests/scenarios/combat_bot_test.gd"

BASE=""
DRY_RUN=0
LIST=0
SMOKE=1
PATHS_ARG=""
HAVE_PATHS=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		--list) LIST=1 ;;
		--no-smoke) SMOKE=0 ;;
		--paths=*) PATHS_ARG="${arg#--paths=}"; HAVE_PATHS=1 ;;
		-h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
		-*) echo "error: unknown option $arg (see --help)" >&2; exit 2 ;;
		*)
			if [[ -n "$BASE" ]]; then echo "error: more than one base ref: $BASE $arg" >&2; exit 2; fi
			BASE="$arg" ;;
	esac
done
if [[ ! -f "$MAP_FILE" ]]; then
	echo "error: change map not found: $MAP_FILE" >&2
	exit 2
fi
cd "$PROJECT_DIR"

# Everything that differs from commit $1: committed since, staged, unstaged
# and untracked.
changed_since() {
	{
		git -c core.quotepath=off diff --name-only "$1"
		git -c core.quotepath=off ls-files --others --exclude-standard
	} | sort -u
}

CHANGED=()
if [[ $HAVE_PATHS -eq 1 ]]; then
	IFS=',' read -r -a CHANGED <<< "$PATHS_ARG"
	echo "[changed] paths given on the command line: ${#CHANGED[@]}"
else
	if [[ -n "$BASE" ]]; then
		if ! git rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
			echo "error: not a commit: $BASE" >&2
			exit 2
		fi
		mapfile -t CHANGED < <(changed_since "$BASE")
	else
		# Default base: where this branch left main. When that leaves nothing
		# (main itself, or a branch with nothing new, and a clean tree), the
		# previous commit: "what did the last commit change".
		BASE="HEAD"
		if git rev-parse --verify -q main >/dev/null; then
			BASE="$(git merge-base HEAD main)"
		fi
		mapfile -t CHANGED < <(changed_since "$BASE")
		if [[ ${#CHANGED[@]} -eq 0 ]] && git rev-parse --verify -q "HEAD~1" >/dev/null; then
			BASE="HEAD~1"
			mapfile -t CHANGED < <(changed_since "$BASE")
		fi
	fi
	echo "[changed] base $BASE ($(git rev-parse --short "$BASE")): ${#CHANGED[@]} changed path(s), uncommitted and untracked included"
fi

CODE_CHANGE=0
RUN_ALL=0
FILES=()
add_file() {
	local wanted="$1" existing
	for existing in ${FILES[@]+"${FILES[@]}"}; do
		[[ "$existing" == "$wanted" ]] && return
	done
	FILES+=("$wanted")
}

for path in ${CHANGED[@]+"${CHANGED[@]}"}; do
	[[ -z "$path" ]] && continue
	matched=0
	reasons=""
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%$'\r'}"
		[[ -z "$line" || "$line" == \#* ]] && continue
		pattern="${line%% *}"
		targets="${line#* }"
		if [[ "$path" =~ $pattern ]]; then
			matched=1
			reasons+=" [$pattern -> $targets]"
			for target in $targets; do
				case "$target" in
					none) ;;
					p0) CODE_CHANGE=1 ;;
					all) CODE_CHANGE=1; RUN_ALL=1 ;;
					bot) CODE_CHANGE=1; add_file "$BOT_TEST" ;;
					self)
						CODE_CHANGE=1
						# A deleted test file leaves nothing to run but P0.
						if [[ -f "$PROJECT_DIR/$path" ]]; then add_file "$path"; fi ;;
					*) CODE_CHANGE=1; add_file "$target" ;;
				esac
			done
		fi
	done < "$MAP_FILE"
	if [[ $matched -eq 0 ]]; then
		CODE_CHANGE=1
		reasons=" [unknown path -> p0]"
	fi
	echo "[changed]   $path$reasons"
done

if [[ ${#CHANGED[@]} -eq 0 ]]; then
	echo "[changed] nothing changed"
	echo "[changed] RUN: nothing"
	exit 0
fi
if [[ $CODE_CHANGE -eq 0 ]]; then
	echo "[changed] documents only"
	echo "[changed] RUN: nothing"
	exit 0
fi

TEST_ARGS=()
if [[ $RUN_ALL -eq 1 ]]; then
	echo "[changed] chosen: every test (a change everything rides on)"
else
	TEST_ARGS+=("--tier=p0")
	if [[ ${#FILES[@]} -gt 0 ]]; then
		joined="$(IFS=','; echo "${FILES[*]}")"
		TEST_ARGS+=("--files=$joined")
	fi
	bot_note="no"
	for wanted in ${FILES[@]+"${FILES[@]}"}; do
		[[ "$wanted" == "$BOT_TEST" ]] && bot_note="yes"
	done
	echo "[changed] chosen: the P0 tier + ${#FILES[@]} named test group(s); combat bot: $bot_note"
fi
echo "[changed] RUN: tools/run_tests.sh ${TEST_ARGS[*]+"${TEST_ARGS[*]}"}"
if [[ $SMOKE -eq 1 ]]; then
	echo "[changed] RUN: tools/smoke_test.sh"
fi
if [[ $DRY_RUN -eq 1 ]]; then
	exit 0
fi
if [[ $LIST -eq 1 ]]; then
	"$PROJECT_DIR/tools/run_tests.sh" ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} --list
	exit 0
fi
"$PROJECT_DIR/tools/run_tests.sh" ${TEST_ARGS[@]+"${TEST_ARGS[@]}"}
if [[ $SMOKE -eq 1 ]]; then
	"$PROJECT_DIR/tools/smoke_test.sh"
fi
echo "[changed] the chosen checks passed (tools/check.sh is the full gate)"
