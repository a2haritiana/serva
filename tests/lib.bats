#!/usr/bin/env bats
# Tests for lib/state.sh, lib/os.sh and lib/modules.sh.

load test_helper

setup() {
  serva_load
}

write_release() {
  printf 'PRETTY_NAME="%s"\nID=%s\nVERSION_ID="%s"\n' "$1" "$2" "$3" >"$BATS_TEST_TMPDIR/os-release"
  SERVA_OS_RELEASE="$BATS_TEST_TMPDIR/os-release"
}

# --- state ------------------------------------------------------------------------

@test "state::put stores a value and replaces it" {
  state::put admin_user alice
  [ "$(state::value admin_user)" = alice ]
  state::put admin_user bob
  [ "$(state::value admin_user)" = bob ]
  [ "$(grep -c '^admin_user=' "$SERVA_STATE_DIR/state")" -eq 1 ]
}

@test "state::value prints nothing for an unknown key" {
  [ -z "$(state::value nothing)" ]
}

@test "state::module records the status, a date and the version" {
  state::module ssh done
  run state::module_last ssh
  [[ "$output" == "done "*" ${SERVA_VERSION}" ]]
}

@test "state::put writes nothing in dry-run" {
  SERVA_DRY_RUN=1
  state::put key value
  [ ! -e "$SERVA_STATE_DIR/state" ]
}

# --- os ---------------------------------------------------------------------------

@test "Ubuntu 24.04 and 26.04 are supported" {
  write_release "Ubuntu 24.04.3 LTS" ubuntu 24.04
  os::detect
  os::is_supported
  [ "$OS_ID" = ubuntu ]
  write_release "Ubuntu 26.04.1 LTS" ubuntu 26.04
  os::detect
  os::is_supported
}

@test "Debian 12 and 13 are supported" {
  write_release "Debian GNU/Linux 12 (bookworm)" debian 12
  os::detect
  os::is_supported
  write_release "Debian GNU/Linux 13 (trixie)" debian 13
  os::detect
  os::is_supported
}

@test "Ubuntu 22.04 is not supported" {
  write_release "Ubuntu 22.04.5 LTS" ubuntu 22.04
  os::detect
  run os::is_supported
  [ "$status" -ne 0 ]
}

@test "an unsupported system is refused with a hint" {
  write_release "Fedora Linux 41" fedora 41
  run os::require_supported
  [ "$status" -ne 0 ]
  [[ "$output" == *"SERVA_FORCE_OS"* ]]
}

@test "SERVA_FORCE_OS=yes lets an untested system through" {
  write_release "Fedora Linux 41" fedora 41
  SERVA_FORCE_OS=yes
  run os::require_supported
  [ "$status" -eq 0 ]
}

# --- module runner --------------------------------------------------------------------

fake::describe() { printf 'A fake module'; }
fake::check() { return "${FAKE_CHECK:-1}"; }
fake::apply() { return "${FAKE_APPLY:-0}"; }

@test "module::run skips a module that is already in place" {
  FAKE_CHECK=0
  module::run fake
  [ "${SERVA_RESULTS[0]}" = "fake|already in place" ]
}

@test "module::run records a successful module" {
  module::run fake
  [ "${SERVA_RESULTS[0]}" = "fake|done" ]
  [[ "$(state::module_last fake)" == "done "* ]]
}

@test "module::run records a module skipped by the user" {
  FAKE_APPLY=2
  module::run fake
  [ "${SERVA_RESULTS[0]}" = "fake|skipped" ]
}

@test "module::run reports a failure" {
  FAKE_APPLY=1
  run module::run fake
  [ "$status" -eq 1 ]
}

@test "module::exists knows the base modules only" {
  module::exists ssh
  run module::exists nope
  [ "$status" -ne 0 ]
}
