#!/usr/bin/env bash
# Runs the headless combat bot alone (docs/12 §9.3): every scene of
# tests/bot/scenes, or only the named ones.
#   tools/combat_bot.sh                      every scene
#   tools/combat_bot.sh one_zombie_open      one scene (scene_id)
#   tools/combat_bot.sh a_scene,another      several
# ZSS_BOT_TRACE=30 prints one line per swing and per hit taken, and the
# bot's status every 30 ticks (any number of ticks).
# The table is printed; one line per scene is appended to the results log
# (its path is printed, ZSS_BOT_LOG overrides it).
source "$(dirname "${BASH_SOURCE[0]}")/_godot_env.sh"
if [[ $# -gt 1 ]]; then
	echo "usage: tools/combat_bot.sh [scene_id[,scene_id...]]" >&2
	exit 2
fi
if [[ $# -eq 1 ]]; then
	export ZSS_BOT_SCENE="$1"
fi
"$PROJECT_DIR/tools/run_tests.sh" --files=tests/scenarios/combat_bot_test.gd
