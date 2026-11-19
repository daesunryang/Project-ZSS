#!/usr/bin/env bash
# Installs the official Godot 4.7.2 stable Linux x86_64 build for headless
# use in a cloud (Linux) environment, at the path tools/_godot_env.sh
# expects by default. Idempotent: does nothing when the right version is
# already there. Verifies the archive against the official SHA512.
#
#   bash tools/cloud/setup_godot.sh            # install to the default path
#   GODOT_DIR=/opt/godot bash tools/cloud/setup_godot.sh
#
# Afterwards `bash tools/check.sh` works without setting GODOT (or export
# GODOT to the printed path if you installed elsewhere).
set -euo pipefail

VERSION="4.7.2-stable"
ARCHIVE="Godot_v${VERSION}_linux.x86_64.zip"
BINARY="Godot_v${VERSION}_linux.x86_64"
URL="https://github.com/godotengine/godot/releases/download/${VERSION}/${ARCHIVE}"
# From the official SHA512-SUMS.txt of the 4.7.2-stable release.
SHA512="9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65"
GODOT_DIR="${GODOT_DIR:-/home/user/tools/godot}"
TARGET="$GODOT_DIR/$BINARY"

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
	echo "[setup_godot] this script installs the Linux x86_64 build; this machine is $(uname -s) $(uname -m)" >&2
	exit 2
fi

if [[ -x "$TARGET" ]] && "$TARGET" --headless --version 2>/dev/null | grep -q "^4\.7\.2\.stable"; then
	echo "[setup_godot] already installed: $TARGET ($("$TARGET" --headless --version | head -n1))"
	exit 0
fi

for tool in curl unzip sha512sum; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "[setup_godot] missing tool: $tool (install it first, e.g. apt-get install -y $tool)" >&2
		exit 127
	fi
done

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
echo "[setup_godot] downloading $URL"
curl -fsSL --retry 3 -o "$work/$ARCHIVE" "$URL"
echo "$SHA512  $work/$ARCHIVE" | sha512sum -c - >/dev/null || {
	echo "[setup_godot] SHA512 mismatch for $ARCHIVE; refusing to install" >&2
	exit 1
}
unzip -q -o "$work/$ARCHIVE" -d "$work"
mkdir -p "$GODOT_DIR"
mv -f "$work/$BINARY" "$TARGET"
chmod +x "$TARGET"
echo "[setup_godot] installed $TARGET ($("$TARGET" --headless --version | head -n1))"
if [[ "$TARGET" != "/home/user/tools/godot/$BINARY" ]]; then
	echo "[setup_godot] export GODOT=\"$TARGET\" before running tools/check.sh"
fi
