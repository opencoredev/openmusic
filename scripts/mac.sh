#!/usr/bin/env bash
# Sync this checkout to the build Mac (OPENMUSIC_MAC_HOST in scripts/local.env) and run a command there.
#   scripts/mac.sh <slot> '<command>'
# <slot> names your own build directory (~/agents/medley-<slot>) so parallel workers never share one.
# Examples:
#   scripts/mac.sh ytm 'swift build'
#   scripts/mac.sh ytm 'swift test --filter YouTubeMusicKitTests'
#   scripts/mac.sh ytm 'swift run medley-probe ytm search "daft punk"'
#   scripts/mac.sh ui  'scripts/bundle.sh'
set -euo pipefail
slot="${1:?usage: scripts/mac.sh <slot> '<command>'}"
shift
cmd="${1:-swift build}"
root="$(cd "$(dirname "$0")/.." && pwd)"
remote="agents/medley-${slot}"
. "$root/scripts/env.sh"
need OPENMUSIC_MAC_HOST
remote_run "$OPENMUSIC_MAC_HOST" "mkdir -p ~/${remote}" >/dev/null
rsync -az --delete \
  --exclude-from="$root/scripts/rsync-excludes.txt" \
  -e "ssh -o BatchMode=yes" "$root/" "$(remote_prefix "$OPENMUSIC_MAC_HOST")${remote}/"
remote_run "$OPENMUSIC_MAC_HOST" "cd ~/${remote} && ${cmd}"
