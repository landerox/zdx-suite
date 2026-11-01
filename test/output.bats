#!/usr/bin/env bats
# Core command-output services (docs/output-spec.md).
# Quoted programs are passed literally to the isolated Zsh process.
# shellcheck disable=SC2016

setup() {
  load test_helper
  load core_options_test_helper
}

teardown() {
  cleanup_sandbox
}

@test "output: services load in eager and lazy modes before any suite" {
  run zsh -f -c '
    emulate -R zsh
    unset TEST_TEMP_DIR BATS_TEST_DIRNAME
    export ZSH_CUSTOM="$1" HOME="$2"
    source "$ZSH_CUSTOM/functions.zsh" || exit 1
    typeset -f _git_dispatch &>/dev/null && exit 2
    for name in _zdx_ui_color_enabled _zdx_ui_verbose _zdx_format_duration \
      _zdx_count_noun _zdx_outcome_class _zdx_ui_outcome _zdx_ui_heading \
      _zdx_ui_step_banner _zdx_ui_step_result _zdx_ui_table _zdx_step_exec \
      _zdx_step_report _zdx_step_reported _zdx_step_active \
      _zdx_run_captured _zdx_run_captured_here _zdx_ui_command_display \
      _zdx_ui_label _zdx_ui_section _zdx_ui_step_summary; do
      typeset -f "$name" &>/dev/null || { print -r -- "missing:$name"; exit 3; }
    done
    print -r -- lazy-ok
  ' zsh "$TEST_SUITE_ROOT" "$HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "lazy-ok" ]

  run run_zsh 'typeset -f _zdx_run_captured >/dev/null && print -r -- eager-ok'
  [ "$status" -eq 0 ]
  [ "$output" = "eager-ok" ]
}

@test "output: durations use one compact format and reject invalid input" {
  run run_zsh '
    local -a cases=(
      0 0.0s 0.05 0.1s 1.7e-05 0.0s 3. 3.0s 9.94 9.9s 9.95 10s 24.3 24s
      59.4 59s 59.5 "1m 00s" 78 "1m 18s" 3599.4 "59m 59s" 3599.5 "1h 00m"
      3630 "1h 01m" 360000 "4d 04h" 1e9 "11574d 02h"
    )
    local input expected
    for input expected in "${cases[@]}"; do
      _zdx_format_duration "$input" || { print -r -- "rc:$input"; return 1; }
      [[ "$REPLY" == "$expected" ]] || { print -r -- "bad:$input:$REPLY"; return 1; }
    done
    for input in "" -1 1,5 abc 0x10 1.2.3 " 1" 1e400 1000000001; do
      _zdx_format_duration "$input" && { print -r -- "accepted:$input"; return 1; }
      [[ -z "$REPLY" ]] || return 1
    done
    print -r -- ok
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "output: durations promote rounded days and round day hours once" {
  run run_zsh '
    cd "$HOME" || return 1
    local -a cases=(
      86369.49 "23h 59m" 86369.5 "1d 00h" 86370 "1d 00h"
      86399.49 "1d 00h" 86399.5 "1d 00h" 86400 "1d 00h"
      88169.49 "1d 00h" 88169.5 "1d 00h" 88199.5 "1d 00h"
      88200 "1d 01h" 170969.5 "1d 23h" 170999.5 "1d 23h"
      171000 "2d 00h" 172799.5 "2d 00h" 172800 "2d 00h"
    )
    local input expected
    for input expected in "${cases[@]}"; do
      _zdx_format_duration "$input" || { print -r -- "rc:$input"; return 1; }
      [[ "$REPLY" == "$expected" ]] || { print -r -- "bad:$input:$REPLY"; return 1; }
    done
    print -r -- ok
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "output: durations keep a decimal point under a comma locale" {
  local locale_dir="$TEST_TEMP_DIR/locales"
  command -v localedef >/dev/null 2>&1 || skip "localedef is unavailable"
  mkdir -p "$locale_dir"
  localedef -i de_DE -f UTF-8 "$locale_dir/de_DE.UTF-8" >/dev/null 2>&1 \
    || skip "a decimal-comma locale cannot be built"
  export OUTPUT_LOCALE_DIR="$locale_dir"

  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export LOCPATH="$OUTPUT_LOCALE_DIR" LC_ALL=de_DE.UTF-8 NO_COLOR=1
    printf -v probe "%.1f" 1.5
    [[ "$probe" == "1,5" ]] || exit 42
    _zdx_format_duration 1.5 || return 1
    print -r -- "duration=$REPLY"
    _timed "sys:sys-info" true
  '
  [ "$status" -ne 42 ] || skip "the built locale does not use a decimal comma"
  [ "$status" -eq 0 ]
  [[ "$output" == *"duration=1.5s"* ]]
  [[ "$output" =~ sys:sys-info\ completed\ in\ [0-9]+[.][0-9]s ]]
}

@test "output: counted nouns and the outcome vocabulary are exact" {
  run run_zsh '
    _zdx_count_noun 0 step; print -r -- "$REPLY"
    _zdx_count_noun 1 step; print -r -- "$REPLY"
    _zdx_count_noun 3 dependency dependencies; print -r -- "$REPLY"
    _zdx_count_noun 2 "linked ZDX development checkout"; print -r -- "$REPLY"
    local bad
    for bad in -1 1.5 01 ""; do
      _zdx_count_noun "$bad" step && return 1
    done
    local token
    for token in updated current done passed delegated planned skipped \
      not-run failed blocked interrupted timed-out; do
      _zdx_ui_outcome "$token" || return 1
      print -rn -- "$REPLY|"
      _zdx_outcome_class "$token" || return 1
      print -r -- "$REPLY"
    done
    _zdx_ui_outcome bogus && return 1
    [[ -z "$REPLY" ]]
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "0 steps" ]
  [ "${lines[1]}" = "1 step" ]
  [ "${lines[2]}" = "3 dependencies" ]
  [ "${lines[3]}" = "2 linked ZDX development checkouts" ]
  [ "${lines[4]}" = "✔ updated|success" ]
  [ "${lines[7]}" = "✔ passed|success" ]
  [ "${lines[8]}" = "→ delegated|info" ]
  [ "${lines[11]}" = "– not run|neutral" ]
  [ "${lines[15]}" = "✘ timed out|failure" ]
}

@test "output: headings are top-level only and demoted inside verbose steps" {
  run run_zsh '
    _zdx_ui_heading "Plan" > "$HOME/out" 2> "$HOME/top"
    _zdx_step_exec _zdx_ui_heading "Hidden" 2> "$HOME/step"
    ZDX_VERBOSE=1 _zdx_step_exec _zdx_ui_heading "Demoted" 2> "$HOME/verbose"
    _zdx_ui_heading $'"'"'a\eb'"'"' 2> "$HOME/escaped"
    _zdx_ui_heading "" && return 1
    [[ ! -s "$HOME/out" ]]
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/top")" = $'\n════ Plan ════' ]
  [ ! -s "$HOME/step" ]
  [ "$(cat "$HOME/verbose")" = "  ▸ Demoted" ]
  [[ "$(cat "$HOME/escaped")" == *"a^[b"* ]]
}

@test "output: key-value lines share one width and a theme-safe key" {
  run run_zsh '
    _zdx_ui_label Origin "https://example.invalid/fzf.git"
    _zdx_ui_label "Current commit:" b1be3a8
    _zdx_ui_label "Current candidates:" 28
    _zdx_ui_label Escaped $'"'"'a\eb'"'"'
    _zdx_ui_label "" value && return 1
    _zdx_ui_label ":" value && return 1
    _sys_label "Origin:" sys-value
    return 0
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "  Origin:            https://example.invalid/fzf.git" ]
  [ "${lines[1]}" = "  Current commit:    b1be3a8" ]
  [ "${lines[2]}" = "  Current candidates: 28" ]
  [[ "${lines[3]}" == "  Escaped:           a^[b" ]]
  [ "${lines[4]}" = "  Origin:            sys-value" ]

  run run_zsh '
    exec 2>"$HOME/tty-label"
    _zdx_ui_color_enabled() { return 0; }
    _zdx_ui_label Origin value
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/tty-label")" = $'  \e[1mOrigin:\e[0m            value' ]
}

@test "output: report sections and step summaries follow the step depth" {
  run run_zsh '
    _zdx_ui_section "Claude Code"
    _zdx_step_exec _zdx_ui_section "Nested"
    _zdx_ui_section "" && return 1
    _zdx_ui_step_summary --first-column Assistant "Update Summary" \
      $'"'"'Claude Code\tupdated\t1.5\t1.0 → 1.1'"'"' \
      $'"'"'Codex CLI\tskipped\t\tnot installed'"'"'
    _zdx_step_exec _zdx_ui_step_summary "Hidden Summary" $'"'"'X\tdone\t1\t'"'"'
    ZDX_VERBOSE=1 _zdx_step_exec _zdx_ui_step_summary "Shown Summary" \
      $'"'"'Y\tdone\t1\t'"'"'
    _zdx_ui_step_summary "Bad" $'"'"'one-field'"'"' && return 1
    return 0
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "▸ Claude Code" ]
  [ "${lines[1]}" = "  ▸ Nested" ]
  [[ "$output" == *"════ Update Summary ════"* ]]
  printf '%s\n' "$output" | grep -Fxq '  Assistant    Result     Time  Detail'
  printf '%s\n' "$output" | grep -Fxq '  Claude Code  ✔ updated  1.5s  1.0 → 1.1'
  printf '%s\n' "$output" | grep -Fxq '  Codex CLI    ⊘ skipped        not installed'
  [[ "$output" != *"Hidden Summary"* ]]
  [[ "$output" == *"▸ Shown Summary"* ]]

  # The section that directly follows a heading reuses its blank line.
  run run_zsh '_zdx_ui_section --first "First"; _zdx_ui_section "Second"'
  [ "$status" -eq 0 ]
  [ "$output" = $'▸ First\n\n▸ Second' ]
}

@test "output: step banners and result lines have an exact shape" {
  run run_zsh '
    export COLUMNS=40
    _zdx_ui_step_banner 4 11 fzf
    _zdx_ui_step_result 4 11 fzf current "0.74.4 (b1be3a8)" 3.04
    _zdx_ui_step_result 1 2 APT failed "" ""
    _zdx_step_exec _zdx_ui_step_banner 1 2 nested
    _zdx_ui_step_banner 3 2 bad && return 1
    _zdx_ui_step_result 1 2 x bogus "" 1 && return 1
    _zdx_ui_step_result 1 2 x done "" abc && return 1
    return 0
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "── [4/11] fzf ─────────────────────────" ]
  [ "${lines[1]}" = "✔ [4/11] fzf — current: 0.74.4 (b1be3a8) (3.0s)" ]
  [ "${lines[2]}" = "✘ [1/2] APT — failed" ]
  [ "${lines[3]}" = "  [1/2] nested" ]
  [ "${#lines[@]}" -eq 4 ]

  # The banner that directly follows a heading reuses its blank line.
  run run_zsh '
    export COLUMNS=40
    _zdx_ui_step_banner --first 1 2 first
    _zdx_ui_step_banner 2 2 second
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "── [1/2] first ─"*$'─\n\n── [2/2] second ─'* ]]
}

@test "output: tables align by display width and reject malformed rows" {
  run run_zsh '
    _zdx_ui_table --outcome-column 2 $'"'"'Step\tResult\tTime\tDetail'"'"' \
      $'"'"'APT\tfailed\t11s\tsigning key missing'"'"' \
      $'"'"'中文\tcurrent\t0.4s\t'"'"' > "$HOME/out" 2> "$HOME/table"
    _zdx_ui_table --outcome-column 2 $'"'"'A\tB'"'"' $'"'"'x\tnot-an-outcome'"'"' \
      2> "$HOME/bad" && return 1
    _zdx_ui_table $'"'"'A\tB'"'"' $'"'"'only-one-field'"'"' 2>> "$HOME/bad" && return 1
    _zdx_ui_table $'"'"'A\tB'"'"' 2> "$HOME/empty" || return 1
    [[ ! -s "$HOME/out" && ! -s "$HOME/bad" && ! -s "$HOME/empty" ]]
  '
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$HOME/table")" = "  Step  Result     Time  Detail" ]
  [ "$(sed -n 2p "$HOME/table")" = "  APT   ✘ failed   11s   signing key missing" ]
  [ "$(sed -n 3p "$HOME/table")" = "  中文  ✔ current  0.4s" ]
}

@test "output: the step slot reconciles reports with the exit status" {
  run run_zsh '
    show() { print -r -- "$1:${reply[1]}|${reply[2]}"; }
    reports_updated() { _zdx_step_report updated "1 package"; return ${1:-0}; }
    no_report() { return ${1:-0}; }
    reports_failure() { _zdx_step_report failed "lock failed"; return 1; }
    from_subshell() { ( _zdx_step_report updated lost; print -r -- "sub:$?" ); }
    delegated_child() { _zdx_step_report delegated owner; _zdx_step_report current "uv 1.0"; }

    _zdx_step_exec reports_updated; show a
    _zdx_step_exec reports_updated 3; show b
    _zdx_step_exec no_report; show c
    _zdx_step_exec no_report 124; show d
    _zdx_step_exec no_report 130; show e
    _zdx_step_exec reports_failure; show f
    _zdx_step_exec from_subshell; show g
    _zdx_step_exec delegated_child; show h
    _zdx_step_report done && return 1
    [[ $? -eq 1 ]] || return 1
    _zdx_step_exec _zdx_step_report bogus; [[ $? -eq 2 ]] || return 1
    REPLY=keep
    _zdx_step_exec true
    print -r -- "reply-kept:$REPLY"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"a:updated|1 package"* ]]
  [[ "$output" == *"b:failed|status 3"* ]]
  [[ "$output" == *"c:done|"* ]]
  [[ "$output" == *"d:timed-out|status 124"* ]]
  [[ "$output" == *"e:interrupted|status 130"* ]]
  [[ "$output" == *"f:failed|lock failed"* ]]
  [[ "$output" == *"sub:1"* ]]
  [[ "$output" == *"g:done|"* ]]
  [[ "$output" == *"h:current|uv 1.0"* ]]
  [[ "$output" == *"reply-kept:keep"* ]]
}

@test "output: captured success is quiet and failures replay a bounded redacted tail" {
  mkdir -m 700 "$HOME/capture-tmp"
  run run_zsh '
    export TMPDIR="$HOME/capture-tmp"
    _zdx_run_captured "quiet tool" "" "" zsh -f -c "emulate -R zsh; echo success-out; echo success-err >&2" \
      > "$HOME/stdout"
    print -r -- "success:$?"
    _zdx_run_captured "noisy tool" "" "" zsh -f -c '"'"'
      emulate -R zsh
      for i in {1..100}; do printf "bounded-%03d\n" $i; done
      print -r -- "token=abc123"
      print -r -- "https://user:pass@example.invalid/repo"
      print -r -- "ssh://git@example.invalid/repo"
      printf "\e[31mcolored\e[0m\n"
      printf "progress 10%%\rprogress done\n"
      exit 9
    '"'"' >> "$HOME/stdout"
    print -r -- "failure:$?"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  [[ "$output" == *'$ quiet tool  (output shown on failure)'* ]]
  [[ "$output" != *"success-out"* ]]
  [[ "$output" != *"success-err"* ]]
  [[ "$output" == *"success:0"* ]]
  [[ "$output" == *"failure:9"* ]]
  [[ "$output" == *"output (status 9, last 80 lines):"* ]]
  [[ "$output" != *"bounded-020"* ]]
  [[ "$output" == *"bounded-100"* ]]
  [[ "$output" != *"abc123"* ]]
  [[ "$output" != *"user:pass"* ]]
  [[ "$output" == *"[redacted potentially sensitive output]"* ]]
  [[ "$output" == *"ssh://git@example.invalid/repo"* ]]
  [[ "$output" == *"│ colored"* ]]
  [[ "$output" == *"│ progress done"* ]]
  [ -z "$(find "$HOME/capture-tmp" -mindepth 1 -print -quit)" ]
}

@test "output: captured commands keep the caller umask and get closed stdin" {
  mkdir -m 700 "$HOME/capture-tmp"
  run run_zsh '
    export TMPDIR="$HOME/capture-tmp"
    umask 022
    _zdx_run_captured "write file" "" "" zsh -f -c "emulate -R zsh; print created > \"\$HOME/created\"" || return 1
    print -r -- "must-not-reach" | _zdx_run_captured "stdin check" "" "" \
      zsh -f -c '"'"'emulate -R zsh; if IFS= read -r line; then print -r -- "unexpected:$line"; exit 97; fi'"'"'
  '
  [ "$status" -eq 0 ]
  [ "$(file_mode "$HOME/created")" = "644" ]
  [[ "$output" != *"unexpected:"* ]]
  [ -z "$(find "$HOME/capture-tmp" -mindepth 1 -print -quit)" ]
}

@test "output: verbose streams live and replay 0 never shows output" {
  mkdir -m 700 "$HOME/capture-tmp"
  run run_zsh '
    export TMPDIR="$HOME/capture-tmp"
    ZDX_VERBOSE=1 _zdx_run_captured "live tool" "" "" zsh -f -c "emulate -R zsh; echo streamed-line" \
      > "$HOME/stdout"
    print -r -- "live:$?"
    _zdx_run_captured "vendor updater" "" 0 zsh -f -c "emulate -R zsh; echo vendor-secret; exit 3"
    print -r -- "hidden:$?"
    ZDX_VERBOSE=1 _zdx_run_captured "vendor updater" "" 0 zsh -f -c "emulate -R zsh; echo vendor-secret-2; exit 4"
    print -r -- "hidden-verbose:$?"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  [[ "$output" == *'$ live tool'* ]]
  [[ "$output" == *"streamed-line"* ]]
  [[ "$output" == *"live:0"* ]]
  [[ "$output" == *'$ vendor updater  (output not shown)'* ]]
  [[ "$output" != *"vendor-secret"* ]]
  [[ "$output" == *"hidden:3"* ]]
  [[ "$output" == *"hidden-verbose:4"* ]]
  [ -z "$(find "$HOME/capture-tmp" -mindepth 1 -print -quit)" ]
}

@test "output: invalid capture arguments and an unsafe TMPDIR never run the command" {
  mkdir -m 777 "$HOME/shared-tmp"
  run run_zsh '
    marker="$HOME/ran"
    _zdx_run_captured "" "" "" touch "$marker"; print -r -- "empty-display:$?"
    _zdx_run_captured "x" 12 "" touch "$marker"; print -r -- "small-max:$?"
    _zdx_run_captured "x" "" 1001 touch "$marker"; print -r -- "many-lines:$?"
    _zdx_run_captured "x" "" ""; print -r -- "no-command:$?"
    TMPDIR="$HOME/shared-tmp" _zdx_run_captured "x" "" "" touch "$marker"
    print -r -- "unsafe-tmp:$?"
    [[ ! -e "$marker" ]] && print -r -- not-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty-display:2"* ]]
  [[ "$output" == *"small-max:2"* ]]
  [[ "$output" == *"many-lines:2"* ]]
  [[ "$output" == *"no-command:2"* ]]
  [[ "$output" == *"unsafe-tmp:1"* ]]
  [[ "$output" == *"not-run"* ]]
}

@test "output: the in-shell capture keeps shell changes and hides success output" {
  mkdir -m 700 "$HOME/capture-tmp"
  run run_zsh '
    export TMPDIR="$HOME/capture-tmp"
    fake_nvm() {
      typeset -g FAKE_NODE=v24
      path=(/fake/node/bin $path)
      print -r -- "Now using node v24"
    }
    _zdx_run_captured_here "nvm use v24" "" "" fake_nvm || return 1
    print -r -- "node=$FAKE_NODE path=${path[1]}"
    failing_nvm() { print -r -- "N/A: version not installed"; return 3; }
    _zdx_run_captured_here "nvm use v99" "" "" failing_nvm
    print -r -- "failing:$?"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"node=v24 path=/fake/node/bin"* ]]
  [[ "$output" != *"Now using node v24"* ]]
  [[ "$output" == *"N/A: version not installed"* ]]
  [[ "$output" == *"failing:3"* ]]
  [ -z "$(find "$HOME/capture-tmp" -mindepth 1 -print -quit)" ]
}

@test "output: only the outermost timer outside a step prints a footer" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export NO_COLOR=1 ZDX_TELEMETRY=1
    inner() { _timed "sys:sys-info" true; }
    _timed "dev:dev-check-health" inner
    _zdx_step_exec _timed "dev:dev-check-types" true
    partial() { _zdx_timed_mark_partial || return 90; return 1; }
    _timed "sys:update-system" _timed "sys:sys-health" partial
    print -r -- "partial:$?"
    _zdx_timed_mark_partial && return 91
    command grep -c "\"command\"" "$HOME/.config/zdx/telemetry.json"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev:dev-check-health completed in "* ]]
  [[ "$output" != *"sys:sys-info"* ]]
  [[ "$output" != *"dev:dev-check-types"* ]]
  [[ "$output" == *"sys:update-system failed after "*"(status 1)"* ]]
  [[ "$output" != *"sys:sys-health"* ]]
  [[ "$output" == *"partial:1"* ]]
  [ "${lines[${#lines[@]}-1]}" = "5" ]
}

@test "core: _zdx_spinner runs a command and returns its output" {
  run run_zsh '
    local result
    result=$(_zdx_spinner "Running test" sh -c "sleep 0.1; echo SUCCESS")
    print -r -- "RESULT=$result"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT=SUCCESS"* ]]
}

@test "F3-04 regex: duration preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'duration' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: duration preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'duration' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: count preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'count' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: count preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'count' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: step-counter preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'step-counter' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: step-counter preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'step-counter' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: step-banner preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'step-banner' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: step-banner preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'step-banner' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: table preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'table' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: table preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'table' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: capture-args preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'capture-args' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: capture-args preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'capture-args' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: capture-redaction preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'capture-redaction' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: capture-redaction preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'capture-redaction' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: reject:duration preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'reject:duration' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: reject:duration preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'reject:duration' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: reject:count preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'reject:count' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: reject:count preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'reject:count' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: reject:step-counter preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'reject:step-counter' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: reject:step-counter preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'reject:step-counter' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: reject:capture-args preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'reject:capture-args' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: reject:capture-args preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'reject:capture-args' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 invariant: timed user callbacks retain caller options and shell effects" {
  f304_mock_local_probes
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    setopt sh_word_split
    _f304_callback() {
      [[ -o sh_word_split ]] || return 78
      setopt null_glob
      typeset -g F304_CALLBACK_EFFECT=visible
      return 23
    }
    _timed "sys:sys-info" _f304_callback
    local call_rc=$?
    [[ $call_rc == 23 && -o sh_word_split && -o null_glob && "$F304_CALLBACK_EFFECT" == visible ]]
  '
  [ "$status" -eq 0 ]
}


@test "F3-04 regression: a timer preserves the user callback own regex results" {
  f304_mock_local_probes
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    _f304_callback() { [[ foobarbaz =~ "(bar)" ]]; }
    _timed "sys:sys-info" _f304_callback || exit 31
    [[ "$MATCH" == bar && "$MBEGIN" == 4 && "$MEND" == 6 ]] || exit 32
    [[ "${match[1]}" == bar && "${mbegin[1]}" == 4 && "${mend[1]}" == 6 ]]
  '
  [ "$status" -eq 0 ]
}


@test "F3-04 invariant: in-shell capture keeps user options shell effects and regex results" {
  f304_mock_local_probes
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    setopt sh_word_split
    _f304_callback() {
      [[ -o sh_word_split ]] || return 78
      setopt null_glob
      typeset -g F304_CALLBACK_EFFECT=visible
      [[ foobarbaz =~ "(bar)" ]] || return 79
      return 23
    }
    _zdx_run_captured_here probe 4096 0 _f304_callback
    local call_rc=$?
    [[ $call_rc == 23 && -o sh_word_split && -o null_glob && "$F304_CALLBACK_EFFECT" == visible ]] || exit 31
    [[ "$MATCH" == bar && "$MBEGIN" == 4 && "$MEND" == 6 \
      && "${match[1]}" == bar && "${mbegin[1]}" == 4 && "${mend[1]}" == 6 ]]
  '
  [ "$status" -eq 0 ]
}


@test "F3-04 invariant: pipeline capture inherits options but isolates child shell effects" {
  f304_mock_local_probes
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    setopt sh_word_split pipe_fail
    typeset -g F304_CALLBACK_EFFECT=parent
    _f304_callback() {
      [[ -o sh_word_split && ! -o pipe_fail ]] || return 78
      typeset -g F304_CALLBACK_EFFECT=child
      print -r -- inherited > "$HOME/callback.options"
      return 23
    }
    _zdx_run_captured probe 4096 0 _f304_callback
    local call_rc=$?
    [[ $call_rc == 23 && -o sh_word_split && -o pipe_fail && "$F304_CALLBACK_EFFECT" == parent ]] || exit 31
    [[ "$(<"$HOME/callback.options")" == inherited ]]
  '
  [ "$status" -eq 0 ]
}


@test "F3-04 invariant: step user callbacks retain caller options and shell effects" {
  f304_mock_local_probes
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    setopt sh_word_split
    _f304_callback() {
      [[ -o sh_word_split ]] || return 78
      setopt null_glob
      typeset -g F304_CALLBACK_EFFECT=visible
      return 143
    }
    _zdx_step_exec _f304_callback
    local call_rc=$?
    [[ $call_rc == 143 && -o sh_word_split && -o null_glob && "$F304_CALLBACK_EFFECT" == visible ]] || exit 31
    [[ "${reply[1]}" == interrupted ]]
  '
  [ "$status" -eq 0 ]
}

@test "F3-04 augmentation: step execution preserves all six callback regex parameters" {
  f304_mock_local_probes
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    _f304a_callback() {
      [[ foobarbaz =~ "(bar)" ]] || return 78
      return 143
    }
    _zdx_step_exec _f304a_callback
    local callback_rc=$?
    [[ "$callback_rc" == 143 && "$MATCH" == bar && "$MBEGIN" == 4 && "$MEND" == 6 ]] || exit 31
    [[ "${match[1]}" == bar && "${mbegin[1]}" == 4 && "${mend[1]}" == 6 ]]
  '
  [ "$status" -eq 0 ]
}

@test "F3-04 augmentation v2: FORCE_FLOAT preserves the decimal duration and caller option" {
  f304_mock_local_probes
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    setopt force_float
    _zdx_format_duration 1.5 || exit 31
    [[ -o force_float ]] || exit 32
    print -r -- "duration=$REPLY"
  '
  [ "$status" -eq 0 ]
  [ "$output" = duration=1.5s ]
}
