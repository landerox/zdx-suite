#!/usr/bin/env bats
# Literal Zsh programs and per-test exported controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export LC_ALL=C NO_COLOR=1 TERM=dumb GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  export CREATE_BASE="$HOME/workspaces" CREATE_ID=test
  mkdir -m 700 "$HOME/.ssh"
  printf '# Keep unrelated configuration\nHost unrelated\n  HostName elsewhere.invalid\n' > "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"
  cp "$HOME/.ssh/config" "$HOME/ssh.before"
  cat > "$TEST_MOCK_BIN/ssh-keygen" <<'EOF'
#!/usr/bin/env zsh
[[ "$#" == 9 && "$1" == -t && "$2" == ed25519 && "$3" == -C \
  && "$4" == fixture@example.invalid && "$5" == -f && "$7" == -N \
  && -z "$8" && "$9" == -q ]] || exit 97
print -r -- "$6" >> "$HOME/keygen.calls"
print -r -- FIXTURE > "$6"
print -r -- 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURE fixture' > "$6.pub"
if [[ "${CREATE_SWAP_CONFIG:-0}" == 1 ]]; then
  print -r -- 'Host github-test' > "$HOME/.ssh/config"
  print -r -- '  HostName changed.invalid' >> "$HOME/.ssh/config"
fi
EOF
  chmod +x "$TEST_MOCK_BIN/ssh-keygen"
  cat > "$TEST_MOCK_BIN/ssh" <<'EOF'
#!/usr/bin/env zsh
print -r -- "$*" >> "$HOME/ssh.calls"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/ssh"
}

teardown() {
  cleanup_sandbox
}

run_create() {
  run_zsh '
    WS_BASE_DIR="$CREATE_BASE"
    typeset -gA ZDX_GIT_IDENTITIES=()
    _ws_fzf_capture() { REPLY=github; }
    _tk_confirm() { return 1; }
    printf "%s\n" "$CREATE_ID" "Fixture User" "fixture@example.invalid" > "$HOME/create.input"
    ws-create < "$HOME/create.input" > "$HOME/create.stdout"
  '
}

write_compatible_alias() {
  printf '  hOsT unrelated-alias github-test\n    hOsTnAmE = "github.com" # expected host\n    uSeR git\n    IdentityFile "%s/.ssh/id_ed25519" # exact key\n    IdentitiesOnly YES\n    CanonicalizeHostname NO\n' \
    "$CREATE_BASE/github/test" >> "$HOME/.ssh/config"
}

assert_no_creation() {
  [ ! -e "$CREATE_BASE/github/test" ]
  [ ! -e "$HOME/.gitconfig" ]
  [ ! -e "$HOME/keygen.calls" ]
  [ ! -e "$HOME/ssh.calls" ]
  cmp "$HOME/ssh.before" "$HOME/.ssh/config"
}

@test "ws create recovery: conflicting explicit alias fails before creating files" {
  printf 'Host github-test\n  HostName wrong.invalid\n  User git\n  IdentityFile /wrong/key\n  IdentitiesOnly yes\n' >> "$HOME/.ssh/config"
  cp "$HOME/.ssh/config" "$HOME/ssh.before"
  run run_create
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflicts with existing or ambiguous configuration"* ]]
  assert_no_creation
}

@test "ws create recovery: compatible indented multiple alias block remains unchanged" {
  write_compatible_alias
  cp "$HOME/.ssh/config" "$HOME/ssh.before"
  run run_create
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reusing the verified SSH alias"* ]]
  [ -f "$CREATE_BASE/github/test/.ssh/id_ed25519" ]
  [ -f "$HOME/.gitconfig" ]
  [ ! -s "$HOME/create.stdout" ]
  [ ! -e "$HOME/ssh.calls" ]
  cmp "$HOME/ssh.before" "$HOME/.ssh/config"
}

@test "ws create recovery: a new alias quotes a workspace path with spaces" {
  export CREATE_BASE="$HOME/work spaces"
  run run_create
  [ "$status" -eq 0 ]
  grep -Fxq "    IdentityFile \"$CREATE_BASE/github/test/.ssh/id_ed25519\"" "$HOME/.ssh/config"
  grep -Fxq "$CREATE_BASE/github/test/.ssh/id_ed25519" "$HOME/keygen.calls"
  grep -Fxq 'Host unrelated' "$HOME/.ssh/config"
  [ ! -e "$HOME/ssh.calls" ]
}

@test "ws create recovery: Host arguments retain case and keyword case is ignored" {
  printf 'HOST GITHUB-TEST\n  HostName wrong.invalid\n' >> "$HOME/.ssh/config"
  run run_create
  [ "$status" -eq 0 ]
  grep -Fxq 'HOST GITHUB-TEST' "$HOME/.ssh/config"
  grep -Fxq 'Host github-test' "$HOME/.ssh/config"
}

@test "ws create recovery: duplicate aliases and additional identities are ambiguous" {
  for extra in 'Host github-test' 'IdentityFile /another/key'; do
    cp "$HOME/ssh.before" "$HOME/.ssh/config"
    write_compatible_alias
    printf '%s\n' "$extra" >> "$HOME/.ssh/config"
    cp "$HOME/.ssh/config" "$HOME/expected.config"
    run run_create
    [ "$status" -eq 1 ]
    [ ! -e "$CREATE_BASE/github/test" ]
    [ ! -e "$HOME/keygen.calls" ]
    cmp "$HOME/expected.config" "$HOME/.ssh/config"
  done
}

@test "ws create recovery: wildcard defaults cannot silently override the alias" {
  printf 'Host github-*\n  User another-user\n' >> "$HOME/.ssh/config"
  write_compatible_alias
  cp "$HOME/.ssh/config" "$HOME/ssh.before"
  run run_create
  [ "$status" -eq 1 ]
  assert_no_creation
}

@test "ws create recovery: negated wildcard block does not conflict with exact alias" {
  printf 'Host github-* !github-test\n  User another-user\n' >> "$HOME/.ssh/config"
  write_compatible_alias
  cp "$HOME/.ssh/config" "$HOME/ssh.before"
  run run_create
  [ "$status" -eq 0 ]
  cmp "$HOME/ssh.before" "$HOME/.ssh/config"
}

@test "ws create recovery: Match and Include remain passive and fail before mutation" {
  for directive in 'Match exec "touch $HOME/executed"' 'Include ~/.ssh/extra.conf'; do
    cp "$HOME/ssh.before" "$HOME/.ssh/config"
    printf '%s\n' "$directive" >> "$HOME/.ssh/config"
    run run_create
    [ "$status" -eq 1 ]
    [ ! -e "$HOME/executed" ]
    [ ! -e "$HOME/ssh.calls" ]
    [ ! -e "$CREATE_BASE/github/test" ]
  done
}

@test "ws create recovery: changed config during key generation is not overwritten" {
  export CREATE_SWAP_CONFIG=1
  run run_create
  [ "$status" -eq 1 ]
  [[ "$output" == *"SSH configuration changed before routing publication"* ]]
  grep -Fxq '  HostName changed.invalid' "$HOME/.ssh/config"
  [ ! -e "$HOME/.gitconfig" ]
  [ -f "$CREATE_BASE/github/test/.ssh/id_ed25519" ]
}

@test "ws create recovery: every identity field must match the intended workspace" {
  for field in 'HostName wrong.invalid' 'User someone-else' \
    'IdentityFile /wrong/key' 'IdentitiesOnly no'; do
    cp "$HOME/ssh.before" "$HOME/.ssh/config"
    printf 'Host github-test\n  %s\n' "$field" >> "$HOME/.ssh/config"
    printf '  HostName github.com\n  User git\n  IdentityFile "%s/.ssh/id_ed25519"\n  IdentitiesOnly yes\n' \
      "$CREATE_BASE/github/test" >> "$HOME/.ssh/config"
    run run_create
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflicts with existing or ambiguous configuration"* ]]
    [ ! -e "$CREATE_BASE/github/test" ]
    [ ! -e "$HOME/keygen.calls" ]
  done
}

@test "ws create recovery: literal quotes backslashes percent and shell text stay data" {
  export CREATE_BASE="$HOME/"'work "quoted" \ 100% $(touch SHOULD_NOT_EXIST)'
  run run_create
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/SHOULD_NOT_EXIST" ]
  grep -Fxq "$CREATE_BASE/github/test/.ssh/id_ed25519" "$HOME/keygen.calls"
  run run_zsh '
    local -a reply=()
    _ws_create_ssh_alias_plan "$HOME/.ssh/config" github-test github.com \
      "$CREATE_BASE/github/test/.ssh/id_ed25519" || return
    [[ "${reply[1]}" == compatible ]]
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/ssh.calls" ]
}

@test "ws create recovery: unresolved key environment expansions are refused before creation" {
  export CREATE_BASE="$HOME/"'work-${UNREVIEWED_ENV}'
  run run_create
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported SSH environment syntax"* ]]
  assert_no_creation
}

@test "ws create recovery: hashes inside unquoted host and key tokens remain literal" {
  for field in "HostName github.com#unexpected" \
    "IdentityFile $CREATE_BASE/github/test/.ssh/id_ed25519#unexpected"; do
    cp "$HOME/ssh.before" "$HOME/.ssh/config"
    printf 'Host github-test\n  %s\n  HostName github.com\n  User git\n  IdentityFile "%s/.ssh/id_ed25519"\n  IdentitiesOnly yes\n' \
      "$field" "$CREATE_BASE/github/test" >> "$HOME/.ssh/config"
    run run_create
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflicts with existing or ambiguous configuration"* ]]
    [ ! -e "$CREATE_BASE/github/test" ]
    [ ! -e "$HOME/keygen.calls" ]
  done
}
