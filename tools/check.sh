#!/usr/bin/env bash
# One-line local CI, the full gate before a merge: the selector's self-test,
# every test of both tiers (the combat bot included) and the server/client
# smoke test. For a quick check of what just changed: tools/test_changed.sh
# (docs/12 §9).
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
"$PROJECT_DIR/tools/test_changed_selftest.sh"
"$PROJECT_DIR/tools/run_tests.sh"
"$PROJECT_DIR/tools/smoke_test.sh"
echo "[check] all checks passed"
