#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export APT_RECOVERY_LOG="$TEST_TEMP_DIR/apt-recovery.log"
  export APT_SIMULATION_STATUS=0
  export APT_TRANSIENT_INDEX_ERROR=0
  export APT_DIRTY_STATE=0
  : > "$APT_RECOVERY_LOG"
  cat > "$TEST_MOCK_BIN/apt-recovery-env" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == -i ]] || exit 97
shift
while [[ "${1:-}" == *=* ]]; do shift; done
[[ "${1:-}" == apt-get ]] || exit 97
shift
if IFS= read -r unexpected_input; then exit 98; fi
if [[ " $* " == *" -s "* ]]; then
  printf 'simulate\n' >> "$APT_RECOVERY_LOG"
  if [[ "$APT_SIMULATION_STATUS" != 0 ]]; then
    printf 'E: The cached package lists could not be read.\n' >&2
    exit "$APT_SIMULATION_STATUS"
  fi
  printf 'Inst example [1.0] (1.1 stable [amd64])\n'
  exit 0
fi
case " $* " in
  *" update "*)
    printf 'update\n' >> "$APT_RECOVERY_LOG"
    if [[ "$APT_TRANSIENT_INDEX_ERROR" == 1 ]]; then
      printf 'W: Some index files failed to download. They have been ignored, or old ones used instead.\n' >&2
      [[ " $* " == *" --error-on=any "* ]] && exit 100
    fi
    ;;
  *" full-upgrade "*) printf 'full-upgrade\n' >> "$APT_RECOVERY_LOG" ;;
  *" autoremove "*) printf 'autoremove\n' >> "$APT_RECOVERY_LOG" ;;
  *) exit 97 ;;
esac
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/apt-recovery-env"
}

teardown() {
  cleanup_sandbox
}

run_apt_recovery_zsh() {
  run_zsh '
    source "$TEST_SUITE_ROOT/functions/sys-menu.zsh" || exit
    _SYS_PRIVILEGE_NONINTERACTIVE=1
    _sys_has_capability() { [[ "$1" == "package:apt" ]]; }
    _sys_update_resolve_trusted_program() {
      [[ "${APT_UNSAFE_ENV:-0}" == 0 && "$1" == env ]] || return 1
      REPLY="$TEST_MOCK_BIN/apt-recovery-env"
    }
    _sys_run_with_timeout() { shift; "$@"; }
    _sys_apt_plan_blocker() {
      REPLY=""
      return "${APT_INVALID_PLAN_STATUS:-0}"
    }
    _sys_resolve_privilege_prefix() { reply=(); }
    _sys_apt_dpkg_state_clean() {
      print -r -- "audit:${1:-before}" >> "$APT_RECOVERY_LOG"
      if [[ "$APT_DIRTY_STATE" == 1 ]]; then
        _sys_error "dpkg has an unfinished transaction."
        return 1
      fi
    }
    _sys_apt_report_reboot_requirement() {
      print -r -- "reboot-report" >> "$APT_RECOVERY_LOG"
    }
    update-apt ${=APT_RECOVERY_OPTIONS:---yes}
  '
}

@test "sys APT recovery: an advisory simulation failure still permits one authorized refresh" {
  export APT_SIMULATION_STATUS=100
  run run_apt_recovery_zsh

  [ "$status" -eq 0 ]
  [[ "$output" == *"advisory APT snapshot"* ]]
  [[ "$output" == *"APT update plan completed"* ]]
  [ "$(cat "$APT_RECOVERY_LOG")" = $'simulate\naudit:before\nupdate\nfull-upgrade\nautoremove\naudit:after\nreboot-report' ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys APT recovery: a timed out preview can recover without retrying the preview" {
  export APT_SIMULATION_STATUS=124
  run run_apt_recovery_zsh

  [ "$status" -eq 0 ]
  [ "$(grep -c '^simulate$' "$APT_RECOVERY_LOG")" -eq 1 ]
  [ "$(grep -c '^update$' "$APT_RECOVERY_LOG")" -eq 1 ]
}

@test "sys APT recovery: an unsuccessful dry run never starts a refresh" {
  export APT_SIMULATION_STATUS=100
  export APT_RECOVERY_OPTIONS="--dry-run --yes"
  run run_apt_recovery_zsh

  [ "$status" -eq 1 ]
  [[ "$output" != *"Dry run complete"* ]]
  [ "$(cat "$APT_RECOVERY_LOG")" = "simulate" ]
}

@test "sys APT recovery: transient index errors cannot produce a successful upgrade" {
  export APT_TRANSIENT_INDEX_ERROR=1
  run run_apt_recovery_zsh

  [ "$status" -eq 1 ]
  [[ "$output" == *"APT index update failed"* ]]
  [[ "$output" != *"APT update plan completed"* ]]
  [ "$(cat "$APT_RECOVERY_LOG")" = $'simulate\naudit:before\nupdate\naudit:after\nreboot-report' ]
}

@test "sys APT recovery: recovering a preview still requires explicit authorization" {
  export APT_SIMULATION_STATUS=100
  export APT_RECOVERY_OPTIONS="--verbose"
  run run_apt_recovery_zsh

  [ "$status" -eq 1 ]
  [[ "$output" == *"Non-interactive APT updates require --yes"* ]]
  [ "$(cat "$APT_RECOVERY_LOG")" = "simulate" ]
}

@test "sys APT recovery: invalid configuration and dirty dpkg still prevent mutation" {
  export APT_SIMULATION_STATUS=100
  export APT_INVALID_PLAN_STATUS=2
  run run_apt_recovery_zsh
  [ "$status" -eq 2 ]
  [ "$(cat "$APT_RECOVERY_LOG")" = "simulate" ]

  export APT_INVALID_PLAN_STATUS=0
  export APT_DIRTY_STATE=1
  : > "$APT_RECOVERY_LOG"
  run run_apt_recovery_zsh
  [ "$status" -eq 1 ]
  [[ "$output" == *"dpkg has an unfinished transaction"* ]]
  [ "$(cat "$APT_RECOVERY_LOG")" = $'simulate\naudit:before' ]
}

@test "sys APT recovery: an untrusted runner cannot enter the advisory fallback" {
  export APT_UNSAFE_ENV=1
  run run_apt_recovery_zsh

  [ "$status" -eq 1 ]
  [[ "$output" == *"trusted root-owned env program"* ]]
  [ ! -s "$APT_RECOVERY_LOG" ]
}
