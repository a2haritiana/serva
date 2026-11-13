#!/usr/bin/env bash
# serva - fail2ban module: ban IP addresses that brute-force SSH.

F2B_JAIL=/etc/fail2ban/jail.d/serva.local

fail2ban::describe() { printf 'Ban IPs that brute-force SSH'; }

# fail2ban::render IGNOREIP PORTS: extra addresses never banned (space-separated, may be empty), SSH ports (comma-separated).
fail2ban::render() {
  local ignore="${1:-}" ports="${2:-22}"
  cat <<EOT
# Managed by serva.
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1${ignore:+ ${ignore}}

[sshd]
enabled = true
backend = systemd
port = ${ports}
maxretry = 5
findtime = 10m
bantime = 1h
EOT
}

# Addresses and ranges only (spaces or commas), so a config value cannot
# inject extra lines into the jail file. Prints them space-separated.
fail2ban::normalize_ignoreip() {
  local value="${1//,/ }" out
  [[ "$value" =~ ^[0-9A-Fa-f:./[:blank:]]+$ ]] || return 1
  read -r -a out <<<"$value"
  printf '%s' "${out[*]}"
}

fail2ban::check() {
  [[ -f "$F2B_JAIL" ]] && systemctl is-active --quiet fail2ban && fail2ban-client status sshd &>/dev/null
}

fail2ban::apply() {
  local ignore ports ip
  # The systemd backend needs python3-systemd (Debian 12 has no auth.log).
  os::apt_install fail2ban python3-systemd || return 1

  ignore="${SERVA_F2B_IGNOREIP:-}"
  if [[ "${ignore,,}" == none ]]; then
    ignore=''
  elif [[ -n "$ignore" ]]; then
    ignore="$(fail2ban::normalize_ignoreip "$ignore")" || {
      log::error "SERVA_F2B_IGNOREIP must be IP addresses or ranges separated by spaces, or 'none'."
      return 1
    }
  elif ui::is_interactive && ip="$(os::client_ip)" && [[ -n "$ip" ]] &&
    ui::yesno "Never ban your address" "Never ban your current IP address (${ip})? Choose No if it changes often." yes; then
    ignore="$ip"
  fi

  ports="$(os::ssh_ports | paste -sd, -)"
  core::write_file "$F2B_JAIL" 644 root:root < <(fail2ban::render "$ignore" "$ports") || return 1
  core::run systemctl enable fail2ban || return 1
  core::run systemctl restart fail2ban || return 1

  if ! core::is_dry_run; then
    for _ in {1..10}; do
      fail2ban-client status sshd &>/dev/null && break
      sleep 1
    done
    fail2ban-client status sshd &>/dev/null || {
      log::error "fail2ban did not start the SSH jail. See: journalctl -u fail2ban"
      return 1
    }
  fi

  report::note "fail2ban bans an address for 1 hour after 5 failed SSH logins in 10 minutes (ports ${ports})${ignore:+. Never banned: ${ignore}}."
}
