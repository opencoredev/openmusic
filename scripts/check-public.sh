#!/usr/bin/env bash
# Fails when a tracked file contains something private: any extended regex (one per line) from the gitignored
# scripts/private-patterns.txt. Lines starting with # and blank lines are skipped. Prints file:line:text for each match.
#   scripts/check-public.sh
# Without the patterns file it says so and passes, so it is safe to run in any clone.
set -euo pipefail
cd "$(dirname "$0")/.."
patterns=scripts/private-patterns.txt
if [[ ! -f "$patterns" ]]; then
  echo "check-public: no $patterns, nothing to check"
  exit 0
fi
list="$(mktemp)"
trap 'rm -f -- "${list:?}"' EXIT
grep -vE '^[[:space:]]*(#|$)' "$patterns" > "$list" || true
if [[ ! -s "$list" ]]; then
  echo "check-public: $patterns has no patterns"
  exit 0
fi
status=0
# -I skips binary files; the patterns file itself is untracked, so git grep never sees it.
git grep -n -I -E -f "$list" -- . || status=$?
case "$status" in
  0) echo "check-public: FAIL, private text in tracked files (above)" >&2; exit 1 ;;
  1) echo "check-public: PASS ($(wc -l < "$list" | tr -d ' ') patterns, $(git ls-files | wc -l | tr -d ' ') tracked files)" ;;
  *) echo "check-public: git grep failed ($status)" >&2; exit 2 ;;
esac
