#!/usr/bin/env bash
# Art loop helper (docs/19_art_loop.md). Keeps the round folders, snapshots,
# metrics and scores under art/loop/runs/<job>/.
#
#   tools/art_loop.sh start  <job> "<goal in the user's own words>"
#   tools/art_loop.sh round  <job> [--user-said-continue="<the user's words>"] <png> [<png>...]
#   tools/art_loop.sh pack   <job>      # review pack in a new temp folder + reviewer prompt
#   tools/art_loop.sh record <job>      # average the two reviewer answers, decide
#   tools/art_loop.sh report <job>      # what to show the user
#   tools/art_loop.sh metrics <image> [<image>...]   # metrics only, JSON to stdout
#
# Exit codes: 0 done, 1 wrong use, 2 refused (stopped / scores missing /
# the user's slots are empty). The loop never approves art.
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
require_godot

# Godot needs Windows-style paths when this runs from Git Bash.
native_path() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || { sed -n '2,13p' "${BASH_SOURCE[0]}" >&2; exit 1; }
shift
ARGS=()
SCRIPT="res://tools/art_loop.gd"
case "$COMMAND" in
	metrics)
		SCRIPT="res://tools/art_metrics.gd"
		for arg in "$@"; do
			if [[ -e "$arg" ]]; then ARGS+=("$(native_path "$arg")"); else ARGS+=("$arg"); fi
		done
		;;
	round)
		ARGS+=("$COMMAND")
		for arg in "$@"; do
			if [[ -f "$arg" ]]; then ARGS+=("$(native_path "$arg")"); else ARGS+=("$arg"); fi
		done
		;;
	pack)
		PACK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/art-loop-review-XXXXXX")"
		ARGS+=("$COMMAND" "$@" "--out=$(native_path "$PACK_ROOT")")
		;;
	*)
		ARGS+=("$COMMAND" "$@")
		;;
esac
exec "$GODOT" --headless --path "$PROJECT_DIR" --script "$SCRIPT" -- "${ARGS[@]}"
