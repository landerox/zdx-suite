#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

# git-identity-check and the opt-in identity guard on directory changes. Each
# test builds repositories below a sandbox $WS_BASE_DIR/<platform>/<identity>.

setup() {
  load test_helper
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
}

teardown() {
  cleanup_sandbox
}

# Prints Zsh that defines two profiles and creates REPO_DIR as a repository
# below the "personal" identity directory.
identity_repo() {
  cat <<'ZSH'

    typeset -gA ZDX_GIT_IDENTITIES=(
      personal 'Name|Jane Doe;Email|jane@personal.example;GpgKey|~/.ssh/signing.pub;SshKey|~/.ssh/id_personal'
      work 'Name|Jane Doe;Email|jane@work.example'
    )
    REPO_DIR="$WS_BASE_DIR/github/personal/project"
    mkdir -p "$REPO_DIR" || return 81
    command git init -q -b main "$REPO_DIR" || return 82
    cd "$REPO_DIR" || return 83
ZSH
}

show_failure() {
  printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
  cat "$HOME"/*.stderr >&2 2>/dev/null || true
}

@test "git identity check: a repository set up by its profile matches" {
  run run_zsh "$(identity_repo)"'
    git-identity-switcher --switch personal local >/dev/null 2>&1 || return 10
    git-identity-check >"$HOME/match.stdout" 2>"$HOME/match.stderr" || return 11
    git-identity-check --quiet >"$HOME/quiet.stdout" 2>"$HOME/quiet.stderr" ||
      return 12
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/match.stdout" ]
  [ ! -s "$HOME/quiet.stdout" ]
  [ ! -s "$HOME/quiet.stderr" ]
  grep -Fq "Git Identity Check" "$HOME/match.stderr"
  grep -Eq "Workspace: +github/personal" "$HOME/match.stderr"
  grep -Eq "Profile: +personal" "$HOME/match.stderr"
  grep -Fq "The repository identity matches profile personal." "$HOME/match.stderr"
}

@test "git identity check: mismatches name each field and the fix without key material or changes" {
  run run_zsh "$(identity_repo)"'
    git-identity-switcher --switch personal local >/dev/null 2>&1 || return 10
    command git config user.email jane@work.example
    command git config user.signingkey ~/.ssh/other-signing.pub
    command git config gpg.format openpgp
    command git config commit.gpgSign false
    command git config core.sshCommand "ssh -o IdentityFile=~/.ssh/id_other"
    local before=""
    before=$(command git config --list --show-origin) || return 11

    git-identity-check >"$HOME/text.stdout" 2>"$HOME/text.stderr"
    local -i text_rc=$?
    git-identity-check --quiet >"$HOME/quiet.stdout" 2>"$HOME/quiet.stderr"
    local -i quiet_rc=$?
    [[ "$(command git config --list --show-origin)" == "$before" ]] || return 12
    print -r -- "$text_rc:$quiet_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:1" ]
  [ ! -s "$HOME/text.stdout" ]
  [ ! -s "$HOME/quiet.stdout" ]
  grep -Fq "user.email is jane@work.example; the profile expects jane@personal.example." \
    "$HOME/text.stderr"
  grep -Fq "user.signingkey names a different key than the profile." "$HOME/text.stderr"
  grep -Fq "gpg.format is openpgp; the profile expects ssh." "$HOME/text.stderr"
  grep -Fq "commit.gpgSign is false; the profile signs every commit." "$HOME/text.stderr"
  grep -Fq "core.sshCommand selects a different SSH key than the profile." \
    "$HOME/text.stderr"
  grep -Fq "The repository identity differs from profile personal in 5 fields." \
    "$HOME/text.stderr"
  grep -Fq "Fix: git-identity-switcher --switch personal local" "$HOME/text.stderr"
  [ "$(wc -l < "$HOME/quiet.stderr")" -eq 2 ]
  grep -Fq "Git identity mismatch in project for profile personal: user.email, user.signingkey, gpg.format, commit.gpgSign, core.sshCommand" \
    "$HOME/quiet.stderr"
  grep -Fq "Fix: git-identity-switcher --switch personal local" "$HOME/quiet.stderr"
  local stream
  for stream in "$HOME/text.stderr" "$HOME/quiet.stderr"; do
    ! grep -Eq "\.pub|id_personal|id_other|\.ssh/" "$stream" || false
  done
}

@test "git identity check: a profile without keys refuses signing and SSH key selection" {
  run run_zsh "$(identity_repo)"'
    local work_dir="$WS_BASE_DIR/gitlab/work/app"
    mkdir -p "$work_dir" && command git init -q -b main "$work_dir" || return 10
    cd "$work_dir" || return 11
    git-identity-switcher --switch work local >/dev/null 2>&1 || return 12
    git-identity-check >"$HOME/clean.stdout" 2>"$HOME/clean.stderr" || return 13
    command git config commit.gpgSign yes
    command git config core.sshCommand "ssh -i ~/.ssh/id_work -o IdentitiesOnly=yes"
    git-identity-check >"$HOME/keys.stdout" 2>"$HOME/keys.stderr"
    print -r -- "$?"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  grep -Fq "matches profile work." "$HOME/clean.stderr"
  grep -Fq "commit.gpgSign is true; the profile has no signing key." "$HOME/keys.stderr"
  grep -Fq "core.sshCommand selects an SSH key, but the profile has none." \
    "$HOME/keys.stderr"
  ! grep -Fq "id_work" "$HOME/keys.stderr" || false
}

@test "git identity check: no profile and repositories outside the layout are not applicable" {
  run run_zsh "$(identity_repo)"'
    local -a codes=()
    local unknown_dir="$WS_BASE_DIR/github/unknown/repo"
    mkdir -p "$unknown_dir" && command git init -q "$unknown_dir" || return 10
    cd "$unknown_dir" || return 11
    git-identity-check >"$HOME/none.stdout" 2>"$HOME/none.stderr"
    codes+=($?)
    git-identity-check --quiet >>"$HOME/none.stdout" 2>"$HOME/none-quiet.stderr"
    codes+=($?)

    command git init -q "$HOME/elsewhere" || return 12
    cd "$HOME/elsewhere" || return 13
    git-identity-check >"$HOME/outside.stdout" 2>"$HOME/outside.stderr"
    codes+=($?)

    # The identity directory itself is not a repository location.
    command git init -q "$WS_BASE_DIR/github/personal" || return 14
    cd "$WS_BASE_DIR/github/personal" || return 15
    git-identity-check >>"$HOME/outside.stdout" 2>"$HOME/identity-dir.stderr"
    codes+=($?)

    unset ZDX_GIT_IDENTITIES
    cd "$REPO_DIR" || return 16
    git-identity-check >>"$HOME/none.stdout" 2>"$HOME/unset.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "0,0,0,0,0" ]
  [ ! -s "$HOME/none.stdout" ]
  [ ! -s "$HOME/outside.stdout" ]
  [ ! -s "$HOME/none-quiet.stderr" ]
  grep -Fq "Not applicable: no profile named unknown in ZDX_GIT_IDENTITIES." \
    "$HOME/none.stderr"
  grep -Fq 'Not applicable: the repository is not below $WS_BASE_DIR/<platform>/<identity>.' \
    "$HOME/outside.stderr"
  grep -Fq "Not applicable" "$HOME/identity-dir.stderr"
  grep -Fq "Not applicable: no profile named personal in ZDX_GIT_IDENTITIES." \
    "$HOME/unset.stderr"
}

@test "git identity check: SSH keys match through IdentityFile options and ssh.exe Windows paths" {
  cat > "$TEST_MOCK_BIN/wslpath" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -w && "$2" == "$HOME/.ssh/id_personal" ]] || exit 1
printf 'C:\\Users\\jane\\.ssh\\id_personal\r\n'
MOCK
  chmod +x "$TEST_MOCK_BIN/wslpath"

  run run_zsh "$(identity_repo)"'
    git-identity-switcher --switch personal local >/dev/null 2>&1 || return 10
    command git config core.sshCommand \
      "ssh -o \"IdentityFile ~/.ssh/id_personal\" -o IdentitiesOnly=yes"
    git-identity-check >"$HOME/option.stdout" 2>"$HOME/option.stderr" || return 11
    command git config core.sshCommand \
      "ssh.exe -i '\''C:\\Users\\jane\\.ssh\\id_personal'\'' -o IdentitiesOnly=yes"
    git-identity-check >"$HOME/windows.stdout" 2>"$HOME/windows.stderr" || return 12
    command git config core.sshCommand "ssh -i ~/.ssh/id_personal -i ~/.ssh/id_other"
    git-identity-check >"$HOME/two.stdout" 2>"$HOME/two.stderr"
    print -r -- "$?"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  grep -Fq "matches profile personal." "$HOME/option.stderr"
  grep -Fq "matches profile personal." "$HOME/windows.stderr"
  grep -Fq "core.sshCommand selects 2 SSH keys; the profile uses one." "$HOME/two.stderr"
}

@test "git identity check: grammar errors return 2 and other contexts fail before any check" {
  run run_zsh "$(identity_repo)"'
    local -a codes=()
    git-identity-check --json --quiet >"$HOME/usage.stdout" 2>"$HOME/usage.stderr"
    codes+=($?)
    git-identity-check --quiet --quiet >>"$HOME/usage.stdout" 2>>"$HOME/usage.stderr"
    codes+=($?)
    git-identity-check local >>"$HOME/usage.stdout" 2>>"$HOME/usage.stderr"
    codes+=($?)
    cd "$HOME" || return 10
    git-identity-check >"$HOME/norepo.stdout" 2>"$HOME/norepo.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "2,2,2,1" ]
  [ ! -s "$HOME/usage.stdout" ]
  [ ! -s "$HOME/norepo.stdout" ]
  grep -Fq -- "--json and --quiet cannot be combined." "$HOME/usage.stderr"
  grep -Fq "Duplicate option: --quiet" "$HOME/usage.stderr"
  grep -Fq "Unknown argument for git-identity-check: local" "$HOME/usage.stderr"
  grep -Fq "Not inside a Git worktree." "$HOME/norepo.stderr"
}

# --- Identity guard on directory changes ----------------------------------------

# Prints Zsh that creates a mismatching, a matching, and an outside repository
# for the guard tests. Run in a shell that loaded the plugin wrapper.
guard_fixture() {
  cat <<'ZSH'

    typeset -gA ZDX_GIT_IDENTITIES=(
      personal 'Name|Jane Doe;Email|jane@personal.example'
    )
    local ws="$WS_BASE_DIR/github/personal"
    mkdir -p "$ws/wrong/sub" "$ws/right" "$ws/other" "$HOME/outside" || exit 81
    command git init -q "$ws/wrong" && command git init -q "$ws/right" \
      && command git init -q "$ws/other" && command git init -q "$HOME/outside" \
      || exit 82
    command git -C "$ws/wrong" config user.email jane@work.example
    command git -C "$ws/other" config user.email other@work.example
    command git -C "$ws/right" config user.email jane@personal.example
    command git -C "$ws/right" config commit.gpgSign false
ZSH
}

@test "git identity guard: it is off by default and in non-interactive shells" {
  run zsh -f -i -c "
    export HOME='$HOME' PATH='$PATH' ZDX_KEYBINDINGS=0
    source '$TEST_SUITE_ROOT/zdx-suite.plugin.zsh' || exit 1
    (( \${chpwd_functions[(Ie)_zdx_git_identity_guard]:-0} == 0 )) || exit 2
    (( ! \${+functions[_zdx_git_identity_guard]} )) || exit 3
  " </dev/null
  [ "$status" -eq 0 ]

  run zsh -f -c "
    export HOME='$HOME' PATH='$PATH' ZDX_KEYBINDINGS=0 ZDX_GIT_IDENTITY_GUARD=1
    source '$TEST_SUITE_ROOT/zdx-suite.plugin.zsh' || exit 1
    (( \${chpwd_functions[(Ie)_zdx_git_identity_guard]:-0} == 0 )) || exit 2
  " </dev/null
  [ "$status" -eq 0 ]
}

@test "git identity guard: it warns once per repository and stays silent elsewhere" {
  run zsh -f -i -c "
    export HOME='$HOME' PATH='$PATH' ZDX_KEYBINDINGS=0 ZDX_GIT_IDENTITY_GUARD=1
    export WS_BASE_DIR='$HOME/workspaces'
    source '$TEST_SUITE_ROOT/zdx-suite.plugin.zsh' || exit 1
    (( \${chpwd_functions[(Ie)_zdx_git_identity_guard]} )) || exit 2
    $(guard_fixture)
    local ws=\"\$WS_BASE_DIR/github/personal\"
    {
      cd \"\$HOME/outside\" || exit 3
      cd \"\$WS_BASE_DIR/github\" || exit 4
      ( cd \"\$ws/wrong\" ) || exit 5
      cd \"\$ws/right\" || exit 6
      cd \"\$ws/wrong\" || exit 7
      cd \"\$ws/wrong/sub\" || exit 8
      cd \"\$ws/right\" || exit 9
      cd \"\$ws/wrong\" || exit 10
      cd \"\$ws/other\" || exit 11
    } >\"\$HOME/guard.stdout\" 2>\"\$HOME/guard.stderr\"
    print -r -- \"cd-status:\$?\"
  " </dev/null

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME/guard.stderr" >&2; false; }
  [[ "$output" == *"cd-status:0"* ]]
  [ ! -s "$HOME/guard.stdout" ]
  [ "$(grep -c "Git identity mismatch" "$HOME/guard.stderr")" -eq 2 ]
  grep -Fq "Git identity mismatch in wrong for profile personal: user.email" \
    "$HOME/guard.stderr"
  grep -Fq "Git identity mismatch in other for profile personal: user.email" \
    "$HOME/guard.stderr"
  [ "$(grep -c "Fix: git-identity-switcher --switch personal local" "$HOME/guard.stderr")" -eq 2 ]
  ! grep -Fq "right" "$HOME/guard.stderr" || false
  ! grep -Fq "completed in" "$HOME/guard.stderr" || false
}

@test "git identity guard: a lazy shell loads the Git suite only when a repository needs a check" {
  run zsh -f -i -c "
    unset TEST_TEMP_DIR BATS_TEST_DIRNAME
    export HOME='$HOME' PATH='$PATH' ZDX_KEYBINDINGS=0 ZDX_GIT_IDENTITY_GUARD=1
    export WS_BASE_DIR='$HOME/workspaces' ZDX_LAZY_LOAD=1
    source '$TEST_SUITE_ROOT/zdx-suite.plugin.zsh' || exit 1
    $(guard_fixture)
    cd \"\$HOME/outside\" 2>\"\$HOME/outside.stderr\" || exit 2
    (( ! \${+functions[_git_dispatch]} )) || exit 3
    cd \"\$WS_BASE_DIR/github/personal/wrong\" 2>\"\$HOME/lazy.stderr\" || exit 4
    (( \${+functions[git-identity-check]} )) || exit 5
  " </dev/null

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME"/*.stderr >&2; false; }
  [ ! -s "$HOME/outside.stderr" ]
  grep -Fq "Git identity mismatch in wrong for profile personal: user.email" \
    "$HOME/lazy.stderr"
  ! grep -Fq "Usage:" "$HOME/lazy.stderr" || false
}
