#!/usr/bin/env bash
# Common set-up for bats tests: load serva's libraries without touching the
# system. Every path serva writes to points into the test's temporary folder.

serva_load() {
  export SERVA_HOME="${BATS_TEST_DIRNAME}/.."
  export NO_COLOR=1
  export SERVA_LOG="${BATS_TEST_TMPDIR}/serva.log"
  export SERVA_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  export SERVA_BACKUP_ROOT="${BATS_TEST_TMPDIR}/backups"
  export SERVA_REPORT_DIR="${BATS_TEST_TMPDIR}/reports"
  export SERVA_LOCK_FILE="${BATS_TEST_TMPDIR}/serva.lock"
  export SERVA_SESSION="test"
  # shellcheck source=../lib/core.sh
  source "${SERVA_HOME}/lib/core.sh"
  # shellcheck source=../lib/ui.sh
  source "${SERVA_HOME}/lib/ui.sh"
  # shellcheck source=../lib/os.sh
  source "${SERVA_HOME}/lib/os.sh"
  # shellcheck source=../lib/state.sh
  source "${SERVA_HOME}/lib/state.sh"
  # shellcheck source=../lib/report.sh
  source "${SERVA_HOME}/lib/report.sh"
  # shellcheck source=../lib/modules.sh
  source "${SERVA_HOME}/lib/modules.sh"
  UI_MODE=none
}

# serva_load_module NAME: source modules/base/NAME.sh after serva_load.
serva_load_module() {
  # shellcheck source=/dev/null
  source "${SERVA_HOME}/modules/base/${1}.sh"
}
