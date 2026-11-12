#!/usr/bin/env bash
# Regenerates windows/tests/OpenMusic.Core.Tests/Fixtures and windows/src/OpenMusic.Core/Mock/DemoCatalogData.json with the real
# Swift model sources and JSONEncoder (Linux swiftc). Rerun after changing the Swift models or the demo catalog.
#   scripts/windows-fixtures/generate.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
build="$(mktemp -d)"
trap 'rm -rf "${build:?}"' EXIT
src="$root/Sources"
grep -v '^import OpenMusicCore' "$src/OpenMusicSync/Model/SyncModels.swift" > "$build/SyncModels.swift"
# DemoCatalog.swift ends with a MockProvider extension (SwiftUI); leave it out.
sed '/^extension MockProvider/,$d' "$src/OpenMusicCore/Mock/DemoCatalog.swift" > "$build/DemoCatalog.swift"; echo '#endif' >> "$build/DemoCatalog.swift"
{ cat "$here/MockArtworkStub.swift"; sed -n '/^func fnv1a/,$p' "$src/OpenMusicCore/Mock/MockArtwork.swift"; } > "$build/MockArtwork.swift"
swiftc -D DEBUG -O -module-name OpenMusicFixtures -o "$build/fixtures" \
  "$src/OpenMusicCore/Contracts/Models.swift" "$src/OpenMusicCore/Contracts/PlaybackEngine.swift" "$src/OpenMusicCore/Playback/PlaybackModels.swift" \
  "$build/SyncModels.swift" "$build/MockArtwork.swift" \
  "$src/OpenMusicCore/Mock/MockCatalog.swift" "$build/DemoCatalog.swift" "$src/OpenMusicCore/Mock/DemoCatalogData.swift" \
  "$here/main.swift"
"$build/fixtures" "$root/windows/tests/OpenMusic.Core.Tests/Fixtures" "$root/windows/src/OpenMusic.Core/Mock/DemoCatalogData.json"
