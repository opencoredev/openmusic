#!/usr/bin/env bash
# Runs on the build Mac (called by scripts/ios.sh). One simulator per slot, addressed by UDID only.
# Never shuts down, erases or kills other simulators.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
slot="${OPENMUSIC_SLOT:-ios}"
bundle="dev.openmusic.OpenMusicMobile"
udid_file="build/sim-udid"
derived="build/ios-dd"
# OPENMUSIC_CONFIG=Release builds and installs the Release configuration (no self-test code).
config="${OPENMUSIC_CONFIG:-Debug}"
app="$derived/Build/Products/$config-iphonesimulator/OpenMusic.app"
shots="build/shots"
mkdir -p build "$shots"

# Screenshots and the live check exist only in Debug builds (Release ignores their launch arguments).
debug_only() {
  if [[ "$config" != Debug ]]; then
    echo "note: $1 needs a Debug build; building Debug instead of $config" >&2
    config=Debug
    app="$derived/Build/Products/$config-iphonesimulator/OpenMusic.app"
  fi
}

sim() {
  if [[ -s "$udid_file" ]] && xcrun simctl list devices | grep -q "$(cat "$udid_file")"; then
    cat "$udid_file"; return
  fi
  xcrun simctl create "agent-openmusic-$slot" "iPhone 17 Pro" > "$udid_file"
  cat "$udid_file"
}

boot() {
  local u; u="$(sim)"
  xcrun simctl bootstatus "$u" -b >/dev/null 2>&1 || true
  # Clean, fixed status bar for screenshots.
  xcrun simctl status_bar "$u" override --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
  echo "$u"
}

build() {
  local u; u="$(sim)"
  /opt/homebrew/bin/xcodegen generate --spec iOS/project.yml --quiet
  set +e
  xcodebuild -project iOS/OpenMusic.xcodeproj -scheme OpenMusic -configuration "$config" \
    -destination "id=$u" -derivedDataPath "$derived" build > build/ios-build.log 2>&1
  local status=$?
  set -e
  grep -E "error:|warning: .*iOS/OpenMusic|\*\* BUILD" build/ios-build.log | sort -u | head -80
  return $status
}

install() {
  local u; u="$(boot)"
  xcrun simctl install "$u" "$app"
}

launch() {
  local u; u="$(boot)"
  xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$u" "$bundle" "$@"
}

shot() {
  local u; u="$(sim)"
  xcrun simctl io "$u" screenshot --type=png "$shots/$1.png" >/dev/null 2>&1
  echo "$shots/$1.png"
}

snapshots() {
  local u; u="$(boot)"
  install
  local screens="${SCREENS:-home new library library-liked library-signedout search search-recent search-empty album artist playlist shelf error nowplaying lyrics queue settings welcome welcome-signin account-signedout account-comparing account-allowed account-outdated account allow-device}"
  for appearance in ${APPEARANCES:-light dark}; do
    xcrun simctl ui "$u" appearance "$appearance"
    for s in $screens; do
      if [[ "$s" == "library-signedout" ]]; then
        launch -OpenMusicMock YES -OpenMusicScreen "$s" -OpenMusicSignedOut YES >/dev/null
      else
        launch -OpenMusicMock YES -OpenMusicScreen "$s" >/dev/null
      fi
      sleep "${SNAP_WAIT:-4}"
      shot "$s-$appearance"
    done
  done
  xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1 || true
  ls "$shots"
}

selftest() {
  local u; u="$(boot)"
  install
  xcrun simctl ui "$u" appearance dark
  launch -OpenMusicSelfTest live >/dev/null
  local data log
  data="$(xcrun simctl get_app_container "$u" "$bundle" data)"
  log="$data/Documents/selftest.log"
  for _ in $(seq 1 90); do
    sleep 2
    if [[ -f "$log" ]] && grep -q "screen lyrics-open\|FAIL error" "$log"; then break; fi
  done
  sleep 3
  shot "live-lyrics"
  # Background the app: open Settings, wait, come back.
  echo "-- backgrounding at $(date +%T)"
  xcrun simctl launch "$u" com.apple.Preferences >/dev/null
  sleep 14
  shot "live-backgrounded"
  echo "-- foregrounding at $(date +%T)"
  xcrun simctl launch "$u" "$bundle" >/dev/null
  sleep 4
  shot "live-after-background"
  for _ in $(seq 1 45); do
    grep -q "^done" "$log" 2>/dev/null && break
    sleep 2
  done
  cat "$log"
}

# Frame timings for the main transitions with sample data (PerfSelfTest); prints perf.log.
# PERF_ONLY=lyrics-open,queue-open runs only those scenarios.
perf() {
  local u; u="$(boot)"
  install
  xcrun simctl ui "$u" appearance dark
  launch -OpenMusicMock YES -OpenMusicSelfTest perf ${PERF_ONLY:+-OpenMusicPerfOnly "$PERF_ONLY"} >/dev/null
  local data log
  data="$(xcrun simctl get_app_container "$u" "$bundle" data)"
  log="$data/Documents/perf.log"
  for _ in $(seq 1 150); do
    sleep 2
    grep -q "^done\|^FAIL" "$log" 2>/dev/null && break
  done
  xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1 || true
  cp "$log" build/perf.log 2>/dev/null || true
  cat "$log"
}

case "${1:-build}" in
  udid) sim ;;
  build) build ;;
  install) install ;;
  run) shift; build && install && launch "$@" ;;
  launch) shift; launch "$@" ;;
  shot) shot "${2:?name}" ;;
  appearance) xcrun simctl ui "$(sim)" appearance "${2:?light|dark}" ;;
  snapshots) debug_only snapshots; build && snapshots ;;
  selftest) debug_only selftest; build && selftest ;;
  perf) debug_only perf; build && perf ;;
  perf-only) debug_only perf; perf ;;
  delete)
    if [[ -s build/sim-udid ]]; then
      xcrun simctl shutdown "$(cat build/sim-udid)" >/dev/null 2>&1 || true
      xcrun simctl delete "$(cat build/sim-udid)"
      rm -f build/sim-udid
    fi ;;
  *) echo "unknown command: $1" >&2; exit 2 ;;
esac
