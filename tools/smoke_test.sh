#!/usr/bin/env bash
# Acceptance smoke test (real processes, headless):
#  1. server alone and offline client alone boot and shut down cleanly
#     (client uses the headless display driver: no real rendering);
#  2. one server process + two client processes: both clients join the
#     server over ENet on localhost and all three exit cleanly. A dedicated
#     server asks every player to create a character (P2-T9); the headless
#     clients have no creation screen to click, so each gets its character
#     with --character-name= (name given, default appearance).
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
require_godot
import_project
FRAMES="${SMOKE_FRAMES:-120}"
RUN_ID="smoke_$$_$(date +%s)"
SAVE_ROOT="user://smoke_saves/$RUN_ID"
USER_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/LAST HAVEN"
PORT=$(( 35000 + RANDOM % 20000 ))
WORK="$(mktemp -d)"
FAILED=0
cleanup() { rm -rf "$WORK" "$USER_DATA/smoke_saves/$RUN_ID"; }
trap cleanup EXIT

check_log() {  # check_log <name> <log> <exit-status> <required-text>...
	local name="$1" log="$2" status="$3"; shift 3
	local ok=1
	[[ "$status" -eq 0 ]] || { echo "[smoke] $name: exit code $status" >&2; ok=0; }
	for text in "$@"; do
		grep -qF -- "$text" "$log" || { echo "[smoke] $name: missing '$text'" >&2; ok=0; }
	done
	if log_has_errors "$log"; then echo "[smoke] $name: errors in output" >&2; ok=0; fi
	if [[ $ok -eq 1 ]]; then echo "[smoke] PASS $name"; else echo "[smoke] FAIL $name"; cat "$log"; FAILED=1; fi
}

run_game() {  # run_game <log> <args...>
	local log="$1"; shift
	timeout 120 "$GODOT" --headless --path "$PROJECT_DIR" -- "$@" >"$log" 2>&1
}

# 1. single-process boots
set +e
run_game "$WORK/server.log" --server "--port=$PORT" "--save-root=$SAVE_ROOT/solo" "--run-frames=$FRAMES"; S=$?
set -e
check_log server "$WORK/server.log" $S "empty world ready" "role=server" "server listening" "world saved" "[main] shutdown | exit_code=0"
if grep -q "client view ready" "$WORK/server.log"; then echo "[smoke] FAIL server: presentation was loaded" >&2; FAILED=1; fi
set +e
run_game "$WORK/client.log" --client "--run-frames=$FRAMES"; S=$?
set -e
check_log client_offline "$WORK/client.log" $S "empty world ready" "role=client" "client view ready" "[main] shutdown | exit_code=0"

# 2. server + 2 client processes
set +e
run_game "$WORK/mp_server.log" --server "--port=$PORT" "--save-root=$SAVE_ROOT/mp" --run-seconds=7 &
SERVER_PID=$!
sleep 2
run_game "$WORK/mp_client_a.log" --client "--connect=127.0.0.1:$PORT" --player-key=smoke_a "--character-name=Smoke A" --run-seconds=3 &
A_PID=$!
run_game "$WORK/mp_client_b.log" --client "--connect=127.0.0.1:$PORT" --player-key=smoke_b "--character-name=스모크 B" --run-seconds=3 &
B_PID=$!
wait $A_PID; A=$?
wait $B_PID; B=$?
wait $SERVER_PID; S=$?
set -e
check_log mp_client_a "$WORK/mp_client_a.log" $A "joined world" "character created without a creation screen" "[main] shutdown | exit_code=0"
check_log mp_client_b "$WORK/mp_client_b.log" $B "joined world" "character created without a creation screen" "[main] shutdown | exit_code=0"
check_log mp_server "$WORK/mp_server.log" $S "server listening" "[main] shutdown | exit_code=0"
JOINS=$(grep -c "join accepted" "$WORK/mp_server.log" || true)
if [[ "$JOINS" -ne 2 ]]; then echo "[smoke] FAIL mp_server: expected 2 joins, got $JOINS" >&2; FAILED=1; else echo "[smoke] PASS mp_server_two_joins"; fi
# Both players joined without a character and created one by request.
WAITING=$(grep -c "player connected without a character" "$WORK/mp_server.log" || true)
CREATED=$(grep -cF "[net] character created" "$WORK/mp_server.log" || true)
if [[ "$WAITING" -ne 2 || "$CREATED" -ne 2 ]]; then echo "[smoke] FAIL mp_server: expected 2 players without a character and 2 created characters, got $WAITING and $CREATED" >&2; cat "$WORK/mp_server.log"; FAILED=1; else echo "[smoke] PASS mp_server_two_characters"; fi
exit "$FAILED"
