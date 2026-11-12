#!/usr/bin/env bash
# Runs the Swift side of the C# cross-language vectors on the build Mac.
#   windows/scripts/swift-vectors.sh <swift checkout> [csharp-vectors.json]
# Copies <swift checkout> (a worktree of the accounts branch) to ~/agents/openmusic-winsync on the build Mac, adds
# tests/OpenMusic.Sync.Tests/Vectors/CSharpVectorTests.swift.txt to its OpenMusicSyncTests there (never to the checkout itself), runs
# `swift test --filter CSharpVectorTests` with 4 jobs, and writes the Swift vectors to
# windows/tests/OpenMusic.Sync.Tests/Vectors/swift-vectors.json. With a C# vectors file, the Swift code also opens what C# sealed.
set -euo pipefail
src="$(cd "${1:?usage: swift-vectors.sh <swift checkout> [csharp-vectors.json]}" && pwd)"
csharp="${2:-}"
here="$(cd "$(dirname "$0")/.." && pwd)"
remote="agents/openmusic-winsync"
. "$here/../scripts/env.sh"
need OPENMUSIC_MAC_HOST
host="$OPENMUSIC_MAC_HOST"
remote_run "$host" "mkdir -p ~/${remote}" >/dev/null
rsync -az --delete --exclude-from="$src/scripts/rsync-excludes.txt" --exclude windows \
  -e "ssh -o BatchMode=yes" "$src/" "${host}:${remote}/"
scp -q -o BatchMode=yes "$here/tests/OpenMusic.Sync.Tests/Vectors/CSharpVectorTests.swift.txt" "${host}:${remote}/Tests/OpenMusicSyncTests/CSharpVectorTests.swift"
env=""
if [[ -n "$csharp" ]]; then
  scp -q -o BatchMode=yes "$csharp" "${host}:${remote}/csharp-vectors.json"
  env="OPENMUSIC_CSHARP_VECTORS=\$HOME/${remote}/csharp-vectors.json"
fi
remote_run "$host" "set -o pipefail; cd ~/${remote} && ${env} OPENMUSIC_VECTORS_OUT=\$HOME/${remote}/swift-vectors.json swift test --jobs 4 --filter CSharpVectorTests 2>&1 | grep -E '✔|✘|OPENMUSIC-CSHARP|error:|recorded an issue'"
scp -q -o BatchMode=yes "${host}:${remote}/swift-vectors.json" "$here/tests/OpenMusic.Sync.Tests/Vectors/swift-vectors.json"
echo "wrote $here/tests/OpenMusic.Sync.Tests/Vectors/swift-vectors.json"
