#!/usr/bin/env bash
# serva installer: downloads serva from GitHub and installs it under /opt/serva.
# https://github.com/a2haritiana/serva - MIT License
#
#   curl -fsSL https://raw.githubusercontent.com/a2haritiana/serva/main/install.sh | sudo bash
#   ... | sudo bash -s -- --version v0.1.0
#   ... | sudo bash -s -- --ref main     (unreleased code, no checksum: testing only)
#
# A release is verified against the SHA256SUMS file published with it. If the
# check fails, nothing is installed.
set -Eeuo pipefail

# Fixed on purpose. These are plain variables only so that the tests can point
# them to temporary directories after sourcing this file.
REPO="a2haritiana/serva"
OPT="/opt/serva"
BIN="/usr/local/bin/serva"
OS_RELEASE="/etc/os-release"
TMP=""

say() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOT
serva installer: installs serva under ${OPT}.

Usage: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash -s -- [OPTIONS]

Options:
  --version vX.Y.Z   Install this release (default: the latest release)
  --ref NAME         Install a branch or tag from its source archive. No checksum
                     can be verified: for testing only.
  -h, --help         Show this help
EOT
}

# A release tag such as v0.1.0 or v1.2.3-rc.1.
valid_tag() { [[ "${1:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; }

# A branch or tag name that is safe in a URL and in a directory name.
valid_ref() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != *..* && "$1" != */ ]]; }

check_root() { [[ "$EUID" -eq 0 ]] || die "Run as root (curl ... | sudo bash)."; }

# The ID= line of os-release is parsed, never sourced.
check_os() {
  local id
  id="$(sed -n 's/^ID=//p' "$OS_RELEASE" 2>/dev/null | head -n 1 | tr -d "\"'")" || true
  [[ "$id" == ubuntu || "$id" == debian ]] || die "Unsupported system '${id:-unknown}': serva needs Ubuntu or Debian."
}

# Downloads go over HTTPS only (redirects included).
fetch() { curl -fsSL --proto '=https' --tlsv1.2 "$@"; }

# Print the tag of the latest release (JSON read with sed, no jq).
latest_tag() {
  local tag
  tag="$(fetch "https://api.github.com/repos/${REPO}/releases/latest" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)" ||
    die "Cannot read the latest release of ${REPO} (none yet? Try --ref main)."
  valid_tag "$tag" || die "Unexpected release tag from GitHub: '${tag}'."
  printf '%s\n' "$tag"
}

# verify_checksum DIR FILE: DIR/FILE must match its single line in DIR/SHA256SUMS.
# The name is compared as a string, not a pattern: "serva-v1.tar.gz.bak" does
# not satisfy a check for "serva-v1.tar.gz".
verify_checksum() {
  local dir="$1" file="$2" line
  [[ -f "${dir}/SHA256SUMS" && -f "${dir}/${file}" ]] || { echo "SHA256SUMS or ${file} missing." >&2; return 1; }
  line="$(F="$file" awk '{ n = $2; sub(/^\*/, "", n); if (n == ENVIRON["F"]) print }' "${dir}/SHA256SUMS")"
  [[ -n "$line" && "$line" != *$'\n'* ]] || { echo "SHA256SUMS needs exactly one entry for ${file}." >&2; return 1; }
  (cd "$dir" && sha256sum -c --strict - <<<"$line" >&2)
}

# install_tree TARBALL NAME: extract aside, then move into place and point the links to it.
install_tree() {
  local dest="${OPT}/${2}" new="${TMP}/tree"
  mkdir "$new"
  tar -xzf "$1" -C "$new" --strip-components=1 --no-same-owner || die "Cannot extract the archive."
  [[ -f "${new}/serva" ]] || die "The archive does not look like serva."
  chmod 755 "$new" "${new}/serva"
  mkdir -p "$OPT"
  rm -rf -- "$dest"
  mv -- "$new" "$dest"
  ln -sfn "$dest" "${OPT}/current"
  ln -sfn "${OPT}/current/serva" "$BIN"
}

main() {
  local version="" ref="" name file base f
  while (($#)); do
    case "$1" in
      --version) version="${2:-}" ;;
      --ref) ref="${2:-}" ;;
      -h | --help) usage; return 0 ;;
      *) die "Unknown option: $1 (see --help)." ;;
    esac
    [[ -n "${2:-}" ]] || die "$1 needs a value."
    shift 2
  done
  [[ -z "$version" || -z "$ref" ]] || die "Use either --version or --ref, not both."
  [[ -z "$version" ]] || valid_tag "$version" || die "Invalid version '${version}' (expected vX.Y.Z)."
  [[ -z "$ref" ]] || valid_ref "$ref" || die "Invalid ref '${ref}'."
  check_root
  check_os
  TMP="$(mktemp -d)"
  trap 'rm -rf -- "$TMP"' EXIT

  if [[ -n "$ref" ]]; then
    say "WARNING: '${ref}' is installed from its source archive, with no checksum. Testing only."
    name="ref-${ref//\//-}"
    file="serva-ref.tar.gz"
    fetch -o "${TMP}/${file}" "https://github.com/${REPO}/archive/${ref}.tar.gz" || die "Cannot download '${ref}' (not a branch or tag?)."
  else
    [[ -n "$version" ]] || version="$(latest_tag)"
    name="$version"
    file="serva-${version}.tar.gz"
    base="https://github.com/${REPO}/releases/download/${version}"
    say "Downloading serva ${version}"
    for f in "$file" SHA256SUMS; do
      fetch -o "${TMP}/${f}" "${base}/${f}" || die "Cannot download ${base}/${f}"
    done
    verify_checksum "$TMP" "$file" || die "Verification failed: nothing was installed."
  fi

  install_tree "${TMP}/${file}" "$name"
  say "serva ${name} is installed in ${OPT}/${name}"
  cat >&2 <<'EOT'

Next steps:
  sudo serva setup --dry-run    preview what serva would change
  sudo serva setup              set up this server (asks before each step)
EOT
}

# The guard is a variable, not a BASH_SOURCE check: when piped into bash
# ("curl ... | sudo bash"), BASH_SOURCE is empty. The variable lets tests source
# this file without running it. Keep it the last line: a truncated download ends
# before it and runs nothing.
[[ "${SERVA_INSTALL_TEST:-0}" == 1 ]] || main "$@"
