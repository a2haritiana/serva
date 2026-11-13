#!/usr/bin/env bash
# serva - dialogs (whiptail). With --yes (UI_MODE=none) nothing is asked and
# every function returns its default. Answers go to stdout and dialogs to
# stderr, so the functions also work inside $(...). Cancel returns 1.

UI_MODE=none
UI_BACKTITLE="serva ${SERVA_VERSION:-}"

ui::init() {
  [[ "$SERVA_ASSUME_YES" == 1 ]] && return 0
  [[ -t 0 ]] || core::die "No terminal: run serva in an SSH session, or use --yes with --config FILE."
  if ! command -v whiptail >/dev/null 2>&1; then
    core::is_dry_run && core::die "whiptail is missing: install it (apt install whiptail) or use --yes."
    os::apt_install whiptail || core::die "Could not install whiptail."
  fi
  UI_MODE=whiptail
}

ui::is_interactive() { [[ "$UI_MODE" != none ]]; }

# Dialog width (50 to 78 columns) and a height that fits TEXT (+ EXTRA lines).
ui::_w() {
  local c=$(($(tput cols 2>/dev/null || echo 80) - 4))
  ((c > 78)) && c=78
  ((c < 50)) && c=50
  echo "$c"
}

ui::_h() {
  local max=$(($(tput lines 2>/dev/null || echo 24) - 2)) n
  n=$(($(printf '%s\n' "$1" | fold -s -w "$(($(ui::_w) - 4))" | wc -l) + 7 + ${2:-0}))
  echo $((n > max ? max : n))
}

# whiptail prints the answer on stderr: swap stdout and stderr to capture it.
ui::_wt() { whiptail --backtitle "$UI_BACKTITLE" "$@" 3>&1 1>&2 2>&3; }

ui::_print() { printf '\n%s\n%s\n' "${C_BOLD}$1${C_RESET}" "$2" >&2; }

ui::msg() { # TITLE TEXT
  [[ "$UI_MODE" == none ]] && { ui::_print "$1" "$2"; return 0; }
  whiptail --backtitle "$UI_BACKTITLE" --title "$1" --scrolltext --msgbox "$2" "$(ui::_h "$2")" "$(ui::_w)" >&2 || true
}

ui::yesno() { # TITLE TEXT [yes|no]: 0 = yes
  local default="${3:-yes}" opts=()
  [[ "$UI_MODE" == none ]] && { [[ "$default" == yes ]]; return; }
  [[ "$default" == no ]] && opts=(--defaultno)
  whiptail --backtitle "$UI_BACKTITLE" --title "$1" "${opts[@]}" --yesno "$2" "$(ui::_h "$2")" "$(ui::_w)" >&2
}

ui::input() { # TITLE TEXT [DEFAULT]
  [[ "$UI_MODE" == none ]] && { printf '%s' "${3:-}"; return 0; }
  ui::_wt --title "$1" --inputbox "$2" "$(ui::_h "$2" 1)" "$(ui::_w)" "${3:-}"
}

ui::password() { # TITLE TEXT (no default: fails in --yes mode)
  [[ "$UI_MODE" == none ]] && return 1
  ui::_wt --title "$1" --passwordbox "$2" "$(ui::_h "$2" 1)" "$(ui::_w)"
}

ui::menu() { # TITLE TEXT DEFAULT TAG DESC [TAG DESC...]
  local title="$1" text="$2" default="$3"
  shift 3
  [[ "$UI_MODE" == none ]] && { printf '%s' "$default"; return 0; }
  ui::_wt --title "$title" --default-item "$default" \
    --menu "$text" "$(ui::_h "$text" $(($# / 2)))" "$(ui::_w)" $(($# / 2)) "$@"
}

ui::checklist() { # TITLE TEXT TAG DESC ON|OFF [...]: selected tags, one per line
  local title="$1" text="$2"$'\n\n''Space: select or unselect. Enter: confirm.'
  shift 2
  if [[ "$UI_MODE" == none ]]; then
    while (($# >= 3)); do
      [[ "${3^^}" == ON ]] && printf '%s\n' "$1"
      shift 3
    done
    return 0
  fi
  ui::_wt --title "$title" --separate-output \
    --checklist "$text" "$(ui::_h "$text" $(($# / 3)))" "$(ui::_w)" $(($# / 3)) "$@"
}

ui::textbox() { # TITLE FILE
  [[ "$UI_MODE" == none ]] && { ui::_print "$1" "$(cat "$2")"; return 0; }
  whiptail --backtitle "$UI_BACKTITLE" --title "$1" --scrolltext \
    --textbox "$2" "$(($(tput lines 2>/dev/null || echo 24) - 2))" "$(ui::_w)" >&2 || true
}
