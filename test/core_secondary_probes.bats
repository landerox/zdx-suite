#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Incremental F3-08 coverage: secondary executables and public outcome paths.
# Requires the earlier proposal's core_probe_test_helper; no previous test is
# replaced, and every scenario loads the core before narrowing the mock PATH.

setup() {
  load test_helper
  load core_probe_test_helper
  load core_secondary_probe_test_helper
  f308_probe_setup
}

teardown() {
  cleanup_sandbox
}

@test "core secondary probes: WireGuard versions use a resolved bounded external wg with closed stdin" {
  f308_wireguard
  run run_core_probe_zsh '
    source "$HOME/secondary-trace.zsh" || exit 31
    wg() { print -r -- shadow > "$HOME/wg-function-ran"; return 97; }
    local version=""
    exec < "$HOME/secondary-probe.stdin" || exit 30
    version=$(_zdx_doctor_get_version wg-quick) || exit 32
    [[ "$version" == 1.0.20210914 && ! -e "$HOME/wg-function-ran" ]] || exit 33
    [[ "$(<"$F308_TRACE")" == *$'\''\t'\''"$CORE_PROBE_BIN/wg"* ]] || exit 34
    local unread=""
    IFS= read -r unread || exit 80
    [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
    print -r -- external-wg
  '
  [ "$status" -eq 0 ]
  [ "$output" = external-wg ]
}

@test "core secondary probes: failed and interrupted wg cannot become an empty successful version" {
  f308_wireguard
  local rc
  for rc in 19 130 143; do
    export F308_WG_RC="$rc"
    run run_core_probe_zsh '
      local -i rc=0
      exec < "$HOME/secondary-probe.stdin" || exit 30
      _zdx_doctor_get_version wg-quick >"$HOME/version.stdout" 2>"$HOME/version.stderr" || rc=$?
      (( rc == F308_WG_RC )) || exit 31
      [[ ! -s "$HOME/version.stdout" ]] || exit 32
      local unread=""
      IFS= read -r unread || exit 80
      [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
      print -r -- preserved
    '
    [ "$status" -eq 0 ]
    [ "$output" = preserved ]
    [ -s "$HOME/wg.argv" ]
  done
}

@test "core secondary probes: a hung wg is stopped by the real fallback before completion" {
  f308_wireguard
  export F308_WG_SLEEP=8
  run run_core_probe_zsh '
    local -i rc=0
    exec < "$HOME/secondary-probe.stdin" || exit 30
    _zdx_doctor_get_version wg-quick >"$HOME/version.stdout" 2>"$HOME/version.stderr" || rc=$?
    (( rc == 124 )) || exit 31
    [[ ! -s "$HOME/version.stdout" && ! -e "$HOME/wg-completed" ]] || exit 32
    local unread=""
    IFS= read -r unread || exit 80
    [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
    print -r -- bounded
  '
  [ "$status" -eq 0 ]
  [ "$output" = bounded ]
  [ ! -e "$HOME/wg-completed" ]
}

@test "core secondary probes: CLT classification resolves and bounds external xcode-select" {
  f308_xcode_select
  run run_core_probe_zsh '
    source "$HOME/secondary-trace.zsh" || exit 31
    OSTYPE=darwin23
    xcode-select() { print -r -- shadow > "$HOME/xcode-function-ran"; return 97; }
    local -i rc=0
    exec < "$HOME/secondary-probe.stdin" || exit 30
    _zdx_doctor_clt_placeholder git /usr/bin/git || rc=$?
    (( rc == 1 )) || exit 32
    [[ ! -e "$HOME/xcode-function-ran" ]] || exit 33
    [[ "$(<"$F308_TRACE")" == *$'\''\t'\''"$CORE_PROBE_BIN/xcode-select"* ]] || exit 34
    local unread=""
    IFS= read -r unread || exit 80
    [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
    print -r -- external-clt-check
  '
  [ "$status" -eq 0 ]
  [ "$output" = external-clt-check ]
  [ -s "$HOME/xcode-select.argv" ]
}

@test "core secondary probes: a failed CLT check never reports the Apple placeholder usable" {
  f308_xcode_select
  export F308_XCODE_RC=19
  run run_core_probe_zsh '
    OSTYPE=darwin23
    local -i rc=0
    exec < "$HOME/secondary-probe.stdin" || exit 30
    _zdx_doctor_clt_placeholder git /usr/bin/git >"$HOME/clt.stdout" 2>"$HOME/clt.stderr" || rc=$?
    (( rc == 0 )) || exit 31
    [[ ! -s "$HOME/clt.stdout" ]] || exit 32
    local unread=""
    IFS= read -r unread || exit 80
    [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
    print -r -- refused-placeholder
  '
  [ "$status" -eq 0 ]
  [ "$output" = refused-placeholder ]
}

@test "core secondary probes: a hung CLT check cannot run to completion before classifying the placeholder" {
  f308_xcode_select
  export F308_XCODE_SLEEP=8
  run run_core_probe_zsh '
    OSTYPE=darwin23
    local -i rc=0
    exec < "$HOME/secondary-probe.stdin" || exit 30
    _zdx_doctor_clt_placeholder git /usr/bin/git >"$HOME/clt.stdout" 2>"$HOME/clt.stderr" || rc=$?
    # The selected classifier retains a returned timeout for its caller;
    # only an explicit cleared status may authorize the candidate.
    (( rc == 124 )) || exit 31
    [[ ! -s "$HOME/clt.stdout" && ! -e "$HOME/xcode-select-completed" ]] || exit 32
    local unread=""
    IFS= read -r unread || exit 80
    [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
    print -r -- bounded
  '
  [ "$status" -eq 0 ]
  [ "$output" = bounded ]
  [ ! -e "$HOME/xcode-select-completed" ]
}

@test "core secondary probes: PR candidates freeze env gh and jq paths through the real fallback" {
  [ -n "$F308_REAL_JQ" ] || skip "jq is not installed"
  f308_pr_tools
  run run_core_probe_zsh '
    zle() { return 0; }
    env() { print -r -- shadow > "$HOME/env-function-ran"; return 97; }
    gh() { print -r -- shadow > "$HOME/gh-function-ran"; return 97; }
    jq() { print -r -- shadow > "$HOME/jq-function-ran"; return 97; }
    local -a widget_values=() widget_alternates=() widget_labels=()
    exec < "$HOME/secondary-probe.stdin" || exit 30
    _zdx_widget_pr_candidates >"$HOME/pr.stdout" 2>"$HOME/pr.stderr" || exit 31
    (( ${#widget_values} == 1 )) || exit 32
    [[ "${widget_values[1]}" == 42 && "${widget_labels[1]}" == *"Fixture PR"* ]] || exit 33
    [[ ! -s "$HOME/pr.stdout" ]] || exit 34
    [[ ! -e "$HOME/env-function-ran" && ! -e "$HOME/gh-function-ran" && ! -e "$HOME/jq-function-ran" ]] || exit 35
    local unread=""
    IFS= read -r unread || exit 80
    [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
    print -r -- external-pr-tools
  '
  [ "$status" -eq 0 ]
  [ "$output" = external-pr-tools ]
  run command python3 - "$HOME" "$CORE_PROBE_BIN" <<'PY'
from pathlib import Path
import sys

home, binary = map(Path, sys.argv[1:])
argv = {name: home.joinpath(name + ".argv").read_bytes().decode().split("\0")[:-1]
        for name in ("env", "gh", "jq")}
for name in argv:
    assert argv[name][0] == str(binary / name), (name, argv[name])
assert argv["env"][1:4] == ["GH_PROMPT_DISABLED=1", "GH_NO_UPDATE_NOTIFIER=1", str(binary / "gh")]
assert argv["gh"][1:] == ["pr", "list", "--state", "open", "--limit", "200", "--json", "number,title,headRefName"]
assert argv["jq"][1] == "-r"
PY
  [ "$status" -eq 0 ]
}

@test "core secondary probes: PR env gh and jq failures cannot create candidates" {
  [ -n "$F308_REAL_JQ" ] || skip "jq is not installed"
  f308_pr_tools
  local kind
  for kind in env gh jq malformed; do
    export F308_ENV_RC=0 F308_GH_RC=0 F308_JQ_RC=0 F308_BAD_PR_JSON=0
    case "$kind" in
      env) export F308_ENV_RC=19 ;;
      gh) export F308_GH_RC=4 ;;
      jq) export F308_JQ_RC=19 ;;
      malformed) export F308_BAD_PR_JSON=1 ;;
    esac
    run run_core_probe_zsh '
      zle() { return 0; }
      local -a widget_values=() widget_alternates=() widget_labels=()
      local -i rc=0
      exec < "$HOME/secondary-probe.stdin" || exit 30
      _zdx_widget_pr_candidates >"$HOME/pr.stdout" 2>"$HOME/pr.stderr" || rc=$?
      (( rc == 1 && ${#widget_values} == 0 )) || exit 31
      [[ -n "$REPLY" && ! -s "$HOME/pr.stdout" ]] || exit 32
      if (( F308_GH_RC == 4 )); then
        [[ "$REPLY" == *"authenticated"* ]] || exit 33
      fi
      local unread=""
      IFS= read -r unread || exit 80
      [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
      print -r -- no-candidates
    '
    [ "$status" -eq 0 ]
    [ "$output" = no-candidates ]
  done
}

@test "core secondary probes: a hung PR jq is bounded before its completion marker" {
  [ -n "$F308_REAL_JQ" ] || skip "jq is not installed"
  f308_pr_tools
  export F308_JQ_SLEEP=8
  run run_core_probe_zsh '
    zle() { return 0; }
    local -a widget_values=() widget_alternates=() widget_labels=()
    local -i rc=0
    exec < "$HOME/secondary-probe.stdin" || exit 30
    _zdx_widget_pr_candidates >"$HOME/pr.stdout" 2>"$HOME/pr.stderr" || rc=$?
    (( rc == 1 && ${#widget_values} == 0 )) || exit 31
    [[ "$REPLY" == *"unreadable"* && ! -e "$HOME/jq-completed" ]] || exit 32
    local unread=""
    IFS= read -r unread || exit 80
    [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
    print -r -- bounded
  '
  [ "$status" -eq 0 ]
  [ "$output" = bounded ]
  [ ! -e "$HOME/jq-completed" ]
}

@test "core secondary probes: doctor reports a timed-out version and still diagnoses the next independent row" {
  core_probe_program fzf <<'MOCK'
"$F308_REAL_SLEEP" 8
: > "$HOME/fzf-completed"
printf '0.74.3\n'
MOCK
  core_probe_program git <<'MOCK'
: > "$HOME/independent-git-row-ran"
printf 'git version 2.43.0\n'
MOCK
  run run_core_probe_zsh '
    _zdx_doctor_detect_os() { print -r -- Linux; }
    _zdx_doctor_detect_pkg_manager() { print -r -- none; }
    local -i rc=0
    zdx-doctor >"$HOME/doctor.stdout" 2>"$HOME/doctor.stderr" || rc=$?
    (( rc == 1 )) || exit 31
    [[ ! -s "$HOME/doctor.stdout" && ! -e "$HOME/fzf-completed" ]] || exit 32
    [[ -e "$HOME/independent-git-row-ran" ]] || exit 33
    print -r -- continued
  '
  [ "$status" -eq 0 ]
  [ "$output" = continued ]
  grep -Ei -- 'fzf.*(timed out|timeout|124)' "$HOME/doctor.stderr"
  grep -E -- 'git.*2[.]43[.]0' "$HOME/doctor.stderr"
  [ ! -e "$HOME/fzf-completed" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "core secondary probes: whole doctor maps prompt refusals and preserves prompt interruptions" {
  f308_doctor_prompt_fixture
  local rc expected
  for rc in 1 2 3 130 143; do
    case "$rc" in
      1) expected=0 ;;
      2|3) expected=1 ;;
      *) expected="$rc" ;;
    esac
    export F308_PROMPT_RC="$rc" F308_EXPECTED_RC="$expected"
    run run_core_probe_zsh '
      source "$HOME/doctor-prompt-fixture.zsh" || exit 31
      local -i rc=0
      zdx-doctor >"$HOME/doctor.stdout" 2>"$HOME/doctor.stderr" || rc=$?
      (( rc == F308_EXPECTED_RC )) || exit 32
      [[ ! -s "$HOME/doctor.stdout" && ! -e "$HOME/package-manager-ran" ]] || exit 33
      [[ "$(<"$HOME/shared-prompt-calls")" == *"$F308_PROMPT_RC"* ]] || exit 34
      [[ "$(<"$HOME/doctor.stderr")" != *"All packages installed"* ]] || exit 35
      print -r -- public-outcome
    '
    [ "$status" -eq 0 ]
    [ "$output" = public-outcome ]
  done
  [ ! -e "$HOME/package-manager-ran" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "core secondary probes: public plugin removal maps prompt refusals and preserves prompt interruptions" {
  local target="$HOME/.config/zdx/plugins/alpha"
  mkdir -p "$target"
  printf '%s\n' 'alpha-menu() { :; }' > "$target/alpha-menu.zsh"
  local before rc expected
  before=$(file_identity "$target")
  for rc in 1 2 3 130 143; do
    case "$rc" in
      1) expected=0 ;;
      2|3) expected=1 ;;
      *) expected="$rc" ;;
    esac
    export F308_PROMPT_RC="$rc" F308_EXPECTED_RC="$expected"
    run run_core_probe_zsh '
      _zdx_plugins_terminal() { return 0; }
      _zdx_confirm_prompt() {
        print -r -- "$F308_PROMPT_RC" >> "$HOME/plugin-prompt-calls"
        return "$F308_PROMPT_RC"
      }
      local before="${functions[alpha-menu]}"
      local -i rc=0
      zdx-plugins --remove alpha >"$HOME/remove.stdout" 2>"$HOME/remove.stderr" || rc=$?
      (( rc == F308_EXPECTED_RC )) || exit 31
      [[ ! -s "$HOME/remove.stdout" && -f "$HOME/.config/zdx/plugins/alpha/alpha-menu.zsh" ]] || exit 32
      [[ "${functions[alpha-menu]-}" == "$before" ]] || exit 33
      [[ "$(<"$HOME/plugin-prompt-calls")" == *"$F308_PROMPT_RC"* ]] || exit 34
      print -r -- public-outcome
    '
    [ "$status" -eq 0 ]
    [ "$output" = public-outcome ]
    [ "$(file_identity "$target")" = "$before" ]
  done
}

@test "core secondary probes: malformed local facts still produce one valid status JSON document" {
  [ -n "$F308_REAL_JQ" ] || skip "jq is not installed"
  f308_status_tools
  export F308_STATUS_KIND=malformed
  run run_core_probe_zsh '
    source "$HOME/status-secondary-fixture.zsh" || exit 31
    cd "$F308_REPO" || exit 32
    exec < "$HOME/secondary-probe.stdin" || exit 30
    zdx-status --json >"$HOME/status.json" 2>"$HOME/status.stderr" || exit 33
    local unread=""
    IFS= read -r unread || exit 80
    [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
    print -r -- json-written
  '
  [ "$status" -eq 0 ]
  [ "$output" = json-written ]
  [ "$(wc -l < "$HOME/status.json")" -eq 1 ]
  "$F308_REAL_JQ" -e --arg root "$F308_REPO" '
    .schema == "zdx.status.v1" and .repository.root == $root
    and .repository.branch == "main" and .repository.commit == null
    and .repository.ahead == null and .repository.behind == null
    and .repository.user_email == "fixture@example.invalid"
    and .host.platform == "Linux" and .host.load_average == null
    and .host.home_filesystem.used_percent == 25
    and .project.files == ["pyproject.toml"]' "$HOME/status.json"
}

@test "core secondary probes: a real status timeout leaves null repository facts and independent JSON facts intact" {
  [ -n "$F308_REAL_JQ" ] || skip "jq is not installed"
  f308_status_tools
  export F308_STATUS_KIND=timeout
  run run_core_probe_zsh '
    source "$HOME/status-secondary-fixture.zsh" || exit 31
    cd "$F308_REPO" || exit 32
    git() { print -r -- shadow > "$HOME/git-function-ran"; return 97; }
    exec < "$HOME/secondary-probe.stdin" || exit 30
    zdx-status --json >"$HOME/status.json" 2>"$HOME/status.stderr" || exit 33
    [[ ! -e "$HOME/git-function-ran" && ! -e "$HOME/git-status-completed" ]] || exit 34
    local unread=""
    IFS= read -r unread || exit 80
    [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
    print -r -- json-written
  '
  [ "$status" -eq 0 ]
  [ "$output" = json-written ]
  [ "$(wc -l < "$HOME/status.json")" -eq 1 ]
  "$F308_REAL_JQ" -e --arg root "$F308_REPO" '
    .schema == "zdx.status.v1" and .repository.root == $root
    and .repository.branch == null and .repository.commit == null
    and .repository.staged == null and .repository.unstaged == null
    and .repository.ahead == null and .repository.user_email == "fixture@example.invalid"
    and .host.platform == "Linux" and .host.load_average == [0.5, 0.4, 0.3]
    and .host.home_filesystem.used_percent == 25
    and .project.files == ["pyproject.toml"]' "$HOME/status.json"
  grep -Ei -- 'git status.*(timed out|timeout|124)' "$HOME/status.stderr"
  [ ! -e "$HOME/git-status-completed" ]
}

@test "core secondary probes: a failing status JSON serializer emits no partial document" {
  [ -n "$F308_REAL_JQ" ] || skip "jq is not installed"
  f308_status_tools
  export F308_STATUS_JQ_RC=19
  run run_core_probe_zsh '
    source "$HOME/status-secondary-fixture.zsh" || exit 31
    cd "$F308_REPO" || exit 32
    local -i rc=0
    exec < "$HOME/secondary-probe.stdin" || exit 30
    zdx-status --json >"$HOME/status.json" 2>"$HOME/status.stderr" || rc=$?
    (( rc == 1 )) || exit 33
    [[ ! -s "$HOME/status.json" && -s "$HOME/status.stderr" ]] || exit 34
    local unread=""
    IFS= read -r unread || exit 80
    [[ "$unread" == "$F308_STDIN_CANARY" ]] || exit 81
    print -r -- no-document
  '
  [ "$status" -eq 0 ]
  [ "$output" = no-document ]
}
