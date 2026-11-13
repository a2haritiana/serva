#!/usr/bin/env bats
# Tests for the serva entry point (commands that need neither root nor changes).

load test_helper

setup() {
  SERVA="${BATS_TEST_DIRNAME}/../serva"
  export NO_COLOR=1
}

@test "serva --version prints the version" {
  run "$SERVA" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "serva "* ]]
}

@test "serva --help shows the usage and the steps" {
  run "$SERVA" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: sudo serva"* ]]
  [[ "$output" == *"user ssh firewall fail2ban updates swap sysctl cleanup"* ]]
}

@test "serva list describes every step" {
  run "$SERVA" list
  [ "$status" -eq 0 ]
  for m in user ssh firewall fail2ban updates swap sysctl cleanup; do
    [[ "$output" == *"$m"* ]]
  done
}

@test "an unknown option is refused" {
  run "$SERVA" --nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "commands that change the system require root" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  run "$SERVA" status
  [ "$status" -ne 0 ]
  [[ "$output" == *"must run as root"* ]]
}

@test "every module defines describe, check and apply, with a short description" {
  serva_load
  module::load_all
  for m in "${SERVA_BASE_MODULES[@]}"; do
    declare -F "${m}::describe" "${m}::check" "${m}::apply" >/dev/null
    desc="$("${m}::describe")"
    [ "${#desc}" -le 45 ]
  done
}
