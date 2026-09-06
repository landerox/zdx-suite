#!/usr/bin/env bats

setup() {
  load test_helper
  GIT_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/git-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

@test "git interface: help uses stderr without repository or dependency probes" {
  run run_zsh '
    _git_require_repo() {
      print -r -- "unexpected repository probe" >>"$HOME/help.probes"
      return 99
    }
    _tk_require_git_repo() {
      print -r -- "unexpected repository probe" >>"$HOME/help.probes"
      return 99
    }
    _git_verify_deps() {
      print -r -- "unexpected dependency probe" >>"$HOME/help.probes"
      return 99
    }
    _tk_verify_deps() {
      print -r -- "unexpected dependency probe" >>"$HOME/help.probes"
      return 99
    }

    git-menu --help >"$HOME/help.stdout" 2>"$HOME/help.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/help.stdout" ]
  [ ! -e "$HOME/help.probes" ]
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]
  grep -Fq "Usage:" "$HOME/help.stderr"
  grep -Fq "git-menu" "$HOME/help.stderr"
}

@test "git interface: unknown option and command return 2 without probes" {
  run run_zsh '
    _git_require_repo() {
      print -r -- "unexpected repository probe" >>"$HOME/invalid.probes"
      return 99
    }
    _tk_require_git_repo() {
      print -r -- "unexpected repository probe" >>"$HOME/invalid.probes"
      return 99
    }
    _git_verify_deps() {
      print -r -- "unexpected dependency probe" >>"$HOME/invalid.probes"
      return 99
    }
    _tk_verify_deps() {
      print -r -- "unexpected dependency probe" >>"$HOME/invalid.probes"
      return 99
    }

    git-menu --not-a-git-option \
      >"$HOME/option.stdout" 2>"$HOME/option.stderr"
    local option_rc=$?

    git-menu not-a-git-command \
      >"$HOME/command.stdout" 2>"$HOME/command.stderr"
    local command_rc=$?

    print -r -- "$option_rc:$command_rc"
    [[ "$option_rc" -eq 2 && "$command_rc" -eq 2 ]]
  '

  [ "$status" -eq 0 ]
  [ "$output" = "2:2" ]
  [ ! -e "$HOME/invalid.probes" ]
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]
  [ ! -s "$HOME/option.stdout" ]
  [ ! -s "$HOME/command.stdout" ]
  grep -Fq "Unknown option" "$HOME/option.stderr"
  grep -Eq "Unknown( Git)? command" "$HOME/command.stderr"
}

@test "git interface: direct routing forwards exact arguments and times once" {
  run run_zsh '
    _git_test_timed() {
      local label="$1"
      shift
      print -r -- "$label" >>"$HOME/timing-labels"
      "$@"
    }
    _git_timed() { _git_test_timed "$@"; }
    _timed() { _git_test_timed "$@"; }
    _git_dispatch() {
      print -r -- "$#" >"$HOME/dispatched-arguments"
      local argument
      for argument in "$@"; do
        print -r -- "$argument" >>"$HOME/dispatched-arguments"
      done
      return 7
    }

    git-menu git-pr-checkout "123" "" --leading-dash
  '

  [ "$status" -eq 7 ]
  [ "$(cat "$HOME/timing-labels")" = "git:git-pr-checkout" ]
  [ "$(cat "$HOME/dispatched-arguments")" = \
    $'4\ngit-pr-checkout\n123\n\n--leading-dash' ]
}

@test "git interface: dispatched help stays isolated and uses stderr" {
  run run_zsh '
    fzf() {
      print -r -- "unexpected fzf" >>"$HOME/help.probes"
      return 99
    }
    _git_verify_deps() {
      print -r -- "unexpected dependency probe" >>"$HOME/help.probes"
      return 99
    }
    _tk_verify_deps() {
      print -r -- "unexpected dependency probe" >>"$HOME/help.probes"
      return 99
    }

    git-menu git-identity-switcher --help \
      >"$HOME/identity-help.stdout" 2>"$HOME/identity-help.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/help.probes" ]
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]
  [ ! -s "$HOME/identity-help.stdout" ]
  grep -Fq "Usage:" "$HOME/identity-help.stderr"
  grep -Fq "git-identity-switcher" "$HOME/identity-help.stderr"
}

@test "git interface: every direct command help uses stderr without probes" {
  local command_list
  command_list=$(
    awk -F '\t' '!/^#/ && NF { print $1 }' "$GIT_CONTRACT" \
      | sort \
      | tr '\n' ' '
  )

  run run_zsh "
    _git_require_repo() {
      print -r -- \"repository\" >>\"\$HOME/direct-help.probes\"
      return 99
    }
    _git_check_gh() {
      print -r -- \"github\" >>\"\$HOME/direct-help.probes\"
      return 99
    }
    _git_require_interactive() {
      print -r -- \"terminal\" >>\"\$HOME/direct-help.probes\"
      return 99
    }

    local command_name
    for command_name in $command_list; do
      : >\"\$HOME/direct-help.stdout\"
      : >\"\$HOME/direct-help.stderr\"
      \"\$command_name\" --help \
        >\"\$HOME/direct-help.stdout\" \
        2>\"\$HOME/direct-help.stderr\"
      local -i help_rc=\$?
      (( help_rc == 0 )) || {
        print -u2 -r -- \"\$command_name --help returned \$help_rc\"
        return 1
      }
      [[ ! -s \"\$HOME/direct-help.stdout\" ]] || {
        print -u2 -r -- \"\$command_name --help wrote stdout\"
        return 2
      }
      command grep -Fq \"Usage:\" \"\$HOME/direct-help.stderr\" || {
        print -u2 -r -- \"\$command_name --help omitted usage\"
        return 3
      }
    done

    [[ ! -e \"\$HOME/direct-help.probes\" ]]
  "

  if [ "$status" -ne 0 ]; then
    echo "$output" >&2
  fi
  [ "$status" -eq 0 ]
}

@test "git interface: invalid direct and nested options fail before probes" {
  local command_list
  command_list=$(
    awk -F '\t' '!/^#/ && NF { print $1 }' "$GIT_CONTRACT" \
      | sort \
      | tr '\n' ' '
  )

  run run_zsh "
    _git_invalid_probe() {
      print -r -- \"\$1\" >>\"\$HOME/invalid-command.probes\"
      return 99
    }
    _git_require_git() { _git_invalid_probe git; }
    _git_require_repo() { _git_invalid_probe repository; }
    _git_check_gh() { _git_invalid_probe github; }
    _git_require_interactive() { _git_invalid_probe terminal; }
    _git_verify_deps() { _git_invalid_probe dependency; }

    local command_name
    for command_name in $command_list; do
      \"\$command_name\" --zdx-invalid \
        >\"\$HOME/invalid-direct.stdout\" \
        2>\"\$HOME/invalid-direct.stderr\"
      (( \$? == 2 )) || {
        print -u2 -r -- \
          \"Direct invalid option was not status 2: \$command_name\"
        return 1
      }

      git-menu \"\$command_name\" --zdx-invalid \
        >\"\$HOME/invalid-nested.stdout\" \
        2>\"\$HOME/invalid-nested.stderr\"
      (( \$? == 2 )) || {
        print -u2 -r -- \
          \"Nested invalid option was not status 2: \$command_name\"
        return 2
      }
    done

    [[ ! -e \"\$HOME/invalid-command.probes\" ]]
  "

  if [ "$status" -ne 0 ]; then
    echo "$output" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/invalid-direct.stdout" ]
  [ ! -s "$HOME/invalid-nested.stdout" ]
}

@test "git interface: valid row helpers emit canonical three-field records" {
  run run_zsh '
    _git_menu_section \
      "Inspection" \
      "Read-only repository information."
    _git_menu_entry \
      "Show Git Status" \
      "git-status" \
      "Display branch, upstream, and working-tree state."
  '

  [ "$status" -eq 0 ]
  [ "$output" = \
    $'── Inspection ──|:|Read-only repository information.\n  Show Git Status|git-status|Display branch, upstream, and working-tree state.' ]
}

@test "git interface: row helpers reject missing and unsafe fields with status 2" {
  run run_zsh '
    local -i failures=0

    _git_menu_section \
      >"$HOME/row.stdout" 2>"$HOME/row.stderr"
    [[ $? -eq 2 ]] || (( failures++ ))

    _git_menu_section "Bad|section" "Description" \
      >>"$HOME/row.stdout" 2>>"$HOME/row.stderr"
    [[ $? -eq 2 ]] || (( failures++ ))

    _git_menu_entry "Label" "git-status" $'\''Bad\ndescription'\'' \
      >>"$HOME/row.stdout" 2>>"$HOME/row.stderr"
    [[ $? -eq 2 ]] || (( failures++ ))

    _git_menu_entry "" "git-status" "Description" \
      >>"$HOME/row.stdout" 2>>"$HOME/row.stderr"
    [[ $? -eq 2 ]] || (( failures++ ))

    (( failures == 0 ))
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/row.stdout" ]
  grep -Fiq "menu" "$HOME/row.stderr"
}

@test "git interface: menu fzf contract is plain accurate and responsive" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Contract Test"
    command git config user.email "contract@example.invalid"

    _tk_auth_badge() { print -r -- "Contract Test"; }
    export MOCK_FZF_MODE=cancel
    export MOCK_FZF_STATUS=130

    git-menu >"$HOME/menu.stdout" 2>"$HOME/menu.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/menu.stdout" ]

  grep -Fq -- "--height=80%" "$MOCK_FZF_ARGS_FILE"
  grep -Fq -- "--layout=reverse" "$MOCK_FZF_ARGS_FILE"
  grep -Fq -- "--border=rounded" "$MOCK_FZF_ARGS_FILE"
  grep -Fq -- '--delimiter=\[\|\]' "$MOCK_FZF_ARGS_FILE"
  grep -Fq -- "--with-nth=1" "$MOCK_FZF_ARGS_FILE"
  grep -Fq -- "--prompt=git\\ \\>\\ " "$MOCK_FZF_ARGS_FILE"
  grep -Fq -- "--preview=" "$MOCK_FZF_ARGS_FILE"
  grep -Eq -- "--preview-window=.*wrap" "$MOCK_FZF_ARGS_FILE"

  grep -Fq "Repository:" "$MOCK_FZF_ARGS_FILE"
  grep -Fq "Branch:" "$MOCK_FZF_ARGS_FILE"
  grep -Fq "Identity:" "$MOCK_FZF_ARGS_FILE"
  grep -Fq "Remote:" "$MOCK_FZF_ARGS_FILE"
  grep -Fq "GitHub CLI:" "$MOCK_FZF_ARGS_FILE"
  grep -Fq "Type to filter | Enter run | Esc cancel | Ctrl-/ details" \
    "$MOCK_FZF_ARGS_FILE"
  if grep -Fq "Tab" "$MOCK_FZF_ARGS_FILE"; then
    return 1
  fi
  if grep -Fq '\E' "$MOCK_FZF_ARGS_FILE" \
    || grep -Fq '\e' "$MOCK_FZF_ARGS_FILE" \
    || grep -Fq '\033' "$MOCK_FZF_ARGS_FILE"; then
    return 1
  fi

  awk -F "|" "NF != 3 { exit 1 }" "$MOCK_FZF_INPUT_FILE"
  if LC_ALL=C grep -q $'\033' "$MOCK_FZF_INPUT_FILE"; then
    return 1
  fi
}

@test "git interface: outside-repository rows expose context without changing commands" {
  run run_zsh '
    cd "$HOME" || return 1
    export MOCK_FZF_MODE=cancel
    export MOCK_FZF_STATUS=130

    git-menu >"$HOME/menu.stdout" 2>"$HOME/menu.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/menu.stdout" ]
  grep -Fq "Repository: none" "$MOCK_FZF_ARGS_FILE"

  awk -F "|" '
    $2 == "git-status" {
      found = 1
      if ($1 !~ /unavailable: repository/) exit 1
    }
    END { if (!found) exit 1 }
  ' "$MOCK_FZF_INPUT_FILE"

  awk -F "|" '
    $2 == "git-repo-create" || $2 == "git-identity-switcher" {
      found[$2] = 1
      if ($1 ~ /unavailable: repository/) exit 1
    }
    END {
      if (!found["git-repo-create"] || !found["git-identity-switcher"]) exit 1
    }
  ' "$MOCK_FZF_INPUT_FILE"

  [ "$(awk -F "|" '$2 == "git-status" { print $2 }' \
    "$MOCK_FZF_INPUT_FILE")" = "git-status" ]
}

@test "git interface: NO_COLOR suppresses helper ANSI and forces monochrome fzf" {
  run run_zsh '
    export NO_COLOR=1
    export TERM=xterm-256color

    export MOCK_FZF_MODE=cancel
    export MOCK_FZF_STATUS=130

    print -r -- "Label|command|Description" |
      _git_fzf --prompt="git > " >"$HOME/no-color-fzf.stdout"
    local fzf_rc=$?
    [[ "$fzf_rc" -eq 130 ]] || return 1

    _git_no_color_helper_probe() {
      print -u2 -r -- "TTY_PROBE:$([[ -t 2 ]] && print yes || print no)"
      _git_header "Header"
      _git_success "Success"
      _git_warn "Warning"
      _git_info "Info"
      _git_error "Error"
      _git_dim "Dim"
      _git_label "Label:" "Value"
    }

    zmodload zsh/zpty || return 1
    zpty no_color_helpers _git_no_color_helper_probe || return 1

    local chunk=""
    while zpty -r no_color_helpers chunk 2>/dev/null; do
      print -rn -- "$chunk" >>"$HOME/no-color-helper.stderr"
    done
    zpty -d no_color_helpers 2>/dev/null || true
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/no-color-fzf.stdout" ]
  grep -Fq -- "--height=70%" "$MOCK_FZF_ARGS_FILE"
  grep -Eq -- '--no-color$' "$MOCK_FZF_ARGS_FILE"

  grep -Fq "TTY_PROBE:yes" "$HOME/no-color-helper.stderr"
  grep -Fq "✔ Success" "$HOME/no-color-helper.stderr"
  if LC_ALL=C grep -q $'\033' "$HOME/no-color-helper.stderr"; then
    return 1
  fi
}

@test "git interface: fzf cancellation is zero and fzf failure is nonzero" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Contract Test"
    command git config user.email "contract@example.invalid"

    _tk_auth_badge() { print -r -- "Contract Test"; }
    _git_dispatch() {
      print -r -- "$@" >>"$HOME/dispatched-actions"
      return 99
    }

    export MOCK_FZF_MODE=cancel
    export MOCK_FZF_STATUS=130
    git-menu >"$HOME/cancel.stdout" 2>"$HOME/cancel.stderr"
    local cancel_rc=$?

    export MOCK_FZF_STATUS=2
    git-menu >"$HOME/error.stdout" 2>"$HOME/error.stderr"
    local error_rc=$?

    print -r -- "$cancel_rc:$error_rc"
    [[ "$cancel_rc" -eq 0 && "$error_rc" -ne 0 ]]
  '

  [ "$status" -eq 0 ]
  [ "$output" = "0:1" ]
  [ ! -e "$HOME/dispatched-actions" ]
  [ ! -s "$HOME/cancel.stdout" ]
  [ ! -s "$HOME/error.stdout" ]
}

@test "git interface: programmable selection dispatches one action once" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Contract Test"
    command git config user.email "contract@example.invalid"

    _tk_auth_badge() { print -r -- "Contract Test"; }
    export MOCK_FZF_MODE=match
    export MOCK_FZF_MATCH="|git-status|"
    _git_test_timed() {
      local label="$1"
      shift
      print -r -- "$label" >>"$HOME/timing-labels"
      "$@"
    }
    _git_timed() { _git_test_timed "$@"; }
    _timed() { _git_test_timed "$@"; }
    _git_dispatch() {
      print -r -- "$@" >>"$HOME/dispatched-actions"
      return 7
    }

    git-menu >"$HOME/menu.stdout" 2>"$HOME/menu.stderr"
  '

  [ "$status" -eq 7 ]
  [ ! -s "$HOME/menu.stdout" ]
  [ "$(cat "$HOME/dispatched-actions")" = "git-status" ]
  [ "$(wc -l <"$HOME/dispatched-actions")" -eq 1 ]
  [ "$(cat "$HOME/timing-labels")" = "git:git-status" ]
}

@test "git interface: human status UI uses stderr only" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Contract Test"
    command git config user.email "contract@example.invalid"

    git-status >"$HOME/status.stdout" 2>"$HOME/status.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/status.stdout" ]
  grep -Fq "Repository Status" "$HOME/status.stderr"
}

@test "git interface: standalone sourcing is silent idempotent and directly usable" {
  local stdout_file="$TEST_TEMP_DIR/source.stdout"
  local stderr_file="$TEST_TEMP_DIR/source.stderr"
  local probe_file="$TEST_TEMP_DIR/source.probes"

  run env \
    HOME="$HOME" \
    PATH="$PATH" \
    zsh -f -c '
      typeset probe_log="$3"
      fzf() { print -r -- "fzf" >>"$probe_log"; return 99; }
      gh() { print -r -- "gh" >>"$probe_log"; return 99; }
      git() { print -r -- "git" >>"$probe_log"; return 99; }

      {
        source "$1/functions/git-menu.zsh" || return 1
        source "$1/functions/git-menu.zsh" || return 2
      } >"$4" 2>"$5"

      [[ ! -e "$probe_log" ]] || return 3
      [[ ! -s "$4" && ! -s "$5" ]] || return 4

      local dispatch_count_file="$6"
      _git_dispatch() {
        print -r -- "$#" >"$dispatch_count_file"
        print -rl -- "$@"
        return 7
      }
      git-menu git-status "value with spaces" \
        >"$7" 2>"$8"
      local direct_rc=$?
      [[ "$direct_rc" -eq 7 ]] || return 5
      [[ "$(cat "$6")" -eq 2 ]] || return 6
    ' zsh \
    "$TEST_SUITE_ROOT" \
    "$HOME" \
    "$probe_file" \
    "$stdout_file" \
    "$stderr_file" \
    "$TEST_TEMP_DIR/direct.count" \
    "$TEST_TEMP_DIR/direct.stdout" \
    "$TEST_TEMP_DIR/direct.stderr"

  [ "$status" -eq 0 ]
  [ ! -e "$probe_file" ]
  [ ! -s "$stdout_file" ]
  [ ! -s "$stderr_file" ]
}

@test "git interface: loader fails closed without a home fallback and can retry" {
  local loader_root="$TEST_TEMP_DIR/copied-suite"
  local fallback_root="$HOME/.oh-my-zsh/custom/functions/git"
  mkdir -p "$loader_root/functions/git" "$fallback_root"
  cp \
    "$TEST_SUITE_ROOT/functions/git-menu.zsh" \
    "$TEST_SUITE_ROOT/functions/git-common.zsh" \
    "$loader_root/functions/"
  cp "$TEST_SUITE_ROOT"/functions/git/*.zsh "$loader_root/functions/git/"
  mv \
    "$loader_root/functions/git/git-stash.zsh" \
    "$loader_root/git-stash.withheld"
  printf '%s\n' \
    'typeset -g GIT_HOME_FALLBACK_USED=1' \
    'git-stash() { return 0; }' \
    >"$fallback_root/git-stash.zsh"

  run env \
    HOME="$HOME" \
    PATH="$PATH" \
    zsh -f -c '
      typeset loader_root="$1"
      export ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"

      source "$loader_root/functions/git-menu.zsh" \
        >"$HOME/failed-load.stdout" 2>"$HOME/failed-load.stderr"
      local -i failed_rc=$?
      (( failed_rc != 0 )) || return 1
      [[ -z "${GIT_HOME_FALLBACK_USED:-}" ]] || return 2
      [[ -z "${_GIT_MENU_SOURCED:-}" ]] || return 3

      command cp \
        "$loader_root/git-stash.withheld" \
        "$loader_root/functions/git/git-stash.zsh" \
        || return 4
      source "$loader_root/functions/git-menu.zsh" \
        >"$HOME/retry.stdout" 2>"$HOME/retry.stderr"
      local -i retry_rc=$?
      (( retry_rc == 0 )) || return 5
      [[ "${_GIT_MENU_SOURCED:-}" == "1" ]] || return 6

      print -r -- "$failed_rc:$retry_rc"
    ' zsh "$loader_root"

  [ "$status" -eq 0 ]
  [ "$output" = "1:0" ]
  [ ! -s "$HOME/failed-load.stdout" ]
  grep -Fq "failed to load git-stash.zsh" "$HOME/failed-load.stderr"
  [ ! -s "$HOME/retry.stdout" ]
  [ ! -s "$HOME/retry.stderr" ]
}

@test "git interface: loader rejects a symlinked mandatory module" {
  local loader_root="$TEST_TEMP_DIR/symlinked-suite"
  mkdir -p "$loader_root/functions/git"
  cp \
    "$TEST_SUITE_ROOT/functions/git-menu.zsh" \
    "$TEST_SUITE_ROOT/functions/git-common.zsh" \
    "$loader_root/functions/"
  cp "$TEST_SUITE_ROOT"/functions/git/*.zsh "$loader_root/functions/git/"
  mv \
    "$loader_root/functions/git/git-stash.zsh" \
    "$loader_root/git-stash.outside"
  ln -s \
    "$loader_root/git-stash.outside" \
    "$loader_root/functions/git/git-stash.zsh"

  run env HOME="$HOME" PATH="$PATH" zsh -f -c '
    source "$1/functions/git-menu.zsh"
  ' zsh "$loader_root"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to load git-stash.zsh"* ]]
}
