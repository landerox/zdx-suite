#!/usr/bin/env bats
# Quoted programs are passed literally to the isolated Zsh process.
# BATS gives each test its own exported mock controls.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

run_interrupted_system_update() {
  run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh"
    _sys_update_step_requires_privilege() { return 1; }
    update-brew() { print -r -- brew >>"$HOME/update.calls"; }
    _sys_update_ai_tools() {
      print -r -- ai >>"$HOME/update.calls"
      _SYS_UPDATE_STEP_FAILURE_DETAILS=("Codex CLI: updater failed (status $SYS_INTERRUPT_STATUS)")
      return "$SYS_INTERRUPT_STATUS"
    }
    update-repomix() { print -r -- repomix >>"$HOME/update.calls"; }
    update-omz() { print -r -- omz >>"$HOME/update.calls"; }
    update-zsh-plugins() { print -r -- plugins >>"$HOME/update.calls"; }
    _sys_update_run "$SYS_FAIL_FAST" 1 0 0 \
      "Homebrew;update-brew" "AI assistants;_sys_update_ai_tools" \
      "Repomix CLI;update-repomix" "Oh My Zsh;update-omz" \
      "Zsh Plugins;update-zsh-plugins"
  '
}

@test "sys update interruptions: INT stops independent updates without fail-fast" {
  export SYS_INTERRUPT_STATUS=130 SYS_FAIL_FAST=0
  run run_interrupted_system_update

  [ "$status" -eq 130 ]
  [ "$(cat "$HOME/update.calls")" = $'brew\nai' ]
  [[ "$output" == *"System update interrupted (status 130): AI assistants"* ]]
  [[ "$output" == *"Stopped at 2 of 5 steps"* ]]
  [[ "$output" == *"Core package steps: 1/1 succeeded"* ]]
  [[ "$output" == *"Optional tool steps: 0/4 succeeded; 1 failed; 3 not run"* ]]
  [[ "$output" != *"--fail-fast"* ]]
  [[ "$output" != *"completed with partial failures"* ]]
}

@test "sys update interruptions: TERM preserves its status even when fail-fast was requested" {
  export SYS_INTERRUPT_STATUS=143 SYS_FAIL_FAST=1
  run run_interrupted_system_update

  [ "$status" -eq 143 ]
  [ "$(cat "$HOME/update.calls")" = $'brew\nai' ]
  [[ "$output" == *"System update interrupted (status 143): AI assistants"* ]]
  [[ "$output" == *"Optional tool steps: 0/4 succeeded; 1 failed; 3 not run"* ]]
  [[ "$output" != *"Aborting after first failure (--fail-fast)"* ]]
}
