#!/usr/bin/env bash
# Download the demo catalog's artwork (scripts/demo-art.tsv) into a cache directory, once.
#   scripts/demo-art.sh [dir]        default: build/demo-art
# Images come from public sources (Apple's iTunes artwork CDN, Deezer artist photos) and are never committed.
# Point the app at the directory with MEDLEY_DEMO_ART=<dir> (Mac) or -MedleyDemoArt <dir> (iOS Simulator).
set -euo pipefail
cd "$(dirname "$0")/.."
dir="${1:-build/demo-art}"
mkdir -p "$dir"
fetched=0 failed=0
while IFS=$'\t' read -r key url; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  out="$dir/$key.jpg"
  [[ -s "$out" ]] && continue
  if curl -fsSL --retry 3 --max-time 60 -o "$out.part" "$url"; then
    mv "$out.part" "$out"; fetched=$((fetched + 1))
  else
    rm -f "${out:?}.part"; failed=$((failed + 1)); echo "failed: $key" >&2
  fi
done < scripts/demo-art.tsv
echo "demo art: $fetched fetched, $failed failed, $(ls "$dir" | wc -l | tr -d ' ') in $dir"
