#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "sys-doctor: --help prints help screen and exits 0" {
  run run_zsh "zdx-doctor --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ZDX Doctor - Dependency Diagnostic CLI Assistant"* ]]
}

@test "sys-doctor: diagnostic scan identifies installed vs missing packages" {
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == --version ]]; then
  printf '0.74.3 (fixture)\n'
  exit 0
fi
exit 97
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
  # Mock system binaries by ensuring fzf, git, and jq are present, but pipx and wg-quick are missing
  run zsh -c "
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$TEST_MOCK_BIN:/usr/bin:/bin'

    # Mock command command to simulate missing wg-quick and pipx
    command() {
      if [[ \"\$1\" == \"wg-quick\" || \"\$1\" == \"pipx\" || \"\$1\" == \"nvidia-smi\" ]]; then
        return 1
      fi
      builtin command \"\$@\"
    }

    source \$ZSH_CUSTOM/functions.zsh

    # Run zdx-doctor with pre-defined response (Skip installation)
    echo 'n' | zdx-doctor
  "
  [ "$status" -eq 1 ] # Exits with 1 because there are missing packages and user skipped installation
  [[ "$output" == *"ZDX Dependency Doctor Checkup"* ]]
  [[ "$output" == *"fzf - Installed"* ]]
  [[ "$output" == *"pipx - MISSING"* ]]
  [[ "$output" == *"Skipping installation"* ]]
}

@test "sys-doctor: OS and Pkg Manager detection is accurate" {
  run zsh -c "
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$TEST_MOCK_BIN:/usr/bin:/bin'

    source \$ZSH_CUSTOM/functions.zsh

    # Trigger loading of zdx-doctor
    zdx-doctor --help >/dev/null

    # Test helpers directly
    os_name=\$(_zdx_doctor_detect_os)
    pm_name=\$(_zdx_doctor_detect_pkg_manager)

    if [[ -z \"\$os_name\" || -z \"\$pm_name\" ]]; then
      echo 'FAIL: OS or package manager detection returned empty'
      exit 1
    fi

    echo \"SUCCESS: Detected OS=\$os_name, PM=\$pm_name\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: Detected OS="* ]]
}

@test "sys-doctor: Docker owns timeout and SHA-256 capability metadata" {
  local doctor_file="$TEST_SUITE_ROOT/functions/zdx-doctor.zsh"

  [ "$(grep -cF \
    '[Docker, Python, CI, Network, Hugging Face Hub & NVIDIA GPU]' \
    "$doctor_file")" -eq 2 ]
  [ "$(grep -cF \
    '[App, Docker & Environment]' "$doctor_file")" -eq 2 ]
  grep -Fq \
    'bounded Docker and suite inventories' "$doctor_file"
  grep -Fq \
    'descriptor, Docker identity, and passive-data revalidation' "$doctor_file"
}
