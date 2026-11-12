# Sourced by the scripts that reach other machines. Loads scripts/local.env (gitignored; copy
# scripts/local.env.example and fill it in) and gives them a few helpers:
#   need VAR...                 fail with a clear message unless every VAR is set
#   remote_run <host> [cmd]     run cmd (or stdin) in a bash login shell on <host>; "local" runs it here
#   remote_tty <host> <cmd>     the same with a terminal, for commands that prompt
#   remote_ssh <host> args...   plain ssh to <host> with the shared options
# Commands go to the remote `bash -ls` on stdin, so the remote login shell (fish, zsh) doesn't matter.
# Variables already in the environment win over local.env. Variables from before the rename still work: each
# MEDLEY_<name> also sets OPENMUSIC_<name> unless that is set (the apps do the same). Precedence, highest first:
# OPENMUSIC_<name> in the environment, MEDLEY_<name> in the environment, OPENMUSIC_<name> in local.env,
# MEDLEY_<name> in local.env.

_openmusic_legacy_aliases() {
  local _legacy _name
  for _legacy in $(compgen -e); do
    [[ "$_legacy" == MEDLEY_* ]] || continue
    _name="OPENMUSIC_${_legacy#MEDLEY_}"
    [[ -n "${!_name+x}" ]] || export "$_name=${!_legacy}"
  done
}
_openmusic_legacy_aliases

_openmusic_env="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local.env"
if [[ -f "$_openmusic_env" ]]; then
  _lineno=0
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    _lineno=$((_lineno + 1))
    [[ "$_line" =~ ^[[:space:]]*(#|$) ]] && continue
    _name="${_line%%=*}"
    _name="${_name#export }"
    _name="${_name//[[:space:]]/}"
    [[ "$_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "scripts/local.env line $_lineno: expected NAME=value" >&2; exit 2; }
    [[ -n "${!_name+x}" ]] && continue
    _value="${_line#*=}"
    _value="${_value#"${_value%%[![:space:]]*}"}"
    _value="${_value%"${_value##*[![:space:]]}"}"
    if [[ "$_value" =~ ^\"(.*)\"$ || "$_value" =~ ^\'(.*)\'$ ]]; then _value="${BASH_REMATCH[1]}"; fi
    printf -v "$_name" '%s' "$_value"
    export "${_name?}"
  done < "$_openmusic_env"
  unset _line _lineno _name _value
fi
# local.env may still use the old names.
_openmusic_legacy_aliases

OPENMUSIC_SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15)

need() {
  local v missing=()
  for v in "$@"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
  if (( ${#missing[@]} )); then
    echo "${0##*/}: set ${missing[*]} in scripts/local.env (see scripts/local.env.example) or in the environment" >&2
    exit 2
  fi
}

remote_run() {
  local host="${1:?remote_run <host> [cmd]}"; shift
  if [[ "$host" == local ]]; then
    if (( $# )); then printf '%s\n' "$*" | (cd ~ && bash -ls); else (cd ~ && bash -ls); fi
  elif (( $# )); then
    printf '%s\n' "$*" | ssh "${OPENMUSIC_SSH_OPTS[@]}" "$host" 'bash -ls'
  else
    ssh "${OPENMUSIC_SSH_OPTS[@]}" "$host" 'bash -ls'
  fi
}

remote_tty() {
  local host="${1:?remote_tty <host> <cmd>}"; shift
  ssh -t "${OPENMUSIC_SSH_OPTS[@]}" "$host" "bash -lc $(printf '%q' "$*")"
}

remote_ssh() {
  local host="${1:?remote_ssh <host> args...}"; shift
  ssh "${OPENMUSIC_SSH_OPTS[@]}" "$host" "$@"
}

# rsync/scp destination prefix for <host>: "" for local, "<host>:" otherwise.
remote_prefix() { if [[ "$1" == local ]]; then printf '%s' "$HOME/"; else printf '%s:' "$1"; fi; }
