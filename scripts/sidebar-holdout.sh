#!/usr/bin/env bash
# Hill-climb holdout for sidebar smoothness: the older `sidebar` self-test (SidebarSelfTest.swift), which the climb
# never scores against: 30 hides/shows at the top of Home, New, an album, an artist and Songs. From the Linux checkout:
#   scripts/mac.sh climb-holdout 'scripts/sidebar-holdout.sh'
# Prints `SCORE <dropped frames total>`. Exits non-zero, with no SCORE line, if anything fails.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/sidebar-holdout
out="$PWD/build/sidebar-holdout"
scripts/bundle.sh > "$out/bundle.log" 2>&1 || { tail -20 "$out/bundle.log"; echo "bundle failed"; exit 1; }

# The build Mac is shared: frame timings are noise while another build runs. Wait up to 5 minutes for a quiet machine.
for _ in $(seq 1 60); do
  load="$(sysctl -n vm.loadavg | awk '{print $2}')"
  awk -v l="$load" 'BEGIN { exit !(l < 4) }' && break
  sleep 5
done
echo "load $(sysctl -n vm.loadavg)"

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
lockf -t 1800 /tmp/medley-ui.lock timeout 240 open -W -n --env OPENMUSIC_MOCK=1 --env OPENMUSIC_SELFTEST=sidebar --env OPENMUSIC_SELFTEST_OUT="$result" build/OpenMusic.app || true
[[ -f "$result" ]] || { echo "self-test wrote nothing"; exit 1; }
grep -E '^(page|summary)' "$result" || true
total="$(sed -n 's/^summary: 30 toggles.*dropped frames total \([0-9][0-9]*\).*/\1/p' "$result" | tail -1)"
[[ -n "$total" ]] || { echo "no score"; exit 1; }
echo "SCORE $total"
echo "$total"
