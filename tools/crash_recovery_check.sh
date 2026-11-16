#!/usr/bin/env bash
# Real-process persistence acceptance check.
#
# Each round exercises one graceful restart and three hard-kill moments. The
# save tree is inspected independently of the process logs so a successful
# boot cannot hide a stale manifest, duplicate entries, or abandoned temp
# files.
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
require_godot
import_project

ROUNDS="${CRASH_ROUNDS:-5}"
READY_TIMEOUT="${CRASH_READY_TIMEOUT:-45}"
SAVE_TIMEOUT="${CRASH_SAVE_TIMEOUT:-20}"
WORLD_ID="crash_world"
PROJECT_NAME="LAST HAVEN"
RUN_ID="crash_recovery_$$_$(date +%s)"
WORK="$(mktemp -d)"
FAILED=0
FAILURES=0
LAST_PID=0
LAST_STATUS=0
PORT_COUNTER=$((38000 + RANDOM % 12000))
TABLE_ROWS=()
LIVE_PIDS=()

if ! [[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
	echo "error: CRASH_ROUNDS must be a positive integer" >&2
	exit 2
fi

if command -v python3 >/dev/null 2>&1; then
	PYTHON=python3
elif command -v python >/dev/null 2>&1; then
	PYTHON=python
else
	echo "error: python3 or python is required to inspect JSON save files" >&2
	exit 127
fi

if [[ -n "${APPDATA:-}" ]]; then
	if command -v cygpath >/dev/null 2>&1; then
		USER_DATA="$(cygpath -u "$APPDATA")/Godot/app_userdata/$PROJECT_NAME"
	else
		USER_DATA="$APPDATA/Godot/app_userdata/$PROJECT_NAME"
	fi
else
	USER_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/$PROJECT_NAME"
fi
SAVE_BASE="$USER_DATA/crash_recovery/$RUN_ID"

fail() {
	echo "[crash] FAIL $*" >&2
	FAILED=1
	FAILURES=$((FAILURES + 1))
}

untrack_pid() {
	local target="$1" pid
	local remaining=()
	for pid in "${LIVE_PIDS[@]}"; do
		if [[ "$pid" != "$target" ]]; then remaining+=("$pid"); fi
	done
	LIVE_PIDS=("${remaining[@]}")
}

hard_kill() {
	local pid="$1"
	if ! kill -0 "$pid" 2>/dev/null; then
		untrack_pid "$pid"
		return 0
	fi
	case "$(uname -s)" in
		MINGW*|MSYS*|CYGWIN*)
			# `$!` is an MSYS pid, not a Windows pid: passing it to taskkill could
			# kill an unrelated Windows process with the same number. Use the
			# Windows pid MSYS records for this process; without it, only kill.
			local winpid=""
			if [[ -r "/proc/$pid/winpid" ]]; then
				winpid="$(cat "/proc/$pid/winpid" 2>/dev/null)"
			fi
			if [[ "$winpid" =~ ^[0-9]+$ ]]; then
				taskkill //F //PID "$winpid" >/dev/null 2>&1 || kill -9 "$pid" >/dev/null 2>&1 || true
			else
				kill -9 "$pid" >/dev/null 2>&1 || true
			fi
			;;
		*) kill -9 "$pid" >/dev/null 2>&1 || true ;;
	esac
	wait "$pid" 2>/dev/null || true
	untrack_pid "$pid"
}

cleanup() {
	local pid
	for pid in "${LIVE_PIDS[@]}"; do
		hard_kill "$pid"
	done
	if [[ "$FAILED" -eq 0 && "${CRASH_KEEP_WORK:-0}" != "1" ]]; then
		rm -rf -- "$WORK"
		case "$SAVE_BASE" in
			"$USER_DATA"/crash_recovery/*) rm -rf -- "$SAVE_BASE" ;;
			*) echo "[crash] refusing to remove unexpected save path: $SAVE_BASE" >&2 ;;
		esac
	else
		echo "[crash] logs kept at: $WORK" >&2
		echo "[crash] saves kept at: $SAVE_BASE" >&2
	fi
}
trap cleanup EXIT

next_port() {
	PORT_COUNTER=$((PORT_COUNTER + 1))
	echo "$PORT_COUNTER"
}

start_server() { # start_server <log> <save-root> <port> <seconds>
	local log="$1" save_root="$2" port="$3" seconds="$4"
	"$GODOT" --headless --path "$PROJECT_DIR" -- \
		--server "--port=$port" "--world-id=$WORLD_ID" \
		"--save-root=$save_root" "--run-seconds=$seconds" >"$log" 2>&1 &
	LAST_PID=$!
	LIVE_PIDS+=("$LAST_PID")
}

start_client() { # start_client <log> <port> <key> <name> <seconds>
	local log="$1" port="$2" key="$3" name="$4" seconds="$5"
	"$GODOT" --headless --path "$PROJECT_DIR" -- \
		--client "--connect=127.0.0.1:$port" "--player-key=$key" \
		"--character-name=$name" "--run-seconds=$seconds" >"$log" 2>&1 &
	LAST_PID=$!
	LIVE_PIDS+=("$LAST_PID")
}

wait_for_log() { # wait_for_log <log> <text> [timeout]
	local log="$1" text="$2" timeout_seconds="${3:-$READY_TIMEOUT}"
	local deadline=$((SECONDS + timeout_seconds))
	while (( SECONDS < deadline )); do
		if [[ -f "$log" ]] && grep -qF -- "$text" "$log"; then
			return 0
		fi
		if [[ -f "$log" ]] && grep -qF -- "[FATAL]" "$log"; then
			return 1
		fi
		sleep 0.05
	done
	return 1
}

wait_for_log_count() { # wait_for_log_count <log> <text> <count> [timeout]
	local log="$1" text="$2" expected="$3" timeout_seconds="${4:-$READY_TIMEOUT}"
	local deadline=$((SECONDS + timeout_seconds)) count=0
	while (( SECONDS < deadline )); do
		if [[ -f "$log" ]]; then
			count="$(grep -cF -- "$text" "$log" || true)"
			if (( count >= expected )); then
				return 0
			fi
		fi
		sleep 0.05
	done
	return 1
}

wait_process() {
	local pid="$1"
	set +e
	wait "$pid"
	LAST_STATUS=$?
	set -e
	untrack_pid "$pid"
}

check_clean_exit() { # check_clean_exit <name> <log> <status>
	local name="$1" log="$2" status="$3"
	if [[ "$status" -ne 0 ]]; then
		fail "$name exited with $status"
	fi
	if ! grep -qF -- "[main] shutdown | exit_code=0" "$log"; then
		fail "$name did not log a clean shutdown"
	fi
	if log_has_errors "$log"; then
		fail "$name logged an engine or game error"
	fi
}

manifest_generation() {
	"$PYTHON" - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(int(json.load(handle)["generation"]))
PY
}

manifest_player_count() {
	"$PYTHON" - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    files = json.load(handle)["files"]
print(sum(path.startswith("players/") and path.endswith(".json") for path in files))
PY
}

verify_save_tree() { # verify_save_tree <world-dir> <expected-players>
	"$PYTHON" - "$1" "$2" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
expected_players = int(sys.argv[2])
manifest_path = root / "manifest.json"
with manifest_path.open(encoding="utf-8") as handle:
    manifest = json.load(handle)
files = manifest.get("files")
assert isinstance(files, list) and "world_state.json" in files, "manifest file list is invalid"
assert len(files) == len(set(files)), "manifest contains duplicate paths"
assert not any(path.endswith(".tmp") for path in files), "manifest uses a temporary file"
players = [path for path in files if path.startswith("players/") and path.endswith(".json")]
assert len(players) == expected_players, f"expected {expected_players} players, found {len(players)}"
assert len({pathlib.PurePosixPath(path).stem for path in players}) == len(players), "duplicate player ids"
for relative in files:
    path = root.joinpath(*pathlib.PurePosixPath(relative).parts)
    assert path.is_file(), f"manifest file is missing: {relative}"
    with path.open(encoding="utf-8") as handle:
        json.load(handle)
with (root / "world_state.json").open(encoding="utf-8") as handle:
    world = json.load(handle)
maps = world.get("systems", {}).get("map_content", {}).get("maps", {})
assert isinstance(maps, dict) and maps, "saved world has no map-content record"
assert any(isinstance(record, dict) and record.get("complete") is True for record in maps.values()), "test map is not completely seeded"
PY
}

verify_restart_log() { # verify_restart_log <log> <generation> <players>
	local log="$1" generation="$2" players="$3" loaded
	if ! grep -qF -- "server listening" "$log"; then
		fail "restart did not listen: $log"
		return 0
	fi
	loaded="$(grep -F -- "world loaded" "$log" | tail -n 1 || true)"
	if [[ -z "$loaded" ]]; then
		fail "restart did not log the loaded generation: $log"
	else
		[[ "$loaded" == *"generation=$generation"* ]] || fail "restart loaded an unexpected generation: $loaded"
		[[ "$loaded" == *"players=$players"* ]] || fail "restart loaded an unexpected player count: $loaded"
	fi
	if grep -qF -- "new world seeded" "$log" || grep -qF -- "map content seeded" "$log"; then
		fail "restart seeded existing world content again: $log"
	fi
	if log_has_errors "$log"; then
		fail "restart logged an engine or game error: $log"
	fi
}

warning_for_restart() { # warning_for_restart <log> <world-dir>
	local log="$1" world_dir="$2" warning=""
	if grep -qF -- "file restored from backup" "$log"; then
		warning="restored from backup"
	fi
	if find "$world_dir" -type f -name '*.tmp' -print -quit | grep -q .; then
		warning="${warning:+$warning; }orphan .tmp ignored"
	fi
	echo "${warning:--}"
}

restart_and_check() { # restart_and_check <tag> <moment> <save-root> <world-dir> <port> <before-gen> <players>
	local tag="$1" moment="$2" save_root="$3" world_dir="$4" port="$5" before="$6" players="$7"
	local log pid after warning restart_ok="yes" failures_before="$FAILURES"
	log="$WORK/${tag}_restart.log"
	start_server "$log" "$save_root" "$port" 2
	pid=$LAST_PID
	if ! wait_for_log "$log" "server listening"; then
		fail "$tag restart timed out"
		hard_kill "$pid"
		TABLE_ROWS+=("$tag|$moment|no|$before/?|timeout")
		return 0
	fi
	wait_process "$pid"
	check_clean_exit "$tag restart" "$log" "$LAST_STATUS"
	verify_restart_log "$log" "$before" "$players"
	if ! after="$(manifest_generation "$world_dir/manifest.json")"; then
		fail "$tag restart left an unreadable manifest"
		after="?"
	fi
	if [[ "$after" != "?" && "$after" -ne $((before + 1)) ]]; then
		fail "$tag expected generation $((before + 1)), found $after"
	fi
	if ! verify_save_tree "$world_dir" "$players"; then
		fail "$tag save-tree verification failed"
	fi
	if (( FAILURES > failures_before )); then restart_ok="no"; fi
	warning="$(warning_for_restart "$log" "$world_dir")"
	TABLE_ROWS+=("$tag|$moment|$restart_ok|$before/$after|$warning")
}

launch_two_clients() { # launch_two_clients <tag> <port> <seconds>
	local tag="$1" port="$2" seconds="$3"
	start_client "$WORK/${tag}_client_a.log" "$port" "${tag}_a" "Crash A" "$seconds"
	CLIENT_A_PID=$LAST_PID
	start_client "$WORK/${tag}_client_b.log" "$port" "${tag}_b" "강제 종료 B" "$seconds"
	CLIENT_B_PID=$LAST_PID
}

wait_for_saved_players() { # wait_for_saved_players <manifest> <count>
	local manifest="$1" expected="$2" deadline=$((SECONDS + SAVE_TIMEOUT)) count
	while (( SECONDS < deadline )); do
		if [[ -f "$manifest" ]] && count="$(manifest_player_count "$manifest" 2>/dev/null)" && (( count == expected )); then
			return 0
		fi
		sleep 0.05
	done
	return 1
}

kill_when_tmp_appears() { # kill_when_tmp_appears <world-dir> <server-pid>
	local world_dir="$1" server_pid="$2" deadline=$((SECONDS + SAVE_TIMEOUT))
	local temps=()
	shopt -s globstar nullglob
	while (( SECONDS < deadline )); do
		temps=("$world_dir"/**/*.tmp)
		if (( ${#temps[@]} > 0 )); then
			echo "[crash] observed save temp: ${temps[0]}"
			hard_kill "$server_pid"
			return 0
		fi
		# Keep the polling interval below the normal small-world write window.
		sleep 0.001
	done
	return 1
}

run_graceful() {
	local round="$1" scenario save_root
	scenario="r${round}_graceful"
	save_root="user://crash_recovery/$RUN_ID/$scenario"
	local world_dir="$SAVE_BASE/$scenario/$WORLD_ID" port log pid before players
	port="$(next_port)"
	log="$WORK/${scenario}_server.log"
	start_server "$log" "$save_root" "$port" 8
	pid=$LAST_PID
	if ! wait_for_log "$log" "server listening"; then
		fail "$scenario initial server timed out"
		hard_kill "$pid"
		TABLE_ROWS+=("$scenario|normal stop|no|?/?|timeout")
		return 0
	fi
	launch_two_clients "$scenario" "$port" 3
	if ! wait_for_log_count "$log" "[net] character created" 2; then
		fail "$scenario did not create two characters"
	fi
	wait_process "$CLIENT_A_PID"; check_clean_exit "$scenario client A" "$WORK/${scenario}_client_a.log" "$LAST_STATUS"
	wait_process "$CLIENT_B_PID"; check_clean_exit "$scenario client B" "$WORK/${scenario}_client_b.log" "$LAST_STATUS"
	wait_process "$pid"; check_clean_exit "$scenario initial server" "$log" "$LAST_STATUS"
	if ! before="$(manifest_generation "$world_dir/manifest.json")"; then
		fail "$scenario initial manifest is unreadable"
		TABLE_ROWS+=("$scenario|normal stop|no|?/?|bad manifest")
		return 0
	fi
	players="$(manifest_player_count "$world_dir/manifest.json")"
	if [[ "$players" -ne 2 ]]; then fail "$scenario expected two saved players, found $players"; fi
	restart_and_check "$scenario" "normal stop" "$save_root" "$world_dir" "$(next_port)" "$before" "$players"
}

run_kill_after_start() {
	local round="$1" scenario save_root
	scenario="r${round}_after_start"
	save_root="user://crash_recovery/$RUN_ID/$scenario"
	local world_dir="$SAVE_BASE/$scenario/$WORLD_ID" port log pid before players
	port="$(next_port)"; log="$WORK/${scenario}_server.log"
	start_server "$log" "$save_root" "$port" 60; pid=$LAST_PID
	if ! wait_for_log "$log" "server listening"; then
		fail "$scenario initial server timed out"; hard_kill "$pid"
		TABLE_ROWS+=("$scenario|right after start|no|?/?|timeout")
		return 0
	fi
	hard_kill "$pid"
	before="$(manifest_generation "$world_dir/manifest.json")"
	players="$(manifest_player_count "$world_dir/manifest.json")"
	restart_and_check "$scenario" "right after start" "$save_root" "$world_dir" "$(next_port)" "$before" "$players"
}

run_kill_connected() {
	local round="$1" scenario save_root
	scenario="r${round}_connected"
	save_root="user://crash_recovery/$RUN_ID/$scenario"
	local world_dir="$SAVE_BASE/$scenario/$WORLD_ID" port log pid before players
	port="$(next_port)"; log="$WORK/${scenario}_server.log"
	start_server "$log" "$save_root" "$port" 60; pid=$LAST_PID
	if ! wait_for_log "$log" "server listening"; then
		fail "$scenario initial server timed out"; hard_kill "$pid"
		TABLE_ROWS+=("$scenario|clients connected|no|?/?|timeout")
		return 0
	fi
	launch_two_clients "$scenario" "$port" 30
	if ! wait_for_log_count "$log" "[net] character created" 2 || ! wait_for_saved_players "$world_dir/manifest.json" 2; then
		fail "$scenario did not persist both connected players"
	fi
	hard_kill "$pid"
	hard_kill "$CLIENT_A_PID"; hard_kill "$CLIENT_B_PID"
	before="$(manifest_generation "$world_dir/manifest.json")"
	players="$(manifest_player_count "$world_dir/manifest.json")"
	restart_and_check "$scenario" "clients connected" "$save_root" "$world_dir" "$(next_port)" "$before" "$players"
}

run_kill_in_flight() {
	local round="$1" scenario save_root
	scenario="r${round}_save_in_flight"
	save_root="user://crash_recovery/$RUN_ID/$scenario"
	local world_dir="$SAVE_BASE/$scenario/$WORLD_ID" port log pid before players
	port="$(next_port)"; log="$WORK/${scenario}_server.log"
	start_server "$log" "$save_root" "$port" 60; pid=$LAST_PID
	if ! wait_for_log "$log" "server listening"; then
		fail "$scenario initial server timed out"; hard_kill "$pid"
		TABLE_ROWS+=("$scenario|save .tmp observed|no|?/?|timeout")
		return 0
	fi
	launch_two_clients "$scenario" "$port" 30
	if ! kill_when_tmp_appears "$world_dir" "$pid"; then
		fail "$scenario never observed an in-flight .tmp file"
		hard_kill "$pid"
	fi
	hard_kill "$CLIENT_A_PID"; hard_kill "$CLIENT_B_PID"
	if ! before="$(manifest_generation "$world_dir/manifest.json")"; then
		fail "$scenario manifest is unreadable after hard kill"
		TABLE_ROWS+=("$scenario|save .tmp observed|no|?/?|bad manifest")
		return 0
	fi
	players="$(manifest_player_count "$world_dir/manifest.json")"
	restart_and_check "$scenario" "save .tmp observed" "$save_root" "$world_dir" "$(next_port)" "$before" "$players"
}

echo "[crash] work=$WORK"
echo "[crash] save_base=$SAVE_BASE"
echo "[crash] rounds=$ROUNDS"
for round in $(seq 1 "$ROUNDS"); do
	echo "[crash] round $round/$ROUNDS"
	run_graceful "$round"
	run_kill_after_start "$round"
	run_kill_connected "$round"
	run_kill_in_flight "$round"
done

printf '\n%-24s | %-20s | %-10s | %-17s | %s\n' "scenario" "kill moment" "restart ok" "generation b/a" "warnings"
printf '%s\n' "-------------------------+----------------------+------------+-------------------+---------------------"
for row in "${TABLE_ROWS[@]}"; do
	IFS='|' read -r scenario moment restart generations warnings <<<"$row"
	printf '%-24s | %-20s | %-10s | %-17s | %s\n' "$scenario" "$moment" "$restart" "$generations" "$warnings"
done

if [[ "$FAILED" -ne 0 ]]; then
	echo "[crash] FAILED; inspect $WORK" >&2
else
	echo "[crash] PASS: $ROUNDS rounds, ${#TABLE_ROWS[@]} restart checks"
fi
exit "$FAILED"
