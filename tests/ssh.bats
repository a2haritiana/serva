#!/usr/bin/env bats
# Tests for modules/base/ssh.sh (pure functions only: no root, no real system).

load test_helper

setup() {
  serva_load
  serva_load_module ssh
  unset SERVA_SSH_CONFIRM_TIMEOUT
}

@test "describe fits in 45 characters" {
  run ssh::describe
  [ "$status" -eq 0 ]
  [ "${#output}" -le 45 ]
}

@test "render has the exact hardening lines" {
  run ssh::render alice
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "# Managed by serva (https://github.com/a2haritiana/serva)." ]
  [ "${lines[1]}" = "# Remove this file and reload ssh to go back to the distribution defaults." ]
  local expected=(
    "PermitRootLogin no"
    "PasswordAuthentication no"
    "KbdInteractiveAuthentication no"
    "PermitEmptyPasswords no"
    "PubkeyAuthentication yes"
    "AuthenticationMethods publickey"
    "AllowUsers alice"
    "MaxAuthTries 3"
    "LoginGraceTime 30"
    "ClientAliveInterval 300"
    "ClientAliveCountMax 2"
    "X11Forwarding no"
    "AllowAgentForwarding no"
  )
  [ "${#lines[@]}" -eq $((2 + ${#expected[@]})) ]
  local i
  for i in "${!expected[@]}"; do
    [ "${lines[i + 2]}" = "${expected[i]}" ]
  done
}

@test "timeout accepts 30..900 and defaults to 120" {
  run ssh::_timeout
  [ "$output" = 120 ]
  SERVA_SSH_CONFIRM_TIMEOUT=30 run ssh::_timeout
  [ "$status" -eq 0 ] && [ "$output" = 30 ]
  SERVA_SSH_CONFIRM_TIMEOUT=900 run ssh::_timeout
  [ "$status" -eq 0 ] && [ "$output" = 900 ]
  local bad
  for bad in 29 901 abc "" 12.5 -5 0100x; do
    [ -n "$bad" ] || continue
    SERVA_SSH_CONFIRM_TIMEOUT="$bad" run ssh::_timeout
    [ "$status" -eq 1 ]
    [[ "$output" == *SERVA_SSH_CONFIRM_TIMEOUT* ]]
  done
}

@test "effective_ok needs all three hardened values" {
  os::sshd_effective() { printf '%s\n' "$EFF"; }
  EFF=$'port 22\npermitrootlogin no\npasswordauthentication no\nkbdinteractiveauthentication no' run ssh::_effective_ok alice
  [ "$status" -eq 0 ]
  EFF=$'permitrootlogin no\npasswordauthentication yes\nkbdinteractiveauthentication no' run ssh::_effective_ok alice
  [ "$status" -eq 1 ]
  EFF=$'permitrootlogin prohibit-password\npasswordauthentication no\nkbdinteractiveauthentication no' run ssh::_effective_ok alice
  [ "$status" -eq 1 ]
  EFF="" run ssh::_effective_ok alice
  [ "$status" -eq 1 ]
}

@test "rollback script is valid sh and restores the previous drop-in" {
  # shellcheck disable=SC2034 # read by the sourced module
  SSH_DROPIN="${BATS_TEST_TMPDIR}/00-serva.conf" SSH_PREV="${BATS_TEST_TMPDIR}/prev" SSH_SCRIPT="${BATS_TEST_TMPDIR}/rb.sh"
  # The real core::write_file chowns to root, which a non-root test cannot do.
  core::write_file() { cat >"$1" && chmod "$2" "$1"; }
  ssh::_write_rollback_script
  [ -x "$SSH_SCRIPT" ]
  sh -n "$SSH_SCRIPT"
  grep -q "^if \[ -f \"${SSH_PREV}\" \]; then cp -p \"${SSH_PREV}\" \"${SSH_DROPIN}\"; else rm -f \"${SSH_DROPIN}\"; fi\$" "$SSH_SCRIPT"
  grep -q '^mkdir -p /run/sshd$' "$SSH_SCRIPT"
  grep -q 'sshd -t' "$SSH_SCRIPT"
  grep -q 'ROLLBACK' "$SSH_SCRIPT"
}

@test "rendered config is accepted by sshd -t" {
  local sshd
  sshd="$(command -v sshd || true)"
  [ -n "$sshd" ] || [ ! -x /usr/sbin/sshd ] || sshd=/usr/sbin/sshd
  [ -n "$sshd" ] || skip "sshd is not installed"
  command -v ssh-keygen >/dev/null || skip "ssh-keygen is not installed"
  local cfg="${BATS_TEST_TMPDIR}/sshd_config"
  ssh-keygen -q -t ed25519 -N '' -f "${BATS_TEST_TMPDIR}/hostkey"
  {
    printf 'HostKey %s\n' "${BATS_TEST_TMPDIR}/hostkey"
    ssh::render alice
  } >"$cfg"
  run "$sshd" -t -f "$cfg"
  if [ "$status" -ne 0 ] && [[ "$output" == *"privilege separation"* || "$output" == *"/run/sshd"* || "$output" == *"Permission denied"* ]]; then
    skip "sshd -t needs root or /run/sshd here: ${output}"
  fi
  [ "$status" -eq 0 ]
}

@test "has_include finds the Include line for the drop-in directory" {
  # shellcheck disable=SC2034 # read by the sourced module
  SSH_DROPIN="${BATS_TEST_TMPDIR}/conf.d/00-serva.conf"
  # shellcheck disable=SC2034 # read by the sourced module
  SSH_MAIN_CONFIG="${BATS_TEST_TMPDIR}/sshd_config"
  printf '%s\n' "Port 22" >"$SSH_MAIN_CONFIG"
  run ssh::_has_include
  [ "$status" -eq 1 ]
  printf '%s\n' "  Include ${BATS_TEST_TMPDIR}/conf.d/*.conf  " "Port 22" >"$SSH_MAIN_CONFIG"
  run ssh::_has_include
  [ "$status" -eq 0 ]
  printf '%s\n' "# Include ${BATS_TEST_TMPDIR}/conf.d/*.conf" >"$SSH_MAIN_CONFIG"
  run ssh::_has_include
  [ "$status" -eq 1 ]
}
