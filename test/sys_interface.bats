#!/usr/bin/env bats

setup() {
  load test_helper
  SYS_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/sys-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

@test "sys interface: help uses stderr and does not probe host capabilities" {
  run run_zsh '
    _sys_capabilities_refresh() {
      print -r -- "unexpected capability probe" >"$HOME/capability-probe"
      return 99
    }

    sys-menu --help >"$HOME/help.stdout" 2>"$HOME/help.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/help.stdout" ]
  [ ! -e "$HOME/capability-probe" ]
  grep -q "Usage:" "$HOME/help.stderr"
  grep -q "sys-menu" "$HOME/help.stderr"
}

@test "sys interface: dispatched help bypasses operational prerequisites" {
  run run_zsh '
    _sys_capabilities_refresh() {
      print -r -- "unexpected capability probe" >>"$HOME/help.probes"
      return 99
    }

    sys-menu update-brew --help \
      >"$HOME/subcommand-help.stdout" 2>"$HOME/subcommand-help.stderr"
    local help_rc=$?
    sys-menu update-brew --help extra \
      >"$HOME/invalid-help.stdout" 2>"$HOME/invalid-help.stderr"
    local invalid_rc=$?

    print -r -- "$help_rc:$invalid_rc"
    [[ "$help_rc" -eq 0 && "$invalid_rc" -eq 2 ]]
  '

  [ "$status" -eq 0 ]
  [ "$output" = "0:2" ]
  [ ! -e "$HOME/help.probes" ]
  [ ! -s "$HOME/subcommand-help.stdout" ]
  [ ! -s "$HOME/invalid-help.stdout" ]
  grep -q "Usage: update-brew" "$HOME/subcommand-help.stderr"
  grep -q "Unknown or extra argument" "$HOME/invalid-help.stderr"
}

@test "sys interface: nested invalid arguments reach the public parser before probes" {
  run run_zsh '
    _sys_capabilities_refresh() {
      print -r -- "unexpected capability probe" >>"$HOME/parser.probes"
      return 92
    }
    command() {
      if [[ "$1" == "-v" && "${2:-}" == "fzf" ]]; then
        return 1
      fi
      builtin command "$@"
    }

    command -v fzf &>/dev/null && return 90

    update-fzf --definitely-invalid \
      >"$HOME/direct.stdout" 2>"$HOME/direct.stderr"
    local direct_rc=$?
    sys-menu update-fzf --definitely-invalid \
      >"$HOME/nested.stdout" 2>"$HOME/nested.stderr"
    local nested_rc=$?

    print -r -- "$direct_rc:$nested_rc"
    [[ "$direct_rc" -eq 2 && "$nested_rc" -eq "$direct_rc" ]]
  '

  [ "$status" -eq 0 ]
  [ "$output" = "2:2" ]
  [ ! -e "$HOME/parser.probes" ]
  [ ! -s "$HOME/direct.stdout" ]
  [ ! -s "$HOME/nested.stdout" ]
  grep -q "Unknown option for update-fzf" "$HOME/direct.stderr"
  grep -q "Unknown option for update-fzf" "$HOME/nested.stderr"
}

@test "sys interface: font list help documents the exact TSV schema" {
  run run_zsh '
    sys-menu sys-fonts --help \
      >"$HOME/font-help.stdout" 2>"$HOME/font-help.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/font-help.stdout" ]
  grep -Fq "family<TAB>absolute-path" "$HOME/font-help.stderr"
}

@test "sys interface: unknown option and command return 2 without capability probes" {
  run run_zsh '
    _sys_capabilities_refresh() {
      print -r -- "unexpected capability probe" >>"$HOME/capability-probes"
      return 99
    }

    sys-menu --not-a-system-option \
      >"$HOME/option.stdout" 2>"$HOME/option.stderr"
    local option_rc=$?

    sys-menu not-a-system-command \
      >"$HOME/command.stdout" 2>"$HOME/command.stderr"
    local command_rc=$?

    print -r -- "$option_rc:$command_rc"
    [[ "$option_rc" -eq 2 && "$command_rc" -eq 2 ]]
  '

  [ "$status" -eq 0 ]
  [ "$output" = "2:2" ]
  [ ! -e "$HOME/capability-probes" ]
  [ ! -s "$HOME/option.stdout" ]
  [ ! -s "$HOME/command.stdout" ]
  grep -q "Unknown option" "$HOME/option.stderr"
  grep -q "Unknown command" "$HOME/command.stderr"
}

@test "sys interface: direct routing forwards exact arguments and times once" {
  run run_zsh '
    _sys_capabilities_refresh() { return 0; }
    _sys_timed() {
      local label="$1"
      shift
      print -r -- "$label" >>"$HOME/timing-labels"
      "$@"
    }
    _sys_dispatch() {
      print -r -- "$#" >"$HOME/dispatched-arguments"
      local argument
      for argument in "$@"; do
        print -r -- "$argument" >>"$HOME/dispatched-arguments"
      done
      return 7
    }

    sys-menu sys-info "value with spaces" --leading-dash
  '

  [ "$status" -eq 7 ]
  [ "$(cat "$HOME/timing-labels")" = "sys:sys-info" ]
  [ "$(cat "$HOME/dispatched-arguments")" = $'3\nsys-info\nvalue with spaces\n--leading-dash' ]
}

@test "sys interface: valid row helpers emit canonical three-field records" {
  run run_zsh '
    _sys_menu_missing_requirements() { return 0; }

    _sys_menu_section "Inspection" "Read-only host information."
    _sys_menu_entry \
      "Show System Info" \
      "sys-info" \
      "Display portable host diagnostics."
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'── Inspection ──|:|Read-only host information.\n  Show System Info|sys-info|Display portable host diagnostics.' ]
}

@test "sys interface: row helpers reject missing and unsafe fields with status 2" {
  run run_zsh '
    _sys_menu_missing_requirements() { return 0; }
    local -i failures=0

    _sys_menu_section \
      >"$HOME/row.stdout" 2>"$HOME/row.stderr"
    [[ $? -eq 2 ]] || (( failures++ ))

    _sys_menu_section "Bad|section" "Description" \
      >>"$HOME/row.stdout" 2>>"$HOME/row.stderr"
    [[ $? -eq 2 ]] || (( failures++ ))

    _sys_menu_entry "Label" "sys-info" $'\''Bad\ndescription'\'' \
      >>"$HOME/row.stdout" 2>>"$HOME/row.stderr"
    [[ $? -eq 2 ]] || (( failures++ ))

    _sys_menu_entry "Label" "sys-info" $'\''Bad\rdescription'\'' \
      >>"$HOME/row.stdout" 2>>"$HOME/row.stderr"
    [[ $? -eq 2 ]] || (( failures++ ))

    _sys_menu_entry $'\''Bad\0label'\'' "sys-info" "Description" \
      >>"$HOME/row.stdout" 2>>"$HOME/row.stderr"
    [[ $? -eq 2 ]] || (( failures++ ))

    _sys_menu_entry "" "sys-info" "Description" \
      >>"$HOME/row.stdout" 2>>"$HOME/row.stderr"
    [[ $? -eq 2 ]] || (( failures++ ))

    (( failures == 0 ))
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/row.stdout" ]
  grep -q "menu" "$HOME/row.stderr"
}

@test "sys interface: menu fzf contract is plain accurate and responsive" {
  run run_zsh '
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os linux environment native architecture x86_64
        package_manager unavailable service_manager unavailable
        process_backend unavailable ports_backend unavailable
        privilege unavailable fonts_backend unavailable
        snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_menu_missing_requirements() { return 0; }
    fzf() {
      local argument
      for argument in "$@"; do
        print -r -- "$argument" >>"$HOME/fzf.arguments"
        if [[ "$argument" == --header=* ]]; then
          print -r -- "${argument#--header=}" >"$HOME/fzf.header"
        fi
      done
      command cat >"$HOME/fzf.input"
      return 130
    }

    sys-menu >"$HOME/menu.stdout" 2>"$HOME/menu.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/menu.stdout" ]

  grep -Fxq -- "--height=80%" "$HOME/fzf.arguments"
  grep -Fxq -- "--layout=reverse" "$HOME/fzf.arguments"
  grep -Fxq -- "--border=rounded" "$HOME/fzf.arguments"
  grep -Fxq -- "--delimiter=[|]" "$HOME/fzf.arguments"
  grep -Fxq -- "--with-nth=1" "$HOME/fzf.arguments"
  grep -q "^--preview=" "$HOME/fzf.arguments"
  grep -Fxq -- "--preview-window=down:4:wrap" "$HOME/fzf.arguments"
  grep -Fxq -- "--prompt=sys > " "$HOME/fzf.arguments"

  local header
  header=$(cat "$HOME/fzf.header")
  [ "$header" = $'OS: linux | Environment: native | Packages: unavailable | Services: unavailable\nType to filter | Enter run | Esc cancel | Ctrl-/ details' ]

  awk -F "|" "NF != 3 { exit 1 }" "$HOME/fzf.input"
  if grep -q $'\033' "$HOME/fzf.input"; then
    return 1
  fi
}

@test "sys interface: NO_COLOR suppresses helper ANSI and forces monochrome fzf" {
  run run_zsh '
    export NO_COLOR=1
    export TERM=xterm-256color

    fzf() {
      local argument
      for argument in "$@"; do
        print -r -- "$argument" >>"$HOME/no-color-fzf.arguments"
      done
      command cat >/dev/null
      return 130
    }

    print -r -- "Label|command|Description" |
      _sys_fzf --prompt="sys > " >"$HOME/no-color-fzf.stdout"
    local fzf_rc=$?
    [[ "$fzf_rc" -eq 130 ]] || return 1

    _sys_no_color_helper_probe() {
      print -u2 -r -- "TTY_PROBE:$([[ -t 2 ]] && print yes || print no)"
      _sys_header "Header"
      _sys_success "Success"
      _sys_warn "Warning"
      _sys_info "Info"
      _sys_error "Error"
      _sys_dim "Dim"
      _sys_label "Label:" "Value"
    }

    zmodload zsh/zpty || return 1
    zpty no_color_helpers _sys_no_color_helper_probe || return 1

    local chunk=""
    while zpty -r no_color_helpers chunk 2>/dev/null; do
      print -rn -- "$chunk" >>"$HOME/no-color-helper.stderr"
    done
    zpty -d no_color_helpers 2>/dev/null || true
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/no-color-fzf.stdout" ]
  grep -Fxq -- "--height=80%" "$HOME/no-color-fzf.arguments"
  [ "$(tail -n 1 "$HOME/no-color-fzf.arguments")" = --no-color ]

  grep -Fq "TTY_PROBE:yes" "$HOME/no-color-helper.stderr"
  grep -Fq "✔ Success" "$HOME/no-color-helper.stderr"
  if LC_ALL=C grep -q $'\033' "$HOME/no-color-helper.stderr"; then
    return 1
  fi
}

@test "sys interface: programmable fzf selection dispatches one real action once" {
  export MOCK_FZF_MODE=match
  export MOCK_FZF_MATCH="|sys-info|"

  run run_zsh '
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os linux environment native architecture x86_64
        package_manager unavailable service_manager unavailable
        process_backend unavailable ports_backend unavailable
        privilege unavailable fonts_backend unavailable
        snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_menu_missing_requirements() { return 0; }
    _sys_timed() {
      local label="$1"
      shift
      print -r -- "$label" >>"$HOME/timing-labels"
      "$@"
    }
    _sys_dispatch() {
      print -r -- "$@" >>"$HOME/dispatched-actions"
      return 7
    }

    sys-menu >"$HOME/menu.stdout" 2>"$HOME/menu.stderr"
  '

  [ "$status" -eq 7 ]
  [ "$(cat "$HOME/dispatched-actions")" = "sys-info" ]
  [ "$(wc -l < "$HOME/dispatched-actions")" -eq 1 ]
  [ "$(cat "$HOME/timing-labels")" = "sys:sys-info" ]
  grep -q "|sys-info|" "$MOCK_FZF_INPUT_FILE"
}

@test "sys interface: standalone sourcing is silent idempotent and probe-free" {
  local stdout_file="$TEST_TEMP_DIR/source.stdout"
  local stderr_file="$TEST_TEMP_DIR/source.stderr"
  local probe_file="$TEST_TEMP_DIR/source.probes"

  run env \
    HOME="$HOME" \
    PATH="$PATH" \
    zsh -f -c '
      typeset probe_log="$3"
      fzf() { print -r -- "fzf" >>"$probe_log"; return 99; }
      sudo() { print -r -- "sudo" >>"$probe_log"; return 99; }
      curl() { print -r -- "curl" >>"$probe_log"; return 99; }
      git() { print -r -- "git" >>"$probe_log"; return 99; }
      uname() { print -r -- "uname" >>"$probe_log"; return 99; }
      systemctl() { print -r -- "systemctl" >>"$probe_log"; return 99; }
      snap() { print -r -- "snap" >>"$probe_log"; return 99; }

      {
        source "$1/functions/sys-menu.zsh" || return 1
        source "$1/functions/sys-menu.zsh" || return 2
      } >"$4" 2>"$5"

      [[ "${_SYS_CAPABILITIES_READY:-1}" -eq 0 ]] || return 3
      [[ -z "$(command find "$2" -mindepth 1 -print -quit)" ]] || return 4
    ' zsh \
    "$TEST_SUITE_ROOT" \
    "$HOME" \
    "$probe_file" \
    "$stdout_file" \
    "$stderr_file"

  [ "$status" -eq 0 ]
  [ ! -e "$probe_file" ]
  [ ! -s "$stdout_file" ]
  [ ! -s "$stderr_file" ]
}

@test "sys interface: lazy and eager loading expose the same System surface" {
  run env \
    -u TEST_TEMP_DIR \
    -u BATS_TEST_DIRNAME \
    -u ZDX_EAGER_LOAD \
    HOME="$HOME" \
    PATH="$PATH" \
    ZSH_CUSTOM="$TEST_SUITE_ROOT" \
    ZDX_LAZY_LOAD=1 \
    zsh -f -c '
      source "$1/functions.zsh" || return 1
      typeset -f sys-menu &>/dev/null || return 2
      typeset -f _sys_dispatch &>/dev/null && return 3

      sys-menu --help >/dev/null 2>/dev/null || return 4
      typeset -f _sys_dispatch &>/dev/null || return 5

      local command_name module_name risk capability
      while IFS=$'\''\t'\'' read -r \
        command_name module_name risk capability; do
        [[ -z "$command_name" || "$command_name" == \#* ]] && continue
        typeset -f "$command_name" &>/dev/null || return 6
        print -r -- "$command_name"
      done < "$2"
    ' zsh "$TEST_SUITE_ROOT" "$SYS_CONTRACT"

  [ "$status" -eq 0 ]
  local lazy_surface="$output"

  run env \
    -u TEST_TEMP_DIR \
    -u BATS_TEST_DIRNAME \
    -u ZDX_LAZY_LOAD \
    HOME="$HOME" \
    PATH="$PATH" \
    ZSH_CUSTOM="$TEST_SUITE_ROOT" \
    ZDX_EAGER_LOAD=1 \
    zsh -f -c '
      source "$1/functions.zsh" || return 1
      typeset -f _sys_dispatch &>/dev/null || return 2

      local command_name module_name risk capability
      while IFS=$'\''\t'\'' read -r \
        command_name module_name risk capability; do
        [[ -z "$command_name" || "$command_name" == \#* ]] && continue
        typeset -f "$command_name" &>/dev/null || return 3
        print -r -- "$command_name"
      done < "$2"
    ' zsh "$TEST_SUITE_ROOT" "$SYS_CONTRACT"

  [ "$status" -eq 0 ]
  [ "$output" = "$lazy_surface" ]
  [ "$(printf "%s\n" "$output" | wc -l)" -eq 34 ]
}

@test "sys interface: nested pickers run in the foreground with private capture" {
  mkdir -p "$HOME/.config/zdx"
  mkdir -m 700 "$HOME/.dotfiles-backups"
  printf '%s\n' \
    '{"suite":"sys","command":"safe","duration_ms":5,"exit_code":0,"timestamp":"2026-07-11T12:00:00Z"}' \
    > "$HOME/.config/zdx/telemetry.json"
  : > "$HOME/.dotfiles-backups/dotfiles_20260101_000000.tar.gz"

  run run_zsh '
    local picker_root="$HOME/sys-nested-picker"
    local subshell_log="$HOME/picker-subshells"
    command mkdir -m 700 -- "$picker_root"
    local current_picker=""
    fzf() {
      command cat >/dev/null
      print -r -- "$current_picker $ZSH_SUBSHELL" >>"$subshell_log"
      return 130
    }
    _sys_processes_records() {
      print -r -- $'\''process\t4242\t1000\t0.0\t0.0\tdemo'\''
    }
    _sys_ports_records() {
      print -r -- $'\''port\ttcp\t3000\t127.0.0.1\t4242\tdemo'\''
    }
    _sys_services_backend() { print -r -- "systemd"; }
    _sys_services_records() {
      print -r -- $'\''service\tsystemd\tdemo.service\tactive\trunning\tDemo'\''
    }
    _sys_fonts_render_installed() { return 0; }

    local -a pickers=(
      "sys-aliases"
      "sys-telemetry --browse"
      "sys-telemetry"
      "sys-processes"
      "sys-ports"
      "sys-services"
      "sys-fonts"
      "sys-restore-dots"
    )
    local picker picker_rc
    for picker in "${pickers[@]}"; do
      current_picker="$picker"
      REPLY="keep"
      TMPDIR="$picker_root" ${=picker} \
        >"$HOME/picker.stdout" 2>>"$HOME/picker.stderr"
      picker_rc=$?
      (( picker_rc == 0 )) || {
        print -u2 -r -- "$picker returned $picker_rc"
        return 1
      }
      [[ ! -s "$HOME/picker.stdout" ]] || {
        print -u2 -r -- "$picker wrote stdout"
        return 1
      }
      [[ "$REPLY" == "keep" ]] || {
        print -u2 -r -- "$picker leaked REPLY into the shell"
        return 1
      }
    done

    local -a subshell_levels=("${(@f)$(<"$subshell_log")}")
    (( ${#subshell_levels[@]} == ${#pickers[@]} )) || {
      print -u2 -r -- "expected ${#pickers[@]} pickers, saw ${#subshell_levels[@]}"
      return 1
    }
    local level
    for level in "${subshell_levels[@]}"; do
      [[ "$level" == *" 0" ]] || {
        print -u2 -r -- "a picker ran fzf in a subshell: $level"
        return 1
      }
    done
    [[ -z "$(command find "$picker_root" -mindepth 1 -print -quit)" ]] || {
      print -u2 -r -- "picker result files were left behind"
      return 1
    }
  '

  [ "$status" -eq 0 ]
}

@test "sys interface: nested pickers reject a row outside their snapshot" {
  mkdir -p "$HOME/.config/zdx"
  mkdir -m 700 "$HOME/.dotfiles-backups"
  printf '%s\n' \
    '{"suite":"sys","command":"safe","duration_ms":5,"exit_code":0,"timestamp":"2026-07-11T12:00:00Z"}' \
    > "$HOME/.config/zdx/telemetry.json"
  : > "$HOME/.dotfiles-backups/dotfiles_20260101_000000.tar.gz"

  run run_zsh '
    fzf() {
      command cat >/dev/null
      print -r -- "forged|forged|forged"
    }
    _sys_processes_records() {
      print -r -- $'\''process\t4242\t1000\t0.0\t0.0\tdemo'\''
    }
    _sys_ports_records() {
      print -r -- $'\''port\ttcp\t3000\t127.0.0.1\t4242\tdemo'\''
    }
    _sys_services_backend() { print -r -- "systemd"; }
    _sys_services_records() {
      print -r -- $'\''service\tsystemd\tdemo.service\tactive\trunning\tDemo'\''
    }
    _sys_fonts_render_installed() { return 0; }
    _sys_processes_terminate() { print -r -- "mutation" >>"$HOME/forged.log"; }
    _sys_ports_terminate_record() { print -r -- "mutation" >>"$HOME/forged.log"; }
    _sys_services_mutate() { print -r -- "mutation" >>"$HOME/forged.log"; }

    local -a pickers=(
      "sys-aliases"
      "sys-telemetry --browse"
      "sys-telemetry"
      "sys-processes"
      "sys-ports"
      "sys-services"
      "sys-fonts"
      "sys-restore-dots"
    )
    local picker picker_rc
    for picker in "${pickers[@]}"; do
      : >"$HOME/forged.stderr"
      ${=picker} >"$HOME/forged.stdout" 2>"$HOME/forged.stderr"
      picker_rc=$?
      (( picker_rc == 1 )) || {
        print -u2 -r -- "$picker returned $picker_rc for a forged row"
        return 1
      }
      command grep -q "snapshot" "$HOME/forged.stderr" || {
        print -u2 -r -- "$picker accepted a forged row silently"
        return 1
      }
      [[ ! -s "$HOME/forged.stdout" ]] || {
        print -u2 -r -- "$picker wrote stdout for a forged row"
        return 1
      }
    done
    [[ ! -e "$HOME/forged.log" ]]
  '

  [ "$status" -eq 0 ]
}

@test "sys interface: resource browser keys route through the private capture" {
  run run_zsh '
    _sys_processes_records() {
      print -r -- $'\''process\t4242\t1000\t0.0\t0.0\tdemo'\''
    }
    _sys_processes_fingerprint() {
      print -r -- $'\''process\t4242\t1000\tMon Jan  1 00:00:00 2026\tdemo'\''
    }
    _sys_processes_terminate() {
      print -r -- "terminate:$1:$2:$3" >>"$HOME/route.log"
    }
    fzf() {
      local first_row=""
      IFS= read -r first_row
      command cat >/dev/null
      print -r -- "${MOCK_EXPECT_KEY:-}"
      print -r -- "$first_row"
    }

    MOCK_EXPECT_KEY="" sys-processes \
      >"$HOME/enter.stdout" 2>"$HOME/enter.stderr" || return 1
    MOCK_EXPECT_KEY="ctrl-t" sys-processes \
      >"$HOME/term.stdout" 2>"$HOME/term.stderr" || return 2
    MOCK_EXPECT_KEY="ctrl-k" sys-processes \
      >"$HOME/kill.stdout" 2>"$HOME/kill.stderr" || return 3
    [[ ! -s "$HOME/enter.stdout" && ! -s "$HOME/term.stdout" \
      && ! -s "$HOME/kill.stdout" ]] || return 4
  '

  [ "$status" -eq 0 ]
  grep -q "Process Details" "$HOME/enter.stderr"
  grep -q "4242" "$HOME/enter.stderr"
  [ "$(cat "$HOME/route.log")" = $'terminate:4242:0:0\nterminate:4242:1:0' ]
}
