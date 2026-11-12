#!/usr/bin/env bash
# Runs on the Mac the iPhone is paired with, called by scripts/install-iphone.sh: unlock the login keychain, sign the
# Release build install-iphone.sh just made, and install it on the iPhone.
#   OPENMUSIC_DEV_IDENTITY=… OPENMUSIC_TEAM_ID=… OPENMUSIC_PROFILE_UUID=… OPENMUSIC_IPHONE_UDID=… \
#     bash scripts/iphone-sign.sh < <password-file>
# OPENMUSIC_DEV_IDENTITY is the "Apple Development: …" certificate's name, OPENMUSIC_PROFILE_UUID an Xcode-managed
# wildcard profile of team OPENMUSIC_TEAM_ID in ~/Library/Developer/Xcode/UserData/Provisioning Profiles.
# stdin is that Mac's login password and nothing else. The unlock calls SecKeychainUnlock from Python, so the password
# never appears in a process's arguments. Unlock and codesign run in one SSH command: an earlier attempt that unlocked
# in a separate SSH command still got errSecInternalComponent from codesign (cause not pinned down).
set -euo pipefail
cd "$(dirname "$0")/.."
for v in OPENMUSIC_DEV_IDENTITY OPENMUSIC_TEAM_ID OPENMUSIC_PROFILE_UUID OPENMUSIC_IPHONE_UDID; do
  [[ -n "${!v:-}" ]] || { echo "iphone-sign.sh: $v is not set (scripts/install-iphone.sh passes it from scripts/local.env)" >&2; exit 2; }
done
team="$OPENMUSIC_TEAM_ID"
app=build/device/Build/Products/Release-iphoneos/OpenMusic.app
[ -d "$app" ] || { echo "no build at $app" >&2; exit 1; }

/usr/bin/python3 -c '
import ctypes, sys
pw = sys.stdin.buffer.read()
for end in (b"\n", b"\r"):  # one line ending, LF or CRLF; anything else is part of the password
    if pw.endswith(end):
        pw = pw[:-1]
sec = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/Security.framework/Security")
sec.SecKeychainUnlock.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_bool]
status = sec.SecKeychainUnlock(None, len(pw), pw, True)  # None: the default (login) keychain
if status != 0:
    sys.exit("keychain unlock failed (OSStatus %d)" % status)
'

id=$(security find-identity -v -p codesigning | awk -v name="$OPENMUSIC_DEV_IDENTITY" 'index($0, name) { print $2; exit }')
[ -n "$id" ] || { echo "signing identity not found" >&2; exit 1; }
cp ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/"$OPENMUSIC_PROFILE_UUID".mobileprovision \
  "$app/embedded.mobileprovision"
cat > build/device.entitlements <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>${team}.dev.openmusic.OpenMusicMobile</string>
  <key>com.apple.developer.team-identifier</key><string>${team}</string>
  <key>get-task-allow</key><true/>
  <key>keychain-access-groups</key><array><string>${team}.dev.openmusic.OpenMusicMobile</string></array>
</dict></plist>
EOF
# Nested code first (deepest first), then the app with its entitlements.
find "$app" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' \) -print0 |
  while IFS= read -r -d '' f; do codesign --force --sign "$id" --timestamp=none "$f"; done
codesign --force --sign "$id" --timestamp=none --entitlements build/device.entitlements --generate-entitlement-der "$app"
codesign --verify --deep --strict "$app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' -c 'Print :OpenMusicSyncURL' \
  "$app/Info.plist"
xcrun devicectl device install app --device "$OPENMUSIC_IPHONE_UDID" "$app" > build/device-install.log 2>&1 ||
  { tail -20 build/device-install.log >&2; exit 1; }
echo "installed on the iPhone"
