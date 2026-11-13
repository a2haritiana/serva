#!/usr/bin/env bats
# Pure functions of the firewall, fail2ban, updates, swap, sysctl and cleanup
# modules: renderers, validators, parsers and calculations. No root needed.

load test_helper

setup() {
  serva_load
  local m
  for m in firewall fail2ban updates swap sysctl cleanup; do
    serva_load_module "$m"
  done
}

# --- swap ----------------------------------------------------------------------

@test "swap::to_mb converts G and M sizes" {
  [ "$(swap::to_mb 2G)" = 2048 ]
  [ "$(swap::to_mb 2g)" = 2048 ]
  [ "$(swap::to_mb 1536M)" = 1536 ]
  [ "$(swap::to_mb 512m)" = 512 ]
}

@test "swap::to_mb refuses invalid sizes" {
  run swap::to_mb abc
  [ "$status" -eq 1 ]
  run swap::to_mb 0
  [ "$status" -eq 1 ]
  run swap::to_mb 0G
  [ "$status" -eq 1 ]
  run swap::to_mb 2
  [ "$status" -eq 1 ]
  run swap::to_mb ''
  [ "$status" -eq 1 ]
  run swap::to_mb -2G
  [ "$status" -eq 1 ]
}

@test "swap::to_mb does not read leading zeros as octal" {
  [ "$(swap::to_mb 08G)" = 8192 ]
}

@test "swap::recommended follows the amount of RAM" {
  [ "$(swap::recommended 1024)" = 2G ]
  [ "$(swap::recommended 4096)" = 2G ]
  [ "$(swap::recommended 8192)" = 2G ]
  [ "$(swap::recommended 16384)" = 4G ]
}

# --- fail2ban --------------------------------------------------------------------

@test "fail2ban::render without extra address" {
  run fail2ban::render '' 22
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "# Managed by serva." ]]
  [[ "$output" == *$'ignoreip = 127.0.0.1/8 ::1\n'* ]]
  [[ "$output" == *"port = 22"* ]]
  [[ "$output" == *"backend = systemd"* ]]
  [[ "$output" == *"maxretry = 5"* ]]
  [[ "$output" == *"bantime = 1h"* ]]
}

@test "fail2ban::render with an extra address" {
  run fail2ban::render '203.0.113.7' 22
  [[ "$output" == *$'ignoreip = 127.0.0.1/8 ::1 203.0.113.7\n'* ]]
}

@test "fail2ban::render with several ports" {
  run fail2ban::render '' 22,2222
  [[ "$output" == *"port = 22,2222"* ]]
}

@test "fail2ban::normalize_ignoreip accepts addresses and refuses junk" {
  [ "$(fail2ban::normalize_ignoreip '1.2.3.4,10.0.0.0/8  2001:db8::1')" = '1.2.3.4 10.0.0.0/8 2001:db8::1' ]
  run fail2ban::normalize_ignoreip $'1.2.3.4\nmaxretry = 100'
  [ "$status" -eq 1 ]
  run fail2ban::normalize_ignoreip 'example.com'
  [ "$status" -eq 1 ]
  run fail2ban::normalize_ignoreip $'1.2.3.4\n5.6.7.8'
  [ "$status" -eq 1 ]
}

# --- sysctl ----------------------------------------------------------------------

@test "sysctl::render sets loose rp_filter and never touches ip_forward" {
  run sysctl::render
  [ "$status" -eq 0 ]
  [[ "$output" == *"net.ipv4.conf.all.rp_filter = 2"* ]]
  [[ "$output" == *"net.ipv4.conf.default.rp_filter = 2"* ]]
  [[ "$output" == *"net.ipv4.tcp_syncookies = 1"* ]]
  [[ "$output" != *ip_forward* ]]
}

@test "sysctl::render starts with the revert hint" {
  run sysctl::render
  [[ "${lines[0]}" == "# Managed by serva: network hardening. Remove this file and run 'sysctl --system' to revert." ]]
}

# --- updates ---------------------------------------------------------------------

@test "updates::render_policy with reboot" {
  run updates::render_policy yes 03:30
  [[ "$output" == *'Unattended-Upgrade::Automatic-Reboot "true";'* ]]
  [[ "$output" == *'Unattended-Upgrade::Automatic-Reboot-Time "03:30";'* ]]
  [[ "$output" == *'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";'* ]]
  [[ "${lines[0]}" == "// Managed by serva." ]]
}

@test "updates::render_policy without reboot has no time line" {
  run updates::render_policy no 03:30
  [[ "$output" == *'Unattended-Upgrade::Automatic-Reboot "false";'* ]]
  [[ "$output" != *Reboot-Time* ]]
  [[ "$output" != *03:30* ]]
}

@test "updates::render_periodic enables daily unattended upgrades" {
  run updates::render_periodic
  [[ "$output" == *'APT::Periodic::Update-Package-Lists "1";'* ]]
  [[ "$output" == *'APT::Periodic::Unattended-Upgrade "1";'* ]]
  [[ "$output" == *'APT::Periodic::AutocleanInterval "7";'* ]]
}

# --- cleanup ---------------------------------------------------------------------

@test "cleanup::expire_is_past reads the shadow expiry field" {
  run cleanup::expire_is_past ''
  [ "$status" -ne 0 ]
  run cleanup::expire_is_past -1
  [ "$status" -ne 0 ]
  cleanup::expire_is_past 1
  run cleanup::expire_is_past 999999
  [ "$status" -ne 0 ]
}

@test "cleanup::guard stops on an unmet precondition, except in dry-run" {
  cleanup::guard yes "ignored"
  run cleanup::guard no "not ready"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not ready"* ]]
  SERVA_DRY_RUN=1
  run cleanup::guard no "not ready"
  [ "$status" -eq 0 ]
}

@test "cleanup::root_keys lists only valid keys" {
  [[ -f "${SERVA_HOME}/modules/base/user.sh" ]] || skip "user.sh not written yet"
  serva_load_module user
  local key
  key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test@serva"
  CLEANUP_ROOT_KEYS_FILE="${BATS_TEST_TMPDIR}/authorized_keys"
  printf '# a comment\nnot a key\n%s\n' "$key" >"$CLEANUP_ROOT_KEYS_FILE"
  run cleanup::root_keys
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == ssh-ed25519\ * ]]
}

@test "cleanup::root_keys is empty when the file is missing" {
  [[ -f "${SERVA_HOME}/modules/base/user.sh" ]] || skip "user.sh not written yet"
  serva_load_module user
  CLEANUP_ROOT_KEYS_FILE="${BATS_TEST_TMPDIR}/none"
  run cleanup::root_keys
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- all modules -----------------------------------------------------------------

@test "every describe is at most 45 characters and prints no newline" {
  local m out
  for m in firewall fail2ban updates swap sysctl cleanup; do
    out="$("${m}::describe"; printf x)"
    out="${out%x}"
    [[ "$out" != *$'\n'* ]]
    [ "${#out}" -le 45 ]
    [ "${#out}" -gt 0 ]
  done
}
