#!/usr/bin/env bash
# Starts the client (windowed; needs a display). Pass --headless before any
# game args is not supported here: use smoke_test.sh for headless checks.
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
require_godot
exec "$GODOT" --path "$PROJECT_DIR" -- --client "$@"
