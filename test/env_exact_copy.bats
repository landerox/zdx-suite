#!/usr/bin/env bats

setup() {
  load test_helper
  export EC_ROOT="$HOME/env-exact" EC_ZSH
  EC_ZSH=$(type -P zsh)
  mkdir -m 700 "$EC_ROOT"
  export EC_WINDOWS="$EC_ROOT/windows-clip.exe"
  local backend
  for backend in wl-copy xclip xsel pbcopy clip.exe; do
    printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/$backend"
    cat >> "$TEST_MOCK_BIN/$backend" <<'RECORDER'
[[ "$EC_ROOT" == "$HOME/env-exact" && -d "$EC_ROOT" && ! -L "$EC_ROOT" ]] || exit 97
backend="${0##*/}"
printf '%s\n' "$backend" >> "$EC_ROOT/calls"
printf '%s\n' "$@" > "$EC_ROOT/args"
cat > "$EC_ROOT/bytes"
if [[ "$backend" == wl-copy && -n "${EC_BACKEND_STATUS:-}" ]]; then
  exit "$EC_BACKEND_STATUS"
fi
RECORDER
    chmod -- 700 "$TEST_MOCK_BIN/$backend"
  done
  cp "$TEST_MOCK_BIN/clip.exe" "$EC_WINDOWS"
}

teardown() {
  cleanup_sandbox
}

run_ec() {
  run_zsh '''OSTYPE=linux-gnu
    unset DISPLAY WAYLAND_DISPLAY
    _env_wsl_windows_clip_path() { REPLY="$EC_WINDOWS"; }
    '''"$1"
}

copy_collision() {
  export EC_NAME="$1"
  run run_ec '''export WAYLAND_DISPLAY=fixture
    export "$EC_NAME=exact-export-value"
    env-list --copy "$EC_NAME"'''
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/bytes")" = exact-export-value ]
  [[ "$output" != *exact-export-value* ]]
  [ "$(cat "$EC_ROOT/calls")" = wl-copy ]
}

@test "env exact copy: key is copied from the export" { copy_collision key; }
@test "env exact copy: parameter_type is copied from the export" { copy_collision parameter_type; }
@test "env exact copy: copy_key is copied from the export" { copy_collision copy_key; }
@test "env exact copy: list_mode is copied from the export" { copy_collision list_mode; }
@test "env exact copy: private snapshot names remain valid exports" { copy_collision _env_export_snapshot; }

@test "env exact copy: every helper-name export stays in masked list data" {
  run run_ec '''export key=canary-key parameter_type=canary-type copy_key=canary-copy list_mode=canary-mode
    env-list --list'''
  [ "$status" -eq 0 ]
  local name
  for name in key parameter_type copy_key list_mode; do
    [[ "$output" == *"$name"$'\t<hidden>'* ]]
  done
  [[ "$output" != *canary-* ]]
}

@test "env exact copy: direct copy preserves Unicode and trailing newline bytes" {
  run run_ec '''export WAYLAND_DISPLAY=fixture
    export EC_VALUE=$'''"'"'caf\303\251\nlast\n\n'"'"'''
    env-list --copy EC_VALUE'''
  [ "$status" -eq 0 ]
  printf 'caf\303\251\nlast\n\n' > "$EC_ROOT/expected"
  cmp "$EC_ROOT/expected" "$EC_ROOT/bytes"
  [ "$(cat "$EC_ROOT/calls")" = wl-copy ]
  [[ "$output" != *last* ]]
}

@test "env exact copy: an empty export reaches the backend without a newline" {
  run run_ec '''export WAYLAND_DISPLAY=fixture EC_VALUE=""; env-list --copy EC_VALUE'''
  [ "$status" -eq 0 ]
  [ -f "$EC_ROOT/bytes" ]
  [ "$(file_size "$EC_ROOT/bytes")" -eq 0 ]
}

@test "env exact copy: direct menu dispatch preserves command_name" {
  run run_ec '''export WAYLAND_DISPLAY=fixture command_name=menu-export-value
    env-menu env-list --copy command_name'''
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/bytes")" = menu-export-value ]
  [[ "$output" != *menu-export-value* ]]
}

@test "env exact copy: interactive menu preserves selected for the variable picker" {
  run run_ec '''export WAYLAND_DISPLAY=fixture selected=selected-export-value
    _env_fzf_capture() {
      local row=""
      while IFS= read -r row; do
        if [[ "$row" == *"|env-list|"* || "$row" == *"|selected|"* ]]; then
          REPLY="$row"
          return 0
        fi
      done
      return 1
    }
    env-menu'''
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/bytes")" = selected-export-value ]
  [[ "$output" != *selected-export-value* ]]
}

cold_lazy_copy() {
  export EC_NAME="$1" EC_ROUTE="$2"
  run "$EC_ZSH" -f -c 'emulate -R zsh
    unset TEST_TEMP_DIR BATS_TEST_DIRNAME
    export ZSH_CUSTOM="$TEST_SUITE_ROOT" ZDX_EAGER_LOAD=0 ZDX_LAZY_LOAD=1
    source "$TEST_SUITE_ROOT/functions.zsh" || exit 91
    _env_wsl_windows_clip_path() { REPLY="$EC_WINDOWS"; }
    export WAYLAND_DISPLAY=fixture "$EC_NAME=cold-export-value"
    if [[ "$EC_ROUTE" == menu ]]; then
      env-menu env-list --copy "$EC_NAME"
    else
      env-list --copy "$EC_NAME"
    fi'
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/bytes")" = cold-export-value ]
  [[ "$output" != *cold-export-value* ]]
}

@test "env exact copy: cold lazy direct call preserves function_name" { cold_lazy_copy function_name direct; }
@test "env exact copy: cold lazy menu call preserves source_rc" { cold_lazy_copy source_rc menu; }

@test "env exact copy: successful picker copies only the frozen selected value" {
  export MOCK_FZF_MODE=match MOCK_FZF_MATCH='|EC_PICK_TOKEN|'
  run run_ec '''export WAYLAND_DISPLAY=fixture EC_PICK_TOKEN=picker-canary-value
    env-list'''
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/bytes")" = picker-canary-value ]
  [[ "$output" != *picker-canary-value* ]]
  grep -Fq -- '|EC_PICK_TOKEN|********' "$MOCK_FZF_INPUT_FILE"
  run grep -Fq -- picker-canary-value "$MOCK_FZF_INPUT_FILE" "$MOCK_FZF_ARGS_FILE" "$EC_ROOT/args"
  [ "$status" -eq 1 ]
}

@test "env exact copy: stale selected value refuses before a clipboard write" {
  run run_ec '''export WAYLAND_DISPLAY=fixture EC_PICK_TOKEN=original-canary
    _env_fzf_capture() {
      local row=""
      while IFS= read -r row; do
        if [[ "$row" == *"|EC_PICK_TOKEN|"* ]]; then
          REPLY="$row"
          export EC_PICK_TOKEN=changed-canary
          return 0
        fi
      done
      return 1
    }
    env-list'''
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed while the picker was open"* ]]
  [[ "$output" != *original-canary* && "$output" != *changed-canary* ]]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: without iconv ASCII goes unchanged to clip.exe" {
  run run_ec '''whence() { [[ "$1" == -p && "$2" == iconv ]] && return 1; builtin whence "$@"; }
    export EC_VALUE=ascii-canary
    env-list --copy EC_VALUE'''
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/bytes")" = ascii-canary ]
  [ "$(cat "$EC_ROOT/calls")" = clip.exe ]
}

@test "env exact copy: without iconv non-ASCII is refused before clip.exe" {
  run run_ec '''whence() { [[ "$1" == -p && "$2" == iconv ]] && return 1; builtin whence "$@"; }
    export EC_VALUE=$'''"'"'caf\303\251'"'"'''
    env-list --copy EC_VALUE'''
  [ "$status" -eq 1 ]
  [[ "$output" == *"iconv is required"* ]]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: a backend error never tries a second clipboard backend" {
  export EC_BACKEND_STATUS=1
  run run_ec '''export WAYLAND_DISPLAY=fixture EC_VALUE=backend-canary
    env-list --copy EC_VALUE'''
  [ "$status" -eq 1 ]
  [ "$(cat "$EC_ROOT/calls")" = wl-copy ]
  [[ "$output" == *"clipboard backend failed"* && "$output" != *backend-canary* ]]
}

@test "env exact copy: missing Wayland capability can select clip.exe" {
  run run_ec '''command() {
      [[ "$1" == -v && "$2" == wl-copy ]] && return 1
      builtin command "$@"
    }
    export WAYLAND_DISPLAY=fixture EC_VALUE=available-canary
    env-list --copy EC_VALUE'''
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/calls")" = clip.exe ]
}

@test "env exact copy: the snapshot cursor name remains a valid export" { copy_collision _env_export_key; }

mutating_picker() {
  export EC_MUTATION="$1" EC_PICK_NAME="$2" EC_MENU="$3"
  run run_ec '''export WAYLAND_DISPLAY=fixture EC_PICK_TOKEN=original-canary
    export selected=original-selected
    if [[ "$EC_MUTATION" == tied ]]; then
      unset selected
      typeset -Tx selected EC_SELECTED_PARTS=(original-selected)
    fi
    _env_fzf_capture() {
      local row=""
      while IFS= read -r row; do
        if [[ "$row" == *"|env-list|"* ]]; then
          REPLY="$row"
          return 0
        fi
        if [[ "$row" == *"|$EC_PICK_NAME|"* ]]; then
          REPLY="$row"
          case "$EC_MUTATION" in
            unset) unset "$EC_PICK_NAME" ;;
            type) unset "$EC_PICK_NAME"; typeset -ga "$EC_PICK_NAME"; set -A "$EC_PICK_NAME" -- changed ;;
            exportlocal) typeset -gx "$EC_PICK_NAME=changed-local" ;;
            tied) EC_SELECTED_PARTS=(changed-global) ;;
            mapunset) unset _env_export_snapshot ;;
            *) return 99 ;;
          esac
          return 0
        fi
      done
      return 1
    }
    if [[ "$EC_MENU" == yes ]]; then env-menu; else env-list; fi
    typeset -i EC_RC=$?
    print -rn -- "$selected" > "$EC_ROOT/global-selected"
    return $EC_RC'''
}

@test "env exact copy: an unset visible export refuses the selected copy" {
  mutating_picker unset EC_PICK_TOKEN no
  [ "$status" -eq 1 ]
  [[ "$output" == *'changed while the picker was open'* ]]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: a changed export type refuses the selected copy" {
  mutating_picker type EC_PICK_TOKEN no
  [ "$status" -eq 1 ]
  [[ "$output" == *'changed while the picker was open'* ]]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: a newly exported internal local cannot pass stale validation" {
  mutating_picker exportlocal selected yes
  [ "$status" -eq 1 ]
  [[ "$output" == *'could not be revalidated'* ]]
  [ "$(cat "$EC_ROOT/global-selected")" = original-selected ]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: a tied hidden export is refused and direct copy reads its current value" {
  mutating_picker tied selected yes
  [ "$status" -eq 1 ]
  [[ "$output" == *'env-list --copy selected'* ]]
  [ "$(cat "$EC_ROOT/global-selected")" = changed-global ]
  [ ! -e "$EC_ROOT/calls" ]
  run run_ec '''export WAYLAND_DISPLAY=fixture
    typeset -Tx selected EC_SELECTED_PARTS=(changed-global)
    env-list --copy selected'''
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/bytes")" = changed-global ]
}

@test "env exact copy: missing private snapshot state refuses before clipboard access" {
  mutating_picker mapunset EC_PICK_TOKEN no
  [ "$status" -eq 1 ]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: forwarded help bypasses export inventory limits" {
  run run_ec '_ENV_MAX_RECORDS=0; env-menu env-list --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *'Usage:'* && "$output" != *'inventory exceeds'* ]]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: forwarded invalid grammar precedes export inventory limits" {
  run run_ec '_ENV_MAX_RECORDS=0; env-menu env-list --invalid'
  [ "$status" -eq 2 ]
  [[ "$output" == *'Unknown env-list argument:'* && "$output" != *'inventory exceeds'* ]]
  [ ! -e "$EC_ROOT/calls" ]
}

master_env_picker() {
  run_ec '''export WAYLAND_DISPLAY=fixture
    _zdx_fzf_capture() {
      local row=""
      while IFS= read -r row; do
        if [[ "$row" == *"|env|"* ]]; then REPLY="$row"; return 0; fi
      done
      return 1
    }
    _env_fzf_capture() {
      local row=""
      while IFS= read -r row; do
        if [[ "$row" == *"|env-list|"* || "$row" == *"|$EC_MASTER_NAME|"* ]]; then
          REPLY="$row"
          if [[ "$row" == *"|$EC_MASTER_NAME|"* && "$EC_MASTER_TIED" == yes ]]; then
            EC_MASTER_PARTS=(changed-global)
          fi
          return 0
        fi
      done
      return 1
    }
    '''"$1"'
    zdx'
}

@test "env exact copy: the master copy route retains the suite_name export" {
  run run_ec 'export WAYLAND_DISPLAY=fixture suite_name=master-canary
    zdx env env-list --copy suite_name'
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/bytes")" = master-canary ]
  [[ "$output" != *master-canary* ]]
}

@test "env exact copy: the master list route retains the masked suite_name export" {
  run run_ec 'export suite_name=master-canary; zdx env env-list --list'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'suite_name\t<hidden>'* && "$output" != *master-canary* ]]
}

@test "env exact copy: the interactive master retains its private-name export" {
  export EC_MASTER_NAME=_zdx_selected_suite EC_MASTER_TIED=no
  run master_env_picker 'export _zdx_selected_suite=master-private-canary'
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/bytes")" = master-private-canary ]
  [[ "$output" != *master-private-canary* ]]
}

@test "env exact copy: occupied interactive carriers remain visible in the export snapshot" {
  export EC_MASTER_NAME=_zdx_selected_suite__ EC_MASTER_TIED=no
  run master_env_picker 'export _zdx_selected_suite=occupied-zero
    export _zdx_selected_suite_=occupied-one _zdx_selected_suite__=occupied-two'
  [ "$status" -eq 0 ]
  [ "$(cat "$EC_ROOT/bytes")" = occupied-two ]
  [[ "$output" != *occupied-* ]]
}

@test "env exact copy: all 128 occupied carriers refuse before opening the master picker" {
  run run_ec 'EC_CARRIER_NAME=_zdx_selected_suite
    repeat 128; do
      typeset -gx "$EC_CARRIER_NAME=occupied-canary"
      EC_CARRIER_NAME="${EC_CARRIER_NAME}_"
    done
    _zdx_fzf_capture() { print -r -- called > "$EC_ROOT/picker-called"; return 1; }
    zdx'
  [ "$status" -eq 1 ]
  [[ "$output" == *'selection context'* && "$output" != *occupied-canary* ]]
  [ ! -e "$EC_ROOT/picker-called" ]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: master cancellation creates no global carrier under strict caller options" {
  run run_ec 'unset _zdx_selected_suite _zdx_selected_suite_
    unset MATCH MBEGIN MEND match mbegin mend
    _zdx_fzf_capture() { REPLY=""; return 130; }
    setopt nounset ksh_arrays
    zdx || exit 71
    [[ -o nounset && -o ksh_arrays ]] || exit 72
    (( ! ${+parameters[_zdx_selected_suite]} && ! ${+parameters[_zdx_selected_suite_]} )) || exit 73
    (( ! ${+MATCH} && ! ${+MBEGIN} && ! ${+MEND} && ! ${+match} && ! ${+mbegin} && ! ${+mend} ))'
  [ "$status" -eq 0 ]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: a tied private-name export changed after the master picker refuses copying" {
  export EC_MASTER_NAME=_zdx_selected_suite EC_MASTER_TIED=yes
  run master_env_picker 'unset _zdx_selected_suite
    typeset -Tx _zdx_selected_suite EC_MASTER_PARTS=(original-global)'
  [ "$status" -eq 1 ]
  [[ "$output" == *'changed while the picker was open'* ]]
  [[ "$output" != *original-global* && "$output" != *changed-global* ]]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: direct master routing preserves override argv options and match state" {
  run run_ec 'env-menu() {
      [[ -o ksh_arrays && -o nounset && -o sh_word_split ]] || return 71
      [[ "$MATCH" == caller && "$MBEGIN" == 7 && "$MEND" == 12 ]] || return 72
      printf "<%s>\n" "$@" > "$EC_ROOT/override-argv"
      setopt null_glob
    }
    MATCH=caller MBEGIN=7 MEND=12
    setopt ksh_arrays nounset sh_word_split
    unsetopt null_glob
    zdx env "one two" "" "*[literal]" || exit 73
    [[ -o ksh_arrays && -o nounset && -o sh_word_split && -o null_glob ]]'
  [ "$status" -eq 0 ]
  printf '<one two>\n<>\n<*[literal]>\n' > "$EC_ROOT/expected"
  cmp "$EC_ROOT/expected" "$EC_ROOT/override-argv"
}

@test "env exact copy: interactive master routing returns from preparation before an override" {
  run run_ec '_zdx_fzf_capture() {
      local row=""
      while IFS= read -r row; do
        if [[ "$row" == *"|env|"* ]]; then REPLY="$row"; return 0; fi
      done
      return 1
    }
    env-menu() {
      [[ -o ksh_arrays && -o nounset && -o sh_word_split ]] || return 71
      [[ "$MATCH" == caller && "$MBEGIN" == 7 && "$MEND" == 12 && $# == 0 ]] || return 72
      setopt null_glob
    }
    MATCH=caller MBEGIN=7 MEND=12
    setopt ksh_arrays nounset sh_word_split
    unsetopt null_glob
    zdx || exit 73
    [[ -o ksh_arrays && -o nounset && -o sh_word_split && -o null_glob ]]'
  [ "$status" -eq 0 ]
}

@test "env exact copy: the private master carrier stays unexported with ALLEXPORT inherited" {
  run run_ec '_zdx_fzf_capture() {
      local row=""
      while IFS= read -r row; do
        if [[ "$row" == *"|env|"* ]]; then REPLY="$row"; return 0; fi
      done
      return 1
    }
    env-menu() {
      [[ -o allexport && "${parameters[_zdx_selected_suite]}" == scalar-local ]] || return 71
    }
    unset _zdx_selected_suite
    setopt allexport
    zdx || exit 72
    [[ -o allexport ]] && (( ! ${+parameters[_zdx_selected_suite]} ))'
  [ "$status" -eq 0 ]
}

@test "env exact copy: the master selector refuses an arbitrary output name without evaluation" {
  export EC_INVALID_NAME='_zdx_selected_suite[$(print -r -- unsafe > "$EC_ROOT/evaluated")]'
  run run_ec '_zdx_fzf_capture() { print -r -- called > "$EC_ROOT/picker-called"; return 1; }
    _zdx_interactive_select "$EC_INVALID_NAME"'
  [ "$status" -eq 1 ]
  [[ "$output" == *'selection context'* ]]
  [ ! -e "$EC_ROOT/picker-called" ]
  [ ! -e "$EC_ROOT/evaluated" ]
  [ ! -e "$EC_ROOT/calls" ]
}

changed_master_carrier() {
  export EC_CARRIER_CHANGE="$1"
  run run_ec 'unset _zdx_selected_suite
    _zdx_fzf_capture() {
      local row=""
      while IFS= read -r row; do
        if [[ "$row" == *"|env|"* ]]; then
          REPLY="$row"
          case "$EC_CARRIER_CHANGE" in
            unset) unset _zdx_selected_suite ;;
            export) typeset -gx _zdx_selected_suite=changed ;;
          esac
          return 0
        fi
      done
      return 1
    }
    env-menu() { print -r -- called > "$EC_ROOT/dispatched"; }
    zdx
    local EC_CARRIER_RC=$?
    print -r -- "${parameters[_zdx_selected_suite]-absent}" > "$EC_ROOT/carrier-type"
    return $EC_CARRIER_RC'
}

@test "env exact copy: a removed master carrier refuses before dispatch and remains absent" {
  changed_master_carrier unset
  [ "$status" -eq 1 ]
  [ ! -e "$EC_ROOT/dispatched" ]
  [ "$(cat "$EC_ROOT/carrier-type")" = absent ]
  [ ! -e "$EC_ROOT/calls" ]
}

@test "env exact copy: an exported master carrier refuses before dispatch" {
  changed_master_carrier export
  [ "$status" -eq 1 ]
  [ ! -e "$EC_ROOT/dispatched" ]
  [ ! -e "$EC_ROOT/calls" ]
}

corrupted_revalidation_metadata() {
    export EC_MAP_CORRUPTION="$1"
    run run_ec 'export WAYLAND_DISPLAY=fixture EC_REVIEW_VALUE=original-private-canary
      _env_fzf_capture() {
        local row=""
        while IFS= read -r row; do
          if [[ "$row" == *"|EC_REVIEW_VALUE|"* ]]; then
            REPLY="$row"
            if [[ "$EC_MAP_CORRUPTION" == value ]]; then
              export EC_REVIEW_VALUE=changed-private-canary
              _env_export_snapshot[value:EC_REVIEW_VALUE]=changed-private-canary
            else
              typeset -gxl EC_REVIEW_VALUE
              _env_export_snapshot[type:EC_REVIEW_VALUE]="${parameters[EC_REVIEW_VALUE]}"
            fi
            return 0
          fi
        done
        return 1
      }
      env-list'
    [ "$status" -eq 1 ]
    [ ! -e "$EC_ROOT/calls" ]
    [[ "$output" != *original-private-canary* && "$output" != *changed-private-canary* ]]
}

@test "env exact copy: changed revalidation metadata cannot authorize a cached old value" {
  corrupted_revalidation_metadata value
}

@test "env exact copy: changed revalidation metadata cannot authorize a cached old type" {
  corrupted_revalidation_metadata type
}

@test "env exact copy: an untouched master context copies the selected exact bytes" {
  export EC_MASTER_NAME=EC_REVIEW_VALUE EC_MASTER_TIED=no
  run master_env_picker 'export EC_REVIEW_VALUE=$'"'"'exact-private\n\n'"'"''
  [ "$status" -eq 0 ]
  printf 'exact-private\n\n' > "$EC_ROOT/expected"
  cmp "$EC_ROOT/expected" "$EC_ROOT/bytes"
  [[ "$output" != *exact-private* ]]
}
