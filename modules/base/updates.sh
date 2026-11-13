#!/usr/bin/env bash
# serva - updates module: upgrade now, then security updates every day.

UPD_PERIODIC=/etc/apt/apt.conf.d/20auto-upgrades
# 52 sorts after the distribution's 50unattended-upgrades, so it wins.
UPD_POLICY=/etc/apt/apt.conf.d/52serva-unattended-upgrades

updates::describe() { printf 'Install updates now and automatically'; }

updates::render_periodic() {
  cat <<'EOT'
// Managed by serva.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOT
}

# updates::render_policy REBOOT(yes|no) TIME
updates::render_policy() {
  printf '// Managed by serva.\n'
  if [[ "${1:-no}" == yes ]]; then
    printf 'Unattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-Time "%s";\n' "${2:-04:00}"
  else
    printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
  fi
  printf 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";\n'
}

updates::check() {
  os::is_installed unattended-upgrades && [[ -f "$UPD_POLICY" ]] &&
    grep -Eqs '^[[:space:]]*APT::Periodic::Unattended-Upgrade[[:space:]]+"1"' "$UPD_PERIODIC"
}

updates::apply() {
  local upgrade=yes reboot=no time="${SERVA_AUTO_REBOOT_TIME:-04:00}"
  local reboot_note="Automatic reboot is off: reboot yourself after kernel updates."
  # Ask everything first, so a bad answer does not come after the long upgrade.
  if [[ -n "${SERVA_UPGRADE_NOW:-}" ]]; then
    core::is_yes "$SERVA_UPGRADE_NOW" || upgrade=no
  else
    ui::yesno "Updates" "Install all available updates now?" yes || upgrade=no
  fi
  if [[ -n "${SERVA_AUTO_REBOOT:-}" ]]; then
    core::is_yes "$SERVA_AUTO_REBOOT" && reboot=yes
  elif ui::yesno "Automatic reboot" "Reboot the server automatically when an update (a new kernel) needs it?" no; then
    reboot=yes
  fi
  if [[ "$reboot" == yes ]]; then
    [[ -n "${SERVA_AUTO_REBOOT_TIME:-}" ]] || time="$(ui::input "Reboot time" "At what time (HH:MM, server time) may it reboot?" 04:00)" || return 2
    # The value ends up in an apt config file.
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || {
      log::error "The reboot time must be HH:MM (00:00 to 23:59), got '${time}'."
      return 1
    }
    reboot_note="Automatic reboot enabled at ${time} (server time) when an update needs it."
  fi

  if [[ "$upgrade" == yes ]]; then
    log::info "Installing updates. This can take a few minutes..."
    os::apt_full_upgrade || return 1
  fi
  os::apt_install unattended-upgrades || return 1
  updates::render_periodic | core::write_file "$UPD_PERIODIC" 644 root:root || return 1
  updates::render_policy "$reboot" "$time" | core::write_file "$UPD_POLICY" 644 root:root || return 1
  core::run systemctl enable --now unattended-upgrades || return 1

  report::note "Security updates install automatically every day. ${reboot_note}"
  if [[ -e /var/run/reboot-required ]]; then report::note "A reboot is needed to finish the updates."; fi
}
