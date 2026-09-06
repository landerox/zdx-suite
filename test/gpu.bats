#!/usr/bin/env bats

setup() {
  load test_helper

  cat <<'EOF' > "$TEST_MOCK_BIN/nvidia-smi"
#!/usr/bin/env bash
if [[ "$*" == *"--query-gpu"* ]]; then
  printf '%s\n' \
    "55, 45, 2048, 8192, 25, 120.50, NVIDIA GeForce RTX 3070 Ti, 535.113.01"
  exit 0
fi
if [[ "$*" == *"--query-compute-apps"* ]]; then
  printf '%s\n' \
    "4321, /usr/bin/python3, 1024" \
    "9876, /usr/lib/firefox/firefox, 512"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/nvidia-smi"
}

teardown() {
  cleanup_sandbox
}

@test "gpu: entrypoint and visualizer are loaded in the eager test runtime" {
  run run_zsh '
    typeset -f gpu-menu >/dev/null
    typeset -f gpu-visualizer >/dev/null
  '
  [ "$status" -eq 0 ]
}

@test "gpu: help is stderr-only and documents explicit simulation" {
  run run_zsh '
    gpu-menu --help >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q -- "--simulate" "$HOME/stderr"
    grep -q "never selected automatically" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "gpu: direct routing forwards visualizer flags" {
  run run_zsh '
    NO_COLOR=1 gpu-menu gpu-visualizer --simulate --once \
      >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "Synthetic simulation was explicitly requested" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "gpu: missing nvidia-smi fails instead of simulating" {
  rm -f "$TEST_MOCK_BIN/nvidia-smi"

  run run_zsh '
    gpu-visualizer --once >"$HOME/stdout" 2>"$HOME/stderr"
  '
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/stdout" ]
  grep -q "nvidia-smi is required" "$HOME/stderr"
  ! grep -q "Synthetic" "$HOME/stderr"
}

@test "gpu: validated hardware records render on stderr" {
  run run_zsh '
    NO_COLOR=1 gpu-visualizer --once --gpu 0 \
      >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "NVIDIA GeForce RTX 3070 Ti" "$HOME/stderr"
    grep -q "2048 / 8192 MiB" "$HOME/stderr"
    grep -q "/usr/bin/python3" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "gpu: malformed numeric telemetry fails closed" {
  cat <<'EOF' > "$TEST_MOCK_BIN/nvidia-smi"
#!/usr/bin/env bash
if [[ "$*" == *"--query-gpu"* ]]; then
  printf '%s\n' "bad, 45, 2048, 8192, 25, 120.50, GPU, 1.0"
  exit 0
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/nvidia-smi"

  run run_zsh 'gpu-visualizer --once'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not obtain valid NVIDIA metrics"* ]]
}

@test "gpu: unknown options and dispatch tokens return status 2" {
  run run_zsh 'gpu-menu invalid-command'
  [ "$status" -eq 2 ]

  run run_zsh 'gpu-visualizer --unknown'
  [ "$status" -eq 2 ]
}

@test "gpu: menu cancellation is success and private capture is removed" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    gpu-menu
    local menu_rc=$?
    (( menu_rc == 0 )) || return 1
    local -a leftovers=("$TMPDIR"/zdx-gpu-fzf.*(N))
    (( ${#leftovers} == 0 ))
  '
  [ "$status" -eq 0 ]
}

@test "gpu: an fzf record outside the current menu snapshot is refused" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="Injected|gpu-visualizer|forged"

  run run_zsh 'gpu-menu'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the menu snapshot"* ]]
}

@test "gpu: an exact menu row with spaces dispatches without subscript parsing" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="  Monitor NVIDIA GPU|gpu-visualizer|Show NVIDIA utilization, temperature, memory, power, and running processes."

  run run_zsh '
    gpu-visualizer() {
      print -r -- "exact-gpu-route"
    }
    gpu-menu
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"exact-gpu-route"* ]]
  [[ "$output" != *"invalid subscript"* ]]
}

@test "gpu: visualizer handles TTIN and TTOU in an interactive job-control shell" {
  command -v script >/dev/null || skip "util-linux script is unavailable"

  run script -qefc \
    "zsh -fic '[[ -o monitor ]] || exit 91; source \"$TEST_SUITE_ROOT/functions/gpu-menu.zsh\" || exit; NO_COLOR=1 gpu-visualizer --simulate --once && [[ -o monitor ]]'" \
    /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Synthetic simulation was explicitly requested"* ]]
  [[ "$output" != *"can't trap SIGTTIN"* ]]
  [[ "$output" != *"can't trap SIGTTOU"* ]]
}
