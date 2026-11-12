#!/usr/bin/env bash
# Drive Medley for Windows in the medley-win VM through its Debug --self-test file. Source it, or run it:
#   scripts/windows-selftest.sh launch '<app args>' -- '<command>' '<command>' ...   start the app, run commands in order
#   commands: any self-test line (see Services/SelfTest.cs), "sleep <s>", "snap <out.png> [main|mini|youtube]",
#   "log <pattern>" (prints this run's matching log lines).
# MEDLEY_VM_SLOT picks the slot (default council-win).
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
W="${MEDLEY_VM:-${OPENMUSIC_WIN_VM:-$HOME/vms/medley-win/win.sh}}"
SLOT="${MEDLEY_VM_SLOT:-council-win}"
EXE="${MEDLEY_EXE:-C:\\medley\\$SLOT\\src\\Medley.App\\bin\\x64\\Debug\\net10.0-windows10.0.22621.0\\win-x64\\OpenMusic.exe}"
ST="C:\\medley\\$SLOT\\council-st.txt"
LOG='$env:LOCALAPPDATA\OpenMusic\logs\openmusic.log'
SELFTEST_TMP="${SELFTEST_TMP:-$(mktemp -d)}"
ps() { "$W" ps "$1"; }
N=0; START=0
# Steps that failed or timed out in this run; callers exit non-zero when it isn't 0.
SELFTEST_FAILURES=0

# Starts the app with a fresh self-test file; later lines in the log than START belong to this run.
launch() {
  "$W" kill OpenMusic >/dev/null
  ps "Remove-Item '$ST' -ErrorAction SilentlyContinue; New-Item -ItemType File '$ST' | Out-Null" >/dev/null
  START=$(ps "if (Test-Path \"$LOG\") { (Get-Content \"$LOG\").Count } else { 0 }" | tr -d '\r')
  N=0
  "$W" gui "$SLOT" "$EXE --self-test $ST $*" >/dev/null
  for _ in $(seq 1 60); do
    ps "Get-Content \"$LOG\" | Select -Skip $START | Select-String 'selftest: watching'" | grep -q watching && break
    sleep 1
  done
  sleep "${SETTLE_LAUNCH:-4}"
}

# Runs one self-test command and waits (inside the VM, one SSH call) until the app logs it done or failed. Prints the
# run's last "selftest: bounds" line when asked for bounds.
st() {
  N=$((N + 1))
  local line="$*"
  if [[ "$line" == quit ]]; then ps "Add-Content '$ST' 'quit'" >/dev/null; sleep 2; return 0; fi
  local result
  result=$(ps "Add-Content '$ST' '$line'; \$d = (Get-Date).AddSeconds(60); do { \$t = Get-Content \"$LOG\" | Select -Skip $START; \$f = \$t | Select-String -SimpleMatch 'selftest: done $N ','selftest: failed $N ' | Select -First 1; if (\$f) { break }; Start-Sleep -Milliseconds 200 } while ((Get-Date) -lt \$d); if (-not \$f) { 'TIMEOUT' } elseif (\$f.Line -match 'failed') { 'FAILED' }; if ('$line' -like 'bounds*') { (\$t | Select-String 'selftest: bounds' | Select -Last 1).Line }" | tr -d '\r')
  local out status=0
  while read -r out; do
    case "$out" in
      TIMEOUT) echo "  self-test timed out: $line" >&2; status=1 ;;
      FAILED) echo "  self-test failed: $line" >&2; status=1 ;;
      *bounds*) echo "${out##*bounds }" ;;
    esac
  done <<<"$result"
  SELFTEST_FAILURES=$((SELFTEST_FAILURES + status))
  return 0
}

# Crops a VM screenshot to the foreground window's frame and saves it as <name>.png.
snap() {
  local name="$1" wait="${2:-1.5}" which="${3:-main}"
  sleep "$wait"
  # Not $(st …): a subshell would lose st's step counter, and the next wait would match this step's "done" line.
  st bounds "$which" > "$SELFTEST_TMP/bounds"
  read -r x y w h < "$SELFTEST_TMP/bounds"
  "$W" shot "$SELFTEST_TMP/screen.png" >/dev/null
  ffmpeg -loglevel error -y -i "$SELFTEST_TMP/screen.png" -vf "crop=$w:$h:$x:$y" "$name"
  echo "  $(basename "$name") (${w}x$h)"
}


runlog() { ps "Get-Content \"$LOG\" | Select -Skip $START | Select-String -SimpleMatch '$1' | ForEach-Object { \$_.Line }" | tr -d '\r'; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  [[ "${1:-}" == launch ]] || { sed -n 2,6p "$0"; exit 2; }
  args="$2"; shift 2; [[ "${1:-}" == -- ]] && shift
  launch "$args"
  for c in "$@"; do
    case "$c" in
      sleep\ *) sleep "${c#sleep }" ;;
      snap\ *) read -r _ file which <<<"$c"; snap "$file" 0.5 "${which:-main}" ;;
      log\ *) runlog "${c#log }" ;;
      *) st "$c" ;;
    esac
  done
  rm -rf "${SELFTEST_TMP:?}"
  if ((SELFTEST_FAILURES > 0)); then echo "$SELFTEST_FAILURES step(s) failed" >&2; exit 1; fi
fi
