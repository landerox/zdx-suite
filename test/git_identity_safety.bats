#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export IDENTITY_REPO="$HOME/workspaces/github/work/repository"
  mkdir -p "$IDENTITY_REPO"
  git init -q -b main "$IDENTITY_REPO"
  export IDENTITY_REAL_GIT
  IDENTITY_REAL_GIT=$(command -v git)
}

teardown() {
  cleanup_sandbox
}

@test "git identity safety: an incomplete grouped SSH option refuses before configuration writes" {
  export IDENTITY_SECRET_COMMAND='TOKEN=CANARY_ASSIGN ssh -vi'
  git -C "$IDENTITY_REPO" config core.sshCommand "$IDENTITY_SECRET_COMMAND"
  cp "$IDENTITY_REPO/.git/config" "$HOME/reviewed.config"
  run run_zsh '
    cd "$IDENTITY_REPO" || return 80
    typeset -gA ZDX_GIT_IDENTITIES=(work "Name|Work User;Email|work@example.invalid;SshKey|$HOME/new_key")
    git-identity-switcher --switch work local \
      >"$HOME/switch.stdout" 2>"$HOME/switch.stderr"
  '
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/switch.stdout" ]
  cmp "$HOME/reviewed.config" "$IDENTITY_REPO/.git/config"
  grep -Fq 'Unable to parse configured SSH options; identity unchanged.' "$HOME/switch.stderr"
  run grep -F CANARY_ASSIGN "$HOME/switch.stderr"
  [ "$status" -eq 1 ]
}

install_identity_config_failure() {
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == config && "${2:-}" == --local \
  && "${3:-}" == --replace-all && "${4:-}" == commit.gpgSign \
  && ! -e "$HOME/identity-write-failed" ]]; then
  : > "$HOME/identity-write-failed"
  if [[ "${IDENTITY_PERSISTENT_LOCK:-0}" == 1 ]]; then
    : > "$PWD/.git/config.lock"
  else
    exit 23
  fi
fi
exec "$IDENTITY_REAL_GIT" "$@"
MOCK
  chmod -- 755 "$TEST_MOCK_BIN/git"
}

@test "git identity safety: failed rollback of previously absent identity keys never claims restoration" {
  install_identity_config_failure
  export IDENTITY_PERSISTENT_LOCK=1
  run run_zsh '
    cd "$IDENTITY_REPO" || return 80
    typeset -gA ZDX_GIT_IDENTITIES=(work "Name|Work User;Email|work@example.invalid")
    git-identity-switcher --switch work local >"$HOME/switch.stdout" 2>"$HOME/switch.stderr"
    local rc=$?
    (( rc == 1 )) || return 81
    [[ "$(command git config --local --get user.name)" == "Work User" ]] || return 82
    [[ "$(command git config --local --get user.email)" == work@example.invalid ]] || return 83
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/switch.stdout" ]
  grep -Fq 'Rollback was incomplete; inspect the local Git configuration.' "$HOME/switch.stderr"
  run grep -F 'Previous identity configuration restored.' "$HOME/switch.stderr"
  [ "$status" -eq 1 ]
}

@test "git identity safety: a recoverable write failure restores exact prior values and absence" {
  git -C "$IDENTITY_REPO" config user.name 'Previous Name'
  git -C "$IDENTITY_REPO" config user.email previous@example.invalid
  install_identity_config_failure
  run run_zsh '
    cd "$IDENTITY_REPO" || return 80
    typeset -gA ZDX_GIT_IDENTITIES=(work "Name|Work User;Email|work@example.invalid")
    git-identity-switcher --switch work local >"$HOME/switch.stdout" 2>"$HOME/switch.stderr"
    (( $? == 1 )) || return 81
    [[ "$(command git config --local --get user.name)" == "Previous Name" ]] || return 82
    [[ "$(command git config --local --get user.email)" == previous@example.invalid ]] || return 83
    command git config --local --get commit.gpgSign >/dev/null && return 84
    return 0
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/switch.stdout" ]
  grep -Fq 'Previous identity configuration restored.' "$HOME/switch.stderr"
  run grep -F 'Rollback was incomplete' "$HOME/switch.stderr"
  [ "$status" -eq 1 ]
}

@test "git identity safety: status and switch plan hide SSH arguments and assignment secrets without changing them" {
  export IDENTITY_SECRET_COMMAND='TOKEN=CANARY_ASSIGN ssh -o ProxyCommand="corp-proxy --token=CANARY_PROXY %h %p" -o IdentityAgent=CANARY_AGENT'
  git -C "$IDENTITY_REPO" config core.sshCommand "$IDENTITY_SECRET_COMMAND"
  run run_zsh '
    cd "$IDENTITY_REPO" || return 80
    typeset -gA ZDX_GIT_IDENTITIES=(work "Name|Work User;Email|work@example.invalid")
    git-identity-switcher --status >"$HOME/status.stdout" 2>"$HOME/status.stderr" || return 81
    git-identity-switcher --switch work local >"$HOME/plan.stdout" 2>"$HOME/plan.stderr" || return 82
    [[ "$(command git config --local --get core.sshCommand)" == "$IDENTITY_SECRET_COMMAND" ]] || return 83
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/status.stdout" ]
  [ ! -s "$HOME/plan.stdout" ]
  run grep -F 'CANARY_' "$HOME/status.stderr" "$HOME/plan.stderr"
  [ "$status" -eq 1 ]
  grep -Fq 'ssh' "$HOME/status.stderr"
  grep -Fq 'ssh' "$HOME/plan.stderr"
  grep -Fq '********' "$HOME/status.stderr"
  grep -Fq '********' "$HOME/plan.stderr"
}

identity_grouped_switch_case() {
  export IDENTITY_OPTION="$1"
  run run_zsh '
    cd "$IDENTITY_REPO" || return 80
    local prior="ssh $IDENTITY_OPTION"
    prior="${prior//OLD/$HOME/old_key}"
    command git config core.sshCommand "$prior" || return 81
    typeset -gA ZDX_GIT_IDENTITIES=(work "Name|Work User;Email|work@example.invalid;SshKey|$HOME/new_key")
    git-identity-switcher --switch work local >"$HOME/switch.stdout" 2>"$HOME/switch.stderr" || return 82
    local actual=""
    actual=$(command git config --local --get core.sshCommand) || return 83
    [[ "$actual" != *old_key* ]] || { print -r -- "$actual"; return 84; }
    [[ "$actual" == *new_key* ]] || return 85
    [[ "$actual" == *-v* || "$actual" == *-4* ]] || return 86
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "git identity safety: switching replaces the key selected by grouped -vi" {
  identity_grouped_switch_case '-vi OLD'
}

@test "git identity safety: switching replaces the attached key selected by grouped -4i" {
  identity_grouped_switch_case '-4iOLD'
}

@test "git identity safety: switching replaces grouped -voIdentityFile and keeps verbosity" {
  identity_grouped_switch_case '-voIdentityFile=OLD'
}

@test "git identity safety: grouped keys are mismatches for keyless and differently keyed profiles" {
  run run_zsh '
    cd "$IDENTITY_REPO" || return 80
    command git config user.email work@example.invalid || return 81
    command git config commit.gpgSign false || return 82
    typeset -gA ZDX_GIT_IDENTITIES=(work "Name|Work User;Email|work@example.invalid")
    local option="" rc=0 failures=0
    for option in "-vi $HOME/old_key" "-4i$HOME/old_key" "-voIdentityFile=$HOME/old_key"; do
      command git config core.sshCommand "ssh $option" || return 83
      git-identity-check >"$HOME/check.stdout" 2>"$HOME/check.stderr"
      rc=$?
      (( rc == 1 )) || (( ++failures ))
      ZDX_GIT_IDENTITIES[work]="Name|Work User;Email|work@example.invalid;SshKey|$HOME/new_key"
      git-identity-check >"$HOME/keyed.stdout" 2>"$HOME/keyed.stderr"
      rc=$?
      (( rc == 1 )) || (( ++failures ))
      ZDX_GIT_IDENTITIES[work]="Name|Work User;Email|work@example.invalid"
    done
    (( failures == 0 )) || { print -r -- "missed=$failures"; return 84; }
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [ ! -s "$HOME/check.stdout" ]
  [ ! -s "$HOME/keyed.stdout" ]
  grep -Fq 'selects an SSH key, but the profile has none' "$HOME/check.stderr"
  grep -Fq 'selects a different SSH key than the profile' "$HOME/keyed.stderr"
  run grep -F 'old_key' "$HOME/check.stderr" "$HOME/keyed.stderr"
  [ "$status" -eq 1 ]
}

@test "git identity safety: other argument-taking options consume their values before key parsing" {
  run run_zsh '
    local -a reply=()
    _git_identity_ssh_parts "ssh -vF -iNOT_A_KEY -p 2222 -o IdentityAgent=agent"
    [[ "${reply[2]}" == "ssh -vF -iNOT_A_KEY -p 2222 -o IdentityAgent=agent" ]] || return 80
    [[ "${reply[3]}" == no ]] || return 81
    local -a _git_identity_ssh_keys=()
    _git_identity_ssh_selected_keys "ssh -vF -iNOT_A_KEY -p 2222"
    (( ${#_git_identity_ssh_keys} == 0 )) || return 82
  '
  [ "$status" -eq 0 ]
}
