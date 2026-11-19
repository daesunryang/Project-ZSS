#!/usr/bin/env bash
# Fixed-seed server and client performance bench.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"

COMPARE_REF=""
RUN_CLIENT=1
HEADLESS_CLIENT=0
CLIENT_SECONDS="${ZSS_PERF_CLIENT_SECONDS:-10}"
PORT="${ZSS_PERF_PORT:-24689}"
CORE_ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--compare)
			[[ $# -ge 2 ]] || { echo "error: --compare needs a git ref" >&2; exit 2; }
			COMPARE_REF="$2"
			shift 2
			;;
		--compare=*)
			COMPARE_REF="${1#--compare=}"
			shift
			;;
		--no-client)
			RUN_CLIENT=0
			shift
			;;
		--headless-client)
			HEADLESS_CLIENT=1
			shift
			;;
		--client-seconds=*)
			CLIENT_SECONDS="${1#--client-seconds=}"
			shift
			;;
		--port=*)
			PORT="${1#--port=}"
			CORE_ARGS+=("$1")
			shift
			;;
		--seed=*|--ticks=*|--players=*|--zombies=*|--items=*|--delta=*|--save-every=*)
			CORE_ARGS+=("$1")
			shift
			;;
		*)
			echo "error: unknown option: $1" >&2
			exit 2
			;;
	esac
done

require_godot
command -v node >/dev/null 2>&1 || { echo "error: Node.js is required" >&2; exit 127; }
import_project

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zss-perf-bench.XXXXXX")"
BASE_TREE=""
SERVER_PID=""

cleanup() {
	if [[ -n "$SERVER_PID" ]]; then
		kill "$SERVER_PID" >/dev/null 2>&1 || true
	fi
	if [[ -n "$BASE_TREE" ]]; then
		git -C "$PROJECT_DIR" worktree remove --force "$BASE_TREE" >/dev/null 2>&1 || true
	fi
	rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

run_core() {
	local project_path="$1"
	local output_path="$2"
	local json_path="$3"
	set +e
	"$GODOT" --headless --path "$project_path" --script res://tools/perf_bench.gd -- "${CORE_ARGS[@]}" 2>&1 | tee "$output_path"
	local status=${PIPESTATUS[0]}
	set -e
	if [[ $status -ne 0 ]]; then
		echo "error: core performance bench failed with exit $status" >&2
		return "$status"
	fi
	local json_line
	json_line="$(grep '^PERF_BENCH_JSON=' "$output_path" | tail -n 1)"
	if [[ -z "$json_line" ]]; then
		echo "error: core performance bench produced no JSON result" >&2
		return 1
	fi
	printf '%s\n' "${json_line#PERF_BENCH_JSON=}" > "$json_path"
}

COMPARE_STATUS=0
if [[ -n "$COMPARE_REF" ]]; then
	BASE_TREE="$TEMP_ROOT/base"
	if ! git -C "$PROJECT_DIR" worktree add --detach "$BASE_TREE" "$COMPARE_REF"; then
		echo "error: could not create the detached comparison worktree; rerun outside a sandbox that blocks the common .git/worktrees directory" >&2
		exit 1
	fi
	cp "$PROJECT_DIR/tools/perf_bench.gd" "$BASE_TREE/tools/perf_bench.gd"
	cp "$PROJECT_DIR/tools/perf_bench_scenario.gd" "$BASE_TREE/tools/perf_bench_scenario.gd"
	cp "$PROJECT_DIR/tools/perf_bench_state.gd" "$BASE_TREE/tools/perf_bench_state.gd"
	"$GODOT" --headless --path "$BASE_TREE" --import >/dev/null 2>&1
	BASE_OUTPUT="$TEMP_ROOT/base.out"
	BASE_JSON="$TEMP_ROOT/base.json"
	run_core "$BASE_TREE" "$BASE_OUTPUT" "$BASE_JSON"
	# Run the current tree second so both sides use the same warmed engine setup.
	CURRENT_OUTPUT="$TEMP_ROOT/current.out"
	CURRENT_JSON="$TEMP_ROOT/current.json"
	run_core "$PROJECT_DIR" "$CURRENT_OUTPUT" "$CURRENT_JSON"
	set +e
	node "$PROJECT_DIR/tools/perf_bench_report.mjs" compare "$BASE_JSON" "$CURRENT_JSON"
	COMPARE_STATUS=$?
	set -e
else
	CURRENT_OUTPUT="$TEMP_ROOT/current.out"
	CURRENT_JSON="$TEMP_ROOT/current.json"
	run_core "$PROJECT_DIR" "$CURRENT_OUTPUT" "$CURRENT_JSON"
fi

CLIENT_JSON="-"
if [[ $RUN_CLIENT -eq 1 ]]; then
	SERVER_OUTPUT="$TEMP_ROOT/live_server.out"
	CLIENT_OUTPUT="$TEMP_ROOT/client.out"
	LIVE_SECONDS="$(node -e 'console.log(Number(process.argv[1]) + 12)' "$CLIENT_SECONDS")"
	"$GODOT" --headless --path "$PROJECT_DIR" --script res://tools/perf_bench.gd -- "${CORE_ARGS[@]}" --serve "--port=$PORT" "--seconds=$LIVE_SECONDS" >"$SERVER_OUTPUT" 2>&1 &
	SERVER_PID=$!
	ready=0
	for _attempt in $(seq 1 150); do
		if grep -q '^PERF_BENCH_SERVER_READY' "$SERVER_OUTPUT"; then
			ready=1
			break
		fi
		if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
			break
		fi
		sleep 0.1
	done
	if [[ $ready -ne 1 ]]; then
		echo "error: live bench server did not become ready" >&2
		cat "$SERVER_OUTPUT" >&2
		exit 1
	fi
	client_flags=()
	case "$(uname -s)" in
		MINGW*|MSYS*|CYGWIN*) ;;
		*)
			if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
				HEADLESS_CLIENT=1
			fi
			;;
	esac
	if [[ $HEADLESS_CLIENT -eq 1 ]]; then
		client_flags+=(--headless)
	fi
	expected_zombies="$(node -e 'const r=require(process.argv[1]); console.log(r.requested_counts.zombies)' "$CURRENT_JSON")"
	set +e
	ZSS_PERF_CLIENT_SECONDS="$CLIENT_SECONDS" ZSS_PERF_EXPECT_ZOMBIES="$expected_zombies" \
		"$GODOT" "${client_flags[@]}" --path "$PROJECT_DIR" --script res://tools/perf_client.gd -- \
		--client "--connect=127.0.0.1:$PORT" --player-key=perf_viewer 2>&1 | tee "$CLIENT_OUTPUT"
	client_status=${PIPESTATUS[0]}
	set -e
	if [[ $client_status -ne 0 ]]; then
		echo "error: performance client failed with exit $client_status" >&2
		cat "$SERVER_OUTPUT" >&2
		exit "$client_status"
	fi
	client_line="$(grep '^PERF_CLIENT_JSON=' "$CLIENT_OUTPUT" | tail -n 1)"
	if [[ -z "$client_line" ]]; then
		echo "error: performance client produced no JSON result" >&2
		exit 1
	fi
	CLIENT_JSON="$TEMP_ROOT/client.json"
	printf '%s\n' "${client_line#PERF_CLIENT_JSON=}" > "$CLIENT_JSON"
	wait "$SERVER_PID"
	SERVER_PID=""
	grep '^PERF_BENCH_LIVE_JSON=' "$SERVER_OUTPUT" || true
fi

COMMIT="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
RUN_DATE="$(date +%F)"
node "$PROJECT_DIR/tools/perf_bench_report.mjs" append-log \
	"$PROJECT_DIR/docs/18_perf_log.md" "$CURRENT_JSON" "$CLIENT_JSON" "$COMMIT" "$RUN_DATE"

exit "$COMPARE_STATUS"
