#!/usr/bin/env bash
# Build, run and screenshot OpenMusic for Windows in the test VM through its helper (OPENMUSIC_WIN_VM, see windows/README.md).
#   scripts/windows-vm.sh build [Debug|Release]      push windows/ to C:\medley\<slot> and build OpenMusic.App (x64)
#   scripts/windows-vm.sh publish                    self-contained Release publish to C:\medley\<slot>\publish
#   scripts/windows-vm.sh run [args...]              start the built app in the VM's desktop session
#   scripts/windows-vm.sh snapshot <local-dir>       run --snapshot in the VM and copy the PNGs to <local-dir>
#   scripts/windows-vm.sh shot <out.png>             screenshot the VM screen
#   scripts/windows-vm.sh log                        tail the app's log (%LOCALAPPDATA%\OpenMusic\logs\openmusic.log)
#   scripts/windows-vm.sh kill                       stop the app
#   scripts/windows-vm.sh uia <op> <AutomationId> [text]   UI Automation in the desktop session (scripts/windows-uia.ps1):
#                                                    click, set, text, exists, dump; prints the result, fails on ERROR
#   scripts/windows-vm.sh vm <helper args...>       pass a command to the VM helper itself (push, pull, ps, gui, ...)
# OPENMUSIC_VM_SLOT picks the slot (default: win). Pushed files keep the host's mtimes, which the VM reads as older than
# its build output, so `build` touches them after each push to keep incremental builds honest (and drops build output
# dated in the future, which a clock or time-zone jump in the VM leaves behind).
set -euo pipefail
. "$(dirname "$0")/env.sh"
W="${OPENMUSIC_VM:-${OPENMUSIC_WIN_VM:-$HOME/vms/medley-win/win.sh}}"
SLOT="${OPENMUSIC_VM_SLOT:-win}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR='src\OpenMusic.App\bin\x64'
EXE_REL='net10.0-windows10.0.22621.0\win-x64\OpenMusic.exe'
cmd="${1:-}"; shift || true

push() {
  "$W" push "$ROOT/windows" "$SLOT" >/dev/null
  "$W" ps "Get-ChildItem C:\\medley\\$SLOT -Recurse -File -Include *.cs,*.xaml,*.csproj,*.props,*.json,*.sln,*.slnf,*.manifest,*.png,*.ico | Where-Object { \$_.FullName -notmatch '\\\\(bin|obj)\\\\' } | ForEach-Object { \$_.LastWriteTime = Get-Date }"
  # Build output dated in the future (the VM's clock or time zone jumped back) would make every build look up to date:
  # drop the project's bin and obj so the build starts clean.
  "$W" ps "\$late = (Get-Date).AddMinutes(1); Get-ChildItem C:\\medley\\$SLOT -Recurse -Directory -Include bin,obj | Where-Object { Get-ChildItem \$_.FullName -Recurse -File | Where-Object { \$_.LastWriteTime -gt \$late } | Select -First 1 } | ForEach-Object { Remove-Item \$_.FullName -Recurse -Force -ErrorAction SilentlyContinue }; exit 0" >/dev/null
}

case "$cmd" in
  build)
    config="${1:-Debug}"
    "$W" kill OpenMusic >/dev/null
    push
    "$W" ps "Start-Sleep 1; cd C:\\medley\\$SLOT; dotnet build src\\OpenMusic.App\\OpenMusic.App.csproj -c $config -p:Platform=x64 -nologo -clp:NoSummary 2>&1 | Select-String -Pattern ' error |warning MSB3|Build succeeded|Time Elapsed' | ForEach-Object { \$_.Line } | Sort-Object -Unique" ;;
  publish)
    "$W" kill OpenMusic >/dev/null
    push
    "$W" ps "Start-Sleep 1; cd C:\\medley\\$SLOT; if (Test-Path publish) { Remove-Item publish -Recurse -Force }; \$o = dotnet publish src\\OpenMusic.App\\OpenMusic.App.csproj -c Release -r win-x64 -p:Platform=x64 -o publish -nologo 2>&1; \$code = \$LASTEXITCODE; \$o | Select-String -Pattern ' error |OpenMusic.App ->' | ForEach-Object { \$_.Line }; if (\$code -ne 0) { 'publish failed (dotnet exit ' + \$code + ')'; exit 1 }; \$s = (Get-ChildItem publish -Recurse | Measure-Object Length -Sum).Sum; 'publish: {0:N1} MB, {1} files' -f (\$s/1MB), (Get-ChildItem publish -Recurse -File).Count" ;;
  run)
    exe="C:\\medley\\$SLOT\\$CONFIG_DIR\\${OPENMUSIC_CONFIG:-Debug}\\$EXE_REL"
    [[ "${OPENMUSIC_PUBLISHED:-}" == 1 ]] && exe="C:\\medley\\$SLOT\\publish\\OpenMusic.exe"
    "$W" kill OpenMusic >/dev/null
    "$W" gui "$SLOT" "$exe $*" ;;
  snapshot)
    out="${1:?local dir}"
    exe="C:\\medley\\$SLOT\\$CONFIG_DIR\\${OPENMUSIC_CONFIG:-Debug}\\$EXE_REL"
    "$W" kill OpenMusic >/dev/null
    "$W" ps "Remove-Item C:\\medley\\$SLOT\\snapshots -Recurse -ErrorAction SilentlyContinue" || true
    "$W" gui "$SLOT" "$exe --snapshot C:\\medley\\$SLOT\\snapshots" >/dev/null
    running() { "$W" ps "if (Get-Process OpenMusic -ErrorAction SilentlyContinue) { 'running' }" | grep -q running; }
    for _ in $(seq 1 20); do running && break; sleep 1; done   # the scheduled task takes a moment to start it
    for _ in $(seq 1 120); do running || break; sleep 2; done
    mkdir -p "$out"
    "$W" pull "C:/medley/$SLOT/snapshots/*" "$out"
    ls "$out" ;;
  shot) "$W" shot "${1:?out.png}" ;;
  log) "$W" ps "Get-Content \"\$env:LOCALAPPDATA\\OpenMusic\\logs\\openmusic.log\" -Tail ${1:-40}" ;;
  kill) "$W" kill OpenMusic ;;
  vm) "$W" "$@" ;;
  uia)
    # The script runs in the desktop session (a gui task); its answer comes back through a file.
    op="${1:?op}"; id="${2:-}"; text="${3:-}"
    U="C:\\medley\\$SLOT-uia"
    if [[ "${OPENMUSIC_UIA_PUSHED:-}" != 1 ]]; then
      d="$(mktemp -d)"; cp "$ROOT/scripts/windows-uia.ps1" "$d/"; "$W" push "$d" "$SLOT-uia" >/dev/null; rm -rf "${d:?}"
    fi
    b64=$(printf '%s\n%s\n%s\n' "$op" "$id" "$text" | base64 -w0)
    "$W" ps "Remove-Item $U\\uia-out.txt -ErrorAction SilentlyContinue; [IO.File]::WriteAllBytes('$U\\uia-args.txt', [Convert]::FromBase64String('$b64')); exit 0" >/dev/null
    "$W" gui "$SLOT-uia" "powershell -NoProfile -ExecutionPolicy Bypass -File $U\\windows-uia.ps1 -ArgsFile $U\\uia-args.txt" >/dev/null
    out=""
    for _ in $(seq 1 60); do
      out=$("$W" ps "if (Test-Path $U\\uia-out.txt) { Get-Content $U\\uia-out.txt }" | tr -d '\r')
      [[ -n "$out" ]] && break; sleep 0.5
    done
    echo "${out:-ERROR no answer from UI Automation}"
    [[ -n "$out" && "$out" != ERROR* ]] ;;
  *) sed -n 2,14p "$0"; exit 2 ;;
esac
