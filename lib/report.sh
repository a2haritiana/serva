#!/usr/bin/env bash
# serva - end-of-session summary. Modules add lines with report::note; the
# runner records each step in SERVA_RESULTS ("name|result").

SERVA_RESULTS=()
SERVA_NOTES=()

report::note() { SERVA_NOTES+=("$*"); }

report::_render() {
  local entry ip host user
  ip="$(os::primary_ip)"
  host="$(hostname -s 2>/dev/null || echo vps)"
  user="${SERVA_USER:-$(state::value admin_user)}"
  printf 'serva %s - session %s%s\n' "$SERVA_VERSION" "$SERVA_SESSION" "$(core::is_dry_run && echo ' (dry run: nothing was changed)')"
  printf 'Server: %s (%s), %s\n\nSteps:\n' "$(os::hostname)" "${ip:-unknown IP}" "${OS_PRETTY:-unknown system}"
  for entry in "${SERVA_RESULTS[@]}"; do printf '  %-10s %s\n' "${entry%%|*}" "${entry#*|}"; done
  if ((${#SERVA_NOTES[@]})); then
    printf '\n%s\n' "$(core::is_dry_run && echo 'What would be done:' || echo 'Notes:')"
    for entry in "${SERVA_NOTES[@]}"; do printf '  - %s\n' "$entry"; done
  fi
  if [[ -n "$user" && -n "$ip" ]]; then
    printf '\nOn your computer, add this to ~/.ssh/config, then run "ssh %s":\n\n' "$host"
    printf '  Host %s\n    HostName %s\n    User %s\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n' "$host" "$ip" "$user"
  fi
  core::is_dry_run || printf '\nBackups: %s\nLog: %s\n' "$SERVA_BACKUP_DIR" "$SERVA_LOG"
}

# report::finish: show the summary and keep it in /var/log/serva/.
report::finish() {
  local file="${SERVA_REPORT_DIR}/report-${SERVA_SESSION}.txt"
  core::is_dry_run && file="$(mktemp)"
  (umask 077 && report::_render >"$file")
  ui::textbox "Summary" "$file"
  if core::is_dry_run; then rm -f "$file"; else log::info "Summary saved to ${file}"; fi
}
