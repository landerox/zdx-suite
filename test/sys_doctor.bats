#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  load core_probe_test_helper
}

# Executable presence is real and private. Only fzf/git/jq are installed
# dependencies; package-manager and sudo recorders must never execute.
_sys_doctor_tools() {
  make_core_probe_path
  local tool
  for tool in fzf git jq; do
    core_probe_program "$tool" <<'MOCK'
[[ "$#" -eq 1 && "$1" == --version ]] || exit 97
if IFS= read -r unexpected; then exit 98; fi
case "${0##*/}" in
  fzf) printf '0.74.3 (fixture)\n' ;;
  git) printf 'git version 2.43.0\n' ;;
  jq) printf 'jq-1.7.1\n' ;;
esac
MOCK
  done
  for tool in apt-get brew sudo; do
    core_probe_program "$tool" <<'MOCK'
printf '%s\n' "$0 $*" >> "$HOME/sys-doctor-mutator-ran"
exit 97
MOCK
  done
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
  _sys_doctor_tools
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" || exit 90
    path=("$CORE_PROBE_BIN")
    rehash
    # Only these private inert tools satisfy the install-plan trust boundary.
    _zdx_doctor_program_trusted() {
      [[ "$1" == "$CORE_PROBE_BIN"/(apt-get|brew|sudo) && -f "$1" && -x "$1" ]]
    }
    # A pipe supplies no terminal: this is headless refusal, not a user decline.
    print -r -- n | zdx-doctor
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 1 ] # Missing packages remain and confirmation has no terminal.
  [[ "$output" == *"ZDX Dependency Doctor Checkup"* ]]
  [[ "$output" =~ (^|$'\n')'  fzf:'[[:space:]]+"Installed ($CORE_PROBE_BIN/fzf, v0.74.3)"($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  pipx:'[[:space:]]+'MISSING (Alternative Python global tools) [Python & Virtualenvs]'($|$'\n') ]]
  [[ "$output" == *"Installation unavailable: confirmation could not be completed."* ]]
  [[ "$output" =~ (^|$'\n')'▸ Install Plan'($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  Official link:'[[:space:]]+'https://github.com/pypa/pipx'($|$'\n') ]]
  [ ! -e "$HOME/sys-doctor-mutator-ran" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys-doctor: OS and Pkg Manager detection is accurate" {
  _sys_doctor_tools
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" || exit 90

    # Trigger loading of zdx-doctor
    zdx-doctor --help >/dev/null
    path=("$CORE_PROBE_BIN")
    rehash

    # Test helpers directly
    os_name=$(_zdx_doctor_detect_os)
    pm_name=$(_zdx_doctor_detect_pkg_manager)

    if [[ -z "$os_name" || -z "$pm_name" ]]; then
      print -r -- "FAIL: OS or package manager detection returned empty"
      exit 1
    fi

    print -r -- "SUCCESS: Detected OS=$os_name, PM=$pm_name"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: Detected OS="* ]]
}

@test "sys-doctor: timeout and SHA-256 capabilities name the suites that use them" {
  local doctor_file="$TEST_SUITE_ROOT/functions/zdx-doctor.zsh"

  [ "$(grep -cF '[System, Python & VPN]' "$doctor_file")" -eq 2 ]
  [ "$(grep -cF "_zdx_doctor_label 'sha256sum/shasum'" "$doctor_file")" -eq 2 ]
  [ "$(grep -cF '[File]' "$doctor_file")" -eq 2 ]
  grep -Fq 'bounded inventories, probes, and remote lookups' "$doctor_file"
  grep -Fq 'MISSING (archive identity checks) [File]' "$doctor_file"
}
