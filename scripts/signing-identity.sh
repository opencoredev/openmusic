#!/usr/bin/env bash
# Create (once) the stable self-signed code-signing identity that scripts/bundle.sh signs Medley with. Runs on the
# Mac that builds (the build Mac). Safe to run again: it reuses what exists.
#
# Why: the Keychain ties an item to the designated requirement of the app that wrote it. An ad-hoc signature's
# requirement is its cdhash, which changes with every build, so each new build lost access to the saved sign-ins.
# A build signed by this identity has the requirement `identifier "dev.openmusic.OpenMusic" and certificate root = H"…"`,
# the same for every build.
#
# Files, all under ~/agents/medley-signing (mode 700):
#   medley-signing.keychain-db  a keychain of its own holding only this identity (not the login keychain)
#   keychain-password           its random password, mode 600; never printed, never in the repo
#   identity.cer                the public certificate, for reference
set -euo pipefail
name="Medley Self-Signed"
dir="$HOME/agents/medley-signing"
kc="$dir/medley-signing.keychain-db"
pwfile="$dir/keychain-password"

mkdir -p "$dir"
chmod 700 "$dir"
if [ ! -s "$pwfile" ]; then
  (umask 077 && openssl rand -hex 32 > "$pwfile")
fi
chmod 600 "$pwfile"
pw="$(<"$pwfile")"
# Passwords go to `security -i` on stdin, never as arguments: the process list of this shared Mac shows every
# process's arguments to every user. `security -i` exits non-zero when a command fails.
sec() { security -i >/dev/null; }

if [ ! -f "$kc" ]; then
  sec <<EOF
create-keychain -p "$pw" "$kc"
EOF
fi
# No auto-lock timeout; bundle.sh unlocks it before each signature anyway.
security set-keychain-settings "$kc"
sec <<EOF
unlock-keychain -p "$pw" "$kc"
EOF

if security find-certificate -c "$name" "$kc" >/dev/null 2>&1; then
  echo "identity \"$name\" already in $kc"
else
  work="$(mktemp -d)"
  trap 'rm -rf "${work:?}"' EXIT
  cat > "$work/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[dn]
CN = Medley Self-Signed
[codesign]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 7300 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  (umask 077 && openssl rand -hex 16 > "$work/p12pw")
  p12pw="$(<"$work/p12pw")"
  # macOS's importer reads only the older PKCS#12 algorithms. openssl reads the export password from the file.
  openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -out "$work/identity.p12" -passout "file:$work/p12pw" 2>/dev/null \
    || openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
      -out "$work/identity.p12" -passout "file:$work/p12pw"
  sec <<EOF
import "$work/identity.p12" -k "$kc" -P "$p12pw" -T /usr/bin/codesign
EOF
  cp "$work/cert.pem" "$dir/identity.cer"
  echo "created identity \"$name\" in $kc"
fi
# Let codesign use the key without a prompt.
sec <<EOF
set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc"
EOF
security find-certificate -c "$name" -Z "$kc" | grep -E "^SHA-1" | sed 's/^/certificate /'
