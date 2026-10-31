# shellcheck disable=SC2016
# Seed only the new option probes, leaving unrelated test cases untouched.
f304_mock_local_probes() {
  printf '#!/bin/sh\nprintf "0.74.3 (fixture)\\n"\n' > "$TEST_MOCK_BIN/fzf"
  printf '#!/bin/sh\nexit 97\n' > "$TEST_MOCK_BIN/ip"
  printf '#!/bin/sh\nexit 97\n' > "$TEST_MOCK_BIN/kubectl"
  chmod -- 755 "$TEST_MOCK_BIN/fzf" "$TEST_MOCK_BIN/ip" "$TEST_MOCK_BIN/kubectl"
}

# Proposed test-only helpers for core option and regex-state regression tests.

f304_regex_probe() {
  export F304_SERVICE="$1" F304_REGEX_MODE="$2"
  run_zsh '
    builtin cd -- "$HOME" || exit 80
    # Fixture preparation precedes seeding, so only the service under test is
    # allowed to determine whether caller regex state changes.
    _f304_error() { print -ru2 -- "$*"; }
    _f304_picker() { print -r -- selected; }
    _f304_root() { REPLY="$TMPDIR"; }
    _f304_available() { return 0; }
    _f304_confirm() { REPLY=Yes; }
    typeset -A zdx_status_facts=()
    typeset -a zdx_status_files=()
    command mkdir -p "$HOME/proc" "$HOME/project"
    print -r -- "0.50 1.25 2.00 1/20 42" > "$HOME/proc/loadavg"
    : > "$HOME/project/dbt_project.yml"
    local _zdx_cap_display=probe _zdx_cap_max=4096 _zdx_cap_lines=0
    local -i expected_rc=0
    case "$F304_SERVICE" in
      status-wireguard)
        OSTYPE=linux-gnu
        _zdx_status_probe() { REPLY="7: wg-fixture: <UP>"; }
        ;;
      status-project)
        export DBT_TARGET=dev
        builtin cd -- "$HOME/project" || exit 80
        ;;
      status-kubernetes)
        _zdx_status_probe() { REPLY=$'\''fixture\tdefault'\''; }
        ;;
      status-json)
        _zdx_status_collect() {
          local fact
          for fact in detached ahead behind staged unstaged untracked conflicted \
            venv_active project_venv_present project_venv_active uv_lock_older \
            reboot_required disk_size disk_used disk_available disk_percent \
            load_1 load_5 load_15 plugins plugins_available telemetry verbose repo \
            wireguard_known k8s_known k8s_private; do
            zdx_status_facts[$fact]=null
          done
          zdx_status_facts[load_1]=0.50
          zdx_status_facts[zdx_modified]=false
        }
        _zdx_status_collect
        ;;
      plugin-head)
        _zdx_plugins_git() { print -r -- 0123456789012345678901234567890123456789; }
        ;;
      release-checkout)
        command mkdir -p "$HOME/version/.git"
        _zdx_run_with_timeout() {
          case "${(j: :)@}" in
            *--show-toplevel*) print -r -- "$HOME/version" ;;
            *--short=7*) print -r -- deadbee ;;
            *status*) return 0 ;;
            *) return 1 ;;
          esac
        }
        ;;
      reject:step-counter) expected_rc=1 ;;
      reject:confirm-name) expected_rc=3 ;;
      reject:*) expected_rc=2 ;;
    esac
    if [[ "$F304_REGEX_MODE" == seeded ]]; then
      typeset -g MATCH=caller MBEGIN=7 MEND=12
      typeset -ga match=(captured other) mbegin=(2 5) mend=(8 11)
    else
      unset MATCH MBEGIN MEND match mbegin mend
    fi
    case "$F304_SERVICE" in
      duration) _zdx_format_duration 2 ;;
      count) _zdx_count_noun 2 record ;;
      step-counter) _zdx_ui_step_counter_valid 1 2 ;;
      step-banner) COLUMNS=40 _zdx_ui_step_banner 1 2 probe ;;
      table) _zdx_ui_table --outcome-column 2 $'\''Step\tResult'\'' $'\''A\tdone'\'' ;;
      capture-args) _zdx_capture_check_args 1 ;;
      capture-redaction) _zdx_capture_line_sensitive "https://user:pass@example.invalid/" ;;
      master-name) _zdx_plugin_name_valid demo ;;
      master-entry) _zdx_menu_entry Demo demo Description ;;
      status-load) OSTYPE=linux-gnu _zdx_status_load_average "$HOME/proc" ;;
      status-wireguard) _zdx_status_wireguard_interfaces "$HOME/absent-net" ;;
      status-project) _zdx_status_project "" ;;
      status-porcelain)
        _zdx_status_parse_porcelain $'\''# branch.oid 0123456789012345678901234567890123456789\0# branch.head main\0# branch.ab +2 -1\0'\''
        ;;
      doctor-version) _zdx_doctor_get_version fzf ;;
      doctor-package) _zdx_doctor_package_name_valid package-name ;;
      status-kubernetes) _zdx_status_kubernetes ;;
      status-json) _zdx_status_render_json ;;
      plugin-name) _zdx_plugins_name_valid demo ;;
      plugin-head) _zdx_plugins_head "$HOME" ;;
      release-checkout) _zdx_release_checkout "$HOME/version" ;;
      reject:duration) _zdx_format_duration invalid ;;
      reject:count) _zdx_count_noun invalid record ;;
      reject:step-counter) _zdx_ui_step_counter_valid invalid 2 ;;
      reject:capture-args) _zdx_cap_max=invalid _zdx_capture_check_args 1 ;;
      reject:picker-name)
        _zdx_picker_capture --tag probe --noun Probe --error _f304_error \
          --picker invalid --temp-root _f304_root
        ;;
      reject:confirm-name)
        _zdx_confirm_prompt --style picker --error _f304_error \
          --available _f304_available --capture invalid -- "Proceed?"
        ;;
      picker:*)
        "${F304_SERVICE#picker:}" --tag probe --noun Probe \
          --error _f304_error --picker _f304_picker --temp-root _f304_root
        ;;
      confirm:*)
        "${F304_SERVICE#confirm:}" --style picker --error _f304_error \
          --available _f304_available --capture _f304_confirm -- "Proceed?"
        ;;
      *) exit 81 ;;
    esac > "$HOME/service.stdout" 2> "$HOME/service.stderr"
    local service_rc=$?
    (( service_rc == expected_rc )) || {
      print -r -- "service=$F304_SERVICE status=$service_rc expected=$expected_rc"
      command cat "$HOME/service.stderr"
      exit 82
    }
    if [[ "$F304_REGEX_MODE" == seeded ]]; then
      print -r -- "state=$MATCH:$MBEGIN:$MEND:${(j:,:)match}:${(j:,:)mbegin}:${(j:,:)mend}"
      [[ "$MATCH" == caller && "$MBEGIN" == 7 && "$MEND" == 12 ]] || exit 83
      [[ "${(j:,:)match}" == captured,other \
        && "${(j:,:)mbegin}" == 2,5 && "${(j:,:)mend}" == 8,11 ]] || exit 84
    else
      print -r -- "state=${+MATCH}:${+MBEGIN}:${+MEND}:${+match}:${+mbegin}:${+mend}"
      (( ! ${+MATCH} && ! ${+MBEGIN} && ! ${+MEND} \
        && ! ${+match} && ! ${+mbegin} && ! ${+mend} )) || exit 85
    fi
  '
}

f304_lazy_shell() {
  local program="$1"
  env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME -u ZDX_EAGER_LOAD \
    ZDX_LAZY_LOAD=1 zsh -f -c '
      emulate -R zsh
      builtin cd -- "$HOME" || exit 80
      source "$1/functions.zsh" || exit 90
      source "$2" || exit 91
    ' _ "$TEST_SUITE_ROOT" "$program"
}

f304_write_option_plugin() {
  local root="$HOME/.config/zdx/plugins"
  mkdir -p "$root/optiondemo"
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx" "$root" "$root/optiondemo"
  cat > "$root/optiondemo/optiondemo-menu.zsh" <<'ZSH'
setopt null_glob
typeset -g OPTIONDEMO_SOURCE_OPTION=${options[nullglob]}
optiondemo-menu() { [[ "${F304_EXPECT_SPLIT:-}" != yes || -o sh_word_split ]] || return 78; printf 'plugin:<%s>\n' "$@"; }
optiondemo-action() { [[ "${F304_EXPECT_SPLIT:-}" != yes || -o sh_word_split ]] || return 78; printf 'action:<%s>\n' "$@"; }
ZSH
  printf '%s\n' optiondemo-action > "$root/optiondemo/commands"
  chmod -- 600 "$root/optiondemo/optiondemo-menu.zsh" "$root/optiondemo/commands"
}

# One actual executable version field under each independently enabled option.
f304_doctor_option_field() {
  export F304_FIELD_OPTION="$1"
  printf '#!%s\n[[ "$*" == --version ]] || exit 97\nprintf "Python 3.12.3\\n"\n' "$BASH" > "$TEST_MOCK_BIN/python3"
  chmod -- 755 "$TEST_MOCK_BIN/python3"
  run_zsh '
    builtin cd -- "$HOME" || exit 80
    local option_key="${F304_FIELD_OPTION//_/}"
    unset MATCH MBEGIN MEND match mbegin mend
    setopt "$F304_FIELD_OPTION"
    _zdx_doctor_get_version python3 > "$HOME/version.data" 2> "$HOME/version.err"
    local probe_rc=$? kept="${options[$option_key]}"
    unsetopt "$F304_FIELD_OPTION"
    [[ "$probe_rc" == 0 && "$kept" == on ]] || exit 31
    [[ "$(<"$HOME/version.data")" == 3.12.3 && ! -s "$HOME/version.err" ]]
  '
}
