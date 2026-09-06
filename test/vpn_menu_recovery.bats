#!/usr/bin/env bats
# Literal Zsh programs and per-test exported controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export LC_ALL=C TERM=dumb NO_COLOR=1
  export VPN_CONFIG_DIR="$HOME/wireguard" VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/vpn-stats"
  export MENU_ACTION_RC=130 MENU_PICKER_CANCEL=0
  export MENU_ACTION=vpn-off MENU_TARGET=wg0
}

teardown() {
  cleanup_sandbox
}

run_recovery_menu() {
  run_zsh '
    local menu_row="Fixture action|$MENU_ACTION|Reviewed fixture action.|$MENU_TARGET"
    _vpn_state_load() {
      print -r -- state >> "$HOME/state.calls"
      _VPN_MENU_CONFIG_ACCESS_STATE=direct
      _VPN_MENU_WG_ACCESS_STATE=direct
      _VPN_MENU_ACTIVE_KNOWN=1
      _VPN_MENU_ACTIVE_IFACES=(wg0)
    }
    _vpn_menu_rows() { print -r -- "$menu_row"; }
    _vpn_menu_context() { print -r -- "Fixture context"; }
    _vpn_menu_capabilities() { print -r -- "Fixture capabilities"; }
    _vpn_preview_render() { print -r -- "Fixture preview for $1"; }
    fzf() {
      local offered="$(command cat)"
      [[ "$offered" == "$menu_row" ]] || return 97
      _vpn_private_dir_identity "$_VPN_PREVIEW_DIR" "fixture preview" >/dev/null \
        || return 98
      _vpn_state_validate_file "$_VPN_PREVIEW_DIR/0" "$_VPN_PREVIEW_DIR" \
        "fixture pane" "$_VPN_MAX_PREVIEW_BYTES" || return 99
      print -r -- "$_VPN_PREVIEW_DIR" >> "$HOME/preview.paths"
      print -r -- fzf >> "$HOME/fzf.calls"
      if (( MENU_PICKER_CANCEL )) || [[ -e "$HOME/dispatch.calls" ]]; then
        return 130
      fi
      print -r -- "$menu_row"
    }
    _vpn_dispatch() {
      [[ "$1" == "$MENU_ACTION" ]] || return 97
      if [[ -n "$MENU_TARGET" ]]; then
        [[ $# == 2 && "$2" == "$MENU_TARGET" ]] || return 98
      else
        [[ $# == 1 ]] || return 99
      fi
      print -r -- "$1:${2:-}" >> "$HOME/dispatch.calls"
      return "$MENU_ACTION_RC"
    }
    _vpn_menu_pause() { print -r -- pause >> "$HOME/pause.calls"; }

    vpn-menu > "$HOME/menu.stdout"
    local menu_rc=$?
    [[ -z "$_VPN_PREVIEW_DIR" && -z "$_VPN_PREVIEW_DIR_IDENTITY" ]] || return 96
    return "$menu_rc"
  '
}

assert_previews_removed() {
  [ -s "$HOME/preview.paths" ]
  local preview_dir
  while IFS= read -r preview_dir; do
    [ ! -e "$preview_dir" ]
  done < "$HOME/preview.paths"
  [ ! -s "$HOME/menu.stdout" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn menu recovery: action status 130 exits without another pause or selection" {
  run run_recovery_menu
  [ "$status" -eq 130 ]
  [ "$(wc -l < "$HOME/dispatch.calls")" -eq 1 ]
  [ "$(wc -l < "$HOME/fzf.calls")" -eq 1 ]
  [ "$(wc -l < "$HOME/state.calls")" -eq 1 ]
  [ ! -e "$HOME/pause.calls" ]
  assert_previews_removed
}

@test "vpn menu recovery: untargeted action status 143 exits and cleans private previews" {
  export MENU_ACTION_RC=143 MENU_ACTION=vpn-off-all MENU_TARGET=""
  run run_recovery_menu
  [ "$status" -eq 143 ]
  [ "$(wc -l < "$HOME/dispatch.calls")" -eq 1 ]
  [ "$(wc -l < "$HOME/fzf.calls")" -eq 1 ]
  [ "$(wc -l < "$HOME/state.calls")" -eq 1 ]
  [ ! -e "$HOME/pause.calls" ]
  assert_previews_removed
}

@test "vpn menu recovery: an ordinary action failure pauses and refreshes the menu" {
  export MENU_ACTION_RC=1
  run run_recovery_menu
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$HOME/dispatch.calls")" -eq 1 ]
  [ "$(wc -l < "$HOME/fzf.calls")" -eq 2 ]
  [ "$(wc -l < "$HOME/state.calls")" -eq 2 ]
  [ "$(wc -l < "$HOME/pause.calls")" -eq 1 ]
  assert_previews_removed
}

@test "vpn menu recovery: picker status 130 remains a clean cancellation" {
  export MENU_PICKER_CANCEL=1
  run run_recovery_menu
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$HOME/fzf.calls")" -eq 1 ]
  [ ! -e "$HOME/dispatch.calls" ]
  [ ! -e "$HOME/pause.calls" ]
  assert_previews_removed
}

run_preview_in_posix_shell() {
  run_zsh '
    _vpn_state_load() { return 0; }
    _vpn_menu_rows() { print -r -- "Fixture|vpn-summary|Fixture details.|"; }
    _vpn_menu_context() { print -r -- "Fixture context"; }
    _vpn_menu_capabilities() { print -r -- "Fixture capabilities"; }
    _vpn_preview_render() { print -r -- "Exact fixture preview"; }
    _vpn_dispatch() { print -r -- unexpected > "$HOME/dispatch.calls"; return 99; }
    fzf() {
      command cat >/dev/null
      local argument preview=""
      for argument in "$@"; do
        [[ "$argument" == --preview=* ]] && preview="${argument#--preview=}"
      done
      [[ -n "$preview" ]] || return 97
      print -rn -- "$_VPN_PREVIEW_DIR" > "$HOME/preview.path"
      # Emulate only the integer placeholder; execute the actual supplied
      # preview in /bin/sh while the real private pane still exists.
      preview="${preview//\{n\}/0}"
      (
        builtin cd -- "$HOME" || exit 96
        command /bin/sh -c "$preview" > "$HOME/preview.actual"
      ) || return 98
      return 130
    }
    vpn-menu > "$HOME/menu.stdout" || return $?
    local pane_dir="$(<"$HOME/preview.path")"
    [[ -n "$pane_dir" && ! -e "$pane_dir" ]] || return 95
    [[ -z "$_VPN_PREVIEW_DIR" && -z "$_VPN_PREVIEW_DIR_IDENTITY" ]] || return 94
  '
}

assert_posix_preview() {
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/preview.actual")" = 'Exact fixture preview' ]
  [ ! -s "$HOME/menu.stdout" ]
  [ ! -e "$HOME/dispatch.calls" ]
  [ ! -e "$HOME/injected" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn menu recovery: POSIX preview reads private panes below a tab and newline path" {
  export TMPDIR="$HOME/"$'preview\twith\ncontrols'
  mkdir -m 700 -- "$TMPDIR"

  run run_preview_in_posix_shell

  assert_posix_preview
}

@test "vpn menu recovery: POSIX preview keeps quotes and shell text in its path literal" {
  export TMPDIR="$HOME/preview quote' "'$(touch injected) `touch injected` [x] café'
  mkdir -m 700 -- "$TMPDIR"

  run run_preview_in_posix_shell

  assert_posix_preview
}
