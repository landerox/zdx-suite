#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Core-optional standalone acceptance; fresh-source/presentation rebind pending.

setup() {
  load test_helper
  load core_probe_test_helper
  load core_clt_consumer_test_helper
  make_core_probe_path
  f308c_setup
}

teardown() { cleanup_sandbox; }

@test "doctor standalone: source help and grammar remain passive without the core" {
  run zsh -f -c '
    emulate -R zsh
    path=("$CORE_PROBE_BIN")
    source "$1/functions/zdx-doctor.zsh" >"$HOME/source.stdout" 2>"$HOME/source.stderr" || exit 31
    source "$1/functions/zdx-doctor.zsh" >>"$HOME/source.stdout" 2>>"$HOME/source.stderr" || exit 32
    [[ ! -s "$HOME/source.stdout" && ! -s "$HOME/source.stderr" ]] || exit 33
    zdx-doctor --help >"$HOME/help.stdout" 2>"$HOME/help.stderr" || exit 34
    [[ ! -s "$HOME/help.stdout" && -s "$HOME/help.stderr" ]] || exit 35
    local -i rc=0
    zdx-doctor --unknown >"$HOME/grammar.stdout" 2>"$HOME/grammar.stderr" || rc=$?
    (( rc == 2 )) || exit 36
    [[ ! -s "$HOME/grammar.stdout" && -s "$HOME/grammar.stderr" ]] || exit 37
    [[ ! -e "$HOME/candidate-git.calls" && ! -e "$HOME/candidate-python.calls" \
      && ! -e "$HOME/other-tool.calls" && ! -e "$HOME/clt.argv" ]] || exit 38
    (( ! ${+_ZDX_FUNCTIONS_SOURCED} )) || exit 39
    print -r -- passive
  ' _ "$TEST_SUITE_ROOT" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = passive ]
}

@test "doctor standalone: the private bounded backend preserves leaf status and enforces its deadline" {
  f308c_timeout_backend
  run "$CORE_PROBE_BIN/timeout" -k 2s 1s "$F308C_REAL_PYTHON" -B -I -c \
    'import sys; print("leaf-data"); raise SystemExit(23)'
  [ "$status" -eq 23 ]
  [ "$output" = leaf-data ]
  run "$CORE_PROBE_BIN/timeout" -k 2s 1s "$F308C_REAL_PYTHON" -B -I -c \
    'import os,pathlib,time; time.sleep(8); pathlib.Path(os.environ["HOME"],"slow-leaf-completed").touch()'
  [ "$status" -eq 124 ]
  [ ! -e "$HOME/slow-leaf-completed" ]
}

@test "doctor standalone: a full scan uses a resolved bounded backend and real independent rows" {
  f308c_complete_tools
  f308c_timeout_backend
  run run_f308c_standalone '
    _zdx_doctor_detect_os() { print -r -- Linux; }
    _zdx_doctor_detect_pkg_manager() { print -r -- none; }
    _zdx_doctor_confirm() { print -r -- prompt > "$HOME/prompt-ran"; return 97; }
    _zdx_doctor_run_install() { print -r -- install > "$HOME/install-ran"; return 97; }
    timeout() { print -r -- shadow > "$HOME/backend-function-ran"; return 97; }
    local -i rc=0
    zdx-doctor >"$HOME/standalone.stdout" 2>"$HOME/standalone.stderr" || rc=$?
    (( rc == 0 )) || exit 31
    [[ ! -s "$HOME/standalone.stdout" && -s "$HOME/standalone-timeout.argv" \
      && -s "$HOME/standalone-probes.calls" ]] || exit 32
    [[ ! -e "$HOME/backend-function-ran" && ! -e "$HOME/install-ran" && ! -e "$HOME/prompt-ran" ]] || exit 33
    local report="$(<"$HOME/standalone.stderr")" row=""
    local -i git_installed=0 jq_installed=0
    for row in "${(@f)report}"; do
      [[ "$row" == *git*Installed*2.43.0* ]] && git_installed=1
      [[ "$row" == *jq*Installed*1.7.1* ]] && jq_installed=1
    done
    (( git_installed && jq_installed )) || exit 34
    print -r -- standalone-bounded-scan
  '
  [ "$status" -eq 0 ]
  [ "$output" = standalone-bounded-scan ]
  run "$F308C_REAL_PYTHON" -B -I - "$HOME/standalone-timeout.argv" "$CORE_PROBE_BIN" <<'PY'
import json, pathlib, sys
calls = [json.loads(row) for row in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert calls
assert all(row[:2] == ['-k', '2s'] for row in calls)
assert all(pathlib.Path(row[3]).parent == pathlib.Path(sys.argv[2]) for row in calls)
assert {'git', 'jq'} <= {pathlib.Path(row[3]).name for row in calls}
PY
  [ "$status" -eq 0 ]
}

@test "doctor standalone: no safe backend yields individual unknown rows without raw probes or inferred installation" {
  f308c_complete_tools
  [ ! -e "$CORE_PROBE_BIN/timeout" ]
  [ ! -e "$CORE_PROBE_BIN/gtimeout" ]
  run run_f308c_standalone '
    _zdx_doctor_detect_os() { print -r -- Linux; }
    _zdx_doctor_detect_pkg_manager() { print -r -- brew; }
    _zdx_doctor_confirm() { print -r -- prompt > "$HOME/prompt-ran"; return 97; }
    _zdx_doctor_run_install() { print -r -- install > "$HOME/install-ran"; return 97; }
    timeout() { print -r -- shadow > "$HOME/backend-function-ran"; return 97; }
    gtimeout() { print -r -- shadow > "$HOME/backend-function-ran"; return 97; }
    local -i rc=0 git_unknown=0 jq_unknown=0 row_index=0 git_index=0 jq_index=0
    zdx-doctor >"$HOME/standalone.stdout" 2>"$HOME/standalone.stderr" || rc=$?
    # Proposed unresolved-scan status; rebind explicitly if the design changes.
    (( rc == 1 )) || exit 31
    [[ ! -s "$HOME/standalone.stdout" && ! -e "$HOME/standalone-probes.calls" \
      && ! -e "$HOME/backend-function-ran" && ! -e "$HOME/install-ran" && ! -e "$HOME/prompt-ran" ]] || exit 32
    local report="$(<"$HOME/standalone.stderr")" row=""
    for row in "${(@f)report}"; do
      (( ++row_index ))
      if [[ "$row" == *git* && ( "$row" == *[Uu][Nn][Kk][Nn][Oo][Ww][Nn]* \
        || "$row" == *[Uu][Nn][Aa][Vv][Aa][Ii][Ll][Aa][Bb][Ll][Ee]* || "$row" == *"VERSION CHECK FAILED"* ) ]]; then
        git_unknown=1
        git_index=$row_index
      fi
      if [[ "$row" == *jq* && ( "$row" == *[Uu][Nn][Kk][Nn][Oo][Ww][Nn]* \
        || "$row" == *[Uu][Nn][Aa][Vv][Aa][Ii][Ll][Aa][Bb][Ll][Ee]* || "$row" == *"VERSION CHECK FAILED"* ) ]]; then
        jq_unknown=1
        jq_index=$row_index
      fi
      [[ "$row" != "  git:"*"Installed ("* && "$row" != "  jq:"*"Installed ("* ]] || exit 34
    done
    (( git_unknown && jq_unknown && git_index != jq_index )) || exit 33
    [[ "$report" == *TERM:* && "$report" == *"Doctor source:"* \
      && "$report" != *"brew install git"* && "$report" != *"brew install jq"* ]] || exit 34
    print -r -- standalone-per-probe-unknown
  '
  [ "$status" -eq 0 ]
  [ "$output" = standalone-per-probe-unknown ]
}
