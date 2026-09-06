#!/usr/bin/env bats
# Quoted programs are passed literally to the isolated Zsh process.
# shellcheck disable=SC2016

setup() {
  load test_helper
  export DEV_PROJECT="$HOME/project"
  mkdir -p "$DEV_PROJECT"
}

teardown() {
  cleanup_sandbox
}

@test "dev update dispatch: missing uv does not block Terraform inspection or cleanup" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/dev-menu.zsh"
    cd "$DEV_PROJECT"
    command() {
      if [[ "$1" == "-v" ]]; then
        case "$2" in
          uv|tflint) return 1 ;;
          terraform) return 0 ;;
        esac
      fi
      builtin command "$@"
    }
    dev-update-toolchain() {
      _dev_error "Host uv is unavailable."
      return 1
    }
    _dev_detect_terraform_manager() { print -r -- apt; }
    _dev_pypi_check_connectivity() {
      _dev_error "UNEXPECTED_NETWORK_PROBE"
      return 97
    }
    dev-menu dev-update-all --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Host uv is unavailable."* ]]
  [[ "$output" == *"Managed by APT."* ]]
  [[ "$output" == *"Cleaning All Project Artifacts"* ]]
  [[ "$output" != *"Missing required dependency:"* ]]
  [[ "$output" != *"UNEXPECTED_NETWORK_PROBE"* ]]
}

@test "dev update dispatch: a lockfile update still requires its own uv backend" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/dev-menu.zsh"
    cd "$DEV_PROJECT"
    command() {
      [[ "$1" == "-v" && "$2" == "uv" ]] && return 1
      builtin command "$@"
    }
    dev-menu dev-update-lock
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required dependency: uv"* ]]
  [[ "$output" == *"dev-update-lock"* ]]
}

@test "dev update dispatch: maintenance help and invalid flags never probe backends" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/dev-menu.zsh"
    command() {
      print -u2 -r -- "UNEXPECTED_BACKEND_PROBE:$*"
      return 97
    }
    dev-menu dev-update-all --help
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: dev-update-all"* ]]
  [[ "$output" != *"UNEXPECTED_BACKEND_PROBE"* ]]

  run run_zsh '
    source "$ZSH_CUSTOM/functions/dev-menu.zsh"
    command() {
      print -u2 -r -- "UNEXPECTED_BACKEND_PROBE:$*"
      return 97
    }
    dev-menu dev-update-all --unknown
  '

  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --unknown"* ]]
  [[ "$output" != *"UNEXPECTED_BACKEND_PROBE"* ]]
}
