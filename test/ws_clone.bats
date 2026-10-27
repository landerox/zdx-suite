#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REAL_GIT=$(command -v git)
  export REAL_GIT
  load test_helper
  WS="$HOME/workspaces"
  export WS
  mkdir -p "$WS/github/personal" "$WS/github/work"
  chmod -- 755 "$WS" "$WS/github" "$WS/github/personal" "$WS/github/work"
  export MOCK_GIT_LOG="$TEST_TEMP_DIR/git.log"
  export MOCK_GIT_MENU_LOG="$TEST_TEMP_DIR/git-menu.log"
  : > "$MOCK_GIT_LOG"
  install_clone_mock
}

teardown() {
  cleanup_sandbox
}

# git clone is mocked: the harness has no test-only transport, and ws-clone
# refuses local paths and file:// URLs. Every other command runs real Git.
install_clone_mock() {
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == clone ]]; then
  {
    printf 'clone'
    printf ' <%s>' "${@:2}"
    printf ' GIT_DIR=%s\n' "${GIT_DIR:-unset}"
  } >> "$MOCK_GIT_LOG"
  target="${!#}"
  case "${MOCK_CLONE:-ok}" in
    ok)
      "$REAL_GIT" init -q "$target" || exit 1
      "$REAL_GIT" -C "$target" -c user.name=T -c user.email=t@example.invalid \
        commit -q --allow-empty -m cloned || exit 1
      ;;
    fail)
      mkdir -p "$target/.git/objects" && printf 'partial\n' > "$target/partial"
      printf 'fatal: repository not found\n' >&2
      exit 128
      ;;
    interrupt)
      # Ctrl-C reaches the foreground clone and the shell that waits for it.
      mkdir -p "$target/.git/objects" && printf 'partial\n' > "$target/partial"
      kill -INT "$PPID"
      exit 130
      ;;
    terminal-interrupt)
      # Ctrl-C at a terminal: the terminal driver sends SIGINT to its
      # foreground process group, which includes this clone.
      mkdir -p "$target/.git/objects" && printf 'partial\n' > "$target/partial"
      ps_program=/bin/ps
      [[ -x "$ps_program" ]] || ps_program=/usr/bin/ps
      tpgid=$("$ps_program" -o tpgid= -p "$$" | tr -d ' ')
      [[ "$tpgid" =~ ^[1-9][0-9]*$ ]] || exit 99
      printf 'interrupt tpgid=%s\n' "$tpgid" >> "$MOCK_GIT_LOG"
      kill -INT -- "-$tpgid"
      sleep 5
      exit 0
      ;;
  esac
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/git"
}

# An ssh that maps the github-personal alias to github.com.
install_alias_ssh() {
  cat > "$TEST_MOCK_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -G ]]; then
  shift
  [[ "${1:-}" == -- ]] && shift
  case "${1:-}" in
    github-personal) printf 'user git\nhostname github.com\nport 22\n' ;;
    *) printf 'user git\nhostname %s\nport 22\n' "${1:-}" ;;
  esac
  exit 0
fi
printf 'mock ssh denied: %s\n' "$*" >&2
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/ssh"
}

clone_count() {
  grep -c '^clone' "$MOCK_GIT_LOG" || true
}

@test "ws clone: unsafe and unsupported URLs are refused before any clone" {
  local url
  for url in \
    'ext::sh -c touch% /tmp/pwned' \
    'ext::sh' \
    'file:///etc' \
    '/srv/git/repo.git' \
    './repo' \
    '../repo' \
    '~/repo' \
    '--upload-pack=touch /tmp/pwned' \
    '-oProxyCommand=sh' \
    'https://user:secret@github.com/acme/app.git' \
    'https://token@github.com/acme/app.git' \
    'ssh://git:secret@github.com/acme/app.git' \
    'git:secret@github.com:acme/app.git' \
    'http://github.com/acme/app.git' \
    'git://github.com/acme/app.git' \
    'https://github.com/acme/app.git?ref=x' \
    'https://github.com/acme/app.git#frag' \
    'https://github.com/../app' \
    'https://github.com/acme/-app' \
    'https://-github.com/acme/app' \
    'https://github.com:0/acme/app' \
    'github.com:acme/app.git' \
    'https://github.com/' \
    $'https://github.com/acme/app\nx'; do
    run run_zsh "ws-clone ${url@Q} --yes"
    [ "$status" -eq 2 ]
  done
  [ "$(clone_count)" -eq 0 ]
  [ ! -e "$WS/github/personal/app" ]

  # A URL typed at the prompt bypasses the option parser, not validation.
  run run_zsh '
    local url=""
    for url in -oProxyCommand=sh --upload-pack=x "" "ext::sh -c x"; do
      _ws_clone_parse_url "$url" 2>/dev/null
      (( $? == 2 )) || return 1
    done
    _ws_clone_parse_url git@github.com:acme/app.git || return 2
    print -r -- "${(j:|:)reply}"
    _ws_clone_parse_url ssh://git@gitlab.com:2222/group/sub/app.git || return 3
    print -r -- "${(j:|:)reply}"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "scp|git|github.com||acme/app.git" ]
  [ "${lines[1]}" = "ssh|git|gitlab.com|2222|group/sub/app.git" ]
}

@test "ws clone: the dry run prints the exact plan and writes nothing" {
  run run_zsh '
    typeset -gA ZDX_GIT_IDENTITIES=(personal "Name|Jane Doe;Email|jane@example.com")
    NO_COLOR=1 ws-clone https://github.com/acme/app.git --identity personal --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"════ Workspace Clone Plan ════"* ]]
  [[ "$output" == *"Repository:        app"* ]]
  [[ "$output" == *"URL:               https://github.com/acme/app.git"* ]]
  [[ "$output" == *"Workspace:         github/personal (option)"* ]]
  [[ "$output" == *"Destination:       ~/workspaces/github/personal/app"* ]]
  [[ "$output" == *"Identity profile:  git-menu git-identity-switcher --switch personal local"* ]]
  [[ "$output" == *"⚠ git clone downloads github.com content that ZDX does not review."* ]]
  [[ "$output" == *"Dry run: 1 clone planned; nothing was cloned."* ]]
  [[ "$output" != *"SSH alias"* ]]
  [ "$(clone_count)" -eq 0 ]
  [ ! -e "$WS/github/personal/app" ]
  [ -z "$(ls -A "$WS/github/personal")" ]
}

@test "ws clone: a new workspace is planned, created, and cloned with --yes" {
  run run_zsh '
    NO_COLOR=1 ws-clone ssh://git@gitlab.com:2222/group/sub/tool.git \
      --identity team --name tool-fork --yes 2>"$HOME/stderr"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "$WS/gitlab/team/tool-fork" ]
  grep -Fq 'New directory:     ~/workspaces/gitlab' "$HOME/stderr"
  grep -Fq 'New directory:     ~/workspaces/gitlab/team' "$HOME/stderr"
  grep -Fq '$ git clone -- ssh://git@gitlab.com:2222/group/sub/tool.git ~/workspaces/gitlab/team/.ws-clone.' "$HOME/stderr"
  grep -Fq '✔ Cloned tool-fork into ~/workspaces/gitlab/team/tool-fork.' "$HOME/stderr"
  [ -d "$WS/gitlab/team/tool-fork/.git" ]
  [ "$(file_mode "$WS/gitlab")" = 755 ]
  [ "$(file_mode "$WS/gitlab/team")" = 755 ]
  [ -z "$(ls -A "$WS/gitlab/team" | grep -v '^tool-fork$')" ]
  grep -Fq 'clone <--> <ssh://git@gitlab.com:2222/group/sub/tool.git> <'"$WS"'/gitlab/team/.ws-clone.' "$MOCK_GIT_LOG"
}

@test "ws clone: an existing destination is refused before cloning" {
  mkdir -p "$WS/github/personal/app"
  run run_zsh 'ws-clone https://github.com/acme/app --identity personal --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"The destination already exists: ~/workspaces/github/personal/app"* ]]
  [ "$(clone_count)" -eq 0 ]

  rmdir "$WS/github/personal/app"
  ln -s "$HOME" "$WS/github/personal/app"
  run run_zsh 'ws-clone https://github.com/acme/app --identity personal --yes'
  [ "$status" -eq 1 ]
  [ "$(clone_count)" -eq 0 ]
}

@test "ws clone: a failed clone removes its staging directory and publishes nothing" {
  export MOCK_CLONE=fail
  run run_zsh 'NO_COLOR=1 ws-clone git@github.com:acme/app.git --identity personal --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"git clone failed (status 128); nothing was published."* ]]
  [ "$(clone_count)" -eq 1 ]
  [ ! -e "$WS/github/personal/app" ]
  [ -z "$(ls -A "$WS/github/personal")" ]

  export MOCK_CLONE=interrupt
  run run_zsh 'ws-clone git@github.com:acme/app.git --identity personal --yes'
  [ "$status" -eq 130 ]
  [[ "$output" == *"git clone was interrupted; nothing was published."* ]]
  [ "$(clone_count)" -eq 2 ]
  [ ! -e "$WS/github/personal/app" ]
  [ -z "$(ls -A "$WS/github/personal")" ]
}

@test "ws clone: Ctrl-C at a terminal ends with 130, publishes nothing, and applies no profile" {
  has_util_linux_script || skip "util-linux script is unavailable"
  export MOCK_CLONE=terminal-interrupt
  export WS_PTY_LOG="$TEST_TEMP_DIR/pty.log"
  export WS_PTY_CODE='
    emulate -R zsh
    # emulate -R keeps job control; the -fic case depends on it.
    [[ "$WS_PTY_MODE" == -fc || -o monitor ]] || exit 97
    source "$TEST_SUITE_ROOT/functions/ws-menu.zsh" || exit 98
    typeset -gA ZDX_GIT_IDENTITIES=(personal "Name|Jane Doe;Email|jane@example.com")
    git-menu() { print -r -- "git-menu:$*" >> "$MOCK_GIT_MENU_LOG"; }
    print -r -- "shell pgid=$$" >> "$WS_PTY_LOG"
    NO_COLOR=1 ws-clone https://github.com/acme/app.git --identity personal --yes
    print -r -- "ws-clone status=$?" >> "$WS_PTY_LOG"
  '
  # script runs the command through $SHELL -c; exec makes Zsh the session
  # leader. Without job control (-fc) the shell shares the foreground group,
  # so the signal also reaches ws-clone and runs its INT trap; with job
  # control (-fic) the clone runs in its own foreground group.
  export SHELL=/bin/sh
  local mode shell_group signaled_group violations=""
  for mode in -fc -fic; do
    : > "$WS_PTY_LOG"
    : > "$MOCK_GIT_LOG"
    : > "$MOCK_GIT_MENU_LOG"
    export WS_PTY_MODE="$mode"
    run script -qefc 'exec zsh $WS_PTY_MODE "$WS_PTY_CODE"' /dev/null
    printf '%s: status=%s\n%s\n' "$mode" "$status" "${output//$'\r'/}" >&2
    sed "s/^/$mode: /" "$MOCK_GIT_LOG" "$WS_PTY_LOG" >&2
    find "$WS/github/personal" -mindepth 1 -maxdepth 1 \
      | sed "s|^|$mode: left: |" >&2
    grep -q '^clone ' "$MOCK_GIT_LOG" || violations+=" $mode:no-clone"
    shell_group=$(sed -n 's/^shell pgid=//p' "$WS_PTY_LOG")
    signaled_group=$(sed -n 's/^interrupt tpgid=//p' "$MOCK_GIT_LOG")
    if [[ -z "$signaled_group" || -z "$shell_group" ]]; then
      violations+=" $mode:no-signal"
    elif [[ "$mode" == -fc && "$signaled_group" != "$shell_group" ]] \
      || [[ "$mode" == -fic && "$signaled_group" == "$shell_group" ]]; then
      violations+=" $mode:unexpected-group"
    fi
    grep -Fqx 'ws-clone status=130' "$WS_PTY_LOG" || violations+=" $mode:status"
    [ ! -e "$WS/github/personal/app" ] || violations+=" $mode:published"
    [ -z "$(find "$WS/github/personal" -mindepth 1 -maxdepth 1 ! -name app)" ] \
      || violations+=" $mode:staging-left"
    [ ! -s "$MOCK_GIT_MENU_LOG" ] || violations+=" $mode:profile-applied"
    rm -rf -- "$WS/github/personal/app" "$WS/github/personal"/.ws-clone.*
  done
  printf 'violations:%s\n' "$violations" >&2
  [ -z "$violations" ]
}

@test "ws clone: the SSH alias of the workspace replaces the host when it resolves" {
  install_alias_ssh
  run run_zsh 'NO_COLOR=1 ws-clone git@github.com:acme/app.git --identity personal --yes 2>"$HOME/stderr"'
  [ "$status" -eq 0 ]
  grep -Fq 'URL:               git@github-personal:acme/app.git' "$HOME/stderr"
  grep -Fq 'Requested URL:     git@github.com:acme/app.git' "$HOME/stderr"
  grep -Fq 'SSH alias:         github-personal (HostName github.com)' "$HOME/stderr"
  grep -Fq 'clone <--> <git@github-personal:acme/app.git>' "$MOCK_GIT_LOG"

  run run_zsh 'NO_COLOR=1 ws-clone ssh://git@github.com/acme/other.git --identity work --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"URL:               ssh://git@github.com/acme/other.git"* ]]
  [[ "$output" == *"SSH alias:         none (github-work does not resolve to github.com)"* ]]

  run run_zsh 'NO_COLOR=1 ws-clone ssh://git@github.com:22/acme/third.git --identity personal --dry-run'
  [[ "$output" == *"URL:               ssh://git@github-personal:22/acme/third.git"* ]]

  # HTTPS URLs authenticate through credential helpers and keep their host.
  run run_zsh 'NO_COLOR=1 ws-clone https://github.com/acme/web.git --identity personal --dry-run'
  [[ "$output" == *"URL:               https://github.com/acme/web.git"* ]]
  [[ "$output" != *"SSH alias"* ]]
}

@test "ws clone: an alias host in the URL selects its workspace" {
  run run_zsh 'NO_COLOR=1 ws-clone git@github-work:acme/app.git --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workspace:         github/work (inferred)"* ]]
  [[ "$output" == *"SSH alias:         github-work (used by the URL)"* ]]
  [[ "$output" == *"Destination:       ~/workspaces/github/work/app"* ]]
}

@test "ws clone: the identity profile is applied through git-menu inside the clone" {
  run run_zsh '
    typeset -gA ZDX_GIT_IDENTITIES=(personal "Name|Jane Doe;Email|jane@example.com")
    git-menu() {
      print -r -- "git-menu|$PWD|$#|${(j:|:)@}" >> "$MOCK_GIT_MENU_LOG"
    }
    builtin cd -- "$HOME" || return
    ws-clone https://github.com/acme/app.git --identity personal --yes \
      2>/dev/null || return
    print -r -- "pwd:$PWD"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_GIT_MENU_LOG")" = "git-menu|$WS/github/personal/app|4|git-identity-switcher|--switch|personal|local" ]
  [[ "$output" == *"pwd:$HOME"* ]]

  : > "$MOCK_GIT_MENU_LOG"
  run run_zsh '
    typeset -gA ZDX_GIT_IDENTITIES=(personal "Name|Jane Doe;Email|jane@example.com")
    git-menu() { return 1; }
    NO_COLOR=1 ws-clone https://github.com/acme/second.git --identity personal --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"The identity profile was not applied (status 1); the clone is kept."* ]]
  [ -d "$WS/github/personal/second/.git" ]

  run run_zsh '
    git-menu() { print -r -- UNEXPECTED >> "$MOCK_GIT_MENU_LOG"; }
    NO_COLOR=1 ws-clone https://github.com/acme/third.git --identity work --yes
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Identity profile:  none (ZDX_GIT_IDENTITIES has no work)"* ]]
  [ ! -s "$MOCK_GIT_MENU_LOG" ]
}

@test "ws clone: real identity delegation configures the new repository" {
  run run_zsh '
    typeset -gA ZDX_GIT_IDENTITIES=(personal "Name|Jane Doe;Email|jane@example.com")
    ws-clone https://github.com/acme/app.git --identity personal --yes >/dev/null 2>&1 \
      || return
    command git -C "$WS/github/personal/app" config --local --get user.email
  '
  [ "$status" -eq 0 ]
  [ "$output" = "jane@example.com" ]
}

@test "ws clone: an inherited GIT_DIR never redirects the identity profile" {
  # vcsh enter, yadm enter, a Git hook, and git rebase --exec export GIT_DIR.
  # The profile belongs in the new clone, not in the repository it names.
  local other="$TEST_TEMP_DIR/dotfiles"
  "$REAL_GIT" init -q "$other"
  "$REAL_GIT" -C "$other" config --local user.email owner@dotfiles.example
  export WS_OTHER_GIT_DIR="$other/.git"
  run run_zsh '
    typeset -gA ZDX_GIT_IDENTITIES=(personal "Name|Jane Doe;Email|jane@example.com")
    export GIT_DIR="$WS_OTHER_GIT_DIR"
    ws-clone https://github.com/acme/app.git --identity personal --yes \
      2>"$HOME/clone.stderr"
  '
  sed 's/^/stderr: /' "$HOME/clone.stderr" >&2
  [ "$status" -eq 0 ]
  [ "$output" = "$WS/github/personal/app" ]
  grep -Fq 'GIT_DIR=unset' "$MOCK_GIT_LOG"
  local clone_email="" other_email=""
  clone_email=$("$REAL_GIT" -C "$WS/github/personal/app" config --local --get user.email || true)
  other_email=$("$REAL_GIT" -C "$other" config --local --get user.email || true)
  printf 'clone=%s other=%s\n' "$clone_email" "$other_email" >&2
  [ "$clone_email" = jane@example.com ]
  [ "$other_email" = owner@dotfiles.example ]
  # The keyless profile's signing overrides never reached the other repository.
  run "$REAL_GIT" -C "$other" config --local --get commit.gpgSign
  [ "$status" -eq 1 ]
}

@test "ws clone: an inherited GIT_CONFIG never hides the SSH command Git would run" {
  # Alias resolution reads the global core.sshCommand, as the clone does.
  cat > "$TEST_MOCK_BIN/alias-ssh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -G ]]; then
  shift
  [[ "${1:-}" == -- ]] && shift
  case "${1:-}" in
    github-personal) printf 'user git\nhostname github.com\nport 22\n' ;;
    *) printf 'user git\nhostname %s\nport 22\n' "${1:-}" ;;
  esac
  exit 0
fi
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/alias-ssh"
  "$REAL_GIT" config --global core.sshCommand "$TEST_MOCK_BIN/alias-ssh"
  printf '[user]\n\tname = Other\n' > "$TEST_TEMP_DIR/other.gitconfig"
  export WS_OTHER_CONFIG="$TEST_TEMP_DIR/other.gitconfig"
  run run_zsh '
    export GIT_CONFIG="$WS_OTHER_CONFIG"
    NO_COLOR=1 ws-clone git@github.com:acme/app.git --identity personal --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"URL:               git@github-personal:acme/app.git"* ]]
  [[ "$output" == *"SSH alias:         github-personal (HostName github.com)"* ]]
}

@test "ws clone: without a terminal, confirmation and identity choices fail closed" {
  run run_zsh 'ws-clone https://github.com/acme/app.git --identity personal'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Confirmation requires a terminal; pass --yes to proceed."* ]]

  run run_zsh 'ws-clone https://github.com/acme/app.git --yes'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Several identities can receive this clone: personal, work; pass --identity NAME."* ]]

  run run_zsh 'ws-clone --yes'
  [ "$status" -eq 2 ]
  [[ "$output" == *"A repository URL is required."* ]]
  [ "$(clone_count)" -eq 0 ]
  [ ! -e "$WS/github/personal/app" ]
}

@test "ws clone: a declined confirmation and a cancelled picker change nothing" {
  run run_zsh '
    _ws_interactive_available() { return 0; }
    ws-clone https://github.com/acme/app.git --identity personal <<< "n"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled: nothing was cloned."* ]]

  export MOCK_FZF_MODE=cancel MOCK_FZF_STATUS=130
  run run_zsh '
    _ws_interactive_available() { return 0; }
    ws-clone https://github.com/acme/app.git
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled: nothing was cloned."* ]]
  [ "$(clone_count)" -eq 0 ]
  [ -z "$(ls -A "$WS/github/personal")" ]
}

@test "ws clone: the identity picker offers directories and profiles for the host" {
  mkdir -p "$WS/gitlab/corp" "$WS/gitlab/public"
  chmod -- 755 "$WS/gitlab" "$WS/gitlab/corp" "$WS/gitlab/public"
  printf 'git.corp.example\r\n' > "$WS/gitlab/corp/.ws-hostname"
  export MOCK_FZF_MODE=match MOCK_FZF_MATCH=work
  run run_zsh '
    _ws_interactive_available() { return 0; }
    typeset -gA ZDX_GIT_IDENTITIES=(
      oss "Name|Jane Doe;Email|jane@example.com"
      work "Name|Jane Doe;Email|jane@work.example"
    )
    NO_COLOR=1 ws-clone https://github.com/acme/app.git --dry-run
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_FZF_INPUT_FILE")" = "$(printf '%s\n' oss personal work)" ]
  [[ "$output" == *"Workspace:         github/work (selected)"* ]]

  # A .ws-hostname file selects its platform and identity for its host.
  run run_zsh 'NO_COLOR=1 ws-clone git@git.corp.example:team/svc.git --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workspace:         gitlab/corp (inferred)"* ]]

  # gitlab.com excludes the workspace that serves another host.
  run run_zsh 'NO_COLOR=1 ws-clone https://gitlab.com/team/svc.git --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workspace:         gitlab/public (inferred)"* ]]

  run run_zsh 'ws-clone https://git.unknown.example/team/svc.git --dry-run'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Cannot infer the workspace platform for git.unknown.example; pass --platform NAME."* ]]
}

@test "ws clone: unsafe workspace directories and roots are refused" {
  chmod -- 775 "$WS/github/personal"
  run run_zsh 'ws-clone https://github.com/acme/app.git --identity personal --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be real directories that you own"* ]]
  chmod -- 755 "$WS/github/personal"

  ln -s "$HOME" "$WS/github/linked"
  run run_zsh 'ws-clone https://github.com/acme/app.git --identity linked --yes'
  [ "$status" -eq 1 ]

  run run_zsh 'WS_BASE_DIR="$HOME/missing"; ws-clone https://github.com/acme/app.git --identity personal --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"The workspace root does not exist: ~/missing"* ]]
  [ ! -e "$HOME/missing" ]
  [ "$(clone_count)" -eq 0 ]
}
