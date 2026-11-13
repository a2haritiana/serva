#!/usr/bin/env bats
# Tests for install.sh: validation, checksum verification, and a full install
# run with a stubbed curl (the fixed paths are pointed to temp dirs).

setup() {
  export SERVA_INSTALL_TEST=1
  INSTALL="${BATS_TEST_DIRNAME}/../install.sh"
  # shellcheck source=../install.sh
  source "$INSTALL"
  DIR="${BATS_TEST_TMPDIR}/dl"
  mkdir -p "$DIR"
  printf 'serva release content\n' >"${DIR}/serva-v0.1.0.tar.gz"
  (cd "$DIR" && sha256sum serva-v0.1.0.tar.gz >SHA256SUMS)
}

# --- verify_checksum -------------------------------------------------------------

@test "verify_checksum: a good file passes" {
  run verify_checksum "$DIR" serva-v0.1.0.tar.gz
  [ "$status" -eq 0 ]
}

@test "verify_checksum: a binary-mode (*name) entry passes" {
  (cd "$DIR" && sha256sum -b serva-v0.1.0.tar.gz >SHA256SUMS)
  run verify_checksum "$DIR" serva-v0.1.0.tar.gz
  [ "$status" -eq 0 ]
}

@test "verify_checksum: a tampered file fails" {
  printf 'tampered\n' >>"${DIR}/serva-v0.1.0.tar.gz"
  run verify_checksum "$DIR" serva-v0.1.0.tar.gz
  [ "$status" -ne 0 ]
}

@test "verify_checksum: a file missing from SHA256SUMS fails" {
  printf 'other\n' >"${DIR}/serva-v0.2.0.tar.gz"
  run verify_checksum "$DIR" serva-v0.2.0.tar.gz
  [ "$status" -ne 0 ]
}

@test "verify_checksum: a missing SHA256SUMS fails" {
  rm "${DIR}/SHA256SUMS"
  run verify_checksum "$DIR" serva-v0.1.0.tar.gz
  [ "$status" -ne 0 ]
}

@test "verify_checksum: a missing file fails" {
  rm "${DIR}/serva-v0.1.0.tar.gz"
  run verify_checksum "$DIR" serva-v0.1.0.tar.gz
  [ "$status" -ne 0 ]
}

@test "verify_checksum: a similarly named entry does not satisfy the check" {
  # Right hash, but listed as serva-v0.1.0.tar.gz.bak: no entry for the real name.
  (cd "$DIR" && sha256sum serva-v0.1.0.tar.gz | sed 's/tar.gz$/tar.gz.bak/' >SHA256SUMS)
  grep -q '\.bak$' "${DIR}/SHA256SUMS"
  run verify_checksum "$DIR" serva-v0.1.0.tar.gz
  [ "$status" -ne 0 ]
}

@test "verify_checksum: a prefixed name does not satisfy the check either" {
  (cd "$DIR" && sha256sum serva-v0.1.0.tar.gz | sed 's/serva-v0.1.0/old-serva-v0.1.0/' >SHA256SUMS)
  run verify_checksum "$DIR" serva-v0.1.0.tar.gz
  [ "$status" -ne 0 ]
}

@test "verify_checksum: a lookalike name (dot as wildcard) is not matched" {
  printf 'x\n' >"${DIR}/serva-v0.1.0.tar.gz.bak"
  (cd "$DIR" && sha256sum serva-v0.1.0.tar.gz.bak >SHA256SUMS)
  printf 'y\n' >"${DIR}/serva-v0x1.0.tar.gz"
  run verify_checksum "$DIR" serva-v0x1.0.tar.gz
  [ "$status" -ne 0 ]
}

@test "verify_checksum: the exact entry with a wrong hash fails" {
  printf '%s  serva-v0.1.0.tar.gz\n' "$(printf '0%.0s' {1..64})" >"${DIR}/SHA256SUMS"
  run verify_checksum "$DIR" serva-v0.1.0.tar.gz
  [ "$status" -ne 0 ]
}

@test "verify_checksum: two entries for the same file fail" {
  cat "${DIR}/SHA256SUMS" "${DIR}/SHA256SUMS" >"${DIR}/both"
  mv "${DIR}/both" "${DIR}/SHA256SUMS"
  run verify_checksum "$DIR" serva-v0.1.0.tar.gz
  [ "$status" -ne 0 ]
}

# --- valid_tag, valid_ref, check_os ----------------------------------------------

@test "valid_tag: accepts release tags" {
  run valid_tag v0.1.0
  [ "$status" -eq 0 ]
  run valid_tag v1.2.3-rc.1
  [ "$status" -eq 0 ]
  run valid_tag v10.20.30
  [ "$status" -eq 0 ]
}

@test "valid_tag: rejects anything else" {
  local bad
  for bad in 0.1.0 v1.2 v1 "" "v1.2.3; rm -rf /" 'v1.2.3$(id)' "v1.2.3/../x" "v1.2.3 " "xv1.2.3" "v1.2.3-"; do
    run valid_tag "$bad"
    [ "$status" -ne 0 ] || {
      echo "accepted: '$bad'"
      return 1
    }
  done
}

@test "valid_ref: accepts branch and tag names" {
  local ok
  for ok in main v0.1.0 feature/foo-1.2 release_2; do
    run valid_ref "$ok"
    [ "$status" -eq 0 ] || {
      echo "rejected: '$ok'"
      return 1
    }
  done
}

@test "valid_ref: rejects names unsafe in a URL or a path" {
  local bad
  for bad in "" "-x" ".x" "/x" "../x" "a..b" "a/../b" "a/" "a b" 'a;b' 'a$(id)' 'a`id`' "a?b" "a#b" "a%2e" "a|b" "a\\b"; do
    run valid_ref "$bad"
    [ "$status" -ne 0 ] || {
      echo "accepted: '$bad'"
      return 1
    }
  done
}

@test "check_os: accepts ubuntu and debian, parsing os-release without sourcing it" {
  OS_RELEASE="${BATS_TEST_TMPDIR}/os-release"
  printf 'NAME="Debian"\nID=debian\nPRETTY_NAME="x"\n' >"$OS_RELEASE"
  run check_os
  [ "$status" -eq 0 ]
  printf 'ID="ubuntu"\n$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" >"$OS_RELEASE"
  run check_os
  [ "$status" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
}

@test "check_os: refuses other systems and a missing os-release" {
  OS_RELEASE="${BATS_TEST_TMPDIR}/os-release"
  printf 'ID=fedora\n' >"$OS_RELEASE"
  run check_os
  [ "$status" -ne 0 ]
  rm "$OS_RELEASE"
  run check_os
  [ "$status" -ne 0 ]
}

# --- full run with a stubbed curl ------------------------------------------------

# A fake curl on PATH serves fixtures for the known URLs and fails (like curl -f)
# for everything else. It refuses any call without --proto =https.
setup_stub() {
  FIX="${BATS_TEST_TMPDIR}/fix"
  STUB="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$FIX" "$STUB" "${BATS_TEST_TMPDIR}/tmp"
  export TMPDIR="${BATS_TEST_TMPDIR}/tmp" STUB_FIX="$FIX" STUB_LOG="${BATS_TEST_TMPDIR}/curl.log"
  : >"$STUB_LOG"
  cat >"${STUB}/curl" <<'EOT'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
[[ " $* " == *" --proto =https "* ]] || exit 99
out="" url=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
case "$url" in
  https://api.github.com/repos/a2haritiana/serva/releases/latest) f="${STUB_FIX}/latest.json" ;;
  https://github.com/a2haritiana/serva/releases/download/*/*) f="${STUB_FIX}/${url##*/}" ;;
  https://github.com/a2haritiana/serva/archive/*.tar.gz) f="${STUB_FIX}/ref.tar.gz" ;;
  *) exit 22 ;;
esac
[[ -f "$f" ]] || exit 22
if [[ -n "$out" ]]; then cp "$f" "$out"; else cat "$f"; fi
EOT
  chmod +x "${STUB}/curl"
  export PATH="${STUB}:${PATH}"

  # A release tarball shaped like the real one: one top directory.
  local src="${BATS_TEST_TMPDIR}/src/serva-v0.1.0"
  mkdir -p "${src}/lib"
  printf '#!/usr/bin/env bash\n' >"${src}/serva"
  chmod 644 "${src}/serva"
  : >"${src}/lib/core.sh"
  tar -czf "${FIX}/serva-v0.1.0.tar.gz" -C "${BATS_TEST_TMPDIR}/src" serva-v0.1.0
  cp "${FIX}/serva-v0.1.0.tar.gz" "${FIX}/ref.tar.gz"
  (cd "$FIX" && sha256sum serva-v0.1.0.tar.gz >SHA256SUMS)
  printf '{\n  "url": "x",\n  "tag_name": "v0.1.0",\n  "name": "v0.1.0"\n}\n' >"${FIX}/latest.json"

  TEST_OPT="${BATS_TEST_TMPDIR}/opt"
  TEST_BIN="${BATS_TEST_TMPDIR}/bin/serva"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
}

# run_install ARGS...: run main in a fresh bash with the fixed paths overridden.
run_install() {
  run bash -c '
    source "$1"; shift
    OPT="$TEST_OPT" BIN="$TEST_BIN" OS_RELEASE="$TEST_OS"
    check_root() { :; }
    main "$@"' _ "$INSTALL" "$@"
}

@test "install: the latest release is downloaded, verified and installed" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=ubuntu\n' >"$TEST_OS"
  run_install
  [ "$status" -eq 0 ]
  [ -x "${TEST_OPT}/v0.1.0/serva" ]
  [ -f "${TEST_OPT}/v0.1.0/lib/core.sh" ]
  [ "$(readlink "${TEST_OPT}/current")" = "${TEST_OPT}/v0.1.0" ]
  [ "$(readlink "$TEST_BIN")" = "${TEST_OPT}/current/serva" ]
  [[ "$output" == *"sudo serva setup --dry-run"* ]]
  # The temp dir is removed.
  [ -z "$(ls -A "${BATS_TEST_TMPDIR}/tmp")" ]
}

@test "install: --version installs that release without asking the API" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=debian\n' >"$TEST_OS"
  rm "${FIX}/latest.json"
  run_install --version v0.1.0
  [ "$status" -eq 0 ]
  [ -x "${TEST_OPT}/v0.1.0/serva" ]
  ! grep -q api.github.com "$STUB_LOG"
}

@test "install: the same version again replaces the old files" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=ubuntu\n' >"$TEST_OS"
  run_install
  [ "$status" -eq 0 ]
  touch "${TEST_OPT}/v0.1.0/stale"
  run_install
  [ "$status" -eq 0 ]
  [ ! -e "${TEST_OPT}/v0.1.0/stale" ]
  [ -x "${TEST_OPT}/v0.1.0/serva" ]
  [ "$(ls -A "$TEST_OPT" | sort | tr '\n' ' ')" = "current v0.1.0 " ]
}

@test "install: a tampered tarball installs nothing" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=ubuntu\n' >"$TEST_OS"
  printf 'tampered' >>"${FIX}/serva-v0.1.0.tar.gz"
  run_install
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing was installed"* ]]
  [ ! -e "${TEST_OPT}/v0.1.0" ] && [ ! -e "${TEST_OPT}/current" ] && [ ! -e "$TEST_BIN" ]
  [ -z "$(ls -A "${BATS_TEST_TMPDIR}/tmp")" ]
}

@test "install: a missing SHA256SUMS installs nothing" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=ubuntu\n' >"$TEST_OS"
  rm "${FIX}/SHA256SUMS"
  run_install
  [ "$status" -ne 0 ]
  [ ! -e "${TEST_OPT}/v0.1.0" ] && [ ! -e "$TEST_BIN" ]
}

@test "install: no release yet suggests --ref main" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=ubuntu\n' >"$TEST_OS"
  rm "${FIX}/latest.json"
  run_install
  [ "$status" -ne 0 ]
  [[ "$output" == *"--ref main"* ]]
  [ ! -e "$TEST_BIN" ]
}

@test "install: --ref installs the source archive under ref-NAME with a warning" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=ubuntu\n' >"$TEST_OS"
  run_install --ref feature/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"no checksum"* ]]
  [ -x "${TEST_OPT}/ref-feature-x/serva" ]
  [ "$(readlink "${TEST_OPT}/current")" = "${TEST_OPT}/ref-feature-x" ]
  grep -q 'archive/feature/x.tar.gz' "$STUB_LOG"
}

@test "install: an archive that is not serva installs nothing" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=ubuntu\n' >"$TEST_OS"
  mkdir -p "${BATS_TEST_TMPDIR}/other/x"
  : >"${BATS_TEST_TMPDIR}/other/x/readme"
  tar -czf "${FIX}/ref.tar.gz" -C "${BATS_TEST_TMPDIR}/other" x
  run_install --ref main
  [ "$status" -ne 0 ]
  [ ! -e "${TEST_OPT}/ref-main" ] && [ ! -e "$TEST_BIN" ]
}

@test "install: an unsupported system installs nothing" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=fedora\n' >"$TEST_OS"
  run_install
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "install: bad arguments are refused before anything is downloaded" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=ubuntu\n' >"$TEST_OS"
  local bad
  for bad in "--version 1.2" "--version v1.2.3;id" "--ref ../x" "--ref a..b" "--ref -x" \
    "--version v0.1.0 --ref main" "--version" "--ref" "--ref=main" "--bogus"; do
    # shellcheck disable=SC2086 # word splitting of the list above is intended
    run_install $bad
    [ "$status" -ne 0 ] || {
      echo "accepted: $bad"
      return 1
    }
  done
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$TEST_OPT" ]
}

@test "install: --help prints the usage and exits 0 without installing" {
  setup_stub
  export TEST_OPT TEST_BIN TEST_OS="${BATS_TEST_TMPDIR}/os"
  printf 'ID=fedora\n' >"$TEST_OS"
  run_install --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--version"* && "$output" == *"--ref"* ]]
  [ ! -s "$STUB_LOG" ]
}
