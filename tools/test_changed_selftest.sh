#!/usr/bin/env bash
# Checks what tools/test_changed.sh chooses for known paths (docs/12 §9.2).
# No Godot: every case is a --dry-run with --paths=. Run by tools/check.sh.
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
FAILED=0
BOT="tests/scenarios/combat_bot_test.gd"

# expect <name> <paths> <must contain>... ; a text starting with "!" must NOT appear.
expect() {
	local name="$1" paths="$2" output ok=1 text
	shift 2
	output="$("$PROJECT_DIR/tools/test_changed.sh" --dry-run "--paths=$paths" 2>&1)" || { echo "[selftest] $name: exit code $?" >&2; ok=0; }
	for text in "$@"; do
		if [[ "$text" == !* ]]; then
			if grep -qF -- "${text#!}" <<< "$output"; then echo "[selftest] $name: unexpected '${text#!}'" >&2; ok=0; fi
		elif ! grep -qF -- "$text" <<< "$output"; then
			echo "[selftest] $name: missing '$text'" >&2; ok=0
		fi
	done
	if [[ $ok -eq 1 ]]; then echo "[selftest] PASS $name"; else echo "[selftest] FAIL $name"; echo "$output"; FAILED=1; fi
}

expect documents_only "docs/12_testing_acceptance.md,notes/test-tiers.md,README.md" \
	"documents only" "RUN: nothing" "!run_tests.sh" "!smoke_test.sh"
expect nothing_changed "" "nothing changed" "RUN: nothing"
expect unknown_path_gets_p0 "somewhere/new_thing.xyz" \
	"unknown path -> p0" "RUN: tools/run_tests.sh --tier=p0" "RUN: tools/smoke_test.sh" "!--files=" "!$BOT"
expect documents_and_code "docs/02_survival_combat_infection.md,somewhere/new_thing.xyz" \
	"RUN: tools/run_tests.sh --tier=p0" "!documents only"
for path in scripts/domain/combat/combat_service.gd scripts/domain/zombie/zombie_service.gd \
	scripts/domain/survival/survival_service.gd scripts/domain/navigation/grid_path_finder.gd \
	scripts/domain/posture/posture_service.gd scripts/services/multiplayer/combat_net_module.gd \
	scripts/services/multiplayer/client_zombie_state.gd data/tuning/zombie_settings.tres \
	resources/definitions/melee_weapons/dev_melee_pipe.tres tests/bot/combat_bot_policy.gd; do
	expect "bot_runs_for_$(basename "$path")" "$path" "--tier=p0" "$BOT" "combat bot: yes" "RUN: tools/smoke_test.sh"
done
expect combat_names_its_tests "scripts/domain/combat/melee_hit_rules.gd" "--tier=p0 --files=combat_,phase2_acceptance,$BOT"
expect save_names_persistence "scripts/services/save/save_service.gd" "--tier=p0 --files=save,persistence" "combat bot: no"
expect trade_does_not_run_the_bot "scripts/domain/trade/trade_service.gd" "--files=trade_" "combat bot: no" "!$BOT"
expect a_changed_test_runs_itself "tests/unit/posture_test.gd" "--files=tests/unit/posture_test.gd"
expect framework_runs_everything "tests/framework/net_test_cluster.gd" "every test" "!--tier=p0"
expect art_tools_run_the_art_tests "tools/art_metrics_lib.gd" "--tier=p0 --files=test_tiers_test,art_" "combat bot: no"
expect art_data_runs_the_art_tests "art/loop/settings.json" "--tier=p0 --files=art_" "combat bot: no"
expect perf_bench_runs_its_digest_test "tools/perf_bench_scenario.gd" "--tier=p0 --files=test_tiers_test,perf_bench_digest" "combat bot: no"
expect agent_skills_are_documents ".claude/skills/art-loop/SKILL.md,AGENTS.md" "documents only" "RUN: nothing"
expect core_runs_everything "scripts/core/server_composition.gd" "every test" "!--tier=p0"
exit "$FAILED"
