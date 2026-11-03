#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Four prospective F308 gap cases. Returned statuses are deterministic
# injections, not native signal acceptance or proof of watchdog deadlines.

setup() {
  load test_helper
  load core_probe_test_helper
  load core_clt_consumer_test_helper
  load core_probe_gap_test_helper
  make_core_probe_path
  f308c_setup
  f308g_setup
}

teardown() { cleanup_sandbox; }

@test "F308 gaps: canonical and every generated line/key prompt retain returned interrupts and map other read failures to unavailable" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" || exit 90
    local suite=""
    for suite in git sys dev py ws env file vpn; do
      source "$1/functions/$suite-common.zsh" || exit 91
    done
    source "$1/functions/zdx-doctor.zsh" || exit 92
    _f308g_error() { print -u2 -r -- "error: $1"; }
    _f308g_available() { return 0; }
    # A controlled read boundary exercises each unchanged real prompt body.
    # eof delegates to the actual builtin against /dev/null; 7 is an
    # ordinary non-interruption failure. No terminal or signal is required.
    read() {
      print -r -- "$F308G_PROMPT_HELPER|$F308G_PROMPT_STYLE|$F308G_READ_CODE|${(j: :)@}" \
        >> "$HOME/gap-read.calls"
      [[ "$F308G_READ_CODE" == eof ]] && { builtin read "$@"; return $?; }
      return "$F308G_READ_CODE"
    }
    local F308G_PROMPT_HELPER="" F308G_PROMPT_STYLE="" F308G_READ_CODE=""
    local -a helpers=(
      _zdx_confirm_prompt _git_confirm_prompt _sys_confirm_prompt
      _dev_confirm_prompt _py_confirm_prompt _ws_confirm_prompt
      _env_confirm_prompt _file_confirm_prompt _vpn_confirm_prompt
      _zdx_doctor_confirm_prompt
    )
    local -i rc=0 expected=0 checked=0
    local -a receipts=()
    local expected_read=""
    for F308G_PROMPT_HELPER in "${helpers[@]}"; do
      (( ${+functions[$F308G_PROMPT_HELPER]} )) || exit 31
      for F308G_PROMPT_STYLE in line key; do
        expected_read="-r zcp_reply"
        [[ "$F308G_PROMPT_STYLE" == key ]] && expected_read="-r -k 1 -u 0 zcp_reply"
        for F308G_READ_CODE in 130 143 eof 7; do
          expected=2
          [[ "$F308G_READ_CODE" == (130|143) ]] && expected=$F308G_READ_CODE
          rc=0
          "$F308G_PROMPT_HELPER" --style "$F308G_PROMPT_STYLE" \
            --error _f308g_error --available _f308g_available -- "Proceed?" \
            </dev/null >"$HOME/gap-prompt.stdout" 2>"$HOME/gap-prompt.stderr" || rc=$?
          (( rc == expected )) || exit 32
          [[ ! -s "$HOME/gap-prompt.stdout" ]] || exit 33
          (( ++checked ))
          receipts=("${(@f)$(<"$HOME/gap-read.calls")}")
          (( ${#receipts} == checked )) || exit 34
          [[ "${receipts[-1]}" == "$F308G_PROMPT_HELPER|$F308G_PROMPT_STYLE|$F308G_READ_CODE|$expected_read" ]] || exit 35
        done
      done
    done
    (( checked == 80 )) || exit 36
    unfunction read
    print -r -- read-status-table
  ' _ "$TEST_SUITE_ROOT" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = read-status-table ]
}

@test "F308 gaps: public plugin list and real-session removal dry-run retain availability when optional CLT metadata is unknown" {
  local code
  for code in 124 125; do
    export F308C_XCODE_RC="$code"
    run run_f308g_manager_zsh '
      local action="" report="" entrypoint="$ZDX_PLUGINS_DIR/$F308G_PLUGIN_NAME/$F308G_PLUGIN_NAME-menu.zsh"
      local original_entrypoint="$(<"$entrypoint")"
      local -i rc=0 before_count=0 after_count=0
      local -a stages=()
      zmodload -F zsh/stat b:zstat || exit 31
      local -A original=() current=()
      zstat -LH original -- "$ZDX_PLUGINS_DIR/$F308G_PLUGIN_NAME" || exit 32
      for action in list remove; do
        before_count=0
        [[ -f "$HOME/clt-count" ]] && before_count="$(<"$HOME/clt-count")"
        rc=0
        case "$action" in
          list) zdx-plugins --list >"$HOME/gap-manager.stdout" 2>"$HOME/gap-manager.stderr" || rc=$? ;;
          remove) zdx-plugins --remove "$F308G_PLUGIN_NAME" --dry-run \
            >"$HOME/gap-manager.stdout" 2>"$HOME/gap-manager.stderr" || rc=$? ;;
        esac
        (( rc == 0 )) || exit 33
        [[ -f "$HOME/clt-count" ]] || exit 34
        after_count="$(<"$HOME/clt-count")"
        (( after_count > before_count )) && [[ -s "$HOME/clt.argv" ]] || exit 35
        [[ ! -s "$HOME/gap-manager.stdout" && ! -e "$HOME/candidate-git.calls" \
          && ! -e "$HOME/prompt-ran" && ! -e "$HOME/gap-plugin-sourced" ]] || exit 36
        report="$(<"$HOME/gap-manager.stderr")"
        [[ "$report" == *"$F308G_PLUGIN_NAME"* ]] || exit 37
        [[ "${report:l}" == *unknown* || "${report:l}" == *unavailable* \
          || "${report:l}" == *"timed out"* ]] || exit 38
        if [[ "$action" == remove ]]; then
          [[ "${report:l}" == *"dry run"* && -f "$ZDX_PLUGINS_DIR/.zdx-plugins.lock" \
            && ! -L "$ZDX_PLUGINS_DIR/.zdx-plugins.lock" \
            && ${+_ZDX_PLUGINS_LOCK_FD} == 0 ]] || exit 39
        fi
        zstat -LH current -- "$ZDX_PLUGINS_DIR/$F308G_PLUGIN_NAME" || exit 40
        [[ "${current[device]}:${current[inode]}" == "${original[device]}:${original[inode]}" \
          && -d "$ZDX_PLUGINS_DIR/$F308G_PLUGIN_NAME/.git" \
          && "$(<"$entrypoint")" == "$original_entrypoint" ]] || exit 41
        stages=("$ZDX_PLUGINS_DIR"/.zdx-staging.*(DN))
        (( ${#stages} == 0 )) || exit 42
      done
      print -r -- optional-metadata-unknown
    '
    [ "$status" -eq 0 ]
    [ "$output" = optional-metadata-unknown ]
  done
}

@test "F308 gaps: public plugin list and real-session removal retain metadata interruption before Git prompt or quarantine" {
  local code
  for code in 130 143; do
    export F308C_XCODE_RC="$code"
    run run_f308g_manager_zsh '
      local action="" entrypoint="$ZDX_PLUGINS_DIR/$F308G_PLUGIN_NAME/$F308G_PLUGIN_NAME-menu.zsh"
      local original_entrypoint="$(<"$entrypoint")"
      local -i rc=0 before_count=0 after_count=0
      local -a stages=()
      zmodload -F zsh/stat b:zstat || exit 31
      local -A original=() current=()
      zstat -LH original -- "$ZDX_PLUGINS_DIR/$F308G_PLUGIN_NAME" || exit 32
      for action in list remove; do
        before_count=0
        [[ -f "$HOME/clt-count" ]] && before_count="$(<"$HOME/clt-count")"
        rc=0
        case "$action" in
          list) zdx-plugins --list >"$HOME/gap-manager.stdout" 2>"$HOME/gap-manager.stderr" || rc=$? ;;
          remove) zdx-plugins --remove "$F308G_PLUGIN_NAME" --yes \
            >"$HOME/gap-manager.stdout" 2>"$HOME/gap-manager.stderr" || rc=$? ;;
        esac
        (( rc == F308C_XCODE_RC )) || exit 33
        [[ -f "$HOME/clt-count" ]] || exit 34
        after_count="$(<"$HOME/clt-count")"
        (( after_count > before_count )) && [[ -s "$HOME/clt.argv" ]] || exit 35
        [[ ! -s "$HOME/gap-manager.stdout" && ! -e "$HOME/candidate-git.calls" \
          && ! -e "$HOME/prompt-ran" && ! -e "$HOME/gap-plugin-sourced" ]] || exit 36
        if [[ "$action" == remove ]]; then
          [[ -f "$ZDX_PLUGINS_DIR/.zdx-plugins.lock" \
            && ! -L "$ZDX_PLUGINS_DIR/.zdx-plugins.lock" \
            && ${+_ZDX_PLUGINS_LOCK_FD} == 0 ]] || exit 37
        fi
        zstat -LH current -- "$ZDX_PLUGINS_DIR/$F308G_PLUGIN_NAME" || exit 38
        [[ "${current[device]}:${current[inode]}" == "${original[device]}:${original[inode]}" \
          && -d "$ZDX_PLUGINS_DIR/$F308G_PLUGIN_NAME/.git" \
          && "$(<"$entrypoint")" == "$original_entrypoint" ]] || exit 39
        stages=("$ZDX_PLUGINS_DIR"/.zdx-staging.*(DN))
        (( ${#stages} == 0 )) || exit 40
      done
      print -r -- optional-metadata-interrupted
    '
    [ "$status" -eq 0 ]
    [ "$output" = optional-metadata-interrupted ]
  done
}

@test "F308 gaps: whole doctor dry-run returns unresolved while printing a genuine other-package plan and excluding uncertain Git" {
  f308g_doctor_tools
  local code
  for code in 124 125; do
    export F308C_XCODE_RC="$code"
    run run_f308c_zsh '
      # Restore the actual doctor after the revised helper denial fixtures.
      # The public command, rows/counters, renderer and install-plan coordinator
      # remain real. Only the safe private-program trust and prompt boundaries
      # are controlled; --dry-run must never reach the latter or execute brew.
      unset _ZDX_DOCTOR_SOURCED
      () {
        emulate -L zsh
        unsetopt aliases
        builtin source "$1"
      } "$F308C_MODULES/zdx-doctor.zsh" || exit 30
      _zdx_doctor_program_trusted() {
        [[ $# == 2 && "$1" == "$CORE_PROBE_BIN/brew" && "$2" == user \
          && -f "$1" && -x "$1" && ! -L "$1" ]]
      }
      _zdx_doctor_confirm() {
        print -r -- prompt > "$HOME/prompt-ran"
        return 97
      }
      [[ ! -e "$CORE_PROBE_BIN/pipx" && ! -L "$CORE_PROBE_BIN/pipx" ]] || exit 31
      local -i rc=0 legitimate_plan=0
      local report="" row=""
      zdx-doctor --dry-run >"$HOME/gap-doctor.stdout" 2>"$HOME/gap-doctor.stderr" || rc=$?
      (( rc == 1 )) || exit 32
      [[ ! -s "$HOME/gap-doctor.stdout" && -s "$HOME/clt.argv" \
        && ! -e "$HOME/candidate-git.calls" && ! -e "$HOME/candidate-python.calls" \
        && ! -e "$HOME/prompt-ran" && ! -e "$HOME/gap-package-manager-ran" ]] || exit 33
      report="$(<"$HOME/gap-doctor.stderr")"
      [[ "$report" == *"Install Plan"* && "${report:l}" == *"dry run"* ]] || exit 34
      for row in "${(@f)report}"; do
        [[ "$row" == *"$CORE_PROBE_BIN/brew"* && "$row" == *"install pipx"* ]] \
          && legitimate_plan=1
        [[ "$row" != *"$CORE_PROBE_BIN/brew"*"install git"* ]] || exit 35
        [[ "$row" != "  git:"*"Installed ("* ]] || exit 37
      done
      (( legitimate_plan )) || exit 36
      [[ "$report" != *"brew install git"* ]] || exit 37
      print -r -- valid-plan-remains-unresolved
    '
    [ "$status" -eq 0 ]
    [ "$output" = valid-plan-remains-unresolved ]
  done
}
