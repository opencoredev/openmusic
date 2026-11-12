#!/usr/bin/env bash
# The screens design review looks at: every main Mac screen with the demo data, 2x, 1440x900
# window, light and dark (Sources/OpenMusic/App/CouncilShots.swift). Runs on the build Mac. From the Linux checkout:
#   scripts/mac.sh council 'scripts/council-shots.sh'
#   rsync -az "$OPENMUSIC_MAC_HOST:agents/openmusic-council/build/council/" <dir>/
# Output in build/council: shots/<name>-<light|dark>.png, contact-sheet.png, index.md, council.txt (the app's log).
#
# The build Mac is shared with workers measuring frame timing: the part that adds the 2x virtual display and runs the
# app holds /tmp/medley-ui.lock (lockf), so it never overlaps their runs. Afterwards nothing of this run is left:
# no app process, no virtual display, and the real app's preferences and saved window state are put back.
#   OPENMUSIC_COUNCIL_SHOTS=home,album   only these shots (names as in index.md)
#   OPENMUSIC_DEMO_SIZE=1440x900         main window size in points
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
root="$PWD"
out="$root/build/council"
shots="$out/shots"
art="$root/build/demo-art"
lock=/tmp/medley-ui.lock
mkdir -p "$out"

# Locked part: re-run this script under lockf with the build already done.
if [[ "${1:-}" == "--locked" ]]; then
  vd="" defaults_backup="$out/defaults-backup.plist" saved_state="$HOME/Library/Saved Application State/dev.openmusic.OpenMusic.savedState"
  app_bin="$root/build/OpenMusic.app/Contents/MacOS/OpenMusic"
  cleanup() {
    [[ -n "$vd" ]] && { kill "$vd" 2>/dev/null || true; wait "$vd" 2>/dev/null || true; vd=""; }
    pkill -f "$app_bin" 2>/dev/null || true
    # Keyboard Navigation back as it was, if the second launch was interrupted.
    if declare -F restore_kn >/dev/null; then restore_kn; unset -f restore_kn; fi
    if [[ -f "$out/.defaults-saved" ]]; then
      defaults delete dev.openmusic.OpenMusic >/dev/null 2>&1 || true
      [[ -s "$defaults_backup" ]] && defaults import dev.openmusic.OpenMusic "$defaults_backup"
      rm -rf "${saved_state:?}"
      [[ -d "$out/saved-state-backup" ]] && ditto "$out/saved-state-backup" "$saved_state"
      rm -rf "${out:?}/saved-state-backup" "${out:?}/.defaults-saved" "${out:?}/defaults-backup.plist"
    fi
    return 0
  }
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  # Same size in points as the screen now, so other windows on this shared Mac keep their layout.
  read -r w h < <(osascript -l JavaScript -e 'ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.frame; Math.round(f.size.width) + " " + Math.round(f.size.height)' 2>/dev/null || echo "1920 1080")
  rm -f "${defaults_backup:?}"; rm -rf "${out:?}/saved-state-backup"
  defaults export dev.openmusic.OpenMusic "$defaults_backup" 2>/dev/null || true
  [[ -d "$saved_state" ]] && ditto "$saved_state" "$out/saved-state-backup"
  touch "$out/.defaults-saved"
  # Shots show the layout a new listener gets: no remembered sidebar width or restored window (both put back by cleanup).
  defaults delete dev.openmusic.OpenMusic "NSSplitView Subview Frames main, SidebarNavigationSplitView" >/dev/null 2>&1 || true
  rm -rf "${saved_state:?}"
  # Up for both launches (960 + 240 s at most; cleanup ends it sooner): at 600 s it went away during round 25's
  # signed-out shots, which came out at 1x. The first launch took about 712 s by round 32 and ran past 720 in round 33.
  build/virtual-display "${w:-1920}" "${h:-1080}" 1300 &
  vd=$!
  sleep 3
  status=0
  # Through `open`, so the app starts in the GUI session as the frontmost app and its window is key.
  timeout 960 open -W -n --env OPENMUSIC_MOCK=demo --env OPENMUSIC_DEMO_ART="$art" --env OPENMUSIC_SNAPSHOT_DIR="$shots" \
    --env OPENMUSIC_SNAPSHOT_ONLY=council --env OPENMUSIC_DEMO_SIZE="${OPENMUSIC_DEMO_SIZE:-1440x900}" \
    ${OPENMUSIC_COUNCIL_SHOTS:+--env OPENMUSIC_COUNCIL_SHOTS="$OPENMUSIC_COUNCIL_SHOTS"} build/OpenMusic.app || status=$?
  # Space on focused buttons needs Keyboard Navigation (without it a SwiftUI button takes no focus): a second, short
  # launch with it on. AppKit reads the setting from the global domain only (an argument or app-domain value is
  # ignored), so it is set there for this launch and put back right after, with no change notification, so apps
  # already running keep theirs.
  if [[ "$status" -eq 0 && ( -z "${OPENMUSIC_COUNCIL_SHOTS:-}" || ",$OPENMUSIC_COUNCIL_SHOTS," == *",space-keys,"* ) ]]; then
    kn_before=$(defaults read -g AppleKeyboardUIMode 2>/dev/null || echo none)
    restore_kn() {
      if [[ "$kn_before" == none ]]; then defaults delete -g AppleKeyboardUIMode >/dev/null 2>&1 || true
      else defaults write -g AppleKeyboardUIMode -int "$kn_before"; fi
    }
    defaults write -g AppleKeyboardUIMode -int 2
    timeout 240 open -W -n --env OPENMUSIC_MOCK=demo --env OPENMUSIC_DEMO_ART="$art" --env OPENMUSIC_SNAPSHOT_DIR="$shots" \
      --env OPENMUSIC_SNAPSHOT_ONLY=council --env OPENMUSIC_DEMO_SIZE="${OPENMUSIC_DEMO_SIZE:-1440x900}" \
      --env OPENMUSIC_COUNCIL_SHOTS=space-keys --env OPENMUSIC_COUNCIL_LOG=council-space.txt build/OpenMusic.app || status=$?
    restore_kn; unset -f restore_kn
  fi
  cleanup
  if [[ "$status" -eq 124 ]]; then echo "captures timed out after 960 s" >&2; exit 1; fi
  exit "$status"
fi

start=$(date +%s)
scripts/demo-art.sh "$art"
CONFIG=debug scripts/bundle.sh >/dev/null
clang -fobjc-arc -framework Foundation -framework CoreGraphics scripts/virtual-display.m -o build/virtual-display
swiftc -O scripts/council-sheet.swift -o build/council-sheet 2>&1 | grep -v "^$" || true
rm -rf "${shots:?}"; mkdir -p "$shots"
rm -f "$out/contact-sheet.png" "$out/index.md" "$out/council.txt" "$out/sidebar-rows.txt" "$out/council-space.txt"
echo "waiting for $lock (other workers' frame-timing runs)…"
locked_at=$(date +%s)
lockf -t 1800 "$lock" "$0" --locked
echo "captures took $(( $(date +%s) - locked_at )) s"

[[ -f "$shots/council.txt" ]] || { echo "the app wrote no log" >&2; exit 1; }
mv "$shots/council.txt" "$out/council.txt"
[[ -f "$shots/sidebar-rows.txt" ]] && mv "$shots/sidebar-rows.txt" "$out/sidebar-rows.txt"
if [[ -f "$shots/council-space.txt" ]]; then
  { echo; echo "Keyboard Navigation launch:"; cat "$shots/council-space.txt"; } >> "$out/council.txt"
  mv "$shots/council-space.txt" "$out/council-space.txt"
fi
cat "$out/council.txt"
grep -q "capture failed" "$out/council.txt" && echo "WARNING: some captures failed (see council.txt)" >&2
compgen -G "$shots/*.png" >/dev/null || { echo "no images" >&2; exit 1; }

build/council-sheet "$shots" "$shots/manifest.tsv" "$out/contact-sheet.png"

# index.md: one line per file from the app's manifest, with pixel sizes.
{
  echo "# OpenMusic Mac UI: council capture"
  echo
  echo "Demo data (real chart albums, a made-up listener \"Riley Calder\", \"the cure\" playing 1:12 in), Debug build,"
  echo "main window ${OPENMUSIC_DEMO_SIZE:-1440x900} pt on a 2x display, light and dark. Captured $(date '+%Y-%m-%d %H:%M %Z')"
  echo "from $(git rev-parse --short HEAD 2>/dev/null || echo "an rsynced checkout")."
  echo "Window captures never show the pointer; hover shots have an arrow drawn where it rests."
  echo
  echo "Contact sheet: \`contact-sheet.png\`."
  echo
  while IFS=$'\t' read -r name about; do
    [[ -n "$name" ]] || continue
    for mode in light dark; do
      f="$name-$mode.png"
      [[ -f "$shots/$f" ]] || { echo "- \`shots/$f\`: MISSING"; continue; }
      size=$(sips -g pixelWidth -g pixelHeight "$shots/$f" 2>/dev/null | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')
      echo "- \`shots/$f\` ($size, $mode): $about"
    done
  done < "$shots/manifest.tsv"
} > "$out/index.md"
rm -f "$shots/manifest.tsv"
echo "done in $(( $(date +%s) - start )) s: $out"
