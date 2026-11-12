#!/usr/bin/env bash
# The iPhone screens design review looks at: every main screen with the demo data (real chart
# albums and covers, a made-up signed-in listener, "the cure" playing), light and dark on an iPhone 17 Pro, plus a
# layout subset on a small iPhone (SE 3rd generation, or 16e where the runtime has no SE).
#   scripts/ios-council-shots.sh <out-dir>      from the Linux checkout: sync, capture on the build Mac, pull PNGs
#   scripts/ios-council-shots.sh --remote         on the build Mac (called by the line above)
# Most screens are a launch with -OpenMusicScreen <name> (iOS/OpenMusic/App/SnapshotDriver.swift) and `simctl io
# screenshot`. The ones that need a finger (a long press, typing, a drag, the route picker) are UI tests in
# iOS/ScreenshotUITests. One simulator at a time, created for this run and deleted after it, even on failure. The
# capture holds /tmp/medley-ui.lock so it never overlaps other workers' frame-timing runs on the shared build Mac.
#   COUNCIL_DEVICES="pro se"        which devices (default both)
#   COUNCIL_SCREENS="home album"    only these simctl screens
#   COUNCIL_TESTS="testContextMenu" only these UI tests ("none" for none; "AppleMusic/testAppleMusic" captures
#                                   Apple's Music app as the reference, applemusic-*.png)
set -euo pipefail
cd "$(dirname "$0")/.."
slot=council-ios

if [[ "${1:-}" != --remote && "${1:-}" != --capture ]]; then
  . scripts/env.sh
  need OPENMUSIC_MAC_HOST
  mini="$OPENMUSIC_MAC_HOST"
  dest="${1:?usage: scripts/ios-council-shots.sh <out-dir>}"
  mkdir -p "$dest"
  rev=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
  dirty=""
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then dirty="+uncommitted"; fi
  scripts/mac.sh "$slot" "COUNCIL_DEVICES='${COUNCIL_DEVICES:-}' COUNCIL_SCREENS='${COUNCIL_SCREENS:-}' COUNCIL_TESTS='${COUNCIL_TESTS:-}' scripts/ios-council-shots.sh --remote"
  rsync -az --delete -e "ssh -o BatchMode=yes" "$mini:agents/openmusic-$slot/build/ios-council/shots/" "$dest/shots/"
  rsync -az -e "ssh -o BatchMode=yes" "$mini:agents/openmusic-$slot/build/ios-council/capture.log" "$dest/" || true
  echo "$rev$dirty" > "$dest/revision.txt"
  echo "pulled $(ls "$dest/shots" | wc -l) images to $dest/shots ($rev$dirty)"
  exit 0
fi

root="$PWD"
out="$root/build/ios-council"
shots="$out/shots"
art="$root/build/demo-art"
derived="$root/build/ios-council-dd"
bundle=dev.openmusic.OpenMusicMobile
app="$derived/Build/Products/Debug-iphonesimulator/OpenMusic.app"
pro_screens="home new library library-songs library-albums library-artists library-playlist search-recent search search-empty album artist nowplaying lyrics queue settings"
se_screens="home library-songs search album artist nowplaying lyrics queue"
tests="testHomeScrolled testContextMenu testSearchSuggestions testQueueDrag"

if [[ "$1" == --remote ]]; then
  start=$(date +%s)
  rm -rf "${out:?}"
  mkdir -p "$shots"
  scripts/demo-art.sh "$art" >/dev/null
  /opt/homebrew/bin/xcodegen generate --spec iOS/project.yml --quiet
  if ! xcodebuild build-for-testing -project iOS/OpenMusic.xcodeproj -scheme OpenMusic -configuration Debug \
      -destination "generic/platform=iOS Simulator" -derivedDataPath "$derived" > "$out/build.log" 2>&1; then
    grep -E "error:" "$out/build.log" | sort -u | head -40
    echo "build failed" >&2
    exit 1
  fi
  echo "built in $(( $(date +%s) - start )) s; waiting for /tmp/medley-ui.lock"
  lockf -t 1800 /tmp/medley-ui.lock "$0" --capture
  echo "done in $(( $(date +%s) - start )) s: $(ls "$shots" | wc -l | tr -d ' ') images"
  exit 0
fi

# --capture: runs under the lock.
udid=""
cleanup() {
  if [[ -n "$udid" ]]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    udid=""
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
log="$out/capture.log"
: > "$log"

device_type() {
  case "$1" in
    pro) echo "iPhone 17 Pro" ;;
    se)
      local probe
      if probe="$(xcrun simctl create agent-openmusic-council-probe "iPhone SE (3rd generation)" 2>/dev/null)"; then
        xcrun simctl delete "$probe" >/dev/null 2>&1 || true
        echo "iPhone SE (3rd generation)"
      else
        echo "iPhone 16e"
      fi ;;
  esac
}

ui_test() { # <test name> <file suffix>
  local name="$1" suffix="$2" status=0 marker="$shots/.dragging" id="CouncilShots/$1"
  # AppleMusic/<test> names a test in AppleMusicReference (the reference captures).
  [[ "$name" == AppleMusic/* ]] && id="AppleMusicReference/${name#AppleMusic/}" && name="${name#AppleMusic/}"
  rm -f "${marker:?}"
  if [[ "$name" == testQueueDrag ]]; then
    (
      for _ in $(seq 1 160); do [[ -f "$marker" ]] && break; sleep 0.25; done
      sleep 2.6
      xcrun simctl io "$udid" screenshot --type=png "$shots/queue-drag$suffix.png" >/dev/null 2>&1
    ) &
  fi
  timeout 240 env TEST_RUNNER_COUNCIL_OUT="$shots" TEST_RUNNER_COUNCIL_SUFFIX="$suffix" TEST_RUNNER_COUNCIL_ART="$art" \
    xcodebuild test-without-building -project iOS/OpenMusic.xcodeproj -scheme OpenMusic -destination "id=$udid" \
    -derivedDataPath "$derived" -only-testing:"ScreenshotUITests/$id" > "$out/test-$name$suffix.log" 2>&1 || status=$?
  wait 2>/dev/null || true
  rm -f "${marker:?}"
  echo "ui $name$suffix: exit $status" >> "$log"
}

for dev in ${COUNCIL_DEVICES:-pro se}; do
  type="$(device_type "$dev")"
  udid="$(xcrun simctl create "agent-openmusic-council-$dev" "$type")"
  echo "$dev: $type $udid" >> "$log"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState discharging --batteryLevel 100 >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$app"
  suffix_dev=""
  appearances="light dark"
  screens="${COUNCIL_SCREENS:-$pro_screens}"
  if [[ "$dev" == se ]]; then
    suffix_dev="-se"
    appearances="light"
    [[ -z "${COUNCIL_SCREENS:-}" ]] && screens="$se_screens"
  fi
  for appearance in $appearances; do
    xcrun simctl ui "$udid" appearance "$appearance"
    sleep 3
    for screen in $screens; do
      xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
      xcrun simctl launch "$udid" "$bundle" -OpenMusicMock demo -OpenMusicDemoArt "$art" -OpenMusicScreen "$screen" >/dev/null
      sleep "${SNAP_WAIT:-5}"
      if xcrun simctl io "$udid" screenshot --type=png "$shots/$screen-$appearance$suffix_dev.png" >/dev/null 2>&1; then
        echo "shot $screen-$appearance$suffix_dev" >> "$log"
      else
        echo "FAILED $screen-$appearance$suffix_dev" >> "$log"
      fi
    done
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    if [[ "$dev" == pro && "${COUNCIL_TESTS:-}" != none ]]; then
      for t in ${COUNCIL_TESTS:-$tests}; do ui_test "$t" "-$appearance"; done
    fi
  done
  cleanup
done
cat "$log"
