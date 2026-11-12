#!/usr/bin/env bash
# Checks that a Release build of the Mac app carries no test hooks: no OPENMUSIC_SELFTEST self-test types except the
# sidebar benchmarks `sidebar` and `sidebarscroll` (which Release builds keep on purpose, see AGENTS.md "Mac app: frame timing"), no sync self-test,
# no fake test sign-ins and no snapshot runner (`OPENMUSIC_SNAPSHOT_DIR` walks the app, runs interaction and live checks,
# writes files and quits; snapshot scripts build Debug). Runs on macOS after `scripts/bundle.sh` (release).
#   scripts/check-release-hooks.sh [path to the OpenMusic binary]
set -euo pipefail
cd "$(dirname "$0")/.."
binary="${1:-build/OpenMusic.app/Contents/MacOS/OpenMusic}"
[ -f "$binary" ] || { echo "no binary at $binary; run scripts/bundle.sh first" >&2; exit 2; }

# Swift keeps type names in its metadata, so a self-test type compiled into the binary shows up by name.
absent=(FullScreenSelfTest InspectorSelfTest InspectorWidthSelfTest ResizeSelfTest FindSelfTest MenuSelfTest
        LaunchSelfTest HoverSelfTest LayoutSelfTest LyricsSelfTest TourSelfTest SyncSelfTest CouncilShots
        MEDLEY_TEST_SIGNIN medley-test-signin SnapshotRunner OPENMUSIC_SNAPSHOT_DIR OPENMUSIC_SNAPSHOT_ONLY)
present=(SidebarSelfTest SidebarScrollSelfTest)

status=0
for name in "${absent[@]}"; do
  if grep -aqF "$name" "$binary"; then echo "FAIL: $name is in the release binary"; status=1; else echo "ok: no $name"; fi
done
for name in "${present[@]}"; do
  if grep -aqF "$name" "$binary"; then echo "ok: $name kept (Release benchmark)"; else echo "FAIL: $name is missing"; status=1; fi
done
exit "$status"
