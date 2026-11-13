#!/usr/bin/env bash
# serva - persistent state: KEY=VALUE lines in /var/lib/serva/state.
# Each module's check function inspects the server itself; the state only
# remembers settings (admin user) and the last result of each step.

state::_file() { printf '%s/state' "$SERVA_STATE_DIR"; }

# state::put KEY VALUE (no-op in dry-run)
state::put() {
  local file tmp
  core::is_dry_run && return 0
  file="$(state::_file)"
  (umask 077 && mkdir -p "$SERVA_STATE_DIR") && tmp="$(mktemp "${SERVA_STATE_DIR}/.state.XXXXXX")" || return 1
  { grep -v -- "^${1}=" "$file" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  mv -f "$tmp" "$file"
}

state::value() { grep -m 1 -- "^${1}=" "$(state::_file)" 2>/dev/null | cut -d= -f2- || true; }

# state::module NAME STATUS: stores "STATUS DATE VERSION".
state::module() { state::put "module.${1}" "${2} $(date -u +%Y-%m-%dT%H:%M:%SZ) ${SERVA_VERSION}"; }

state::module_last() { state::value "module.${1}"; }
