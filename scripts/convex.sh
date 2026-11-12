#!/usr/bin/env bash
# Run a Convex CLI command for sync/ on the machine where the Convex CLI is logged in (OPENMUSIC_CONVEX_HOST in
# scripts/local.env; "local" for this one).
#   scripts/convex.sh [<slot>] '<command>'
# Syncs sync/ to ~/agents/openmusic-sync there (Convex project `openmusic`; its .env.local points `npx convex dev` at
# the dev deployment sensible-barracuda-214), installs packages and runs the command there. Every deploy goes from
# that one folder. The optional <slot> is accepted for older call sites and ignored.
# Examples:
#   scripts/convex.sh 'npx convex dev --once'          # push functions to the dev deployment
#   scripts/convex.sh 'npx convex deploy -y'           # production (insightful-roadrunner-835), after dev passed
#   scripts/convex.sh 'npx convex run devices:list ...'
#   scripts/convex.sh 'npx tsc -p convex --noEmit && npx vitest run'
set -euo pipefail
[[ $# -ge 2 ]] && shift
cmd="${1:-npx convex dev --once}"
root="$(cd "$(dirname "$0")/.." && pwd)"
remote="agents/openmusic-sync"
. "$root/scripts/env.sh"
need OPENMUSIC_CONVEX_HOST
host="$OPENMUSIC_CONVEX_HOST"
remote_run "$host" "test -f ~/${remote}/.env.local" >/dev/null || { echo "~/${remote}/.env.local is missing on $host" >&2; exit 2; }
rsync -az --exclude-from="$root/scripts/rsync-excludes.txt" -e "ssh -o BatchMode=yes" "$root/sync/" "$(remote_prefix "$host")${remote}/"
remote_run "$host" "cd ~/${remote} && (test -d node_modules || npm ci --silent) && ${cmd}"
