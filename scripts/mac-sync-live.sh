#!/usr/bin/env bash
# Live check of OpenMusic Sync in the Mac app against a `openmusic-probe sync` device, on the build Mac.
#   scripts/mac.sh <slot> 'scripts/mac-sync-live.sh'
# Builds a debug OpenMusic.app (the sync self-test exists only in debug builds) and the probe, then drives the app with
# openmusic://… lines in its command file (see Sources/OpenMusic/Sync/SyncSelfTest.swift). The probe ("Probe iPhone")
# plays a real YouTube Music queue on its silent engine.
# Checks: consent before pairing by link, banner, pull handoff, push, remote control, settings and recent searches,
# a test sign-in from the probe, sign-out here vs everywhere, typed-code pairing without the key, then the key link.
# The app keeps its sync token in a file here (-OpenMusicSyncState), and, being a self-test run, every other Keychain
# account (YouTube Music and Spotify sign-ins too) in files under build/mac-sync-live/keychain: it never restores,
# overwrites, deletes or uploads the Mac's real sign-ins. The run checks the login Keychain's OpenMusic items are
# unchanged afterwards (scripts/keychain-snapshot.sh: attributes only, never the stored data).
# Logs: build/mac-sync-live/; screenshots (light and dark): build/mac-sync-live/shots/.
set -euo pipefail
# Accounts replaced invite pairing (docs/accounts-design.md). This script still drives create/invite/join, which no
# longer exist; it needs a rework around sign-in with a Clerk test user's JWT (openmusic-probe sync sign-in --jwt-file,
# the apps' -OpenMusicSyncJWTFile) before it can run again.
echo "$(basename "$0"): not updated for accounts yet; see docs/accounts-design.md (Testing)." >&2
exit 2
cd "$(dirname "$0")/.."
out="$PWD/build/mac-sync-live"
rm -rf "$out"; mkdir -p "$out/shots"
P=.build/debug/openmusic-probe
swift build --product openmusic-probe 2>&1 | tail -1
CONFIG=debug scripts/bundle.sh | tail -1
app="$PWD/build/OpenMusic.app"
exe="$app/Contents/MacOS/OpenMusic"

say() { echo "-- $(date +%T) $*"; }
send_url() { echo "$1" >> "$out/synctest-cmd.txt"; }
cmd() { send_url "openmusic://test/$1"; }
wait_log() { # wait_log PATTERN SECONDS
  for _ in $(seq 1 "${2:-20}"); do grep -q "$1" "$out/synctest.log" 2>/dev/null && return 0; sleep 1; done
  echo "!! timed out waiting for: $1"; return 1
}
shot() { # shot NAME WINDOW: light and dark
  for a in light dark; do
    cmd "appearance?mode=$a"; sleep 1.4
    cmd "shot?name=$1-$a&w=${2:-main}"; sleep 0.8
  done
  cmd "appearance?mode=light"
}
screen() { cmd "screen?name=$1"; sleep "${2:-2.5}"; }
quit_app() { pkill -TERM -f "$exe" 2>/dev/null || true; sleep 2; }
# The app shares its preferences domain with every OpenMusic build on this Mac; the run changes crossfade, autoplay and
# recent searches through sync, so put them back afterwards.
defaults export dev.openmusic.OpenMusic "$out/defaults-backup.plist" 2>/dev/null || true
restore() { quit_app; [[ -s "$out/defaults-backup.plist" ]] && defaults import dev.openmusic.OpenMusic "$out/defaults-backup.plist"; }
trap restore EXIT
scripts/keychain-snapshot.sh > "$out/keychain-before.txt"

quit_app
say "probe: new library"
$P sync create-library --name "Probe iPhone" --state "$out/probe.json" | tee "$out/probe-setup.log"
link="$($P sync invite --state "$out/probe.json" | tee -a "$out/probe-setup.log" | sed -n 's/.* link \(openmusic:.*\)$/\1/p')"
[[ -n "$link" ]] || { echo "no invite link"; exit 1; }

say "app: launch unpaired"
open -n -F "$app" --args -didOnboard YES -OpenMusicSyncSelfTest YES -OpenMusicSyncDir "$out" -OpenMusicSyncState "$out/mac-state.json" \
  -OpenMusicSyncDeviceName "Test Mac"
wait_log "STARTED" 40
sleep 4
cmd status; sleep 1
grep -q "connection=idle\|connection=stopped" "$out/synctest.log" && echo "ok: unpaired Mac has no connection" || echo "!! unpaired Mac connected"
grep -q "STARTED .* keychain=file $out/keychain" "$out/synctest.log" && echo "ok: sign-ins kept in the run's own files, not the Keychain" || echo "!! the app uses the real Keychain"
grep -q "sign-in youtubeMusic: signed out" "$out/synctest.log" && grep -q "sign-in spotify: signed out" "$out/synctest.log" \
  && echo "ok: no real sign-in restored at launch" || echo "!! a sign-in was restored at launch"
grep -q "spotify refresh recovery from the vault: wired" "$out/synctest.log" && echo "ok: Spotify refresh recovery reads the vault" || echo "!! Spotify refresh recovery not wired"
screen sync; shot settings-sync-unpaired settings
screen join; shot settings-join-sheet sheet
screen devices; shot devices-unpaired popover
screen close

say "app: open the pairing link (must ask first)"
send_url "$link"
wait_log "asking to confirm" 10
wait_log "INVITE preview" 10
sleep 1.5
grep -q "PAIRED" "$out/synctest.log" && echo "!! paired without consent" || echo "ok: not paired before consent"
grep -q "INVITE preview: Probe iPhone (mac) invited this Mac; 1 device" "$out/synctest.log" && echo "ok: consent names the inviting device" || echo "!! consent preview missing"
shot link-consent sheet
cmd confirm
wait_log "PAIRED" 20
sleep 2

# The probe's second sign-in: another (fake) account in the transfer's format, so it is a new vault write the Mac
# must ignore after signing out here. Same test marker cookie as YouTubeMusicSignInTransfer.testPayload.
second='{"account":{"detail":"Test sign-in","name":"Probe-Second-Account"},"credentials":{"authUser":0,"cookies":{"MEDLEY_TEST_SIGNIN":"1","SAPISID":"openmusic-test-2","SID":"openmusic-test-2"}},"version":1}'
say "probe: play Discovery from 40 s; settings, searches and test sign-ins later"
$P sync fake-play --name "Probe iPhone" --state "$out/probe.json" --ytm "daft punk discovery" --start-at 40 --seconds 340 \
  --script "sleep 70; crossfade 6; autoplay off; searches Daft Punk,Justice; sleep 6; signin-test youtubeMusic; sleep 205; signin youtubeMusic $second; sleep 15; signout youtubeMusic everywhere; sleep 15" \
  > "$out/probe.log" 2>&1 &
probe=$!
wait_log "BANNER Continue from" 20
sleep 2
shot banner main

say "app: Play Here on the banner"
cmd playhere
wait_log "PULL done\|PULL failed" 30
sleep 5
shot playing-here main
cmd status; sleep 1

say "app: Devices popover, push back to the probe, remote control"
screen devices 3
shot devices main
shot devices-popover popover
cmd "send?to=Probe%20iPhone"
wait_log "PUSH done\|PUSH failed" 30
sleep 3
screen devices 3
shot devices-after-push popover
cmd "remote?to=Probe%20iPhone&do=toggle"; sleep 3
cmd "remote?to=Probe%20iPhone&do=toggle"; sleep 3
cmd "remote?to=Probe%20iPhone&do=next"; sleep 4
cmd "remote?to=Probe%20iPhone&do=seek&v=95"; sleep 4
screen devices 3
shot devices-remote popover
cmd status; sleep 1
screen close

say "dismiss the Continue banner: it stays hidden while the probe plays on (it republishes every 20 s)"
cmd status; sleep 1
if tail -3 "$out/synctest.log" | grep -q "playerBanner Continue from"; then
  cmd dismiss; sleep 1
  mark=$(wc -l < "$out/synctest.log")
  sleep 25
  cmd status; sleep 1
  tail -n +"$((mark + 1))" "$out/synctest.log" | grep -E "BANNER|REMOTE-STATE|banner " || true
  if tail -n +"$((mark + 1))" "$out/synctest.log" | grep -q "BANNER Continue from"; then echo "!! dismissed banner came back during the same song"
  elif tail -n +"$((mark + 1))" "$out/synctest.log" | grep -q "REMOTE-STATE Probe iPhone: playing"; then echo "ok: dismissed banner stays hidden through the probe's republishes"
  else echo "!! no republish from the probe while waiting"; fi
else
  echo "!! no Continue banner to dismiss"
fi

say "network loss, then a wake from sleep: the Mac reconnects at once instead of waiting out its backoff"
# Reconnects are blocked for 16 s; the backoff (1, 2, 4, 8, then 16 s) is mid-wait when the wake comes at 19 s.
cmd "drop?s=16"; sleep 19
echo "-- $(date +%T) wake posted"
cmd wake; sleep 4
grep -E "CONNECTION|FOREGROUND|TEST wake|TEST drop" "$out/synctest.log" | tail -12

say "the network moves to another interface while connected: the Mac replaces the socket at once"
cmd "network?up=1&if=en0"; sleep 4
cmd status; sleep 1
before=$(grep -o "connections so far [0-9]*" "$out/synctest.log" | tail -1 | grep -o "[0-9]*$")
cmd "network?up=1&if=en0,utun9"; sleep 5
cmd status; sleep 1
after=$(grep -o "connections so far [0-9]*" "$out/synctest.log" | tail -1 | grep -o "[0-9]*$")
grep -E "NETWORK|TEST network" "$out/synctest.log" | tail -3
if grep -q "NETWORK changed (en0, utun9)" "$out/synctest.log" && (( ${after:-0} > ${before:-0} )) && grep "client socket" "$out/synctest.log" | tail -1 | grep -q "socket connected"; then
  echo "ok: a network change opens a fresh socket (connections $before -> $after)"
else echo "!! no fresh socket after a network change (connections ${before:-?} -> ${after:-?})"; fi

say "waiting for the probe's settings and test sign-in"
wait_log "SIGN-IN youtubeMusic" 90 || true
sleep 3
screen sync; shot settings-sync-paired settings
screen accounts; shot settings-accounts-synced settings
screen signout-youtubeMusic; shot signout-prompt sheet
screen invite 4; shot invite sheet
screen keyshare; shot keyshare sheet
screen close
cmd status; sleep 1

say "typed code: leave, rejoin without the key, then the key link (asks first)"
cmd leave; sleep 4
cmd status; sleep 1
grep "LEFT sync" "$out/synctest.log" | tail -1
code="$($P sync invite --state "$out/probe.json" | sed -n 's/.*invite code \([A-Z0-9-]*\) .*/\1/p')"
screen "join&code=ZZZZZ-ZZZZZ" 4; shot join-invalid-code sheet
grep -q "INVITE preview: not valid or expired" "$out/synctest.log" && echo "ok: a wrong code says it isn't valid" || echo "!! wrong code not reported"
screen "join&code=$code" 4; shot join-code-preview sheet
screen close
cmd "join?code=$code"
wait_log "PAIRED via typed code" 20
sleep 3
screen sync; shot settings-key-missing settings
screen pastekey; shot paste-key-sheet sheet
screen close
keylink="$($P sync key-link --state "$out/probe.json" | sed -n 's/.* key link \(openmusic:.*\)$/\1/p')"
send_url "$keylink"
wait_log "LINK key opened" 10
sleep 2
shot key-consent sheet
cmd confirm
wait_log "KEY imported" 10
sleep 2
screen sync; shot settings-key-imported settings
screen close
cmd status; sleep 1

say "app: sign out everywhere while the Keychain refuses (its folder read-only): the error shows, nothing changes"
chmod 500 "$out/keychain"
cmd "signout?provider=youtubeMusic&everywhere=1"; sleep 4
chmod 700 "$out/keychain"
cmd status; sleep 1.5
grep "SIGN-OUT youtubeMusic" "$out/synctest.log" | tail -2
if grep -q "SIGN-OUT youtubeMusic everywhere failed; provider signed in" "$out/synctest.log" \
   && grep -q "SIGN-OUT failed: Couldn't sign out of YouTube Music on this Mac" "$out/synctest.log" \
   && ! grep -q "signedOutEverywhere" "$out/synctest.log"; then
  echo "ok: a refused sign-out reports its error and signs nothing out anywhere"
else echo "!! refused sign-out not reported, or it signed something out"; fi

say "app: sign out of YouTube Music on this Mac only (the probe signs in again later; this Mac must ignore it)"
cmd "signout?provider=youtubeMusic&everywhere=0"; sleep 4
cmd status; sleep 1


say "waiting for the probe's second sign-in (another account): this Mac signed out here, so it must not take it"
for _ in $(seq 1 120); do grep -q "step: signin youtubeMusic" "$out/probe.log" && break; sleep 1; done
sleep 4
cmd status; sleep 1.5
if grep -q "Probe-Second-Account" "$out/synctest.log"; then echo "!! signed back in after signing out here"
elif tail -12 "$out/synctest.log" | grep -q "sign-in youtubeMusic: signed out; sync Optional(OpenMusicSync.SignInSync.Status.signedOutHere)"; then echo "ok: signed out here stays signed out when another device signs in"
else echo "!! unexpected status after the probe's second sign-in"; fi
say "waiting for the probe's sign-out everywhere"
wait "$probe" || true
cmd status; sleep 2
say "leave sync (the connection must close)"
cmd leave; sleep 5
cmd status; sleep 1
quit_app
say "the Mac's own Keychain: OpenMusic items before and after the run (attributes only)"
scripts/keychain-snapshot.sh > "$out/keychain-after.txt"
cat "$out/keychain-after.txt"
if diff "$out/keychain-before.txt" "$out/keychain-after.txt"; then echo "ok: the run left the login Keychain's OpenMusic items unchanged ($(wc -l < "$out/keychain-after.txt" | tr -d ' ') items)"
else echo "!! the run changed the login Keychain's OpenMusic items"; fi
echo "accounts the run kept in its own files instead: $(ls "$out/keychain" 2>/dev/null | tr '\n' ' ')"
say "done"
echo "== app log"; cat "$out/synctest.log"
echo "== probe log"; cat "$out/probe.log"
