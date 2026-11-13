#!/usr/bin/env bash
# serva - sysctl module: kernel network hardening (ip_forward is never touched: Docker needs it).
SYSCTL_FILE=/etc/sysctl.d/99-serva.conf

sysctl::describe() { printf 'Kernel network hardening'; }

sysctl::render() {
  cat <<'EOT'
# Managed by serva: network hardening. Remove this file and run 'sysctl --system' to revert.
# Protect against SYN flood attacks.
net.ipv4.tcp_syncookies = 1
# Drop packets with spoofed source addresses. Loose mode (2) on purpose: strict
# mode (1) can break Docker and WireGuard, which route replies through another interface.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# Ignore ICMP redirects and source-routed packets: they can reroute traffic.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Log packets with impossible addresses; ignore broadcast pings and bogus ICMP errors.
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Hide kernel messages from unprivileged users.
kernel.dmesg_restrict = 1
EOT
}

sysctl::check() {
  [[ -f "$SYSCTL_FILE" ]] && cmp -s "$SYSCTL_FILE" <(sysctl::render) &&
    [[ "$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)" == 1 ]]
}

sysctl::apply() {
  sysctl::render | core::write_file "$SYSCTL_FILE" 644 root:root || return 1
  core::run sysctl -q -p "$SYSCTL_FILE" || log::warn "Some kernel settings could not be applied now (see ${SERVA_LOG}); the file applies at next boot."
  report::note "Kernel network hardening in ${SYSCTL_FILE}. Remove it and run 'sysctl --system' to revert."
}
