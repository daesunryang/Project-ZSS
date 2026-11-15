#!/usr/bin/env bash
# Starts the headless dedicated server with the empty world. Extra args are
# passed to the game, e.g. tools/run_server.sh --log-level=DEBUG --run-frames=600
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
require_godot
exec "$GODOT" --headless --path "$PROJECT_DIR" -- --server "$@"
