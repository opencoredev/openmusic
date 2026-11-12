#!/usr/bin/env bash
# The first-run flow on the Mac and the iPhone, live against the dev deployment (sensible-barracuda-214) and the
# OpenMusic Clerk development instance, captured for design review (docs/onboarding.md).
#   scripts/onboarding-shots-apple.sh <out-dir> [mac|ios|both]     from the Linux checkout
#   scripts/onboarding-shots-apple.sh --remote <what>                on the build Mac (called by the line above)
#
# The Linux side makes two Clerk test users (`+clerk_test` addresses: every email code is 424242) through the Backend
# API with the secret in ~/.config/openmusic/clerk-dev.env (it never leaves that machine; ~/.config/openmusic/onb/clerk.sh,
# a local helper that is not in the repo: `create <email>`, `jwt <user>`, `delete <user>`), pushes a
# fresh Convex JWT for each to the build Mac every 45 s (0600 files, for medley-probe's stand-in devices), and deletes the
# users and the files on exit, also after a failure.
#
# On the build Mac: a Debug bundle, medley-probe and the iPhone app are built, then the captures run under
# /tmp/medley-ui.lock with a 2x virtual display. Each app starts as a fresh install (the Mac's preferences moved
# aside and put back afterwards, its Keychain kept in files by the sync self-test; the slot's own simulator erased)
# and is driven through its self-test command file, the code paths the buttons take. The probe plays the account's
# other device: the holder that approves the new device, a third device asking the app (the holder's prompt), and
# the device playing for the Continue banner. Shots: <out-dir>/{mac,iphone}/<n>-<state>-<light|dark>.png, checks
# in <out-dir>/results.txt (PASS/FAIL lines), the apps' logs in <out-dir>/logs.
set -euo pipefail
cd "$(dirname "$0")/.."
slot=onb-shots
rdir="agents/medley-$slot"
clerk="$HOME/.config/openmusic/onb/clerk.sh"

# ---------------------------------------------------------------- Linux side
if [[ "${1:-}" != --remote && "${1:-}" != --capture ]]; then
  . scripts/env.sh
  need OPENMUSIC_MAC_HOST
  mini="$OPENMUSIC_MAC_HOST"
  dest="${1:?usage: scripts/onboarding-shots-apple.sh <out-dir> [mac|ios|both]}"
  what="${2:-both}"
  mkdir -p "$dest"
  [[ -x "$clerk" ]] || { echo "needs $clerk (Clerk Backend API helper for the dev instance)" >&2; exit 2; }
  run="$(date +%s)$RANDOM"
  mac_email="onb-mac-$run+clerk_test@example.com"
  ios_email="onb-ios-$run+clerk_test@example.com"
  mac_user="" ios_user="" pusher=""
  cleanup() {
    [[ -n "$pusher" ]] && { kill "$pusher" 2>/dev/null || true; wait "$pusher" 2>/dev/null || true; }
    ssh -o BatchMode=yes "$mini" "find ~/$rdir/build/onb -maxdepth 1 \( -name 'jwt-*' -o -name accounts \) -delete" 2>/dev/null || true
    for u in "$mac_user" "$ios_user"; do [[ "$u" == user_* ]] && "$clerk" delete "$u" >/dev/null 2>&1 || true; done
    echo "test users deleted"
  }
  trap cleanup EXIT
  mac_user="$("$clerk" create "$mac_email")"
  ios_user="$("$clerk" create "$ios_email")"
  [[ "$mac_user" == user_* && "$ios_user" == user_* ]] || { echo "couldn't make the test users" >&2; exit 1; }
  ssh -o BatchMode=yes "$mini" "mkdir -p ~/$rdir/build/onb && chmod 700 ~/$rdir/build/onb"
  printf 'MAC_EMAIL=%s\nIOS_EMAIL=%s\n' "$mac_email" "$ios_email" | ssh -o BatchMode=yes "$mini" "umask 077; cat > ~/$rdir/build/onb/accounts"
  push() {
    local n u
    for n in mac ios; do
      if [[ "$n" == mac ]]; then u="$mac_user"; else u="$ios_user"; fi
      "$clerk" jwt "$u" | ssh -o BatchMode=yes "$mini" "umask 077; cat > ~/$rdir/build/onb/jwt-$n.tmp && mv ~/$rdir/build/onb/jwt-$n.tmp ~/$rdir/build/onb/jwt-$n.txt"
    done
  }
  push
  ( while sleep 45; do push >/dev/null 2>&1 || true; done ) &
  pusher=$!
  status=0
  scripts/mac.sh "$slot" "scripts/onboarding-shots-apple.sh --remote $what" || status=$?
  rsync -az -e "ssh -o BatchMode=yes" "$mini:$rdir/build/onb/out/" "$dest/" || true
  rev=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && rev="$rev+uncommitted"
  echo "$rev" > "$dest/revision.txt"
  echo "pulled $(find "$dest" -name '*.png' | wc -l | tr -d ' ') images to $dest ($rev)"
  if [[ -f "$dest/results.txt" ]]; then
    echo "PASS lines: $(grep -c '^PASS' "$dest/results.txt" || true)"
    grep '^FAIL' "$dest/results.txt" || true
  fi
  exit "$status"
fi

# ---------------------------------------------------------------- build Mac: build, then capture under the lock
root="$PWD"
base="$root/build/onb"
out="$base/out"
lock=/tmp/medley-ui.lock
app="$root/build/OpenMusic.app"
exe="$app/Contents/MacOS/OpenMusic"
probe="$root/.build/debug/medley-probe"
bundle=dev.openmusic.OpenMusicMobile

if [[ "$1" == --remote ]]; then
  what="${2:-both}"
  start=$(date +%s)
  if [[ "$what" != ios ]]; then CONFIG=debug scripts/bundle.sh | tail -1; fi
  swift build --product medley-probe 2>&1 | grep -E "error|Build complete" | tail -2
  clang -fobjc-arc -framework Foundation -framework CoreGraphics scripts/virtual-display.m -o build/virtual-display
  if [[ "$what" != mac ]]; then
    MEDLEY_SLOT="$slot" scripts/ios-sim.sh build | tail -3
    # The VoiceOver check (iOS/CouncilUITests/OnboardingAccessibility.swift) runs from its own test build.
    xcodebuild build-for-testing -project iOS/MedleyMobile.xcodeproj -scheme MedleyMobile -configuration Debug \
      -destination "generic/platform=iOS Simulator" -derivedDataPath build/onb-ui-dd > build/onb-ui-build.log 2>&1 \
      || { grep -E "error:" build/onb-ui-build.log | head; echo "UI test build failed" >&2; }
  fi
  echo "built in $(( $(date +%s) - start )) s; waiting for $lock"
  lockf -t 2400 "$lock" "$0" --capture "$what"
  echo "done in $(( $(date +%s) - start )) s"
  exit 0
fi

# --capture
what="${2:-both}"
# shellcheck disable=SC1091
. "$base/accounts"
[[ -n "${MAC_EMAIL:-}" && -s "$base/jwt-mac.txt" ]] || { echo "no test accounts in $base" >&2; exit 2; }
rm -rf "${out:?}"
mkdir -p "$out/mac" "$out/iphone" "$out/logs" "$out/run"
run="$out/run"
results="$out/results.txt"
: > "$results"
vd="" u="" data="" defaults_saved=""
saved_state="$HOME/Library/Saved Application State/dev.openmusic.OpenMusic.savedState"

say() { echo "-- $(date +%T) $*"; }
pass() { echo "PASS $*" | tee -a "$results"; }
fail() { echo "FAIL $*" | tee -a "$results"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
lines() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# Probe devices: P <state-name> <jwt: mac|ios> <device name> <platform> <command…>
P() {
  local st="$1" jwt="$2" name="$3" platform="$4"; shift 4
  "$probe" sync "$@" --state "$run/probe-$st.json" --jwt-file "$base/jwt-$jwt.txt" --name "$name" --platform "$platform" \
    >> "$out/logs/probe-$st.log" 2>&1
}

# ---- Mac helpers (the run's directory: its log, command file, Keychain files and state)
mdir="$run/mac"
maclog="$mdir/synctest.log"
mac_from=0
use_mac_dir() { mdir="$1"; maclog="$mdir/synctest.log"; mac_from=0; }
mcmd() { echo "openmusic://test/$1" >> "$mdir/synctest-cmd.txt"; }
msnap() { mac_from=$(lines "$maclog"); }
mwait() { # PATTERN SECONDS: in lines added since the last msnap
  local pat="$1" secs="${2:-20}"
  for _ in $(seq 1 $((secs * 4))); do
    # A new hub (after Use This Server) starts the log again.
    (( $(lines "$maclog") < mac_from )) && mac_from=0
    tail -n +"$((mac_from + 1))" "$maclog" 2>/dev/null | grep -qE "$pat" && return 0
    sleep 0.25
  done
  echo "!! Mac: timed out waiting for: $pat"; return 1
}
mlast() { tail -n +"$((mac_from + 1))" "$maclog" 2>/dev/null | grep -E "$1" | tail -1; }
mshot() { # NAME [main|stack|sheet] [light|dark|both]
  local name="$1" w="${2:-main}" modes="${3:-both}" m
  [[ "$modes" == both ]] && modes="light dark"
  for m in $modes; do
    mcmd "appearance?mode=$m"; sleep 1.3
    mcmd "shot?name=$name-$m&w=$w"; sleep 1
    [[ -f "$mdir/shots/$name-$m.png" ]] && cp "$mdir/shots/$name-$m.png" "$out/mac/" || fail "Mac shot $name-$m"
  done
  mcmd "appearance?mode=light"; sleep 0.5
}
mfr() { mcmd "firstrun?$1"; sleep "${2:-1.2}"; }
# VoiceOver: every control on screen has a label (AX audit lines in the app's log).
max() { msnap; mcmd "ax${2:+?scope=$2}"; if mwait "AX audit: " 10; then
  local line; line="$(mlast "AX audit: ")"
  if [[ "$line" == *" 0 without a label"* && "$line" != *"audit: 0 controls"* ]]; then pass "Mac VoiceOver labels ($1): ${line##*AX audit: }"; else fail "Mac VoiceOver labels ($1): ${line##*AX audit: }"; fi
  else fail "Mac VoiceOver audit ($1) didn't run"; fi; }

# ---- iPhone helpers
ioslog=/dev/null
ios_from=0
icmd() { echo "openmusic://test/$1" >> "$data/Documents/synctest-cmd.txt"; }
isnap() { ios_from=$(lines "$ioslog"); }
iwait() {
  local pat="$1" secs="${2:-20}"
  for _ in $(seq 1 $((secs * 4))); do
    (( $(lines "$ioslog") < ios_from )) && ios_from=0
    tail -n +"$((ios_from + 1))" "$ioslog" 2>/dev/null | grep -qE "$pat" && return 0
    sleep 0.25
  done
  echo "!! iPhone: timed out waiting for: $pat"; return 1
}
ilast() { tail -n +"$((ios_from + 1))" "$ioslog" 2>/dev/null | grep -E "$1" | tail -1; }
ishot() { # NAME [light|dark|both]
  local name="$1" modes="${2:-both}" m
  [[ "$modes" == both ]] && modes="light dark"
  for m in $modes; do
    xcrun simctl ui "$u" appearance "$m"; sleep 1.4
    xcrun simctl io "$u" screenshot --type=png "$out/iphone/$name-$m.png" >/dev/null 2>&1 || fail "iPhone shot $name-$m"
  done
  xcrun simctl ui "$u" appearance light; sleep 0.4
}
ifr() { icmd "firstrun?$1"; sleep "${2:-1.4}"; }

quit_mac() { pkill -TERM -f "$exe" 2>/dev/null || true; sleep 2; pkill -KILL -f "$exe" 2>/dev/null || true; }

cleanup() {
  set +e
  # Nothing left on the test accounts: the apps sign out, the probes too.
  if pgrep -qf "$exe"; then mcmd signout-account; sleep 4; fi
  if [[ -n "$data" ]]; then icmd signout-account; sleep 4; fi
  pkill -f "medley-probe sync fake-play" 2>/dev/null
  for st in mac-holder mac-ipad ios-holder ios-ipad; do
    [[ -s "$run/probe-$st.json" ]] || continue
    case "$st" in mac-*) j=mac ;; *) j=ios ;; esac
    P "$st" "$j" "cleanup" ios sign-out
  done
  quit_mac
  if [[ -n "$u" ]]; then
    [[ -f "$ioslog" ]] && cp "$ioslog" "$out/logs/iphone-synctest-last.log"
    xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1
    xcrun simctl ui "$u" content_size large >/dev/null 2>&1
    xcrun simctl shutdown "$u" >/dev/null 2>&1
  fi
  [[ -n "$vd" ]] && { kill "$vd" 2>/dev/null; wait "$vd" 2>/dev/null; }
  if [[ -n "$defaults_saved" ]]; then
    defaults delete dev.openmusic.OpenMusic >/dev/null 2>&1
    [[ -s "$base/defaults-backup.plist" ]] && defaults import dev.openmusic.OpenMusic "$base/defaults-backup.plist"
    rm -rf "${saved_state:?}"
    [[ -d "$base/saved-state-backup" ]] && ditto "$base/saved-state-backup" "$saved_state"
    rm -rf "${base:?}/saved-state-backup" "${base:?}/defaults-backup.plist"
  fi
  # Logs only come back; the runs' state, Keychain files and probe tokens stay out of what is pulled.
  for f in "$run"/*/synctest.log; do [[ -f "$f" ]] && cp "$f" "$out/logs/$(basename "$(dirname "$f")")-synctest.log"; done
  rm -rf "${run:?}"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# A fresh Mac install: no preferences (backed up once first), no saved window state. The self-test keeps every
# Keychain account in files of its own, so the Mac's real sign-ins are never read or touched.
fresh_mac() {
  if [[ -z "$defaults_saved" ]]; then
    rm -rf "${base:?}/saved-state-backup" "${base:?}/defaults-backup.plist"
    defaults export dev.openmusic.OpenMusic "$base/defaults-backup.plist" 2>/dev/null || true
    [[ -d "$saved_state" ]] && ditto "$saved_state" "$base/saved-state-backup"
    defaults_saved=1
  fi
  defaults delete dev.openmusic.OpenMusic >/dev/null 2>&1 || true
  rm -rf "${saved_state:?}"
}
launch_mac() { # <run dir> <device name>
  use_mac_dir "$1"
  mkdir -p "$mdir"
  open -n -F "$app" --args -MedleySyncSelfTest YES -MedleySyncDir "$mdir" -MedleySyncState "$mdir/state.json" \
    -MedleySyncDeviceName "$2"
  for _ in $(seq 1 80); do grep -q STARTED "$maclog" 2>/dev/null && break; sleep 0.5; done
}

# ---------------------------------------------------------------- Mac
mac_run() {
  local sw sh mac_code probe_code first
  read -r sw sh < <(osascript -l JavaScript -e 'ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.frame; Math.round(f.size.width) + " " + Math.round(f.size.height)' 2>/dev/null || echo "1920 1080")
  build/virtual-display "${sw:-1920}" "${sh:-1080}" 2400 &
  vd=$!
  sleep 3

  say "Mac: the probe signs in first and makes the account's key (the holder, \"Riley's iPhone\")"
  P mac-holder mac "Riley's iPhone" ios sign-in || fail "probe sign-in (Mac account)"
  P mac-holder mac "Riley's iPhone" ios keys || true
  if grep -q "vault key: available" "$out/logs/probe-mac-holder.log"; then pass "Mac account: the probe holds the key"; else fail "Mac account: the probe has no key: $(tail -2 "$out/logs/probe-mac-holder.log")"; fi

  say "Mac: fresh install"
  quit_mac
  fresh_mac
  launch_mac "$run/mac" "Riley's Mac"
  first="$mdir"
  mcmd "window?w=1200&h=780"; sleep 4
  check "Mac fresh install opens on Welcome" "grep -q 'FIRSTRUN step=welcome' '$maclog'"
  mshot 01-welcome
  max welcome

  say "Mac: keyboard: Return on Welcome, Escape on Your music, Tab"
  msnap; mcmd "key?k=return"; if mwait "KEY return → .*step music" 6; then pass "Mac: Return on Welcome is Get Started"; else fail "Mac: Return on Welcome: $(mlast KEY)"; fi
  msnap; mcmd "key?k=escape"; if mwait "KEY escape → .*step welcome" 6; then pass "Mac: Escape on Your music goes back"; else fail "Mac: Escape on Your music: $(mlast KEY)"; fi
  msnap; mcmd "key?k=return"; mwait "KEY return → .*step music" 6 || true
  for _ in 1 2 3 4; do mcmd "key?k=tab"; sleep 0.7; done
  mshot 02-music-fresh
  max "your music"
  mcmd "window?w=900&h=560"; sleep 1.5
  mshot 02-music-fresh-min main light
  mcmd "window?w=1200&h=780"; sleep 1.5

  say "Mac: YouTube Music's own sign-in sheet, then signed in (a Debug test sign-in) and Spotify connected"
  mfr "do=signin-youtube" 5
  mshot 03-youtube-signin-sheet stack light
  mfr "do=close-signin" 1.5
  # Signed-in rows as a listener sees them after Sign in with Google and Connect (Debug: no real sign-in needed).
  mfr "preview=$(enc "youtubeMusic:Riley Calder,spotify:riley.calder")" 1.5
  mshot 04-music-signed-in
  check "Mac: Your music marks both services done with the account name" "grep FIRSTRUN '$maclog' | tail -1 | grep -q 'youtube=signed in as Riley Calder spotify=signed in as riley.calder'"
  mfr "preview=" 0.8
  mfr "do=youtube-without" 1.5
  mshot 05-music-without-account main light
  check "Mac: Use without an account counts as ready" "grep FIRSTRUN '$maclog' | tail -1 | grep -q 'youtube=without-account'"

  say "Mac: Sync, empty"
  msnap; mfr "do=continue" 2.5
  mwait "FIRSTRUN step=sync" 5 || fail "Mac: Continue didn't open Sync"
  mshot 06-sync-empty
  max sync
  mcmd "window?w=900&h=560"; sleep 1.5
  mshot 06-sync-empty-min
  mcmd "window?w=1200&h=780"; sleep 1.5
  mcmd "key?k=tab"; sleep 0.7; mcmd "key?k=shift-tab"; sleep 0.7

  say "Mac: Use your own server: field, failure, checking, success"
  msnap; mfr "do=server" 2
  mshot 07-server-field main light
  mfr "do=guide" 1.5
  mshot 07-server-guide stack
  mfr "do=close-guide" 1.2
  mfr "server=$(enc "sync.example.invalid/path")" 0.6; mfr "do=check" 2
  mshot 08-server-failure-address main light
  mfr "server=$(enc "https://openmusic-nope.invalid")" 0.6; msnap; mfr "do=check" 0.1
  mwait "server=failed" 25 || true
  sleep 0.5
  mshot 08-server-failure
  # A host that never answers: the check stays in progress long enough to see it.
  mfr "server=$(enc "https://10.255.255.1")" 0.6; mfr "do=check" 1.5
  mshot 09-server-checking main light
  check "Mac: Check shows its progress" "grep FIRSTRUN '$maclog' | tail -1 | grep -q 'server=checking'"
  mfr "server=$(enc "https://sensible-barracuda-214.convex.cloud")" 0.6; msnap; mfr "do=check" 0.2
  if mwait "server=reachable" 25; then pass "Mac: the dev server checks out (reachable and set up)"; else fail "Mac: dev server check: $(mlast FIRSTRUN)"; fi
  sleep 0.8
  mshot 10-server-success
  max "own server"
  msnap; mfr "do=use" 0.2
  if mwait "FIRSTRUN step=sync" 30; then pass "Mac: Use This Server switches and goes back to Sync"; else fail "Mac: Use This Server: $(mlast FIRSTRUN)"; fi
  sleep 5

  say "Mac: email code: sent, wrong code, code entered"
  msnap
  mcmd "type?text=$(enc "$MAC_EMAIL")&submit=1"
  mwait "TYPE " 10 || fail "Mac: typing the email (focus: $(mlast 'TYPE'))"
  if mwait "code=sent" 25; then pass "Mac: Send Code from the keyboard"; else fail "Mac: Send Code: $(mlast FIRSTRUN)"; fi
  sleep 1
  mshot 11-sync-code-sent
  msnap; mcmd "type?text=111111"
  if mwait "error=[^n]" 25; then pass "Mac: a wrong code shows an inline error"; else fail "Mac: wrong code: $(mlast FIRSTRUN)"; fi
  sleep 0.6
  mshot 12-sync-code-wrong
  msnap; mcmd "type?text=$(enc "424 242")"; sleep 0.3
  mshot 13-sync-code-entered main light
  if mwait "ACCOUNT signed in to sync as" 45; then pass "Mac: signed in with the email code (pasted with a space) and registered"; else fail "Mac: sign-in: $(mlast 'ACCOUNT|FIRSTRUN')"; fi

  say "Mac: Approve this device (the holder is the probe, offline)"
  if mwait "FIRSTRUN step=approve" 25; then pass "Mac: a second device of the account goes to Approve this device"; else fail "Mac: no Approve step: $(mlast FIRSTRUN)"; fi
  sleep 1.5
  mshot 14-approve-waiting
  say "Mac: the holder comes online and answers: both show a code"
  msnap
  for _ in 1 2 3 4 5 6; do
    P mac-holder mac "Riley's iPhone" ios keys || true
    mlast "KEYSTATUS" | grep -q "comparing" && break
    sleep 1
  done
  mwait "KEYSTATUS comparing code" 20 || fail "Mac never got a code to compare"
  mac_code=$(mlast "KEYSTATUS comparing" | sed -nE 's/.*comparing code ([0-9]{3} ?[0-9]{3}).*/\1/p')
  probe_code=$(grep -E "REQUEST .*code" "$out/logs/probe-mac-holder.log" | tail -1 | sed -nE 's/.*code ([0-9]{3} ?[0-9]{3}).*/\1/p')
  if [[ -n "$mac_code" && "$mac_code" == "$probe_code" ]]; then pass "Mac and the holder show the same code ($mac_code)"; else fail "codes: Mac \"$mac_code\", holder \"$probe_code\""; fi
  sleep 1
  mshot 15-approve-code
  max approve
  mcmd "window?w=900&h=560"; sleep 1.5
  mshot 15-approve-code-min main light
  mcmd "window?w=1200&h=780"; sleep 1.5
  msnap; mfr "do=codes-match" 1.5
  mshot 16-approve-codes-matched main light
  P mac-holder mac "Riley's iPhone" ios allow all || fail "the holder's Allow"
  if mwait "KEYSTATUS available" 30; then pass "Mac took the key after Allow and Codes Match"; else fail "Mac key: $(mlast KEYSTATUS)"; fi
  if mwait "FIRSTRUN closed" 10; then pass "Mac: approved, it lands on Home by itself"; else fail "Mac: the flow didn't close after approval: $(mlast FIRSTRUN)"; fi
  sleep 0.6
  mshot 17-home-approved main light

  say "Mac: Done: Home, and the holder plays, so the Continue banner shows"
  P mac-holder mac "Riley's iPhone" ios fake-play --ytm "daft punk discovery" --seconds 900 &
  if mwait "BANNER Continue from Riley's iPhone: \"[^(]" 90; then pass "Mac: Home shows Continue from Riley's iPhone with the song"; else fail "Mac: Continue banner: $(mlast BANNER)"; fi
  sleep 6
  mshot 18-home-continue
  mcmd "window?w=900&h=560"; sleep 2
  mshot 18-home-continue-min main light
  mcmd "window?w=1200&h=780"; sleep 1.5

  say "Mac: the holder's prompt: another device (\"Riley's iPad\") asks this Mac"
  # The probe playing for the banner holds the key too and would answer the iPad first: only this Mac answers.
  pkill -f "medley-probe sync fake-play" 2>/dev/null || true
  sleep 2
  msnap
  P mac-ipad mac "Riley's iPad" ios sign-in || fail "second probe sign-in"
  for _ in 1 2 3 4 5 6; do
    P mac-ipad mac "Riley's iPad" ios keys || true
    mlast "KEYREQUESTS" | grep -q "Riley's iPad code" && break
    sleep 1
  done
  if mwait "PRESENTED pending=Riley's iPad on screen: .*sheet" 20; then pass "Mac shows the Allow alert as the holder"; else fail "Mac holder alert: $(mlast PRESENTED)"; fi
  sleep 1
  mshot 19-holder-prompt stack
  max "holder alert" sheet
  mcmd allow; sleep 2
  P mac-ipad mac "Riley's iPad" ios confirm || true
  if grep -q "vault key: available" "$out/logs/probe-mac-ipad.log"; then pass "Allow on the Mac gave Riley's iPad the key"; else fail "Riley's iPad key: $(tail -1 "$out/logs/probe-mac-ipad.log")"; fi
  P mac-ipad mac "Riley's iPad" ios sign-out || true

  say "Mac: relaunch: no first-run flow"
  quit_mac
  launch_mac "$first" "Riley's Mac"
  sleep 5
  check "Mac: a relaunch after finishing shows no first-run flow" "[[ \$(grep -c 'FIRSTRUN step=' '$maclog') -eq 0 ]]"
  mcmd signout-account; sleep 5
  quit_mac

  say "Mac: the skip paths: Not Now on Sync, then Do This Later on Approve"
  fresh_mac
  launch_mac "$run/mac-skip" "Riley's Mac"
  mcmd "window?w=1200&h=780"; sleep 3
  mfr "do=getstarted"; mfr "do=youtube-without"; mfr "do=continue" 2
  msnap; mfr "do=notnow" 2
  if mwait "FIRSTRUN closed" 8; then pass "Mac: Not Now on Sync lands on Home"; else fail "Mac: Not Now: $(mlast FIRSTRUN)"; fi
  sleep 6
  mshot 20-home-after-not-now main light
  quit_mac
  launch_mac "$run/mac-skip" "Riley's Mac"
  sleep 5
  check "Mac: relaunch after Not Now shows no first-run flow" "[[ \$(grep -c 'FIRSTRUN step=' '$maclog') -eq 0 ]]"
  quit_mac
  # Do This Later: a fresh install of a second Mac on the same account, which has holders.
  fresh_mac
  launch_mac "$run/mac-later" "Riley's MacBook Air"
  mcmd "window?w=1200&h=780"; sleep 3
  mfr "do=getstarted"; mfr "do=youtube-without"; mfr "do=continue" 2
  mfr "email=$(enc "$MAC_EMAIL")" 0.5; msnap; mfr "do=send" 0.2
  mwait "code=sent" 25 || fail "Mac (second): Send Code"
  mfr "code=424242" 0.2
  mwait "FIRSTRUN step=approve" 45 || fail "Mac (second): no Approve step: $(mlast FIRSTRUN)"
  pkill -f "medley-probe sync fake-play" 2>/dev/null || true
  msnap; mfr "do=later" 2
  if mwait "FIRSTRUN closed" 8; then pass "Mac: Do This Later lands on Home"; else fail "Mac: Do This Later: $(mlast FIRSTRUN)"; fi
  if mwait "BANNER approve this Mac" 150; then pass "Mac: a quiet Approve banner stays after Do This Later"; else fail "Mac: no approval banner: $(mlast BANNER)"; fi
  sleep 3
  mshot 21-home-approve-later
  mcmd signout-account; sleep 5
  quit_mac
  P mac-holder mac "Riley's iPhone" ios sign-out || true
  [[ -n "$vd" ]] && { kill "$vd" 2>/dev/null || true; wait "$vd" 2>/dev/null || true; vd=""; }
}

# ---------------------------------------------------------------- iPhone
ios_launch() { xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1 || true; xcrun simctl launch "$u" "$bundle" -MedleySyncSelfTest YES -MedleySyncDeviceName "Riley's iPhone" "$@" >/dev/null; }
ios_fresh() { # erase, boot, install: a fresh iPhone
  xcrun simctl shutdown "$u" >/dev/null 2>&1 || true
  xcrun simctl erase "$u"
  xcrun simctl boot "$u" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$u" -b >/dev/null 2>&1 || true
  xcrun simctl status_bar "$u" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState discharging --batteryLevel 100 >/dev/null 2>&1 || true
  xcrun simctl spawn "$u" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true >/dev/null 2>&1 || true
  xcrun simctl install "$u" "$root/build/ios-dd/Build/Products/Debug-iphonesimulator/OpenMusic.app"
  data="$(xcrun simctl get_app_container "$u" "$bundle" data)"
  ioslog="$data/Documents/synctest.log"
}
ios_wait_start() { for _ in $(seq 1 60); do [[ -s "$ioslog" ]] && break; sleep 0.5; done; sleep 4; ios_from=0; }

ios_run() {
  local ios_code probe_code se
  u="$(MEDLEY_SLOT="$slot" scripts/ios-sim.sh udid)"
  say "iPhone: the probe signs in first (the holder, \"Riley's Mac\")"
  P ios-holder ios "Riley's Mac" mac sign-in || fail "probe sign-in (iPhone account)"
  P ios-holder ios "Riley's Mac" mac keys || true

  say "iPhone: skip path on a fresh install: Not Now on Sync, then a relaunch"
  ios_fresh
  ios_launch; ios_wait_start
  check "iPhone fresh install opens on Welcome" "grep -q 'FIRSTRUN step=welcome' '$ioslog'"
  ifr "do=getstarted"; ifr "do=youtube-without"; ifr "do=continue" 2
  isnap; ifr "do=notnow" 2
  if iwait "FIRSTRUN closed" 8; then pass "iPhone: Not Now on Sync lands on Home"; else fail "iPhone: Not Now: $(ilast FIRSTRUN)"; fi
  sleep 5
  ishot 20-home-after-not-now light
  ios_launch; sleep 7; ios_from=0
  check "iPhone: relaunch after Not Now shows no first-run flow" "! grep -q 'FIRSTRUN step=' '$ioslog'"

  say "iPhone: fresh install, the whole flow"
  ios_fresh
  ios_launch; ios_wait_start
  ishot 01-welcome
  ifr "do=getstarted" 1.6
  ishot 02-music-fresh
  ifr "do=signin-youtube" 5
  ishot 03-youtube-signin-sheet light
  ifr "do=close-signin" 1.5
  ifr "preview=$(enc "youtubeMusic:Riley Calder,spotify:riley.calder")" 1.5
  ishot 04-music-signed-in
  check "iPhone: Your music marks both services done with the account name" "grep FIRSTRUN '$ioslog' | tail -1 | grep -q 'youtube=signed in as Riley Calder spotify=signed in as riley.calder'"
  ifr "preview=" 0.8
  ifr "do=youtube-without" 1.5
  ishot 05-music-without-account light
  isnap; ifr "do=continue" 2.2
  iwait "FIRSTRUN step=sync" 5 || fail "iPhone: Continue didn't open Sync"
  ishot 06-sync-empty

  say "iPhone: Use your own server"
  ifr "do=server" 1.8
  ishot 07-server-field light
  ifr "do=guide" 1.6
  ishot 07-server-guide
  ifr "do=close-guide" 1.4
  ifr "server=$(enc "https://openmusic-nope.invalid")" 0.5; isnap; ifr "do=check" 0.1
  iwait "server=failed" 25 || true; sleep 0.5
  ishot 08-server-failure
  ifr "server=$(enc "https://10.255.255.1")" 0.5; ifr "do=check" 1.2
  ishot 09-server-checking light
  ifr "server=$(enc "https://sensible-barracuda-214.convex.cloud")" 0.5; isnap; ifr "do=check" 0.2
  if iwait "server=reachable" 25; then pass "iPhone: the dev server checks out"; else fail "iPhone: dev server check: $(ilast FIRSTRUN)"; fi
  sleep 0.8
  ishot 10-server-success
  isnap; ifr "do=use" 0.2
  if iwait "FIRSTRUN step=sync" 30; then pass "iPhone: Use This Server switches and goes back to Sync"; else fail "iPhone: Use This Server: $(ilast FIRSTRUN)"; fi
  sleep 5

  say "iPhone: email code"
  ifr "email=$(enc "$IOS_EMAIL")" 0.5; isnap; ifr "do=send" 0.2
  if iwait "code=sent" 25; then pass "iPhone: Send Code"; else fail "iPhone: Send Code: $(ilast FIRSTRUN)"; fi
  sleep 2
  ishot 11-sync-code-sent
  isnap; ifr "code=111111" 0.2
  if iwait "error=[^n]" 25; then pass "iPhone: a wrong code shows an inline error"; else fail "iPhone: wrong code: $(ilast FIRSTRUN)"; fi
  sleep 0.6
  ishot 12-sync-code-wrong
  isnap; ifr "code=$(enc "424 242")" 0.3
  ishot 13-sync-code-entered light
  if iwait "ACCOUNT signed in to sync as" 45; then pass "iPhone: signed in with the email code (pasted with a space) and registered"; else fail "iPhone: sign-in: $(ilast 'ACCOUNT|FIRSTRUN')"; fi

  say "iPhone: Approve this device"
  if iwait "FIRSTRUN step=approve" 25; then pass "iPhone: a second device of the account goes to Approve this device"; else fail "iPhone: no Approve step: $(ilast FIRSTRUN)"; fi
  sleep 1.5
  ishot 14-approve-waiting
  isnap
  for _ in 1 2 3 4 5 6; do
    P ios-holder ios "Riley's Mac" mac keys || true
    ilast "KEYSTATUS" | grep -q "comparing" && break
    sleep 1
  done
  iwait "KEYSTATUS comparing code" 20 || fail "iPhone never got a code to compare"
  ios_code=$(ilast "KEYSTATUS comparing" | sed -nE 's/.*comparing code ([0-9]{3} ?[0-9]{3}).*/\1/p')
  probe_code=$(grep -E "REQUEST .*code" "$out/logs/probe-ios-holder.log" | tail -1 | sed -nE 's/.*code ([0-9]{3} ?[0-9]{3}).*/\1/p')
  if [[ -n "$ios_code" && "$ios_code" == "$probe_code" ]]; then pass "iPhone and the holder show the same code ($ios_code)"; else fail "codes: iPhone \"$ios_code\", holder \"$probe_code\""; fi
  sleep 1
  ishot 15-approve-code
  xcrun simctl ui "$u" content_size accessibility-extra-extra-extra-large; sleep 2.5
  ishot 15-approve-code-ax5 light
  xcrun simctl ui "$u" content_size large; sleep 1.5
  isnap; ifr "do=codes-match" 1.5
  ishot 16-approve-codes-matched light
  P ios-holder ios "Riley's Mac" mac allow all || fail "the holder's Allow (iPhone)"
  if iwait "KEYSTATUS available" 30; then pass "iPhone took the key after Allow and Codes Match"; else fail "iPhone key: $(ilast KEYSTATUS)"; fi
  if iwait "FIRSTRUN closed" 10; then pass "iPhone: approved, it lands on Home by itself"; else fail "iPhone: the flow didn't close after approval: $(ilast FIRSTRUN)"; fi
  sleep 0.5
  ishot 17-home-approved light

  say "iPhone: Done: Home with the Continue banner"
  P ios-holder ios "Riley's Mac" mac fake-play --ytm "daft punk discovery" --seconds 900 &
  if iwait "BANNER Continue from Riley's Mac: \"[^(]" 90; then pass "iPhone: Home shows Continue from Riley's Mac with the song"; else fail "iPhone: Continue banner: $(ilast BANNER)"; fi
  sleep 6
  ishot 18-home-continue

  say "iPhone: the holder's prompt"
  pkill -f "medley-probe sync fake-play" 2>/dev/null || true
  sleep 2
  isnap
  P ios-ipad ios "Riley's iPad" ios sign-in || fail "second probe sign-in (iPhone account)"
  for _ in 1 2 3 4 5 6; do
    P ios-ipad ios "Riley's iPad" ios keys || true
    ilast "KEYREQUESTS" | grep -q "Riley's iPad code" && break
    sleep 1
  done
  if iwait "PRESENTED pending=Riley's iPad on screen: .+" 20; then pass "iPhone shows the Allow alert as the holder"; else fail "iPhone holder alert: $(ilast PRESENTED)"; fi
  sleep 1.2
  ishot 19-holder-prompt
  icmd allow; sleep 2
  P ios-ipad ios "Riley's iPad" ios confirm || true
  P ios-ipad ios "Riley's iPad" ios sign-out || true
  pkill -f "medley-probe sync fake-play" 2>/dev/null || true

  say "iPhone: relaunch: no first-run flow"
  cp "$ioslog" "$out/logs/iphone-synctest-main.log"
  ios_launch; sleep 7; ios_from=0
  check "iPhone: a relaunch after finishing shows no first-run flow" "! grep -q 'FIRSTRUN step=' '$ioslog'"
  icmd signout-account; sleep 5
  P ios-holder ios "Riley's Mac" mac sign-out || true

  say "iPhone: VoiceOver labels on every step, default and largest text size (XCUITest, fresh install)"
  ios_fresh
  local axlog="$out/logs/onboarding-ax-test.log"
  if timeout 600 env TEST_RUNNER_COUNCIL_OUT="$out/logs" xcodebuild test-without-building -project iOS/MedleyMobile.xcodeproj \
      -scheme MedleyMobile -destination "id=$u" -derivedDataPath build/onb-ui-dd \
      -only-testing:CouncilUITests/OnboardingAccessibility > "$axlog" 2>&1; then
    pass "iPhone VoiceOver: every control on Welcome, Your music, Sync, Use your own server and the guide has a label, default and AX5 ($(grep -c 'controls$' "$out/logs/onboarding-ax.txt" 2>/dev/null || echo 0) screens audited, nothing off screen)"
  else
    fail "iPhone VoiceOver XCUITest: $(grep -E "error: -\[|XCTAssert|failed" "$axlog" | head -3 | tr '\n' ' ')"
  fi

  say "iPhone: the largest accessibility text size (fresh install, signed out)"
  ios_fresh
  xcrun simctl ui "$u" content_size accessibility-extra-extra-extra-large
  ios_launch; ios_wait_start
  ishot 22-welcome-ax5 light
  ifr "do=getstarted" 1.6; ishot 23-music-ax5 light
  ifr "do=youtube-without"; ifr "do=continue" 2; ishot 24-sync-ax5 light
  xcrun simctl ui "$u" content_size large
  xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl shutdown "$u" >/dev/null 2>&1 || true

  say "iPhone: an SE-sized screen"
  se="$(xcrun simctl create agent-medley-onb-se "iPhone SE (3rd generation)" 2>/dev/null || xcrun simctl create agent-medley-onb-se "iPhone 16e")"
  u="$se"
  ios_fresh
  ios_launch; ios_wait_start
  ishot 30-se-welcome light
  ifr "do=getstarted" 1.6; ishot 31-se-music light
  ifr "do=youtube-without"; ifr "do=continue" 2; ishot 32-se-sync
  ifr "do=server" 1.6; ifr "server=$(enc "https://openmusic-nope.invalid")" 0.5; isnap; ifr "do=check" 0.1
  iwait "server=failed" 25 || true; sleep 0.5; ishot 33-se-server-failure light
  xcrun simctl ui "$u" content_size accessibility-extra-extra-extra-large; sleep 2.5
  ifr "do=back" 1.5; ishot 34-se-sync-ax5 light
  xcrun simctl ui "$u" content_size large
  xcrun simctl terminate "$u" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl shutdown "$u" >/dev/null 2>&1 || true
  xcrun simctl delete "$se" >/dev/null 2>&1 || true
  u="$(MEDLEY_SLOT="$slot" scripts/ios-sim.sh udid)"
}

if [[ "$what" != ios ]]; then mac_run; fi
if [[ "$what" != mac ]]; then ios_run; fi
echo
echo "== results"
cat "$results"
