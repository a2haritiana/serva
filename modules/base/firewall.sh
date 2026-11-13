#!/usr/bin/env bash
# serva - firewall module: ufw, deny incoming, only SSH (and web ports) open.
# Known limit: Docker-published ports bypass ufw (serva v0.2 adds ufw-docker).

firewall::describe() { printf 'Firewall: only SSH (and web ports) open'; }

firewall::check() {
  local status ports port
  status="$(ufw status verbose 2>/dev/null)" || return 1
  grep -q '^Status: active' <<<"$status" || return 1
  grep -q '^Default: deny (incoming)' <<<"$status" || return 1
  mapfile -t ports < <(os::ssh_ports)
  for port in "${ports[@]}"; do
    # "22/tcp" or a bare "22"; ALLOW or LIMIT.
    grep -Eq "^${port}(/tcp)?[[:space:]]+(ALLOW|LIMIT)" <<<"$status" || return 1
  done
}

firewall::apply() {
  local web=yes ports port
  os::apt_install ufw || return 1

  if [[ -n "${SERVA_OPEN_WEB:-}" ]]; then
    core::is_yes "$SERVA_OPEN_WEB" || web=no
  else
    ui::yesno "Web ports" "Open ports 80 and 443 for websites and apps?" yes || web=no
  fi

  # SSH rules come first: with "deny" as default and no SSH rule, new SSH
  # connections would be refused. "limit" also slows down brute force.
  mapfile -t ports < <(os::ssh_ports)
  for port in "${ports[@]}"; do
    core::run ufw limit "${port}/tcp" comment 'SSH (serva)' || return 1
  done
  if [[ "$web" == yes ]]; then
    core::run ufw allow 80/tcp comment 'HTTP (serva)' || return 1
    core::run ufw allow 443/tcp comment 'HTTPS (serva)' || return 1
  fi
  core::run ufw default deny incoming || return 1
  core::run ufw default allow outgoing || return 1
  core::run ufw --force enable || return 1

  report::note "Firewall active: incoming traffic blocked except SSH (${ports[*]}, rate-limited)."
  if [[ "$web" == yes ]]; then
    report::note "Ports 80 and 443 are open."
  else
    report::note "Ports 80 and 443 are closed: open them later with 'ufw allow 80/tcp' and 'ufw allow 443/tcp'."
  fi
}
