#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# External tools that differ between GNU/Linux and macOS: the core timeout
# service without GNU timeout, and BSD chmod argument parsing.

setup() {
  load test_helper
  mkdir -m 700 "$TEST_TEMP_DIR/runtime"
  PLATFORM_TMP=$(cd -P "$TEST_TEMP_DIR/runtime" && pwd -P)
  export PLATFORM_TMP
  export PLATFORM_CALLS="$TEST_TEMP_DIR/timeout-calls"
  : > "$PLATFORM_CALLS"

  # Hides GNU timeout and Homebrew gtimeout, as on a stock macOS host.
  export PLATFORM_NO_TIMEOUT="$TEST_TEMP_DIR/no-timeout.zsh"
  cat > "$PLATFORM_NO_TIMEOUT" <<'ZSH'
command() {
  if [[ "$1" == -v && ( "$2" == timeout || "$2" == gtimeout ) ]]; then
    return 1
  fi
  builtin command "$@"
}
ZSH
}

teardown() {
  cleanup_sandbox
}

_platform_timeout_recorder() {
  local name="$1"
  cat > "$TEST_MOCK_BIN/$name" <<SH
#!/usr/bin/env bash
printf '$name' >> "\$PLATFORM_CALLS"
printf ' %q' "\$@" >> "\$PLATFORM_CALLS"
printf '\n' >> "\$PLATFORM_CALLS"
[[ "\${1:-}" == -k && "\${2:-}" == 2s && "\${3:-}" == *s ]] || exit 98
shift 3
exec "\$@"
SH
  chmod +x "$TEST_MOCK_BIN/$name"
}

@test "platform tools: the timeout service validates arguments before running" {
  run run_zsh '
    export TMPDIR="$PLATFORM_TMP"
    local marker="$HOME/ran"
    _zdx_run_with_timeout x touch "$marker"; print -r -- "word=$?"
    _zdx_run_with_timeout 1234567 touch "$marker"; print -r -- "digits=$?"
    _zdx_run_with_timeout -1 touch "$marker"; print -r -- "negative=$?"
    _zdx_run_with_timeout 5; print -r -- "command=$?"
    _zdx_run_with_timeout; print -r -- "empty=$?"
    [[ ! -e "$marker" ]] && print -r -- "not-run"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'word=2\ndigits=2\nnegative=2\ncommand=2\nempty=2\nnot-run' ]
}

@test "platform tools: timeout is preferred, then gtimeout, with a KILL grace" {
  _platform_timeout_recorder timeout
  _platform_timeout_recorder gtimeout

  run run_zsh '
    _zdx_run_with_timeout 7 printf "%s\n" first-ok || return 91
    command() {
      if [[ "$1" == -v && "$2" == timeout ]]; then
        return 1
      fi
      builtin command "$@"
    }
    _zdx_run_with_timeout 9 printf "%s\n" second-ok || return 92
    _zdx_run_with_timeout 0 printf "%s\n" unbounded-ok
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'first-ok\nsecond-ok\nunbounded-ok' ]
  [ "$(cat "$PLATFORM_CALLS")" = \
    $'timeout -k 2s 7s printf %s\\\\n first-ok\ngtimeout -k 2s 9s printf %s\\\\n second-ok' ]
}

@test "platform tools: the Zsh watchdog bounds a command without timeout or gtimeout" {
  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    export TMPDIR="$PLATFORM_TMP"
    local -F started=$EPOCHREALTIME
    _zdx_run_with_timeout 1 sleep 20
    local -i timeout_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 8 )) || return 93
    _zdx_run_with_timeout 5 zsh -fc "exit 7"
    print -r -- "bounded=$timeout_rc passthrough=$?"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "bounded=124 passthrough=7" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: the watchdog stops descendants and keeps its marker private" {
  mkdir -m 700 "$TEST_TEMP_DIR/physical"
  ln -s "$TEST_TEMP_DIR/physical" "$TEST_TEMP_DIR/alias"
  mkdir -m 700 "$TEST_TEMP_DIR/physical/tmp"
  export PLATFORM_CANONICAL
  PLATFORM_CANONICAL=$(cd -P "$TEST_TEMP_DIR/physical/tmp" && pwd -P)

  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    export TMPDIR="$TEST_TEMP_DIR/alias/tmp"
    _zdx_run_with_timeout 1 zsh -fc "
      markers=(\"\$PLATFORM_CANONICAL\"/zdx-timeout.*(N))
      print -r -- \${#markers} > \"\$HOME/markers\"
      sleep 20 &
      print -r -- \$! > \"\$HOME/descendant.pid\"
      wait
    "
    local -i timeout_rc=$?
    local descendant_pid=""
    descendant_pid=$(<"$HOME/descendant.pid") || return 91
    if builtin kill -0 "$descendant_pid" 2>/dev/null; then
      builtin kill -KILL "$descendant_pid" 2>/dev/null
      return 92
    fi
    print -r -- "rc=$timeout_rc markers=$(<"$HOME/markers")"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 markers=1" ]
  [ -z "$(ls -A "$PLATFORM_CANONICAL")" ]
}

@test "platform tools: the watchdog refuses an unsafe TMPDIR without running the command" {
  mkdir -m 777 "$TEST_TEMP_DIR/shared"
  chmod 777 "$TEST_TEMP_DIR/shared"

  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    export TMPDIR="$TEST_TEMP_DIR/shared"
    _zdx_run_with_timeout 5 touch "$HOME/ran"
    print -r -- "rc=$?"
    [[ ! -e "$HOME/ran" ]] && print -r -- "not-run"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"TMPDIR must be an owner-private or root-owned sticky directory"* ]]
  [[ "$output" == *$'rc=1\nnot-run' ]]
  [ -z "$(ls -A "$TEST_TEMP_DIR/shared")" ]
}

@test "platform tools: System delegates to the core and keeps its standalone fallback" {
  run run_zsh '
    _zdx_run_with_timeout() {
      print -r -- "core:$*"
      return 42
    }
    _sys_run_with_timeout 3 printf ok
  '
  [ "$status" -eq 42 ]
  [ "$output" = "core:3 printf ok" ]

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    export TMPDIR="$3"
    _sys_run_with_timeout 1 sleep 20
    print -r -- "standalone=$?"
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_NO_TIMEOUT" "$PLATFORM_TMP"
  [ "$status" -eq 0 ]
  [ "$output" = "standalone=124" ]
}

# BSD chmod parses options with getopt(3), which stops at the first operand:
# in `chmod 700 -- path` the `--` becomes a file operand and chmod exits 1.
# This shim reproduces that on Linux so the argument order cannot regress.
_platform_bsd_chmod() {
  local real_chmod
  real_chmod=$(command -v chmod)
  mkdir -p "$TEST_TEMP_DIR/bsd-bin"
  cat > "$TEST_TEMP_DIR/bsd-bin/chmod" <<SH
#!/usr/bin/env bash
operand_seen=0
for argument in "\$@"; do
  if (( operand_seen )) && [[ "\$argument" == -- ]]; then
    printf 'chmod: --: No such file or directory\n' >&2
    exit 1
  fi
  case "\$argument" in
    --) break ;;
    -*) ;;
    *) operand_seen=1 ;;
  esac
done
exec '$real_chmod' "\$@"
SH
  chmod +x "$TEST_TEMP_DIR/bsd-bin/chmod"
  export PATH="$TEST_TEMP_DIR/bsd-bin:$PATH"
}

@test "platform tools: private modes are applied with BSD chmod argument parsing" {
  _platform_bsd_chmod
  export MOCK_FZF_MODE=response
  export MOCK_FZF_RESPONSE=picked

  run run_zsh '
    export TMPDIR="$PLATFORM_TMP"
    local probe="$HOME/order-probe"
    command mkdir -p "$probe" || return 90
    command chmod 700 -- "$probe" 2>/dev/null && return 91
    command chmod -- 700 "$probe" || return 92

    local created=""
    created=$(_vpn_make_private_temp_dir zdx-vpn-chmod) || return 93
    command rmdir -- "$created" || return 94

    local capture="" REPLY=""
    for capture in _py_fzf_capture _file_fzf_capture; do
      REPLY=""
      "$capture" </dev/null >/dev/null || return 95
      [[ "$REPLY" == picked ]] || return 96
    done

    local -a reply=()
    _dev_update_workspace_create || return 97
    _dev_update_workspace_cleanup "${reply[@]}" || return 98
    print -r -- "private modes applied"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "private modes applied" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: product code never places the option terminator after a mode" {
  run grep -rnE \
    'chmod[[:space:]]+[^-[:space:]][^[:space:]]*[[:space:]]+--([[:space:]]|$)' \
    "$TEST_SUITE_ROOT/functions" "$TEST_SUITE_ROOT/functions.zsh" \
    "$TEST_SUITE_ROOT/completions" "$TEST_SUITE_ROOT/scripts"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "platform tools: product code loads only zstat from zsh/stat" {
  # A full zsh/stat load adds a stat builtin that shadows the external stat
  # command in the user's interactive shell for the rest of the session.
  local offenders=""
  offenders=$(grep -rnIE 'zmodload[^#]*zsh/stat' \
    "$TEST_SUITE_ROOT/functions" "$TEST_SUITE_ROOT/functions.zsh" \
    "$TEST_SUITE_ROOT/completions" "$TEST_SUITE_ROOT/scripts" \
    "$TEST_SUITE_ROOT/.demo" | grep -v -- '-F zsh/stat b:zstat' || true)
  [ -z "$offenders" ]
}

@test "platform tools: suite helpers keep the external stat command" {
  run run_zsh '
    local suite=""
    for suite in git dev file env py sys vpn ws; do
      source "$ZSH_CUSTOM/functions/$suite-menu.zsh" || exit 1
    done
    # Each helper loads zstat; their verdicts do not matter here.
    _zdx_resolve_trusted_dir "$TMPDIR" >/dev/null 2>&1
    _git_temp_parent_safe >/dev/null 2>&1
    _dev_temp_parent_safe >/dev/null 2>&1
    _sys_temp_parent_safe >/dev/null 2>&1
    _file_validate_temp_parent "$TMPDIR" >/dev/null 2>&1
    _env_validate_temp_parent "$TMPDIR" >/dev/null 2>&1
    _py_validate_temp_parent "$TMPDIR" >/dev/null 2>&1
    _ws_validate_temp_parent "$TMPDIR" >/dev/null 2>&1
    (( ${+builtins[zstat]} )) || exit 4
    (( ! ${+builtins[stat]} )) || exit 5
    print -r -- "$(whence -w stat)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *": builtin"* ]]
}

@test "platform tools: the plugin entrypoint keeps the external stat command" {
  run zsh -fc '
    source "$1/zdx-suite.plugin.zsh" >/dev/null 2>&1 || exit 3
    (( ${+builtins[zstat]} )) || exit 4
    (( ! ${+builtins[stat]} )) || exit 5
    print -r -- "$(whence -w stat)"
  ' zsh "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *": builtin"* ]]
}
