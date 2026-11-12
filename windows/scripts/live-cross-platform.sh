#!/usr/bin/env bash
# One C# probe device (here) and one Swift probe device (openmusic-probe on the build Mac, built from a checkout of the
# landed accounts branch) in the test user's account on the dev deployment: the key exchange (Swift holds the key and
# allows; C# confirms the code), a fake YouTube Music sign-in sealed by Swift opening in C# and a Spotify one sealed
# by C# opening in Swift, a pull and a push handoff, and remote commands. Appends to the live log.
#   windows/scripts/live-cross-platform.sh <swift checkout> [log]
# OPENMUSIC_USER_FILE names the test user's file (default ~/.config/openmusic/clerk-test-user.json) and OPENMUSIC_REMOTE the build Mac
# directory to build the Swift probe in (default agents/openmusic-winsync).
set -euo pipefail
src="$(cd "${1:?usage: live-cross-platform.sh <swift checkout> [log]}" && pwd)"
log="${2:-${TMPDIR:-/tmp}/openmusic-win-sync-live.log}"
here="$(cd "$(dirname "$0")/.." && pwd)"
. "$here/../scripts/env.sh"
need OPENMUSIC_MAC_HOST
host="$OPENMUSIC_MAC_HOST"
remote="${OPENMUSIC_REMOTE:-agents/openmusic-winsync}"
user=()
[[ -n "${OPENMUSIC_USER_FILE:-}" ]] && user=(--user-file "$OPENMUSIC_USER_FILE")
state="$(mktemp -d /tmp/winsync-cross.XXXXXX)"
chmod 700 "$state"
probe=("$HOME/.dotnet/dotnet" "$here/src/OpenMusic.SyncProbe/bin/Debug/net10.0/OpenMusic.SyncProbe.dll")
swift() { remote_run "$host" "cd ~/${remote} && .build/debug/openmusic-probe sync $* --state ~/${remote}/swift-mac.json --jwt-file jwt.txt --name Swift-Mac" 2>&1; }
note() { echo "[orchestrator $(date -u +%T)] $*" | tee -a "$log"; }

{ echo; echo "=== $(date -u +%FT%TZ) C# + Swift (live-cross-platform.sh), Swift from $(git -C "$src" rev-parse --short HEAD), deployment sensible-barracuda-214 ==="; } >> "$log"
note "syncing the Swift checkout to the build Mac and building openmusic-probe (4 jobs)"
remote_run "$host" "mkdir -p ~/${remote}" >/dev/null
rsync -az --delete --exclude-from="$src/scripts/rsync-excludes.txt" --exclude windows \
  -e "ssh -o BatchMode=yes" "$src/" "${host}:${remote}/"
build_start=$(date +%s)
remote_run "$host" "set -o pipefail; cd ~/${remote} && rm -f swift-mac.json jwt.txt && swift build --jobs 4 --product openmusic-probe 2>&1 | tail -2"
note "openmusic-probe built in $(( $(date +%s) - build_start )) s"

# A fresh Convex JWT for the Swift probe, kept current in a 0600 file on the build Mac.
"${probe[@]}" jwt-file "${user[@]}" --state "$state/jwt" --name jwt --out "$state/jwt.txt" --remote "${host}:${remote}/jwt.txt" --seconds 420 >> "$state/jwt.log" 2>&1 &
pj=$!
sleep 5

# The Swift device holds the key (it is the account's first device) and plays; the C# device asks, confirms the code,
# opens the Swift sign-in, seals its own, pulls, pushes back and sends remote commands. Allow is a one-shot Swift
# command on the running device's state file.
s_script="'signin youtubeMusic secret-from-swift-mac; sleep 75; signins; status'"
remote_run "$host" "cd ~/${remote} && .build/debug/openmusic-probe sync run --play --seconds 100 --script ${s_script} --state ~/${remote}/swift-mac.json --jwt-file jwt.txt --name Swift-Mac" > "$state/swift.log" 2>&1 &
ps=$!
sleep 10
b_script='wait-devices 2; confirm; wait-key; wait-signin youtubeMusic secret-from-swift-mac; signin spotify secret-from-win-pc; wait-playing Swift-Mac; play-here Swift-Mac; sleep 3; status; send Swift-Mac; sleep 2; remote Swift-Mac pause; remote Swift-Mac seek 30; remote Swift-Mac play; sleep 3; status'
"${probe[@]}" run "${user[@]}" --state "$state/b" --name Win-PC --seconds 90 --exit-after-script --script "$b_script" >> "$state/b.log" 2>&1 &
pa=$!
confirmed=0
for attempt in $(seq 1 20); do
  sleep 2
  out="$(swift allow all || true)"
  echo "$out" | tee -a "$log"
  if echo "$out" | grep -q "ALLOWED"; then confirmed=1; break; fi
done
note "Swift allowed the C# device: $confirmed"

ra=0
wait $pa || ra=$?
wait $ps || true
cat "$state/swift.log" >> "$log"
cat "$state/b.log" >> "$log"
note "signing both devices out"
swift sign-out | tee -a "$log" || true
"${probe[@]}" sign-out "${user[@]}" --state "$state/b" --name Win-PC >> "$log" 2>&1 || true
kill $pj 2>/dev/null || true
remote_run "$host" "rm -f ~/${remote}/jwt.txt ~/${remote}/jwt.txt.tmp" >/dev/null || true
echo "=== exit C#=$ra swift-allowed=$confirmed ===" >> "$log"
echo "---- Swift device ----"; cat "$state/swift.log"; echo "---- C# device ----"; cat "$state/b.log"
rm -rf "${state:?}"
exit $(( ra || !confirmed ))
