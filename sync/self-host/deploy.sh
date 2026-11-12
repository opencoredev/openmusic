#!/usr/bin/env bash
# Start (or upgrade) your OpenMusic sync server and deploy the backend to it. See docs/self-hosting.md.
#
#   ./deploy.sh                  start the backend, set the Clerk settings, deploy sync/convex, check config:get
#   ./deploy.sh convex <args>    run any Convex CLI command against your server, e.g.
#                                ./deploy.sh convex data devices
#                                ./deploy.sh convex logs
#
# Reads .env next to this script. Uses `docker compose`, `podman compose` or `podman-compose`, whichever works
# first; set COMPOSE="podman-compose" (for example) to choose. Needs Node.js 22.12+ and curl.
# Keeps the backend's admin key in ~/.config/openmusic-sync/<COMPOSE_PROJECT_NAME>.admin-key (folder 0700, file 0600),
# outside the checkout so it is never committed or copied along with it. Never share it: it can read and change
# everything on the server.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sync_dir="$(cd "$here/.." && pwd)"

say() { printf '%s\n' "$*" >&2; }
die() { say "error: $*"; exit 1; }

# --- settings ---------------------------------------------------------------------------------------------------

[[ -f "$here/.env" ]] || die "no $here/.env yet. Copy .env.example to .env and fill in your Clerk keys."

# Read KEY=VALUE lines without running the file as shell code. Only the settings below are taken (plain variables,
# not an associative array: macOS ships Bash 3.2).
publishable_key="" issuer="" server_url="" port="3210" project="openmusic-sync" legacy=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]] || die ".env: can't read this line: $line"
  name="${BASH_REMATCH[1]}"
  value="${BASH_REMATCH[2]}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
  case "$name" in
    CLERK_PUBLISHABLE_KEY) publishable_key="$value" ;;
    CLERK_JWT_ISSUER_DOMAIN) issuer="${value%/}" ;;
    OPENMUSIC_SERVER_URL) server_url="${value%/}" ;;
    OPENMUSIC_PORT) port="${value:-3210}" ;;
    COMPOSE_PROJECT_NAME) project="${value:-openmusic-sync}" ;;
    MEDLEY_SERVER_URL|MEDLEY_PORT) legacy+=("$name") ;;
  esac
done < "$here/.env"

# A .env from before the rename to OpenMusic: its settings would be ignored (compose.yaml reads only the OPENMUSIC_
# names), so the server would come back on the default port and address. Stop before touching anything.
if (( ${#legacy[@]} )); then
  say "error: .env uses the old Medley setting names (${legacy[*]}), which this version ignores. Before upgrading:"
  say "  1. rename MEDLEY_SERVER_URL to OPENMUSIC_SERVER_URL and MEDLEY_PORT to OPENMUSIC_PORT in $here/.env;"
  say "  2. keep your data: add COMPOSE_PROJECT_NAME=medley-sync to .env if it has no COMPOSE_PROJECT_NAME line;"
  say "  3. move the admin key: mkdir -p ~/.config/openmusic-sync && chmod 700 ~/.config/openmusic-sync &&"
  say "     mv ~/.config/medley-sync/*.admin-key ~/.config/openmusic-sync/"
  say "Then run ./deploy.sh again."
  exit 1
fi

[[ "$port" =~ ^[0-9]+$ ]] || die "OPENMUSIC_PORT must be a port number."
[[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "COMPOSE_PROJECT_NAME: lowercase letters, digits, - and _ only."
local_url="http://127.0.0.1:$port"
key_dir="${XDG_CONFIG_HOME:-$HOME/.config}/openmusic-sync"
key_file="$key_dir/$project.admin-key"

# --- compose -------------------------------------------------------------------------------------------------------

compose=()
if [[ -n "${COMPOSE:-}" ]]; then
  read -r -a compose <<< "$COMPOSE"
elif command -v docker > /dev/null && docker compose version > /dev/null 2>&1; then
  compose=(docker compose)
elif command -v podman > /dev/null && podman compose version > /dev/null 2>&1; then
  compose=(podman compose)
elif command -v podman-compose > /dev/null; then
  compose=(podman-compose)
else
  die "no compose tool found: install Docker (with compose) or podman and podman-compose."
fi
dc() { "${compose[@]}" -p "$project" -f "$here/compose.yaml" --env-file "$here/.env" "$@"; }

# --- the Convex CLI, pointed at this server --------------------------------------------------------------------

ensure_node() {
  # The Convex CLI needs Node.js 22 and vitest (in the same lockfile) 22.12, so ask for that.
  command -v node > /dev/null || die "Node.js 22.12 or newer is needed (node not found)."
  local major minor
  IFS=. read -r major minor _ <<< "$(node -p 'process.versions.node')"
  (( major > 22 || (major == 22 && minor >= 12) )) || die "Node.js 22.12 or newer is needed (found $(node --version))."
  if [[ ! -d "$sync_dir/node_modules/convex" ]]; then
    say "Installing the Convex CLI (npm ci in sync/)…"
    (cd "$sync_dir" && npm ci --no-audit --no-fund --loglevel=error)
  fi
}

# The admin key reaches the CLI through its environment, never its arguments (other users can see arguments).
convex() {
  [[ -s "$key_file" ]] || die "no admin key yet: run ./deploy.sh first."
  (
    cd "$sync_dir"
    CONVEX_SELF_HOSTED_URL="$local_url" CONVEX_SELF_HOSTED_ADMIN_KEY="$(< "$key_file")" CONVEX_DEPLOYMENT= \
      npx --no-install convex "$@"
  )
}

if [[ "${1:-}" == "convex" ]]; then
  shift
  ensure_node
  convex "$@"
  exit
fi
[[ $# -eq 0 ]] || die "usage: ./deploy.sh, or ./deploy.sh convex <command>"

# --- checks --------------------------------------------------------------------------------------------------------

[[ "$publishable_key" =~ ^pk_(test|live)_[A-Za-z0-9+/=]+$ ]] ||
  die "CLERK_PUBLISHABLE_KEY should look like pk_test_… or pk_live_… (Clerk dashboard › API keys)."
[[ "$issuer" =~ ^https://[a-z0-9.-]+$ ]] ||
  die "CLERK_JWT_ISSUER_DOMAIN should be your Clerk Frontend API URL, like https://verb-noun-12.clerk.accounts.dev."
# The publishable key is base64 of "<Frontend API host>$": both settings must name the same Clerk instance.
encoded="${publishable_key#pk_*_}"
while (( ${#encoded} % 4 )); do encoded+="="; done
key_host="$(printf '%s' "$encoded" | base64 -d 2> /dev/null | tr -d '$' || true)"
[[ "https://$key_host" == "$issuer" ]] ||
  die "CLERK_PUBLISHABLE_KEY belongs to https://$key_host, but CLERK_JWT_ISSUER_DOMAIN is $issuer. Use the same Clerk instance for both."
if [[ -n "$server_url" ]]; then
  [[ "$server_url" =~ ^https?://[^/?#@]+$ ]] ||
    die "OPENMUSIC_SERVER_URL should be just a scheme, host and optional port, like https://my-box.example.ts.net:3443."
  [[ "$server_url" == https://* ]] ||
    say "note: $server_url isn't HTTPS. OpenMusic accepts http:// only for this machine and the local network, not Tailscale."
fi
command -v curl > /dev/null || die "curl is needed."
ensure_node

# --- start the backend -----------------------------------------------------------------------------------------------

say "Starting the backend (${compose[*]}, project $project)…"
dc up -d backend
for _ in $(seq 1 60); do
  curl -fsS "$local_url/version" > /dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$local_url/version" > /dev/null 2>&1 || die "the backend didn't answer on $local_url. See: ${compose[*]} -p $project logs backend"

# The admin key: generated once, then reused while the backend accepts it (a new volume has a new secret, and the
# saved key stops working). Generate as rarely as possible: the backend image's generate_admin_key.sh hands the
# instance secret to its key tool as a command-line argument, which other users of this machine can read in the
# process list for that moment (docs/self-hosting.md, "On a shared machine").
# -T: no terminal, or the key comes back with a carriage return and the CLI calls it invalid.
umask 077
mkdir -p "$key_dir"
chmod 700 "$key_dir"
if [[ -s "$key_file" ]] && convex env list > /dev/null 2>&1; then
  say "Using the saved admin key ($key_file)."
else
  say "Generating the admin key…"
  key="$(dc exec -T backend ./generate_admin_key.sh | tr -d '\r' | grep -E '^[^ ]+\|[0-9a-f]+$' | tail -n 1 || true)"
  [[ -n "$key" ]] || die "couldn't generate the admin key (${compose[*]} -p $project exec -T backend ./generate_admin_key.sh)."
  printf '%s' "$key" > "$key_file.tmp"
  chmod 600 "$key_file.tmp"
  mv -f "$key_file.tmp" "$key_file"
  unset key
fi

# --- deploy ------------------------------------------------------------------------------------------------------

say "Setting the Clerk settings…"
# The issuer must be set before the first deploy: sync/convex/auth.config.ts refuses to load without it.
convex env set CLERK_JWT_ISSUER_DOMAIN "$issuer" > /dev/null
convex env set CLERK_PUBLISHABLE_KEY "$publishable_key" > /dev/null

say "Deploying sync/convex…"
convex deploy < /dev/null

# --- check -----------------------------------------------------------------------------------------------------------

query='{"path":"config:get","format":"convex_encoded_json","args":[{}]}'
check() {
  local answer
  answer="$(curl -fsS --max-time 10 -X POST "$1/api/query" -H 'Content-Type: application/json' -d "$query")" || return 1
  [[ "$answer" == *'"kind":"clerk"'* && "$answer" == *"$publishable_key"* ]] || { say "unexpected answer from $1: $answer"; return 1; }
}
check "$local_url" || die "config:get on $local_url doesn't name your Clerk app."
say "config:get on $local_url names your Clerk app."

if [[ -z "$server_url" ]]; then
  say ""
  say "Deployed. Next: give the server an HTTPS address (docs/self-hosting.md, step 3), put it in OPENMUSIC_SERVER_URL"
  say "in .env and run ./deploy.sh again."
  exit 0
fi
check "$server_url" || die "the server works on this machine, but $server_url doesn't answer config:get. Check the HTTPS step."
say ""
say "Done. Paste this into OpenMusic (Use your own server, or Settings › Account › Server):"
printf '%s\n' "$server_url"
