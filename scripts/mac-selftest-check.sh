#!/usr/bin/env bash
# Checks how scripts/mac-selftest.sh shares the Mac with other runs. Runs on macOS after `CONFIG=debug scripts/bundle.sh`.
#   scripts/mac-selftest-check.sh
# 1. A run stops only its own app: a decoy process whose command line starts with the same app binary (as another
#    run's app would) is still alive afterwards.
# 2. A run that can't get /tmp/medley-ui.lock launches nothing and stops nothing: with the lock held by this script
#    for 20 s and MEDLEY_UI_LOCK_WAIT=3, the run reports the busy lock, fails, and the decoy is still alive.
# 3. An interrupt while the run is still finding its app (MEDLEY_SELFTEST_FIND_DELAY holds it there, after `open`)
#    stops that app before the lock goes: with ^C (INT to the runner's process group, as a terminal sends it; it
#    reaches `lockf` too unless the runner keeps it apart) (a) and TERM to its `--locked-run` (b), no app of the run
#    is alive at the moment its `lockf` exits and lets the lock go, and the decoy survives. Also (c) with TERM to the
#    runner itself, which must stop the run through its `--locked-run`, never by signalling `lockf`.
# 4. A run that can't find its app (MEDLEY_SELFTEST_FIND_TRIES=0) fails as "never started" and leaves no app behind.
# Uses the quick `resize` self-test (MEDLEY_RESIZE_ONLY=none; checks 3 and 4 a longer one, so the app outlives the
# interrupt). Prints PASS or FAIL per check; exits non-zero on a FAIL.
set -uo pipefail
cd "$(dirname "$0")/.."
app_bin="$PWD/build/OpenMusic.app/Contents/MacOS/OpenMusic"
[[ -x "$app_bin" ]] || { echo "no $app_bin; build first"; exit 2; }
out="$(mktemp -d "${TMPDIR:-/tmp}/mac-selftest-check.XXXX")"
failed=0
pids=()
cleanup() { for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
start_decoy() { bash -c "exec -a '$app_bin' sleep 900" & decoy=$!; pids+=("$decoy"); sleep 0.5; }
verdict() { if [[ $1 -eq 0 ]]; then echo "PASS $2"; else echo "FAIL $2"; failed=1; fi; }

start_decoy
scripts/mac-selftest.sh resize 1 MEDLEY_RESIZE_ONLY=none > "$out/1.txt" 2>&1
run=$?
kill -0 "$decoy" 2>/dev/null; alive=$?
cat "$out/1.txt" | sed 's/^/  /'
verdict $(( run != 0 || alive != 0 )) "1: the run passed ($run) and another process of the same binary survived it (alive: $([[ $alive -eq 0 ]] && echo yes || echo no))"

start_decoy
lockf /tmp/medley-ui.lock sleep 20 & holder=$!; pids+=("$holder")
sleep 1
before="$(pgrep -f -- "^$app_bin -MedleySelfTestRun" | wc -l | tr -d ' ')"
MEDLEY_UI_LOCK_WAIT=3 scripts/mac-selftest.sh resize 1 MEDLEY_RESIZE_ONLY=none > "$out/2.txt" 2>&1
run=$?
kill -0 "$decoy" 2>/dev/null; alive=$?
launched="$(pgrep -f -- "^$app_bin -MedleySelfTestRun" | wc -l | tr -d ' ')"
busy=$(grep -c "not launched" "$out/2.txt")
cat "$out/2.txt" | sed 's/^/  /'
verdict $(( run == 0 || alive != 0 || busy == 0 || launched != before )) \
  "2: with the lock busy the run failed ($run), said so ($busy), launched nothing ($before -> $launched) and the decoy survived (alive: $([[ $alive -eq 0 ]] && echo yes || echo no))"
# Let the lock go now rather than in 20 s.
pkill -P "$holder" sleep 2>/dev/null; kill "$holder" 2>/dev/null
sleep 1

# The run's apps: those with a marker argument, less the ones alive before it started.
run_apps() { pgrep -f -- "^$app_bin -MedleySelfTestRun " | grep -vxF -f "$out/apps.before" | tr '\n' ' '; }
# A shell started in the background by a non-interactive one (nohup, a batch) inherits SIGINT ignored, and bash
# can't undo that: ^C can't be sent from there, so 3a is skipped rather than passed.
int_ignored="$(bash -c 'kill -INT $$; echo yes' 2>/dev/null)"
for target in ^C locked-run runner; do
  if [[ $target == ^C && -n $int_ignored ]]; then
    echo "SKIP 3a: SIGINT is ignored in this shell (started in the background); run the check from a terminal or ssh"
    continue
  fi
  { echo none; pgrep -f -- "^$app_bin -MedleySelfTestRun "; } > "$out/apps.before"
  # In a process group of its own, as a run started from a terminal is, so ^C can be sent to that group.
  set -m
  MEDLEY_SELFTEST_FIND_DELAY=8 scripts/mac-selftest.sh resize 1 MEDLEY_RESIZE_ONLY=steps MEDLEY_RESIZE_PANELS=lyrics > "$out/3-${target#^}.txt" 2>&1 &
  runner=$!; pids+=("$runner")
  set +m
  # Wait for this run's app to appear (the runner then sleeps 8 s before looking for it), up to the lock wait:
  # another worker may hold the lock.
  apps=""
  for ((i = 0; i < 18000; i++)); do apps="$(run_apps)"; [[ -n $apps ]] && break; kill -0 "$runner" 2>/dev/null || break; sleep 0.1; done
  holder="--locked-run resize\..*\.1\.$runner "
  case $target in
    ^C) kill -INT -- "-$runner" ;;
    runner) kill -TERM "$runner" ;;
    *) kill -TERM "$(pgrep -f -- "^bash .*$holder" | head -1)" ;;
  esac
  # The moment the run's `lockf` exits (the lock is let go), no app of the run may be left. Then let the rest of
  # the run (a `--locked-run` that outlived its `lockf`) finish before the next check.
  for ((i = 0; i < 2400; i++)); do [[ -z "$(pgrep -f -- "^lockf .*$holder")" ]] && break; sleep 0.05; done
  left="$(run_apps)"
  for ((i = 0; i < 1200; i++)); do [[ -z "$(pgrep -f -- "$holder")" ]] && break; sleep 0.1; done
  wait "$runner" 2>/dev/null
  kill -0 "$decoy" 2>/dev/null; alive=$?
  cat "$out/3-${target#^}.txt" | sed 's/^/  /'
  case $target in
    ^C) label="3a: ^C to the runner's process group" ;;
    runner) label="3c: TERM to the runner" ;;
    *) label="3b: TERM to the --locked-run" ;;
  esac
  # The interrupt must have taken effect: a run that went on to pass proves nothing.
  grep -q "PASS in" "$out/3-${target#^}.txt"; finished=$(( $? == 0 ))
  verdict $(( ${#apps} == 0 || ${#left} != 0 || alive != 0 || finished )) \
    "$label$( ((finished)) && echo " (not interrupted: the run went on and passed)") while it looked for app ${apps:-<none seen>}left ${left:-nothing} running when the lock was let go (decoy alive: $([[ $alive -eq 0 ]] && echo yes || echo no))"
  # Don't leave a stray app to the next check.
  for p in $left; do kill -KILL "$p" 2>/dev/null; done
  sleep 2
done

{ echo none; pgrep -f -- "^$app_bin -MedleySelfTestRun "; } > "$out/apps.before"
MEDLEY_SELFTEST_FIND_TRIES=0 scripts/mac-selftest.sh resize 1 MEDLEY_RESIZE_ONLY=steps MEDLEY_RESIZE_PANELS=lyrics > "$out/4.txt" 2>&1
run=$?
left="$(run_apps)"
never=$(grep -c "never started" "$out/4.txt")
kill -0 "$decoy" 2>/dev/null; alive=$?
cat "$out/4.txt" | sed 's/^/  /'
verdict $(( run == 0 || never == 0 || ${#left} != 0 || alive != 0 )) \
  "4: a run that can't find its app failed ($run), said so ($never) and left ${left:-nothing} running (decoy alive: $([[ $alive -eq 0 ]] && echo yes || echo no))"
for p in $left; do kill -KILL "$p" 2>/dev/null; done
exit $failed
