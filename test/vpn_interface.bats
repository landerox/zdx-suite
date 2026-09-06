#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

# --- Source safety ----------------------------------------------------------

@test "vpn interface: sourcing twice is silent and defines the entrypoint" {
  local stdout_file="$TEST_TEMP_DIR/stdout"
  local stderr_file="$TEST_TEMP_DIR/stderr"

  run zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    source '$TEST_SUITE_ROOT/functions/vpn-menu.zsh'
    source '$TEST_SUITE_ROOT/functions/vpn-menu.zsh'
    typeset -f vpn-menu >/dev/null || exit 1
  " >"$stdout_file" 2>"$stderr_file"

  [ "$status" -eq 0 ]
  [ ! -s "$stdout_file" ]
  [ ! -s "$stderr_file" ]
}

@test "vpn interface: standalone sourcing works without the core runtime" {
  run zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    source '$TEST_SUITE_ROOT/functions/vpn-menu.zsh' || exit 1

    typeset -f _timed >/dev/null && exit 1
    _vpn_timed 'vpn:probe' true || exit 1
    typeset -f _vpn_fzf >/dev/null || exit 1
    print -r -- OK
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "vpn interface: sourcing opens no fzf, prompts nothing, requests no sudo" {
  run zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    fzf() { print -u2 -r -- 'FZF OPENED'; return 1; }
    sudo() { print -u2 -r -- 'SUDO CALLED'; return 1; }
    source '$TEST_SUITE_ROOT/functions/vpn-menu.zsh'
    print -r -- DONE
  " < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" != *"FZF OPENED"* ]]
  [[ "$output" != *"SUDO CALLED"* ]]
  [[ "$output" == *"DONE"* ]]
}

@test "vpn interface: a failed mandatory module leaves no loaded sentinel" {
  local broken_root="$TEST_TEMP_DIR/broken"
  mkdir -p "$broken_root/vpn"
  cp "$TEST_SUITE_ROOT/functions/vpn-menu.zsh" "$broken_root/"
  cp "$TEST_SUITE_ROOT/functions/vpn-common.zsh" "$broken_root/"
  local module
  for module in "$TEST_SUITE_ROOT"/functions/vpn/*.zsh; do
    cp "$module" "$broken_root/vpn/"
  done
  printf 'if true; then\n' > "$broken_root/vpn/vpn-control.zsh"

  run zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    source '$broken_root/vpn-menu.zsh'
    local rc=\$?
    [[ -n \"\${_VPN_MENU_SOURCED:-}\" ]] && exit 1
    exit \$(( rc == 0 ? 1 : 0 ))
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"failed to load vpn-control.zsh"* ]]
}

@test "vpn interface: the loader resolves modules below one derived root" {
  # A second hard-coded installation root would let an unrelated tree win.
  ! grep -q 'oh-my-zsh' "$TEST_SUITE_ROOT/functions/vpn-menu.zsh"
  grep -q '${${(%):-%x}:A:h}' "$TEST_SUITE_ROOT/functions/vpn-menu.zsh"
}

# --- Stream contract --------------------------------------------------------

@test "vpn interface: help goes to stderr, never stdout" {
  local stdout_file="$TEST_TEMP_DIR/help.out"
  local stderr_file="$TEST_TEMP_DIR/help.err"

  run run_zsh "vpn-menu --help >'$stdout_file' 2>'$stderr_file'"

  [ "$status" -eq 0 ]
  [ ! -s "$stdout_file" ]
  grep -q 'Usage:' "$stderr_file"
}

@test "vpn interface: logging helpers write only to stderr" {
  local stdout_file="$TEST_TEMP_DIR/log.out"
  local stderr_file="$TEST_TEMP_DIR/log.err"

  run run_zsh "
    {
      _vpn_header 'Header'
      _vpn_success 'Success'
      _vpn_warn 'Warn'
      _vpn_info 'Info'
      _vpn_error 'Error'
      _vpn_dim 'Dim'
      _vpn_label 'Key' 'Value'
      _vpn_blank
    } >'$stdout_file' 2>'$stderr_file'
  "

  [ "$status" -eq 0 ]
  [ ! -s "$stdout_file" ]
  grep -q 'Header' "$stderr_file"
  grep -q 'Value' "$stderr_file"
}

@test "vpn interface: labels display backslash escapes instead of interpreting" {
  local stderr_file="$TEST_TEMP_DIR/label.err"

  run run_zsh "_vpn_label 'Endpoint' 'a\\tb\\nc' 2>'$stderr_file'"

  [ "$status" -eq 0 ]
  # The literal two-character sequences must survive; no real tab or newline.
  grep -q 'a\\tb\\nc' "$stderr_file"
  [ "$(wc -l < "$stderr_file")" -eq 1 ]
}

@test "vpn interface: NO_COLOR suppresses ANSI without changing status" {
  local stderr_file="$TEST_TEMP_DIR/nocolor.err"

  run run_zsh "
    export NO_COLOR=1
    _vpn_info 'plain message' 2>'$stderr_file'
  "

  [ "$status" -eq 0 ]
  grep -q 'plain message' "$stderr_file"
  ! grep -q $'\033' "$stderr_file"
}

@test "vpn interface: menu row builders write records only to stdout" {
  local stdout_file="$TEST_TEMP_DIR/rows.out"
  local stderr_file="$TEST_TEMP_DIR/rows.err"

  run run_zsh "
    _vpn_state_load
    _vpn_menu_rows >'$stdout_file' 2>'$stderr_file'
  "

  [ "$status" -eq 0 ]
  [ ! -s "$stderr_file" ]
  grep -q '|vpn-summary|' "$stdout_file"
}

@test "vpn interface: no public command prints UI spacing to stdout" {
  ! grep -rn 'echo ""' \
    "$TEST_SUITE_ROOT/functions/vpn-menu.zsh" \
    "$TEST_SUITE_ROOT/functions/vpn-common.zsh" \
    "$TEST_SUITE_ROOT"/functions/vpn/*.zsh
}

# --- Menu record validation -------------------------------------------------

@test "vpn interface: menu rows carry four fields and no raw escapes" {
  run run_zsh "_vpn_state_load; _vpn_menu_rows"
  [ "$status" -eq 0 ]

  local line field_count
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    field_count=$(awk -F '|' '{ print NF }' <<< "$line")
    if [[ "$field_count" -ne 4 ]]; then
      echo "Row does not have four fields: $line" >&2
      return 1
    fi
    if [[ "$line" == *$'\033'* ]]; then
      echo "Row contains a raw escape sequence: $line" >&2
      return 1
    fi
  done <<< "$output"
}

@test "vpn interface: row helpers reject delimiters and invalid targets" {
  run run_zsh "_vpn_menu_entry 'Bad|Label' 'vpn-summary' 'Description.'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"delimiters and control characters"* ]]

  run run_zsh "_vpn_menu_section 'Bad|Title'"
  [ "$status" -eq 2 ]

  run run_zsh "_vpn_menu_entry 'Label' 'vpn-summary'"
  [ "$status" -eq 2 ]

  run run_zsh "_vpn_menu_entry 'Label' 'vpn-on' 'Connect.' '-dash'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid menu entry target"* ]]

  run run_zsh "_vpn_menu_entry 'Label' 'vpn-on' 'Connect.' 'wg0'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|vpn-on|Connect.|wg0"* ]]
}

@test "vpn interface: interface names must start with an alphanumeric" {
  run run_zsh '
    _vpn_validate_iface_name "wg0"        || return 1
    _vpn_validate_iface_name "office-vpn" || return 2
    _vpn_validate_iface_name "valid.name" || return 3
    _vpn_validate_iface_name "invalid/name" && return 4
    _vpn_validate_iface_name "invalid name" && return 5
    _vpn_validate_iface_name "-dash-lead"  && return 6
    _vpn_validate_iface_name ".dot-lead"   && return 7
    _vpn_validate_iface_name ""            && return 8
    return 0
  '
  [ "$status" -eq 0 ]
}

# --- fzf and preview contract -----------------------------------------------

@test "vpn interface: fzf receives a pipe delimiter and one visible field" {
  run run_zsh "
    fzf() {
      command cat >/dev/null
      printf '%s\n' \"\$@\" >&2
      return 130
    }
    vpn-menu 2>&1
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"--delimiter=[|]"* ]]
  [[ "$output" == *"--with-nth=1"* ]]
  [[ "$output" == *"--pointer=▶"* ]]
}

@test "vpn interface: the preview command references only the row index" {
  run run_zsh "
    fzf() {
      command cat >/dev/null
      printf '%s\n' \"\$@\" >&2
      return 130
    }
    vpn-menu 2>&1
  "

  [ "$status" -eq 0 ]
  # The pane is a precomputed file addressed by fzf's integer index.
  [[ "$output" == *"--preview=command cat -- "*"/{n}"* ]]
  # No record field may reach the preview program text.
  [[ "$output" != *'--preview='*'{2}'* ]]
  [[ "$output" != *'--preview='*'{3}'* ]]
  [[ "$output" != *'--preview='*'{4}'* ]]
}

@test "vpn interface: the preview program never contains sudo" {
  run run_zsh "
    fzf() {
      command cat >/dev/null
      printf '%s\n' \"\$@\" >&2
      return 130
    }
    vpn-menu 2>&1 | command grep -- '--preview='
  "

  [ "$status" -eq 0 ]
  [[ "$output" != *"sudo"* ]]
}

@test "vpn interface: precomputed panes are owner-only and indexed from zero" {
  run run_zsh '
    _vpn_state_load
    local rows
    rows=$(_vpn_menu_rows) || return 1
    local -a records=("${(@f)rows}")

    # The builder publishes its directory in _VPN_PREVIEW_DIR. Capturing it with
    # command substitution would run it in a subshell and lose that state.
    _vpn_preview_build "${records[@]}" || return 1
    local dir="$_VPN_PREVIEW_DIR"
    [[ -n "$dir" && -d "$dir" ]] || return 1
    [[ "$(command stat -c "%a" "$dir")" == "700" ]] || return 1
    [[ -f "$dir/0" ]] || return 1
    [[ -f "$dir/$(( ${#records[@]} - 1 ))" ]] || return 1
    command grep -q "^Command: " "$dir/1" || return 1

    _vpn_preview_dir_cleanup
    [[ ! -d "$dir" ]] || return 1
    print -r -- OK
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "vpn interface: the preview directory is removed when the menu exits" {
  # Asserting only that _VPN_PREVIEW_DIR is empty is vacuous: it stays empty
  # whenever the builder ran in a subshell. The path is recovered from the
  # recorded --preview argument and the directory itself is checked.
  run run_zsh '
    local args_file="$HOME/fzf.args"
    fzf() {
      command cat >/dev/null
      print -rl -- "$@" > "$args_file"
      return 130
    }

    vpn-menu >/dev/null 2>&1

    local preview_arg
    preview_arg=$(command grep -m1 -- "--preview=command cat -- " "$args_file") \
      || { print -u2 -r -- "no preview argument was recorded"; return 1 }

    local pane_dir="${${preview_arg##*--preview=command cat -- }%/\{n\}}"
    pane_dir="${(Q)pane_dir}"
    [[ -n "$pane_dir" ]] || { print -u2 -r -- "empty pane dir"; return 1 }

    if [[ -d "$pane_dir" ]]; then
      print -u2 -r -- "pane directory leaked: $pane_dir"
      return 1
    fi
    [[ -z "$_VPN_PREVIEW_DIR" ]] || return 1
    print -r -- "CLEAN $pane_dir"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEAN /"* ]]
  [[ "$output" == *"zdx-vpn-preview."* ]]
}

@test "vpn interface: the header shows context and only active bindings" {
  run run_zsh "
    fzf() {
      command cat >/dev/null
      printf '%s\n' \"\$@\" >&2
      return 130
    }
    vpn-menu 2>&1
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"Platform:"* ]]
  [[ "$output" == *"Type to filter | Enter run | Esc cancel"* ]]
  # Typing filters; Tab is not a search binding and multi-select is not enabled.
  [[ "$output" != *"Tab] Search"* ]]
  [[ "$output" != *"--multi"* ]]
}

@test "vpn interface: fzf remains in the terminal foreground process group" {
  export VPN_PTY_PGID_FILE="$TEST_TEMP_DIR/vpn-pty-pgid"
  export VPN_PTY_RC_FILE="$TEST_TEMP_DIR/vpn-pty-rc"
  export VPN_PTY_CHILD="$TEST_TEMP_DIR/vpn-pty-child.zsh"

  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
set -u

cat >/dev/null
current_pgid=$(ps -o pgid= -p "$$" | tr -d '[:space:]')
terminal_pgid=$(ps -o tpgid= -p "$$" | tr -d '[:space:]')
printf '%s|%s\n' "$current_pgid" "$terminal_pgid" > "$VPN_PTY_PGID_FILE"

[[ -n "$current_pgid" && "$current_pgid" == "$terminal_pgid" ]] || exit 97
exit 130
EOF
  chmod +x "$TEST_MOCK_BIN/fzf"

  cat > "$VPN_PTY_CHILD" <<'EOF'
setopt MONITOR
source "$ZSH_CUSTOM/functions/vpn-menu.zsh" || exit 91
vpn-menu
menu_rc=$?
print -r -- "$menu_rc" > "$VPN_PTY_RC_FILE"
exit "$menu_rc"
EOF
  chmod +x "$VPN_PTY_CHILD"

  run run_zsh '
    _vpn_pty_foreground_check() {
      zmodload zsh/zpty || return 80
      zpty -b vpn-foreground zsh -dfi "$VPN_PTY_CHILD" || return 81
      {
        local -i attempt=0
        local chunk=""
        while [[ ! -s "$VPN_PTY_RC_FILE" ]] && (( ++attempt <= 200 )); do
          zpty -r -t vpn-foreground chunk 2>/dev/null || true
          command sleep 0.01
        done

        [[ -s "$VPN_PTY_RC_FILE" ]] || {
          print -u2 -r -- "The PTY menu did not finish within the test bound."
          return 82
        }
        [[ -s "$VPN_PTY_PGID_FILE" ]] || return 83

        local process_groups
        process_groups=$(<"$VPN_PTY_PGID_FILE")
        local current_pgid="${process_groups%%|*}"
        local terminal_pgid="${process_groups##*|}"
        [[ -n "$current_pgid" && "$current_pgid" == "$terminal_pgid" ]] || {
          print -u2 -r -- \
            "fzf was not foreground: pgid=$current_pgid tpgid=$terminal_pgid"
          return 84
        }

        local menu_rc
        menu_rc=$(<"$VPN_PTY_RC_FILE")
        [[ "$menu_rc" == "0" ]] || return 85
        print -r -- "foreground:$current_pgid"
      } always {
        zpty -d vpn-foreground 2>/dev/null || true
      }
    }

    _vpn_pty_foreground_check
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"foreground:"* ]]
  [[ "$output" != *"suspended (tty output)"* ]]
}

# --- Selection and dispatch -------------------------------------------------

@test "vpn interface: selecting a section row dispatches nothing" {
  run run_zsh '
    local dispatch_log="$HOME/dispatch.log"
    local fzf_marker="$HOME/fzf.called"
    fzf() {
      command cat >/dev/null
      if [[ ! -e "$fzf_marker" ]]; then
        : > "$fzf_marker"
        print -r -- "── Diagnostics ──|:|Read-only inspection.|"
        return 0
      fi
      return 130
    }
    _vpn_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
      return 0
    }
    _vpn_menu_pause() { return 0; }

    # One iteration, then break out by making the second render cancel.
    _vpn_menu_rows() { print -r -- "── x ──|:|y|"; }
    vpn-menu >/dev/null 2>&1
    [[ ! -e "$dispatch_log" ]] || return 1
    return 0
  '

  [ "$status" -eq 0 ]
}

@test "vpn interface: selecting an action dispatches it with its target" {
  run run_zsh '
    local menu_log="$HOME/action-menu.log"
    local fzf_marker="$HOME/fzf.called"
    fzf() {
      command cat >/dev/null
      if [[ ! -e "$fzf_marker" ]]; then
        : > "$fzf_marker"
        print -r -- \
          "  wg0 (active)|vpn-off|Disconnect this active profile.|wg0"
        return 0
      fi
      return 130
    }
    _vpn_dispatch() {
      print -r -- "dispatched:$1:${2:-}"
      # The next fzf call cancels so the manager loop stops deterministically.
      return 0
    }
    _vpn_menu_pause() { return 0; }
    _vpn_state_load() { _VPN_MENU_CONFIG_ACCESS_STATE=direct; return 0; }
    _vpn_menu_rows() {
      print -r -- \
        "  wg0 (active)|vpn-off|Disconnect this active profile.|wg0"
    }

    vpn-menu >"$menu_log" 2>&1
    command cat -- "$menu_log"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched:vpn-off:wg0"* ]]
}

@test "vpn interface: an invalid selection target is refused before dispatch" {
  run run_zsh '
    local dispatch_log="$HOME/dispatch.log"
    local menu_log="$HOME/invalid-menu.log"
    local fzf_marker="$HOME/fzf.called"
    fzf() {
      command cat >/dev/null
      if [[ ! -e "$fzf_marker" ]]; then
        : > "$fzf_marker"
        print -r -- "  evil|vpn-off|Disconnect.|../../etc/passwd"
        return 0
      fi
      return 130
    }
    _vpn_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
      return 0
    }
    _vpn_menu_pause() { return 0; }
    _vpn_menu_rows() { print -r -- "── x ──|:|y|"; }

    vpn-menu >"$menu_log" 2>&1
    command cat -- "$menu_log"
    [[ ! -e "$dispatch_log" ]] || print -r -- "DISPATCHED"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Refusing an invalid selection target"* ]]
  [[ "$output" != *"DISPATCHED"* ]]
}

@test "vpn interface: --help reaches a command whose dependency is missing" {
  run run_zsh '
    _vpn_check_wg_quick() { _vpn_error "wg-quick missing"; return 1; }
    vpn-menu vpn-on --help
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: vpn-on"* ]]
  [[ "$output" != *"wg-quick missing"* ]]
}

@test "vpn interface: parsing precedes the command-owned dependency probe" {
  run run_zsh '
    local profile_dir="$HOME/wireguard"
    mkdir -p "$profile_dir"
    chmod 700 "$profile_dir"
    print -rl -- "[Interface]" "PrivateKey = x" "" \
      "[Peer]" "PublicKey = y" > "$profile_dir/wg0.conf"
    chmod 600 "$profile_dir/wg0.conf"
    VPN_CONFIG_DIR="$profile_dir"
    unset WSL_DISTRO_NAME
    _vpn_is_wsl() { return 1; }
    _vpn_check_wg_quick() { _vpn_error "wg-quick is not installed."; return 1; }

    local invalid_output
    invalid_output=$(vpn-menu vpn-on --definitely-invalid 2>&1)
    (( $? == 2 )) || return 10
    [[ "$invalid_output" != *"wg-quick is not installed"* ]] || return 11

    vpn-menu vpn-on wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"wg-quick is not installed."* ]]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "vpn interface: every public command rejects an unknown option" {
  local contract="$TEST_SUITE_ROOT/test/fixtures/vpn-public-commands.tsv"
  local command_list
  command_list=$(awk -F '\t' '!/^#/ && NF { print $1 }' "$contract" | tr '\n' ' ')

  run run_zsh "
    local command_name
    for command_name in $command_list; do
      \"\$command_name\" --definitely-not-a-flag >/dev/null 2>&1
      if (( \$? != 2 )); then
        print -u2 -r -- \"\$command_name did not return 2 for a bad option\"
        return 1
      fi
    done
  "

  [ "$status" -eq 0 ]
}

@test "vpn interface: every public command has a --help mode" {
  local contract="$TEST_SUITE_ROOT/test/fixtures/vpn-public-commands.tsv"
  local command_list
  command_list=$(awk -F '\t' '!/^#/ && NF { print $1 }' "$contract" | tr '\n' ' ')

  run run_zsh "
    local command_name help_text
    for command_name in $command_list; do
      help_text=\$(\"\$command_name\" --help 2>&1 >/dev/null) || {
        print -u2 -r -- \"\$command_name --help returned non-zero\"
        return 1
      }
      if [[ \"\$help_text\" != *\"Usage: \$command_name\"* ]]; then
        print -u2 -r -- \"\$command_name --help lacks its usage line\"
        return 1
      fi
    done
  "

  [ "$status" -eq 0 ]
}

@test "vpn interface: lazy and eager loading expose the same public surface" {
  local eager_file="$TEST_TEMP_DIR/eager.txt"
  local lazy_file="$TEST_TEMP_DIR/lazy.txt"

  run zsh -c "
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'
    export ZDX_EAGER_LOAD=1
    source \$ZSH_CUSTOM/functions.zsh
    source \$ZSH_CUSTOM/functions/vpn-menu.zsh
    print -rl -- \${(ok)functions[(I)vpn-*]} > '$eager_file'
  "
  [ "$status" -eq 0 ]

  run zsh -c "
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'
    source \$ZSH_CUSTOM/functions.zsh
    vpn-menu --help >/dev/null 2>&1
    print -rl -- \${(ok)functions[(I)vpn-*]} > '$lazy_file'
  "
  [ "$status" -eq 0 ]

  run diff -u "$eager_file" "$lazy_file"
  [ "$status" -eq 0 ]
}

@test "vpn interface: a second menu iteration does not print loop-local variables" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/vpn-menu.zsh" || return 98
    typeset -gi _test_fzf_calls=0
    _vpn_state_load() { return 0 }
    _vpn_menu_rows() {
      print -r -- "  Refresh State|vpn-refresh|Re-read state.|"
    }
    _vpn_preview_build() { return 1 }
    _vpn_preview_dir_init() {
      _VPN_PREVIEW_DIR="$HOME/.vpn-panes"
      command mkdir -p -- "$_VPN_PREVIEW_DIR"
      command chmod 700 -- "$_VPN_PREVIEW_DIR"
    }
    _vpn_preview_dir_cleanup() { return 0 }
    _vpn_state_validate_file() { return 0 }
    _vpn_menu_context() { print -r -- "ctx" }
    _vpn_menu_capabilities() { print -r -- "caps" }
    _vpn_dispatch() { print -u2 -r -- "dispatched:$1" }
    _vpn_fzf() {
      (( ++_test_fzf_calls ))
      if (( _test_fzf_calls == 1 )); then
        print -r -- "  Refresh State|vpn-refresh|Re-read state.|"
        return 0
      fi
      return 130
    }
    _vpn_interactive
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched:vpn-refresh"* ]]
  [[ "$output" != *"rows_output="* ]]
  [[ "$output" != *"header="* ]]
  [[ "$output" != *"selection_file="* ]]
  [[ "$output" != *"option_record="* ]]
}
