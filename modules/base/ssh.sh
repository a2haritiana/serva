#!/usr/bin/env bash
# serva module: harden SSH (keys only, no root login) with automatic rollback.
#
# A drop-in file: sshd_config itself is never edited and the port never changed.
# A systemd timer, armed BEFORE the reload and living outside this process,
# restores the previous configuration unless the owner confirms a key login
# from a second terminal.

# sshd keeps the FIRST value it reads for a keyword, and it reads
# sshd_config.d/*.conf in alphabetical order. Cloud images ship
# 50-cloud-init.conf with "PasswordAuthentication yes": a file named 00-...
# is read before it and wins.
SSH_DROPIN=/etc/ssh/sshd_config.d/00-serva.conf
SSH_MAIN_CONFIG=/etc/ssh/sshd_config
SSH_UNIT=serva-ssh-rollback
SSH_PREV="${SERVA_STATE_DIR}/ssh-dropin.prev"
SSH_SCRIPT="${SERVA_STATE_DIR}/ssh-rollback.sh"
SSH_GRACE=15 # seconds the timer waits after our own confirmation wait ends

ssh::describe() { printf 'Harden SSH (keys only, no root) with rollback'; }

# ssh::render USER: the drop-in file content.
ssh::render() {
  printf '%s\n' \
    '# Managed by serva (https://github.com/a2haritiana/serva).' \
    '# Remove this file and reload ssh to go back to the distribution defaults.' \
    'PermitRootLogin no' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitEmptyPasswords no' \
    'PubkeyAuthentication yes' \
    'AuthenticationMethods publickey' \
    "AllowUsers ${1:?ssh::render needs a user name}" \
    'MaxAuthTries 3' \
    'LoginGraceTime 30' \
    'ClientAliveInterval 300' \
    'ClientAliveCountMax 2' \
    'X11Forwarding no' \
    'AllowAgentForwarding no'
}

# ssh::_effective_ok USER: does the effective configuration show the hardening?
ssh::_effective_ok() {
  local eff line
  eff="$(os::sshd_effective "$1")" || return 1
  for line in 'permitrootlogin no' 'passwordauthentication no' 'kbdinteractiveauthentication no'; do
    grep -qxF "$line" <<<"$eff" || return 1
  done
}

# ssh::_has_include: does the main sshd_config read the drop-in directory?
# Keywords are case-insensitive and Include may list several paths.
ssh::_has_include() {
  local dir="${SSH_DROPIN%/*}" line path paths=()
  local re='^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]+(.*)$'
  [[ -r "$SSH_MAIN_CONFIG" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $re ]] || continue
    read -r -a paths <<<"${BASH_REMATCH[1]}" # no glob expansion
    for path in "${paths[@]}"; do
      [[ "$path" == "${dir}/*.conf" || "$path" == "${dir}/*" ]] && return 0
    done
  done <"$SSH_MAIN_CONFIG"
  return 1
}

# ssh::_timeout: print the confirmation timeout (seconds), or fail.
ssh::_timeout() {
  local t="${SERVA_SSH_CONFIRM_TIMEOUT:-120}"
  if ! [[ "$t" =~ ^[0-9]{2,3}$ ]] || ((10#$t < 30 || 10#$t > 900)); then
    log::error "SERVA_SSH_CONFIRM_TIMEOUT must be a whole number of seconds between 30 and 900 (got '${t}')."
    return 1
  fi
  printf '%s' "$((10#$t))"
}

# ssh::_fail MESSAGE: a failed precondition. An error, except in a dry run
# where an earlier step has not really happened: warn and carry on.
ssh::_fail() {
  if core::is_dry_run; then log::warn "Dry run: $1"; return 0; fi
  log::error "$1"
  return 1
}

ssh::check() {
  local name="${SERVA_USER:-$(state::value admin_user)}"
  [[ -n "$name" && -f "$SSH_DROPIN" ]] || return 1
  [[ "$(cat "$SSH_DROPIN")" == "$(ssh::render "$name")" ]] && ssh::_effective_ok "$name"
}

# --- Rollback machinery ---------------------------------------------------------

# A standalone /bin/sh script: put the previous drop-in back (or remove ours)
# and reload ssh. It runs from the timer, so it cannot depend on this process.
ssh::_write_rollback_script() {
  core::write_file "$SSH_SCRIPT" 700 <<EOF
#!/bin/sh
# Written by serva: undo the SSH hardening when it was not confirmed in time.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
if [ -f "$SSH_PREV" ]; then cp -p "$SSH_PREV" "$SSH_DROPIN"; else rm -f "$SSH_DROPIN"; fi
mkdir -p /run/sshd
if sshd -t >>"$SERVA_LOG" 2>&1 && { systemctl reload ssh.service || systemctl restart ssh.service; }; then
  msg='previous SSH configuration restored'
else
  msg='previous drop-in restored but the ssh reload FAILED: check sshd -t'
fi
printf '%s [ROLLBACK] no confirmation received: %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$msg" >>"$SERVA_LOG"
EOF
}

# Stop the rollback timer (and clear a failed unit of the same name).
ssh::_disarm() {
  systemctl stop "${SSH_UNIT}.timer" "${SSH_UNIT}.service" >/dev/null 2>&1
  systemctl reset-failed "${SSH_UNIT}.timer" "${SSH_UNIT}.service" >/dev/null 2>&1
  return 0
}

# ssh::_arm SECONDS: start the rollback timer, outside this process.
ssh::_arm() {
  ssh::_disarm # a stale timer would block the new one
  core::run systemd-run --quiet --unit="$SSH_UNIT" --on-active="${1}s" \
    --timer-property=AccuracySec=1s /bin/sh "$SSH_SCRIPT" || return 1
  systemctl is-active --quiet "${SSH_UNIT}.timer" || {
    log::error "The rollback timer is not active; not changing SSH."
    return 1
  }
}

# ssh::_abort MESSAGE: log the failure, put the previous drop-in back, stop the
# timer. Always returns 1.
ssh::_abort() {
  log::error "$1"
  ssh::_disarm
  if [[ -f "$SSH_PREV" ]]; then core::run install -m 644 -o root -g root "$SSH_PREV" "$SSH_DROPIN"; else core::run rm -f "$SSH_DROPIN"; fi ||
    log::error "Could not restore the previous SSH configuration: check ${SSH_DROPIN} by hand."
  os::reload_ssh || true
  rm -f "$SSH_SCRIPT" "$SSH_PREV"
  return 1
}

# ssh::_confirm NAME SECONDS: plain text on the terminal (a dialog would use up
# the countdown). Returns 0 only when the owner typed yes.
ssh::_confirm() {
  local name="$1" seconds="$2" ip port target answer=''
  ip="$(os::primary_ip)"
  read -r port < <(os::ssh_ports)
  target="${name}@${ip:-<server-ip>}"
  [[ "$port" == 22 ]] || target="-p ${port} ${target}"
  printf '\n%s\n%s\n\n  1. Open a NEW terminal on your computer.\n  2. Run:  ssh %s\n  3. When you are logged in, come back here and type "yes".\n\n' \
    "${C_BOLD}SSH now refuses root and passwords.${C_RESET}" "${C_BOLD}KEEP THIS SESSION OPEN.${C_RESET}" "$target" >&2
  printf 'No answer within %s seconds: the previous configuration comes back automatically.\n\n' "$seconds" >&2
  trap 'printf "\nInterrupted. The rollback timer will restore the previous SSH configuration in about %s seconds.\n" "$((seconds + SSH_GRACE))" >&2; exit 130' INT
  read -r -t "$seconds" -p 'Type "yes" once the new login works: ' answer </dev/tty || {
    answer=''
    printf '\n' >&2
  }
  trap - INT
  [[ "${answer,,}" =~ ^[[:space:]]*(y|yes)[[:space:]]*$ ]]
}

ssh::apply() {
  local name="${SERVA_USER:-$(state::value admin_user)}" timeout
  timeout="$(ssh::_timeout)" || return 1

  # Preconditions: never disable passwords without a working key.
  user::has_valid_key "$name" || ssh::_fail "The admin user '${name:-?}' does not exist or has no usable public key: with passwords disabled you would be locked out. Run the 'user' step first (serva run user)." || return 1
  ssh::_has_include || ssh::_fail "${SSH_MAIN_CONFIG} has no 'Include ${SSH_DROPIN%/*}/*.conf' line, so a drop-in would be ignored. serva does not edit that file; add the line yourself." || return 1
  os::has_systemd || ssh::_fail "systemd is required for the automatic rollback timer." || return 1

  if core::is_dry_run; then
    ssh::render "${name:-ADMIN_USER}" | core::write_file "$SSH_DROPIN" || return 1
    log::info "Dry run: serva would then run 'sshd -t', arm a rollback timer (${timeout}s + ${SSH_GRACE}s), reload ssh and ask you to test a login from a second terminal. Without your confirmation the previous configuration is restored automatically."
    return 0
  fi

  # Keep the previous drop-in for the rollback, then write ours.
  if [[ -f "$SSH_DROPIN" ]]; then cp -p "$SSH_DROPIN" "$SSH_PREV"; else rm -f "$SSH_PREV"; fi || return 1
  ssh::render "$name" | core::write_file "$SSH_DROPIN" || { ssh::_abort "Could not write ${SSH_DROPIN}."; return 1; }
  os::_sshd_runtime_dir
  sshd -t >>"$SERVA_LOG" 2>&1 || { ssh::_abort "sshd rejects the new configuration (details in ${SERVA_LOG}). Previous one restored."; return 1; }
  # sshd keeps the first value it reads: another file read earlier would win.
  ssh::_effective_ok "$name" || { ssh::_abort "The effective SSH configuration does not show the hardening: another file in ${SSH_DROPIN%/*} overrides serva. Previous one restored."; return 1; }

  # Arm the rollback before touching the running service, never without it.
  { ssh::_write_rollback_script && ssh::_arm "$((timeout + SSH_GRACE))"; } || { ssh::_abort "Could not arm the rollback."; return 1; }
  os::reload_ssh || { ssh::_abort "Could not reload ssh. Previous configuration restored."; return 1; }

  if ui::is_interactive; then
    ssh::_confirm "$name" "$timeout"
  else
    log::warn "Unattended mode cannot prove that a login works. If you are locked out, use your provider's web console."
    systemctl is-active --quiet ssh.service || systemctl is-active --quiet ssh.socket
  fi || { ssh::_abort "Not confirmed: previous SSH configuration restored. Test the key login (ssh ${name}@<server-ip>), then run this step again."; return 1; }

  ssh::_disarm
  rm -f "$SSH_SCRIPT" "$SSH_PREV"
  log::ok "SSH now accepts keys only; root and passwords are refused."
  report::note "SSH: key-only login for ${name}; root login and passwords refused."
}
