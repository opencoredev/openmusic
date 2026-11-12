#!/usr/bin/env bash
# Build OpenMusic for iPhone (Release, production sync) on the Mac the iPhone is paired with (OPENMUSIC_DEVICE_HOST)
# and install it on the iPhone (OPENMUSIC_IPHONE_UDID). Signing needs OPENMUSIC_DEV_IDENTITY, OPENMUSIC_TEAM_ID and
# OPENMUSIC_PROFILE_UUID; all of these live in scripts/local.env (see scripts/local.env.example).
#   scripts/install-iphone.sh <password-file>
# <password-file> holds that Mac's login password; it is deleted when this script exits. Over SSH the login keychain
# is locked, so codesign fails with errSecInternalComponent until it is unlocked: scripts/iphone-sign.sh does that on
# the Mac from stdin, never from a command line. See AGENTS.md (iOS and sync).
set -euo pipefail
pw="${1:?usage: scripts/install-iphone.sh <file with the login password of the device Mac>}"
[ -r "$pw" ] || { echo "can't read $pw" >&2; exit 2; }
trap 'rm -f -- "${pw:?}"' EXIT
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/env.sh"
need OPENMUSIC_DEVICE_HOST OPENMUSIC_IPHONE_UDID OPENMUSIC_DEV_IDENTITY OPENMUSIC_TEAM_ID OPENMUSIC_PROFILE_UUID
host="$OPENMUSIC_DEVICE_HOST"
remote=agents/medley-device
# Drops the login profile's cargo warning on the owner's Mac; never fails the pipeline on empty output.
quiet() { grep -v cargo || true; }
# The signing values go to the remote command in single quotes, which every login shell reads literally.
squote() { [[ "$1" != *"'"* ]] || { echo "single quote in a signing value" >&2; exit 2; }; printf "'%s'" "$1"; }

remote_run "$host" "mkdir -p ~/${remote}" >/dev/null
rsync -az --delete \
  --exclude-from="$root/scripts/rsync-excludes.txt" --exclude windows \
  -e "ssh -o BatchMode=yes" "$root/" "$(remote_prefix "$host")${remote}/"

echo "building"
remote_run "$host" "cd ~/${remote} && mkdir -p build && /opt/homebrew/bin/xcodegen generate --spec iOS/project.yml --quiet \
  && xcodebuild -project iOS/MedleyMobile.xcodeproj -scheme MedleyMobile -configuration Release \
       -destination generic/platform=iOS -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build \
       > build/device-build.log 2>&1 \
  || { tail -40 build/device-build.log; exit 1; }" 2>&1 | quiet

echo "signing and installing"
remote_ssh "$host" "env OPENMUSIC_DEV_IDENTITY=$(squote "$OPENMUSIC_DEV_IDENTITY") \
  OPENMUSIC_TEAM_ID=$(squote "$OPENMUSIC_TEAM_ID") OPENMUSIC_PROFILE_UUID=$(squote "$OPENMUSIC_PROFILE_UUID") \
  OPENMUSIC_IPHONE_UDID=$(squote "$OPENMUSIC_IPHONE_UDID") bash ~/${remote}/scripts/iphone-sign.sh" < "$pw" 2>&1 | quiet
