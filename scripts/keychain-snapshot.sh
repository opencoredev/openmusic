#!/usr/bin/env bash
# Prints one line per OpenMusic item in the login Keychain (services dev.openmusic*): service, account, created and modified
# times. Attributes only, never the stored data (`security dump-keychain` without -d), so it is safe to log.
# Run it before and after a live test run (on the build Mac) and compare the output to show the run left the Mac's real
# sign-ins alone.
set -euo pipefail
security dump-keychain 2>/dev/null | awk '
  function flush() { if (svce ~ /^dev\.openmusic/) printf "%s %s cdat=%s mdat=%s\n", svce, acct, cdat, mdat; svce = acct = cdat = mdat = "" }
  /^keychain: / { flush() }
  /"svce"<blob>=/ { s = $0; sub(/.*"svce"<blob>=/, "", s); gsub(/"/, "", s); svce = s }
  /"acct"<blob>=/ { s = $0; sub(/.*"acct"<blob>=/, "", s); gsub(/"/, "", s); acct = s }
  /"cdat"<timedate>=/ { s = $0; sub(/.*"cdat"<timedate>=[^ ]* /, "", s); gsub(/"/, "", s); cdat = s }
  /"mdat"<timedate>=/ { s = $0; sub(/.*"mdat"<timedate>=[^ ]* /, "", s); gsub(/"/, "", s); mdat = s }
  END { flush() }
' | sort
