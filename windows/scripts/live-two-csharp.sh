#!/usr/bin/env bash
# Two C# probe devices in the test user's account on the dev deployment: key exchange (the fake YouTube Music sign-in
# sealed on A opens on B), pull handoff, push handoff, remote commands and a synced setting. Appends to the live log.
#   windows/scripts/live-two-csharp.sh [log]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
log="${1:-$HOME/code/medley-worktrees/win-sync-live.log}"
state="$(mktemp -d /tmp/winsync-live.XXXXXX)"
chmod 700 "$state"
probe=("$HOME/.dotnet/dotnet" "$here/src/Medley.SyncProbe/bin/Debug/net10.0/Medley.SyncProbe.dll")
# MEDLEY_PROBE_USER_FILE picks another test user (its own account), so runs never share an account with other work.
user_args=(); if [[ -n "${MEDLEY_PROBE_USER_FILE:-}" ]]; then user_args=(--user-file "$MEDLEY_PROBE_USER_FILE"); fi
{
  echo
  echo "=== $(date -u +%FT%TZ) two C# devices (live-two-csharp.sh), deployment sensible-barracuda-214 ==="
} >> "$log"
a_script='signin youtubeMusic secret-from-pc-a; wait-devices 2; wait-request; allow all; wait-setting playback.crossfadeSeconds 4; sleep 4; status'
b_script='wait-devices 2; confirm; wait-key; wait-signin youtubeMusic secret-from-pc-a; wait-playing Probe-PC-A; play-here Probe-PC-A; sleep 3; status; send Probe-PC-A; sleep 2; remote Probe-PC-A pause; remote Probe-PC-A seek 42; remote Probe-PC-A play; remote Probe-PC-A volume 0.4; crossfade 4; sleep 3; status'
timeout 200 "${probe[@]}" run "${user_args[@]}" --play --state "$state/a" --name Probe-PC-A --seconds 120 --exit-after-script --script "$a_script" >> "$state/a.log" 2>&1 &
pa=$!
sleep 6
timeout 200 "${probe[@]}" run "${user_args[@]}" --state "$state/b" --name Probe-PC-B --seconds 120 --exit-after-script --script "$b_script" >> "$state/b.log" 2>&1 &
pb=$!
ra=0; rb=0
wait $pa || ra=$?
wait $pb || rb=$?
cat "$state/a.log" "$state/b.log" >> "$log"
# Sign both devices out so the account doesn't fill with probe devices.
"${probe[@]}" sign-out "${user_args[@]}" --state "$state/a" --name Probe-PC-A >> "$log" 2>&1 || true
"${probe[@]}" sign-out "${user_args[@]}" --state "$state/b" --name Probe-PC-B >> "$log" 2>&1 || true
echo "=== exit A=$ra B=$rb ===" >> "$log"
cat "$state/a.log"; echo ----; cat "$state/b.log"
rm -rf "${state:?}"
exit $(( ra || rb ))
