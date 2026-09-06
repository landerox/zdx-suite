#!/usr/bin/env bats

setup() {
  load test_helper

  # Setup dummy git repo inside TEST_TEMP_DIR to prevent polluting workspace config
  export REPO_DIR="$TEST_TEMP_DIR/dummy-repo"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR"
}

teardown() {
  cleanup_sandbox
}

@test "git_ws: git and ws menus source cleanly" {
  run run_zsh "echo SOURCED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCED"* ]]
}

@test "git_ws: _tk_test_write succeeds when paths are writable" {
  if [[ ! -f "$TEST_SUITE_ROOT/functions/ws-common.zsh" ]]; then
    skip "ws-common.zsh not found (ws-common is gitignored)"
  fi

  run run_zsh "_tk_test_write"
  [ "$status" -eq 0 ]
}

@test "git_ws: _tk_test_write fails when gitconfig is not writable" {
  if [[ ! -f "$TEST_SUITE_ROOT/functions/ws-common.zsh" ]]; then
    skip "ws-common.zsh not found (ws-common is gitignored)"
  fi

  run run_zsh "
    touch \"\$HOME/.gitconfig\"
    chmod 400 \"\$HOME/.gitconfig\"
    _tk_test_write
  "
  [ "$status" -eq 1 ]
}

@test "git_ws: _tk_test_write fails when workspaces parent is not writable" {
  if [[ ! -f "$TEST_SUITE_ROOT/functions/ws-common.zsh" ]]; then
    skip "ws-common.zsh not found (ws-common is gitignored)"
  fi

  run run_zsh "
    # Make HOME non-writable so workspaces directory cannot be created
    chmod 500 \"\$HOME\"
    _tk_test_write
  "
  [ "$status" -eq 1 ]
}

@test "git_ws: Git menu record formatting works" {
  run run_zsh "
    echo \$(_git_menu_section 'SecTitle' 'SecDesc')
    echo \$(_git_menu_entry 'EntryLabel' 'git-status' 'EntryDesc')
  "
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"── SecTitle ──|:|SecDesc"* ]]
  [[ "${lines[1]}" == *"EntryLabel|git-status|EntryDesc"* ]]
}

@test "git_ws: _tk_confirm handles positive and negative responses" {
  run run_zsh "
    read() { REPLY=y; }
    _tk_confirm 'Proceed'
  "
  [ "$status" -eq 0 ]

  run run_zsh "
    read() { REPLY=n; }
    _tk_confirm 'Proceed'
  "
  [ "$status" -eq 1 ]
}


@test "git_ws: _tk_file_perms returns octal permissions" {
  run run_zsh "
    touch \"\$HOME/perm-test\"
    chmod 644 \"\$HOME/perm-test\"
    _tk_file_perms \"\$HOME/perm-test\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"644"* ]]
}

@test "git_ws: _tk_extract_repo_path parses git urls correctly" {
  if [[ ! -f "$TEST_SUITE_ROOT/functions/ws-common.zsh" ]]; then
    skip "ws-common.zsh not found (ws-common is gitignored)"
  fi

  run run_zsh "
    _tk_extract_repo_path 'git@github.com:user/repo.git'
    _tk_extract_repo_path 'https://github.com/user2/repo2.git'
  "
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "user/repo" ]]
  [[ "${lines[1]}" == "user2/repo2" ]]
}

@test "git_ws: _tk_auth_badge shows non-sensitive repository context" {
  run run_zsh "
    git init -q
    git config user.name 'Test User'
    git config user.email 'test@example.com'
    _tk_auth_badge
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Repository: dummy-repo"* ]]
  [[ "$output" == *"Branch:"* ]]
  [[ "$output" != *"test@example.com"* ]]
}

@test "git_ws: _tk_diff_viewer detects delta and diff-so-fancy" {
  run run_zsh "
    # Mock delta
    touch \"\$TEST_MOCK_BIN/delta\" && chmod +x \"\$TEST_MOCK_BIN/delta\"
    _tk_diff_viewer
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"delta --paging=never"* ]]

  run run_zsh "
    # Remove delta, mock diff-so-fancy
    rm -f \"\$TEST_MOCK_BIN/delta\"
    touch \"\$TEST_MOCK_BIN/diff-so-fancy\" && chmod +x \"\$TEST_MOCK_BIN/diff-so-fancy\"
    _tk_diff_viewer
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff-so-fancy"* ]]

  run run_zsh "
    # Remove both
    rm -f \"\$TEST_MOCK_BIN/delta\" \"\$TEST_MOCK_BIN/diff-so-fancy\"
    _tk_diff_viewer
  "
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

@test "git_ws: git-pr-checkout fixes repository and PR head identity" {
  run run_zsh "
    git init -q
    git config user.name 'Test User'
    git config user.email 'test@example.com'
    touch tracked.txt
    git add tracked.txt
    git commit -qm 'test head'
    git remote add origin git@github.com:user/repo.git
    export PR_HEAD=\$(git rev-parse HEAD)

    cat <<'MOCKGH' > \"\$TEST_MOCK_BIN/gh\"
#!/usr/bin/env bash
if [[ \"\$*\" == *\"repo view\"* && \"\$*\" == *\"id,nameWithOwner,url\"* ]]; then
  printf 'R_repo_id\\tuser/repo\\thttps://github.com/user/repo\\n'
  exit 0
elif [[ \"\$*\" == *\"repo view\"* && \"\$*\" == *\"--json id\"* ]]; then
  printf 'R_repo_id\\n'
  exit 0
elif [[ \"\$*\" == *\"pr view 123\"* ]]; then
  printf 'PR_node_id\\tOPEN\\t%s\\n' \"\$PR_HEAD\"
  exit 0
elif [[ \"\$*\" == *\"pr checkout\"* ]]; then
  printf 'checked out exact PR head\\n'
  exit 0
fi
exit 0
MOCKGH
    chmod +x \"\$TEST_MOCK_BIN/gh\"

    git-pr-checkout 123
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked out exact PR head"* ]]
  [[ "$output" == *"detached mode"* ]]
}

@test "git_ws: ws-autoclean cleans up stale branches in workspace" {
  if [[ ! -f "$TEST_SUITE_ROOT/functions/ws-menu.zsh" ]]; then
    skip "ws-menu.zsh not found (ws-menu is gitignored)"
  fi

  # Select the workspace first, then its only stale-branch record.
  export MOCK_FZF_MODE=first

  run run_zsh "
    # Create workspace path structure
    mkdir -p \"\$WS_BASE_DIR/github/user/repo1/.git\"
    touch \"\$WS_BASE_DIR/github/user/repo1/.git/config\"
    mkdir -p \"\$WS_BASE_DIR/github/user/.ssh\"
    touch \"\$WS_BASE_DIR/github/user/.ssh/id_ed25519\"

    # Mock git
    cat <<'MOCKGIT' > \"\$TEST_MOCK_BIN/git\"
#!/usr/bin/env bash
if [[ \"\$*\" == *\"fetch --prune --all\"* ]]; then
  exit 0
elif [[ \"\$*\" == *\"branch --format\"* && \"\$*\" == *\"--list stale-branch\"* ]]; then
  echo -e \"stale-branch\t[gone]\"
  exit 0
elif [[ \"\$*\" == *\"branch --format\"* ]]; then
  echo -e \"stale-branch\t[gone]\"
  echo -e \"main\t\"
  exit 0
elif [[ \"\$*\" == *\"rev-parse --verify refs/heads/stale-branch\"* ]]; then
  printf '1111111111111111111111111111111111111111\\n'
  exit 0
elif [[ \"\$*\" == *\"branch --merged\"* ]]; then
  echo \"\"
  exit 0
elif [[ \"\$*\" == *\"symbolic-ref\"* ]]; then
  echo \"refs/remotes/origin/main\"
  exit 0
elif [[ \"\$*\" == *\"branch --show-current\"* ]]; then
  echo \"main\"
  exit 0
elif [[ \"\$*\" == *\"worktree list --porcelain\"* ]]; then
  printf 'worktree /tmp/mock\\nHEAD 2222222222222222222222222222222222222222\\nbranch refs/heads/main\\n'
  exit 0
elif [[ \"\$*\" == *\"update-ref -d refs/heads/stale-branch\"* ]]; then
  exit 0
fi
exec /usr/bin/git \"\$@\"
MOCKGIT
    chmod +x \"\$TEST_MOCK_BIN/git\"

    _ws_autoclean_confirmation_available() {
      return 0
    }

    # Override read to confirm deletion only when called with -q
    read() {
      if [[ \"\$1\" == \"-q\" ]]; then
        REPLY=y
        return 0
      fi
      builtin read \"\$@\"
    }

    # Run ws-autoclean specifying the workspace
    ws-autoclean
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleted stale-branch"* ]]
}

@test "git_ws: _tk_fzf_color_opts returns default or customized colors" {
  run run_zsh "
    unset NO_COLOR
    _tk_fzf_color_opts
  "
  [ "$status" -eq 0 ]
  [[ "$output" == --color=*"fg:-1,bg:-1"*"fg+:-1,bg+:-1"* ]]

  run run_zsh "
    unset NO_COLOR
    ZDX_FZF_THEME='fg:custom,bg:custom'
    _tk_fzf_color_opts
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "--color=fg:custom,bg:custom" ]]

  run run_zsh "
    NO_COLOR=1
    _tk_fzf_color_opts
  "
  [ "$status" -eq 0 ]
  [ "$output" = --no-color ]
}

@test "git_ws: _tk_spinner runs command and captures output" {
  run run_zsh "
    res=\$(_tk_spinner 'Running test' sh -c 'sleep 0.1; echo SUCCESS')
    echo \"RESULT=\$res\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT=SUCCESS"* ]]
}

@test "git_ws: dependency checking validation works" {
  run run_zsh "
    # Mock gh to be present
    touch \"\$TEST_MOCK_BIN/gh\" && chmod +x \"\$TEST_MOCK_BIN/gh\"
    _tk_verify_deps 'git-prs'
  "
  [ "$status" -eq 0 ]

  run run_zsh "
    # Mock gh to be missing
    rm -f \"\$TEST_MOCK_BIN/gh\"
    # Override command to simulate missing gh on system too
    command() {
      if [[ \"\$1\" == \"-v\" && \"\$2\" == \"gh\" ]]; then
        return 1
      fi
      builtin command \"\$@\"
    }
    # Mock read -q inside _tk_confirm to return 'n' (decline checking)
    read() { REPLY=n; return 1; }
    _tk_verify_deps 'git-prs'
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing gh required by 'git-prs'"* ]]
}

@test "git_ws: git-menu direct argument execution works" {
  run run_zsh "
    # Simulate being inside a git repo
    git init -q
    git config user.name 'Test User'
    git config user.email 'test@example.com'

    # Run git-menu with subcommand direct argument
    git-menu git-status
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Repository Status"* ]]
}

@test "git_ws: ws-create can import git identity from ZDX_GIT_IDENTITIES profile" {
  if [[ ! -f "$TEST_SUITE_ROOT/functions/ws-menu.zsh" ]]; then
    skip "ws-menu.zsh not found"
  fi

  run run_zsh "
    # Setup dummy variables
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(
      \"work\" \"Name|Jane Doe;Email|jane@corp.com;GpgKey|KEY123\"
    )

    # Mock fzf to choose:
    # 1. Platform: github
    # 2. profile: Profile: work
    # 3. SSH key: Generate new key
    fzf() {
      if [[ \"\$*\" == *\"Platform >\"* ]]; then
        echo \"github\"
      elif [[ \"\$*\" == *\"Select profile or manual >\"* ]]; then
        echo \"👤 Profile: work (Jane Doe <jane@corp.com>)\"
      elif [[ \"\$*\" == *\"SSH Key >\"* ]]; then
        echo \"Generate new key\"
      fi
    }

    # Mock ssh-keygen
    ssh-keygen() {
      local key_path=\"\"
      local i
      for ((i=1; i<=\$#; i++)); do
        if [[ \"\${@[\$i]}\" == \"-f\" ]]; then
          key_path=\"\${@[\$((i+1))]}\"
          break
        fi
      done
      if [[ -n \"\$key_path\" ]]; then
        mkdir -p \"\${key_path:h}\"
        touch \"\$key_path\"
        touch \"\${key_path}.pub\"
        echo \"ssh-ed25519 AAAAB3Nza... test@example.com\" > \"\${key_path}.pub\"
      fi
    }

    # Mock read -r and read -q
    read() {
      if [[ \"\${2:-}\" == \"-u\" ]]; then
        builtin read \"\$@\"
        return \$?
      fi
      if [[ \"\$1\" == \"-r\" ]]; then
        # For Step 3 (Identity name)
        eval \"\$2='corp-work'\"
        return 0
      fi
      if [[ \"\$1\" == \"-q\" ]]; then
        # Decline testing connection and cd
        REPLY=n
        return 1
      fi
      return 1
    }

    # Run ws-create
    ws-create
  "
  [ "$status" -eq 0 ]
  [[ -f "$HOME/workspaces/github/corp-work/.gitconfig" ]]
  local name email signingkey
  name=$(git config --file "$HOME/workspaces/github/corp-work/.gitconfig" user.name)
  email=$(git config --file "$HOME/workspaces/github/corp-work/.gitconfig" user.email)
  signingkey=$(git config --file "$HOME/workspaces/github/corp-work/.gitconfig" user.signingkey)
  [[ "$name" == "Jane Doe" ]]
  [[ "$email" == "jane@corp.com" ]]
  [[ "$signingkey" == "KEY123" ]]
}
