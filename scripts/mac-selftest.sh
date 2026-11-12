#!/usr/bin/env bash
# Run a mock-data UI self-test of build/OpenMusic.app on the Mac, several times. Runs on macOS.
#   scripts/mac-selftest.sh <name> [runs] [VAR=value ...]
# Build first (`CONFIG=debug scripts/bundle.sh` for debug-only self-tests such as `resize`). Each run goes through
# `open` so the app is in the GUI session, and is killed after OPENMUSIC_SELFTEST_TIMEOUT seconds (default 1200: the
# full `resize` suite takes about 10 minutes). The build Mac is shared: each run holds
# /tmp/medley-ui.lock from before the launch until no process carrying a marker argument unique to the run is left,
# and kills only those. That holds when the run is interrupted (^C, or TERM to this script or to its `--locked-run`)
# at any point, and when the process can't be found after `open`. A run that can't get the lock in 1800 s
# (OPENMUSIC_UI_LOCK_WAIT seconds) launches nothing, kills nothing and fails. scripts/mac-selftest-check.sh checks
# this. A run passes when the self-test's last line ends in PASS. Each run's log and stderr (where
# AppKit prints an exception's reason) go to a fresh build/selftest/<name>.XXXX directory, with the path of the
# crash report a failed run left. Prints one line per run, then "<passed>/<runs> passed"; exits non-zero unless
# every run passed.
set -uo pipefail
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."
source scripts/env.sh
app="$PWD/build/OpenMusic.app"
app_bin="$app/Contents/MacOS/OpenMusic"

# One run, executed by `lockf` while it holds the lock:
#   mac-selftest.sh --locked-run <marker> <stderr file> <log file> <open args...>
# Launches the app with `-OpenMusicSelfTestRun <marker>`, waits up to OPENMUSIC_SELFTEST_TIMEOUT s for it to exit, and returns only once no
# process carrying the marker is left: the interrupt trap is set before `open`, so an interrupt during the launch or
# while the process is being found also stops it, and so does failing to find it. When the self-test's last line
# asks for it (`RELAUNCH`, the resize test's relaunch case), launches the app once more with
# OPENMUSIC_SELFTEST_RELAUNCHED=1. Exit status: 0 the app exited on its own, 124 killed after the timeout, 70 `open`
# failed, 71 the process never showed up, 130 interrupted.
# For scripts/mac-selftest-check.sh: OPENMUSIC_SELFTEST_FIND_DELAY waits that many seconds after `open` before looking
# for the process, and OPENMUSIC_SELFTEST_FIND_TRIES (default 100, 0.1 s apart) bounds the search.
if [[ "${1:-}" == --locked-run ]]; then
  marker="$2" err="$3" log="$4"; shift 4
  # For the runner above: whom to signal (never `lockf`, which lets the lock go when signalled), and which app
  # processes are this run's.
  echo $$ > "$err.runner"
  pattern="^$app_bin -OpenMusicSelfTestRun $marker\$"
  find_pid() { pgrep -f -- "$pattern" | head -1; }
  # Stops every process carrying this run's marker and returns once none is left.
  stop_marked() {
    pkill -TERM -f -- "$pattern" 2>/dev/null
    for ((i = 0; i < 50; i++)); do [[ -z "$(find_pid)" ]] && return 0; sleep 0.1; done
    pkill -KILL -f -- "$pattern" 2>/dev/null
    while [[ -n "$(find_pid)" ]]; do sleep 0.1; done
  }
  trap 'stop_marked; exit 130' INT TERM HUP
  launch() {
    open -n --stderr "$err" "$@" "$app" --args -OpenMusicSelfTestRun "$marker" || { stop_marked; return 70; }
    [[ -n "${OPENMUSIC_SELFTEST_FIND_DELAY:-}" ]] && sleep "$OPENMUSIC_SELFTEST_FIND_DELAY"
    local pid="" i
    for ((i = 0; i < ${OPENMUSIC_SELFTEST_FIND_TRIES:-100}; i++)); do pid="$(find_pid)"; [[ -n $pid ]] && break; sleep 0.1; done
    if [[ -z $pid ]]; then
      # It may still be starting: give it a moment, then stop whatever carries the marker.
      sleep 2; stop_marked; return 71
    fi
    echo "$pid" >> "$err.pids"
    local deadline=$((SECONDS + ${OPENMUSIC_SELFTEST_TIMEOUT:-1200}))
    while kill -0 "$pid" 2>/dev/null; do
      if ((SECONDS >= deadline)); then stop_marked; return 124; fi
      sleep 0.2
    done
    stop_marked
    return 0
  }
  launch "$@"; status=$?
  if [[ $status -eq 0 && "$(tail -1 "$log" 2>/dev/null)" == RELAUNCH* ]]; then
    launch "$@" --env OPENMUSIC_SELFTEST_RELAUNCHED=1; status=$?
  fi
  exit $status
fi

name="${1:?usage: scripts/mac-selftest.sh <name> [runs] [VAR=value ...]}"
runs="${2:-1}"
shift; [[ $# -gt 0 ]] && shift
mkdir -p build/selftest
out_dir="$(mktemp -d "$PWD/build/selftest/$name.XXXX")"
echo "logs: $out_dir"
extra=()
for kv in "$@"; do extra+=(--env "$kv"); done
reports="$HOME/Library/Logs/DiagnosticReports"
latest_report() { ls "$reports" 2>/dev/null | grep '^OpenMusic-' | sort | tail -1; }
passed=0
# Interrupted: the run that holds the lock stops its app and then lets the lock go. The signal goes to the run's
# `--locked-run` (its pid file), never to `lockf`: a signalled `lockf` releases the lock (and deletes the lock file)
# at once while its command keeps running. A run still waiting for the lock has no pid file yet; its `lockf` is
# killed outright (SIGKILL runs no cleanup, and it holds nothing).
interrupted() {
  local runner=""
  [[ -s "$err.runner" ]] && runner="$(cat "$err.runner")"
  if [[ -z $runner ]]; then
    kill -KILL "$locker" 2>/dev/null
    sleep 0.2
    [[ -s "$err.runner" ]] && runner="$(cat "$err.runner")"
  fi
  [[ -n $runner ]] && kill -TERM "$runner" 2>/dev/null
  while kill -0 "$locker" 2>/dev/null || { [[ -n $runner ]] && kill -0 "$runner" 2>/dev/null; }; do sleep 0.1; done
  echo "run $n: interrupted"
  exit 130
}
for ((n = 1; n <= runs; n++)); do
  log="$out_dir/$n.log" err="$out_dir/$n.stderr"
  marker="$(basename "$out_dir").$n.$$"
  before="$(latest_report)"
  start=$(date +%s)
  # In a process group of its own (job control), so a terminal's ^C reaches only this script, which stops the run
  # and waits for it: `lockf` releases the lock as soon as it is signalled, even with its command still running.
  set -m
  lockf -t "${OPENMUSIC_UI_LOCK_WAIT:-1800}" /tmp/medley-ui.lock "$self" --locked-run "$marker" "$err" "$log" \
    --env OPENMUSIC_MOCK=1 --env OPENMUSIC_SELFTEST="$name" --env OPENMUSIC_SELFTEST_OUT="$log" ${extra[@]+"${extra[@]}"} &
  locker=$!
  set +m
  trap 'interrupted' INT TERM HUP
  wait "$locker"; status=$?
  # `wait` returns early when a trapped signal arrives; the run's own exit status comes from waiting again.
  while kill -0 "$locker" 2>/dev/null; do wait "$locker"; status=$?; done
  trap - INT TERM HUP
  case $status in
    0) how="exited" ;;
    124) how="killed after ${OPENMUSIC_SELFTEST_TIMEOUT:-1200} s" ;;
    70) how="open failed" ;;
    71) how="never started" ;;
    130) how="interrupted" ;;
    75) how="UI lock busy for ${OPENMUSIC_UI_LOCK_WAIT:-1800} s, not launched" ;;
    *) how="runner exit $status" ;;
  esac
  last="$(tail -1 "$log" 2>/dev/null)"
  if [[ $status -eq 0 && "$last" == *PASS ]]; then
    passed=$((passed + 1)); verdict=PASS
  else
    verdict=FAIL
    if [[ $status -ne 75 && -s "$err.pids" ]]; then
      sleep 3
      # The newest report since the run started that belongs to one of its app processes.
      for report in $(ls "$reports" 2>/dev/null | grep '^OpenMusic-' | sort -r); do
        [[ -n "$before" && ! "$report" > "$before" ]] && break
        if grep -qE "\"pid\" : ($(paste -sd'|' "$err.pids"))[^0-9]" "$reports/$report" 2>/dev/null; then
          echo "$reports/$report" > "$out_dir/$n.crash"; break
        fi
      done
    fi
  fi
  echo "run $n: $verdict in $(( $(date +%s) - start )) s ($how); last line: ${last:-<none>}"
  if [[ $verdict == FAIL && $status -ne 75 ]]; then
    # AppKit logs an uncaught exception's reason to the unified log. Only this run's app processes count: the
    # run's time span includes waiting for the lock, while other runs' apps were up.
    pids="$(tr '\n' ',' < "$err.pids" 2>/dev/null | sed 's/,$//')"
    if [[ -n $pids ]]; then
      log show --start "$(date -r "$start" '+%Y-%m-%d %H:%M:%S')" --style compact \
        --predicate "process == \"OpenMusic\" AND processIdentifier IN {$pids} AND (messageType == error OR messageType == fault) AND (category == \"General\" OR category == \"HIExceptions\")" 2>/dev/null \
        | grep -vE 'General\] +[0-9]+ ' | grep -E 'Exception|Update Constraints|reason' | cut -c1-600 | head -4 | sed 's/^/  log: /'
    fi
    [[ -f "$out_dir/$n.crash" ]] && echo "  crash report: $(cat "$out_dir/$n.crash")"
  fi
done
echo "$passed/$runs passed"
[[ $passed -eq $runs ]]
