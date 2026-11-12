#!/usr/bin/env bash
# Regenerates windows/tests/Medley.Core.Tests/Fixtures and windows/src/Medley.Core/Mock/DemoCatalogData.json with the real
# Swift model sources and JSONEncoder (Linux swiftc). Rerun after changing the Swift models or the demo catalog.
#   scripts/windows-fixtures/generate.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
build="$(mktemp -d)"
trap 'rm -rf "${build:?}"' EXIT
src="$root/Sources"
grep -v '^import MedleyCore' "$src/MedleySync/Model/SyncModels.swift" > "$build/SyncModels.swift"
# DemoCatalog.swift ends with a MockProvider extension (SwiftUI); leave it out.
sed '/^extension MockProvider/,$d' "$src/MedleyCore/Mock/DemoCatalog.swift" > "$build/DemoCatalog.swift"; echo '#endif' >> "$build/DemoCatalog.swift"
{ cat "$here/MockArtworkStub.swift"; sed -n '/^func fnv1a/,$p' "$src/MedleyCore/Mock/MockArtwork.swift"; } > "$build/MockArtwork.swift"
swiftc -D DEBUG -O -module-name MedleyFixtures -o "$build/fixtures" \
  "$src/MedleyCore/Contracts/Models.swift" "$src/MedleyCore/Contracts/PlaybackEngine.swift" "$src/MedleyCore/Playback/PlaybackModels.swift" \
  "$build/SyncModels.swift" "$build/MockArtwork.swift" \
  "$src/MedleyCore/Mock/MockCatalog.swift" "$build/DemoCatalog.swift" "$src/MedleyCore/Mock/DemoCatalogData.swift" \
  "$here/main.swift"
"$build/fixtures" "$root/windows/tests/Medley.Core.Tests/Fixtures" "$root/windows/src/Medley.Core/Mock/DemoCatalogData.json"
