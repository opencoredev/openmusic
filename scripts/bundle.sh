#!/usr/bin/env bash
# Build OpenMusic.app (release, arm64) into build/OpenMusic.app. Runs on macOS.
# CONFIG=debug builds a debug app instead: it also has the Keychain probe (Sources/OpenMusic/App/KeychainProbe.swift),
# which release builds leave out. Never install a debug build as the copy you use day to day.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
config="${CONFIG:-release}"
swift build -c "$config" --arch arm64 --product OpenMusic
bin="$(swift build -c "$config" --arch arm64 --show-bin-path)"
app="build/OpenMusic.app"
rm -rf "${app:?}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/OpenMusic" "$app/Contents/MacOS/OpenMusic"
# SwiftPM records the deployment target (15.0) as the SDK version too. macOS gives the current design
# (Liquid Glass toolbar, floating sidebar) only to apps linked against a current SDK, so stamp the real one.
sdk="$(xcrun --show-sdk-version)"
xcrun vtool -set-build-version macos 15.0 "$sdk" -replace -output "$app/Contents/MacOS/OpenMusic" "$app/Contents/MacOS/OpenMusic"
# SwiftPM resource bundles, if any target declares resources.
for b in "$bin"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done
cp Resources/Info.plist "$app/Contents/Info.plist"
# Debug builds only: lets the Keychain service serve the probe's throwaway account (the signature seals this key).
if [ "$config" = debug ]; then /usr/libexec/PlistBuddy -c "Add :MedleyKeychainProbe bool true" "$app/Contents/Info.plist"; fi
# Sync deployment: release builds use production, debug builds (self-tests, live scripts) the dev deployment.
if [ "$config" = debug ]; then sync_url="https://sensible-barracuda-214.convex.cloud"; else sync_url="https://insightful-roadrunner-835.convex.cloud"; fi
/usr/libexec/PlistBuddy -c "Add :OpenMusicSyncURL string ${OPENMUSIC_SYNC_URL:-$sync_url}" "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
# Signing. Sign-ins live in the Keychain, and macOS lets an item be read only by the code that saved it. Two things
# keep that the same from build to build:
# - the stable self-signed identity (scripts/signing-identity.sh), so every build has the same designated requirement;
# - Contents/XPCServices/dev.openmusic.keychain-service.xpc, the XPC service that saves and reads the items for the app.
#   It is built once per version of its source and Info.plist and reused byte for byte, so its cdhash (the Keychain
#   partition of a team-less app) never changes. See Resources/KeychainService/main.swift.
# Without the identity the app is signed ad-hoc, has neither, and every new build starts signed out.
identity="${OPENMUSIC_SIGNING_IDENTITY:-Medley Self-Signed}"
signing_dir="$HOME/agents/medley-signing"
keychain="${OPENMUSIC_SIGNING_KEYCHAIN:-$signing_dir/medley-signing.keychain-db}"
password_file="${OPENMUSIC_SIGNING_PASSWORD_FILE:-$signing_dir/keychain-password}"
signed_with="ad-hoc"
unlock() {
  # `security -i` reads its command from stdin, so the password is never in any process's arguments (the process
  # list of this shared Mac shows those to every user). It exits non-zero when the password is wrong.
  local pw
  pw="$(<"$password_file")"
  security -i >/dev/null 2>&1 <<EOF
unlock-keychain -p "$pw" "$keychain"
EOF
}
if [ -f "$keychain" ] && [ -r "$password_file" ] && unlock \
   && security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
  cert="$(security find-certificate -c "$identity" -Z "$keychain" | awk '/^SHA-1/ {print $3}')"
  # The Keychain service, built and signed once per (main.swift + Info.plist, certificate), then reused.
  service_src=Resources/KeychainService
  service_hash="$(cat "$service_src/main.swift" "$service_src/Info.plist" | shasum -a 256 | cut -c1-16)"
  service_dir="$signing_dir/keychain-service/$service_hash-${cert:0:12}"
  service="$service_dir/dev.openmusic.keychain-service.xpc"
  if [ ! -d "$service" ]; then
    mkdir -p "$service_dir"
    staging="$(mktemp -d "$service_dir/staging.XXXXXX")/dev.openmusic.keychain-service.xpc"
    mkdir -p "$staging/Contents/MacOS"
    cp "$service_src/Info.plist" "$staging/Contents/Info.plist"
    swiftc -O -target arm64-apple-macos15.0 "$service_src/main.swift" -o "$staging/Contents/MacOS/openmusic-keychain-service"
    codesign --force --sign "$identity" --keychain "$keychain" --options runtime "$staging"
    mv "$staging" "$service"
    rmdir "${staging%/*}"
    echo "built the Keychain service once: $service"
  fi
  mkdir -p "$app/Contents/XPCServices"
  cp -R "$service" "$app/Contents/XPCServices/"
  codesign --force --sign "$identity" --keychain "$keychain" --entitlements Resources/OpenMusic.entitlements --options runtime "$app"
  signed_with="$identity"
else
  echo "warning: signing identity \"$identity\" not found in $keychain; signing ad-hoc, without the Keychain service." >&2
  echo "warning: an ad-hoc build can't read sign-ins saved by other builds. Run scripts/signing-identity.sh once on this Mac." >&2
  codesign --force --sign - --entitlements Resources/OpenMusic.entitlements --options runtime "$app"
fi
echo "built $app ($(du -sh "$app" | cut -f1), signed: $signed_with)"
