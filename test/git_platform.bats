#!/usr/bin/env bats
# shellcheck disable=SC2016

# Git behavior that differs by platform: case-insensitive file systems
# (core.ignorecase), WSL Windows drives and ssh.exe, the macOS Command Line
# Tools placeholder, the minimum Git release, and the signing terminal. Case
# folding is simulated with core.ignorecase on the host file system; WSL and
# macOS are selected through mocks, never by the host.

setup() {
  load test_helper
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat
  export GIT_ALLOW_PROTOCOL=file
  export GIT_AUTHOR_NAME="Platform Test"
  export GIT_AUTHOR_EMAIL="platform@example.invalid"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  unset GPG_TTY
}

teardown() {
  cleanup_sandbox
}

# Prints Zsh that creates a repository with one commit. The assertions run on
# case-sensitive and case-insensitive hosts alike: on APFS, `-e notes.txt` and
# `git show-ref --verify` also find Notes.TXT, so the helpers compare exact
# directory entries and listed ref names instead.
platform_repo() {
  cat <<'ZSH'

    local repo_dir="$HOME/repository"
    command git init -q -b main "$repo_dir" || return 81
    cd "$repo_dir" || return 82
    command git config core.hooksPath /dev/null
    command git config commit.gpgSign false
    command git config core.ignorecase false
    print -r -- "base" > base.txt
    command git add -A || return 83
    command git commit -q -m "base" || return 84

    # Succeeds when the current directory has an entry named exactly NAME.
    _platform_has_entry() {
      local -a entries=(*(DN))
      (( ${entries[(Ie)$1]} ))
    }
    # Prints the exact ref names below a namespace.
    _platform_refs() {
      command git for-each-ref --format="%(refname)" "$1"
    }
ZSH
}

show_failure() {
  printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
  cat "$HOME"/*.stderr >&2 2>/dev/null || true
}

# --- Case-insensitive file systems -------------------------------------------

@test "git platform: undo-commit --hard refuses an untracked case variant of a restored path" {
  run run_zsh "$(platform_repo)"'
    print -r -- "tracked notes" > notes.txt
    command git add notes.txt && command git commit -q -m notes || return 1
    command git rm -q notes.txt && command git commit -q -m "remove notes" || return 2
    print -r -- "precious" > Notes.TXT
    local head_before="$(command git rev-parse HEAD)"

    git-undo-commit --hard --dry-run >"$HOME/sensitive.stdout" 2>"$HOME/sensitive.stderr" \
      || return 10

    command git config core.ignorecase true
    git-undo-commit --hard --yes >"$HOME/folded.stdout" 2>"$HOME/folded.stderr" && return 11
    [[ "$(command git rev-parse HEAD)" == "$head_before" ]] || return 12
    [[ "$(<Notes.TXT)" == precious ]] || return 13
    _platform_has_entry notes.txt && return 14
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  ! grep -Fq "Protected untracked hard-reset obstacles" "$HOME/sensitive.stderr" || false
  grep -Fq "Protected untracked hard-reset obstacles" "$HOME/folded.stderr"
  grep -Fq "Notes.TXT" "$HOME/folded.stderr"
  [ ! -s "$HOME/folded.stdout" ]
}

@test "git platform: discard --all refuses an untracked case variant of a staged deletion" {
  run run_zsh "$(platform_repo)"'
    command git config core.ignorecase true
    command git rm -q --cached base.txt || return 1
    command mv base.txt BASE.TXT || return 2

    git-discard --all --yes >"$HOME/all.stdout" 2>"$HOME/all.stderr" && return 10
    [[ "$(<BASE.TXT)" == base ]] || return 11
    _platform_has_entry base.txt && return 12
    [[ "$(command git diff --cached --name-status)" == "D"$'\''\t'\''"base.txt" ]] || return 13
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/all.stdout" ]
  grep -Fq "BASE.TXT" "$HOME/all.stderr"
  grep -Fq "Refusing to overwrite or remove untracked or ignored paths." "$HOME/all.stderr"
}

@test "git platform: discard refuses an untracked file whose case variant is a restored directory" {
  run run_zsh "$(platform_repo)"'
    mkdir docs && print -r -- "doc" > docs/a.txt
    command git add docs/a.txt && command git commit -q -m docs || return 1
    command rm -r docs && print -r -- "precious" > Docs || return 2
    command git config core.ignorecase true

    export MOCK_FZF_MODE=match MOCK_FZF_MATCH=$'\''\tdocs/a.txt'\''
    git-discard --yes >"$HOME/discard.stdout" 2>"$HOME/discard.stderr" && return 10
    [[ -f Docs && "$(<Docs)" == precious ]] || return 11
    _platform_has_entry docs && return 12
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/discard.stdout" ]
  grep -Fq "Docs" "$HOME/discard.stderr"
  grep -Fq "Refusing to overwrite or remove untracked or ignored paths." \
    "$HOME/discard.stderr"
}

@test "git platform: stash apply and branch refuse case variants when core.ignorecase is set" {
  run run_zsh "$(platform_repo)"'
    command git branch topic || return 1
    print -r -- "stashed" > notes.txt
    git-stash save --include-untracked --yes \
      >"$HOME/save.stdout" 2>"$HOME/save.stderr" || return 2
    print -r -- "precious" > Notes.TXT

    git-stash apply --dry-run >"$HOME/sensitive.stdout" 2>"$HOME/sensitive.stderr" \
      || return 10

    command git config core.ignorecase true
    git-stash apply --yes >"$HOME/apply.stdout" 2>"$HOME/apply.stderr" && return 11
    [[ "$(<Notes.TXT)" == precious ]] || return 12
    _platform_has_entry notes.txt && return 13
    [[ -n "$(command git stash list)" ]] || return 14

    command rm Notes.TXT || return 15
    local branches_before="$(_platform_refs refs/heads)"
    git-stash branch "stash@{0}" Topic --yes \
      >"$HOME/branch.stdout" 2>"$HOME/branch.stderr" && return 16
    [[ "$(_platform_refs refs/heads)" == "$branches_before" ]] || return 17
    [[ -n "$(command git stash list)" ]] || return 18
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Dry run: 1 file planned; nothing was applied." "$HOME/sensitive.stderr"
  grep -Fq "These untracked or ignored paths collide with the stash:" "$HOME/apply.stderr"
  grep -Fq "Notes.TXT" "$HOME/apply.stderr"
  grep -Fq "refs/heads/Topic and refs/heads/topic" "$HOME/branch.stderr"
  [ ! -s "$HOME/apply.stdout" ]
  [ ! -s "$HOME/branch.stdout" ]
}

@test "git platform: tag creation refuses a case variant of an existing tag" {
  run run_zsh "$(platform_repo)"'
    command git tag v1.0 || return 1
    command git pack-refs --all || return 2

    git-tag-create --name V1.0 --dry-run \
      >"$HOME/sensitive.stdout" 2>"$HOME/sensitive.stderr" || return 10

    command git config core.ignorecase true
    git-tag-create --name V1.0 --yes >"$HOME/folded.stdout" 2>"$HOME/folded.stderr" \
      && return 11
    [[ "$(_platform_refs refs/tags)" == refs/tags/v1.0 ]] || return 12
    git-tag-create --name release/v2 --lightweight --yes \
      >"$HOME/distinct.stdout" 2>"$HOME/distinct.stderr" || return 13
    git-tag-create --name Release --yes >"$HOME/directory.stdout" 2>"$HOME/directory.stderr" \
      && return 14
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "DRY-RUN" "$HOME/sensitive.stderr"
  grep -Fq "collide on this case-insensitive file system" "$HOME/folded.stderr"
  grep -Fq "refs/tags/V1.0 and refs/tags/v1.0" "$HOME/folded.stderr"
  grep -Fq "Choose a tag name that differs by more than letter case." "$HOME/folded.stderr"
  grep -Fq "refs/tags/Release and refs/tags/release/v2" "$HOME/directory.stderr"
  [ ! -s "$HOME/folded.stdout" ]
}

@test "git platform: fetch-prune refuses remote branches that differ only in case" {
  run run_zsh "$(platform_repo)"'
    local remote_dir="$HOME/remote.git"
    command git init -q --bare "$remote_dir" || return 1
    command git remote add origin "$remote_dir" || return 2
    command git push -q origin main:refs/heads/main main:refs/heads/Feature || return 3
    command git fetch -q origin || return 4
    # A stale tracking ref left by a remote branch renamed by letter case.
    command git update-ref -d refs/remotes/origin/Feature || return 5
    command git update-ref refs/remotes/origin/feature "$(command git rev-parse HEAD)" \
      || return 6
    command git config core.ignorecase true
    local before="$(_platform_refs refs/remotes)"

    git-pull --fetch-prune --yes >"$HOME/prune.stdout" 2>"$HOME/prune.stderr" && return 10
    [[ "$(_platform_refs refs/remotes)" == "$before" ]] || return 11

    # Remote branches Feature and feature; packed refs hold both on any host.
    command git update-ref -d refs/remotes/origin/feature || return 12
    command git -C "$remote_dir" pack-refs --all || return 13
    command git push -q origin main:refs/heads/feature || return 14
    git-pull --fetch-prune --dry-run >"$HOME/twins.stdout" 2>"$HOME/twins.stderr" && return 15
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/prune.stdout" ]
  grep -Fq "refs/remotes/origin/Feature and refs/remotes/origin/feature" "$HOME/prune.stderr"
  ! grep -Fq "Tracking refs changed during fetch" "$HOME/prune.stderr" || false
  grep -Fq "Rename one of the remote branches" "$HOME/prune.stderr"
  grep -Fq "refs/remotes/origin/Feature and refs/remotes/origin/feature" "$HOME/twins.stderr"
}

@test "git platform: exact fetch and upstream push refuse a tracking ref that differs only in case" {
  run run_zsh "$(platform_repo)"'
    local remote_dir="$HOME/remote.git"
    command git init -q --bare "$remote_dir" || return 1
    command git remote add origin "$remote_dir" || return 2
    command git push -q origin main:refs/heads/main || return 3
    command git config branch.main.remote origin
    command git config branch.main.merge refs/heads/main
    # A stale tracking ref left by a remote branch renamed by letter case.
    command git update-ref -d refs/remotes/origin/main || return 4
    command git update-ref refs/remotes/origin/Main "$(command git rev-parse HEAD)" || return 5

    git-pull --fetch --dry-run >"$HOME/sensitive.stdout" 2>"$HOME/sensitive.stderr" || return 10

    command git config core.ignorecase true
    local before="$(_platform_refs refs/remotes)"
    git-pull --fetch --yes >"$HOME/fetch.stdout" 2>"$HOME/fetch.stderr" && return 11
    [[ "$(_platform_refs refs/remotes)" == "$before" ]] || return 12
    git-push --remote origin --ref refs/heads/main --set-upstream --dry-run \
      >"$HOME/push.stdout" 2>"$HOME/push.stderr" && return 13
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "DRY-RUN" "$HOME/sensitive.stderr"
  grep -Fq "refs/remotes/origin/main and refs/remotes/origin/Main" "$HOME/fetch.stderr"
  ! grep -Fq "changed during fetch" "$HOME/fetch.stderr" || false
  grep -Fq "refs/remotes/origin/main and refs/remotes/origin/Main" "$HOME/push.stderr"
}

# --- WSL ----------------------------------------------------------------------

@test "git platform: WSL detection reads its evidence and only /mnt/<letter> is a Windows drive" {
  local proc_root="$TEST_TEMP_DIR/proc"
  mkdir -p "$proc_root/interop/sys/fs/binfmt_misc" \
    "$proc_root/late/sys/fs/binfmt_misc" \
    "$proc_root/kernel/sys/kernel" "$proc_root/linux/sys/kernel"
  : > "$proc_root/interop/sys/fs/binfmt_misc/WSLInterop"
  : > "$proc_root/late/sys/fs/binfmt_misc/WSLInterop-late"
  printf '6.6.87.2-microsoft-standard-WSL2\n' > "$proc_root/kernel/sys/kernel/osrelease"
  printf '6.8.0-45-generic\n' > "$proc_root/linux/sys/kernel/osrelease"
  export PROC_FIXTURES="$proc_root"

  run run_zsh '
    unset WSL_DISTRO_NAME WSL_INTEROP
    OSTYPE=linux-gnu
    local -a results=()
    local fixture
    for fixture in interop late kernel linux missing; do
      if _git_is_wsl "$PROC_FIXTURES/$fixture"; then
        results+=("$fixture=wsl")
      else
        results+=("$fixture=linux")
      fi
    done
    WSL_DISTRO_NAME=Ubuntu _git_is_wsl "$PROC_FIXTURES/linux" && results+=(env=wsl)
    OSTYPE=darwin24.0 WSL_DISTRO_NAME=Ubuntu _git_is_wsl "$PROC_FIXTURES/interop" \
      && results+=(darwin=wsl)

    _git_is_wsl() { return 0; }
    local candidate
    for candidate in /mnt/c /mnt/c/Users/jane/repo /mnt/D/work /mnt/cdrom/x \
      /home/jane/repo /mnt; do
      _git_wsl_drive_path "$candidate" && results+=("drive:$candidate")
    done
    _git_is_wsl() { return 1; }
    _git_wsl_drive_path /mnt/c/Users/jane/repo && results+=("drive-off-wsl")
    print -r -- "${(j: :)results}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "interop=wsl late=wsl kernel=wsl linux=linux missing=linux env=wsl drive:/mnt/c drive:/mnt/c/Users/jane/repo drive:/mnt/D/work" ]
}

@test "git platform: a Windows-drive repository gets the cheap badge and one advisory" {
  run run_zsh "$(platform_repo)"'
    mkdir -p scratch/deep
    print -r -- one > scratch/one.txt
    print -r -- two > scratch/deep/two.txt
    print -r -- three > top.txt
    local stat_before="$(whence -w stat)"
    export MOCK_FZF_MODE=cancel MOCK_FZF_STATUS=130

    git-menu >"$HOME/linux.stdout" 2>"$HOME/linux.stderr" || return 10
    command cp "$MOCK_FZF_ARGS_FILE" "$HOME/linux.args"
    : >| "$MOCK_FZF_ARGS_FILE"
    git-status >"$HOME/linux-status.stdout" 2>"$HOME/linux-status.stderr" || return 11

    _git_wsl_drive_path() { return 0; }
    git-menu >"$HOME/drive.stdout" 2>"$HOME/drive.stderr" || return 12
    git-status >"$HOME/drive-status.stdout" 2>"$HOME/drive-status.stderr" || return 13
    [[ "$(whence -w stat)" == "$stat_before" ]] || return 14
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Changes: 3" "$HOME/linux.args"
  grep -Fq "Changes: 2" "$MOCK_FZF_ARGS_FILE"
  ! grep -Fq "Windows drive" "$HOME/linux.stderr" || false
  ! grep -Fq "Windows drive" "$HOME/linux-status.stderr" || false
  [ "$(grep -c "This repository is on a Windows drive" "$HOME/drive.stderr")" -eq 1 ]
  grep -Fq "core.autocrlf" "$HOME/drive.stderr"
  grep -Fq "This repository is on a Windows drive" "$HOME/drive-status.stderr"
  [ ! -s "$HOME/drive.stdout" ]
  [ ! -s "$HOME/drive-status.stdout" ]
}

@test "git platform: the menu scans PATH once for a missing dependency" {
  run run_zsh "$(platform_repo)"'
    # A missing command scans every PATH directory, which is slow when WSL
    # appends the Windows PATH; the menu must not repeat that per row.
    _git_check_cmd() {
      print -r -- "$1" >>"$HOME/dependency-probes"
      [[ "$1" != gh ]] && builtin command -v "$1" >/dev/null 2>&1
    }
    export MOCK_FZF_MODE=cancel MOCK_FZF_STATUS=130
    git-menu >"$HOME/menu.stdout" 2>"$HOME/menu.stderr" || return 10
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$(grep -cx gh "$HOME/dependency-probes")" -eq 1 ]
  [ "$(grep -cx fzf "$HOME/dependency-probes")" -eq 1 ]
  grep -Fq "GitHub CLI: missing" "$MOCK_FZF_ARGS_FILE"
  [ "$(grep -c '(missing: gh)|git-pr-' "$MOCK_FZF_INPUT_FILE")" -eq 2 ]
}

@test "git platform: PR creation resolves host aliases with the SSH program Git uses" {
  command cp "$TEST_SUITE_ROOT/test/fixtures/git-gh-default-branch" "$TEST_MOCK_BIN/gh"
  command chmod +x "$TEST_MOCK_BIN/gh"
  # Windows OpenSSH reads the Windows SSH configuration and writes CRLF lines.
  local program
  for program in ssh.exe ssh-env ssh-program; do
    cat > "$TEST_MOCK_BIN/$program" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "$program \$*" >> "\$HOME/ssh-calls"
[[ " \$* " == *" -G "* ]] || exit 97
case "\${*: -1}" in
  github-work) printf 'user git\r\nhostname github.com\r\nport 22\r\n' ;;
  *) printf 'hostname %s\r\n' "\${1:-}" ;;
esac
MOCK
    chmod +x "$TEST_MOCK_BIN/$program"
  done
  printf '#!/usr/bin/env bash\nprintf "plink %%s\\n" "$*" >> "$HOME/ssh-calls"\nexit 97\n' \
    > "$TEST_MOCK_BIN/plink"
  chmod +x "$TEST_MOCK_BIN/plink"

  run run_zsh "$(platform_repo)"'
    command git remote add origin "git@github-work:example/repository.git"
    command git config branch.main.remote origin
    command git config branch.main.merge refs/heads/main
    _git_gh_repo_context() {
      typeset -gA _GIT_GH_REPO=(
        target "github.com/example/repository"
        id "R_test"
        host "github.com"
        name "example/repository"
        url "https://github.com/example/repository"
      )
    }
    _git_gh_base_oid() { REPLY="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; }
    _git_gh_remote_head_oid() { REPLY=""; }

    git-pr-create --base main --fill --dry-run \
      >"$HOME/default.stdout" 2>"$HOME/default.stderr" && return 10

    command git config core.sshCommand "ssh.exe -o BatchMode=yes"
    git-pr-create --base main --fill --dry-run \
      >"$HOME/config.stdout" 2>"$HOME/config.stderr" || return 11

    local -a hosts=()
    GIT_SSH_COMMAND=ssh-env _git_gh_ssh_hostname github-work
    hosts+=("$REPLY")
    command git config --unset core.sshCommand
    GIT_SSH=ssh-program _git_gh_ssh_hostname github-work
    hosts+=("$REPLY")
    GIT_SSH=plink _git_gh_ssh_hostname github-work
    hosts+=("$REPLY")
    print -r -- "${(j: :)hosts}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "github.com github.com github-work" ]
  grep -Fq "targets github-work/example/repository" "$HOME/default.stderr"
  ! grep -Fq "targets github-work" "$HOME/config.stderr" || false
  grep -Fq "Dry run complete" "$HOME/config.stderr"
  grep -Fxq "ssh.exe -o BatchMode=yes -G -- github-work" "$HOME/ssh-calls"
  grep -Fxq "ssh-env -G -- github-work" "$HOME/ssh-calls"
  grep -Fxq "ssh-program -G -- github-work" "$HOME/ssh-calls"
  ! grep -Fq "plink" "$HOME/ssh-calls" || false
}

@test "git platform: a CRLF workspace hostname file is read as its hostname" {
  run run_zsh '
    local workspace="$WS_BASE_DIR/gitlab/work"
    mkdir -p "$workspace" || return 1
    printf "gitlab.example.com\r\n" > "$workspace/.ws-hostname"
    command git init -q "$workspace/repository" || return 2
    cd "$workspace/repository" || return 3
    print -r -- "$(_git_hostname gitlab "$workspace")"
    git-auth >"$HOME/auth.stdout" 2>"$HOME/auth.stderr" || return 4
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "gitlab.example.com" ]
  grep -Eq "Host:[[:space:]]+gitlab\.example\.com$" "$HOME/auth.stderr"
  [ ! -s "$HOME/auth.stdout" ]
}

# --- macOS and Git releases ---------------------------------------------------

@test "git platform: the macOS Command Line Tools placeholder is reported without being run" {
  printf '#!/usr/bin/env bash\necho "xcode-select: error: no developer tools" >&2\nexit 2\n' \
    > "$TEST_MOCK_BIN/xcode-select"
  chmod +x "$TEST_MOCK_BIN/xcode-select"

  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q "$repo_dir" || return 1
    mkdir "$repo_dir/sub" && cd "$repo_dir/sub" || return 2
    _git_path_command_needs_root && print -r -- "root=${REPLY:t}"
    OSTYPE=darwin23.0
    hash git=/usr/bin/git
    # Path commands probe the repository root before parsing; that probe
    # must not run the placeholder either.
    _git_path_command_needs_root || print -r -- "placeholder-not-run"
    git-status >"$HOME/status.stdout" 2>"$HOME/status.stderr" && return 10
    git-menu >"$HOME/menu.stdout" 2>"$HOME/menu.stderr" && return 11
    git-discard --all --dry-run >"$HOME/discard.stdout" 2>"$HOME/discard.stderr" && return 12
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = $'root=repository\nplaceholder-not-run' ]
  grep -Fq "/usr/bin/git is the Apple Command Line Tools placeholder" "$HOME/discard.stderr"
  grep -Fq "/usr/bin/git is the Apple Command Line Tools placeholder" "$HOME/status.stderr"
  grep -Fq "xcode-select --install" "$HOME/status.stderr"
  grep -Fq "brew install git" "$HOME/status.stderr"
  ! grep -Fq "Not inside a Git worktree" "$HOME/status.stderr" || false
  grep -Fq "/usr/bin/git is the Apple Command Line Tools placeholder" "$HOME/menu.stderr"
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]
  [ ! -s "$HOME/status.stdout" ]
  [ ! -s "$HOME/menu.stdout" ]
}

@test "git platform: the placeholder check applies only to Apple's /usr/bin/git without tools" {
  local developer_dir="$TEST_TEMP_DIR/CommandLineTools"
  mkdir -p "$developer_dir"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$XCODE_FIXTURE_DIR"\n' \
    > "$TEST_MOCK_BIN/xcode-select"
  chmod +x "$TEST_MOCK_BIN/xcode-select"
  export XCODE_FIXTURE_DIR="$developer_dir"

  run run_zsh '
    local -a results=()
    OSTYPE=darwin23.0
    _git_clt_placeholder /usr/bin/git || results+=(installed)
    _git_clt_placeholder /opt/homebrew/bin/git || results+=(homebrew)
    XCODE_FIXTURE_DIR="$HOME/missing-tools"
    _git_clt_placeholder /usr/bin/git && results+=(missing-directory)
    OSTYPE=linux-gnu
    _git_clt_placeholder /usr/bin/git || results+=(linux)
    print -r -- "${(j: :)results}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "installed homebrew missing-directory linux" ]
}

@test "git platform: Git older than 2.31 or one that fails to run is refused with guidance" {
  local fake
  for fake in old broken current; do
    {
      printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s\\n" "$*" >> "$HOME/%s-git.calls"\n' "$fake"
      case "$fake" in
        old) printf 'printf "git version 2.25.1\\n"\n' ;;
        broken) printf 'exit 69\n' ;;
        current) printf 'printf "git version 2.31.0.windows.1\\n"\n' ;;
      esac
    } > "$TEST_TEMP_DIR/$fake-git"
    chmod +x "$TEST_TEMP_DIR/$fake-git"
  done
  export FAKE_GIT_DIR="$TEST_TEMP_DIR"

  run run_zsh '
    OSTYPE=linux-gnu
    hash git="$FAKE_GIT_DIR/old-git"
    git-status >"$HOME/old.stdout" 2>"$HOME/old.stderr" && return 10
    hash git="$FAKE_GIT_DIR/broken-git"
    git-stash save --yes >"$HOME/broken.stdout" 2>"$HOME/broken.stderr" && return 11

    hash git="$FAKE_GIT_DIR/current-git"
    _git_require_git 2>"$HOME/current.stderr" || return 12
    _git_require_git 2>>"$HOME/current.stderr" || return 13
    print -r -- "# changed" >> "$FAKE_GIT_DIR/current-git"
    _git_require_git 2>>"$HOME/current.stderr" || return 14
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Git 2.31 or newer is required; $TEST_TEMP_DIR/old-git is Git 2.25.1." \
    "$HOME/old.stderr"
  grep -Fq "Install Git 2.31 or newer with your platform package manager" "$HOME/old.stderr"
  ! grep -Fq "Not inside a Git worktree" "$HOME/old.stderr" || false
  grep -Fq "did not run (git --version exit 69)" "$HOME/broken.stderr"
  [ ! -s "$HOME/current.stderr" ]
  [ "$(grep -c -- '--version' "$HOME/current-git.calls")" -eq 2 ]
  [ "$(grep -c -- '--version' "$HOME/old-git.calls")" -eq 1 ]
}

# --- Signing ------------------------------------------------------------------

@test "git platform: signed tags get GPG_TTY from the terminal when it is unset" {
  cat > "$TEST_TEMP_DIR/fake-gpg" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${GPG_TTY-unset}" >> "$HOME/gpg-tty.log"
cat > /dev/null
printf '\n[GNUPG:] SIG_CREATED D 1 8 00 1700000000 0123456789ABCDEF\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\n\nZmFrZQ==\n-----END PGP SIGNATURE-----\n'
MOCK
  chmod +x "$TEST_TEMP_DIR/fake-gpg"
  export FAKE_GPG="$TEST_TEMP_DIR/fake-gpg"

  run run_zsh "$(platform_repo)"'
    unset GPG_TTY
    command git config gpg.program "$FAKE_GPG"
    command git config user.signingkey 0123456789ABCDEF

    git-tag-create --name piped --signed --message piped --yes \
      >"$HOME/piped.stdout" 2>"$HOME/piped.stderr" || return 10
    GPG_TTY=/dev/preset git-tag-create --name preset --signed --message preset --yes \
      >"$HOME/preset.stdout" 2>"$HOME/preset.stderr" || return 11

    _git_sign_in_terminal() {
      git-tag-create --name terminal --signed --message terminal --yes
      print -r -- "SIGN_STATUS:$?"
    }
    zmodload zsh/zpty || return 12
    zpty signer _git_sign_in_terminal || return 13
    local chunk=""
    while zpty -r signer chunk 2>/dev/null; do
      print -rn -- "$chunk" >>"$HOME/terminal.log"
    done
    zpty -d signer 2>/dev/null || true
    command grep -q "SIGN_STATUS:0" "$HOME/terminal.log" || return 14
    command git show-ref --verify --quiet refs/tags/terminal || return 15
  '

  [ "$status" -eq 0 ] || { show_failure; cat "$HOME/terminal.log" >&2 2>/dev/null; false; }
  [ "$(sed -n 1p "$HOME/gpg-tty.log")" = "unset" ]
  [ "$(sed -n 2p "$HOME/gpg-tty.log")" = "/dev/preset" ]
  [[ "$(sed -n 3p "$HOME/gpg-tty.log")" == /dev/?* ]]
  [ "$(sed -n 3p "$HOME/gpg-tty.log")" != "/dev/preset" ]
}
