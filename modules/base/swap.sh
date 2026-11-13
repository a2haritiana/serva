#!/usr/bin/env bash
# serva - swap module: a swap file, so memory peaks do not kill applications.

SWAP_FILE=/swapfile
SWAP_SYSCTL=/etc/sysctl.d/99-serva-swap.conf

swap::describe() { printf 'Create a swap file'; }

# swap::to_mb SIZE: 2G, 1536M (any case) -> megabytes. Fails on anything else, 0 included.
swap::to_mb() {
  local re='^([0-9]{1,6})([GgMm])$' n
  [[ "${1:-}" =~ $re ]] || return 1
  n=$((10#${BASH_REMATCH[1]}))
  ((n > 0)) || return 1
  [[ "${BASH_REMATCH[2]}" == [Gg] ]] && n=$((n * 1024))
  printf '%s' "$n"
}

# swap::recommended MEM_MB: 2G up to 8 GB of RAM, 4G above.
swap::recommended() { printf '%sG' "$(($1 <= 8192 ? 2 : 4))"; }

swap::check() { [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; }

swap::apply() {
  local size="${SERVA_SWAP_SIZE:-}" mb free
  if [[ -z "$size" ]]; then
    size="$(ui::input "Swap file" "Swap keeps the server alive during memory peaks. Size (for example 2G or 512M), or 0 for none:" \
      "$(swap::recommended "$(os::mem_mb)")")" || return 2
  fi
  [[ "${size,,}" =~ ^(0|none)$ ]] && return 2
  mb="$(swap::to_mb "$size")" || {
    log::error "Invalid swap size '${size}': use a number with G or M, for example 2G or 512M, or 0 for none."
    return 1
  }

  # check found no active swap, so an existing file is not ours: never overwrite it.
  [[ ! -e "$SWAP_FILE" ]] || {
    log::error "${SWAP_FILE} already exists but is not active swap. Remove or rename it, then run this step again."
    return 1
  }
  free="$(os::disk_free_mb /)"
  ((free >= mb + 1024)) || {
    log::error "Not enough disk space: swap ${mb} MB + 1024 MB spare needed, ${free:-unknown} MB free."
    return 1
  }

  # Some file systems cannot swap on a fallocate'd file: fall back to real zeros.
  core::run fallocate -l "${mb}M" "$SWAP_FILE" ||
    core::run dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$mb" status=none || return 1
  core::run chmod 600 "$SWAP_FILE" || return 1
  core::run mkswap "$SWAP_FILE" || return 1
  core::run swapon "$SWAP_FILE" || return 1
  core::ensure_line /etc/fstab "${SWAP_FILE} none swap sw 0 0" || return 1

  core::write_file "$SWAP_SYSCTL" 644 root:root <<'EOT' || return 1
# Managed by serva: use swap only when memory is nearly full.
vm.swappiness = 10
EOT
  core::run sysctl -q -p "$SWAP_SYSCTL" || log::warn "Could not apply vm.swappiness now; it applies at next boot."

  report::note "Swap file ${SWAP_FILE} (${mb} MB) created, enabled at boot, swappiness 10."
}
