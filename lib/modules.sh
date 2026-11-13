#!/usr/bin/env bash
# serva - module registry and runner.
#
# A module is modules/base/<name>.sh defining:
#   <name>::describe  one line (max 45 characters)
#   <name>::check     0 if already in place; silent and read-only
#   <name>::apply     0 done, 1 failed, 2 skipped by the user
# apply runs inside "||", where bash ignores "set -e": every command that
# matters must be followed by "|| return 1".

SERVA_BASE_MODULES=(user ssh firewall fail2ban updates swap sysctl cleanup)

module::load_all() {
  local m
  for m in "${SERVA_BASE_MODULES[@]}"; do
    # shellcheck source=/dev/null
    source "${SERVA_HOME}/modules/base/${m}.sh"
  done
}

module::exists() { [[ " ${SERVA_BASE_MODULES[*]} " == *" ${1:-} "* ]]; }

# module::run NAME: returns 1 only if the module failed.
module::run() {
  local m="$1" rc=0 suffix=''
  core::is_dry_run && suffix=' (dry run)'
  log::step "[${m}] $("${m}::describe")"
  if "${m}::check"; then
    log::ok "Already in place."
    SERVA_RESULTS+=("${m}|already in place")
    state::module "$m" ok
    return 0
  fi
  "${m}::apply" || rc=$?
  case "$rc" in
    0)
      SERVA_RESULTS+=("${m}|done${suffix}")
      state::module "$m" "done"
      log::ok "${m}: done${suffix}."
      ;;
    2)
      SERVA_RESULTS+=("${m}|skipped")
      state::module "$m" skipped
      log::warn "${m}: skipped."
      ;;
    *)
      SERVA_RESULTS+=("${m}|FAILED (see ${SERVA_LOG})")
      state::module "$m" failed
      log::error "${m}: failed. Details in ${SERVA_LOG}."
      return 1
      ;;
  esac
}

# module::run_many NAME...: canonical order; after a failure, ask whether to
# go on (stop at once with --yes).
module::run_many() {
  local m
  for m in "${SERVA_BASE_MODULES[@]}"; do
    [[ " $* " == *" $m "* ]] || continue
    module::run "$m" && continue
    ui::is_interactive && ui::yesno "Step failed" "The '${m}' step failed (details in ${SERVA_LOG}).

Continue with the next steps?" no || return 1
  done
}
