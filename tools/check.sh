#!/usr/bin/env bash
# One-line local CI: unit/integration tests + server/client smoke test.
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
"$PROJECT_DIR/tools/run_tests.sh"
"$PROJECT_DIR/tools/smoke_test.sh"
echo "[check] all checks passed"
