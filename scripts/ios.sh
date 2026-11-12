#!/usr/bin/env bash
# Build and run the iPhone app in your own iOS Simulator on the build Mac.
#   scripts/ios.sh <slot> <command> [args...]
# Syncs this checkout to ~/agents/openmusic-<slot> (like scripts/mac.sh), then runs scripts/ios-sim.sh there.
# Commands (see scripts/ios-sim.sh):
#   build                      xcodegen + xcodebuild for the slot's simulator
#   run [launch args...]       build, install, launch    e.g.  run -OpenMusicMock YES -OpenMusicScreen album
#   launch [launch args...]    relaunch without building
#   shot <name>                screenshot to build/shots/<name>.png on the build Mac
#   snapshots                  every SnapshotDriver screen in light and dark (mock data) into build/shots/
#   selftest                   live YouTube Music check incl. backgrounding; prints selftest.log
#   perf                       frame timings of the main transitions with sample data; prints perf.log
#   delete                     delete the slot's simulator
# Fetch screenshots:  rsync -az "$OPENMUSIC_MAC_HOST:agents/openmusic-<slot>/build/shots/" <dir>/
set -euo pipefail
source "$(dirname "$0")/env.sh"
slot="${1:?usage: scripts/ios.sh <slot> <command> [args...]}"
shift
cmd="${*:-build}"
exec "$(dirname "$0")/mac.sh" "$slot" "OPENMUSIC_SLOT=$slot OPENMUSIC_CONFIG=${OPENMUSIC_CONFIG:-Debug}${PERF_ONLY:+ PERF_ONLY=$PERF_ONLY} scripts/ios-sim.sh $cmd"
