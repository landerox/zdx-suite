#!/usr/bin/env bats
# Single-quoted scripts execute in Zsh; exports are isolated by BATS.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "gpu recovery: unavailable processes retain valid metrics and partial status" {
  for code in 4 124 125; do
    export GPU_RECOVERY_RC="$code"
    run run_zsh '
      _gpu_query_hardware() { reply=(55 45 2048 8192 25 120.5 "Audit GPU" 1.0); }
      _gpu_query_processes() { reply=("invalid partial data"); return "$GPU_RECOVERY_RC"; }
      gpu-visualizer --once
    '
    [ "$status" -eq "$code" ]
    [[ "$output" == *"Audit GPU"*"2048 / 8192 MiB"* ]]
    [[ "$output" == *"Process inventory unavailable"* ]]
    [[ "$output" != *"No processes currently"* ]]
    [[ "$output" != *"invalid partial data"* ]]
    [[ "$output" != *"Synthetic"* ]]
  done
}

@test "gpu recovery: process interruption exits without a synthetic or successful frame" {
  for code in 130 143; do
    export GPU_RECOVERY_RC="$code"
    run run_zsh '
      _gpu_query_hardware() { reply=(55 45 2048 8192 25 120.5 "Audit GPU" 1.0); }
      _gpu_query_processes() { return "$GPU_RECOVERY_RC"; }
      gpu-visualizer --once
    '
    [ "$status" -eq "$code" ]
    [[ "$output" != *"No processes currently"* ]]
    [[ "$output" != *"Synthetic"* ]]
  done
}

@test "gpu recovery: the next continuous frame recovers an unavailable inventory" {
  run run_zsh '
    local -i queries=0 reads=0
    _gpu_terminal_is_foreground() { return 0; }
    _gpu_query_hardware() { reply=(55 45 2048 8192 25 120.5 "Audit GPU" 1.0); }
    _gpu_query_processes() {
      (( queries < 3 )) || return 97
      (( ++queries == 1 )) && return 4
      reply=($'\''42\taudit-process\t1024'\'')
    }
    read() {
      [[ "$1" == -k ]] || { builtin read "$@"; return $?; }
      (( ++reads == 2 )) || return 1
      key=q
    }
    gpu-visualizer >"$HOME/out" 2>"$HOME/err" || return
    (( queries == 2 && reads == 2 )) || return 1
    [[ ! -s "$HOME/out" ]] || return 1
    grep -q "Process inventory unavailable" "$HOME/err" || return 1
    grep -q "audit-process" "$HOME/err"
  '
  [ "$status" -eq 0 ]
}

@test "gpu recovery: quitting after an unavailable process frame retains partial failure" {
  run run_zsh '
    _gpu_terminal_is_foreground() { return 0; }
    _gpu_query_hardware() { reply=(55 45 2048 8192 25 120.5 "Audit GPU" 1.0); }
    _gpu_query_processes() { return 4; }
    read() { key=q; }
    gpu-visualizer
  '
  [ "$status" -eq 4 ]
  [[ "$output" == *"Visual monitoring ended with unavailable process data"* ]]
  [[ "$output" != *"ended cleanly"* ]]
}
