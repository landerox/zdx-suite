#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE FZF_DEFAULT_COMMAND
  export NO_COLOR=1
  export MOCK_DOCTOR_VERSION='0.74.3 (fixture)'
  export MOCK_DOCTOR_FZF_RC=0
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
[[ "$#" -eq 1 && "$1" == --version ]] || exit 97
[[ -z "${FZF_DEFAULT_OPTS:-}${FZF_DEFAULT_OPTS_FILE:-}${FZF_DEFAULT_COMMAND:-}" ]] || exit 96
if IFS= read -r unexpected_input; then exit 95; fi
[[ -z "${MOCK_DOCTOR_VERSION:-}" ]] || printf '%s\n' "$MOCK_DOCTOR_VERSION"
exit "${MOCK_DOCTOR_FZF_RC:-0}"
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
  cat > "$TEST_TEMP_DIR/doctor-fixture.zsh" <<'FIXTURE'
_zdx_doctor_detect_os() { print -r -- Linux; }
_zdx_doctor_detect_pkg_manager() { print -r -- none; }
_zdx_doctor_timeout_command() { return 1; }
_zdx_doctor_sha256_command() { return 1; }
command() {
  if [[ "${1:-}" == -v ]]; then
    [[ "${2:-}" == fzf ]]
  else
    builtin command "$@"
  fi
}
FIXTURE
}

teardown() { cleanup_sandbox; }

@test "doctor rendering: version probe isolates fzf defaults and leaves caller state intact" {
  run zsh -f -c '
    source "$1/functions/zdx-doctor.zsh" || exit
    export FZF_DEFAULT_OPTS="--header-lines=999"
    export FZF_DEFAULT_OPTS_FILE="$HOME/unreadable-options"
    export FZF_DEFAULT_COMMAND="do-not-run"
    _zdx_doctor_get_version fzf <<< "must not be consumed" >"$HOME/version"
    probe_rc=$?
    (( probe_rc == 0 )) || exit 1
    [[ "$(<"$HOME/version")" == 0.74.3 ]] || exit 1
    [[ "$FZF_DEFAULT_OPTS" == --header-lines=999 \
      && "$FZF_DEFAULT_OPTS_FILE" == "$HOME/unreadable-options" \
      && "$FZF_DEFAULT_COMMAND" == do-not-run ]]
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

@test "doctor rendering: version failures and interruptions cannot become empty success" {
  run zsh -f -c '
    source "$1/functions/zdx-doctor.zsh" || exit
    local expected_rc=0
    for expected_rc in 19 130 143; do
      export MOCK_DOCTOR_FZF_RC="$expected_rc"
      _zdx_doctor_get_version fzf >"$HOME/version"
      (( $? == expected_rc )) || exit 1
      [[ ! -s "$HOME/version" ]] || exit 1
    done
    export MOCK_DOCTOR_FZF_RC=0
    local invalid_version=""
    for invalid_version in "" "unexpected output"; do
      export MOCK_DOCTOR_VERSION="$invalid_version"
      _zdx_doctor_get_version fzf >"$HOME/version"
      (( $? == 1 )) || exit 1
      [[ ! -s "$HOME/version" ]] || exit 1
    done
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

@test "doctor rendering: report distinguishes a valid fzf version from a failed probe" {
  run zsh -f -c '
    source "$1/functions/zdx-doctor.zsh" || exit
    source "$2/doctor-fixture.zsh" || exit
    zdx-doctor >"$HOME/stdout" 2>"$HOME/valid-report"
    (( $? == 1 )) || exit 1
    export MOCK_DOCTOR_FZF_RC=19
    zdx-doctor >"$HOME/stdout" 2>"$HOME/failed-report"
    (( $? == 1 ))
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fq 'fzf - Installed' "$HOME/valid-report"
  grep -Fq 'v0.74.3' "$HOME/valid-report"
  grep -Fq 'fzf - VERSION CHECK FAILED' "$HOME/failed-report"
  grep -Fq 'status 19' "$HOME/failed-report"
  grep -Fq 'Optional Suite-Specific Dependencies' "$HOME/failed-report"
  run grep -Fq 'fzf - Installed' "$HOME/failed-report"
  [ "$status" -eq 1 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "doctor rendering: interrupted fzf probes stop later diagnostics" {
  for expected_rc in 130 143; do
    export MOCK_DOCTOR_FZF_RC="$expected_rc"
    run zsh -f -c '
      source "$1/functions/zdx-doctor.zsh" || exit
      source "$2/doctor-fixture.zsh" || exit
      zdx-doctor >"$HOME/stdout"
    ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"
    [ "$status" -eq "$expected_rc" ]
    [[ "$output" == *"fzf - VERSION CHECK FAILED"* ]]
    [[ "$output" != *"Optional Suite-Specific Dependencies"* ]]
    [ ! -s "$HOME/stdout" ]
  done
}

@test "doctor rendering: passive display context escapes terminal and source paths without secrets" {
  local copied_dir="$TEST_TEMP_DIR/"$'copy\033[31m\nproject'
  mkdir "$copied_dir"
  cp "$TEST_SUITE_ROOT/functions/zdx-doctor.zsh" "$copied_dir/zdx-doctor.zsh"
  run zsh -f -c '
    source "$1" || exit
    [[ "$_ZDX_DOCTOR_SOURCE_FILE" == "${1:A}" ]] || exit 1
    export TERM=$'\''vt100\033[31m\nforged-line'\''
    export ZDX_FZF_THEME="PRIVATE_THEME_VALUE"
    export FZF_DEFAULT_OPTS="PRIVATE_OPTIONS_VALUE"
    export FZF_DEFAULT_OPTS_FILE="PRIVATE_FILE_VALUE"
    export NO_COLOR=1
    PATH=""
    _zdx_doctor_visual_diagnostics >"$HOME/stdout" 2>"$HOME/display-report"
  ' _ "$copied_dir/zdx-doctor.zsh"
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fq 'colors: disabled by NO_COLOR' "$HOME/display-report"
  grep -Fq 'custom theme: configured' "$HOME/display-report"
  grep -Fq 'options=set; file=set' "$HOME/display-report"
  grep -Fq 'Doctor source:' "$HOME/display-report"
  grep -Fq 'open a new shell' "$HOME/display-report"
  [ "$(wc -l < "$HOME/display-report")" -eq 3 ]
  run grep -Eq $'PRIVATE_|\033' "$HOME/display-report"
  [ "$status" -eq 1 ]
}

@test "doctor rendering: explicit plain mode takes precedence over a custom theme" {
  run zsh -f -c '
    source "$1/functions/zdx-doctor.zsh" || exit
    unset NO_COLOR
    export ZDX_FZF_PLAIN=1 ZDX_FZF_THEME="PRIVATE_THEME_VALUE" TERM=xterm-256color
    _zdx_doctor_visual_diagnostics
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"colors: disabled by ZDX_FZF_PLAIN"* ]]
  [[ "$output" == *"custom theme: configured"* ]]
  [[ "$output" != *"PRIVATE_THEME_VALUE"* ]]
}
