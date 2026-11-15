#!/usr/bin/env bash
# Phase 0 acceptance smoke test: the empty world boots and shuts down cleanly
# as headless server and as client (client runs with the headless display
# driver, so no real rendering is exercised).
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
require_godot
import_project
FRAMES="${SMOKE_FRAMES:-120}"
FAILED=0
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

run_role() {
	local role="$1"
	set +e
	timeout 120 "$GODOT" --headless --path "$PROJECT_DIR" -- "--$role" "--run-frames=$FRAMES" >"$LOG" 2>&1
	local status=$?
	set -e
	cat "$LOG"
	local ok=1
	[[ $status -eq 0 ]] || { echo "[smoke] $role: exit code $status" >&2; ok=0; }
	grep -q "empty world ready" "$LOG" || { echo "[smoke] $role: world did not become ready" >&2; ok=0; }
	grep -q "role=$role" "$LOG" || { echo "[smoke] $role: wrong role" >&2; ok=0; }
	grep -q "\[main\] shutdown | exit_code=0" "$LOG" || { echo "[smoke] $role: no clean shutdown" >&2; ok=0; }
	if log_has_errors "$LOG"; then echo "[smoke] $role: errors in output" >&2; ok=0; fi
	if [[ "$role" == "server" ]] && grep -q "client view ready" "$LOG"; then
		echo "[smoke] server: presentation was loaded" >&2; ok=0
	fi
	if [[ $ok -eq 1 ]]; then echo "[smoke] PASS $role"; else echo "[smoke] FAIL $role"; FAILED=1; fi
}

run_role server
run_role client
exit "$FAILED"
