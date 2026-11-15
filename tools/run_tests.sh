#!/usr/bin/env bash
# Runs all automated tests headless. Usage: tools/run_tests.sh [--filter=<substring>]
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
require_godot
import_project
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
