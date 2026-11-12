#!/usr/bin/env bash
# Hill-climb check for sidebar smoothness. Runs on the build Mac; from the Linux checkout:
#   scripts/mac.sh climb 'scripts/sidebar-bench.sh'
# Builds the release app, waits for the shared build Mac to be quiet, runs the `sidebarscroll` self-test
# (SidebarScrollSelfTest.swift: 32 sidebar hides/shows on scrolled pages, half of them while the page scrolls)
# and prints its last line, `SCORE <dropped frames>`. Exits non-zero, with no SCORE line, if anything fails.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/sidebar-bench
out="$PWD/build/sidebar-bench"
scripts/bundle.sh > "$out/bundle.log" 2>&1 || { tail -20 "$out/bundle.log"; echo "bundle failed"; exit 1; }


# The test moves the window and the sidebar of the shared dev.openmusic.OpenMusic defaults: put them back after.
defaults export dev.openmusic.OpenMusic "$out/defaults-backup.plist" 2>/dev/null || true
restore() {
  pkill -f "$PWD/build/OpenMusic.app/Contents/MacOS/OpenMusic" 2>/dev/null || true
  if [[ -s "$out/defaults-backup.plist" ]]; then
    defaults delete dev.openmusic.OpenMusic >/dev/null 2>&1 || true
    defaults import dev.openmusic.OpenMusic "$out/defaults-backup.plist"
  fi
}
trap restore EXIT

result="$out/result.txt"
rm -f "${result:?}"
# The build Mac is shared: frame timings are noise while anything else builds or runs. Inside the lock (so no other
# app run starts meanwhile), wait up to 10 minutes until no compiler, test or Xcode build runs and the 1-minute
# load is under 3, then run the test.
quiet_run() {
  for _ in $(seq 1 120); do
    load="$(sysctl -n vm.loadavg | awk '{print $2}')"
    if ! pgrep -q -f 'swift-frontend|swift-build|swift-test|xcodebuild|xctest|swiftc' \
       && awk -v l="$load" 'BEGIN { exit !(l < 3) }'; then break; fi
    sleep 5
  done
  echo "load $(sysctl -n vm.loadavg)"
  timeout 240 open -W -n --env OPENMUSIC_MOCK=1 --env OPENMUSIC_SELFTEST=sidebarscroll --env OPENMUSIC_SELFTEST_OUT="$result" build/OpenMusic.app || true
}
export -f quiet_run
export result
lockf -t 1800 /tmp/medley-ui.lock bash -c quiet_run
[[ -f "$result" ]] || { echo "self-test wrote nothing"; exit 1; }
grep -v '^SCORE' "$result" | grep -E 'dropped [0-9]+,|refresh|FAIL|main-thread cpu' || true
grep -q '^SCORE [0-9]' "$result" || { echo "no score"; exit 1; }
grep '^SCORE' "$result" | tail -1
