#!/usr/bin/env bats
# Tests for lib/core.sh: command execution, dry-run, files, config parsing.

load test_helper

setup() {
  serva_load
  OWNER="$(id -un):$(id -gn)"
}

@test "core::run executes the command and logs it" {
  run core::run touch "$BATS_TEST_TMPDIR/created"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/created" ]
  grep -q '\[RUN\] touch' "$SERVA_LOG"
}

@test "core::run returns the exit status of a failing command" {
  run core::run false
  [ "$status" -eq 1 ]
  [[ "$output" == *"Command failed"* ]]
}

@test "core::run in dry-run only prints the command" {
  SERVA_DRY_RUN=1
  run core::run touch "$BATS_TEST_TMPDIR/not-created"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/not-created" ]
  [[ "$output" == *"[dry-run]"*"touch"* ]]
}

@test "core::write_file writes the content and mode, and backs up the old file" {
  local f="$BATS_TEST_TMPDIR/etc/app.conf"
  mkdir -p "$(dirname "$f")"
  echo old >"$f"
  run core::write_file "$f" 600 "$OWNER" <<<"new"
  [ "$status" -eq 0 ]
  [ "$(cat "$f")" = new ]
  [ "$(stat -c %a "$f")" = 600 ]
  [ "$(cat "${SERVA_BACKUP_DIR}${f}")" = old ]
}

@test "core::write_file leaves an identical file alone" {
  local f="$BATS_TEST_TMPDIR/same.conf"
  echo same >"$f"
  run core::write_file "$f" 644 "$OWNER" <<<"same"
  [ "$status" -eq 0 ]
  [ ! -e "${SERVA_BACKUP_DIR}${f}" ]
}

@test "core::write_file in dry-run shows the content and writes nothing" {
  SERVA_DRY_RUN=1
  local f="$BATS_TEST_TMPDIR/new.conf"
  run core::write_file "$f" 644 "$OWNER" <<<"hello"
  [ "$status" -eq 0 ]
  [ ! -e "$f" ]
  [[ "$output" == *"would write"*"hello"* ]]
}

@test "core::ensure_line adds a line only once" {
  local f="$BATS_TEST_TMPDIR/fstab"
  : >"$f"
  core::ensure_line "$f" "/swapfile none swap sw 0 0"
  core::ensure_line "$f" "/swapfile none swap sw 0 0"
  [ "$(grep -c swapfile "$f")" -eq 1 ]
}

@test "core::is_yes accepts yes in several forms and refuses the rest" {
  core::is_yes yes
  core::is_yes Y
  core::is_yes true
  core::is_yes oui
  run core::is_yes no
  [ "$status" -ne 0 ]
  run core::is_yes ''
  [ "$status" -ne 0 ]
}

@test "core::load_config reads SERVA_ keys, with or without quotes" {
  cat >"$BATS_TEST_TMPDIR/s.env" <<'EOF'
# a comment

SERVA_USER=alice
SERVA_SWAP_SIZE="2G"
export SERVA_OPEN_WEB='no'
EOF
  core::load_config "$BATS_TEST_TMPDIR/s.env"
  [ "$SERVA_USER" = alice ]
  [ "$SERVA_SWAP_SIZE" = 2G ]
  [ "$SERVA_OPEN_WEB" = no ]
}

@test "core::load_config never executes values" {
  # shellcheck disable=SC2016 # the $(...) must stay literal
  printf 'SERVA_USER=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/s.env"
  core::load_config "$BATS_TEST_TMPDIR/s.env"
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ "$SERVA_USER" = "\$(touch $BATS_TEST_TMPDIR/pwned)" ]
}

@test "core::load_config rejects lines that are not SERVA_KEY=value" {
  echo 'rm -rf /' >"$BATS_TEST_TMPDIR/s.env"
  run core::load_config "$BATS_TEST_TMPDIR/s.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected SERVA_KEY=value"* ]]
}

@test "core::load_config warns about unknown keys and ignores them" {
  echo 'SERVA_NOPE=1' >"$BATS_TEST_TMPDIR/s.env"
  run core::load_config "$BATS_TEST_TMPDIR/s.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown key SERVA_NOPE"* ]]
}
