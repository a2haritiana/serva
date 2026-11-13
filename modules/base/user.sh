#!/usr/bin/env bash
# serva module: admin user with sudo and your SSH key.
#
# SSH becomes key-only and root gets locked later, so this module must leave a
# normal user with sudo, a password for sudo and at least one REAL public key.
# A private key is never generated here and a placeholder is never installed:
# either would lock the owner out.

USER_NAME_RE='^[a-z_][a-z0-9_-]{0,31}$'
# shellcheck disable=SC2016 # a regex: the $ signs are literal
USER_HASH_RE='^\$(6|y|5)\$[^[:space:]:]+$'
USER_ROOT_KEYS=/root/.ssh/authorized_keys

user::describe() { printf 'Admin user with sudo and your SSH key'; }

# user::normalize_key LINE: print "TYPE BASE64[ COMMENT]" (authorized_keys
# options and CR removed); return 1 unless LINE holds a usable public key.
user::normalize_key() {
  local line="${1:-}" info type b64 comment
  local re='(^|[[:space:]])(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa)[[:space:]]+([A-Za-z0-9+/]+={0,3})([[:space:]]+(.*))?$'
  line="${line%$'\r'}"
  [[ "$line" != *"PRIVATE KEY"* && "$line" =~ $re ]] || return 1
  type="${BASH_REMATCH[2]}" b64="${BASH_REMATCH[4]}" comment="${BASH_REMATCH[6]:-}"
  comment="${comment%"${comment##*[![:space:]]}"}"
  # Let OpenSSH decide whether the key blob is real ("AAAA..." is not).
  info="$(ssh-keygen -l -f <(printf '%s %s\n' "$type" "$b64") 2>/dev/null)" || return 1
  [[ "$type" != ssh-rsa ]] || ((${info%% *} >= 2048)) || return 1
  printf '%s %s%s\n' "$type" "$b64" "${comment:+ ${comment}}"
}

# user::has_valid_key USER: true if USER's authorized_keys holds a usable key.
user::has_valid_key() {
  local home line
  home="$(os::user_home "${1:-}")"
  [[ -n "$home" && -r "${home}/.ssh/authorized_keys" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    user::normalize_key "$line" >/dev/null && return 0
  done <"${home}/.ssh/authorized_keys"
  return 1
}

user::valid_name() { [[ "${1:-}" =~ $USER_NAME_RE && "${1:-}" != root ]]; }

user::check() {
  local name="${SERVA_USER:-$(state::value admin_user)}"
  id -u -- "${name:-}" >/dev/null 2>&1 || return 1
  [[ " $(id -nG -- "$name") " == *" sudo "* ]] && user::has_valid_key "$name"
}

# user::_name: print the admin user name. Returns 2 if the user cancelled.
user::_name() {
  local name="${SERVA_USER:-}" hint="use lowercase letters, digits, '_' and '-' (max 32), not 'root'"
  if [[ -z "$name" ]] && ui::is_interactive; then
    while true; do
      name="$(ui::input "Admin user" "Name of the admin user you will log in as: ${hint}." "$(state::value admin_user)")" || {
        log::warn "No admin user chosen."
        return 2
      }
      user::valid_name "$name" && break
      ui::msg "Invalid name" "'${name}' is not a valid user name: ${hint}."
    done
  fi
  user::valid_name "$name" || { log::error "Missing or invalid SERVA_USER: ${hint}."; return 1; }
  printf '%s' "$name"
}

# user::_set_password NAME HASH: apply HASH, keep a usable password, or ask for
# one (interactive). Secrets never reach the log or a core::run command line.
user::_set_password() {
  local name="$1" hash="$2" pw1='' pw2='' min=12
  if [[ -n "$hash" ]]; then
    core::is_dry_run && { log::info "Dry run: would set the password hash of ${name}."; return 0; }
    usermod -p "$hash" "$name" >>"$SERVA_LOG" 2>&1 || { log::error "Could not set the password hash of ${name} (see ${SERVA_LOG})."; return 1; }
    log::ok "Password hash set for ${name}."
    return 0
  fi
  if [[ "$(os::password_status "$name")" == P ]]; then
    ui::is_interactive || { log::info "${name} already has a password: kept."; return 0; }
    ui::yesno "Password" "${name} already has a password.

Change it?" no || return 0
  fi
  while true; do
    pw1="$(ui::password "Password for ${name}" "Choose a password for ${name}: it is needed for sudo (SSH will accept keys only).
At least ${min} characters.")" || break
    ((${#pw1} >= min)) || { ui::msg "Password too short" "Use at least ${min} characters."; continue; }
    pw2="$(ui::password "Confirm the password" "Type the password again.")" || break
    [[ "$pw1" == "$pw2" ]] && break
    ui::msg "Passwords differ" "The two passwords are not the same. Try again."
  done
  [[ -n "$pw1" && "$pw1" == "$pw2" ]] || { log::error "Cancelled: ${name} needs a password to use sudo."; return 1; }
  core::is_dry_run && { log::info "Dry run: would set the password of ${name}."; return 0; }
  printf '%s:%s\n' "$name" "$pw1" | chpasswd >>"$SERVA_LOG" 2>&1 || { log::error "Could not set the password of ${name} (see ${SERVA_LOG})."; return 1; }
  log::ok "Password set for ${name}."
}

# A log line would be hidden behind the next dialog: interactive shows a dialog.
user::_warn() { if ui::is_interactive; then ui::msg "SSH key" "$1"; else log::warn "$1"; fi; }

# user::_keys_in TEXT LABEL [COMMENT]: print the usable keys of TEXT (COMMENT
# is added to those without one), report the other lines. 1 if none is usable.
user::_keys_in() {
  local line key n=0 ok=0 bad=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if key="$(user::normalize_key "$line")"; then
      ok=1
      [[ -z "${3:-}" || "$key" == *" "*" "* ]] || key+=" ${3}"
      printf '%s\n' "$key"
    elif [[ "$line" == *"PRIVATE KEY"* ]]; then
      bad+="line ${n}: this is a PRIVATE key. Never paste it anywhere: paste the public one (the .pub file)."$'\n'
    else
      bad+="line ${n}: not a usable public key (expected: ssh-ed25519 AAAAC3Nza... you@laptop; placeholders, ssh-dss and RSA under 2048 bits are refused)."$'\n'
    fi
  done <<<"$1"
  [[ -z "$bad" ]] || user::_warn "${2}: some lines were skipped.
${bad}"
  ((ok)) || { [[ -n "$bad" ]] || user::_warn "${2}: no key found."; return 1; }
}

# user::_github LOGIN: print the public keys of a GitHub account.
user::_github() {
  local gh="$1" text
  [[ "$gh" =~ ^[A-Za-z0-9-]{1,39}$ ]] || { user::_warn "'${gh}' is not a valid GitHub user name."; return 1; }
  command -v curl >/dev/null 2>&1 || os::apt_install curl || return 1
  # Reading a public URL changes nothing, so this also runs in a dry run.
  text="$(curl -fsSL --max-time 15 "https://github.com/${gh}.keys" 2>/dev/null)" ||
    { user::_warn "Could not download the keys of GitHub user ${gh} (wrong name, or no network?)."; return 1; }
  user::_keys_in "$text" "GitHub ${gh}" "github:${gh}"
}

user::_root_keys() {
  [[ -r "$USER_ROOT_KEYS" ]] || { user::_warn "No readable ${USER_ROOT_KEYS}."; return 1; }
  user::_keys_in "$(cat "$USER_ROOT_KEYS")" "root's authorized_keys"
}

# user::_ask_keys NAME HAS_KEY: print the keys chosen from the menu.
user::_ask_keys() {
  local name="$1" have="$2" keys='' got line gh choice default items
  ui::msg "SSH key" "serva needs the PUBLIC half of an SSH key made on YOUR computer, never on this server.
No key yet? On your computer, run:
  ssh-keygen -t ed25519 -a 100
  cat ~/.ssh/id_ed25519.pub
Paste only that last line (it starts with ssh-ed25519), never the file without .pub: that is your PRIVATE key."
  while true; do
    items=(paste "Paste a public key" github "Download the keys of a GitHub account")
    [[ ! -s "$USER_ROOT_KEYS" ]] || items+=(root "Copy the keys of root (set by your provider)")
    default='paste'
    if ((have)); then
      items+=(keep "Keep the keys already installed for ${name}")
      default=keep
    fi
    choice="$(ui::menu "SSH key" "Where is the public key you will log in with?" "$default" "${items[@]}")" ||
      { [[ -n "$keys" ]] && break; log::error "Cancelled: no SSH key was chosen."; return 1; }
    got=''
    case "$choice" in
      paste) line="$(ui::input "Public key" "Paste ONE public key (the single line of your .pub file):")" && got="$(user::_keys_in "$line" "Pasted text")" ;;
      github) gh="$(ui::input "GitHub" "GitHub user name whose public keys to download:")" && got="$(user::_github "$gh")" ;;
      root) got="$(user::_root_keys)" ;;
      *) break ;;
    esac
    [[ -z "$got" ]] && continue
    keys+="${got}"$'\n'
    ui::yesno "More keys" "Add keys from another source?" no || break
  done
  printf '%s' "$keys"
}

# user::_keys_config HAS_KEY: print the keys given by SERVA_PUBKEY*. A source
# that is set but gives no usable key is an error, never silently ignored.
user::_keys_config() {
  local keys=''
  [[ -z "${SERVA_PUBKEY:-}" ]] || keys+="$(user::_keys_in "$SERVA_PUBKEY" SERVA_PUBKEY)"$'\n' || return 1
  [[ -z "${SERVA_PUBKEY_GITHUB:-}" ]] || keys+="$(user::_github "$SERVA_PUBKEY_GITHUB")"$'\n' || return 1
  ! core::is_yes "${SERVA_PUBKEY_FROM_ROOT:-no}" || keys+="$(user::_root_keys)"$'\n' || return 1
  [[ -n "$keys" || "$1" == 1 ]] || {
    log::error "No SSH key to install. Set SERVA_PUBKEY (one public key line), SERVA_PUBKEY_GITHUB (a GitHub user name) or SERVA_PUBKEY_FROM_ROOT=yes."
    return 1
  }
  printf '%s' "$keys"
}

# user::_install_keys NAME KEYS: merge KEYS (one per line) into authorized_keys,
# skipping those already there (same type and key).
user::_install_keys() {
  local name="$1" keys="$2" home dir file group have='' add='' line key t b fps
  local -A seen=()
  home="$(os::user_home "$name")"
  dir="${home:-/home/${name}}/.ssh" # no such user yet in a dry run
  file="${dir}/authorized_keys"
  group="$(id -gn -- "$name" 2>/dev/null || printf '%s' "$name")"
  [[ ! -f "$file" ]] || have="$(cat "$file")" || return 1
  while IFS= read -r line; do
    key="$(user::normalize_key "$line")" || continue
    read -r t b _ <<<"$key"
    seen["$t $b"]=1
  done <<<"$have"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    read -r t b _ <<<"$key"
    [[ -z "${seen["$t $b"]:-}" ]] || continue
    seen["$t $b"]=1
    add+="${key}"$'\n'
  done <<<"$keys"
  [[ -n "$add" ]] || { log::ok "The SSH keys are already installed for ${name}."; return 0; }

  fps="$(ssh-keygen -l -f <(printf '%s' "$add"))"
  log::info "SSH keys to install for ${name}:"$'\n'"${fps}"
  if ui::is_interactive; then
    ui::yesno "Install these keys?" "These keys will be allowed to log in as ${name}:

${fps}

Are they yours?" || { log::error "Keys not confirmed: nothing installed."; return 1; }
  fi

  # ~/.ssh first: core::write_file would create missing parents owned by root.
  core::run install -d -m 700 -o "$name" -g "$group" "$dir" || return 1
  { [[ -z "$have" ]] || printf '%s\n' "$have"; printf '%s' "$add"; } |
    core::write_file "$file" 600 "${name}:${group}" || return 1
  core::is_dry_run || user::has_valid_key "$name" || {
    log::error "No usable key in ${file} after writing it. Not continuing."
    return 1
  }
  log::ok "SSH key(s) installed for ${name}."
}

user::apply() {
  local name uid keys='' have=0 hash="${SERVA_USER_PASSWORD_HASH:-}"
  name="$(user::_name)" || return
  if uid="$(id -u -- "$name" 2>/dev/null)" && ((uid < 1000 || uid >= 65534)); then
    log::error "'${name}' is a system account (UID ${uid}). Choose another name for the admin user."
    return 1
  fi
  if [[ -n "$hash" && ! "$hash" =~ $USER_HASH_RE ]]; then
    log::error "SERVA_USER_PASSWORD_HASH is not a password hash (expected \$6\$..., \$y\$... or \$5\$...). Generate one with: openssl passwd -6"
    return 1
  fi
  user::has_valid_key "$name" && have=1
  # Unattended: check password and keys before the first change, so a typo in
  # the config file cannot leave a half-made user behind.
  if ! ui::is_interactive; then
    [[ -n "$hash" || "$(os::password_status "$name")" == P ]] || {
      log::error "${name} has no password, so sudo would be unusable once SSH is key-only. Set SERVA_USER_PASSWORD_HASH in the config file (generate the value with: openssl passwd -6)."
      return 1
    }
    keys="$(user::_keys_config "$have")" || return 1
  fi

  os::apt_install sudo || return 1
  if ! id -u -- "$name" >/dev/null 2>&1; then
    log::info "Creating the user ${name}..."
    core::run useradd -m -s /bin/bash -U "$name" || return 1
  fi
  [[ " $(id -nG -- "$name" 2>/dev/null) " == *" sudo "* ]] || core::run usermod -aG sudo "$name" || return 1
  user::_set_password "$name" "$hash" || return 1
  if ui::is_interactive; then
    keys="$(user::_ask_keys "$name" "$have")" || return 1
  fi
  user::_install_keys "$name" "$keys" || return 1

  export SERVA_USER="$name" # read by the next modules
  state::put admin_user "$name" || return 1
  report::note "Admin user: ${name} (sudo, SSH key installed)"
}
