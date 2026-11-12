#!/usr/bin/env bash
# Council screenshots of OpenMusic for Windows: builds the Debug app in the medley-win VM, drives every main screen in the
# real window through the app's --self-test file, screenshots the VM's screen and crops each PNG to the window's frame
# (title bar, Mica fallback, flyouts and dialogs included).
#   scripts/windows-council-shots.sh <out-dir> [--no-build] [--only demo|live|narrow|onboarding]
# demo: the demo catalog (--demo --demo-sync) in light and dark at 1440x900, plus dialogs with sample data.
# live: YouTube Music and OpenMusic Sync as the VM's app data has them (Home, search, album, Devices, Settings › Account,
#       the YouTube sign-in window), light and dark. Needs network; skips what isn't signed in.
# narrow: Home and an album at 1024x700 (demo), light.
# onboarding: the first run from a fresh install (settings, server choice and secrets deleted first), live against the
#       dev deployment, driven through UI Automation (scripts/windows-uia.ps1, by AutomationId): every step in
#       docs/onboarding.md, light and dark at 1440x900, plus 1024x700. The second device is the
#       C# sync probe ("Riley's iPhone", key holder, playing a song) in OPENMUSIC_ONBOARDING_USER's account; it allows the
#       PC 40 s after the PC asks. Each pass signs the PC out at the end, so the next one is a new device again.
# OPENMUSIC_VM_SLOT picks the VM slot (default council-win). OPENMUSIC_LIVE_ALBUM is the album id for the live album page.
set -euo pipefail
. "$(dirname "$0")/env.sh"
W="${OPENMUSIC_VM:-${OPENMUSIC_WIN_VM:-$HOME/vms/medley-win/win.sh}}"
export OPENMUSIC_VM_SLOT="${OPENMUSIC_VM_SLOT:-council-win}"
SLOT="$OPENMUSIC_VM_SLOT"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?out dir}"; shift
BUILD=1; ONLY=""
while (($#)); do
  case "$1" in
    --no-build) BUILD=0 ;;
    --only) ONLY="$2"; shift ;;
  esac
  shift
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
LIVE_ALBUM="${OPENMUSIC_LIVE_ALBUM:-MPREb_7ltM34kr0mH}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

SELFTEST_TMP="$TMP"
source "$ROOT/scripts/windows-selftest.sh"
shoot() { snap "$OUT/$1.png" "${2:-1.5}" "${3:-main}"; }

reset_view() { st "pane off"; st "nowplaying off"; st "close-devices"; st "close-dialog"; }

if ((BUILD)); then
  echo "build"
  "$ROOT/scripts/windows-vm.sh" build Debug
fi

if [[ -z "$ONLY" || "$ONLY" == demo ]]; then
  for theme in light dark; do
    echo "demo $theme"
    launch "--demo --demo-sync --no-restore --play --position 83 --size 1440x900 --theme $theme"
    st "place 20 20"
    shoot "$theme-continue" 2.5
    st "continue off"
    shoot "$theme-home"
    st "scroll 900"; shoot "$theme-home-scrolled"; st "scroll top"
    st "screen new"; shoot "$theme-new" 2
    st "screen radio"; shoot "$theme-radio" 2
    st "screen search"; shoot "$theme-search" 2
    st "suggest oliv"; shoot "$theme-search-suggestions" 2; st "close-suggestions"
    st "screen album"; shoot "$theme-album" 2
    st "menu track"; shoot "$theme-menu" 1.5; st "close-menu"
    st "pane lyrics"; shoot "$theme-lyrics-pane" 2
    st "pane queue"; shoot "$theme-up-next" 2; st "pane off"
    st "screen artist"; shoot "$theme-artist" 2
    st "screen playlist"; shoot "$theme-playlist" 2
    st "screen songs"; shoot "$theme-songs" 2
    st "screen albums"; shoot "$theme-library-albums" 2
    st "screen album"; st "devices"; shoot "$theme-devices" 2; st "close-devices"
    st "nowplaying"; shoot "$theme-nowplaying" 2.5; st "nowplaying off"
    st "screen settings"; shoot "$theme-settings" 2
    st "welcome"; shoot "$theme-welcome" 2
    st "screen home"
    st "preview signin"; shoot "$theme-signin-email" 1.5; st "close-dialog"
    st "preview signin-code"; shoot "$theme-signin-code" 1.5; st "close-dialog"
    st "preview compare"; shoot "$theme-compare" 1.5; st "close-dialog"
    st "preview allow"; shoot "$theme-allow" 1.5; st "close-dialog"
    st "mini"; shoot "$theme-mini" 2 mini; st "mini off"
    st quit
  done
fi

if [[ -z "$ONLY" || "$ONLY" == narrow ]]; then
  echo "narrow"
  launch "--demo --no-restore --play --position 83 --size 1024x700 --theme light"
  st "place 20 20"
  shoot "light-narrow-home" 2
  st "screen album"; st "pane lyrics"; shoot "light-narrow-album-lyrics" 2
  st quit
fi

if [[ "$ONLY" == onboarding ]]; then
  # One test account per pass (user-<pass>.json: a +clerk_test email), each with its own holder probe: a holder answers
  # at most six requests an hour and pauses after failed exchanges, so one account per pass keeps rounds independent.
  ONB_USERS="${OPENMUSIC_ONBOARDING_USERS:-$HOME/.config/openmusic/onb-win}"
  ONB_PROBE="${OPENMUSIC_ONBOARDING_PROBE:-$HOME/medley-council/onboarding/windows/probe}"
  DEV_URL="https://sensible-barracuda-214.convex.cloud"
  export OPENMUSIC_UIA_PUSHED=0
  ui() { "$ROOT/scripts/windows-vm.sh" uia "$@" >/dev/null || { echo "  uia failed: $*" >&2; SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1)); }; export OPENMUSIC_UIA_PUSHED=1; }
  # Waits (up to 40 s) until a control is on screen.
  ui_wait() { local i; for i in $(seq 1 20); do [[ "$("$ROOT/scripts/windows-vm.sh" uia exists "$1")" == yes ]] && return 0; sleep 1; done; echo "  never appeared: $1" >&2; SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1)); }
  reset_first_run() {
    "$W" kill OpenMusic >/dev/null
    "$W" ps '$o="$env:LOCALAPPDATA\OpenMusic"; Remove-Item "$o\settings.json","$o\server.json","$o\queue.json" -ErrorAction SilentlyContinue; Remove-Item "$o\secrets\*" -ErrorAction SilentlyContinue; exit 0' >/dev/null
  }
  (cd "$ROOT/windows" && ~/.dotnet/dotnet build src/OpenMusic.SyncProbe -nologo -v q >/dev/null)
  start_probe() { # <pass>
    mkdir -p "$ONB_PROBE"; chmod 700 "$ONB_PROBE"
    ~/.dotnet/dotnet "$ROOT/windows/src/OpenMusic.SyncProbe/bin/Debug/net10.0/OpenMusic.SyncProbe.dll" run --user-file "$ONB_USERS/user-$1.json" \
      --state "$ONB_PROBE/iphone-$1" --name "Riley's iPhone" --platform ios --play --track "FGBhQbmPwH8|One More Time|Daft Punk|322" \
      --script "wait-request; sleep 40; allow all" --seconds 600 >> "$ONB_PROBE/iphone-$1.log" 2>&1 &
    probe_pid=$!
    sleep 6
  }
  # One pass: <theme> <WxH> <prefix> full|short
  onboarding_pass() {
    local theme="$1" size="$2" p="$3" depth="$4"
    local EMAIL; EMAIL=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['email'])" "$ONB_USERS/user-$p.json")
    reset_first_run
    start_probe "$p"
    SETTLE_LAUNCH=5 launch "--test-sign-ins --size $size --theme $theme"
    st "place 20 20"
    shoot "$p-1-welcome" 1.5
    ui click OnboardingPrimary; shoot "$p-2-music" 1.5
    if [[ "$depth" == full ]]; then
      st "fake-youtube Riley Chen"; shoot "$p-2-music-youtube-signed-in" 1.5; st "youtube-signout"
    fi
    # The footer's "Use without an account" goes straight on to Sync.
    ui click OnboardingPrimary; shoot "$p-3-sync" 1.5
    if [[ "$depth" == full ]]; then
      ui click OnboardingServerLink; shoot "$p-4-server-field" 1
      ui set OnboardingServerUrl "https://10.255.255.1"; ui click OnboardingCheckServer; shoot "$p-4-server-checking" 0.5
      sleep 20
      ui set OnboardingServerUrl "https://example.com"; ui click OnboardingCheckServer; shoot "$p-4-server-failure" 3
      ui set OnboardingServerUrl "$DEV_URL"; ui click OnboardingCheckServer; shoot "$p-4-server-success" 3
      ui click OnboardingUseServer; shoot "$p-4-server-in-use" 3
      # Continue with Apple: Apple's page opens in the browser; the app waits with a way to cancel.
      # Edge opens over the window and Windows won't hand the foreground back: close it, the app keeps waiting.
      ui click OnboardingApple; sleep 5; "$W" ps "Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force; exit 0" >/dev/null
      st "front"; shoot "$p-3-sync-browser-waiting" 1.5
      ui click OnboardingBrowserCancel
    fi
    ui set OnboardingEmail "$EMAIL"; ui click OnboardingSendCode; shoot "$p-3-sync-code-sent" 2.5
    if [[ "$depth" == full ]]; then
      ui set OnboardingCode "000000"; shoot "$p-3-sync-code-wrong" 3
    fi
    ui set OnboardingCode "424 242"; shoot "$p-3-sync-code-entered" 0.8
    ui_wait OnboardingCodesMatch
    shoot "$p-5-approve-compare" 1
    ui click OnboardingCodesMatch; shoot "$p-5-approve-waiting" 1.5
    # The probe allows 40 s after the request; the PC takes the key, then Home.
    local code; code=$(runlog "sync: key comparing" | tail -1 | sed -n 's/.*comparing \([0-9 ]*\) with.*/\1/p' | tr -d ' ')
    sleep 30
    shoot "$p-6-home-continue" 3
    if [[ "$depth" == full ]]; then
      st "preview allow Studio PC|${code:-204617}"; shoot "$p-5-approve-holder-prompt" 1.5; st "close-dialog"
    fi
    st "sync-signout"; sleep 2
    st quit
    kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true
  }
  # OPENMUSIC_ONBOARDING_PASSES picks passes (default all three: light dark narrow).
  for pass in ${OPENMUSIC_ONBOARDING_PASSES:-light dark narrow}; do
    echo "onboarding $pass"
    case "$pass" in
      light) onboarding_pass light 1440x900 light full ;;
      dark) onboarding_pass dark 1440x900 dark short ;;
      narrow) onboarding_pass light 1024x700 narrow short ;;
    esac
  done
  # Relaunch: the first run doesn't come back (the pass above finished it).
  launch "--size 1440x900 --theme light"; st "onboarding-state"; runlog "selftest: onboarding" | tail -1; st quit
fi

if [[ -z "$ONLY" || "$ONLY" == live ]]; then
  # A second device in the test account (OPENMUSIC_PROBE_USER, a +clerk_test user): the C# sync probe on this machine,
  # playing a real song, so Devices, Continue and Play Here are live. Its state (and its approval) persist in
  # OPENMUSIC_PROBE_STATE between rounds.
  PROBE_USER="${OPENMUSIC_PROBE_USER:-$HOME/.config/openmusic/clerk-council-win-user.json}"
  PROBE_STATE="${OPENMUSIC_PROBE_STATE:-$HOME/medley-council/windows/probe}"
  probe_pid=""
  if [[ -f "$PROBE_USER" ]]; then
    mkdir -p "$PROBE_STATE"; chmod 700 "$PROBE_STATE"
    (cd "$ROOT/windows" && ~/.dotnet/dotnet build src/OpenMusic.SyncProbe -nologo -v q >/dev/null)
    ~/.dotnet/dotnet "$ROOT/windows/src/OpenMusic.SyncProbe/bin/Debug/net10.0/OpenMusic.SyncProbe.dll" run --user-file "$PROBE_USER" \
      --state "$PROBE_STATE/iphone-ios" --name "Riley's iPhone" --platform ios --play --track "FGBhQbmPwH8|One More Time|Daft Punk|322" \
      --seconds 900 > "$PROBE_STATE/iphone.log" 2>&1 &
    probe_pid=$!
    sleep 8
  fi
  for theme in light dark; do
    echo "live $theme"
    SETTLE_LAUNCH=10 launch "--size 1440x900 --theme $theme"
    st "place 20 20"
    shoot "$theme-live-continue" 2
    st "continue off"
    shoot "$theme-live-home" 2
    st "suggest daft p"; shoot "$theme-live-search-suggestions" 3; st "close-suggestions"
    st "screen search:daft punk"; shoot "$theme-live-search" 4
    st "screen album:$LIVE_ALBUM"; shoot "$theme-live-album" 4
    st "devices"; shoot "$theme-live-devices" 3
    if [[ "$theme" == light && -n "$probe_pid" ]]; then
      # Play Here: the probe's song (sent without artwork) moves to this PC; the bar must show its artwork.
      st "click PlayHere-RileysiPhone"; sleep 6; st "close-devices"; shoot "$theme-live-handoff" 4
      st "devices"; shoot "$theme-live-devices-after" 2; st "click SendTo-RileysiPhone"; sleep 3
    fi
    st "close-devices"
    st "screen settings"; shoot "$theme-live-settings-account" 3
    st "youtube-signin"; shoot "$theme-live-youtube-signin" 6 youtube; st "close-youtube-signin"
    st quit
  done
  [[ -n "$probe_pid" ]] && kill "$probe_pid" 2>/dev/null || true
fi
"$W" kill OpenMusic >/dev/null
echo "$OUT"
if ((SELFTEST_FAILURES > 0)); then echo "$SELFTEST_FAILURES self-test step(s) failed or timed out: check the shots" >&2; exit 1; fi
