#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Prospective CLT consumer acceptance. The preceding F308 helper proposal is
# required. These cases remap only Apple path identity in disposable copies;
# no host Apple executable, package manager, service or network action is run.

setup() {
  load test_helper
  load core_probe_test_helper
  load core_clt_consumer_test_helper
  make_core_probe_path
  f308c_setup
}

teardown() { cleanup_sandbox; }

@test "CLT consumers: doctor diagnoses secondary timeout without probing the candidate or installing its package" {
  export F308C_XCODE_RC=124
  run run_f308c_zsh '
    local -i rc=0
    zdx-doctor --dry-run >"$HOME/doctor.stdout" 2>"$HOME/doctor.stderr" || rc=$?
    (( rc == 1 )) || exit 31
    [[ ! -s "$HOME/doctor.stdout" && -s "$HOME/clt.argv" ]] || exit 32
    [[ ! -e "$HOME/candidate-git.calls" && ! -e "$HOME/candidate-python.calls" ]] || exit 33
    [[ -s "$HOME/jq.calls" && ! -e "$HOME/install-ran" && ! -e "$HOME/prompt-ran" ]] || exit 34
    local report="$(<"$HOME/doctor.stderr")" line=""
    local -i explained=0 jq_installed=0
    for line in "${(@f)report}"; do
      [[ "$line" == *git* && ( "$line" == *"timed out"* || "$line" == *timeout* || "$line" == *"status 124"* ) ]] \
        && explained=1
      [[ "$line" == "  jq:"*"Installed ("* ]] && jq_installed=1
      [[ "$line" != "  git:"*"Installed ("* && "$line" != "  python3:"*"Installed ("* ]] || exit 36
      [[ "$line" != "  Suggested command:"*"brew install git"* ]] || exit 37
    done
    (( explained && jq_installed )) || exit 35
    print -r -- diagnosed
  '
  [ "$status" -eq 0 ]
  [ "$output" = diagnosed ]
}

@test "CLT consumers: doctor propagates secondary interruption before later dependencies prompts or installation" {
  local code
  for code in 130 143; do
    export F308C_XCODE_RC="$code"
    run run_f308c_zsh '
      local -i rc=0
      zdx-doctor >"$HOME/doctor.stdout" 2>"$HOME/doctor.stderr" || rc=$?
      (( rc == F308C_XCODE_RC )) || exit 31
      [[ ! -s "$HOME/doctor.stdout" && -s "$HOME/clt.argv" ]] || exit 32
      [[ ! -e "$HOME/candidate-git.calls" && ! -e "$HOME/candidate-python.calls" ]] || exit 33
      [[ ! -e "$HOME/jq.calls" && ! -e "$HOME/install-ran" && ! -e "$HOME/prompt-ran" ]] || exit 34
      print -r -- interrupted
    '
    [ "$status" -eq 0 ]
    [ "$output" = interrupted ]
  done
}

@test "CLT consumers: status maps secondary timeout to unknown facts and retains independent JSON facts" {
  export F308C_XCODE_RC=124
  run run_f308c_zsh '
    # This case isolates the repository chain. Optional checkout signals have
    # separate real two-stage cases below.
    _zdx_release_checkout() { reply=(); return 1; }
    zdx-status --json >"$HOME/status.stdout" 2>"$HOME/status.stderr" || exit 31
    [[ ! -e "$HOME/candidate-git.calls" && -s "$HOME/clt.argv" ]] || exit 32
    [[ -e "$HOME/independent-fact-ran" ]] || exit 33
    local -a documents=("${(@f)$(<"$HOME/status.stdout")}")
    (( ${#documents} == 1 )) || exit 34
    command jq -e ".schema == \"zdx.status.v1\" and (.repository == null or .repository.root == null) and .host.platform == \"macOS\"" \
      "$HOME/status.stdout" >/dev/null || exit 34
    [[ "$(<"$HOME/status.stderr")" == *"timed out"* || "$(<"$HOME/status.stderr")" == *timeout* ]] || exit 35
    print -r -- unknown
  '
  [ "$status" -eq 0 ]
  [ "$output" = unknown ]
}

@test "CLT consumers: status propagates secondary interruption without later facts or a partial JSON document" {
  local code
  for code in 130 143; do
    export F308C_XCODE_RC="$code"
    run run_f308c_zsh '
      local -i rc=0
      zdx-status --json >"$HOME/status.stdout" 2>"$HOME/status.stderr" || rc=$?
      (( rc == F308C_XCODE_RC )) || exit 31
      [[ ! -s "$HOME/status.stdout" && -s "$HOME/clt.argv" ]] || exit 32
      [[ ! -e "$HOME/candidate-git.calls" && ! -e "$HOME/independent-fact-ran" ]] || exit 33
      print -r -- interrupted
    '
    [ "$status" -eq 0 ]
    [ "$output" = interrupted ]
  done
}

@test "CLT consumers: branch widget blocks secondary timeout before Git picker and line editing" {
  export F308C_XCODE_RC=124
  run run_f308c_zsh '
    local -i rc=0
    LBUFFER="keep this line "
    _zdx_widget_insert branch >"$HOME/widget.stdout" 2>"$HOME/widget.stderr" || rc=$?
    (( rc == 1 )) || exit 31
    [[ "$LBUFFER" == "keep this line " && ! -s "$HOME/widget.stdout" ]] || exit 32
    [[ ! -e "$HOME/candidate-git.calls" && ! -e "$HOME/picker-ran" && -s "$HOME/clt.argv" ]] || exit 33
    [[ "$(<"$HOME/widget.messages")" == *"timed out"* || "$(<"$HOME/widget.messages")" == *timeout* ]] || exit 34
    print -r -- unchanged
  '
  [ "$status" -eq 0 ]
  [ "$output" = unchanged ]
}

@test "CLT consumers: branch widget preserves secondary interruption separately from picker cancellation" {
  local code
  for code in 130 143; do
    export F308C_XCODE_RC="$code"
    run run_f308c_zsh '
      local -i rc=0
      LBUFFER="keep this line "
      _zdx_widget_insert branch >"$HOME/widget.stdout" 2>"$HOME/widget.stderr" || rc=$?
      (( rc == F308C_XCODE_RC )) || exit 31
      [[ "$LBUFFER" == "keep this line " && ! -s "$HOME/widget.stdout" ]] || exit 32
      [[ ! -e "$HOME/candidate-git.calls" && ! -e "$HOME/picker-ran" && -s "$HOME/clt.argv" ]] || exit 33
      print -r -- interrupted
    '
    [ "$status" -eq 0 ]
    [ "$output" = interrupted ]
  done
}

@test "CLT consumers: version omits optional checkout metadata after a secondary timeout without running Git" {
  export F308C_XCODE_RC=124
  run run_f308c_zsh '
    zdx --version >"$HOME/version.stdout" 2>"$HOME/version.stderr" || exit 31
    [[ "$(<"$HOME/version.stdout")" == "ZDX (Zsh Developer Experience) v${_ZDX_RELEASE_VERSION}" ]] || exit 32
    [[ ! -e "$HOME/candidate-git.calls" && -s "$HOME/clt.argv" ]] || exit 33
    print -r -- release-only
  '
  [ "$status" -eq 0 ]
  [ "$output" = release-only ]
}

@test "CLT consumers: version propagates secondary interruption without printing a successful version" {
  local code
  for code in 130 143; do
    export F308C_XCODE_RC="$code"
    run run_f308c_zsh '
      local -i rc=0
      zdx --version >"$HOME/version.stdout" 2>"$HOME/version.stderr" || rc=$?
      (( rc == F308C_XCODE_RC )) || exit 31
      [[ ! -s "$HOME/version.stdout" && -s "$HOME/clt.argv" ]] || exit 32
      [[ ! -e "$HOME/candidate-git.calls" ]] || exit 33
      print -r -- interrupted
    '
    [ "$status" -eq 0 ]
    [ "$output" = interrupted ]
  done
}

@test "CLT consumers: optional status checkout timeout is handled after the repository check clears" {
  export F308C_XCODE_RC=0 F308C_XCODE_AFTER_FIRST=124
  run run_f308c_zsh '
    _ZDX_STATUS_SOURCE_DIR="$HOME/release/functions"
    zdx-status --json >"$HOME/status.stdout" 2>"$HOME/status.stderr" || exit 31
    [[ "$(<"$HOME/clt-count")" == 2 ]] || exit 32
    local -a calls=("${(@f)$(<"$HOME/candidate-git.calls")}")
    (( ${#calls} == 1 )) || exit 33
    local -a documents=("${(@f)$(<"$HOME/status.stdout")}")
    (( ${#documents} == 1 )) || exit 34
    command jq -e ".schema == \"zdx.status.v1\" and .zdx.commit == null" "$HOME/status.stdout" >/dev/null || exit 34
    print -r -- optional-unknown
  '
  [ "$status" -eq 0 ]
  [ "$output" = optional-unknown ]
}

@test "CLT consumers: optional status checkout interruption cannot be swallowed by metadata rendering" {
  local code
  for code in 130 143; do
    export F308C_XCODE_RC=0 F308C_XCODE_AFTER_FIRST="$code"
    run run_f308c_zsh '
      _ZDX_STATUS_SOURCE_DIR="$HOME/release/functions"
      local -i rc=0
      zdx-status --json >"$HOME/status.stdout" 2>"$HOME/status.stderr" || rc=$?
      (( rc == F308C_XCODE_AFTER_FIRST )) || exit 31
      [[ ! -s "$HOME/status.stdout" && "$(<"$HOME/clt-count")" == 2 ]] || exit 32
      local -a calls=("${(@f)$(<"$HOME/candidate-git.calls")}")
      (( ${#calls} == 1 )) || exit 33
      print -r -- interrupted
    '
    [ "$status" -eq 0 ]
    [ "$output" = interrupted ]
  done
}

@test "CLT consumers: all plugin Git preflights reject uncertainty and preserve interruption before authorization" {
  local code
  for code in 7 124 125 130 143; do
    export F308C_XCODE_RC="$code"
    run run_f308c_zsh '
      local action="" expected=1
      local -i rc=0 before_count=0 after_count=0
      (( F308C_XCODE_RC == 130 || F308C_XCODE_RC == 143 )) && expected=$F308C_XCODE_RC
      for action in install update update-all; do
        rc=0
        before_count=0
        if [[ -f "$HOME/clt-count" ]]; then
          IFS= read -r before_count < "$HOME/clt-count" || exit 35
        fi
        case "$action" in
          install) zdx-plugins --install https://example.invalid/fixture.git fixture --yes \
            >"$HOME/plugin.stdout" 2>"$HOME/plugin.stderr" || rc=$? ;;
          update) zdx-plugins --update fixture --yes \
            >"$HOME/plugin.stdout" 2>"$HOME/plugin.stderr" || rc=$? ;;
          update-all) zdx-plugins --update --yes \
            >"$HOME/plugin.stdout" 2>"$HOME/plugin.stderr" || rc=$? ;;
        esac
        (( rc == expected )) || exit 31
        IFS= read -r after_count < "$HOME/clt-count" || exit 36
        (( after_count > before_count )) && [[ -s "$HOME/clt.argv" ]] || exit 37
        [[ ! -s "$HOME/plugin.stdout" && ! -e "$HOME/candidate-git.calls" ]] || exit 32
        [[ ! -e "$HOME/authorization-ran" && ! -e "$HOME/session-ran" ]] || exit 33
      done
      [[ -s "$HOME/clt.argv" ]] || exit 34
      print -r -- refused
    '
    [ "$status" -eq 0 ]
    [ "$output" = refused ]
  done
}

@test "CLT consumers: an uncertain real doctor row is excluded from an install-capable package plan" {
  local code
  for code in 124 125; do
    export F308C_XCODE_RC="$code"
    run run_f308c_zsh '
    local -a missing_cmds=() missing_pkgs=()
    local -i issues_count=0 capability_issues_count=0 indeterminate_probe_count=0
    local pm=brew
    _zdx_doctor_report_dependency "fixture-missing|Fixture|optional|https://example.invalid|fixture-pkg|fixture-pkg|fixture-pkg|fixture-pkg|Fixture" \
      >"$HOME/missing.stdout" 2>"$HOME/missing.stderr" || exit 31
    [[ "${(j:,:)missing_cmds}" == fixture-missing && "${(j:,:)missing_pkgs}" == fixture-pkg ]] || exit 32
    (( issues_count == 1 && capability_issues_count == 0 && indeterminate_probe_count == 0 )) || exit 33
    _zdx_doctor_report_dependency "git|Core System|critical|https://git-scm.com/|git|git|git|git|Fixture" \
      >"$HOME/uncertain.stdout" 2>"$HOME/uncertain.stderr" || exit 34
    [[ "${(j:,:)missing_cmds}" == fixture-missing && "${(j:,:)missing_pkgs}" == fixture-pkg ]] || exit 35
    (( issues_count == 2 && capability_issues_count == 1 && indeterminate_probe_count == 1 )) || exit 36
    print -r -- "$capability_issues_count" > "$HOME/row-capability-count"
    [[ ! -s "$HOME/missing.stdout" && ! -s "$HOME/uncertain.stdout" \
      && ! -e "$HOME/candidate-git.calls" && ! -e "$HOME/install-ran" && ! -e "$HOME/prompt-ran" ]] || exit 37
    [[ "$(<"$HOME/missing.stderr")" == *"brew install fixture-pkg"* ]] || exit 38
    [[ "$(<"$HOME/uncertain.stderr")" != *"brew install git"* ]] || exit 39
    local row=""
    for row in "${(@f)$(<"$HOME/uncertain.stderr")}"; do
      [[ "$row" != "  git:"*"Installed ("* ]] || exit 39
    done
    print -r -- uncertainty-excluded-from-real-plan
    '
    [ "$status" -eq 0 ]
    [ "$output" = uncertainty-excluded-from-real-plan ]
  done
}

@test "CLT consumers: a successful external developer-directory check permits the private Git candidate" {
  run run_f308c_zsh '
    local -a missing_cmds=() missing_pkgs=()
    local -i issues_count=0 capability_issues_count=0
    local pm=none
    _zdx_doctor_report_dependency "git|Core System|critical|https://git-scm.com/|git|git|git|git|Fixture" \
      >"$HOME/row.stdout" 2>"$HOME/row.stderr" || exit 31
    local row=""
    local -i git_installed=0
    for row in "${(@f)$(<"$HOME/row.stderr")}"; do
      [[ "$row" == "  git:"*"Installed ($CORE_PROBE_BIN/git, v2.43.0)"* ]] && git_installed=1
    done
    [[ -s "$HOME/candidate-git.calls" ]] && (( git_installed )) || exit 32
    [[ ! -s "$HOME/row.stdout" && -s "$HOME/clt.argv" ]] || exit 33
    _zdx_plugins_require_git >"$HOME/preflight.stdout" 2>"$HOME/preflight.stderr" || exit 34
    print -r -- permitted
  '
  [ "$status" -eq 0 ]
  [ "$output" = permitted ]
}
