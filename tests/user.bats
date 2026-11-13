#!/usr/bin/env bats
# shellcheck disable=SC2317 # functions overridden in tests are called indirectly
# Tests for modules/base/user.sh: the key validator is what keeps the owner
# from being locked out, so it gets the most attention.

load test_helper

setup() {
  serva_load
  serva_load_module user
  command -v ssh-keygen >/dev/null || skip "ssh-keygen is not installed"
  ssh-keygen -q -t ed25519 -N '' -C 'alice@laptop' -f "${BATS_TEST_TMPDIR}/k"
  KEY_TYPE_B64="$(cut -d' ' -f1,2 "${BATS_TEST_TMPDIR}/k.pub")"
}

@test "describe fits in 45 characters" {
  run user::describe
  [ "$status" -eq 0 ]
  [ "${#output}" -le 45 ]
}

@test "normalize_key accepts a real ed25519 key and keeps its comment" {
  run user::normalize_key "$(cat "${BATS_TEST_TMPDIR}/k.pub")"
  [ "$status" -eq 0 ]
  [ "$output" = "${KEY_TYPE_B64} alice@laptop" ]
}

@test "normalize_key accepts a key without comment" {
  run user::normalize_key "$KEY_TYPE_B64"
  [ "$status" -eq 0 ]
  [ "$output" = "$KEY_TYPE_B64" ]
}

@test "normalize_key strips authorized_keys options" {
  local line="no-port-forwarding,command=\"echo 'Please login as the user ubuntu'\" ${KEY_TYPE_B64} cloud-key"
  run user::normalize_key "$line"
  [ "$status" -eq 0 ]
  [ "$output" = "${KEY_TYPE_B64} cloud-key" ]
}

@test "normalize_key strips a trailing carriage return and spaces" {
  run user::normalize_key "${KEY_TYPE_B64} my key  "$'\r'
  [ "$status" -eq 0 ]
  [ "$output" = "${KEY_TYPE_B64} my key" ]
}

@test "normalize_key rejects the documentation placeholder" {
  run user::normalize_key "ssh-ed25519 AAAA... haritiana-vps-2026"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "normalize_key rejects a well-formed type with a fake blob" {
  run user::normalize_key "ssh-ed25519 AAAA haritiana-vps-2026"
  [ "$status" -eq 1 ]
}

@test "normalize_key rejects a truncated key" {
  run user::normalize_key "${KEY_TYPE_B64:0:40}"
  [ "$status" -eq 1 ]
}

@test "normalize_key rejects a private key line" {
  run user::normalize_key "-----BEGIN OPENSSH PRIVATE KEY-----"
  [ "$status" -eq 1 ]
  run user::normalize_key "ssh-ed25519 AAAA PRIVATE KEY"
  [ "$status" -eq 1 ]
}

@test "normalize_key rejects garbage and empty input" {
  run user::normalize_key "hello world"
  [ "$status" -eq 1 ]
  run user::normalize_key ""
  [ "$status" -eq 1 ]
  run user::normalize_key "ssh-ed25519"
  [ "$status" -eq 1 ]
}

@test "normalize_key rejects ssh-dss" {
  run user::normalize_key "ssh-dss AAAAB3NzaC1kc3MAAACBAP== old"
  [ "$status" -eq 1 ]
}

@test "normalize_key rejects a 1024-bit RSA key but accepts 3072 bits" {
  ssh-keygen -q -t rsa -b 1024 -N '' -f "${BATS_TEST_TMPDIR}/rsa1024" 2>/dev/null ||
    skip "this OpenSSH cannot generate 1024-bit RSA keys"
  run user::normalize_key "$(cat "${BATS_TEST_TMPDIR}/rsa1024.pub")"
  [ "$status" -eq 1 ]
  ssh-keygen -q -t rsa -b 3072 -N '' -f "${BATS_TEST_TMPDIR}/rsa3072"
  run user::normalize_key "$(cat "${BATS_TEST_TMPDIR}/rsa3072.pub")"
  [ "$status" -eq 0 ]
}

@test "normalize_key accepts ecdsa keys" {
  ssh-keygen -q -t ecdsa -b 256 -N '' -f "${BATS_TEST_TMPDIR}/ec"
  run user::normalize_key "$(cat "${BATS_TEST_TMPDIR}/ec.pub")"
  [ "$status" -eq 0 ]
  [[ "$output" == ecdsa-sha2-nistp256\ * ]]
}

# refute CMD...: succeed only when CMD fails (a bare "!" never fails a bats test).
refute() { if "$@"; then return 1; fi; }

@test "valid_name accepts normal names and refuses root and bad characters" {
  user::valid_name deploy
  user::valid_name _svc-1
  refute user::valid_name root
  refute user::valid_name Alice
  refute user::valid_name 1abc
  refute user::valid_name "a b"
  refute user::valid_name ""
  refute user::valid_name "$(printf 'a%.0s' {1..33})"
}

@test "_keys_in prints the valid keys, reports the others and adds a default comment" {
  local text
  text="$(printf '%s\n' "# comment" "" "$KEY_TYPE_B64 first" "garbage" "$KEY_TYPE_B64" "ssh-ed25519 AAAA... placeholder")"
  run user::_keys_in "$text" "test" "github:bob"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$KEY_TYPE_B64 first"* ]]
  [[ "$output" == *"$KEY_TYPE_B64 github:bob"* ]]
  [[ "$output" == *"line 4"* && "$output" == *"line 6"* ]]
}

@test "_keys_in fails when no line is usable and never echoes a private key" {
  run user::_keys_in "$(printf '%s\n' "-----BEGIN OPENSSH PRIVATE KEY-----" "SECRETBODYLINE1")" "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRIVATE key"* ]]
  [[ "$output" != *SECRETBODY* ]]
  run user::_keys_in "" "test"
  [ "$status" -eq 1 ]
}

@test "_install_keys merges without duplicates and keeps the other lines" {
  os::user_home() { printf '%s' "${BATS_TEST_TMPDIR}/home"; }
  core::run() { :; }
  core::write_file() { cat >"$1"; }
  local f="${BATS_TEST_TMPDIR}/home/.ssh/authorized_keys" other
  ssh-keygen -q -t ed25519 -N '' -f "${BATS_TEST_TMPDIR}/k2"
  other="$(cut -d' ' -f1,2 "${BATS_TEST_TMPDIR}/k2.pub")"
  mkdir -p "${BATS_TEST_TMPDIR}/home/.ssh"
  printf '%s\n' "# mine" "$KEY_TYPE_B64 old-comment" >"$f"
  user::_install_keys alice "$(printf '%s\n' "$KEY_TYPE_B64 new-comment" "$other bob" "$other bob")"
  [ "$(grep -c . "$f")" -eq 3 ]
  grep -qx "# mine" "$f"
  grep -qx "$KEY_TYPE_B64 old-comment" "$f"
  grep -qx "$other bob" "$f"
}

@test "has_valid_key needs a usable key in the user's authorized_keys" {
  # getent resolves the home directory: use the current user, whose home we
  # can point at a temporary directory only by overriding os::user_home.
  os::user_home() { printf '%s' "${BATS_TEST_TMPDIR}/home"; }
  mkdir -p "${BATS_TEST_TMPDIR}/home/.ssh"
  local f="${BATS_TEST_TMPDIR}/home/.ssh/authorized_keys"
  refute user::has_valid_key alice
  printf '%s\n' "ssh-ed25519 AAAA... placeholder" >"$f"
  refute user::has_valid_key alice
  printf '%s\n' "# comment" "ssh-ed25519 AAAA... placeholder" "$KEY_TYPE_B64 real" >"$f"
  user::has_valid_key alice
}
