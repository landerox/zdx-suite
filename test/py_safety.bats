#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "py safety: create never replaces an existing .venv" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project/.venv"
    print -r -- "version = 3.12.1" >"$project/.venv/pyvenv.cfg"
    cd "$project" || return 1
    uv() {
      print -r -- called >"$HOME/uv-called"
      return 0
    }
    venv-create --uv --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$HOME/project/.venv/pyvenv.cfg" ]
  [ ! -e "$HOME/uv-called" ]
  [[ "$output" == *"create never replaces an existing path"* ]]
}

@test "py safety: create dry-run plans without invoking a backend" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project"
    cd "$project" || return 1
    uv() {
      print -r -- called >"$HOME/uv-called"
      return 0
    }
    venv-create --uv --python 3.12 --dry-run
  '

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/project/.venv" ]
  [ ! -e "$HOME/uv-called" ]
}

@test "py safety: non-interactive create fails closed without --yes" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project"
    cd "$project" || return 1
    uv() {
      print -r -- called >"$HOME/uv-called"
      return 0
    }
    venv-create --uv
  ' < /dev/null

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/project/.venv" ]
  [ ! -e "$HOME/uv-called" ]
}

@test "py safety: remove rejects external environments and preserves them" {
  run run_zsh '
    local project="$HOME/project"
    local external="$HOME/external"
    command mkdir -p "$project" "$external"
    print -r -- "version = 3.12.1" >"$external/pyvenv.cfg"
    cd "$project" || return 1
    venv-remove --path "$external" --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$HOME/external/pyvenv.cfg" ]
  [[ "$output" == *"not in the validated discovery snapshot"* ]]
}

@test "py safety: remove dry-run preserves a fingerprinted local environment" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project/.venv"
    print -r -- "version = 3.12.1" >"$project/.venv/pyvenv.cfg"
    cd "$project" || return 1
    venv-remove --path "$project/.venv" --dry-run
  '

  [ "$status" -eq 0 ]
  [ -f "$HOME/project/.venv/pyvenv.cfg" ]
}

@test "py safety: rebuild is fail-closed even with --yes" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project/.venv"
    print -r -- "version = 3.12.1" >"$project/.venv/pyvenv.cfg"
    cd "$project" || return 1
    venv-rebuild --path "$project/.venv" --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$HOME/project/.venv/pyvenv.cfg" ]
  [[ "$output" == *"Automatic rebuild is disabled"* ]]
  [[ "$output" == *"No files were changed"* ]]
}

@test "py safety: activation revalidates script content after confirmation" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project/.venv/bin"
    print -r -- "version = 3.12.1" >"$project/.venv/pyvenv.cfg"
    print -r -- "export SAFE_ACTIVATED=1" >"$project/.venv/bin/activate"
    cd "$project" || return 1
    _py_confirm() {
      print -r -- "export UNSAFE_ACTIVATED=1" >"$project/.venv/bin/activate"
      return 0
    }
    venv-activate --path "$project/.venv"
    local activate_rc=$?
    [[ -z "${SAFE_ACTIVATED:-}" && -z "${UNSAFE_ACTIVATED:-}" ]]
    return $activate_rc
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed after review"* ]]
}

@test "py safety: package operations reject option-like names before probes" {
  run run_zsh '
    uv() {
      print -r -- called >"$HOME/uv-called"
      return 0
    }
    package-install --malicious
  '

  [ "$status" -eq 2 ]
  [ ! -e "$HOME/uv-called" ]
}

@test "py safety: package install never falls back to ambient pip" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project"
    cd "$project" || return 1
    pip() {
      print -r -- called >"$HOME/pip-called"
      return 0
    }
    package-install ruff --yes
  '

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/pip-called" ]
  [[ "$output" == *"ambient pip installation is never used"* ]]
}

@test "py safety: remote tool install supports a side-effect-free dry-run" {
  run run_zsh '
    uv() {
      print -r -- "$*" >"$HOME/uv-called"
      return 0
    }
    tool-install ruff --backend uv --dry-run
  '

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/uv-called" ]
  [[ "$output" == *"downloads and installs executable package code"* ]]
}

@test "py safety: invalid Python versions fail before uv is invoked" {
  run run_zsh '
    uv() {
      print -r -- called >"$HOME/uv-called"
      return 0
    }
    venv-python-install "../3.12" --yes
  '

  [ "$status" -eq 2 ]
  [ ! -e "$HOME/uv-called" ]
}
