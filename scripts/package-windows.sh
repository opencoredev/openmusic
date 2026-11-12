#!/usr/bin/env bash
# Packages the Windows release: a self-contained Release publish in the test VM (scripts/windows-vm.sh publish),
# laid out as a single OpenMusic/ folder with LICENSE and THIRD-PARTY-NOTICES.txt, zipped to
# build/OpenMusic-<version>-windows-x64.zip (version from windows/Directory.Build.props).
#   scripts/package-windows.sh [--no-publish] [out.zip]
# --no-publish packages the slot's existing publish. The notices are written from the license files of every
# package in the publish (windows/scripts/collect-notices.ps1, then scripts/windows-notices.py), which stops when a
# published file can't be traced to OpenMusic or a package. OPENMUSIC_VM_SLOT picks the VM slot, as in windows-vm.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
vm() { scripts/windows-vm.sh vm "$@"; }
SLOT="${OPENMUSIC_VM_SLOT:-win}"
publish=1
if [[ "${1:-}" == --no-publish ]]; then publish=0; shift; fi
version="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' windows/Directory.Build.props)"
[[ -n "$version" ]] || { echo "package-windows: no <Version> in windows/Directory.Build.props" >&2; exit 2; }
out="${1:-build/OpenMusic-$version-windows-x64.zip}"

work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
if (( publish )); then
  scripts/windows-vm.sh publish
else
  # The collector rides along with every push of windows/; send it alone when nothing else is pushed.
  mkdir -p "$work/push/scripts" && cp windows/scripts/collect-notices.ps1 "$work/push/scripts/"
  vm push "$work/push" "$SLOT" >/dev/null
fi
vm ps "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\medley\\$SLOT\\scripts\\collect-notices.ps1 -Checkout C:\\medley\\$SLOT"

vm pull "C:/medley/$SLOT/notices-src" "$work" >/dev/null
vm pull "C:/medley/$SLOT/publish" "$work" >/dev/null
stage="$work/stage/OpenMusic"
mkdir -p "$work/stage"
mv "$work/publish" "$stage"
cp LICENSE "$stage/LICENSE"
python3 -I scripts/windows-notices.py "$work/notices-src" "$stage/THIRD-PARTY-NOTICES.txt"

mkdir -p "$(dirname "$out")"
rm -f -- "$out"
python3 -I - "$work/stage" "$out" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for base, dirs, files in os.walk(stage):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(base, name)
            z.write(path, os.path.relpath(path, stage))
PY
echo "package-windows: $out ($(du -h "$out" | cut -f1), $(python3 -I -c 'import sys, zipfile; print(len(zipfile.ZipFile(sys.argv[1]).namelist()))' "$out") files)"
