#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  export DEMO_CASE="$TEST_TEMP_DIR/demo-case"
  export DEMO_REPO="$DEMO_CASE/repo"
  export TMPDIR="$DEMO_CASE/runtime"
  mkdir -p "$DEMO_REPO/.demo" "$TMPDIR"
  chmod 700 "$DEMO_CASE" "$TMPDIR"
  cp "$TEST_SUITE_ROOT/functions.zsh" "$DEMO_REPO/"
  cp -R "$TEST_SUITE_ROOT/functions" "$DEMO_REPO/"
  cp "$TEST_SUITE_ROOT/.demo/record.zsh" \
    "$TEST_SUITE_ROOT/.demo/session.zsh" \
    "$TEST_SUITE_ROOT/.demo/demo.tape" \
    "$TEST_SUITE_ROOT/.demo/git-demo.conf" "$DEMO_REPO/.demo/"
  printf 'previous-gif\n' > "$DEMO_REPO/.demo/demo.gif"
  printf 'previous-png\n' > "$DEMO_REPO/.demo/demo.png"
  printf 'success\n' > "$DEMO_CASE/mode"

  local tool
  for tool in ttyd fzf demo-browser; do
    cat > "$TEST_MOCK_BIN/$tool" <<'MOCK'
#!/usr/bin/env bash
printf 'fixture tool 1.0.0\n'
MOCK
    chmod +x "$TEST_MOCK_BIN/$tool"
  done
  export ZDX_DEMO_BROWSER="$TEST_MOCK_BIN/demo-browser"

  cat > "$TEST_MOCK_BIN/ffprobe" <<'MOCK'
#!/usr/bin/env bash
case "${*: -1}" in
  *.gif) printf 'gif\n' ;;
  *.png) printf 'png\n' ;;
  *) exit 92 ;;
esac
MOCK
  chmod +x "$TEST_MOCK_BIN/ffprobe"

  {
    printf '#!/usr/bin/env bash\nset -eu\n'
    printf 'fixture_dir=%q\n' "$DEMO_CASE"
    cat <<'MOCK'
[[ "$HOME" == "$ZDX_DEMO_ROOT/home" ]]
[[ "$ZDOTDIR" == "$ZDX_DEMO_ROOT/zdotdir" ]]
[[ "$TMPDIR" == "$ZDX_DEMO_ROOT/tmp" ]]
for name in DEMO_PRIVATE_TOKEN BASH_ENV ENV GIT_DIR ZDX_PLUGINS_DIR; do
  [[ ! -v "$name" ]]
done
[[ -z "${FZF_DEFAULT_OPTS:-}${FZF_DEFAULT_OPTS_FILE:-}${FZF_DEFAULT_COMMAND:-}" ]]
[[ "$GIT_CEILING_DIRECTORIES" == "$ZDX_DEMO_ROOT" ]]
no_stdin=false
no_overwrite=false
input=''
previous=''
for argument in "$@"; do
  [[ "$previous" != -i ]] || input="$argument"
  [[ "$argument" != -nostdin ]] || no_stdin=true
  [[ "$argument" != -n ]] || no_overwrite=true
  previous="$argument"
done
destination="${*: -1}"
[[ "$no_stdin" == true && "$no_overwrite" == true ]]
[[ "$input" == "$ZDX_DEMO_ROOT/"* && -f "$input" ]]
[[ "$destination" == "$ZDX_DEMO_ROOT/"*.gif ]]
[[ "$destination" != "$input" && ! -e "$destination" ]]
printf 'converter-environment-and-target:ok\n' > "$fixture_dir/converter.checks"
mode=$(cat "$fixture_dir/mode")
if [[ "$mode" == conversion-failure ]]; then
  printf 'partial conversion\n' > "$destination"
  exit 42
fi
printf 'GIF89a converted fixture output\n' > "$destination"
# A valid 1.5 MiB converted GIF exercises the specific demo exception.
last_byte=1572863
[[ "$mode" != oversized-gif ]] || last_byte=2097152
dd if=/dev/zero of="$destination" bs=1 count=1 seek="$last_byte" conv=notrunc 2>/dev/null
MOCK
  } > "$TEST_MOCK_BIN/ffmpeg"
  chmod +x "$TEST_MOCK_BIN/ffmpeg"

  {
    printf '#!/usr/bin/env bash\nset -eu\n'
    printf 'fixture_dir=%q\n' "$DEMO_CASE"
    cat <<'MOCK'
if [[ "${1:-}" == --version ]]; then
  printf 'vhs version v0.11.0\n'
  exit 0
fi
printf '%s\n' "$ZDX_DEMO_ROOT" > "$fixture_dir/root.path"
mode=$(cat "$fixture_dir/mode")
if [[ "$mode" == replacement ]]; then
  mv -- "$ZDX_DEMO_ROOT" "$fixture_dir/displaced-root"
  mkdir -m 700 -- "$ZDX_DEMO_ROOT"
  printf 'unrelated replacement\n' > "$ZDX_DEMO_ROOT/keep.txt"
  exit 41
fi
mkdir -p .demo
printf 'GIF89a fixture output\n' > .demo/demo.gif
if [[ "$mode" == failure ]]; then
  exit 41
fi
printf '\211PNG\r\n\032\nfixture output\n' > .demo/demo.png
if [[ "$mode" == oversized-png ]]; then
  dd if=/dev/zero of=.demo/demo.png bs=1 count=1 seek=1048576 conv=notrunc 2>/dev/null
fi

# Check named values only: never record the inherited environment wholesale.
[[ "$HOME" == "$ZDX_DEMO_ROOT/home" ]]
[[ "$ZDOTDIR" == "$ZDX_DEMO_ROOT/zdotdir" ]]
[[ "$TMPDIR" == "$ZDX_DEMO_ROOT/tmp" ]]
for name in XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR; do
  [[ "${!name}" == "$ZDX_DEMO_ROOT/"* ]]
done
for name in DEMO_PRIVATE_TOKEN GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE \
  GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS \
  BASH_ENV ENV ZDX_PLUGINS_DIR ZDX_FZF_THEME ZDX_FZF_PLAIN NO_COLOR; do
  [[ ! -v "$name" ]]
done
[[ -z "${FZF_DEFAULT_OPTS:-}${FZF_DEFAULT_OPTS_FILE:-}${FZF_DEFAULT_COMMAND:-}" ]]
[[ "$GIT_CONFIG_NOSYSTEM" == 1 ]]
[[ "$GIT_CONFIG_GLOBAL" == "$ZDX_DEMO_SOURCE_ROOT/.demo/git-demo.conf" ]]
[[ "$GIT_CEILING_DIRECTORIES" == "$ZDX_DEMO_ROOT" ]]
printf 'renderer-environment:ok\n' > "$fixture_dir/renderer.checks"

# Exercise the real session initializer under the renderer's closed environment.
zsh -f > "$fixture_dir/session.stdout" 2> "$fixture_dir/session.stderr" <<'ZSH'
builtin source "$ZDX_DEMO_SOURCE_ROOT/.demo/session.zsh" || exit
_zdx_demo_session || exit
[[ "$PWD" == "$ZDX_DEMO_ROOT/home/workspace/zdx-demo" ]] || exit 93
[[ "$HOME" == "$ZDX_DEMO_ROOT/home" ]] || exit 94
[[ "${_ZDX_FUNCTIONS_DIR:-}" == "$ZDX_DEMO_SOURCE_ROOT/functions" ]] || exit 95
for suite in dev sys ai git file; do
  (( $+functions[${suite}-menu] )) || exit 96
done

# Exercise the real routing guard with harmless menu recorders. Public backend
# recorders keep a missing dispatcher guard from running a real host action.
(
  typeset -a routed=()
  dev-menu() { (( $# == 0 )) || return 91; routed+=(dev); }
  sys-menu() { (( $# == 0 )) || return 91; routed+=(sys); }
  ai-menu() { (( $# == 0 )) || return 91; routed+=(ai); }
  git-menu() { (( $# == 0 )) || return 91; routed+=(git); }
  file-menu() { (( $# == 0 )) || return 91; routed+=(file); }
  for suite in dev sys ai git file; do
    _zdx_dispatch_suite "$suite" || exit
  done
  [[ "${(j:,:)routed}" == dev,sys,ai,git,file ]] || exit 96

  command mkdir -- "$ZDX_DEMO_ROOT/guard-check" || exit
  ZDX_DEMO_ROOT="$ZDX_DEMO_ROOT/guard-check"
  _zdx_dispatch_suite vpn
  (( $? == 99 )) || exit 97
  _zdx_dispatch_suite dev unexpected
  (( $? == 99 )) || exit 97
  _zdx_dispatch_suite
  (( $? == 99 )) || exit 97
  [[ "${(j:,:)routed}" == dev,sys,ai,git,file ]] || exit 96

  _demo_unexpected_backend() {
    print -r -- unexpected > "$ZDX_DEMO_ROOT/backend.called"
    return 98
  }
  file-find() { _demo_unexpected_backend; }
  dev-update-deps() { _demo_unexpected_backend; }
  update-system() { _demo_unexpected_backend; }
  ai-update() { _demo_unexpected_backend; }
  git-pull() { _demo_unexpected_backend; }
  _sys_dispatch_prepare() { return 0; }
  typeset -A actions=(dev dev-update-deps sys update-system ai ai-update git git-pull file file-find)
  for suite in dev sys ai git file; do
    "_${suite}_dispatch" "${actions[$suite]}"
    (( $? == 99 )) || exit 97
  done
  [[ ! -e "$ZDX_DEMO_ROOT/backend.called" ]] || exit 98
  [[ "$(<"$ZDX_DEMO_ROOT/action.denied")" == denied ]] || exit 97
  for suite in dev sys ai git file; do
    _zdx_demo_check 0 || exit
  done
  _zdx_demo_finish && exit 97
  [[ ! -e "$ZDX_DEMO_ROOT/session.complete" ]] || exit 97
) || exit

# A failed return adds no successful step; four returns cannot publish the
# expanded tour, and five successful returns can publish its completion marker.
_zdx_demo_check 130
(( $? == 130 )) || exit 97
[[ ! -e "$ZDX_DEMO_ROOT/steps" ]] || exit 97
for suite in dev sys ai git; do
  _zdx_demo_check 0 || exit
done
_zdx_demo_finish && exit 97
[[ ! -e "$ZDX_DEMO_ROOT/session.complete" ]] || exit 97
_zdx_demo_check 0 || exit
_zdx_demo_finish
ZSH
[[ "$(cat "$ZDX_DEMO_ROOT/session.complete")" == 0 ]]
MOCK
  } > "$TEST_MOCK_BIN/vhs"
  chmod +x "$TEST_MOCK_BIN/vhs"
}

teardown() { cleanup_sandbox; }

@test "demo recording: hostile startup and backend environment cannot enter the recorded session" {
  mkdir -p "$HOME/startup" "$HOME/.config/zdx" "$HOME/hostile-xdg"
  local startup_marker="$DEMO_CASE/startup-ran"
  printf 'printf "unexpected\\n" >> %q\n' "$startup_marker" > "$HOME/startup/.zshenv"
  cp "$HOME/startup/.zshenv" "$HOME/startup/.zshrc"
  cp "$HOME/startup/.zshenv" "$HOME/.config/zdx/config.zsh"
  export ZDOTDIR="$HOME/startup"
  export BASH_ENV="$HOME/startup/.zshenv" ENV="$HOME/startup/.zshenv"
  export XDG_CONFIG_HOME="$HOME/hostile-xdg" XDG_DATA_HOME="$HOME/hostile-xdg"
  export XDG_CACHE_HOME="$HOME/hostile-xdg" XDG_STATE_HOME="$HOME/hostile-xdg"
  export XDG_RUNTIME_DIR="$HOME/hostile-xdg"
  export GIT_DIR="$HOME/private.git" GIT_WORK_TREE="$HOME/private-worktree"
  export GIT_INDEX_FILE="$HOME/private-index" GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOME/hooks"
  export GIT_CONFIG_PARAMETERS="'user.email=private@example.invalid'"
  export GIT_CONFIG_GLOBAL="$HOME/private-gitconfig" GIT_CONFIG_NOSYSTEM=0
  export GIT_CEILING_DIRECTORIES="$HOME/private-ceiling"
  export FZF_DEFAULT_OPTS='--header-lines=999 --read0'
  export FZF_DEFAULT_OPTS_FILE="$HOME/missing-fzf-options"
  export FZF_DEFAULT_COMMAND='false'
  export ZDX_PLUGINS_DIR="$HOME/private-plugins"
  export _ZDX_FUNCTIONS_SOURCED=1 _FILE_MENU_SOURCED=1 _DEV_MENU_SOURCED=1
  export _SYS_MENU_SOURCED=1 _AI_MENU_SOURCED=1 _GIT_MENU_SOURCED=1
  export ZDX_FZF_THEME='fg:#ffffff,bg:#ffffff' ZDX_FZF_PLAIN=1 NO_COLOR=1
  export DEMO_PRIVATE_TOKEN='private-fixture-value'

  run zsh -f "$DEMO_REPO/.demo/record.zsh"

  [ "$status" -eq 0 ]
  [ -s "$DEMO_CASE/root.path" ]
  [ "$(cat "$DEMO_CASE/renderer.checks")" = 'renderer-environment:ok' ]
  [ "$(cat "$DEMO_CASE/converter.checks")" = 'converter-environment-and-target:ok' ]
  [ ! -e "$startup_marker" ]
  [ ! -e "$(cat "$DEMO_CASE/root.path")" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [[ "$output" != *'private-fixture-value'* ]]
  [ "$(head -c 6 "$DEMO_REPO/.demo/demo.gif")" = GIF89a ]
  [ "$(wc -c < "$DEMO_REPO/.demo/demo.gif")" -eq 1572864 ]

  # Git ceiling directories are colon-separated. Reject an unrepresentable
  # canonical parent before a renderer can inspect any ancestor repository.
  cp "$DEMO_REPO/.demo/demo.gif" "$DEMO_CASE/before-colon.gif"
  cp "$DEMO_REPO/.demo/demo.png" "$DEMO_CASE/before-colon.png"
  mkdir -m 700 "$DEMO_CASE/runtime:ambiguous"
  ln -s "$DEMO_CASE/runtime:ambiguous" "$DEMO_CASE/runtime-alias"
  rm -f "$DEMO_CASE/root.path"
  local candidate_tmp
  for candidate_tmp in "$DEMO_CASE/runtime:ambiguous" "$DEMO_CASE/runtime-alias"; do
    run env TMPDIR="$candidate_tmp" zsh -f "$DEMO_REPO/.demo/record.zsh"

    [ "$status" -ne 0 ]
    [ ! -e "$DEMO_CASE/root.path" ]
    [ -z "$(find "$DEMO_CASE/runtime:ambiguous" -mindepth 1 -print -quit)" ]
    cmp -s "$DEMO_REPO/.demo/demo.gif" "$DEMO_CASE/before-colon.gif"
    cmp -s "$DEMO_REPO/.demo/demo.png" "$DEMO_CASE/before-colon.png"
  done
}

@test "demo recording: failed or oversized media preserve previous files and clean only the temporary workspace" {
  printf 'keep sibling\n' > "$TMPDIR/unrelated.txt"
  local failure_mode
  for failure_mode in failure conversion-failure oversized-gif oversized-png; do
    printf '%s\n' "$failure_mode" > "$DEMO_CASE/mode"
    rm -f "$DEMO_CASE/root.path" "$DEMO_CASE/converter.checks"

    run zsh -f "$DEMO_REPO/.demo/record.zsh"

    [ "$status" -ne 0 ]
    [ -s "$DEMO_CASE/root.path" ]
    [ "$(cat "$DEMO_REPO/.demo/demo.gif")" = previous-gif ]
    [ "$(cat "$DEMO_REPO/.demo/demo.png")" = previous-png ]
    [ "$(cat "$TMPDIR/unrelated.txt")" = 'keep sibling' ]
    [ ! -e "$(cat "$DEMO_CASE/root.path")" ]
    [ ! -s "$MOCK_SUDO_LOG" ]
    if [[ "$failure_mode" != failure ]]; then
      [ "$(cat "$DEMO_CASE/converter.checks")" = 'converter-environment-and-target:ok' ]
    else
      [ ! -e "$DEMO_CASE/converter.checks" ]
    fi
  done
}

@test "demo recording: a replaced temporary directory is retained instead of adopted for cleanup" {
  printf 'replacement\n' > "$DEMO_CASE/mode"

  run zsh -f "$DEMO_REPO/.demo/record.zsh"

  [ "$status" -ne 0 ]
  [ -s "$DEMO_CASE/root.path" ]
  [ "$(cat "$DEMO_REPO/.demo/demo.gif")" = previous-gif ]
  [ "$(cat "$DEMO_REPO/.demo/demo.png")" = previous-png ]
  [ -d "$DEMO_CASE/displaced-root" ]
  [ "$(cat "$(cat "$DEMO_CASE/root.path")/keep.txt")" = 'unrelated replacement' ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}
