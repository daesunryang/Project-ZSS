#!/usr/bin/env bash
# Shared helpers for tools/*.sh. Sourced, not executed.
# GODOT: path to the Godot 4.7.2 stable editor binary (override via env).
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-/home/user/tools/godot/Godot_v4.7.2-stable_linux.x86_64}"
REQUIRED_GODOT_VERSION="4.7.2.stable"

require_godot() {
	if [[ ! -x "$GODOT" ]]; then
		echo "error: Godot binary not found or not executable: $GODOT (set GODOT=...)" >&2
		exit 127
	fi
	local version
	version="$("$GODOT" --version | head -n1)"
	if [[ "$version" != "$REQUIRED_GODOT_VERSION"* ]]; then
		echo "error: Godot $REQUIRED_GODOT_VERSION required, found $version" >&2
		exit 127
	fi
}

# Imports resources and refreshes the global class cache (.godot/), needed
# on a fresh clone before scripts using class_name can run.
import_project() {
	"$GODOT" --headless --path "$PROJECT_DIR" --import >/dev/null 2>&1 || {
		echo "error: project import failed" >&2
		exit 1
	}
}

# Fails (returns 1) if a log contains engine/script errors.
# Engine errors start with "ERROR:" / "SCRIPT ERROR:"; GameLogger uses "[ERROR]"/"[FATAL]".
log_has_errors() {
	grep -nE '(^|[[:space:]])(SCRIPT ERROR|ERROR):|\[(ERROR|FATAL)\]' "$1"
}
