#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

# APT signing-key renewal for known repositories. APT, curl, gpg, sudo, and
# install are mocks; the APT layout (sources and keyrings) lives in the
# sandbox, owned by the test user in place of root.

setup() {
  load test_helper
  skip_on_darwin "APT and its signing keyrings exist only on Debian-based Linux"

  export APT_KEY_ROOT="$TEST_TEMP_DIR/apt"
  export APT_KEY_LOG="$TEST_TEMP_DIR/apt-key.log"
  export APT_KEY_CURL_LOG="$TEST_TEMP_DIR/apt-key-curl.log"
  export APT_KEY_GPG_LOG="$TEST_TEMP_DIR/apt-key-gpg.log"
  export APT_KEY_FAILURE_FILE="$TEST_TEMP_DIR/apt-update.out"
  export APT_KEY_DOWNLOAD="$TEST_TEMP_DIR/download.key"
  export APT_KEY_KEYRING="$APT_KEY_ROOT/keyrings/githubcli-archive-keyring.gpg"
  export APT_KEY_SOURCE="$APT_KEY_ROOT/sources.list.d/github-cli.list"
  export APT_KEY_REPOSITORY="https://cli.github.com/packages stable"
  export APT_KEY_ACCEPT_MARKER="new-ghcli"
  export APT_KEY_CURL_STATUS=0
  export MOCK_SUDO_ALLOW="apt-key-env,install"
  : > "$APT_KEY_LOG"
  : > "$APT_KEY_CURL_LOG"
  : > "$APT_KEY_GPG_LOG"

  mkdir -p "$APT_KEY_ROOT/sources.list.d" "$APT_KEY_ROOT/keyrings"
  chmod -- 755 "$APT_KEY_ROOT" "$APT_KEY_ROOT/sources.list.d" \
    "$APT_KEY_ROOT/keyrings"
  # A keyring whose old key is still valid: APT asks for a newer key.
  printf 'fixture old-valid\n' > "$APT_KEY_KEYRING"
  chmod -- 644 "$APT_KEY_KEYRING"
  printf 'deb [arch=amd64 signed-by=%s] https://cli.github.com/packages stable main\n' \
    "$APT_KEY_KEYRING" > "$APT_KEY_SOURCE"
  printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
    'old-expired new-ghcli' '-----END PGP PUBLIC KEY BLOCK-----' \
    > "$APT_KEY_DOWNLOAD"
  cat > "$APT_KEY_FAILURE_FILE" <<'EOF'
Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease
Get:2 https://cli.github.com/packages stable InRelease [3917 B]
Err:2 https://cli.github.com/packages stable InRelease
  The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 5612B36462313325
Reading package lists... Done
W: GPG error: https://cli.github.com/packages stable InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 5612B36462313325
E: The repository 'https://cli.github.com/packages stable InRelease' is not signed.
EOF

  # APT verifies the repository only when its keyring holds the marker.
  cat > "$TEST_MOCK_BIN/apt-key-env" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == -i ]] || exit 97
shift
while [[ "${1:-}" == *=* ]]; do shift; done
[[ "${1:-}" == apt-get ]] || exit 97
shift
if IFS= read -r unexpected_input; then exit 98; fi
if [[ " $* " == *" -s "* ]]; then
  printf 'simulate\n' >> "$APT_KEY_LOG"
  printf 'Inst example [1.0] (1.1 stable [amd64])\n'
  exit 0
fi
case " $* " in
  *" update --error-on=any "*)
    printf 'update\n' >> "$APT_KEY_LOG"
    if [[ -n "${APT_KEY_ACCEPT_MARKER:-}" ]] \
      && grep -q -- "$APT_KEY_ACCEPT_MARKER" "$APT_KEY_KEYRING" 2>/dev/null; then
      printf 'Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease\n'
      printf 'Get:2 %s InRelease [3917 B]\n' "$APT_KEY_REPOSITORY"
      printf 'Reading package lists... Done\n'
      exit 0
    fi
    cat "$APT_KEY_FAILURE_FILE"
    exit 100
    ;;
  *" full-upgrade "*)
    printf 'full-upgrade\n' >> "$APT_KEY_LOG"
    printf '1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n'
    ;;
  *" autoremove "*)
    printf 'autoremove\n' >> "$APT_KEY_LOG"
    printf '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n'
    ;;
  *) exit 97 ;;
esac
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/apt-key-env"

  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
{ printf 'curl'; printf ' %s' "$@"; printf '\n'; } >> "$APT_KEY_CURL_LOG"
if [[ "${APT_KEY_CURL_STATUS:-0}" != 0 ]]; then
  printf 'curl: (22) The requested URL returned error: 404\n' >&2
  exit "$APT_KEY_CURL_STATUS"
fi
cat -- "$APT_KEY_DOWNLOAD"
EOF
  chmod +x "$TEST_MOCK_BIN/curl"

  # gpg lists the keys named by markers in a fixture file, with the colon
  # records of the real GitHub CLI keyring, and models --dearmor.
  cat > "$TEST_MOCK_BIN/gpg" <<'EOF'
#!/usr/bin/env bash
set -u
{ printf 'gpg'; printf ' %s' "$@"; printf '\n'; } >> "$APT_KEY_GPG_LOG"
mode="" output="" homedir=""
args=("$@")
for (( index = 0; index < ${#args[@]}; index++ )); do
  case "${args[index]}" in
    --show-keys) mode=show ;;
    --dearmor) mode=dearmor ;;
    --output) output="${args[index + 1]}" ;;
    --homedir) homedir="${args[index + 1]}" ;;
  esac
done
[[ -d "$homedir" && "$homedir" != "$HOME/.gnupg" ]] || exit 96
file="${args[${#args[@]} - 1]}"
content=$(cat -- "$file") || exit 2
case "$mode" in
  show)
    found=0
    if [[ "$content" == *old-expired* ]]; then
      printf '%s\n' \
        'pub:e:4096:1:23F3D4EA75716059:1662463626:1788612228::-:::sc::::::23::0:' \
        'fpr:::::::::2C6106201985B60E6C7AC87323F3D4EA75716059:' \
        'uid:e::::1725540228::8112F49127753770F34E73A49614E0AFC050A705::GitHub CLI <opensource+cli@github.com>::::::::::0:' \
        'sub:e:4096:1:E5FAF19590714157:1662463626:1788612228:::::e::::::23:' \
        'fpr:::::::::5700BAB26C8DE75F3EE323FEE5FAF19590714157:'
      found=1
    fi
    if [[ "$content" == *old-valid* ]]; then
      printf '%s\n' \
        'pub:-:4096:1:23F3D4EA75716059:1662463626:::-:::scESC::::::23::0:' \
        'fpr:::::::::2C6106201985B60E6C7AC87323F3D4EA75716059:'
      found=1
    fi
    if [[ "$content" == *new-ghcli* || "$content" == *fake-ghcli* ]]; then
      printf '%s\n' \
        'pub:-:4096:1:5612B36462313325:1775559160:::-:::scESC::::::23::0:' \
        'fpr:::::::::7F38BBB59D064DBCB3D84D725612B36462313325:' \
        'uid:-::::1775559160::8112F49127753770F34E73A49614E0AFC050A705::GitHub CLI <opensource+cli@github.com>::::::::::0:' \
        'sub:-:4096:1:F4CAB2C46C97E579:1775559160::::::e::::::23:' \
        'fpr:::::::::B84252FAAA164D9EBEA2E2C1F4CAB2C46C97E579:'
      found=1
    fi
    if [[ "$content" == *other-publisher* ]]; then
      printf '%s\n' \
        'pub:-:4096:1:9999000011112222:1775559160:::-:::scESC::::::23::0:' \
        'fpr:::::::::AAAABBBBCCCCDDDDEEEEFFFF9999000011112222:'
      found=1
    fi
    (( found )) || { printf 'gpg: no valid OpenPGP data found.\n' >&2; exit 2; }
    ;;
  dearmor)
    [[ -n "$output" ]] || exit 97
    { printf 'binary\n'; grep -v -- '-----' "$file"; } > "$output"
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/gpg"
}

teardown() {
  cleanup_sandbox
}

run_apt_keys_zsh() {
  run_zsh '
    export TZ=UTC
    source "$TEST_SUITE_ROOT/functions/sys-menu.zsh" || exit 98
    _SYS_PRIVILEGE_NONINTERACTIVE=1
    _sys_has_capability() { [[ "$1" == "package:apt" ]]; }
    _sys_update_resolve_trusted_program() {
      case "$1" in
        env) REPLY="$TEST_MOCK_BIN/apt-key-env" ;;
        gpg|curl|install) REPLY="$TEST_MOCK_BIN/$1" ;;
        *) return 1 ;;
      esac
    }
    _sys_run_with_timeout() { shift; "$@"; }
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_resolve_privilege_prefix() { reply=(sudo -n); }
    sudo() { "$TEST_MOCK_BIN/sudo" "$@"; }
    _sys_apt_dpkg_state_clean() { return 0; }
    _sys_apt_report_reboot_requirement() { REPLY=""; }
    _sys_apt_key_layout() {
      reply=("$APT_KEY_ROOT/sources.list" "$APT_KEY_ROOT/sources.list.d"
        "$EUID" "$APT_KEY_ROOT/keyrings")
    }
    '"$1"'
  '
}

expected_curl_call() {
  printf '%s' 'curl -q --silent --show-error --fail --location' \
    ' --max-redirs 5 --proto =https --proto-redir =https --tlsv1.2' \
    ' --connect-timeout 10 --max-time 30 --max-filesize 1048576' \
    ' --output - -- https://cli.github.com/packages/githubcli-archive-keyring.gpg'
}

# The privileged install calls recorded by the sudo mock.
install_calls() {
  grep -F -- "$TEST_MOCK_BIN/install " "$MOCK_SUDO_LOG" || true
}

assert_no_key_workspace() {
  local leftover
  for leftover in "$TMPDIR"/zdx-sys-apt-key.*; do
    [[ ! -e "$leftover" ]] || return 1
  done
}

@test "sys APT keys: a reported missing key of a known repository is renewed and verified by one retry" {
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 0 ]
  [ "$(cat "$APT_KEY_LOG")" = $'simulate\nupdate\nupdate\nfull-upgrade\nautoremove' ]
  [ "$(cat "$APT_KEY_CURL_LOG")" = "$(expected_curl_call)" ]
  [[ "$output" == *"APT reported a missing or expired signing key for 1 known repository."* ]]
  [[ "$output" == *"Renewing the GitHub CLI signing key"* ]]
  [[ "$output" == *"  Repository:        https://cli.github.com/packages stable"$'\n'* ]]
  [[ "$output" == *"Source file:"*"$APT_KEY_SOURCE"* ]]
  [[ "$output" == *"Keyring:"*"$APT_KEY_KEYRING"* ]]
  [[ "$output" == *"Key URL:"*"https://cli.github.com/packages/githubcli-archive-keyring.gpg"* ]]
  [[ "$output" == *"Current keys:"*"2C61 0620 … 7571 6059 (valid, no expiry)"* ]]
  [[ "$output" == *"Requested key:"*"5612B36462313325"* ]]
  [[ "$output" == *"New key:"*"7F38 BBB5 … 6231 3325"* ]]
  [[ "$output" == *"Retrying the APT index update once to verify the renewed key."* ]]
  [[ "$output" == *"✔ Renewed the GitHub CLI signing key (7F38 BBB5 … 6231 3325)"* ]]
  [[ "$output" == *"APT update plan completed: 1 upgraded, 0 newly installed, 0 removed, GitHub CLI key renewed."* ]]
  [[ "$output" != *"APT index update failed"* ]]
  # The armored download was converted for the binary .gpg keyring.
  [ "$(cat "$APT_KEY_KEYRING")" = $'binary\nold-expired new-ghcli' ]
  [ "$(file_mode "$APT_KEY_KEYRING")" = 644 ]
  grep -Fq -- '--dearmor' "$APT_KEY_GPG_LOG"
  # The exact announced privileged argv, with the private staged file.
  [ "$(install_calls | wc -l)" -eq 1 ]
  local install_call
  install_call=$(install_calls)
  [[ "$install_call" == "sudo -n $TEST_MOCK_BIN/install -m 0644 -o 0 -g 0 $TMPDIR/zdx-sys-apt-key."??????"/1/githubcli-archive-keyring.gpg $APT_KEY_KEYRING" ]]
  [[ "$output" == *"Privileged operation: ${install_call}"* ]]
  assert_no_key_workspace
}

@test "sys APT keys: an expired dedicated keyring is renewed before the index update" {
  printf 'fixture old-expired\n' > "$APT_KEY_KEYRING"
  # A second suite shares the keyring; both are verified together.
  printf 'deb [signed-by=%s] https://cli.github.com/packages unstable main\n' \
    "$APT_KEY_KEYRING" >> "$APT_KEY_SOURCE"
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 0 ]
  # The first refresh already verifies the renewed key; there is no retry.
  [ "$(cat "$APT_KEY_LOG")" = $'simulate\nupdate\nfull-upgrade\nautoremove' ]
  [[ "$output" == *"Renew key:"*"GitHub CLI (expired 2026-09-05): $APT_KEY_KEYRING"* ]]
  [[ "$output" == *"Current keys:"*"2C61 0620 … 7571 6059 (expired 2026-09-05)"* ]]
  [[ "$output" != *"Requested key:"* ]]
  [[ "$output" == *"  Repository:        https://cli.github.com/packages stable and 1 more"$'\n'* ]]
  [[ "$output" == *"New key:"*"7F38 BBB5 … 6231 3325"* ]]
  [[ "$output" != *"Retrying the APT index update"* ]]
  [[ "$output" == *"✔ Renewed the GitHub CLI signing key (7F38 BBB5 … 6231 3325)"* ]]
  [ "$(cat "$APT_KEY_CURL_LOG")" = "$(expected_curl_call)" ]
  [ "$(cat "$APT_KEY_KEYRING")" = $'binary\nold-expired new-ghcli' ]
  [ "$(install_calls | wc -l)" -eq 1 ]
  assert_no_key_workspace
}

@test "sys APT keys: a download without the requested key ID is refused before installation" {
  printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'other-publisher' \
    '-----END PGP PUBLIC KEY BLOCK-----' > "$APT_KEY_DOWNLOAD"
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 1 ]
  [ "$(cat "$APT_KEY_LOG")" = $'simulate\nupdate' ]
  [ -z "$(install_calls)" ]
  [ "$(cat "$APT_KEY_KEYRING")" = "fixture old-valid" ]
  [[ "$output" == *"does not contain a valid signing key 5612B36462313325"* ]]
  [[ "$output" == *"APT index update failed."* ]]
  [[ "$output" == *"This is a problem with the repository's signing key, not with ZDX: https://cli.github.com/packages stable ($APT_KEY_SOURCE) needs key 5612B36462313325."* ]]
  [[ "$output" == *"ZDX could not renew it: the key at https://cli.github.com/packages/githubcli-archive-keyring.gpg does not contain a valid signing key 5612B36462313325."* ]]
  [[ "$output" == *"Install the publisher's current key from its official instructions: sudo install -m 0644 -o 0 -g 0 <downloaded-key> $APT_KEY_KEYRING"* ]]
  [[ "$output" == *"Or disable the source: sudo mv $APT_KEY_SOURCE $APT_KEY_SOURCE.disabled"* ]]
  [[ "$output" == *"After fixing the cause, run: sys-menu update-apt"* ]]
  [[ "$output" != *"Renewed the GitHub CLI signing key"* ]]
  assert_no_key_workspace
}

@test "sys APT keys: a failed download leaves the keyring untouched" {
  export APT_KEY_CURL_STATUS=22
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 1 ]
  [ -z "$(install_calls)" ]
  [ "$(cat "$APT_KEY_KEYRING")" = "fixture old-valid" ]
  [[ "$output" == *"ZDX could not renew it: downloading https://cli.github.com/packages/githubcli-archive-keyring.gpg failed ((22) The requested URL returned error: 404)."* ]]
  assert_no_key_workspace
}

@test "sys APT keys: the previous keyring is restored when APT still rejects the repository" {
  printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'fake-ghcli' \
    '-----END PGP PUBLIC KEY BLOCK-----' > "$APT_KEY_DOWNLOAD"
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 1 ]
  [ "$(cat "$APT_KEY_LOG")" = $'simulate\nupdate\nupdate' ]
  [ "$(cat "$APT_KEY_KEYRING")" = "fixture old-valid" ]
  [ "$(file_mode "$APT_KEY_KEYRING")" = 644 ]
  [ "$(install_calls | wc -l)" -eq 2 ]
  [[ "$(install_calls | sed -n 2p)" == "sudo -n $TEST_MOCK_BIN/install -m 0644 -o 0 -g 0 $TMPDIR/zdx-sys-apt-key."??????"/1/previous $APT_KEY_KEYRING" ]]
  [[ "$output" == *"APT still cannot verify GitHub CLI with the downloaded key; the previous keyring was restored."* ]]
  [[ "$output" == *"ZDX could not renew it: APT still could not verify it with the key from its publisher, so ZDX restored the previous keyring."* ]]
  [[ "$output" != *"✔ Renewed the GitHub CLI signing key"* ]]
  [[ "$output" == *"APT index update failed."* ]]
  assert_no_key_workspace
}

@test "sys APT keys: an unknown repository gets plain guidance and no download" {
  printf 'fixture unknown\n' > "$APT_KEY_ROOT/keyrings/example.gpg"
  printf 'deb [signed-by=%s] https://apt.example.org/debian stable main\n' \
    "$APT_KEY_ROOT/keyrings/example.gpg" \
    > "$APT_KEY_ROOT/sources.list.d/example.list"
  cat > "$APT_KEY_FAILURE_FILE" <<'EOF'
Err:3 https://apt.example.org/debian stable InRelease
  The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 0123456789ABCDEF
E: The repository 'https://apt.example.org/debian stable InRelease' is not signed.
EOF
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 1 ]
  [ ! -s "$APT_KEY_CURL_LOG" ]
  [ -z "$(install_calls)" ]
  [ "$(cat "$APT_KEY_LOG")" = $'simulate\nupdate' ]
  [[ "$output" == *"APT index update failed."* ]]
  [[ "$output" == *"This is a problem with the repository's signing key, not with ZDX: https://apt.example.org/debian stable ($APT_KEY_ROOT/sources.list.d/example.list) needs key 0123456789ABCDEF."* ]]
  [[ "$output" == *"ZDX renews keys automatically only for GitHub CLI, Google Cloud SDK, Charm, Docker, HashiCorp, Microsoft, NodeSource, and Google Chrome."* ]]
  [[ "$output" == *"sudo install -m 0644 -o 0 -g 0 <downloaded-key> $APT_KEY_ROOT/keyrings/example.gpg"* ]]
  [[ "$output" == *"Or disable the source: sudo mv $APT_KEY_ROOT/sources.list.d/example.list $APT_KEY_ROOT/sources.list.d/example.list.disabled"* ]]
  [[ "$output" != *"Renewing the"* ]]
}

@test "sys APT keys: an inline deb822 key and global trust are never changed" {
  rm -f "$APT_KEY_SOURCE"
  cat > "$APT_KEY_ROOT/sources.list.d/github-cli.sources" <<'EOF'
Types: deb
URIs: https://cli.github.com/packages/
Suites: stable
Components: main
Signed-By: -----BEGIN PGP PUBLIC KEY BLOCK-----
 .
 mQINBGYo2OYBEADVRjI+o29u9izslaVr0Xqj8hpmo
 -----END PGP PUBLIC KEY BLOCK-----
EOF
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 1 ]
  [ ! -s "$APT_KEY_CURL_LOG" ]
  [ -z "$(install_calls)" ]
  [[ "$output" == *"Its key is embedded in the source file, and ZDX renews only dedicated keyrings of GitHub CLI,"* ]]
  [[ "$output" == *"Install the publisher's current key from its official instructions, as its documentation describes."* ]]
  [[ "$output" == *"Or disable the source: sudo mv $APT_KEY_ROOT/sources.list.d/github-cli.sources $APT_KEY_ROOT/sources.list.d/github-cli.sources.disabled"* ]]

  rm -f "$APT_KEY_ROOT/sources.list.d/github-cli.sources"
  printf 'deb https://cli.github.com/packages stable main\n' \
    > "$APT_KEY_ROOT/sources.list"
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 1 ]
  [ ! -s "$APT_KEY_CURL_LOG" ]
  [ -z "$(install_calls)" ]
  [[ "$output" == *"It has no signed-by keyring, and ZDX renews only dedicated keyrings of GitHub CLI,"* ]]
  [[ "$output" == *"Or disable the source: comment out its entry in $APT_KEY_ROOT/sources.list"* ]]
}

@test "sys APT keys: a symlinked or group-writable keyring is never replaced" {
  printf 'fixture old-valid\n' > "$APT_KEY_ROOT/real-keyring.gpg"
  rm -f "$APT_KEY_KEYRING"
  ln -s "$APT_KEY_ROOT/real-keyring.gpg" "$APT_KEY_KEYRING"
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 1 ]
  [ ! -s "$APT_KEY_CURL_LOG" ]
  [ -z "$(install_calls)" ]
  [ -L "$APT_KEY_KEYRING" ]
  [ "$(cat "$APT_KEY_ROOT/real-keyring.gpg")" = "fixture old-valid" ]
  [[ "$output" == *"ZDX does not replace its keyring because it is a symbolic link."* ]]

  rm -f "$APT_KEY_KEYRING"
  printf 'fixture old-valid\n' > "$APT_KEY_KEYRING"
  chmod -- 664 "$APT_KEY_KEYRING"
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 1 ]
  [ ! -s "$APT_KEY_CURL_LOG" ]
  [ -z "$(install_calls)" ]
  [ "$(cat "$APT_KEY_KEYRING")" = "fixture old-valid" ]
  [[ "$output" == *"ZDX does not replace its keyring because it is group- or world-writable."* ]]
}

@test "sys APT keys: disabled renewal keeps the diagnosis and downloads nothing" {
  printf 'fixture old-expired\n' > "$APT_KEY_KEYRING"
  export SYS_APT_KEY_RENEWAL=0
  run run_apt_keys_zsh 'update-apt --yes'

  [ "$status" -eq 1 ]
  [ ! -s "$APT_KEY_CURL_LOG" ]
  [ ! -s "$APT_KEY_GPG_LOG" ]
  [ -z "$(install_calls)" ]
  [ "$(cat "$APT_KEY_LOG")" = $'simulate\nupdate' ]
  [[ "$output" == *"Key renewal:"*"off (SYS_APT_KEY_RENEWAL=0)"* ]]
  [[ "$output" == *"Automatic key renewal is off (SYS_APT_KEY_RENEWAL=0); it covers GitHub CLI,"* ]]
  [[ "$output" == *"APT index update failed."* ]]

  export SYS_APT_KEY_RENEWAL=maybe
  run run_apt_keys_zsh 'update-apt --yes'
  [ "$status" -eq 2 ]
  [[ "$output" == *"SYS_APT_KEY_RENEWAL must be exactly 0 or 1."* ]]
  [ "$(cat "$APT_KEY_LOG")" = $'simulate\nupdate\nsimulate' ]
}

@test "sys APT keys: a dry run names the keys it would renew without downloading or installing" {
  printf 'fixture old-expired\n' > "$APT_KEY_KEYRING"
  run run_apt_keys_zsh 'update-apt --dry-run --yes'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Key renewal:"*"known repositories; their publisher keys are installed with sudo"* ]]
  [[ "$output" == *"Renew key:"*"GitHub CLI (expired 2026-09-05): $APT_KEY_KEYRING"* ]]
  [[ "$output" == *"Key URL:"*"https://cli.github.com/packages/githubcli-archive-keyring.gpg"* ]]
  [[ "$output" == *"Dry run complete; APT state was not changed."* ]]
  [ ! -s "$APT_KEY_CURL_LOG" ]
  [ -z "$(install_calls)" ]
  [ "$(cat "$APT_KEY_LOG")" = "simulate" ]
  [ "$(cat "$APT_KEY_KEYRING")" = "fixture old-expired" ]
  # The dry run reads the local keyring only through gpg --show-keys.
  ! grep -Fq -- '--dearmor' "$APT_KEY_GPG_LOG" || false
  assert_no_key_workspace
}

@test "sys APT keys: the aggregate plan discloses key renewal in the APT scope" {
  printf 'fixture old-expired\n' > "$APT_KEY_KEYRING"
  run run_apt_keys_zsh '
    _sys_capabilities_refresh_for_command() { return 0; }
    _sys_step_applies() { [[ "$1" == "update-apt" ]]; }
    update-system --dry-run --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"APT packages · sudo · key renewal for known repositories"* ]]
  [[ "$output" == *"Renew key:"*"GitHub CLI (expired 2026-09-05)"* ]]
  [[ "$output" == *"1 candidate, 1 signing key to renew"* ]]
  [ ! -s "$APT_KEY_CURL_LOG" ]
  [ -z "$(install_calls)" ]

  export SYS_APT_KEY_RENEWAL=0
  run run_apt_keys_zsh '
    _sys_capabilities_refresh_for_command() { return 0; }
    _sys_step_applies() { [[ "$1" == "update-apt" ]]; }
    update-system --dry-run --yes
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"APT packages · sudo"* ]]
  [[ "$output" != *"key renewal for known repositories"* ]]

  export SYS_APT_KEY_RENEWAL=2
  run run_apt_keys_zsh '
    _sys_capabilities_refresh_for_command() { return 0; }
    _sys_step_applies() { [[ "$1" == "update-apt" ]]; }
    update-system --dry-run --yes
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"SYS_APT_KEY_RENEWAL must be exactly 0 or 1."* ]]
}

@test "sys APT keys: an aggregate run reports the renewal in the step summary" {
  run run_apt_keys_zsh '
    _sys_capabilities_refresh_for_command() { return 0; }
    _sys_step_applies() { [[ "$1" == "update-apt" ]]; }
    _sys_update_lock_path() { REPLY="$HOME/.zdx-update-system.lock"; }
    _sys_update_preauthenticate() { REPLY=0; }
    update-system --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"✔ Renewed the GitHub CLI signing key (7F38 BBB5 … 6231 3325)"* ]]
  [[ "$output" == *"[1/1] APT — updated: 1 upgraded, 0 newly installed, 0 removed, GitHub CLI key renewed"* ]]
  [[ "$output" == *"Update Summary"* ]]
}

@test "sys APT keys: the registry matches publisher hosts and paths exactly" {
  run run_apt_keys_zsh '
    local uri
    for uri in \
      https://cli.github.com/packages \
      https://CLI.GitHub.com/packages/ \
      https://cli.github.com/packagesX \
      http://cli.github.com/packages \
      https://user@cli.github.com/packages \
      https://cli.github.com:8443/packages \
      https://packages.cloud.google.com/apt \
      https://repo.charm.sh/apt/ \
      https://download.docker.com/linux/ubuntu \
      https://download.docker.com/linux/fedora \
      https://apt.releases.hashicorp.com \
      https://packages.microsoft.com/ubuntu/24.04/prod \
      https://deb.nodesource.com/node_22.x \
      https://dl.google.com/linux/chrome/deb \
      https://dl.google.com/other \
      https://ppa.launchpadcontent.net/git-core/ppa/ubuntu; do
      if _sys_apt_key_registry_match "$uri"; then
        print -r -- "$uri|${reply[1]}|${reply[2]}"
      else
        print -r -- "$uri|-"
      fi
    done
  '

  [ "$status" -eq 0 ]
  [ "$output" = "https://cli.github.com/packages|GitHub CLI|https://cli.github.com/packages/githubcli-archive-keyring.gpg
https://CLI.GitHub.com/packages/|GitHub CLI|https://cli.github.com/packages/githubcli-archive-keyring.gpg
https://cli.github.com/packagesX|-
http://cli.github.com/packages|-
https://user@cli.github.com/packages|-
https://cli.github.com:8443/packages|-
https://packages.cloud.google.com/apt|Google Cloud SDK|https://packages.cloud.google.com/apt/doc/apt-key.gpg
https://repo.charm.sh/apt/|Charm|https://repo.charm.sh/apt/gpg.key
https://download.docker.com/linux/ubuntu|Docker|https://download.docker.com/linux/ubuntu/gpg
https://download.docker.com/linux/fedora|-
https://apt.releases.hashicorp.com|HashiCorp|https://apt.releases.hashicorp.com/gpg
https://packages.microsoft.com/ubuntu/24.04/prod|Microsoft|https://packages.microsoft.com/keys/microsoft.asc
https://deb.nodesource.com/node_22.x|NodeSource|https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
https://dl.google.com/linux/chrome/deb|Google Chrome|https://dl.google.com/linux/linux_signing_key.pub
https://dl.google.com/other|-
https://ppa.launchpadcontent.net/git-core/ppa/ubuntu|-" ]
}

@test "sys APT keys: APT 3 sqv reports of a missing key are classified as key problems" {
  run run_apt_keys_zsh '
    _sys_apt_classify_index_problem "Sub-process /usr/bin/sqv returned an error code (1), error message is: Missing key 7F38BBB59D064DBCB3D84D725612B36462313325, which is needed to verify signature."
    print -r -- "$REPLY"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'key\tsigning key not installed (Missing key 7F38BBB59D064DBCB3D84D725612B36462313325)' ]
}
