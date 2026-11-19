#!/usr/bin/env bash
# Installs the OpenAI Codex CLI in a cloud (Linux) environment so the
# coordinator can hand work to Codex there, as on the local machine
# (AGENTS.md §12, .claude/skills/codex-art-handoff/).
#
# Authentication is the user's: set OPENAI_API_KEY as a secret in the cloud
# environment's settings. This script never prints the key; it only pipes
# the variable to `codex login --with-api-key` when it is set. Without it,
# Codex is installed but not logged in (the script says so and exits 0).
#
#   bash tools/cloud/setup_codex.sh
set -euo pipefail

CODEX_PACKAGE="@openai/codex"

if ! command -v npm >/dev/null 2>&1; then
	echo "[setup_codex] npm is required (Node.js); install Node.js first" >&2
	exit 127
fi

if ! command -v codex >/dev/null 2>&1; then
	echo "[setup_codex] installing $CODEX_PACKAGE"
	npm install -g "$CODEX_PACKAGE" >/dev/null
fi
echo "[setup_codex] $(codex --version)"

if codex login status >/dev/null 2>&1; then
	echo "[setup_codex] already logged in"
	exit 0
fi

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
	printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null
	if codex login status >/dev/null 2>&1; then
		echo "[setup_codex] logged in with the OPENAI_API_KEY secret"
	else
		echo "[setup_codex] login with OPENAI_API_KEY failed; check the secret" >&2
		exit 1
	fi
else
	echo "[setup_codex] not logged in: set OPENAI_API_KEY as a secret in the cloud environment, then run this again"
fi
