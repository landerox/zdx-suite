#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "ws safety: standalone execution routes through ws-menu instead of arbitrary commands" {
  local probe="$TEST_MOCK_BIN/ws-arbitrary-probe"
  cat > "$probe" <<'EOF'
#!/usr/bin/env zsh
print -r -- "arbitrary command executed" > "$HOME/ws-arbitrary-executed"
EOF
  chmod +x "$probe"

  run env \
    HOME="$HOME" \
    PATH="$PATH" \
    ZSH_CUSTOM="$TEST_SUITE_ROOT" \
    zsh -f "$TEST_SUITE_ROOT/functions/ws-menu.zsh" ws-arbitrary-probe

  [ "$status" -eq 2 ]
  [ ! -e "$HOME/ws-arbitrary-executed" ]
  [[ "$output" == *"Unknown"* ]]
}

@test "ws safety: lazy loading succeeds after the Git suite is already loaded" {
  run env \
    -u TEST_TEMP_DIR \
    -u BATS_TEST_DIRNAME \
    -u ZDX_EAGER_LOAD \
    HOME="$HOME" \
    PATH="$PATH" \
    ZSH_CUSTOM="$TEST_SUITE_ROOT" \
    ZDX_LAZY_LOAD=1 \
    zsh -f -c '
      source "$1/functions.zsh" || return 1
      git-menu --help >/dev/null 2>/dev/null || return 2
      ws-menu --help >/dev/null 2>/dev/null || return 3

      [[ -n "${_WS_COMMON_SOURCED:-}" ]] || return 4
      [[ -n "${_WS_MENU_SOURCED:-}" ]] || return 5
      typeset -f _ws_dispatch &>/dev/null || return 6
      typeset -f ws-remove &>/dev/null || return 7
    ' zsh "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
}

@test "ws safety: create rejects unsafe workspace roots before opening fzf" {
  run run_zsh '
    local real_root="$HOME/real-workspaces"
    command mkdir -p -- "$real_root"
    command ln -s -- "$real_root" "$HOME/workspaces-link"

    fzf() {
      print -r -- "fzf called" >> "$HOME/unsafe-root-fzf"
      command cat >/dev/null
      return 130
    }

    local invalid_root
    for invalid_root in \
      "" \
      "/" \
      "$HOME" \
      "$HOME/workspaces/../outside" \
      "$HOME/workspaces-link"; do
      WS_BASE_DIR="$invalid_root"
      ws-create >/dev/null 2>/dev/null
      (( $? != 0 )) || return 10
    done

    [[ ! -e "$HOME/unsafe-root-fzf" ]]
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: create distinguishes fzf failure from cancellation" {
  run run_zsh '
    fzf() {
      command cat >/dev/null
      return 97
    }

    ws-create >/dev/null 2>"$HOME/ws-create-error"
    local create_rc=$?
    (( create_rc != 0 )) || return 10
    command grep -Fq "selection failed (status 97)" \
      "$HOME/ws-create-error" || return 11
    [[ ! -d "$WS_BASE_DIR/github" \
      && ! -d "$WS_BASE_DIR/gitlab" ]] || return 12
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: remove rejects unsafe workspace roots before selection or deletion" {
  run run_zsh '
    local real_root="$HOME/real-workspaces"
    command mkdir -p -- "$real_root"
    command ln -s -- "$real_root" "$HOME/workspaces-link"

    _tk_list_workspaces() {
      print -r -- "github/victim"
    }
    fzf() {
      print -r -- "fzf called" >> "$HOME/unsafe-remove-fzf"
      command cat >/dev/null
      return 130
    }
    rm() {
      print -r -- "$@" >> "$HOME/unsafe-remove-rm"
      return 97
    }

    local invalid_root
    for invalid_root in \
      "" \
      "/" \
      "$HOME" \
      "$HOME/workspaces/../outside" \
      "$HOME/workspaces-link"; do
      WS_BASE_DIR="$invalid_root"
      ws-remove >/dev/null 2>/dev/null
      (( $? != 0 )) || return 10
    done

    [[ ! -e "$HOME/unsafe-remove-fzf" ]]
    [[ ! -e "$HOME/unsafe-remove-rm" ]]
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: remove dry-run preserves scope and confirmed removal stays exact" {
  run run_zsh '
    local workspace_name="github/test"
    local workspace_dir="$WS_BASE_DIR/$workspace_name"
    command mkdir -p -- "$workspace_dir/.ssh" "$workspace_dir/repository/.git" \
      "$HOME/.ssh"
    : > "$workspace_dir/.gitconfig"
    print -r -- "keep" > "$workspace_dir/repository/kept"
    command chmod 700 "$HOME/.ssh"
    print -rl -- \
      "# BEGIN ws:github/test" \
      "Host github-test" \
      "    HostName github.com" \
      "# END ws:github/test" \
      "Host keep-me" \
      "    HostName example.invalid" > "$HOME/.ssh/config"
    command chmod 600 "$HOME/.ssh/config"
    git config --global \
      "includeIf.gitdir:${workspace_dir}/.path" "$workspace_dir/.gitconfig"

    ws-remove --dry-run --yes "$workspace_name" \
      >/dev/null 2>/dev/null || return 10
    [[ -f "$workspace_dir/repository/kept" ]] || return 11
    command grep -Fq "BEGIN ws:github/test" "$HOME/.ssh/config" || return 12
    git config --global --get-all \
      "includeIf.gitdir:${workspace_dir}/.path" >/dev/null || return 13

    ws-remove --yes "$workspace_name" >/dev/null 2>/dev/null || return 20
    [[ ! -e "$workspace_dir" && ! -L "$workspace_dir" ]] || return 21
    command grep -Fq "Host keep-me" "$HOME/.ssh/config" || return 22
    ! command grep -Fq "BEGIN ws:github/test" "$HOME/.ssh/config" \
      || return 23
    ! git config --global --get-all \
      "includeIf.gitdir:${workspace_dir}/.path" >/dev/null \
      || return 24
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: remove fails closed on incomplete SSH markers" {
  run run_zsh '
    local workspace_name="github/test"
    local workspace_dir="$WS_BASE_DIR/$workspace_name"
    command mkdir -p -- "$workspace_dir/.ssh" "$HOME/.ssh"
    : > "$workspace_dir/.gitconfig"
    print -rl -- \
      "# BEGIN ws:github/test" \
      "Host github-test" \
      "    HostName github.com" \
      "Host keep-me" \
      "    HostName example.invalid" > "$HOME/.ssh/config"
    command chmod 600 "$HOME/.ssh/config"
    local before
    before=$(<"$HOME/.ssh/config")

    ws-remove --yes "$workspace_name" >/dev/null 2>/dev/null
    local remove_rc=$?
    (( remove_rc != 0 )) || return 10
    [[ -d "$workspace_dir" ]] || return 11
    [[ "$(<"$HOME/.ssh/config")" == "$before" ]] || return 12
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: remove without --yes fails closed outside a terminal" {
  run run_zsh '
    local workspace_name="github/test"
    local workspace_dir="$WS_BASE_DIR/$workspace_name"
    command mkdir -p -- "$workspace_dir/.ssh"
    : > "$workspace_dir/.gitconfig"

    ws-remove "$workspace_name" </dev/null >/dev/null 2>/dev/null
    local remove_rc=$?
    (( remove_rc != 0 )) || return 10
    [[ -d "$workspace_dir" ]] || return 11
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: remove deletes one exact legacy SSH Host block" {
  run run_zsh '
    local workspace_name="github/test"
    local workspace_dir="$WS_BASE_DIR/$workspace_name"
    command mkdir -p -- "$workspace_dir/.ssh" "$HOME/.ssh"
    : > "$workspace_dir/.gitconfig"
    print -rl -- \
      "Host before" \
      "    HostName before.invalid" \
      "# Workspace: github/test" \
      "Host github-test" \
      "" \
      "    HostName github.com" \
      "    IdentityFile /private/key" \
      "    IdentitiesOnly yes" \
      "# comment inside managed block" \
      "" \
      "Match host example.invalid" \
      "    User special-user" \
      "" \
      "Host keep-me" \
      "    HostName example.invalid" > "$HOME/.ssh/config"
    command chmod 600 "$HOME/.ssh/config"

    ws-remove --yes "$workspace_name" >/dev/null 2>/dev/null || return 10
    [[ ! -e "$workspace_dir" ]] || return 11
    command grep -Fqx -- "Host before" "$HOME/.ssh/config" || return 12
    command grep -Fqx -- "Match host example.invalid" \
      "$HOME/.ssh/config" || return 13
    command grep -Fqx -- "    User special-user" \
      "$HOME/.ssh/config" || return 14
    command grep -Fqx -- "Host keep-me" "$HOME/.ssh/config" || return 15
    ! command grep -Fq -- "github-test" "$HOME/.ssh/config" || return 16
    ! command grep -Fq -- "/private/key" "$HOME/.ssh/config" || return 17
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: remove refuses a workspace inode swapped during configuration" {
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ "$*" == *"config --file"* && "$*" == *"--get-all"* \
  && ! -e "$HOME/ws-remove-swapped" ]]; then
  mv -- "$WS_SWAP_TARGET" "${WS_SWAP_TARGET}.original"
  mkdir -p -- "$WS_SWAP_TARGET"
  printf 'substitute\n' > "$WS_SWAP_TARGET/must-survive"
  : > "$HOME/ws-remove-swapped"
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    local workspace_name="github/test"
    local workspace_dir="$WS_BASE_DIR/$workspace_name"
    command mkdir -p -- "$workspace_dir/.ssh"
    : > "$workspace_dir/.gitconfig"
    export WS_SWAP_TARGET="$workspace_dir"
    /usr/bin/git config --global \
      "includeIf.gitdir:${workspace_dir}/.path" "$workspace_dir/.gitconfig"

    ws-remove --yes "$workspace_name" >/dev/null 2>/dev/null
    local remove_rc=$?
    (( remove_rc != 0 )) || return 10
    [[ -f "$workspace_dir/must-survive" ]] || return 11
    [[ -d "${workspace_dir}.original" ]] || return 12
    /usr/bin/git config --global --get-all \
      "includeIf.gitdir:${workspace_dir}/.path" >/dev/null || return 13
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: remove never follows a gitconfig symlink swapped mid-plan" {
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ "$*" == *"config --file"* && "$*" == *"--get-all"* \
  && ! -e "$HOME/ws-gitconfig-swapped" ]]; then
  mv -- "$HOME/.gitconfig" "$HOME/.gitconfig.original"
  ln -s -- "$WS_EXTERNAL_GITCONFIG" "$HOME/.gitconfig"
  : > "$HOME/ws-gitconfig-swapped"
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    local workspace_name="github/test"
    local workspace_dir="$WS_BASE_DIR/$workspace_name"
    command mkdir -p -- "$workspace_dir/.ssh"
    : > "$workspace_dir/.gitconfig"
    export WS_EXTERNAL_GITCONFIG="$HOME/external-gitconfig"
    print -r -- "external-must-survive" > "$WS_EXTERNAL_GITCONFIG"
    /usr/bin/git config --global \
      "includeIf.gitdir:${workspace_dir}/.path" "$workspace_dir/.gitconfig"

    ws-remove --yes "$workspace_name" >/dev/null 2>/dev/null
    local remove_rc=$?
    (( remove_rc != 0 )) || return 10
    [[ -d "$workspace_dir" ]] || return 11
    [[ "$(<"$WS_EXTERNAL_GITCONFIG")" == "external-must-survive" ]] \
      || return 12
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: remove aborts when the global gitconfig cannot be parsed" {
  run run_zsh '
    local workspace_name="github/test"
    local workspace_dir="$WS_BASE_DIR/$workspace_name"
    command mkdir -p -- "$workspace_dir/.ssh"
    : > "$workspace_dir/.gitconfig"
    print -r -- "[malformed" > "$HOME/.gitconfig"
    local before=""
    before=$(<"$HOME/.gitconfig")

    ws-remove --yes "$workspace_name" >/dev/null 2>/dev/null
    local remove_rc=$?
    (( remove_rc != 0 )) || return 10
    [[ -d "$workspace_dir" ]] || return 11
    [[ "$(<"$HOME/.gitconfig")" == "$before" ]] || return 12
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: a failed single clone returns nonzero" {
  run run_zsh '
    command mkdir -p -- "$WS_BASE_DIR/github/test/.ssh"
    print -r -- "ssh-ed25519 public-test" \
      > "$WS_BASE_DIR/github/test/.ssh/id_ed25519.pub"

    _tk_detect_workspace() {
      print -r -- "github/test"
    }
    _tk_confirm() {
      return 0
    }
    _tk_success() {
      print -r -- "$1" >> "$HOME/clone-success"
    }
    git() {
      if [[ "${1:-}" == "clone" ]]; then
        print -u2 -r -- "simulated clone failure"
        return 47
      fi
      return 1
    }

    ws-clone owner/repository
  '

  [ "$status" -ne 0 ]
  [ ! -e "$HOME/clone-success" ]
  [[ "$output" == *"Clone failed"* ]]
}

@test "ws safety: invalid clone operands never echo URL credentials" {
  run run_zsh '
    ws-clone \
      "https://alice:secret-token@example.invalid/org/repo.git?bad"
  '

  [ "$status" -eq 2 ]
  [[ "$output" != *"secret-token"* ]]
  [[ "$output" != *"alice:"* ]]

  run run_zsh '
    ws-clone-multi \
      "https://alice:batch-secret@example.invalid/org/repo.git?bad"
  '

  [ "$status" -ne 0 ]
  [[ "$output" != *"batch-secret"* ]]
  [[ "$output" != *"alice:"* ]]
}

@test "ws safety: clone failure never follows a public-key symlink" {
  run run_zsh '
    local workspace_dir="$WS_BASE_DIR/github/test"
    command mkdir -p -- "$workspace_dir/.ssh"
    print -r -- "TOP-SECRET-NOT-A-PUBLIC-KEY" > "$HOME/private-value"
    command ln -s -- "$HOME/private-value" \
      "$workspace_dir/.ssh/id_ed25519.pub"

    _tk_detect_workspace() {
      print -r -- "github/test"
    }
    git() {
      [[ "${1:-}" == "clone" ]] && return 47
      return 1
    }

    ws-clone owner/repository
  '

  [ "$status" -ne 0 ]
  [[ "$output" != *"TOP-SECRET"* ]]
  [[ "$output" == *"ws-show-key"* ]]
}

@test "ws safety: a failed batch clone is not converted into success by a pipeline" {
  run run_zsh '
    command mkdir -p -- "$WS_BASE_DIR/github/test/.ssh"
    print -r -- "ssh-ed25519 public-test" \
      > "$WS_BASE_DIR/github/test/.ssh/id_ed25519.pub"

    _tk_detect_workspace() {
      print -r -- "github/test"
    }
    _tk_confirm() {
      [[ "$1" == Clone\ * ]]
    }
    _ws_clone_confirmation_available() {
      return 0
    }
    _tk_success() {
      print -r -- "$1" >> "$HOME/batch-clone-success"
    }
    git() {
      if [[ "${1:-}" == "clone" ]]; then
        print -r -- "simulated clone failure"
        return 47
      fi
      return 1
    }

    ws-clone-multi owner/repository
  '

  [ "$status" -ne 0 ]
  [ ! -e "$HOME/batch-clone-success" ]
  [[ "$output" == *"Failed"* ]]
}

@test "ws safety: batch clone rejects colliding destination basenames" {
  run run_zsh '
    _tk_detect_workspace() {
      print -r -- "github/test"
    }
    _ws_clone_confirmation_available() {
      return 0
    }
    _tk_confirm() {
      return 0
    }
    git() {
      if [[ "$*" == clone\ * ]]; then
        print -r -- "unexpected clone" >> "$HOME/ws-clone-collision"
      fi
      return 1
    }

    ws-clone-multi alice/shared bob/shared
  '

  [ "$status" -eq 2 ]
  [ ! -e "$HOME/ws-clone-collision" ]
  [[ "$output" == *"collide"* ]]
}

@test "ws safety: migration never rewrites or displays a query-bearing remote" {
  run run_zsh '
    local source_root="$HOME/source-repos"
    local workspace_dir="$WS_BASE_DIR/github/test"
    command mkdir -p -- "$source_root/repository/.git" \
      "$workspace_dir/.ssh"
    : > "$workspace_dir/.gitconfig"
    command git init -q "$source_root/repository" || return 10
    command git -C "$source_root/repository" remote add origin \
      "https://example.invalid/org/repository.git?access_token=QUERY-SECRET" \
      || return 11
    export MOCK_FZF_MODE=first

    _ws_migrate_interactive_available() {
      return 0
    }
    read() {
      source_dir="$source_root"
      return 0
    }
    _tk_confirm() {
      return 0
    }
    ws-migrate
  '

  [ "$status" -ne 0 ]
  [[ "$output" != *"QUERY-SECRET"* ]]
  [[ "$output" == *"Will migrate 1 repo(s)"* ]]
  run git -C "$HOME/workspaces/github/test/repository" remote get-url origin
  [ "$status" -eq 0 ]
  [ "$output" = "https://example.invalid/org/repository.git?access_token=QUERY-SECRET" ]
}

@test "ws safety: sync never pops a foreign stash when its own stash push fails" {
  run run_zsh '
    local repo_dir="$WS_BASE_DIR/github/test/repository"
    command mkdir -p -- "$repo_dir/.git"

    _tk_detect_workspace() {
      print -r -- "github/test"
    }
    _tk_confirm() {
      [[ "$1" == Stash\ * ]]
    }
    git() {
      local joined="$*"
      case "$joined" in
        *"fetch --all --prune"*)
          return 0
          ;;
        *"branch --show-current"*)
          print -r -- "main"
          return 0
          ;;
        *"branch -r --no-merged HEAD"*)
          return 0
          ;;
        *"status --porcelain"*)
          print -r -- " M tracked.txt"
          return 0
          ;;
        *"rev-parse --abbrev-ref main@{upstream}"*)
          print -r -- "origin/main"
          return 0
          ;;
        *"rev-parse --verify HEAD"*)
          printf "1111111111111111111111111111111111111111\n"
          return 0
          ;;
        *"rev-parse --verify origin/main"*)
          printf "2222222222222222222222222222222222222222\n"
          return 0
          ;;
        *"rev-list --count origin/main..HEAD"*)
          print -r -- "0"
          return 0
          ;;
        *"rev-list --count HEAD..origin/main"*)
          print -r -- "1"
          return 0
          ;;
        *"stash push"*)
          print -r -- "push-failed" >> "$HOME/stash-calls"
          return 1
          ;;
        *"merge --ff-only"*)
          return 0
          ;;
        *"stash pop"*|*"stash apply"*|*"stash drop"*)
          print -r -- "foreign-stash-touched" >> "$HOME/stash-calls"
          return 0
          ;;
      esac
      return 1
    }

    ws-sync >/dev/null 2>/dev/null
    [[ ! -e "$HOME/stash-calls" ]] \
      || ! command grep -Fq "foreign-stash-touched" "$HOME/stash-calls"
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: sync identifies its exact stash even when an older stash has identical changes" {
  run run_zsh '
    local repo_dir="$WS_BASE_DIR/github/test/repository"
    command mkdir -p -- "$repo_dir"
    command git -C "$repo_dir" init -q
    command git -C "$repo_dir" config user.name "Test User"
    command git -C "$repo_dir" config user.email "test@example.invalid"
    print -r -- "before" > "$repo_dir/tracked.txt"
    command git -C "$repo_dir" add tracked.txt
    command git -C "$repo_dir" commit -qm "initial"

    print -r -- "changed" > "$repo_dir/tracked.txt"
    command git -C "$repo_dir" stash push -m \
      "ws-sync invocation-owned auto-stash" -q
    local foreign_oid
    foreign_oid=$(command git -C "$repo_dir" rev-parse refs/stash)
    command git -C "$repo_dir" stash apply -q "$foreign_oid"

    _ws_sync_create_stash "$repo_dir" \
      "ws-sync invocation-owned auto-stash" || return 10
    local owned_oid="$REPLY"
    [[ -n "$owned_oid" && "$owned_oid" != "$foreign_oid" ]] || return 11
    [[ -z "$(command git -C "$repo_dir" status --porcelain)" ]] || return 12

    _ws_sync_restore_stash "$repo_dir" "$owned_oid" || return 13
    [[ -n "$(command git -C "$repo_dir" status --porcelain)" ]] || return 14
    command git -C "$repo_dir" stash list --format="%H" \
      | command grep -Fqx -- "$owned_oid" || return 15
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: sync reports rev-list failure instead of claiming up to date" {
  run run_zsh '
    local repo_dir="$WS_BASE_DIR/github/test/repository"
    command mkdir -p -- "$repo_dir/.git"

    _tk_detect_workspace() {
      print -r -- "github/test"
    }
    git() {
      local joined="$*"
      case "$joined" in
        *"fetch --all --prune"*)
          return 0
          ;;
        *"branch --show-current"*)
          print -r -- "main"
          return 0
          ;;
        *"branch -r --no-merged HEAD"*)
          return 0
          ;;
        *"status --porcelain"*)
          return 0
          ;;
        *"rev-parse --abbrev-ref main@{upstream}"*)
          print -r -- "origin/main"
          return 0
          ;;
        *"rev-parse --verify HEAD"*)
          printf "1111111111111111111111111111111111111111\n"
          return 0
          ;;
        *"rev-parse --verify origin/main"*)
          printf "2222222222222222222222222222222222222222\n"
          return 0
          ;;
        *"rev-list --count"*)
          return 88
          ;;
        *"merge --ff-only"*)
          print -r -- "unexpected merge" >> "$HOME/ws-sync-pull"
          return 0
          ;;
      esac
      return 1
    }

    ws-sync >/dev/null 2>/dev/null
    local sync_rc=$?
    (( sync_rc != 0 )) || return 10
    [[ ! -e "$HOME/ws-sync-pull" ]] || return 11
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: sync merges the frozen upstream object across a ref race" {
  run run_zsh '
    local repo_dir="$WS_BASE_DIR/github/test/repository"
    command mkdir -p -- "$repo_dir"
    /usr/bin/git -C "$repo_dir" init -q -b main
    /usr/bin/git -C "$repo_dir" config user.name "Test User"
    /usr/bin/git -C "$repo_dir" config user.email "test@example.invalid"

    print -r -- "A" > "$repo_dir/tracked.txt"
    /usr/bin/git -C "$repo_dir" add tracked.txt
    /usr/bin/git -C "$repo_dir" commit -qm "A"
    local oid_a
    oid_a=$(/usr/bin/git -C "$repo_dir" rev-parse HEAD)

    print -r -- "B" > "$repo_dir/tracked.txt"
    /usr/bin/git -C "$repo_dir" commit -qam "B"
    local oid_b
    oid_b=$(/usr/bin/git -C "$repo_dir" rev-parse HEAD)

    print -r -- "C" > "$repo_dir/tracked.txt"
    /usr/bin/git -C "$repo_dir" commit -qam "C"
    local oid_c
    oid_c=$(/usr/bin/git -C "$repo_dir" rev-parse HEAD)

    /usr/bin/git -C "$repo_dir" reset -q --hard "$oid_a"
    /usr/bin/git -C "$repo_dir" update-ref \
      refs/remotes/origin/main "$oid_b"
    /usr/bin/git -C "$repo_dir" config branch.main.remote .
    /usr/bin/git -C "$repo_dir" config \
      branch.main.merge refs/remotes/origin/main

    export WS_SYNC_RACE_REPO="$repo_dir"
    export WS_SYNC_RACE_OID="$oid_c"
    _tk_detect_workspace() {
      print -r -- "github/test"
    }
    git() {
      if [[ "$*" == *"merge --ff-only"* \
        && ! -e "$HOME/ws-sync-raced" ]]; then
        /usr/bin/git -C "$WS_SYNC_RACE_REPO" update-ref \
          refs/remotes/origin/main "$WS_SYNC_RACE_OID" || return 91
        : > "$HOME/ws-sync-raced"
      fi
      /usr/bin/git "$@"
    }

    ws-sync >/dev/null 2>/dev/null
    local sync_rc=$?
    (( sync_rc != 0 )) || return 10
    [[ -e "$HOME/ws-sync-raced" ]] || return 11
    [[ "$(/usr/bin/git -C "$repo_dir" rev-parse HEAD)" == "$oid_b" ]] \
      || return 12
    [[ "$(/usr/bin/git -C "$repo_dir" rev-parse HEAD)" != "$oid_c" ]] \
      || return 13
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: autoclean never evaluates stale branches after fetch failure" {
  run run_zsh '
    local repo_dir="$WS_BASE_DIR/github/test/repository"
    command mkdir -p -- "$repo_dir/.git"

    _tk_detect_workspace() {
      print -r -- "github/test"
    }
    git() {
      if [[ "$*" == *"fetch --prune --all"* ]]; then
        return 89
      fi
      if [[ "$*" == *"branch -D"* ]]; then
        print -r -- "unexpected deletion" >> "$HOME/ws-autoclean-delete"
      fi
      return 1
    }

    ws-autoclean >/dev/null 2>/dev/null
    local clean_rc=$?
    (( clean_rc != 0 )) || return 10
    [[ ! -e "$HOME/ws-autoclean-delete" ]] || return 11
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: autoclean atomically preserves a branch repointed during deletion" {
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ "$*" == *"update-ref -d refs/heads/stale"* \
  && ! -e "$HOME/ws-autoclean-repointed" ]]; then
  old_oid=$(/usr/bin/git -C "$WS_AUTOCLEAN_RACE_REPO" \
    rev-parse refs/heads/stale) || exit 91
  new_oid=$(printf 'concurrent branch update\n' \
    | /usr/bin/git -C "$WS_AUTOCLEAN_RACE_REPO" \
      commit-tree "${old_oid}^{tree}" -p "$old_oid") || exit 92
  /usr/bin/git -C "$WS_AUTOCLEAN_RACE_REPO" update-ref \
    refs/heads/stale "$new_oid" "$old_oid" || exit 93
  printf '%s\n' "$new_oid" > "$HOME/ws-autoclean-repointed"
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    local repo_dir="$WS_BASE_DIR/github/test/repository"
    command mkdir -p -- "$repo_dir"
    /usr/bin/git -C "$repo_dir" init -q
    /usr/bin/git -C "$repo_dir" config user.name "Test User"
    /usr/bin/git -C "$repo_dir" config user.email "test@example.invalid"
    /usr/bin/git -C "$repo_dir" commit --allow-empty -qm "initial"
    /usr/bin/git -C "$repo_dir" branch stale
    export WS_AUTOCLEAN_RACE_REPO="$repo_dir"
    export MOCK_FZF_MODE=first

    _tk_detect_workspace() {
      print -r -- "github/test"
    }
    _ws_autoclean_confirmation_available() {
      return 0
    }
    _tk_confirm_count() {
      return 0
    }

    ws-autoclean >/dev/null 2>/dev/null
    local clean_rc=$?
    (( clean_rc != 0 )) || return 10
    [[ -s "$HOME/ws-autoclean-repointed" ]] || return 11
    local expected_oid=""
    expected_oid=$(<"$HOME/ws-autoclean-repointed")
    [[ "$(/usr/bin/git -C "$repo_dir" rev-parse refs/heads/stale)" \
      == "$expected_oid" ]] || return 12
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: repository displays redact credentials from remote URLs" {
  run run_zsh '
    local repo_dir="$WS_BASE_DIR/github/test/repository"
    command mkdir -p -- "$repo_dir/.git" "$WS_BASE_DIR/github/test/.ssh"
    : > "$WS_BASE_DIR/github/test/.gitconfig"
    export MOCK_FZF_MODE=first
    git() {
      local joined="$*"
      case "$joined" in
        *"remote get-url origin"*)
          print -r -- \
            "https://alice:secret-token@example.invalid/org/repository.git"
          return 0
          ;;
        *"branch --show-current"*)
          print -r -- "main"
          return 0
          ;;
        *"status --porcelain"*)
          return 0
          ;;
      esac
      return 1
    }

    ws-repos
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"secret-token"* ]]
  [[ "$output" != *"alice:"* ]]
  [[ "$output" == *"example.invalid"* || "$output" == *"redacted"* ]]
}

@test "ws safety: repository operations reject symlink escapes" {
  run run_zsh '
    local workspace_dir="$WS_BASE_DIR/github/test"
    local outside_repo="$HOME/outside-repository"
    command mkdir -p -- "$workspace_dir/.ssh" "$outside_repo/.git"
    : > "$workspace_dir/.gitconfig"
    command ln -s -- "$outside_repo" "$workspace_dir/linked-repository"

    _ws_validate_repo_dir "$workspace_dir" \
      "$workspace_dir/linked-repository" && return 10

    _tk_detect_workspace() {
      print -r -- "github/test"
    }
    git() {
      print -r -- "$*" >> "$HOME/symlink-repo-git"
      return 97
    }

    ws-sync >/dev/null 2>/dev/null
    [[ ! -e "$HOME/symlink-repo-git" ]]
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: workspace previews cannot execute interpolated root text" {
  run run_zsh '
    local marker="$HOME/ws-preview-injected"
    WS_BASE_DIR="$HOME/workspaces\"; command touch \"$marker\"; #"

    _tk_list_workspaces() {
      print -r -- "github/test"
    }
    fzf() {
      local preview=""
      local argument
      command cat >/dev/null
      for argument in "$@"; do
        case "$argument" in
          --preview=*)
            preview="${argument#--preview=}"
            ;;
        esac
      done
      preview="${preview//\{\}/github/test}"
      [[ -z "$preview" ]] \
        || command zsh -f -c "$preview" >/dev/null 2>/dev/null
      return 130
    }

    ws-info >/dev/null 2>/dev/null
    [[ ! -e "$marker" ]]
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: SSH probes are non-interactive, bounded, and preserve failure" {
  cat > "$TEST_MOCK_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" > "$HOME/ws-ssh-arguments"
printf 'simulated SSH failure with secret-token-value\n' >&2
exit 255
EOF
  chmod +x "$TEST_MOCK_BIN/ssh"

  run run_zsh '
    command mkdir -p -- "$WS_BASE_DIR/github/test/.ssh"
    : > "$WS_BASE_DIR/github/test/.gitconfig"
    : > "$WS_BASE_DIR/github/test/.ssh/id_ed25519"

    export MOCK_FZF_MODE=first
    ws-test
  '

  [ "$status" -ne 0 ]
  [ -s "$HOME/ws-ssh-arguments" ]
  grep -Fq "BatchMode=yes" "$HOME/ws-ssh-arguments"
  grep -Eq '^ConnectTimeout=[1-9][0-9]*$' "$HOME/ws-ssh-arguments"
  grep -Fq "KbdInteractiveAuthentication=no" "$HOME/ws-ssh-arguments"
  grep -Fq "NumberOfPasswordPrompts=0" "$HOME/ws-ssh-arguments"
  grep -Fq "PasswordAuthentication=no" "$HOME/ws-ssh-arguments"
  grep -Fq "PreferredAuthentications=publickey" "$HOME/ws-ssh-arguments"
  grep -Fq "StrictHostKeyChecking=yes" "$HOME/ws-ssh-arguments"
  [[ "$output" != *"secret-token-value"* ]]
}

@test "ws safety: SSH probe returns 124 at its total deadline" {
  cat > "$TEST_MOCK_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
sleep 10
EOF
  chmod +x "$TEST_MOCK_BIN/ssh"

  run run_zsh '
    _ws_ssh_probe github-test 1 1
    (( $? == 124 )) || return 10

    whence() {
      if [[ "$*" == "-p timeout" || "$*" == "-p gtimeout" ]]; then
        return 1
      fi
      builtin whence "$@"
    }
    _ws_ssh_probe github-test 1 1
  '

  [ "$status" -eq 124 ]
  [[ "$output" != *"github-test"* ]]
}

@test "ws safety: authentication inventory uses the bounded redacted SSH probe" {
  cat > "$TEST_MOCK_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" > "$HOME/ws-auth-ssh-arguments"
printf 'Hi! You have successfully authenticated, secret-token-value.\n' >&2
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/ssh"

  run run_zsh '
    command mkdir -p -- "$WS_BASE_DIR/github/test/.ssh"
    : > "$WS_BASE_DIR/github/test/.gitconfig"
    : > "$WS_BASE_DIR/github/test/.ssh/id_ed25519"

    ws-auth
  '

  [ "$status" -eq 0 ]
  [ -s "$HOME/ws-auth-ssh-arguments" ]
  grep -Fq "StrictHostKeyChecking=yes" "$HOME/ws-auth-ssh-arguments"
  [[ "$output" == *"accepted"* ]]
  [[ "$output" != *"secret-token-value"* ]]
}

@test "ws safety: public key display rejects symlink and hardlink escapes" {
  run run_zsh '
    local workspace_dir="$WS_BASE_DIR/github/test"
    local outside_file="$HOME/private-material"
    command mkdir -p -- "$workspace_dir/.ssh"
    : > "$workspace_dir/.gitconfig"
    print -r -- "private-secret-value" > "$outside_file"
    command ln -s -- "$outside_file" \
      "$workspace_dir/.ssh/id_ed25519.pub"

    export MOCK_FZF_MODE=first
    ws-show-key >/dev/null 2>"$HOME/symlink-error"
    (( $? != 0 )) || return 10
    ! command grep -Fq "private-secret-value" "$HOME/symlink-error" \
      || return 11

    command rm -f -- "$workspace_dir/.ssh/id_ed25519.pub"
    command ln -- "$outside_file" "$workspace_dir/.ssh/id_ed25519.pub"
    ws-show-key >/dev/null 2>"$HOME/hardlink-error"
    (( $? != 0 )) || return 20
    ! command grep -Fq "private-secret-value" "$HOME/hardlink-error" \
      || return 21
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: key rotation prunes only validated private-public backup pairs" {
  run run_zsh '
    local workspace_dir="$WS_BASE_DIR/github/test"
    local ssh_dir="$workspace_dir/.ssh"
    command mkdir -p -- "$ssh_dir"
    : > "$workspace_dir/.gitconfig"
    print -r -- "private-current" > "$ssh_dir/id_ed25519"
    print -r -- "ssh-ed25519 public-current" > "$ssh_dir/id_ed25519.pub"
    command chmod 600 "$ssh_dir/id_ed25519"
    command chmod 644 "$ssh_dir/id_ed25519.pub"

    local stamp
    for stamp in 20240101000000 20240201000000 20240301000000; do
      print -r -- "private-$stamp" \
        > "$ssh_dir/id_ed25519.bak.$stamp"
      print -r -- "ssh-ed25519 public-$stamp" \
        > "$ssh_dir/id_ed25519.bak.$stamp.pub"
      command chmod 600 "$ssh_dir/id_ed25519.bak.$stamp"
      command chmod 644 "$ssh_dir/id_ed25519.bak.$stamp.pub"
    done

    export MOCK_FZF_MODE=first
    _tk_confirm() {
      return 0
    }
    git() {
      [[ "$*" == *"user.email"* ]] && print -r -- "test@example.invalid"
      return 0
    }
    ssh-keygen() {
      if [[ "${1:-}" == "-lf" ]]; then
        print -r -- "256 SHA256:test workspace (ED25519)"
        return 0
      fi
      local key_path=""
      local -i index=1
      while (( index <= $# )); do
        if [[ "${@[$index]}" == "-f" ]]; then
          (( ++index ))
          key_path="${@[$index]}"
          break
        fi
        (( ++index ))
      done
      [[ -n "$key_path" ]] || return 2
      print -r -- "private-new" > "$key_path"
      print -r -- "ssh-ed25519 public-new" > "${key_path}.pub"
    }

    ws-rotate-key >/dev/null 2>/dev/null || return 10
    local -a private_backups=()
    local backup_path
    for backup_path in "$ssh_dir"/id_ed25519.bak.*(N); do
      [[ "$backup_path" == *.pub ]] || private_backups+=("$backup_path")
    done
    (( ${#private_backups[@]} == 1 )) || return 11
    [[ -f "${private_backups[1]}.pub" ]] || return 12
    local -a public_backups=("$ssh_dir"/id_ed25519.bak.*.pub(N))
    (( ${#public_backups[@]} == 1 )) || return 13
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: failed key rotation preserves the active keypair" {
  run run_zsh '
    local workspace_dir="$WS_BASE_DIR/github/test"
    command mkdir -p -- "$workspace_dir/.ssh"
    print -r -- "private-before" > "$workspace_dir/.ssh/id_ed25519"
    print -r -- "public-before" > "$workspace_dir/.ssh/id_ed25519.pub"
    : > "$workspace_dir/.gitconfig"
    command chmod 600 "$workspace_dir/.ssh/id_ed25519"
    command chmod 644 "$workspace_dir/.ssh/id_ed25519.pub"

    export MOCK_FZF_MODE=first
    _tk_confirm() {
      return 0
    }
    ssh-keygen() {
      return 73
    }

    ws-rotate-key >/dev/null 2>/dev/null
    local rotation_rc=$?
    (( rotation_rc != 0 )) || return 10
    [[ "$(<"$workspace_dir/.ssh/id_ed25519")" == "private-before" ]] \
      || return 11
    [[ "$(<"$workspace_dir/.ssh/id_ed25519.pub")" == "public-before" ]] \
      || return 12
    local -a backups=("$workspace_dir"/.ssh/id_ed25519.bak.*(N))
    (( ${#backups[@]} == 0 )) || return 13
  '

  [ "$status" -eq 0 ]
}

@test "ws safety: fzf remains in the terminal foreground process group" {
  export WS_PTY_PGID_FILE="$TEST_TEMP_DIR/ws-pty-pgid"
  export WS_PTY_RC_FILE="$TEST_TEMP_DIR/ws-pty-rc"
  export WS_PTY_CHILD="$TEST_TEMP_DIR/ws-pty-child.zsh"

  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
set -u

cat >/dev/null
current_pgid=$(ps -o pgid= -p "$$" | tr -d '[:space:]')
terminal_pgid=$(ps -o tpgid= -p "$$" | tr -d '[:space:]')
printf '%s|%s\n' "$current_pgid" "$terminal_pgid" >> "$WS_PTY_PGID_FILE"

[[ -n "$current_pgid" && "$current_pgid" == "$terminal_pgid" ]] || exit 97
exit 130
EOF
  chmod +x "$TEST_MOCK_BIN/fzf"

  cat > "$WS_PTY_CHILD" <<'EOF'
setopt MONITOR
source "$ZSH_CUSTOM/functions/ws-menu.zsh" || exit 91
ws-menu
menu_rc=$?
command mkdir -p -- "$WS_BASE_DIR/github/test/.ssh" || exit 92
: > "$WS_BASE_DIR/github/test/.gitconfig" || exit 93
ws-show-key
picker_rc=$?
print -r -- "$menu_rc:$picker_rc" > "$WS_PTY_RC_FILE"
(( menu_rc == 0 && picker_rc == 0 ))
exit $?
EOF
  chmod +x "$WS_PTY_CHILD"

  run run_zsh '
    _ws_pty_foreground_check() {
      zmodload zsh/zpty || return 80
      zpty -b ws-foreground zsh -dfi "$WS_PTY_CHILD" || return 81
      {
        local -i attempt=0
        local chunk=""
        while [[ ! -s "$WS_PTY_RC_FILE" ]] && (( ++attempt <= 200 )); do
          zpty -r -t ws-foreground chunk 2>/dev/null || true
          command sleep 0.01
        done

        [[ -s "$WS_PTY_RC_FILE" ]] || return 82
        [[ -s "$WS_PTY_PGID_FILE" ]] || return 83

        local process_groups
        local -a process_group_lines=()
        process_groups=$(<"$WS_PTY_PGID_FILE")
        process_group_lines=("${(@f)process_groups}")
        (( ${#process_group_lines[@]} == 2 )) || return 84
        local process_group_line=""
        for process_group_line in "${process_group_lines[@]}"; do
          local current_pgid="${process_group_line%%|*}"
          local terminal_pgid="${process_group_line##*|}"
          [[ -n "$current_pgid" && "$current_pgid" == "$terminal_pgid" ]] \
            || return 85
        done

        local menu_rc
        menu_rc=$(<"$WS_PTY_RC_FILE")
        [[ "$menu_rc" == "0:0" ]] || return 86
      } always {
        zpty -d ws-foreground 2>/dev/null || true
      }
    }

    _ws_pty_foreground_check
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"suspended (tty output)"* ]]
}
