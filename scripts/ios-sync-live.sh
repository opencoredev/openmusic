#!/usr/bin/env bash
# Live check of Medley Sync on the iPhone app against a `medley-probe sync` device, on the build Mac.
#   scripts/mac.sh <slot> 'scripts/ios-sync-live.sh'      (after: scripts/ios.sh <slot> build)
# The probe ("Probe Mac") plays a real YouTube Music queue on its silent engine. The app runs with
# -MedleySyncSelfTest YES and is driven with openmusic://test/... links (see iOS/Medley/Sync/SyncSelfTest.swift).
# Checks: no sync socket while unpaired; a pairing link asks first (nothing joins on Cancel, the backend shows no new
# device before Join); pair by link, banner, pull handoff (position and the probe's pause), push, remote control,
# settings and a test sign-in from the probe; then typed-code pairing (also confirmed) without the key, a sign-out
# on this iPhone only before the key arrives (it must stick), and the key link opened during a cold launch.
# Lines starting "CHECK" sum up each check (PASS/FAIL).
# Screenshots (light and dark) go to build/shots/sync-*.png; logs to build/sync-live/.
set -euo pipefail
# Accounts replaced invite pairing (docs/accounts-design.md). This script still drives create/invite/join, which no
# longer exist; it needs a rework around sign-in with a Clerk test user's JWT (medley-probe sync sign-in --jwt-file,
# the apps' -MedleySyncJWTFile) before it can run again.
echo "$(basename "$0"): not updated for accounts yet; see docs/accounts-design.md (Testing)." >&2
exit 2
cd "$(dirname "$0")/.."
export MEDLEY_SLOT="${MEDLEY_SLOT:-iossync}"
export MEDLEY_CONFIG=Debug   # the self-test only exists in Debug builds
bundle="dev.openmusic.OpenMusicMobile"
out="build/sync-live"
mkdir -p "$out" build/shots
rm -f build/sync-live/*.json build/sync-live/*.log build/shots/sync-*.png
: > "$out/checks.log"
P=.build/debug/medley-probe
swift build --product medley-probe 2>&1 | tail -1

u="$(scripts/ios-sim.sh udid)"
# Reboot this slot's own simulator (by UDID) so no system alert from an earlier run is left on screen.
xcrun simctl shutdown "$u" >/dev/null 2>&1 || true
xcrun simctl boot "$u" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$u" -b >/dev/null 2>&1 || true
xcrun simctl status_bar "$u" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
# A clean iPhone: no pairing, no sign-ins (this simulator belongs to the slot).
xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1 || true
xcrun simctl uninstall "$u" "$bundle" >/dev/null 2>&1 || true
xcrun simctl keychain "$u" reset
scripts/ios-sim.sh install
xcrun simctl ui "$u" appearance light

say() { echo "-- $(date +%T) $*"; }
# Links go in through the app's command file (see SyncSelfTest.swift): simctl openurl asks "Open in OpenMusic?" on iOS 27.
send_url() { echo "$1" >> "$data/Documents/synctest-cmd.txt"; }
test_url() { send_url "openmusic://test/$1"; }
shot() { # shot NAME: light and dark
  for a in light dark; do
    xcrun simctl ui "$u" appearance "$a"; sleep 1.6
    xcrun simctl io "$u" screenshot --type=png "build/shots/sync-$1-$a.png" >/dev/null 2>&1
  done
  xcrun simctl ui "$u" appearance light
}
screen() { test_url "screen?name=$1"; sleep "${2:-2.5}"; }
check() { local r; if eval "$2"; then r="CHECK PASS $1"; else r="CHECK FAIL $1"; fi; echo "$r" | tee -a "$out/checks.log"; }
wait_log() { for _ in $(seq 1 "${2:-20}"); do grep -q "$1" "$log" 2>/dev/null && return 0; sleep 1; done; return 1; }

say "probe: new library"
$P sync create-library --name "Probe Mac" --state "$out/a.json" | tee "$out/probe-setup.log"
link="$($P sync invite --state "$out/a.json" | tee -a "$out/probe-setup.log" | sed -n 's/.* link \(openmusic:.*\)$/\1/p')"
[[ -n "$link" ]] || { echo "no invite link"; exit 1; }

say "app: launch unpaired"
xcrun simctl launch "$u" "$bundle" -firstRunFinished YES -MedleySyncSelfTest YES -MedleySyncDeviceName "Test iPhone" >/dev/null
data="$(xcrun simctl get_app_container "$u" "$bundle" data)"
log="$data/Documents/synctest.log"
for _ in $(seq 1 30); do [[ -s "$log" ]] && break; sleep 1; done
sleep 5
test_url status; sleep 1
check "unpaired: no sync socket" '! grep -q "CONNECTION start" "$log" && grep -q "STATUS paired=false" "$log"'
screen sync; shot onboarding
screen pair; shot pair
screen close
check "pair sheet open: socket opened for pairing" 'grep -q "CONNECTION start (pairing)" "$log"'
sleep 2
check "pair sheet closed: socket stopped again" 'grep -q "CONNECTION stop" "$log"'

say "app: open the pairing link; it must ask first"
send_url "$link"
wait_log "CONFIRM asked" 15 || true
sleep 2.5
shot confirm-link
$P sync devices --state "$out/a.json" > "$out/devices-before-confirm.log" 2>&1 || true
check "link asks before joining" 'grep -q "CONFIRM asked: join a library (link with key)" "$log" && ! grep -q "PAIRED" "$log"'
check "backend: no new device before Join" '! grep -q "Test iPhone" "$out/devices-before-confirm.log"'
test_url decline; sleep 2
test_url status; sleep 1
check "Cancel: nothing joined" 'grep -q "CONFIRM declined" "$log" && ! grep -q "PAIRED" "$log" && grep -q "STATUS paired=false" "$log"'
say "app: open the link again and tap Join"
send_url "$link"
wait_log "CONFIRM asked: join a library (link with key)" 15 || true
sleep 1.5
test_url confirm
wait_log "PAIRED" 20 || true
$P sync devices --state "$out/a.json" > "$out/devices-after-confirm.log" 2>&1 || true
check "Join: paired with the key" 'grep -q "PAIRED via link as Test iPhone; library key received" "$log"'
check "backend: device after Join" 'grep -q "Test iPhone" "$out/devices-after-confirm.log"'
sleep 2

say "probe: play a real YouTube Music queue (Discovery), 40 s in; settings and a test sign-in later"
$P sync fake-play --name "Probe Mac" --state "$out/a.json" --ytm "daft punk discovery" --start-at 40 --seconds 215 \
  --script "sleep 75; crossfade 6; autoplay off; searches Daft Punk,Justice; sleep 6; signin-test youtubeMusic; sleep 100; signin-test youtubeMusic; sleep 8; signout youtubeMusic everywhere; sleep 15" \
  > "$out/probe.log" 2>&1 &
probe=$!
sleep 9
shot banner

say "app: tap Play Here on the banner"
test_url playhere
sleep 9
shot playing-here
test_url status; sleep 1

say "app: Devices sheet"
screen devices 3
shot devices

say "app: push back to the probe"
test_url "send?to=Probe%20Mac"
sleep 7
shot devices-after-push
say "app: remote control the probe"
test_url "remote?to=Probe%20Mac&do=toggle"; sleep 3
test_url "remote?to=Probe%20Mac&do=toggle"; sleep 3
test_url "remote?to=Probe%20Mac&do=next"; sleep 4
test_url "remote?to=Probe%20Mac&do=seek&v=95"; sleep 4
shot devices-remote
test_url status; sleep 1
screen close

say "waiting for the probe's settings and test sign-in"
for _ in $(seq 1 60); do grep -q "SIGN-IN youtubeMusic" "$log" 2>/dev/null && break; sleep 1; done
sleep 3
screen sync; shot paired
screen account-youtubeMusic; shot account-synced
screen signout-youtubeMusic; shot signout-prompt
screen invite 4; shot invite
screen keyshare; shot keyshare
screen close
test_url status; sleep 1

say "typed code: leave, rejoin without the key (confirmed), sign out here only, then take the key at launch"
test_url leave; sleep 3
check "left sync: socket stopped" '[[ "$(grep -c "CONNECTION stop" "$log")" -ge 2 ]]'
code="$($P sync invite --state "$out/a.json" | sed -n 's/.*invite code \([A-Z0-9-]*\) .*/\1/p')"
test_url "join?code=$code"
wait_log "CONFIRM asked: join a library (typed code, no key)" 10 || true
sleep 2.5
shot confirm-code
check "typed code asks before joining" '[[ "$(grep -c "PAIRED" "$log")" -eq 1 ]]'
test_url confirm
wait_log "PAIRED via typed code" 15 || true
sleep 2
screen sync; shot key-missing
say "app: Sign Out of YouTube Music (the button) while the key is missing"
test_url "signout?provider=youtubeMusic&tap=1"; sleep 4
check "sign-out without the key goes through sign-in sync" 'grep -q "SIGNED OUT youtubeMusic here" "$log"'
screen close
keylink="$($P sync key-link --state "$out/a.json" | sed -n 's/.* key link \(openmusic:.*\)$/\1/p')"
cp "$log" "$out/app-before-relaunch.log"
say "app: cold launch with the key link arriving during launch"
xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1 || true
xcrun simctl launch "$u" "$bundle" -firstRunFinished YES -MedleySyncSelfTest YES -MedleySyncDeviceName "Test iPhone" -MedleyOpenURL "$keylink" >/dev/null
sleep 2
for _ in $(seq 1 30); do [[ -s "$log" ]] && break; sleep 1; done
wait_log "CONFIRM asked: take the sign-in key" 30 || true
sleep 2.5
shot confirm-key
check "link sent during launch is handled (asks)" 'grep -q "CONFIRM asked: take the sign-in key" "$log" && ! grep -q "KEY imported" "$log"'
test_url confirm
wait_log "KEY imported" 15 || true
sleep 5
screen sync; shot key-imported
test_url status; sleep 1
check "key imported" 'grep -q "KEY imported; status available" "$log"'
check "here-only sign-out stuck after the key arrived" '! grep -q "SIGN-IN youtubeMusic imported" "$log" && grep -q "sign-in youtubeMusic: signed out; sync .*signedOutHere" "$log"'
screen close
say "waiting for the probe's second test sign-in and its sign-out everywhere"
wait "$probe" || true
test_url status; sleep 2
say "done"
cp "$log" "$out/app.log"
check "probe's later sign-in ignored, sign-out everywhere applied" 'grep -q "SIGN-IN youtubeMusic signed out everywhere" "$log" && ! grep -q "SIGN-IN youtubeMusic imported" "$log"'
echo "== app log (before the relaunch)"; cat "$out/app-before-relaunch.log"
echo "== app log (after)"; cat "$out/app.log"
echo "== probe log"; cat "$out/probe.log"
echo "== checks"; cat "$out/checks.log"
