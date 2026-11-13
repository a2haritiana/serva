#!/usr/bin/env bash
# serva - core helpers: logging, commands, dry-run, backups, config file.

SERVA_VERSION="0.1.0-dev"

: "${SERVA_LOG:=/var/log/serva.log}"
: "${SERVA_REPORT_DIR:=/var/log/serva}"
: "${SERVA_STATE_DIR:=/var/lib/serva}"
: "${SERVA_BACKUP_ROOT:=/var/backups/serva}"
: "${SERVA_LOCK_FILE:=/run/serva.lock}"
: "${SERVA_DRY_RUN:=0}"
: "${SERVA_ASSUME_YES:=0}"
: "${SERVA_SESSION:=$(date +%Y%m%d-%H%M%S)}"
SERVA_BACKUP_DIR="${SERVA_BACKUP_ROOT}/${SERVA_SESSION}"

# Keys accepted in a --config file (see examples/serva.env.example).
SERVA_CONFIG_KEYS=" SERVA_MODULES SERVA_USER SERVA_USER_PASSWORD_HASH SERVA_PUBKEY
  SERVA_PUBKEY_GITHUB SERVA_PUBKEY_FROM_ROOT SERVA_SSH_CONFIRM_TIMEOUT SERVA_OPEN_WEB
  SERVA_F2B_IGNOREIP SERVA_UPGRADE_NOW SERVA_AUTO_REBOOT SERVA_AUTO_REBOOT_TIME
  SERVA_SWAP_SIZE SERVA_CLEANUP_USERS SERVA_CLEANUP_ROOT_KEYS SERVA_LOCK_ROOT SERVA_FORCE_OS "

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

# Messages go to stderr (stdout carries values returned by functions) and to
# the log file, except in dry-run mode.
core::_log_file() {
  [[ "$SERVA_DRY_RUN" == 1 ]] && return 0
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$SERVA_LOG" 2>/dev/null || true
}

log::info() { printf '%s %s\n' "${C_BLUE}==>${C_RESET}" "$*" >&2 && core::_log_file INFO "$*"; }
log::ok() { printf '%s %s\n' "${C_GREEN} ok${C_RESET}" "$*" >&2 && core::_log_file OK "$*"; }
log::warn() { printf '%s %s\n' "${C_YELLOW}  !${C_RESET}" "$*" >&2 && core::_log_file WARN "$*"; }
log::error() { printf '%s %s\n' "${C_RED}  x${C_RESET}" "$*" >&2 && core::_log_file ERROR "$*"; }
log::step() { printf '\n%s\n' "${C_BOLD}$*${C_RESET}" >&2 && core::_log_file STEP "$*"; }

core::die() {
  log::error "$*"
  exit 1
}

core::is_dry_run() { [[ "$SERVA_DRY_RUN" == 1 ]]; }

# core::is_yes VALUE: yes/y/true/1/on/oui/o, any case.
core::is_yes() { [[ "${1,,}" =~ ^(yes|y|true|1|on|oui|o)$ ]]; }

core::quote() {
  local out='' arg
  for arg in "$@"; do out+="$(printf '%q' "$arg") "; done
  printf '%s' "${out% }"
}

# core::run CMD...: run a command, its output going to the log file. With
# --dry-run, only print it. On failure, show the end of the log.
core::run() {
  if core::is_dry_run; then
    printf '%s %s\n' "${C_DIM}[dry-run]${C_RESET}" "$(core::quote "$@")" >&2
    return 0
  fi
  core::_log_file RUN "$(core::quote "$@")"
  "$@" >>"$SERVA_LOG" 2>&1 && return 0
  local rc=$?
  log::error "Command failed (exit ${rc}): $(core::quote "$@")"
  tail -n 15 "$SERVA_LOG" 2>/dev/null | sed 's/^/      /' >&2
  return "$rc"
}

# core::backup PATH: copy a file into this session's backup folder, keeping its
# full path (/var/backups/serva/<session>/etc/...). The first copy wins.
core::backup() {
  local src="$1" dest="${SERVA_BACKUP_DIR}${1}"
  [[ -e "$src" ]] && ! core::is_dry_run && [[ ! -e "$dest" ]] || return 0
  (umask 077 && mkdir -p "${dest%/*}") && cp -a "$src" "$dest" || return 1
  core::_log_file BACKUP "$src -> $dest"
}

# core::write_file PATH [MODE] [OWNER:GROUP] < content
# Back up the old file and install the new content (nothing if identical).
# With --dry-run, print the diff instead.
core::write_file() {
  local path="$1" mode="${2:-644}" owner="${3:-root:root}" tmp rc=0
  tmp="$(mktemp)" || return 1
  cat >"$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    :
  elif core::is_dry_run; then
    printf '%s\n' "${C_DIM}[dry-run] would write ${path}:${C_RESET}" >&2
    { if [[ -f "$path" ]]; then diff -u "$path" "$tmp"; else cat "$tmp"; fi | sed 's/^/    /' >&2; } || true
  elif core::backup "$path" && install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"; then
    core::_log_file WRITE "$path"
  else
    log::error "Could not write $path"
    rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}

# core::ensure_line FILE LINE: append LINE unless it is already there.
core::ensure_line() {
  grep -qxF -- "$2" "$1" 2>/dev/null && return 0
  if core::is_dry_run; then
    printf '%s\n' "${C_DIM}[dry-run] would add to ${1}:${C_RESET} $2" >&2
    return 0
  fi
  core::backup "$1" && printf '%s\n' "$2" >>"$1" || return 1
  core::_log_file WRITE "$1 (+ $2)"
}

# core::load_config FILE: read SERVA_KEY=value lines. Parsed, never executed.
core::load_config() {
  local file="$1" line key value n=0
  local re='^[[:space:]]*(export[[:space:]]+)?(SERVA_[A-Z0-9_]+)=(.*)$' re_q="^([\"'])(.*)\\1\$"
  [[ -r "$file" ]] || core::die "Cannot read config file: $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ $re ]] || core::die "${file}:${n}: expected SERVA_KEY=value"
    key="${BASH_REMATCH[2]}" value="${BASH_REMATCH[3]}"
    [[ "$value" =~ $re_q ]] && value="${BASH_REMATCH[2]}"
    if [[ "$SERVA_CONFIG_KEYS" != *[[:space:]]"$key"[[:space:]]* ]]; then
      log::warn "${file}:${n}: unknown key ${key} (ignored)"
      continue
    fi
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done <"$file"
}

# core::init: root, folders, log file and a lock against parallel runs.
core::init() {
  [[ "${EUID}" -eq 0 ]] || core::die "serva must run as root (try: sudo serva ...)."
  if ! core::is_dry_run; then
    (umask 077 && mkdir -p "$SERVA_STATE_DIR" "$SERVA_BACKUP_ROOT" "$SERVA_REPORT_DIR" &&
      touch "$SERVA_LOG" && chmod 600 "$SERVA_LOG") || core::die "Cannot write to ${SERVA_LOG} or /var/lib/serva."
  fi
  exec 9>"$SERVA_LOCK_FILE" || core::die "Cannot open ${SERVA_LOCK_FILE}"
  flock -n 9 || core::die "Another serva session is already running."
  core::_log_file INFO "serva ${SERVA_VERSION} session ${SERVA_SESSION} started"
}
