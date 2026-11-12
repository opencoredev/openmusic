#!/usr/bin/env bash
# Build OpenMusic.app on the build Mac (OPENMUSIC_MAC_HOST) and install it in /Applications on another Mac
# (OPENMUSIC_DEVICE_HOST). Both come from scripts/local.env.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/env.sh
need OPENMUSIC_MAC_HOST OPENMUSIC_DEVICE_HOST
scripts/mac.sh main 'scripts/bundle.sh 2>&1 | grep -E "error:|built" && cd build && rm -f OpenMusic.zip && ditto -c -k --keepParent OpenMusic.app OpenMusic.zip'
T=$(mktemp -d)
trap 'rm -rf -- "${T:?}"' EXIT
scp -q "${OPENMUSIC_SSH_OPTS[@]}" "$(remote_prefix "$OPENMUSIC_MAC_HOST")agents/medley-main/build/OpenMusic.zip" "$T/OpenMusic.zip"
remote_run "$OPENMUSIC_DEVICE_HOST" 'mkdir -p ~/agents/medley' >/dev/null 2>&1
scp -q "${OPENMUSIC_SSH_OPTS[@]}" "$T/OpenMusic.zip" "$(remote_prefix "$OPENMUSIC_DEVICE_HOST")agents/medley/"
remote_run "$OPENMUSIC_DEVICE_HOST" 'cd ~/agents/medley && (osascript -e "quit app \"OpenMusic\"" 2>/dev/null || true); sleep 1; pkill -x OpenMusic || true; ditto -x -k OpenMusic.zip . && rm -rf /Applications/OpenMusic.app && mv OpenMusic.app /Applications/ && codesign --verify --deep /Applications/OpenMusic.app && echo installed && cd ~ && rm -rf ~/agents/medley' 2>&1 | grep -v cargo
