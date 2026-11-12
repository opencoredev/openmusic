#!/usr/bin/env bash
# End-to-end OpenMusic accounts and sync between the Mac app and the iPhone app (Simulator), both on the build Mac,
# against the dev deployment (sensible-barracuda-214) and the OpenMusic Clerk development instance.
#   scripts/ios.sh <slot> build                    (once; builds the iPhone app for the slot's own simulator)
#   scripts/mac.sh <slot> 'scripts/e2e-sync.sh'
# Needs the Clerk test user's email in ~/.config/openmusic/clerk-test-email on the build Mac (mode 0600; a `+clerk_test`
# address, so the development instance's email code is always 424242). OPENMUSIC_TEST_EMAIL_FILE overrides the path.
# Both apps run their sync self-test (Debug builds only) and are driven through their command files, the same code
# paths the buttons take; the email and the code are typed into the real sign-in sheets (`type`). Steps:
#   1  the Mac shows the welcome, signs in through Settings › Account › Sign In… (email, then the code), registers
#      and becomes the first device (it makes the account's sign-in key)
#   2  the iPhone shows the welcome, signs in the same way and appears in the Mac's device list (and the Mac in its)
#   3  key exchange: the Mac's "Allow iPhone…?" alert and the iPhone's code must show the same six digits; Don't
#      Allow, then Ask Again on the iPhone brings the alert back with a new code; Allow on the Mac, Codes Match on the
#      iPhone, and the iPhone holds the key
#   4  handoff: the Mac plays Discovery from 1:00, the iPhone takes it (Play Here), then sends it back
#   5  a test sign-in made on the Mac (fake YouTube Music credentials) reaches the iPhone through the vault
#   6  the Mac signs out of the account and in again: now the iPhone shows the Allow alert, the Mac Codes Match
#   7  both sign out of the account (their devices leave it)
# What the server sees (docs/sync-design.md, "What the server can see"): before the iPhone has the key it sees the Mac
# play without a title and can still pause it, and Play Here says why it can't (3b); recent searches sync sealed (4c);
# a third device (openmusic-probe, OPENMUSIC_PROBE_JWT names a Clerk JWT file for the test user) gets the key and is
# removed, and after the rotation both apps still read each other's playback (5b). OPENMUSIC_E2E_HOLD=1 waits before
# step 7 (until build/e2e/release exists, at most 10 minutes) so the deployment's tables can be dumped while the
# account still has its rows.
# Screenshots (light and dark) of the welcome, the sign-in sheet, Settings › Account and the Allow alert on both,
# logs and timings (build/e2e/timings.txt, build/e2e/e2e-report.txt) go to build/e2e/.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
export OPENMUSIC_SLOT="${OPENMUSIC_SLOT:-macsync}"
lock=/tmp/medley-ui.lock
out="$PWD/build/e2e"
app="$PWD/build/OpenMusic.app"
exe="$app/Contents/MacOS/OpenMusic"

# Build first, then run the UI part under the shared UI lock, so no frame-timing run or capture overlaps it.
if [[ "${1:-}" != "--locked" ]]; then
  email_file="${OPENMUSIC_TEST_EMAIL_FILE:-$HOME/.config/openmusic/clerk-test-email}"
  [[ -s "$email_file" ]] || { echo "no test user email in $email_file" >&2; exit 2; }
  rm -rf "$out"; mkdir -p "$out/shots"
  CONFIG=debug scripts/bundle.sh | tail -1
  echo "-- waiting for $lock"
  OPENMUSIC_TEST_EMAIL_FILE="$email_file" exec lockf -t 1800 "$lock" "$0" --locked
fi

email="$(cat "$OPENMUSIC_TEST_EMAIL_FILE")"
code="${OPENMUSIC_TEST_CODE:-424242}"
bundle="dev.openmusic.OpenMusicMobile"
maclog="$out/synctest.log"
ioslog=/dev/null
status=0

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
say() { echo "-- $(date +%T) $*"; }
mark() { echo "$(now) $*" >> "$out/marks.txt"; }
fail() { echo "FAIL: $*"; echo "FAIL $*" >> "$out/results.txt"; status=1; }
# abort: a step everything after it needs failed.
abort() { fail "$*"; echo "stopping: the steps after this need it"; exit 1; }
pass() { echo "PASS: $*"; echo "PASS $*" >> "$out/results.txt"; }
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
mac_url() { echo "$1" >> "$out/synctest-cmd.txt"; }
mac_cmd() { mac_url "openmusic://test/$1"; }
ios_url() { echo "$1" >> "$data/Documents/synctest-cmd.txt"; }
ios_cmd() { ios_url "openmusic://test/$1"; }
lines() { [[ -f "$1" ]] && wc -l < "$1" | tr -d ' ' || echo 0; }
# wait_new FILE PATTERN SECONDS: wait for PATTERN in lines added after the last `snap`.
snap() { mac_from=$(lines "$maclog"); ios_from=$(lines "$ioslog"); }
wait_new() {
  local file="$1" pat="$2" secs="${3:-30}" from
  if [[ "$file" == "$maclog" ]]; then from=$mac_from; else from=$ios_from; fi
  for _ in $(seq 1 $((secs * 4))); do
    tail -n +"$((from + 1))" "$file" 2>/dev/null | grep -qE "$pat" && return 0
    sleep 0.25
  done
  echo "!! timed out waiting for: $pat"; return 1
}
# last_new FILE PATTERN: the last line matching PATTERN added after the last `snap`.
last_new() {
  local file="$1" pat="$2" from
  if [[ "$file" == "$maclog" ]]; then from=$mac_from; else from=$ios_from; fi
  tail -n +"$((from + 1))" "$file" 2>/dev/null | grep -E "$pat" | tail -1
}
tick() { t0=$(now); }
tock() { local dt; dt=$(python3 -c "print(f'{$(now) - $t0:.2f}')"); echo "$1: $dt s" | tee -a "$out/timings.txt"; }
mac_shot() { mac_cmd "shot?name=$1&w=${2:-main}"; sleep 0.8; }
ios_shot() { xcrun simctl io "$u" screenshot --type=png "$out/shots/$1.png" >/dev/null 2>&1; }
# both_modes NAME CMD...: a light and a dark capture (`mac_shot`/`ios_shot` NAME-light, NAME-dark).
mac_both() { mac_cmd "appearance?mode=light"; sleep 1.2; mac_shot "$1-light" "$2"; mac_cmd "appearance?mode=dark"; sleep 1.2; mac_shot "$1-dark" "$2"; mac_cmd "appearance?mode=light"; sleep 0.6; }
ios_both() { xcrun simctl ui "$u" appearance light; sleep 1.2; ios_shot "$1-light"; xcrun simctl ui "$u" appearance dark; sleep 1.2; ios_shot "$1-dark"; xcrun simctl ui "$u" appearance light; sleep 0.6; }
quit_mac() { pkill -TERM -f "$exe" 2>/dev/null || true; sleep 2; }
code_of() { sed -nE "s/.*$1 ([0-9]{3} ?[0-9]{3}).*/\1/p" <<< "$2" | tail -1; }

# The Mac app shares its preferences with every OpenMusic build on this Mac; put them back afterwards.
defaults export dev.openmusic.OpenMusic "$out/defaults-backup.plist" 2>/dev/null || true
u="$(scripts/ios-sim.sh udid)"
cleanup() {
  # Leave nothing on the test account, also after a failed or interrupted run.
  if pgrep -qf "$exe"; then mac_cmd signout-account; fi
  if [[ -n "${data:-}" ]]; then ios_cmd signout-account; fi
  sleep 6
  [[ -f "$ioslog" ]] && cp "$ioslog" "$out/iphone.log"
  [[ -f "$maclog" ]] && cp "$maclog" "$out/mac.log"
  quit_mac
  xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl ui "$u" appearance light >/dev/null 2>&1 || true
  if [[ -s "$out/defaults-backup.plist" ]]; then
    defaults delete dev.openmusic.OpenMusic >/dev/null 2>&1 || true
    defaults import dev.openmusic.OpenMusic "$out/defaults-backup.plist"
  fi
}
trap cleanup EXIT

say "iPhone: clean simulator $u (this slot's own)"
# Erased, not only uninstalled: after a run that imported the fake YouTube sign-in, the next runs on the same simulator
# couldn't load any YouTube stream on the iPhone (CoreMedia -15697) although uninstall and `keychain reset` ran; a fresh
# simulator played. Only this slot's simulator is erased.
xcrun simctl shutdown "$u" >/dev/null 2>&1 || true
xcrun simctl erase "$u"
xcrun simctl boot "$u" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$u" -b >/dev/null 2>&1 || true
xcrun simctl status_bar "$u" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1 || true
xcrun simctl uninstall "$u" "$bundle" >/dev/null 2>&1 || true
xcrun simctl keychain "$u" reset
scripts/ios-sim.sh install
xcrun simctl ui "$u" appearance light
# No keyboard tips over the sign-in sheet in the captures.
xcrun simctl spawn "$u" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true >/dev/null 2>&1 || true

say "1. Mac: launch signed out; the welcome"
quit_mac
# The welcome shows once per Mac; this run's preferences are put back afterwards.
defaults delete dev.openmusic.OpenMusic didShowAccountWelcome >/dev/null 2>&1 || true
open -n -F "$app" --args -didOnboard YES -OpenMusicSyncSelfTest YES -OpenMusicSyncDir "$out" -OpenMusicSyncState "$out/mac-state.json" \
  -OpenMusicSyncDeviceName "Mac"
for _ in $(seq 1 60); do grep -q STARTED "$maclog" 2>/dev/null && break; sleep 0.5; done
snap
sleep 4
mac_both mac-1-welcome sheet

say "1. Mac: Settings › Account › Sign In…, email, then the code"
mac_cmd "screen?name=signin"; sleep 3
mac_both mac-2-signin-email sheet
snap; tick
mac_cmd "type?text=$(enc "$email")&submit=1"
wait_new "$maclog" "TYPE " 10 || fail "Mac: typing the email"
sleep 4
mac_both mac-3-signin-code sheet
mac_cmd "type?text=$code&submit=1"
if wait_new "$maclog" "ACCOUNT signed in to sync as" 40; then pass "Mac signed in and registered"; else abort "Mac sign-in"; fi
tock "Mac: email typed to registered"
sleep 2
# Devices an interrupted earlier run left on the test account go first, as Settings › Account › Remove… does.
if last_new "$maclog" "DEVICES" | grep -q ", \|\[[^]]*[^)] [a-z]*, "; then
  echo "leftover devices: $(last_new "$maclog" DEVICES)"
  mac_cmd remove-others
  wait_new "$maclog" "DEVICES \[Mac \(self\) [a-z]*\]" 30 || fail "leftover devices stayed: $(last_new "$maclog" DEVICES)"
fi
wait_new "$maclog" "KEYSTATUS available" 60 && pass "Mac made the account's sign-in key" || fail "Mac key"
wait_new "$maclog" "DEVICES \[Mac \(self\) holder\]" 15 && pass "Mac is in the device list" || fail "Mac device list: $(last_new "$maclog" DEVICES)"
mac_cmd "screen?name=account"; sleep 3.5
mac_both mac-4-settings-account settings

say "2. iPhone: launch signed out; the welcome"
xcrun simctl launch "$u" "$bundle" -firstRunFinished YES -OpenMusicSyncSelfTest YES -OpenMusicSyncDeviceName "iPhone" >/dev/null
data="$(xcrun simctl get_app_container "$u" "$bundle" data)"
ioslog="$data/Documents/synctest.log"
for _ in $(seq 1 60); do [[ -s "$ioslog" ]] && break; sleep 0.5; done
sleep 5
ios_both iphone-1-welcome
snap
say "calibrate the iPhone log's clock (it logs offsets from its start)"
for i in 1 2 3 4 5 6 7 8; do mark "ping $i"; ios_cmd "ping?i=$i"; sleep 0.37; done
sleep 1

say "2. iPhone: Settings › Account › Sign In, email, then the code"
ios_cmd "screen?name=signin"; sleep 3.5
ios_both iphone-2-signin-email
snap; tick
ios_cmd "type?text=$(enc "$email")&submit=1"
wait_new "$ioslog" "TYPE " 10 || fail "iPhone: typing the email"
sleep 4
ios_both iphone-3-signin-code
snap
ios_cmd "type?text=$code"
if wait_new "$ioslog" "ACCOUNT signed in to sync as" 40; then pass "iPhone signed in and registered"; else abort "iPhone sign-in"; fi
tock "iPhone: email typed to registered"
wait_new "$ioslog" "DEVICES \[.*Mac holder" 20 && pass "iPhone sees the Mac" || fail "iPhone device list: $(last_new "$ioslog" DEVICES)"
wait_new "$maclog" "DEVICES \[.*iPhone" 20 && pass "Mac sees the iPhone" || fail "Mac device list: $(last_new "$maclog" DEVICES)"

say "3. key exchange: the Mac's alert and the iPhone's code"
tick
wait_new "$maclog" "KEYREQUESTS \[iPhone code" 40 || fail "the Mac never saw the iPhone ask"
wait_new "$ioslog" "KEYSTATUS comparing code" 40 || fail "the iPhone never got a code to compare"
tock "iPhone asked to both showing a code"
mac_code="$(code_of "iPhone code" "$(last_new "$maclog" "KEYREQUESTS")")"
ios_code="$(code_of "comparing code" "$(last_new "$ioslog" "KEYSTATUS comparing")")"
echo "codes: Mac alert \"$mac_code\", iPhone \"$ios_code\""
[[ -n "$mac_code" && "$mac_code" == "$ios_code" ]] && pass "both show the same code ($mac_code)" || fail "codes differ: Mac \"$mac_code\" iPhone \"$ios_code\""
mac_cmd "screen?name=close"; sleep 2
wait_new "$maclog" "PRESENTED pending=iPhone on screen: .*sheet" 10 && pass "the Mac shows the Allow alert" || fail "no Allow alert on the Mac: $(last_new "$maclog" PRESENTED)"
mac_both mac-5-allow-alert sheet

say "3. Don't Allow on the Mac, Ask Again on the iPhone: the alert comes back with the new request"
snap
mac_cmd deny
wait_new "$ioslog" "KEYSTATUS denied" 20 && pass "Don't Allow reached the iPhone" || fail "the iPhone wasn't told no: $(last_new "$ioslog" KEYSTATUS)"
snap
ios_cmd askagain
wait_new "$maclog" "KEYREQUESTS \[iPhone code" 40 || fail "the Mac never saw the iPhone ask again"
wait_new "$ioslog" "KEYSTATUS comparing code" 40 || fail "the iPhone got no new code"
wait_new "$maclog" "PRESENTED pending=iPhone on screen: .*sheet" 15 && pass "the Mac's alert came back after Ask Again" || fail "no alert after Ask Again: $(last_new "$maclog" PRESENTED)"
mac_code="$(code_of "iPhone code" "$(last_new "$maclog" "KEYREQUESTS")")"
ios_code="$(code_of "comparing code" "$(last_new "$ioslog" "KEYSTATUS comparing")")"
[[ -n "$mac_code" && "$mac_code" == "$ios_code" ]] && pass "the new exchange shows one code on both ($mac_code)" || fail "codes differ after Ask Again: Mac \"$mac_code\" iPhone \"$ios_code\""
ios_cmd "screen?name=account"; sleep 3.5
ios_both iphone-4-settings-account-comparing

say "3b. sealed: the iPhone has no key yet; it sees where the Mac plays, not what, and can still pause it"
snap
mac_cmd "play?ytm=daft%20punk%20discovery&seek=60"
wait_new "$maclog" "PLAY seeked" 60 || fail "the Mac couldn't play (3b)"
if wait_new "$ioslog" 'REMOTE-STATE Mac: playing "\(sealed\)"' 30; then pass "the iPhone without the key sees the Mac playing, no title: $(last_new "$ioslog" 'REMOTE-STATE Mac')"; else fail "keyless iPhone row: $(last_new "$ioslog" 'REMOTE-STATE')"; fi
last_new "$ioslog" 'REMOTE-STATE Mac' | grep -q '"(sealed)"' || fail "the keyless iPhone read a title: $(last_new "$ioslog" 'REMOTE-STATE Mac')"
wait_new "$ioslog" 'BANNER Continue from Mac: "\(sealed\)"' 20 && pass "its banner offers the Mac without a title" || fail "keyless banner: $(last_new "$ioslog" BANNER)"
ios_cmd "screen?name=devices"; sleep 3.5
ios_both iphone-keyless-devices
ios_cmd "screen?name=close"; sleep 1.5
ios_shot iphone-keyless-banner
snap
ios_cmd playhere
if wait_new "$ioslog" "PULL done|PULL failed" 30 && last_new "$ioslog" "PULL" | grep -q "sign-in key"; then pass "Play Here without the key says why: $(last_new "$ioslog" "PULL failed")"; else fail "keyless Play Here: $(last_new "$ioslog" PULL)"; fi
snap; tick
ios_cmd "remote?to=Mac&do=pause"
if wait_new "$maclog" "PLAYER paused" 20; then pass "the keyless iPhone paused the Mac"; else fail "the keyless iPhone couldn't pause the Mac"; fi
tock "remote pause from the keyless iPhone to the Mac paused"
wait_new "$ioslog" "REMOTE pause acked ok=true" 10 && pass "its pause was acked: $(last_new "$ioslog" "REMOTE pause")" || fail "pause ack: $(last_new "$ioslog" REMOTE)"
sleep 1
snap; tick
mac_cmd allow
wait_new "$maclog" "KEY allowed iPhone" 20 || fail "Allow on the Mac"
wait_new "$ioslog" "KEYSTATUS comparing .*allowed=true" 20 || true
ios_cmd codes-match
if wait_new "$ioslog" "KEYSTATUS available" 30; then pass "the iPhone holds the sign-in key"; else abort "the iPhone never got the key"; fi
tock "Allow to the iPhone holding the key"
wait_new "$maclog" "DEVICES \[.*iPhone holder" 20 && pass "the Mac lists the iPhone as a holder" || fail "Mac list: $(last_new "$maclog" DEVICES)"
sleep 2
ios_both iphone-5-settings-account-signed-in
ios_cmd "screen?name=close"; sleep 1.5

say "4a. handoff: the Mac plays Discovery from 1:00; the iPhone takes it"
snap
mac_cmd "play?ytm=daft%20punk%20discovery&seek=60"
wait_new "$maclog" "PLAY seeked" 60 || fail "the Mac couldn't play"
wait_new "$ioslog" "BANNER Continue from Mac" 30 || fail "no Continue from Mac banner on the iPhone"
sleep 3
snap; tick
mark "tap a playhere"
ios_cmd playhere
if wait_new "$ioslog" "PULL done|PULL failed" 45 && ! last_new "$ioslog" "PULL" | grep -q failed; then pass "Play Here on the iPhone: $(last_new "$ioslog" "PULL done")"; else fail "Play Here: $(last_new "$ioslog" PULL)"; fi
tock "Play Here (iPhone takes the Mac's playback)"
wait_new "$maclog" "PLAYER paused" 20 && pass "the Mac paused after the handoff" || fail "the Mac kept playing"
sleep 5
ios_shot e2e-handoff-iphone-playing
ios_cmd status; mac_cmd status; sleep 1.5

say "4b. the iPhone sends playback back to the Mac"
ios_cmd "screen?name=devices"; sleep 3.5
snap; tick
mark "tap b send"
ios_cmd "send?to=Mac"
if wait_new "$ioslog" "PUSH done|PUSH failed" 45 && ! last_new "$ioslog" "PUSH" | grep -q failed; then pass "send to the Mac: $(last_new "$ioslog" "PUSH done")"; else fail "send to the Mac: $(last_new "$ioslog" PUSH)"; fi
tock "send to Mac"
wait_new "$maclog" "PLAYER playing" 20 && pass "the Mac plays again" || fail "the Mac didn't play"
sleep 4
mac_shot e2e-handoff-mac-playing
ios_cmd "screen?name=close"; sleep 1.5
say "4c. remote control from the iPhone (sealed or not, commands carry only numbers)"
snap; tick
ios_cmd "remote?to=Mac&do=pause"
wait_new "$maclog" "PLAYER paused" 20 && pass "the iPhone paused the Mac" || fail "remote pause"
tock "remote pause: iPhone tap to the Mac paused"
snap; tick
ios_cmd "remote?to=Mac&do=play"
wait_new "$maclog" "PLAYER playing" 30 && pass "the iPhone resumed the Mac" || fail "remote play"
tock "remote play: iPhone tap to the Mac playing"
mac_cmd pause; sleep 2

say "4d. recent searches sync, sealed"
snap; tick
mac_cmd "search?q=sealed%20e2e%20search"
if wait_new "$ioslog" 'SETTING search.recent .*sealed e2e search' 20; then pass "the Mac's search reached the iPhone: $(last_new "$ioslog" 'SETTING search.recent')"; else fail "recent searches didn't sync"; fi
tock "search on the Mac to applied on the iPhone (includes the 400 ms debounce)"

say "5. a test sign-in made on the Mac reaches the iPhone through the vault (fake credentials)"
snap; tick
mac_cmd "signin-test?provider=youtubeMusic"
wait_new "$maclog" "SIGNIN-TEST youtubeMusic made here" 20 || fail "the Mac's test sign-in"
if wait_new "$ioslog" "SIGN-IN youtubeMusic" 40; then pass "the iPhone took the Mac's sign-in: $(last_new "$ioslog" "SIGN-IN youtubeMusic")"; else fail "the sign-in never reached the iPhone"; fi
tock "sign-in on the Mac to the iPhone signed in"
ios_cmd "screen?name=account-youtubeMusic"; sleep 3
ios_shot e2e-vault-iphone-youtube-signed-in
ios_cmd status; mac_cmd status; sleep 1.5
ios_cmd "screen?name=close"; sleep 1

say "5b. a third device gets the key and is removed: the key rotates, both apps still read each other"
probe="$PWD/.build/debug/openmusic-probe"; pstate="$out/probe-state.json"; pjwt="${OPENMUSIC_PROBE_JWT:-}"
if [[ -x "$probe" && -s "$pjwt" ]]; then
  p() { "$probe" sync "$@" --state "$pstate" --jwt-file "$pjwt" --name Probe >> "$out/probe.log" 2>&1; }
  snap
  p sign-in || fail "probe sign-in"
  # The probe runs one step per call: it commits, a holder answers, then its next call reveals and both show a code.
  asked=""
  for _ in 1 2 3 4 5 6; do
    sleep 2
    p keys || true
    if last_new "$maclog" "KEYREQUESTS" | grep -q "Probe code" || last_new "$ioslog" "KEYREQUESTS" | grep -q "Probe code"; then asked=1; break; fi
  done
  [[ -n "$asked" ]] || fail "no holder saw the probe ask"
  mac_cmd allow; ios_cmd allow; sleep 3
  p confirm || true
  if grep -q "vault key: available" "$out/probe.log"; then pass "the probe holds the key"; else fail "the probe never got the key: $(tail -3 "$out/probe.log")"; fi
  wait_new "$maclog" "DEVICES \[[^]]*Probe holder" 20 || true
  snap; tick
  mac_cmd "remove?to=Probe"
  wait_new "$maclog" "REMOVED Probe" 20 && pass "the Mac removed the probe" || fail "removing the probe: $(last_new "$maclog" REMOVE)"
  wait_new "$maclog" "DEVICES \[(Mac \(self\) holder, iPhone holder|iPhone holder, Mac \(self\) holder)\]" 30 && pass "two holders left" || fail "Mac list after the removal: $(last_new "$maclog" DEVICES)"
  sleep 4
  tock "probe removed to the key rotated (approx.)"
  snap
  mac_cmd "play?ytm=daft%20punk%20discovery&seek=30"
  wait_new "$maclog" "PLAY seeked" 60 || fail "the Mac couldn't play after the rotation"
  if wait_new "$ioslog" 'REMOTE-STATE Mac: playing "[^(]' 30; then pass "after the rotation the iPhone reads the Mac's title: $(last_new "$ioslog" 'REMOTE-STATE Mac')"; else fail "iPhone after rotation: $(last_new "$ioslog" 'REMOTE-STATE Mac')"; fi
  wait_new "$ioslog" "BANNER Continue from Mac" 30 || true
  sleep 2
  snap; tick
  ios_cmd playhere
  if wait_new "$ioslog" "PULL done|PULL failed" 45 && ! last_new "$ioslog" "PULL" | grep -q failed; then pass "Play Here after the rotation: $(last_new "$ioslog" "PULL done")"; else fail "Play Here after the rotation: $(last_new "$ioslog" PULL)"; fi
  tock "Play Here after the rotation"
  if wait_new "$maclog" 'REMOTE-STATE iPhone: playing "[^(]' 30; then pass "after the rotation the Mac reads the iPhone's title: $(last_new "$maclog" 'REMOTE-STATE iPhone')"; else fail "Mac after rotation: $(last_new "$maclog" 'REMOTE-STATE iPhone')"; fi
  ios_cmd "remote?to=Mac&do=pause"; sleep 1; ios_cmd status; mac_cmd status; sleep 1.5
  snap
  ios_cmd "screen?name=devices"; sleep 3.5; ios_shot iphone-after-rotation-devices; ios_cmd "screen?name=close"; sleep 1
  # The iPhone keeps playing: the Mac's sign-out next starts from a playing account.
else
  fail "5b skipped: no openmusic-probe at $probe or no OPENMUSIC_PROBE_JWT"
fi

say "6. the Mac signs out of the account and in again: the iPhone approves it this time"
snap
mac_cmd signout-account
wait_new "$maclog" "ACCOUNT signed out" 30 && pass "the Mac signed out of the account" || fail "Mac sign-out"
wait_new "$ioslog" "DEVICES \[iPhone \(self\) holder\]" 30 && pass "the Mac left the iPhone's device list" || fail "iPhone list after the Mac left: $(last_new "$ioslog" DEVICES)"
mac_cmd "screen?name=account"; sleep 3
mac_both mac-6-settings-account-signed-out settings
mac_cmd "screen?name=signin"; sleep 3
snap; tick
mac_cmd "type?text=$(enc "$email")&submit=1"; sleep 4
mac_cmd "type?text=$code&submit=1"
wait_new "$maclog" "ACCOUNT signed in to sync as" 40 && pass "the Mac signed in again" || fail "the Mac's second sign-in"
tock "Mac: second sign-in"
tick
wait_new "$ioslog" "KEYREQUESTS \[Mac code" 40 || fail "the iPhone never saw the Mac ask"
wait_new "$maclog" "KEYSTATUS comparing code" 40 || fail "the Mac never got a code to compare"
tock "Mac asked to both showing a code"
ios_code="$(code_of "Mac code" "$(last_new "$ioslog" "KEYREQUESTS")")"
mac_code="$(code_of "comparing code" "$(last_new "$maclog" "KEYSTATUS comparing")")"
[[ -n "$mac_code" && "$mac_code" == "$ios_code" ]] && pass "both show the same code ($mac_code)" || fail "codes differ: iPhone \"$ios_code\" Mac \"$mac_code\""
wait_new "$ioslog" "PRESENTED pending=Mac on screen: .*Alert" 10 && pass "the iPhone shows the Allow alert" || fail "no Allow alert on the iPhone: $(last_new "$ioslog" PRESENTED)"
sleep 1
ios_both iphone-6-allow-alert
mac_cmd "screen?name=account"; sleep 3.5
mac_both mac-7-settings-account-comparing settings
snap; tick
ios_cmd allow
wait_new "$ioslog" "KEY allowed Mac" 20 || fail "Allow on the iPhone"
mac_cmd codes-match
if wait_new "$maclog" "KEYSTATUS available" 30; then pass "the Mac holds the sign-in key again"; else fail "the Mac never got the key back"; fi
tock "Allow on the iPhone to the Mac holding the key"
sleep 2
mac_both mac-8-settings-account-signed-in settings
mac_cmd status; ios_cmd status; sleep 1.5

if [[ -n "${OPENMUSIC_E2E_HOLD:-}" ]]; then
  say "holding for the table dump (touch $out/release)"
  touch "$out/hold"
  for _ in $(seq 1 600); do [[ -f "$out/release" ]] && break; sleep 1; done
fi

say "7. both sign out of the account"
snap
ios_cmd signout-account; sleep 4
mac_cmd signout-account
wait_new "$maclog" "ACCOUNT signed out" 30 || fail "Mac final sign-out"
wait_new "$ioslog" "ACCOUNT signed out" 30 || fail "iPhone final sign-out"
mac_cmd status; ios_cmd status; sleep 2
cp "$ioslog" "$out/iphone.log"
cp "$maclog" "$out/mac.log"
python3 scripts/e2e-report.py "$out" > "$out/e2e-report.txt" 2>&1 || true
echo "== results"; cat "$out/results.txt"
echo "== timings"; cat "$out/timings.txt"
exit "$status"
