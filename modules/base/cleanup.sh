#!/usr/bin/env bash
# serva - cleanup module: close the access paths that bypass the admin user (default
# cloud accounts, root SSH keys, root password). Needs an interactive "yes" or a config
# value: with --yes the defaults keep things as they are.

CLEANUP_DEFAULT_USERS=(ubuntu debian admin cloud-user ec2-user azureuser)
CLEANUP_ROOT_KEYS_FILE=/root/.ssh/authorized_keys

cleanup::describe() { printf 'Lock default accounts, root keys and password'; }

cleanup::admin_user() { printf '%s' "${SERVA_USER:-$(state::value admin_user)}"; }

# cleanup::expire_is_past FIELD: the "account expires" field of /etc/shadow
# (days since 1970, empty or -1 = never) is today or earlier. An expired
# account cannot log in at all, not even with an SSH key.
cleanup::expire_is_past() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (($1 <= $(date +%s) / 86400)); }

# The default accounts that still work.
cleanup::default_users_active() {
  local admin u
  admin="$(cleanup::admin_user)"
  for u in "${CLEANUP_DEFAULT_USERS[@]}"; do
    [[ "$u" == "$admin" ]] && continue
    id "$u" &>/dev/null || continue
    cleanup::expire_is_past "$(getent shadow "$u" | cut -d: -f8)" || printf '%s\n' "$u"
  done
}

# The valid public keys in root's authorized_keys.
cleanup::root_keys() {
  local line
  [[ -r "$CLEANUP_ROOT_KEYS_FILE" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    user::normalize_key "$line" || true
  done <"$CLEANUP_ROOT_KEYS_FILE"
}

cleanup::root_password_locked() { [[ "$(os::password_status root)" =~ ^(L|NP)$ ]]; }

cleanup::check() {
  [[ -z "$(cleanup::default_users_active)" && -z "$(cleanup::root_keys)" ]] && cleanup::root_password_locked
}

# cleanup::guard OK MESSAGE: 0 when the action may go on. An unmet precondition only
# warns in dry-run (earlier steps have not really run), so the plan is still shown.
cleanup::guard() {
  [[ "$1" == yes ]] && return 0
  log::warn "$2"
  core::is_dry_run
}

cleanup::users() {
  local admin="$1" ready="$2" mode="${SERVA_CLEANUP_USERS:-}" users u
  mapfile -t users < <(cleanup::default_users_active)
  ((${#users[@]})) || return 0
  [[ "$mode" =~ ^(lock|keep)?$ ]] || {
    log::error "SERVA_CLEANUP_USERS must be lock or keep."
    return 1
  }
  [[ "$mode" == keep ]] && return 0
  [[ -n "$mode" ]] || ui::is_interactive || return 0
  # Locking the other way in would be a lock-out: the admin user must work first.
  cleanup::guard "$ready" "The admin user '${admin:-?}' does not exist or has no SSH key yet: default accounts are not locked." || return 0

  for u in "${users[@]}"; do
    [[ "$mode" == lock ]] || ui::yesno "Default account: ${u}" "The account '${u}' came with this server and still works: anyone who finds its key or password gets in without going through '${admin:-your admin user}'.

Lock it? Nobody can log in any more; its files stay." yes || continue
    core::run usermod --lock --expiredate 1 --shell /usr/sbin/nologin "$u" || return 1
    report::note "Account '${u}' locked. Undo: usermod --unlock --expiredate '' --shell /bin/bash ${u}"
  done
}

cleanup::root_keys_step() {
  local admin="$1" ready="$2" mode="${SERVA_CLEANUP_ROOT_KEYS:-}" keys fp eff ok=no
  keys="$(cleanup::root_keys)"
  [[ -n "$keys" ]] || return 0
  [[ "$mode" =~ ^(remove|keep)?$ ]] || {
    log::error "SERVA_CLEANUP_ROOT_KEYS must be remove or keep."
    return 1
  }
  [[ "$mode" == keep ]] && return 0
  [[ -n "$mode" ]] || ui::is_interactive || return 0

  # Capture first: "cmd | grep -q" can fail under pipefail.
  eff="$(os::sshd_effective || true)"
  [[ "$ready" == yes ]] && grep -qix 'permitrootlogin no' <<<"$eff" && ok=yes
  cleanup::guard "$ok" "Root SSH keys stay until '${admin:-the admin user}' has an SSH key and root SSH login is refused." || return 0

  fp="$(ssh-keygen -lf "$CLEANUP_ROOT_KEYS_FILE" 2>/dev/null)" || fp="$keys"
  [[ "$mode" == remove ]] || ui::yesno "Keys of root" "These SSH keys can still be used to log in as root (${CLEANUP_ROOT_KEYS_FILE}):

${fp}

Root SSH login is refused, so they are not needed. Remove them? (A backup is kept.)" yes || return 0

  # An empty file rather than no file: sshd keeps the same path.
  core::write_file "$CLEANUP_ROOT_KEYS_FILE" 600 root:root </dev/null || return 1
  report::note "Removed the SSH keys of root: ${fp//$'\n'/; }"
}

cleanup::root_password_step() {
  local admin="$1" mode="${SERVA_LOCK_ROOT:-}" ok=no
  cleanup::root_password_locked && return 0
  [[ -z "$mode" ]] || core::is_yes "$mode" || return 0
  [[ -n "$mode" ]] || ui::is_interactive || return 0
  [[ "$(os::password_status "$admin")" == P ]] && ok=yes
  cleanup::guard "$ok" "The root password stays until '${admin:-the admin user}' has a usable password: the provider's web console would become unusable." || return 0

  [[ -n "$mode" ]] || ui::yesno "Root password" "Lock the password of root?

The provider's web console (rescue/VNC) will then need '${admin:-the admin user}' and its password instead of root. You can still become root with sudo." yes || return 0
  core::run passwd -l root || return 1
  report::note "Root password locked: use '${admin:-the admin user}' (then sudo) in the provider's web console. Undo: sudo passwd -u root"
}

cleanup::apply() {
  local admin ready=no
  admin="$(cleanup::admin_user)"
  if [[ -n "$admin" ]] && id "$admin" &>/dev/null && user::has_valid_key "$admin"; then ready=yes; fi
  cleanup::users "$admin" "$ready" || return 1
  cleanup::root_keys_step "$admin" "$ready" || return 1
  cleanup::root_password_step "$admin"
}
