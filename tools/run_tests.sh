#!/usr/bin/env bash
# Runs the automated tests headless (all of them without options).
# Usage: tools/run_tests.sh [--filter=<substring>] [--tier=p0|p1|all] [--files=<a>,<b>,...] [--list]
#   --filter=  only the tests whose "file.gd::test_name" contains the text
#   --tier=    only the test files of that tier (tests/test_tiers.cfg)
#   --files=   also the test files whose path contains one of the texts
#   --list     print the chosen files and stop
# (docs/12 §9; tools/test_changed.sh chooses --tier/--files from what changed.)
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
require_godot
import_project
# Written into the combat bot's results log (tests/scenarios/combat_bot_test.gd).
if [[ -z "${ZSS_GIT_REV:-}" ]]; then
	ZSS_GIT_REV="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)" ]]; then
		ZSS_GIT_REV="$ZSS_GIT_REV+changes"
	fi
	export ZSS_GIT_REV
fi
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
set +e
"$GODOT" --headless --path "$PROJECT_DIR" --script res://tests/run_tests.gd -- "$@" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
if log_has_errors "$LOG"; then
	echo "[test] engine/script errors detected in output (see lines above)" >&2
	exit 1
fi
exit "$STATUS"
