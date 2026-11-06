#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export OWN_LOG="$HOME/tool-execution.log" OWN_PULL_LOG="$HOME/pulls.log"
  export OWN_PREFIX="$HOME/homebrew" OWN_BREW_INSTALLED=1 OWN_WSL_TOOL=""
  : > "$OWN_LOG"
  : > "$OWN_PULL_LOG"
  mkdir -p "$OWN_PREFIX/Cellar" "$HOME/.cargo/bin" "$HOME/.cache/uv" \
    "$HOME/.cache/go/pkg/mod/cache/download"
  cat > "$HOME/tool-program" <<'MOCK'
#!/usr/bin/env bash
tool=${0##*/}
case "$tool:$*" in
  'brew:--version') printf 'Homebrew 4.5.0\n'; exit 0 ;;
  'cargo:--version') printf 'cargo 1.80.0\n'; exit 0 ;;
  'brew:--prefix') printf '%s\n' "$OWN_PREFIX"; exit 0 ;;
  'brew:list awscli'|'brew:list starship') [[ "$OWN_BREW_INSTALLED" == 1 ]]; exit $? ;;
  'brew:list fzf') exit 1 ;;
  'aws:--version') printf 'aws-cli/2.30.0 Python/3.12\n' ;;
  'starship:--version') printf 'starship 1.20.0\n' ;;
  'fzf:--version') printf '0.99.0 (fixture)\n' ;;
  'uv:cache dir') printf '%s\n' "$HOME/.cache/uv" ;;
  'go:env GOMODCACHE') printf '%s\n' "$HOME/.cache/go/pkg/mod" ;;
  'cargo:install --list') printf 'starship v1.20.0:\n' ;;
  'brew:upgrade --no-ask awscli'|'brew:upgrade --no-ask starship'|'cargo:install --locked starship') ;;
  *) exit 97 ;;
esac
printf '%s %s\n' "$tool" "$*" >> "$OWN_LOG"
exit 0
MOCK
  local tool
  for tool in aws starship uv go cargo brew; do
    cp "$HOME/tool-program" "$TEST_MOCK_BIN/$tool"
    chmod -- 700 "$TEST_MOCK_BIN/$tool"
  done
  printf '#!/bin/sh\nexit 1\n' > "$TEST_MOCK_BIN/dpkg"
  printf '#!/bin/sh\nexit 1\n' > "$TEST_MOCK_BIN/snap"
  chmod -- 700 "$TEST_MOCK_BIN/dpkg" "$TEST_MOCK_BIN/snap"
  cat > "$HOME/ownership-context.zsh" <<'ZSH'
emulate -R zsh
builtin cd -q -- "$TEST_TEMP_DIR" || return 90
_sys_has_capability() { [[ "$1" == environment:wsl && -n "$OWN_WSL_TOOL" ]]; }
_sys_capabilities_refresh() { return 0; }
_sys_wsl_windows_program() { [[ "${1:t}" == "$OWN_WSL_TOOL" ]]; }
_sys_clean_protected_roots() { reply=(); }
_sys_clean_running_executables() { reply=(); }
command() {
  if [[ "$1" == -v ]]; then
    case "${2:-}" in npm|pip|pip3|python3|pre-commit|rustup) return 1 ;; esac
  fi
  builtin command "$@"
}
_sys_update_git_logged() {
  print -r -- "$*" >> "$OWN_PULL_LOG"
  return 0
}
ZSH
}

teardown() {
  cleanup_sandbox
}

ownership_git_checkout() {
  local repository="$1"
  mkdir -p "$repository/bin"
  git init -q -b main "$repository"
  git -C "$repository" config user.name "Ownership Test"
  git -C "$repository" config user.email ownership@example.invalid
  git -C "$repository" config commit.gpgSign false
  git -C "$repository" config core.hooksPath /dev/null
  printf '%s\n' fixture > "$repository/README"
  git -C "$repository" add README
  git -C "$repository" commit -qm base
  git -C "$repository" remote add origin https://example.invalid/fzf.git
  cp "$HOME/tool-program" "$repository/bin/fzf"
  chmod -- 700 "$repository/bin/fzf"
}

ownership_failure() {
  printf 'status=%s output=%s\n' "$status" "$output" >&2
  cat "$OWN_LOG" "$OWN_PULL_LOG" >&2
  false
}

@test "sys active ownership: fzf selects the second checkout that owns the active executable" {
  ownership_git_checkout "$HOME/.fzf"
  ownership_git_checkout "$HOME/.local/share/fzf"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/.local/share/fzf/bin" $path)
    update-fzf --dry-run
  '
  [ "$status" -eq 0 ] || ownership_failure
  [[ "$output" == *"Repository:"*"~/.local/share/fzf"* ]]
  [ ! -s "$OWN_PULL_LOG" ]
}

@test "sys active ownership: fzf updates only the active checkout" {
  ownership_git_checkout "$HOME/.fzf"
  ownership_git_checkout "$HOME/.local/share/fzf"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/.local/share/fzf/bin" $path)
    # Release integrity is covered by its complete fixture; this control owns
    # active-checkout routing and keeps the real pre/post ownership guards.
    _sys_update_fzf_verified_release() { return 0; }
    update-fzf --yes
  '
  [ "$status" -eq 0 ] || ownership_failure
  [ "$(cat "$OWN_PULL_LOG")" = "-C $HOME/.local/share/fzf pull --ff-only origin" ]
}

@test "sys active ownership: unrelated fzf never updates a discovered inactive checkout" {
  ownership_git_checkout "$HOME/.fzf"
  mkdir -p "$HOME/independent/bin"
  cp "$HOME/tool-program" "$HOME/independent/bin/fzf"
  chmod -- 700 "$HOME/independent/bin/fzf"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/independent/bin" $path)
    _sys_update_fzf_applies && exit 91
    update-fzf --yes
  '
  [ "$status" -eq 0 ] || ownership_failure
  [ ! -s "$OWN_PULL_LOG" ]
  [[ "$output" == *"owner"* ]]
}

@test "sys active ownership: an unsafe inactive fzf checkout cannot block the active one" {
  ownership_git_checkout "$HOME/inactive-fzf"
  ln -s "$HOME/inactive-fzf" "$HOME/.fzf"
  ownership_git_checkout "$HOME/.local/share/fzf"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/.local/share/fzf/bin" $path)
    update-fzf --dry-run
  '
  [ "$status" -eq 0 ] || ownership_failure
  [[ "$output" == *"Repository:"*"~/.local/share/fzf"* ]]
}

@test "sys active ownership: changed active fzf target blocks the reviewed pull" {
  ownership_git_checkout "$HOME/.fzf"
  mkdir -p "$HOME/launchers" "$HOME/outside"
  cp "$HOME/tool-program" "$HOME/outside/fzf"
  chmod -- 700 "$HOME/outside/fzf"
  ln -s "$HOME/.fzf/bin/fzf" "$HOME/launchers/fzf"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/launchers" $path)
    functions[_ownership_revalidate]="${functions[_sys_update_git_revalidate]}"
    _sys_update_git_revalidate() {
      command ln -sfn "$HOME/outside/fzf" "$HOME/launchers/fzf" || return 91
      _ownership_revalidate "$@"
    }
    update-fzf --yes
  '
  [ "$status" -eq 1 ] || ownership_failure
  [ ! -s "$OWN_PULL_LOG" ]
}

@test "sys active ownership: inactive Homebrew AWS formula never owns an independent executable" {
  run run_zsh 'source "$HOME/ownership-context.zsh" || exit 90; update-awscli --yes'
  [ "$status" -eq 1 ] || ownership_failure
  run grep -F 'brew upgrade' "$OWN_LOG"
  [ "$status" -eq 1 ]
}

@test "sys active ownership: inactive Homebrew Starship formula never owns an independent executable" {
  run run_zsh 'source "$HOME/ownership-context.zsh" || exit 90; update-starship --yes'
  [ "$status" -eq 1 ] || ownership_failure
  run grep -F 'brew upgrade' "$OWN_LOG"
  [ "$status" -eq 1 ]
}

@test "sys active ownership: Cargo owns the active Starship despite an inactive Homebrew formula" {
  cp "$HOME/tool-program" "$HOME/.cargo/bin/starship"
  chmod -- 700 "$HOME/.cargo/bin/starship"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/.cargo/bin" $path)
    _sys_update_starship_applies || exit 91
    update-starship --yes
  '
  [ "$status" -eq 0 ] || ownership_failure
  grep -Fqx 'cargo install --locked starship' "$OWN_LOG"
  run grep -F 'brew upgrade' "$OWN_LOG"
  [ "$status" -eq 1 ]
}

@test "sys active ownership: Cargo inventory cannot own a different active Starship" {
  export OWN_BREW_INSTALLED=0
  run run_zsh 'source "$HOME/ownership-context.zsh" || exit 90; update-starship --yes'
  [ "$status" -eq 1 ] || ownership_failure
  run grep -F 'cargo install --locked' "$OWN_LOG"
  [ "$status" -eq 1 ]
}

@test "sys active ownership: refused AWS is never probed or delegated to an inactive formula" {
  chmod -- 777 "$TEST_MOCK_BIN/aws"
  run run_zsh 'source "$HOME/ownership-context.zsh" || exit 90; update-awscli --yes'
  [ "$status" -eq 1 ] || ownership_failure
  [ ! -s "$OWN_LOG" ]
}

@test "sys active ownership: cleanup never runs refused uv or Go in a dry run" {
  local tool mode
  for tool in uv go; do
    for mode in permissions windows; do
      : > "$OWN_LOG"
      export OWN_REFUSED_TOOL="$tool"
      if [ "$mode" = permissions ]; then
        chmod -- 777 "$TEST_MOCK_BIN/$tool"
        export OWN_WSL_TOOL=""
      else
        chmod -- 700 "$TEST_MOCK_BIN/$tool"
        export OWN_WSL_TOOL="$tool"
      fi
      run run_zsh '
        source "$HOME/ownership-context.zsh" || exit 90
        clean-system --deep --dry-run
      '
      [ "$status" -eq 0 ] || ownership_failure
      run grep -F "$tool " "$OWN_LOG"
      [ "$status" -eq 1 ]
      chmod -- 700 "$TEST_MOCK_BIN/$tool"
    done
  done
}

@test "sys active ownership: canonical Homebrew AWS and Starship executables use their formula owner" {
  local tool formula
  for tool in aws starship; do
    formula="$tool"
    [ "$tool" != aws ] || formula=awscli
    # AWS's formula uses libexec/bin; a symlinked launcher must resolve here.
    mkdir -p "$OWN_PREFIX/Cellar/$formula/1.0/libexec/bin" "$OWN_PREFIX/bin"
    cp "$HOME/tool-program" "$OWN_PREFIX/Cellar/$formula/1.0/libexec/bin/$tool"
    chmod -- 700 "$OWN_PREFIX/Cellar/$formula/1.0/libexec/bin/$tool"
    ln -s "$OWN_PREFIX/Cellar/$formula/1.0/libexec/bin/$tool" "$OWN_PREFIX/bin/$tool"
  done
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$OWN_PREFIX/bin" $path)
    _sys_update_starship_applies && exit 91
    update-awscli --yes || exit $?
    update-starship --yes
  '
  [ "$status" -eq 0 ] || ownership_failure
  grep -Fqx 'brew upgrade --no-ask awscli' "$OWN_LOG"
  grep -Fqx 'brew upgrade --no-ask starship' "$OWN_LOG"
  run grep -F 'cargo install' "$OWN_LOG"
  [ "$status" -eq 1 ]
}

@test "sys active ownership: a formula executable without installed formula evidence is not owned" {
  export OWN_BREW_INSTALLED=0
  mkdir -p "$OWN_PREFIX/Cellar/starship/1.0/bin"
  cp "$HOME/tool-program" "$OWN_PREFIX/Cellar/starship/1.0/bin/starship"
  chmod -- 700 "$OWN_PREFIX/Cellar/starship/1.0/bin/starship"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$OWN_PREFIX/Cellar/starship/1.0/bin" $path)
    _sys_update_starship_applies && exit 91
    update-starship --yes
  '
  [ "$status" -eq 1 ] || ownership_failure
  [ ! -s "$OWN_LOG" ]
}

@test "sys active ownership: changed active fzf bytes block the reviewed pull" {
  ownership_git_checkout "$HOME/.fzf"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/.fzf/bin" $path)
    functions[_ownership_revalidate]="${functions[_sys_update_git_revalidate]}"
    _sys_update_git_revalidate() {
      print -r -- "# changed after plan" >> "$HOME/.fzf/bin/fzf"
      _ownership_revalidate "$@"
    }
    update-fzf --yes
  '
  [ "$status" -eq 1 ] || ownership_failure
  [ ! -s "$OWN_PULL_LOG" ]
}

@test "sys active ownership: refused Cargo and rustup never contribute cleanup targets" {
  mkdir -p "$HOME/.cargo/registry/cache" "$HOME/.rustup/downloads"
  cp "$HOME/tool-program" "$TEST_MOCK_BIN/rustup"
  # The context hides rustup by default; this case restores the real resolver.
  for tool in cargo rustup; do
    chmod -- 777 "$TEST_MOCK_BIN/$tool"
  done
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    command() { builtin command "$@"; }
    _sys_clean_plan deep
  '
  [ "$status" -eq 0 ] || ownership_failure
  [[ "$output" != *"Cargo registry cache"* ]]
  [[ "$output" != *"Rust downloads"* ]]
  run grep -E '^(cargo|rustup) ' "$OWN_LOG"
  [ "$status" -eq 1 ]
}

@test "sys active ownership: refused Starship or Cargo cannot authorize an owner probe" {
  cp "$HOME/tool-program" "$HOME/.cargo/bin/starship"
  chmod -- 700 "$HOME/.cargo/bin/starship"
  local tool
  for tool in starship cargo; do
    : > "$OWN_LOG"
    if [ "$tool" = starship ]; then
      chmod -- 777 "$HOME/.cargo/bin/starship"
    else
      chmod -- 700 "$HOME/.cargo/bin/starship"
      chmod -- 777 "$TEST_MOCK_BIN/cargo"
    fi
    run run_zsh '
      source "$HOME/ownership-context.zsh" || exit 90
      path=("$HOME/.cargo/bin" $path)
      update-starship --yes
    '
    [ "$status" -eq 1 ] || ownership_failure
    [ ! -s "$OWN_LOG" ]
  done
}

@test "sys active ownership: refused fzf is never probed or pulled" {
  ownership_git_checkout "$HOME/.fzf"
  chmod -- 777 "$HOME/.fzf/bin/fzf"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/.fzf/bin" $path)
    _sys_update_fzf_applies || exit 91
    update-fzf --yes
  '
  [ "$status" -eq 1 ] || ownership_failure
  [ ! -s "$OWN_LOG" ]
  [ ! -s "$OWN_PULL_LOG" ]
}

@test "sys active ownership: standalone loader binds the active fzf checkout" {
  ownership_git_checkout "$HOME/.fzf"
  ownership_git_checkout "$HOME/.local/share/fzf"
  run zsh -f -c '
    emulate -R zsh
    source "$TEST_SUITE_ROOT/functions/sys-menu.zsh" || exit 90
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/.local/share/fzf/bin" $path)
    update-fzf --dry-run
  '
  [ "$status" -eq 0 ] || ownership_failure
  [[ "$output" == *"Repository:"*"~/.local/share/fzf"* ]]
  [ ! -s "$OWN_PULL_LOG" ]
}

@test "sys active ownership: a writable Homebrew manager cannot run ownership probes" {
  mkdir -p "$OWN_PREFIX/Cellar/starship/1.0/bin"
  cp "$HOME/tool-program" "$OWN_PREFIX/Cellar/starship/1.0/bin/starship"
  chmod -- 700 "$OWN_PREFIX/Cellar/starship/1.0/bin/starship"
  cat > "$TEST_MOCK_BIN/brew" <<'MOCK'
#!/usr/bin/env bash
printf 'brew %s\n' "$*" >> "$OWN_LOG"
case "$*" in
  --prefix) printf '%s\n' "$OWN_PREFIX" ;;
  'list starship'|'upgrade --no-ask starship') ;;
  *) exit 97 ;;
esac
MOCK
  chmod -- 770 "$TEST_MOCK_BIN/brew"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$OWN_PREFIX/Cellar/starship/1.0/bin" $path)
    update-starship --yes
  '
  [ "$status" -eq 1 ] || ownership_failure
  [ ! -s "$OWN_LOG" ]
}

@test "sys active ownership: a writable Cargo manager cannot run its ownership inventory" {
  cp "$HOME/tool-program" "$HOME/.cargo/bin/starship"
  chmod -- 700 "$HOME/.cargo/bin/starship"
  chmod -- 770 "$TEST_MOCK_BIN/cargo"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/.cargo/bin" $path)
    update-starship --yes
  '
  [ "$status" -eq 1 ] || ownership_failure
  [ ! -s "$OWN_LOG" ]
}

@test "sys active ownership: interrupted Homebrew observation never falls through to Cargo" {
  cp "$HOME/tool-program" "$HOME/.cargo/bin/starship"
  chmod -- 700 "$HOME/.cargo/bin/starship"
  local observation_rc
  for observation_rc in 130 143; do
    export OWN_OBSERVATION_RC="$observation_rc"
    : > "$OWN_LOG"
    run run_zsh '
      source "$HOME/ownership-context.zsh" || exit 90
      path=("$HOME/.cargo/bin" $path)
      _sys_update_homebrew_owns_program() { return "$OWN_OBSERVATION_RC"; }
      _sys_tool_program starship || exit 90
      _sys_update_starship_owner "$REPLY"
    '
    [ "$status" -eq "$observation_rc" ] || ownership_failure
    [ ! -s "$OWN_LOG" ]
  done
}

ownership_owner_interruption() {
  export OWN_REVIEW_COMMAND="$1" OWN_OBSERVATION_RC="$2"
  cp "$HOME/tool-program" "$HOME/.cargo/bin/starship"
  chmod -- 700 "$HOME/.cargo/bin/starship"
  cat > "$TEST_MOCK_BIN/brew" <<'MOCK'
#!/usr/bin/env bash
printf 'brew-observation %s -> %s\n' "$*" "$OWN_OBSERVATION_RC" >> "$OWN_LOG"
[[ "$*" == --prefix ]] || exit 97
exit "$OWN_OBSERVATION_RC"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/brew"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || exit 90
    path=("$HOME/.cargo/bin" $path)
    _sys_update_step_requires_privilege() { return 1; }
    update-rust() { print -r -- mutation:later >> "$OWN_LOG"; }
    _sys_update_run 0 1 0 0 "Owner;$OWN_REVIEW_COMMAND" "Rust;update-rust"
  '
  [ "$status" -eq "$OWN_OBSERVATION_RC" ] || ownership_failure
  run grep -E "^(mutation:later|aws |starship |cargo )" "$OWN_LOG"
  [ "$status" -eq 1 ] || ownership_failure
}

@test "sys active ownership: interrupted Starship owner read130 stops aggregate later mutation" {
  ownership_owner_interruption update-starship 130
}
@test "sys active ownership: interrupted Starship owner read143 stops aggregate later mutation" {
  ownership_owner_interruption update-starship 143
}
@test "sys active ownership: interrupted AWS owner read130 stops aggregate later mutation" {
  ownership_owner_interruption update-awscli 130
}
@test "sys active ownership: interrupted AWS owner read143 stops aggregate later mutation" {
  ownership_owner_interruption update-awscli 143
}

planning_owner_interrupt() {
  export OWN_OBSERVATION_RC="$1"
  cp "$HOME/tool-program" "$HOME/.cargo/bin/starship"
  chmod -- 700 "$HOME/.cargo/bin/starship"
  cat > "$TEST_MOCK_BIN/brew" <<'MOCK'
#!/usr/bin/env bash
printf 'brew-observation %s -> %s\n' "$*" "$OWN_OBSERVATION_RC" >> "$OWN_LOG"
[[ "$*" == --prefix ]] || exit 97
exit "$OWN_OBSERVATION_RC"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/brew"
  run run_zsh '
    source "$HOME/ownership-context.zsh" || return 90
    path=("$HOME/.cargo/bin" $path)
    functions[_review_original_step_applies]="${functions[_sys_step_applies]}"
    _sys_step_applies() {
      case "$1" in
        update-starship) _review_original_step_applies "$@" ;;
        update-rust) return 0 ;;
        *) return 1 ;;
      esac
    }
    _sys_update_step_requires_privilege() { return 1; }
    update-rust() { print -r -- mutation:later >> "$OWN_LOG"; return 0; }
    NO_COLOR=1 update-system --yes
  '
  printf 'public status=%s\n' "$status" >&2
  cat "$OWN_LOG" >&2
  [ "$status" -eq "$OWN_OBSERVATION_RC" ]
  run grep -Fq mutation:later "$OWN_LOG"
  [ "$status" -eq 1 ]
}

@test "sys ownership review: planning130 cannot continue to later aggregate mutation" {
  planning_owner_interrupt 130
}

@test "sys ownership review: planning143 cannot continue to later aggregate mutation" {
  planning_owner_interrupt 143
}

@test "sys active ownership: ordinary inapplicable planning still runs later applicable step" {
  run run_zsh '
    source "$HOME/ownership-context.zsh" || return 90
    _sys_step_applies() { [[ "$1" == update-rust ]]; }
    _sys_update_step_requires_privilege() { return 1; }
    update-rust() { print -r -- mutation:later >> "$OWN_LOG"; return 0; }
    NO_COLOR=1 update-system --yes
  '
  [ "$status" -eq 0 ] || ownership_failure
  run grep -Fxc mutation:later "$OWN_LOG"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}
