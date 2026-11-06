#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  export FZF_RELEASE_FIXTURE="$TEST_TEMP_DIR/release"
  export FZF_CHECKSUM_MODE=valid FZF_TRANSFER_RC=0
  export FZF_REDIRECT_MODE=none
  export FZF_TEST_OS=linux FZF_TEST_ARCH=x86_64
  mkdir -p "$HOME/.fzf/bin" "$HOME/.fzf/shell" "$FZF_RELEASE_FIXTURE/payload"
  cat >"$HOME/.fzf/install" <<'EOF'
#!/usr/bin/env bash
version=0.99.0
printf 'installer executed\n' >>"$HOME/installer-log"
curl -fL https://example.invalid/unverified-fzf.tar.gz >/dev/null
EOF
  cat >"$HOME/.fzf/bin/fzf" <<'EOF'
#!/usr/bin/env bash
printf '0.98.0 (existing)\n'
EOF
  printf '# completion fixture\n' >"$HOME/.fzf/shell/completion.zsh"
  printf '# key bindings fixture\n' >"$HOME/.fzf/shell/key-bindings.zsh"
  cat >"$FZF_RELEASE_FIXTURE/payload/fzf" <<'EOF'
#!/usr/bin/env bash
printf 'verified-binary:%s\n' "$*" >>"$HOME/binary-executed"
[[ "$*" == --version ]] || exit 94
printf '0.99.0 (verified)\n'
EOF
  chmod -- 755 "$HOME/.fzf/install" "$HOME/.fzf/bin/fzf" \
    "$FZF_RELEASE_FIXTURE/payload/fzf"
  export PATH="$HOME/.fzf/bin:$PATH"
  git -C "$HOME/.fzf" init --quiet
  git -C "$HOME/.fzf" add install shell
  git -C "$HOME/.fzf" -c user.name='ZDX Test' \
    -c user.email='zdx-test@example.invalid' commit --quiet -m 'test: fzf release metadata'
  git -C "$HOME/.fzf" remote add origin https://github.com/junegunn/fzf.git
  build_fzf_release
  printf 'original integration\n' >"$HOME/.fzf.zsh"
  cat >"$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
printf '%s\n' "$url" >>"$HOME/transfer-log"
[[ "$FZF_TRANSFER_RC" == 0 ]] || exit "$FZF_TRANSFER_RC"
if [[ "$url" == *checksums.txt ]]; then
  case "$FZF_REDIRECT_MODE" in
    foreign) printf 'ZDX-FZF-STATUS:302\nZDX-FZF-LOCATION:https://example.invalid/checksums\n' >&2; exit 0 ;;
    insecure) printf 'ZDX-FZF-STATUS:302\nZDX-FZF-LOCATION:http://github.com/checksums\n' >&2; exit 0 ;;
    allowed) printf 'ZDX-FZF-STATUS:302\nZDX-FZF-LOCATION:https://release-assets.githubusercontent.com/fzf-checksums\n' >&2; exit 0 ;;
    loop) printf 'ZDX-FZF-STATUS:302\nZDX-FZF-LOCATION:%s\n' "$url" >&2; exit 0 ;;
  esac
fi
case "$url" in
  https://release-assets.githubusercontent.com/fzf-checksums)
    cat "$FZF_RELEASE_FIXTURE/checksums" ;;
  https://github.com/junegunn/fzf/releases/download/v0.99.0/fzf_0.99.0_checksums.txt)
    case "$FZF_CHECKSUM_MODE" in
      absent) exit 22 ;;
      invalid) printf 'invalid checksum\n' ;;
      duplicate) cat "$FZF_RELEASE_FIXTURE/checksums" "$FZF_RELEASE_FIXTURE/checksums" ;;
      missing) printf '%064d  another-asset.tar.gz\n' 0 ;;
      mismatch) printf '%064d  fzf-0.99.0-linux_amd64.tar.gz\n' 0 ;;
      *) cat "$FZF_RELEASE_FIXTURE/checksums" ;;
    esac ;;
  https://github.com/junegunn/fzf/releases/download/v0.99.0/fzf-0.99.0-*.tar.gz)
    cat "$FZF_RELEASE_FIXTURE/archive.tar.gz" ;;
  *) exit 97 ;;
esac
printf 'ZDX-FZF-STATUS:200\nZDX-FZF-LOCATION:\n' >&2
EOF
  chmod -- 755 "$TEST_MOCK_BIN/curl"
  local denied
  for denied in wget go brew dpkg; do
    printf '#!/usr/bin/env bash\nexit 97\n' >"$TEST_MOCK_BIN/$denied"
    chmod -- 755 "$TEST_MOCK_BIN/$denied"
  done
}

teardown() { cleanup_sandbox; }

build_fzf_release() {
  tar -czf "$FZF_RELEASE_FIXTURE/archive.tar.gz" \
    -C "$FZF_RELEASE_FIXTURE/payload" fzf
  local digest
  digest=$(sha256_file "$FZF_RELEASE_FIXTURE/archive.tar.gz")
  printf '%s  fzf-0.99.0-linux_amd64.tar.gz\n' "$digest" >"$FZF_RELEASE_FIXTURE/checksums"
}

run_fzf_zsh() {
  run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 98
    _SYS_CAPABILITIES=(os "$FZF_TEST_OS" environment native architecture "$FZF_TEST_ARCH" privilege direct)
    _SYS_CAPABILITIES_READY=1
    _sys_capabilities_refresh() { return 0; }
    _sys_update_git_logged() { print -r -- "$*" >>"$HOME/git-log"; return 0; }
  '"$1"
}

assert_original_fzf() {
  [ ! -e "$HOME/installer-log" ]
  [ ! -e "$HOME/binary-executed" ]
  [ "$(cat "$HOME/.fzf.zsh")" = 'original integration' ]
  run "$HOME/.fzf/bin/fzf" --version
  [ "$status" -eq 0 ]
  [ "$output" = '0.98.0 (existing)' ]
}

@test "sys fzf integrity: pinned checksum precedes binary fetch and installer never runs" {
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/installer-log" ]
  [ "$(cat "$HOME/transfer-log")" = $'https://github.com/junegunn/fzf/releases/download/v0.99.0/fzf_0.99.0_checksums.txt\nhttps://github.com/junegunn/fzf/releases/download/v0.99.0/fzf-0.99.0-linux_amd64.tar.gz' ]
  grep -q 'verified-binary:--version' "$HOME/binary-executed"
  grep -q 'completion.zsh' "$HOME/.fzf.zsh"
  grep -q 'key-bindings.zsh' "$HOME/.fzf.zsh"
  run zsh -n "$HOME/.fzf.zsh"
  [ "$status" -eq 0 ]
}

@test "sys fzf integrity: unavailable checksum never requests the executable" {
  export FZF_CHECKSUM_MODE=absent
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/installer-log" ]
  [ "$(wc -l <"$HOME/transfer-log")" -eq 1 ]
  [[ "$output" == *"https://github.com/junegunn/fzf/releases"* ]]
  assert_original_fzf
}

@test "sys fzf integrity: malformed duplicate and unmatched checksum rows block archive download" {
  local mode
  for mode in invalid duplicate missing; do
    export FZF_CHECKSUM_MODE="$mode"
    rm -f "$HOME/transfer-log"
    run run_fzf_zsh 'update-fzf --yes'
    [ "$status" -eq 1 ]
    [ "$(wc -l <"$HOME/transfer-log")" -eq 1 ]
    assert_original_fzf
  done
}

@test "sys fzf integrity: checksum mismatch never executes or publishes the payload" {
  export FZF_CHECKSUM_MODE=mismatch
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$HOME/transfer-log")" -eq 2 ]
  assert_original_fzf
}

@test "sys fzf integrity: valid checksum does not authorize a linked archive member" {
  rm "$FZF_RELEASE_FIXTURE/payload/fzf"
  ln -s "$HOME/outside" "$FZF_RELEASE_FIXTURE/payload/fzf"
  build_fzf_release
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$HOME/transfer-log")" -eq 2 ]
  [ ! -e "$HOME/outside" ]
  assert_original_fzf
}

@test "sys fzf integrity: extra archive members are refused even with a matching digest" {
  printf 'unexpected\n' >"$FZF_RELEASE_FIXTURE/payload/extra"
  tar -czf "$FZF_RELEASE_FIXTURE/archive.tar.gz" \
    -C "$FZF_RELEASE_FIXTURE/payload" fzf extra
  local digest
  digest=$(sha256_file "$FZF_RELEASE_FIXTURE/archive.tar.gz")
  printf '%s  fzf-0.99.0-linux_amd64.tar.gz\n' "$digest" >"$FZF_RELEASE_FIXTURE/checksums"
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$HOME/transfer-log")" -eq 2 ]
  assert_original_fzf
}

@test "sys fzf integrity: dry run discloses integrity policy without transfer or publication" {
  run run_fzf_zsh 'update-fzf --dry-run'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/transfer-log" ]
  [ ! -e "$HOME/git-log" ]
  [ ! -e "$HOME/installer-log" ]
  [[ "$output" == *"checksum"* && "$output" == *".fzf.zsh"* ]]
  assert_original_fzf
}

@test "sys fzf integrity: unsupported architecture prints manual guidance without transfer" {
  export FZF_TEST_ARCH=unknown
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/transfer-log" ]
  assert_original_fzf
}

@test "sys fzf integrity: release version is data and ambiguous metadata fails closed" {
  printf '\nversion=0.99.1\n' >>"$HOME/.fzf/install"
  git -C "$HOME/.fzf" add install
  git -C "$HOME/.fzf" -c user.name='ZDX Test' \
    -c user.email='zdx-test@example.invalid' commit --quiet -m 'test: ambiguous version'
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/transfer-log" ]
  [ ! -e "$HOME/installer-log" ]
  assert_original_fzf
}

@test "sys fzf integrity: integration symlinks are refused before any executable fetch" {
  rm "$HOME/.fzf.zsh"
  printf 'protected\n' >"$HOME/outside"
  ln -s "$HOME/outside" "$HOME/.fzf.zsh"
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/transfer-log" ]
  [ ! -e "$HOME/binary-executed" ]
  [ "$(cat "$HOME/outside")" = protected ]
}

@test "sys fzf integrity: redirects cannot change the reviewed publisher or protocol" {
  local mode
  for mode in foreign insecure; do
    export FZF_REDIRECT_MODE="$mode"
    rm -f "$HOME/transfer-log"
    run run_fzf_zsh 'update-fzf --yes'
    [ "$status" -eq 1 ]
    [ "$(wc -l <"$HOME/transfer-log")" -eq 1 ]
    assert_original_fzf
  done
}

@test "sys fzf integrity: official release CDN redirect remains checksum first" {
  export FZF_REDIRECT_MODE=allowed
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$HOME/transfer-log")" -eq 3 ]
  [ "$(sed -n '2p' "$HOME/transfer-log")" = https://release-assets.githubusercontent.com/fzf-checksums ]
  [ ! -e "$HOME/installer-log" ]
}

@test "sys fzf integrity: redirect loops are bounded before any binary request" {
  export FZF_REDIRECT_MODE=loop
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$HOME/transfer-log")" -eq 6 ]
  assert_original_fzf
}

@test "sys fzf integrity: a verified archive still needs the exact checkout version" {
  cat >"$FZF_RELEASE_FIXTURE/payload/fzf" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected version\n' >>"$HOME/binary-executed"
printf '0.98.0\n'
EOF
  chmod -- 755 "$FZF_RELEASE_FIXTURE/payload/fzf"
  build_fzf_release
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [ -e "$HOME/binary-executed" ]
  [ "$(cat "$HOME/.fzf.zsh")" = 'original integration' ]
  run "$HOME/.fzf/bin/fzf" --version
  [ "$status" -eq 0 ]
  [ "$output" = '0.98.0 (existing)' ]
}

@test "sys fzf integrity: transfer interruptions retain 130 and 143" {
  local signal_rc
  for signal_rc in 130 143; do
    export FZF_TRANSFER_RC="$signal_rc"
    run run_fzf_zsh 'update-fzf --yes'
    [ "$status" -eq "$signal_rc" ]
    assert_original_fzf
  done
}

@test "sys fzf integrity: concurrent integration edit preserves the edit and reports installed binary" {
  export FZF_REAL_MV
  FZF_REAL_MV=$(command -v mv)
  cat >"$TEST_MOCK_BIN/mv" <<'EOF'
#!/usr/bin/env bash
target="${!#}"
"$FZF_REAL_MV" "$@" || exit $?
if [[ "$target" == "$HOME/.fzf/bin/fzf" ]]; then
  printf 'concurrent integration edit\n' >"$HOME/.fzf.zsh"
fi
EOF
  chmod -- 755 "$TEST_MOCK_BIN/mv"
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"binary was installed; Zsh integration was not published"* ]]
  [ "$(cat "$HOME/.fzf.zsh")" = 'concurrent integration edit' ]
  run "$HOME/.fzf/bin/fzf" --version
  [ "$status" -eq 0 ]
  [ "$output" = '0.99.0 (verified)' ]
}

@test "sys fzf integrity: stage content changed by its version probe is never published" {
  cat >"$FZF_RELEASE_FIXTURE/payload/fzf" <<'EOF'
#!/usr/bin/env bash
printf '# changed during version observation\n' >>"$0"
printf '0.99.0\n'
EOF
  chmod -- 755 "$FZF_RELEASE_FIXTURE/payload/fzf"
  build_fzf_release
  run run_fzf_zsh 'update-fzf --yes'
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.fzf.zsh")" = 'original integration' ]
  run "$HOME/.fzf/bin/fzf" --version
  [ "$status" -eq 0 ]
  [ "$output" = '0.98.0 (existing)' ]
}

@test "sys fzf integrity: checksum target and source interruptions retain terminal status" {
  local signal_rc boundary
  for signal_rc in 130 143; do
    for boundary in binary source integration; do
      export FZF_OBSERVATION_RC="$signal_rc" FZF_OBSERVATION_BOUNDARY="$boundary"
      run run_fzf_zsh '
        functions[_sys_fzf_original_target_state]=$functions[_sys_update_fzf_target_state]
        _sys_update_fzf_target_state() {
          case "$FZF_OBSERVATION_BOUNDARY:$1" in
            binary:"$HOME/.fzf/bin/fzf"|source:"$HOME/.fzf/shell/completion.zsh"|integration:"$HOME/.fzf.zsh")
              return "$FZF_OBSERVATION_RC" ;;
          esac
          _sys_fzf_original_target_state "$@"
        }
        update-fzf --yes
      '
      [ "$status" -eq "$signal_rc" ]
      [ "$(cat "$HOME/.fzf.zsh")" = 'original integration' ]
    done
  done
}

@test "sys fzf integrity: failure paths remove owned staging and private transfer directories" {
  export FZF_CHECKSUM_MODE=mismatch
  run run_fzf_zsh '
    update-fzf --yes; local update_rc=$?
    local -a leftovers=("$TMPDIR"/zdx-fzf.*(N) "$HOME"/.zdx-fzf-zsh.*(N) "$HOME/.fzf/bin"/.zdx-fzf.*(N))
    (( update_rc == 1 && ${#leftovers} == 0 ))
  '
  [ "$status" -eq 0 ]
}

@test "sys fzf integrity: supported platform assets stay exact and version pinned" {
  local pair platform arch
  for pair in darwin:arm64 darwin:x86_64 linux:aarch64; do
    platform="${pair%:*}"; arch="${pair#*:}"
    export FZF_TEST_OS="$platform" FZF_TEST_ARCH="$arch"
    run run_fzf_zsh '
      _sys_update_fzf_release "$HOME/.fzf" || return
      print -r -- "${reply[1]}:${reply[2]}"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == 0.99.0:fzf-0.99.0-* ]]
    [[ "$output" == *"${platform}_"* ]]
    [ ! -e "$HOME/transfer-log" ]
  done
}

@test "sys fzf integrity: generated loader treats checkout paths as quoted data" {
  local quoted_home="$TEST_TEMP_DIR/home with spaces [literal]"
  run run_fzf_zsh '
    local quoted_home="$TEST_TEMP_DIR/home with spaces [literal]"
    command mv "$HOME" "$quoted_home" || return
    export HOME="$quoted_home"
    path=("$HOME/.fzf/bin" "${path[@]}")
    update-fzf --yes || return
    source "$HOME/.fzf.zsh" || return
    source "$HOME/.fzf.zsh" || return
    local entry
    local -i count=0
    for entry in "${path[@]}"; do
      [[ "$entry" == "$HOME/.fzf/bin" ]] && (( ++count ))
    done
    (( count == 1 ))
  '
  [ "$status" -eq 0 ]
  [ ! -e "$quoted_home/installer-log" ]
}

@test "sys fzf integrity: publication interruptions retain status and the completed phase" {
  export FZF_REAL_MV
  FZF_REAL_MV=$(command -v mv)
  cat >"$TEST_MOCK_BIN/mv" <<'EOF'
#!/usr/bin/env bash
target="${!#}"
case "$FZF_PUBLICATION_BOUNDARY:$target" in
  binary:"$HOME/.fzf/bin/fzf"|integration:"$HOME/.fzf.zsh") exit "$FZF_PUBLICATION_RC" ;;
esac
exec "$FZF_REAL_MV" "$@"
EOF
  chmod -- 755 "$TEST_MOCK_BIN/mv"
  local signal_rc boundary
  for signal_rc in 130 143; do
    for boundary in binary integration; do
      export FZF_PUBLICATION_RC="$signal_rc" FZF_PUBLICATION_BOUNDARY="$boundary"
      run run_fzf_zsh 'update-fzf --yes'
      [ "$status" -eq "$signal_rc" ]
      [ "$(cat "$HOME/.fzf.zsh")" = 'original integration' ]
      if [[ "$boundary" == integration ]]; then
        [[ "$output" == *"binary was installed; Zsh integration was not published"* ]]
      fi
    done
  done
}

prepare_fzf_unexpected_stage() {
  export FZF_STAGE_BOUNDARY="$1"
  export FZF_STAGE_CANARY="$HOME/outside-staging-canary"
  printf 'owned out-of-scope staging canary\n' > "$FZF_STAGE_CANARY"
  chmod -- 640 "$FZF_STAGE_CANARY"
  export FZF_REAL_MKTEMP
  FZF_REAL_MKTEMP=$(command -v mktemp)
  cat > "$TEST_MOCK_BIN/mktemp" <<'MOCK'
#!/usr/bin/env bash
case "$FZF_STAGE_BOUNDARY:$*" in
  "binary:$HOME/.fzf/bin/.zdx-fzf.XXXXXX"|"integration:$HOME/.zdx-fzf-zsh.XXXXXX")
    printf '%s\n' "$FZF_STAGE_CANARY"; exit 0 ;;
esac
exec "$FZF_REAL_MKTEMP" "$@"
MOCK
  chmod -- 755 "$TEST_MOCK_BIN/mktemp"
}

assert_fzf_unexpected_stage_untouched() {
  prepare_fzf_unexpected_stage "$1"
  local before_hash before_mode before_identity
  before_hash=$(sha256_file "$FZF_STAGE_CANARY")
  before_mode=$(file_mode "$FZF_STAGE_CANARY")
  before_identity=$(file_identity "$FZF_STAGE_CANARY")
  run run_fzf_zsh 'update-fzf --yes'
  local observed=absent
  if [[ -f "$FZF_STAGE_CANARY" ]]; then
    observed="$(sha256_file "$FZF_STAGE_CANARY")/$(file_mode "$FZF_STAGE_CANARY")/$(file_identity "$FZF_STAGE_CANARY")"
  fi
  printf 'observed status=%s boundary=%s canary=%s before=%s/%s/%s\n' \
    "$status" "$1" "$observed" "$before_hash" "$before_mode" "$before_identity" >&2
  [[ -f "$FZF_STAGE_CANARY" ]]
  [ "$(sha256_file "$FZF_STAGE_CANARY")" = "$before_hash" ]
  [ "$(file_mode "$FZF_STAGE_CANARY")" = "$before_mode" ]
  [ "$(file_identity "$FZF_STAGE_CANARY")" = "$before_identity" ]
  [ "$status" -eq 1 ]
}

@test "sys fzf integrity: binary mktemp output outside expected staging name is untouched" {
  assert_fzf_unexpected_stage_untouched binary
}

@test "sys fzf integrity: integration mktemp output outside expected staging name is untouched" {
  assert_fzf_unexpected_stage_untouched integration
}

assert_fzf_failed_loader_write() {
  export FZF_LOADER_WRITE_RC="$1"
  local binary_before integration_before binary_after integration_after
  binary_before="$(sha256_file "$HOME/.fzf/bin/fzf")/$(file_mode "$HOME/.fzf/bin/fzf")/$(file_identity "$HOME/.fzf/bin/fzf")"
  integration_before="$(sha256_file "$HOME/.fzf.zsh")/$(file_mode "$HOME/.fzf.zsh")/$(file_identity "$HOME/.fzf.zsh")"
  run run_fzf_zsh '
    print() {
      case "$*" in
        "-r -- source "*"/shell/completion.zsh")
          builtin print -r -- "$FZF_LOADER_WRITE_RC" >> "$HOME/nonfinal-write-errors"
          return "$FZF_LOADER_WRITE_RC" ;;
      esac
      builtin print "$@"
    }
    update-fzf --yes
  '
  binary_after="$(sha256_file "$HOME/.fzf/bin/fzf")/$(file_mode "$HOME/.fzf/bin/fzf")/$(file_identity "$HOME/.fzf/bin/fzf")"
  integration_after="$(sha256_file "$HOME/.fzf.zsh")/$(file_mode "$HOME/.fzf.zsh")/$(file_identity "$HOME/.fzf.zsh")"
  printf 'observed status=%s firstfailedrc=%s binary-before=%s binary-after=%s loader-before=%s loader-after=%s loader-size=%s\n' \
    "$status" "$(head -n 1 "$HOME/nonfinal-write-errors")" \
    "$binary_before" "$binary_after" "$integration_before" "$integration_after" \
    "$(file_size "$HOME/.fzf.zsh")" >&2
  [ "$(cat "$HOME/nonfinal-write-errors")" = "$FZF_LOADER_WRITE_RC" ]
  [ "$status" -eq "$FZF_LOADER_WRITE_RC" ]
  [ "$binary_after" = "$binary_before" ]
  [ "$integration_after" = "$integration_before" ]
}

@test "sys fzf integrity: first nonfinal loader write failure1 stops before publication" {
  assert_fzf_failed_loader_write 1
}
@test "sys fzf integrity: first nonfinal loader write130 stops before publication" {
  assert_fzf_failed_loader_write 130
}
@test "sys fzf integrity: first nonfinal loader write143 stops before publication" {
  assert_fzf_failed_loader_write 143
}
