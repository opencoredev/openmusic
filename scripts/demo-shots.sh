#!/usr/bin/env bash
# The screenshots for posting: real chart albums and covers, a made-up signed-in listener, "the cure" playing.
# Runs on the build Mac. From the Linux checkout:
#   scripts/mac.sh shots 'scripts/demo-shots.sh'            # everything: mac, ios, compose
#   scripts/mac.sh shots 'scripts/demo-shots.sh mac'        # or one step: mac | ios | compose
#   rsync -az "$OPENMUSIC_MAC_HOST:agents/openmusic-shots/build/demo-shots/final/" <dir>/
# Output: build/demo-shots/raw (captures) and build/demo-shots/final (the images to post).
#
# mac      Debug bundle with OPENMUSIC_MOCK=demo. Starts a temporary 2x virtual display the size of the current
#          screen in points (scripts/virtual-display.m), so the window is captured at Retina density, and stops
#          it when the captures are done.
# ios      Its own iPhone 17 Pro Max simulator (agent-openmusic-demo-<slot>), status bar 9:41 / full battery (no charging bolt) /
#          full signal, -OpenMusicMock demo, one launch per screen and appearance. The simulator is deleted after.
# compose  Hero images (1600x900 and 1080x1080) and framed single shots (scripts/demo-compose.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
root="$PWD"
out="$root/build/demo-shots"
art="$root/build/demo-art"
raw="$out/raw"
mkdir -p "$raw" "$out/final"

# One cleanup for every exit path (a failed command under `set -e`, Ctrl-C, a kill): stop the virtual display and
# this run's app, put back the real app's preferences and saved window state, and delete the demo simulator.
vd="" udid="" defaults_backup="$out/defaults-backup.plist" saved_state="$HOME/Library/Saved Application State/dev.openmusic.OpenMusic.savedState"
app_bin="$root/build/OpenMusic.app/Contents/MacOS/OpenMusic"
cleanup() {
  [[ -n "$vd" ]] && { kill "$vd" 2>/dev/null || true; wait "$vd" 2>/dev/null || true; vd=""; }
  pkill -f "$app_bin" 2>/dev/null || true
  if [[ -f "$out/.defaults-saved" ]]; then
    defaults delete dev.openmusic.OpenMusic >/dev/null 2>&1 || true
    [[ -s "$defaults_backup" ]] && defaults import dev.openmusic.OpenMusic "$defaults_backup"
    rm -rf "${saved_state:?}"
    [[ -d "$out/saved-state-backup" ]] && ditto "$out/saved-state-backup" "$saved_state"
    rm -rf "${out:?}/saved-state-backup" "${out:?}/.defaults-saved"
  fi
  [[ -n "$udid" ]] && { xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid" >/dev/null 2>&1 || true; udid=""; }
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mac_shots() {
  scripts/demo-art.sh "$art"
  CONFIG=debug scripts/bundle.sh >/dev/null
  clang -fobjc-arc -framework Foundation -framework CoreGraphics scripts/virtual-display.m -o build/virtual-display
  # Same size in points as the screen now, so other windows on this shared Mac keep their layout.
  local w h status=0
  read -r w h < <(osascript -l JavaScript -e 'ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.frame; Math.round(f.size.width) + " " + Math.round(f.size.height)' 2>/dev/null || echo "1920 1080")
  # The capture moves and resizes the app's window: keep the real app's preferences and window state to restore after.
  rm -f "${defaults_backup:?}"; rm -rf "${out:?}/saved-state-backup"
  defaults export dev.openmusic.OpenMusic "$defaults_backup" 2>/dev/null || true
  [[ -d "$saved_state" ]] && ditto "$saved_state" "$out/saved-state-backup"
  touch "$out/.defaults-saved"
  build/virtual-display "${w:-1920}" "${h:-1080}" 300 &
  vd=$!
  sleep 3
  rm -f "${raw:?}"/mac-*.png
  # Through `open`, so the app starts in the GUI session as the frontmost app and its window is key.
  timeout 240 open -W -n --env OPENMUSIC_MOCK=demo --env OPENMUSIC_DEMO_ART="$art" --env OPENMUSIC_SNAPSHOT_DIR="$raw" \
    --env OPENMUSIC_SNAPSHOT_ONLY=demo --env OPENMUSIC_DEMO_SIZE="${OPENMUSIC_DEMO_SIZE:-1440x900}" \
    ${OPENMUSIC_DEMO_SHOTS:+--env OPENMUSIC_DEMO_SHOTS="$OPENMUSIC_DEMO_SHOTS"} build/OpenMusic.app || status=$?
  cleanup
  if [[ "${status:-0}" -eq 124 ]]; then echo "mac captures timed out after 240 s" >&2; return 1; fi
  [[ -f "$raw/demo.txt" ]] || { echo "mac captures wrote no log" >&2; return 1; }
  cat "$raw/demo.txt"
  compgen -G "$raw/mac-*.png" >/dev/null || { echo "mac captures wrote no images" >&2; return 1; }
}

ios_shots() {
  scripts/demo-art.sh "$art"
  local slot="${OPENMUSIC_SLOT:-shots}" bundle="dev.openmusic.OpenMusicMobile" derived="build/ios-dd"
  udid="$(xcrun simctl create "agent-openmusic-demo-$slot" "${OPENMUSIC_DEMO_DEVICE:-iPhone 17 Pro Max}")"
  /opt/homebrew/bin/xcodegen generate --spec iOS/project.yml --quiet
  xcodebuild -project iOS/OpenMusic.xcodeproj -scheme OpenMusic -configuration Debug \
    -destination "id=$udid" -derivedDataPath "$derived" build > build/ios-demo-build.log 2>&1 || { grep -E "error:" build/ios-demo-build.log | head -20; return 1; }
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState discharging --batteryLevel 100
  xcrun simctl install "$udid" "$derived/Build/Products/Debug-iphonesimulator/OpenMusic.app"
  # The app reads the covers from the host path (Simulator apps can read the Mac's files).
  local screens="${DEMO_SCREENS:-nowplaying lyrics home library album}" screen
  for screen in $screens; do rm -f "${raw:?}"/ios-"$screen"-*.png; done
  for appearance in light dark; do
    xcrun simctl ui "$udid" appearance "$appearance"
    sleep 3  # let the switch settle, or the first capture can catch a transient Dynamic Island
    for screen in $screens; do
      xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
      xcrun simctl launch "$udid" "$bundle" -OpenMusicMock demo -OpenMusicDemoArt "$art" -OpenMusicScreen "$screen" >/dev/null
      sleep "${SNAP_WAIT:-5}"
      xcrun simctl io "$udid" screenshot --type=png "$raw/ios-$screen-$appearance.png" >/dev/null
      echo "ios-$screen-$appearance.png"
    done
  done
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  cleanup
}

compose() {
  swiftc -O scripts/demo-compose.swift -o build/demo-compose 2>&1 | grep -v "^$" || true
  build/demo-compose "$raw" "$out/final" "$art"
}

case "${1:-all}" in
  mac) mac_shots ;;
  ios) ios_shots ;;
  compose) compose ;;
  all) mac_shots; ios_shots; compose ;;
  *) echo "usage: scripts/demo-shots.sh [mac|ios|compose|all]" >&2; exit 2 ;;
esac
