#!/usr/bin/env bash
# serva - system helpers: detection, packages, services, facts.

: "${SERVA_OS_RELEASE:=/etc/os-release}"
OS_ID='' OS_VERSION_ID='' OS_PRETTY=''
_SERVA_APT_UPDATED=0

# os-release is parsed, never sourced.
os::_release_value() { sed -n "s/^${1}=//p" "$SERVA_OS_RELEASE" | head -n 1 | tr -d "\"'"; }

os::detect() {
  [[ -r "$SERVA_OS_RELEASE" ]] || return 1
  OS_ID="$(os::_release_value ID)"
  OS_VERSION_ID="$(os::_release_value VERSION_ID)"
  OS_PRETTY="$(os::_release_value PRETTY_NAME)"
}

os::is_supported() { [[ "${OS_ID}:${OS_VERSION_ID}" =~ ^(ubuntu:2[46]\.04|debian:1[23])$ ]]; }

os::require_supported() {
  os::detect || core::die "Cannot read ${SERVA_OS_RELEASE}."
  os::is_supported && return 0
  core::is_yes "${SERVA_FORCE_OS:-no}" ||
    core::die "Unsupported system: ${OS_PRETTY:-unknown}. serva supports Ubuntu 24.04/26.04 LTS and Debian 12/13 (SERVA_FORCE_OS=yes to try anyway)."
  log::warn "Untested system (${OS_PRETTY:-unknown}): continuing because SERVA_FORCE_OS is set."
}

os::has_systemd() { [[ -d /run/systemd/system ]]; }

os::is_installed() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == *"ok installed" ]]; }

os::_apt() {
  core::run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y -q \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

os::apt_update_once() {
  ((_SERVA_APT_UPDATED)) && return 0
  log::info "Refreshing package lists..."
  os::_apt update || return 1
  core::is_dry_run || _SERVA_APT_UPDATED=1
}

# os::apt_install PKG...: install the missing ones.
os::apt_install() {
  local missing=() pkg
  for pkg in "$@"; do os::is_installed "$pkg" || missing+=("$pkg"); done
  ((${#missing[@]})) || return 0
  os::apt_update_once || return 1
  log::info "Installing ${missing[*]}..."
  os::_apt install "${missing[@]}"
}

os::apt_full_upgrade() { os::apt_update_once && os::_apt full-upgrade; }

os::mem_mb() { awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo; }

os::disk_free_mb() { df -Pm "${1:-/}" | awk 'NR == 2 { print $4 }'; }

# Source address of the default IPv4 route (empty without one).
os::primary_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true
}

os::hostname() { hostname -f 2>/dev/null || hostname; }

# IP address of the SSH client of this session, when it can be found.
os::client_ip() {
  local ip="${SSH_CLIENT:-}"
  ip="${ip%% *}"
  [[ -n "$ip" ]] || ip="$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p')"
  [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] && printf '%s' "$ip"
  return 0
}

# sshd will not test its config without /run/sshd, which is missing while a
# socket-activated sshd has not started yet.
os::_sshd_runtime_dir() { [[ -d /run/sshd ]] || install -d -m 0755 /run/sshd 2>/dev/null || true; }

# os::sshd_effective [USER]: effective sshd configuration (sshd -T).
# shellcheck disable=SC2120 # the user is optional
os::sshd_effective() {
  os::_sshd_runtime_dir
  if [[ -n "${1:-}" ]]; then
    sshd -T -C "user=${1},host=localhost,addr=127.0.0.1" 2>/dev/null
  else
    sshd -T 2>/dev/null
  fi
}

# TCP port(s) of sshd, one per line (22 when unknown).
os::ssh_ports() {
  local ports
  # shellcheck disable=SC2119 # no user: global configuration
  ports="$(os::sshd_effective | awk '$1 == "port" { print $2 }' | sort -un)"
  printf '%s\n' "${ports:-22}"
}

# Apply a new sshd configuration without dropping open sessions.
os::reload_ssh() {
  if systemctl is-active --quiet ssh.service; then
    core::run systemctl reload ssh.service
  elif systemctl is-active --quiet ssh.socket; then
    log::info "SSH is socket-activated: new connections use the new configuration."
  else
    core::run systemctl restart ssh.service
  fi
}

os::user_home() { getent passwd "$1" | cut -d: -f6; }

# Password status: P (usable), L (locked) or NP (none).
os::password_status() { passwd -S "$1" 2>/dev/null | awk '{ print $2 }'; }
