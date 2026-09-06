#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  RENDER_REAL_FZF=$(command -v fzf || true)
  load test_helper
  export RENDER_DIR="$TEST_TEMP_DIR/rendering"
  mkdir "$RENDER_DIR"
  export TERM=xterm-256color LANG=C.UTF-8
  unset LC_ALL LC_CTYPE NO_COLOR ZDX_FZF_PLAIN ZDX_FZF_THEME
  unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE FZF_DEFAULT_COMMAND
  export RENDER_FZF_RC=0
  printf 'Visible Tâche 日本語|example-status|Descripción literal: café → archivo\n' > "$RENDER_DIR/input"
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\0' "$@" > "$RENDER_DIR/$RENDER_SUITE.argv"
printf '%s\0' "${FZF_DEFAULT_OPTS:-}" "${FZF_DEFAULT_OPTS_FILE:-}" \
  "${FZF_DEFAULT_COMMAND:-}" "${SHELL:-}" > "$RENDER_DIR/$RENDER_SUITE.environment"
[[ -z "${FZF_DEFAULT_OPTS:-}${FZF_DEFAULT_OPTS_FILE:-}${FZF_DEFAULT_COMMAND:-}" ]] || exit 97
[[ "${SHELL:-}" == /bin/sh ]] || exit 96
cat > "$RENDER_DIR/$RENDER_SUITE.input"
if [[ -n "${RENDER_EXEC_FZF:-}" ]]; then
  exec "$RENDER_EXEC_FZF" "$@" < "$RENDER_DIR/$RENDER_SUITE.input"
fi
if [[ "${RENDER_FZF_RC:-0}" == 0 ]]; then
  cat "$RENDER_DIR/$RENDER_SUITE.input"
fi
exit "${RENDER_FZF_RC:-0}"
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
  cat > "$RENDER_DIR/fixture.zsh" <<'FIXTURE'
typeset -ga render_suites=(ai app ci dev docker env file git gpu hf net py sys vpn ws zdx plugins)
_render_load() {
  local mode="${1:-standalone}" suite=""
  for suite in "${render_suites[@]}"; do
    if [[ "$suite" == plugins ]]; then
      source "$TEST_SUITE_ROOT/functions/zdx-plugins.zsh" || return
    else
      source "$TEST_SUITE_ROOT/functions/$suite-menu.zsh" || return
    fi
  done
  if [[ "$mode" == core ]]; then
    export ZSH_CUSTOM="$TEST_SUITE_ROOT"
    source "$TEST_SUITE_ROOT/functions.zsh" || return
    render_suites+=(core)
  else
    (( ! ${+functions[_tk_fzf_color_opts]} )) || return 1
  fi
}
_render_all() {
  local expected_rc="$1"
  shift
  local suite="" wrapper=""
  local -i actual_rc=0
  export RENDER_SUITE
  for suite in "${render_suites[@]}"; do
    RENDER_SUITE="$suite"
    case "$suite" in
      core) wrapper=_tk_fzf ;;
      plugins) wrapper=_zdx_plugins_fzf ;;
      *) wrapper="_${suite}_fzf" ;;
    esac
    actual_rc=0
    "$wrapper" "$@" < "$RENDER_DIR/input" > "$RENDER_DIR/$suite.stdout" || actual_rc=$?
    if (( actual_rc != expected_rc )); then
      print -u2 -r -- "$wrapper: expected $expected_rc, received $actual_rc"
      return 1
    fi
    if (( expected_rc == 0 )); then
      command cmp "$RENDER_DIR/input" "$RENDER_DIR/$suite.stdout" || return
    else
      [[ ! -s "$RENDER_DIR/$suite.stdout" ]] || return 1
    fi
  done
}
FIXTURE
  cat > "$RENDER_DIR/assert-options.py" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
expected_count = int(sys.argv[3])
files = list(root.glob('*.argv'))
assert len(files) == expected_count, (mode, len(files))
for path in files:
    args = path.read_bytes().decode().split('\0')[:-1]
    color = [arg for arg in args if arg.startswith('--color=') or arg == '--no-color']
    assert color, path
    if mode == 'native':
        spec = color[-1].removeprefix('--color=')
        fields = spec.split(',')
        assert fields[0] in ('16', 'base16'), (path, spec)
        for role in ('fg', 'bg', 'fg+', 'bg+'):
            assert f'{role}:-1' in fields, (path, role, spec)
        assert '#' not in spec, (path, spec)
    elif mode == 'custom':
        assert color[-1] == '--color=16,fg:0,bg:7,fg+:7,bg+:0', (path, color)
    elif mode in ('no-color', 'plain'):
        assert color[-1] == '--no-color', (path, color)
    if mode in ('ascii', 'plain'):
        unicode = [arg for arg in args if arg in ('--unicode', '--no-unicode')]
        pointer = [arg for arg in args if arg.startswith('--pointer=')]
        marker = [arg for arg in args if arg.startswith('--marker=')]
        assert unicode[-1] == '--no-unicode', (path, unicode)
        assert pointer[-1] == '--pointer=>', (path, pointer)
        assert marker[-1] == '--marker=+', (path, marker)
    elif mode == 'unicode':
        assert '--no-unicode' not in args, (path, args)
PY
}

teardown() { cleanup_sandbox; }

@test "menu rendering: every wrapper isolates inherited defaults and preserves caller state and status" {
  run zsh -f -c '
    source "$RENDER_DIR/fixture.zsh" || exit
    _render_load core || exit
    export FZF_DEFAULT_OPTS="--header-lines=999 --read0 --no-input"
    export FZF_DEFAULT_OPTS_FILE="$HOME/missing options file"
    export FZF_DEFAULT_COMMAND="do-not-run"
    export SHELL="/fixture/fish"
    local expected_rc=0
    for expected_rc in 0 42 130 143; do
      export RENDER_FZF_RC="$expected_rc"
      _render_all "$expected_rc" || exit
      [[ "$FZF_DEFAULT_OPTS" == "--header-lines=999 --read0 --no-input" \
        && "$FZF_DEFAULT_OPTS_FILE" == "$HOME/missing options file" \
        && "$FZF_DEFAULT_COMMAND" == do-not-run \
        && "$SHELL" == /fixture/fish ]] || exit 1
    done
    unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE FZF_DEFAULT_COMMAND SHELL
    export RENDER_FZF_RC=0
    _render_all 0 || exit
    (( ! ${+FZF_DEFAULT_OPTS} && ! ${+FZF_DEFAULT_OPTS_FILE} \
      && ! ${+FZF_DEFAULT_COMMAND} && ! ${+SHELL} ))
  '
  [ "$status" -eq 0 ]
}

@test "menu rendering: standalone suites use paired terminal colors without a core import" {
  run zsh -f -c '
    source "$RENDER_DIR/fixture.zsh" || exit
    _render_load standalone || exit
    _render_all 0
  '
  [ "$status" -eq 0 ]
  run python3 "$RENDER_DIR/assert-options.py" "$RENDER_DIR" native 17
  [ "$status" -eq 0 ]
}

@test "menu rendering: core themes remain configurable at invocation time across all wrappers" {
  run zsh -f -c '
    source "$RENDER_DIR/fixture.zsh" || exit
    _render_load core || exit
    _render_all 0 || exit
    command python3 "$RENDER_DIR/assert-options.py" "$RENDER_DIR" native 18 || exit
    export ZDX_FZF_THEME="16,fg:0,bg:7,fg+:7,bg+:0"
    _render_all 0
  '
  [ "$status" -eq 0 ]
  run python3 "$RENDER_DIR/assert-options.py" "$RENDER_DIR" custom 18
  [ "$status" -eq 0 ]
}

@test "menu rendering: NO_COLOR overrides custom themes and explicit call-site colors" {
  run zsh -f -c '
    source "$RENDER_DIR/fixture.zsh" || exit
    _render_load core || exit
    export NO_COLOR=1 ZDX_FZF_THEME="16,fg:0,bg:7,fg+:7,bg+:0"
    _render_all 0 --color=light --pointer="▶" --marker="✓"
  '
  [ "$status" -eq 0 ]
  run python3 "$RENDER_DIR/assert-options.py" "$RENDER_DIR" no-color 18
  [ "$status" -eq 0 ]
}

@test "menu rendering: plain mode and dumb terminals override call-site Unicode and colors" {
  run zsh -f -c '
    source "$RENDER_DIR/fixture.zsh" || exit
    _render_load core || exit
    local mode=""
    for mode in plain dumb; do
      unset ZDX_FZF_PLAIN
      TERM=xterm-256color
      if [[ "$mode" == plain ]]; then ZDX_FZF_PLAIN=0; else TERM=dumb; fi
      _render_all 0 --color=light --unicode --pointer="▶" --marker="✓" || exit
      command python3 "$RENDER_DIR/assert-options.py" "$RENDER_DIR" plain 18 || exit
    done
  '
  [ "$status" -eq 0 ]
}

@test "menu rendering: C and POSIX locale fallback respects locale precedence" {
  run zsh -f -c '
    source "$RENDER_DIR/fixture.zsh" || exit
    _render_load core || exit
    local mode=""
    for mode in all ctype language unset; do
      unset LC_ALL LC_CTYPE
      LANG=C.UTF-8
      case "$mode" in
        all) LC_ALL=C; LC_CTYPE=C.UTF-8 ;;
        ctype) LC_CTYPE=POSIX ;;
        language) LANG=C ;;
        unset) unset LANG ;;
      esac
      _render_all 0 --unicode --pointer="▶" --marker="✓" || exit
      command python3 "$RENDER_DIR/assert-options.py" "$RENDER_DIR" ascii 18 || exit
    done
    LC_ALL=C.UTF-8
    LC_CTYPE=C
    _render_all 0 --unicode --pointer="▶" --marker="✓" || exit
    command python3 "$RENDER_DIR/assert-options.py" "$RENDER_DIR" unicode 18
  '
  [ "$status" -eq 0 ]
}

@test "menu rendering: real fzf filtering cannot inherit options that hide input rows" {
  [ -n "$RENDER_REAL_FZF" ] || skip "real fzf is not installed"
  export RENDER_EXEC_FZF="$RENDER_REAL_FZF"
  run zsh -f -c '
    source "$RENDER_DIR/fixture.zsh" || exit
    _render_load core || exit
    export FZF_DEFAULT_OPTS="--header-lines=999 --read0 --print0"
    export FZF_DEFAULT_OPTS_FILE="$HOME/missing-options"
    export FZF_DEFAULT_COMMAND="do-not-run"
    export SHELL="/fixture/fish"
    _render_all 0 --filter=Visible
  '
  [ "$status" -eq 0 ]
}
